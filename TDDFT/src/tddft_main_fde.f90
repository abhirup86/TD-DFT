
! Copyright (C) 2001-2014 Quantum-ESPRESSO group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!

! *** This is the FDE version ***

!-----------------------------------------------------------------------
PROGRAM tddft_main
  !-----------------------------------------------------------------------
  !
  ! ... This is the main driver of the real time TDDFT propagation.
  ! ... Authors: Xiaofeng Qian and Davide Ceresoli
  ! ...
  ! ... References:
  ! ...   Xiaofeng Qian, Ju Li, Xi Lin, and Sidney Yip, PRB 73, 035408 (2006)
  ! ...
  USE kinds,           ONLY : DP
  USE io_files,        ONLY : tmp_dir
  USE io_global,       ONLY : ionode, stdout
  USE mp,              ONLY : mp_bcast
  USE tddft_module,    ONLY : job, molecule, tddft_exit_code
  USE control_flags,   ONLY : io_level, gamma_only, use_para_diag, twfcollect
  USE mp_global,       ONLY : mp_startup, nproc_pool_file
  USE mp_images,       ONLY : my_image_id
  USE mp_pools,        ONLY : nproc_pool
  USE check_stop,      ONLY : check_stop_init
  USE environment,     ONLY : environment_start
  USE wvfct,           ONLY : nbnd
  USE noncollin_module,ONLY : noncolin
!  USE tddft_version
  USE iotk_module  
  USE xml_io_base
  USE mp_global,         ONLY : mp_startup  
  USE mp_images,         ONLY : my_image_id
  USE read_input,        ONLY : read_input_file
  USE command_line_options, ONLY: input_file_
  USE fde,               ONLY : do_fde, rho_old
  USE mp_images,         ONLY : my_image_id
  USE mp_bands,        ONLY : nbgrp
#ifdef __BANDS
  USE mp_bands,        ONLY : inter_bgrp_comm
#endif

  !------------------------------------------------------------------------
  IMPLICIT NONE
  CHARACTER (LEN=9)   :: code = 'FDE'
  LOGICAL, EXTERNAL  :: check_para_diag
  INTEGER :: i
  LOGICAL :: opnd
  CHARACTER(LEN=256) :: filin, filout
  CHARACTER(LEN=7) :: image_label
  CHARACTER(LEN=6), EXTERNAL :: int_to_char
  !------------------------------------------------------------------------

  ! begin with the initialization part
!  call mp_startup(start_images=.true.)
  call mp_startup(start_fragments=.true.)
  call environment_start (code)
  

  do_fde = .true.


#ifndef __BANDS
  if (nbgrp > 1) &
    call errore('tddft_main', 'configure and recompile TDDFT with --enable-band-parallel', 1)
#endif

  ! ... Image-specific input files
  image_label = '_' // int_to_char(my_image_id)
  if ( trim (input_file_) == ' ') then
     filin = 'pw' // trim(image_label)  // '.in'
  else
     filin = trim(input_file_) // trim(image_label) // '.in'
  end if

  ! ... Here open image-specific output files
  IF ( ionode ) THEN
     !
     IF ( TRIM (input_file_) == ' ') THEN
        filout = 'pw' // TRIM(image_label)  // '.out'
     ELSE
        filout = TRIM(input_file_) // TRIM(image_label) // '.out'
     END IF
     INQUIRE ( UNIT = stdout, OPENED = opnd )
     IF (opnd) CLOSE ( UNIT = stdout )
     OPEN( UNIT = stdout, FILE = TRIM(filout), STATUS = 'UNKNOWN' )
     !
     write(stdout,*)
!  write(stdout,'(5X,''***** This is TDDFT svn revision '',A,'' *****'')') tddft_svn_revision
     write(stdout,'(5X,''***** This is TDDFT svn revision '',A,'' *****'')') 
     write(stdout,*)
     call flush(stdout)
  END IF



  call start_clock('PWSCF')
  call tddft_readin(filin)
  call check_stop_init()

  ! ... Set image-specific value for "tmpdir", starting from input value
  ! ... (read in read_input_file)
  DO i=LEN_TRIM(tmp_dir),1,-1
     IF ( tmp_dir(i:i) /= '/' .AND. tmp_dir(i:i) /= '.' ) EXIT
  END DO
  ! ... i = position of last character different from '/' and '.'
  IF ( i == 0 ) THEN
     tmp_dir = 'tmp' // trim(image_label) // '/'
  ELSE
     tmp_dir = tmp_dir(1:i) // trim(image_label) // '/'
  END IF

  io_level = 1
 
  ! read ground state wavefunctions
  call read_file
  call tddft_read_cards

#ifdef __MPI
  use_para_diag = check_para_diag(nbnd)
#else
  use_para_diag = .false.
#endif

  call tddft_openfil

  if (gamma_only) call errore ('tdddft_main', 'Cannot run TDFFT with gamma_only == .true. ', 1)
  if ((twfcollect .eqv. .false.)  .and. (nproc_pool_file /= nproc_pool)) &
    call errore('tddft_main', 'Different number of CPU/pool. Set wf_collect=.true. in SCF', 1)
#ifdef __BANDS
  if (nbgrp > 1 .and. (twfcollect .eqv. .false.)) &
    call errore('tddft_main', 'Cannot use band-parallelization without wf_collect in SCF', 1)
#endif
  if (noncolin) call errore('tdddft_main', 'non-collinear not supported yet', 1)
 

  call tddft_allocate()
  call tddft_setup()
  call tddft_summary()

#ifdef __BANDS
  call init_parallel_over_band(inter_bgrp_comm, nbnd)
#endif

  ! calculation
  select case (trim(job))
  case ('optical')
     if (molecule) then
        call molecule_optical_absorption
     else
        call errore('tddft_main', 'solids are not yet implemented', 1)
     endif

  case default
     call errore('tddft_main', 'wrong or undefined job in input', 1)

  end select
  
  ! print timings and stop the code
  call tddft_closefil
  call print_clock_tddft()
  call stop_run(tddft_exit_code)
  call do_stop(tddft_exit_code)
  
  STOP
  
END PROGRAM tddft_main

