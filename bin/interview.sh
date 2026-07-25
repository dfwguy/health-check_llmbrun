#!/bin/bash
# bin/interview.sh - collect everything this suite needs about a cluster and
# write the site configuration. Run this FIRST, once per cluster.
#
#   bin/interview.sh                     # detect + confirm each answer
#   bin/interview.sh --non-interactive   # accept every detected value
#   bin/interview.sh --answers site.conf # replay a previous interview
#   bin/interview.sh --force             # overwrite an existing conf/cluster.conf
#   bin/interview.sh --offline           # no cluster access: prompt for everything
#
# It writes three files:
#   conf/cluster.conf            the site configuration the suite reads
#   conf/inventory/racks.txt     rack -> node mapping
#   conf/interview-answers.conf  every answer, so this can be replayed
#
# Nothing else in the repo needs editing to move to a new cluster.
#
# Design note: every question is asked with a DETECTED default where detection is
# possible, because the fastest way to get a wrong nodelist is to make a human
# retype 2000 hostnames.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

INTERACTIVE=1; FORCE=0; OFFLINE=0; ANSWERS_IN=""
while (( $# )); do
    case "$1" in
        --non-interactive|-y) INTERACTIVE=0 ;;
        --answers) ANSWERS_IN="${2:-}"; INTERACTIVE=0; shift ;;
        --force|-f) FORCE=1 ;;
        --offline) OFFLINE=1 ;;
        -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 1 ;;
    esac
    shift
done

OUT_CONF="$ROOT/conf/cluster.conf"
OUT_INV="$ROOT/conf/inventory/racks.txt"
OUT_ANS="$ROOT/conf/interview-answers.conf"

c_b=$'\033[1m'; c_g=$'\033[32m'; c_y=$'\033[33m'; c_c=$'\033[36m'; c_d=$'\033[2m'; c_0=$'\033[0m'
[[ -t 1 ]] || { c_b=""; c_g=""; c_y=""; c_c=""; c_d=""; c_0=""; }

sect()  { printf '\n%s=== %s ===%s\n' "$c_b" "$1" "$c_0"; }
note()  { printf '  %s%s%s\n' "$c_d" "$1" "$c_0"; }
found() { printf '  %sdetected%s %s\n' "$c_g" "$c_0" "$1"; }
nope()  { printf '  %scould not detect%s %s\n' "$c_y" "$c_0" "$1"; }

have() { command -v "$1" >/dev/null 2>&1; }
probe() { (( OFFLINE )) && return 1; have "$1"; }

# ask <var> <prompt> <default> [hint]
ask() {
    local var="$1" prompt="$2" def="$3" hint="${4:-}" reply=""
    # a value already loaded from --answers wins
    if [[ -n "${!var:-}" && -n "$ANSWERS_IN" ]]; then
        printf '  %-26s %s %s(from answers file)%s\n' "$prompt" "${!var}" "$c_d" "$c_0"
        return 0
    fi
    if (( INTERACTIVE == 0 )); then
        printf -v "$var" '%s' "$def"
        printf '  %-26s %s\n' "$prompt" "$def"
        return 0
    fi
    [[ -n "$hint" ]] && note "$hint"
    printf '  %s%s%s [%s%s%s]: ' "$c_c" "$prompt" "$c_0" "$c_b" "$def" "$c_0"
    IFS= read -r reply || reply=""
    printf -v "$var" '%s' "${reply:-$def}"
}

