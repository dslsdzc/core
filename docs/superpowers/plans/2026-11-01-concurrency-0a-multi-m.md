# Core 并发 0A：多 M 无锁基础 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Core 的 `go`/channel 在 2～4 个 M（OS 线程）上正确运行，且运行时**不引入锁**：TLS 保存线程本地状态，per-M run queue 用无锁栈，channel 用 SPSC 环形缓冲 + 单等待槽，arena 元数据按 M 分区并用原子操作。

**Architecture:** G 固定到创建它的 M（`home_m`），只由该 M 执行；每个 M 有一条 **带 15-bit tag 的 Treiber stack** 作为 run queue（tag 防 ABA，其他 M 用 CAS push，owner 只 pop 自己的 head）。channel 走 SPSC：`head` 只由消费者推进，`tail` 只由生产者推进，等待槽各只有一个 G；用 `xchg`/CAS 完成发布和唤醒。arena 元数据按 M 分区、启动时预分配，arena/slot/segment 的 free list 用 per-M 分区 + 原子操作；不再用全局分配器锁。

**Tech Stack:** Core stdlib（`src/stdlib/{sched,chan,goroutine,arena}.cr`）、x86-64 ELF 后端（`src/format/elf/`、`src/os/linux/entry.cr`、`src/arch/x86_64/`）、rt.s、Python bootstrap、jj。

**Spec:** `docs/superpowers/specs/2026-09-17-concurrency-model-design.md` §11.1 步 0a；事实依据 `docs/superpowers/implementation/2026-09-17-concurrency-model-evidence.md` §15。

## Global Constraints

- 0A 只做“多 M 正确”，**不**做 Transfer Analysis、不实现 MOVE/LOAN/SPLIT/FILL/COPY、不实现预算/证书，不声称实现 2026-09-17 模型。
- **运行时不得引入锁**。只用 TLS、原子 load/store/xchg/CAS/fetch-add、per-M 分区和无锁队列；源语言仍不新增 lock/mutex/atomic/ownership 语法。
- G 固定 `home_m`，不迁移。跨 M 只能 push 到目标 M 的 run queue，不能直接执行或改目标 M 的栈。
- channel 以 SPSC 为前提：单生产者、单消费者。多生产者/多消费者不在 0A 承诺内（`TODO #2026-09-18-1`）；等待槽只有一个 sender/一个 receiver。
- 默认仍保持 share-nothing 的设计方向；本阶段不新增跨 G 共享 API。
- worker 上的 G 始终有 arena；**global bump heap 只由 M0/启动期使用**。若 worker 走到 global heap（current arena < 0），必须 fail-closed（测试断言），不能假装全局堆是线程安全的。
- 不改 `.ccr` 的 transfer/sync 决策面；不把原子/并发策略写进 IR。
- 版本控制只用 `jj`，不用 `git`。
- 长编译/长测试用 `nice -n 19`（必要时 `cpulimit -l 10`）。
- 当前分支必须基于 `feature/region-v2`；`develop` 缺少 per-G arena 绑定和 raw current-arena builtins。

## Review Focus

- run queue 的 ABA/重复入队：同一个 G 不能被 push 两次（Task 2/3 的等待槽 `xchg` 必须保证只有一个 waker）；Treiber stack 的 head 必须带 tag，不能只 CAS 裸指针。
- channel 空/满与阻塞的丢失唤醒：发布等待槽和重查 head/tail 之间必须有屏障（Task 3）。
- blocking path 不能调用会重新入队的 `sched_yield`：waker 可能已经把 G push 回来，再入队会造成同一个 G 两次入队（Task 3）。
- waker 在 recheck 窗口认领等待槽后，G 可能还在跑：G 必须走 `sched_schedule` 消费自己的 spurious queue entry；若 G 已 dead，schedule 必须丢弃 `next_g == old_g` 的 dead 条目，不能返回到 dead stack（Task 3/5）。
- G 退出时在自己栈上 reset 自己的 arena：必须延迟到 home M 的调度器栈上（Task 2）。
- main G 被 worker 抢走：`home_m=0` 且 M0 只 pop 自己的栈（Task 2）。
- arena 元数据跨 M 写：必须按 M 分区，不能让两个 M 写同一个 free list/counter（Task 4）。
- `cell_store` 是逐字节写，不是原子 64 位写：共享字段必须用 `rt_atomic_load/store/xchg`（Task 1/3）。
- worker 的 TLS 未在第一次 `alloc` 前建立（Task 1）。
- worker 栈/TLS 未按 16 字节对齐（Task 5）。

---

## Task 0: 建立隔离工作区与基线

**Files:** 无源码改动。

- [ ] **Step 1: 确认工作区与分支**

```bash
jj status
jj log -r '@-' --no-graph -T 'commit_id.short() ++ " " ++ description.first_line() ++ "\n"'
```

Expected: 工作区干净；`@-` 是 `regionplan: copy-on-write for share writes`。

- [ ] **Step 2: 构建基线**

```bash
nice -n 19 python3 build_selfhost_native.py
```

Expected: `build/corec`、`build/corearch`、`build/corelsp`，成功行。

- [ ] **Step 3: 跑并发基线**

```bash
nice -n 19 python3 tests/selfhost/test_chan_handle_model.py
nice -n 19 python3 tests/selfhost/test_go_arena.py
```

Expected: `11/11 通过`；`PASS go arena per-G context switch`。

- [ ] **Step 4: 提交空分支声明**

```bash
jj commit -m "chore: start concurrency 0A (lock-free multi-M foundation)"
```

---

## Task 1: TLS 运行时状态与原子原语

**Files:**
- Modify: `src/runtime/rt.s`
- Modify: `src/runtime/rt.cr`
- Modify: `src/os/linux/entry.cr`
- Modify: `src/arch/x86_64/sizes.cr`
- Modify: `src/format/elf/elf.cr`
- Modify: `src/compiler/ir_gen.cr`
- Modify: `src/runtime/runtime_frontend_abi.cr`
- Modify: `src/compiler/ccr_io.cr`
- Modify: `bootstrap/corec/frontend/name_resolver.py`
- Modify: `bootstrap/corec/frontend/type_checker.py`
- Test: `tests/selfhost/test_rt_tls.py`（新建）

