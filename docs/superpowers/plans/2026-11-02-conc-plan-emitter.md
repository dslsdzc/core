# CP-2: 编译器 plan emitter + runtime plan loader Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让编译器从现有 `go`/`chan` 源码生成 target-neutral `ConcurrencyPlan` 文本 artifact，并让 CP-1 runtime 解析、加载、在 CPU/SIMT 上执行同一份 plan。

**Architecture:** 新编译器子命令 `corec conc-plan` 在 IR 上做保守模式匹配，输出文本 plan；`conc.cr` 新增 `conc_plan_load(text, entry_table)` 解析该文本并复用 CP-1 的 plan 描述符与执行器。默认 `go`/`chan` lowering 不变，只有显式 `conc-plan` 命令和显式 `conc_plan_load` 使用新路径。

**Tech Stack:** Core self-hosted compiler（IR 表 + CLI）、`src/stdlib/conc.cr`、Python selfhost 测试驱动、jj。

**Spec:** `docs/superpowers/specs/2026-11-01-cross-paradigm-concurrency-design.md`

## Global Constraints

- 不新增源码语法；plan 是旁路 artifact，不进入 `.ccr`。
- 默认 `go`/`chan` 编译器 lowering 不变；CP-2 只新增显式子命令/显式 loader。
- plan 只携带结构事实（body/channel/edge），不携带 CPU/GPU/slot/memory 具体值。
- 模式不支持时 fail-closed：报错、零 artifact，不得静默生成残缺 plan。
- runtime 对象继续走 owner region；不落 compiler function arena。
- 长编译/测试用 `nice -n 19`；版本控制只用 `jj`。

## Review Focus

- plan emitter 对不支持模式（多个 `go`、动态 cap、aliasing channel）是否零 artifact 且诊断清晰。
- plan loader 对截断/未知 kind/越界 id 是否拒绝，而不是读越界或生成半成品。
- entry table 与 body 顺序是否绑定正确；同名函数/多 body 是否错位。
- 同一份 plan 在 CPU/SIMT 上是否产生相同值/终止类别。
- 默认 `go`/`chan` 回归是否完全不变。

---

### Task 1: Plan text schema + runtime loader

**Files:**
- Modify: `src/stdlib/conc.cr`
- Test: `tests/selfhost/test_conc_plan.py`

**Interfaces:**
- `conc_plan_add_edge_ch(plan: int, from_body: int, to_body: int, kind: int, channel: int) -> int, pub`
- `conc_plan_edge_channel(plan: int, edge: int) -> int, pub`
- `conc_plan_load(text: string, entries: string) -> int, pub`
  - `text` 是 v1 文本 plan；`entries` 是 raw table，`cell_load(entries, i*8)` 是 body entry 地址。
  - 成功返回 plan id；任何语法/语义错误返回 `-1`。
- `conc_run_body(plan: int, body: int, arg: string) -> int, pub`
- 文本格式：
  ```text
  v 1
  body 0 TASK 0 0
  body 1 TASK 1 1
  channel 0 8 1 SPSC
  edge 0 1 SPAWN -1
  ```

- [ ] **Step 1: 写失败测试**

`tests/selfhost/test_conc_plan.py` 内嵌一份 plan 文本，构造 entry table（`@addr(worker)`），调用 `conc_plan_load`，然后 `conc_run_body(plan, 1, req)`，断言 worker 写入的 channel 值。

- [ ] **Step 2: 实现 loader**

- 增加一个轻量 tokenizer（`str_sub`/`str_len`/`get_char`/`str_int`），按 token 读取 `v/body/channel/edge`。
- `body` token 的 kind 只接受 `TASK`/`PAR`；entry index 必须 `< 8` 且 table 项非 0。
- `channel` 只接受 `SPSC`；`edge` 只接受 `SPAWN`/`SEND`/`JOIN`/`RECV`。
- 未知 token、缺失版本、重复 id、越界 id 一律返回 `-1`。
- `conc_run_body` 只执行指定 body；TASK 按 params 0/1 分派，PAR 遍历 `0..params`。

- [ ] **Step 3: 跑测试**

```bash
nice -n 19 python3 tests/selfhost/test_conc_plan.py
```

Expected: `PASS conc_plan_load`, `PASS conc_plan_run_body`.

- [ ] **Step 4: 提交**

```bash
jj commit -m "conc: load target-neutral plan text and run one body"
```

---

### Task 2: Compiler `conc-plan` emitter

