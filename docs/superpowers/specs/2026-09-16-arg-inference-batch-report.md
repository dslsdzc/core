# 实参推断缺失（TODO #93 真面目）—— 批报告（2026-09-16）

**批名**：**实参推断缺失**（**不是**「修 139」）· **批次位置**：**第 3 批**（用户 2026-09-16 裁）
**起点**：`develop = 0808a8ca`（分批 `feature/arg-inference-gap`；收尾前按纪律 rebase 到最新 develop）
**性质**：只读侦查 → 计划 → 取裁 → 实施 → 判据复验 → 收官（全程**先裁后码**、**三态纪律**、**路径限定小步提交**）
**输入**：`docs/superpowers/specs/2026-09-16-arg-inference-gap.md`（侦查全文）· `TODO.md` #93
**计划**：`docs/superpowers/plans/2026-09-16-arg-inference-fix.md`（§3bis 先裁 · §3ter/§3quater/§3quinquies 各阶段记录）

---

## 0. 批终态一行结论

**修好**：`checker.cr` 的 `infer_expr` 在「被调已解析为 Core `fn`」时提前 return、致**实参表达式从不被推断**这一根因级缺口——**响亮面 139**（9 例）与**静默面零诊断**（正据 1 例）**两条腿同时收敛**；并**顺带修复两条既有缺陷**（实参位泛型退化实例键 · **range-go 迭代变量绑定缺口**）。判据：**三腿 + 腿 D + 腿 E 全绿**、**74 档 rc 逐档全同**、**849 条新诊断逐条归因全部「本来就该报」**、**canary + `.ccr` 四条 IDENTICAL**（无需重锁）、自举链稳定。

## 1. 交付（提交链）

**开发链**（`feature/arg-inference-gap`，基点 `develop = 0808a8ca`）= **16 个提交，tip `59bd94a1`**（下表；每一步的裁决/判据/停止点都在提交信息里，保留作**开发史**）。

| 提交 | 内容 |
|---|---|
| `5004dea6` | #93 侦查落纸（TODO 按真面目重写 + 侦查文档 + **入仓 RED 语料 19 例** + 白名单条目） |
| `f2b76589` | **批计划**（判据网三腿 · 放大面预判 · 七裁决门） |
| `467bcaef` | **先裁落纸**（七门全按推荐 + 三条加码） |
| `e9a884ff` | **登记性提交**：`TODO #96`（`as` 静默重解释；非本批范围，来自维护者实测） |
| `ec1c6f32` · `a5433bd1` | T1 零构建（**return 点零未分类枚举** · 放大面基线 · **U3 证伪**） |
| `f37e38a9` | T1 构建步骤 + **U5 决定性发现** + 新增**裁-ARG-8** |
| `b342d077` | 裁-ARG-8 = (i) 落纸（五条硬条件 H1–H5）+ `TODO #97` |
| **`bd3fbd77`** | **T3-(a) 实现**：抽 `infer_call_args()` 在**四处**「已解析」return 前调用 |
| **`d38a7b65`** | **T3-(b) 实现**：fail-closed 护栏（实参位未解析的 `EXPR_FIELD` 被调 ⇒ 响亮拒绝） |
| `8e1e5120` | 套件**转正**（RED→已修）+ **腿 D** + 挂点三件套 |
| `c4703475` | T3/T4 实施记录（含**方法学修正**：码集对拍不得用「码+行号」做身份） |
| `77d55860` | **⚠ T4 停止点**（腿 C 抓到 1 处新引入误报） |
| **`43d6b598`** | **裁 (i) 落实**：补 **range-go 迭代变量绑定** + **腿 E** 直接判据 |
| `5eaab2ae` | 编号碰撞处置（我的 #94→**#96**、#95→**#97**） |
| `59bd94a1` | 硬条件 3 留痕（TODO 追记）+ 方法论文档 §0quater |

**收官形态 = 在最新 develop 上的单提交**（重建，非 rebase；事故经过见 §10）。理由与证据：

