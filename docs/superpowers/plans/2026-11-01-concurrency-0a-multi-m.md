# Core 并发 0A：多 M 基础 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Core 的 `go`/channel 在 2～4 个 M（OS 线程）上正确运行，先建立线程本地运行时状态、运行时内部锁、全局 run queue 和安全的 G 生命周期。

**Architecture:** 用 `%fs` TLS 保存每个线程的 current G、M index、current arena 和运行时锁递归深度；用一个可重入运行时锁保护 scheduler/queue、channel 和 arena 元数据；run queue 先用单个全局 FIFO（正确性优先），G 退出后延迟回收其 arena，避免在自己的栈上 reset 自己所在的 arena。

**Tech Stack:** Core stdlib（`src/stdlib/{sched,chan,goroutine,arena}.cr`）、x86-64 ELF 后端（`src/format/elf/`、`src/os/linux/entry.cr`、`src/arch/x86_64/`）、rt.s、Python bootstrap、jj。

**Spec:** `docs/superpowers/specs/2026-09-17-concurrency-model-design.md` §11.1 步 0a；事实依据 `docs/superpowers/implementation/2026-09-17-concurrency-model-evidence.md` §15。

## Global Constraints

- 0A 只做“多 M 正确”，**不**做 Transfer Analysis、不实现 MOVE/LOAN/SPLIT/FILL/COPY、不实现预算/证书，不声称实现 2026-09-17 模型。
- 源语言不新增 lock/mutex/atomic/ownership 语法；本计划的锁是**运行时内部同步**，不是用户可见锁。
- 默认仍保持 share-nothing 的设计方向；本阶段不新增跨 G 共享 API，也不把 `channel` 以外的共享对象合法化。
- SPSC 仍是约定，不是强制（`TODO #2026-09-18-1`）；本阶段用运行时锁保证多 M 下 channel 不崩，但不承诺多生产者/多消费者语义。
- 不改 `.ccr` 的 transfer/sync 决策面；本阶段不新增 `.ccr` 段，不把锁写进 IR。
- 版本控制只用 `jj`，不用 `git`。
- 任何长编译/长测试用 `nice -n 19`（必要时 `cpulimit -l 10`），遵守 CLAUDE.md 硬性规则 #6。
- 当前分支必须基于 `feature/region-v2`；`develop` 缺少 per-G arena 绑定和 raw current-arena builtins，不能作为 0A 基线。

## Review Focus

这些是规格没有逐条写、但 0A 最容易出错的输入/条件；对应测试放在括号中的任务里。

- 运行时锁在 `alloc` 递归路径上重入（arena grow 内再调用 `alloc`）——不能死锁（Task 2）。
- 锁跨 `fiber_switch`/`sched_yield` 持有——会永久阻塞另一个 M（Task 5 ping-pong）。
- worker 第一次从空 `cur_g` 启动 G——不能只 dequeue 不启动（Task 5 2M spawn）。
- G 退出时在自己栈上 reset 自己的 arena——不能 use-after-free（Task 5 1000 次 spawn）。
- worker 的 TLS 未在第一次 `alloc` 前建立——会 segfault（Task 1）。
- main G 被 worker 抢走执行——main 的栈会被两个线程同时使用（Task 5 main pinned 测试）。
- channel 唤醒跨 M：唤醒者把 G 放回自己的本地队列——被唤醒的 M 永远看不到（Task 5 ping-pong）。
- worker 栈/TLS 未按 16 字节对齐——进入 Core 函数时 SSE/ABI 崩溃（Task 5 4M 测试）。

---

## Task 0: 建立隔离工作区与基线

**Files:** 无源码改动。

**Interfaces:**
- Consumes: `feature/region-v2` 的当前树。
- Produces: `feature/concurrency-0a` 工作区，基线全绿。

- [ ] **Step 1: 确认工作区与分支**

Run:

```bash
jj status
jj log -r '@-' --no-graph -T 'commit_id.short() ++ " " ++ description.first_line() ++ "\n"'
```

Expected: 工作区干净；`@-` 是 `regionplan: copy-on-write for share writes`。

- [ ] **Step 2: 构建基线**

Run:

```bash
nice -n 19 python3 build_selfhost_native.py
```

Expected: 产出 `build/corec`、`build/corearch`、`build/corelsp`，末尾 `BUILD SUCCESS`（或脚本的等价成功行）。

- [ ] **Step 3: 跑并发基线**

Run:

```bash
nice -n 19 python3 tests/selfhost/test_chan_handle_model.py
nice -n 19 python3 tests/selfhost/test_go_arena.py
```

Expected: 前者 `11/11 通过`；后者 `PASS go arena per-G context switch`。

- [ ] **Step 4: 提交空分支声明**

```bash
jj commit -m "chore: start concurrency 0A (multi-M foundation)"
```

