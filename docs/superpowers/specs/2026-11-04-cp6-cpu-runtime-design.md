# CP-6 设计：CPU 运行时 1–14 项

**日期：** 2026-11-04
**状态：** 已实施（1–14，host CPU）。实现记录见 `docs/superpowers/implementation/2026-11-04-cp6-cpu-runtime.md`。
**范围：** host CPU（x86-64 Linux 裸 ELF）。真实 GPU/FPGA/集群不在本设计内。
**上位规格：** `2026-11-01-cross-paradigm-concurrency-design.md`、`2026-09-17-concurrency-model-design.md`

## 1. 意图与边界

把 CP-5 留下的 1–14 项在 CPU 映射上做完：抢占、futex 等待、MPMC/range/transfer 的 plan 表达、MessageRef 正式绑定、slot/target/plan v2、预算/证书、确定性执法、DATA_PARALLEL、PIPELINE、旧 runtime 退役。

硬约束：

- 不新增源码语法；transfer/budget/slot 都是 stdlib API 或 plan 旁路字段。
- `.ccr` 的 9 段 wire 不变；plan/证书走旁路文件。
- 无法证明的映射 fail-closed；`unknown` 不渲染为通过。
- activation 仍固定 home M；TLS/arena 不跨 M。
- 信号 handler 内不切 fiber、不拿锁、不分配。

## 2. 交付项与验收

| # | 交付 | 验收 |
|---|---|---|
| 1 | 抢占与强制让出 | 用户并发程序的循环回边插 `conc_preempt_tick`；长循环 activation 不再饿死同 M 的其他 activation；可选的 SIGALRM pending flag 提供异步请求 |
| 2 | futex 等待 | 空闲 worker 用 `futex(202)` park；wake 精确唤醒 home M；无 lost wakeup；忙轮询从热路径移除 |
| 3 | MPMC plan | plan v2 `channel ... MPMC` 可加载/执行；多生产者/多消费者 e2e |
| 4 | descriptor 绑定 | `conc_send_ref`/`conc_recv_ref` 走 MessageRef；旧 raw `conc_send/recv` 与 `chan_send/recv` 保持兼容 |
| 5 | range go plan | range go 生成 PAR body + 结果数组描述；plan 可加载并由 `conc_plan_run_range` 执行；默认 runtime 仍可走 `conc_go` |
| 6 | MessageRef layout/identity | 全局 layout table；跨 region 校验 layout id；reset/复用 ABA 仍成立 |
| 7 | transfer | `conc_transfer_move/loan/split/fill/copy` + plan 记录；源侧失效/归还/子区域 owner 语义在 CPU 上可测 |
| 8 | slot/拓扑 | `sched_init_slots(m_count, slots_per_m)`；plan `slot` 记录；body→slot 映射；CPU slot 层级可见 |
| 9 | TargetProfile/plan 格式 | plan v2 文本含 `target`/`slot`/`transfer`/`budget`/`cert`；版本/目标不匹配 fail-closed |
| 10 | 预算/证书 | 编译期义务 + plan 状态 `proved/unknown/violated/measured`；explain 可见；`unknown` 不当通过 |
| 11 | 确定性执法 | 通道顺序/边冲突检查；违反确定性拒绝或 serial fallback |
| 12 | DATA_PARALLEL | 显式 range go 生成 PAR plan 并由 conc_run_range 执行；普通 for 在没有独立性证明时 serial fallback |
| 13 | PIPELINE | `yield` 是真实 conc yield；PIPE body + executor 落地；emitter 检测 go 目标中的 yield 输出 v2 PIPE plan |
| 14 | 旧 runtime 退役 | 删除 goroutine.cr/g_new/g_free/wrapper/死 sched 队列；保留兼容入口，IR_SPAWN 仅保留 wire 兼容 |

## 3. 关键设计决定

### 3.1 抢占

- `ir_gen` 在**用户库**（`lib_kind == LIB_KIND_USER`）且程序 import 了 `sched/chan/conc` 时，于 `loop`/`while`/`for` 回边前发射 `IR_CALL conc_preempt_tick`。
- `conc_preempt_tick` 每 M 一个 quantum 计数；到 0 调 `conc_yield`。无 activation 上下文直接返回。
- 允许 SIGALRM handler 只写 `g_conc_preempt_flag`；tick 看到 flag 立即让出。handler 不切 fiber。
- `conc_preempt_tick` 对纯度分析是透明的（mark pure），避免污染 region plan。
- 编译器/stdlib 自身不插 tick，避免锁内重入。

