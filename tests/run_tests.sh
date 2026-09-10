#!/bin/bash
# Both examples, as a gate.
#
#   ./tests/run_tests.sh          RC and PLL      (~20 s)
#   ./tests/run_tests.sh rc       just the RC     (~1 s)
#
# THE RC CHECKS THE PLUMBING. Its answer is arithmetic: tau = 1 us, the
# digital side toggles the drive every 5 tau, so the capacitor must reach
# within e^-5 = 0.67% of the rail before each flip. A coupling that is not
# actually in step -- ngspice free-running, or the digital side reading a
# stale vector -- gives a visibly different number, not a noisy one.
#
# THE PLL CHECKS THE OUTCOME, which is a different question. Every part of
# the plumbing can work while the loop is wired backwards: it still runs,
# still prints, and still looks like a PLL. What separates the two is
# whether the output settles at N x the reference, so that is what the
# testbench asserts, along with the VCO actually oscillating and the
# control voltage not having run to a rail.
#
# The PLL example runs 3 us, not the 20 us of the figure in the README, so
# this stays a gate rather than a coffee break. 3 us is mid-settle -- it
# lands near 397.5 MHz against 400 -- so the tolerance is 2%, which still
# separates a working loop from a broken one by a wide margin.
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

# A missing toolchain is a SKIP, not a failure -- but it must be visible as
# one. These patterns track build.sh's own messages; if they drift, a broken
# toolchain reports as a test failure instead, which is noisy but not silent.
#
# CI passes STRICT=1 so the skip becomes a failure there: a green tick that
# only means "ngspice was not installed" is worse than no CI at all.
case "$out" in
  *"no shared libngspice found"*|*"no executable xezim"*)
    if [ "${STRICT:-0}" = 1 ]; then
      echo "FAIL: toolchain not present, and STRICT=1"
      echo "$out" | sed 's/^/  /'
      echo "VERDICT: FAIL"
      exit 1
    fi
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

if [ "${1:-}" = "rc" ]; then
  echo
  [ "$fail" -eq 0 ] && { echo "VERDICT: PASS"; exit 0; }
  echo "VERDICT: FAIL"; exit 1
fi

echo
echo "== PLL =="
pout=$(./build.sh pll 2>&1) || true
echo "$pout" | grep -E '^PLL (f_vco|-)|^PLL-' || true
echo

# The testbench reaches the verdict, not this script -- it is the thing
# holding the frequency, the edge count and the control voltage, and a
# grep for a number here would be a second, weaker copy of that judgement.
case "$pout" in *PLL-OK*)   check "the loop locks at N x the reference" 1 ;;
                *PLL-FAIL*) check "the loop locks at N x the reference" 0 ;;
                *)          check "the PLL example ran to a verdict" 0 ;; esac
case "$pout" in *stalled*)  check "no analog stall" 0 ;;
                *)          check "no analog stall" 1 ;; esac
case "$pout" in *aborted*)  check "no ngspice abort" 0 ;;
                *)          check "no ngspice abort" 1 ;; esac

# The waveforms, checked against numbers rather than looked at. The two
# simulators counting the same VCO edges on their own time grids is real
# evidence the coupling held; a drift would show here and nowhere else.
echo
echo "== waveforms =="
if python3 tests/check_waves.py; then :; else fail=1; fi

# What the coupling itself costs in edge timing. The first question anyone
# asks about a polled analog-to-digital crossing, answered with a number
# and bounded rather than left to be discovered by the audience.
echo
echo "== coupling jitter =="
if python3 tests/check_coupling_jitter.py; then :; else fail=1; fi

echo
if [ "$fail" -ne 0 ]; then
  # Show what the examples actually printed. Everything above is a grep of
  # this text, so on a green run it is noise -- but on a red one it is the
  # only evidence there is, and discarding it makes a CI failure unreadable
  # by whoever has to fix it. That is not hypothetical: the first CI run
  # reported five FAILs and zero samples with no indication of why, because
  # this output was captured and dropped.
  echo "=== captured output: build.sh rc ==="
  printf '%s\n' "$out" | sed 's/^/  /'
  if [ -n "${pout:-}" ]; then
    echo "=== captured output: build.sh pll ==="
    printf '%s\n' "$pout" | sed 's/^/  /'
  fi
  echo
  echo "VERDICT: FAIL"
  exit 1
fi
echo "VERDICT: PASS"
