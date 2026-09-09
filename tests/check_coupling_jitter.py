#!/usr/bin/env python3
"""How much timing error does the coupling itself add?

The testbench squares the VCO output by reading v(aout) every coupling tick
and comparing it to a threshold. That quantises every VCO edge onto the
tick grid, and the rawfile holds where the crossing REALLY was -- at
ngspice's own timepoints -- so the artifact is directly measurable rather
than a matter of opinion:

    error = (digital edge time) - (interpolated analog crossing time)

For a PLL this is the number that decides what the setup may be used for.
Lock, frequency and settling survive quantisation; jitter and phase noise
do not. Anyone who sees a polled `ams_get` plus a threshold will ask about
this within a minute, and the answer should be a measurement.

WHAT TO EXPECT. Uniform quantisation over one tick T gives a LAG of about
T/2 and a JITTER of about T/sqrt(12) = 0.289*T. The checks below require
the measurement to match that, because agreement means the mechanism is
understood -- a number outside it would mean something else is going on
(the analog running ahead, an edge missed entirely, a threshold being
crossed twice) and those have very different consequences.

Run ./build.sh pll first; this reads the waveforms it leaves behind.
"""
from __future__ import annotations

import re
import struct
import sys
from bisect import bisect_left
from pathlib import Path

VTH = 1.65          # the threshold the testbench squares aout at
TICK_PS = 100.0     # the coupling tick, from tb_pll.sv (STEP = 100 @ 1ps)
ASTEP_PS = 20.0     # the analog step granted in ams_start(20.0e-12, ...)
PERIOD_PS = 2515.7  # one VCO period at the measured 397.5 MHz
REF_PS = 1e5        # the 10 MHz reference period
NDIV = 40


def analog_crossings(path: Path, node="v(aout)", vth=VTH):
    """Interpolated upward crossing times, in ps.

    Interpolated, not snapped to the nearest timepoint: ngspice's step is
    adaptive and can be coarser than the coupling tick, so snapping would
    add an error of its own and confuse it with the one being measured.
    """
    blob = path.read_bytes()
    cut = blob.index(b"Binary:\n") + len(b"Binary:\n")
    head = blob[:cut].decode("latin-1")
    nvars = int(re.search(r"No\. Variables:\s*(\d+)", head).group(1))
    npts = int(re.search(r"No\. Points:\s*(\d+)", head).group(1))
    names = re.findall(r"^\s*\d+\s+(\S+)\s+\S+", head, re.M)
    vals = struct.unpack_from("<%dd" % (nvars * npts), blob, cut)
    it, ia = names.index("time"), names.index(node)

    out, pt, pv = [], None, None
    for k in range(npts):
        t, v = vals[k * nvars + it], vals[k * nvars + ia]
        if pv is not None and pv <= vth < v:
            f = (vth - pv) / (v - pv)
            out.append((pt + f * (t - pt)) * 1e12)
        pt, pv = t, v
    return out


def digital_edges(path: Path, name="vco_clk"):
    """Rising edge times, in ps, from a 1 ps-timescale VCD."""
    txt = path.read_text(errors="replace")
    m = re.search(r"\$timescale\s+(\d+)\s*([munpf]?s)\s*\$end", txt)
    scale = {"s": 1e12, "ms": 1e9, "us": 1e6, "ns": 1e3,
             "ps": 1.0, "fs": 1e-3}[m.group(2)] * int(m.group(1))
    sym = re.search(r"\$var\s+\w+\s+1\s+(\S+)\s+" + re.escape(name)
                    + r"\s+\$end", txt).group(1)
    body = txt[txt.index("$enddefinitions"):]
    out, now = [], 0
    for line in body.splitlines():
        s = line.strip()
        if s[:1] == "#":
            now = int(s[1:])
        elif s == "1" + sym:
            out.append(now * scale)
    return out


