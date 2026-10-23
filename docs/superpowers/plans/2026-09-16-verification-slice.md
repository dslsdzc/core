# 验证切片轮（verification slice）实施计划（草案）

> 状态：草案已写入仓库（2026-09-16，R0-B；原稿在 `/tmp/verslice/`，写入仓库的内容为全文加本节头部）。开始前提是裁-V1..V6（第四节）；尚未实施任何一行。
> 定位（受众、状态、以哪份为准）：受众 = maintainer（规约层 = 设计态）；状态 = 草案（待裁）；以本文（切片边界与任务表）和 `maintainer/design/spec-design.md`（规约设计权威）为准。
> 事实边界：本草案写作时没有运行任何构建、编译或测试（只做了只读 grep/sed/Read，实查 `ps`，未运行 `jj`）。因此行号是草案写作时工作树的实读值，T1 必须重新取值。这与本仓「形式上成果只对当轮 revision 有效」的约定一致。
> 格式：按本仓 SSDD 组织（Goal、Architecture、切片边界、分类表、裁决门、任务总表、Global Constraints、停条件、未决项、自检记录）。

目标：实现「语义保留」标志下规约层从 0 到 1。设计已定（`docs/maintainer/design/spec-design.md`，556 行，v2 CIC 内核加 SMT 证书架构），实现为零（parser/lexer/checker 没有任何规约面）。本切片只做第一步：连通端到端链「用户写下 `#check`/`#ensure`，编译产出可打印、可检查的 VC 清单」。不接入求解器，不接入 CIC 内核，不做 spec fn、量化和转换桥。

架构（第一步的形态）：
```
.cr 源码（#check/#ensure 标注）
    交给 lexer：`#` + IDENT 词法（新 token）
    交给 parser：函数声明的标注链（签名与 body 之间）+ 表达式复用 parse_expr
    交给 checker：注解表达式三查（bool / 纯 / 名字在域内），只判形态，不判真值
    交给 ir_gen/dataflow：表达式编为普通条件子图（DFNode/DFEdge；状态边照常）
    交给 VC 注册表 + 输出通道（按裁-V2：`--dump-vcs` dump 或 `.csr` v1）
    交给消费者：`corec` 自带读回 dump，第三方按 schema 读
```
关键边界：VC 的真值判定一律不做（唯一例外是常量折叠出的「常量假，因此为失败」）；「未证明」不拦编译（spec-design 第十二节已定稿）。

Tech Stack（实读基准）：`src/compiler/lexer.cr`（`#` 零词法）· `src/compiler/parser.cr`（`:30 fn check` = token 谓词助手，非规约）· `src/compiler/checker.cr`（`compute_all_purity` `:3975`）· `src/compiler/dataflow.cr`（`df_create_node` `:99` / `df_connect_state` `:156` / `df_graph_to_dot` `:512`）· `src/compiler/ccr_io.cr`（`CCR_VERSION = 9` `:135` / `CCR_SEG_COUNT = 8` `:138` / TYPE=`7` `:139` / IFACE=`8` `:140`）· `src/lattice/ent_kernel.cr`（`ESZ_NOD_SEM = 32` `:1010` / `OFF_NS_ITEM = 28` `:1022`）· `src/compiler/main.cr`（`cli_cmd("cir")` `:236` / cir 分支 `:583` / `region_check_all(); provenance_verify_all();` `:614-615`）· `src/compiler/{region_check,provenance_verify,ptr_analysis}.cr` · `grammar/core.ebnf:12`（`FunctionDecl`，无标注槽）· `docs/ir-schema/corespecir-schema.md`（117 行，`.csr` v1 设计：头 32B + TagNode 40B + magic `CSR1`）· `src/stdlib/assert.cr`（panic 基元）。

Spec：`maintainer/design/spec-design.md`（第四节 语法示例 / 第六节 `#` 标签语法 / 第七节 检查函数 / 第八节 量词 / 第十一节 求解器接口 / 第十二节 绿黄红 + unproven 不拦 / 第十三节 证明门控优化 / 第十四节 管线 / 第十七节 阶段节点 / 第十八节 内核选型暂停）· `adr-0001-corespec-crasm-retired.md`（规约并入 `.cr`，2026-09-06）· `TODO.md:844`「规约语法并入 .cr」（含 `where` 值约束三档，再 验证切片）· `TODO.md:886`「验证/工具自动化」· `docs/project-book.md:210` 第 4.7 节（验证工具 = 外部消费者）。

