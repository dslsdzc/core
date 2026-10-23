# R2 P3b Task 6 报告：impl 契约（签名类型项化、形状项逐成员判定、mangling 退役、覆盖集）

日期：2026-09-12。基线：`44100ba4`，P3b Task 2，工作副本起点，selftest-types 319/319。
任务：P3 计划 Task 6，Step 1 签名类型项化、Step 2 覆盖集、Step 3 满足判定接引擎和 mangling 退役、Step 4 判据、Step 5 提交。
报告口径：所有数字为本机实跑。命令使用 `nice -n 19`，cwd 为仓库根，clean-cache 先于任何 `.ccr` 或缓存态比较，一次构建一次编译串行。未跑的标为“未跑”。
旧二进制口径：`/tmp/p3b2_pre_mut_corec`，P3b Task 2 收尾构建 `44100ba4`，是上一版。另附 `/tmp/p3b_t0_base_bin/corec`，P3a 收尾 `aa54d26a`，pre-Task-0，作远端对照。

---

## 0. 交付摘要

| 项 | 结果 |
|---|---|
| Step 1 签名类型项化 | `g_ifaces` 方法条目新增类型节点槽：参数节点 8 个、返回节点、接收者模式。`ESZ_IFMETHOD` 从 88 变为 168，`ESZ_IFACEINFO` 从 1432 变为 2712。不进入 `.ccr` 序列化，实测逐字节相同。裸码槽保留（S6 值域），参数裸码槽零读者，已登记 |
| 上限 16 方法、8 参数 | 显式登记保留，单源常量 `MAX_IFACE_METHODS`/`MAX_IFACE_METHOD_PARAMS`。超限为硬错 rc=1，不是不报错地截断，新套件两例钉死。解除面为表迁侧表，按 B.4-7 口径 |
| Step 3 接引擎 | 形状项是方法集，即 fn 的 product，使用 `sh_iface_shape_term`。判定为逐成员包含：方法名在 `g_methods` 表查询，接收者模式显式比较，签名规范项用引擎结构比较原语 `tt_list_same` |
| mangling 退役 | `type_has_method`/`check_iface`/`check_impl_for`/泛型约束路径全部走 `iface_find_method`，零 `str_intern`。旧形态对缺失名会增长驻留表。泛型体内方法调用改为实例化查表解析，使用 `CALL_FLAG_IFACE_METHOD` 加 monomorph |
| 崩溃修复（同任务收益） | 泛型体内方法调用 `x.m()`（`fn f[T: I]`）旧态产物运行 rc=139，调用目标悬空；本批运行得到正确值，实测 7/9 |
| 两处裁决 | ① 用户轴保持结构口径，不采用 spec §2.3 的名义口径。采纳会翻转既有钉死用例 5 例以上，且属于语义争议，因此停下上报并登记。② 形状名字面仍不注册，零 `.ccr` STR 增长 |
| 收紧台账 | 4 条：参数类型命名型、返回类型命名型对原生、泛型应用实参、接收者模式。旧态 rc=0 零诊断，新态 rc=1 加 TG02。`test_iface_satisfies.py` 按台账改 1 例。放宽 0 |
| `.ccr` / ELF | 都逐字节相同：`ptr_arith` 88943B `54e3856b…`、`generics_test` 130974B `97be2f9e…`、ELF canary `95084e7b…d475`。类型层改动零泄漏到发射面 |
| 判据 | `selftest-types` 333/333（319 增加 14 个 `ifc.*`）；新套件 20/20，已挂 `run.sh`；六个套件全部通过；五个 CI job；更宽 selfhost 45/45 加 `test_backend_bootstrap` rc=0；同源对拍 72 档零差异；影子 30628/30628，全计数 0 |
| 突变控制 | 4 条逐条咬合：M1 应用展开、M2 接收者模式、M3b `tt_list_same` 换 `ty_sub`、M4 monomorph 解析。M4 只有行为级自测。复位后二进制逐字节复原 |
| 提交 | `e838f18b`，13 个文件，提交后工作副本干净 |

过程发现两条，如实登记。① CI `check` 作业在本批抓到自测夹具的不报错地类型错：`alloc` 返回 `string`，夹具却声明 `-> int`，Python bootstrap 侧没有报，自托管 checker 报 TF01。已修，缓冲参数改为 4 槽显式实参。② 正例需要双站点纪律：只走实例化点的正例在突变下空转，实测 MUT1 不咬合。因此全部正例补“实例化点注解加函数调用点”两个站点，这是 Task 0 M4 教训的复发面。

---

## 1. 交付面

### 1.1 Step 1：签名类型项化（`dyn_arr.cr` / `parser.cr`）

