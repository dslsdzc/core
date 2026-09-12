# R2 P3（能力落地）实施计划：定长退役 + 序列接口/长度约束 + 穷尽性/联合/可选 + 泛型约束 + impl 契约

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 P0/P1/P2a 建成的「类型项层 + 语义包含引擎 + 判定接线」从**判定替换**推进到**能力落地**——五项目标能力（定长退役、序列接口/长度约束、穷尽性/联合/可选、泛型约束、impl 契约）各自在引擎/桥接/checker 三层接通，每项带正负控、边界例与不变量双钉。

**Architecture:** 三条主线：① **引擎展开层**（Task 0：named/struct/enum/generic-apply → 结构项；**仅**服务满足判定与域查询，等价判定保持原子名义）——它是穷尽性/联合/可选/泛型约束/impl 四项的共同前提，也是 P2a 登记的「P5 引擎命名展开」前移；② **不依赖 P2b 的能力**（Task 1 定长/变型、Task 3 穷尽性、Task 4 联合/可选、Task 5 的非接口半边）= **P3a**；③ **依赖 P2b 注册表的接口面**（Task 2 横切接口、Task 6 impl 契约、Task 5 的 `T: I` 满足半边）= **P3b**（P2b 计划落地后接，接口契约见下节）。

**Tech Stack:** Core 自举栈。`src/compiler/type_terms.cr`（类型项 DAG）· `type_engine.cr`（三态判定）· `ty_shadow.cr`（ti→term 桥接 + 10 站点 + 计数）· `checker.cr`（判定点/公理区/泛型/接口）· `monomorph.cr`（实例化）· `ir_gen.cr`（表示层读 N 的两处）。判据通道：`corec selftest-types`、`--type-shadow`、`tests/selfhost/test_type_engine.py`。

**Spec:** `docs/superpowers/specs/2026-09-10-type-interface-unification-design.md` §5（能力落点：§5.1 定长/序列/长度约束、§5.2 泛型、§5.3 impl、§5.4 穷尽性/联合/可选）+ §1/§2（语义基座/双轴注册表）+ §9 P3 行；方向定案 `docs/superpowers/specs/2026-08-30-type-system-direction-design.md` 条目 8；定长裁决 `docs/superpowers/specs/2026-09-10-language-surface-narrowing-design.md` §1 + TODO.md `fixed-array-retire`（TODO.md:446）。**前置状态（已实测，非本计划目标）**：P0 引擎 + **95 例**（`selftest-types` 95/95）；P1 影子（开/关两态产物逐字节同）；P2a 判定替换（`type_equal` → `ty_equiv`）+ 语料对拍归零。

## Global Constraints

- **jj only（禁 git 含只读/复合）**；**提交路径限定**；所有命令 `nice -n 19`；判据前 `clean-cache`、cwd = 仓库根（比较任何 `.ccr`/缓存态产物前必须 clean-cache——TODO #5 末条/#26）。
- **ELF canary 本计划全任务预期不变**：`clean-cache` → `build tests/suite/ptr_arith.cr --static -o /tmp/…` → sha256 `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`（即 `/tmp/r1t4_base_bin`）。**任一任务 ELF 变 → 停下上报**（类型层改动泄进发射面）。⚠ canary 语料（`tests/suite/ptr_arith.cr`：一个数组字面量 + 取址/解引用，**无切片/联合/match**）对类型层改动**不敏感**——它是「发射面零泄漏」证据，**不得**当新语义正确性证据；新语义一律由**行为探针**承担（各任务判据步单列）。
- **`.ccr` 预期与实测**：Task 0/1/2/3 预期不变（类型表行序不动）；**Task 4（退役内建 Option 注册）/ Task 5（实例键类型项化）预期会变**（命名行编号 / SYM 中 mangled 实例名）→ **允许但必须实测报告**；判据按 TODO #26 = **结构性断言**（`tests/selfhost/test_ccr_v7.py` 全绿）+ 语义零变化 + 自举稳定（`corec2/corec3` `cmp` IDENTICAL + N06=0 + 冒烟 42），不以「与旧版逐字节同」为准。ELF 同时变 → 停下上报。
- **三态纪律（P0/P1/P2a 继承）**：引擎 -1（预算耗尽/未覆盖面）**不得**当 0/1 用；判定路径回落（`type_equal_legacy`）必须计数（`g_replace_unknown`/`g_replace_bridge`）并单列。新引擎查询自带预算前后隔离（照 `type_equal_engine`，checker.cr:500-502）。
- **影子对拍门（每任务复跑）**：基线 = 71 候选 / **67 有效文件 / 26,989 判定全 agree / `old_stricter=0` / `old_looser=0` / `unknown=0` / `replace_*=0`**（findings §11）。**必须与站点覆盖同报**（站点 1/2/4/6 语料零命中、3 仅 2 次）——「零差异」≠「面收敛」；新能力面（match/切片/泛型约束/impl）语料零命中 ⇒ 由定向探针承担。
- **收紧处置（spec §0 裁决 6）**：新判定若「旧接受 → 新拒绝」，逐条记录（文件/用例/旧判定/新判定/处置）；涉及自举源码先跑全语料清单再改；**语义争议停下上报**。
- **新硬错误先报告后开门**：任何把新检查升为 rc=1 门的步骤（穷尽性、长度方向、可选面）必须先在**全语料**（`src/compiler/_import.cr` 自指 + `tests/suite` + `tests/selfhost` 内联源 + `src/stdlib` + `examples`）report-only 跑一遍，清单审查后再入 `run_frontend` 硬错误名单（main.cr:146-158；照 #29 先例）。语料排除项见 TODO #22（`src/compiler/elf.cr` 陈旧 2 parse error；`tests/suite/test_control_flow.cr`/`test_generics.cr` 0 字节）。
- **不得回退既有收纳**：TS01-04/TK02 硬错误门（#29）、F2 常量档拒绝语义与「N 不回身份」（#19/#24）、F5 槽位契约（#25/#28）、效应/纯度判据（#26/#27）本计划一律不动；冲突 → 停下上报。
- 本语言无三元运算符；取模须非负；键比较不得依赖 i64 回绕；noclobber（`>|`）；自测用例**只增不减**（`test_type_engine.py:MIN_CASES=32` 为下限，逐任务下限见各任务判据）。

## 侦查底座（2026-09-11 实读 + 定向实测，file:line = 当前工作树）

**引擎/桥接（能力落点现状）**
- 三态 API：`ty_sub`/`ty_equiv`/`ty_disjoint`/`ty_inhabited`/`tt_witness`/`ty_exhaustive`（type_engine.cr:390/405/479/414/448/471）；`tt_norm`（type_terms.cr:326）；预算 `ty_budget_reset`（type_engine.cr:301）。
- P0 显式未覆盖面（type_engine.cr:10-13）：① 参数化原子**仅同形判等**（变型 = P3）；② `AK_NAMED` **不展开**；③ 空递归保守 -1。变型现状证据 = 同类参数不同形 → `-1`（type_engine.cr:175-182）+ `tt_list_same` 结构相等（:187-193）。
- 桥接（ty_shadow.cr:194-246）：`TYP_ARRAY`/`TYP_SLICE` **同归** `AK_SEQUENCE(elem)`（:217-220，固定性与 N 均不入项）；`TYP_REF` 的 mut 标记**不入参数链**（:224-227，注记自认「引擎无只读/可写区分 = P3 条目化面」）；`TYP_NAMED`/`TYP_GENERIC_PARAM`/`TYP_GENERIC_APPLY` → `AK_NAMED`（:230-231）；`TYP_TUPLE` → `AK_PRODUCT`（:178-191）。桥接缓存随 `init_types()` 失效（:98-102）。

**判定点/长度约束（P2a 现状）**
- `type_equal_engine`（checker.cr:492-508）+ 包装（:515-523）；`type_equal_legacy`（:419-477，对照物 + 回落，P5 删）；10 站点表（ty_shadow.cr:252-269）。
- `array_len_constraint_ok`（checker.cr:346-386）= **常量档**、下钻 6 位（数组/指针/引用/切片/元组字段/泛型实参）；**异 kind → 返回 1（无约束）**；`type_compat_strict`（:394-398）= 身份 ∧ 长度；判定点 10 处（:1088/1455/1468/1483/1732/1927/2320/2654/2780/2845）。
- **实测（2026-09-11，探针 `/tmp/r2p3_probe/`，cwd=探针目录，`build/corec` = 20:39 构建）**：
  - pA `fn g() -> [int;3] { b:[int;4]=[1,2,3,4]; return b[0..2]; }` → **rc=0、零诊断**（切片值当 `[int;3]` 用 = **静默放宽**；读码：legacy 数组分支要求两侧同为 `TYP_ARRAY`（:432-434），跨 kind 判 false ⇒ 此为 P2a 替换后的**现行语义洞**。P2a 前为 `error[TF01]`——此「前值」为读码结论，**未实测**）。
  - pB `fn h() -> [int] { c:[int;3]=[1,2,3]; return c; }` → rc=0（符合 spec §5.1 `[T;N] <: [T]`）。
  - pC 异长（`[int;4]` 在返回位给 `[int;3]`）→ rc=1 `error[TF01]: Array length constraint not satisfied`（常量档拒绝仍在）。
  - pD `fn f(x: int?) -> int` + `v := Some(3)`（无用户 `enum Option`）→ rc=1 `error[N01]: Undefined enum constructor 'Some'`。

**定长退役「未办面」枚举（读码逐条，非猜）**
1. **array/slice 判等过度合并**：桥接同译 `AK_SEQUENCE(elem)`（ty_shadow.cr:217-220）+ `array_len_constraint_ok` 异 kind 返回 1（checker.cr:349）⇒ 方向不设防（实测 pA）。
2. **变型规则缺位**：参数链不携带「固定长/视图」「只读/可写」维度（ty_shadow.cr:220/225-227）⇒ `[T;N] <: [T]`、`[T;N] ≢ [T]`、`&T` vs `&mut T` 均无法表达。
3. **长度档位**：常量档已有（:346-386）；**符号档/动态档未实现**（:343-344 自注「P3 面」）。本次裁定：动态档 = 既有运行期检查（`g_ir_slice_lens` 侧表 + `IR_BOUNDS_CHECK`，R1 已落、TODO F11 划销）+ checker 字面量界检查（:2586-2602）；**符号档 = VC 义务，本计划不实现，显式登记**。
4. **N 读取面边界**：`get_type_extra(TYP_ARRAY)` 仍被读 5 处——常量档（:351）、F11 字面量切片界（:2589）、F2 字面量索引界（:2609）、表示层 `ir_gen.cr:120-131 arr_len_lit_of` / `:476-483 type_size`（+`type_align`）。退役后的**不变式** = 「N 只许被常量档检查与表示层读，身份/子类型路径零 N」——Task 1 为它加守门用例。
5. 自举源码 10 处 `[T; N]` 零改造（R1 裁决）——Task 1 判据复验。

