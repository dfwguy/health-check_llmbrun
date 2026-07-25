#!/bin/bash
# tests/run-tests.sh - offline validation suite.
#
# Runs the real scripts against mock slurm + mock llmb-run, so the whole submit
# -> track -> score -> fan-out -> drain path is exercised without a cluster.
#
#   ./run-tests.sh              # everything
#   ./run-tests.sh submit       # only tests whose name matches 'submit'
#   ./run-tests.sh -v           # keep temp dirs and show command output
#
# Every test is independent and gets a fresh temp tree.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$TESTS_DIR")"
MOCKS="$TESTS_DIR/mocks"
FIX="$TESTS_DIR/fixtures"

VERBOSE=0
FILTER=""
for a in "$@"; do
    case "$a" in
        -v|--verbose) VERBOSE=1 ;;
        *) FILTER="$a" ;;
    esac
done

PASS=0; FAIL=0; SKIP=0
declare -a FAILED=()
CURRENT=""

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
[[ -t 1 ]] || { c_red=""; c_grn=""; c_yel=""; c_dim=""; c_off=""; }

# --------------------------------------------------------------- assertions --
_fail() {
    FAIL=$((FAIL + 1)); FAILED+=("$CURRENT")
    printf '%s  FAIL%s %s\n       %s\n' "$c_red" "$c_off" "$CURRENT" "$1"
    [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/       | /'
    return 1
}
_ok() { PASS=$((PASS + 1)); printf '%s  ok  %s %s\n' "$c_grn" "$c_off" "$CURRENT"; }

assert_eq() {       # assert_eq <expected> <actual> [msg]
    [[ "$1" == "$2" ]] && return 0
    _fail "${3:-values differ}: expected [$1] got [$2]"
}
assert_ne()      { [[ "$1" != "$2" ]] || _fail "${3:-values should differ}: both [$1]"; }
assert_contains(){ [[ "$1" == *"$2"* ]] || _fail "${3:-missing substring}: [$2]" "$1"; }
assert_lacks()   { [[ "$1" != *"$2"* ]] || _fail "${3:-unexpected substring}: [$2]" "$1"; }
assert_file()    { [[ -f "$1" ]] || _fail "${2:-expected file}: $1"; }
assert_no_file() { [[ ! -f "$1" ]] || _fail "${2:-file should not exist}: $1"; }
assert_grep()    { grep -q -- "$2" "$1" 2>/dev/null || _fail "${3:-pattern not in file}: $2 in $1" "$(head -30 "$1" 2>/dev/null)"; }
assert_rc()      { [[ "$1" == "$2" ]] || _fail "${3:-exit code}: expected $1 got $2"; }
# `grep -c` prints 0 and exits 1 on no match, so `grep -c ... || printf 0`
# emits "0\n0". Same trap as sl_queue_depth had; tests/lint.sh now flags it.
count_lines() {
    local n=0
    [[ -f "$1" ]] && n="$(grep -c . "$1" 2>/dev/null || true)"
    printf '%s' "${n:-0}"
}

# ---------------------------------------------------------------- fixtures ---
# make_inventory <file> <n_racks>
# Uses the real the target cluster shape: 18 trays per rack, U numbers 11-18 and 28-37.
make_inventory() {
    local f="$1" n="$2" i u nodes rack
    : >"$f"
    printf '# test inventory\n' >>"$f"
    for ((i = 1; i <= n; i++)); do
        rack="$(printf 'rack%02d' "$i")"
        nodes=""
        for u in 11 12 13 14 15 16 17 18 28 29 30 31 32 33 34 35 36 37; do
            nodes+=" $rack-$u"
        done
        printf '%s A%d%s\n' "$rack" "$i" "$nodes" >>"$f"
    done
}

# setup <n_racks> - exports the environment a case needs
setup() {
    local nracks="${1:-4}"
    TC="$(mktemp -d "${TMPDIR:-/tmp}/aat-test.XXXXXX")"
    export AAT_HOME_OVERRIDE="$TC/home"
    export MOCK_DIR="$TC/mock"
    export TEST_INVENTORY="$TC/racks.txt"
    export TEST_WORKLOADS="$TC/workloads.conf"
    export AAT_CONF="$FIX/test-cluster.conf"
    export TEST_LOG_LEVEL="${TEST_LOG_LEVEL:-WARN}"
    mkdir -p "$AAT_HOME_OVERRIDE" "$MOCK_DIR" "$AAT_HOME_OVERRIDE/llmb"
    : >"$MOCK_DIR/calls.log"; : >"$MOCK_DIR/nodes.state"; : >"$MOCK_DIR/jobs.state"
    make_inventory "$TEST_INVENTORY" "$nracks"
    cp "$ROOT/conf/workloads.conf" "$TEST_WORKLOADS"
    # partition = every node in the inventory, plus one foreign rack so that
    # --exclude has something real to subtract.
    { awk '!/^#/{for(i=3;i<=NF;i++) print $i}' "$TEST_INVENTORY";
      printf 'other01-11\nother01-12\n'; } | tr '\n' ',' | sed 's/,$//' >"$MOCK_DIR/partition.nodes"
    PATH="$MOCKS:$PATH"; export PATH
    unset MOCK_LLMB_MODE MOCK_LLMB_HAS_JOBS MOCK_LLMB_FAIL MOCK_LLMB_NOJOBID \
          MOCK_LLMB_JOBID_STYLE MOCK_LLMB_TFLOPS AAT_DRY_RUN AAT_ALLOW_UNPINNED \
          TEST_MAX_SUBMITS TEST_QUEUE_LIMIT
    export MOCK_DEFAULT_NODE_STATE=idle
}

teardown() {
    [[ "$VERBOSE" == 1 ]] && { printf '%s    temp: %s%s\n' "$c_dim" "$TC" "$c_off"; return 0; }
    [[ -n "${TC:-}" && "$TC" == */aat-test.* ]] && rm -rf "$TC"
}

# ------------------------------------------------------------------ helpers --
orch()   { bash "$ROOT/bin/rack-orchestrator.sh" "$@" 2>&1; }
rstat()  { bash "$ROOT/bin/rack-status.sh" "$@" 2>&1; }
libsh()  { bash -c "set -uo pipefail
    source '$ROOT/lib/common.sh'; source '$ROOT/lib/nodeset.sh'
    source '$ROOT/lib/slurm.sh';  source '$ROOT/lib/rack.sh'
    source '$ROOT/lib/llmb.sh';   source '$ROOT/lib/results.sh'
    source '$ROOT/lib/submit.sh'; source '$ROOT/lib/collect.sh'
    $1" 2>&1; }

# mark a node-scope workload DONE for every node of a rack
pass_node_wl() {
    local rack="$1" wlname="$2" n f
    for n in $(rack_nodes_of "$rack"); do
        f="$AAT_HOME_OVERRIDE/results/$n/$wlname.txt"
        mkdir -p "$(dirname "$f")"
        printf 'workload=%s\nDONE\n' "$wlname" >"$f"
    done
}
rack_nodes_of() { awk -v r="$1" '!/^#/ && $1==r {for(i=3;i<=NF;i++) print $i}' "$TEST_INVENTORY"; }
racks_in_inv()  { awk '!/^#/{print $1}' "$TEST_INVENTORY"; }

set_job() {   # set_job <jid> <state> <elapsed>
    local jid="$1" st="$2" el="${3:-01:00:00}" nodes
    nodes="$(awk -v j="$jid" '$1==j{print $4; exit}' "$MOCK_DIR/jobs.state")"
    grep -v "^$jid " "$MOCK_DIR/jobs.state" >"$MOCK_DIR/jobs.state.n" 2>/dev/null || : >"$MOCK_DIR/jobs.state.n"
    mv "$MOCK_DIR/jobs.state.n" "$MOCK_DIR/jobs.state"
    printf '%s %s %s %s\n' "$jid" "$st" "$el" "${nodes:-unknown}" >>"$MOCK_DIR/jobs.state"
}
last_jobid() { tail -1 "$MOCK_DIR/jobs.state" | awk '{print $1}'; }
state_of()   { grep -m1 '^status=' "$1" 2>/dev/null | cut -d= -f2; }
mk_nccl()    { bash "$FIX/mk_nccl_logs.sh" "$AAT_HOME_OVERRIDE/llmb" "$1" "$2" "${3:-13}" >/dev/null; }

run_test() {
    local name="$1"
    [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && { SKIP=$((SKIP + 1)); return 0; }
    CURRENT="$name"
    local before=$FAIL
    "$name" || true
    [[ "$FAIL" == "$before" ]] && _ok
    teardown
}

# =========================================================================== #
# unit tests
# =========================================================================== #
test_unit_nodeset_fold_noncontiguous() {
    local out
    out="$(libsh 'ns_fold rack01-11 rack01-12 rack01-13 rack01-14 rack01-15 rack01-16 rack01-17 rack01-18 rack01-28 rack01-29 rack01-30 rack01-31 rack01-32 rack01-33 rack01-34 rack01-35 rack01-36 rack01-37')"
    assert_eq 'rack01-[11-18,28-37]' "$out" "18-tray rack must fold to two ranges"
}

test_unit_nodeset_expand_roundtrip() {
    local n out
    n="$(libsh 'ns_count "rack01-[11-18,28-37]"')"
    assert_eq 18 "$n" "expand of a folded rack must give 18 trays"
    out="$(libsh 'ns_fold "$(ns_expand "rack01-[11-18,28-37]")"')"
    assert_eq 'rack01-[11-18,28-37]' "$out" "fold(expand(x)) == x"
    out="$(libsh 'ns_expand "a-01,b-[02-03] c-04" | tr "\n" " "')"
    assert_eq 'a-01 b-02 b-03 c-04 ' "$out" "mixed comma/space/bracket input"
}

test_unit_nodeset_subtract() {
    local out
    out="$(libsh 'ns_subtract "r-[01-06]" "r-[03-04]"')"
    assert_eq 'r-[01-02,05-06]' "$out"
    out="$(libsh 'ns_subtract "r-[01-03]" "r-[01-03]"')"
    assert_eq '' "$out" "subtracting everything yields empty"
}

test_unit_jobid_parsing_all_styles() {
    local out
    out="$(libsh 'llmb_parse_jobid "JobID: 48727, Workdir: /x/y"')";        assert_eq 48727 "$out" "JobID: style"
    out="$(libsh 'llmb_parse_jobid "LAUNCHED: w dtype=fp8 jobid=36512"')";  assert_eq 36512 "$out" "jobid= style"
    out="$(libsh 'llmb_parse_jobid "- Job id: 12345"')";                    assert_eq 12345 "$out" "Job id: style"
    out="$(libsh 'llmb_parse_jobid "Submitted batch job 777888"')";         assert_eq 777888 "$out" "sbatch style"
    out="$(libsh 'llmb_parse_jobid "no id here at all"')";                  assert_eq '' "$out" "must not invent an id"
}

test_unit_nccl_busbw_both_layouts() {
    setup 1
    mk_nccl 40100 915.3 13
    mk_nccl 40101 688.4 11
    local out
    out="$(libsh 'export LLMB_INSTALL="'"$AAT_HOME_OVERRIDE"'/llmb"; llmb_nccl_peaks "$(llmb_nccl_logdir 40100)" | tr "\n" " "')"
    assert_contains "$out" 'all_reduce=915.3' "13-column layout"
    out="$(libsh 'export LLMB_INSTALL="'"$AAT_HOME_OVERRIDE"'/llmb"; llmb_nccl_peaks "$(llmb_nccl_logdir 40101)" | tr "\n" " "')"
    assert_contains "$out" 'all_reduce=688.4' "11-column layout (no redop/root)"
}

test_unit_elapsed_parsing() {
    local out
    out="$(libsh 'sl_parse_elapsed_hours "05:30"')";       assert_eq 0 "$out" "MM:SS"
    out="$(libsh 'sl_parse_elapsed_hours "07:15:00"')";    assert_eq 7 "$out" "HH:MM:SS"
    out="$(libsh 'sl_parse_elapsed_hours "1-03:00:00"')";  assert_eq 27 "$out" "D-HH:MM:SS"
    out="$(libsh 'sl_parse_elapsed_hours "2-05:30"')";     assert_eq 53 "$out" "D-HH:MM"
    out="$(libsh 'sl_parse_elapsed_hours ""')";            assert_eq 0 "$out" "empty"
    out="$(libsh 'sl_parse_elapsed_hours "09:00:00"')";    assert_eq 9 "$out" "leading zero must not be octal"
    out="$(libsh 'sl_parse_elapsed_hours "08:00:00"')";    assert_eq 8 "$out" "08 is not octal"
}

test_unit_scoring_and_thresholds() {
    local out
    out="$(libsh 'thr_get "all_reduce:820,alltoall:620" alltoall')"; assert_eq 620 "$out"
    out="$(libsh 'score_nccl "all_reduce:820" all_reduce=915.3 alltoall=690')"
    assert_eq '' "$out" "above floor must pass"
    out="$(libsh 'score_nccl "all_reduce:820" all_reduce=684 alltoall=445')"
    assert_contains "$out" 'all_reduce=684<820' "below floor must fail"
    out="$(libsh 'score_nccl "all_reduce:820" all_reduce=0 alltoall=0')"
    assert_contains "$out" 'no busbw parsed' "all-zero means unparsed, not pass"
    out="$(libsh 'score_tflops "-" ""')"
    assert_contains "$out" 'no TFLOPS' "missing metric must not silently pass"
}

test_unit_workload_dsl_rejects_typos() {
    setup 1
    printf 'workload bad runner=llmb llmb_workload=x sclae=auto\n' >"$TEST_WORKLOADS"
    local out; out="$(orch --dry-run)"
    assert_contains "$out" "unknown key 'sclae'" "a typo in workloads.conf must be fatal"
    printf 'workload a runner=llmb llmb_workload=x gate=b\nworkload b runner=llmb llmb_workload=y\n' >"$TEST_WORKLOADS"
    out="$(orch --dry-run)"
    assert_contains "$out" "gate 'b' is declared after it" "forward gate references must be fatal"
}

test_unit_inventory_mapping() {
    setup 3
    local out
    out="$(libsh 'aat_init; rack_load_inventory; node_rack rack02-29')"
    assert_eq 'rack02' "$out" "node -> rack"
    out="$(libsh 'aat_init; rack_load_inventory; rack_nodelist rack03')"
    assert_eq 'rack03-[11-18,28-37]' "$out" "rack -> folded nodelist"
    out="$(libsh 'aat_init; rack_load_inventory; rack_list | wc -l')"
    assert_eq 3 "$out"
    # a duplicated node across racks must be fatal, not first-wins
    printf 'rackA L a-01 a-02\nrackB L a-02 a-03\n' >"$TEST_INVENTORY"
    out="$(libsh 'aat_init; rack_load_inventory' || true)"
    assert_contains "$out" 'in two racks' "overlapping racks must be rejected"
}

# =========================================================================== #
# integration tests
# =========================================================================== #
test_dryrun_writes_no_state() {
    setup 2
    pass_node_wl rack01 dcgm
    local out; out="$(orch --dry-run)"
    assert_contains "$out" 'DRY-RUN' 'dry run must print the command'
    assert_contains "$out" 'llmb-run submit -w microbenchmark_nccl' 'command shape'
    assert_contains "$out" '--nodelist rack01-[11-18,28-37]' 'single rack pins by nodelist'
    assert_no_file "$AAT_HOME_OVERRIDE/state/racks/rack01/nccl_single.state" \
        'dry run must not create state'
    assert_eq 0 "$(count_lines "$MOCK_DIR/jobs.state")" 'dry run must queue nothing'
}

test_submit_respects_node_gate() {
    setup 2
    pass_node_wl rack01 dcgm      # only rack 1 has passed dcgm
    orch >/dev/null
    assert_eq SUBMITTED "$(state_of "$AAT_HOME_OVERRIDE/state/racks/rack01/nccl_single.state")" \
        'gated rack should submit'
    assert_no_file "$AAT_HOME_OVERRIDE/state/racks/rack02/nccl_single.state" \
        'rack without dcgm must not submit'
    assert_grep "$MOCK_DIR/llmb.args.log" -- '--force' 'non-whitelisted scale needs --force'
    assert_grep "$MOCK_DIR/llmb.args.log" -- '--scale 72' 'one NVL72 rack = 72 GPUs'
    assert_grep "$MOCK_DIR/llmb.env.log" 'RUN_CONF_IMAGE=/raid/llmb/nvidia+nemo+26.04.01.sqsh' \
        'image must come from the local staging dir'
    assert_grep "$MOCK_DIR/llmb.env.log" 'NCCL_SOCKET_IFNAME=eth0' \
        'site fabric interface must be passed'
}

test_submit_is_idempotent() {
    setup 2
    pass_node_wl rack01 dcgm
    orch >/dev/null
    local first; first="$(count_lines "$MOCK_DIR/llmb.args.log")"
    orch >/dev/null
    local second; second="$(count_lines "$MOCK_DIR/llmb.args.log")"
    assert_eq "$first" "$second" 'a second pass must not resubmit an in-flight rack'
}

test_lock_prevents_double_submit() {
    setup 2
    pass_node_wl rack01 dcgm
    mkdir -p "$AAT_HOME_OVERRIDE/state/locks"
    ( flock 9; sleep 5 ) 9>"$AAT_HOME_OVERRIDE/state/locks/orchestrator.lock" &
    local holder=$!
    sleep 0.3
    local out rc
    out="$(TEST_LOG_LEVEL=INFO orch)"; rc=$?
    kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
    assert_rc 0 "$rc" 'a locked-out pass must exit 0, not error'
    assert_contains "$out" 'holds the lock' 'and say so'
    assert_no_file "$MOCK_DIR/llmb.args.log" 'and submit nothing'
}

test_collect_success_opens_next_gate() {
    setup 2
    pass_node_wl rack01 dcgm
    orch >/dev/null
    local jid; jid="$(last_jobid)"
    mk_nccl "$jid" 915.3
    set_job "$jid" COMPLETED 00:40:00
    orch >/dev/null
    local sf="$AAT_HOME_OVERRIDE/state/racks/rack01/nccl_single.state"
    assert_eq DONE "$(state_of "$sf")" 'completed job with good busbw is DONE'
    assert_grep "$sf" 'm_all_reduce=915.3' 'metrics land on the state file'
    local rf="$AAT_HOME_OVERRIDE/results/rack01-28/nccl_single.txt"
    assert_file "$rf" 'result fanned out to every tray'
    assert_eq DONE "$(tail -1 "$rf")" 'last line stays the DONE/FAIL contract'
    assert_grep "$rf" 'all_gather=' 'per-collective numbers in the result file'
    # nemo_single is gated on nccl_single and should now be in flight
    assert_eq SUBMITTED "$(state_of "$AAT_HOME_OVERRIDE/state/racks/rack01/nemo_single.state")" \
        'passing NCCL must open the pretrain gate'
    assert_grep "$MOCK_DIR/llmb.env.log" 'MAX_STEPS=2010' 'pretrain env from the workload table'
}

test_collect_low_busbw_fails_and_drains() {
    setup 2
    pass_node_wl rack01 dcgm
    orch >/dev/null
    local jid; jid="$(last_jobid)"
    mk_nccl "$jid" 449.0          # the marginal-rack signature from the reference fleet
    set_job "$jid" COMPLETED 00:40:00
    orch >/dev/null
    local sf="$AAT_HOME_OVERRIDE/state/racks/rack01/nccl_single.state"
    assert_eq FAIL "$(state_of "$sf")"
    assert_grep "$sf" 'all_reduce=449.0<820'
    assert_file "$MOCK_DIR/scontrol.log" 'a failing rack must be drained'
    assert_grep "$MOCK_DIR/scontrol.log" 'state=DRAIN'
    assert_grep "$MOCK_DIR/scontrol.log" 'nodename=rack01-\[11-18,28-37\]' \
        'drain must name the whole rack in one call'
    assert_eq FAIL "$(tail -1 "$AAT_HOME_OVERRIDE/results/rack01-37/nccl_single.txt")"
    assert_no_file "$AAT_HOME_OVERRIDE/state/racks/rack01/nemo_single.state" \
        'a failed rack must not progress to the next workload'
}

test_collect_completed_but_no_results_is_a_failure() {
    setup 1
    pass_node_wl rack01 dcgm
    orch >/dev/null
    set_job "$(last_jobid)" COMPLETED 00:40:00     # no log tree created
    orch >/dev/null
    local sf="$AAT_HOME_OVERRIDE/state/racks/rack01/nccl_single.state"
    assert_eq FAIL "$(state_of "$sf")" 'COMPLETED with no parsable results is not a pass'
    assert_grep "$sf" 'no NCCL result dir'
}

test_collect_slurm_failure_is_terminal() {
    setup 1
    pass_node_wl rack01 dcgm
    orch >/dev/null
    set_job "$(last_jobid)" FAILED 00:03:00
    orch >/dev/null
    assert_eq FAIL "$(state_of "$AAT_HOME_OVERRIDE/state/racks/rack01/nccl_single.state")"
    assert_grep "$MOCK_DIR/scontrol.log" 'state=DRAIN'
}

test_collect_node_fail_is_retried() {
    setup 1
    pass_node_wl rack01 dcgm
    TEST_LOG_LEVEL=WARN orch >/dev/null
    local sf="$AAT_HOME_OVERRIDE/state/racks/rack01/nccl_single.state"
    set_job "$(last_jobid)" NODE_FAIL 00:01:00
    orch --collect-only >/dev/null
    assert_eq NOT_RUN "$(state_of "$sf")" 'infra failure resets for retry rather than failing the rack'
    assert_grep "$sf" 'attempts=1'
    assert_no_file "$MOCK_DIR/scontrol.log" 'an infra failure must not drain the rack'
    orch --submit-only >/dev/null
    assert_eq SUBMITTED "$(state_of "$sf")" 'and the retry actually goes out'
    assert_grep "$sf" 'attempts=2'
}

test_collect_timeout_cancels() {
    setup 1
    pass_node_wl rack01 dcgm
    orch >/dev/null
    local jid; jid="$(last_jobid)"
    set_job "$jid" RUNNING 1-07:00:00      # 31h > MAX_RACK_JOB_HOURS=30
    orch --collect-only >/dev/null
    assert_file "$MOCK_DIR/scancel.log" 'an over-running rack job must be cancelled'
    local sf="$AAT_HOME_OVERRIDE/state/racks/rack01/nccl_single.state"
    assert_eq FAIL "$(state_of "$sf")"
    assert_grep "$sf" 'timeout after 31h'
}

test_unready_rack_is_not_submitted() {
    setup 2
    pass_node_wl rack01 dcgm
    printf 'rack01-15 drained\n' >>"$MOCK_DIR/nodes.state"
    local out; out="$(TEST_LOG_LEVEL=INFO orch)"
    assert_no_file "$AAT_HOME_OVERRIDE/state/racks/rack01/nccl_single.state" \
        'one bad tray must block the whole rack'
    assert_contains "$out" 'unhealthy trays: rack01-15:drained' 'and say which tray'
}

test_group_uses_exclude_not_nodelist() {
    setup 4
    local r
    for r in $(racks_in_inv); do pass_node_wl "$r" dcgm; done
    # pass nccl_single on all four racks
    orch >/dev/null
    local sf jid
    for r in $(racks_in_inv); do
        sf="$AAT_HOME_OVERRIDE/state/racks/$r/nccl_single.state"
        jid="$(grep -m1 '^jobid=' "$sf" | cut -d= -f2)"
        mk_nccl "$jid" 915.3
        set_job "$jid" COMPLETED 00:40:00
    done
    orch >/dev/null                       # collect the four, submit nemo + group
    local gsf="$AAT_HOME_OVERRIDE/state/groups/g4_rack01/nccl_multi.state"
    assert_file "$gsf" 'multi-rack group job must be created once all members pass'
    assert_eq SUBMITTED "$(state_of "$gsf")"
    local line
    line="$(grep -- '--scale 288' "$MOCK_DIR/llmb.args.log" | tail -1)"
    assert_ne '' "$line" '4 racks x 72 GPUs = scale 288'
    assert_contains "$line" '--exclude' 'multi-rack must pin with --exclude under topology/block'
    assert_lacks "$line" '--nodelist' 'multi-rack must NOT use --nodelist under topology/block'
    assert_contains "$line" 'other01' 'the exclude set must name the nodes outside the group'
}

test_group_blocked_until_all_members_pass() {
    setup 4
    local r
    for r in $(racks_in_inv); do pass_node_wl "$r" dcgm; done
    orch >/dev/null
    local sf jid n=0
    for r in $(racks_in_inv); do
        n=$((n + 1)); [[ $n -gt 3 ]] && break        # only 3 of 4 racks pass
        sf="$AAT_HOME_OVERRIDE/state/racks/$r/nccl_single.state"
        jid="$(grep -m1 '^jobid=' "$sf" | cut -d= -f2)"
        mk_nccl "$jid" 915.3; set_job "$jid" COMPLETED 00:40:00
    done
    orch >/dev/null
    assert_no_file "$AAT_HOME_OVERRIDE/state/groups/g4_rack01/nccl_multi.state" \
        '3 of 4 racks is not a 4-rack test'
    local out; out="$(rstat --pending)"
    assert_contains "$out" 'nccl_multi' 'pending view must show the blocked group work'
}

test_old_llmb_refuses_unpinned_submit() {
    setup 1
    pass_node_wl rack01 dcgm
    export MOCK_LLMB_MODE=single
    local out; out="$(orch)"
    assert_contains "$out" 'cannot be pinned' 'a release without submit must refuse, not guess'
    assert_no_file "$MOCK_DIR/llmb.args.log" 'nothing may be queued'
    AAT_ALLOW_UNPINNED=1 orch >/dev/null
    assert_grep "$MOCK_DIR/llmb.args.log" 'single -w microbenchmark_nccl' \
        'the explicit override falls back to the single subcommand'
    assert_lacks "$(cat "$MOCK_DIR/llmb.args.log")" '--force' \
        'flags the old release does not know must be dropped'
}

test_submit_failure_does_not_lose_state() {
    setup 1
    pass_node_wl rack01 dcgm
    export MOCK_LLMB_FAIL=1
    orch >/dev/null
    local sf="$AAT_HOME_OVERRIDE/state/racks/rack01/nccl_single.state"
    assert_eq NOT_RUN "$(state_of "$sf")" 'a failed submit stays retryable'
    assert_grep "$sf" 'attempts=1'
    unset MOCK_LLMB_FAIL
    orch >/dev/null
    assert_eq SUBMITTED "$(state_of "$sf")" 'and succeeds once llmb-run works again'
}

test_unparsable_jobid_is_an_error() {
    setup 1
    pass_node_wl rack01 dcgm
    export MOCK_LLMB_NOJOBID=1
    local out; out="$(orch)"
    assert_contains "$out" 'no job id could be parsed'
    assert_eq NOT_RUN "$(state_of "$AAT_HOME_OVERRIDE/state/racks/rack01/nccl_single.state")" \
        'an unattributable submission must not be recorded as in flight'
}

test_tflops_without_jobs_subcommand() {
    setup 1
    pass_node_wl rack01 dcgm
    orch >/dev/null                                  # nccl_single
    local jid; jid="$(last_jobid)"
    mk_nccl "$jid" 915.3; set_job "$jid" COMPLETED 00:40:00
    orch >/dev/null                                  # -> nemo_single submitted
    local sf="$AAT_HOME_OVERRIDE/state/racks/rack01/nemo_single.state"
    jid="$(grep -m1 '^jobid=' "$sf" | cut -d= -f2)"
    export MOCK_LLMB_HAS_JOBS=0                      # 25.10-style install
    set_job "$jid" COMPLETED 02:55:00
    orch --collect-only >/dev/null
    assert_eq FAIL "$(state_of "$sf")" \
        'no TFLOPS source means the run is unverified, which is not a pass'
    assert_grep "$sf" 'no TFLOPS/GPU reported'
}

test_tflops_pass_with_jobs_subcommand() {
    setup 1
    pass_node_wl rack01 dcgm
    orch >/dev/null
    local jid; jid="$(last_jobid)"
    mk_nccl "$jid" 915.3; set_job "$jid" COMPLETED 00:40:00
    orch >/dev/null
    local sf="$AAT_HOME_OVERRIDE/state/racks/rack01/nemo_single.state"
    jid="$(grep -m1 '^jobid=' "$sf" | cut -d= -f2)"
    export MOCK_LLMB_TFLOPS=705.4
    set_job "$jid" COMPLETED 02:55:00
    orch --collect-only >/dev/null
    assert_eq DONE "$(state_of "$sf")"
    assert_grep "$sf" 'm_tflops=705.4'
}

test_queue_depth_limit_stops_submission() {
    setup 4
    local r
    for r in $(racks_in_inv); do pass_node_wl "$r" dcgm; done
    printf '90001 RUNNING 00:10:00 x\n90002 PENDING 00:00:00 x\n' >>"$MOCK_DIR/jobs.state"
    export TEST_QUEUE_LIMIT=2
    local out; out="$(TEST_LOG_LEVEL=INFO orch)"
    assert_contains "$out" 'not submitting this pass'
    assert_no_file "$MOCK_DIR/llmb.args.log"
}

test_submit_budget_per_pass() {
    setup 4
    local r
    for r in $(racks_in_inv); do pass_node_wl "$r" dcgm; done
    export TEST_MAX_SUBMITS=2
    orch >/dev/null
    assert_eq 2 "$(count_lines "$MOCK_DIR/llmb.args.log")" 'at most MAX_SUBMITS_PER_CYCLE per pass'
}

test_status_and_report_outputs() {
    setup 2
    pass_node_wl rack01 dcgm
    orch >/dev/null
    local jid; jid="$(last_jobid)"
    mk_nccl "$jid" 915.3; set_job "$jid" COMPLETED 00:40:00
    orch --collect-only >/dev/null

    local out
    out="$(bash "$ROOT/bin/status-check.sh" 2>&1)"
    assert_contains "$out" 'nccl_single: DONE' 'status-check keeps the node: column: STATUS shape'

    out="$(bash "$ROOT/bin/status-daily-report.sh" "$AAT_HOME_OVERRIDE/r.csv" 2>&1)"
    assert_contains "$out" 'Report written'
    assert_grep "$AAT_HOME_OVERRIDE/r.csv" 'nccl_single.all_reduce' 'CSV gains a column per collective'
    assert_grep "$AAT_HOME_OVERRIDE/r.csv" '915.3' 'and carries the numbers'
    local ncols
    ncols="$(head -1 "$AAT_HOME_OVERRIDE/r.csv" | awk -F, '{print NF}')"
    local nrow
    nrow="$(sed -n '2p' "$AAT_HOME_OVERRIDE/r.csv" | awk -F, '{print NF}')"
    assert_eq "$ncols" "$nrow" 'header and rows must have equal width'

    out="$(rstat)"
    assert_contains "$out" 'rack01' 'rack matrix lists racks'
    assert_contains "$out" 'DONE' 'and their verdicts'
}

test_node_action_submits_only_node_scope() {
    setup 1
    export HOSTNAME=rack01-11
    local out
    out="$(AAT_ROOT="$ROOT" bash "$ROOT/actions/launch_job.sh" 2>&1)"
    assert_grep "$MOCK_DIR/calls.log" 'sbatch' 'the node action still submits the dcgm sbatch'
    assert_lacks "$(cat "$MOCK_DIR/calls.log")" 'llmb-run' \
        'the node action must never submit rack-scale llmb work'
    [[ -d "$AAT_HOME_OVERRIDE/results/rack01-11" ]] || \
        _fail 'the node action should create the result dir for its own node'
}


test_verify_passes_on_a_healthy_cluster() {
    setup 4
    export MOCK_TOPOLOGY=topology/block
    mkdir -p "$AAT_HOME_OVERRIDE/llmb/workloads/microbenchmark_nccl" \
             "$AAT_HOME_OVERRIDE/llmb/workloads/pretrain_nemotron-h" \
             "$AAT_HOME_OVERRIDE/llmb/images"
    touch "$AAT_HOME_OVERRIDE/llmb/images/nvidia+nemo+26.04.01.sqsh"
    printf 'gpu:4\n' >"$MOCK_DIR/gres"
    awk '!/^#/{for(i=3;i<=NF;i++) print $i}' "$TEST_INVENTORY" >"$MOCK_DIR/all.nodes"
    printf 'microbenchmark_nccl\npretrain_nemotron-h\n' >"$MOCK_DIR/llmb_workloads"
    local out rc
    out="$(bash "$ROOT/bin/verify-cluster.sh" 2>&1)"; rc=$?
    assert_contains "$out" 'every inventory tray exists in slurm' 'naming-domain check must run'
    assert_contains "$out" 'topology plugin' 'topology must be checked'
    assert_lacks "$out" 'FAIL  slurm node list' 'sinfo -N must be readable'
    assert_lacks "$out" 'FAIL  every rack has' 'rack sizes are correct in the fixture'
}

test_verify_catches_naming_domain_mismatch() {
    setup 4
    export MOCK_TOPOLOGY=topology/block
    mkdir -p "$AAT_HOME_OVERRIDE/llmb/workloads" "$AAT_HOME_OVERRIDE/llmb/images"
    touch "$AAT_HOME_OVERRIDE/llmb/images/nvidia+nemo+26.04.01.sqsh"
    # Slurm reports a completely different naming domain than the inventory
    for i in $(seq 1 72); do printf 'othernaming-gpu%04d\n' "$i"; done >"$MOCK_DIR/all.nodes"
    tr '\n' ',' <"$MOCK_DIR/all.nodes" | sed 's/,$//' >"$MOCK_DIR/partition.nodes"
    local out rc
    out="$(bash "$ROOT/bin/verify-cluster.sh" 2>&1)"; rc=$?
    assert_rc 1 "$rc" 'a total naming mismatch must be a hard failure'
    assert_contains "$out" 'NONE of the' 'must say that no inventory name exists in Slurm'
    assert_contains "$out" 'othernaming-gpu' 'must show the actual Slurm names for comparison'
    assert_contains "$out" 'DO NOT deploy' 'verdict must block deployment'
}

test_verify_flags_topology_mismatch() {
    setup 2
    export MOCK_TOPOLOGY=topology/tree
    awk '!/^#/{for(i=3;i<=NF;i++) print $i}' "$TEST_INVENTORY" >"$MOCK_DIR/all.nodes"
    local out; out="$(bash "$ROOT/bin/verify-cluster.sh" 2>&1)"
    assert_contains "$out" 'topology/tree' 'must report the plugin the cluster actually uses'
}


test_interview_generates_a_working_config() {
    setup 4
    # a scratch copy of the repo, so the interview cannot touch the real conf/
    local W="$TC/repo"
    mkdir -p "$W"; cp -r "$ROOT"/{bin,lib,conf,actions,jobs,tests,docs} "$W"/ 2>/dev/null
    rm -f "$W/conf/cluster.conf" "$W/conf/inventory/racks.txt"
    awk '!/^#/{for(i=3;i<=NF;i++) print $i}' "$TEST_INVENTORY" >"$MOCK_DIR/all.nodes"
    printf 'gpu:4\n' >"$MOCK_DIR/gres"
    export MOCK_TOPOLOGY=topology/block
    local out
    out="$(cd "$W" && bash bin/interview.sh --non-interactive 2>&1)"
    assert_contains "$out" 'rack grouping rule' 'the interview must offer grouping rules'
    assert_contains "$out" 'uniform' 'and score them for uniformity'
    assert_file "$W/conf/cluster.conf"            'writes the site config'
    assert_file "$W/conf/inventory/racks.txt"     'writes the inventory'
    assert_file "$W/conf/interview-answers.conf"  'writes a replayable answers file'
    assert_grep "$W/conf/cluster.conf" 'GPUS_PER_NODE=4'   'detects GPUs per node from gres'
    assert_grep "$W/conf/cluster.conf" 'NODES_PER_RACK=18' 'detects nodes per rack from the layout'
    assert_grep "$W/conf/cluster.conf" 'SLURM_TOPOLOGY=block' 'detects the topology plugin'
    assert_eq 4 "$(grep -vc '^#' "$W/conf/inventory/racks.txt")" 'one line per rack'
    # the generated config must actually drive the orchestrator
    out="$(cd "$W" && ALLOW_ROOT=1 AAT_CONF="$W/conf/cluster.conf" \
           bash bin/rack-orchestrator.sh --dry-run 2>&1)"
    assert_lacks "$out" 'no site configuration' 'the generated config is found'
    assert_lacks "$out" 'unknown key'           'the generated config parses'
}

test_interview_replays_from_answers() {
    setup 2
    local W="$TC/repo"
    mkdir -p "$W"; cp -r "$ROOT"/{bin,lib,conf,actions,jobs,tests,docs} "$W"/ 2>/dev/null
    rm -f "$W/conf/cluster.conf" "$W/conf/inventory/racks.txt"
    cat >"$W/conf/answers.conf" <<'ANS'
CLUSTER_NAME=replayed
PLATFORM_PROFILE=gb300-nvl72
PARTITION=somepartition
GPUS_PER_NODE=8
NODES_PER_RACK=4
SLURM_TOPOLOGY=none
LLMB_INSTALL=/shared/llmb
LLMB_SUBCOMMAND=submit
LLMB_IMAGE_NAME=img.sqsh
NCCL_SOCKET_IFNAME=eth9
NODE_HEALTH_DRIVER=cron
ANS
    local out
    out="$(cd "$W" && bash bin/interview.sh --answers conf/answers.conf --force 2>&1)"
    assert_contains "$out" 'from answers file' 'answers must be honoured verbatim'
    assert_grep "$W/conf/cluster.conf" 'CLUSTER_NAME="replayed"'
    assert_grep "$W/conf/cluster.conf" 'GPUS_PER_NODE=8'    'no re-detection when replaying'
    assert_grep "$W/conf/cluster.conf" 'SLURM_TOPOLOGY=none'
    assert_grep "$W/conf/cluster.conf" 'NCCL_SOCKET_IFNAME=eth9'
    assert_grep "$W/conf/cluster.conf" 'gb300-nvl72'        'profile is wired into the config'
}

test_uncalibrated_profile_passes_on_completion() {
    setup 1
    export TEST_PROFILE=generic          # every NCCL floor empty
    pass_node_wl rack01 dcgm
    orch >/dev/null
    local jid; jid="$(last_jobid)"
    mk_nccl "$jid" 12.5                  # absurdly low, but there is no floor
    set_job "$jid" COMPLETED 00:40:00
    orch --collect-only >/dev/null
    assert_eq DONE "$(state_of "$AAT_HOME_OVERRIDE/state/racks/rack01/nccl_single.state")" \
        'with no floors configured, a completed sweep passes and only the outlier gate applies'
}

# =========================================================================== #
main() {
    printf '\n%s== llmb-bringup validation suite ==%s\n' "$c_yel" "$c_off"
    printf '%srepo: %s%s\n\n' "$c_dim" "$ROOT" "$c_off"
    local t
    for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}' | sort); do
        run_test "$t"
    done
    printf '\n%s%d passed%s, %s%d failed%s, %d filtered out\n' \
        "$c_grn" "$PASS" "$c_off" "$c_red" "$FAIL" "$c_off" "$SKIP"
    if (( FAIL )); then
        printf '\nfailed tests:\n'
        printf '  %s\n' "${FAILED[@]}"
        exit 1
    fi
    exit 0
}
main