---

## Task 1: TLS 运行时状态与 ABI 原语

**Files:**
- Modify: `src/runtime/rt.s`
- Modify: `src/runtime/rt.cr`
- Modify: `src/os/linux/entry.cr`
- Modify: `src/arch/x86_64/sizes.cr`
- Modify: `src/format/elf/elf.cr`
- Modify: `src/compiler/ir_gen.cr`（`ir_gen_globals` 注册 `g_rt_lock_owner`）
- Modify: `src/runtime/runtime_frontend_abi.cr`
- Modify: `src/compiler/ccr_io.cr`
- Modify: `bootstrap/corec/frontend/name_resolver.py`
- Modify: `bootstrap/corec/frontend/type_checker.py`
- Test: `tests/selfhost/test_rt_tls.py`（新建）

**Interfaces:**
- Consumes: 无。
- Produces:
  - TLS 布局（32 bytes，`%fs` 基址）：`+0 current_g`、`+8 m_idx`、`+16 current_arena`、`+24 lock_depth`。
  - `rt_m_idx() -> int`
  - `rt_current_arena() -> int`
  - `rt_set_current_arena(v: int)`
  - `rt_lock_acquire()`
  - `rt_lock_release()`
  - `g_rt_lock_owner : int, mut = 0`（BSS 锁字；全局，不是 TLS）
  - `g_set_curg(ptr: int)` / `g_get_curg() -> int` 改为读写 `%fs:0`。
  - `sched_current_m_idx()` 改为返回 `rt_m_idx()`。

- [ ] **Step 1: 写失败测试**

新建 `tests/selfhost/test_rt_tls.py`，内容为一个 Python 驱动；核心源码断言：

```core
import arena

fn main() -> int:
    if rt_m_idx() != 0:
        return 1
    rt_lock_acquire()
    rt_lock_acquire()
    rt_lock_release()
    rt_lock_release()
    a := arena_new_sized(65536)
    if arena_current_unchecked() != a:
        return 2
    arena_reset(a)
    return 0
```

驱动用 `build/corec ccr` + `build/corearch --raw-int --elf` 构建，`subprocess.run(..., timeout=60)` 运行，断言 rc=0。测试同时覆盖“第一次 `alloc` 前 TLS 已建立”：`arena_new_sized` 会经过 allocator。

- [ ] **Step 2: 运行测试，确认失败**

Run:

```bash
nice -n 19 python3 tests/selfhost/test_rt_tls.py
```

Expected: `ccr` 阶段失败，`Undefined function 'rt_m_idx'`（或同类未定义）。

- [ ] **Step 3: 在 `rt.s` 中建立 main TLS**

在 `.bss` 加 32 字节 `main_tls`。`_start` 在保存 argc/argv 之后、任何 `alloc`/`main` 之前执行：

```asm
lea rsi, [rip + main_tls]
mov edi, 0x1002          # ARCH_SET_FS
mov eax, 158             # arch_prctl
syscall
mov rax, -1
mov qword ptr fs:[0], rax    # current_g = -1
xor eax, eax
mov qword ptr fs:[8], rax    # m_idx = 0
mov rax, -1
mov qword ptr fs:[16], rax   # current_arena = -1
xor eax, eax
mov qword ptr fs:[24], rax   # lock_depth = 0
```

把 `g_set_curg`/`g_get_curg` 改成 `mov fs:[0], rdi` / `mov rax, fs:[0]`。

- [ ] **Step 4: 在 ELF 后端 `_start` 建立 main TLS**

`src/os/linux/entry.cr::emit_start` 在 argc/argv 保存之后、`g_current_arena` 初始化之前，发同一段 TLS 初始化。TLS 块放在 BSS 末尾：

- 在 `elf.cr` 的 `globals_size` 计算后加 32 字节，并记录 `g_rt_tls_va = bss_va + 16 + globals_size - 32`。
- `emit_start` 记录 `lea rsi, [rip+disp32]` 的 disp32 位置到新全局 `g_start_tls_patch_pos`；`elf_gen` 在最终 `bss_va` 确定后调用 `w32(buf, g_start_tls_patch_pos, g_rt_tls_va - (TEXT_BASE + g_start_tls_patch_pos + 4))`。
- `src/arch/x86_64/sizes.cr::sz_start_body` 加 TLS 初始化字节数；新增 `sz_start_tls_init()`，`emit_start_size` 同步加。

- [ ] **Step 5: 发 TLS 原语 stub（ELF）**

在 `elf.cr` 新增 `emit_rt_tls_stubs(buf, pos) -> int`，每项 11 字节（不足补 `nop`），并注册到 `func_offsets`：

