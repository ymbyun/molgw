!=========================================================================
! This file is part of MOLGW.
! Author: Ivan Maliyov
!
! This module contains
! propagation of the wavefunction in time
!
!=========================================================================
module m_tddft_propagator
 use m_atoms
 use m_definitions
 use m_basis_set
 use m_scf_loop
 use m_memory
 use m_hamiltonian
 use m_hamiltonian_sca
 use m_hamiltonian_onebody
 use m_hamiltonian_buffer
 use m_hamiltonian_cmplx
 use m_inputparam
 use m_dft_grid
 use m_tools
 use m_scf
 use m_warning
 use m_tddft_variables
 use m_timing

 interface propagate_orth
  module procedure propagate_orth_ham_1
  module procedure propagate_orth_ham_2
 end interface propagate_orth

 interface print_2d_matrix
  module procedure print_2d_matrix_real
  module procedure print_2d_matrix_cmplx
 end interface print_2d_matrix

 !integer,private :: unit_cube  
 real(dp),private                   :: time_read
 real(dp),allocatable,private       :: xatom_start(:,:)
 complex(dp),private                :: m_excit_field_dir
 integer,private                    :: nocc

contains


!=========================================================================
subroutine calculate_propagation(nstate,              &
                                 basis,               &
                                 occupation,          &
                                 c_matrix)
 implicit none

 type(basis_set),intent(in)      :: basis
 integer,intent(in)              :: nstate
 real(dp),intent(in)             :: c_matrix(basis%nbf,nstate,nspin)
 real(dp),intent(in)             :: occupation(nstate,nspin)
!=====
 integer,parameter          :: BATCH_SIZE=64
 integer                    :: ntau, ispin 
 integer                    :: istate, nstate_tmp
 integer                    :: nwrite_step 
 real(dp)                   :: time_min
 real(dp),allocatable       :: dipole_basis(:,:,:)
 real(dp),allocatable       :: s_matrix(:,:)
 real(dp),allocatable       :: s_matrix_sqrt_inv(:,:)
 real(dp),allocatable       :: hamiltonian_kinetic(:,:)
 real(dp),allocatable       :: hamiltonian_nucleus(:,:)
!===== variables for the calc_p_matrix_error
 logical                    :: calc_p_matrix_error_=.false.
 integer                    :: mod_write 
!=====initial values
 real(dp),allocatable       :: energies_inst(:)
 complex(dp),allocatable    :: c_matrix_cmplx(:,:,:)
 complex(dp),allocatable    :: c_matrix_orth_cmplx(:,:,:)
 complex(dp),allocatable    :: hamiltonian_fock_cmplx(:,:,:)
 complex(dp),allocatable    :: h_small_cmplx(:,:,:)
!=====TDDFT loop variables=============================
 integer                    :: itau 
 integer                    :: i_iter, iwrite_step
 integer                    :: file_time_data, file_excit_field
 integer                    :: file_dipole_time,file_iter_norm ! keep this var
 real(dp)                   :: time_cur, time_one_iter
 real(dp)                   :: dipole(3)
 complex(dp),allocatable    :: p_matrix_cmplx(:,:,:)
 complex(dp),allocatable    :: h_small_hist_cmplx(:,:,:,:)
 complex(dp),allocatable    :: c_matrix_orth_hist_cmplx(:,:,:,:)
 logical                    :: is_identity_ ! keep this varibale
!==variables for extrapolation
 integer                    :: iextr,ham_dim_cur
 real(dp),allocatable       :: m_nods(:)
 real(dp),allocatable       :: extrap_coefs(:)
 real(dp)                   :: x_pred
!==cube_diff varibales===
 real(dp),allocatable       :: cube_density_start(:,:,:,:)
 integer                    :: nx,ny,nz,unit_cube_diff
 logical                    :: file_exists
!==qmatrix==
 integer,allocatable        :: istate_cut(:)
 integer                    :: file_q_matrix(2)
 integer                    :: iocc
 complex(dp),allocatable    :: q_matrix_cmplx(:,:,:)
 real(dp)                   :: q_occ(10)
 complex(dp),allocatable    :: c_matrix_orth_start_complete_cmplx(:,:,:)
!=====

 write(stdout,'(/,/,1x,a)') '=================================================='
 write(stdout,'(x,a,/)')    'RT-TDDFT simulation'

 call clean_allocate('Overlap matrix S for TDDFT',s_matrix,basis%nbf,basis%nbf)
 call clean_allocate('Kinetic operator T for TDDFT',hamiltonian_kinetic,basis%nbf,basis%nbf)
 call clean_allocate('Nucleus operator V for TDDFT',hamiltonian_nucleus,basis%nbf,basis%nbf)

 call setup_overlap(basis,s_matrix)

 ! s_matrix_sqrt_inv is now allocated with dimension (basis%nbf,nstate))
 call setup_sqrt_overlap(min_overlap,s_matrix,nstate_tmp,s_matrix_sqrt_inv)
 if(nstate/=nstate_tmp) then
   call die('Error with nstate in the TDDFT propagator')
 end if

 call setup_kinetic(basis,hamiltonian_kinetic)

 call setup_nucleus(basis,hamiltonian_nucleus)

 if( nelement_ecp > 0 ) then
   call setup_nucleus_ecp(basis,hamiltonian_nucleus)
 endif

 if(write_step / time_step - NINT( write_step / time_step ) > 0.0E-10_dp .OR. write_step < time_step ) then
   call die("Tddft error: write_step is not a multiple of time_step or smaller than time_step.")
 end if
 mod_write = NINT( write_step / time_step ) ! write each write_step, assumed that time_step <= write_step

 if( calc_type%is_dft ) then
    call init_dft_grid(basis,grid_level,dft_xc_needs_gradient,.TRUE.,BATCH_SIZE)
 endif

 nocc=0
 do ispin=1,nspin
   do istate=1,nstate
     if( occupation(istate,ispin) < completely_empty ) cycle
     if( istate > nocc ) nocc = istate
   enddo
 end do

 call clean_allocate('Wavefunctions C for TDDFT',c_matrix_cmplx,basis%nbf,nocc,nspin)
 call clean_allocate('Wavefunctions hist. C for TDDFT',c_matrix_orth_cmplx,nstate,nocc,nspin)
 call clean_allocate('Hamiltonian Fock for TDDFT',hamiltonian_fock_cmplx,basis%nbf,basis%nbf,nspin)
 call clean_allocate('h_small_start for TDDFT',h_small_cmplx,nstate,nstate,nspin)
 call clean_allocate('p_matrix_cmplx for TDDFT',p_matrix_cmplx,basis%nbf,basis%nbf,nspin)

 allocate(xatom_start(3,natom))

 !===INITIAL CONDITIONS===
 ! Getting c_matrix_cmplx(t=0) whether using RESTART_TDDFT file, whether using real c_matrix
 if( read_tddft_restart_ .AND. restart_tddft_is_correct ) then
   ! assign xatom_start, c_matrix_orth_cmplx, time_min with values given in RESTART File
   call read_restart_tddft(nstate,time_read,c_matrix_orth_cmplx)
   time_min = time_read
   do ispin=1,nspin
     c_matrix_cmplx(:,:,ispin) = MATMUL( s_matrix_sqrt_inv(:,:) , c_matrix_orth_cmplx(:,:,ispin) )
   end do
   xatom=xatom_start
 else
   c_matrix_cmplx(:,:,:) = c_matrix(:,1:nocc,:)
   xatom_start=xatom
   time_min=0.0_dp
 end if

 ! Getting starting value of the Hamiltonian
 ! itau=0 to avoid excitation calculation
 call setup_hamiltonian_fock_cmplx( basis,                   &
                                    nstate,                  &
                                    0,                       &    ! itau
                                    time_min,                &
                                    0.0_dp,                  &    ! time_cur
                                    occupation,              &
                                    c_matrix_cmplx,          &
                                    hamiltonian_kinetic,     &
                                    hamiltonian_nucleus,     &
                                    h_small_cmplx,           &
                                    s_matrix_sqrt_inv,       &
                                    dipole_basis,            &
                                    hamiltonian_fock_cmplx)

 ! In case of no restart, find the c_matrix_orth_cmplx by diagonalizing h_small
 if( (.NOT. read_tddft_restart_) .OR. (.NOT. restart_tddft_is_correct)) then
   call clean_allocate('c_matrix_buf for TDDFT',c_matrix_orth_start_complete_cmplx,nstate,nstate,nspin)
   allocate(energies_inst(nstate))
   do ispin=1, nspin
     call diagonalize(h_small_cmplx(:,:,ispin),energies_inst,c_matrix_orth_start_complete_cmplx(:,:,ispin))
   end do
   ! in order to save the memory, we dont keep inoccupied states (nocc+1:nstate)
   c_matrix_orth_cmplx(1:nstate,1:nocc,1:nspin)=c_matrix_orth_start_complete_cmplx(1:nstate,1:nocc,1:nspin)
   call clean_deallocate('c_matrix_buf for TDDFT',c_matrix_orth_start_complete_cmplx)
   deallocate(energies_inst)
 end if

 ! Number of iterations
 ntau=NINT((time_sim-time_min)/time_step)
 nwrite_step=NINT((time_sim - time_min)/write_step)
 mod_write = NINT( write_step / time_step )

 if(excit_type%is_light) then
   call clean_allocate('Dipole_basis for TDDFT',dipole_basis,basis%nbf,basis%nbf,3)
   call calculate_dipole_basis(basis,dipole_basis)
 end if

 if( print_dens_traj_tddft_ ) then
   call plot_rho_traj_bunch_cmplx(nstate,nocc,basis,occupation,c_matrix_cmplx,0,0.d0)
 end if

 call start_clock(timing_tddft_loop)

 if( calc_q_matrix_ ) then
   call initialize_q(nstate,nocc,nspin,q_matrix_cmplx,c_matrix_orth_start_complete_cmplx,h_small_cmplx,istate_cut,file_q_matrix)
 end if

