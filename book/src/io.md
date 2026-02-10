# Input and Output

badlang provides built-in facilities for console I/O, file I/O, and
command-line argument access.

## Console Output

### utter — Print with Newline

`utter` evaluates an expression and prints the result to stdout, followed by
a newline:

```
utter "Hello, world!"
utter 42
utter invoke factorial {| n: 5 |}
```

Integers print as decimal numbers. Strings print as their contents (no
quotes).

### whisper — Print without Newline

`whisper` prints without appending a newline:

```
whisper "Enter your name: "
whisper "> "
```

Use `whisper` to build up output incrementally or to print prompts:

```
ritual main
  whisper "Hello, "
  whisper "world"
  utter "!"
seal
```

Output:

```
Hello, world!
```

## Console Input

### hearken — Read a String

`hearken` reads a line from stdin and returns it as a `String`. The trailing
newline is stripped:

```
ritual main
  utter "What is your name?"
  whisper "> "
  let name = hearken
  whisper "Hello, "
  whisper name
  utter "!"
seal
```

### scry — Read an Integer

`scry` reads an integer from stdin:

```
ritual main
  utter "Pick a number:"
  whisper "> "
  let n = scry
  utter "You chose:"
  utter n
seal
```

## File I/O

### inscribe — Write to a File

`inscribe` writes a string to a file, creating or overwriting it:

```
invoke inscribe {| path: "output.txt", content: "Written by badlang!" |}
```

The argument is a record with fields `path` (the file path) and `content`
(the string to write).

### unearth — Read from a File

`unearth` reads the entire contents of a file and returns it as a `String`:

```
let contents = invoke unearth {| path: "input.txt" |}
utter contents
```

The argument is a record with a single field `path`.

## Command-Line Arguments

### argc — Argument Count

`argc` returns the number of command-line arguments (including the program
name):

```
utter invoke argc {| |}
```

The argument is the empty record `{| |}`.

### argv — Get Argument by Index

`argv` returns the nth command-line argument as a string:

```
utter invoke argv {| n: 0 |}   -- program name
utter invoke argv {| n: 1 |}   -- first argument
```

The argument is a record with field `n` (the zero-based index).

## Complete I/O Example

```
ritual main
  utter "=== badlang IO demo ==="

  -- Console I/O
  utter "What is your name?"
  whisper "> "
  let name = hearken
  whisper "Hello, "
  whisper name
  utter "!"

  utter "Pick a number:"
  whisper "> "
  let n = scry
  utter "You chose:"
  utter n

  -- Command-line arguments
  utter "Number of CLI args:"
  utter invoke argc {| |}

  utter "Program name:"
  utter invoke argv {| n: 0 |}

  -- File I/O
  invoke inscribe {| path: "io_test.txt", content: "Written by badlang!" |}
  utter "Wrote io_test.txt"

  let contents = invoke unearth {| path: "io_test.txt" |}
  utter "Read back:"
  utter contents
seal
```
