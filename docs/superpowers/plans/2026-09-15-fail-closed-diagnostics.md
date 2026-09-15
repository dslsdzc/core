# fail-closed 判据线实施计划：报错即拒（默认全阻断 + 豁免登记表）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 兑现**维护者已裁「要改」的方向 = fail-closed**：把编译器语义收敛到「**报出错误 ⇒ `rc=1` 且不产生产物**」，消灭「诊断照打、二进制照出」的静默错产物类。机制 = 把 `src/compiler/main.cr` 的**硬名单闸反转为「默认全阻断 + 已知命中面豁免登记表」**（现行正向名单 ⇒ 默认 `hard = 1`，豁免表 = 白名单：码 + 语料位点 + 理由 + 生效范围）。**全批纪律：新面 report-only 先行、命中清单审查后才开门；命中面过大 ⇒ 转独立批（停条件）。**

**Architecture:** 六条主线：① **前置侦查 + 冻结基线重建 + 锚点实核**（T0，源码零改动）；② **全语料 report-only 基线（核心产物）**（T1：用**现有二进制**在 build 面语料上采全量命中清单——现有 `check` 面已是 fail-closed 闸，是天然仪器，**零源码改动**即可产出清单）；③ **分诊表定稿 + 裁决门取裁**（T2，零代码）；④ **闸门机制实现 + report-only 开关**（T3：反转 + 豁免表 + 隐藏旗标 + 采集器）；⑤ **命中面处置**（T4：逐条归因——修根因 / 修语料 / 登记豁免）；⑥ **开门 + 零产物语义 + 回归收官**（T5/T6）。

**Tech Stack / 锚点（本实例实读，行号 = 当前工作树）：** 闸门三处 + 一处已收紧面——① **语法面闸**：`src/compiler/main.cr:134`（`parse_all()` 后 `g_diag_count > 0 ⇒ print_diagnostics(); return 1`）+ `:135`（`g_error_count > 0 ⇒ print_parse_errors(); return 1`）；② **类型面闸（本批的对象）**：`main.cr:146-179`（`if g_diag_count > 0 { 硬名单扫描 }`；**6 条语句行** `:152`/`:153`/`:154`/`:160`/`:166`/`:174` 覆盖 **11 个码常量**；`if hard != 0 { return 1; }` 在 **`:178`**）；③ **安全检查面闸（已 fail-closed）**：`main.cr:594-603`（`base_diags` 快照 → `ptr_analysis_all()` / `region_check_all()` / `provenance_verify_all()` → `g_diag_count > base_diags ⇒ return 1`，**无码过滤 = 任意诊断阻断**）；④ **`check` 面闸（已 fail-closed）**：`main.cr:443-451`（`if g_diag_count > 0 { return 1; }`）。
其余落点：`main.cr:399-402`（`run` 走同一 `run_frontend` 闸）· `:431-438`（`--static` 前置 `rt.cr`）· `:440-441`（`fe_rc` 唯一入口）· `:473`（`make_cir_cache_dir`）· `:565-591`（`cir`，**不过**安全检查面）· `:620-662`（`ccr`）· `:665-703`（`build`：`:671` `.ccr` 路径 / `:674-679` `save_ccr` / `:682-702` 拼 `corearch` 命令行并 `system()` / `:702` `return exit_code`）· `diag.cr:122-150`（`print_diagnostics`，码面 = `cat = ec/1000` + `num = ec%1000`，`diag.cr:86-104` 前缀表 + `:106-110` 补零）· `checker.cr:820-828`（`check_error` 唯一写入器，记录 40B = `globals.cr:182` `DIAG_REC_SIZE`）· `checker.cr:490-495`（`diag_type_incompatible` 组合判定）· `globals.cr:463-500`（`reset_frontend_state` 清 `g_diag_count`；`check_all` 自身亦在 `checker.cr:3805` 清零）· `src/ci/run.sh:31-33`（check job）/`:36-54`（suite job：`:44` `*_mini*.cr` SKIP、`:46` 空文件 SKIP）/`:119-130`（full-bootstrap）· `tools/baseline/parity_run.sh:30`（`CORPUS_TOTAL=72`）/`:32-40`（逐档 `clean-cache` + `check`）/`:68-71`（计数硬断言）· `tools/baseline/probes_run.sh`（`PROBE_TOTAL=29`）。

**Spec / 依据：** ① **维护者 2026-09-14 裁定「要改、方向 = fail-closed」**（本批成立的前提；裁定文本经协调者转述，**无独立文件载体 —— 须 T0 向维护者核一句原文并落报告**）；② **P6 裁决门 裁-P6-2 的 (b)(c) 两问**（`docs/superpowers/plans/2026-09-14-r2-p6-tail.md:58`：**(b)** 非硬名单诊断是否收紧到 `build` 面；**(c)** 新硬错入闸判据是否成文化为「判定继续 ⇒ 产出静默错产物」）——**本批 = 该两问的最强形式，未取裁前的方向性背书不成立**；③ **P5 已落政策**：P-A（ICE04 硬错，`plans/2026-09-13-r2-p5-cleanup.md` + `main.cr:161-166` 注）、TA02（TODO #32 + `main.cr:167-174` 注）——**本批不得回退这两条**；④ **`docs/error-codes.md`**（码族/消息模板/统计）；⑤ **E-14 的活证据**（P6 T0 报告 §6-5：`tests/suite/ptr_arith.cr` `check` rc=1（B04 `12:8`）而 `build --static` rc=0 且产出 canary ELF）。

---

## 前置状态（**本计划未跑任何构建/测试**；下列全部为实读源码/文档或既有报告记录值，出处逐条标注）

- **工作树 = `/tmp/p7wt`，基线 = P6 终态提交 `97f4394f`**（协调者给定）。**本实例 `jj` 命令零执行**（纪律：统一由协调者提交）；`ps` 实查无并发编译进程的步骤留给实施任务。
- **诊断通道实读 = 5 条**（全仓 `check_error(` / `g_diags` 写入点 grep 实证）：
  1. **词法/语法消息通道**：`lexer.cr:39-43` `add_error()`（`g_errors` = 驻留串下标）+ `parser.cr` 同族 `add_error` —— **20 个调用点**（`lexer.cr` 10：`:147/:226/:233/:236/:238/:240/:246/:436/:454/:456`；`parser.cr` 10：`:468/:591/:704/:1472/:1474/:1477/:1479/:1482/:1531/:1580`）。无码，打印形 `error: <msg>`（`diag.cr:154-162`）。**已 fail-closed**（`main.cr:135`）。
  2. **语法诊断码通道**：`parser.cr` 直接写 `g_diags`（15 处写入 / **8 个码**）：`EC_P_EXPECTED`（`:121`/`:130`）、`EC_P_FIELD_SYNTAX`（`:1828`）、`EC_P_PARAM_TYPE`（`:1847`）、`EC_TA_UNKNOWN_TAG`（`:829`）、`EC_P_NESTED_FN`（`:927`）、`EC_P_TOO_MANY_PARAMS`（`:1453`）、`EC_P_STRUCT_LIMIT`（`:1647`）、`EC_P_ENUM_LIMIT`（`:1723`/`:1728`）。**已 fail-closed**（`main.cr:134`）。
  3. **类型诊断码通道（`check_all` 内，**本批反转对象**）**：`checker.cr` 的 `check_error` 调用面 = **55 处 / 32 个码**（清单见「表 1」）。`check` 面已 fail-closed（`main.cr:448`）；**`build` 面只拦 11 码**（`main.cr:152-174`）⇒ **本批的唯一缺口面**。
  4. **安全检查面通道（build/ccr 专属）**：`region_check.cr:83`/`:134`（`EC_B_LIFETIME`/B11）、`provenance_verify.cr:68`（`EC_TU_DEREF`/TU03）、`:91`/`:99`/`:126`（`EC_TK_INDEX`/TK01 复用）。**已 fail-closed**（`main.cr:600`，任意新诊断阻断）——**注意：`check` 面不跑该面（`main.cr:451` 提前返回）⇒ 该面是「check rc=0 / build rc=1」的**反向不一致**存在性证据**（与 `ptr_arith` 的正向不一致成对；本实例未构造具体语料，**须 T1 实测登记**）。
  5. **非 `g_diags` 的 `error:` 打印通道**：`main.cr`（`:32`/`:94`/`:421`/`:434`/`:640`/`:675`/`:679`、写入失败 `:650-652`/`corearch.cr:510`/`:586`/`:596`）、`corearch.cr`（装载/链接失败全分支）、`interp.cr:408`/`:413`/`:738`/`:743`。**已 fail-closed**（各自 `return 1`）。
