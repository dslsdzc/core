# R2 P3b Task 0 报告：`iface_satisfies` 契约回补（P2b 交接面 ① 的交付）

日期：2026-09-12 · 基线：`aa54d26a`（P3a errata；工作副本起点）
任务：P3 计划「与 P2b 的交接面」① + 附录 B.1 唯一阻塞项，`iface_satisfies` 未交付。
范围：契约 + 接线点（不是 P3b 的 Task 2/6 全部；Task 2 形状条目细化与消费点换位、Task 6 签名类型项化/mangling 退役仍归其各自任务）。
报告口径：所有数字 = 本机实跑（`nice -n 19`，cwd = 仓库根，一构建一编译串行）；未跑的一律标「未跑」。

---

## 0. 交付摘要（摘要）

| 项 | 结果 |
|---|---|
| 契约 | `iface_satisfies(t_ti, iface_ni)` = 原生/横切/用户三类同入口，三态 1/0/-1 + 每查询预算隔离（`type_engine.cr`） |
| 轴分派 | A 横切形状名（`iface_shape_*` 表，本批空表），再到 C 用户接口（形状项路由到结构谓词），最后到 B 本质轴（= P3a `gen_constr_satisfied` 引擎面逐字同口径） |
| 首个消费者 | `gen_constr_satisfied` 首分支（函数调用点）：1 提前返回，0/-1 回落既有 `check_iface` 路径（措辞/去重/rc 逐字未动） |
| 新消费者 | `gen_inst_constr_satisfied`（结构/枚举实例化点）：直取真值 因此 `T: I` 在实例化点真判定（P3a 登记面关闭） |
| `T: I` 是否判 | 判（负方向 = 可证违反 因此 `error[TG02]` + 「does not satisfy interface 'I'」，与函数调用点同措辞）；正方向受映射层签名编码限制（未覆盖面，见 第 3.3 节） |
| 收紧台账 | 6 例（实例化点接口约束违反从 rc=0 零诊断变为 check rc=1 + TG02）；全语料 72 档零命中 |
| 零行为变化证据 | 同源对拍（旧二进制 × 新源 vs 新二进制 × 新源）check 日志逐字节同 + 影子日志/转储逐字节同 + ELF canary 逐字节同 + `.ccr` 逐字节同 |
| 判据 | `selftest-types` 304/304（288 增加 16 例）· 新套件 17/17 · 四套件通过 · 五 CI job（见 第 2 节）· 突变控制 4 条逐条生效 + 复位后二进制逐字节复原 |

---

## 1. 交付面（逐件）

### 1.1 `iface_satisfies`（`src/compiler/type_engine.cr`）

```
iface_satisfies(t_ti, iface_ni):
  guard（负键 因此 -1）
  轴 A：iface_shape_lookup(iface_ni) ≥ 0 因此 iface_satisfies_term(t_ti, 形状项)
  轴 C：find_iface(iface_ni) ≥ 0 因此 ① sh_iface_shape_term ≥ 0 因此 iface_satisfies_term(...)
                                ② 否则 iface_user_satisfies(t_ti, iface_ni)
  轴 B：gen_constr_type_ti(iface_ni) ≥ 0 因此 iface_satisfies_ti(t_ti, 约束行)
  否则 -1（不判）
```

