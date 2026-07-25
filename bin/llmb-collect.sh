#!/bin/bash
# bin/llmb-collect.sh - collection pass only (no submissions).
# Useful as a separate, more frequent cron entry, or during triage.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(dirname "$HERE")"
source "$ROOT/lib/common.sh";  source "$ROOT/lib/nodeset.sh"
source "$ROOT/lib/slurm.sh";   source "$ROOT/lib/rack.sh"
source "$ROOT/lib/llmb.sh";    source "$ROOT/lib/results.sh"
source "$ROOT/lib/collect.sh"
[[ "${1:-}" == "-v" ]] && { LOG_LEVEL=DEBUG; export LOG_LEVEL; }
_AAT_TAG=collect
aat_init
rack_load_inventory
with_lock collect collect_all
rc=$?; [[ $rc == 75 ]] && exit 0; exit $rc
