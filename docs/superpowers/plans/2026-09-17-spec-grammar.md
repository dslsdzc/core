# 批 6：验证内核管线正式接入（正式规约语法 `#check` / `#ensure`）

> 实施记录：[implementation/2026-09-17-spec-grammar.md](../implementation/2026-09-17-spec-grammar.md)
> 状态：计划（已实施；实施记录见上述文件）。开始实施前置 = 第 3.1 节六门（已由维护者按默认取裁）+ 第 3.2 节本批新门（逐条给推荐，未取裁前不实施）。
> 定位（受众/状态/出处）：受众 = 批次实施代理 + 维护者；状态 = 计划（已实施；实施记录见上述文件）；出处 = 本文（切片边界/任务卡/检查）+ `docs/maintainer/design/spec-design.md`（规约设计权威）+ `docs/superpowers/plans/2026-09-16-verification-slice.md`（切片草案，本批 = 其 C1 的正式接入）。
> 诚实边界（规划轮陈述，须先读）：本计划只读侦查、零源码改动、零构建（未运行 `build/corec` / 未运行任何套件）。行号 = develop `dbadb8d6` 工作树实读值（下一任务开始实施时须重取，本仓「纸面成果只对当轮 revision 有效」约定）。凡推断/预测一律标「预测」；凡实读一律给 `file:line`。代价估计为相对量级（小/中/大），非工时。
> 体例：照本仓 SSDD（现状根因 / 候选方案 / 裁决门 / 验收设计 / Global Constraints / 停条件 / 任务卡 / 自检）。
> 拆分说明：第 10–17 节（T0–T6 实施记录、批终态与方法论）已移至上述实施记录；正文中「第 10.x / 11.x / 12–17 节」的引用均指该文件，章节号保持不变。

目标：让 Core 正式获得规约语法。用户写下 `#check(expr)` / `#ensure(expr)` 后，前端完成词法识别、语法成链、检查成形、生成 VC 记录，并经 dump 通道打印。本批不判定真值，唯一例外是常量折叠出的「常量假」，这种情况报硬错。本批不接求解器、不接 CIC 内核、不做 spec fn、量化或翻译桥，不落 `.csr`。

架构（第一项的实际形态，与草案 Architecture 的唯一实质差异 = 「编图」出列，见裁-S4）：

```
.cr 源码（#check/#ensure 标注）
  -> lexer：`#` 新 token（T_HASH = 101；紧邻 IDENT，不做关键字）
  -> parser：函数签名与 body 之间的标注链 -> 表达式复用 parse_expr，节点落 g_ast（不被 body 引用）
  -> parser/checker：标注记录落侧表（函数 × 序）--不挤 EXPR_FN 的 a/b/c 槽
  -> checker：三查（bool 型 / 名字域 / 纯度--本批子集无调用 => 纯度项空转，见裁-V5 推论）
  -> VC 记录 + 状态（green 常量真 / yellow 未证 / red 常量假）
  -> 输出通道（裁-V2：dump 先行）：`corec … --dump-vcs`（stdout；零新产物）
  -> 消费者：人/外部工具按行读；`.csr` 转下一批
```

关键边界（三条，全部由已裁门推出）：
1. 零影响：不含 `#` 的程序，产物逐字节不变（canary 五条 IDENTICAL + 检查项174 + 检查项229）。
2. 不阻断：未证（yellow）只进 dump，不进诊断通道，否则 `main.cr:140-175` 的 fail-closed 检查（默认阻断）会把它变成 rc=1，直接违反裁-V6。
3. 唯一硬错：`#check(常量假)`，可判定且必然错误，会新增诊断码，rc=1，零产物。

---

## 1. 现状根因 / 起点实核（逐条实读；行号 = develop `dbadb8d6`）

### 1.1 `#` 词法面 = 零（草案结论复核：成立）

| 事实 | 实读证据 |
|---|---|
| 注释只有 `//` 与 `/* */`，无 `#` 注释 | `src/compiler/lexer.cr:381-400`（两条注释分支；字符码 47/47 与 47/42） |
| 全 lexer 无 `#`（字符码 35）任何分支 | `grep -n "'#'\|T_HASH\|HASH\|annotation" src/compiler/lexer.cr` = 0 命中（599 行全文） |
| 未知字符 = 不报错地跳过（关键，草案未记） | `src/compiler/lexer.cr:590-592`：`// Unknown`，因此 `_pos = _pos + 1; _pos = _skip_ws(...); continue;`，不 `add_error`、不产 token |
| 关键字表 = 34 个 if 链（`None/Some` 亦在其中） | `src/compiler/lexer.cr:71-109`；`T_NONE/T_SOME` = `ast.cr:87-88`，由 `lexer.cr:105-106` 产出 |
| token 常量空间现状：最大 100，且有空洞 | `src/compiler/ast.cr:5-100`：`T_EXTERN : int = 100`（末位）；空洞 = 6 / 77-86（宽度后缀退役残留）/ 91（`T_FLOAT_TYPE` 已删）。`ast.cr:84-86` 明写「勿重编号，编号空间稳定」 |
| token kind 与 AST kind 共用同一整数空间（不同上下文） | `T_IDENT=1` vs `EXPR_INT=1`（`ast.cr:6` vs `:157`）等，因此新 token 号只须不与既有 token 号撞，与 `EXPR_*` 无关 |

因此根因一句话：`#` 今天在词法层不存在，不是「注释」，是「被不报错地丢弃的垃圾字符」。

### 1.2 零影响硬性检查的构造性证据（本批最关键的新事实，可证伪）

全仓 `.cr` 静态扫描（本计划实际运行，只读）：剥掉 `//` / `/* */` 注释、`"…"` 字符串（含转义）、`'…'` 字符字面量后，182 个 `.cr` 文件中裸 `#` = 0 个（扫描范围 = 全仓除 `.git`/`build`）。

因此在词法层加 `#` token 不可能改变任何既有 `.cr` 语料的 token 流（`#` 只出现在注释与字符串里，两者都被既有分支完整消费）。这是「canary 五条 + 检查项174 + 检查项229 必须 IDENTICAL」的构造性依据，不是经验观察。

同扫描的否证面（须一并记住）：`#` 在非 `.cr` 文件格式里是行注释首，`src/arch/hit/hit.cr:264/:382`（HIT 表）、`src/compiler/module.cr:245`（`.so` 索引）、`src/kernel/kernel_main.cr:105` + `src/kernel/test_term_io.cr:82`（kernel 行格式）、`src/arch/hit/lower_to_core.cr:340`（注释叙述）。这四处都是「读文件字节后按 35 判列」，不经 Core 词法器，因此与 `#` token 零交互（须在 T1 检查里固定：这四面的行为不变）。

### 1.3 两编译器分歧（草案未记；本批必须处置，见裁-S7）

