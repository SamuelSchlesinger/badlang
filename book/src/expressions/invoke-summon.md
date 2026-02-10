# Invoke and Summon

## invoke — Calling a Rite

`invoke` calls a rite with an argument:

```
invoke riteName argument
```

The argument is typically a record literal:

```
invoke square {| n: 5 |}
invoke distance {| a: p1, b: p2 |}
invoke factorial {| n: 10 |}
```

The argument can also be a variable or parenthesized expression:

```
let args = {| n: 5 |}
invoke square args

invoke square (args)
```

### Nested Invocations

Invoke expressions can be nested. The inner invocation must be wrapped in the
record literal or parenthesized:

```
invoke ackermann {|
  m: m - 1,
  n: invoke ackermann {| m: m, n: n - 1 |}
|}
```

### invoke in Statements

In a ritual, `invoke` can appear as a statement (result discarded) or as part
of an `utter`/`whisper`:

```
ritual main
  utter invoke factorial {| n: 10 |}
  invoke inscribe {| path: "out.txt", content: "hello" |}
seal
```

## summon — Constructing Named Records

`summon` creates a record of a specific altar type:

```
summon AltarName {| field1: value1, field2: value2, ... |}
```

### Example

```
altar Point
  x : Int
  y : Int
seal

ritual main
  let p = summon Point {| x: 3, y: 4 |}
  utter p.x
  utter p.y
seal
```

### When to Use summon

`summon` is optional. You can use anonymous record literals anywhere a named
type is expected. These two are equivalent:

```
let p = summon Point {| x: 3, y: 4 |}
let p = {| x: 3, y: 4 |}
```

`summon` is useful for documentation and clarity — it makes the intent
explicit and ensures the fields match the altar declaration.
