#!/usr/bin/env bash
#
# mayhem/build.sh — build the xst OSS-Fuzz/libFuzzer harness (+ standalone reproducer) and the
# file-input `tools` target (the Moddable SDK tool runner, fuzzed via `tools bles2gatt @@`).
# Match OSS-Fuzz projects/xs/build.sh: let xst.mk link the fuzz binary (custom relinks broke
# sanitizer coverage → 0 Mayhem edges). Only build a separate standalone reproducer here.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# OSS-Fuzz sets -fsanitize=fuzzer-no-link in CFLAGS/CXXFLAGS; without it the .o files get no
# edge counters and Mayhem reports 0 edges even though the link step pulls in libFuzzer.
# The full $SANITIZER_FLAGS (default ASan+UBSan, halting) instruments the fuzzed code, minus two
# UBSan checks that abort on EVERY input because of the XS engine's design (ASan and all other
# UBSan checks stay on and halting):
#   alignment — the bytecode interpreter reads packed operands in place, e.g.
#     xsRun.c:2879 "load of misaligned address ... for type 'txS2'" (tools, on every seed) and
#     xsRun.c:4209 "load of misaligned address ... for type 'txS4'" (xst, on the first seed);
#   function  — host callbacks are declared on xsMachine* and called as txCallback(txMachine*), e.g.
#     xsRun.c:891 "call to function xs_textdecoder through pointer to incorrect function type"
#     (xst, on the first seed).
XS_UBSAN_RELAX="-fno-sanitize=alignment,function"
FUZZ_SANITIZER_FLAGS="$SANITIZER_FLAGS $XS_UBSAN_RELAX -fsanitize=fuzzer-no-link"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

export MODDABLE="$SRC"
export XS_DIR="$SRC/xs"
export BUILD_DIR="$SRC/build"

export CFLAGS="${CFLAGS:-} $FUZZ_SANITIZER_FLAGS $DEBUG_FLAGS"
export CXXFLAGS="${CXXFLAGS:-} $FUZZ_SANITIZER_FLAGS $DEBUG_FLAGS"

OUT="/mayhem"
mkdir -p "$OUT"
SEED_DIR="$SRC/mayhem/xst/testsuite"
[ -n "$(ls -A "$SEED_DIR"/*.js 2>/dev/null)" ] || { echo "ERROR: missing seed corpus under $SEED_DIR" >&2; exit 1; }

# Build-time LSan opt-out hook, linked into BOTH the fuzz binary and the standalone reproducer.
# xst.mk links the fuzz binary as `$(CXX) $(LIB_FUZZING_ENGINE) $(LINK_OPTIONS) $(OBJECTS) ...`, so the
# hook object rides in via a make-command-line LIB_FUZZING_ENGINE (no upstream file is modified).
LSAN_OFF_DIR="$BUILD_DIR/tmp/lin/debug/mayhem"
LSAN_OFF_O="$LSAN_OFF_DIR/lsan_off.o"
mkdir -p "$LSAN_OFF_DIR"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.c" -o "$LSAN_OFF_O"

cd "$SRC/xs/makefiles/lin"
# OSS-Fuzz: FUZZING=1 OSSFUZZ=1 FUZZ_METER=2560000 make debug
make -j"$MAYHEM_JOBS" FUZZING=1 OSSFUZZ=1 FUZZ_METER=2560000 \
    LIB_FUZZING_ENGINE="$LIB_FUZZING_ENGINE $LSAN_OFF_O" debug

BIN_DIR="$BUILD_DIR/bin/lin/debug"
TMP_DIR="$BUILD_DIR/tmp/lin/debug/xst"
XST_MK="$SRC/xs/makefiles/lin/xst.mk"
[ -x "$BIN_DIR/xst" ] || { echo "ERROR: $BIN_DIR/xst not built" >&2; exit 1; }

cp "$BIN_DIR/xst" "$OUT/xst"

# Standalone reproducer: same OBJECTS order as xst.mk + LSan opt-out hook + run-once driver.
STANDALONE_O="$TMP_DIR/standalone_main.o"
mapfile -t OBJECTS < <(python3 - "$XST_MK" "$TMP_DIR" <<'PY'
import sys
mk, tmp = sys.argv[1], sys.argv[2]
objs, in_objs = [], False
for line in open(mk):
    if line.startswith("OBJECTS = "):
        in_objs = True
        continue
    if not in_objs:
        continue
    if line and not line[0].isspace():
        break
    entry = line.strip().rstrip("\\").strip()
    if entry:
        objs.append(entry.replace("$(TMP_DIR)", tmp))
for o in objs:
    print(o)
PY
)
[ "${#OBJECTS[@]}" -gt 0 ] || { echo "build.sh: failed to parse OBJECTS from $XST_MK" >&2; exit 1; }

LIBS="-ldl -lm -lpthread -latomic -lrt"
$CC $FUZZ_SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$STANDALONE_O"
$CXX -rdynamic $FUZZ_SANITIZER_FLAGS $DEBUG_FLAGS \
    "${OBJECTS[@]}" "$LSAN_OFF_O" "$STANDALONE_O" \
    $LIBS \
    -o "$OUT/xst-standalone"

# ---- `tools` target: the SDK tool runner (build/makefiles/lin/tools.mk), file-input ----
# The host compilers it needs (xsc/xsid/xsl) are build-time tools: plain, uninstrumented.
# tools.mk has no CFLAGS hook, so the sanitizers ride in on a make-command-line CC (used for every
# compile AND the link) and the LSan hook on LINK_FLAGS (link only). Release goal, as upstream ships.
TOOLS_SEED_DIR="$SRC/mayhem/tools/testsuite"
[ -n "$(ls -A "$TOOLS_SEED_DIR"/*.json 2>/dev/null)" ] || { echo "ERROR: missing seed corpus under $TOOLS_SEED_DIR" >&2; exit 1; }
for mk in xsc xsid xsl; do
  env -u CFLAGS -u CXXFLAGS make -j"$MAYHEM_JOBS" GOAL=release -f "$XS_DIR/makefiles/lin/$mk.mk"
done
cd "$SRC/build/makefiles/lin"
env -u CFLAGS -u CXXFLAGS make -j"$MAYHEM_JOBS" GOAL=release -f tools.mk \
    CC="$CC $SANITIZER_FLAGS $XS_UBSAN_RELAX $DEBUG_FLAGS" LINK_FLAGS="-fPIC $LSAN_OFF_O"
TOOLS_BIN="$BUILD_DIR/bin/lin/release/tools"
[ -x "$TOOLS_BIN" ] || { echo "ERROR: $TOOLS_BIN not built" >&2; exit 1; }
# /mayhem/tools is the upstream tools/ source dir, so the binary ships under another name.
cp "$TOOLS_BIN" "$OUT/moddable-tools"

echo "build.sh complete:"
ls -la "$OUT/xst" "$OUT/xst-standalone" "$OUT/moddable-tools"
ls "$SEED_DIR" | wc -l | xargs echo "xst seed corpus files:"
ls "$TOOLS_SEED_DIR" | wc -l | xargs echo "tools seed corpus files:"
