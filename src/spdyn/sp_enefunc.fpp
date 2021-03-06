!--------1---------2---------3---------4---------5---------6---------7---------8
!
!  Module   sp_enefunc_mod
!> @brief   define potential energy functions in each domain
!! @authors Jaewoon Jung (JJ), Yuji Sugita (YS), Chigusa Kobayashi (CK)
!
!  (c) Copyright 2014 RIKEN. All rights reserved.
!
!--------1---------2---------3---------4---------5---------6---------7---------8

#ifdef HAVE_CONFIG_H
#include "../config.h"
#endif

module sp_enefunc_mod

  use sp_enefunc_gromacs_mod
  use sp_enefunc_amber_mod
  use sp_enefunc_charmm_mod
  use sp_enefunc_restraints_mod
  use sp_enefunc_localres_mod
  use sp_enefunc_table_mod
  use sp_communicate_mod
  use sp_migration_mod
  use sp_energy_mod
  use sp_restraints_str_mod
  use sp_constraints_str_mod
  use sp_enefunc_str_mod
  use sp_energy_str_mod
  use sp_domain_str_mod
  use molecules_str_mod
  use fileio_localres_mod
  use fileio_grotop_mod
  use fileio_prmtop_mod
  use fileio_par_mod
  use timers_mod
  use messages_mod
  use mpi_parallel_mod
  use constants_mod
#ifdef MPI
  use mpi
#endif

  implicit none
  private

  ! subroutines
  public  :: define_enefunc
  public  :: define_enefunc_pio
  public  :: update_enefunc
  private :: setup_enefunc_bond_pio
  private :: setup_enefunc_bond_constraint_pio
  private :: setup_enefunc_angl_pio
  private :: setup_enefunc_dihe_pio
! private :: setup_enefunc_rb_dihe_pio
  private :: setup_enefunc_impr_pio
  private :: setup_enefunc_cmap_pio
  private :: setup_enefunc_nonb_pio
  private :: setup_enefunc_dispcorr
  private :: check_bonding

contains

  !======1=========2=========3=========4=========5=========6=========7=========8
  !
  !  Subroutine    define_enefunc
  !> @brief        a driver subroutine for defining potential energy functions
  !! @authors      YS, JJ, CK
  !! @param[in]    ene_info    : ENERGY section control parameters information
  !! @param[in]    par         : CHARMM PAR information
  !! @param[in]    prmtop      : AMBER parameter topology information
  !! @param[in]    grotop      : GROMACS parameter topology information
  !! @param[in]    localres    : local restraint information
  !! @param[in]    molecule    : molecule information
  !! @param[in]    constraints : constraints information
  !! @param[inout] domain      : domain information
  !! @param[inout] enefunc     : energy potential functions information
  !
  !======1=========2=========3=========4=========5=========6=========7=========8

  subroutine define_enefunc(ene_info, par, prmtop, grotop, localres, molecule, &
                            constraints, restraints, domain, enefunc)

    ! formal arguments
    type(s_ene_info),        intent(in)    :: ene_info
    type(s_par),             intent(in)    :: par
    type(s_prmtop),          intent(in)    :: prmtop
    type(s_grotop),          intent(in)    :: grotop
    type(s_localres),        intent(in)    :: localres
    type(s_molecule),        intent(in)    :: molecule
    type(s_constraints),     intent(inout) :: constraints
    type(s_restraints),      intent(in)    :: restraints
    type(s_domain),          intent(inout) :: domain
    type(s_enefunc),         intent(inout) :: enefunc


    enefunc%forcefield        = ene_info%forcefield
    enefunc%output_style      = ene_info%output_style
    enefunc%table%water_table = ene_info%table .and. &
                                (ene_info%water_model(1:4) /= 'NONE' .and. &
                                (.not. ene_info%nonb_limiter))

    enefunc%switchdist        = ene_info%switchdist
    enefunc%cutoffdist        = ene_info%cutoffdist
    enefunc%pairlistdist      = ene_info%pairlistdist
    enefunc%dielec_const      = ene_info%dielec_const
    enefunc%force_switch      = ene_info%vdw_force_switch
    enefunc%vdw_shift         = ene_info%vdw_shift

    enefunc%vdw               = ene_info%vdw
    enefunc%pme_use           = ene_info%electrostatic == ElectrostaticPME
    enefunc%pme_alpha         = ene_info%pme_alpha
    enefunc%pme_ngrid_x       = ene_info%pme_ngrid_x
    enefunc%pme_ngrid_y       = ene_info%pme_ngrid_y
    enefunc%pme_ngrid_z       = ene_info%pme_ngrid_z
    enefunc%pme_nspline       = ene_info%pme_nspline
    enefunc%pme_scheme        = ene_info%pme_scheme
    enefunc%pme_max_spacing   = ene_info%pme_max_spacing
    enefunc%dispersion_corr   = ene_info%dispersion_corr
    enefunc%contact_check     = ene_info%contact_check
    enefunc%nonb_limiter      = ene_info%nonb_limiter
    enefunc%minimum_contact   = ene_info%minimum_contact
    enefunc%err_minimum_contact = ene_info%err_minimum_contact

    if (ene_info%structure_check == StructureCheckDomain) then
      enefunc%pairlist_check = .true.
      enefunc%bonding_check  = .true.
    endif


    ! charmm
    !
    if (par%num_bonds > 0) then

      call define_enefunc_charmm(ene_info, par, localres, molecule, &
                                 constraints, restraints, domain, enefunc)

    ! amber
    !
    else if (prmtop%num_atoms > 0) then

      call define_enefunc_amber (ene_info, prmtop, molecule, &
                                 constraints, restraints, domain, enefunc)

    ! gromacs
    !
    else if (grotop%num_atomtypes > 0) then

      call define_enefunc_gromacs(ene_info, grotop, molecule, &
                                 constraints, restraints, domain, enefunc)

    end if

    ! dispersion correction
    !
    call setup_enefunc_dispcorr(ene_info, domain, enefunc)

    ! bonding_checker
    !
    if (ene_info%structure_check /= StructureCheckNone)  &
      call check_bonding(enefunc, domain)

    return

  end subroutine define_enefunc

  !======1=========2=========3=========4=========5=========6=========7=========8
  !
  !  Subroutine    define_enefunc_pio
  !> @brief        a driver subroutine for defining potential energy functions
  !! @authors      JJ
  !! @param[in]    ene_info    : ENERGY section control parameters information
  !! @param[in]    localres    : local restraint information
  !! @param[inout] constraints : constraints information
  !! @param[inout] domain      : domain information
  !! @param[inout] enefunc     : energy potential functions information
  !
  !======1=========2=========3=========4=========5=========6=========7=========8

  subroutine define_enefunc_pio(ene_info, localres, comm, constraints, &
                                restraints, domain, enefunc)

    ! formal arguments
    type(s_ene_info),        intent(in)    :: ene_info
    type(s_localres),        intent(in)    :: localres
    type(s_comm),            intent(inout) :: comm
    type(s_constraints),     intent(inout) :: constraints
    type(s_restraints),      intent(inout) :: restraints 
    type(s_domain),          intent(inout) :: domain
    type(s_enefunc),         intent(inout) :: enefunc

    ! local variables
    integer                  :: ncel, ncelb

    enefunc%forcefield        = ene_info%forcefield
    enefunc%output_style      = ene_info%output_style
    enefunc%table%water_table = ene_info%table .and. &
                                (ene_info%water_model(1:4) /= 'NONE')

    enefunc%switchdist        = ene_info%switchdist
    enefunc%cutoffdist        = ene_info%cutoffdist
    enefunc%pairlistdist      = ene_info%pairlistdist
    enefunc%dielec_const      = ene_info%dielec_const

    enefunc%pme_use           = ene_info%electrostatic == ElectrostaticPME
    enefunc%vdw               = ene_info%vdw
    enefunc%pme_alpha         = ene_info%pme_alpha
    enefunc%pme_ngrid_x       = ene_info%pme_ngrid_x
    enefunc%pme_ngrid_y       = ene_info%pme_ngrid_y
    enefunc%pme_ngrid_z       = ene_info%pme_ngrid_z
    enefunc%pme_nspline       = ene_info%pme_nspline
    enefunc%pme_max_spacing   = ene_info%pme_max_spacing
    enefunc%pme_scheme        = ene_info%pme_scheme
    enefunc%dispersion_corr   = ene_info%dispersion_corr
    enefunc%contact_check     = ene_info%contact_check
    enefunc%nonb_limiter      = ene_info%nonb_limiter
    enefunc%minimum_contact   = ene_info%minimum_contact
    enefunc%err_minimum_contact = ene_info%err_minimum_contact

    ! base
    !
    ncel  = domain%num_cell_local
    ncelb = domain%num_cell_local + domain%num_cell_boundary

    call alloc_enefunc(enefunc, EneFuncBase, ncel, ncel)
    call alloc_enefunc(enefunc, EneFuncBond, ncel, ncel)
    call alloc_enefunc(enefunc, EneFuncAngl, ncel, ncel)
    call alloc_enefunc(enefunc, EneFuncDihe, ncel, ncel)
    call alloc_enefunc(enefunc, EneFuncImpr, ncel, ncel)
    call alloc_enefunc(enefunc, EneFuncBondCell, ncel, ncelb)

    if (.not. constraints%rigid_bond) then

      ! bond
      !
      call setup_enefunc_bond_pio(domain, enefunc)

    else

      ! bond
      !
      call setup_enefunc_bond_constraint_pio(domain, constraints, enefunc)

    end if

    ! angle
    !
    call setup_enefunc_angl_pio(domain, enefunc)

    ! dihedral
    !
    call setup_enefunc_dihe_pio(domain, enefunc)

    ! Ryckaert-Bellemans dihedral
    !
