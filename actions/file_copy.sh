#!/bin/bash
# actions/file_copy.sh - stage the llmb container image onto each tray's local
# NVMe so an 18-tray job does not pull a 25 GB squashfs from the shared FS
# 18 times.
#
# Two modes:
#   (a) BCM action on the node (no arguments): copies for this tray only.
#   (b) head node with a hostlist:  ./file_copy.sh 'rack01-[11-18,28-37]'
#       Two-stage hierarchical copy - shared source to one leader per rack, then
#       leader to its rack siblings - which is what keeps this from saturating
#       the shared filesystem at 112-rack scale.
#
# Uses clush/pdsh when present, falls back to plain ssh loops so this works on a
# head node without ClusterShell installed.
set -uo pipefail
AAT_ROOT="${AAT_ROOT:-/opt/llmb-bringup}"
source "$AAT_ROOT/lib/common.sh"; source "$AAT_ROOT/lib/nodeset.sh"
source "$AAT_ROOT/lib/slurm.sh";  source "$AAT_ROOT/lib/rack.sh"
_AAT_TAG=file_copy
aat_init

IMG="$LLMB_IMAGE_NAME"
SRC="${LLMB_IMAGE_SRC%/}/$IMG"
DST_DIR="${LLMB_IMAGE_LOCAL%/}"
DST="$DST_DIR/$IMG"
STAGE2_FANOUT="${STAGE2_FANOUT:-8}"

if [[ "${LLMB_STAGE_IMAGE:-1}" != 1 ]]; then
    info "LLMB_STAGE_IMAGE=0 - nothing to stage"; exit 0
fi
[[ -r "$SRC" ]] || die "source image not readable: $SRC"

# ---- mode (a): local tray ----
if (( $# == 0 )); then
    mkdir -p "$DST_DIR" || die "cannot create $DST_DIR (run as root or make it writable)"
    run_cmd rsync -ah --inplace "$SRC" "$DST"
    info "staged $IMG on $HOSTNAME"
    exit 0
fi

# ---- mode (b): head node, hostlist ----
rack_load_inventory
NODES="$(ns_expand "$*")"
[[ -n "$NODES" ]] || die "no nodes resolved from '$*'"

leaders=""
for r in $(printf '%s\n' $NODES | while read -r n; do node_rack "$n"; echo; done | sort -u); do
    [[ -z "$r" ]] && continue
    first="$(printf '%s\n' $NODES | grep -F -- "$r-" | sort | head -1)"
    [[ -n "$first" ]] && leaders+=" $first"
done
leaders="${leaders# }"
[[ -n "$leaders" ]] || die "could not derive rack leaders; is the inventory current?"
info "rack leaders: $(ns_fold "$leaders")"

fanout() {   # fanout <hostlist> <command>
    local hl="$1" cmd="$2"
    if command -v clush >/dev/null 2>&1; then
        run_cmd clush -w "$(ns_fold "$hl")" -f "$(ns_count "$hl")" "$cmd"
    else
        local n
        for n in $(ns_expand "$hl"); do
            run_cmd ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$n" "$cmd" &
        done
        wait
    fi
}

info "[stage 1] shared source -> rack leaders"
fanout "$leaders" "mkdir -p $DST_DIR && rsync -ah --inplace $SRC $DST" \
    || warn "stage 1 reported errors (dead leaders?) - continuing"

info "[stage 2] rack leaders -> remaining trays"
for L in $leaders; do
    rack="$(node_rack "$L")"
    sibs="$(printf '%s\n' $NODES | grep -F -- "$rack-" | grep -vFx "$L" | tr '\n' ' ')"
    [[ -z "${sibs// /}" ]] && continue
    if command -v pdsh >/dev/null 2>&1; then
        run_cmd pdsh -R ssh -f "$STAGE2_FANOUT" -w "$(ns_fold "$sibs")" \
            "mkdir -p $DST_DIR && rsync -ah --inplace $L:$DST $DST" &
    else
        fanout "$sibs" "mkdir -p $DST_DIR && rsync -ah --inplace $L:$DST $DST" &
    fi
done
wait
info "staging complete: $IMG -> $DST_DIR on $(ns_count "$NODES") trays"
