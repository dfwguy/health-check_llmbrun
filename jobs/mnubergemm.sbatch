#!/bin/bash
#SBATCH -J mnubergemm
##SBATCH -p defq
##SBATCH -N 1
#SBATCH --exclusive
#SBATCH --ntasks-per-node=4
#SBATCH --gpus-per-node=4
##SBATCH --cpus-per-task=32
#SBATCH -t 6:00:00

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=mnubergemm
totalRuns=12


## AAT_HOME is exported by actions/launch_job.sh; default is only a fallback
## for running this file by hand.
AAT_HOME="${AAT_HOME:-/opt/llmb-bringup}"

## ------------- job info starts here ------------- ##


CONT=${AAT_HOME}/containers/mnubergemm-26.03-v1.17-arm.sqsh

# Important for manual/hand-rolled container launches
#unset XDG_CACHE_HOME
#unset CLAUDE_CONFIG_DIR

# Cluster/fabric tuning: adjust as needed for your environment
export NCCL_DEBUG=INFO
export NCCL_P2P_LEVEL=NVL
export NCCL_CUMEM_ENABLE=1
export NCCL_CUMEM_HOST_ENABLE=0
export NCCL_MNNVL_ENABLE=1
export NCCL_IB_DISABLE=1
export NCCL_MIN_CTAS=16
export NCCL_NVLS_ENABLE=1
export UCX_TLS=tcp


srun \
  --mpi=pmix \
  --cpu-bind=none \
  --container-image="${CONT}" \
  ./mnubergemm \
    --time_to_run 21420 \
    --workload GNC \
    --freq 500 \
    --duty 1.0 \
    --MM_max_workload 65536 \
    --NET_sm_count=32 \
    --MM_M 0 \
    --MM_N 0 \
    --MM_type SX_SX_SSS \
    --MM_sm_count 112 \
    --NET_link_order scatter_sum \
    --NET_size 20480000 \
    --CE_type H \
    --CE_size 20480000 

## ------------- parse info starts here ----------- ##

status=$(grep -iE "code 1" "$RESULT_FILE")

if [[ -z "$status" ]];
then
        echo DONE
else
        echo FAIL
fi

