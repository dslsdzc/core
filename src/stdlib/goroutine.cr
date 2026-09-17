// Goroutine lifecycle — G struct creation and teardown
import arena
import sched

// goroutine_wrapper_addr() — the address of goroutine_entry_wrapper
// (rt.s / emitted by the ELF backend). The backend intercepts calls to
// this name and emits movabs r10, <wrapper VA> (patched at link time),
// so the stub body is never executed.
fn goroutine_wrapper_addr() -> int {
    return 0;
}

// Goroutine ID counter
g_next_id : int, mut = 1;

// G struct layout (80 bytes):
//   0: id
//   8: status (0=runnable, 1=running, 2=waiting, 3=dead)
//  16: sp (stack pointer for fiber)
//  24: stack_lo (lowest address of stack)
//  32: arena_id
//  40: result_ch (result channel, set by sched_go)
//  48: next (linked list for run queue / send_wait / recv_wait)
//  56: saved_fn (entry function ptr, for wrapper dispatch)
//  64: saved_arg (saved argument, for wrapper dispatch)
//  72: temp_val (temp value for wait queue handoff)

fn g_new(entry_fn: int, arg: int, arg_type: int) -> string {
    // Create the goroutine's arena FIRST: the fiber stack and G struct must
    // live in the G's own arena (not a transient one), so they survive until
    // g_free reclaims them at goroutine exit. With the subgraph arena model,
    // alloc() routes to g_current_arena when it is >= 0 — arena_new() sets it.
    aid := arena_new();

    // Allocate stack (16KB) — from the G's arena
    stack := alloc(16384);
    stack_top := stack + 16384 - 8;

    // Initialize fiber. The entry is ALWAYS goroutine_entry_wrapper
    // (rt.s / emitted by the ELF backend): it reads saved_fn/saved_arg
    // from this G (offsets 56/64), calls saved_fn(saved_arg), and sends
    // the result to result_ch (offset 40). goroutine_wrapper_addr() is a
    // backend builtin resolving the wrapper's VA at link time.
    wrap_addr := goroutine_wrapper_addr();
    sp := fiber_init(stack_top, wrap_addr);

    // Allocate G struct (80 bytes)
    g := alloc(80);
    id := g_next_id; g_next_id = g_next_id + 1;
    w64(g, 0, id);           // id
    w64(g, 8, 0);            // _Grunnable
    w64(g, 16, sp);          // stack pointer
    w64(g, 24, stack);       // stack_lo
    w64(g, 32, aid);         // arena_id
    w64(g, 40, 0);           // result_ch = 0 (default)
    w64(g, 48, -1);          // next = -1
    w64(g, 56, entry_fn);    // saved_fn = entry function ptr
    w64(g, 64, arg);         // saved_arg
    w64(g, 72, 0);           // temp_val = 0

    return g;
}

fn g_free(g: string) {
    // Reset arena (reclaims the fiber stack + G struct, which live in it)
    aid := r64(g, 32);
    arena_reset(aid);
    // Mark G dead so it is never re-enqueued (status 3 = _Gdead)
    w64(g, 8, 3);
}