| 前端 | 对未知字符 `#` 的行为 | 实读 |
|---|---|---|
| self-hosted `src/compiler/lexer.cr` | 不报错地跳过 | `:590-592` |
| Python bootstrap `bootstrap/corec/frontend/lexer.py` | 响亮报错 `Unexpected character: '#'`（`SyntaxError`） | `bootstrap/corec/frontend/lexer.py:287` |

因此今天同一份带裸 `#` 的源：`corec` 不报错地丢字符继续运行，bootstrap 直接拒。加 `#` token 后 self-hosted 侧改成合法 token；bootstrap 侧若不动，则「bootstrap 拒 / corec 收」的分歧从「不报错地 vs 响亮」升级为「拒 vs 收」，分歧性质变了（从 fail-loud 的一侧失守，变成两前端接受集不同）。
影响面实核：`build_selfhost_native.py` 的 concat 清单（`:35 common_files` / `:103 backend_support_files` / `:311 corec_files` / `:405 corelsp_files`）只含 `src/` 下的全部文件，不含 `tests/` 下的全部文件，因此只要 `#` 标注不进 `src/` 下的全部文件，bootstrap 在本批不会被喂到 `#`。既有对照先例 = `tests/selfhost/test_lexer_parity.py`（两前端对 `_`/宽度后缀同判是本仓既有约定）。

### 1.4 EBNF 面 = 零（复核：成立；且 EBNF 是文档产物、无消费者的解析器）

- `grammar/*.ebnf` 全文 `#` 0 命中（`grep -n "#" grammar/*.ebnf` = 空）。
- `FunctionDecl`（`grammar/core.ebnf:12-13`）= `[ 'pub' ] 'fn' IDENT [ GenericParams ] '(' [ ParamList ] ')' '->' Type ( FunctionBody | '=' Expr ';' )`，因此无标注槽。
- EBNF 无机械消费者（grep 全仓：无工具读它），因此但它被判定引用（`src/ci/run.sh:45`、`src/compiler/parser.cr:912`、`tests/selfhost/test_nested_fn.py:5` 用它论证「嵌套 fn 不属语言面」），因此改语言面必须同步，否则判定引用变成假前提。

### 1.5 parser 面 = 零；插入点已固定

| 事实 | 实读 |
|---|---|
| `parse_body` = 形参、`)`、`->` Type、body | `src/compiler/parser.cr:1366-1471` |
| 标注链的插入窗口 = 返回类型解析之后、body 之前（即 `:1440` 与 `:1442` 之间） | `:1436-1440`（`if check(T_ARROW) { advance_tok(); rt = parse_type(); rtv = unpack_type(rt); }`）到 `:1442-1449`（`if check(T_LBRACE) { body = parse_block(); } else { advance_tok(); body = parse_expr(); advance_tok(); }`） |
| `EXPR_FN` 的槽语义（新标注不得挤占） | `:1451` `alloc_node(EXPR_FN, fn_ni, pf, pc, rtv + hotpatch_ver*256, rt, body, fn_line, fn_col)` = `a=名 ni, b=首形参, c=形参数, int_val=返回型+hotpatch, type_val=返回类型节点, data=body` |
| 既有 `@` 标注先例（形态可借，sigil 不同） | `:1491-1500` `@hotpatch(ver=N)`：声明前用 `parse_expr()` 解析 + `:1473-1490` `parse_ffi_annotation()`（`@ffi("lang")`），因此 「`@` = 声明前 / `#` = 签名后」两套位置不重叠（spec-design 六定稿同此） |
| `check(k)` 是 token 谓词助手（非规约面） | `:30`（这条事实是本批裁-S1 的证据：`check` 这个名字在本仓已经是函数名） |

### 1.6 checker / 纯度面：时序陷阱实锤（草案结论复核：成立且更具体）

- 真纯度唯一入口 = `df_state_finalize()`（`src/compiler/dataflow.cr:259-265` 改为 `compute_all_purity()` `src/compiler/checker.cr:4026`），调用点 = `src/compiler/main.cr:580`（IR 生成循环之后）。
- 头注原文（`checker.cr:3968-3977`）：「时点：IR 生成结束之后」+「生成期 `fi_ispure` 是冻结的乐观默认值」+「删掉默认值会让 lazy 全部不发射、发射面逐字节改变」。
- 生成期唯一消费者 = `src/compiler/ir_gen.cr:2145`（`fi_ispure(call_fi)` 的 lazy-thunk 判定），因此该值不可信但有意冻结。
- 对本批的推论（重要）：裁-V5 已定「子集先禁调用」，因此 C1 的纯度查是空转项，时序陷阱被回避而非被解决。实施者不得声称「已处理纯度时序」；「允许可证纯调用」= 下一批（C1c），其前置 = 把纯度读点移到 `df_state_finalize` 之后（或改读 state 链）。

### 1.7 诊断 / 检查面

| 事实 | 实读 |
|---|---|
| 错误码家族：`cat = ec / 1000`，`num = ec % 1000` | `src/compiler/diag.cr:132-136` |
| 家族表 = 16 个（P/N/I/TA/TF/TB/TU/TC/TM/TK/TS/TG/B/R/E/ICE） | `src/compiler/diag.cr:86-104`（`error_cat_prefix`） |
| 17xxx 段空闲 | `src/compiler/ast.cr:324-487` 全表最大 = `EC_ICE_TY_INDET = 16004`；无 17xxx 定义 |
| fail-closed 默认阻断 + 豁免登记表（只减不增） | `src/compiler/diag.cr:163-210`（`diag_gate_exempt`）+ 调用点 `src/compiler/main.cr:146-175`（不在表内，因此 hard=1，因此 rc=1） |
| `check` 面 rc 规则 = 「`g_diag_count > 0`，因此 1」 | `src/compiler/main.cr:447-453` |
| 前端解析后检查 | `src/compiler/main.cr:134`（`parse_all()` 后 `g_diag_count > 0 则 return 1`） |

因此由 1.7 直接推出（本批最易遇到的问题）：yellow（未证）若走诊断通道，默认会被阻断，得到 rc=1，违反裁-V6。故三态必须分流：失败 = 诊断（唯一硬错）/ 通过黄 = dump 通道。

### 1.8 实现方式面（裁-V2/V3 的实施依据，复核）

