# Built-in Functions

Stele provides several built-in functions for I/O and system interaction.
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

### read

Read the contents of a file.

- **Call:** `read {| path: "filename.txt" |}`
- **Argument:** `{| path: String |}`
- **Returns:** `String`
- **Behavior:** Reads the entire file contents into a string.

```
let contents = read {| path: "data.txt" |}
print contents
```

### write

Write a string to a file.

- **Call:** `write {| path: "filename.txt", content: "data" |}`
- **Argument:** `{| path: String, content: String |}`
- **Returns:** `Void`
- **Behavior:** Creates or overwrites the file with the case content.

```
write {| path: "output.txt", content: "Hello from Stele!" |}
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

## Process Control

### sh

Run a shell command.

- **Call:** `sh {| command: "echo hello" |}`
- **Argument:** `{| command: String |}`
- **Returns:** `Int`
- **Behavior:** Executes the command via the host shell and returns the
  process status code.

### terminate

Exit the current process immediately.

- **Call:** `terminate {| code: 1 |}`
- **Argument:** `{| code: Int |}`
- **Returns:** `Void`
- **Behavior:** Terminates the process with the provided exit code.

### spawn

Run a shell command in a child process and return its PID.

- **Call:** `spawn {| command: "sleep 1" |}`
- **Argument:** `{| command: String |}`
- **Returns:** `Int`
- **Behavior:** Forks, executes the command via `/bin/sh -c ...`, and returns
  the child PID to the caller.

### await

Wait for a child process to exit.

- **Call:** `await {| pid: 12345 |}`
- **Argument:** `{| pid: Int |}`
- **Returns:** `Int`
- **Behavior:** Blocks until the child exits and returns its exit status.

### sleep_ms

Sleep the current process for a number of milliseconds.

- **Call:** `sleep_ms {| ms: 250 |}`
- **Argument:** `{| ms: Int |}`
- **Returns:** `Void`
- **Behavior:** Sleeps for the requested duration (negative values are treated
  as `0`).

## Summary Table

| Function | Argument | Returns | Description |
|------|----------|---------|-------------|
| `readln` | (none) | `String` | Read line from stdin |
| `readint` | (none) | `Int` | Read integer from stdin |
| `read` | `{| path: String |}` | `String` | Read file contents |
| `write` | `{| path: String, content: String |}` | `Void` | Write to file |
| `argc` | `{| |}` | `Int` | Argument count |
| `argv` | `{| n: Int |}` | `String` | Get argument by index |
| `sh` | `{| command: String |}` | `Int` | Run shell command |
| `terminate` | `{| code: Int |}` | `Void` | Exit the process |
| `spawn` | `{| command: String |}` | `Int` | Spawn child process (shell command) |
| `await` | `{| pid: Int |}` | `Int` | Wait for child and return status |
| `sleep_ms` | `{| ms: Int |}` | `Void` | Sleep for a duration in ms |
