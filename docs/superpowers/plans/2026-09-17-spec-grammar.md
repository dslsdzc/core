# 批 6：验证内核管线正式接入（**正式规约语法** `#check` / `#ensure`）

> **状态**：实施计划（**规划轮落纸**）。开工前置 = §3.1 六门（**已由维护者按默认取裁**）+ §3.2 本批新门（**逐条给推荐，未取裁前不实施**）。
> **定位（受众/状态/真源）**：受众 = 批次实施代理 + 维护者；状态 = **计划（待实施）**；真源 = 本文（切片边界/任务卡/判据）+ `docs/maintainer/design/spec-design.md`（规约设计权威）+ `docs/superpowers/plans/2026-09-16-verification-slice.md`（切片草案，本批 = 其 C1 的正式接入）。
> **诚实边界（**须先读**）**：本计划**只读侦查、零源码改动、零构建**（未跑 `build/corec` / 未跑任何套件）。**行号 = develop `dbadb8d6` 工作树实读值**（下一任务开工时**须重取**——本仓「纸面成果只对当轮 revision 有效」口径）。凡**推断/预测**一律标「**预测**」；凡实读一律给 `file:line`。代价估计为**相对量级**（小/中/大），非工时。
> **体例**：照本仓 SSDD（现状根因 / 候选方案 / 裁决门 / 判据设计 / Global Constraints / 停条件 / 任务卡 / 自检）。

**Goal**：让 Core **正式获得规约语法**——用户写下 `#check(expr)` / `#ensure(expr)` ⇒ 前端**词法识别、语法成链、检查成形、生成 VC 记录、经 dump 通道打印出来**。**本批不判定真值**（唯一例外 = 常量折叠出的「常量假」⇒ 硬错），**不接求解器、不接 CIC 内核、不做 spec fn/量化/翻译桥、不落 `.csr`**。

**Architecture（第一刀的实际形态，与草案 §Architecture 的**唯一实质差异** = 「编图」出列，见裁-S4）**：

```
.cr 源码（#check/#ensure 标注）
  → lexer：`#` 新 token（T_HASH = 101；紧邻 IDENT，**不**做关键字）
  → parser：函数**签名与 body 之间**的标注链 → 表达式复用 parse_expr，节点落 g_ast（**不被 body 引用**）
  → parser/checker：标注记录落**侧表**（函数 × 序）——不挤 EXPR_FN 的 a/b/c 槽
  → checker：三查（bool 型 / 名字域 / 纯度——本批子集无调用 ⇒ 纯度项**空转**，见裁-V5 推论）
  → VC 记录 + 状态（green 常量真 / yellow 未证 / red 常量假）
  → 输出通道（裁-V2：**dump 先行**）：`corec … --dump-vcs`（stdout；**零新产物**）
  → 消费者：人/外部工具按行读；`.csr` 转下一刀
```

**关键边界（三条，全部由已裁门推出）**：
1. **零足迹**：不含 `#` 的程序 ⇒ **逐字节不变**（canary 五条 IDENTICAL + 腿①74 + 腿②29）。
2. **不阻断**：未证（yellow）**只进 dump，不进诊断通道**——否则 `main.cr:140-175` 的 fail-closed 闸门（默认阻断）会把它变成 rc=1，**直接违反裁-V6**。
3. **唯一硬错**：`#check(常量假)`（可判定且必错）⇒ 新诊断码 + rc=1 + 零产物。

---

## 1. 现状根因 / 起点实核（**逐条实读**；行号 = develop `dbadb8d6`）

### 1.1 `#` 词法面 = **零**（草案结论复核：**成立**）

| 事实 | 实读证据 |
|---|---|
| 注释只有 `//` 与 `/* */`，**无 `#` 注释** | `src/compiler/lexer.cr:381-400`（两条注释分支；字符码 47/47 与 47/42） |
| **全 lexer 无 `#`（字符码 35）任何分支** | `grep -n "'#'\|T_HASH\|HASH\|annotation" src/compiler/lexer.cr` = **0 命中**（599 行全文） |
| **未知字符 = 静默跳过**（关键，草案未记） | `src/compiler/lexer.cr:590-592`：`// Unknown` ⇒ `_pos = _pos + 1; _pos = _skip_ws(...); continue;`——**不 `add_error`、不产 token** |
| 关键字表 = 34 个 if 链（`None/Some` 亦在其中） | `src/compiler/lexer.cr:71-109`；`T_NONE/T_SOME` = `ast.cr:87-88`，由 `lexer.cr:105-106` 产出 |
| token 常量空间现状：**最大 100**，且**有空洞** | `src/compiler/ast.cr:5-100`：`T_EXTERN : int = 100`（末位）；空洞 = 6 / 77-86（宽度后缀退役残留）/ 91（`T_FLOAT_TYPE` 已删）。`ast.cr:84-86` 明写「**勿重编号**——编号空间稳定」 |
| token kind 与 AST kind **共用同一整数空间**（不同上下文） | `T_IDENT=1` vs `EXPR_INT=1`（`ast.cr:6` vs `:157`）等 ⇒ **新 token 号只须不与既有 token 号撞**，与 `EXPR_*` 无关 |

**⇒ 根因一句话**：`#` 今天在**词法层不存在**——不是「注释」，是「**被静默丢弃的垃圾字符**」。

### 1.2 **零足迹硬闸的构造性证据（本批最关键的新事实，可证伪）**

**全仓 `.cr` 静态扫描（本计划实跑，只读）**：剥掉 `//` / `/* */` 注释、`"…"` 字符串（含转义）、`'…'` 字符字面量后，**182 个 `.cr` 文件中裸 `#` = 0 个**（扫描范围 = 全仓除 `.git`/`build`）。

⇒ **在词法层加 `#` token 不可能改变任何既有 `.cr` 语料的 token 流**（`#` 只出现在注释与字符串里，两者都被既有分支完整消费）。这是「canary 五条 + 腿①74 + 腿②29 必须 IDENTICAL」的**构造性**依据，不是经验观察。

**同扫描的否证面（须一并记住）**：`#` 在**非 `.cr` 文件格式**里是**行注释首**——`src/arch/hit/hit.cr:264/:382`（HIT 表）、`src/compiler/module.cr:245`（`.so` 索引）、`src/kernel/kernel_main.cr:105` + `src/kernel/test_term_io.cr:82`（kernel 行格式）、`src/arch/hit/lower_to_core.cr:340`（注释叙述）。**这四处都是「读文件字节后按 35 判列」，不经 Core 词法器** ⇒ 与 `#` token **零交互**（须在 T1 判据里钉住：这四面的行为**不变**）。

### 1.3 **两编译器分歧（草案未记；本批必须处置，见裁-S7）**

| 前端 | 对未知字符 `#` 的行为 | 实读 |
|---|---|---|
| **self-hosted** `src/compiler/lexer.cr` | **静默跳过** | `:590-592` |
| **Python bootstrap** `bootstrap/corec/frontend/lexer.py` | **响亮报错** `Unexpected character: '#'`（`SyntaxError`） | `bootstrap/corec/frontend/lexer.py:287` |

⇒ 今天**同一份带裸 `#` 的源**：`corec` 静默丢字符继续跑，bootstrap **直接拒**。加 `#` token 后 self-hosted 侧改成合法 token；bootstrap 侧**若不动**，则「bootstrap 拒 / corec 收」的分歧从「静默 vs 响亮」升级为「**拒 vs 收**」——分歧性质变了（从 fail-loud 的一侧失守，变成两前端接受集不同）。
**影响面实核**：`build_selfhost_native.py` 的 concat 清单（`:35 common_files` / `:103 backend_support_files` / `:311 corec_files` / `:405 corelsp_files`）**只含 `src/**`，不含 `tests/**`** ⇒ 只要 `#` 标注**不进 `src/**`**，bootstrap 在本批**不会被喂到** `#`。既有对照先例 = `tests/selfhost/test_lexer_parity.py`（两前端对 `_`/宽度后缀**同判**是本仓既有口径）。

### 1.4 EBNF 面 = **零**（复核：成立；且 EBNF 是**文档产物、无消费者的解析器**）

- `grammar/*.ebnf` 全文 **`#` 0 命中**（`grep -n "#" grammar/*.ebnf` = 空）。
- `FunctionDecl`（`grammar/core.ebnf:12-13`）= `[ 'pub' ] 'fn' IDENT [ GenericParams ] '(' [ ParamList ] ')' '->' Type ( FunctionBody | '=' Expr ';' )` ⇒ **无标注槽**。
- EBNF **无机械消费者**（grep 全仓：无工具读它）⇒ 但它**被判定引用**（`src/ci/run.sh:45`、`src/compiler/parser.cr:912`、`tests/selfhost/test_nested_fn.py:5` 用它论证「嵌套 fn 不属语言面」）⇒ 改语言面**必须同步**，否则判定引用变成假前提。

### 1.5 parser 面 = **零**；**插入点已锁定**

| 事实 | 实读 |
|---|---|
| `parse_body` = 形参 → `)` → `->` Type → **body** | `src/compiler/parser.cr:1366-1471` |
| **标注链的插入窗口 = 返回类型解析之后、body 之前**（即 `:1440` 与 `:1442` 之间） | `:1436-1440`（`if check(T_ARROW) { advance_tok(); rt = parse_type(); rtv = unpack_type(rt); }`）→ `:1442-1449`（`if check(T_LBRACE) { body = parse_block(); } else { advance_tok(); body = parse_expr(); advance_tok(); }`） |
| `EXPR_FN` 的槽语义（新标注**不得**挤占） | `:1451` `alloc_node(EXPR_FN, fn_ni, pf, pc, rtv + hotpatch_ver*256, rt, body, fn_line, fn_col)` = `a=名 ni, b=首形参, c=形参数, int_val=返回型+hotpatch, type_val=返回类型节点, data=body` |
| **既有 `@` 标注先例（形态可借，sigil 不同）** | `:1491-1500` `@hotpatch(ver=N)`：**声明前**用 `parse_expr()` 解析 + `:1473-1490` `parse_ffi_annotation()`（`@ffi("lang")`）⇒ **「`@` = 声明前 / `#` = 签名后」两套位置不重叠**（spec-design §六 定稿同此） |
| `check(k)` 是 **token 谓词助手**（非规约面） | `:30`（**这条事实是本批裁-S1 的证据**：`check` 这个名字在本仓**已经是函数名**） |

