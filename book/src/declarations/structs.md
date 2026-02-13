# Structs

A `struct` declares a named record type.

## Syntax

```
struct TypeName
  field1 : Type
  field2 : Type
  ...
end
```

## Example

```
struct Point
  x : Int
  y : Int
end

struct Person
  name : String
  age : Int
end
```

## Semantics

An struct gives a name to a specific set of typed fields. Once declared, you can:

- Use the type name in pattern annotations: `case {| p : Point |} => ...`
- Construct values of that type: `Point {| x: 3, y: 4 |}`

Struct declarations are **erased at runtime**. They exist only to guide type
checking. The fields you declare in a struct become the expected fields when
you construct a value of that type.

## Available Types

Field types in struct declarations can be:

| Type | Description |
|------|-------------|
| `Int` | 64-bit signed integer |
| `String` | Immutable string |
| *StructName* | A previously declared struct type |

## Using Structs in Patterns

When a pattern annotates a field with an struct type, the type checker ensures
the argument at that position has the required fields:

```
struct Pair
  fst : Int
  snd : Int
end

fn swap
  case {| p : Pair |} => Pair {| fst: p.snd, snd: p.fst |}
end
```

## Structs Are Optional

You do not need to declare an struct to use records. Anonymous record literals
work everywhere:

```
fn add_xy
  case {| x, y |} => x + y
end

do main
  -- No struct needed
  print add_xy {| x: 3, y: 4 |}
end
```

Structs are useful when you want to give a meaningful name to a recurring
record shape, or when you want type annotations in patterns.
