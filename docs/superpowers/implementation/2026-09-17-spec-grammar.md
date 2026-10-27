# 阶段 6：验证内核管线正式接入：实施记录（T0–T6）

> 对应计划：[plans/2026-09-17-spec-grammar.md](../plans/2026-09-17-spec-grammar.md)
> 说明：以下为原计划文档第 10–17 节，原文移动；章节号与全部数字保持不变。

## 10. T0 实施记录（2026-09-17 实施轮；工作区 `core-veri-ws` @ `feature/spec-grammar`）

> 约定：本节全部数字 = 当场实测（非引用文档）；命令与产物路径逐条给出，可复测运行。

### 10.1 固定基线（本次 pre-side）与构建确定性

| 项 | 实测值 |
|---|---|
| 构建命令 | `nice -n 19 python3 build_selfhost_native.py`（cwd = 工作区根） |
| 耗时 | 25.6s（real；user 12.0s；4 核机） |
| 确定性 ×2 | 两次构建逐字节同：`corec` = `899e3090ad8d6f84787f5cbb245af997269585e045fb9b4d11f054cf194a5036` · `corearch` = `072f2c7ccc243cc2a23fb5a0ad8dd97046bbd38c4f1a0aaafd137b660a1617be` |
| 快速验证 | `./build/corec run 'fn main()->int{return 42;}'`，因此 rc=42 |
| pre-side 存档 | `/tmp/spec-t0/pre/{corec,corearch}` + `SHA256.txt`（= 本次 leg-1 的「pre-阶段」二进制） |
| 起点 revision | `develop = dbadb8d649ba`（未动，因此第 1 节全部 `file:line` 定位点有效，无须重取） |

约定声明：本次 leg-1 的 pre-side = 上表自建二进制（本次起点树、确定性 ×2 已证）。
`tools/baseline/rebuild.sh` 的 pinned `97f4394f`（P6 终态）复现属 E-13 方法自检，与本次判定面无关
（该 pin 之后源已多次变更，因此其产物不代表本次起点），单独运行，结论见第 10.5 节。

### 10.2 RED 实测（取代第 4 节 T0 卡的预测；预测被否证）

探针 `/tmp/spec-t0/red_annot.cr`：

```core
fn f() -> int #check(1 < 0):
    return 1
fn main() -> int:
    return f()
```

| 命令 | 实测结果 |
|---|---|
| `corec check /tmp/spec-t0/red_annot.cr` | rc=1 + `error[TF01]: Function return type mismatch --> 1:1`（误归位点：报在 fn 声明行） |
| `corec build … --static` | rc=0（打印了 `error[TF01]` 却照常产出），因此 ELF `013b43df89fa253d2ce74f6e05b840cdad62fcb99066387e70137428f89a4659`（28822B）+ `.ccr` 均落盘 |
| 运行该 ELF | rc=0（应为 1），因此不报错地误编译（零提示） |
| bootstrap 侧（同源，`Lexer` 直调） | `SyntaxError: <unknown>:1:15: Unexpected character: '#'`，因此响亮拒收 |

根因（实测修正版，三环）：
1. `#` 被词法器不报错地丢弃（`src/compiler/lexer.cr:590-592`），因此 cur token 变 `check`（IDENT）；
2. `parse_body`（`src/compiler/parser.cr:1442-1449`）因 cur token 不等于 `{` 走 `=` 分支：`advance_tok()` 跳过 `check`、`parse_expr()` 把标注的括号表达式 `(1 < 0)` 当成函数体、再 `advance_tok()` 跳过 `{`；
3. 于是 `f` 的体 = `1 < 0`（bool），因此与 `-> int` 冲突，因此 `TF01`；而 `EC_TF_RETURN` 在 build 面豁免表内（`src/compiler/diag.cr:176`），因此 fail-closed `hard=0`，因此产物照出。

因此结论（比原预测严重一级）：今天带标注的源不是「不支持」，是不报错地误编译成 rc=0 的错产物，
正是本仓最要消灭的形态。T2 的负控必须覆盖此条（`#` 成 token 后，该路径必变语法错或正确解析，二者皆可判）。

### 10.3 起点检查（canary + 检查项1；检查项2/3 见第 10.4 节）

| 检查 | 命令 | 实测 |
|---|---|---|
| canary 五条 | `nice -n 19 bash tools/baseline/canary_check.sh` | PASS 5/5：ELF `95084e7b…d475`（28822B）· `pa_ccr 680a6f98…`（96015）· `pa_static_ccr 76f36e6a…`（96158）· `gt_ccr d92a2727…`（142765）· `gt_static_ccr a1f7b99c…`（142908） |
| 检查项1 74 档 | `bash tools/baseline/parity_run.sh /tmp/spec-t0/pre/corec /tmp/spec-t0/parity_pre` | PARITY DONE（74 档）· rc 分布 35×0 / 39×1（基线日志 `/tmp/spec-t0/parity_pre/logs/`） |

39×1 的构成（本次实测，取代 `REBUILD.md:126` 的「38」旧账）：
空 fixture ×2（`tests/suite/test_control_flow.cr` / `test_generics.cr`，实测日志 = `error: cannot read`）·
P21 嵌套 fn ×3（`at_test_mini{,.4,.6}.cr`；旧账记 2）· examples 解析错 ×2 · 库单元单独 check ×25
（t1 `apx_conversion_test` 1 + t2 `_import.cr` 1 + t3 13 + t4 10）· TF01 并发族 ×5 · TF07 ×1（`ptr_ref_first`）·
B04 ×2（`ptr_arith` = canary 实现方式本人 + `apx_conversion_test`）= 39。
诊断码直方图（全部 rc=1 档）：`N06 ×1889 · N01 ×1426 · TA01 ×202 · N11 ×71 · TF01 ×18 · TB01 ×10 · TF07 ×2 · P21 ×2 · B04 ×2`
（N 族占绝对多数 = 库单元单独 check 的 concat 语境缺失，属既有语义）。
因此 T6 修 `REBUILD.md:126` 时须用本节的实测构成（不得沿用 38 的旧账）。