| 事实 | 实读 |
|---|---|
| `.csr` / TagNode / `CSR1` 在 `src/` 零命中（纯设计） | 草案已核；本计划复核 `grep -rn "csr\|TagNode" src/compiler/*.cr` 无规约面命中 |
| `.ccr` 现行 = v9 / 8 段（STR/SYM/NOD/ENT/REG/EDG/TYPE(7)/IFACE(8)） | `src/compiler/ccr_io.cr:135`（`CCR_VERSION = 9`）/ `:138`（`CCR_SEG_COUNT = 8`）/ `:139-140` |
| `.cir` 快照版本位 = 18 | `src/compiler/cir_cache.cr:52`（`CIR_CACHE_VER : int = 18`） |
| dump 通道的既有先例（隐藏 flag + 纯打印 + 不改 rc/产物） | `main.cr:240-253` 一族（`--dump-types` / `--dump-ifaces` / `--dump-tk-terms` / `--diag-gate-report`）；文本工具 = `dump.cr:8-41`（`dump_buf_*`）/ `:270`（`cir_text_dump`）/ `:351`（`df_tk_term_dump`） |
| 缓存与标注的交互（实读结论：安全） | 缓存键 = 源路径::函数名 + `func_fingerprint`/`sig_fingerprint`（`ir_gen.cr:3685`/`:3721`，按源字节区间哈希）+ 编译器身份（`cir_cache.cr:456-462`），因此加/去标注，因此源变，因此指纹变，因此必 miss（无害重建）；且标注不产 IR，因此命中与否都不影响 dump（dump 在 parse/check 期算，与缓存状态无关，因此空缓存/有缓存 dump 恒同，构造性） |

### 1.9 检查集合出处（计数以实读为准，本节全部本计划现场枚举）

| 检查 | 计数（实读） | 出处 |
|---|---|---|
| 检查项1 固定基线同源对比 | 74 档（硬断言 `CORPUS_TOTAL=74`） | `tools/baseline/parity_run.sh:31`；分层实测 = t1 `tests/suite/*.cr` 34 + t2 2 + t3 15 + t4 `src/stdlib/*.cr` 19 + t5 `examples/*.cr` 4 = 74 |
| 检查项2 行为探针 | 29 档（硬断言 `PROBE_TOTAL=29`）+ `probes/warm/` 7 档（另一层） | `tools/baseline/probes_run.sh:29` / `tests/probes/README.md` |
| 检查项3 有缓存状态检查 | 有效性层 7 档 + 广度层随两 runner 附带 | `tools/baseline/warm_leg.sh` / `REBUILD.md:64-96` |
| canary 五条 = 单一依据 | ELF `95084e7b…d475`（28822B）· `pa_ccr 680a6f98…`（96015）· `pa_static_ccr 76f36e6a…`（96158）· `gt_ccr d92a2727…`（142765）· `gt_static_ccr a1f7b99c…`（142908） | `tools/baseline/canary_values.tsv`（末 5 行数据行；检查 = `canary_check.sh`，fail-closed F1-F4） |
| 五 CI job | `check` / `bootstrap-tests` / `selfhost-tests` / `suite` / `full-bootstrap` | `src/ci/run.sh:61 / :67 / :98 / :199 / :204` |
| 套件面计数 | selfhost 59 · bootstrap 7 · harness 5 · run.sh 可执行接入点 50 | 本计划现场 `ls` / `grep -c "^    python3 " src/ci/run.sh` |
| 自举链 | `corec2 == corec3` + `N06=0` + 快速验证 42 | `src/ci/run.sh:204-215`（`full-bootstrap`） |
| `selftest-types` | run.sh 注释记载 415 例（本计划未运行） | `src/ci/run.sh:115` |

### 1.10 文档面陈旧（本批须顺带修；全部实读）

| 面 | 陈旧处 | 实况 |
|---|---|---|
| `tools/baseline/REBUILD.md` | `:6`、`:126` 写「72 档」 | 真值 74（`parity_run.sh:31` 硬断言） |
| `tools/baseline/parity_run.sh` | `:33` 分层注释 `t1 33 + t2 2 + t3 15 + t4 19 + t5 4` | 和 = 73 不等于 `CORPUS_TOTAL` 74（apx 批 +1 只加到总数，分层没跟上；实测 t1 = 34） |
| `src/ci/run.sh` | `:106` 写「73 档语料」 | 真值 74 |
| `tests/harness/ci_hook_allowlist.txt` | `:14-15` 头注「scope 66（selfhost 56 …）/ 接入点 45」 | 实测 scope 71（59+7+5）/ 接入点 50（该文件自注「计数随分支变化，以当场重算为准」，则属已知约定，非缺陷；本批顺带刷新） |
| `docs/maintainer/design/spec-design.md` | `:71-90` 四示例用 `result != None` / `return None`（`None` 仍是关键字，示例可解析，但不在 C1 子集内，见裁-S9） | 须在 T6 标注「C1 子集」与示例的关系 |
| 同文件 `:106-107` | `#check(/* 用户填写前置条件 */)` 占位符形态 | 实施后须改为可编译的真例 |

---

## 2. 候选方案（逐案：改动面 / 风险 / 检查 / 对 canary 与五条出处的影响）

### 方案 A，`#` 新 token（推荐主选）

- 改动面：`lexer.cr` 单字符分支加 `if c == 35 { … add_tok(T_HASH, …) }`（1 行级）；`ast.cr` 加 `T_HASH : int = 101`（取空洞外的下一个自由号，不重编号）；parser 标注链（第 3.2 节裁-S2）。
- 零影响论证：第 1.2 节的 182 档全扫（0 裸 `#`），因此构造性零扰动；`#` 在字符串/注释内永不进该分支。
- 风险：1 token 号选错（撞既有号），因此检查 = 静态断言「101 未被占用 + 既有 0..100 值一字不动」；2 未来有人写裸 `#`，因此从「不报错地丢」变「语法错」，这是期望行为（响亮优于不报错地），须在计划里显式登记为有意的行为变更。
- 对 canary/五出处：零影响（预期 IDENTICAL）。

### 方案 B，复用注释起始面 + 特定形态识别（不推荐）

- 形态：把 `#` 当行注释首，再在词法/预扫描里识别 `#check` / `#ensure`。
- 致命缺陷（三条，全部可证伪）：1 本仓 `.cr` 的注释首是 `//` 与 `/* */`，不是 `#`（`lexer.cr:381-400`），「复用注释面」等于新增一种注释语法，是比方案 A 更大的语言面变更；2 `#chekc(x)`（拼错）会被不报错地吞成注释，因此直接违反硬性规则 #1/#4（不许不报错地、不许掩盖）；3 形态识别须在词法层做前瞻（`#` 后有空白？`#checkxin` 前缀误配？），与 `hit.cr:200-201` 记录的前缀误配教训同族。
- 检查范围：可写「拼错必须报错」的负控，但方案 A 天然满足、方案 B 需额外前瞻代码。
- 结论：否（保留为记录：说明为何不选）。

### 方案 C，复用 `@` sigil（零词法改动）（不推荐）

- 形态：写 `@check(x)` / `@ensure(x)`（`T_AT` 已在 `ast.cr:76` = 70；`@hotpatch` 先例在 `parser.cr:1491-1500`）。
- 优点：词法零改动、`compile` 面无新 token。
- 致命缺陷：1 与既有 `@` 面语义撞车，`@name` 在本仓 = 内建/项目访问（`@raw_int` `@inline` `@no_bounds_check` `@ffi` `@hotpatch`、`import @acme`），`parse_primary` 已把 `@IDENT` 当表达式解析（`parser.cr:460`），则签名后放 `@check(x)` 会让「注解」和「表达式」在同一位置歧义；2 违反 spec-design 六定稿（原文：`#` 与 `@` 区分，`#` 标记的东西不影响运行时语义）；3 实施后再改回 `#` 要付迁移成本（用户语法一旦发布）。
- 结论：否（但记录为「若维护者改判 sigil，本计划第 4 节的 T2/T4 只需换 token 谓词，其余不动」，方案的可替换性是本仓偏好）。