- `rt_m_idx`：`mov rax, fs:[8]; ret`
- `rt_current_arena`：`mov rax, fs:[16]; ret`
- `rt_set_current_arena`：`mov fs:[16], rdi; ret`
- `rt_lock_acquire`：读 `fs:[8]` 得到 m_idx，token=m_idx+1；`lock cmpxchg` 争用 `g_rt_lock_owner`；owner==token 时 `inc qword fs:[24]`；否则 `pause` 重试。
- `rt_lock_release`：`dec qword fs:[24]`；归零时把 `g_rt_lock_owner` 写成 0。

新增 BSS 全局 `g_rt_lock_owner : int, mut = 0`：

- 在 `src/compiler/ir_gen.cr::ir_gen_globals` 的运行时全局段加 `reg_one_global(str_intern("g_rt_lock_owner"))`，保证**每个程序**都有 BSS 槽（不依赖程序是否 import sched/rt.cr）。
- 在 `src/runtime/rt.cr` 加声明，供源码/文档引用。
- `rt_lock_acquire`/`release` 用 `lea r10, [rip+0]` 或 `mov [rip+0]` 占位，并按 `grow_rip_patch(..., g_rt_lock_owner 的全局 var id)` 登记，交给现有 rip patch 通道填 BSS 地址；不要手写死地址。
- `rt.s` 里用**不同**的本地符号（例如 `rt_lock_owner`），避免动态链接时与 Core 的 `g_rt_lock_owner` 重复定义。

Phase 2 的 `total_code` 必须逐项加这些 stub 的精确大小；Phase 3 用同一常量发射（参考 `emit_curg_stubs` 的 11 字节成对写法）。

- [ ] **Step 6: 在 `rt.s` 提供同名符号**

`rt.s` 加：

```asm
rt_m_idx:            mov rax, qword ptr fs:[8]; ret
rt_current_arena:    mov rax, qword ptr fs:[16]; ret
rt_set_current_arena: mov qword ptr fs:[16], rdi; ret
rt_lock_acquire:     # 与 Step 5 同语义
rt_lock_release:     # 与 Step 5 同语义
```

`rt_lock_owner`（注意不是 `g_rt_lock_owner`）在 rt.s 的 `.data` 里 `.quad 0`。用于 bootstrapped 二进制（corearch 自身）和动态链接路径；与 ELF 静态路径的 Core BSS 槽分开命名，避免重复符号。

- [ ] **Step 7: 注册 ABI 名称**

- `src/runtime/runtime_frontend_abi.cr`：`prelude_builtin_add` 加 5 个名字，返回型 `TI_INT` / `TI_UNIT`。
- `src/compiler/ccr_io.cr::ccr_raw_abi_builtin`：把 5 个名字加入 SYSTEM 名单。
- `bootstrap/corec/frontend/name_resolver.py::_declare_builtins`：加 5 个名字。
- `bootstrap/corec/frontend/type_checker.py` 的 `rt_funcs` 集合：加 5 个名字。

- [ ] **Step 8: 运行测试**

Run:

```bash
nice -n 19 python3 tests/selfhost/test_rt_tls.py
nice -n 19 python3 tests/selfhost/test_go_arena.py
nice -n 19 python3 tests/selfhost/test_chan_handle_model.py
```

Expected: 三个都 rc=0；新测试输出 `PASS rt tls`。

- [ ] **Step 9: 提交**

```bash
jj commit -m "runtime: per-thread TLS state and runtime lock primitives (0A)"
```

---

## Task 2: per-thread current arena 与 allocator 内部锁

**Files:**
- Modify: `src/runtime/alloc_body.cr`
- Modify: `src/runtime/alloc_blob.cr`（生成物）
- Modify: `tools/gen_alloc_blob.py`
- Modify: `src/stdlib/arena.cr`
- Modify: `src/compiler/ir_gen.cr`
- Modify: `src/format/elf/elf.cr`
- Test: 复用 `tests/selfhost/test_rt_tls.py`、`test_go_arena.py`，并加一个 arena grow 用例。

**Interfaces:**
- Consumes: Task 1 的 `rt_current_arena` / `rt_set_current_arena` / `rt_lock_*`。
- Produces:
  - `arena_current_unchecked()` 读 TLS；`arena_set_current_unchecked(v)` 写 TLS。
  - `alloc_blob` 的 `alloc_arena` 用 `rt_current_arena()` 取当前 arena，不再读 `g_arena_scalars[0]`。
  - `alloc` 入口在 blob trampoline 上 acquire/release 可重入运行时锁。

- [ ] **Step 1: 写失败测试**

在 `tests/selfhost/test_rt_tls.py` 增加第二个 Core 源码用例：

```core
import arena

fn main() -> int:
    a := arena_new_sized(131072)
    p := alloc(200000)
    if p < 0:
        return 1
    if arena_current_unchecked() != a:
        return 2
    arena_reset(a)
    return 0
```

