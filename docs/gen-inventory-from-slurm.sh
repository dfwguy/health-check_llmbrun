#!/bin/bash
# docs/gen-inventory-from-slurm.sh - build conf/inventory/racks.txt from live Slurm.
#
# Use this when verify-cluster.sh reports that the CVT-derived names do not exist
# in Slurm. Slurm is authoritative for --nodelist, so when the two disagree, this
# wins.
#
#   docs/gen-inventory-from-slurm.sh                 > conf/inventory/racks.txt
#   RACK_RE='s/-[0-9]+$//' docs/gen-inventory-from-slurm.sh > ...
#
# RACK_RE is the sed expression that turns a node name into its rack id. The
# default strips a trailing -<number>, which groups rack01-37 into
# rack01. If your names differ (e.g. othernaming-gpu0123), override it.
set -uo pipefail
PARTITION="${PARTITION:-defq}"
RACK_RE="${RACK_RE:-s/-[0-9]\+$//}"
EXPECT="${NODES_PER_RACK:-18}"

nodes="$(sinfo -h -N -p "$PARTITION" -o '%N' | sort -u)"
[[ -n "$nodes" ]] || { echo "sinfo returned no nodes for partition $PARTITION" >&2; exit 1; }

printf '# rack_id  physical_rack  node1 ... nodeN\n'
printf '# Generated from live Slurm (partition %s) on %s.\n' "$PARTITION" "$(date -Iseconds)"
printf '# Rack grouping rule: sed %s applied to each node name.\n' "'$RACK_RE'"
printf '# Physical rack label is UNKNOWN from Slurm and set to "-"; fill it from the CVT if you want it.\n'

printf '%s\n' "$nodes" | sed "$RACK_RE" | sort -u | while read -r rack; do
    members="$(printf '%s\n' "$nodes" | awk -v r="$rack" -v re="$RACK_RE" '
        { n=$0; cmd="printf %s \"" n "\" | sed \"" re "\""; cmd | getline g; close(cmd); if (g==r) print n }' | sort | tr '\n' ' ')"
    count="$(printf '%s' "$members" | wc -w)"
    if [[ "$count" != "$EXPECT" ]]; then
        printf '# WARNING rack %s has %s trays, expected %s\n' "$rack" "$count" "$EXPECT" >&2
    fi
    printf '%s - %s\n' "$rack" "${members% }"
done
