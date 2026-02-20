#!/usr/bin/env bash
# Compiler test suite: positive tests (compile+run, check output) and
# negative tests (must fail to compile, check error message).
# Tests both the Haskell bootstrap compiler and the self-hosted compiler
# across all available backends (C, AArch64, x86-64).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Ensure large stack for deeply recursive code
ulimit -s unlimited 2>/dev/null || ulimit -s "$(ulimit -Hs)" 2>/dev/null || true

# Compile flags
CC_FLAGS=("-O1")
if [[ "$(uname)" == "Darwin" ]]; then
    CC_FLAGS+=("-Wl,-stack_size,0x10000000")  # 256MB stack
fi

PASS=0
FAIL=0
TOTAL=0

# Build the Haskell compiler
echo "Building Haskell compiler..."
(cd "$ROOT_DIR/bootstrap/haskell" && cabal build exe:stele) >/dev/null 2>&1

STELE_HS="$(cd "$ROOT_DIR/bootstrap/haskell" && cabal list-bin exe:stele 2>/dev/null)"

# Detect native targets
NATIVE_TARGETS=()
ARCH="$(uname -m)"
OS="$(uname -s)"
if [[ "$ARCH" == "arm64" || "$ARCH" == "aarch64" ]]; then
    if [[ "$OS" == "Darwin" ]]; then
        NATIVE_TARGETS+=("aarch64-macos")
    elif [[ "$OS" == "Linux" ]]; then
        NATIVE_TARGETS+=("aarch64-linux")
    fi
fi
if [[ "$ARCH" == "x86_64" ]]; then
    if [[ "$OS" == "Darwin" ]]; then
        NATIVE_TARGETS+=("x86_64-macos")
    elif [[ "$OS" == "Linux" ]]; then
        NATIVE_TARGETS+=("x86_64-linux")
    fi
fi

# ── Build the self-hosted compiler (gen0) ─────────────────────────

build_self_hosted() {
    local compiler_src
    compiler_src="$(mktemp /tmp/stele_compiler_XXXXXX.stele)"
    cat "$ROOT_DIR/compiler/util.stele" \
        "$ROOT_DIR/compiler/lexer.stele" \
        "$ROOT_DIR/compiler/parser.stele" \
        "$ROOT_DIR/compiler/lambda_lift.stele" \
        "$ROOT_DIR/compiler/codegen_c.stele" \
        "$ROOT_DIR/compiler/codegen_aarch64.stele" \
        "$ROOT_DIR/compiler/codegen_x86.stele" \
        "$ROOT_DIR/compiler/main.stele" > "$compiler_src"

    local c_out="${compiler_src%.stele}.c"
    if ! "$STELE_HS" "$compiler_src" >/dev/null 2>&1; then
        echo "WARNING: Failed to compile self-hosted compiler, skipping those tests"
        rm -f "$compiler_src" "$c_out"
        return 1
    fi

    local bin_out="$ROOT_DIR/.build/gen0_compiler"
    mkdir -p "$ROOT_DIR/.build"
    if ! cc "${CC_FLAGS[@]}" -o "$bin_out" "$c_out" 2>/dev/null; then
        echo "WARNING: Failed to build self-hosted compiler binary, skipping those tests"
        rm -f "$compiler_src" "$c_out"
        return 1
    fi
    rm -f "$compiler_src" "$c_out"
    echo "$bin_out"
}

# ── Positive tests: compile, run, compare output ──────────────────

run_positive_test_hs_c() {
    local src="$1"
    local name
    name="$(basename "$src" .stele)"
    local expected_file="${src%.stele}.expected"

    TOTAL=$((TOTAL + 1))
    echo -n "  [+] ${name} (haskell/c) ... "

    if [[ ! -f "$expected_file" ]]; then
        echo "SKIP (no .expected file)"
        return
    fi

    local expected
    expected="$(cat "$expected_file")"

    # Use --run to compile and run in one step
    local actual
    if ! actual=$("$STELE_HS" --run "$src" 2>&1); then
        echo "FAIL (compile+run failed)"
        FAIL=$((FAIL + 1))
        return
    fi

    if [[ "$actual" == "$expected" ]]; then
        echo "PASS"
        PASS=$((PASS + 1))
    else
        echo "FAIL"
        echo "    Expected: $(echo "$expected" | head -3)"
        echo "    Actual:   $(echo "$actual" | head -3)"
        FAIL=$((FAIL + 1))
    fi
    # Clean up generated files
    rm -f "${src%.stele}.c" "${src%.stele}"
}

run_positive_test_hs_native() {
    local src="$1"
    local target="$2"
    local name
    name="$(basename "$src" .stele)"
    local expected_file="${src%.stele}.expected"

    TOTAL=$((TOTAL + 1))
    echo -n "  [+] ${name} (haskell/${target}) ... "

    if [[ ! -f "$expected_file" ]]; then
        echo "SKIP (no .expected file)"
        return
    fi

    local expected
    expected="$(cat "$expected_file")"

    local actual
    if ! actual=$("$STELE_HS" --native --target "$target" --run "$src" 2>&1); then
        echo "FAIL (native compile+run failed)"
        echo "    Output: $(echo "$actual" | head -5)"
        FAIL=$((FAIL + 1))
        rm -f "${src%.stele}.s" "${src%.stele}_rt.c" "${src%.stele}"
        return
    fi

    rm -f "${src%.stele}.s" "${src%.stele}_rt.c" "${src%.stele}"

    if [[ "$actual" == "$expected" ]]; then
        echo "PASS"
        PASS=$((PASS + 1))
    else
        echo "FAIL"
        echo "    Expected: $(echo "$expected" | head -3)"
        echo "    Actual:   $(echo "$actual" | head -3)"
        FAIL=$((FAIL + 1))
    fi
}

