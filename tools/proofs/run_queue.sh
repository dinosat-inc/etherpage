#!/bin/zsh
# Builds the proofs once, then runs every line of a queue file, N proofs at a time.
# A line is <tag> <Contract> <function> <seconds> [loop bound]; empty lines and lines starting with # are skipped.
# Usage: tools/proofs/run_queue.sh <queue file> [N]
cd "${0:A:h}/../.."
Q=$1; N=${2:-2}
mkdir -p logs/halmos
FOUNDRY_PROFILE=proofs forge build > logs/halmos/build.txt 2>&1 || { echo "proofs build failed, see logs/halmos/build.txt"; exit 1; }
grep -v '^#' $Q | grep -v '^$' | xargs -P $N -L 1 zsh tools/proofs/run_one.sh
rmdir tmp-halmos 2>/dev/null
echo "queue done: $Q"