### 10.4 检查项2（探针 29 档）与检查项3（有缓存状态）

| 检查 | 命令 | 实测 |
|---|---|---|
| 检查项2 29 档 | `bash tools/baseline/probes_run.sh /tmp/spec-t0/pre/corec /tmp/spec-t0/probes_pre` | rc 分布 17×0 / 12×1（rc=1 多为预期负例；检查 = 两态零差异） |
| 检查项2 附带的有缓存状态广度层 | 同上（runner 默认） | 29 档 · 有缓存状态生效（≥1 真命中）档数 = 15 · FAIL=0 |
| 检查项3 有效性层 | `bash tools/baseline/warm_run.sh /tmp/spec-t0/pre/corec /tmp/spec-t0/warm_pre` | 7 档 · 有缓存状态生效档数 = 7 · FAIL=0 |

注意：未竟项（登记，会报错；已补对照实验，2026-09-17 T1 轮）：检查项3 广度层（`parity_run.sh` 附带的 74 档有缓存状态第二次运行）未运行完，
卡在 `corec ccr src/compiler/main.cr` 的有缓存状态第第二次运行（`-o o2.ccr`）：首观测 `State: D (disk sleep)` ·
`rchar = 760,556,173`（760MB）· `.core/cache/cir/` = 1.4GB / 1011 条目 · 单次调用 elapsed 9:52 且 >8min 零进展。
对照实验（维护者要求的先决条件，已按1无并发2清缓存3记墙钟执行）：
- 1 无并发：开运行前 `pgrep -a corec` / `pgrep -a corearch` 为空（仅本实验进程）；
- 2 清缓存后开运行（`.core/cache/cir` 0 到空缓存状态运行重建）；
- 3 墙钟：WALL = 901s，rc = 124（`timeout 900` 硬超时截断），日志停在 35/74，同一 `-o o2.ccr` 调用 elapsed >13 min、`State: D`、`rchar ≈ 44MB`、RSS ≈ 219MB、`%CPU 1–3%`。
因此结论（实测，可证伪）：不是并发单因（对照已排除）；对照 `REBUILD.md:78-79` 的「parity 广度层 +125s」差 ≥7× 且未运行完
因此属既有性能问题（本次零源码改动，且已在干净窗口复现）。

机制（维护者读码定位 + 本代理复核 file:line）：`src/compiler/cir_cache.cr` 的每条函数快照携带单元级表，`:226` 全图边数进尺寸、`:228-234` 整个单元级字符串常量表进每条快照、`:310-313` 注释原文「they're few compared to nodes」+ 写 `g_df_edge_count`（全图）条边，因此缓存总量 = O(函数数 × 单元级表) = 二次膨胀。

因果对照实验（本代理复测运行，维护者设计要求：无并发 / 清缓存 / 冷暖双记）：

| 语料 | 空缓存状态运行墙钟 | 运行后 cache | 有缓存状态运行墙钟 |
|---|---|---|---|
| `tests/suite/ptr_arith.cr`（小） | 1s | 15 条 / 352K | 0s |
| `src/compiler/main.cr`（约千函数单元） | 231s | 1011 条 / 1.4G | >254s 未完成，因此看门狗检查命中杀（CPU 1.9% · `State: D` · rchar 169MB） |

因此测到的关联（不是已证因果）：小缓存档有缓存状态运行 0s、大缓存档 >254s 未完成，但两档语料不同（未控制「同文件 × 不同缓存规模」），因此不得据此断言「缓存体积，因此有缓存状态运行墙钟」。

注意：环境未控（须与上表同读）：测量时段机器实测（2026-09-17 09:07，同量级），交换 12127MB / 已用 5985MB · `loadavg 16.47/15.92/16.72`（4 核）· `vmstat b=16 · si=184 · wa=40%` · 常驻大户 = 4 个多日前起的 `bun` 进程（RSS ≈ 2.4GB），因此系统级 I/O 饱和 + swap 抖动；「无并发 + 清缓存」只对本代理进程成立，系统级不成立，因此墙钟只能读作「在既有机器负载下，有缓存状态第二次运行 ≥7× 于 `REBUILD.md:78-79` 的 +125s」。

注意：与机制的关系（不得混为一谈；维护者更正 + 本对照证伪）：「快照二次膨胀」= 已定位机制；「阻塞点」= 现象。对照证伪了「阻塞点由读体积解释」，阻塞点进程 `rchar` 仅 44MB / 169MB，缓存却 1.4GB，因此阻塞点直接原因未知，两条不是同一条因果链的已证结论（完全归因 = `plan-cachebloat` 只读侦查；本条不重新运行）。

因此立 `TODO #2026-09-17-6`（该条目 = 上述机制 + 实测四条 + 本表 + 一行推测方向；
不做根因定位，维护者指示）。处理：杀进程 + 清缓存；该层明确按「未运行通过」登记
（`REBUILD.md` 应补「广度层不覆盖大文件」约定；不得把它写成「已运行通过」）。检查项3 有效性层（7 档）与检查项2 广度层（29 档）不受影响，均实测通过。

### 10.5 E-13 固定基线方法自检（pinned `97f4394f`）

