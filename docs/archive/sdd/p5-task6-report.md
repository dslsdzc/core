# R2 P5 Task 6 报告：TODO #32，`EXPR_LET` 站点判定点

状态：完成。判据全部通过；有 2 项裁决、1 项语料修正、1 项登记，见第 6 节。

任务面：`docs/superpowers/plans/2026-09-13-r2-p5-cleanup.md` Task 6；TODO #32；发现来源是 `p3-task1-report.md` 第 6 节第 ① 条。
起点：`build/corec` 为 `2342fd03…`（P5 Task 5 收官 `66316751`，工作树干净）。
产物：`src/compiler/checker.cr`（判定函数加两个调用点）、`src/compiler/main.cr`（硬名单条目）、`tests/selfhost/test_let_check.py`（新，24 例）、`tests/selfhost/test_named_face.py`（1 例语料修正）、`docs/error-codes.md`、`src/ci/run.sh`、TODO.md、本计划 Task 6 记录。证据在 `/tmp/p5t6/`。

---

## 1. RED（Step 1；本任务自跑，两代二进制同值，说明是预存问题）

| 探针 | 源 | 冻结基线 `/tmp/p5t0/base/corec`（pre-P5） | 本批起点 `2342fd03…` |
|---|---|---|---|
| red1 | `fn h(s: [int]) -> int { x: [int;3] = s; ... }` | check rc=0，0 诊断 | check rc=0，0 诊断 |
| red2 | `fn main() -> int { x: [int;4] = [1,2,3]; ... }` | rc=0，0 诊断 | rc=0，0 诊断 |
| red3 | `x: int? = 5; y: int = x;` | rc=0，0 诊断 | rc=0，0 诊断 |
| red4（本任务加） | `x: int = "s";` | rc=0，0 诊断 | rc=0，0 诊断 |
| red5（正控） | `fn main() -> int { return 0; }` | rc=0 | rc=0 |

命令（cwd 为仓库根，`nice -n 19`）：`./build/corec check /tmp/p5t6/redN.cr`。结论：`EXPR_LET` 站点（局部）和 `check_global_let`（全局初始化器）没有任何兼容检查。符号取注解行，后端按注解行发射，结果是不报错地错产物。全仓 grep：`EC_TA_DECL`（TA02）已定义但零 raise（`ast.cr:408` 与零调用点）。

## 2. 实现（Step 2/3）

判定函数（`checker.cr`，紧邻 `diag_type_incompatible`）：

```core
fn check_let_annot_compat(node: int, val_node: int, val_ti: int, ti: int) {
    type_node := ast_b(node);                          // EXPR_LET: b = 注解类型节点（-1 = 无）
    if type_node < 0 || val_node < 0 { return; }
    if ti == TI_DYN { return; }
    if val_ti == TI_NEVER { return; }
    if get_type_kind(ti) == TYP_GENERIC_PARAM { return; }
    compat := type_compat_strict(val_ti, ti);
    if compat != 1 {
        diag_type_incompatible(compat, EC_TA_DECL, "Variable declared as " + type_display(ti) + ", got " + type_display(val_ti), ast_line(node), ast_col(node));
    }
}
```

两个调用点，共用，单点豁免面：
- `infer_expr` 的 `EXPR_LET` 分支（局部），在 `ti` 计算之后、`def_sym` 之前调用 `check_let_annot_compat(node, val_node, val_ti, ti);`。
- `check_global_let`（全局初始化器）。原函数只 `infer_expr(val_node)` 并丢掉结果，现在补上 `ti` 计算和同样的调用。

参数顺序：源是 `val_ti`（初始化值），目标是注解行 `ti`，照 P3 Task 1 第 3.1 节归一，与赋值位点 `:3285`、返回位点 `:2194` 相同。

豁免四条，各附理由，见函数头注：

