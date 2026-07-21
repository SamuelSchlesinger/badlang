# Declarations

A Stele program is a sequence of top-level declarations:

| Declaration | Purpose |
|-------------|---------|
| `struct`     | Declare a named record type |
| `oneof`      | Declare a nominal sum type |
| `fn`      | Define a function by pattern matching |
| `do`    | Define an effectful entry point |
| `test`    | Define an embedded test body |
| `import`  | Load a module for qualified access |
| `open`    | Load a module and bring exports into scope |

Block declarations close with `end`; `import` and `open` occupy one line.
Sibling `.steli` files control module visibility. The resolver flattens modules
and mangles names before type checking and code generation.

Declarations can appear in any order. Functions may reference other functions
defined later in the file, enabling mutual recursion without forward
declarations.

The following sections cover each declaration form in detail.
