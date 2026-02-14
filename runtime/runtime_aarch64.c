#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/wait.h>

/* ── stele runtime for native (aarch64) backend ──────────────── */
/* All functions have external linkage so they can be called from   */
/* generated assembly.                                              */

typedef enum { TAG_INT, TAG_STR, TAG_RECORD, TAG_VOID } Tag;

typedef struct Field {
    const char* name;
    struct Value* value;
} Field;

typedef struct Value {
    Tag tag;
    int refcount;
    union {
        int64_t int_val;
        char* str_val;
        struct { int num_fields; Field* fields; } record;
    };
} Value;

void rc_release(Value* v);

static void stele_runtime_null(const char* where) {
    fprintf(stderr, "stele: null value in %s\n", where);
    exit(1);
}

void rc_retain(Value* v) {
    if (!v) return;
    v->refcount++;
}

Value* make_int(int64_t n) {
    Value* v = (Value*)malloc(sizeof(Value));
    v->tag = TAG_INT;
    v->refcount = 1;
    v->int_val = n;
    return v;
}

Value* make_str(const char* s) {
    Value* v = (Value*)malloc(sizeof(Value));
    v->tag = TAG_STR;
    v->refcount = 1;
    v->str_val = strdup(s);
    return v;
}

Value* make_void(void) {
    Value* v = (Value*)malloc(sizeof(Value));
    v->tag = TAG_VOID;
    v->refcount = 1;
    return v;
}

Value* make_record(int n, ...) {
    Value* v = (Value*)malloc(sizeof(Value));
    v->tag = TAG_RECORD;
    v->refcount = 1;
    v->record.num_fields = n;
    v->record.fields = (Field*)malloc(sizeof(Field) * n);
    __builtin_va_list ap;
    __builtin_va_start(ap, n);
    for (int i = 0; i < n; i++) {
        v->record.fields[i].name = __builtin_va_arg(ap, const char*);
        v->record.fields[i].value = __builtin_va_arg(ap, Value*);
    }
    __builtin_va_end(ap);
    return v;
}

Value* make_record_with_fields(int n, const char** names, Value** values) {
    Value* v = (Value*)malloc(sizeof(Value));
    v->tag = TAG_RECORD;
    v->refcount = 1;
    v->record.num_fields = n;
    v->record.fields = (Field*)malloc(sizeof(Field) * n);
    for (int i = 0; i < n; i++) {
        v->record.fields[i].name = names[i];
        v->record.fields[i].value = values[i];
    }
    return v;
}

void rc_release(Value* v) {
    if (!v) return;
    v->refcount--;
    if (v->refcount > 0) return;
    switch (v->tag) {
        case TAG_STR: free(v->str_val); break;
        case TAG_RECORD:
            for (int i = 0; i < v->record.num_fields; i++)
                rc_release(v->record.fields[i].value);
            free(v->record.fields);
            break;
        default: break;
    }
    free(v);
}

Value* record_field(Value* rec, const char* name) {
    if (!rec || rec->tag != TAG_RECORD) return NULL;
    for (int i = 0; i < rec->record.num_fields; i++) {
        if (strcmp(rec->record.fields[i].name, name) == 0)
            return rec->record.fields[i].value;
    }
    return NULL;
}

void stele_write(Value* v);

int stele_value_eq(Value* a, Value* b) {
    if (a == b) return 1;
    if (!a || !b) return 0;
    if (a->tag != b->tag) return 0;
    switch (a->tag) {
        case TAG_INT: return a->int_val == b->int_val;
        case TAG_STR: return strcmp(a->str_val, b->str_val) == 0;
        case TAG_VOID: return 1;
        case TAG_RECORD:
            if (a->record.num_fields != b->record.num_fields) return 0;
            for (int i = 0; i < a->record.num_fields; i++) {
                Value* bv = record_field(b, a->record.fields[i].name);
                if (!bv) return 0;
                if (!stele_value_eq(a->record.fields[i].value, bv)) return 0;
            }
            return 1;
    }
    return 0;
}

int stele_value_neq(Value* a, Value* b) {
    return !stele_value_eq(a, b);
}