Expected: 当前实现能过；但实现改为 TLS 后必须继续过。真正的 RED 来自 Task 1 的 `rt_current_arena` 未实现；本任务先把该用例登记为回归。

- [ ] **Step 2: 改 `alloc_body.cr`**

把 `alloc_arena` 里的：

```core
ai := cell_load(g_arena_scalars, 0)
```

改成：

```core
ai := rt_current_arena()
```

`tools/gen_alloc_blob.py` 的 `EXTERNAL_CALLS` 加 `"rt_current_arena"`；重生成：

```bash
nice -n 19 python3 tools/gen_alloc_blob.py
```

Expected: `src/runtime/alloc_blob.cr` 更新，`alloc_arena` 的 relocation 表含 `rt_current_arena`。`elf.cr::patch_alloc_blob_calls` 对非 `heap_expand` 的名字走 `find_alloc_blob_func`，因此只要 Task 1 已把 `rt_current_arena` 注册进 `g_x86_func_offsets`，这里无需新增特判；构建时若报 `alloc blob: unresolved call rt_current_arena`，说明 stub 注册顺序在 patch 之后，必须调整。

- [ ] **Step 3: 改 `arena.cr`**

- `arena_set_current(val)`：改为 `rt_set_current_arena(val)`，保留 `g_current_arena = val` 的兼容写（不作为运行时权威）。
- `arena_current_unchecked()`：改为 `return rt_current_arena()`。
- `arena_set_current_unchecked(v)`：调用 `arena_set_current(v)`。
- `arena_init`、`_grow_arena_meta`、`arena_grow_pool`、`arena_new_sized`、`arena_reset`、`arena_clear` 的入口/出口加 `rt_lock_acquire()` / `rt_lock_release()`。锁是可重入的，因此 `arena_reset` 内再调 `arena_reset`/`alloc` 不会死锁。
- `arena_new_sized` 和 `_grow_arena_meta` 里的 `arena_scalar_get(0)` 全部改成 `rt_current_arena()`。
- `arena_reset` 恢复 parent 时仍用 `arena_set_current(parent)`；调用方若在别的 G 上下文回收，必须自己保存/恢复 current（Task 5 的 `sched_reap_dead` 会做）。

- [ ] **Step 4: 改 `ir_gen.cr` 的 raw current-arena lowering**

`arena_current_unchecked` 的拦截分支从 `cell_load(g_arena_scalars, 0)` 改为发 `IR_CALL rt_current_arena()`。
`arena_set_current_unchecked` 的拦截分支从 `cell_store(...)` 改为发 `IR_CALL rt_set_current_arena(arg)`，再保留 `IR_STORE g_current_arena, arg` 的兼容写。
两处仍必须返回 `TI_INT` / `TI_UNIT`，不得让普通函数调用先建函数 arena。

- [ ] **Step 5: 给 alloc blob trampoline 包锁**

`src/format/elf/elf.cr::emit_alloc_blob_body` 当前是 `mov rsi...; mov rdx...; jmp body`。改成：

```text
push rbx
push rdi
push rsi
push rdx
sub rsp, 8
call rt_lock_acquire
add rsp, 8
pop rdx
pop rsi
pop rdi
call body
mov rbx, rax
call rt_lock_release
mov rax, rbx
pop rbx
ret
```

用与 `emit_curg_stubs` 相同的 `w8`/`e2_*` 手工字节写法；调用点用 `g_x86_call_patch_*` 记录 `rt_lock_acquire` / `rt_lock_release` / body。检查 SysV 16 字节对齐：trampoline 入口 `rsp % 16 == 8`，按上面的 push 数在每次 `call` 前保持 `rsp % 16 == 0`。
Phase 2 的 `total_code` 从 `16 + ALLOC_BLOB_SIZE` 改为 `16 + ALLOC_TRAMPOLINE_SIZE + ALLOC_BLOB_SIZE`；Phase 3 用同一常量。

- [ ] **Step 6: 运行测试**

Run:

```bash
nice -n 19 python3 tests/selfhost/test_rt_tls.py
nice -n 19 python3 tests/selfhost/test_go_arena.py
nice -n 19 python3 tests/selfhost/test_chan_handle_model.py
```

Expected: 全 PASS。若 `test_go_arena` 失败，先查 `arena_current_unchecked` 是否仍走旧全局。

- [ ] **Step 7: 提交**

```bash
jj commit -m "arena: per-thread current arena and allocator runtime lock (0A)"
```

---

## Task 3: scheduler 全局 run queue、延迟 G 回收、单 M 回归

**Files:**
- Modify: `src/stdlib/sched.cr`
- Modify: `src/stdlib/goroutine.cr`
- Test: `tests/selfhost/test_chan_handle_model.py`、`tests/selfhost/test_go_arena.py`、`tests/suite/conc_test.cr`。

