# R2 P5 任务 4 报告：删除 `type_equal_legacy` 和全部回落面，另删桥接 legacy 副本、不可达分支和站点 6

日期：2026-09-13。起点：`faca94e0`，P5 任务 3b，工作副本为空，`jj status` 干净，起点 `build/corec` 为 `f0862d70…`。

产物：`build/corec` 为 `eae13428cfe881c832d4f836d30361d529b70578a37cb281cc743c9fc3e755d5`，`build/corearch` 为 `cc2a7e6de0ed95e3692a10fb645872590be9214dcf343179eb59dc871260240f`。

报告口径：数字全部由本实例实测，命令和原始输出路径见第 8 节；未实测的标为“未测”。

## 0. 摘要

清零判据成立，全语料 `replace_*=0`，因此按 D24 的顺序删除以下内容：`type_equal_legacy`，含 7 处递归自调；两处回落；`g_replace_*` 计数；桥接 legacy 副本 `sh_*_ak_legacy`；`EXPR_BINARY+OP_ASSIGN` 不可达分支和站点 6，涉及 `checker` 和 `ir_gen` 两侧；影子对照物调用点，`sh_compare` 停摆，其余部分留到任务 5。

判定采用引擎唯一权威。残留 -1 按计划推荐案落到 P-A：新错误码 `EC_ICE_TY_INDET`（ICE04），使用新措辞和反例，并加入 `main.cr` 硬名单。

零行为变化：全语料的 rc 和日志、canary、`.ccr`、`--dump-objects`、`.cir`、自举链全部相同；冻结基线同源对拍 72 档零差异；探针全集在 pre 和 post 全同；3 条突变控制逐条失败，并精确回滚。

## 1. 清零判据复现（删除前置；本任务步骤 0 自跑）

命令为 `bash /tmp/p3t0_run.sh {check,shadow} /home/DslsDZC/core/build/corec /tmp/p5t4/parity_pre/{check,shadow}`。起点二进制是 T3b 的 `f0862d70…`，cwd 为仓库根，逐档 `clean-cache`。

| 面 | 结果 |
|---|---|
| `check` rc 分布 | 34×0、38×1，与 T0、T3、T3b 逐档相同 |
| shadow 汇总，70 档出摘要 | `decisions=agree=32988` |
| 差异和未知桶 | `old_stricter=0`、`old_looser=0`、`unknown=0`、`unknown_bridge=0`、`unknown_engine=0`、`unknown_engine_uncovered=0`、`unknown_engine_budget=0`、`replace_bridge=0`、`replace_unknown=0`，70 档逐档全为 0 |
| 站点覆盖 | `assign-node=24998`、`fn-body-ret=5905`、`if-branch=2051`、`struct-field-type=28`、`array-elem-type=4`、`generic-apply-base=2`、`assign-binary=0`、`generic-arg=0`、`hotpatch-ret=0`、`unify-fallback=0` |

判定：回落计数全为 0，删除前置成立；站点 6 的 `assign-binary` 零命中，语料佐证其不可达。原始记录在 `/tmp/p5t4/parity_pre_{check,shadow}.out`。

## 2. 步骤 1：残留 -1 政策（P-A，已写入文档；计划步骤 1 要求维护者签核）

清零之后，引擎仍可能返回 -1 的出口只剩两类。一是桥接缺口，`sh_term_of_ti` 无法译成项，包括行越界和桥接未覆盖。二是未覆盖面或预算耗尽，任务 0 表 D 清点为 μ 变元、`¬`、`⊤ₖ` 元素、NEVER 和 DYN 混类、空链、dyn 位图。

实施采用 P-A，即计划推荐案：

- 新错误码 `EC_ICE_TY_INDET = 16004`，即 ICE04，措辞为 `type judgment indeterminate`，原因分列两类：
  - 桥接缺口：`type judgment indeterminate: no type term for type row {t1} / {t2} (bridge gap)`
  - 引擎负值：`type judgment indeterminate: {term_a} vs {term_b} (uncovered face|budget exhausted)`
  - 反例是两侧类型项的文本，由 `tt_display` 直接输出；成因位在第二次 `ty_budget_reset` 之前读取。
