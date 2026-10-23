# R2 P2a Task 3 报告：判定替换（`type_equal` → 引擎）

**状态**：完成（判据全绿；1 条 pre-existing 缺陷登记 = §9 F5）
**提交**：见 §12（jj change / commit 短哈希）
**范围**：Step 1 替换实现 + Step 2 对拍复跑（替换门）+ Step 3/3b/3c 判据与 N 面探针 + C-1 负控 + C-4 管线内断言。
**产物**：`src/compiler/checker.cr` · `src/compiler/globals.cr` · `src/compiler/main.cr` · `src/compiler/ty_shadow.cr` · `src/compiler/type_selftest.cr` · `tests/selfhost/test_named_dedup.py`（新增）

**判据一行结论**：ELF 逐字节 `95084e7b…d475` IDENTICAL（开/关两态）· 对拍三档 71 文件 **26989/26989 agree、old_stricter=0、old_looser=0、unknown=0、replace_bridge=0、replace_unknown=0** · 全回归**已跑集**（17 selfhost + 5 bootstrap + `selftest-types`）rc=0（含 `selftest-types` **88/88**、新增 `test_named_dedup`；终态 95/95 与全仓抽跑见 §13）· 自举 `corec2/corec3` **CMP_IDENTICAL + N06=0 + 冒烟 rc=42** · `.ccr` 4 语料（含自指）IDENTICAL。

> **Task 4 收官重算（2026-09-11，评审 Important 收口）**：本报告初稿的 §1 判据行 / §5.1 / §5.3 曾写 **24796 / 26962**（直方图 4414/1738/18642）——该组数字取自**中间产物**。以 **final 产物** `/tmp/r2p2t3/all_tiers2_final.txt`（71 行，与 `dumps2/`/`logs2/` 同批）**独立重算**后的正确值为：**decisions=26989 / agree=26989**，直方图 **fn-body-ret=4949 · if-branch=1919 · assign-node=20119 · generic-apply-base=2**（合计 26989）。逐档修正见 §5.1（T2 7980→**7998**、T3 14046→**14055**；T1 2743 与 T4+T5 2193 不变）。**校验来源**：Task 4 收官用独立解析脚本对 71 行逐行重算（主行 key=value 求和 + 站点行逐项求和 + 逐文件 `sum(site)==decisions` 比对），非引用原脚本输出——**原脚本 `/tmp/r2p2t3_run.sh` 并不做任何校验**（只打印），详见 §5.3 脚注。

---

## 1. 判据总表

| # | 判据 | 结果 | 证据 |
|---|------|------|------|
| 1 | `selftest-types` | **88/88 PASS**（85 基线 + 3 新用例 t3.*） | §7.1 |
| 2 | ELF 逐字节（关态 / 开态） | **IDENTICAL**（sha256 `95084e7b…d475`） | §8.1 |
| 3 | `.ccr` 实测（冷缓存，含**自指语料**） | **4/4 IDENTICAL** | §8.2 |
| 4 | 对拍复跑（P1 三档 + 2 档扩面，**影子对照物 = legacy**） | 71 文件 **agree=26989/26989**（final 产物重算，Task 4 收口）；旧严格/旧宽松/未知/回落 全 0 | §5 |
| 5 | 站点覆盖（与差异数同报，硬性） | 站点 1/2/4/6 = **0 命中**；3 = 2；5/7/8 覆盖 | §5.3 |
| 6 | unknown 计数（回落 legacy 次数） | 语料 **0**；探针面见 §6（三处非零，逐条登记） | §5.4 / §6 |
| 7 | N 面行为探针（异长/同长 + 嵌套四位） | 5 位中 **4 位**拒绝语义保持；元组复合元素位 = **pre-existing 缺陷**（F5，§9） | §6 |
| 8 | C-1 泛型应用跨站点 + 负控 | 正控判等 / 负控①②均拒（含 N 面负控） | §7.2 |
| 9 | C-4 管线内断言（侧表 ↔ res_type_node） | `mismatches=0`（真实语料）+ 注入故障负控 `mismatches=6, rc=1` | §7.3 |
| 10 | N 不得回身份（判定路径码级复核） | 无 N 比较；唯一调用方 = `type_compat_strict` | §4 |
| 11 | 两态零变化（build/check 双路径） | OFF/ON-IDENTICAL + CHECK-STDOUT-IDENTICAL | §8.1 |
| 12 | 自举链 | **CMP_IDENTICAL** · N06=0/0 · `error[`=2/2（既有 TF01 误报逐字同）· 冒烟 rc=42 | §8.3 |
| 13 | 全回归 | **已跑集 rc=0**（17 selfhost + 5 bootstrap + `selftest-types`；即下 §8.4 所列 14 标准 + 8 加固 + 新增 C-4 套件）——终态扩至全仓 38 套件见 §13 | §8.4 |
| 14 | 收紧清单（旧受新拒 = 行为变化的唯一方向） | **空**（old_looser 全语料 0） | §5.2 |

---

## 2. 替换前后对照

### 2.1 结构（三函数拆分）

| 名称 | 改前 | 改后 |
|---|---|---|
| `type_equal_legacy` | 旧名 `type_equal_core`（P1 起内部递归名） | **降级为对照物 + 回落实现**（P5 删）；6 处内部递归同步改名；**函数体零改动**（数组分支 Task 2 起已 N-free） |
| `type_equal_engine` | —（新） | 判定主体：快路径 + 桥接 + `ty_equiv` 三态 + unknown/桥接回落计数 |
| `type_equal` | P1 影子包装（调 `type_equal_core`） | 判定入口：`type_equal_engine` + 影子包装（**对照物切到 `type_equal_legacy`**） |

```core
// checker.cr:488
fn type_equal_engine(t1: int, t2: int) -> bool {
    if t1 == t2 { return true; }                       // 快路径：同一行
    a := sh_term_of_ti(t1);
    b := sh_term_of_ti(t2);
    if a < 0 || b < 0 { g_replace_bridge = g_replace_bridge + 1; return type_equal_legacy(t1, t2); }
    ty_budget_reset(200000);
    e := ty_equiv(a, b);
    ty_budget_reset(200000);
    if e == 1 { return true; }
    if e == 0 { return false; }
    g_replace_unknown = g_replace_unknown + 1;         // 未知：不静默
    return type_equal_legacy(t1, t2);
}
// checker.cr:511
fn type_equal(t1: int, t2: int) -> bool {
    r := type_equal_engine(t1, t2);
    if g_shadow_on != 0 { ok : ., mut = 0; if type_equal_legacy(t1, t2) { ok = 1; } sh_compare(t1, t2, ok); }
    return r;
}
```