**Interfaces:**
- Consumes: Task 1 的 `rt_m_idx`、Task 2 的 arena 锁。
- Produces:
  - `sched_init_n(n: int)`、`sched_init()`（= `sched_init_n(1)`）
  - `sched_spawn_workers(n: int)` 改为 `pub`
  - `sched_enqueue(g: string)`、`sched_dequeue() -> int`（去掉 m_idx 参数）
  - 全局 `g_runq_head` / `g_runq_tail`
  - G 退出延迟回收：`g_dead_head` / `g_dead_tail` + `sched_reap_dead(cur_g)`
  - M 结构 32 字节：`id(0)`、`cur_g(8)`、`sched_sp(16)`、`pad(24)`

- [ ] **Step 1: 写/改测试**

先不改多 M 测试；用现有单 M 套件固定行为：

```bash
nice -n 19 python3 tests/selfhost/test_chan_handle_model.py
nice -n 19 python3 tests/selfhost/test_go_arena.py
```

Expected: 当前全绿。refactor 后必须仍全绿。

- [ ] **Step 2: 把 run queue 改成全局 FIFO**

`sched.cr` 加：

```core
g_runq_head : int, mut = -1
g_runq_tail : int, mut = -1
```

`sched_enqueue(g)`：acquire 锁；把 `g.next` 置 -1；空队则 head/tail=g，否则 tail.next=g、tail=g；release。
`sched_dequeue()`：acquire；取 head；head=next；空则 tail=-1；清 `g.next`；release；返回 g。
所有 `sched_dequeue(m_idx)` 调用点改为 `sched_dequeue()`。

- [ ] **Step 3: 加 `sched_init_n` 与 M 数组**

```core
fn sched_init_n(n: int), pub:
    rt_lock_acquire()
    if g_sched_inited != 0:
        rt_lock_release()
        return
    if n < 1:
        n = 1
    arena_init(g_arena_pool_limit, 1048576)
    m := alloc(n * 32)
    # 逐槽写 id/cur_g/sched_sp
    ...
    main_g := alloc(88)
    # 与当前 main G 字段一致，offset 80 = -1
    ...
    g_machines = m
    g_machine_count = n
    g_num_workers = n - 1
    g_runq_head = -1
    g_runq_tail = -1
    g_dead_head = -1
    g_dead_tail = -1
    g_main_g = main_g
    g_main_ready = 0
    cell_store(m, 8, main_g)
    g_set_curg(main_g)
    g_sched_inited = 1
    rt_lock_release()
    if n > 1:
        sched_spawn_workers(n)
```

`g_main_g : int, mut = -1`、`g_main_ready : int, mut = 0`。
`sched_init()` 改为 `sched_init_n(1)`。
`sched_spawn_workers(n)` 只做 `g_num_workers = n - 1` + `m_start_workers(n)`，**不再**重新分配 `g_machines`（当前实现会覆盖 M0 和 main G，必须删掉）。

- [ ] **Step 4: main G 固定到 M0**

`sched_enqueue(g)` 若 `g == g_main_g`：acquire 锁，`g_main_ready = 1`，release，不进入全局 runq。
`sched_dequeue()` 永远不返回 `g_main_g`。
`sched_schedule()` 的 main 分支：若 `g_main_ready != 0` 且 `old_g == g_main_g`，在运行时锁内清 0 并返回；若 `old_g != g_main_g`，在运行时锁内把 `g_main_ready` 清 0、`next_g = g_main_g` 并切换。
`g_main_ready` 的读取/清除和 `sched_enqueue(main_g)` 的写入都必须用同一把运行时锁保护；不要裸读。
这样 worker 永远不会拿到 main G 的栈。

- [ ] **Step 5: 延迟回收 G arena**

`goroutine.cr::g_free` 改为：

```core
rt_lock_acquire()
cell_store(g, 8, 3)
cell_store(g, 48, -1)
# append to g_dead list
...
rt_lock_release()
```

不再在 `g_free` 里 `arena_reset`。

`sched.cr` 加：

```core
fn sched_reap_dead(cur_g: int):
    rt_lock_acquire()
    loop:
        g := g_dead_head
        if g < 0:
            break
        if g == cur_g:
            break
        g_dead_head = cell_load(g, 48)
        if g_dead_head < 0:
            g_dead_tail = -1
        aid := cell_load(g, 32)
        saved := rt_current_arena()
        arena_reset(aid)
        rt_set_current_arena(saved)
    rt_lock_release()
```

`sched_schedule()` 入口和 `sched_worker_run` 循环入口调用 `sched_reap_dead(cur_g)`。`cur_g` 用 `-1` 表示当前在调度器栈上。

- [ ] **Step 6: 单 M 回归**

Run:

