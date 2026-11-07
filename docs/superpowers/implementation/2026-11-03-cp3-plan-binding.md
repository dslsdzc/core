# CP-3 实现记录：plan body/channel binding

> 定位：受众 = 维护者；状态 = 已完成；出处 = 本页。

日期：2026-11-03
状态：CP-3 host 切片完成：plan body 参数可以绑定到 channel descriptor，runtime 通过绑定表执行 body。
计划：`docs/superpowers/plans/2026-11-03-cp3-plan-binding.md`
规格：`docs/superpowers/specs/2026-11-01-cross-paradigm-concurrency-design.md`

## 1. 范围

CP-3 在 CP-2 plan 文本上增加：

```text
bind 1 0 0
```

表示 body 1 的 param 0 绑定到 channel 0。`corec conc-plan` 在 `go` 目标有一个 string 参数时生成该行，并同时发出 request channel 的 `SEND` edge：

```text
bind 1 0 0
edge 0 1 SEND 0
edge 0 1 SPAWN -1
```

runtime 新增：

- `conc_plan_bind_count(plan)`
- `conc_plan_bind_param(plan, body, param, channel)`
- `conc_plan_param_channel(plan, body, param)`
- `conc_run_body_bound(plan, body, channels)`
  - `channels` 是 raw table：`cell_load(channels, channel_id*8)` 是 handle 指针。
  - TASK params=1 时用绑定 channel 调用；无绑定/空表/越界返回 `-1`。

plan 记录第 72 字节保存 bind block 指针；block 有 count/cap + 32 条 24B 记录。loader 解析 `bind` 行并校验 body/param/channel、重复绑定。

## 2. 测试

```text
test_conc_plan_emitter.py   21/21
test_conc_plan.py            4/4
test_conc_runtime.py        13/13
test_chan_handle_model.py   11/11
```

- emitter：params=1 的 plan 含 `bind 1 0 0` + `edge 0 1 SEND 0`；zero-arg 只发 SPAWN；所有 CP-2 fail-closed case 保持。
- loader：`conc_plan_bind_count` / `conc_plan_param_channel`；bind channel 越界、重复 bind、body 越界均返回 `-1`。
- E2E：compiler plan 的 `bind` 指向 channel 0；runtime 用 channel table 执行 body 1，原始 `chan_recv` worker 返回 41。不再手写传 channel 给 body。

完整 `selfhost-tests` 中 CP-1/2/3 gate 先执行并通过：

```text
PASS conc_region ... PASS conc_negative     13/13
PASS emitter_fixture ... PASS emitter_fail_closed_preexisting  21/21
PASS conc_plan_load
PASS conc_plan_simt
PASS conc_plan_negative
PASS conc_plan_e2e                           4/4

FAIL test_p41_dynamic_string_arena_switch_path: run rc=-11
44/45 passed
CI_EXIT=1
```

p41 仍是 CP-1 基线 `1e47f93f` 上已复现的旧 0A 问题，不是 CP-3 引入。

## 3. 边界（CP-4+）

- 多 channel 的 go 实参→channel id 显式绑定；当前只支持单 `go` + 单 `chan_make`。
- worker body 内 send/recv edge 的完整抽取；当前只发 request channel 的 SEND 和 SPAWN。
- 默认 `go`/`chan` lowering 切换到 plan 执行。
- 阻塞 send/recv、fiber 调度、close/零容量/MPMC。
- 真实 GPU/FPGA/集群、transfer MOVE/LOAN/SPLIT/FILL、多 slot、预算/证书。
- 正式 MessageRef `(region_id, offset, layout)` 身份与 reset+复用 ABA。

## 4. 不变量核对

| 不变量 | CP-3 证据 |
|---|---|
| plan 旁路 | `bind` 只在 `.plan` 文本，不进入 `.ccr` |
| 编译期事实不复算 | emitter 发 bind；runtime 只按 descriptor 查表 |
| fail-closed | body/param/channel 越界、重复 bind、空 channel table 均 `-1` |
| 默认 lowering 不变 | `go`/`chan` 回归 11/11、runtime 13/13 |
| target-neutral | bind 只有 body/param/channel id，无 CPU/GPU/slot 字段 |
