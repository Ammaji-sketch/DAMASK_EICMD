# sets up an environment for DAMASK on tcsh
# usage:  source DAMASK_env.csh

set CALLED=($_)
set DIRNAME=`dirname $CALLED[2]`
set DAMASK_ROOT=`python -c "import os,sys; print(os.path.realpath(os.path.expanduser(sys.argv[1])))" $DIRNAME"/../"`

source $DAMASK_ROOT/CONFIG

# add BRANCH if DAMASK_ROOT is a git repository
cd $DAMASK_ROOT >/dev/null
set BRANCH = `git branch 2>/dev/null| grep -E '^\* ')`
cd - >/dev/null

set path = ($DAMASK_ROOT/bin $path)

set SOLVER=`which DAMASK_spectral`                                                          
set PROCESSING=`which postResults`                                                          
if ( "x$DAMASK_NUM_THREADS" == "x" ) then                                                                  
  set DAMASK_NUM_THREADS=1
endif

# currently, there is no information that unlimited stack size causes problems
# still, http://software.intel.com/en-us/forums/topic/501500 suggest to fix it
# more info https://jblevins.org/log/segfault
#           https://stackoverflow.com/questions/79923/what-and-where-are-the-stack-and-heap
# http://superuser.com/questions/220059/what-parameters-has-ulimit
limit stacksize unlimited  # maximum stack size (kB)

# disable output in case of scp
if ( $?prompt ) then
  echo ''
  echo Düsseldorf Advanced Materials Simulation Kit --- DAMASK
  echo Max-Planck-Institut für Eisenforschung GmbH, Düsseldorf
  echo https://damask.mpie.de
  echo
  echo Using environment with ...
  echo "DAMASK             $DAMASK_ROOT $BRANCH"
  echo "Grid Solver        $SOLVER" 
  echo "Post Processing    $PROCESSING"
  if ( $?PETSC_DIR) then
    echo "PETSc location     $PETSC_DIR"
  endif
  if ( $?MSC_ROOT) then
    echo "MSC.Marc/Mentat    $MSC_ROOT"
  endif
  echo
  echo "Multithreading     DAMASK_NUM_THREADS=$DAMASK_NUM_THREADS"
  echo `limit datasize`
  echo `limit stacksize`
  echo
endif

setenv DAMASK_NUM_THREADS $DAMASK_NUM_THREADS
if ( ! $?PYTHONPATH ) then
  setenv PYTHONPATH $DAMASK_ROOT/python
else
  setenv PYTHONPATH $DAMASK_ROOT/python:$PYTHONPATH
endif
