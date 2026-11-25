#!/usr/bin/env python3
# Writes the files the gates compare against from the current build: for each contract its method
# identifiers, ABI events and errors, storage layout without AST ids, and the error and event
# declarations of its source. Run it only on the commit to sign off, and review every changed file:
# a change here is a change of the public surface or the storage of an immutable contract.
# Usage: python3 gates/record.py
import json, os, sys

# gates.py and deployed.py are imported without writing a bytecode cache
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gates as g

for c in g.CONTRACTS:
    for field, fname in (('methodIdentifiers', 'methodIdentifiers'), ('events', 'events'), ('errors', 'errors')):
        data = g.inspect(c, field)
        with open(os.path.join(g.gates_dir, f'{c}.{fname}.json'), 'w') as f:
            json.dump(dict(sorted(data.items())), f, indent=2)
            f.write('\n')
    with open(os.path.join(g.gates_dir, f'{c}.storage-layout.json'), 'w') as f:
        json.dump(g.norm_layout(g.inspect(c, 'storageLayout')), f, indent=2)
        f.write('\n')
    with open(os.path.join(g.gates_dir, f'{c}.declarations.txt'), 'w') as f:
        f.write(''.join(d + '\n' for d in g.declarations(g.strip_comments(g.raw[c]))))
    print(f"recorded {c}")