| # | 豁免 | 理由 |
|---|---|---|
| ① | 无注解（`: .` / `: auto`，`type_node < 0`）或无初值（`val_node < 0`） | 没有契约可核（parser 对 `:=`/auto 都写 `typ = -1`） |
| ② | 注解为 `dyn` | dyn 槽按值追踪，照赋值位点 `tt == TI_DYN` 分支和本站下行 `dyn_set_type` |
| ③ | 值为 `TI_NEVER` | 底部，照返回位点 `body_ti != TI_NEVER`；表达式层 TI_NEVER 是错误标记，因此抑制诊断级联（探针 r1/r3：`x : int = nosuchname` 只发 N01，`= nosuchfn()` 只发 N06，没有二次 TA02） |
| ④ | 注解 kind 为 `TYP_GENERIC_PARAM` | 声明期不可验证，照返回位点既有策略（`fn f[T](v: T) -> T { return 5; }` 现在就是 rc=0，探针 v1）。套件 `let_generic_param_annotation_not_judged` 把两个站点同策略一并钉住 |

硬错门：`main.cr` 硬名单新增 `if ec == EC_TA_DECL { hard = 1; }`，附开门依据注。因此 `build` rc=1 且无产物，拒绝位置在 `[4/5] type check` 之后、`lower to ccr` 之前。

GREEN（三种形态转闭）：red1/red2 报 `error[TA02]: Array length constraint not satisfied`；red3 报 `error[TA02]: Variable declared as int, got int?`；red4 报 `error[TA02]: Variable declared as int, got string`。全部 check rc=1，build rc=1，且没有 `.ccr`/ELF。

## 3. 裁决（计划 Step 2/3 的“先裁决”两处）

| # | 议题 | 裁决 | 依据 |
|---|---|---|---|
| 裁-A | 用现有码还是新码 | 复用 TA02（`EC_TA_DECL` = 4002） | `docs/error-codes.md` 的 TA02 槽位就是这个面（“变量声明类型与初始值不符 / `Variable declared as {T1}, got {T2}`”），`ast.cr:408` 早已定义且零 raise，复用不需要扩张清单。-1（长度档）的措辞走共享 `diag_type_incompatible`，为“Array length constraint not satisfied”，与 TS03/TK02 同形，已在该码行注明双措辞 |
| 裁-B | 硬错还是软错 | 硬错，加入 `main.cr` 硬名单 | 计划 Task 6 Step 3 明确要求“三红态转 rc=1 且无产物”。硬名单的既有判据是“判定继续就会产出不报错地错产物”（符号取注解行，后端按注解行发射，与 TS01-04/TK02/R002 同族）。report-only 零命中（自源加 72 档），开门零风险 |

划界：覆盖局部 `EXPR_LET` 和全局 `check_global_let`。后者是 TODO #32 点名的 `:1614-1620` 同形缺口，注册趟就会取注解行。第 6 节登记③说明 `#20`（调用位点）不并入。

## 4. report-only 全语料（Step 2，开门依据）

| 语料面 | 结果 |
|---|---|
| 72 档 runner（`/tmp/p3t0_run.sh check`，逐档 clean-cache） | check rc 分布为 34 档 0、38 档 1（与 pre-P5 基线逐档相同）；零 TA02；诊断正文（`error[`/`warning[` 归一化行号）逐条相同（`text_diffs=0 rc_diffs=0`） |
| `check src/compiler`（自源） | rc=0，`error[` 为 0 |
| 58 套件全枚举（tests/selfhost 内联源加 tests/bootstrap，逐套件实跑） | 58/58 rc=0（修正第 5 节的 1 例后）；全日志 `error[TA02]` 命中 0 |
| 修正前枚举（同一枚举器，先跑） | 1 例命中：`tests/selfhost/test_named_face.py::named.in_container_same`（2 条 TA02），见第 5 节 |

