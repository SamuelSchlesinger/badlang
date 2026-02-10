# Pattern Matching

Pattern matching is the fundamental operation in badlang. It is the only way
to inspect values, the only way to branch, and the primary way to destructure
records.

There are two places patterns appear:

1. **`given` clauses in rites** — the function dispatches on its argument
2. **`divine` expressions** — inline pattern matching on any expression

In both cases, the structure is the same: a value is matched against a
sequence of `given` clauses, and the body of the first matching clause is
evaluated.

```
given pattern => body
```

If no pattern matches, the program crashes at runtime. There is no
exhaustiveness checking — it is the programmer's responsibility to ensure
all cases are covered.

The following sections cover the pattern language and the `divine` expression
in detail.
