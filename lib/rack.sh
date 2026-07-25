#!/bin/bash
# lib/rack.sh - the NVL72 rack is the unit of work for llmb-run, so everything
# that maps nodes <-> racks lives here.
#
# The inventory file is authoritative. Do NOT derive rack membership by string
# arithmetic on node names: on the target cluster the tray U-numbers inside a rack are
# 11-18,28-37 - not 01-18 - so any "-ct[01-18]" style assumption (as used in
# the reference scripts) silently builds the wrong nodelist.

[[ -n "${_AAT_RACK_SH:-}" ]] && return 0
_AAT_RACK_SH=1

declare -A RACK_NODES=()      # rack -> "n1 n2 ... n18"
declare -A RACK_LABEL=()      # rack -> physical rack label from the CVT
declare -A NODE_RACK=()       # node -> rack
declare -a RACK_ORDER=()

rack_load_inventory() {
    local f="${1:-$RACK_INVENTORY}"
    [[ -r "$f" ]] || die "rack inventory not readable: $f"
    RACK_NODES=(); RACK_LABEL=(); NODE_RACK=(); RACK_ORDER=()
    local line rack label nodes n count=0
    while IFS= read -r line; do
        line="${line%%#*}"
        [[ -z "${line// /}" ]] && continue
        # shellcheck disable=SC2206
        set -- $line
        (( $# >= 3 )) || die "inventory $f: bad line (need rack label node...): $line"
        rack="$1"; label="$2"; shift 2; nodes="$*"
        [[ -n "${RACK_NODES[$rack]:-}" ]] && die "inventory $f: duplicate rack $rack"
        RACK_NODES["$rack"]="$nodes"
        RACK_LABEL["$rack"]="$label"
        RACK_ORDER+=("$rack")
        for n in $nodes; do
            [[ -n "${NODE_RACK[$n]:-}" ]] && die "inventory $f: node $n in two racks"
            NODE_RACK["$n"]="$rack"
        done
        count=$((count + 1))
    done <"$f"
    (( count > 0 )) || die "inventory $f contained no racks"
    debug "loaded $count racks / ${#NODE_RACK[@]} nodes from $f"
}

rack_list()  { printf '%s\n' "${RACK_ORDER[@]}"; }
rack_nodes() { printf '%s' "${RACK_NODES[$1]:-}"; }
rack_label() { printf '%s' "${RACK_LABEL[$1]:-}"; }
node_rack()  { printf '%s' "${NODE_RACK[$1]:-}"; }
rack_exists(){ [[ -n "${RACK_NODES[$1]:-}" ]]; }

# Folded hostlist for one rack: rack01-[11-18,28-37]
rack_nodelist() { ns_fold "$(rack_nodes "$1")"; }

rack_node_count() {
    local n c=0
    for n in $(rack_nodes "$1"); do c=$((c + 1)); done
    printf '%s' "$c"
}

# A rack is submit-ready when every tray is idle in Slurm. Anything else
# (down, drained, allocated) means we must not queue rack-scale work: a job
# that pends forever behind a drained tray looks exactly like a hung benchmark
# on a bring-up call, and costs an hour to diagnose.
# Echoes a human reason on stdout when not ready.
rack_ready() {
    local rack="$1" n st bad=() notidle=()
    for n in $(rack_nodes "$rack"); do
        st="$(sl_node_state "$n")"
        case "$st" in
            idle) ;;
            down|down\**|drained|draining|drain|fail|failing|unknown|no_respond)
                bad+=("$n:$st") ;;
            *) notidle+=("$n:$st") ;;
        esac
    done
    if (( ${#bad[@]} > 0 )); then
        printf 'unhealthy trays: %s' "$(IFS=,; echo "${bad[*]}")"
        return 1
    fi
    if (( ${#notidle[@]} > 0 )); then
        printf 'busy trays: %s' "$(IFS=,; echo "${notidle[*]}")"
        return 1
    fi
    local want have
    want="$NODES_PER_RACK"; have="$(rack_node_count "$rack")"
    if [[ "$have" != "$want" ]]; then
        printf 'inventory has %s trays, expected %s' "$have" "$want"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------ groups --
# Groups are DERIVED, never registered. An earlier version built them into a
# global map inside `group_build`, but every caller invoked it as
# `for gid in $(group_build ...)` - a subshell - so the map was empty by the time
# try_submit read it, nracks came out 0 and jobs went out with `--scale 0`.
# Deriving membership from the inventory order keeps group ids stable across
# restarts and works no matter what subshell you are in.

# group_id <racks_per_job> <first rack>
group_id() { printf 'g%s_%s' "$1" "$2"; }

# group_list <racks_per_job> -> one group id per line, inventory order.
# A trailing partial chunk is dropped: a 4-rack test with 3 racks is a different
# test, not a smaller one.
group_list() {
    local per="$1" i n=${#RACK_ORDER[@]}
    [[ "$per" =~ ^[0-9]+$ ]] && (( per > 0 )) || return 0
    for ((i = 0; i + per <= n; i += per)); do
        printf '%s\n' "$(group_id "$per" "${RACK_ORDER[$i]}")"
    done
}

# group_racks <gid> -> space separated rack list
group_racks() {
    local gid="$1" per first i j n=${#RACK_ORDER[@]}
    [[ "$gid" =~ ^g([0-9]+)_(.+)$ ]] || return 1
    per="${BASH_REMATCH[1]}"; first="${BASH_REMATCH[2]}"
    for ((i = 0; i < n; i++)); do [[ "${RACK_ORDER[$i]}" == "$first" ]] && break; done
    (( i < n )) || return 1
    (( i + per <= n )) || return 1
    local -a out=()
    for ((j = i; j < i + per; j++)); do out+=("${RACK_ORDER[$j]}"); done
    printf '%s' "${out[*]}"
}

# group_of <rack> <racks_per_job> -> the gid containing that rack
group_of() {
    local rack="$1" per="$2" gid
    while IFS= read -r gid; do
        [[ " $(group_racks "$gid") " == *" $rack "* ]] && { printf '%s' "$gid"; return 0; }
    done < <(group_list "$per")
    return 1
}

group_nodes() {
    local gid="$1" r out=""
    for r in $(group_racks "$gid"); do out+=" $(rack_nodes "$r")"; done
    printf '%s' "${out# }"
}

group_nodelist() { ns_fold "$(group_nodes "$1")"; }

group_ready() {
    local gid="$1" r reason bad=""
    for r in $(group_racks "$gid"); do
        if ! reason="$(rack_ready "$r")"; then bad+="${bad:+; }$r: $reason"; fi
    done
    [[ -z "$bad" ]] && return 0
    printf '%s' "$bad"; return 1
}
