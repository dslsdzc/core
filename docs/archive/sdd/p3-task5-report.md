# R2 P3 Task 5 报告：泛型约束的保留、实例化判定、monomorph 类型项化（P3a 半边交付，P3b 半边登记阻塞）

状态：DONE_WITH_CONCERNS。判据全部通过。核心关切有四项：① `T: I`（用户接口）的满足判定按计划归 P3b（`iface_satisfies` 未交付），因此本批的结构和枚举实例化点对接口约束一律不判（零诊断），只交付本质轴（原生类型和已声明类型名约束）判定；② 覆盖面上有两处硬限制，引擎 `AK_NAMED` 不展开，导致命名实参对原生约束不判，引擎 `AK_NEVER` 是原子而不是 ⊥，导致 `never` 不满足原生约束，两项如实登记；③ `MAX_GENERICS=4` 未解除，按计划二选一，见第 0 节第 ② 条和第 7 节第 ④ 条；④ `build_selfhost_native.py` 有一处清单变更，`monomorph.cr` 迁出 corearch，零引用证据见第 0 节第 ③ 条。
提交：见第 9 节，路径限定 12 个文件。
计划：`docs/superpowers/plans/2026-09-11-r2-p3-capabilities.md` Task 5（P3a 主，P3b 半）。
起点：`c8c7731b`（P3 Task 4 末提交，工作副本干净，`selftest-types` 279/279）。
范围口径：Step 1 修复 F4 形参链，Step 2 保留结构和枚举泛型约束，Step 3 把实例化判定引擎化（本质轴），Step 4 把 monomorph 实例键类型项化，Step 5 判据和覆盖集。未做的是 P3b 登记项：`T: I` 的用户接口满足判定，走 `iface_satisfies`。

---

## 0. 实施前须定的三处（计划决策点和本批新增裁决）

### ① `T: I` 的 P3a/P3b 边界（计划 Task 5 Step 3 原文的直接实施）

计划原文是：“`T: I` 检查 = `ty_sub(实参项, 约束项)`。约束为类型项；本质轴形状用引擎，用户接口形状待 P2b 的 `iface_satisfies`，因此本步本质轴部分 P3a 可做，用户接口部分 P3b。”

实施形态是 `gen_constr_satisfied(c_ni, arg_ti)` 三态：
- 约束名 `find_iface(c_ni) >= 0`（用户接口）时返回 -1（不判）。形状项构造 `sh_iface_shape_term` 是 Task 0 占位，恒为 -1，满足判定需要 `iface_satisfies`，尚未交付，见附录 A.3-①。
- 否则约束名按类型解析，原生八名 `int/dex/bool/string/char/unit/never/dyn` 逐名判断，符号表 `SYM_TYPE` 包括 struct、enum、别名、泛型形参，然后计算 `ty_sub(sh_term_of_ti(arg), sh_term_of_ti(约束行))`。
- 函数调用点的接口约束回落到既有 `check_iface` 名拼接路径，逐字未动，`test_iface_ops.py` 的 `t6_S6_*` 和 `test_impl.py` 零回归。

因此三态纪律是：-1 既不当 0（拒绝），也不当 1（放行）。行为用 `test_generic_constr.py::struct_iface_constr_unjudged` 钉死：结构加接口约束加不满足的实参，结果为零诊断。

### ② `MAX_GENERICS = 4`：选择显式登记（计划 Step 5 二选一）

实测：超过 4 个泛型形参时，现状是 parse 期硬报。`fn f[A,B,C,D,E](…)` 报 `error[P01] expected type after '->'` 加 `error[TA08] unknown declaration tag 'd'`；`struct G[A,B,C,D,E]` 同理。这不是不报错地截断，`parse_generics_into` 在 `gc >= MAX_GENERICS` 时 break，剩余形参被当普通语句解析，因此报错。
语料实测：全仓最大泛型实参是 2（`tests/suite/generics_test.cr` 的 `pair[A, B]`；struct 侧是 `struct Box[T]`）。
解除代价（实测读码）：struct/enum 表的 `OFF_SI_GENERIC_NAMES`/`OFF_EI_GENERIC_NAMES` 各恰好 4 槽（400..431 / 4368..4399，其后紧邻 count）。解除需要修改 `ESZ_STRUCTINFO`/`ESZ_ENUMINFO`，这是布局变更，会触及 `ccr_io` 零写槽和全部 `OFF_*` 使用者，还要改 `parse_generics_into` 的硬编码 4 槽和两张新侧表的索引空间。语料零命中，收益为零，成本不能接受，因此登记为单开项（TODO #33 登记②）。

