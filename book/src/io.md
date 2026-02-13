# Input and Output

Stele provides built-in facilities for console I/O, file I/O, and
command-line argument access.

## Console Output

### print — Print with Newline

`print` evaluates an expression and prints the result to stdout, followed by
a newline:

```
print "Hello, world!"
print 42
print factorial {| n: 5 |}
```

Integers print as decimal numbers. Strings print as their contents (no
quotes).

### write — Print without Newline

`write` prints without appending a newline:

```
write "Enter your name: "
write "> "
```

Use `write` to build up output incrementally or to print prompts:

```
do main
  write "Hello, "
  write "world"
  print "!"
end
```

Output:

```
Hello, world!
```

## Console Input

### readln — Read a String

`readln` reads a line from stdin and returns it as a `String`. The trailing
newline is stripped:

```
do main
  print "What is your name?"
  write "> "
  let name = readln
  write "Hello, "
  write name
  print "!"
end
```

### readint — Read an Integer

`readint` reads an integer from stdin:

```
do main
  print "Pick a number:"
  write "> "
  let n = readint
  print "You chose:"
  print n
end
```

## File I/O

### inscribe — Write to a File

`inscribe` writes a string to a file, creating or overwriting it:

```
inscribe {| path: "output.txt", content: "Written by Stele!" |}
```

The argument is a record with fields `path` (the file path) and `content`
(the string to write).

### unearth — Read from a File

`unearth` reads the entire contents of a file and returns it as a `String`:

```
let contents = unearth {| path: "input.txt" |}
print contents
```

The argument is a record with a single field `path`.

## Command-Line Arguments

### argc — Argument Count

`argc` returns the number of command-line arguments (including the program
name):

```
print argc {| |}
```

The argument is the empty record `{| |}`.

### argv — Get Argument by Index

`argv` returns the nth command-line argument as a string:

```
print argv {| n: 0 |}   -- program name
print argv {| n: 1 |}   -- first argument
```

The argument is a record with field `n` (the zero-based index).

## Complete I/O Example

```
do main
  print "=== Stele IO demo ==="

  -- Console I/O
  print "What is your name?"
  write "> "
  let name = readln
  write "Hello, "
  write name
  print "!"

  print "Pick a number:"
  write "> "
  let n = readint
  print "You chose:"
  print n

  -- Command-line arguments
  print "Number of CLI args:"
  print argc {| |}

  print "Program name:"
  print argv {| n: 0 |}

  -- File I/O
  inscribe {| path: "io_test.txt", content: "Written by Stele!" |}
  print "Wrote io_test.txt"

  let contents = unearth {| path: "io_test.txt" |}
  print "Read back:"
  print contents
end
```
