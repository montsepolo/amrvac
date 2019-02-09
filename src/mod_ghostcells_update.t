!> update ghost cells of all blocks including physical boundaries 
module mod_ghostcells_update

  implicit none
  ! Special buffer for pole copy
  type wbuffer
    double precision, dimension(:^D&,:), allocatable :: w
  end type wbuffer

  ! A switch of update physical boundary or not
  logical, public :: bcphys=.true.
  integer :: ixM^L, ixCoG^L, ixCoM^L

  ! The number of interleaving sending buffers for ghost cells
  integer, parameter :: npwbuf=2

  ! The first index goes from -1:2, where -1 is used when a block touches the
  ! lower boundary, 1 when a block touches an upper boundary, and 0 a situation
  ! away from boundary conditions, 2 when a block touched both lower and upper
  ! boundary

  ! index ranges to send (S) to sibling blocks, receive (R) from 
  ! sibling blocks, send restricted (r) ghost cells to coarser blocks 
  integer, dimension(-1:2,-1:1) :: ixS_srl_^L, ixR_srl_^L, ixS_r_^L

  ! index ranges to receive restriced ghost cells from finer blocks, 
  ! send prolongated (p) ghost cells to finer blocks, receive prolongated 
  ! ghost from coarser blocks
  integer, dimension(-1:1, 0:3) :: ixR_r_^L, ixS_p_^L, ixR_p_^L

  integer, dimension(^ND,-1:1) :: ixS_srl_stg_^L, ixR_srl_stg_^L
  integer, dimension(^ND,-1:1) :: ixS_r_stg_^L
  integer, dimension(^ND,0:3)  :: ixS_p_stg_^L, ixR_p_stg_^L
  integer, dimension(^ND,0:3)  :: ixR_r_stg_^L

  ! number of MPI receive-send pairs, srl: same refinement level; r: restrict; p: prolong
  integer :: nrecv_bc_srl, nsend_bc_srl, nrecv_bc_r, nsend_bc_r, nrecv_bc_p, nsend_bc_p

  ! total size of buffer arrays
  integer :: nbuff_bc_recv_srl, nbuff_bc_send_srl, nbuff_bc_recv_r, nbuff_bc_send_r, nbuff_bc_recv_p, nbuff_bc_send_p

  ! sizes to send and receive for siblings
  integer, dimension(-1:1^D&) :: sizes_srl_send, sizes_srl_recv

  ! total sizes = cell-center normal flux + stagger-grid flux of send and receive
  integer, dimension(-1:1^D&) :: sizes_srl_send_total, sizes_srl_recv_total

  ! sizes of buffer arrays for stagger-grid variable
  integer, dimension(^ND,-1:1^D&) :: sizes_srl_send_stg, sizes_srl_recv_stg

  integer, dimension(:), allocatable :: recvrequest_srl, sendrequest_srl
  integer, dimension(:,:), allocatable :: recvstatus_srl, sendstatus_srl
 
  ! buffer arrays for send and receive of siblings
  double precision, dimension(:), allocatable :: recvbuffer_srl, sendbuffer_srl

  integer, dimension(:), allocatable :: recvrequest_r, sendrequest_r
  integer, dimension(:,:), allocatable :: recvstatus_r, sendstatus_r

  ! buffer arrays for send and receive in restriction
  double precision, dimension(:), allocatable :: recvbuffer_r, sendbuffer_r

  ! sizes to allocate buffer arrays for send and receive for restriction
  integer, dimension(-1:1^D&)     :: sizes_r_send
  integer, dimension(0:3^D&)      :: sizes_r_recv
  integer, dimension(^ND,-1:1^D&) :: sizes_r_send_stg
  integer, dimension(^ND,0:3^D&)  :: sizes_r_recv_stg
  integer, dimension(-1:1^D&)     :: sizes_r_send_total
  integer, dimension(0:3^D&)      :: sizes_r_recv_total


  integer, dimension(0:3^D&)      :: sizes_p_send, sizes_p_recv
  integer, dimension(^ND,0:3^D&)  :: sizes_p_send_stg, sizes_p_recv_stg
  integer, dimension(0:3^D&)      :: sizes_p_send_total, sizes_p_recv_total

  integer, dimension(:), allocatable :: recvrequest_p, sendrequest_p
  integer, dimension(:,:), allocatable :: recvstatus_p, sendstatus_p

  double precision, dimension(:), allocatable :: recvbuffer_p, sendbuffer_p
  ! index pointer for buffer arrays as a start for a segment
  integer :: ibuf_start

  ! MPI derived datatype to send and receive subarrays of ghost cells to
  ! neighbor blocks in a different processor.
  !
  ! There are two variants, _f indicates that all flux variables are filled,
  ! whereas _p means that part of the variables is filled 
  ! Furthermore _r_ stands for restrict, _p_ for prolongation.
  integer, dimension(-1:2^D&,-1:1^D&), target :: type_send_srl_f, type_recv_srl_f
  integer, dimension(-1:1^D&,-1:1^D&), target :: type_send_r_f
  integer, dimension(-1:1^D&, 0:3^D&), target :: type_recv_r_f, type_send_p_f, type_recv_p_f
  integer, dimension(-1:2^D&,-1:1^D&), target :: type_send_srl_p1, type_recv_srl_p1
  integer, dimension(-1:1^D&,-1:1^D&), target :: type_send_r_p1
  integer, dimension(-1:1^D&, 0:3^D&), target :: type_recv_r_p1, type_send_p_p1, type_recv_p_p1
  integer, dimension(-1:2^D&,-1:1^D&), target :: type_send_srl_p2, type_recv_srl_p2
  integer, dimension(-1:1^D&,-1:1^D&), target :: type_send_r_p2
  integer, dimension(-1:1^D&, 0:3^D&), target :: type_recv_r_p2, type_send_p_p2, type_recv_p_p2
  integer, dimension(:^D&,:^D&), pointer :: type_send_srl, type_recv_srl, type_send_r
  integer, dimension(:^D&,:^D&), pointer :: type_recv_r, type_send_p, type_recv_p

