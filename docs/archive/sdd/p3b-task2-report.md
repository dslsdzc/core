# R2 P3b Task 2 报告：横切接口接线（序列、可索引、可迭代、product 形状判定接管 TYP_* 直比）

日期：2026-09-12。基线：`9aa1786c`（P3b Task 0，工作副本起点，selftest-types 304/304）。
任务：P3 计划 Task 2（Step 1 形状条目细化，Step 2 用例，Step 3 消费点换位，Step 4 判据，Step 5 提交）。
报告口径：所有数字都是本机实跑（`nice -n 19`，cwd 为仓库根，clean-cache 先于任何 `.ccr` 或缓存态比较，一次构建一次编译串行执行）。未跑的一律标“未跑”。
旧二进制口径：`/tmp/p3b_t0_base_bin/corec`，等于 P3b Task 0 的基线构建 `aa54d26a`。Task 0 已实测该二进制与其自源 check/shadow 日志逐字节相同，因此本批“老对新”两个二进制对比就是“改动前对改动后”的同源对拍。链条是：`aa54d26a` 二进制等价于其行为，等价于 `9aa1786c` 源码，再到本批改动。

---

## 0. 交付摘要

| 项 | 结果 |
|---|---|
| Step 1 形状条目 | 六条形状项（`iface_registry.cr` 横切形状段，唯一构造点）：序列、只读序列、可写序列、可索引、可迭代、product |
| Step 3 消费点 | 索引后备门改为可索引形状；range 分支改为序列形状且固定性位（序列项 b 槽）；结果三分支原地保留 |
| 行为变化 | 收紧 0，放宽 0。没有新诊断、没有新硬门；12 例探针在老新两个二进制上逐例相同，全语料 72 档 check 面 diff 零差异 |
| `.ccr` 和 ELF | 都逐字节相同（`ptr_arith` 88943B `54e3856b…`，`generics_test` 130974B `97be2f9e…`，ELF canary `95084e7b…d475`） |
| 判据 | `selftest-types` 319/319（304 增加 15 例 `x2.*`）；新套件 12/12（挂在 `run.sh`）；六套件通过；五个 CI job；更宽 selfhost 枚举 44/44；自举链 `corec2==corec3` 加 N06=0 加冒烟 42 |
| 影子对拍门 | `decisions=30400 agree=30400`，全部计数为 0；旧二进制配新源得到同值，因此零语义变化；站点覆盖同报 |
| 突变控制 | M1/M2/M3 逐条咬合（selftest 和行为探针两级）；复位后二进制逐字节复原 |
| 两处按实测重定 | ① 只读和可写分野落在视图面（只读等于序列本体并上 `&[⊤ₖ(SEQ)]`，按协变槽判定）；② 形状名字面在生产路径不注册（驻留 ni 约束，命名消费语法待裁决，消费者走无名字入口） |

---

## 1. 交付面（逐件）

### 1.1 形状条目（Step 1，`src/compiler/iface_registry.cr` 横切形状段）

| 形状 | 形状项 | 语义和实测判据 |
|---|---|---|
| `sh_shape_seq`（序列接口） | `⊤ₖ(AK_SEQUENCE)` | 数组和切片都满足；`&[T]`/`&mut[T]`/原生/命名行都不满足 |
| `sh_shape_seq_ro`（只读序列） | `⊤ₖ(SEQ) ∪ ref(mut=0, ⊤ₖ(SEQ))` | 本体加只读视图。只读视图由 AK_REF 协变槽判定（元素不是 ⊤ 也成立），兑现 Task 1 变型表的“只读等于协变”；`&mut[T]` 不满足（mut 等式语义） |
| `sh_shape_seq_rw`（可写序列） | `⊤ₖ(SEQ)` | 本体（本语言切片可写，T1 探针 pSliceW 实证）；拒绝只读视图 |
| `sh_shape_indexable`（可索引） | `⊤ₖ(SEQ) ∪ ⊤ₖ(STRING)` | 与 `IP_INDEX` 许可集逐行同集（全类型行枚举等于消费点等价判据） |
| `sh_shape_iterable`（可迭代） | `⊤ₖ(SEQ)` | 首版；字符串不宣称（迭代面零类型检查代码证据） |
| `sh_shape_product`（product） | `⊤ₖ(AK_PRODUCT)` | 元组行满足；struct 行等于 AK_NAMED（展开层或用户轴面），不在首版 |