def main() -> int:
    here = Path(__file__).resolve().parent.parent / "examples" / "pll"
    raw, vcd = here / "pll_analog.raw", here / "pll_digital.vcd"
    for p in (raw, vcd):
        if not p.exists():
            print("SKIP: %s not present -- run ./build.sh pll first" % p.name)
            return 0

    ana, dig = analog_crossings(raw), digital_edges(vcd)

    # Match each digital edge to the NEAREST analog crossing, not the i-th.
    # Pairing by index gave a mean of -2443 ps -- one whole VCO period,
    # because the two lists start one edge apart. That is a bug in the
    # comparison and it looks exactly like a systematic delay in the
    # coupling, which is the kind of thing that gets reported as a finding.
    errs = []
    for d in dig:
        i = bisect_left(ana, d)
        cand = [ana[j] for j in (i - 1, i) if 0 <= j < len(ana)]
        if not cand:
            continue
        a = min(cand, key=lambda x: abs(d - x))
        if abs(d - a) < PERIOD_PS * 0.6:
            errs.append(d - a)
    if len(errs) < 100:
        print("FAIL: only %d edges matched; the two runs do not line up"
              % len(errs))
        return 1

    errs.sort()
    n = len(errs)
    mean = sum(errs) / n
    sd = (sum((e - mean) ** 2 for e in errs) / n) ** 0.5

    print("matched edges : %d of %d digital, %d analog" % (n, len(dig), len(ana)))
    print()
    print("digital edge minus true analog crossing")
    print("  min    %7.1f ps" % errs[0])
    print("  median %7.1f ps" % errs[n // 2])
    print("  max    %7.1f ps" % errs[-1])
    print("  mean   %7.1f ps   <- sampling LAG" % mean)
    print("  stdev  %7.1f ps   <- sampling JITTER" % sd)
    print("  spread %7.1f ps   (coupling tick %.0f ps)"
          % (errs[-1] - errs[0], TICK_PS))
    print()
    print("  per VCO edge          : %.2f deg rms" % (360 * sd / PERIOD_PS))
    print("  on the /%d feedback edge: %.4f %% of the %.0f ns reference"
          % (NDIV, 100 * sd / REF_PS, REF_PS / 1000))

    fails = []

    def check(label, cond, detail=""):
        print("%-56s %s" % (label, "ok" if cond else "FAIL"))
        if not cond:
            fails.append("%s %s" % (label, detail))

    print()
    check("every digital edge matched an analog crossing",
          abs(len(dig) - len(ana)) <= 1 and n >= len(ana) - 1,
          "%d dig, %d ana, %d matched" % (len(dig), len(ana), n))
    # A digital edge can only come at or AFTER the real crossing: the
    # threshold is tested at tick boundaries. A negative error would mean
    # the digital side saw an edge before the analog produced it.
    check("no edge is detected before it happened", errs[0] >= -1.0,
          "min %.1f ps" % errs[0])
    # The bound is one tick PLUS one analog step, not one tick. ams_get
    # returns ngspice's most recently computed value, which can be up to one
    # of ITS steps stale, so a crossing that happens just after the analog
    # solved a point is not visible until the tick after next. Measured max
    # is 119.8 ps against a 100 ps tick and a 20 ps granted step -- which is
    # exactly 100 + 20, and is the reason this bound is not simply the tick.
    check("no edge is late by more than one tick plus one analog step",
          errs[-1] <= (TICK_PS + ASTEP_PS) * 1.05,
          "max %.1f ps vs %.1f bound" % (errs[-1], TICK_PS + ASTEP_PS))
    check("lag is about half a tick, as uniform quantisation gives",
          abs(mean - TICK_PS / 2) < TICK_PS * 0.25,
          "%.1f ps vs %.1f expected" % (mean, TICK_PS / 2))
    check("jitter is about tick/sqrt(12), likewise",
          abs(sd - TICK_PS / 12 ** 0.5) < TICK_PS * 0.15,
          "%.1f ps vs %.1f expected" % (sd, TICK_PS / 12 ** 0.5))

    print()
    if fails:
        print("VERDICT: FAIL")
        for f in fails:
            print("  -", f)
        return 1
    print("VERDICT: PASS")
    print()
    print("So: lock, frequency and settling are unaffected (%.3f%% of the"
          % (100 * sd / REF_PS))
    print("reference period after the divider), and this setup CANNOT be used")
    print("to measure jitter or phase noise -- it injects %.0f ps rms of its own."
          % sd)
    return 0


if __name__ == "__main__":
    sys.exit(main())