`nice -n 19 bash tools/baseline/rebuild.sh /tmp/spec-t0/pinned-baseline`，因此 rc=0，三 sha 与允许清单逐条命中
（`corec ae01de75…` · `corearch 228f82e9…` · `corelsp 90eb19c6…`）+ 快速验证 rc=42 + `error[` 行数 = 3（守卫通过）。
因此 E-13 方法完好（与 `REBUILD.md` 现行代一致）。注：该产物 = P6 终态源，不代表本次起点
（pin 之后源已多次变更），因此本次 leg-1 的 pre-side 一律用第 10.1 节的自建二进制。

### 10.6 T0 检查汇总（一处看全）

| # | 检查 | 状态 |
|---|---|---|
| 1 | 工作区 + bookmark | `core-veri-ws` @ `feature/spec-grammar` |
| 2 | 构建确定性 ×2 + 快速验证 42 | 第 10.1 节 |
| 3 | 六门 + 十二门写进文档 | 第 3.1 节 / 第 3.2.1 节（提交 `05667d03`） |
| 4 | 定位点重取（revision 未动） | 第 10.1 节 |
| 5 | RED 实测 | 第 10.2 节（预测被否证，实测更严重） |
| 6 | canary 五条 | 5/5 |
| 7 | 检查项1 74 档 | 35×0 / 39×1（基线落盘） |
| 8 | 检查项2 29 档 | 17×0 / 12×1（+ 有缓存状态生效 15 · FAIL=0） |
| 9 | 检查项3 有效性层 7 档 | 有缓存状态生效 7 · FAIL=0 |
| 10 | 检查项3 广度层（74 档有缓存状态） | 注意：未竟（对照实验后定性：既有性能问题，非并发单因），`TODO #2026-09-17-6`（第 10.4 节附三条实测事实；不写成通过） |
| 11 | E-13 pinned 方法自检 | 三 sha + 快速验证 42 |

---

## 11. T1 实施记录（词法面 `#` token；2026-09-17）

改动面（提交 `1b5a8799` + `a4df9c75`）：`src/compiler/ast.cr`（`T_HASH = 101`）· `src/compiler/lexer.cr`（单字符分支）· `bootstrap/corec/{syntax/tokens.py, frontend/lexer.py, frontend/parser.py}`（裁-S7 bounded：接受并跳过）。

| 检查 | 实测 |
|---|---|
| 1 常量静态断言 | `T_` 常量 89 改为 90；新增仅 `T_HASH: 101`；既有 0..100 零改动（`jj file show -r <pre>` 逐条比对）；101 不与既有值相撞 |
| 2 全仓裸 `#` 扫描 | 182 档 · 0 命中（构造性零影响；与 T0 同一标准同脚本） |
| 3 非 `.cr` 的 `#` 面不变 | `test_hit_table.py` 24/24（HIT 表 `#` 注释面）· `test_so_index_repro.py` 8/8（`.so` 索引 `#` 行面） |
| 4 两前端一致性 | 注意：部分（下详）：bootstrap 侧 · corec 侧 = 响亮拒绝（T1 单独作用；「两侧 rc=0」须待 T2） |
| 附：canary 五条 | 5/5 IDENTICAL（`95084e7b…d475` / `680a6f98…` / `76f36e6a…` / `d92a2727…` / `a1f7b99c…`） |
| 附：检查项1 74 档 | pre `35×0/39×1` ≡ post `35×0/39×1`，`diff -rq logs` = 零差异（`WARM_LEG=0` 运行冷面） |
| 附：检查项2 29 档 | `diff -rq` = 零差异 |
| 附：快速验证 | rc=42（新二进制 `corec = 8ffb3511…`） |

检查4 的实测与约定修正（须维护者知悉）：
- bootstrap 侧：`#check(1 < 0)` 语料走完整前端（lex 改为 parse到resolve 改为 desugar到check 改为 ir_gen到asm）rc=0，且 asm 与无注解版逐字节同（`sha256 ff86d802…`）；修复前 = `SyntaxError: Unexpected character: '#'`（T0 实测）。
- corec 侧（T1 单独作用）= 响亮拒绝：`error[N06]: Undefined function 'check'` @ 2:11（正确定位到标注）· rc=1 · 零产物。因此相对 T0 的不报错地误编译（rc=0 + 运行返回错值）是严格改进；但「两侧都 rc=0」在 T1 单独作用下不可能成立，corec 的 `#` 消费者 = T2 的 parser 标注链。
- 约定修正（结构性，且不可回避；维护者 2026-09-17 已准并定为本次检查）：「两侧产物逐字节同」不可构造，两前端的后端不同（bootstrap = Python `X86_64StackAsmGen` + `as`/`ld`；corec = 自研 ELF 发射器），无共同产物面，因此本条按可构造的最强形实现：（a） 两侧都接受（rc=0） + （b） 各自零影响（bootstrap：asm ±注解逐字节同，已通过；corec：±注解 ELF/`.ccr` 逐字节同 = 裁-S12 强式，T2 后验）。

顺带实核（已立 TODO）：bootstrap `KEYWORDS` 残留 `requires`/`ensures`/`result`（self-hosted 无），因此 `TODO #2026-09-17-8`。

T1 的另一实测收获（登记为 TODO）：TF01 的豁免洞（误报 × 豁免 = 不报错地错产物），触发器已被 T1 消灭，洞本身未动，因此 `TODO #2026-09-17-7`。

### 11.1 注意：T1 结论的重要限定：本节的「响亮拒绝」是条件性的（2026-09-17 实测；维护者验收项2）

上文「corec 侧 = 响亮拒绝」只在注解名恰好未定义时成立。实测（`/tmp/spec-t1/collide.cr`）：

```core
fn check(x: bool) -> bool:
    return x
// ← 注解名遇到一个真实函数
fn f() -> int #check(1 < 0):
    return 1
fn main() -> int:
    return f()
```

