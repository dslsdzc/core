# CP-3: plan graph binding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 plan body 的参数绑定到 channel descriptor，让 runtime 通过绑定表执行 body，而不是手写传 channel handle。

**Architecture:** plan v1 增加 `bind <body> <param> <channel>` 行；`conc.cr` 增加 bind 表、`conc_plan_bind_param` / `conc_plan_param_channel` / `conc_run_body_bound`；compiler emitter 在单 channel 切片上发 `bind 1 0 0` 与 `edge 0 1 SEND 0`。仍是显式 `corec conc-plan` 路径，默认 `go`/`chan` lowering 不变。

**Tech Stack:** Core self-hosted compiler、`src/stdlib/conc.cr`、Python selfhost 测试、jj。

**Spec:** `docs/superpowers/specs/2026-11-01-cross-paradigm-concurrency-design.md`

## Global Constraints

- 不新增源码语法；plan 仍是旁路文本 artifact。
- 不做多 channel 绑定、worker body 内 send/recv 全图、默认 lowering 切换；这些留 CP-4。
- bind 的 body/param/channel 必须越界检查、重复检查；loader 失败返回 `-1`。
- runtime 对象继续走 owner region / 全局 plan 表。
- 长编译/测试用 `nice -n 19`；版本控制只用 `jj`。

## Review Focus

- bind 的 body/param/channel 越界与重复是否 fail-closed。
- `conc_run_body_bound` 在无绑定、空 channel table、非法 body 时是否拒绝。
- compiler emitter 是否只在 `go_params == 1` 时发 bind/SEND，且不影响 zero-arg 切片。
- E2E 是否真的用 plan bind 选择 channel，而不是又手写传参。

---

### Task 1: plan bind records + runtime

**Files:**
- Modify: `src/stdlib/conc.cr`
- Test: `tests/selfhost/test_conc_plan.py`

**Interfaces:**
- `conc_plan_bind_count(plan: int) -> int, pub`
- `conc_plan_bind_param(plan: int, body: int, param: int, channel: int) -> int, pub`
- `conc_plan_param_channel(plan: int, body: int, param: int) -> int, pub`
- `conc_run_body_bound(plan: int, body: int, channels: string) -> int, pub`
- plan text: `bind <body> <param> <channel>`。

- [ ] **Step 1: 写失败测试**

在 `test_conc_plan.py` 的 LOAD_RUN plan 加 `bind 1 0 0`，断言 `conc_plan_bind_count == 1`、`conc_plan_param_channel(1,0) == 0`；E2E 用 `conc_run_body_bound` + channel table。

- [ ] **Step 2: 实现**

- plan record 的 72 字节槽存 bind block 指针；block = count/cap + 32 条 24B 记录。
- `conc_plan_bind_param` 校验 body/param/channel、重复绑定、容量。
- `conc_run_body_bound` 从 `channels` raw table 取 handle，调用 TASK body；无绑定/空表返回 `-1`。

- [ ] **Step 3: 跑测试**

```bash
nice -n 19 python3 tests/selfhost/test_conc_plan.py
```

Expected: `PASS conc_plan_load`, `PASS conc_plan_e2e`.

- [ ] **Step 4: 提交**

```bash
jj commit -m "conc: bind plan body parameters to channel descriptors"
```

---

### Task 2: Emitter bind/SEND edge + tests

**Files:**
- Modify: `src/compiler/conc_plan_emit.cr`
- Test: `tests/selfhost/test_conc_plan_emitter.py`

- [ ] **Step 1: 写失败测试**

更新 `EXPECTED` / `MUT_CAP_EXPECTED`，要求 params=1 的 plan 含：
```text
bind 1 0 0
edge 0 1 SEND 0
edge 0 1 SPAWN -1
```
zero-arg 切片只发 SPAWN。

- [ ] **Step 2: 实现**

`go_params == 1` 时在 channel 行后追加 bind 与 SEND edge。

- [ ] **Step 3: 跑测试**

```bash
nice -n 19 python3 tests/selfhost/test_conc_plan_emitter.py
```

Expected: `21/21 passed`.

- [ ] **Step 4: 提交**

```bash
jj commit -m "compiler: emit plan body/channel bindings"
```

---

### Task 3: Report + CI

**Files:**
- Create: `docs/superpowers/implementation/2026-11-03-cp3-plan-binding.md`
- Modify: `src/ci/run.sh`（无需新文件，现有 CP-2 套件已覆盖）

- [ ] **Step 1: 报告**：记录 bind 格式、runtime 语义、单 channel 边界、测试证据、CP-4 未做项。
- [ ] **Step 2: 跑完整 selfhost-tests**，确认 CP-2/CP-3 gate 在 p41 前执行。
- [ ] **Step 3: 提交**。

---

## Self-Review

- **Spec coverage:** plan graph binding 对应 spec 的 body/channel 连接；多 channel/worker edge/default lowering 明确 CP-4。
- **Step scan:** 每个任务有失败测试、最小实现、验证、提交。
- **Type consistency:** `conc_plan_bind_param(int,int,int,int)`, `conc_plan_param_channel(int,int,int)`, `conc_run_body_bound(int,int,string)` 固定。
- **Review Focus:** bind 越界/重复、bound executor fail-closed、emitter 单 channel 限制、E2E 真实消费 bind。
- **Proportion:** 计划只给接口、fixture、验收，不转录完整实现。