**Interfaces:**
- Consumes: 无。
- Produces:
  - TLS 布局（32 bytes）：`+0 current_g`、`+8 m_idx`、`+16 current_arena`、`+24 arena_suspend`。
  - `rt_m_idx() -> int`、`rt_current_arena() -> int`、`rt_set_current_arena(v: int)`、`rt_arena_suspend() -> int`、`rt_set_arena_suspend(v: int)`。
  - `rt_atomic_load(buf: string, off: int) -> int`、`rt_atomic_store(buf: string, off: int, val: int)`。
  - `rt_atomic_xchg(buf: string, off: int, val: int) -> int`（返回旧值）。
  - `rt_atomic_cas(buf: string, off: int, old: int, new: int) -> int`（成功 1 / 失败 0）。
  - `rt_atomic_fetch_add(buf: string, off: int, delta: int) -> int`（返回旧值）。
  - `g_set_curg(ptr: int)` / `g_get_curg() -> int` 改为 `%fs:0`。

- [ ] **Step 1: 写失败测试**

新建 `tests/selfhost/test_rt_tls.py`，Core 源码：

```core
import arena

g_test_cell : string, mut

fn main() -> int:
    g_test_cell = alloc(8)
    if rt_m_idx() != 0:
        return 1
    rt_atomic_store(g_test_cell, 0, 7)
    if rt_atomic_load(g_test_cell, 0) != 7:
        return 2
    if rt_atomic_xchg(g_test_cell, 0, 9) != 7:
        return 3
    if rt_atomic_load(g_test_cell, 0) != 9:
        return 4
    if rt_atomic_cas(g_test_cell, 0, 9, 11) != 1:
        return 5
    if rt_atomic_load(g_test_cell, 0) != 11:
        return 6
    if rt_atomic_fetch_add(g_test_cell, 0, 5) != 11:
        return 7
    if rt_atomic_load(g_test_cell, 0) != 16:
        return 8
    arena_init(1073741824, 1048576)
    a := arena_new_sized(65536)
    if arena_current_unchecked() != a:
        return 9
    arena_reset(a)
    return 0
```

`g_test_cell` 声明在测试源码里：`g_test_cell : string, mut`，并在 `main` 里 `g_test_cell = alloc(8)`（或直接用 `alloc(8)` 后传 buffer）。驱动用 `corec ccr` + `corearch --raw-int --elf`，`timeout=60` 运行。

- [ ] **Step 2: 运行测试，确认失败**

```bash
nice -n 19 python3 tests/selfhost/test_rt_tls.py
```

Expected: `Undefined function 'rt_m_idx'`（或同类）。

- [ ] **Step 3: `rt.s` 建立 main TLS**

`.bss` 加 32 字节 `main_tls`。`_start` 在保存 argc/argv 后、任何 alloc/main 前：

```asm
lea rsi, [rip + main_tls]
mov edi, 0x1002          # ARCH_SET_FS
mov eax, 158             # arch_prctl
syscall
mov rax, -1
mov qword ptr fs:[0], rax
xor eax, eax
mov qword ptr fs:[8], rax
mov rax, -1
mov qword ptr fs:[16], rax
xor eax, eax
mov qword ptr fs:[24], rax
```

`g_set_curg` / `g_get_curg` 改成 `mov fs:[0], rdi` / `mov rax, fs:[0]`。

- [ ] **Step 4: ELF `_start` 建立 main TLS**

`src/os/linux/entry.cr::emit_start` 发同一段初始化。TLS 块放在 BSS 末尾：

- `elf.cr` 的 `globals_size` 加 32 字节，记录 `g_rt_tls_va = bss_va + 16 + globals_size - 32`。
- `emit_start` 记录 `lea rsi, [rip+disp32]` 的 disp32 位置到 `g_start_tls_patch_pos`；最终 `bss_va` 确定后 `w32` 回填。
- `src/arch/x86_64/sizes.cr::sz_start_body` 加 `sz_start_tls_init()`，`emit_start_size` 同步。

- [ ] **Step 5: ELF 发原子/TLS stub**

`elf.cr` 新增 `emit_rt_tls_stubs`，每项按 16 字节对齐的固定大小发射并注册 `func_offsets`：

- `rt_m_idx`：`mov rax, fs:[8]; ret`
- `rt_current_arena`：`mov rax, fs:[16]; ret`
- `rt_set_current_arena`：`mov fs:[16], rdi; ret`
- `rt_arena_suspend`：`mov rax, fs:[24]; ret`
- `rt_set_arena_suspend`：`mov fs:[24], rdi; ret`
- `rt_atomic_load`：`mov rax, [rdi+rsi]; ret`
- `rt_atomic_store`：`mov [rdi+rsi], rdx; ret`
- `rt_atomic_xchg`：`mov rax, rdx; xchg [rdi+rsi], rax; ret`
- `rt_atomic_cas`：`mov rax, rdx; lock cmpxchg [rdi+rsi], rcx; sete al; movzx rax, al; ret`
- `rt_atomic_fetch_add`：`mov rax, rdx; lock xadd [rdi+rsi], rax; ret`

Phase 2 `total_code` 与 Phase 3 使用同一组 `sz_rt_*` 常量。原子操作要求地址 8 字节对齐；调用方保证字段偏移是 8 的倍数。

- [ ] **Step 6: `rt.s` 提供同名符号**

在 rt.s 用真实汇编实现上述 10 个函数。`g_set_curg`/`g_get_curg` 改为 FS 版本。rt.s 不需要 `g_rt_lock_owner`（本计划没有锁）。

- [ ] **Step 7: 注册 ABI 名称**

- `src/runtime/runtime_frontend_abi.cr`：加 10 个 `prelude_builtin_add`。
- `src/compiler/ccr_io.cr::ccr_raw_abi_builtin`：10 个名字加入 SYSTEM 名单。
- `bootstrap/corec/frontend/name_resolver.py::_declare_builtins` 与 `bootstrap/corec/frontend/type_checker.py` 的 `rt_funcs`：同样加 10 个。
- `src/compiler/ir_gen.cr::ir_gen_globals`：`g_rt_tls` 不需要全局；测试用的 `g_test_cell` 由源码声明。

- [ ] **Step 8: 运行测试**

```bash
nice -n 19 python3 tests/selfhost/test_rt_tls.py
nice -n 19 python3 tests/selfhost/test_go_arena.py
nice -n 19 python3 tests/selfhost/test_chan_handle_model.py
```

Expected: 全 PASS。

- [ ] **Step 9: 提交**

```bash
jj commit -m "runtime: per-thread TLS state and atomic primitives (0A)"
```

---

## Task 2: per-M run queue、home M 固定、延迟 G 回收

