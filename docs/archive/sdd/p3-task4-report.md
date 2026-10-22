# R2 P3 Task 4 报告：联合/可选（enum = sum 项、`T?` = T ∪ null、退役内建 Option 注册）

Status: DONE_WITH_CONCERNS（判据全部通过；9 项登记：① 决策点裁定 = `null` 表示体取计划推荐 (a) 新增原生原子 `AK_NULL`；② T0 交接 ① 已办（枚举载荷类型节点列 + 唯一消费者 + 入库断言通道）；③ 运行期表示未统一（Some 值 = 枚举对象 / 裸值 = 裸值），计划未列 ir_gen/后端，登记为未覆盖面；④ 本任务暴露并修复一处既有崩溃面（`sym_*` 访问器 + bootstrap 不短路，T0 第 5 节-③ 根因仍开放）；⑤ 修掉一处既有编译器挂死（`Some(x)` 实参链契约，rc=124）；⑥ 站点面子类型只对可选目标注入（其余子类型规则不动）；⑦ `T?` 行不去重（每出现点一行）；⑧ 枚举变体数/载荷数 >16 越界写（既有，新布局下影响变化，未修）；⑨ 收紧清单 3 条 + 放宽 7 条 + 挂死修复 2 条，逐条实测见 第 3 节）
提交：见 第 9 节（路径限定 14 文件）
计划：`docs/superpowers/plans/2026-09-11-r2-p3-capabilities.md` Task 4（P3a）
起点：`e9818d62`（= P3 Task 3 末提交；工作副本干净，`selftest-types` 263/263）
范围口径：`T?` = `T ∪ null`（spec 第 5.4 节）：类型层联合语义（项/桥接/引擎/判定点注入/穷尽性域）+ 退役内建 Option 注册 + `Some`/`None` 内建解析 + `?` 结构解包 + T0 交接 ①（载荷类型节点列）。

---

## 0. 决策点裁定（计划 Task 4「实施前须定」）

计划列三候选：(a) 新增原生原子 `AK_NULL`（推荐）/ (b) `null` 归 `AK_UNIT` / (c) 仅保留枚举形态。
裁定 = (a)，依据（逐条实测/读码，非判断）：
- `None` 是语言关键字值（lexer.cr:105 `T_NONE`），其类型在模型中必须有一个值域 = 单点的原子；`AK_UNIT` 的值域是 unit 单值，两者合并即「`None` ≍ `unit` 值」不报错地混淆（候选 b 的自认缺陷），且 `null` 与 `unit` 应当不相交（本实现已钉：`t4.null_disjoint_and_inhabited` 断 `ty_disjoint(null, unit) == 1`）。
- 候选 (c)（纯枚举形态）与 spec 第 5.4 节 直接相悖（「`T?`/Option = `T ∪ null`，不再依赖内建 Option 枚举名」）。
- (a) 的实施代价经实测受控：`AK_NULL` 只进引擎原子宇宙（第九员）+ `ak_disjoint` 一条公理；不进 `iface_registry` 条目表（`iface.count == 13` 是 P2b 判据硬值）因此 `iface_kind_of` 对表示行回 `-1`（无操作许可 = 算术/逻辑/条件门全拒，正是期望行为，`t4.null_no_ops_no_entry` 固定）。
- 行面表示：`TYP_OPTIONAL(data = 内层行)` + `TYP_NULL`（两新 kind，ast.cr:321/324）+ 新 AST 节点 `EXPR_OPTIONAL`（ast.cr:251，`T?` 的目标形态；退役 parser 里 `T?` 改为 `Option[T]` 的名字依赖与 `str_intern("Option")`）。

---

## 1. 交付物与落点（file:line，全部实测）