- **码面实读统计**：`ast.cr` 定义码 ≈ **146**（`docs/error-codes.md:275-287` 统计表自述「总计 ~146」）；**可达码（有 raise 点）= 42**（本实例用 `check_error(EC_*` / `diag_type_incompatible(…, EC_*` / `DIAG_REC_SIZE, EC_*` 三形态全仓 grep 去重实得 43 项，其中 `EC_SIZE` 为 `DIAG_REC_SIZE` 的子串假命中，扣 1）⇒ **其余 ≈104 个码「定义零 raise」（本批不动，登记）**。**码名两式口径**（照 P6 T0 表 D-6）：常量名 `EC_P_ENUM_LIMIT=1022`（`ast.cr:372`）而**用户面实印 `error[P22]`**（`diag.cr:132-136` 的 `num = ec%1000 = 22`）——**本计划一律「常量名（用户面码）」双写**。
- **现行 11 码硬名单**（`main.cr:152-174` 逐行实读）：`EC_R_OOB`（R002）· `EC_TK_SLICE_BOUNDS`（TK05）· `EC_TK_SLICE_LEN`（TK06）· `EC_TS_MISSING_FIELD`/`EC_TS_UNKNOWN_FIELD`/`EC_TS_FIELD_TYPE`/`EC_TS_FIELD_DUP`（TS01-04）· `EC_TK_ELEM_TYPE`（TK02）· `EC_TM_EXHAUST`（TM03）· `EC_ICE_TY_INDET`（ICE04）· `EC_TA_DECL`（TA02）。
- **已知非硬名单诊断**（`ast.cr:487-489` 定义、`main.cr` 名单外）：`EC_TG_ARG_COUNT`（TG01，**零 raise**）· `EC_TG_BOUND`（TG02，raise 于 `checker.cr:1227`/`:1233`/`:2059`）· 族内其余（N/TF/TB/TC/TM/TK/B 面）。
- **`check` 面不产生产物**（实读：`main.cr:444-451` 在 `:467` `optrep_begin()`/`:473` `make_cir_cache_dir()` 之前返回）⇒ 「零产物」的缺口**只在 `build`/`ccr`/`cir` 面**。

---

## 表 0：闸门 × 命令矩阵（**现状**，本实例实读；本批的判定面边界）

| 命令 | 语法面闸 `:134/:135` | 类型面硬名单闸 `:146-179` | 安全检查面闸 `:594-603` | 现行 rc 语义 | 产物 | 本批是否改 |
|---|---|---|---|---|---|---|
| `check` | ✔ | ✖（不用；`:448` 独立更严） | ✖（`:451` 前返回） | **任意诊断 ⇒ rc=1** | 无 | **不改**（已 fail-closed） |
| `build` | ✔ | ✔ | ✔ | 名单内 ⇒ rc=1；**名单外 ⇒ rc=0 + 照出产物** | `<out>` ELF + `<out>.ccr` | **本批对象** |
| `ccr` | ✔ | ✔ | ✔ | 同上（名单外 ⇒ 照出 `.ccr`） | `<out>.ccr` | 同批（同一 `run_frontend` 闸） |
| `cir` | ✔ | ✔ | ✖（`:565` 分支在 `:594` 前返回） | 同上（名单外 ⇒ 照出 `.cir`） | `<out>.cir` | 同批（闸同源；安全检查面**不在本批扩面**） |
| `run` | ✔ | ✔ | ✖（解释器路径） | 名单外 ⇒ 照跑 | 无 | 同批（闸同源） |
| `selftest-types` / `selftest-purity` | — | — | — | 自测通道，不读源文件 | 无 | **不改** |
| LSP（`src/lsp/lsp.cr`） | — | — | — | 编辑器诊断推送（不产生产物） | 无 | **不改**（登记：非产物面，fail-closed 不适用） |

**判定面定义（本批语义）**：**error = 阻断**（`rc=1` + 零产物）；本仓**现行无 warning 通道**（全仓无 `warning[` 打印面；`TM04`（`EC_TM_REDUNDANT`）在 `main.cr:159` 注中记为「软面登记（同 Rust unreachable-pattern 的警告口径）」但**打印仍是 `error[TM04]`**）⇒ **本批要么把软面码降级为真 warning，要么登记为豁免**（见裁-FC-2）。

---

## 表 1：全诊断面清点（**核心产物**；`check_all` 面 32 个可达码逐码分诊）

> 口径：**① 必须阻断** = 语义上「判定继续 ⇒ 产出静默错产物 / 判定不可信」（照 P6 裁-P6-2(c) 的成文化判据）；**② 必须豁免** = 有**已实测语料命中**且该命中属已知假阳性/过渡期，或**已有政策裁定**使其非 error；**③ 本批不动** = 在闸门作用域之外（另见表 0/表 2）。**「命中」列 = P6 T0 报告 §3.1 的 72 档实跑记录值（`/tmp/p6t0/corpus_rc.txt`），非本实例实测；套件面命中一律标「须 T1 实测」。**

