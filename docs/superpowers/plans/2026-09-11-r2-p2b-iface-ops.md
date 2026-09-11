# R2 P2（逐点替换 · 批 b）实施计划：`infer_expr` 公理区 → `iface_ops` 查表接线 + `res_type_node` 双份 TY→TI 映射合一

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `infer_expr` 的**内联类型公理区**（决定「操作是否许可 / 结果是什么类型 / 字面量定型」的硬编码特判）替换为**本质条目表 + 操作许可位集**的查表接线（spec §2），并把 `res_type_node`/`res_call_type` 的**双份 TY→TI 映射**合成单表（spec §4 步 3）；同时交付 P2 的查询 API `iface_*`（spec §2.5）——它是 P3/P4/P5 与下游 S-A/S-B/S-C/S-D 切片共同等待的「统一入口」。

**Architecture:** 三块，逐块独立可验收：
1. **注册表（新建 `iface_registry.cr`）**——13 条本质条目（8 原生 + product/sequence/ref/ptr/named）+ 操作许可位集 + 字面量定型码 + `iface_*` 查询 API。表是**静态数据**（不新增 `g_types` 行 ⇒ 不动 `.ccr` 类型段）。
2. **接线（`checker.cr` 三个面）**——① 字面量定型 5 处；② 操作许可（二元 11 条 / 一元 4 条 / 条件 3 条）；③ 容器面（索引 5 条 / 字段 4 条 / 转换 1 条 / dyn）。
3. **两表合一**——`res_type_node` 与 `res_call_type` 的基型分支合为 `ty_code_to_ti(ty)`；**顺带**把同族 6 处 TY→TI 内联链与「checker 行号 → 原子类」映射（现散在桥接层 `sh_base_ak`/`sh_native_ak`）也收敛到同一处，避免 P2b 自己制造新重复。

**接线口径 = 保语义（零行为变化）**：本批**只换寻址方式，不换判定结果**——表的每一格都是从现状代码**逐格转录**而来，且每格注上现状 `file:line`。任何「旧接受 → 新拒绝/新放宽」都**不在本批**（spec §4 裁决 6 的收紧处置属 P3 能力落地批，见 Global Constraints 第 4 条）。

**Tech Stack:** Core 自举栈；P0 引擎（`type_terms.cr`/`type_engine.cr` 的 `AK_*` + `tt_atom` + 判定 API）；P1/P2a 桥接与影子通道（`ty_shadow.cr`：`sh_native_ak`/`sh_base_ak`/`sh_map_*`/`--type-shadow`/分类计数）；P2a 判定替换面（`type_equal_engine`/`type_equal_legacy`/`type_compat_strict`/`array_len_constraint_ok`）；检查器 `checker.cr`；自测通道 `type_selftest.cr`（`corec selftest-types`）。

**Spec:** `docs/superpowers/specs/2026-09-10-type-interface-unification-design.md` §2（双轴注册表：本质轴字段表 / §2.4 衔接 / §2.5 查询 API）+ §4 步 3（逐点替换：`infer_expr` 公理区 → `iface_ops`；`res_type_node` 两表合一）+ §9 P2 行 (b) 部分。方向设计：`docs/superpowers/specs/2026-08-30-type-system-direction-design.md` 定案 2/3（int/dex/string/bool/dyn = **原生接口条目**（规则内建、用户不可实现）；一张 interface 注册表；检查器删类型特判、统一查表验证；**发射层原语映射不动**）。
**P2a 交接**：`docs/superpowers/specs/2026-09-10-type-shadow-findings.md` §11（P2a 后复跑：26989/26989 agree、站点 1/2/4/6 零命中、N 面须行为探针）+ TODO #24（P5 继承项 / 未覆盖面）。

**范围**：本批 = **P2b**（注册表建层 + 公理区三面接线 + 双份 TY→TI 合一 + 收官）。
- **不做**（明记，避免范围蔓延）：① 收紧任何现状宽松面（= P3）；② 横切轴（序列/可索引/可迭代接口）与用户轴（`impl`/`interface` 语义重定义、mangling 废弃）= P3（spec §2.2/§2.3）；③ `iface_size/iface_align`（尺寸/对齐 = 映射层/hw-map 领域，spec §2.1 明标「非语义」，且 `ir_gen.cr:279/462-463/514-515` 的 `type_size`/`type_align` 是发射面消费点）；④ `iface_satisfies`（三类统一满足判定——**零调用者**，P3 落地 impl 语义时才有对象）；⑤ 发射层：`ir_gen.cr` 的算子降级/字符串比较降级（`ir_gen.cr:904` 起）与 `type_size/type_align` **一律不动**（方向设计定案 3：`+` → addq 是机器知识，归 hw-map 编码层）；⑥ `AK_SUM`/`AK_FN` 条目（checker 侧无对应原子：enum = `TYP_NAMED`，见侦查 §4.1）。

---

## Global Constraints

- **jj only（含只读与复合命令一律不用 `git`）**；**提交必须路径限定**（多 agent 并行下全员含协调者）；所有命令 `nice -n 19`；判据前 `clean-cache` 且 **cwd = 仓库根**。
- **行为零变化面（P2b 的硬判据）**：接线前后 **ELF 产物逐字节相同**（`tests/suite/ptr_arith.cr` vs 基线，sha256 `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`）；影子开/关两态亦逐字节相同。
- **`.ccr` 面**：注册表是**静态数据表，不 alloc `g_types` 行、不改既有行号**（先例：`init_builtins` 的 `g_rt_builtin_*` 旁表不占类型行）⇒ `.ccr` **预期逐字节不变**（强于 P2a 的「允许变须实测」）。**必须实测并报告**（冷缓存）；若变 → **停下上报**（说明类型信息泄进了编码层/行号被扰动）。
- **保语义（本批的语义口径，硬性）**：表的每一格 = 现状代码的**逐格转录**，格注必须给出对应现状 `file:line`。现状的**宽松面**（侦查 §2 清单：比较不校验操作数、算术门「任一侧数值即可」、一元透传、索引类型不校验、字段落空静默、转换无校验）**原样保留为表的「全许可」格**——它们由本批**登记为 P3 收紧面**，不得在接线时顺手收紧/放宽（spec §4 裁决 6：收紧 = 改源码 + 逐处记录 + 语义争议停下上报）。
- **AK/TI 下标不 1:1（血泪，硬性）**：`AK_STRING=2` 而 `TI_STR=3`、`AK_BOOL=3` 而 `TI_BOOL=2`（`ty_shadow.cr:18-26`；P1 事故：照下标直传会把 bool↔string 静默错标且两侧同错自洽）。**注册表内任何「原子类 ↔ 类型行」的对应都必须按语义逐项分派，禁止数值直传**；守卫 = `bridge.str_ak`/`bridge.bool_ak`（`type_selftest.cr:208-209`）+ 本批新增逐条目用例。
- **表全局放 `globals.cr`**（bootstrap 名字解析对**变量**按声明序、跨文件前向引用不成立——`globals.cr:290-292` 的 `g_purity_inst` 先例）；**函数**的跨文件前向引用成立（既有事实：`checker.cr` 调后置文件 `ty_shadow.cr`/`type_engine.cr` 的函数）。
- **本语言无三元运算符、无移位运算符**；取模须非负；位集构造照既有乘 2 循环（`checker.cr:1830/1841/1853-1854` 的 `dyn_set_type` 惯例）；键比较不得依赖 i64 回绕；noclobber（用 `>|`）；比较 `.ccr` 前必须 `clean-cache`（TODO #5 家族：冷/热缓存态分歧）。
- **文件永久不允许还原；不得绕过。**
- **CI 挂点**：新测试须挂 `src/ci/run.sh` 的 `selfhost-tests`（该 job 是「已跑集」的唯一真源；不挂 = 不进判据）。

---

## 侦查底座（2026-09-11 实测；行号 = 本计划起草时点工作副本，**非 spec 时点**）

> **行号口径警告**：spec §11 的行号指修订 `a9d991908910`（`checker.cr` **2483 行**，已用 `jj file show` 核对）。工作副本现为 **3376 行**（P2a/P0/#25/#28/#29/纯度批等已落），**偏移逐段不同**（+521 于 `infer_expr` 头部、+648 于 `EXPR_AS`）。本计划**一律用实测行号**，需要跨文档对读处另注 spec 时点行号。

### 0. 交付物现状：`iface_*` **不存在**（硬前置）

