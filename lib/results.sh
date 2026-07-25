#!/bin/bash
# lib/results.sh - turn an llmb job into (a) a pass/fail verdict and (b) the
# per-node result files the existing status/report tooling already understands.
#
# The compat contract is deliberately unchanged from the sbatch original:
#   results/<node>/<workload>[-runN].txt  with DONE or FAIL as the LAST line.
# Everything above the last line is free-form KEY=VALUE, so status-daily-report
# can pull metrics without re-reading llmb.

[[ -n "${_AAT_RESULTS_SH:-}" ]] && return 0
_AAT_RESULTS_SH=1

# ------------------------------------------------------------- thresholds ----
# thr_get <thresholds_string> <key>  ("a:1,b:2" -> value or empty)
thr_get() {
    local spec="$1" key="$2" part
    [[ "$spec" == "-" || -z "$spec" ]] && return 0
    IFS=',' read -r -a _parts <<<"$spec"
    for part in "${_parts[@]}"; do
        [[ "${part%%:*}" == "$key" ]] && { printf '%s' "${part#*:}"; return 0; }
    done
}

# score_nccl <thresholds> <"k=v" ...>
# Echoes "" when everything passes, otherwise a comma-joined failure reason.
score_nccl() {
    local spec="$1"; shift
    local kv k v floor bad=""
    local any=0
    for kv in "$@"; do
        k="${kv%%=*}"; v="${kv#*=}"
        [[ -z "$v" ]] && v=0
        fgt "$v" 0 && any=1
        floor="$(thr_get "$spec" "$k")"
        [[ -z "$floor" ]] && continue
        if flt "$v" "$floor"; then bad+="${bad:+,}$k=$v<$floor"; fi
    done
    if (( any == 0 )); then
        printf 'no busbw parsed from results'
        return 0
    fi
    printf '%s' "$bad"
}

# score_tflops <thresholds> <value>
score_tflops() {
    local spec="$1" v="${2:-}"
    local floor; floor="$(thr_get "$spec" tflops)"
    if [[ -z "$v" ]]; then printf 'no TFLOPS/GPU reported'; return 0; fi
    if [[ -n "$floor" ]] && flt "$v" "$floor"; then printf 'tflops=%s<%s' "$v" "$floor"; fi
}

# --------------------------------------------------- fleet-relative outlier --
# fleet_mean <workload> <metric_key>
# Mean of that metric over every rack whose state file says status=DONE.
fleet_mean() {
    local wlname="$1" key="$2" f vals=""
    for f in "$STATE_DIR"/racks/*/"$wlname".state "$STATE_DIR"/groups/*/"$wlname".state; do
        [[ -r "$f" ]] || continue
        [[ "$(state_get "$f" status)" == DONE ]] || continue
        local v; v="$(state_get "$f" "m_$key")"
        [[ -n "$v" ]] && vals+=" $v"
    done
    printf '%s' "$vals" | awk '{ n=0; s=0; for (i=1;i<=NF;i++) { s+=$i; n++ } if (n) printf "%.1f %d", s/n, n; else printf "0 0" }'
}

# outlier_check <workload> <thresholds_keys...> <"k=v" ...>
# Flags a metric that is more than OUTLIER_FRAC below the fleet mean, once at
# least OUTLIER_MIN_SAMPLES racks have passed. Absolute floors catch gross
# failures; this catches the marginal rack that a fixed floor would wave through.
outlier_check() {
    local wlname="$1"; shift
    local kv k v mean n bad=""
    for kv in "$@"; do
        k="${kv%%=*}"; v="${kv#*=}"
        read -r mean n <<<"$(fleet_mean "$wlname" "$k")"
        (( n >= OUTLIER_MIN_SAMPLES )) || continue
        fgt "$mean" 0 || continue
        local floor
        floor="$(awk -v m="$mean" -v f="$OUTLIER_FRAC" 'BEGIN{printf "%.1f", m*(1-f)}')"
        if flt "$v" "$floor"; then bad+="${bad:+,}$k=$v<${floor}(fleet_mean=$mean,n=$n)"; fi
    done
    printf '%s' "$bad"
}

# ---------------------------------------------------------------- fan-out ----
# result_file <node> <workload> <run>
result_file() {
    local node="$1" wlname="$2" run="${3:-1}"
    if [[ "$run" -gt 1 ]] 2>/dev/null; then
        printf '%s/%s/%s-run%s.txt' "$RESULTS_DIR" "$node" "$wlname" "$run"
    else
        printf '%s/%s/%s.txt' "$RESULTS_DIR" "$node" "$wlname"
    fi
}

# fanout_result <workload> <run> <status DONE|FAIL> <reason> <nodes> <"k=v" ...>
fanout_result() {
    local wlname="$1" run="$2" status="$3" reason="$4" nodes="$5"; shift 5
    local node f kv
    for node in $nodes; do
        f="$(result_file "$node" "$wlname" "$run")"
        mkdir -p "$(dirname "$f")"
        {
            printf '# auto-action-trigger (llmb-run) result\n'
            printf 'workload=%s\n' "$wlname"
            printf 'node=%s\n' "$node"
            printf 'rack=%s\n' "$(node_rack "$node")"
            printf 'generated=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
            [[ -n "$reason" ]] && printf 'reason=%s\n' "$reason"
            for kv in "$@"; do printf '%s\n' "$kv"; done
            printf '%s\n' "$status"          # MUST stay last: compat contract
        } >"$f"
    done
}

# Convenience: mark every node of a rack/group at once.
fanout_rack()  { local r="$1"; shift; fanout_result "$1" "$2" "$3" "$4" "$(rack_nodes "$r")"  "${@:5}"; }
fanout_group() { local g="$1"; shift; fanout_result "$1" "$2" "$3" "$4" "$(group_nodes "$g")" "${@:5}"; }

# read_result_status <file> -> DONE | FAIL | IN_PROGRESS | NOT_RUN
read_result_status() {
    local f="$1"
    [[ -f "$f" ]] || { printf 'NOT_RUN'; return 0; }
    case "$(tail -1 "$f" 2>/dev/null)" in
        DONE) printf 'DONE' ;;
        FAIL) printf 'FAIL' ;;
        *)    printf 'IN_PROGRESS' ;;
    esac
}