**Files:**
- Modify: `src/stdlib/sched.cr`
- Modify: `src/stdlib/goroutine.cr`
- Test: 现有 `test_chan_handle_model.py`、`test_go_arena.py`、`tests/suite/conc_test.cr`

**Interfaces:**
- Consumes: Task 1。
- Produces:
  - G 布局 104 字节：`+88 home_m`、`+96 dead_next`（dead 链不能复用 run queue 的 `next`，否则 stale queue entry 会被破坏）。
  - M 布局 48 字节：`id(0)`、`cur_g(8)`、`ready_head(16)`、`sched_sp(24)`、`spawn_head(32)`、`pad(40)`。
  - `sched_init_n(n: int)`、`sched_init()`（= `sched_init_n(1)`）、`sched_spawn_workers(n)`（`pub`）。
  - `sched_enqueue(g: string)`：push 到 `g.home_m` 的 tagged Treiber 栈。
  - `sched_dequeue(m_idx: int) -> int`：只 pop 自己 M 的栈。
  - `sched_reap_dead(m_idx: int, cur_g: int)`：home M 回收自己的 dead 链；`cur_g` 是当前正在跑的 G（scheduler 栈上为 -1）。

- [ ] **Step 1: 写测试**

先保留现有单 M 套件作为回归：

```bash
nice -n 19 python3 tests/selfhost/test_chan_handle_model.py
nice -n 19 python3 tests/selfhost/test_go_arena.py
```

Expected: 当前全绿；refactor 后继续全绿。

- [ ] **Step 2: G 结构加 `home_m`**

`goroutine.cr` 的 `g_new` 读取 `rt_m_idx()`：

```core
fn g_new(entry_fn: int, arg: int, arg_type: int) -> string:
    ...
    home := rt_m_idx()
    g := alloc(104)
    ...
    cell_store(g, 88, home)
    cell_store(g, 96, -1)   # dead_next
```

ID 也按 M 分区，避免全局 `g_next_id` 写竞争：

```core
g_next_id_m : string, mut   # per-M counter array, alloc(n*8) in sched_init_n
...
id := cell_load(g_next_id_m, home * 8)
cell_store(g_next_id_m, home * 8, id + 1)
```

`g_free` 只标记 dead 并 push 到 `g_dead_head_m[home_m]` 链表；run queue 用 offset 48，dead 链用 offset 96，两者不能复用。

- [ ] **Step 3: M 结构与 tagged Treiber stack**

```core
# M: id(0), cur_g(8), ready_head(16), sched_sp(24), spawn_head(32), pad(40) = 48 bytes
# ready_head/spawn_head = (tag << 48) | ptr；tag 1..32767，ptr 为 48-bit 用户地址
g_machines : string, mut
g_dead_head_m : string, mut
g_next_id_m : string, mut
PTR_MASK : int = 281474976710656   # 2^48
TAG_MAX : int = 32767
```

push（任意 M；G 固定 home M）：

```core
fn sched_enqueue(g: string):
    hm := cell_load(g, 88)
    if hm < 0:
        hm = 0
    m := g_machines + hm * 48
    gp : ., mut = 0
    unsafe:
        gp = @ptr_of(g)
    loop:
        old := rt_atomic_load(m, 16)
        tag := old / PTR_MASK + 1
        if tag > TAG_MAX:
            tag = 1
        ptr := old % PTR_MASK
        cell_store(g, 48, ptr)
        newv := tag * PTR_MASK + gp
        if rt_atomic_cas(m, 16, old, newv) != 0:
            return
```

pop（只有 owner M）：

```core
fn sched_dequeue(m_idx: int) -> int:
    m := g_machines + m_idx * 48
    loop:
        old := rt_atomic_load(m, 16)
        ptr := old % PTR_MASK
        if ptr == 0:
            return -1
        nxt := cell_load(ptr, 48)
        tag := old / PTR_MASK + 1
        if tag > TAG_MAX:
            tag = 1
        newv := tag * PTR_MASK + nxt
        if rt_atomic_cas(m, 16, old, newv) != 0:
            cell_store(ptr, 48, 0)
            return ptr
```

tag 用 15 bit（bit48..62），最高位保持 0，Core 的数学整数不会变成负数；用户地址在 48 bit 内（TEXT_BASE 4MB、BSS/堆 1GB、mmap 用户态 < 2^47）。tag 回绕窗口 32768 次，0A 可接受；0C 若要更强保证再换 128-bit CAS。

- [ ] **Step 4: `sched_init_n` 与 M 初始化**

```core
fn arena_init_m(pool: int, size: int, n: int), pub:
    arena_init(pool, size)                  # Task 4 再替换为真正分区

fn sched_init_n(n: int), pub:
    if g_sched_inited != 0:
        return
    if n < 1:
        n = 1
    arena_init_m(g_arena_pool_limit, 1048576, n)
    m := alloc(n * 48)
    g_dead_head_m = alloc(n * 8)
    g_next_id_m = alloc(n * 8)
    mi : ., mut = 0
    loop:
        if mi >= n:
            break
        cell_store(m, mi * 48, mi)          # id
        cell_store(m, mi * 48 + 8, -1)      # cur_g
        cell_store(m, mi * 48 + 16, 0)      # ready_head (tag=0, ptr=0)
        cell_store(m, mi * 48 + 24, 0)      # sched_sp
        cell_store(m, mi * 48 + 32, 0)      # spawn_head (tag=0, ptr=0)
        cell_store(g_dead_head_m, mi * 8, -1)
        cell_store(g_next_id_m, mi * 8, 1)
        mi = mi + 1
    main_g := alloc(104)
    # 与当前 main G 字段一致；+80 = -1，+88 = home_m = 0，+96 = dead_next = -1
    ...
    g_machines = m
    g_machine_count = n
    g_num_workers = n - 1
    g_sched_inited = 1
    g_set_curg(main_g)
    cell_store(m, 8, main_g)
    if n > 1:
        sched_spawn_workers(n)
```

`sched_spawn_workers(n)` 只设置 `g_num_workers = n - 1` 并调用 `m_start_workers(n)`；不再重建 `g_machines`。
`sched_init()` 调用 `sched_init_n(1)`。

- [ ] **Step 5: 延迟回收**

`goroutine.cr::g_free`：

```core
fn g_free(g: string):
    hm := cell_load(g, 88)
    if hm < 0:
        hm = 0
    rt_atomic_store(g, 8, 3)   # status 是跨 M 可见字段，不能 byte-wise cell_store
    cell_store(g, 96, cell_load(g_dead_head_m, hm * 8))  # dead_next，不碰 queue 的 next(48)
    cell_store(g_dead_head_m, hm * 8, g)
```

