# R2 P3 Task 7 报告：P3a 收尾（全量回归、终态判据、收紧台账、P3b 交接包、文档）

状态：DONE_WITH_CONCERNS。全部判据在终态通过，另有 4 项登记。① 全量枚举发现并修复了一处 P3a 期间不可见的回归：Task 5 漏改 project-mode 清单，导致 project-mode corearch 构建出现 33 次 `error[N06]` 不报错地未定义，`test_backend_bootstrap.py` rc=1；修复后全量枚举 49/49 rc=0，详见 §6 和计划附录 B.6。② P3b 三件全部未开工：Task 2 横切接口、Task 6 impl 契约、Task 5 的 `T: I` 半边；唯一阻塞是 `iface_satisfies` 未交付。交接包落在计划附录 B。③ `check` job rc=1 是既有 red 划界：2 条 TF01 误报，行号随源码增长变化，两侧编译器输出一致。④ 影子判定数终态为 30,128，等于 T5 的 30,338 减 210，精确归因见 §3.3，不是新语义变化。

提交：`3b2a43d26bbf39c0cdb96558797e195742756ce4`。路径限定 5 个文件：`TODO.md`、计划、spec 类型接口统一设计 §9、findings §13、`src/targets/x86_64-linux/_import.cr`。216 insertions / 5 deletions。

计划：`docs/superpowers/plans/2026-09-11-r2-p3-capabilities.md` 的 Task 7，P3a 收尾。

起点：`9c0a83ec`，即 P3 Task 5 末提交，工作副本干净。起点二进制为 T5 冻结值：`corec ae9215df…`、`corearch 9230da6c…`、`corelsp 748250bb…`。本批全部构建后逐字节不变，见 §1.1。

范围：P3a（Task 0/1/3/4/5）收尾，P3b 全部未开工。本报告不重新推导各任务判据，逐条聚合自五份任务报告（`docs/archive/sdd/p3-task{0,1,3,4,5}-report.md`），只在“收尾复跑/终态”处给出本轮实测。

---

## 0. 收尾摘要

| 面 | 结果 |
|---|---|
| CI 五个 job | selfhost-tests rc=0（0 FAIL）、bootstrap-tests rc=0、suite rc=0（ALL PASS）、check rc=1（既有 red：2 条 TF01）、full-bootstrap rc=0 |
| 全量套件枚举 | 42 个 selfhost 加 7 个 bootstrap，逐档 rc；首次 48/49，1 个 red 即 §6 回归，修复后 49/49 rc=0 |
| 自举链 | `corec2 == corec3`，`cmp` IDENTICAL（2,404,414 B）；N06 = 0（全部 job 日志）；冒烟 `run 'fn main()->int{return 42;}'` = 42（corec 与 corec2 双通道）；`corec3 --help` rc=1，既有约定 |
| ELF canary | `tests/suite/ptr_arith.cr`（clean-cache）sha256 = `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`，IDENTICAL，修复前后各一次 |
| `.ccr` | `ptr_arith` = `54e3856b…0df9`（88,943 B，等于 T4/T5 记录值）；`generics_test` = 130,974 B（等于 T5 值；`get_val[int]` 和 `get_val[string]` 反折叠） |
| 影子终态 | `decisions=30128 agree=30128`，全部计数为 0，`agree==decisions` 成立，`sum(sites)==decisions` 成立；check/shadow/dump 三面对拍 `diff -r` 为空 |
| 收紧/放宽台账 | 收紧 18，诊断面新增 1（TM04 软），放宽 8，实例名忠实化 6，挂死修复 2 端；全语料零命中 |
| P3b 交接包 | 计划附录 B：B.1 阻塞/接线点、B.2 台账、B.3 语料证据、B.4 登记面 19 条、B.5 P5 继承、B.6 回归修复 |

---

## 1. 全量回归（判据 1）

### 1.1 CI 五个 job（`nice -n 19 env CI_JOB_NAME=<job> bash src/ci/run.sh`，cwd 为仓库根）

