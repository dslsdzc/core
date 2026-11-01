// Goroutine lifecycle — G struct creation and teardown
import arena
import sched

// goroutine_wrapper_addr() — the address of goroutine_entry_wrapper
// (rt.s / emitted by the ELF backend). The backend intercepts calls to
// this name and emits movabs r10, <wrapper VA> (patched at link time),
// so the stub body is never executed.
fn goroutine_wrapper_addr() -> int:
    return 0

// Goroutine IDs are per-M (g_next_id_m is allocated by sched_init_n).
// Fiber stack size for one G. This is an execution policy constant, not a
// frontend type-layout rule.
G_STACK_SIZE : int = 16384

// G struct layout (104 bytes):
//   0: id
//   8: status (0=runnable, 1=running, 2=waiting, 3=dead)
//  16: sp (stack pointer for fiber)
//  24: stack_lo (lowest address of stack)
//  32: arena_id
//  40: result_ch (result channel, set by sched_go)
//  48: next (run queue / channel wait list link)
//  56: saved_fn (entry function ptr, for wrapper dispatch)
//  64: saved_arg (saved argument, for wrapper dispatch)
//  72: temp_val (legacy channel handoff storage; removed in Task 3)
//  80: saved_current_arena (nested region current; -1 = use base arena)
//  88: home_m (0A: G never migrates)
//  96: dead_next (deferred reclamation list; never reuse run-queue next)

fn g_new(entry_fn: int, arg: int, arg_type: int) -> string, pub:
    // Create the goroutine's arena FIRST: the fiber stack and G struct must
    // live in the G's own arena (not a transient one), so they survive until
    // g_free reclaims them at goroutine exit. With the subgraph arena model,
    // alloc() routes to g_current_arena when it is >= 0 — arena_new() sets it.
    aid := arena_new()

    // Allocate stack (G_STACK_SIZE) — from the G's arena
    stack := alloc(G_STACK_SIZE)
    stack_top := stack + G_STACK_SIZE - 8

    // Initialize fiber. The entry is ALWAYS goroutine_entry_wrapper
    // (rt.s / emitted by the ELF backend): it reads saved_fn/saved_arg
    // from this G (offsets 56/64), calls saved_fn(saved_arg), and sends
    // the result to result_ch (offset 40). goroutine_wrapper_addr() is a
    // backend builtin resolving the wrapper's VA at link time.
    wrap_addr := goroutine_wrapper_addr()
    sp := fiber_init(stack_top, wrap_addr)

    // Allocate G struct (104 bytes; +80 saved arena, +88 home M, +96 dead next)
    g := alloc(104)
    home : ., mut = rt_m_idx()
    if home < 0:
        home = 0
    id := cell_load(g_next_id_m, home * 8)
    cell_store(g_next_id_m, home * 8, id + 1)
    cell_store(g, 0, id)           // id
    cell_store(g, 8, 0)            // _Grunnable
    cell_store(g, 16, sp)          // stack pointer
    cell_store(g, 24, stack)       // stack_lo
    cell_store(g, 32, aid)         // arena_id
    cell_store(g, 40, 0)           // result_ch = 0 (default)
    cell_store(g, 48, -1)          // next = -1
    cell_store(g, 56, entry_fn)    // saved_fn = entry function ptr
    cell_store(g, 64, arg)         // saved_arg
    cell_store(g, 72, 0)           // temp_val = 0 (legacy until Task 3)
    cell_store(g, 80, -1)          // saved_current_arena = base
    cell_store(g, 88, home)        // 0A: fixed home M
    cell_store(g, 96, -1)          // dead_next

    return g

fn g_free(g: string), pub:
    // Mark dead and defer arena reset until the home M is off this stack.
    home : ., mut = cell_load(g, 88)
    if home < 0:
        home = 0
    rt_atomic_store(g, 8, 3)       // _Gdead
    cell_store(g, 96, cell_load(g_dead_head_m, home * 8))
    cell_store(g_dead_head_m, home * 8, g)
