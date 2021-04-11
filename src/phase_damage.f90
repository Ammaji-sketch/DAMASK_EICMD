!----------------------------------------------------------------------------------------------------
!> @brief internal microstructure state for all damage sources and kinematics constitutive models
!----------------------------------------------------------------------------------------------------
submodule(phase) damage

  type :: tDamageParameters
    real(pReal) ::                 mu = 0.0_pReal                                                   !< viscosity
    real(pReal), dimension(3,3) :: K  = 0.0_pReal                                                   !< conductivity/diffusivity
  end type tDamageParameters

  enum, bind(c); enumerator :: &
    DAMAGE_UNDEFINED_ID, &
    DAMAGE_ISOBRITTLE_ID, &
    DAMAGE_ISODUCTILE_ID, &
    DAMAGE_ANISOBRITTLE_ID, &
    DAMAGE_ANISODUCTILE_ID
  end enum


  type :: tDataContainer
    real(pReal), dimension(:), allocatable :: phi, d_phi_d_dot_phi
  end type tDataContainer

  integer(kind(DAMAGE_UNDEFINED_ID)),     dimension(:), allocatable :: &
    phase_source                                                                                    !< active sources mechanisms of each phase

  integer, dimension(:), allocatable :: &
    phase_Nsources

  type(tDataContainer), dimension(:), allocatable :: current

  type(tDamageParameters), dimension(:), allocatable :: param

  interface

    module function anisobrittle_init() result(mySources)
      logical, dimension(:), allocatable :: mySources
    end function anisobrittle_init

    module function anisoductile_init() result(mySources)
      logical, dimension(:), allocatable :: mySources
    end function anisoductile_init

    module function isobrittle_init() result(mySources)
      logical, dimension(:), allocatable :: mySources
    end function isobrittle_init

    module function isoductile_init() result(mySources)
      logical, dimension(:), allocatable :: mySources
    end function isoductile_init


    module subroutine isobrittle_deltaState(C, Fe, ph, me)
      integer, intent(in) :: ph,me
      real(pReal),  intent(in), dimension(3,3) :: &
        Fe
      real(pReal),  intent(in), dimension(6,6) :: &
        C
    end subroutine isobrittle_deltaState


    module subroutine anisobrittle_dotState(S, ph, me)
      integer, intent(in) :: ph,me
      real(pReal),  intent(in), dimension(3,3) :: &
        S
    end subroutine anisobrittle_dotState

    module subroutine anisoductile_dotState(ph,me)
      integer, intent(in) :: ph,me
    end subroutine anisoductile_dotState

    module subroutine isoductile_dotState(ph,me)
      integer, intent(in) :: ph,me
    end subroutine isoductile_dotState

    module subroutine anisobrittle_results(phase,group)
      integer,          intent(in) :: phase
      character(len=*), intent(in) :: group
    end subroutine anisobrittle_results

    module subroutine anisoductile_results(phase,group)
      integer,          intent(in) :: phase
      character(len=*), intent(in) :: group
    end subroutine anisoductile_results

    module subroutine isobrittle_results(phase,group)
      integer,          intent(in) :: phase
      character(len=*), intent(in) :: group
    end subroutine isobrittle_results

    module subroutine isoductile_results(phase,group)
      integer,          intent(in) :: phase
      character(len=*), intent(in) :: group
    end subroutine isoductile_results

 end interface

contains

!----------------------------------------------------------------------------------------------
!< @brief initialize damage sources and kinematics mechanism
!----------------------------------------------------------------------------------------------
module subroutine damage_init

  integer :: &
    ph, &                                                                                           !< counter in phase loop
    Nmembers
  class(tNode), pointer :: &
   phases, &
   phase, &
   sources


  print'(/,a)', ' <<<+-  phase:damage init  -+>>>'

  phases => config_material%get('phase')

  allocate(current(phases%length))

  allocate(damageState (phases%length))
  allocate(phase_Nsources(phases%length),source = 0)
  allocate(param(phases%length))

  do ph = 1,phases%length

    Nmembers = count(material_phaseID == ph)

    allocate(current(ph)%phi(Nmembers),source=1.0_pReal)
    allocate(current(ph)%d_phi_d_dot_phi(Nmembers),source=0.0_pReal)

    phase => phases%get(ph)
    sources => phase%get('damage',defaultVal=emptyList)
    param(ph)%K(1,1) = sources%get_asFloat('K_11',defaultVal=0.0_pReal)
    param(ph)%K(2,2) = sources%get_asFloat('K_22',defaultVal=0.0_pReal)
    param(ph)%K(3,3) = sources%get_asFloat('K_33',defaultVal=0.0_pReal)
    if (sources%length > 1) error stop
    phase_Nsources(ph) = sources%length

  enddo

  allocate(phase_source(phases%length), source = DAMAGE_UNDEFINED_ID)