# ask_choice <var> <prompt> <default> <option...>
ask_choice() {
    local var="$1" prompt="$2" def="$3"; shift 3
    local opts=("$@") i reply
    if [[ -n "${!var:-}" && -n "$ANSWERS_IN" ]]; then
        printf '  %-26s %s %s(from answers file)%s\n' "$prompt" "${!var}" "$c_d" "$c_0"; return 0
    fi
    if (( INTERACTIVE == 0 )); then
        printf -v "$var" '%s' "$def"; printf '  %-26s %s\n' "$prompt" "$def"; return 0
    fi
    printf '  %s%s%s\n' "$c_c" "$prompt" "$c_0"
    for i in "${!opts[@]}"; do
        printf '    %d) %s%s\n' "$((i+1))" "${opts[$i]}" \
            "$([[ "${opts[$i]}" == "$def" ]] && printf '  <- default')"
    done
    printf '  choice [%s]: ' "$def"
    IFS= read -r reply || reply=""
    if [[ -z "$reply" ]]; then printf -v "$var" '%s' "$def"
    elif [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= ${#opts[@]} )); then
        printf -v "$var" '%s' "${opts[$((reply-1))]}"
    else printf -v "$var" '%s' "$reply"; fi
}

confirm() {
    (( INTERACTIVE )) || return 0
    local reply
    printf '  %s%s%s [y/N]: ' "$c_c" "$1" "$c_0"
    IFS= read -r reply || reply=""
    [[ "$reply" == [yY]* ]]
}

# --------------------------------------------------------------------------- #
printf '%s\n' "$c_b"
cat <<'BANNER'
  llmb-bringup - site interview
  Collects the cluster facts this suite needs and writes conf/cluster.conf.
BANNER
printf '%s' "$c_0"

if [[ -n "$ANSWERS_IN" ]]; then
    [[ -r "$ANSWERS_IN" ]] || { printf 'cannot read answers file: %s\n' "$ANSWERS_IN" >&2; exit 1; }
    # shellcheck disable=SC1090
    source "$ANSWERS_IN"
    note "replaying answers from $ANSWERS_IN"
fi
if [[ -e "$OUT_CONF" && "$FORCE" != 1 ]]; then
    printf '\n%sconf/cluster.conf already exists.%s Re-run with --force to overwrite it.\n' "$c_y" "$c_0"
    printf 'Existing settings would be lost; %s keeps a copy of the last interview.\n' "conf/interview-answers.conf"
    exit 1
fi

# =========================================================================== #
sect "1. identity and paths"
det_cluster=""
if probe scontrol; then
    det_cluster="$(scontrol show config 2>/dev/null | awk -F= '/^ClusterName/{gsub(/ /,"",$2); print $2}')"
fi
[[ -n "$det_cluster" ]] && found "Slurm ClusterName = $det_cluster" || nope "cluster name"
ask CLUSTER_NAME "cluster name" "${det_cluster:-mycluster}" \
    "Free-form label used in reports and logs."

ask AAT_HOME "deploy root" "$ROOT" \
    "Where this repo lives on the head node; results/, state/, log/ are created under it."
det_user="$(id -un)"
if [[ "$det_user" == root ]]; then
    # Suggest whoever owns the checkout; a guessed username that does not exist
    # produces a confusing chown failure much later.
    det_user="$(stat -c %U "$ROOT" 2>/dev/null || true)"
    [[ -z "$det_user" || "$det_user" == root ]] && det_user=""
fi
ask RUN_AS_USER "service user" "${det_user}" \
    "The account the orchestrator and sbatch jobs run as. Must exist, and should not be root."

# =========================================================================== #
sect "2. platform profile"
det_gpu=""
if probe nvidia-smi; then
    det_gpu="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
fi
[[ -n "$det_gpu" ]] && found "local GPU = $det_gpu" || nope "GPU model (head nodes usually have none)"
det_profile=generic
case "${det_gpu,,}" in
    *gb300*) det_profile=gb300-nvl72 ;;
    *gb200*) det_profile=gb200-nvl72 ;;
    *b300*|*b200*) det_profile=gb200-nvl72 ;;
    *vr200*) det_profile=vr200-nvl144 ;;
    *h100*|*h200*) det_profile=hgx-8gpu ;;
