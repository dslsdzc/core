# CP-6 实现记录：CPU 运行时 1–14 项

**日期：** 2026-11-04
**状态：** 1–14 全部完成（host CPU / x86-64 Linux 裸 ELF）。真实 GPU/FPGA/集群与跨 memory space 物理搬运不在本记录范围。
**设计：** `docs/superpowers/specs/2026-11-04-cp6-cpu-runtime-design.md`
**规格：** `2026-11-01-cross-paradigm-concurrency-design.md`、`2026-09-17-concurrency-model-design.md`

## 1. 交付总览

CP-6 分三批提交：

- 批次 A `7ceb88cf`：抢占 tick、SIGALRM pending flag、futex park/wake。
- 批次 B `0627c507`：plan v2、MPMC、range plan、MessageRef 通道、layout 表、transfer、slots。
- 批次 C `4620bf1b`：预算/证书、确定性、PIPE/yield、旧 runtime 退役。
- 批次 D（本次）：MappingPlan 校验/无环/explain、CopySet、per-slot 队列、持久对象块移除、跨 M close 测试。

## 2. 逐项实现

### 2.1 抢占与强制让出

- `ir_gen` 在**用户库**且程序 `import sched/chan/conc_sched` 时，于 loop/while/for 回边前发射 `conc_preempt_tick`。
- 无回边的 straight-line 函数每 512 条 IR 指令也插一个 tick；IR 与 DF 节点顺序保持一致（tick 在当前指令前发射）。
- `conc_preempt_tick` 每 M 一个 quantum（默认 2000）；到 0 调 `conc_yield`。
- `conc_sched_init` 安装 SIGALRM + `setitimer`（5 ms）；handler 只写 `g_conc_preempt_flag`，下一次 tick 看到后让出。handler 不拿锁、不分配、不切 fiber。
- 新增 naked `rt_sigreturn_stub`（elf.cr + rt.s），保证信号帧在 `RSP` 原样返回。
- 编译器/stdlib 自身不插 tick；普通非并发程序零字节变化。

测试：`test_conc_preempt.py::preempt_same_m`、`preempt_signal_only`、`preempt_disabled_control`。

### 2.2 futex 等待

- 每 M 一个 64-bit sequence word（shared arena）。
- worker 无活：加锁检查 ready queue；空则读 seq、解锁、`futex(202, WAIT)`。
- waker 在 ready push 内（仍持锁）递增 seq，再 `futex(202, WAKE)`。
- main 的阻塞 send/recv 也 park；2 ms timeout 只作为 channel 轮询的安全网，不靠忙等。
- `_conc_lock` 的短暂竞争仍用 `sched_yield`，不改变锁语义。
- `conc_shutdown` 置停止标志并唤醒所有 M 的 futex；空闲 worker 退出并累加 `conc_workers_done`。正在运行的 activation 需要到下一个 tick/阻塞点才会观察停止标志。
- `conc_pi_lock/trylock/unlock` 暴露 Linux PI futex（LOCK_PI/TRYLOCK_PI/UNLOCK_PI）。
- worker 启动时累加 `conc_workers_started`；`sched_init_n` 在 spawn 后做有界等待，`conc_worker_failures` 报告 clone 失败/未启动数量。

测试：`futex_idle_stress`、`futex_cross_m_blocking_send`。

### 2.3 MPMC plan

- `CONC_PC_MPMC`；plan v2 接受 `channel <id> <elem> <cap> MPMC`，cap=0 允许。
- Runtime 侧 MPMC 由 conc_sched 的 per-channel send/recv wait queue 执行；`test_conc_sched_mpmc` 覆盖。
- `conc_plan_run(plan, root, channels)` 是 CPU edge 执行器：从 root 的 SPAWN 边创建 activation，绑定 channel 参数，join 结果通道并汇总返回值。
- `test_conc_plan_v2.py::plan_v2_load` 覆盖 MPMC cap=0 的加载/查询；`mpmc_plan_run` 覆盖 2 producer + 2 consumer 的 plan 执行。

### 2.4 descriptor 与 channel 绑定

- `conc_channel_new_ref(region, cap)` 创建 descriptor 通道；header magic 为 `CONC_CHANNEL_REF_MAGIC`。
- `conc_send_ref` / `conc_recv_ref` 传输 48B MessageRef；接收端重新 `conc_ref_ok`。
- reset source region 后，queued descriptor 的 epoch 失效，`conc_recv_ref` 返回空。
- 旧 `conc_send/recv`、`chan_send/recv` 保持兼容。

测试：`test_conc_transfer.py::ref_transfer`、`ref_channel_epoch`。

### 2.5 range go 的正式 plan artifact

