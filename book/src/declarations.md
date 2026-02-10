# Declarations

A badlang program is a sequence of top-level declarations. There are exactly
three kinds:

| Declaration | Purpose |
|-------------|---------|
| `altar`     | Declare a named record type |
| `rite`      | Define a pure function by pattern matching |
| `ritual`    | Define an effectful entry point |

Every declaration is opened by its keyword and closed by `seal`. There are
no imports, no modules, and no visibility modifiers — all declarations live in
a single flat global scope.

Declarations can appear in any order. Rites may reference other rites defined
later in the file, enabling mutual recursion without forward declarations.

The following sections cover each declaration form in detail.
