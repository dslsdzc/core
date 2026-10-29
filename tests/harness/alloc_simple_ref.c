/* Simple allocator parity: Core blob alloc_simple versus this C reference. */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#define HEAP_SIZE (1UL << 30)
#define MAX_REQUEST 67108864L

extern char *_g_g_heap_ptr;
extern char *_g_g_heap_end;
extern long heap_expand(void);
extern char *alloc_simple(long size, char *heap_start);

static char *ref_alloc(long size, char *heap_start) {
    if (size < 0 || size > MAX_REQUEST)
        return NULL;
    long aligned = (size + 15) / 8 * 8;
    char *hp = _g_g_heap_ptr;
    if (hp == NULL) {
        hp = heap_start;
        _g_g_heap_ptr = hp;
        _g_g_heap_end = heap_start + HEAP_SIZE;
    }
    char *newp = hp + aligned;
    if (newp > _g_g_heap_end) {
        if (heap_expand() != 0)
            return NULL;
        hp = _g_g_heap_ptr;
        newp = hp + aligned;
        if (newp > _g_g_heap_end)
            return NULL;
    }
    _g_g_heap_ptr = newp;
    memset(hp, 0, (size_t)aligned);
    *(long *)hp = size;
    return hp + 8;
}

static int check_one(long size, char *heap_start) {
    _g_g_heap_ptr = NULL;
    _g_g_heap_end = NULL;
    char *a = alloc_simple(size, heap_start);
    long a_off = a ? (long)(a - heap_start) : -1;
    long a_hdr = a ? *(long *)(a - 8) : -1;
    unsigned char a_first = (a && size > 0) ? (unsigned char)a[0] : 0;
    unsigned char a_last = (a && size > 0) ? (unsigned char)a[size - 1] : 0;

    _g_g_heap_ptr = NULL;
    _g_g_heap_end = NULL;
    char *b = ref_alloc(size, heap_start);
    long b_off = b ? (long)(b - heap_start) : -1;
    long b_hdr = b ? *(long *)(b - 8) : -1;
    unsigned char b_first = (b && size > 0) ? (unsigned char)b[0] : 0;
    unsigned char b_last = (b && size > 0) ? (unsigned char)b[size - 1] : 0;

    if (a_off != b_off || a_hdr != b_hdr ||
        a_first != b_first || a_last != b_last) {
        fprintf(stderr,
                "size %ld mismatch: core off=%ld hdr=%ld first=%u last=%u; "
                "ref off=%ld hdr=%ld first=%u last=%u\n",
                size, a_off, a_hdr, a_first, a_last,
                b_off, b_hdr, b_first, b_last);
        return 1;
    }
    if (a != NULL && size > 0) {
        a[0] = (char)0x5a;
        if ((unsigned char)a[0] != 0x5a) {
            fprintf(stderr, "size %ld first byte is not writable\n", size);
            return 1;
        }
        if (size > 1) {
            a[size - 1] = (char)0xa5;
            if ((unsigned char)a[size - 1] != 0xa5) {
                fprintf(stderr, "size %ld last byte is not writable\n", size);
                return 1;
            }
        }
    }
    return 0;
}

int main(void) {
    char *heap_start = mmap(NULL, HEAP_SIZE, PROT_READ | PROT_WRITE,
                            MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE,
                            -1, 0);
    if (heap_start == MAP_FAILED) {
        perror("mmap");
        return 1;
    }

    const long sizes[] = {
        0, 1, 7, 8, 15, 16, 3361, 3362, 4088, 4089, 4096,
        1048576L - 8, 1048576L, 1048576L + 8,
        67108864L - 8, 67108864L, 67108864L + 1,
        1099511627776L - 1, 1099511627776L, 1099511627776L + 1,
        -1,
    };
    for (size_t i = 0; i < sizeof(sizes) / sizeof(sizes[0]); i++) {
        if (check_one(sizes[i], heap_start) != 0)
            return 1;
    }
    printf("simple allocator parity: %zu sizes\n",
           sizeof(sizes) / sizeof(sizes[0]));
    return 0;
}
