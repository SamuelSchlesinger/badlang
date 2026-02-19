#!/usr/bin/env bash
# Check that the 4 runtime copies stay in sync.
# The C-backend runtime uses 'static' linkage; the native-backend runtime
# uses external linkage.  We strip the 'static ' prefix and diff the rest.
set -euo pipefail

cd "$(dirname "$0")/.."

RUNTIME_C="runtime.c"
RUNTIME_NATIVE="runtime/runtime.c"

strip_static() {
    sed 's/^static //; s/^static Value/Value/; s/^static void/void/; s/^static int /int /; s/^static char/char/' "$1"
}

# Compare the two standalone C files (ignoring static linkage and the
# make_record_with_fields / stele_match_fail functions that only exist in
# the native runtime).
DIFF_C=$(diff <(strip_static "$RUNTIME_C") \
              <(strip_static "$RUNTIME_NATIVE" | \
                sed '/^Value\* make_record_with_fields/,/^}$/d; /^void stele_match_fail/,/^}$/d; /^\/\* ── stele runtime for native/s/.*/\/* ── stele runtime (reference counted) ────────────────────── *\//' | \
                sed '/^\/\* All functions have external linkage/d; /^\/\* generated assembly\./d') \
         || true)

if [ -n "$DIFF_C" ]; then
    echo "FAIL: runtime.c and runtime/runtime.c have diverged!"
    echo "$DIFF_C" | head -40
    echo "..."
    exit 1
fi

echo "PASS: standalone runtime files are in sync"