### ③ `monomorph.cr` 从 corearch 清单迁出（计划外文件变更，附零引用证据）

动因：本批给 `monomorph.cr` 增加的类型项化函数需要类型表读取器和节点合成（`get_type_kind`/`get_type_data`/`get_type_extra` 在 `checker.cr`，`alloc_node` 在 `parser.cr`）。corearch 清单不含这两层，直接构建会失败，实测报 `Errors: ['Undefined name: get_type_kind', …]` 共 63 条。
证据：用脚本逐符号核对 corearch 链接集 31+19 个文件。`monomorph.cr` 的全部定义符（`gen_*`/`grow_gen_*`/`g_*`）在 corearch 链接集内只出现在 `globals.cr` 的注释里，零代码引用。因此该文件在 corearch 是死码。单态化本来就是前端 `ir_gen` 期的动作，后端消费的是已经特化的 `.ccr`。
安全面：ELF canary 逐字节相同（第 2 节判据 4），全套回归（判据 7）和自举链（判据 8）分别验证 corearch 行为不变。唯一产物面影响是 corearch 二进制不再包含这段死码。

---

## 1. 交付物和落点（file:line，全部实测）

| 交付物 | 落点 |
|---|---|
| 修复 F4 形参链导航（前扫到下一个 EXPR_PARAM） | `checker.cr` 的 `infer_gen_call`（形参循环尾部；同款先例在 `ir_gen.cr` 三处） |
| 约束名转类型行（原生八名加符号表类型） | `checker.cr` 的 `gen_constr_type_ti` |
| 本质轴三态判定（`ty_sub` 加预算隔离） | `checker.cr` 的 `gen_constr_satisfied` |
| 反例文本（`tt_witness` 转文本，零 str_intern） | `checker.cr` 的 `gen_constr_witness_str` / `ty_shadow.cr` 的 `tt_display`/`tt_display_at` |
| 约束违反诊断（TG02 加约束名加反例） | `checker.cr` 的 `gen_constr_raise` |
| 诊断去重侧表（16B 每条，{node*MAX_GENERICS+gi, 1}） | `checker.cr` 的 `gen_constr_seen_init/probe/rehash/add/reset` 加 `globals.cr` 的 `g_constr_seen*` |
| 实例化点检查（结构和枚举；`res_type_node` 加 `res_call_type` 双入口） | `checker.cr` 的 `gen_inst_constr_check` |
| 函数调用点本质轴判定，回落既有 check_iface | `checker.cr` 的 `infer_gen_call` 约束循环 |
| 调用点绑定登记（块为 [count, ti…]；节点 iv 为起始加 1） | `checker.cr` 的 `infer_gen_call` 尾部；表为 `globals.cr` 的 `g_gen_binds*` |
| 结构和枚举约束保留（空槽预填 -1） | `parser.cr` 的 `save_struct_gen_constrs`/`save_enum_gen_constrs`（struct/enum 分支改传真实缓冲） |
| 侧表增长和读取护栏 | `dyn_arr.cr` 的 `grow_sgen_constr`/`grow_egen_constr`/`grow_gen_binds`/`si_gen_constr`/`ei_gen_constr` |
| 实例键规范结构名（类型行转文本，项内用 "|"，长度用 ";"） | `monomorph.cr` 的 `inst_key_of_ti` |
| 类型行转类型语法节点（单槽根约束） | `monomorph.cr` 的 `inst_type_node_of_ti` |
| ti 型替换（实例化）和全具体前置 | `monomorph.cr` 的 `gen_build_subst_tis`/`gen_lookup_subst_ti`/`gen_subst_ti`/`inst_ti_concrete` |
| 克隆期嵌套调用点绑定重映射 | `monomorph.cr` 的 `gen_remap_binds`（`gen_clone_tree` 的 EXPR_CALL 分支） |
| 克隆 EXPR_IDENT 的 ti 路径优先 | `monomorph.cr` 的 `gen_clone_tree`（EXPR_IDENT 分支） |
| 带绑定的查和建入口 | `monomorph.cr` 的 `gen_find_or_create_bind` 加 `gen_create_instance(func, args, bstart)` |
| 调用点建键（checker 绑定优先，旧名串回落） | `ir_gen.cr` 泛型派发段（旧路径逐字保留） |
| 新自测 9 例（t5.*，279 到 288） | `type_selftest.cr` 的 `ts_t5_run()`（独立函数，见第 8 节诚实项①） |
| 行为覆盖集 14 例（三路同证、负例、实例名） | `tests/selfhost/test_generic_constr.py`（新） |
| CI 挂钩和计数同步（279 到 288） | `src/ci/run.sh` |
| TODO：#21 划销（F4），新增 #33（本任务实施、阻塞、未覆盖、死码登记） | `TODO.md` |
| 清单：`monomorph.cr` 迁到 corec（见第 0 节第 ③ 条） | `build_selfhost_native.py` |

