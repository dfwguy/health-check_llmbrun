#!/bin/bash
# lib/common.sh - config loading, workload DSL, state files, locking, logging.
# Sourced, never executed. Requires bash 4+ (associative arrays).

[[ -n "${_AAT_COMMON_SH:-}" ]] && return 0
_AAT_COMMON_SH=1

# --------------------------------------------------------------------------- #
# logging
# --------------------------------------------------------------------------- #
declare -A _LOG_RANK=([DEBUG]=10 [INFO]=20 [WARN]=30 [ERROR]=40)

log() {
    local level="$1"; shift
    local want="${LOG_LEVEL:-INFO}"
    local lr="${_LOG_RANK[$level]:-20}" wr="${_LOG_RANK[$want]:-20}"
    (( lr < wr )) && return 0
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') [$level] ${_AAT_TAG:-aat}: $*"
    printf '%s\n' "$line" >&2
    [[ -n "${LOG_DIR:-}" && -d "${LOG_DIR:-}" ]] && printf '%s\n' "$line" >>"$LOG_DIR/aat.log"
    return 0
}
debug() { log DEBUG "$@"; }
info()  { log INFO  "$@"; }
warn()  { log WARN  "$@"; }
error() { log ERROR "$@"; }
die()   { log ERROR "$@"; exit 1; }

# --------------------------------------------------------------------------- #
# workload DSL
#
#   workload <name> key=value ...
#
# Values may contain spaces if the caller quotes them (env="A=1 B=2").
# Unknown keys are a hard error: a typo in workloads.conf must not silently
# turn into a default, because the cost lands on the cluster floor.
# --------------------------------------------------------------------------- #
declare -a WL_ORDER=()
declare -A WL=()            # WL[name/key] = value

# One line on purpose: the membership test below is `case " $_WL_KEYS " in
# *" $key "*)`, so a newline inside this string makes the key that precedes it
# unmatchable.
_WL_KEYS="runner scope gate llmb_workload llmb_size dtype racks_per_job scale scale_flag pin metric thresholds runs env sbatch enabled time_limit"

workload() {
    local name="$1"; shift
    [[ "$name" =~ ^[a-z0-9_]+$ ]] || die "workload name '$name' must be [a-z0-9_]+"
    for k in $_WL_KEYS; do WL["$name/$k"]=""; done
    # defaults
    WL["$name/runner"]=llmb
    WL["$name/scope"]=rack
    WL["$name/gate"]="-"
    WL["$name/racks_per_job"]=1
    WL["$name/scale"]=auto
    WL["$name/scale_flag"]="-"
    WL["$name/pin"]=auto
    WL["$name/metric"]="-"
    WL["$name/thresholds"]="-"
    WL["$name/runs"]=1
    WL["$name/enabled"]=1
    WL["$name/llmb_size"]="-"
    WL["$name/dtype"]="-"

    local kv key val
    for kv in "$@"; do
        [[ "$kv" == *=* ]] || die "workload $name: '$kv' is not key=value"
        key="${kv%%=*}"; val="${kv#*=}"
        case " $_WL_KEYS " in
            *" $key "*) WL["$name/$key"]="$val" ;;
            *) die "workload $name: unknown key '$key' (valid: $(echo $_WL_KEYS))" ;;
        esac
    done

    case "${WL[$name/runner]}" in llmb|sbatch|local) ;; *) die "workload $name: bad runner '${WL[$name/runner]}'";; esac
    case "${WL[$name/scope]}"  in node|rack|group)  ;; *) die "workload $name: bad scope '${WL[$name/scope]}'";;  esac
    case "${WL[$name/pin]}"    in auto|nodelist|exclude|none) ;; *) die "workload $name: bad pin '${WL[$name/pin]}'";; esac
    case "${WL[$name/scale_flag]}" in force|proxy|-) ;; *) die "workload $name: bad scale_flag";; esac
    [[ "${WL[$name/runner]}" == llmb && -z "${WL[$name/llmb_workload]}" ]] &&
        die "workload $name: runner=llmb needs llmb_workload="
    [[ "${WL[$name/runner]}" == sbatch && -z "${WL[$name/sbatch]}" ]] &&
        die "workload $name: runner=sbatch needs sbatch="
    [[ "${WL[$name/scope]}" == group && "${WL[$name/racks_per_job]}" -lt 2 ]] &&
        die "workload $name: scope=group needs racks_per_job>=2"

    WL_ORDER+=("$name")
    debug "registered workload $name (runner=${WL[$name/runner]} scope=${WL[$name/scope]})"
}

wl()          { printf '%s' "${WL[$1/$2]:-}"; }
wl_exists()   { [[ -n "${WL[$1/runner]:-}" ]]; }
wl_enabled()  { [[ "$(wl "$1" enabled)" != 0 ]]; }
wl_gates()    { local g; g="$(wl "$1" gate)"; [[ "$g" == "-" ]] && return 0; printf '%s' "${g//,/ }"; }

