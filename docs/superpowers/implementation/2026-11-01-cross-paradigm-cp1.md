# CP-1 实现记录：跨范式并发 runtime 基底

> 定位：受众 = 维护者；状态 = 已完成；出处 = 本页。

日期：2026-11-01
状态：CP-1 runtime substrate 完成；compiler plan emitter 与真实目标映射留 CP-2。
计划：`docs/superpowers/plans/2026-11-01-cross-paradigm-cp1-runtime-substrate.md`
规格：`docs/superpowers/specs/2026-11-01-cross-paradigm-concurrency-design.md`

> 计划更新说明：实现时把 `conc_run_cpu` 的 `arg` 固定为 `string`（TASK）并使用 `params=0/1` 分派 `sched_call_0/1`；SIMT 测试从“只查 index 3”加强为 `0..15` 全量对拍。计划文件已同步这些接口与测试，属于 plan update，不是原始计划。

## 1. 交付内容

| 文件 | 变化 |
|---|---|
| `src/stdlib/conc.cr` | 新增 CP-1 runtime：owner region、typed MessageRef channel、fixture plan、CPU/SIMT 执行器 |
| `tests/selfhost/test_conc_runtime.py` | 新增 13 例：region、arena 生命周期、容量耗尽、16B 对齐、channel、12B 元素/ring wrap、plan、plan growth/edge、CPU（1 参数）、CPU（0 参数）、SIMT（同 body list 对拍）、lifetime、negative |
| `src/ci/run.sh` | `selfhost-tests` 接入 `test_conc_runtime.py`，并放在已知失败用例之前 |
| `src/format/elf/elf.cr` | 修正 `sched_call_N` trampoline 的表项寻址与 Phase 3 偏移更新 |

## 2. 对象模型

### 2.1 Owner region

- `conc_region_new(size)` 从全局 heap 分配 `size + 16` 字节，把 base 对齐到 16 字节后返回 region id；`size < 64` 拒绝。
- `conc_alloc(region, size)` 是 16 字节对齐的 bump 分配；每个 payload 前有 32 字节消息头：
  - `0 magic`
  - `8 region id`
  - `16 epoch`
  - `24 Core string length (size + 1)`
- 分配时预留并写入 payload 末尾的 NUL 终止符；`str_len(payload)` 等于请求的 `size`。
- `conc_region_reset(region)` 把 cursor 归零并递增 epoch。
- `conc_send` / `conc_recv` / `conc_is_ok` 校验消息头、region 活性、epoch、size 和 payload 边界；reset 前的 MessageRef 在 reset 后会被拒绝（除非同地址已被新分配复用，见 §5 的 ABA 限制）。
- 分配路径：region block、plan record、plan 描述符数组、call table 通过 `_conc_global_alloc`（临时把 current arena 设为 -1）分配；channel 与 message payload 是 `conc_alloc` 在 owner region 内的 bump 子分配。两者都不会落进 compiler function arena。

### 2.2 Typed channel

- `conc_channel_new(region, elem_size, cap)` 在 owner region 内分配 header（64B）+ 环形 buffer；CP-1 只接受 `elem_size > 0`、`cap > 0`。
- `conc_send(ch, msg)` 要求 `msg` 是有效 MessageRef，且 `msg.size == elem_size`；按字节复制，不假设 8 字节。
- `conc_recv(ch)` 把队首复制到 owner region 的新 MessageRef；空队列返回空串，`conc_last_error()` 返回 `CONC_ERR_EMPTY`；输出分配失败返回空串并返回 `CONC_ERR_NOMEM`，不消耗队首。
- 满队列 `conc_send` 返回 `CONC_ERR_FULL`（1），不覆盖旧元素；非法句柄/消息返回 `CONC_ERR_INVALID`（-1）。
- `conc_channel_len` / `conc_channel_elemsize` 对非法 handle 返回 `-1`。
- `_conc_channel_valid` 还校验 `head ∈ [0, cap)`、`len ∈ [0, cap]`、buffer 指针恰好等于 `ch + 64`、buffer 容量不超过 channel payload。
- CP-1 不做 close、零容量 rendezvous、MPMC；plan 层只接受 `CONC_PC_SPSC`。

### 2.3 Plan fixture