!   call setup_enefunc_rb_dihe_pio(domain, enefunc)

    ! improper
    !
    call setup_enefunc_impr_pio(domain, enefunc)

    ! cmap
    !
    call setup_enefunc_cmap_pio(ene_info, domain, enefunc)

    ! restraint
    !
    call setup_enefunc_restraints_pio(restraints, domain, enefunc)

    ! reassign bond information
    !
    call update_enefunc_pio(domain, comm, enefunc, constraints)
    call dealloc_enefunc(enefunc, EneFuncBondCell)

    ! nonbonded
    !
    call setup_enefunc_nonb_pio(ene_info, constraints, domain, enefunc)

    ! dispersion correction
    !
    call setup_enefunc_dispcorr(ene_info, domain, enefunc)

    ! lookup table
    !
    if(ene_info%table) &
    call setup_enefunc_table(ene_info, enefunc)

    ! restraint
    !
    call setup_enefunc_localres(localres, domain, enefunc)

    if (ene_info%structure_check /= StructureCheckNone)  &
      call check_bonding(enefunc, domain)

    call dealloc_domain(domain, DomainDynvar_pio)
    call dealloc_enefunc(enefunc, EneFuncBase_pio)
    call dealloc_enefunc(enefunc, EneFuncBond_pio)
    call dealloc_enefunc(enefunc, EneFuncAngl_pio)
    call dealloc_enefunc(enefunc, EneFuncDihe_pio)
    call dealloc_enefunc(enefunc, EneFuncRBDihe_pio)
    call dealloc_enefunc(enefunc, EneFuncImpr_pio)
    call dealloc_enefunc(enefunc, EneFuncCmap_pio)

    ! write summary of energy function
    !
    if (main_rank) then
      write(MsgOut,'(A)') &
           'Define_Enefunc_Pio> Number of Interactions in Each Term'
      write(MsgOut,'(A20,I10,A20,I10)')                  &
           '  bond_ene        = ', enefunc%num_bond_all, &
           '  angle_ene       = ', enefunc%num_angl_all
      write(MsgOut,'(A20,I10,A20,I10)')                  &
           '  torsion_ene     = ', enefunc%num_dihe_all, &
           '  rb_torsion_ene  = ', enefunc%num_rb_dihe_all
      write(MsgOut,'(A20,I10,A20,I10)')                  &
           '  improper_ene    = ', enefunc%num_impr_all, &
           '  cmap_ene        = ', enefunc%num_cmap_all
      write(MsgOut,'(A20,I10,A20,I10)')                  &
           '  nb_exclusions   = ', enefunc%num_excl_all, &
           '  nb14_calc       = ', enefunc%num_nb14_all
      write(MsgOut,'(A)') ' '
    end if

    return

  end subroutine define_enefunc_pio

  !======1=========2=========3=========4=========5=========6=========7=========8
  !
  !  Subroutine    update_enefunc
  !> @brief        a driver subroutine for updating potential energy functions
  !! @authors      JJ
  !! @param[inout] domain      : domain information
  !! @param[inout] comm        : communication information
  !! @param[inout] enefunc     : energy potential functions information
  !! @param[inout] constraints : constraints information [optional]
  !
  !======1=========2=========3=========4=========5=========6=========7=========8

  subroutine update_enefunc(domain, comm, enefunc, constraints)

    ! formal arguments
    type(s_domain),                intent(inout) :: domain
    type(s_comm),                  intent(inout) :: comm
    type(s_enefunc),               intent(inout) :: enefunc
    type(s_constraints), optional, intent(inout) :: constraints

    ! local variables
    logical                        :: first


    ! sending the bonding information to other domain
    !

    ! bond
    !
    call update_outgoing_enefunc_bond(domain, enefunc)

    ! angle
    !
    call update_outgoing_enefunc_angl(domain, enefunc)

    ! dihedral
    !
    call update_outgoing_enefunc_dihe(domain, enefunc)

    ! Ryckaert-Bellemans dihedral
    !
    call update_outgoing_enefunc_rb_dihe(domain, enefunc)

    ! improper dihedral
    !
    call update_outgoing_enefunc_impr(domain, enefunc)

    ! cmap
    !
    call update_outgoing_enefunc_cmap(domain, enefunc)

    ! restraint
    !
    call update_outgoing_enefunc_restraint(domain, enefunc)

    ! fitting
    !
    call update_outgoing_enefunc_fitting(domain, enefunc)

    ! communicate neighbour domain
    !
    call communicate_bond(domain, comm, enefunc)


    ! bond
    !
    call update_incoming_enefunc_bond(domain, enefunc)

    ! angle
    !
    call update_incoming_enefunc_angl(domain, enefunc)

    ! dihedral
    !
    call update_incoming_enefunc_dihe(domain, enefunc)

    ! Ryckaert-Bellemans dihedral
    !
    call update_incoming_enefunc_rb_dihe(domain, enefunc)

    ! improper dihedral
    !
    call update_incoming_enefunc_impr(domain, enefunc)

    ! cmap
    !
    call update_incoming_enefunc_cmap(domain, enefunc)

    ! restraint
    !
    call update_incoming_enefunc_restraint(domain, enefunc)

    ! fitting
    !
    call update_incoming_enefunc_fitting(domain, enefunc)

    ! re-count nonbond exclusion list
    !

    first = .false.

    if (constraints%rigid_bond) then

      call count_nonb_excl(first, .true., constraints, domain, enefunc)

    else

      call count_nonb_excl(first, .false., constraints, domain, enefunc)

    end if

    if (enefunc%bonding_check) call check_bonding(enefunc, domain)

    return

  end subroutine update_enefunc

  !======1=========2=========3=========4=========5=========6=========7=========8
  !
  !  Subroutine    update_enefunc_pio
  !> @brief        a driver subroutine for updating potential energy functions
  !! @authors      JJ
  !! @param[inout] domain      : domain information
  !! @param[inout] comm        : communication information
  !! @param[inout] enefunc     : energy potential functions information
  !! @param[inout] constraints : constraints information [optional]
  !
  !======1=========2=========3=========4=========5=========6=========7=========8

  subroutine update_enefunc_pio(domain, comm, enefunc, constraints)

    ! formal arguments
    type(s_domain),                intent(inout) :: domain
    type(s_comm),                  intent(inout) :: comm
    type(s_enefunc),               intent(inout) :: enefunc
    type(s_constraints), optional, intent(inout) :: constraints

    ! local variables
    logical                        :: first


    ! sending the bonding information to other domain
    !

    ! bond
    !
    call update_outgoing_enefunc_bond(domain, enefunc)

    ! angle
    !
    call update_outgoing_enefunc_angl(domain, enefunc)

    ! dihedral
    !
    call update_outgoing_enefunc_dihe(domain, enefunc)

    ! Ryckaert-Bellemans dihedral
    !
    call update_outgoing_enefunc_rb_dihe(domain, enefunc)

    ! improper dihedral
    !
    call update_outgoing_enefunc_impr(domain, enefunc)

    ! cmap
    !
    call update_outgoing_enefunc_cmap(domain, enefunc)

    ! restraint
    !
    call update_outgoing_enefunc_restraint(domain, enefunc)

    ! fitting
    !
    call update_outgoing_enefunc_fitting(domain, enefunc)

    ! communicate neighbour domain
    !
    call communicate_bond(domain, comm, enefunc)


    ! bond
    !
    call update_incoming_enefunc_bond(domain, enefunc)

    ! angle
    !
    call update_incoming_enefunc_angl(domain, enefunc)

    ! dihedral
    !
    call update_incoming_enefunc_dihe(domain, enefunc)

    ! Ryckaert-Bellemans dihedral
    !
    call update_incoming_enefunc_rb_dihe(domain, enefunc)

    ! improper dihedral
    !
    call update_incoming_enefunc_impr(domain, enefunc)

    ! cmap
    !
    call update_incoming_enefunc_cmap(domain, enefunc)

    ! restraint
    !
    call update_incoming_enefunc_restraint(domain, enefunc)

    ! fitting
    !
    call update_incoming_enefunc_fitting(domain, enefunc)

    return

  end subroutine update_enefunc_pio

  !======1=========2=========3=========4=========5=========6=========7=========8
  !
  !  Subroutine    setup_enefunc_bond_pio
  !> @brief        define BOND term for each cell in potential energy function
  !! @authors      NT
  !! @param[in]    domain  : domain information
  !! @param[inout] enefunc : potential energy functions information
  !
  !======1=========2=========3=========4=========5=========6=========7=========8

  subroutine setup_enefunc_bond_pio(domain, enefunc)

    ! formal arguments
    type(s_domain),  target, intent(in)    :: domain
    type(s_enefunc), target, intent(inout) :: enefunc

    ! local variable
    integer                  :: i, ix, ic, icel, found, ncell, ncell_pio
    integer                  :: file_num, file_tot_num
    integer,         pointer :: nwater(:)
    integer,         pointer :: bond(:), bond_list(:,:,:)
    real(wp),        pointer :: bond_force(:,:), bond_dist(:,:)
    integer,         pointer :: bond_pio(:,:), bond_list_pio(:,:,:,:)
    real(wp),        pointer :: bond_force_pio(:,:,:), bond_dist_pio(:,:,:)
    integer,         pointer :: cell_l2g_pio(:,:)
    integer(int2),   pointer :: cell_g2l(:)

    cell_l2g_pio   => domain%cell_l2g_pio
    cell_g2l       => domain%cell_g2l
    nwater         => domain%num_water
    bond           => enefunc%num_bond
    bond_list      => enefunc%bond_list
    bond_force     => enefunc%bond_force_const
    bond_dist      => enefunc%bond_dist_min
    bond_pio       => enefunc%num_bond_pio
    bond_list_pio  => enefunc%bond_list_pio
    bond_force_pio => enefunc%bond_force_const_pio
    bond_dist_pio  => enefunc%bond_dist_min_pio
    ncell          =  domain%num_cell_local
    ncell_pio      =  domain%ncell_local_pio

    file_tot_num = domain%file_tot_num
    found = 0

    do file_num = 1, file_tot_num

      do icel = 1, ncell_pio

        ic = cell_l2g_pio(icel,file_num)
        i = cell_g2l(ic)

        if (i /= 0) then

          bond(i) = bond_pio(icel,file_num)

          do ix = 1, bond(i)
            bond_list (1,ix,i) = bond_list_pio (1,ix,icel,file_num)
            bond_list (2,ix,i) = bond_list_pio (2,ix,icel,file_num)
            bond_force(  ix,i) = bond_force_pio(  ix,icel,file_num)
            bond_dist (  ix,i) = bond_dist_pio (  ix,icel,file_num)
          end do  
          found = found + bond(i) + 2*nwater(i)  !! 2 is two O-H bond from water molecules
          if (bond(i) > MaxBond) &
            call error_msg('Setup_Enefunc_Bond_Pio> Too many bonds.')

        end if

      end do
    end do
    
    enefunc%table%water_bond_calc = .true.