- 轴优先序 = A > C > B（同名撞车时的取先规则；「原生名 vs 接口名」保持 P3a 现状 = 接口优先，`gen_constr_satisfied` 改动前即 `find_iface` 先行）。两向都由 selftest 固定（`isat.axis_order_shape_first` / `isat.axis_order_iface_over_essence`），后者并由突变 M2 验证。
- 预算隔离（照 `type_equal_engine`/`gen_constr_satisfied` 先例）：进入引擎前 `ty_budget_reset(IFACE_SAT_BUDGET)`、返回前再复位，memo 跨查询命中会让结果依赖预算历史（P0 终审 Critical 3）。常量 `IFACE_SAT_BUDGET = 200000`（与 `gen_constr_satisfied` 同值）。
- 轴 C 谓词 `iface_user_satisfies` = 与 `check_iface` 同源：对接口的每个方法 m ， T 的方法表含 m（`g_methods` 三元组查名）+ `fi_param_count` 相符 + `fi_return_type` 相符。三态：全过 因此 1（含零方法接口的空洞满足）；方法缺失 / 计数不符 / 返回码不同 因此 0；T 非命名行（原生/`dyn`/泛型形参/复合构造子，无方法表身份）或「表登记了方法名而函数行缺失」因此 -1（不发明违反）。
- 零 `str_intern`：查名走 `g_methods`（parser impl 分支唯一写点的三元组），不构造 `"T.m"` 串，方法缺失（= 判定 0 的路径）不得往 `g_strs` 追加新串（`.ccr` STR 段硬判据；`type_has_method` 的 `str_intern` 形态对缺失名会增长驻留表）。守门 = selftest `isat.no_str_intern_on_missing`（delta 口径），并由突变 M3 验证。

### 1.2 接线点（B.1 三处 + 一处说明书更新）

| B.1 接线点 | 本批处置 |
|---|---|
| `gen_constr_satisfied` 首分支（`find_iface ≥ 0 因此 -1`） | 改走 `iface_satisfies`：`if s == 1 { return 1; }` 因此 `return -1`（0/-1 回落既有 `check_iface` 名拼接路径）。函数调用点行为逐字未动（措辞/去重/rc），「0 改为新措辞」的切换仍归 Task 6 Step 3（计划 Step 3 原文即此） |
| `sh_iface_shape_term`（占位恒 -1） | 仍恒 -1（阻塞精确定位 = Task 6 Step 1 签名类型项化），但已升为轴 C 的第一路由（返回 ≥0 即走形状包含判定 因此 切换点就位；注释已重写） |
| `ty_variance_of`（Task 1 已就位） | 未动（本批不触引擎变型表） |
| 新增（Task 5 的 `T: I` 半边） | `gen_inst_constr_satisfied`（实例化点直取真值）+ `gen_constr_raise` 措辞分派（接口名约束 因此 与既有路径同措辞「does not satisfy interface 'X'」，不附反例，接口非类型行、反例项不可得 因此 不谎报） |

### 1.3 形状表（横切轴数据面；Task 2 的入口）

`src/compiler/iface_registry.cr`：`iface_shape_register / iface_shape_lookup / iface_shape_count / iface_shape_reset` + `g_iface_shape_{names,terms,count,cap}`（`globals.cr`；`reset_frontend_state` 复位 count、cap 保留，照 `g_sgen_constr` 生命周期先例）。
- 本批零条目（空表 因此 轴 A 恒未命中，三态纪律不破）；条目细化（`sequence`/只读/可写/可索引/可迭代/product）归 Task 2 Step 1。
- 表不 alloc `g_types` 行、不进 `.ccr` 序列化、不 `str_intern` 因此 类型段/行号/STR 段零扰动（实测见 第 5.3 节）。
- 附带交付 `iface_satisfies_term(t_ti, shape_term)` 原语（Task 2 的名字无关消费点可直接用：桥接 + 预算隔离 + 三态一次收口）。
-  给 Task 2 的形状项口径勘误：`AK_SEQUENCE` 元素槽在引擎侧是不变（Task 1 变型表），故「序列接口」形状项不能写成 `sequence<⊤>` 参数链（不变槽遇 ⊤ 会落 -1 未覆盖面）；须写成 `⊤ₖ`（`tt_top_k(AK_SEQUENCE)`），selftest `isat.axis_a_shape` 即该形（切片行 因此 1 / 原生行 因此 0）。

---

## 2. 判据复验（逐条 = 命令 + 结果）

