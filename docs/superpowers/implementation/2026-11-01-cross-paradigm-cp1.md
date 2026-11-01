# CP-1 实现记录：跨范式并发 runtime 基底

**日期：** 2026-11-01
**状态：** CP-1 runtime substrate 完成；compiler plan emitter 与真实目标映射留 CP-2。
**计划：** `docs/superpowers/plans/2026-11-01-cross-paradigm-cp1-runtime-substrate.md`
**规格：** `docs/superpowers/specs/2026-11-01-cross-paradigm-concurrency-design.md`

## 1. 交付内容

| 文件 | 变化 |
|---|---|
| `src/stdlib/conc.cr` | 新增 CP-1 runtime：owner region、typed MessageRef channel、fixture plan、CPU/SIMT 执行器 |
| `tests/selfhost/test_conc_runtime.py` | 新增 7 例：region、channel、plan、CPU、SIMT（CPU/SIMT 同 plan 对拍）、lifetime、negative |
| `src/ci/run.sh` | `selfhost-tests` 接入 `test_conc_runtime.py` |
| `src/format/elf/elf.cr` | 修正 `sched_call_N` trampoline 的表项寻址与 Phase 3 偏移更新 |

## 2. 对象模型

### 2.1 Owner region

- `conc_region_new(size)` 从全局 heap 分配 region block，返回 region id。
- `conc_alloc(region, size)` 是 16 字节对齐的 bump 分配；每个 payload 前有 32 字节消息头：
  - `0 magic`
  - `8 region id`
  - `16 epoch`
  - `24 Core string length (size + 1)`
- `conc_region_reset(region)` 把 cursor 归零并递增 epoch。
- `conc_send` 校验消息头、region 活性和 epoch；reset 前的 MessageRef 在 reset 后会被拒绝，不会静默读到新数据。
- region block、channel、plan、消息 payload 都通过 `_conc_global_alloc` 分配（临时把 current arena 设为 -1），不会落进 compiler function arena。

### 2.2 Typed channel

- `conc_channel_new(region, elem_size, cap)` 在 owner region 内分配 header（64B）+ 环形 buffer。
- `conc_send(ch, msg)` 要求 `msg` 是有效 MessageRef，且 `msg.size == elem_size`；按字节复制，不假设 8 字节。
- `conc_recv(ch)` 把队首复制到 owner region 的新 MessageRef；空队列返回空串。
- 满队列 `conc_send` 返回 `1`，不覆盖旧元素；非法句柄/消息返回 `-1`。
- CP-1 不做 close、零容量 rendezvous、MPMC；这些在 spec 中留待后续切片。

### 2.3 Plan fixture

- `conc_plan_new()` 返回 target-neutral plan id。
- body/channel/edge 描述符只存结构事实：kind、entry、params、elem size/cap/PC、edge kind；不存 CPU/GPU/slot/memory space。
- `CONC_BODY_TASK=1`、`CONC_BODY_DATA_PARALLEL=2`；`CONC_EDGE_SPAWN=1`、`CONC_EDGE_SEND=2`、`CONC_EDGE_JOIN=3`。
- 描述符数组按需增长，全部在全局 heap。

### 2.4 执行器

- `conc_run_cpu(plan, arg: string)`：单逻辑 slot，按 plan body 顺序执行。
  - TASK：`sched_call_1(table, 0, arg)`；
  - DATA_PARALLEL：串行 fallback，遍历 `0..params` 调 `entry(i)`；
  - 未知 kind / entry 为 0：返回 `-1`。
- `conc_run_simt(plan, start, end)`：只接受 DATA_PARALLEL body，遍历 `start..end` 调 `entry(i)`；TASK/PIPELINE 返回 `-1`，不静默串行。
- CPU 与 SIMT 消费同一份 `plan`；测试先 CPU 后 SIMT，逐项检查 `0..15`，并显式把数组改写成 `-1` 后再跑 SIMT，避免“SIMT 什么都没做”也能通过。

## 3. 后端前提修正

CP-1 需要 `sched_call_1` 真正能调用 `@addr(fn)`。实测发现两处既有缺陷（此前没有调用者，因此未暴露）：

1. **Trampoline 取错寄存器**：`emit_sched_call` 生成 `mov (%rax,%rsi,8),%rax`，但调用约定把 table 放在 `rdi`。`sched_call_1(table, 0, arg)` 会跳到未定义地址。
   - 修正：`mov (%rdi,%rsi,8),%rax`。