| 命令 | 实测 |
|---|---|
| `corec check` | rc=1 + `error[TF01]`（误归 2:1） |
| `corec build --static` | rc=0 + 产物落盘（28922B到实测 28822B）· 打印了 `error[TF01]` 却照常发射，因此运行 rc=0（应 1） |

因此不报错地误编译在本形态下依旧存在（T1 未消灭它，只消灭了「名字不存在」那一支）。根因同 T0：`parse_body` 的 `=` 分支把 `#check(1<0)` 解析成对 `check` 的调用当函数体，而 TF01 在 build 面豁免（`TODO #2026-09-17-7`）。
因此 T2 的硬验收（不可省）：`#` 被 parser 消费后，注解再也进不了 body，因此本形态必须 rc=1 + 零产物（不再依赖「名字不存在」）。

---

## 12. T2 实施记录（语法面：标注链 + 常量失败规则；2026-09-17）

改动面（7 文件）：`src/compiler/ast.cr`（`EC_V_*` 17xxx 家族：V01 常量假 / V02 未知标签 / V03 形态错）· `src/compiler/diag.cr`（`error_cat_prefix` 加 `cat == 17 则 "V"`）· `src/compiler/globals.cr`（规约标注侧表 `g_spec_{fn,kind,expr,line,col,count,cap}` + 会话复位）· `src/compiler/dyn_arr.cr`（`grow_spec_side` / `spec_add` / 5 个受护读访问器）· `src/compiler/parser.cr`（`parse_spec_annotations` + `parse_body` 调用点 + 顶层后备对 `#` 转响亮）· `src/compiler/checker.cr`（`spec_fold_val` 常量折叠 + `spec_check_all`，挂 `check_all()` 尾）· `grammar/core.ebnf`（`FunctionDecl`/`FlowDecl` 加 `{ Annotation }` + `Annotation` 产生式）· `docs/developer/errors.md`（V0xx 节）。

检查实测（13/13 + 2 手工）：

| 类 | 用例 | 实测 |
|---|---|---|
| 正控 ×4 | 无注解 / `#check` / 多条（`#check`×2 + `#ensure`）/ 注解链重复 | rc=0 + 产物（重复 = 合法，见下「待裁」） |
| 负控 ×9 | `#` 后非 IDENT · 未知标签 · 缺 `(` · 未闭合 `)` · 空 `#check()` · 签名前位置 · body 后位置 · 常量假 · 撞名形态 | 全部 rc=1 + `error[V01/V02/V03]` + 零产物 |
| 手工 ×2 | body 内 `#`（同语句行 / 独立行） | rc=1（parse 层 `error:` 文本）+ 零产物 |

三条硬验收：
1. 两侧都接受：corec （正控 rc=0）· bootstrap （`pos_check.cr` 全链 rc=0 且 asm `ff86d802…` 与无注解版逐字节同）。
   ±注解产物面（裁-S12，实测后第二处约定修正，须维护者准）：
   - ELF：逐字节同 （`m_plain.cr` vs `m_annot.cr`（注解插在同一行），因此同一 sha `cae8d50d…`；即使行数不同（多行注解形态）ELF 亦同）。
   - `.ccr`：7/8 段逐字节同；唯一差异 = STR 段，且 Δ = 注解独有词素的驻留量。实测两例：`#check(1 > 0)`，因此 +9 B（= 4B 长度前缀 + `check`(5)）；`#check(true)`，因此 +8 B（= 4 + `true`(4)）。机制：`lexer.cr:318` `add_tok_str` 对每个 IDENT/关键字词素调 `str_intern`（既有行为，非本次引入），因此只出现在注解里的标识符/关键字会进 STR。
   因此可构造的最强形（本次检查）= （a） ELF 逐字节同 + （b） `.ccr` 除 STR 外逐段同 + STR Δ 恰为可算值；逐字节全同不可达（除非注解里的词素在程序别处已驻留）。检查不缩水：差异必须恰好等于该量，多一个字节即失败。
2. 撞名形态必堵：`fn check(x: bool) -> bool` 存在时 `#check(1 < 0)`，因此 rc=1 + `error[V01]` + 零产物（T1 的漏洞已闭合；不再依赖「名字不存在」）。
3. 负例 ≥8：实测 9 条（含维护者点名的 6 类：签名外位置 / 重名冲突 （撞名形态）/ `#ensure` 先于 `#check`（= 反序链，见「待裁」）/ 空 `#check()` / 非布尔（T3）/ 注解链重复）。

顺带修掉的雷（T2 首轮实测发现）：`parse_declaration` 的顶层后备 = `advance_tok()` 不报错地吞一个 token、不报错，因此 `#check(1>0) fn f()…`（签名前）与 `…} #check(1>0)`（body 后）rc=0 + 产物照出（首轮 2 例 FAIL）。已在该点对 `#` 转响亮（`EC_V_BAD_TAG` + 定位）。其余 token 的不报错地吞仍在，因此候选 TODO（见 `TODO #2026-09-17-9`）。

回归检查：canary 5/5 PASS · 检查项2 29 档零差异 · J 检查 4/4 · 检查项1 74 档 rc 分布不变（35×0/39×1）且两档日志差异经机械归因 = 纯行号平移（`_import.cr` 4 行 · `ccr_io.cr` 156 行，全为 `--> 行:列` 与源码回显形态；剥行号后逐字节同，根因 = 本次给编译器源加了 193 行，而对比语料含编译器自身源），因此判定面行为零变更，属预期内差异（入清单）。

未做（转 T3/T4）：bool 型检查 · 名字域（`result` 绑定、`#check` 无 `result`）· `#ensure` 的常量失败 · VC 记录与 `--dump-vcs`。