| # | 判据 | 命令 | 结果 |
|---|---|---|---|
| 1 | 自举构建 | `nice -n 19 python3 build_selfhost_native.py` | rc=0；守卫全过；checker 警告集与基线逐条相同（344 = 344，零新增）；`corec` 函数数 875 增加到 889（+14 = 本批新函数） |
| 2 | 类型引擎自测 | `nice -n 19 ./build/corec selftest-types` | 304/304（基线 288 增加 16 例 `isat.*`；逐例见 第 4.1 节） |
| 3 | 四套件 | `test_iface_ops` / `test_generic_constr` / `test_match_exhaust` / `test_optional` | 76/76 · 15/15 · 16/16 · 12/12（`test_generic_constr` 14 增加到 15：P3a 的「不判」钉按台账改为违反 + 新增正控；见 第 4.2 节） |
| 3b | 邻接套件 | `test_impl` / `test_type_engine` | 7/7 · PASS（自测通道 304 例） |
| 3c | 新行为覆盖集 | `nice -n 19 python3 tests/selfhost/test_iface_satisfies.py` | 17/17（从真 parser 输入到真 CLI；含三路同证的正例与措辞断言的负例） |
| 4 | ELF canary | 先 `clean-cache`，再 `build tests/suite/ptr_arith.cr --static`，最后 `sha256sum` | `95084e7b…d475` IDENTICAL |
| 4b | `.ccr` 面（TODO #26） | 先 `clean-cache`，再 `ccr`，最后取尺寸和 sha256 | `ptr_arith` 88943B `54e3856b383301be…`、`generics_test` 130974B `97be2f9e7431fde5…` ，与基线二进制逐字节同（本批零 `.ccr` 变更：形状表不入序列化、无新 `str_intern`） |
| 5 | 全语料 report-only | 72 档（见 第 5.1 节/第 5.2 节） | 新诊断面零命中；同源对拍 check 日志逐字节同 |
| 6 | 影子对拍门 | 72 档 `--type-shadow --type-shadow-dump` + 聚合 | `decisions=30271 agree=30271`，全计数 0；站点覆盖同报（见 第 5.4 节） |
| 7 | 全回归 | 五 CI job + 更宽 selfhost 集 | 五 job：`selfhost-tests`/`bootstrap-tests`/`suite`/`full-bootstrap` rc=0 · `check` rc=1 = 既有 red 划界（2 条 TF01 误报）；`corec2 == corec3` IDENTICAL；冒烟 rc=42；更宽集见 第 2.2 节 |
| 8 | 突变控制 | 4 条 + 复位核 sha | 逐条生效、复位后 `build/corec` sha 逐字节复原（见 第 6 节） |

### 2.1 五 CI job + 更宽 selfhost 集

（自举作业串行执行；五 job 各跑一次）

| job | 命令 | rc | 备注 |
|---|---|---|---|
| selfhost-tests | `CI_JOB_NAME=selfhost-tests bash src/ci/run.sh` | 0 | 19 档（本批新增 `test_iface_satisfies.py` 挂入；含 `test_generic_constr` 15/15） |
| bootstrap-tests | 同上 `bootstrap-tests` | 0 | 3/3 |
| suite | 同上 `suite` | 0 | tests/suite 全档「ALL PASS」 |
| full-bootstrap | 同上 `full-bootstrap` | 0 | 三阶段：`corec2 == corec3` `cmp` IDENTICAL（sha `90e8f773b92a06c1…`）+ `--help` rc=1（既有约定）+ 冒烟 `run 'fn main()->int{return 42;}'` rc=42 |
| check | 同上 `check` | 1 | 自源 `check src/compiler`，既有 red 划界（2 条 TF01 误报 `lits_copy`/`ty_memo_slot_no_grow`，行号随源增长位移；同源对拍两侧一致，非本批引入） |
| 更宽 selfhost 集 | 全枚举 `tests/selfhost/*.py`（43 档） | 见 第 2.2 节 | #31 缺口（CI 只挂 19/43）的复现口径 |

### 2.2 更宽 selfhost 枚举（43 档 = 全枚举，含 CI 未挂的 24 档 ， #31 缺口口径）

