# Parser

The parser transforms a list of tokens into an abstract syntax tree (AST). It
is a **recursive descent parser** with **precedence climbing** for operators.

## Token Stream Interface

The parser consumes tokens through three helper rites:

- `peek` — look at the next token without consuming it
- `advance` — consume the current token and return the rest
- `expect` — consume a token of a specific type, or abort with an error

Every parse rite takes a `tokens` parameter and returns a record containing the
parsed AST `node` and the remaining `rest` tokens.

## AST Node Types

The parser produces tagged records as AST nodes. Each node has a `tag` field
that identifies its type.

### Expressions

| Tag | Fields | Example |
|-----|--------|---------|
| `int_lit` | `value` | `42` |
| `str_lit` | `value` | `"hello"` |
| `var` | `name` | `x` |
| `binop` | `op`, `left`, `right` | `x + 1` |
| `unop` | `op`, `operand` | `-x` |
| `field_access` | `obj`, `field` | `point.x` |
| `record` | `fields` | `{\| x: 1, y: 2 \|}` |
| `summon` | `name`, `fields` | `summon Point {\| x: 1 \|}` |
| `invoke` | `name`, `arg` | `invoke factorial {\| n: 5 \|}` |
| `let_in` | `name`, `value`, `body` | `let x = 1` (desugared) |
| `divine` | `scrutinee`, `clauses` | `divine expr given ... seal` |
| `hearken` | *(none)* | `hearken` |
| `scry` | *(none)* | `scry` |

### Patterns

| Tag | Fields | Example |
|-----|--------|---------|
| `pat_int` | `value` | `0` |
| `pat_str` | `value` | `"hello"` |
| `pat_var` | `name` | `n` |
| `pat_wild` | *(none)* | `_` |
| `pat_rec` | `fields` | `{\| x, y: 0 \|}` |

### Declarations

| Tag | Fields | Example |
|-----|--------|---------|
| `decl_rite` | `name`, `clauses` | `rite factorial given ... seal` |
| `decl_ritual` | `name`, `stmts` | `ritual main ... seal` |
| `decl_altar` | `name`, `fields` | `altar Point x: Int y: Int seal` |

## Operator Precedence

The parser implements operator precedence via a chain of mutually recursive
rites, from lowest to highest precedence:

| Level | Operators | Rite |
|-------|-----------|------|
| 1 (lowest) | `\|\|` | `parse_or_expr` |
| 2 | `&&` | `parse_and_expr` |
| 3 | `==` `!=` `<` `>` `<=` `>=` | `parse_cmp_expr` |
| 4 | `+` `-` | `parse_add_expr` |
| 5 | `*` `/` `%` | `parse_mul_expr` |
| 6 | unary `-` | `parse_unary_expr` |
| 7 (highest) | `.` (field access) | `parse_postfix_expr` |

Each level parses its operand by calling the next higher level, then checks for
its operator in a tail-recursive loop. For example, `parse_add_expr` calls
`parse_mul_expr` for its left operand, then loops checking for `+` or `-`.

All binary operators are **left-associative**: `a + b + c` parses as
`(a + b) + c`.

## Parsing Let Bindings

Sequential `let` bindings in a block are parsed into a list, then folded into
right-nested `let_in` AST nodes:

```
let x = 1        →   {| tag: "let_in", name: "x", value: 1,
let y = x + 1             body: {| tag: "let_in", name: "y", value: ...,
x * y                              body: {| tag: "binop", ... |} |} |}
```

The `parse_let_bindings` rite collects bindings into a list, then
`fold_let_bindings` converts them into nested `let_in` nodes where the
innermost body is the final expression.

## Parsing Invoke

`invoke` supports three argument forms:

1. **Record literal:** `invoke f {| x: 1 |}`
2. **Parenthesized expression:** `invoke f (expr)`
3. **Variable:** `invoke f x`

This flexibility lets the programmer choose the most readable form for each
call site.
