# Keyword Reference

All reserved keywords in badlang.

## Declaration Keywords

| Keyword | Syntax | Description |
|---------|--------|-------------|
| `altar` | `altar Name ... seal` | Declare a named record type with typed fields |
| `rite` | `rite name given ... seal` | Define a pure function by pattern matching |
| `ritual` | `ritual name ... seal` | Define an effectful entry point |
| `seal` | (closing delimiter) | Close an altar, rite, ritual, or divine block |

## Pattern Matching Keywords

| Keyword | Syntax | Description |
|---------|--------|-------------|
| `given` | `given pattern => body` | A pattern clause in a rite or divine |
| `divine` | `divine expr given ... seal` | Inline pattern match expression |

## Expression Keywords

| Keyword | Syntax | Description |
|---------|--------|-------------|
| `invoke` | `invoke name arg` | Call a rite with an argument |
| `summon` | `summon AltarName {| ... |}` | Construct a value of a named record type |
| `let` | `let name = expr` | Bind a local variable |
| `in` | (reserved) | Reserved for future use |

## I/O Keywords

| Keyword | Syntax | Description |
|---------|--------|-------------|
| `utter` | `utter expr` | Print a value to stdout with a newline |
| `whisper` | `whisper expr` | Print a value to stdout without a newline |
| `hearken` | `hearken` | Read a line from stdin as a String |
| `scry` | `scry` | Read an integer from stdin |

## Lexical Rules

- **Identifiers** start with a letter and continue with letters or digits
- **Keywords** take priority — you cannot use a keyword as a variable name
- **Comments** start with `--` and extend to the end of the line
- **Strings** are delimited by `"` with no escape sequences
- **Integers** are sequences of digits (`[0-9]+`)
- **Records** are delimited by `{|` and `|}`