void stele_print(Value* v) {
    if (!v) stele_runtime_null("print");
    switch (v->tag) {
        case TAG_INT:    printf("%lld\n", (long long)v->int_val); break;
        case TAG_STR:    printf("%s\n", v->str_val); break;
        case TAG_VOID:   printf("void\n"); break;
        case TAG_RECORD: {
            printf("{| ");
            for (int i = 0; i < v->record.num_fields; i++) {
                if (i > 0) printf(", ");
                printf("%s: ", v->record.fields[i].name);
                stele_write(v->record.fields[i].value);
            }
            printf(" |}\n");
            break;
        }
    }
}

void stele_write(Value* v) {
    if (!v) stele_runtime_null("write");
    switch (v->tag) {
        case TAG_INT:    printf("%lld", (long long)v->int_val); break;
        case TAG_STR:    printf("%s", v->str_val); break;
        case TAG_VOID:   printf("void"); break;
        case TAG_RECORD: {
            printf("{| ");
            for (int i = 0; i < v->record.num_fields; i++) {
                if (i > 0) printf(", ");
                printf("%s: ", v->record.fields[i].name);
                stele_write(v->record.fields[i].value);
            }
            printf(" |}");
            break;
        }
    }
}

Value* runtime_readln(void) {
    char buf[4096];
    if (fgets(buf, sizeof(buf), stdin) == NULL) {
        return make_str("");
    }
    size_t len = strlen(buf);
    if (len > 0 && buf[len-1] == '\n') buf[len-1] = '\0';
    return make_str(buf);
}

Value* runtime_readint(void) {
    long long n = 0;
    if (scanf("%lld", &n) != 1) {
        fprintf(stderr, "stele: readint failed to read integer\n");
        exit(1);
    }
    int c = getchar(); (void)c;
    return make_int((int64_t)n);
}

void stele_match_fail(const char* msg) {
    fprintf(stderr, "Pattern match failure in %s\n", msg);
    exit(1);
}

/* ── file IO and argv built-in fns ───────────────────────────── */

int g_argc = 0;
char** g_argv = NULL;

Value* fn_unearth(Value* arg) {
    Value* pathVal = record_field(arg, "path");
    if (!pathVal || pathVal->tag != TAG_STR) {
        fprintf(stderr, "stele: unearth requires path: String\n");
        exit(1);
    }
    FILE* f = fopen(pathVal->str_val, "r");
    if (!f) {
        fprintf(stderr, "stele: unearth cannot open '%s'\n", pathVal->str_val);
        exit(1);
    }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    char* buf = (char*)malloc(sz + 1);
    fread(buf, 1, sz, f);
    buf[sz] = '\0';
    fclose(f);
    Value* result = make_str(buf);
    free(buf);
    return result;
}

Value* fn_inscribe(Value* arg) {
    Value* pathVal = record_field(arg, "path");
    Value* contentVal = record_field(arg, "content");
    if (!pathVal || pathVal->tag != TAG_STR ||
        !contentVal || contentVal->tag != TAG_STR) {
        fprintf(stderr, "stele: inscribe requires path: String, content: String\n");
        exit(1);
    }
    FILE* f = fopen(pathVal->str_val, "w");
    if (!f) {
        fprintf(stderr, "stele: inscribe cannot open '%s'\n", pathVal->str_val);
        exit(1);
    }
    fputs(contentVal->str_val, f);
    fclose(f);
    return make_void();
}

Value* fn_argc(Value* arg) {
    (void)arg;
    return make_int((int64_t)g_argc);
}

Value* fn_argv(Value* arg) {
    Value* nVal = record_field(arg, "n");
    if (!nVal || nVal->tag != TAG_INT) {
        fprintf(stderr, "stele: argv requires n: Int\n");
        exit(1);
    }
    int idx = (int)nVal->int_val;
    if (idx < 0 || idx >= g_argc) {
        fprintf(stderr, "stele: argv index %d out of bounds (argc=%d)\n", idx, g_argc);
        exit(1);
    }
    return make_str(g_argv[idx]);
}

Value* fn_sh(Value* arg) {
    Value* cmdVal = record_field(arg, "command");
    if (!cmdVal || cmdVal->tag != TAG_STR) {
        fprintf(stderr, "stele: sh requires command: String\n");
        exit(1);
    }
    int rc = system(cmdVal->str_val);
    return make_int((int64_t)rc);
}

Value* fn_terminate(Value* arg) {
    Value* codeVal = record_field(arg, "code");
    if (!codeVal || codeVal->tag != TAG_INT) {
        fprintf(stderr, "stele: terminate requires code: Int\n");
        exit(1);
    }
    exit((int)codeVal->int_val);
}