> 三案对比一句话：A 是最小且最响亮的；B 把「新 token」换成「新注释语法 + 不报错地吞错」，C 把「新 token」换成「与既有 sigil 撞车」。推荐 A。

---

## 3. 裁决门

### 3.1 六门（维护者已按默认取裁，本计划写进文档照办，不再询问）

| 门 | 裁定 | 本计划实施点 |
|---|---|---|
| 裁-V1 | 第一项 = C1（用户规约最小面 + VC 打印） | 第 4 节任务表全体 |
| 裁-V2 | 先 dump 通道，后 `.csr` | T4（`--dump-vcs`，stdout，零新产物）；`.csr` 转下批 |
| 裁-V3 | 消费面 = `.ccr`；`.cir` 只作开发期 dump | 本批不动 `.ccr` 段表/版本位（停条件5）；dump 为过渡实现方式 |
| 裁-V4 | `#` 默认零影响 + 运行时插模拟须显式开关 | 第 5.1 节零影响硬性检查；C3（插模拟）不在本批 |
| 裁-V5 | 表达式子集先禁调用（避开纯度时序问题） | T3 子集实现；纯度项空转（第 1.6 节推论） |
| 裁-V6 | 证不出不阻断编译；`#check(常量 false)` = 硬错 | 第 1.7 节推论：通过黄走 dump、失败走诊断（分流表见第 5.2 节） |

### 3.2 本批新门（实施中必然遇到、草案未裁；逐条：问句 / 影响 / 推荐 / 未取裁时）

| # | 问句 | 影响 | 推荐 | 未取裁时 |
|---|---|---|---|---|
| 裁-S1 | `#` 后的 `check`/`ensure` 是新关键字（`T_CHECK`）还是 `#` + 普通 IDENT（parser 比对词素）？| 词法关键字表（`lexer.cr:71-109`）+ 既有语料 | `#` + IDENT（证据：`parser.cr:30` 本仓已有函数名 `check`，`main.cr:235` 还有 CLI 子命令 `"check"`；新增关键字 = `fn check(...)` 全仓立刻变语法错） | 按推荐（否则先改 `parser.cr` 的 `fn check` 名字，本批不做） |
| 裁-S2 | 标注位置与链形：签名后/body 前、可多条、源序？| parser + EBNF + 全语料 | 是（照 spec-design 四；`{ ('#' IDENT '(' Expr ')') }*`；插入窗口 = `parser.cr:1440`/`:1442` 之间） | 按推荐 |
| 裁-S3 | VC 记录的内容形态：源码文本 / AST 索引 / 编图 / 规范化文本？| T4 + 后续 `.csr` 批 | AST 节点索引 + 规范化文本（新 printer）+ 行/列 + 状态（三样并存：索引供后续 `.csr` 引用、文本供人读、行/列供定位） | 按推荐（最少 = 仅文本；但后续批要重做） |
| 裁-S4 | 「编图」（VC 条件编入 IR/DFG）本批做不做？| 发射面 | 不做（理由三条：1 编图，因此写 `g_ir_instrs`，因此 `g_ir_func_instr_count` 变，因此 `.ccr` NOD/REG，因此 ELF 变，因此违反裁-V4「`#` 不改运行时语义」；2 现机制 = DFNode 逐条由 `emit()` 建（`dataflow.cr:99` `df_create_node`，`ir_gen` 生成期逐指令调用），因此无「不落指令流」的旁路；3 独立 scratch 函数须回滚 `g_ir_func_count/g_ir_instr_count` 且生成期副作用不可回滚（`alloc_type` 行表/optrep 侧表/state 链，见 `main.cr:549-575` 见证面清单），因此高风险）。编图转 C1b，其前置 = 先裁「注解 IR 的实现方式」（新 `.ccr` 段 vs 独立产物） | 按推荐（若坚持编图，则停：须先裁实现方式，属停条件5） |
| 裁-S5 | 三态如何呈现？（通过/黄/失败） | 诊断检查 / rc / 检查 | 通过 + 黄 = dump 通道（纯打印）；失败 = 诊断（`error[V..]` + rc=1 + 零产物）（理由见第 1.7 节：通过黄走诊断会被 fail-closed 误阻断） | 按推荐（唯一安全解） |
| 裁-S6 | 诊断码分配 | `ast.cr` / `diag.cr` / `docs/developer/errors.md` | 新家族 17xxx，因此 `error[V01…]`：`error_cat_prefix` 加 `if cat == 17 { return "V"; }`（`diag.cr:86-104` 尾部 + 一行）；首批码 = `EC_V_CHECK_FALSE = 17001`（常量假，唯一硬错）+ `EC_V_BAD_TAG = 17002`（未知 `#` 标签/形态错），须同步 `docs/developer/errors.md`（该文件自注「改码须同步 ast.cr 注释与本文」） | 按推荐 |
| 裁-S7 | bootstrap（Python）面同批做吗？| 两前端接受集 / 自举链 | 同批做「最小一致面」：`bootstrap` lexer 认 `#`+IDENT 产 token、parser 消费标注链并忽略（不做检查/VC），理由：1 两前端同判是本仓既有约定（`test_lexer_parity.py`）；2 成本小（lexer 单字符表 + parser 一处）；3 否则分歧升级为「拒 vs 收」。明确不做：bootstrap 侧不产诊断、不产 VC（它不是语言参照实现） | 退路 = 显式登记分歧（bootstrap 对 `#` 响亮报错 = fail-loud，不是不报错地），因此可接受但须入 TODO |
| 裁-S8 | 名字域：`#ensure` 绑 `result`；与形参重名？`#check` 有无 `result`？| checker 域检查 | `#check` 域 = 形参 + 文件级可见名（全局常量/函数名，本批子集无调用，因此实为形参 + 常量）；`#ensure` 域 = 形参 + `result`；`result` 与形参同名，因此硬错（`EC_V_…`，避免歧义不报错地）；域外名，因此硬错（不是 yellow，「名字不在域内」是形态错、可判定） | 按推荐 |
| 裁-S9 | 表达式子集精确边界（对裁-V5 的实施细化） | T2/T3/T4 + 用例面 | C1 子集 = {int/bool/dchar 字面量 · 形参 ident · `result`（仅 ensure）· 一元 `-` `!` · 二元算术/比较/逻辑 · 括号}；禁调用 / 字段 / 下标 / `Some`/`None` / `?` / 赋值（属后续批）。因此 spec-design 四的 `result != None` 示例不在子集内，T6 须在文档标注（或改写示例为 `#ensure(result >= 0)` 形态） | 按推荐（若要求含 `Some/None`，则需额外裁 `?` 类型判定面） |
| 裁-S10 | dump 通道名与格式 | T4 + 检查 | `--dump-vcs`（隐藏 flag，照 `main.cr:240-253` 家族）；输出 = `dump_buf_*` 逐行、源序、`[vcs] ` 前缀；只打印、不改 rc/产物；不落文件（零新产物，因此无 `.gitignore`/格式包袱） | 按推荐 |
| 裁-S11 | 新语料入仓位置 | 两条检查计数 / CI 接入点 | 新目录 `tests/spec/`（`#` 语料）+ 新套件 `tests/selfhost/test_spec_grammar.py`；不进 `tests/probes/`（否则 `PROBE_TOTAL 29到30`）也不进 `tests/suite/`（否则 `CORPUS_TOTAL 74到75`），理由：两条检查是既有行为回归检查，其计数不变本身就是「旧面零扰动」的最强证据 | 按推荐（若坚持进 `tests/suite/`，则须同批改 `parity_run.sh:31` 计数 + 分层注释 + `REBUILD.md`，并把 74 改为 75 记入清单） |
| 裁-S12 | 零影响强度：只要求「无 `#` 的程序不变」，还是更强的「同程序 ± 注解，产物逐字节同」？| 检查强度 / 实施约束 | 强式（推荐）：`corec build` 同一程序 1 无注解 2 加 `#check` 3 加 `#ensure`，因此 ELF + `.ccr` 逐字节同。理由：1 构造性可判（无需新工具，sha256 即可）；2 它把裁-V4「零运行时语义」变成机器检查而不是口号；3 它当场堵死裁-S4 的「编图」近路（编图必然违反） | 退路 = 只做弱式（无 `#` 的不变），强式转下一批 |