**穷尽性/联合/可选（现状）**
- match **零检查**：`EC_TM_*` 仅定义（ast.cr:443-451），`checker.cr` 零 raise；`EXPR_MATCH` 只推臂体（:2407-2451），模式绑定变量**恒 `TI_INT`**（:2431/:2439）；臂类型一致性、模式 vs scrutinee、穷尽性、冗余臂全无。模式形态（parser.cr:1020-1040）：通配 / 字面量（int/string/char/bool）/ 绑定 ident / 枚举 / struct 模式。
- enum：变体构造器注册为「返回枚举 named 类型的函数」（checker.cr:977-993）；`EXPR_ENUM_CONSTRUCTOR` 只解析名字（:2489-2507，载荷类型不校验）；表访问器 dyn_arr.cr:393-399；`MAX_ENUM_VARIANTS=16`（ast.cr:117）。
- 可选：`T?` 降级为 `Option[T]`（parser.cr:139-143）；`Option` 仅在用户未声明时被注册为**一个 named 类型**（checker.cr:962-975）；`Some`/`None` 走 `EXPR_ENUM_CONSTRUCTOR`（parser.cr:418-431）⇒ 无用户 `enum Option` 时 `Some(3)` 报 N01（实测 pD）；`EXPR_TRY` 按**基名字符串** `"Option"`/`"Result"` 解包（checker.cr:2871-2888）。
- 语料：`src/compiler/**` 与 `tests/suite/**` **零 `match` 表达式**、零 `enum` 声明（全仓 grep 仅注记命中）⇒ 穷尽性收紧的**自举风险 ≈ 0**；enum/match 仅出现在 `tests/selfhost/test_interp_float.py:34-35`、`test_interp_parity.py:54-74`、`test_native_memory.py:68`、`test_lsp.py:137-145` 内联 fixture（均为全变体覆盖的 3 变体枚举）。

**泛型约束（现状）**
- 约束语法仅**函数**泛型有：`parse_generics_into` 收 `T: I`（parser.cr:1184-1188）→ `save_func_gen_constrs`（:1210-1222，索引 `fi * MAX_GENERICS + gi`）；**结构/枚举/接口泛型把约束写进 dummy 缓冲后丢弃**（parser.cr:1533/:1575/:1628）⇒ `struct S[T: I]` 静默无约束。
- 调用点检查 = 名字拼接 + `check_iface`（checker.cr:1562-1598 → :1588）；泛型体内经约束的方法调用同样走名拼接（:2103-2144）。
- monomorph：实例键 = **逗号分隔类型名字符串**，由 `ir_gen` 从**调用实参**的 `irv_type` 生成（ir_gen.cr:1497-1513），**非原生类型一律兜底 `"int"`**（:1511；读码 ⇒ 不同类型实参可折叠到同一实例，**未实测**）；去重 `istr_eq`（monomorph.cr:443-456）；替换 = 名字文本替换（:64-89）；`MAX_GENERICS=4`（ast.cr:115）。

**impl/interface（现状）**
- 表：`g_ifaces` 1432B/条（16 方法 × 88B、方法参数 ≤8；dyn_arr.cr:143-149）；签名存**裸 `TY_*`**（parser.cr:1671/1685 `unpack_type`）⇒ 签名**无法表达命名/泛型类型**。`g_impl_for` 16B 存两名字 ni（parser.cr:1763-1767）。
- 判定：`find_iface`（checker.cr:844-852）/`type_has_method`（:873-879，名字拼接 `Type.method`）/`check_iface`（:881-904）/`check_impl_for`（:1746-1807，param/ret 裸 TY 比较）。
- **ir_gen 零消费、.ccr 零序列化**（spec §11 已核）；覆盖 = `tests/selfhost/test_impl.py` 5 check + 2 native 例，**全为固有方法**（`impl Vec { … }`），`interface`/`impl I for T` 零命中（实读）。

**产物面（判据依据）**
- ELF 无符号表（`src/format/elf/elf.cr` 全文件 `symtab` 零命中）⇒ 函数名/mangled 名**不入 ELF**；`.ccr` 函数记录含 `name_idx`、NOD/var 含类型行号（ccr_io.cr:39-47/129-130）⇒ 命名行编号或实例名变化 → `.ccr` 字节变（允许、须报告）。

## 与 P2b 的交接面（阻塞 / 非阻塞）

| P3 项 | 阻塞于 P2b？ | 说明 |
|---|---|---|
| 定长退役（身份方向/变型/常量档收口） | **否** | 落点 = 桥接（ty_shadow.cr:217-227）+ 引擎变型表 + `array_len_constraint_ok`；P2b 的双表合一不碰这三处 |
| 穷尽性（match 真判定） | **否** | 引擎 `ty_exhaustive` 已有（type_engine.cr:471）；缺的是枚举域项（Task 0）与 checker 接线 |
| 联合/可选（enum = sum、`T?` = T ∪ null） | **否** | 同上；退役 `Option` 注册在 checker.cr:962-975，与 `res_type_node` 无交集 |
| 泛型约束 | **半阻塞** | `T: I` 的**满足判定**须走 `iface_satisfies`（spec §2.3/§2.5）= P2b 注册表入口；**非阻塞半边** = 结构/枚举泛型约束保留（parser.cr:1533/1575）+ monomorph 实例键类型项化 |
| 序列接口 / 横切接口 | **是** | 横切轴条目（`sequence<⊤>`、只读/可写两形状）属注册表；P3 增量 = 形状条目内容 + 消费点（索引/切片/迭代）接线 |
| impl 契约（用户轴） | **是** | 条目升级（形状项引用 + 满足关系）+ `g_ifaces` 布局 + mangling 退役归 P2b；P3 增量 = 签名类型项化 + 覆盖集 |

**交接契约（要求 P2b 落点提供；若落地形态与此不符 → 停下上报后重定 Task 2/6）**：① `iface_satisfies(t_ti: int, iface_ni: int) -> int`（三态 1/0/-1，不得静默当 0）；② 本质条目留可扩展字段——`操作许可`（P2b 落）与**变型规则**（P3 落；引擎侧表可先在 Task 1 落，条目字段后续挂引用）；③ `res_type_node` 单一化后 `TYP_ARRAY`/`TYP_SLICE`/`TYP_NAMED` 构造语义不得变化（Task 0/1 依赖）。

> **P2b 已落地（2026-09-11，提交链 `7f520dce`→`30545da7`）——本条契约按 P2b 实际交付面重定，实施前必读附录 A**：① **`iface_satisfies` 未交付**（P2b 范围明标「零调用者，P3 落地 impl 语义时才有对象」，见附录 A.3-①）⇒ Task 2/6 与 Task 5 的 `T: I` 满足半边**开工前先补条目 + 满足判定**；② 条目表已落 5 字段 `{ak, ti_row, name_ni, lit_code, ops}`（40B/条，无变型规则字段；`name_ni` 现为 `-1`——.ccr STR 段硬判据，见 A.3-②）⇒ 变型规则无处挂，Task 1 按「引擎侧表先行」口径落地（本计划原文已备此路）；③ 已满足：`res_type_node`/`res_call_type` 经单表 `ty_code_to_ti`，`TYP_ARRAY`/`TYP_SLICE`/`TYP_NAMED` 三构造语义零变化（P2b 全判据 = 零行为变化）。

---

## Task 0（P3a，前置）：引擎展开层——named/struct/enum/generic-apply → 结构项

**Files:** Modify `src/compiler/ty_shadow.cr`（新增展开查询，**不改**既有分支语义）· `src/compiler/checker.cr`（暴露 名字→struct/enum 行 查询）· `src/compiler/type_engine.cr`（满足判定入口占位）· `src/compiler/type_selftest.cr`

**Interfaces:**
```
// 展开查询（只读、per-ti 缓存 + 预算；-1 = 不可展开/未覆盖面——不得静默判否）
fn sh_struct_term(ti: int) -> int          // struct named → AK_PRODUCT(字段项链, 声明序)
fn sh_enum_domain_term(ti: int) -> int     // enum named → AK_SUM 变体项之 union（= 域）
fn sh_variant_term(ti: int, name_ni: int) -> int  // 变体名 → 变体项（穷尽性模式项用）
fn sh_iface_shape_term(iface_ni: int) -> int      // 接口 → 形状项（方法集 product of fn；P2b 条目就绪前返回 -1）
```
**语义边界（实施须遵守）**：展开**只服务** ① 满足判定 `T <: 形状` ② 穷尽性域/模式项。**等价/包含判定（`type_equal` 路径）保持原子名义，不展开**——否则同形不同名类型被判等价 = 语义漂移，且推翻 P2a 对拍归零基线。一层深度不足 → 按引擎既有规则 -1 上抛。

- [ ] **Step 1: 用例（红）6 例**（`type_selftest.cr`）：struct → product 字段序；enum → sum 变体数；`Box[int]` 域展开含实参代入；**名义不漂移**（两个同形不同名 struct：`ty_equiv` 仍 **-1**、`type_equal` 仍 false）；行号越界 → -1；展开缓存命中计数。**为何 6 例**：四个正向形态 + 一条名义不变量双钉 + 一条缺口上抛。
- [ ] **Step 2: 实现 + 缓存**（照 `sh_map_*` 先例：装填守卫 / 重建重放 / 回写重探；`find_struct`/`find_enum`/`find_iface`（checker.cr:824-852）为名字入口）。
- [ ] **Step 3: 判据**：`selftest-types` **95 → ≥101**；影子对拍复跑（**预期零变化**——展开未接入 `type_equal` 路径；`unknown`/`replace_*` 若变 → 逐条归因登记）；ELF canary IDENTICAL（clean-cache）；`test_compile`/`test_purity`/`test_ccr_v7` 绿。
- [ ] **Step 4: 提交**：`feat: R2 P3 Task 0——引擎展开层（struct→product / enum→sum / generic-apply 代入；仅满足判定与域查询用，等价判定保持原子名义）`

## Task 1（P3a）：定长退役收口——array/slice 方向 + 变型 + 长度档位

**Files:** Modify `src/compiler/ty_shadow.cr`（`AK_SEQUENCE`/`AK_REF` 参数链携带固定性与 mut）· `src/compiler/type_engine.cr`（变型表 + `tt_list_same` 按变型比较）· `src/compiler/checker.cr`（`array_len_constraint_ok` 方向规则；判定点不变）· `src/compiler/type_selftest.cr`

**Interfaces:**
```
fn ty_variance_of(ak: int, slot: int) -> int   // 0 = 不变 / 1 = 协变（P3 首版落引擎；条目字段后挂引用）
fn sh_seq_term(elem: int, fixed_len: int) -> int   // fixed_len = N（数组）或 -1（视图/切片）；N 仍不入等价身份，仅入「固定性」位
fn array_len_constraint_ok(a: int, b: int) -> int  // 签名不变；补方向：视图→固定 且无法证 len==N ⇒ 0
```
**语义（spec §5.1）**：`[T;N] <: [T]`（更强长度约束 = 子类型）；`[T] ⊄ [T;N]`（除非证 len==N）；只读序列视图**协变**、可写视图**不变**；`&T`/`&mut T` 进参数链（mut 标记成为判定维度，替代 ty_shadow.cr:224-227 的「不入链」）。