---

## 一、切片边界（关键）：五个候选 + 推荐第一步

| # | 候选 | 一句话 | 能证明什么 | 不能证明什么 | 代价 |
|---|---|---|---|---|---|
| C1 | 用户规约最小面 + VC 打印（推荐） | `#check`/`#ensure` 布尔表达式（无量化、无 spec fn），因此编入图 + 产出可打印 VC 清单（零求解器） | 1 语法/解析/检查/编图/实现方式整链贯通（0 改为 1）2 实现方式与 schema 的先裁被逼出（`.csr` vs dump）3 后续切片（量化/转换桥/SMT）有了接入点 | 不证明任何程序性质（无判定）；不覆盖量化/归纳/高阶 | 中 |
| C2 | 自动标签 + `.csr` 实现方式（无用户语法） | 用已有裁决事实（纯度/region/provenance）产出 `.csr`-lite 自动标签（`auto_proven`）+ 读回 | 1 实现方式 + 消费通道 2 第十三节「已证性质表，再 优化门控」的前置 | 无用户表达面（用户写不了性质） | 小-中 |
| C3 | 运行时契约插模拟 | 把 C1 的 VC 编成运行时 assert（显式开关），借 `assert`/`panic` 给「反例」 | 动态证伪（红 = 具体输入违反）；开发期即刻有用 | 不是证明（只能证伪不能证真） | 中 |
| C4 | spec fn + 量化 + 转换桥 | `spec fn`/`forall`/循环，再递归/终止性变体，再 CIC 项 | 设计稿的表达力面 | 需要内核选型（第十八节 暂停）+ 信任根 | 大（勿先切） |
| C5 | 外部消费者原型（零编译器改动） | 仓库外写一个读 `.ccr`/`.cir` 的最小 VC 提取器 | 实现方式自足性（第三方不看源码能否重建语义） | 无规约可提取（没有用户面） | 小-中 |

推荐第一步 = C1（lead 草图同向），理由三条：
1. 0 改为 1 的价值不在「证了什么」，而在「链通了」，设计稿 第十四节的管线（`.cr`，再 图，再 `.csr`）此前一行实现都没有；C1 把这条链的每一环（词法/语法/检查/编图/实现方式/读回）都变成可检查的实物，后续切片各自替换一环即可（C4 换「编图」、C3 换「消费」）。
2. C1 迫使两个「藏在设计稿里没定」的决策实现（见裁决门）：实现方式（`.csr` vs dump）与消费面（`.ccr` vs 补 `.cir` 序列化）。这两条不先裁，后面每一步都要重做。
3. 风险可控：`#` 标注不改运行时代码（设计定稿「`#` 标记的东西不影响运行时语义」），因此 canary `95084e7b…d475` 是一条构造性硬性检查；即便本步失败，也不伤发射面。

C1 的精确子集（最小可验证子集）：
- 标注位置：函数签名与 body 之间（per spec-design 第四节）；种类 = `#check(expr)` / `#ensure(expr)` 两种。
- 表达式面：bool 类型；名字域 = 形参 + `result`（`#ensure`）+ 既有全局常量；禁调用非纯函数（纯度用 `fi_ispure` 真值，见分类表时序陷阱）；禁 `forall/exists`/`spec fn`/`#tag`/`#pure` 等其余标签（前者属 C4、后者属 C2）。
- 判定面：只做常量折叠（`#check(1 > 0)`，因此绿-常量真；`#check(1 < 0)`，所以红-常量假）；其余一律 黄-待证。
- 反例面：只给常量假的具体值；符号反例属 C3/SMT。

---

## 二、分类表（逐要素：现状(file:line) / 最小代价 / 前置 / 建议）

