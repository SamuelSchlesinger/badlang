#!/usr/bin/env bash
# Bootstrap test: compile the self-hosting compiler N times and verify
# each generation produces identical output (fixed point).
#
# Usage: ./bootstrap.sh [N] [c|asm|x86|x86-linux]
#   N    = number of bootstrap generations (default: 3)
#   mode = "c" (default), "asm" (AArch64), "x86" (macOS x86_64), or
#          "x86-linux" (System V x86_64)
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
#
# x86/x86-linux modes:
#   gen0: Haskell compiler -> compiler.c -> gen0 binary
#   gen1+: genN-1 compiler.stele genN.s <mode> -> cc genN.s + runtime_x86_64.c -> genN
#   verify: gen1.s == gen2.s == ... == genN.s

set -euo pipefail

N="${1:-3}"
MODE="${2:-c}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPILER_SRC="$SCRIPT_DIR/compiler.stele"
RUNTIME_AARCH64="$SCRIPT_DIR/../../runtime/runtime_aarch64.c"
RUNTIME_X86_64="$SCRIPT_DIR/../../runtime/runtime_x86_64.c"
WORK_DIR=$(mktemp -d)

trap 'rm -rf "$WORK_DIR"' EXIT

if [[ "$MODE" != "c" && "$MODE" != "asm" && "$MODE" != "x86" && "$MODE" != "x86-linux" ]]; then
    echo "Error: mode must be one of: c, asm, x86, x86-linux; got '$MODE'"
    exit 1
fi

# Ensure large stack for deeply recursive code
ulimit -s unlimited 2>/dev/null || ulimit -s "$(ulimit -Hs)" 2>/dev/null || true

# Compile flags: larger stack on macOS
CC_FLAGS=("-O1")
if [[ "$(uname)" == "Darwin" ]]; then
    CC_FLAGS+=("-Wl,-stack_size,0x10000000")  # 256MB stack
fi

case "$MODE" in
    c)
        EXT="c"
        EMIT_MODE=""
        RUNTIME_SRC=""
        ;;
    asm)
        EXT="s"
        EMIT_MODE="asm"
        RUNTIME_SRC="$RUNTIME_AARCH64"
        ;;
    x86)
        EXT="s"
        EMIT_MODE="x86"
        RUNTIME_SRC="$RUNTIME_X86_64"
        if [[ "$(uname)" == "Darwin" ]]; then
            CC_FLAGS+=("-arch" "x86_64")
        fi
        ;;
    x86-linux)
        EXT="s"
        EMIT_MODE="x86-linux"
        RUNTIME_SRC="$RUNTIME_X86_64"
        ;;
esac

if [[ "$MODE" == "x86-linux" && "$(uname)" == "Darwin" ]]; then
    echo "Error: mode 'x86-linux' needs a Linux toolchain in 'cc' (not detected on macOS default cc)."
    exit 1
fi

compile_generated() {
    local src="$1"
    local out="$2"
    if [[ "$EXT" == "c" ]]; then
        cc "${CC_FLAGS[@]}" -o "$out" "$src"
    else
        cc "${CC_FLAGS[@]}" -o "$out" "$src" "$RUNTIME_SRC"
    fi
}

emit_with_compiler() {
    local compiler_bin="$1"
    local src="$2"
    local out="$3"
    if [[ "$EXT" == "c" ]]; then
        (cd "$SCRIPT_DIR" && "$compiler_bin" "$src" "$out")
    else
        (cd "$SCRIPT_DIR" && "$compiler_bin" "$src" "$out" "$EMIT_MODE")
    fi
}

echo "=== Stele Bootstrap Test ==="
echo "Generations: $N"
echo "Mode: $MODE"
echo "Source: $COMPILER_SRC"
echo "Work dir: $WORK_DIR"
echo ""

# Step 0: Build gen0 using the Haskell reference compiler (always C)
echo "[gen0] Compiling compiler.stele with Haskell compiler..."
if command -v cabal >/dev/null 2>&1; then
    (cd "$SCRIPT_DIR/../.." && cabal run stele -- "$COMPILER_SRC") >/dev/null 2>&1
else
    if [[ -f "$SCRIPT_DIR/compiler.c" ]]; then
        echo "[gen0] cabal not found; reusing existing $SCRIPT_DIR/compiler.c"
    else
        echo "Error: cabal not found and $SCRIPT_DIR/compiler.c is missing."
        exit 1
    fi
fi
cp "$SCRIPT_DIR/compiler.c" "$WORK_DIR/gen0.c"
compile_generated "$WORK_DIR/gen0.c" "$WORK_DIR/gen0"
echo "[gen0] OK"

# Step 1..N: Each generation compiles the source
prev="$WORK_DIR/gen0"
for i in $(seq 1 "$N"); do
    echo "[gen$i] Compiling compiler.stele with gen$((i-1))..."
    emit_with_compiler "$prev" "$COMPILER_SRC" "$WORK_DIR/gen${i}.$EXT"
    compile_generated "$WORK_DIR/gen${i}.$EXT" "$WORK_DIR/gen${i}"
    echo "[gen$i] OK"
    prev="$WORK_DIR/gen${i}"
done

# Verify fixed point: gen1.ext == gen2.ext == ... == genN.ext
echo ""
echo "=== Verifying Fixed Point ==="
FIXED=true
if [[ "$N" -ge 2 ]]; then
    for i in $(seq 2 "$N"); do
        if diff -q "$WORK_DIR/gen1.$EXT" "$WORK_DIR/gen${i}.$EXT" >/dev/null 2>&1; then
            echo "[gen1.$EXT == gen${i}.$EXT] OK"
        else
            echo "[gen1.$EXT != gen${i}.$EXT] MISMATCH!"
            FIXED=false
        fi
    done
else
    echo "Skipping fixed-point diff (need N >= 2)"
fi

# Smoke test: compile a simple program with the final generation
echo ""
echo "=== Smoke Test (gen$N compiles hello.stele) ==="
HELLO_SRC="$SCRIPT_DIR/../hello.stele"
if [ -f "$HELLO_SRC" ]; then
    emit_with_compiler "$WORK_DIR/gen${N}" "$HELLO_SRC" "$WORK_DIR/hello.$EXT"
    compile_generated "$WORK_DIR/hello.$EXT" "$WORK_DIR/hello"
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
