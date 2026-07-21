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
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Haskell CLI compilation writes next to the source. Stage the suites so tests
# never overwrite or delete checked-in fixtures and module dependencies remain
# adjacent to their importers.
mkdir -p "$WORK_DIR/compiler"
cp "$ROOT_DIR"/compiler/*.stele "$WORK_DIR/compiler/"
cp -R "$ROOT_DIR/tests" "$WORK_DIR/tests"

staged_source() {
    local src="$1"
    echo "$WORK_DIR/${src#"$ROOT_DIR/"}"
}

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
        # Apple Silicon can build and run x86_64 binaries through Rosetta.
        if /usr/bin/arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
            NATIVE_TARGETS+=("x86_64-macos")
        fi
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
    local compiler_src="$WORK_DIR/compiler/main.stele"
    local c_out="$WORK_DIR/compiler/main.c"

    if ! "$STELE_HS" "$compiler_src" >/dev/null 2>&1; then
        echo "ERROR: Failed to compile self-hosted compiler"
        return 1
    fi

    local bin_out="$WORK_DIR/gen0_compiler"
    if ! cc "${CC_FLAGS[@]}" -o "$bin_out" "$c_out" 2>/dev/null; then
        echo "ERROR: Failed to build self-hosted compiler binary"
        return 1
    fi
    echo "$bin_out"
}

# ── Positive tests: compile, run, compare output ──────────────────

run_positive_test_hs_c() {
    local src="$1"
    local name
    name="$(basename "$src" .stele)"
    local expected_file="${src%.stele}.expected"

    if [[ ! -f "$expected_file" ]]; then
        echo "ERROR: missing expectation for $src"
        FAIL=$((FAIL + 1))
        return
    fi

    TOTAL=$((TOTAL + 1))
    echo -n "  [+] ${name} (haskell/c) ... "

    local expected
    expected="$(cat "$expected_file")"

    # Use --run to compile and run in one step
    local actual
    local staged
    staged="$(staged_source "$src")"
    if ! actual=$("$STELE_HS" --run "$staged" 2>&1); then
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
}

run_positive_test_hs_native() {
    local src="$1"
    local target="$2"
    local name
    name="$(basename "$src" .stele)"
    local expected_file="${src%.stele}.expected"

    if [[ ! -f "$expected_file" ]]; then
        echo "ERROR: missing expectation for $src"
        FAIL=$((FAIL + 1))
        return
    fi

    TOTAL=$((TOTAL + 1))
    echo -n "  [+] ${name} (haskell/${target}) ... "

    local expected
    expected="$(cat "$expected_file")"

    local actual
    local staged
    staged="$(staged_source "$src")"
    if ! actual=$("$STELE_HS" --native --target "$target" --run "$staged" 2>&1); then
        echo "FAIL (native compile+run failed)"
        echo "    Output: $(echo "$actual" | head -5)"
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
}

run_positive_test_selfhost() {
    local src="$1"
    local compiler_bin="$2"
    local name
    name="$(basename "$src" .stele)"
    local expected_file="${src%.stele}.expected"

    if [[ ! -f "$expected_file" ]]; then
        echo "ERROR: missing expectation for $src"
        FAIL=$((FAIL + 1))
        return
    fi

    TOTAL=$((TOTAL + 1))
    echo -n "  [+] ${name} (self-hosted/c) ... "

    local expected
    expected="$(cat "$expected_file")"

    local c_out
    c_out="$(mktemp "$WORK_DIR/stele_test_XXXXXX.c")"
    local bin_out
    bin_out="$(mktemp "$WORK_DIR/stele_test_XXXXXX")"

    # Compile .stele -> .c via self-hosted compiler
    if ! (cd "$ROOT_DIR" && "$compiler_bin" "$src" "$c_out") 2>/dev/null; then
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
    if ! actual=$("$bin_out" 2>&1); then
        echo "FAIL (program exited non-zero)"
        rm -f "$c_out" "$bin_out"
        FAIL=$((FAIL + 1))
        return
    fi
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

native_mode_for_target() {
    case "$1" in
        aarch64-macos) echo "asm" ;;
        aarch64-linux) echo "asm-linux" ;;
        x86_64-macos) echo "x86" ;;
        x86_64-linux) echo "x86-linux" ;;
        *) return 1 ;;
    esac
}

run_positive_test_selfhost_native() {
    local src="$1"
    local compiler_bin="$2"
    local target="$3"
    local name
    name="$(basename "$src" .stele)"
    local expected_file="${src%.stele}.expected"

    if [[ ! -f "$expected_file" ]]; then
        echo "ERROR: missing expectation for $src"
        FAIL=$((FAIL + 1))
        return
    fi

    TOTAL=$((TOTAL + 1))
    echo -n "  [+] ${name} (self-hosted/${target}) ... "

    local expected
    expected="$(cat "$expected_file")"
    local mode
    mode="$(native_mode_for_target "$target")"
    local asm_out="$WORK_DIR/self_native_${TOTAL}.s"
    local bin_out="$WORK_DIR/self_native_${TOTAL}"

    if ! (cd "$ROOT_DIR" && "$compiler_bin" "$src" "$asm_out" "$mode") 2>/dev/null; then
        echo "FAIL (self-hosted native compilation failed)"
        FAIL=$((FAIL + 1))
        return
    fi

    local link_flags=("${CC_FLAGS[@]}")
    if [[ "$target" == "x86_64-macos" ]]; then
        link_flags+=("-arch" "x86_64")
    fi
    if ! cc "${link_flags[@]}" -o "$bin_out" "$asm_out" "$ROOT_DIR/runtime/runtime.c" 2>/dev/null; then
        echo "FAIL (native link failed)"
        FAIL=$((FAIL + 1))
        return
    fi

    local actual
    if ! actual=$("$bin_out" 2>&1); then
        echo "FAIL (program exited non-zero)"
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
}

# ── Negative tests: must fail to compile ──────────────────────────

run_negative_test() {
    local src="$1"
    local name
    name="$(basename "$src" .stele)"
    local error_file="${src%.stele}.expected_error"

    if [[ ! -f "$error_file" ]]; then
        echo "ERROR: missing expectation for $src"
        FAIL=$((FAIL + 1))
        return
    fi

    TOTAL=$((TOTAL + 1))
    echo -n "  [-] ${name} (haskell) ... "

    local expected_error
    expected_error="$(cat "$error_file")"

    local stderr_out
    stderr_out="$(mktemp "$WORK_DIR/stele_stderr_XXXXXX")"
    local staged
    staged="$(staged_source "$src")"

    # Compile .stele (should FAIL)
    if "$STELE_HS" --run "$staged" >/dev/null 2>"$stderr_out"; then
        echo "FAIL (compilation succeeded, expected failure)"
        rm -f "$stderr_out"
        FAIL=$((FAIL + 1))
        return
    fi

    local actual_stderr
    actual_stderr="$(cat "$stderr_out")"
    rm -f "$stderr_out"

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

run_negative_test_self() {
    local src="$1"
    local compiler_bin="$2"
    local name
    name="$(basename "$src" .stele)"
    local error_file="${src%.stele}.expected_error"
    local expected_error="$(cat "$error_file")"
    local stderr_out="$WORK_DIR/self_negative_${TOTAL}.err"
    local output="$WORK_DIR/self_negative_${TOTAL}.c"

    TOTAL=$((TOTAL + 1))
    echo -n "  [-] ${name} (self-hosted) ... "
    if (cd "$ROOT_DIR" && "$compiler_bin" "$src" "$output") >/dev/null 2>"$stderr_out"; then
        echo "FAIL (compilation succeeded, expected failure)"
        FAIL=$((FAIL + 1))
        return
    fi
    if grep -qi "$expected_error" "$stderr_out"; then
        echo "PASS"
        PASS=$((PASS + 1))
    else
        echo "FAIL (wrong error message)"
        echo "    Expected to contain: $expected_error"
        echo "    Actual stderr: $(head -3 "$stderr_out")"
        FAIL=$((FAIL + 1))
    fi
}

check_runtime_error() {
    local label="$1"
    local expected="$2"
    local stderr_file="$3"
    if grep -qi "$expected" "$stderr_file"; then
        echo "PASS"
        PASS=$((PASS + 1))
    else
        echo "FAIL (wrong runtime error: $label)"
        echo "    Expected to contain: $expected"
        echo "    Actual stderr: $(head -3 "$stderr_file")"
        FAIL=$((FAIL + 1))
    fi
}

run_runtime_negative_hs_c() {
    local src="$1"
    local expected="$(cat "${src%.stele}.expected_error")"
    local staged="$(staged_source "$src")"
    local stderr_file="$WORK_DIR/runtime_hs_c_${TOTAL}.err"
    TOTAL=$((TOTAL + 1))
    echo -n "  [!] $(basename "$src" .stele) (haskell/c) ... "
    if "$STELE_HS" --run "$staged" >/dev/null 2>"$stderr_file"; then
        echo "FAIL (program succeeded, expected runtime failure)"
        FAIL=$((FAIL + 1))
        return
    fi
    check_runtime_error "haskell/c" "$expected" "$stderr_file"
}

run_runtime_negative_hs_native() {
    local src="$1"
    local target="$2"
    local expected="$(cat "${src%.stele}.expected_error")"
    local staged="$(staged_source "$src")"
    local stderr_file="$WORK_DIR/runtime_hs_native_${TOTAL}.err"
    TOTAL=$((TOTAL + 1))
    echo -n "  [!] $(basename "$src" .stele) (haskell/${target}) ... "
    if "$STELE_HS" --native --target "$target" --run "$staged" >/dev/null 2>"$stderr_file"; then
        echo "FAIL (program succeeded, expected runtime failure)"
        FAIL=$((FAIL + 1))
        return
    fi
    check_runtime_error "haskell/$target" "$expected" "$stderr_file"
}

run_runtime_negative_self_c() {
    local src="$1"
    local compiler_bin="$2"
    local expected="$(cat "${src%.stele}.expected_error")"
    local c_out="$WORK_DIR/runtime_self_${TOTAL}.c"
    local bin_out="$WORK_DIR/runtime_self_${TOTAL}"
    local stderr_file="$WORK_DIR/runtime_self_${TOTAL}.err"
    TOTAL=$((TOTAL + 1))
    echo -n "  [!] $(basename "$src" .stele) (self-hosted/c) ... "
    if ! (cd "$ROOT_DIR" && "$compiler_bin" "$src" "$c_out") 2>"$stderr_file"; then
        echo "FAIL (compilation failed before runtime)"
        FAIL=$((FAIL + 1))
        return
    fi
    if ! cc "${CC_FLAGS[@]}" -o "$bin_out" "$c_out" 2>"$stderr_file"; then
        echo "FAIL (C link failed)"
        FAIL=$((FAIL + 1))
        return
    fi
    if "$bin_out" >/dev/null 2>"$stderr_file"; then
        echo "FAIL (program succeeded, expected runtime failure)"
        FAIL=$((FAIL + 1))
        return
    fi
    check_runtime_error "self-hosted/c" "$expected" "$stderr_file"
}

run_runtime_negative_self_native() {
    local src="$1"
    local compiler_bin="$2"
    local target="$3"
    local expected="$(cat "${src%.stele}.expected_error")"
    local mode="$(native_mode_for_target "$target")"
    local asm_out="$WORK_DIR/runtime_self_native_${TOTAL}.s"
    local bin_out="$WORK_DIR/runtime_self_native_${TOTAL}"
    local stderr_file="$WORK_DIR/runtime_self_native_${TOTAL}.err"
    TOTAL=$((TOTAL + 1))
    echo -n "  [!] $(basename "$src" .stele) (self-hosted/${target}) ... "
    if ! (cd "$ROOT_DIR" && "$compiler_bin" "$src" "$asm_out" "$mode") 2>"$stderr_file"; then
        echo "FAIL (compilation failed before runtime)"
        FAIL=$((FAIL + 1))
        return
    fi
    local link_flags=("${CC_FLAGS[@]}")
    [[ "$target" == "x86_64-macos" ]] && link_flags+=("-arch" "x86_64")
    if ! cc "${link_flags[@]}" -o "$bin_out" "$asm_out" "$ROOT_DIR/runtime/runtime.c" 2>"$stderr_file"; then
        echo "FAIL (native link failed)"
        FAIL=$((FAIL + 1))
        return
    fi
    if "$bin_out" >/dev/null 2>"$stderr_file"; then
        echo "FAIL (program succeeded, expected runtime failure)"
        FAIL=$((FAIL + 1))
        return
    fi
    check_runtime_error "self-hosted/$target" "$expected" "$stderr_file"
}

check_embedded_test_output() {
    local label="$1"
    local expected="$2"
    local stdout_file="$3"
    local actual
    actual="$(cat "$stdout_file")"
    if [[ "$actual" == "$expected" ]]; then
        echo "PASS"
        PASS=$((PASS + 1))
    else
        echo "FAIL (embedded test body did not run: $label)"
        echo "    Expected: $expected"
        echo "    Actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

run_embedded_test_matrix() {
    local src="$ROOT_DIR/tests/positive/test_decl.stele"
    local staged="$(staged_source "$src")"
    local expected="$(cat "${src%.stele}.test_expected")"
    local compiler_bin="$1"
    local stdout_file="$WORK_DIR/embedded_hs.out"
    local stderr_file="$WORK_DIR/embedded_hs.err"

    TOTAL=$((TOTAL + 1))
    echo -n "  [t] test_decl (haskell/c test mode) ... "
    if ! "$STELE_HS" --test --run "$staged" >"$stdout_file" 2>"$stderr_file"; then
        echo "FAIL (test runner failed)"
        FAIL=$((FAIL + 1))
    elif ! grep -q "1/1 tests passed" "$stderr_file"; then
        echo "FAIL (missing test-runner summary)"
        FAIL=$((FAIL + 1))
    else
        check_embedded_test_output "haskell/c" "$expected" "$stdout_file"
    fi

    local c_out="$WORK_DIR/embedded_self.c"
    local bin_out="$WORK_DIR/embedded_self"
    TOTAL=$((TOTAL + 1))
    echo -n "  [t] test_decl (self-hosted/c test mode) ... "
    if ! (cd "$ROOT_DIR" && "$compiler_bin" "$src" "$c_out" test) 2>"$stderr_file" ||
       ! cc "${CC_FLAGS[@]}" -o "$bin_out" "$c_out" 2>"$stderr_file" ||
       ! "$bin_out" >"$stdout_file" 2>"$stderr_file"; then
        echo "FAIL (test runner failed)"
        FAIL=$((FAIL + 1))
    elif ! grep -q "1/1 tests passed" "$stderr_file"; then
        echo "FAIL (missing test-runner summary)"
        FAIL=$((FAIL + 1))
    else
        check_embedded_test_output "self-hosted/c" "$expected" "$stdout_file"
    fi

    local target
    for target in "${NATIVE_TARGETS[@]}"; do
        local mode="$(native_mode_for_target "$target")"
        local asm_out="$WORK_DIR/embedded_${mode}.s"
        local native_bin="$WORK_DIR/embedded_${mode}"
        local link_flags=("${CC_FLAGS[@]}")
        [[ "$target" == "x86_64-macos" ]] && link_flags+=("-arch" "x86_64")
        TOTAL=$((TOTAL + 1))
        echo -n "  [t] test_decl (self-hosted/${target} test mode) ... "
        if ! (cd "$ROOT_DIR" && "$compiler_bin" "$src" "$asm_out" "$mode" test) 2>"$stderr_file" ||
           ! cc "${link_flags[@]}" -o "$native_bin" "$asm_out" "$ROOT_DIR/runtime/runtime.c" 2>"$stderr_file" ||
           ! "$native_bin" >"$stdout_file" 2>"$stderr_file"; then
            echo "FAIL (native test runner failed)"
            FAIL=$((FAIL + 1))
        else
            check_embedded_test_output "self-hosted/$target" "$expected" "$stdout_file"
        fi
    done
}

# ── Run all tests ─────────────────────────────────────────────────

echo ""
echo "=== Haskell compiler: C backend ==="
POSITIVE_TESTS=()
while IFS= read -r expected_file; do
    source_file="${expected_file%.expected}.stele"
    [[ -f "$source_file" ]] && POSITIVE_TESTS+=("$source_file")
done < <(find "$ROOT_DIR/tests/positive" -type f -name '*.expected' | sort)

for test_file in "${POSITIVE_TESTS[@]}"; do
    run_positive_test_hs_c "$test_file"
done

for target in "${NATIVE_TARGETS[@]}"; do
    echo ""
    echo "=== Haskell compiler: $target backend ==="
    for test_file in "${POSITIVE_TESTS[@]}"; do
        run_positive_test_hs_native "$test_file" "$target"
    done
done

echo ""
echo "=== Self-hosted compiler: C backend ==="
SELF_HOSTED_BIN=""
if SELF_HOSTED_BIN="$(build_self_hosted)"; then
    for test_file in "${POSITIVE_TESTS[@]}"; do
        run_positive_test_selfhost "$test_file" "$SELF_HOSTED_BIN"
    done
    for target in "${NATIVE_TARGETS[@]}"; do
        echo ""
        echo "=== Self-hosted compiler: $target backend ==="
        for test_file in "${POSITIVE_TESTS[@]}"; do
            run_positive_test_selfhost_native "$test_file" "$SELF_HOSTED_BIN" "$target"
        done
    done
else
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    echo "  FAIL (self-hosted compiler is required)"
fi

echo ""
echo "=== Negative tests (should fail to compile) ==="
while IFS= read -r error_file; do
    test_file="${error_file%.expected_error}.stele"
    if [[ ! -f "$test_file" ]]; then
        echo "ERROR: missing source for $error_file"
        TOTAL=$((TOTAL + 1))
        FAIL=$((FAIL + 1))
        continue
    fi
    run_negative_test "$test_file"
    if [[ -n "$SELF_HOSTED_BIN" && -x "$SELF_HOSTED_BIN" ]]; then
        run_negative_test_self "$test_file" "$SELF_HOSTED_BIN"
    fi
done < <(find "$ROOT_DIR/tests/negative" -type f -name '*.expected_error' | sort)

echo ""
echo "=== Runtime failures (must fail consistently) ==="
for test_file in "$ROOT_DIR"/tests/runtime-negative/*.stele; do
    [[ -f "$test_file" ]] || continue
    run_runtime_negative_hs_c "$test_file"
    for target in "${NATIVE_TARGETS[@]}"; do
        run_runtime_negative_hs_native "$test_file" "$target"
    done
    if [[ -n "$SELF_HOSTED_BIN" && -x "$SELF_HOSTED_BIN" ]]; then
        run_runtime_negative_self_c "$test_file" "$SELF_HOSTED_BIN"
        for target in "${NATIVE_TARGETS[@]}"; do
            run_runtime_negative_self_native "$test_file" "$SELF_HOSTED_BIN" "$target"
        done
    fi
done

if [[ -n "$SELF_HOSTED_BIN" && -x "$SELF_HOSTED_BIN" ]]; then
    echo ""
    echo "=== Embedded test mode ==="
    run_embedded_test_matrix "$SELF_HOSTED_BIN"
fi

# ── Summary ───────────────────────────────────────────────────────

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