| job | rc | 要点 | 日志 |
|---|---|---|---|
| `selfhost-tests` | 0 | 18 档全部通过，`FAIL` 行 0；包含新挂的三档：match_exhaust 16/16、optional 12/12、generic_constr 14/14。重建后三个二进制 sha 与起点逐字节相同 | `/tmp/p3t7/selfhost-tests.log` |
| `bootstrap-tests` | 0 | 3 档：pipeline 29/29、borrow 4/4、generics 3/3 | `/tmp/p3t7/bootstrap-tests.log` |
| `suite` | 0 | 21 档 build+run 全部通过（32 个 `.cr` 减 9 个 `*_mini*` 减 2 个空文件） | `/tmp/p3t7/suite.log` |
| `check` | 1 | `check src/compiler` 为既有 red，2 条 TF01 误报，见 §1.3 | `/tmp/p3t7/check.log` |
| `full-bootstrap` | 0 | corec 到 corec2 到 corec3 链，加 `cmp` 和 `--help` | `/tmp/p3t7/full-bootstrap.log` |

构建确定性：五个 job 各自带 `build_selfhost` 重建，`build/corec|corearch|corelsp` 的 sha 在全部 job 前后逐字节不变（`ae9215df…` / `9230da6c…` / `748250bb…`，等于 T5 冻结值）。

### 1.2 全量套件枚举（42 个 selfhost 加 7 个 bootstrap；逐档 `nice -n 19 python3 <file>`，rc 为进程 rc，末列为日志末行）

口径：CI 只挂 18/42 加 3/7（TODO #31），因此收尾另跑全量，与 P2b 收尾同口径。首次枚举 48/49，唯一 red 是 `test_backend_bootstrap.py`，见 §6 回归。修复后提交完成，在提交后的树上整套重跑，`rc!=0 count: 0 / 49`，终态 49/49 rc=0（`/tmp/p3t7/suites_final.tsv` 加 `/tmp/p3t7/final/*.log`）。

| 套件 | rc | 计数/末行 | 套件 | rc | 计数/末行 |
|---|---|---|---|---|---|
| selfhost/test_agg_checks | 0 | 20/20 | selfhost/test_native_float | 0 | ALL PASS |
| selfhost/test_agg_slots | 0 | 13/13 | selfhost/test_native_memory | 0 | 6/6 |
| selfhost/test_apx_tag | 0 | 2/2 | selfhost/test_native_strings | 0 | PASS |
| selfhost/test_backend_bootstrap | 0（修复后） | stage1/2/3 逐字节同，smoke/O2 全部通过（首轮 rc=1，见 §6） | selfhost/test_nested_fn | 0 | 17/17 |
| selfhost/test_borrow | 0 | 7/7 | selfhost/test_optional | 0 | 12/12 |
| selfhost/test_cache_identity | 0 | 5/5 | selfhost/test_params_limit | 0 | 5/5 |
| selfhost/test_ccr_v7 | 0 | 27/27 | selfhost/test_pointer_safety | 0 | PASS |
| selfhost/test_compile | 0 | All selfhost compile tests passed | selfhost/test_purity | 0 | PASS |
| selfhost/test_dex_arith | 0 | 11/11 | selfhost/test_region_cfg | 0 | 22/22 |
| selfhost/test_dex_type | 0 | 5/5 | selfhost/test_slice_bounds | 0 | 7/7 |
| selfhost/test_directory_build | 0 | PASS（末例） | selfhost/test_tuple_slots | 0 | 14/14 |
| selfhost/test_ent_kernel_neutrality | 0 | PASS | selfhost/test_type_engine | 0 | PASS（selftest-types 288/288） |
| selfhost/test_generic_constr | 0 | 14/14 | bootstrap/test_apx_tag | 0 | 5/5 |
| selfhost/test_global_init | 0 | 15/15 | bootstrap/test_borrow | 0 | 4/4 |
| selfhost/test_hit_table | 0 | 24/24 | bootstrap/test_dex_arith | 0 | 14/14 |
| selfhost/test_iface_ops | 0 | 76/76 | bootstrap/test_dex_type | 0 | 3/3 |
| selfhost/test_impl | 0 | 7/7 | bootstrap/test_generics | 0 | 3/3 |
| selfhost/test_interp_float | 0 | ALL PASS | bootstrap/test_modules | 0 | PASS（末例） |
| selfhost/test_interp_parity | 0 | 23/23 | bootstrap/test_pipeline | 0 | 29/29 |
| selfhost/test_lexer_parity | 0 | PASS | — | — | — |
| selfhost/test_live_ranges | 0 | 13/13 | — | — | — |
| selfhost/test_lsp | 0 | ALL PASS (10 tests) | — | — | — |
| selfhost/test_match_exhaust | 0 | 16/16 | — | — | — |
| selfhost/test_mw_task1..6 | 0 | ALL PASS，6 档 | — | — | — |
| selfhost/test_named_dedup | 0 | PASS | — | — | — |

