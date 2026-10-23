# FC 批 T3 报告：隐藏通道 `--diag-gate-report`（report-only 二次核对实现方式）

日期：2026-09-15。任务：FC 计划 T3。起点：`b01a948c`（FC T2 收官）。提交：`3990a0a5ccefdab3c40805ac4401d103febac80c`（change `wmnupkpl`，路径限定 3 个文件）。
工作地：`/tmp/p7wt`。二进制 `build/corec` 为 `308f06a3…`，`corearch` 为 `22e96d03…`。纪律同前：`nice -n 19`，逐段 `ps`，`clean-cache`，canary 无豁免，路径限定提交。

---

## 0. 摘要

| 项 | 结果 |
|---|---|
| 形态 | `main.cr` 注册 `cli_flag_bool("diag-gate-report", …)`（与 `--verify-*` 家族同址同式），并在检查门内输出只读报告行 `[diag-gate] face=build blocked=N total=M codes=<用户面码名,…>` |
| 默认关时零行为差异 | 72 档 parity `diff -rq` 零输出；探针 29 档零差异（与 FC-T2 基线逐字节相同） |
| 开态只多一行 | rc 和产物 sha 逐字节相同（canary 两态均为 `95084e7b…d475`），日志只多标记行 |
| 重放对表（对比 T1） | 101 档重放，无表外命中（语料 25 档 blocked 与 T1 的 34 行对齐；探针 11 档属于 T1 未覆盖面，口径差已登记） |
| 判据全套 | 五个 CI 5/5 rc=0，枚举 60/60，selftest 415/415，canary IDENTICAL，`.ccr` 四条相同，dump 3521，cir 165915B，自举链 `24802386a1…` IDENTICAL，`backend_bootstrap` rc=0 |
| 环境干扰（非本批） | 测量期间 `build/` 被外部删除两次，`examples/*.{ccr,cir,o}` 的 tracked 文件也被删除，首轮两条腿作废。重建后重跑取得有效值。那批 `D` 未提交也未还原（铁律 #3） |

---

## 1. 落码（路径限定 3 个文件）

| 文件 | 内容 |
|---|---|
| `src/compiler/main.cr` | ① `cli_flag_bool("diag-gate-report", "", "FC T2: report fail-closed gate verdicts per compile (debug; default off，不改 rc/产物)")`；② 在检查门循环内累计 `n_block`/`rep`（默认关时恒为 0，零行为影响）；③ 在检查门块内、`print_diagnostics()` 之前输出报告行（`if cli_has("diag-gate-report") != 0`） |
| `TODO.md` | #61（T3 条目：形态、判据、对表、口径注、登记） |
| FC 计划 | 勘误节（T3 实施、口径注、环境干扰登记） |

口径注（重要）：报告面只覆盖前端类型面检查（`g_diag_count > 0` 块）。解析阶段检查（`:134/:135`，例如 P21）和安全检查面检查（`:594-603`，例如 TU03）的诊断不会出现在报告行中，因为它们不经过 `diag_gate_exempt`。

---

## 2. 默认关的两态证据（`--diag-gate-report` 关与开）

| 档 | rc 关/开 | 产物 sha 关/开 | 日志差异 |
|---|---|---|---|
| `tests/suite/arena_test.cr` | 0 / 0 | `4e645e9c…` / `4e645e9c…` | 只有输出路径回显（测试自身使用不同的 `-o`）；无标记行（无诊断） |
| `tests/suite/ptr_arith.cr` | 0 / 0 | `95084e7b…d475` / 相同 | 只有标记行 `[diag-gate] face=build blocked=0 total=1 codes=` |
| `tests/suite/ptr_ref_first.cr` | 0 / 0 | `f38cdb6a…` / 相同 | 只有标记行（`blocked=0 total=3 codes=`） |
| `/tmp/fct3/ctl2/b6_tu03.cr`（TU03 冷态） | 1 / 1 | 无产物 / 无产物 | 0 行差异（TU03 属于安全检查面，不在报告面，符合口径注） |

结论：默认关时与关态逐字节相同（72 档加探针两条腿已经证明）；开态只多一行标记，rc 和产物不变。

---

## 3. 重放与对表（对比 T1 的 `hits.tsv`/`would_block.tsv`）

方法：用 `check <file> --diag-gate-report` 逐档重放 101 档（72 档语料加 29 档探针），抽取标记行，输出到 `/tmp/fct3/replay_gate.tsv`，再与 T1 表做集合差。

