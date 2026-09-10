#!/bin/bash
# Build the bridge, and optionally run an example.
#
#   ./build.sh          build src/ams_bridge.c -> ams_bridge.so
#   ./build.sh rc       build, then the RC lockstep check   (~1 s)
#   ./build.sh pll      build, then the PLL golden          (~2.5 min)
#
# Paths come from the environment, so this is not tied to one machine:
#
#   XEZIM         the xezim BINARY (not the checkout directory)
#
# and libngspice is found in one of two shapes, in this order:
#
#   NGSPICE_LIB + NGSPICE_INC   an explicit pair, checked first
#   NGSPICE_SRC                 an ngspice SOURCE tree configured
#                               --with-ngshared (libngspice.so in
#                               src/.libs, headers in src/include)
#   otherwise                   a packaged install, e.g. Debian's
#                               libngspice0-dev: the loader's own path
#                               plus /usr/include/ngspice
#
# Whichever shape, it must be the SHARED library. The ordinary ngspice
# binary will not do: this links libngspice.so, which a source tree only
# produces if it was configured --with-ngshared. If you build from source,
# configure a SECOND copy -- ngspice refuses to configure a tree that is
# already configured, and reusing the one that built the CLI destroys it.
#
# The packaged path exists so CI (and anyone who just wants to run this)
# needs `apt-get install libngspice0-dev` rather than an ngspice build. The
# examples are pure analog -- no XSPICE code models -- so a stock package
# is enough.
set -e

XEZIM=${XEZIM:-$HOME/xezim/target/release/xezim}
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

find_ngspice() {
  # 1. an explicit pair wins, so an unusual layout is always expressible.
  #    VALIDATED, not just accepted: taking it on trust turned a wrong path
  #    into a gcc "cannot find -lngspice" further down, which reads like a
  #    fault in the bridge rather than a mistyped variable -- and, because
  #    it changed the error text, stopped run_tests.sh recognising a missing
  #    toolchain as a skip.
  if [ -n "${NGSPICE_LIB:-}" ] && [ -n "${NGSPICE_INC:-}" ]; then
    if ls "$NGSPICE_LIB"/libngspice.so* >/dev/null 2>&1 \
       && [ -f "$NGSPICE_INC/sharedspice.h" ]; then
      NGLIB=$NGSPICE_LIB; NGINC="-I$NGSPICE_INC"; NGWHERE="NGSPICE_LIB/NGSPICE_INC"
      return 0
    fi
    BAD_EXPLICIT="  NGSPICE_LIB=$NGSPICE_LIB (needs libngspice.so*)
  NGSPICE_INC=$NGSPICE_INC (needs sharedspice.h)"
  fi
  # 2. a source tree, the historical default
  local src=${NGSPICE_SRC:-$HOME/ngspice-46-shared}
  if [ -f "$src/src/.libs/libngspice.so" ]; then
    NGLIB="$src/src/.libs"
    NGINC="-I$src/src/include/ngspice -I$src/src/include"
    NGWHERE="source tree $src"
    return 0
  fi
  # 3. a packaged install: ask the loader where the library is, rather than
  #    guessing a multiarch triplet
  local so
  so=$(ldconfig -p 2>/dev/null | awk '/libngspice\.so/ {print $NF; exit}')
  if [ -n "$so" ] && [ -f "$so" ]; then
    for inc in /usr/include/ngspice /usr/local/include/ngspice; do
      if [ -f "$inc/sharedspice.h" ]; then
        NGLIB=$(dirname "$so"); NGINC="-I$inc"; NGWHERE="package $so"
        return 0
      fi
    done
  fi
  return 1
}

BAD_EXPLICIT=""
if ! find_ngspice; then
  echo "no shared libngspice found" >&2
  echo "  tried: NGSPICE_LIB+NGSPICE_INC, then a source tree, then the loader" >&2
  # An explicit `cmd && echo` here would abort the rest of this help text
  # under `set -e` whenever the test is false.
  if [ -n "$BAD_EXPLICIT" ]; then echo "$BAD_EXPLICIT" >&2; fi
  echo "  easiest fix:  sudo apt-get install libngspice0-dev" >&2
  echo "  from source:" >&2
  echo "    cp -a ngspice-46 ngspice-46-shared && cd ngspice-46-shared" >&2
  echo "    make distclean" >&2
  echo "    ./configure --with-ngshared --enable-xspice --disable-debug" >&2
  echo "    make -j\$(nproc)" >&2
  exit 1
fi
if [ ! -x "$XEZIM" ]; then
  echo "no executable xezim at $XEZIM" >&2
  echo "  XEZIM must name the BINARY, not the checkout directory" >&2
  exit 1
fi

echo "== ams_bridge.so =="
echo "   libngspice: $NGWHERE"
# shellcheck disable=SC2086  # NGINC is deliberately several -I words
gcc -shared -fPIC -O2 -Wall \
    $NGINC \
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
