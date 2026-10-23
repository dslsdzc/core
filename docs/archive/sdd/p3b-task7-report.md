# R2 P3b 任务 7 收尾报告：全量回归、判据复验、统一台账、P3 总状态、P4 交接包

日期：2026-09-12。基线：`e838f18b`，P3b 任务 6 收尾，工作副本起点，selftest-types 为 333/333。

任务：计划任务 7b（`docs/superpowers/plans/2026-09-11-r2-p3-capabilities.md`）。P3b 包含任务 0（`9aa1786c`）、任务 2（`44100ba4`）、任务 6（`e838f18b`）三件，在各自任务验收之上做阶段收尾：全量回归、判据复验、台账统一、P3 总状态、P4 交接包（附录 C）。

报告口径：所有数字都是本轮实跑，使用 `nice -n 19`，cwd 为仓库根，一构建一编译串行，任何 `.ccr` 或缓存态比较前都先 `clean-cache`。继承基线的数字逐条标注，见第 1.1 节表格的“本轮/继承”列。证据脚本为 `/tmp/p3b7/regress.sh`，本轮新写；产物在 `/tmp/p3b7/*`，为日志。

## 0. 交付摘要

| 项 | 结果 |
|---|---|
| 全量回归 | 五个 CI job：4 个 rc=0，`check` 为 rc=1，属于既有失败划界；全枚举为 45 个 selfhost 加 7 个 bootstrap，逐档 rc=0 |
| 既有失败划界 | `check src/compiler` rc=1，恰好 2 条 TF01 误报（`lits_copy` 和 `ty_memo_slot_no_grow`）。check 按 F19 用非零返回反映任意诊断，不是本批引入，同源对拍两侧一致 |
| ELF canary | `clean-cache` 后为 `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`，IDENTICAL |
| 自举链 | `corec2/corec3` 的 `cmp` 为 IDENTICAL，双 2542222B，sha `03c9812fc735ec4b…`；N06=0；冒烟 42（corec 和 corec2 双通道）；`corec3 --help` rc=1 |
| `.ccr` 面 | `ptr_arith` 88943B `54e3856b…`，`generics_test` 130974B `97be2f9e…`，与任务 0、2、6 的记录值逐字节相同，P3b 三件零 `.ccr` 变更 |
| P3b 统一台账 | 收紧 10（T0 6、T2 0、T6 4），放宽 0，崩溃修复 1；全语料零命中，同源对拍零差异，11 条突变控制逐条对应 |
| P3 阶段总账 | 收紧 28，放宽 8，软诊断面增加 1（TM04），实例名忠实化 6，挂死和崩溃修复 3 端；五项目标能力全部接通；`selftest-types` 从 95 到 333；新套件 6 个 |
| P4 交接 | 计划附录 C，包含实现方式盘点、`.ccr` 加段四面、会翻转的固定项 7 条、待裁决 8 条；P4 没有独立计划，已实查 |
| 文档 | TODO #39 本批实施，另更新 #34 的 P3b 剩余面注、附录 B 存档注、附录 C、spec 第 9 节 P3 行的 P3a 和 P3b 双标记，以及状态表 Task 0b、2、6、7b 行 |
| 提交 | 路径限定为 3 个文件：TODO、计划、spec |

## 1. 全量回归（本轮实跑）

### 1.1 五个 CI job（`for j in …; do CI_JOB_NAME=$j bash src/ci/run.sh; done`）