待裁（T2 暴露的两处语义问题）：1 注解链重复（同一标签重复）本次判合法（设计稿未禁止；判「可判定且必错」不成立），维护者若要求禁止，需另立语义（当前按合法实现）；2 `#check` 与 `#ensure` 的顺序本次不约束（两者语义独立，先 `#ensure` 后 `#check` 亦可）。

---

## 13. T3 实施记录（检查面：bool 型 + 名字域 + 调用禁用 + `#ensure` 常量失败；2026-09-17）

改动面：`src/compiler/checker.cr`（`spec_check_func`：每函数标注检查，挂 `check_func` 尾部（形参仍在域内）；
`spec_has_call`：C1 子集禁调用扫描；`spec_check_all` 常量失败扩到 `#ensure`）· `src/compiler/dyn_arr.cr` + `globals.cr`
（侧表加 `g_spec_fnode` 列 = EXPR_FN 节点索引，唯一键，按函数名会串台（同名方法/多 impl））·
`src/compiler/parser.cr`（`spec_start` 记录 + `alloc_node` 后回填 fn_node）· `src/compiler/ast.cr`（V04/V05/V06）·
`docs/developer/errors.md`（V0xx 三行）。

检查（T3 电池 11/11 + Δ 2/2）：

| 类 | 用例 | 实测 |
|---|---|---|
| 正控 ×4 | `#check(a >= 0)` · `#ensure(result >= 0)` · `#check(a>=0) #ensure(result>a)` · `#ensure(1 > 0)` | rc=0 + 产物 |
| 负控 ×7 | 非 bool（`#check(1)`）· `#ensure(result)` · `#ensure` 常量假 · `result` 撞形参 · 域外名 · 表达式含调用 · 重复链含假 | rc=1 + 零产物：V05 · V05 · V01 · V04 · N01（`infer_expr` 既有诊断，build 面非豁免，因此阻断）· V06 · V01 |

`.ccr` 零影响检查（裁-S12 三段式；维护者三条要求全部落实）：
1. ELF 逐字节同；2. 除 STR 外 7 段逐字节同；3. STR Δ 恰为公式值（`Δ = Σ(4+len(m))`，`m` = 注解独有词素）：
   `#check(1 > 0)`（`check` 未在他处出现），因此 Δ=9（4+5）；零 Δ 用例（注解词素已在程序别处驻留），因此 Δ=0 通过。
   机制注（写进 `delta_check.py` 头注 + 本节）：`src/compiler/lexer.cr` 的 `add_tok_str` 对每个 IDENT/关键字词素调
   `str_intern`，既有行为、非本次引入；只出现在注解里的词素必然进 STR。

注意：检查当场抓到本次自己的泄漏（T3 首轮）：`spec_check_func` 里 `str_intern("result")` 写成无条件调用
因此两个用例的 STR Δ 各凭空 +10B（d0 期望 0、实测 10；d9 期望 9、实测 19）。根因 = 未注解的函数也驻留了该串。
修法 = 把 `str_intern("result")` 移进「确需绑定」分支，因此 Δ 双双命中期望值。这正是「零 Δ 用例必须通过」这条要求的价值，
没有它，一条纯编译期的实现细节会永久污染 `.ccr` 产物而无人察觉。

回归检查（新基 = `c1546f9b`；pre 侧 = 该基自建，见下「重定位点」）：canary 5/5 · 检查项1 75 档零差异 ·
检查项2 零差异 · T2 电池回归 13/13 · J 检查 5/5（未受 T3 影响）。

方法论点（本轮新增，须继承）：rebase 之后必须重定位点 pre 侧。检查的 pre 侧必须与新基同源，否则检查项1 的差异里
会混进它阶段的整阶段判定面变更，本次的「零影响」就无法证明。本轮第二次 rebase 到 `c1546f9b` 后，
按维护者裁定重建了 T0 起点二进制（`/tmp/spec-t3/pre/corec`，sha `19155c4c…`，`jj workspace add -r c1546f9b` + `nice -n 19` 构建 + 快速验证 42），
两条检查在新定位点上零差异。（同教训的另一处实例：缓存阶段 rebase 后 `jj diff` 显示其树少了阶段 5 report 的 24 行，develop 一前进，比较基就失效。）

未做（转 T4）：VC 记录结构 + `--dump-vcs` 通道（三态输出：green/yellow/red）。

---

## 14. T4 实施记录（VC 清单 + `--dump-vcs` 通道；2026-09-17）

改动面：`src/compiler/globals.cr` + `dyn_arr.cr`（侧表加 `g_spec_status` 状态列；`spec_set_status` red 粘性，
已判失败不被后续 green 覆盖，否则「有硬错」会被「常量真」抹掉）· `src/compiler/ast.cr`（`SPEC_ST_{YELLOW,GREEN,RED}`）·
`src/compiler/checker.cr`（4 处状态写入：折叠真，因此 green / 折叠假，因此 red / V04·V05·V06，因此 red）·
`src/compiler/dump.cr`（`spec_expr_text` 规范化文本 + `vcs_dump`）· `src/compiler/main.cr`（注册 `--dump-vcs` +
打印点 = `run_frontend` 的 fail-closed 检查之前）。

 样例输出（三态一屏；`check` 面，无 `--static`，因此行号即源码行）：

```
[vcs] count=3
[vcs] vc 0 fn=f kind=check status=green line=2 col=5 expr=(1 > 0)
[vcs] vc 1 fn=f kind=check status=yellow line=3 col=5 expr=(a >= 0)
[vcs] vc 2 fn=f kind=check status=red line=4 col=5 expr=(1 < 0)
error[V01]: #check(...) is statically false
```

 样例输出（跨 impl 同名方法，侧表键 `g_spec_fnode` 的检查）：