- 布局（`src/compiler/dyn_arr.cr`）：`ESZ_IFMETHOD` 从 88 变为 168，组成是 name(0)、param_count(8)、ret_ti(16)、param_types[8](24..87)、param_nodes[8](88..151)、ret_node(152)、self_mode(160)。`ESZ_IFACEINFO` 从 1432 变为 2712，即 24 加 16×168。
- 写点（`parser.cr` interface 分支）：参数类型节点随裸码并行写，照 struct/enum 的 code 加 node 双写先例。接收者槽（`self`/`&self`/`&mut self`）记 `OFF_IFM_SELF_MODE`，1/2/3，0 表示无接收者，照 `EXPR_PARAM` 的 `int_val` 约定，且无节点。无 `->` 时 `ret_node = -1`，这是哨兵，不用 0，因为节点 0 是合法下标。
- 保守项：裸码槽保留。`OFF_IFM_RET_TI` 的读者是 S6 站点，即泛型方法调用返回型映射，值域是映射层编码 `{INT..CHAR}`，P2b Task 6 已显式化钉住，不得改。`OFF_IFM_PARAM_TYPES` 从本批起零读者，登记为参数码面由节点取代，写入保留。
- `.ccr` 不变量：`g_ifaces` 和类型节点槽不进入 `.ccr` 序列化，ccr_io 全文件没有 `iface` 命中。本批零新增 `str_intern`，全部使用既有 ni 或行，因此 `.ccr` 逐字节相同，§5.3 有实测。

### 1.2 Step 3：满足判定接引擎和 mangling 退役

（a）签名规范项，`src/compiler/ty_shadow.cr`，唯一构造点。`sh_sig_term_of_ti` 把类型行转成身份规范形：序列 N 归 -1，N 不进入身份，与 P3a 不变量同源；泛型应用展开为“基名行（named_dedup 规范）加实参链”，`TYP_GENERIC_APPLY` 行不去重，直接桥接会把同型的两次出现判成不同节点；命名行按行，按名规范；指针 asp 不进入项；引用 mut 进入项；`dyn` 或未知返回 -1。配套函数有 `sh_sig_term_of_node`（节点到项，小于 0 为 unit）、`sh_iface_sig_param_term`/`_ret_term`/`sh_iface_self_mode`（接口侧）、`sh_func_sig_param_term`/`_ret_term`/`sh_func_self_mode`/`sh_func_sig_term`（impl 侧，从 AST 形参链前扫解析，形参节点不连续，照 `check_func`/`ir_gen` 同款扫描约定）、`sh_iface_shape_term`（接口到形状项，即 fn 的 product，成员 b 槽为方法名 ni）、`sh_shape_member_at`（按方法表索引取成员）。接收者槽用 unit 占位，模式另外比较。不为它造令牌原子的原因是令牌 b 槽在引擎类级比较下只看 a/c 两槽，不可见，模式 1/2/3 会互相判等，造成不报错地错误。

（b）判定，`src/compiler/type_engine.cr` 的 `iface_user_satisfies` 加 `iface_user_satisfies_ii`。对接口 I 的每个方法 m：① `iface_find_method(T 名, m 名)` 表查询，缺失返回 0，函数行缺失返回 -1 不判；② 接收者模式相等，不等返回 0；③ 形状成员 fn 项对比 impl fn 项，使用 `tt_list_same(tt_c(impl), tt_c(member))`，0/1 全域；链长不同即元数不符，自然落 0。`check_iface` 使用同一核心，判断 `== 1`，bool 面。`iface_satisfies` 轴 C 直接走 `iface_user_satisfies`，同源由构造保证。

（c）两处按实测重定，都有实证：

1. 整形状 `ty_sub` 路由不可用，`iface_satisfies` 轴 C 注释逐条落案。原因一：引擎对 `AK_NAMED` 不展开，P0 未覆盖面②，命名行实参与 product 形状做 `ty_sub` 恒为 -1，全部负例会不报错地降级为不判，不报错地通过面复活。原因二：`product` 的引擎比较是不变槽链结构相等，不是子集包含，方法集包含形状集（实现方带额外方法是常态）会被误拒。因此形状项作为签名实现方式，由逐成员判定消费。整形状 ty_sub 路由登记为未覆盖面。
2. 逐成员比较不得用 `ty_sub`。引擎在不变槽上把确定不同上抛为 -1，`tt_list_variance_at` 中 `tt_type_elem_same != 1` 会置 `g_ty_uncovered = 1` 并返回 -1。“确定不等为 0”的加强仍是登记面。直接消费会让签名不符退化为不判，不报错地通过面复活。首版实测 `isat.axis_c_ret_code` 得 -1，突变 M3b 全面实证，8 个自测和 3 个行为例失败。因此签名项采用规范形，同型恒同节点，异型恒异节点，引擎的结构比较原语 `tt_list_same` 是 0/1 全域且不计步，就是正确判据。

