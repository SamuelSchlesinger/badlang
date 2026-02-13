# Field Access

The dot operator (`.`) extracts a field from a record.

## Syntax

```
record.fieldName
```

## Basic Usage

```
do main
  let p = {| x: 3, y: 4 |}
  print p.x
  print p.y
end
```

Output:

```
3
4
```

## In Function Bodies

Field access is commonly used after pattern matching to drill into nested
records:

```
struct Point
  x : Int
  y : Int
end

fn distance_sq
  case {| a : Point, b : Point |} =>
    let dx = a.x - b.x
    let dy = a.y - b.y
    dx * dx + dy * dy
end
```

## Chaining

Field access can be chained to access nested records:

```
do main
  let line = {| start: {| x: 0, y: 0 |}, end: {| x: 3, y: 4 |} |}
  print line.start.x
  print line.end.y
end
```

Output:

```
0
4
```

## Type Inference

The type checker infers the required field from the access. If you write
`p.x`, the type checker knows `p` must be a record with at least an `x`
field, using row polymorphism to allow extra fields.