```
[vcs] count=2
[vcs] vc 0 fn=A.get kind=check status=yellow line=4 col=37 expr=(alpha >= 0)
[vcs] vc 1 fn=B.get kind=check status=yellow line=7 col=36 expr=(beta >= 0)
```

检查（T4 电池 16 项全部通过）：

| # | 检查 | 实测 |
|---|---|---|
| 1 | 三态齐全 + 失败也列（会报错省略）+ 失败，因此诊断通道 rc=1 | （green/yellow/red 同屏 + `error[V01]`） |
| 2 | 失败的 line/col 与诊断自洽 | dump `19:5` ≡ 诊断 `--> 19:5`（`--static` 形态） |
| 3 | 源序确定（两次 dump 逐字节同） | |
| 4 | 开关不改产物（有/无 `--dump-vcs`，因此 ELF 与 `.ccr` sha 同） | （黄态语料；失败状态无产物，检查标准另定） |
| 5 | 空缓存/有缓存 dump 逐字节同 | |
| 6 | 五分支可用（`check`/`ccr`/`cir`/`run`/`build` 均经 `run_frontend`） | |
| 7 | 侧表键防串台：两个 impl 的同名方法各带不同注解，因此各自独立、rc=0（无伪 N01） | （`A.get`/`B.get` 分列，参数各为 `alpha`/`beta`） |

四点固定的落实：1 stdout、零新产物、开关不改 rc/产物 · 2 三态分流（失败走诊断 / 通过黄进 dump） ·
3 失败也列（打印点在检查之前，因此失败状态照样列出；「没列出来」与「列出来是失败的」可区分） ·
4 只读侧表（`vcs_dump` 直接读 `g_spec_*`，不另起状态，因此无第二处定义）。

回归检查：canary 5/5 · 检查项2 零差异 · T2 电池 13/13 · T3 电池 11/11 · Δ 检查 2/2 · J 检查 5/5 ·
检查项1（75 档）：rc 分布不变，两档日志差异经机械归因 = 纯行号平移（`_import.cr` 4 行 · `ccr_io.cr` 156 行，
全为 `--> L:C` 与源码回显形态；剥行号后逐字节同；两档 rc 逐档相同），根因 = 阶段 6 给编译器源累计加了行，
而对比语料含编译器自身源；属预期内差异（同 T2 的归因，见第 12 节）。

顺带实核（登记，非本次）：`src/compiler/dump.cr` 的 `cmd_cir`（`:429`）全仓零调用者（不可达代码，同 `elf.cr`/`linker.cr` 家族）；
本次未动（不扩面）。

未做（转 T5/T6）：检查入仓（`tests/spec/` 语料 + `tests/selfhost/test_spec_grammar.py` + `run.sh` 接入点 + 覆盖率检查）·
文档面（`syntax.md` / `spec-design.md` 示例 / `REBUILD.md` 计数勘误）· 全量回归与清单。

---

## 15. T5 实施记录（检查入仓：语料 + 套件 + 接入点；2026-09-17）

交付物三件：

| # | 路径 | 内容 |
|---|---|---|
| 1 | `tests/spec/`（33 档 .cr + README.md） | 四组语料：`t2_*` 语法面 15 · `t3_*` 检查面 11 · `t4_*` dump 通道 3 · `delta_*` 零影响对比 4（两对，成对使用不可拆）。独立目录：不进检查项1（parity 75 档）与检查项2（probes 29 档），两条检查计数不变 = 旧面零扰动的证据 |
| 2 | `tests/selfhost/test_spec_grammar.py`（48 项） | A 语法面 16 · B 检查面 11 · C dump 通道 15（含失败也列/自洽/源序/开关不改产物/冷热同/五分支/防串台）· D `.ccr` 零影响三段式 6（含 Δ 公式与零 Δ 用例） |
| 3 | `src/ci/run.sh`（`selfhost-tests` job 尾） | 接入点 + 行内注释（四组构成 + Δ 公式价值 + 语料位置 + 实测时长） |

维护者三条要求：
1. 独立可运行：`BASE = Path(__file__).resolve().parents[2]`（不依赖调用者 cwd）· 所有产物落 `tempfile` 并在 `finally` 清理 ·
   唯一外部依赖 = 「`cwd` 必须是仓库根」，这是既有依赖（`--static` 要读 `src/runtime/rt.cr`，`main.cr:112-122` 只按 cwd/exe 相对找），
   套件内部对每条 `corec` 调用都显式传 `cwd=BASE`，因此对调用者无要求。
2. 时长写进注释：1.8s（本机，2026-09-17，含 swap 抖动；CI 关键路径无影响）。
3. Δ 公式入仓：`delta_case()` 把公式算在检查里（`4 + len("check")` 与 `0` 两种期望值），
   机制注（`add_tok_str` 的 `str_intern` 是既有行为）+ 「多一字节即失败」+ 「零 Δ 用例必须通过」全部写进
   套件头注与 `tests/spec/README.md`。

接入点三件套自证：`python3 tests/harness/test_ci_hook_coverage.py`，因此 PASS（`scope=73 · hooked=52 · unhooked(allowlisted)=21`），
新套件已挂故不进允许清单。

五 CI job 面：本套件挂 `selfhost-tests`（需已构建编译器）；不进 `suite`（该 job 只运行 `tests/suite/*.cr` 正例）
与 `full-bootstrap`（自举链），不改任何 job 的语料计数。`check` job 运行 `corec check src/compiler`，本次给编译器源加的行会进该语料，
但零诊断增量（T5 本轮实测：J 5/5 + 构建 rc=0 + 快速验证 42；`check src/compiler` 的增量判定见 T6 全量回归）。

顺带登记：`TODO #2026-09-17-12`（`dump.cr::cmd_cir` 零调用者 = 不可达代码，与 `elf.cr`/`linker.cr` 同族；不与 `#2026-09-10-3` 重复）。