- [ ] **Step 1: 用例（红）8 例**：方向 4（`[int;3] <: [int]` = 1 / `[int] <: [int;3]` = 0 / `[int;3]` vs `[int;4]`：等价判 1（N 不入身份）+ 常量档拒 0 / slice vs slice 同元素 = 1）；变型 2（只读协变通过、可写不变拒绝）；**N 读取面守门 1**（身份路径零 N：`type_equal` 对异长同结构仍 true，且 `array_len_constraint_ok` 是唯一拒绝来源）；**动态档登记 1**（切片运行期长度不可证 ⇒ 视图→固定拒绝，不给 -1 当 0）。**为何 8 例**：每条方向/变型规则正负控成对 + N 边界双钉 + 三态纪律。
- [ ] **Step 2: 实现**（变型表首版仅含 `AK_SEQUENCE`/`AK_REF`/`AK_PTR` 三构造子，其余默认不变；`tt_list_same` 改为按 `ty_variance_of` 递归，**不得**改变同形时的既有结果——同形判定仍是 1）。
- [ ] **Step 3: 行为探针（本任务主判据）**：pA 必须由 rc=0 翻为 **rc=1 + 专属措辞**（收紧清单第 1 条）；pB/pC 语义保持（pB rc=0、pC rc=1 TF01）；新增 pE（`&mut T` 形参接 `&T` 实参拒绝 / 反向拒绝）；嵌套位沿用 f2.* 探针形态（`[[int;3];2]`、`G<[int;3]>`、`*[int;3]`、`(int,[int;3])`）。
- [ ] **Step 4: 判据**：`selftest-types` 101 → **≥109**；影子对拍复跑（预期零差异——N 面影子已失明，**不得**以对拍充当 N 面证据，findings §11）；全语料 report-only（收紧面清单）→ 自举源码 10 处 `[T;N]` 复验零改造；ELF canary IDENTICAL；全回归 + 自举链。
- [ ] **Step 5: 提交**：`feat: R2 P3 Task 1——定长退役收口（array<:slice 方向规则 + 只读协变/可写不变变型表 + N 读取面守门；修 slice→数组 静默放宽）`

## Task 2（P3b，P2b 后置）：横切接口——序列/可索引/可迭代/product 形状判定接线

**Files:** Modify `src/compiler/checker.cr`（索引/切片/字段/迭代路径：`get_type_kind == TYP_ARRAY/TYP_SLICE` 直比 → `iface_satisfies`）· `src/compiler/ty_shadow.cr`（形状项构造）· `src/compiler/type_selftest.cr`

**依赖**：P2b 注册表的 `iface_satisfies` 与横切轴条目（交接契约 ①）。若 P2b 只落本质轴操作许可（lead 描述的窄版本），本任务 Step 1 先补横切轴条目再接线，并在报告登记范围扩大。

- [ ] **Step 1: 形状条目细化（spec §2.2 的「待细化」）**：`序列接口` ⟺ `sequence<⊤>`；**只读/可写两形状**（只读 = 协变、可写 = 不变，与 Task 1 变型表同源）；`可索引`/`可迭代`/`product` 三条目首版（形状项 = 对应 AK 的 ⊤ 实例化）。
- [ ] **Step 2: 用例（红）6 例**：数组/切片满足序列接口（正）；int 不满足（负）；只读形状接受数组与切片、可写形状拒绝只读视图；`可索引` 对字符串（TI_STR 索引已支持，checker.cr:2619-2633）正控；接口形状项不可展开 → -1（不得当 0）。
- [ ] **Step 3: 消费点接线**：索引（checker.cr:2581-2636）/切片（:2586-2602）的 `get_type_kind` 直比改为「形状满足 + 元素项取出」；**行为保持**（既有接受/拒绝集合不变，仅来源换位——如出现差异按收紧清单登记）。
- [ ] **Step 4: 判据**：`selftest-types` ≥109 → **≥115**；影子对拍复跑（站点 8/5/7 主流量：**判定数应不变**，agree 全绿）；行为探针：数组/切片/字符串索引全部正例 + 负例（`int` 索引拒绝）；ELF canary IDENTICAL；全回归。
- [ ] **Step 5: 提交**：`feat: R2 P3 Task 2——横切接口接线（序列/可索引/可迭代/product 形状满足判定取代 TYP_* 直比；只读协变/可写不变两形状）`

## Task 3（P3a）：穷尽性真判定——match 补集空性 + 反例值

**Files:** Modify `src/compiler/checker.cr`（`EXPR_MATCH` 分支：模式项收集 + `ty_exhaustive` 判定 + 诊断）· `src/compiler/ty_shadow.cr`（变体项）· `src/compiler/type_selftest.cr` · New `tests/selfhost/test_match_exhaust.py`

**语义（spec §5.4）**：穷尽性 = 补集空性 ⇒ `ty_exhaustive(domain, patterns)`；反例给**具体值**（未被覆盖的变体名）。**域限定**：仅枚举 scrutinee 判穷尽（域 = 变体集）；int/string/bool/char 字面量模式与通配的域不判穷尽（**显式登记**：非枚举域不判，不得假装穷尽或假装不穷尽）；`-1`（未知）**不得**升为「不穷尽」硬错误。

- [ ] **Step 1: 模式项收集**：臂模式 → 项（枚举模式 = `sh_variant_term`；绑定 ident = 通配但**不绑定值域**；通配 = ⊤）；scrutinee 类型 → 域项（`sh_enum_domain_term`，Task 0）。
- [ ] **Step 2: 用例（红）8 例**（引擎层，`type_selftest.cr`）：全变体覆盖 = 1 / 缺一变体 = 0 + witness = 该变体 / 通配吸收 = 1 / 单变体枚举 = 1（无臂 = 0）/ 域不可展开（`AK_NAMED` 不展开）= -1（不得当 0）/ 空枚举域 = 0（无值可覆盖，登记语义）/ 重复臂 → 补集已空（`EC_TM_REDUNDANT` 同源判据）/ payload 变体与 tag 变体混合。**「非枚举域不判穷尽」是 checker 侧登记项**（不调引擎），验证在 Step 4 行为集，不占引擎用例。
- [ ] **Step 3: 硬错误门（report-only 先行）**：`EC_TM_EXHAUST`（9003）入 `run_frontend` 硬名单前，全语料 report-only；清单若空 → 开门（main.cr:146-158 追加一行）。**冗余臂（9004）同期评估**（同族判据，可同批）。
- [ ] **Step 4: 行为覆盖集**：新增 `tests/selfhost/test_match_exhaust.py`（≥8 例：穷尽过 / 缺臂拒 + 码 + **无产物** / 通配过 / 嵌套枚举 / payload 变体 / 空枚举边界 / 非枚举域不报穷尽 / 泛型枚举实例），挂钩 `src/ci/run.sh` selfhost-tests。
- [ ] **Step 5: 判据**：`selftest-types` ≥115 → **≥123**；镜像回归：`test_interp_float.py`（3 变体全列）、`test_interp_parity.py`、`test_native_memory.py` 全绿（**这些是唯一既有 match 语料**）；ELF canary IDENTICAL；全回归 + 自举链。
- [ ] **Step 6: 提交**：`feat: R2 P3 Task 3——match 穷尽性真判定（补集空性 + 具体变体反例；仅枚举域，非枚举显式登记）+ TM03 硬门 + 覆盖集`

## Task 4（P3a）：联合/可选——enum = sum 项、`T?` = T ∪ null、退役内建 Option 注册

**Files:** Modify `src/compiler/checker.cr`（:962-975 退役；`EXPR_TRY` :2871-2888 去名字依赖）· `src/compiler/parser.cr`（`T?` 目标形态）· `src/compiler/ty_shadow.cr`（null 项）· `src/compiler/type_selftest.cr` · New `tests/selfhost/test_optional.py`

**决策点（实施前须定，语义争议 → 停下上报，spec 裁决 6）**：`null` 的类型承载。spec §5.4 写「`T?` = `T ∪ null`」，但 §1.2 原生八员**无 `null`**。候选：**(a) 新增原生原子 `AK_NULL`（原生九员，值域单点）**——推荐（`None` 值、`T ∪ null` 直接成立、与 AK_UNIT 不相交）；(b) `null` 归 `AK_UNIT`（值域混淆，不推荐）；(c) 仅保留枚举形态（= 不做此项，与 spec 相悖）。**裁定前不实施本任务 Step 2+**。

- [ ] **Step 1: 用例（红）6 例**：`T?` 的项 = `T ∪ null`（`ty_equiv`）/ `None` 满足 `T?`（子类型）/ `Some(1)` 满足 `int?` / `null` 与 `int` 不相交（`ty_disjoint`）/ 联合在 match 域上的穷尽性（`T?` 两分支：有值 + None）/ 退役后 `Option` 名字不再被 bultin 注册（行数对照）。
- [ ] **Step 2: 实现**：`Some`/`None` 在无用户 `enum Option` 时仍可解析（parser.cr:418-431 的名字路径接 `T?` 的联合项）；`EXPR_TRY` 改按**类型项结构**（`AK_SUM`/联合含 null）解包，废掉基名字符串 `"Option"`/`"Result"`（checker.cr:2879 的 `base_name ==` 判断）。
- [ ] **Step 3: 判据**：`selftest-types` ≥123 → **≥129**；`.ccr` **预期变**（退役一个命名行 → 行号位移）→ 实测报告 + `test_ccr_v7` 结构性断言全绿 + 冷缓存对比；ELF canary IDENTICAL（若变 → 停下上报）；`test_optional.py` ≥8 例（含解释器/ELF 双路径 rc）；全回归。
- [ ] **Step 4: 提交**：`feat: R2 P3 Task 4——可选 = 联合（T? = T ∪ null；退役内建 Option 注册与 EXPR_TRY 名字解包）`

## Task 5（P3a 主 + P3b 半）：泛型约束——保留/实例化判定/monomorph 类型项化

**Files:** Modify `src/compiler/parser.cr`（:1533/:1575 结构/枚举泛型约束不再丢）· `src/compiler/checker.cr`（声明处约束登记 + `ty_sub(实参, 约束)` 实例化判定）· `src/compiler/monomorph.cr` + `src/compiler/ir_gen.cr:1497-1513`（实例键类型项化）· `src/compiler/type_selftest.cr`

- [ ] **Step 1: F4 同族复核（TODO #21）**：`infer_gen_call` 的形参链导航（`ast_data(pn)`）在后续形参上取到 `gparam(T)` 而非声明类型——本任务先修此（否则实例化判定拿不到正确的实参类型）；用例正/负控各一。
- [ ] **Step 2: 结构/枚举泛型约束落地**：`parse_generics_into` 的约束不再写 dummy（parser.cr:1533/1575），登记到结构/枚举侧表（照 `g_generic_constr` 先例，索引空间分家）；声明处检查 = 实例化点（`Box[T: I]` 的 `Box[P]`）。
- [ ] **Step 3: 实例化判定引擎化**：`T: I` 检查 = `ty_sub(实参项, 约束项)`（约束为**类型项**；本质轴形状用引擎、用户接口形状待 P2b 的 `iface_satisfies` ⇒ **本步本质轴部分 P3a 可做，用户接口部分 P3b**）；失败给**非空反例**（`tt_witness`），诊断含反例值；`-1` 不得当 0。
- [ ] **Step 4: monomorph 类型项化**：实例键由「调用实参名串（非原生 → `"int"` 兜底）」改为「**类型项结构哈希**（含命名/泛型应用实参真身份）」；`gen_build_subst` 名字替换升级为类型项替换（或按项哈希生成规范名）。**产物面**：实例 mangled 名若变 → SYM/`.ccr` 变（允许、实测报告；ELF 无 symtab ⇒ 预期不变）；去重正确性探针：两个**不同结构体类型**实参调用同一泛型函数 → 必须是两个实例（今天可能折叠——**未实测**，本步实测并登记）。
- [ ] **Step 5: 判据**：`selftest-types` ≥129 → **≥137**；`MAX_GENERICS=4`（ast.cr:115）解除或显式登记（二选一，记录理由）；行为探针：约束满足/违反（含反例文本）/结构泛型约束/双类型实参实例分离；影子对拍复跑 + 全回归 + ELF canary IDENTICAL + `.ccr` 实测报告 + 自举链。
- [ ] **Step 6: 提交**：`feat: R2 P3 Task 5——泛型约束（结构/枚举约束不再丢 + 实例化 ty_sub 判定 + 反例；monomorph 实例键类型项化）+ F4 形参链修复`