esac
mapfile -t profiles < <(cd "$ROOT/conf/profiles" 2>/dev/null && ls -1 *.conf 2>/dev/null | sed 's/\.conf$//')
(( ${#profiles[@]} )) || profiles=(generic)
ask_choice PLATFORM_PROFILE "platform profile" "$det_profile" "${profiles[@]}"
note "Profiles set rack geometry and NCCL bandwidth floors; see conf/profiles/."
# shellcheck disable=SC1090
[[ -r "$ROOT/conf/profiles/$PLATFORM_PROFILE.conf" ]] && source "$ROOT/conf/profiles/$PLATFORM_PROFILE.conf"

# =========================================================================== #
sect "3. slurm"
det_part=""
if probe sinfo; then
    det_part="$(sinfo -h -o '%P' 2>/dev/null | grep '\*$' | head -1 | tr -d '*')"
    [[ -z "$det_part" ]] && det_part="$(sinfo -h -o '%R' 2>/dev/null | head -1)"
fi
[[ -n "$det_part" ]] && found "default partition = $det_part" || nope "partition"
ask PARTITION "GPU partition" "${det_part:-defq}"

det_acct=""
if probe sacctmgr; then
    det_acct="$(sacctmgr -n show user "$(id -un)" format=DefaultAccount 2>/dev/null | tr -d ' ' | head -1)"
fi
ask SLURM_ACCOUNT "slurm account (blank = none)" "${det_acct:-}"

det_gpn=""
if probe sinfo; then
    det_gpn="$(sinfo -h -p "$PARTITION" -o '%G' 2>/dev/null | tr ',' '\n' \
               | sed -n 's/.*gpu:[^:]*:\([0-9]\+\).*/\1/p;s/^gpu:\([0-9]\+\)$/\1/p' | sort -u | head -1)"
fi
[[ -n "$det_gpn" ]] && found "GPUs per node from gres = $det_gpn" || nope "GPUs per node"
ask GPUS_PER_NODE "GPUs per node" "${det_gpn:-${PROFILE_GPUS_PER_NODE:-4}}" \
    "Every --scale value is derived from this. Getting it wrong sizes every job wrong."

det_topo=""
if probe scontrol; then
    det_topo="$(scontrol show config 2>/dev/null | awk -F= '/^TopologyPlugin/{gsub(/ /,"",$2); print $2}')"
fi
if [[ -n "$det_topo" ]]; then
    found "TopologyPlugin = $det_topo"
    case "$det_topo" in *block*) det_st=block ;; *) det_st=none ;; esac
else
    nope "topology plugin"; det_st=block
fi
ask_choice SLURM_TOPOLOGY "topology mode" "$det_st" block none
note "block: multi-rack jobs pin with --exclude (--nodelist conflicts with block placement)."
note "none:  --nodelist everywhere."

# =========================================================================== #
sect "4. rack layout"
note "A rack here means one NVLink domain - the unit an llmb-run job occupies."
NODES_RAW=""
if probe sinfo; then
    NODES_RAW="$(sinfo -h -N -p "$PARTITION" -o '%N' 2>/dev/null | sort -u)"
fi
if [[ -z "$NODES_RAW" ]]; then
    nope "node list from Slurm"
    ask NODE_SOURCE_FILE "file with one node name per line" "" \
        "Offline mode needs a node list. Leave blank to write a placeholder inventory you edit by hand."
    [[ -n "${NODE_SOURCE_FILE:-}" && -r "$NODE_SOURCE_FILE" ]] && NODES_RAW="$(sort -u "$NODE_SOURCE_FILE")"
else
    found "$(printf '%s\n' "$NODES_RAW" | grep -c .) nodes in partition $PARTITION"
fi

RACK_RULE=""
if [[ -n "$NODES_RAW" ]]; then
    # Evaluate candidate grouping rules and score them: a good rule yields racks
    # that are all the same size, and that size is a plausible tray count.
    declare -a RULES=(
        's/-[0-9]\+$//'                 # node-r01-05      -> node-r01
        's/[0-9]\+$//'                  # noder0105        -> noder01
        's/-[^-]*-[^-]*$//'             # dc-row-r01-t05   -> dc-row
        's/\(.*\)-[a-z]*[0-9]\+$/\1/'   # rack-ct01        -> rack
    )
    printf '\n  %-34s %8s %10s %s\n' "candidate rule" "racks" "trays/rack" "verdict"
    printf '  %-34s %8s %10s %s\n' "----------------------------------" "-----" "----------" "-------"
    best=""; best_score=-1
    for r in "${RULES[@]}"; do
        sizes="$(printf '%s\n' "$NODES_RAW" | sed "$r" | sort | uniq -c | awk '{print $1}' | sort -u)"
        nracks="$(printf '%s\n' "$NODES_RAW" | sed "$r" | sort -u | grep -c .)"
        uniq_sizes="$(printf '%s\n' "$sizes" | grep -c .)"
        size="$(printf '%s\n' "$sizes" | head -1)"
        verdict="mixed sizes"; score=0
        if [[ "$uniq_sizes" == 1 ]] && (( size >= 2 && size <= 72 )) && (( nracks >= 1 )); then
            verdict="uniform"; score=$(( 100 - nracks % 100 ))
            (( size == ${PROFILE_NODES_PER_RACK:-18} )) && { verdict="uniform, matches profile"; score=$((score + 1000)); }
        fi
        printf '  %-34s %8s %10s %s\n' "$r" "$nracks" "$(printf '%s' "$sizes" | tr '\n' '/')" "$verdict"
        (( score > best_score )) && { best_score=$score; best="$r"; }
    done
    printf '\n'
    ask RACK_RULE "rack grouping rule (sed)" "${best:-s/-[0-9]\+$//}" \
        "Applied to each node name to get its rack id. Pick a row above or type your own."
fi

if [[ -n "$NODES_RAW" && -n "$RACK_RULE" ]]; then
    tmpinv="$(mktemp)"
    printf '%s\n' "$NODES_RAW" | sed "$RACK_RULE" | sort -u | while IFS= read -r rack; do
        members="$(printf '%s\n' "$NODES_RAW" | awk -v r="$rack" -v re="$RACK_RULE" '
            { line=$0; cmd="printf %s \"" line "\" | sed \x27" re "\x27"
              cmd | getline g; close(cmd); if (g == r) print line }' | sort | tr '\n' ' ')"
        printf '%s - %s\n' "$rack" "${members% }"
    done >"$tmpinv"
    nracks="$(grep -c . "$tmpinv" || true)"
    modal="$(awk '{print NF-2}' "$tmpinv" | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')"
    found "$nracks racks, $modal trays in the most common rack"
    printf '  %sfirst rack:%s %s\n' "$c_d" "$c_0" "$(head -1 "$tmpinv" | cut -c1-100)"
    odd="$(awk -v m="$modal" 'NF-2 != m {print $1"("NF-2")"}' "$tmpinv" | tr '\n' ' ')"
    [[ -n "$odd" ]] && printf '  %sracks that are not %s trays:%s %s\n' "$c_y" "$modal" "$c_0" "${odd:0:200}"
    ask NODES_PER_RACK "trays per rack" "${modal:-${PROFILE_NODES_PER_RACK:-18}}"
else
    ask NODES_PER_RACK "trays per rack" "${PROFILE_NODES_PER_RACK:-18}"
    tmpinv="$(mktemp)"
    printf '# PLACEHOLDER - no node list was available during the interview.\n' >"$tmpinv"
    printf '# Format: <rack_id> <site_label|-> <node> <node> ...\n' >>"$tmpinv"
    printf '# Generate with docs/gen-inventory-from-slurm.sh on the head node.\n' >>"$tmpinv"
fi

# =========================================================================== #
sect "5. llmb-run (DGX Cloud Benchmarking)"
det_venv=""
for c in "$HOME/llmbmarking/llmb_venv" /opt/llmbmarking/llmb_venv; do
    [[ -x "$c/bin/llmb-run" ]] && { det_venv="$c"; break; }
done
[[ -n "$det_venv" ]] && found "venv = $det_venv" || nope "llmb venv"
ask LLMB_VENV "llmb-run venv (blank if on PATH)" "$det_venv"
[[ -n "$LLMB_VENV" && -x "$LLMB_VENV/bin/llmb-run" ]] && PATH="$LLMB_VENV/bin:$PATH"

det_install="${LLMB_INSTALL:-}"
if [[ -z "$det_install" ]]; then
    for c in "$HOME/llmb" /home/*/llmb; do [[ -d "$c/workloads" ]] && { det_install="$c"; break; }; done
fi
[[ -n "$det_install" ]] && found "LLMB_INSTALL = $det_install" || nope "LLMB_INSTALL"
ask LLMB_INSTALL "LLMB_INSTALL path" "${det_install:-$HOME/llmb}" \
    "Shared-filesystem install produced by llmbmarking/install.sh."

det_sub=auto
if probe llmb-run; then
    h="$(llmb-run --help 2>&1 || true)"
    if printf '%s' "$h" | grep -qw submit; then det_sub=submit; found "llmb-run supports 'submit' (placement flags available)"
    elif printf '%s' "$h" | grep -qw single; then det_sub=single
         printf '  %swarning%s this release has no "submit": rack pinning is impossible\n' "$c_y" "$c_0"
    fi
fi
ask_choice LLMB_SUBCOMMAND "launch subcommand" "$det_sub" auto submit single

det_img=""
if [[ -d "$LLMB_INSTALL/images" ]]; then
    det_img="$(ls -1t "$LLMB_INSTALL/images" 2>/dev/null | grep -i '\.sqsh$' | head -1)"
fi
[[ -n "$det_img" ]] && found "container image = $det_img" || nope "container image"
ask LLMB_IMAGE_NAME "container image filename" "${det_img:-nvidia+nemo+26.04.01.sqsh}"
ask LLMB_IMAGE_SRC "shared image directory" "$LLMB_INSTALL/images"
ask_choice LLMB_STAGE_IMAGE "stage image to node-local disk" 1 1 0
note "1 = copy to each node's local NVMe first (strongly recommended at rack scale)."
if [[ "$LLMB_STAGE_IMAGE" == 1 ]]; then
    ask LLMB_IMAGE_LOCAL "node-local staging dir" "${LLMB_IMAGE_LOCAL:-/raid/llmb}"
else
    LLMB_IMAGE_LOCAL="${LLMB_IMAGE_LOCAL:-/raid/llmb}"
fi

# =========================================================================== #
sect "6. fabric interface"
det_nic=""
if (( OFFLINE == 0 )) && have srun && [[ -n "$NODES_RAW" ]]; then
    probe_node="$(printf '%s\n' "$NODES_RAW" | head -1)"
    note "probing $probe_node for its highest-speed ethernet interface..."
    det_nic="$(srun -w "$probe_node" -p "$PARTITION" -t 1 --pty bash -c '
        for i in /sys/class/net/*; do
            n=${i##*/}
            [[ "$n" == lo || "$n" == ib* || "$n" == docker* ]] && continue
            s=$(cat "$i/speed" 2>/dev/null || echo 0)
            printf "%s %s\n" "${s:-0}" "$n"
        done | sort -rn | head -1 | awk "{print \$2}"' 2>/dev/null | tr -d '[:space:]')"
