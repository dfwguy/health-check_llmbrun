#!/bin/bash
# lib/submit.sh - decide what to queue this pass, and queue it.
#
# Rules that matter operationally:
#  * Nothing is submitted for a rack unless every tray is idle. A rack-scale job
#    that pends behind one drained tray is indistinguishable from a hung
#    benchmark until someone reads squeue --start.
#  * Groups are built from the FULL inventory in fixed order, not from the
#    current candidate set, so group ids (and therefore state) are stable as
#    racks come and go.
#  * Budgets are enforced per pass so a cron misfire cannot flood the queue.

[[ -n "${_AAT_SUBMIT_SH:-}" ]] && return 0
_AAT_SUBMIT_SH=1

SUBMIT_COUNT=0
SKIP_REASONS=""

submit_pass() {
    SUBMIT_COUNT=0
    local depth
    depth="$(sl_queue_depth)"
    if (( depth >= QUEUE_DEPTH_LIMIT )); then
        info "queue depth $depth >= QUEUE_DEPTH_LIMIT ($QUEUE_DEPTH_LIMIT) - not submitting this pass"
        return 0
    fi

    local wlname scope per gid r
    for wlname in $(wl_list); do
        [[ "$(wl "$wlname" runner)" == llmb ]] || continue
        scope="$(wl "$wlname" scope)"
        case "$scope" in
            rack)
                for r in $(rack_list); do
                    (( SUBMIT_COUNT >= MAX_SUBMITS_PER_CYCLE )) && { info "submit budget reached"; return 0; }
                    try_submit rack "$r" "$wlname"
                done
                ;;
            group)
                per="$(wl "$wlname" racks_per_job)"
                for gid in $(group_list "$per"); do
                    (( SUBMIT_COUNT >= MAX_SUBMITS_PER_CYCLE )) && { info "submit budget reached"; return 0; }
                    try_submit group "$gid" "$wlname"
                done
                ;;
            node) : ;;   # per-node work is launched by the BCM action on the node
        esac
    done
    info "submitted $SUBMIT_COUNT job(s) this pass"
}

# unit_racks <kind> <id>
unit_racks() {
    if [[ "$1" == rack ]]; then printf '%s' "$2"; else group_racks "$2"; fi
}
unit_nodes() {
    if [[ "$1" == rack ]]; then rack_nodes "$2"; else group_nodes "$2"; fi
}

# gates_met <kind> <id> <workload>  ; echoes the blocking reason when false
gates_met() {
    local kind="$1" id="$2" wlname="$3"
    local g gscope r n runs i f st first
    first="$(unit_racks "$kind" "$id")"; first="${first%% *}"
    for g in $(wl_gates "$wlname"); do
        wl_enabled "$g" || continue
        gscope="$(wl "$g" scope)"
        runs="$(wl "$g" runs)"
        case "$gscope" in
            node)
                for n in $(unit_nodes "$kind" "$id"); do
                    for ((i = 1; i <= runs; i++)); do
                        f="$(result_file "$n" "$g" "$i")"
                        st="$(read_result_status "$f")"
                        [[ "$st" == DONE ]] || { printf '%s not DONE on %s (%s)' "$g" "$n" "$st"; return 1; }
                    done
                done
                ;;
            rack)
                for r in $(unit_racks "$kind" "$id"); do
                    f="$(state_path rack "$r" "$g")"
                    st="$(state_status "$f")"
                    [[ "$st" == DONE ]] || { printf '%s not DONE on rack %s (%s)' "$g" "$r" "$st"; return 1; }
                done
                ;;
            group)
                local ggid
                ggid="$(group_id "$(wl "$g" racks_per_job)" "$first")"
                f="$(state_path group "$ggid" "$g")"
                st="$(state_status "$f")"
                [[ "$st" == DONE ]] || { printf '%s not DONE on group %s (%s)' "$g" "$ggid" "$st"; return 1; }
                ;;
        esac
    done
    return 0
}

# try_submit <kind> <id> <workload> [run]
try_submit() {
    local kind="$1" id="$2" wlname="$3" run="${4:-1}"
    local f status
    f="$(state_path "$kind" "$id" "$wlname" "$run")"
    status="$(state_status "$f")"

    case "$status" in
        DONE|SUBMITTED|RUNNING) return 0 ;;
        FAIL)
            [[ "${RETRY_FAILED:-0}" == 1 ]] || return 0
            ;;
    esac

    local att; att="$(state_get "$f" attempts 0)"
    if (( att >= MAX_ATTEMPTS )); then
        debug "$kind/$id/$wlname: attempts exhausted ($att)"
        return 0
    fi

    local why
    if ! why="$(gates_met "$kind" "$id" "$wlname")"; then
        debug "$kind/$id/$wlname: blocked - $why"
        return 0
    fi

    if [[ "$kind" == rack ]]; then
        if ! why="$(rack_ready "$id")"; then
            debug "$kind/$id/$wlname: not ready - $why"
            SKIP_REASONS+="$id/$wlname: $why"$'\n'
            return 0
        fi
    else
        if ! why="$(group_ready "$id")"; then
            debug "$kind/$id/$wlname: not ready - $why"
            SKIP_REASONS+="$id/$wlname: $why"$'\n'
            return 0
        fi
    fi

    # scale / placement target
    local nracks scale target
    nracks="$(unit_racks "$kind" "$id" | wc -w)"
    scale="$(wl "$wlname" scale)"
    if [[ "$scale" == auto ]]; then scale=$(( nracks * GPUS_PER_RACK )); fi
    [[ "$scale" =~ ^[0-9]+$ ]] || { error "$wlname: bad scale '$scale'"; return 1; }
    target="$(ns_fold "$(unit_nodes "$kind" "$id")")"

    local jid
    if ! jid="$(llmb_submit "$wlname" "$scale" "$nracks" "$target")"; then
        state_set "$f" status=NOT_RUN attempts=$((att + 1)) reason="submit failed"
        return 1
    fi

    # Dry runs must leave no trace: writing state here would make the next real
    # pass believe a job is already in flight.
    if [[ "${AAT_DRY_RUN:-0}" == 1 ]]; then
        SUBMIT_COUNT=$((SUBMIT_COUNT + 1))
        return 0
    fi

    state_set "$f" status=SUBMITTED jobid="$jid" scale="$scale" \
        nodelist="$target" attempts=$((att + 1)) \
        submitted_at="$(date '+%Y-%m-%dT%H:%M:%S%z')" reason=
    info "$kind/$id/$wlname: submitted job $jid (scale=$scale)"
    SUBMIT_COUNT=$((SUBMIT_COUNT + 1))
    [[ "${AAT_DRY_RUN:-0}" == 1 ]] || sleep "${SUBMIT_SLEEP:-10}"
    return 0
}
