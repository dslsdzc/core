# R2 P6 Task 4a 报告：E-11 `-> never` 调用返回型（消除两个站点的误报，发射面零变化）

日期：2026-09-14 · 起点：合流树工作副本 `9cfa6246`（双亲为 T2 `911c692d` 和 T3 `0819d506`；自带空 `build/`） · 隔离 workspace：`/tmp/p6mrg`（主树 `/home/DslsDZC/core/` 零写入，唯一例外是本报告） · 提交：`9bdbdf16`（change id `yzwnpuuv`；双亲合并提交，见第 6 节-1）
纪律：全部 `nice -n 19`、逐段用 `ps` 实查、比较前 `clean-cache`、版本控制只用 `jj`、突变一律在仓库外实拷贝
先裁（协调者 2026-09-14）：① 重新固定 `t6_S1_never_unit`，采纳；② 姊妹站点（方法调用）并入（先证同形）；③ `EXPR_ASSIGN` 缺 never 豁免，入 TODO 登记；④ 泛型、extern、模块三面明确不动（extern 面须在守卫里显式排除）。E-12 半身挂裁-P6-2，本任务不实施（止于定位点点登记）。

---

## 1. 前置和先裁

### 1.1 合流健全性首检（「合流未破」的证据，不是 T4a 判据）

| 项 | 实测 | 期望 | 判定 |
|---|---|---|---|
| `build_selfhost_native.py`（合流树） | rc=0 · 非 GUARD `error[` = 0 · corec/corearch/corelsp 三处 `build log clean` | rc=0 + 0 | 通过 |
| 冒烟 `corec run 'fn main()->int{return 42;}'` | rc=42 | 42 | 通过 |
| `selftest-types` | 415/415 | 415 | 通过 |
| `test_ccr_types` / `test_ccr_v7` / `test_region_cfg` | 48/48 / 27/27 / 22/22 | 相同 | 通过 |

### 1.2 定位点点实核与姊妹站点同形判定

- 落笔前重核（T2/T3 两批提交都不含 `checker.cr`，实核行号未漂）：`:526`（声明位豁免③）、`:1491`（注册域守卫）、`:2234`（返回位豁免）、`:2691-2697`（方法尾）、`:2744-2753`（直调尾）。
- 同形判定（裁② 的前置硬约束）：同形。A 同 `sym_type(si)` 读取（`:2694` 对 `:2752`）；B 同 `fi_return_type` 可取，方法由 `parser.cr:1887-1889` 以 mangled 名（`"S.m"`）走同一个 `parse_body`（`:1362`）到 `add_func`（`:1457`/`:1302`），因此与直调面使用同一张 g_funcs/符号表、同一钳位点 `:1491`；C 同发射面消费者 `ir_gen.cr:1660-1663`（`ir_call_return_type` 到 `new_ir_var("call", call_ti)`），且本补丁不改 `sym_type` 值，因此两站点同为零耦合。
- 一处结构差异（显式对齐）：方法尾没有泛型早退（直调面的 `:2749-2751` 会提前走 `infer_gen_call`），因此方法守卫补 `fi_generic_count(fi_m) == 0`；方法恒非 extern（`parser.cr:1864-1899` 的 impl 分支只认 `T_FN`），因此方法面不需要 `EXPR_FN` 限定。两站点行为等价，不是逐字镜像。

### 1.3 本任务自纠两处（都有实读依据）

1. extern 排除（守卫④）由可选升格为必需：extern 函数也在 g_funcs（`checker.cr:1584-1592`，`fi_return_type = TY_NEVER`），且符号侧 `sym_type = TI_UNIT`，裸补丁会把 extern 一并透传，违反裁④，并额外破坏 `t6_S3_never_unit`。裁决后落为守卫④（`ast_kind(fi_ast_node(fi)) == EXPR_FN`），并由突变 Mu3 验证。
2. `test_let_check` 的计数注陈旧：`run.sh` 注记写「23 例」，三处提交实读都是 24（P5 期遗留差 1），本批一并纠正并在注中写明。

---

## 2. 用例 RED 到 GREEN 实测（替换侦查期的纸面值）

口径：`<corec> check <probe>`（cwd 为 `/tmp/p6mrg`）；探针源为 `/tmp/p6t4/probe_*.cr`；日志为 `red.log` / `green.log`。