### 1.6 checker / 纯度面：**时序陷阱实锤**（草案结论复核：**成立且更具体**）

- 真纯度**唯一入口** = `df_state_finalize()`（`src/compiler/dataflow.cr:259-265` → `compute_all_purity()` `src/compiler/checker.cr:4026`），调用点 = `src/compiler/main.cr:580`（IR 生成循环**之后**）。
- 头注原文（`checker.cr:3968-3977`）：**「时点：IR 生成结束之后」**+「生成期 `fi_ispure` 是**冻结的乐观默认值**」+「删掉默认值会让 lazy 全部不发射、**发射面逐字节改变**」。
- **生成期唯一消费者** = `src/compiler/ir_gen.cr:2145`（`fi_ispure(call_fi)` 的 lazy-thunk 判定）⇒ 该值**不可信但**有意冻结。
- **对本批的推论（重要）**：裁-V5 已定「子集**先禁调用**」⇒ **C1 的纯度查是空转项**，时序陷阱**被绕开而非被解决**。实施者**不得**声称「已处理纯度时序」；「允许可证纯调用」= 下一刀（C1c），其前置 = 把纯度读点移到 `df_state_finalize` 之后（或改读 state 链）。

### 1.7 诊断 / 闸门面

| 事实 | 实读 |
|---|---|
| 错误码家族：`cat = ec / 1000`，`num = ec % 1000` | `src/compiler/diag.cr:132-136` |
| 家族表 = 16 个（P/N/I/TA/TF/TB/TU/TC/TM/TK/TS/TG/B/R/E/ICE） | `src/compiler/diag.cr:86-104`（`error_cat_prefix`） |
| **17xxx 段空闲** | `src/compiler/ast.cr:324-487` 全表最大 = `EC_ICE_TY_INDET = 16004`；**无 17xxx 定义** |
| **fail-closed 默认阻断 + 豁免登记表（只减不增）** | `src/compiler/diag.cr:163-210`（`diag_gate_exempt`）+ 调用点 `src/compiler/main.cr:146-175`（**不在表内 ⇒ hard=1 ⇒ rc=1**） |
| `check` 面 rc 规则 = 「`g_diag_count > 0` ⇒ 1」 | `src/compiler/main.cr:447-453` |
| 前端解析后闸门 | `src/compiler/main.cr:134`（`parse_all()` 后 `g_diag_count > 0 ⇒ return 1`） |

**⇒ 由 1.7 直接推出（本批最易踩的坑）**：**yellow（未证）若走诊断通道 ⇒ 默认阻断 ⇒ rc=1 ⇒ 违反裁-V6**。故三态必须**分流**：**红 = 诊断（唯一硬错）/ 绿黄 = dump 通道**。

### 1.8 载体面（裁-V2/V3 的落地依据，复核）

| 事实 | 实读 |
|---|---|
| `.csr` / TagNode / `CSR1` 在 `src/` **零命中**（纯设计） | 草案已核；本计划复核 `grep -rn "csr\|TagNode" src/compiler/*.cr` 无规约面命中 |
| `.ccr` 现行 = **v9 / 8 段**（STR/SYM/NOD/ENT/REG/EDG/TYPE(7)/IFACE(8)） | `src/compiler/ccr_io.cr:135`（`CCR_VERSION = 9`）/ `:138`（`CCR_SEG_COUNT = 8`）/ `:139-140` |
| `.cir` 快照版本位 = 18 | `src/compiler/cir_cache.cr:52`（`CIR_CACHE_VER : int = 18`） |
| dump 通道的既有先例（**隐藏 flag + 纯打印 + 不改 rc/产物**） | `main.cr:240-253` 一族（`--dump-types` / `--dump-ifaces` / `--dump-tk-terms` / `--diag-gate-report`）；文本工具 = `dump.cr:8-41`（`dump_buf_*`）/ `:270`（`cir_text_dump`）/ `:351`（`df_tk_term_dump`） |
| **缓存与标注的交互（实读结论：安全）** | 缓存键 = 源路径::函数名 + `func_fingerprint`/`sig_fingerprint`（`ir_gen.cr:3685`/`:3721`，**按源字节区间**哈希）+ 编译器身份（`cir_cache.cr:456-462`）⇒ 加/去标注 ⇒ 源变 ⇒ 指纹变 ⇒ **必 miss**（无害重建）；且标注**不产 IR** ⇒ 命中与否都不影响 dump（dump 在 parse/check 期算，**与缓存状态无关** ⇒ 冷/暖 dump 恒同，**构造性**） |

### 1.9 判据网真源（**计数以实读为准**——本节全部本计划现场枚举）

| 判据 | 计数（**实读**） | 真源 |
|---|---|---|
| **腿① 冻结基线同源对拍** | **74 档**（硬断言 `CORPUS_TOTAL=74`） | `tools/baseline/parity_run.sh:31`；分层**实测** = t1 `tests/suite/*.cr` **34** + t2 **2** + t3 **15** + t4 `src/stdlib/*.cr` **19** + t5 `examples/*.cr` **4** = 74 |
| 腿② 行为探针 | **29 档**（硬断言 `PROBE_TOTAL=29`）+ `probes/warm/` **7 档**（另一层） | `tools/baseline/probes_run.sh:29` / `tests/probes/README.md` |
| 腿③ 暖态腿 | 牙齿层 7 档 + 广度层随两 runner 附带 | `tools/baseline/warm_leg.sh` / `REBUILD.md:64-96` |
| **canary 五条 = 单一真源** | ELF `95084e7b…d475`（**28822B**）· `pa_ccr 680a6f98…`（96015）· `pa_static_ccr 76f36e6a…`（96158）· `gt_ccr d92a2727…`（142765）· `gt_static_ccr a1f7b99c…`（142908） | `tools/baseline/canary_values.tsv`（末 5 行数据行；闸门 = `canary_check.sh`，fail-closed F1-F4） |
| 五 CI job | `check` / `bootstrap-tests` / `selfhost-tests` / `suite` / `full-bootstrap` | `src/ci/run.sh:61 / :67 / :98 / :199 / :204` |
| 套件面计数 | selfhost **59** · bootstrap **7** · harness **5** · run.sh 可执行挂点 **50** | 本计划现场 `ls` / `grep -c "^    python3 " src/ci/run.sh` |
| 自举链 | `corec2 == corec3` + `N06=0` + 冒烟 42 | `src/ci/run.sh:204-215`（`full-bootstrap`） |
| `selftest-types` | run.sh 注释记载 **415 例**（**本计划未跑**） | `src/ci/run.sh:115` |

### 1.10 **文档面陈旧（本批须顺带修；全部实读）**

| 面 | 陈旧处 | 实况 |
|---|---|---|
| `tools/baseline/REBUILD.md` | `:6`、`:126` 写「**72 档**」 | 真值 **74**（`parity_run.sh:31` 硬断言） |
| `tools/baseline/parity_run.sh` | `:33` 分层注释 `t1 33 + t2 2 + t3 15 + t4 19 + t5 4` | **和 = 73 ≠ `CORPUS_TOTAL` 74**（apx 批 +1 只加到总数，分层没跟上；实测 t1 = **34**） |
| `src/ci/run.sh` | `:106` 写「**73 档**语料」 | 真值 **74** |
| `tests/harness/ci_hook_allowlist.txt` | `:14-15` 头注「scope 66（selfhost 56 …）/ 挂点 45」 | 实测 **scope 71（59+7+5）/ 挂点 50**（该文件自注「计数随分支漂移，以当场重算为准」⇒ 属**已知口径**，非缺陷；本批顺带刷新） |
| `docs/maintainer/design/spec-design.md` | `:71-90` §四 示例用 `result != None` / `return None`（`None` 仍是关键字，示例**可解析**，但**不在 C1 子集内**，见裁-S9） | 须在 T6 标注「C1 子集」与示例的关系 |
| 同文件 `:106-107` | `#check(/* 用户填写前置条件 */)` 占位符形态 | 实施后须改为**可编译的真例** |

---

## 2. 候选方案（**逐案：改动面 / 风险 / 判据 / 对 canary 与五条真源的影响**）

### 方案 A —— **`#` 新 token**（**推荐主选**）

- **改动面**：`lexer.cr` 单字符分支加 `if c == 35 { … add_tok(T_HASH, …) }`（1 行级）；`ast.cr` 加 `T_HASH : int = 101`（**取空洞外的下一个自由号**，不重编号）；parser 标注链（§3.2 裁-S2）。
- **零足迹论证**：§1.2 的 182 档全扫（0 裸 `#`）⇒ **构造性**零扰动；`#` 在字符串/注释内**永不进**该分支。
- **风险**：① token 号选错（撞既有号）⇒ 判据 = 静态断言「101 未被占用 + 既有 0..100 值一字不动」；② 未来有人写裸 `#` ⇒ 从「静默丢」变「语法错」——**这是期望行为**（响亮优于静默），须在计划里**显式登记为有意的行为变更**。
- **对 canary/五真源**：**零影响**（预期 IDENTICAL）。

### 方案 B —— **复用注释起始面 + 特定形态识别**（**不推荐**）

- 形态：把 `#` 当行注释首，再在词法/预扫描里识别 `#check` / `#ensure`。
- **致命缺陷（三条，全部可证伪）**：① **本仓 `.cr` 的注释首是 `//` 与 `/* */`，不是 `#`**（`lexer.cr:381-400`）——「复用注释面」等于**新增一种注释语法**，是**比方案 A 更大**的语言面变更；② `#chekc(x)`（拼错）会被**静默吞成注释** ⇒ 直接违反铁律 #1/#4（不许静默、不许掩盖）；③ 形态识别须在词法层做**前瞻**（`#` 后有空白？`#checkxin` 前缀误配？），与 `hit.cr:200-201` 记录的**前缀误配教训**同族。
- **判据面**：可写「拼错必须报错」的负控——但方案 A 天然满足、方案 B 需额外前瞻代码。
- **结论**：**否**（保留为记录：说明为何不选）。