| 面 | 重放结果 | 与 T1 对齐 |
|---|---|---|
| 72 档语料 | 25 档 blocked>0（N 族、TA01、TB01 级联；逐档码串完整） | 等于 T1 `would_block.tsv` 的 34 行，减去 7 行 build 面豁免（chan/conc/go_e2e/go_final/go_parallel/ptr_arith/ptr_ref_first），再减去 2 行 P21（`at_test_mini4/6`，属于解析阶段检查，不在本报告面），逐条对齐 |
| 探针 29 档 | 11 档 blocked（TA01 九档、TS03 一档、N 族一档） | T1 表未覆盖探针面（口径差已登记）。这些档是负例（期望 rc=1），其阻断与期望一致 |
| 表外命中 | 0 | 重放集合是 T1 预测、豁免表语义和口径差登记的并集的子集 |
| 豁免码出现在豁免面之外 | 0 | 通过 |

---

## 4. 判据全套

五个 CI job 为 5/5 rc=0。全枚举 60/60。`selftest-types` 415/415。canary `95084e7b…d475`（28822B）IDENTICAL。`.ccr` 四条为 96015 / 96158 / 142793 / 142936（差恒为 143B）。`--dump-objects` 为 3521。`.cir` DOT 为 165915B `b1bdf480…`。自举链 `corec2==corec3` IDENTICAL（`24802386a1…`；新值是 T3 修改 `main.cr` 所致，符合预期），N06=0，冒烟 42。`test_backend_bootstrap` rc=0。72 档对拍（对比 T2 基线）零差异。探针零差异。

---

## 5. 环境干扰事件（登记；非本批代理所为）

- 现象：`build/` 整个目录被外部删除两次（约 18:50 和 18:53）。`examples/add/main.ccr`、`examples/add/main.cir`、`examples/complex/main.ccr`、`examples/complex/prog.o`、`examples/test_max.ccr`、`examples/test_max.o`、`examples/test_scale.ccr`、`examples/test_scale.o`、`examples/test_sum.ccr` 等 tracked 文件被删除（`jj status` 中显示为 `D`）。`/tmp/fct3/parity_{t2,t2b,t2c}/parity.out` 被删除（`logs/` 幸存）。
- 后果：首轮 `parity_t3`/`probes_t3` 测量作废（二进制在运行中被删除，rc=127：parity 21 档 rc=0、51 档 rc=1，probes 的 rc.txt 全部为 127）。已重新运行并取得有效值（34 档 rc=0 / 38 档 rc=1，17 档 rc=0 / 12 档 rc=1），与 T2 基线零差异。
- 重建确定性旁证：两次重建后的 `corec` sha 均为 `308f06a3…`，冒烟结果为 42，说明干扰不改变构建产物。
- 处置：那批 `D`（tracked 文件删除）未提交、未还原（铁律 #3：还原需要维护者明确许可）。提请维护者处置。本轮提交为路径限定，不受影响。

---

## 6. 登记项

1. 报告面口径：只覆盖前端类型面检查（P21/TU03 等不在内）。重放和对表须按此解读（已写入计划勘误）。
2. `blocked` 计数粒度：按逐条诊断计数，不去重。同一个码多次命中会重复出现，保留原样，便于定位。
3. 探针面在 T1 表中的缺口：T1 `would_block.tsv` 只覆盖 72 档加 build 面，探针面的命中由本 T3 重放补记（11 档）。
4. 环境干扰（第 5 节）待维护者处置。

---

## 7. 证据路径

| 用途 | 路径 |
|---|---|
| 本文 | `/tmp/fct3/t3-report.md`，归位到 `/home/DslsDZC/core/docs/archive/sdd/fc-task3-report.md` |
| 状态盘 | `/tmp/fct3/t3-state.md`（含干扰事件记录） |
| 两态证据 | `/tmp/fct3/t3_{arena_test,ptr_arith,ptr_ref_first}_{off,on}.log` 加 `.bin`，以及 `t3_{off,on}.log` |
| 重放对表 | `/tmp/fct3/replay_gate.py`、`replay_gate.tsv` |
| 判据原始件 | `/tmp/fct3/parity_t3/`、`probes_t3/`、`enum_t3/`、`ci_t3_*.log`、`t3_pa`(canary)、`t3_{pa_c,pa_s,gt_c,gt_s}.ccr`、`t3_gt.cir` |