所有跨 M 可见的 `G.status` 读写（`sched_yield`、`sched_schedule`、channel 阻塞/wake、`g_free`）必须用 `rt_atomic_load/store`；`cell_store` 是逐字节循环，不是原子 64 位写。G 的 `next(48)`/`dead_next(96)` 是单写者字段，可以继续用 `cell_store`。

`sched.cr`：

```core
fn sched_reap_dead(m_idx: int, cur_g: int):
    loop:
        g := cell_load(g_dead_head_m, m_idx * 8)
        if g < 0:
            break
        if g == cur_g:
            # 当前正跑在这个 G 的栈上，不能 reset 它的 arena
            break
        cell_store(g_dead_head_m, m_idx * 8, cell_load(g, 96))
        aid := cell_load(g, 32)
        saved := rt_current_arena()
        arena_reset(aid)
        rt_set_current_arena(saved)
```

home M 的 scheduler/worker loop 调用 `sched_reap_dead(m_idx, cur_g)`：`sched_schedule` 传当前 `old_g`，worker 在 scheduler 栈上时传 `-1`。因为 G 不迁移，dead list 和 arena 都只由 home M 操作。

`sched_yield` 的 `st := cell_load(cur_g, 8)` / `cell_store(cur_g, 8, 0)` 改为 `rt_atomic_load/store`；它只在自己 M 的 G 栈上运行，但 waker 可能同时读 status，不能逐字节写。

- [ ] **Step 6: 单 M 回归**

```bash
nice -n 19 python3 tests/selfhost/test_chan_handle_model.py
nice -n 19 python3 tests/selfhost/test_go_arena.py
nice -n 19 ./build/corec check tests/suite/conc_test.cr
```

Expected: 全 PASS / rc=0。

- [ ] **Step 7: 提交**

```bash
jj commit -m "sched: lock-free per-M run queues and deferred G reclamation (0A)"
```

---

## Task 3: SPSC channel 无锁化

**Files:**
- Modify: `src/stdlib/chan.cr`
- Test: `test_chan_handle_model.py`、`tests/suite/conc_test.cr`

**Interfaces:**
- Consumes: Task 1 的原子原语、Task 2 的 `sched_enqueue`。
- Produces:
  - channel 布局不变（64B），但语义改为：`head` 消费者单调索引、`tail` 生产者单调索引、`send_wait`/`recv_wait` 单 G 槽。
  - `chan_send`/`chan_recv` 无锁循环；`chan_close` 用 `xchg` 唤醒两个等待槽。

- [ ] **Step 1: 写单 M 回归**

现有 `conc_test` 覆盖 FIFO/close；先保留。

```bash
nice -n 19 python3 tests/selfhost/test_chan_handle_model.py
```

- [ ] **Step 2: 改 channel 字段语义**

`chan_make`：

```core
cell_store(ch, 16, 0)   # head = 0
cell_store(ch, 24, 0)   # tail = 0
cell_store(ch, 40, 0)   # send_wait = none
cell_store(ch, 48, 0)   # recv_wait = none
cell_store(ch, 56, 0)   # closed = 0
```

`head`/`tail` 是单调计数，`buf[(tail % cap) * esize]` 写入，`buf[(head % cap) * esize]` 读出。不要再用 `len`。
`_chan_ensure_init` 的 `g_chan_inited` 读写改用 `rt_atomic_load/store`；初始化本身只在 `sched_init_n` 之前或主线程发生，但多个 G 首次 `chan_make` 时不能逐字节写。

- [ ] **Step 3: `chan_send` 快速路径**

```core
fn chan_send(ch: string, val: int), pub:
    _chan_ensure_init()
    if rt_atomic_load(ch, 56) != 0:
        return   # 0A 不实现 panic；closed 后 send 直接返回
    loop:
        cap := cell_load(ch, 8)
        head := rt_atomic_load(ch, 16)
        tail := rt_atomic_load(ch, 24)
        if tail - head < cap:
            buf := cell_load(ch, 0)
            esize := cell_load(ch, 32)
            cell_store(buf, (tail % cap) * esize, val)
            rt_atomic_store(ch, 24, tail + 1)
            rw := rt_atomic_xchg(ch, 48, 0)
            if rw != 0:
                rt_atomic_store(rw, 8, 0)  # runnable
                sched_enqueue(rw)
            return
        if rt_atomic_load(ch, 56) != 0:
            return
        # 满：发布 send_wait
        g := sched_get_curg()
        if g < 0:
            return
        rt_atomic_store(g, 8, 2)  # waiting
        rt_atomic_xchg(ch, 40, g)
        # 重新检查空间；闭包在同一轮内完成
        head = rt_atomic_load(ch, 16)
        tail = rt_atomic_load(ch, 24)
        if tail - head < cap:
            if rt_atomic_xchg(ch, 40, 0) == g:
                rt_atomic_store(g, 8, 1)
                continue
        # 注意：blocking path 不能调 sched_yield（它会按 status 再入队，
        # 与 waker 的 push 竞争导致同一个 G 入队两次）；直接进 schedule。
        # 如果上面的 xchg 失败（waker 已认领），即使 closed 也要先走
        # sched_schedule 消费自己的 queue entry，不能直接 return。
        sched_schedule()
        # 被唤醒后重新走循环；waker 已把状态置 runnable
```

`cap` 用局部变量缓存，避免重复 load。

- [ ] **Step 4: `chan_recv`**

```core
fn chan_recv(ch: string) -> int, pub:
    _chan_ensure_init()
    loop:
        cap := cell_load(ch, 8)
        head := rt_atomic_load(ch, 16)
        tail := rt_atomic_load(ch, 24)
        if head < tail:
            buf := cell_load(ch, 0)
            esize := cell_load(ch, 32)
            val := cell_load(buf, (head % cap) * esize)
            rt_atomic_store(ch, 16, head + 1)
            sw := rt_atomic_xchg(ch, 40, 0)
            if sw != 0:
                rt_atomic_store(sw, 8, 0)
                sched_enqueue(sw)
            return val
        if rt_atomic_load(ch, 56) != 0:
            return 0
        g := sched_get_curg()
        if g < 0:
            return 0
        rt_atomic_store(g, 8, 2)
        rt_atomic_xchg(ch, 48, g)
        head = rt_atomic_load(ch, 16)
        tail = rt_atomic_load(ch, 24)
        if head < tail:
            if rt_atomic_xchg(ch, 48, 0) == g:
                rt_atomic_store(g, 8, 1)
                continue
        sched_schedule()
```