---

## 2. 判据（命令和结果）

| # | 判据 | 命令 | 结果 |
|---|---|---|---|
| 1 | 自举构建 | `nice -n 19 python3 build_selfhost_native.py` | rc=0；三守卫全部 clean（`error[ = 0, undefined = 0`） |
| 2 | 自测用例表 | `nice -n 19 ./build/corec selftest-types` | 288/288（基线 279，增加 9 例，零 FAIL） |
| 3 | 三套件 | `test_iface_ops` / `test_match_exhaust` / `test_optional` | 76/76、16/16、12/12 |
| 3b | 姊妹套件 | `test_impl` 7/7、`test_ccr_v7` 27/27、`test_generic_constr`（本批）14/14 | 全部通过 |
| 4 | ELF canary 逐字节 | `clean-cache`，然后 `build tests/suite/ptr_arith.cr --static`，再 sha256 | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475` IDENTICAL |
| 5 | 收紧和放宽清单加全语料 | 第 3 节（16 个探针对旧新二进制），第 4 节（72 档同源对拍） | 收紧 3 条，放宽 1 条，语义保持加实例名变化 6 条；语料零新增诊断 |
| 6 | 影子对拍门 | 72 档 `--type-shadow --type-shadow-dump` | 第 4 节：`decisions=30338 agree=30338`，全部计数为 0，dump 与 T4 逐字节相同，站点直方图同前批 |
| 7 | 全回归 | CI `selfhost-tests` / `suite` / `bootstrap-tests` / `full-bootstrap` | rc=0，4 项（suite 32 档 build 和 run ALL PASS；bootstrap 3/3） |
| 8 | 自举链 | CI `full-bootstrap` 加 N06 加冒烟 | `corec2 == corec3` IDENTICAL（2,404,414 B），N06=0，冒烟 `run 'fn main()->int{return 42;}'` 得到 42（corec 和 corec2 双通道） |
| 9 | 突变控制 | 第 6 节（4 个突变，用例咬合，复位） | 逐条咬合（selftest 和行为各有专属失败例）；复位后二进制逐字节复原（`d78f49aa…`），构建确定性（连续构建同 sha） |
| 10 | `.ccr` 变更面 | 第 5 节（ptr_arith / generics_test 逐段） | `ptr_arith` 逐字节相同；`generics_test` 增加 370B，恰好是一个额外实例（反折叠） |

冻结二进制（交付）：`corec ae9215df…`、`corearch 9230da6c…`、`corelsp 748250bb…`。
既存 red 划界（不是本批引入）：`CI_JOB_NAME=check`（`check src/compiler`）仍报 2 条 TF01 误报（`lits_copy` / `ty_memo_slot_no_grow`，`ty_shadow.cr:118` 记载的 loop 落空既有误报，TODO #8 已划界）。本批新代码曾引入第 3 条（`tt_display_at` 的 if 链混类型，报 `error[TC02]`），已修（AK_NAMED 提前返回加链内统一赋值），修后 check 作业恢复为恰好 2 条既存误报。

---

## 3. 行为台账（16 个探针对旧新二进制；探针目录 `/tmp/p3t5_ledger/`，脚本 `battery.sh`）

旧二进制口径是 `/tmp/p3t5_base_bin/corec`，等于 T4 末冻结的 `9eb68846…`，起点就是本批父提交的产物。逐例记录 `check rc[诊断码] / build rc / run rc / .ccr 实例名`。

### 3.1 收紧清单（旧接受变为新拒绝或新诊断，3 条）

| # | 探针 | 旧 | 新 | 成因和处置 |
|---|---|---|---|---|
| T1 | p04 `struct Box[T: int]` 加 `Box[string]` | `chk=0`，零诊断，约束被丢弃 | `chk=1`，`error[TG02]` 加 `counterexample: string ∩ ¬int` | Step 2 和 3 的直接目的：保留结构泛型约束并在实例化点判定。语料零命中（全仓没有约束语法） |
| T2 | p05 `enum EBox[T: int]` 加 `EBox[string]` | `chk=0`，原因相同 | `chk=1`，`error[TG02]` | 枚举侧同源，使用同一个 `gen_inst_constr_check` |
| T3 | p02 `fn f[T: int](a: T) -> T` 以 `f("s")` 调用 | `chk=1`，只有 TF01（返回值流入 int 的既有误用） | `chk=1`，增加 TG02，诊断码集合扩张 | 函数调用点本质轴判定。旧态约束被 `check_iface` 路径吞掉，`find_iface("int")` 为 -1，因此没有动作。rc 不变，不是硬门变化 |

硬门说明：本任务没有新增任何硬错误门（`main.cr` 硬名单一行未动）。TG02 是软诊断（`check` rc=1，`build` rc=0 且产物照出），与既有约束检查同门同码。计划 Global Constraints 的“新硬错误先 report-only”规则没有被触发。`test_generic_constr.py` 的负例一律走 `check` 加措辞断言。

### 3.2 放宽清单（旧拒绝变为新接受，1 条）

| # | 探针 | 旧 | 新 | 说明 |
|---|---|---|---|---|
| L1 | p09 `fn take[T](n: int, a: T) -> T` 加 `take(1, 2)`（前面放置 `fn foo(s: string)`，使 AST 节点 0 不是该泛型形参的 ident） | `chk=1`，TF01，属于假拒：T 未绑定，调用返回型回落到声明裸码 | `chk=0`，实例名从 `take[int,int]` 变为 `take[int]` | F4 修复的正确性正控。修复前后续形参的 pattern 落在类型节点上（`ast_data = 0`，`res_call_type(0)` 读 AST 节点 0），该形参的声明类型被绕过，未绑定形参被凭空绑定。行为例 `f4_later_param_binds_correctly` 钉住 |

### 3.3 语义保持面（rc 全同）加实例名变化（E 面，6 条，全部是键更忠实）

| # | 探针 | 旧实例名 | 新实例名 | 语义 |
|---|---|---|---|---|
| S1 | p11 两个不同 struct 实参调用同一泛型 | `f[unit]`（1 份，发生折叠） | `f[A]` 加 `f[B]` | 旧态“非原生实参一律后备 int/unit”，异型共用一实例。计划 Step 4 要求实证的折叠缺陷，本批实测确认并修 |
| S2 | p12 `fn id[T](x: T) -> T` 加 struct S 实参 | `id[unit]` | `id[S]` | 键包含命名真身份 |
| S3 | p13 嵌套泛型（`outer[U]` 体内调用 `inner[T]`） | `inner[int]` 加 `outer[unit]` | `inner[A]` 加 `outer[A]` | 克隆期绑定重映射（`gen_remap_binds`）生效的直接证据：嵌套调用的实参身份贯通 |
| S4 | p10 `fn take[T](n: int, a: T)` 加 `take(1,"s")` | `take[int,string]`（位置串，T 被错绑 int） | `take[string]`（按形参声明序的真绑定） | 键来源从实参位置序改为泛型形参序 |
| S5 | p06 `fn f[T: Show]` 加满足约束的 S（既有接口路径） | `f[unit]` | `f[S]` | rc 相同（0） |
| S6 | p14 元组实参 | `f[int]` | `f[int]` | 未覆盖面：复合实参没有语法形态，回落旧名串路径（登记第 7 节第 ③ 条） |

语义零变化的反向证据（rc 和产物面）：S1 到 S6 的 `chk/bld/run` 逐例同值；`ptr_arith` 的 ELF 和 `.ccr` 逐字节相同；suite 32 档 build 和 run ALL PASS。

---

## 4. 影子对拍门和全语料（与站点覆盖同报）

- 同源对拍（判据 5 的最强形式）：旧二进制配当前源，对比新二进制配当前源（72 档，逐档 `clean-cache`，cwd 为仓库根），0 档差异（rc、诊断码、逐条消息含行号全部相等）。因此本批在全语料上零新增诊断、零消失诊断、零 rc 变化。
- 影子面（`/tmp/p3t5_shadow2`）：`decisions=30338 agree=30338 old_stricter=0 old_looser=0 unknown=0 unknown_bridge=0 unknown_engine=0 unknown_engine_uncovered=0 unknown_engine_budget=0 replace_bridge=0 replace_unknown=0`；`agree == decisions` 成立，`sum(sites) == decisions` 成立；dump 与 T4 逐字节相同（`diff -r` 为空）。
  - 判定数从 29,687（T4）变为 30,338，增加 651。语料包含编译器自源（t2/t3/t4 档），本批新增源码行自身产生判定，与 T4 的 +245 口径相同。
- 站点覆盖（直方图）：`assign-node=22947 · fn-body-ret=5386 · if-branch=1971 · struct-field-type=28 · array-elem-type=4 · generic-apply-base=2`。站点 1（hotpatch-ret）、2（generic-arg）、4（unify-fallback）、6（assign-binary）在语料中零命中，站点 3 只有 2 次（与 P1/P2a/P2b/T0 到 T4 口径相同）。
- 效力范围声明：语料中没有泛型约束语法（全仓 grep 只有 `tests/selfhost/test_iface_ops.py` 的 3 处内联源有 `T: Show`，未进入语料 runner 的文件集）。因此本能力面在语料中零命中，上表的零差异不是本任务正确性证据。正确性由第 3 节探针、第 2 节判据 2（9 例）、判据 3b（14 例）和第 6 节突变控制承担。

---

## 5. `.ccr` 变更面实测（计划预期为变；TODO #26 口径为结构性断言加语义零变化）

结论：`ptr_arith`（没有语料泛型）逐字节相同，`54e3856b…`；`generics_test`（有泛型）增加 370B，唯一差异是实例折叠消失。逐段实测如下：

| 语料 | 总长 | STR | SYM | NOD | ENT | REG | EDG |
|---|---|---|---|---|---|---|---|
| ptr_arith | 88943（相同） | 1555（相同） | 6452（相同） | 46732（相同） | 23020（相同） | 2068（相同） | 9028（相同） |
| generics_test | 130604 变为 130974 | 2356 变为 2366 | 10072 变为 10128 | 66892 变为 67072 | 35116 变为 35200 | 2836 变为 2860 | 13244 变为 13260 |
| dyn_test / at_test_struct | 相同 | 相同 | 相同 | 相同 | 相同 | 相同 | 相同 |

- 字符串面唯一差异（`strings` 排序对比）：`get_val[unit]`（旧折叠名）变为 `get_val[int]` 加 `get_val[string]`（新，两个实例）。这就是第 3 节 S1 的折叠缺陷在真实套件语料上的体现，`unit` 串随之消失。
- 段增量（STR +10、SYM +56、NOD +180、ENT +84、REG +24、EDG +16）与“恰好多一个函数实例”自洽（函数记录加其节点、边、注册表项），没有结构变化（没有段新增或消失，没有非预期的段尺寸变化）。
- 结构性判据：`test_ccr_v7.py` 27/27，suite 32 档 build 和 run ALL PASS，ELF canary 逐字节相同，自举链 `corec2==corec3`。

---

## 6. 突变控制（用例非真空性，复位后二进制逐字节复原）

逐条注入，重建，收集失败集，复位。复位时逐文件核验源码 sha256，并确认重建二进制与注入前逐字节相同。

| # | 突变（临时，已复位） | selftest 新增失败例 | 行为套件新增失败例 |
|---|---|---|---|
| M1 | `infer_gen_call` 形参导航退回 `pn = pn + 1`（F4 旧态） | `t5.f4_later_param_declared_type`（got 0 want 1） | `f4_later_param_binds_correctly`（check rc=1，假拒复活） |
| M2 | `gen_constr_satisfied` 恒返回 -1（本质轴判定失效） | `t5.constr_essence_three_state`、`t5.inst_check_dedup_and_controls` | `func_essence_constr_violated`（缺 TG02）、`struct_inst_constr_violated`、`enum_inst_constr_violated`（不报错地通过面复活） |
| M3 | `ir_gen` 泛型派发强制走旧名串路径（实例键类型项化失效） | 无（selftest 走 monomorph 层，不经过 ir_gen 派发，如实登记覆盖面边界） | `mono_two_struct_instances`（缺 `f[A]`） |
| M4 | `save_struct_gen_constrs`/`save_enum_gen_constrs` 空转（约束保留失效） | `t5.constr_side_table_readback`、`t5.inst_check_dedup_and_controls` | `struct_inst_constr_violated`、`enum_inst_constr_violated` |
| 无 | 复位（4 处还原加重建） | 288/288 rc=0 | 14/14 |

- 字节复原判据：M3 注入后 `corec 064d4503…`，复位重建后 `corec d78f49aa…`，等于注入前 sha，并且与另一次独立重建同 sha，说明构建具有确定性。
- M1 附带观察：旧导航下，selftest 夹具在失败例之后继续执行会 rc=139。旧代码把 `ast_data` 读成 0 后，`res_call_type(0)` 依赖“节点 0 恰好是类型节点”的偶然性，在夹具布局下越界。这正是被修掉的类，不是新问题。

---

## 7. 发现和登记（影响后续任务）

### ① P3b 阻塞面（本批显式不判，不得当成“不满足”）

`T: I`（I 是 `interface` 名）的满足判定必须走 P2b 注册表的 `iface_satisfies`，该接口未交付（P3 计划附录 A.3-①；Task 2/6 同样阻塞）。本批处理：结构和枚举实例化点返回 -1，零动作；函数调用点回落到既有 `check_iface`（名拼接加参数数加裸码返回型比较，逐字未动）。接线点已经就位：`gen_constr_satisfied` 的首分支把 `find_iface >= 0` 判为 -1，等 `iface_satisfies` 交付后改这一处加 `sh_iface_shape_term` 即可全覆盖，包括函数侧回落路径的替换。

### ② 缺陷修复（本批引入并自灭）：稀疏侧表零初值等于合法名字 ni

`g_sgen_constr`/`g_egen_constr` 是稀疏写的，只写有约束的槽，而缓冲零初值。因此表高水位区内“本行未写过的槽”会读出 0，而 0 是合法的名字 ni（首个驻留串）。读取方 `c_ni >= 0` 会把空槽当成有效约束名，拿首个驻留串去查接口或类型表，凭空产生约束。修法是 `save_*_gen_constrs` 先把整行（MAX_GENERICS 槽）填 -1。selftest `t5.constr_side_table_readback` 和突变 M4 钉死。同族提示：`save_func_gen_constrs`（既有，函数侧）同样零初值稀疏写，其唯一读者 `infer_gen_call` 用 `iface_ni >= 0` 判有效，同一风险在函数侧也存在。本批未改，因为函数侧约束面不在 Task 5 的 P3a 半边内，改动会触及既有 `test_iface_ops` 基线。登记为单开项。

### ③ 未覆盖面（显式登记，逐条实测）

- 命名实参对原生约束返回 -1，不判：`struct Box[T: int]` 加 `Box[S]`（S 是 struct），引擎 `AK_NAMED` 不展开（P0 未覆盖面②，`lit_implies` 的 NAMED 分支返回 -1），零诊断。行为例 `struct_inst_named_arg_unjudged` 把“不判”钉住，这不是漏放，`Box[string]` 这类可判的仍然拒绝。
- `never` 不满足原生约束：引擎 `AK_NEVER` 是与 `AK_INT` 互斥的原子，不是 ⊥，因此 `gen_constr_satisfied(int, never) == 0`。这是既有语义（T4 第 7 节第 ⑨ 条“never 行在引擎侧不是真 ⊥”），本批如实钉住，不动引擎。
- 约束名既不是类型也不是接口时不判（`unknown_constr_name_unjudged`）：包括拼写错误的约束名不报错地通过（`T: NoSuchThing` 零诊断）。这是保守方向，登记在案。如果要升为诊断，必须先 report-only（新诊断面）。
- 复合实参（元组、嵌套应用）没有语法形态，实例键走行号后备（`#<row>`），替换回落名字路径。p14 实测 `f[int]` 与旧态同值。根因是 `inst_type_node_of_ti` 的单槽根契约（`EXPR_GENERIC_APPLY` 的实参根节点必须连续，parser 侧靠“子树的根恒为该子树最后分配的节点”自然成立，合成侧不成立），加上元组类型没有语法形态。
- ti 型替换不覆盖实例形参：`gen_clone_tree` 的 `EXPR_FN` 分支不克隆形参（形参类型由 `fi_param_type` 的裸码承担），替换只作用于函数体内节点。selftest `t5.inst_ti_subst_in_clone` 已按此范围断言，判据落在 body 上的形参位。
- `inst_key_of_ti` 对未知 kind 用行号后备：同一编译期内确定，跨行同型不去重，登记。
- `gen_remap_binds` 的“全具体”前置：克隆期嵌套绑定如果替换后仍含泛型形参行，整段放弃，回落旧名串路径，不发明半解实例。