`grep -rn "iface_kind_of\|iface_ops\|iface_satisfies\|iface_size\|iface_of_term" src/` = **零命中**（仅 `docs/` 出现；提及该 API 的 spec：设计 spec §2.5、`2026-09-11-semantic-safety-roadmap.md:122`、`2026-09-11-policy-injection-design.md:365`、`2026-09-11-policy-information-flow-design.md:316`、`2026-09-11-semantic-safety-obligations-design.md:497`）。⇒ **P2b 的首个交付 = 该 API 本身**（Task 1），不是「已有 API 的接线」。spec §9 P0 行已预先登记此项归属：「查询 API `iface_*` 属 P2 接线面，P0 只出判定 API」。

### 1. 公理区全量枚举（`infer_expr` = `checker.cr:1888-3061`，1174 行）

口径：**一条 = 一处决定「操作是否许可」或「结果是什么类型」的硬编码判定**。家族 × 条数 = **66 条**（下表逐条；= 5+8+1+1+2+4+3+5+5+5+1+4+4+15+3）。量度代理（同口径的可复核计数）：`return TI_<非 unit>` **49** 处 · `== TI_*`/`!= TI_*` **28** 处 · `get_type_kind(...)` 调用 **20 点/21 次** · `check_error` **36** 处 · `TYP_*` 提及面 PTR 9 / GENERIC_APPLY 6 / ARRAY 5 / TUPLE 3 / REF 3 / NAMED 3 / GENERIC_PARAM 3 / SLICE 2。

| # | 家族 | 现状行号 | 条数 | 内容（现状语义） |
|---|---|---|---|---|
| 1 | **字面量定型** | `:1892` `:1894` `:1895` `:1896` `:1897` | 5 | `EXPR_INT→TI_INT`／`EXPR_DEX→TI_DEX`／`EXPR_STRING→TI_STR`／`EXPR_BOOL→TI_BOOL`／`EXPR_CHAR→TI_CHAR`（spec 时点 `:1371-1376`） |
| 2 | **二元算术/指针/拼接** | `:1935`（组门）`:1937`（串拼接）`:1939-1941`（`*T±int→*T`）`:1942-1944`（`int+*T→*T`）`:1946-1948`（`*T−*T→int`）`:1950-1952`（合法性门）`:1953-1954`（dex 支配→DEX 否则 INT）`:1965`（兜底 INT） | 8 | 见侦查 §2 的宽松面 ①② |
| 3 | **比较** | `:1956-1958` | 1 | 6 个比较 op **恒返回 `TI_BOOL`、不校验操作数** |
| 4 | **逻辑** | `:1959-1964` | 1 | 两侧各须 `bool\|int`（**每侧独立**）→ `TI_BOOL` |
| 5 | **赋值** | `:1922-1932`（`OP_ASSIGN`）`:2638-2660`（`EXPR_ASSIGN`） | 2 | 站点 6（无生产点，TODO #17）/ 站点 8 |
| 6 | **一元** | `:1970-1972`（NEG/NOT 透传）`:1973-1993`（`UOP_REF`→`TYP_PTR`）`:1994-2006`（`UOP_DEREF` 三种分支）`:2007`（兜底透传） | 4 | `&x` 产 `TYP_PTR` 而类型位 `&T` 产 `TYP_REF` = **双表示并存**（spec §11 同记） |
| 7 | **条件/区间** | `:2265`（if 须 bool\|int）`:2376`（while 须 bool）`:2402-2403`（range 两端须 int） | 3 | |
| 8 | **索引** | `:2586-2603`（range→`TYP_SLICE` + F11 界）`:2605-2615`（ARRAY→元素 + F2 越界）`:2616-2618`（SLICE→元素）`:2619-2633`（STR→`TI_INT` + 字面量越界）`:2634`（`EC_TK_INDEX` 拒绝） | 5 | `idx_ti`（`:2583`）**推断后从未被使用** ⇒ 索引**类型**不校验 |
| 9 | **字段** | `:2513-2517`（REF 自动解引用）`:2519-2521`（APPLY 解包基型）`:2522-2563`（NAMED→struct 字段表 + 泛型实参代换 `:2538-2555`）`:2566-2577`（TUPLE `.N`）`:2578`（**落空 → `TI_UNIT`，无诊断**） | 5 | |
| 10 | **方法** | `:2022-2062`（module 限定调用）`:2064-2082`（dyn 方法）`:2083-2101`（NAMED→方法表 `g_methods`）`:2103-2146`（GENERIC_PARAM→约束 iface + **mangled 字符串**）`:2147-2160`（实参推断 + 返回） | 5 | mangling 废弃 = P3（spec §2.3） |
| 11 | **转换** | `:2892-2908` | 1 | `as` 仅处理 `TYP_PTR` 的 asp 传递（`:2897-2906`），其余**无合法性校验** |
| 12 | **dyn 面** | `:1825-1834`（写集）`:1836-1845`（读集）`:1861-1884`（方法校验）`:2066-2082` `:2643-2651` `:2473-2477`（三消费点） | 4 | 位图 **64 上限**（`:1829`/`:1840`/`:1868` 的 `ti < 64` 钳位；spec §3.3 登记「须解除或显式登记」） |
| 13 | **内建/外部调用定型** | `:2173-2177`（`syscall3/4`→INT，按名字）`:2195-2203`（SO 返回码→TI_*）`:2218-2225`（`g_rt_builtin_ret_types` 表）`:2238`（未知外部→`TI_INT`） | 4 | `:2195-2203` 是**第三份 TY 式→TI 映射**（`ret_code2 % 100`，`:2196`） |
| 14 | **`@builtin` 定型** | `:2946-3057` | 15 | `str_eq(name, …)` 15 处：`sizeOf`/`addr`/`alignOf`/`fields`/`hasField`/`field`/`typeInfo`/`raw_int`/`comptime`/`inline`/`no_bounds_check`/`fast`/`unroll`/`section`/`hotpatch` + 兜底报错 |
| 15 | **其它结构特判** | `:2359-2361`（await 数组→元素）`:2871-2888`（try：**按名字字符串**判 `Option`/`Result`）`:2341-2343`（go range→`TYP_ARRAY`） | 3 | `:2879` 的 `base_name == "Option"` 是名字特判（spec §5.4「不再依赖内建 Option 枚举名」= P3） |

### 2. 现状「宽松面」清单（**保真/收紧分界**；本批逐格转录，P3 才动）

逐条实测（读码 + 推演，**未**逐条跑探针——见 §6.2 待补），这些是接线时**最容易被"顺手修正"**的格子：

1. **比较不校验操作数**（`:1956-1958`）：`(1, "a") == …` / 结构体 `==` / 数组 `==` 一律收敛为 `TI_BOOL` 无诊断。
2. **算术合法性门是「任一侧」语义**（`:1950`）：`lt != INT && lt != DEX && rt != INT && rt != DEX` ⇒ **两侧皆非数值才报错**。故 `1 + [int;3]`（lt=int）**静默为 INT**；`"a" * 2`（rt=int）**静默为 INT**；`"a" * "b"` 才报 `EC_TB_ADD`。
3. **串拼接优先且单向**（`:1937`）：`op == OP_ADD && (lt == TI_STR || rt == TI_STR) → TI_STR` ⇒ `1 + "a"` 得 string。
4. **一元透传**（`:1970-1972`）：`-x`／`!x` 直接返回操作数类型，**不校验**（`-"a"` → string）。
5. **解引用兜底透传**（`:2004-2005`）：非 REF/PTR/GPARAM 的操作数**原样返回**。
6. **索引类型不校验**（`:2583` 的 `idx_ti` 无消费者）。
7. **字段落空静默**（`:2578`）：非 NAMED/TUPLE 的 `.f` → `TI_UNIT`，**无诊断**。
8. **转换无校验**（`:2904-2907`）：除 PTR 的 asp 外，`as` 是恒等透传。
9. **dyn = ⊤ 近似**（`:2066`/`:2643`/`:2473` + 桥接 `ty_shadow.cr:212-216`）：位图是收窄而 `AK_DYN` 在引擎 = ⊤。

**这份清单即「收紧清单的预备队」**：本批报告须逐条给出「现状格 → 表中格」，并声明「均按现状落格，无一条被收紧」。

### 3. 双份 TY→TI 映射 + 同族（P2b 第二交付物）

**spec 所指两表**（已用 `jj file show -r a9d991908910` 核对 spec 时点行号 → 现址）：

| 表 | spec 时点 | 现址 | 内容差异 |
|---|---|---|---|
| `res_type_node` 基型分支 | `:367-380` | **`checker.cr:732-744`** | 8 行：`TY_INT/DEX/BOOL/STRING/UNIT/NEVER/CHAR` + `tv == TI_DYN` |
| `res_call_type` 基型分支 | `:886-893` | **`checker.cr:1382-1392`** | 7 行：**无 `TY_NEVER`**；`TY_CHAR` 位置不同；同样有 `tv == TI_DYN` |