!===cube_diff matrix allocation and parameters initialization
 if(print_cube_diff_tddft_) then
   call initialize_cube_diff_cmplx(nx,ny,nz,unit_cube_diff)
   allocate(cube_density_start(nx,ny,nz,nspin))
 end if

 time_min=time_read
 !OPENING FILES
 ! FBFB move this fucking shit into another fucking place
 if( is_iomaster ) then
   open(newunit=file_time_data,file="time_data.dat")
   if(excit_type%is_light) then
     open(newunit=file_dipole_time,file="dipole_time.dat")
     open(newunit=file_excit_field,file="excitation_time.dat")


     write(file_excit_field,"(A)") "# time(au)                      E_field_excit_dir(au)"
     write(file_excit_field,*) time_min, REAL(m_excit_field_dir)
   end if

   if(excit_type%is_projectile) then
     write(file_time_data,"(A)") "  # time(au)     e_total        z_projectile        enuc_nuc            enuc             ekin              ehart&
                               &           eexx_hyb            exc"
   end if
   if(excit_type%is_light) then
     write(file_time_data,"(A)") " # time(au)     e_total             enuc_nuc             enuc            ekin               ehart            &
                               &eexx_hyb            exc             eexcit"
   end if
   if(excit_type%is_light) write(file_dipole_time,"(A)") "# time(au)                      Dipole_x(D)               Dipole_y(D)               Dipole_z(D)"
 end if

 !
 ! Printing initial values of energy and dipole taken from SCF or RESTART_TDDFT
 en%tot = en%nuc + en%kin + en%nuc_nuc + en%hart + en%exx_hyb + en%xc + en%excit

 if(excit_type%is_light) then
   call setup_density_matrix_cmplx(basis%nbf,nstate,nocc,c_matrix_cmplx,occupation,p_matrix_cmplx)
   call static_dipole_fast_cmplx(basis,p_matrix_cmplx,dipole_basis,dipole)
 endif

 if( is_iomaster ) then
 ! Here time_min point coresponds to the end of calculation written in the RESTART_TDDFT or to 0 a.u.
   if( print_cube_rho_tddft_ ) call plot_cube_wfn_cmplx(nstate,nocc,basis,occupation,c_matrix_cmplx,0)
   if( print_cube_diff_tddft_ ) then
     call calc_cube_initial_cmplx(nstate,nocc,basis,occupation,c_matrix_cmplx,cube_density_start,nx,ny,nz)
     call plot_cube_diff_cmplx(nstate,nocc,basis,occupation,c_matrix_cmplx,0,cube_density_start,nx,ny,nz)
   end if
   if( print_line_rho_tddft_ ) call plot_rho_cmplx(nstate,nocc,basis,occupation,c_matrix_cmplx,0,time_min)
   if(excit_type%is_projectile) then
     write(file_time_data,"(F9.4,8(2x,es16.8E3))") &
      time_min, en%tot, xatom(3,natom), en%nuc_nuc, en%nuc, en%kin, en%hart, en%exx_hyb, en%xc
   end if
   if(excit_type%is_light) then
     write(file_time_data,"(F9.4,8(2x,es16.8E3))") &
      time_min, en%tot, en%nuc_nuc, en%nuc, en%kin, en%hart, en%exx_hyb, en%xc, en%excit
   end if
   write(stdout,*)
   write(stdout,'(a31,1x,f19.10)') 'RT-TDDFT Simulation time (au):', time_min
   write(stdout,'(a31,1x,f19.10)') 'RT-TDDFT Total Energy    (Ha):', en%tot

   if(excit_type%is_light) then
     write(file_dipole_time,'(4f19.10)') time_min, dipole(:) * au_debye
     write(stdout,'(a31,1x,3f19.10)') 'RT-TDDFT Dipole Moment    (D):', dipole(:) * au_debye
   end if
   if(excit_type%is_projectile) call output_projectile_position()
 end if

 time_min=time_min+time_step

 if(pred_corr /= 'PC0' ) then

   allocate(m_nods(n_hist),extrap_coefs(n_hist))

   if(pred_corr=='PC1') then
     ham_dim_cur=2
   end if

   if(pred_corr=='PC2B') then
     ham_dim_cur=n_hist
     do iextr=1,n_hist
       m_nods(iextr)=(iextr-1.0_dp)*0.5_dp
     end do
     x_pred=(n_hist-1.0_dp)*0.5_dp+0.25_dp
     call get_extrap_coefs_lagr(m_nods,x_pred,extrap_coefs,n_hist)
   end if

   if(pred_corr=='PC3' .OR. pred_corr=='PC4') then
     ham_dim_cur=n_hist+2
     do iextr=1,n_hist
       m_nods(iextr)=iextr-1.0_dp
     end do
     x_pred=n_hist
     if(pred_corr=='PC3') call get_extrap_coefs_lagr(m_nods,x_pred,extrap_coefs,n_hist)
     if(pred_corr=='PC4') call get_extrap_coefs_aspc(extrap_coefs,n_hist)
   end if

   if(pred_corr=='PC5' .OR. pred_corr=='PC6') then
     ham_dim_cur=n_hist+1
     do iextr=1,n_hist
       m_nods(iextr)=iextr-1.0_dp
     end do
     x_pred=n_hist
     if(pred_corr=='PC5') call get_extrap_coefs_lagr(m_nods,x_pred,extrap_coefs,n_hist)
     if(pred_corr=='PC6') call get_extrap_coefs_aspc(extrap_coefs,n_hist)
   end if

   if(pred_corr=='PC7' ) then
     ham_dim_cur=2
   end if

   call clean_allocate('h_small_hist_cmplx for TDDFT',h_small_hist_cmplx,nstate,nstate,nspin,ham_dim_cur)
   call clean_allocate('c_matrix_orth_hist_cmplx for TDDFT',c_matrix_orth_hist_cmplx,nstate,nocc,nspin,1)
   do iextr=1,ham_dim_cur
     h_small_hist_cmplx(:,:,:,iextr)=h_small_cmplx(:,:,:)
   end do
   c_matrix_orth_hist_cmplx(:,:,:,1)=c_matrix_orth_cmplx(:,:,:)
   m_nods(:)=0.0_dp
 end if
!===END INITIAL CONDITIONS===

