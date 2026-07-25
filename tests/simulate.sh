#!/bin/bash
# tests/simulate.sh - drive the whole matrix to completion on a simulated
# cluster, then print the operator views. This is the end-to-end rehearsal:
# every state transition, gate, group formation and report path in one run.
#
#   ./simulate.sh [n_racks]        default 8 (-> two 4-rack groups)
#   BAD_RACK=3 ./simulate.sh 8     make rack 3 a marginal-busbw rack
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(dirname "$HERE")"
N="${1:-8}"; BAD="${BAD_RACK:-0}"

TC="$(mktemp -d "${TMPDIR:-/tmp}/aat-sim.XXXXXX")"
export AAT_HOME_OVERRIDE="$TC/home" MOCK_DIR="$TC/mock"
export TEST_INVENTORY="$TC/racks.txt" TEST_WORKLOADS="$ROOT/conf/workloads.conf"
export AAT_CONF="$HERE/fixtures/test-cluster.conf"
export TEST_LOG_LEVEL=WARN TEST_MAX_SUBMITS=99 MOCK_DEFAULT_NODE_STATE=idle MOCK_LLMB_TFLOPS=708.2
mkdir -p "$AAT_HOME_OVERRIDE/llmb" "$MOCK_DIR"
: >"$MOCK_DIR/nodes.state"; : >"$MOCK_DIR/jobs.state"; : >"$MOCK_DIR/calls.log"
PATH="$HERE/mocks:$PATH"; export PATH

: >"$TEST_INVENTORY"
for ((i=1;i<=N;i++)); do
    rack="$(printf 'rack%02d' "$i")"; nodes=""
    for u in 11 12 13 14 15 16 17 18 28 29 30 31 32 33 34 35 36 37; do nodes+=" $rack-$u"; done
    printf '%s A%d%s\n' "$rack" "$i" "$nodes" >>"$TEST_INVENTORY"
done
awk '{for(i=3;i<=NF;i++) print $i}' "$TEST_INVENTORY" | tr '\n' ',' | sed 's/,$//' >"$MOCK_DIR/partition.nodes"

# dcgm passes everywhere (that is the per-node BCM path, simulated)
for node in $(awk '{for(i=3;i<=NF;i++) print $i}' "$TEST_INVENTORY"); do
    mkdir -p "$AAT_HOME_OVERRIDE/results/$node"
    printf 'workload=dcgm\nDONE\n' >"$AAT_HOME_OVERRIDE/results/$node/dcgm.txt"
done

orch() { bash "$ROOT/bin/rack-orchestrator.sh" "$@" >/dev/null 2>&1; }

# complete every in-flight job, inventing plausible results
complete_inflight() {
    local sf jid wl busbw rackno
    while IFS= read -r sf; do
        [[ "$(grep -m1 '^status=' "$sf" | cut -d= -f2)" =~ ^(SUBMITTED|RUNNING)$ ]] || continue
        jid="$(grep -m1 '^jobid=' "$sf" | cut -d= -f2)"; [[ -n "$jid" ]] || continue
        wl="$(basename "$sf" .state)"
        if [[ "$wl" == nccl_* ]]; then
            busbw=915.3
            rackno="$(basename "$(dirname "$sf")" | sed 's/^rack0*//; s/^g[0-9]*_.*//')"
            [[ -n "$rackno" && "$rackno" == "$BAD" ]] && busbw=449.0
            [[ "$wl" == nccl_multi ]] && busbw=612.0
            bash "$HERE/fixtures/mk_nccl_logs.sh" "$AAT_HOME_OVERRIDE/llmb" "$jid" "$busbw" 13 >/dev/null
        fi
        grep -v "^$jid " "$MOCK_DIR/jobs.state" >"$MOCK_DIR/j.n" 2>/dev/null || : >"$MOCK_DIR/j.n"
        mv "$MOCK_DIR/j.n" "$MOCK_DIR/jobs.state"
        printf '%s COMPLETED 00:45:00 x\n' "$jid" >>"$MOCK_DIR/jobs.state"
    done < <(find "$AAT_HOME_OVERRIDE/state" -name '*.state' 2>/dev/null | sort)
}

printf '== simulating %d racks (%d GPUs)%s ==\n\n' "$N" $((N*72)) \
    "$([[ "$BAD" != 0 ]] && printf ', rack %s marginal' "$BAD")"
for pass in 1 2 3 4 5 6; do
    orch
    inflight="$(find "$AAT_HOME_OVERRIDE/state" -name '*.state' -exec grep -l '^status=\(SUBMITTED\|RUNNING\)' {} + 2>/dev/null | wc -l)"
    done_n="$(find "$AAT_HOME_OVERRIDE/state" -name '*.state' -exec grep -l '^status=DONE' {} + 2>/dev/null | wc -l)"
    fail_n="$(find "$AAT_HOME_OVERRIDE/state" -name '*.state' -exec grep -l '^status=FAIL' {} + 2>/dev/null | wc -l)"
    printf 'pass %d: %2d in flight, %2d done, %2d failed\n' "$pass" "$inflight" "$done_n" "$fail_n"
    complete_inflight
done
orch

printf '\n'; bash "$ROOT/bin/rack-status.sh" 2>&1
printf '\n== metrics view ==\n'; bash "$ROOT/bin/rack-status.sh" --metrics 2>&1 | head -"$((N+4))"
printf '\n== CSV report (first 3 lines, first 8 columns) ==\n'
bash "$ROOT/bin/status-daily-report.sh" "$TC/r.csv" >/dev/null 2>&1
head -3 "$TC/r.csv" | cut -d, -f1-8 | sed 's/^/  /'
printf '\n== llmb-run calls issued ==\n'
sed 's/^/  /' "$MOCK_DIR/llmb.args.log" | sed 's/--exclude .*/--exclude <partition minus target>/' | sort | uniq -c | sed 's/^/  /'
rm -rf "$TC"
