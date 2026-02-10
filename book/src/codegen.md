# C Code Generation

badlang compiles to readable, self-contained C. Understanding the generated
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

Because badlang values are **immutable** and there are **no closures or
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
| Rite call | Caller owns the argument; callee borrows it. Return value is owned. |
| `utter` / `whisper` | Borrow their argument (caller releases after) |

## How Constructs Compile

### Rites → C Functions

Each rite becomes a C function taking and returning `Value*`:

```
rite square
  given {| n |} => n * n
seal
```

Compiles to something like:

```c
static Value* rite_square(Value* arg) {
    Value* _f_n = record_field(arg, "n");
    Value* bl_n = _f_n;
    if (_f_n != NULL) {
        rc_retain(bl_n);
        Value* _t0 = bl_n; rc_retain(_t0);
        Value* _t1 = bl_n; rc_retain(_t1);
        Value* _t2 = make_int(_t0->int_val * _t1->int_val);
        rc_release(_t0); rc_release(_t1);
        rc_release(bl_n);
        return _t2;
    }
    // ...pattern match failure...
}
```

### Pattern Matching → if-chains

Multi-clause pattern matching compiles to cascading if-statements that check
field values:

```
rite factorial
  given {| n: 0 |} => 1
  given {| n |} => n * (invoke factorial {| n: n - 1 |})
seal
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

### let ... in → Block Scoping

Let bindings use C block scoping with a result variable declared outside:

```c
Value* _t5;
{
    Value* bl_x = /* evaluated value */;
    /* body that may reference bl_x */
    _t5 = /* body result */;
    rc_release(bl_x);
}
/* _t5 is the result */
```

### divine → Local Variable + goto

`divine` expressions compile to a local result variable and a label for early
exit, with each clause checking its pattern and jumping to the end on match.
The scrutinee is released at the label after the matching clause stores its
result.

### utter/whisper → Print Functions

`utter` and `whisper` borrow their argument — the caller is responsible for
releasing it afterward.

```c
// Generated for: utter expr
Value* _t0 = /* evaluate expr */;
utter(_t0);
rc_release(_t0);
```

## Identifier Mangling

To avoid collisions with C keywords, badlang identifiers are prefixed with
`bl_`:

| badlang | C |
|---------|---|
| `x` | `bl_x` |
| `name` | `bl_name` |
| `result` | `bl_result` |

Generated temporaries use numbered prefixes like `_t0`, `_t1`, `_scr0`,
`_dvn0`, `_done0`, etc., ensuring uniqueness across the entire compilation
unit.

## Compiler Extensions

The generated code uses `__builtin_va_list` / `__builtin_va_start` /
`__builtin_va_arg` for `make_record`'s variadic interface. These are supported
by both GCC and Clang. No statement expressions (`({ ... })`) are used.

## Inspecting Generated Code

To see the generated C without running it:

```bash
cabal run badlang -- examples/hello.bad
cat examples/hello.c
```

The output is intentionally readable. It's a useful learning tool for
understanding how high-level constructs map to low-level code.