### 方案 C —— **复用 `@` sigil（零词法改动）**（**不推荐**）

- 形态：写 `@check(x)` / `@ensure(x)`（`T_AT` 已在 `ast.cr:76` = 70；`@hotpatch` 先例在 `parser.cr:1491-1500`）。
- **优点**：词法零改动、`compile` 面无新 token。
- **致命缺陷**：① **与既有 `@` 面语义撞车**——`@name` 在本仓 = 内建/项目访问（`@raw_int` `@inline` `@no_bounds_check` `@ffi` `@hotpatch`、`import @acme`），`parse_primary` 已把 `@IDENT` 当表达式解析（`parser.cr:460`）⇒ 签名后放 `@check(x)` 会让「注解」和「表达式」在同一位置**歧义**；② **违反 spec-design §六 定稿**（原文：`#` 与 `@` 区分，`#` 标记的东西不影响运行时语义）；③ 实施后**再改回 `#`** 要付迁移成本（用户语法一旦发布）。
- **结论**：**否**（但**记录为**「若维护者改判 sigil，本计划 §4 的 T2/T4 只需换 token 谓词，其余不动」——方案的**可替换性**是本仓偏好）。

> **三案对比一句话**：**A 是最小且最响亮的**；B 把「新 token」换成「新注释语法 + 静默吞错」，C 把「新 token」换成「与既有 sigil 撞车」。**推荐 A。**

---

## 3. 裁决门

### 3.1 六门（**维护者已按默认取裁——本计划落纸照办，不再询问**）

| 门 | 裁定 | 本计划落地点 |
|---|---|---|
| **裁-V1** | 第一刀 = **C1**（用户规约最小面 + VC 打印） | §4 任务表全体 |
| **裁-V2** | **先 dump 通道，后 `.csr`** | T4（`--dump-vcs`，stdout，零新产物）；`.csr` 转下刀 |
| **裁-V3** | **消费面 = `.ccr`**；`.cir` 只作开发期 dump | 本批 **不动** `.ccr` 段表/版本位（停条件⑤）；dump 为**过渡载体** |
| **裁-V4** | **`#` 默认零足迹** + 运行时插桩须显式开关 | §5.1 零足迹硬闸；C3（插桩）**不在本批** |
| **裁-V5** | **表达式子集先禁调用**（避开纯度时序坑） | T3 子集实现；**纯度项空转**（§1.6 推论） |
| **裁-V6** | 证不出**不阻断**编译；**`#check(常量 false)` = 硬错** | §1.7 推论：**绿黄走 dump、红走诊断**（分流表见 §5.2） |

### 3.2 本批新门（**实施中必然遇到、草案未裁**；逐条：问句 / 影响 / 推荐 / 未取裁时）

| # | 问句 | 影响 | **推荐** | 未取裁时 |
|---|---|---|---|---|
| **裁-S1** | `#` 后的 `check`/`ensure` 是**新关键字**（`T_CHECK`）还是 **`#` + 普通 IDENT**（parser 比对词素）？ | 词法关键字表（`lexer.cr:71-109`）+ **既有语料** | **`#` + IDENT**（**证据**：`parser.cr:30` 本仓**已有函数名 `check`**，`main.cr:235` 还有 CLI 子命令 `"check"`；新增关键字 = `fn check(...)` 全仓立刻变语法错） | 按推荐（否则先改 `parser.cr` 的 `fn check` 名字——**本批不做**） |
| **裁-S2** | 标注**位置与链形**：签名后/body 前、可多条、源序？ | parser + EBNF + 全语料 | **是**（照 spec-design §四；`{ ('#' IDENT '(' Expr ')') }*`；插入窗口 = `parser.cr:1440`/`:1442` 之间） | 按推荐 |
| **裁-S3** | **VC 记录的内容形态**：源码文本 / AST 索引 / 编图 / 规范化文本？ | T4 + 后续 `.csr` 刀 | **AST 节点索引 + 规范化文本（新 printer）+ 行/列 + 状态**（三样并存：索引供后续 `.csr` 引用、文本供人读、行/列供定位） | 按推荐（最少 = 仅文本；但后续刀要重做） |
| **裁-S4** | **「编图」（VC 条件编入 IR/DFG）本批做不做？** | **发射面** | **不做**（理由三条：① 编图 ⇒ 写 `g_ir_instrs` ⇒ `g_ir_func_instr_count` 变 ⇒ `.ccr` NOD/REG ⇒ **ELF 变** ⇒ 违反裁-V4「`#` 不改运行时语义」；② 现机制 = **DFNode 逐条由 `emit()` 建**（`dataflow.cr:99` `df_create_node`，`ir_gen` 生成期逐指令调用）⇒ 无「不落指令流」的旁路；③ 独立 scratch 函数须回滚 `g_ir_func_count/g_ir_instr_count` **且**生成期副作用不可回滚（`alloc_type` 行表/optrep 侧表/state 链，见 `main.cr:549-575` 见证面清单）⇒ 高风险）。**编图转 C1b**，其前置 = 先裁「注解 IR 的载体」（新 `.ccr` 段 vs 独立产物） | 按推荐（**若坚持编图 ⇒ 停**：须先裁载体，属停条件⑤） |
| **裁-S5** | **三态如何呈现**？（绿/黄/红） | 诊断闸门 / rc / 判据 | **绿 + 黄 = dump 通道（纯打印）；红 = 诊断（`error[V..]` + rc=1 + 零产物）**（理由见 §1.7：绿黄走诊断会被 fail-closed 误阻断） | 按推荐（**唯一安全解**） |
| **裁-S6** | **诊断码分配** | `ast.cr` / `diag.cr` / `docs/developer/errors.md` | **新家族 17xxx ⇒ `error[V01…]`**：`error_cat_prefix` 加 `if cat == 17 { return "V"; }`（`diag.cr:86-104` 尾部 + 一行）；首批码 = `EC_V_CHECK_FALSE = 17001`（常量假，**唯一硬错**）+ `EC_V_BAD_TAG = 17002`（未知 `#` 标签/形态错）——**须同步 `docs/developer/errors.md`**（该文件自注「改码须同步 ast.cr 注释与本文」） | 按推荐 |
| **裁-S7** | **bootstrap（Python）面同批做吗？** | 两前端接受集 / 自举链 | **同批做「最小一致面」**：`bootstrap` lexer 认 `#`+IDENT 产 token、parser 消费标注链并**忽略**（不做检查/VC）——理由：① 两前端**同判**是本仓既有口径（`test_lexer_parity.py`）；② **成本小**（lexer 单字符表 + parser 一处）；③ 否则分歧升级为「拒 vs 收」。**明确不做**：bootstrap 侧不产诊断、不产 VC（它**不是**语言参照实现） | 退路 = **显式登记分歧**（bootstrap 对 `#` 响亮报错 = fail-loud，不是静默）⇒ 可接受但须入 TODO |
| **裁-S8** | **名字域**：`#ensure` 绑 `result`；与形参重名？`#check` 有无 `result`？ | checker 域检查 | **`#check` 域 = 形参 + 文件级可见名（全局常量/函数名——本批子集无调用 ⇒ 实为形参 + 常量）；`#ensure` 域 = 形参 + `result`**；`result` 与形参**同名 ⇒ 硬错**（`EC_V_…`，避免歧义静默）；域外名 ⇒ 硬错（**不是** yellow——「名字不在域内」是形态错、可判定） | 按推荐 |
| **裁-S9** | **表达式子集精确边界**（对裁-V5 的落地细化） | T2/T3/T4 + 用例面 | **C1 子集 = {int/bool/dchar 字面量 · 形参 ident · `result`（仅 ensure）· 一元 `-` `!` · 二元 算术/比较/逻辑 · 括号}**；**禁**调用 / 字段 / 下标 / `Some`/`None` / `?` / 赋值（属后续刀）。⇒ **spec-design §四 的 `result != None` 示例不在子集内**，T6 须在文档标注（或改写示例为 `#ensure(result >= 0)` 形态） | 按推荐（若要求含 `Some/None` ⇒ 需额外裁 `?` 类型判定面） |
| **裁-S10** | **dump 通道名与格式** | T4 + 判据 | **`--dump-vcs`**（隐藏 flag，照 `main.cr:240-253` 家族）；输出 = `dump_buf_*` 逐行、**源序**、`[vcs] ` 前缀；**只打印、不改 rc/产物**；**不落文件**（零新产物 ⇒ 无 `.gitignore`/格式包袱） | 按推荐 |
| **裁-S11** | **新语料入仓位置** | 两腿计数 / CI 挂点 | **新目录 `tests/spec/`**（`#` 语料）+ **新套件 `tests/selfhost/test_spec_grammar.py`**；**不进** `tests/probes/`（否则 `PROBE_TOTAL 29→30`）**也不进** `tests/suite/`（否则 `CORPUS_TOTAL 74→75`）——理由：两腿是**既有行为回归网**，其**计数不变**本身就是「旧面零扰动」的最强证据 | 按推荐（若坚持进 `tests/suite/` ⇒ 须同批改 `parity_run.sh:31` 计数 + 分层注释 + `REBUILD.md`，并把 74→75 记入台账） |
| **裁-S12** | **零足迹强度**：只要求「无 `#` 的程序不变」，还是**更强**的「同程序 ± 注解，产物逐字节同」？ | 判据强度 / 实施约束 | **强式**（推荐）：`corec build` 同一程序 ① 无注解 ② 加 `#check` ③ 加 `#ensure` ⇒ **ELF + `.ccr` 逐字节同**。理由：① 构造性可判（无需新工具，sha256 即可）；② 它把裁-V4「零运行时语义」**变成机器判据**而不是口号；③ 它**当场堵死**裁-S4 的「编图」近路（编图必然违反） | 退路 = 只做弱式（无 `#` 的不变），强式转下一刀 |

### 3.2.1 取裁记录（**维护者 2026-09-17 已裁；本节为最终裁定，覆盖上表「未取裁时」列**）