### ④ 死码登记

`ir_gen.cr` 的 `find_or_create_mono_func` 零调用者（全仓 grep 实测）。它读取调用节点 `int_val` 的旧语义（等于首个绑定类型名，`infer_gen_call` 旧写入点）已经被本批改写为“绑定段起始加 1（0 表示无）”。如果该函数将来复活，必须先改，否则会错读绑定段下标，不报错地得到错误实例。本次未删，因为不在 Task 5 Files 面，删除须同步 `ast_set_int_val` 的语义迁移说明。

### ⑤ `MAX_GENERICS = 4` 未解除（选择显式登记，理由见第 0 节第 ② 条）

触发条件是语料出现超过 4 个形参（当前最大 2）。解除面是 `ESZ_STRUCTINFO`/`ESZ_ENUMINFO` 加 `parse_generics_into` 硬编码 4 槽加 `ccr_io` 零写槽。已写入 TODO #33 登记②。

### ⑥ 清单变更（`monomorph.cr` 迁出 corearch，见第 0 节第 ③ 条）

零引用证据来自脚本逐符号核对，不是 grep 直觉。本批未改其他清单项。

---

## 8. 过程诚实项

- `ts_t5_run` 拆成独立函数不是风格偏好：t5 段 9 例包含 40 多个局部变量，内联进 `type_selftest_run` 会在 Python bootstrap 的栈式代码生成下越界。实测内联版 `selftest-types` SIGSEGV rc=139，gdb 定位 `ts_t5_run+1849` 是调试打印读 NULL 表；去掉该打印后仍在同一区域崩溃。拆为独立函数后正常。调用方用 `total = total + 9` 同步用例数，注释标明“增删用例两处一起改”。
  - 诚实修正：首次定位把崩溃归因于 `add_func`（gdb 帧 `if_merge_670` 看起来像 str_len 调用点），实际是本实例给 `add_func` 传了 interned 索引而不是字符串。`add_func(name: string, …)` 接收的是 `tok_lx` 的字符串，parser 同样。修正后本组用例全部通过。“帧名不等于根因”是同 T4 的教训。
