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
  , emitCFromIRTest
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
  , "#include <unistd.h>"
  , "#include <sys/wait.h>"
  , ""
  , "/* ── stele runtime (reference counted) ────────────────────── */"
  , ""
  , "typedef enum { TAG_INT, TAG_STR, TAG_RECORD, TAG_VOID, TAG_CLOSURE } Tag;"
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
  , "        struct { struct Value* (*fn_ptr)(struct Value*); struct Value* env; } closure;"
  , "    };"
  , "} Value;"
  , ""
  , "static void rc_release(Value* v);"
  , ""
  , "static void stele_runtime_null(const char* where) {"
  , "    fprintf(stderr, \"stele: null value in %s\\n\", where);"
  , "    exit(1);"
  , "}"
  , ""
  , "static void* stele_malloc(size_t size) {"
  , "    void* p = malloc(size);"
  , "    if (!p) { fprintf(stderr, \"stele: out of memory (%zu bytes)\\n\", size); abort(); }"
  , "    return p;"
  , "}"
  , ""
  , "static char* stele_strdup(const char* s) {"
  , "    char* p = strdup(s);"
  , "    if (!p) { fprintf(stderr, \"stele: out of memory (strdup)\\n\"); abort(); }"
  , "    return p;"
  , "}"
  , ""
  , "static void rc_retain(Value* v) {"
  , "    if (!v) return;"
  , "    v->refcount++;"
  , "}"
  , ""
  , "static Value* make_int(int64_t n) {"
  , "    Value* v = (Value*)stele_malloc(sizeof(Value));"
  , "    v->tag = TAG_INT;"
  , "    v->refcount = 1;"
  , "    v->int_val = n;"
  , "    return v;"
  , "}"
  , ""
  , "static Value* make_str(const char* s) {"
  , "    Value* v = (Value*)stele_malloc(sizeof(Value));"
  , "    v->tag = TAG_STR;"
  , "    v->refcount = 1;"
  , "    v->str_val = stele_strdup(s);"
  , "    return v;"
  , "}"
  , ""
  , "static Value* make_void(void) {"
  , "    Value* v = (Value*)stele_malloc(sizeof(Value));"
  , "    v->tag = TAG_VOID;"
  , "    v->refcount = 1;"
  , "    return v;"
  , "}"
  , ""
  , "static Value* make_record(int n, ...) {"
  , "    Value* v = (Value*)stele_malloc(sizeof(Value));"
  , "    v->tag = TAG_RECORD;"
  , "    v->refcount = 1;"
  , "    v->record.num_fields = n;"
  , "    v->record.fields = (Field*)stele_malloc(sizeof(Field) * n);"
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
  , "static Value* make_closure(Value* (*fn_ptr)(Value*), Value* env) {"
  , "    Value* v = (Value*)stele_malloc(sizeof(Value));"
  , "    v->tag = TAG_CLOSURE;"
  , "    v->refcount = 1;"
  , "    v->closure.fn_ptr = fn_ptr;"
  , "    v->closure.env = env;"
  , "    if (env) rc_retain(env);"
  , "    return v;"
  , "}"
  , ""
  , "static Value* stele_call_closure(Value* clos, Value* arg) {"
  , "    if (!clos || clos->tag != TAG_CLOSURE) {"
  , "        fprintf(stderr, \"stele: attempt to call non-closure value\\n\");"
  , "        exit(1);"
  , "    }"
  , "    Value* env = clos->closure.env;"
  , "    if (env && env->tag == TAG_RECORD && arg && arg->tag == TAG_RECORD) {"
  , "        int total = arg->record.num_fields + env->record.num_fields;"
  , "        Value* merged = (Value*)stele_malloc(sizeof(Value));"
  , "        merged->tag = TAG_RECORD;"
  , "        merged->refcount = 1;"
  , "        merged->record.num_fields = total;"
  , "        merged->record.fields = (Field*)stele_malloc(sizeof(Field) * total);"
  , "        for (int i = 0; i < arg->record.num_fields; i++) {"
  , "            merged->record.fields[i] = arg->record.fields[i];"
  , "            rc_retain(arg->record.fields[i].value);"
  , "        }"
  , "        for (int i = 0; i < env->record.num_fields; i++) {"
  , "            merged->record.fields[arg->record.num_fields + i] = env->record.fields[i];"
  , "            rc_retain(env->record.fields[i].value);"
  , "        }"
  , "        Value* result = clos->closure.fn_ptr(merged);"
  , "        rc_release(merged);"
  , "        return result;"
  , "    }"
  , "    return clos->closure.fn_ptr(arg);"
  , "}"
  , ""
  , "static void rc_release(Value* v) {"
  , "    Value* stack[64];"
  , "    int sp = 0;"
  , "    if (!v) return;"
  , "    stack[sp++] = v;"
  , "    while (sp > 0) {"
  , "        Value* cur = stack[--sp];"
  , "        if (!cur) continue;"
  , "        cur->refcount--;"
  , "        if (cur->refcount > 0) continue;"
  , "        switch (cur->tag) {"
  , "            case TAG_STR: free(cur->str_val); break;"
  , "            case TAG_RECORD:"
  , "                for (int i = 0; i < cur->record.num_fields; i++) {"
  , "                    Value* child = cur->record.fields[i].value;"
  , "                    if (!child) continue;"
  , "                    if (sp < 64) {"
  , "                        stack[sp++] = child;"
  , "                    } else {"
  , "                        rc_release(child);"
  , "                    }"
  , "                }"
  , "                free(cur->record.fields);"
  , "                break;"
  , "            case TAG_CLOSURE:"
  , "                if (cur->closure.env) {"
  , "                    if (sp < 64) { stack[sp++] = cur->closure.env; }"
  , "                    else { rc_release(cur->closure.env); }"
  , "                }"
  , "                break;"
  , "            default: break;"
  , "        }"
  , "        free(cur);"
  , "    }"
  , "}"
  , ""
  , "static Value* record_field(Value* rec, const char* name) {"
  , "    if (!rec || rec->tag != TAG_RECORD) return NULL;"
  , "    for (int i = 0; i < rec->record.num_fields; i++) {"
  , "        if (strcmp(rec->record.fields[i].name, name) == 0)"
  , "            return rec->record.fields[i].value;"
  , "    }"
  , "    return NULL;"
  , "}"
  , ""
  , "static void stele_write(Value* v);"
  , ""
  , "static int stele_value_eq(Value* a, Value* b) {"
  , "    if (a == b) return 1;"
  , "    if (!a || !b) return 0;"
  , "    if (a->tag != b->tag) return 0;"
  , "    switch (a->tag) {"
  , "        case TAG_INT: return a->int_val == b->int_val;"
  , "        case TAG_STR: return strcmp(a->str_val, b->str_val) == 0;"
  , "        case TAG_VOID: return 1;"
  , "        case TAG_CLOSURE: return a == b;"
  , "        case TAG_RECORD:"
  , "            if (a->record.num_fields != b->record.num_fields) return 0;"
  , "            for (int i = 0; i < a->record.num_fields; i++) {"
  , "                Value* bv = record_field(b, a->record.fields[i].name);"
  , "                if (!bv) return 0;"
  , "                if (!stele_value_eq(a->record.fields[i].value, bv)) return 0;"
  , "            }"
  , "            return 1;"
  , "    }"
  , "    return 0;"
  , "}"
  , ""
  , "static int stele_value_neq(Value* a, Value* b) {"
  , "    return !stele_value_eq(a, b);"
  , "}"
  , ""
  , "static void stele_print(Value* v) {"
  , "    if (!v) stele_runtime_null(\"print\");"
  , "    switch (v->tag) {"
  , "        case TAG_INT:    printf(\"%lld\\n\", (long long)v->int_val); break;"
  , "        case TAG_STR:    printf(\"%s\\n\", v->str_val); break;"
  , "        case TAG_VOID:    printf(\"void\\n\"); break;"
  , "        case TAG_CLOSURE: printf(\"<closure>\\n\"); break;"
  , "        case TAG_RECORD: {"
  , "            printf(\"{| \");"
  , "            for (int i = 0; i < v->record.num_fields; i++) {"
  , "                if (i > 0) printf(\", \");"
  , "                printf(\"%s: \", v->record.fields[i].name);"
  , "                stele_write(v->record.fields[i].value);"
  , "            }"
  , "            printf(\" |}\\n\");"
  , "            break;"
  , "        }"
  , "    }"
  , "}"
  , ""
  , "static void stele_write(Value* v) {"
  , "    if (!v) stele_runtime_null(\"write\");"
  , "    switch (v->tag) {"
  , "        case TAG_INT:     printf(\"%lld\", (long long)v->int_val); break;"
  , "        case TAG_STR:     printf(\"%s\", v->str_val); break;"
  , "        case TAG_VOID:    printf(\"void\"); break;"
  , "        case TAG_CLOSURE: printf(\"<closure>\"); break;"
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
  , "    char* line = NULL;"
  , "    size_t cap = 0;"
  , "    ssize_t n = getline(&line, &cap, stdin);"
  , "    if (n < 0) {"
  , "        free(line);"
  , "        return make_str(\"\");"
  , "    }"
  , "    if (n > 0 && line[n-1] == '\\n') line[n-1] = '\\0';"
  , "    Value* result = make_str(line);"
  , "    free(line);"
  , "    return result;"
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
  , "static Value* fn_read(Value* arg) {"
  , "    Value* pathVal = record_field(arg, \"path\");"
  , "    if (!pathVal || pathVal->tag != TAG_STR) {"
  , "        fprintf(stderr, \"stele: read requires path: String\\n\");"
  , "        exit(1);"
  , "    }"
  , "    FILE* f = fopen(pathVal->str_val, \"r\");"
  , "    if (!f) {"
  , "        fprintf(stderr, \"stele: read cannot open '%s'\\n\", pathVal->str_val);"
  , "        exit(1);"
  , "    }"
  , "    fseek(f, 0, SEEK_END);"
  , "    long sz = ftell(f);"
  , "    fseek(f, 0, SEEK_SET);"
  , "    char* buf = (char*)stele_malloc(sz + 1);"
  , "    fread(buf, 1, sz, f);"
  , "    buf[sz] = '\\0';"
  , "    fclose(f);"
  , "    Value* result = make_str(buf);"
  , "    free(buf);"
  , "    return result;"
  , "}"
  , ""
  , "static Value* fn_write(Value* arg) {"
  , "    Value* pathVal = record_field(arg, \"path\");"
  , "    Value* contentVal = record_field(arg, \"content\");"
  , "    if (pathVal && pathVal->tag == TAG_STR &&"
  , "        contentVal && contentVal->tag == TAG_STR) {"
  , "        FILE* f = fopen(pathVal->str_val, \"w\");"
  , "        if (!f) {"
  , "            fprintf(stderr, \"stele: write cannot open '%s'\\n\", pathVal->str_val);"
  , "            exit(1);"
  , "        }"
  , "        fputs(contentVal->str_val, f);"
  , "        fclose(f);"
  , "        return make_void();"
  , "    }"
  , "    stele_write(arg);"
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
  , "static Value* fn_sh(Value* arg) {"
  , "    Value* cmdVal = record_field(arg, \"command\");"
  , "    if (!cmdVal || cmdVal->tag != TAG_STR) {"
  , "        fprintf(stderr, \"stele: sh requires command: String\\n\");"
  , "        exit(1);"
  , "    }"
  , "    int rc = system(cmdVal->str_val);"
  , "    return make_int((int64_t)rc);"
  , "}"
  , ""
  , "static Value* fn_terminate(Value* arg) {"
  , "    Value* codeVal = record_field(arg, \"code\");"
  , "    if (!codeVal || codeVal->tag != TAG_INT) {"
  , "        fprintf(stderr, \"stele: terminate requires code: Int\\n\");"
  , "        exit(1);"
  , "    }"
  , "    exit((int)codeVal->int_val);"
  , "}"
  , ""
  , "static Value* fn_spawn(Value* arg) {"
  , "    Value* cmdVal = record_field(arg, \"command\");"
  , "    if (!cmdVal || cmdVal->tag != TAG_STR) {"
  , "        fprintf(stderr, \"stele: spawn requires command: String\\n\");"
  , "        exit(1);"
  , "    }"
  , "    pid_t pid = fork();"
  , "    if (pid < 0) {"
  , "        fprintf(stderr, \"stele: spawn failed\\n\");"
  , "        exit(1);"
  , "    }"
  , "    if (pid == 0) {"
  , "        execl(\"/bin/sh\", \"sh\", \"-c\", cmdVal->str_val, (char*)NULL);"
  , "        _exit(127);"
  , "    }"
  , "    return make_int((int64_t)pid);"
  , "}"
  , ""
  , "static Value* fn_await(Value* arg) {"
  , "    Value* pidVal = record_field(arg, \"pid\");"
  , "    if (!pidVal || pidVal->tag != TAG_INT) {"
  , "        fprintf(stderr, \"stele: await requires pid: Int\\n\");"
  , "        exit(1);"
  , "    }"
  , "    int status = 0;"
  , "    pid_t r = waitpid((pid_t)pidVal->int_val, &status, 0);"
  , "    if (r < 0) {"
  , "        fprintf(stderr, \"stele: await failed for pid %lld\\n\", (long long)pidVal->int_val);"
  , "        exit(1);"
  , "    }"
  , "    if (WIFEXITED(status)) {"
  , "        return make_int((int64_t)WEXITSTATUS(status));"
  , "    }"
  , "    if (WIFSIGNALED(status)) {"
  , "        return make_int((int64_t)(128 + WTERMSIG(status)));"
  , "    }"
  , "    return make_int((int64_t)status);"
  , "}"
  , ""
  , "static Value* fn_sleep_ms(Value* arg) {"
  , "    Value* msVal = record_field(arg, \"ms\");"
  , "    if (!msVal || msVal->tag != TAG_INT) {"
  , "        fprintf(stderr, \"stele: sleep_ms requires ms: Int\\n\");"
  , "        exit(1);"
  , "    }"
  , "    int64_t ms = msVal->int_val;"
  , "    if (ms < 0) ms = 0;"
  , "    usleep((useconds_t)(ms * 1000));"
  , "    return make_void();"
  , "}"
  , ""
  , "/* ── string built-in rites ─────────────────────────────────── */"
  , ""
  , "static Value* fn_strlen(Value* arg) {"
  , "    Value* sVal = record_field(arg, \"s\");"
  , "    if (!sVal || sVal->tag != TAG_STR) {"
  , "        fprintf(stderr, \"stele runtime bug: strlen requires s: String\\n\");"
  , "        exit(1);"
  , "    }"
  , "    return make_int((int64_t)strlen(sVal->str_val));"
  , "}"
  , ""
  , "static Value* fn_char_at(Value* arg) {"
  , "    Value* sVal = record_field(arg, \"s\");"
  , "    Value* nVal = record_field(arg, \"n\");"
  , "    if (!sVal || sVal->tag != TAG_STR) {"
  , "        fprintf(stderr, \"stele runtime bug: char_at requires s: String\\n\");"
  , "        exit(1);"
  , "    }"
  , "    if (!nVal || nVal->tag != TAG_INT) {"
  , "        fprintf(stderr, \"stele runtime bug: char_at requires n: Int\\n\");"
  , "        exit(1);"
  , "    }"
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
  , "    if (!sVal || sVal->tag != TAG_STR) {"
  , "        fprintf(stderr, \"stele runtime bug: substr requires s: String\\n\");"
  , "        exit(1);"
  , "    }"
  , "    if (!startVal || startVal->tag != TAG_INT) {"
  , "        fprintf(stderr, \"stele runtime bug: substr requires start: Int\\n\");"
  , "        exit(1);"
  , "    }"
  , "    if (!lenVal || lenVal->tag != TAG_INT) {"
  , "        fprintf(stderr, \"stele runtime bug: substr requires len: Int\\n\");"
  , "        exit(1);"
  , "    }"
  , "    int64_t slen = (int64_t)strlen(sVal->str_val);"
  , "    int64_t start = startVal->int_val;"
  , "    int64_t rlen = lenVal->int_val;"
  , "    if (start < 0) start = 0;"
  , "    if (start >= slen || rlen <= 0) return make_str(\"\");"
  , "    if (start + rlen > slen) rlen = slen - start;"
  , "    char* buf = (char*)stele_malloc(rlen + 1);"
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
  , "    if (!aVal || aVal->tag != TAG_STR) {"
  , "        fprintf(stderr, \"stele runtime bug: concat requires a: String\\n\");"
  , "        exit(1);"
  , "    }"
  , "    if (!bVal || bVal->tag != TAG_STR) {"
  , "        fprintf(stderr, \"stele runtime bug: concat requires b: String\\n\");"
  , "        exit(1);"
  , "    }"
  , "    size_t la = strlen(aVal->str_val);"
  , "    size_t lb = strlen(bVal->str_val);"
  , "    char* buf = (char*)stele_malloc(la + lb + 1);"
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
  , "    if (!nVal || nVal->tag != TAG_INT) {"
  , "        fprintf(stderr, \"stele runtime bug: int_to_str requires n: Int\\n\");"
  , "        exit(1);"
  , "    }"
  , "    char buf[32];"
  , "    snprintf(buf, sizeof(buf), \"%lld\", (long long)nVal->int_val);"
  , "    return make_str(buf);"
  , "}"
  , ""
  , "static Value* fn_char_of_int(Value* arg) {"
  , "    Value* nVal = record_field(arg, \"n\");"
  , "    if (!nVal || nVal->tag != TAG_INT) {"
  , "        fprintf(stderr, \"stele runtime bug: char_of_int requires n: Int\\n\");"
  , "        exit(1);"
  , "    }"
  , "    char buf[2] = { (char)nVal->int_val, '\\0' };"
  , "    return make_str(buf);"
  , "}"
  , ""
  , "static Value* fn_strcmp(Value* arg) {"
  , "    Value* aVal = record_field(arg, \"a\");"
  , "    Value* bVal = record_field(arg, \"b\");"
  , "    if (!aVal || aVal->tag != TAG_STR) {"
  , "        fprintf(stderr, \"stele runtime bug: strcmp requires a: String\\n\");"
  , "        exit(1);"
  , "    }"
  , "    if (!bVal || bVal->tag != TAG_STR) {"
  , "        fprintf(stderr, \"stele runtime bug: strcmp requires b: String\\n\");"
  , "        exit(1);"
  , "    }"
  , "    int r = strcmp(aVal->str_val, bVal->str_val);"
  , "    return make_int((int64_t)(r < 0 ? -1 : (r > 0 ? 1 : 0)));"
  , "}"
  , ""
  , "/* ── checked arithmetic ──────────────────────────────────────── */"
  , ""
  , "static Value* checked_add(Value* a, Value* b) {"
  , "    int64_t x = a->int_val, y = b->int_val, r;"
  , "    if (__builtin_add_overflow(x, y, &r)) {"
  , "        fprintf(stderr, \"stele runtime error: integer overflow in addition\\n\");"
  , "        abort();"
  , "    }"
  , "    return make_int(r);"
  , "}"
  , ""
  , "static Value* checked_sub(Value* a, Value* b) {"
  , "    int64_t x = a->int_val, y = b->int_val, r;"
  , "    if (__builtin_sub_overflow(x, y, &r)) {"
  , "        fprintf(stderr, \"stele runtime error: integer overflow in subtraction\\n\");"
  , "        abort();"
  , "    }"
  , "    return make_int(r);"
  , "}"
  , ""
  , "static Value* checked_mul(Value* a, Value* b) {"
  , "    int64_t x = a->int_val, y = b->int_val, r;"
  , "    if (__builtin_mul_overflow(x, y, &r)) {"
  , "        fprintf(stderr, \"stele runtime error: integer overflow in multiplication\\n\");"
  , "        abort();"
  , "    }"
  , "    return make_int(r);"
  , "}"
  , ""
  , "/* ── end runtime ────────────────────────────────────────────── */"
  , ""
  ]

