#!/bin/bash
# bin/verify-cluster.sh - check every assumption this repo makes against the
# live cluster, before you let it submit anything.
#
# Run this ON THE HEAD NODE as the service user, after editing conf/cluster.conf:
#
#   bin/verify-cluster.sh              # environment, Slurm, inventory, llmb-run
#   bin/verify-cluster.sh --deep       # also srun a real tray to check NIC/raid/GPUs
#   bin/verify-cluster.sh --fix-hints  # print the exact command to fix each FAIL
#
# Exit 0 only when there are no FAILs. WARNs are things to eyeball, not blockers.
#
# WHY THIS EXISTS: the the target cluster project artifacts carry TWO naming domains for the
# same hardware - the CVT Nodes sheet (rack01-37, which is what BCM and
# this repo's inventory use) and the P2P/cabling documents (othernaming-gpu1).
# Naming mismatches across documents are a tracked open issue on the P2P/BOM
# tracker. If Slurm reports a different name family than conf/inventory/racks.txt,
# every --nodelist this repo builds is silently wrong and jobs pend forever. That
# check is the single most important thing below.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(dirname "$HERE")"
source "$ROOT/lib/common.sh"; source "$ROOT/lib/nodeset.sh"
source "$ROOT/lib/slurm.sh";  source "$ROOT/lib/rack.sh"
source "$ROOT/lib/llmb.sh";   source "$ROOT/lib/results.sh"

DEEP=0; HINTS=0
while (( $# )); do
    case "$1" in
        --deep) DEEP=1 ;;
        --fix-hints) HINTS=1 ;;
        -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 1 ;;
    esac
    shift
done

_AAT_TAG=verify; LOG_LEVEL=ERROR
aat_init
rack_load_inventory

NF=0; NW=0
c_g=$'\033[32m'; c_r=$'\033[31m'; c_y=$'\033[33m'; c_b=$'\033[1m'; c_0=$'\033[0m'
[[ -t 1 ]] || { c_g=""; c_r=""; c_y=""; c_b=""; c_0=""; }

pass() { printf '  %sPASS%s  %-34s %s\n' "$c_g" "$c_0" "$1" "${2:-}"; }
warn_() { printf '  %sWARN%s  %-34s %s\n' "$c_y" "$c_0" "$1" "${2:-}"; NW=$((NW+1)); }
fail() { printf '  %sFAIL%s  %-34s %s\n' "$c_r" "$c_0" "$1" "${2:-}"; NF=$((NF+1))
         [[ "$HINTS" == 1 && -n "${3:-}" ]] && printf '        fix: %s\n' "$3"; }
sect() { printf '\n%s== %s ==%s\n' "$c_b" "$1" "$c_0"; }

# --------------------------------------------------------------------------- #
sect "environment"
[[ "${BASH_VERSINFO[0]}" -ge 4 ]] \
    && pass "bash >= 4" "${BASH_VERSION%%(*}" \
    || fail "bash >= 4" "found $BASH_VERSION" "install a newer bash; associative arrays are required"
for t in awk flock sed grep find; do
    command -v "$t" >/dev/null && pass "tool: $t" || fail "tool: $t" "not on PATH"
done
if [[ "$(id -u)" == 0 ]]; then
    [[ "${ALLOW_ROOT:-0}" == 1 ]] \
        && warn_ "running as root" "ALLOW_ROOT=1; root-owned files under $RESULTS_DIR will break the ${RUN_AS_USER} sbatch path" \
        || fail "not running as root" "re-run as ${RUN_AS_USER:-svc-bringup}" "su - ${RUN_AS_USER:-svc-bringup}"
else
    pass "service user" "$(id -un)"
fi
for d in "$AAT_HOME" "$RESULTS_DIR" "$STATE_DIR" "$LOG_DIR"; do
    if mkdir -p "$d" 2>/dev/null && [[ -w "$d" ]]; then pass "writable: ${d#"$AAT_HOME"/}" ""
    else fail "writable: $d" "cannot create or write" "chown -R ${RUN_AS_USER:-svc-bringup} $AAT_HOME"; fi
done

# --------------------------------------------------------------------------- #
sect "slurm"
for t in sinfo squeue scontrol scancel sbatch; do
    command -v "$t" >/dev/null && pass "tool: $t" || fail "tool: $t" "not on PATH" "module load slurm"
done
if command -v sacct >/dev/null; then
    if sacct -n -X -o State -j 1 >/dev/null 2>&1; then
        pass "sacct usable" "job accounting reachable"
    else
        warn_ "sacct usable" "sacct present but erroring; tracking degrades to squeue, which forgets finished jobs"
    fi