两条硬约束（逐条实测）：① `⊤ₖ` 形。`sequence<⊤>` 参数链在 AK_SEQUENCE 的不变槽落 -1（Task 0 第 1.3 节勘误；`x2.fixedness_not_in_shape_judgment` 反向钉住“固定性不进入形状判定”：数组项和切片项互判为 1，差异只在 b 槽）。② 零 `str_intern`。形状项只进入类型项 DAG（append-only，跨编译稳定），不驻留新串（`x2.no_str_intern` 的 delta 口径，由 `.ccr` STR 段守）。

### 1.2 消费点换位（Step 3，`src/compiler/checker.cr`）

| 站点 | 改动前 | 改动后 |
|---|---|---|
| 索引后备门（落空集） | `iface_permits(iface_kind_of(arr_ti), IP_INDEX) == 0` 时报 TK01 | `idx_ok := iface_satisfies_term(arr_ti, sh_shape_indexable())`；-1 回落既有许可表；`!= 1` 时报 TK01（码、文案、位置逐字不变） |
| range 分支类别判定 | `arr_kind == TYP_ARRAY` 时按 [F11] 得到 `alloc_type(TYP_SLICE, elem, 0)`，否则得到 `TI_UNIT` | `iface_satisfies_term(arr_ti, sh_shape_seq())`（-1 回落旧 kind 直比）且固定性位 ≥ 0（`sh_seq_fixed_len_of_ti` 读序列项 b 槽），然后同上 |

- 结果三分支原地保留（arr 到元素加 F2，slice 到元素，str 到 int）。它们同时决定结果类型，A.2 #16-18 明确规定不在换位面内。
- 三态纪律：形状返回 -1（不可译行等）不折算成 0/1，而是回落既有判定（索引门回落许可表，range 回落 kind 直比）。回落等于逐行同结论，改动前同类行本来就走该判定。
- `sh_seq_fixed_len_of_ti`（`ty_shadow.cr`）读取序列项 b 槽的表示层（数组为 N，视图为 -1），与 T1 登记的“固定性位消费者”清单一致。它不作为身份或子类型维度。

### 1.3 与计划原文的两处偏差（实测重定，逐条）

1. 只读和可写两个形状的实施形态。计划 Step 2 的读法是“只读形状接受数组与切片，可写形状拒绝只读视图”。在本实现中，只读形状包含 {数组，切片} 并上 {只读视图}（`x2.ro_accepts_body_and_ro_view`），可写形状为 {数组，切片} 且拒绝只读视图（`x2.rw_accepts_body_rejects_ro_view`）。可写视图（`&mut [T]`）的形状不可表达（AK_REF 可写侧槽 1 是不变加 ⊤，因此为 -1），不谎报 0/1，用例 `x2.rw_view_unexpressible` 钉死三态。
2. 名字面不注册。形状注册需要驻留 ni，而初始化路径的 `str_intern` 会把新串追加进 `g_strs`，导致 `.ccr` STR 段变化（A.3-② 硬判据）。因此生产路径零注册。本批消费者都是无名字消费点（`iface_satisfies_term`，Task 0 第 1.3 节已准备这条路）。命名消费语法（`T: 可索引` 一类）是独立裁决面，转到后续。注册面本身由 `x2.axis_a_registered` / `x2.shape_no_leak_after_reset` 用测试名覆盖（六条规范项按名可判，复位无泄漏）。

---

## 2. 判据复验（逐条为命令和结果）

