# Comprehensive Testing Plan for Stele

## Current State

### What Exists Today
1. **Compiler integration tests** (`ci/test-compiler.sh`): 8 positive + 4 negative tests run across Haskell C backend, Haskell native backends, and self-hosted C backend (28 total test runs)
2. **Stdlib tests** (`stdlib/tests/run.sh`): 6 test files (assert, cli, math, concurrency, strings, path) run across all 5 backend modes via `stela test`
3. **Bootstrap verification** (`bootstrap.sh`): Fixed-point test that compiles the compiler with itself 3 times and verifies output converges
4. **Example programs** (`ci/test-examples.sh`): Compiles and runs example programs

### Gaps
- No **unit tests** for individual compiler modules (util, lexer, parser, codegen)
- No tests for the **self-hosted compiler's AArch64/x86 backends**
- No **fuzz testing** or property-based testing
- No **performance regression** tracking
- Tests cannot be **co-located** with the code they test
- No test discovery — all tests are manually enumerated in bash scripts

---

## Testing Layers

### Layer 1: Language-Level Unit Tests (Embedded `test` Blocks)

**Goal:** Test individual functions in each compiler module from within the same `.stele` file.

**Prerequisite:** Implement the `test` declaration (see `docs/design-embedded-tests.md`).

#### compiler/util.stele — Utility Functions
| Test | What it covers |
|------|----------------|
| `is_digit` boundary values | Character classification at ASCII boundaries (47, 48, 57, 58) |
| `is_alpha` boundary values | Uppercase/lowercase letter boundaries |
| `is_alnum` combines digit+alpha | Composed classification |
| `is_whitespace` recognizes all 4 chars | Space, newline, CR, tab |
| `is_ident_char` combines alnum+underscore | Identifier character test |
| `str_eq` equal and unequal strings | String comparison wrapper |
| `starts_with` prefix matching | Prefix present, absent, longer than string |
| `str_to_int` positive, negative, zero | String-to-integer conversion |
| `nil`, `cons`, `is_nil` | Empty/non-empty list construction |
| `list_head`, `list_tail` | List destructuring |
| `list_len` empty and non-empty | Length computation |
| `list_reverse` | List reversal |
| `list_nth` | Indexed access |
| `cat3`, `cat4`, `cat5` | Multi-string concatenation |
| `wrap` | Prefix/suffix wrapping |

**Estimated:** ~20 test blocks, ~80 assertions

#### compiler/lexer.stele — Tokenizer
| Test | What it covers |
|------|----------------|
| Integer literals | `0`, `42`, negative (unary minus) |
| String literals | Simple, empty, with escapes (`\\n`, `\\t`, `\\"`) |
| Keywords | All 11 keywords tokenize to their keyword type |
| Identifiers | Simple, with underscores, single-char |
| Operators | All arithmetic, comparison, boolean operators |
| Record delimiters | `{|`, `|}` |
| Punctuation | `(`, `)`, `,`, `:`, `.`, `=>`, `=` |
| Whitespace skipping | Spaces, tabs, newlines between tokens |
| Comments | `--` line comments are skipped |
| Token positions | `line` and `col` fields are correct |
| EOF | EOF token at end of input |
| Edge cases | Empty input, only whitespace, only comments |

**Estimated:** ~20 test blocks, ~100 assertions

#### compiler/parser.stele — Parser
| Test | What it covers |
|------|----------------|
| Parse integer literal | AST node tag and value |
| Parse string literal | AST node tag and value |
| Parse variable reference | AST node tag and name |
| Parse binary operations | All operators, precedence |
| Parse unary negation | `-x` |
| Parse field access | `x.field` |
| Parse record literal | `{| x: 1, y: 2 |}` |
| Parse function call | `f {| x: 1 |}` |
| Parse let-in expression | `let x = 1 in x + 1` |
| Parse match expression | `match x case 0 => ... end` |
| Parse fn declaration | Single and multiple case clauses |
| Parse do declaration | With let, print, expr statements |
| Parse struct declaration | With typed fields |
| Parse pattern matching | Variable, wildcard, literal, record patterns |
| Parse full program | Multiple declarations |

**Estimated:** ~25 test blocks, ~120 assertions

#### compiler/codegen_c.stele — C Code Generator

Unit-testing codegen is harder because the output is C code strings. The approach is to test individual helper functions:

| Test | What it covers |
|------|----------------|
| `c_name` | Identifier mangling (reserved words get prefix) |
| `c_string` | String literal escaping |
| `c_escape_char` | Individual character escaping |
| `emit_binop_c` | Operator code generation |
| `fresh_var` | Counter-based variable naming |
| `is_builtin_fn` | Builtin function detection |

**Estimated:** ~10 test blocks, ~40 assertions

### Layer 2: Integration Tests (Compile-and-Run)

**Goal:** Verify end-to-end compilation and execution across all backends.

#### Positive Tests (`tests/positive/`)

Current tests (8):
- `empty_program` — Minimal program
- `int_arithmetic` — Arithmetic operations
- `string_ops` — String builtins
- `pattern_matching` — Pattern match dispatch
- `nested_let` — Let binding scoping
- `records` — Record construction and access
- `comparisons` — Comparison and boolean operators
- `mutual_recursion` — Mutual recursion