完整逐档表和原始日志在 `/tmp/p3t7/suites.tsv` 和 `/tmp/p3t7/suites/*.log`。

### 1.3 既有 red 复认（`check` job rc=1）

`check src/compiler` 输出恰好 2 条 TF01：`fn lits_copy` @10069:1、`fn ty_memo_slot_no_grow` @10292:1。它们是 `ty_shadow.cr` 记载的 loop 落空既有误报，TODO #8 已划界。行号从 P2b 的 9383/9498 变化到 10069/10292，原因是源码行数增长，T3/T4/T5 报告同口径。同源双编译器对拍（`/tmp/p3t5_base_bin/corec` 加当前源，见 §3）逐条消息包括行号全部相等，因此不是本批引入。Task 5 关切⑤确认：`check` CI job 因为这两条长期 rc=1，软诊断让 check 路径 rc=1，与 P3a 无关。P3a 期间没有新增，T3/T4/T5 各自 grep 零新增，本次收尾复核相同。

---

## 2. 自举链和零变化面（判据 2/3）

| 序号 | 判据 | 命令 | 结果 |
|---|---|---|---|
| 1 | 自举链 | `CI_JOB_NAME=full-bootstrap bash src/ci/run.sh` | rc=0；`cmp /tmp/corec2 /tmp/corec3` rc=0，IDENTICAL（2,404,414 B，两个文件 ls 同尺寸） |
| 2 | N06 | `grep -c 'error\[N06\]' full-bootstrap.log` | 0；全部 job 日志的 `error[` 只有 4 行，是两段链各自的 2 条既有 TF01；三个守卫都输出 `[GUARD] … build log clean (error[ = 0, undefined = 0)` |
| 3 | 冒烟 | `./build/corec run 'fn main()->int{return 42;}'` / `/tmp/corec2 run '…'` | 42 / 42，双通道；`corec3 --help` rc=1，既有约定 |
| 4 | ELF canary | `clean-cache`，然后 `build tests/suite/ptr_arith.cr --static -o …`，再 sha256 | `95084e7b…d475`，IDENTICAL。修复前后各一次，同值 |
| 5 | `.ccr`（ptr_arith） | `clean-cache`，然后 `ccr tests/suite/ptr_arith.cr` | `54e3856b383301be5daecaf61f75ce120e56ef4d1569c3008009fc368b750df9`（88,943 B，等于 T4/T5 记录值） |
| 6 | `.ccr`（generics_test） | 同上 | 130,974 B，等于 T5 值。`strings` 面中 `get_val[int]` 和 `get_val[string]` 存在，`get_val[unit]` 不存在，说明反折叠 |
| 7 | 三个二进制 | `sha256sum build/corec build/corearch build/corelsp` | 全程 `ae9215df…` / `9230da6c…` / `748250bb…`，等于 T5 冻结值。本批唯一的源改动不进入任何 concat 清单，见 §6 |

`.ccr` 变更面逐任务列，判据 2 要求逐任务；出处是各任务报告 §5，T0/T1/T3 为不变项。T0 不变；T1 不变，类型表行序未动；T3 不变；T4 变，内建 Option 串退役，STR 段恰好减少 10B，后续 STR 索引整体减 1，段尺寸其余全同；T5 变，`generics_test` 增加 370B，恰好是一个额外实例的反折叠，`ptr_arith`/`dyn_test`/`at_test_struct` 不变。判据按 TODO #26 口径：`test_ccr_v7` 27/27 结构性断言、语义零变化、自举稳定。没有用“与旧版逐字节同”替代。

---

## 3. 终态复跑（判据 4：影子加语料；站点覆盖与差异数同报）

### 3.1 终态影子对拍（本轮实测；运行器复用 `/tmp/p3t0_run.sh`，72 档逐档 `clean-cache`）