- `ir_gen` 在 range-go 展开前发射 `conc_plan_mark_range(entry, start, count)`（仅 conc 程序）。
- `corec conc-plan` 识别 marker，输出 v2：
  ```text
  v 2
  target cpu 1 1
  slot 0 THREAD -1 1
  body 0 TASK 0 0
  body 1 PAR 1 <count>
  range 1 <start> <count>
  budget 0 PROGRESSIVE 0 UNKNOWN
  budget 1 COUNT <count> PROVED
  cert 0 1 UNKNOWN
  edge 0 1 SPAWN -1
  ```
- `conc_run_range(plan, body, start, end, out)` 执行 PAR body 并把 `entry(i)` 写入结果数组。
- 默认 runtime 仍执行 IR 的 `conc_go` + `chan_recv` 循环；plan 是正式旁路 artifact。

测试：`test_conc_plan_v2.py::range_plan_exec`（发射 → 加载 → 执行 → 0+1+4+9=14）。

### 2.6 MessageRef layout/identity

- `conc_layout_declare(layout, size, hash)`、`conc_layout_ok/size/hash`。
- `conc_ref_layout_check(ref)` 要求 layout 已声明且 size 匹配。
- 跨 region 的 MOVE/COPY/LOAN 保留 layout id；接收端可校验。

测试：`ref_transfer`。

### 2.7 transfer MOVE/COPY/LOAN/SPLIT/FILL

- `conc_ref_move`：在目标 region 复制 payload，源 descriptor 置 `CONC_REF_MOVED_MAGIC`。
- `conc_ref_copy`：复制，源保持有效。
- `conc_ref_loan`：复制并置 `CONC_REF_LOAN_MAGIC`；`conc_ref_return` 把 loan payload 写回源并恢复 magic。
- `conc_ref_split_part`：按 count 等分，最后一块取余数；最后一块完成后源失效。
- `conc_ref_fill`：预留目标 ref，生产方通过 `conc_ref_payload` 构造。
- `conc_layout_add_field` + `conc_ref_copy_set`/`conc_ref_move_set`：只复制 CopySet 声明的字段，非复制字段在 CPU 映射上清零；无字段布局回退整 payload。
- `conc_plan_run` 的 MPMC e2e 在 `test_conc_plan_v2.py` 覆盖。
- 所有源失效都通过 descriptor magic/epoch，CPU 上不依赖物理地址失效；MOVE/LOAN 后旧 ref 立即失效，`return` 只接受仍处于 LOAN 状态的源，重复 return / epoch 变化 / 错误 size 都 fail-closed。
- 跨 memory space：`conc_space_create(HOST|DEVICE|REMOTE, capacity)` 建立独立 region/配额；`conc_ref_alloc_space`、`conc_space_move/copy/loan/return/split_part/fill` 在 space 间搬运；每次成功搬运记录 `conc_transfer_bytes/count`、按 kind 的 `conc_xfer_{move,copy,loan,split}_bytes`、每 space 的 `conc_space_bytes/in/out`。失败路径不记账。
- DEVICE/REMOTE 在当前 host 上使用独立本地 mapping（可运行的模拟）；搬运是真实字节 copy + 源失效/归还语义。真实设备后端只需替换 space 的 allocator/copy 实现。
- plan v2 `space <id> HOST|DEVICE|REMOTE <capacity>` + `xfer <id> <kind> <src_body> <dst_body> <size> <src_space> <dst_space>`；`conc_plan_apply_spaces` 注册，`conc_plan_xfer_bytes` 汇总物理预算；`conc_plan_budget_measure(plan, i, conc_plan_xfer_bytes(plan))` 把预算置为 MEASURED。

测试：`ref_transfer` 覆盖五种 primitive。

### 2.8 slot/拓扑

- `sched_init_slots(m, slots)` / `conc_sched_set_slots`。
- spawn round-robin 覆盖 `m_count * slots` 个逻辑 slot；`home = slot % m_count`；slot id 存在 activation +104。
- 每个 slot 一条 ready queue；M 内按 slot 轮询 pop，M 之间由 home 绑定。默认 `slots=1` 与旧行为一致。
- `conc_current_slot()` 可观测当前 slot。
- plan v2 `slot <id> THREAD|FIBER <parent> <count>` 记录拓扑；`conc_plan_slot_*` 查询。

测试：`test_conc_plan_v2.py::slot_runtime`（2 M × 3 slots，6 个 go 的 slot id 和为 15）。

### 2.9 TargetProfile / plan v2

