# Sum Types

badlang supports sum types via the `oneof` declaration. A sum type defines a
closed set of variants, each of which may carry named fields (like a struct) or
be nullary (carrying no data).

## Declaring a Sum Type

Use `oneof ... end` to declare a sum type:

```
oneof Color
  Red
  Green
  Blue
end

oneof Shape
  Circle {| radius: Int |}
  Rectangle {| width: Int, height: Int |}
  Point
end
```

Each variant is either:

- **Nullary** -- just a name, like `Red` or `Point`.
- **With fields** -- a name followed by a record type, like `Circle {| radius: Int |}`.

## Constructing Values

Nullary variants are used directly as expressions:

```
let c = Red
```

Variants with fields are constructed by providing a record literal with the
variant name:

```
let s = Circle {| radius: 5 |}
let r = Rectangle {| width: 10, height: 20 |}
```

## Pattern Matching on Sum Types

Use pattern matching to branch on the variant of a sum type value. Variant
patterns mirror construction syntax:

```
match shape
  case Circle {| radius |} => radius * radius * 3
  case Rectangle {| width, height |} => width * height
  case Point => 0
end
```

Nullary variants match with just the variant name:

```
match color
  case Red => "red"
  case Green => "green"
  case Blue => "blue"
end
```

You can also use inline match expressions on sum type values wherever an
expression is expected:

```
let area = match shape
  case Circle {| radius |} => radius * radius * 3
  case Rectangle {| width, height |} => width * height
  case Point => 0
end
```

## Runtime Representation

At runtime, a sum type value is represented as a record with a `__tag` field
that identifies the variant. For a nullary variant like `Red`, the value is
simply `{| __tag: "Red" |}`. For a variant with fields like
`Circle {| radius: 5 |}`, the value is `{| __tag: "Circle", radius: 5 |}`.

This means sum type values are ordinary records under the hood, and the pattern
matching machinery inspects the `__tag` field to determine which branch to take.