| 门 | **裁定** | 理由要点 / 落实点 |
|---|---|---|
| **裁-S4** | **出列（C1 不编图）** | 三条依据（编图 ⇒ 写 `g_ir_instrs` ⇒ `.ccr` NOD/REG 变 ⇒ ELF 变 · DFNode 逐条由 `emit()` 建**无旁路** · scratch 方案**生成期副作用不可回滚**）判**决定性**；**另加与前门的一致性论证**：裁-V4（零足迹）+ 裁-S12（强式）与编图**直接冲突**。将来编图 = **独立批 + 独立判据**，前置 = 先解决「生成期副作用不可回滚」。⇒ T4 **不含**编图；编图归 T7 的 **C1b** |
| **裁-S7** | **同批做「最小一致」（bounded）** | 理由：「一方拒收合法语法」是**最坏那类**两编译器分歧（不是意见不同，是一边直接打断）。**边界钉死**：bootstrap 侧**只需「接受并跳过」（零语义）**——能词法化、不报错、**不影响产物**；**不要求**实现 VC/三态；完整 bootstrap VC 面**登记后续**。**判据**：① 一份最小带 `#` 语料在**两侧都 rc=0 且产物逐字节同**；② 既有语料两侧行为不变 |
| **裁-S12** | **取强式** | 同程序 ± 注解 ⇒ ELF + `.ccr` **逐字节同**；它把「`#` 没碰任何下游」从**声明**变成**判据** |
| 裁-S1 / S2 / S3 / S5 / S6 / S8 / S9 / S10 / S11 | **按推荐** | 逐条见上表「推荐」列。附带：S9 的 `result != None` 示例**不在 C1 子集内** ⇒ T6 标注/改写；S11 的「两腿计数不变」= 旧面零扰动的最强证据（维护者确认） |

**三条提醒（维护者；已逐条落进任务卡正文）**：
1. **T0 的 RED 复现是「预测」** ⇒ **不得当已有证据用**，须实测后替换（T0 卡）。
2. §1.10 文档计数陈旧面 ⇒ **T6 顺带修，但改计数前先实测**（不得再写一个过期数）。
3. **实施者不得声称「已处理纯度时序陷阱」**——裁-V5 是**绕开**不是解决（T3 卡内明令保留）。

---

## 4. 任务表（T0..T7；**每卡含：前置 / 改动面 / 判据 / 停条件**）

> **纪律（照 P6 事故护栏）**：含「先裁」的任务把护栏写进**任务卡正文**；**一构建一编译串行**（同工作区禁并发构建）；`nice -n 19`；cwd = 仓库根；比较前 `clean-cache`；**路径限定 jj 提交**；自测用例**只增不减**。

### **T0 — 前置（冻结基线 + 起点判据 + 六门落纸）**
- **前置**：无（本卡即前置）。
- **动作**：① `jj workspace add` 独立工作区（本批 = `core-veri-ws` @ `feature/spec-grammar`，**已建**）；② **冻结基线重建**（`bash tools/baseline/rebuild.sh /tmp/spec-baseline`，配方 = `REBUILD.md`；**须重跑自证**：三 sha = 白名单 + 确定性 ×2 + 冒烟 42）；③ **起点判据表**（腿①74 冷态 rc+日志落 `/tmp/spec-t0/parity_pre`；腿②29 + warm 7；`canary_check.sh` 全绿）；④ **六门落纸**（§3.1）+ **十二门取裁落纸**（§3.2.1，**已完成**）；⑤ **锚点重取**（§1 全部 `file:line` 在开工 revision 上重核一遍——**行号漂移即更新本节**）；⑥ **RED 复现**：**已实测（2026-09-17），结论见 §10.2——实测结果与本节原「预测」**不符且更严重**（预测 = 报 P0xx 语法错；实测 = **无解析错**，标注表达式被误当函数体 ⇒ `error[TF01]`（**build 面豁免码**）⇒ `build` **rc=0 + 产物**，运行返回 0（应返回 1）= **静默误编译**）。预测文本已由 §10.2 取代，**保留此注否证痕**。
- **判据**：基线三 sha 命中 + 起点两腿落盘 + 六门/新门入纸 + RED 实测记录。
- **停条件**：基线 sha 不符 ⇒ 停（`REBUILD.md` 换代纪律 1：**不得改白名单对齐**）。

### **T1 — 词法面（`#` token）+ 零足迹构造性判据**
- **前置**：T0（尤其裁-S7）。
- **改动面**：`src/compiler/ast.cr`（`T_HASH : int = 101`，注释写明「空洞外首个自由号；勿重编号」）；`src/compiler/lexer.cr`（单字符分支加 `#`；**不动**注释分支）；**bootstrap 侧（裁-S7 = 同批「最小一致」，bounded）**：`bootstrap/corec/syntax/tokens.py` + `bootstrap/corec/frontend/lexer.py` + `bootstrap/corec/frontend/parser.py:240 parse_function_decl` —— **只做「接受并跳过」（零语义）**：能词法化、不报错、**不影响产物**；**不要求** VC/三态（完整 bootstrap VC 面**登记后续**）。**不得**动 `lexer.py:287` 的未知字符报错（那是最后一道响亮防线，`#` 之外仍需它）。
- **判据**（**四条，缺一不可**）：
  1. **静态**：`T_HASH == 101` ∧ 既有 token 常量 0..100 值**一字不动**（脚本比对改动前后的常量表快照）；`T_HASH` 不与任何既有 token 号相撞。
  2. **构造性零扰动**：全仓 `.cr` 裸 `#` 扫描断言（T0 的脚本入仓为 `tests/spec/scan_bare_hash.py` 或并入 T5 套件）——**182 档 0 命中**；此断言使「加 token 改了既有语料」变成**不可能**而非「没观察到」。
  3. **非 `.cr` 的 `#` 语义不变**：HIT 表 / `.so` 索引 / kernel 行格式四处（§1.2）行为逐字节不变（取样 + 对拍）。
  4. **canary 五条 IDENTICAL**（`canary_check.sh`）+ **腿①74 / 腿②29 零差异**（对拍 runner 两态 diff 空）。
- **停条件**：canary 变 ⇒ **停**（发射面泄漏，不是「容忍区」）。

### **T2 — 语法面（标注链 + EBNF + 负例）**
- **前置**：T1（裁-S1/S2）。
- **改动面**：`src/compiler/parser.cr` 在 `:1440`/`:1442` 之间加**标注链**（`#` IDENT `(` `parse_expr()` `)`，可多条）；标注记录落**侧表**（建议 = `globals.cr` 新增 `g_spec_*` 平行数组 + `dyn_arr.cr` 访问器，**照 `FuncInfo` 侧表化后的既有形态**）；**不挤** `EXPR_FN` 的 `a/b/c`（`:1451` 语义不变）；`grammar/core.ebnf:12-13` 加标注产生式（`FunctionDecl = [ 'pub' ] 'fn' … '->' Type { Annotation } ( FunctionBody | '=' Expr ';' )` + `Annotation = '#' IDENT '(' Expr ')'`）；**`_import.cr` + `build_selfhost_native.py` 清单同步**（若新增 `.cr` 文件——**建议新文件 `src/compiler/spec.cr`**，只放纯 Core 代码，**自身不含 `#`**，保 bootstrap 面安全）。
- **负例（≥8，全部须「响亮」）**：`#` 后非 IDENT；`#check` 缺 `(`；`)` 未闭合；标注出现在**签名前/body 后**；未知标签（`#foo(…)`）；`#` 在表达式位置；`#check(,)`（表达式语法错）；`#ensure` 用在**无返回**函数（若定为硬错）。**每条 = rc=1 + 定位诊断 + 零产物**。
- **判据**：正例 ≥6（单条/多条/多函数/带泛型/`=` 形 body/`{}` 形 body）；负例 ≥8；**零足迹**：T1 的四条全绿。
  **T2 三条硬验收（维护者 2026-09-17 批准时指定，不可省）**：
  1. **两侧都接受 rc=0**（bootstrap 侧 ✅ 已绿）+ **corec 侧 ±注解 ELF/`.ccr` 逐字节同**（裁-S12 强式）——本批判据口径（见 §11 的口径修正）；
  2. **撞名形态必堵**（§11.1 实测的 T1 漏洞）：`fn check(x: bool) -> bool` 存在时，`#check(1 < 0)` 所在函数必须 **rc=1 + 零产物**——**不得**依赖「注解名恰好未定义」才响亮；
  3. **负例 ≥8 必含**：签名外位置的 `#` · **重名冲突** · `#ensure` 在 `#check` 前 · 空 `#check()` · 非布尔表达式 · 注解链重复（另加 T2 卡原有的位置/形态错例）。
- **停条件**：负例出现**静默通过**（rc=0）⇒ 停（本批最要消灭的形态）。

### **T3 — 检查面（三查 + 时序纪律 + 诊断码）**
- **前置**：T2（裁-S5/S6/S8/S9）。
- **改动面**：`src/compiler/spec.cr` 新增三查：① **bool 型**（走判定引擎三态——`-1` 未判 ⇒ **不得当 0/1**，照 R2 P5 三态纪律；不可译 ⇒ 硬错）；② **名字域**（裁-S8）；③ **纯度**——**本批子集无调用 ⇒ 空转**（**须在代码注释里写明「时序陷阱未解决、仅因无调用而空转」**，防后来者误以为已处理）；诊断码 `EC_V_*`（`ast.cr` 17xxx）+ `error_cat_prefix` 分支（`diag.cr:86-104`）+ `docs/developer/errors.md` 同步；**常量折叠**（绿/红判定：仅 literal 与字面量运算，**不做代数化简**）。
- **判据**：三查正控/负控各 ≥6；**裁决性判据 = 绿黄绝不出现在诊断通道**（`--dump-vcs` 有、stderr 无）；红 = `error[V01]` + rc=1 + **零产物**；**全语料 report-only 扫面**（新硬错在 74+29 档命中必须为 **0**——若命中非空 ⇒ 停）。
- **停条件**：新硬错全语料命中非空 ⇒ 停上报。