未做（转 T6）：五 job 全量回归 + 自举链（`corec2==corec3` + N06=0 + 快速验证 42）· 文档面（`syntax.md` / `spec-design.md` 示例 /
`REBUILD.md` 计数勘误「72/73 改为 75」）· 统一清单 · TODO 完成。

---

## 16. T6 结束：五 CI job 全量回归 + 清单 + 文档勘误（2026-09-17）

基：`develop bf346a31`（阶段 6 链 rebase 后 · 0 冲突）；pre 侧沿用 `/tmp/spec-t3/pre/corec`（sha `19155c4c…`），
引证豁免：`jj diff --from c1546f9b --to develop --stat` 此后仅动 4 个文档文件（TODO/计划/报告），零 `src/` 下的全部文件，因此语料面未变（第 13 节方法论照用）。

### 16.1 五 job（本轮实测；`CI_JOB_NAME=<job> bash src/ci/run.sh`，逐 job 串行、`nice -n 19`）

| job | rc | WALL | 关键读数 |
|---|---|---|---|
| `check` | 0 | 44s | `corec check src/compiler`，因此 0 条 `error[`、V 家族 0 命中（「自源即语料」陷阱自查） |
| `bootstrap-tests` | 0 | 125s | J 检查 5/5（含 M-a/M-b/M-c 三突变）+ `test_ci_hook_coverage` PASS（scope 73/hooked 52） |
| `selfhost-tests` | 0 | 170s | 含新套件 48/48 · `test_ccr_types` 49/49 · `so_index_repro` 8/8 … |
| `suite` | 0 | 27s | `ALL PASS` |
| `full-bootstrap` | 0 | 685s | 三阶段链 `cmp corec2 corec3` 成功（不报错地）+ 两处守卫 `error[ = 0, undefined = 0`（= N06=0）+ `corec3 --help` 正常 |

注意：两次「假失败」的归因（过程错误，非代码回归；如实入清单）：
1. 首轮 `full-bootstrap` rc=2 + `run.sh:244 未预期的记号 ";;"`，因此根因 = 本次在该 job 运行期间编辑了 `src/ci/run.sh`（bash 读到半改文件）；
2. 同时段 `test_ccr_types` 出现 2–3 例失败（含 0 字节 `.cir` 读到一半），因此根因 = 同一 job 残留的 `corec2` 进程与本次的复测运行共用 `.core/cache/cir`（本次违反了「同工作区禁并发构建」）。
判定依据：干净 develop 检出（`jj workspace add -r develop`）上 `test_ccr_types` 49/49 ×3 稳定通过；清理后本支单运行亦 49/49；
两 job 在不编辑任何文件的重新运行中全部通过，因此非本次代码回归。

### 16.2 文档勘误（先实测再改；写清「怎么数出来的」）

| 面 | 旧值 | 实测值 + 数法 |
|---|---|---|
| 检查项1 语料 | `REBUILD.md:6/74/79/126` 与 `run.sh:106` 写「72 档/73 档」 | 75 档 = `tests/suite/*.cr` 35 + `src/compiler/{main,_import}.cr` 2 + 后端/内核单元 15 + `src/stdlib/*.cr` 19 + `examples/*.cr` 4（逐层枚举，与 `parity_run.sh:31` 的 `CORPUS_TOTAL=75` 硬断言一致）；rc 分布 36×0 / 39×1（构成 = 空 fixture ×2 · P21 ×3 · examples ×2 · 库单元 ×25 · TF01 并发 ×5 · TF07 ×1 · B04 ×2） |
| `parity_run.sh:31` 分层注释 | 算术和 = 74（t1 记 34） | t1 = 35（R2 P6 T0 记 32，其后 global_seam/apx/阶段 5 三次 +1），因此注释改为逐层实数 + 注明「档数变化必须同阶段改本行与本注释」 |
| `ci_hook_allowlist.txt` 头注 | scope 66 / hooked 45 | scope 73 / hooked 52 / allowlisted 21（阶段 6 +1 接入点） |

### 16.3 本次清单（一处看全）

| T | 交付 | 主要检查 |
|---|---|---|
| T0 | 起点基线 + RED 实测 | 构建确定性 ×2 · canary 5/5 · 检查项1 74 档 · 检查项2 29 档 · RED = 不报错地误编译（build rc=0 + 运行返回错值） |
| T1 | 词法 `T_HASH=101` + bootstrap 最小一致 | 常量静态断言 · 全仓裸 `#` 扫描 182 档 0 命中 · 非 `.cr` 面 24/24+8/8 · 两条检查零差异 |
| T2 | 语法面（标注链 + 侧表 + EBNF + V 家族） | 13/13 · 撞名漏洞闭合（rc=1+V01+零产物）· 零影响（ELF 同 + STR Δ 公式） |
| T3 | 检查面（bool/域/禁调用/常量失败） | 11/11 · Δ 2/2（检查当场抓到实现自身的 `str_intern` 泄漏） |
| T4 | VC 清单 + `--dump-vcs` | 16/16（失败也列 / 只读侧表 / 五分支 / 防串台） |
| T5 | 检查入仓 | 套件 48/48 · 1.8s · 接入点自证 PASS |
| T6 | 五 job + 勘误 + 清单 | 五 job 全 rc=0 · 文档勘误先实测 |

本次登记条目：`#2026-09-17-8`（快照二次膨胀）· `#9`（TF01 豁免对）· `#10`（bootstrap 关键字残留）· `#11`（顶层吞 token）· `#12`（`cmd_cir` 不可达代码）。
TODO 完成：`#2026-09-16-5`（验证切片轮立项）状态由「立项/草案」改为「已实施（阶段 6）」（含实施面 + 检查 + 下一组指向）。

