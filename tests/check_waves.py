#!/usr/bin/env python3
"""Are the waveform files faithful to the run, and to each other?

A file that exists is not a file that is right, and a waveform is the
easiest thing in the world to look at and believe. So this checks numbers:

  * the ANALOG rawfile and the DIGITAL vcd must report the same number of
    VCO edges. They are produced by different simulators on different time
    grids, so agreement is real evidence that the coupling held -- if the
    two had drifted apart, this is where it would show.
  * the MERGED vcd must reproduce both counts exactly, or the conversion
    dropped or duplicated events.
  * no analog signal may share a VCD identifier with a digital one, which
    would silently draw two traces as one.

Note that a VCD legitimately REUSES an identifier across names: one code
per unique signal, declared under every name it has. `vco_clk` and
`u_div.clk_in` are the same net and correctly share a code. An earlier
version of this file counted that as a collision and failed a correct
merge, so the check is specifically analog-versus-digital.
"""
from __future__ import annotations

import re
import struct
import sys
from pathlib import Path

VTH = 1.65          # the threshold the testbench squares aout at


def raw_crossings(path: Path, node: str = "v(aout)", vth: float = VTH) -> int:
    blob = path.read_bytes()
    cut = blob.index(b"Binary:\n") + len(b"Binary:\n")
    head = blob[:cut].decode("latin-1")
    nvars = int(re.search(r"No\. Variables:\s*(\d+)", head).group(1))
    npts = int(re.search(r"No\. Points:\s*(\d+)", head).group(1))
    names = re.findall(r"^\s*\d+\s+(\S+)\s+\S+", head, re.M)
    vals = struct.unpack_from("<%dd" % (nvars * npts), blob, cut)
    idx = names.index(node)
    prev, n = None, 0
    for k in range(npts):
        v = vals[k * nvars + idx]
        if prev is not None and prev <= vth < v:
            n += 1
        prev = v
    return n


def _split(path: Path):
    txt = path.read_text(errors="replace")
    end = txt.index("$enddefinitions")
    return txt[:end], txt[txt.index("$end", end) + 4:]


def vcd_rises(path: Path, name: str) -> int:
    hdr, body = _split(path)
    m = re.search(r"\$var\s+\w+\s+1\s+(\S+)\s+" + re.escape(name) + r"\s+\$end",
                  hdr)
    if not m:
        raise SystemExit("no 1-bit %s in %s" % (name, path))
    return len(re.findall(r"^1" + re.escape(m.group(1)) + r"\s*$", body, re.M))


def vcd_real_crossings(path: Path, name: str, vth: float = VTH) -> int:
    hdr, body = _split(path)
    m = re.search(r"\$var\s+real\s+\d+\s+(\S+)\s+" + re.escape(name)
                  + r"\s+\$end", hdr)
    if not m:
        raise SystemExit("no real %s in %s" % (name, path))
    sym = m.group(1)
    prev, n = None, 0
    for mm in re.finditer(r"^r([-\d.eE+]+) " + re.escape(sym) + r"\s*$",
                          body, re.M):
        v = float(mm.group(1))
        if prev is not None and prev <= vth < v:
            n += 1
        prev = v
    return n


def analog_digital_overlap(path: Path):
    """Identifiers used by BOTH an analog and a digital signal."""
    hdr, _ = _split(path)
    ana, dig, in_ana = set(), set(), False
    for line in hdr.splitlines():
        s = line.strip()
        if "scope module analog" in s:
            in_ana = True
            continue
        if in_ana and "upscope" in s:
            in_ana = False
            continue
        m = re.match(r"\$var\s+\S+\s+\d+\s+(\S+)\s", s)
        if m:
            (ana if in_ana else dig).add(m.group(1))
    return sorted(ana & dig)


def main() -> int:
    here = Path(__file__).resolve().parent.parent / "examples" / "pll"
    raw = here / "pll_analog.raw"
    dig = here / "pll_digital.vcd"
    comb = here / "pll_combined.vcd"
    for p in (raw, dig, comb):
        if not p.exists():
            print("SKIP: %s not present -- run ./build.sh pll first" % p.name)
            return 0

    fails = []

    def check(label, cond, detail=""):
        print("%-54s %s" % (label, "ok" if cond else "FAIL"))
        if not cond:
            fails.append("%s %s" % (label, detail))

    n_raw = raw_crossings(raw)
    n_dig = vcd_rises(dig, "vco_clk")
    print("analog rawfile  : %d crossings of %.2f V on v(aout)" % (n_raw, VTH))
    print("digital vcd     : %d rising edges on vco_clk" % n_dig)
    # One apart is the run ending mid-cycle; more means they drifted.
    check("the two simulators agree on the VCO edge count",
          abs(n_raw - n_dig) <= 1, "%d vs %d" % (n_raw, n_dig))

    n_ca = vcd_real_crossings(comb, "v(aout)")
    n_cd = vcd_rises(comb, "vco_clk")
    print("merged vcd      : %d analog crossings, %d digital rises"
          % (n_ca, n_cd))
    check("the merge kept every analog point", n_ca == n_raw,
          "%d vs %d" % (n_ca, n_raw))
    check("the merge kept every digital edge", n_cd == n_dig,
          "%d vs %d" % (n_cd, n_dig))

    over = analog_digital_overlap(comb)
    check("no analog signal shares an identifier with a digital one",
          not over, str(over))

    print()
    if fails:
        print("VERDICT: FAIL")
        for f in fails:
            print("  -", f)
        return 1
    print("VERDICT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
