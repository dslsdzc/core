# TF01 收口报告：两条长期误报面（落空分析缺失 + `lits_copy` 类型洗白）

日期：2026-09-13 · 基线：`3d604e11`（P4 Task 2 收官）· 口径：全部命令 `nice -n 19`、cwd = 仓库根、
一构建一编译串行、`.ccr`/缓存面比较前 `clean-cache`、仓库文件零改动（突变面全在 `/tmp`）。
目标：`check src/compiler` 的两条 `error[TF01]`（长期被当作「既有 red 划界」）根因修复 + 解阻 P4 Task 2 的 corearch 清单步。

---

## 0. 交付摘要（TL;DR）

| 项 | 结果 |
|---|---|
| 诊断定性 | `lits_copy` = 真·类型洗白（`alloc` 模型返回 `string`，声明 `-> int`）；`ty_memo_slot_no_grow` = checker 误报（体以无 break 的 loop 收尾 因此 不落空） |
| 修法 | (a) checker 新增落空分析（`stmt_cannot_fall_through`/`loop_body_has_break`/`seg_has_break`）挂站点 5；(b) `lits_copy -> string` + `lits_contradictory_buf(buf: string, …)` |
| `check src/compiler` | rc=0 · 诊断 0 条（目标达成） |
| 构建 | `build_selfhost_native.py` rc=0；GUARD：corec 45 / corearch 32（+`type_engine.cr`）/ corelsp 31；三条 `build log clean (error[ = 0, undefined = 0)` |
| project-mode 门 | `test_backend_bootstrap.py` rc=0（11 PASS / 0 FAIL / `error[` = 0），Task 2 第9-② 收口路径 (a) 兑现 |
| 自测 | `selftest-types` 338/338 |
| ELF canary | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475` IDENTICAL（清单步前后各一次） |
| 全枚举 | 47 selfhost + 7 bootstrap 全 rc=0（第二轮 = 定稿二进制；第一轮暴露 3 条过期期望，见 第6） |
| 自举链 | `full-bootstrap` job rc=0：`corec2 == corec3` cmp IDENTICAL `991eecc1…b2ba`（双 2604942B）+ N06=0 + 冒烟 42（corec/corec2 双通道）+ `corec3 --help` rc=1 |
| 突变控制 | 5 条（过接受 / 过拒绝 / 嵌套截断 / match 臂链 / 连续段），逐条单点转红，仓库零改动 |
| 同源对拍（check 面） | 30 档 `tests/suite` 语料：旧 vs 新二进制 输出与 rc 逐字节同（零差异）；自源 = 恰差那 2 条 TF01 |
| 新增回归套件 | `tests/selfhost/test_tf01_fallthrough.py` 19 例（正控 10 / 负控 8 / 端到端 1），挂 `src/ci/run.sh` selfhost-tests |

---

## 1. 复现与定性（探针；先于修复，用旧二进制 `/tmp/tf01/bin_pre/corec` = `c910df2d…`）

| # | 探针（最小形） | 旧二进制 | 新二进制 | 定性 |
|---|---|---|---|---|
| p1 | `fn f() -> int { b := alloc(8); return b; }` | rc=1 TF01×1 | rc=1 TF01×1 | 真错（`lits_copy` 同形）：`alloc` 类型模型 = `() -> string`（`checker.cr:278` `bi_add("alloc", TI_STR)`）因此 声明 `int` = 类型洗白 |
| p2 | `fn f() -> string { b := alloc(8); return b; }` | rc=0 | rc=0 | 模型一致写法（修法方向） |
| p3 | `fn f() -> int { loop { return 5; } }` | rc=1 TF01×1 | rc=0 | 误报（`ty_memo_slot_no_grow` 同形）：体以无 break 的 loop 收尾 因此 运行时永不到函数尾 因此 「末语句类型 = unit」不是缺返回值的证据 |
| p4 | `fn f() -> int { 1 + 1; }` | rc=1 TF01×1 | rc=1 TF01×1 | 真落空（负控基准，不变） |

自源直接证据：`check src/compiler` 修复前 = 恰 2 条 TF01（`lits_copy` / `ty_memo_slot_no_grow`，行号随源码变化：本轮 10236/10459），修复后 = 0 条。
消费面证据（为什么 `lits_copy` 该是 `string`）：`lits_copy` 的返回值只流向 `lits_contradictory_buf`（其另一调用点传 `g_ty_lits : string`）与 `r64(buf: string, …)`，整条链都是字节缓冲面；改声明（而非改 `alloc` 模型）= 与模型对齐且零行为变化。

---

## 2. 修法

(a) checker.cr（站点 5 落空分析；新函数 3 个，插在 `scan_for_yield` 之后）
- `loop_body_has_break(node)`：循环体内是否存在直属本循环的 break。嵌套 `loop/while/for` 处截断（break 归内层）；子槽遍历按 `monomorph.cr:gen_clone_tree` 的完整枚举逐类下钻（`EXPR_LET` 只下钻 b/c、`EXPR_ENUM_CONSTRUCTOR`/`EXPR_AT` 的 a 是名 ni 不是节点、`EXPR_MATCH` 臂 = `c` 链非连续槽、`EXPR_GO` 体在 b）；未枚举形态后备 = 1（按「可能有 break」）= fail-closed。
- `seg_has_break(first,count)`：连续 wrapper 段（STRUCT/STRUCTPAT/ENUMPAT/GENERIC_APPLY/ARRAY/TUPLE），越界由 `g_ast_count` 后备。
- `stmt_cannot_fall_through(node)`：只认不产出值的不可落空形态，无直系 break 的 `loop`、双分支皆不可落空且有 else 的 `if`、`STMT`/`UNSAFE`/嵌套 block 包裹；block = 任一语句不可落空。`return` 明确不判 divergence（它带返回值，其值类型正是站点 5 的被检对象，豁免它 = 洗白 `lits_copy` 型真错面）。
- 站点 5 接线（一行）：`if compat != 1 && body_ti != TI_NEVER && stmt_cannot_fall_through(body) == 0 { diag }`。
- 保守性纪律：未知形态一律回「可落空」（照旧 TF01），真落空体绝不溜过。登记：非落空体内的 `return` 值类型不核对（checker 现模型无逐 return 核对面；该面 = 既有面，非本批引入；见 第9-③ 与套件 `pos_boundary_no_return_value_check`）。

(b) type_engine.cr（真错面）：`lits_copy(p: int) -> int` 到 `-> string`；`lits_contradictory_buf(buf: int, n: int)` 到 `(buf: string, n: int)`（两调用点传的全是 string）。返回型注释写明依据（`alloc` 模型 + 消费面）。
(c) ty_shadow.cr：`sh_map_find_nogrow` 头注「已知误报面」改写为「该误报已修」（原文被 TODO/计划引用，故同批更正）。

---

## 3. 判据（逐条 = 命令 + 结果）

| # | 判据 | 命令 | 结果 |
|---|---|---|---|
| 1 | 目标 | `nice -n 19 ./build/corec check src/compiler` | rc=0，`error[` = 0 |
| 2 | 构建 | `nice -n 19 python3 build_selfhost_native.py` | rc=0（三 GUARD clean；`/tmp/tf01/build4.log`） |
| 3 | project-mode 门 | `nice -n 19 python3 tests/selfhost/test_backend_bootstrap.py` | rc=0，11 PASS，`error[` = 0（`/tmp/tf01/tbb2.log`） |
| 4 | 类型引擎自测 | `nice -n 19 ./build/corec selftest-types` | 338/338（`/tmp/tf01/selftest.log`） |
| 5 | ELF canary | `clean-cache` 到 `build tests/suite/ptr_arith.cr` 到 sha256 | `95084e7b…d475` IDENTICAL（`/tmp/pa_tf01` 修复后、`/tmp/pa_tf01b` 清单步后） |
| 6 | 全枚举 | `bash /tmp/tf01/enumerate.sh`（47 selfhost + 7 bootstrap） | 第二轮 54/54 rc=0（`/tmp/tf01/enum_all2.log`；逐档 `/tmp/tf01/enum/*.log`） |
| 7 | 自举链 | `CI_JOB_NAME=full-bootstrap bash src/ci/run.sh` | rc=0；`cmp /tmp/corec2 /tmp/corec3` IDENTICAL `991eecc1…b2ba`（双 2604942B）；N06=0；冒烟 42×2；`corec3 --help` rc=1（`/tmp/tf01/cifull.log`） |
| 8 | 其余 CI job | `CI_JOB_NAME={check,suite,bootstrap-tests,selfhost-tests} bash src/ci/run.sh` | 全 rc=0：check（`ok`）· suite（21 档 ALL PASS）· bootstrap-tests（3/3）· selfhost-tests（新套件在内 19/19；`/tmp/tf01/ci_*.log`） |
| 9 | 新回归套件 | `nice -n 19 python3 tests/selfhost/test_tf01_fallthrough.py` | 19/19（`/tmp/tf01/suite3.log`） |
| 10 | 突变控制 | 5 条（第5） | 逐条单点转红 |
| 11 | 同源对拍（check 面） | 30 档 `tests/suite` 语料 × {旧，新} 二进制 | 零差异（输出 + rc 全同；`/tmp/tf01/parity/`） |

---

## 4. 行为面 delta（精确刻画）

1. 语料零命中：30 档 `tests/suite` 语料上，旧/新二进制 `check` 输出与 rc 逐字节同（无任何语料含「体以无 break 的 loop 收尾」形）。
2. 自源 delta = 恰 2 条 到 0 条（即本次修复的目标本身）。
3. 接受面放宽 = 恰一类：体确定不能落空（无直系 break 的 loop / 双分支皆不可落空的 if-else / 其包裹）的函数体不再判 TF01。放宽面由 8 条负控（真落空体仍拒）+ 5 条突变控制钉住。
4. 发射面零泄漏：ELF canary 逐字节同（两轮）；`.ccr` 面未比对（本批不在判据内），但核心判据 ELF + 自举链 + 全枚举同证。

---

## 5. 突变控制（5 条；`/tmp` 侧「清单照旧 + 内容替换」构建，仓库零改动；harness = `/tmp/p4t2/mutmut/build_mut.py`，`MUT_ONLY=corec`）

| 突变 | 内容（`checker.cr`） | 期望 | 实测 |
|---|---|---|---|
| M1 过接受 | `stmt_cannot_fall_through` 恒 `return 1` | 8 条负控转红（不报错地接受） | 11/19：恰 8 条 `neg_*` 全红（`rc=0 TF01×0`） |
| M2 过拒绝 | `loop_body_has_break` 恒 `return 1` | 正控转红（误报回归） | 10/19：恰 9 条 `pos_*` 全红 |
| M3 嵌套截断失效 | `EXPR_LOOP` 自截断分支去掉 | `pos_nested_loop_inner_break` 红 | 18/19：该档红（其余 18 绿） |
| M4 match 臂链失效 | `EXPR_MATCH` 分支短路（`&& 0 == 1`） | `pos_match_no_break` 红 | 18/19：该档红（负控 `neg_match_break` 仍绿 = 后备保守方向，符合设计） |
| M5 连续段失效 | `EXPR_ARRAY` 段分支短路 | `pos_array_no_break` 红 | 18/19：该档红 |

突变二进制 sha（`corec`）：M1 `fcb5bbf8…` / M2 `da45a94b…` / M3 `649c2929…` / M4 `5ccd19d4…` / M5 `1d212872…`，与仓库 `b952535e…` 全不同；仓库源码在突变前后由 `jj status` + 本报告 第7 提交面证明零改动。

---

## 6. 第一轮全枚举暴露的 3 条过期期望（`test_iface_ops`，已随批更新）

第一轮枚举 = 46/47 selfhost + 7/7 bootstrap（唯一红 = `test_iface_ops` 73/76）。三条 FAIL 均为「期望 2 条诊断、实得 1 条」：少掉的恰是 第1 的同一误报类（体以无 break 的 loop 收尾 + 声明 `-> never`）：

| 用例 | 旧期望 | 新期望 | 依据 |
|---|---|---|---|
| `t6_C_never_call_unit` | `TF01@1, TF07@2` | `TF07@2` | `fn g[T](a: T) -> never { loop { } }` 语义上确是 never 函数 因此 TF01@1 为误报；关注面（调用位点 unit 后备 到 TF07@2）不变 |
| `t6_S1_never_unit` | `TF01@1, TF01@2` | `TF01@2` | 同误报类；S1 链域面（`never` 落 unit 到 TF01@2）不变 |
| `t6_S6_iface_never_unit` | `TF01@3, TF07@4` | `TF07@4` | 同误报类（impl 体）；S6 iface 返回链面（到 TF07@4）不变 |

三条用例的关注面诊断全部原样保留（行号亦不变），仅去掉误报项；三处均加注说明。改后 `test_iface_ops` 76/76 rc=0（`/tmp/tf01/iface_ops2.log`）。

---

## 7. P4 Task 2 阻塞步（corearch 清单），已解阻

- `build_selfhost_native.py` `backend_support_files` + `src/targets/x86_64-linux/_import.cr` 两面同批插入 `src/compiler/type_engine.cr`（位置 = `type_terms.cr` 之后、`ccr_io.cr` 之前；依赖面实查：`type_engine.cr` 的外部符仅 `alloc/r64/w64/_dyncpy/tt_*` + globals，无 checker/parser/影子层引用）。
- 结果：corearch 清单 31 到 32 文件；concat 与 project-mode 两侧 `error[` = 0；`test_backend_bootstrap` rc=0；ELF canary 仍 IDENTICAL；全枚举第二轮 54/54。
- 说明：`type_engine.cr` 在 corearch 链接集内当前零消费者（死码），本步的目的 = 解阻 T2 报告 第9-② 的「判定原语（`ty_sub` 族）跨进程同值」探针面（后续批次可接）；corearch 二进制因而变大（`32166aae…` 到 `6ee8057b…`，非判据面，B.4-18 先例）。

---

## 8. 提交

`6822102a`（change `xwquztnr`）路径限定 12 文件：`src/compiler/checker.cr` · `type_engine.cr` ·
`ty_shadow.cr` · `build_selfhost_native.py` · `src/targets/x86_64-linux/_import.cr` · `src/ci/run.sh` ·
`tests/selfhost/test_tf01_fallthrough.py`(A) · `tests/selfhost/test_iface_ops.py` · `TODO.md` ·
`docs/superpowers/{plans/2026-09-11-r2-p3-capabilities.md, plans/2026-09-12-r2-p4-carrier.md,
implementation/2026-09-10-type-shadow-findings.md}`。`jj diff -r 6822102a --summary` 核过 = 恰上列
（M×11 + A×1）；提交后 `jj status` = 工作副本无改动（空提交 `e3279135`）。
定稿重建可复现：`build/corec` `b952535e…` / `build/corearch` `6ee8057b…`（注释级改动后重建 sha 不变 因此 定稿源码 ↔ 定稿二进制对应）。
（注：`docs/archive/sdd/*` 不入版本控制，本报告与 P4 T2 报告的同批注记以工作副本为准。）

---

## 9. 登记面（不在本批范围 / 发现即登记）

① TF01 对 `build` 非致命（既有面，实测）：含 `error[TF01]` 的源经 `corec build` rc=0 且照出产物（该产物运行正常，rc=42），只有 `check` 以非零反映任意诊断（F19）。故本批修复的实际收益面 = `check` 门（CI `check` job / 工具链 / 清单门），不是运行期行为。测量：`/tmp/tf01/cases/m2_build2.out`（用 M2 突变二进制：TF01×1 + rc=0 + 产物 + 运行 42）。
② `while <标识符> { … }` 被当结构体字面量解析（既有 parser 缺陷，本批不修，登记）：`parse_while_expr`（`parser.cr:990`）缺 `parse_if_expr` 同款的 `g_parse_no_struct_literal` 守卫 因此 `while c { break; }` 解析失败（63 条 `error: Unexpected token in expression`）。旧二进制同款复现 因此 非本批引入。探针用 `while c == true { … }` 规避（套件 `neg_while_conservative` 注记同此）。
③ 非落空体内 `return` 值类型不核对（本批显式登记的放宽面）：`fn f() -> int { loop { return "x"; } }` 由「旧：误拒」变「新：接受」，checker 现模型无逐 return 核对（且逐 return 核对需重跑推断 = 副作用风险，本批不做）。套件 `pos_boundary_no_return_value_check` 以注释钉住该边界，若未来引入逐 return 核对，该例期望随之改拒。
④ 影子通道未跑（本批判据外）：落空分析不触 `type_equal` 采样面（站点 5 的判定入口不变），故未复跑 P1 影子对拍；如需，跑法同 P3a/P3b 台账。

## 10. 证据路径（本机）

- 探针：`/tmp/tf01probe/*.out` · `/tmp/tf01/probe3_*.out` · `/tmp/tf01/cases/*`
- 构建：`/tmp/tf01/build{1,2,3,4}.log`（1/2 = 构建器自身缺陷两修：ty_shadow 重复 fn 行、落空分析误豁免 return）
- 判据：`/tmp/tf01/{selftest.log, tbb2.log, canary2.log, cifull.log, suite3.log, iface_ops2.log, check_src3.out}`
- 全枚举：`/tmp/tf01/enumerate.sh` + `enum_all.log`（一轮）/ `enum_all2.log`（二轮）+ `enum/*.log`
- 对拍：`/tmp/tf01/parity/*`（30 档 × 旧/新）
- 突变：`/tmp/tf01/mut/`（`gen_mut.py` + `checker.mut{1..5}.cr` + `run{1..5}/` + 构建/测试日志）