| 要素 | 现状（实读） | 最小实现代价 | 前置 | 建议 |
|---|---|---|---|---|
| 标注语法（lexer） | 零：`src/compiler/lexer.cr` 对 `#` 无任何词法（`grep "'#'\|T_HASH\|annotation"` = 0 命中）；`grammar/core.ebnf` 亦无 `#check/#ensure/forall/variant/spec `（grep = 0 命中），因此 spec-design 第八节「EBNF 已定义」与 第 9.3 节「变体（EBNF 已有）」均不成立（须实证，T1 重核） | 小：新 token（`#`+IDENT 或复用注释起始面）；EBNF 同步一个产生式 | 裁-V5（表达式子集）；`#` 与 `@`（import/intrinsic）不冲突（spec-design 第六节 明示） | 实施（C1 第一步） |
| 解析 | 零：`parser.cr` 无规约面（`:30 fn check(k)` = token 谓词助手）；`FunctionDecl`（`grammar/core.ebnf:12`）= `[ 'pub' ] 'fn' IDENT [ GenericParams ] '(' [ ParamList ] ')' '->' Type (FunctionBody \| '=' Expr ';')`，因此无标注槽 | 中：签名与 body 之间加标注链（`{ #check(expr) }*`）+ 表达式复用 `parse_expr`；`spec fn` 关键字本步不做 | 词法 token | 实施 |
| 检查（类型/纯度/作用域） | 判定引擎在位（`type_engine.cr`，三态）；纯度已有真计算（`checker.cr:3975 compute_all_purity`）但无「注解表达式必须 bool/纯/在域」的门；风险项 时序陷阱：生成期 `fi_ispure` 是冻结的乐观默认值（TODO「性能自动化」节明注：消费侧须在 `compute_all_purity` 之后读） | 小-中：三查（`type_compat_strict` 判 bool · 纯度查禁用生成期旗标 · 名字域查 `def_sym`/形参表） | 解析；纯度读点必须在 IR 生成之后 | 实施（风险点，见停条件4） |
| VC 生成 | 零。最接近资产 = HDFG（`dataflow.cr`：`df_create_node :99`/`df_connect_state :156`）+ 三个已接线的图 pass（`main.cr:614-615` 调 `region_check_all` `region_check.cr:160` / `provenance_verify_all` `provenance_verify.cr:135`；另有 `ptr_analysis.cr`） | 中：注解表达式编为普通条件子图 + VC 注册表（函数/种类/节点 id/行列/状态） | 解析 + 检查 | 实施（C1 核心；只生成不判定） |
| 实现方式（`.csr` vs dump） | 零实现：`.csr`/TagNode 在 `src/` 零命中（`grep csr\|CSR1\|TagNode --include='*.cr' src/` = 0）；`docs/ir-schema/corespecir-schema.md` 称「真源 = `src/compiler/ccr_io.cr`」不成立（`ccr_io.cr` 对该面 0 命中），因此纯设计；`.ccr` 现行 = v9 八段（`ccr_io.cr:135/:138`），不含 purity/provenance（`ccr_io.cr` 对该面 0 命中） | 小（dump 通道）/ 中（`.csr` v1：头 32B + TagNode 40B，照 schema） | 裁-V2（先 dump 还是先 `.csr`） | 裁决门 |
| 求解器接口 | 零（无 SMT 依赖）；设计约定 = 证书经 CIC 内核（spec-design 第十一节，SMTCoq 模式：求解器不可信、健全性只在内核）；内核选型 Rocq vs Lean 4 暂停（第十八节） | C1 明确不做 | — | 转后续切片（C4+） |
| 反例呈现 | 间接资产：`assert`/`panic`（`src/stdlib/assert.cr`）· 解释器（`interp.cr`）· 诊断体系（`diag.cr`，`-->` 定位）；求解器级反例零。设计约定 = 绿/黄/红三态 + unproven 不拦编译（第十二节） | 小-中（C3 运行时版；C1 仅常量假 = 红） | 运行时插模拟须显式开关（`#` 默认零影响）+ 裁-V4 | C1 只落「常量假」；C3 另切 |
| 自动标签（C2 面） | 事实在、实现方式不在：纯度 = `compute_all_purity`（内存）；region = `region_check` + `.ccr` REG 段（在实现方式）；provenance/points-to = `ptr_analysis`/`provenance_verify`（pass 内部，不入实现方式）；state 边 = EDG 段（kind=1，在实现方式）；类型项 = TYPE 段 + NOD 项索引（v9，在实现方式） | 小 | 裁-V2 | C2（C1 之后） |

---

## 三、与 IR 的关系（裁决门级；逐条实读）

Q：验证消费 `.cir` 还是 `.ccr`？

