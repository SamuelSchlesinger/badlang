# C Code Generation

Stele compiles to readable, self-contained C. Understanding the generated
code can help with debugging and with understanding the language's runtime
behavior.

## Runtime Representation

All values are represented as tagged unions:

```c
typedef enum { TAG_INT, TAG_STR, TAG_RECORD, TAG_VOID } Tag;

typedef struct Field {
    const char* name;
    struct Value* value;
} Field;

typedef struct Value {
    Tag tag;
    int refcount;
    union {
        int64_t int_val;
        char* str_val;
        struct {
            int num_fields;
            Field* fields;
        } record;
    };
} Value;
```

Every value — including plain integers — is a pointer to a `Value` on the
heap. This means all values are **boxed**.

## Memory Model

The runtime uses **reference counting**. Every `Value` has a `refcount` field
that tracks how many references point to it. When the count drops to zero the
value is freed:

- `TAG_STR` — the `str_val` buffer is freed, then the `Value`.
- `TAG_RECORD` — each field value is recursively released, the fields array
  is freed, then the `Value`.
- `TAG_INT` / `TAG_VOID` — the `Value` is freed directly.

Because Stele values are **immutable** and there are **no closures or
first-class functions**, reference cycles are impossible and reference counting
is a complete solution — no garbage collector is needed.

### Ownership Convention

Every expression evaluates to an **owned** `Value*` (its reference count has
been incremented for the recipient). The recipient must call `rc_release` when
it is done with the value.

| Operation | Ownership |
|-----------|-----------|
| `make_int`, `make_str`, `make_void` | Returns owned (refcount 1) |
| `make_record` | Returns owned; **adopts** field values (does not retain them) |
| `record_field` | Returns **borrowed** (no refcount change) |
| Variable access | Borrows from local, caller retains to own |
| Function call | Caller owns the argument; callee borrows it. Return value is owned. |
| `print` / `write` | Borrow their argument (caller releases after) |

## How Constructs Compile

### Functions → C Functions

Each fn becomes a C function taking and returning `Value*`:

```
fn square
  case {| n |} => n * n
end
```

Compiles to something like:

```c
static Value* fn_square(Value* arg) {
    Value* _f_n = record_field(arg, "n");
    Value* stele_n = _f_n;
    if (_f_n != NULL) {
        rc_retain(stele_n);
        Value* _t0 = stele_n; rc_retain(_t0);
        Value* _t1 = stele_n; rc_retain(_t1);
        Value* _t2 = make_int(_t0->int_val * _t1->int_val);
        rc_release(_t0); rc_release(_t1);
        rc_release(stele_n);
        return _t2;
    }
    // ...pattern match failure...
}
```

### Pattern Matching → if-chains

Multi-clause pattern matching compiles to cascading if-statements that check
field values:

```
fn factorial
  case {| n: 0 |} => 1
  case {| n |} => n * (factorial {| n: n - 1 |})
end
```

Becomes cascading blocks, each extracting fields and checking conditions. On
match, pattern-bound variables are retained, the body is evaluated, bindings
are released, and the result is returned.

### Record Literals → make_record

Record construction uses a variadic function:

```c
make_record(2, "x", make_int(3), "y", make_int(4))
```

This allocates a `Value` with tag `TAG_RECORD` containing two fields. The
field values are **adopted** — `make_record` takes ownership without
incrementing their reference counts.

### Field Access → record_field

Field access compiles to a linear scan that returns a **borrowed** pointer:

```c
Value* record_field(Value* rec, const char* name) {
    for (int i = 0; i < rec->record.num_fields; i++) {
        if (strcmp(rec->record.fields[i].name, name) == 0)
            return rec->record.fields[i].value;
    }
    return NULL;
}
```

The caller must `rc_retain` the result if it needs to outlive the record.

### let ... in → Flat Sequential Statements

Chains of `let` bindings are flattened into sequential C variable declarations.
The compiler collects consecutive `let` bindings and emits them without nesting,
then releases all bound variables in reverse declaration order after the body:

```c
Value* stele_x = /* evaluated value for x */;
Value* stele_y = /* evaluated value for y */;
/* body code that may reference stele_x, stele_y */
/* body result is used directly */
rc_release(stele_y);
rc_release(stele_x);
```

This avoids O(N) nesting depth for N sequential bindings, keeping the generated
C flat regardless of how many `let` bindings appear in a row.

### match → Local Variable + goto

`match` expressions compile to a local result variable and a label for early
exit, with each clause checking its pattern and jumping to the end on match.
The scrutinee is released at the label after the matching clause stores its
result.

### print/write → Print Functions

`print` and `write` borrow their argument — the caller is responsible for
releasing it afterward.

```c
// Generated for: print expr
Value* _t0 = /* evaluate expr */;
print(_t0);
rc_release(_t0);
```

## Identifier Mangling

To avoid collisions with C keywords, Stele identifiers are prefixed with
`stele_`:

| Stele | C |
|---------|---|
| `x` | `stele_x` |
| `name` | `stele_name` |
| `result` | `stele_result` |

Generated temporaries use numbered prefixes like `_t0`, `_t1`, `_scr0`,
`_dvn0`, `_done0`, etc., ensuring uniqueness across the entire compilation
unit.

## Compiler Extensions

The generated code uses `__builtin_va_list` / `__builtin_va_start` /
`__builtin_va_arg` for `make_record`'s variadic interface. These are supported
by both GCC and Clang. No statement expressions (`({ ... })`) are used.

## The AArch64 Backend

In addition to C, Stele can compile directly to AArch64 (Apple Silicon)
assembly. The native backend (`Stele.EmitAArch64`) consumes the same IR as
the C backend but emits `.s` files linked against a separate C runtime.

Using the bootstrap compiler:

```bash
cd bootstrap/haskell
cabal run stele -- --native ../../examples/hello.stele
# => Writes examples/hello.s + examples/hello_rt.c, links to examples/hello
```

Or using the self-hosted compiler:

```bash
./compiler examples/hello.stele hello.s asm
cc -O1 -o hello hello.s runtime/runtime_aarch64.c && ./hello
```

The strategy is straightforward: all IR variables are stored on the stack in
a fixed-size frame. String literals are collected into a `.section
__TEXT,__cstring` data section. Function calls use the standard Apple AArch64
calling convention (x0 for first argument / return value, x29/x30 for frame
and link registers).

The self-hosting compiler in `compiler.stele` (at the repo root) also has its own
AArch64 backend and can emit assembly when invoked with the `asm` flag.

## Inspecting Generated Code

To see the generated C without running it:

```bash
./compiler examples/hello.stele hello.c
cat hello.c
```

To see the generated assembly:

```bash
./compiler examples/hello.stele hello.s asm
cat hello.s
```

The output is intentionally readable. It's a useful learning tool for
understanding how high-level constructs map to low-level code.