- **两表唯一的语义差 = `TY_NEVER` 单元格**（`:740` 有 / `:1388-1391` 缺，缺则落 `TI_UNIT`）。`never` **是**可解析的类型位（`parser.cr:94` `else if lex == "never" { … TY_NEVER … }`）⇒ 该差异**并非文法不可达**，合一必须显式处置（Task 6 Step 2 的探针）。
- `tv == TI_DYN`（`:742`/`:1390`）比的是 **TY 值域**而常量取自 **TI 命名**（值 7）——这正是 spec §2.4 记的**纯数字撞车** `TY_GENERIC_PARAM=7 == TI_DYN=7` 的现场；下行字面量节点不受影响（parser 从不产 `type_val=7`），但合一表时**必须原样保留该格语义**（枚举 §2.4 的「按命名空间分家」= P4/P5 面，本批不改）。
- **同族另有 6 处 TY→TI 内联链**（不在 spec 两表口径内，但同属「同一映射抄了多份」的病；Task 6 一并合并，逐处给出等价判据）：
  `:1055-1061`（hotpatch 返回）｜`:1080-1085`（hotpatch 首版返回）｜`:1133-1140`（extern 返回）｜`:1671-1675`（`check_func` 形参；**缺 UNIT/NEVER**，落 `TI_UNIT`）｜`:1724-1730`（`check_func` 返回）｜`:2129-2134`（iface 返回；**`iface_ret2` 与 `TY_*` 比较而值域是 TI_*，靠 `TY_INT==TI_INT==0 … TY_CHAR==TI_CHAR==6` 的数值撞车成立**——合一时须显式化）。
  另有 2 处不同性质、**不入合并**仅登记：`:241-248`（`init_types` 位置公理，8 行顺序分配）与 `:859-865`（`get_type_name` **反向** TY→名字）。
- 实测计数：`checker.cr` 内含 `TY_*` 常量的代码行 **61** 行（含注释共 65 次提及）。
- **spec 数字勘误（诚实声明）**：spec §11 记「`== TI_*` 比较 **72 处**」——本计划四种口径均**未复现**（spec 时点修订实测：`checker.cr` 含 TI_ 判等的行 19 / `== TI_` 10 / 与 `ir_gen.cr` 合计 75 行；工作副本 `checker.cr` 19 行、`ir_gen.cr` 56 行）。本计划一律引用上述自测口径，**不沿用 72**。

### 4. 可贴合的既有结构（新表必须照抄的形态）

1. **checker 侧原子宇宙 = 13 类**（不是引擎的 14）：`TYP_BASE`→8 原生（经 `TY_*` 码）、`TYP_NAMED`/**`TYP_GENERIC_PARAM`**/**`TYP_GENERIC_APPLY`**→`AK_NAMED`、`TYP_ARRAY`/`TYP_SLICE`→`AK_SEQUENCE`、`TYP_REF`→`AK_REF`、`TYP_PTR`→`AK_PTR`、`TYP_TUPLE`→`AK_PRODUCT`、`TYP_DYN`→`AK_DYN`。**无 `AK_SUM`/`AK_FN` 对应**（enum 类型 = `TYP_NAMED` 行，`checker.cr:982`；checker 无函数类型行）。
2. **「行号 → 原子类」的既有唯一实现 = 桥接层** `sh_native_ak`（`ty_shadow.cr:67-71`）+ `sh_base_ak`（`:75-88`）——**这就是 `iface_kind_of` 的原型**（含 `TY_DEX_S→AK_DEX`、`TY_GENERIC_PARAM→AK_NAMED` 两条已裁决格）。⇒ Task 2 的合一不是新建，是**单源化**（否则 P2b 会亲手造出第二份映射 = 本批要治的病）。
3. **「名字 → 结果类型」的表驱动先例** = `init_builtins`/`bi_add`（`checker.cr:261-303`，`g_rt_builtin_names` + `g_rt_builtin_ret_types` 两条平行 i64 缓冲）——本质条目表的形态参照（**扁平 i64 缓冲 + 偏移常量**，非对象树）。
4. **类型行 24B/条**（`g_types`，`checker.cr:9-16`）；引擎原子项 48B/条（`ESZ_TYPE_TERM`，`type_terms.cr:22-24`）；桥接缓存 16B/条（`g_shadow_map`）。新条目表取 **40B/条 × 5 字段**（下 Task 1）。
5. **iface 既有表（P3 面，本批不动）**：`g_ifaces` 1432B/条 ×16 方法×88B（`dyn_arr.cr:143-149`）+ `g_impl_for` 16B（`:830-833`）；查询 `find_iface`（`checker.cr:844`）/`type_has_method`（`:873`，**名字拼接**）/`check_iface`（`:881`）/`check_impl_for`（`:1746`）。

### 5. 判据底座（既有，复用不另发明）

| 判据 | 现值/命令 | 来源 |
|---|---|---|
| `selftest-types` | **95/95 PASS**（本计划实测，rc=0） | `nice -n 19 ./build/corec selftest-types`；下限守卫 `tests/selfhost/test_type_engine.py:20` `MIN_CASES = 32` |
| ELF canary | sha256 `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`（**本计划未复测**，取自近期提交链反复实测值） | `clean-cache` → `build tests/suite/ptr_arith.cr --static -o /tmp/x` → `sha256sum` |
| 影子对拍 | **71 文件 / 26989 判定 / agree 26989 / `old_stricter` 0 / `old_looser` 0 / `unknown` 0 / `replace_*` 0**（**本计划未复跑**，取自 findings §11 表） | `--type-shadow` + `grep '^\[type-shadow\] '` |
| `.ccr` 结构 | `tests/selfhost/test_ccr_v7.py` 27 例 | 见 `src/ci/run.sh:72` |
| 自举链 | `src/ci/run.sh full-bootstrap`（corec→corec2→corec3 `cmp` IDENTICAL + 两段 `error[N06]=0` + `--help` rc=1） | `src/ci/run.sh:90-101` |
| 冒烟 | `corec run 'fn main()->int{return 42;}'` rc=42 | 见 spec §4「每步判据」行 |
| 套件 | 38（7 bootstrap + 31 selfhost，TODO #27 收官实测）+ `tests/suite` 20 语料 | `src/ci/run.sh` |
| **判据重定（TODO #26）不适用** | 本批**不触** state 边/纯度（`dataflow.cr`/`purity_op_effect`/`ccr_io` 的 EDG/NOD 零改动）⇒ **不套用**边集断言；仍适用「ELF 逐字节 + `.ccr` 实测 + 自举稳定」 | TODO #26 适用面＝state 链/纯度类改动 |

### 6. 待实现者实测确认的两项（本计划**未**测，不得当已知）

1. **`never` 在「调用位点类型节点」的可达性**（Task 6 Step 2 探针）：`fn f[T](a: T, b: never)` 与嵌套形 `[never;3]` / `*never` / `G[never]` 是否让 `res_call_type` 走到 `TY_NEVER` 格。可达 ⇒ 合一必须保留该调用点现状（`TI_UNIT`）并登记；不可达 ⇒ 合一可直接统一语义（仍须登记）。
2. **现状宽松面的行为实证**（§2 九条）：本计划对第 2/6/7 条只做了读码推演（`1 + [int;3]` → INT、`arr[true]` 无诊断、`p.f` 落空静默）——**未跑探针**。Task 4/5 的红态用例须先跑出这些现状事实（**探针先行**，防「以为保语义其实改了」）。

---

## Task 1：建层——本质条目表 + `iface_*` 查询 API + 用例表（零消费者，零行为变化）

**Files:**
- 新建：`src/compiler/iface_registry.cr`（表 + 访问器 + API；**只含函数与常量**——表全局须放 `globals.cr`）
- Modify: `src/compiler/globals.cr`（`g_iface_entries` / `g_iface_entry_count` / `g_iface_registry_ok`）
- Modify: `src/compiler/type_selftest.cr`（`iface.*` 用例段）
- Modify: `src/compiler/_import.cr`（`import iface_registry`，插在 `type_engine` 之后 `ty_shadow` 之前）
- Modify: `build_selfhost_native.py`（**corec 清单** `:307-315` 区、**corelsp 清单** `:392-394` 区——插在 `type_engine.cr` 之后、`ty_shadow.cr` **之前**）
- Modify: `tests/selfhost/test_compile.py`（`concat_sources()` 清单 `:25-27` 区同步；清单漂移 = 该测试 resolver 报 `Undefined name`）

