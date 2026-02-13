# Records

Records are the universal data structure in Stele. They are collections of
named fields, each holding a value. Every function argument is a record. Every
structured value is a record.

## Record Literals

Record literals are written between "pillars" `{|` and `|}`:

```
{| x: 1, y: 2 |}
{| name: "Alice", age: 30 |}
{| n: 42 |}
{| |}
```

The last form, `{| |}`, is the empty record — used when a fn takes no
meaningful arguments.

## Fields

Each field has a name and a value, separated by a colon:

```
{| fieldName: expression |}
```

Multiple fields are separated by commas:

```
{| x: 1, y: 2, z: 3 |}
```

Field values can be any expression, including nested records:

```
{| origin: {| x: 0, y: 0 |}, direction: {| x: 1, y: 0 |} |}
```

## Records Are Structural

Records in Stele are **structural**, not nominal. Two records with the same
fields and types are the same type, regardless of how they were created:

```
fn add_xy
  case {| x, y |} => x + y
end

do main
  -- All of these are acceptable arguments:
  print add_xy {| x: 1, y: 2 |}
  print add_xy {| x: 10, y: 20 |}
  print add_xy {| x: 5, y: 5, z: 100 |}
end
```

## Named Records
While anonymous records work everywhere, you can use `struct` to declare named
record types and construct them with the type name:

```
struct Point
  x : Int
  y : Int
end

do main
  let p = Point {| x: 3, y: 4 |}
  print p.x
end
```

See [Function Calls and Construction](./function-calls.md) for details.

## Records at Runtime

At runtime, every record is a tagged value containing an array of
`(name, value)` pairs. Field access is by name lookup. This means records are
lightweight and flexible, but field access is linear in the number of fields.