- **为何不 rebase**：`jj git fetch` 后 develop 已到 `a30715e2`——本批**侦查落纸**经 PR #84 被 squash 合入（同一批文件已在 develop 里），**判据网加固批** PR #85 又改了 `TODO.md` / `src/ci/run.sh` / `tests/harness/ci_hook_allowlist.txt` / `2026-09-16-criteria-strength-audit.md` ⇒ 逐提交重放 = 16 段相互冲突。**该形态下「按提交粒度收口」的信息价值为 0**（PR 走 squash 合入，最终只留一个提交），而冲突手工解有静默丢改动之险。
- **重建口径**：`jj new a30715e2` + 逐路径取本批净 diff（`jj diff --from 0808a8ca --to 59bd94a1 -- <path>`）⇒ **8 条路径**：`src/compiler/checker.cr` · `tests/selfhost/test_arg_inference_gap.py` · `src/ci/run.sh`（**只加 1 行挂点**，develop 侧 +6 挂点原样保留）· `tests/harness/ci_hook_allowlist.txt`（**只删 1 行** RED 条目）· `TODO.md`（#93 追记 + `#96`/`#97`，重编号与交叉引用同步）· 计划 · 侦查 · 本报告。
- **等价性证据（实测，非推断）**：重建树重编译后 —— **74 档 parity 日志与旧链 `diff -rq` = 0 行**；**29 探针根日志逐字节相同**（warm 腿日志仅 `mktemp` 目录名不同，`17 funcs/1262 instrs` 等数值全同）；canary 5/5 · 74 档 rc 序列 · 29 探针 rc 序列**三项与旧链全同**。⇒ 重建**零行为差异**；代价 = 旧链 16 段提交信息（已在本表留存）。

## 2. 根因与修法

**根因**：`checker.cr` `infer_expr` 的 EXPR_CALL 直调分支在**被调解析成已注册 Core `fn`** 时提前 `return sym_type(si)`（原 `:2817`），而「推实参（for side effects）」循环在**函数尾**（`:2833-2839`）——只在 `func_ni < 0` 时可达 ⇒ **对任何有名被调都是死码**。两种表现：

| 表现 | 机理 | 结果 |
|---|---|---|
| **响亮面 = SIGSEGV 139** | 实参位的内层调用若是 `EXPR_FIELD` 被调，其 `ast_data`（被调名索引）**只能由 checker 的模块/方法分支回填**（`:2584`/`:2645`）⇒ 从没回填 ⇒ 保持 parser 初值 **0** ⇒ `istr_get(0)` = 首个 interned 串（`"import"`）⇒ 后端查不到 ⇒ 外部位重定位 | 9 例（腿 A） |
| **静默面 = 零诊断** | 实参里的未定义函数/变量、常量越界**完全不查** | 1 例（腿 B） |

**修法（三件）**：
1. **(a) 补推断**：新增 `fn infer_call_args(first_arg)`（单一真源），在**四处**「已解析」return 之前调用——`:2811`（never 返回型）· **`:2817`（主病灶）** · `:2824`（runtime builtin）· `:2831`（EC_N_FUNC）；泛型直调 `:2791` 经 `infer_gen_call` 内部**已推**，不需。**四处来自「零未分类枚举」**（T1），不是「补一处」。
2. **(b) fail-closed 护栏**：`infer_call_args` 内，实参位 `EXPR_CALL` 且 callee 为 `EXPR_FIELD` 且 `ast_data <= 0` ⇒ `check_error(EC_N_FUNC, …)`。**落点偏离计划已交代**：既有 fail-closed 闸门（`main.cr:146-175`）位于 `check_all()` 之后、`ir_gen` **之前** ⇒ 在 ir_gen 报错不进闸门、须改构建控制流；改在 **checker 侧**实现同一条件（零新控制流、闸门天然覆盖）。**(a) 已修 ⇒ 恒不触发**（其价值 = 防未来同类回归）；**不误伤 dyn**（dyn 方法调用的名字由 dyn 分支回填，`cir` 实测 `dyn_dispatch` 正常）。
3. **同批**：`TODO #97`（实参位泛型退化键）与 **range-go 绑定**（见 §3）。

## 3. ⚠ **本批顺带修复的既有缺陷（两条）**（硬条件 3：必须写清，否则后来人不知本批改了多少东西）