约定修正共两处（均经维护者准）：1 「两侧产物逐字节同」不可构造，因此改「两侧都接受 + 各自零影响」；
2 `.ccr` 逐字节同不可达（注解词素必然进 STR），因此改「ELF 同 + 除 STR 外逐段同 + STR Δ 恰为公式值（多一字节即失败）」。

### 16.4 注意：历史收敛登记（T3/T4 的 src 变更位置；审阅者必读）

T5/T6 两次 rebase 的 `TODO.md` 冲突消解过程中，T3/T4 的 `src` 改动被从原提交剥出、落入工作副本
（链上逐提交查 `vcs_dump` 命中 = 0）；已在 T6 提交 `773b1042` 收敛，最终树 = 本轮全部检查实测过的状态
（提交后复验：build · 快速验证 42 · 套件 48/48 · canary 5/5 · J 5/5）；
`jj diff --from develop --to feature/spec-grammar` = 55 文件 +1732/−16，含全部 src。

- 性质：位置问题、非内容丢失（合并为 squash，因此最终树不变）。
- 机制（可复现）：`jj edit <中间提交>` + 重写工作副本文件（用于消解 7 个 TODO.md 冲突）会把该提交的后续改动
  一并卷进工作副本；反复 `edit`/写/`rebase` 后，某些提交的实际内容与提交信息不再一一对应。
- 教训（方法论）：大文件冲突消解不要用「逐提交 edit + 重写」，优先「一次收敛到一个提交」（本轮 T5/T6 已按此做）。

### 16.4.1 注意：通用陷阱（本次最有价值的过程产物）：检查运行在工作副本上，断言必须落在提交上

第二个实例（2026-09-17，rebase #101 后）：按「一次收敛」把合成的 `TODO.md` 写进 `T6 结束` 提交后，本地 J 检查 5/5
但检查读的是工作副本；随后的一次 `jj edit`/bookmark 操作把合成内容从尖端提交里带走（尖端 `TODO.md` 只剩 develop 的 10 条）。
抓到它的是 CI：`bootstrap-tests` 到 J2 悬空 = 10（`TODO.md` 与 `REBUILD.md`/计划多处引用 `#2026-09-17-8..12` 而无对应标题），因为 CI 读的是推送出去的提交。

因此复核点修正（覆盖上一条的「逐提交」说法）：

| | 正确做法 |
|---|---|
| 复核对象 | 最终提交：`jj file show -r @ <file>` / `-r <bookmark>`（不是 `cat <file>`） |
| 复核范围 | 最终提交（不是逐中间提交，本次丢的正是尖端，逐提交查法没抓到） |
| 最终裁定 | 推送后以 CI 检查为准（CI 读提交，是唯一能证明「内容在提交里」的机械检查） |

一句话：「本地检查通过」≠「内容在提交里」，本地检查证明的是工作副本的性质，而提交才是被审阅与被合并的对象。

同族（三条一体）：1 第 13 节「rebase 之后必须重定位点 pre 侧」（比较基位移）；2 第 16.4 节「一次收敛 + 复核」（提交内容位移）；
3 16.4.1「检查对象 = 提交而非工作副本」（检查对象位移）。三者合起来 = 本次的过程方法论文集：
凡「读的东西」与「被裁定的东西」不是同一个对象，结论就不能照用。
- 同族：第 13 节的「rebase 之后必须重定位点 pre 侧」= 同一类「历史/比较基位移」问题的另一半。

---

## 17. 阶段终态与方法论产物（本次最值钱的两条，一个抓实现、一个抓流程）

### 17.1 实现面：检查抓到实现自身（Δ 检查的当场兑现）
T3 首轮 Δ 检查失败（d0 期望 0 / 实测 10），因此解码 `.ccr` 的 STR 段，因此根因 = 本次自己写的
`checker.cr::spec_check_func` 里 `str_intern("result")` 无条件调用（未注解的函数也驻留该串），因此移进「确需绑定」分支后 Δ 归位。
意义：若无维护者加的「零 Δ 用例必须通过」这一条，一条纯编译期的实现细节会永久污染 `.ccr` 产物而无人察觉
检查不是验收仪式，是发现器。

### 17.2 过程面：检查对象位移（第 16.4.1 节；比第 16.4 节原命题更根本）
「检查运行在工作副本上，断言必须落在提交上。」 两个实例：1 逐提交 `jj edit`+重写，因此 T3/T4 内容被从原提交剥出（第 16.4 节）；
2 一次收敛写盘 + 本地检查 5/5，因此随后的 `jj edit`/bookmark 把合成内容从尖端带走，本地检查仍通过，CI（读提交）立即失败（J2 悬空 10）。
因此复核点 = 最终提交（`jj file show -r @ <file>`，不是 `cat <file>`）+ 推送后以 CI 为准。

与第 13 节合起来 = 三条一体的过程纪律：1 rebase 后重定位点 pre 侧（比较基位移）· 2 冲突消解一次收敛 + 复核（提交内容位移）·
3 检查对象 = 提交而非工作副本（检查对象位移）。共同检查：「读的东西」与「被裁定的东西」必须是同一个对象；不是，结论就不能照用。

### 17.3 检查盘点（本次入仓面）
`tests/spec/`（33 档）+ `tests/selfhost/test_spec_grammar.py`（48 项，挂 `selfhost-tests`），四组：
A 语法 16 · B 检查 11 · C dump 15 · D 零影响 6；其中 Δ 公式 + 零 Δ 用例（D 组）是 17.1 那条教训的实现方式，
必须留在仓里（已在 `tests/spec/README.md` 与套件头注写明机制与「多一字节即失败」）。