计划预期的命中面实测为零：泛型函数体内 `T` 注解走豁免④，且同链走快路径；`[T;N]` 表示提示位，探针 q4 `x : [T; 2] = [v, v]` 为 rc=0；可选注入面，目标为 `T?` 时 `type_compat_strict` 的注入分支放行（探针 q5/p5/p6 均为 rc=0）。这些都是逐条实跑，不是推断。

## 5. 命中 1 例的裁决和修正（收紧台账的核心条目）

命中：`tests/selfhost/test_named_face.py`（P5 Task 3 的套件）`named.in_container_same` 内联源：

```core
p : *NA = 0;
q : *NA = 0;
```

裁决是修语料，不放松检查。三条独立证据：
1. 赋值位点早已拒绝同形（冻结基线和 T6 二进制同值，探针 t1）：`a : *N ← a = 0` 报 `error[TA01] Assignment type mismatch`；`a = None` 同样；`a = b`（指针赋指针）rc=0。也就是说，`*T ← int` / `*T ← null` 从来不是本语言的合法转换，只是声明位点没有检查。
2. bootstrap（参考实现）对全局面本来就有这个检查：`bootstrap/corec/frontend/type_checker.py::_check_let_decl` 中有 `if inferred and not self._type_equal(inferred, var_type): errors.append(f"Global {name}: declared type {var_type} but initialized with {inferred}")`。因此“声明对初始化”的比对是设计语义，自举编译器这里缺位属于回归。
3. 修正后语义不变：`p : *NA, mut;`（无初值声明）使该套件 18/18，指针身份面（`p = q`）的语义和用例意图逐字保持。

台账条目（旧接受变为新拒绝）：

| # | 形态 | 旧 | 新 | 语料面 | 裁决 |
|---|---|---|---|---|---|
| T6-1 | `x : T = <异型值>`（局部或全局，含切片到定长、异长常量档、可选流窄槽、int 与 string 互转、struct 与 int 互转） | check rc=0（不报错地错产物） | TA02 硬错（build rc=1 且无产物） | 零命中（自源加 72 档加枚举） | 开门 |
| T6-2 | `p : *NA = 0;`（`*T ← int` 字面量）/ `*T ← None` | check rc=0 | TA02 | 1 例（P5 T3 套件内联源，2 行） | 修语料为无初值声明（裁决见上三条证据） |
| T6-3 | `x : T = 5`（注解为泛型形参） | rc=0 | 仍 rc=0（豁免④，与返回位点同策略） | 零命中 | 豁免登记（套件钉住） |
| T6-4 | `x : dyn = 5` | rc=0 | rc=0（豁免②） | 探针 | 豁免 |
| T6-5 | `x : int = nosuchname` | 只发 N01 | 只发 N01（豁免③抑制级联） | 探针 | 豁免 |

## 6. 登记（未覆盖面，不收口）

① `never` 调用面：`fn boom() -> never {...}` 的调用被推断为 unit，不是 never，因此 `x : int = boom()` 新增 TA02。但返回位点今天就有同样问题（`return boom()` 报 TF01，探针 q15，冻结基线同值），同一个既有 `never` 类型化缺口在本站点多暴露一例，不是本检查新引入的类。全语料 `-> never` 计数为 0（src/tests/examples）。根因是调用返回型映射 never，本任务不修，不停车条件触发。
② 计划预期命中面不存在：Step 2 列的“泛型 `T` 注解 / `[T;N]` / 可选注入”三类实测 rc=0（豁免面或正控覆盖），不改判，不放松。
③ `#20`（F3 调用位点无诊断）不并入：本任务按计划文件面（checker、测试、error-codes、run.sh）只落声明位点。实参和返回位点归 #20，本次显式划界。
④ `x = 2` 对不可变变量（TA04）仍不检查（探针 u2 rc=0，run rc=2），这是与本案无关的既有面，未触碰，未登记为新条目。

## 7. 判据（Step 4，全部由本实例实跑；二进制 `f737e26b…`）