```bash
nice -n 19 python3 tests/selfhost/test_chan_handle_model.py
nice -n 19 python3 tests/selfhost/test_go_arena.py
nice -n 19 ./build/corec check tests/suite/conc_test.cr
```

Expected: 前两个 PASS；`check` rc=0。若单 M 回归红，先不要继续 Task 4/5。

- [ ] **Step 7: 提交**

```bash
jj commit -m "sched: global run queue, main-G pinning, deferred G reclamation (0A)"
```

---

## Task 4: channel 运行时内部锁

**Files:**
- Modify: `src/stdlib/chan.cr`
- Test: 现有 `test_chan_handle_model.py`、`conc_test`、`chan_test`。

**Interfaces:**
- Consumes: Task 1 的 `rt_lock_acquire` / `rt_lock_release`。
- Produces: `chan_send` / `chan_recv` / `chan_close` / `chan_make` 的临界区；锁**不跨** `sched_yield`。

- [ ] **Step 1: 写并发负例（先不改 chan）**

在 `tests/selfhost/test_multi_m.py`（Task 5 新建）先放一个最小用例：

```core
import sched
import chan

fn main() -> int:
    sched_init_n(2)
    ch := chan_make(8, 1)
    chan_send(ch, 7)
    if chan_recv(ch) != 7:
        return 1
    return 0
```

Expected before implementation: 能过（单线程），所以这个用例只锁行为；真正的 RED 是 Task 5 的多 M 用例。本任务用现有单 M 套件做回归。

- [ ] **Step 2: 给 channel 状态加锁**

- `chan_make`：`_chan_ensure_init()` 之后 acquire；初始化字段；release。
- `chan_send`：`_chan_ensure_init()`；acquire；读 buf/cap/len/head/esize；直接 handoff 时写 waiter temp_val、置 runnable、`sched_enqueue`（锁可重入）、移除等待者；release；return。缓冲路径同样在 release 后 return。
- 缓冲满路径：acquire 下把当前 G 入 send_wait、置 `_Gwaiting`；**release**；`sched_yield()`；return。
- `chan_recv`：acquire；直接 handoff / 缓冲读取；release 后 return。空且未关闭：acquire 下入 recv_wait、置 waiting；release；`sched_yield()`；醒来后读 `g.temp_val`；return。
- `chan_close`：acquire；置 closed、唤醒所有等待者、清链；release；return。

规则：**任何 `sched_yield` 之前必须 release**；任何 `sched_enqueue` 可以嵌套 acquire（锁可重入）。

- [ ] **Step 3: 回归**

Run:

```bash
nice -n 19 python3 tests/selfhost/test_chan_handle_model.py
nice -n 19 python3 tests/selfhost/test_go_arena.py
```

Expected: 全 PASS。

- [ ] **Step 4: 提交**

```bash
jj commit -m "chan: runtime-internal critical sections, never held across yield (0A)"
```

---

## Task 5: 启用多 M、worker 启动/恢复、跨 M 唤醒与压力测试

**Files:**
- Modify: `src/stdlib/sched.cr`
- Modify: `src/format/elf/elf.cr`
- Modify: `src/runtime/rt.s`
- Create: `tests/selfhost/test_multi_m.py`
- Modify: `src/ci/run.sh`

**Interfaces:**
- Consumes: Task 1～4。
- Produces:
  - `sched_init_n(n)` 真正启动 n-1 个 worker。
  - worker 首次启动 G：`fiber_switch(&M.sched_sp, G.sp)`。
  - worker 无可运行 G：`fiber_switch(&G.sp, M.sched_sp)` 回到 scheduler 栈。
  - `m_start_workers` 修正 double-inc、CLONE_SETTLS、16 字节栈对齐。

- [ ] **Step 1: 写失败测试**

新建 `tests/selfhost/test_multi_m.py`，用 `build/corec ccr` + `build/corearch --raw-int --elf` 构建，`subprocess.run(timeout=60)` 运行；至少 4 个 Core 用例：

1. `two_workers_two_goroutines`：

```core
import sched
import chan

fn work(n: int) -> int:
    return n + 1

fn main() -> int:
    sched_init_n(2)
    c1 := go work(1)
    c2 := go work(2)
    r1 := chan_recv(c1)
    r2 := chan_recv(c2)
    if r1 != 2:
        return 1
    if r2 != 3:
        return 2
    return 0
```

2. `four_workers_queue`：`sched_init_n(4)`，spawn 64 个 `work(i)`，把 handle 存进 `alloc(64 * 8)` 的原始缓冲区，使用 `store_str_ptr(buf, i * 8, ch)` / `load_str_ptr(buf, i * 8)`（不要用 `cell_store`/`cell_load` 存 handle，那会把 `string` 当 `int`，触发类型面冲突），逐个 `chan_recv`，校验和。

