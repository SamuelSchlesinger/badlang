-- | C code generation for stele, consuming the IR.
--
-- Translates an 'IRProgram' into a self-contained C99 source file.
-- The generated code includes an embedded runtime with reference counting
-- and can be compiled directly with @cc@ (GCC or Clang).
--
-- The IR has already resolved all pattern matching, match expressions,
-- and let-in chains into flat instructions and basic block control flow.
-- This backend is a mechanical translation: each IR instruction maps to
-- one or two lines of C, and basic blocks map to labeled sections with
-- gotos.
module Stele.EmitC
  ( emitCFromIR
  ) where

import Stele.IR
import qualified Data.Set as Set

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
  , "/* ── stele runtime (reference counted) ────────────────────── */"
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
  , "static void stele_print(Value* v) {"
  , "    switch (v->tag) {"
  , "        case TAG_INT:    printf(\"%lld\\n\", (long long)v->int_val); break;"
  , "        case TAG_STR:    printf(\"%s\\n\", v->str_val); break;"
  , "        case TAG_VOID:   printf(\"void\\n\"); break;"
  , "        case TAG_RECORD: {"
  , "            printf(\"{| \");"
  , "            for (int i = 0; i < v->record.num_fields; i++) {"
  , "                if (i > 0) printf(\", \");"
  , "                printf(\"%s: \", v->record.fields[i].name);"
  , "                stele_print(v->record.fields[i].value);"
  , "            }"
  , "            printf(\" |}\");"
  , "            break;"
  , "        }"
  , "    }"
  , "}"
  , ""
  , "static void stele_write(Value* v) {"
  , "    switch (v->tag) {"
  , "        case TAG_INT:    printf(\"%lld\", (long long)v->int_val); break;"
  , "        case TAG_STR:    printf(\"%s\", v->str_val); break;"
  , "        case TAG_VOID:   printf(\"void\"); break;"
  , "        case TAG_RECORD: {"
  , "            printf(\"{| \");"
  , "            for (int i = 0; i < v->record.num_fields; i++) {"
  , "                if (i > 0) printf(\", \");"
  , "                printf(\"%s: \", v->record.fields[i].name);"
  , "                stele_write(v->record.fields[i].value);"
  , "            }"
  , "            printf(\" |}\");"
  , "            break;"
  , "        }"
  , "    }"
  , "}"
  , ""
  , "static Value* runtime_readln(void) {"
  , "    char buf[4096];"
  , "    if (fgets(buf, sizeof(buf), stdin) == NULL) {"
  , "        return make_str(\"\");"
  , "    }"
  , "    size_t len = strlen(buf);"
  , "    if (len > 0 && buf[len-1] == '\\n') buf[len-1] = '\\0';"
  , "    return make_str(buf);"
  , "}"
  , ""
  , "static Value* runtime_readint(void) {"
  , "    long long n = 0;"
  , "    if (scanf(\"%lld\", &n) != 1) {"
  , "        fprintf(stderr, \"stele: readint failed to read integer\\n\");"
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
  , "static Value* fn_unearth(Value* arg) {"
  , "    Value* pathVal = record_field(arg, \"path\");"
  , "    if (!pathVal || pathVal->tag != TAG_STR) {"
  , "        fprintf(stderr, \"stele: unearth requires path: String\\n\");"
  , "        exit(1);"
  , "    }"
  , "    FILE* f = fopen(pathVal->str_val, \"r\");"
  , "    if (!f) {"
  , "        fprintf(stderr, \"stele: unearth cannot open '%s'\\n\", pathVal->str_val);"
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
  , "static Value* fn_inscribe(Value* arg) {"
  , "    Value* pathVal = record_field(arg, \"path\");"
  , "    Value* contentVal = record_field(arg, \"content\");"
  , "    if (!pathVal || pathVal->tag != TAG_STR ||"
  , "        !contentVal || contentVal->tag != TAG_STR) {"
  , "        fprintf(stderr, \"stele: inscribe requires path: String, content: String\\n\");"
  , "        exit(1);"
  , "    }"
  , "    FILE* f = fopen(pathVal->str_val, \"w\");"
  , "    if (!f) {"
  , "        fprintf(stderr, \"stele: inscribe cannot open '%s'\\n\", pathVal->str_val);"
  , "        exit(1);"
  , "    }"
  , "    fputs(contentVal->str_val, f);"
  , "    fclose(f);"
  , "    return make_void();"
  , "}"
  , ""
  , "static Value* fn_argc(Value* arg) {"
  , "    (void)arg;"
  , "    return make_int((int64_t)g_argc);"
  , "}"
  , ""
  , "static Value* fn_argv(Value* arg) {"
  , "    Value* nVal = record_field(arg, \"n\");"
  , "    if (!nVal || nVal->tag != TAG_INT) {"
  , "        fprintf(stderr, \"stele: argv requires n: Int\\n\");"
  , "        exit(1);"
  , "    }"
  , "    int idx = (int)nVal->int_val;"
  , "    if (idx < 0 || idx >= g_argc) {"
  , "        fprintf(stderr, \"stele: argv index %d out of bounds (argc=%d)\\n\", idx, g_argc);"
  , "        exit(1);"
  , "    }"
  , "    return make_str(g_argv[idx]);"
  , "}"
  , ""
  , "/* ── string built-in rites ─────────────────────────────────── */"
  , ""
  , "static Value* fn_strlen(Value* arg) {"
  , "    Value* sVal = record_field(arg, \"s\");"
  , "    return make_int((int64_t)strlen(sVal->str_val));"
  , "}"
  , ""
  , "static Value* fn_char_at(Value* arg) {"
  , "    Value* sVal = record_field(arg, \"s\");"
  , "    Value* nVal = record_field(arg, \"n\");"
  , "    int64_t idx = nVal->int_val;"
  , "    int64_t len = (int64_t)strlen(sVal->str_val);"
  , "    if (idx < 0 || idx >= len) return make_int(-1);"
  , "    return make_int((int64_t)(unsigned char)sVal->str_val[idx]);"
  , "}"
  , ""
  , "static Value* fn_substr(Value* arg) {"
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
  , "static Value* fn_concat(Value* arg) {"
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
  , "static Value* fn_int_to_str(Value* arg) {"
  , "    Value* nVal = record_field(arg, \"n\");"
  , "    char buf[32];"
  , "    snprintf(buf, sizeof(buf), \"%lld\", (long long)nVal->int_val);"
  , "    return make_str(buf);"
  , "}"
  , ""
  , "static Value* fn_char_of_int(Value* arg) {"
  , "    Value* nVal = record_field(arg, \"n\");"
  , "    char buf[2] = { (char)nVal->int_val, '\\0' };"
  , "    return make_str(buf);"
  , "}"
  , ""
  , "static Value* fn_strcmp(Value* arg) {"
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
-- Built-in rite names
-- ---------------------------------------------------------------------------