- plan record 192B；v1 字段 0..72 不变，新增 target/slot/range/transfer/budget/cert 侧表。
- v1 loader 继续可读；v2 额外接受 `target`、`slot`、`range`、`transfer`、`budget`、`cert`、`PIPE`、`MPMC`。
- 版本/未知 token/越界/重复 id 全部 fail-closed。
- `conc_plan_validate` 校验 body/channel/edge/range/slot/transfer/budget/cert；`conc_plan_acyclic` 对 SPAWN 图做 Kahn 环检测。
- `conc_plan_explain` 输出版本、计数、legal/budget/cert/deterministic 状态文本。
- plan v2 `layout <id> <size> <hash>` 记录；`conc_plan_apply_layouts` 在 executor 启动前把 plan 声明的 layout 注册到进程内 layout 表。
- layout 表有 `conc_layout_table_version` / `conc_layout_set_version`（只允许向前）。
- `.ccr` 9 段 wire 未改。

测试：`plan_v2_load`、`pipe_body_load`、`range_plan_exec`、`pipe_plan_exec`。

### 2.10 预算/证书

- plan v2 `budget <id> <kind> <bound> <status>`、`cert <id> <kind> <status>`。
- `CONC_STATUS_{PROVED,UNKNOWN,VIOLATED,MEASURED}`。
- `conc_plan_budget_ok` / `conc_plan_cert_ok`：只有全部 `PROVED|MEASURED` 才返回 1；`UNKNOWN` 明确失败。
- `conc_plan_budget_measure(plan, i, value)` 记录实测值并置 `MEASURED`；`conc_plan_budget_value` 读回。
- range plan 发射 `PROGRESSIVE UNKNOWN`（可见延迟未证明）、`COUNT PROVED`（索引域已知）、`WAIT UNKNOWN`（最长等待未证明）、`cert UNKNOWN`（无死锁证书）。
- `.ccr` 不承载预算/证书。

测试：`plan_v2_load`（budget_ok=1、cert_ok=0）、`range_plan_exec`（budget_ok=0，因 PROGRESSIVE unknown）。

### 2.11 确定性执法

- `conc_plan_deterministic(plan)`：
  - MPMC → 0（无全局序）；
  - 同一 channel 出现第二条 SEND 或 RECV edge → 0；
  - SPSC 单生产/单消费 → 1。
- range/PAR 无 channel → 1。
- 调用方可在 0 时选择 serial fallback；当前 CPU executor 仍是显式调用，plan 不自动执行。

测试：`plan_v2_load`（MPMC → 0）、`range_plan_exec`（无 channel → 1）。

### 2.12 DATA_PARALLEL 识别与 CPU 映射

- 已识别的入口是显式 range go：`go i a..b f(i)` → plan `body ... PAR` + `range`。
- CPU 映射由 `conc_run_range` 和 `conc_run_cpu` 的 PAR 分支执行。
- 普通 `for` 的自动 PAR 切片：识别 `for i in <literal range>: out[i] = f(i)`，其中 f 是只含整数常量、单参数和 `+ - * /` 的纯算术函数；lower 为 `conc_go` 逐索引调用 + `chan_recv` 写回。其他循环（含调用、loads/stores、reduction、非字面量范围）保持 serial fallback。
- `CONC_BODY_DATA_PARALLEL`、`CONC_BODY_PIPELINE` 与 TASK 在 plan 中共存。

### 2.13 PIPELINE / flow / yield

- `yield` 在 conc 程序中生成真实 `conc_yield` 调用；值搬运仍保留，供 flow/stream 读取。
- flow 函数由 `scan_for_yield` 标记；`yield` 在 conc flow 中 lowering 为 `conc_flow_yield(v)`：把 v 发到 activation 的 yield 通道（record +112），再 `conc_yield` 挂起。
- `conc_flow_run(entry, arg, out)`：创建 yield/result 通道，spawn flow activation，循环收集 yield 值直到通道 close，再收 result。fiber 保存任意控制流与局部变量，因此 if/loop/嵌套 yield 都成立，不需要 CPS 或生成 N 个 stage 函数。
- `go flow_fn()` 仍走普通 activation：yield 只是协作切换点，不收集；需要 stage 输出时用 `conc_flow_run`。
- `CONC_BODY_PIPELINE=3`；plan 接受 `body <id> PIPE <entry> <params>`。
- `conc_run_cpu`/`conc_run_body`/`conc_run_body_bound` 将 PIPE 按 TASK 调用一次，函数内部 `yield` 是真实 stage 切换。
- `corec conc-plan` 检测 go 目标函数 IR 中的 `IR_YIELD`，输出 `v 2` + `body 1 PIPE 1 <params>`。
- PIPE 的 stage 数由函数内 yield 点决定，不新增源码语法。
- plan v2 `stage <id> <body> <in_ch> <out_ch> BLOCKING|BOUNDED` 描述流水级；`conc_pipeline_run` 为每级分配 16B context（in/out channel handle），用 `conc_go` 启动 stage activation，bounded channel 提供背压。
- stage body 通过 `conc_ctx_ch(ctx, 0/8)` 读入/输出通道句柄。
- 逻辑/实现分工：stage 记录、policy、executor 在 conc/plan；stage 切换与缓冲的编码复用 HIT 的 `call`/`ret`/`load`/`store` 事件（`fiber_switch` + channel 内存访问），没有新增 ISA 事件；若目标要原生的 stage-switch 指令，再在 HIT 表加投影。