**与 brief 的唯一结构偏差（如实登记）**：brief 的 `type_equal` 代码块（含 `return` 早退）被落在 `type_equal_engine`，
外层 `type_equal` 保留 P1 的「入口 + 影子包装」两段式。理由：影子挂点必须**唯一**（P1 契约：8 站点经包装层采样一次/次调用），
若把影子塞进 brief 块的三个早退出口会重复三份；且 8 站点调用点零改动（`type_compat_strict` 不变）。
**语义与 brief 逐字一致**：快路径 / 桥接回落 + 计数 / `e==1→true` / `e==0→false` / `e==-1→回落 legacy + 计数`。

### 2.2 计数器与报告通道

- `g_replace_unknown`（引擎 -1 回落）、`g_replace_bridge`（桥接失败回落）——**两因分列**（与 P1 Task 3 Step 0 拆因同因：混记则归因不可恢复）。
- 归零 = `init_types()`（类型表重置 = 判定行号空间作废 → 计数同生命周期；LSP 每请求一次）。
- 打印 = `[type-shadow]` 摘要行尾追加 2 组（前缀不变；Task 2 契约的 5 组 + Task 3 Step 0 的 4 组 → 现 11 组）。
- 影子关时计数器照常累加（自增位于 `if g_shadow_on != 0` 之前且不以它为条件），仅不打印 → 关态输出逐字节不变。
- **交叉证据**：影子侧 `unknown_engine`（影子自查的引擎负值次数）与判定路径 `replace_unknown` 在 71 个语料文件上**逐文件相等**（两个独立计数器、同一批调用）——本次审计脚本逐文件核过，无一失配。

### 2.3 快路径的语义论证（不改判定的依据）

`type_equal_engine` 快路径 `if t1 == t2 { return true; }` 与 `type_equal_legacy` **首行逐字同义**
（legacy:419 同款语句，含负 ti 情形 `(-1,-1) → true`）→ 快路径是 legacy 行为的**严格子集**，不引入任何判定变化，只省一次桥接 + 引擎查询。

---

## 3. 红态对照实验（unknown 政策是**承重**的）

**实验**：本地副本 `/tmp/redctl`（不在仓库内）把 `e == -1` 分支改为 `return true`（「未知当接受」= 违反 unknown 政策），重建后跑同一组探针：

| 探针 | pre（F2 态） | 本任务（正确） | red（unknown→accept） |
|---|---|---|---|
| `c1_genapply_diff`（`Box<int>` vs `Box<string>`，引擎 unknown） | 1 错 | **1 错** | **0 错 ← 不报错地接受** |
| `x2_tuple_elemtype`（元组字段异型，引擎 unknown） | 1 错 | **1 错** | **0 错 ← 不报错地接受** |
| `c1_genapply_diff2` / `n1` / `n5`（引擎确定 0 或约束判定） | — | 不变 | 不变 |

结论：unknown 政策**不是装饰**——不回落即两处类型不匹配被不报错地接受；本任务实现（回落 legacy + 计数）在该两处与替换前逐字同结果。同时说明：**语料面 replace_unknown=0 是因为语料没走到这些分支**（见 §5.4），探针与 C-1 才是这些分支的覆盖通道。

---

## 4. N 不得回身份（Task 2 评审裁决，硬性）

**判定路径的 N 面复核（码级）**：

| 环节 | 位置 | N 是否入判定 |
|---|---|---|
| 快路径 | `checker.cr:489` | 不涉类型内容 |
| 桥接 | `ty_shadow.cr:200` `tt_atom(AK_SEQUENCE, -1, tt_cons(el, tt_nil()))` | **否**——b 槽恒 -1，参数链只含元素项 |
| 引擎 | `type_equiv`/`sub_cover`/`lit_implies` | **否**——只吃类型项；N 从未进入任何项 |
| 回落 | `type_equal_legacy` 数组分支（`checker.cr:433`） | **否**——Task 2 起只比元素 |
| 长度面 | `array_len_constraint_ok`（`checker.cr:342`，判定点 `type_compat_strict`） | **是（唯一入口）** |

**唯一调用方结构性论证**：`type_equal` 全仓仅 `type_compat_strict`（`checker.cr:391`）调用；`type_compat_strict` 恒「先 `type_equal` 再 `array_len_constraint_ok`」。故「N 面拒绝完整性」依赖的条件（所有判定点都经 `type_compat_strict`）由 grep 实证成立——**8 站点全部经 `type_compat_strict`**（:1071/:1309/:1322/:1337/:1577/:1772/:2165/:2499），无裸 `type_equal` 调用点。

**行为级钉死**：`t3.engine_len_not_identity`（§7.1）双断「`type_equal([int;3],[int;4]) == true` ∧ `array_len_constraint_ok(...) == 0`」——引擎不放宽成身份、且拒绝不丢。

---

## 5. 对拍复跑（替换门）

**通道**：影子对照物已切到 `type_equal_legacy`（`type_equal` 包装尾部）；`sh_compare` 内部照旧自算引擎判定 ⇒ 分类语义 = **引擎 vs 旧结构判等**（正是替换门要的对拍）。
**条件**：cwd = 仓库根；每文件 `clean-cache`（冷缓存）；`--type-shadow --type-shadow-dump`；脚本 `/tmp/r2p2t3_run.sh`（P1 三档 + stdlib + examples 扩面，与 P1 同款以保可比）；原始输出 `/tmp/r2p2t3/all_tiers2_final.txt`；基线 P1 `/tmp/r2p1t3/all_tiers2.txt`。

### 5.1 三档结论

