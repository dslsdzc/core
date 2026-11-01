# CP-2 实现记录：编译器 plan emitter + runtime plan loader

**日期：** 2026-11-02
**状态：** CP-2 host 纵向切片完成；真实 GPU/FPGA/集群、transfer 全 primitive、多 slot、预算/证书留 CP-3+。
**计划：** `docs/superpowers/plans/2026-11-02-conc-plan-emitter.md`
**规格：** `docs/superpowers/specs/2026-11-01-cross-paradigm-concurrency-design.md`

## 1. 范围

CP-2 完成“编译器生成 target-neutral plan artifact → runtime 解析/加载 → CPU/SIMT 执行”的 host 纵向切片；emitter 当前生成 TASK body，PAR 由 loader 手写 plan 验证：

- 新编译器子命令 `corec conc-plan file.cr -o file.plan`。
- 新 `src/compiler/conc_plan_emit.cr`：在 lowering 后的 IR 上做保守模式匹配。
- 新 `conc_plan_load(text, entries)` / `conc_run_body(plan, body, arg)` / `conc_plan_add_edge_ch`。
- plan 文本 artifact，不进入 `.ccr`；默认 `go`/`chan` lowering 不变。
- loader 能加载 TASK 和 PAR body；编译器 emitter 当前只生成 TASK body。SIMT 对拍使用 loader 手写 PAR plan，不用来声称编译器已生成 PAR。

## 2. Plan artifact v1

```text
v 1
entries 2
body 0 TASK 0 0
body 1 TASK 1 1
channel 0 8 1 SPSC
edge 0 1 SPAWN -1
```

- `entries N`：entry table 大小；`cell_load(entries, i*8)` = body i 的入口地址。
- `body <id> TASK|PAR <entry_index> <params>`。
- `channel <id> <elem_size> <cap> SPSC`。
- `edge <from> <to> SPAWN|SEND|JOIN|RECV <channel_id|-1>`；edge 的 channel id 保存在 CP-1 edge 记录的 reserved 槽。
- loader 对未知 token、缺失版本、越界 id、非 SPSC、entry 越界、entry=0、`entries` 与 entry table 长度不符、过大 `entries`、edge 引用不存在 channel、SEND/RECV 无 channel、SPAWN/JOIN 带 channel 一律返回 `-1`。
- entry table 合约：`entries N` 要求调用方提供至少 `N*8` 字节的 raw table；loader 用 `str_len(entries)+1` 校验。

## 3. Emitter 子集与 fail-closed

支持：

- `main` 内恰好一个 `sched_go`，且 `main` 自身没有参数；
- `main` 内恰好一个 `chan_make`；多 channel 的 handle 绑定尚未建模，CP-3。
- `chan_make` 的 `elem_size`/`cap` 在调用点有唯一 reaching definition，且该定义是整数字面量（调用后的重赋值不影响；分支/多定义/函数调用/全局读一律拒绝）；
- `go` 目标函数有 0/1 个参数；1 个参数时必须是 `string`（channel handle）；
- `sched_go`/`chan_make` 不在 loop/if/flow/unsafe 子图内；
- 输出 body 0 = main placeholder（entry index 0，不执行）、body 1 = spawned body（entry index 1）。

不支持时打印 `error: conc-plan unsupported: ...`，rc=1，目标路径被删除（零 artifact）：

- 多个 `sched_go`；
- 多个 `chan_make`；
- `main` 有参数；
- 动态/多定义/非字面量 `chan_make` 参数；分支/循环内的单次定义；local 取地址后被 helper 改写；
- `go` 目标参数 >1 或参数不是 string；
- `go`/`chan_make` 在 loop/if 内；
- `sched_go` arity 不是 2；
- frontend/type-check/lowering 失败时目标路径也会被删除（零 artifact）。

当前不分析 worker body 内部的 send/recv 边；plan 只发出 `SPAWN` edge。channel handle 的 aliasing 与“go 实参指向哪个 channel”的显式绑定也不分析；CP-2 通过限制为单 channel 来避免歧义（CP-3 建模多 channel 绑定）。

## 4. 验证

### 4.1 Emitter

```bash
nice -n 19 python3 tests/selfhost/test_conc_plan_emitter.py
```

实测：

```text
PASS emitter_fixture
PASS emitter_zero_arg
PASS emitter_mut_cap_before_call
PASS emitter_non_cr_default_output
PASS emitter_fail_closed_multi_go
PASS emitter_fail_closed_dynamic_cap
PASS emitter_fail_closed_int_go
PASS emitter_fail_closed_go_literal
PASS emitter_fail_closed_go_no_arg
PASS emitter_fail_closed_two_param_go
PASS emitter_fail_closed_main_param
PASS emitter_fail_closed_global_cap
PASS emitter_fail_closed_loop_go
PASS emitter_fail_closed_no_chan
PASS emitter_fail_closed_go_helper
PASS emitter_frontend_failure_zero_artifact
PASS emitter_fail_closed_branch_cap
PASS emitter_fail_closed_alias_cap
PASS emitter_fail_closed_multi_chan
PASS emitter_fail_closed_no_chan
PASS emitter_fail_closed_go_helper
PASS emitter_fail_closed_preexisting
20/20 passed
```

