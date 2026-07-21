#!/usr/bin/env bash
# Bootstrap test: compile the self-hosting compiler N times and verify
# each generation produces identical output (fixed point).
#
# Usage: ./bootstrap.sh [N] [c|asm|asm-linux|x86|x86-linux]
#   N    = number of bootstrap generations (default: 3)
#   mode = "c" (default), "asm" (AArch64 macOS), "asm-linux" (AArch64 Linux),
#          "x86" (macOS x86_64), or "x86-linux" (System V x86_64)
#
# C mode:
#   gen0: Haskell compiler -> compiler.c -> gen0 binary
#   gen1+: genN-1 compiler.stele genN.c -> cc genN.c -> genN binary
#   verify: gen1.c == gen2.c == ... == genN.c
#
# ASM mode:
#   gen0: Haskell compiler -> compiler.c -> gen0 binary (always via C)
#   gen1+: genN-1 compiler.stele genN.s asm -> cc genN.s + runtime.c -> genN
#   verify: gen1.s == gen2.s == ... == genN.s
#
# x86/x86-linux modes:
#   gen0: Haskell compiler -> compiler.c -> gen0 binary
#   gen1+: genN-1 compiler.stele genN.s <mode> -> cc genN.s + runtime.c -> genN
#   verify: gen1.s == gen2.s == ... == genN.s

set -euo pipefail

N="${1:-3}"
MODE="${2:-c}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NATIVE_RUNTIME="$SCRIPT_DIR/runtime/runtime.c"
STDLIB_DIR="$SCRIPT_DIR/stdlib"
WORK_DIR=$(mktemp -d)

# Use module-based compilation (no concatenation needed)
COMPILER_SRC="$SCRIPT_DIR/compiler/main.stele"

trap 'rm -rf "$WORK_DIR"' EXIT

if [[ "$MODE" != "c" && "$MODE" != "asm" && "$MODE" != "asm-linux" && "$MODE" != "x86" && "$MODE" != "x86-linux" ]]; then
    echo "Error: mode must be one of: c, asm, asm-linux, x86, x86-linux; got '$MODE'"
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
        RUNTIME_SRC="$NATIVE_RUNTIME"
        ;;
    asm-linux)
        EXT="s"
        EMIT_MODE="asm-linux"
        RUNTIME_SRC="$NATIVE_RUNTIME"
        ;;
    x86)
        EXT="s"
        EMIT_MODE="x86"
        RUNTIME_SRC="$NATIVE_RUNTIME"
        if [[ "$(uname)" == "Darwin" ]]; then
            CC_FLAGS+=("-arch" "x86_64")
        fi
        ;;
    x86-linux)
        EXT="s"
        EMIT_MODE="x86-linux"
        RUNTIME_SRC="$NATIVE_RUNTIME"
        ;;
esac

if [[ ("$MODE" == "x86-linux" || "$MODE" == "asm-linux") && "$(uname)" == "Darwin" ]]; then
    echo "Error: mode '$MODE' needs a Linux toolchain in 'cc' (not detected on macOS default cc)."
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
    (cd "$SCRIPT_DIR/bootstrap/haskell" && cabal run stele -- "$COMPILER_SRC") >/dev/null 2>&1
    cp "$SCRIPT_DIR/compiler/main.c" "$WORK_DIR/gen0.c"
else
    if [[ -f "$SCRIPT_DIR/compiler.c" ]]; then
        echo "[gen0] cabal not found; reusing existing $SCRIPT_DIR/compiler.c"
    else
        echo "Error: cabal not found and $SCRIPT_DIR/compiler.c is missing."
        exit 1
    fi
    cp "$SCRIPT_DIR/compiler.c" "$WORK_DIR/gen0.c"
fi
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
HELLO_SRC="$SCRIPT_DIR/examples/hello.stele"
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

