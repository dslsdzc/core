# CP-4: default conc runtime + cooperative scheduler Implementation Plan

> 定位：受众 = 维护者；状态 = 已完成；出处 = 本页。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把默认 `go`/`chan` 路径切到 conc runtime：单线程 fiber 调度、阻塞 send/recv、多 channel plan 绑定、worker body send/recv edge。

**Architecture:** 新增 `src/stdlib/conc_sched.cr`：激活表 + ready queue + per-channel wait queue + `fiber_init/fiber_switch`。`ir_gen` 的单 `go` 改调 `conc_go`；`chan.cr`/`sched.cr` 委托 conc。plan emitter 通过 `chan_make` 后首个 handle store 建立 channel id，并绑定 `go` 实参。

**Tech Stack:** Core self-hosted compiler、`conc` / `conc_sched` stdlib、backend fiber stubs、Python selfhost 测试、jj。

**Spec:** `docs/superpowers/specs/2026-11-01-cross-paradigm-concurrency-design.md`

## Global Constraints

- 不新增源码语法；默认 surface 仍是 `go`/`chan_make`/`chan_send`/`chan_recv`/`chan_close`。
- CP-4 的 CPU mapping 单线程、协作式、无锁；不做 multi-M/抢占/原子等待协议。
- `go`/`chan` 默认路径需要保持现有语料行为；range go 的 `IR_SPAWN` 仍是旧同步近似，留 CP-5。
- runtime 对象走 activation arena / 全局 heap；不落 compiler function arena。
- 长编译/测试用 `nice -n 19`；版本控制只用 `jj`。

## Review Focus

- fiber_init/fiber_switch 的 SP 保存/恢复与 arena 保存/恢复。
- 阻塞 send/recv 的 wait queue：满/空、唤醒、close、主线程调度。
- 默认 `go` 参数（int/channel handle）与结果 channel 的返回。
- 多 channel emitter 的 handle 映射与 `go` 实参绑定；不支持形态 fail-closed。
- 现有 `go_*`/`chan_*` 语料、`test_go_arena`、`test_rt_tls` 不回归。

---

### Task 1: conc scheduler + blocking channels

**Files:**
- Create: `src/stdlib/conc_sched.cr`
- Modify: manifests / `_import.cr`
- Test: `tests/selfhost/test_conc_sched.py`

- [ ] **Step 1: 写失败测试**：`go worker(req)` 传 channel、阻塞 send、两个 `go`。
- [ ] **Step 2: 实现**：activation table、ready ring、wait queue、`fiber_init`/`fiber_switch`、arena save/restore、`conc_sched_send_int`/`recv_int`/`close`。
- [ ] **Step 3: 跑测试**：`test_conc_sched.py` 7/7（含大 channel、无 sched_init、1000 go、native build）。
- [ ] **Step 4: 提交**。

### Task 2: default `go`/`chan` switch

**Files:**
- Modify: `src/compiler/ir_gen.cr`（单 `go` -> `conc_go`）
- Modify: `src/stdlib/sched.cr`、`src/stdlib/chan.cr`
- Test: `tests/selfhost/test_chan_handle_model.py`、`test_go_arena.py`、`test_rt_tls.py`

- [ ] **Step 1: 切换**：`ir_gen` 单 `go` 调 `conc_go`；`sched_init` 初始化 conc；`chan_*` 委托 conc_sched。
- [ ] **Step 2: 跑现有并发语料**：`test_chan_handle_model.py` 11/11；`test_go_arena.py`、`test_rt_tls.py` 通过。
- [ ] **Step 3: 提交**。

### Task 3: multi-channel plan binding + worker edges

**Files:**
- Modify: `src/compiler/conc_plan_emit.cr`
- Modify: `tests/selfhost/test_conc_plan_emitter.py`
- Modify: `tests/selfhost/test_conc_plan.py`

- [ ] **Step 1: 写失败测试**：两 channel，`go` 用第二个；plan 含 `bind 1 0 1`、`SEND 1`、`RECV 1`。
- [ ] **Step 2: 实现**：`chan_make` 后首个 handle store 建 channel id；`go` 实参映射到 channel id；worker body `chan_recv/chan_send(param)` 发 RECV/SEND edge。
- [ ] **Step 3: 跑测试**：emitter 25/25；plan 5/5（含 multichannel）。
- [ ] **Step 4: 提交**。

### Task 4: CI + report

**Files:**
- Modify: `src/ci/run.sh`
- Create: `docs/superpowers/implementation/2026-11-03-cp4-default-conc-runtime.md`

- [ ] **Step 1: CI**：`test_conc_sched.py` 加入 selfhost-tests，排在 p41 前。
- [ ] **Step 2: 报告**：记录 scheduler/默认路径/多 channel/边界。
- [ ] **Step 3: 跑完整 selfhost-tests**。
- [ ] **Step 4: 提交**。

## Self-Review

- **Spec coverage:** 覆盖 CP-4 前四项：多 channel 绑定、worker send/recv edge、阻塞 send/recv + 协作调度、默认 `go`/`chan` 切换。range go、multi-M、GPU/transfer/预算留 CP-5+。
- **Step scan:** 每任务有失败测试、最小实现、验证。
- **Type consistency:** `conc_spawn(int,int,string)`, `conc_go(int,int)->string`, `conc_sched_send_int(string,int)`, `conc_sched_recv_int(string)->int`。
- **Review Focus:** fiber SP/arena、wait queue、close、默认语料回归、多 channel 绑定、fail-closed。
- **Proportion:** 计划只给接口、fixture、验收。