#ifdef MPI
    call mpi_allreduce(found, enefunc%num_bond_all, 1, mpi_integer, &
                       mpi_sum, mpi_comm_country, ierror)
#else
    enefunc%num_bond_all = found
#endif

    return

  end subroutine setup_enefunc_bond_pio

  !======1=========2=========3=========4=========5=========6=========7=========8
  !
  !  Subroutine    setup_enefunc_bond_constraint_pio
  !> @brief        define BOND term for each cell in potential energy function
  !! @authors      NT
  !! @param[in]    domain      : domain information
  !! @param[in]    constraints : constraints information
  !! @param[inout] enefunc     : potential energy functions information
  !
  !======1=========2=========3=========4=========5=========6=========7=========8

  subroutine setup_enefunc_bond_constraint_pio(domain, constraints, enefunc)

    ! formal arguments
    type(s_domain),      target, intent(in)    :: domain
    type(s_constraints), target, intent(inout) :: constraints
    type(s_enefunc),     target, intent(inout) :: enefunc

    ! local variable
    logical                  :: calc_bond
    integer                  :: i, ix, j, k, ih, ih1, ih2, i1, i2, ia, ib, ig
    integer                  :: file_num, file_tot_num
    integer                  :: found, ncel, connect, pbond
    integer                  :: icel, ncell, ncell_pio
    integer,         pointer :: bond(:), bond_pio(:,:)
    integer,         pointer :: bond_list(:,:,:), bond_list_pio(:,:,:,:)
    integer,         pointer :: HGr_local(:,:), HGr_bond_list(:,:,:,:)
    integer,         pointer :: id_l2g_sol(:,:)
    integer,         pointer :: cell_l2g_pio(:,:)
    integer(int2),   pointer :: cell_g2l(:)
    real(wp),        pointer :: bond_force(:,:), bond_force_pio(:,:,:)
    real(wp),        pointer :: bond_dist(:,:), bond_dist_pio(:,:,:)

    cell_l2g_pio   => domain%cell_l2g_pio
    cell_g2l       => domain%cell_g2l
    bond           => enefunc%num_bond
    bond_list      => enefunc%bond_list
    bond_force     => enefunc%bond_force_const
    bond_dist      => enefunc%bond_dist_min
    bond_pio       => enefunc%num_bond_pio
    bond_list_pio  => enefunc%bond_list_pio
    bond_force_pio => enefunc%bond_force_const_pio
    bond_dist_pio  => enefunc%bond_dist_min_pio

    id_l2g_sol     => domain%id_l2g_solute

    HGr_local      => constraints%HGr_local
    HGr_bond_list  => constraints%HGr_bond_list

    found = 0
    file_tot_num = domain%file_tot_num

    ncell     = domain%num_cell_local
    ncell_pio = domain%ncell_local_pio

    bond(1:ncell) = 0

    do file_num = 1, file_tot_num

      do icel = 1, ncell_pio

        ig = cell_l2g_pio(icel,file_num)
        i  = cell_g2l(ig)

        if (i /= 0) then

          do ix = 1, bond_pio(icel,file_num)

            calc_bond = .true.
            i1 = bond_list_pio(1,ix,icel,file_num)
            i2 = bond_list_pio(2,ix,icel,file_num)
        
            do j = 1, constraints%connect
              do k = 1, HGr_local(j,i)
                ia = HGr_bond_list(1,k,j,i)
                ih1 = id_l2g_sol(ia,i)
                do ih = 1, j
                  ib = HGr_bond_list(ih+1,k,j,i)
                  ih2 = id_l2g_sol(ib,i)
                  if ((ih1 == i1 .and. ih2 == i2) .or. &
                      (ih1 == i2 .and. ih2 == i1)) then
                    calc_bond = .false.
                    exit
                  end if
                end do
                if (.not.calc_bond) exit
              end do
              if (.not.calc_bond) exit
            end do
        
            if (calc_bond) then
              bond(i) = bond(i) + 1
              found = found + 1
              pbond = bond(i)
              bond_list(1,pbond,i) = i1
              bond_list(2,pbond,i) = i2
              bond_force(pbond,i) = bond_force_pio(ix,icel,file_num)
              bond_dist (pbond,i) = bond_dist_pio(ix,icel,file_num)
            end if