| job | rc | 本轮要点 | 证据 |
|---|---|---|---|
| `selfhost-tests` | 0 | 21 个套件全部通过：`test_iface_ops` 76/76、`test_ccr_v7` 27/27、`test_impl_iface` 20/20、`test_iface_satisfies` 17/17、`test_generic_constr` 15/15、`test_match_exhaust` 16/16、`test_optional` 12/12、`test_xcut_iface` 12/12、`test_impl` 7/7、`test_borrow` 7/7、`test_params_limit` 5/5、`test_tuple_slots` 14/14、`test_agg_slots` 13/13、`test_agg_checks` 20/20、`test_nested_fn` 17/17、`test_interp_parity` 23/23、`test_cache_identity` 5/5、`test_compile` ALL、`test_type_engine` PASS（333 例通道）、`test_purity` PASS、`test_pointer_safety` PASS | `/tmp/p3b7/ci_selfhost-tests.log` 和逐档 `/tmp/p3b7/sh_*.log` |
| `bootstrap-tests` | 0 | 3 档：29/29、4/4、3/3，全部通过 | `/tmp/p3b7/ci_bootstrap-tests.log` |
| `suite` | 0 | `tests/suite` 的 21 档 `.cr` 编译和运行全部通过；`*_mini*` 和空 fixture 按 `run.sh` 既有规则跳过 | `/tmp/p3b7/ci_suite.log` |
| `full-bootstrap` | 0 | 三阶段，`corec2 == corec3` 的 `cmp` 为 IDENTICAL，双 2542222B；`--help` rc=1，符合既有约定 | `/tmp/p3b7/ci_full-bootstrap.log` |
| `check` | 1 | `check src/compiler` 属于既有失败划界，见第 1.3 节。恰好 2 条 TF01 误报，与 P3a 收尾和各任务报告是同一对 | `/tmp/p3b7/ci_check.log` |

继承和本轮的关系：五个 job 的 rc 形状与任务 0、2、6 的报告逐 job 相同，那时各自跑过一次。本轮是在已提交树 `e838f18b` 上的独立复跑。job 内的计数，即套件数和例数，也与各报告一致，`run.sh` 没有再改动。

### 1.2 全枚举（#31 缺口口径；全量 `tests/selfhost/*.py` 和 `tests/bootstrap/*.py`）

```
for f in tests/selfhost/*.py; do nice -n 19 python3 $f; done   # 45/45 rc=0
for f in tests/bootstrap/*.py; do nice -n 19 python3 $f; done  # 7/7  rc=0
```

- selfhost 45/45 rc=0，包含 CI 未挂的 24 档，也就是 #31 缺口的实际代价面。要点档：`test_compile` 通过，`test_purity` 通过，`test_ccr_v7` 27/27，`test_backend_bootstrap` rc=0，这是附录 B.6 必含档，stage0、stage1 的 `error[` 为 0，stage1、2、3 逐字节相同，smoke 和 O2 smoke 全部通过；`test_lsp` rc=0；`test_native_*`、`test_agg_*`、`test_tuple_slots`、`test_params_limit` 全部 rc=0。
- bootstrap 7/7 rc=0。CI 只挂了 3 档，未挂的 4 档 `test_apx_tag`、`test_dex_arith`、`test_dex_type`、`test_modules` 同样通过。
- 逐档 rc 明细在 `/tmp/p3b7/regress.out` 的第 3、4 节段，逐档日志在 `/tmp/p3b7/sh_*.log` 和 `bt_*.log`。

### 1.3 既有失败划界的复核（逐字）

- `check src/compiler` rc=1，诊断恰好 2 条。`grep -F 'error['` 在全日志命中 5 行，其中 2 条是诊断，3 条是 `[GUARD] … (error[ = 0 …)` 构建守卫行。
  - `error[TF01]: Function return type mismatch` 指向 `fn lits_copy(p: int) -> int`，check 路径行号 10162。
  - `error[TF01]: Function return type mismatch` 指向 `fn ty_memo_slot_no_grow(a: int, b: int) -> int`，check 路径行号 10385。
- rc=1 的机制，读码复核 `main.cr:435-441`：`check` 命令按 F19 语义“有任意诊断就返回 rc=1”。这对 TF01 是既有误报，P3a 收尾已登记 `lits_copy` 和 `ty_memo_slot_no_grow`，行号随源码增长变化。同源对拍两侧一致，不是本批新增。
- 同一对误报也出现在 corec2 的构建日志中，位置是 `build src/compiler/main.cr` 的类型检查阶段，行号 10177 和 10400。与 check 路径相差 15 行，是该路径的 `rt_src` 前置造成的，在 `main.cr:428` 区。`error[` 计数为 2，N06 为 0。判据口径是 N06，不是“零诊断”。

## 2. 判据复验（本轮实跑，逐条给出命令和结果）