3. `cross_m_pingpong`：`sched_init_n(2)`；全局 `g_in`、`g_out` 两个 channel；spawn 一个 `ping`（从 `g_in` recv，向 `g_out` send）；main 向 `g_in` send 0，从 `g_out` recv 1；验证跨 M 唤醒和等待链。

4. `spawn_stress`：`sched_init_n(2)`；循环 1000 次 `ch := go work(i); r := chan_recv(ch); sum += r;`，验证延迟回收、arena 不爆、无崩溃（`timeout=120`）。

Expected before implementation: 用例 1 编译失败 `Undefined function 'sched_init_n'`；或修复编译后 hang（timeout）。这就是 RED。

- [ ] **Step 2: 修 `m_start_workers`**

`src/format/elf/elf.cr::emit_m_start_workers` 与 `src/runtime/rt.s::m_start_workers` 同步：

- 删掉 `.Lworker_loop`/`.Lnext_worker` 的双重 `inc r12`；只保留一处递增。
- clone flags 改为 `0x10F00 | 0x80000`（`CLONE_SETTLS`）。
- 每个 worker 先 `alloc(32)` 得到 TLS block；写 `[block+0] = -1`、`[block+8] = m_idx`、`[block+16] = -1`、`[block+24] = 0`；把 block 放进 `r10`（clone 的 child_tls）。
- worker 栈顶按 16 字节对齐：`r15 = (alloc_base + 65536) & ~15`；`[r15-16]=worker_entry`、`[r15-8]=index`。
- `worker_entry` 用 `pop rdi` 拿 index；调用 `sched_worker_run`。

- [ ] **Step 3: 修 worker loop**

`sched.cr::sched_worker_run(m_idx)`：

```core
loop:
    sched_reap_dead(-1)
    next_g := sched_dequeue()
    if next_g >= 0:
        m := g_machines + m_idx * 32
        cell_store(m, 8, next_g)
        g_set_curg(next_g)
        cell_store(next_g, 8, 1)
        next_cur := cell_load(next_g, 80)
        if next_cur < 0:
            next_cur = cell_load(next_g, 32)
        arena_set_current_unchecked(next_cur)
        # 首次启动：把 scheduler 上下文保存到 M.sched_sp，再进入 G
        fiber_switch(@ptr_add(m, 16), cell_load(next_g, 16))
        # 从 scheduler 切回来时，G 已 yield/退出；sched_schedule 已把 cur_g 置 -1
        g_set_curg(-1)
```

- [ ] **Step 4: 修 `sched_schedule` 的 worker 无工作路径**

`sched_schedule`：

```core
m_idx := sched_current_m_idx()
old_g := sched_get_curg()
sched_reap_dead(old_g)

loop:
    rt_lock_acquire()
    main_ready := g_main_ready
    rt_lock_release()
    if m_idx == 0 && old_g == g_main_g && main_ready != 0:
        rt_lock_acquire()
        g_main_ready = 0
        rt_lock_release()
        return
    next_g := sched_dequeue()
    if next_g >= 0:
        if next_g == old_g:
            return
        break
    if m_idx == 0:
        # main M: spin until main G ready or another G appears
        continue
    # worker M: park on scheduler stack
    m := g_machines + m_idx * 32
    if old_g >= 0:
        cell_store(old_g, 80, arena_current_unchecked())
        cell_store(m, 8, -1)
        g_set_curg(-1)
        fiber_switch(@ptr_add(old_g, 16), cell_load(m, 16))
        # 被重新调度时返回这里；G 已被 waker 置 runnable
        return
```

然后按现有逻辑设置 `m.cur_g`、`g_set_curg`、状态、arena，再 `fiber_switch`。注意：`sched_dequeue()` 已在全局锁内；不要在持锁时 `fiber_switch`。

- [ ] **Step 5: 运行多 M 测试**

Run:

```bash
nice -n 19 python3 tests/selfhost/test_multi_m.py
```

Expected: 4/4 PASS；1000 次 spawn 用例不超时、不崩溃。

- [ ] **Step 6: 回归全套并发**

Run:

```bash
nice -n 19 python3 tests/selfhost/test_chan_handle_model.py
nice -n 19 python3 tests/selfhost/test_go_arena.py
nice -n 19 python3 tests/selfhost/test_multi_m.py
```

Expected: 全 PASS。

- [ ] **Step 7: 接入 CI**

`src/ci/run.sh` 的 `selfhost-tests` 段加：

```bash
python3 tests/selfhost/test_multi_m.py   # 并发 0A：2/4 M 下 go/chan + 延迟回收
```

`tests/harness/test_ci_hook_coverage.py` 会自动检查接入；如果它要求 allowlist，按现有格式登记理由。

- [ ] **Step 8: 提交**

```bash
jj commit -m "sched: enable multi-M workers, cross-M wake, and stress tests (0A)"
```