- [ ] **Step 5: `chan_close`**

```core
fn chan_close(ch: string), pub:
    _chan_ensure_init()
    rt_atomic_store(ch, 56, 1)
    rw := rt_atomic_xchg(ch, 48, 0)
    if rw != 0:
        rt_atomic_store(rw, 8, 0)
        sched_enqueue(rw)
    sw := rt_atomic_xchg(ch, 40, 0)
    if sw != 0:
        rt_atomic_store(sw, 8, 0)
        sched_enqueue(sw)
```

- [ ] **Step 6: 单 M 回归**

```bash
nice -n 19 python3 tests/selfhost/test_chan_handle_model.py
nice -n 19 python3 tests/selfhost/test_go_arena.py
```

Expected: 全 PASS；`conc_test` 的 FIFO/close 行为不变。

- [ ] **Step 7: 提交**

```bash
jj commit -m "chan: lock-free SPSC ring and single-waiter wake protocol (0A)"
```

---

## Task 4: per-M arena 元数据分区

**Files:**
- Modify: `src/stdlib/arena.cr`
- Modify: `src/runtime/alloc_body.cr`
- Modify: `src/runtime/alloc_blob.cr`（生成物）
- Modify: `tools/gen_alloc_blob.py`
- Modify: `src/compiler/ir_gen.cr`
- Modify: `src/format/elf/elf.cr`（alloc blob 外部调用解析）
- Test: `test_rt_tls.py`、`test_go_arena.py`、`test_multi_m.py` 的 spawn stress。

**Interfaces:**
- Consumes: Task 1 原子/TLS；Task 2 home M 固定。
- Produces:
  - `arena_init_m(pool_size: int, arena_size: int, m_count: int)`；`arena_init(pool,size)` = `arena_init_m(pool,size,1)`。
  - 预分配元数据：`ARENA_PER_M=1024`、`SLOTS_PER_M=256`、`SEGMENTS_PER_M=4`（每段 64MB）。
  - per-M 数组：`g_arena_count_m`、`g_arena_free_list_m`、`g_slot_count_m`、`g_slot_free_m`、`g_segment_count_m`、`g_dead_head_m`（Task 2）。
  - `g_arena_suspend` 改为 TLS；`alloc_blob` 调 `rt_arena_suspend()`。
  - `alloc_body.cr` 的 `arena_get_slot` 改为读 per-M slot free/count，不再走全局 slot free list；`arena.cr::_arena_get_slot` 同逻辑。

- [ ] **Step 1: 写 stress 测试**

在 `tests/selfhost/test_multi_m.py` 先写一个单 M 也能跑的 arena 复用用例：

```core
import arena

fn work(n: int) -> int:
    a : [int; 4], mut
    a[0] = n
    return a[0]

fn main() -> int:
    arena_init_m(1073741824, 1048576, 1)
    i : ., mut = 0
    sum : ., mut = 0
    loop:
        if i >= 2000:
            break
        aid := arena_new_sized(65536)
        p := alloc(2048)
        if p < 0:
            return 1
        arena_reset(aid)
        sum = sum + 1
        i = i + 1
    return 0
```

Expected before implementation: `arena_init_m` 未定义 → ccr 失败。实现后 2000 次 new/reset 不崩、不耗尽。

- [ ] **Step 2: `arena_init_m` 预分配**

`arena.cr`：

```core
ARENA_PER_M : int = 1024
SLOTS_PER_M : int = 256
SEGMENTS_PER_M : int = 4

fn arena_init_m(pool_size: int, arena_size: int, m_count: int), pub:
    if m_count < 1:
        m_count = 1
    g_arena_m_count = m_count
    total := m_count * ARENA_PER_M
    g_arena_live = alloc(total * 8)
    g_arena_cursors = alloc(total * 8)
    g_arena_sizes = alloc(total * 8)
    g_arena_parents = alloc(total * 8)
    g_arena_slot = alloc(total * 8)
    g_arena_slot_cursor = alloc(total * 8)
    g_arena_static = alloc(total * 8)
    g_arena_large_head = alloc(total * 8)
    g_arena_large_count = alloc(total * 8)
    g_class_base = alloc(total * ARENA_CLASS_COUNT * 8)
    g_class_cursor = alloc(total * ARENA_CLASS_COUNT * 8)
    g_class_limit = alloc(total * ARENA_CLASS_COUNT * 8)
    g_arena_slot_next = alloc(m_count * SLOTS_PER_M * 8)
    g_segment_base = alloc(m_count * SEGMENTS_PER_M * 8)
    g_arena_count_m = alloc(m_count * 8)
    g_arena_free_list_m = alloc(m_count * 8)
    g_slot_count_m = alloc(m_count * 8)
    g_slot_free_m = alloc(m_count * 8)
    g_segment_count_m = alloc(m_count * 8)
    # 初始化：g_arena_count_m=0、g_arena_free_list_m=-1、g_slot_count_m=0、
    # g_slot_free_m=-1、g_segment_count_m[mi]=mi*SEGMENTS_PER_M；
    # g_arena_live=0、g_arena_large_head=-1、g_arena_large_count=0。
    mi : ., mut = 0
    loop:
        if mi >= m_count:
            break
        cell_store(g_arena_count_m, mi * 8, 0)
        cell_store(g_arena_free_list_m, mi * 8, -1)
        cell_store(g_slot_count_m, mi * 8, 0)
        cell_store(g_slot_free_m, mi * 8, -1)
        cell_store(g_segment_count_m, mi * 8, mi * SEGMENTS_PER_M)
        mi = mi + 1
    g_arena_cap = total
    g_arena_pool_limit = pool_size
    # 保留现有 arena_init 的 g_arena_scalars=alloc(64)、scalar 8 = max size、
    # g_class_lookup 初始化、g_arena_scalars_ready=1 等；只把 metadata 数组改成
    # 上面的预分配版本，不要丢掉 allocator blob 依赖的只读单元。
```

不调用 `_grow_arena_meta`；`arena_new_sized` 若 local id >= ARENA_PER_M 则 fail-closed（返回 -1 / trap）。

- [ ] **Step 3: per-M arena id 与 free list**

`arena_new_sized`：