- 红态未单独构建（同 T0/T1/T3/T4 口径）：新符号（`gen_constr_*`/`inst_key_of_ti`/`ts_t5_run`/t5 用例）此前全仓零定义，构建期会因 `Undefined name` 硬失败，即红态。用例非真空性由第 6 节的四个突变承担。
- 旧二进制口径：本批起点（T4 末）二进制未留档，被本批构建覆盖。第 3 节使用 `/tmp/p3t5_base_bin/corec`，等于 T4 末冻结 sha `9eb68846…`，与 T4 报告第 2 节冻结值逐字节相同，因此是该面真实前置态。
- `.ccr` 和 ELF 口径：ELF canary 逐字节相同（clean-cache，cwd 为仓库根）。`.ccr` 变更面按计划“允许但须实测报告”逐段实测（第 5 节），没有用结构性断言替代实测。
- 工作量口径：本批约 20 次自举构建。实现和调试 12 次（首版、三元运算符语法、清单迁移、约束接线、打包、自测用例 4 轮、`tt_display` TC02 修复）；突变控制 6 次（M1、复位、M2 到 M4、复位加确定性复建）；CI 期 4 次（selfhost/suite/bootstrap/full-bootstrap 各自带重建）。除突变态外，全部判据适用于同一冻结二进制 `ae9215df…`。全程 `nice -n 19`，串行构建。
- 语料运行器和探针不是仓库文件（复用 `/tmp/p3t0_run.sh` 和 `/tmp/p3t0_agg.py`，另留档 `/tmp/p3t5_{probe,ledger,ccr,mut,shadow2,new_check3,old_check3}`）。报告与 `docs/archive/sdd/` 的其他报告一致，不入提交。
- `test_generic_constr.py` 的软硬门口径：TF01/TG02 是软诊断（build rc=0 且产物照出），负例一律走 `check`（有诊断即 rc=1）加措辞断言。正例走 `check` rc=0 且 ELF rc=N 且 interp rc=N，三路同证（固化 T4 的 M1 教训）。
- `test_generic_constr.py` 的正例源形受既有语义约束（新旧实测一致）：泛型体内 `return a`（a 为 T）对具体返回型（`-> int`）恒报 TF01，这是既有面。因此正例写 `-> T`，注释标明。

