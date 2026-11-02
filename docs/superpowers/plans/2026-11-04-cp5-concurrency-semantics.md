# CP-5: range go / zero-cap / formal MessageRef Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 补齐 CP-5 的并发语义：range go 走 conc scheduler、零容量 rendezvous + MPMC、activation id 复用、正式 MessageRef `(region, offset, size, layout, epoch)` 与 reset/reuse ABA。

**Architecture:** range go 在 `ir_gen` 中展开为 `conc_go` + `chan_recv` 收集；`conc_sched` 增加 cap=0 的 direct handoff 与 per-activation handoff slot，并复用 dead activation id；`conc` 增加 descriptor 形式的 `conc_ref_*`，用 region/offset/epoch 做身份校验。

**Tech Stack:** Core self-hosted compiler、`conc` / `conc_sched`、Python selfhost 测试、jj。

**Spec:** `docs/superpowers/specs/2026-11-01-cross-paradigm-concurrency-design.md`

## Global Constraints

- 不新增源码语法；range go 仍是现有 `go var start..end expr`。
- CP-5 的 executor 仍单线程协作式；true OS-thread multi-M/抢占/跨线程原子等待不在本次范围（旧 0A 阻断仍在）。
- 零容量只承诺默认 `chan` runtime；plan descriptor 仍要求 `cap>0`。
- MessageRef descriptor 是新增 API；旧 raw pointer `conc_alloc/conc_send/recv` 保留兼容。
- 长编译/测试用 `nice -n 19`；版本控制只用 `jj`。

## Review Focus

- range go 的结果数组是否收集每个 `chan_recv`，且不再走同步 `IR_SPAWN`。
- cap=0 send/recv 的 handoff slot 是否只在对应 activation 上读写；close/MPMC 唤醒是否正确。
- activation id 复用后，旧 `g_conc_acts` 槽、free list、ready queue 是否一致。
- descriptor 的 epoch/offset/size/layout 是否拒绝 reset+reuse 的旧 ref。
- 默认 `go`/`chan`、`test_multi_m`、`build_kernel` 不回归。

---

### Task 1: range go

**Files:**
- Modify: `src/compiler/ir_gen.cr`
- Test: `tests/selfhost/test_conc_sched.py`

- [ ] **Step 1: 写失败测试**：`arr := go i 0..3 square(i)`，断言 `arr[0]+arr[1]+arr[2] == 5`。
- [ ] **Step 2: 实现**：每个 index 发 `conc_go(@addr(f), i)`，存 handle；再逐 index `chan_recv` 写入结果数组。
- [ ] **Step 3: 跑测试**：`test_conc_sched.py` 10/10。

### Task 2: zero-cap rendezvous / MPMC / activation id reuse

**Files:**
- Modify: `src/stdlib/conc.cr`、`src/stdlib/conc_sched.cr`
- Test: `tests/selfhost/test_conc_sched.py`

- [ ] **Step 1: 写失败测试**：cap=0 sender→main recv；两个 cap=0 sender；close。
- [ ] **Step 2: 实现**：activation handoff slot（+72）；send 匹配 recv waiter 直接写入；recv 匹配 send waiter 直接取值；dead activation 的 id 回 free list。
- [ ] **Step 3: 跑测试**：`test_conc_sched.py` 含 rendezvous/MPMC。

### Task 3: formal MessageRef descriptor

**Files:**
- Modify: `src/stdlib/conc.cr`
- Test: `tests/selfhost/test_conc_runtime.py`

- [ ] **Step 1: 写失败测试**：`conc_ref_alloc` → reset → 旧 ref `conc_ref_ok == 0`；同 offset 新 ref 有效；layout/offset 可读。
- [ ] **Step 2: 实现**：`CONC_REF_MAGIC`、`CONC_REF_SIZE=48`；descriptor 存 region/offset/size/layout/epoch；`conc_ref_ok` 校验 region/epoch/header/size/边界；`conc_ref_payload` 解析。
- [ ] **Step 3: 跑测试**：`test_conc_runtime.py` 14/14。

### Task 4: report + CI

- [ ] 记录 CP-5 1/4/5 完成；multi-M/抢占/跨线程原子等待仍 blocked（CP-6）。
- [ ] 完整 selfhost-tests；`build_kernel.py`；`test_multi_m.py`。
- [ ] 提交。

## Self-Review

- **Spec coverage:** range go、rendezvous/MPMC、activation identity、formal MessageRef。true multi-M 明确不在本次。
- **Step scan:** 每任务有失败测试、最小实现、验证。
- **Type consistency:** `conc_ref_alloc(int,int,int)->string`, `conc_ref_ok(string)->int`, `conc_ref_payload(string)->string`。
- **Review Focus:** range collection、handoff slot、free list、epoch/offset、默认语料回归。
- **Proportion:** 计划只给接口、fixture、验收。
