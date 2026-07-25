#!/bin/bash
# bin/rack-status.sh - the bring-up call view: one row per rack, one column per
# workload, plus outliers and what is blocking the rest.
#
#   ./rack-status.sh              # matrix + summary
#   ./rack-status.sh --metrics    # show numbers instead of statuses
#   ./rack-status.sh --pending    # only racks with work left, and why
#   ./rack-status.sh --rack rack01
#
# Equivalent of the reference validation_tracker.py, minus the fleet-wide
# statistics that only make sense once a few hundred racks have run.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(dirname "$HERE")"
source "$ROOT/lib/common.sh"; source "$ROOT/lib/nodeset.sh"
source "$ROOT/lib/slurm.sh";  source "$ROOT/lib/rack.sh"
source "$ROOT/lib/llmb.sh";   source "$ROOT/lib/results.sh"
source "$ROOT/lib/submit.sh"

MODE=matrix
ONLY_RACK=""
while (( $# )); do
    case "$1" in
        --metrics) MODE=metrics ;;
        --pending) MODE=pending ;;
        --rack)    ONLY_RACK="${2:-}"; shift ;;
        -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 1 ;;
    esac
    shift
done

_AAT_TAG=rack-status
LOG_LEVEL=WARN
aat_init
rack_load_inventory

# Status of one workload for one rack, resolving group-scope workloads to the
# group this rack belongs to.
cell_status() {
    local rack="$1" wlname="$2" scope f
    scope="$(wl "$wlname" scope)"
    case "$scope" in
        node)
            local n st worst=DONE
            for n in $(rack_nodes "$rack"); do
                st="$(read_result_status "$(result_file "$n" "$wlname" 1)")"
                case "$st" in
                    FAIL) printf 'FAIL'; return 0 ;;
                    NOT_RUN)     worst=NOT_RUN ;;
                    IN_PROGRESS) [[ "$worst" == NOT_RUN ]] || worst=IN_PROGRESS ;;
                esac
            done
            printf '%s' "$worst" ;;
        rack)
            f="$(state_path rack "$rack" "$wlname")"; state_status "$f" ;;
        group)
            local gid
            gid="$(_group_of "$rack" "$(wl "$wlname" racks_per_job)")"
            [[ -z "$gid" ]] && { printf 'N/A'; return 0; }
            f="$(state_path group "$gid" "$wlname")"; state_status "$f" ;;
    esac
}

cell_metric() {
    local rack="$1" wlname="$2" scope f m
    scope="$(wl "$wlname" scope)"
    case "$scope" in
        rack)  f="$(state_path rack "$rack" "$wlname")" ;;
        group) local gid; gid="$(_group_of "$rack" "$(wl "$wlname" racks_per_job)")"
               [[ -z "$gid" ]] && { printf '-'; return 0; }
               f="$(state_path group "$gid" "$wlname")" ;;
        *)     printf '-'; return 0 ;;
    esac
    case "$(wl "$wlname" metric)" in
        nccl_busbw) m="$(state_get "$f" m_all_reduce)"; printf '%s' "${m:--}" ;;
        tflops)     m="$(state_get "$f" m_tflops)";     printf '%s' "${m:--}" ;;
        *)          printf '-' ;;
    esac
}

_group_of() { group_of "$1" "$2"; }

colour() {
    case "$1" in
        DONE)        printf '\033[32m%s\033[0m' "$1" ;;
        FAIL)        printf '\033[31m%s\033[0m' "$1" ;;
        RUNNING|SUBMITTED) printf '\033[36m%s\033[0m' "$1" ;;
        *)           printf '%s' "$1" ;;
    esac
}
[[ -t 1 ]] || colour() { printf '%s' "$1"; }

racks_to_show() {
    if [[ -n "$ONLY_RACK" ]]; then printf '%s\n' "$ONLY_RACK"; else rack_list; fi
}

print_matrix() {
    local -a cols=()
    local w
    while IFS= read -r w; do cols+=("$w"); done < <(wl_list)

    printf '%-22s %-10s' rack slurm
    for w in "${cols[@]}"; do printf ' %-12s' "${w:0:12}"; done
    printf '\n'
    printf '%-22s %-10s' '----------------------' '----------'
    for w in "${cols[@]}"; do printf ' %-12s' '------------'; done
    printf '\n'

    local rack st idle total n cell val
    local -A tally=()
    while IFS= read -r rack; do
        idle=0; total=0
        for n in $(rack_nodes "$rack"); do
            total=$((total + 1))
            [[ "$(sl_node_state "$n")" == idle ]] && idle=$((idle + 1))
        done
        printf '%-22s %-10s' "$rack" "$idle/$total idle"
        for w in "${cols[@]}"; do
            cell="$(cell_status "$rack" "$w")"
            tally["$w/$cell"]=$(( ${tally[$w/$cell]:-0} + 1 ))
            if [[ "$MODE" == metrics ]]; then
                val="$(cell_metric "$rack" "$w")"
                printf ' %-12s' "$val"
            else
                printf ' %-12b' "$(colour "$cell")"
            fi
        done
        printf '\n'
    done < <(racks_to_show)

    printf '\n%-14s %8s %8s %8s %8s %8s\n' workload DONE FAIL RUNNING SUBMITTED NOT_RUN
    for w in "${cols[@]}"; do
        printf '%-14s %8s %8s %8s %8s %8s\n' "$w" \
            "${tally[$w/DONE]:-0}" "${tally[$w/FAIL]:-0}" "${tally[$w/RUNNING]:-0}" \
            "${tally[$w/SUBMITTED]:-0}" "${tally[$w/NOT_RUN]:-0}"
    done
}

print_failures() {
    local shown=0 f rack w reason
    while IFS= read -r rack; do
        for w in $(wl_list); do
            [[ "$(cell_status "$rack" "$w")" == FAIL ]] || continue
            case "$(wl "$w" scope)" in
                rack)  f="$(state_path rack "$rack" "$w")" ;;
                group) f="$(state_path group "$(_group_of "$rack" "$(wl "$w" racks_per_job)")" "$w")" ;;
                *)     f="" ;;
            esac
            reason="$([[ -n "$f" ]] && state_get "$f" reason)"
            (( shown == 0 )) && printf '\nTO INVESTIGATE\n--------------\n'
            printf '  %-22s %-14s %s\n' "$rack" "$w" "${reason:-see results/}"
            shown=1
        done
    done < <(racks_to_show)
}

print_pending() {
    printf '%-22s %-14s %s\n' rack workload blocked-by
    printf '%-22s %-14s %s\n' '----------------------' '--------------' '----------'
    local rack w st why
    while IFS= read -r rack; do
        for w in $(wl_list); do
            st="$(cell_status "$rack" "$w")"
            case "$st" in DONE|FAIL|RUNNING|SUBMITTED|N/A) continue ;; esac
            if ! why="$(gates_met rack "$rack" "$w")"; then :
            elif ! why="$(rack_ready "$rack")"; then :
            else why="eligible - waiting for a submit slot"; fi
            printf '%-22s %-14s %s\n' "$rack" "$w" "$why"
        done
    done < <(racks_to_show)
}

case "$MODE" in
    pending) print_pending ;;
    *)       print_matrix; print_failures ;;
esac