run_positive_test_selfhost() {
    local src="$1"
    local compiler_bin="$2"
    local name
    name="$(basename "$src" .stele)"
    local expected_file="${src%.stele}.expected"

    TOTAL=$((TOTAL + 1))
    echo -n "  [+] ${name} (self-hosted/c) ... "

    if [[ ! -f "$expected_file" ]]; then
        echo "SKIP (no .expected file)"
        return
    fi

    local expected
    expected="$(cat "$expected_file")"

    local c_out
    c_out="$(mktemp /tmp/stele_test_XXXXXX.c)"
    local bin_out
    bin_out="$(mktemp /tmp/stele_test_XXXXXX)"

    # Compile .stele -> .c via self-hosted compiler
    if ! "$compiler_bin" "$src" "$c_out" 2>/dev/null; then
        echo "FAIL (self-hosted compilation failed)"
        rm -f "$c_out" "$bin_out"
        FAIL=$((FAIL + 1))
        return
    fi

    # Compile .c -> binary
    if ! cc "${CC_FLAGS[@]}" -o "$bin_out" "$c_out" 2>/dev/null; then
        echo "FAIL (cc failed)"
        rm -f "$c_out" "$bin_out"
        FAIL=$((FAIL + 1))
        return
    fi

    local actual
    actual=$("$bin_out" 2>&1) || true
    rm -f "$c_out" "$bin_out"

    if [[ "$actual" == "$expected" ]]; then
        echo "PASS"
        PASS=$((PASS + 1))
    else
        echo "FAIL"
        echo "    Expected: $(echo "$expected" | head -3)"
        echo "    Actual:   $(echo "$actual" | head -3)"
        FAIL=$((FAIL + 1))
    fi
}

# ── Negative tests: must fail to compile ──────────────────────────

run_negative_test() {
    local src="$1"
    local name
    name="$(basename "$src" .stele)"
    local error_file="${src%.stele}.expected_error"

    TOTAL=$((TOTAL + 1))
    echo -n "  [-] ${name} (haskell) ... "

    if [[ ! -f "$error_file" ]]; then
        echo "SKIP (no .expected_error file)"
        return
    fi

    local expected_error
    expected_error="$(cat "$error_file")"

    local stderr_out
    stderr_out="$(mktemp /tmp/stele_stderr_XXXXXX)"

    # Compile .stele (should FAIL)
    if "$STELE_HS" --run "$src" >/dev/null 2>"$stderr_out"; then
        echo "FAIL (compilation succeeded, expected failure)"
        rm -f "$stderr_out" "${src%.stele}.c" "${src%.stele}"
        FAIL=$((FAIL + 1))
        return
    fi

    local actual_stderr
    actual_stderr="$(cat "$stderr_out")"
    rm -f "$stderr_out" "${src%.stele}.c" "${src%.stele}"

    if echo "$actual_stderr" | grep -qi "$expected_error"; then
        echo "PASS"
        PASS=$((PASS + 1))
    else
        echo "FAIL (wrong error message)"
        echo "    Expected to contain: $expected_error"
        echo "    Actual stderr: $(echo "$actual_stderr" | head -3)"
        FAIL=$((FAIL + 1))
    fi
}

# ── Run all tests ─────────────────────────────────────────────────

echo ""
echo "=== Haskell compiler: C backend ==="
for test_file in "$ROOT_DIR"/tests/positive/*.stele; do
    [[ -f "$test_file" ]] && run_positive_test_hs_c "$test_file"
done

for target in "${NATIVE_TARGETS[@]}"; do
    echo ""
    echo "=== Haskell compiler: $target backend ==="
    for test_file in "$ROOT_DIR"/tests/positive/*.stele; do
        [[ -f "$test_file" ]] && run_positive_test_hs_native "$test_file" "$target"
    done
done

echo ""
echo "=== Self-hosted compiler: C backend ==="
SELF_HOSTED_BIN=""
if SELF_HOSTED_BIN="$(build_self_hosted)"; then
    for test_file in "$ROOT_DIR"/tests/positive/*.stele; do
        [[ -f "$test_file" ]] && run_positive_test_selfhost "$test_file" "$SELF_HOSTED_BIN"
    done
else
    echo "  (skipped)"
fi

echo ""
echo "=== Negative tests (should fail to compile) ==="
for test_file in "$ROOT_DIR"/tests/negative/*.stele; do
    [[ -f "$test_file" ]] && run_negative_test "$test_file"
done

# ── Clean up ──────────────────────────────────────────────────────
rm -f "$ROOT_DIR/.build/gen0_compiler" 2>/dev/null || true
rmdir "$ROOT_DIR/.build" 2>/dev/null || true

# ── Summary ───────────────────────────────────────────────────────

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
