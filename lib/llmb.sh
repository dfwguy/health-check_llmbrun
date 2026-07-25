#!/bin/bash
# lib/llmb.sh - the only place that knows how to talk to llmb-run.
#
# Release differences this handles, because the the target cluster install may be either:
#   25.10.x : `llmb-run single -w W -s S --dtype D --scale N`
#             no placement flags, no `jobs` subcommand
#   26.06.x : `llmb-run submit -w W [-s S] --dtype D --scale N
#              [--force|--proxy] [--nodelist NL] [--exclude NL]`
#             plus `llmb-run jobs list` / `jobs show <id>`
#
# Results:
#   pretrain  -> llmb-run parses them (TFLOPS/GPU, s/iter via `jobs show`)
#   NCCL      -> llmb-run does NOT parse them; we read the sweep .txt files
#                under $LLMB_INSTALL/workloads/microbenchmark_nccl/experiments/

[[ -n "${_AAT_LLMB_SH:-}" ]] && return 0
_AAT_LLMB_SH=1

NCCL_COLLECTIVES="all_reduce all_gather reduce_scatter alltoall sendrecv"

llmb_have() { command -v llmb-run >/dev/null 2>&1; }

# ------------------------------------------------------- capability probing --
_LLMB_SUBCMD=""
llmb_subcommand() {
    [[ -n "$_LLMB_SUBCMD" ]] && { printf '%s' "$_LLMB_SUBCMD"; return 0; }
    if [[ "${LLMB_SUBCOMMAND:-auto}" != auto ]]; then
        _LLMB_SUBCMD="$LLMB_SUBCOMMAND"
    elif ! llmb_have; then
        _LLMB_SUBCMD="submit"          # assume modern; submission will fail loudly
    else
        local h
        h="$(llmb-run --help 2>&1 || true)"
        if printf '%s' "$h" | grep -qw submit; then _LLMB_SUBCMD="submit"
        elif printf '%s' "$h" | grep -qw single; then _LLMB_SUBCMD="single"
        else _LLMB_SUBCMD="submit"; fi
    fi
    debug "llmb-run subcommand: $_LLMB_SUBCMD"
    printf '%s' "$_LLMB_SUBCMD"
}

llmb_supports_placement() { [[ "$(llmb_subcommand)" == submit ]]; }

_LLMB_HAS_JOBS=""
llmb_has_jobs_cmd() {
    if [[ -z "$_LLMB_HAS_JOBS" ]]; then
        if ! llmb_have; then _LLMB_HAS_JOBS=0
        elif llmb-run jobs --help >/dev/null 2>&1; then _LLMB_HAS_JOBS=1
        else _LLMB_HAS_JOBS=0; fi
        debug "llmb-run jobs subcommand available: $_LLMB_HAS_JOBS"
    fi
    [[ "$_LLMB_HAS_JOBS" == 1 ]]
}

# ------------------------------------------------------------- placement -----
# llmb_placement_args <pin_mode> <n_racks> <target_nodelist>
# Echoes the flags to append. Empty output = unpinned.
llmb_placement_args() {
    # Separate statements on purpose: bash expands every RHS on a single `local`
    # line before making any assignment, so `local a="$1" b="$a"` dies under set -u.
    local pin="$1" nracks="$2" target="$3"
    local mode="$pin"
    if [[ "$pin" == auto ]]; then
        if (( nracks <= 1 )); then mode=nodelist
        elif [[ "${SLURM_TOPOLOGY:-block}" == block ]]; then mode=exclude
        else mode=nodelist; fi
    fi
    case "$mode" in
        none) return 0 ;;
        nodelist) printf -- '--nodelist %s' "$target" ;;
        exclude)
            # Documented workaround: with topology/block enforced, --nodelist
            # conflicts with block placement ("Requested topology configuration
            # is not available"), so pin by excluding the rest of the partition.
            local pool ex
            pool="$(sl_partition_nodes)"
            if [[ -z "$pool" ]]; then
                pool="$(ns_fold "$(printf '%s ' "${!NODE_RACK[@]}")")"
                warn "sinfo gave no partition nodes; excluding from inventory instead"
            fi
            ex="$(ns_subtract "$pool" "$target")"
            if [[ -z "$ex" ]]; then
                debug "exclude set is empty (target is the whole partition)"
                return 0
            fi
            printf -- '--exclude %s' "$ex"
            ;;
    esac
}