!********start time loop*************
! write(stdout,"(1x,a)") "--------------------------------------------------------"
! write(stdout,"(1x,a,I5)") "Start of the tddft loop, number of iterations: ",ntau
! write(stdout,"(1x,a)") "--------------------------------------------------------"

 time_cur=time_min
 iwrite_step = 1
 itau = 1
 in_tddft_loop=.TRUE.
 do while ( (time_cur - time_sim) < 1.0e-10 )
   if(itau==3) call start_clock(timing_tddft_one_iter)

   if(pred_corr=='PC0') then
     call propagate_orth(nstate,basis,time_step,c_matrix_orth_cmplx,c_matrix_cmplx,h_small_cmplx,s_matrix_sqrt_inv,prop_type)
     call setup_hamiltonian_fock_cmplx( basis,                   &
                                        nstate,                  &
                                        itau,                    &
                                        time_cur,                &
                                        time_step,           &
                                        occupation,              &
                                        c_matrix_cmplx,          &
                                        hamiltonian_kinetic,     &
                                        hamiltonian_nucleus,     &
                                        h_small_cmplx,           &
                                        s_matrix_sqrt_inv,       &
                                        dipole_basis,            &
                                        hamiltonian_fock_cmplx)
   end if

   ! ///////////////////////////////////
   ! Following Van Voorhis, Phys Rev B 74 (2006)
   if(pred_corr=='PC1') then
     !--1--PREDICTOR----| H(2/4),H(6/4)-->H(9/4)
         h_small_cmplx= -3.0_dp/4.0_dp*h_small_hist_cmplx(:,:,:,1)+7.0_dp/4.0_dp*h_small_hist_cmplx(:,:,:,2)
     !--2--PREDICTOR----| C(8/4)---U[H(9/4)]--->C(10/4)
     call propagate_orth(nstate,basis,time_step/2.0_dp,c_matrix_orth_hist_cmplx(:,:,:,1),c_matrix_cmplx,h_small_cmplx,s_matrix_sqrt_inv,prop_type)

     !--3--CORRECTOR----| C(10/4)-->H(10/4)
     call setup_hamiltonian_fock_cmplx( basis,                   &
                                        nstate,                  &
                                        itau,                    &
                                        time_cur-time_step/2.0_dp, &
                                        time_step,           &
                                        occupation,              &
                                        c_matrix_cmplx,          &
                                        hamiltonian_kinetic,     &
                                        hamiltonian_nucleus,     &
                                        h_small_cmplx,           &
                                        s_matrix_sqrt_inv,       &
                                        dipole_basis,            &
                                        hamiltonian_fock_cmplx)

     !--4--PROPAGATION----| C(8/4)---U[H(10/4)]--->C(12/4)
     call propagate_orth(nstate,basis,time_step,c_matrix_orth_cmplx,c_matrix_cmplx,h_small_cmplx,s_matrix_sqrt_inv,prop_type)

     !--5--UPDATE----| C(12/4)-->C(8/4); H(6/4)-->H(2/4); H(10/4)-->H(6/4)
     c_matrix_orth_hist_cmplx(:,:,:,1)=c_matrix_orth_cmplx(:,:,:)
     h_small_hist_cmplx(:,:,:,1)=h_small_hist_cmplx(:,:,:,2)
     h_small_hist_cmplx(:,:,:,2)=h_small_cmplx(:,:,:)
   end if

   ! ///////////////////////////////////

   if(pred_corr=='PC2B') then
     h_small_cmplx=(0.0_dp,0.0_dp)
     !--0--EXTRAPOLATE----
     do iextr=1,n_hist
       h_small_cmplx=h_small_cmplx+extrap_coefs(iextr)*h_small_hist_cmplx(:,:,:,iextr)
     end do
     ! n_hist-2  <---  n_hist; n_hist-3 <-- n_hist-1
     if(n_hist > 2) then
       do iextr=1,n_hist-2
         h_small_hist_cmplx(:,:,:,iextr)=h_small_hist_cmplx(:,:,:,iextr+2)
       end do
     end if

     !--1--PROPAGATE----| C(t)--U[H(1/4dt)]-->C(t+dt/2)
     call propagate_orth(nstate,basis,time_step/2.0_dp,c_matrix_orth_hist_cmplx(:,:,:,1),c_matrix_cmplx,h_small_cmplx,s_matrix_sqrt_inv,prop_type)
     !--2--CALCULATE- H(t+dt/4)
     call setup_hamiltonian_fock_cmplx( basis,                   &
                                        nstate,                  &
                                        itau,                    &
                                        time_cur-time_step/2.0_dp, &
                                        time_step,           &
                                        occupation,              &
                                        c_matrix_cmplx,          &
                                        hamiltonian_kinetic,     &
                                        hamiltonian_nucleus,     &
                                        h_small_cmplx,           &
                                        s_matrix_sqrt_inv,       &
                                        dipole_basis,            &
                                        hamiltonian_fock_cmplx)

     if (n_hist > 1) h_small_hist_cmplx(:,:,:,n_hist-1)=h_small_cmplx
     !--3--PROPAGATION----|
     call propagate_orth(nstate,basis,time_step,c_matrix_orth_cmplx,c_matrix_cmplx,h_small_cmplx,s_matrix_sqrt_inv,prop_type)

     call setup_hamiltonian_fock_cmplx( basis,                   &
                                        nstate,                  &
                                        itau,                    &
                                        time_cur,                &
                                        time_step,           &
                                        occupation,              &
                                        c_matrix_cmplx,          &
                                        hamiltonian_kinetic,     &
                                        hamiltonian_nucleus,     &
                                        h_small_cmplx,           &
                                        s_matrix_sqrt_inv,       &
                                        dipole_basis,            &
                                        hamiltonian_fock_cmplx)

     !--5--UPDATE----|
     c_matrix_orth_hist_cmplx(:,:,:,1)=c_matrix_orth_cmplx(:,:,:)
     h_small_hist_cmplx(:,:,:,n_hist)=h_small_cmplx
   end if
   ! ///////////////////////////////////

   ! Iterative propagation with Lagrange interpolation
   ! ---------------|t-dt|-----------------|t|----------|t+dt/2)|----------|t+dt|
   !............|H(n_hist-1)|..........|H(n_hist)|....|H(n_hist+1)|.....|H(n_hist+2)|
   if(pred_corr=='PC3' .OR. pred_corr=='PC4') then
     hamiltonian_fock_cmplx=(0.0_dp,0.0_dp)
     h_small_hist_cmplx(:,:,:,n_hist+2)=(0.0_dp,0.0_dp)
     !--1--EXTRAPOLATION WITH PREVIOUS STEPS----
     do iextr=1,n_hist
       h_small_hist_cmplx(:,:,:,n_hist+2)=h_small_hist_cmplx(:,:,:,n_hist+2)+extrap_coefs(iextr)*h_small_hist_cmplx(:,:,:,iextr)
     end do

     !--2--LOCAL LINEAR INTERPOLATION----| hamiltonian_fock_cmplx in the 1/2 of the current time interval
     h_small_hist_cmplx(:,:,:,n_hist+1)=0.5_dp*(h_small_hist_cmplx(:,:,:,n_hist)+h_small_hist_cmplx(:,:,:,n_hist+2))

!     if ( is_iomaster .AND. mod(itau-1,mod_write)==0 ) then
!       write(name_iter_norm,"(3A,I4.4,A)") "./iter_norm/", TRIM(pred_corr), "_norm_itau_",itau,".dat"
!       open(newunit=file_iter_norm,file=name_iter_norm)
!     end if
     do i_iter=1,n_iter
       h_small_cmplx(:,:,:)=h_small_hist_cmplx(:,:,:,n_hist+1)
       !--3--PREDICTOR (propagation of C(0)-->C(1))
       call propagate_orth(nstate,basis,time_step,c_matrix_orth_hist_cmplx(:,:,:,1),c_matrix_cmplx,h_small_cmplx,s_matrix_sqrt_inv,prop_type)

       !--4--CORRECTOR----| C(1)-->H(1)
       call setup_hamiltonian_fock_cmplx( basis,                   &
                                          nstate,                  &
                                          itau,                    &
                                          time_cur,                &
                                          time_step,           &
                                          occupation,              &
                                          c_matrix_cmplx,          &
                                          hamiltonian_kinetic,     &
                                          hamiltonian_nucleus,     &
                                          h_small_hist_cmplx(:,:,:,n_hist+2),           &
                                          s_matrix_sqrt_inv,       &
                                          dipole_basis,            &
                                          hamiltonian_fock_cmplx)

       c_matrix_orth_hist_cmplx(:,:,:,1)=c_matrix_orth_cmplx(:,:,:)
       !--2B--LOCAL LINEAR INTERPOLATION----| hamiltonian_fock_cmplx in the 1/2 of the current time interval
       h_small_hist_cmplx(:,:,:,n_hist+1)=0.5_dp*(h_small_hist_cmplx(:,:,:,n_hist)+h_small_hist_cmplx(:,:,:,n_hist+2))

       !**COMPARISON**
!       if( is_iomaster ) then
!         if(mod(itau-1,mod_write)==0 ) then
!           write(file_iter_norm,*) i_iter, NORM2(ABS(h_small_hist_cmplx(:,:,:,n_hist+1)-h_small_cmplx(:,:,:)))
!         end if
!       end if
     end do ! i_iter
!     close(file_iter_norm)

     !--5--PROPAGATION----| C(0)---U[H(1/2)]--->C(1)
     call propagate_orth(nstate,basis,time_step,c_matrix_orth_hist_cmplx(:,:,:,1),c_matrix_cmplx,h_small_hist_cmplx(:,:,:,n_hist+1),s_matrix_sqrt_inv,prop_type)

     !--6--UPDATE----|C(1)-->C(0)
     c_matrix_orth_cmplx(:,:,:)=c_matrix_orth_hist_cmplx(:,:,:,1)
     do iextr=1,n_hist-1
       h_small_hist_cmplx(:,:,:,iextr)=h_small_hist_cmplx(:,:,:,iextr+1)
     end do
     h_small_hist_cmplx(:,:,:,n_hist)=h_small_hist_cmplx(:,:,:,n_hist+2)
   end if

   ! ///////////////////////////////////

   ! Iterative ETRS - enforced time-reversal symmetry
   ! ---------------|t-dt|-----------------|t|--------------------|t+dt|
   !............|H(n_hist-1)|..........|H(n_hist)|.............|H(n_hist+1)|
   if(pred_corr=='PC5' .OR. pred_corr=='PC6') then
     hamiltonian_fock_cmplx=(0.0_dp,0.0_dp)
     h_small_hist_cmplx(:,:,:,n_hist+1)=(0.0_dp,0.0_dp)
     !--1--EXTRAPOLATION WITH PREVIOUS STEPS----
     do iextr=1,n_hist
       h_small_hist_cmplx(:,:,:,n_hist+1)=h_small_hist_cmplx(:,:,:,n_hist+1)+extrap_coefs(iextr)*h_small_hist_cmplx(:,:,:,iextr)
     end do

