#!/bin/bash
# bin/status-daily-report.sh - dated CSV, one row per node.
#
# Metrics now come from the KEY=VALUE lines the collector wrote into each result
# file, so the report never re-parses nccl-tests output or calls llmb-run. NCCL
# workloads expand to one column per collective (peak busbw GB/s); pretrain
# workloads emit TFLOPS/GPU. Everything else emits the status word.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(dirname "$HERE")"
source "$ROOT/lib/common.sh"; source "$ROOT/lib/nodeset.sh"
source "$ROOT/lib/slurm.sh";  source "$ROOT/lib/rack.sh"
source "$ROOT/lib/llmb.sh";   source "$ROOT/lib/results.sh"
_AAT_TAG=report; LOG_LEVEL=WARN
aat_init
rack_load_inventory
mkdir -p "$REPORT_DIR"
OUT="${1:-$REPORT_DIR/report-$(date '+%Y-%m-%d_%H-%M-%S').csv}"

# metric keys per workload -> the sub-columns it contributes
metric_keys() {
    case "$(wl "$1" metric)" in
        nccl_busbw) printf '%s\n' $NCCL_COLLECTIVES ;;
        tflops)     printf 'tflops\n' ;;
    esac
}

field() {   # field <file> <key>
    [[ -r "$1" ]] || return 0
    local v; v="$(grep -m1 "^$2=" "$1" 2>/dev/null || true)"
    printf '%s' "${v#*=}"
}

# ---- header ----
hdr="node,rack"
for col in $(wl_columns); do
    base="${col%%-run*}"
    keys="$(metric_keys "$base")"
    if [[ -z "$keys" ]]; then hdr+=",$col"
    else hdr+=",${col}.status"; for k in $keys; do hdr+=",${col}.$k"; done
    fi
done
printf '%s\n' "$hdr" > "$OUT"

# ---- rows ----
for node in $(ls -1 "$RESULTS_DIR" 2>/dev/null | sort); do
    row="$node,$(node_rack "$node")"
    for col in $(wl_columns); do
        base="${col%%-run*}"
        f="$RESULTS_DIR/$node/${col}.txt"
        st="$(read_result_status "$f")"
        keys="$(metric_keys "$base")"
        if [[ -z "$keys" ]]; then
            row+=",$st"
        else
            row+=",$st"
            for k in $keys; do row+=",$(field "$f" "$k")"; done
        fi
    done
    printf '%s\n' "$row" >> "$OUT"
done
printf 'Report written to: %s\n' "$OUT"
