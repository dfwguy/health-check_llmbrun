#!/bin/bash
#
#

# Delete node_health_action
cmsh -c "monitoring action; remove node_health_action; commit"

# Delete file_copy_action
#cmsh -c "monitoring action; remove file_copy_action; commit"

# Delete launch_job_action (slurm)
cmsh -c "monitoring action; remove launch_job_action; commit"

# Delete Node Health Trigger
cmsh -c "monitoring trigger; remove NodeHealthTrigger; commit"

# Delete File Copy Trigger
#cmsh -c "monitoring trigger; remove FileCopyTrigger; commit"

# Delete Launch Job Trigger (slurm)
cmsh -c "monitoring trigger; remove LaunchJobTrigger; commit"


