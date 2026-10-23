# 并发 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** M:N concurrency — `go f()` creates a fiber on a separate arena, goroutines communicate through channels with copy semantics, cooperative scheduling at channel operations.

**Architecture:** rt.s fiber_switch asm for context switching. `sched.cr` for run queue + scheduler. `chan.cr` for channel send/recv. `goroutine.cr` for go/fiber lifecycle. Arena isolation per goroutine.

**Tech Stack:** Core runtime (rt.s), Core stdlib (sched.cr, chan.cr, goroutine.cr), IR gen, ELF backend

## Global Constraints

- No shared memory between goroutines — values copied through channels
- Each goroutine gets its own arena (arena_new at go, arena_reset at exit)
- Cooperative scheduling — only switches at channel send/recv
- Fiber switch via rt.s assembly (save/restore registers + stack pointer)
- IR_SPAWN(27) and IR_YIELD(28) existing opcodes
- Uses `jj` for version control

---

### Task 1: rt.s — Fiber Switch Assembly

**Files:**
- Modify: `src/runtime/rt.s`

Add fiber_switch and fiber_init functions:

```asm
# fiber_switch(current_sp_addr, next_sp) -> int
# Save current context, load next context
.globl fiber_switch
.type fiber_switch, @function
fiber_switch:
    # rdi = &current_g.stack_ptr (address to save RSP to)
    # rsi = next_g.stack_ptr (RSP to restore)
    
    # Save callee-saved registers
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    
    # Save RSP
    mov [rdi], rsp
    
    # Restore next RSP
    mov rsp, rsi
    
    # Restore callee-saved registers
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    
    ret

# fiber_init(stack_bottom, entry_fn) -> int
# Initialize a new fiber's stack and return its initial SP
.globl fiber_init
.type fiber_init, @function
fiber_init:
    # rdi = stack_bottom (highest address of the 16KB stack)
    # rsi = entry_fn (function to call when fiber starts)
    
    # Set up a fake stack frame so fiber_switch will jump to entry_fn
    # Stack layout (from top):
    #   [return address] = entry_fn
    #   [saved rbp] = 0
    #   [saved r15-r12, rbx] = 0
    # RSP after fiber_switch pops these will be at entry_fn
    
    mov rax, rdi        # rax = stack_bottom
    sub rax, 48         # Reserve space for callee-saved regs (6*8)
    mov [rax], rsi      # Return address = entry_fn
    
    # Clear registers for clean start
    sub rax, 8          # Fake return address for when entry_fn returns
    mov qword [rax], 0  # entry_fn returns to 0 = crash (intentional)
    
    ret
```

- [ ] **Step 1: Add fiber_switch and fiber_init**

Add the assembly code at the end of rt.s (before the final newline).

- [ ] **Step 2: Verify assembly**

```bash
as -o /tmp/rt.o src/runtime/rt.s
```

Expected: No errors.

- [ ] **Step 3: Commit**

```bash
jj commit -m "feat: fiber_switch/fiber_init asm for goroutine context switching"
```

---

### Task 2: stdlib — Goroutine + Scheduler + Channel

**Files:**
- Create: `src/stdlib/goroutine.cr`
- Create: `src/stdlib/sched.cr`
- Create: `src/stdlib/chan.cr`

- [ ] **Step 1: Create goroutine.cr**

```core
import arena
import sched

// Goroutine lifecycle
g_next_id : int, mut = 1

fn g_new(entry_fn: int, arg: int, arg_type: int) -> int:
    // Allocate stack (16KB)
    stack := alloc(16384)
    stack_top := stack + 16384 - 8

    // Create new arena for this goroutine
    aid := arena_new()

    // Initialize fiber
    sp := fiber_init(stack_top, entry_fn)

    // Allocate G struct
    g := alloc(64)
    // G layout: id(8), status(8), sp(8), stack_lo(8), arena_id(8), chan_wait(8), next(8)
    id := g_next_id
    g_next_id = g_next_id + 1
    w64(g, 0, id)           // id
    w64(g, 8, 0)            // _Grunnable
    w64(g, 16, sp)          // stack pointer
    w64(g, 24, stack)       // stack_lo
    w64(g, 32, aid)         // arena_id
    w64(g, 40, -1)          // chan_wait = -1
    w64(g, 48, -1)          // next = -1

    // Enqueue to scheduler
    sched_enqueue(g)

    return g

fn g_free(g: int):
    // Reset arena
    aid := r64(g, 32)
    arena_reset(aid)
```