- `conc_plan_new()` 返回 target-neutral plan id。
- body/channel/edge 描述符只存结构事实：kind、entry、params、elem size/cap/PC、edge kind；不存 CPU/GPU/slot/memory space。
- `CONC_BODY_TASK=1`、`CONC_BODY_DATA_PARALLEL=2`；`CONC_EDGE_SPAWN=1`、`CONC_EDGE_SEND=2`、`CONC_EDGE_JOIN=3`；`CONC_PC_SPSC=1`。
- 校验：`entry >= 0`；TASK 的 `params` 只能是 0 或 1（CPU 按 0/1 分派 `sched_call_0/1`，更多参数留给 CP-2 的 param layout）；channel `cap > 0` 且 `pc == CONC_PC_SPSC`；edge 端点需要在 body 范围内。
- 描述符数组按需增长，全部在全局 heap。

### 2.4 执行器

- `conc_run_cpu(plan, arg: string)`：单逻辑 slot，按 plan body 顺序执行。
  - TASK：`params=0` 用 `sched_call_0`，`params=1` 用 `sched_call_1(table, 0, arg)`；
  - DATA_PARALLEL：串行 fallback，遍历 `0..params` 调 `entry(i)`；
  - 未知 kind / entry <= 0 / TASK params > 1：返回 `-1`。
- `conc_run_simt(plan, start, end)`：只接受 DATA_PARALLEL body，遍历 `start..end` 调 `entry(i)`；TASK/PIPELINE 返回 `-1`，不静默串行。
- CPU 与 SIMT 消费同一份 plan 的 body list；测试先 CPU 后 SIMT，逐项检查 `0..15`，并显式把数组改写成 `-1` 后再跑 SIMT，避免“SIMT 什么都没做”也能通过。CP-1 的 plan channel/edge 描述符只做结构校验，尚未驱动执行；完整 channel/edge 执行留 CP-2。

## 3. 后端前提修正

CP-1 需要 `sched_call_N` 真正能调用 `@addr(fn)`。实测发现两处既有缺陷（此前没有调用者，因此未暴露）：

1. Trampoline 取错寄存器：`emit_sched_call` 生成 `mov (%rax,%rsi,8),%rax`，但调用约定把 table 放在 `rdi`。`sched_call_1(table, 0, arg)` 会跳到未定义地址。
   - 修正：`mov (%rdi,%rsi,8),%rax`。
2. Phase 3 偏移未更新：Phase 2 用估计偏移预登记 `sched_call_*`，Phase 3 又追加一份实际偏移；call patching 取第一项，于是调用落到估计地址（指令中间）。
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
PASS conc_region_arena
PASS conc_region_exhaust
PASS conc_alignment
PASS conc_channel
PASS conc_channel_edge
PASS conc_plan
PASS conc_plan_growth
PASS conc_cpu
PASS conc_cpu0
PASS conc_simt
PASS conc_lifetime
PASS conc_negative
13/13 passed
```

覆盖点：

- region：两次分配地址不同；reset 后再次分配复用同一地址；`conc_same` 按指针比较；`conc_region_new(64)` 能失败而不崩溃。
- arena 生命周期：先在 `arena_init` 后记录 current arena，`make_region()` 返回后 current arena 不变；`arena_new_sized` + `arena_reset` 后 region payload 仍可读。这是“runtime 对象不落 function arena”的直接回归。
- 容量/对齐/overflow：region 耗尽时 `conc_alloc` 返回空而不写只读内存；`conc_channel_new` 超容量返回空；`conc_recv` 分配失败返回 `CONC_ERR_NOMEM` 且不消费；极大 size/cap 被拒绝；连续 8 轮强制 8-mod-16 的全局偏移后，payload 仍 16 字节对齐。
- channel：16 字节元素（两个 8 字节字）完整往返；12 字节元素的两个 8 字节字/尾部复制；ring wrap；send 后覆盖源数据仍保留副本；空 recv 返回 `CONC_ERR_EMPTY`；非法 handle 的 `len/elemsize` 返回 `-1`。
- plan：body/channel/edge 计数、未知 kind、负 entry、TASK params>1、cap<=0、非 SPSC 拒绝；20 个 body/channel 与 15 条 edge 的 growth、edge 端点校验。
- CPU/SIMT：同一 body list、同一 `par` 入口、逐项值一致；TASK params=0 走 `sched_call_0`，params=1 走 `sched_call_1`；SIMT 子区间 `4..8` 只写对应索引。
- lifetime：reset 前消息在 reset 后 send 被拒绝，channel 的 recv 返回空。
- negative：满 channel send 返回 `1` 且不覆盖旧元素；未知 body kind 返回 `-1`；TASK plan 交给 SIMT 返回 `-1`。

### 4.2 回归

```bash
nice -n 19 python3 tests/selfhost/test_rt_tls.py        # PASS rt tls
nice -n 19 python3 tests/selfhost/test_go_arena.py      # PASS go arena per-G context switch
nice -n 19 python3 tests/selfhost/test_chan_handle_model.py  # 11/11
nice -n 19 python3 tests/selfhost/test_pub_visibility.py     # PASS
nice -n 19 python3 tests/selfhost/test_raw_abi_boundary.py   # PASS
nice -n 19 python3 tests/selfhost/test_import_graph.py       # 7/7
```

完整 `selfhost-tests` 中 CP-1 gate 已执行并通过，随后停在 `test_merge_copy.py` 的既存失败：

```text
PASS conc_region
...
PASS conc_negative
13/13 passed