`for f in tests/selfhost/*.py; do nice -n 19 python3 $f; done`（串行）因此 43/43 rc=0。要点档：
`test_compile` PASS · `test_purity` PASS · `test_ccr_v7` 27/27 · `test_backend_bootstrap` rc=0（P3a 收尾发现漏检的那档）· `test_lsp` ALL PASS(10) · `test_interp_parity` 23/23 · `test_named_dedup` PASS · `test_slice_bounds` 7/7 · `test_generic_constr` 15/15 · `test_iface_satisfies` 17/17 · `test_type_engine` PASS（304 例自测通道）。逐档明细 = `/tmp/p3b_t0_wider.txt`（43 行，全 `rc=0`）。

---

## 3. 契约语义与三态纪律

### 3.1 三态口径（本批主判据）

- 0 = 可证违反：方法名不在位（名字面忠实：parser 在 impl 块按 `Type.method` 登记，查名同域）/ 参数计数不符 / 返回码不同。「查不到」绝不等于 0：T 非命名行 因此 -1 不判（`isat.axis_c_non_named_unjudged`：原生行 / `dyn` 行 / 泛型形参行三例）。
- 1 = 判定满足：接口的每个方法都在位且计数/返回码相符（含零方法接口的空洞满足）；命名行、泛型应用行（查名走基名，`isat.generic_apply_base_name`）。
- -1 = 不判/未覆盖：轴不命中 / 桥接失败 / 域外输入（负键、越界行）/ 表内不一致。-1 没有被任何消费方当 0/1 用：实例化点 `== 0` 才发诊断；函数调用点回落既有路径（该路径自带同一谓词的判定）。
- 预算隔离：成功判定后 `g_ty_steps == 0` 且窗口上限 = 本层常量（`isat.three_state_budget_isolated`；该用例含一条非同一比较以真正计步，见 第 6 节的 M4 教训）。

### 3.2 与 `check_iface` 的同源性

谓词 = 同源（方法名在位 + 参数计数 + 返回码），并有逐例对拍用例 `isat.predicate_same_as_check_iface`（满足/计数不符/返回码不符三形态，两侧结论逐例相等）。因此 函数调用点「1 提前返回」是结论保持的（不存在判定分歧）；实例化点新判定与函数调用点同措辞（行为探针 `func_site_ret_mismatch_also_rejected` 与 `inst_ret_code_mismatch_rejected` 同判）。

### 3.3 覆盖边界（登记面，非漏放）

接口方法签名的参数/返回槽 = 映射层编码：parser 对接口与 impl 两侧同样取 `unpack_type(类型节点)`（`parser.cr:1671/1685` 与 `ast_type_val(EXPR_PARAM)`），非原生类型节点一律塌缩为码 0 = `TY_INT`；`self`/`&self` 接收者槽两侧均写字面 0（parser 约定）。后果：
- 逐参数类型不参与判定（与 `check_iface` 逐字一致；`check_impl_for` 的逐参比对是声明侧校验，非本谓词面）；
- 返回码比对语义 = 编码相等而非类型项等价 因此 「命名返回型 vs `int`」相互相等（行为探针 `inst_encoding_limit_named_ret_pinned` 把现状固定，防后续不报错地改成「不判」或「违反」）。
- 解锁 = Task 6 Step 1（签名类型项化）后由形状项包含判定承担，`iface_satisfies` 轴 C ① 的路由即为切换点。同族未覆盖面 = 计划 B.4-3（命名实参 vs 原生约束 = -1）。

---

## 4. 收紧台账与用例

### 4.1 selftest 新增（`isat.*` 16 例；288 增加到 304）

轴分派 4（`axis_a_shape` / `axis_b_essence` / `axis_c_satisfied` / 两向优先序）· 三态 3（`axis_c_missing_method` = 0 / `axis_c_param_count` = 0 / `axis_c_ret_code` = 0）· 域限定 1（`axis_c_non_named_unjudged`）· 谓词对拍 1（`predicate_same_as_check_iface`）· 零驻留 1（`no_str_intern_on_missing`）· 空洞满足 1（`empty_iface_vacuous`）· 泛型应用基名 1（`generic_apply_base_name`）· 预算/三态 1（`three_state_budget_isolated`）· 形状表 3（`shape_registry_semantics` / `shape_registry_reset` + 轴 A 主例）。

