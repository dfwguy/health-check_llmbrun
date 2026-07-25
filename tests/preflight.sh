#!/bin/bash
# tests/preflight.sh - dry-run the orchestrator against the inventory this repo
# is configured with, using mocked slurm + llmb-run so it works off-cluster.
#
# Run this before deploying and read the commands it prints. If these are not
# the llmb-run lines you want executed on the cluster, fix conf/ - not the scripts.
#
#   ./preflight.sh [n_racks_to_simulate_as_dcgm_passed]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(dirname "$HERE")"
N="${1:-8}"

TC="$(mktemp -d "${TMPDIR:-/tmp}/aat-preflight.XXXXXX")"
export AAT_HOME_OVERRIDE="$TC/home"  MOCK_DIR="$TC/mock"
# Prefer the real (interview-generated) inventory; fall back to the shipped example.
if [[ -r "$ROOT/conf/inventory/racks.txt" ]]; then
    export TEST_INVENTORY="$ROOT/conf/inventory/racks.txt"
else
    export TEST_INVENTORY="$ROOT/conf/inventory/racks.txt.example"
    printf 'note: no conf/inventory/racks.txt yet - using the shipped example.\n'
    printf '      run bin/interview.sh on the head node for the real thing.\n\n'
fi
export TEST_WORKLOADS="$ROOT/conf/workloads.conf"
export AAT_CONF="$HERE/fixtures/test-cluster.conf"
export TEST_LOG_LEVEL=INFO TEST_MAX_SUBMITS=99 MOCK_DEFAULT_NODE_STATE=idle
mkdir -p "$AAT_HOME_OVERRIDE" "$MOCK_DIR"
: >"$MOCK_DIR/nodes.state"; : >"$MOCK_DIR/jobs.state"; : >"$MOCK_DIR/calls.log"
awk '!/^#/{for(i=3;i<=NF;i++) print $i}' "$TEST_INVENTORY" | tr '\n' ',' | sed 's/,$//' >"$MOCK_DIR/partition.nodes"
PATH="$HERE/mocks:$PATH"; export PATH

printf '== inventory ==\n'
awk '!/^#/{r++; n+=NF-2} END{printf "  %d racks, %d trays, %d GPUs\n", r, n, n*4}' "$TEST_INVENTORY"

# simulate: dcgm passed on the first N racks
i=0
while read -r rack; do
    i=$((i+1)); [[ $i -gt $N ]] && break
    for node in $(awk -v r="$rack" '!/^#/ && $1==r{for(j=3;j<=NF;j++) print $j}' "$TEST_INVENTORY"); do
        mkdir -p "$AAT_HOME_OVERRIDE/results/$node"
        printf 'workload=dcgm\nDONE\n' >"$AAT_HOME_OVERRIDE/results/$node/dcgm.txt"
    done
done < <(awk '!/^#/{print $1}' "$TEST_INVENTORY")
printf '  simulating dcgm=DONE on the first %d racks\n\n' "$N"

printf '== commands the orchestrator would run ==\n'
bash "$ROOT/bin/rack-orchestrator.sh" --dry-run 2>&1 \
  | grep -E 'DRY-RUN|ERROR' | sed 's/^/  /'
printf '\n'
# aat_init always creates the state DIRECTORY; what must not appear is a .state FILE.
if find "$AAT_HOME_OVERRIDE/state" -name '*.state' 2>/dev/null | grep -q .; then
    printf '!! dry run wrote state files - BUG\n'
else
    printf '== dry run wrote no state files (correct) ==\n'
fi
rm -rf "$TC"