| 判据 | 结果 |
|---|---|
| 新套件 `tests/selfhost/test_let_check.py` | 24/24（拒绝 11，正控 13；含无产物、前端拒绝、级联抑制 exact-diags） |
| 语料修正后套件 `test_named_face.py` | 18/18 |
| `selftest-types` | 404/404（不增减） |
| `check src/compiler` | rc=0，`error[` 为 0 |
| `test_backend_bootstrap.py`（CI bootstrap-tests） | rc=0，`error[` 为 0 |
| 五个 CI job（check / bootstrap-tests / suite / selfhost-tests / full-bootstrap） | 全部 rc=0 |
| 全枚举（58 套件，57 加本套件） | 58/58 |
| ELF canary | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`（28822B）IDENTICAL |
| `.ccr` 两套口径（冷态，带标） | `ptr_arith` 90823B `fb4a3b59…` / 90966B `592afa31…`；`generics_test` 135341B `ddec1ce6…` / 135484B `cd2af565…`。与 T5 记录逐字节相同，零发射面泄漏（本任务只改诊断面） |
| 自举链 | `corec2==corec3` 的 `cmp` IDENTICAL（2854910B `5559beef…`），N06 为 0/0，冒烟 42，`corec3 --help` rc=1 |
| 构建确定性 | `build_selfhost_native.py` 连续两次构建 `f737e26b…` 逐字节相同（包含 CI full-bootstrap 重建后 sha 不变） |
| 冻结基线同源对拍（72 档 check） | `text_diffs=0`，`rc_diffs=0`（pre-P5 二进制配当前源对比当前二进制配当前源） |

突变控制 4 条，逐条单点改坏，转红，精确回滚：

| # | 突变 | 转红面 | 回滚 |
|---|---|---|---|
| M1 | 移除局部 `EXPR_LET` 调用点 | 套件 15/24（局部拒绝 9 例全红，全局例仍绿，单点归因） | 源 sha 复原 |
| M2 | 移除豁免④（泛型形参跳过） | 套件 23/24（`let_generic_param_annotation_not_judged` 转红） | 源 sha 复原 |
| M3 | 移除 `main.cr` 硬名单条目 | 套件 20/24（4 条 build 面“不报错地面复活”，rc=0 且产物照出） | 源 sha 复原 |
| M4 | 移除 `check_global_let` 调用点 | 套件 23/24（只有 `let_global_rejected` 转红） | 源 sha 复原 |

回滚证据：`src/compiler/checker.cr` 为 `fff7a8ba…`，`src/compiler/main.cr` 为 `739f7f5f…`，与突变前逐字节相同；三个二进制 `corec f737e26b…` / `corearch 544e9201…` / `corelsp 4251108b…` 逐字节复原。

## 8. 过程诚实项

- report-only 的形态：本任务的 report-only 是“检查已接入、诊断已发”的全语料跑（照 T4 的 ICE04 先例：先跑、审清单、再决定入硬名单），不是“不报错地计数”变体。命中面由 `error[TA02]` 直接给出行列和两侧类型，比计数更强。
- 首跑暴露的枚举缺口：72 档 runner 不含 tests/selfhost 的内联源（它们是 Python 套件里的字符串），首轮 `selfhost-tests` CI 才暴露第 5 节的命中。本轮把“58 套件全枚举”并入 report-only 语料面（Global Constraints 第 6 条本来就点名“tests/selfhost 内联源”）。后续任务引用本报告时请按此口径。
- 一处误判自纠：`SLICE_SRC` 常量初版误用 f-string 双花括号，已在运行前修正。
- 停机条件核对：自源（`src/compiler`）零命中，不触发“self-host hits 就 STOP”。命中面是 1 例，且不涉及语义裁决（赋值位点与参考实现双证），按“先 report-only 加清单审查”正常开门，未触发“命中面涉及语义裁决”的停车条件。如果维护者认为 `*T ← 0`/`*T ← None` 应作为 null 初始化放行，回退面是两个站点同改（声明位加赋值位），并重开第 5 节条目。
