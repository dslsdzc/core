# fail-closed 检查体系实施计划：报错即拒（默认全阻断 + 豁免登记表）

> 实施记录：[implementation/2026-09-15-fail-closed-diagnostics.md](../implementation/2026-09-15-fail-closed-diagnostics.md)

> 面向执行代理：必须使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans，按任务逐步执行本计划。用复选框（`- [ ]`）跟踪进度。

目标：按维护者已裁定的「要改」方向实施 fail-closed。本批把编译器语义收敛为：报出错误时 `rc=1`，并且不产生产物，从而消除「打印诊断但仍生成二进制」的不报错地错产物。机制是把 `src/compiler/main.cr` 的硬名单检查反转为「默认全阻断 + 已知命中面豁免登记表」：当前名单是正向名单，反转后默认 `hard = 1`；豁免表作为允许清单，条目包含错误码、语料位点、理由和生效范围。全批纪律：新检查面先做 report-only，命中清单审查后才启用；命中面过大时转独立批（停条件）。

架构：本批共六条主线。

- 1 前置侦查、固定基线重建、基准点实核（T0，源码零改动）。
- 2 全语料 report-only 基线（核心产物）（T1：用现有二进制在 build 面语料上采集全量命中清单；现有 `check` 面已经是 fail-closed 检查，可以直接作为采集工具，零源码改动即可产出清单）。
- 3 分类表定稿与裁决门裁定（T2，零代码）。
- 4 检查机制实现 + report-only 开关（T3：反转 + 豁免表 + 隐藏旗标 + 采集器）。
- 5 命中面处置（T4：逐条归因，修根因 / 修语料 / 登记豁免）。
- 6 启用 + 零产物语义 + 回归完成（T5/T6）。

Tech Stack / 基准点（本实例实读，行号 = 当前工作树）： 检查共三处，另有一处为已收紧面。

- 1 语法面检查：`src/compiler/main.cr:134`（`parse_all()` 后 `g_diag_count > 0，因此 print_diagnostics(); return 1`）+ `:135`（`g_error_count > 0，所以 print_parse_errors(); return 1`）。
- 2 类型面检查（本批的对象）：`main.cr:146-179`（`if g_diag_count > 0 { 硬名单扫描 }`）。其中 6 条语句行 `:152`/`:153`/`:154`/`:160`/`:166`/`:174` 覆盖 11 个码常量；`if hard != 0 { return 1; }` 在 `:178`。
- 3 安全检查面检查（已 fail-closed）：`main.cr:594-603`（`base_diags` 快照，再 `ptr_analysis_all()` / `region_check_all()` / `provenance_verify_all()` 改为 `g_diag_count > base_diags，因此 return 1`，无码过滤 = 任意诊断阻断）。
- 4 `check` 面检查（已 fail-closed）：`main.cr:443-451`（`if g_diag_count > 0 { return 1; }`）。

其余落点逐条如下。

- `main.cr:399-402`：`run` 走同一 `run_frontend` 检查。
- `main.cr:431-438`：`--static` 前置 `rt.cr`。
- `main.cr:440-441`：`fe_rc` 唯一入口。
- `main.cr:473`：`make_cir_cache_dir`。
- `main.cr:565-591`：`cir`，不过安全检查面。
- `main.cr:620-662`：`ccr`。
- `main.cr:665-703`：`build`，`:671` 为 `.ccr` 路径，`:674-679` 为 `save_ccr`，`:682-702` 拼 `corearch` 命令行并调用 `system()`，`:702` 为 `return exit_code`。
- `diag.cr:122-150`：`print_diagnostics`，码面 = `cat = ec/1000` + `num = ec%1000`；`diag.cr:86-104` 为前缀表，`:106-110` 为补零。
- `checker.cr:820-828`：`check_error` 唯一写入器，记录 40B = `globals.cr:182` `DIAG_REC_SIZE`。
- `checker.cr:490-495`：`diag_type_incompatible` 组合判定。
- `globals.cr:463-500`：`reset_frontend_state` 清 `g_diag_count`；`check_all` 自身亦在 `checker.cr:3805` 清零。
- `src/ci/run.sh:31-33`：check job；`:36-54`：suite job（`:44` 为 `*_mini*.cr` SKIP、`:46` 为空文件 SKIP）；`:119-130`：full-bootstrap。
- `tools/baseline/parity_run.sh:30`：`CORPUS_TOTAL=72`；`:32-40`：逐档 `clean-cache` + `check`；`:68-71`：计数硬断言。
- `tools/baseline/probes_run.sh`：`PROBE_TOTAL=29`。

Spec / 依据：

- 1 维护者 2026-09-14 裁定「要改、方向 = fail-closed」，本批成立的前提即此。该裁定文本经协调者转述，无独立文件实现方式， 须 T0 向维护者核一句原文并落报告。
- 2 P6 裁决门 裁-P6-2 的 (b)(c) 两问（`docs/superpowers/plans/2026-09-14-r2-p6-tail.md:58`）：(b) 非硬名单诊断是否收紧到 `build` 面；(c) 新硬错纳入检查是否成文化为「判定继续，因此产出不报错地错产物」。本批 = 该两问的最强形式，未取裁前的方向性背书不成立。
- 3 P5 已落政策：P-A（ICE04 硬错，`plans/2026-09-13-r2-p5-cleanup.md` + `main.cr:161-166` 注）、TA02（TODO #2026-09-11-14 + `main.cr:167-174` 注）。本批不得回退这两条。
- 4 `docs/error-codes.md`（码族 / 消息模板 / 统计）。
- 5 E-14 的活证据（P6 T0 报告 第 6 节-5：`tests/suite/ptr_arith.cr` 的 `check` rc=1（B04 `12:8`），而 `build --static` rc=0 且产出 canary ELF）。

---

## 前置状态（本计划未运行任何构建/测试；下列全部为实读源码/文档或既有报告记录值，出处逐条标注）

- 工作树 = `/tmp/p7wt`，基线 = P6 终态提交 `97f4394f`（协调者给定）。本实例 `jj` 命令零执行（纪律：统一由协调者提交）；`ps` 实查无并发编译进程的步骤留给实施任务。
- 诊断通道实读 = 5 条（全仓 `check_error(` / `g_diags` 写入点 grep 实证）。逐条如下。
  1. 词法/语法消息通道：`lexer.cr:39-43` 的 `add_error()`（`g_errors` = 驻留串下标），加 `parser.cr` 的同族 `add_error`。该通道共 20 个调用点（`lexer.cr` 10 处，即 `:147`/`:226`/`:233`/`:236`/`:238`/`:240`/`:246`/`:436`/`:454`/`:456`；`parser.cr` 10 处，即 `:468`/`:591`/`:704`/`:1472`/`:1474`/`:1477`/`:1479`/`:1482`/`:1531`/`:1580`）。该通道无码，打印形为 `error: <msg>`（`diag.cr:154-162`）。已 fail-closed（`main.cr:135`）。
  2. 语法诊断码通道：`parser.cr` 直接写 `g_diags`，共 15 处写入 / 8 个码：`EC_P_EXPECTED`（`:121`/`:130`）、`EC_P_FIELD_SYNTAX`（`:1828`）、`EC_P_PARAM_TYPE`（`:1847`）、`EC_TA_UNKNOWN_TAG`（`:829`）、`EC_P_NESTED_FN`（`:927`）、`EC_P_TOO_MANY_PARAMS`（`:1453`）、`EC_P_STRUCT_LIMIT`（`:1647`）、`EC_P_ENUM_LIMIT`（`:1723`/`:1728`）。已 fail-closed（`main.cr:134`）。
  3. 类型诊断码通道（`check_all` 内，本批反转对象）：`checker.cr` 的 `check_error` 调用面 = 55 处 / 32 个码（清单见「表 1」）。`check` 面已 fail-closed（`main.cr:448`）；`build` 面只拦 11 码（`main.cr:152-174`），因此本批的唯一缺失面。
  4. 安全检查面通道（build/ccr 专属）：`region_check.cr:83`/`:134`（`EC_B_LIFETIME`/B11）、`provenance_verify.cr:68`（`EC_TU_DEREF`/TU03）、`:91`/`:99`/`:126`（`EC_TK_INDEX`/TK01 复用）。已 fail-closed（`main.cr:600`，任意新诊断阻断）。注意：`check` 面不运行该面（`main.cr:451` 提前返回），因此该面是「check rc=0 / build rc=1」的反向不一致存在性证据（与 `ptr_arith` 的正向不一致成对；本实例未构造具体语料，须 T1 实测登记）。
  5. 非 `g_diags` 的 `error:` 打印通道：`main.cr`（`:32`/`:94`/`:421`/`:434`/`:640`/`:675`/`:679`，写入失败为 `:650-652`/`corearch.cr:510`/`:586`/`:596`）、`corearch.cr`（装载/链接失败全分支）、`interp.cr:408`/`:413`/`:738`/`:743`。已 fail-closed（各自 `return 1`）。