contains

  subroutine init_bc()
    use mod_global_parameters 
    use mod_physics, only: phys_req_diagonal

    integer :: nghostcellsCo, interpolation_order
    integer :: nx^D, nxCo^D, ixG^L, i^D, ic^D, inc^D, idir

    ixG^L=ixG^LL;
    ixM^L=ixG^L^LSUBnghostcells;
    ixCoGmin^D=1;
    !ixCoGmax^D=ixGmax^D/2+nghostcells;
    ixCoGmax^D=(ixGhi^D-2*nghostcells)/2+2*nghostcells;

    ixCoM^L=ixCoG^L^LSUBnghostcells;

    nx^D=ixMmax^D-ixMmin^D+1;
    nxCo^D=nx^D/2;
    
    select case (typeghostfill)
    case ("copy")
       interpolation_order=1
    case ("linear")
       interpolation_order=2
    case default
       write (unitterm,*) "Undefined typeghostfill ",typeghostfill
       call mpistop("Undefined typeghostfill")
    end select
    nghostcellsCo=int((nghostcells+1)/2)
    
    if (nghostcellsCo+interpolation_order-1>nghostcells) then
       call mpistop("interpolation order for prolongation in getbc too high")
    end if
    
    if (stagger_grid) then
      ! Staggered (face-allocated) variables
      do idir=1,ndim
      { ixS_srl_stg_min^D(idir,-1)=ixMmin^D-kr(idir,^D)
        ixS_srl_stg_max^D(idir,-1)=ixMmin^D-1+nghostcells
        ixS_srl_stg_min^D(idir,0) =ixMmin^D-kr(idir,^D)
        ixS_srl_stg_max^D(idir,0) =ixMmax^D
        ixS_srl_stg_min^D(idir,1) =ixMmax^D-nghostcells+1-kr(idir,^D)
        ixS_srl_stg_max^D(idir,1) =ixMmax^D
        
        ixR_srl_stg_min^D(idir,-1)=1-kr(idir,^D)
        ixR_srl_stg_max^D(idir,-1)=nghostcells
        ixR_srl_stg_min^D(idir,0) =ixMmin^D-kr(idir,^D)
        ixR_srl_stg_max^D(idir,0) =ixMmax^D
        ixR_srl_stg_min^D(idir,1) =ixMmax^D+1-kr(idir,^D)
        ixR_srl_stg_max^D(idir,1) =ixGmax^D

        ixS_r_stg_min^D(idir,-1)=ixCoMmin^D-kr(idir,^D)
        ixS_r_stg_max^D(idir,-1)=ixCoMmin^D-1+nghostcells
        ixS_r_stg_min^D(idir,0) =ixCoMmin^D-kr(idir,^D)
        ixS_r_stg_max^D(idir,0) =ixCoMmax^D
        ixS_r_stg_min^D(idir,1) =ixCoMmax^D+1-nghostcells-kr(idir,^D)
        ixS_r_stg_max^D(idir,1) =ixCoMmax^D
 
        ixR_r_stg_min^D(idir,0)=1-kr(idir,^D)
        ixR_r_stg_max^D(idir,0)=nghostcells
        ixR_r_stg_min^D(idir,1)=ixMmin^D-kr(idir,^D)
        ixR_r_stg_max^D(idir,1)=ixMmin^D-1+nxCo^D
        ixR_r_stg_min^D(idir,2)=ixMmin^D+nxCo^D-kr(idir,^D)
        ixR_r_stg_max^D(idir,2)=ixMmax^D
        ixR_r_stg_min^D(idir,3)=ixMmax^D+1-kr(idir,^D)
        ixR_r_stg_max^D(idir,3)=ixGmax^D
        \}
       {if (idir==^D) then
          ! Parallel components
          {
          ixS_p_stg_min^D(idir,0)=ixMmin^D-1 ! -1 to make redundant 
          ixS_p_stg_max^D(idir,0)=ixMmin^D-1+nghostcellsCo
          ixS_p_stg_min^D(idir,1)=ixMmin^D-1 ! -1 to make redundant 
          ixS_p_stg_max^D(idir,1)=ixMmin^D-1+nxCo^D+nghostcellsCo
          ixS_p_stg_min^D(idir,2)=ixMmax^D-nxCo^D-nghostcellsCo
          ixS_p_stg_max^D(idir,2)=ixMmax^D
          ixS_p_stg_min^D(idir,3)=ixMmax^D-nghostcellsCo
          ixS_p_stg_max^D(idir,3)=ixMmax^D

          ixR_p_stg_min^D(idir,0)=ixCoMmin^D-1-nghostcellsCo
          ixR_p_stg_max^D(idir,0)=ixCoMmin^D-1
          ixR_p_stg_min^D(idir,1)=ixCoMmin^D-1 ! -1 to make redundant 
          ixR_p_stg_max^D(idir,1)=ixCoMmax^D+nghostcellsCo
          ixR_p_stg_min^D(idir,2)=ixCoMmin^D-1-nghostcellsCo
          ixR_p_stg_max^D(idir,2)=ixCoMmax^D
          ixR_p_stg_min^D(idir,3)=ixCoMmax^D+1-1 ! -1 to make redundant 
          ixR_p_stg_max^D(idir,3)=ixCoMmax^D+nghostcellsCo
          \}
        else
          {
          ! Perpendicular component
          ixS_p_stg_min^D(idir,0)=ixMmin^D
          ixS_p_stg_max^D(idir,0)=ixMmin^D-1+nghostcellsCo+(interpolation_order-1)
          ixS_p_stg_min^D(idir,1)=ixMmin^D
          ixS_p_stg_max^D(idir,1)=ixMmin^D-1+nxCo^D+nghostcellsCo+(interpolation_order-1)
          ixS_p_stg_min^D(idir,2)=ixMmax^D+1-nxCo^D-nghostcellsCo-(interpolation_order-1)
          ixS_p_stg_max^D(idir,2)=ixMmax^D
          ixS_p_stg_min^D(idir,3)=ixMmax^D+1-nghostcellsCo-(interpolation_order-1)
          ixS_p_stg_max^D(idir,3)=ixMmax^D
 
          ixR_p_stg_min^D(idir,0)=ixCoMmin^D-nghostcellsCo-(interpolation_order-1)
          ixR_p_stg_max^D(idir,0)=ixCoMmin^D-1
          ixR_p_stg_min^D(idir,1)=ixCoMmin^D
          ixR_p_stg_max^D(idir,1)=ixCoMmax^D+nghostcellsCo+(interpolation_order-1)
          ixR_p_stg_min^D(idir,2)=ixCoMmin^D-nghostcellsCo-(interpolation_order-1)
          ixR_p_stg_max^D(idir,2)=ixCoMmax^D
          ixR_p_stg_min^D(idir,3)=ixCoMmax^D+1
          ixR_p_stg_max^D(idir,3)=ixCoMmax^D+nghostcellsCo+(interpolation_order-1)
          \}
        end if
        }
      end do
    end if

    ! (iib,i) index has following meanings: iib = 0 means it is not at any physical boundary
    ! iib=-1 means it is at the minimum side of a physical boundary  
    ! iib= 1 means it is at the maximum side of a physical boundary  
    ! i=-1 means subregion prepared for the neighbor at its minimum side 
    ! i= 1 means subregion prepared for the neighbor at its maximum side 

    ! index limits for siblings
    {
    ixS_srl_min^D(:,-1)=ixMmin^D
    ixS_srl_min^D(:, 1)=ixMmax^D+1-nghostcells
    ixS_srl_max^D(:,-1)=ixMmin^D-1+nghostcells
    ixS_srl_max^D(:, 1)=ixMmax^D
    
    ixS_srl_min^D(-1,0)=1
    ixS_srl_min^D( 0,0)=ixMmin^D
    ixS_srl_min^D( 1,0)=ixMmin^D
    ixS_srl_min^D( 2,0)=1
    ixS_srl_max^D(-1,0)=ixMmax^D
    ixS_srl_max^D( 0,0)=ixMmax^D
    ixS_srl_max^D( 1,0)=ixGmax^D
    ixS_srl_max^D( 2,0)=ixGmax^D
     
    ixR_srl_min^D(:,-1)=1
    ixR_srl_min^D(:, 1)=ixMmax^D+1
    ixR_srl_max^D(:,-1)=nghostcells
    ixR_srl_max^D(:, 1)=ixGmax^D
    
    ixR_srl_min^D(-1,0)=1
    ixR_srl_min^D( 0,0)=ixMmin^D
    ixR_srl_min^D( 1,0)=ixMmin^D
    ixR_srl_min^D( 2,0)=1
    ixR_srl_max^D(-1,0)=ixMmax^D
    ixR_srl_max^D( 0,0)=ixMmax^D
    ixR_srl_max^D( 1,0)=ixGmax^D
    ixR_srl_max^D( 2,0)=ixGmax^D
    \}

    ! index limits for restrict
    { 
    ixS_r_min^D(:,-1)=ixCoMmin^D
    ixS_r_min^D(:, 1)=ixCoMmax^D+1-nghostcells
    ixS_r_max^D(:,-1)=ixCoMmin^D-1+nghostcells
    ixS_r_max^D(:, 1)=ixCoMmax^D
    
    ixS_r_min^D(-1,0)=1
    ixS_r_min^D( 0,0)=ixCoMmin^D
    ixS_r_min^D( 1,0)=ixCoMmin^D
    ixS_r_max^D(-1,0)=ixCoMmax^D
    ixS_r_max^D( 0,0)=ixCoMmax^D
    ixS_r_max^D( 1,0)=ixCoGmax^D
    
    ixR_r_min^D(:, 0)=1
    ixR_r_min^D(:, 1)=ixMmin^D
    ixR_r_min^D(:, 2)=ixMmin^D+nxCo^D
    ixR_r_min^D(:, 3)=ixMmax^D+1
    ixR_r_max^D(:, 0)=nghostcells
    ixR_r_max^D(:, 1)=ixMmin^D-1+nxCo^D
    ixR_r_max^D(:, 2)=ixMmax^D
    ixR_r_max^D(:, 3)=ixGmax^D

    ixR_r_min^D(-1,1)=1
    ixR_r_max^D(-1,1)=ixMmin^D-1+nxCo^D
    ixR_r_min^D( 1,2)=ixMmin^D+nxCo^D
    ixR_r_max^D( 1,2)=ixGmax^D
    \}

    ! index limits for prolong
    {
    ixS_p_min^D(:, 0)=ixMmin^D-(interpolation_order-1)
    ixS_p_min^D(:, 1)=ixMmin^D-(interpolation_order-1)
    ixS_p_min^D(:, 2)=ixMmin^D+nxCo^D-nghostcellsCo-(interpolation_order-1)
    ixS_p_min^D(:, 3)=ixMmax^D+1-nghostcellsCo-(interpolation_order-1)
    ixS_p_max^D(:, 0)=ixMmin^D-1+nghostcellsCo+(interpolation_order-1)
    ixS_p_max^D(:, 1)=ixMmin^D-1+nxCo^D+nghostcellsCo+(interpolation_order-1)
    ixS_p_max^D(:, 2)=ixMmax^D+(interpolation_order-1)
    ixS_p_max^D(:, 3)=ixMmax^D+(interpolation_order-1)

    if(.not.phys_req_diagonal) then
      ! exclude ghost-cell region when diagonal cells are unknown
      ixS_p_min^D(:, 0)=ixMmin^D
      ixS_p_max^D(:, 3)=ixMmax^D
      ixS_p_max^D(:, 1)=ixMmin^D-1+nxCo^D+(interpolation_order-1)
      ixS_p_min^D(:, 2)=ixMmin^D+nxCo^D-(interpolation_order-1)
    end if

    ! extend index range to physical boundary
    ixS_p_min^D(-1,1)=1
    ixS_p_max^D( 1,2)=ixGmax^D

    ixR_p_min^D(:, 0)=ixCoMmin^D-nghostcellsCo-(interpolation_order-1)
    ixR_p_min^D(:, 1)=ixCoMmin^D-(interpolation_order-1)
    ixR_p_min^D(:, 2)=ixCoMmin^D-nghostcellsCo-(interpolation_order-1)
    ixR_p_min^D(:, 3)=ixCoMmax^D+1-(interpolation_order-1)
    ixR_p_max^D(:, 0)=nghostcells+(interpolation_order-1)
    ixR_p_max^D(:, 1)=ixCoMmax^D+nghostcellsCo+(interpolation_order-1)
    ixR_p_max^D(:, 2)=ixCoMmax^D+(interpolation_order-1)
    ixR_p_max^D(:, 3)=ixCoMmax^D+nghostcellsCo+(interpolation_order-1)

    if(.not.phys_req_diagonal) then
      ! exclude ghost-cell region when diagonal cells are unknown
      ixR_p_max^D(:, 0)=nghostcells
      ixR_p_min^D(:, 3)=ixCoMmax^D+1
      ixR_p_max^D(:, 1)=ixCoMmax^D+(interpolation_order-1)
      ixR_p_min^D(:, 2)=ixCoMmin^D-(interpolation_order-1)
    end if

    ! extend index range to physical boundary
    ixR_p_min^D(-1,1)=1
    ixR_p_max^D( 1,2)=ixCoGmax^D
    \}

    ! calculate sizes for buffer arrays for siblings
    {do i^DB=-1,1\}
      sizes_srl_send(i^D)=(nwflux+nwaux)*{(ixS_srl_max^D(2,i^D)-ixS_srl_min^D(2,i^D)+1)|*}
      sizes_srl_recv(i^D)=(nwflux+nwaux)*{(ixR_srl_max^D(2,i^D)-ixR_srl_min^D(2,i^D)+1)|*}
      sizes_srl_send_total(i^D)=sizes_srl_send(i^D)
      sizes_srl_recv_total(i^D)=sizes_srl_recv(i^D)
      if(stagger_grid) then
        ! Staggered (face-allocated) variables
        do idir=1,ndim
          sizes_srl_send_stg(idir,i^D)={(ixS_srl_stg_max^D(idir,i^D)-ixS_srl_stg_min^D(idir,i^D)+1)|*}
          sizes_srl_recv_stg(idir,i^D)={(ixR_srl_stg_max^D(idir,i^D)-ixR_srl_stg_min^D(idir,i^D)+1)|*}
          sizes_srl_send_total(i^D)=sizes_srl_send_total(i^D)+sizes_srl_send_stg(idir,i^D)
          sizes_srl_recv_total(i^D)=sizes_srl_recv_total(i^D)+sizes_srl_recv_stg(idir,i^D)
        end do
      end if
    {end do\}

    ! Sizes for multi-resolution communications
    {do i^DB=-1,1\}
       ! Cell-centred variables
       sizes_r_send(i^D)=(nwflux+nwaux)*{(ixS_r_max^D(2,i^D)-ixS_r_min^D(2,i^D)+1)|*}
       sizes_r_send_total(i^D)=sizes_r_send(i^D)
       if(stagger_grid) then
         ! Staggered (face-allocated) variables
         do idir=1,ndim
           sizes_r_send_stg(idir,i^D)={(ixS_r_stg_max^D(idir,i^D)-ixS_r_stg_min^D(idir,i^D)+1)|*}
           sizes_r_send_total(i^D)=sizes_r_send_total(i^D)+sizes_r_send_stg(idir,i^D)
         end do
       end if
    {end do\}

    {do i^DB=0,3\}
       ! Cell-centred variables
       sizes_r_recv(i^D)=(nwflux+nwaux)*{(ixR_r_max^D(1,i^D)-ixR_r_min^D(1,i^D)+1)|*}
       sizes_p_send(i^D)=(nwflux+nwaux)*{(ixS_p_max^D(1,i^D)-ixS_p_min^D(1,i^D)+1)|*}
       sizes_p_recv(i^D)=(nwflux+nwaux)*{(ixR_p_max^D(1,i^D)-ixR_p_min^D(1,i^D)+1)|*}

       sizes_r_recv_total(i^D)=sizes_r_recv(i^D)
       sizes_p_send_total(i^D)=sizes_p_send(i^D)
       sizes_p_recv_total(i^D)=sizes_p_recv(i^D)
    
       if (stagger_grid) then
       ! Staggered (face-allocated) variables
         do idir=1,^ND
           sizes_r_recv_stg(idir,i^D)={(ixR_r_stg_max^D(idir,i^D)-ixR_r_stg_min^D(idir,i^D)+1)|*}
           sizes_p_send_stg(idir,i^D)={(ixS_p_stg_max^D(idir,i^D)-ixS_p_stg_min^D(idir,i^D)+1)|*}
           sizes_p_recv_stg(idir,i^D)={(ixR_p_stg_max^D(idir,i^D)-ixR_p_stg_min^D(idir,i^D)+1)|*}
           sizes_r_recv_total(i^D)=sizes_r_recv_total(i^D)+sizes_r_recv_stg(idir,i^D)
           sizes_p_send_total(i^D)=sizes_p_send_total(i^D)+sizes_p_send_stg(idir,i^D)
           sizes_p_recv_total(i^D)=sizes_p_recv_total(i^D)+sizes_p_recv_stg(idir,i^D)
         end do
       end if

    {end do\}

  end subroutine init_bc

  subroutine create_bc_mpi_datatype(nwstart,nwbc) 
    use mod_global_parameters 

    integer, intent(in) :: nwstart, nwbc
    integer :: i^D, ic^D, inc^D, iib^D

    {do i^DB=-1,1\}
      if (i^D==0|.and.) cycle
      {do iib^DB=-1,2\}
         call get_bc_comm_type(type_send_srl(iib^D,i^D),ixS_srl_^L(iib^D,i^D),ixG^LL,nwstart,nwbc)
         call get_bc_comm_type(type_recv_srl(iib^D,i^D),ixR_srl_^L(iib^D,i^D),ixG^LL,nwstart,nwbc)
         if (iib^D==2|.or.) cycle
         call get_bc_comm_type(type_send_r(iib^D,i^D),  ixS_r_^L(iib^D,i^D),ixCoG^L,nwstart,nwbc)
         {do ic^DB=1+int((1-i^DB)/2),2-int((1+i^DB)/2)
            inc^DB=2*i^DB+ic^DB\}
            call get_bc_comm_type(type_recv_r(iib^D,inc^D),ixR_r_^L(iib^D,inc^D), ixG^LL,nwstart,nwbc)
            call get_bc_comm_type(type_send_p(iib^D,inc^D),ixS_p_^L(iib^D,inc^D), ixG^LL,nwstart,nwbc)
            call get_bc_comm_type(type_recv_p(iib^D,inc^D),ixR_p_^L(iib^D,inc^D),ixCoG^L,nwstart,nwbc)
         {end do\}
      {end do\}
    {end do\}
  
  end subroutine create_bc_mpi_datatype

  subroutine get_bc_comm_type(comm_type,ix^L,ixG^L,nwstart,nwbc)
    use mod_global_parameters 
  
    integer, intent(inout) :: comm_type
    integer, intent(in) :: ix^L, ixG^L, nwstart, nwbc
    
    integer, dimension(ndim+1) :: fullsize, subsize, start

    ^D&fullsize(^D)=ixGmax^D;
    fullsize(ndim+1)=nw
    ^D&subsize(^D)=ixmax^D-ixmin^D+1;
    subsize(ndim+1)=nwbc
    ^D&start(^D)=ixmin^D-1;
    start(ndim+1)=nwstart
    
    call MPI_TYPE_CREATE_SUBARRAY(ndim+1,fullsize,subsize,start,MPI_ORDER_FORTRAN, &
                                  MPI_DOUBLE_PRECISION,comm_type,ierrmpi)
    call MPI_TYPE_COMMIT(comm_type,ierrmpi)
    
  end subroutine get_bc_comm_type

  subroutine put_bc_comm_types()
    use mod_global_parameters 
 
    integer :: i^D, ic^D, inc^D, iib^D

    {do i^DB=-1,1\}
       if (i^D==0|.and.) cycle
       {do iib^DB=-1,2\}
           call MPI_TYPE_FREE(type_send_srl(iib^D,i^D),ierrmpi)
           call MPI_TYPE_FREE(type_recv_srl(iib^D,i^D),ierrmpi)
           if (levmin==levmax) cycle
           if (iib^D==2|.or.) cycle
           call MPI_TYPE_FREE(type_send_r(iib^D,i^D),ierrmpi)
           {do ic^DB=1+int((1-i^DB)/2),2-int((1+i^DB)/2)
              inc^DB=2*i^DB+ic^DB\}
              call MPI_TYPE_FREE(type_recv_r(iib^D,inc^D),ierrmpi)
              call MPI_TYPE_FREE(type_send_p(iib^D,inc^D),ierrmpi)
              call MPI_TYPE_FREE(type_recv_p(iib^D,inc^D),ierrmpi)
           {end do\}
       {end do\}
    {end do\}
  
  end subroutine put_bc_comm_types

  subroutine getbc(time,qdt,psb,nwstart,nwbc,req_diag)
    use mod_global_parameters
    use mod_physics

    double precision, intent(in)      :: time, qdt
    type(state), target               :: psb(max_blocks)
    integer, intent(in)               :: nwstart ! Fill from nwstart+1
    integer, intent(in)               :: nwbc    ! Number of variables to fill
    logical, intent(in), optional     :: req_diag ! If false, skip diagonal ghost cells

    integer :: my_neighbor_type, ipole, idims, iside, nwhead, nwtail
    integer :: iigrid, igrid, ineighbor, ipe_neighbor
    integer :: nrecvs, nsends, isizes
    integer :: ixG^L, ixR^L, ixS^L, ixB^L, ixI^L, k^L
    integer :: i^D, n_i^D, ic^D, inc^D, n_inc^D, iib^D
    ! store physical boundary indicating index
    integer :: idphyb(ndim,max_blocks),bindex(ndim)
    integer :: isend_buf(npwbuf), ipwbuf, nghostcellsco,iB
    logical  :: req_diagonal
    type(wbuffer) :: pwbuf(npwbuf)

    double precision :: time_bcin
    ! Stretching grid parameters for coarsened block of the current block

    nwhead=nwstart+1
    nwtail=nwstart+nwbc

    req_diagonal = .true.
    if (present(req_diag)) req_diagonal = req_diag

    time_bcin=MPI_WTIME()
    ixG^L=ixG^LL;
    
    if (internalboundary) then 
       call getintbc(time,ixG^L)
    end if
    ! fill ghost cells in physical boundaries
    if(bcphys) then
      do iigrid=1,igridstail; igrid=igrids(iigrid);
         if(.not.phyboundblock(igrid)) cycle
         saveigrid=igrid
         block=>ps(igrid)
         ^D&dxlevel(^D)=rnode(rpdx^D_,igrid);
         do idims=1,ndim
            ! to avoid using as yet unknown corner info in more than 1D, we
            ! fill only interior mesh ranges of the ghost cell ranges at first,
            ! and progressively enlarge the ranges to include corners later
            {
             kmin^D=merge(0, 1, idims==^D)
             kmax^D=merge(0, 1, idims==^D)
             ixBmin^D=ixGmin^D+kmin^D*nghostcells
             ixBmax^D=ixGmax^D-kmax^D*nghostcells
            \}
            {^IFTWOD
             if(idims > 1 .and. neighbor_type(-1,0,igrid)==neighbor_boundary) ixBmin1=ixGmin1
             if(idims > 1 .and. neighbor_type( 1,0,igrid)==neighbor_boundary) ixBmax1=ixGmax1}
            {^IFTHREED
             if(idims > 1 .and. neighbor_type(-1,0,0,igrid)==neighbor_boundary) ixBmin1=ixGmin1
             if(idims > 1 .and. neighbor_type( 1,0,0,igrid)==neighbor_boundary) ixBmax1=ixGmax1
             if(idims > 2 .and. neighbor_type(0,-1,0,igrid)==neighbor_boundary) ixBmin2=ixGmin2
             if(idims > 2 .and. neighbor_type(0, 1,0,igrid)==neighbor_boundary) ixBmax2=ixGmax2}
            do iside=1,2
               i^D=kr(^D,idims)*(2*iside-3);
               if (aperiodB(idims)) then 
                  if (neighbor_type(i^D,igrid) /= neighbor_boundary .and. &
                       .not. psb(igrid)%is_physical_boundary(2*idims-2+iside)) cycle
               else 
                  if (neighbor_type(i^D,igrid) /= neighbor_boundary) cycle
               end if
               call bc_phys(iside,idims,time,qdt,psb(igrid)%w,ps(igrid)%x,ixG^L,ixB^L)
            end do
         end do
      end do
    end if
    
    ! default : no singular axis
    ipole=0
    
    irecv=0
    isend=0
    isend_buf=0
    ipwbuf=1
    ! total number of times to call MPI_IRECV in each processor between sibling blocks or from finer neighbors
    nrecvs=nrecv_bc_srl+nrecv_bc_r
    ! total number of times to call MPI_ISEND in each processor between sibling blocks or to coarser neighors
    nsends=nsend_bc_srl+nsend_bc_r

    allocate(recvstatus(MPI_STATUS_SIZE,nrecvs),recvrequest(nrecvs))
    recvrequest=MPI_REQUEST_NULL

    allocate(sendstatus(MPI_STATUS_SIZE,nsends),sendrequest(nsends))
    sendrequest=MPI_REQUEST_NULL

    ! receiving ghost-cell values from sibling blocks and finer neighbors
    do iigrid=1,igridstail; igrid=igrids(iigrid);
       saveigrid=igrid
       call identifyphysbound(ps(igrid),iib^D)   
       ^D&idphyb(^D,igrid)=iib^D;
       {do i^DB=-1,1\}
          if (skip_direction([ i^D ])) cycle
          my_neighbor_type=neighbor_type(i^D,igrid)
          select case (my_neighbor_type)
          case (neighbor_sibling)
             call bc_recv_srl
          case (neighbor_fine)
             call bc_recv_restrict
          end select
       {end do\}
    end do
    
    ! sending ghost-cell values to sibling blocks and coarser neighbors
    nghostcellsco=ceiling(nghostcells*0.5d0)
    do iigrid=1,igridstail; igrid=igrids(iigrid);
       saveigrid=igrid
       block=>ps(igrid)

       ! Used stored data to identify physical boundaries
       ^D&iib^D=idphyb(^D,igrid);

       if (any(neighbor_type(:^D&,igrid)==neighbor_coarse)) then
          ^D&dxlevel(^D)=rnode(rpdx^D_,igrid);
    {#IFDEF EVOLVINGBOUNDARY
          if(phyboundblock(igrid)) then
            ! coarsen finer ghost cells at physical boundaries
            ixCoMmin^D=ixCoGmin^D+nghostcellsco;
            ixCoMmax^D=ixCoGmax^D-nghostcellsco;
            ixMmin^D=ixGmin^D+(nghostcellsco-1);
            ixMmax^D=ixGmax^D-(nghostcellsco-1);
          else
            ixCoM^L=ixCoG^L^LSUBnghostcells;
            ixM^L=ixG^L^LSUBnghostcells;
          end if
    }
          call coarsen_grid(psb(igrid)%w,ps(igrid)%x,ixG^L,ixM^L,psc(igrid)%w,psc(igrid)%x,&
                            ixCoG^L,ixCoM^L,igrid,igrid)
       end if
    
       {do i^DB=-1,1\}
          if (skip_direction([ i^D ])) cycle
          if (phi_ > 0) ipole=neighbor_pole(i^D,igrid)
          my_neighbor_type=neighbor_type(i^D,igrid)
          select case (my_neighbor_type)
          case (neighbor_coarse)
             call bc_send_restrict
          case (neighbor_sibling)
             call bc_send_srl
          end select
       {end do\}
    end do
    
    !if (irecv/=nrecvs) then
    !   call mpistop("number of recvs in phase1 in amr_ghostcells is incorrect")
    !end if
    !if (isend/=nsends) then
    !   call mpistop("number of sends in phase1 in amr_ghostcells is incorrect")
    !end if
    
    call MPI_WAITALL(irecv,recvrequest,recvstatus,ierrmpi)
    deallocate(recvstatus,recvrequest)

    call MPI_WAITALL(isend,sendrequest,sendstatus,ierrmpi)
    do ipwbuf=1,npwbuf
       if (isend_buf(ipwbuf)/=0) deallocate(pwbuf(ipwbuf)%w)
    end do
    deallocate(sendstatus,sendrequest)

    irecv=0
    isend=0
    isend_buf=0
    ipwbuf=1
    ! total number of times to call MPI_IRECV in each processor from coarser neighbors
    nrecvs=nrecv_bc_p
    ! total number of times to call MPI_ISEND in each processor to finer neighbors
    nsends=nsend_bc_p

    allocate(recvstatus(MPI_STATUS_SIZE,nrecvs),recvrequest(nrecvs))
    recvrequest=MPI_REQUEST_NULL
    allocate(sendstatus(MPI_STATUS_SIZE,nsends),sendrequest(nsends))
    sendrequest=MPI_REQUEST_NULL

    ! receiving ghost-cell values from coarser neighbors
    do iigrid=1,igridstail; igrid=igrids(iigrid);
       saveigrid=igrid
       ^D&iib^D=idphyb(^D,igrid);
       {do i^DB=-1,1\}
          if (skip_direction([ i^D ])) cycle
          my_neighbor_type=neighbor_type(i^D,igrid)
          if (my_neighbor_type==neighbor_coarse) call bc_recv_prolong
       {end do\}
    end do
    ! sending ghost-cell values to finer neighbors 
    do iigrid=1,igridstail; igrid=igrids(iigrid);
       saveigrid=igrid
       block=>ps(igrid)
       ^D&iib^D=idphyb(^D,igrid);
       ^D&dxlevel(^D)=rnode(rpdx^D_,igrid);
       if (any(neighbor_type(:^D&,igrid)==neighbor_fine)) then
          {do i^DB=-1,1\}
             if (skip_direction([ i^D ])) cycle
             if (phi_ > 0) ipole=neighbor_pole(i^D,igrid)
             my_neighbor_type=neighbor_type(i^D,igrid)
             if (my_neighbor_type==neighbor_fine) call bc_send_prolong
          {end do\}
       end if
    end do
    
    !if (irecv/=nrecvs) then
    !   call mpistop("number of recvs in phase2 in amr_ghostcells is incorrect")
    !end if
    !if (isend/=nsends) then
    !   call mpistop("number of sends in phase2 in amr_ghostcells is incorrect")
    !end if
    
    call MPI_WAITALL(irecv,recvrequest,recvstatus,ierrmpi)
    deallocate(recvstatus,recvrequest)

    ! do prolongation on the ghost-cell values received from coarser neighbors 
    do iigrid=1,igridstail; igrid=igrids(iigrid);
       saveigrid=igrid
       block=>ps(igrid)
       ^D&iib^D=idphyb(^D,igrid);
       ^D&dxlevel(^D)=rnode(rpdx^D_,igrid);
       if (any(neighbor_type(:^D&,igrid)==neighbor_coarse)) then
          {do i^DB=-1,1\}
             if (skip_direction([ i^D ])) cycle
             my_neighbor_type=neighbor_type(i^D,igrid)
             if (my_neighbor_type==neighbor_coarse) call bc_prolong
          {end do\}
       end if
    end do
    
    call MPI_WAITALL(isend,sendrequest,sendstatus,ierrmpi)
    do ipwbuf=1,npwbuf
       if (isend_buf(ipwbuf)/=0) deallocate(pwbuf(ipwbuf)%w)
    end do
    deallocate(sendstatus,sendrequest)

     ! modify normal component of magnetic field to fix divB=0 
    if(bcphys .and. physics_type=='mhd' .and. ndim>1) call phys_boundary_adjust()
    
    if (nwaux>0) call fix_auxiliary
    
    time_bc=time_bc+(MPI_WTIME()-time_bcin)
    
    contains

      logical function skip_direction(dir)
        integer, intent(in) :: dir(^ND)

        if (all(dir == 0)) then
           skip_direction = .true.
        else if (.not. req_diagonal .and. count(dir /= 0) > 1) then
           skip_direction = .true.
        else
           skip_direction = .false.
        end if
      end function skip_direction

      !> Send to sibling at same refinement level
      subroutine bc_send_srl

        ineighbor=neighbor(1,i^D,igrid)
        ipe_neighbor=neighbor(2,i^D,igrid)

        if (ipole==0) then
           n_i^D=-i^D;
           if (ipe_neighbor==mype) then
              ixS^L=ixS_srl_^L(iib^D,i^D);
              ixR^L=ixR_srl_^L(iib^D,n_i^D);
              psb(ineighbor)%w(ixR^S,nwhead:nwtail)=&
                  psb(igrid)%w(ixS^S,nwhead:nwtail)
           else
              isend=isend+1
              itag=(3**^ND+4**^ND)*(ineighbor-1)+{(n_i^D+1)*3**(^D-1)+}
              call MPI_ISEND(psb(igrid)%w,1,type_send_srl(iib^D,i^D), &
                             ipe_neighbor,itag,icomm,sendrequest(isend),ierrmpi)
           end if
        else
           ixS^L=ixS_srl_^L(iib^D,i^D);
           select case (ipole)
           {case (^D)
              n_i^D=i^D^D%n_i^DD=-i^DD;\}
           end select
           if (ipe_neighbor==mype) then
              ixR^L=ixR_srl_^L(iib^D,n_i^D);
              call pole_copy(psb(ineighbor)%w,ixG^L,ixR^L,psb(igrid)%w,ixG^L,ixS^L)
           else
              if (isend_buf(ipwbuf)/=0) then
                 call MPI_WAIT(sendrequest(isend_buf(ipwbuf)), &
                               sendstatus(:,isend_buf(ipwbuf)),ierrmpi)
                 deallocate(pwbuf(ipwbuf)%w)
              end if
              allocate(pwbuf(ipwbuf)%w(ixS^S,nwhead:nwtail))
              call pole_buf(pwbuf(ipwbuf)%w,ixS^L,ixS^L,psb(igrid)%w,ixG^L,ixS^L)
              isend=isend+1
              isend_buf(ipwbuf)=isend
              itag=(3**^ND+4**^ND)*(ineighbor-1)+{(n_i^D+1)*3**(^D-1)+}
              isizes={(ixSmax^D-ixSmin^D+1)*}*nwbc
              call MPI_ISEND(pwbuf(ipwbuf)%w,isizes,MPI_DOUBLE_PRECISION, &
                             ipe_neighbor,itag,icomm,sendrequest(isend),ierrmpi)
              ipwbuf=1+modulo(ipwbuf,npwbuf)
           end if
        end if

      end subroutine bc_send_srl

      !> Send to coarser neighbor
      subroutine bc_send_restrict
        integer :: ii^D

        ic^D=1+modulo(node(pig^D_,igrid)-1,2);
        if ({.not.(i^D==0.or.i^D==2*ic^D-3)|.or.}) return
        if(phyboundblock(igrid)) then
          ! filling physical boundary ghost cells of a coarser representative block for
          ! sending swap region with width of nghostcells to its coarser neighbor
          do idims=1,ndim
             ! to avoid using as yet unknown corner info in more than 1D, we
             ! fill only interior mesh ranges of the ghost cell ranges at first,
             ! and progressively enlarge the ranges to include corners later
             {kmin^D=merge(0, 1, idims==^D)
             kmax^D=merge(0, 1, idims==^D)
             ixBmin^D=ixCoGmin^D+kmin^D*nghostcells
             ixBmax^D=ixCoGmax^D-kmax^D*nghostcells\}
             {^IFTWOD
             if(idims > 1 .and. neighbor_type(-1,0,igrid)==neighbor_boundary) ixBmin1=ixCoGmin1
             if(idims > 1 .and. neighbor_type( 1,0,igrid)==neighbor_boundary) ixBmax1=ixCoGmax1}
             {^IFTHREED
             if(idims > 1 .and. neighbor_type(-1,0,0,igrid)==neighbor_boundary) ixBmin1=ixCoGmin1
             if(idims > 1 .and. neighbor_type( 1,0,0,igrid)==neighbor_boundary) ixBmax1=ixCoGmax1
             if(idims > 2 .and. neighbor_type(0,-1,0,igrid)==neighbor_boundary) ixBmin2=ixCoGmin2
             if(idims > 2 .and. neighbor_type(0, 1,0,igrid)==neighbor_boundary) ixBmax2=ixCoGmax2}
             {if(i^D==-1) then
               ixBmin^D=ixCoGmin^D+nghostcells
               ixBmax^D=ixCoGmin^D+2*nghostcells-1
             else if(i^D==1) then
               ixBmin^D=ixCoGmax^D-2*nghostcells+1
               ixBmax^D=ixCoGmax^D-nghostcells
             end if\}
             do iside=1,2
                ii^D=kr(^D,idims)*(2*iside-3);
                if ({abs(i^D)==1.and.abs(ii^D)==1|.or.}) cycle
                if (neighbor_type(ii^D,igrid)/=neighbor_boundary) cycle
                call bc_phys(iside,idims,time,0.d0,psc(igrid)%w,&
                       psc(igrid)%x,ixCoG^L,ixB^L)
             end do
          end do
        end if

        ineighbor=neighbor(1,i^D,igrid)
        ipe_neighbor=neighbor(2,i^D,igrid)

        if (ipole==0) then
           n_inc^D=-2*i^D+ic^D;
           if (ipe_neighbor==mype) then
              ixS^L=ixS_r_^L(iib^D,i^D);
              ixR^L=ixR_r_^L(iib^D,n_inc^D);
              psb(ineighbor)%w(ixR^S,nwhead:nwtail)=&
               psc(igrid)%w(ixS^S,nwhead:nwtail)
           else
              isend=isend+1
              itag=(3**^ND+4**^ND)*(ineighbor-1)+3**^ND+{n_inc^D*4**(^D-1)+}
              call MPI_ISEND(psc(igrid)%w,1,type_send_r(iib^D,i^D), &
                             ipe_neighbor,itag,icomm,sendrequest(isend),ierrmpi)
           end if
        else
           ixS^L=ixS_r_^L(iib^D,i^D);
           select case (ipole)
           {case (^D)
              n_inc^D=2*i^D+(3-ic^D)^D%n_inc^DD=-2*i^DD+ic^DD;\}
           end select
           if (ipe_neighbor==mype) then
              ixR^L=ixR_r_^L(iib^D,n_inc^D);
              call pole_copy(psb(ineighbor)%w,ixG^L,ixR^L,psc(igrid)%w,ixCoG^L,ixS^L)
           else
              if (isend_buf(ipwbuf)/=0) then
                 call MPI_WAIT(sendrequest(isend_buf(ipwbuf)), &
                               sendstatus(:,isend_buf(ipwbuf)),ierrmpi)
                 deallocate(pwbuf(ipwbuf)%w)
              end if
              allocate(pwbuf(ipwbuf)%w(ixS^S,nwhead:nwtail))
              call pole_buf(pwbuf(ipwbuf)%w,ixS^L,ixS^L,psc(igrid)%w,ixCoG^L,ixS^L)
              isend=isend+1
              isend_buf(ipwbuf)=isend
              itag=(3**^ND+4**^ND)*(ineighbor-1)+3**^ND+{n_inc^D*4**(^D-1)+}
              isizes={(ixSmax^D-ixSmin^D+1)*}*nwbc
              call MPI_ISEND(pwbuf(ipwbuf)%w,isizes,MPI_DOUBLE_PRECISION, &
                             ipe_neighbor,itag,icomm,sendrequest(isend),ierrmpi)
              ipwbuf=1+modulo(ipwbuf,npwbuf)
           end if
        end if

      end subroutine bc_send_restrict

      !> Send to finer neighbor
      subroutine bc_send_prolong
        integer :: ii^D

        {do ic^DB=1+int((1-i^DB)/2),2-int((1+i^DB)/2)
           inc^DB=2*i^DB+ic^DB\}
           ixS^L=ixS_p_^L(iib^D,inc^D);

           ineighbor=neighbor_child(1,inc^D,igrid)
           ipe_neighbor=neighbor_child(2,inc^D,igrid)
        
           if (ipole==0) then
              n_i^D=-i^D;
              n_inc^D=ic^D+n_i^D;
              if (ipe_neighbor==mype) then
                 ixR^L=ixR_p_^L(iib^D,n_inc^D);
                 psc(ineighbor)%w(ixR^S,nwhead:nwtail) &
                    =psb(igrid)%w(ixS^S,nwhead:nwtail)
              else
                 isend=isend+1
                 itag=(3**^ND+4**^ND)*(ineighbor-1)+3**^ND+{n_inc^D*4**(^D-1)+}
                 call MPI_ISEND(psb(igrid)%w,1,type_send_p(iib^D,inc^D), &
                                ipe_neighbor,itag,icomm,sendrequest(isend),ierrmpi)
              end if
           else
              select case (ipole)
              {case (^D)
                 n_inc^D=inc^D^D%n_inc^DD=ic^DD-i^DD;\}
              end select
              if (ipe_neighbor==mype) then
                 ixR^L=ixR_p_^L(iib^D,n_inc^D);
                 call pole_copy(psc(ineighbor)%w,ixCoG^L,ixR^L,psb(igrid)%w,ixG^L,ixS^L)
              else
                 if (isend_buf(ipwbuf)/=0) then
                    call MPI_WAIT(sendrequest(isend_buf(ipwbuf)), &
                                  sendstatus(:,isend_buf(ipwbuf)),ierrmpi)
                    deallocate(pwbuf(ipwbuf)%w)
                 end if
                 allocate(pwbuf(ipwbuf)%w(ixS^S,nwhead:nwtail))
                 call pole_buf(pwbuf(ipwbuf)%w,ixS^L,ixS^L,psb(igrid)%w,ixG^L,ixS^L)
                 isend=isend+1
                 isend_buf(ipwbuf)=isend
                 itag=(3**^ND+4**^ND)*(ineighbor-1)+3**^ND+{n_inc^D*4**(^D-1)+}
                 isizes={(ixSmax^D-ixSmin^D+1)*}*nwbc
                 call MPI_ISEND(pwbuf(ipwbuf)%w,isizes,MPI_DOUBLE_PRECISION, &
                                ipe_neighbor,itag,icomm,sendrequest(isend),ierrmpi)
                 ipwbuf=1+modulo(ipwbuf,npwbuf)
              end if
           end if
        {end do\}

      end subroutine bc_send_prolong

      !> Receive from sibling at same refinement level
      subroutine bc_recv_srl

        ipe_neighbor=neighbor(2,i^D,igrid)
        if (ipe_neighbor/=mype) then
           irecv=irecv+1
           itag=(3**^ND+4**^ND)*(igrid-1)+{(i^D+1)*3**(^D-1)+}
           call MPI_IRECV(psb(igrid)%w,1,type_recv_srl(iib^D,i^D), &
                          ipe_neighbor,itag,icomm,recvrequest(irecv),ierrmpi)
        end if

      end subroutine bc_recv_srl

      !> Receive from fine neighbor
      subroutine bc_recv_restrict

        {do ic^DB=1+int((1-i^DB)/2),2-int((1+i^DB)/2)
           inc^DB=2*i^DB+ic^DB\}
           ipe_neighbor=neighbor_child(2,inc^D,igrid)
           if (ipe_neighbor/=mype) then
              irecv=irecv+1
              itag=(3**^ND+4**^ND)*(igrid-1)+3**^ND+{inc^D*4**(^D-1)+}
              call MPI_IRECV(psb(igrid)%w,1,type_recv_r(iib^D,inc^D), &
                             ipe_neighbor,itag,icomm,recvrequest(irecv),ierrmpi)
           end if
        {end do\}

      end subroutine bc_recv_restrict

      !> Receive from coarse neighbor
      subroutine bc_recv_prolong

        ic^D=1+modulo(node(pig^D_,igrid)-1,2);
        if ({.not.(i^D==0.or.i^D==2*ic^D-3)|.or.}) return

        ipe_neighbor=neighbor(2,i^D,igrid)
        if (ipe_neighbor/=mype) then
           irecv=irecv+1
           inc^D=ic^D+i^D;
           itag=(3**^ND+4**^ND)*(igrid-1)+3**^ND+{inc^D*4**(^D-1)+}
           call MPI_IRECV(psc(igrid)%w,1,type_recv_p(iib^D,inc^D), &
                          ipe_neighbor,itag,icomm,recvrequest(irecv),ierrmpi)  
        end if

      end subroutine bc_recv_prolong

      subroutine bc_prolong
        use mod_physics, only: phys_to_primitive, phys_to_conserved

        integer :: ixFi^L,ixCo^L,ii^D
        double precision :: dxFi^D, dxCo^D, xFimin^D, xComin^D, invdxCo^D

        ixFi^L=ixR_srl_^L(iib^D,i^D);
        dxFi^D=rnode(rpdx^D_,igrid);
        dxCo^D=two*dxFi^D;
        invdxCo^D=1.d0/dxCo^D;

        ! compute the enlarged grid lower left corner coordinates
        ! these are true coordinates for an equidistant grid, 
        ! but we can temporarily also use them for getting indices 
        ! in stretched grids
        xFimin^D=rnode(rpxmin^D_,igrid)-dble(nghostcells)*dxFi^D;
        xComin^D=rnode(rpxmin^D_,igrid)-dble(nghostcells)*dxCo^D;

        if(prolongprimitive) then
           ! following line again assumes equidistant grid, but 
           ! just computes indices, so also ok for stretched case
           ! reason for +1-1 and +1+1: the coarse representation has 
           ! also nghostcells at each side. During
           ! prolongation, we need cells to left and right, hence -1/+1
           ixComin^D=int((xFimin^D+(dble(ixFimin^D)-half)*dxFi^D-xComin^D)*invdxCo^D)+1-1;
           ixComax^D=int((xFimin^D+(dble(ixFimax^D)-half)*dxFi^D-xComin^D)*invdxCo^D)+1+1;
           call phys_to_primitive(ixCoG^L,ixCo^L,&
             psc(igrid)%w,psc(igrid)%x)
        endif

        select case (typeghostfill)
        case ("linear")
           call interpolation_linear(ixFi^L,dxFi^D,xFimin^D,dxCo^D,invdxCo^D,xComin^D)
        case ("copy")
           call interpolation_copy(ixFi^L,dxFi^D,xFimin^D,dxCo^D,invdxCo^D,xComin^D)
        case default
           write (unitterm,*) "Undefined typeghostfill ",typeghostfill
           call mpistop("Undefined typeghostfill")
        end select

        if(prolongprimitive) call phys_to_conserved(ixCoG^L,ixCo^L,&
             psc(igrid)%w,psc(igrid)%x)

      end subroutine bc_prolong

      subroutine interpolation_linear(ixFi^L,dxFi^D,xFimin^D, &
                                      dxCo^D,invdxCo^D,xComin^D)
        use mod_physics, only: phys_to_conserved
        integer, intent(in) :: ixFi^L
        double precision, intent(in) :: dxFi^D, xFimin^D,dxCo^D, invdxCo^D, xComin^D

        integer :: ixCo^D, jxCo^D, hxCo^D, ixFi^D, ix^D, iw, idims, nwmin,nwmax
        double precision :: xCo^D, xFi^D, eta^D
        double precision :: slopeL, slopeR, slopeC, signC, signR
        double precision :: slope(1:nw,ndim)
        !!double precision :: local_invdxCo^D
        double precision :: signedfactorhalf^D
        !integer :: ixshift^D, icase

        !icase=mod(nghostcells,2)

        if(prolongprimitive) then
          nwmin=1
          nwmax=nw
        else
          nwmin=nwhead
          nwmax=nwtail
        end if

        {do ixFi^DB = ixFi^LIM^DB
           ! cell-centered coordinates of fine grid point
           ! here we temporarily use an equidistant grid
           xFi^DB=xFimin^DB+(dble(ixFi^DB)-half)*dxFi^DB
        
           ! indices of coarse cell which contains the fine cell
           ! since we computed lower left corner earlier 
           ! in equidistant fashion: also ok for stretched case
           ixCo^DB=int((xFi^DB-xComin^DB)*invdxCo^DB)+1
        
           ! cell-centered coordinates of coarse grid point
           ! here we temporarily use an equidistant grid
           xCo^DB=xComin^DB+(dble(ixCo^DB)-half)*dxCo^DB \}

           !if(.not.slab) then
           !   ^D&local_invdxCo^D=1.d0/psc(igrid)%dx({ixCo^DD},^D)\
           !endif

           if(slab) then
             ! actual cell-centered coordinates of fine grid point
             !!^D&xFi^D=block%x({ixFi^DD},^D)\
             ! actual cell-centered coordinates of coarse grid point
             !!^D&xCo^D=psc(igrid)%x({ixCo^DD},^D)\
             ! normalized distance between fine/coarse cell center
             ! in coarse cell: ranges from -0.5 to 0.5 in each direction
             ! (origin is coarse cell center)
             ! this is essentially +1/4 or -1/4 on cartesian mesh
             eta^D=(xFi^D-xCo^D)*invdxCo^D;
           else
             !select case(icase)
             ! case(0)
             !{! here we assume an even number of ghostcells!!!
             !ixshift^D=2*(mod(ixFi^D,2)-1)+1
             !if(ixshift^D>0.0d0)then
             !   ! oneven fine grid points
             !   eta^D=-0.5d0*(one-block%dvolume(ixFi^DD) &
             !     /sum(block%dvolume(ixFi^D:ixFi^D+1^D%ixFi^DD))) 
             !else
             !   ! even fine grid points
             !   eta^D=+0.5d0*(one-block%dvolume(ixFi^DD) &
             !     /sum(block%dvolume(ixFi^D-1:ixFi^D^D%ixFi^DD))) 
             !endif\}
             ! case(1)
             !{! here we assume an odd number of ghostcells!!!
             !ixshift^D=2*(mod(ixFi^D,2)-1)+1
             !if(ixshift^D>0.0d0)then
             !   ! oneven fine grid points
             !   eta^D=+0.5d0*(one-block%dvolume(ixFi^DD) &
             !     /sum(block%dvolume(ixFi^D-1:ixFi^D^D%ixFi^DD))) 
             !else
             !   ! even fine grid points
             !   eta^D=-0.5d0*(one-block%dvolume(ixFi^DD) &
             !     /sum(block%dvolume(ixFi^D:ixFi^D+1^D%ixFi^DD))) 
             !endif\}
             ! case default
             !  call mpistop("no such case")
             !end select
             ! the different cases for even/uneven number of ghost cells 
             ! are automatically handled using the relative index to ixMlo
             ! as well as the pseudo-coordinates xFi and xCo 
             ! these latter differ from actual cell centers when stretching is used
             ix^D=2*int((ixFi^D+ixMlo^D)/2)-ixMlo^D;
             {signedfactorhalf^D=(xFi^D-xCo^D)*invdxCo^D*two
              if(dabs(signedfactorhalf^D**2-1.0d0/4.0d0)>smalldouble) call mpistop("error in bc_prolong")
              eta^D=signedfactorhalf^D*(one-block%dvolume(ixFi^DD) &
                   /sum(block%dvolume(ix^D:ix^D+1^D%ixFi^DD))) \}
             !{eta^D=(xFi^D-xCo^D)*invdxCo^D &
             !      *two*(one-block%dvolume(ixFi^DD) &
             !      /sum(block%dvolume(ix^D:ix^D+1^D%ixFi^DD))) \}
           end if
        
           do idims=1,ndim
              hxCo^D=ixCo^D-kr(^D,idims)\
              jxCo^D=ixCo^D+kr(^D,idims)\
        
              do iw=nwmin,nwmax
                 slopeL=psc(igrid)%w(ixCo^D,iw)-psc(igrid)%w(hxCo^D,iw)
                 slopeR=psc(igrid)%w(jxCo^D,iw)-psc(igrid)%w(ixCo^D,iw)
                 slopeC=half*(slopeR+slopeL)
        
                 ! get limited slope
                 signR=sign(one,slopeR)
                 signC=sign(one,slopeC)
                 select case(typeprolonglimit)
                 case('unlimit')
                   slope(iw,idims)=slopeC
                 case('minmod')
                   slope(iw,idims)=signR*max(zero,min(dabs(slopeR), &
                                                     signR*slopeL))
                 case('woodward')
                   slope(iw,idims)=two*signR*max(zero,min(dabs(slopeR), &
                                      signR*slopeL,signR*half*slopeC))
                 case('koren')
                   slope(iw,idims)=signR*max(zero,min(two*signR*slopeL, &
                    (dabs(slopeR)+two*slopeL*signR)*third,two*dabs(slopeR)))
                 case default
                   slope(iw,idims)=signC*max(zero,min(dabs(slopeC), &
                                     signC*slopeL,signC*slopeR))
                 end select
              end do
           end do
        
           ! Interpolate from coarse cell using limited slopes
           psb(igrid)%w(ixFi^D,nwmin:nwmax)=psc(igrid)%w(ixCo^D,nwmin:nwmax)+&
             {(slope(nwmin:nwmax,^D)*eta^D)+}
        
        {end do\}
        
        if(prolongprimitive) call phys_to_conserved(ixG^LL,ixFi^L,psb(igrid)%w,psb(igrid)%x)
      
      end subroutine interpolation_linear

      subroutine interpolation_copy(ixFi^L,dxFi^D,xFimin^D, &
                                    dxCo^D,invdxCo^D,xComin^D)
        use mod_physics, only: phys_to_conserved
        integer, intent(in) :: ixFi^L
        double precision, intent(in) :: dxFi^D, xFimin^D,dxCo^D, invdxCo^D, xComin^D

        integer :: ixCo^D, ixFi^D, nwmin,nwmax
        double precision :: xFi^D

        if(prolongprimitive) then
          nwmin=1
          nwmax=nw
        else
          nwmin=nwhead
          nwmax=nwtail
        end if

        {do ixFi^DB = ixFi^LIM^DB
           ! cell-centered coordinates of fine grid point
           xFi^DB=xFimin^DB+(dble(ixFi^DB)-half)*dxFi^DB
        
           ! indices of coarse cell which contains the fine cell
           ! note: this also works for stretched grids
           ixCo^DB=int((xFi^DB-xComin^DB)*invdxCo^DB)+1\}
        
           ! Copy from coarse cell
           psb(igrid)%w(ixFi^D,nwmin:nwmax)=psc(igrid)%w(ixCo^D,nwmin:nwmax)
        
        {end do\}
        
        if(prolongprimitive) call phys_to_conserved(ixG^LL,ixFi^L,psb(igrid)%w,psb(igrid)%x)
      
      end subroutine interpolation_copy

      subroutine pole_copy(wrecv,ixIR^L,ixR^L,wsend,ixIS^L,ixS^L)
      
        integer, intent(in) :: ixIR^L,ixR^L,ixIS^L,ixS^L
        double precision :: wrecv(ixIR^S,1:nw), wsend(ixIS^S,1:nw)

        integer :: iw, iB

        select case (ipole)
        {case (^D)
           iside=int((i^D+3)/2)
           iB=2*(^D-1)+iside
           do iw=nwhead,nwtail
             select case (typeboundary(iw,iB))
             case ("symm")
               wrecv(ixR^S,iw) = wsend(ixSmax^D:ixSmin^D:-1^D%ixS^S,iw)
             case ("asymm")
               wrecv(ixR^S,iw) =-wsend(ixSmax^D:ixSmin^D:-1^D%ixS^S,iw)
             case default
               call mpistop("Pole boundary condition should be symm or asymm")
             end select
           end do \}
        end select
      
      end subroutine pole_copy

      subroutine pole_buf(wrecv,ixIR^L,ixR^L,wsend,ixIS^L,ixS^L)
      
        integer, intent(in) :: ixIR^L,ixR^L,ixIS^L,ixS^L
        double precision :: wrecv(ixIR^S,nwhead:nwtail), wsend(ixIS^S,1:nw)

        integer :: iw, iB

        select case (ipole)
        {case (^D)
           iside=int((i^D+3)/2)
           iB=2*(^D-1)+iside
           do iw=nwhead,nwtail
             select case (typeboundary(iw,iB))
             case ("symm")
               wrecv(ixR^S,iw) = wsend(ixSmax^D:ixSmin^D:-1^D%ixS^S,iw)
             case ("asymm")
               wrecv(ixR^S,iw) =-wsend(ixSmax^D:ixSmin^D:-1^D%ixS^S,iw)
             case default
               call mpistop("Pole boundary condition should be symm or asymm")
             end select
           end do \}
        end select
      
      end subroutine pole_buf

      subroutine fix_auxiliary
        use mod_physics, only: phys_get_aux
      
        integer :: ix^L

        do iigrid=1,igridstail; igrid=igrids(iigrid);
          saveigrid=igrid
          block=>ps(igrid)
          call identifyphysbound(ps(igrid),iib^D)   
             
          {do i^DB=-1,1\}
             if (skip_direction([ i^D ])) cycle
        
             ix^L=ixR_srl_^L(iib^D,i^D);
             call phys_get_aux(.true.,psb(igrid)%w,ps(igrid)%x,ixG^L,ix^L,"bc")
          {end do\}
        end do
      
      end subroutine fix_auxiliary

  end subroutine getbc

  subroutine identifyphysbound(s,iib^D)
    use mod_global_parameters

    type(state)          :: s
    integer, intent(out) :: iib^D

    {
    if(s%is_physical_boundary(2*^D) .and. &
       s%is_physical_boundary(2*^D-1)) then
      iib^D=2
    else if(s%is_physical_boundary(2*^D-1)) then
      iib^D=-1
    else if(s%is_physical_boundary(2*^D)) then
      iib^D=1
    else
      iib^D=0
    end if
    \}

  end subroutine identifyphysbound

end module mod_ghostcells_update