# Smoke test: build and run stela via the final generation
echo ""
echo "=== Smoke Test (gen$N compiles stela.stele) ==="
STELA_SRC="$SCRIPT_DIR/stela.stele"
if [ -f "$STELA_SRC" ]; then
    emit_with_compiler "$WORK_DIR/gen${N}" "$STELA_SRC" "$WORK_DIR/stela.$EXT"
    compile_generated "$WORK_DIR/stela.$EXT" "$WORK_DIR/stela"
    STELA_RUN_DIR="$WORK_DIR/stela-run"
    mkdir -p "$STELA_RUN_DIR"
    mkdir -p "$STELA_RUN_DIR/runtime"
    cp "$NATIVE_RUNTIME" "$STELA_RUN_DIR/runtime/runtime.c"
    cp "$STDLIB_DIR/cli.stele" "$STELA_RUN_DIR/cli.stele"
    cp "$STDLIB_DIR/math.stele" "$STELA_RUN_DIR/math.stele"
    cp "$STDLIB_DIR/concurrency.stele" "$STELA_RUN_DIR/concurrency.stele"
    cp "$STDLIB_DIR/assert.stele" "$STELA_RUN_DIR/assert.stele"
    cp "$STDLIB_DIR/strings.stele" "$STELA_RUN_DIR/strings.stele"
    cp "$STDLIB_DIR/path.stele" "$STELA_RUN_DIR/path.stele"
    cp "$STDLIB_DIR/tests/assert_test.stele" "$STELA_RUN_DIR/assert_test.stele"
    cp "$STDLIB_DIR/tests/cli_test.stele" "$STELA_RUN_DIR/cli_test.stele"
    cp "$STDLIB_DIR/tests/math_test.stele" "$STELA_RUN_DIR/math_test.stele"
    cp "$STDLIB_DIR/tests/concurrency_test.stele" "$STELA_RUN_DIR/concurrency_test.stele"
    cp "$STDLIB_DIR/tests/strings_test.stele" "$STELA_RUN_DIR/strings_test.stele"
    cp "$STDLIB_DIR/tests/path_test.stele" "$STELA_RUN_DIR/path_test.stele"
    WEIRD_SRC="$STELA_RUN_DIR/quoted ' \$(printf injected).stele"
    cp "$HELLO_SRC" "$WEIRD_SRC"
    cat > "$STELA_RUN_DIR/app.stele" <<'EOF'
do main
  let argc_now = cli_argc {| |}
  let clamped = math_clamp {| n: argc_now, lo: 0, hi: 10 |}
  let pid = conc_spawn {| command: "true" |}
  let code = conc_await {| pid: pid |}
  print clamped
  print code
end
EOF
    (
      cd "$STELA_RUN_DIR" && \
      "$WORK_DIR/stela" check "$HELLO_SRC" --compiler "$WORK_DIR/gen${N}" --mode "$MODE" --no-sandbox >/dev/null && \
      "$WORK_DIR/stela" check "$WEIRD_SRC" --compiler "$WORK_DIR/gen${N}" --mode "$MODE" --no-sandbox >/dev/null && \
      "$WORK_DIR/stela" package-lib cli.stele --name cli >/dev/null && \
      "$WORK_DIR/stela" package-lib math.stele --name math >/dev/null && \
      "$WORK_DIR/stela" package-lib concurrency.stele --name concurrency >/dev/null && \
      "$WORK_DIR/stela" package-lib assert.stele --name assert >/dev/null && \
      "$WORK_DIR/stela" package-lib strings.stele --name strings >/dev/null && \
      "$WORK_DIR/stela" package-lib path.stele --name path >/dev/null && \
      "$WORK_DIR/stela" test assert_test.stele --lib assert --compiler "$WORK_DIR/gen${N}" --mode "$MODE" --no-sandbox >/dev/null && \
      "$WORK_DIR/stela" test cli_test.stele --lib cli --compiler "$WORK_DIR/gen${N}" --mode "$MODE" --no-sandbox >/dev/null && \
      "$WORK_DIR/stela" test math_test.stele --lib math --compiler "$WORK_DIR/gen${N}" --mode "$MODE" --no-sandbox >/dev/null && \
      "$WORK_DIR/stela" test concurrency_test.stele --lib concurrency --compiler "$WORK_DIR/gen${N}" --mode "$MODE" --no-sandbox >/dev/null && \
      "$WORK_DIR/stela" test strings_test.stele --lib assert --lib strings --compiler "$WORK_DIR/gen${N}" --mode "$MODE" --no-sandbox >/dev/null && \
      "$WORK_DIR/stela" test path_test.stele --lib assert --lib path --compiler "$WORK_DIR/gen${N}" --mode "$MODE" --no-sandbox >/dev/null && \
      "$WORK_DIR/stela" test app.stele --lib cli --lib math --lib concurrency --compiler "$WORK_DIR/gen${N}" --mode "$MODE" --no-sandbox >/dev/null
    )
    echo "stela self-hosted targets/libs/stdlib/tests: OK"
else
    echo "Skipped (stela.stele not found)"
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
