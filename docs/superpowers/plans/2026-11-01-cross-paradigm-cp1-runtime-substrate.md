# CP-1：跨范式并发 runtime 基底 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** 用一份手工 fixture plan 验证新的 runtime 基底：owner region、typed message/channel、CPU 单 slot 执行器和 SIMT host 执行器共用同一份 plan。

**Architecture:** 新 runtime 放在独立 `src/stdlib/conc.cr`，不修改现有 `sched/chan/goroutine` 的语义降级。Region 的元数据和 payload 都从全局 heap 显式分配，不进入 compiler function arena。Channel 使用 `MessageRef`（region + offset + size + layout），不再传 8 字节字。CPU/SIMT 都是 plan 的执行器，不定义语义。

**Tech Stack:** Core stdlib、现有 `alloc`/`cell_*`/`@addr`/`sched_call_1` 原语、Python 测试驱动、jj。

**Spec:** `docs/superpowers/specs/2026-11-01-cross-paradigm-concurrency-design.md`

**Implementation note（2026-11-01）：** 落地时按 review 收紧了失败路径与测试，最终套件为 13 例（新增 arena 生命周期、容量耗尽、16B 对齐、12B 元素/ring wrap、plan growth/edge、0 参数 CPU）；接口细节以 `docs/superpowers/implementation/2026-11-01-cross-paradigm-cp1.md` 为准。

## Global Constraints

- 不新增源码语法；不引入 `Chan<T>`、lock/mutex/atomic/ownership 关键字。
- 不修改现有 `go`/`chan` 的 compiler lowering；CP-1 只验证新 runtime。
- 不绑定 CPU 核数；plan 只有 body/channel/edge/region；CPU/SIMT 是 mapping。
- runtime 对象必须属于 owner region，不能落进 compiler function arena。
- 只实现 CP-1 fixture；transfer primitive 先只做 typed COPY/MOVE 的显式 fixture，不做 SPLIT/FILL/LOAN。
- 长编译/测试用 `nice -n 19`；版本控制只用 `jj`。

## Review Focus

- Region payload 是否真的绕开 function arena（Task 6 生命周期测试）。
- Channel 是否按 layout 搬运，而不是只搬 8 字节（Task 2 测试）。
- CPU/SIMT 执行器是否消费同一份 plan，而不是各写一套 fixture（Task 4/5 对拍）。
- Plan 是否只携带约束，不携带具体 CPU/GPU 资源（Task 3 schema 断言）。
- 失败时是否 fail-closed，而不是静默返回零值（Task 2/6 负例）。

---

## Task 0: 分支与基线

**Files:** 无源码改动。

- [ ] **Step 1: 确认工作区与基线**

```bash
jj status
nice -n 19 python3 tests/selfhost/test_chan_handle_model.py
nice -n 19 python3 tests/selfhost/test_go_arena.py
```

Expected: 工作区当前 WIP 之外无意外改动；单 M 套件全绿。

- [ ] **Step 2: 提交 CP-1 计划**

```bash
jj commit -m "docs: add cross-paradigm CP-1 runtime substrate plan"
```

---

## Task 1: ConcRegion owner-region allocator

**Files:**
- Create: `src/stdlib/conc.cr`
- Test: `tests/selfhost/test_conc_runtime.py`

**Interfaces:**
- `conc_region_new(size: int) -> int` — region id；metadata/payload 从全局 heap 分配。
- `conc_alloc(region: int, size: int) -> string` — bump 分配；返回 region 内 payload。
- `conc_region_reset(region: int) -> int` — 重置 cursor，保留 block。
- `conc_region_owner(region: int) -> int` — 当前 fixture 里为 0；后续 activation id。

- [ ] **Step 1: 写失败测试**

`tests/selfhost/test_conc_runtime.py` 先建一个 Core 源码：

```core
import conc

fn main() -> int:
    r := conc_region_new(4096)
    if r < 0:
        return 1
    p := conc_alloc(r, 64)
    if p == "":
        return 2
    q := conc_alloc(r, 64)
    if q == "":
        return 3
    if q == p:
        return 4
    conc_region_reset(r)
    p2 := conc_alloc(r, 64)
    if p2 != p:
        return 5
    return 0
```

Expected before implementation: `Undefined module conc` / `Undefined function`.

- [ ] **Step 2: 实现 region**

`src/stdlib/conc.cr`：

