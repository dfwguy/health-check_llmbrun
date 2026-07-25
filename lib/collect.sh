#!/bin/bash
# lib/collect.sh - advance every in-flight rack/group job to a verdict.
#
# State machine per (unit, workload, run):
#
#   NOT_RUN --submit--> SUBMITTED --slurm running--> RUNNING
#                            \                          |
#                             \-- job vanished ----.    |  terminal slurm state
#                                                  v    v
#                                        FAIL <-- score/parse --> DONE
#
# FAIL also fans out to the trays (results/<node>/<wl>.txt) and, when
# ON_RACK_FAIL=drain, drains them with a reason a human can read in sinfo -R.

[[ -n "${_AAT_COLLECT_SH:-}" ]] && return 0
_AAT_COLLECT_SH=1

# Grace period for a submitted job to become visible to sacct/squeue.
: "${SUBMIT_GRACE_MIN:=10}"

collect_all() {
    local f kind id wlname run
    shopt -s nullglob
    for f in "$STATE_DIR"/racks/*/*.state "$STATE_DIR"/groups/*/*.state; do
        case "$f" in
            "$STATE_DIR"/racks/*)  kind=rack  ;;
            "$STATE_DIR"/groups/*) kind=group ;;
            *) continue ;;
        esac
        id="$(basename "$(dirname "$f")")"
        wlname="$(basename "$f" .state)"
        run=1
        if [[ "$wlname" =~ ^(.*)-run([0-9]+)$ ]]; then
            wlname="${BASH_REMATCH[1]}"; run="${BASH_REMATCH[2]}"
        fi
        wl_exists "$wlname" || { debug "state file for unknown workload: $f"; continue; }
        collect_one "$kind" "$id" "$wlname" "$run" "$f"
    done
    shopt -u nullglob
}

collect_one() {
    local kind="$1" id="$2" wlname="$3" run="$4" f="$5"
    local status jid
    status="$(state_status "$f")"
    case "$status" in SUBMITTED|RUNNING) ;; *) return 0 ;; esac

    jid="$(state_get "$f" jobid)"
    if [[ -z "$jid" ]]; then
        _verdict "$kind" "$id" "$wlname" "$run" "$f" FAIL "state had no job id"
        return 0
    fi

    local sstate hours
    sstate="$(sl_job_state "$jid")"
    hours="$(sl_job_elapsed_hours "$jid")"
    debug "$kind/$id/$wlname job=$jid slurm=$sstate elapsed=${hours}h"

    # Job not known to Slurm at all.
    if [[ "$sstate" == UNKNOWN ]]; then
        local age_min
        age_min="$(_state_age_minutes "$f")"
        if (( age_min > SUBMIT_GRACE_MIN )); then
            _maybe_retry "$kind" "$id" "$wlname" "$run" "$f" \
                "job $jid unknown to slurm after ${age_min}m"
        else
            debug "$kind/$id/$wlname job $jid not visible yet (${age_min}m old)"
        fi
        return 0
    fi

    if [[ "$sstate" == RUNNING && "$status" != RUNNING ]]; then
        state_set "$f" status=RUNNING started_at="$(date '+%Y-%m-%dT%H:%M:%S%z')"
        status=RUNNING
    fi

    # Wall-clock guard: a rack-scale job that outruns its window is a hang.
    if ! sl_state_is_terminal "$sstate"; then
        if (( hours >= MAX_RACK_JOB_HOURS )); then
            warn "$kind/$id/$wlname job $jid exceeded ${MAX_RACK_JOB_HOURS}h - cancelling"
            sl_cancel "$jid"
            _verdict "$kind" "$id" "$wlname" "$run" "$f" FAIL \
                "timeout after ${hours}h in state $sstate"
        fi
        return 0
    fi

    # -------- terminal -------------------------------------------------------
    if [[ "$sstate" != COMPLETED ]]; then
        if sl_state_is_infra "$sstate"; then
            _maybe_retry "$kind" "$id" "$wlname" "$run" "$f" "slurm state $sstate"
        else
            _verdict "$kind" "$id" "$wlname" "$run" "$f" FAIL "slurm state $sstate"
        fi
        return 0
    fi

    # COMPLETED - now score the actual numbers.
    local metric reason=""
    metric="$(wl "$wlname" metric)"
    local -a kvs=()
    case "$metric" in
        nccl_busbw)
            local dir
            if ! dir="$(llmb_nccl_logdir "$jid" "$(wl "$wlname" llmb_workload)")"; then
                _verdict "$kind" "$id" "$wlname" "$run" "$f" FAIL \
                    "job COMPLETED but no NCCL result dir found under \$LLMB_INSTALL for job $jid"
                return 0
            fi
            local line
            while IFS= read -r line; do [[ -n "$line" ]] && kvs+=("$line"); done < <(llmb_nccl_peaks "$dir")
            reason="$(score_nccl "$(wl "$wlname" thresholds)" "${kvs[@]}")"
            if [[ -z "$reason" ]]; then
                reason="$(outlier_check "$wlname" "${kvs[@]}")"
                [[ -n "$reason" ]] && reason="outlier: $reason"
            fi
            state_set "$f" logdir="$dir"
            ;;
        tflops)
            local tf
            tf="$(llmb_job_tflops "$jid")"
            kvs=("tflops=${tf:-}")
            reason="$(score_tflops "$(wl "$wlname" thresholds)" "$tf")"
            if [[ -z "$reason" && -n "$tf" ]]; then
                reason="$(outlier_check "$wlname" "tflops=$tf")"
                [[ -n "$reason" ]] && reason="outlier: $reason"
            fi
            ;;
        -|"")
            : ;;   # completion is the whole test
        *)
            warn "$wlname: unknown metric '$metric'; treating COMPLETED as pass" ;;
    esac

    # Record metrics on the state file so fleet_mean/report can use them.
    local kv setargs=()
    for kv in "${kvs[@]:-}"; do [[ -n "$kv" ]] && setargs+=("m_${kv%%=*}=${kv#*=}"); done
    (( ${#setargs[@]} )) && state_set "$f" "${setargs[@]}"

    if [[ -n "$reason" ]]; then
        _verdict "$kind" "$id" "$wlname" "$run" "$f" FAIL "$reason" "${kvs[@]:-}"
    else
        _verdict "$kind" "$id" "$wlname" "$run" "$f" DONE "" "${kvs[@]:-}"
    fi
}

# _verdict <kind> <id> <wl> <run> <statefile> <DONE|FAIL> <reason> [kv ...]
_verdict() {
    local kind="$1" id="$2" wlname="$3" run="$4" f="$5" status="$6" reason="$7"; shift 7
    local nodes
    if [[ "$kind" == rack ]]; then nodes="$(rack_nodes "$id")"; else nodes="$(group_nodes "$id")"; fi

    state_set "$f" status="$status" reason="$reason" finished_at="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    fanout_result "$wlname" "$run" "$status" "$reason" "$nodes" "$@"

    if [[ "$status" == DONE ]]; then
        info "$kind/$id/$wlname: DONE ${*:+(${*})}"
        return 0
    fi

    error "$kind/$id/$wlname: FAIL - $reason"
    if [[ "${ON_RACK_FAIL:-drain}" == drain && -n "$nodes" ]]; then
        sl_drain "$(ns_fold "$nodes")" "$wlname FAIL: $reason"
    fi
}

# Infra failures get MAX_ATTEMPTS tries before becoming a real FAIL.
_maybe_retry() {
    local kind="$1" id="$2" wlname="$3" run="$4" f="$5" why="$6"
    local att; att="$(state_get "$f" attempts 1)"
    if [[ "${RETRY_INFRA_FAIL:-1}" == 1 ]] && (( att < MAX_ATTEMPTS )); then
        warn "$kind/$id/$wlname: $why - resetting for retry (attempt $att/$MAX_ATTEMPTS)"
        state_set "$f" status=NOT_RUN reason="retry after: $why" jobid=
        return 0
    fi
    _verdict "$kind" "$id" "$wlname" "$run" "$f" FAIL "$why (attempts=$att)"
}

_state_age_minutes() {
    local f="$1" then now
    then="$(state_get "$f" submitted_at)"
    [[ -z "$then" ]] && { printf '9999'; return 0; }
    then="$(date -d "$then" +%s 2>/dev/null || printf '')"
    [[ -z "$then" ]] && { printf '9999'; return 0; }
    now="$(date +%s)"
    printf '%s' $(( (now - then) / 60 ))
}