| 站点 | 探针 | RED（未打补丁） | GREEN（打补丁后） |
|---|---|---|---|
| ① 直调声明位 | `probe_m1`（`fn boom() -> never { loop { } }` 加 `x : int = boom();`） | rc=1 加 `error[TA02]: Variable declared as int, got unit` | rc=0 |
| ② 直调返回位 | `probe_m2`（`fn f() -> int { return boom(); }`） | rc=1 加 `error[TF01]: Function return type mismatch` | rc=0 |
| 变量传播位 | `probe_m3` | rc=1 加 `error[TF01]` | rc=0 |
| 方法站点（裁②） | `probe_m5`（`impl S { fn m(self: S) -> never }` 加 `x : int = s.m();`） | rc=1 加 `error[TA02]` | rc=0 |
| 死分支端到端 | `probe_m4` | build rc=1 加 `error[TA02]`，无产物 | build rc=0，运行 rc=42 |
| extern（裁④：不动） | `probe_p2` | rc=1 加 `error[TA02]` | rc=1 加 TA02（不变） |
| 泛型方法（不动） | `probe_p3` | rc=1 加 `error[TA02]` | rc=1 加 TA02（不变） |
| 赋值位（登记） | `probe_p5`（`busy = boom();`） | rc=1 加 `error[TA01]: Assignment type mismatch` | rc=1 加 TA01（不变） |
| near-miss 负控 | `probe_c3`（普通 int 调用） | rc=0 | rc=0（不变） |
| 语句位宽面 | `probe_c5` | rc=0 | rc=0（不变） |

机制（RED 归因，实读）：根因是声明注册趟的域守卫 `:1491`（`rt_mapped != TI_NEVER`）把 NEVER 钳成 unit（`never` 在 `parser.cr:94` 是 ast-kind-0 基类型节点，走 `fi_return_type` 裸码路径），SYM_FN 符号类型变成 unit，于是 ① 声明位豁免③（`val_ti == TI_NEVER`）不触发，`type_compat_strict(unit, int)` = 0，报 TA02；② `EXPR_RETURN` 推断（`:3092-3097`）的返回调用值是 unit，`body_ti != TI_NEVER` 成立，报 TF01。

---

## 3. 实现（两个站点守卫；首次编译即验 SR0）

HUNK-1 直调站点（`infer_expr` 的 `EXPR_CALL` 分支、SYM_FN 非泛型尾）：守卫四条。① 泛型由既有早退排除；② `sym_type(si) == TI_UNIT`；③ `fi_return_type(fi) == TY_NEVER`；④ `ast_kind(fi_ast_node(fi)) == EXPR_FN`（排除 extern 面）。嵌套 `if` 是硬约束：bootstrap 构建的 corec 对 `&&` 两侧无条件求值（`bootstrap/corec/frontend/ir_gen.py:226-235`），而 `fi_return_type`（`dyn_arr.cr:459`）和 `ast_kind`（`dyn_arr.cr:370`）都没有护栏，因此不能写 `guard && 表读`。首次编译即验：重编译 rc=0、非 GUARD `error[` = 0、没有 P21 类结构错。

HUNK-2 方法姊妹站点（裁② 并入）：同形判定见第 1.2 节；守卫为 `fi_m := find_func(func_ni)` + `fi_generic_count(fi_m) == 0` + `sym_type(si) == TI_UNIT` + `fi_return_type(fi_m) == TY_NEVER`（嵌套 if，同上）。

语义边界（只改推断结果，不改发射）：`sym_type(si)` 的值不动，因此 `ir_gen.cr:464 ir_call_return_type`（唯一消费者是 `:1662-1663` 的 `new_ir_var("call", call_ti)`）不变；`EXPR_LET` 的局部类型在 ir_gen 侧只取注解类型节点（`ir_gen.cr:2092-2115`），不读 checker 符号表，因此发射面零耦合。

HUNK-3 重新固定（裁①）：`tests/selfhost/test_iface_ops.py` 的 `t6_S1_never_unit` 从 `case_diag_lines(..., [("TF01", 2)])` 改判为 `case_ok(...)`（rc=0）。改前固定的是误报（`f()` 发散，`return x` 不可达），改后固定正确行为；注释改写并注明「S1 链注册值仍落 unit」的证据面改由 `t6_S3/S4/S5/S6` 四个固定项加 `t6.never_cell_diff` 承担。

用例增加 10 个（对比改动前实读计数）：