### **T4 — VC 记录 + dump 通道**
- **前置**：T3（裁-S3/S4/S10）。
- **改动面**：VC 记录结构（函数 / 种类 / AST 节点索引 / 行 / 列 / 状态 / 规范化文本）；规范化 printer（新函数，**只服务 dump**，不参与判定）；`main.cr` 注册 `--dump-vcs` + 在**全部分支**（`check` / `ccr` / `cir` / `build` / `run`）的既有 dump 家族位置打印（照 `main.cr:240-253` 纪律：**只打印、不改 rc/产物**）；`dump.cr` 加 `vcs_text_dump()`（复用 `dump_buf_*`）。
- **判据**：① **源序确定**（同一源两次编译 dump **逐字节同**）；② **冷/暖同**（`clean-cache` 前后 + 缓存命中路径——**构造性成立**，§1.8）；③ **零产物影响**（开/关 `--dump-vcs` ⇒ ELF/`.ccr` sha 同）；④ **三态齐全**（green/yellow 各 ≥1 例，red 走诊断）；⑤ **强式零足迹（裁-S12 已裁：取强式）**：同程序 无注解/`#check`/`#ensure` 三态 ELF+`.ccr` **逐字节同**（sha256 全等；**这是本批的判据脊梁**——把「`#` 没碰任何下游」从声明变成判据）。
- **停条件**：dump 开/关导致产物变 ⇒ 停（dump 必须零副作用）。

### **T5 — 判据三件套（语料 + 套件 + 挂点）**
- **前置**：T4（裁-S11）。
- **改动面**：`tests/spec/*.cr` 语料（正/负/边界，**目录独立于两腿**）+ `tests/selfhost/test_spec_grammar.py`（照 `tests/selfhost/test_params_limit.py` 的 harness 体例：`_compile` / `case_run` / `case_reject`）；**挂点**：`src/ci/run.sh` 的 `selfhost-tests` job 加一行（`python3 tests/selfhost/test_spec_grammar.py`）+ 实测时长入注释；`tests/harness/ci_hook_allowlist.txt` **不加条目**（挂上即不属未挂项）——但**须跑** `tests/harness/test_ci_hook_coverage.py` 自证覆盖率判据仍绿（**三件套 = `run.sh` 挂点 + 白名单 + 覆盖率判据**）。
- **判据**：新套件全绿；覆盖率判据绿（非空转下限 `MIN_SCOPE=50/MIN_HOOKED=30` 仍满足：实测 71/50）；**两腿计数不变**（74/29 硬断言仍过 = 旧面零扰动的机械证据）。
- **裁-S7 的判据（bounded，两条）**：① 一份最小带 `#` 语料在 **corec 与 bootstrap 两侧都 rc=0，且产物逐字节同**（`clean-cache` + 同源同参）；② **既有语料两侧行为不变**（bootstrap 侧 = `build_selfhost_native.py` 的 `error[`/未定义符号守卫仍 0；corec 侧 = 两腿）。**bootstrap 侧不做 VC/三态**——判据只认「接受并跳过」。
- **停条件**：不得为「让新语料进来」而放宽两腿的 `CORPUS_TOTAL`/`PROBE_TOTAL`（放宽即销毁「计数不变」这条证据）。

### **T6 — 收官（回归 + 台账 + 文档）**
- **前置**：T1-T5 全绿。
- **动作**：五 CI job 全跑（`check`/`bootstrap-tests`/`selfhost-tests`/`suite`/`full-bootstrap`）；自举链 `corec2==corec3` + `N06=0` + 冒烟 42；`selftest-types` + 全套件枚举（59 → 60）；**文档**：`spec-design.md`（示例标 C1 子集 + §十七 里程碑打勾）、`docs/developer/syntax.md`（§二 词法/§四 标注位置加 `#check`/`#ensure`）、`docs/developer/errors.md`（V 家族）、`grammar/core.ebnf`（已在 T2）、**§1.10 的陈旧面逐条修**（`REBUILD.md` 72→74、`parity_run.sh:33` 分层注释、`run.sh:106` 73→74、`ci_hook_allowlist.txt` 头注刷新）——**改计数前先实测**，不得再写一个过期数（维护者提醒 2）；`TODO.md` 新条目（当日号 + 登记未修项）；**统一台账**（本批各任务判据汇总）。
- **判据**：全绿 + 文档 diff 逐条可核。
- **停条件**：任一 job 红 ⇒ 停下定位（**不得**以「本批是文档批」为由跳过）。

### **T7 — 下一刀指向（**不实施，仅登记**）**
- C1b「编图 / 注解 IR 载体」（前置 = 裁「新 `.ccr` 段 vs 独立产物」= 段表变更裁决）。
- C1c「允许可证纯调用」（前置 = **纯度时序收口**：读点移到 `df_state_finalize` 后或改读 state 链——§1.6）。
- C2「自动标签（纯度/region/provenance 事实入载体）」、C3「运行时插桩（显式开关）」、C4「spec fn / 量化 / 翻译桥（须先裁 CIC 内核）」。

---

## 5. 判据设计（本批的脊梁）

### 5.1 零足迹 = **硬闸**（旧面零扰动；两条腿 + 五条真源）

| 判据 | 命令（**口径**） | 期望 | 真源 |
|---|---|---|---|
| **canary ELF** | `canary_check.sh`（内建逐条 `clean-cache` + `HOME` 归一化） | `95084e7b…d475`（28822B）**IDENTICAL** | `tools/baseline/canary_values.tsv` |
| **`.ccr` 四条** | 同上 | `680a6f98…` / `76f36e6a…` / `d92a2727…` / `a1f7b99c…` | 同上（两口径差恒 143B 的根因见 `:43-47`） |
| **腿① 冻结基线同源对拍** | `parity_run.sh <frozen> /tmp/a` × `parity_run.sh ./build/corec /tmp/b` ⇒ `diff -rq a/logs b/logs` | **空**（74 档 rc + 日志） | `REBUILD.md:52-56` |
| **腿② 行为探针** | `probes_run.sh` 两态 ⇒ `diff -rq` | **空**（29 档；**rc=1 多为预期负例**，判据 = 零差异，**不是**全 0） | `tests/probes/README.md` |
| 腿③ 暖态 | `warm_run.sh`（牙齿 7 档）+ 广度层随两 runner | 一致 + **暖态生效档数 ≥1**（0 = 空洞警报） | `REBUILD.md:64-96` |
| **构造性面** | 全仓 `.cr` 裸 `#` 扫描（入仓断言） | **0 命中**（182 档） | 本计划 §1.2（须在 T1 固化为**仓内脚本 + 套件断言**） |
| **强式零足迹**（裁-S12 若取推荐） | 同程序 ± 注解 ⇒ `sha256` ELF / `.ccr` | **逐字节同 ×3 形态** | 本批新增 |

### 5.2 `#` 面自身（**正控 / 负控 / 三态分流**）

| 类 | 用例（≥ 数） | 期望 |
|---|---|---|
| 正控 | `#check` 常量真（绿）· `#check` 未证（黄）· `#ensure(result…)`（黄）· 多条同函数（**源序**）· 多函数（**声明序**）· `=` 形 body · 泛型函数 · 无返回 `-> unit` 的 `#check` | rc=0 + **零诊断** + dump 行数/内容精确匹配 |
| 负控（语法） | `#` 后非 IDENT / 缺 `(` / 未闭合 / 位置错（签名前·body 后）/ 未知标签 / 空表达式 | rc=1 + `error[V02]` 定位 + **零产物** |
| 负控（域/型） | 域外名 / `result` 出现在 `#check` / `result` 与形参重名 / 非 bool 表达式（`#check(1)`） | rc=1 + `error[V…]` |
| **硬错（红）** | `#check(1 < 0)` · `#check(false)` · `#check(1 == 2)` | rc=1 + `error[V01]` + **零产物** + **不得**同时产出 dump 的「绿」行 |
| **不阻断（黄）** | `#check(x > 0)`（形参）· `#ensure(result >= 0)` | **rc=0** + **stdout 无 `error[`** + **stderr 无诊断** + dump 有 yellow 行 |
| **三态分流**（本节最重要） | 上述三类的**通道断言** | **绿/黄 ⇒ 只在 `--dump-vcs`**；**红 ⇒ 只在诊断**；**两者不混** |

### 5.3 探针入仓形态 + 挂点三件套
- **语料**：`tests/spec/*.cr`（**不进**两腿；`tests/probes/README.md` 的「非编译单元」口径**不适用于本目录**——本目录**是**编译单元，由新套件驱动）。
- **套件**：`tests/selfhost/test_spec_grammar.py`（**只增不减**；每例一个 `case_*`，含 `_compile`/`case_run`/`case_reject` + **无产物断言** + 无 core dump 护栏）。
- **挂点三件套**：① `src/ci/run.sh` 的 `selfhost-tests` 加 `python3 tests/selfhost/test_spec_grammar.py`（**行首可执行、非注释**——`test_ci_hook_coverage.py` 的判据③只认这种形态）；② `ci_hook_allowlist.txt` **不加条目**（挂上=不属未挂项）；③ **跑 `test_ci_hook_coverage.py` 自证**（覆盖率判据 + 突变自证）。
- **突变控制（≥3，须入套件或报告）**：M1 摘掉 `#` 词法分支 ⇒ 正控全红；M2 摘掉「常量假 ⇒ 硬错」⇒ 红例变绿（**必须红**——这是本批唯一硬错）；M3 让 yellow 走诊断 ⇒ 「不阻断」例变 rc=1（**必须红**）；M4（若裁-S7 同批）摘掉 bootstrap 的 `#` 分支 ⇒ 两句柄分歧判据红。

---

## 6. Global Constraints（**全批适用**）