- 码面实读统计：`ast.cr` 定义码 ≈ 146（`docs/error-codes.md:275-287` 统计表自述「总计 ~146」）；可达码（有 raise 点）= 42（本实例用 `check_error(EC_*` / `diag_type_incompatible(…, EC_*` / `DIAG_REC_SIZE, EC_*` 三形态全仓 grep 去重实得 43 项，其中 `EC_SIZE` 为 `DIAG_REC_SIZE` 的子串假命中，扣 1），因此其余 ≈104 个码「定义零 raise」，本批不动，登记。码名两式约定（照 P6 T0 表 D-6）：常量名写作 `EC_P_ENUM_LIMIT=1022`（`ast.cr:372`），而用户面实印 `error[P22]`（`diag.cr:132-136` 的 `num = ec%1000 = 22`），本计划一律「常量名（用户面码）」双写。
- 现行 11 码硬名单（`main.cr:152-174` 逐行实读）：`EC_R_OOB`（R002）· `EC_TK_SLICE_BOUNDS`（TK05）· `EC_TK_SLICE_LEN`（TK06）· `EC_TS_MISSING_FIELD`/`EC_TS_UNKNOWN_FIELD`/`EC_TS_FIELD_TYPE`/`EC_TS_FIELD_DUP`（TS01-04）· `EC_TK_ELEM_TYPE`（TK02）· `EC_TM_EXHAUST`（TM03）· `EC_ICE_TY_INDET`（ICE04）· `EC_TA_DECL`（TA02）。
- 已知非硬名单诊断（`ast.cr:487-489` 定义、`main.cr` 名单外）：`EC_TG_ARG_COUNT`（TG01，零 raise）· `EC_TG_BOUND`（TG02，raise 于 `checker.cr:1227`/`:1233`/`:2059`）· 族内其余（N/TF/TB/TC/TM/TK/B 面）。
- `check` 面不产生产物（实读：`main.cr:444-451` 在 `:467` `optrep_begin()`/`:473` `make_cir_cache_dir()` 之前返回），因此 「零产物」的缺失只在 `build`/`ccr`/`cir` 面。

---

## 表 0：检查 × 命令矩阵（现状，本实例实读；本批的判定面边界）

| 命令 | 语法面检查 `:134/:135` | 类型面硬名单检查 `:146-179` | 安全检查面检查 `:594-603` | 现行 rc 语义 | 产物 | 本批是否改 |
|---|---|---|---|---|---|---|
| `check` | 是 | 否（不用；`:448` 独立更严） | 否（`:451` 前返回） | 任意诊断，因此 rc=1 | 无 | 不改（已 fail-closed） |
| `build` | 是 | 是 | 是 | 名单内，因此 rc=1；名单外，所以 rc=0 + 照出产物 | `<out>` ELF + `<out>.ccr` | 本批对象 |
| `ccr` | 是 | 是 | 是 | 同上（名单外，因此照出 `.ccr`） | `<out>.ccr` | 同批（同一 `run_frontend` 检查） |
| `cir` | 是 | 是 | 否（`:565` 分支在 `:594` 前返回） | 同上（名单外，因此照出 `.cir`） | `<out>.cir` | 同批（检查同源；安全检查面不在本批扩面） |
| `run` | 是 | 是 | 否（解释器路径） | 名单外，因此照运行 | 无 | 同批（检查同源） |
| `selftest-types` / `selftest-purity` | — | — | — | 自测通道，不读源文件 | 无 | 不改 |
| LSP（`src/lsp/lsp.cr`） | — | — | — | 编辑器诊断推送（不产生产物） | 无 | 不改（登记：非产物面，fail-closed 不适用） |

判定面定义（本批语义）：error = 阻断（`rc=1` + 零产物）；本仓现行无 warning 通道（全仓无 `warning[` 打印面）。`TM04`（`EC_TM_REDUNDANT`）在 `main.cr:159` 注中记为「软面登记（同 Rust unreachable-pattern 的警告约定）」，但打印仍是 `error[TM04]`，因此本批要么把软面码降级为真 warning，要么登记为豁免（见裁-FC-2）。

---

## 表 1：全诊断面清点（核心产物；`check_all` 面 32 个可达码逐码分类）

> 约定：1 必须阻断 = 语义上「判定继续，因此产出不报错地错产物 / 判定不可信」（照 P6 裁-P6-2(c) 的成文化检查）；2 必须豁免 = 有已实测语料命中且该命中属已知假阳性/过渡期，或已有政策裁定使其非 error；3 本批不动 = 在检查作用域之外（另见表 0/表 2）。「命中」列 = P6 T0 报告 第 3.1 节的 72 档实际运行记录值（`/tmp/p6t0/corpus_rc.txt`），非本实例实测；套件面命中一律标「须 T1 实测」。