| 交付物 | 落点 |
|---|---|
| `TYP_OPTIONAL` / `TYP_NULL` kind + `EXPR_OPTIONAL` AST 节点 | `ast.cr:321 / :324 / :251` |
| `T?` 目标形态（零名字依赖；删 `str_intern("Option")`） | `parser.cr:139-148` |
| `Some(...)` 实参 EXPR_ARG 链（契约修复，见 第 6 节-①） | `parser.cr:418-455` |
| 枚举变体载荷类型节点写入（T0 交接 ①） | `parser.cr:1630` |
| 枚举表布局扩展（载荷节点列；`OFF_EV_SIZE` 从 144 改为 272，`ESZ_ENUMINFO` 从 2360 改为 4408） | `dyn_arr.cr:58 / :161-164` |
| 载荷节点访问器 `ei_variant_type_node` | `dyn_arr.cr:417` |
| `sym_*` 读取面护栏（崩溃修复，见 第 6 节-④） | `dyn_arr.cr:325-333` |
| `.ccr` 读回侧节点列零写（不落盘，v7 段布局不动） | `ccr_io.cr:1133-1136` |
| `AK_NULL`（原生第九员）+ `ak_disjoint` 公理 | `type_engine.cr:28-36 / :74` |
| `null` 项 `sh_null_term`（行号不入项 因此 全仓单节点） | `ty_shadow.cr:269` |
| 桥接：`TYP_OPTIONAL` 对应 union(内层项, null)，`TYP_NULL` 对应 null | `ty_shadow.cr:313-323` |
| 可选域：`sh_match_domain_term` / `sh_match_opt_pat` / `sh_match_opt_term`；`sh_match_exhaustive` 接域面 | `ty_shadow.cr:919 / :931 / :942 / :903` |
| 载荷项 `sh_variant_payload_at` / `sh_variant_payload_term`（载荷节点列唯一消费者） | `ty_shadow.cr:956 / :981` |
| 载荷列入库断言 `sh_evp_verify` + 通道 `--verify-evp-nodes`（默认关） | `ty_shadow.cr:1010` + `main.cr:188-190 / :236` |
| `T?` 目标行解析（res_type_node / res_call_type） | `checker.cr:861 / :1569` |
| 退役内建 Option 注册（零行零符号） | `checker.cr:1082-1089` |
| 内建 `Some`/`None` 构造器（关键字名分派；用户同名变体优先） | `checker.cr:2737-2783` |
| `EXPR_TRY` 结构解包（废 `base_name == "Option"/"Result"`） | `checker.cr:3170-3178` |
| 判定点可选目标子类型注入 `ti_subsumes` | `checker.cr:433-461` |
| `type_equal_legacy` 新 kind 分支（对拍对照物一致性） | `checker.cr:576-584` |
| `type_display`（`T?` / `null` 措辞）/ 结构形参提及下钻 | `checker.cr:1503-1505 / :1466` |
| match 收集面（可选分支 + 覆盖位 + 反例命名） | `checker.cr:2600-2620 / :2665-2674` |
| monomorph 克隆分支（EXPR_OPTIONAL） | `monomorph.cr:250` |
| LSP 类型节点显示 | `lsp/analysis.cr:112-117` |
| 自测用例 16 例（t4.*，263 增加到 279） | `type_selftest.cr:1479-1612` |
| 行为覆盖集 12 例（双路径 rc + 硬门 + 退役 + 载荷列） | `tests/selfhost/test_optional.py`（新） |
| CI 挂钩 + 计数同步 | `src/ci/run.sh:71 / :86` |
| TODO #32（EXPR_LET 站点无兼容检查，协调者交办项） | `TODO.md` |

---

## 2. 判据（命令 + 结果）

