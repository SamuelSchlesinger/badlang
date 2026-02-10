# Built-in Rites

badlang provides several built-in rites for I/O and system interaction. These
are implemented in the C runtime and available in every program.

## Console I/O

### hearken

Read a line from standard input.

- **Syntax:** `hearken` (expression, not invoked)
- **Type:** `String`
- **Behavior:** Reads characters until a newline, strips the newline, returns
  the result as a string.

```
let name = hearken
```

### scry

Read an integer from standard input.

- **Syntax:** `scry` (expression, not invoked)
- **Type:** `Int`
- **Behavior:** Reads an integer from stdin using `scanf`.

```
let n = scry
```

## File I/O

### unearth

Read the contents of a file.

- **Invocation:** `invoke unearth {| path: "filename.txt" |}`
- **Argument:** `{| path: String |}`
- **Returns:** `String`
- **Behavior:** Reads the entire file contents into a string.

```
let contents = invoke unearth {| path: "data.txt" |}
utter contents
```

### inscribe

Write a string to a file.

- **Invocation:** `invoke inscribe {| path: "filename.txt", content: "data" |}`
- **Argument:** `{| path: String, content: String |}`
- **Returns:** `Void`
- **Behavior:** Creates or overwrites the file with the given content.

```
invoke inscribe {| path: "output.txt", content: "Hello from badlang!" |}
```

## Command-Line Arguments

### argc

Get the number of command-line arguments.

- **Invocation:** `invoke argc {| |}`
- **Argument:** `{| |}` (empty record)
- **Returns:** `Int`
- **Behavior:** Returns the argument count, including the program name.

```
let count = invoke argc {| |}
utter count
```

### argv

Get a command-line argument by index.

- **Invocation:** `invoke argv {| n: index |}`
- **Argument:** `{| n: Int |}`
- **Returns:** `String`
- **Behavior:** Returns the nth argument. Index 0 is the program name.

```
let program = invoke argv {| n: 0 |}
let first_arg = invoke argv {| n: 1 |}
```

## Summary Table

| Rite | Argument | Returns | Description |
|------|----------|---------|-------------|
| `hearken` | (none) | `String` | Read line from stdin |
| `scry` | (none) | `Int` | Read integer from stdin |
| `unearth` | `{| path: String |}` | `String` | Read file contents |
| `inscribe` | `{| path: String, content: String |}` | `Void` | Write to file |
| `argc` | `{| |}` | `Int` | Argument count |
| `argv` | `{| n: Int |}` | `String` | Get argument by index |
