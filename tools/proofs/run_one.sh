#!/bin/zsh
# Runs one Halmos proof under a wall clock limit and appends its result to logs/halmos/summary-<tag>.txt.
# The solver scratch goes to tmp-halmos/<tag>-<function> and is deleted when the run ends. On the time
# limit, or when the runner is stopped, the whole process group is killed so no solver is left behind.
# Needs the proofs build: FOUNDRY_PROFILE=proofs forge build
# Usage: tools/proofs/run_one.sh <tag> <Contract> <function> <seconds> [loop bound]
# ST sets the solver threads (default 2).
cd "${0:A:h}/../.."
TAG=$1; C=$2; F=$3; T=$4; LP=${5:-4}
SCRATCH=tmp-halmos/$TAG-$F
mkdir -p $SCRATCH logs/halmos
trap 'rm -rf "$SCRATCH"' EXIT
export TMPDIR="$PWD/$SCRATCH"
L=logs/halmos/$TAG-$F
S=$(date +%s)
echo "start $(date '+%F %T') $C $F alarm ${T}s" > $L.raw
FOUNDRY_PROFILE=proofs perl -e '
  my $t = shift;
  my $pid = fork();
  if ($pid == 0) { setpgrp(0, 0); exec @ARGV or exit 127; }
  my $stop = sub { kill "KILL", -$pid; waitpid($pid, 0); exit $_[0]; };
  $SIG{ALRM} = sub { $stop->(142) };
  $SIG{INT} = $SIG{TERM} = sub { $stop->(143) };
  alarm $t;
  waitpid($pid, 0);
  my $rc = $? >> 8;
  kill "KILL", -$pid;
  exit $rc;
' $T halmos --contract $C --match-test "^${F}\(" --forge-build-out out-proofs --loop $LP \
  --storage-layout generic --solver-timeout-assertion 300s --solver-threads ${ST:-2} >> $L.raw 2>&1
X=$?
E=$(date +%s)
echo "exit $X wall $((E-S))s end $(date '+%F %T')" >> $L.raw
R=$(grep -aoE "\[(PASS|FAIL|TIMEOUT|ERROR)\]" $L.raw | head -1)
[[ -z "$R" ]] && { [[ $X -eq 142 ]] && R="[ALARM-TIMEOUT]" || R="[NO-RESULT exit $X]"; }
echo "$R $C $F wall $((E-S))s" >> logs/halmos/summary-$TAG.txt