| 面 | 实读事实 | 判断 |
|---|---|---|
| `.cir`（HDFG） | 1 `corec cir` 只产 DOT 文本（`main.cr:236` 命令注册 / `:583` 分支 / `:588 df_graph_to_dot()` / `:591` 默认 `*.cir`）；2 另有每函数缓存快照（`main.cr:527 cache_path + ".cir"`；`cir_cache.cr`，键 = 源路径：:函数名），私有缓存面，非交付格式，因此 `.cir` 无独立对外序列化 | 外部工具今天拿不到 `.cir` |
| `.ccr`（格形态） | v9 八段（STR/SYM/NOD/ENT/REG/EDG/TYPE/IFACE）· 版本检查（整类拒收）· 段表 + 确定性装填 · corearch 读回已实现（`--dump-types/--dump-ifaces/--dump-objects/--dump-nod-items`）· 类型项索引跨进程可解析 | 现行唯一可写入文件、可版本管、有读回的实现方式 |
| spec-design 的叙述（第十四节） | 「验证器加载 `.cir` + `.csr`」 | 与实现方式现实不一致（`.cir` 无交付格式），因此须裁（裁-V3） |

建议（裁-V3 的推荐案）：验证消费面 = `.ccr`（+ 若需规约元数据，则 `.csr` 与 `.ccr` 并列产物，`target_node` 指向 NOD 索引）；`.cir` 面只作开发期 dump。理由：1 `.ccr` 有版本检查/段表/确定性/读回四件套（P4–P6 已打牢）；2 让验证工具依赖私有缓存（`.cir` 快照）会把「缓存键/编译器身份」这类 TODO #2026-09-10-1 家族的问题带进验证链；3 若坚持 `.cir` 优先，等价于新增一个对外序列化格式，因此应作为独立裁项（工作量远大于 C1）。

Q：哪些语义必须已在 IR 里（「能用多少现有资产」）？

| 语义 | 现状（实读） | 是否够 C1 用 | 缺失 |
|---|---|---|---|
| 图结构（节点/边/嵌套 region） | HDFG 在位（`dataflow.cr`；region 嵌套 = SG_IF/LOOP/…）；`.ccr` REG 段写入文件 | 够 | — |
| 类型（节点级） | `.ccr` TYPE 段 + NOD 项索引（v9）+ `atom_of` 语义面 | 够 | — |
| 纯度 | `compute_all_purity`（`checker.cr:3975`）；state 链已保守覆盖全部效应（extern/spawn/yield/hotpatch/间接调用/原始指针写，因此入链） | 风险项 够（内存面） | 不入 `.ccr`，所以外部消费者拿不到；且生成期读点是乐观默认值（时序陷阱） |
| region / 边界 | `region_check.cr`（`_func :105` / `_all :160`）+ `provenance_verify.cr`（`_func :52` / `_all :135`），已在 `main.cr:614-615` 接线（编译期拒绝） | 够（`#safe_index` 类标签的现成事实源） | 事实不入实现方式（pass 内部）+ 无「标签，再 实现方式」通道 |
| state 边 | EDG 段（kind=1）写入文件 | 够 | — |
| 循环不变量 / 变体 | 零（EBNF 无 `variant`；spec-design 第 9.3 节的「EBNF 已有」不成立） | 完成（C1 不涉及） | 属 C4 |
| 量化 | 零（`forall/exists` 未入 EBNF/parser） | 完成（C1 不涉及） | 属 C4 |

---

## 四、裁决门（开始前置；逐条 = 问句 / 影响 / 推荐 / 未取裁时）