fi
[[ -n "$det_nic" ]] && found "NCCL_SOCKET_IFNAME candidate = $det_nic" || nope "fabric interface"
ask NCCL_SOCKET_IFNAME "NCCL_SOCKET_IFNAME" "$det_nic" \
    "The ethernet interface NCCL should bootstrap over. Wrong value = jobs hang at init."
ask LLMB_EXTRA_ENV_MORE "extra env for every llmb job" "" \
    "Space-separated KEY=VAL, e.g. 'NCCL_IB_HCA=mlx5_0,mlx5_1'. Blank is fine."

# =========================================================================== #
sect "7. per-node health checks"
det_driver=none
have cmsh && det_driver=bcm
[[ "$det_driver" == bcm ]] && found "BCM detected (cmsh present)" || nope "BCM (cmsh not found)"
ask_choice NODE_HEALTH_DRIVER "how node health is triggered" "$det_driver" bcm cron none
note "bcm:  register monitoring triggers (pre-post/create-action-trigger.sh)"
note "cron: run actions/node_health.sh from cron on each node"
note "none: skip per-node health entirely (rack workloads then gate on nothing)"
if [[ "$NODE_HEALTH_DRIVER" == bcm ]]; then
    ask BCM_HEAD "BCM head node hostname" "$(hostname -s 2>/dev/null || echo localhost)"