两处既有用例的处置（注释/标签级，断言语义保持或按台账更新）：
- `t5.constr_iface_is_unknown_p3b` 改为标签 `t5.constr_iface_non_named_unjudged`（断言不变：非命名实参 因此 -1；旧标签的「未交付」理由已失效）；
- `unf.iface_stub_three_state`（注释更新为「域外输入守卫」；断言不变）。

### 4.2 收紧台账（旧到新和处置；全语料 72 档零命中）

| 用例（`test_iface_satisfies.py`） | 旧（`aa54d26a` 二进制实测） | 新 | 说明 |
|---|---|---|---|
| `inst_missing_method_rejected` | check rc=0 零诊断 | check rc=1 + `error[TG02]` + 「does not satisfy interface 'Show'」 | 方法缺失（结构侧新判定） |
| `inst_count_mismatch_rejected` | rc=0 零诊断 | rc=1 + TG02 | 参数计数不符 |
| `inst_ret_code_mismatch_rejected` | rc=0 零诊断 | rc=1 + TG02 | 返回码不符（函数调用点本就拒，同措辞，站点一致性由此证） |
| `inst_enum_missing_method_rejected` | rc=0 零诊断 | rc=1 + TG02 | 枚举实例化点 |
| `inst_multi_method_partial_rejected` | rc=0 零诊断 | rc=1 + TG02 | 多方法接口实现一半 |
| `inst_second_iface_missing_rejected` | rc=0 零诊断 | rc=1 + TG02 | 两接口隔离 |
| `test_generic_constr.py::struct_iface_constr_unjudged` | rc=0 零诊断（P3a 钉） | 按台账改为 `struct_iface_constr_violated` = rc=1 + TG02 | 同一条边界的旧钉 |
| 零变化用例（其余 11 + `..._present_accepted`） | rc=0 / 三路同证 | 同 | 正方向与「不判」面 |

诊断门口径：TG02 = 软诊断（check rc=1 / build rc=0 + 产物照出），与既有约束检查同门同码，本批未新增硬门（计划 Global Constraints「新硬错误先 report-only」未被触发；硬门化是另立决策）。

### 4.3 行为探针（真 parser 输入；T3 假通过教训）

新套件 17 例全部走真 `corec check/build/run`（正例 = check rc=0 ∧ ELF rc=N ∧ interp rc=N 三路同证；负例 = rc + 措辞 + 无产物断言）。逐例见 `tests/selfhost/test_iface_satisfies.py` 头注与 第 4.2 节。已挂 `src/ci/run.sh` selfhost-tests。

---

## 5. 零行为变化证据（四面）

### 5.1 同源对拍（最强形）

`旧二进制（`aa54d26a` 构建）× 新源` vs `新二进制 × 新源`，72 档逐档 `clean-cache`：
- check：`diff -r` 日志目录 rc=0（逐字节相同），rc + 诊断码 + 逐条消息含行号全等；
- shadow：日志目录 `diff -r` rc=0，转储目录 `diff -r` rc=0；
- 归一化诊断对照（与「各自基线」比）：610 种诊断形态，零新增 / 零消失 / 零计数变化（仅 `lits_copy`/`ty_memo_slot_no_grow` 两条既有 TF01 误报的行号随源增长位移，两侧一致）。

### 5.2 语料/自源零命中

收紧面（第 4.2 节）在全语料（tests/suite 21 + src/compiler 2 + 后端/内核 30 + stdlib 12 + examples 7 = 72 档）零命中；自源 `check src/compiler` 仅既有 2 条 TF01 误报（见 第 5.1 节）。

### 5.3 `/.ccr` 与 ELF