| 档 | 文件数 | 有摘要 | decisions | agree | old_stricter | old_looser | unknown | replace_bridge | replace_unknown |
|---|---|---|---|---|---|---|---|---|---|
| T1 `tests/suite/*.cr` | 31（有效 **29**） | 27 | 2743 | 2743 | 0 | 0 | 0 | 0 | 0 |
| T2 编译器自指（`main.cr`/`_import.cr`） | 2 | 2 | 7998 | 7998 | 0 | 0 | 0 | 0 | 0 |
| T3 后端/内核单元 | 15 | 15 | 14055 | 14055 | 0 | 0 | 0 | 0 | 0 |
| T4 stdlib（19）/ T5 examples（4）（扩面） | 23 | 23 | 2193（2042+151） | 2193 | 0 | 0 | 0 | 0 | 0 |
| **合计** | **71** | **67** | **26989** | **26989** | **0** | **0** | **0** | **0** | **0** |

（数字 = Task 4 收官对 final 产物 `/tmp/r2p2t3/all_tiers2_final.txt` 的独立重算值；初稿的 26962/7980/14046 为中间产物值，已按上文注记修正。站点直方图见 §5.3。）

**差异清单归零** ✓（agree = 全部；bounded：见 §5.3 站点覆盖警示）。
**逐文件一致性**：71 文件 rc 与 P1 基线**逐文件相同**（含既有非类型面：`ptr_arith`/`chan_test` rc=1、`at_test_mini4/6` rc=139 = TODO #16 嵌套 fn，均 pre/post 同）；无 summary 的 4 文件（2 个 rc=139 段错误 + **2 个 0 字节空文件** `test_control_flow.cr` / `test_generics.cr` → `error: cannot read` rc=1，**非**「解析失败」）pre/post rc 亦同。**t1 有效语料 = 29**（31 − 2 空文件；措辞更正见 TODO #22）。
**P1 遗留 unknown（9 条）已清零**（F1 去重的收官实证；P1 时代 `generics_test` unknown=2、`hotpatch_test` unknown=1 等）。

### 5.2 收紧清单（Task 4 挂账面）

`old_looser = 0` 全语料 ⇒ **「旧接受 → 新拒绝」为空**。`old_stricter = 0` 亦空（引擎未比 legacy 更宽）。即：替换在语料面**零语义变化**。

### 5.3 站点覆盖（与差异数同报——**0 差异 ≠ 全面覆盖**）

T1–T5 站点直方图（final 产物重算；初稿为 4414/1738/18642，中间产物值）：

```
hotpatch-ret=0  generic-arg=0  generic-apply-base=2  unify-fallback=0
fn-body-ret=4949  assign-binary=0  if-branch=1919  assign-node=20119      sum=26989=decisions ✓
```

- 覆盖 = 站点 **5（返回位）/ 7（if 分支）/ 8（赋值）**；站点 **3** 仅 2 次（`generics_test`）。
- **零命中 = 站点 1（hotpatch 返回）/ 2（泛型实参已绑定）/ 4（unify 后备）/ 6（`EXPR_BINARY+OP_ASSIGN`，parser 已无生产点）**——与 P1 实测一致（P1 交接即要求本项同报）。
- 故「差异归零」的效力范围 = **赋值/返回/if 面**；站点 1/2/4/6 面由**定向探针**承担（P1 探针 A/C/D/G 同款 + 本任务 C-1 探针经站点 8 覆盖泛型应用类；见 §7.2）。
- 每文件恒 `sum(site) == decisions`（**67 条摘要行全部成立**）→ 直方图与主行互为校验。
  ⚠ **校验来源更正（Task 4 收口）**：`/tmp/r2p2t3_run.sh` **不进行**该项校验——脚本只 `grep` 主行/站点行并 `printf`（`:11-13`），无任何求和或断言。该性质由 Task 3 评审、Task 4 收官各自**独立重算**复核（71 行逐行解析，0 违例）。引用时勿把「脚本通过」当作校验证据。
- 直方图的**逐档**分布（final 重算，列序 = fn-body-ret / if-branch / assign-node，另注 `generic-apply-base`）：T1 = 760/215/1766（+2）· T2 = 1425/655/5918 · T3 = 2229/868/10958 · T4 = 501/166/1375 · T5 = 34/15/102；五档合计 **4949/1919/20119** ✓（2743+7998+14055+2042+151 = 26989 ✓）。

### 5.4 unknown / 回落计数与处置

| 项 | 值 | 处置 |
|---|---|---|
| 语料 `replace_unknown` | 0 | 语料未触发引擎未知面 |
| 语料 `replace_bridge` | 0 | 桥接全成功 |
| 探针面 `replace_unknown` | **5 个文件** =1（n5/n6 `G<[int;N]>` + c1 三例 `c1_genapply_same/diff/diff2`；评审更正：原文「3 处」漏计 c1 三例的展开） | **逐条登记**：`TYP_GENERIC_APPLY` 桥接为 `AK_NAMED`（不展开）→ 引擎 -1 → 回落 legacy；语义与替换前一致（agree/结果均无差） |
| 单测覆盖 | `t3.unknown_fallback_legacy` / `t3.bridge_fallback_legacy` | 把两条回落路径钉进 `selftest-types`（计数与判定双断） |

**归因**：`AK_NAMED` 不展开（P0 已登记未覆盖面②）⇒ 命名类型/泛型应用面的等价判定**仍由 legacy 承担**。这不是本次替换的缺陷，而是 P5「删 legacy」的**前置**：引擎命名类型展开实施前，unknown 清零不可达。建议 Task 4 在收紧清单/交 P5 项中明确登记「P5 前必须清零 `replace_unknown`」。

---

## 6. N 面行为探针（原始输出；Task 2 评审 Important，硬性）

**方法**：`--type-shadow` 同时跑，**证明「拒绝来自约束、不是来自身份」**——影子 agree 表示引擎与 legacy 都判「等价」（N-free），而 rc=1 表示约束独立拒绝。这正是「对拍归零不得充当 N 面证据」的正向用法。