else
    BCM_HEAD=""
fi

# =========================================================================== #
sect "8. policy"
ask MAX_SUBMITS_PER_CYCLE "new jobs per pass" "${MAX_SUBMITS_PER_CYCLE:-8}"
ask QUEUE_DEPTH_LIMIT "stop submitting at queue depth" "${QUEUE_DEPTH_LIMIT:-32}"
ask MAX_RACK_JOB_HOURS "cancel a rack job after N hours" "${MAX_RACK_JOB_HOURS:-30}"
ask_choice ON_RACK_FAIL "on rack failure" "${ON_RACK_FAIL:-drain}" drain none
ask_choice RETRY_FAILED "retry a real failure" "${RETRY_FAILED:-0}" 0 1
note "0 keeps a failed rack failed until a human clears it - usually what you want."

# =========================================================================== #
sect "writing files"
GPUS_PER_RACK=$(( GPUS_PER_NODE * NODES_PER_RACK ))
LLMB_EXTRA_ENV="$(printf 'NCCL_SOCKET_IFNAME=%s %s' "${NCCL_SOCKET_IFNAME:-}" "${LLMB_EXTRA_ENV_MORE:-}")"
LLMB_EXTRA_ENV="$(printf '%s' "$LLMB_EXTRA_ENV" | sed 's/NCCL_SOCKET_IFNAME= //; s/[[:space:]]*$//')"

