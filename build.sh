#!/bin/bash
# Build the bridge, and optionally run an example.
#
#   ./build.sh          build src/ams_bridge.c -> ams_bridge.so
#   ./build.sh rc       build, then the RC lockstep check   (~1 s)
#   ./build.sh pll      build, then the PLL golden          (~2.5 min)
#
# Paths come from the environment, so this is not tied to one machine:
#
#   NGSPICE_SRC   an ngspice source tree configured --with-ngshared
#   XEZIM         the xezim BINARY (not the checkout directory)
#
# NGSPICE_SRC must be a SHARED build. The ordinary ngspice binary will not
# do: this links libngspice.so, which exists only if the tree was
# configured --with-ngshared. Configure a SECOND copy of the source --
# ngspice refuses to configure a tree that is already configured, and
# reusing the one that built the CLI destroys it.
set -e

NGSPICE_SRC=${NGSPICE_SRC:-$HOME/ngspice-46-shared}
XEZIM=${XEZIM:-$HOME/xezim/target/release/xezim}
NGLIB="$NGSPICE_SRC/src/.libs"
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

if [ ! -f "$NGLIB/libngspice.so" ]; then
  echo "no libngspice.so under $NGLIB" >&2
  echo "build one with:" >&2
  echo "  cp -a ngspice-46 ngspice-46-shared && cd ngspice-46-shared" >&2
  echo "  make distclean" >&2
  echo "  ./configure --with-ngshared --enable-xspice --disable-debug" >&2
  echo "  make -j\$(nproc)" >&2
  exit 1
fi
if [ ! -x "$XEZIM" ]; then
  echo "no executable xezim at $XEZIM" >&2
  echo "  XEZIM must name the BINARY, not the checkout directory" >&2
  exit 1
fi

echo "== ams_bridge.so =="
gcc -shared -fPIC -O2 -Wall \
    -I"$NGSPICE_SRC/src/include/ngspice" \
    -I"$NGSPICE_SRC/src/include" \
    src/ams_bridge.c -o ams_bridge.so \
    -L"$NGLIB" -lngspice -lpthread
echo "   ok"

# LD_LIBRARY_PATH matters at RUN time as well as link time: xezim dlopens
# the bridge, and a libngspice it cannot find surfaces as "cannot open
# shared object", which reads like a fault in the bridge itself.
#
# --wave is required for $dumpfile/$dumpvars to do anything: xezim compiles
# waveform support out by default, because an active dump forces loops onto
# a slower path. Without it a testbench that calls $dumpvars runs happily
# and writes no file.
run() {
  local dir=$1 maxt=$2
  shift 2
  ( cd "$dir" && LD_LIBRARY_PATH="$NGLIB:$LD_LIBRARY_PATH" \
      "$XEZIM" --max-time "$maxt" --wave \
               --dpi-lib "$HERE/ams_bridge.so" "$@" 2>&1 \
      | grep -vE '^\[(PROF|FUSE|COV|EVENT|PHASE)' )
}

case "${1:-}" in
  rc)  echo "== RC lockstep check =="
       run examples/rc 50ms tb_rc.sv ;;
  pll) echo "== PLL golden =="
       run examples/pll 5ms pfd.sv divn.sv tb_pll.sv
       # One file a viewer can open, with both domains on one timeline.
       # Nothing is resampled: a VCD timestamp is an arbitrary integer, so
       # each of ngspice's own timepoints becomes one.
       if [ -f examples/pll/pll_analog.raw ]; then
         python3 tools/raw2vcd.py examples/pll/pll_analog.raw \
                 --merge examples/pll/pll_digital.vcd \
                 -o examples/pll/pll_combined.vcd
       fi ;;
  "")  ;;
  *)   echo "unknown target: $1" >&2; exit 2 ;;
esac
