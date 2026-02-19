#!/usr/bin/env bash
# Compile and run each non-interactive example program, verifying expected output.
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

# Build the Haskell compiler
echo "Building Haskell compiler..."
(cd "$ROOT_DIR/bootstrap/haskell" && cabal build exe:stele) >/dev/null 2>&1

PASS=0
FAIL=0
TOTAL=0

compile_and_run() {
    local name="$1"
    local expected="$2"
    local src="$ROOT_DIR/examples/${name}.stele"
    local c_out="$ROOT_DIR/examples/${name}.c"
    local bin_out
    bin_out="$(mktemp)"

    TOTAL=$((TOTAL + 1))
    echo -n "Testing ${name}.stele ... "

    # Compile .stele -> .c via the Haskell reference compiler
    if ! (cd "$ROOT_DIR/bootstrap/haskell" && cabal run exe:stele -- "$src") >/dev/null 2>&1; then
        echo "FAIL (compilation to C failed)"
        FAIL=$((FAIL + 1))
        return
    fi

    # Compile .c -> binary
    if ! cc "${CC_FLAGS[@]}" -o "$bin_out" "$c_out"; then
        echo "FAIL (cc failed)"
        rm -f "$c_out" "$bin_out"
        FAIL=$((FAIL + 1))
        return
    fi

    # Run and capture output
    local actual
    actual=$("$bin_out" 2>&1) || true

    # Clean up
    rm -f "$c_out" "$bin_out"

    # Compare
    if [[ "$actual" == "$expected" ]]; then
        echo "PASS"
        PASS=$((PASS + 1))
    else
        echo "FAIL"
        echo "  Expected:"
        echo "$expected" | head -5 | sed 's/^/    /'
        echo "  Actual:"
        echo "$actual" | head -5 | sed 's/^/    /'
        FAIL=$((FAIL + 1))
    fi
}

# ── Expected outputs ────────────────────────────────────────────

compile_and_run "hello" "$(printf '25\n3628800')"

compile_and_run "match" "$(printf 'fizz\nbuzz\nfizzbuzz\n')"

compile_and_run "oneof" "$(printf '75\n12\n0\ncircle\nrect\npoint\nred\ngreen\nblue\nit'\''s a circle')"

compile_and_run "mutual" "$(printf '6\n6\n111\n16\n6\n7\n11\n61\n21\n21\n6765\n832040')"

compile_and_run "subtyping" "$(printf '25\n5\n14\n0\n1\n2\n3\n200')"

compile_and_run "test_strings" "$(printf '11\n104\n111\nhello\nfoobar\n42\nA\n0\n-1\n1\n1\n0')"

# ── Summary ─────────────────────────────────────────────────────

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