- 旧二进制加新源，对比新二进制加新源。旧二进制为 `/tmp/p3t0_base_bin/corec`，即 P2b 末/Task 0 起点树的 `8f69e346…`。
  - check 面日志 `diff -r` 为空，rc=0；rc 分布为 33 个 rc=0、39 个 rc=1，两个二进制相同，等于 T0 报告口径。
  - shadow 日志 `diff -r` 为空；shadow dump `diff -r` 为空。
  - 聚合（两个二进制逐值相同）：`decisions=30128 agree=30128`，`old_stricter=0 old_looser=0 unknown=0 unknown_bridge=0 unknown_engine=0 unknown_engine_uncovered=0 unknown_engine_budget=0 replace_bridge=0 replace_unknown=0`；`agree==decisions` 成立，`sum(sites)==decisions` 成立；无摘要的语料文件 2 个，是 0 字节空 fixture，同 §2 排除项。
- 站点覆盖直方图：`assign-node=22785 · fn-body-ret=5338 · if-branch=1971 · struct-field-type=28 · array-elem-type=4 · generic-apply-base=2`。站点 1（hotpatch-ret）、2（generic-arg）、4（unify-fallback）、6（assign-binary）在语料中零命中，站点 3 仅 2 次，同 P1/P2a/P2b/T0 到 T5 口径。

### 3.2 五个任务对拍汇总（不重新推导；出处为各任务报告 §3/§4）

| 任务 | 对拍结果 | 判定数 |
|---|---|---|
| T0 | 三面 `diff -r` 空 | 29,090 |
| T1 | 三面空 | 29,267 |
| T3 | check 面只有 2 处行号位移，既有 TF01 随新增行变化；shadow/dump 空 | 29,442 |
| T4 | check 面诊断码集合和 rc 相同，3 档自源行号位移；dump 同 T3 | 29,687 |
| T5 | 0 档差异，rc、码、逐条消息含行号全部相等；dump 同 T4 | 30,338 |
| 收尾（本轮） | 三面空（§3.1） | 30,128 |

效力范围声明，继承口径：全部新能力面，包括展开层、方向、变型、mut、穷尽性、`T?`、`Some`/`None`、泛型约束，在 72 档语料中零命中。因此上表“零差异”不是新能力正确性的证据。正确性由行为探针（T1 19、T3 22、T4 14、T5 16 例）、用例表 288、新套件（16+12+14 例）和突变控制承担，见各任务报告 §3/§5/§6。

### 3.3 判定数 30,338 到 30,128（减 210）的精确归因（本轮新增实测）

唯一来源是 §6 的回归修复：删除 target project 的 `import monomorph`，使 monomorph.cr 退出 `src/targets/x86_64-linux/{main,_import}.cr` 两档的导入闭包。逐档切换实测，使用 `--type-shadow` 单档，切换 import 前后各一次：

| 语料档 | 含 `import monomorph`（修复前） | 删除后（终态） | 差值 |
|---|---|---|---|
| `src/targets/x86_64-linux/main.cr` | 3577（加 33 次 N06） | 3472（N06=0） | −105 |
| `src/targets/x86_64-linux/_import.cr` | 3542 | 3437 | −105 |
| 合计 | — | — | −210，等于总差 |

因此“30,338 到 30,128”不是语义变化，同源对拍三面为空可以作证。这是一个不再被编译的后端死码文件退出语料闭包造成的计数效应。

---

## 4. 收紧/放宽台账（判据 5：P3a 统一汇总）

汇总：收紧 18，诊断面新增 1（TM04 软），放宽 8，实例名忠实化 6，挂死修复 2 端；全语料零命中，72 档乘五个任务同源对拍。逐条表在计划附录 B.2，本报告不重复大表，只给口径和计数：