Value* fn_spawn(Value* arg) {
    Value* cmdVal = record_field(arg, "command");
    if (!cmdVal || cmdVal->tag != TAG_STR) {
        fprintf(stderr, "stele: spawn requires command: String\n");
        exit(1);
    }
    pid_t pid = fork();
    if (pid < 0) {
        fprintf(stderr, "stele: spawn failed\n");
        exit(1);
    }
    if (pid == 0) {
        execl("/bin/sh", "sh", "-c", cmdVal->str_val, (char*)NULL);
        _exit(127);
    }
    return make_int((int64_t)pid);
}

Value* fn_await(Value* arg) {
    Value* pidVal = record_field(arg, "pid");
    if (!pidVal || pidVal->tag != TAG_INT) {
        fprintf(stderr, "stele: await requires pid: Int\n");
        exit(1);
    }
    int status = 0;
    pid_t r = waitpid((pid_t)pidVal->int_val, &status, 0);
    if (r < 0) {
        fprintf(stderr, "stele: await failed for pid %lld\n", (long long)pidVal->int_val);
        exit(1);
    }
    if (WIFEXITED(status)) {
        return make_int((int64_t)WEXITSTATUS(status));
    }
    if (WIFSIGNALED(status)) {
        return make_int((int64_t)(128 + WTERMSIG(status)));
    }
    return make_int((int64_t)status);
}

Value* fn_sleep_ms(Value* arg) {
    Value* msVal = record_field(arg, "ms");
    if (!msVal || msVal->tag != TAG_INT) {
        fprintf(stderr, "stele: sleep_ms requires ms: Int\n");
        exit(1);
    }
    int64_t ms = msVal->int_val;
    if (ms < 0) ms = 0;
    usleep((useconds_t)(ms * 1000));
    return make_void();
}

/* ── string built-in fns ──────────────────────────────────── */

Value* fn_strlen(Value* arg) {
    Value* sVal = record_field(arg, "s");
    return make_int((int64_t)strlen(sVal->str_val));
}

Value* fn_char_at(Value* arg) {
    Value* sVal = record_field(arg, "s");
    Value* nVal = record_field(arg, "n");
    int64_t idx = nVal->int_val;
    int64_t len = (int64_t)strlen(sVal->str_val);
    if (idx < 0 || idx >= len) return make_int(-1);
    return make_int((int64_t)(unsigned char)sVal->str_val[idx]);
}

Value* fn_substr(Value* arg) {
    Value* sVal = record_field(arg, "s");
    Value* startVal = record_field(arg, "start");
    Value* lenVal = record_field(arg, "len");
    int64_t slen = (int64_t)strlen(sVal->str_val);
    int64_t start = startVal->int_val;
    int64_t rlen = lenVal->int_val;
    if (start < 0) start = 0;
    if (start >= slen || rlen <= 0) return make_str("");
    if (start + rlen > slen) rlen = slen - start;
    char* buf = (char*)malloc(rlen + 1);
    memcpy(buf, sVal->str_val + start, rlen);
    buf[rlen] = '\0';
    Value* result = make_str(buf);
    free(buf);
    return result;
}

Value* fn_concat(Value* arg) {
    Value* aVal = record_field(arg, "a");
    Value* bVal = record_field(arg, "b");
    size_t la = strlen(aVal->str_val);
    size_t lb = strlen(bVal->str_val);
    char* buf = (char*)malloc(la + lb + 1);
    memcpy(buf, aVal->str_val, la);
    memcpy(buf + la, bVal->str_val, lb);
    buf[la + lb] = '\0';
    Value* result = make_str(buf);
    free(buf);
    return result;
}

Value* fn_int_to_str(Value* arg) {
    Value* nVal = record_field(arg, "n");
    char buf[32];
    snprintf(buf, sizeof(buf), "%lld", (long long)nVal->int_val);
    return make_str(buf);
}

Value* fn_char_of_int(Value* arg) {
    Value* nVal = record_field(arg, "n");
    char buf[2] = { (char)nVal->int_val, '\0' };
    return make_str(buf);
}

Value* fn_strcmp(Value* arg) {
    Value* aVal = record_field(arg, "a");
    Value* bVal = record_field(arg, "b");
    int r = strcmp(aVal->str_val, bVal->str_val);
    return make_int((int64_t)(r < 0 ? -1 : (r > 0 ? 1 : 0)));
}

/* ── end runtime ────────────────────────────────────────────── */
