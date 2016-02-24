!=========================================================================
! This file is part of MOLGW.
!=========================================================================
module m_hamiltonian_dist
 use m_definitions
 use m_mpi
 use m_timing
 use m_warning
 use m_memory
 use m_inputparam,only: nspin,spin_fact


 real(dp),private,allocatable :: buffer(:,:)


contains


!=========================================================================
subroutine allocate_buffer(nbf)
 implicit none

 integer,intent(in) :: nbf
!=====

 write(stdout,'(/,x,a)') 'For SCALAPACK buffer, only this buffer is not distributed'
 call clean_allocate('large buffer that is not distributed',buffer,nbf,nbf)

end subroutine allocate_buffer


!=========================================================================
subroutine destroy_buffer()
 implicit none

!=====

 call clean_deallocate('large buffer that is not distributed',buffer)

end subroutine destroy_buffer


!=========================================================================
subroutine reduce_hamiltonian_sca(m_ham,n_ham,matrix_local)
 implicit none

 integer,intent(in)   :: m_ham,n_ham
 real(dp),intent(out) :: matrix_local(m_ham,n_ham)
!=====
 integer              :: nbf
 integer              :: ipcol,iprow,rank_dest
 integer              :: ilocal,jlocal,iglobal,jglobal
 integer              :: m_block,n_block
 real(dp),allocatable :: matrix_block(:,:)
!=====

 call start_clock(timing_sca_distr)

 nbf = SIZE(buffer(:,:),DIM=1)

#ifdef HAVE_SCALAPACK

 ! Loops over the SCALAPACK grid
 do ipcol=0,npcol_ham-1
   do iprow=0,nprow_ham-1

     ! Identify the destination processor
     rank_dest = rank_ham_sca_to_mpi(iprow,ipcol)

     m_block = row_block_size(nbf,iprow,nprow_ham)
     n_block = col_block_size(nbf,ipcol,npcol_ham)
     allocate(matrix_block(m_block,n_block))

     do jlocal=1,n_block
       jglobal = colindex_local_to_global(ipcol,npcol_ham,jlocal)
       do ilocal=1,m_block
         iglobal = rowindex_local_to_global(iprow,nprow_ham,ilocal)

         matrix_block(ilocal,jlocal) = buffer(iglobal,jglobal)

       enddo
     enddo


     call xsum(rank_dest,matrix_block)

     if( rank == rank_dest ) then
       matrix_local(:,:) = matrix_block(:,:)
     endif
     deallocate(matrix_block)

   enddo
 enddo


#else

 matrix_local(:,:) = buffer(:,:)

#endif

 call stop_clock(timing_sca_distr)

end subroutine reduce_hamiltonian_sca


!=========================================================================
subroutine broadcast_hamiltonian_sca(m_ham,n_ham,matrix_local)
 implicit none

 integer,intent(in)     :: m_ham,n_ham
 real(dp),intent(in)    :: matrix_local(m_ham,n_ham)
!=====
 integer              :: nbf
 integer              :: ipcol,iprow,rank_orig
 integer              :: ier
 integer              :: ilocal,jlocal,iglobal,jglobal
 integer              :: m_block,n_block
 real(dp),allocatable :: matrix_block(:,:)
!=====

 call start_clock(timing_sca_distr)

 nbf = SIZE(buffer(:,:),DIM=1)

#ifdef HAVE_SCALAPACK

 ! Loops over the SCALAPACK grid
 do ipcol=0,npcol_ham-1
   do iprow=0,nprow_ham-1

     ! Identify the destination processor
     rank_orig = rank_ham_sca_to_mpi(iprow,ipcol)

     m_block = row_block_size(nbf,iprow,nprow_ham)
     n_block = col_block_size(nbf,ipcol,npcol_ham)
     allocate(matrix_block(m_block,n_block))

     if( rank == rank_orig ) then
       matrix_block(:,:) = matrix_local(:,:)
     endif


     call xbcast(rank_orig,matrix_block)


     do jlocal=1,n_block
       jglobal = colindex_local_to_global(ipcol,npcol_ham,jlocal)
       do ilocal=1,m_block
         iglobal = rowindex_local_to_global(iprow,nprow_ham,ilocal)

         buffer(iglobal,jglobal) = buffer(iglobal,jglobal) + matrix_block(ilocal,jlocal)

       enddo
     enddo

     deallocate(matrix_block)

   enddo
 enddo


