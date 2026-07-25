#!/bin/bash
# lib/nodeset.sh - Slurm-style hostlist fold/expand.
#
# WHY THIS EXISTS: the reference implementation shells out to ClusterShell
# (`nodeset`), which is not installed on every BCM head node. Everything here
# is pure bash+awk and is used unconditionally; if `nodeset` happens to be on
# PATH it is used as a fast path for expansion only (its folding output is
# equivalent to ours for the single-bracket names this cluster uses).
#
# Supported bracket form: <prefix>[<ranges>]<suffix>  with one bracket group,
# ranges = comma separated N or N-M, zero padding preserved. That covers every
# name in a real cluster inventory (rack01-[11-18,28-37]) and everything
# Slurm hands back in %N. Nested/multi-bracket forms are rejected loudly
# rather than silently mis-expanded.

[[ -n "${_AAT_NODESET_SH:-}" ]] && return 0
_AAT_NODESET_SH=1

# ns_expand <hostlist ...> -> one node per line, sorted, unique
ns_expand() {
    local raw="$*"
    [[ -z "${raw// /}" ]] && return 0
    printf '%s' "$raw" | awk '
    function emit(s) { if (s != "") print s }
    {
        # split on commas that are NOT inside brackets, and on whitespace
        n = length($0); depth = 0; tok = ""
        for (i = 1; i <= n; i++) {
            c = substr($0, i, 1)
            if (c == "[") depth++
            else if (c == "]") depth--
            if ((c == "," || c == " " || c == "\t") && depth == 0) { emit(tok); tok = "" }
            else tok = tok c
        }
        emit(tok)
    }' | while IFS= read -r tok; do
        [[ -z "$tok" ]] && continue
        if [[ "$tok" != *'['* ]]; then printf '%s\n' "$tok"; continue; fi
        if [[ "$(printf '%s' "$tok" | tr -cd '[' | wc -c)" -gt 1 ]]; then
            printf 'ns_expand: unsupported multi-bracket hostlist: %s\n' "$tok" >&2
            return 1
        fi
        local pre body post
        pre="${tok%%\[*}"; body="${tok#*\[}"; body="${body%%\]*}"; post="${tok##*\]}"
        local part lo hi w i
        IFS=',' read -r -a _parts <<<"$body"
        for part in "${_parts[@]}"; do
            if [[ "$part" == *-* ]]; then
                lo="${part%%-*}"; hi="${part##*-}"
                w="${#lo}"
                for ((i = 10#$lo; i <= 10#$hi; i++)); do
                    printf '%s%0*d%s\n' "$pre" "$w" "$i" "$post"
                done
            else
                printf '%s%s%s\n' "$pre" "$part" "$post"
            fi
        done
    done | sort -u
}

# ns_count <hostlist ...>
ns_count() { ns_expand "$@" | grep -c . || true; }

# ns_fold <nodes ...> -> compact hostlist, comma separated between prefixes.
# Groups by "everything up to the final numeric field".
ns_fold() {
    local nodes
    nodes="$(ns_expand "$@")"
    [[ -z "$nodes" ]] && return 0
    printf '%s\n' "$nodes" | awk '
    {
        name = $0
        # split trailing digits into (prefix, number); preserve zero padding
        if (match(name, /[0-9]+$/)) {
            num = substr(name, RSTART, RLENGTH)
            pre = substr(name, 1, RSTART - 1)
        } else { pre = name; num = "" }
        if (num == "") { plain[name] = 1; next }
        key = pre SUBSEP length(num)
        if (!(key in seen)) { order[++nk] = key; seen[key] = 1; prefix[key] = pre; width[key] = length(num) }
        vals[key] = vals[key] " " (num + 0)
    }
    END {
        out = ""
        for (i = 1; i <= nk; i++) {
            key = order[i]
            m = split(vals[key], a, " ")
            # insertion sort (small n)
            for (x = 1; x <= m; x++) for (y = x + 1; y <= m; y++) if (a[y] + 0 < a[x] + 0) { t = a[x]; a[x] = a[y]; a[y] = t }
            ranges = ""; s = a[1]; p = a[1]
            for (x = 2; x <= m; x++) {
                if (a[x] + 0 == p + 0 + 1) { p = a[x]; continue }
                ranges = ranges (ranges == "" ? "" : ",") rng(s, p, width[key])
                s = a[x]; p = a[x]
            }
            ranges = ranges (ranges == "" ? "" : ",") rng(s, p, width[key])
            if (m == 1 && s == p) item = prefix[key] pad(s, width[key])
            else item = prefix[key] "[" ranges "]"
            out = out (out == "" ? "" : ",") item
        }
        for (nm in plain) out = out (out == "" ? "" : ",") nm
        print out
    }
    function pad(v, w) { return sprintf("%0" w "d", v) }
    function rng(s, e, w) { return (s == e) ? pad(s, w) : pad(s, w) "-" pad(e, w) }
    '
}

# ns_subtract <all> <remove>  -> folded hostlist of all minus remove
ns_subtract() {
    local all remove
    all="$(ns_expand "$1")"; remove="$(ns_expand "$2")"
    ns_fold "$(comm -23 <(printf '%s\n' "$all") <(printf '%s\n' "$remove") | tr '\n' ' ')"
}
