#!/bin/bash
# lib/slurm.sh - every call into Slurm goes through here, so the mock harness
# can replace the whole surface and so failures degrade predictably.

[[ -n "${_AAT_SLURM_SH:-}" ]] && return 0
_AAT_SLURM_SH=1

sl_have() { command -v "$1" >/dev/null 2>&1; }

# --------------------------------------------------------------- node state --
# Lowercase Slurm state with flags stripped: idle, alloc, mix, drain, down...
# '%T' gives the base state; drained/draining show as 'drained'/'draining'.
sl_node_state() {
    local node="$1" out
    sl_have sinfo || { printf 'unknown'; return 0; }
    out="$(sinfo -N -n "$node" -h -o '%T' 2>/dev/null | head -1)"
    out="${out%\*}"                     # strip the unreachable marker
    printf '%s' "${out:-unknown}"
}

# One "node state" line per node in a hostlist.
sl_node_states() {
    local nl="$1" n
    for n in $(ns_expand "$nl"); do printf '%s %s\n' "$n" "$(sl_node_state "$n")"; done
}

sl_node_is_usable() {                   # idle or already running our work
    case "$(sl_node_state "$1")" in
        idle|allocated|alloc|mixed|mix|completing|comp) return 0 ;;
        *) return 1 ;;
    esac
}

sl_node_is_idle() {
    case "$(sl_node_state "$1")" in idle) return 0 ;; *) return 1 ;; esac
}

sl_drain() {                            # sl_drain <hostlist> <reason>
    local nl="$1" reason="$2"
    sl_have scontrol || { warn "scontrol missing; cannot drain $nl"; return 0; }
    # Slurm caps reason length; keep it short and greppable.
    reason="${reason:0:200}"
    run_cmd scontrol update "nodename=$nl" state=DRAIN "reason=$reason"
}

sl_resume() {
    local nl="$1"
    sl_have scontrol || return 0
    run_cmd scontrol update "nodename=$nl" state=RESUME
}

sl_partition_nodes() {
    sl_have sinfo || return 0
    sinfo -h -p "$PARTITION" -o '%N' 2>/dev/null | tr '\n' ',' | sed 's/,$//'
}

# ---------------------------------------------------------------- job state --
# Preference order: sacct (authoritative, survives job completion) then squeue
# (live only). llmb-run's own bookkeeping is NOT trusted for state: it is known
# to keep jobs at RUNNING after Slurm has cancelled or requeued them.
sl_job_state() {
    local jid="$1" st=""
    if sl_have sacct; then
        st="$(sacct -j "$jid" -X -n -P -o State 2>/dev/null | head -1)"
        st="${st%% *}"                   # "CANCELLED by 1234" -> CANCELLED
    fi
    if [[ -z "$st" ]] && sl_have squeue; then
        st="$(squeue -h -j "$jid" -o '%T' 2>/dev/null | head -1)"
    fi
    printf '%s' "${st:-UNKNOWN}"
}

# Elapsed wall time of a job, in whole hours.
sl_job_elapsed_hours() {
    local jid="$1" el=""
    if sl_have sacct; then
        el="$(sacct -j "$jid" -X -n -P -o Elapsed 2>/dev/null | head -1)"
    fi
    if [[ -z "$el" ]] && sl_have squeue; then
        el="$(squeue -h -j "$jid" -o '%M' 2>/dev/null | head -1)"
    fi
    sl_parse_elapsed_hours "$el"
}

# Accepts MM:SS, HH:MM:SS, D-HH:MM:SS, D-HH:MM, or empty.
sl_parse_elapsed_hours() {
    local e="${1:-}"
    [[ -z "$e" ]] && { printf '0'; return 0; }
    if [[ "$e" =~ ^([0-9]+)-([0-9]+):([0-9]+):([0-9]+)$ ]]; then
        printf '%s' $(( ${BASH_REMATCH[1]} * 24 + ${BASH_REMATCH[2]} ))
    elif [[ "$e" =~ ^([0-9]+)-([0-9]+):([0-9]+)$ ]]; then
        printf '%s' $(( ${BASH_REMATCH[1]} * 24 + ${BASH_REMATCH[2]} ))
    elif [[ "$e" =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]]; then
        printf '%s' "$(( 10#${BASH_REMATCH[1]} ))"
    else
        printf '0'
    fi
}

sl_job_nodelist() {
    local jid="$1" nl=""
    if sl_have squeue; then nl="$(squeue -h -j "$jid" -o '%N' 2>/dev/null | head -1)"; fi
    if [[ -z "$nl" ]] && sl_have sacct; then
        nl="$(sacct -j "$jid" -X -n -P -o NodeList 2>/dev/null | head -1)"
    fi
    printf '%s' "$nl"
}

sl_cancel() {
    local jid="$1"
    sl_have scancel || return 0
    run_cmd scancel "$jid"
}

# How many of our jobs are already queued or running.
sl_queue_depth() {
    sl_have squeue || { printf '0'; return 0; }
    # NB: `grep -c` prints 0 and exits 1 on no match, so a `|| printf 0` fallback
    # emits "0\n0" and every arithmetic context downstream blows up.
    local n
    n="$(squeue -h -u "$(id -un)" -o '%i' 2>/dev/null | grep -c . || true)"
    printf '%s' "${n:-0}"
}

# Terminal Slurm states.
sl_state_is_terminal() {
    case "$1" in
        COMPLETED|FAILED|CANCELLED|TIMEOUT|OUT_OF_MEMORY|NODE_FAIL|BOOT_FAIL|DEADLINE|PREEMPTED|REVOKED)
            return 0 ;;
        *) return 1 ;;
    esac
}

# States that mean "the cluster broke, not the workload" - worth one retry.
sl_state_is_infra() {
    case "$1" in NODE_FAIL|BOOT_FAIL|PREEMPTED|REVOKED) return 0 ;; *) return 1 ;; esac
}