| # | 码（用户面） | 常量（`ast.cr` 行） | raise 点（`file:line`） | 语义 | 72 档命中（P6 T0 记录） | 分类 | 依据 |
|---|---|---|---|---|---|---|---|
| 1 | TA01 | `EC_TA_ASSIGN`（:407） | `checker.cr:3376` | 赋值号两侧类型不匹配 | 0（未见于首条诊断表） | 1阻断 | 与 TA02 同族（声明位/赋值位同形）；符号类型与实际值分歧，因此不报错地错值 |
| 2 | TA02 | `EC_TA_DECL`（:408） | `checker.cr:530` | 声明注解 vs 初值 | 0（P5 T6 report-only 全语料零命中） | 1阻断（已在名单） | P5 政策，不得回退 |
| 3 | TF01 | `EC_TF_RETURN`（:417） | `checker.cr:1525`/`:2240` | 返回型不匹配 | 5（`chan_test`/`conc_test`/`go_e2e_test`/`go_final_test`/`go_parallel_test`，P6 T0 第 3.1 节「TF01 返回型不匹配（并发/goroutine 族）」） | 2豁免（待裁，须逐档归因） | 命中面 = CI `suite` job 实际 build 的 21 档中 5 档（`run.sh:36-54`），因此直接纳入检查 = 套件 job 变为失败 + 可能改写 ELF canary 族检查。同码先例 = 已修的假阳性（`src/compiler` 内两条 TF01 系误报已由 P6 TF01 清理批修，TODO #2026-09-13-1，所以 `check src/compiler` rc=0），因此本批须先判这 5 档是同族误报还是真错 |
| 4 | TF07 | `EC_TF_ARG_TYPE`（:423） | `checker.cr:3727`（唯一 raise，`@raw_int` 内建位；非调用位点，#20 登记的「调用位点判定点不存在」实读 = 已知 `SYM_FN` 非泛型分支 `checker.cr:2766-2797` 连实参推断都不走（直接 `return sym_type(si)`；T4a 报告基准 `:2744-2753` 为打补丁前行号，本实例实读变化 +22）） | 实参类型不匹配 | 1（`ptr_ref_first.cr`，P6 T0 第 3.1 节「TF07 实参类型 1」） | 2豁免（待裁） | 同行 3：命中档在 suite job 的 build 集内 |
| 5 | TF08 | `EC_TF_METHOD_NOT_FOUND`（:424） | `checker.cr:2277` | impl 缺接口方法 | 0 | 1阻断 | 接口契约未履行，因此表项/调用面不可信（同 TG02 族） |
| 6 | TF09 | `EC_TF_METHOD_ARG_CNT`（:425） | `checker.cr:2288` | 方法实参个数 | 0 | 1阻断 | 同上 |
| 7 | TF10 | `EC_TF_METHOD_ARG_TYP`（:426） | `checker.cr:2283`/`:2301` | 方法实参类型 | 0 | 1阻断 | 同上 |
| 8 | TB01 | `EC_TB_ADD`（:436） | `checker.cr:2474`/`:2990`/`:2991` | 算术操作数类型错 | 0 | 1阻断 | 算术无良定义，因此发射按错宽度 |
| 9 | TC01 | `EC_TC_IF_COND`（:452） | `checker.cr:2489`/`:2851` | 条件非 bool/int | 0 | 1阻断 | 分支判定按非布尔值，因此不报错地错控制流 |
| 10 | TC02 | `EC_TC_IF_BRANCH`（:453） | `checker.cr:2908` | 两分支类型不同 | 0 | 1阻断 | 结果型随分支变化（同 TK02 族）；`checker.cr:2906-2908` 已含 `TI_NEVER` 双侧豁免（返回值合并面） |
| 11 | TC04 | `EC_TC_WHILE_COND`（:455） | `checker.cr:2965` | while 条件非 bool | 0 | 1阻断 | 同 TC01 |
| 12 | TM03 | `EC_TM_EXHAUST`（:463） | `checker.cr:3097` | match 非穷尽 | 0（P3 Task 3 report-only 零命中） | 1阻断（已在名单） | 未匹配值不报错地得 0（`main.cr:155-159` 注） |
| 13 | TM04 | `EC_TM_REDUNDANT`（:464） | `checker.cr:3100` | 冗余臂 | 0 | 2豁免（政策既定） | `main.cr:159` 原文：「TM04（冗余臂）不入本名单 = 软面登记（同 Rust unreachable-pattern 的警告约定）」因此默认全阻断会否定该裁定，须登记豁免或改判为真 warning |
| 14 | TK01 | `EC_TK_INDEX`（:472） | `checker.cr:3353` + `provenance_verify.cr:91`/`:99`/`:126` | 非可索引类型 / 指针越界 | 0 | 1阻断 | 索引回退处理门（P3b Task 2 接线）；后三处属安全检查面（已阻断） |
| 15 | TK02 | `EC_TK_ELEM_TYPE`（:473） | `checker.cr:3567` | 数组元素异型 | 0 | 1阻断（已在名单） | TODO #2026-09-11-11 三校验 |
| 16 | TK05 | `EC_TK_SLICE_BOUNDS`（:476） | `checker.cr:3304` | 常量档切片越界 | 0 | 1阻断（已在名单） | F2：修复前不报错地生成越界二进制 |
| 17 | TK06 | `EC_TK_SLICE_LEN`（:477） | `checker.cr:3306` | 切片长度负 | 0 | 1阻断（已在名单） | 同上 |
| 18 | R002 | `EC_R_OOB`（:504） | `checker.cr:3320`/`:3335` | 常量档越界索引（数组/字符串） | 0 | 1阻断（已在名单） | 同上 |
| 19 | N001 | `EC_N_UNDEFINED`（:376） | `checker.cr` 17 处（`:2257`/`:2432`/`:3205`/`:3673`…`:3776`） | 未定义名 | 25（P6 T0 第 3.1 节「库单元单独 check（N01/N06/N11，本该由 concat 供货）25 档 = t2 1 + t3 13 + t4 10 + t1 1」） | 2豁免（范围 = check 面） | 该 25 档从不在 build 面被编译（语料 runner 只运行 `check`，`parity_run.sh:36`），因此若裁-FC-1 取「两面同检查」则必须豁免，取「build 面单检查」则无需豁免（自然不触发） |
| 20 | N006 | `EC_N_FUNC`（:381） | `checker.cr:2809` | 未定义函数 | 同上 25 档内嵌（t1 `at_test_mini.cr` + t3 7 档 + t4 5 档） | 2豁免（范围 = check 面） | 同上 |
| 21 | N008 | `EC_N_METHOD`（:383） | `checker.cr:2396` | dyn 方法不存在 | 0 | 1阻断 | 调用面不可解析，因此不报错地错分派 |
| 22 | N009 | `EC_N_GENERIC_TYPE`（:384） | `checker.cr:1000` | 泛型应用基类型不存在 | 0 | 1阻断 | 实例化不可进行 |
| 23 | N011 | `EC_N_DUPLICATE`（:386） | `checker.cr:1530`/`:1550` | 重复定义（含 hotpatch 形参不符） | 1（t3 `ccr_io.cr`，P6 T0 第 3.1 节 表「N11×1」） | 2豁免（范围 = check 面） | 同上（concat 供货面） |
| 24 | TG02 | `EC_TG_BOUND`（:489） | `checker.cr:1227`/`:1233`/`:2059` | 泛型约束不满足 | 0（P5 清单：全语料 0 命中；唯一命中 = `test_generic_constr.py` 1 例登记面已重新固定） | 1阻断 | 约束未满足，因此实例化假定不成立 |
| 25 | B001 | `EC_B_BORROW_MUT`（:492） | `checker.cr:2510` | 对已借用者取可变借用 | 0（P6 T0 第 3.1 节 借用族仅 `ptr_arith` 1 档，且首条 = B04） | 1阻断（待 T1 实测复核） | 借用模型判定；若 T1 实测出套件面命中，因此并入 2（见裁-FC-3） |
| 26 | B002 | `EC_B_BORROW_IMMUT`（:493） | `checker.cr:2512` | 对可变借用者取共享借用 | 0（同上） | 1阻断（待 T1 实测复核） | 同上 |
| 27 | B004 | `EC_B_USE_WHILE_BORROWED`（:495） | `checker.cr:2427` | 借用存续期内使用被借用变量 | 1（`tests/suite/ptr_arith.cr` `12:8`，P6 T0 第 3.1 节 + 第 6 节-5 活证据） | 2豁免（必选之一，见裁-FC-3） | 该档 = ELF canary 硬性检查的唯一实现方式（canary 命令即 `build tests/suite/ptr_arith.cr --static`，P6 T0 第 2 节#7），因此纳入检查 = canary 不可产，所以三选一（修 B04 假阳性 / 登记豁免 / 换 canary 实现方式） |
| 28 | ICE04 | `EC_ICE_TY_INDET`（:521） | `checker.cr:559` | 类型判定不可判（引擎 -1/桥接缺失） | 0 | 1阻断（已在名单） | P-A 政策，不得回退 |
| 29 | TS01 | `EC_TS_MISSING_FIELD`（:482） | `checker.cr:3449` | 缺字段 | 0 | 1阻断（已在名单） | TODO #2026-09-11-11 |
| 30 | TS02 | `EC_TS_UNKNOWN_FIELD`（:483） | `checker.cr:3433` | 未知字段 | 0 | 1阻断（已在名单） | 同上 |
| 31 | TS03 | `EC_TS_FIELD_TYPE`（:484） | `checker.cr:3478`/`:3502` | 字段类型不符 | 0 | 1阻断（已在名单） | 同上 |
| 32 | TS04 | `EC_TS_FIELD_DUP`（:485） | `checker.cr:3436` | 字段重复初始化 | 0 | 1阻断（已在名单） | 同上 |

表 1 计数：1 必须阻断 = 25 码（TA01/TA02/TF08/TF09/TF10/TB01/TC01/TC02/TC04/TM03/TK01/TK02/TK05/TK06/R002/N008/N009/TG02/B001/B002/ICE04/TS01/TS02/TS03/TS04）2 必须豁免 = 7 码（TF01 · TF07 · TM04 · N001 · N006 · N011 · B004）3 本批不动 = 表 0 的七行作用域外命令 + ≈104 个「定义零 raise」码 + 5 条通道里已 fail-closed 的 4 条。

表 1-补：已 fail-closed 的 10 个可达码（本批不改，清点收编）：`EC_P_EXPECTED`/`EC_P_FIELD_SYNTAX`/`EC_P_PARAM_TYPE`/`EC_P_NESTED_FN`/`EC_P_TOO_MANY_PARAMS`/`EC_P_STRUCT_LIMIT`/`EC_P_ENUM_LIMIT`/`EC_TA_UNKNOWN_TAG`（语法面 8 个，落 `main.cr:134`）· `EC_B_LIFETIME`（B11，`region_check.cr:83`/`:134`）· `EC_TU_DEREF`（TU03，`provenance_verify.cr:68`）（安全检查面 2 个，落 `main.cr:600`）。因此可达码 42 = 25 + 7 + 10。

---