!     if( is_iomaster ) then
!       if(mod(itau-1,mod_write)==0 ) then
!         write(name_iter_norm,"(3A,I4.4,A)") "./iter_norm/", TRIM(pred_corr), "_norm_itau_",itau,".dat"
!         open(newunit=file_iter_norm,file=name_iter_norm)
!       end if
!     end if
     do i_iter=1,n_iter
       c_matrix_orth_hist_cmplx(:,:,:,1)=c_matrix_orth_cmplx(:,:,:)
       h_small_cmplx(:,:,:)=h_small_hist_cmplx(:,:,:,n_hist+1)
       !--3--PREDICTOR (propagation of C(0)-->C(1))
       call propagate_orth(nstate,basis,time_step,c_matrix_orth_hist_cmplx(:,:,:,1),c_matrix_cmplx,h_small_hist_cmplx(:,:,:,n_hist:n_hist+1),s_matrix_sqrt_inv,"ETRS")
       !--4--CORRECTOR----| C(1)-->H(1)
       call setup_hamiltonian_fock_cmplx( basis,                   &
                                          nstate,                  &
                                          itau,                    &
                                          time_cur,                &
                                          time_step,           &
                                          occupation,              &
                                          c_matrix_cmplx,          &
                                          hamiltonian_kinetic,     &
                                          hamiltonian_nucleus,     &
                                          h_small_hist_cmplx(:,:,:,n_hist+1) ,    &
                                          s_matrix_sqrt_inv,       &
                                          dipole_basis,            &
                                          hamiltonian_fock_cmplx)

!       c_matrix_orth_hist_cmplx(:,:,:,1)=c_matrix_orth_cmplx(:,:,:)

       !**COMPARISON**
!       if( is_iomaster ) then
!         if(mod(itau-1,mod_write)==0 ) then
!           write(file_iter_norm,*) i_iter, NORM2(ABS(h_small_hist_cmplx(:,:,:,n_hist+1)-h_small_cmplx(:,:,:)))
!         end if
!       end if
     end do ! i_iter
!     close(file_iter_norm)

!     !--5--PROPAGATION----| C(0)---U[H(1/2)]--->C(!1)
!     call propagate_orth(nstate,basis,time_step,c_matrix_orth_cmplx,c_matrix_cmplx,h_small_hist_cmplx(:,:,:,n_hist:n_hist+1),s_matrix_sqrt_inv,"ETRS")

     !--6--UPDATE----|
!     c_matrix_orth_hist_cmplx(:,:,:,1)=c_matrix_orth_cmplx(:,:,:)
     c_matrix_orth_cmplx(:,:,:)=c_matrix_orth_hist_cmplx(:,:,:,1)
     do iextr=1,n_hist
       h_small_hist_cmplx(:,:,:,iextr)=h_small_hist_cmplx(:,:,:,iextr+1)
     end do
   end if

   ! ///////////////////////////////////

   ! ETRS proposed by Xavier Andrade
   ! ---------------|t-dt|-----------------|t|--------------------|t+dt|
   !............|---------|...............|H(1)|..................|H(2)|
   if(pred_corr=='PC7' ) then
     hamiltonian_fock_cmplx=(0.0_dp,0.0_dp)
     h_small_hist_cmplx(:,:,:,2)=(0.0_dp,0.0_dp)

     call propagate_orth(nstate,basis,time_step,c_matrix_orth_hist_cmplx(:,:,:,1),c_matrix_cmplx,h_small_hist_cmplx(:,:,:,1),s_matrix_sqrt_inv,"MAG2")

     do i_iter=1,n_iter
       call setup_hamiltonian_fock_cmplx( basis,                   &
                                          nstate,                  &
                                          itau,                    &
                                          time_cur,                &
                                          time_step,           &
                                          occupation,              &
                                          c_matrix_cmplx,          &
                                          hamiltonian_kinetic,     &
                                          hamiltonian_nucleus,     &
                                          h_small_hist_cmplx(:,:,:,2),   &
                                          s_matrix_sqrt_inv,       &
                                          dipole_basis,            &
                                          hamiltonian_fock_cmplx)

       if(i_iter/=n_iter) then
         c_matrix_orth_hist_cmplx(:,:,:,1)=c_matrix_orth_cmplx(:,:,:)
         call propagate_orth(nstate,basis,time_step,c_matrix_orth_hist_cmplx(:,:,:,1),c_matrix_cmplx,h_small_hist_cmplx(:,:,:,1:2),s_matrix_sqrt_inv,"ETRS")
       end if
     end do

     !--6--UPDATE----|C(1)-->C(0)
     c_matrix_orth_cmplx(:,:,:)=c_matrix_orth_hist_cmplx(:,:,:,1)
     h_small_hist_cmplx(:,:,:,1)=h_small_hist_cmplx(:,:,:,2)
   end if

   ! debug
   !call check_identity_cmplx(nocc,nocc,MATMUL(MATMUL(TRANSPOSE(CONJG(c_matrix_cmplx(:,:,nspin))),s_matrix(:,:)), c_matrix_cmplx(:,:,nspin) ),is_identity_)
   !if(.NOT. is_identity_) then
   !  write(stdout,*) "C**H*S*C is not identity at itau= ", itau
   !end if

!   call print_2d_matrix("check",MATMUL(MATMUL(TRANSPOSE(CONJG(c_matrix_cmplx(:,:,nspin))),s_matrix(:,:)), c_matrix_cmplx(:,:,nspin) )   ,nocc,nocc,stdout,4)
!   call print_2d_matrix("c_matrix_cmplx",c_matrix_cmplx(:,:,1),basis%nbf,nocc,stdout,4)
!   call print_2d_matrix_cmplx("c_matrix_orth_cmplx",c_matrix_orth_cmplx(:,:,1),nstate,nocc,stdout,4)

   if( is_iomaster .AND. ABS(time_cur / (write_step)- NINT(time_cur / (write_step))) < 1.0e-7 ) then

     if(excit_type%is_projectile) call output_projectile_position()

     !FBFB do something !
     call setup_density_matrix_cmplx(basis%nbf,nstate,nocc,c_matrix_cmplx,occupation,p_matrix_cmplx)
     en%tot = en%nuc + en%kin + en%nuc_nuc + en%hart + en%exx_hyb + en%xc + en%excit

     if( print_cube_rho_tddft_ ) call plot_cube_wfn_cmplx(nstate,nocc,basis,occupation,c_matrix_cmplx,iwrite_step)
     if(print_cube_diff_tddft_ ) call plot_cube_diff_cmplx(nstate,nocc,basis,occupation,c_matrix_cmplx,iwrite_step,cube_density_start,nx,ny,nz)
     if( print_line_rho_tddft_ ) call plot_rho_cmplx(nstate,nocc,basis,occupation,c_matrix_cmplx,iwrite_step,time_cur)
     if(excit_type%is_light) write(file_excit_field,'(2f19.10)') time_cur, REAL(m_excit_field_dir)

     if(excit_type%is_light) then
       call static_dipole_fast_cmplx(basis,p_matrix_cmplx,dipole_basis,dipole)
       write(file_dipole_time,'(4f19.10)') time_cur, dipole(:) * au_debye
     end if

     if(excit_type%is_projectile) then
       write(file_time_data,"(F9.4,8(2x,es16.8E3))") &
        time_cur, en%tot, xatom(3,natom), en%nuc_nuc, en%nuc, en%kin, en%hart, en%exx_hyb, en%xc
     end if
     if(excit_type%is_light) then
       write(file_time_data,"(F9.4,8(2x,es16.8E3))") &
        time_cur, en%tot, en%nuc_nuc, en%nuc, en%kin, en%hart, en%exx_hyb, en%xc, en%excit
     end if

     write(stdout,*)
     write(stdout,'(1x,a31,1x,f19.10)')  'RT-TDDFT Simulation time (au):', time_cur
     write(stdout,'(1x,a31,1x,f19.10)')  'RT-TDDFT Total Energy    (Ha):', en%tot
     if(excit_type%is_light) write(stdout,'(1x,a31,1x,3f19.10)') 'RT-TDDFT Dipole Moment    (D):', dipole(:) * au_debye

     iwrite_step = iwrite_step + 1
  !-------q_matrix----------
     if(calc_q_matrix_) then
       q_occ=0.0_dp
       do ispin=1,nspin
         q_matrix_cmplx(:,:,ispin)=MATMUL(CONJG(TRANSPOSE(c_matrix_orth_start_complete_cmplx(:,:,ispin))),c_matrix_orth_cmplx(:,:,ispin))

         do istate=istate_cut(1),istate_cut(2)
           do iocc=1,nocc
             q_occ(1)=q_occ(1)+ABS(q_matrix_cmplx(istate,iocc,ispin))**2*occupation(iocc,ispin)
           end do
         end do

         do istate=istate_cut(2)+1,istate_cut(3)
           do iocc=1,nocc
             q_occ(2)=q_occ(2)+ABS(q_matrix_cmplx(istate,iocc,ispin)**2)*occupation(iocc,ispin)
           end do
         end do

         do istate=istate_cut(3)+1,istate_cut(4)
           do iocc=1,nocc
             q_occ(3)=q_occ(3)+ABS(q_matrix_cmplx(istate,iocc,ispin))**2*occupation(iocc,ispin)
           end do
         end do

         write(file_q_matrix(ispin),"(F9.4,10(2x,es16.8E3))") time_cur, q_occ(:)
       end do
     end if
  !---end q_matrix

   end if