-- ---------------------------------------------------------------------------
-- Built-in rite names
-- ---------------------------------------------------------------------------

builtinRiteNames :: [String]
builtinRiteNames = ["read", "write", "argc", "argv", "sh", "terminate",
                    "spawn", "await", "sleep_ms",
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
emitForwardDecl (IRTest _ _) = ""

-- | Emit a rite or main function.
emitIRDecl :: IRDecl -> String
emitIRDecl (IRFunc name body) =
  "static Value* fn_" ++ name ++ "(Value* arg) {\n" ++
  emitVarDecls body ++
  emitFuncBlocks body ++
  "}\n\n"
emitIRDecl (IRMain _) = ""
emitIRDecl (IRTest _ _) = ""

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
-- The function parameter is excluded since it's already declared.
emitVarDecls :: IRFuncBody -> String
emitVarDecls (IRFuncBody param blocks) =
  let (ptrVars, intVars) = collectVarDecls blocks
      ptrVars' = Set.delete param ptrVars
  in concatMap (\v -> "Value* " ++ v ++ ";\n") (Set.toList ptrVars') ++
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
      IClosure v _ _   -> (Set.insert v ptrs, ints)
      ICallClosure v _ _ -> (Set.insert v ptrs, ints)
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
emitInstr (IClosure v lambdaName envFields) =
  let retains = concatMap (\(_, fv) -> "rc_retain(" ++ fv ++ ");\n") envFields
      envCode = if null envFields
        then v ++ " = make_closure(fn_" ++ lambdaName ++ ", NULL);\n"
        else let envRec = "make_record(" ++ show (length envFields) ++
                   concatMap (\(name, fv) -> ", " ++ cString name ++ ", " ++ fv) envFields ++ ")"
             in v ++ " = make_closure(fn_" ++ lambdaName ++ ", " ++ envRec ++ ");\n"
  in retains ++ envCode
emitInstr (ICallClosure v clos arg) =
  v ++ " = stele_call_closure(" ++ clos ++ ", " ++ arg ++ ");\n"
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
  Add -> "checked_add(" ++ a ++ ", " ++ b ++ ")"
  Sub -> "checked_sub(" ++ a ++ ", " ++ b ++ ")"
  Mul -> "checked_mul(" ++ a ++ ", " ++ b ++ ")"
  Div -> "make_int(" ++ a ++ "->int_val / " ++ b ++ "->int_val)"
  Mod -> "make_int(" ++ a ++ "->int_val % " ++ b ++ "->int_val)"
  Eq  -> "make_int(stele_value_eq(" ++ a ++ ", " ++ b ++ "))"
  Neq -> "make_int(stele_value_neq(" ++ a ++ ", " ++ b ++ "))"
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

-- ---------------------------------------------------------------------------
-- Test mode
-- ---------------------------------------------------------------------------

-- | Emit a complete C source file in test mode — generates a test runner
-- main that executes each test block sequentially.
emitCFromIRTest :: IRProgram -> String
emitCFromIRTest (IRProgram decls) =
  cRuntime
  ++ "\n/* ── forward declarations ──────────────────────────────────── */\n\n"
  ++ concatMap emitForwardDecl decls
  ++ "\n/* ── fn definitions ────────────────────────────────────────── */\n\n"
  ++ concatMap emitIRDecl [d | d@(IRFunc _ _) <- decls]
  ++ "\n/* ── test runner ──────────────────────────────────────────── */\n\n"
  ++ emitTestMainDecl decls

-- | Emit a main() that runs all test blocks sequentially.
emitTestMainDecl :: [IRDecl] -> String
emitTestMainDecl decls =
  let tests = [(name, body) | IRTest name body <- decls]
      nTests = length tests
  in "int main(int argc, char** argv) {\n" ++
     "g_argc = argc;\ng_argv = argv;\n" ++
     "int _test_pass = 0;\n" ++
     "int _test_total = " ++ show nTests ++ ";\n" ++
     concatMap emitTestBlock tests ++
     "fprintf(stderr, \"\\n%d/%d tests passed\\n\", _test_pass, _test_total);\n" ++
     "return (_test_pass == _test_total) ? 0 : 1;\n" ++
     "}\n"

emitTestBlock :: (String, IRFuncBody) -> String
emitTestBlock (name, body) =
  "fprintf(stderr, \"test: " ++ concatMap escCharC name ++ " ... \");\n" ++
  "{\n" ++
  emitVarDecls body ++
  emitFuncBlocksMain body ++
  "}\n" ++
  "fprintf(stderr, \"ok\\n\");\n" ++
  "_test_pass++;\n"
  where
    escCharC '"'  = "\\\""
    escCharC '\\' = "\\\\"
    escCharC '\n' = "\\n"
    escCharC c    = [c]