else
    warn_ "sacct present" "job state will be read from squeue only; finished jobs look 'unknown to slurm' and get retried"
fi

part_nodes="$(sl_partition_nodes)"
if [[ -n "$part_nodes" ]]; then
    pass "partition $PARTITION exists" "$(ns_count "$part_nodes") nodes"
else
    fail "partition $PARTITION exists" "sinfo -p $PARTITION returned nothing" \
         "set PARTITION= in conf/cluster.conf to a real partition (sinfo -s)"
fi

topo="$(scontrol show config 2>/dev/null | awk -F= '/^TopologyPlugin/{gsub(/ /,"",$2); print $2}')"
if [[ -z "$topo" ]]; then
    warn_ "topology plugin" "could not read scontrol show config"
elif [[ "$topo" == *block* ]]; then
    [[ "$SLURM_TOPOLOGY" == block ]] \
        && pass "topology plugin" "$topo, matches SLURM_TOPOLOGY=block" \
        || fail "topology plugin" "cluster uses $topo but SLURM_TOPOLOGY=$SLURM_TOPOLOGY" \
                "set SLURM_TOPOLOGY=block in conf/cluster.conf (multi-rack must pin via --exclude)"
else
    [[ "$SLURM_TOPOLOGY" == block ]] \
        && warn_ "topology plugin" "cluster uses $topo but SLURM_TOPOLOGY=block; --exclude still works but --nodelist would be simpler" \
        || pass "topology plugin" "$topo, matches SLURM_TOPOLOGY=$SLURM_TOPOLOGY"
fi

gres="$(sinfo -h -p "$PARTITION" -o '%G' 2>/dev/null | sort -u | head -3 | tr '\n' ' ')"
gres="${gres:0:120}"     # a malformed reply must not dump 2000 node names
if [[ -n "${gres// /}" && "$gres" != "(null) " ]]; then
    if printf '%s' "$gres" | grep -q "gpu:.*$GPUS_PER_NODE"; then
        pass "GPUs per node" "$GPUS_PER_NODE (gres: ${gres% })"
    else
        warn_ "GPUs per node" "conf says $GPUS_PER_NODE, gres reports: ${gres% } - scale values depend on this"
    fi
else
    warn_ "GPUs per node" "no gres reported; cannot confirm GPUS_PER_NODE=$GPUS_PER_NODE"
fi

# --------------------------------------------------------------------------- #
sect "inventory vs live cluster   <-- the naming-domain check"
inv_nodes="$(printf '%s\n' "${!NODE_RACK[@]}" | sort)"
inv_n="$(printf '%s\n' "$inv_nodes" | grep -c .)"
live_nodes="$(sinfo -h -N -o '%N' 2>/dev/null | sort -u)"
live_n="$(printf '%s\n' "$live_nodes" | grep -c . || true)"
pass "inventory loaded" "$(rack_list | wc -l) racks / $inv_n trays from ${RACK_INVENTORY##*/}"

if [[ -z "$live_nodes" ]]; then
    fail "slurm node list readable" "sinfo -N returned nothing" "check slurmctld is up: scontrol ping"
else
    missing="$(comm -23 <(printf '%s\n' "$inv_nodes") <(printf '%s\n' "$live_nodes") | head -5)"
    extra="$(comm -13 <(printf '%s\n' "$inv_nodes") <(printf '%s\n' "$live_nodes") | head -5)"
    nmiss="$(comm -23 <(printf '%s\n' "$inv_nodes") <(printf '%s\n' "$live_nodes") | grep -c . || true)"
    nextra="$(comm -13 <(printf '%s\n' "$inv_nodes") <(printf '%s\n' "$live_nodes") | grep -c . || true)"

    if (( nmiss == 0 )); then
        pass "every inventory tray exists in slurm" "$inv_n/$inv_n"
    elif (( nmiss == inv_n )); then
        fail "inventory names match slurm" "NONE of the $inv_n inventory names exist in Slurm" \
             "the inventory is in the wrong naming domain - regenerate it from Slurm: docs/gen-inventory-from-slurm.sh > conf/inventory/racks.txt"
        printf '        inventory sample : %s\n' "$(printf '%s\n' "$inv_nodes" | head -2 | tr '\n' ' ')"
        printf '        slurm sample     : %s\n' "$(printf '%s\n' "$live_nodes" | head -2 | tr '\n' ' ')"
        printf '        Sites often carry two naming domains for the same hardware.\n'
        printf '        Slurm is authoritative for --nodelist. Regenerate from Slurm.\n'
    else
        fail "every inventory tray exists in slurm" "$nmiss of $inv_n missing, e.g. $(printf '%s' "$missing" | tr '\n' ' ')" \
             "remove decommissioned trays from the inventory, or regenerate it"
    fi
    if (( nextra > 0 )); then
        warn_ "slurm nodes not in inventory" "$nextra, e.g. $(printf '%s' "$extra" | tr '\n' ' ') (they will never be tested)"
    else
        pass "no untracked slurm nodes" ""
    fi