mkdir -p "$ROOT/conf/inventory"
if [[ -s "$tmpinv" ]]; then
    {
        printf '# rack_id  site_label  node1 node2 ... nodeN\n'
        printf '# Generated by bin/interview.sh on %s\n' "$(date -Iseconds)"
        printf '# Cluster: %s   partition: %s   grouping rule: %s\n' "$CLUSTER_NAME" "$PARTITION" "${RACK_RULE:-n/a}"
        printf '# One rack = one NVLink domain = %s nodes = %s GPUs.\n' "$NODES_PER_RACK" "$GPUS_PER_RACK"
        printf '# Node numbering inside a rack is often NOT contiguous - this file is the\n'
        printf '# authority, never derive membership by arithmetic on node names.\n'
        cat "$tmpinv"
    } >"$OUT_INV"
    printf '  wrote %s (%s racks)\n' "${OUT_INV#"$ROOT"/}" "$(grep -vc '^#' "$OUT_INV" || true)"
fi
rm -f "$tmpinv"

cat >"$OUT_CONF" <<CONF
# ============================================================================
# cluster.conf - site configuration
#
# GENERATED by bin/interview.sh on $(date -Iseconds)
# Cluster: $CLUSTER_NAME
#
# Safe to hand-edit. To regenerate: bin/interview.sh --force
# To replay this interview elsewhere: bin/interview.sh --answers conf/interview-answers.conf
# ============================================================================

CLUSTER_NAME="$CLUSTER_NAME"
PLATFORM_PROFILE="$PLATFORM_PROFILE"

# Rack geometry and NCCL bandwidth floors come from the platform profile.
# Anything set after this line overrides the profile.
if [ -r "\$(dirname "\${BASH_SOURCE[0]}")/profiles/$PLATFORM_PROFILE.conf" ]; then
    . "\$(dirname "\${BASH_SOURCE[0]}")/profiles/$PLATFORM_PROFILE.conf"
fi

# ---------------------------------------------------------------- paths -----
AAT_HOME="$AAT_HOME"
RESULTS_DIR="\$AAT_HOME/results"
STATE_DIR="\$AAT_HOME/state"
LOG_DIR="\$AAT_HOME/log"
REPORT_DIR="\$AAT_HOME/reports"
LOGS_DIR="\$AAT_HOME/logs"
VALID_CONFIG_DIR="\$AAT_HOME/valid-config"
RACK_INVENTORY="\$AAT_HOME/conf/inventory/racks.txt"
WORKLOAD_CONF="\$AAT_HOME/conf/workloads.conf"

# ------------------------------------------------------------- llmb-run -----
LLMB_INSTALL="$LLMB_INSTALL"
LLMB_VENV="$LLMB_VENV"
LLMB_SUBCOMMAND=$LLMB_SUBCOMMAND
LLMB_IMAGE_NAME="$LLMB_IMAGE_NAME"
LLMB_IMAGE_SRC="$LLMB_IMAGE_SRC"
LLMB_IMAGE_LOCAL="$LLMB_IMAGE_LOCAL"
LLMB_STAGE_IMAGE=$LLMB_STAGE_IMAGE

# ---------------------------------------------------------------- slurm -----
PARTITION="$PARTITION"
SLURM_ACCOUNT="$SLURM_ACCOUNT"
GPUS_PER_NODE=$GPUS_PER_NODE
NODES_PER_RACK=$NODES_PER_RACK
GPUS_PER_RACK=\$((GPUS_PER_NODE * NODES_PER_RACK))
SLURM_TOPOLOGY=$SLURM_TOPOLOGY

# ------------------------------------------------------- health-check mode ---
NODE_HEALTH_DRIVER=$NODE_HEALTH_DRIVER
BCM_HEAD="$BCM_HEAD"

# ------------------------------------------------------------- policies -----
MAX_JOB_HOURS=${MAX_JOB_HOURS:-6}
MAX_RACK_JOB_HOURS=$MAX_RACK_JOB_HOURS
MAX_SUBMITS_PER_CYCLE=$MAX_SUBMITS_PER_CYCLE
SUBMIT_SLEEP=${SUBMIT_SLEEP:-10}
QUEUE_DEPTH_LIMIT=$QUEUE_DEPTH_LIMIT
ON_RACK_FAIL=$ON_RACK_FAIL
RETRY_FAILED=$RETRY_FAILED
RETRY_INFRA_FAIL=${RETRY_INFRA_FAIL:-1}
MAX_ATTEMPTS=${MAX_ATTEMPTS:-3}