### 3.2.1 取裁记录（维护者 2026-09-17 已裁；本节为最终裁定，覆盖上表「未取裁时」列）

| 门 | 裁定 | 理由要点 / 落实点 |
|---|---|---|
| 裁-S4 | 出列（C1 不编图） | 三条依据（编图，因此写 `g_ir_instrs`，因此 `.ccr` NOD/REG 变，因此 ELF 变 · DFNode 逐条由 `emit()` 建无旁路 · scratch 方案生成期副作用不可回滚）判决定性；另加与前门的一致性论证：裁-V4（零影响）+ 裁-S12（强式）与编图直接冲突。将来编图 = 独立批 + 独立检查，前置 = 先解决「生成期副作用不可回滚」。因此 T4 不含编图；编图归 T7 的 C1b |
| 裁-S7 | 同批做「最小一致」（bounded） | 理由：「一方拒收合法语法」是最坏那类两编译器分歧（不是意见不同，是一边直接打断）。边界固定：bootstrap 侧只需「接受并跳过」（零语义），能词法化、不报错、不影响产物；不要求实现 VC/三态；完整 bootstrap VC 面登记后续。检查：1 一份最小带 `#` 语料在两侧都 rc=0 且产物逐字节同；2 既有语料两侧行为不变 |
| 裁-S12 | 取强式 | 同程序 ± 注解，因此 ELF + `.ccr` 逐字节同；它把「`#` 没碰任何下游」从声明变成检查 |
| 裁-S1 / S2 / S3 / S5 / S6 / S8 / S9 / S10 / S11 | 按推荐 | 逐条见上表「推荐」列。附带：S9 的 `result != None` 示例不在 C1 子集内，因此 T6 标注/改写；S11 的「两条检查计数不变」= 旧面零扰动的最强证据（维护者确认） |

三条提醒（维护者；已逐条落进任务卡正文）：
1. T0 的 RED 复现是「预测」，因此不得当已有证据用，须实测后替换（T0 卡）。
2. 第 1.10 节文档计数陈旧面，因此 T6 顺带修，但改计数前先实测（不得再写一个过期数）。
3. 实施者不得声称「已处理纯度时序陷阱」，裁-V5 是回避不是解决（T3 卡内明令保留）。

---

## 4. 任务表（T0..T7；每卡含：前置 / 改动面 / 检查 / 停条件）

> 纪律（照 P6 事故护栏）：含「先裁」的任务把护栏写进任务卡正文；一构建一编译串行（同工作区禁并发构建）；`nice -n 19`；cwd = 仓库根；比较前 `clean-cache`；路径限定 jj 提交；自测用例只增不减。

### T0 — 前置（固定基线 + 起点检查 + 六门写进文档）
- 前置：无（本卡即前置）。
- 动作：1 `jj workspace add` 独立工作区（本批 = `core-veri-ws` @ `feature/spec-grammar`，已建）；2 固定基线重建（`bash tools/baseline/rebuild.sh /tmp/spec-baseline`，方法 = `REBUILD.md`；须重新运行自证：三 sha = 允许清单 + 确定性 ×2 + 快速验证 42）；3 起点检查表（检查项174 空缓存状态 rc+日志落 `/tmp/spec-t0/parity_pre`；检查项229 + warm 7；`canary_check.sh` 全部通过）；4 六门写进文档（第 3.1 节）+ 十二门取裁写进文档（第 3.2.1 节，已完成）；5 定位点重取（第 1 节全部 `file:line` 在开始实施 revision 上重核一遍，行号变化即更新本节）；6 RED 复现：已实测（2026-09-17），结论见第 10.2 节，实测结果与本节原「预测」不符且更严重（预测 = 报 P0xx 语法错；实测 = 无解析错，标注表达式被误当函数体，则 `error[TF01]`（build 面豁免码），则 `build` rc=0 + 产物，运行返回 0（应返回 1）= 不报错地误编译）。预测文本已由第 10.2 节取代，保留此注否证痕。
- 检查：基线三 sha 命中 + 起点两条检查落盘 + 六门/新门入纸 + RED 实测记录。
- 停条件：基线 sha 不符，因此停（`REBUILD.md` 换代纪律 1：不得改允许清单对齐）。

### T1 — 词法面（`#` token）+ 零影响构造性检查
- 前置：T0（尤其裁-S7）。
- 改动面：`src/compiler/ast.cr`（`T_HASH : int = 101`，注释写明「空洞外首个自由号；勿重编号」）；`src/compiler/lexer.cr`（单字符分支加 `#`；不动注释分支）；bootstrap 侧（裁-S7 = 同批「最小一致」，bounded）：`bootstrap/corec/syntax/tokens.py` + `bootstrap/corec/frontend/lexer.py` + `bootstrap/corec/frontend/parser.py:240 parse_function_decl`，只做「接受并跳过」（零语义）：能词法化、不报错、不影响产物；不要求 VC/三态（完整 bootstrap VC 面登记后续）。不得动 `lexer.py:287` 的未知字符报错（那是最后一道响亮防线，`#` 之外仍需它）。
- 检查（四条，缺一不可）：
  1. 静态：`T_HASH == 101` ∧ 既有 token 常量 0..100 值一字不动（脚本比对改动前后的常量表快照）；`T_HASH` 不与任何既有 token 号相撞。
  2. 构造性零扰动：全仓 `.cr` 裸 `#` 扫描断言（T0 的脚本入仓为 `tests/spec/scan_bare_hash.py` 或并入 T5 套件），182 档 0 命中；此断言使「加 token 改了既有语料」变成不可能而非「没观察到」。
  3. 非 `.cr` 的 `#` 语义不变：HIT 表 / `.so` 索引 / kernel 行格式四处（第 1.2 节）行为逐字节不变（取样 + 对比）。
  4. canary 五条 IDENTICAL（`canary_check.sh`）+ 检查项174 / 检查项229 零差异（对比 runner 两态 diff 空）。
