# Altars

An `altar` declares a named record type.

## Syntax

```
altar TypeName
  field1 : Type
  field2 : Type
  ...
seal
```

## Example

```
altar Point
  x : Int
  y : Int
seal

altar Person
  name : String
  age : Int
seal
```

## Semantics

An altar gives a name to a specific set of typed fields. Once declared, you can:

- Use the type name in pattern annotations: `given {| p : Point |} => ...`
- Construct values of that type with `summon`: `summon Point {| x: 3, y: 4 |}`

Altar declarations are **erased at runtime**. They exist only to guide type
checking. The fields you declare in an altar become the expected fields when
you `summon` a value of that type.

## Available Types

Field types in altar declarations can be:

| Type | Description |
|------|-------------|
| `Int` | 64-bit signed integer |
| `String` | Immutable string |
| *AltarName* | A previously declared altar type |

## Using Altars in Patterns

When a pattern annotates a field with an altar type, the type checker ensures
the argument at that position has the required fields:

```
altar Pair
  fst : Int
  snd : Int
seal

rite swap
  given {| p : Pair |} => summon Pair {| fst: p.snd, snd: p.fst |}
seal
```

## Altars Are Optional

You do not need to declare an altar to use records. Anonymous record literals
work everywhere:

```
rite add_xy
  given {| x, y |} => x + y
seal

ritual main
  -- No altar needed
  utter invoke add_xy {| x: 3, y: 4 |}
seal
```

Altars are useful when you want to give a meaningful name to a recurring
record shape, or when you want type annotations in patterns.