builtinRiteNames :: [String]
builtinRiteNames = ["unearth", "inscribe", "argc", "argv",
                    "strlen", "char_at", "substr", "concat",
                    "int_to_str", "char_of_int", "strcmp"]

-- ---------------------------------------------------------------------------
-- Code generation from IR
-- ---------------------------------------------------------------------------

-- | Emit a complete, self-contained C source file from an IR program.
emitCFromIR :: IRProgram -> String
emitCFromIR (IRProgram decls) =
  cRuntime
  ++ "\n/* ── forward declarations ──────────────────────────────────── */\n\n"
  ++ concatMap emitForwardDecl decls
  ++ "\n/* ── fn definitions ────────────────────────────────────────── */\n\n"
  ++ concatMap emitIRDecl [d | d@(IRFunc _ _) <- decls]
  ++ "\n/* ── entry point ──────────────────────────────────────────── */\n\n"
  ++ emitMainDecl decls

-- | Forward declarations for user-defined rites.
emitForwardDecl :: IRDecl -> String
emitForwardDecl (IRFunc name _)
  | name `elem` builtinRiteNames = ""
  | otherwise = "static Value* fn_" ++ name ++ "(Value* arg);\n"
emitForwardDecl (IRMain _) = ""

-- | Emit a rite or main function.
emitIRDecl :: IRDecl -> String
emitIRDecl (IRFunc name body) =
  "static Value* fn_" ++ name ++ "(Value* arg) {\n" ++
  emitVarDecls body ++
  emitFuncBlocks body ++
  "}\n\n"