- 停条件：canary 变，因此停（发射面泄漏，不是「容忍区」）。

### T2 — 语法面（标注链 + EBNF + 负例）
- 前置：T1（裁-S1/S2）。
- 改动面：`src/compiler/parser.cr` 在 `:1440`/`:1442` 之间加标注链（`#` IDENT `(` `parse_expr()` `)`，可多条）；标注记录落侧表（建议 = `globals.cr` 新增 `g_spec_*` 平行数组 + `dyn_arr.cr` 访问器，照 `FuncInfo` 侧表化后的既有形态）；不挤 `EXPR_FN` 的 `a/b/c`（`:1451` 语义不变）；`grammar/core.ebnf:12-13` 加标注产生式（`FunctionDecl = [ 'pub' ] 'fn' … '->' Type { Annotation } ( FunctionBody | '=' Expr ';' )` + `Annotation = '#' IDENT '(' Expr ')'`）；`_import.cr` + `build_selfhost_native.py` 清单同步（若新增 `.cr` 文件，建议新文件 `src/compiler/spec.cr`，只放纯 Core 代码，自身不含 `#`，保 bootstrap 面安全）。
- 负例（≥8，全部须「响亮」）：`#` 后非 IDENT；`#check` 缺 `(`；`)` 未闭合；标注出现在签名前/body 后；未知标签（`#foo(…)`）；`#` 在表达式位置；`#check(,)`（表达式语法错）；`#ensure` 用在无返回函数（若定为硬错）。每条 = rc=1 + 定位诊断 + 零产物。
- 检查：正例 ≥6（单条/多条/多函数/带泛型/`=` 形 body/`{}` 形 body）；负例 ≥8；零影响：T1 的四条全部通过。
  T2 三条硬验收（维护者 2026-09-17 批准时指定，不可省）：
  1. 两侧都接受 rc=0（bootstrap 侧已通过）+ corec 侧 ±注解 ELF/`.ccr` 逐字节同（裁-S12 强式），本批检查标准（见第 11 节的约定修正）；
  2. 撞名形态必堵（第 11.1 节实测的 T1 漏洞）：`fn check(x: bool) -> bool` 存在时，`#check(1 < 0)` 所在函数必须 rc=1 + 零产物，不得依赖「注解名恰好未定义」才响亮；
  3. 负例 ≥8 必含：签名外位置的 `#` · 重名冲突 · `#ensure` 在 `#check` 前 · 空 `#check()` · 非布尔表达式 · 注解链重复（另加 T2 卡原有的位置/形态错例）。
- 停条件：负例出现不报错地通过（rc=0），因此停（本批最要消灭的形态）。

### T3 — 检查面（三查 + 时序纪律 + 诊断码）
- 前置：T2（裁-S5/S6/S8/S9）。
- 改动面：`src/compiler/spec.cr` 新增三查：1 bool 型（走判定引擎三态，`-1` 未判，因此不得当 0/1，照 R2 P5 三态纪律；不可译，因此硬错）；2 名字域（裁-S8）；3 纯度，本批子集无调用，因此空转（须在代码注释里写明「时序陷阱未解决、仅因无调用而空转」，防后来者误以为已处理）；诊断码 `EC_V_*`（`ast.cr` 17xxx）+ `error_cat_prefix` 分支（`diag.cr:86-104`）+ `docs/developer/errors.md` 同步；常量折叠（通过/失败判定：仅 literal 与字面量运算，不做代数化简）。
- 检查：三查正控/负控各 ≥6；裁决性检查 = 通过黄绝不出现在诊断通道（`--dump-vcs` 有、stderr 无）；失败 = `error[V01]` + rc=1 + 零产物；全语料 report-only 扫面（新硬错在 74+29 档命中必须为 0，若命中非空，则停）。
- 停条件：新硬错全语料命中非空，因此停上报。

### T4 — VC 记录 + dump 通道
- 前置：T3（裁-S3/S4/S10）。
- 改动面：VC 记录结构（函数 / 种类 / AST 节点索引 / 行 / 列 / 状态 / 规范化文本）；规范化 printer（新函数，只服务 dump，不参与判定）；`main.cr` 注册 `--dump-vcs` + 在全部分支（`check` / `ccr` / `cir` / `build` / `run`）的既有 dump 家族位置打印（照 `main.cr:240-253` 纪律：只打印、不改 rc/产物）；`dump.cr` 加 `vcs_text_dump()`（复用 `dump_buf_*`）。
- 检查：1 源序确定（同一源两次编译 dump 逐字节同）；2 空缓存/有缓存同（`clean-cache` 前后 + 缓存命中路径，构造性成立，第 1.8 节）；3 零产物影响（开/关 `--dump-vcs`，因此 ELF/`.ccr` sha 同）；4 三态齐全（green/yellow 各 ≥1 例，red 走诊断）；5 强式零影响（裁-S12 已裁：取强式）：同程序无注解/`#check`/`#ensure` 三态 ELF+`.ccr` 逐字节同（sha256 全等；这是本批的检查清单，把「`#` 没碰任何下游」从声明变成检查）。
- 停条件：dump 开/关导致产物变，因此停（dump 必须零副作用）。

### T5 — 检查三件套（语料 + 套件 + 接入点）
- 前置：T4（裁-S11）。
- 改动面：`tests/spec/*.cr` 语料（正/负/边界，目录独立于两条检查）+ `tests/selfhost/test_spec_grammar.py`（照 `tests/selfhost/test_params_limit.py` 的 harness 体例：`_compile` / `case_run` / `case_reject`）；接入点：`src/ci/run.sh` 的 `selfhost-tests` job 加一行（`python3 tests/selfhost/test_spec_grammar.py`）+ 实测时长入注释；`tests/harness/ci_hook_allowlist.txt` 不加条目（挂上即不属未挂项），但须运行 `tests/harness/test_ci_hook_coverage.py` 自证覆盖率检查仍通过（三件套 = `run.sh` 接入点 + 允许清单 + 覆盖率检查）。
- 检查：新套件全部通过；覆盖率检查通过（非空转下限 `MIN_SCOPE=50/MIN_HOOKED=30` 仍满足：实测 71/50）；两条检查计数不变（74/29 硬断言仍过 = 旧面零扰动的机械证据）。
- 裁-S7 的检查（bounded，两条）：1 一份最小带 `#` 语料在 corec 与 bootstrap 两侧都 rc=0，且产物逐字节同（`clean-cache` + 同源同参）；2 既有语料两侧行为不变（bootstrap 侧 = `build_selfhost_native.py` 的 `error[`/未定义符号守卫仍 0；corec 侧 = 两条检查）。bootstrap 侧不做 VC/三态，检查只认「接受并跳过」。
- 停条件：不得为「让新语料进来」而放宽两条检查的 `CORPUS_TOTAL`/`PROBE_TOTAL`（放宽即销毁「计数不变」这条证据）。