### ① 实参位泛型调用用「退化实例键」实例化 → `TODO #97`（独立条目）

- **现象**：同一泛型调用位置不同 ⇒ 实例键不同：**LET 位** `idf[P]`（精确）vs **实参位** `idf[unit]`（**退化**，仅原生实参下两者一致）。
- **机理**：ir_gen 的泛型重定向有两条路径（`ir_gen.cr:1931-1984`）——优先走 checker 登记的调用点绑定段（`g_gen_binds` ⇒ 类型项精确键）；兜底按实参 IR 型拼名串。**实参位**调用点因「实参不被推断」从未获得 `g_gen_binds` ⇒ 永远走兜底。
- **后果（**未追**）**：实例体依赖 `T` 时**行为可能错**（探针返回常量 ⇒ 不可观测）。
- **本批处置**：(a) 修好后实参位自动改走精确键路径 ⇒ `idf[unit]` → **`idf[P]`**（**附带修复**）。
- **判据**：套件**腿 D**（正据）。

### ② **range-go 迭代变量绑定缺口**（`go i a..b body` 的 `i` 在 checker 里从未绑定）

- **坐标**：`parser.cr:617`（range-go 只把迭代变量名写进 `EXPR_GO` 的 `c` 槽 `iter_var_ni`，**不产生绑定**）· `checker.cr` 的 `EXPR_GO` 分支（原 `:2981-3000`：直接 `infer_expr(body)`，**不 bind**）。
- **修前不可见的原因**：body 常为 `f(i)` 形（**已解析直调的实参**）⇒ 实参从不被推断（TODO #93）⇒ `i` **从未被查**、无诊断。
- **暴露**：#93 修好后 ⇒ `i` 被查 ⇒ 未绑定 ⇒ **N01 误报**。命中载体：**29 探针之一** `tests/probes/p_spawn.cr`（rc 0→1）+ **已挂 CI** 的 `tests/selfhost/test_interp_parity.py`（23/23→22/23）。
- **判定**：**checker 与语言语义不一致**（`go i a..b body` 的语义**就是绑定 `i`**；ir_gen 已按 `EXPR_GO.c` 使用）⇒ **checker 缺口，不是误报豁免问题**（维护者裁 (i)）。
- **修法**：照 `for` 先例（`checker.cr:3039-3051`）——`ast_c(node) > 0` 时 `push_scope()` + `def_sym(iter_ni, SYM_LOCAL, TI_INT, -1)`（**int 局部**，与 ir_gen 用法对齐），body 推完 `pop_scope()` ⇒ **作用域严格限 body**；`ast_c(node) <= 0`（单发形 `go f(x)`）**不绑、不受影响**。
- **判据**：套件**腿 E**（E1 body 引用 ⇒ check rc=0 + **运行值 5**＝0+1+4；E2 **不泄漏**——body 外引用 `i` ⇒ rc=1 + `error[N01]`；E3 单发形不受影响）。

## 4. 判据（全绿）

| 判据 | 结果 |
|---|---|
| **腿 A**（响亮面 9 例） | 套件由 **10 RED → 0 RED**，139 全消、均得精确值 |
| **腿 B**（静默面，**正据**） | `g(nosuchfn(1))`：「`check` rc=0 零诊断」→ **rc=1 + `error[N06]`** |
| **腿 D**（泛型键精确，**正据**） | 实参位 `idf[unit]` → **`idf[P]`**，与 LET 位一致 |
| **腿 E**（range-go 直接判据） | E1 rc=0 + 运行 **5** · E2 不泄漏（N01）· E3 单发形 rc=0 |
| **腿 C-①**（新增诊断面） | **74 档 rc 逐档全同**；码集变化 11 档（全为 t2/t3/t4 源码单文件档）；**真新增 849 = N01×767 + N06×81 + TB01×1**，**逐条归因全部「本来就该报」**（N01/N06 = 独立文件里本就不存在的名；TB01×1 = **同因级联**，证据 = 该算术操作数本身就是同一个 N01）⇒ **零误报 / 零归因不清** |
| **腿 C-②**（预期 `.ccr` 变化面） | **空**——canary + `.ccr` 四条**全 IDENTICAL** ⇒ **无需重锁**（H1/H2 满足） |
| 零足迹 | ELF canary `95084e7b…d475`(28822B) IDENTICAL · `.ccr` 四条 96015/96158/142765/142908 IDENTICAL（go 绑定后**复验仍成立**） |
| 自源 | `check src/compiler` **rc=0 + 0 error** |
| selftest | `selftest-types` **415/415** |
| 行为探针 29 档 | **rc 与基线全同**（`p_spawn` 回到基线 rc=0） |
| `interp_parity` | **23/23**（回到基线） |
| 挂点三件套 | `run.sh` 已挂（**相对 develop 只 +1 行**）+ 白名单 RED 条目已删（**相对 develop 只 −1 行**）+ 头注转正；`test_ci_hook_coverage.py` **PASS**（重建后实测 **scope=68 hooked=47 unhooked=21**；本批净 +1 挂点，其余 +6 来自 develop 侧判据网加固批 PR #85） |
| 五 CI job / 自举链 | 见 §7 |

