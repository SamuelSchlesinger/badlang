#!/usr/bin/env bash
# Bootstrap test: compile the self-hosting compiler N times and verify
# each generation produces identical output (fixed point).
#
# Usage: ./bootstrap.sh [N] [c|asm]
#   N    = number of bootstrap generations (default: 3)
#   mode = "c" (default) or "asm" (AArch64 native)
#
# C mode:
#   gen0: Haskell compiler -> compiler.c -> gen0 binary
#   gen1+: genN-1 compiler.stele genN.c -> cc genN.c -> genN binary
#   verify: gen1.c == gen2.c == ... == genN.c
#
# ASM mode:
#   gen0: Haskell compiler -> compiler.c -> gen0 binary (always via C)
#   gen1+: genN-1 compiler.stele genN.s asm -> cc genN.s + runtime_aarch64.c -> genN
#   verify: gen1.s == gen2.s == ... == genN.s

set -euo pipefail

N="${1:-3}"
MODE="${2:-c}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPILER_SRC="$SCRIPT_DIR/compiler.stele"
RUNTIME_C="$SCRIPT_DIR/runtime.c"
RUNTIME_AARCH64="$SCRIPT_DIR/../../runtime/runtime_aarch64.c"
WORK_DIR=$(mktemp -d)

trap 'rm -rf "$WORK_DIR"' EXIT

if [[ "$MODE" != "c" && "$MODE" != "asm" ]]; then
    echo "Error: mode must be 'c' or 'asm', got '$MODE'"
    exit 1
fi

# Ensure large stack for deeply recursive code
ulimit -s unlimited 2>/dev/null || ulimit -s "$(ulimit -Hs)" 2>/dev/null || true

# Compile flags: larger stack on macOS
CC_FLAGS="-O1"
if [[ "$(uname)" == "Darwin" ]]; then
    CC_FLAGS="$CC_FLAGS -Wl,-stack_size,0x10000000"  # 256MB stack
fi

echo "=== Stele Bootstrap Test ==="
echo "Generations: $N"
echo "Mode: $MODE"
echo "Source: $COMPILER_SRC"
echo "Work dir: $WORK_DIR"
echo ""

# Step 0: Build gen0 using the Haskell reference compiler (always C)
echo "[gen0] Compiling compiler.stele with Haskell compiler..."
(cd "$SCRIPT_DIR/../.." && cabal run stele -- "$COMPILER_SRC") >/dev/null 2>&1
cp "$SCRIPT_DIR/compiler.c" "$WORK_DIR/gen0.c"
cc $CC_FLAGS -o "$WORK_DIR/gen0" "$WORK_DIR/gen0.c"
echo "[gen0] OK"

# Extension for generated output
if [[ "$MODE" == "asm" ]]; then
    EXT="s"
else
    EXT="c"
fi

# Step 1..N: Each generation compiles the source
prev="$WORK_DIR/gen0"
for i in $(seq 1 "$N"); do
    echo "[gen$i] Compiling compiler.stele with gen$((i-1))..."
    if [[ "$MODE" == "asm" ]]; then
        (cd "$SCRIPT_DIR" && "$prev" "$COMPILER_SRC" "$WORK_DIR/gen${i}.s" asm)
        cc $CC_FLAGS -o "$WORK_DIR/gen${i}" "$WORK_DIR/gen${i}.s" "$RUNTIME_AARCH64"
    else
        (cd "$SCRIPT_DIR" && "$prev" "$COMPILER_SRC" "$WORK_DIR/gen${i}.c")
        cc $CC_FLAGS -o "$WORK_DIR/gen${i}" "$WORK_DIR/gen${i}.c"
    fi
    echo "[gen$i] OK"
    prev="$WORK_DIR/gen${i}"
done

# Verify fixed point: gen1.ext == gen2.ext == ... == genN.ext
echo ""
echo "=== Verifying Fixed Point ==="
FIXED=true
for i in $(seq 2 "$N"); do
    if diff -q "$WORK_DIR/gen1.$EXT" "$WORK_DIR/gen${i}.$EXT" >/dev/null 2>&1; then
        echo "[gen1.$EXT == gen${i}.$EXT] OK"
    else
        echo "[gen1.$EXT != gen${i}.$EXT] MISMATCH!"
        FIXED=false
    fi
done

# Smoke test: compile a simple program with the final generation
echo ""
echo "=== Smoke Test (gen$N compiles hello.stele) ==="
HELLO_SRC="$SCRIPT_DIR/../hello.stele"
if [ -f "$HELLO_SRC" ]; then
    if [[ "$MODE" == "asm" ]]; then
        (cd "$SCRIPT_DIR" && "$WORK_DIR/gen${N}" "$HELLO_SRC" "$WORK_DIR/hello.s" asm)
        cc $CC_FLAGS -o "$WORK_DIR/hello" "$WORK_DIR/hello.s" "$RUNTIME_AARCH64"
    else
        (cd "$SCRIPT_DIR" && "$WORK_DIR/gen${N}" "$HELLO_SRC" "$WORK_DIR/hello.c")
        cc $CC_FLAGS -o "$WORK_DIR/hello" "$WORK_DIR/hello.c"
    fi
    ACTUAL=$("$WORK_DIR/hello")
    EXPECTED=$(printf "25\n3628800")
    if [ "$ACTUAL" = "$EXPECTED" ]; then
        echo "Output matches expected: OK"
    else
        echo "Output mismatch!"
        echo "Expected: $EXPECTED"
        echo "Actual: $ACTUAL"
        FIXED=false
    fi
else
    echo "Skipped (hello.stele not found)"
fi

echo ""
if [ "$FIXED" = true ]; then
    echo "=== BOOTSTRAP SUCCESS ==="
    echo "The compiler reaches a fixed point at gen1."
    echo "All $N generations produce identical $EXT output."
else
    echo "=== BOOTSTRAP FAILURE ==="
    exit 1
fi