| # | 判据 | 命令（cwd 为仓库根） | 结果 |
|---|---|---|---|
| 1 | 自举构建 | `nice -n 19 python3 build_selfhost_native.py` | rc=0；`build/corec` 的 sha 为 `9a583215af8397cc…`，`build/corearch` 的 sha 为 `599ee27553899b5d…`，与任务 6 报告复位基线逐字节相同，构建确定性成立 |
| 2 | 类型引擎自测 | `nice -n 19 ./build/corec selftest-types` | 333/333 |
| 3 | ELF canary | `clean-cache`，然后 `build tests/suite/ptr_arith.cr --static`，再 sha256 | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`，IDENTICAL |
| 4 | `.ccr` 面 | `clean-cache`，然后 `ccr`，再比较尺寸和 sha256 | `ptr_arith` 88943B `54e3856b383301be5daecaf61f75ce120e56ef4d1569c3008009fc368b750df9`；`generics_test` 130974B `97be2f9e7431fde54de99e29394903a431aeafa591159c900e0175dfa064c8b1`。与任务 0、2、6 的记录值逐字节相同，P3b 三件零 `.ccr` 变更 |
| 5 | 自举链 | `./build/corec build src/compiler/main.cr -o corec2 -O 0`，然后 `corec2 build … -o corec3`，再 `cmp` | `cmp` rc=0，双 2542222B，sha `03c9812fc735ec4b4582bf0cbea468e60ca5c87c27b0d5a0ac7bc857538a775b` |
| 6 | N06 | `grep -c -F 'error[N06]'`，检查两份构建日志 | 0 / 0 |
| 7 | 冒烟 | `./build/corec run 'fn main()->int{return 42;}'`，corec2 同样执行 | rc=42 / rc=42 |
| 8 | `--help` 约定 | `/tmp/p3b7_corec3 --help` | rc=1，符合既有约定 |

## 3. P3b 统一台账（聚合为收紧 10、放宽 0、崩溃修复 1）

### 3.1 收紧（旧接受，新拒绝或新诊断）

T0（`9aa1786c`；旧为 P3a 收尾 `aa54d26a` 构建，6 例逐例实测；全语料 72 档零命中）

| # | 用例（`test_iface_satisfies.py`） | 旧到新 | 处置 |
|---|---|---|---|
| T0-1 | `inst_missing_method_rejected` | check rc=0 零诊断，变为 rc=1 加 `error[TG02]` 和“does not satisfy interface 'Show'” | 结构或枚举实例化点 `T: I` 的方法缺失 |
| T0-2 | `inst_count_mismatch_rejected` | rc=0 零诊断，变为 rc=1 加 TG02 | 参数计数不符 |
| T0-3 | `inst_ret_code_mismatch_rejected` | rc=0 零诊断，变为 rc=1 加 TG02 | 返回码不符，措辞与函数调用点相同，是站点一致性证据 |
| T0-4 | `inst_enum_missing_method_rejected` | rc=0 零诊断，变为 rc=1 加 TG02 | 枚举实例化点 |
| T0-5 | `inst_multi_method_partial_rejected` | rc=0 零诊断，变为 rc=1 加 TG02 | 多方法接口半实现 |
| T0-6 | `inst_second_iface_missing_rejected` | rc=0 零诊断，变为 rc=1 加 TG02 | 两个接口隔离 |
| 重新固定 | `test_generic_constr.py::struct_iface_constr_unjudged` 改为 `..._violated`，另加正控 `..._present_accepted` | 同台账 | 同一边界原先“不判”的固定用例，P3a 已登记 |

T2（`44100ba4`）：收紧 0，放宽 0，属于换位批，行为保持。证据有三项：① 12 例行为探针（`test_xcut_iface.py`）在旧新两个二进制上逐例相同；② 全语料 72 档 check 日志 `diff -r` 为 0 行，rc 分布 33×0、39×1，两侧相同；③ 影子面旧新同值。台账条目为空。

T6（`e838f18b`；旧为任务 2 基线 `/tmp/p3b2_pre_mut_corec`，逐例实测；新套件 20 例，旧为 14/20，新为 20/20）

| # | 用例（`test_impl_iface.py`） | 旧到新 | 处置 |
|---|---|---|---|
| T6-1 | `neg_named_param_type_mismatch` | check rc=0 零诊断，变为 rc=1 加 TG02 | 参数类型进入判定，旧态裸码塌缩不可比 |
| T6-2 | `neg_named_ret_vs_native` | rc=0 零诊断，变为 rc=1 加 TG02 | 返回型按类型项判断，取代编码相等 |
| T6-3 | `neg_apply_arg_mismatch` | rc=0 零诊断，变为 rc=1 加 TG02 | 泛型应用实参，规范形展开后可比 |
| T6-4 | `neg_receiver_mode_mismatch` | rc=0 零诊断，变为 rc=1 加 TG02 | 接收者模式，旧态两侧都是码 0 |
| 重新固定 | `test_iface_satisfies.py::inst_encoding_limit_named_ret_pinned` 改为 `..._rejected` | 同台账 | 同返回型面的既有固定项，T0 已登记“解锁等于 T6 步骤 1” |

诊断门口径：TG02 是软诊断，check rc=1，build rc=0 且产物照常生成。它与既有约束检查同门同码。P3b 三件没有新增硬门，计划 Global Constraints 第 6 条的 report-only 前置没有被触发。

崩溃修复，台账之外，不属于收紧：T6 的 `pos_generic_body_call_inherent` 和 `_impl_for`。泛型体内的方法调用（`fn f[T: I]` 中的 `x.m()`）在旧态合成 `"T.m"` 字符串，并在克隆期做文本替换，导致实例体调用目标悬空。产物运行 rc=139，build rc=0。本批改为实例化查表解析，运行得到 rc=7 和 rc=9，是正确值。

### 3.2 语料扫面证据（逐任务；站点覆盖和差异数一同报告）

| 任务 | 同源对拍（旧二进制配新源，对比新二进制配新源） | 影子判定数（全计数 0） | 新能力面语料命中 |
|---|---|---|---|
| T0 | check、shadow、dump 三面 `diff -r` 为空 | 30271 / 30271，旧新归因同值 | 接口和 `T: I` 零命中 |
| T2 | check 面 `diff -r` 为空，rc 分布两侧相同；shadow 两轮同值 | 30400 / 30400，旧新同值 | 形状面零命中，属于行为保持批 |
| T6 | check 面 `diff -r` 为空；shadow dump 为空 | 30628 / 30628，旧新同值 | `interface`、`impl I for T`、`T: I` 的生产用法零命中 |

- 判定数逐任务增量为 30128、30271、30400、30628，全部是新增源码自身的站点。旧二进制跑同一新源得到完全相同的数字。“零差异不等于面收敛”的声明继承 P3a 附录 B.3。P3b 新能力的正确性由定向探针（T0 17 例、T2 12 例、T6 20 例）、用例表（增加 45 例：`isat.*` 16、`x2.*` 15、`ifc.*` 14）和 11 条突变控制承担。突变控制为 T0 4 条、T2 3 条、T6 4 条，逐条对应，复位后二进制逐字节复原。
- 继承声明：影子通道只覆盖 `type_equal` 站点。P3b 的判定面，包括 `ty_sub`、`iface_satisfies*`、签名 `tt_list_same`，不在其站点集内。因此影子零差异是必要条件，不是充分证据。

## 4. P3 阶段总状态和未开工清单

交付面：五项目标能力全部接通。定长退役（T1）、序列接口和长度约束（T2）、穷尽性、联合和可选（T3、T4）、泛型约束（T5 加 T0b 的 `T: I` 半边）、impl 契约（T6）。`selftest-types` 从 95 到 333；新套件 6 个：match_exhaust 16、optional 12、generic_constr 15、iface_satisfies 17、xcut_iface 12、impl_iface 20，全部挂在 `run.sh`。

收紧和放宽总账：P3a 收紧 18，放宽 8，诊断面新增 1（TM04 软面），实例名忠实化 6，挂死修复 2 端。P3b 收紧 10，放宽 0，崩溃修复 1。合计收紧 28，放宽 8，软诊断面增加 1，挂死和崩溃修复 3 端。全语料零命中，自举源码零改造。

判据面在全阶段稳定：ELF canary `95084e7b…d475` 全程 IDENTICAL。`.ccr` 变更面只有 T4 的 `ptr_arith` STR 减少 10B 和 T5 的 `generics_test` 增加 370B 反折叠，P3b 三件零变更。自举链全程保持 `cmp` IDENTICAL、N06=0、冒烟 42。

未开工和未实现（P3 终态清单）：

1. iterable 面接线：`EXPR_FOR` 现状零类型检查（`checker.cr:2810-2821`，`infer_expr(iter)` 的返回值被丢弃，循环变量恒为 `TI_INT`，T2 登记项④）。接线等于新增判定，可能新增硬门，必须走 report-only 专批。
2. 形状命名消费语法（`T: 可索引`）和 `.ccr` STR 段增长裁决，属于 A.3-② 后续，同一个裁决涉及两面。
3. 整形状 `ty_sub` 路由。T6 实测不可用：引擎的 `AK_NAMED` 不展开，命名行恒为 -1；product 比较是结构相等，不是子集包含。因此形状项作为签名实现方式，由逐成员判定消费。
4. 上限族保留：`MAX_GENERICS=4`、`MAX_IFACE_METHODS=16` 和 `MAX_IFACE_METHOD_PARAMS=8`，硬错护栏已建立；`MAX_ENUM_VARIANTS` 和 `MAX_VARIANT_TYPES=16`，#35 的写入侧护栏未修。原则是先加护栏，再评估解除。
5. TODO #38 名义与结构的区别，属于用户轴口径，由维护者裁决。
6. 运行期可选表示统一。B.7 中 `Some` 臂双路径 SIGSEGV，rc=139，check 和 build 为 rc=0 零诊断；P3b 未动。
7. TODO #32，`EXPR_LET` 没有任何兼容检查。
8. TODO #35，前端枚举表写入侧没有护栏。
9. 其余未覆盖面，登记如下：可写视图形状不可表达；索引侧“须为 int”的位缺失；dyn 和字段面未接线；符号档长度约束属于 VC 义务，不实现；`Box[S]` 命名实参为 -1，不判；接口泛型形参丢弃；变参签名不可表达；`save_func_gen_constrs` 稀疏零初值，未触发；bootstrap 的 `&&` 和 `||` 不短路根因；空递归保守返回 -1；非枚举域不判穷尽；空枚举域属于空洞穷尽；`never` 语义见 B.4-2；性能面的 `(ak → entry)` 快表实测无必要。

## 5. P4 交接包（写入计划附录 C；P4 没有独立计划，已实查）

新写 `docs/superpowers/plans/2026-09-11-r2-p3-capabilities.md` 的附录 C，标题为“R2 P4 交接包——实现方式（`.ccr` TYPE/IFACE 段加 DFNode.TK 升格加 corearch 读回）”，包含六节。

- C.1 P4 四件与现状实测：TYPE 段不存在，类型只以 u32 索引出现在 SYM、NOD、EDG；IFACE 段零序列化，`ccr_io.cr` 全文件中 `iface`、`impl_for`、`g_methods` 的命中为 0；DFNode.TK 是粗类型码槽，`ir_gen.cr:190-206` 把同值直写 IR instr 和 DF 节点，`.ccr` 的 NOD 段用 `tk` 镜像；corearch 读回有 `g_v7_nod_sem` 语义对象范式可以照搬。
- C.2 今日实现方式盘点，按内存态、布局、可重建性、P4 动作列出：类型项 DAG（`g_type_terms` 48B 加 `g_tt_index`）、本质条目表（13 条 × 40B 常量）、形状表（零注册）、`g_ifaces`（每条 2712B，方法条目 168B，包含参数节点×8、返回节点、接收者模式）、`g_impl_for` 16B、`g_methods` 24B、签名规范项（派生态，可重建）、桥接和影子缓存（P5 下线）。
- C.3 加段机制：段表为 {tag,offset,size}，tag 1 到 6，7 以上预留，见 format spec 第 2 节。加段要四面同改：`CCR_SEG_COUNT` 和 calc 尺寸、save 写侧、load 读侧检查与 `have{1..6}` 标量族、`test_ccr_v7` 结构断言。版本升级另行裁决。纠正 spec 第 6.1 节的失效文件名引用：`2026-09-07-lattice-ir-v7-format.md` 不存在，实际是 `2026-09-09-lattice-ir-v7-format.md`。
- C.4 会翻转的固定项 7 条：零 `str_intern` 三守门（`x2.no_str_intern`、`ifc.mangling_zero_str_intern`、`isat.no_str_intern_on_missing`）；`.ccr` 逐字节同记录值，改为结构断言，ELF canary 不得变；形状注册面两例；签名编码面；`iface_count()==13` 硬值（`type_selftest.cr:2362`）；影子站点面（P5）；清单双注册面和 `test_backend_bootstrap`。
- C.5 开工必守 6 条：结构性判据（TODO #26）；清单双注册（B.6）；三态纪律，载入失败必须拒绝；新硬错误先 report-only；一构建一编译串行，加 `nice`，加 `clean-cache`；发射面零泄漏先证明。
- C.6 待裁决 8 条：形状命名语法和 STR 段增长；#38 名义与结构；13 条表扩列还是引擎侧另表，包含 `AK_NULL`；整形状 `ty_sub` 路由；B.7 可选表示，spec 明确要求与 TYPE 段同批；MAX_* 的统一处置；`never` 和符号档；TK 升格的发射面判据。

## 6. 文档面（本批改动）

| 文件 | 变更 |
|---|---|
| `docs/superpowers/plans/2026-09-11-r2-p3-capabilities.md` | 新增任务 7b，包含六步勾选、P3b 统一台账 10 条、语料证据表、P3 阶段总状态、未开工清单；新增附录 C 的 P4 交接包；实施状态总表增加 Task 0b 行，Task 2 和 6 行填入实际提交 sha，增加 Task 7b 行，更新表头注；附录 B 头部加“P3b 已交付”存档注 |
| `docs/superpowers/specs/2026-09-10-type-interface-unification-design.md` | 第 9 节 P3 行从“（b）P3b 未开工”改为“P3b 已实施”，包含三提交链、判据和 P3 未开工面；未覆盖面登记两条状态更新：MAX_IFACE 护栏已建立，B.7 转为 P4 必修 |
| `TODO.md` | 新增 #39，记录 P3b 收尾：交付链、回归、判据、统一台账、P3 总账、P4 交接、未开工、关联；#34 的“P3b 剩余面（未开工）”列表项更新为已全部交付，指向 #36、#37、#38 和 #39 |
| `docs/archive/sdd/p3b-task7-report.md` | 本报告，属于未跟踪面，不入提交，同前例 |

指针准确性复核：#38（名义与结构裁决加未覆盖面）、#32（`EXPR_LET` 无检查加建议修法）、#35（枚举写侧护栏加两面实测）三条逐字复核，无需改动。本批未触碰其事实面，#39 和附录 C 是它们的交叉引用。

## 7. 提交（路径限定）

- 提交 `55280aa5`，提交信息 `docs: R2 P3b 收官（Task 7b）——全量回归 + 判据复验 + 统一台账 + P3 总状态 + P4 交接包（附录 C）`。base 为 `e838f18b`，3 个文件为 `TODO.md`、计划、spec。`jj diff -r 55280aa5 --summary` 恰好列出 3 个文件，工作副本提交后干净。
- 本报告和 `/tmp/p3b7/*` 属于未跟踪面或机外产物。

## 8. 证据命令速查（可复核）

```bash
# 全量回归（本轮脚本）
bash /tmp/p3b7/regress.sh                      # 全链：构建 → 五 CI job → selftest → 45+7 枚举 → canary → .ccr → 自举链 → check 面
# 逐条
nice -n 19 ./build/corec selftest-types | tail -1                       # 333/333
for j in selfhost-tests bootstrap-tests suite full-bootstrap check; do nice -n 19 env CI_JOB_NAME=$j bash src/ci/run.sh; echo "$j rc=$?"; done
nice -n 19 ./build/corec clean-cache && nice -n 19 ./build/corec build tests/suite/ptr_arith.cr -o /tmp/x --static && sha256sum /tmp/x
nice -n 19 ./build/corec build src/compiler/main.cr -o /tmp/corec2 --static -O 0 && nice -n 19 /tmp/corec2 build src/compiler/main.cr -o /tmp/corec3 --static -O 0 && cmp /tmp/corec2 /tmp/corec3
grep -c -F 'error[N06]' /tmp/p3b7/corec2.log                            # 0
nice -n 19 ./build/corec run 'fn main()->int{return 42;}'; echo $?     # 42
```
