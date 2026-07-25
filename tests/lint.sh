#!/bin/bash
# tests/lint.sh - static checks.
#
# shellcheck cannot be installed in this environment (pythonhosted is blocked),
# so this parses every script and greps for the specific pitfalls that actually
# bit during development. Comments are stripped before matching, so the rules
# do not fire on the notes that explain them.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FAIL=0
note() { printf '  %-28s %s\n' "$1" "$2"; FAIL=1; }
pass() { printf '  ok  %s\n' "$1"; }

# Scripts carried over from the sbatch original with no changes. Left verbatim
# on purpose: rewriting them is not part of this conversion and would bury the
# real diff in noise.
LEGACY='node-health-refresh.sh set-valid-default.sh single-node-purge.sh sync-check.sh watch-rack.sh node_health.sh valid-node-check.sh'
is_legacy() { case " $LEGACY " in *" ${1##*/} "*) return 0 ;; esac; return 1; }

mapfile -t FILES < <(find lib bin actions tests -name '*.sh' -type f | sort)

# code_lines <file> -> "line:content" with comment-only and trailing comments dropped
code_lines() { sed 's/[[:space:]]*#.*$//' "$1" | grep -n . ; }

scan() {   # scan <name> <regex> <message> [file ...]
    local name="$1" re="$2" msg="$3"; shift 3
    local f hit=0 l
    for f in "$@"; do
        while IFS= read -r l; do
            [[ "$l" =~ $re ]] && { note "$f" "$msg (line ${l%%:*})"; hit=1; }
        done < <(code_lines "$f")
    done
    (( hit )) || pass "$name"
}

printf '== parse ==\n'
for f in "${FILES[@]}"; do
    if out="$(bash -n "$f" 2>&1)"; then pass "$f"; else note "$f" "parse error: $out"; fi
done
for f in conf/*.conf; do
    if out="$(bash -n "$f" 2>&1)"; then pass "$f"; else note "$f" "parse error: $out"; fi
done

printf '\n== pitfalls ==\n'
scan 'no "grep -c ... ||" double-prints' \
     'grep -c.*\|\|[[:space:]]*(printf|echo)' \
     'grep -c prints the count AND the fallback' "${FILES[@]}"

scan 'no self-referencing single-line locals' \
     '^[[:space:]]*local [a-z_]+="\$[0-9]".*"\$[a-z_]+"' \
     'every RHS on a local line expands before any assignment (set -u trap)' \
     lib/*.sh bin/*.sh

scan 'no subshell-registered global state' \
     '\$\(group_build' \
     'globals set inside $( ) are lost' "${FILES[@]}"

printf '\n== conventions ==\n'
missing=0
for f in bin/*.sh actions/*.sh; do
    is_legacy "$f" && continue
    grep -q '^set -uo pipefail' "$f" || { note "$f" "missing 'set -uo pipefail'"; missing=1; }
done
(( missing )) || pass "entry points set -uo pipefail"

# multi-line word-set constants: `X="a b\n c"` used with a " $x " membership test
if awk '/^_?[A-Z][A-Z_]*="[^"]*$/ { print FILENAME":"FNR }' lib/*.sh | grep -q .; then
    awk '/^_?[A-Z][A-Z_]*="[^"]*$/ { print "  "FILENAME"  unterminated word-set at line "FNR }' lib/*.sh
    FAIL=1
else pass "no multi-line word-set constants"; fi

grep -q "MUST stay last" lib/results.sh || note lib/results.sh "result-file compat contract comment gone"
grep -q "MUST stay last" lib/results.sh && pass "result-file compat contract documented"

printf '\n'
if (( FAIL )); then printf 'lint: FAILED\n'; exit 1; fi
printf 'lint: clean (%d shell files + %d conf)\n' "${#FILES[@]}" "$(ls conf/*.conf | wc -l)"