- **canary 硬闸**：`95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`（**28822B**）——变 = **越界 ⇒ 停下上报**（不是容忍区）。
- **`.ccr` 五条真源**（**只此一处**）= `tools/baseline/canary_values.tsv` 末 5 行数据行（ELF 1 + `.ccr` 4）；闸门 = `tools/baseline/canary_check.sh`（fail-closed F1-F4；**只锁冷态**，不得「补全」成冷暖双锁）；**手工复跑须 `HOME` 归一化**（照 `REBUILD.md:133-148`；2026-09-17 起归一化**仍保留作双保险**）。
- **腿① = 74 档**（`CORPUS_TOTAL` 硬断言；实测分层 34/2/15/19/4）· **腿② = 29 档**（`PROBE_TOTAL` 硬断言）+ warm 7 档 · **两腿计数本批不得改**（改了 = 销毁「旧面零扰动」的机械证据）。
- **五 CI job**：`check` / `bootstrap-tests` / `selfhost-tests` / `suite` / `full-bootstrap`（`src/ci/run.sh:61/67/98/199/204`）。
- **自举链**：`corec2 == corec3` + `N06 = 0` + **冒烟 42**（`run.sh:204-215`）。
- **枚举**：`selftest-types`（`run.sh:115` 记载 415 例）+ 全套件枚举 `tests/{selfhost,bootstrap,harness}/*.py`（**不含注释里的自称**）+ 清单三面同核（`build_selfhost_native.py` 清单 / `_import.cr` / 新增文件三处同步）。
- **三态纪律**（R2 P5 起）：判定 `-1`（未判）**不得当 0/1**；未知 ⇒ 响亮（本批硬错 `EC_V_*` 或 yellow，**不得静默**）。
- **先裁后码**：§3.2 未取裁的门**不得实施**（含「先裁」的任务把护栏写进任务卡正文）。
- **工具/纪律**：`nice -n 19`（铁律 6）· **一构建一编译串行**（同工作区禁并发构建）· cwd = 仓库根 · 比较前 `clean-cache` · **只 jj、禁 git**（铁律 2）· 路径限定提交 · **文件永不还原**（铁律 3）。
- **不得回退既有收纳**：TS01-04/TK02/R002/TM03/ICE04/TA02 硬门 · P4/P5/P6 全批 · 容量批 / fail-closed 批 / 判据载体化批 / home-repro 批的既有裁决——**本批一律不动**。
- **`.ccr` 段表 / `CCR_VERSION=9` / `CIR_CACHE_VER=18` 本批不动**（停条件⑤）。

## 7. 停条件（**任一命中 ⇒ 停下上报，不得自行取裁**）

1. **canary 变**（五条任一）⇒ 注解泄进发射面。
2. **两腿出现非章程 diff** ⇒ 判定面行为变更（新检查若改既有语料 rc ⇒ 先 report-only + 裁决）。
3. **新硬错（`EC_V_*`）全语料命中非空** ⇒ 停（不得靠豁免表 `diag_gate_exempt` 掩盖——该表「只减不增、加条须维护者批」）。
4. **被迫动 `.ccr` 段表/版本位或 `.cir` 快照布局** ⇒ 停（单独裁决 + 失效面登记）。
5. **被迫引入外部依赖**（SMT/CIC/新工具链）⇒ 停（越出 C1）。
6. **纯度时序**：若实施中需要读生成期 `fi_ispure` 而无法在不改发射面的前提下收口 ⇒ 停（裁-V5 已把该风险出列，**不得**顺手「解决」）。
7. **bootstrap 分歧升级**：若裁-S7 取「不动 bootstrap」而自举链上出现 `#` 形态 ⇒ 停。
8. **工作副本不干净或他方在途** ⇒ 停（照 P6 事故护栏）。

## 8. 未决项（**不猜**；须实证 / 须裁）

- **U-1**：spec-design §八/§9.3 称 `variant`/`forall`「EBNF 已有」——**实读零命中** ⇒ 文档勘误（T6 顺带）。
- **U-2**：`.csr` schema（`docs/ir-schema/corespecir-schema.md`）称「真源 = `ccr_io.cr`」——**实读零命中** ⇒ 勘误 + 转 C1b。
- **U-3**：`docs/project-book.md` §3.2 仍按**已退役**的独立 `.corespec` 叙述 ⇒ 陈旧文档（T6 顺带）。
- **U-4**：`fi_ispure` / provenance / region 事实**是否入载体**——实读 = `.ccr` 零命中 ⇒ C2/§十三 门控通道**须先建载体通道**。
- **U-5**：`.cir` 是否有**对外**序列化（实读 = DOT + 私有缓存快照两形态）——若维护者知道第三形态 ⇒ 更正。
- **U-6**：CIC 内核选型（Rocq vs Lean 4）**挂起** ⇒ 本批不依赖；C4 依赖。
- **U-7**：`where` 值约束三档（`TODO.md` 的「规约语法并入 .cr」节）与 `#check`/`#ensure` 的关系（同族语法还是两套）⇒ 须裁（影响 T2 产生式）。
- **U-8**：`#pure` / `#tag` / `#invariant` 等其余标签的**先后**（spec-design §六 列出，C1 不做）⇒ 转 C2。
- **U-9**：**`#` 是否允许出现在 `impl` 块内的方法**（`grammar/core.ebnf:102` 的 `ImplDecl` 内嵌 `FunctionDecl`）⇒ 须裁（影响 T2 的接线点数量）。

## 9. 自检记录

- **根因 vs 止血**：本批**不做**「先接个假绿勾」的兑现——C1 **明确不判定真值**（唯一判定 = 常量折叠），未证如实标 yellow 且**不阻断**，与 spec-design §十二 + 仓内三态纪律一致。
- **诚实边界**：**本计划零构建、零源码改动**；行号 = `dbadb8d6` 实读；**§1.2 的全仓扫描是本计划实跑的唯一实验**（只读、可复现，扫描口径已写入判据设计）；**§4 T0 的 RED 复现为「预测」**，标注待实测。
- **与既有裁决的一致性**：ADR-0001（规约并入 `.cr`）· spec-design §六（`#` 与 `@` 分工）/§十二（unproven 不拦）· 裁-V1..V6 · `TODO #2026-09-11-9` 判据口径（结构性断言 + 语义零变化 + 自举稳定）· 三态纪律 · P4 T5「零足迹」先例（裁-V4）· P6 事故护栏（含「先裁」入卡）。
- **占位符扫描**：无 TBD；§3.2 十二门逐条「推荐 + 未取裁时」；§8 九条未决项全部指向具体文件/行或明确「须裁」。
- **最大风险（本计划判定）**：**① 绿/黄误走诊断通道**（会与 fail-closed 闸门耦合出「未证即 rc=1」，直接违反裁-V6）——缓解 = §5.2 的**通道断言** + 突变 M3；**② 实施者顺手「编图」**（会把 `.ccr`/ELF 改坏）——缓解 = 裁-S4 + 裁-S12 强式判据；**③ bootstrap 面被遗忘**（分歧升级）——缓解 = 裁-S7 + 突变 M4。

---

## 10. T0 实施记录（**2026-09-17 实施轮**；工作区 `core-veri-ws` @ `feature/spec-grammar`）

> **口径**：本节全部数字 = **当场实测**（非引用文档）；命令与产物路径逐条给出，可复跑。

### 10.1 冻结基线（**本批 pre-side**）与构建确定性

| 项 | 实测值 |
|---|---|
| 构建命令 | `nice -n 19 python3 build_selfhost_native.py`（cwd = 工作区根） |
| 耗时 | **25.6s**（real；user 12.0s；4 核机） |
| **确定性 ×2** | 两次构建逐字节同：`corec` = `899e3090ad8d6f84787f5cbb245af997269585e045fb9b4d11f054cf194a5036` · `corearch` = `072f2c7ccc243cc2a23fb5a0ad8dd97046bbd38c4f1a0aaafd137b660a1617be` |
| 冒烟 | `./build/corec run 'fn main()->int{return 42;}'` ⇒ **rc=42** |
| pre-side 存档 | `/tmp/spec-t0/pre/{corec,corearch}` + `SHA256.txt`（= **本批 leg-① 的「pre-批」二进制**） |
| 起点 revision | `develop = dbadb8d649ba`（**未动** ⇒ §1 全部 `file:line` 锚点**有效**，无须重取） |

**口径声明**：本批 leg-① 的 pre-side = **上表自建二进制**（本批起点树、确定性 ×2 已证）。
`tools/baseline/rebuild.sh` 的 pinned `97f4394f`（P6 终态）复现属 **E-13 配方自检**，与本批判定面无关
（该 pin 之后源已多次变更 ⇒ 其产物**不代表**本批起点）——单独跑，结论见 §10.5。

### 10.2 RED 实测（**取代 §4 T0 卡的预测；预测被否证**）

**探针** `/tmp/spec-t0/red_annot.cr`：

```core
fn f() -> int #check(1 < 0) { return 1; }
fn main() -> int { return f(); }
```

| 命令 | **实测结果** |
|---|---|
| `corec check /tmp/spec-t0/red_annot.cr` | **rc=1** + `error[TF01]: Function return type mismatch --> 1:1`（**误归位点**：报在 fn 声明行） |
| `corec build … --static` | **rc=0**（**打印了 `error[TF01]` 却照常产出**）⇒ ELF `013b43df89fa253d2ce74f6e05b840cdad62fcb99066387e70137428f89a4659`（28822B）+ `.ccr` 均落盘 |
| 运行该 ELF | **rc=0**（**应为 1**）⇒ **静默误编译**（零提示） |
| bootstrap 侧（同源，`Lexer` 直调） | `SyntaxError: <unknown>:1:15: Unexpected character: '#'` ⇒ **响亮拒收** |

**根因（实测修正版，三环）**：
1. `#` 被词法器**静默丢弃**（`src/compiler/lexer.cr:590-592`）⇒ cur token 变 `check`（IDENT）；
2. `parse_body`（`src/compiler/parser.cr:1442-1449`）因 cur token ≠ `{` 走 **`=` 分支**：`advance_tok()` 吃掉 `check`、`parse_expr()` 把标注的括号表达式 `(1 < 0)` **当成函数体**、再 `advance_tok()` 吃掉 `{`；
3. 于是 `f` 的体 = `1 < 0`（bool）⇒ 与 `-> int` 冲突 ⇒ `TF01`；而 **`EC_TF_RETURN` 在 build 面豁免表内**（`src/compiler/diag.cr:176`）⇒ fail-closed `hard=0` ⇒ **产物照出**。

