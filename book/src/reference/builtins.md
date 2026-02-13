# Built-in Functions

badlang provides several built-in functions for I/O and system interaction.
These are implemented in the C runtime and available in every program.

## Console I/O

### readln

Read a line from standard input.

- **Syntax:** `readln` (standalone expression)
- **Type:** `String`
- **Behavior:** Reads characters until a newline, strips the newline, returns
  the result as a string.

```
let name = readln
```

### readint

Read an integer from standard input.

- **Syntax:** `readint` (standalone expression)
- **Type:** `Int`
- **Behavior:** Reads an integer from stdin using `scanf`.

```
let n = readint
```

## File I/O

### unearth

Read the contents of a file.

- **Call:** `unearth {| path: "filename.txt" |}`
- **Argument:** `{| path: String |}`
- **Returns:** `String`
- **Behavior:** Reads the entire file contents into a string.

```
let contents = unearth {| path: "data.txt" |}
print contents
```

### inscribe

Write a string to a file.

- **Call:** `inscribe {| path: "filename.txt", content: "data" |}`
- **Argument:** `{| path: String, content: String |}`
- **Returns:** `Void`
- **Behavior:** Creates or overwrites the file with the case content.

```
inscribe {| path: "output.txt", content: "Hello from badlang!" |}
```

## Command-Line Arguments

### argc

Get the number of command-line arguments.

- **Call:** `argc {| |}`
- **Argument:** `{| |}` (empty record)
- **Returns:** `Int`
- **Behavior:** Returns the argument count, including the program name.

```
let count = argc {| |}
print count
```

### argv

Get a command-line argument by index.

- **Call:** `argv {| n: index |}`
- **Argument:** `{| n: Int |}`
- **Returns:** `String`
- **Behavior:** Returns the nth argument. Index 0 is the program name.

```
let program = argv {| n: 0 |}
let first_arg = argv {| n: 1 |}
```

## Summary Table

| Function | Argument | Returns | Description |
|------|----------|---------|-------------|
| `readln` | (none) | `String` | Read line from stdin |
| `readint` | (none) | `Int` | Read integer from stdin |
| `unearth` | `{| path: String |}` | `String` | Read file contents |
| `inscribe` | `{| path: String, content: String |}` | `Void` | Write to file |
| `argc` | `{| |}` | `Int` | Argument count |
| `argv` | `{| n: Int |}` | `String` | Get argument by index |