| # | 码（用户面） | 常量（`ast.cr` 行） | raise 点（`file:line`） | 语义 | 72 档命中（P6 T0 记录） | 分诊 | 依据 |
|---|---|---|---|---|---|---|---|
| 1 | TA01 | `EC_TA_ASSIGN`（:407） | `checker.cr:3376` | 赋值号两侧类型不匹配 | 0（未见于首条诊断表） | **①阻断** | 与 TA02 同族（声明位/赋值位同形）；符号类型与实际值分歧 ⇒ 静默错值 |
| 2 | TA02 | `EC_TA_DECL`（:408） | `checker.cr:530` | 声明注解 vs 初值 | 0（P5 T6 report-only 全语料零命中） | **①阻断（已在名单）** | P5 政策，不得回退 |
| 3 | TF01 | `EC_TF_RETURN`（:417） | `checker.cr:1525`/`:2240` | 返回型不匹配 | **5**（`chan_test`/`conc_test`/`go_e2e_test`/`go_final_test`/`go_parallel_test`，P6 T0 §3.1「TF01 返回型不匹配（并发/goroutine 族）」） | **②豁免（待裁，须逐档归因）** | 命中面 = CI `suite` job **实际 build 的 21 档中 5 档**（`run.sh:36-54`）⇒ 直接入闸 = 套件 job 转红 + 可能改写 ELF canary 族判据。**同码先例 = 已修的假阳性**（`src/compiler` 内两条 TF01 系误报已由 P6 TF01 清理批修，TODO #40 ⇒ `check src/compiler` rc=0）⇒ 本批须先判这 5 档是同族误报还是真错 |
| 4 | TF07 | `EC_TF_ARG_TYPE`（:423） | `checker.cr:3727`（**唯一 raise**，`@raw_int` 内建位；非调用位点——#20 登记的「调用位点判定点不存在」实读 = 已知 `SYM_FN` 非泛型分支 `checker.cr:2766-2797` **连实参推断都不走**（直接 `return sym_type(si)`；T4a 报告锚 `:2744-2753` 为打补丁前行号，本实例实读漂移 **+22**）） | 实参类型不匹配 | **1**（`ptr_ref_first.cr`，P6 T0 §3.1「TF07 实参类型 1」） | **②豁免（待裁）** | 同行 3：命中档在 suite job 的 build 集内 |
| 5 | TF08 | `EC_TF_METHOD_NOT_FOUND`（:424） | `checker.cr:2277` | impl 缺接口方法 | 0 | **①阻断** | 接口契约未履行 ⇒ 表项/调用面不可信（同 TG02 族） |
| 6 | TF09 | `EC_TF_METHOD_ARG_CNT`（:425） | `checker.cr:2288` | 方法实参个数 | 0 | **①阻断** | 同上 |
| 7 | TF10 | `EC_TF_METHOD_ARG_TYP`（:426） | `checker.cr:2283`/`:2301` | 方法实参类型 | 0 | **①阻断** | 同上 |
| 8 | TB01 | `EC_TB_ADD`（:436） | `checker.cr:2474`/`:2990`/`:2991` | 算术操作数类型错 | 0 | **①阻断** | 算术无良定义 ⇒ 发射按错宽度 |
| 9 | TC01 | `EC_TC_IF_COND`（:452） | `checker.cr:2489`/`:2851` | 条件非 bool/int | 0 | **①阻断** | 分支判定按非布尔值 ⇒ 静默错控制流 |
| 10 | TC02 | `EC_TC_IF_BRANCH`（:453） | `checker.cr:2908` | 两分支类型不同 | 0 | **①阻断** | 结果型随分支漂移（同 TK02 族）；`checker.cr:2906-2908` 已含 `TI_NEVER` 双侧豁免（返回值合并面） |
| 11 | TC04 | `EC_TC_WHILE_COND`（:455） | `checker.cr:2965` | while 条件非 bool | 0 | **①阻断** | 同 TC01 |
| 12 | TM03 | `EC_TM_EXHAUST`（:463） | `checker.cr:3097` | match 非穷尽 | 0（P3 Task 3 report-only 零命中） | **①阻断（已在名单）** | 未匹配值静默得 0（`main.cr:155-159` 注） |
| 13 | TM04 | `EC_TM_REDUNDANT`（:464） | `checker.cr:3100` | 冗余臂 | 0 | **②豁免（政策既定）** | `main.cr:159` 原文：「TM04（冗余臂）**不入**本名单 = 软面登记（同 Rust unreachable-pattern 的警告口径）」⇒ 默认全阻断会**推翻该裁定**，须登记豁免或改判为真 warning |
| 14 | TK01 | `EC_TK_INDEX`（:472） | `checker.cr:3353` + `provenance_verify.cr:91`/`:99`/`:126` | 非可索引类型 / 指针越界 | 0 | **①阻断** | 索引兜底门（P3b Task 2 接线）；后三处属安全检查面（已阻断） |
| 15 | TK02 | `EC_TK_ELEM_TYPE`（:473） | `checker.cr:3567` | 数组元素异型 | 0 | **①阻断（已在名单）** | TODO #29 三校验 |
| 16 | TK05 | `EC_TK_SLICE_BOUNDS`（:476） | `checker.cr:3304` | 常量档切片越界 | 0 | **①阻断（已在名单）** | F2：修复前静默生成越界二进制 |
| 17 | TK06 | `EC_TK_SLICE_LEN`（:477） | `checker.cr:3306` | 切片长度负 | 0 | **①阻断（已在名单）** | 同上 |
| 18 | R002 | `EC_R_OOB`（:504） | `checker.cr:3320`/`:3335` | 常量档越界索引（数组/字符串） | 0 | **①阻断（已在名单）** | 同上 |
| 19 | N001 | `EC_N_UNDEFINED`（:376） | `checker.cr` **17 处**（`:2257`/`:2432`/`:3205`/`:3673`…`:3776`） | 未定义名 | **25**（P6 T0 §3.1「库单元单独 check（N01/N06/N11——本该由 concat 供货）25 档 = t2 1 + t3 13 + t4 10 + t1 1」） | **②豁免（范围 = check 面）** | 该 25 档**从不在 build 面被编译**（语料 runner 只跑 `check`，`parity_run.sh:36`）⇒ **若裁-FC-1 取「两面同闸」则必须豁免，取「build 面单闸」则无需豁免（自然不触发）** |
| 20 | N006 | `EC_N_FUNC`（:381） | `checker.cr:2809` | 未定义函数 | 同上 25 档内嵌（t1 `at_test_mini.cr` + t3 7 档 + t4 5 档） | **②豁免（范围 = check 面）** | 同上 |
| 21 | N008 | `EC_N_METHOD`（:383） | `checker.cr:2396` | dyn 方法不存在 | 0 | **①阻断** | 调用面不可解析 ⇒ 静默错分派 |
| 22 | N009 | `EC_N_GENERIC_TYPE`（:384） | `checker.cr:1000` | 泛型应用基类型不存在 | 0 | **①阻断** | 实例化不可进行 |
| 23 | N011 | `EC_N_DUPLICATE`（:386） | `checker.cr:1530`/`:1550` | 重复定义（含 hotpatch 形参不符） | **1**（t3 `ccr_io.cr`，P6 T0 §3.1 表「N11×1」） | **②豁免（范围 = check 面）** | 同上（concat 供货面） |
| 24 | TG02 | `EC_TG_BOUND`（:489） | `checker.cr:1227`/`:1233`/`:2059` | 泛型约束不满足 | 0（P5 台账：全语料 0 命中；唯一命中 = `test_generic_constr.py` 1 例登记面已重钉） | **①阻断** | 约束未满足 ⇒ 实例化假定不成立 |
| 25 | B001 | `EC_B_BORROW_MUT`（:492） | `checker.cr:2510` | 对已借用者取可变借用 | 0（P6 T0 §3.1 借用族仅 `ptr_arith` 1 档，且首条 = B04） | **①阻断（待 T1 实测复核）** | 借用模型判定；**若 T1 实测出套件面命中 ⇒ 并入 ②**（见裁-FC-3） |
| 26 | B002 | `EC_B_BORROW_IMMUT`（:493） | `checker.cr:2512` | 对可变借用者取共享借用 | 0（同上） | **①阻断（待 T1 实测复核）** | 同上 |
| 27 | B004 | `EC_B_USE_WHILE_BORROWED`（:495） | `checker.cr:2427` | 借用存续期内使用被借用变量 | **1**（`tests/suite/ptr_arith.cr` `12:8`，P6 T0 §3.1 + §6-5 活证据） | **②豁免（必选之一，见裁-FC-3）** | **该档 = ELF canary 硬闸的唯一载体**（canary 命令即 `build tests/suite/ptr_arith.cr --static`，P6 T0 §2#7）⇒ 入闸 = **canary 不可产** ⇒ 三选一（修 B04 假阳性 / 登记豁免 / 换 canary 载体） |
| 28 | ICE04 | `EC_ICE_TY_INDET`（:521） | `checker.cr:559` | 类型判定不可判（引擎 -1/桥接缺口） | 0 | **①阻断（已在名单）** | P-A 政策，不得回退 |
| 29 | TS01 | `EC_TS_MISSING_FIELD`（:482） | `checker.cr:3449` | 缺字段 | 0 | **①阻断（已在名单）** | TODO #29 |
| 30 | TS02 | `EC_TS_UNKNOWN_FIELD`（:483） | `checker.cr:3433` | 未知字段 | 0 | **①阻断（已在名单）** | 同上 |
| 31 | TS03 | `EC_TS_FIELD_TYPE`（:484） | `checker.cr:3478`/`:3502` | 字段类型不符 | 0 | **①阻断（已在名单）** | 同上 |
| 32 | TS04 | `EC_TS_FIELD_DUP`（:485） | `checker.cr:3436` | 字段重复初始化 | 0 | **①阻断（已在名单）** | 同上 |

**表 1 计数：① 必须阻断 = 25 码**（TA01/TA02/TF08/TF09/TF10/TB01/TC01/TC02/TC04/TM03/TK01/TK02/TK05/TK06/R002/N008/N009/TG02/B001/B002/ICE04/TS01/TS02/TS03/TS04）**② 必须豁免 = 7 码**（TF01 · TF07 · TM04 · N001 · N006 · N011 · B004）**③ 本批不动 = 表 0 的七行作用域外命令 + ≈104 个「定义零 raise」码 + 5 条通道里已 fail-closed 的 4 条**。

**表 1-补：已 fail-closed 的 10 个可达码（本批不改，清点收编）**：`EC_P_EXPECTED`/`EC_P_FIELD_SYNTAX`/`EC_P_PARAM_TYPE`/`EC_P_NESTED_FN`/`EC_P_TOO_MANY_PARAMS`/`EC_P_STRUCT_LIMIT`/`EC_P_ENUM_LIMIT`/`EC_TA_UNKNOWN_TAG`（语法面 8，`main.cr:134`）· `EC_B_LIFETIME`（B11，`region_check.cr:83`/`:134`）· `EC_TU_DEREF`（TU03，`provenance_verify.cr:68`）（安全检查面 2，`main.cr:600`）。⇒ **可达码 42 = 25 + 7 + 10。**

---

## 表 2：语料面与**转红面**预估（第 4 项交付的输入；全部为记录值或实读构成）

| 语料面 | 构成（实读） | 面 | 现行状态 | 全阻断后的预估转红面 | 出处 |
|---|---|---|---|---|---|
| 72 档 | t1 `tests/suite/*.cr` 32 + t2 自源 2 + t3 后端/内核 15 + t4 stdlib 19 + t5 examples 4 | `check` | rc **34×0 / 38×1**；38 档划界 = 0 字节 fixture 2 + P21 负例 2 + examples 解析错 2 + 库单元单独 check（N01/N06/N11）25 + TF01 5 + TF07 1 + B04 1 | **若 check 面不改：零变化**（表 0）；若取「两面同闸」：N 族豁免条生效 ⇒ **≈25 档 rc 1→0**（精确档数取决于 T2 豁免表的 `scope` 字段 ⇒ 判据换代 + 逐档重锁） | P6 T0 §3.1（`/tmp/p6t0/corpus_rc.txt`）+ `tools/baseline/parity_run.sh:30` |
| CI `suite` job | `tests/suite/*.cr` **实 build 21 档**（32 − 2 空 − 9 `*_mini*`；`run.sh:44`/`:46`） | `build` | 全 rc=0 + 运行通过 | **≥7 档**（TF01×5 / TF07×1 / B04×1；见下「转红面预估方法」） | `run.sh:36-54` + P6 T0 §3.1 |
| CI `full-bootstrap` job | `src/compiler/main.cr --static -O 0` ×2（corec2/corec3）+ `--help` | `build` | rc=0 · `cmp` IDENTICAL | **0**（`check src/compiler` rc=0 ⇒ 零诊断 ⇒ 闸无差别） | `run.sh:119-130` + P6 T0 §2#6 |
| CI `check` job | `build_selfhost` + `check src/compiler` | `check` | rc=0 | **0** | `run.sh:31-33` |
| ELF canary | `clean-cache` → `build tests/suite/ptr_arith.cr --static` | `build` | rc=0 + `95084e7b…d475`（28822B） | **1 档 = 硬冲突**（B04 命中）⇒ **canary 不可产** | P6 T0 §2#7 |
| `.ccr` 四条判据 | `ptr_arith` / `generics_test` 两口径 | `ccr`+`build` | 四条 = T3 新锁值（96015/96158/142793/142936） | **≥1 档**（`ptr_arith` 含 B04） | P6 T6 §Step 2 + `p6-task4-report.md` §4 |
| `tests/selfhost/*.py` 套件 | 51 档 py；其中 **44 档含 `"build"` 调用（126 处）**（本实例 `grep -l`/`grep -rho` 计数） | `build` | 全绿 | **须 T1 实测**（负例套件断言 rc=1 不受影响；风险 = 「断言 build rc=0」的档） | `src/ci/run.sh:84-111` 挂点 28（`grep -c 'python3 tests/selfhost/'` 实核）+ 本实例 `grep -rho '"build"'` |
| 探针语料 | `tests/probes/*.cr` 29 档 | `check` | **17×0 / 12×1**（12 档为**故意的负例**） | **零变化**（check 面不改 ⇒ 两态对拍仍为零差异） | `tests/probes/README.md:58` |
| `examples/*.cr` | 4 档 | `check` | 2 档解析错（既有） | 零变化（check 面） | P6 T0 §3.1 |