---

## 9. 提交

路径限定 12 个文件：`src/compiler/{checker,dyn_arr,globals,ir_gen,monomorph,parser,type_selftest,ty_shadow}.cr`、`tests/selfhost/test_generic_constr.py`（新）、`src/ci/run.sh`、`TODO.md`、`build_selfhost_native.py`。
`build_selfhost_native.py` 超出计划 Files 列，是第 0 节第 ③ 条的清单迁移。`globals.cr`/`dyn_arr.cr` 也超出，是新侧表及其增长和护栏函数的既定落点。`globals.cr` 是跨文件变量可见性的硬要求，checker 在 dyn_arr 之后仍可使用，反之不行。

---

## 10. 证据命令速查（可复核）

```bash
# 判据 2/3（用例表 288 + 四套件）
nice -n 19 ./build/corec selftest-types | tail -1
nice -n 19 python3 tests/selfhost/test_generic_constr.py | tail -1
nice -n 19 python3 tests/selfhost/test_iface_ops.py | tail -1
nice -n 19 python3 tests/selfhost/test_match_exhaust.py | tail -1
nice -n 19 python3 tests/selfhost/test_optional.py | tail -1
# 判据 4/10（ELF canary + .ccr；必须先 clean-cache、cwd = 仓库根）
nice -n 19 ./build/corec clean-cache && nice -n 19 ./build/corec build tests/suite/ptr_arith.cr -o /tmp/x --static && sha256sum /tmp/x
nice -n 19 ./build/corec clean-cache && nice -n 19 ./build/corec ccr tests/suite/generics_test.cr -o /tmp/y.ccr && strings -n 2 /tmp/y.ccr | grep -E '^get_val\['
# 第3 台账（16 探针 × 旧/新：check rc / build rc / run rc / 实例名）
nice -n 19 bash /tmp/p3t5_ledger/battery.sh
# 第4 全语料（同源对拍）+ 影子
nice -n 19 bash /tmp/p3t0_run.sh check ./build/corec /tmp/c3 && nice -n 19 bash /tmp/p3t0_run.sh check /tmp/p3t5_base_bin/corec /tmp/o3
nice -n 19 bash /tmp/p3t0_run.sh shadow ./build/corec /tmp/s3 && nice -n 19 python3 /tmp/p3t0_agg.py /tmp/s3
# 第6 突变控制（逐条：注入 到 重建 到 收集 到 复位 到 核 sha）
python3 /tmp/p3t5_mut/mutate.py M1 && nice -n 19 python3 build_selfhost_native.py
# 回归 + 自举链
nice -n 19 env CI_JOB_NAME=selfhost-tests bash src/ci/run.sh
nice -n 19 env CI_JOB_NAME=full-bootstrap bash src/ci/run.sh && cmp /tmp/corec2 /tmp/corec3
```

