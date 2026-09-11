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
- [ ] **Step 6: 提交**（路径限定）

## 自检记录

- **spec 覆盖**：§5.1 定长/序列/长度约束 → Task 0/1/2；§5.2 泛型 → Task 5；§5.3 impl → Task 6；§5.4 穷尽性/联合/可选 → Task 3/4；§9 P3 行五项目标能力逐项有落点；`TODO.md:446` fixed-array-retire 的「未办 = 类型身份退役本身」由 Task 1 收口（枚举了 5 条读码事实，非猜）。
- **占位符扫描**：无 TBD；两处**决策点显式登记**（Task 4 的 `null` 原子承载、Task 5 的 MAX_GENERICS 解除或登记）——均为"实施前须定"，非「稍后填」。
- **命名一致性**：`sh_struct_term`/`sh_enum_domain_term`/`sh_variant_term`/`sh_iface_shape_term`/`ty_variance_of`/`sh_seq_term`/`iface_satisfies` 在任务间一致；`iface_satisfies` 为 P2b 交接契约名。
- **数字口径**：95 = 实测（`grep -c "fails = fails + ts_check("` = 95）；26,989/67 文件 = findings §11 实测；pA-pD 四探针 = 本计划实测（2026-09-11）；其余「≥N 例」为计划下限（可增不可减）。
- **风险面**：① **展开层裁定**（Task 0 的「仅满足判定展开、等价不展开」边界）——裁错 → 判定全面漂移 + 推翻 P2a 基线（缓解：影子对拍逐任务归零 + 名义不变量用例）；② **pA 类静默放宽**（已实测在库：切片→数组）——本批收紧即修，须走收紧清单 + report-only；③ 穷尽性硬错误影响用户 rc（缓解：语料零 match + report-only 先行）；④ monomorph 实例键变更（`.ccr`/SYM 变化 + 折叠缺陷修复可能改变既有实例数——实测报告）；⑤ **P2b 依赖项阻塞**（Task 2/6 + Task 5 半）——分批交付（P3a 先行、P3b 待 P2b）。
