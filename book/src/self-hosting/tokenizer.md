# Tokenizer

The tokenizer (lexer) converts a source string into a list of tokens. Each
token is a record with a `type` and a `value`:

```
{| type: "ident", value: "factorial" |}
{| type: "int",   value: "42" |}
{| type: "+",     value: "+" |}
```

## Token Types

The tokenizer recognizes the following token types:

| Category | Types |
|----------|-------|
| Keywords | `fn`, `do`, `struct`, `case`, `end`, `let`, `match`, `readln`, `readint`, `print`, `write`, `oneof` |
| Identifiers | `ident` |
| Literals | `int`, `str` |
| Operators | `+`, `-`, `*`, `/`, `%`, `==`, `!=`, `<`, `>`, `<=`, `>=`, `&&`, `\|\|` |
| Delimiters | `{\|`, `\|}`, `(`, `)`, `.`, `,`, `:`, `=`, `=>` |
| Special | `_` (wildcard), `eof` |

## How It Works

The tokenizer operates on a source string and a position index. At each step,
it skips whitespace and `--` comments, then dispatches based on the current
character:

1. **Digits** → `lex_number`: Scan forward to find the end of the digit
   sequence, extract with `substr`.

2. **`"`** → `lex_string`: Scan forward to the closing `"` (respecting
   backslash escapes), extract the contents (without quotes), and process
   escape sequences (`\n`, `\t`, `\r`, `\\`, `\"`) into their actual
   characters.

3. **Letters or `_`** → `lex_word`: Scan to the end of the alphanumeric
   sequence. Check against the keyword list with `is_keyword`. If it matches,
   the token type is the keyword itself (e.g., `"fn"`). A lone `_` becomes
   the wildcard token. Otherwise, it's an `ident`.

4. **Punctuation** → `lex_punct`: Check for two-character tokens first (`==`,
   `=>`, `!=`, `<=`, `>=`, `{|`, `|}`, `||`, `&&`), then fall back to
   single-character tokens.

## The Tokenization Loop

The main loop (`tokenize_loop`) is tail-recursive with an accumulator:

```
fn tokenize_loop
  case {| src, pos, acc |} =>
    -- skip whitespace and comments
    -- if at end of string, reverse acc and append EOF
    -- otherwise, lex next token, cons onto acc, recurse
end
```

Tokens accumulate in reverse order via `cons` and are reversed at the end.
The final token list always ends with an `{| type: "eof", value: "" |}` sentinel.

## Whitespace and Comments

The `skip_ws_cmt` fn handles both whitespace and line comments recursively:

- Skip any whitespace characters
- If the next two characters are `--`, skip to end of line
- Repeat until neither whitespace nor comment is found

This means comments can appear anywhere whitespace is legal.
