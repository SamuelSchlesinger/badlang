-- | C code generation for badlang.
--
-- Compiles the typed AST to readable, portable C99 (with GCC statement
-- expression extensions for @let@\/@divine@). The generated code is
-- self-contained — it includes an embedded runtime and can be compiled
-- directly with @cc@.
--
-- = Runtime Representation
--
-- All badlang values are represented at runtime as tagged unions:
--
-- @
-- typedef struct Value {
--     Tag tag;           /\/ TAG_INT, TAG_STR, TAG_RECORD, TAG_VOID
--     union {
--         int64_t     int_val;
--         const char* str_val;
--         struct { int num_fields; Field* fields; } record;
--     };
-- } Value;
-- @
--
-- Records are arrays of @(name, value)@ pairs, accessed by linear scan
-- on the field name. This is simple and sufficient for the language's
-- current scope.
--
-- = Memory Model
--
-- All heap allocation uses a fixed-size arena (1 MB). Values are
-- allocated sequentially and never freed — the arena is reclaimed
-- when the process exits. This eliminates the need for a garbage
-- collector.
--
-- = Compilation Strategy
--
-- * __Rites__ compile to C functions: @static Value* rite_name(Value* arg)@
-- * __Pattern matching__ compiles to cascading @if@-chains that extract
--   record fields, check null/tag/value, and bind variables
-- * __@let ... in ...@__ uses GCC statement expressions: @({ ...; result; })@
-- * __@divine@__ uses a local variable + @goto@ for early exit from
--   the pattern match
-- * __Identifiers__ are mangled with a @bl_@ prefix to avoid C keyword
--   collisions
--
-- = Entry Point
--
-- @
-- let cSource = 'emitC' typecheckedProgram
-- writeFile \"output.c\" cSource
-- -- then: cc -o output output.c
-- @
module Badlang.Emit
  ( -- * Code Generation
    emitC
  ) where

import Badlang.AST
import Data.List (intercalate)

-- ---------------------------------------------------------------------------
-- The C runtime (embedded)
-- ---------------------------------------------------------------------------

