/* Independent arena allocator model for the Core blob parity test.
 *
 * The Core object owns the real globals. This file keeps a second, separate
 * state in `Ref` and implements the same class/slot/static algorithm in C.
 * Both sides see the same size sequence; returned offsets and metadata must
 * match. Large mmap extents are covered by the Core test suite, not here.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#define SLOT_SIZE (1UL << 20)
#define SEG_SIZE (64UL << 20)
#define MAX_SEGS 8
#define MAX_SLOTS (MAX_SEGS * 64)
#define CLASSES 26
#define HEAP_SIZE (1UL << 30)
#define MAX_REQUEST 1099511627776L

extern char *alloc_arena(long size, char *heap_start, char *heap_end);
extern long heap_expand(void);
extern long arena_grow_pool(void);

extern char *_g_g_heap_ptr;
extern char *_g_g_heap_end;
extern char *_g_g_arena_scalars;
extern long _g_g_arena_scalars_ready;
extern long _g_g_arena_suspend;
extern char *_g_g_arena_slot;
extern char *_g_g_arena_slot_cursor;
extern char *_g_g_arena_slot_next;
extern char *_g_g_arena_static;
extern char *_g_g_arena_sizes;
extern char *_g_g_arena_cursors;
extern char *_g_g_segment_base;
extern char *_g_g_class_base;
extern char *_g_g_class_cursor;
extern char *_g_g_class_limit;
extern char *_g_g_class_lookup;

typedef struct {
    long max_size;
    long pool;
    long seg_count;
    long count;
    long free_head;
    char *seg[MAX_SEGS];
    long slot[8];
    long cursor[8];
    long next[MAX_SLOTS];
    long is_static[8];
    long size[8];
    long bump[8];
    long cbase[8 * CLASSES];
    long ccur[8 * CLASSES];
    long climit[8 * CLASSES];
    long lookup[256];
} Ref;

static Ref ref;
static char lookup_source[256];

static const long class_sizes[25] = {
    16, 20, 25, 31, 39, 49, 61, 76, 95, 119, 149, 186, 232, 290, 362,
    452, 565, 706, 882, 1102, 1377, 1721, 2151, 2689, 3361,
};

static void build_lookup(void) {
    for (int lb = 0; lb < 256; lb++) {
        long aligned = (long)lb * 16;
        long cls = 25;
        for (int i = 0; i < 25; i++) {
            if (aligned <= class_sizes[i]) {
                cls = i;
                break;
            }
        }
        ref.lookup[lb] = cls;
        lookup_source[lb] = (char)cls;
    }
}

static char *core_slot_base(long slot) {
    char **segs = (char **)_g_g_segment_base;
    return segs[slot / 64] + (slot % 64) * SLOT_SIZE;
}

static char *ref_slot_base(long slot) {
    return ref.seg[slot / 64] + (slot % 64) * SLOT_SIZE;
}

static long core_scalar(long off) {
    return *(long *)(_g_g_arena_scalars + off);
}

static long core_slot(long ai) {
    return ((long *)_g_g_arena_slot)[ai];
}

static long core_cursor(long ai) {
    return ((long *)_g_g_arena_slot_cursor)[ai];
}

static long core_static(long ai) {
    return ((long *)_g_g_arena_static)[ai];
}

static long core_size(long ai) {
    return ((long *)_g_g_arena_sizes)[ai];
}

static long core_bump(long ai) {
    return ((long *)_g_g_arena_cursors)[ai];
}

static long core_class_base(long idx) {
    return ((long *)_g_g_class_base)[idx];
}

static long core_class_cursor(long idx) {
    return ((long *)_g_g_class_cursor)[idx];
}

/* Called by the Core blob when the bump slot pool is exhausted. */
long arena_grow_pool(void) {
    long seg_count = core_scalar(24);
    if (seg_count >= MAX_SEGS)
        return -1;
    void *p = mmap(NULL, SEG_SIZE, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (p == MAP_FAILED)
        return -1;
    ((char **)_g_g_segment_base)[seg_count] = (char *)p;
    *(long *)(_g_g_arena_scalars + 24) = seg_count + 1;
    *(long *)(_g_g_arena_scalars + 16) += 64;
    return 0;
}

/* The class/slot test never takes the global heap path. */
long heap_expand(void) {
    return -1;
}

static int ref_grow(void) {
    if (ref.seg_count >= MAX_SEGS)
        return -1;
    void *p = mmap(NULL, SEG_SIZE, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (p == MAP_FAILED)
        return -1;
    ref.seg[ref.seg_count++] = (char *)p;
    ref.pool += 64;
    return 0;
}

static int ref_get_slot(long ai) {
    long slot;
    if (ref.free_head >= 0) {
        slot = ref.free_head;
        ref.free_head = ref.next[slot];
    } else {
        if (ref.count >= ref.pool) {
            if (ref_grow() != 0)
                return -1;
        }
        if (ref.count >= ref.pool)
            return -1;
        slot = ref.count++;
    }
    long old = ref.slot[ai];
    ref.next[slot] = old;
    ref.slot[ai] = slot;
    ref.cursor[ai] = 0;
    return 0;
}

static int ref_alloc(long size, char **out) {
    *out = NULL;
    if (size < 0 || size > MAX_REQUEST)
        return -1;
    long aligned = (size + 15) / 8 * 8;
    long ai = 0;
    long slot = ref.slot[ai];
    if (slot < 0)
        return -1;
    if (ref.is_static[ai]) {
        long cur = ref.bump[ai];
        long limit = ref.size[ai];
        if (cur + aligned > limit)
            return -1;
        ref.bump[ai] = cur + aligned;
        *out = ref_slot_base(slot) + cur + 8;
        return 0;
    }
    if (aligned > SLOT_SIZE)
        return -1;
    long max_size = ref.max_size;
    char *slot_base = ref_slot_base(slot);
    for (;;) {
        long lookup = aligned / 16;
        long cls = 25;
        if (lookup <= 255)
            cls = ref.lookup[lookup];
        long idx = ai * CLASSES + cls;
        long base = ref.cbase[idx];
        if (base < 0) {
            if (cls == 25) {
                long cur = ref.cursor[ai];
                if (aligned > max_size - cur) {
                    if (ref_get_slot(ai) != 0)
                        return -1;
                    slot = ref.slot[ai];
                    slot_base = ref_slot_base(slot);
                } else {
                    base = (long)slot_base + cur;
                    ref.cbase[idx] = base;
                    ref.climit[idx] = (long)slot_base + max_size;
                    ref.ccur[idx] = 0;
                    ref.cursor[ai] = max_size;
                }
            } else {
                long cur = ref.cursor[ai];
                long newcur = cur + 4096;
                if (newcur > max_size) {
                    if (ref_get_slot(ai) != 0)
                        return -1;
                    slot = ref.slot[ai];
                    slot_base = ref_slot_base(slot);
                } else {
                    base = (long)slot_base + cur;
                    ref.cursor[ai] = newcur;
                    ref.cbase[idx] = base;
                    ref.climit[idx] = (long)slot_base + newcur;
                    ref.ccur[idx] = 0;
                }
            }
        }
        base = ref.cbase[idx];
        long cur = ref.ccur[idx];
        long limit = ref.climit[idx];
        if (base >= 0 && cur + aligned <= limit - base) {
            ref.ccur[idx] = cur + aligned;
            *out = (char *)(base + cur + 8);
            return 0;
        }
        if (base >= 0)
            ref.cbase[idx] = -1;
    }
}

static void setup_core(int static_mode, long pool_init) {
    _g_g_arena_scalars = calloc(1, 64);
    _g_g_arena_slot = calloc(4096, 8);
    _g_g_arena_slot_cursor = calloc(4096, 8);
    _g_g_arena_slot_next = calloc(MAX_SLOTS, 8);
    _g_g_arena_static = calloc(4096, 8);
    _g_g_arena_sizes = calloc(4096, 8);
    _g_g_arena_cursors = calloc(4096, 8);
    _g_g_segment_base = calloc(256, sizeof(char *));
    _g_g_class_base = calloc(4096, 8);
    _g_g_class_cursor = calloc(4096, 8);
    _g_g_class_limit = calloc(4096, 8);
    _g_g_class_lookup = calloc(256, 8);
    _g_g_heap_ptr = NULL;
    _g_g_heap_end = NULL;
    _g_g_arena_scalars_ready = 1;
    _g_g_arena_suspend = 0;

    void *seg = mmap(NULL, SEG_SIZE, PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (seg == MAP_FAILED) {
        perror("mmap core segment");
        exit(1);
    }
    ((char **)_g_g_segment_base)[0] = (char *)seg;
    *(long *)(_g_g_arena_scalars + 0) = 0;
    *(long *)(_g_g_arena_scalars + 8) = SLOT_SIZE;
    *(long *)(_g_g_arena_scalars + 16) = pool_init;
    *(long *)(_g_g_arena_scalars + 24) = 1;
    *(long *)(_g_g_arena_scalars + 32) = 1;
    *(long *)(_g_g_arena_scalars + 40) = -1;
    ((long *)_g_g_arena_slot)[0] = 0;
    ((long *)_g_g_arena_slot_cursor)[0] = 0;
    ((long *)_g_g_arena_slot_next)[0] = -1;
    ((long *)_g_g_arena_static)[0] = static_mode;
    ((long *)_g_g_arena_sizes)[0] = SLOT_SIZE;
    ((long *)_g_g_arena_cursors)[0] = 0;
    for (int i = 0; i < 256; i++)
        ((long *)_g_g_class_lookup)[i] = lookup_source[i];
    for (int i = 0; i < 8 * CLASSES; i++) {
        ((long *)_g_g_class_base)[i] = -1;
        ((long *)_g_g_class_cursor)[i] = 0;
        ((long *)_g_g_class_limit)[i] = 0;
    }
}

static void setup_ref(int static_mode, long pool_init) {
    memset(&ref, 0, sizeof(ref));
    build_lookup();
    void *seg = mmap(NULL, SEG_SIZE, PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (seg == MAP_FAILED) {
        perror("mmap ref segment");
        exit(1);
    }
    ref.max_size = SLOT_SIZE;
    ref.pool = pool_init;
    ref.seg_count = 1;
    ref.count = 1;
    ref.free_head = -1;
    ref.seg[0] = (char *)seg;
    ref.slot[0] = 0;
    ref.cursor[0] = 0;
    ref.next[0] = -1;
    ref.is_static[0] = static_mode;
    ref.size[0] = SLOT_SIZE;
    ref.bump[0] = 0;
    for (int i = 0; i < 8 * CLASSES; i++) {
        ref.cbase[i] = -1;
        ref.ccur[i] = 0;
        ref.climit[i] = 0;
    }
}

static int compare_after(long size, char *cp, char *rp) {
    long coff = cp ? (long)(cp - core_slot_base(0)) : -1;
    long roff = rp ? (long)(rp - ref_slot_base(0)) : -1;
    if (coff != roff) {
        fprintf(stderr, "size %ld offset mismatch: core=%ld ref=%ld\n",
                size, coff, roff);
        return 1;
    }
    long cs = core_slot(0), rs = ref.slot[0];
    long cc = core_cursor(0), rc = ref.cursor[0];
    if (cs != rs || cc != rc) {
        fprintf(stderr, "size %ld slot/cursor mismatch: core=%ld/%ld ref=%ld/%ld\n",
                size, cs, cc, rs, rc);
        return 1;
    }
    if (core_static(0) != ref.is_static[0] ||
        core_size(0) != ref.size[0] ||
        core_bump(0) != ref.bump[0]) {
        fprintf(stderr, "size %ld static state mismatch\n", size);
        return 1;
    }
    long core_base0 = (long)core_slot_base(0);
    long ref_base0 = (long)ref_slot_base(0);
    for (int i = 0; i < CLASSES; i++) {
        long cb = core_class_base(i);
        long rb = ref.cbase[i];
        long cl = ((long *)_g_g_class_limit)[i];
        long rl = ref.climit[i];
        if (cb >= 0 && rb >= 0) {
            cb -= core_base0;
            rb -= ref_base0;
            cl -= core_base0;
            rl -= ref_base0;
        } else {
            cb = -1;
            rb = -1;
            cl = 0;
            rl = 0;
        }
        if (cb != rb || cl != rl ||
            core_class_cursor(i) != ref.ccur[i]) {
            fprintf(stderr,
                    "size %ld class %d mismatch: core=%ld/%ld/%ld ref=%ld/%ld/%ld\n",
                    size, i, cb, cl, core_class_cursor(i),
                    rb, rl, ref.ccur[i]);
            return 1;
        }
    }
    return 0;
}

static int run_sequence(const long *sizes, size_t n, int static_mode,
                        long pool_init) {
    build_lookup();
    setup_core(static_mode, pool_init);
    setup_ref(static_mode, pool_init);
    long first_slot = ref.slot[0];
    int switched = 0;
    for (size_t i = 0; i < n; i++) {
        char *cp = alloc_arena(sizes[i], (char *)0x10000000, (char *)0x20000000);
        char *rp = NULL;
        int rr = ref_alloc(sizes[i], &rp);
        if ((cp == NULL) != (rr != 0)) {
            fprintf(stderr, "size %ld null mismatch: core=%p ref=%p\n",
                    sizes[i], (void *)cp, (void *)rp);
            return 1;
        }
        if (compare_after(sizes[i], cp, rp) != 0)
            return 1;
        if (ref.slot[0] != first_slot)
            switched = 1;
    }
    if (static_mode == 0 && sizes[0] != 16 && !switched) {
        fprintf(stderr, "dynamic sequence did not switch slots\n");
        return 1;
    }
    return 0;
}

int main(void) {
    const long dynamic_sizes[] = {
        0, 1, 7, 8, 15, 16, 32, 64,
        3361, 3362, 4088, 4089, 4096,
        100000, 500000, 1048568, 1048568, 1048568,
        16, 32, 3361, 100000,
    };
    if (run_sequence(dynamic_sizes,
                     sizeof(dynamic_sizes) / sizeof(dynamic_sizes[0]), 0, 64) != 0)
        return 1;
    const long grow_sizes[] = {16, 1048568, 1048568, 16};
    if (run_sequence(grow_sizes,
                     sizeof(grow_sizes) / sizeof(grow_sizes[0]), 0, 1) != 0)
        return 1;
    const long static_sizes[] = {
        0, 16, 32, 4096, 100000, 500000, 100000,
    };
    if (run_sequence(static_sizes,
                     sizeof(static_sizes) / sizeof(static_sizes[0]), 1, 64) != 0)
        return 1;
    printf("arena C model: %zu dynamic + %zu grow + %zu static sizes\n",
           sizeof(dynamic_sizes) / sizeof(dynamic_sizes[0]),
           sizeof(grow_sizes) / sizeof(grow_sizes[0]),
           sizeof(static_sizes) / sizeof(static_sizes[0]));
    return 0;
}
