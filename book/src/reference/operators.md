# Operator Reference

## Arithmetic Operators

All arithmetic operators require `Int` operands and produce `Int` results.

| Operator | Name | Associativity | Example |
|----------|------|---------------|---------|
| `+` | Addition | Left | `3 + 4` → `7` |
| `-` | Subtraction | Left | `10 - 3` → `7` |
| `*` | Multiplication | Left | `5 * 6` → `30` |
| `/` | Integer Division | Left | `17 / 5` → `3` |

Division truncates toward zero.

## Unary Operators

| Operator | Name | Example |
|----------|------|---------|
| `-` | Negation | `-5` |

## Comparison Operators

Comparison operators return `Int`: `1` for true, `0` for false.

| Operator | Name | Example |
|----------|------|---------|
| `==` | Equal | `3 == 3` → `1` |
| `!=` | Not equal | `3 != 4` → `1` |
| `<` | Less than | `3 < 4` → `1` |
| `>` | Greater than | `4 > 3` → `1` |
| `<=` | Less or equal | `3 <= 3` → `1` |
| `>=` | Greater or equal | `4 >= 3` → `1` |

## Boolean Operators

Boolean operators treat `0` as false, non-zero as true. Both operands must
be `Int`.

| Operator | Name | Example |
|----------|------|---------|
| `&&` | Logical AND | `1 && 1` → `1` |
| `\|\|` | Logical OR | `0 \|\| 1` → `1` |

## Field Access Operator

| Operator | Name | Example |
|----------|------|---------|
| `.` | Field access | `point.x` |

Field access can be chained: `line.start.x`.

## Precedence Table

From highest to lowest:

| Level | Operators | Associativity |
|-------|-----------|---------------|
| 1 | Literals, variables, `(...)` | — |
| 2 | `-` (unary) | Prefix |
| 3 | `.field` | Left |
| 4 | `*`, `/` | Left |
| 5 | `+`, `-` | Left |
| 6 | `==`, `!=`, `<`, `>`, `<=`, `>=` | Non-associative |
| 7 | `&&` | Left |
| 8 | `\|\|` | Left |

Use parentheses to override precedence: `(a + b) * c`.
