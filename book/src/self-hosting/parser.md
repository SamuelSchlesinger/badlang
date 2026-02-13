# Parser

The parser transforms a list of tokens into an abstract syntax tree (AST). It
is a **recursive descent parser** with **precedence climbing** for operators.

## Token Stream Interface

The parser consumes tokens through three helper functions:

- `peek` — look at the next token without consuming it
- `advance` — consume the current token and return the rest
- `expect` — consume a token of a specific type, or abort with an error

Every parse fn takes a `tokens` parameter and returns a record containing the
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
| `named_record` | `name`, `fields` | `Point {\| x: 1 \|}` |
| `call` | `name`, `arg` | `factorial {\| n: 5 \|}` |
| `let_in` | `name`, `value`, `body` | `let x = 1` (desugared) |
| `match` | `scrutinee`, `clauses` | `match expr case ... end` |
| `readln` | *(none)* | `readln` |
| `readint` | *(none)* | `readint` |

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
| `decl_fn` | `name`, `clauses` | `fn factorial case ... end` |
| `decl_do` | `name`, `stmts` | `do main ... end` |
| `decl_struct` | `name`, `fields` | `struct Point x: Int y: Int end` |

## Operator Precedence

The parser implements operator precedence via a chain of mutually recursive
functions, from lowest to highest precedence:

| Level | Operators | Function |
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

The `parse_let_bindings` fn collects bindings into a list, then
`fold_let_bindings` converts them into nested `let_in` nodes where the
innermost body is the final expression.

## Parsing Function Calls

Function calls support three argument forms:

1. **Record literal:** `f {| x: 1 |}`
2. **Parenthesized expression:** `f (expr)`
3. **Variable:** `f x`

This flexibility lets the programmer choose the most readable form for each
call site.