!           found = found + bond(i)
            if (bond(i) > MaxBond) call error_msg &
              ('Setup_Enefunc_Bond_Constraint_Pio> Too many bonds.')

          end do

        end if

      end do
    end do
#ifdef MPI
    call mpi_allreduce(found, enefunc%num_bond_all, 1, mpi_integer, &
                       mpi_sum, mpi_comm_country, ierror)
#else
    enefunc%num_bond_all = found
#endif

    ! count # of constraints bonds
    HGr_local => constraints%HGr_local

    ncel    = domain%num_cell_local
    connect = constraints%connect

    found = 0

    do i = 1, ncel
      do j = 1, connect
        do k = 1, HGr_local(j,i)
          do ih = 1, j
            found = found + 1
          end do
        end do
      end do
    end do

#ifdef MPI
    call mpi_allreduce(found, constraints%num_bonds, 1, mpi_integer, &
                       mpi_sum, mpi_comm_country, ierror)
#else
    constraints%num_bonds = found
#endif

    return

  end subroutine setup_enefunc_bond_constraint_pio

  !======1=========2=========3=========4=========5=========6=========7=========8
  !
  !  Subroutine    setup_enefunc_angl_pio
  !> @brief        define ANGLE term for each cell in potential energy function
  !! @authors      NT
  !! @param[in]    domain  : domain information
  !! @param[inout] enefunc : potential energy functions information
  !
  !======1=========2=========3=========4=========5=========6=========7=========8

  subroutine setup_enefunc_angl_pio(domain, enefunc)

    ! formal arguments
    type(s_domain),  target, intent(in)    :: domain
    type(s_enefunc), target, intent(inout) :: enefunc

    ! local variables
    integer                  :: i, ix, icel, ic, found
    integer                  :: file_num, file_tot_num
    integer,         pointer :: angle(:), angle_pio(:,:)
    integer,         pointer :: list(:,:,:), list_pio(:,:,:,:)
    integer,         pointer :: nwater(:)
    integer,         pointer :: cell_l2g_pio(:,:)
    integer(int2),   pointer :: cell_g2l(:)
    real(wp),        pointer :: force(:,:), theta(:,:)
    real(wp),        pointer :: force_pio(:,:,:), theta_pio(:,:,:)
    real(wp),        pointer :: ubforce(:,:), ubrmin(:,:)
    real(wp),        pointer :: ubforce_pio(:,:,:), ubrmin_pio(:,:,:)

    angle        => enefunc%num_angle
    list         => enefunc%angle_list
    force        => enefunc%angle_force_const
    theta        => enefunc%angle_theta_min
    ubforce      => enefunc%urey_force_const
    ubrmin       => enefunc%urey_rmin
    angle_pio    => enefunc%num_angle_pio
    list_pio     => enefunc%angle_list_pio
    force_pio    => enefunc%angle_force_const_pio
    theta_pio    => enefunc%angle_theta_min_pio
    ubforce_pio  => enefunc%urey_force_const_pio
    ubrmin_pio   => enefunc%urey_rmin_pio
    nwater       => domain%num_water
    cell_l2g_pio => domain%cell_l2g_pio
    cell_g2l     => domain%cell_g2l

    found = 0
    file_tot_num = domain%file_tot_num

    do file_num = 1, domain%file_tot_num

      do icel = 1, domain%ncell_local_pio

        ic = cell_l2g_pio(icel,file_num)
        i  = cell_g2l(ic)

        if (i /= 0) then

          angle(i)   = angle_pio(icel,file_num)

          do ix = 1, angle(i)
            list(1:3,ix,i) = list_pio(1:3,ix,icel,file_num)
            force(ix,i)   = force_pio(ix,icel,file_num)
            theta(ix,i)   = theta_pio(ix,icel,file_num)
            ubforce(ix,i) = ubforce_pio(ix,icel,file_num)
            ubrmin(ix,i)  = ubrmin_pio(ix,icel,file_num)
          end do
    
          if (enefunc%table%water_bond_calc) then
            found = found + angle(i) + nwater(i)  ! angle from water
          else
            found = found + angle(i)
          end if
 
          if (angle(i) > MaxAngle) &
            call error_msg('Setup_Enefunc_Angl_Pio> Too many angles.')

        end if

      end do
    end do

#ifdef MPI
    call mpi_allreduce(found, enefunc%num_angl_all, 1, mpi_integer, &
                       mpi_sum, mpi_comm_country, ierror)
#else
    enefunc%num_angl_all = found