- [ ] **Step 2: Create sched.cr**

```core
// M:N scheduler — M OS threads, N goroutines

g_machines : string, mut    // M array
g_machine_count : int, mut

g_global_runq_head : int, mut = -1  // global run queue
g_global_runq_tail : int, mut = -1

fn sched_init():
    // Initialize M workers (one per CPU)
    // For now: single-threaded (1 M, cooperative)
    m := alloc(32)
    w64(m, 0, 0)     // id = 0
    w64(m, 8, -1)     // cur_g = none
    w64(m, 16, -1)    // runq_head = empty
    w64(m, 24, -1)    // runq_tail = empty
    g_machine_count = 1

fn sched_enqueue(g: int):
    // Add to global run queue (simple for now)
    if g_global_runq_head < 0:
        g_global_runq_head = g
        g_global_runq_tail = g
    else:
        w64(g_global_runq_tail, 48, g)  // next = g
        g_global_runq_tail = g

fn sched_dequeue() -> int:
    g := g_global_runq_head
    if g >= 0:
        g_global_runq_head = r64(g, 48)  // g.next
        if g_global_runq_head < 0:
            g_global_runq_tail = -1
        w64(g, 48, -1)  // clear next
    return g

fn sched_yield():
    // Current goroutine yields
    m_idx := 0  // single M
    cur_g := r64(g_machines, m_idx * 32 + 8)

    // Re-enqueue current G
    if cur_g >= 0:
        w64(cur_g, 8, 0)  // _Grunnable
        sched_enqueue(cur_g)

    // Schedule next
    sched_schedule()

fn sched_schedule():
    m_idx := 0
    next_g := sched_dequeue()
    if next_g >= 0:
        old_g := r64(g_machines, m_idx * 32 + 8)
        w64(g_machines, m_idx * 32 + 8, next_g)
        w64(next_g, 8, 1)  // _Grunning

        if old_g >= 0:
            // Save old_g's sp, switch to next_g's sp
            old_sp_addr := old_g + 16  // &g.stack_ptr
            next_sp := r64(next_g, 16)  // g.stack_ptr
            fiber_switch(old_sp_addr, next_sp)
        // else: first goroutine, just start it
```

- [ ] **Step 3: Create chan.cr**

```core
// Channel: typed FIFO, goroutine-safe

fn chan_make(elemsize: int, cap: int) -> int:
    ch := alloc(56)
    buf := alloc(cap * elemsize)
    w64(ch, 0, buf)        // buf
    w64(ch, 8, cap)         // cap
    w64(ch, 16, 0)          // len
    w64(ch, 24, 0)          // head
    w64(ch, 32, elemsize)   // elemsize
    w64(ch, 40, -1)         // send_wait = empty
    w64(ch, 48, -1)         // recv_wait = empty
    w64(ch, 56, 0)          // closed = false
    return ch

fn chan_send(ch: int, val: int):
    // Copy val into channel buffer
    buf := r64(ch, 0)
    cap := r64(ch, 8)
    len := r64(ch, 16)
    head := r64(ch, 24)
    esize := r64(ch, 32)

    if len < cap:
        // Buffer has space
        tail := (head + len) % cap
        w64(buf, tail * esize, val)
        w64(ch, 16, len + 1)
    else:
        // Buffer full: block current goroutine
        // For now: simple blocking wait (yield + retry)
        // In full implementation: add to send_wait list
        loop:
            sched_yield()
            len := r64(ch, 16)
            if len < cap:
                continue
            tail := (head + len) % cap
            w64(buf, tail * esize, val)
            w64(ch, 16, len + 1)
            break

fn chan_recv(ch: int) -> int:
    buf := r64(ch, 0)
    cap := r64(ch, 8)
    len := r64(ch, 16)
    head := r64(ch, 24)
    esize := r64(ch, 32)

    if len > 0:
        val := r64(buf, head * esize)
        w64(ch, 24, (head + 1) % cap)
        w64(ch, 16, len - 1)
        return val

    // Buffer empty: block (yield + retry)
    loop:
        sched_yield()
        len := r64(ch, 16)
        if len > 0:
            head := r64(ch, 24)
            val := r64(buf, head * esize)
            w64(ch, 24, (head + 1) % cap)
            w64(ch, 16, len - 1)
            return val

fn chan_close(ch: int):
    w64(ch, 56, 1)  // closed = true
    // Wake up all waiting senders/receivers
    // ... (for now, just mark closed)
```