#else

 buffer(:,:) = buffer(:,:) + matrix_local(:,:)

#endif

 call stop_clock(timing_sca_distr)

end subroutine broadcast_hamiltonian_sca


!=========================================================================
subroutine setup_nucleus_buffer_sca(print_matrix_,basis,m_ham,n_ham,hamiltonian_nucleus)
 use m_basis_set
 use m_atoms
 implicit none
 logical,intent(in)         :: print_matrix_
 type(basis_set),intent(in) :: basis
 integer,intent(in)         :: m_ham,n_ham
 real(dp),intent(out)       :: hamiltonian_nucleus(m_ham,n_ham)
!=====
 integer              :: natom_local
 integer              :: ibf,jbf
 integer              :: ibf_cart,jbf_cart
 integer              :: i_cart,j_cart
 integer              :: ni,nj,ni_cart,nj_cart,li,lj
 integer              :: iatom
 real(dp),allocatable :: matrix_cart(:,:)
 real(dp)             :: vnucleus_ij
!=====

 call start_clock(timing_hamiltonian_nuc)
 write(stdout,'(/,a)') ' Setup nucleus-electron part of the Hamiltonian: SCALAPACK buffer'


 if( nproc > 1 ) then
   natom_local=0
   do iatom=1,natom
     if( rank /= MODULO(iatom-1,nproc) ) cycle
     natom_local = natom_local + 1
   enddo
   write(stdout,'(a)')         '   Parallelizing over atoms'
   write(stdout,'(a,i5,a,i5)') '   this proc treats ',natom_local,' over ',natom
 endif


 ibf_cart = 1
 jbf_cart = 1
 ibf      = 1
 jbf      = 1
 do while(ibf_cart<=basis%nbf_cart)
   li      = basis%bf(ibf_cart)%am
   ni_cart = number_basis_function_am('CART',li)
   ni      = number_basis_function_am(basis%gaussian_type,li)

   do while(jbf_cart<=basis%nbf_cart)
     lj      = basis%bf(jbf_cart)%am
     nj_cart = number_basis_function_am('CART',lj)
     nj      = number_basis_function_am(basis%gaussian_type,lj)

     allocate(matrix_cart(ni_cart,nj_cart))
     matrix_cart(:,:) = 0.0_dp
     do iatom=1,natom
       if( rank /= MODULO(iatom-1,nproc) ) cycle
       do i_cart=1,ni_cart
         do j_cart=1,nj_cart
           call nucleus_basis_function(basis%bf(ibf_cart+i_cart-1),basis%bf(jbf_cart+j_cart-1),zatom(iatom),x(:,iatom),vnucleus_ij)
           matrix_cart(i_cart,j_cart) = matrix_cart(i_cart,j_cart) + vnucleus_ij
         enddo
       enddo
     enddo
     buffer(ibf:ibf+ni-1,jbf:jbf+nj-1) = MATMUL( TRANSPOSE(cart_to_pure(li)%matrix(:,:)) , &
                                                MATMUL( matrix_cart(:,:) , cart_to_pure(lj)%matrix(:,:) ) )


     deallocate(matrix_cart)
     jbf      = jbf      + nj
     jbf_cart = jbf_cart + nj_cart
   enddo
   jbf      = 1
   jbf_cart = 1

   ibf      = ibf      + ni
   ibf_cart = ibf_cart + ni_cart

 enddo


 ! Sum up the buffers and store the result in the sub matrix hamiltonian_nucleus
 call reduce_hamiltonian_sca(m_ham,n_ham,hamiltonian_nucleus)


 call stop_clock(timing_hamiltonian_nuc)

end subroutine setup_nucleus_buffer_sca