cRuntime :: String
cRuntime = unlines
  [ "#include <stdio.h>"
  , "#include <stdlib.h>"
  , "#include <string.h>"
  , "#include <stdint.h>"
  , ""
  , "/* ── badlang runtime ─────────────────────────────────────────── */"
  , ""
  , "typedef enum { TAG_INT, TAG_STR, TAG_RECORD, TAG_VOID } Tag;"
  , ""
  , "typedef struct Field {"
  , "    const char* name;"
  , "    struct Value* value;"
  , "} Field;"
  , ""
  , "typedef struct Value {"
  , "    Tag tag;"
  , "    union {"
  , "        int64_t int_val;"
  , "        const char* str_val;"
  , "        struct { int num_fields; Field* fields; } record;"
  , "    };"
  , "} Value;"
  , ""
  , "/* Arena allocator: allocate, never free (until exit) */"
  , "static char arena[1024 * 1024];"
  , "static size_t arena_pos = 0;"
  , ""
  , "static void* arena_alloc(size_t size) {"
  , "    size = (size + 7) & ~7;  /* align to 8 bytes */"
  , "    if (arena_pos + size > sizeof(arena)) {"
  , "        fprintf(stderr, \"badlang: out of memory\\n\");"
  , "        exit(1);"
  , "    }"
  , "    void* ptr = &arena[arena_pos];"
  , "    arena_pos += size;"
  , "    return ptr;"
  , "}"
  , ""
  , "static Value* make_int(int64_t n) {"
  , "    Value* v = (Value*)arena_alloc(sizeof(Value));"
  , "    v->tag = TAG_INT;"
  , "    v->int_val = n;"
  , "    return v;"
  , "}"
  , ""
  , "static Value* make_str(const char* s) {"
  , "    Value* v = (Value*)arena_alloc(sizeof(Value));"
  , "    v->tag = TAG_STR;"
  , "    v->str_val = s;"
  , "    return v;"
  , "}"
  , ""
  , "static Value* make_void(void) {"
  , "    Value* v = (Value*)arena_alloc(sizeof(Value));"
  , "    v->tag = TAG_VOID;"
  , "    return v;"
  , "}"
  , ""
  , "static Value* make_record(int n, ...) {"
  , "    /* varargs: n pairs of (const char* name, Value* value) */"
  , "    Value* v = (Value*)arena_alloc(sizeof(Value));"
  , "    v->tag = TAG_RECORD;"
  , "    v->record.num_fields = n;"
  , "    v->record.fields = (Field*)arena_alloc(sizeof(Field) * n);"
  , "    __builtin_va_list ap;"
  , "    __builtin_va_start(ap, n);"
  , "    for (int i = 0; i < n; i++) {"
  , "        v->record.fields[i].name = __builtin_va_arg(ap, const char*);"
  , "        v->record.fields[i].value = __builtin_va_arg(ap, Value*);"
  , "    }"
  , "    __builtin_va_end(ap);"
  , "    return v;"
  , "}"
  , ""
  , "static Value* record_field(Value* rec, const char* name) {"
  , "    if (rec->tag != TAG_RECORD) return NULL;"
  , "    for (int i = 0; i < rec->record.num_fields; i++) {"
  , "        if (strcmp(rec->record.fields[i].name, name) == 0)"
  , "            return rec->record.fields[i].value;"
  , "    }"
  , "    return NULL;"
  , "}"
  , ""
  , "static void utter(Value* v) {"
  , "    switch (v->tag) {"
  , "        case TAG_INT:    printf(\"%lld\\n\", (long long)v->int_val); break;"
  , "        case TAG_STR:    printf(\"%s\\n\", v->str_val); break;"
  , "        case TAG_VOID:   printf(\"void\\n\"); break;"
  , "        case TAG_RECORD: {"
  , "            printf(\"{| \");"
  , "            for (int i = 0; i < v->record.num_fields; i++) {"
  , "                if (i > 0) printf(\", \");"
  , "                printf(\"%s: \", v->record.fields[i].name);"
  , "                utter(v->record.fields[i].value);"
  , "            }"
  , "            printf(\" |}\");"
  , "            break;"
  , "        }"
  , "    }"
  , "}"
  , ""
  , "static void whisper(Value* v) {"
  , "    switch (v->tag) {"
  , "        case TAG_INT:    printf(\"%lld\", (long long)v->int_val); break;"
  , "        case TAG_STR:    printf(\"%s\", v->str_val); break;"
  , "        case TAG_VOID:   printf(\"void\"); break;"
  , "        case TAG_RECORD: {"
  , "            printf(\"{| \");"
  , "            for (int i = 0; i < v->record.num_fields; i++) {"
  , "                if (i > 0) printf(\", \");"
  , "                printf(\"%s: \", v->record.fields[i].name);"
  , "                whisper(v->record.fields[i].value);"
  , "            }"
  , "            printf(\" |}\");"
  , "            break;"
  , "        }"
  , "    }"
  , "}"
  , ""
  , "static Value* runtime_hearken(void) {"
  , "    char buf[4096];"
  , "    if (fgets(buf, sizeof(buf), stdin) == NULL) {"
  , "        return make_str(\"\");"
  , "    }"
  , "    size_t len = strlen(buf);"
  , "    if (len > 0 && buf[len-1] == '\\n') buf[len-1] = '\\0';"
  , "    char* s = (char*)arena_alloc(len + 1);"
  , "    strcpy(s, buf);"
  , "    return make_str(s);"
  , "}"
  , ""
  , "static Value* runtime_scry(void) {"
  , "    long long n = 0;"
  , "    if (scanf(\"%lld\", &n) != 1) {"
  , "        fprintf(stderr, \"badlang: scry failed to read integer\\n\");"
  , "        exit(1);"
  , "    }"
  , "    /* consume trailing newline */"
  , "    int c = getchar(); (void)c;"
  , "    return make_int((int64_t)n);"
  , "}"
  , ""
  , "/* ── file IO and argv built-in rites ─────────────────────────── */"
  , ""
  , "static int g_argc = 0;"
  , "static char** g_argv = NULL;"
  , ""
  , "static Value* rite_unearth(Value* arg) {"
  , "    Value* pathVal = record_field(arg, \"path\");"
  , "    if (!pathVal || pathVal->tag != TAG_STR) {"
  , "        fprintf(stderr, \"badlang: unearth requires path: String\\n\");"
  , "        exit(1);"
  , "    }"
  , "    FILE* f = fopen(pathVal->str_val, \"r\");"
  , "    if (!f) {"
  , "        fprintf(stderr, \"badlang: unearth cannot open '%s'\\n\", pathVal->str_val);"
  , "        exit(1);"
  , "    }"
  , "    fseek(f, 0, SEEK_END);"
  , "    long sz = ftell(f);"
  , "    fseek(f, 0, SEEK_SET);"
  , "    char* buf = (char*)arena_alloc(sz + 1);"
  , "    fread(buf, 1, sz, f);"
  , "    buf[sz] = '\\0';"
  , "    fclose(f);"
  , "    return make_str(buf);"
  , "}"
  , ""
  , "static Value* rite_inscribe(Value* arg) {"
  , "    Value* pathVal = record_field(arg, \"path\");"
  , "    Value* contentVal = record_field(arg, \"content\");"
  , "    if (!pathVal || pathVal->tag != TAG_STR ||"
  , "        !contentVal || contentVal->tag != TAG_STR) {"
  , "        fprintf(stderr, \"badlang: inscribe requires path: String, content: String\\n\");"
  , "        exit(1);"
  , "    }"
  , "    FILE* f = fopen(pathVal->str_val, \"w\");"
  , "    if (!f) {"
  , "        fprintf(stderr, \"badlang: inscribe cannot open '%s'\\n\", pathVal->str_val);"
  , "        exit(1);"
  , "    }"
  , "    fputs(contentVal->str_val, f);"
  , "    fclose(f);"
  , "    return make_void();"
  , "}"
  , ""
  , "static Value* rite_argc(Value* arg) {"
  , "    (void)arg;"
  , "    return make_int((int64_t)g_argc);"
  , "}"
  , ""
  , "static Value* rite_argv(Value* arg) {"
  , "    Value* nVal = record_field(arg, \"n\");"
  , "    if (!nVal || nVal->tag != TAG_INT) {"
  , "        fprintf(stderr, \"badlang: argv requires n: Int\\n\");"
  , "        exit(1);"
  , "    }"
  , "    int idx = (int)nVal->int_val;"
  , "    if (idx < 0 || idx >= g_argc) {"
  , "        fprintf(stderr, \"badlang: argv index %d out of bounds (argc=%d)\\n\", idx, g_argc);"
  , "        exit(1);"
  , "    }"
  , "    return make_str(g_argv[idx]);"
  , "}"
  , ""
  , "/* ── end runtime ────────────────────────────────────────────── */"
  , ""
  ]