!--TIMING
   if(itau==3) then
     ntau=NINT((time_sim-time_min)/time_step)
     call stop_clock(timing_tddft_one_iter)
     time_one_iter=timing(timing_tddft_one_iter)
     write(stdout,'(/,1x,a)') '**********************************'
     write(stdout,"(1x,a30,2x,es14.6,1x,a)") "Time of one iteration is", time_one_iter,"s"
     write(stdout,"(1x,a30,2x,3(f12.2,1x,a))") "Estimated calculation time is", time_one_iter*ntau, "s  = ", &
                                               time_one_iter*ntau/60.0_dp, &
                                               "min  = ", time_one_iter*ntau/3600.0_dp, "hrs"
     write(stdout,'(1x,a)') '**********************************'
     flush(stdout)
   end if

   if( print_tddft_restart_ .AND. mod(itau,n_restart_tddft)==0 ) then
     call write_restart_tddft(nstate,time_cur,c_matrix_orth_cmplx)
   end if

  time_cur = time_min + itau*time_step
  itau = itau + 1
!---
 end do
 in_tddft_loop=.FALSE.
!********end time loop*******************

 if(print_tddft_restart_) then
   !time_cur-time_step to be consistent with the actual last moment of the simulation
   call write_restart_tddft(nstate,time_cur-time_step,c_matrix_orth_cmplx)
 end if

 if( is_iomaster) then
   close(file_time_data)
   if( excit_type%is_light) close(file_dipole_time)
   if( excit_type%is_light ) close(file_excit_field)
 end if

 call clean_deallocate('p_matrix_cmplx for TDDFT',p_matrix_cmplx)
 call clean_deallocate('h_small_hist_cmplx for TDDFT',h_small_hist_cmplx)
 call clean_deallocate('c_matrix_orth_hist_cmplx for TDDFT',c_matrix_orth_hist_cmplx)

! if(calc_q_matrix_) then
!   call clean_deallocate('q_matrix for TDDFT',q_matrix_cmplx,nstate,nocc,nspin)
! end if

 if(ALLOCATED(m_nods)) deallocate(m_nods)
 if(ALLOCATED(extrap_coefs)) deallocate(extrap_coefs)
 if(ALLOCATED(cube_density_start)) deallocate(cube_density_start)

!end subroutine tddft_time_loop

 call stop_clock(timing_tddft_loop)
 write(stdout,"(1x,a)") "--------------------------------------------------------"
 write(stdout,"(1x,a)") "End of the tddft loop"
 write(stdout,"(1x,a)") "--------------------------------------------------------"

 if( calc_type%is_dft ) call destroy_dft_grid()

 call clean_deallocate('Overlap matrix S for TDDFT',s_matrix)
 call clean_deallocate('Overlap sqrt S^{-1/2}',s_matrix_sqrt_inv)
 call clean_deallocate('Kinetic operator T for TDDFT',hamiltonian_kinetic)
 call clean_deallocate('Nucleus operator V for TDDFT',hamiltonian_nucleus)

 deallocate(xatom_start)

 call clean_deallocate('Dipole_basis for TDDFT',dipole_basis)

 call clean_deallocate('Wavefunctions C for TDDFT',c_matrix_cmplx)   
 call clean_deallocate('Wavefunctions hist. C for TDDFT',c_matrix_orth_cmplx)   
 call clean_deallocate('Hamiltonian Fock for TDDFT',hamiltonian_fock_cmplx)   
 call clean_deallocate('h_small_start for TDDFT',h_small_cmplx)  

 write(stdout,'(/,x,a)') "End of RT-TDDFT simulation"
 write(stdout,'(1x,a,/)') '=================================================='


end subroutine calculate_propagation

!==========================================
subroutine initialize_q(nstate,nocc,nspin,q_matrix_cmplx,c_matrix_orth_start_complete_cmplx,h_small_cmplx,istate_cut,file_q_matrix)
 implicit none
 integer,intent(in)                       :: nstate, nocc, nspin
 integer,allocatable,intent(inout)        :: istate_cut(:)
 complex(dp),allocatable,intent(inout)    :: q_matrix_cmplx(:,:,:)
 complex(dp),allocatable,intent(inout)    :: c_matrix_orth_start_complete_cmplx(:,:,:)
 complex(dp),allocatable,intent(inout)    :: h_small_cmplx(:,:,:)
 integer,intent(inout)                    :: file_q_matrix(2)
!=====
 character(len=50)           :: name_file_q_matrix
 integer                    :: ispin
 real(dp),allocatable       :: energies_inst(:)
 logical                    :: file_exists
 integer                    :: file_q_matrix_param
!=====

 allocate(istate_cut(10))
 call clean_allocate('q_matrix for TDDFT',q_matrix_cmplx,nstate,nocc,nspin)
 call clean_allocate('c_matrix_orth_start for TDDFT',c_matrix_orth_start_complete_cmplx,nstate,nstate,nspin)
 allocate(energies_inst(nstate))
 do ispin=1, nspin
   call diagonalize(h_small_cmplx(:,:,ispin),energies_inst,c_matrix_orth_start_complete_cmplx(:,:,ispin))
 end do
 deallocate(energies_inst)
 istate_cut(4)=nstate
 inquire(file='manual_q_matrix_param',exist=file_exists)
 if(file_exists) then
   open(newunit=file_q_matrix_param,file='manual_q_matrix_param',status='old')
   read(file_q_matrix_param,*) istate_cut(1), istate_cut(2), istate_cut(3)
   close(file_q_matrix_param)
 else
   istate_cut(1)=1
   istate_cut(2)=natom-1
   istate_cut(3)=natom+INT((natom-1)/2)
   call issue_warning('plot_rho_traj_bunch_contrib: manual_q_matrix_param file was not found')
 endif
 
 if( is_iomaster ) then
   do ispin=1,nspin
     write(name_file_q_matrix,"(a,i1,a)") "q_matrix_", ispin, ".dat"
     open(newunit=file_q_matrix(ispin),file=name_file_q_matrix)
   end do
 end if

end subroutine

!==========================================
subroutine check_identity_cmplx(n,m,mat_cmplx,ans)
 implicit none
 integer,intent(in)     :: n, m
 complex(dp),intent(in) :: mat_cmplx(n,m)
 logical,intent(inout)  :: ans
!=====
 integer   ::  i,j
 real(dp),parameter :: tol=1.0e-9_dp
!=====

 ans=.TRUE.
 do i=1,n
   do j=1,m
     if(i==j) then
       if(ABS(mat_cmplx(i,j)-1.0_dp)>tol) then
         write(stdout,*) "M(i,i)/=1 for: ",i,j,mat_cmplx(i,j)
         ans=.FALSE.
       end if
     else
       if(ABS(mat_cmplx(i,j))>tol) then
         write(stdout,*) "M(i,j)/=0 for: ",i,j,mat_cmplx(i,j)
         ans=.FALSE.
       end if
     end if
   end do
 end do

end subroutine check_identity_cmplx
!==========================================


!==========================================
subroutine write_restart_tddft(nstate,time_cur,c_matrix_orth_cmplx)
 use m_definitions
 implicit none
 integer,intent(in)         :: nstate
 complex(dp),intent(in)     :: c_matrix_orth_cmplx(nstate,nocc,nspin)
 real(dp),intent(in)        :: time_cur
!===
 integer                    :: restartfile
 integer                    :: istate,ispin
