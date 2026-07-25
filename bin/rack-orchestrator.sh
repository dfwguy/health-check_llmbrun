#!/bin/bash
# bin/rack-orchestrator.sh - head-node driver for rack-scale llmb-run workloads.
#
# Run it from cron/systemd every few minutes, or by hand. It is idempotent and
# lock-protected: two concurrent invocations cannot double-submit.
#
#   ./rack-orchestrator.sh --dry-run          # print every llmb-run line, queue nothing
#   ./rack-orchestrator.sh                    # collect finished jobs, then submit
#   ./rack-orchestrator.sh --collect-only
#   ./rack-orchestrator.sh --submit-only --rack rack01
#   ./rack-orchestrator.sh --workload nccl_single -v
#
# WHY THIS EXISTS: the sbatch original submitted 1-node jobs from a BCM action
# running ON each node. llmb-run workloads are rack-scale (72 GPUs = 18 trays)
# and must be submitted ONCE PER RACK from a single place, or 18 trays each
# submit the same 18-tray job. Per-node health checks stay on the node; anything
# that spans trays moves here.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
source "$ROOT/lib/nodeset.sh"
source "$ROOT/lib/slurm.sh"
source "$ROOT/lib/rack.sh"
source "$ROOT/lib/llmb.sh"
source "$ROOT/lib/results.sh"
source "$ROOT/lib/collect.sh"
source "$ROOT/lib/submit.sh"

DO_COLLECT=1
DO_SUBMIT=1
ONLY_RACK=""
ONLY_WL=""

usage() {
    sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while (( $# )); do
    case "$1" in
        --dry-run)      AAT_DRY_RUN=1; export AAT_DRY_RUN ;;
        --collect-only) DO_SUBMIT=0 ;;
        --submit-only)  DO_COLLECT=0 ;;
        --rack)         ONLY_RACK="${2:-}"; shift ;;
        --workload|-w)  ONLY_WL="${2:-}"; shift ;;
        -v|--verbose)   LOG_LEVEL=DEBUG; export LOG_LEVEL ;;
        -h|--help)      usage 0 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; usage 1 ;;
    esac
    shift
done

_AAT_TAG=orchestrator
aat_init
[[ -n "${LOG_LEVEL_OVERRIDE:-}" ]] && LOG_LEVEL="$LOG_LEVEL_OVERRIDE"
rack_load_inventory

if [[ -n "$ONLY_WL" ]]; then
    wl_exists "$ONLY_WL" || die "unknown workload '$ONLY_WL' (have: $(wl_list | tr '\n' ' '))"
fi
if [[ -n "$ONLY_RACK" ]]; then
    rack_exists "$ONLY_RACK" || die "unknown rack '$ONLY_RACK' - check $RACK_INVENTORY"
fi

main() {
    info "pass start (dry_run=${AAT_DRY_RUN:-0} racks=$(rack_list | wc -l) workloads=$(wl_list | tr '\n' ' '))"

    if ! llmb_have && [[ "${AAT_DRY_RUN:-0}" != 1 ]]; then
        die "llmb-run not on PATH. Set LLMB_VENV in cluster.conf (install.sh creates
 <llmbmarking>/llmb_venv) or activate the venv before running."
    fi
    if [[ -z "${LLMB_INSTALL:-}" || ! -d "${LLMB_INSTALL:-/nonexistent}" ]]; then
        warn "LLMB_INSTALL='${LLMB_INSTALL:-}' is not a directory; NCCL results cannot be parsed"
    fi

    if (( DO_COLLECT )); then
        if [[ -n "$ONLY_RACK" || -n "$ONLY_WL" ]]; then
            collect_filtered
        else
            collect_all
        fi
    fi

    if (( DO_SUBMIT )); then
        if [[ -n "$ONLY_RACK" || -n "$ONLY_WL" ]]; then
            submit_filtered
        else
            submit_pass
        fi
        [[ -n "$SKIP_REASONS" ]] && info "racks not ready this pass:"$'\n'"${SKIP_REASONS%$'\n'}"
    fi

    info "pass end"
}

collect_filtered() {
    local f kind id wlname run
    shopt -s nullglob
    for f in "$STATE_DIR"/racks/*/*.state "$STATE_DIR"/groups/*/*.state; do
        case "$f" in
            "$STATE_DIR"/racks/*)  kind=rack ;;
            *)                     kind=group ;;
        esac
        id="$(basename "$(dirname "$f")")"
        wlname="$(basename "$f" .state)"; run=1
        [[ "$wlname" =~ ^(.*)-run([0-9]+)$ ]] && { wlname="${BASH_REMATCH[1]}"; run="${BASH_REMATCH[2]}"; }
        wl_exists "$wlname" || continue
        [[ -n "$ONLY_WL"   && "$wlname" != "$ONLY_WL" ]] && continue
        if [[ -n "$ONLY_RACK" ]]; then
            [[ "$kind" == rack && "$id" == "$ONLY_RACK" ]] || \
            [[ "$kind" == group && " $(group_racks "$id") " == *" $ONLY_RACK "* ]] || continue
        fi
        collect_one "$kind" "$id" "$wlname" "$run" "$f"
    done
    shopt -u nullglob
}

submit_filtered() {
    local wlname scope per gid r
    for wlname in $(wl_list); do
        [[ "$(wl "$wlname" runner)" == llmb ]] || continue
        [[ -n "$ONLY_WL" && "$wlname" != "$ONLY_WL" ]] && continue
        scope="$(wl "$wlname" scope)"
        case "$scope" in
            rack)
                for r in $(rack_list); do
                    [[ -n "$ONLY_RACK" && "$r" != "$ONLY_RACK" ]] && continue
                    try_submit rack "$r" "$wlname"
                done ;;
            group)
                per="$(wl "$wlname" racks_per_job)"
                for gid in $(group_list "$per"); do
                    if [[ -n "$ONLY_RACK" ]]; then
                        [[ " $(group_racks "$gid") " == *" $ONLY_RACK "* ]] || continue
                    fi
                    try_submit group "$gid" "$wlname"
                done ;;
        esac
    done
    info "submitted $SUBMIT_COUNT job(s) this pass"
}

with_lock orchestrator main
rc=$?
[[ $rc == 75 ]] && exit 0     # another pass already running: not an error
exit $rc