!=========================================================================
subroutine setup_hartree_ri_buffer_sca(print_matrix_,nbf,m_ham,n_ham,p_matrix,hartree_ij,ehartree)
 use m_eri
 implicit none
 logical,intent(in)   :: print_matrix_
 integer,intent(in)   :: nbf,m_ham,n_ham
 real(dp),intent(in)  :: p_matrix(m_ham,n_ham,nspin)
 real(dp),intent(out) :: hartree_ij(m_ham,n_ham)
 real(dp),intent(out) :: ehartree
!=====
 integer              :: ibf,jbf,kbf,lbf
 integer              :: ipair
 real(dp),allocatable :: partial_sum(:)
 real(dp)             :: rtmp
!=====

 write(stdout,*) 'Calculate Hartree term with Resolution-of-Identity: SCALAPACK buffer'
 call start_clock(timing_hartree)


 !
 ! First the buffer contains the density matrix p_matrix
 buffer(:,:) = 0.0_dp

 call broadcast_hamiltonian_sca(m_ham,n_ham,p_matrix(:,:,1))
 if( nspin == 2 ) then
   call broadcast_hamiltonian_sca(m_ham,n_ham,p_matrix(:,:,2))
 endif

 allocate(partial_sum(nauxil_3center))

 partial_sum(:) = 0.0_dp
 do ipair=1,npair
   kbf = index_basis(1,ipair)
   lbf = index_basis(2,ipair)
   ! Factor 2 comes from the symmetry of p_matrix
   partial_sum(:) = partial_sum(:) + eri_3center(:,ipair) * buffer(kbf,lbf) * 2.0_dp
   ! Then diagonal terms have been counted twice and should be removed once.
   if( kbf == lbf ) &
     partial_sum(:) = partial_sum(:) - eri_3center(:,ipair) * buffer(kbf,kbf)
 enddo


 ! Hartree potential is not sensitive to spin
 buffer(:,:) = 0.0_dp
 do ipair=1,npair
   ibf = index_basis(1,ipair)
   jbf = index_basis(2,ipair)
   rtmp = DOT_PRODUCT( eri_3center(:,ipair) , partial_sum(:) )
   buffer(ibf,jbf) = rtmp
   buffer(jbf,ibf) = rtmp
 enddo

 deallocate(partial_sum)

 ! Sum up the buffers and store the result in the sub matrix exchange_ij
 call reduce_hamiltonian_sca(m_ham,n_ham,hartree_ij)

 !
 ! Calculate the Hartree energy
 if( cntxt_ham > 0 ) then
   ehartree = 0.5_dp*SUM(hartree_ij(:,:) * SUM(p_matrix(:,:,:),DIM=3) )
 else
   ehartree = 0.0_dp
 endif
 call xsum(ehartree)


 call stop_clock(timing_hartree)


end subroutine setup_hartree_ri_buffer_sca


!=========================================================================
subroutine setup_exchange_ri_buffer_sca(print_matrix_,nbf,m_ham,n_ham,p_matrix_occ,p_matrix_sqrt,p_matrix,exchange_ij,eexchange)
 use m_eri
 implicit none
 logical,intent(in)   :: print_matrix_
 integer,intent(in)   :: nbf,m_ham,n_ham
 real(dp),intent(in)  :: p_matrix_occ(nbf,nspin)
 real(dp),intent(in)  :: p_matrix_sqrt(m_ham,n_ham,nspin)
 real(dp),intent(in)  :: p_matrix(m_ham,n_ham,nspin)
 real(dp),intent(out) :: exchange_ij(m_ham,n_ham,nspin)
 real(dp),intent(out) :: eexchange
!=====
 integer              :: ibf,jbf,ispin,istate
 real(dp),allocatable :: tmp(:,:)
 real(dp)             :: eigval(nbf)
 integer              :: ipair
 real(dp)             :: p_matrix_i(nbf)
 integer              :: iglobal,ilocal,jlocal