```core
m := rt_m_idx()
if m < 0:
    m = 0
ai : ., mut = -1
free := cell_load(g_arena_free_list_m, m * 8)
if free >= 0:
    ai = free
    cell_store(g_arena_free_list_m, m * 8, cell_load(g_arena_parents, ai * 8))
else:
    local := cell_load(g_arena_count_m, m * 8)
    if local >= ARENA_PER_M:
        return -1
    ai = m * ARENA_PER_M + local
    cell_store(g_arena_count_m, m * 8, local + 1)
```

`arena_reset` 把 `ai` push 回 `g_arena_free_list_m[m]`，并把该 arena 的 slots 归还 per-M slot free list。

`g_arena_live` 仍按 ai 标记；`arena_avail` 用 `ai < g_arena_cap` + live。

- [ ] **Step 4: per-M slot/segment**

`alloc_body.cr` 的 `arena_get_slot(ai, size)` 直接在 blob 内用 per-M 数组，不调用 Core 函数（避免函数 arena 递归）：

```core
m := rt_m_idx()
if m < 0:
    m = 0
sf := cell_load(g_slot_free_m, m * 8)
if sf >= 0:
    slot = sf
    cell_store(g_slot_free_m, m * 8, cell_load(g_arena_slot_next, sf * 8))
else:
    local := cell_load(g_slot_count_m, m * 8)
    if local >= SLOTS_PER_M:
        return arena_fail_slot(size, local, SLOTS_PER_M)
    slot = m * SLOTS_PER_M + local
    cell_store(g_slot_count_m, m * 8, local + 1)
    seg := slot / 64
    # g_segment_count_m[m] 是“下一个全局 segment 下标”，初始 m*SEGMENTS_PER_M
    if seg >= cell_load(g_segment_count_m, m * 8):
        arena_grow_pool_m(m)
# 链接到当前 arena 的 slot 单链
old := cell_load(g_arena_slot, ai * 8)
if old >= 0:
    cell_store(g_arena_slot_next, slot * 8, old)
else:
    cell_store(g_arena_slot_next, slot * 8, -1)
cell_store(g_arena_slot, ai * 8, slot)
cell_store(g_arena_slot_cursor, ai * 8, 0)
return slot
```

`arena.cr::_arena_get_slot` 用同一逻辑（解释器路径）。`arena_reset` 把 slots 按链归还 `g_slot_free_m[m]`。

`arena_grow_pool_m(m)`：取 `seg := cell_load(g_segment_count_m, m*8)`；若 `seg >= (m+1)*SEGMENTS_PER_M` 则 fail-closed；`mmap(0, 64MB, PROT_READ|WRITE, MAP_PRIVATE|ANON, -1, 0)`；把段指针存到 `g_segment_base[seg]`；`g_segment_count_m[m] = seg + 1`。每 M 最多 4 段（256 个 1MB slot），耗尽则 fail-closed。`arena_init_m` 把 `g_segment_count_m[m]` 初始化为 `m * SEGMENTS_PER_M`。保留 `arena_grow_pool()` 作为 `arena_grow_pool_m(rt_m_idx())` 的兼容包装，编译器/单 M 路径继续可用。

`arena_slot_base(slot)` 仍用 `g_segment_base[slot/64]`；因为 slot id 按 M 分区，段索引也自然分区。

把 `rt_m_idx`、`rt_current_arena`、`rt_arena_suspend`、`arena_grow_pool_m` 加入 `tools/gen_alloc_blob.py` 的 `EXTERNAL_CALLS`；`g_slot_free_m`、`g_slot_count_m`、`g_segment_count_m` 加入 `EXTERNAL_GLOBALS`。`patch_alloc_blob_calls` 通过 `find_alloc_blob_func` 解析（`rt_m_idx`/`rt_current_arena`/`rt_arena_suspend` 是 Task 1 注册的 runtime stub；`arena_grow_pool_m` 是 `arena.cr` 的 Core 函数）。

- [ ] **Step 5: TLS current arena / suspend**

- `arena_set_current(val)` 写 `rt_set_current_arena(val)`；保留 `g_current_arena` 兼容写。
- `arena_current_unchecked()` 读 `rt_current_arena()`。
- `arena_reset/arena_clear/arena_init` 用 `rt_set_arena_suspend(1/0)` 代替全局 `g_arena_suspend`。
- `alloc_body.cr` 把 `g_arena_suspend` 改为 `rt_arena_suspend()`；`g_arena_scalars_ready` 仍全局只读。
- `alloc_blob` 的 `alloc_arena` 用 `rt_current_arena()`；不再读 `g_arena_scalars[0]`。
- `ir_gen.cr` 的 `arena_current_unchecked`/`arena_set_current_unchecked` lowering 改为 `rt_current_arena`/`rt_set_current_arena`（同上一版计划）。
- `alloc_body.cr` 的 `alloc_arena` 在 `ai < 0` 且 `rt_m_idx() != 0` 时直接 `alloc_fail(..., -3, ...)`，把“worker 掉进 global heap”变成可见失败；M0 仍允许 global heap。

- [ ] **Step 6: 运行 arena 回归**

```bash
nice -n 19 python3 tests/selfhost/test_rt_tls.py
nice -n 19 python3 tests/selfhost/test_go_arena.py
nice -n 19 python3 tests/selfhost/test_multi_m.py
```

Expected: TLS/arena 用例 PASS；2000 次 new/reset 不崩溃。

- [ ] **Step 7: 提交**

```bash
jj commit -m "arena: per-M metadata partitions and lock-free slot/segment allocators (0A)"
```

---

## Task 5: 启用多 M、worker 启动/恢复、跨 M 唤醒与压力测试

**Files:**
- Modify: `src/stdlib/sched.cr`
- Modify: `src/format/elf/elf.cr`
- Modify: `src/runtime/rt.s`
- Create/Modify: `tests/selfhost/test_multi_m.py`
- Modify: `src/ci/run.sh`

**Interfaces:**
- Consumes: Task 1～4。
- Produces:
  - `sched_init_n(n)` 启动 n-1 个 worker。
  - spawn 分发：`sched_go` 按原子 round-robin 选择 home M；目标 M 不是当前 M 时，把 `{fn_ptr,arg,result_ch}` 请求 push 到目标 M 的 `spawn_head`，由目标 M 在本地创建 G（arena 也在目标 M 创建）。
  - worker 首次启动 G：`fiber_switch(&M.sched_sp, G.sp)`。
  - worker 无 G：`fiber_switch(&G.sp, M.sched_sp)` 回 scheduler 栈。
  - `m_start_workers`：CLONE_SETTLS、TLS block、16 字节栈对齐、去掉 double-inc。
  - M 布局增加 `spawn_head(32)`；总 48 字节。