#endif

    return

  end subroutine setup_enefunc_angl_pio

  !======1=========2=========3=========4=========5=========6=========7=========8
  !
  !  Subroutine    setup_enefunc_dihe_pio
  !> @brief        define DIHEDRAL term in potential energy function
  !! @authors      NT
  !! @param[in]    domain  : domain information
  !! @param[inout] enefunc : potential energy functions information
  !
  !======1=========2=========3=========4=========5=========6=========7=========8

  subroutine setup_enefunc_dihe_pio(domain, enefunc)

    ! formal arguments
    type(s_domain),   target, intent(in)    :: domain
    type(s_enefunc),  target, intent(inout) :: enefunc

    ! local variables
    integer                   :: i, ix, ic, icel, found, ncell, ncell_pio
    integer                   :: file_num, file_tot_num
    integer,          pointer :: dihedral(:), dihedral_pio(:,:)
    integer,          pointer :: list(:,:,:), list_pio(:,:,:,:)
    integer,          pointer :: period(:,:), period_pio(:,:,:)
    integer,          pointer :: cell_l2g_pio(:,:)
    integer(int2),    pointer :: cell_g2l(:)
    real(wp),         pointer :: force(:,:), force_pio(:,:,:)
    real(wp),         pointer :: phase(:,:), phase_pio(:,:,:)

    cell_l2g_pio  => domain%cell_l2g_pio
    cell_g2l      => domain%cell_g2l
    dihedral      => enefunc%num_dihedral
    list          => enefunc%dihe_list
    force         => enefunc%dihe_force_const
    period        => enefunc%dihe_periodicity
    phase         => enefunc%dihe_phase
    dihedral_pio  => enefunc%num_dihedral_pio
    list_pio      => enefunc%dihe_list_pio
    force_pio     => enefunc%dihe_force_const_pio
    period_pio    => enefunc%dihe_periodicity_pio
    phase_pio     => enefunc%dihe_phase_pio

    ncell         = domain%num_cell_local
    ncell_pio     = domain%ncell_local_pio

    found = 0

    do file_num = 1, domain%file_tot_num

      do icel = 1, ncell_pio

        ic = cell_l2g_pio(icel,file_num)
        i  = cell_g2l(ic)

        if (i /= 0) then

          dihedral(i) = dihedral_pio(icel,file_num)
          do ix = 1, dihedral(i)
            list(1:4,ix,i) = list_pio(1:4,ix,icel,file_num)
            force(ix,i) = force_pio(ix,icel,file_num)
            period(ix,i) = period_pio(ix,icel,file_num)
            phase(ix,i) = phase_pio(ix,icel,file_num)
          end do
          found = found + dihedral(i)
          if (dihedral(i) > MaxDihe) &
            call error_msg('Setup_Enefunc_Dihe_Pio> Too many dihedral angles.')
  
        end if

      end do
    end do
#ifdef MPI
    call mpi_allreduce(found, enefunc%num_dihe_all, 1, mpi_integer, &
                       mpi_sum, mpi_comm_country, ierror)
#else
    enefunc%num_dihe_all = found
#endif

    return

  end subroutine setup_enefunc_dihe_pio

  !======1=========2=========3=========4=========5=========6=========7=========8
  !
  !  Subroutine    setup_enefunc_impr_pio
  !> @brief        define IMPROPER term in potential energy function
  !! @authors      NT
  !! @param[in]    domain  : domain information
  !! @param[inout] enefunc : potential energy functions information
  !
  !======1=========2=========3=========4=========5=========6=========7=========8

  subroutine setup_enefunc_impr_pio(domain, enefunc)

    ! formal variables
    type(s_domain),   target, intent(in)    :: domain
    type(s_enefunc),  target, intent(inout) :: enefunc

    ! local variables
    integer                   :: i, ix, ic, icel, found, ncell, ncell_pio
    integer                   :: file_num, file_tot_num
    integer,          pointer :: cell_l2g_pio(:,:)
    integer(int2),    pointer :: cell_g2l(:)
    integer,          pointer :: improper(:), improper_pio(:,:)
    integer,          pointer :: list(:,:,:), list_pio(:,:,:,:)
    real(wp),         pointer :: force(:,:), force_pio(:,:,:)
    real(wp),         pointer :: phase(:,:), phase_pio(:,:,:)

    cell_l2g_pio  => domain%cell_l2g_pio
    cell_g2l      => domain%cell_g2l
    improper      => enefunc%num_improper
    list          => enefunc%impr_list
    force         => enefunc%impr_force_const
    phase         => enefunc%impr_phase
    improper_pio  => enefunc%num_improper_pio
    list_pio      => enefunc%impr_list_pio
    force_pio     => enefunc%impr_force_const_pio
    phase_pio     => enefunc%impr_phase_pio

    ncell     = domain%num_cell_local
    ncell_pio = domain%ncell_local_pio

    found = 0
    file_tot_num = domain%file_tot_num

    do file_num = 1, file_tot_num

      do icel = 1, ncell_pio

        ic = cell_l2g_pio(icel,file_num)
        i  = cell_g2l(ic)

        if (i /= 0) then

          improper(i) = improper_pio(icel,file_num)
          do ix = 1, improper(i)
            list(1:4,ix,i) = list_pio(1:4,ix,icel,file_num)
            force(ix,i) = force_pio(ix,icel,file_num)
            phase(ix,i) = phase_pio(ix,icel,file_num)
          end do
          found = found + improper(i)
          if (improper(i) > MaxImpr) &
            call error_msg( &
              'Setup_Enefunc_Impr_Pio> Too many improper dihedral angles')
 
        end if

      end do
    end do

#ifdef MPI
    call mpi_allreduce(found, enefunc%num_impr_all, 1, mpi_integer, mpi_sum, &
                       mpi_comm_country, ierror)
#else
    enefunc%num_impr_all = found
#endif

    return

  end subroutine setup_enefunc_impr_pio

  !======1=========2=========3=========4=========5=========6=========7=========8
  !
  !  Subroutine    setup_enefunc_cmap_pio
  !> @brief        define cmap term in potential energy function with DD
  !! @authors      NT
  !! @param[in]    ene_info : ENERGY section control parameters information
  !! @param[in]    domain   : domain information
  !! @param[inout] enefunc  : energy potential functions informationn
  !
  !======1=========2=========3=========4=========5=========6=========7=========8

  subroutine setup_enefunc_cmap_pio(ene_info, domain, enefunc)

    ! formal variables
    type(s_ene_info),        intent(in)    :: ene_info
    type(s_domain),  target, intent(in)    :: domain
    type(s_enefunc), target, intent(inout) :: enefunc

    ! local variables
    integer                   :: i, j, k, l, m, ix, found, ncell
    integer                   :: file_num
    integer                   :: icel, ic, ncell_pio
    integer                   :: ngrid0, ncmap_p
    integer,          pointer :: cmap(:), cmap_pio(:,:)
    integer,          pointer :: list_pio(:,:,:,:)
    integer,          pointer :: ctype_pio(:,:,:) 
    integer,          pointer :: cell_l2g_pio(:,:)
    integer(int2),    pointer :: cell_g2l(:)

    cell_l2g_pio => domain%cell_l2g_pio
    cell_g2l     => domain%cell_g2l
    cmap         => enefunc%num_cmap
    cmap_pio     => enefunc%num_cmap_pio
    list_pio     => enefunc%cmap_list_pio
    ctype_pio    => enefunc%cmap_type_pio

    ncell = domain%num_cell_local
    ncell_pio = domain%ncell_local_pio

    ngrid0  = enefunc%cmap_ngrid0
    ncmap_p = enefunc%cmap_ncmap_p

    call alloc_enefunc(enefunc, EneFuncCmap, ncell, ngrid0, ncmap_p)

    do i = 1, ncmap_p
      enefunc%cmap_resolution(i) = enefunc%cmap_resolution_pio(i)
      do m = 1, ngrid0
        do l = 1, ngrid0
          do k = 1, 4
            do j = 1, 4
              enefunc%cmap_coef(j,k,l,m,i) = enefunc%cmap_coef_pio(j,k,l,m,i)
            end do
          end do
        end do
      end do
    end do
 
    found = 0
    do file_num = 1, domain%file_tot_num

      do icel = 1, ncell_pio

        ic = cell_l2g_pio(icel,file_num)
        i  = cell_g2l(ic)

        if (i /= 0) then

          cmap(i) = cmap_pio(icel,file_num)
          do ix = 1, cmap(i)
            enefunc%cmap_list(1:8,ix,i) = list_pio(1:8,ix,icel,file_num)
            enefunc%cmap_type(ix,i) = ctype_pio(ix,icel,file_num)
          end do
          found = found + enefunc%num_cmap(i)
          if (enefunc%num_cmap(i) > MaxCmap) &
            call error_msg('Setup_Enefunc_Cmap_Pio> Too many cmaps.')

        end if

      end do
    end do