| 探针 | 形态 | rc | 结果 | 影子 | 回落 |
|---|---|---|---|---|---|
| `n1_arr_diff` | 顶层 `[int;4]` → `[int;3]`（站点 5 返回位） | 1 | `error[TF01]: Array length constraint not satisfied` | agree=74 全 0 | 0 |
| `n2_arr_same` | 同长对照 | 0 | `ok` | agree=74 | 0 |
| `n3_nested_diff` | **嵌套位 `[[int;4];2]` → `[[int;3];2]`** | 1 | `error[TF01]: Array length constraint not satisfied` | agree=74 | 0 |
| `n4_nested_same` | 嵌套同长对照 | 0 | `ok` | agree=74 | 0 |
| `n5_genapply_diff` | **`G<[int;4]>` → `G<[int;3]>`** | 1 | `error[TF01]: Array length constraint not satisfied` | agree=73 unknown=1 | replace_unknown=1 |
| `n6_genapply_same` | 泛型实参同长对照 | 0 | `ok` | agree=73 unknown=1 | replace_unknown=1 |
| `n7_ptr_diff` | **`*[int;4]` → `*[int;3]`**（形参→返回位） | 1 | `error[TF01]: Array length constraint not satisfied` | agree=74 | 0 |
| `n8_ptr_same` | 指针元素位同长对照 | 0 | `ok` | agree=74 | 0 |
| `x14_tuple_idents` | **`(int,[int;3])` 元组字段位**（元素为单节点：`(1, a)`） | 1 | `error[TA01]: Array length constraint not satisfied` | agree=74 | 0 |
| `x15_tuple_idents_same` | 元组字段位同长对照 | 0 | `ok` | agree=74 | 0 |
| `n9_tuple_diff` | `(1, [int;2/3...])` 元组字段位（元素为**复合表达式**） | 0 | **`ok` ← 未拒绝（F5，见 §9）** | agree=74 | 0 |
| `n10_tuple_same` | 同上对照 | 0 | `ok` | agree=74 | 0 |

**pre/post 逐探针对照**：19 条探针（含 §7.2 的 C-1 三条与 x5/x7/x8/x9/x11/x13 等诊断探针）在 `pre` 二进制（Task 2 收口态）与终态二进制上**逐条同结果**（19/19 SAME，脚本逐条打印）→ 替换未改任何探针行为。
**每条探针的 `agree` 值 = 引擎与 legacy 都判等价**，与「N 不入身份」一致；**拒绝只来自 `array_len_constraint_ok`** ✓ 这是 N 面验收的正确证据形态（对拍归零在此**不**充当证据）。

### 6.1 探针发现（F5，pre-existing，交裁决）

`(int, [int;3])` 位在**元素为复合表达式**时字段类型被记错（`(1, [1,2,3])` 的字段 1 被记成 `int`）→ 该位 N 面无检查、且 legacy 亦比不到 ⇒ **该位异长不报错地通过**。根因见 §9。**不在本任务修复范围**（改 AST 布局/parser，可能动产物），已定向下探：
- `([1,2,3], 1)`（数组在**首位**）→ 正确拒绝（首位 = `parse_expr` 返回值，位置天然正确）；
- `(1, a)`（元素为单节点 ident/字面量）→ 正确拒绝 ✓；
- 三个字段、数组在末位 → 同样漏检。
pre/post 同结果 + 记录在 `checker.cr` F2 头注的「边界」面 → **非本任务引入**。

---

## 7. 单元/管线内证据

### 7.1 `selftest-types` 新用例（85 → 88）

```
PASS t3.engine_len_not_identity     # type_equal([int;3],[int;4])==true ∧ 约束==0（N 不回身份 + 拒绝不丢）
PASS t3.unknown_fallback_legacy     # 互异 named 行 → 引擎 -1 → legacy 判 false ∧ g_replace_unknown 恰 +1
PASS t3.bridge_fallback_legacy      # 行号越界 → 桥接失败 → legacy 判 false ∧ g_replace_bridge 恰 +1
88/88 type-engine cases passed
```

### 7.2 C-1：同名泛型应用跨站点 + 负控（Task 1 交接必测项）

```core
struct Box[T] { val: T }
a : ., mut = Box { val: 1 };   b := Box { val: 2 };   a = b;        // 正控：两个不同出现点的 Box<int>
a : ., mut = Box { val: 1 };   c := Box { val: "s" };  a = c;        // 负控①：同名不同实参
a : ., mut = Box { val: x };   c := Box { val: y };    a = c;        // 负控②：Box<[int;3]> vs Box<[int;4]>
```

| 探针 | rc | 输出 | 影子/回落 |
|---|---|---|---|
| `c1_genapply_same`（正控，站点 8） | 0 | `ok` ← 同名跨站点**判等**（F1 去重的目标语义） | agree=73 unknown=1 / replace_unknown=1 |
| `c1_genapply_diff`（负控①） | 1 | `error[TA01]: Assignment type mismatch` ← **不同实参不得判等** | 同上 |
| `c1_genapply_diff2`（负控②，N 面负控） | 1 | `error[TA01]: Array length constraint not satisfied` ← 实参同族异长不判等 | 同上 |

三条均走「引擎 unknown（APPLY→AK_NAMED 不展开）→ 回落 legacy」→ 该面由 legacy 提供判等，**两侧结果与替换前一致**。

### 7.3 C-4：侧表 ↔ `res_type_node` 管线内断言（替换弱断言 `f1.row_count`）

**实现**：隐藏通道 `--verify-named-dedup`（默认关；`check`/`build`/`cir`/`ccr`/`run` 共用 `run_frontend` 尾部调用，一次全局读 + 返回；先例 = `--inject-var-shift`）+ `checker.cr:named_dedup_verify()` 三组断言（类型表→侧表回指 / 侧表→类型表合法行 + 名字恰 1 行 / AST 类型名引用经 `res_type_node` 落回侧表同一行）+ 套件 `tests/selfhost/test_named_dedup.py`。

**真实语料（`tests/suite/at_test_struct.cr`，noclobber 重定向）**：

```
$ nice -n 19 ./build/corec check tests/suite/at_test_struct.cr --verify-named-dedup ; echo rc=$?
[named-dedup] named_rows=2 ident_checks=5 mismatches=0
rc=0
```

**负数控制（注入故障，实证断言非空转）**：本地副本 `/tmp/negctl`（不在仓库内）把 **struct 注册点**（`collect_decls` 首个分配点）退回裸 `alloc_type(TYP_NAMED, name_idx, 0)` → 重建 → 同命令：

```
[named-dedup] named_rows=2 ident_checks=5 mismatches=6
rc=1                      ← 6 条不一致：该名字的行使侧表缺失/读取面 res_type_node 落不回侧表
```

⇒ 该断言**能**捕获「生产分配点绕过侧表」，不是同义反复；`ident_checks=5 > 0` 排除断言③空转。