**转红面预估方法（**硬要求，T1 落地**）**：① **不靠猜**：T1 用**现有二进制**对「build 面语料全集」逐档跑 `build`（`-o /tmp/fc1/out/<tag>`，**保留产物供二次比对**），采集 `rc` + 日志中全部 `error[XX]` 行的（码, `file:line`）二元组 ⇒ 产出 `hits.tsv`；② **逐档归因表**：每档给「码 → 归因（真错 / 假阳性 / 语境缺失 / 政策软面）→ 处置（修根因 / 修语料 / 登记豁免）」；③ **分批开门办法**：批次 1 = 全反转 + 豁免表覆盖 T1 全清单（**先保 CI 绿**）；批次 2..n = 逐条撤销豁免（每条以「根因已修 / 语料已正」为撤除判据），**只减不增**。

---

## 裁决门（**开工前置**；逐条 = 问句 / 影响 / 本计划推荐 / 未取裁时的行为）

> 纪律继承 P6：**未取裁的项一律不实施**；**不得**以「推荐案」冒充裁定；凡「先裁」项，护栏写进任务卡正文（P6 事故 §7-1 的教训）。

| # | 问句（逐条照抄给维护者） | 影响 | 本计划推荐 | 未取裁时 |
|---|---|---|---|---|
| **裁-FC-1** | `check` 面与 `build` 面**是否用同一闸门**？**(A)** 现状（check 严 / build 宽）+ 本批只反转 build 面；**(B)** 两面同闸同表（check 也走豁免表 ⇒ 72 档 rc 分布换代、parity 基线重锁）；**(C)** 两面同闸但豁免表带**生效范围**字段（`build`/`check`/`both`），初始绝大多数条 = `build` 范围 ⇒ check 基线不动。 | 表 0 全行；72 档 + 探针两条对拍腿的可用性 | **(C)**（同机制、显式登记差异、check 基线零扰动；(B) 会让 ≈25 档 rc 1→0，parity 腿从「零差异」退化为「大面 diff」，丧失回归网价值） | 按 (A) 执行：只动 build/ccr/cir/run 四面，check 不动；差异显式登记 |
| **裁-FC-2** | **豁免表的载体与粒度**，以及**软面码（TM04）**的处置：**(a) 粒度** = 码级 / 码×语料位点级（`file:line`）/ 码×范围级；**(b) 载体** = 源码内静态表（照 `corearch.cr` 的 `g_instance_decl` 表先例）/ 仓库配置文件 / CI 白名单；**(c) 换代纪律** = 只减不增 + 撤除须带根因证据 + 新增须维护者批？**(d)** TM04 是登记豁免还是改为**真 warning 通道**（`warning[...]` 前缀，不阻断）？ | T3 的实现形态与全批的「豁免可审计性」 | **(a) 码级 + 位点列作证据字段**（位点级更窄但脆弱：语料一行漂移即失效；码级简单但允许同码在别处静默 ⇒ 用「每次开新面必重跑 report-only」补偿）；**(b) 源码内静态表**（Core 无配置文件读取面、CI 不跑本地判据）；**(c) 只减不增**；**(d) 登记豁免**（引入 warning 通道 = 新诊断类别，超本批章程） | 表形态 = 源码内 `code → {scope, locus, reason}` 静态表；TM04 登记豁免 |
| **裁-FC-3** | **B004（`ptr_arith.cr:12:8`）与 ELF canary 硬闸的冲突**：B004 入闸 ⇒ canary 不可产。三选一：**(i) 修 B004 假阳性**（实现末次使用/NLL 级借用收缩——**语义变更，工作量未估**）；**(ii) 登记豁免 B004**（canary 保住，但「check rc=1 / build rc=0」的活证据继续存在）；**(iii) 换 canary 载体**（判据换代：canary sha 全链作废、须重建白名单与全部历史比对基线）。 | ELF canary 判据（本批硬闸）+ suite job | **(ii) 本批登记豁免 + 同批开 TODO 条目把 (i) 立为独立批**（(i) 是语义变更不是闸门变更；(iii) 代价 = 判据换代，不能由实施者自裁） | T5 不实施 B004 阻断；B004 豁免条目标「退出条件 = 借用收缩落地」 |
| **裁-FC-4** | **命中语料（≥7 档）的处置**：TF01×5（并发族）/ TF07×1（`ptr_ref_first`）/ B04×1 —— **修前端假阳性 / 修语料（删除或改判负例）/ 登记豁免**？（修语料涉 `tests/` 面改动，且 `tests/suite` 是 CI 正例集；改 neg 例会动 `run.sh:36-54` 的 SKIP 语义） | CI `suite` job 转红面 | **先逐档归因（T1）再判**：真误报 ⇒ 修前端（照 P6 TF01 清理批先例 `p3-task3-report`/TODO #40）；真错误 ⇒ 语料归为负例（照 `*_mini*` SKIP 先例，**须维护者批**）；**本批不预判** | 全部登记豁免 + CI 保持绿；修复批次另立 |
| **裁-FC-5** | **与 P6 待裁项的接口**：**(a)** 本批是否即为 裁-P6-2**(b)**（非硬名单诊断收紧）与 **(c)**（入闸判据成文化）的**最强形式**？若维护者只取 (b) 的「`build` 面汇总告警」档（不阻断），本批**降级为 report-only**（T3 只落采集器、不落闸）；**(b)** 裁-P6-2**(d)**（`*T ← 0/None`）/**(e)**（`--verify-named-dedup`）与本批无耦合（(d) 是规则语义、(e) 是调试通道）——**本批不动**，确认？ | 全批章程 | **(a) 取最强形式**（否则本批无对象）；**(b) 确认无耦合、不动** | 本批降级为「report-only 常设」：T3 落采集器 + 清单，**不反转默认闸**；命中表交维护者处置 |
| **裁-FC-6** | **「零产物」的边界**：失败时 **(a)** 是否删除**本次**写入的 `<out>.ccr`（`main.cr:678` 写在 `corearch` 之前 ⇒ corearch 失败即留半成品；纯静态路径的 ELF 在 `ctx_emit_static` 末尾一次性写（`ld.cr:525-529`），本身不留半成品）？**(b)** `.core/cache/cir/*.cir` 过程缓存与 `.core/cache/cir/` 目录（`main.cr:473`）是否算产物？ | T5 的实现面 | **(a) 删除**（仅限本次 `save_ccr` 成功且 `corearch` rc≠0 的路径；**已存在的旧产物不动**——不删用户文件）；**(b) 登记为口径豁免**（过程缓存非交付产物；且 frontend 闸在 IR gen 之前 ⇒ 闸触发时不产生任何缓存） | 按推荐执行（不外扩删除面） |

---

## 任务总表（**本批实施面**；状态一律「待实施」，收官按实测回填）

| 任务 | 内容 | 依赖 |
|---|---|---|
| T0 | 前置侦查 + **冻结基线重建**（P6 终态 `97f4394f`）+ 起点判据（表 B）+ 锚点实核（表 D）+ 维护者裁定原文核录（**源码零改动**） | — |
| T1 | **全语料 report-only 基线（核心产物）**：`tools/baseline/build_gate_run.sh` + 命中清单 + 逐档归因表（**零源码改动**，用现有二进制） | T0 |
| T2 | 分诊表定稿 + 豁免表草案 + **裁决门提交**（零代码） | T1 |
| T3 | 闸门反转 + 豁免表 + 隐藏 report-only 通道 + 采集器（**默认关**） | T2 + 裁-FC-1/2 |
| T4 | 命中面处置（逐条：修根因 / 修语料 / 登记豁免）+ 新套件 | T3 + 裁-FC-3/4 |
| T5 | **开门**（默认全阻断）+ 零产物语义 + CI 面同步 | T4 + 裁-FC-6 |
| T6 | 收官：全量回归 + 判据复验 + 统一台账 + 文档 + 批终态 | 全部 |

**顺序理由**：T1 必须先于一切（**先量后改**：本批最大风险 = 一次改动让大量既有语料转红）；T2 的取裁决定 T3 的实现形态（同闸 vs 单面、豁免粒度）；T4 依赖 T3 的采集器做二次核对；T5 的开门是**单点翻转**（默认值一行），其判据全在 T1–T4 的证据链上。

---

## Global Constraints（照 P6 简版）

- **jj only（禁 git 含只读/复合）**；**提交路径限定**（多 agent 在场：一律 `jj commit -m … <paths>`）；所有命令 `nice -n 19`；一构建一编译**串行**（每段前 `ps` 实查）；cwd = 仓库根（`/tmp` cwd 触发 import 解析假失败）。
- **基线纪律**：每任务开工先取**同任务起点**基线（binary sha + 语料 rc 表 + 探针 rc 表），**不得沿用上一任务的计数**。冻结基线 = 由 `tools/baseline/rebuild.sh`（配方 `tools/baseline/REBUILD.md`；pinned revision + 三 sha 白名单）重建；**P6 终态的白名单值须 T0 实核后落表**（P6 期的白名单 = P4 收官 `9bcb7083` 产物，**不是**本批基线 ⇒ 本批须以 P6 终态 revision 重建并**新锁白名单**）。
- **ELF canary（硬闸，全批）**：`clean-cache` → `build tests/suite/ptr_arith.cr --static` → sha256 `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`（28822B）。**本批的 canary 语义有变体**：T5 开门后若 B04 豁免生效，canary 应**逐字节同**（豁免 = 不阻断，发射面零变化）；**若 canary 不可产 ⇒ 立即停下**（= 裁-FC-3 未取裁或取 (i)/(iii) 的信号）。
- **发射面声明（本批必须显式声明）**：**本批声明发射面零变更**（闸门 = 前端 rc 语义；不触 `ir_gen`/`lower_to_ccr`/`emit`）。任何 canary/`--dump-objects`/`.ccr` 逐字节差异 ⇒ 停下（越界信号）。
- **`.ccr` 记录值引用口径（D28 继承）**：一律带**命令口径**（`corec ccr F -o O` vs `corec build F -o O --static`，差恒 143B）+ **缓存态**（冷/热；非可选程序冷≠热为**预存**豁免）；比较任何 `.ccr`/缓存态产物前 `clean-cache`。
- **判据口径按 TODO #26**：不采用「与旧版逐字节同」当语义证据；结构性断言 + 语义零变化 + 自举稳定为本仓主判据；「≥N 例」= 下限（可增不可减）；**自测用例只增不减**（重钉/改名允许，删除须给死亡证据）。
- **三态纪律（不得稀释）**：引擎 -1 不得当 0/1 用；载入失败/段缺失/行不可译/项不可建 ⇒ **拒绝**。**新硬错先 report-only**：本批新增的任何 rc=1 门（含闸门反转本身）必须先在**全语料**（72 档 + `tests/selfhost` **内联源** + `src/stdlib` + `examples` + `src/compiler` 自指 + **58 套件全枚举**）report-only 跑一遍，清单审查后才开门。
- **清单三面同核（B.6，硬性）**：任何清单/段表改动必须三面同核——`build_selfhost_native.py`（`corec_files`/`corearch_files`/`corelsp_files`）↔ `src/targets/x86_64-linux/_import.cr` ↔ `src/compiler/_import.cr`；每任务回归面**必含** `tests/selfhost/test_backend_bootstrap.py`（rc=0 + 构建日志 `error[` = 0）。本批新增的 runner/语料（`tools/baseline/*`、`tests/probes/*`）**不进**任何编译清单。
- **不得回退既有收纳**：TS01-04/TK02 硬门（#29）、TM03/TG02 门（#31/#33）、F2 常量档拒绝语义与「N 不回身份」、F5 槽位契约（#25/#28）、效应/纯度判据（#26/#27）、`iface_satisfies` 轴序 A>C>B、P4 全批、P5 全批（ICE04/TA02/影子下线）、P6 全批（β/¬ 面/never/文档）——**一律不动**；冲突 → 停下上报。
- **本语言无三元运算符**；取模须非负；键比较不得依赖 i64 回绕；noclobber（`>|`）；**不写 `buf == 0` 形态的空判**（string-int 混比在 bootstrap 侧编成 `str_eq` ⇒ 自崩）；bootstrap 构建的 corec 对 **`&&`/`||` 两侧无条件求值** ⇒ **不得写 `guard && 表读`**（`p6-task4-report.md` §3 先例：须嵌套 `if`）。
- **多 agent 纪律**：不并发构建；提交路径限定；实施时逐任务串行；突变控制一律在**仓库外实拷贝**（`tests/` 必须**实拷贝**而非软链）。

---

## 起点基线值（**P6 终态记录值；本计划未复测**，出处逐条标注）

| # | 项 | 值 | 出处 |
|---|---|---|---|
| 1 | 72 档 `check` rc 分布 | **34×0 / 38×1**（含 2 档 0 字节 fixture `test_generics.cr`/`test_control_flow.cr`、P21 嵌套 fn 负例 `at_test_mini4/6.cr`、examples 两档解析错 `test_scale.cr`/`test_sum.cr`——**不得当回归**） | P6 T0 §3.1（`/tmp/p6t0/corpus_rc.txt`） |
| 2 | 五 CI job | 全 **rc=0** | P6 T6 §Step 1 |
| 3 | `check src/compiler` | **rc=0**（零诊断；P6 TF01 清理批后成立，#40） | P6 T0 §2#2 / P6 T6 |
| 4 | `selftest-types` | **415/415** | P6 T6 §Step 1（T5 收紧 `MIN_CASES=415`，`test_type_engine.py:20`） |
| 5 | ELF canary | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`（**28822B**） | P6 T0 §2#7 / P6 T6 |
| 6 | 自举链 | `corec2 == corec3` IDENTICAL（**`0b2e06d0c8b2f78402d08950364fb224db697fdf2e5b6e5d0d6a06e85fc581c1`**）+ N06=**0** + 冒烟 **42** + `--help` rc=1 | P6 T6 §Step 2 |
| 7 | `.ccr` 两口径四条（冷态） | `ptr_arith` **96015B** `680a6f98…` / **96158B** `76f36e6a…`；`generics_test` **142793B** `41e9d845…` / **142936B** `704316c8…`；**差恒 143B** | P6 T3 新锁值（P6 T6 §Step 2 复验） |
| 8 | 全枚举 | **58/58**（51 selfhost + 7 bootstrap） | P6 T6 §Step 1 |
| 9 | 探针 29 档 | rc **17×0 / 12×1**（12 档为故意负例） | `tests/probes/README.md:58` |
| 10 | `--dump-objects` / `.cir` DOT | 3521 行 / 165915B `b1bdf480…` | P6 T6 §Step 2 |
| 11 | 冻结基线三 sha（P6 期白名单，**本批须重建换锁**） | `5d2b15ad…` / `493dc490…` / `18b94bd9…` | `tools/baseline/REBUILD.md` |

---

## Task 0：前置侦查 + 冻结基线重建 + 锚点实核（**源码零改动**）

**Files:** 无源码改动。产物 = 报告 `.superpowers/sdd/fc-task0-report.md`（工作区，不入提交）+ 重建的冻结基线 `/tmp/fc0/base/{corec,corearch,corelsp}` + 清点原始输出（`/tmp/fc0/`）。

**Interfaces（产物四表，数字一律实测；未实测标「待实测」）：**
- **表 A：冻结基线重建**——`tools/baseline/rebuild.sh`（或等价手跑配方：`jj workspace add --revision 97f4394f` → `nice -n 19 python3 build_selfhost_native.py`）→ 三 sha **新锁白名单**（写入本任务产出的 `REBUILD.md` 换代记录）；构建 ×2 取确定性；冒烟 42。
- **表 B：本批起点判据基线**——起点基线值表 1–11 项**逐条复跑**（五 CI job / 全枚举 / `check src/compiler` / `selftest-types` / 构建确定性 ×2 / 自举链 / canary / `.ccr` 四条 / `--dump-objects` / `.cir` DOT）。
- **表 C：语料清点（**本批的新增面**）**——① 72 档逐档清单 + rc；② **build 面语料全集**：`tests/suite` 实 build 档（`run.sh:36-54` 语义实跑逐档计数）、`src/compiler/main.cr --static -O 0`、canary 档、`.ccr` 两档、`tests/selfhost/*.py` 内 `build` 调用逐处清点（含内联源去重）、`examples/*.cr`；③ 探针 29 档。
- **表 D：锚点实核**——本计划「Tech Stack」「表 0/1/2」的每个 `file:line` 逐条实读复核（**行号漂移以本轮实读为准**，漂移逐条落纸）。
- **表 E：裁定原文核录**——向维护者核一句「fail-closed 方向已裁」的原文/出处（来源 = 协调者转述）；**无原文 ⇒ 本批章程不成立 ⇒ 停**。

- [ ] **Step 1: 基线重建**。判据：三 sha 与**新白名单**逐条同 + 冒烟 42 + 构建确定性 ×2（日志逐字节同）。**不符 ⇒ 停下上报**。
- [ ] **Step 2: 起点判据**（表 B；cwd = 仓库根、逐段 `ps` 实查无并发、比较前 `clean-cache`）。
- [ ] **Step 3: 语料清点**（表 C；`ls`/`find`/`grep -c` 实核，逐类计数）。
- [ ] **Step 4: 锚点实核**（表 D）。
- [ ] **Step 5: 裁定原文核录**（表 E）。
- [ ] **Step 6: 报告**（不入提交；`jj status` 收工为空）。

**判据**：五表齐 + 基线三 sha 逐条同 + 源码零改动（`jj status` 干净）+ 报告内数字全部可追溯（命令 + 原始输出片段）。

**停条件**：① 重建 sha 不可复现 ⇒ 停下（判据腿失效）；② 表 E 无原文 ⇒ 停下（本批方向性背书缺失）；③ 表 B 任一项与上表记录值不符且无法归因 ⇒ 停下（起点漂移 ⇒ 后续所有对拍无意义）。

---

## Task 1：全语料 report-only 基线（**核心产物**；零源码改动）

**Files:** New `tools/baseline/build_gate_run.sh`（**build 面**采集 runner：逐档 `clean-cache` → `build` → 记 rc/日志/产物 sha；**不新增任何二进制入库**）· New `.superpowers/sdd/fc-task1-report.md`（工作区）· 证据 `/tmp/fc1/**`。**零 `.cr` 改动、零闸门改动。**

**Interfaces：**
```
tools/baseline/build_gate_run.sh <corec二进制> <outdir>
  # 语料 = 显式清单（照 probes_run.sh 先例：`shopt -s nullglob` + 计数硬断言，杜绝字面 glob 伪条目）
  #   t1  suite 实 build 档（run.sh 语义：排除 *_mini*.cr 与空文件）
  #   t2  src/compiler/main.cr --static -O 0（full-bootstrap 口径）
  #   t3  canary 档（tests/suite/ptr_arith.cr --static）+ .ccr 判据两档（ptr_arith/generics_test，ccr 与 build 两口径）
  #   t4  tests/selfhost/*.py 的内联源（**由各套件自跑**：本 runner 不重造，改为采集各套件日志——
  #        实现 = 58 套件枚举 + `grep -oE 'error\\[[A-Z0-9]+\\]'` 聚合）
  #   t5  examples/*.cr（check 面 + build 面各一遍）
  # 产物: <outdir>/hits.tsv（列 = tag | path | face(build/check) | rc | 码集合(去重) | 首条诊断 file:line | 产物 sha256|缺失）
```
- [ ] **Step 1: 采集 runner 入仓**（显式清单 + 计数断言 + cwd = 仓库根）。判据：跑一遍 rc=0 且 `hits.tsv` 行数 = 清单计数；与手工抽查逐档一致。
- [ ] **Step 2: 采全量命中清单**（现有二进制；build 面 + 58 套件枚举）。判据：每档给（rc, 码集合, 首条 `file:line`）；**与 P6 T0 §3.1 的 check 面 rc 分布交叉核对**（build 面 rc 应 ⊇ check 面 rc=1 档的**子集语义**——逐档差异须能归因到「该码是否在 11 码名单内」）。
- [ ] **Step 3: 逐档归因表**（表 2 的「转红面」列落纸）：每档 = {码 → 归因（真错 / 假阳性 / 语境缺失 / 政策软面）→ 处置建议}。判据：**无「未知/待查」行**（不能归因的档 = 停条件下上报）。
- [ ] **Step 4: 转红面汇总**：给「全阻断后 CI 五 job 各红几档 + canary 是否可产 + `.ccr` 四条是否可产」的**逐 job 表**。
- [ ] **Step 5: 报告**（不入提交；`jj status` 收工为空）。

**判据**：`hits.tsv` 与归因表齐备 + 每一行的归因有证据（命令 + 原始输出片段）+ 零源码改动。

**停条件**：① **命中面过大 ⇒ 转独立批**（阈值：**build 面转红档 > 10 档 或 > CI `suite` job 实 build 档的 1/3**，或**任一 CI job 出现「无法用登记豁免保住」的档**）⇒ 停，出「转独立批」建议书（含命中面全表）交维护者；② 归因表出现「无法判定真/假」的档 ⇒ 停下上报（不得猜）；③ 采集 runner 与手工抽查不符 ⇒ 停（仪器失真）。

---

## Task 2：分诊表定稿 + 豁免表草案 + 裁决门提交（**零代码**）

**Files:** Modify 本计划（把 T1 实测值回填表 1/表 2 + 落「豁免表草案」节）· 报告 `.superpowers/sdd/fc-task2-report.md`。

**Interfaces（豁免表草案的**逐条字段**，本任务定稿后交维护者）：**
```
{ code,            // 码常量（如 EC_B_USE_WHILE_BORROWED）
  scope,           // build | check | both（裁-FC-1）
  locus,           // 证据位点清单（如 tests/suite/ptr_arith.cr:12:8），**证据字段**
  reason,          // 为何不是真错误（假阳性机制 / 政策裁定 / 语境缺失）
  exit,            // 退出条件（撤除判据：根因修复 / 语料转负例 / 政策改判）
  hit_count,       // T1 实测命中档数
  owner_task }     // 归属（本批 T4 / 独立批）
```
- [ ] **Step 1: 表 1 回填**（32 码的「72 档命中 / 套件命中」两列由 T1 实测值替换「须 T1 实测」）。
- [ ] **Step 2: 豁免表草案**（≤10 条；每条六字段齐；**无 `reason` 或 `exit` 的条目不许入表**）。
- [ ] **Step 3: 裁决门提交**（裁-FC-1..6 逐条照抄问句；附 T1 的转红面逐 job 表作事实输入）。判据：六问**全部**有明文答复（**口头/转述不计**——照 P6 `p6-task4-report.md` §6 的「协调者已裁」需落纸的先例，**须维护者本人答复**）。
- [ ] **Step 4: 报告**。

**判据**：表 1 无占位符 + 豁免表每条六字段齐 + 六问答复落纸（含「不裁则按未取裁分支执行」的显式声明）。

**停条件**：① 任一裁-FC 的答复与 T1 的事实冲突（如裁「不豁免 B04」但 T1 证 canary 依赖它）⇒ 停下重报；② 豁免表条目 **>10 条** ⇒ 触 T1 停条件①（转独立批）。

---

## Task 3：闸门反转 + 豁免表 + report-only 通道（**默认关**）

**Files:** Modify `src/compiler/main.cr`（`:146-179` 的硬名单块反转为「默认 `hard = 1` + 豁免表查询」；新增隐藏旗标 `--diag-gate-report`（默认关，照 `--verify-named-dedup` 同址同式，注册面 = `main.cr:249`，消费面 = `main.cr:196`））· Modify `src/compiler/globals.cr`（豁免表数据 + 只读访问器；**若**表需要跨文件可见——变量/常量跨文件按声明序可见）· New `tests/selfhost/test_fail_closed.py`（≥12 例，下限）· Modify `src/ci/run.sh`（selfhost-tests 挂点 + 计数注）· Modify `docs/error-codes.md`（判定面表）· 报告 `.superpowers/sdd/fc-task3-report.md`。

**Interfaces：**
```
// 豁免表（形态 = 源码内静态表；载体与粒度按裁-FC-2）
// 行 = {code:i32, scope:i32, reason_ni:i32}（± locus 字段）
// 查询 = diag_gate_exempt(code, scope) -> int（1 = 豁免；0 = 阻断）
// 闸门（main.cr 原硬名单块处）：
//   hard : ., mut = 1;                              // **反转**：默认阻断
//   loop { ec := …; if diag_gate_exempt(ec, GATE_BUILD) != 0 { hard = 0 的**逐条**语义 } }
//   —— 注意语义：任一**未豁免**诊断 ⇒ hard = 1（不是「全部豁免才 1」）
//   ⇒ 实现 = hard = 0 起始；出现未豁免诊断即 hard = 1；break/或全扫后判定（保诊断打印顺序）
// 报告通道（默认关）：--diag-gate-report ⇒ 打印一行机器可读标记：
//   [diag-gate] face=build codes=B04,TF01 would-block=1 n_diag=3
```
- [ ] **Step 1: 表 + 查询函数 + 单测（红）**：`test_fail_closed.py` 机制面（≥6 例：默认阻断 / 豁免命中不阻断 / 多诊断混合（一豁免一未豁免 ⇒ 阻断）/ 空名单 / 双面 scope / 越界码）。
- [ ] **Step 2: 闸门反转**（落点 = `main.cr:146-179`；**嵌套 `if`，不得写 `&&` 串表读**；只改 rc 判定，**不改诊断产生与打印**）。判据：单测绿 + 全语料 report-only（Step 3）零意外。
- [ ] **Step 3: report-only 全语料**（`--diag-gate-report` + T1 的 runner 与 58 套件枚举）⇒ 产 `would_block.tsv`。判据：与 T1 `hits.tsv` **逐档逐码一致**（差异逐条归因；**任何未在豁免表内的命中 ⇒ 停下**）。
- [ ] **Step 4: 行为面用例（≥6 例）**：真错误 build ⇒ rc=1 + **无产物**（`<out>` 与 `<out>.ccr` 均不存在）；豁免码 build ⇒ rc=0 + 产物在 + ELF 可运行；`check`/`cir`/`ccr`/`run` 四面各自同闸验证；级联（多诊断混合）。
- [ ] **Step 5: 判据（硬闸）**：**ELF canary IDENTICAL** · `.ccr` 四条 = P6 T3 值 · `--dump-objects` 3521 行 · `.cir` DOT 165915B · 五 CI job rc=0 · 全枚举 58/58 · `check src/compiler` rc=0 · `selftest-types` ≥415 · 自举链 · 72 档对拍零差异 · 探针 29 档零差异 · `test_backend_bootstrap` rc=0 + `error[`=0 · **突变控制 ≥3**（M1 豁免表清空 ⇒ 命中档全部转红；M2 默认值反转回 0（不阻断）⇒ 未豁免码静默放行（转红 = 本批要消灭的形态复现）；M3 单条豁免删除 ⇒ 对应档转红）+ 精确回滚。
- [ ] **Step 6: 提交**：`feat: fail-closed 闸门——默认全阻断 + 豁免登记表 + report-only 通道（默认关；发射面零变化）`。

**停条件**：① report-only 出现**豁免表外的命中** ⇒ 停下（清单不完整）；② 任一 canary/`.ccr`/`--dump-objects` 变化 ⇒ 停下（发射面泄漏）；③ 默认关路径下**任何**既有判据发生变化（rc/日志/产物）⇒ 停下（本任务应零行为变化）；④ 裁-FC-1 未取裁 ⇒ **只落 report-only 通道，不落闸**（Step 2 跳过）。

---

## Task 4：命中面处置（逐条：修根因 / 修语料 / 登记豁免）

**Files:** 按 T1 归因表逐条定；预期面 = `src/compiler/checker.cr`（若修前端假阳性：如 TF01 并发族、TF07 `@raw_int` 位、B004 末次使用）+ `tests/suite/*.cr`（若语料转负例，**须裁-FC-4 批准**）+ `src/ci/run.sh`（SKIP 语义若改）+ `tests/selfhost/test_*.py`（重钉）+ 本计划（豁免表终稿）。

- [ ] **Step 1: 逐条归因复核**（每条：RED 复现 → 冻结基线复证 → 机制定位 → 处置判定）。判据：每条有 `file:line` + 触发语料 + 机制。
- [ ] **Step 2: 假阳性根因修复**（照 P6 TF01 清理批先例：`stmt_cannot_fall_through` + `lits_copy` 类型洗白，TODO #40）。判据：修复后该码在全语料零命中 + 原用例转绿 + **反例仍红**（强负控）。
- [ ] **Step 3: 语料处置**（**仅限裁-FC-4 批准面**）。判据：语料改动逐条有维护者批复 + 语料只增不减纪律的例外声明。
- [ ] **Step 4: 豁免表终稿**（撤除已修条；每条保留 `exit` 条件）。判据：表内条目全部有 T1 实测命中支撑（**不得有空条**）。
- [ ] **Step 5: 判据**：同 T3 Step 5 全套 + **命中档逐档转绿（或登记明确）的对照表**。
- [ ] **Step 6: 提交**（按处置分批；路径限定）。

**停条件**：① 修假阳性过程中发现**语义变更面**（如 B004 的借用收缩）⇒ 停下（超本批章程，转独立批）；② 语料处置超出裁-FC-4 批准面 ⇒ 停下；③ 命中档在修复后**仍红且未登记** ⇒ 停下。

---

## Task 5：开门（默认全阻断）+ 零产物语义 + CI 面同步

**Files:** Modify `src/compiler/main.cr`（闸门默认值/表终稿；**零产物**：`corearch` 失败路径删本次 `<out>.ccr`——落点 `:702` 附近，`exit_code != 0` 分支）· Modify `src/ci/run.sh`（若 CI 需承认新语义：如 suite job 对已知豁免档的注释块 + 自述）· Modify `docs/error-codes.md`（判定面/闸门语义成文化）· Modify `TODO.md` · Modify 本计划（实施记录）。

- [ ] **Step 1: 开门**（裁-FC-5 取最强形式时；默认全阻断生效）。判据：`hit` 档的 build rc 由 0 → 1（逐档对照 T1 表），而**豁免档 rc=0 且产物逐字节同**（canary/`.ccr` 四条为证）。
- [ ] **Step 2: 零产物语义**（裁-FC-6）。判据：新套件断言——失败路径 `<out>` 与 `<out>.ccr` **均不存在**；**已存在的旧产物不被删除**（前置造一个旧文件 + 触发失败 ⇒ 旧文件仍在）；`.core/cache/cir/` 口径落纸。
- [ ] **Step 3: CI 面同步**（`run.sh` 注释/自述；若需新 job 或新挂点，走三面同核）。判据：五 CI job rc=0 + 全枚举 58/58。
- [ ] **Step 4: 判据（硬闸）**：canary IDENTICAL · `.ccr` 四条 = T3 值 · 全枚举 · selftest-types ≥415 · 自举链 · 72 档对拍**换代后的期望值**（若裁-FC-1 取 (B)/(C)，此处须给新期望分布 + 逐档归因）· 探针 29 档 · 突变 ≥3 + 精确回滚。
- [ ] **Step 5: 提交**：`feat: fail-closed 开门——默认全阻断生效 + 零产物语义（豁免表 N 条；发射面零变化）`。

**停条件**：① CI 任一 job 转红且非豁免表覆盖 ⇒ 停下；② canary 变化 ⇒ 停下；③ 零产物断言在**失败路径先于** `save_ccr`（前端闸）与**后于**（corearch 失败）两种形态任一处不成立 ⇒ 停下。

---

## Task 6：收官（回归 + 判据 + 台账 + 文档 + 批终态）

- [ ] **Step 1: 全量回归**（cwd = 仓库根、`nice -n 19`、串行、比较前 `clean-cache`）：五 CI job；全枚举 58/58；`check src/compiler`；`selftest-types`；构建确定性 ×2。
- [ ] **Step 2: 判据复验**：重建基线（T0 白名单）× 同源对拍（72 档）· 探针全集 · **build 面采集器（T1 产物）复跑 ⇒ 命中面 = 豁免表**（**逐条等式判据**，本批的核心不复现性判据）· canary · 自举链 · `.ccr` 四条 · `--dump-objects` · `.cir` DOT。
- [ ] **Step 3: 统一台账**：逐任务列 {实施 / 收紧 / 豁免 / 修复 / 语料处置 / 登记 / 偏差}——与各任务实际 diff 逐条对应；**豁免表终稿（含每条 exit 条件）单列一节**。
- [ ] **Step 4: 文档**：`docs/error-codes.md`（判定面语义 + 闸门机制 + 豁免表指针）· `CLAUDE.md`（若新增 `tools/baseline/build_gate_run.sh` 或新套件 ⇒ 相应节补一行；`.cr` 清单无变化则不写）· `TODO.md`（Fail-closed 条目 + 转独立批登记 + 豁免退出条件追踪）· 本计划实施记录。
- [ ] **Step 5: 批终态陈述（一页）**：「已实施 / 已豁免（含退出条件）/ 剩余登记 / 下一批指向」四栏。
- [ ] **Step 6: 提交**（路径限定）。

**判据**：五 CI job + 全枚举 + canary + 自举链 + 同源对拍 + 探针 + **命中面=豁免表的逐条等式** + 台账逐条可溯源 + 文档指针链闭合。

---

## 风险面（本批最大风险 = **一次改动让大量既有语料转红**）

| # | 风险 | 缓解（硬要求） |
|---|---|---|
| R1 | **转红面超预期**（套件 job 7 档 + 49 档 py 内联源的未知命中面） | T1 **先量后改**（零源码改动采清单）+ T2 逐档归因 + 停条件「>10 档 / >1/3 ⇒ 转独立批」+ 分批开门（批次 1 = 全豁免保绿，批次 2..n 只减不增） |
| R2 | **ELF canary 不可产**（B04 命中 canary 载体） | 裁-FC-3 三选一（本批推 (ii) 豁免）+ T5 判据「canary 不可产 ⇒ 立即停下」 |
| R3 | **豁免表变成新的静默面**（码级豁免在别处静默放行） | 表只减不增 + 每条 `exit` 条件 + **每次开新面必重跑 report-only** + 台账单列一节 + 突变 M2/M3 咬合 |
| R4 | **两面语义分歧长期化**（check ⊃ build） | 裁-FC-1 + 表 0 成文化 + `docs/error-codes.md` 记明差异 + CI 自述块 |
| R5 | **零产物语义误删用户文件** | 只删**本次写入**的 `<out>.ccr`（`save_ccr` 成功后 + `corearch` rc≠0）；旧产物不动；用例覆盖 |
| R6 | **判据腿失效**（若取「两面同闸」，72 档/探针两条对拍腿的「零差异」判据换代） | 裁-FC-1 推荐 (C)；若取 (B) ⇒ 先出「新期望分布 + 逐档归因」再开门 |

---

## 未决项与登记（**不猜**）

- **U-1（维护者裁定原文）**：本批的章程前提 = 「要改、方向 = fail-closed」，来源 = 协调者转述，**无独立文件载体** ⇒ T0 表 E 核录；**无原文则本批停在 T2**。
- **U-2（`测试面 `check` rc 分布 vs `build` 面）**：72 档 runner 只跑 `check`（`parity_run.sh:36`），**build 面无既有 runner** ⇒ T1 必须新建（`build_gate_run.sh`）；「命中面」的完整定义**在本批首次建立**。
- **U-3（安全检查面的反向不一致）**：`region_check`/`provenance_verify` 只在 build/ccr 面跑 ⇒ 存在「check rc=0 / build rc=1」档（本实例**未构造具体语料**）⇒ T1 实测登记（不得当已知事实引用）。
- **U-4（TM04 的打印前缀）**：现行以 `error[TM04]` 打印但语义声明为软面（`main.cr:159`）⇒ 「报错即拒」与「软面」字面冲突 ⇒ 裁-FC-2(d)。
- **U-5（≈104 个「定义零 raise」码）**：`ast.cr` 定义 ≈146 / 可达 42 ⇒ 其余为**死码面**（本批不删、不改、登记；删除属独立决定，照 `tools/module_to_ccr.py` 的「只标废弃不删」先例）。
- **U-6（LSP 面）**：`src/lsp/lsp.cr` 消费 `g_diag_count` 但**不产生产物** ⇒ fail-closed 不适用（表 0 登记）。
- **登记维持（不做，理由写死）**：`EXPR_FOR` 元素类型恒 int（E-6/裁-P6-4）· `.csr`/TagNode（验证切片轮）· 容量批（E-2/E-3/E-4）· `string == int` 混比（裁-P6-3）· `--verify-named-dedup` 保留（裁-P6-2(e)）——**本批一律不动**。

---

## 自检记录

- **本计划的自我限制（诚实登记）**：**本计划未跑任何构建/测试/`jj` 命令**；所有「现状值」= 实读源码/文档或既有报告记录值（出处逐条标注）；需实测的数字（基线重建 sha、build 面命中清单、套件面命中档数、转红面逐 job 计数）一律留给 T0/T1 的实测步。
- **判定面清点的诚实性**：「42 可达码」= 全仓 grep 三形态（`check_error(EC_*` / `diag_type_incompatible(…, EC_*` / `DIAG_REC_SIZE, EC_*`）去重实得 43 减 1 个假命中（`EC_SIZE` 为 `DIAG_REC_SIZE` 子串）；**未**用「源码注释/文档统计」冒充实测（`docs/error-codes.md` 的 ~146 为文档自述值，已标出处）。分诊的 7 条豁免**全部带命中证据或政策出处**；其余 25 条阻断**全部按「判定继续 ⇒ 静默错产物 / 不可信」判据成文**（裁-P6-2(c) 口径），未用一个「大概/应该」。
- **根因 vs 止血**：闸门反转直达根因（**默认允许**是缺口本身，不是名单不全）；豁免表被明确设计为**临时面**（每条带 `exit`）+ 只减不增 + 每次开新面重跑 report-only（防退化成语义黑洞）。
- **与既有裁决的一致性复核**：不回退 TM03/TG02（#31/#33）、TS01-04/TK02（#29）、ICE04（P-A）、TA02（#32）、F2/R002（先例即入闸依据）；TM04 的「软面」裁定经裁-FC-2(d) 显式处置（**不得**由实施者私自改判）。
- **占位符扫描**：无 TBD；「须 T1 实测」逐处给出测量命令或产物格式；六条裁决门**逐条点名问句**，未用「推荐」冒充裁定。
- **本批最大风险（一句话）**：**一次反转会让 CI `suite` job 至少 7 档（TF01×5/TF07×1/B04×1）与 ELF canary 载体同时转红——而 canary 载体 `ptr_arith.cr` 自身就是 check rc=1 档 ⇒ 不先取裁-FC-3，本批无法开门。**

---

## 勘误与进展（2026-09-14，TC02 极小批落地后回填）

- **本条只动一处**：表 1 第 10 行（TC02）的处置由「① 必须阻断」改判为「**已修**（真误报）」。归因报告 = `/tmp/fct1/tc02_attribution.md`；设计稿 = `/tmp/fct2/tc02_minibatch.md`；落地 = `checker.cr` 新增 `stmt_diverges` + EXPR_IF 合并点守卫（P3：**仅 else 支发散 ⇒ 不报**；不对称是有意的）。
- **对「表 2 转红面」的影响**：`test_native_float` 从「裸反转 6 档红套件」中**移出**；CI `selfhost-tests` 的裸反转真红面由 **6 → 5 档**（`test_ccr_types` [TF07+TB01] · `test_interp_float` [B04] · `test_interp_parity` [B04] · `test_match_exhaust` [TM04] · `test_xcut_iface` [TK01]）。
- **对「豁免表草案」的影响**：`/tmp/fct1/exemption_draft.tsv` 的 **TC02 条目可撤**（退出条件「逐例归因后」已达成）⇒ 豁免表初稿由 **10 码降为 9 码**（TF01 · TF07 · TB01 · TM04 · TK01 · N01 · N06 · N11 · B04）。**表调整由 FC 批 T2 统一执行**（维护者 2026-09-14 裁）。
- **未覆盖面（本批不判，登记）**：`break`/`continue` 收尾的分支（需循环上下文）；`x := if c { } else { return 1; }`（值被用且 else 发散）形态按 P3 不报（if 型 = `then_ti` = unit 是真值 ⇒ 误用由 TA02/TF01 兜住；**未构造端到端用例**）。

---

## 勘误与进展（2026-09-15，FC 批 T2 落地后回填）

- **本条 = 本计划的 T2 段落地记录**（设计稿 = `/tmp/fct3/fc-t2-impl-draft.md`；报告 = `.superpowers/sdd/fc-task2-report.md`）。
- **落地形态（与设计稿的差异逐条）**：
  1. **`diag_gate_exempt` 落 `diag.cr`**（表 9 条；`scope` 常量落 `globals.cr`）——照设计稿，零清单改动（`main.cr`/`globals.cr`/`diag.cr` 均在 corec 清单内；`corearch_files` 不含 `diag.cr`）。
  2. **类型面闸反转**（`main.cr` 硬判定循环 → `diag_gate_exempt(ec, GATE_SCOPE_BUILD) == 0 ⇒ hard = 1`；旧 6 语句行/11 码名单整体退役）；**语法面 `:134/:135` 与安全检查面 `:594-603` 不动**（照设计稿）。
  3. **零产物删除点**：`exit_code := system(cmd2)` 之后 `if exit_code != 0 { system("rm -f \"<ccr_path>\"") }`（只删**本次**写下者；既有旧 `<out>` 不删——裁-FC-6）。
  4. **新增（设计稿未含）= 进度行保真修正**：`[5/5] frontend done` 由「仅 `hard==0` 路径」改为「诊断之后、返回之前一律打印」⇒ 72 档语料日志除**纯行号偏移**外零差异（否则 25 档会缺该行）。**唯一可见差异 = 探针 `n05_recursive.cr` 多一行**（其 `TS03` 属旧硬名单 ⇒ S0 提前返回无该行）。
  5. **新套件** = `tests/selfhost/test_diag_gate.py`（**17 例**：正控 9 + 负控 6 + 零产物 3）+ `run.sh` 挂点（设计稿写 ≥14；实际 17）。
- **对表结论**：**无表外命中**（T1 `would_block.tsv` 的 7 条 build 面行全部放行、34 条 check 面行逐条不变；T1 的 6 档红套件全绿）。**豁免表 = 9 条**（10 − TC02；TC02 已在 `7f53305d` 修掉）。
- **72 档差异口径（先例继承）**：日志差异 **2 档 = 纯行号偏移 +53**（编辑编译器自身源码 ⇒ 语料含编译器 ⇒ 行号位移；先例 = P6 T2 的 +146）；rc 分布两侧 34×0/38×1 零差异。
- **新登记（本批施工中发现，另批）**：**安全面诊断随 `.cir` 暖缓存静默消失**（冷 rc=1 / 暖 rc=0 出 ELF；P6 期二进制同病 ⇒ 预存）⇒ TODO #60（含派生建议：两条 runner 加「暖态腿」，**本批不实施**）。

## 勘误与进展（2026-09-15，FC 批 T3 落地后回填）

- **T3 = 隐藏通道 `--diag-gate-report`**（默认关；同 `--verify-*` 家族纪律）：注册于 `main.cr` 的 `cli_flag_bool` 段；输出 = 闸门内只读报告行 `[diag-gate] face=build blocked=N total=M codes=…`（用户面码名）。
- **判据**：**默认关两态零差异**（72 档 `diff -rq` 零 + 探针 29 零）· 开态 rc/产物 sha 逐字节同（仅多一行标记）· 重放 101 档 **无表外命中**（语料 25 档 blocked 与 T1 的 34 行 − 7 build 豁免 − 2 P21 对齐；探针 11 档 = T1 未覆盖面，口径差登记）· 五 CI 5/5 · 枚举 60/60 · canary IDENTICAL · `.ccr` 四条同 · 链 `24802386a1…` IDENTICAL · `backend_bootstrap` rc=0。
- **口径注**：报告面只覆盖**前端类型面闸**（`g_diag_count > 0` 块）；**解析阶段闸**（`:134/:135`）与**安全检查面闸**（`:594-603`）的诊断不出现在报告行中（前者如 P21、后者如 TU03）——重放对表时须按此口径解读。
- **环境干扰事件（非本批代理所为，登记）**：T3 测量期间 `build/`（整目录）两次被外部删除、`examples/*.ccr` 等 7 个 tracked 文件被删（`jj status` 见 `D`）、`/tmp/fct3/parity_*/parity.out` 被删 ⇒ 首轮 parity/probe 腿作废（rc=127 满屏）；重建后（corec sha 复原 `308f06a3…`）**全部重跑并取有效值**。**未提交、未还原**那 7 条 `D`（铁律 #3）。
