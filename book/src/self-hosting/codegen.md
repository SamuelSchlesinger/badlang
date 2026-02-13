# Code Generation

The code emitter translates AST nodes into C code. It generates
reference-counted `Value*` operations that work with the shared `runtime.c`.

## The Emitter Pattern

Every emitter fn follows the same convention. It takes an AST node and a
`counter` (for generating unique variable names), and returns:

```
{| code: String, var: String, counter: Int |}
```

- **`code`** — C statements that set up the computation (variable declarations,
  function calls, etc.)
- **`var`** — the name of the C variable holding the result
- **`counter`** — the updated counter for the next fresh variable

The counter is **threaded** through every emitter call: each fn receives
the counter, may allocate fresh variables (incrementing it), and passes the
updated counter to the next call. This ensures all generated variable names
are globally unique.

## Fresh Variables

The `fresh_var` fn generates unique C identifiers:

```
fresh_var {| prefix: "_t", counter: 0 |}
→ {| name: "_t0", counter: 1 |}
```

Generated names include `_t0`, `_t1`, ... for temporaries, `_scr0` for
scrutinees, `_dvn0` for match results, and `_done0` for goto labels.

## Identifier Mangling

The `c_name` fn prefixes Stele identifiers with `stele_` to avoid collisions
with C keywords. The special name `arg` (the fn parameter) is left unmangled
since it matches the generated C function signature.

## Expression Emission

The central dispatcher `emit_expr` pattern-matches on the AST node's `tag`
field and delegates to specialized emitters:

| AST Tag | Emitter | Generated C |
|---------|---------|-------------|
| `int_lit` | `emit_int_lit` | `make_int(42)` |
| `str_lit` | `emit_str_lit` | `make_str("hello")` |
| `var` | `emit_var` | `stele_x; rc_retain(stele_x)` |
| `binop` | `emit_binop` | Emit both sides, apply op, release operands |
| `unop` | `emit_unop` | Emit operand, negate |
| `field_access` | `emit_field_access` | `record_field(obj, "name")` + retain |
| `record` | `emit_record` | `make_record(n, "f1", v1, ...)` |
| `call` | `emit_call_expr` | `fn_name(arg)` |
| `let_in` | `emit_let_in` | Flat sequential bindings (see below) |
| `match` | `emit_match` | Cascading if-chains with goto |

### Let Binding Chains

The emitter flattens chains of nested `let_in` nodes into sequential C
variable declarations. The `collect_let_chain` fn walks the nested structure
and extracts all bindings and the final body. Then `emit_let_bindings_loop`
emits each binding as a flat `Value*` declaration, and all bound variables are
released in reverse order after the body:

```c
// let x = 1
// let y = x + 1
// x * y
Value* stele_x = make_int(1);
Value* stele_y = make_int(stele_x->int_val + make_int(1)->int_val);
/* ... body code ... */
rc_release(stele_y);
rc_release(stele_x);
```

This avoids nested `{ }` blocks, keeping the generated C flat regardless of how
many sequential `let` bindings appear.

### Record Emission

Records are emitted as variadic `make_record` calls. The emitter loops over the
field list, emitting each value expression and collecting the field names and
result variables into an argument string:

```c
make_record(2, "x", _t0, "y", _t1)
```

`make_record` **adopts** the field values — it takes ownership without
incrementing their reference counts.

## Pattern Matching

Pattern matching emission produces two things:

- **`cond`** — a C condition expression (e.g., `_f_x != NULL && _f_x->int_val == 0`)
- **`bindings`** — C variable declarations extracting matched values

### Record Patterns

For each field in a record pattern, the emitter generates:

```c
Value* _f_x = record_field(arg, "x");
Value* stele_x = _f_x;
```

The condition checks that `_f_x != NULL` (the field exists). For literal
sub-patterns, it additionally checks the value:

```c
_f_n != NULL && _f_n->tag == TAG_INT && _f_n->int_val == 0
```

### Match Expressions

`match` compiles to a local result variable, a scrutinee, and a series of
if-blocks with a shared `goto` label:

```c
Value* _dvn0;
Value* _scr0 = /* scrutinee */;
/* clause 1: */ if (condition) { ... _dvn0 = result; goto _done0; }
/* clause 2: */ if (condition) { ... _dvn0 = result; goto _done0; }
fprintf(stderr, "Pattern match failure\n"); exit(1);
_done0:;
rc_release(_scr0);
```

Each clause retains pattern-bound variables on entry and releases them before
the `goto`.

## Function Definitions

Each fn compiles to a static C function:

```c
static Value* fn_factorial(Value* arg) {
    /* clause 1 */
    /* clause 2 */
    fprintf(stderr, "Pattern match failure in fn 'factorial'\n");
    exit(1);
}
```

Clauses are emitted as cascading if-blocks. On a successful match, the body is
evaluated, pattern-bound variables are released, and the result is returned.

## Built-in Functions

Certain functions (`unearth`, `inscribe`, `concat`, `strlen`, `char_at`,
`substr`, `strcmp`, `int_to_str`, `char_of_int`, `argc`, `argv`) are
implemented in `runtime.c` rather than generated. The emitter checks
`is_builtin_fn` and skips code generation for these — they are available as C
functions at link time.

## Assembling the Output

The top-level `emit_c` fn assembles the complete C file by concatenating:

1. The contents of `runtime.c` (read via `unearth`)
2. Forward declarations for all non-builtin functions
3. Function definitions
4. The `main()` function (from the `do main` declaration)

## The AArch64 Code Generator

The self-hosting compiler also includes an AArch64 native code generator,
activated by passing `asm` as the third command-line argument:

```
compiler source.stele output.s asm
```

### Emitter State

Where the C emitter threads a simple `counter` through each call, the AArch64
emitter threads a richer state record:

```
{| counter, slot_counter, slots, strs |}
```

- **`counter`** — for generating fresh labels
- **`slot_counter`** — tracks the next available stack slot
- **`slots`** — a linked list mapping variable names to stack slot numbers
- **`strs`** — a linked list of string literals with deduplicated labels

### Stack-based Variables

All variables live on the stack. The `alloc_slot` fn allocates a slot and
the `lookup_slot` fn finds one by name. Stack offsets are computed as
`-(16 + (slot+1)*8)` relative to the frame pointer (x29), with
`emit_load_slot` and `emit_store_slot` generating the appropriate `ldur`/`stur`
instructions (falling back to register-indirect addressing for large offsets).

### Expression Emission

Each expression emitter follows the same convention as the C side — it takes
an AST node and state, and returns `{| code, var, state |}`. The `code` is
assembly text, `var` names the stack slot holding the result, and `state`
carries the updated counters, slots, and string table.

### String Table

String literals and field names are collected into a deduplicated string
table during emission. The `emit_string_table` fn emits them as `.asciz`
directives in a `.section __TEXT,__cstring` data section at the end of the
file.

### Mode Selection

The `get_mode` fn checks `argv[3]` for the string `"asm"`. The main do
uses a `match` on the mode to select between `emit_c` and `emit_asm`.