- 加入 `main.cr` 硬名单，即 `if ec == EC_ICE_TY_INDET { hard = 1; }`。因此除了 `check` 返回 rc=1，`build` 也会拒绝写入磁盘，端到端证明由突变 M3 提供。
- 三态纪律：`type_equal_engine` 在 -1 时返回 `false`，这只是 bool 面的唯一保守出口，属于 fail-closed，不因未知而放宽。它不等价于“确定不等价”，后者不发诊断，诊断只在未知时发出。
- 位置面：判定点 `type_equal` 没有 AST 位置，因此 `line/col = 0`，`print_diagnostics` 打印 `--> 0:0`。定位由调用点自身的诊断承担，例如 TA01、TF01。
- report-only 依据：全语料 72 档零命中，即第 1 节的 `replace_*=0`，加上本任务实跑的 `check` 面零差异，因此零行为变化。
- 待签核，明示：政策选择按计划步骤 1 要求维护者签核。回退只需一行，删除 `main.cr` 硬名单条目，保留诊断但 `build` 不再拒绝。整条回到 P-B 也只是小改，去掉 `ty_indeterminate_report` 调用点。

## 3. 删除清单（逐件列出，删除依据是 D26 表的实施）

| # | 删除件 | 原位置和规模 | 删除依据 |
|---|---|---|---|
| 1 | `type_equal_legacy`，含 7 处递归自调 | `checker.cr:497-573`，注记 10 行加函数 67 行 | 清零判据：全语料 `replace_*=0`，引擎判定与它逐点同值，因此无人调用其结论 |
| 2 | 两处回落调用，桥接缺口和引擎 -1 | `checker.cr:590` 和 `:599` 区域 | 同上，两个计数全为 0，两个分支恒不进入 |
| 3 | `g_replace_unknown` 和 `g_replace_bridge` | `globals.cr` 声明、`checker.cr:246` 复位、`ty_shadow.cr` 摘要两个字段 | 计数已无对象，报告通道随之删除。这是任务 5 影子下线前的中间态，摘要不再有 `replace_*` 两个字段 |
| 4 | `sh_native_ak_legacy` 和 `sh_base_ak_legacy` | `ty_shadow.cr` 的两份对照物 | 零生产调用，只有自测 3 例引用。自测改为固定冻结期望表 `ts_t4_ak_expected` 和 `ts_t4_native_ak_expected`，生产文件不再有第二份实现 |
| 5 | 站点 6 分支，含 `sh_site_begin(6)` | `checker.cr:2459-2470`，12 行 | 三面不可达：`tok2op`（`parser.cr:170-184`）零 `OP_ASSIGN` 和 `T_EQ`；`EXPR_ASSIGN` 只在 `parser.cr:227` 出现；`+=` 族显式构造 `EXPR_ASSIGN` 包裹的 `EXPR_BINARY`，且 op 属于 {ADD,SUB,MUL,DIV}，见 `parser.cr:216-224`；全仓 `OP_ASSIGN` 只出现在定义、该分支和注释中，没有生产者；语料站点直方图中 `assign-binary=0`，共 32988 次判定 |
| 6 | `ir_gen` 对应的发射分支 | `ir_gen.cr:932-996`，65 行 | 同第 5 项，是同一 AST 组合的另一侧消费者。`IR_STORE_INDEX_VAR` 等操作码仍有活发射点，`ir_gen.cr:1184` 的 `EXPR_ASSIGN` 臂，因此没有操作码变成不可达 |
| 7 | `type_equal` 包装层的对照计算改为纯转发，并移除 `sh_compare` 调用点 | `checker.cr` 包装层 | 对照物已删除，无法对拍。D24 规定中间态不跑影子判据，`sh_compare` 函数体留到任务 5 |
| 8 | 自测 5 处计数固定项重钉，3 例副本对拍重钉，6 处注释和文档同步 | `type_selftest.cr`、`test_named_dedup.py`、`test_named_face.py`、`iface_registry.cr`、`type_engine.cr`、`ty_shadow.cr`、`docs/error-codes.md`、`src/ci/run.sh` | 见第 4 节判据，404/404 全部通过 |