Additional tests to add:
| Test | What it covers |
|------|----------------|
| `higher_order` | Passing functions as record fields, callback patterns |
| `struct_decl` | Struct declarations (ensure they parse without error) |
| `large_record` | Records with 10+ fields |
| `deep_nesting` | Deeply nested let/match (20+ levels) |
| `string_escapes` | `\n`, `\t`, `\\`, `\"` in string literals |
| `tail_calls` | TCO verification (count to 100,000) |
| `multiclause_fn` | Functions with 5+ case clauses |
| `shadowing` | Variable shadowing in let bindings |
| `readln_readint` | I/O builtins (with piped input) |
| `builtin_fns` | All builtin functions (strlen, concat, char_at, etc.) |
| `checked_arithmetic` | Verify overflow detection triggers error |
| `field_access_chain` | `x.a.b.c` nested field access |
| `empty_record` | `{| |}` empty record |
| `wildcard_pattern` | `_` pattern in various positions |

**Estimated:** 14 new tests + 8 existing = 22 positive tests

#### Negative Tests (`tests/negative/`)

Current tests (4):
- `unclosed_record` — Missing `|}`
- `missing_end` — Missing `end` keyword
- `bad_operator` — Dangling operator
- `missing_case` — fn without case

Additional tests to add:
| Test | What it covers |
|------|----------------|
| `unclosed_string` | String literal without closing `"` |
| `unclosed_paren` | Missing `)` |
| `duplicate_field` | `{| x: 1, x: 2 |}` (if enforced) |
| `empty_match` | `match x end` with no cases |
| `bad_pattern` | Invalid pattern syntax |
| `missing_arrow` | `case x` without `=>` |
| `unexpected_eof` | Truncated input mid-expression |
| `bad_escape` | Invalid escape sequence in string |
| `nested_fn` | `fn` inside `fn` (not allowed) |
| `missing_do_name` | `do end` without name |

**Estimated:** 10 new tests + 4 existing = 14 negative tests

#### Backend Matrix

Every positive test runs across all available backends:

| Backend | Compiler | Platform |
|---------|----------|----------|
| C | Haskell bootstrap | All |
| C | Self-hosted | All |
| AArch64 macOS | Haskell bootstrap | macOS arm64 |
| AArch64 Linux | Haskell bootstrap | Linux aarch64 |
| x86_64 macOS | Haskell bootstrap | macOS (Rosetta) |
| x86_64 Linux | Haskell bootstrap | Linux x86_64 |
| AArch64 macOS | Self-hosted | macOS arm64 |
| AArch64 Linux | Self-hosted | Linux aarch64 |
| x86_64 macOS | Self-hosted | macOS |
| x86_64 Linux | Self-hosted | Linux x86_64 |

**Estimated:** 22 tests x 10 backend/compiler combinations = 220 test runs (on a machine with all backends available)

### Layer 3: Compiler Self-Tests

**Goal:** Run embedded unit tests in the compiler modules themselves.

Once `test` declarations are implemented:

1. Build the compiler with `stela build` (normal mode — tests are stripped)
2. Run `stela test compiler/util.stele --lib assert` to run util unit tests
3. Run `stela test compiler/lexer.stele --lib assert` to run lexer unit tests
4. Etc.

Since the compiler modules are concatenated in dependency order, testing individual modules requires either:
- **Option A:** `stela test` concatenates modules up to and including the target, then compiles in test mode
- **Option B:** Each module file is self-contained enough to test independently (util already is; lexer depends on util; parser depends on lexer+util; etc.)

**Recommended: Option B with explicit lib dependencies.**

```bash
# Test util (no deps beyond assert)
stela test compiler/util.stele --lib assert

# Test lexer (depends on util)
stela test compiler/lexer.stele --lib assert --lib compiler-util

# Test parser (depends on util + lexer)
stela test compiler/parser.stele --lib assert --lib compiler-util --lib compiler-lexer
```

Where `compiler-util`, `compiler-lexer` etc. are packaged as stela libraries. This fits the existing `stela package-lib` / `--lib` mechanism.

### Layer 4: Bootstrap Verification

**Goal:** Ensure the self-hosted compiler can compile itself and produce identical output.

This already exists via `bootstrap.sh`. The test plan is:

1. After any change to `.stele` compiler files, run `./bootstrap.sh 3 c`
2. CI runs this on every PR
3. Verify the fixed-point is reached in exactly 2 iterations (gen1 == gen2)

### Layer 5: Runtime Tests

**Goal:** Verify the C runtime behaves correctly for edge cases.

| Test | What it covers |
|------|----------------|
| OOM handling | `stele_malloc` aborts gracefully |
| NULL guards | String builtins reject NULL/wrong-tag values |
| Reference counting | Objects are freed when refcount reaches 0 |
| `rc_release` iterative | Deep linked lists don't overflow during deallocation |
| `checked_add` overflow | INT64_MAX + 1 triggers abort |
| `checked_sub` underflow | INT64_MIN - 1 triggers abort |
| `checked_mul` overflow | Large multiplication triggers abort |
| `getline` readln | Large input lines work (>4096 chars) |
| Value equality | `stele_value_eq` for ints, strings, records |

