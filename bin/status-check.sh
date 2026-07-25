#!/bin/bash
# bin/status-check.sh - live per-node status for every workload column.
# Same output contract as the sbatch original ("node: column: STATUS", grouped
# with dshbak when available) but the column list now comes from the workload
# table instead of grepping a variable out of launch_job.sh.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(dirname "$HERE")"
source "$ROOT/lib/common.sh"; source "$ROOT/lib/nodeset.sh"
source "$ROOT/lib/slurm.sh";  source "$ROOT/lib/rack.sh"
source "$ROOT/lib/results.sh"
_AAT_TAG=status-check; LOG_LEVEL=WARN
aat_init
rack_load_inventory

emit() {
    local node col f st
    for node in $(ls -1 "$RESULTS_DIR" 2>/dev/null | sort); do
        for col in $(wl_columns); do
            f="$RESULTS_DIR/$node/${col}.txt"
            st="$(read_result_status "$f")"
            printf '%s: %s: %s\n' "$node" "$col" "$st"
        done
    done
}

if command -v dshbak >/dev/null 2>&1; then emit | sort | dshbak -c; else emit | sort; fi