-- ---------------------------------------------------------------------------
-- Code generation
-- ---------------------------------------------------------------------------

-- | Emit a complete, self-contained C source file from a badlang program.
--
-- The output includes the embedded runtime, forward declarations for all
-- rites, rite definitions with pattern-matching dispatch, and a @main()@
-- function generated from the @ritual main@ declaration (if present).
emitC :: Program -> String
emitC (Program decls) =
  let forwardDecls = concatMap emitForwardDecl decls
      riteDefs     = concatMap emitDecl decls
      mainFn       = emitMain decls
  in cRuntime
  ++ "\n/* ── forward declarations ──────────────────────────────────── */\n\n"
  ++ forwardDecls
  ++ "\n/* ── rite definitions ──────────────────────────────────────── */\n\n"
  ++ riteDefs
  ++ "\n/* ── entry point ──────────────────────────────────────────── */\n\n"
  ++ mainFn

-- | Built-in rite names (defined in runtime, no forward decl needed).
builtinRiteNames :: [String]
builtinRiteNames = ["unearth", "inscribe", "argc", "argv"]

-- | Emit forward declarations for rites.
emitForwardDecl :: Decl -> String
emitForwardDecl (RiteDecl name _)
  | name `elem` builtinRiteNames = ""
  | otherwise = "static Value* rite_" ++ name ++ "(Value* arg);\n"