新增，非删除面：`EC_ICE_TY_INDET`，在 `ast.cr` 和文档中；`ty_indeterminate_report`，在 `checker.cr`；硬名单一行，在 `main.cr`；自测 `ts_t4_run` 3 例；冻结期望表 2 个函数；`ts_diag_msg_at`。

## 4. 判据复验（全部本实例实跑）

| # | 判据 | 命令和结果 |
|---|---|---|
| 1 | 构建 | `nice -n 19 python3 build_selfhost_native.py` rc=0。构建日志中 `[GUARD] … error[ = 0` 出现 3 次，corec、corearch、corelsp 全部干净；`build/corec` 为 `eae13428…` |
| 2 | 后端引导 | CI 的 `bootstrap-tests` job rc=0，`tests/bootstrap/*` 三套；`check src/compiler` rc=0 |
| 3 | 自测 | `selftest-types` 404/404，即 401 加 `ts_t4_run` 3 例，0 FAIL |
| 4 | ELF canary | `clean-cache`，然后 `build tests/suite/ptr_arith.cr --static`，得到 `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`（28822B），IDENTICAL |
| 5 | 语料 `check` | 34×0、38×1 逐档相同；日志 diff 只在 2 档自源出现，即 `_import.cr` 和 `ccr_io.cr`，表现为均匀的 −38 行位移。诊断码、措辞、列和回显行内容逐字相同；−38 是自源净删行数在拼接序中的位置 |
| 6 | 冻结基线同源对拍（D26-①） | `/tmp/p5t0/base/corec`（pre-P5）配当前源，对比 `build/corec`（post-T4）配当前源，72 档的 rc 和日志逐字节零差异，`diff -rq` 零输出 |
| 7 | 探针全集复跑 | `/tmp/p5t3/probes`、`/tmp/p5t3b/probes`、`/tmp/p5t0/probes` 全档，pre-T4 和 post-T4 的 rc 全同、日志全同。残留 -1 面已由 T3、T3b 收口，因此没有 ICE04 命中 |
| 8 | 影子面，中间态 | `decisions=0 agree=0`，所有差异桶为 0，停摆，依据 D24。站点直方图仍计数，但不作判据：自源档有少量位移，因为源变更导致决策点数量变化，非自源档逐字节相同 |
| 9 | `.ccr`，两口径 × 两语料，冷态 | `ptr_arith` 90823B `fb4a3b59…` 和 90966B `592afa31…`；`generics_test` 135341B `ddec1ce6…` 和 135484B `cd2af565…`。四件与 T3b 后状态逐字节相同。归因是本任务零类型表和项表写入：删除面是永远不执行的代码和计数，`tt_display` 不调用 `str_intern` |
| 10 | `--dump-objects` | corearch 口径：非静态与 T3b 的 `do_try.txt` 做 `cmp`，IDENTICAL；静态与 T3b 的 `gt_do2.txt` 做 `cmp`，IDENTICAL |
| 11 | `.cir` DOT | `generics_test` 逐字节相同，165915B `b1bdf480…` |
| 12 | 五个 CI job | `check`、`bootstrap-tests`、`suite`、`selfhost-tests`、`full-bootstrap` 全部 rc=0 |
| 13 | 全枚举 | 57/57 rc=0，48 个 selfhost 加 9 个 bootstrap，路径编码日志名 |
| 14 | 自举链 | `cmp /tmp/corec2 /tmp/corec3` IDENTICAL，双 `36e8f3fd…`，2868158B；N06 为 0/0，命令为 `grep -c -F 'error[N06]' chain_corec{2,3}.log`；冒烟 42；`--help` rc=1 |
| 15 | 突变控制 | 第 6 节，3 条失败并精确回滚 |