- ELF canary `95084e7b…d475` IDENTICAL（clean-cache）；
- `.ccr`：`ptr_arith` / `generics_test` 与基线逐字节同（本批零 `.ccr` 变更；形状表不入序列化是关键设计点）。

### 5.4 影子对拍门（数字 + 站点覆盖）

| 口径 | decisions | agree | old_stricter | old_looser | unknown* | replace_* |
|---|---|---|---|---|---|---|
| 基线（`aa54d26a` 二进制 × P3a 源） | 30128 | 30128 | 0 | 0 | 全 0 | 全 0 |
| 本批（新二进制 × 本批源） | 30271 | 30271 | 0 | 0 | 全 0 | 全 0 |
| 旧二进制 × 本批源（归因对照） | 30271 | 30271 | 0 | 0 | 全 0 | 全 0 |

- +143 精确归因（同二进制两跑对比：旧源和新源）：`main.cr` +47 · `ccr_io.cr` +47 · `targets/x86_64-linux/_import.cr` +47 · targets `_import.cr`/`main.cr` 各 +1，即本批新增代码自身的站点（assign-node +101、fn-body-ret +42），非语义变化。
- 站点覆盖（本批）：`assign-node=22886` · `fn-body-ret=5380` · `if-branch=1971` · `struct-field-type=28` · `array-elem-type=4` · `generic-apply-base=2`；`assign-binary` / `generic-arg` / `hotpatch-ret` / `unify-fallback` 仍零命中（与 P3a 同）；`sum(sites) == decisions` 通过，`agree == decisions` 通过，全计数 0 通过。
- 声明（继承 P3a）：影子通道只覆盖 `type_equal` 站点；本批判定面（`ty_sub` 满足判定）不在其站点集内 因此 影子零差异是必要条件而非充分证据；满足判定面的证据 = 第 4.1 节 用例 + 第 4.3 节行为探针 + 第 5.1 节 同源对拍。

---

## 6. 突变控制（逐条生效并复位，逐字节复原）

方法：注入，运行 `build_selfhost_native.py`，观察预测的用例变为失败，复位，重建，最后用 `sha256sum` 比对。

| # | 注入 | 结果（生效） |
|---|---|---|
| M1 | 轴 C 缺方法 因此 `return 0` 改 `-1`（三态的 0 侧失效） | selftest：`isat.axis_c_missing_method` 失败（got -1 want 0），恰 1 例；行为面：4 条负例探针失败（`inst_missing_method_rejected`/`inst_enum_*`/`inst_multi_method_partial_*`/`inst_second_iface_*` = 「不报错地通过面复活」），13/17 |
| M2 | 本质轴前置于用户轴（破坏 A > C > B） | `isat.axis_order_iface_over_essence` 失败，恰 1 例 |
| M3 | 改回 `str_intern("T.m")` + `find_func` 形态（绕过 `g_methods`、复活驻留表增长） | `isat.no_str_intern_on_missing` 失败，恰 1 例 |
| M4 | 丢弃查询出口预算复位 | `isat.three_state_budget_isolated` 失败，前提修复：首次注入未生效，根因 = 原用例只走「节点同一」快路径（`ty_sub` 的 `a == b` 早退，零计步）因此 断言没有实际作用（假通过）；已改为「快路径 + 非同一比较（真计步）」双路 因此 注入即失败。这是本轮突变控制唯一发现的弱用例 |
| 复位核验 | 还原 `type_engine.cr` 后重建 | `build/corec` = `53c8b9c9bb663128…` 与注入前逐字节相同；`build/corearch` = `e7bd453728a719fa…` 不变；`selftest-types` 304/304 |

M1 的批量内曾被 M3 无意中和（两处改同一行），已拆分为独立批次复验（上表 M1 结果即独立批次）；这一过程本身是「突变须逐条独立生效」的实证。

---

## 7. 登记面 / 未覆盖面 / 裁决点（交 Task 2/6 与 P5）