emitForwardDecl _ = ""

-- | Emit a top-level declaration.
emitDecl :: Decl -> String
emitDecl (AltarDecl _ _) = ""  -- altars are erased at runtime
emitDecl (RiteDecl name clauses) = emitRite name clauses
emitDecl (RitualDecl _ _) = ""  -- main is handled separately

-- | Emit a rite (function) definition.
emitRite :: String -> [GivenClause] -> String
emitRite name clauses = unlines $
  [ "static Value* rite_" ++ name ++ "(Value* arg) {"
  ] ++ concatMap (emitClause 1) clauses ++
  [ "    fprintf(stderr, \"Pattern match failure in rite '" ++ name ++ "'\\n\");"
  , "    exit(1);"
  , "}"
  , ""
  ]

-- | Emit a given clause as an if-block.
emitClause :: Int -> GivenClause -> [String]
emitClause indent (GivenClause pat body) =
  let (cond, bindings) = emitPatternMatch "arg" pat
      bodyCode = emitExpr body
      ind = replicate (indent * 4) ' '
  in [ ind ++ "/* given " ++ showPat pat ++ " */"
     , ind ++ "{"
     ] ++ map (\b -> ind ++ "    " ++ b) bindings ++
     [ ind ++ "    if (" ++ cond ++ ") {"
     , ind ++ "        return " ++ bodyCode ++ ";"
     , ind ++ "    }"
     , ind ++ "}"
     ]

-- | Generate a pattern match condition and variable bindings.
-- Returns (condition_expr, [binding_statements]).
emitPatternMatch :: String -> Pattern -> (String, [String])
emitPatternMatch _var PWild = ("1", [])
emitPatternMatch var (PVar name) =
  ("1", ["Value* " ++ cName name ++ " = " ++ var ++ ";"])
emitPatternMatch var (PLit (IntLit n)) =
  (var ++ "->tag == TAG_INT && " ++ var ++ "->int_val == " ++ show n, [])
emitPatternMatch var (PLit (StrLit s)) =
  (var ++ "->tag == TAG_STR && strcmp(" ++ var ++ "->str_val, " ++ cString s ++ ") == 0", [])
emitPatternMatch var (PRec fields) =
  let (conds, binds) = unzip $ map (emitFieldMatch var) fields
      allConds = filter (/= "1") conds
      condExpr = if null allConds then "1" else intercalate " && " allConds
  in (var ++ "->tag == TAG_RECORD" ++
      (if null allConds then "" else " && " ++ condExpr),
      concat binds)
emitPatternMatch _ (PLit _) = ("0", [])