- [ ] **Step 1: 写 4 个多 M 用例**

`tests/selfhost/test_multi_m.py`：

1. `two_workers_two_goroutines`：`sched_init_n(2)`，两个 `go work(n)`，`chan_recv` 校验 2/3。
2. `four_workers_queue`：`sched_init_n(4)`，spawn 64 个，用 `store_str_ptr`/`load_str_ptr` 存 handle，校验和。
3. `cross_m_pingpong`：`sched_init_n(2)`；全局 `g_in`/`g_out`；先 spawn 一个 `noop()` 占掉 round-robin 的 0，再 spawn `ping` 到 M1（`chan_recv(g_in)` → `chan_send(g_out, v+1)`）；main 发送 0、接收 1。
4. `spawn_stress`：`sched_init_n(2)`，1000 次 `ch := go work(i); sum += chan_recv(ch)`，timeout=120。

Expected before implementation: `sched_init_n` 未定义或 hang（timeout）。

- [ ] **Step 2: 修 `m_start_workers`**

`elf.cr::emit_m_start_workers` 与 `rt.s` 同步：

- 去掉 double `inc r12`（只保留 `.Lnext_worker` 或 `.Lworker_loop` 一处）。
- clone flags = `0x10F00 | 0x80000`（`CLONE_SETTLS`）。
- 每个 worker `alloc(32)` 得 TLS block；写 `[0]=-1, [8]=m_idx, [16]=-1, [24]=0`；`r10 = block`。
- 栈顶 `r15 = (base + 65536) & ~15`；`[r15-16]=worker_entry`、`[r15-8]=index`。
- `worker_entry` 继续 `pop rdi`，调用 `sched_worker_run`。

- [ ] **Step 3: spawn 请求分发**

每个 G 固定 home M，且 arena 元数据按 M 分区；因此**不能在 M0 创建 G 再让 M1 跑**。`sched_go` 按 round-robin 选目标 M：目标就是当前 M 时直接创建；否则把请求 push 到目标 M 的 `spawn_head`，由目标 M 创建 G。

在 `sched_init_n` 增加：

```core
MAX_SPAWN_REQ : int = 8192
g_spawn_req_buf : string, mut
g_spawn_req_next : string, mut   # 8-byte atomic counter
g_spawn_rr : string, mut         # 8-byte atomic round-robin counter

g_spawn_req_buf = alloc(MAX_SPAWN_REQ * 32)
g_spawn_req_next = alloc(8)
g_spawn_rr = alloc(8)
# 两处 8 字节清零；这些必须在 m_start_workers 之前完成
```

请求节点 32B：`fn_ptr(0)`、`arg(8)`、`result_ch(16)`、`next(24)`。

`sched_go`：

```core
fn sched_go(fn_ptr: int, arg: int) -> string, pub:
    ch := chan_make(8, 1)
    n := g_machine_count
    target : ., mut = rt_m_idx()
    if n > 1:
        target = rt_atomic_fetch_add(g_spawn_rr, 0, 1) % n
    if target == rt_m_idx():
        saved := rt_current_arena()
        g := g_new(fn_ptr, arg, 0)
        rt_set_current_arena(saved)
        cell_store(g, 40, ch)
        sched_enqueue(g)
    else:
        idx := rt_atomic_fetch_add(g_spawn_req_next, 0, 1)
        if idx >= MAX_SPAWN_REQ:
            # 0A 上限：回退到当前 M 直接创建，保证 go 不丢
            saved := rt_current_arena()
            g := g_new(fn_ptr, arg, 0)
            rt_set_current_arena(saved)
            cell_store(g, 40, ch)
            sched_enqueue(g)
        else:
            req := g_spawn_req_buf + idx * 32
            cell_store(req, 0, fn_ptr)
            cell_store(req, 8, arg)
            cell_store(req, 16, ch)
            cell_store(req, 24, 0)
            sched_push_spawn(target, req)
    return ch
```

`sched_push_spawn(m_idx, req)` 用与 run queue 相同的 tagged Treiber push，只是 M 的 offset 32（`spawn_head`）。tag 规则相同：

```core
fn sched_push_spawn(m_idx: int, req: string):
    m := g_machines + m_idx * 48
    rp : ., mut = 0
    unsafe:
        rp = @ptr_of(req)
    loop:
        old := rt_atomic_load(m, 32)
        tag := old / PTR_MASK + 1
        if tag > TAG_MAX:
            tag = 1
        ptr := old % PTR_MASK
        cell_store(req, 24, ptr)
        newv := tag * PTR_MASK + rp
        if rt_atomic_cas(m, 32, old, newv) != 0:
            return
```

`sched_process_spawns` 的 pop 与 `sched_dequeue` 同形，只是 offset 32、node.next 在 offset 24。请求节点不回收。

`sched_process_spawns(m_idx)`：pop 本 M 的 `spawn_head`；对每个请求：

```core
saved := rt_current_arena()
g := g_new(cell_load(req, 0), cell_load(req, 8), 0)
rt_set_current_arena(saved)
cell_store(g, 40, cell_load(req, 16))
sched_enqueue(g)
```

请求节点不回收（0A 上限 8192；耗尽回退到当前 M）。0C 再做回收/池化。

- [ ] **Step 4: worker loop**

`sched_worker_run(m_idx)`：

```core
loop:
    sched_process_spawns(m_idx)
    sched_reap_dead(m_idx, -1)
    next_g := sched_dequeue(m_idx)
    if next_g >= 0:
        m := g_machines + m_idx * 48
        cell_store(m, 8, next_g)
        g_set_curg(next_g)
        rt_atomic_store(next_g, 8, 1)
        next_cur := cell_load(next_g, 80)
        if next_cur < 0:
            next_cur = cell_load(next_g, 32)
        rt_set_current_arena(next_cur)
        # scheduler 上下文保存到 M.sched_sp（offset 24），再进入 G
        fiber_switch(@ptr_add(m, 24), cell_load(next_g, 16))
        g_set_curg(-1)
    else:
        # 空队列：自旋；0A 不做 futex，0C 再做
        continue
```

- [ ] **Step 5: `sched_schedule`**

