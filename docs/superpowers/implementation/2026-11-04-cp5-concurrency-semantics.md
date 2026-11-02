# CP-5 实现记录：range go / zero-cap / formal MessageRef

**日期：** 2026-11-04
**状态：** CP-5 的 1/4/5 完成；第 2 项只完成单线程 logical multi-activation，true OS-thread multi-M/抢占/跨线程原子等待仍 blocked（CP-6）。
**计划：** `docs/superpowers/plans/2026-11-04-cp5-concurrency-semantics.md`
**规格：** `docs/superpowers/specs/2026-11-01-cross-paradigm-concurrency-design.md`

## 1. Range go

`ir_gen` 的 range go 不再走同步 `IR_SPAWN`：

- 每个 index 调 `conc_go(@addr(f), i)`，handle 存入临时 channel 数组；
- 全部 spawn 后逐 index `chan_recv`，结果写入返回数组；
- `arr := go i 0..3 square(i)` 由 `test_conc_sched_range_go` 验证（0²+1²+2²=5）。

`IR_SPAWN` opcode 保留，但 range go 默认路径已不走它；`test_ccr_types.py` 的旧 `p_spawn` 动态标记语料已随 CP-5 删除（53/53 通过）。

## 2. Multi-M 状态

- 当前 conc scheduler 仍是单线程协作式：一个 ready queue、一个 current activation、无抢占、无跨线程原子等待。
- `sched_init_n(n>1)` 在 CP-4/5 收敛为 `n=1`，不启动旧 multi-M worker；`test_multi_m.py` 的 5 个用例现在验证的是 logical multi-activation（含 1000 go spawn_stress），不是 OS-thread multi-M。
- true multi-M / 抢占 / 跨线程 channel 协议仍受旧 0A 阻断，留 CP-6。本次没有用假 worker 或全局锁冒充 multi-M。

## 3. Zero-cap rendezvous + MPMC

- `conc_channel_new` 允许 `cap=0`；plan descriptor 仍只接受 `cap>0`。
- cap=0 的 send/recv 使用 activation handoff slot（record +72）：
  - send 遇到 recv waiter：直接写 waiter 的 handoff 并唤醒；
  - recv 遇到 send waiter：直接读 sender 的 handoff 并唤醒；
  - 无对端时阻塞当前 activation；main 线程无 ready 且无对端时返回 0（fail-closed）。
- 多个 waiter 由 per-channel wait queue 支持；`test_conc_sched_rendezvous` 与 `test_conc_sched_mpmc` 覆盖。
- activation 死亡后 arena/stack 回收，id 进入 free list；新 activation 复用 id。1000 次 `go` 不再撞 arena slot 上限。

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

```text
test_conc_sched.py          10/10
test_conc_runtime.py        14/14
test_conc_plan.py            5/5
test_conc_plan_emitter.py   25/25
test_chan_handle_model.py   11/11
test_go_arena.py            PASS
test_multi_m.py              5/5
test_compile.py             PASS
test_ccr_types.py           53/53
test_purity.py              24/24（IR_SPAWN 用例随 range-go 切换删除）
build_kernel.py             PASS
```

完整 `selfhost-tests` 中 CP-1/2/3/4/5 gate 在 p41 前执行并通过：

```text
PASS test_selftest_purity_all_pass
PASS conc_region ... PASS conc_negative      14/14
PASS emitter_fixture ... PASS emitter_fail_closed_preexisting  25/25
PASS conc_plan_load ... PASS conc_plan_e2e    5/5
PASS conc_sched_channel_arg ... PASS conc_sched_native_build  10/10
PASS spawn_stress                              5/5

FAIL test_p41_dynamic_string_arena_switch_path: run rc=-11
44/45 passed
CI_EXIT=1
```

p41 仍是 CP-1 基线的旧 0A 问题，不是 CP-5 引入。

## 6. 未做（CP-6+）

- true OS-thread multi-M、抢占、跨线程原子/等待协议。
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
| activation 身份 | id free list 复用；arena/stack 回收；1000 go |
| formal MessageRef | region/offset/size/layout/epoch；reset+reuse ABA 测试 |
| fail-closed | cap0 无对端、descriptor stale、越界均返回 0/空 |
| 不冒充 multi-M | 明确记录单线程 scheduler；multi-M 留 CP-6 |