### T6 — 结束（回归 + 清单 + 文档）
- 前置：T1-T5 全部通过。
- 动作：五 CI job 全运行（`check`/`bootstrap-tests`/`selfhost-tests`/`suite`/`full-bootstrap`）；自举链 `corec2==corec3` + `N06=0` + 快速验证 42；`selftest-types` + 全套件枚举（59 改为 60）；文档：`spec-design.md`（示例标 C1 子集 + 十七阶段目标打勾）、`docs/developer/syntax.md`（二词法/四标注位置加 `#check`/`#ensure`）、`docs/developer/errors.md`（V 家族）、`grammar/core.ebnf`（已在 T2）、第 1.10 节的陈旧面逐条修（`REBUILD.md` 72 改为 74、`parity_run.sh:33` 分层注释、`run.sh:106` 73 改为 74、`ci_hook_allowlist.txt` 头注刷新），改计数前先实测，不得再写一个过期数（维护者提醒 2）；`TODO.md` 新条目（当日号 + 登记未修项）；统一清单（本批各任务检查汇总）。
- 检查：全部通过 + 文档 diff 逐条可核。
- 停条件：任一 job 失败，因此停下定位（不得以「本批是文档批」为由跳过）。

### T7 — 下一批指向（不实施，仅登记）
- C1b「编图 / 注解 IR 实现方式」（前置 = 裁「新 `.ccr` 段 vs 独立产物」= 段表变更裁决）。
- C1c「允许可证纯调用」（前置 = 纯度时序完成：读点移到 `df_state_finalize` 后或改读 state 链，第 1.6 节）。
- C2「自动标签（纯度/region/provenance 事实入实现方式）」、C3「运行时插模拟（显式开关）」、C4「spec fn / 量化 / 翻译桥（须先裁 CIC 内核）」。

---

## 5. 验收设计（本批的核心）

### 5.1 零影响 = 硬性检查（旧面零扰动；两条检查 + 五条出处）

| 检查 | 命令（约定） | 期望 | 出处 |
|---|---|---|---|
| canary ELF | `canary_check.sh`（内建逐条 `clean-cache` + `HOME` 归一化） | `95084e7b…d475`（28822B）IDENTICAL | `tools/baseline/canary_values.tsv` |
| `.ccr` 四条 | 同上 | `680a6f98…` / `76f36e6a…` / `d92a2727…` / `a1f7b99c…` | 同上（两种形式差恒 143B 的根因见 `:43-47`） |
| 检查项1 固定基线同源对比 | `parity_run.sh <frozen> /tmp/a` × `parity_run.sh ./build/corec /tmp/b`，因此 `diff -rq a/logs b/logs` | 空（74 档 rc + 日志） | `REBUILD.md:52-56` |
| 检查项2 行为探针 | `probes_run.sh` 两态，因此 `diff -rq` | 空（29 档；rc=1 多为预期负例，检查 = 零差异，不是全 0） | `tests/probes/README.md` |
| 检查项3 有缓存状态 | `warm_run.sh`（有效性 7 档）+ 广度层随两 runner | 一致 + 有缓存状态生效档数 ≥1（0 = 空洞警报） | `REBUILD.md:64-96` |
| 构造性面 | 全仓 `.cr` 裸 `#` 扫描（入仓断言） | 0 命中（182 档） | 本计划第 1.2 节（须在 T1 固化为仓内脚本 + 套件断言） |
| 强式零影响（裁-S12 若取推荐） | 同程序加减注解，比较 `sha256` 的 ELF / `.ccr` | 逐字节同 ×3 形态 | 本批新增 |

### 5.2 `#` 面自身（正控 / 负控 / 三态分流）

| 类 | 用例（≥ 数） | 期望 |
|---|---|---|
| 正控 | `#check` 常量真（通过）· `#check` 未证（黄）· `#ensure(result…)`（黄）· 多条同函数（源序）· 多函数（声明序）· `=` 形 body · 泛型函数 · 无返回 `-> unit` 的 `#check` | rc=0 + 零诊断 + dump 行数/内容精确匹配 |
| 负控（语法） | `#` 后非 IDENT / 缺 `(` / 未闭合 / 位置错（签名前·body 后）/ 未知标签 / 空表达式 | rc=1 + `error[V02]` 定位 + 零产物 |
| 负控（域/型） | 域外名 / `result` 出现在 `#check` / `result` 与形参重名 / 非 bool 表达式（`#check(1)`） | rc=1 + `error[V…]` |
| 硬错（失败） | `#check(1 < 0)` · `#check(false)` · `#check(1 == 2)` | rc=1 + `error[V01]` + 零产物 + 不得同时产出 dump 的「通过」行 |
| 不阻断（黄） | `#check(x > 0)`（形参）· `#ensure(result >= 0)` | rc=0 + stdout 无 `error[` + stderr 无诊断 + dump 有 yellow 行 |
| 三态分流（本节最重要） | 上述三类的通道断言 | 通过/黄，因此只在 `--dump-vcs`；失败，因此只在诊断；两者不混 |

### 5.3 探针入仓形态 + 接入点三件套
- 语料：`tests/spec/*.cr`（不进两条检查；`tests/probes/README.md` 的「非编译单元」约定不适用于本目录，本目录是编译单元，由新套件驱动）。
- 套件：`tests/selfhost/test_spec_grammar.py`（只增不减；每例一个 `case_*`，含 `_compile`/`case_run`/`case_reject` + 无产物断言 + 无 core dump 护栏）。
- 接入点三件套：1 `src/ci/run.sh` 的 `selfhost-tests` 加 `python3 tests/selfhost/test_spec_grammar.py`（行首可执行、非注释，`test_ci_hook_coverage.py` 的检查3只认这种形态）；2 `ci_hook_allowlist.txt` 不加条目（挂上=不属未挂项）；3 运行 `test_ci_hook_coverage.py` 自证（覆盖率检查 + 突变自证）。
- 突变控制（≥3，须入套件或报告）：M1 摘掉 `#` 词法分支，因此正控全部失败；M2 摘掉「常量假，因此硬错」，因此失败例变通过（必须失败，这是本批唯一硬错）；M3 让 yellow 走诊断，因此 「不阻断」例变 rc=1（必须失败）；M4（若裁-S7 同批）摘掉 bootstrap 的 `#` 分支，则两句柄分歧检查失败。