- 收紧 18：T0 为 0，纯新增 502/0，三面零差异；T1 为 6，包括 pA 切片到固定长、pF 字段位、pIf1 结果位、pN3 嵌套、pE1/pE2 mut 双向；T3 为 6，TM03 缺臂 6 条，其中 1 条是“运行值即缺失变体”的不报错地 0 实例，另有软 1 条 TM04；T4 为 3，Option 名退役 N09 软、`Option[T]` 与 `int?` 混用挂死改为 TF01、`Result` 名字解包退役改为 TF01；T5 为 3，`Box[string]`/`EBox[string]` 增加 TG02，`f[T:int]←s` 码集合扩张，末条 rc 不变。
- 放宽 8：T4 为 7，包括 `T ⊆ T?`、`null ⊆ T?`、`Some` 可解析、赋值位注入、调用位可解析（自注：非语义放宽）、可选域穷尽、挂死修复；T5 为 1，F4 假拒 TF01 改为 rc=0。
- 实例名忠实化 6，T5，rc 全同：`f[unit]` 改为 `f[A]` 加 `f[B]`（反折叠，计划 Step 4 要求实证的折叠缺陷）、`id[unit]` 改为 `id[S]`、嵌套重映射、`take[string]` 按声明序、`f[S]`、S6 元组实参为未覆盖面（同值）。
- 挂死修复 2 端，T4：`Some(x)` 实参链契约，30 秒超时改为明确拒绝，挂死改为 rc=0。
- 语料证据：§3.2 表加各任务报告 §4；自举源码零改造，延续 R1 裁决，`[T;N]` 10 处零改造复验。

---

## 5. P3b 交接包（判据 6；落点选择为计划新增附录 B）

选择与理由：交接包的读者是 P3b 实施者，其入口文档是本计划，即 Task 2/6 的任务文加附录 A 的 P2b 交接惯例。因此落在 `docs/superpowers/plans/2026-09-11-r2-p3-capabilities.md` 的附录 B，作为附录 A 的姊妹篇，同位置惯例；附录 A 是“P2b 到 P3”，附录 B 是“P3a 到 P3b”。内容共六节：

- B.1 阻塞项和接线点：唯一阻塞是 `iface_satisfies` 未交付（附录 A.3-① 状态未变）。三件的 P3a 侧已就位接线点：`gen_constr_satisfied` 首分支、`sh_iface_shape_term` 占位、`ty_variance_of` 引擎侧变型表。另有开工顺序建议、继承硬口径（report-only、`.ccr` STR 段约束、三态纪律）和新裁决面（`AK_NULL` 与 `iface.count == 13`）。
- B.2 收紧/放宽统一台账：§4 的逐条表，18 加 1 加 8 加 6 加 2，包含出处和处置。
- B.3 语料全扫证据：逐任务表、站点覆盖、效力范围声明、减 210 归因。
- B.4 逐条登记面 19 条，每条为出处、现状、影响、建议：函数侧 `save_func_gen_constrs` 稀疏零初值同族风险、`never` 非 ⊥、命名实参与非原生约束 -1 不判、MAX_GENERICS=4、`EXPR_LET` 无检查（等于 TODO #32）、运行期可选表示未统一、MAX_ENUM_VARIANTS/MAX_VARIANT_TYPES 越界写（加 MAX_* 族处置总口径）、不可判面清点、空枚举域等于空洞穷尽、空递归保守、符号档长度约束（VC 义务）、bootstrap `&&`/`||` 短路根因、`EXPR_ENUMPAT` 槽等于 `ast_a`、witness 空析取支、链元素不变量缺位、只读序列第二层协变、复合实参实例键后备加死码 `find_or_create_mono_func`、monomorph 清单迁移、性能面。
- B.5 交 P5 继承项：`type_equal_legacy`、`sh_*_ak_legacy`、站点 6、影子层下线，以及状态更新：T0 展开层按设计不满足“unknown 清零前提等于引擎命名展开”，因此 P5 须对“等价面是否展开”做裁决。
- B.6 收尾回归修复，见 §6。

---

## 6. 收尾发现并修复的回归（本轮唯一源改动；详版在计划附录 B.6）

现象：全量枚举首轮，`tests/selfhost/test_backend_bootstrap.py` rc=1，报 `[FAIL] stage0 builds corearch stage1: exit 0 but build log carries 33 error[ diagnostic line(s)`。全部是 `error[N06]: Undefined function`，涉及 `get_type_kind`/`get_type_data`/`get_type_extra`/`alloc_node`/`alloc_type`。