!=====

 if( .NOT. is_iomaster) return

 call start_clock(timing_restart_tddft_file)

 if (.NOT. in_tddft_loop) then
   write(stdout,'(/,a,f19.10)') ' Writing a RESTART_TDDFT file, time_cur= ', time_cur
 endif
 write(stdout,*) "suka", natom
 open(newunit=restartfile,file='RESTART_TDDFT',form='unformatted',action='write')
 ! current time
 write(restartfile) time_cur
 ! Atomic structure
 write(restartfile) natom
 write(restartfile) zatom(1:natom)
 write(restartfile) xatom(:,1:natom)
 ! nocc
 write(restartfile) nocc
 ! Nstate
 write(restartfile) nstate
 ! nspin
 write(restartfile) nspin
 ! Complex wavefunction coefficients C
 do ispin=1,nspin
   do istate=1,nocc
     write(restartfile) c_matrix_orth_cmplx(:,istate,ispin)
   enddo
 enddo

 close(restartfile)

 call stop_clock(timing_restart_tddft_file)

end subroutine write_restart_tddft

!==========================================
subroutine check_restart_tddft(nstate,occupation,restart_is_correct)
 use m_definitions
 implicit none
 logical,intent(out)        :: restart_is_correct
 integer,intent(in)         :: nstate
 real(dp),intent(in)        :: occupation(nstate,nspin)
!===
 logical                    :: file_exists
 integer                    :: nocc_check
 integer                    :: restartfile
 integer                    :: istate,ispin
 integer                    :: natom_read
 real(dp)                   :: time_cur_read
 real(dp),allocatable       :: zatom_read(:),x_read(:,:)
 integer                    :: nstate_read, nspin_read,nocc_read
!=====

 write(stdout,'(/,a)') ' Checking RESTART_TDDFT file'

 restart_is_correct=.TRUE.

 ! Find highest occupied state
 nocc_check=0
 do ispin=1,nspin
   do istate=1,nstate
     if( occupation(istate,ispin) < completely_empty ) cycle
     if( istate > nocc_check ) nocc_check = istate
   enddo
 end do

 inquire(file='RESTART_TDDFT',exist=file_exists)
 if(.NOT. file_exists) then
   write(stdout,'(/,a)') ' No RESTART file found'
   restart_is_correct=.FALSE.
   return
 endif


 open(newunit=restartfile,file='RESTART_TDDFT',form='unformatted',status='old',action='read')

 ! current time
 read(restartfile) time_cur_read

 !Different number of atoms in restart and input files is not provided for tddft restart
 !natom
 read(restartfile) natom_read
 if( natom_read /= natom ) then
   call issue_warning('RESTART_TDDFT file: natom is not the same.')
   restart_is_correct=.FALSE.
   close(restartfile)
   return 
 end if

 allocate(zatom_read(natom_read),x_read(3,natom_read))
 read(restartfile) zatom_read(1:natom_read)
 read(restartfile) x_read(:,1:natom_read)
 if( natom_read /= natom  &
  .OR. ANY( ABS( zatom_read(1:MIN(natom_read,natom)) - zatom(1:MIN(natom_read,natom)) ) > 1.0e-5_dp ) &
  .OR. ANY( ABS(   x_read(:,1:MIN(natom_read,natom-nprojectile)) - xatom(:,1:MIN(natom_read,natom-nprojectile))   ) > 1.0e-5_dp ) ) then
   call issue_warning('RESTART_TDDFT file: Geometry has changed')
 endif
 deallocate(zatom_read,x_read)

 ! nocc
 read(restartfile) nocc_read
 if(nocc_check /= nocc_read) then
   call issue_warning('RESTART_TDDFT file: nocc is not the same, restart file will not be used')
   restart_is_correct=.FALSE.
   close(restartfile)
   return
 end if

 ! nstate
 read(restartfile) nstate_read
 if(nstate /= nstate_read) then
   call issue_warning('RESTART_TDDFT file: nstate is not the same, restart file will not be used')
   restart_is_correct=.FALSE.
   close(restartfile)
   return
 end if

 ! nspin
 read(restartfile) nspin_read
 if(nspin /= nspin_read) then
   call issue_warning('RESTART_TDDFT file: nspin is not the same, restart file will not be used')
   restart_is_correct=.FALSE.
   close(restartfile)
   return
 end if

 close(restartfile)

end subroutine check_restart_tddft

!==========================================
subroutine get_time_min_restart(time_min)
 use m_definitions
 implicit none
 real(dp),intent(inout)     :: time_min
!===
 logical                    :: file_exists
 integer                    :: restartfile
!=====

 write(stdout,'(/,a)') ' Getting time_min from RESTART_TDDFT file'

 inquire(file='RESTART_TDDFT',exist=file_exists)
 if(.NOT. file_exists) then
   write(stdout,'(/,a)') ' No RESTART file found'
   call die("No RESTART_TDDFT file found for the second read")
 endif

 open(newunit=restartfile,file='RESTART_TDDFT',form='unformatted',status='old',action='read')

 ! current time
 read(restartfile) time_min
 write(stdout,"(1x,a,f7.3)") "time_min= ", time_min

 close(restartfile)

end subroutine get_time_min_restart

!==========================================
subroutine read_restart_tddft(nstate,time_min,c_matrix_orth_cmplx)
 use m_definitions
 implicit none
 complex(dp),intent(inout)  :: c_matrix_orth_cmplx(nstate,nocc,nspin)
 real(dp),intent(inout)     :: time_min
 integer,intent(in)         :: nstate
!===
 logical                    :: file_exists
 integer                    :: restartfile
 integer                    :: istate,ispin
 integer                    :: natom_read
 real(dp),allocatable       :: zatom_read(:),x_read(:,:)
 integer                    :: nstate_read, nspin_read,nocc_read
!=====

 write(stdout,'(/,a)') ' Reading a RESTART_TDDFT file'

 inquire(file='RESTART_TDDFT',exist=file_exists)
 if(.NOT. file_exists) then
   write(stdout,'(/,a)') ' No RESTART file found'
   return
 endif

 open(newunit=restartfile,file='RESTART_TDDFT',form='unformatted',status='old',action='read')

 ! current time
 read(restartfile) time_min
 write(stdout,"(1x,a,f7.3)") "time_min= ", time_min

 ! Atomic structure
 read(restartfile) natom_read
 allocate(zatom_read(natom_read),x_read(3,natom_read))
 read(restartfile) zatom_read(1:natom_read)
 read(restartfile) xatom_start(:,1:natom_read)
 deallocate(zatom_read)

 ! nocc
 read(restartfile) nocc_read

 ! Nstate
 read(restartfile) nstate_read

 ! nspin
 read(restartfile) nspin_read

 ! Complex wavefunction coefficients C
 do ispin=1,nspin
   do istate=1,nocc
     read(restartfile) c_matrix_orth_cmplx(:,istate,ispin)
   enddo
 enddo

 close(restartfile)

end subroutine read_restart_tddft

!==========================================
subroutine get_extrap_coefs_lagr(m_nods,x_pred,extrap_coefs,n_hist_cur)
 use m_definitions
 implicit none
 integer, intent(in)          :: n_hist_cur
 real(dp),intent(in)          :: m_nods(n_hist_cur)
 real(dp),intent(in)          :: x_pred
 real(dp),intent(inout)       :: extrap_coefs(n_hist_cur)
!=====
 integer      :: i,j
!=====

 extrap_coefs(:)=1.0_dp
 do i=1,n_hist_cur
   do j=1,n_hist_cur
     if(i==j) cycle
     extrap_coefs(i)=extrap_coefs(i)*(x_pred-m_nods(j))/(m_nods(i)-m_nods(j))
   end do
 end do
end subroutine get_extrap_coefs_lagr

!==========================================
subroutine get_extrap_coefs_aspc(extrap_coefs,n_hist_cur)
 use m_definitions
 implicit none
 integer, intent(in)          :: n_hist_cur!
 real(dp),intent(inout)       :: extrap_coefs(n_hist_cur)
!=====

 if(n_hist_cur==1) then
   extrap_coefs(1)=1.0_dp
 end if


 if(n_hist_cur==2) then
   extrap_coefs(1)=-1.0_dp
   extrap_coefs(2)=2.0_dp
 end if

 if(n_hist_cur==3) then
   extrap_coefs(1)=0.5_dp
   extrap_coefs(2)=-2.0_dp
   extrap_coefs(3)=2.5_dp
 end if

 if(n_hist_cur==4) then
   extrap_coefs(1)=-0.2_dp
   extrap_coefs(2)=1.2_dp
   extrap_coefs(3)=-2.8_dp
   extrap_coefs(4)=2.8_dp
 end if

 if(n_hist_cur==5) then
   extrap_coefs(1)=1.0_dp/14.0_dp
   extrap_coefs(2)=-4.0_dp/7.0_dp
   extrap_coefs(3)=27.0_dp/14.0_dp
   extrap_coefs(4)=-24.0_dp/7.0_dp
   extrap_coefs(5)=3.0_dp
 end if

 if(n_hist_cur==6) then
   extrap_coefs(1)=-1.0_dp/42.0_dp
   extrap_coefs(2)=5.0_dp/21.0_dp
   extrap_coefs(3)=-22.0_dp/21.0_dp
   extrap_coefs(4)=55.0_dp/21.0_dp
   extrap_coefs(5)=-55.0_dp/14.0_dp
   extrap_coefs(6)=22.0_dp/7.0_dp
 end if