- `emitter_fixture`：`go worker(req)` + `chan_make(8,1)`，产物逐行匹配。
- `emitter_zero_arg`：`go worker()` 产出 `body 1 TASK 1 0`。
- `emitter_mut_cap_before_call`：`cap=1` 在调用后重赋 2，plan 仍用调用点的 1。
- `emitter_non_cr_default_output`：非 `.cr` 输入默认写 `<src>.plan`，不覆盖输入。
- fail-closed：多 `go`、函数调用形式的动态 cap、`go worker(0)`（int 参数）、字面量 `go` 实参、单参数 target 的 `go worker()`、两参数 target、main 形参、helper 后写全局、loop 内 `go`、分支内 `chan_make` cap、`&cap` 被 helper 改写、多/无 `chan_make`、`go` 在 helper、预存在输出，以及 frontend 失败，全部 rc=1 且目标路径不存在。

### 4.2 Runtime loader + E2E

```bash
nice -n 19 python3 tests/selfhost/test_conc_plan.py
```

实测：

```text
PASS conc_plan_load
PASS conc_plan_simt
PASS conc_plan_negative
PASS conc_plan_e2e
4/4 passed
```

- `conc_plan_load`：手写 plan 文本 + entry table，加载后 `conc_run_body` 执行 worker；短 entry table、巨大 `entries`、entry=0、edge channel 越界/SEND -1 等负例均返回 `-1`。
- `conc_plan_simt`：PAR plan 在 CPU 和 host-SIMT 上逐项对拍。
- `conc_plan_negative`：body entry 越界、未知 token、非 SPSC、版本 2 均返回 `-1`。
- `conc_plan_e2e`：`corec conc-plan` 生成 plan → 读回文本 → 生成 Core fixture（entry table + `conc_plan_load`）→ 用 plan 的 channel descriptor 创建 `chan_make(8,1)` → `conc_run_body` 调用**原始 `chan_recv` worker** → 返回 41。body 0 与 SPAWN edge 仍未执行，属于 CP-3；该测试证明的是“compiler plan 的 body/channel 描述被真实消费”，不是完整调度图执行。

### 4.3 默认 lowering 回归

CP-2 不修改 `go`/`chan` lowering；`test_conc_runtime.py` 13/13、`test_chan_handle_model.py` 11/11、`test_go_arena.py`、`test_rt_tls.py`、`test_compile.py`、`test_pub_visibility.py`、`test_raw_abi_boundary.py` 继续通过。`corec check src/compiler` 也在 `_import.cr` 加入 `conc_plan_emit` 后通过。

### 4.4 完整 selfhost-tests

完整套件仍会在既存 p41 处变红（CP-1 基线 `1e47f93f` 已复现，与本阶段无关）。CI 中 CP-1/CP-2 测试排在 `test_merge_copy.py` 之前，实测 gate 先执行：

```text
PASS conc_negative
PASS emitter_fixture
PASS emitter_zero_arg
PASS emitter_fail_closed_multi_go
PASS emitter_fail_closed_dynamic_cap
PASS conc_plan_load
PASS conc_plan_simt
PASS conc_plan_negative
PASS conc_plan_e2e

FAIL test_p41_dynamic_string_arena_switch_path: run rc=-11
44/45 passed
CI_EXIT=1
```

## 5. 未做项（CP-3+）

- worker body 内的 send/recv edge 抽取；当前只发 SPAWN edge。
- 默认 `go`/`chan` lowering 切换到 plan 执行；CP-2 是显式 `conc-plan` + 显式 loader。
- 真实 GPU/SIMT 后端、FPGA/集群映射。
- MOVE / LOAN / SPLIT / FILL 的 transfer 执行器。
- 多 slot / multi-M、真实并发调度。
- close、零容量 rendezvous、MPMC。
- 预算/证书/explain。
- 正式 MessageRef `(region_id, offset, layout)` 身份与 reset+复用 ABA。

## 6. 不变量核对

| 不变量 | CP-2 证据 |
|---|---|
| 不新增源码语法 | 只新增 `corec conc-plan` 子命令和 stdlib API |
| plan 旁路 | `.plan` 文本 artifact，不写 `.ccr` |
| 编译期事实不复算 | emitter 从 IR 提取 body/channel/edge；runtime 只解析/执行 |
| target-neutral | plan 无 CPU/GPU/slot/memory 字段 |
| fail-closed | emitter 对多 go/main 形参/非字面量/嵌套/坏参数零 artifact；loader 对短 entry table、越界 edge channel、非法 token 返回 `-1` |
| 默认 lowering 不变 | `go`/`chan` 回归通过 |
