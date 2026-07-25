#!/bin/bash
# actions/launch_job.sh - BCM action, runs ON the node while devicestatus == UP.
#
# CHANGED FROM THE SBATCH ORIGINAL:
#   This script used to sequence the whole benchmark chain (dcgm -> allreduce ->
#   alltoall) from the node. Everything that spans trays (NCCL, pretrain) moved
#   to bin/rack-orchestrator.sh on the head node, because an 18-tray llmb-run
#   job submitted independently by all 18 trays of a rack means 18 identical
#   rack-scale jobs fighting for the same rack.
#
#   What is left here is node-scope work only: workloads declared
#   `runner=sbatch scope=node` in conf/workloads.conf (dcgm today).
#
# Kept deliberately dependency-light: BCM runs it with a 2m timeout, so it must
# never block. It submits at most one job per invocation and exits.
set -uo pipefail

AAT_ROOT="${AAT_ROOT:-/opt/llmb-bringup}"
source "$AAT_ROOT/lib/common.sh"
source "$AAT_ROOT/lib/nodeset.sh"
source "$AAT_ROOT/lib/slurm.sh"
source "$AAT_ROOT/lib/rack.sh"
source "$AAT_ROOT/lib/results.sh"

_AAT_TAG="launch_job[$HOSTNAME]"
aat_init

[[ -r /etc/profile.d/modules.sh ]] && { source /etc/profile.d/modules.sh; module load slurm 2>/dev/null || true; }

node="${HOSTNAME%%.*}"

# Not in Slurm yet -> nothing to do (BCM fires this before the node joins).
state="$(sl_node_state "$node")"
[[ "$state" == unknown ]] && exit 0

# A job of ours already on the node: enforce the wall-clock guard, then leave.
job_info="$(squeue -h -w "$node" -o '%M %T' 2>/dev/null | head -1)"
if [[ -n "$job_info" ]]; then
    elapsed="${job_info%% *}"; job_state="${job_info##* }"
    hours="$(sl_parse_elapsed_hours "$elapsed")"
    if (( hours >= MAX_JOB_HOURS )); then
        sl_drain "$node" "benchmark timeout after ${hours}h ($job_state)"
    fi
    exit 0
fi

for wlname in $(wl_list node); do
    [[ "$(wl "$wlname" runner)" == sbatch ]] || continue
    runs="$(wl "$wlname" runs)"; [[ "$runs" -ge 1 ]] || runs=1
    launch="$AAT_ROOT/jobs/$(wl "$wlname" sbatch)"
    if [[ ! -r "$launch" ]]; then
        warn "$wlname: missing job file $launch"
        continue
    fi

    completed=0
    for ((r = 1; r <= runs; r++)); do
        [[ -f "$(result_file "$node" "$wlname" "$r")" ]] && completed=$((completed + 1))
    done
    next=$((completed + 1))
    last_file="$(result_file "$node" "$wlname" "$completed")"
    next_file="$(result_file "$node" "$wlname" "$next")"

    checks=empty
    [[ -f "$last_file" ]] && checks="$(read_result_status "$last_file")"

    if [[ "$checks" == FAIL ]]; then
        sl_drain "$node" "$wlname FAIL"
        exit 0
    fi
    if [[ "$checks" == DONE && "$completed" -ge "$runs" ]]; then
        continue
    fi
    if [[ "$state" == idle && "$next" -le "$runs" ]]; then
        mkdir -p "$(dirname "$next_file")"
        info "submitting $wlname run $next/$runs"
        # --export=ALL only forwards EXPORTED variables; the job files read these.
        export AAT_HOME AAT_ROOT RESULTS_DIR
        run_cmd sbatch -w "$node" --export="ALL,RESULT_FILE=$next_file" \
                --output="$next_file" "$launch"
        exit 0
    fi
done
exit 0
