# R2 P4 Task 7 报告：收官（全量回归、判据复验、统一台账、文档、P5 交接）

日期：2026-09-13。基线：`cc015ae4`（P4 Task 6 收官，实现方式批第 8 个提交）。任务：计划 `docs/superpowers/plans/2026-09-12-r2-p4-carrier.md` 的 Task 7（Step 1 到 5）。
口径：cwd 为仓库根；所有命令使用 `nice -n 19`；一次构建一次编译串行执行；比较任何 `.ccr` 或缓存态产物前先 `clean-cache`；开工前用 `ps` 实查，构建进程为 0，本轮判据全部在 15:13 到 15:31 的独占窗口内执行（`/tmp/p4t7b/chain.out` 时间戳可核）。

性质说明（先读）：本实例是 resume，原 T7 实例因 API 402 中断。原实例遗留的 4 个文件文档改动（`CLAUDE.md`、计划、两份 spec）经审读后保留，内容正确，与各任务报告一致，见第 6 节。但其判据数字一律不采信，本报告第 1/2 节的每个数字都由本实例重新采集。碰撞窗验证档（`p4-task5-verify-independent.md` 第 6 节）明确声明未背书的五项（`corec2==corec3`、N06=0、冒烟 42、全枚举 54 到 55、同源语料对拍），本报告逐项重跑，并在此声明由本实例独立复现。

注：原实例在 `/tmp/p4t7/` 留下的中间产物（含一份 05:06 到 05:24 的自跑记录）与本轮互不引用，数字对照一致，见第 9 节第 ② 条。本报告一律以 `/tmp/p4t7b/` 本轮产物为准。

---

## 0. 交付摘要