**Interfaces：**
```core
// ── 条目布局（40B/条 × 5 字段；与 g_types(24B)/ESZ_TYPE_TERM(48B) 同族：扁平 i64 缓冲）──
//   {ak, ti_row, name_ni, lit_code, ops}
//   ak       = 原子类（AK_*；type_engine.cr:19-22）
//   ti_row   = 该原子的**规范 checker 类型行**（8 原生 = TI_INT..TI_DYN 常量；结构/命名 = -1）
//   name_ni  = 名字 ni（str_intern；自测/诊断显示用）
//   lit_code = **字面量定型**：AST 字面量 kind（EXPR_INT/EXPR_DEX/EXPR_STRING/EXPR_BOOL/EXPR_CHAR）
//              → 本条目（查表入口 = `iface_lit_ti`/`iface_lit_ak` 的**字典**，本字段为其中一项）；-1 = 无字面量
//   ops      = 操作许可位集（bit(OP_*)/bit(UOP_*+20)/bit(IP_*)；见 Task 4 的位下标约定）
ESZ_IFACE_ENTRY : int = 40;
OFF_IE_AK : int = 0;  OFF_IE_TI : int = 8;  OFF_IE_NAME : int = 16;
OFF_IE_LIT : int = 24; OFF_IE_OPS : int = 32;

fn iface_registry_init()            // 幂等；由 init_types() 调用（尾部，原生 9 行 alloc 之后；表内容 = 常量，不缓存行号）
fn iface_count() -> int             // 条目数（恒 13；自测断言用）
fn iface_entry(ak: int) -> int      // 原子类 → 条目行号（-1 = 无此原子）
fn iface_ops(ak: int) -> int        // 操作许可位集（**spec §2.5 的签名**；-1/未知原子 → 全 0 = 无许可）
fn iface_permits(ak: int, op: int) -> int            // 1/0：位测试（op 已含 UOP/IP 偏置）
fn iface_lit_ti(lit_kind: int) -> int                // 字面量 AST kind → TI_*（-1 = 非字面量 kind）
fn iface_lit_ak(lit_kind: int) -> int                // 同上 → AK_*（交叉断言/引擎侧用）
fn iface_kind_of(ti: int) -> int                     // checker 行号 → AK_*（-1 = 越界/负）——Task 2 起为**唯一**实现
fn iface_by_ty_code(ty: int) -> int                  // TY_* 码 → AK_*（= 现 sh_base_ak 的语义；-1 = 无对应）
fn iface_ti_of(ak: int) -> int                       // 原子类 → 规范行（8 原生；其余 -1）
fn iface_of_term(t: int) -> int                      // 类型项 → AK_*（单一原子；非单一 → -1；⊤ₖ → 其 k）
```

**表数据（13 条，静态；每格注现状 `file:line`）**：8 原生条目 + `AK_PRODUCT`/`AK_SEQUENCE`/`AK_REF`/`AK_PTR`/`AK_NAMED`。`ti_row` 取 `TI_*` **常量**（不是位置推演——P1 M1 教训：勿依赖 init_types 行号序）；`AK↔TI` 的对应**逐项写死**（`AK_INT↔TI_INT`、`AK_DEX↔TI_DEX`、**`AK_STRING↔TI_STR`**、**`AK_BOOL↔TI_BOOL`**、`AK_UNIT↔TI_UNIT`、`AK_NEVER↔TI_NEVER`、`AK_CHAR↔TI_CHAR`、`AK_DYN↔TI_DYN`——bool/string 必错位书写以示下标不 1:1）。

- [ ] **Step 1: 守门用例（`type_selftest.cr`；红）**

```core
    // --- P2b Task 1：本质条目表 + iface_* 查询 API ---
    total = total + 1; fails = fails + ts_check("iface.count", iface_count(), 13);
    // 逐原生条目：ak/ti 对 + AK↔TI 下标**不 1:1** 的显式守卫（bool/string 互换）
    total = total + 1; fails = fails + ts_check("iface.int_ti", iface_ti_of(AK_INT), TI_INT);
    total = total + 1; fails = fails + ts_check("iface.str_ti", iface_ti_of(AK_STRING), TI_STR);
    total = total + 1; fails = fails + ts_check("iface.bool_ti", iface_ti_of(AK_BOOL), TI_BOOL);
    total = total + 1; fails = fails + ts_check("iface.dex_ti", iface_ti_of(AK_DEX), TI_DEX);
    total = total + 1; fails = fails + ts_check("iface.dyn_ti", iface_ti_of(AK_DYN), TI_DYN);
    // 行号 → 原子类：8 原生经**类型表本体**（kind == TYP_BASE && data == TY_*）判，不按行号猜
    total = total + 1; fails = fails + ts_check("iface.kind_int", iface_kind_of(TI_INT), AK_INT);
    total = total + 1; fails = fails + ts_check("iface.kind_str", iface_kind_of(TI_STR), AK_STRING);
    total = total + 1; fails = fails + ts_check("iface.kind_bool", iface_kind_of(TI_BOOL), AK_BOOL);
    total = total + 1; fails = fails + ts_check("iface.kind_dyn", iface_kind_of(TI_DYN), AK_DYN);
    total = total + 1; fails = fails + ts_check("iface.kind_oob", iface_kind_of(g_type_count + 7), -1);
    total = total + 1; fails = fails + ts_check("iface.kind_neg", iface_kind_of(-1), -1);
    // 字面量定型（**当前实现 = :1892-1897 的内联 if 链**，本表为唯一真源后仍须逐 kind 对拍）
    total = total + 1; fails = fails + ts_check("iface.lit_int", iface_lit_ti(EXPR_INT), TI_INT);
    total = total + 1; fails = fails + ts_check("iface.lit_dex", iface_lit_ti(EXPR_DEX), TI_DEX);
    total = total + 1; fails = fails + ts_check("iface.lit_str", iface_lit_ti(EXPR_STRING), TI_STR);
    total = total + 1; fails = fails + ts_check("iface.lit_bool", iface_lit_ti(EXPR_BOOL), TI_BOOL);
    total = total + 1; fails = fails + ts_check("iface.lit_char", iface_lit_ti(EXPR_CHAR), TI_CHAR);
    total = total + 1; fails = fails + ts_check("iface.lit_none", iface_lit_ti(EXPR_IDENT), -1);
    // 未知原子 → 空许可集（不得给「看起来有许可」的位）
    total = total + 1; fails = fails + ts_check("iface.ops_unknown", iface_ops(-1), 0);
    total = total + 1; fails = fails + ts_check("iface.ops_unknown_ak", iface_ops(9999), 0);
```

- [ ] **Step 2: 运行确认红**（`iface_*` 未定义 → 构建失败 / 用例挂；`nice -n 19 python3 build_selfhost_native.py` 期望解析期报错）

- [ ] **Step 3: 实现**（`iface_registry.cr` + `globals.cr` + 清单一/二/三处）
  - 表用**两条平行 i64 缓冲**（照 `bi_add` 先例）还是单 40B 缓冲？**取单缓冲**（40B/条，`alloc(13 * 40)`，`w64(g_iface_entries, e * ESZ_IFACE_ENTRY + OFF_IE_*)`）——理由是「13 条 × 5 字段」有 4 个异构字段，平行表会产生四份偏移表（`bi_add` 式只有「名字/返回型」两列才划算）。
  - `iface_kind_of(ti)`：`k := get_type_kind(ti)`；`k == TYP_BASE` → `iface_by_ty_code(get_type_data(ti))`；`k == TYP_DYN` → `AK_DYN`；`TYP_NAMED|TYP_GENERIC_PARAM|TYP_GENERIC_APPLY` → `AK_NAMED`；`TYP_ARRAY|TYP_SLICE` → `AK_SEQUENCE`；`TYP_REF` → `AK_REF`；`TYP_PTR` → `AK_PTR`；`TYP_TUPLE` → `AK_PRODUCT`；`k < 0` → `-1`。**本步先在本文件内实现 `iface_by_ty_code`（= `sh_base_ak` 的语义，含 `TY_DEX_S→AK_DEX`、`TY_GENERIC_PARAM→AK_NAMED` 两条已裁决格）；Task 2 再把桥接层改成委托它。**
  - `iface_lit_ti/lit_ak`：按条目表的 `lit_code` 反向扫（13 条线性扫，AST kind 面只有 5 个命中项）。
  - `iface_of_term(t)`：`tt_tag(t) == TT_ATOM` → `tt_a(t)`；`tt_tag(t) == TT_TOP_K` → `tt_a(t)`；其余（union/inter/not/bot/top/mu/var/nil/cons）→ `-1`。
  - `iface_registry_init()`：由 `init_types()` 调用（**尾部**，`:253` 原生 9 行 alloc 之后——表要读 `get_type_kind`）；幂等（`g_iface_registry_ok`）；照 `named_dedup_reset()`（`checker.cr:233`）/`sh_map_reset()`（`:237`）的重置先例挂同处。
  - `ops` 位集本 Task 先落**空集**（全 0），Task 4/5 逐格填——**空集期间不得有消费者**（本 Task 零消费者）。