```core
fn sched_schedule():
    m_idx := rt_m_idx()
    old_g := sched_get_curg()
    sched_process_spawns(m_idx)
    sched_reap_dead(m_idx, old_g)

    loop:
        sched_process_spawns(m_idx)
        next_g := sched_dequeue(m_idx)
        if next_g >= 0:
            if next_g == old_g:
                if rt_atomic_load(old_g, 8) == 3:
                    # 自己是已退出的 G，但 queue 里留有 spurious wake 的条目：
                    # 丢弃它，继续调度，不能返回到 dead stack。
                    continue
                return
            break
        if old_g < 0:
            # worker 在 scheduler 栈上调用（不应发生）：回到循环
            continue
        if m_idx == 0:
            # main M 没有 scheduler 栈：在自己的 G 栈上自旋，
            # 直到 main G 被 waker push 回来，或队列出现别的 G。
            continue
        # worker 当前 G 阻塞/退出，且没有下一个：回 scheduler 栈
        m := g_machines + m_idx * 48
        cell_store(old_g, 80, rt_current_arena())
        cell_store(m, 8, -1)
        g_set_curg(-1)
        fiber_switch(@ptr_add(old_g, 16), cell_load(m, 24))
        # 被重新调度后返回；waker 已置 runnable
        return

    m := g_machines + m_idx * 48
    cell_store(m, 8, next_g)
    g_set_curg(next_g)
    rt_atomic_store(next_g, 8, 1)
    if old_g >= 0:
        cell_store(old_g, 80, rt_current_arena())
    next_cur := cell_load(next_g, 80)
    if next_cur < 0:
        next_cur = cell_load(next_g, 32)
    rt_set_current_arena(next_cur)
    if old_g >= 0:
        fiber_switch(@ptr_add(old_g, 16), cell_load(next_g, 16))
        rt_set_current_arena(cell_load(old_g, 80))
    # old_g < 0 的首个 G 由 sched_worker_run 处理，不在这里
```

M0 也走同一路径：main G 的 `home_m=0`，只会在 M0 的栈里；M0 空栈时自旋。

- [ ] **Step 6: 跑多 M 测试**

```bash
nice -n 19 python3 tests/selfhost/test_multi_m.py
```

Expected: 4/4 PASS；1000 次 spawn 不超时、不崩溃。

- [ ] **Step 7: 回归并发**

```bash
nice -n 19 python3 tests/selfhost/test_chan_handle_model.py
nice -n 19 python3 tests/selfhost/test_go_arena.py
nice -n 19 python3 tests/selfhost/test_multi_m.py
```

- [ ] **Step 8: 接 CI**

`src/ci/run.sh` 的 `selfhost-tests` 段加：

```bash
python3 tests/selfhost/test_multi_m.py   # 并发 0A：无锁 per-M run queue + SPSC channel
```

- [ ] **Step 9: 提交**

```bash
jj commit -m "sched: enable lock-free multi-M workers and cross-M wake (0A)"
```

---

## Task 6: 文档、TODO、canary 与完整验证

**Files:**
- Modify: `src/stdlib/sched.cr`（头注）
- Modify: `docs/maintainer/design/execution-model.md`
- Modify: `TODO.md`
- Create: `docs/superpowers/implementation/2026-11-01-concurrency-0a.md`
- Maybe modify: `tools/baseline/canary_values.tsv`

- [ ] **Step 1: 改 `sched.cr` 头注**

写明：

```text
0A: multi-M uses per-M lock-free run queues (tagged Treiber stacks) and
home-M-pinned Gs. Channels are SPSC with monotonic head/tail and one
waiter slot per direction; runtime does not use locks. Work stealing,
futex idle, and lock-free proof/validation remain 0C.
```

- [ ] **Step 2: 更新执行模型文档**

`docs/maintainer/design/execution-model.md` 的“实现状态”加：`sched_init_n(n)`、per-M tagged Treiber run queue、home M 固定、spawn 请求分发、SPSC channel、延迟回收、arena per-M 分区；明确 0A 不实现 Transfer Analysis，也不做 work stealing。

- [ ] **Step 3: 更新 TODO**

`TODO.md` 的 `#2026-07-31-1` 追加“2026-11-01 状态”：多 M 已接线；无锁 per-M run queue；spawn 请求 round-robin 分发；SPSC channel；arena per-M 分区；0C 待办 = work stealing、futex idle、SPSC 强制/文档化、wait list 无锁正确性证明、spawn 请求节点回收。

- [ ] **Step 4: 写实现报告**

`docs/superpowers/implementation/2026-11-01-concurrency-0a.md`：改动文件/接口、4 个多 M 测试输出、单 M 回归、未做项（Transfer Analysis、typed message、work stealing、futex、预算/证书）、已知限制（SPSC 约定、main G 固定 M0、每 M arena cap、busy-spin）。

- [ ] **Step 5: 完整验证**

```bash
nice -n 19 CI_JOB_NAME=selfhost-tests src/ci/run.sh
nice -n 19 CI_JOB_NAME=bootstrap-tests src/ci/run.sh
nice -n 19 CI_JOB_NAME=check src/ci/run.sh
```

Expected: 三个 job rc=0。

- [ ] **Step 6: 自举链**

```bash
nice -n 19 CI_JOB_NAME=full-bootstrap src/ci/run.sh
```

Expected: `corec2 == corec3` IDENTICAL，N06=0。

- [ ] **Step 7: canary**

```bash
bash tools/baseline/canary_check.sh
```

若 ELF 因 runtime stub/queue/channel 改变布局而变化：按 `tools/baseline/REBUILD.md` 查明原因，留旧值、写新值，并在报告里说明。不得直接改值表匹配输出。

- [ ] **Step 8: 最终提交**

```bash
jj commit -m "docs: record lock-free concurrency 0A evidence and boundaries"
```

---

## Self-Review

- **Spec coverage:** 0A 的“多 M 启用 / runq / 恢复执行面”由 Task 2/5；“并发运行时验证基础”由 Task 2/3/4 的 SPSC + per-M arena 测试覆盖；0B/1–10 明确排除。
- **Step scan:** 每个任务有失败测试或回归命令、最小实现、验证、提交；没有“适当处理”类步骤。
- **Type consistency:** `rt_m_idx() -> int`、`rt_atomic_load/store/xchg/cas/fetch_add`、`sched_init_n(int)`、`sched_dequeue(int) -> int`、`sched_reap_dead(int,int)`、`arena_init_m(int,int,int)` 在 Task 1～5 中同名同型。
- **Review Focus:** 8 条风险均有对应测试（Task 2/3 等待槽、Task 3 丢失唤醒、Task 2 延迟回收、Task 2 main pin、Task 4 arena 分区、Task 1 原子字段、Task 1 TLS、Task 5 对齐）。
- **Proportion:** 计划给签名、关键算法和测试断言，不转录完整实现。
