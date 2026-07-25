#!/usr/bin/env python3
"""Regenerate conf/inventory/racks.txt from the cluster CVT workbook.

    python3 docs/gen-inventory.py <cluster>.xlsx > conf/inventory/racks.txt

Reads the 'Nodes' sheet, keeps NodeType == 'host', and groups trays into NVL72
racks by stripping the trailing -<U> field from the node name. Fails loudly if
any rack does not have exactly EXPECTED_TRAYS members, because a silently short
rack becomes a silently wrong --nodelist.
"""
import sys
from collections import defaultdict
from openpyxl import load_workbook

EXPECTED_TRAYS = 18

def main(path):
    ws = load_workbook(path, read_only=True, data_only=True)["Nodes"]
    hdr = None
    racks, label = defaultdict(list), {}
    for row in ws.iter_rows(values_only=True):
        if not row:
            continue
        if hdr is None:
            if row[0] == "FabricId":
                hdr = {name: i for i, name in enumerate(row) if name}
            continue
        get = lambda k: row[hdr[k]] if k in hdr and hdr[k] < len(row) else None
        if get("NodeType") != "host":
            continue
        name = str(get("NodeName"))
        rack = name.rsplit("-", 1)[0]
        tray = get("TrayIndex")
        racks[rack].append((int(tray) if tray is not None else 999, name))
        label[rack] = str(get("Rack"))

    bad = {r: len(v) for r, v in racks.items() if len(v) != EXPECTED_TRAYS}
    if bad:
        sys.exit(f"tray count != {EXPECTED_TRAYS} for: {bad}")

    print("# rack_id  physical_rack  node1 node2 ... nodeN")
    print(f"# Generated from {path} (Nodes sheet, NodeType=host).")
    print("# rack_id = node name minus the trailing -<U>; one GB300 NVL72 domain.")
    print("# NOTE: tray U-numbers are NOT contiguous - never assume a -[01-18] suffix.")
    for rack in sorted(racks, key=lambda s: tuple(s.split("-")[1:3])):
        nodes = " ".join(n for _, n in sorted(racks[rack]))
        print(f"{rack} {label[rack]} {nodes}")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