## 5. 中间态口径（D24，逐条写入文档）

1. 影子判定对拍停摆：对照物 legacy 已删除，`type_equal` 包装层的 `sh_compare(t1,t2,ok)` 调用被移除。摘要为 `decisions=0/agree=0`，所有差异桶恒为 0。这不是新的判据信号，而是通道没有对照物后的机械结果。中间态不跑影子判据，依据计划 D24。
2. 站点直方图仍在，9 个活挂点；站点 6 退役为 0 槽，id 不重新编号。`sh_site_begin` 未动，随任务 5 下线。
3. 判定面回归网从本任务起改为冻结基线同源对拍，即第 4 节第 6 项；行为探针，即 `tests/selfhost/test_named_face.py` 和第 4 节第 7 项的探针集；突变控制；三态纪律 ICE04。
4. 任务 4 和任务 5 必须连续提交，中间态不发布。本报告和本提交就是中间态。

## 6. 突变控制（3 条加精确回滚）

驱动脚本为 `/tmp/p5t4/mut.py`（M1、M2）和 `/tmp/p5t4/mut_m3.sh`（M3）。回滚校验是源 sha256 前后对拍，加上二进制 sha 复原，即逐字节回到 `eae13428…`。

| 突变 | 内容 | 失败证据 |
|---|---|---|
| M1 | 去掉 P-A 报告面，删除 `ty_indeterminate_report` 两个调用点，未知时不报错地返回 false，即 P-B 形态 | 自测 3 FAIL：`t3.bridge_gap_ice04_hard_error`、`t4.ice04_bridge_gap_hard_error`、`t4.ice04_engine_uncovered_hard_error`，401/404 |
| M2 | 合并两类原因的措辞，桥接和引擎使用同一文案，归因不可读 | 自测 1 FAIL：`t4.ice04_engine_uncovered_hard_error`，措辞相异子句，403/404 |
| M3 | 门接线端到端：强制在 `(TI_STR, TI_INT)` 上触发，探针为 `x : ., mut = 5; x = "s";` | `check` rc=1，打印 `error[ICE04]: type judgment indeterminate: string vs int (uncovered face)` 和 `--> 0:0`，随后 TA01 带定位；`build --static` rc=1 且无产物，`artifact_exists=NO`，证明硬名单已接线 |

M1 的语义是：P-A 被改回不报错地 false 时自测失败，这是计划步骤 5 要求的突变面。M3 的语义是：新硬错误在 `main.cr` 的接线不是纸面承诺，否则 ICE04 只在自测里有效，`build` 仍会产出产物。

## 7. 实施偏离和登记（如实逐条）

