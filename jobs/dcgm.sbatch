#!/bin/bash
#SBATCH -N 1
##SBATCH --gpus-per-node=4
##SBATCH -o ${AAT_HOME}/results/%N/dcgm.txt

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=dcgm

## AAT_HOME is exported by actions/launch_job.sh; default is only a fallback
## for running this file by hand.
AAT_HOME="${AAT_HOME:-/opt/llmb-bringup}"

## ------------- job info starts here ------------- ##
unset CUDA_VISIBLE_DEVICES
#export CUDA_VISIBLE_DEVICES=0,1,2,3

#module load cuda-dcgm
dcgmi diag -r 3


## ------------- parse info starts here ----------- ##

status=$(grep -iE "fail|warn|error" "$RESULT_FILE")

if [[ -z "$status" ]];
then
	echo DONE
else
	echo FAIL
fi