-- | Generate match code for a single record field.
emitFieldMatch :: String -> PatField -> (String, [String])
emitFieldMatch var (PatField name mPat) =
  let fieldAccess = "record_field(" ++ var ++ ", " ++ cString name ++ ")"
      tmpVar = "_f_" ++ name
      binding = "Value* " ++ tmpVar ++ " = " ++ fieldAccess ++ ";"
      nullCheck = tmpVar ++ " != NULL"
  in case mPat of
    Nothing ->
      -- Bare field: bind to variable
      (nullCheck,
       [binding, "Value* " ++ cName name ++ " = " ++ tmpVar ++ ";"])
    Just (PLit (IntLit n)) ->
      -- Literal match: check value
      (nullCheck ++ " && " ++ tmpVar ++ "->tag == TAG_INT && " ++ tmpVar ++ "->int_val == " ++ show n,
       [binding, "Value* " ++ cName name ++ " = " ++ tmpVar ++ ";"])
    Just (PLit (StrLit s)) ->
      (nullCheck ++ " && " ++ tmpVar ++ "->tag == TAG_STR && strcmp(" ++ tmpVar ++ "->str_val, " ++ cString s ++ ") == 0",
       [binding, "Value* " ++ cName name ++ " = " ++ tmpVar ++ ";"])
    Just (PVar _typeName) ->
      -- Type annotation in pattern: just bind
      (nullCheck,
       [binding, "Value* " ++ cName name ++ " = " ++ tmpVar ++ ";"])
    Just PWild ->
      (nullCheck, [binding])
    Just _ ->
      (nullCheck, [binding])

-- ---------------------------------------------------------------------------
-- Expression emission
-- ---------------------------------------------------------------------------

-- | Emit a C expression from a badlang expression.
emitExpr :: Expr -> String
emitExpr (IntLit n) = "make_int(" ++ show n ++ ")"
emitExpr (StrLit s) = "make_str(" ++ cString s ++ ")"
emitExpr (Var name) = cName name
emitExpr (BinOp op e1 e2) = emitBinOp op e1 e2
emitExpr (UnOp Neg e) = "make_int(-(" ++ emitExpr e ++ ")->int_val)"
emitExpr (UnOp Not e) = "make_int(!(" ++ emitExpr e ++ ")->int_val)"
emitExpr (FieldAccess e field) =
  "record_field(" ++ emitExpr e ++ ", " ++ cString field ++ ")"
emitExpr (Record fields) = emitRecord fields
emitExpr (Summon _altarName fields) = emitRecord fields
emitExpr (Invoke riteName arg) =
  "rite_" ++ riteName ++ "(" ++ emitExpr arg ++ ")"
emitExpr Hearken = "runtime_hearken()"
emitExpr Scry = "runtime_scry()"
emitExpr (LetIn name value body) =
  -- Use GCC statement expression: ({ type x = val; body; })
  "({" ++ " Value* " ++ cName name ++ " = " ++ emitExpr value ++ "; " ++ emitExpr body ++ "; })"
emitExpr (Divine scrutinee clauses) = emitDivine scrutinee clauses

-- | Emit a record literal.
emitRecord :: [(String, Expr)] -> String
emitRecord fields =
  "make_record(" ++ show (length fields) ++
  concatMap (\(n, e) -> ", " ++ cString n ++ ", " ++ emitExpr e) fields ++
  ")"

-- | Emit a binary operation.
emitBinOp :: BinOp -> Expr -> Expr -> String
emitBinOp op e1 e2 =
  let a = emitExpr e1
      b = emitExpr e2
  in case op of
    Add -> "make_int((" ++ a ++ ")->int_val + (" ++ b ++ ")->int_val)"
    Sub -> "make_int((" ++ a ++ ")->int_val - (" ++ b ++ ")->int_val)"
    Mul -> "make_int((" ++ a ++ ")->int_val * (" ++ b ++ ")->int_val)"
    Div -> "make_int((" ++ a ++ ")->int_val / (" ++ b ++ ")->int_val)"
    Eq  -> "make_int((" ++ a ++ ")->int_val == (" ++ b ++ ")->int_val)"
    Neq -> "make_int((" ++ a ++ ")->int_val != (" ++ b ++ ")->int_val)"
    Lt  -> "make_int((" ++ a ++ ")->int_val < (" ++ b ++ ")->int_val)"
    Gt  -> "make_int((" ++ a ++ ")->int_val > (" ++ b ++ ")->int_val)"
    Lte -> "make_int((" ++ a ++ ")->int_val <= (" ++ b ++ ")->int_val)"
    Gte -> "make_int((" ++ a ++ ")->int_val >= (" ++ b ++ ")->int_val)"
    And -> "make_int((" ++ a ++ ")->int_val && (" ++ b ++ ")->int_val)"
    Or  -> "make_int((" ++ a ++ ")->int_val || (" ++ b ++ ")->int_val)"

