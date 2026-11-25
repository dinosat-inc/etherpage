#!/usr/bin/env python3
# The gates live in gates/gates.py. This runs it with the same arguments.
# Usage: python3 tools/gates.py [arguments of gates/gates.py]
import os, subprocess, sys

here = os.path.dirname(os.path.abspath(__file__))
sys.exit(subprocess.call([sys.executable, os.path.join(here, '..', 'gates', 'gates.py')] + sys.argv[1:]))