emitIRDecl (IRMain _) = ""

-- | Emit the main() wrapper.
emitMainDecl :: [IRDecl] -> String
emitMainDecl decls =
  case [body | IRMain body <- decls] of
    [] -> "int main(int argc, char** argv) {\n    g_argc = argc;\n    g_argv = argv;\n    return 0;\n}\n"
    (body:_) ->
      "int main(int argc, char** argv) {\n" ++
      "g_argc = argc;\ng_argv = argv;\n" ++
      emitVarDecls body ++
      emitFuncBlocksMain body ++
      "return 0;\n}\n"

-- | Pre-declare all variables used in a function body.
-- This avoids redefinition errors when goto jumps across declarations.
emitVarDecls :: IRFuncBody -> String
emitVarDecls (IRFuncBody _ blocks) =
  let (ptrVars, intVars) = collectVarDecls blocks
  in concatMap (\v -> "Value* " ++ v ++ ";\n") (Set.toList ptrVars) ++
     concatMap (\v -> "int " ++ v ++ ";\n") (Set.toList intVars)

-- | Collect all variable names that need declaration, split by type.
collectVarDecls :: [Block] -> (Set.Set String, Set.Set String)
collectVarDecls blocks = foldl addBlock (Set.empty, Set.empty) blocks
  where
    addBlock (ptrs, ints) (Block _ instrs _) = foldl addInstr (ptrs, ints) instrs
    addInstr (ptrs, ints) instr = case instr of
      IConst v _       -> (Set.insert v ptrs, ints)
      IBinOp v _ _ _   -> (Set.insert v ptrs, ints)
      IUnOp v _ _      -> (Set.insert v ptrs, ints)
      IRecord v _      -> (Set.insert v ptrs, ints)
      IFieldGet v _ _  -> (Set.insert v ptrs, ints)
      ICall v _ _      -> (Set.insert v ptrs, ints)
      ITagCheck v _ _  -> (ptrs, Set.insert v ints)
      INullCheck v _   -> (ptrs, Set.insert v ints)
      IIntEq v _ _     -> (ptrs, Set.insert v ints)
      IStrEq v _ _     -> (ptrs, Set.insert v ints)
      IReadLn v        -> (Set.insert v ptrs, ints)
      IReadInt v       -> (Set.insert v ptrs, ints)
      ICopy v _        -> (Set.insert v ptrs, ints)
      _                -> (ptrs, ints)

-- | Emit basic blocks for a function body.
emitFuncBlocks :: IRFuncBody -> String
emitFuncBlocks (IRFuncBody _ blocks) = concatMap emitBlock blocks

-- | Emit basic blocks for main (TReturn becomes goto end instead of return).
emitFuncBlocksMain :: IRFuncBody -> String
emitFuncBlocksMain (IRFuncBody _ blocks) = concatMap emitBlockMain blocks

-- | Emit a basic block.
emitBlock :: Block -> String
emitBlock (Block bid instrs term) =
  bid ++ ":;\n" ++
  concatMap emitInstr instrs ++
  emitTerm term

-- | Emit a basic block for main (special handling of TReturn).
emitBlockMain :: Block -> String
emitBlockMain (Block bid instrs term) =
  bid ++ ":;\n" ++
  concatMap emitInstr instrs ++
  emitTermMain term

