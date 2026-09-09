#!/bin/bash
# The RC lockstep check, as a gate.
#
# The RC is the case worth automating because its answer is ARITHMETIC:
# tau = 1 us, the digital side toggles the drive every 5 tau, so the
# capacitor must reach within e^-5 = 0.67% of the rail before each flip. A
# coupling that is not actually in step -- ngspice free-running, or the
# digital side reading a stale vector -- gives a visibly different number,
# not a slightly noisy one.
#
# The PLL is not run here: 20 us of transistor-level loop is ~2.5 minutes,
# which is a reference you generate deliberately, not a gate you run on
# every change.
#
# Exit status is non-zero if anything failed, and the last line says the
# verdict in words -- an exit status is only readable by whoever launched
# the process, and capturing it through nested shells is easy to get wrong
# in a way that reports success.
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE"

fail=0
note() { printf '%-52s %s\n' "$1" "$2"; }
check() { if [ "$2" = 1 ]; then note "$1" ok; else note "$1" FAIL; fail=1; fi; }

out=$(./build.sh rc 2>&1) || true

echo "$out" | grep -E '^AMS' || true
echo

case "$out" in
  *"no libngspice.so"*|*"no executable xezim"*)
    echo "SKIP: toolchain not present"
    echo "$out" | sed 's/^/  /'
    echo "VERDICT: SKIP"
    exit 0 ;;
esac

case "$out" in *AMS-OK*) check "lockstep held for the whole run" 1 ;;
               *)        check "lockstep held for the whole run" 0 ;; esac
case "$out" in *stalled*) check "no analog stall" 0 ;;
               *)         check "no analog stall" 1 ;; esac
case "$out" in *aborted*) check "no ngspice abort" 0 ;;
               *)         check "no ngspice abort" 1 ;; esac

# The physics, not just the plumbing.
#
# COUNT THE SAMPLES FIRST. "no sample was bad" is trivially true when there
# are no samples, and that is not hypothetical: renaming the deck without
# updating the testbench produced AMS-FAIL open, zero readings, and two
# green physics checks underneath the failure.
n_hi=$(echo "$out" | grep -c 'drive=1' || true)
n_lo=$(echo "$out" | grep -c 'drive=0' || true)
check "the run produced charged samples at all"    "$([ "$n_hi" -ge 3 ] && echo 1 || echo 0)"
check "the run produced discharged samples at all" "$([ "$n_lo" -ge 3 ] && echo 1 || echo 0)"

bad_hi=$(echo "$out" | grep 'drive=1' | sed 's/.*v=//' \
         | awk '$1 <= 0.98' | wc -l)
bad_lo=$(echo "$out" | grep 'drive=0' | sed 's/.*v=//' \
         | awk 'NR > 1 && $1 >= 0.02' | wc -l)
check "charged samples reach 5 tau (>0.98)"      "$([ "$bad_hi" -eq 0 ] && echo 1 || echo 0)"
check "discharged samples fall to 5 tau (<0.02)" "$([ "$bad_lo" -eq 0 ] && echo 1 || echo 0)"

echo
if [ "$fail" -ne 0 ]; then
  echo "VERDICT: FAIL"
  exit 1
fi
echo "VERDICT: PASS"
