#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
COMPILER_DIR="$ROOT_DIR/examples/compiler"
COMPILER_BIN="${COMPILER_BIN:-$COMPILER_DIR/compiler}"
STELA_BIN="${STELA_BIN:-$COMPILER_DIR/stela}"
HOST_OS="$(uname -s)"
HOST_ARCH="$(uname -m)"

if [[ ! -x "$COMPILER_BIN" ]]; then
  echo "Missing compiler binary: $COMPILER_BIN"
  echo "Build it first:"
  echo "  cabal run stele -- $COMPILER_DIR/compiler.stele"
  echo "  cc -O1 -o $COMPILER_DIR/compiler $COMPILER_DIR/compiler.c"
  exit 1
fi

if [[ ! -x "$STELA_BIN" ]]; then
  echo "Missing stela binary: $STELA_BIN"
  echo "Build it first:"
  echo "  (cd $COMPILER_DIR && ./compiler stela.stele stela.c)"
  echo "  cc -O1 -o $COMPILER_DIR/stela $COMPILER_DIR/stela.c"
  exit 1
fi

run_suite() {
  local action="$1"
  local mode="$2"
  echo "== stdlib suite: action=$action mode=$mode =="
  "$STELA_BIN" "$action" ../../stdlib/tests/assert_test.stele --lib assert --compiler "$COMPILER_BIN" --mode "$mode" --no-sandbox
  "$STELA_BIN" "$action" ../../stdlib/tests/cli_test.stele --lib cli --compiler "$COMPILER_BIN" --mode "$mode" --no-sandbox
  "$STELA_BIN" "$action" ../../stdlib/tests/math_test.stele --lib math --compiler "$COMPILER_BIN" --mode "$mode" --no-sandbox
  "$STELA_BIN" "$action" ../../stdlib/tests/concurrency_test.stele --lib concurrency --compiler "$COMPILER_BIN" --mode "$mode" --no-sandbox
  "$STELA_BIN" "$action" ../../stdlib/tests/strings_test.stele --lib assert --lib strings --compiler "$COMPILER_BIN" --mode "$mode" --no-sandbox
  "$STELA_BIN" "$action" ../../stdlib/tests/path_test.stele --lib assert --lib path --compiler "$COMPILER_BIN" --mode "$mode" --no-sandbox
}

(
  cd "$COMPILER_DIR"

  "$STELA_BIN" package-lib ../../stdlib/cli.stele --name cli >/dev/null
  "$STELA_BIN" package-lib ../../stdlib/math.stele --name math >/dev/null
  "$STELA_BIN" package-lib ../../stdlib/concurrency.stele --name concurrency >/dev/null
  "$STELA_BIN" package-lib ../../stdlib/assert.stele --name assert >/dev/null
  "$STELA_BIN" package-lib ../../stdlib/strings.stele --name strings >/dev/null
  "$STELA_BIN" package-lib ../../stdlib/path.stele --name path >/dev/null

  # C mode: compile/link/run all tests.
  run_suite test c

  # AArch64 mode: always build; run on arm64 hosts.
  run_suite build asm
  if [[ "$HOST_ARCH" == "arm64" ]]; then
    run_suite test asm
  fi

  # macOS x86 mode: test on Darwin (native x86_64 or via Rosetta on arm64).
  if [[ "$HOST_OS" == "Darwin" ]]; then
    run_suite test x86
  else
    run_suite check x86
  fi

  # System V x86_64 mode: build on Linux, syntax-check elsewhere.
  if [[ "$HOST_OS" == "Linux" ]]; then
    run_suite build x86-linux
    if [[ "$HOST_ARCH" == "x86_64" ]]; then
      run_suite test x86-linux
    fi
  else
    run_suite check x86-linux
  fi
)

echo "stdlib target matrix passed"