2. **Phase 3 偏移未更新**：Phase 2 用估计偏移预登记 `sched_call_*`，Phase 3 又追加一份实际偏移；call patching 取第一项，于是调用落到估计地址（指令中间）。
   - 修正：`sched_reg_one` 先按名字更新已有项，找不到才追加。

这两处只影响 `sched_call_*` 这类 runtime trampoline，不修改 `go`/`chan` 的 compiler lowering，也不改变 CP-1 的“新 runtime 不改旧 runtime”边界。

## 4. 验证

### 4.1 CP-1 套件

```bash
nice -n 19 python3 tests/selfhost/test_conc_runtime.py
```

实测：

```text
PASS conc_region
PASS conc_channel
PASS conc_plan
PASS conc_cpu
PASS conc_simt
PASS conc_lifetime
PASS conc_negative
7/7 passed
```

覆盖点：

- region：两次分配地址不同；reset 后再次分配复用同一地址；`conc_same` 按指针比较。
- channel：16 字节元素（两个 8 字节字）完整往返；空 recv 返回空 MessageRef。
- plan：body/channel 计数、未知 kind 拒绝。
- CPU/SIMT：同一 plan、同一 `par` 入口、逐项值一致。
- lifetime：reset 前消息在 reset 后 send 被拒绝，channel 的 recv 返回空。
- negative：满 channel send 返回 `1` 且不覆盖旧元素；未知 body kind 返回 `-1`；TASK plan 交给 SIMT 返回 `-1`。

### 4.2 回归

```bash
nice -n 19 python3 tests/selfhost/test_rt_tls.py        # PASS rt tls
nice -n 19 python3 tests/selfhost/test_go_arena.py      # PASS go arena per-G context switch
nice -n 19 python3 tests/selfhost/test_chan_handle_model.py  # 11/11
```

后端重建：

```bash
nice -n 19 python3 build_selfhost_native.py
```

`build/corec`、`build/corearch`、`build/corelsp` 均成功产出。

## 5. 未做项（明确留给 CP-2+）

- 编译器从 `go`/channel/独立循环抽取 `ConcurrencyPlan`，生成 plan artifact 与版本/ABI。
- 真实 GPU/SIMT 后端；CP-1 的 SIMT 是 host 模拟。
- MOVE / LOAN / SPLIT / FILL 的完整 transfer 执行器；CP-1 只覆盖 typed message 的 COPY 语义。
- 多 slot、多 M、真实并发调度；CP-1 的 CPU/SIMT 都是单线程顺序执行。
- `close`、零容量 rendezvous、MPMC channel。
- 预算/证书/explain 接线。
- CP-1 的 `conc_recv` 每收一条消息就在 owner region 分配一份副本；region 没有回收/释放，长跑会耗尽。生命周期回收留 CP-2。
- MessageRef 在 CP-1 中是裸 payload 指针 + epoch；region reset 后如果新分配复用同一地址，旧指针会重新“看起来有效”。正式 MessageRef 必须使用 `(region_id, offset, layout)` 身份，而不是裸地址；这是 CP-2 的必做项。
- plan body 的 `params` 在 CP-1 fixture 中兼作 DATA_PARALLEL 的索引域长度；正式 schema 在 CP-2 拆分 `param_layout` 与 `index_domain`。
- plan body 的 `entry` 在 CP-1 中直接存 `@addr(fn)`，只对 host CPU/SIMT 模拟有效；target-neutral artifact 在 CP-2 改为 body/entry 引用。

## 6. 不变量核对

| 不变量 | CP-1 证据 |
|---|---|
| 不新增源码语法 | 只新增 stdlib 函数；测试用现有 `fn`/`loop`/`@addr` |
| 不绑定 CPU 核数 | plan 无 slot/CPU/GPU 字段；CPU/SIMT 只是两个执行器 |
| runtime 对象不落 function arena | `_conc_global_alloc` 保存/恢复 current arena；lifetime/region 测试 |
| 编译期事实不复算 | plan 只携带结构；执行器不推导布局/owner |
| mapping 不改语义 | 同一 plan 的 CPU/SIMT 输出逐项一致 |
| fail-closed | 非法 kind、TASK→SIMT、满 send、stale MessageRef 均显式失败 |