#ifdef MPI
    call mpi_allreduce(found, enefunc%num_cmap_all, 1, mpi_integer, mpi_sum, &
                       mpi_comm_country, ierror)
#else
    enefunc%num_cmap_all = found
#endif

    return

  end subroutine setup_enefunc_cmap_pio

  !======1=========2=========3=========4=========5=========6=========7=========8
  !
  !  Subroutine    setup_enefunc_nonb_pio
  !> @brief        define NON-BOND term in potential energy function
  !! @authors      NT
  !! @param[in]    ene_info    : ENERGY section control parameters information
  !! @param[in]    molecule    : molecule information
  !! @param[in]    constraints : constraints information
  !! @param[inout] domain      : domain information
  !! @param[inout] enefunc     : energy potential functions information
  !
  !======1=========2=========3=========4=========5=========6=========7=========8

  subroutine setup_enefunc_nonb_pio(ene_info, constraints, domain, enefunc)

    ! formal arguments
    type(s_ene_info),        intent(in)    :: ene_info
    type(s_constraints),     intent(in)    :: constraints
    type(s_domain),          intent(inout) :: domain
    type(s_enefunc),         intent(inout) :: enefunc

    ! local variables
    integer                  :: ncel


    ! treatment for 1-2, 1-3, 1-4 interactions
    !
    ncel   = domain%num_cell_local

    call alloc_enefunc(enefunc, EneFuncNonb,     ncel, maxcell)
    call alloc_enefunc(enefunc, EneFuncNonbList, ncel, maxcell)

    if (constraints%rigid_bond) then

      call count_nonb_excl(.true., .true., constraints, domain, enefunc)

    else

      call count_nonb_excl(.true., .false., constraints, domain, enefunc)

    end if

    return

  end subroutine setup_enefunc_nonb_pio

  !======1=========2=========3=========4=========5=========6=========7=========8
  !
  !  Subroutine    setup_enefunc_dispcorr
  !> @brief        define dispersion correction term
  !! @authors      CK
  !! @param[in]    ene_info : ENERGY section control parameters information
  !! @param[inout] domain   : domain information
  !! @param[inout] enefunc  : energy potential functions information
  !
  !======1=========2=========3=========4=========5=========6=========7=========8
  subroutine setup_enefunc_dispcorr(ene_info, domain, enefunc)

    ! formal arguments
    type(s_ene_info),        intent(in)    :: ene_info
    type(s_domain),  target, intent(inout) :: domain
    type(s_enefunc), target, intent(inout) :: enefunc

    ! local variables
    integer                  :: i, j, iatmcls, ntypes
    integer                  :: icel1, icel2, icel3, icel4
    integer                  :: i1, i2, i3, i4
    integer                  :: num_all_atoms, natom2, nexpair
    real(wip)                :: lj6_tot, lj6_diff, lj6_ex
    real(wip)                :: factor, rpair
    real(wip)                :: diff_cs, diff_cs2, diff_cs3, diff_cs4
    real(wip)                :: cutoff , cutoff2, cutoff3, cutoff4
    real(wip)                :: cutoff5, cutoff6, cutoff7, cutoff8
    real(wip)                :: cutoff14
    real(wip)                :: inv_cutoff3, inv_cutoff6, inv_cutoff12
    real(wip)                :: switchdist , switchdist2, switchdist3
    real(wip)                :: switchdist4, switchdist5
    real(wip)                :: switchdist6, switchdist7, switchdist8
    real(wip)                :: shift_a, shift_b, shift_c
    real(wip)                :: vswitch, eswitch, vlong

    integer(int2),   pointer :: id_g2l(:,:)
    integer,         pointer :: bondlist(:,:,:),anglelist(:,:,:)
    integer,         pointer :: dihelist(:,:,:),rb_dihelist(:,:,:)
    integer,         pointer :: atmcls(:,:),imprlist(:,:,:)
    integer,     allocatable :: atype(:)


    if (ene_info%dispersion_corr == Disp_corr_NONE) return

    bondlist    => enefunc%bond_list
    anglelist   => enefunc%angle_list
    dihelist    => enefunc%dihe_list
    rb_dihelist => enefunc%rb_dihe_list
    imprlist    => enefunc%impr_list
    atmcls      => domain%atom_cls_no
    id_g2l      => domain%id_g2l

    ntypes = enefunc%num_atom_cls
    allocate(atype(1:ntypes))

    atype(1:ntypes) = 0
    num_all_atoms   = 0

    do i = 1, domain%num_cell_local
      do j = 1, domain%num_atom(i)
        iatmcls = atmcls(j,i)
        atype(iatmcls) = atype(iatmcls)+1
      end do
      num_all_atoms = num_all_atoms + domain%num_atom(i)
    end do

#ifdef MPI
    call mpi_allreduce(mpi_in_place, atype, ntypes, mpi_integer, &
                       mpi_sum, mpi_comm_country, ierror)
