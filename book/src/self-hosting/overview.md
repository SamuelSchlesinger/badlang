# Data Structures and Utilities

Before the compiler can tokenize or parse anything, it needs basic data
structures. badlang has no built-in lists, so the compiler builds them from
records.

## Linked Lists from Records

The compiler implements linked lists using tagged records:

```
rite nil
  given {| |} => {| tag: "nil" |}
seal

rite cons
  given {| head, tail |} => {| tag: "cons", head: head, tail: tail |}
seal
```

A list is either `{| tag: "nil" |}` or `{| tag: "cons", head: x, tail: xs |}`.
Pattern matching on the `tag` field distinguishes the two cases. This is a
classic encoding of algebraic data types using structural records.

### List Operations

The compiler provides a small standard library of list operations:

| Rite | Purpose |
|------|---------|
| `is_nil` | Returns `1` if the list is nil, `0` otherwise |
| `list_head` | Returns the head element |
| `list_tail` | Returns the tail |
| `list_len` | Counts elements (via tail-recursive accumulator) |
| `list_reverse` | Reverses a list (via tail-recursive accumulator) |
| `list_nth` | Returns the element at index N |

All recursive list operations use **accumulator-passing style** for
tail recursion:

```
rite list_reverse_acc
  given {| list, acc |} =>
    divine invoke is_nil {| list: list |}
      given 1 => acc
      given 0 =>
        let h = invoke list_head {| list: list |}
        let t = invoke list_tail {| list: list |}
        invoke list_reverse_acc {| list: t, acc: invoke cons {| head: h, tail: acc |} |}
    seal
seal
```

### The Accumulate-Then-Reverse Pattern

Throughout the compiler, recursive parsers accumulate results by `cons`-ing
onto the front of a list (which is O(1)), building the list in reverse order.
When the recursion finishes, a final `list_reverse` call restores the correct
order. This pattern appears in the tokenizer, the parser, and the code emitter.

## Character Classification

The compiler provides character classification rites for the tokenizer:

| Rite | Purpose |
|------|---------|
| `is_digit` | ASCII digits 0–9 |
| `is_alpha` | ASCII letters a–z, A–Z |
| `is_alnum` | Alphanumeric characters |
| `is_ws` | Whitespace (space, newline, CR, tab) |

These operate on integer character codes obtained via `char_at` — one of the
built-in string rites provided by the runtime.

## String Helpers

Since badlang strings are immutable and there is no character type, string
manipulation uses the built-in rites `strlen`, `char_at`, `substr`, and
`concat`. The compiler adds convenience wrappers like:

- `str_eq` — string equality via `strcmp`
- `str_starts_with` — prefix matching
- A string builder pattern using `concat` accumulation