!=====


 write(stdout,*) 'Calculate Exchange term with Resolution-of-Identity: SCALAPACK buffer'
 call start_clock(timing_exchange)



 allocate(tmp(nauxil_3center,nbf))

 do ispin=1,nspin

   buffer(:,:) = 0.0_dp

   do istate=1,nbf
     if( p_matrix_occ(istate,ispin) < completely_empty ) cycle

     !
     ! First all processors must have the p_matrix for (istate, ispin)
     p_matrix_i(:) = 0.0_dp
     if( cntxt_ham > 0 ) then
       jlocal = colindex_global_to_local('H',istate)
       if( jlocal /= 0 ) then
         do ilocal=1,m_ham
           iglobal = rowindex_local_to_global('H',ilocal)
           p_matrix_i(iglobal) = p_matrix_sqrt(ilocal,jlocal,ispin) 
         enddo
       endif
     endif
     call xsum(p_matrix_i)


     tmp(:,:) = 0.0_dp
     do ipair=1,npair
       ibf = index_basis(1,ipair)
       jbf = index_basis(2,ipair)

       tmp(:,ibf) = tmp(:,ibf) + p_matrix_i(jbf) * eri_3center(:,ipair)
       if( ibf /= jbf ) &
            tmp(:,jbf) = tmp(:,jbf) + p_matrix_i(ibf) * eri_3center(:,ipair)
     enddo

     buffer(:,:) = buffer(:,:) - MATMUL( TRANSPOSE(tmp(:,:)) , tmp(:,:) ) / spin_fact

   enddo

   ! Sum up the buffers and store the result in the sub matrix exchange_ij
   call reduce_hamiltonian_sca(m_ham,n_ham,exchange_ij(:,:,ispin))

 enddo
 deallocate(tmp)


 !
 ! Calculate the exchange energy
 if( cntxt_ham > 0 ) then
   eexchange = 0.5_dp * SUM( exchange_ij(:,:,:) * p_matrix(:,:,:) )
 else
   eexchange = 0.0_dp
 endif
 call xsum(eexchange)

 call stop_clock(timing_exchange)



end subroutine setup_exchange_ri_buffer_sca


!=========================================================================
subroutine dft_exc_vxc_buffer_sca(nstate,m_ham,n_ham,basis,p_matrix_occ,p_matrix_sqrt,p_matrix,vxc_ij,exc_xc)
 use,intrinsic ::  iso_c_binding, only: C_INT,C_DOUBLE
 use m_inputparam
 use m_basis_set
 use m_dft_grid
#ifdef HAVE_LIBXC
 use libxc_funcs_m
 use xc_f90_lib_m
 use xc_f90_types_m
#endif
 implicit none

 integer,intent(in)         :: nstate
 integer,intent(in)         :: m_ham,n_ham
 type(basis_set),intent(in) :: basis
 real(dp),intent(in)        :: p_matrix_occ(basis%nbf,nspin)
 real(dp),intent(in)        :: p_matrix_sqrt(m_ham,n_ham,nspin)
 real(dp),intent(in)        :: p_matrix(m_ham,n_ham,nspin)
 real(dp),intent(out)       :: vxc_ij(m_ham,n_ham,nspin)
 real(dp),intent(out)       :: exc_xc
!=====

 real(dp),parameter :: TOL_RHO=1.0e-10_dp
 integer  :: idft_xc
 logical  :: require_gradient,require_laplacian
 integer  :: igrid,ibf,jbf,ispin
 real(dp) :: rr(3)
 real(dp) :: normalization(nspin)
 real(dp) :: weight

#ifdef HAVE_LIBXC
 type(xc_f90_pointer_t) :: xc_func(ndft_xc),xc_functest
 type(xc_f90_pointer_t) :: xc_info(ndft_xc),xc_infotest