1. Task 2（横切接口）：`iface_shape_*` 注册面已就位、`iface_satisfies_term` 原语可用；Step 1 只剩条目细化，形状项须用 `⊤ₖ` 形（`AK_SEQUENCE` 元素槽不变，`sequence<⊤>` 参数链会落 -1；第 1.3 节）。Step 3 消费点换位未动（本批未接线）。
2. Task 6（impl 契约）：Step 1 签名类型项化仍是其第一步（`g_ifaces` 方法条目仍裸 `TY_*`；`self` 槽两侧写字面 0；≥16 方法 / ≥8 参数上限未处置）；`sh_iface_shape_term` 仍 -1 但已是轴 C 第一路由；`check_iface`/`check_impl_for`/`type_has_method`/mangling 未动；函数调用点「0 改为新措辞」切换归其 Step 3。
3. 语义裁决项（交 Task 6）：① 用户轴是否改名义口径（`impl I for T` 声明即满足，spec 第 2.3 节的模型；本批未做：会推翻 `iface_constr_legacy_pass` 的结构判定实例，属 Task 6 的 impl 语义重定义面）；② 结构谓词的 1 是否升级为形状项包含（其精度受 第 3.3 节 限制）。
4. 登记（本批显式不判，不得当「不满足」）：非命名实参（原生/`dyn`/泛型形参/复合行）· 接口签名编码不可判面（第 3.3 节）· 未注册的形状名 · 表内不一致（方法名在 `g_methods` 而函数行缺失）。
5. P5 继承：形状表为进程级全局态（`reset_frontend_state` 复位；LSP 长驻下同一进程多编译已覆盖）· 若后续允许 `.ccr` STR 段增长（A.3-② 裁决），本层「零 `str_intern`」可放宽。
6. B.4-1 未触发：本批未动 `infer_gen_call` 的约束循环（`save_func_gen_constrs` 稀疏零初值风险仍在库）。

---

## 8. 计划覆盖自检

| 来源 | 要求 | 状态 |
|---|---|---|
| 交接契约 ① | `iface_satisfies(t_ti, iface_ni)` 三态 1/0/-1、不得不报错地当 0、预算隔离 |  第 1.1 节 / 第 3.1 节 |
| 附录 B.1 接线点 1 | `gen_constr_satisfied` 首分支「改这一处即全覆盖」 |  已接线（1 提前返回；0/-1 回落 = 计划对函数调用点的「逐字未动」口径） |
| 附录 B.1 接线点 2 | `sh_iface_shape_term` 占位改为切换点 |  已设为轴 C 第一路由（建项归 Task 6 Step 1） |
| 附录 B.1 接线点 3 | `ty_variance_of` | — 未动（本批未触变型表） |
| Task 5 的 `T: I` 半边 | 满足判定接引擎；`-1` 不得当 0 |  实例化点真判定 + 函数调用点结论保持；三态用例固定 |
| 结构约束不回归 | `T: int` / `Box[T:int]` |  `test_generic_constr` 本质轴 5 例全部通过（含反例文本） |
| 计划 Global Constraints | 新硬错误先 report-only；`.ccr` STR 约束；三态纪律 |  无新硬门（TG02 软）+ 全语料零命中；零 `str_intern`；第 3.1 节 |
| 待办（本批后更新） | 附录 B.1 标阻塞解除；TODO 登记；`run.sh` 例数同步 |  第 9 节 文档面 |

---

## 9. 改动清单与文档面

