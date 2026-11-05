# CP-4 实现记录：默认 conc runtime + 协作调度

**日期：** 2026-11-03
**状态：** CP-4 前四项完成：多 channel plan binding、worker send/recv edge、阻塞 send/recv + fiber 协作调度、默认 `go`/`chan` 切换。
**计划：** `docs/superpowers/plans/2026-11-03-cp4-default-conc-runtime.md`
**规格：** `docs/superpowers/specs/2026-11-01-cross-paradigm-concurrency-design.md`

## 1. 交付

| 文件 | 内容 |
|---|---|
| `src/stdlib/conc_sched.cr` | 单线程协作 activation scheduler：ready queue、per-channel wait queue、fiber_init/fiber_switch、arena save/restore、阻塞 int send/recv、close |
| `src/compiler/ir_gen.cr` | 单 `go` 从 `sched_go` 切到 `conc_go` |
| `src/stdlib/sched.cr` | `sched_init` 初始化 conc scheduler；`sched_go` 委托 `conc_go` |
| `src/stdlib/chan.cr` | `chan_make/send/recv/close` 委托 conc/conc_sched |
| `src/compiler/conc_plan_emit.cr` | 多 `chan_make` handle 映射、`go` 实参→channel id、worker body RECV/SEND edge |
| `src/runtime/rt.s` | 加入 native `sched_call_0..4` trampolines（编译器自身链接用） |
| `bootstrap/corec/frontend/*` | bootstrap prelude 认识 `sched_call_0..4` |
| `build_kernel.py` | 纳入 `conc.cr` / `conc_sched.cr`，kernel 构建恢复 |
| `src/compiler/ir_gen.cr` | `import sched/chan/conc` 自动 raw-int，`corec build` 不再要求手动 `--raw-int` |

## 2. 调度模型

- 每个 activation 有独立 fiber stack、arena、entry、arg、result channel。
- `conc_spawn` 入 ready queue；`conc_schedule` 在 scheduler/fiber 之间用 `fiber_switch` 切换。
- 每个 activation 保存/恢复 `arena_current_unchecked()`；`test_go_arena` 验证主 arena 不被 activation 改写。
- activation 死亡后 scheduler 立即 `arena_reset(aid)`，释放 fiber stack/arena slot；1000 次 `go` 不再撞 arena slot 上限。
- `sched_init_n(n>1)` 在 CP-4 单线程 conc mapping 下收敛为 `n=1`，不再启动旧 multi-M worker 线程。
- channel 满/空时，当前 activation 进入 per-channel wait queue；对端 send/recv 唤醒一个 waiter。
- `close` 标记 closed 并唤醒所有 waiter；recv 先排空再返回 0。
- 主线程不是 activation：在空 result channel 上 `chan_recv` 时调用 `conc_schedule` 推进 ready activation；无 ready 且无数据时返回 0（fail-closed）。
- `chan_make` 大容量（如 `cap=200000`）超过默认 1 MiB region 时，按需求创建专用 region；不再静默返回空 handle。
- `import sched` / `import chan` / `import conc` 的源自动置 raw-int，`corec build` 可直接编译 `go`/`chan` 程序。
- 无锁、无原子、单线程；不宣称线程安全。

## 3. 多 channel / edges

`corec conc-plan` 现在：

- 每个 `chan_make` 后第一条 handle store 建立 `channel id -> 用户变量`。
- `go` 实参追溯到某个 handle 后，plan 发 `bind 1 0 <id>`、`edge 0 1 SEND <id>`。
- worker body 中 `chan_recv(param)` / `chan_send(param, ...)` 发 `RECV` / `SEND` edge（同一 bound channel）。
- 多 channel plan 例：
  ```text
  channel 0 8 2 SPSC
  channel 1 8 1 SPSC
  bind 1 0 1
  edge 0 1 SEND 1
  edge 1 0 RECV 1
  edge 0 1 SPAWN -1
  ```
- 仍只支持单 `go`；多 `go` 的 plan emitter 留 CP-5。默认 runtime 已支持多 `go`（`go_parallel` 与 `test_conc_sched_two_go`）。

## 4. 验证

```text
test_conc_plan_emitter.py   25/25
test_conc_plan.py            5/5
test_conc_runtime.py        13/13
test_conc_sched.py           7/7
test_chan_handle_model.py   11/11
test_go_arena.py            PASS
test_rt_tls.py              PASS
test_compile.py             PASS
test_multi_m.py              5/5
build_kernel.py             PASS
```

`test_chan_handle_model` 覆盖 `chan_test`、`conc_test`、`go_e2e`、`go_final`、`go_parallel`；全部 run rc=0。`test_conc_sched` 覆盖：

- `go worker(req)` 传 channel handle；
- cap=1 上连续两次 `chan_send` 的阻塞/唤醒；
- 两个 `go` 的结果 channel；
- `cap=200000` 大 channel；
- 无 `sched_init` 的 `go`（lazy arena init）；
- 1000 次 `go` + arena 回收；
- `corec build --static` 原生构建（自动 raw-int）。

完整 `selfhost-tests` 中 CP-1/2/3/4 gate 先执行并通过：

```text
PASS conc_region ... PASS conc_negative        13/13
PASS emitter_fixture ... PASS emitter_fail_closed_preexisting  25/25
PASS conc_plan_load ... PASS conc_plan_e2e      5/5
PASS conc_sched_channel_arg ... PASS conc_sched_native_build  7/7
PASS spawn_stress（test_multi_m）                              5/5

FAIL test_p41_dynamic_string_arena_switch_path: run rc=-11
44/45 passed
CI_EXIT=1
```

p41 仍是 CP-1 基线 `1e47f93f` 上已复现的旧 0A 问题，不是 CP-4 引入。

## 5. 边界（CP-5+）

- range `go var start..end` 仍是 `IR_SPAWN` 同步近似，未接 conc scheduler。
- 多 `go` 的 plan emitter（默认 runtime 已支持）。
- multi-M、抢占、跨线程原子/等待协议。
- 真实 GPU/FPGA/集群、transfer MOVE/LOAN/SPLIT/FILL、多 slot、预算/证书。
- 零容量 rendezvous/MPMC；close 已有基本实现。
- 正式 MessageRef `(region_id, offset, layout)` 与 reset+复用 ABA。
- activation id 不复用；已死 activation 的 arena/stack 已回收，但 id/指针表槽位不复用。
- range `go var start..end` 仍走 `IR_SPAWN` 同步近似。

## 6. 不变量核对

| 不变量 | CP-4 证据 |
|---|---|
| 不新增源码语法 | 默认 surface 仍是 `go`/`chan_*` |
| 默认路径切换 | `ir_gen` 单 `go` -> `conc_go`；`chan.cr`/`sched.cr` 委托 |
| 无锁 | `conc_sched.cr` 无 mutex/atomic/spin；单线程 ready/wait queue |
| 编译期事实不复算 | plan emitter 发 bind/edges；runtime 只按 descriptor 执行 |
| fail-closed | emitter 多 go/非法 handle/嵌套/字面量参数拒绝；loader 越界/短表/edge channel 拒绝 |
| 默认语料回归 | `test_chan_handle_model` 11/11、go_arena、rt_tls、compile |