- 全局数组：`g_conc_region_block`、`g_conc_region_cap`、`g_conc_region_cursor`、`g_conc_region_count`、`g_conc_region_cap_count`。
- `conc_region_new`：`saved := rt_current_arena(); rt_set_current_arena(-1); block := alloc(size); rt_set_current_arena(saved)`；把 block/cap/cursor 写入数组。
- `conc_alloc`：按 16 字节对齐；越界返回 `""`；返回 `@str_of(base + cursor)`。
- `conc_region_reset`：cursor=0。
- 所有数组按需扩容，扩容也用 `alloc`（全局 heap）。

- [ ] **Step 3: 运行测试**

```bash
nice -n 19 python3 tests/selfhost/test_conc_runtime.py
```

Expected: `PASS conc region`.

- [ ] **Step 4: 提交**

```bash
jj commit -m "conc: owner-region bump allocator (CP-1)"
```

---

## Task 2: Typed MessageRef + Channel

**Files:**
- Modify: `src/stdlib/conc.cr`
- Modify: `tests/selfhost/test_conc_runtime.py`

**Interfaces:**
- `conc_channel_new(region: int, elem_size: int, cap: int) -> string`
- `conc_send(ch: string, msg: string)` — msg 是 MessageRef payload 指针，按 `elem_size` 复制。
- `conc_recv(ch: string) -> string` — 返回 region 内副本；空则返回 `""`，`conc_last_error()` 返回 `CONC_ERR_EMPTY`；输出分配失败返回 `CONC_ERR_NOMEM` 且不消费队首。
- `conc_channel_elemsize(ch: string) -> int`
- `conc_channel_len(ch: string) -> int`

- [ ] **Step 1: 写失败测试**

```core
import conc

fn main() -> int:
    r := conc_region_new(8192)
    ch := conc_channel_new(r, 16, 2)
    if ch == "":
        return 1
    a := conc_alloc(r, 16)
    b := conc_alloc(r, 16)
    cell_store(a, 0, 11)
    cell_store(a, 8, 12)
    cell_store(b, 0, 21)
    cell_store(b, 8, 22)
    conc_send(ch, a)
    conc_send(ch, b)
    if conc_channel_len(ch) != 2:
        return 2
    x := conc_recv(ch)
    y := conc_recv(ch)
    if cell_load(x, 0) != 11 || cell_load(x, 8) != 12:
        return 3
    if cell_load(y, 0) != 21 || cell_load(y, 8) != 22:
        return 4
    z := conc_recv(ch)
    if z != "":
        return 5
    return 0
```

- [ ] **Step 2: 实现 channel**

- Channel 在 owner region 分配：header 64B + buffer `cap * elem_size`。
- 字段：`buf(0), cap(8), len(16), head(24), esize(32), closed(40), owner_region(48)`。
- `conc_send` 满时返回，不阻塞（CP-1 单线程 fixture 先由 plan 顺序保证）。
- 复制按 `esize` 字节逐字节（`cell_store`/`cell_load` 8 字节 + 尾字节），不假设 8 字节。
- `conc_recv` 空返回 `""`；`conc_last_error()` 区分 `CONC_ERR_EMPTY` 与 `CONC_ERR_NOMEM`，分配失败不消费队首。
- 不做 close/MPMC；负例返回明确错误。CP-1 只接受 `elem_size > 0`、`cap > 0`。

- [ ] **Step 3: 运行测试**

```bash
nice -n 19 python3 tests/selfhost/test_conc_runtime.py
```

Expected: `PASS conc channel`.

- [ ] **Step 4: 提交**

```bash
jj commit -m "conc: typed MessageRef channel (CP-1)"
```

---

## Task 3: ConcPlan fixture descriptor

**Files:**
- Modify: `src/stdlib/conc.cr`
- Modify: `tests/selfhost/test_conc_runtime.py`

**Interfaces:**
- `conc_plan_new() -> int`
- `conc_plan_add_body(plan: int, kind: int, entry: int, params: int) -> int`
- `conc_plan_add_channel(plan: int, elem_size: int, cap: int, pc: int) -> int`
- `conc_plan_add_edge(plan: int, from_body: int, to_body: int, kind: int) -> int`
- `conc_plan_body_count(plan: int) -> int`
- `conc_plan_channel_count(plan: int) -> int`
- 常量：`CONC_BODY_TASK=1`, `CONC_BODY_DATA_PARALLEL=2`, `CONC_EDGE_SPAWN=1`, `CONC_EDGE_SEND=2`, `CONC_EDGE_JOIN=3`, `CONC_PC_SPSC=1`.
- 校验：TASK `params` 只接受 0/1；channel `cap > 0` 且 `pc == CONC_PC_SPSC`；`entry >= 0`。

