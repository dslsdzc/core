/* Shared allocator state for the Core blob parity harness.
 *
 * The Core object owns the globals (they are emitted as _g_g_* symbols by the
 * Python bootstrap).  This file only provides the external heap_expand call.
 */

#include <stddef.h>
#include <sys/mman.h>

/* Runtime-boundary adapters for the standalone single-arena C model.
 * The Core blob is extracted without the rest of the runtime, so the symbols
 * below are supplied here. The model uses arena 0 and never suspends arena
 * metadata; these values match the reference state initialized in setup. */
long _g_g_arena_suspend = 0;
long rt_m_idx(void) { return 0; }
long rt_current_arena(void) { return 0; }
long rt_arena_suspend(void) { return _g_g_arena_suspend; }

#define ALLOC_HEAP_SIZE (1UL << 30)

extern char *_g_g_heap_ptr;
extern char *_g_g_heap_end;

long heap_expand(void) {
    void *p = mmap(NULL, ALLOC_HEAP_SIZE, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (p == MAP_FAILED)
        return -1;
    _g_g_heap_ptr = (char *)p;
    _g_g_heap_end = (char *)p + ALLOC_HEAP_SIZE;
    return 0;
}

/* The arena body is present in the same object; the simple parity harness does
 * not call it. Provide the symbol so the whole object links. */
long arena_grow_pool(void) {
    return -1;
}