These are best tested as Stele programs in `tests/positive/` and `tests/negative/` that exercise the runtime behavior through the language.

### Layer 6: Performance Tests

**Goal:** Catch performance regressions in compilation speed and runtime.

| Benchmark | What it measures |
|-----------|-----------------|
| Compile large file | Compilation time for 1000+ line program |
| Fibonacci(30) | Runtime performance of recursive code |
| String building (10K concat) | String allocation/GC pressure |
| List operations (10K elements) | Record allocation throughput |
| Bootstrap time | Time to run `bootstrap.sh 3 c` |

These should be run via `stela bench` and tracked over time, but are not blocking CI.

---

## CI Pipeline

### Current CI Jobs
1. `build` — Build Haskell compiler
2. `test-examples` — Run example programs
3. `stdlib-tests` — Run stdlib test suite
4. `compiler-tests` — Run positive/negative integration tests

### Additional CI Jobs

#### `compiler-unit-tests`
```yaml
compiler-unit-tests:
  runs-on: ${{ matrix.os }}
  strategy:
    matrix:
      os: [macos-14, ubuntu-latest]
  steps:
    - uses: actions/checkout@v4
    - name: Setup Haskell
      uses: haskell-actions/setup@v2
    - name: Build compiler
      run: cd bootstrap/haskell && cabal build
    - name: Run util tests
      run: stela test compiler/util.stele --lib assert --mode c
    - name: Run lexer tests
      run: stela test compiler/lexer.stele --lib assert --mode c
    - name: Run parser tests
      run: stela test compiler/parser.stele --lib assert --mode c
```

#### `self-hosted-backend-tests`
```yaml
self-hosted-backend-tests:
  runs-on: ${{ matrix.os }}
  strategy:
    matrix:
      os: [macos-14, ubuntu-latest]
  steps:
    - uses: actions/checkout@v4
    - name: Build self-hosted compiler
      run: ./stdlib/tests/run.sh  # rebuilds compiler as side effect
    - name: Run positive tests (self-hosted, all backends)
      run: ci/test-compiler.sh --self-hosted-all-backends
```

#### `bootstrap-check`
```yaml
bootstrap-check:
  runs-on: ${{ matrix.os }}
  strategy:
    matrix:
      os: [macos-14, ubuntu-latest]
  steps:
    - uses: actions/checkout@v4
    - name: Setup Haskell
      uses: haskell-actions/setup@v2
    - name: Bootstrap verification
      run: ./bootstrap.sh 3 c
```

---

## Implementation Roadmap

### Phase A: Implement `test` Declarations (1-2 days)
1. Add `test` keyword to self-hosted lexer
2. Add `test_decl` parsing to self-hosted parser
3. Add `TestDecl` to Haskell AST and grammar
4. Update all codegen backends to skip `decl_test` in normal mode
5. Add test-mode codegen to C backend
6. Update `stela test` to pass test flag
7. Re-bootstrap and verify

### Phase B: Write Unit Tests (2-3 days)
1. Package compiler modules as stela libraries
2. Write unit tests for `compiler/util.stele` (~20 tests)
3. Write unit tests for `compiler/lexer.stele` (~20 tests)
4. Write unit tests for `compiler/parser.stele` (~25 tests)
5. Write unit tests for `compiler/codegen_c.stele` (~10 tests)
6. Verify all tests pass

### Phase C: Expand Integration Tests (1 day)
1. Add 14 new positive test files
2. Add 10 new negative test files
3. Extend `ci/test-compiler.sh` to test self-hosted native backends
4. Update CI to run expanded test suite

### Phase D: CI Integration (0.5 day)
1. Add `compiler-unit-tests` CI job
2. Add `self-hosted-backend-tests` CI job
3. Add `bootstrap-check` CI job
4. Verify all CI jobs pass

### Phase E: Documentation and Maintenance (ongoing)
1. Document test conventions in CONTRIBUTING.md
2. Add test coverage tracking (count tests per module)
3. Require tests for new features in PR reviews

---

## Test Naming Conventions

- **Integration tests:** `tests/positive/<feature_name>.stele` — lowercase with underscores
- **Negative tests:** `tests/negative/<error_condition>.stele` — describes the error
- **Unit test blocks:** `test "<module>: <function> <description>"` — e.g., `test "util: is_digit recognizes ASCII 0-9"`
- **Assert codes:** Unique per test file, incrementing by module (util: 100-199, lexer: 200-299, parser: 300-399, codegen: 400-499)

## Success Criteria

- All compiler modules have at least 80% function coverage via unit tests
- Every public function in `compiler/util.stele` and `compiler/lexer.stele` has at least one test
- All positive integration tests pass on all available backend/compiler combinations
- CI runs the full test suite on every PR
- Bootstrap verification passes on every PR that touches `.stele` compiler files
- New features require corresponding tests
