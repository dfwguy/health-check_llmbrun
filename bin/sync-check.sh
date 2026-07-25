#!/bin/bash

if ! command -v scontrol &>/dev/null; then
    source /etc/profile.d/modules.sh
    module load slurm
fi

NODELIST=$1
if [ -z ${NODELIST} ]; then
  NODELIST=${SLURM_JOB_NODELIST}
fi
[ -z ${NODELIST} ] && echo "ERROR: NODELIST is not set. Please provide node list as argument or run within a slurm job." && exit 1


#INPUT=$(scontrol show node=$NODELIST | awk -F= '/NodeName=/{n=$2; sub(/ .*/,"",n)} /Reason=/{r=$2; sub(/ \[.*/,"",r); print n, r}')

while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    # Split line into fields
    read -r -a fields <<< "$line"

    # First field
    node="${fields[0]}"
    echo "------------"
    echo "$node"
    echo "------------"

    # Remaining fields
    for ((i=1; i<${#fields[@]}; i++)); do
        name="${fields[i]}"
        echo "$name"
        diff "logs/$node/$name" "valid-config/default/$name"
    	echo -e "--------------------------------\n"
    done
done < <(
	scontrol show node=$NODELIST | awk -F= '/NodeName=/{n=$2; sub(/ .*/,"",n)} /Reason=/{r=$2; sub(/ \[.*/,"",r); print n, r}'
)



