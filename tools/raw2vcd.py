#!/usr/bin/env python3
"""Put the analog and the digital waveform in ONE file, on one timeline.

    raw2vcd.py analog.raw                       -> analog.vcd
    raw2vcd.py analog.raw --merge digital.vcd   -> combined.vcd

An ngspice rawfile and a VCD cannot be opened together by any viewer worth
using, so the two halves of a co-simulation end up in separate windows with
separate cursors. This converts the rawfile and, given the digital dump,
interleaves both into a single VCD that GTKWave or Surfer shows as one
trace set.

NOTHING IS RESAMPLED. VCD timestamps are arbitrary integers, not a grid, so
each of ngspice's own timepoints becomes a VCD timestamp carrying the node
voltage as a `real`. The solver picks those timepoints by its own error
control -- they are neither uniform nor the coupling ticks -- and forcing
them onto the digital grid is the step that would turn a real waveform into
a plausible-looking one. The output timescale is 1 fs so that no analog
timepoint has to round onto another.
"""
from __future__ import annotations

import argparse
import re
import struct
import sys
from pathlib import Path

# VCD identifier codes: printable ASCII 33..126. Two disjoint runs, so an
# analog signal can never collide with a symbol the digital dump already
# used -- a collision would silently merge two traces into one.
_CODES = [chr(c) for c in range(33, 127)]


def _ids(start: int):
    """An endless supply of VCD identifiers, beginning at `start`."""
    n = start
    while True:
        s, k = "", n
        while True:
            s = _CODES[k % len(_CODES)] + s
            k = k // len(_CODES) - 1
            if k < 0:
                break
        yield s
        n += 1


def read_raw(path: Path):
    """(names, points) from a binary ngspice rawfile.

    points is a list of tuples, one per timepoint, in variable order.
    """
    blob = path.read_bytes()
    marker = b"Binary:\n"
    if marker not in blob:
        raise SystemExit("%s is not a binary rawfile (no 'Binary:' marker). "
                         "ngspice writes ASCII with `write` when `set "
                         "filetype=ascii`; this reads the binary form." % path)
    cut = blob.index(marker) + len(marker)
    head = blob[:cut].decode("latin-1")

    nvars = int(re.search(r"No\. Variables:\s*(\d+)", head).group(1))
    npts = int(re.search(r"No\. Points:\s*(\d+)", head).group(1))
    names = re.findall(r"^\s*\d+\s+(\S+)\s+\S+", head, re.M)
    if len(names) != nvars:
        raise SystemExit("rawfile declares %d variables but names %d"
                         % (nvars, len(names)))
    if "complex" in head.lower().split("flags:")[1].split("\n")[0]:
        raise SystemExit("complex rawfile (an AC sweep?); this handles the "
                         "real-valued transient form")

    vals = struct.unpack_from("<%dd" % (nvars * npts), blob, cut)
    pts = [vals[i * nvars:(i + 1) * nvars] for i in range(npts)]
    return names, pts


def read_vcd(path: Path):
    """(header_lines, timescale_fs, events) from a VCD.

    events is [(t_fs, [line, ...]), ...] with the value-change lines exactly
    as written, so nothing about the digital dump is reinterpreted.
    """
    text = path.read_text(errors="replace")
    m = re.search(r"\$timescale\s+(\d+)\s*([munpf]?s)\s*\$end", text)
    if not m:
        raise SystemExit("no $timescale in %s" % path)
    unit = {"s": 1e15, "ms": 1e12, "us": 1e9, "ns": 1e6,
            "ps": 1e3, "fs": 1.0}[m.group(2)]
    ts_fs = int(m.group(1)) * unit

    end = text.index("$enddefinitions")
    header = text[:end]
    body = text[text.index("$end", end) + 4:]

    events, cur, buf = [], None, []
    for line in body.splitlines():
        s = line.strip()
        if not s:
            continue
        if s[0] == "#":
            if cur is not None:
                events.append((cur, buf))
            cur, buf = int(round(int(s[1:]) * ts_fs)), []
        elif cur is not None:
            buf.append(s)
    if cur is not None:
        events.append((cur, buf))
    return header, events


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("raw", type=Path, help="ngspice binary rawfile")
    ap.add_argument("--merge", type=Path,
                    help="a digital VCD to interleave with the analog")
    ap.add_argument("-o", "--out", type=Path,
                    help="output VCD (default: alongside the input)")
    a = ap.parse_args(argv)

    names, pts = read_raw(a.raw)
    if not names or names[0].lower() != "time":
        raise SystemExit("first rawfile variable is %r, expected time"
                         % (names[0] if names else None))
    analog = names[1:]
    out = a.out or (a.raw.with_suffix(".vcd") if not a.merge
                    else a.raw.with_name("combined.vcd"))

    dig_header, dig_events = (read_vcd(a.merge) if a.merge else ("", []))
    # Start analog identifiers past anything the digital dump could have
    # used, rather than hoping they do not overlap.
    used = set(re.findall(r"^\$var\s+\S+\s+\d+\s+(\S+)\s", dig_header, re.M))
    gen = _ids(len(used) + 8)
    sym = {}
    for nm in analog:
        s = next(gen)
        while s in used:
            s = next(gen)
        sym[nm] = s

    # Analog events, at ngspice's own timepoints.
    ana_events = []
    for row in pts:
        t_fs = int(round(row[0] * 1e15))
        ana_events.append((t_fs, ["r%.6g %s" % (row[i + 1], sym[nm])
                                  for i, nm in enumerate(analog)]))

    with out.open("w") as f:
        f.write("$date co-simulation: %s%s $end\n"
                % (a.raw.name, " + " + a.merge.name if a.merge else ""))
        f.write("$version ams-cosim raw2vcd $end\n")
        f.write("$timescale 1fs $end\n")
        if dig_header:
            # The digital declarations verbatim, so hierarchy and names are
            # exactly what the simulator wrote.
            body = dig_header[dig_header.index("$timescale"):]
            body = re.sub(r"\$timescale.*?\$end", "", body, count=1, flags=re.S)
            f.write(body.strip() + "\n")
        f.write("$scope module analog $end\n")
        for nm in analog:
            f.write("$var real 64 %s %s $end\n" % (sym[nm], nm))
        f.write("$upscope $end\n$enddefinitions $end\n")

        merged = {}
        for t, lines in ana_events + dig_events:
            merged.setdefault(t, []).extend(lines)
        for t in sorted(merged):
            f.write("#%d\n" % t)
            for line in merged[t]:
                f.write(line + "\n")

    print("%s: %d analog points x %d signals%s -> %s"
          % (a.raw.name, len(pts), len(analog),
             ", %d digital timestamps" % len(dig_events) if dig_events else "",
             out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