**⇒ 结论（比原预测严重一级）**：今天带标注的源不是「不支持」，是**静默误编译成 rc=0 的错产物**——
正是本仓最要消灭的形态。**T2 的负控必须覆盖此条**（`#` 成 token 后，该路径必变语法错或正确解析，二者皆可判）。

### 10.3 起点判据（canary + 腿①；腿②/③ 见 §10.4）

| 判据 | 命令 | **实测** |
|---|---|---|
| **canary 五条** | `nice -n 19 bash tools/baseline/canary_check.sh` | **PASS 5/5**：ELF `95084e7b…d475`（28822B）· `pa_ccr 680a6f98…`（96015）· `pa_static_ccr 76f36e6a…`（96158）· `gt_ccr d92a2727…`（142765）· `gt_static_ccr a1f7b99c…`（142908） |
| **腿① 74 档** | `bash tools/baseline/parity_run.sh /tmp/spec-t0/pre/corec /tmp/spec-t0/parity_pre` | **PARITY DONE（74 档）· rc 分布 35×0 / 39×1**（基线日志 `/tmp/spec-t0/parity_pre/logs/`） |

**39×1 的构成（本批实测，取代 `REBUILD.md:126` 的「38」旧账）**：
空 fixture ×2（`tests/suite/test_control_flow.cr` / `test_generics.cr`，实测日志 = `error: cannot read`）·
P21 嵌套 fn ×3（`at_test_mini{,.4,.6}.cr`；**旧账记 2**）· examples 解析错 ×2 · 库单元单独 check ×25
（t1 `apx_conversion_test` 1 + t2 `_import.cr` 1 + t3 13 + t4 10）· TF01 并发族 ×5 · TF07 ×1（`ptr_ref_first`）·
B04 ×2（`ptr_arith` **= canary 载体本人** + `apx_conversion_test`）= **39**。
诊断码直方图（全部 rc=1 档）：`N06 ×1889 · N01 ×1426 · TA01 ×202 · N11 ×71 · TF01 ×18 · TB01 ×10 · TF07 ×2 · P21 ×2 · B04 ×2`
（**N 族占绝对多数 = 库单元单独 check 的 concat 语境缺失，属既有语义**）。
⇒ **T6 修 `REBUILD.md:126` 时须用本节的实测构成**（不得沿用 38 的旧账）。

### 10.4 腿②（探针 29 档）与腿③（暖态）

| 判据 | 命令 | **实测** |
|---|---|---|
| **腿② 29 档** | `bash tools/baseline/probes_run.sh /tmp/spec-t0/pre/corec /tmp/spec-t0/probes_pre` | **rc 分布 17×0 / 12×1**（rc=1 多为预期负例；判据 = 两态零差异） |
| 腿② 附带的暖态广度层 | 同上（runner 默认） | **29 档 · 暖态生效（≥1 真命中）档数 = 15 · FAIL=0** |
| **腿③ 牙齿层** | `bash tools/baseline/warm_run.sh /tmp/spec-t0/pre/corec /tmp/spec-t0/warm_pre` | **7 档 · 暖态生效档数 = 7 · FAIL=0** |

**⚠ 未竟项（登记，不静默；**已补对照实验，2026-09-17 T1 轮**）**：**腿③ 广度层（`parity_run.sh` 附带的 74 档暖态二跑）未跑完**——
卡在 `corec ccr src/compiler/main.cr` 的**暖态第二跑**（`-o o2.ccr`）：首观测 `State: D (disk sleep)` ·
`rchar = 760,556,173`（760MB）· `.core/cache/cir/` = **1.4GB / 1011 条目** · 单次调用 elapsed 9:52 且 >8min 零进展。
**对照实验（维护者要求的先决条件，已按①无并发②清缓存③记墙钟执行）**：
- **① 无并发**：开跑前 `pgrep -a corec` / `pgrep -a corearch` **为空**（仅本实验进程）；
- **② 清缓存后开跑**（`.core/cache/cir` 0 → 冷跑重建）；
- **③ 墙钟**：**WALL = 901s，rc = 124（`timeout 900` 硬超时截断）**，日志停在 **35/74**——同一 `-o o2.ccr` 调用 elapsed **>13 min**、`State: D`、`rchar ≈ 44MB`、RSS ≈ 219MB、`%CPU 1–3%`。
**⇒ 结论（实测，可证伪）**：**不是并发单因**（对照已排除）；对照 `REBUILD.md:78-79` 的「parity 广度层 **+125s**」**差 ≥7× 且未跑完**
⇒ 属**既有性能病理**（**本批零源码改动**，且**已在干净窗口复现**）。

**机制（维护者读码定位 + 本代理复核 file:line）**：`src/compiler/cir_cache.cr` 的**每条函数快照携带单元级表**——`:226` 全图边数进尺寸、`:228-234` **整个单元级字符串常量表**进每条快照、`:310-313` 注释原文「they're few compared to nodes」+ 写 **`g_df_edge_count`（全图）**条边 ⇒ 缓存总量 = **O(函数数 × 单元级表)** = **二次膨胀**。

**因果对照实验（本代理复跑，维护者设计要求：无并发 / 清缓存 / 冷暖双记）**：

| 语料 | 冷跑墙钟 | 跑后 cache | 暖跑墙钟 |
|---|---|---|---|
| `tests/suite/ptr_arith.cr`（小） | **1s** | 15 条 / 352K | **0s** |
| `src/compiler/main.cr`（约千函数单元） | **231s** | **1011 条 / 1.4G** | **>254s 未完成 ⇒ 看门狗判据命中杀**（CPU 1.9% · `State: D` · rchar 169MB） |

⇒ **测到的关联（**不是已证因果**）**：小缓存档暖跑 0s、大缓存档 >254s 未完成——但**两档语料不同**（未控制「同文件 × 不同缓存规模」）⇒ 不得据此断言「缓存体积 ⇒ 暖跑墙钟」。

**⚠ 环境未控（须与上表同读）**：测量时段机器实测（2026-09-17 09:07，同量级）——交换 **12127MB / 已用 5985MB** · `loadavg **16.47/15.92/16.72**`（**4 核**）· `vmstat b=16 · si=184 · **wa=40%**` · 常驻大户 = 4 个多日前起的 `bun` 进程（RSS ≈ 2.4GB）⇒ **系统级 I/O 饱和 + swap 抖动**；「无并发 + 清缓存」**只对本代理进程成立，系统级不成立** ⇒ 墙钟只能读作「**在既有机器负载下**，暖态二跑 ≥7× 于 `REBUILD.md:78-79` 的 +125s」。

**⚠ 与机制的关系（**不得混为一谈**；维护者更正 + 本对照证伪）**：「快照二次膨胀」= **已定位机制**；「卡点」= **现象**。对照**证伪**了「卡点由读体积解释」——卡点进程 `rchar` 仅 **44MB / 169MB**，缓存却 1.4GB ⇒ **卡点直接原因未知**，两条**不是同一条因果链的已证结论**（完全归因 = `plan-cachebloat` 只读侦查；**本条不重跑**）。

⇒ 立 **`TODO #2026-09-17-6`**（该条目 = 上述机制 + 实测四条 + 本表 + 一行推测方向；
**不做根因定位**——维护者指示）。**处理**：杀进程 + 清缓存；该层**明确按「未跑绿」登记**
（`REBUILD.md` 应补「广度层不覆盖大文件」口径；**不得**把它写成「已跑绿」）。**腿③ 牙齿层（7 档）与腿② 广度层（29 档）不受影响，均实测绿。**

### 10.5 E-13 冻结基线配方自检（pinned `97f4394f`）

`nice -n 19 bash tools/baseline/rebuild.sh /tmp/spec-t0/pinned-baseline` ⇒ **rc=0**，三 sha 与白名单**逐条命中**
（`corec ae01de75…` · `corearch 228f82e9…` · `corelsp 90eb19c6…`）+ **冒烟 rc=42** + `error[` 行数 = 3（守卫通过）。
⇒ **E-13 配方完好**（与 `REBUILD.md` 现行代一致）。**注**：该产物 = P6 终态源，**不代表本批起点**
（pin 之后源已多次变更）⇒ 本批 leg-① 的 pre-side 一律用 §10.1 的自建二进制。

### 10.6 T0 判据汇总（**一处看全**）

| # | 判据 | 状态 |
|---|---|---|
| 1 | 工作区 + bookmark | ✅ `core-veri-ws` @ `feature/spec-grammar` |
| 2 | 构建确定性 ×2 + 冒烟 42 | ✅ §10.1 |
| 3 | 六门 + 十二门落纸 | ✅ §3.1 / §3.2.1（提交 `05667d03`） |
| 4 | 锚点重取（revision 未动） | ✅ §10.1 |
| 5 | RED 实测 | ✅ §10.2（**预测被否证**，实测更严重） |
| 6 | canary 五条 | ✅ 5/5 |
| 7 | 腿① 74 档 | ✅ 35×0 / 39×1（基线落盘） |
| 8 | 腿② 29 档 | ✅ 17×0 / 12×1（+ 暖态生效 15 · FAIL=0） |
| 9 | 腿③ 牙齿层 7 档 | ✅ 暖态生效 7 · FAIL=0 |
| 10 | 腿③ 广度层（74 档暖态） | ⚠ **未竟（对照实验后定性：既有性能病理，非并发单因）** —— `TODO #2026-09-17-6`（§10.4 附三条实测事实；**不写成绿**） |
| 11 | E-13 pinned 配方自检 | ✅ 三 sha + 冒烟 42 |

---

## 11. T1 实施记录（词法面 `#` token；2026-09-17）

**改动面**（提交 `1b5a8799` + `a4df9c75`）：`src/compiler/ast.cr`（`T_HASH = 101`）· `src/compiler/lexer.cr`（单字符分支）· `bootstrap/corec/{syntax/tokens.py, frontend/lexer.py, frontend/parser.py}`（裁-S7 bounded：接受并跳过）。