## 表 2：语料面与变为失败面预估（第 4 项交付的输入；全部为记录值或实读构成）

| 语料面 | 构成（实读） | 面 | 现行状态 | 全阻断后的预估变为失败面 | 出处 |
|---|---|---|---|---|---|
| 72 档 | t1 `tests/suite/*.cr` 32 + t2 自源 2 + t3 后端/内核 15 + t4 stdlib 19 + t5 examples 4 | `check` | rc 34×0 / 38×1；38 档划界 = 0 字节 fixture 2 + P21 负例 2 + examples 解析错 2 + 库单元单独 check（N01/N06/N11）25 + TF01 5 + TF07 1 + B04 1 | 若 check 面不改：零变化（表 0）；若取「两面同检查」：N 族豁免条生效，因此≈25 档 rc 1 改为 0（精确档数取决于 T2 豁免表的 `scope` 字段，所以检查换代 + 逐档更新基准值） | P6 T0 第 3.1 节（`/tmp/p6t0/corpus_rc.txt`）+ `tools/baseline/parity_run.sh:30` |
| CI `suite` job | `tests/suite/*.cr` 实 build 21 档（32 − 2 空 − 9 `*_mini*`；`run.sh:44`/`:46`） | `build` | 全 rc=0 + 运行通过 | ≥7 档（TF01×5 / TF07×1 / B04×1；见下「变为失败面预估方法」） | `run.sh:36-54` + P6 T0 第 3.1 节 |
| CI `full-bootstrap` job | `src/compiler/main.cr --static -O 0` ×2（corec2/corec3）+ `--help` | `build` | rc=0 · `cmp` IDENTICAL | 0（`check src/compiler` rc=0，因此零诊断，所以检查无差别） | `run.sh:119-130` + P6 T0 第 2 节#6 |
| CI `check` job | `build_selfhost` + `check src/compiler` | `check` | rc=0 | 0 | `run.sh:31-33` |
| ELF canary | `clean-cache` 改为 `build tests/suite/ptr_arith.cr --static` | `build` | rc=0 + `95084e7b…d475`（28822B） | 1 档 = 硬冲突（B04 命中），因此 canary 不可产 | P6 T0 第 2 节#7 |
| `.ccr` 四条检查 | `ptr_arith` / `generics_test` 两种形式 | `ccr`+`build` | 四条 = T3 新基准值（96015/96158/142793/142936） | ≥1 档（`ptr_arith` 含 B04） | P6 T6 “Step”节 2 + `p6-task4-report.md` 第 4 节 |
| `tests/selfhost/*.py` 套件 | 51 档 py；其中 44 档含 `"build"` 调用（126 处）（本实例 `grep -l`/`grep -rho` 计数） | `build` | 全部通过 | 须 T1 实测（负例套件断言 rc=1 不受影响；风险 = 「断言 build rc=0」的档） | `src/ci/run.sh:84-111` 接入点 28（`grep -c 'python3 tests/selfhost/'` 实核）+ 本实例 `grep -rho '"build"'` |
| 探针语料 | `tests/probes/*.cr` 29 档 | `check` | 17×0 / 12×1（12 档为故意的负例） | 零变化（check 面不改，因此两态对比仍为零差异） | `tests/probes/README.md:58` |
| `examples/*.cr` | 4 档 | `check` | 2 档解析错（既有） | 零变化（check 面） | P6 T0 第 3.1 节 |

变为失败面预估方法（硬要求，T1 实现）：1 不靠猜，T1 用现有二进制对「build 面语料全集」逐档运行 `build`（`-o /tmp/fc1/out/<tag>`，保留产物供二次比对），采集 `rc` 与日志中全部 `error[XX]` 行的（码, `file:line`）二元组，因此产出 `hits.tsv`。2 逐档归因表，每档给出「码，再 归因（真错 / 假阳性 / 语境缺失 / 政策软面），再 处置（修根因 / 修语料 / 登记豁免）」。3 分批启用办法，批次 1 = 全反转 + 豁免表覆盖 T1 全清单（先保 CI 绿）；批次 2..n = 逐条撤销豁免（每条以「根因已修 / 语料已正」为撤除检查），只减不增。

---

## 裁决门（开始前置；逐条 = 问句 / 影响 / 本计划推荐 / 未取裁时的行为）

> 纪律继承 P6：未取裁的项一律不实施；不得把推荐方案当作裁定；凡「先裁」项，限制写进任务卡正文（P6 事故 第 7 节-1 的教训）。

| # | 问句（逐条照抄给维护者） | 影响 | 本计划推荐 | 未取裁时 |
|---|---|---|---|---|
| 裁-FC-1 | `check` 面与 `build` 面是否用同一检查？(A) 现状（check 严 / build 宽）+ 本批只反转 build 面；(B) 两面同检查同表（check 也走豁免表，因此 72 档 rc 分布换代、parity 基线更新基准值）；(C) 两面同检查但豁免表带生效范围字段（`build`/`check`/`both`），初始绝大多数条 = `build` 范围，所以 check 基线不动。 | 表 0 全行；72 档 + 探针两条对比检查的可用性 | (C)（同机制、显式登记差异、check 基线无影响；(B) 会让 ≈25 档 rc 1 改为 0，parity 检查从「零差异」退化为「大面 diff」，丧失回归检查价值） | 按 (A) 执行：只动 build/ccr/cir/run 四面，check 不动；差异显式登记 |
| 裁-FC-2 | 豁免表的实现方式与粒度，以及软面码（TM04）的处置：(a) 粒度 = 码级 / 码×语料位点级（`file:line`）/ 码×范围级；(b) 实现方式 = 源码内静态表（照 `corearch.cr` 的 `g_instance_decl` 表先例）/ 仓库配置文件 / CI 允许清单；(c) 换代纪律 = 只减不增 + 撤除须带根因证据 + 新增须维护者批？(d) TM04 是登记豁免还是改为真 warning 通道（`warning[...]` 前缀，不阻断）？ | T3 的实现形态与全批的「豁免可审计性」 | (a) 码级 + 位点列作证据字段（位点级更窄但脆弱：语料一行变化即失效；码级简单但允许同码在别处不报错地，因此用「每次开新面必重运行 report-only」补偿）；(b) 源码内静态表（Core 无配置文件读取面、CI 不运行本地检查）；(c) 只减不增；(d) 登记豁免（引入 warning 通道 = 新诊断类别，超本批章程） | 表形态 = 源码内 `code 到 {scope, locus, reason}` 静态表；TM04 登记豁免 |
| 裁-FC-3 | B004（`ptr_arith.cr:12:8`）与 ELF canary 硬性检查的冲突：B004 纳入检查，因此 canary 不可产。三选一：(i) 修 B004 假阳性（实现末次使用/NLL 级借用收缩，语义变更，工作量未估）；(ii) 登记豁免 B004（canary 保住，但「check rc=1 / build rc=0」的活证据继续存在）；(iii) 换 canary 实现方式（检查换代：canary sha 全链作废、须重建允许清单与全部历史比对基线）。 | ELF canary 检查（本批硬性检查）+ suite job | (ii) 本批登记豁免 + 同批开 TODO 条目把 (i) 立为独立批（(i) 是语义变更不是检查变更；(iii) 代价 = 检查换代，不能由实施者自裁） | T5 不实施 B004 阻断；B004 豁免条目标「退出条件 = 借用收缩实现」 |
| 裁-FC-4 | 命中语料（≥7 档）的处置：TF01×5（并发族）/ TF07×1（`ptr_ref_first`）/ B04×1， 修前端假阳性 / 修语料（删除或改判负例）/ 登记豁免？（修语料涉 `tests/` 面改动，且 `tests/suite` 是 CI 正例集；改 neg 例会动 `run.sh:36-54` 的 SKIP 语义） | CI `suite` job 变为失败面 | 先逐档归因（T1）再判：真误报，因此修前端（照 P6 TF01 清理批先例 `p3-task3-report`/TODO #2026-09-13-1）；真错误，所以语料归为负例（照 `*_mini*` SKIP 先例，须维护者批）；本批不预判 | 全部登记豁免 + CI 保持绿；修复批次另立 |
| 裁-FC-5 | 与 P6 待裁项的接口：(a) 本批是否即为 裁-P6-2(b)（非硬名单诊断收紧）与 (c)（纳入检查成文化）的最强形式？若维护者只取 (b) 的「`build` 面汇总告警」档（不阻断），本批降级为 report-only（T3 只落采集器、不落检查）；(b) 裁-P6-2(d)（`*T ← 0/None`）/(e)（`--verify-named-dedup`）与本批无耦合（(d) 是规则语义、(e) 是调试通道），本批不动，确认？ | 全批章程 | (a) 取最强形式（否则本批无对象）；(b) 确认无耦合、不动 | 本批降级为「report-only 常设」：T3 落采集器 + 清单，不反转默认检查；命中表交维护者处置 |
| 裁-FC-6 | 「零产物」的边界：失败时 (a) 是否删除本次写入的 `<out>.ccr`（`main.cr:678` 写在 `corearch` 之前，因此 corearch 失败即留半成品；纯静态路径的 ELF 在 `ctx_emit_static` 末尾一次性写（`ld.cr:525-529`），本身不留半成品）？(b) `.core/cache/cir/*.cir` 过程缓存与 `.core/cache/cir/` 目录（`main.cr:473`）是否算产物？ | T5 的实现面 | (a) 删除（仅限本次 `save_ccr` 成功且 `corearch` rc≠0 的路径；已存在的旧产物不动，不删用户文件）；(b) 登记为约定豁免（过程缓存非交付产物；且 frontend 检查在 IR gen 之前，所以检查触发时不产生任何缓存） | 按推荐执行（不外扩删除面） |