FAIL test_p41_dynamic_string_arena_switch_path: run rc=-11, expected 0
44/45 passed
CI_EXIT=1
```

该失败在 CP-1 基线 `1e47f93f` 上用一个全新 workspace + 全新 `build_selfhost_native.py` 构建同样复现，因此不是 CP-1 引入的。它属于旧 0A WIP 的既存问题（p41 走 `arena_init`/`arena_new_sized` 路径，不经过 `sched_call`），CP-1 不修改 `arena/sched/chan`，也不把它当作 CP-1 的验收基线。

为避免该既存失败挡住 CP-1 gate，`src/ci/run.sh` 把 `test_conc_runtime.py` 放在 `test_merge_copy.py` 之前；即使后续 p41 仍失败，CP-1 套件也已经执行。

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
- CP-1 的 `conc_recv` 每收一条消息就在 owner region 分配一份副本；region 没有回收/释放，长跑会耗尽。`conc_last_error` 能报告 `CONC_ERR_NOMEM`，但不会自动回收；生命周期回收留 CP-2。
- MessageRef 在 CP-1 中是裸 payload 指针 + epoch；region reset 后如果新分配复用同一地址，旧指针会重新“看起来有效”。正式 MessageRef 需要使用 `(region_id, offset, layout)` 身份，而不是裸地址；这是 CP-2 的必做项。CP-1 的 `conc_is_ok`/send/recv 在“未复用地址”的 reset 场景下会拒绝 stale ref。
- plan body 的 `params` 在 CP-1 fixture 中兼作 DATA_PARALLEL 的索引域长度；正式 schema 在 CP-2 拆分 `param_layout` 与 `index_domain`。
- plan body 的 `entry` 在 CP-1 中直接存 `@addr(fn)`，只对 host CPU/SIMT 模拟有效；target-neutral artifact 在 CP-2 改为 body/entry 引用。
- `_conc_global_alloc` 走现有 `alloc` 的 `current_arena = -1` 全局路径，该路径在非 M0 上会 trap；CP-1 的执行器都跑在 M0。多 slot 需要独立的全局 heap allocator，这是 CP-2 的 runtime 前提。
- 单格 call table、channel 的 head/len 更新都不是并发的；CP-1 是单线程对象模型验证，不宣称线程安全。并发 channel 需要原子/等待协议，留 CP-2。
- `conc_region_owner` 仍是 fixture（返回 0）；descriptor 数组增长时不释放旧数组；这些都不影响 CP-1 的对象模型验证。

## 6. 不变量核对

| 不变量 | CP-1 证据 |
|---|---|
| 不新增源码语法 | 只新增 stdlib 函数；测试用现有 `fn`/`loop`/`@addr` |
| 不绑定 CPU 核数 | plan 无 slot/CPU/GPU 字段；CPU/SIMT 只是两个执行器 |
| runtime 对象不落 function arena | `_conc_global_alloc` 保存/恢复 current arena；`conc_region_arena` 直接验证 arena reset 后 payload 仍可读 |
| 编译期事实不复算 | plan 只携带结构；执行器不推导布局/owner |
| mapping 不改语义 | 同一 body list 的 CPU/SIMT 输出逐项一致 |
| fail-closed | 非法 kind/负 entry/params>1/cap<=0/非 SPSC、TASK→SIMT、满 send、stale MessageRef、容量耗尽/overflow 均有显式失败或 `conc_last_error` |
| 不静默降级 | `CONC_ERR_NOMEM` 与 `CONC_ERR_EMPTY` 分离，recv 分配失败不消费队首 |