#endif

    lj6_tot = 0.0_wip
    do i = 1, ntypes
      do j = 1, ntypes
        lj6_tot = lj6_tot + enefunc%nonb_lj6(i,j)*atype(i)*atype(j)
      end do
    end do
    deallocate(atype)

    cutoff       = enefunc%cutoffdist
    cutoff2      = cutoff*cutoff
    cutoff3      = cutoff2*cutoff
    inv_cutoff3  = 1.0_wip/cutoff3

    eswitch = 0.0_wip
    vswitch = 0.0_wip
    vlong   = inv_cutoff3/3.0_wip

    if (enefunc%forcefield == ForcefieldAMBER ) then

      factor       = 2.0_wip*PI*lj6_tot
      enefunc%dispersion_energy = -factor*vlong
      enefunc%dispersion_virial = -2.0_wip*factor*vlong

    else if (enefunc%forcefield == ForcefieldGROAMBER .or.  &
             enefunc%forcefield == ForcefieldGROMARTINI) then
      !
      ! remove exclusion
      !
      lj6_ex = 0.0_wip
      nexpair = 0
      do i = 1, domain%num_cell_local
        ! self
        do j = 1, domain%num_atom(i)
          iatmcls = atmcls(j,i)
          lj6_ex  = lj6_ex + enefunc%nonb_lj6(iatmcls,iatmcls)
        end do

        ! bonds
        do j = 1, enefunc%num_bond(i)
          icel1 = id_g2l(1,bondlist(1,j,i))
          i1    = id_g2l(2,bondlist(1,j,i))
          icel2 = id_g2l(1,bondlist(2,j,i))
          i2    = id_g2l(2,bondlist(2,j,i))
          lj6_ex= lj6_ex + enefunc%nb14_lj6(atmcls(i1,icel1),atmcls(i2,icel2))
        end do

        ! angles
        do j = 1, enefunc%num_angle(i)
          icel1 = id_g2l(1,anglelist(1,j,i))
          i1    = id_g2l(2,anglelist(1,j,i))
          icel3 = id_g2l(1,anglelist(3,j,i))
          i3    = id_g2l(2,anglelist(3,j,i))
          lj6_ex= lj6_ex + enefunc%nb14_lj6(atmcls(i1,icel1),atmcls(i3,icel3))
        end do

        ! dihedral
        do j = 1, enefunc%num_dihedral(i)
          icel1 = id_g2l(1,dihelist(1,j,i))
          i1    = id_g2l(2,dihelist(1,j,i))
          icel4 = id_g2l(1,dihelist(4,j,i))
          i4    = id_g2l(2,dihelist(4,j,i))
          lj6_ex= lj6_ex + enefunc%nb14_lj6(atmcls(i1,icel1),atmcls(i4,icel4))
        end do

        ! RB dihedral
        do j = 1, enefunc%num_rb_dihedral(i)
          icel1 = id_g2l(1,rb_dihelist(1,j,i))
          i1    = id_g2l(2,rb_dihelist(1,j,i))
          icel4 = id_g2l(1,rb_dihelist(4,j,i))
          i4    = id_g2l(2,rb_dihelist(4,j,i))
          lj6_ex= lj6_ex + enefunc%nb14_lj6(atmcls(i1,icel1),atmcls(i4,icel4))
        end do

        ! improper
        do j = 1, enefunc%num_improper(i)
          icel1 = id_g2l(1,imprlist(1,j,i))
          i1    = id_g2l(2,imprlist(1,j,i))
          icel4 = id_g2l(1,imprlist(4,j,i))
          i4    = id_g2l(2,imprlist(4,j,i))
          lj6_ex= lj6_ex + enefunc%nb14_lj6(atmcls(i1,icel1),atmcls(i4,icel4))
        end do

        nexpair = nexpair + domain%num_atom(i)        &
                          + enefunc%num_bond(i)        &
                          + enefunc%num_angle(i)       &
                          + enefunc%num_dihedral(i)    &
                          + enefunc%num_rb_dihedral(i) &
                          + enefunc%num_improper(i)
      end do
#ifdef MPI
      call mpi_allreduce(mpi_in_place, num_all_atoms, 1, mpi_integer, &
                         mpi_sum, mpi_comm_country, ierror)
      call mpi_allreduce(mpi_in_place, nexpair, 1, mpi_integer, &
                         mpi_sum, mpi_comm_country, ierror)
      call mpi_allreduce(mpi_in_place, lj6_ex, 1, mpi_wip_real, &
                         mpi_sum, mpi_comm_country, ierror)
#endif
      lj6_diff = (lj6_tot - lj6_ex)

      natom2 = num_all_atoms*num_all_atoms
      rpair  = real(natom2/(natom2-nexpair),wip)
      factor       = 2.0_wip*PI*rpair*lj6_diff

      switchdist   = enefunc%switchdist
      diff_cs      = (cutoff - switchdist)

      if (diff_cs > EPS) then

        if (enefunc%vdw_shift) then
          cutoff4      = cutoff3*cutoff
          cutoff5      = cutoff4*cutoff
          cutoff6      = cutoff5*cutoff
          cutoff7      = cutoff6*cutoff
          cutoff8      = cutoff7*cutoff
          cutoff14     = cutoff7*cutoff7
          inv_cutoff6  = inv_cutoff3*inv_cutoff3
          inv_cutoff12 = inv_cutoff6*inv_cutoff6
  
          diff_cs2     = diff_cs*diff_cs
          diff_cs3     = diff_cs2*diff_cs
          diff_cs4     = diff_cs3*diff_cs
  
          switchdist2  = switchdist*switchdist
          switchdist3  = switchdist2*switchdist
          switchdist4  = switchdist3*switchdist
          switchdist5  = switchdist4*switchdist
          switchdist6  = switchdist5*switchdist
          switchdist7  = switchdist6*switchdist
          switchdist8  = switchdist7*switchdist
  
          ! LJ6
          !
          shift_a = -(10.0_wip*cutoff - 7.0_wip*switchdist)/(cutoff8*diff_cs2)
          shift_b =  ( 9.0_wip*cutoff - 7.0_wip*switchdist)/(cutoff8*diff_cs3)
  
          shift_c = inv_cutoff6 - 2.0_wip * shift_a * diff_cs3  &
                    - 1.5_wip * shift_b * diff_cs4
  
          eswitch = -2.0_wip * shift_a * ((1.0_wip/6.0_wip)*cutoff6            &
                                        -(3.0_wip/5.0_wip)*cutoff5*switchdist  &
                                        +(3.0_wip/4.0_wip)*cutoff4*switchdist2 &
                                        -(1.0_wip/3.0_wip)*cutoff3*switchdist3 &
                                        +(1.0_wip/6.0e1_wip)*switchdist6)      &
                    -1.5_wip * shift_b * ((1.0_wip/7.0_wip)*cutoff7            &
                                        -(2.0_wip/3.0_wip)*cutoff6*switchdist  &
                                        +(6.0_wip/5.0_wip)*cutoff5*switchdist2 &
                                        -                cutoff4*switchdist3   &
                                        +(1.0_wip/3.0_wip)*cutoff3*switchdist4 &
                                        -(1.0_wip/1.05e2_wip)*switchdist7)     &
                    -(1.0_wip/3.0_wip) * shift_c * (cutoff3)
    
          ! LJ12
          !
          shift_a = -(16.0_wip*cutoff - 13.0_wip*switchdist)/(cutoff14*diff_cs2)
          shift_b =  (15.0_wip*cutoff - 13.0_wip*switchdist)/(cutoff14*diff_cs3)
          shift_c = inv_cutoff12 - 2.0_wip * shift_a * diff_cs3  &
                    - 1.5_wip * shift_b * diff_cs4
  
 
          shift_a = -(10.0_wip*cutoff - 7.0_wip*switchdist)/(cutoff8*diff_cs2)
          shift_b =  ( 9.0_wip*cutoff - 7.0_wip*switchdist)/(cutoff8*diff_cs3)
 
          vswitch = shift_a * ( (1.0_wip/6.0_wip)*cutoff6                      &
                               -(2.0_wip/5.0_wip)*cutoff5*switchdist           &
                               +(1.0_wip/4.0_wip)*cutoff4*switchdist2          &
                               -(1.0_wip/6.0e1_wip)*switchdist6)               &
                   +shift_b * ( (1.0_wip/7.0_wip)*cutoff7                      &
                               -(1.0_wip/2.0_wip)*cutoff6*switchdist           &
                               +(3.0_wip/5.0_wip)*cutoff5*switchdist2          &
                               -(1.0_wip/4.0_wip)*cutoff4*switchdist3          &
                               +(1.0_wip/1.4e2_wip)*switchdist7)
        enefunc%dispersion_energy = factor*(eswitch-vlong)
        enefunc%dispersion_virial = -2.0_wip*factor*(-vswitch+vlong)

        else

          eswitch = enefunc%eswitch
          vswitch = enefunc%vswitch
          enefunc%dispersion_energy = factor*(eswitch-vlong)
          enefunc%dispersion_virial = -factor*(vswitch+vlong)

        end if

      else 

        enefunc%dispersion_energy = factor*(eswitch-vlong)
        enefunc%dispersion_virial = -2.0_wip*factor*(-vswitch+vlong)

      end if

    else
      call error_msg('Setup_Enefunc_DispCorr> This force field is not allowed')
    end if