-- | Emit a divine (inline pattern match) as a GCC statement expression.
emitDivine :: Expr -> [GivenClause] -> String
emitDivine scrutinee clauses =
  "({ Value* _dvn = NULL; Value* _scr = " ++ emitExpr scrutinee ++ "; " ++
  concatMap emitDivineClause clauses ++
  "fprintf(stderr, \"Pattern match failure in divine\\n\"); exit(1); " ++
  "_dvn_done: _dvn; })"

emitDivineClause :: GivenClause -> String
emitDivineClause (GivenClause pat body) =
  let (cond, bindings) = emitPatternMatch "_scr" pat
  in "{ " ++ unwords bindings ++ " if (" ++ cond ++ ") { " ++
     "_dvn = " ++ emitExpr body ++ "; goto _dvn_done; } } "

-- ---------------------------------------------------------------------------
-- Main function emission
-- ---------------------------------------------------------------------------

emitMain :: [Decl] -> String
emitMain decls =
  case findRitual "main" decls of
    Nothing -> "int main(int argc, char** argv) {\n    g_argc = argc;\n    g_argv = argv;\n    return 0;\n}\n"
    Just stmts ->
      "int main(int argc, char** argv) {\n" ++
      "    g_argc = argc;\n" ++
      "    g_argv = argv;\n" ++
      concatMap (emitStmt 1) stmts ++
      "    return 0;\n}\n"

findRitual :: String -> [Decl] -> Maybe [Stmt]
findRitual _ [] = Nothing
findRitual name (RitualDecl n stmts : _) | n == name = Just stmts
findRitual name (_ : rest) = findRitual name rest

-- | Emit a statement.
emitStmt :: Int -> Stmt -> String
emitStmt indent (LetStmt name expr) =
  ind ++ "Value* " ++ cName name ++ " = " ++ emitExpr expr ++ ";\n"
  where ind = replicate (indent * 4) ' '
emitStmt indent (UtterStmt expr) =
  ind ++ "utter(" ++ emitExpr expr ++ ");\n"
  where ind = replicate (indent * 4) ' '
emitStmt indent (WhisperStmt expr) =
  ind ++ "whisper(" ++ emitExpr expr ++ ");\n"
  where ind = replicate (indent * 4) ' '
emitStmt indent (ExprStmt expr) =
  ind ++ emitExpr expr ++ ";\n"
  where ind = replicate (indent * 4) ' '

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Mangle a badlang identifier for C.
cName :: String -> String
cName "arg" = "arg"  -- reserved
cName name  = "bl_" ++ name

-- | Emit a C string literal.
cString :: String -> String
cString s = "\"" ++ concatMap escChar s ++ "\""
  where
    escChar '"'  = "\\\""
    escChar '\\' = "\\\\"
    escChar '\n' = "\\n"
    escChar c    = [c]

-- | Show a pattern for comments.
showPat :: Pattern -> String
showPat (PVar name) = name
showPat (PLit (IntLit n)) = show n
showPat (PLit (StrLit s)) = show s
showPat (PLit _) = "?"
showPat PWild = "_"
showPat (PRec fields) =
  "{| " ++ intercalate ", " (map showPatField fields) ++ " |}"

showPatField :: PatField -> String
showPatField (PatField name Nothing) = name
showPatField (PatField name (Just pat)) = name ++ ": " ++ showPat pat