（d）mangling 退役，`checker.cr` / `monomorph.cr` / `ast.cr`。`type_has_method` 改为 `iface_find_method(...) >= 0`，使用表查询，不再 `str_intern("T.m")` 加 `find_func`。`check_impl_for` 逐参和返回比较也改签名项，诊断码和措辞逐字保留：`EC_TF_METHOD_NOT_FOUND`/`EC_TF_METHOD_ARG_CNT`/`EC_TF_METHOD_ARG_TYP`/`EC_TF_RETURN`；新增接收者模式面使用 `ARG_TYP` 措辞。泛型体内方法调用（`fn f[T: I]` 的 `x.m()`）旧态合成 `"T.m"` 串，克隆期文本替换是唯一替换通道，导致实例体调用目标悬空，产物运行 rc=139，build rc=0，旧二进制实测 -11。本批在调用点记 `data = 泛型形参名 ni` 加 `CALL_FLAG_IFACE_METHOD`（`ast.cr`），monomorph 的 `EXPR_CALL` 克隆分支按当前实例的具体类型查表解析，使用 `gen_lookup_subst` 加 `iface_find_method`，运行得到正确值。

### 1.3 Step 2：覆盖集（新建 `tests/selfhost/test_impl_iface.py`，20 例）

正向 7 例，双站点同证：实例化点 `Box[S]` 注解加函数调用点 `f(s)`。覆盖固有 impl、`impl I for T`、命名参数加命名返回、泛型应用实参、`&self`、固有方法不受影响、多接口隔离。

泛型体内方法调用运行面 2 例，check 和 ELF 两路，解释器面登记不覆盖。

反向 7 例：缺方法、参数数、参数类型（命名型）、返回类型（命名型对原生）、泛型应用实参、接收者模式、第二接口隔离。

错误例 1 例：未定义接口，报 `error[N01]`。登记面 1 例：原生实参不判。上限钉子 2 例：17 方法、9 参数，硬错且无产物。

---

## 2. 判据复验（逐条：命令与结果）