**Files:**
- Create: `src/compiler/conc_plan_emit.cr`
- Modify: `compiler_manifest.py`
- Modify: `src/compiler/main.cr`
- Test: `tests/selfhost/test_conc_plan_emitter.py`

**Interfaces:**
- CLI: `corec conc-plan file.cr -o file.plan`
- `conc_plan_emit_write(path: string) -> int`
- 只支持：
  - 一个函数内一个 `sched_go` 调用；
  - `chan_make` 的 `elemsize`/`cap` 是整数字面量；
  - channel handle 是直接变量（`chan_make` dest、函数参数、全局变量），不允许 aliasing。
- 不支持时：打印 `error: conc-plan unsupported: ...`，返回 1，不写文件。

- [ ] **Step 1: 写失败测试**

Fixture：
```core
import chan
import sched

fn worker(req: string) -> int:
    v := chan_recv(req)
    return v

fn main() -> int:
    sched_init()
    req := chan_make(8, 1)
    h := go worker(req)
    chan_send(req, 41)
    return chan_recv(h) - 41
```

测试调用 `corec conc-plan`，断言 `.plan` 含：
```text
v 1
body 0 TASK 0 0
body 1 TASK 1 1
channel 0 8 1 SPSC
edge 0 1 SPAWN -1
```

- [ ] **Step 2: 实现 emitter**

- 在 `lower_to_ccr()` 之后扫描 `g_ir_func_*` / `g_ir_instr_*`。
- 先登记 `chan_make` 的 dest var -> channel id（常量参数通过 var 的 `IR_CONST`/`IR_STORE` 回溯）。
- 再扫 `sched_go`：从 arg0 的 `IR_STORE` 追到 `IR_FNADDR`，取函数名；记录 body(name, params=1)。body 0 固定为 entry/main（entry index 0，params 0）。
- 入口函数里每发现一个 `chan_send`/`chan_recv` 且 handle 可解析，输出 `SEND`/`RECV` edge；解析不到就 fail-closed。
- 只支持单 `go`；多 `go`、动态 cap、aliasing 都返回 1。

- [ ] **Step 3: 跑测试**

```bash
nice -n 19 python3 tests/selfhost/test_conc_plan_emitter.py
```

Expected: `PASS emitter_fixture`, `PASS emitter_fail_closed`.

- [ ] **Step 4: 提交**

```bash
jj commit -m "compiler: emit target-neutral conc plan artifact"
```

---

### Task 3: End-to-end plan execution + CI + report

**Files:**
- Modify: `tests/selfhost/test_conc_plan.py`
- Modify: `src/ci/run.sh`
- Create: `docs/superpowers/implementation/2026-11-02-cp2-plan-emitter.md`

- [ ] **Step 1: 端到端**

`test_conc_plan.py` 跑两层：
1. `corec conc-plan` 生成 plan；
2. 读取 plan 文本，连同 `worker` source 一起生成一个 Core fixture（entry table + `conc_plan_load`），编译/运行 CPU 和 SIMT，断言同样的值。

- [ ] **Step 2: 负例**

- 截断 plan / 未知 token / 越界 body id / 非 SPSC / 动态 cap / 多 `go`：返回 `-1` 或 rc=1 + 零 artifact。

- [ ] **Step 3: CI**

`src/ci/run.sh` 在 `test_conc_runtime.py` 附近加入 `test_conc_plan_emitter.py` 和 `test_conc_plan.py`。

- [ ] **Step 4: 报告**

记录：emitter 支持的子集、plan 文本格式、loader 语义、CPU/SIMT 对拍、fail-closed 证据、未做项（真实 GPU、transfer primitive、多 slot、预算、默认 lowering 切换）。

- [ ] **Step 5: 提交**

```bash
jj commit -m "docs/ci: record CP-2 plan emitter"
```

---

## Self-Review

- **Spec coverage:** 覆盖 spec 实施顺序 1-2（plan 内部表示 + ChannelDescriptor）与 3-4 的 host 纵向切片；真实目标/transfer/预算明确留 CP-3+。
- **Step scan:** 每个任务有失败测试、最小实现、验证、提交。
- **Type consistency:** `conc_plan_load(string,string)`, `conc_run_body(int,int,string)`, `conc_plan_add_edge_ch(int,int,int,int,int)` 固定。
- **Review Focus:** emitter fail-closed、loader 越界、entry table 顺序、CPU/SIMT 对拍、默认 lowering 不回归。
- **Proportion:** 计划只给接口、fixture、验收，不转录完整实现。
