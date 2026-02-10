# Rituals

A `ritual` is an effectful entry point — the equivalent of `main` in C.

## Syntax

```
ritual name
  statement1
  statement2
  ...
seal
```

## The Main Ritual

Every executable badlang program must have a `ritual main`:

```
ritual main
  utter "Hello, world!"
seal
```

This is where execution begins.

## Statements

The body of a ritual is a sequence of **statements**. Statements execute in
order for their side effects. The available statement forms are:

### utter — Print with Newline

```
utter expr
```

Evaluates `expr` and prints the result to stdout, followed by a newline.
Integers print as decimal numbers. Strings print as their contents.

```
ritual main
  utter 42
  utter "hello"
seal
```

Output:

```
42
hello
```

### whisper — Print without Newline

```
whisper expr
```

Like `utter`, but does **not** append a newline. Useful for building up output
piece by piece:

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

### let — Bind a Variable

```
let name = expr
```

Evaluates `expr` and binds the result to `name` for use in subsequent
statements:

```
ritual main
  let x = 5
  let y = x * x
  utter y
seal
```

Output:

```
25
```

### Expression Statements

A bare expression can appear as a statement. Its result is discarded. This is
useful for calling rites with side effects:

```
ritual main
  invoke inscribe {| path: "out.txt", content: "data" |}
  utter "Done."
seal
```

## Complete Example

```
ritual main
  utter "=== badlang IO demo ==="

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
seal
```