| # | 判据 | 命令 | 结果 |
|---|---|---|---|
| 1 | 自举构建 | `nice -n 19 python3 build_selfhost_native.py` | rc=0；三守卫 `build log clean (error[ = 0, undefined = 0)` |
| 2 | 自测用例表 | `nice -n 19 ./build/corec selftest-types` | 279/279（基线 263/263，增加 16 例，零 FAIL） |
| 3 | 接口查表回归 | `nice -n 19 python3 tests/selfhost/test_iface_ops.py` | 76/76 passed |
| 3b | Task 3 覆盖集 | `nice -n 19 python3 tests/selfhost/test_match_exhaust.py` | 16/16 passed |
| 3c | 本任务覆盖集 | `nice -n 19 python3 tests/selfhost/test_optional.py` | 12/12 passed |
| 4 | ELF canary 逐字节 | 先 `clean-cache`，再 `build tests/suite/ptr_arith.cr --static -o …`，最后取 sha256 | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475` IDENTICAL |
| 4b | `.ccr`（计划预期 = 变，须实测报告） | 先 `clean-cache`，再 `ccr tests/suite/ptr_arith.cr` | `54e3856b383301be5daecaf61f75ce120e56ef4d1569c3008009fc368b750df9`（≠ 旧 `ecd7a9df…`），变更面已逐段实测，见 第 5 节 |
| 5 | 收紧清单 + 全语料 report-only | 第 3 节（14 探针 × 旧/新二进制）· 第 4 节（72 档 check 复跑） | 收紧 3 条（含 2 条挂死修复）+ 放宽 7 条；语料零命中 |
| 6 | 影子对拍门 | 72 档 `--type-shadow --type-shadow-dump` | 第 4 节：`decisions=29687 agree=29687`、全计数 0、dump 逐字节同 |
| 7 | 回归套件 | CI `selfhost-tests` rc=0（15 档全部通过）+ `bootstrap-tests` 3/3 + `suite` ALL PASS + `test_lsp` 10/10 + `test_named_dedup` PASS + `test_slice_bounds` 7/7 + `test_lexer_parity` PASS | 全部通过 |
| 8 | 自举链 | CI `full-bootstrap` | rc=0；`corec2 == corec3` cmp IDENTICAL（2,300,870 B）；N06=0；冒烟 `run 'fn main()->int{return 42;}'` = 42（corec 与 corec2 双通道） |
| 9 | 突变控制 | 第 5 节（4 个突变、用例生效、复位） | 6 例 selftest 失败 + 4 例行为失败（增量互不重叠）；复位后 279/279 + 三二进制 sha 逐字节复原 |
| 10 | 确定性 | 连续重建（含 CI 两次自带重建） | `corec 9eb68846…` / `corearch 8c717d1e…` / `corelsp e85ce76a…` 全程不变 |

冻结二进制（交付）：`corec 9eb68846…` · `corearch 8c717d1e…` · `corelsp e85ce76a…`。

---

## 3. 行为探针与清单（旧/新逐条；探针目录 `/tmp/p3t4_ledger/`）

旧二进制口径：`/tmp/p3t3_base_bin/corec`（Task 1 末树）。本批面（`T?`/`Some`/`None`/Option 注册/EXPR_TRY）Task 3 一行未动（其报告 第 6 节-⑥ 自证「`T?` 的桥接/注册表行语义零改动」）因此 下列旧值为该面的真实前置态。

### 3.1 收紧清单（旧接受变为新拒绝或新诊断；3 条）

| # | 用例 | 旧 | 新 | 措辞/码（新） | 成因与处置 |
|---|---|---|---|---|---|
| T1 | p8 `fn f(x: Option[int]) -> int`（无用户声明 Option） | rc=0（零诊断） | rc=1 | `Undefined type in generic application`（EC_N_GENERIC_TYPE=N09，软诊断：build 仍 rc=0） | 退役内建 Option 注册的直接后果（spec 第 5.4 节 明令）；`Option` 不再是语言内建类型名，用户声明则按普通枚举解析 |
| T2 | p9 用户 `enum Option[T]{None,Some(T)}`：`fn g() -> int? { return f(); }`（f 返回 `Option[int]`） | rc=124（挂死，30s 超时） | rc=1 | `error[TF01]` | `T?` 与用户 `Option[T]` 不再同一行（退役名字身份 = 设计使然）。旧态本身是挂死 因此 净效果 = 明确拒绝。零语料命中（全仓无 `T?`、无用户 `enum Option`）；交互面登记见 第 6 节-⑦ |
| T3 | p13 用户 `enum Result[T,E]`：`fn g(v: Result[int,string]) -> int { return v?; }` | rc=0（旧按名字解包取首个类型实参） | rc=1 | `error[TF01]` | 计划 Step 2 明令「废掉基名字符串」，结构解包只认 `TYP_OPTIONAL`；用户枚举不再按名字猜语义。零语料命中 |

硬门说明：本任务未新增任何硬错误门（`main.cr` 硬名单一行未动）；TM03 对可选域生效 = 既有门（Task 3 开出）接入新域，其零命中证据 = 第 4 节 全语料复跑（诊断码集合与 rc 逐档同）。计划 Global Constraints 的「先 report-only 再开门」由 Task 3 的空清单 + 本任务「域扩展不改门集合」的复跑共同承担。

### 3.2 放宽清单（旧拒绝或旧不可用变为新接受；7 条，即本能力的实施面）

| # | 用例 | 旧 | 新 | 说明 |
|---|---|---|---|---|
| L1 | p1 `fn g() -> int? { return 5; }` | rc=1 `TF01` | rc=0 | `T ⊆ T?`（判定点注入；spec 第 5.4 节） |
| L2 | p2 `fn g() -> int? { return None; }` | rc=1 `N01` | rc=0 | `null ⊆ T?` + `None` 可解析 |
| L3 | p3 `fn g() -> int? { return Some(1); }` | rc=1 `N01` | rc=0 | `Some` 可解析；`Some(1)` 的行 = `int?`（计划用例「Some(1) 满足 int?」） |
| L4 | p4 `x: int? = 5; x = 3;` | rc=1 `TA01` | rc=0 | 赋值位注入（`int ⊆ int ∪ null`） |
| L5 | p7 `fn f(v: int)` 来自 `int?` 实参 | rc=1 `N01` | rc=0 | 不是本批放宽（构造器可解析而已）；调用位点仍无检查（#20），见 第 6 节-⑧ |
| L6 | p12 `match x { Some(v) => v, None => 0 }` | rc=1 `N01` | rc=0 | 两臂覆盖 = 穷尽（可选域） |
| L7 | p14 用户 `enum Option[T]` + `x: int? = Some(5)` | rc=124（挂死） | rc=0 | 挂死根因修复见 第 6 节-① |

### 3.3 语义保持面（旧值和新值相同；负控）

| 用例 | 语义 | 旧值和新值 |
|---|---|---|
| p5 `fn f(x: int?) -> int { return x; }` | `T? ⊄ T`（方向性，soundness 面） | rc=1 `TF01`，仍为 rc=1 `TF01`（不变） |
| p6 `x: int? = 5; y: int = x;` | EXPR_LET 洞（#32；本批不动） | rc=0，仍为 rc=0（漏放面如实登记） |
| p10 `enum Result[T,E]` 返回位 TF01 | 与本批无关的既有站点 | rc=1，仍为 rc=1（不变） |
| p11 `match x { Some(v) => v }`（缺臂） | 拒绝面 | rc=1 `N01` 变为 rc=1 `TM03`（码变化＝构造器先可解析、随后穷尽性判缺 `None`；镜像见 第 4 节） |

---

## 4. 影子对拍门 + 全语料复跑（与站点覆盖同报）

运行器 = `/tmp/p3t0_run.sh`（72 档 = t1 `tests/suite` 32 + t2 自源 2 + t3 后端/kernel 15 + t4 stdlib 19 + t5 examples 4；逐档 `clean-cache`，cwd = 仓库根）。

- check 面（新二进制 × 新源，`/tmp/p3t4_check`）vs Task 3 末态日志（`/tmp/p3t3_final_check`）：全部 72 档的诊断码集合与 rc 逐档相同（脚本逐档比对 `error[CODE]` 多重集 + `.rc`，零差异）。仅 3 档（自源 `_import.cr`/`main.cr`/`ccr_io.cr`）有行号位移（本批新增 ~500 行源文件行 因此 既有 TF01 误报的定位行 9528 变为 9730 等；诊断内容/条数/码不变）。
- shadow 面（`/tmp/p3t4_shadow`）：`decisions=29687 agree=29687 old_stricter=0 old_looser=0 unknown=0 unknown_bridge=0 unknown_engine=0 unknown_engine_uncovered=0 unknown_engine_budget=0 replace_bridge=0 replace_unknown=0`；`agree == decisions` 通过、`sum(sites) == decisions` 通过；dump（逐档差异条目）与 Task 3 末态 `diff -r` 空（逐字节同）。shadow 日志仅 5 档自源有差（行号位移 + 判定数随新增源码行增加：Task 3 的 29442 增加到本批 29687，+245 = 新增行自身的判定），全为零计数。
- 站点覆盖（直方图）：`assign-node=22483 · fn-body-ret=5259 · if-branch=1911 · struct-field-type=28 · array-elem-type=4 · generic-apply-base=2`；站点 1（hotpatch-ret）/ 2（generic-arg）/ 4（unify-fallback）/ 6（assign-binary）语料零命中，站点 3 仅 2 次（同 P1/P2a/P2b/T0/T1/T3 口径）。
- 效力范围声明（同前批口径）：语料零 `T?`、零 `Some`/`None`（全仓 grep 实测）因此 本能力面语料零命中，零差异不是本任务正确性证据；正确性由 第 3 节 探针（14 例）+ 第 2 节 判据 2（16 例）+ 判据 3c（12 例）+ 第 5 节 突变控制承担。
- report-only 面：本批无新硬门（第 3.1 节 说明）因此 复跑的「诊断码集合/rc 逐档同」即「零命中」的直接证据。

---

## 5. `.ccr` 变更面实测（计划预期 = 变；TODO #26 口径 = 结构性断言 + 语义零变化）

结论：`.ccr` 变 = 纯「内建 Option 串退役」，STR 段恰少 10 字节（`"Option"`：4B 长度头 + 6B 载荷）+ 其后所有 STR 索引整体 −1 + 后续段偏移前移 10；段尺寸与结构零变化。

逐段实测（4 档语料，`/tmp/pa_base.ccr` 等；基线 = Task 1 树二进制，本面 Task 3 零改动）：

| 语料 | 总长 | STR | SYM | NOD | ENT | REG | EDG |
|---|---|---|---|---|---|---|---|
| ptr_arith | 88953 减为 88943 | 1565 减为 1555 | 6452（同尺寸，索引移位） | 46732（逐字节同） | 23020（逐字节同） | 2068（=） | 9028（=） |
| dyn_test | 119955 减为 119945 | 1931 减为 1921 | 9068（≠） | 62032（=） | 31980（=） | 2692（=） | 12164（=） |
| at_test_struct | 97577 减为 97567 | 1813 减为 1803 | 7140（≠） | 51520（≠，索引指向移位后条目） | 24952（=） | 2452（=） | 9612（=） |
| generics_test | 130614 减为 130604 | 2366 减为 2356 | 10072（≠） | 66892（≠） | 35116（=） | 2836（=） | 13244（=） |

- 每档恰 −10 字节（= `str_intern("Option")` 的唯一落点；退役前它在每次编译都入 `g_strs` 因此 这是计划预告的「行号/STR 段变化」的精确形态）。段尺寸（除 STR）逐档不变 因此 无结构变化。
- 语义零变化的判据：`test_ccr_v7.py` 27/27（结构性断言）+ ELF canary 逐字节同 + `suite` job（32 档 build+run）ALL PASS + 全语料 check 面一致（第 4 节）。

---

## 6. 突变控制（用例非真空性；复位后二进制逐字节复原）

增量法（M1、+M2、+M3、+M4，逐次重建；每步联合失败集与上一步之差 = 该突变的专一生效面）：

| # | 突变（临时，已复位） | 失败用例（增量） | hidden |
|---|---|---|---|
| M1 | `type_compat_strict` 可选目标注入失效 | selftest 278/279：`t4.sub_injection_asymmetry`；行为 9/12：`plain_value_into_optional` · `none_into_optional` · `none_flow_none_arm` | — |
| +M2 | 桥接 `TYP_OPTIONAL` 丢 null 析取支（`term = 内层`） | 增量 selftest 2：`t4.opt_term_is_union` · `t4.none_sub_optional`；增量行为 1：`optional_not_assignable_to_plain`（`T?` 塌回 `T` 因此 方向性失守被咬） | — |
| +M3 | `sh_variant_payload_at` 退回裸码列（旧布局语义） | 增量 selftest 2：`t4.payload_node_beats_bare_code` · `t4.payload_generic_subst`（T0 交接 ① 的判别力：码说 int、节点说 string 因此 只读码即失败） | 行为集无增量，`--verify-evp-nodes` 用例测的是入库（parser 写 + verify 函数），与本消费者不同层（如实登记） |
| +M4 | `ak_disjoint` 的 `AK_NULL` 公理失效 | 增量 selftest 1：`t4.ak_null_disjoint_table`（AK_NULL vs AK_NAMED 格） | 其余 null 面仍通过 = 尾部 `return 1` 覆盖，说明该例专咬公理表而非一般不相交 |
| — | 复位（4 处还原 + 重建） | 279/279 rc=0 + 行为 12/12 | `build/corec 9eb68846…` / `corearch 8c717d1e…` / `corelsp e85ce76a…` 三 sha 与突变前逐字节相同（构建确定性 + 复位完整） |

行为集反软诊断加固（M1 实测教训，已固化进测试）：本仓库多数类型诊断（TF01/TA01…）是软诊断，`build` 路径 rc=0 + 产物照出，只有 `check` 因「有诊断即 rc=1」暴露。M1 首轮实测：注入失效后 `plain_value_into_optional` 仍 PASS（只断 build+run rc 会全部通过）。因此 `case_dual` 已加第三路 `check` rc=0 断言（`test_optional.py` 文首注记），三路同证后才计 PASS。

---

## 7. 发现与登记（影响后续任务）

### ① `Some(x)` 实参链契约违反导致编译器挂死（既有缺陷，本批修复）
parser 的 `T_SOME` 分支（`parse_primary`）把值节点直接放 `b` 槽，而消费点（checker / ir_gen）按 EXPR_ARG 链遍历（`an := ast_b(node); ast_a(an); an = ast_b(an)`）因此 链读进值节点自身的 a/b 槽并按 `ast_b` 前行。实测：`enum Option[T]{None,Some(T)}` + `x: int? = Some(5)`，check 为 rc=124（30s 无输出）；`v := Some(3)`（同声明）能返回是巧合（节点 0 的 `b` 恰为负，链提前终止 因此 同一表达式两种命运）。修法 = 照通用枚举构造器分支（parser.cr:300-312）建 EXPR_ARG 链（并支持多实参）。零语料命中（全仓无 `Some(`），但任意用户代码可触发。

### ② T0 交接 ① 已办：枚举载荷类型节点列 + 唯一消费者 + 入库断言
- 布局：`OFF_EV_TYPE_NODES = 144`（每变体 16 槽 ×8B），`OFF_EV_SIZE` 从 144 改为 272、`ESZ_ENUMINFO` 从 2360 改为 4408；accessor `ei_variant_type_node`（dyn_arr.cr:417）。列不落 .ccr（v7 段布局不动；读回侧零写，见 ccr_io.cr:1133-1136 因此 消费者须以 `type_count` 为界，不得据 0 反推「节点 0」）。
- 消费者：`sh_variant_payload_term(ti, name_ni)`（单载荷 = 该载荷项 / 多载荷 = AK_PRODUCT 声明序 / tag 变体（0 载荷）返回 -1，语义域外登记：载荷为空 ≠ 载荷 unit，不发明「单点变体项」）；泛型形参按泛型应用行实参一层代入（照 `sh_struct_field_term`；嵌套代入属 F4 同族，TODO #21）。
- 入库断言通道：`--verify-evp-nodes`（默认关，与 `--verify-named-dedup` 同址同式），输出 `[enum-payload-verify] enums=E variants=V slots=S collapses=C bad=B`；`bad` = 载荷槽无节点数（>0 因此 rc=1），`collapses` = 裸码说 int 而节点不是 int 基型的槽数（T0 第 5 节-① 的仓库级量化，实测：`enum E { V(S), W(int) }` + `enum Opt[T]{N,Some(T)}` 因此 `slots=3 collapses=2 bad=0`）。
- 诚实偏差：协调者转述的前提是「payload 节点列是「`Some(1)` 满足 `int?`」的前提」。本实现的该用例走另一条路（内建 `Some` 的载荷类型 = 实参类型行，不查枚举表）因此 该用例不依赖节点列。节点列照办（T0 登记的缺口本身要修，且是 Task 5/6 泛型/impl 面的前提），但不声称它是本用例的前提。

### ③ 运行期表示未统一（未覆盖面登记，计划未列 ir_gen/后端 因此 不在本任务 Files 面）
`Some(1)`/`None` 的运行期形态沿用既有 `EXPR_ENUM_CONSTRUCTOR` 路径（`IR_MAKE_ENUM` 对象 + tag）；`T?` 槽里的裸值仍是裸值。两者在同一次 `match` 里各自正确（`test_optional.py` 的 `some_flow_some_arm`/`none_flow_none_arm` 双路径 rc=101/7 实测），但「`T?` 值表示统一」（裸 `5` 与 `Some(5)` 同值）未实现 因此 运行期对同一 `T?` 变量可能持两种表示（如 `x: int? = 5; match x { Some(v) => …, None => … }` 会走 `None` 臂）。属后续面（需 ir_gen/后端 + 表示决策），本任务如实登记、不谎称完整。

### ④ 暴露并修复既有崩溃面：`sym_*` 访问器 + bootstrap 不求值短路（T0 第 5 节-③ 根因仍开放）
退役内建 Option 注册后，「无类型声明的源文件」在 `collect_decls` 的函数注册循环处 `g_syms` 仍为 NULL（首个 `def_sym` 尚未发生，合法状态）；而 `checker.cr:1202` 的重复函数检查是 `existing_si >= 0 && sym_kind(existing_si)`，bootstrap 构建的二进制不求值短路（T0 第 5 节-③ 反汇编实证）因此 `sym_kind(-1)` 导致 `r64(NULL, 负偏移)`，最终 SIGSEGV（rc=139，实测 `fn main() -> int { return 0; }` 即崩）。修法 = `sym_name/sym_kind/sym_type/sym_node` 四读取器加范围检查（`n ∉ [0, g_sym_count)` 因此 -1；与类型表访问器同款）。合法读零变化、非法读不再崩。根因（bootstrap `ir_gen` 不分支化 `&&`/`||`）仍归 T0 第 5 节-③ 裁决，本批只关掉「符号表未分配」这一具体触发链。

### ⑤ 站点面子类型只对可选目标注入（范围与理由）
`type_compat_strict` 的 10 判定点仍是身份口径（`type_equal` ∧ 长度档）；新增的唯一放宽 = 目标 kind 为 `TYP_OPTIONAL` 时的 `ti_subsumes`（`T ⊆ T?` / `null ⊆ T?`），该 kind 只由 `T?` 产生、语料零命中 因此 既有接受/拒绝集合逐点不变（第 4 节 全语料 + shadow 全零计数为证）。为何不把 10 站点整体改子类型：那会重定义既有收纳（P2a/P2b 判据面 + 对拍基线），超出本任务授权。因此 连带面：`p5`（`T? ⊄ T`）在返回/赋值/字段/实参等站点已拒，但 EXPR_LET（#32）与调用实参（#20） 两个无检查站点仍可绕过（`p6`/`p7` 实测），修 #32/#20 时须一并复核方向性。

### ⑥ 枚举变体数 / 载荷数 >16 越界写（既有，新布局下影响变化，未修）
parser 写 `OFF_EI_VARIANTS + vc*OFF_EV_SIZE` 与 `+ OFF_EV_TYPES + tc*8` 时无上限检查（`MAX_ENUM_VARIANTS`/`MAX_VARIANT_TYPES` 仅被 `.ccr` 读回侧检查）因此 声明 17 变体或 17 载荷会越界写（旧布局踩下一个变体/计数字段，新布局同族）。当前零语料命中；修法照 TODO #8 先例（parser 硬错 P020 + 访问器护栏），建议专批（新硬门 因此 先 report-only）。

### ⑦ `T?` 与用户声明 `enum Option` 的交互（Task 3 第 6 节-⑥ 的交接面，本批裁决）
`T?` 与用户 `Option[T]` 不再同一行（退役名字身份）：混用处 T2（旧行为是挂死，新行为是 TF01）。零语料命中；若要「用户 Option 也满足 `T?`」，须把枚举域升级为载荷代入的联合项（= 载荷节点列的下一个消费者，属 Task 5/6 面），本批不动（Task 3 的变体身份语义已被 `unf.*`/`t3.*` 用例固定，改域形状 = 推翻其判定基线）。

### ⑧ TODO #32（协调者交办）已落：`EXPR_LET` 站点无任何兼容检查
含本批新增证据（`T?` 值经 EXPR_LET 不报错地流进窄槽 因此 `run rc=5`；同族调用位点 `run rc=8` = 指针值），并与 #20（F3 调用位点）互为姊妹面、给出统一修法建议（先 report-only）。

### ⑨ `T?` 行不去重 + 其他实现裁决
- `TYP_OPTIONAL` 每出现点分配一行（不进 `named_dedup`，本行无名字）；同内容两行在桥接侧译成同一项（`tt_norm`/DAG 去重）因此 判定等价（`t4.some_sub_optional` 钉）。代价 = 每 `T?` 一行 + 一次桥接缓存条目（可接受，登记）。
- `EXPR_TRY` 对 `TYP_NULL` 不解包（返回原行）：解包 null 应得空类型，而本层 `never` 行在引擎侧不是真 ⊥（`lit_implies` 按原子类判），判 never 会引入新的拒绝面 因此 保守不动（登记）。
- match 可选域的模式名只接裸名 `Some`/`None`（限定名 `Option.Some` 在可选域 因此 不可映射 因此 不判；用户枚举的限定名走枚举域那条路，互不干扰），保守方向登记。
- `Some`/`None` 分派是关键字名分派（lexer 的 T_SOME/T_NONE 仅由这两个词产出），用户同名变体经 `def_sym` 优先命中（Task 3 p20 语义保持，`test_match_exhaust.py` 16/16 为证）。

### ⑩ 未覆盖/未接线（如实清点）
`type_compat_sym`（hotpatch 站）无注入（两侧皆声明、无源/目标 因此 注入会让方向任意）；`iface_*` 对 `TYP_OPTIONAL`/`TYP_NULL` 行回 -1（无操作许可，门全拒，`+`/`if` 条件对可选值即报错，登记为保守面）；运行期表示（第 7 节-③）；枚举域升级（第 7 节-⑦）；`never ⊆ T?` 不给（引擎状态 quo：never 按普通原子判，登记）。

---

## 8. 过程诚实项

- 失败态未单独构建（同 T0/T1/T3 口径）：新符号（`sh_null_term`/`t4.*` 用例/EXPR_OPTIONAL 分支）此前全仓零定义（构建期 `Undefined name` 硬失败即失败）；用例非真空性由 第 6 节的 4 突变增量法承担。
- 旧二进制口径：本任务起点的树（Task 3 末）二进制未留档（被本批构建覆盖）因此 第 3 节 旧值用 Task 1 末树二进制；本批全部触及面 Task 3 未动（其报告 第 6 节-⑥ 自证），且 第 4 节的「check 面诊断码集合/rc 逐档同」给出跨树的独立交叉证据。
- `.ccr`/ELF 口径：ELF canary 逐字节同（clean-cache、cwd = 仓库根）；`.ccr` 变更面按计划「允许但须实测报告」逐段实测（第 5 节），未以「结构性断言」替代实测。
- 工作量口径：本批共 13 次自举构建（实现/调试 4 = 首版、崩溃修复、注入、自测用例；突变控制 5 次为 M1、+M2、+M3、+M4、复位；CI 期 4 = selfhost-tests / full-bootstrap / bootstrap-tests / suite 各自带重建）。所有 第 2 节 判据（除突变态）均适用于同一冻结二进制 `9eb68846…`（终态复位 + CI 重建后 sha 逐字节复原）。全程 `nice -n 19`、串行构建。
- 语料运行器/探针：非仓库文件（`/tmp/p3t0_run.sh` / `/tmp/p3t0_agg.py` 复用 + `/tmp/p3t4_probe/`、`/tmp/p3t4_ledger/`、`/tmp/p3t4_{check,shadow}/` 留档）；报告与 `docs/archive/sdd/` 其余报告一致不入提交。
- `test_optional.py` 的软/硬门口径：TF01/TF02 系在本仓库是软诊断（build rc=0 + 产物照出；硬名单只含 R002/TK05-06/TS01-04/TK02/TM03）因此 负例判据一律走 `check`（有诊断即 rc=1）+ 措辞断言；正例走 `check` rc=0 ∧ ELF rc=N ∧ interp rc=N 三路同证。

---

## 9. 提交

路径限定 14 文件 = `src/compiler/{ast,ccr_io,checker,dyn_arr,main,monomorph,parser,ty_shadow,type_engine,type_selftest}.cr` · `src/lsp/analysis.cr` · `src/ci/run.sh` · `TODO.md` · `tests/selfhost/test_optional.py`（新）；802 insertions / 52 deletions。
`monomorph.cr`/`lsp/analysis.cr` 两个文件超出计划 Task 4 的 Files 列，理由：新增 AST 节点（`EXPR_OPTIONAL`）的既有消费者必修（否则 monomorph 走后备克隆 `d` 槽 = 读进节点 0；LSP 类型显示落 `?`）。计划 Files 列的 5 文件全部在列。

---

## 10. 证据命令速查（可复核）

```bash
# 判据 2/3（用例表 279 + 三套件）
nice -n 19 ./build/corec selftest-types | tail -1
nice -n 19 python3 tests/selfhost/test_iface_ops.py | tail -1
nice -n 19 python3 tests/selfhost/test_match_exhaust.py | tail -1
nice -n 19 python3 tests/selfhost/test_optional.py | tail -1
# 判据 4/4b（ELF canary + .ccr；必须先 clean-cache、cwd = 仓库根）
nice -n 19 ./build/corec clean-cache && nice -n 19 ./build/corec build tests/suite/ptr_arith.cr -o /tmp/x --static && sha256sum /tmp/x
nice -n 19 ./build/corec clean-cache && nice -n 19 ./build/corec ccr tests/suite/ptr_arith.cr -o /tmp/y.ccr && sha256sum /tmp/y.ccr
# 载荷节点列入库断言（T0 交接 ①）
nice -n 19 ./build/corec check <含变体载荷的源>.cr --verify-evp-nodes    # 期望 bad=0
# 第 3 节 收紧/放宽清单（14 探针 × 旧/新）
cd /tmp/p3t4_ledger && for f in p1 p2 p3 p4 p5 p6 p7 p8 p9 p10 p11 p12 p13 p14; do
  nice -n 19 /tmp/p3t3_base_bin/corec check $f.cr >/dev/null 2>&1; echo "$f old rc=$?"
  nice -n 19 /home/DslsDZC/core/build/corec check $f.cr >/dev/null 2>&1; echo "$f new rc=$?"
done
# 第 4 节 全语料（check/shadow）
nice -n 19 bash /tmp/p3t0_run.sh check ./build/corec /tmp/p3t4_check
nice -n 19 bash /tmp/p3t0_run.sh shadow ./build/corec /tmp/p3t4_shadow && nice -n 19 python3 /tmp/p3t0_agg.py /tmp/p3t4_shadow
# 回归 + 自举链
nice -n 19 env CI_JOB_NAME=selfhost-tests bash src/ci/run.sh
nice -n 19 env CI_JOB_NAME=full-bootstrap bash src/ci/run.sh && cmp /tmp/corec2 /tmp/corec3
```