- [ ] **Step 1: 写失败测试**

```core
import conc

fn main() -> int:
    p := conc_plan_new()
    if p < 0:
        return 1
    b0 := conc_plan_add_body(p, CONC_BODY_TASK, 0, 1)
    b1 := conc_plan_add_body(p, CONC_BODY_TASK, 0, 0)
    c := conc_plan_add_channel(p, 8, 1, 1)
    if b0 != 0 || b1 != 1 || c != 0:
        return 2
    if conc_plan_body_count(p) != 2:
        return 3
    if conc_plan_channel_count(p) != 1:
        return 4
    return 0
```

- [ ] **Step 2: 实现 plan**

- 全局 plan 数组：`g_conc_plans`、`g_conc_plan_bodies`、`g_conc_plan_channels`、`g_conc_plan_edges`，均为全局 heap。
- 只存结构事实：kind、entry、param count、elem size/cap/PC、edge kind；**不存 CPU/GPU/slot/memory space 具体值**。
- 越界/未知 kind 返回 -1。

- [ ] **Step 3: 运行测试**

```bash
nice -n 19 python3 tests/selfhost/test_conc_runtime.py
```

Expected: `PASS conc plan`.

- [ ] **Step 4: 提交**

```bash
jj commit -m "conc: plan fixture descriptors (CP-1)"
```

---

## Task 4: CPU single-slot executor

**Files:**
- Modify: `src/stdlib/conc.cr`
- Modify: `tests/selfhost/test_conc_runtime.py`

**Interfaces:**
- `conc_run_cpu(plan: int, arg: string) -> int`
- CPU mapping：单 slot，按 plan 的 body 顺序执行；TASK `params=0` 调 `sched_call_0`，`params=1` 调 `entry(arg)`；DATA_PARALLEL body 先按串行 fallback 遍历 `0..params`。
- 用 `sched_call_1` 调 body entry；entry 的地址由 `@addr` 给出。
- `sched_call_1` 是 CP-1 的必要后端原语；实现前必须修正 `src/format/elf/elf.cr` 的两处缺陷：trampoline 从 `rdi+rsi*8` 取表项（不是 `rax`），且 Phase 3 必须更新 Phase 2 预登记的偏移而不是追加重复项。

- [ ] **Step 1: 写失败测试**

```core
import conc

g_out : string, mut

fn worker(req: string) -> int:
    v := conc_recv(req)
    if v == "":
        return 1
    conc_send(g_out, v)
    return 0

fn main() -> int:
    r := conc_region_new(65536)
    req := conc_channel_new(r, 8, 1)
    g_out = conc_channel_new(r, 8, 1)
    p := conc_plan_new()
    conc_plan_add_body(p, CONC_BODY_TASK, @addr(worker), 1)
    v := conc_alloc(r, 8)
    cell_store(v, 0, 41)
    conc_send(req, v)
    rc := conc_run_cpu(p, req)
    if rc != 0:
        return 2
    out := conc_recv(g_out)
    if out == "":
        return 3
    if cell_load(out, 0) != 41:
        return 4
    return 0
```

- [ ] **Step 2: 实现 CPU executor**

- `conc_run_cpu` 遍历 plan body：TASK `params=0` 用 `sched_call_0`，`params=1` 用 `sched_call_1`；DATA_PARALLEL 用 `entry(index)` 串行遍历。`entry <= 0` / TASK `params > 1` 返回 `-1`。
- `sched_call_1` 的 table 用全局 heap 上的一格指针；idx=0；arg 原样传入。
- 返回第一个非 0 的 body 结果；无 body 返回 0。
- 不启动 OS 线程；CP-1 只验证 plan/对象模型，不验证并行时序。

- [ ] **Step 3: 运行测试**

```bash
nice -n 19 python3 tests/selfhost/test_conc_runtime.py
```

Expected: `PASS conc cpu`.

- [ ] **Step 4: 提交**

```bash
jj commit -m "conc: CPU single-slot plan executor (CP-1)"
```

---

## Task 5: SIMT host executor，同一 plan

**Files:**
- Modify: `src/stdlib/conc.cr`
- Modify: `tests/selfhost/test_conc_runtime.py`

**Interfaces:**
- `conc_run_simt(plan: int, start: int, end: int) -> int`
- SIMT mapping 在 host 上用 DATA_PARALLEL 索引遍历模拟；不假设每 instance 有栈。
- 与 CPU executor 消费同一个 `ConcPlan`；DATA_PARALLEL body 的索引域是 `start..end`。