### 3.2 futex

- 每 M 一个 64-bit sequence word，位于 shared arena。
- worker 无活时：加锁检查 ready queue；空则读取 seq，解锁，`futex_wait(seq_addr, seq)`。
- waker 在 ready push 后（仍在锁内）递增 seq，再 `futex_wake(seq_addr, 1)`。
- main 在阻塞 send/recv 无 ready 可跑时同样 park 到 M0 的 seq。
- 不使用 `sched_yield` 忙等；`syscall3(24)` 只保留给 spinlock 的短暂退让。

### 3.3 plan v2

文本格式版本升级到 `v 2`，v1 loader 继续可读。新增行：

```text
target <name> <slots> <memory_spaces>
slot <id> <kind> <parent> <count>
channel <id> <elem> <cap> SPSC|MPMC BOUNDED|UNBOUNDED
range <body> <start> <count>
transfer <id> <kind> <src_region> <dst_region> <size>
budget <id> <kind> <bound> <status>
cert <id> <kind> <status>
```

`.ccr` 不变；所有新字段只进旁路 plan。

### 3.4 MessageRef / transfer

- channel descriptor 增加 `ref_mode` 位；`conc_send_ref`/`recv_ref` 传输 48B descriptor，接收端用 `conc_ref_ok` 校验。
- transfer API 不新增语法：`conc_transfer_move(src_ref, dst_region)` 等；源侧失效通过 region epoch + owner 位记录。
- SPLIT 返回子 region/子 ref 数组；FILL 预留目标后由生产方写；COPY 仅复制 CopySet（保守实现：整个 payload）。

### 3.5 分析

- 预算/确定性/DATA_PARALLEL 都是 IR/DF 后置 pass，位置在 `region_check_all` 之后、`lower_to_ccr` 之前。
- 新 pass 失败用 `check_error` fail-closed；不写 `.ccr`。
- DATA_PARALLEL 只识别 `for` 循环；独立性 = 迭代变量仿射 + body 对共享位置无写 + 调用纯；否则 serial。
- PIPELINE 以 `flow` 函数为 body，`yield` 点作为 stage 边界；CPU 映射为 round-robin stage 执行。

### 3.6 旧 runtime 退役

- 保留 `m_start_workers`；`sched_worker_run` 直接委托 `conc_worker_run`。
- 删除 `g_new`/`g_free`/`goroutine.cr`、`goroutine_entry_wrapper`、backend 的 `goroutine_wrapper_addr` 特判、死 `sched_enqueue/dequeue/reap/yield/schedule/push_spawn/process_spawns/sched_go_direct` 与旧 G 队列全局。
- 保留 `sched_init/sched_init_n/sched_init_slots/sched_go/sched_get_curg` 作为兼容入口。
- `IR_SPAWN` 保留 wire/解释器兼容，但编译器不再发射。

## 4. 实施批次

- **批次 A（1–2）**：抢占 tick + futex park/wake。测试：`test_conc_preempt.py`。
- **批次 B（3–9）**：plan v2、MPMC、range plan、descriptor 绑定、layout/identity、transfer、slot、target 格式。测试：扩 `test_conc_plan*.py`、`test_conc_runtime.py`。
- **批次 C（10–14）**：预算/证书、确定性、DATA_PARALLEL、PIPELINE、旧 runtime 退役。测试：`test_conc_plan_v2.py`、`test_conc_preempt.py`、`test_conc_transfer.py` + 既有 gate。

每批完成后跑 CP-1..CP-5 gate，再跑 `selfhost-tests` 的对应子集；只有已知 p41/三例基线红允许保留。

## 5. 非目标

- 真实 GPU/FPGA/集群后端。
- 跨 memory space 的物理 MOVE/LOAN 预算记账（CPU 上以 region 语义验证）。
- 实验 shared mapping 与 shared-memory 死锁证书。
- 新源码关键字/语法。