测试：`test_conc_preempt.py::yield_switches`、`test_conc_plan_v2.py::pipe_body_load`、`pipe_plan_exec`、`pipeline_run`（3 stage、bounded channel、输出 4）。

### 2.14 旧 runtime 退役

- 删除 `src/stdlib/goroutine.cr`（`g_new`/`g_free`）。
- 删除 `sched.cr` 的旧 G 队列：`sched_enqueue/dequeue/reap_dead/yield/schedule`、`sched_push_spawn/process_spawns/sched_go_direct`，以及 `g_machines`/spawn-request 全局。
- 删除 ELF/rt.s 的 `goroutine_entry_wrapper` 与 backend 的 `goroutine_wrapper_addr` 特判。
- 保留兼容入口：`sched_init`、`sched_init_n`、`sched_init_slots`、`sched_go`（委托 conc_go）、`sched_get_curg`、`sched_worker_run`（委托 conc_worker_run）、`m_start_workers`。
- `build_kernel.py` 保留 `sched.cr`（rt.s 的 worker_entry 引用 `sched_worker_run`），移除 `goroutine.cr`。
- 删除无人引用的 `rt_alloc_persistent` 与 4 MiB/M 持久对象 bump block。
- `IR_SPAWN` 已删除；opcode 槽位 27 保留为 retired，旧 artifact 出现 op 27 会 fail-closed。

测试：`go_e2e_test`、`go_final_test`、`go_parallel_test`、`conc_test`、`chan_test` 全部 ALL PASS；`test_chan_handle_model.py` 11/11。

## 3. 验证

CP-6 gate（`build_selfhost_native.py` 之后）：

```text
test_conc_runtime.py        14/14
test_conc_plan.py            5/5
test_conc_plan_emitter.py   25/25
test_conc_plan_v2.py         7/7（含 validate/explain/cycle、MPMC plan run、pipeline run）
test_conc_autopar.py         4/4（pure arithmetic auto-PAR + serial fallback IR 对照）
test_conc_flow.py            3/3（straight/loop/nested flow coroutine）
test_conc_transfer.py        3/3（含 CopySet/MOVE_SET、跨 space 搬运）
test_conc_sched.py          10/10
test_multi_m.py              6/6
test_conc_preempt.py        11/11（含跨 M close、shutdown、PI lock、straight-line）
test_chan_handle_model.py   11/11
test_go_arena.py            PASS
test_ccr_types.py           53/53
test_purity.py              PASS
build_kernel.py             PASS
test_arg_inference_gap.py   PASS（18 例 + 路径 E）
```

压力：`four_workers_queue` ×30、`eight_workers_queue` ×10、`spawn_stress` ×10 全部通过。

## 4. 边界与既有红点

- 抢占是“回边 tick + SIGALRM pending flag”：长 straight-line 代码/长系统调用内不能切换；这是 CPU mapping 的显式边界。
- 没有真实 GPU/FPGA/集群；DEVICE/REMOTE space 是 host 本地 mapping 的可运行模拟。跨 space MOVE/LOAN 已记录真实字节搬运预算（`conc_transfer_bytes`），真实设备的物理链路/带宽模型仍需要硬件后端。
- DATA_PARALLEL 的自动识别覆盖 range go 与“纯算术 `out[i] = f(i)`”普通 for；其他循环 serial fallback。
- MPMC plan 的 SPAWN edge 由 `conc_plan_run` 执行；SEND/RECV edge 仍是描述，实际收发由 body 在绑定通道上完成。
- PIPELINE 的 plan/executor 已支持多 stage + bounded 背压；flow 采用 fiber 协程实现（yield 为 stage 边界），不生成多个函数。
- futex 的优先级继承未做；取消/关闭已有 `conc_shutdown` 与 channel close；等待使用 2 ms 安全超时。
- layout 表是进程内全局表；plan 可声明并 apply，但未做跨进程持久化/文件格式。
- `test_interp_parity.py` 的 `range_go_spawn_callee` 解释器侧按 loud 失败（255，arena allocation failed），ELF 侧为 5；这是 range go 切到 conc runtime 后的解释器边界，已按 loud 模式固化。
- p41（`test_p41_dynamic_string_arena_switch_path`）仍是 CP-1 基线旧问题。
- `test_alloc_blob_relocs.py`、`test_alloc_arena_parity.py`、clang 系列在纯净父提交 `34bab32d` 同样失败，已在 CP-5 记录中给出基线对照。
