# CP-5 实现记录：range go / true multi-M / zero-cap / formal MessageRef

**日期：** 2026-11-04
**状态：** CP-5 的 1/2/4/5 完成。第 2 项现在是真实 OS 线程 multi-M（per-M worker + per-M ready queue + home M 固定），不是 logical multi-activation，也不是用假 worker 顶替。抢占与跨线程原子等待协议仍留 CP-6。
**计划：** `docs/superpowers/plans/2026-11-04-cp5-concurrency-semantics.md`
**规格：** `docs/superpowers/specs/2026-11-01-cross-paradigm-concurrency-design.md`

## 1. Range go

`ir_gen` 的 range go 不再走同步 `IR_SPAWN`：

- 每个 index 调 `conc_go(@addr(f), i)`，handle 存入临时 channel 数组；
- 全部 spawn 后逐 index `chan_recv`，结果写入返回数组；
- `arr := go i 0..3 square(i)` 由 `test_conc_sched_range_go` 验证（0²+1²+2²=5）。

`IR_SPAWN` opcode 保留，但 range go 默认路径已不走它；`test_ccr_types.py` 的旧 `p_spawn` 动态标记语料已随 CP-5 删除（53/53 通过）。

## 2. True multi-M

CP-5 第 2 项完成，映射如下：

- `sched_init_n(n)` 不再把 `n` 收敛到 1，而是保留 `n` 个 M，并额外预留 1 个 arena 分区给共享运行时元数据（见 §2.30）。
- 每个 M 一个 worker 线程；worker 由 `m_start_workers` 用 `clone` 启动，TLS 中带 `m_idx`/`current_arena`/`suspend`。
- 每个 M 一条 ready queue。activation 在 spawn 时按 round-robin 绑定 home M，之后**不迁移**：arena、fiber stack、TLS 只由 home M 的线程访问。
- activation 的 arena 与 fiber stack 在 home M 第一次调度它时惰性创建（`conc_schedule` 的 prepare 段），因此 spawner 不会写别的 M 的 slot 池。
- 控制块、ready queue、channel wait list、scheduler 数组由一把全局 spinlock 保护。锁只覆盖元数据操作，绝不跨 `fiber_switch` 持有。
- worker 空闲时 `sched_yield`；main 线程（M0）在阻塞 send/recv 时也会跑本 M 的 ready queue，因此单 M 与多 M 走同一条调度路径。
- M 之间只通过 channel 的 wait/wake 交互：wait queue 与 ready queue 都在锁内更新，wake 可以把 activation 放回其 home M 的 ready queue。

### 2.30 本次修掉的三个真实阻断

1. **slot 分区不一致（旧 0A 根因）**
   `src/stdlib/arena.cr` 的 `SLOTS_PER_M=1024 / SEGMENTS_PER_M=16` 与 allocator blob（`src/runtime/alloc_body.cr`）编译死的 `slot = m * 256 + count` 不一致。M1 的 slot 256 落在 M0 的 segment 4 上，两个 M 写同一块 1MiB slot，导致随机 segfault / `alloc_fail`。现在 arena.cr 与 blob 统一为 256 slots / 4 segments per M，并在两处加了对齐注释。

2. **worker 上的共享元数据分配**
   allocator 对 `current_arena < 0 && m_idx != 0` 是 fail-closed（exit 132）。旧 conc scheduler 用 `current_arena=-1` 从全局 heap 分配 ready queue / free list / channel state 扩容，这些扩容在 worker 上必然失败。现在新增共享 arena：
   - `sched_init_n(n)` 用 `arena_init_m(..., n + 1)` 预留最后一个分区；
   - `arena_shared_init/arena_shared_alloc` 只在这个分区分配；
   - `conc_sched` 的共享数组、channel region 扩容都走它，调用方已在 conc lock 内。

3. **`g_current_arena` 全局读**
   `ir_gen` 在 merge-plan 里读全局 `g_current_arena`。多 M 下每个 M 的 `arena_set_current` 都写这个全局，读到的是别的 M 的 arena id。现在改为读 TLS `rt_current_arena`。allocator blob 本身早已读 TLS，不受影响。

## 3. Zero-cap rendezvous + MPMC

- `conc_channel_new` 允许 `cap=0`；plan descriptor 仍只接受 `cap>0`。
- cap=0 的 send/recv 使用 activation handoff slot（record +72）：
  - send 遇到 recv waiter：直接写 waiter 的 handoff 并唤醒；
  - recv 遇到 send waiter：直接读 sender 的 handoff 并唤醒；
  - 无对端时阻塞当前 activation；main 线程无 ready 且无对端时返回 0（fail-closed）。
- 多个 waiter 由 per-channel wait queue 支持；`test_conc_sched_rendezvous` 与 `test_conc_sched_mpmc` 覆盖。
- activation 死亡后 arena/stack 回收，id 进入 free list；新 activation 复用 id 与 96B 控制块（不重复分配）。1000 次 `go` 不再撞 arena slot 上限。