# ------------------------------------------------------------- submission ----
# llmb_submit <wlname> <scale> <n_racks> <target_nodelist>
# Prints the job id on stdout. Non-zero return means "not submitted".
llmb_submit() {
    local name="$1" scale="$2" nracks="$3" target="$4"
    local sub; sub="$(llmb_subcommand)"

    local -a argv=(llmb-run "$sub" -w "$(wl "$name" llmb_workload)")
    local size dtype flag
    size="$(wl "$name" llmb_size)"; [[ "$size" != "-" && -n "$size" ]] && argv+=(-s "$size")
    dtype="$(wl "$name" dtype)";    [[ "$dtype" != "-" && -n "$dtype" ]] && argv+=(--dtype "$dtype")
    argv+=(--scale "$scale")

    flag="$(wl "$name" scale_flag)"
    if [[ "$flag" != "-" && -n "$flag" ]]; then
        if llmb_supports_placement; then
            argv+=("--$flag")
        else
            warn "$name: --$flag not supported by 'llmb-run single'; omitting"
        fi
    fi

    local place=""
    if llmb_supports_placement; then
        place="$(llmb_placement_args "$(wl "$name" pin)" "$nracks" "$target")"
        # shellcheck disable=SC2206
        [[ -n "$place" ]] && argv+=($place)
    elif [[ "$(wl "$name" pin)" != none ]]; then
        if [[ "${AAT_ALLOW_UNPINNED:-0}" != 1 ]]; then
            error "$name: this llmb-run release has no 'submit' subcommand, so the job
 cannot be pinned to $target. An unpinned rack-scale job lands on arbitrary racks and its
 result cannot be attributed to a rack, which corrupts the validation matrix.
 Fix: install a release with 'llmb-run submit' (26.06+), or set AAT_ALLOW_UNPINNED=1
 to accept unattributable results."
            return 1
        fi
        warn "$name: submitting UNPINNED (AAT_ALLOW_UNPINNED=1); results not rack-attributable"
    fi

    # Environment: image override + global extras + per-workload env.
    local -a envv=()
    if [[ "${LLMB_STAGE_IMAGE:-1}" == 1 ]]; then
        envv+=("RUN_CONF_IMAGE=${LLMB_IMAGE_LOCAL%/}/$LLMB_IMAGE_NAME")
    else
        envv+=("RUN_CONF_IMAGE=${LLMB_IMAGE_SRC%/}/$LLMB_IMAGE_NAME")
    fi
    local e
    for e in ${LLMB_EXTRA_ENV:-};      do envv+=("$e"); done
    for e in $(wl "$name" env);        do envv+=("$e"); done

    local out rc
    info "submit $name scale=$scale racks=$nracks target=$target"
    if [[ "${AAT_DRY_RUN:-0}" == 1 ]]; then
        # stderr: this function's stdout is the job id, and a human reading a
        # dry run needs the command, not a swallowed line.
        printf 'DRY-RUN: env %s %s\n' "${envv[*]}" "${argv[*]}" >&2
        printf 'DRYRUN'
        return 0
    fi
    out="$(env "${envv[@]}" "${argv[@]}" 2>&1)"; rc=$?
    printf '%s\n' "$out" | sed 's/^/  llmb| /' >&2
    if (( rc != 0 )); then
        error "$name: llmb-run exited $rc"
        return 1
    fi
    local jid
    jid="$(llmb_parse_jobid "$out")"
    if [[ -z "$jid" ]]; then
        error "$name: llmb-run returned 0 but no job id could be parsed from its output"
        return 1
    fi
    printf '%s' "$jid"
}

# Job id appears in several shapes across releases; try all of them.
#   "JobID: 48727, Workdir: ..."      "... jobid=48727"      "- Job id: 48727"
llmb_parse_jobid() {
    local out="$1" jid
    jid="$(printf '%s\n' "$out" | sed -n 's/.*JobID:[[:space:]]*\([0-9]\{2,\}\).*/\1/p'  | head -1)"
    [[ -z "$jid" ]] && jid="$(printf '%s\n' "$out" | sed -n 's/.*jobid=\([0-9]\{2,\}\).*/\1/p' | head -1)"
    [[ -z "$jid" ]] && jid="$(printf '%s\n' "$out" | sed -n 's/.*Job id:[[:space:]]*\([0-9]\{2,\}\).*/\1/p' | head -1)"
    [[ -z "$jid" ]] && jid="$(printf '%s\n' "$out" | sed -n 's/.*Submitted batch job[[:space:]]*\([0-9]\{2,\}\).*/\1/p' | head -1)"
    printf '%s' "$jid"
}