#endif

 real(dp)             :: basis_function_r(basis%nbf)
 real(dp)             :: basis_function_gradr(3,basis%nbf)
 real(dp)             :: basis_function_laplr(3,basis%nbf)

 real(dp)             :: rhor(nspin,ngrid)
 real(dp)             :: grad_rhor(3,nspin,ngrid)
 real(dp)             :: sigma(2*nspin-1)
 real(dp)             :: tau(nspin),lapl_rhor(nspin)
 real(dp)             :: vxc_libxc(nspin)
 real(dp)             :: vxc_dummy(nspin)
 real(dp)             :: exc_libxc(1)
 real(dp)             :: vsigma(2*nspin-1)
 real(dp)             :: vlapl_rho(nspin),vtau(nspin)
 real(dp)             :: vxc_av(nspin)
 real(dp)             :: dedd_r(nspin)
 real(dp)             :: dedgd_r(3,nspin)
 real(dp)             :: omega
 character(len=256)   :: string
!=====

 if( nspin/=1 ) call die('DFT XC potential: SCALAPACK buffer not implemented for spin unrestricted')

 exc_xc = 0.0_dp
 vxc_ij(:,:,:) = 0.0_dp
 if( ndft_xc == 0 ) return

 call start_clock(timing_dft)


#ifdef HAVE_LIBXC

 write(stdout,*) 'Calculate DFT XC potential: SCALAPACK buffer'
 
 require_gradient =.FALSE.
 require_laplacian=.FALSE.
 do idft_xc=1,ndft_xc

   if( dft_xc_type(idft_xc) < 1000 ) then
     if(nspin==1) then
       call xc_f90_func_init(xc_func(idft_xc), xc_info(idft_xc), dft_xc_type(idft_xc), XC_UNPOLARIZED)
     else
       call xc_f90_func_init(xc_func(idft_xc), xc_info(idft_xc), dft_xc_type(idft_xc), XC_POLARIZED)
     endif
   else if(dft_xc_type(idft_xc) < 2000) then
     write(stdout,*) 'Home-made functional LDA functional'
     ! Fake LIBXC descriptor 
     if(nspin==1) then
       call xc_f90_func_init(xc_func(idft_xc), xc_info(idft_xc), XC_LDA_X, XC_UNPOLARIZED)
     else
       call xc_f90_func_init(xc_func(idft_xc), xc_info(idft_xc), XC_LDA_X, XC_POLARIZED)
     endif
   else
     write(stdout,*) 'Home-made functional GGA functional'
     ! Fake LIBXC descriptor 
     if(nspin==1) then
       call xc_f90_func_init(xc_func(idft_xc), xc_info(idft_xc), XC_GGA_X_PBE, XC_UNPOLARIZED)
     else
       call xc_f90_func_init(xc_func(idft_xc), xc_info(idft_xc), XC_GGA_X_PBE, XC_POLARIZED)
    endif
   endif

   if( dft_xc_type(idft_xc) < 1000 ) then
     call xc_f90_info_name(xc_info(idft_xc),string)
     write(stdout,'(a,i4,a,i6,5x,a)') '   XC functional ',idft_xc,' :  ',xc_f90_info_number(xc_info(idft_xc)),TRIM(string)
   else
     write(stdout,'(a,i4,a,i6,5x,a)') '   XC functional ',idft_xc,' :  ',xc_f90_info_number(xc_info(idft_xc)),'FAKE LIBXC DESCRIPTOR'
   endif

   if(xc_f90_info_family(xc_info(idft_xc)) == XC_FAMILY_GGA     ) require_gradient  =.TRUE.
   if(xc_f90_info_family(xc_info(idft_xc)) == XC_FAMILY_HYB_GGA ) require_gradient  =.TRUE.
   if(xc_f90_info_family(xc_info(idft_xc)) == XC_FAMILY_MGGA    ) require_laplacian =.TRUE.

   if( dft_xc_type(idft_xc) == XC_GGA_X_HJS_PBE ) then
     call xc_f90_gga_x_hjs_set_par(xc_func(idft_xc), REAL(gamma_hybrid,C_DOUBLE) )
   endif
   if( dft_xc_type(idft_xc) == XC_GGA_X_WPBEH ) then
     call xc_f90_gga_x_wpbeh_set_par(xc_func(idft_xc), REAL(gamma_hybrid,C_DOUBLE) )
   endif

 enddo

 if( require_laplacian ) call die('meta-GGA not implemented in SCALAPACK buffer')


 !
 ! If it is the first time, then set up the stored arrays
 !
 if( .NOT. ALLOCATED(bfr) )                          call prepare_basis_functions_r(basis)
 if( require_gradient  .AND. .NOT. ALLOCATED(bfgr) ) call prepare_basis_functions_gradr(basis)
 if( require_laplacian .AND. .NOT. ALLOCATED(bfgr) ) call prepare_basis_functions_laplr(basis)

 normalization(:)=0.0_dp


 do ispin=1,nspin
   !
   ! Buffer constains the p_matrix_sqrt for a spin channel ispin
   buffer(:,:) = 0.0_dp
   call broadcast_hamiltonian_sca(m_ham,n_ham,p_matrix_sqrt(:,:,ispin))

   do igrid=1,ngrid

     rr(:) = rr_grid(:,igrid)
     weight = w_grid(igrid)

     !
     ! Get all the functions at point rr
     call get_basis_functions_r(basis,igrid,basis_function_r)
     !
     ! calculate the density at point r for spin up and spin down
     call calc_density_r(1,basis,p_matrix_occ(:,ispin),buffer,rr,basis_function_r,rhor(ispin,igrid))

     ! Skip all the rest if the density is too small
     if( rhor(ispin,igrid) < TOL_RHO ) cycle

     if( require_gradient ) then
       call get_basis_functions_gradr(basis,igrid,basis_function_gradr)
     endif

     !
     ! Normalization
     normalization(ispin) = normalization(ispin) + rhor(ispin,igrid) * weight


     if( require_gradient ) then 
       call calc_density_gradr(1,basis%nbf,p_matrix_occ(:,ispin),buffer,basis_function_r,basis_function_gradr,grad_rhor(:,ispin,igrid))
     endif

   enddo
 enddo


 do ispin=1,nspin

   !
   ! buffer now contains the vxc_ij
   buffer(:,:) = 0.0_dp

   do igrid=1,ngrid

     rr(:) = rr_grid(:,igrid)
     weight = w_grid(igrid)

     if( require_gradient .OR. require_laplacian ) then
       sigma(1) = SUM( grad_rhor(:,1,igrid)**2 )
       if(nspin==2) then
         sigma(2) = SUM( grad_rhor(:,1,igrid) * grad_rhor(:,2,igrid) )
         sigma(3) = SUM( grad_rhor(:,2,igrid)**2 )
       endif
     endif

     !
     ! LIBXC calls
     !
     dedd_r(:)    = 0.0_dp
     dedgd_r(:,:) = 0.0_dp

     do idft_xc=1,ndft_xc

       select case(xc_f90_info_family(xc_info(idft_xc)))

       case(XC_FAMILY_LDA)
         if( dft_xc_type(idft_xc) < 1000 ) then 
           call xc_f90_lda_exc_vxc(xc_func(idft_xc),1_C_INT,rhor(1,igrid),exc_libxc(1),vxc_libxc(1))
         else
           call my_lda_exc_vxc(nspin,dft_xc_type(idft_xc),rhor(:,igrid),exc_libxc(1),vxc_libxc)
         endif

       case(XC_FAMILY_GGA,XC_FAMILY_HYB_GGA)
         if( dft_xc_type(idft_xc) < 2000 ) then 
           !
           ! Remove too small densities to stabilize the computation
           ! especially useful for Becke88
           if( ANY( rhor(:,igrid) > 1.0e-9_dp ) ) then
             call xc_f90_gga_exc_vxc(xc_func(idft_xc),1_C_INT,rhor(1,igrid),sigma(1),exc_libxc(1),vxc_libxc(1),vsigma(1))
           else
             exc_libxc(:)     = 0.0_dp
             vxc_libxc(:)     = 0.0_dp
             vsigma(:)        = 0.0_dp
           endif
         else
           call my_gga_exc_vxc_hjs(gamma_hybrid,rhor(1,igrid),sigma(1),exc_libxc(1),vxc_libxc(1),vsigma(1))
         endif

       case default
         call die('functional is not LDA nor GGA nor hybrid nor meta-GGA')
       end select

       exc_xc = exc_xc + weight * exc_libxc(1) * rhor(ispin,igrid) * dft_xc_coef(idft_xc)

       dedd_r(:) = dedd_r(:) + vxc_libxc(:) * dft_xc_coef(idft_xc)

       !
       ! Set up divergence term if needed (GGA case)
       !
       if( xc_f90_info_family(xc_info(idft_xc)) == XC_FAMILY_GGA &
          .OR. xc_f90_info_family(xc_info(idft_xc)) == XC_FAMILY_HYB_GGA ) then
         if(nspin==1) then

           dedgd_r(:,1) = dedgd_r(:,1) + 2.0_dp * vsigma(1) * grad_rhor(:,1,igrid) * dft_xc_coef(idft_xc)

         else

           dedgd_r(:,1) = dedgd_r(:,1) + 2.0_dp * vsigma(1) * grad_rhor(:,1,igrid) * dft_xc_coef(idft_xc) &
                                 + vsigma(2) * grad_rhor(:,2,igrid)

           dedgd_r(:,2) = dedgd_r(:,2) + 2.0_dp * vsigma(3) * grad_rhor(:,2,igrid) * dft_xc_coef(idft_xc) &
                                 + vsigma(2) * grad_rhor(:,1,igrid)
         endif

       endif


     enddo ! loop on the XC functional


     !
     ! Get all the functions at point rr
     call get_basis_functions_r(basis,igrid,basis_function_r)
     if( require_gradient ) then
       call get_basis_functions_gradr(basis,igrid,basis_function_gradr)
     endif

     !
     ! Eventually set up the vxc term
     !
     if( .NOT. require_gradient ) then 
       ! LDA
       do jbf=1,basis%nbf
         ! Only the lower part is calculated
         do ibf=1,jbf ! basis%nbf 
           buffer(ibf,jbf) =  buffer(ibf,jbf) + weight &
               *  dedd_r(ispin) * basis_function_r(ibf) * basis_function_r(jbf) 
         enddo
       enddo

     else 
       ! GGA
       do jbf=1,basis%nbf
         ! Only the lower part is calculated
         do ibf=1,jbf ! basis%nbf 
           buffer(ibf,jbf) = buffer(ibf,jbf) +  weight                    &
                     * (  dedd_r(ispin) * basis_function_r(ibf) * basis_function_r(jbf)    &
                     * DOT_PRODUCT( dedgd_r(:,ispin) ,                                     &
                                       basis_function_gradr(:,ibf) * basis_function_r(jbf) &
                                     + basis_function_gradr(:,jbf) * basis_function_r(ibf) ) )
         enddo
       enddo
     endif

   enddo ! loop on the grid point

   ! Symmetrize now
   do jbf=1,basis%nbf
     do ibf=1,jbf-1
       buffer(jbf,ibf) = buffer(ibf,jbf)
     enddo
   enddo

   call reduce_hamiltonian_sca(m_ham,n_ham,vxc_ij(:,:,ispin))


 enddo

 !
 ! Sum up the contributions from all procs only if needed
 if( parallel_grid ) then
   call xsum(normalization)
   call xsum(exc_xc)
 endif

 !
 ! Destroy operations
 do idft_xc=1,ndft_xc
   call xc_f90_func_end(xc_func(idft_xc))
 enddo

#else
 write(stdout,*) 'XC energy and potential set to zero'
 write(stdout,*) 'LIBXC is not present'
#endif

 write(stdout,'(/,a,2(2x,f12.6))') ' Number of electrons:',normalization(:)
 write(stdout,'(a,2x,f12.6,/)')    '  DFT xc energy (Ha):',exc_xc

 call stop_clock(timing_dft)

end subroutine dft_exc_vxc_buffer_sca


!=========================================================================
!=========================================================================
end module m_hamiltonian_dist
!=========================================================================