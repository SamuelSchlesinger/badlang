# Declarations

A Stele program is a sequence of top-level declarations. There are exactly
three kinds:

| Declaration | Purpose |
|-------------|---------|
| `struct`     | Declare a named record type |
| `fn`      | Define a pure function by pattern matching |
| `do`    | Define an effectful entry point |

Every declaration is opened by its keyword and closed by `end`. There are
no imports, no modules, and no visibility modifiers — all declarations live in
a single flat global scope.

Declarations can appear in any order. Functions may reference other functions
defined later in the file, enabling mutual recursion without forward
declarations.

The following sections cover each declaration form in detail.