# Ordered list of enabled workloads, optionally filtered by scope.
wl_list() {
    local scope="${1:-}" n
    for n in "${WL_ORDER[@]}"; do
        wl_enabled "$n" || continue
        [[ -n "$scope" && "$(wl "$n" scope)" != "$scope" ]] && continue
        printf '%s\n' "$n"
    done
}

# Column labels used by status/report tooling: "wl" or "wl-runN".
wl_columns() {
    local n runs r
    for n in $(wl_list); do
        runs="$(wl "$n" runs)"
        if [[ "$runs" -le 1 ]]; then printf '%s\n' "$n"
        else for ((r=1; r<=runs; r++)); do printf '%s-run%s\n' "$n" "$r"; done
        fi
    done
}

# --------------------------------------------------------------------------- #
# init
# --------------------------------------------------------------------------- #
aat_init() {
    _AAT_TAG="${_AAT_TAG:-${0##*/}}"

    # Repo root: parent of the dir holding this library.
    local libdir
    libdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    AAT_ROOT="$(dirname "$libdir")"

    local conf="${AAT_CONF:-$AAT_ROOT/conf/cluster.conf}"
    if [[ ! -r "$conf" ]]; then
        die "no site configuration at $conf

This suite is cluster-agnostic; the site facts live in conf/cluster.conf, which
is generated. Run the interview once per cluster:

    bin/interview.sh                 # detect what it can, ask about the rest
    bin/interview.sh --offline       # no cluster access yet
    bin/interview.sh --answers <f>   # replay a previous interview

conf/cluster.conf.example lists every setting if you would rather write it by hand."
    fi
    # shellcheck disable=SC1090
    source "$conf"

    # Test/dev override: relocate the whole writable tree in one shot.
    if [[ -n "${AAT_HOME_OVERRIDE:-}" ]]; then
        AAT_HOME="$AAT_HOME_OVERRIDE"
        RESULTS_DIR="$AAT_HOME/results"; STATE_DIR="$AAT_HOME/state"
        LOG_DIR="$AAT_HOME/log";         REPORT_DIR="$AAT_HOME/reports"
        LOGS_DIR="$AAT_HOME/logs";       VALID_CONFIG_DIR="$AAT_HOME/valid-config"
    fi
    : "${RACK_INVENTORY:=$AAT_ROOT/conf/inventory/racks.txt}"
    : "${WORKLOAD_CONF:=$AAT_ROOT/conf/workloads.conf}"
    [[ -r "$RACK_INVENTORY" ]] || RACK_INVENTORY="$AAT_ROOT/conf/inventory/racks.txt"
    [[ -r "$WORKLOAD_CONF"  ]] || WORKLOAD_CONF="$AAT_ROOT/conf/workloads.conf"

    _aat_validate_conf

    mkdir -p "$RESULTS_DIR" "$STATE_DIR/racks" "$STATE_DIR/groups" "$STATE_DIR/locks" \
             "$LOG_DIR" "$REPORT_DIR" 2>/dev/null || true

    if [[ -r "$WORKLOAD_CONF" ]]; then
        # shellcheck disable=SC1090
        source "$WORKLOAD_CONF"
    else
        die "cannot read workload config: $WORKLOAD_CONF"
    fi
    (( ${#WL_ORDER[@]} > 0 )) || die "no workloads registered from $WORKLOAD_CONF"
    _aat_validate_gates

    # llmb-run lives in a venv on most installs.
    if [[ -n "${LLMB_VENV:-}" && -x "$LLMB_VENV/bin/llmb-run" ]]; then
        PATH="$LLMB_VENV/bin:$PATH"; export PATH
    fi
    [[ -n "${LLMB_INSTALL:-}" ]] && export LLMB_INSTALL

    if [[ "$(id -u)" == 0 && "${ALLOW_ROOT:-0}" != 1 ]]; then
        die "refusing to run as root (root-owned files in $RESULTS_DIR break the
 ${RUN_AS_USER:-svc-bringup} sbatch path). Re-run as ${RUN_AS_USER:-svc-bringup} or set ALLOW_ROOT=1."
    fi
}

_aat_validate_conf() {
    local v missing=()
    for v in AAT_HOME RESULTS_DIR STATE_DIR PARTITION GPUS_PER_NODE NODES_PER_RACK; do
        [[ -n "${!v:-}" ]] || missing+=("$v")
    done
    (( ${#missing[@]} == 0 )) || die "cluster.conf missing: ${missing[*]}"
    [[ "$GPUS_PER_NODE"  =~ ^[0-9]+$ ]] || die "GPUS_PER_NODE must be numeric"
    [[ "$NODES_PER_RACK" =~ ^[0-9]+$ ]] || die "NODES_PER_RACK must be numeric"
    GPUS_PER_RACK=$((GPUS_PER_NODE * NODES_PER_RACK))
    : "${MAX_RACK_JOB_HOURS:=30}" "${MAX_SUBMITS_PER_CYCLE:=8}" "${SUBMIT_SLEEP:=10}"
    : "${QUEUE_DEPTH_LIMIT:=32}" "${ON_RACK_FAIL:=drain}" "${RETRY_FAILED:=0}"
    : "${RETRY_INFRA_FAIL:=1}" "${MAX_ATTEMPTS:=3}" "${LLMB_SUBCOMMAND:=auto}"
    : "${SLURM_TOPOLOGY:=block}" "${LLMB_STAGE_IMAGE:=1}" "${OUTLIER_FRAC:=0.05}"
    : "${OUTLIER_MIN_SAMPLES:=8}" "${LOG_LEVEL:=INFO}" "${LLMB_EXTRA_ENV:=}"
    case "$ON_RACK_FAIL" in drain|none) ;; *) die "ON_RACK_FAIL must be drain|none";; esac
    case "$SLURM_TOPOLOGY" in block|none) ;; *) die "SLURM_TOPOLOGY must be block|none";; esac
}

# Every gate must name a workload that exists and is declared earlier.
_aat_validate_gates() {
    local n g seen=" "
    for n in "${WL_ORDER[@]}"; do
        for g in $(wl_gates "$n"); do
            wl_exists "$g" || die "workload $n: gate '$g' is not a known workload"
            [[ "$seen" == *" $g "* ]] || die "workload $n: gate '$g' is declared after it"
        done
        seen+="$n "
    done
}

# --------------------------------------------------------------------------- #
# locking - the orchestrator is safe to run from cron and by hand at once
# --------------------------------------------------------------------------- #
with_lock() {
    local name="$1"; shift
    local lf="$STATE_DIR/locks/$name.lock"
    mkdir -p "$(dirname "$lf")"
    exec 9>"$lf" || die "cannot open lock $lf"
    if ! flock -n 9; then
        info "another $name holds the lock - exiting quietly"
        return 75          # EX_TEMPFAIL
    fi
    "$@"
}

# --------------------------------------------------------------------------- #
# state files:  KEY=VALUE, one per line. Deliberately dumb and greppable so a
# human on a bring-up call can read and hand-edit them.
# --------------------------------------------------------------------------- #
state_path() {           # state_path <rack|group> <id> <workload> [run]
    local kind="$1" id="$2" wlname="$3" run="${4:-}"
    local base="$STATE_DIR/${kind}s/$id"
    if [[ -n "$run" && "$run" -gt 1 ]] 2>/dev/null; then
        printf '%s/%s-run%s.state' "$base" "$wlname" "$run"
    else
        printf '%s/%s.state' "$base" "$wlname"
    fi
}

state_get() {            # state_get <file> <key> [default]
    local f="$1" k="$2" d="${3:-}"
    [[ -r "$f" ]] || { printf '%s' "$d"; return 0; }
    local v
    v="$(grep -m1 "^$k=" "$f" 2>/dev/null || true)"
    if [[ -z "$v" ]]; then printf '%s' "$d"; else printf '%s' "${v#*=}"; fi
}

state_set() {            # state_set <file> key=val [key=val ...]
    local f="$1"; shift
    mkdir -p "$(dirname "$f")"
    local kv k tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/aat.XXXXXX")"
    [[ -r "$f" ]] && cat "$f" >"$tmp"
    for kv in "$@"; do
        k="${kv%%=*}"
        grep -v "^$k=" "$tmp" >"$tmp.n" 2>/dev/null || : >"$tmp.n"
        mv "$tmp.n" "$tmp"
        printf '%s\n' "$kv" >>"$tmp"
    done
    printf 'updated_at=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" >>"$tmp"
    grep -v '^updated_at=' "$tmp" >"$tmp.f"; grep -m1 '^updated_at=' "$tmp" >>"$tmp.f"
    mv "$tmp.f" "$f"; rm -f "$tmp" "$tmp.n"
}

state_status() { state_get "$1" status NOT_RUN; }

# --------------------------------------------------------------------------- #
# command execution with a real dry-run mode.
# AAT_DRY_RUN=1 prints what would run and returns success without side effects,
# so a site engineer can eyeball every llmb-run line before anything is queued.
# --------------------------------------------------------------------------- #
run_cmd() {
    if [[ "${AAT_DRY_RUN:-0}" == 1 ]]; then
        printf 'DRY-RUN: %s\n' "$*" >&2
        return 0
    fi
    debug "exec: $*"
    "$@"
}

# Numeric compare helpers that work without bc.
fgt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 > b+0)}'; }
flt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 < b+0)}'; }