- [ ] **Step 4: 判据**
```bash
nice -n 19 python3 build_selfhost_native.py
nice -n 19 ./build/corec selftest-types            # 现值 95/95（本计划实测）→ 本 Task 加 20 例 ⇒ 期望 115/115（实现者实测补面，计数以实测为准）
nice -n 19 ./build/corec clean-cache
nice -n 19 ./build/corec build tests/suite/ptr_arith.cr --static -o /tmp/p2b_t1_bin
sha256sum /tmp/p2b_t1_bin                          # 必须 == 95084e7b…d475
# .ccr 面（预期逐字节不变，须实测报告）：
nice -n 19 ./build/corec clean-cache && nice -n 19 ./build/corec ccr tests/suite/ptr_arith.cr -o /tmp/t1.ccr
# 与基线比 sha 并记录（基线 = 本批**第一个提交前**用同一构造路径 + clean-cache 取；若未取，
# 则以「同源两次构建产出一致」替代并在报告**显式记录该替代**——照 P0 计划先例）
nice -n 19 python3 tests/selfhost/test_ccr_v7.py   # 结构判据全绿
```
  - `iface.count != 13` 或 `iface_*.ti` 对不上 → **停下上报**（AK/TI 下标事故的现场）。
- [ ] **Step 5: 提交**（路径限定）：`feat: R2 P2b Task 1——本质条目表 + iface_* 查询 API（13 条原子条目：8 原生 + product/sequence/ref/ptr/named；AK↔TI 逐项分派不按下标直传）+ selftest 用例；零消费者零行为变化`

---

## Task 2：`iface_kind_of` 单源化——桥接分派（`sh_native_ak`/`sh_base_ak`）与注册表合一

**为什么在本批做**：`iface_kind_of` 与 `sh_*_ak` 是**同一个函数的两份实现**（侦查 §4.2）。不合一 = P2b 亲手制造「同一映射两份」，正是本批要治的病（先例：P2a 的 F1 就是「同名类型多行」的同族病）。

**Files:** Modify: `src/compiler/ty_shadow.cr`（`:67-88` 三函数改为委托）、`src/compiler/type_selftest.cr`（对拍用例）

**Interfaces：**
```core
// ty_shadow.cr 保留原签名（影子证据链的可比性依赖调用点不变），实现改委托：
fn sh_native_ak(ti: int) -> int {
    if ti < 0 { return -1; }
    if get_type_kind(ti) != TYP_BASE { return -1; }        // **原门保留**（见下）
    return iface_by_ty_code(get_type_data(ti));
}
fn sh_base_ak(ty: int) -> int { return iface_by_ty_code(ty); }
```
（**`sh_native_ak` 不可直接换成 `iface_kind_of`**：原实现要求 `get_type_kind(ti) == TYP_BASE` 才回 AK，否则 -1（`ty_shadow.cr:67-71`）；而 `iface_kind_of` 对 `TYP_DYN` 行回 `AK_DYN`、对结构行回 `AK_SEQUENCE` 等。原 `sh_native_ak(TI_DYN)` 回 **-1**，`TI_DYN` 由 `sh_term_of_ti` 的 `TYP_DYN` 分支另行处理（`:212-216`）⇒ 两者只在 `TYP_BASE` 行上重合，委托必须**显式保留该门**。）

- [ ] **Step 1: 对拍用例（红）——**对照物**先行**：旧实现**改名保留**（`sh_base_ak_legacy`/`sh_native_ak_legacy`，照 P2a 的 `type_equal_legacy` 双用先例；**P5 删**），委托版与 legacy 版**全表逐项对拍**——不是抽样：`ty ∈ 全部 TY 码`（含 `TY_DEX_S` 与 `TY_GENERIC_PARAM` 两条灰格 + 未映射码）× `ti ∈ [0, g_type_count)`（含 `TI_DYN` 行与全部结构/命名行）。
```core
    // --- P2b Task 2：iface_kind_of 与桥接分派单源化（**全表对拍**，非抽样）---
    // 判据 = 对每个 ti 码：委托版 == legacy 版（legacy = 改动前的字面拷贝；P5 删）
    ty_codes := alloc(16 * 8);
    w64(ty_codes, 0, TY_INT);  w64(ty_codes, 8, TY_DEX);   w64(ty_codes, 16, TY_BOOL);
    w64(ty_codes, 24, TY_STRING); w64(ty_codes, 32, TY_UNIT); w64(ty_codes, 40, TY_NEVER);
    w64(ty_codes, 48, TY_CHAR); w64(ty_codes, 56, TY_GENERIC_PARAM); w64(ty_codes, 64, TY_DEX_S);
    w64(ty_codes, 72, 999);   // 未映射码
    ty_bad : ., mut = 0;
    tc_i : ., mut = 0;
    loop {
        if tc_i >= 10 { break; }
        if iface_by_ty_code(r64(ty_codes, tc_i * 8)) != sh_base_ak_legacy(r64(ty_codes, tc_i * 8)) { ty_bad = ty_bad + 1; }
        tc_i = tc_i + 1;
    }
    total = total + 1; fails = fails + ts_check("iface.by_ty_code_all_codes", ty_bad, 0);
    // 行号面全表：构造 8 原生 + struct/数组/指针/元组/泛型应用行后逐 ti 比
    ti_bad : ., mut = 0;
    ti_i : ., mut = 0;
    loop {
        if ti_i >= g_type_count { break; }
        if sh_native_ak(ti_i) != sh_native_ak_legacy(ti_i) { ti_bad = ti_bad + 1; }
        ti_i = ti_i + 1;
    }
    total = total + 1; fails = fails + ts_check("iface.native_ak_all_rows", ti_bad, 0);
    // 两条灰格的**显式**断言（不止"两版相等"——防两版一起错）
    total = total + 1; fails = fails + ts_check("iface.kind_dyn_vs_bridge",
        (iface_kind_of(TI_DYN) == AK_DYN), 1);                    // 注册表：DYN 行 → AK_DYN
    total = total + 1; fails = fails + ts_check("iface.bridge_dyn_branch",
        (sh_native_ak(TI_DYN) == -1), 1);                        // 桥接：DYN 行**不经原生快路径**（委托后须保持）
    // TY_GENERIC_PARAM（=7，与 TI_DYN 同值）与 TY_DEX_S（=8）两条灰格
    total = total + 1; fails = fails + ts_check("iface.gparam_ak",
        iface_by_ty_code(TY_GENERIC_PARAM), AK_NAMED);
    total = total + 1; fails = fails + ts_check("iface.dex_s_ak",
        iface_by_ty_code(TY_DEX_S), AK_DEX);
    total = total + 1; fails = fails + ts_check("iface.unknown_ty_code",
        iface_by_ty_code(999), -1);
    // 语义分派守卫（P1 血泪：AK/TI 下标不 1:1）——沿用 bridge.str_ak / bridge.bool_ak
    total = total + 1; fails = fails + ts_check("iface.dispatch_no_index_shortcut",
        (iface_ti_of(AK_STRING) != AK_STRING), 1);                // 若哪天有人"按下标直传"，本行必红
```
- [ ] **Step 2: 实现**：① 原体改名为 `sh_base_ak_legacy`/`sh_native_ak_legacy`（**保留**，供对拍 + 报告引用；P5 删，登记入 TODO #24 的 P5 继承项）；② `sh_base_ak`/`sh_native_ak` 改为委托 `iface_by_ty_code`（**显式保留** `ti < 0` 与 `get_type_kind(ti) != TYP_BASE → -1` 两个门）；③ 跑 Step 1 用例，`*_all_codes`/`*_all_rows` 必须为 0 mismatches。
- [ ] **Step 3: 判据**：`selftest-types` 全绿 + **影子语料复跑数字与基线逐项相同**（71 文件 / 26989 / agree 26989 / 0 / 0 / 0；**必须同报站点直方图**——P1 交接硬性要求）+ ELF/`.ccr` 逐字节 + `test_lsp.py`（桥接缓存重置面，P2a 评审 Critical 的守卫）。
- [ ] **Step 4: 提交**：`refactor: R2 P2b Task 2——iface_kind_of 与桥接分派（sh_native_ak/sh_base_ak）单源化（逐 case 对拍含 DYN/GENERIC_PARAM/DEX_S 三条灰格；影子语料数字逐项不变）`

---

## Task 3：字面量定型查表接线（5 处）

**Files:** Modify: `src/compiler/checker.cr`（`:1892-1897`）、`src/compiler/type_selftest.cr`

**Interfaces：** 复用 Task 1 的 `iface_lit_ti(lit_kind)`；**接线后 `infer_expr` 头部 5 行变 5 行查表调用**（不得合并成一次「先取 kind 再查」的循环——5 个 AST kind 的判断顺序与短路行为必须逐字保持）。

