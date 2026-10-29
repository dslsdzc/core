// Arena allocator regressions: class chunks must stay tied to their slot and
// a slot popped from the free list must become the arena's current slot.
import arena
import io

// Runtime globals (normally provided by rt.cr when --static is used)
g_current_arena : int, mut = -1
g_arena_pool_data : string, mut
g_arena_free_list : int, mut = -1
g_arena_slot : string, mut
g_arena_slot_next : string, mut

fn addr(s: string) -> int:
    v : ., mut = 0
    unsafe:
        v = @ptr_of(s)
    return v

fn in_range(p: int, start: string, n: int) -> int:
    s := addr(start)
    if p >= s && p < s + n:
        return 1
    return 0

fn slot_of(ai: int) -> int:
    return cell_load(g_arena_slot, ai * 8)

fn slot_next(sl: int) -> int:
    return cell_load(g_arena_slot_next, sl * 8)

fn test_class_chunk_slot_alias() -> int:
    arena_init(67108864, 65536)
    a := arena_new()
    if a < 0:
        return 10
    small := alloc(16)
    fill := alloc(1044480)
    other := alloc(32)
    again := alloc(16)
    ap := addr(again)
    if in_range(ap, other, 32) != 0:
        return 11
    if in_range(ap, fill, 1044480) != 0:
        return 12
    if in_range(ap, small, 16) != 0:
        return 13
    arena_reset(a)
    return 0

fn test_free_list_slot_link() -> int:
    arena_init(67108864, 65536)
    a := arena_new()
    if a < 0:
        return 20
    small := alloc(16)
    fill := alloc(1044480)
    b := arena_new()
    if b < 0:
        return 21
    b_slot := slot_of(b)
    old_slot := slot_of(a)
    arena_reset(b)
    p32 := alloc(32)
    new_slot := slot_of(a)
    // The popped slot must become the arena's current slot and be linked
    // ahead of the previous head. On the buggy path this stays at the old
    // slot, and the next allocation carves over `fill`.
    if new_slot != b_slot:
        return 25
    // The blob links the new slot to the old head; the legacy body links in
    // the opposite direction and leaves the new slot's next at -1. Both must
    // avoid a self-loop; the blob's reset walk is tested separately.
    nxt := slot_next(new_slot)
    if nxt == new_slot:
        return 26
    if nxt != old_slot && nxt != -1:
        return 26
    next := alloc(56)
    np := addr(next)
    // The buggy path returns the old slot's freed class chunk, which aliases
    // the 1044480-byte fill allocation.
    if in_range(np, fill, 1044480) != 0:
        return 22
    if in_range(np, p32, 32) != 0:
        return 23
    if in_range(np, small, 16) != 0:
        return 24
    if addr(p32) == addr(next):
        return 27
    arena_reset(a)
    return 0

fn main() -> int:
    r := test_class_chunk_slot_alias()
    if r != 0:
        return r
    r2 := test_free_list_slot_link()
    if r2 != 0:
        return r2
    return 0
