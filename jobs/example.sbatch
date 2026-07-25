#!/bin/bash
#SBATCH -p defq
#SBATCH --ntasks-per-node=4
#SBATCH --gpus-per-node=4

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=example
totalRuns=1

## ------------- job info starts here ------------- ##


echo $HOSTNAME
sleep 15
echo "Test job!"


## ------------- parse info starts here ----------- ##

status=$(grep -iE "code 1" "$RESULT_FILE")

if [[ -z "$status" ]];
then
	echo DONE
else
	echo FAIL
fi