- [ ] **Step 1: 交叉断言用例（红）**：字面量节点在 parser 侧**本已带 `type_val`**（`parser.cr:399` `EXPR_INT→TY_INT`、`:410` `EXPR_DEX→TY_DEX`、`:414/:1032` `EXPR_STRING→TY_STRING`、`:416-417/:1040-1044` `EXPR_BOOL→TY_BOOL`、`:556/:1036` `EXPR_CHAR→TY_CHAR`）⇒ 可加一条**跨交付物交叉断言**：`iface_lit_ti(K) == ty_code_to_ti(<K 的字面量 type_val>)` 对 5 个 kind 全成立（Task 6 的 `ty_code_to_ti` 落地后启用；本 Task 先断前 5 个 `iface.lit_*` 用例不变）。
- [ ] **Step 2: 接线**：`:1892` `if ast_kind(node) == EXPR_INT { return iface_lit_ti(EXPR_INT); }` … 逐行同构替换（**不**引入中间变量、**不**改判断顺序）。
- [ ] **Step 3: 判据**：`selftest-types` 全绿 + ELF 逐字节 + `.ccr` 实测 + 全回归。
- [ ] **Step 4: 提交**：`refactor: R2 P2b Task 3——字面量定型查表（infer_expr:1892-1897 内联 if 链 → iface_lit_ti；5 个 kind 逐项对拍，短路顺序逐字保持）`

---

## Task 4：操作许可接线（二元 11 条 / 一元 4 条 / 条件 3 条）

**Files:** Modify: `src/compiler/checker.cr`（`:1918-1966`、`:1968-2008`、`:2265`、`:2376`、`:2402-2403`）、`src/compiler/iface_registry.cr`（填 `ops` 位集）、`src/compiler/type_selftest.cr`

**位下标约定（写死，跨 Task 一致）：**
```core
// 许可位下标 = **复用 ast.cr 既有操作码**（少一层映射 = 少一处漂移源；P1 的 AK/TI 事故即映射层自造）：
//   OP_*  1..19  →  直接用其值（OP_ADD=1 … OP_PTR_DIFF=19；OP_AND=12/OP_OR=13 同理，
//                   故**不另设** IP_LOGIC——逻辑族的谓词就写 iface_permits(kind, OP_AND)）
//   UOP_* 1..4   →  经 +20 偏置（UOP_NEG→21 … UOP_DEREF→24）
//   新族    25.. →  IP_INDEX=25 / IP_INDEX_RANGE=26 / IP_FIELD=27 / IP_METHOD=28 / IP_AS=29
//                   / IP_COND=30（真值性，`if` 现状收 bool|int）
//                   / IP_COND_BOOL=31（严格 bool，`while` 现状**只收 bool**——两条规则现状不同，
//                     **不得合并为一个「更统一」的位**：合并 = 收紧 `if` 或放宽 `while`）
IP_UOP_BIAS : int = 20;
IP_INDEX : int = 25;  IP_INDEX_RANGE : int = 26;  IP_FIELD : int = 27;
IP_METHOD : int = 28; IP_AS : int = 29;  IP_COND : int = 30;  IP_COND_BOOL : int = 31;
// 位构造照 dyn_set_type 的乘 2 循环（本语言无移位运算符）：
fn iface_bit(n: int) -> int { b : ., mut = 1; k : ., mut = n; loop { if k <= 0 { break; } b = b * 2; k = k - 1; } return b; }
```

**站点侧的三种「门形状」（现状各异，**必须逐字保留**；表只出「原子类 × op」的单侧许可）：**
```core
// ① ANY（算术族 :=1950）：至少一侧许可即通过 —— if iface_permits(k(lt),op) == 0 && iface_permits(k(rt),op) == 0 { 报错 }
// ② ALL（逻辑族 :=1960）：每侧都须许可     —— if iface_permits(k(lt),OP_AND) == 0 || iface_permits(k(rt),OP_AND) == 0 { 报错 }
// ③ ONE（条件族 :=2265 / :2376）：单操作数 —— if iface_permits(k(c),IP_COND)==0 { 报错 }（while 用 IP_COND_BOOL）
```

**表填空（逐格 = 现状语义；**这是本 Task 的核心产出物**，每格注现状行号）**

**先立一条结构事实（否则表会填错）**：现状的「算术许可」是**两层**——① `:1937/1939/1942/1946` 的**早退规则**（串拼接、指针算术、指针差：命中即 `return`，**不会走到门**）；② `:1950` 的**门**（「两侧皆非数值才报错」）。故：

- **门集合只含 `INT`/`DEX` 两员**——这**不是**省事，而是与 `:1950` 一字等价所要求的最小集。反例（**若把 `PTR` 或 `STRING` 也放进门的 ADD 格，就会放宽**）：
  `*T + *T` 现状 = 报错（`:1939/1942` 都不命中、`:1950` 两侧非数值）——若 `PTR@ADD=1`，ANY 门下 `permits(PTR,ADD)=1` ⇒ **不再报错**（静默降为 `TI_INT`）= 放宽；
  `"a" - "b"` 同理（`:1937` 只管 `OP_ADD`）。
- **串拼接（`+` on string）的「许可」在现状**落在①（`:1937`）**而非门里**——这与 spec §2.1 的示例（「`+` 对 int/dex/string 合法」）**不冲突**：spec 说的是语义层的操作许可，本批的落地形态把它拆成「门集合 + 早退规则」两处，两处合起来 = spec 的语义（**报告须逐条给出该对应关系**，见 Task 7 Step 5 的事实表）。
- 故门的**许可格**只有 `AK_INT`/`AK_DEX` 的 `ADD..MOD = 1`，其余原子一律 `0`；早退规则（串拼接/指针算术/指针差）**留代码**（它们同时决定**结果类型**，属结果规则）。

**许可格（门 + 非算术族；每格注现状行号）：**