## 5. **判据分工（本批第二次兑现）**

| 判据 | 覆盖域 | **零覆盖域** |
|---|---|---|
| 腿 A/B/D/E + 套件 | **实参推断面**（含泛型实例键、range-go 绑定） | 其余一切 |
| 腿 C | 74 档 / 29 探针 / 自源的 **check 面** | ir_gen 之后；74 档之外的形态 |
| canary + `.ccr` 四条 | `ptr_arith`/`generics_test` 两语料面 | 本批面（**实测：本批改动下仍 IDENTICAL** ⇒ 不能据它推断本批正确） |

## 6. ⚠ **方法学：腿 C 机制已被证明会工作**（务必留痕）

> **若按「新增诊断一律算修好」的口径，两处载体变红会被误记为「修好」——腿 C 的「逐条归因 + 不许把新增诊断当修好」纪律正是抓到它的机制。**

机制：一次**触发面变更**会**同时**产生①真修好②新引入误报，二者在「诊断计数」上**不可区分**。
**落地要求**（已写入 `2026-09-16-criteria-strength-audit.md` **§0quater**）：触发面变更批**必须**把新增诊断**默认按回归嫌疑**处理、逐条归因；**且必须有「原载体回归」腿**（本例 = 29 探针 + 已挂套件的 rc 基线）——因为**新形态的钉子 ≠ 原载体的钉子**。

**方法学附带修正（防后人重踩）**：码集对拍**不能**以「码 + 行号」为身份——t2/t3 语料是**多文件拼接单元**，改动任一参与文件的行数都会让后续行号整体漂移（实测 +17）⇒ 首轮把「位移」误判为「新增 N11×38」。**正确身份 = 码 + 诊断文本**。

## 7. 收官判据（五 CI job + 自举链）

**判据口径**：`src/ci/run.sh` **不读 argv**——job 名走**环境变量** `CI_JOB_NAME`（`CI_JOB_NAME=check src/ci/run.sh`）。写成 `bash src/ci/run.sh check` ⇒ 五个 job 全部 `unknown CI_JOB_NAME:` rc=1，**是命令用错、不是 job 红**（假红陷阱，见 §10②）。

**实测（重建树 × develop `a30715e2` 基点 · `nice -n 19` 限速）**：

| job | rc | 关键内证 |
|---|---|---|
| `check` | **0** | `./build/corec check src/compiler` 0 error；corearch/corelsp `build log clean (error[ = 0, undefined = 0)`（既有**非致命** checker 警告原样不变） |
| `bootstrap-tests` | **0** | bootstrap 套件全绿 |
| `selfhost-tests` | **0** | 含**本批套件**（腿 D / 腿 E PASS 行在日志内）· `interp_parity` **23/23** · `selftest-types` PASS · `selftest-purity` PASS · 挂点覆盖 harness + canary 载体 harness PASS |
| `suite` | **0** | 集成语料 **23 档 ALL PASS** |
| `full-bootstrap` | **0** | `cmp /tmp/corec2 /tmp/corec3` **恒等**（sha256 `fd9aa4f5c0daafe7212dcdb7…` · 2900630 B；`corec3 --help` 冒烟正常） |