!   enefunc%dispersion_energy = factor*(eswitch-vlong)
!   enefunc%dispersion_virial = -2.0_wp*factor*(-vswitch+vlong)

  end subroutine setup_enefunc_dispcorr

  !======1=========2=========3=========4=========5=========6=========7=========8
  !
  !  Subroutine    check_bonding
  !> @brief        check bonds
  !! @authors      CK
  !! @param[in]    enefunc  : potential energy functions information
  !! @param[in]    domain   : domain information
  ! 
  !======1=========2=========3=========4=========5=========6=========7=========8

  subroutine check_bonding(enefunc, domain)

    ! formal arguments
    type(s_enefunc), target, intent(in)    :: enefunc
    type(s_domain),  target, intent(in)    :: domain

    ! local variables
    real(wp)                 :: d12(1:3), r12, r_dif
    integer                  :: i, j, ix, icel1, icel2, i1, i2
    integer                  :: icel3, i3,icel4, i4
    integer                  :: id, my_id, omp_get_thread_num
    real(wp), parameter      :: maxdistance = 0.5_wp
    real(wp)                 :: maxcell_size 

    real(wp),        pointer :: r0(:,:)
    integer,         pointer :: nbond(:), bondlist(:,:,:)
    integer,         pointer :: nangle(:), anglelist(:,:,:)
    integer,         pointer :: ndihe(:),  dihelist(:,:,:)
    integer,         pointer :: nrbdihe(:),  rb_dihelist(:,:,:)
    integer,         pointer :: nimpr(:),  imprlist(:,:,:)
    integer,         pointer :: ncell_local
    integer(int2),   pointer :: id_g2l(:,:)
    real(wip),       pointer :: coord(:,:,:)

    ncell_local => domain%num_cell_local
    id_g2l      => domain%id_g2l
    coord       => domain%coord

    maxcell_size = max(domain%cell_size(1),  &
                       domain%cell_size(2),  &
                       domain%cell_size(3))

    nbond       => enefunc%num_bond
    bondlist    => enefunc%bond_list
    r0          => enefunc%bond_dist_min

    nangle      => enefunc%num_angle
    anglelist   => enefunc%angle_list

    ndihe       => enefunc%num_dihedral
    dihelist    => enefunc%dihe_list

    nrbdihe     => enefunc%num_rb_dihedral
    rb_dihelist => enefunc%rb_dihe_list

    nimpr       => enefunc%num_improper
    imprlist    => enefunc%impr_list

    !$omp parallel default(shared)                                     &
    !$omp private(id, i, j, ix, icel1, i1, icel2, i2, d12, r12, r_dif, &
    !$omp         my_id, icel3, i3, icel4, i4)
    !
#ifdef OMP
    id  = omp_get_thread_num()
#else
    id  = 0
#endif
    my_id = id

    do i = my_id+1, ncell_local, nthread

      do ix = 1, nbond(i)

        icel1 = id_g2l(1,bondlist(1,ix,i))
        i1    = id_g2l(2,bondlist(1,ix,i))
        icel2 = id_g2l(1,bondlist(2,ix,i))
        i2    = id_g2l(2,bondlist(2,ix,i))

        d12(1:3) = coord(1:3,i1,icel1) - coord(1:3,i2,icel2)
        r12   = sqrt( d12(1)*d12(1) + d12(2)*d12(2) + d12(3)*d12(3) )
        r_dif = r12 - r0(ix,i)
        if (r_dif > maxdistance) &
           write(MsgOut,'(A,I10,I10,F10.5)') &
          'WARNING: too long bond:',bondlist(1,ix,i),bondlist(2,ix,i),r12
        if (r_dif < -maxdistance) &
           write(MsgOut,'(A,I10,I10,F10.5)') &
          'WARNING: too short bond:',bondlist(1,ix,i),bondlist(2,ix,i),r12
        if (r12 > maxcell_size) then
           write(MsgOut,'(A,2I10,F10.5)') &
          'Check_bonding> distance is grater than cellsize:', &
           bondlist(1,ix,i),bondlist(2,ix,i),r12
           call error_msg('')
        endif

      end do

      do ix = 1, nangle(i)

        icel1 = id_g2l(1,anglelist(1,ix,i))
        i1    = id_g2l(2,anglelist(1,ix,i))
        icel3 = id_g2l(1,anglelist(3,ix,i))
        i3    = id_g2l(2,anglelist(3,ix,i))

        d12(1:3) = coord(1:3,i1,icel1) - coord(1:3,i3,icel3)
        r12   = sqrt( d12(1)*d12(1) + d12(2)*d12(2) + d12(3)*d12(3) )

        if (r12 > maxcell_size) then
           write(MsgOut,'(A,2I10,F10.5)') &
           'Check_bonding> distance in angle is grater than cellsize:', &
           anglelist(1,ix,i),anglelist(3,ix,i),r12
           call error_msg('')
        endif

      end do

      do ix = 1, ndihe(i)

        icel1 = id_g2l(1,dihelist(1,ix,i))
        i1    = id_g2l(2,dihelist(1,ix,i))
        icel4 = id_g2l(1,dihelist(4,ix,i))
        i4    = id_g2l(2,dihelist(4,ix,i))

        d12(1:3) = coord(1:3,i1,icel1) - coord(1:3,i4,icel4)
        r12   = sqrt( d12(1)*d12(1) + d12(2)*d12(2) + d12(3)*d12(3) )

        if (r12 > maxcell_size) then
           write(MsgOut,'(A,2I10,F10.5)') &
           'Check_bonding> distance in dihedral is grater than cellsize:', &
           dihelist(1,ix,i),dihelist(4,ix,i),r12
           call error_msg('')
        endif

      end do

      if (nrbdihe(i) > 0) then
        do ix = 1, nrbdihe(i)
       
          icel1 = id_g2l(1,rb_dihelist(1,ix,i))
          i1    = id_g2l(2,rb_dihelist(1,ix,i))
          icel4 = id_g2l(1,rb_dihelist(4,ix,i))
          i4    = id_g2l(2,rb_dihelist(4,ix,i))
       
          d12(1:3) = coord(1:3,i1,icel1) - coord(1:3,i4,icel4)
          r12   = sqrt( d12(1)*d12(1) + d12(2)*d12(2) + d12(3)*d12(3) )
          if (r12 > maxcell_size) then
            write(MsgOut,'(A,2I10,F10.5)') &
           'Check_bonding> distance in rb dihedral is grater than cellsize:', &
            rb_dihelist(1,ix,i), rb_dihelist(4,ix,i),r12
            call error_msg('')
          endif
       
        end do
      endif

      do ix = 1, nimpr(i)

        icel1 = id_g2l(1,imprlist(1,ix,i))
        i1    = id_g2l(2,imprlist(1,ix,i))
        icel4 = id_g2l(1,imprlist(4,ix,i))
        i4    = id_g2l(2,imprlist(4,ix,i))

        d12(1:3) = coord(1:3,i1,icel1) - coord(1:3,i4,icel4)
        r12   = sqrt( d12(1)*d12(1) + d12(2)*d12(2) + d12(3)*d12(3) )

        if (r12 > maxcell_size) then
          write(MsgOut,'(A,2I10,F10.5)') &
      'Check_bonding> distance in improper dihedral is grater than cellsize:', &
          imprlist(1,ix,i), imprlist(4,ix,i),r12
          call error_msg('')
        endif
      end do

    end do

    !$omp end parallel 

    return

  end subroutine check_bonding

end module sp_enefunc_mod