# ------------------------------------------------------------ job details ----
# `llmb-run jobs show <id>` prints "Label : value" lines. Absent on 25.10.
llmb_job_show() {
    local jid="$1"
    llmb_has_jobs_cmd || return 1
    llmb-run jobs show "$jid" 2>/dev/null
}

llmb_job_show_field() {
    local jid="$1" label="$2" out
    out="$(llmb_job_show "$jid")" || return 1
    printf '%s\n' "$out" | awk -F' : ' -v L="$label" '
        { gsub(/^[ \t]+|[ \t]+$/, "", $1) }
        $1 == L { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit }'
}

# TFLOPS per GPU for pretrain workloads. Empty if unavailable.
llmb_job_tflops() {
    local jid="$1" v
    v="$(llmb_job_show_field "$jid" 'TFLOPS/GPU' 2>/dev/null || true)"
    [[ -z "$v" ]] && v="$(llmb_job_show_field "$jid" 'TFLOPS' 2>/dev/null || true)"
    printf '%s' "$v"
}

llmb_job_logdir() {
    local jid="$1" v
    v="$(llmb_job_show_field "$jid" 'Log Dir' 2>/dev/null || true)"
    [[ -z "$v" ]] && v="$(llmb_job_show_field "$jid" 'Workdir' 2>/dev/null || true)"
    printf '%s' "$v"
}

# --------------------------------------------------- NCCL result discovery ---
# $LLMB_INSTALL/workloads/<wl>/experiments/*_<jobid>/LOG_*_<jobid>_*/
llmb_nccl_logdir() {
    local jid="$1" wlkey="${2:-microbenchmark_nccl}" d
    [[ -n "${LLMB_INSTALL:-}" ]] || return 1
    local base="$LLMB_INSTALL/workloads/$wlkey/experiments"
    [[ -d "$base" ]] || return 1
    for d in "$base"/*_"$jid"/LOG_*_"$jid"_*; do
        [[ -d "$d" ]] && { printf '%s' "$d"; return 0; }
    done
    # Looser fallback: any directory under the experiment tree naming this job.
    d="$(find "$base" -maxdepth 3 -type d -name "*$jid*" 2>/dev/null | sort | head -1)"
    [[ -n "$d" ]] && { printf '%s' "$d"; return 0; }
    return 1
}

# llmb_nccl_peaks <logdir> -> "collective=peak_busbw" lines (0 when not found).
llmb_nccl_peaks() {
    local dir="$1" coll files peak
    for coll in $NCCL_COLLECTIVES; do
        peak=0
        files="$(find "$dir" -type f -name "*LOG_${coll}_*.txt" 2>/dev/null | sort)"
        [[ -z "$files" ]] && files="$(find "$dir" -type f -name "*${coll}*.txt" 2>/dev/null | sort)"
        if [[ -n "$files" ]]; then
            # shellcheck disable=SC2086
            peak="$(nccl_peak_busbw $files)"
        fi
        printf '%s=%s\n' "$coll" "${peak:-0}"
    done
}

# nccl_peak_busbw <file ...> -> highest busbw seen in any nccl-tests table.
#
# Column layout varies by test and release, so the busbw columns are located
# from the header line when present:
#   13 cols: size count type redop root  time algbw busbw #wrong time algbw busbw #wrong
#   11 cols: size count type            time algbw busbw #wrong time algbw busbw #wrong
# Picking a fixed column index (as the reference parser does) silently reports 0
# for the 11-column variants.
nccl_peak_busbw() {
    awk '
    FNR == 1 { c1 = 0; c2 = 0 }
    /^#/ {
        if ($0 ~ /busbw/) {
            c1 = 0; c2 = 0; idx = 0
            for (i = 1; i <= NF; i++) {
                t = $i
                if (t == "#") continue
                idx++                       # data-row column number
                if (t == "busbw") { if (!c1) c1 = idx; else if (!c2) c2 = idx }
            }
        }
        next
    }
    $1 ~ /^[0-9]+$/ {
        a = 0; b = 0
        if (c1 && c2 && NF >= c2) { a = $(c1) + 0; b = $(c2) + 0 }
        else if (NF >= 13)        { a = $8 + 0;   b = $12 + 0 }
        else if (NF >= 11)        { a = $6 + 0;   b = $10 + 0 }
        else next
        if (a > peak) peak = a
        if (b > peak) peak = b
    }
    END { printf "%.1f", peak + 0 }
    ' "$@"
}