## Task 6（P3b，P2b 后置）：impl 契约——签名类型项化 + 满足判定接引擎 + mangling 退役 + 覆盖集

**Files:** Modify `src/compiler/parser.cr`（:1619-1721 `interface` 方法签名：裸 `TY_*` → 类型节点/ti；≥16 方法 / ≥8 参数上限的处理）· `src/compiler/checker.cr`（:844-904/:1746-1807 + 方法解析 :2103-2144 名字拼接 → 条目查表）· `src/compiler/ty_shadow.cr`（接口形状项）· New `tests/selfhost/test_impl_iface.py`

**依赖**：P2b 注册表（条目 + 满足关系 + `iface_satisfies`）。**mangling 废弃**（spec §2.3/§5.3，无兼容窗口 = 裁决 5）。

- [ ] **Step 1: 签名类型项化**：`interface I { fn m(a: T) -> U; }` 的 T/U 从裸 `TY_*` 改为类型节点解析（`res_type_node`）——**现状只能写基类型**（parser.cr:1671/1685）；方法上限 16 / 参数上限 8（dyn_arr.cr:143-149）**解除或显式登记**。
- [ ] **Step 2: 覆盖集（spec §5.3 要求新建）**：`test_impl_iface.py` ≥10 例——正向（满足）/ 反向（缺方法、参数数不符、参数类型不符、返回类型不符）/ 多接口 / 与泛型约束交互（`fn f[T: I]`）/ 错误例（未定义接口）/ 固有方法不受影响（`test_impl.py` 7 例保持绿）。
- [ ] **Step 3: 满足判定接引擎**：`check_iface`/`check_impl_for` 改走 `iface_satisfies`（形状项包含判定）；方法解析（`type_has_method` 名字拼接，checker.cr:873-879）改「类型项 + 条目」查表；泛型约束的方法调用路径（:2103-2144）同步。
- [ ] **Step 4: 判据**：`selftest-types` ≥137 → **≥141**；`test_impl.py` 7/7 不回归 + 新套件全绿 + `src/ci/run.sh` 挂钩；影子对拍复跑；全回归；ELF canary IDENTICAL；`.ccr` 实测报告（接口目前零序列化 ⇒ 预期不变）。
- [ ] **Step 5: 提交**：`feat: R2 P3 Task 6——impl 契约（接口签名类型项化 + iface_satisfies 接引擎 + mangling 退役）+ 覆盖集`

## Task 7：收官（回归 + 判据 + 收紧清单 + 文档）

- [ ] **Step 1: 全量回归**（`src/ci/run.sh` selfhost + bootstrap 全档）
- [ ] **Step 2: 零变化复验**：ELF canary IDENTICAL（clean-cache，开/关两态）+ `.ccr` 变更面实测报告（逐任务列）+ 影子对拍终态（差异/站点覆盖/回落计数同报）
- [ ] **Step 3: 自举链**：`corec2/corec3` `cmp` IDENTICAL + N06=0 + 冒烟 `run 'fn main()->int{return 42;}'` = 42
- [ ] **Step 4: 收紧清单汇总**：本批「旧接受 → 新拒绝」逐条（预期 ≥1 条：pA 切片→数组；标「P2a 引入的静默放宽在本批关闭」）
- [ ] **Step 5: 文档**：spec §9 P3 行标 ✅ + 未覆盖面更新（符号档登记）；TODO：`fixed-array-retire`（TODO.md:446）未办句划销、#19 的「P3 面遗留」收口、#26 判据继承、新增登记（非枚举域不判穷尽 / 空递归保守 / MAX_* 上限处置）；findings 文档追加「P3 后复跑」节
- [x] **Step 1: 全量回归**（`src/ci/run.sh` selfhost + bootstrap 全档）——收官实测：五 job（selfhost-tests / bootstrap-tests / suite / check / full-bootstrap）rc 与逐档计数见收官报告 §1；全量套件枚举 **42 selfhost + 7 bootstrap** 逐档记录 rc；`check` job rc=1 = **既有 red 划界**（2 条 TF01 误报，非本批引入）；枚举**暴露 1 处新增 red**（`test_backend_bootstrap.py` — T5 漏改 project-mode 清单 ⇒ 33×N06 静默，**已修**，见**附录 B.6**）⇒ 终态 **49/49 rc=0**
- [x] **Step 2: 零变化复验**：ELF canary IDENTICAL（clean-cache）`95084e7b…d475` ✓；`.ccr` 变更面逐任务列（T0/T1/T3 不变；T4 = STR 段整串退役 −10B；T5 = `generics_test` +370B 反折叠而 `ptr_arith` 不变）✓；影子对拍终态 `decisions=30338 agree=30338` 全计数 0、站点覆盖同报 ✓
- [x] **Step 3: 自举链**：`corec2/corec3` `cmp` IDENTICAL + N06=0 + 冒烟 42 ✓（收官复验，见报告 §2）
- [x] **Step 4: 收紧清单汇总**：**18 条**（T0 0 · T1 6 · T3 6 · T4 3 · T5 3）+ 诊断面新增 1（TM04 软）；放宽 **8 条**（T4 7 + T5 1）+ 实例名忠实化 6（T5）——统一台账 = **附录 B.2**
- [x] **Step 5: 文档**：spec §9 P3 行标 ✅（**P3a**）+ 符号档登记；TODO = #34（P3a 落地）+ `fixed-array-retire` 未办句划销 + #19「P3 面遗留」收口 + #26 判据继承 + 新登记（非枚举域不判穷尽 / 空递归保守 / MAX_* 上限处置）；findings §13「P3a 后复跑」
- [x] **Step 6: 提交**（路径限定）

## 实施状态总表（2026-09-12，P3a 收官更新）

> **P3a = Task 0/1/3/4/5 已交付**（提交链 `61d3a8b4`→`ef61f002`→`e9818d62`→`c8c7731b`→`9c0a83ec` + 收官提交）；**P3b = Task 2/6 + Task 5 的 `T: I` 半边全部未开工**——开工前必读**附录 B**（阻塞项 / 接线点 / 逐条登记面 / P5 继承项）。

| 任务 | 状态 | 提交 | 判据要点 | 报告 |
|---|---|---|---|---|
| Task 0 引擎展开层 | ✅ 已交付 | `61d3a8b4` | 纯新增 502/0；用例 212→**229**；零行为变化（72 档三面 diff 空） | `.superpowers/sdd/p3-task0-report.md` |
| Task 1 定长退役收口 | ✅ 已交付 | `ef61f002` | 用例 229→**249**；收紧 **6** / 放宽 0；修「切片→固定长」静默放宽 | `.superpowers/sdd/p3-task1-report.md` |
| Task 2 横切接口 | ⛔ 未开工（P3b） | — | 阻塞 = `iface_satisfies` 未交付 | 附录 B.1 |
| Task 3 穷尽性真判定 | ✅ 已交付 | `e9818d62` | 用例 249→**263**；收紧 **6** + 软 1（TM04）；TM03 硬门；新套件 16 例 | `.superpowers/sdd/p3-task3-report.md` |
| Task 4 联合/可选 | ✅ 已交付 | `c8c7731b` | 用例 263→**279**；收紧 **3** / 放宽 **7**（含挂死修复 2 端）；新套件 12 例 | `.superpowers/sdd/p3-task4-report.md` |
| Task 5 泛型约束（P3a 半边） | ✅ 已交付 | `9c0a83ec` | 用例 279→**288**；收紧 **3** / 放宽 1 / 实例名忠实化 6；新套件 14 例；`T: I` 半边 = P3b | `.superpowers/sdd/p3-task5-report.md` |
| Task 6 impl 契约 | ⛔ 未开工（P3b） | — | 阻塞 = `iface_satisfies` 未交付 | 附录 B.1 |
| Task 7 收官（P3a） | ✅ 已交付 | 收官提交 | 全量回归（49/49）+ canary + 台账汇总 + 交接包（附录 B）；**发现并修复 T5 的 project-mode 清单漏改回归**（附录 B.6） | `.superpowers/sdd/p3-task7-report.md` |

## 自检记录

- **spec 覆盖**：§5.1 定长/序列/长度约束 → Task 0/1/2；§5.2 泛型 → Task 5；§5.3 impl → Task 6；§5.4 穷尽性/联合/可选 → Task 3/4；§9 P3 行五项目标能力逐项有落点；`TODO.md:446` fixed-array-retire 的「未办 = 类型身份退役本身」由 Task 1 收口（枚举了 5 条读码事实，非猜）。
- **占位符扫描**：无 TBD；两处**决策点显式登记**（Task 4 的 `null` 原子承载、Task 5 的 MAX_GENERICS 解除或登记）——均为"实施前须定"，非「稍后填」。
- **命名一致性**：`sh_struct_term`/`sh_enum_domain_term`/`sh_variant_term`/`sh_iface_shape_term`/`ty_variance_of`/`sh_seq_term`/`iface_satisfies` 在任务间一致；`iface_satisfies` 为 P2b 交接契约名。
- **数字口径**：95 = 实测（`grep -c "fails = fails + ts_check("` = 95）；26,989/67 文件 = findings §11 实测；pA-pD 四探针 = 本计划实测（2026-09-11）；其余「≥N 例」为计划下限（可增不可减）。
- **风险面**：① **展开层裁定**（Task 0 的「仅满足判定展开、等价不展开」边界）——裁错 → 判定全面漂移 + 推翻 P2a 基线（缓解：影子对拍逐任务归零 + 名义不变量用例）；② **pA 类静默放宽**（已实测在库：切片→数组）——本批收紧即修，须走收紧清单 + report-only；③ 穷尽性硬错误影响用户 rc（缓解：语料零 match + report-only 先行）；④ monomorph 实例键变更（`.ccr`/SYM 变化 + 折叠缺陷修复可能改变既有实例数——实测报告）；⑤ **P2b 依赖项阻塞**（Task 2/6 + Task 5 半）——分批交付（P3a 先行、P3b 待 P2b）。

---

## 附录 A：R2 P2b 交接包（2026-09-11 收官实测；P3 实施前必读）