**同树复验的判定面（重建后重跑，非沿用旧链数据）**：canary **5/5 IDENTICAL**（ELF `95084e7b…d475` 28822 B + `.ccr` 四条 96015/96158/142765/142908）· **74 档 rc 序列全同**（35×0 / 39×1，与改前基线 `pb2`、旧链 `pc93c` 均逐档相同）· **29 探针 rc 序列全同**（warm 腿 11 档真命中、FAIL=0，`p_spawn` rc=0）· `test_ci_hook_coverage.py` PASS（scope=68 hooked=47 unhooked=21）· **parity 日志与旧链 `diff -rq` = 0 行**。

## 8. 遗留登记

| # | 内容 | 状态 |
|---|---|---|
| **#96** | `as` 值转换 = **静默重解释**（非转换） | 登记，未修（用户裁「不投入」；非本批范围） |
| **#97** | 实参位泛型**退化实例键** | **本批附带修复**；判据 = 腿 D；**行为面（实例体依赖 T）未追** |
| — | **range-go 迭代变量绑定缺口** | **本批附带修复**（见 §3②）；判据 = 腿 E |
| **U** | 本批**未动**：`go` 的**单一 go** 语义（`ast_c <= 0` 路径，逐字保持）· `dyn` 面（实测未受影响） | — |

## 9. 诚实边界

- 本批**未修**：`as` 面（#96，用户裁不投入）· 泛型退化键的**行为面**（仅键精确化，实例体依赖 `T` 时的错值**未追**）。
- **两处偏离计划已显式交代**：(b) 护栏落点由 ir_gen 改为 checker（§2.2）；range-go 绑定为本批新增范围（裁 (i)，§3②）。
- **一处探针自纠**：A5/A6 期望值原稿写错（实得即正确值）⇒ 已改并留痕。

## 10. ⚠ 事故留痕（两条，均为「判据/工具用错」而非本批逻辑）

### ① 失败的 rebase：`jj rebase -s <链尖> -d develop` 把 16 段链压成 1 段

- **经过**：收尾执行 `jj rebase -s feature/arg-inference-gap -d develop`（意图 = 整链移到最新 develop）。**`-s` 语义 = 「以该 revision 为根重定位它与它的后代」**；我给的却是**链尖** ⇒ 链尖被直接挂到 develop，**15 个祖先被孤立**，工作副本树 = **只剩链尖一个提交的 diff**。
- **发现**：`jj status` + 8 条路径清单对照 ⇒ `src/compiler/checker.cr` 里 `infer_call_args` 不见了。
- **恢复**：`jj undo` ×2（jj 操作日志逐条记录）⇒ 完整回到 `59bd94a1`；`cmp` 逐路径复核 = **零数据损失**。
- **正确用法（防重踩）**：整链移动用 **`jj rebase -b <bookmark>`**（或 `-s <链根>`）；**绝不** `-s <链尖>`；单提交用 `-r`。
- **加固纪律（本批新增）**：破坏性 `jj` 操作（rebase / squash / abandon）**先 `jj log -r '::@'` 记链形态**，**操作后立即**以「关键标记 grep + `jj diff --stat`」复核树内容，**再**跑判据。

### ② 两条判据命令的假红陷阱（同一晚各踩一次）

- **`src/ci/run.sh` 不读 argv**：job 名走 **`CI_JOB_NAME` 环境变量**（`CI_JOB_NAME=check src/ci/run.sh`）。我首轮写成 `bash src/ci/run.sh check` ⇒ 五个 job **全部** `unknown CI_JOB_NAME:` rc=1——**是命令用错，不是 job 红**。
- **重定向被 noclobber 拦住 ⇒ 读到的是上次的旧日志**：第二轮我用 `env CI_JOB_NAME=$j ... > /tmp/apx-t1/job_$j.log`，而该文件已存在、当前 shell 开了 noclobber ⇒ **重定向失败、命令根本没跑**，`tail` 展示的仍是首轮的旧内容 ⇒ 两轮「结果」看起来完全相同。**判据命令必须核对「日志时间戳/新路径」**，否则「跑过了」本身是假的。