| # | 问句 | 影响 | 推荐 | 未取裁时 |
|---|---|---|---|---|
| 裁-V1 | 第一步 = C1（用户规约最小面 + VC 打印），还是 C2（自动标签实现方式）/ C5（外部消费者）/ C3（运行时插模拟）先切？ | 全部任务面 | C1（理由见 第一节；C2 作为其后的实现方式扩充、C3 作为其后的消费扩充） | 不实施（本计划只到「草案」） |
| 裁-V2 | VC 的实现方式：先落 dump 通道（`corec … --dump-vcs`，零格式承诺）还是直接落 `.csr` v1（32B 头 + 40B TagNode + magic `CSR1`，须定与 `.ccr` 的关系/版本族/是否入 `.gitignore`）？ | VC 生成 + 消费面 + 文档 | dump 先行、`.csr` 紧随（dump = 检查实现方式，`.csr` = 交付格式；避免第一步就承担格式成本） | 实施止于 dump，`.csr` 转下一步 |
| 裁-V3 | 验证消费面 = `.ccr`（现行实现方式）还是补 `.cir` 对外序列化（spec-design 第十四节 原文）？ | 实现方式 + 检查 + 后续切片全部 | `.ccr`（+ `.csr` 并列）；`.cir` 只作 dump | 以 `.ccr` 为准（若坚持 `.cir`，因此停下另立格式批） |
| 裁-V4 | `#` 系列是否永不影响运行时代码（默认零影响）？运行时插模拟（C3）是否作为显式开关（`-s`/`--contracts` 式）？ | canary 硬性检查 + 检查范围 | 是（零影响默认；插模拟显式开关，先例 = P4 T5 的「可选面零影响，因此发射面逐字节不变」） | 不实施插模拟 |
| 裁-V5 | C1 的表达式子集：bool 表达式（形参 + `result` + 纯调用？），禁不禁非纯调用（`len()`/纯辅助函数）？ | 检查 + VC 生成 + 用例面 | 允许可证纯的调用（`fi_ispure` 真值，须在 `compute_all_purity` 后读），禁 IO/unsafe/非纯 | 子集收窄到「无调用」 |
| 裁-V6 | 「未证明」语义：不拦编译（spec-design 第十二节）+ 报告三态（绿/黄/红）；`#check(常量假)` 是否硬错（红）？ | 诊断 + 硬名单 + 语料 | 不拦编译；常量假 = 硬错（可判定且必错，与 TS01-04/TM03 同族） | 只报不拒（全软） |

---

## 五、任务总表

| 任务 | 内容 | 依赖 |
|---|---|---|
| T0 | 前置侦查（源码零改动）：基准点重取（行号全表）· 语料/探针基线 · `.cir`/`.ccr` 实现方式面实核（含 `ccs` 段表/读回通道）· `fi_ispure` 时序陷阱的红色复现（证明生成期读到乐观值）· EBNF/lexer 的「零规约面」证据固化 | 裁-V1 |
| T1 | 语法面：lexer `#` token + parser 标注链 + `grammar/core.ebnf` 产生式 + 负例（非法标注/位置错/未处理）= 用例 ≥8 | T0 |
| T2 | 检查面：三查（bool/纯/域）+ 时序陷阱处置（纯度读点后移或读 state 链）+ 诊断码分配 + 用例 ≥8 | T1 |
| T3 | VC 生成 + 实现方式：注解表达式编图 + VC 注册表 + dump 通道（`--dump-vcs`）/`.csr` v1（按裁-V2）+ 常量折叠三态 | T2、裁-V2 |
| T4 | 消费/读回 + 检查：读回 dump/`.csr` + 对比（同一 `.cr` 两次编译 VC 清单逐字节同 / 冷热态）+ 突变控制 | T3 |
| T5 | 完成：全量回归 + 统一清单 + 文档（spec-design 阶段节点标记 / TODO `:844` 节结束 / schema 文档勘误）+ 本批 终态与下一步指向（C2/C3/C4） | 全部 |

---

## 六、Global Constraints

- canary 硬性检查（全批）：`clean-cache` 改为 `build tests/suite/ptr_arith.cr --static`，因此 sha256 `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`（28822B）。`#` 标注默认零影响，所以 canary 一律 IDENTICAL；变即停下上报（说明注解泄进发射面）。
- `#` 零运行时语义（设计定稿）· 未证明不拦编译（spec-design 第十二节）· 硬错仅限「可判定且必错」（常量假）。
- 实现方式版本位：`.ccr` v9（`ccr_io.cr:135`）/`CIR_CACHE_VER = 17`（`cir_cache.cr:51`）本批不动；若裁-V2 落 `.csr`，因此新格式独立版本族（`CSR1` + version 1，照 `docs/ir-schema/corespecir-schema.md`），不得挤进 `.ccr` 段表（无裁不得动版本位）。
- 检查以 TODO #2026-09-11-9 为准（结构性断言 + 语义零变化 + 自举稳定，非「与旧版逐字节同」）· 三态纪律 · 新硬错先 report-only 全语料 · 清单三面同核 + `test_backend_bootstrap`（`error[`=0）。
- 工具/纪律：`nice -n 19` · 一构建一编译串行 · cwd = 仓库根 · 比较前 `clean-cache` · `jj` only + 提交路径限定（禁 git）· 自测用例只增不减 · 多 agent 下不并发构建。
- 不得回退既有收纳：TS01-04/TK02/R002/TM03/ICE04/TA02 硬门 · P4/P5/P6 全批（段机制/单槽化/ICE04/影子下线/β 项索引）· 容量批与 fail-closed 批的既有裁决 — 本批一律不动。