**来源**：R2 P2b Task 1~6 报告（`.superpowers/sdd/p2b-task{1..6}-report.md`）+ 收官复验（提交链 `7f520dce`→`31143cd0`→`6d2790cd`→`a99ee825`→`7145eea5`→`30545da7` + 本附录所在收官提交）。P2b 的硬口径 = **保语义接线（零行为变化）**：同源双编译器对拍逐任务空（旧二进制 × 新源 == 新二进制 × 新源：21 档语料 + 自源 + 影子 + `.ccr` 四面）。⇒ 本附录的每一条「不接线」= **在该口径下不可能接线**，理由均为实测（探针/突变/全行枚举），不是判断。

**行号口径**：本附录行号 = P2b 末提交 `30545da7` 实测（`checker.cr` 3422 行）；括注「←T4/T5 报告号」= 该任务报告的**接线前**行号（两报告间有 +10~+21 增行位移，勿混；定位请按内容）。

### A.1 P2b 实际接线面（P3 的「已就位」清单）

| 面 | 站点（P2b 末行号） | 接线形态 | 任务 |
|---|---|---|---|
| 字面量定型 5 处 | `checker.cr:1906/1908/1909/1910/1911` | 内联 `if` → `iface_lit_ti(EXPR_*)`（短路顺序逐字保持；`EXPR_NONE` 转发行夹在中间未动） | T3 |
| 算术门（ANY） | `checker.cr:1969` | `iface_permits(iface_kind_of(lt), op) == 0 && …(rt)…`；表 ADD..MOD **只含 int/dex**（早退规则 `:1951/:1953/:1956/:1960` 留代码 = 结果规则） | T4 |
| 逻辑门（ALL） | `checker.cr:1984` | `… OP_AND … \|\| …`；表 AND/OR **恰 {int, bool}**（dex 为 0——`1.5 && true` 探针实测拒） | T4 |
| `if` 条件门（ONE） | `checker.cr:2298` | `IP_COND`（bool\|int） | T4 |
| `while` 条件门（ONE） | `checker.cr:2411` | `IP_COND_BOOL`（仅 bool；**不得与上合并**） | T4 |
| 索引兜底拒绝 | `checker.cr:2678` | 原 `EC_TK_INDEX` 调用被 `iface_permits(…, IP_INDEX) == 0` 包住；门体即原调用（**不是**「门 + 原调用」两条——`check_error` 无去重，T5 §3 裁决）；可达集 = 表拒绝集（逐行枚举 `idx.gate_deny_covers_fallback` 钉死） | T5 |
| TY→TI 单表（8 站点） | `checker.cr:742`（res_type_node）/`:1397`（res_call_type）/`:1063`+`:1089`（hotpatch 两处）/`:1146`（extern）/`:1682`（形参）/`:1737`（返回）/`:2159`（iface 返回）——值全部经 `iface_registry.cr:259-270` 的 `ty_code_to_ti` | 单表给**值** + 站点给**域**（逐站显式排除项）；域差异是**载荷**（T6 §6.2 突变 M2 实证：一刀切写法会静默改判定） | T6 |

### A.2 未接线站点台账（31 条 = T4 的 14 + T5 的 17）

> 「不接线」的三种实测理由分类：**结果规则**（该分支同时决定结果类型，非许可判定）、**无拒绝路径**（现状恒真，换成门 = 空转）、**谓词非类级位**（类级位表达不了逐行/逐名判定）。

#### A.2.1 二元 / 一元 / 条件面（T4：18 站点 − 4 接线 = 14）

| # | 站点（P2b 末行号 ← 接线前） | 现状语义 | 不接线的实测理由 | P3 动作 |
|---|---|---|---|---|
| 1 | `:1949` ←`:1944` 组派发 `op ∈ ADD..MOD` | 选出算术族 | **结构判定**（不是许可）：决定走哪一族；换表需先有「族」概念 | 横切轴（Task 2） |
| 2 | `:1951` ←`:1946` 串拼接 | `OP_ADD ∧ (lt/rt==STR) → STR` | **结果规则 + 早退**：表 ADD 格含 STRING 会在 ANY 门下误命中（如 `1 + 2` 一侧为串即成）⇒ 需**另设拼接位** = 计划位表外的新设计 | 拼接位独立建模 |
| 3 | `:1953` ←`:1948` `*T ± int → *T` | 结果 = 指针行 | 结果规则；PTR 进门 = 放宽（`*T + *T` 现状 TB01，负控实测） | — |
| 4 | `:1956` ←`:1951` `int + *T → *T` | 结果 = 指针行 | 同上 | — |
| 5 | `:1960` ←`:1955` `*T − *T → int` | 结果 = int | 结果规则（且只认 `OP_SUB`） | — |
| 6 | `:1972` ←`:1962` dex 支配 | 任一侧 DEX → DEX | 结果规则（门只管报不报错） | — |
| 7 | `:1973` ←`:1963` 兜底 | `return TI_INT` | 结果规则 | — |
| 8 | `:1975-1977` ←`:1965-1967` 比较 6 op | 恒 `TI_BOOL`、**不校验操作数** | **无拒绝路径**（登记面探针零拒绝） | 可比性判据后逐类收紧 |
| 9 | `:1936-1946` ←`:1931-1941` 赋值（`EXPR_BINARY`+`OP_ASSIGN`） | `type_compat_strict(lt, rt)` | **P2a 判定替换面**（引擎 + legacy 回落），非 ops 位集对象；`OP_ASSIGN` 位在表中不使用 | 随 P2a 面（P5 清偿） |
| 10 | `:1994-1996` ←`:1979-1981` NEG/NOT | 直接返回操作数类型 | **无拒绝路径**（`-"a"` rc=0，探针实测） | 数值性判据（NEG 只收数值、NOT 只收 bool/int） |
| 11 | `:1997-2017` ←`:1982-2002` `UOP_REF` | 任意操作数 → `alloc_type(TYP_PTR, …)` | 结果规则（构造类型行）；全类许可 | — |
| 12 | `:2018-2029` ←`:2003-2014` `UOP_DEREF` | REF/PTR→内层；GPARAM→自身；**兜底透传** | 三分支皆结果规则；兜底 = **无拒绝路径**（`*x`（x: int）rc=0） | 兜底分支改拒绝 |
| 13 | `:2030` ←`:2016` 一元尾兜底 | 透传操作数 | 无诊断（未识别一元 op） | — |
| 14 | `:2437-2438` ←`:2411-2412` range 两端 | `st == TI_INT && et == TI_INT`（**只收 int**） | **无对应位定义**：最接近的 `IP_COND` 含 bool ⇒ 用之 = 放宽（`"a".."b"` 现状 TB01，实测）；新造端点位 = 计划位表外设计 | 端点位（新位） |

#### A.2.2 容器面（T5：18 候选 − 1 接线 = 17）

| # | 面 | 站点（P2b 末行号 ← 接线前） | 现状语义 | 不接线的实测理由 | P3 动作 |
|---|---|---|---|---|---|
| 15 | 索引 | `:2621-2638` ←`:2611-2628` range 索引 | 数组→`TYP_SLICE`；否则 `return TI_UNIT` **静默** | `IP_INDEX_RANGE` 拒绝分支**无诊断** ⇒ 门恒真（探针 I14-I16：串/切片/int range 全 rc=0） | 落空加诊断（或定串 range 语义——语义裁决） |
| 16 | 索引 | `:2640-2650` ←`:2630-2640` `TYP_ARRAY`→元素 + **F2 越界** | 结果规则 + 既有诊断 | 计划明令原地保留（三分支做**不同的事**：F2 检查/元素/`TI_INT`） | — |
| 17 | 索引 | `:2651-2653` ←`:2641-2643` `TYP_SLICE`→元素 | 结果规则 | 同上 | — |
| 18 | 索引 | `:2654-2668` ←`:2644-2658` `TI_STR`→`TI_INT` + 字面量越界 | 结果规则 + 既有诊断 | 同上 | — |
| 19 | 字段 | `:2548-2552` ←`:2538-2542` `TYP_REF` 自动解引用 | 结果规则（落 `actual_ti`） | 无拒绝路径；改查表 = 改结果规则 | — |
| 20 | 字段 | `:2553-2556` ←`:2543-2546` `TYP_GENERIC_APPLY` 解包基型 | 结果规则 | 同上 | — |
| 21 | 字段 | `:2557-2599` ←`:2547-2589` `TYP_NAMED`→struct 字段表（含泛型代换） | 结果规则（名字匹配 + 返回字段行） | 谓词是**字段名匹配**（`si_field_name == field_ni`），不是类级位 | 字段名×类型二维判定 |
| 22 | 字段 | `:2600-2611` ←`:2590-2602` `TYP_TUPLE`→`.N` | 结果规则 | 同上 | — |
| 23 | 字段 | `:2613` ←`:2603` **落空** `return TI_UNIT` | **无诊断静默** | `IP_FIELD` 拒绝集与「能走到的行集」**同集** ⇒ 恒真门（探针 F3-F12：越界元组位/未知字段/方法当字段/ptr·串·数组/int·dex·bool·dyn 操作数 **12/12 rc=0**） | 落空加诊断；此时 `IP_FIELD` 才成为可推翻判定 |
| 24 | 转换 | `:2943-2952` ←`:2922-2931` PTR 目标 asp 传递 | 结果规则（构造 `*T`） | 结果规则，非许可判定 | — |
| 25 | 转换 | `:2953` ←`:2932` 其余恒等透传 | `return target_ti` | **无拒绝路径**（探针 A1-A10：`"a" as int`/`arr as int`/`1 as S` 等 **10/10 rc=0**） | 转换合法性矩阵（源→目标允许表） |
| 26 | dyn | `:1834-1843` ←`:1829-1838` 写集 | 位图并集 | 无拒绝路径；**64 上限钳位**（spec §3.3） | 解除 64 上限 |
| 27 | dyn | `:1845-1854` ←`:1840-1849` 读集 | 位测试 | 只读，无判定面 | — |
| 28 | dyn | `:1870-1893` ←`:1865-1888` `validate_dyn_method` | 「dyn 集里**每个**具体行都须有该方法」 | **谓词非类级位**：`type_has_method(get_type_name(ti), method_ni)` = 逐具体行名拼接方法表成员判定；**int/string 候选行今日也发 N08**（探针 D1/D4）⇒ 类级门会**抑制既有诊断 = 放宽**；反向（给 int 开位）抑制不了 NAMED 行判定 | (方法名 × 类型行) 二维判定 |
| 29 | dyn | `:2090-2106` ←`:2085-2101` dyn 方法分派 | 结果规则（早退 `TI_UNIT`） | 谓词 = **dyn 行同一性**（非许可）；`IP_METHOD` 在 `AK_NAMED` 也为 1 ⇒ 换成 `permits != 0` 会把 struct 方法调用误吞进 dyn 早退分支（返回 unit）= 大面积行为变化 | — |
| 30 | dyn | `:2508-2511` ←`:2498-2502` `EXPR_LET` 建 dyn 集 | 结果规则 | 无拒绝路径 | — |
| 31 | dyn | `:2689-2697` ←`:2674` `EXPR_ASSIGN` 建 dyn 集 | 结果规则 | 同上 | — |

### A.3 P3 裁决点登记（实施前须定 / 须先补）