---

## 11. 计划覆盖自检（Task 5 Step 1 到 5 逐条）

| Step | 要求 | 状态 |
|---|---|---|
| 1 | F4 同族复核（TODO #21）：形参链导航修复，正负控各一 | 修复完成，加 `t5.f4_later_param_declared_type`/`t5.f4_bind_seg_recorded`，加行为正控 `f4_later_param_binds_correctly` 和负控 `f4_later_param_type_mismatch`，加突变 M1 |
| 2 | 结构和枚举泛型约束不再丢（登记到侧表，索引空间分家） | 完成。`g_sgen_constr`/`g_egen_constr` 与函数侧使用不同缓冲，索引空间分家，空槽预填 -1（第 7 节第 ② 条） |
| 3 | 实例化判定引擎化：`ty_sub(实参项, 约束项)` 加非空反例，-1 不当 0 | 本质轴全部实施（`gen_constr_satisfied`/`gen_constr_witness_str`）；用户接口部分作为 P3b 登记（第 7 节第 ① 条） |
| 4 | monomorph 类型项化：键为类型项结构（含真身份），替换升级，去重正确性探针（两个 struct 得到两个实例） | 完成。`inst_key_of_ti`（规范结构名）/`inst_type_node_of_ti` 加 ti 替换加嵌套重映射；探针是 p11（`f[unit]` 变为 `f[A]` 加 `f[B]`）、generics_test `.ccr` 实测、`mono_two_struct_instances` |
| 5 | 判据：至少 137 个 selftest（本树口径 279 到至少 287），MAX_GENERICS 二选一，行为探针，影子，全回归，ELF，`.ccr` 实测，自举链 | 完成。288（增加 9）；MAX_GENERICS 选择登记（第 0 节第 ② 条）；全部判据见第 2 节 |
