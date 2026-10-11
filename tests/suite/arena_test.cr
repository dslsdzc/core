// Arena memory model test suite
// Tests basic arena lifecycle, nesting, and free-list reuse.
import arena
import io

// Runtime globals (normally provided by rt.cr when --static is used)
// These are redeclared here so the test works without --static too.
g_current_arena : int, mut = -1
g_arena_pool_data : string, mut
g_arena_free_list : int, mut = -1

fn test_arena_basic() -> int:
    arena_init(1048576, 65536)  // 1MB pool, 64KB chunks

    // Create arena
    a1 := arena_new()
    if a1 < 0:
        return 1
    // arena_new failed
    if g_current_arena != a1:
        return 2
    // not activated

    // Alloc should now use arena
    p := alloc(64)
    if p == 0:
        return 3
    // alloc failed

    // Reset
    arena_reset(a1)
    if g_current_arena >= 0:
        return 4
    // should be -1 after reset

    // Re-use arena from free list
    a2 := arena_new()
    if a2 != a1:
        return 5
    // should reuse same ID

    arena_reset(a2)
    return 0  // pass

fn test_arena_nesting() -> int:
    arena_init(1048576, 65536)

    a1 := arena_new()    // parent
    p1 := alloc(32)
    if p1 == 0:
        return 1

    a2 := arena_new()    // child (arena in loop)
    if g_current_arena != a2:
        return 2
    p2 := alloc(64)
    if p2 == 0:
        return 3

    // Child reset should restore parent
    arena_reset(a2)
    if g_current_arena != a1:
        return 4

    // Parent still works
    p3 := alloc(16)
    if p3 == 0:
        return 5

    arena_reset(a1)
    return 0

fn test_arena_free_list_reuse() -> int:
    arena_init(1048576, 65536)

    // Allocate multiple arenas
    a1 := arena_new()
    arena_reset(a1)
    a2 := arena_new()
    arena_reset(a2)
    a3 := arena_new()
    arena_reset(a3)

    // Next new should reuse a3 (LIFO free list)
    a4 := arena_new()
    if a4 != a3:
        return 1
    // should reuse most recently freed

    arena_reset(a4)
    return 0

fn main() -> int:
    r1 := test_arena_basic()
    if r1 != 0:
        print("FAIL basic: ")
        println(int_str(r1))
        return r1

    r2 := test_arena_nesting()
    if r2 != 0:
        print("FAIL nesting: ")
        println(int_str(r2))
        return r2

    r3 := test_arena_free_list_reuse()
    if r3 != 0:
        print("FAIL freelist: ")
        println(int_str(r3))
        return r3

    println("ALL PASS")
    return 0