① **`iface_satisfies` 未交付**：P2b 范围明标「零调用者，P3 落地 impl 语义时才有对象」（spec §2.5）。⇒ 本计划 Task 2/6 与 Task 5 的 `T: I` 半边**开工前先补条目 + 满足判定**（三态 1/0/-1，不得静默当 0）；已就位底座 = `iface_of_term`（类型项 → AK，单原子/-1）、`iface_kind_of`（行 → AK）、条目表 13 类。
② **`name_ni` 列 = `-1`**（T1 登记偏差）：`.ccr` 的 STR 段 = 编译期 `g_strs` **全量**（`ccr_io.cr:537`）⇒ 在 `iface_registry_init`（`init_types` 尾部、每编译一次）里 `str_intern("product")` 之类会把 13 个新串追加进 `g_strs` ⇒ `.ccr` 逐字节变（控制组实测：未用标识符 `zzz_probe_unused_ident` 确实进 STR 段）。⇒ **首个消费者（P3 诊断/显示）落地时裁决**「是否接受 .ccr STR 段增长」；此前在本表初始化路径加 `str_intern` = 打破 P2b 硬判据。
③ **`TY_DEX_S`（码 8）不入 `ty_code_to_ti`**（T6 §6.1）：两处基型分支现状对码 8 落 `TI_UNIT`；入表 = 若该码可达即行为变化（selftest `t6.R_dex_s_unit`/`t6.C_dex_s_unit` 把现状钉红）⇒ 需 8 个站点各加排除，净收益负。实测：`TY_DEX_S` 仅现于 `init_types` 位置公理（`checker.cr:253`）+ 定义 + 注释；parser 只产 7 个类型名码。
④ **`never` 单元格：调用位点 = unit，类型位点 = never**（T6 §5，插桩实测**可达**）：`res_call_type` 侧显式保留 `|| tv == TY_NEVER`（`checker.cr:1394-1398`）；`fn g[T](a: T) -> never` 的调用结果按 unit 参与检查（`@raw_int` → TF07 实测；32 档语料 + 自源命中 0 次——真实源码无 `never` 类型位）⇒ **语义裁决**（never 形参/返回在调用位点应如何参与），P2b 按 spec §4 裁决 6 停下上报、未顺手改。
⑤ **「全许可列」= 11 个 op 位 × 13 类 = 143 格**（比较 6 + `NEG`/`NOT`/`REF`/`DEREF` + `AS`）：现状**无拒绝路径**（T4/T5 探针 32+44 例零拒绝）⇒ 表位已置 1、无门可换（本批不接线）。每位收紧建议见 findings §12。⚠ 任务简报记「20 个全许可列站点」——**本报告无法复现该计数**：实测口径 = 11 位（比较 6 / 一元 4 / 转换 1）、未接线站点合计 **31**（A.2 逐条）。
⑥ **字段面 / 转换面：无任何拒绝路径**：`EXPR_FIELD` 全形 rc=0 零诊断（落空 `return TI_UNIT`，`checker.cr:2613`）、`EXPR_AS` 除 PTR 结果规则外恒等透传（`checker.cr:2953`）⇒ `IP_FIELD`/`IP_AS` 现为**恒真门**；P3 加诊断后才是可推翻判定（A.2 #23/#25）。
⑦ **dyn 面：谓词非类级位**（A.2 #28/#29）；另有 **dyn 位图 64 上限**（`union_bitmaps` 与 `validate_dyn_method` 的 `ti >= 64` 钳位；spec §3.3 已登记）。
⑧ **索引侧「须 int」位缺失**：`idx_ti`（`checker.cr:2618`）推断后**无消费者** ⇒ `a[true]` rc=0。`IP_INDEX` 是**容器侧**位（ANY 语义），不能兼职索引侧（须 ALL 语义的「indexee」位）⇒ 新位 + 新门属 P3 设计面。
⑨ **枚举域无条目**：注册表 13 类**无 `AK_SUM`/`AK_FN`**（checker 侧 enum 类型行 = `TYP_NAMED`；`iface_kind_of` 对全部 NAMED 行回 `AK_NAMED`）⇒ 本计划 Task 3/4（穷尽性/联合）经 `sh_enum_domain_term` 走桥接展开，**不要**在注册表查「sum 原子」；若要在条目层表达 sum，须先扩 `iface_kind_of` 的命名行分派（需要行→声明的查询，即 Task 0 Step 2 的 `find_enum`）。
⑩ **性能面（如实登记）**：单次判定 = `iface_kind_of` + `iface_entry`（13 条线性扫）+ 位构造循环；三处登记（T3/T4/T5 报告）均判「无编译耗时回归证据」。P3 若把判定面扩到热路径（索引/迭代/字段），先看编译耗时再考虑 `(ak → entry)` 快表。

### A.4 表 / 注册表结构事实（P3 扩展前必知）

- **条目布局** 40B/条 × 5 字段 `{ak, ti_row, name_ni, lit_code, ops}`（`iface_registry.cr:44-48`）；`ti_row` 仅 8 原生有值，**结构/命名类 = -1 = 类级**（类级/行级不得混同——selftest 有专例）；`lit_code` = AST 字面量 kind 的字典；`ops` = 许可位集。
- **位下标**：`OP_*` 直用（1..19）、`UOP_*` **+20 偏置**、`IP_INDEX=25`/`IP_INDEX_RANGE=26`/`IP_FIELD=27`/`IP_METHOD=28`/`IP_AS=29`/`IP_COND=30`/`IP_COND_BOOL=31`。常量在 **`globals.cr:254-271`**（**必须在 globals.cr**：变量/常量跨文件按声明序可见，`checker.cr` 在 `iface_registry.cr` 之前；函数不受限）。`iface_bit` = 乘 2 循环（本语言无移位）；`iface_permits(op<0 || op>62)` → 0（不回绕；≥63 会把 i64 推负 = 全位命中）。
- **三态纪律**：`iface_ops(未知/-1)` = 0、`iface_kind_of(负/越界)` = -1、`iface_lit_ti(非字面量 kind)` = -1；`iface_of_term` 仅 `TT_ATOM`/`TT_TOP_K` 回 AK，其余 -1。
- **初始化**：挂 `init_types()` 尾部（`checker.cr:257` 区）——幂等 + **不缓存行号**（长驻 corelsp 每请求 `init_types`）⇒ P3 新字段照此；**不得**在初始化路径 `str_intern`（见 A.3-②）。
- **桥接单源化**：`sh_base_ak`/`sh_native_ak` 委托 `iface_by_ty_code`（唯一实现；`ty_shadow.cr:72-89`）；`sh_native_ak` **保留** `get_type_kind != TYP_BASE → -1` 门（`sh_native_ak(TI_DYN) == -1`——DYN 行经 `sh_term_of_ti` 的另一分支；**不得**直接换成 `iface_kind_of`）；`sh_*_ak_legacy` 为对拍对照物（P5 删，TODO #24-④）。
- **单表 `ty_code_to_ti`**（`iface_registry.cr:259-270`）：8 码逐项 + 域外 -1；**码 7 格 = 现状数值撞车原样保留**（`TY_GENERIC_PARAM=7` 与 `TI_DYN=7`；`parser.cr:98` 对 `dyn` 正产码 7 ⇒ 可达、N08 判据依赖）——归 P4/P5 命名空间分家，**P3 不得改**。
- **语义分派守卫**（P1 血泪：AK/TI 下标不 1:1）：AK↔TI 一律按语义逐项写死（`AK_STRING↔TI_STR`、`AK_BOOL↔TI_BOOL` 错位书写）；守卫用例 `iface.dispatch_no_index_shortcut`——**任何新映射不得按数值直传**。

### A.5 事实表指针

侦查 §2 九条现状宽松面 → 表中格 → 现状诊断 → P3 收紧建议：**findings 文档 §12「P2b 后：公理区事实表」**（本附录所在提交同批新增）；P3 各任务的「旧接受 → 新拒绝」登记表照其口径逐条填。

---

## 附录 B：R2 P3a 收官交接包（2026-09-12；**P3b 开工前必读**）

**范围与来源**：P3a = Task 0/1/3/4/5 的**非接口半边**，提交链 `61d3a8b4`→`ef61f002`→`e9818d62`→`c8c7731b`→`9c0a83ec` + 本附录所在收官提交。**P3b 三件全部未开工**：Task 2（横切接口）/ Task 6（impl 契约）/ Task 5 的 `T: I` 满足半边。本附录 = 五份任务报告（`.superpowers/sdd/p3-task{0,1,3,4,5}-report.md`）**逐条聚合**（不重新推导）+ 收官复验；数字出处 = 各报告 §2/§3，复验出处 = 收官报告（`.superpowers/sdd/p3-task7-report.md`）。

### B.1 P3b 阻塞项与接线点（唯一阻塞 = `iface_satisfies` 未交付；附录 A.3-① 状态至今未变）

| # | 件 | 阻塞形态（P3a 末实态） | P3a 侧已就位的接线点 |
|---|---|---|---|
| 1 | Task 5 的 `T: I` 半边 | 用户接口约束**一律 -1 不判**（结构/枚举实例化点零诊断）；函数调用点**回落**既有 `check_iface` 名拼接路径（逐字未动，`iface_ops`/`test_impl` 零回归） | `checker.cr` `gen_constr_satisfied` 首分支（`find_iface(c_ni) >= 0 ⇒ -1`）——`iface_satisfies` 交付后**改这一处**即全覆盖；`sh_iface_shape_term` = Task 0 占位（恒 -1） |
| 2 | Task 2 横切接口 | 形状条目（`sequence<⊤>` / 只读 / 可写 / 可索引 / 可迭代 / product）不存在；索引/切片/迭代的 `get_type_kind` 直比未换位 | `ty_variance_of`（T1：只读协变/可写不变已在引擎侧表）+ `sh_seq_term`（固定性位）+ `sh_struct_term`/`sh_enum_domain_term`（T0 展开层，一层深度） |
| 3 | Task 6 impl 契约 | 接口签名仍裸 `TY_*`（`g_ifaces` 布局未动 ⇒ 签名**无法表达**命名/泛型类型）；`check_iface`/`check_impl_for` 未接引擎；mangling 未退役；方法 16/参数 8 上限未处置 | `sh_iface_shape_term`（占位）+ `iface_registry.cr` 条目表（5 字段，**无变型规则字段**——T1 口径 = 变型表留引擎侧，条目字段后挂引用） |

**开工顺序建议**：先补 `iface_satisfies`（三态 1/0/-1，不得静默当 0；零调用者 → 首个消费者）→ Task 6 Step 1 签名类型项化（**形状项构造的前提**）→ Task 2 形状条目 + 消费点换位 → Task 5 半边接线（`gen_constr_satisfied` 一处 + `sh_iface_shape_term`）。**继承的硬口径**：新硬错误先全语料 report-only（Global Constraints 第 6 条）；`.ccr` STR 段约束（A.3-②：初始化路径**不得** `str_intern`）；三态纪律（-1 不当 0/1）。**新裁决面**：P3a 的 `AK_NULL` 不进 `iface_registry`（`iface.count == 13` 为判据硬值）——若 Task 2 形状面要覆盖 `T?`/`null`，须先裁「条目表扩列 vs 引擎侧另表」。

### B.2 P3a 收紧/放宽统一台账（逐条 = 旧 → 新 + 处置；**汇总：收紧 18 · 放宽 8 · 诊断面新增 1 · 实例名忠实化 6**）