| 原子类 | 许可格（现状依据） |
|---|---|
| `AK_INT`/`AK_DEX` | 门：`ADD..MOD`（`:1950`）+ `AND/OR`（`:1960` 允许 bool\|int）+ `EQ..GE`（`:1956` 全许可）+ `NEG/NOT`（`:1970`）+ `REF`（`:1973`）+ `DEREF`（`:1994-2005` 兜底透传）+ `AS`（`:2904` 无校验）+ `IP_COND`（`:2265` 收 int）；**`IP_COND_BOOL` 否**（`:2376` 只收 bool）；`IP_INDEX*` 否（非容器） |
| `AK_BOOL` | 门：`ADD..MOD = 0`（`:1950` 门不含 bool）+ `AND/OR` + `EQ..GE` + `NEG(NOT)`/`REF`/`DEREF`/`AS` + `IP_COND`/**`IP_COND_BOOL`** |
| `AK_STRING` | 门：**全 0**（拼接走 `:1937` 早退）+ `EQ..GE` + `NEG/NOT`/`REF`/`DEREF`/`AS` + `IP_INDEX`（`:2619` 串下标→int）；`IP_COND*` 否（`:2265` 只收 bool/int） |
| `AK_UNIT`/`AK_NEVER`/`AK_CHAR`/`AK_DYN` | 门全 0 + `EQ..GE` + `NEG/NOT`/`REF`/`DEREF`/`AS`；**`IP_COND`/`IP_COND_BOOL` 否**（`:2265`/`:2376` 只收 bool\|int / bool——**不得因「全许可面」顺手表上**）；`AK_DYN` 额外 `IP_METHOD`（`:2066` dyn 方法校验路径） |
| `AK_PRODUCT`（元组） | 门全 0（`:1956` 比较**无校验** ⇒ 比较面全许可，登记 P3 收紧面）+ `IP_FIELD`（`:2566` `.N`）+ `REF`/`DEREF`/`AS` |
| `AK_SEQUENCE` | 门全 0 + `IP_INDEX`（`:2605-2618`）+ `IP_INDEX_RANGE`（`:2586`）+ 比较/一元/转换面 |
| `AK_REF`/`AK_PTR` | 门全 0（**指针算术由 `:1939-1948` 早退承担，见上「结构事实」**）+ `DEREF`（`:1996-2001`）+ 比较全许可面 + `AS`（`:2897`） |
| `AK_NAMED` | 门全 0 + `IP_FIELD`（`:2522` 字段）+ `IP_METHOD`（`:2088` 方法表）+ 比较全许可面 + `NEG/NOT`/`REF`/`DEREF`/`AS` |

（**「比较/一元/转换面全许可」的口径**：`:1956` 比较不校验 ⇒ 6 个比较位对**全部 13 类**置 1；`:1970` 一元透传、`:1994-2005` 解引用兜底、`:2904` 转换无校验 ⇒ `NEG/NOT`/`DEREF`/`AS` 对**全部 13 类**置 1；`UOP_REF`：`:1973` 对任意操作数产 `TYP_PTR` ⇒ 亦全许可。**这四组「全 1 列」是现状宽松面的集中体现**，报告须单列其 P3 收紧建议。）

- [ ] **Step 1: 红态（现状行为探针先行，`tests/selfhost/test_iface_ops.py` 新建）**——先跑出 §2 九条宽松面的**现状事实**（本计划未测，须由实现者实测确证），再接线：
  - 正控（许可）：`fn main()->int{ x:=1+2; return x; }` rc=0；`"a"+"b"` rc=0；`p+1`/`1+p`（`*int`）rc=0；`s[0]`（string）rc=0；`t.0`（元组）rc=0。
  - 负控（拒绝，码不变）：`[int;3] + [int;3]` → `error[TB01]` rc=1；`"a" * "b"` → `error[TB01]` rc=1；`"a" - "b"` → `error[TB01]` rc=1（**门不含 string**）；**`*T + *T` → `error[TB01]` rc=1（本批最易放宽的一条——见上「结构事实」）**；`!x` 中 `x: [int;3]`—— **不适用**（一元现状透传，须断 rc=0 且类型 = 数组，登记为 P3 面）；`if [int;3] {}` → `error[TC01]` rc=1；`while 1.5 {}` → `error[TC01]` rc=1。
  - 登记面（现状宽松，**断言"现状不动"**）：`1 + [int;3]` rc=0；`"a" * 2` rc=0；`arr[true]` rc=0（索引类型不校验）；`p.f`（p 非 struct）rc=0。
- [ ] **Step 2: 接线（逐条同构替换，三种门形状照上表）**：
  - `:1950`（ANY）`if lt != TI_INT && lt != TI_DEX && rt != TI_INT && rt != TI_DEX` → `if iface_permits(iface_kind_of(lt), op) == 0 && iface_permits(iface_kind_of(rt), op) == 0`（**`&&` 形状与现状一字不差**——现状「两侧皆无许可才报错」）。
  - `:1960`（ALL）`(lt != BOOL && lt != INT) || (rt != BOOL && rt != INT)` → `iface_permits(k(lt), OP_AND) == 0 || iface_permits(k(rt), OP_AND) == 0`（`op` 手头就是 `OP_AND`/`OP_OR`）。
  - `:2265`（ONE，`IP_COND` = bool\|int）与 `:2376`（ONE，`IP_COND_BOOL` = 仅 bool）分别取各自位——**两条规则现状不同，不得合并**。
- [ ] **Step 3: 判据**：`selftest-types` 全绿（含新增 `iface.ops.*` 逐格用例 ≥10 例）+ `test_iface_ops.py` 正/负/登记三类全绿 + ELF 逐字节 + `.ccr` 实测 + 全回归 + 影子语料数字不变。
- [ ] **Step 4: 提交**：`refactor: R2 P2b Task 4——操作许可查表接线（二元/一元/条件；许可位 = ast.cr 既有操作码复用；ANY/ALL 语义与现状逐字等价，宽松面原样保留并登记）`

---

## Task 5：容器面接线（索引 / 字段 / 转换 / dyn 消费点）

**Files:** Modify: `src/compiler/checker.cr`（`:2581-2636`、`:2509-2579`、`:2892-2908`、`:2066-2082`、`:2643-2651`、`:2473-2477`）、`src/compiler/iface_registry.cr`、`tests/selfhost/test_iface_ops.py`

- [ ] **Step 1: 红态**：索引容器许可三正（数组/切片/串）+ 非容器负控（`1[0]` → `error[TK01]` 现状已有，`:2634`）+ 落空分支**登记**（`p.f` 落空 rc=0；`x as T` 任意组合 rc=0；`dyn` 方法不存在 → `error[N08]`（`EC_N_METHOD=2008`）`checker.cr:1878`）。
- [ ] **Step 2: 接线**（**与 Task 4 的关键区别**：索引面的三个 kind 分支**做的是不同的事**——数组带 F2 越界检查、切片返元素、串返 `TI_INT`——**它们都是结果规则，必须原地保留**；表在这里只承担「谁**可以**进这个面」的**拒绝判定**）：
  - **不得**把 `if arr_kind == TYP_ARRAY`（`:2605`）/`if arr_kind == TYP_SLICE`（`:2616`）/`if arr_ti == TI_STR`（`:2619`）换成 `iface_permits(...)`——那会把三个分支合并成一条（结果类型与检查全丢）。改动只落在一处：`:2634` 的兜底拒绝（`check_error(EC_TK_INDEX, ...)`）之前加/改为 `if iface_permits(iface_kind_of(arr_ti), IP_INDEX) == 0 { <原 TK01 报错，码与文案逐字不变> }`，**其后保留原兜底**（双保险：表的拒绝集与兜底一致，措辞路径不变）。
  - 同理 CHECK：`IP_INDEX_RANGE` 的拒绝分支（`:2602` 的 `return TI_UNIT`）**保留现状**（range 索引非数组时今日静默返 `TI_UNIT` 无诊断——登记面，不改）。
  - 字段/转换/dyn：**落空分支一律保留现状**（`:2578` 返 `TI_UNIT` 无诊断、`:2907` 恒等透传、`:2071` `validate_dyn_method`）——本 Task 只把它们的**许可判据**改成查表（`IP_FIELD`/`IP_METHOD`/`IP_AS`），**诊断面零改动**；落空分支的「无诊断」事实写入报告的事实表（P3 收紧面的输入）。
  - **可空的接线强度（如实登记）**：索引/字段/转换三面的表格在现状下**几乎不改变判定**（拒绝集与兜底同集）——其价值 = 把「拒绝集」从散落的分支变成表里可审计的一格（P3 收紧的旋钮位置）。报告须如实说明哪些格子**当前不可达/无行为差异**，不得把它记成「已生效的接线」。
- [ ] **Step 3: 判据**：同 Task 4 + 现有 `test_agg_checks.py`（TS01-04/TK02）、`test_slice_bounds.py`、`test_agg_slots.py` 全绿。
- [ ] **Step 4: 提交**：`refactor: R2 P2b Task 5——容器面许可查表接线（索引/字段/转换/dyn；结果规则与诊断面零改动，落空分支现状登记）`

---

## Task 6：`res_type_node` 双份 TY→TI 映射合一（+ 同族 6 处内联链）

**Files:** Modify: `src/compiler/checker.cr`（`:732-744`、`:1382-1392` + 同族 `:1055-1061`/`:1080-1085`/`:1133-1140`/`:1671-1675`/`:1724-1730`/`:2129-2134`）、`src/compiler/iface_registry.cr`、`src/compiler/type_selftest.cr`

**Interfaces：**
```core
// TY_*（基类型码）→ TI_*（类型表行常量）；**-1 = 无对应**（调用方自行决定回落，不再表内兜底）
fn ty_code_to_ti(ty: int) -> int
// 语义：TY_INT→TI_INT / TY_DEX→TI_DEX / TY_BOOL→TI_BOOL / TY_STRING→TI_STR / TY_UNIT→TI_UNIT /
//       TY_NEVER→TI_NEVER / TY_CHAR→TI_CHAR / TI_DYN(值 7，**原样保留现状写法与注释**)→TI_DYN /
//       TY_DEX_S→TI_DEX_S（占位行，仅 init_types 面用；不属两表并集）/ 其余 → -1
// 调用点现状等价改写（**两处回落必须显式写出，不得藏在表里**）：
//   res_type_node  :  ti := ty_code_to_ti(tv); if ti < 0 { ti = TI_UNIT; } return ti;
//   res_call_type  :  ti := ty_code_to_ti(tv); if ti < 0 || tv == TY_NEVER { ti = TI_UNIT; } return ti;   ← 见 Step 2 探针裁决
```

- [ ] **Step 1: 用例（红）**：逐码对拍 `ty_code_to_ti(TY_INT..TY_CHAR)` = 对应 TI；`TY_DEX_S`/未知码 → -1（**表内不兜底**）；`res_type_node`/`res_call_type` 的**基型节点**在合一前后同值（用 `alloc_node(0,…,TY_X)` 逐码构造节点比返回）。
- [ ] **Step 2: `never` 单元格探针（**本计划未测**，须实测才可裁决）**：
  ```core
  // 探针 A：调用位点的 never 形参
  fn f[T](a: T, b: never) -> int { return 1; }
  // 探针 B/C/D：嵌套位 [never;3] / *never / G[never]——经 res_call_type 递归
  ```
  - 结果 **不可达** ⇒ 合一后 `res_call_type` 直接用 `if ti < 0 { ti = TI_UNIT; }`（与另表同形），差异消失，报告登记「不可达」。
  - 结果 **可达** ⇒ **保留现状**：`res_call_type` 处显式 `|| tv == TY_NEVER`（一行 + 注记 + 探针文件），并把「`never` 形参在调用位点被当作 unit」登记为**待裁决项**（交 P3；语义争议按 spec §4 裁决 6 **停下上报**）。
  - **判据 = 探针实测输出**，不得以「大概到不了」代替。
- [ ] **Step 3: 同族 6 处合并**：`:1055-1061`/`:1080-1085`/`:1133-1140`/`:1671-1675`/`:1724-1730`/`:2129-2134` 逐处改调 `ty_code_to_ti`，**逐处保留各自的尾部回落**（`TI_UNIT`；`:1724-1730` 含 `TY_NEVER`；`:2129-2134` 的 `TY_*` 撞车比较改为 `ty_code_to_ti(iface_ret2)` 显式化——**行为等价**：`TY_INT==TI_INT==0 … TY_CHAR==TI_CHAR==6`）。
- [ ] **Step 4: 判据**：`selftest-types` 全绿（新 ≥6 例）+ ELF 逐字节 + `.ccr` 实测（**预期不变**：合一只改 Rust-式分支形状，不 alloc 行）+ 全回归 + 自举链。
- [ ] **Step 5: 提交**：`refactor: R2 P2b Task 6——res_type_node/res_call_type 双份 TY→TI 映射合一（单表 ty_code_to_ti + 各调用点显式回落；同族 6 处内联链一并收敛；never 单元格探针实测裁决）`

---

## Task 7：收官（回归 + 自举 + 收紧清单 + 文档）

- [ ] **Step 1: 全量回归**：38 套件（7 bootstrap + 31 selfhost）+ `tests/suite` 20 语料 + `tests/selfhost/test_iface_ops.py`（新）。
- [ ] **Step 2: 零变化复验**：ELF 逐字节（`ptr_arith`，clean-cache）+ 影子开/关两态逐字节 + `.ccr` **实测变更报告**（预期零变化；变则逐段说明）+ 影子语料复跑（数字 + 站点直方图同报）。
- [ ] **Step 3: 自举链**：`src/ci/run.sh full-bootstrap`（`corec2/corec3` `cmp` IDENTICAL + 两段 `error[N06]=0` + `--help` rc=1）+ 冒烟 `run 'fn main()->int{return 42;}'` rc=42。
- [ ] **Step 4: 收紧清单**：本批「旧接受 → 新拒绝」逐条记录——**预期为空**（保语义口径）；若非空 → 逐条登记文件/用例/旧判定/新判定/处置，并说明为何属于「接线必然而非收紧」。
- [ ] **Step 5: 事实表**：侦查 §2 九条宽松面 → 表格的**逐条落格记录**（现状行号 / 表中格 / 是否有诊断 / P3 收紧建议），落 `docs/superpowers/specs/2026-09-10-type-shadow-findings.md` 新增一节「P2b 后：公理区事实表」，供 P3 直接消费。
- [ ] **Step 6: 文档/TODO**：spec §9 P2 行标 (b) 部分 ✅（含落点/提交链/未覆盖面）；TODO #24 的「P2b 待办」划销、新增「P2b 落地」条目（落点 + 未覆盖面登记：`iface_satisfies`/横切轴/用户轴/尺寸对齐未做、`AK_SUM`/`AK_FN` 无 checker 对应、dyn 64 上限、P3 收紧面清单）；`src/ci/run.sh` 挂 `test_iface_ops.py`。
- [ ] **Step 7: 提交**（路径限定）。

---

## 自检记录

- **根因 vs 止血**：本批**不是止血**——它是 spec §2「一张注册表、检查器统一查表」的**第一段落地面**（此前只有 P0 的判定 API，无查询 API、无条目表）。**采用的路线 = 保语义接线**（表逐格转录现状），**明确不做**「顺手收紧」（= P3）：理由是 P2a 已确立「替换门 = 语料差异归零 + 站点覆盖同报」的纪律，而收紧面尚无全语料证据（P1 的 9 条差异 100% 是 unknown，**零条**是收紧面）。**未采用**的替代方案：① 一步到位「表 + 收紧」（会把语言面收紧混进接线批，违反裁决 6 的「逐处记录 + 争议停下」）；② 只建 API 不接线（P2b 交付物缺一半，且下游切片等的是「统一入口」）。
- **两个交付物的耦合（设计说明）**：`iface_lit_ti`（字面量定型）与 `ty_code_to_ti`（TY→TI 单表）在本语言里**同源**——字面量节点本就携带 `type_val = TY_*`（`parser.cr:399/410/414/416/556`）。本批选**kind 主路**（保语义：`infer_expr` 现状按 AST kind 判，不读 `type_val`），并把 `type_val` 路作为**交叉断言**（Task 3 Step 1）而非主路——因为并非所有字面量铸点都写 type_val（`monomorph.cr:228-231` 克隆**保留** `tv`，但其它路径未审计），主路换 kind 会在未来铸点漏写时静默错型。
- **占位符扫描**：无 TBD；两处**明标未测**（侦查 §6：`never` 可达性 + 宽松面行为实证）已各自绑定「Step 1 红态探针」而非「稍后填」。表的空白格一律有明确取值（0/1），无「待定」。
- **关键结构发现（本计划最大单点风险，已写入 Task 4）**：现状的「算术许可」是**两层**（`:1937/1939/1942/1946` 早退规则 + `:1950` 门），故**门的许可集只能含 `INT`/`DEX`**——把 `PTR`/`STRING` 填进 `ADD` 格会让 `*T + *T`、`"a" - "b"` 从「报错」变「静默」（ANY 门语义下 `permits(PTR,ADD)=1` 足以放行）。spec §2.1 说「`+` 对 int/dex/string 合法」与此不冲突：该语义在现状由「门 + 早退规则」两处合起来给出，本批的落地形态**照现状拆**，并把它列入报告的事实表。**若实现者按直觉把 string/ptr 填进门，判据（负控 `*T + *T` / `"a" - "b"` rc=1）必红。**
- **命名一致性**：`iface_registry.cr` / `iface_count` / `iface_entry` / `iface_ops` / `iface_permits` / `iface_lit_ti` / `iface_lit_ak` / `iface_kind_of` / `iface_ti_of` / `iface_of_term` / `iface_by_ty_code` / `ty_code_to_ti` / `iface_bit` / `ESZ_IFACE_ENTRY` / `OFF_IE_*` / `IP_*` / `IP_UOP_BIAS` 在任务间一致；`sh_native_ak`/`sh_base_ak` 保留原名（影子链路可比性）。
- **spec 覆盖**：§2.1 三字段（操作许可 / 字面量定型 / 尺寸对齐「非语义」）→ Task 1/3/4/5 + 范围节第 ③ 条；§2.5 五个 API → Task 1（`iface_satisfies` 明标 P3，零调用者）；§2.4 编号撞车 → **登记**（Task 6 Step 3 显式化 `:2129-2134` 一处，其余归 P4/P5，不在本批改命名空间）；§4 步 3 的两个点 → Task 4/5 与 Task 6；§9 P2 (b) → 全批。
- **风险 / 退路**：
  1. **最大风险 = 接线时「顺手收紧」**（侦查 §2 的九格都是「看起来像 bug」的现状）⇒ 后果：自举源码或语料出现新诊断（rc 变/ELF 变），且收紧面**无全语料证据**。缓解 = 逐格转录 + 格注行号 + 三类探针（正控/负控/**登记面**）+ 收紧清单预期空。
  2. **AK/TI 下标事故复发**（P1 已发生过一次，且本批要新建「原子类 ↔ 类型行」双向映射）⇒ 缓解 = `bridge.str_ak`/`bridge.bool_ak` 既有守卫 + `iface.dispatch_no_index_shortcut` + 逐条目 `iface.*_ti` 用例。
  3. **桥接层改动动摇影子证据链**（P1/P2a 的数字是跨批可比性基线）⇒ 缓解 = Task 2 单列 + **全表逐行对拍** + 语料数字逐项相同 + 退路 = 若评审否决该合并，**登记为 P5 项**（不静默、不删除重复）。
  4. **`.ccr` 意外变化**（若某处接线扰动类型行号或误 alloc 行）⇒ 缓解 = 表**不 alloc 类型行**、判据要求冷缓存实测 `.ccr`；变则**停下上报**。
  5. **新文件的清单/顺序**（bootstrap 单遍解析；三份清单 + `_import.cr` 四处同步点）⇒ 缓解 = `guard_manifest` + `test_compile.py` 的存在性断言（清单漂移 = resolver 报 `Undefined name`）。
