# Do Blocks

A `do` is an effectful entry point — the equivalent of `main` in C.

## Syntax

```
do name
  statement1
  statement2
  ...
end
```

## The Main Do Block

Every executable Stele program must have a `do main`:

```
do main
  print "Hello, world!"
end
```

This is where execution begins.

## Statements

The body of a do is a sequence of **statements**. Statements execute in
order for their side effects. The available statement forms are:

### print — Print with Newline

```
print expr
```

Evaluates `expr` and prints the result to stdout, followed by a newline.
Integers print as decimal numbers. Strings print as their contents.

```
do main
  print 42
  print "hello"
end
```

Output:

```
42
hello
```

### write — Print without Newline

```
write expr
```

Like `print`, but does **not** append a newline. Useful for building up output
piece by piece:

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

### let — Bind a Variable

```
let name = expr
```

Evaluates `expr` and binds the result to `name` for use in subsequent
statements:

```
do main
  let x = 5
  let y = x * x
  print y
end
```

Output:

```
25
```

### Expression Statements

A bare expression can appear as a statement. Its result is discarded. This is
useful for calling functions with side effects:

```
do main
  write {| path: "out.txt", content: "data" |}
  print "Done."
end
```

## Complete Example

```
do main
  print "=== Stele IO demo ==="

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
end
```