# --------------------------------------------------------------- outlier ----
OUTLIER_FRAC=${OUTLIER_FRAC:-0.05}
OUTLIER_MIN_SAMPLES=${OUTLIER_MIN_SAMPLES:-8}

# ----------------------------------------------------------------- misc -----
RUN_AS_USER="$RUN_AS_USER"
ALLOW_ROOT=${ALLOW_ROOT:-0}
LLMB_EXTRA_ENV="$LLMB_EXTRA_ENV"
LOG_LEVEL=${LOG_LEVEL:-INFO}
CONF
printf '  wrote %s\n' "${OUT_CONF#"$ROOT"/}"

{
    printf '# Answers from bin/interview.sh on %s\n' "$(date -Iseconds)"
    printf '# Replay with: bin/interview.sh --answers conf/interview-answers.conf --force\n'
    for v in CLUSTER_NAME PLATFORM_PROFILE AAT_HOME RUN_AS_USER PARTITION SLURM_ACCOUNT \
             GPUS_PER_NODE NODES_PER_RACK SLURM_TOPOLOGY RACK_RULE LLMB_INSTALL LLMB_VENV \
             LLMB_SUBCOMMAND LLMB_IMAGE_NAME LLMB_IMAGE_SRC LLMB_IMAGE_LOCAL LLMB_STAGE_IMAGE \
             NCCL_SOCKET_IFNAME LLMB_EXTRA_ENV_MORE NODE_HEALTH_DRIVER BCM_HEAD \
             MAX_SUBMITS_PER_CYCLE QUEUE_DEPTH_LIMIT MAX_RACK_JOB_HOURS ON_RACK_FAIL RETRY_FAILED; do
        printf '%s=%q\n' "$v" "${!v:-}"
    done
} >"$OUT_ANS"
printf '  wrote %s\n' "${OUT_ANS#"$ROOT"/}"

# =========================================================================== #
sect "summary"
if [[ -z "${NCCL_SOCKET_IFNAME:-}" ]]; then
    printf '  %sNCCL_SOCKET_IFNAME is not set.%s NCCL will pick an interface itself, which
' "$c_y" "$c_0"
    printf '  works on some fabrics and hangs at init on others. Set it once you know the
'
    printf '  name: srun -w <node> -p %s ip -br link, then add it to LLMB_EXTRA_ENV in
' "$PARTITION"
    printf '  conf/cluster.conf.

'
fi
if [[ -z "${RUN_AS_USER:-}" ]]; then
    printf '  %sservice user is blank.%s Set RUN_AS_USER in conf/cluster.conf, or run the
' "$c_y" "$c_0"
    printf '  suite as a non-root account that owns %s.

' "$AAT_HOME"
fi
printf '  %-24s %s\n' "cluster"        "$CLUSTER_NAME"
printf '  %-24s %s\n' "profile"        "$PLATFORM_PROFILE"
printf '  %-24s %s / %s GPUs per node / %s nodes per rack = %s GPUs per rack\n' \
       "geometry" "$PARTITION" "$GPUS_PER_NODE" "$NODES_PER_RACK" "$GPUS_PER_RACK"
printf '  %-24s %s\n' "topology mode"  "$SLURM_TOPOLOGY"
printf '  %-24s %s\n' "llmb install"   "$LLMB_INSTALL"
printf '  %-24s %s\n' "image"          "$LLMB_IMAGE_NAME"
printf '  %-24s %s\n' "health driver"  "$NODE_HEALTH_DRIVER"
[[ -s "$OUT_INV" ]] && printf '  %-24s %s racks\n' "inventory" "$(grep -vc '^#' "$OUT_INV" || true)"

cat <<NEXT

${c_b}next steps${c_0}
  1. bin/verify-cluster.sh --fix-hints        check every answer against the cluster
  2. review conf/workloads.conf              the validation matrix and its gating
  3. actions/file_copy.sh '<nodelist>'       stage the container image
  4. bin/rack-orchestrator.sh --dry-run      see the exact llmb-run commands
  5. bin/rack-orchestrator.sh --rack <rack>  one rack, then calibrate thresholds

NEXT
