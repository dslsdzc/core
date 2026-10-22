# 并发实现计划

> 受众：执行本计划的 agentic worker。必需子技能：`superpowers:subagent-driven-development`（推荐）或 `superpowers:executing-plans`，按任务逐项实施。进度以复选框（`- [ ]`）跟踪。

目标：实现 M:N 并发。`go f()` 在独立 arena 上创建 fiber，goroutine 之间通过 channel 传递值副本，在 channel 操作处协作式切换。

架构：rt.s 的 fiber_switch 汇编负责上下文切换。`sched.cr` 提供运行队列与调度器。`chan.cr` 提供 channel 收发。`goroutine.cr` 管理 go/fiber 生命周期。每个 goroutine 使用独立 arena。

技术栈：Core 运行期（rt.s）、Core stdlib（sched.cr、chan.cr、goroutine.cr）、IR gen、ELF 后端

## 全局约束

- goroutine 之间不共享内存，值通过 channel 复制传递
- 每个 goroutine 使用独立 arena（go 时 arena_new，退出时 arena_reset）
- 协作式调度，只在 channel 发送/接收处切换
- fiber 切换由 rt.s 汇编完成（保存/恢复寄存器与栈指针）
- 使用既有 opcode IR_SPAWN(27) 与 IR_YIELD(28)
- 版本控制使用 `jj`

---

### 任务 1：rt.s 的 fiber 切换汇编

涉及文件：
- 修改：`src/runtime/rt.s`

添加 fiber_switch 与 fiber_init 函数：

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

- [ ] 步骤 1：添加 fiber_switch 与 fiber_init

把这段汇编加到 rt.s 末尾（最后一个换行之前）。

- [ ] 步骤 2：校验汇编

```bash
as -o /tmp/rt.o src/runtime/rt.s
```

预期：无错误。

- [ ] 步骤 3：提交

```bash
jj commit -m "feat: fiber_switch/fiber_init asm for goroutine context switching"
```

---

### 任务 2：stdlib 的 goroutine、调度器与 channel

涉及文件：
- 创建：`src/stdlib/goroutine.cr`
- 创建：`src/stdlib/sched.cr`
- 创建：`src/stdlib/chan.cr`

- [ ] 步骤 1：创建 goroutine.cr

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

- [ ] 步骤 2：创建 sched.cr

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

- [ ] 步骤 3：创建 chan.cr

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

- [ ] 步骤 4：验证编译

```bash
python3 build_selfhost_native.py 2>&1 | tail -2
```

预期：BUILD SUCCESS

- [ ] 步骤 5：提交

```bash
jj commit -m "feat: goroutine/scheduler/channel stdlib modules"
```

---

### 任务 3：IR Gen 处理 go、yield 与 await

涉及文件：
- 修改：`src/compiler/ir_gen.cr`

- [ ] 步骤 1：完成 EXPR_GO 的 IR 生成

EXPR_GO 的处理已存在，但目前发射 IR_CALL。改为发射 IR_SPAWN：

```core
if ast_kind(node) == EXPR_GO {
    // go f(args) becomes IR_SPAWN
    // Create channel for return value
    // Emit spawn with function, args, channel
    emit(IR_SPAWN, dest_chan, func_ni, first_arg, arg_count, -1);
    return dest_chan;
}
```

- [ ] 步骤 2：提交

```bash
jj commit src/compiler/ir_gen.cr -m "feat: IR gen go/spawn + yield/await"
```

---

### 任务 4：ELF 后端的 IR_SPAWN 与 IR_YIELD

涉及文件：
- 修改：`src/arch/linux/ld/instr.cr`
- 修改：`src/arch/linux/ld/sizes.cr`

- [ ] 步骤 1：添加 IR_SPAWN 与 IR_YIELD 的编码

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

- [ ] 步骤 2：添加尺寸估算

```core
if op == IR_SPAWN { return 9; }   // call(5) + store(4)
if op == IR_YIELD { return 0; }   // no-op (for now)
```

- [ ] 步骤 3：提交

```bash
jj commit -m "feat: ELF backend IR_SPAWN/IR_YIELD encoding"
```

---

### 任务 5：测试

涉及文件：
- 创建：`tests/suite/go_test.cr`
- 创建：`tests/suite/chan_test.cr`

- [ ] 步骤 1：编写 go 测试

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

- [ ] 步骤 2：编写 channel 测试

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

- [ ] 步骤 3：验证

```bash
./build/corec check tests/suite/go_test.cr
./build/corec check tests/suite/chan_test.cr
```

预期：ok

- [ ] 步骤 4：提交

```bash
jj commit -m "test: go + channel tests"
```