- [ ] **Step 1: 写失败测试**

```core
import conc

g_arr : string, mut

fn par(i: int) -> int:
    cell_store(g_arr, i * 8, i * i)
    return 0

fn main() -> int:
    r := conc_region_new(65536)
    g_arr = conc_alloc(r, 8 * 16)
    p := conc_plan_new()
    conc_plan_add_body(p, CONC_BODY_DATA_PARALLEL, @addr(par), 16)
    if conc_run_cpu(p, "") != 0:
        return 1
    i : ., mut = 0
    loop:
        if i >= 16:
            break
        if cell_load(g_arr, i * 8) != i * i:
            return 2
        cell_store(g_arr, i * 8, -1)
        i = i + 1
    if conc_run_simt(p, 0, 16) != 0:
        return 3
    i = 0
    loop:
        if i >= 16:
            break
        if cell_load(g_arr, i * 8) != i * i:
            return 4
        i = i + 1
    return 0
```

- [ ] **Step 2: 实现 SIMT executor**

- `conc_run_simt` 只处理 DATA_PARALLEL body：对 `start..end` 每个 index 调用 `entry(index)`。
- 目标能力不足（body 需要 stack/may_suspend/不是 DATA_PARALLEL）时返回 `-1`，不静默串行。
- CPU 对 DATA_PARALLEL 的 serial fallback 与 SIMT 结果必须逐项一致。

- [ ] **Step 3: 运行测试**

```bash
nice -n 19 python3 tests/selfhost/test_conc_runtime.py
```

Expected: `PASS conc simt`（该 case 内先 CPU 后 SIMT，逐项检查 `0..15`；同一份 plan 的 CPU/SIMT 输出必须相等）。

- [ ] **Step 4: 提交**

```bash
jj commit -m "conc: host SIMT plan executor, same plan as CPU (CP-1)"
```

## Task 6: Test harness, CI and report

**Files:**
- Modify: `src/ci/run.sh`
- Modify: `tests/selfhost/test_conc_runtime.py`
- Create: `docs/superpowers/implementation/2026-11-01-cross-paradigm-cp1.md`

- [ ] **Step 1: 合并测试入口**

`test_conc_runtime.py` 跑完整 fixture：region、arena 生命周期、容量耗尽、16B 对齐、channel、12B 元素/ring wrap、plan、plan growth/edge、CPU 1 参数、CPU 0 参数、SIMT（CPU/SIMT 同 body list 逐项对拍）、lifetime、negative，共 13 例。
`src/ci/run.sh` 的 `selfhost-tests` 段加入该测试。

- [ ] **Step 2: 生命周期负例**

- region reset 前分配的 MessageRef 在 reset 后再用必须失败（不可读/不可发送）；
- channel 满 send 必须返回错误，不覆盖旧元素；
- plan 不合法类型必须返回 -1。

- [ ] **Step 3: 跑测试**

```bash
nice -n 19 python3 tests/selfhost/test_conc_runtime.py
nice -n 19 CI_JOB_NAME=selfhost-tests src/ci/run.sh
```

Expected: 全 PASS。

- [ ] **Step 4: 写报告**

记录：新 runtime 文件、fixture plan、CPU/SIMT 同 plan 对拍、region 生命周期证据、未做项（compiler emitter、真实 GPU、MOVE/SPLIT/FILL/LOAN、多 slot、预算）。

- [ ] **Step 5: 提交**

```bash
jj commit -m "docs: record cross-paradigm CP-1 runtime substrate"
```

---

## Self-Review

- **Spec coverage:** CP-1 覆盖 spec 的 Region/Message/Channel/ExecutionBody 基础对象模型与 CPU/SIMT mapping 验证；编译器 plan emitter、真实 GPU、transfer 全 primitive 明确留 CP-2。
- **Step scan:** 每个 task 有失败测试、最小实现、验证、提交。
- **Type consistency:** `conc_region_new(int)`, `conc_alloc(int,int)`, `conc_channel_new(int,int,int)`, `conc_plan_add_body(int,int,int,int)`, `conc_run_cpu(int,string)`, `conc_run_simt(int,int,int)` 固定。
- **Review Focus:** 生命周期、typed message、同 plan 对拍、target-neutral plan、fail-closed 均有对应测试。
- **Proportion:** 计划只给接口、fixture 和验收，不转录完整实现。