| # | 判据 | 命令 | 结果 |
|---|---|---|---|
| 1 | 自举构建 | `nice -n 19 python3 build_selfhost_native.py` | rc=0（`BUILD SUCCESS`）；checker 警告集与基线逐条相同（208 等于 208，零新增；按 `Checker warnings (non-fatal)` 块逐串对拍） |
| 2 | 类型引擎自测 | `nice -n 19 ./build/corec selftest-types` | 319/319（基线 304，增加 15 例 `x2.*`，逐例见第 4.1 节） |
| 3 | 五套件 | `test_iface_ops` / `test_iface_satisfies` / `test_generic_constr` / `test_match_exhaust` / `test_optional` | 76/76、17/17、15/15、16/16、12/12；邻接 `test_impl` 7/7，`test_type_engine` PASS |
| 3b | 新行为覆盖集 | `nice -n 19 python3 tests/selfhost/test_xcut_iface.py` | 12/12（真 parser 输入到真 CLI；已挂 `src/ci/run.sh` selfhost-tests） |
| 4 | ELF canary | `clean-cache`，然后 `build tests/suite/ptr_arith.cr --static`，再 `sha256sum` | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475` IDENTICAL（构建后和五个 CI job 重建后各复验一次） |
| 4b | `.ccr` 面（TODO #26） | `clean-cache`，然后 `ccr`，再记录尺寸和 sha256 | `ptr_arith` 88943B `54e3856b383301be5daecaf61f75ce120e56ef4d1569c3008009fc368b750df9`；`generics_test` 130974B `97be2f9e7431fde54de99e29394903a431aeafa591159c900e0175dfa064c8b1`。与 Task 0 基线逐字节相同，STR 段零增长，形状项不驻留也不进入序列化 |
| 5 | 全语料收紧和放宽台账 | 72 档（`/tmp/p3t0_run.sh check`：tests/suite 32 加自源 2 加后端/kernel 15 加 stdlib 19 加 examples 4），老新两个二进制 | check 面 `diff -r` 零差异（0 行）；rc 分布两侧相同，33 档 rc=0、39 档 rc=1；新诊断面零命中，台账见第 5 节 |
| 6 | 影子对拍门 | 72 档 `--type-shadow --type-shadow-dump` 加聚合（`/tmp/p3t0_agg.py`） | 新配新 30400/30400，全部计数为 0；旧配新得到同值（零语义变化）；站点覆盖同报（第 5.4 节） |
| 7 | 全回归 | 五个 CI job 加更宽 selfhost 枚举（44 档） | 见第 2.1/2.2 节 |
| 8 | 突变控制 | 3 条注入加复位核 sha | 逐条咬合，复位后 `build/corec` 逐字节复原（第 6 节） |
| 9 | 编译耗时（B.4-19 性能面） | `check src/compiler/main.cr`（2 次取稳）和 `_import.cr`，老新二进制 | main.cr 新 2.46/2.51s，旧 2.58/2.59s；_import.cr 新 2.53/2.56s，旧 2.58/2.59s。没有耗时回归，索引热路径接入形状判定后没有实测代价，快表改造不必要，登记照 A.3-⑩ |

### 2.1 五个 CI job（逐 job 记录 rc 和要点）

| job | rc | 要点 |
|---|---|---|
| `selfhost-tests` | 0 | 20 档（本批新挂 `test_xcut_iface.py`；尾部 12/12） |
| `bootstrap-tests` | 0 | 3/3 |
| `suite` | 0 | tests/suite 全档 ALL PASS |
| `full-bootstrap` | 0 | `cmp /tmp/corec2 /tmp/corec3` IDENTICAL（sha 均为 `3597aaf85d8bf230ac32fee212422e0a99e29bc15935bed1b0a2b1bc86f09a07`）加 `--help` rc=1（既有约定）；另跑 N06=0，冒烟 `run 'fn main()->int{return 42;}'` 得到 42，`/tmp/corec3 selftest-types` 319/319 |
| `check` | 1 | `check src/compiler`。这是既有 red 划界：恰好 2 条 TF01 误报（`lits_copy` 10121 / `ty_memo_slot_no_grow` 10344，与基线同一对；本批未增未减） |

### 2.2 更宽 selfhost 枚举（44 档，43 个既有加新套件；#31 缺口口径）

`for f in tests/selfhost/*.py; do nice -n 19 python3 $f; done` 得到 44/44 rc=0。要点档：`test_compile` PASS，`test_purity` PASS，`test_ccr_v7` rc=0，`test_backend_bootstrap` rc=0（附录 B.6 的必含档），`test_lsp` rc=0，`test_compile`/`test_tuple_slots`/`test_params_limit`/`test_agg_*`/`test_native_*` 全部 rc=0。逐档明细在 `/tmp/p3b2_wider.txt`（44 行，全部 rc=0）。

---

## 3. 语义和三态纪律

- 满足判定等于集合包含：形状判定不另建规则体系，`iface_satisfies_term` 等于桥接（`sh_term_of_ti`）加 `ty_sub` 加预算前后隔离（Task 0 原语，本批零改动）。
- 0/1/-1：1 表示形状满足；0 表示可证不满足（原生、命名、`dyn`、视图对本体形状等都可判定为 0）；-1 表示不可判（不可译行、不变槽遇 ⊤ 的可写视图形状、越界行或负键）。没有任何消费方把 -1 当 0/1 使用：两个消费点都显式回落既有判定，判定结果逐行同改动前。用例 `x2.uncovered_not_folded` 把原语级三态钉死。
- 为什么不变槽遇 ⊤ 落 -1 不算 bug：AK_SEQUENCE/AK_REF 可写侧的元素槽是不变槽（Task 1 变型表：可写时元素协变不健全），不变槽比较是结构相等（`tt_type_elem_same`），⊤ 不是任何项的结构等价物，因此引擎返回 -1 并设置 `g_ty_uncovered`。这是语义正确的未覆盖面，不是“不满足”，所以可写视图形状登记不落项。
- 保守面（有意）：range 分支只让固定长序列产生视图。切片的 range 现状是 `TI_UNIT`（A.2 #15 未接线），保持不变。收紧旋钮（落空加诊断、定串 range 语义）仍登记，本批不做，因为它属于新硬门，必须走 report-only 专批。

---

## 4. 用例和台账

### 4.1 selftest 新增（`x2.*` 15 例，304 到 319）

形状满足 7 例：`seq_accepts_body`（数组加切片，含非同一比较断言）、`seq_rejects_non_body`（原生、只读视图、命名行都为 0）、`ro_accepts_body_and_ro_view`（本体加只读视图为 1；`&mut[T]` 为 0；非同一）、`rw_accepts_body_rejects_ro_view`、`indexable_str_and_seq`（字符串正控）、`iterable_and_product`、`rw_view_unexpressible`（-1 加 uncovered 位；直调引擎读位，因为 `iface_satisfies_term` 出口预算复位会清该位）。
逐行枚举等价 2 例（消费点换位的等价前提，Task 0 M4 教训的“两路”实施）：`indexable_matches_ops`（全类型行：形状满足等于 1 当且仅当 IP_INDEX 许可等于 1，行数和许可行数下界加 `undec == 0` 反真空）、`range_fixedness_matches_kind`（全类型行：形状满足且固定性 ≥ 0 当且仅当 kind == TYP_ARRAY，固定长行和视图行两类都必须出现）。
注册和复位 2 例：`axis_a_registered`（六条规范项按测试名注册，轴 A 按名判定可用；count 增量为 6）、`shape_no_leak_after_reset`（复位后同键为 -1）。
其余 4 例：`no_str_intern`（六条构造零驻留增量）、`uncovered_not_folded`（越界行、负键、-1 形状都得到 -1；成功判定后 `g_ty_steps == 0`，窗口上限为 `IFACE_SAT_BUDGET`）、`iface_shape_term_unexpanded`（用户接口形状项仍为 -1，落结构谓词；零方法接口加命名行为空洞满足 1，原生行为 -1）、`fixedness_not_in_shape_judgment`（数组项和切片项互判为 1，固定性不进入判定；`sh_seq_fixed_len_of_ti` 三分辨为 3、-1（视图）、-1（原生））。

### 4.2 收紧和放宽台账（收紧 0，放宽 0）

本任务为换位批：没有新诊断，没有新硬门，没有判定集合变化。证据有三项：① 12 例行为探针在老新两个二进制上逐例相同（第 2 节和第 5.2 节）；② 全语料 72 档 check 日志 `diff -r` 零差异（第 5.1 节）；③ 影子面旧配新同值（第 5.4 节）。因此计划 Global Constraints 第 6 条的“新硬错误先 report-only”没有被触发（未升任何新门）。台账条目为空，与“零语料命中”的期待形状一致。

---

## 5. 零行为变化证据

### 5.1 同源对拍（最强形式）

旧二进制（`aa54d26a` 构建）配新源，对比新二进制配新源，72 档逐档 `clean-cache`：
- check：`diff -r /tmp/p3b2_old_newsrc_check/logs /tmp/p3b2_new_check/logs` 得到 rc=0（0 行差异），rc、诊断码、逐条消息含行号全部相等；rc 分布两侧相同，33 档 0、39 档 1。
- shadow：两轮聚合同值（30400/30400，全部计数为 0），类型判定的影子面零变化。

### 5.2 行为探针（本任务主判据；`tests/selfhost/test_xcut_iface.py` 12 例乘两个二进制等于 24 次逐例同）

| 组 | 例 | 判据（两个二进制同） |
|---|---|---|
| 正例三路同证 | `arr_index_elem` / `slice_index_elem` / `str_index_byte` / `range_array_view_indexable` / `range_full_array_view` | check rc=0 且 ELF rc 为 20/30/65/2/8，且 interp 同值 |
| 负例（软诊断面） | `int_` / `bool_` / `ptr_` / `struct_index_rejected` / `slice_range_unit_pinned` | check rc=1 加 `error[TK01]` 加 `Cannot index non-array type`，且 build rc=0、产物照出（软诊断门形态钉住） |
| 硬错误面钉子 | `arr_oob_literal_pinned` / `slice_bounds_pinned` | check rc=1 加 F2/F11 专有文案，且 build rc≠0、没有产物 |

### 5.3 `.ccr` 和 ELF

- ELF canary `95084e7b…d475` IDENTICAL（clean-cache；构建后和 CI 重建后两次）。
- `.ccr`：`ptr_arith`/`generics_test` 与 Task 0 记录值逐字节相同（88943B/130974B），形状项零 STR 段扰动。关键设计点是构造点零 `str_intern`。

### 5.4 影子对拍门（数字和站点覆盖同报）

| 口径 | decisions | agree | old_stricter | old_looser | unknown* | replace_* |
|---|---|---|---|---|---|---|
| 本批（新二进制配本批源） | 30400 | 30400 | 0 | 0 | 全 0 | 全 0 |
| 旧二进制配本批源（归因对照） | 30400 | 30400 | 0 | 0 | 全 0 | 全 0 |
| 参考（P3b Task 0 收官） | 30271 | 30271 | 0 | 0 | 全 0 | 全 0 |

- 增加 129 的精确归因（新旧两轮同源，纯源面）：`assign-node` 22886 到 22982（加 96），`fn-body-ret` 5380 到 5407（加 27），`if-branch` 1971 到 1977（加 6）。这些是本批新增代码自身的站点（新增函数和分支），不是语义变化，旧二进制跑同一新源得到完全相同的数。
- 站点覆盖（本批）：`assign-node=22982`、`fn-body-ret=5407`、`if-branch=1977`、`struct-field-type=28`、`array-elem-type=4`、`generic-apply-base=2`；`assign-binary`/`generic-arg`/`hotpatch-ret`/`unify-fallback` 仍零命中（与 P3a/T0 相同）；`sum(sites) == decisions` 成立，`agree == decisions` 成立，全部计数为 0。
- 声明（继承）：影子通道只覆盖 `type_equal` 站点，本批判定面（`ty_sub` 满足判定加 `iface_satisfies_term`）不在其站点集内，因此影子零差异是必要条件而不是充分证据。满足判定面的证据是第 4.1 节用例、第 5.2 节行为探针和第 5.1 节同源对拍。

---

## 6. 突变控制（咬合加复位逐字节复原）

方法：注入，运行 `build_selfhost_native.py`，观察预测的用例失败，复位，重建，比对 sha。

| # | 注入 | 结果（咬合，逐条实测） |
|---|---|---|
| M1 | `sh_shape_seq()` 改为 `tt_top_k(AK_PTR)`（序列形状错类） | selftest 7 例失败：`x2.seq_accepts_body`、`x2.range_fixedness_matches_kind`、`x2.axis_a_registered`、`x2.uncovered_not_folded`，加既有 `idx.infer_range_slice`/`idx.infer_range_oob_diag`/`idx.infer_range_oob_code`；行为面 4 例失败：`slice_index_elem`、`range_array_view_indexable`、`range_full_array_view`、`slice_bounds_pinned`（数组 range 退化为 unit，不报错地面复活）。结果为 312/319 加 8/12 |
| M2 | range 分支丢弃固定性维度（`if seq_ok == 1`，没有 `sh_seq_fixed_len_of_ti ≥ 0`） | 行为面 1 例失败：`slice_range_unit_pinned`（切片 range 改产视图，不报错地放宽）；selftest 全部通过。消费点在 checker，由行为探针咬合。如实登记：该面只有行为级自测，没有 selftest 级自测。结果为 319/319 加 11/12 |
| M3 | `sh_shape_indexable()` 追加 `⊤ₖ(AK_NAMED)`（拒绝集被放宽） | selftest 1 例失败：`x2.indexable_matches_ops`（逐行枚举等价立即失效），行为面 1 例失败：`struct_index_rejected`（struct 行索引不报错地放行）。结果为 318/319 加 11/12 |
| 复位核验 | 还原两个文件，重建 | `build/corec` 为 `6919bb547594685eac02bed3bd651a5992ad323f5ae754a3546b2f89fff8f3e3`，与注入前逐字节相同（五个 CI job 重建后仍同）；`build/corearch` 为 `e7bd453728a719fa70c04a4a005f0267dd5d5e8ee0ecfbb907e5d91af0229654`，不变；319/319 加 12/12 |

未覆盖的突变面（如实登记）：索引后备门的接线本身在行为上不可观测（换位设计等于拒绝集不变，把 `iface_satisfies_term` 换回许可表会全绿）。该面的自测在：① 形状内容（M3 实证）；② 逐行枚举等价用例；③ 四条 TK01 负例探针。这属于“等价换位”的固有性质，不是用例空白。

---

## 7. 登记面、未覆盖面、裁决点（交 Task 6 和后续批）

1. 可写视图形状不可表达（`ref(mut=1, ⊤ₖ(SEQ))` 得到 -1）。解锁需要引擎层为“不变槽的 ⊤ 吸收”定规则，属于引擎裁决，不在本任务 Files 面。本批只登记并钉住三态。
2. 形状名字面在生产路径不注册。注册需要驻留 ni（`.ccr` STR 段约束），命名消费语法（`T: 可索引`）待裁决。届时须一并裁决“`.ccr` STR 段是否接受增长”（A.3-② 的后续）。
3. 可迭代面未接线。`EXPR_FOR` 现状零类型检查（`infer_expr(iter)` 只推类型，`ir_gen` 当数值界用），接线等于新判定加可能的新硬门，必须走 report-only 专批。
4. 用户接口形状项仍不可展开（`sh_iface_shape_term` 恒为 -1），属于 Task 6 Step 1（签名类型项化）。本批的 `iface_satisfies` 轴 C ① 路由未变。
5. 索引侧“须 int”位缺失（A.3-⑧）和 dyn/字段面（A.2 #23/#28）本批未动。同一 `get_type_kind` 直比家族的其他站点不在 Task 2 Step 3 的清单内。
6. `EXPR_LET` 无检查（TODO #32）、运行期可选表示未统一（B.7）与本站点无关，状态不变。
7. 性能面：编译耗时实测无回归（第 2 节第 9 条）。A.3-⑩ 的 `(ak 到 entry)` 快表没有必要，作废条件已由实测给出。

---

## 8. 计划覆盖自检

| 来源 | 要求 | 状态 |
|---|---|---|
| Task 2 Step 1 | 形状条目细化（序列、只读、可写、可索引、可迭代、product） | 完成，第 1.1 节（两处按实测重定并登记：只读和可写落视图面；名字面不注册） |
| Task 2 Step 2 | 用例至少 6 个（数组/切片正例、int 负例、只读接受本体、可写拒绝只读视图、可索引对字符串、接口形状项不可展开 -1） | 完成，15 例（`x2.*`，含两条全类型行枚举等价和三态、零驻留守门） |
| Task 2 Step 3 | 索引和切片消费点从 `get_type_kind` 直比改为形状满足加元素取出；行为保持 | 完成，第 1.2 节（结果分支原地保留，等于 A.2 #16-18；差异为 0） |
| Task 2 Step 4 | selftest 阈值（本批按 P3a/P3b-T0 基线重定为至少 304 加增量）；影子对拍；行为探针；ELF canary；全回归 | 完成，第 2 节（319/319、影子全计数 0、12 例探针、canary 相同、五个 job 加 44 档） |
| Task 2 Step 5 | 提交（路径限定） | 完成，`44100ba4`（8 个文件，工作副本干净） |
| Global Constraints | jj only、路径限定、nice、clean-cache、`.ccr` 与 ELF 判据、三态、收紧台账、硬门 report-only | 全部遵守；没有新硬门 |
| 附录 B.1（P3b 接线点 2） | 形状条目加消费点换位 | 本批交付（B.1 首注已追加 ②b） |

---

## 9. 改动清单和文档面

| 文件 | 变更 |
|---|---|
| `src/compiler/iface_registry.cr` | 横切形状段：六条形状项构造器（增加 51 行；零 `str_intern`，不进入序列化） |
| `src/compiler/ty_shadow.cr` | `sh_seq_fixed_len_of_ti`（读取序列项 b 槽的固定性；增加 16 行） |
| `src/compiler/checker.cr` | 索引后备门和 range 分支换位（31 行改动） |
| `src/compiler/type_selftest.cr` | `ts_x2_run` 15 例加运行器计数（增加 188 行） |
| `tests/selfhost/test_xcut_iface.py` | 新建（12 例行为覆盖集；`COREC_BIN` 可指向基线二进制做同源对拍） |
| `src/ci/run.sh` | 挂新套件，selftest 例数注释从 304 改为 319 |
| `docs/superpowers/plans/2026-09-11-r2-p3-capabilities.md` | Task 2 五个 Step 勾选，实施状态总表行，附录 B.1 交付注（②b） |
| `TODO.md` | 新增 #37（本批实施、台账、未覆盖面、关联） |

`jj diff --stat`：8 个文件，新增 542 行，删除 18 行。

## 10. 证据命令速查（可复核）

```bash
# 构建 / 自测 / 六套件 + 新套件
nice -n 19 python3 build_selfhost_native.py                              # rc=0
nice -n 19 ./build/corec selftest-types | tail -1                        # 319/319
nice -n 19 python3 tests/selfhost/test_xcut_iface.py | tail -1           # 12/12
nice -n 19 python3 tests/selfhost/test_iface_ops.py | tail -1            # 76/76
# 行为保持（同源对拍：旧二进制 = Task 0 基线）
COREC_BIN=/tmp/p3b_t0_base_bin/corec nice -n 19 python3 tests/selfhost/test_xcut_iface.py | tail -1   # 12/12（与新版逐例同）
# ELF canary + .ccr（先 clean-cache、cwd = 仓库根）
nice -n 19 ./build/corec clean-cache && nice -n 19 ./build/corec build tests/suite/ptr_arith.cr -o /tmp/x --static && sha256sum /tmp/x
nice -n 19 ./build/corec clean-cache && nice -n 19 ./build/corec ccr tests/suite/generics_test.cr -o /tmp/g.ccr && sha256sum /tmp/g.ccr
# 语料 + 影子（复用 P3a/T0 运行器）
nice -n 19 bash /tmp/p3t0_run.sh check ./build/corec /tmp/p3b2_new_check
nice -n 19 bash /tmp/p3t0_run.sh check /tmp/p3b_t0_base_bin/corec /tmp/p3b2_old_newsrc_check
diff -r /tmp/p3b2_old_newsrc_check/logs /tmp/p3b2_new_check/logs         # rc=0（零差异）
nice -n 19 bash /tmp/p3t0_run.sh shadow ./build/corec /tmp/p3b2_new_shadow && nice -n 19 python3 /tmp/p3t0_agg.py /tmp/p3b2_new_shadow
# 五 CI job + 更宽枚举
for j in selfhost-tests bootstrap-tests suite full-bootstrap check; do nice -n 19 env CI_JOB_NAME=$j bash src/ci/run.sh; echo "$j rc=$?"; done
for f in tests/selfhost/*.py; do nice -n 19 python3 $f >/dev/null 2>&1 || echo "FAIL $f"; done   # 44/44
```

---

## 11. 提交

- 提交（路径限定）：`44100ba4`，提交信息为 `feat: R2 P3b Task 2，横切接口接线（序列/可索引/可迭代/product 形状满足判定取代 TYP_* 直比；只读协变/可写不变两形状）`。base 为 `9aa1786c`，8 个文件新增 542 行删除 18 行，等于 4 个源码加 1 个测试加 `run.sh` 加计划加 TODO；提交后工作副本干净。
- 本报告（`docs/archive/sdd/p3b-task2-report.md`）是未跟踪面，与 P3a/P3b 各报告口径相同，不入提交。
- 可复核的中间产物（本机）：`/tmp/p3b2_build{1,2,3}.log`（构建加警告集对拍）、`/tmp/p3b2_{checkdiff.txt,new_check,old_newsrc_check}`（语料同源对拍）、`/tmp/p3b2_{new_shadow,old_shadow}`（影子两轮）、`/tmp/p3b2_ci_*.log`（五个 job）、`/tmp/p3b2_wider.txt`（44 档枚举）、`/tmp/p3b2_mut{1,2,3}_build.log`（突变控制）、`/tmp/p3b2_pre_mut_{corec,corearch}`（复位基线二进制）。