---

## Task 6: 文档、TODO、canary 与完整验证

**Files:**
- Modify: `src/stdlib/sched.cr`（头注）
- Modify: `docs/maintainer/design/execution-model.md`
- Modify: `TODO.md`
- Create: `docs/superpowers/implementation/2026-11-01-concurrency-0a.md`
- Maybe modify: `tools/baseline/canary_values.tsv`（只有确认原因后才更新）

**Interfaces:**
- Consumes: Task 1～5 的代码与测试结果。
- Produces: 0A 的可追溯证据；明确“0A ≠ 新并发模型”的边界。

- [ ] **Step 1: 改 `sched.cr` 头注**

删掉“Channels are single-producer/single-consumer edges, so the runtime needs no locks”和“For now: single-threaded”的陈述，改成：

```text
0A: multi-M is enabled via sched_init_n(n). Runtime-internal state
(scheduler queues, channel wait lists, arena metadata) is protected by a
single reentrant runtime lock. Per-M queues, work stealing, and lock-free
wait lists remain 0C work. SPSC is still a convention, not enforced.
```

- [ ] **Step 2: 更新执行模型文档**

`docs/maintainer/design/execution-model.md` 的“实现状态”加：

- `sched_init_n(n)` 可启动 n-1 个 worker；
- 0A 用全局 run queue + 运行时内部锁；
- main G 固定 M0；
- G 退出延迟回收；
- 源码/IR 仍无锁语法，默认仍不生成用户数据锁。

- [ ] **Step 3: 更新 TODO**

`TODO.md` 的 `#2026-07-31-1` 追加状态：

- 多 M 已接线（`sched_init_n`）；
- 全局 runq + 运行时内部锁；
- 待办移交 0C：per-M runq/work stealing、wait list 无锁化、SPSC 强制/文档化。

不要删除历史文字；只追加“2026-11-01 状态”。

- [ ] **Step 4: 写实现报告**

新建 `docs/superpowers/implementation/2026-11-01-concurrency-0a.md`，至少包含：

- 改动的文件与接口；
- 4 个多 M 测试的实际输出；
- 单 M 并发套件回归；
- 明确未做项：Transfer Analysis、typed message、per-M queue、lock-free、SPSC 强制、预算/证书；
- 已知限制：全局锁串行化、worker busy-spin、channel 仍是 8 字节。

- [ ] **Step 5: 跑完整验证**

Run:

```bash
nice -n 19 CI_JOB_NAME=selfhost-tests src/ci/run.sh
nice -n 19 CI_JOB_NAME=bootstrap-tests src/ci/run.sh
nice -n 19 CI_JOB_NAME=check src/ci/run.sh
```

Expected: 三个 job rc=0。若 `selfhost-tests` 因新增测试文件未接入而失败，先修 `run.sh` 接入点。

- [ ] **Step 6: 跑自举链**

Run:

```bash
nice -n 19 CI_JOB_NAME=full-bootstrap src/ci/run.sh
```

Expected: `corec2 == corec3` IDENTICAL，N06=0。若失败，先查新增 runtime 符号是否在 bootstrap 清单/rt.s 中缺失。

- [ ] **Step 7: 跑 canary 并判断是否更新**

Run:

```bash
bash tools/baseline/canary_check.sh
```

- 若失败：先按 `tools/baseline/REBUILD.md` 查明原因；**不得**直接改值表。
- 若 ELF 变化符合预期（运行时 stub/锁/queue 改变代码布局），在同一组留旧值、写新值，并在 `docs/superpowers/implementation/2026-11-01-concurrency-0a.md` 说明原因。
- `.ccr` 应只在新 builtins/`sched_init_n` 被使用的语料上变化；若无关语料变化，停下查根因。

- [ ] **Step 8: 最终提交**

```bash
jj commit -m "docs: record concurrency 0A evidence and boundaries"
```

---

## Self-Review

- **Spec coverage:** 0A 的三项（多 M 接线、runq/恢复执行面、并发运行时验证基础）分别由 Task 3/5、Task 5、Task 1/2/4 覆盖；0B/1–10 明确排除。
- **Step scan:** 每个任务有失败测试或回归命令、最小实现、验证、提交；无“TBD/适当处理”类步骤。
- **Type consistency:** `sched_init_n(int)`、`sched_dequeue() -> int`、`rt_m_idx() -> int`、`rt_current_arena() -> int`、`rt_set_current_arena(int)`、`rt_lock_acquire()`、`rt_lock_release()` 在 Task 1～5 中同名同型。
- **Review Focus:** 8 条风险均有对应测试（Task 2 arena grow、Task 5 ping-pong、2M/4M、1000 spawn、main pinned、TLS-before-alloc）。
- **Proportion:** 计划只给签名、关键算法和测试断言，不转录完整实现。