## 七、停条件

1. canary 变化，因此停下（注解泄进发射面）；2. 72 档同源对比出现非章程 diff，所以停下（新检查若改变既有语料 rc，因此先 report-only + 裁决）；3. 新增硬错（裁-V6 的常量假）全语料命中非空，所以停下上报；4. 纯度时序：若在生成期读到乐观值而无法在不改既有产物面的前提下解决，因此停下（须先修时序或用 state 链替代）；5. 被迫动 `.ccr` 段表/版本位或 `.cir` 快照，所以停下（单独裁决 + 失效面登记）；6. 被迫引入外部依赖（SMT 库/CIC 内核），因此停下（越出 C1）；7. 主树工作副本不干净或他方在途改动，所以停下（照 P6 事故限制：含「先裁」的任务把限制写进任务卡正文）。

## 八、未决项（不猜；须实证/须裁）

- U-1：spec-design 第八节/第 9.3 节 称 `variant`/`forall`「EBNF 已有」，实读 EBNF 零命中，因此文档与 grammar 不符（`须实证` + 文档勘误）。
- U-2：`.csr` schema（`docs/ir-schema/corespecir-schema.md`）称「真源 = `ccr_io.cr`」，实读 `ccr_io.cr` 零命中，因此声称不成立（文档勘误 + 裁-V2）。
- U-3：`docs/project-book.md:68` 第 3.2 节仍按独立 `.corespec` 文件叙述（含 `.corespecir`），与 ADR-0001（2026-09-06 退役）冲突，因此属于陈旧文档，须校正（否则后续实现会照它做错）。
- U-4：`fi_ispure` / provenance/points-to / region 事实是否入实现方式，本草案实读 = `.ccr` 零命中（不入），因此 C2/第十三节的门控通道须先建实现方式通道（`须实证`：是否存在旁路）。
- U-5：`.cir` 是否有对外序列化（本草案实读 = 只有 DOT + 私有缓存快照），若维护者知道有第三形态，因此更正。
- U-6：CIC 内核选型（Rocq vs Lean 4，spec-design 第十八节 暂停），因此本步不依赖，但 C4 依赖。
- U-7：`where` 值约束三档（TODO `:844`）与 `#check`/`#ensure` 的关系（同族语法还是两套），因此须裁（影响 T1 的语法产生式）。

## 九、自检记录

- 根因 vs 临时修复：本切片不做「先接个 SMT 出绿勾」式的假兑现，C1 明确不判定（唯一判定 = 常量折叠），把「没证明」如实标黄，符合 spec-design 第十二节与仓内三态纪律。
- 诚实边界：本草案未运行任何构建/测试（只读 grep/sed/Read；`ps` 实查；未运行 `jj`，因此无提交基准、行号须 T1 重取）；凡「须实证」一律标注（U-1..U-5）；代价估计为相对量级（小/中/大），非工时承诺。
- 与既有裁决的一致性：ADR-0001（规约并入 `.cr`）· spec-design 第十二节（unproven 不拦）· 第十三节（只有 proven 进优化器）· P4 T5 的「零影响」先例（裁-V4）· TODO #2026-09-11-9 检查标准 · P6 事故限制（含「先裁」入卡）。
- 占位符扫描：无 TBD；六条裁决门逐条给「推荐 + 未取裁时行为」；未决项 7 条全部指向具体文件/行或明确「须实证」。
- 风险面（最大者）：实现方式与消费面未定就动语法，因此整体返工（缓解 = 裁-V2/V3 前置）；纯度时序陷阱（生成期乐观值），所以误判「纯」并把非纯调用放进 VC（缓解 = 停条件4）；`.csr` 格式包袱（第一步背格式 = 重），因此缓解 = dump 先行。
