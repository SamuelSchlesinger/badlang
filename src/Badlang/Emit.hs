-- | C code generation for badlang.
--
-- Compiles the typed AST to readable, portable C99. The generated code
-- is self-contained — it includes an embedded runtime with reference
-- counting and can be compiled directly with @cc@ (GCC or Clang).
--
-- = Runtime Representation
--
-- All badlang values are represented at runtime as tagged unions:
--
-- @
-- typedef struct Value {
--     Tag tag;           /\/ TAG_INT, TAG_STR, TAG_RECORD, TAG_VOID
--     int refcount;
--     union {
--         int64_t     int_val;
--         char*       str_val;
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
-- All heap allocation uses @malloc@ with reference counting.  Every
-- expression evaluates to an /owned/ @Value*@ (refcount incremented
-- for the recipient).  The recipient must call @rc_release@ when done.
-- Because badlang values are immutable and there are no closures,
-- cycles are impossible and reference counting is sufficient.
--
-- = Compilation Strategy
--
-- * __Rites__ compile to C functions: @static Value* rite_name(Value* arg)@
-- * __Pattern matching__ compiles to cascading @if@-chains that extract
--   record fields, check null/tag/value, and bind variables
-- * __@let ... in ...@__ uses block scoping with a result variable
--   declared outside the block
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
import Control.Monad.Trans.State.Strict (State, evalState, get, modify')

-- ---------------------------------------------------------------------------
-- Fresh variable generation
-- ---------------------------------------------------------------------------

type Fresh = State Int

freshVar :: String -> Fresh String
freshVar prefix = do
  n <- get; modify' (+1)
  return (prefix ++ show n)

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
  , "/* ── badlang runtime (reference counted) ────────────────────── */"
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
  , "    int refcount;"
  , "    union {"
  , "        int64_t int_val;"
  , "        char* str_val;"
  , "        struct { int num_fields; Field* fields; } record;"
  , "    };"
  , "} Value;"
  , ""
  , "static void rc_release(Value* v);"
  , ""
  , "static void rc_retain(Value* v) {"
  , "    v->refcount++;"
  , "}"
  , ""
  , "static Value* make_int(int64_t n) {"
  , "    Value* v = (Value*)malloc(sizeof(Value));"
  , "    v->tag = TAG_INT;"
  , "    v->refcount = 1;"
  , "    v->int_val = n;"
  , "    return v;"
  , "}"
  , ""
  , "static Value* make_str(const char* s) {"
  , "    Value* v = (Value*)malloc(sizeof(Value));"
  , "    v->tag = TAG_STR;"
  , "    v->refcount = 1;"
  , "    v->str_val = strdup(s);"
  , "    return v;"
  , "}"
  , ""
  , "static Value* make_void(void) {"
  , "    Value* v = (Value*)malloc(sizeof(Value));"
  , "    v->tag = TAG_VOID;"
  , "    v->refcount = 1;"
  , "    return v;"
  , "}"
  , ""
  , "static Value* make_record(int n, ...) {"
  , "    Value* v = (Value*)malloc(sizeof(Value));"
  , "    v->tag = TAG_RECORD;"
  , "    v->refcount = 1;"
  , "    v->record.num_fields = n;"
  , "    v->record.fields = (Field*)malloc(sizeof(Field) * n);"
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
  , "static void rc_release(Value* v) {"
  , "    if (!v) return;"
  , "    v->refcount--;"
  , "    if (v->refcount > 0) return;"
  , "    switch (v->tag) {"
  , "        case TAG_STR: free(v->str_val); break;"
  , "        case TAG_RECORD:"
  , "            for (int i = 0; i < v->record.num_fields; i++)"
  , "                rc_release(v->record.fields[i].value);"
  , "            free(v->record.fields);"
  , "            break;"
  , "        default: break;"
  , "    }"
  , "    free(v);"
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
  , "    return make_str(buf);"
  , "}"
  , ""
  , "static Value* runtime_scry(void) {"
  , "    long long n = 0;"
  , "    if (scanf(\"%lld\", &n) != 1) {"
  , "        fprintf(stderr, \"badlang: scry failed to read integer\\n\");"
  , "        exit(1);"
  , "    }"
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
  , "    char* buf = (char*)malloc(sz + 1);"
  , "    fread(buf, 1, sz, f);"
  , "    buf[sz] = '\\0';"
  , "    fclose(f);"
  , "    Value* result = make_str(buf);"
  , "    free(buf);"
  , "    return result;"
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
  , "/* ── string built-in rites ─────────────────────────────────── */"
  , ""
  , "static Value* rite_strlen(Value* arg) {"
  , "    Value* sVal = record_field(arg, \"s\");"
  , "    return make_int((int64_t)strlen(sVal->str_val));"
  , "}"
  , ""
  , "static Value* rite_char_at(Value* arg) {"
  , "    Value* sVal = record_field(arg, \"s\");"
  , "    Value* nVal = record_field(arg, \"n\");"
  , "    int64_t idx = nVal->int_val;"
  , "    int64_t len = (int64_t)strlen(sVal->str_val);"
  , "    if (idx < 0 || idx >= len) return make_int(-1);"
  , "    return make_int((int64_t)(unsigned char)sVal->str_val[idx]);"
  , "}"
  , ""
  , "static Value* rite_substr(Value* arg) {"
  , "    Value* sVal = record_field(arg, \"s\");"
  , "    Value* startVal = record_field(arg, \"start\");"
  , "    Value* lenVal = record_field(arg, \"len\");"
  , "    int64_t slen = (int64_t)strlen(sVal->str_val);"
  , "    int64_t start = startVal->int_val;"
  , "    int64_t rlen = lenVal->int_val;"
  , "    if (start < 0) start = 0;"
  , "    if (start >= slen || rlen <= 0) return make_str(\"\");"
  , "    if (start + rlen > slen) rlen = slen - start;"
  , "    char* buf = (char*)malloc(rlen + 1);"
  , "    memcpy(buf, sVal->str_val + start, rlen);"
  , "    buf[rlen] = '\\0';"
  , "    Value* result = make_str(buf);"
  , "    free(buf);"
  , "    return result;"
  , "}"
  , ""
  , "static Value* rite_concat(Value* arg) {"
  , "    Value* aVal = record_field(arg, \"a\");"
  , "    Value* bVal = record_field(arg, \"b\");"
  , "    size_t la = strlen(aVal->str_val);"
  , "    size_t lb = strlen(bVal->str_val);"
  , "    char* buf = (char*)malloc(la + lb + 1);"
  , "    memcpy(buf, aVal->str_val, la);"
  , "    memcpy(buf + la, bVal->str_val, lb);"
  , "    buf[la + lb] = '\\0';"
  , "    Value* result = make_str(buf);"
  , "    free(buf);"
  , "    return result;"
  , "}"
  , ""
  , "static Value* rite_int_to_str(Value* arg) {"
  , "    Value* nVal = record_field(arg, \"n\");"
  , "    char buf[32];"
  , "    snprintf(buf, sizeof(buf), \"%lld\", (long long)nVal->int_val);"
  , "    return make_str(buf);"
  , "}"
  , ""
  , "static Value* rite_char_of_int(Value* arg) {"
  , "    Value* nVal = record_field(arg, \"n\");"
  , "    char buf[2] = { (char)nVal->int_val, '\\0' };"
  , "    return make_str(buf);"
  , "}"
  , ""
  , "static Value* rite_strcmp(Value* arg) {"
  , "    Value* aVal = record_field(arg, \"a\");"
  , "    Value* bVal = record_field(arg, \"b\");"
  , "    int r = strcmp(aVal->str_val, bVal->str_val);"
  , "    return make_int((int64_t)(r < 0 ? -1 : (r > 0 ? 1 : 0)));"
  , "}"
  , ""
  , "/* ── end runtime ────────────────────────────────────────────── */"
  , ""
  ]

-- ---------------------------------------------------------------------------
-- Code generation
-- ---------------------------------------------------------------------------

-- | Emit a complete, self-contained C source file from a badlang program.
emitC :: Program -> String
emitC (Program decls) =
  let forwardDecls = concatMap emitForwardDecl decls
      (riteDefs, mainFn) = evalState (do
          rd <- concat <$> mapM emitDecl decls
          mf <- emitMainFn decls
          return (rd, mf)
        ) 0
  in cRuntime
  ++ "\n/* ── forward declarations ──────────────────────────────────── */\n\n"
  ++ forwardDecls
  ++ "\n/* ── rite definitions ──────────────────────────────────────── */\n\n"
  ++ riteDefs
  ++ "\n/* ── entry point ──────────────────────────────────────────── */\n\n"
  ++ mainFn

-- | Built-in rite names (defined in runtime, no forward decl needed).
builtinRiteNames :: [String]
builtinRiteNames = ["unearth", "inscribe", "argc", "argv",
                     "strlen", "char_at", "substr", "concat",
                     "int_to_str", "char_of_int", "strcmp"]

-- | Emit forward declarations for rites.
emitForwardDecl :: Decl -> String
emitForwardDecl (RiteDecl name _)
  | name `elem` builtinRiteNames = ""
  | otherwise = "static Value* rite_" ++ name ++ "(Value* arg);\n"
emitForwardDecl _ = ""

-- | Emit a top-level declaration.
emitDecl :: Decl -> Fresh String
emitDecl (AltarDecl _ _) = return ""
emitDecl (RiteDecl name clauses) = emitRite name clauses
emitDecl (RitualDecl _ _) = return ""

-- ---------------------------------------------------------------------------
-- Rite (function) emission
-- ---------------------------------------------------------------------------

-- | Emit a rite (function) definition.
emitRite :: String -> [GivenClause] -> Fresh String
emitRite name clauses = do
  clauseCode <- concat <$> mapM emitClause clauses
  return $
    "static Value* rite_" ++ name ++ "(Value* arg) {\n" ++
    clauseCode ++
    "fprintf(stderr, \"Pattern match failure in rite '" ++ name ++ "'\\n\");\n" ++
    "exit(1);\n" ++
    "}\n\n"

-- | Emit a given clause as an if-block inside a rite.
emitClause :: GivenClause -> Fresh String
emitClause (GivenClause pat body) = do
  let (cond, bindings) = emitPatternMatch "arg" pat
      boundNames = extractBoundNames pat
  (bodySetup, bodyVar) <- emitExpr body
  let retainCode = concatMap (\n -> "rc_retain(" ++ cName n ++ ");\n") boundNames
      releaseCode = concatMap (\n -> "rc_release(" ++ cName n ++ ");\n") boundNames
  return $
    "/* given " ++ showPat pat ++ " */\n" ++
    "{\n" ++
    concatMap (++ "\n") bindings ++
    "if (" ++ cond ++ ") {\n" ++
    retainCode ++
    bodySetup ++
    releaseCode ++
    "return " ++ bodyVar ++ ";\n" ++
    "}\n" ++
    "}\n"

-- ---------------------------------------------------------------------------
-- Pattern matching (pure — no Fresh needed)
-- ---------------------------------------------------------------------------

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
      (nullCheck,
       [binding, "Value* " ++ cName name ++ " = " ++ tmpVar ++ ";"])
    Just (PLit (IntLit n)) ->
      (nullCheck ++ " && " ++ tmpVar ++ "->tag == TAG_INT && " ++ tmpVar ++ "->int_val == " ++ show n,
       [binding, "Value* " ++ cName name ++ " = " ++ tmpVar ++ ";"])
    Just (PLit (StrLit s)) ->
      (nullCheck ++ " && " ++ tmpVar ++ "->tag == TAG_STR && strcmp(" ++ tmpVar ++ "->str_val, " ++ cString s ++ ") == 0",
       [binding, "Value* " ++ cName name ++ " = " ++ tmpVar ++ ";"])
    Just (PVar _typeName) ->
      (nullCheck,
       [binding, "Value* " ++ cName name ++ " = " ++ tmpVar ++ ";"])
    Just PWild ->
      (nullCheck, [binding])
    Just _ ->
      (nullCheck, [binding])

-- | Extract variable names bound by a pattern (for retain/release).
extractBoundNames :: Pattern -> [String]
extractBoundNames (PVar name) = [name]
extractBoundNames (PLit _) = []
extractBoundNames PWild = []
extractBoundNames (PRec fields) = concatMap extractFieldBound fields

extractFieldBound :: PatField -> [String]
extractFieldBound (PatField name Nothing) = [name]
extractFieldBound (PatField name (Just (PLit (IntLit _)))) = [name]
extractFieldBound (PatField name (Just (PLit (StrLit _)))) = [name]
extractFieldBound (PatField name (Just (PVar _))) = [name]
extractFieldBound (PatField _ _) = []

-- ---------------------------------------------------------------------------
-- Expression emission
-- ---------------------------------------------------------------------------

-- | Emit a C expression.  Returns @(setup_statements, result_var)@ where
-- @result_var@ holds an /owned/ @Value*@ after @setup_statements@ execute.
emitExpr :: Expr -> Fresh (String, String)

emitExpr (IntLit n) = do
  t <- freshVar "_t"
  return ("Value* " ++ t ++ " = make_int(" ++ show n ++ ");\n", t)

emitExpr (StrLit s) = do
  t <- freshVar "_t"
  return ("Value* " ++ t ++ " = make_str(" ++ cString s ++ ");\n", t)

emitExpr (Var name) = do
  t <- freshVar "_t"
  return ("Value* " ++ t ++ " = " ++ cName name ++ "; rc_retain(" ++ t ++ ");\n", t)

emitExpr (BinOp op e1 e2) = do
  (s1, v1) <- emitExpr e1
  (s2, v2) <- emitExpr e2
  t <- freshVar "_t"
  return (s1 ++ s2 ++
          "Value* " ++ t ++ " = " ++ emitBinOp op v1 v2 ++ ";\n" ++
          "rc_release(" ++ v1 ++ "); rc_release(" ++ v2 ++ ");\n", t)

emitExpr (UnOp Neg e) = do
  (s, v) <- emitExpr e
  t <- freshVar "_t"
  return (s ++
          "Value* " ++ t ++ " = make_int(-" ++ v ++ "->int_val);\n" ++
          "rc_release(" ++ v ++ ");\n", t)

emitExpr (UnOp Not e) = do
  (s, v) <- emitExpr e
  t <- freshVar "_t"
  return (s ++
          "Value* " ++ t ++ " = make_int(!" ++ v ++ "->int_val);\n" ++
          "rc_release(" ++ v ++ ");\n", t)

emitExpr (FieldAccess e field) = do
  (s, v) <- emitExpr e
  t <- freshVar "_t"
  return (s ++
          "Value* " ++ t ++ " = record_field(" ++ v ++ ", " ++ cString field ++ ");\n" ++
          "rc_retain(" ++ t ++ ");\n" ++
          "rc_release(" ++ v ++ ");\n", t)

emitExpr (Record fields) = emitRecordExpr fields

emitExpr (Summon _ fields) = emitRecordExpr fields

emitExpr (Invoke riteName arg) = do
  (s, v) <- emitExpr arg
  t <- freshVar "_t"
  return (s ++
          "Value* " ++ t ++ " = rite_" ++ riteName ++ "(" ++ v ++ ");\n" ++
          "rc_release(" ++ v ++ ");\n", t)

emitExpr Hearken = do
  t <- freshVar "_t"
  return ("Value* " ++ t ++ " = runtime_hearken();\n", t)

emitExpr Scry = do
  t <- freshVar "_t"
  return ("Value* " ++ t ++ " = runtime_scry();\n", t)

emitExpr (LetIn name value body) = do
  let (bindings, finalBody) = collectLetChain (LetIn name value body)
  -- Emit all bindings as flat statements
  bindResults <- mapM (\(n, v) -> do
    (setup, var) <- emitExpr v
    return (setup ++ "Value* " ++ cName n ++ " = " ++ var ++ ";\n", n)
    ) bindings
  let bindingsCode = concatMap fst bindResults
      boundNames   = map snd bindResults
  -- Emit body
  (bodySetup, bodyVar) <- emitExpr finalBody
  -- Release in reverse declaration order
  let releaseCode = concatMap (\n -> "rc_release(" ++ cName n ++ ");\n") (reverse boundNames)
  return (bindingsCode ++ bodySetup ++ releaseCode, bodyVar)
  where
    collectLetChain :: Expr -> ([(String, Expr)], Expr)
    collectLetChain (LetIn n v b) =
      let (rest, fb) = collectLetChain b
      in ((n, v) : rest, fb)
    collectLetChain other = ([], other)

emitExpr (Divine scrutinee clauses) = do
  (scrSetup, scrVar) <- emitExpr scrutinee
  dvn <- freshVar "_dvn"
  scr <- freshVar "_scr"
  lbl <- freshVar "_done"
  clauseCode <- concat <$> mapM (emitDivineClause scr dvn lbl) clauses
  return (scrSetup ++
          "Value* " ++ dvn ++ ";\n" ++
          "Value* " ++ scr ++ " = " ++ scrVar ++ ";\n" ++
          clauseCode ++
          "fprintf(stderr, \"Pattern match failure in divine\\n\"); exit(1);\n" ++
          lbl ++ ":;\n" ++
          "rc_release(" ++ scr ++ ");\n",
          dvn)

-- | Emit a record literal.  Field values are /adopted/ by make_record
-- (no release needed).
emitRecordExpr :: [(String, Expr)] -> Fresh (String, String)
emitRecordExpr fields = do
  fieldResults <- mapM (\(name, expr) -> do
    (s, v) <- emitExpr expr
    return (name, s, v)) fields
  t <- freshVar "_t"
  let setup = concatMap (\(_, s, _) -> s) fieldResults
      args  = concatMap (\(name, _, v) -> ", " ++ cString name ++ ", " ++ v) fieldResults
  return (setup ++
          "Value* " ++ t ++ " = make_record(" ++ show (length fields) ++ args ++ ");\n", t)

-- | Emit a binary operation (pure helper — operands are variable names).
emitBinOp :: BinOp -> String -> String -> String
emitBinOp op a b = case op of
    Add -> "make_int(" ++ a ++ "->int_val + " ++ b ++ "->int_val)"
    Sub -> "make_int(" ++ a ++ "->int_val - " ++ b ++ "->int_val)"
    Mul -> "make_int(" ++ a ++ "->int_val * " ++ b ++ "->int_val)"
    Div -> "make_int(" ++ a ++ "->int_val / " ++ b ++ "->int_val)"
    Mod -> "make_int(" ++ a ++ "->int_val % " ++ b ++ "->int_val)"
    Eq  -> "make_int(" ++ a ++ "->int_val == " ++ b ++ "->int_val)"
    Neq -> "make_int(" ++ a ++ "->int_val != " ++ b ++ "->int_val)"
    Lt  -> "make_int(" ++ a ++ "->int_val < " ++ b ++ "->int_val)"
    Gt  -> "make_int(" ++ a ++ "->int_val > " ++ b ++ "->int_val)"
    Lte -> "make_int(" ++ a ++ "->int_val <= " ++ b ++ "->int_val)"
    Gte -> "make_int(" ++ a ++ "->int_val >= " ++ b ++ "->int_val)"
    And -> "make_int(" ++ a ++ "->int_val && " ++ b ++ "->int_val)"
    Or  -> "make_int(" ++ a ++ "->int_val || " ++ b ++ "->int_val)"

-- ---------------------------------------------------------------------------
-- Divine (inline pattern match) emission
-- ---------------------------------------------------------------------------

-- | Emit a single divine clause.
emitDivineClause :: String -> String -> String -> GivenClause -> Fresh String
emitDivineClause scr dvn lbl (GivenClause pat body) = do
  let (cond, bindings) = emitPatternMatch scr pat
      boundNames = extractBoundNames pat
  (bodySetup, bodyVar) <- emitExpr body
  let retainCode  = concatMap (\n -> "rc_retain(" ++ cName n ++ ");\n") boundNames
      releaseCode = concatMap (\n -> "rc_release(" ++ cName n ++ ");\n") boundNames
  return $
    "{\n" ++
    concatMap (++ "\n") bindings ++
    "if (" ++ cond ++ ") {\n" ++
    retainCode ++
    bodySetup ++
    releaseCode ++
    dvn ++ " = " ++ bodyVar ++ ";\n" ++
    "goto " ++ lbl ++ ";\n" ++
    "}\n" ++
    "}\n"

-- ---------------------------------------------------------------------------
-- Statement and main function emission
-- ---------------------------------------------------------------------------

-- | Emit a statement.
emitStmt :: Stmt -> Fresh String
emitStmt (LetStmt name expr) = do
  (setup, var) <- emitExpr expr
  return $ setup ++ "Value* " ++ cName name ++ " = " ++ var ++ ";\n"
emitStmt (UtterStmt expr) = do
  (setup, var) <- emitExpr expr
  return $ setup ++ "utter(" ++ var ++ ");\n" ++ "rc_release(" ++ var ++ ");\n"
emitStmt (WhisperStmt expr) = do
  (setup, var) <- emitExpr expr
  return $ setup ++ "whisper(" ++ var ++ ");\n" ++ "rc_release(" ++ var ++ ");\n"
emitStmt (ExprStmt expr) = do
  (setup, var) <- emitExpr expr
  return $ setup ++ "rc_release(" ++ var ++ ");\n"

-- | Emit the main function.
emitMainFn :: [Decl] -> Fresh String
emitMainFn decls =
  case findRitual "main" decls of
    Nothing -> return "int main(int argc, char** argv) {\n    g_argc = argc;\n    g_argv = argv;\n    return 0;\n}\n"
    Just stmts -> do
      stmtCode <- concat <$> mapM emitStmt stmts
      let letNames = [name | LetStmt name _ <- stmts]
          releaseCode = concatMap (\n -> "rc_release(" ++ cName n ++ ");\n") (reverse letNames)
      return $
        "int main(int argc, char** argv) {\n" ++
        "g_argc = argc;\n" ++
        "g_argv = argv;\n" ++
        stmtCode ++
        releaseCode ++
        "return 0;\n}\n"

findRitual :: String -> [Decl] -> Maybe [Stmt]
findRitual _ [] = Nothing
findRitual name (RitualDecl n stmts : _) | n == name = Just stmts
findRitual name (_ : rest) = findRitual name rest

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Mangle a badlang identifier for C.
cName :: String -> String
cName "arg" = "arg"
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