! initialize source mechanisms
  if(maxval(phase_Nsources) /= 0) then
    where(isobrittle_init()  ) phase_source = DAMAGE_ISOBRITTLE_ID
    where(isoductile_init()  ) phase_source = DAMAGE_ISODUCTILE_ID
    where(anisobrittle_init()) phase_source = DAMAGE_ANISOBRITTLE_ID
    where(anisoductile_init()) phase_source = DAMAGE_ANISODUCTILE_ID
  endif

end subroutine damage_init


!----------------------------------------------------------------------------------------------
!< @brief returns local part of nonlocal damage driving force
!----------------------------------------------------------------------------------------------
module function phase_f_phi(phi,co,ce) result(f)

  integer, intent(in) :: ce,co
  real(pReal), intent(in) :: &
    phi                                                                                             !< damage parameter
  real(pReal) :: &
    f

  integer :: &
    ph, &
    en

  ph = material_phaseID(co,ce)
  en = material_phaseEntry(co,ce)

  select case(phase_source(ph))
    case(DAMAGE_ISOBRITTLE_ID,DAMAGE_ISODUCTILE_ID,DAMAGE_ANISOBRITTLE_ID,DAMAGE_ANISODUCTILE_ID)
      f = 1.0_pReal &
        - phi*damageState(ph)%state(1,en)
    case default
      f = 0.0_pReal
  end select

end function phase_f_phi



!--------------------------------------------------------------------------------------------------
!> @brief integrate stress, state with adaptive 1st order explicit Euler method
!> using Fixed Point Iteration to adapt the stepsize
!--------------------------------------------------------------------------------------------------
module function integrateDamageState(dt,co,ip,el) result(broken)

  real(pReal), intent(in) :: dt
  integer, intent(in) :: &
    el, &                                                                                            !< element index in element loop
    ip, &                                                                                            !< integration point index in ip loop
    co                                                                                               !< grain index in grain loop
  logical :: broken

  integer :: &
    NiterationState, &                                                                              !< number of iterations in state loop
    ph, &
    me, &
    size_so
  real(pReal) :: &
    zeta
  real(pReal), dimension(phase_source_maxSizeDotState) :: &
    r                                                                                               ! state residuum
  real(pReal), dimension(phase_source_maxSizeDotState,2) :: source_dotState
  logical :: &
    converged_

  ph = material_phaseAt(co,el)
  me = material_phaseMemberAt(co,ip,el)

  if (damageState(ph)%sizeState == 0) then
    broken = .false.
    return
  endif

  converged_ = .true.
  broken = phase_damage_collectDotState(ph,me)
  if(broken) return

    size_so = damageState(ph)%sizeDotState
    damageState(ph)%state(1:size_so,me) = damageState(ph)%subState0(1:size_so,me) &
                                        + damageState(ph)%dotState (1:size_so,me) * dt
    source_dotState(1:size_so,2) = 0.0_pReal

  iteration: do NiterationState = 1, num%nState

    if(nIterationState > 1) source_dotState(1:size_so,2) = source_dotState(1:size_so,1)
    source_dotState(1:size_so,1) = damageState(ph)%dotState(:,me)

    broken = phase_damage_collectDotState(ph,me)
    if(broken) exit iteration


      zeta = damper(damageState(ph)%dotState(:,me),source_dotState(1:size_so,1),source_dotState(1:size_so,2))
      damageState(ph)%dotState(:,me) = damageState(ph)%dotState(:,me) * zeta &
                                    + source_dotState(1:size_so,1)* (1.0_pReal - zeta)
      r(1:size_so) = damageState(ph)%state    (1:size_so,me)  &
                   - damageState(ph)%subState0(1:size_so,me)  &
                   - damageState(ph)%dotState (1:size_so,me) * dt
      damageState(ph)%state(1:size_so,me) = damageState(ph)%state(1:size_so,me) - r(1:size_so)
      converged_ = converged_  .and. converged(r(1:size_so), &
                                               damageState(ph)%state(1:size_so,me), &
                                               damageState(ph)%atol(1:size_so))


    if(converged_) then
      broken = phase_damage_deltaState(mechanical_F_e(ph,me),ph,me)
      exit iteration
    endif

  enddo iteration

  broken = broken .or. .not. converged_


  contains

  !--------------------------------------------------------------------------------------------------
  !> @brief calculate the damping for correction of state and dot state
  !--------------------------------------------------------------------------------------------------
  real(pReal) pure function damper(current,previous,previous2)

  real(pReal), dimension(:), intent(in) ::&
    current, previous, previous2

  real(pReal) :: dot_prod12, dot_prod22

  dot_prod12 = dot_product(current  - previous,  previous - previous2)
  dot_prod22 = dot_product(previous - previous2, previous - previous2)
  if ((dot_product(current,previous) < 0.0_pReal .or. dot_prod12 < 0.0_pReal) .and. dot_prod22 > 0.0_pReal) then
    damper = 0.75_pReal + 0.25_pReal * tanh(2.0_pReal + 4.0_pReal * dot_prod12 / dot_prod22)
  else
    damper = 1.0_pReal
  endif

  end function damper

end function integrateDamageState