---

## 6. 全局约束（全批适用）

- canary 硬性检查：`95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`（28822B），变 = 越界，因此停下上报（不是容忍区）。
- `.ccr` 五条出处（只此一处）= `tools/baseline/canary_values.tsv` 末 5 行数据行（ELF 1 + `.ccr` 4）；检查 = `tools/baseline/canary_check.sh`（fail-closed F1-F4；只锁空缓存状态，不得「补全」成冷暖双锁）；手工复测运行须 `HOME` 归一化（照 `REBUILD.md:133-148`；2026-09-17 起归一化仍保留作双保险）。
- 检查项1 = 74 档（`CORPUS_TOTAL` 硬断言；实测分层 34/2/15/19/4）· 检查项2 = 29 档（`PROBE_TOTAL` 硬断言）+ warm 7 档 · 两条检查计数本批不得改（改了 = 销毁「旧面零扰动」的机械证据）。
- 五 CI job：`check` / `bootstrap-tests` / `selfhost-tests` / `suite` / `full-bootstrap`（`src/ci/run.sh:61/67/98/199/204`）。
- 自举链：`corec2 == corec3` + `N06 = 0` + 快速验证 42（`run.sh:204-215`）。
- 枚举：`selftest-types`（`run.sh:115` 记载 415 例）+ 全套件枚举 `tests/{selfhost,bootstrap,harness}/*.py`（不含注释里的自称）+ 清单三面同核（`build_selfhost_native.py` 清单 / `_import.cr` / 新增文件三处同步）。
- 三态纪律（R2 P5 起）：判定 `-1`（未判）不得当 0/1；未知，因此响亮（本批硬错 `EC_V_*` 或 yellow，不得不报错地）。
- 先裁后码：第 3.2 节未取裁的门不得实施（含「先裁」的任务把护栏写进任务卡正文）。
- 工具/纪律：`nice -n 19`（硬性规则 6）· 一构建一编译串行（同工作区禁并发构建）· cwd = 仓库根 · 比较前 `clean-cache` · 只 jj、禁 git（硬性规则 2）· 路径限定提交 · 文件永不还原（硬性规则 3）。
- 不得回退既有收纳：TS01-04/TK02/R002/TM03/ICE04/TA02 硬门 · P4/P5/P6 全批 · 容量批 / fail-closed 批 / 检查实现方式化批 / home-repro 批的既有裁决，本批一律不动。
- `.ccr` 段表 / `CCR_VERSION=9` / `CIR_CACHE_VER=18` 本批不动（停条件5）。

## 7. 停条件（任一命中，因此停下上报，不得自行取裁）

1. canary 变（五条任一），因此注解泄进发射面。
2. 两条检查出现非章程 diff，因此判定面行为变更（新检查若改既有语料 rc，则先 report-only + 裁决）。
3. 新硬错（`EC_V_*`）全语料命中非空，因此停（不得靠豁免表 `diag_gate_exempt` 掩盖，该表「只减不增、加条须维护者批」）。
4. 被迫动 `.ccr` 段表/版本位或 `.cir` 快照布局，因此停（单独裁决 + 失效面登记）。
5. 被迫引入外部依赖（SMT/CIC/新工具链），因此停（越出 C1）。
6. 纯度时序：若实施中需要读生成期 `fi_ispure` 而无法在不改发射面的前提下完成，则停（裁-V5 已把该风险出列，不得顺带「解决」）。
7. bootstrap 分歧升级：若裁-S7 取「不动 bootstrap」而自举链上出现 `#` 形态，则停。
8. 工作副本不干净或他方在途，因此停（照 P6 事故护栏）。

## 8. 未决项（不猜；须实证 / 须裁）

- U-1：spec-design 八/第 9.3 节称 `variant`/`forall`「EBNF 已有」，实读零命中，因此文档勘误（T6 顺带）。
- U-2：`.csr` schema（`docs/ir-schema/corespecir-schema.md`）称「真源 = `ccr_io.cr`」，实读零命中，因此勘误 + 转 C1b。
- U-3：`docs/project-book.md` 第 3.2 节仍按已退役的独立 `.corespec` 叙述，因此陈旧文档（T6 顺带）。
- U-4：`fi_ispure` / provenance / region 事实是否入实现方式，实读 = `.ccr` 零命中，因此 C2/十三门控通道须先建实现方式通道。
- U-5：`.cir` 是否有对外序列化（实读 = DOT + 私有缓存快照两形态），若维护者知道第三形态，则更正。
- U-6：CIC 内核选型（Rocq vs Lean 4）挂起，因此本批不依赖；C4 依赖。
- U-7：`where` 值约束三档（`TODO.md` 的「规约语法并入 .cr」节）与 `#check`/`#ensure` 的关系（同族语法还是两套），因此须裁（影响 T2 产生式）。
- U-8：`#pure` / `#tag` / `#invariant` 等其余标签的先后（spec-design 六列出，C1 不做），因此转 C2。
- U-9：`#` 是否允许出现在 `impl` 块内的方法（`grammar/core.ebnf:102` 的 `ImplDecl` 内嵌 `FunctionDecl`），因此须裁（影响 T2 的接线点数量）。

## 9. 自检记录

- 根因 vs 止血：本批不做「先接个误报通过勾」的兑现，C1 明确不判定真值（唯一判定 = 常量折叠），未证如实标 yellow 且不阻断，与 spec-design 十二 + 仓内三态纪律一致。
- 诚实边界：本计划零构建、零源码改动；行号 = `dbadb8d6` 实读；第 1.2 节的全仓扫描是本计划实际运行的唯一实验（只读、可复现，扫描范围已写入验收设计）；第 4 节 T0 的 RED 复现为「预测」，标注待实测。
- 与既有裁决的一致性：ADR-0001（规约并入 `.cr`）· spec-design 六（`#` 与 `@` 分工）/十二（unproven 不拦）· 裁-V1..V6 · `TODO #2026-09-11-9` 检查标准（结构性断言 + 语义零变化 + 自举稳定）· 三态纪律 · P4 T5「零影响」先例（裁-V4）· P6 事故护栏（含「先裁」入卡）。
- 占位符扫描：无 TBD；第 3.2 节十二门逐条「推荐 + 未取裁时」；第 8 节九条未决项全部指向具体文件/行或明确「须裁」。
- 最大风险（本计划判定）：1 通过/黄误走诊断通道（会与 fail-closed 检查耦合出「未证即 rc=1」，直接违反裁-V6），缓解 = 第 5.2 节的通道断言 + 突变 M3；2 实施者顺带「编图」（会把 `.ccr`/ELF 改坏），缓解 = 裁-S4 + 裁-S12 强式检查；3 bootstrap 面被遗忘（分歧升级），缓解 = 裁-S7 + 突变 M4。

---

> 第 10–17 节（实施记录）见 [implementation/2026-09-17-spec-grammar.md](../implementation/2026-09-17-spec-grammar.md)。