---

## 8. 判据原始输出

### 8.1 ELF 与两态零变化（冷缓存；cwd = 仓库根）

```
$ nice -n 19 ./build/corec clean-cache
$ nice -n 19 ./build/corec build tests/suite/ptr_arith.cr --static -o /tmp/p2a_t3_bin_f2
$ cmp /tmp/r1t4_base_bin /tmp/p2a_t3_bin_f2 && echo ELF-IDENTICAL
ELF-IDENTICAL
$ sha256sum /tmp/p2a_t3_bin_f2
95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475   ← 与基线逐字节同（未走「停下上报」分支）

$ nice -n 19 ./build/corec build tests/suite/ptr_arith.cr --static --type-shadow -o /tmp/p2a_t3_on_final
[type-shadow] decisions=74 agree=74 old_stricter=0 old_looser=0 unknown=0 unknown_bridge=0 unknown_engine=0 unknown_engine_uncovered=0 unknown_engine_budget=0 replace_bridge=0 replace_unknown=0
[type-shadow-sites] hotpatch-ret=0 generic-arg=0 generic-apply-base=0 unify-fallback=0 fn-body-ret=16 assign-binary=0 if-branch=7 assign-node=51
$ cmp /tmp/r1t4_base_bin /tmp/p2a_t3_on_final && echo ON-IDENTICAL
ON-IDENTICAL

$ ./build/corec check tests/suite/ptr_arith.cr            → rc=1（既有 error[B04]），shadow 行 0 条
$ ./build/corec check tests/suite/ptr_arith.cr --type-shadow → rc=1
$ 过滤 shadow 行后 cmp → CHECK-STDOUT-IDENTICAL
（sum(site)=0+0+0+0+16+0+7+51=74=decisions ✓；与 P1 Task 4 基线逐字段同）
```

### 8.2 `.ccr`（允许变，须实测；**冷缓存 + cwd = 仓库根**）

| 语料 | pre（Task 2 收口二进制） | post（终态二进制） | 判定 |
|---|---|---|---|
| `tests/suite/ptr_arith.cr` | `bb9cbdb87f4f…` | 同 | **IDENTICAL** |
| `tests/suite/at_test_struct.cr` | `53ebcf122deb…` | 同 | **IDENTICAL** |
| `tests/suite/generics_test.cr` | `2132d565778c…` | 同 | **IDENTICAL** |
| **`src/compiler/main.cr`（自指语料，C-5 收口）** | `e94e488f10c4…` | 同 | **IDENTICAL** |

**自指语料归因隔离**：`pre` 与 `post` 均以**同一份（终态）源码**为输入 ⇒ 上述「未变」可归因到**编译器改动**本身（而非源码变化）。
（对照：以「首建二进制 + 旧源码」产出的 `1a90975f…` 与终态不同——成因 = `type_selftest.cr` 新增用例属**源码内容变化**（该文件在 `main.cr` 编译单元内），本任务实测：换用 pre 二进制编译**同一份**终态源码产物与终态二进制**逐字节同** `e94e488f10c4` ⇒ 二进制改动零影响。）

### 8.3 自举链（终态）

```
$ nice -n 19 ./build/corec build src/compiler/main.cr -o /tmp/p2a_t3_corec2f --static -O 0   # rc=0
$ nice -n 19 /tmp/p2a_t3_corec2f build src/compiler/main.cr -o /tmp/p2a_t3_corec3f --static -O 0  # rc=0
$ cmp /tmp/p2a_t3_corec2f /tmp/p2a_t3_corec3f && echo CMP_IDENTICAL
CMP_IDENTICAL
N06 计数：0 / 0
error[ 计数：2 / 2   ← 两阶段逐字同，均为既有 TF01 误报：lits_copy(8595) / ty_memo_slot_no_grow(8710)
$ nice -n 19 ./build/corec run 'fn main()->int{return 42;}'
smoke_rc=42
```

> **行号更正（Task 4 收官，评审 Minor）**：初稿此处写 `lits_copy(8593) / ty_memo_slot_no_grow(8708)`——该数字取自 `/tmp/r2p2t3/corec2_build_f.log`，而**产物生成于最终注释编辑之前**（`ty_shadow.cr` 末次改动晚于该日志）。Task 4 以两路实测更正为 **8595 / 8710**：① 终态二进制编译 `main.cr`（Task 4 源）→ 8595/8710；② 拿 **Task 3 冻结源**（`/tmp/p2a_t4/selfsrc_t3/`，`jj` 只读提取 + rsync 副本）配 **Task 3 终态二进制** → 同样 8595/8710 ⇒ 初稿数字为陈旧日志值、非源差异所致。`error[ 计数 = 2/2` 与 `cmp IDENTICAL` 结论不变。
### 8.4 全回归（Task 3 提交态：已跑集 = 17 selfhost + 5 bootstrap + `selftest-types`，rc=0）

```
selftest_types          88/88 type-engine cases passed
test_type_engine        PASS test_selftest_types_all_pass
test_compile            All selfhost compile tests passed.
test_backend_bootstrap  [PASS] stage0 and stage1 O2 smoke ELFs return 7
test_hit_table          24/24 passed          test_ccr_v7      24/24 passed
test_live_ranges        13/13 passed          test_slice_bounds 7/7 passed
test_global_init        15/15 (dual path)     test_lexer_parity PASS
bootstrap_pipeline      29/29 passed          bootstrap_borrow 4/4
bootstrap_generics      3/3 passed            selfhost_impl    7/7
selfhost_borrow         7/7 passed            test_pointer_safety PASS
test_region_cfg         22/22 passed          test_dex_type    5/5
test_apx_tag            2/2                   bootstrap_modules PASS
bootstrap_apx_tag       5/5 passed            test_directory_build PASS
test_named_dedup        PASS test_named_dedup_pipeline_assertion（新增，C-4）
```

---

## 9. 登记（交下游 / 评审裁决）