fi

badracks=""
while IFS= read -r r; do
    c="$(rack_node_count "$r")"
    [[ "$c" == "$NODES_PER_RACK" ]] || badracks+=" $r($c)"
done < <(rack_list)
if [[ -z "$badracks" ]]; then
    pass "every rack has $NODES_PER_RACK trays" "one NVL72 domain per rack"
else
    fail "every rack has $NODES_PER_RACK trays" "short racks:$badracks" \
         "a short rack builds a wrong --nodelist; fix the inventory"
fi

# group alignment: 4-rack groups should not straddle a data-hall row
straddle=""
per="$(wl nccl_4rack racks_per_job 2>/dev/null || echo 4)"
while IFS= read -r gid; do
    rows="$(for r in $(group_racks "$gid"); do rack_label "$r" | sed 's/[0-9]*$//'; done | sort -u | tr '\n' ',')"
    [[ "$(printf '%s' "$rows" | tr -cd ',' | wc -c)" -gt 1 ]] && straddle+=" $gid($rows)"
done < <(group_list "$per")
[[ -z "$straddle" ]] \
    && pass "${per}-rack groups stay in one row" "no group straddles a data-hall row" \
    || warn_ "${per}-rack groups stay in one row" "straddling:$straddle - fine electrically, but cross-row cable runs skew results"

# --------------------------------------------------------------------------- #
sect "llmb-run"
if llmb_have; then
    pass "llmb-run on PATH" "$(command -v llmb-run)"
else
    fail "llmb-run on PATH" "not found" \
         "set LLMB_VENV=<llmbmarking>/llmb_venv in conf/cluster.conf, or source it"
fi
if llmb_have; then
    sub="$(llmb_subcommand)"
    if [[ "$sub" == submit ]]; then
        pass "launch subcommand" "submit (26.06+): placement flags available"
    else
        fail "launch subcommand" "only '$sub' (25.10-era): no --nodelist/--exclude, rack pinning impossible" \
             "install a release with 'llmb-run submit', or accept unattributable results with AAT_ALLOW_UNPINNED=1"
    fi
    if llmb_has_jobs_cmd; then
        pass "jobs subcommand" "TFLOPS/GPU readable for pretrain scoring"
    else
        warn_ "jobs subcommand" "absent: pretrain workloads cannot be scored; set metric=- on nemo_single or upgrade"
    fi
fi
if [[ -n "${LLMB_INSTALL:-}" && -d "$LLMB_INSTALL" ]]; then
    pass "LLMB_INSTALL" "$LLMB_INSTALL"
    [[ -d "$LLMB_INSTALL/workloads" ]] \
        && pass "  workloads/ present" "$(ls "$LLMB_INSTALL/workloads" 2>/dev/null | tr '\n' ' ')" \
        || fail "  workloads/ present" "no $LLMB_INSTALL/workloads" "re-run llmbmarking/install.sh"
    if [[ -r "$LLMB_IMAGE_SRC/$LLMB_IMAGE_NAME" ]]; then
        pass "  source image" "$LLMB_IMAGE_NAME ($(du -h "$LLMB_IMAGE_SRC/$LLMB_IMAGE_NAME" 2>/dev/null | cut -f1))"
    else
        fail "  source image" "missing $LLMB_IMAGE_SRC/$LLMB_IMAGE_NAME" \
             "check LLMB_IMAGE_NAME in conf/cluster.conf against: ls $LLMB_IMAGE_SRC"
    fi
else
    fail "LLMB_INSTALL" "'${LLMB_INSTALL:-}' is not a directory" \
         "set LLMB_INSTALL in conf/cluster.conf to the install.sh output path"
fi
# every llmb workload named in the matrix must actually be installed
if llmb_have && llmb-run list >/dev/null 2>&1; then
    avail="$(llmb-run list 2>/dev/null)"
    for w in $(wl_list); do
        [[ "$(wl "$w" runner)" == llmb ]] || continue
        lw="$(wl "$w" llmb_workload)"
        printf '%s' "$avail" | grep -q -- "$lw" \
            && pass "workload installed: $lw" "(for $w)" \
            || fail "workload installed: $lw" "not in 'llmb-run list'" \
                    "re-run install.sh and select $lw, or set enabled=0 on $w in conf/workloads.conf"
    done
else
    warn_ "llmb-run list" "could not enumerate installed workloads"
fi

