#!/bin/bash
##SBATCH -p defq
##SBATCH --exclusive
##SBATCH -N1
#SBATCH --gpus-per-node=1
##SBATCH -o ${AAT_HOME}/results/%N/hpl.txt
#
CONT=${AAT_HOME}/containers/nvidia+hpc-benchmarks+26.02.sqsh
HPLDATPATH=${AAT_HOME}/jobs/hpl/

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=hpl

## AAT_HOME is exported by actions/launch_job.sh; default is only a fallback
## for running this file by hand.
AAT_HOME="${AAT_HOME:-/opt/llmb-bringup}"

## ------------- job info starts here ------------- ##

#hosts=($(scontrol show hostnames $SLURM_JOB_NODELIST))

#generate HPLDAT
#./scripts/gen_hpldat_gb200.sh ${SLURM_NNODES} > ./hpldat/hpl${SLURM_NNODES}N.dat

#sleep 2

#ssh ${hosts[0]} nvidia-imex-ctl -N

#srun --ntasks-per-node=1 ./collect-power.sh
#srun --ntasks-per-node=1 ./set-cpufreq.sh 2000000
#srun --ntasks-per-node=1 nvidia-smi -pl $i -sc 1

#srun --container-image="{CONT}" --container-mounts="${HPLDATPATH}:/hpldat" hostname
#srun --container-image="{CONT}" hostname

srun --mpi=pmix --export=ALL --cpu-bind=none --mem-bind=none --ntasks-per-node=1 \
                --container-image="${CONT}" --container-mounts="${HPLDATPATH}:/hpldat" \
                /workspace/hpl.sh \
                --dat /hpldat/hpl${SLURM_NNODES}N.dat 
#                --mem-affinity 0:0:1:1 \
#                --cpu-affinity 0-35:36-71:72-107:108-143 \
#                --gpu-affinity 0:1:2:3
#		--ucx-affinity roce_r0:roce_r1:roce_r2:roce_r3

#srun --ntasks-per-node=1 nvidia-smi -pl 2500 -sc 1
#srun --ntasks-per-node=1 ./set-cpufreq.sh 3400000

## ------------- parse info starts here ----------- ##


status=$(grep "PASSED" "$RESULT_FILE")

if [[ ! -z "$status" ]];
then
	echo DONE
else
	echo FAIL
fi