end subroutine get_extrap_coefs_aspc

!==========================================
subroutine propagate_orth_ham_1(nstate,basis,time_step_cur,c_matrix_orth_cmplx,c_matrix_cmplx,h_small_cmplx,s_matrix_sqrt_inv,prop_type)
 implicit none
 integer,intent(in)          :: nstate
 type(basis_set),intent(in)  :: basis
 real(dp),intent(in)         :: time_step_cur
 complex(dp),intent(inout)   :: c_matrix_orth_cmplx(nstate,nocc,nspin)
 complex(dp), intent(inout)  :: c_matrix_cmplx(basis%nbf,nocc,nspin)
 complex(dp),intent(in)      :: h_small_cmplx(nstate,nstate,nspin)
 real(dp),intent(in)         :: s_matrix_sqrt_inv(basis%nbf,nstate)
 character(len=4),intent(in) :: prop_type
!=====
 integer                    :: ispin
 integer                    :: istate,jstate
 complex(dp),allocatable    :: m_tmp_1(:,:)
 complex(dp),allocatable    :: m_tmp_3(:,:)
!==variables for the MAG2 propagator
 complex(dp),allocatable    :: a_matrix_orth_cmplx(:,:)
 real(dp),allocatable       :: energies_inst(:)
!==variables for the CN propagator
 complex(dp),allocatable    :: l_matrix_cmplx(:,:) ! Follow the notation of M.A.L.Marques, C.A.Ullrich et al,
 complex(dp),allocatable    :: b_matrix_cmplx(:,:) ! TDDFT Book, Springer (2006), !p205
!=====
 complex(dp)                :: s_matrix_sqrt_inv_cmplx(basis%nbf,nstate)
!=====

 call start_clock(timing_tddft_propagation)

 s_matrix_sqrt_inv_cmplx = s_matrix_sqrt_inv

 do ispin=1, nspin
   select case(prop_type)
   case('CN')
     allocate(l_matrix_cmplx(nstate,nstate))
     allocate(b_matrix_cmplx(nstate,nstate))
     l_matrix_cmplx(:,:)= im * time_step_cur / 2.0_dp * h_small_cmplx(:,:,ispin)
     b_matrix_cmplx(:,:)=-l_matrix_cmplx(:,:)
     do istate=1,nstate
       b_matrix_cmplx(istate,istate)=b_matrix_cmplx(istate,istate)+1.0_dp
       l_matrix_cmplx(istate,istate)=l_matrix_cmplx(istate,istate)+1.0_dp
     end do
     call invert(l_matrix_cmplx)

     b_matrix_cmplx(:,:)            = MATMUL( l_matrix_cmplx(:,:),b_matrix_cmplx(:,:))
     c_matrix_orth_cmplx(:,:,ispin) = MATMUL( b_matrix_cmplx(:,:),c_matrix_orth_cmplx(:,:,ispin))

!    c_matrix_orth_cmplx(:,:,ispin) = MATMUL( l_matrix_cmplx(:,:),MATMUL( b_matrix_cmplx(:,:),c_matrix_orth_cmplx(:,:,ispin) ) )
     deallocate(l_matrix_cmplx)
     deallocate(b_matrix_cmplx)
   case('MAG2')
     allocate(a_matrix_orth_cmplx(nstate,nstate))
     allocate(energies_inst(nstate))

     !
     ! First part, diagonalize
     call start_clock(timing_propagate_diago)
     a_matrix_orth_cmplx(:,:) = h_small_cmplx(:,:,ispin)
     call diagonalize_scalapack(scalapack_block_min,nstate,a_matrix_orth_cmplx,energies_inst)
     call stop_clock(timing_propagate_diago)

     !
     ! Second part, multiply matrices
     call start_clock(timing_propagate_matmul)

     allocate(m_tmp_1(nstate,nstate))
     forall (jstate=1:nstate)
       m_tmp_1(:,jstate) = a_matrix_orth_cmplx(:,jstate) * EXP(-im*time_step_cur*energies_inst(jstate) )
     end forall

     allocate(m_tmp_3(nstate,nocc))
     call matmul_abc_scalapack(scalapack_block_min,m_tmp_1,CONJG(TRANSPOSE(a_matrix_orth_cmplx(:,:))),c_matrix_orth_cmplx(:,:,ispin),m_tmp_3  )
     c_matrix_orth_cmplx(:,:,ispin) = m_tmp_3

     deallocate(m_tmp_3)
     deallocate(m_tmp_1)
     deallocate(energies_inst)
     deallocate(a_matrix_orth_cmplx)
     call stop_clock(timing_propagate_matmul)

     case default
       call die('Invalid choice for the propagation algorithm. Change prop_type or error_prop_types value in the input file')
   end select

   call matmul_ab_scalapack(scalapack_block_min,s_matrix_sqrt_inv_cmplx,c_matrix_orth_cmplx(:,:,ispin),c_matrix_cmplx(:,:,ispin))

 end do

 call stop_clock(timing_tddft_propagation)


end subroutine propagate_orth_ham_1

!==========================================
subroutine propagate_orth_ham_2(nstate,basis,time_step_cur,c_matrix_orth_cmplx,c_matrix_cmplx,h_small_hist2_cmplx,s_matrix_sqrt_inv,prop_type)
 implicit none
 integer,intent(in)          :: nstate
 type(basis_set),intent(in)  :: basis
 real(dp),intent(in)         :: time_step_cur
 complex(dp),intent(inout)   :: c_matrix_orth_cmplx(nstate,nocc,nspin)
 complex(dp), intent(inout)  :: c_matrix_cmplx(basis%nbf,nocc,nspin)
 complex(dp),intent(in)      :: h_small_hist2_cmplx(nstate,nstate,nspin,2)
 real(dp),intent(in)         :: s_matrix_sqrt_inv(basis%nbf,nstate)
 character(len=4),intent(in) :: prop_type
!=====
 integer             :: ispin,iham
 integer             :: ibf
 complex(dp)         :: a_matrix_orth_cmplx(nstate,nstate,2)
 real(dp)            :: energies_inst(nstate)
 complex(dp)         :: propagator_eigen(nstate,nstate,2)
!=====

 call start_clock(timing_tddft_propagation)
! a_matrix_cmplx(:,1:nstate) = MATMUL( s_matrix_sqrt_inv(:,:) , a_matrix_cmplx(:,:) )

 do ispin =1, nspin
   select case (prop_type)
   case('ETRS')
     do iham=1,2
       call diagonalize(h_small_hist2_cmplx(:,:,ispin,iham),energies_inst,a_matrix_orth_cmplx(:,:,iham))
       propagator_eigen(:,:,iham) = ( 0.0_dp , 0.0_dp )
       do ibf=1,nstate
         propagator_eigen(ibf,ibf,iham) = EXP(-im*time_step_cur/2.d0*energies_inst(ibf))
       end do
     end do
     c_matrix_orth_cmplx(:,:,ispin) = &
         MATMUL(MATMUL(MATMUL(MATMUL( MATMUL( MATMUL( a_matrix_orth_cmplx(:,:,2), propagator_eigen(:,:,2)  ) , CONJG(TRANSPOSE(a_matrix_orth_cmplx(:,:,2)))  ),  &
                            a_matrix_orth_cmplx(:,:,1)), propagator_eigen(:,:,1)), CONJG(TRANSPOSE(a_matrix_orth_cmplx(:,:,1))) ), c_matrix_orth_cmplx(:,:,ispin) )
   case default
     call die('Invalid choice of the propagation algorithm for the given PC scheme. Change prop_type value in the input file')
   end select
    c_matrix_cmplx(:,:,ispin) = MATMUL( s_matrix_sqrt_inv(:,:) , c_matrix_orth_cmplx(:,:,ispin) )
 end do

call stop_clock(timing_tddft_propagation)

end subroutine propagate_orth_ham_2

!==========================================
subroutine setup_hamiltonian_fock_cmplx( basis,                   &
                                         nstate,                  &
                                         itau,                    &
                                         time_cur,                &
                                         time_step_cur,           &
                                         occupation,              &
                                         c_matrix_cmplx,          &
                                         hamiltonian_kinetic,     &
                                         hamiltonian_nucleus,     &
                                         h_small_cmplx,           &
                                         s_matrix_sqrt_inv,       &
                                         dipole_basis,            &
                                         hamiltonian_fock_cmplx)
                                         
 implicit none
