# Operators

Stele supports arithmetic, comparison, and boolean operators. All binary
operators are infix and left-associative.

## Arithmetic Operators

| Operator | Description | Example | Result |
|----------|-------------|---------|--------|
| `+` | Addition | `3 + 4` | `7` |
| `-` | Subtraction | `10 - 3` | `7` |
| `*` | Multiplication | `5 * 6` | `30` |
| `/` | Integer division | `17 / 5` | `3` |
| `%` | Integer remainder | `17 % 5` | `2` |

Division truncates toward zero. Both operands must be `Int`, and the result
is `Int`. Arithmetic traps on overflow, division by zero, and remainder by
zero.

## Unary Operators

| Operator | Description | Example | Result |
|----------|-------------|---------|--------|
| `-` | Negation | `-5` | `-5` |

## Comparison Operators

| Operator | Description | Example | Result |
|----------|-------------|---------|--------|
| `==` | Equal | `3 == 3` | `1` |
| `!=` | Not equal | `3 != 4` | `1` |
| `<` | Less than | `3 < 4` | `1` |
| `>` | Greater than | `4 > 3` | `1` |
| `<=` | Less or equal | `3 <= 3` | `1` |
| `>=` | Greater or equal | `4 >= 3` | `1` |

Comparison operators return `Int` values: `1` for true, `0` for false. Both
operands must be the same type.

## Boolean Operators

| Operator | Description | Example | Result |
|----------|-------------|---------|--------|
| `&&` | Logical AND | `1 && 1` | `1` |
| `\|\|` | Logical OR | `0 \|\| 1` | `1` |

Boolean operators treat `0` as false and any non-zero integer as true. Both
operands must be `Int`.

## Precedence

From highest to lowest precedence:

1. Primary expressions (literals, variables, parenthesized expressions)
2. Unary operators (`-`)
3. Field access (`.field`)
4. Multiplicative (`*`, `/`, `%`)
5. Additive (`+`, `-`)
6. Comparison (`==`, `!=`, `<`, `>`, `<=`, `>=`)
7. Logical AND (`&&`)
8. Logical OR (`||`)

Use parentheses to override precedence:

```
(a + b) * c
```

## Combining with Pattern Matching

Since comparisons return integers, they work naturally with `match`:

```
fn abs
  case {| n |} =>
    match n >= 0
      case 1 => n
      case 0 => 0 - n
    end
end
```

This is the idiomatic way to write conditional logic in Stele.