1. 计划行号和现状变化：计划列出的 `checker.cr:504/:590/:599/:612/:2454-2463`、`ty_shadow.cr:101/:109/:628/:630`、`type_selftest.cr:1814/:1821/:2487/:2492/:2691`、`ir_gen.cr:927-929` 等定位点点已随 T2、T3、T3b 变化。实施以符号定位点为准，即函数名、分支名、Case 名，逐处实读定位。本报告第 3 节表格给出删除前镜像的实测行号。
2. `t3.unknown_fallback_legacy`、`unf.nominal_*` 等 5 处固定项的去向：按照“自测用例只增不减”的纪律，不删例，一律重钉为 T4 形态。断言从“回落计数恰加 1 或零增量”改为“引擎自决且零 ICE04 诊断”。Case 名同步改写，避免语义不符，例如 `t3n.replace_unknown_zero` 改为 `t3n.decided_no_indeterminate`，逐例见第 3 节第 8 项。
3. `ts_t4_run` 的引擎负值形态选择，实测后纠偏：初版用 `AK_NEVER × AK_DYN` 断言 -1，实测是已判面 0，因为 ⊥ 是 ⊤ 的子集，不反向，所以 `ty_equiv = 0`，首轮自测 1 FAIL 暴露了问题。改用命名原子，即身份链，乘 NEVER 原子，`te_named_pair` 的 NEVER 和 DYN 域外守卫返回 -1 并标 uncovered，与自测 `t3n.never_dyn_out_of_domain` 同面，随后通过。该纠偏本身是登记项：NEVER 乘 DYN 是“已判”而不是“未知”，此前没有用例显式固定过。
4. `selftest-types` 计数从 401 变为 404，`src/ci/run.sh:71` 的计数注释同步，只增不减；`test_type_engine.py` 的期望值来源同注释。
5. `docs/error-codes.md` 同步，新增 ICE04，统计表从约 145 变为约 146。计划任务 4 的 Files 未列该文件，但新码不登记会让文档立即过期，按“新增即登记”补充。
6. `_import.cr` 和 `ccr_io.cr` 日志的行号位移：−38 是自源在拼接序中的净删行数。`jj diff --stat` 逐文件净变化为 `checker.cr −60`、`ir_gen.cr −60`、`ty_shadow.cr −14`、`globals.cr −8`、`ast.cr +4`、`main.cr +6`、`type_engine.cr +1`、`iface_registry.cr +1`。同一次运行内全部诊断位移量一致，属于纯位移，没有判定语义差异，第 4 节第 6 项的冻结基线零差异是独立佐证。
7. 政策签核未取得，见第 2 节末尾。作为子代理无法取得维护者签核，因此按计划推荐案实施并在此明示，回退方式已经给出，只需一行。
8. 未测：`build` 路径下 ICE04 命中时的产物面，M3 已证明无产物；真实语料上 ICE04 多命中时的排序和去重行为，全语料 0 命中，没有对象，未测。

## 8. 证据路径

| 用途 | 路径 |
|---|---|
| 起点基线，check 和 shadow 汇总与逐档 | `/tmp/p5t4/parity_pre_{check,shadow}.out` 和 `/tmp/p5t4/parity_pre/{check,shadow}/` |
| post-T4 语料，check 和 shadow | `/tmp/p5t4/parity_post_{check,shadow}.out` 和 `/tmp/p5t4/parity_post/{check,shadow}/` |
| 冻结基线同源对拍 | `/tmp/p5t4/parity_frozen/check/`，对比 `parity_post/check/`，`diff -rq` 零输出 |
| 探针全集，pre 和 post | `/tmp/p5t4/probes_{pre,post}/`，含 `rc.txt` 和逐档日志，加 `/tmp/p5t4/run_probes.sh` |
| 构建和自测 | `/tmp/p5t4/build{1,2}.log`、`/tmp/p5t4/selftest{1,2}.log` |
| canary、`.ccr`、dump、cir | `/tmp/pa_p5t4`（28822B）、`/tmp/p5t4/{pa,pa_st,gt,gt_st}.ccr`、`gt_do.txt` 和 `gt_st_do.txt`，对照 `/tmp/p5t3b/{do_try.txt,gt_do2.txt}`、`gt.cir`，对照 `/tmp/p5t3b/gt.cir` |
| 五个 CI job、全枚举、自举链 | `/tmp/p5t4/ci_*.log`、`/tmp/p5t4/enum_*.log`、`/tmp/p5t4/chain_corec{2,3}.log`，另加 `/tmp/corec{2,3}` |
| 突变控制 | `/tmp/p5t4/mut.py`、`/tmp/p5t4/mut_m3.sh`、`/tmp/p5t4/mut_M{1,2,3}_*.log`、`/tmp/p5t4/checker.cr.pristine` |
| 删除前镜像，含实测行号 | `/tmp/p5t4/checker_pre.cr`、`/tmp/p5t4/ir_gen_pre.cr` |
| runner 和终局驱动 | `/tmp/p3t0_run.sh`、`/tmp/p5t4/final_runs.sh` |