# --------------------------------------------------------------------------- #
sect "workload matrix"
for w in $(wl_list); do
    printf '  %sinfo%s  %-34s runner=%-6s scope=%-5s gate=%s\n' "$c_b" "$c_0" \
        "$w" "$(wl "$w" runner)" "$(wl "$w" scope)" "$(wl "$w" gate)"
done
nic_cfg="$(printf '%s' "${LLMB_EXTRA_ENV:-}" | sed -n 's/.*NCCL_SOCKET_IFNAME=\([^ ]*\).*/\1/p')"
[[ -n "$nic_cfg" ]] \
    && pass "NCCL_SOCKET_IFNAME set" "$nic_cfg (use --deep to confirm it exists on a node)" \
    || warn_ "NCCL_SOCKET_IFNAME set" "unset - NCCL picks an interface itself, which hangs at init on some fabrics"

thr="$(wl nccl_single thresholds 2>/dev/null || true)"
# An "all colons, no numbers" threshold string means an uncalibrated profile.
printf '%s' "$thr" | grep -q '[0-9]' || thr="-"
[[ "$thr" == "-" || -z "$thr" ]] \
    && warn_ "nccl thresholds set" "no absolute floors; only the fleet-relative gate applies" \
    || warn_ "nccl thresholds" "shipped values come from a DIFFERENT GB300 fleet - calibrate on the first 3-5 the target cluster racks"

# --------------------------------------------------------------------------- #
if (( DEEP )); then
    sect "deep checks (one real tray via srun)"
    probe_rack="$(rack_list | head -1)"
    probe_node="$(rack_nodes "$probe_rack" | awk '{print $1}')"
    if ! command -v srun >/dev/null; then
        warn_ "srun available" "skipping deep checks"
    else
        printf '  using tray %s\n' "$probe_node"
        nic="$(printf '%s' "${LLMB_EXTRA_ENV:-}" | sed -n 's/.*NCCL_SOCKET_IFNAME=\([^ ]*\).*/\1/p')"
        out="$(srun -w "$probe_node" -p "$PARTITION" -t 2 --pty bash -c '
            printf "IFACES:%s\n" "$(ip -br link 2>/dev/null | awk "{print \$1}" | tr "\n" ",")"
            printf "GPUS:%s\n"   "$(nvidia-smi -L 2>/dev/null | grep -c GPU)"
            printf "RAIDW:%s\n"  "$([ -w /raid ] && echo yes || echo no)"
        ' 2>/dev/null)" || out=""
        if [[ -z "$out" ]]; then
            warn_ "srun probe" "could not run on $probe_node (drained? busy?)"
        else
            ifaces="$(printf '%s' "$out" | sed -n 's/^IFACES://p')"
            gpus="$(printf '%s' "$out" | sed -n 's/^GPUS://p')"
            raidw="$(printf '%s' "$out" | sed -n 's/^RAIDW://p')"
            if [[ -n "$nic" ]]; then
                printf '%s' "$ifaces" | tr ',' '\n' | grep -qx "$nic" \
                    && pass "NCCL_SOCKET_IFNAME exists" "$nic" \
                    || fail "NCCL_SOCKET_IFNAME exists" "$nic not on $probe_node; has: $ifaces" \
                            "correct LLMB_EXTRA_ENV in conf/cluster.conf"
            fi
            [[ "$gpus" == "$GPUS_PER_NODE" ]] \
                && pass "GPUs on tray" "$gpus" \
                || fail "GPUs on tray" "nvidia-smi sees $gpus, conf says $GPUS_PER_NODE" \
                        "fix GPUS_PER_NODE; every --scale derives from it"
            [[ "$raidw" == yes ]] \
                && pass "$LLMB_IMAGE_LOCAL writable" "" \
                || fail "local image dir writable" "/raid not writable on $probe_node" \
                        "make $LLMB_IMAGE_LOCAL writable, or set LLMB_STAGE_IMAGE=0"
        fi
    fi
fi

# --------------------------------------------------------------------------- #
printf '\n%s== verdict ==%s\n' "$c_b" "$c_0"
if (( NF == 0 && NW == 0 )); then
    printf '  %sready to deploy%s\n' "$c_g" "$c_0"
elif (( NF == 0 )); then
    printf '  %s%d warning(s), 0 failures%s - safe to run --dry-run, read the warnings first\n' "$c_y" "$NW" "$c_0"
else
    printf '  %s%d failure(s)%s, %d warning(s) - DO NOT deploy until the failures are fixed\n' "$c_r" "$NF" "$c_0" "$NW"
    printf '  re-run with --fix-hints for the exact remedy of each failure\n'
fi
printf '\n  next: bin/rack-orchestrator.sh --dry-run\n\n'
(( NF == 0 ))
