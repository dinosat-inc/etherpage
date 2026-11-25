#!/usr/bin/env python3
# Prints one table of every Halmos run in logs/halmos, with result, contract, proof, paths, Halmos
# time, wall time, log and notes, and the number of runs of each result. Then gives, for each tier
# file and umbrella.txt, the number of proofs that have no result yet, naming them when there are 40
# or fewer, and lists any proof function in the sources that no file lists.
# Usage: python3 tools/proofs/collect.py
import glob, os, re

root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
rows, done = [], set()
for f in sorted(glob.glob(os.path.join(root, 'logs', 'halmos', '*.raw'))):
    s = re.sub(r'\x1b\[[0-9;]*m', '', open(f, errors='replace').read())
    m = re.search(r'start (\S+ \S+) (\w+) (\w+) alarm (\d+)s', s.split('\n', 1)[0])
    if not m:
        continue
    contract, fn = m.group(2), m.group(3)
    r = re.search(r'\[(PASS|FAIL|TIMEOUT|ERROR)\] ' + fn + r'\(.*?\(paths: (\d+), time: ([0-9.]+)s', s)
    w = re.search(r'exit (\d+) wall (\d+)s', s)
    if r:
        res, paths, t = r.group(1), r.group(2), r.group(3)
    elif w and w.group(1) == '142':
        res, paths, t = 'TIMEOUT(alarm)', '-', '-'
    elif w:
        res, paths, t = 'NO-RESULT', '-', '-'
    else:
        res, paths, t = 'RUNNING', '-', '-'
    notes = []
    if 'loop unrolling bound' in s:
        notes.append('loop bound hit')
    if 'all paths have been reverted' in s:
        notes.append('all paths reverted')
    if res != 'RUNNING':
        done.add((contract, fn))
    rows.append((res, contract, fn, paths, t, w.group(2) if w else '-', os.path.relpath(f, root), ', '.join(notes)))
for row in rows:
    print(' | '.join(row))
counts = {}
for row in rows:
    counts[row[0]] = counts.get(row[0], 0) + 1
print('totals:', ', '.join(f'{k} {v}' for k, v in sorted(counts.items())) or 'no runs')

listed = set()
for q in ('tier1.txt', 'tier2.txt', 'tier3.txt', 'tier4.txt', 'umbrella.txt'):
    missing = []
    for line in open(os.path.join(root, 'tools', 'proofs', q)):
        parts = line.split()
        if not parts or parts[0].startswith('#'):
            continue
        listed.add((parts[1], parts[2]))
        if (parts[1], parts[2]) not in done:
            missing.append(f'{parts[1]}.{parts[2]}')
    print(f'{q}: {len(missing)} without a result' + (': ' + ' '.join(missing) if missing and len(missing) <= 40 else ''))

found = set()
for p in glob.glob(os.path.join(root, 'proofs', '**', '*.sol'), recursive=True):
    for part in re.split(r'^(?=contract \w+)', open(p).read(), flags=re.M):
        m = re.match(r'contract (\w+)', part)
        if m and m.group(1).endswith('Test'):
            for fm in re.finditer(r'function ((?:test_)?check_\w+)\s*\(', part):
                found.add((m.group(1), fm.group(1)))
sym = open(os.path.join(root, 'test', 'unit', 'minter', 'MinterSymbolic.t.sol')).read()
for f in re.findall(r'function (test_check_\w+)\s*\(', sym):
    found.add(('MinterSymbolicProofsTest', f))
unlisted = sorted(found - listed)
print(f'proof functions in no queue file: {len(unlisted)}' + (': ' + ' '.join(f'{c}.{f}' for c, f in unlisted) if unlisted else ''))