根因，实测归因：Task 5 把 `monomorph.cr` 从 corearch 的 concat 面清单（`build_selfhost_native.py:backend_support_files`）迁出，漏改 project-mode 面。`src/targets/x86_64-linux/_import.cr:16` 的 `import monomorph` 仍然存在。T5 给 monomorph.cr 的类型项化引入了 checker/parser 层符号，实测该文件对 `get_type_kind|get_type_data|get_type_extra|alloc_node|alloc_type` 的引用数从 P3a 起点的 0 变为终态的 46。project-mode corearch 的单元集不包含该层，于是出现 33 次 N06 不报错地未定义，rc=0 且产物照出，stage 链互测看不见。这正是 `test_backend_bootstrap.py` 的 `error[` 门要拦截的类别。

为什么 P3a 期间不可见：唯一守卫是该套件的 project-mode `error[` 门，而它未挂 CI，TODO #31 记录 selfhost-tests 只挂 18/42。因此五个任务的回归面都没有跑到，收尾全量枚举首次暴露。同类面：`build_selfhost_native.py` 与 `src/targets/x86_64-linux/_import.cr` 是双注册关系，后者文件头自述，任何清单增减必须两面同改。

修复：删除 `src/targets/x86_64-linux/_import.cr` 的 `import monomorph`。证据与 T5 的 concat 面迁出相同：monomorph 在 corearch 链接集零代码引用，全部定义符只出现在 globals.cr 注释；文件头落注记。

复验，全部通过：① 该套件 rc=0，stage1/2/3 逐字节同，smoke/O2 全部通过；② project-mode 构建日志 `error[` 从 33 变为 0；③ ELF canary `95084e7b…d475` 不变；④ 三个二进制 sha 不变，该文件不进入任何 concat 清单，见 §2 判据 7；⑤ 全量枚举终态 49/49 rc=0；⑥ 全语料三面对拍为空（§3.1），判定数减 210 有精确归因（§3.3）。

给后续批：改任何构建清单时，同步核对 `src/targets/x86_64-linux/_import.cr` 与 `src/compiler/_import.cr`。每任务回归面必须包含 `test_backend_bootstrap.py`，或者先按 #31 挂 CI。

---

## 7. 文档落点（判据 7）

| 文档 | 改动 |
|---|---|
| `docs/superpowers/plans/2026-09-11-r2-p3-capabilities.md` | Task 7 六步勾选和结果；新增“实施状态总表”（P3a 五个任务已完成，附提交和判据要点；P3b 两个任务未开始）；新增附录 B（§5 六节）；附录 B.3 终态行和减 210 归因注 |
| `TODO.md` | 新增 #34“R2 P3a 实施”（落点、提交链五条、判据、台账、P3b 剩余面、登记面、P5 继承、#26 判据继承、回归修复）；`fixed-array-retire` 未办句改为 R2 P3a 已办（剩余面登记）；#19 的“P3 面遗留”改为收口（动态档为既有机制、符号档为 VC 义务显式不实现、N 读取面守门）；#26 追加 P3a 继承注；#31 追加缺口的实际代价（本次漏检实证）和复测计数；#21 划销行保留 |
| `docs/superpowers/specs/2026-09-10-type-interface-unification-design.md` | §9 路线表 P3 行标为已完成（P3a）：五任务链、判据、P3b 未开工（阻塞为 `iface_satisfies`）；P3 未覆盖面显式登记（符号档、MAX_*、可选表示、`EXPR_LET`、空递归、短路根因、非枚举域、空洞穷尽） |
| `docs/superpowers/implementation/2026-09-10-type-shadow-findings.md` | 新增 §13“P3a 后复跑”：终态数字表、逐任务对拍表、减 210 归因、§12 九条宽松面“P3a 全部未动”声明、收紧台账指针、新登记面、交 P5 状态更新 |

---

## 8. 过程说明