| 项 | 结果 |
|---|---|
| 全量回归 | 五个 CI job 全部 rc=0；全枚举 55/55 rc=0（48 个 selfhost 加 7 个 bootstrap）；`selftest-types` 355/355；`check src/compiler` rc=0 |
| 构建确定性 | `build/corec` = `5d2b15ad746018619b01143cce400e6f3489ae72a962e12283a7afd3dcdb41e7`，与 T6 记录值逐字节相同，因此提交树等于被测二进制度 |
| ELF canary | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475` IDENTICAL（28822B；`--static` 冷态） |
| 自举链 | `corec2==corec3` 的 `cmp` IDENTICAL（双 2792078B `4919023b…f9034`），N06=0，冒烟 42（corec/corec2），`corec3 --help` rc=1 |
| 同源对拍 | 影子摘要两侧同值（`decisions=32620=agree`，全部计数为 0，站点覆盖逐项相同）；日志面唯一差异是 8 档 TF01 收口类 |
| 统一台账 | 收紧 10 类，放宽 2 项（非语义），崩溃和不报错地修复 8 种形态加 1 个不报错地错值类，全语料命中 0 |
| 判据勘误 | 2 条落纸（冷热判据只对可选程序成立；`.ccr` 记录值有两套命令口径） |
| P5 交接 | 计划附录 D（D-1 口径表、D-2 任务面、D-3 十四项继承项、D-4 检查单） |
| 提交 | 见第 7 节（路径限定 6 个文件，纯文档） |

---

## 1. 全量回归（Step 1）

脚本 `/tmp/p4t7b/run_all.sh` 加 `chain.sh`；逐档日志在 `/tmp/p4t7b/logs/` 和 `/tmp/p4t7b/enum/`。

| # | 项 | 命令 | 结果 |
|---|---|---|---|
| 1 | 三二进制构建 | `nice -n 19 python3 build_selfhost_native.py` | rc=0；`[GUARD]` corec manifest OK (45) / corearch (32) / x86_64-linux target (3) / corelsp (31)，三条 `build log clean (error[ = 0, undefined = 0)` |
| 1a | 构建 sha | 同上 | `build/corec` `5d2b15ad…`，`build/corearch` `493dc490…`，`build/corelsp` `18b94bd9…`；corec 与 T6 记录值逐字节相同 |
| 2 | 类型引擎自测 | `./build/corec selftest-types` | 355/355（rc=0；末例 `ct2.reject_unbuildable_sig`） |
| 3 | 自源检查 | `./build/corec check src/compiler` | rc=0（`ok`，诊断 0 条，TF01 收口后的口径） |
| 4 | 自举回归套件 | `python3 tests/selfhost/test_backend_bootstrap.py` | rc=0；11 条 `[PASS]`；构建日志 `error[` 命中 0（#31 未挂 CI 档，本批每个任务必跑） |
| 5 | 五个 CI job | `CI_JOB_NAME=<j> bash src/ci/run.sh`，5 次 | `check` rc=0；`bootstrap-tests` rc=0（29/29 加 4/4 加 3/3）；`selfhost-tests` rc=0（末档 `test_enum_limit` 13/13）；`suite` rc=0（21 档 ALL PASS）；`full-bootstrap` rc=0 |
| 6 | 全枚举 | `tests/selfhost/test_*.py`（48）加 `tests/bootstrap/*.py`（7），逐档 rc | 55/55 全部 rc=0（本轮 `chain.out` 逐档为 `SH 0 …`/`BS 0 …`，非零行数为 0） |
| 7 | 冒烟 | `./build/corec run 'fn main()->int{return 42;}'` 加 corec2 同命令 | rc=42 / rc=42 |
| 8 | `--help` 约定 | `/tmp/corec3 --help` | rc=1（既有约定） |

逐档计数（自举套件内层计数，抽样自 `chain.out`）：`test_ccr_types` 34/34、`test_ccr_v7` 27/27、`test_optional` 34/34、`test_enum_limit` 13/13、`test_iface_ops` 76/76、`test_params_limit` 5/5、`test_tuple_slots` 14/14、`test_tf01_fallthrough` 19/19、`test_region_cfg` 22/22、`test_interp_parity` 23/23、`test_match_exhaust` 16/16、`test_impl_iface` 20/20、`test_generic_constr` 15/15、`test_iface_satisfies` 17/17、`test_xcut_iface` 12/12、`test_live_ranges` 13/13、`test_hit_table` 24/24、`test_dex_arith` 11/11、`test_global_init` 15/15、`test_nested_fn` 17/17、`test_agg_checks` 20/20、`test_agg_slots` 13/13、`test_borrow` 7/7、`test_impl` 7/7、`test_native_memory` 6/6、`test_slice_bounds` 7/7、`test_directory_build` PASS、`test_ent_kernel_neutrality` PASS、`test_lexer_parity` PASS、`test_named_dedup` PASS、`test_pointer_safety` PASS、`test_purity` PASS、`test_type_engine` PASS，其余 PASS 型同上，逐档末行在 `/tmp/p4t7b/chain.out`。

---

## 2. 判据复验（Step 2），碰撞窗未背书的五项由本实例全部重跑

| # | 判据 | 命令 | 本轮结果 | 背书状态 |
|---|---|---|---|---|
| 2.1 | ELF canary | `clean-cache`，然后 `build tests/suite/ptr_arith.cr -o /tmp/p4t7b/pa_t7 --static`，再 sha256 | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475` IDENTICAL（28822B；Task 5 允许面未被触发） | 本实例重跑 |
| 2.2 | `corec2==corec3` | `build src/compiler/main.cr -o /tmp/corec2 --static -O 0`，corec2 同命令产 corec3，然后 `cmp` | IDENTICAL（双 2792078B，sha `4919023b3e92b661219f4624859512d53abb58e3dbfe874a51ae8a5b297f9034`） | 本实例重跑（此前仅另路声明） |
| 2.3 | N06=0 | `grep -c -F 'error[N06]'`（corec2/corec3 构建日志；本轮取 CI `full-bootstrap` 日志） | 0 | 本实例重跑 |
| 2.4 | 冒烟 42 | `corec run 'fn main()->int{return 42;}'` 加 corec2 同命令加 `corec3 --help` | 42 / 42；`--help` rc=1 | 本实例重跑 |
| 2.5 | 全枚举 55/55 | 见第 1 节第 6 条 | 55/55 rc=0（48 个 selfhost 加 7 个 bootstrap，含 #31 档） | 本实例重跑 |
| 2.6 | 同源语料对拍 | `/tmp/p3t0_run.sh {check,shadow}` 分别用 pre-P4 `/tmp/p4t7/sb/build/corec`（`9a583215…`）和当前 `build/corec`（72 档/面，逐档 `clean-cache`） | 见下表 | 本实例重跑（此前仅另路声明） |

### 2.6 同源对拍（pre-P4 配当前源对比当前配当前源）

| 面 | pre-P4 侧 | 当前侧 | 结论 |
|---|---|---|---|
| 影子摘要 | 70 档出摘要；`decisions=32620 agree=32620`；`old_stricter`/`old_looser`/`unknown_bridge`/`unknown_engine*`/`replace_*` 全为 0 | 同值 | 判定面零变化 |
| 站点覆盖 | `assign-node=24721 · fn-body-ret=5828 · if-branch=2037 · struct-field-type=28 · array-elem-type=4 · generic-apply-base=2`（其余为 0；总和 32620） | 逐项相同 | 同上 |
| check 和影子日志 | 5 档语料差异（diff 头 8 个，等于 5 个日志加 3 个 rc），100% 是 TF01 收口类（5 处 `ty_memo_slot_no_grow` 误报消失，3 档 rc 从 1 变为 0；rc 分布从 31 档 0、41 档 1 变为 34 档 0、38 档 1） | 无 | 属于 P4 内的有意修复，不是语义回归 |
| dumps 目录 | 空（没有差异条目，`sh_dump_write` 早退） | 空 | 注意：这是空洞证据，不得引用“dumps diff 为空”作为强证据（findings 第 14 节） |

实现方式面零覆盖声明（继承纪律）：影子通道只覆盖 `type_equal` 站点面，对段、读回、TK、表示零覆盖。本批实现方式正确性证据是结构性断言（第 2.7 节）、corearch 读回对拍、定向探针，见各任务报告。

### 2.7 `.ccr` 面（两套口径、冷热、段结构）

| 项 | 本轮实测（冷缓存，`clean-cache` 后） |
|---|---|
| `ccr` 口径（`corec ccr F -o O`） | `ptr_arith` 90823B `fb4a3b59103f4e0c…`；`generics_test` 134701B `cafb42781f8a4f9b…`；自源 `src/compiler/_import.cr` 10661888B `76c76bb1ff3932b6…`（新记录值；源随 P4 变更，不与前批直比） |
| `build --static` 口径（读 `O.ccr`） | `ptr_arith` 冷 90966B `592afa31d66cc75a…` / 热 90769B `16996f1c95f6143…`；`generics_test` 冷 134844B `ec8413ec55007f51…` |
| 冷热（非可选程序） | 冷不等于热（`ccr` 口径 90823/90626 `05531c0b…`；`--static` 口径 90966/90769）。两态各自确定性可重复。预存面：pre-P4 二进制同样如此（89086 `b0b10406…` / 88954 `1ae48560…`），不是 P4 引入，属于 TODO #5 末条家族，因此非可选程序豁免该判据 |
| 冷热（可选程序，关闭 `.cir` 缓存） | IDENTICAL（97604B `2bfbbe2b…` 两态同），因此判据只对“可选面零影响”程序成立 |
| 两口径关系 | 差恒为 143B（`--static` 前置 `rt.cr`，增加 4 个全局加 1 个串，`main.cr:423-425`）。口径一致性交叉验证成立。T5 报告的“arena_globals 导入”归因有误，但数值成立 |
| 段结构断言 | `magic=827474755 version=8 seg_count=8 reserved=0`；tag 序为 [1..8]；offset 连续；末段尾等于 fsize（三档语料逐档核对） |
| 旧 `.ccr` 拒收 | T1 已实测（v7 六段整类拒收，rc=1 且无产物）；本轮段结构断言复核版本 8 是单一真源 |

---

## 3. 统一台账（T0 到 T6 汇总，Step 3）

逐件出处是 `docs/archive/sdd/p4-task{0..6}-report.md`。分类口径：收紧表示旧接受变为新拒绝（新增诊断或硬门）；放宽表示旧拒绝变为新接受；修复表示旧崩溃或不报错地错值变为正确值。

### 3.1 收紧（合计 10 类）

| 任务 | 类 | 内容 | 全语料命中 |
|---|---|---|---|
| T0 | 0 | 纯搬运，零行为变化 | 无 |
| T1 | 3 | ① 缺 TYPE 段则拒绝；② 缺 IFACE 段则拒绝（D11 必备集）；③ 版本不等于 8 整类拒收（含全部 v7 文件） | 0（72 档 check 加 21 档 suite build/run 加 46 个 selfhost 套件） |
| T2 | 2 | ① save 侧装填遇到不可译行则 save 拒绝（rc=1 加诊断）；② loader 的 TYPE 结构不变量（计数和长度自洽、恰好两小节、tag 域、子项引用拓扑、`a..d ≥ -1`）违规时整体拒绝 | 0（56 档 report-only；失败集与 pre-T1 基线逐条相同） |
| T3 | 2 | ① 签名不可建（`dyn` 位图行进入签名）则 save 拒绝；② loader 的 IFACE 五小节域检查加跨段引用域（`name_ni` 小于 STR 串数、`ti_row` 小于 TYPE 行数、`term` 小于 TYPE 项数） | 0（61 档 report-only；`save refused` 两侧皆为 0） |
| T4 | 0 | 项槽派生和快照面，不动判定 | 无 |
| T5 | 0 | 不动判定面，用对拍反证 | 无 |
| T6 | 3 | ① `P022` 枚举变体超过 16；② `P022` 载荷类型超过 16；③ `P023` 结构体字段超过 16（写入侧护栏是前端的 parse 阶段检查） | 0（139 个文件静态扫描加 suite 25 档加 examples 逐档：P022/P023 命中 0） |

### 3.2 放宽（合计 2 项，均非语义放宽）

| 任务 | 类 | 内容 |
|---|---|---|
| T2 | 1 | T1 的 TYPE 空壳检查退役（“非空即拒”改为内容不变量检查），同批改 save 和 load，自产物不再被自己拒绝 |
| T3 | 1 | T1 的 IFACE 空壳检查退役（同上）；另外 `name_ni` 从“留 -1”翻转为“逐名注册”（裁决 1，纯信息面） |

### 3.3 崩溃和不报错地错值修复

| 任务 | 形态 | 内容 |
|---|---|---|
| T5 | 8 种形态加 1 个不报错地错值类 | 裸值路径（L1/L5/L6/L8/L9 局部加 X1/X4/X6 跨函数返回和形参）双路径 rc=139 变为正确值；1 个不报错地错值类等于 `?` 解包装箱值（修复前 ELF=8 / interp=200，各自都错，现在 7/7） |
| T5 补 | 1 个预存不报错地类 | `IR_LOAD_ENUM_TAG` 的 tag 读取源缺少全局行分派（全局可选槽导致 ELF=0 / interp=5 不报错地分歧，基线同样如此），源改走 `e2_load_var` |
| T6 | 不报错地面（表污染） | 越界写不报错地（17 个变体时 `check` rc=0、零诊断，穷尽性判定被不报错地禁用）变为 P022/P023 定位硬错 |
| T4 | 1 个潜在不报错地类（未落盘即消灭） | 项引用落进程内索引必然悬空（`bad_term=329` 红证），因此不落盘，装载侧重派生 |

### 3.4 实施偏差（实测推翻或修正计划文本）

| # | 计划文本 | 实测结论 | 出处 |
|---|---|---|---|
| 1 | D15/Step 4：`.cir` 快照进入项槽，`CIR_CACHE_VER` 从 17 到 18 | 推翻：入槽版暖路径 `bad_term=329`（进程内索引全部悬空），因此不落槽，保持 17，装载侧在 emit 等价时点重派生（冷热 1298 行逐行相同） | T4 第 4 节 |
| 2 | Global Constraints：TYPE 段冷热逐字节相同 | 半成立：项表和 probe 冷热相同（D13 项面承诺成立）；行表冷 15、热 12（热路径跳过 `ir_gen`，不重建 `alloc_type` 行），热态是冷态前缀 | T2 第 8 节第 ③ 条 |
| 3 | spec 第 3.7 节字段宽度 `{kind i32, data i32, extra i32}` | 与 24B 段体自相矛盾，实施权威为 8B 字段（与内存槽同宽），spec 和头注释同批改正 | T2 第 1 节 |
| 4 | Task 3 方法记录字段序（声明行和尺寸式次序相反） | 取声明行序（项槽在裸码槽之前），四处同序 | T3 第 1 节 |
| 5 | T1 Interfaces 的段体缓冲 | 延后到 T2 内容构造者（空壳期预置就是死码） | T1 第 2.1 节 |
| 6 | T2 判定原语跨进程同值 | 未被覆盖（`type_engine.cr` 进入 corearch 一度触发 TF01，因此走路径 (a) 收口；探针改用项层原语） | T2 第 9 节第 ② 条 |
| 7 | 清单面为“三面同核” | 实际是四面（concat 两份加 project-mode 两处加测试自带副本 1 份），由全枚举捕获 2 处变化 | T0 第 2.4 节 / T1 第 7 节第 ① 条 / T2 第 9 节第 ① 条 |

### 3.5 pin flip 和计数器清单（逐条）

| 任务 | flip |
|---|---|
| T0 | `tests/selfhost/test_compile.py` 自带清单增加 `iface_axis.cr`（计划未列，全枚举捕获） |
| T1 | `test_ccr_v7.py`：`SEG_TAGS [1..8]`、`HEADER_TABLE 88` 改为 112、`V7 7` 改为 8、`seg_count==6` 改为 8、坏版本三元组 `(6,5,8)` 改为 `(7,6,5)`；`test_region_cfg.py`：段集 `(1..6)` 改为 `(1..8)` 加 `assert ver==7` 改为 8（计划未列） |
| T2 | `selftest-types` 333 到 338；`test_ccr_types` 9 到 19；corearch 清单 30 到 31（`type_terms.cr`） |
| TF01（附带件） | `check` job 判据 rc 从 1 变为 0；`test_iface_ops` 3 条过期期望随批更新（76/76 复绿）；corearch 清单 31 到 32（`type_engine.cr`） |
| T3 | `selftest-types` 338 到 347；`test_ccr_types` 19 到 28；`IFACE_ENTRY_COUNT` 13 到 16（selftest 硬值 1362/2362 同批）；`ESZ_IFMETHOD` 168 到 240；`ESZ_IFACEINFO` 2712 到 3864 |
| T4 | `selftest-types` 347 到 355（`t4.tk_*` 8 例）；`test_ccr_types` 28 到 34；`ESZ_DFNODE` 64 到 72；`run.sh` 注释 346 到 355；未 flip：`CIR_CACHE_VER`（保持 17，格式未变）、`test_type_engine.py:MIN_CASES=32`（下限，登记） |
| T5 | `test_optional` 12 到 34；`run.sh` 注释同步；`test_enum_limit` 新增 13 例挂 CI |
| T6 | `test_enum_limit.py` 13 例加 `run.sh` 挂钩；`selftest-types` 保持 355（不加例，遵守计数纪律） |

### 3.6 全语料扫描（report-only 证据链）

| 批 | 扫描面 | 结果 |
|---|---|---|
| T1 | 72 档 check 乘 2 个二进制加 21 档 suite build/run 加 46 个 selfhost 套件 | 新拒绝路径零命中 |
| T2 | 56 档（`corec ccr` 加 `corearch --dump-types`） | 失败集与 pre-T1 基线逐条相同（10 档既有失败） |
| T3 | 61 档（suite 加 examples 加 stdlib 加自源加后端单元） | 失败集逐条相同（11 档既有）；新 `save refused` 为 0 |
| T6 | 139 个文件静态扫描加 suite 25 档加 examples | P022/P023 为 0；没有超过 12 个变体的枚举，最大结构体字段为 9 |
| T7 | 72 档乘 {check, shadow} 双二进制对拍（第 2.6 节） | 差异 100% 是 TF01 收口类；判定面零变化 |

---

## 4. 判据勘误（Step 2 的落纸面；计划 Global Constraints 和附录 D-1 已回填）

勘误 ①：“`.ccr` 冷热两态逐字节相同”对非可选程序不可达。
- 实测（本轮复现）：`ptr_arith` 冷 90966B/`592afa31…` 不等于热 90769B/`16996f1c…`（`--static` 口径；`ccr` 口径为 90823/90626）。两态各自确定性可重复。pre-P4 二进制同样如此（89086/88954），因此是预存问题（TODO #5 末条家族，不是 P4 引入）。
- 因此判据只对“可选面零影响”程序成立（可选程序关闭 `.cir` 缓存，冷热按构造相同；实测 `2bfbbe2b…` 97604B 两态相同）。非可选程序豁免，替换为：① 冷态可重复加热态可重复；② 与同源基线编译器在同口径下逐字节相同；③ 可选程序冷热 IDENTICAL；④ TYPE 段的项表和 probe 冷热相同（行表随缓存态，T2 第 8 节第 ③ 条已登记）。

勘误 ②：`.ccr` 记录值有两条命令口径，引用必须带口径。
- `corec ccr F -o O`：`ptr_arith` 90823B，`generics_test` 134701B（T3/T4 记录值）。
- `corec build F -o O --static`（产 `O.ccr`）：90966B / 134844B（T5/T6 记录值）。
- 差恰好 143B：`--static` 在 `main.cr:423-425` 前置 `rt.cr`，使 4 个全局加 1 个串进入 `.ccr`。两套各自确定性可重复（本轮逐条复现）。

---

## 5. P5 交接包（Step 4 的一部分；正文是计划附录 D）

放置声明：P5 尚无独立计划（实查 `docs/superpowers/plans/` 没有 P5 文件），立计划时以计划附录 D 为起点。指针链是统一设计 spec 第 9 节的 P4 行、计划 Task 7、附录 D、TODO #44。P5 实施者从这三处任一处入手都能到达，P5 看的第一份实现物是附录 D。

| 面 | 内容 |
|---|---|
| D-1 | `.ccr` 两套口径表加冷热豁免表（含自源 T7 新记录值加 `--static` 差因） |
| D-2 | P5 任务面：① DFNode.TK 单槽化（前置为 D-3-2）；② 大步删除旧路径（`type_equal_legacy` 删除加 unknown 清零加桥接缓存退出加影子挂点清理）；③ 文档和台账 |
| D-3 | 十四项继承项，逐条给现状证据和前置裁决 |
| D-4 | 开工前置检查单（逐项可核） |

P5 必读的继承项（本报告点名的六项）：
1. D-3-2 项引用稳定形态（T4 concern，最高优先）：`bad_term=329` 红证。项表是进程内内容寻址表，落进程内索引必然悬空，因此三选一先裁（内容寻址、落盘项 ID、装载侧同款重派生），不得直接落进程内索引。
2. D-3-3/4 unknown 清零加 `type_equal_legacy` 删除：前提是引擎命名展开，而 P3a 展开层按裁决只服务满足判定和域查询，前提不会被自动满足。P5 必须在“接受命名展开（推翻 P2a 对拍基线）”和“legacy 长期化（承认 -1 面）”之间二选一，不得默认。
3. D-3-5 桥接缓存退出生产路径（`sh_*_ak_legacy`，TODO #24/#30）加 D-3-6 站点 6 去留（零命中不等于可删，须先补站点评级说明）。
4. D-3-7 对象布局表示位（T5 concern）：结构体字段、数组元素、全局槽、match 结果的不配位面；修复面是 packed 位图或 element stride；与 D-3-8 同批（同触 `dyn_arr.cr` 布局加 `ast.cr` 镜像）。
5. D-3-8 `MAX_*` 解除（T6 裁定）：三个上限（都是 16）只约束进程内定长记录，盘面变长不受限，解除是同一个决策（记录布局改为侧表）。前置四条是读回检查同步、`ast.cr` 镜像归位（镜像 64 与布局 16 已经不一致）、覆盖位表示超过 63 个变体、冷热与 canary 判据。护栏是解除时的安全网。
6. D-3-9-(ii) 预存暖态 SIGSEGV：`corec build src/compiler/main.cr -O 0` 暖态 rc=139（`load_cir_cache` 到 `str_len`，再 `load64`，gdb 栈；基线二进制同样如此）。可选面的规避只覆盖可选程序，因此另单必修（TODO #5 家族）。D-3-9-(i) 是可选程序关缓存的收回，与 D-3-7 同批。
7. D-3-14 TODO 指针：#32（`EXPR_LET` 无检查）未随 P4 收口，因此 P5 排入；#35 已由 T6 划销；#43 是 T5 实施条目（P5 如果收回可选程序缓存，先读其登记面）。

---

## 6. 文档（Step 4）和 WIP 处置

原实例遗留的 4 个文件改动，审读结论是全部保留，内容与各任务报告一致，没有过度声明：

| 文件 | 改动 | 审读 |
|---|---|---|
| `CLAUDE.md` | `.ccr` 描述从 v6 改为 v8/8 段（命令注释加 bootstrap 目录注加 Key Conventions 三处） | 正确（现行 `CCR_VERSION=8`/`CCR_SEG_COUNT=8` 实读） |
| 格式 spec `2026-09-09-lattice-ir-v7-format.md` | 第 5 节测试族计数刷新（`test_ccr_types` 34/34 加逐批构成）加判据口径注（TODO #26） | 与第 1/2 节实测一致 |
| 统一设计 spec `2026-09-10-type-interface-unification-design.md` | 第 9 节 P4 行标完成（8 个提交链加判据加统一台账加未覆盖面和继承项指针） | 数字本轮全部复现 |
| 计划 `2026-09-12-r2-p4-carrier.md` | 状态表（T0 到 T7）加收官判据加 Task 7 五步勾选加 Global Constraints 勘误加附录 D | 保留；本轮增补修正 5 处，见下 |

本轮（T7 实例）对计划的增补修正：① 影子“dumps diff 为空”改为摘要加站点覆盖，并加 dumps 空洞性注（`sh_dump_write` 早退）；② D-1 冷热表补 `ccr` 口径行（90626B `05531c0b…`）加自源新记录值行；③ D-3 增加 #14“未随 P4 收口的 TODO 指针”；④ D-4 增加两项检查（#32 排期、暖态 SIGSEGV 复现命令）；⑤ 收窄一处措辞（125 条 IR 指令差归 `--static` 侧实测）。

本轮其他文档：
- `TODO.md`：新增 #44（P4 收官条目）；#26 追加“R2 P4 继承与判据勘误”注（两条勘误加两套口径）；修正 #43 一处编辑事故（② 条内一段括号说明重复出现，删除重复段）。
- `docs/superpowers/implementation/2026-09-10-type-shadow-findings.md`：追加第 14 节“P4 后复跑”（对拍口径、结果表、dumps 空洞性声明、效力范围、承接 P5）。原实例在计划 Step 4 声明了该节但未落盘，本轮补齐。

---

## 7. 提交（Step 5）

提交为 `9bcb7083`（change `nxnzrxtk`；`jj diff -r 9bcb7083 --summary` 核过，恰好 6 个路径，`src/`/`tests/`/`build_selfhost_native.py` 命中 0）。路径限定 6 个文件，纯文档；源码零改动，因此第 1 节的被测二进制度继续有效：

```
docs: R2 P4 Task 7 收官，全量回归（五 CI job + 全枚举 55/55 + selftest 355/355 + 自举链
      cmp IDENTICAL + canary IDENTICAL）+ 碰撞窗未背书五项本实例重跑 + 统一台账（收紧 10 类/
      放宽 2/修复 8 形态+1 静默类/全语料命中 0）+ 判据勘误两条（冷/热判据只对可选程序成立；
      .ccr 两套命令口径差 143B）+ P5 交接包（计划附录 D 十四项）+ 文档（TODO #44/#26/#43、
      findings 第14、CLAUDE.md/两 spec v8 同步）
```

文件：`CLAUDE.md`、`TODO.md`、`docs/superpowers/plans/2026-09-12-r2-p4-carrier.md`、`docs/superpowers/specs/2026-09-09-lattice-ir-v7-format.md`、`docs/superpowers/specs/2026-09-10-type-interface-unification-design.md`、`docs/superpowers/implementation/2026-09-10-type-shadow-findings.md`。

本报告与其他 `docs/archive/sdd/*` 报告同档，不入版本控制，`jj status` 不包含该目录。

---

## 8. 证据路径（本机）

- 驱动脚本：`/tmp/p4t7b/{chain.sh,run_all.sh,criteria.sh,parity.sh,aggregate.sh}`，全量输出 `/tmp/p4t7b/chain.out`
- 构建和判据日志：`/tmp/p4t7b/logs/{build,selftest,check_self,check_self2,tbb,ci_*,canary_*,ccr_*,smoke_*,corec3_help,bs_*}.log`
- 枚举逐档：`/tmp/p4t7b/enum/*.log`（55 档）
- canary：`/tmp/p4t7b/pa_t7`（28822B）；段结构和记录值：`/tmp/p4t7b/{pa_cold,pa_warm,pa_s_cold,pa_s_warm,gen_cold,opt_cold,opt_warm,selfsrc_cold}.ccr`
- 自举链：`/tmp/corec2` / `/tmp/corec3`（cmp IDENTICAL `4919023b…`）
- 对拍：`/tmp/p4t7b/parity/{pre,new}_{check,shadow}/{logs,dumps}` 加 `/tmp/p4t7b/meas/{check_diff.txt,shadow_logs_diff.txt,shadow_dumps_diff.txt}`（runner 为 `/tmp/p3t0_run.sh`；pre-P4 二进制为 `/tmp/p4t7/sb/build/corec`，等于 `9a583215…`）
- 原 T7 实例遗留（对照用，不是本报告证据）：`/tmp/p4t7/`（同款数字，与本轮独立吻合）

---

## 9. 登记面和未完成项

① 未重跑项（显式）：`--dump-objects` 逐字节对拍（T4 判据）和编译耗时抽样（T4/T5）本轮未复跑。其对象是任务内二进制度，已经在各任务报告实测，本轮全量回归未触其面。如果需要 P5 基线，可以照 T4 第 5 节第 8/17 条命令复跑。

② 原实例中间产物对照：`/tmp/p4t7/`（05:06 到 05:24 自跑）与本轮 `/tmp/p4t7b/`（15:13 到 15:31）数字逐项一致（构建 sha、selftest 355、CI 全部通过、枚举 55/55、canary、cmp 双 2792078B、冒烟 42、影子 32620、`.ccr` 两口径、冷热）。差异只是本轮补齐了 dumps 空洞性判定和对拍日志分类，原实例只留 rc，未留分类。

③ 预存缺陷（不是 P4 引入，转 P5/P6 单）：暖态 `.cir` 缓存 SIGSEGV（D-3-9-(ii)）；冷热 `.ccr` 分歧（TODO #5 末条，本批量化并重定判据）；`test_type_engine.py:MIN_CASES=32` 是下限（建议后续收紧到实测值）。

④ 纪律提醒（防止稀释）：实现方式面证据不得引用影子通道；`.ccr` 记录值引用必须带口径和缓存态；清单改动必须跑全枚举加 `test_backend_bootstrap`（四面同核）。