## 4. Formal MessageRef descriptor

新增 descriptor API：

```text
conc_ref_alloc(region, size, layout) -> string
conc_ref_ok(ref) -> int
conc_ref_payload(ref) -> string
conc_ref_region/offset/size/layout(ref) -> int
```

descriptor 48B：

```text
0 magic, 8 region_id, 16 offset, 24 size, 32 layout_id, 40 epoch
```

- `conc_ref_ok` 校验 region 活性、epoch、offset/size 边界、消息头 magic/region/epoch/size。
- `conc_region_reset` 后旧 ref 的 epoch 不匹配 → `conc_ref_ok == 0`；同 offset 的新 alloc 不会让旧 ref 复活（epoch 不同）。
- 旧的 raw pointer `conc_alloc/conc_send/conc_recv` 保留兼容；descriptor 是正式身份路径。

## 5. 验证

CP-5 最终 gate（`build_selfhost_native.py` 之后）：

```text
test_conc_sched.py          10/10
test_conc_runtime.py        14/14
test_conc_plan.py            5/5
test_conc_plan_emitter.py   25/25
test_chan_handle_model.py   11/11
test_go_arena.py            PASS
test_multi_m.py              6/6
test_compile.py             PASS
test_ccr_types.py           53/53
test_purity.py              24/24（IR_SPAWN 用例随 range-go 切换删除）
build_kernel.py             PASS
```

multi-M 额外压测（不依赖测试 harness 的重试）：

```text
four_workers_queue     100 次连续通过
eight_workers_queue    20 次连续通过（8 M、512 go）
spawn_stress           30 次连续通过（每次 1000 go）
cross_m_pingpong       重复通过
two_workers_two_goroutines 重复通过
```

`test_multi_m.py` 现在验证的是真实 OS 线程：

- `two_workers_two_goroutines`：2 M 并发执行；
- `four_workers_queue`：4 M、64 个 go；
- `eight_workers_queue`：8 M、512 个 go；
- `cross_m_pingpong`：两个 activation 在不同 M 上经 channel 互 ping；
- `spawn_stress`：2 M 上 1000 次 go。

完整 `selfhost-tests` 的 CP-1..CP-5 gate 在 p41 之前执行。p41 仍是 CP-1 基线 `1e47f93f` 已复现的旧 0A 问题（`run rc=-11`），不是 CP-5 引入。

另有三个与本项无关、在纯净父提交 `34bab32d` 的独立 worktree 中同样失败的用例，已做基线对照：

```text
test_alloc_blob_relocs.py   FAIL: arena_grow_pool missing（测试期望 arena_grow_pool，
                            当前 alloc_body.cr 调用 arena_grow_pool_m）
test_alloc_arena_parity.py  FAIL: tests/suite/arena_test.cr --static rc=-11（基线同样崩溃）
test_alloc_simple_parity.py -- clang 链接缺 rt_m_idx（基线同样失败，环境/工具链问题）
```

这些不是 CP-5 multi-M 引入，也不在 CP-1..CP-5 gate 内。

## 6. 未做（CP-6+）

- 抢占（preemption）与运行时强制让出：当前是协作式，长循环 activation 会占住 home M。
- 跨线程原子等待协议（wait/wake 已跨 M，但没有 futex/原子等待队列，空闲 worker 用 `sched_yield` 轮询）。
- 真实 GPU/FPGA/集群、transfer MOVE/LOAN/SPLIT/FILL、多 slot、预算/证书。
- range go 的正式 plan artifact 提取（默认 runtime 已执行）。
- MPMC plan descriptor（runtime 已支持多 waiter，plan 仍标记 SPSC）。
- descriptor 与 channel send/recv 的正式绑定（当前 descriptor 通过 payload 兼容旧 API）。
- 正式 MessageRef 的 layout/identity table 与跨 region transfer。

## 7. 不变量核对

| 不变量 | CP-5 证据 |
|---|---|
| 不新增源码语法 | range go 仍是原 surface；descriptor 是 stdlib API |
| range go 不再同步近似 | `conc_go` + `chan_recv` 收集，测试通过 |
| 零容量语义 | send/recv handoff + wait queue；rendezvous/MPMC 测试 |
| activation 身份 | id + 控制块 free list 复用；arena/stack 回收；1000 go |
| formal MessageRef | region/offset/size/layout/epoch；reset+reuse ABA 测试 |
| fail-closed | cap0 无对端、descriptor stale、越界均返回 0/空 |
| 真实 multi-M | 真实 clone worker + per-M ready queue + home M 固定；8 M/512 go + 2 M/1000 go 压测 |
| 锁的边界 | 全局 spinlock 只保护共享元数据，不跨 fiber switch；activation 不迁移 |