| 判据 | **实测** |
|---|---|
| ① 常量静态断言 | ✅ `T_` 常量 89 → **90**；**新增仅 `T_HASH: 101`**；既有 0..100 **零改动**（`jj file show -r <pre>` 逐条比对）；101 **不与既有值相撞** |
| ② 全仓裸 `#` 扫描 | ✅ **182 档 · 0 命中**（构造性零足迹；与 T0 同口径同脚本） |
| ③ 非 `.cr` 的 `#` 面不变 | ✅ `test_hit_table.py` **24/24**（HIT 表 `#` 注释面）· `test_so_index_repro.py` **8/8**（`.so` 索引 `#` 行面） |
| ④ 两前端一致性 | ⚠ **部分**（下详）：bootstrap 侧 ✅ · corec 侧 = **响亮拒绝**（T1 单独作用；「两侧 rc=0」须待 T2） |
| 附：canary 五条 | ✅ **5/5 IDENTICAL**（`95084e7b…d475` / `680a6f98…` / `76f36e6a…` / `d92a2727…` / `a1f7b99c…`） |
| 附：腿① 74 档 | ✅ pre `35×0/39×1` ≡ post `35×0/39×1`，`diff -rq logs` = **零差异**（`WARM_LEG=0` 跑冷面） |
| 附：腿② 29 档 | ✅ `diff -rq` = **零差异** |
| 附：冒烟 | ✅ rc=42（新二进制 `corec = 8ffb3511…`） |

**判据④ 的实测与口径修正（**须维护者知悉**）**：
- **bootstrap 侧 ✅**：`#check(1 < 0)` 语料走完整前端（lex→parse→resolve→desugar→check→ir_gen→asm）**rc=0**，且 asm 与**无注解版逐字节同**（`sha256 ff86d802…`）；修复前 = `SyntaxError: Unexpected character: '#'`（T0 实测）。
- **corec 侧（T1 单独作用）= 响亮拒绝**：`error[N06]: Undefined function 'check'` @ **2:11**（**正确定位到标注**）· rc=1 · **零产物**。⇒ 相对 T0 的**静默误编译**（rc=0 + 运行返回错值）是**严格改进**；但「**两侧都 rc=0**」在 T1 单独作用下**不可能成立**——corec 的 `#` 消费者 = **T2 的 parser 标注链**。
- **口径修正（结构性，且不可回避；维护者 2026-09-17 已准并定为**本批判据**）**：「两侧**产物逐字节同**」**不可构造**——两前端的**后端不同**（bootstrap = Python `X86_64StackAsmGen` + `as`/`ld`；corec = 自研 ELF 发射器），无共同产物面 ⇒ 本条按**可构造的最强形**实现：**(a) 两侧都接受（rc=0）** + **(b) 各自零足迹**（bootstrap：asm ±注解逐字节同，**已绿**；corec：±注解 ELF/`.ccr` 逐字节同 = 裁-S12 强式，**T2 后验**）。

**顺带实核（已立 TODO）**：bootstrap `KEYWORDS` 残留 `requires`/`ensures`/`result`（self-hosted 无）⇒ **`TODO #2026-09-17-8`**。

**T1 的另一实测收获（登记为 TODO）**：TF01 的**豁免洞**（误报 × 豁免 = 静默错产物）——**触发器**已被 T1 消灭，**洞本身未动** ⇒ **`TODO #2026-09-17-7`**。

### 11.1 ⚠ **T1 结论的重要限定：本节的「响亮拒绝」是**条件性**的**（2026-09-17 实测；维护者验收项②）

上文「corec 侧 = 响亮拒绝」**只在注解名恰好未定义时成立**。实测（`/tmp/spec-t1/collide.cr`）：

```core
fn check(x: bool) -> bool { return x; }      // ← 注解名撞上一个**真实函数**
fn f() -> int #check(1 < 0) { return 1; }
fn main() -> int { return f(); }
```

| 命令 | 实测 |
|---|---|
| `corec check` | rc=1 + `error[TF01]`（**误归** 2:1） |
| `corec build --static` | **rc=0 + 产物落盘**（28922B→实测 28822B）· 打印了 `error[TF01]` 却照常发射 ⇒ 运行 **rc=0（应 1）** |

⇒ **静默误编译在本形态下**依旧存在**（T1 未消灭它，只消灭了「名字不存在」那一支）**。根因同 T0：`parse_body` 的 `=` 分支把 `#check(1<0)` 解析成**对 `check` 的调用**当函数体，而 TF01 在 build 面豁免（`TODO #2026-09-17-7`）。
**⇒ T2 的硬验收（不可省）**：`#` 被 parser 消费后，**注解再也进不了 body** ⇒ 本形态必须 **rc=1 + 零产物**（不再依赖「名字不存在」）。

---

## 12. T2 实施记录（语法面：标注链 + 常量红规则；2026-09-17）

**改动面（7 文件）**：`src/compiler/ast.cr`（`EC_V_*` 17xxx 家族：V01 常量假 / V02 未知标签 / V03 形态错）· `src/compiler/diag.cr`（`error_cat_prefix` 加 `cat == 17 ⇒ "V"`）· `src/compiler/globals.cr`（**规约标注侧表** `g_spec_{fn,kind,expr,line,col,count,cap}` + 会话复位）· `src/compiler/dyn_arr.cr`（`grow_spec_side` / `spec_add` / 5 个受护读访问器）· `src/compiler/parser.cr`（`parse_spec_annotations` + `parse_body` 调用点 + **顶层兜底对 `#` 转响亮**）· `src/compiler/checker.cr`（`spec_fold_val` 常量折叠 + `spec_check_all`，挂 `check_all()` 尾）· `grammar/core.ebnf`（`FunctionDecl`/`FlowDecl` 加 `{ Annotation }` + `Annotation` 产生式）· `docs/developer/errors.md`（V0xx 节）。

**判据实测（13/13 + 2 手工）**：

| 类 | 用例 | 实测 |
|---|---|---|
| 正控 ×4 | 无注解 / `#check` / 多条（`#check`×2 + `#ensure`）/ 注解链重复 | **rc=0 + 产物**（重复 = **合法**，见下「待裁」） |
| 负控 ×9 | `#` 后非 IDENT · 未知标签 · 缺 `(` · 未闭合 `)` · 空 `#check()` · **签名前位置** · **body 后位置** · **常量假** · **撞名形态** | 全部 **rc=1 + `error[V01/V02/V03]` + 零产物** |
| 手工 ×2 | body 内 `#`（同语句行 / 独立行） | rc=1（parse 层 `error:` 文本）+ 零产物 |

**三条硬验收**：
1. **两侧都接受**：corec ✅（正控 rc=0）· bootstrap ✅（`pos_check.cr` 全链 rc=0 且 asm `ff86d802…` 与无注解版**逐字节同**）。
   **±注解产物面（裁-S12，实测后**第二处口径修正**——须维护者准）**：
   - **ELF：逐字节同** ✅（`m_plain.cr` vs `m_annot.cr`（注解插在同一行）⇒ 同一 sha `cae8d50d…`；**即使行数不同**（多行注解形态）ELF 亦同）。
   - **`.ccr`：7/8 段逐字节同**；**唯一差异 = STR 段**，且 **Δ = 注解独有词素的驻留量**。实测两例：`#check(1 > 0)` ⇒ **+9 B**（= 4B 长度前缀 + `check`(5)）；`#check(true)` ⇒ **+8 B**（= 4 + `true`(4)）。**机制**：`lexer.cr:318` `add_tok_str` 对**每个** IDENT/关键字词素调 `str_intern`（**既有行为，非本批引入**）⇒ 只出现在注解里的标识符/关键字会进 STR。
   ⇒ **可构造的最强形**（本批判据）= **(a) ELF 逐字节同** + **(b) `.ccr` 除 STR 外逐段同 + STR Δ 恰为可算值**；**逐字节全同不可达**（除非注解里的词素在程序别处已驻留）。**判据不缩水**：差异必须**恰好**等于该量，多一个字节即红。
2. **撞名形态必堵** ✅：`fn check(x: bool) -> bool` 存在时 `#check(1 < 0)` ⇒ **rc=1 + `error[V01]` + 零产物**（T1 的漏洞已闭合；不再依赖「名字不存在」）。
3. **负例 ≥8** ✅：实测 9 条（含维护者点名的 6 类：签名外位置 ✓ / 重名冲突 ✓（撞名形态）/ `#ensure` 先于 `#check`（= 反序链，见「待裁」）/ 空 `#check()` ✓ / 非布尔（T3）/ 注解链重复 ✓）。

**顺带修掉的雷（T2 首轮实测挖出）**：`parse_declaration` 的**顶层兜底 = `advance_tok()` 静默吞一个 token、不报错** ⇒ `#check(1>0) fn f()…`（签名前）与 `…} #check(1>0)`（body 后）**rc=0 + 产物照出**（首轮 2 例 FAIL）。已在该点对 `#` 转**响亮**（`EC_V_BAD_TAG` + 定位）。**其余 token 的静默吞仍在** ⇒ 候选 TODO（见 `TODO #2026-09-17-9`）。

**回归闸门**：canary **5/5 PASS** · 腿② 29 档 **零差异** · J 判据 **4/4** · 腿① 74 档 rc 分布不变（35×0/39×1）且**两档日志差异经机械归因 = 纯行号平移**（`_import.cr` 4 行 · `ccr_io.cr` 156 行，**全为 `--> 行:列` 与源码回显形态；剥行号后逐字节同**——根因 = 本批给编译器源加了 193 行，而对拍语料含编译器自身源）⇒ **判定面行为零变更**，属预期内差异（入台账）。

**未做（转 T3/T4）**：bool 型检查 · 名字域（`result` 绑定、`#check` 无 `result`）· `#ensure` 的常量红 · VC 记录与 `--dump-vcs`。

**待裁（T2 暴露的两处语义问题）**：① **注解链重复**（同一标签重复）本批判**合法**（设计稿未禁止；判「可判定且必错」不成立）——维护者若要求禁止，需另立语义（当前按合法实现）；② **`#check` 与 `#ensure` 的顺序**本批**不约束**（两者语义独立，先 `#ensure` 后 `#check` 亦可）。