| 序号 | 判据 | 命令 | 结果 |
|---|---|---|---|
| 1 | 自举构建 | `nice -n 19 python3 build_selfhost_native.py` | rc=0；三个二进制守卫全过（`error[ = 0` / `undefined = 0`）。警告集没有逐条对拍，未跑，本批无同源基线日志，如实登记 |
| 2 | 类型引擎自测 | `nice -n 19 ./build/corec selftest-types` | 333/333。基线 319，增加 14 个 `ifc.*`，逐例见 §4.1 |
| 3 | 既有套件 | `test_iface_ops` / `test_iface_satisfies` / `test_xcut_iface` / `test_generic_constr` / `test_match_exhaust` / `test_optional` / `test_impl` / `test_type_engine` | 76/76、17/17、12/12、15/15、16/16、12/12、7/7、通过。`test_iface_satisfies` 按台账改 1 例，见 §4.2 |
| 3b | 新行为覆盖集 | `nice -n 19 python3 tests/selfhost/test_impl_iface.py` | 20/20。使用真实 parser 输入和真实 CLI，已挂 `src/ci/run.sh` 的 selfhost-tests |
| 4 | ELF canary | `clean-cache`，然后 `build tests/suite/ptr_arith.cr --static`，再 `sha256sum` | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`，IDENTICAL。构建后和最终重建后各一次 |
| 4b | `.ccr` 面（TODO #26） | `clean-cache`，然后 `ccr`，再检查尺寸和 sha256 | `ptr_arith` 88943B `54e3856b383301be5daecaf61f75ce120e56ef4d1569c3008009fc368b750df9`；`generics_test` 130974B `97be2f9e7431fde54de99e29394903a431aeafa591159c900e0175dfa064c8b1`。与 Task 2 基线逐字节相同，接口零序列化，零新 `str_intern` |
| 5 | 全语料收紧/放宽台账 | 72 档，`/tmp/p3t0_run.sh check`，旧二进制 `44100ba4` 和新二进制 | check 面 `diff -r` 零差异，0 行；rc 分布 33 个 0、39 个 1，两侧相同。语料零命中，没有接口、`T: I` 或应用签名 |
| 6 | 影子对拍门 | 72 档 `--type-shadow --type-shadow-dump` 加聚合 | 新加新 30628/30628，全计数 0；旧加新同值；dump 目录 `diff -r` 空；站点覆盖同报，见 §5.4 |
| 7 | 全回归 | 五个 CI job 加更宽 selfhost 枚举 45 档加 `test_backend_bootstrap` | 见 §2.1/§2.2 |
| 8 | 突变控制 | 4 条注入加复位核 sha | 逐条咬合，复位后 `build/corec`/`corearch` 逐字节复原，见 §6 |

### 2.1 五个 CI job（逐 job rc 和要点）

| job | rc | 要点 |
|---|---|---|
| `selfhost-tests` | 0 | 21 档，本批新挂 `test_impl_iface.py`，尾部 20/20；`test_iface_satisfies` 17/17 |
| `bootstrap-tests` | 0 | 3/3 |
| `suite` | 0 | tests/suite 全部通过 |
| `full-bootstrap` | 0 | 三阶段加冒烟，`corec2 == corec3` IDENTICAL，`--help` rc=1 为既有约定 |
| `check` | 1 | 自源 `check src/compiler` 是既有 red 划界：恰好 2 条 TF01 误报（`lits_copy` / `ty_memo_slot_no_grow`）。本作业本轮抓到并促成本批修复：新夹具 `ts_ifc_pnodes` 的 `alloc` 返回 `string`，却声明 `-> int`，是真类型错 TF01。缓冲参数改为 4 槽显式实参后，复跑回到 2 条 |

### 2.2 更宽 selfhost 枚举（45 档，44 个既有加新套件，#31 缺口口径）

`for f in tests/selfhost/*.py; do nice -n 19 python3 $f; done` 得到 45/45 rc=0。要点档：`test_compile` 通过、`test_purity` 通过、`test_ccr_v7` rc=0、`test_backend_bootstrap` rc=0（附录 B.6 必含档）、`test_lsp` rc=0、`test_type_engine` 通过（333 例通道）、`test_impl_iface` 20/20。

---

## 3. 语义和三态纪律

- 满足判定是集合包含的逐成员实现。接口形状项（方法集）是实现方式，判定逐成员做方法名表查询、接收者模式比较、签名项结构相等。0 表示可证违反：缺方法、模式不符、元数不符、签名项不同。1 表示满足，包括零方法接口的空洞满足。-1 表示不判：T 不是命名行、表内不一致（函数行缺失）、接口形状项不可建（签名节点缺失、参数数越域）、impl 签名项不可建（变参、`dyn`、未知 kind）。
- -1 没有被任何消费方当作 0 或 1 使用。实例化点只有 `== 0` 才发 TG02；函数调用点经 `check_iface` 的 `== 1` 维持既有 bool 语义，措辞、去重、rc 逐字未动。
- 签名身份沿用 P3a 既有不变量。N（数组长度）不进入签名身份，`[int;3]` 与 `[int;4]` 判等，长度面由常量档 `array_len_constraint_ok` 承担，selftest `ifc.sig_len_not_in_identity` 钉死。命名行使用名义，同名字同行，`ifc.sig_named_nominal_not_structural` 证明同构异名的两个 struct 不可互换。泛型应用按基名加实参链，`ifc.sig_apply_arg_bound`。
- 接收者模式 1/2/3 是判定维度，属于调用约定而非类型集，因此不进入项，两侧显式比较，`ifc.sig_receiver_mode` 中 2 与 1/3 都得到 0。
- 预算：签名判定路径不计步，`tt_list_same` 不是预算路径。`iface_satisfies` 的预算隔离照 Task 0，轴 A/B/C 各入口前后 `ty_budget_reset`，未动；selftest `isat.three_state_budget_isolated` 仍然通过。
- 零 `str_intern`：判定、查表、形状建项路径全部使用既有 ni。`isat.no_str_intern_on_missing` 和新例 `ifc.mangling_zero_str_intern` 证明缺失方法路径 delta 为 0。

---

## 4. 用例和台账

### 4.1 selftest 新增（`ifc.*` 14 例，319 到 333）

签名四维：`ifc.sig_named_param_bound`（命名参数型同型 1、异型 0）、`ifc.sig_named_ret_bound`（命名返回对原生得到 0）、`ifc.sig_apply_arg_bound`（`IfcBox[IfcA]` 与 `IfcBox[IfcB]` 得到 0）、`ifc.sig_receiver_mode`（iface `&self` 对 impl `self`/`&mut self` 得到 0）、`ifc.sig_arity_chain`（链长）、`ifc.sig_len_not_in_identity`（N 不进入身份得到 1）、`ifc.sig_named_nominal_not_structural`（名义非结构）。

形状项三面：`ifc.shape_product_of_fn`（成员数、成员 b 槽为方法名、链长为 1 加参数数、越界得到 -1）、`ifc.shape_empty_product`（零方法得到空 product 链）、`ifc.shape_build_unjudged`（参数数越域得到 -1）。

其余四例：`ifc.mangling_zero_str_intern`、`ifc.type_has_method_table`（表查询面）、`ifc.check_iface_same_source`（bool 面与三态面 1 侧逐例相等）、`ifc.three_state_unjudged`（非命名行、未知接口名、负键得到 -1）。

既有用例按实测重定一处：`x2.iface_shape_term_unexpanded` 改为 `x2.iface_shape_term_built`。从 Task 6 起接口形状项可建：零方法得到空 product，大于等于 0；未声明接口名得到 -1；命名行加零方法得到空洞满足 1，原生行得到 -1。旧标签的“恒为 -1”理由已经失效；旧断言实际是“把 iface 索引当名字 ni 传入”的偶然通过面，一并修正。

### 4.2 收紧台账（旧到新和处置；旧为 `44100ba4` 构建的 `./build/corec`，逐例实测）

| 用例（`test_impl_iface.py`） | 旧 | 新 | 说明 |
|---|---|---|---|
| `neg_named_param_type_mismatch` | check rc=0 零诊断 | rc=1 加 `error[TG02]` 加“does not satisfy interface 'Show'” | 参数类型参与判定；旧态裸码塌缩，不可比 |
| `neg_named_ret_vs_native` | rc=0 零诊断，编码面判为满足 | rc=1 加 TG02 | 返回型按类型项，取代编码相等 |
| `neg_apply_arg_mismatch` | rc=0 零诊断 | rc=1 加 TG02 | 泛型应用实参，规范形展开后可比 |
| `neg_receiver_mode_mismatch` | rc=0 零诊断 | rc=1 加 TG02 | 接收者模式；旧态两侧都是码 0，不可比 |
| `test_iface_satisfies.py::inst_encoding_limit_named_ret_pinned` | rc=0 零诊断 | 按台账改为 `inst_encoding_limit_named_ret_rejected`，rc=1 加 TG02 | 同一返回型面的既有钉，Task 0 登记“解锁等于 Task 6 Step 1” |
| 修复面，非收紧：`pos_generic_body_call_inherent` / `_impl_for` | build rc=0，产物运行 rc=139 | build rc=0，运行 rc=7 / rc=9 | 泛型体内方法调用，mangling 退役的收益；旧态实例体调用目标悬空 |

旧二进制对照，本套件整体：`COREC_BIN=/tmp/p3b2_pre_mut_corec` 得到 14/20，4 条签名收紧加 2 条崩溃；`COREC_BIN=/tmp/p3b_t0_base_bin/corec`（P3a 收尾，pre-Task-0）得到 11/20，另含 Task 0 已关闭的缺方法、元数、返回码面。

放宽为 0 条。新硬门无。TG02 是软诊断，check rc=1，build rc=0 且产物照出，与既有约束检查同门同码；计划 Global Constraints 第 6 条的 report-only 前置没有被触发。

### 4.3 行为探针（真实 parser 输入；T3/T0 假绿教训）

- 正例双站点：每个正例同时包含 `Box[S]` 注解（实例化点）和 `f(s)` 调用（函数调用点）。MUT1 实证：只有实例化点的正例在应用展开被撤销时不咬合，应用行两侧节点不同，实例化点得到 -1，零动作；补站点后即失败。该纪律已写进源形注释。
- 崩溃面：`pos_generic_body_call_*` 以产物运行 rc 7/9 为判据，旧二进制为 -11/139。
- 解释器面登记：`corec run` 的解析面不支持方法调用语句，旧二进制同样 rc=1，不是本批引入。因此这 2 例走 check 加 ELF，其余正例三路同证。

---

## 5. 零行为变化证据

### 5.1 同源对拍（最强形式）

旧二进制（`44100ba4` 构建）加新源，对比新二进制加新源，72 档逐档 `clean-cache`：

- check：`diff -r` 日志目录 rc=0，0 行差异。rc、诊断码、逐条消息含行号全部相等。rc 分布 33 个 0、39 个 1，两侧相同。
- shadow：两轮聚合同值，30628/30628，全计数 0；dump 目录 `diff -r` rc=0。

### 5.2 语料和自源零命中

本批全部新判定面，包括接口签名、形状、接收者模式、泛型体内方法调用，在 72 档语料中零命中。全仓没有 `interface`、`impl I for T`、`T: I` 的生产用法，interface 只出现在测试内联源。自源 `check src/compiler` 只有既有 2 条 TF01 误报，见 §2.1。

### 5.3 `.ccr` 和 ELF

- ELF canary `95084e7b…d475`，IDENTICAL，clean-cache，最终重建后复验。
- `.ccr`：`ptr_arith` 和 `generics_test` 与 Task 2 基线逐字节相同，分别为 88943B 和 130974B。本批零 `.ccr` 变更，关键设计点是接口条目不进入序列化，且零新 `str_intern`。

### 5.4 影子对拍门（数字和站点覆盖同报）

| 口径 | decisions | agree | old_stricter | old_looser | unknown* | replace_* |
|---|---|---|---|---|---|---|
| 基线（Task 2 收尾） | 30400 | 30400 | 0 | 0 | 全 0 | 全 0 |
| 本批（新二进制加本批源） | 30628 | 30628 | 0 | 0 | 全 0 | 全 0 |
| 旧二进制加本批源（归因对照） | 30628 | 30628 | 0 | 0 | 全 0 | 全 0 |

增加 228 的精确归因，新旧两轮同值，属于纯源面：`assign-node` 从 22982 到 23150，增加 168；`fn-body-ret` 从 5407 到 5464，增加 57；`if-branch` 从 1977 到 1980，增加 3。这些是本批新增源码自身的站点，不是语义变化，旧二进制跑同一新源得到完全相同的数。

站点覆盖，本批：`assign-node=23150`、`fn-body-ret=5464`、`if-branch=1980`、`struct-field-type=28`、`array-elem-type=4`、`generic-apply-base=2`；`assign-binary`、`generic-arg`、`hotpatch-ret`、`unify-fallback` 仍零命中，与 P3a/T0/T2 同。`sum(sites) == decisions` 成立，`agree == decisions` 成立，全计数 0。

声明，继承：影子通道只覆盖 `type_equal` 站点；本批判定面 `iface_satisfies` 和签名项比较不在其站点集内。因此影子零差异是必要条件，不是充分证据。满足判定面的证据是 §4.1 用例、§4.3 行为探针、§5.1 同源对拍。另登记：接口签名比较经 `type_equal` 类的判定，在含接口的源上会被影子计入上一站点；本批语料零接口，判据不受影响，站点命名面归 P5。

---

## 6. 突变控制（咬合和复位逐字节复原）

方法：注入，运行 `build_selfhost_native.py`，观察预测的用例失败，复位，重建，比对 sha。

| 序号 | 注入 | 结果（逐条实测） |
|---|---|---|
| M1 | `sh_sig_term_of_ti` 的泛型应用分支改回“不展开”，`tt_atom(AK_NAMED, ti, -1)` | selftest 2 个失败：`ifc.sig_apply_arg_bound`、`ifc.sig_named_nominal_not_structural`；行为面 1 个失败：`pos_apply_signature_accepted`，同型签名被误拒，属于正例方向，补双站点后才咬合，见 §4.3。结果 331/333 加 19/20 |
| M2 | `iface_user_satisfies_ii` 删除接收者模式检查 | selftest 1 个失败：`ifc.sig_receiver_mode`；行为面 1 个失败：`neg_receiver_mode_mismatch`，不报错地通过面复活。结果 332/333 加 19/20 |
| M3b | 逐成员比较改 `ty_sub` 且上抛 -1，真实缺陷形态 | selftest 8 个失败：`isat.axis_c_ret_code`、`isat.predicate_same_as_check_iface`、`ifc.sig_named_param_bound`、`ifc.sig_named_ret_bound`、`ifc.sig_apply_arg_bound`、`ifc.sig_arity_chain`、`ifc.sig_named_nominal_not_structural`、`ifc.check_iface_same_source`；行为面 3 个失败：`neg_named_param_type_mismatch`、`neg_named_ret_vs_native`、`neg_apply_arg_mismatch`，全部是不报错地通过面复活。结果 325/333 加 17/20。M3 首版把 -1 折成 0，不咬合，因为与正确实现同判，后来改为上抛 -1。记录：突变必须对准真实缺陷形态，否则是空转 |
| M4 | monomorph 的 `CALL_FLAG_IFACE_METHOD` 解析分支失效 | 行为面 2 个失败：`pos_generic_body_call_inherent` / `_impl_for`，ELF rc=-11，即旧态 139；selftest 全绿。该面只有行为级自测，登记，不是用例空白。结果 333/333 加 18/20 |
| 复位核验 | 还原四个文件后重建 | `build/corec` 为 `9a583215af8397cc…`，`build/corearch` 为 `599ee27553899b5d…`，与注入前逐字节相同；333/333 加 20/20 |

---

## 7. 裁决、登记面和未覆盖面（交后续批）

1. 裁决①：用户轴口径采用结构（方法集包含），不采用 spec §2.3 的名义口径（`impl I for T` 声明即满足）。采纳会翻转既有钉死用例，包括 `test_generic_constr.py::iface_constr_legacy_pass`、`test_iface_satisfies.py` 的固有 impl 正例等 5 例以上，且属于语言设计语义，spec §0 裁决 6 要求语义争议停下上报。名义化是维护者裁决项，登记 TODO #38。如果采纳，落点是 `g_impl_for` 边查询，表已在，零新数据面，台账是上述 5 例以上翻转。
2. 裁决②：形状名字面仍不注册，Task 2 登记项延续。接口形状项按接口自身名 ni 建，parser 已驻留，因此零新串、零 `.ccr` STR 增长；命名消费语法（`T: 可索引`）仍待裁。
3. 整形状 `ty_sub` 路由不可用，登记，不是漏放，见 §1.2c。两条实测理由；形状项作为签名实现方式消费。
4. 上限保留：`MAX_IFACE_METHODS=16`、`MAX_IFACE_METHOD_PARAMS=8`，硬错护栏在库，新钉子用例。解除方式是方法表迁侧表，全部读点换位，按 B.4-7“先加护栏、再评估解除”。
5. 接口泛型形参（`interface I[T]`）仍被 parser 丢弃，这是既有事实。含形参行的签名匹配只在同一声明内成立，使用行号身份。
6. 签名面未覆盖面：`dyn` 位图行不进入规范形，返回 -1；变参签名不可表达，返回 -1；泛型形参行跨声明不同行；变型规则（`&T` 协变等）不在签名面，现状是结构相等，需要时另裁。
7. 参数裸码槽零读者，写入保留，登记；S6 返回码槽必须保留，P2b 已钉住值域。
8. 解释器面：`corec run` 不支持方法调用语句，旧二进制相同，不是本批引入。泛型体内方法调用两例走 check 加 ELF；`ir_gen` 和解释器的这一面是独立条目。
9. 泛型方法调用解析失败后备：形参未绑定、嵌套形参（`T := U`）、具体类型没有此方法时，保持原状，不发明目标。登记，同族是约束“不判”面的既有缺口。
10. 名义口径若采纳的连带面：`g_impl_for` 目前只在 `impl I for T` 写入，固有 impl 形态（`impl S { … }`）不登记。名义化会把“固有 impl 加 `T: I`”整类判为不满足，这正是裁决①的翻转清单。
11. 性能面，A.3-⑩ 口径：接口判定面在全语料零命中，没有实测耗时证据，未跑基准。判定路径 `tt_list_same` 不计步，形状建项为 O(方法数) 且 DAG 哈希合并，没有热路径风险面登记。

---

## 8. 计划覆盖自检

| 来源 | 要求 | 状态 |
|---|---|---|
| Task 6 Step 1 | 签名类型项化（节点解析；上限解除或显式登记） | 已完成，见 §1.1，节点槽加裸码保留加上限显式登记 |
| Task 6 Step 2 | 覆盖集至少 10 例（双向、多接口、泛型约束交互、错误例、固有方法） | 已完成，20 例，包含双站点纪律和上限钉子 |
| Task 6 Step 3 | 判定接引擎、mangling 退役、泛型约束路径同步 | 已完成，见 §1.2，两处按实测重定并登记，崩溃修复 |
| Task 6 Step 4 | 判据（自测阈值、套件、影子、回归、canary、`.ccr`） | 已完成，见 §2：333/333、20/20、canary 和 `.ccr` 同、影子全计数 0、五个 job、45/45 |
| Task 6 Step 5 | 提交（路径限定） | 已完成，`e838f18b`，13 个文件 |
| Global Constraints | jj only、路径限定、nice、clean-cache、`.ccr` 和 ELF 判据、三态、收紧台账、硬门 report-only | 全部遵守；没有新硬门，TG02 是软诊断 |
| 附录 B.1（交接点 3） | Task 6 Step 1 是形状项前提；`check_iface`/`check_impl_for`/mangling | 已交付，B.1 ③ 注已更新 |
| 附录 B.6 | 每任务回归面必须包含 `test_backend_bootstrap.py`，或者先挂 CI | rc=0，见 §2.2；已记录“清单双注册面”教训，本批未动任何 `build_selfhost_native.py` 或 `_import.cr` 清单 |

---

## 9. 改动清单和文档面

| 文件 | 变更 |
|---|---|
| `src/compiler/dyn_arr.cr` | 方法条目新增节点、返回节点、接收者模式槽（`ESZ_IFMETHOD` 88 到 168，`ESZ_IFACEINFO` 1432 到 2712），加 `MAX_IFACE_METHODS`（16，单源常量） |
| `src/compiler/parser.cr` | interface 分支写节点槽、接收者模式、返回节点（-1 哨兵）；上限判断改单源常量 |
| `src/compiler/ast.cr` | `CALL_FLAG_IFACE_METHOD = 4`，泛型体内接口方法调用标记 |
| `src/compiler/ty_shadow.cr` | 签名规范项构造：`sh_sig_term_of_ti/of_node`、接口侧和 impl 侧取项、`sh_func_sig_term`、`sh_iface_shape_term`、`sh_shape_member_at` |
| `src/compiler/type_engine.cr` | 轴 C 重写（`iface_user_satisfies` 加同源核心 `iface_user_satisfies_ii`）；轴 A/C 注释落案，记录整形状路由不可用的两条实测理由 |
| `src/compiler/checker.cr` | `type_has_method`/`check_iface` 改为表查询；`check_impl_for` 签名项化；泛型约束方法调用路径改标记位 |
| `src/compiler/monomorph.cr` | `EXPR_CALL` 克隆分支：接口方法调用按具体类型查表解析 |
| `src/compiler/type_selftest.cr` | `ifc.*` 14 例加夹具（真实 `EXPR_FN` 和节点）；`x2.iface_shape_term_unexpanded` 改为 `_built` |
| `tests/selfhost/test_impl_iface.py` | 新建，20 例 |
| `tests/selfhost/test_iface_satisfies.py` | 按台账改 1 例（`..._pinned` 改为 `..._rejected`），头注“覆盖边界”更新 |
| `src/ci/run.sh` | 挂新套件，selftest 例数从 319 改为 333 |
| `docs/superpowers/plans/2026-09-11-r2-p3-capabilities.md` | Task 6 五个 Step 勾选和交付/重定注；状态表行；附录 B.1 ③ 更新 |
| `TODO.md` | 新增 #38，记录本批实施、两处裁决、台账、未覆盖面、关联 |

`jj diff --stat -r e838f18b`：13 个文件，+1158 / −126，源码 9 个、测试 2 个、`run.sh`、计划/TODO。

---

## 10. 证据命令速查（可复核）

```bash
# 构建 / 自测 / 套件
nice -n 19 python3 build_selfhost_native.py                    # rc=0
nice -n 19 ./build/corec selftest-types | tail -1              # 333/333
nice -n 19 python3 tests/selfhost/test_impl_iface.py | tail -1 # 20/20
COREC_BIN=/tmp/p3b2_pre_mut_corec nice -n 19 python3 tests/selfhost/test_impl_iface.py | tail -1  # 14/20（台账「旧」）
# ELF canary + .ccr（先 clean-cache、cwd = 仓库根）
nice -n 19 ./build/corec clean-cache && nice -n 19 ./build/corec build tests/suite/ptr_arith.cr -o /tmp/x --static && sha256sum /tmp/x
# 语料 + 影子（复用 P3a/T0 运行器）
nice -n 19 bash /tmp/p3t0_run.sh check ./build/corec /tmp/n && nice -n 19 bash /tmp/p3t0_run.sh check /tmp/p3b2_pre_mut_corec /tmp/o && diff -r /tmp/o/logs /tmp/n/logs
nice -n 19 bash /tmp/p3t0_run.sh shadow ./build/corec /tmp/s && nice -n 19 python3 /tmp/p3t0_agg.py /tmp/s
# 五 CI job + 更宽枚举
for j in selfhost-tests bootstrap-tests suite full-bootstrap check; do nice -n 19 env CI_JOB_NAME=$j bash src/ci/run.sh; echo "$j rc=$?"; done
for f in tests/selfhost/*.py; do nice -n 19 python3 $f >/dev/null 2>&1 || echo "FAIL $f"; done   # 45/45
```

---

## 11. 提交和文档

- 提交，路径限定：`e838f18b`，信息为 `feat: R2 P3b Task 6——impl 契约（签名类型项化 + 形状项逐成员判定 + mangling 退役）+ 覆盖集`。base 为 `44100ba4`，13 个文件，提交后工作副本干净。
- 本报告 `docs/archive/sdd/p3b-task6-report.md` 是未跟踪面，与 P3a/P3b 各报告同口径，不入提交。
- 计划 Task 6：五个 Step 勾选、交付/重定注、状态表行、附录 B.1 ③；TODO #38 是本批实施条目。
- 可复核的中间产物在本机 `/tmp/p3b6/`：`build*.log` 构建链、`new_check2`/`old2_newsrc_check` 同源对拍、`new_shadow2`/`old2_shadow` 影子两轮、`ci2_*.log` 五个 job、`wider.txt` 45 档、`mut{1,2,3b,4}_build.log` 突变、`pre_mut_sha.txt` 复位基线、`impl_iface_{old,task2bin}.out` 台账对照、`probes/` 探针源。