**收紧（「旧接受 → 新拒绝/新诊断」）——T0 = 0 条（纯新增 502/0，三面零差异）**

| 任务-# | 用例 | 旧 → 新 | 处置/依据 |
|---|---|---|---|
| T1-1 | pA `return b[0..2]`（切片当 `[int;3]` 用，视图→固定） | rc=0 → **rc=1** `TF01` | **计划 Step 3 明令翻转**：P2a 引入的静默放宽在本批关闭 |
| T1-2 | pF `struct S { a: [int;3] }` ← 切片值（字段位） | rc=0 → **rc=1** `TS03` | 同一规则的自然外延（站点 9） |
| T1-3 | pIf1 `if c { arr } else { sl }`（合并结果位） | rc=0 → **rc=1** `TC02` | 结果类型 = then 侧 ⇒ else 须不弱于它（参序归一） |
| T1-4 | pN3 `return [s, s]`（嵌套 `[[int;3];2]` ← 切片元素） | rc=0 → **rc=1** `TF01` | 嵌套位同律（6 个递归位全覆盖） |
| T1-5 | pE1 `&mut int` 实参 → `&int` 形参 | rc=0 → **rc=1** `TF01` | mut 入参数链 = 判定维度（等式语义，非 Rust 单向） |
| T1-6 | pE2 `&int` → `&mut int`（反向） | rc=0 → **rc=1** `TF01` | 反向同拒（计划 pE 原文） |
| T3-1 | p1 缺臂 match（`{Red, Green}` 缺 Blue） | rc=0 + 产物 → **rc=1 + 无产物** | `TM03` 硬门（report-only 先行，清单空后开门） |
| T3-2 | p1b 缺臂且运行值 = 缺失变体 | rc=0 + 产物 / 运行 rc=100（静默 0）→ **rc=1 + 无产物** | 静默误编译面的直接证据 |
| T3-3 | p4 payload 变体缺臂（Third 缺） | rc=0 + 产物（静默 0）→ **rc=1** | 变体身份粒度同律 |
| T3-4 | p8b 无臂 `match c { }` | build rc=0 + 产物 → **rc=1** | 未覆盖面 = 全域 |
| T3-5 | p17 枚举形参位缺臂 | rc=0 + 产物 → **rc=1** | 非构造器来源同律 |
| T3-6 | p20b 用户 `enum Option[T]` + `int?` 缺 `None` 臂 | rc=0 → **rc=1** | 声明枚举即入域判定（T4 后与 `T?` 行身份分家） |
| T4-T1 | p8 `fn f(x: Option[int])`（无用户声明 Option） | rc=0 零诊断 → **rc=1** `N09`（**软**：build rc=0） | 退役内建 Option 注册的直接后果（spec §5.4 明令） |
| T4-T2 | p9 用户 `enum Option[T]`：`-> int?` ← `Option[int]` 值 | **rc=124（30s 挂死）** → rc=1 `TF01` | 旧态本身是挂死 ⇒ 净效果 = 明确拒绝（零语料命中） |
| T4-T3 | p13 用户 `enum Result[T,E]` 的 `v?` 解包 | rc=0（旧按**名字**解包）→ rc=1 `TF01` | 计划 Step 2 明令废「基名字符串」；结构解包只认 `TYP_OPTIONAL` |
| T5-T1 | p04 `struct Box[T: int]` + `Box[string]` | chk=0（约束被丢弃）→ **chk=1** `TG02` + 反例 `string ∩ ¬int` | 结构泛型约束保留 + 实例化点判定（零语料命中） |
| T5-T2 | p05 `enum EBox[T: int]` + `EBox[string]` | chk=0 → **chk=1** `TG02` | 枚举侧同源（同一 `gen_inst_constr_check`） |
| T5-T3 | p02 `fn f[T: int]` 以 `f("s")` 调用 | chk=1（**仅** TF01）→ chk=1（**+ TG02**） | 码集合扩张，**rc 不变 ⇒ 非硬门变化**（旧态约束被 `check_iface` 路径吞掉） |

**诊断面新增（rc 不变）**：T3-p11 重复臂 → `error[TM04] Redundant match arm`（**软面**，评估后不升硬门；升门须重跑全语料 report-only）。

**放宽（「旧拒绝/不可用 → 新接受」）——T0/T1/T3 = 0 条**

| 任务-# | 用例 | 旧 → 新 | 说明 |
|---|---|---|---|
| T4-L1 | p1 `fn g() -> int? { return 5; }` | rc=1 `TF01` → **rc=0** | `T ⊆ T?`（判定点可选目标注入） |
| T4-L2 | p2 `-> int? { return None; }` | rc=1 `N01` → **rc=0** | `null ⊆ T?` + `None` 可解析 |
| T4-L3 | p3 `-> int? { return Some(1); }` | rc=1 `N01` → **rc=0** | `Some` 可解析；行 = `int?` |
| T4-L4 | p4 `x: int? = 5; x = 3;` | rc=1 `TA01` → **rc=0** | 赋值位注入 |
| T4-L5 | p7 调用位 `fn f(v: int)` ← `int?` 实参 | rc=1 `N01` → rc=0 | **不是语义放宽**（构造器可解析而已）；调用位点仍**无检查**（#20/#32 姊妹面） |
| T4-L6 | p12 `match x { Some(v) => v, None => 0 }` | rc=1 `N01` → **rc=0** | 两臂覆盖 = 穷尽（可选域接入 TM03 判定） |
| T4-L7 | p14 用户 `enum Option[T]` + `x: int? = Some(5)` | **rc=124（挂死）** → **rc=0** | 挂死根因（`Some(x)` 实参链契约）修复 |
| T5-L1 | p09 `take(1, 2)`（F4 假拒） | chk=1 `TF01`（假拒：T 未绑定）→ **chk=0** | F4 修复的正确性正控（实例名 `take[int,int]` → `take[int]`） |

**实例名忠实化（T5，rc 全同）**：S1 `f[unit]`（折叠！）→ `f[A]`+`f[B]`（**反折叠**，计划 Step 4 要求实证的折叠缺陷）· S2 `id[unit]` → `id[S]` · S3 嵌套实例 `inner[A]`+`outer[A]`（克隆期绑定重映射）· S4 `take[int,string]` → `take[string]`（按形参声明序） · S5 `f[unit]` → `f[S]` · S6 元组实参 = **未覆盖面**（复合实参无语法形态 ⇒ 回落旧名串，同值）。

**挂死修复面（2 端）**：T4-T2（30s 超时 → 明确拒绝）· T4-L7（挂死 → rc=0）——同一根因（`Some(x)` 实参链契约 + `sym_*` 越界读）的两个出口。

### B.3 语料全扫证据（逐任务；**站点覆盖与差异数同报**——P1 交接硬性要求）

语料 = 72 档（`tests/suite` 32 + 自源 2 + 后端/kernel 15 + stdlib 19 + examples 4），逐档 `clean-cache`，cwd = 仓库根；对拍形态 = **旧二进制 × 新源 vs 新二进制 × 新源**（同源双编译器）。

| 任务 | 对拍结果 | 影子判定数 | 新能力面语料命中 |
|---|---|---|---|
| T0 | check/shadow/dump 三面 `diff -r` **空** | 29,090 / agree 29,090（全计数 0） | 展开层零命中（本批零生产消费者） |
| T1 | 三面 `diff -r` **空** | 29,267 / agree 29,267（全计数 0） | array↔slice 方向/变型/mut/嵌套固定性零命中 |
| T3 | check 面**仅 2 处行号位移**（既有 TF01 误报随新增源码行漂移；诊断集合/条数/rc 全同）；shadow/dump 空 | 29,442 / agree 29,442（全计数 0） | 语料**零 match、零 enum 声明** |
| T4 | check 面逐档**诊断码集合与 rc 同**（3 档自源行号位移）；shadow dump 与 T3 逐字节同 | 29,687 / agree 29,687（全计数 0） | 语料零 `T?`、零 `Some`/`None` |
| T5 | 同源对拍 **0 档差异**（rc + 诊断码 + 逐条消息含行号全等） | **30,338** / agree 30,338（全计数 0）；dump 与 T4 逐字节同 | 语料零泛型约束语法 |
| 收官 | 终态复跑（本轮实测）：check/shadow/dump 三面 `diff -r` **空**；rc 分布 33×rc=0 / 39×rc=1（两二进制同） | **30,128 / agree 30,128**（全计数 0）；站点直方图 `assign-node=22785 · fn-body-ret=5338 · if-branch=1971 · struct-field-type=28 · array-elem-type=4 · generic-apply-base=2` | — |

> **判定数 30,338（T5）→ 30,128（收官）的 −210 已精确归因**：唯一来源 = 附录 B.6 的修复（删 target project 的 `import monomorph`）⇒ monomorph.cr 退出 target `main.cr`/`_import.cr` 两档的导入闭包——逐档切换实测 3577→3472 与 3542→3437（各 −105，合计恰 −210）；语义面零变化由「同源对拍空 + 两档 N06 33→0」双证。

**站点覆盖（五任务口径一致）**：`assign-node` / `fn-body-ret` / `if-branch` 为主流量；`struct-field-type=28` · `array-elem-type=4` · `generic-apply-base=2`；**站点 1（hotpatch-ret）/ 2（generic-arg）/ 4（unify-fallback）/ 6（assign-binary）语料零命中**。⇒ P3a 全部新能力面**语料零命中**，其上表「零差异」**不是**新能力正确性证据——正确性由各任务的**行为探针**（T1 19 例 / T3 22 例 / T4 14 例 / T5 16 例）+ 用例表（288 例）+ 新套件（16+12+14 例）+ 突变控制承担。

### B.4 逐条登记面（出处 → 现状 → 影响 → 建议；P3b 或后批消费）