!----------------------------------------------------------------------------------------------
!< @brief writes damage sources results to HDF5 output file
!----------------------------------------------------------------------------------------------
module subroutine damage_results(group,ph)

  character(len=*), intent(in) :: group
  integer,          intent(in) :: ph

  integer :: so

  sourceLoop: do so = 1, phase_Nsources(ph)

  if (phase_source(ph) /= DAMAGE_UNDEFINED_ID) &
    call results_closeGroup(results_addGroup(group//'damage'))

    sourceType: select case (phase_source(ph))

      case (DAMAGE_ISOBRITTLE_ID) sourceType
        call isobrittle_results(ph,group//'damage/')

      case (DAMAGE_ISODUCTILE_ID) sourceType
        call isoductile_results(ph,group//'damage/')

      case (DAMAGE_ANISOBRITTLE_ID) sourceType
        call anisobrittle_results(ph,group//'damage/')

      case (DAMAGE_ANISODUCTILE_ID) sourceType
        call anisoductile_results(ph,group//'damage/')

    end select sourceType

  enddo SourceLoop

end subroutine damage_results


!--------------------------------------------------------------------------------------------------
!> @brief contains the constitutive equation for calculating the rate of change of microstructure
!--------------------------------------------------------------------------------------------------
function phase_damage_collectDotState(ph,me) result(broken)

  integer, intent(in) :: &
    ph, &
    me                                                                                         !< counter in source loop
  logical :: broken


  broken = .false.

  if (damageState(ph)%sizeState > 0) then

    sourceType: select case (phase_source(ph))

      case (DAMAGE_ISODUCTILE_ID) sourceType
        call isoductile_dotState(ph,me)

      case (DAMAGE_ANISODUCTILE_ID) sourceType
        call anisoductile_dotState(ph,me)

      case (DAMAGE_ANISOBRITTLE_ID) sourceType
        call anisobrittle_dotState(mechanical_S(ph,me), ph,me) ! correct stress?

    end select sourceType

    broken = broken .or. any(IEEE_is_NaN(damageState(ph)%dotState(:,me)))

  endif

end function phase_damage_collectDotState



!--------------------------------------------------------------------------------------------------
!> @brief for constitutive models having an instantaneous change of state
!> will return false if delta state is not needed/supported by the constitutive model
!--------------------------------------------------------------------------------------------------
function phase_damage_deltaState(Fe, ph, me) result(broken)

  integer, intent(in) :: &
    ph, &
    me
  real(pReal),   intent(in), dimension(3,3) :: &
    Fe                                                                                              !< elastic deformation gradient
  integer :: &
    myOffset, &
    mySize
  logical :: &
    broken


  broken = .false.

  if (damageState(ph)%sizeState == 0) return

     sourceType: select case (phase_source(ph))

      case (DAMAGE_ISOBRITTLE_ID) sourceType
        call isobrittle_deltaState(phase_homogenizedC(ph,me), Fe, ph,me)
        broken = any(IEEE_is_NaN(damageState(ph)%deltaState(:,me)))
        if(.not. broken) then
          myOffset = damageState(ph)%offsetDeltaState
          mySize   = damageState(ph)%sizeDeltaState
          damageState(ph)%state(myOffset + 1: myOffset + mySize,me) = &
          damageState(ph)%state(myOffset + 1: myOffset + mySize,me) + damageState(ph)%deltaState(1:mySize,me)
        endif

    end select sourceType


end function phase_damage_deltaState


!--------------------------------------------------------------------------------------------------
!> @brief checks if a source mechanism is active or not
!--------------------------------------------------------------------------------------------------
function source_active(source_label)  result(active_source)

  character(len=*), intent(in)         :: source_label                                              !< name of source mechanism
  logical, dimension(:), allocatable  :: active_source

  class(tNode), pointer :: &
    phases, &
    phase, &
    sources, &
    src
  integer :: ph

  phases => config_material%get('phase')
  allocate(active_source(phases%length))
  do ph = 1, phases%length
    phase => phases%get(ph)
    sources => phase%get('damage',defaultVal=emptyList)
    src => sources%get(1)
    active_source(ph) = src%get_asString('type',defaultVal = 'x') == source_label
  enddo


end function source_active


!----------------------------------------------------------------------------------------------
!< @brief Set damage parameter
!----------------------------------------------------------------------------------------------
module subroutine phase_set_phi(phi,co,ce)

  real(pReal), intent(in) :: phi
  integer, intent(in) :: ce, co


  current(material_phaseID(co,ce))%phi(material_phaseEntry(co,ce)) = phi

end subroutine phase_set_phi


module function damage_phi(ph,me) result(phi)

  integer, intent(in) :: ph, me
  real(pReal) :: phi


  phi = current(ph)%phi(me)

end function damage_phi



!--------------------------------------------------------------------------------------------------
!> @brief Forward data after successful increment.
!--------------------------------------------------------------------------------------------------
module subroutine damage_forward()

  integer :: ph


  do ph = 1, size(damageState)
    if (damageState(ph)%sizeState > 0) &
      damageState(ph)%state0 = damageState(ph)%state
  enddo

end subroutine damage_forward


end submodule damage
