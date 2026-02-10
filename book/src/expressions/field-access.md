# Field Access

The dot operator (`.`) extracts a field from a record.

## Syntax

```
record.fieldName
```

## Basic Usage

```
ritual main
  let p = {| x: 3, y: 4 |}
  utter p.x
  utter p.y
seal
```

Output:

```
3
4
```

## In Rite Bodies

Field access is commonly used after pattern matching to drill into nested
records:

```
altar Point
  x : Int
  y : Int
seal

rite distance_sq
  given {| a : Point, b : Point |} =>
    let dx = a.x - b.x
    let dy = a.y - b.y
    dx * dx + dy * dy
seal
```

## Chaining

Field access can be chained to access nested records:

```
ritual main
  let line = {| start: {| x: 0, y: 0 |}, end: {| x: 3, y: 4 |} |}
  utter line.start.x
  utter line.end.y
seal
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