-- | Emit a single IR instruction as C (assignment only, no declaration).
emitInstr :: Instr -> String
emitInstr (IConst v (OInt n)) =
  v ++ " = make_int(" ++ show n ++ ");\n"
emitInstr (IConst v (OStr s)) =
  v ++ " = make_str(" ++ cString s ++ ");\n"
emitInstr (IConst v OVoid) =
  v ++ " = make_void();\n"
emitInstr (IBinOp v op l r) =
  v ++ " = " ++ cBinOp op l r ++ ";\n"
emitInstr (IUnOp v Neg src) =
  v ++ " = make_int(-" ++ src ++ "->int_val);\n"
emitInstr (IUnOp v Not src) =
  v ++ " = make_int(!" ++ src ++ "->int_val);\n"
emitInstr (IRecord v fields) =
  v ++ " = make_record(" ++ show (length fields) ++
  concatMap (\(name, fv) -> ", " ++ cString name ++ ", " ++ fv) fields ++
  ");\n"
emitInstr (IFieldGet v rec fld) =
  v ++ " = record_field(" ++ rec ++ ", " ++ cString fld ++ ");\n"
emitInstr (ICall v fnName arg) =
  v ++ " = fn_" ++ fnName ++ "(" ++ arg ++ ");\n"
emitInstr (IRetain v) =
  "rc_retain(" ++ v ++ ");\n"
emitInstr (IRelease v) =
  "rc_release(" ++ v ++ ");\n"
emitInstr (ITagCheck v op tag) =
  v ++ " = (" ++ op ++ "->tag == " ++ cTag tag ++ ");\n"
emitInstr (INullCheck v op) =
  v ++ " = (" ++ op ++ " != NULL);\n"
emitInstr (IIntEq v op n) =
  v ++ " = (" ++ op ++ "->int_val == " ++ show n ++ ");\n"
emitInstr (IStrEq v op s) =
  v ++ " = (strcmp(" ++ op ++ "->str_val, " ++ cString s ++ ") == 0);\n"
emitInstr (IPrint v) =
  "stele_print(" ++ v ++ ");\n"
emitInstr (IWrite v) =
  "stele_write(" ++ v ++ ");\n"
emitInstr (IReadLn v) =
  v ++ " = runtime_readln();\n"
emitInstr (IReadInt v) =
  v ++ " = runtime_readint();\n"
emitInstr (ICopy v src) =
  v ++ " = " ++ src ++ ";\n"

-- | Emit a block terminator.
emitTerm :: Terminator -> String
emitTerm (TReturn v) = "return " ++ v ++ ";\n"
emitTerm (TBranch c t f) =
  "if (" ++ c ++ ") goto " ++ t ++ "; else goto " ++ f ++ ";\n"
emitTerm (TJump lbl) = "goto " ++ lbl ++ ";\n"
emitTerm (TMatchFail msg) =
  "fprintf(stderr, \"Pattern match failure in " ++ msg ++ "\\n\"); exit(1);\n"

-- | Emit a block terminator for main (TReturn releases and falls through).
emitTermMain :: Terminator -> String
emitTermMain (TReturn v) = "rc_release(" ++ v ++ ");\n"
emitTermMain other = emitTerm other

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

cBinOp :: BinOp -> String -> String -> String
cBinOp op a b = case op of
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

cTag :: Tag -> String
cTag TagInt    = "TAG_INT"
cTag TagStr    = "TAG_STR"
cTag TagRecord = "TAG_RECORD"
cTag TagVoid   = "TAG_VOID"

-- | Emit a C string literal.
cString :: String -> String
cString s = "\"" ++ concatMap escChar s ++ "\""
  where
    escChar '"'  = "\\\""
    escChar '\\' = "\\\\"
    escChar '\n' = "\\n"
    escChar c    = [c]
