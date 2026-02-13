# Keyword Reference

All reserved keywords in Stele.

## Declaration Keywords

| Keyword | Syntax | Description |
|---------|--------|-------------|
| `struct` | `struct Name ... end` | Declare a named record type with typed fields |
| `fn` | `fn name case ... end` | Define a pure function by pattern matching |
| `do` | `do name ... end` | Define an effectful entry point |
| `end` | (closing delimiter) | Close a struct, fn, do, or match block |

## Pattern Matching Keywords

| Keyword | Syntax | Description |
|---------|--------|-------------|
| `case` | `case pattern => body` | A pattern clause in a fn or match expression |
| `match` | `match expr case ... end` | Inline pattern match expression |

## Expression Keywords

| Keyword | Syntax | Description |
|---------|--------|-------------|
| `let` | `let name = expr` | Bind a local variable |
| `in` | (reserved) | Reserved for future use |

Function calls use postfix syntax: `name arg` (e.g., `factorial {| n: 5 |}`).
Named record construction uses the type name followed by a record literal:
`TypeName {| ... |}` (e.g., `Point {| x: 3, y: 4 |}`).

## I/O Keywords

| Keyword | Syntax | Description |
|---------|--------|-------------|
| `print` | `print expr` | Print a value to stdout with a newline |
| `write` | `write expr` | Print a value to stdout without a newline |
| `readln` | `readln` | Read a line from stdin as a String |
| `readint` | `readint` | Read an integer from stdin |

## Lexical Rules

- **Identifiers** start with a letter and continue with letters or digits
- **Keywords** take priority — you cannot use a keyword as a variable name
- **Comments** start with `--` and extend to the end of the line
- **Strings** are delimited by `"` with standard escape sequences (`\n`, `\t`, `\r`, `\\`, `\"`)
- **Integers** are sequences of digits (`[0-9]+`)
- **Records** are delimited by `{|` and `|}`