**F5（pre-existing 缺陷，本任务发现并定位 root cause；不在 Task 3 范围）**
`EXPR_TUPLE` 的**元素连续槽位假设**在元素为**复合表达式**时不成立 → 元组字面量字段类型被记错（`(1,[1,2,3])` 的字段 1 记为 `int`）。
- **root cause（实读）**：`parser.cr:487` 的元组分支只记 `ef = parse_expr()` 的首元素节点 + `ec` 元素**个数**，注释「stored in consecutive g_ast slots」对**复合元素**不成立（复合表达式自身占多个 AST 槽：`[1,2,3]` 的数组节点在其 3 个子节点之后）；而 `checker.cr:2639`（`infer_expr`）、`ir_gen.cr:2207`、`monomorph.cr:296`（注释原文「elements are consecutive」）、`opt.cr:177` 全按 `a+0..a+ec-1` 读取。
- **对照物**：**结构体字面量有 wrapper 机制**（`parser.cr:459` 每字段值后 `ast_alloc(0, fv, …)` 建转发节点 → 字段恒连续），元组分支缺同款。
- **影响（Task 3 评审加码，全谱）**：① **假拒绝**（类型面）：`(1,a)` vs `(1,[1,2,3])`（**语义同型**）→ 误报 `error[TA01]`；② **soundness 漏放**：`(1,[1,2,3])` vs `(1,h())`（`h()->int`，**异型互赋**）→ **不报错地接受**；③ 该位 N 面无检查（`(int,[int;3])` 的复合元素形态不报错地通过——本报告 §6 的 `n9_tuple_diff` / `n10_tuple_same` 即该位实测）；④ 潜在 IR 生成面（`ir_gen` 同假设）——**本任务未展开验证**。
- **实证**：`/tmp/dbgctl`（本地副本，含打印）实测 `[dbg-tuple-field] i=1 fa=0 kA=0`（应为 `kA=2 exA=3` 的数组行）；`([1,2,3],1)` 首位数组正确（`fa=10 kA=2 exA=3`）；①② 探针见评审复核件（本报告未收录；同源机制见 §6 的 `n9_tuple_diff`——元组字段类型错录的两种表现：假拒与漏放）。
- **同批登记**：`opt.cr:177` 的分支读 `ast_b`/`ast_c` 而约定是 `a`/`b` ⇒ 数组/元组元素优化**恒空转**（无正确性影响，同属 a/b 槽约定写错家族）——与 F5 同一 TODO 条目内登记。
- **为何不在本任务修**：修法（补 wrapper 或改元素存储）动 AST 布局 + **4 个消费者**，且可能改变产物（`.ccr`/ELF）——须列 Task（含 ELF 逐字节判据）单独裁决。**Task 4 已登记 TODO #25**（判据 = 3 条新探针（异长拒/同型接受/异型拒）+ `selftest-types` + 4 消费点复核 + ELF/`.ccr` 逐字节 + 全回归）。
- **边界**：pre/post 行为逐条同（§6）⇒ 与 Task 3 无因果。

**C-1（覆盖）**：站点 1/2/4/6 语料零命中（同 P1）→ 差异归零的效力范围限于赋值/返回/if 面；站点 1/2/4 面由 P1 定向探针 + 本任务 C-1（经站点 8）覆盖，站点 6 无生产点（TODO #17）。
**C-2（性能/开销）**：判定路径由「一次结构比较」变为「桥接缓存查 + 两次 `ty_budget_reset` + `ty_equiv`」（未知时再叠一次 legacy）。实测：`check src/compiler/ccr_io.cr`（4200+ 判定）关/开两态均 ~1.7s（P1 前同量级）；`corec2/corec3` 自举全链通过。**残留风险**：引擎 `ty_budget_reset` 每次判定重建 memo（24KB 分配/次）——语料规模无感，若 P2b/P5 后语料放大需复测。
**C-3（计数器可见性）**：`replace_*` 只在 `--type-shadow` 下打印（关态输出逐字节不变是硬判据）；判定路径两态同码（§2.2），并以 `unknown_engine ↔ replace_unknown` 逐文件相等作交叉证据。
**C-4（新增隐藏通道）**：`--verify-named-dedup` 为调试通道（先例 `--inject-var-shift`），默认关、零产物影响；`test_named_dedup.py` 使其成为常驻判据。
**C-5（未实测面，如实登记）**：① 负控（注入故障）在**仓库外副本**完成（避免污染仓库/需重建两个编译器）；树内只保留正控断言；② `array_len_constraint_ok` 的 REF/SLICE 下钻位用例仍归 Task 4（Task 2 评审 M2 收口项）——**Task 4 已补**（`f2.ref_elem_reject` / `f2.slice_elem_reject` + 站点三态分派 `t3.strict_dispatch_{ok,identity,len}`，见 Task 4 收官报告）；③ 全语料**诊断文本**逐条 diff 未做（以逐文件 rc + 自举守卫 `error[=2/2` 既有误报逐字同替代）。

---

## 10. 与计划/brief 的偏离与自检

| 项 | 计划/brief | 实际 | 理由 |
|---|---|---|---|
| 函数划分 | `type_equal`（含早退）+ `type_equal_legacy` | 增 `type_equal_engine`（判定主体），`type_equal` = 入口 + 影子包装 | 影子挂点唯一（P1 契约）；8 站点零改动；语义逐字同 brief（§2.1） |
| 计数器 | `g_replace_unknown` | `g_replace_unknown` + `g_replace_bridge` | 两因分列（P1 Task 3 Step 0 同因：混记则归因不可恢复） |
| 用例数 | —（brief 未列） | `selftest-types` 85 → **88** | N 不回身份 / unknown 回落 / 桥接回落 三条不变量落常驻判据 |
| 新文件 | brief Files 未列 | `tests/selfhost/test_named_dedup.py` | C-4 断言的常驻判据（评审可复跑；Task 2 亦有「用例数偏离」先例） |
| `init_types` 归零 | brief 未提 | 加两行归零 | 计数与行号空间同生命周期（LSP 每请求隔离） |

**占位符扫描**：无 TBD / 无「稍后填」。**命名一致性**：`type_equal_engine` / `type_equal_legacy` / `g_replace_unknown` / `g_replace_bridge` / `named_dedup_verify` 全仓一致。

---

## 11. 原始材料索引