1. **`save_func_gen_constrs`（函数侧）稀疏零初值同族风险**（T5 §7-②）：struct/enum 侧已修（空槽预填 -1），**函数侧未改**——其唯一读者 `infer_gen_call` 以 `iface_ni >= 0` 判有效，同一「空槽读成 0 = 合法名字 ni（首个驻留串）= 凭空约束」风险在库；改动会触既有 `test_iface_ops` 基线 ⇒ 建议**单开**（若 P3b 动 `infer_gen_call` 的约束循环，**先修此处**）。
2. **`never` 不满足原生约束**（T5 §7-③）：引擎 `AK_NEVER` 是与 `AK_INT` 互斥的**原子**（非 ⊥）⇒ `gen_constr_satisfied(int, never) == 0`；同源面 = `never ⊆ T?` 不给（T4 §7-⑩）、`never` 调用位点 = unit / 类型位点 = never（附录 A.3-④）。**语义裁决项**，P3b 不动引擎即保持现状。
3. **命名实参 vs 原生约束 = -1 不判**（T5 §7-③）：`struct Box[T: int]` + `Box[S]`（S = struct）零诊断——根因 = 引擎 `AK_NAMED` 不展开（P0 未覆盖面②；T0 的展开层**故意**只服务满足判定/域查询）；`Box[string]` 这类可判的照拒。⇒ 若 P3b/P4 要闭合，须裁「满足判定侧启用展开」（**不得**动等价面）。
4. **MAX_GENERICS = 4 未解除**（T5 §0-②，显式登记）：>4 现状 = parse 期硬报（`P01`/`TA08`，非静默截断）；解除面 = struct/enum 表 4 槽布局 + `ESZ_*` + `parse_generics_into` + `ccr_io` 零写槽；语料最大 2 ⇒ 零收益零容忍成本，归单开批。
5. **`EXPR_LET` 无任何兼容检查**（T1 §6-① → TODO #32）：`x: [int;3] = s;` / `x: [int;4] = [1,2,3];` / `x: int? = 5; y: int = x;`（运行 rc=5）全部 rc=0——**本站不是既有 10 判定点之一**，追加即「新判定点 + 新硬错误门」⇒ 须 report-only 专批；与 #20（调用位点无诊断）互为姊妹面（T4-L5 同源）。
6. **运行期表示未统一**（T4 §7-③）：`Some(1)`/`None` 走 `IR_MAKE_ENUM` 对象 + tag，`T?` 槽里的**裸值**仍是裸值 ⇒ 同一 `T?` 变量可持两种表示（`x: int? = 5; match x { Some(v) => …, None => … }` 走 `None` 臂）。需 ir_gen/后端 + 表示决策（后续批）。
7. **枚举变体数/载荷数 >16 越界写**（T4 §7-⑥，既有）：parser 写 `OFF_EI_VARIANTS + vc*OFF_EV_SIZE` 与载荷列 `+ tc*8` **无上限闸**（`MAX_ENUM_VARIANTS`/`MAX_VARIANT_TYPES` 仅 `.ccr` 读回侧检查）；修法照 TODO #8 先例（parser 硬错 + 访问器护栏，P020 式）⇒ **先 report-only**。**同族 MAX_* 处置总口径**（本批新登记）：MAX_ENUM_VARIANTS/MAX_VARIANT_TYPES（本条）、MAX_GENERICS（上条 4）三者均属「表布局定长槽 + 无写入闸」族，统一按「先加护栏、再评估解除」办。
8. **不可判面清点**（T3 §6-④ + T4 §7-⑩）：match 面四条（非枚举域 / 不可映射模式（字面量·struct 模式·未声明名·异枚举限定名）/ 引用 scrutinee / `T?` 无声明枚举——T4 后 `T?` 已入判定，仅「无声明枚举」的旧口径失效）；可选域模式名**只接裸名**（`Option.Some` ⇒ 不可映射 ⇒ 不判）；`TYP_NULL` 的 `EXPR_TRY` **不解包**（保守）；`type_compat_sym`（hotpatch 站）**无**可选注入；`iface_*` 对 `TYP_OPTIONAL`/`TYP_NULL` 行回 **-1**（门全拒 = 保守面）。
9. **空枚举域 = 空洞穷尽**（T3 §6-③，计划原文「= 0」的偏差登记）：域 = ⊥ ⇒ 反例集恒空 ⇒ 判穷尽 = **1**（不报错是正确行为）；源码面 `enum E { }` 可写（`EC_P_ENUM_EMPTY`(P009) 有定义未见 raise——既有事实）。
10. **空递归保守**（P0 引擎未覆盖面③，P3a 未动）：`μX.X` 按深度守卫回 -1；P3a 新增面（变型/展开/联合）均在预算窗口内（`ty_budget_reset(200000)` 前后隔离，照 `type_equal_engine`）。
11. **符号档长度约束未实现**（计划 §侦查 3 / #19 的 P3 面遗留 → 本批收口口径）：**符号档 = VC 义务，本计划不实现，显式登记**；动态档 = 既有运行期检查（`g_ir_slice_lens` + `IR_BOUNDS_CHECK`）+ checker 字面量界检查（R1 已落）。
12. **bootstrap `&&`/`||` 不短路 = 根因仍开放**（T0 §5-③；T4 §7-④ 只关了「`g_syms` 未分配」触发链：`sym_*` 四读取器加范围闸）：短路是**前端**行为（自托管 `ir_gen` 分支化，D11 实证），而 **Python bootstrap 的 `ir_gen.gen_binary` 两侧无条件求值** ⇒ 由它构建的编译器二进制自身按「两侧均求值」执行；生产路径 `g_syms` 必已分配 ⇒ 无外部表现，但任何 `guard && 表读(idx)` 形态在「表未分配」通道可崩。修法 = bootstrap `ir_gen` 分支化（或全线护栏化该形态）。
13. **`EXPR_ENUMPAT` 名字槽 = `ast_a`**（T3 §6-②，实测踩坑）：任何新消费 `EXPR_ENUMPAT` 的代码必须用 `ast_a`（`ast_int_val` = `EXPR_IDENT` 的约定，两套并存）；**selftest 夹具与 helper 同错自洽**曾致 report-only 假绿——行为探针（真 parser 输入）是唯一抓手。
14. **witness 项含空析取支**（T0 §5-② / T3 §6-①）：缺变体时 `ty_exhaustive` 的 witness = `(A∩¬A)∪(B∩¬A)`（`tt_norm` 不净化）；实测 `ty_equiv(witness, 缺失变体) = -1`（未覆盖面）、`ty_sub(w,B)=1`、`ty_inhabited=1`。⇒ **反例命名走覆盖位**（T3 实现）；若后续净化 `tt_norm` 或改 `ty_exhaustive`，须同步 `t3.counterexample_named_variant` 的四个断言。
15. **引擎侧无「链元素皆类型项」不变量**（T1 §6-②）：不变槽「确定不等价 ⇒ 0」的加强**依赖**该不变量（展开项/桥接项/令牌混用同一链空间）；本批以「非同形 = -1」保守（令牌已原子化消除混读风险）。
16. **只读序列视图第二层协变未做**（T1 §3.3-6/§6-④）：`&[int] ⊄ &[int∪str]`（序列构造子自身不变）；spec §5.1 的「只读序列视图协变」在本批以「只读 ref 元素协变」兑现——若 Task 2 形状面要闭合，须引入只读序列形状。
17. **复合实参实例键兜底**（T5 §7-③）：元组/嵌套应用无语法形态 ⇒ `inst_type_node_of_ti` 单槽根契约不成立 ⇒ 键走行号兜底 `#<row>` + 替换回落名字路径；`gen_remap_binds` 的「全具体」前置不满足时**整段放弃**（回落旧名串，不发明半解实例）。`ir_gen.cr` 的 `find_or_create_mono_func` = **死码**（零调用者）且其 `int_val` 旧语义已改（绑定段起始 +1）——若复活**必须先改**（T5 §7-④）。
18. **`monomorph.cr` 已迁出 corearch 清单**（T5 §0-③）：理由 = 本批类型项化需 checker/parser 层符号，corearch 侧对它零代码引用（逐符号核对）；唯一产物面影响 = corearch 二进制不含该段死码（**corearch 二进制 sha 不是本计划判据**——T0 §5-④ 同款说明；ELF canary + 全回归 + 自举链为安全面证据）。
19. **性能面**（T1 §6-⑤ / A.3-⑩ 口径）：P3a 未做基准测量；新增判定路径均在预算窗口内且主流走节点同一性快路径（`p == q`）；若 P3b 把判定面扩到热路径（索引/迭代/字段），先看编译耗时再考虑 `(ak → entry)` 快表。

### B.5 交 P5 的继承项（并入 TODO #24/#30 清单；**P3a 后状态更新**）

- **`type_equal_legacy` 删除归 P5**（双用：对拍对照物 + unknown/桥接回落实现）——**状态更新**：P3a 未减少其调用面（T0 的展开层按设计**只**服务满足判定/域查询，等价面仍原子名义）；⇒ #24 的「unknown 清零前提 = 引擎命名展开」**不会被 T0 满足**（那是等价面的展开，属**裁决**而非欠账）：P5 须先裁「等价面是否接受命名展开（会推翻 P2a 对拍基线）」或「接受 legacy 长期化」。
- **`sh_native_ak_legacy`/`sh_base_ak_legacy` 删除归 P5**（仅 `type_selftest.cr` 三例引用，删时同步调整）。
- **站点 6（assign-binary）挂点去留**随 P5 站点面清理（P3a 未动站点集合）。
- **影子层（`--type-shadow` / `g_shadow_map` / `replace_*` 计数）与 legacy 同族**，P5 一并下线；P3a 全程复用该通道做对拍（其站点覆盖口径**不得**当新能力证据——见 B.3 声明）。
- **`tt_display`/`tt_display_at`（T5 新增反例文本）零 `str_intern`**：若 P5 允许 `.ccr` STR 段增长（A.3-② 的后续裁决），此处是首批可选改造点（当前为守判据而用逐字比较）。
- **MAX_* 族统一处置**（见 B.4-7）与 **`iface_satisfies` 交付后的条目表扩列裁决**（见 B.1 末）——两者均属 P4/P5 载体面（.ccr TYPE/IFACE 段）的输入。

### B.6 收官发现并修复的回归：project-mode 清单漏改（Task 7；**后续批同类面必查**）

**现象**：`tests/selfhost/test_backend_bootstrap.py`（stage0 = `corec build src/targets/x86_64-linux -o … --static -O 0`）rc=1——`[FAIL] stage0 builds corearch stage1: exit 0 but build log carries 33 error[ diagnostic line(s)`，全部为 `error[N06]: Undefined function`（`get_type_kind`/`get_type_data`/`get_type_extra`/`alloc_node`/`alloc_type`）。

**根因**：Task 5 把 `monomorph.cr` 从 corearch 的 **concat 面**清单（`build_selfhost_native.py` `backend_support_files`）迁出，但**漏改 project-mode 面清单**——`src/targets/x86_64-linux/_import.cr` 的 `import monomorph` 仍在。Task 5 给 monomorph.cr 的类型项化引入 checker/parser 层符号（46 处），而 project-mode corearch 单元集不含该层 ⇒ 33×N06 **静默未定义**（rc=0 + 产物照出；stage 链互测不可见，正是该门要拦的类）。

**为何 P3a 期间不可见**：唯一守卫 = `test_backend_bootstrap.py` 的 project-mode `error[` 门，而该套件**未挂 CI**（TODO #31：`selfhost-tests` 挂 18/42）⇒ 5 个任务的回归面都没跑到；收官全量枚举（42+7 逐档）首次暴露。**同类面**：`build_selfhost_native.py` 与 `_import.cr`（project）是**双注册**关系（文件头注记自陈），任何「清单增减」改动必须**两面同改**。

**修复**：删 `src/targets/x86_64-linux/_import.cr` 的 `import monomorph`（证据与 concat 面同一：monomorph 在 corearch 链接集**零代码引用**——全部定义符只出现在 globals.cr 注释里；文件头注记落案）。**复验**：该套件 rc=0（stage1/2/3 逐字节同 + smoke/O2 smoke 全绿）· project-mode 构建日志 `error[` **33 → 0** · ELF canary `95084e7b…d475` 不变 · 三二进制（corec/corearch/corelsp）sha 不变（该文件不入任何 concat 清单）· 全量枚举终态 **49/49 rc=0**。

**给后续批（P3b 尤其 Task 6 的清单改动）**：① 动 `build_selfhost_native.py` 的任何清单 = 必须同步核 `src/targets/x86_64-linux/_import.cr` 与 `src/compiler/_import.cr`（两面）；② 每任务回归面**必含** `test_backend_bootstrap.py`（或先把它挂进 CI——#31）。
