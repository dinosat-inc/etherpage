#!/usr/bin/env python3
# Sums a walk statistics file, which has one line per run: "<n> <label>, <n> <label>, ..."
# Usage: python3 tools/sum_stats.py logs/profile-inv-stats.txt
import re, sys
tot = {}
order = []
lines = 0
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    lines += 1
    for n, label in re.findall(r'(\d+) ([a-zA-Z][^,()\d]*)', line):
        label = label.strip()
        if label not in tot:
            tot[label] = 0
            order.append(label)
        tot[label] += int(n)
print(f"{lines} lines")
for k in order:
    print(f"{tot[k]} {k}")