| 文件 | 变更 |
|---|---|
| `src/compiler/type_engine.cr` | 契约本体（`iface_satisfies` + 轴 C 谓词 `iface_user_satisfies` + `iface_find_method` + 两个引擎面原语 + `IFACE_SAT_BUDGET`） |
| `src/compiler/iface_registry.cr` | 形状表（grow/register/lookup/count/reset） |
| `src/compiler/globals.cr` | 形状表全局 + `reset_frontend_state` 复位 |
| `src/compiler/checker.cr` | `gen_constr_satisfied` 首分支接线 + `gen_inst_constr_satisfied` + `gen_constr_raise` 措辞分派 + 注释口径更新 |
| `src/compiler/ty_shadow.cr` | `sh_iface_shape_term` 注释（阻塞精确定位 + 路由说明；行为不变） |
| `src/compiler/type_selftest.cr` | `isat.*` 16 例 + 夹具 + 两处既有用例标签/注释 |
| `tests/selfhost/test_iface_satisfies.py` | 新建（17 例；含台账与覆盖边界注） |
| `tests/selfhost/test_generic_constr.py` | C 段：从旧「不判」固定改为违反 + 正控（台账注）；头注口径更新 |
| `src/ci/run.sh` | 挂新套件 + selftest 例数 288 增加到 304 |
| `docs/superpowers/plans/2026-09-11-r2-p3-capabilities.md` | 附录 B.1 首注（阻塞解除 + 逐条对照 + 台账/判据）；状态表 Task 2/6 行「阻塞已解除」；交接面 ① 的历史注加指向 |
| `TODO.md` | 新增 #36（本批实施 + 台账 + 未覆盖面 + P3b 剩余） |

`jj diff --stat`：11 文件，+797 / −45。

## 10. 证据命令速查（可复核）

```bash
# 构建 / 自测 / 五套件
nice -n 19 python3 build_selfhost_native.py            # rc=0
nice -n 19 ./build/corec selftest-types | tail -1      # 304/304
nice -n 19 python3 tests/selfhost/test_iface_satisfies.py | tail -1     # 17/17
nice -n 19 python3 tests/selfhost/test_generic_constr.py | tail -1      # 15/15
# ELF canary + .ccr（先 clean-cache、cwd = 仓库根）
nice -n 19 ./build/corec clean-cache && nice -n 19 ./build/corec build tests/suite/ptr_arith.cr -o /tmp/x --static && sha256sum /tmp/x
# 同源对拍（旧二进制 × 新源 vs 新二进制 × 新源）
nice -n 19 bash /tmp/p3t0_run.sh check /tmp/p3b_t0_base_bin/corec /tmp/o && nice -n 19 bash /tmp/p3t0_run.sh check ./build/corec /tmp/n && diff -r /tmp/o/logs /tmp/n/logs
nice -n 19 bash /tmp/p3t0_run.sh shadow ./build/corec /tmp/s && nice -n 19 python3 /tmp/p3t0_agg.py /tmp/s
# 五 CI job
for j in selfhost-tests bootstrap-tests suite full-bootstrap check; do nice -n 19 env CI_JOB_NAME=$j bash src/ci/run.sh; echo "$j rc=$?"; done
```

---

## 11. 提交与文档

- 提交（路径限定）：`9aa1786c` `feat: R2 P3b Task 0，iface_satisfies 契约回补（P2b 交接面 ① 交付；P3b 唯一阻塞解除）`（base = `aa54d26a`；11 文件 +799/−45 = 6 源码 + 2 测试 + `run.sh` + 计划 + TODO；工作副本提交后干净）。
- 本报告（`docs/archive/sdd/p3b-task0-report.md`）= 未跟踪面（与 P3a 各报告同口径，不入提交）。
- 计划附录 B.1 = 阻塞解除注（逐条对照 + 「仍未做」清单 + 台账/判据指针）；状态表 Task 2/6 行 = 「阻塞已解除」；交接面 ① 历史注加指向。TODO #36 = 本批实施条目（含未覆盖面与 P3b 剩余面）。
- 报告可直接复核的中间产物（本机）：`/tmp/p3b_t0_base_bin`（基线二进制）· `/tmp/p3b_t0_oldbehavior.txt`（旧行为台账）· `/tmp/p3b_t0_wider.txt`（43 档枚举）· `/tmp/p3b_t0_ci_*.log`（五 job）· `/tmp/p3b_t0_*_check|shadow`（语料/影子四面）· `/tmp/p3t0_run.sh` + `/tmp/p3t0_agg.py`（P3a 既有运行器，未改动）。