---

## 任务总表（本批实施面；状态一律「待实施」，完成按实测回填）

| 任务 | 内容 | 依赖 |
|---|---|---|
| T0 | 前置侦查 + 固定基线重建（P6 终态 `97f4394f`）+ 起点检查（表 B）+ 基准点实核（表 D）+ 维护者裁定原文核录（源码零改动） | — |
| T1 | 全语料 report-only 基线（核心产物）：`tools/baseline/build_gate_run.sh` + 命中清单 + 逐档归因表（零源码改动，用现有二进制） | T0 |
| T2 | 分类表定稿 + 豁免表草案 + 裁决门提交（零代码） | T1 |
| T3 | 检查反转 + 豁免表 + 隐藏 report-only 通道 + 采集器（默认关） | T2 + 裁-FC-1/2 |
| T4 | 命中面处置（逐条：修根因 / 修语料 / 登记豁免）+ 新套件 | T3 + 裁-FC-3/4 |
| T5 | 启用（默认全阻断）+ 零产物语义 + CI 面同步 | T4 + 裁-FC-6 |
| T6 | 完成：全量回归 + 检查复验 + 统一清单 + 文档 + 批终态 | 全部 |

顺序理由：T1 必须先于一切（先量后改：本批最大风险 = 一次改动让大量既有语料变为失败）；T2 的取裁决定 T3 的实现形态（同检查 vs 单面、豁免粒度）；T4 依赖 T3 的采集器做二次核对；T5 的启用是单点改变（默认值一行），其检查全在 T1–T4 的证据链上。

---

## Global Constraints（照 P6 简版）

- 版本控制与提交：一律使用 `jj`，禁 git（含只读调用与复合调用）。提交路径限定（多 agent 在场时，一律以 `jj commit -m … <paths>` 形式提交）。所有命令以 `nice -n 19` 运行。构建与编译串行执行，每段之前以 `ps` 实查。cwd 恒为仓库根（`/tmp` 作为 cwd 会触发 import 解析假失败）。
- 基线纪律：每个任务开始前先取同任务起点基线（binary sha + 语料 rc 表 + 探针 rc 表），不得沿用上一任务的计数。固定基线由 `tools/baseline/rebuild.sh` 重建，方法见 `tools/baseline/REBUILD.md`，内容为 pinned revision + 三 sha 允许清单。P6 终态的允许清单值须由 T0 实核后落表：P6 期的允许清单 = P4 完成 `9bcb7083` 的产物，不是本批基线，因此本批须以 P6 终态 revision 重建并新锁允许清单。
- ELF canary（硬性检查，全批）：命令序列 = `clean-cache` 改为 `build tests/suite/ptr_arith.cr --static`，检查值 = sha256 `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`（28822B）。本批的 canary 语义有变体：T5 启用后若 B04 豁免生效，canary 应逐字节同（豁免 = 不阻断，发射面零变化）。若 canary 不可产，因此立即停下，该信号等价于裁-FC-3 未取裁或取 (i)/(iii)。
- 发射面声明（本批必须显式声明）：本批声明发射面零变更（检查 = 前端 rc 语义，不触 `ir_gen`/`lower_to_ccr`/`emit`）。任何 canary/`--dump-objects`/`.ccr` 逐字节差异，因此停下（越界信号）。
- `.ccr` 记录值引用约定（D28 继承）：引用记录值一律带命令形式（`corec ccr F -o O` vs `corec build F -o O --static`，差恒 143B），并带缓存态（冷/热；非可选程序的空缓存状态不等于热态属预存豁免）。比较任何 `.ccr`/缓存态产物之前先执行 `clean-cache`。
- 检查标准按 TODO #2026-09-11-9：不采用「与旧版逐字节同」当语义证据；本仓主要检查 = 结构性断言 + 语义零变化 + 自举稳定。「≥N 例」表示下限（可增不可减）；自测用例只增不减（重新固定/改名允许，删除须给删除依据）。
- 三态纪律（不得稀释）：引擎 -1 不得当 0/1 用；载入失败/段缺失/行不可译/项不可建，因此拒绝。新硬错先 report-only：本批新增的任何 rc=1 门（含检查反转本身）必须先在全语料上 report-only 运行一遍，清单审查后才启用；全语料 = 72 档 + `tests/selfhost` 内联源 + `src/stdlib` + `examples` + `src/compiler` 自指 + 58 套件全枚举。
- 清单三面同核（B.6，硬性）：任何清单/段表改动必须三面同核，即 `build_selfhost_native.py`（`corec_files`/`corearch_files`/`corelsp_files`）↔ `src/targets/x86_64-linux/_import.cr` ↔ `src/compiler/_import.cr`。每任务回归面必含 `tests/selfhost/test_backend_bootstrap.py`（检查 = rc=0 + 构建日志 `error[` = 0）。本批新增的 runner/语料（`tools/baseline/*`、`tests/probes/*`）不进任何编译清单。
- 不得回退既有收纳：TS01-04/TK02 硬门（#29）、TM03/TG02 门（#31/#33）、F2 常量档拒绝语义与「N 不回身份」、F5 槽位契约（#25/#28）、效应/纯度检查（#26/#27）、`iface_satisfies` 轴序 A>C>B、P4 全批、P5 全批（ICE04/TA02/影子下线）、P6 全批（β/¬ 面/never/文档），一律不动；冲突时停下上报。
- 语言面约束：本语言无三元运算符；取模须非负；键比较不得依赖 i64 回绕；启用 noclobber（`>|`）；不写 `buf == 0` 形态的空判（string-int 混比在 bootstrap 侧编成 `str_eq`，因此自崩）。bootstrap 构建的 corec 对 `&&`/`||` 两侧无条件求值，所以不得写 `guard && 表读`（先例见 `p6-task4-report.md` 第 3 节：须嵌套 `if`）。
- 多 agent 纪律：不并发构建；提交路径限定；实施时逐任务串行；突变控制一律在仓库外实拷贝（`tests/` 必须实拷贝而非软链）。

---

## 起点基线值（P6 终态记录值；本计划未复测，出处逐条标注）

