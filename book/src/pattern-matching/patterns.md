# Patterns

A pattern describes the expected shape and content of a value. When a value is
matched against a pattern, the match either succeeds (binding variables) or
fails (moving to the next clause).

## Variable Pattern

A bare identifier matches any value and binds it:

```
case x => ...
```

After matching, `x` holds the matched value.

## Wildcard Pattern

An underscore matches any value without binding:

```
case _ => ...
```

Use `_` when you need to accept a value but don't need to refer to it.

## Integer Literal Pattern

An integer literal matches only that exact integer:

```
case 0 => ...
case 42 => ...
```

## String Literal Pattern

A string literal matches only that exact string:

```
case "hello" => ...
```

## Record Pattern

Record patterns are the most important pattern form. They match records by
field name and can nest other patterns inside:

### Binding Fields

```
case {| x, y |} => x + y
```

This matches a record with at least fields `x` and `y`, binding both as
variables. Extra fields are ignored (width subtyping).

### Matching Literal Fields

```
case {| n: 0 |} => ...
```

This matches a record whose `n` field is exactly `0`.

### Mixing Bindings and Literals

```
case {| x: 0, y |} => y
case {| x, y: 0 |} => x
case {| x, y |}    => x + y
```

The first clause matches when `x` is `0`. The second when `y` is `0`. The
third is a catch-all.

### Nested Patterns

Patterns can nest record patterns:

```
case {| a: {| x: 0, y: 0 |} |} => "origin"
case {| a: {| x, y |} |}       => "elsewhere"
```

### Empty Record Pattern

```
case {| |} => ...
```

Matches any record (since every record has at least zero fields).

### Type-Annotated Fields

Fields can be annotated with struct types:

```
case {| p : Point |} => p.x + p.y
case {| a : Point, b : Point |} => ...
```

The annotation constrains the type but does not change the matching behavior.
The field is still bound as a variable.

## Pattern Matching Order

Clauses are tried top to bottom. The first match wins. Place more specific
patterns before more general ones:

```
fn describe
  case {| n: 0 |}    => "zero"
  case {| n: 1 |}    => "one"
  case {| n |} => "something else"
end
```

If you put the general pattern `{| n |}` first, the literal patterns would
never be reached.

## Width Subtyping in Patterns

A key feature of Stele's pattern matching is that record patterns only
specify the **minimum required fields**. A pattern `{| x, y |}` matches any
record with at least `x` and `y`, regardless of additional fields:

```
fn magnitude_sq
  case {| x, y |} => x * x + y * y
end

do main
  -- 2D point
  print magnitude_sq {| x: 3, y: 4 |}

  -- 3D point (z is ignored)
  print magnitude_sq {| x: 1, y: 2, z: 3 |}

  -- Record with extra metadata (extra is ignored)
  print magnitude_sq {| x: 10, y: 10, extra: 999 |}
end
```

This is structural subtyping in action — the fn doesn't care about fields
it didn't ask for.
