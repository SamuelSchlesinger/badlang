#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
DEFAULT_COMPILER_BIN="$ROOT_DIR/compiler"
DEFAULT_STELA_BIN="$ROOT_DIR/stela"
COMPILER_BIN="${COMPILER_BIN:-$DEFAULT_COMPILER_BIN}"
STELA_BIN="${STELA_BIN:-$DEFAULT_STELA_BIN}"
HOST_OS="$(uname -s)"
HOST_ARCH="$(uname -m)"

rebuild_compiler() {
  if ! command -v cabal >/dev/null 2>&1; then
    echo "Missing compiler binary: $COMPILER_BIN"
    echo "cabal is required to rebuild the default self-hosted compiler."
    exit 1
  fi
  echo "Rebuilding compiler binary: $COMPILER_BIN"
  (cd "$ROOT_DIR/bootstrap/haskell" && cabal run stele -- "$ROOT_DIR/compiler.stele") >/dev/null
  cc -O1 -o "$COMPILER_BIN" "$ROOT_DIR/compiler.c"
}

rebuild_stela() {
  echo "Rebuilding stela binary: $STELA_BIN"
  (cd "$ROOT_DIR" && "$COMPILER_BIN" stela.stele stela.c)
  cc -O1 -o "$STELA_BIN" "$ROOT_DIR/stela.c"
}

compiler_needs_rebuild() {
  if [[ ! -x "$COMPILER_BIN" ]]; then
    return 0
  fi

  local src
  for src in "$ROOT_DIR/compiler.stele" "$ROOT_DIR"/bootstrap/haskell/app/*.hs "$ROOT_DIR"/bootstrap/haskell/src/Stele/*.hs; do
    if [[ "$src" -nt "$COMPILER_BIN" ]]; then
      return 0
    fi
  done

  return 1
}

if [[ "$COMPILER_BIN" == "$DEFAULT_COMPILER_BIN" ]]; then
  if compiler_needs_rebuild; then
    rebuild_compiler
  fi
elif [[ ! -x "$COMPILER_BIN" ]]; then
  echo "Missing compiler binary: $COMPILER_BIN"
  exit 1
fi

if [[ "$STELA_BIN" == "$DEFAULT_STELA_BIN" ]]; then
  if [[ ! -x "$STELA_BIN" || "$ROOT_DIR/stela.stele" -nt "$STELA_BIN" || "$COMPILER_BIN" -nt "$STELA_BIN" ]]; then
    rebuild_stela
  fi
elif [[ ! -x "$STELA_BIN" ]]; then
  echo "Missing stela binary: $STELA_BIN"
  exit 1
fi

run_suite() {
  local action="$1"
  local mode="$2"
  echo "== stdlib suite: action=$action mode=$mode =="
  "$STELA_BIN" "$action" stdlib/tests/assert_test.stele --lib assert --compiler "$COMPILER_BIN" --mode "$mode" --no-sandbox
  "$STELA_BIN" "$action" stdlib/tests/cli_test.stele --lib cli --compiler "$COMPILER_BIN" --mode "$mode" --no-sandbox
  "$STELA_BIN" "$action" stdlib/tests/math_test.stele --lib math --compiler "$COMPILER_BIN" --mode "$mode" --no-sandbox
  "$STELA_BIN" "$action" stdlib/tests/concurrency_test.stele --lib concurrency --compiler "$COMPILER_BIN" --mode "$mode" --no-sandbox
  "$STELA_BIN" "$action" stdlib/tests/strings_test.stele --lib assert --lib strings --compiler "$COMPILER_BIN" --mode "$mode" --no-sandbox
  "$STELA_BIN" "$action" stdlib/tests/path_test.stele --lib assert --lib path --compiler "$COMPILER_BIN" --mode "$mode" --no-sandbox
}

(
  cd "$ROOT_DIR"

  "$STELA_BIN" package-lib stdlib/cli.stele --name cli >/dev/null
  "$STELA_BIN" package-lib stdlib/math.stele --name math >/dev/null
  "$STELA_BIN" package-lib stdlib/concurrency.stele --name concurrency >/dev/null
  "$STELA_BIN" package-lib stdlib/assert.stele --name assert >/dev/null
  "$STELA_BIN" package-lib stdlib/strings.stele --name strings >/dev/null
  "$STELA_BIN" package-lib stdlib/path.stele --name path >/dev/null

  # C mode: compile/link/run all tests.
  run_suite test c

  # AArch64 mode: always build; run on arm64 hosts.
  run_suite build asm
  if [[ "$HOST_ARCH" == "arm64" ]]; then
    run_suite test asm
  fi

  # AArch64 Linux mode: run on Linux arm64/aarch64, syntax-check elsewhere.
  if [[ "$HOST_OS" == "Linux" && ( "$HOST_ARCH" == "aarch64" || "$HOST_ARCH" == "arm64" ) ]]; then
    run_suite test asm-linux
  else
    run_suite check asm-linux
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