| 套件 | 计数 | 新例 |
|---|---|---|
| `test_let_check.py` | 24 到 29 | `let_never_call_ok` · `let_ordinary_call_unchanged` · `call_result_mismatch_still_rejected`（强负控，Mu2 的判别力）· `never_stmt_position_unchanged` · `assign_never_still_ta01` |
| `test_tf01_fallthrough.py` | 19 到 22 | `pos_never_call_return` · `pos_never_call_propagates` · `run_never_call_dead_branch` |
| `test_iface_ops.py` | 76 到 78 | `t4a_method_never_call` · `t4a_method_generic_never_unit`（另有重钉 1 条，不增减） |

套件全部通过：29/29 · 22/22 · 78/78；`src/ci/run.sh` 三处计数注同步（含第 1.3 节-2 的陈旧自纠）。

---

## 4. 判据全套（基线为合流树 `9bdbdf16` 的前态；协调者给定值逐条实测）

| 判据 | 实测值 | 判定 |
|---|---|---|
| ELF canary（硬检查） | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`（28822B） | IDENTICAL，通过 |
| `.ccr` 四条冷态（T3 新锁值） | `ptr_arith` ccr 96015B `680a6f98…` / static 96158B `76f36e6a…`；`generics_test` 142793B `41e9d845…` / 142936B `704316c8…`；差恒为 143B | 四条逐字节同，通过 |
| 72 档对拍（`tools/baseline/parity_run.sh`：基线为 `/tmp/p6t1/base/corec`，允许清单三个 sha 实核；当前为 `/tmp/p6mrg/build/corec`） | `diff -rq` 零差异；两侧 rc 分布均为 34×0 / 38×1；144 个日志×2 全等 | 通过 |
| 探针 29 档（`tools/baseline/probes_run.sh`） | 两态 `diff -rq` 零差异 | 通过 |
| 五 CI job（最终认证轮，源冻结后） | `check` / `bootstrap-tests` / `suite` / `selfhost-tests` / `full-bootstrap`，5/5 rc=0 | 通过 |
| 全枚举 | 58/58（51 个 selfhost 加 7 个 bootstrap；逐套件 rc 台账 `enum.out`） | 通过 |
| `check src/compiler` | rc=0 | 通过 |
| `selftest-types` | 415/415（不增减，本任务未动 `type_selftest.cr`） | 通过 |
| 自举链 | `corec2 == corec3` = `0b2e06d0c8b2f78402d08950364fb224db697fdf2e5b6e5d0d6a06e85fc581c1`（2880022B）×2；N06=0；冒烟 42；`--help` rc=1 | 通过 |
| `test_backend_bootstrap` | rc=0，日志 `error[` = 0（未挂 run.sh，单跑） | 通过 |

对拍口径注（本任务实测结论）：72 档语料零差异。「误报消失类 diff」的实现方式是套件 leg（`t6_S1_never_unit` 从 rc=1 加 TF01@2 转为 rc=0），不在 72 档语料中（`parity_run.sh` 的 5 个 tier 覆盖面实读：不含套件内联源）；72 档如果出现 diff 就是越界信号（停条件）。

---

## 5. 突变控制 Mu1-Mu5（仓库外实拷贝 `/tmp/p6t4/mut`；逐条重建后跑目标探针）

| # | 突变 | 期望变为失败 | 实测 | 判定 |
|---|---|---|---|---|
| Mu1 | 删除直调站点守卫（HUNK-1 整段） | m1/m2 再次失败 | `probe_m1` rc=1（TA02 复现），`probe_m2` rc=1（TF01 复现） | 通过 |
| Mu2 | 直调守卫退化为无条件 `return TI_NEVER`（去掉判据条件） | 强负控变为失败 | rc=1，但形态是 stdlib 自身编译失败（`error[TA01] Assignment type mismatch @ src/stdlib/fmt.cr:279`），任何 probe 都是 rc=1；目标用例的抑制效应被更早的失败掩盖（变为失败成立且更明显，形态与预测不同，如实登记） | 通过（形态注） |
| Mu3 | 去掉守卫④（`EXPR_FN` 限定） | extern 探针转为通过，即越裁④ | `probe_p2` rc=0（extern 调用被透传） | 通过 |
| Mu4 | 删除方法站点守卫（HUNK-2 整段） | m5 再次失败 | `probe_m5` rc=1（TA02 复现） | 通过 |
| Mu5 | 方法守卫的泛型条件失效（`== 0` 改为 `>= 0`） | 泛型方法转为通过 | `probe_p3` rc=0 | 通过 |

回滚：`/tmp/p6t4/mut/src/compiler/checker.cr` 已恢复为 T4a 正本（`cmp` 逐字节同）；突变体和正本都在仓库外，主树与合流树零污染。

---

## 6. 偏差和登记

1. 提交形态（协调者已裁决：接受）：`9bdbdf16` 是双亲合并提交（双亲为 T2/T3）。协调者给的合流态 `9cfa6246` 当时仍是未提交的工作副本变更，`jj commit` 直接把它落成带 T4a 描述的合并提交（未另起「合并 + T4a」两段）；树内容正确，不做 rebase/split。
2. 过程事件（我的流程错误，已作废并重跑）：CI 首轮 `selfhost-tests` rc=2。我在该 job 执行期间编辑 `src/ci/run.sh`（计数注同步），bash 增量读取被截断（`line 137: unexpected EOF`）。`bash -n` 复核实为语法完好；处置是源冻结后重跑全部五个 job（第 4 节的 5/5 是重跑结果）。
3. `EXPR_ASSIGN`（赋值位）没有 never 豁免（既有缺口，不是本改动引入）：`busy = boom();` 改前（源为 unit）和改后（源为 never）都报 TA01。同族豁免已在声明位（`:526`）、返回位（`:2234`）、if 合并（`:2863`）三处，赋值位是剩余缺口，记为 TODO #52（本批不修）。
4. 同族未修（裁④ 明确不动，各附理由）：泛型调用（`res_call_type:1829` 钳位，自测 `t6.never_cell_diff`，套件 `t6_C_never_call_unit`）· extern（注册域 `:1574`，套件 `t6_S3_never_unit`）· 模块限定（`g_mod_func_tis`，`:1642` 填，`:2587` 读）。
5. E-12（#20/F3 调用位点诊断）未实施（挂裁-P6-2，本任务止于定位点点登记）。实读订正：「非泛型调用位点」不是待定位，而是不存在。已知 SYM_FN 的非泛型调用分支（`:2744-2753`）连实参推断都不走（对照模块 `:2584`、方法 `:2689`、SO `:2729`、外部未知 `:2773`、枚举构造器 `:3109` 五处都有走查），因此 E-12 实施是在该分支新增判定点；参数型取法（`fi_param_type` 自带护栏或 EXPR_PARAM 链导航）已写入计划 Task 4 Step 4 和附录 E-12 行。
6. `tt_display_at` 面：本任务零接触（E-7 归 T5），没有新增证据，也没有新增登记项；P6 计划 Task 4 节勘误和附录 E-11/E-12 行勘误已随本提交并入。
7. `test_let_check` 计数注陈旧 1 条（23 对实读 24）：不是本改动引入，本批自纠并写明。

---

## 7. 证据路径（全部在 `/tmp/p6t4/` 下的文件）

| 用途 | 路径 |
|---|---|
| 本任务汇总报告（同内容加更多细节） | `/tmp/p6t4/t4a_report.md` |
| 补丁草案（含 SR 语法风险清单和同形判定） | `/tmp/p6t4/t4a_patch_draft.diff` |
| 用例草案 / 计划勘误草案 | `/tmp/p6t4/t4a_cases_draft.md` · `/tmp/p6t4/t4a_erratum_draft.md` |
| 前置侦查报告（含 E-12 定位点点表） | `/tmp/p6t4/recon.md` |
| RED / GREEN / 探针日志 | `/tmp/p6t4/red.log` · `green.log` · `red_check.log` · `run_probes.sh` |
| 合流首检和重编译日志 | `/tmp/p6t4/build_merge.log` · `build_t4a.log` |
| canary / `.ccr` 记录 | `/tmp/p6t4/canary_t4a.bin` · `ccr_check.sh` · `*_ccr.ccr` · `*_static.bin.ccr` |
| 72 档对拍 / 探针 29 档 | `/tmp/p6t4/parity_{base,cur}/` · `parity_diff.txt`（空） · `probes_{base,cur}/` · `probes_diff.txt`（空） |
| 五 CI job / 枚举 / 自举链 | `/tmp/p6t4/ci_*.log` · `ci_all.sh` · `enum.out` · `enum_*.log` · `backend_bootstrap.log` |
| 突变（Mu1-Mu5） | `/tmp/p6t4/mut/`（仓库外实拷贝，已回滚至正本） · `apply_mut.py` · `run_mut.sh` · `mut_build_*.log` · `checker_t4a_final.cr` |
| 提交信息全文 | `/tmp/p6t4/commit_msg.txt` |