- [ ] **Step 4: Verify compilation**

```bash
python3 build_selfhost_native.py 2>&1 | tail -2
```

Expected: BUILD SUCCESS

- [ ] **Step 5: Commit**

```bash
jj commit -m "feat: goroutine/scheduler/channel stdlib modules"
```

---

### Task 3: IR Gen — go + yield + await

**Files:**
- Modify: `src/compiler/ir_gen.cr`

- [ ] **Step 1: Complete EXPR_GO IR gen**

The EXPR_GO handler exists but emits IR_CALL currently. Change to emit IR_SPAWN:

```core
if ast_kind(node) == EXPR_GO {
    // go f(args) → IR_SPAWN
    // Create channel for return value
    // Emit spawn with function, args, channel
    emit(IR_SPAWN, dest_chan, func_ni, first_arg, arg_count, -1);
    return dest_chan;
}
```

- [ ] **Step 2: Commit**

```bash
jj commit src/compiler/ir_gen.cr -m "feat: IR gen go/spawn + yield/await"
```

---

### Task 4: ELF Backend — IR_SPAWN + IR_YIELD

**Files:**
- Modify: `src/arch/linux/ld/instr.cr`
- Modify: `src/arch/linux/ld/sizes.cr`

- [ ] **Step 1: Add encoding for IR_SPAWN and IR_YIELD**

```core
if op == IR_SPAWN {
    // go f(args): call sched.go_new with fn and args
    // For now: just call the function directly (no parallel execution)
    // This makes it work as a normal call in single-threaded mode
    // Full parallel execution comes with M:N threading
    do2 := g2_slot(d);
    name_ni := s1;
    // Emit call to the function
    grow_call_patch(g_x86_call_patch_count + 1);
    w64(g_x86_call_patch_pos, g_x86_call_patch_count * 8, pos + cp);
    w64(g_x86_call_patch_name, g_x86_call_patch_count * 8, name_ni);
    g_x86_call_patch_count = g_x86_call_patch_count + 1;
    e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;
    cp = cp + e2_st(buf, pos+cp, 0, do2);
    return cp;
}

if op == IR_YIELD {
    // yield: call sched.sched_yield()
    // For now: no-op (0 bytes)
    // Full implementation: emit call to sched_yield
    return 0;
}
```

- [ ] **Step 2: Add size estimates**

```core
if op == IR_SPAWN { return 9; }   // call(5) + store(4)
if op == IR_YIELD { return 0; }   // no-op (for now)
```

- [ ] **Step 3: Commit**

```bash
jj commit -m "feat: ELF backend IR_SPAWN/IR_YIELD encoding"
```

---

### Task 5: Tests

**Files:**
- Create: `tests/suite/go_test.cr`
- Create: `tests/suite/chan_test.cr`

- [ ] **Step 1: Write go test**

```core
import io

fn test_go_basic() -> int:
    // Just verify go compiles
    go 42  // minimal go expression
    return 0

fn main() -> int:
    r1 := test_go_basic()
    if r1 != 0:
        print("FAIL: ")
        println(int_str(r1))
        return r1
    println("ALL PASS")
    return 0
```

- [ ] **Step 2: Write channel test**

```core
import io

fn test_chan_basic() -> int:
    ch := chan_make(8, 10)
    if ch < 0:
        return 1
    chan_send(ch, 42)
    val := chan_recv(ch)
    if val != 42:
        return 2
    return 0

fn main() -> int:
    r1 := test_chan_basic()
    if r1 != 0:
        print("FAIL: ")
        println(int_str(r1))
        return r1
    println("ALL PASS")
    return 0
```

- [ ] **Step 3: Verify**

```bash
./build/corec check tests/suite/go_test.cr
./build/corec check tests/suite/chan_test.cr
```

Expected: ok

- [ ] **Step 4: Commit**

```bash
jj commit -m "test: go + channel tests"
```