| # | 项 | 值 | 出处 |
|---|---|---|---|
| 1 | 72 档 `check` rc 分布 | 34×0 / 38×1（含 2 档 0 字节 fixture `test_generics.cr`/`test_control_flow.cr`、P21 嵌套 fn 负例 `at_test_mini4/6.cr`、examples 两档解析错 `test_scale.cr`/`test_sum.cr`，不得当回归） | P6 T0 第 3.1 节（`/tmp/p6t0/corpus_rc.txt`） |
| 2 | 五 CI job | 全 rc=0 | P6 T6 “Step”节 1 |
| 3 | `check src/compiler` | rc=0（零诊断；P6 TF01 清理批后成立，#40） | P6 T0 第 2 节#2 / P6 T6 |
| 4 | `selftest-types` | 415/415 | P6 T6 “Step”节 1（T5 收紧 `MIN_CASES=415`，`test_type_engine.py:20`） |
| 5 | ELF canary | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`（28822B） | P6 T0 第 2 节#7 / P6 T6 |
| 6 | 自举链 | `corec2 == corec3` IDENTICAL（`0b2e06d0c8b2f78402d08950364fb224db697fdf2e5b6e5d0d6a06e85fc581c1`）+ N06=0 + 快速验证 42 + `--help` rc=1 | P6 T6 “Step”节 2 |
| 7 | `.ccr` 两种形式四条（空缓存状态） | `ptr_arith` 96015B `680a6f98…` / 96158B `76f36e6a…`；`generics_test` 142793B `41e9d845…` / 142936B `704316c8…`；差恒 143B | P6 T3 新基准值（P6 T6 “Step”节 2 复验） |
| 8 | 全枚举 | 58/58（51 selfhost + 7 bootstrap） | P6 T6 “Step”节 1 |
| 9 | 探针 29 档 | rc 17×0 / 12×1（12 档为故意负例） | `tests/probes/README.md:58` |
| 10 | `--dump-objects` / `.cir` DOT | 3521 行 / 165915B `b1bdf480…` | P6 T6 “Step”节 2 |
| 11 | 固定基线三 sha（P6 期允许清单，本批须重建换锁） | `5d2b15ad…` / `493dc490…` / `18b94bd9…` | `tools/baseline/REBUILD.md` |

---

## Task 0：前置侦查 + 固定基线重建 + 基准点实核（源码零改动）

Files: 无源码改动。产物 = 报告 `docs/archive/sdd/fc-task0-report.md`（工作区，不入提交）+ 重建的固定基线 `/tmp/fc0/base/{corec,corearch,corelsp}` + 清点原始输出（`/tmp/fc0/`）。

Interfaces（产物四表，数字一律实测；未实测标「待实测」）：

- 表 A：固定基线重建。做法 = `tools/baseline/rebuild.sh`（或等价手运行方法：`jj workspace add --revision 97f4394f` 改为 `nice -n 19 python3 build_selfhost_native.py`），产出三 sha 的新锁允许清单（写入本任务产出的 `REBUILD.md` 换代记录）。同时做构建 ×2 取确定性，并做快速验证 42。
- 表 B：本批起点检查基线。起点基线值表 1–11 项逐条重新运行（五 CI job / 全枚举 / `check src/compiler` / `selftest-types` / 构建确定性 ×2 / 自举链 / canary / `.ccr` 四条 / `--dump-objects` / `.cir` DOT）。
- 表 C：语料清点（本批的新增面）。含三项：1 72 档逐档清单 + rc；2 build 面语料全集，`tests/suite` 实 build 档（`run.sh:36-54` 语义实际运行逐档计数）、`src/compiler/main.cr --static -O 0`、canary 档、`.ccr` 两档、`tests/selfhost/*.py` 内 `build` 调用逐处清点（含内联源去重）、`examples/*.cr`；3 探针 29 档。
- 表 D：基准点实核。本计划「Tech Stack」「表 0/1/2」的每个 `file:line` 逐条实读复核（行号变化以本轮实读为准，变化逐条写进文档）。
- 表 E：裁定原文核录。向维护者核一句「fail-closed 方向已裁」的原文/出处（来源 = 协调者转述）；无原文，因此本批章程不成立，所以停。

- [ ] Step 1: 基线重建。检查：三 sha 与新允许清单逐条同 + 快速验证 42 + 构建确定性 ×2（日志逐字节同）。不符，因此停下上报。
- [ ] Step 2: 起点检查（表 B；cwd = 仓库根、逐段 `ps` 实查无并发、比较前 `clean-cache`）。
- [ ] Step 3: 语料清点（表 C；`ls`/`find`/`grep -c` 实核，逐类计数）。
- [ ] Step 4: 基准点实核（表 D）。
- [ ] Step 5: 裁定原文核录（表 E）。
- [ ] Step 6: 报告（不入提交；`jj status` 收工为空）。

检查：五表齐 + 基线三 sha 逐条同 + 源码零改动（`jj status` 干净）+ 报告内数字全部可追溯（命令 + 原始输出片段）。

停条件：1 重建 sha 不可复现，因此停下（检查失效）；2 表 E 无原文，所以停下（本批方向性背书缺失）；3 表 B 任一项与上表记录值不符且无法归因，因此停下（起点变化，所以后续所有对比无意义）。

---

## Task 1：全语料 report-only 基线（核心产物；零源码改动）

Files: New `tools/baseline/build_gate_run.sh`（build 面采集 runner：逐档 `clean-cache` 改为 `build`，再 记 rc/日志/产物 sha；不新增任何二进制入库）· New `docs/archive/sdd/fc-task1-report.md`（工作区）· 证据 `/tmp/fc1` 下全部文件。零 `.cr` 改动、零检查改动。

Interfaces：
```
tools/baseline/build_gate_run.sh <corec二进制> <outdir>
  # 语料 = 显式清单（照 probes_run.sh 先例：`shopt -s nullglob` + 计数硬断言，杜绝字面 glob 伪条目）
  #   t1  suite 实 build 档（run.sh 语义：排除 *_mini*.cr 与空文件）
  #   t2  src/compiler/main.cr --static -O 0（full-bootstrap 统计标准）
  #   t3  canary 档（tests/suite/ptr_arith.cr --static）+ .ccr 检查两档（ptr_arith/generics_test，ccr 与 build 两种统计标准）
  #   t4  tests/selfhost/*.py 的内联源（由各套件自跑：本 runner 不重造，改为采集各套件日志，
  #        实现 = 58 套件枚举 + `grep -oE 'error\\[[A-Z0-9]+\\]'` 聚合）
  #   t5  examples/*.cr（check 面 + build 面各一遍）
  # 产物： <outdir>/hits.tsv（列 = tag | path | face(build/check) | rc | 码集合(去重) | 首条诊断 file:line | 产物 sha256|缺失）
```
- [ ] Step 1: 采集 runner 入仓（显式清单 + 计数断言 + cwd = 仓库根）。检查：运行一遍 rc=0 且 `hits.tsv` 行数 = 清单计数；与手工抽查逐档一致。
- [ ] Step 2: 采全量命中清单（现有二进制；build 面 + 58 套件枚举）。检查：每档给（rc, 码集合, 首条 `file:line`）；与 P6 T0 第 3.1 节的 check 面 rc 分布交叉核对（build 面 rc 应 ⊇ check 面 rc=1 档的子集语义，逐档差异须能归因到「该码是否在 11 码名单内」）。
- [ ] Step 3: 逐档归因表（表 2 的「变为失败面」列写进文档）：每档 = {码，再 归因（真错 / 假阳性 / 语境缺失 / 政策软面），再 处置建议}。检查：无「未知/待查」行（不能归因的档 = 停条件下上报）。
- [ ] Step 4: 变为失败面汇总：给「全阻断后 CI 五 job 各红几档 + canary 是否可产 + `.ccr` 四条是否可产」的逐 job 表。
- [ ] Step 5: 报告（不入提交；`jj status` 收工为空）。

检查：`hits.tsv` 与归因表齐备 + 每一行的归因有证据（命令 + 原始输出片段）+ 零源码改动。

停条件：1 命中面过大，因此转独立批（阈值：build 面变为失败档 > 10 档 或 > CI `suite` job 实 build 档的 1/3，或任一 CI job 出现「无法用登记豁免保住」的档），所以停，出「转独立批」建议书（含命中面全表）交维护者；2 归因表出现「无法判定真/假」的档，因此停下上报（不得猜）；3 采集 runner 与手工抽查不符，所以停（仪器失真）。

---

## Task 2：分类表定稿 + 豁免表草案 + 裁决门提交（零代码）

Files: Modify 本计划（把 T1 实测值回填表 1/表 2 + 落「豁免表草案」节）· 报告 `docs/archive/sdd/fc-task2-report.md`。

Interfaces（豁免表草案的逐条字段，本任务定稿后交维护者）：
```
{ code,            // 码常量（如 EC_B_USE_WHILE_BORROWED）
  scope,           // build | check | both（裁-FC-1）
  locus,           // 证据位点清单（如 tests/suite/ptr_arith.cr:12:8），证据字段
  reason,          // 为何不是真错误（假阳性机制 / 政策裁定 / 语境缺失）
  exit,            // 退出条件（撤除检查：根因修复 / 语料转负例 / 政策改判）
  hit_count,       // T1 实测命中档数
  owner_task }     // 归属（本批 T4 / 独立批）
```
- [ ] Step 1: 表 1 回填（32 码的「72 档命中 / 套件命中」两列由 T1 实测值替换「须 T1 实测」）。
- [ ] Step 2: 豁免表草案（≤10 条；每条六字段齐；无 `reason` 或 `exit` 的条目不许入表）。
- [ ] Step 3: 裁决门提交（裁-FC-1..6 逐条照抄问句；附 T1 的变为失败面逐 job 表作事实输入）。检查：六问全部有明文答复（口头/转述不计，照 P6 `p6-task4-report.md` 第 6 节的「协调者已裁」需写进文档的先例，须维护者本人答复）。
- [ ] Step 4: 报告。

检查：表 1 无占位符 + 豁免表每条六字段齐 + 六问答复写进文档（含「不裁则按未取裁分支执行」的显式声明）。

停条件：1 任一裁-FC 的答复与 T1 的事实冲突（如裁「不豁免 B04」但 T1 证 canary 依赖它），因此停下重报；2 豁免表条目 >10 条，所以触 T1 停条件1（转独立批）。

---

## Task 3：检查反转 + 豁免表 + report-only 通道（默认关）

Files: Modify `src/compiler/main.cr`（`:146-179` 的硬名单块反转为「默认 `hard = 1` + 豁免表查询」；新增隐藏旗标 `--diag-gate-report`（默认关，照 `--verify-named-dedup` 同址同式，注册面 = `main.cr:249`，消费面 = `main.cr:196`））· Modify `src/compiler/globals.cr`（豁免表数据 + 只读访问器；若表需要跨文件可见，变量/常量跨文件按声明序可见）· New `tests/selfhost/test_fail_closed.py`（≥12 例，下限）· Modify `src/ci/run.sh`（selfhost-tests 接入点 + 计数注）· Modify `docs/error-codes.md`（判定面表）· 报告 `docs/archive/sdd/fc-task3-report.md`。

Interfaces：
```
// 豁免表（形态 = 源码内静态表；实现方式与粒度按裁-FC-2）
// 行 = {code:i32, scope:i32, reason_ni:i32}（± locus 字段）
// 查询 = diag_gate_exempt(code, scope) -> int（1 = 豁免；0 = 阻断）
// 检查（main.cr 原硬名单块处）：
//   hard : ., mut = 1;                              // 反转：默认阻断
//   loop { ec := …; if diag_gate_exempt(ec, GATE_BUILD) != 0 { hard = 0 的逐条语义 } }
// 注意语义：任一未豁免诊断，因此 hard = 1（不是「全部豁免才 1」）
// 因此实现 = hard = 0 起始；出现未豁免诊断即 hard = 1；break/或全扫后判定（保诊断打印顺序）
// 报告通道（默认关）：--diag-gate-report，因此打印一行机器可读标记：
//   [diag-gate] face=build codes=B04,TF01 would-block=1 n_diag=3
```
- [ ] Step 1: 表 + 查询函数 + 单测（红）：`test_fail_closed.py` 机制面（≥6 例：默认阻断 / 豁免命中不阻断 / 多诊断混合（一豁免一未豁免，因此阻断）/ 空名单 / 双面 scope / 越界码）。
- [ ] Step 2: 检查反转（落点 = `main.cr:146-179`；嵌套 `if`，不得写 `&&` 串表读；只改 rc 判定，不改诊断产生与打印）。检查：单测绿 + 全语料 report-only（Step 3）零意外。
- [ ] Step 3: report-only 全语料（`--diag-gate-report` + T1 的 runner 与 58 套件枚举），因此产 `would_block.tsv`。检查：与 T1 `hits.tsv` 逐档逐码一致（差异逐条归因；任何未在豁免表内的命中，所以停下）。
- [ ] Step 4: 行为面用例（≥6 例）：真错误 build，因此 rc=1 + 无产物（`<out>` 与 `<out>.ccr` 均不存在）；豁免码 build，所以 rc=0 + 产物在 + ELF 可运行；`check`/`cir`/`ccr`/`run` 四面各自同检查验证；级联（多诊断混合）。
- [ ] Step 5: 检查（硬性检查）：ELF canary IDENTICAL · `.ccr` 四条 = P6 T3 值 · `--dump-objects` 3521 行 · `.cir` DOT 165915B · 五 CI job rc=0 · 全枚举 58/58 · `check src/compiler` rc=0 · `selftest-types` ≥415 · 自举链 · 72 档对比零差异 · 探针 29 档零差异 · `test_backend_bootstrap` rc=0 + `error[`=0 · 突变控制 ≥3（M1 豁免表清空，因此命中档全部变为失败；M2 默认值反转回 0（不阻断），所以未豁免码不报错地通过（变为失败 = 本批要消除的形态复现）；M3 单条豁免删除，因此对应档变为失败）+ 精确回滚。
- [ ] Step 6: 提交：`feat: fail-closed 检查，默认全阻断 + 豁免登记表 + report-only 通道（默认关；发射面零变化）`。

停条件：1 report-only 出现豁免表外的命中，因此停下（清单不完整）；2 任一 canary/`.ccr`/`--dump-objects` 变化，所以停下（发射面泄漏）；3 默认关路径下任何既有检查发生变化（rc/日志/产物），因此停下（本任务应零行为变化）；4 裁-FC-1 未取裁，所以只落 report-only 通道，不落检查（Step 2 跳过）。

---

## Task 4：命中面处置（逐条：修根因 / 修语料 / 登记豁免）

Files: 按 T1 归因表逐条定；预期面 = `src/compiler/checker.cr`（若修前端假阳性：如 TF01 并发族、TF07 `@raw_int` 位、B004 末次使用）+ `tests/suite/*.cr`（若语料转负例，须裁-FC-4 批准）+ `src/ci/run.sh`（SKIP 语义若改）+ `tests/selfhost/test_*.py`（重新固定）+ 本计划（豁免表终稿）。

- [ ] Step 1: 逐条归因复核（每条：RED 复现，再 固定基线复证，再 机制定位，再 处置判定）。检查：每条有 `file:line` + 触发语料 + 机制。
- [ ] Step 2: 假阳性根因修复（照 P6 TF01 清理批先例：`stmt_cannot_fall_through` + `lits_copy` 类型归一，TODO #2026-09-13-1）。检查：修复后该码在全语料零命中 + 原用例变为通过 + 反例仍然失败（强负控）。
- [ ] Step 3: 语料处置（仅限裁-FC-4 批准面）。检查：语料改动逐条有维护者批复 + 语料只增不减纪律的例外声明。
- [ ] Step 4: 豁免表终稿（撤除已修条；每条保留 `exit` 条件）。检查：表内条目全部有 T1 实测命中支撑（不得有空条）。
- [ ] Step 5: 检查：同 T3 Step 5 全套 + 命中档逐档变为通过（或登记明确）的对照表。
- [ ] Step 6: 提交（按处置分批；路径限定）。

停条件：1 修假阳性过程中发现语义变更面（如 B004 的借用收缩），因此停下（超本批章程，转独立批）；2 语料处置超出裁-FC-4 批准面，所以停下；3 命中档在修复后仍然失败且未登记，因此停下。

---

## Task 5：启用（默认全阻断）+ 零产物语义 + CI 面同步

Files: Modify `src/compiler/main.cr`（检查默认值/表终稿；零产物：`corearch` 失败路径删本次 `<out>.ccr`，落点 `:702` 附近，`exit_code != 0` 分支）· Modify `src/ci/run.sh`（若 CI 需承认新语义：如 suite job 对已知豁免档的注释块 + 自述）· Modify `docs/error-codes.md`（判定面/检查语义成文化）· Modify `TODO.md` · Modify 本计划（实施记录）。

- [ ] Step 1: 启用（裁-FC-5 取最强形式时；默认全阻断生效）。检查：`hit` 档的 build rc 由 0 改为 1（逐档对照 T1 表），而豁免档 rc=0 且产物逐字节同（canary/`.ccr` 四条为证）。
- [ ] Step 2: 零产物语义（裁-FC-6）。检查：新套件断言，失败路径 `<out>` 与 `<out>.ccr` 均不存在；已存在的旧产物不被删除（前置造一个旧文件 + 触发失败，因此旧文件仍在）；`.core/cache/cir/` 约定写进文档。
- [ ] Step 3: CI 面同步（`run.sh` 注释/自述；若需新 job 或新接入点，走三面同核）。检查：五 CI job rc=0 + 全枚举 58/58。
- [ ] Step 4: 检查（硬性检查）：canary IDENTICAL · `.ccr` 四条 = T3 值 · 全枚举 · selftest-types ≥415 · 自举链 · 72 档对比换代后的期望值（若裁-FC-1 取 (B)/(C)，此处须给新期望分布 + 逐档归因）· 探针 29 档 · 突变 ≥3 + 精确回滚。
- [ ] Step 5: 提交：`feat: fail-closed 开门，默认全阻断生效 + 零产物语义（豁免表 N 条；发射面零变化）`。

停条件：1 CI 任一 job 变为失败且非豁免表覆盖，因此停下；2 canary 变化，所以停下；3 零产物断言在失败路径先于 `save_ccr`（前端检查）与后于（corearch 失败）两种形态任一处不成立，因此停下。

---

## Task 6：完成（回归 + 检查 + 清单 + 文档 + 批终态）

- [ ] Step 1: 全量回归（cwd = 仓库根、`nice -n 19`、串行、比较前 `clean-cache`）：五 CI job；全枚举 58/58；`check src/compiler`；`selftest-types`；构建确定性 ×2。
- [ ] Step 2: 检查复验：重建基线（T0 允许清单）× 同源对比（72 档）· 探针全集 · build 面采集器（T1 产物）重新运行，因此命中面 = 豁免表（逐条等式检查，本批的核心不复现性检查）· canary · 自举链 · `.ccr` 四条 · `--dump-objects` · `.cir` DOT。
- [ ] Step 3: 统一清单：逐任务列 {实施 / 收紧 / 豁免 / 修复 / 语料处置 / 登记 / 偏差}，与各任务实际 diff 逐条对应；豁免表终稿（含每条 exit 条件）单列一节。
- [ ] Step 4: 文档：`docs/error-codes.md`（判定面语义 + 检查机制 + 豁免表指针）· `CLAUDE.md`（若新增 `tools/baseline/build_gate_run.sh` 或新套件，因此相应节补一行；`.cr` 清单无变化则不写）· `TODO.md`（Fail-closed 条目 + 转独立批登记 + 豁免退出条件追踪）· 本计划实施记录。
- [ ] Step 5: 批终态陈述（一页）：「已实施 / 已豁免（含退出条件）/ 剩余登记 / 下一批指向」四栏。
- [ ] Step 6: 提交（路径限定）。

检查：五 CI job + 全枚举 + canary + 自举链 + 同源对比 + 探针 + 命中面=豁免表的逐条等式 + 清单逐条可溯源 + 文档指针链完整。

---

## 风险面（本批最大风险 = 一次改动让大量既有语料变为失败）

| # | 风险 | 缓解（硬要求） |
|---|---|---|
| R1 | 变为失败面超预期（套件 job 7 档 + 49 档 py 内联源的未知命中面） | T1 先量后改（零源码改动采清单）+ T2 逐档归因 + 停条件「>10 档 / >1/3，因此转独立批」+ 分批启用（批次 1 = 全豁免保绿，批次 2..n 只减不增） |
| R2 | ELF canary 不可产（B04 命中 canary 实现方式） | 裁-FC-3 三选一（本批推 (ii) 豁免）+ T5 检查「canary 不可产，因此立即停下」 |
| R3 | 豁免表变成新的不报错地面（码级豁免在别处不报错地通过） | 表只减不增 + 每条 `exit` 条件 + 每次开新面必重运行 report-only + 清单单列一节 + 突变 M2/M3 配合 |
| R4 | 两面语义分歧长期化（check ⊃ build） | 裁-FC-1 + 表 0 成文化 + `docs/error-codes.md` 记明差异 + CI 自述块 |
| R5 | 零产物语义误删用户文件 | 只删本次写入的 `<out>.ccr`（`save_ccr` 成功后 + `corearch` rc≠0）；旧产物不动；用例覆盖 |
| R6 | 检查失效（若取「两面同检查」，72 档/探针两条对比检查的「零差异」检查换代） | 裁-FC-1 推荐 (C)；若取 (B)，因此先出「新期望分布 + 逐档归因」再启用 |

---

## 未决项与登记（不猜）

- U-1（维护者裁定原文）：本批的章程前提 = 「要改、方向 = fail-closed」，来源 = 协调者转述，无独立文件实现方式，因此由 T0 表 E 核录；无原文则本批停在 T2。
- U-2（测试面 `check` rc 分布 vs `build` 面）：72 档 runner 只运行 `check`（`parity_run.sh:36`），build 面无既有 runner，因此 T1 必须新建（`build_gate_run.sh`）；「命中面」的完整定义在本批首次建立。
- U-3（安全检查面的反向不一致）：`region_check`/`provenance_verify` 只在 build/ccr 面运行，因此存在「check rc=0 / build rc=1」档（本实例未构造具体语料），所以由 T1 实测登记（不得当已知事实引用）。
- U-4（TM04 的打印前缀）：现行以 `error[TM04]` 打印但语义声明为软面（`main.cr:159`），因此 「报错即拒」与「软面」字面冲突，所以交裁-FC-2(d) 处置。
- U-5（≈104 个「定义零 raise」码）：`ast.cr` 定义 ≈146、可达 42，因此其余为未使用代码面（本批不删、不改、登记；删除属独立决定，照 `tools/module_to_ccr.py` 的「只标废弃不删」先例）。
- U-6（LSP 面）：`src/lsp/lsp.cr` 消费 `g_diag_count` 但不产生产物，因此 fail-closed 不适用（表 0 登记）。
- 登记维持（不做，理由固定写明）：`EXPR_FOR` 元素类型恒 int（E-6/裁-P6-4）· `.csr`/TagNode（验证切片轮）· 容量批（E-2/E-3/E-4）· `string == int` 混比（裁-P6-3）· `--verify-named-dedup` 保留（裁-P6-2(e)）。以上各项本批一律不动。

---

## 自检记录

- 本计划的自身限制（诚实登记）：本计划未运行任何构建/测试/`jj` 命令。所有「现状值」= 实读源码/文档或既有报告记录值（出处逐条标注）。需实测的数字（基线重建 sha、build 面命中清单、套件面命中档数、变为失败面逐 job 计数）一律留给 T0/T1 的实测步。
- 判定面清点的诚实性：「42 可达码」的得出方式 = 全仓 grep 三形态（`check_error(EC_*` / `diag_type_incompatible(…, EC_*` / `DIAG_REC_SIZE, EC_*`）去重实得 43，再减 1 个假命中（`EC_SIZE` 为 `DIAG_REC_SIZE` 子串）；未把「源码注释/文档统计」当作实测（`docs/error-codes.md` 的 ~146 为文档自述值，已标出处）。分类的 7 条豁免全部带命中证据或政策出处；其余 25 条阻断全部按「判定继续，因此不报错地错产物 / 不可信」检查成文（裁-P6-2(c) 约定），未用一个「大概/应该」。
- 根因 vs 临时修复：检查反转直达根因（默认允许是缺失本身，不是名单不全）。豁免表被明确设计为临时面（每条带 `exit`），配合只减不增与每次开新面重运行 report-only，防止其退化成语义黑洞。
- 与既有裁决的一致性复核：不回退 TM03/TG02（#31/#33）、TS01-04/TK02（#29）、ICE04（P-A）、TA02（#32）、F2/R002（先例即纳入检查依据）；TM04 的「软面」裁定经裁-FC-2(d) 显式处置（不得由实施者私自改判）。
- 占位符扫描：无 TBD；「须 T1 实测」逐处给出测量命令或产物格式；六条裁决门逐条点名问句，未把推荐当作裁定。
- 本批最大风险（一句话）：一次反转会让 CI `suite` job 至少 7 档（TF01×5/TF07×1/B04×1）与 ELF canary 实现方式同时变为失败，而 canary 实现方式 `ptr_arith.cr` 自身就是 check rc=1 档，因此不先取裁-FC-3，本批无法启用。

---

