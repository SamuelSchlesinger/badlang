# Function Calls and Construction

## Calling a Function

A function is called by placing an argument after the function name:

```
riteName argument
```

The argument is typically a record literal:

```
square {| n: 5 |}
distance {| a: p1, b: p2 |}
factorial {| n: 10 |}
```

The argument can also be a variable or parenthesized expression:

```
let args = {| n: 5 |}
square args

square (args)
```

### Nested Calls

Function calls can be nested. The inner call must be wrapped in the record
literal or parenthesized:

```
ackermann {|
  m: m - 1,
  n: ackermann {| m: m, n: n - 1 |}
|}
```

### In Statements

In a do block, a function call can appear as a statement (result discarded) or
as part of a `print`/`write`:

```
do main
  print factorial {| n: 10 |}
  write {| path: "out.txt", content: "hello" |}
end
```

## Constructing Named Records

Construction uses the type name followed by a record literal:

```
TypeName {| field1: value1, field2: value2, ... |}
```

### Example

```
struct Point
  x : Int
  y : Int
end

do main
  let p = Point {| x: 3, y: 4 |}
  print p.x
  print p.y
end
```

### When to Use Named Construction
Named construction adds the struct's private runtime tag and validates its
declared fields. Anonymous records remain structurally typed, but they are not
identical constructors:

```
let named = Point {| x: 3, y: 4 |}
let anonymous = {| x: 3, y: 4 |}
```

Use named construction when satisfying a named annotation or when constructor
validation matters.