!=====
 type(basis_set),intent(in)       :: basis
 integer,intent(in)               :: nstate
 integer,intent(in)               :: itau
 real(dp),intent(in)              :: time_cur
 real(dp),intent(in)              :: time_step_cur
 real(dp),intent(in)              :: occupation(nstate,nspin)
 real(dp),intent(in)              :: hamiltonian_kinetic(basis%nbf,basis%nbf)
 real(dp),intent(inout)           :: hamiltonian_nucleus(basis%nbf,basis%nbf)
 real(dp),allocatable,intent(in)  :: dipole_basis(:,:,:)
 real(dp),intent(in)              :: s_matrix_sqrt_inv(basis%nbf,nstate)
 complex(dp),intent(in)           :: c_matrix_cmplx(basis%nbf,nocc,nspin)
 complex(dp),intent(inout)        :: hamiltonian_fock_cmplx(basis%nbf,basis%nbf,nspin)
 complex(dp),intent(inout)        :: h_small_cmplx(nstate,nstate,nspin)
!=====
 logical        :: calc_excit_
 integer        :: ispin, idir
 real(dp)       :: excit_field(3)
 complex(dp)    :: p_matrix_cmplx(basis%nbf,basis%nbf,nspin)
 complex(dp)    :: s_matrix_sqrt_inv_cmplx(basis%nbf,nstate)
!=====

 call start_clock(timing_tddft_hamiltonian_fock)

 s_matrix_sqrt_inv_cmplx = s_matrix_sqrt_inv

 call setup_density_matrix_cmplx(basis%nbf,nstate,nocc,c_matrix_cmplx,occupation,p_matrix_cmplx)

 !--Hamiltonian - Hartree Exchange Correlation---
 call calculate_hamiltonian_hxc_ri_cmplx(basis,                    &
                                         nstate,                   &
                                         nocc,                     &
                                         basis%nbf,                &
                                         basis%nbf,                &
                                         basis%nbf,                &
                                         nocc,                     &
                                         occupation,               &
                                         c_matrix_cmplx,           &
                                         p_matrix_cmplx,           &
                                         hamiltonian_fock_cmplx)

 en%excit=0.0_dp

 !
 ! Excitation part of the Hamiltonian
 ! Light excitation
 if(excit_type%is_light) then
   excit_field=0.0_dp
   calc_excit_ = .FALSE.
   calc_excit_ = calc_excit_ .OR. ( excit_type%name == 'GAU' )
   calc_excit_ = calc_excit_ .OR. ( excit_type%name == 'HSW'  .AND. abs(time_cur - excit_type%time0 - excit_omega/2.0_dp)<=excit_omega/2.0_dp )
   calc_excit_ = calc_excit_ .OR. ( excit_type%name == 'STEP' .AND. abs(time_cur - excit_type%time0 - excit_omega/2.0_dp)<=excit_omega/2.0_dp )
   calc_excit_ = calc_excit_ .OR. ( excit_type%name == 'DEL'  .AND. abs(time_cur - excit_type%time0)<=time_step_cur )
   if(itau==0) calc_excit_=.FALSE.
   if ( calc_excit_ ) then
     call calculate_excit_field(time_cur,excit_field)
     m_excit_field_dir=NORM2(excit_field(:))
     do idir=1,3
       do ispin=1, nspin
         hamiltonian_fock_cmplx(:,:,ispin) = hamiltonian_fock_cmplx(:,:,ispin) - dipole_basis(:,:,idir) * excit_field(idir)
         en%excit=en%excit+REAL(SUM(dipole_basis(:,:,idir)*excit_field(idir)*p_matrix_cmplx(:,:,ispin)),dp)
       enddo
     end do
   end if
 end if ! light excitation

 ! Projectile excitation
 if(excit_type%is_projectile) then
   xatom(:,natom)=xatom_start(:,natom) + vel(:,natom)*(time_cur-time_read)
   call nucleus_nucleus_energy(en%nuc_nuc)
   !
   ! Nucleus-electron interaction
!   if( parallel_ham ) then
!     if( parallel_buffer ) then
!       call setup_nucleus_buffer_sca(basis,basis%nbf,basis%nbf,hamiltonian_nucleus)
!     else
!       call setup_nucleus_sca(.FALSE.,basis,basis%nbf,basis%nbf,hamiltonian_nucleus)
!     endif
!   else
     call setup_nucleus(basis,hamiltonian_nucleus)

     if( nelement_ecp > 0 ) then
       call setup_nucleus_ecp(basis,hamiltonian_nucleus)
     endif
!   endif

 end if

 do ispin=1,nspin
   hamiltonian_fock_cmplx(:,:,ispin) = hamiltonian_fock_cmplx(:,:,ispin) + hamiltonian_kinetic(:,:) + hamiltonian_nucleus(:,:)
 enddo



 !   h_small_cmplx(:,:,ispin) = MATMUL( TRANSPOSE(s_matrix_sqrt_inv(:,:)) , &
 !                   MATMUL( hamiltonian_fock_cmplx(:,:,ispin) , s_matrix_sqrt_inv(:,:) ) )
 do ispin=1,nspin
   call matmul_transaba_scalapack(scalapack_block_min,s_matrix_sqrt_inv_cmplx,hamiltonian_fock_cmplx(:,:,ispin),h_small_cmplx(:,:,ispin))
 end do ! spin loop

 ! kinetic and nuclei-electrons energy contributions
 en%kin = real(SUM( hamiltonian_kinetic(:,:) * SUM(p_matrix_cmplx(:,:,:),DIM=3) ), dp)
 en%nuc = real(SUM( hamiltonian_nucleus(:,:) * SUM(p_matrix_cmplx(:,:,:),DIM=3) ), dp)

 call stop_clock(timing_tddft_hamiltonian_fock)

end subroutine setup_hamiltonian_fock_cmplx


!==========================================
subroutine calculate_excit_field(time_cur,excit_field)
 implicit none
 real(dp),intent(in)      :: time_cur       ! time in au
 real(dp),intent(inout)   :: excit_field(3) ! electric field in 3 dimensions
!=====
 real(dp)                 :: excit_dir_norm(3)
!=====

 excit_dir_norm(:)=excit_type%dir(:)/NORM2(excit_type%dir(:))

 select case(excit_type%name)
 case('GAU') !Gaussian electic field
   excit_field(:) = excit_type%kappa * EXP( -( time_cur-excit_type%time0 )**2 / 2.0_dp / excit_omega**2 ) * &
                  & excit_dir_norm(:)
 case('HSW') !Hann sine window
   excit_field(:) = excit_type%kappa * SIN( pi / excit_omega * ( time_cur - excit_type%time0  ) )**2 * excit_dir_norm(:)
 case('DEL') ! Delta excitation
   excit_field(:) = excit_type%kappa * excit_dir_norm(:)
 case('STEP') ! Step excitation
   excit_field(:) = excit_type%kappa * excit_dir_norm(:)
 case default
    call die('Invalid choice for the excitation type. Change excit_type value in the input file')
 end select

end subroutine calculate_excit_field


!=======================================
subroutine print_2d_matrix_cmplx(desc,matrix_cmplx,size_n,size_m,write_unit,prec)
 implicit none
 integer, intent(in)      :: prec ! precision
 integer, intent(in)      :: size_n,size_m, write_unit
 complex(dp),intent(in)  :: matrix_cmplx(size_n,size_m)
 character(*),intent(in)  :: desc
!=====
 character(100)  :: write_format1, write_format2
 integer            :: ivar,beg
!=====

! beg=4
 beg=3
 write(write_format1,*) '(',size_m," ('( ',F", prec+beg, ".", prec,"' ,',F", prec+beg, ".",prec,",' )  ') " ,')' ! (  1.01 ,  -0.03)  (  0.04 ,  0.10)
 write(write_format2,*) '(',size_m," (F", prec+beg, ".", prec,"' +  i',F", prec+beg, ".",prec,",'  ') " ,')'   ! 1.01 +  i  -0.03    0.03 +  i  0.10
 write(write_unit,*) desc
 do ivar=1,size_n
   write(write_unit,write_format1) matrix_cmplx(ivar,:)
 end do

end subroutine print_2d_matrix_cmplx

!=======================================
subroutine print_2d_matrix_real(desc,matrix_real,size_n,size_m,write_unit,prec)
 implicit none
 integer, intent(in)      :: prec ! precision
 integer, intent(in)      :: size_n,size_m, write_unit
 real(dp),intent(in)      :: matrix_real(size_m,size_m)
 character(*),intent(in)  :: desc
!=====
 character(100)  :: write_format1
 integer            :: ivar

 write(write_format1,*) '(',size_m," (F", prec+4, ".", prec,') ' ,')'
 write(write_unit,*) desc
 do ivar=1,size_n
   write(write_unit,write_format1) matrix_real(ivar,:)
 end do
end subroutine print_2d_matrix_real


!=========================================================================
end module m_tddft_propagator
!=========================================================================
