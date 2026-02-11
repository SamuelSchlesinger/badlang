# Literals and Variables

## Integer Literals

Integer literals are sequences of digits, representing 64-bit signed integers:

```
0
42
1000000
```

Negative integers are written with the unary minus operator:

```
-1
-42
```

## String Literals

String literals are enclosed in double quotes:

```
"hello"
"Hello, world!"
""
```

String literals support the following escape sequences:

| Escape | Character |
|--------|-----------|
| `\n` | Newline |
| `\t` | Tab |
| `\r` | Carriage return |
| `\\` | Backslash |
| `\"` | Double quote |

For example, `"line1\nline2"` contains an actual newline between the two words.

## Variables

A variable is an identifier that refers to a previously bound value. Identifiers
start with a letter and continue with letters or digits:

```
x
name
result42
myPoint
```

Variables are introduced by:

- **Pattern matching** — field names in `given` clauses become variables
- **let bindings** — `let x = expr` introduces `x`

## Reserved Words

The following identifiers are keywords and cannot be used as variable names:

```
altar    rite      ritual    given     seal
let      in        invoke    summon    utter
divine   hearken   scry      whisper
```