| 内容 | 路径 |
|---|---|
| P1 基线（pre） | `/tmp/r2p1t3/all_tiers2.txt` · `/tmp/r2p1t3/probes/` |
| 终态对拍（post） | `/tmp/r2p2t3/all_tiers2_final.txt` · `/tmp/r2p2t3/logs2/` · `dumps2/` |
| 语料脚本 | `/tmp/r2p2t3_run.sh`（P1 同款，仅换 OUT） |
| N 面/C-1 探针 + 日志 | `/tmp/r2p2t3/probes/*.cr` · `/tmp/r2p2t3/probes_final/*.log` |
| C-4 正控/负控输出 | `/tmp/real_verify.txt`（mismatches=0）· `/tmp/negctl_verify.txt`（6/rc=1） |
| 注入故障副本 | `/tmp/negctl`（生产点绕过侧表）· `/tmp/dbgctl`（元组布局打印）· `/tmp/redctl`（unknown→accept 反例） |
| 回归日志 | `/tmp/r2p2t3/reg/*.log` · `summary.txt` |
| 自举日志 | `/tmp/r2p2t3/corec2_build_f.log` · `corec3_build_f.log` |
| pre 二进制 | `/tmp/p2a_t3_pre_corec`（Task 2 收口态；help 无新 flag = 身份可核） |
| 基线 ELF | `/tmp/r1t4_base_bin`（sha256 `95084e7b…d475`） |

---

## 12. 提交

jj change `lmqvrnyktmlrkkkvvwrmltrmpwyzxvzk`（短 `lmqvrnyk`）/ commit `10718ba82b673b99ae772ff1d77982d6a8825af2`（短 `10718ba8`），
路径限定 **6 文件** `+271 / -22`：`src/compiler/checker.cr`（+153/-16）· `src/compiler/globals.cr`（+12）· `src/compiler/main.cr`（+7）·
`src/compiler/ty_shadow.cr`（+20/-2）· `src/compiler/type_selftest.cr`（+33）· `tests/selfhost/test_named_dedup.py`（+58，新增）。
提交后 `jj status` 为空。本报告不在 VCS（`docs/archive/sdd/.gitignore` = `*`）。

---

# 13. P2a 终审 Critical 修复：桥接缓存随类型表重置失效（2026-09-11）

**评审裁决**：P2a 全批终审 = NOT READY（1 项 Critical，**本批引入且已实测复现**）——`g_shadow_map`（ti→term 桥接缓存）**无 reset**。
**本节记录**：机制 → 修法 → 用例（含双负控）→ 全量复验。§1–§12 为 Task 3 提交态（`10718ba8`）的历史记录，数字以本节为终态。

## 13.1 机制（本批引入）

- Task 3 前：`sh_term_of_ti` 仅 `--type-shadow` 下被调（纯观察通道）。
- Task 3 后：`type_equal_engine` **无条件**调它（判定路径）。
- 而 `init_types()` 只清**类型表**（`g_type_count = 0`）与 `named_dedup` 侧表，**未清桥接缓存**；缓存键 = `ti` **本体**。
- ⇒ 长驻进程（corelsp 每请求 `reset_frontend_state → check_all → init_types`）里**行号空间复用**，陈旧的 `ti→term` **命中即返回** ⇒ **两个不同类型被判等**（不报错地漏报）。
- 同类先例已在本仓成立过：`named_dedup_reset`（Task 1 评审 C-3① 纠错）正是同因（陈旧 name→ti 跨重置复用 = 不报错地错型）；本批漏了桥接缓存的同款钩子。

**评审复现（照录）**：`build/corelsp` 同 URI 两次 `didOpen`——V1 = `a:[int;3];b:[int;3];b=a;` → V2 = `a:[bool;3];b:[int;3];b=a;` ⇒ **V2 diagnostics=0**（新进程单跑 V2 应为 1 条 `Assignment type mismatch`）；对 base `b58abbcf` 重建后同序列正常。

## 13.2 负控（修复前必红）——原始输出

**（a）LSP 双请求用例（本仓用例体，BIN 指向修复前二进制副本）**

```
$ nice -n 19 python3 /tmp/r2p2t3/lsp/test_lsp_prefix.py     # BIN = /tmp/p2a_t3b_pre_corelsp（修复前）
  PASS test_stdout_pollution_guard
  PASS test_large_frame_body
  FAIL test_double_open_bridge_cache_reset: AssertionError({'jsonrpc': '2.0', 'method': 'textDocument/publishDiagnostics', 'params': {'uri': 'file:///tmp/bridge_cache_reset.cr', 'diagnostics': []}})
FAILED: test_double_open_bridge_cache_reset
lsp suite: FAIL (1/10 tests failed)          ← 只有新用例红，其余 9 项绿（红点定位精确）
```

独立复现脚本（同序列，直读诊断条数）：`/tmp/r2p2t3/lsp/repro.py <corelsp>`

```
$ nice -n 19 python3 /tmp/r2p2t3/lsp/repro.py /tmp/p2a_t3b_pre_corelsp
V1 diagnostics: 0
V2 diagnostics: 0
REPRO: RED(缺陷在)                            ← 修复前：V2 漏报（应 1）
$ nice -n 19 python3 /tmp/r2p2t3/lsp/repro.py build/corelsp
V1 diagnostics: 0
V2 diagnostics: 1
V2 首条: Assignment type mismatch
REPRO: GREEN(修复后)                          ← 修复后：V2 报出 1 条
```

**（b）自测用例突变控制**（副本 `/tmp/mutctl` 删掉 `init_types()` 里的 `sh_map_reset();` 调用后重建）：

```
$ nice -n 19 ./build/corec selftest-types        # /tmp/mutctl（已突变）
FAIL t3c.map_reset_clears_bridge: got 0 want 1
FAIL t3c.no_stale_term_after_reset: got 0 want 1
93/95 type-engine cases passed                   ← 仅这两例红（用例有牙）
$ nice -n 19 ./build/corec selftest-types        # 本仓（未突变）
PASS t3c.map_reset_clears_bridge
PASS t3c.no_stale_term_after_reset
95/95 type-engine cases passed
```

## 13.3 修法（照 `named_dedup_reset` 先例）