- 本轮重跑与继承：重跑的是五个 CI job、49 套件枚举、自举链（cmp/N06/冒烟）、canary、`.ccr` 两档、终态影子 72 档乘 2 个二进制共四遍、减 210 归因的 4 次单档切换实验、修复后的 `test_backend_bootstrap` 复跑。继承的是各任务的行为探针、突变控制、逐任务对拍数字，未重跑，只引用并交叉核对，出处逐条标注在 §3.2/§4。
- 旧二进制口径：终态对拍用 `/tmp/p3t0_base_bin/corec`，即 P2b 末等于 P3a 起点树的 `8f69e346…`，是 P3a 全批的公共基线。各任务报告的内部数字用各自的前一任务基线，口径差异已在 §3.2 表注明。
- 回归的发现路径：本批不是先看报告再复述。全量枚举是本轮独立跑的，才暴露 §6，CI 和各任务回归面都没有覆盖。该回归在首轮枚举即被发现并修复，没有掩盖。
- 红态和无产物面：本轮为收尾，无新功能。§6 修复的红态是首轮枚举实测 rc=1 加 33 次 N06 日志，修复前原样留档在 `/tmp/p3t7/suites/test_backend_bootstrap.log`，修复后 rc=0 留档在 `/tmp/p3t7/backend_bootstrap_after.log`。
- 一次实验中的文件临时切换：§3.3 的归因实验临时加回 `import monomorph` 再删除，用备份、精确恢复、sha256 核对执行。实验后 `src/targets/x86_64-linux/_import.cr` 的 sha256 为 `8b8df2375956c9aad720c08f2c20c5b33dbef88a3bbb52451a31a6cb6c962816`，与实验前同值；`jj status` 没有意外改动。
- 工作量和资源口径：全部命令 `nice -n 19`，串行，无并发构建。本轮共约 7 次自举级构建（五个 CI job 各带一次，修复后两次复验档）和 4 遍语料全扫。语料运行器、探针、日志都不是仓库文件（`/tmp/p3t7*`）。本报告与 `docs/archive/sdd/` 其余报告一致，不入提交。

---

## 9. 提交

提交 sha 为 `3b2a43d26bbf39c0cdb96558797e195742756ce4`（change `yprmzvvv`，父提交 `9c0a83ec`）。路径限定 5 个文件（收尾提交）：`TODO.md`、`docs/superpowers/plans/2026-09-11-r2-p3-capabilities.md`、`docs/superpowers/specs/2026-09-10-type-interface-unification-design.md`、`docs/superpowers/implementation/2026-09-10-type-shadow-findings.md`、`src/targets/x86_64-linux/_import.cr`（§6 修复，本批唯一源改动）。提交后 `jj status` 工作副本干净。提交内容核对为上述 5 个文件（`jj diff --from 9c0a83ec --to @-`）。计划/TODO 内以“收尾提交”指代本 sha，自指约定同 P2b 收尾。

---

## 10. 证据命令速查（可复核）

```bash
# 回归（五 job；各自带重建，sha 不变）
nice -n 19 env CI_JOB_NAME=selfhost-tests  bash src/ci/run.sh
nice -n 19 env CI_JOB_NAME=bootstrap-tests bash src/ci/run.sh
nice -n 19 env CI_JOB_NAME=suite           bash src/ci/run.sh
nice -n 19 env CI_JOB_NAME=check           bash src/ci/run.sh   # 期望 rc=1（既有 2 TF01）
nice -n 19 env CI_JOB_NAME=full-bootstrap  bash src/ci/run.sh && cmp /tmp/corec2 /tmp/corec3
grep -c 'error\[N06\]' /tmp/p3t7/full-bootstrap.log            # 0
nice -n 19 ./build/corec run 'fn main()->int{return 42;}'; echo $?   # 42
# 全量套件枚举
cat /tmp/p3t7/suites.tsv
nice -n 19 python3 tests/selfhost/test_backend_bootstrap.py    # §6 修复后 rc=0
# canary + .ccr（先 clean-cache、cwd = 仓库根）
nice -n 19 ./build/corec clean-cache && nice -n 19 ./build/corec build tests/suite/ptr_arith.cr --static -o /tmp/x && sha256sum /tmp/x
nice -n 19 ./build/corec clean-cache && nice -n 19 ./build/corec ccr tests/suite/generics_test.cr -o /tmp/y.ccr && ls -l /tmp/y.ccr
# 终态影子 + 语料（四遍；旧 = /tmp/p3t0_base_bin/corec）
bash /tmp/p3t7_sweep.sh && cat /tmp/p3t7/agg_new.txt
# -210 归因（切换 target _import.cr 的 import 行前后）
nice -n 19 ./build/corec clean-cache && nice -n 19 ./build/corec check src/targets/x86_64-linux/main.cr --type-shadow | tail -1
```
