// compiler_rt.c - Runtime library for native Core compiler binary
// Provides all __builtin_* functions and the process entry point.
// Compiled with: gcc -c src/runtime/compiler_rt.c -o build/runtime.o
// Linked with: gcc -no-pie -o build/corec build/compiler.o build/runtime.o

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// -------------------------------------------------------------------------
// Bump allocator for string operations
// -------------------------------------------------------------------------
// The compiler processes one file then exits, so no free() is needed.
// 32MB is enough for any reasonable Core source file + compiler working set.

static char heap[256 * 1024 * 1024];
static size_t heap_pos = 0;

static void *bump_alloc(size_t size) {
    // Align to 8 bytes
    size = (size + 7) & ~7;
    if (heap_pos + size > sizeof(heap)) {
        fprintf(stderr, "runtime: bump allocator OOM (%zu bytes requested)\n", size);
        exit(1);
    }
    void *ptr = heap + heap_pos;
    heap_pos += size;
    memset(ptr, 0, size);
    return ptr;
}

static char *str_dup(const char *s) {
    size_t len = strlen(s);
    char *dst = (char *)bump_alloc(len + 1);
    memcpy(dst, s, len);
    dst[len] = '\0';
    return dst;
}

// -------------------------------------------------------------------------
// Public allocator — used by codegen for struct/array heap allocation
// -------------------------------------------------------------------------

void *__builtin_alloc(unsigned long size) {
    return bump_alloc(size);
}

// -------------------------------------------------------------------------
// Runtime globals for argc/argv (set by main() before calling compiler_main)
// -------------------------------------------------------------------------

static int rt_argc = 0;
static char **rt_argv = NULL;

// -------------------------------------------------------------------------
// String builtins
// -------------------------------------------------------------------------

int __builtin_str_len(const char *s) {
    if (!s) return 0;
    return (int)strlen(s);
}

char *__builtin_str_get(const char *s, int idx) {
    if (!s || idx < 0 || idx >= (int)strlen(s)) {
        char *empty = (char *)bump_alloc(1);
        empty[0] = '\0';
        return empty;
    }
    char *result = (char *)bump_alloc(2);
    result[0] = s[idx];
    result[1] = '\0';
    return result;
}

char *__builtin_str_sub(const char *s, int start, int length) {
    if (!s || start < 0 || start >= (int)strlen(s) || length <= 0) {
        char *empty = (char *)bump_alloc(1);
        empty[0] = '\0';
        return empty;
    }
    size_t slen = strlen(s);
    if (start + length > (int)slen) length = (int)(slen - start);
    char *result = (char *)bump_alloc(length + 1);
    memcpy(result, s + start, length);
    result[length] = '\0';
    return result;
}

char *__builtin_int_to_str(int value) {
    // Max int fits in 12 chars (including '-' sign and null terminator)
    char buf[16];
    snprintf(buf, sizeof(buf), "%d", value);
    return str_dup(buf);
}

char *__builtin_str_push(const char *s, const char *c) {
    if (!s) s = "";
    if (!c) c = "";
    size_t slen = strlen(s);
    size_t clen = strlen(c);
    char *result = (char *)bump_alloc(slen + clen + 1);
    memcpy(result, s, slen);
    memcpy(result + slen, c, clen);
    result[slen + clen] = '\0';
    return result;
}

char *__builtin_str_from_int(int value) {
    return __builtin_int_to_str(value);
}

int __builtin_str_to_int(const char *s) {
    if (!s || *s == '\0') return 0;
    char *end = NULL;
    long val = strtol(s, &end, 10);
    if (end == s) return 0;  // no digits found
    return (int)val;
}

int __builtin_str_eq(const char *a, const char *b) {
    if (a == b) return 1;
    if (!a || !b) return 0;
    return strcmp(a, b) == 0 ? 1 : 0;
}

long __builtin_str_cmp(const char *a, const char *b) {
    if (a == NULL && b == NULL) return 0;
    if (a == NULL) return -1;
    if (b == NULL) return 1;
    int r = strcmp(a, b);
    if (r < 0) return -1;
    if (r > 0) return 1;
    return 0;
}

// I/O builtins

char *__builtin_read_file(const char *path) {
    if (!path) return str_dup("");
    FILE *f = fopen(path, "rb");
    if (!f) return str_dup("");
    // Get file size
    fseek(f, 0, SEEK_END);
    long fsize = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (fsize < 0) { fclose(f); return str_dup(""); }
    // Read entire file
    char *content = (char *)bump_alloc(fsize + 1);
    size_t nread = fread(content, 1, fsize, f);
    fclose(f);
    content[nread] = '\0';
    // Trim trailing newlines (optional, matches bootstrap behavior)
    return content;
}

int __builtin_write_file(const char *path, const char *content) {
    if (!path || !content) return -1;
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    size_t written = fwrite(content, 1, strlen(content), f);
    fclose(f);
    return (int)written;
}

char *__builtin_get_arg(int n) {
    if (n < 0 || n >= rt_argc) return str_dup("");
    return str_dup(rt_argv[n]);
}

// -------------------------------------------------------------------------
// I/O builtins
// -------------------------------------------------------------------------

void __builtin_print(const char *s) {
    if (s) fputs(s, stdout);
    fflush(stdout);
}

void __builtin_println(const char *s) {
    if (s) {
        puts(s);  // adds trailing newline
    } else {
        putchar('\n');
    }
    fflush(stdout);
}

// -------------------------------------------------------------------------
// Entry point
// -------------------------------------------------------------------------
// The Core function that the compiled code provides.
extern int compiler_main(void);

// Global array initializer (generated by x86-64 backend).
extern void _init_globals(void);

int main(int argc, char *argv[]) {
    rt_argc = argc;
    rt_argv = argv;
    _init_globals();
    return compiler_main();
}
