#!/usr/bin/env bash
# Bootstrap test: compile the self-hosting compiler N times and verify
# each generation produces identical output (fixed point).
#
# Usage: ./bootstrap.sh [N]
#   N = number of bootstrap generations (default: 3)
#
# The script:
#   1. Uses the Haskell compiler to produce gen0 (the initial binary)
#   2. gen0 compiles compiler.bad -> gen1
#   3. gen1 compiles compiler.bad -> gen2
#   ...and so on for N generations
#   4. Verifies all generations after gen1 produce identical C output

set -euo pipefail

N="${1:-3}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPILER_SRC="$SCRIPT_DIR/compiler.bad"
RUNTIME="$SCRIPT_DIR/runtime.c"
WORK_DIR=$(mktemp -d)

trap 'rm -rf "$WORK_DIR"' EXIT

# Ensure large stack for deeply recursive code
# The self-hosting compiler generates deeply nested C, which needs a big stack.
# On macOS the hard limit is ~65MB; on Linux "unlimited" usually works.
ulimit -s unlimited 2>/dev/null || ulimit -s "$(ulimit -Hs)" 2>/dev/null || true

# Also compile generated C with a larger stack to handle deep recursion
CC_FLAGS="-O1"
if [[ "$(uname)" == "Darwin" ]]; then
    CC_FLAGS="$CC_FLAGS -Wl,-stack_size,0x4000000"  # 64MB stack
fi

echo "=== Badlang Bootstrap Test ==="
echo "Generations: $N"
echo "Source: $COMPILER_SRC"
echo "Work dir: $WORK_DIR"
echo ""

# Step 0: Build gen0 using the Haskell reference compiler
echo "[gen0] Compiling compiler.bad with Haskell compiler..."
(cd "$SCRIPT_DIR/../.." && cabal run badlang -- "$COMPILER_SRC") >/dev/null 2>&1
cp "$SCRIPT_DIR/compiler.c" "$WORK_DIR/gen0.c"
cc $CC_FLAGS -o "$WORK_DIR/gen0" "$WORK_DIR/gen0.c"
echo "[gen0] OK"

# Step 1..N: Each generation compiles the source
prev="$WORK_DIR/gen0"
for i in $(seq 1 "$N"); do
    echo "[gen$i] Compiling compiler.bad with gen$((i-1))..."
    (cd "$SCRIPT_DIR" && "$prev" "$COMPILER_SRC" "$WORK_DIR/gen${i}.c")
    cc $CC_FLAGS -o "$WORK_DIR/gen${i}" "$WORK_DIR/gen${i}.c"
    echo "[gen$i] OK"
    prev="$WORK_DIR/gen${i}"
done

# Verify fixed point: gen1.c == gen2.c == ... == genN.c
echo ""
echo "=== Verifying Fixed Point ==="
FIXED=true
for i in $(seq 2 "$N"); do
    if diff -q "$WORK_DIR/gen1.c" "$WORK_DIR/gen${i}.c" >/dev/null 2>&1; then
        echo "[gen1.c == gen${i}.c] OK"
    else
        echo "[gen1.c != gen${i}.c] MISMATCH!"
        FIXED=false
    fi
done

# Smoke test: compile a simple program with the final generation
echo ""
echo "=== Smoke Test (gen$N compiles hello.bad) ==="
HELLO_SRC="$SCRIPT_DIR/../hello.bad"
if [ -f "$HELLO_SRC" ]; then
    (cd "$SCRIPT_DIR" && "$WORK_DIR/gen${N}" "$HELLO_SRC" "$WORK_DIR/hello.c")
    cc $CC_FLAGS -o "$WORK_DIR/hello" "$WORK_DIR/hello.c"
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
    echo "Skipped (hello.bad not found)"
fi

echo ""
if [ "$FIXED" = true ]; then
    echo "=== BOOTSTRAP SUCCESS ==="
    echo "The compiler reaches a fixed point at gen1."
    echo "All $N generations produce identical C output."
else
    echo "=== BOOTSTRAP FAILURE ==="
    exit 1
fi