```core
// ty_shadow.cr（新增；经 init_types() 调用）
fn sh_map_reset() {
    g_shadow_map_cap = 0;      // 惰性重建（空槽全 -1）
    g_shadow_entries = 0;
    g_shadow_hits = 0;         // 否则装填守卫按陈旧计数提前扩容、hits 跨请求失去诊断意义
}
// checker.cr init_types()
    named_dedup_reset();
    sh_map_reset();            // 桥接缓存（ti→term）同理必须作废（本批起判定路径无条件调 sh_term_of_ti）
```
**同时更正 `ty_shadow.cr` 头注失真**：原文「`--type-shadow` 关时**除 `g_shadow_on` 自身外**连读都不发生」在 Task 3 后**不成立**——判定路径无条件读写桥接缓存与 `g_shadow_hits/entries`。改写为：① 桥接缓存必须随类型表失效（本修复）；② 本层「只观察」的准确含义 = 「不写 checker 判定状态、不改判定结果、不写产物」，**不是**零写入；③ 仅剩的影子专属读数 = `g_shadow_on` 早退的 `sh_compare`/`sh_site_begin`/`sh_report`/`sh_dump_write`。

## 13.4 回归用例（新增 2 + 1）

| 用例 | 位置 | 断言 |
|---|---|---|
| `t3c.map_reset_clears_bridge` | `type_selftest.cr` | 建项后 `sh_map_entries() >= 1`；`init_types()` 后 `entries == 0 ∧ cap == 0`（惰性重建） |
| `t3c.no_stale_term_after_reset` | 同上 | 行号复用场景（重置前后同一 ti 号）：新项**不得**等于陈旧项，且元素 AK 由 `AK_INT` 变 `AK_BOOL`（行为级对偶——只查计数的断言在「清了计数但表还活着」的错法下会假绿） |
| `test_double_open_bridge_cache_reset` | `tests/selfhost/test_lsp.py`（TESTS 第 10 项） | 同 URI 两次 didOpen（只换 `a` 元素型 int→bool）：V1 诊断 0 条、**V2 恰 1 条且措辞含 `Assignment type mismatch`** |

## 13.5 全量复验（终态；cwd = 仓库根）

| # | 判据 | 结果 | 证据 |
|---|---|---|---|
| 1 | `selftest-types` | **95/95**（>= 93 要求） | §13.2(b) |
| 2 | ELF 关态 / 开态 | **IDENTICAL** `95084e7b…d475` | `cmp /tmp/r1t4_base_bin /tmp/p2a_t3b_bin` · `… /tmp/p2a_t3b_on` |
| 3 | `.ccr` 冷缓存对照（4 语料，含自指 `src/compiler/main.cr`） | **4/4 IDENTICAL**（pre = 修复前二进制，同源码） | `/tmp/r2p2t3/ccr/{fx,fy}_*.ccr` |
| 4 | 自举链 | **CMP_IDENTICAL + N06=0/0 + `error[`=2/2（既有 TF01 误报逐字同）+ 冒烟 rc=42** | `/tmp/r2p2t3/corec{2,3}_build_b.log` |
| 5 | 对拍复跑（T1–T5 = 71 文件，影子对照物 = legacy） | **24853/24853 agree（T1–T3）· 全五档 27046/27046**；`old_stricter=0 old_looser=0 unknown=0 replace_bridge=0 replace_unknown=0`；站点 `fn-body-ret=4417 if-branch=1738 assign-node=18696 generic-apply-base=2`（**1/2/4/6 仍零命中**）；71 文件 rc 与 P1 基线逐文件同；`unknown_engine == replace_unknown` 逐文件成立 | `/tmp/r2p2t3/all_tiers2_fix.txt` |
| 6 | 全仓套件 | **38 套件 rc=0**（21 selfhost + 8 bootstrap + `selftest-types`；含 `test_lsp` **10/10**、`test_named_dedup`、`test_compile`、`test_ccr_v7` 24/24、`test_ent_kernel_neutrality`、`test_mw_task1..6`、`test_native_*`、`test_interp_float`） | `/tmp/r2p2t3b/reg/summary.txt` |

**注**：任务中途 lead 代跑的两项（BUILD SUCCESS、`selftest-types` 95/95、`test_lsp` 10/10）与上表一致；本表全部为修复后亲跑。

## 13.6 文档项（评审清单，逐条落点）

| 项 | 落点 |
|---|---|
| 「3 处」→ **5 个文件**（n5/n6 + c1×3） | 本报告 §5.4（已改）+ TODO.md §24 未覆盖面②（已改） |
| 悬空「§6.1」引用 | 本报告 §9 F5 条目两处（③ 改指 §6 的 `n9_tuple_diff`/`n10_tuple_same`；①② 改指评审复核件 + 同源机制定位点点） |
| `ty_shadow.cr` 头注失真（「关时连读都不发生」） | `ty_shadow.cr` 头注改写（§13.3 末段） |
| 「23 套件」→「已跑集（17 selfhost + 5 bootstrap + selftest-types）」 | 本报告 §8.4 / 判据一行 / 总表 #13（已改；终态 38 套件见 §13.5 #6）+ TODO.md §24「行为面兑现」（已改） |
| TODO 登记①：桥接缓存 + `type_equal_legacy` = 「调试结构进生产路径」族，P5 前清偿 | TODO.md §24「同族清偿（P5 前必办）」 |
| TODO 登记②：F2 的 4/6 下钻位缺**突变控制** | TODO.md §24「覆盖清单（Task 4 挂账 → 由终审转入本条）」 |

## 13.7 提交

两个提交：① `10718ba82b673b99ae772ff1d77982d6a8825af2`（Task 3 本体，见 §12）；
② `6806a5ebd7a3aa739c91f7795d133b6cae9ba23a`（jj change `kruqpnky`）＝ **本修复**，路径限定 5 文件 `+112 / -5`：`src/compiler/checker.cr`（+4）· `src/compiler/ty_shadow.cr`（+23/-3）· `src/compiler/type_selftest.cr`（+27）· `tests/selfhost/test_lsp.py`（+53）· `TODO.md`（+5/-2）。提交后 `jj status` 仅余他人在飞的 spec 草稿（未纳入）。本报告不在 VCS。

**边界（如实登记）**：本修复只补**缓存失效钩子**；「桥接结构进生产路径」的**结构性**清偿（引擎命名展开、桥接层退化为纯调试通道、隐藏通道清理）仍归 P5，已登记 TODO.md §24。缓存键若将来引入「编译器身份/环境身份」分量（TODO #5 家族），本钩子仍应按「类型行号空间失效」语义保留——两者不冲突（本钩子管**同进程跨请求**，缓存键管**跨二进制/跨环境**）。
