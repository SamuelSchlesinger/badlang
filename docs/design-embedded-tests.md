# Design: Embedded Tests in Stele

## Motivation

Currently, Stele tests are either:
1. **External bash-based tests** (`ci/test-compiler.sh`) — separate `.stele` + `.expected` files checked by a shell script
2. **Stdlib tests** (`stdlib/tests/`) — hand-written `do main` blocks that call assert functions and are run via `stela test`

Neither approach supports embedding tests alongside the code they test, which makes it hard to:
- Write unit tests for library functions in the same file
- Keep tests co-located with the code (like Rust's `#[test]`)
- Discover and run tests automatically

## Design

### Syntax

Add `test` as a new top-level declaration keyword:

```stele
fn factorial
  case {| n |} =>
    match n <= 1
      case 1 => 1
      case 0 => n * (factorial {| n: n - 1 |})
    end
end

test "factorial of 0 is 1"
  let _ = assert_eq_int {| actual: factorial {| n: 0 |}, expected: 1, code: 1 |}
end

test "factorial of 5 is 120"
  let _ = assert_eq_int {| actual: factorial {| n: 5 |}, expected: 120, code: 2 |}
end

do main
  print factorial {| n: 10 |}
end
```

The `test` declaration takes a **string literal name** (not an identifier) followed by a statement body (identical to `do` block bodies) and closes with `end`.

### Grammar

```
test_decl ::= "test" string_literal stmt+ "end"
```

This mirrors `do_decl` except the name is a string literal instead of an identifier. This provides descriptive test names without polluting the identifier namespace.

### AST Representation

**Haskell bootstrap compiler (AST.hs):**
```haskell
data Decl
  = StructDecl !String [Field]
  | FnDecl     !String [CaseClause]
  | DoDecl     !String [Stmt]
  | OneofDecl  !String [(String, [Field])]
  | TestDecl   !String [Stmt]              -- NEW: name + body
```

**Self-hosted compiler (parser output):**
```stele
{| tag: "decl_test", name: "factorial of 0 is 1", stmts: <list of stmts> |}
```

### Compilation Modes

The key design decision is how `test` declarations interact with compilation:

**Normal mode** (`stela build`, `stela run`, plain compiler invocation):
- `test` declarations are **parsed but ignored** during code generation
- The `emit_forward_decls_loop`, `emit_decls_loop`, and `emit_main_fn` functions skip `decl_test` nodes (they already skip unknown tags)
- Zero runtime cost — no test code appears in production binaries

**Test mode** (`stela test`):
- `test` declarations are compiled into a **generated test runner main function**
- Each `test` block becomes a function called from the generated main
- The runner prints each test name, executes it, catches failures (non-zero exit), and reports results

### Test Runner Generation (Compiler-Level)

When the compiler receives a `--test` flag (or mode), the code generators produce a different `main()`:

```c
// Generated test runner main (C backend example)
int main(int argc, char** argv) {
    g_argc = argc;
    g_argv = argv;
    int _test_pass = 0;
    int _test_fail = 0;

    // Test 1: "factorial of 0 is 1"
    fprintf(stderr, "test: factorial of 0 is 1 ... ");
    // <compiled test body statements>
    fprintf(stderr, "ok\n");
    _test_pass++;

    // Test 2: "factorial of 5 is 120"
    fprintf(stderr, "test: factorial of 5 is 120 ... ");
    // <compiled test body statements>
    fprintf(stderr, "ok\n");
    _test_pass++;

    fprintf(stderr, "\n%d passed, %d failed\n", _test_pass, _test_fail);
    return _test_fail > 0 ? 1 : 0;
}
```

Since Stele doesn't have exception handling, test failures use `terminate` (via the assert library). A failing test terminates the process. This is acceptable for a v1 — it matches how the existing stdlib tests work. A future version could use `fork()` to isolate each test.

### Alternative Considered: `stela`-Level Rewriting

Instead of compiler support, `stela test` could rewrite the source:
1. Parse `.stele` files to find `test` blocks
2. Remove the original `do main` (if any)
3. Generate a new `do main` that calls each test block
4. Compile and run the rewritten source

**Rejected** because:
- Requires `stela` to have its own parser (or regex-based extraction, which is fragile)
- Doesn't work for testing the compiler itself (bootstrap)
- Compiler-level support is cleaner and enables future features (test filtering, parallel execution)

### Integration with `stela test`

`stela test` currently compiles and runs a file (same as `stela run` but with a different label). With this change:

1. `stela test <file.stele>` passes `--test` flag to the compiler
2. The compiler emits a test runner main instead of the normal main
3. `stela` runs the binary and reports results
4. If the file has no `test` declarations, it falls back to the current behavior (run `do main`)

### Integration with Assert Library

The existing `stdlib/assert.stele` works as-is inside test blocks:

```stele
test "string equality"
  let _ = assert_eq_str {| actual: "hello", expected: "hello", code: 10 |}
  let _ = assert_ne_str {| actual: "a", unexpected: "b", code: 11 |}
end
```

For inline tests that don't want to depend on the assert library, simple match-based assertions work:

```stele
test "basic arithmetic"
  match 2 + 2 == 4
    case 0 => terminate {| code: 1 |}
    case 1 => 0
  end
end
```

### Lexer Changes

Add `"test"` to the keyword list in both compilers:

**Self-hosted lexer (`compiler/lexer.stele`):**
Add `"test"` to the keyword check in `classify_ident`.

**Haskell grammar (`Grammar.hs`):**
Add `kw "test"` rule.

### Parser Changes

**Self-hosted parser (`compiler/parser.stele`):**

```stele
fn parse_test_decl
  case {| tokens |} =>
    let rest1 = expect {| tokens: tokens, type: "test" |}
    let tok = peek {| tokens: rest1 |}
    -- expect a string literal for the test name
    let name = tok.value
    let rest2 = advance {| tokens: rest1 |}
    let empty = nil {| |}
    let r = parse_stmts {| tokens: rest2, acc: empty |}
    let rest3 = expect {| tokens: r.rest, type: "end" |}
    {| node: {| tag: "decl_test", name: name, stmts: r.node |}, rest: rest3 |}
end
```

And add `case "test" => parse_test_decl {| tokens: tokens |}` to `parse_decl`.

**Haskell grammar (`Grammar.hs`):**

```haskell
, ("test_decl", seq_
    [ kw "test", ws1
    , label "name" (rule "string"), ws
    , label "body" (many1 (rule "stmt" <.> ws))
    , kw "end"
    ])
```

Add `rule "test_decl"` to the `decl` alternatives.

### Code Generation Changes

**Normal mode:** All three backends (`codegen_c.stele`, `codegen_aarch64.stele`, `codegen_x86.stele`) already skip unknown declaration tags in their `emit_decls_loop` and `emit_forward_decls_loop`. No changes needed — `decl_test` is silently skipped.

**Test mode:** Add an `emit_test_main` function that:
1. Collects all `decl_test` declarations from the decl list
2. Emits each test body as inline statements in main, wrapped with the test name print and pass counter increment
3. Emits a summary line at the end

The compiler decides between `emit_main_fn` and `emit_test_main` based on a flag (e.g., mode value or a dedicated field in the compilation options).

### Passing the Test Flag

**Self-hosted compiler (`compiler/main.stele`):**
Add a new argument or environment variable. The simplest approach: if `argv[3]` equals `"test"`, use test mode. This is backward compatible since the third arg is currently only used for backend mode selection in the self-hosted compiler, and `stela` would pass it.

**Haskell bootstrap compiler:**
Add a `--test` command-line flag.

---

## Implementation Plan

### Step 1: Lexer — Add `test` keyword
- `compiler/lexer.stele`: Add `"test"` to keyword classification
- `bootstrap/haskell/src/Stele/Grammar.hs`: Add `kw "test"` rule

### Step 2: Parser — Parse `test` declarations
- `compiler/parser.stele`: Add `parse_test_decl`, update `parse_decl`
- `bootstrap/haskell/src/Stele/Grammar.hs`: Add `test_decl` grammar rule
- `bootstrap/haskell/src/Stele/AST.hs`: Add `TestDecl` constructor

### Step 3: Code Generation — Normal mode (skip tests)
- Verify all three self-hosted backends already skip unknown decl tags (they do)
- Haskell `EmitC.hs`: Add `TestDecl` case that produces no output
- Haskell `EmitAArch64.hs`, `EmitX86_64.hs`: Same

### Step 4: Code Generation — Test mode
- `compiler/codegen_c.stele`: Add `emit_test_main` function
- `compiler/main.stele`: Check for test flag, call `emit_test_main` instead of `emit_main_fn`
- Haskell backends: Same pattern

### Step 5: Build tool integration
- `stela.stele`: Pass `--test` flag to compiler when running `stela test`
- Update `stela test` to detect whether file has test declarations

### Step 6: Write unit tests for compiler modules
- Add `test` blocks to `compiler/util.stele`, `compiler/lexer.stele`, etc.
- Create a CI job that runs compiler self-tests

### Step 7: Re-bootstrap
- Run `./bootstrap.sh 3 c` to verify fixed-point
- Verify all existing tests still pass

---

## Example: Unit Tests in compiler/util.stele

```stele
-- (existing utility functions above...)

test "is_digit recognizes ASCII digits"
  let _ = assert_true {| cond: is_digit {| c: 48 |}, code: 100 |}
  let _ = assert_true {| cond: is_digit {| c: 57 |}, code: 101 |}
  let _ = assert_false {| cond: is_digit {| c: 47 |}, code: 102 |}
  let _ = assert_false {| cond: is_digit {| c: 58 |}, code: 103 |}
end

test "is_alpha recognizes letters"
  let _ = assert_true {| cond: is_alpha {| c: 65 |}, code: 110 |}
  let _ = assert_true {| cond: is_alpha {| c: 122 |}, code: 111 |}
  let _ = assert_false {| cond: is_alpha {| c: 64 |}, code: 112 |}
end

test "str_eq compares strings"
  let _ = assert_true {| cond: str_eq {| a: "hello", b: "hello" |}, code: 120 |}
  let _ = assert_false {| cond: str_eq {| a: "hello", b: "world" |}, code: 121 |}
end

test "list operations"
  let empty = nil {| |}
  let _ = assert_true {| cond: is_nil {| list: empty |}, code: 130 |}
  let l1 = cons {| head: 1, tail: empty |}
  let _ = assert_false {| cond: is_nil {| list: l1 |}, code: 131 |}
  let _ = assert_eq_int {| actual: list_head {| list: l1 |}, expected: 1, code: 132 |}
  let _ = assert_eq_int {| actual: list_len {| list: l1 |}, expected: 1, code: 133 |}
end

test "cat3 concatenates three strings"
  let _ = assert_eq_str {| actual: cat3 {| a: "a", b: "b", c: "c" |}, expected: "abc", code: 140 |}
end
```

## Example: Unit Tests in compiler/lexer.stele

```stele
test "tokenize integer literal"
  let tokens = tokenize {| src: "42" |}
  let tok = list_head {| list: tokens |}
  let _ = assert_eq_str {| actual: tok.type, expected: "int", code: 200 |}
  let _ = assert_eq_str {| actual: tok.value, expected: "42", code: 201 |}
end

test "tokenize string literal"
  let tokens = tokenize {| src: "\"hello\"" |}
  let tok = list_head {| list: tokens |}
  let _ = assert_eq_str {| actual: tok.type, expected: "str", code: 210 |}
  let _ = assert_eq_str {| actual: tok.value, expected: "hello", code: 211 |}
end

test "tokenize keywords"
  let tokens = tokenize {| src: "fn do case end let match" |}
  let t1 = list_head {| list: tokens |}
  let _ = assert_eq_str {| actual: t1.type, expected: "fn", code: 220 |}
end

test "tokenize record delimiters"
  let tokens = tokenize {| src: "{| x: 1 |}" |}
  let t1 = list_head {| list: tokens |}
  let _ = assert_eq_str {| actual: t1.type, expected: "{|", code: 230 |}
end
```
