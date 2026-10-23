# R2 P2b Task 4 报告：操作许可接线（二元 11 条、一元 4 条、条件 3 条）

状态：完成
提交：`a99ee825`（change `xqyukvxv`），提交信息为 `refactor: R2 P2b Task 4，操作许可查表接线（checker.cr 三个门 ← iface_registry 的 ops 列；ANY/ALL/ONE 三种门形状与现状逐字等价；宽松面原样保留登记）`。路径限定 6 个：`src/compiler/checker.cr`(26)、`src/compiler/iface_registry.cr`(74)、`src/compiler/globals.cr`(18)、`src/compiler/type_selftest.cr`(204)、`src/ci/run.sh`(3)、`tests/selfhost/test_iface_ops.py`(新增 160)。共新增 465 行，删除 20 行。
计划：`docs/superpowers/plans/2026-09-11-r2-p2b-iface-ops.md` Task 4
一句话：18 个站点中有 4 个门接线（算术 ANY、逻辑 ALL、`if` ONE、`while` ONE），其余 14 个按计划口径留代码并登记，逐条台账见第 4 节，全部有实测依据。ops 列的 13 类与组位集逐格填完并注明现状行号。判据全部通过，并且旧二进制配新源、新二进制配新源的四条链 diffs 全空。

---

## 1. 交付物和落点（file:line，全部实测）

| 交付物 | 落点 | 说明 |
|---|---|---|
| 算术门（ANY） | `checker.cr:1964`（注释块 `:1959-1963`） | `lt != TI_INT && lt != TI_DEX && rt != TI_INT && rt != TI_DEX` 改为 `iface_permits(iface_kind_of(lt), op) == 0 && iface_permits(iface_kind_of(rt), op) == 0`，`&&` 形状与现状一字不差 |
| 逻辑门（ALL） | `checker.cr:1979`（注释块 `:1974-1978`） | 改为 `iface_permits(iface_kind_of(lt), OP_AND) == 0 \|\| iface_permits(iface_kind_of(rt), OP_AND) == 0` |
| 条件门 `if`（ONE） | `checker.cr:2288`（注释块 `:2283-2287`） | 改为 `iface_permits(iface_kind_of(cond_ti), IP_COND) == 0` |
| 条件门 `while`（ONE） | `checker.cr:2401`（注释块 `:2398-2400`） | 改为 `iface_permits(iface_kind_of(cond_ti), IP_COND_BOOL) == 0` |
| `IP_*` 位下标常量 | `globals.cr:254-271`（块注 `:254-268`，常量 `:269-271`） | 必须放在 globals.cr。Task 1 报告第 5.2 节的声明序实测表明变量和常量跨文件前向引用不成立，`checker.cr` 在 `iface_registry.cr` 之前。因此 checker.cr 可以直接写 `IP_COND`/`IP_COND_BOOL` |
| `ops` 列填空（13 类） | `iface_registry.cr:80-127`（组位集 `:87-103`，逐条目 `:106-127`；`iface_bit` `:58-62`） | 每组注明现状 checker.cr 行号。算术组只含 int/dex，逻辑和条件组恰好 {int, bool}，`IP_COND_BOOL` 恰好 {bool} |
| selftest 用例（28 例） | `type_selftest.cr:667-861`（段头 `:667`；探针助手 `ts_diag_code_at` `:23-28`） | 表侧全表对拍 15 例，端到端经真 `infer_expr` 13 例，含负控码断言 |
| 行为回归（39 例，新建） | `tests/selfhost/test_iface_ops.py` | 正控 17、负控 14、登记面 8；使用 `check` 通道（rc 加 `error[码]`） |
| CI 挂点 | `src/ci/run.sh:71-72` | `test_type_engine.py` 的例数注释从 155 改为 183；新增 `test_iface_ops.py`，遵循全局约束“新测试必须挂 selfhost-tests，不挂就不进判据” |

### 1.1 计划行号变化（按内容定址，没有猜测）

计划写的是 `checker.cr` `:1918-1966` / `:1968-2008` / `:2265` / `:2376` / `:2402-2403`。接线前实测（checker.cr 共 3385 行）：

| 站点 | 计划 | 接线前实测 | 变化 |
|---|---|---|---|
| 二元算术块（组派发到后备 return） | `:1935-1965` | `:1944-1974` | +9 |
| 一元块 | `:1970-2007` | `:1977-2016` | +7 到 +9 |
| `if` 条件门 | `:2265` | `:2274` | +9 |
| `while` 条件门 | `:2376` | `:2385` | +9 |
| range 端点 | `:2402-2403` | `:2411-2412` | +9 |

变化原因是计划侦查的底座是起草时点的工作副本，此后又有 Task 1/2/3 等批次增行。本报告一律使用接线前实测行号，并在注释里注明“接线前实测，接线后加 4”。

---

## 2. 判据（命令和结果，逐条）

| # | 判据 | 命令 | 结果 |
|---|---|---|---|
| 1 | 自举构建 | `nice -n 19 python3 build_selfhost_native.py` | rc=0；3 条 `[GUARD] … build log clean (error[ = 0, undefined = 0)`；`=== BUILD SUCCESS ===`（corec/corearch/corelsp） |
| 2 | 自测用例表 | `nice -n 19 ./build/corec selftest-types` | 183/183，零 FAIL，rc=0（基线 155，增加 28 例，例数同步 `run.sh:71`） |
| 3 | ELF 逐字节 | `clean-cache`，然后 `build tests/suite/ptr_arith.cr --static -o /tmp/pa_p2b4_final`，再 `sha256sum` | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475` IDENTICAL（等于计划定值；共复测 3 次，包含突变控制前后） |
| 4a | 语料面零变化（32 档） | 旧二进制配新源对比新二进制配新源：每档 `check` 的 stdout、stderr、rc 落盘 | `diff -r` 逐字节全空；rc 分布 20 档 0、12 档 1，与 Task 1-3 基线相同 |
| 4b | 编译器自源 | 同上，两个编译器配同一份 `src/compiler` | `diff` 为空。零新增诊断，零行号位移，因为两侧输入相同。诊断面恰好是 2 条既有 TF01 误报（`lits_copy` `:9361` / `ty_memo_slot_no_grow` `:9476`，Task 3 时点为 9328/9443，本批增行导致机械位移 +33），`ty_shadow.cr:118` 已登记 |
| 4c | `.ccr` 逐字节（冷缓存，4 个语料） | 每档 `clean-cache`，然后 `ccr`，再 sha256，旧新编译器各一轮 | 4/4 IDENTICAL：ptr_arith `ecd7a9df…d29d`、at_test_struct `891377232b…8f08`、generics_test `35cf0f26…5d23`、dyn_test `dfb82d2b…626f`，与 Task 1-3 报告逐字相同 |
| 4d | 影子通道（32 档，冷缓存） | `check --type-shadow --type-shadow-dump`，摘要、站点直方图、dump 全文逐档落盘 | 旧新两侧逐字节全同。聚合为 `decisions=2826 agree=2826 old_stricter=0 old_looser=0 unknown=0 unknown_bridge=0 unknown_engine=0 replace_bridge=0 replace_unknown=0`；站点直方图为 `assign-node=1816 fn-body-ret=778 if-branch=222 generic-apply-base=2 struct-field-type=4 array-elem-type=4`，其余 4 个站点为 0 |
| 5 | 四套回归 | `test_compile.py`、`test_purity.py`、`test_ccr_v7.py`、`test_type_engine.py` | PASS、PASS、27/27、PASS |
| 6 | 加宽回归（自己追加） | `test_impl`、`test_borrow`、`test_pointer_safety`、`test_params_limit`、`test_tuple_slots`、`test_agg_slots`、`test_agg_checks`、`test_named_dedup`、`test_interp_parity`、`test_cache_identity`、`test_nested_fn`、`test_lsp` | 全部通过：7/7、7/7、PASS、5/5、14/14、13/13、20/20、PASS、23/23、5/5、17/17、ALL PASS (10)，包含 P2a 评审 Critical 的桥接缓存重置 |
| 7 | 新行为回归 | `nice -n 19 python3 tests/selfhost/test_iface_ops.py` | 39/39。旧二进制配同源同用例逐字相同，见第 5 节 |
| 8 | 突变控制（计划要求的有效性实证） | 见第 6 节 | selftest 179/183 rc=1，新测试 38/39 rc=1（`neg_ptr_add_ptr:不报错地放行 = 放宽面复活`）。复位后 183/183、39/39、ELF 相同、全部产物逐字节复原 |
| 9 | 提交边界 | `jj commit -m … <6 路径>` | `jj show --stat` 显示我的 6 个路径、465/20。`tests/suite/*.cr.{out,rc}`（他人 scratch）未入库（`jj file list -r a99ee825 \| grep -c '\.cr\.\(out\|rc\)$'` 为 0） |

---

## 3. 关键结构事实（计划 Task 4 的“两层结构”，实测复证）

现状的“算术许可”分为两层，本批照原样拆分：

1. 早退规则（命中即 `return`，不进入表查询），属于结果规则，留在代码里：
   - 串拼接 `:1946`，只认 `OP_ADD`，`lt == TI_STR \|\| rt == TI_STR` 时结果为 `TI_STR`。
   - 指针算术 `:1948-1953`，`*T ± int` 得到 `*T`，`int + *T` 得到 `*T`。
   - 指针差 `:1955-1957`，`*T - *T` 得到 `int`。
2. 门（`:1959`）的语义是“两侧都不是数值才报错”，即 ANY。

因此门的许可集只能包含 `int`/`dex`。反例如下，本批负控已实测，见第 4/5 节：
`*T + *T` 现状报 `error[TB01]`，因为 `:1948/:1951` 不命中，`:1955` 只认 `OP_SUB`，门的两侧又都不是数值；
`"a" - "b"` 现状报 `error[TB01]`，因为 `:1946` 只管 `OP_ADD`。
如果把 `PTR`/`STRING` 填进 ADD 格，ANY 门下 `permits(PTR, ADD)=1` 就足以放行，结果不报错地降为 `TI_INT`，也就是放宽。

这与 spec 第 2.1 节“`+` 对 int/dex/string 合法”不冲突：该语义在现状由“门加早退规则”两处合起来给出。本批照现状拆分，对应关系是 `+` 的 string 合法性落在早退规则，int/dex 合法性落在门。

---

## 4. 18 个站点台账（逐条：落点、处置、依据）

口径：11 个二元（计划第 1 节家族 2-5：算术族 8、比较 1、逻辑 1、赋值 1），4 个一元（家族 6），3 个条件（家族 7）。
“已接线”表示判定改为查表。“留代码”表示按计划口径不接线，并逐条给出不能接线的原因。lead 明确要求：不能零行为变化地接线时，必须报告而不是硬接。

### 4.1 二元 11 条

| # | 站点（接线前行号） | 现有语义 | 处置 | 依据 |
|---|---|---|---|---|
| 1 | `:1944` 组派发 `op == OP_ADD…OP_MOD` | 选出算术族 | 留代码 | 这是结构判定，不是许可判定：决定后面走哪一族。换成查表需要先有“族”概念（P3 横切轴面） |
| 2 | `:1946` 串拼接 | `OP_ADD && (lt/rt == TI_STR)` 得到 `TI_STR` | 留代码 | 结果规则加早退：它同时决定结果类型。表的 ADD 格如果含 STRING，会在 `1 + 2` 上误命中（ANY 门语义），因此需要另设“拼接位”。计划没有定义这个位，加了就是新设计，不是逐格转录 |
| 3 | `:1948` `*T ± int 到 *T` | 结果为指针行 | 留代码 | 结果规则，返回 `lt`。表的 PTR ADD/SUB 格保持 0 |
| 4 | `:1951` `int + *T 到 *T` | 结果为指针行 | 留代码 | 同上 |
| 5 | `:1955` `*T − *T 到 int` | 结果为 int | 留代码 | 结果规则，且只认 `OP_SUB` |
| 6 | `:1959` 算术门 | `lt≠INT ∧ lt≠DEX ∧ rt≠INT ∧ rt≠DEX` 时报错 | 已接线（ANY） | `iface_permits(k(lt), op) == 0 && iface_permits(k(rt), op) == 0`，由 `checker.cr:1964` 消费 |
| 7 | `:1962` dex 支配 | `lt/rt == TI_DEX` 时结果为 `TI_DEX`，否则 `TI_INT` | 留代码 | 结果规则，门只管报不报错 |
| 8 | `:1963` 后备 `return TI_INT` | 结果为 int | 留代码 | 结果规则 |
| 9 | `:1965-1967` 比较 6 个 op | 恒为 `TI_BOOL`，不校验操作数 | 留代码 | 现状没有拒绝路径（全许可），没有门可换。表按计划填“全 13 类置 1”，作为 P3 收紧旋钮（第 7 节事实表） |
| 10 | `:1968-1973` 逻辑门 | 每侧必须是 `bool\|int`，结果为 `TI_BOOL` | 已接线（ALL） | `permits(k(lt), OP_AND) == 0 \|\| permits(k(rt), OP_AND) == 0`，谓词写 `OP_AND`，不另设 IP_LOGIC，由 `checker.cr:1979` 消费 |
| 11 | `:1931-1941` 赋值（`EXPR_BINARY` 加 `OP_ASSIGN`） | `type_compat_strict(lt, rt)` | 留代码（已引擎化） | 属于 P2a 判定替换面，`type_compat_strict` 是引擎加 legacy 回落，不是 ops 位集对象。表中的 `OP_ASSIGN` 位不使用（globals.cr 注） |

### 4.2 一元 4 条（全部是结果规则或无拒绝路径，表登记为全许可位）

| # | 站点（接线前行号） | 现有语义 | 处置 | 依据 |
|---|---|---|---|---|
| 1 | `:1979-1981` NEG/NOT | 直接 `return infer_expr(operand)`，不校验 | 留代码 | 没有拒绝路径，没有门可换（`-"a"` 现状 rc=0，实测 L6） |
| 2 | `:1982-2002` REF | 任意操作数得到 `alloc_type(TYP_PTR, inner, 0)` | 留代码 | 结果规则，构造类型行；全类许可 |
| 3 | `:2003-2014` DEREF | REF/PTR 得到内层，GPARAM 得到自身，后备透传 | 留代码 | 三个分支都是结果规则；后备等于没有拒绝路径（`*x`，x 为 int，现状 rc=0，实测 L7） |
| 4 | `:2016` 尾后备透传 | `return infer_expr(ast_a(node))` | 留代码 | 未识别一元 op 的透传，现状没有诊断 |

### 4.3 条件 3 条

| # | 站点（接线前行号） | 现有语义 | 处置 | 依据 |
|---|---|---|---|---|
| 1 | `:2274` `if` 条件 | `cond_ti == TI_BOOL \|\| == TI_INT` | 已接线（ONE / `IP_COND`） | `checker.cr:2288` |
| 2 | `:2385` `while` 条件 | `cond_ti == TI_BOOL`，严格 bool | 已接线（ONE / `IP_COND_BOOL`） | `checker.cr:2401`；不得与 `if` 合并，合并会收紧 `if` 或放宽 `while`，实测 `while 1` 报 TC04 |
| 3 | `:2411-2412` range 两端 | `st == TI_INT && et == TI_INT`，只收 int | 留代码 | 没有对应位。计划位表里最接近的 `IP_COND` 含 bool，用它就是放宽（`range(true, 3)` 现状报 error[TB01]，实测 L9：`"a".."b"` 报 TB01）。新造端点位属于计划位表外的设计，不在本批 |

---

## 5. 零行为变化方法（比 Task 3 更强的一版）

- 判据 4a/4b/4c/4d 统一使用同源双编译器对拍。基线是接线前的编译器二进制（Task 3 完成态冻结拷贝 `/tmp/p2b4_base_bin/corec`，sha `7ec070ad…f4bfc5e`，等于 Task 3 报告值，实测一致），让它跑同一份当前源码。对照是新二进制跑同一份源码。两侧输入逐字节相同，因此差异只可能来自编译器行为。
- 不使用“与历史存档比”的原因：本批同时改了 `checker.cr`（诊断路径）和 `type_selftest.cr`（被 `_import.cr` 传递 import，导致 `check src/compiler` 的输入变长）。旧配旧对比新配新会把输入增长误算成行为变化。Task 1/3 已经各踩过一次，登记为行号位移。本报告只报“旧配新等于新配新”，另外单列与旧基线的机械位移（2 条 TF01 行号 +33）。
- 冷缓存：`.ccr` 和影子两侧都逐档 `clean-cache`（cwd 为仓库根）。`check` 通道不读写 `.core/cache/cir`（实读 `main.cr:448-521`：缓存只在 IR 生成和 `build` 路径使用），所以 `check` 类判据没有跨重建缓存污染面。`build` 类判据一律先 `clean-cache`。
- 行为回归（判据 7）的对照：`tests/selfhost/test_iface_ops.py` 用旧二进制跑一遍（COREC 换成冻结基线），逐 case 输出与新二进制逐字节相同（两侧都是 39/39）。

---

## 6. 突变控制（计划要求的有效性实证，本报告自己跑，可复跑）

探针是把 `iface_registry.cr` 的 `AK_PTR` 条目 ops 从 `o_base` 改为 `o_base + iface_bit(OP_ADD)`，只改一行，带 `PROBE-M1` 标记。这正是计划点名的最容易放宽的方向。重建后：

```
FAIL ops.arith_gate_eq_legacy: got 1 want 0            ← 表侧：ADD 格出现非 int/dex 成员
FAIL ops.arith_permit_count:  got 11 want 10           ← 表侧：许可格数多 1
FAIL ops.infer_ptr_add_ptr_diag: got 0 want 1          ← 端到端：`*T + *T` 不再报诊断
FAIL ops.infer_ptr_add_ptr_code: got -1 want 6001      ← 端到端：诊断消失（6001 = EC_TB_ADD）
179/183 …rc=1
[FAIL] neg_ptr_add_ptr: expected rejection, got rc=0（静默放行 = 放宽面复活）   ← 真实源编译面
38/39 …rc=1
```

三层（表侧、端到端经真 `infer_expr`、真实源）同时失败，说明新用例有效，也说明门确实在判定，不是接线后仍然硬编码的空转。
复位：用 `cp` 恢复探针前副本，`cmp` 逐字节相同，`grep -c PROBE` 为 0，然后重建。结果为 183/183、39/39、ELF 哈希复原，全部产物（32 个语料、32 个影子、4 个 .ccr、自源 check）与探针前逐字节相同，探针零残留。纪律说明：该探针是本 agent 自己写入并撤销的临时改动，不是还原既有工作，先例是 Task 2/3 的同类钳位实验。

---

## 7. 事实表（侦查第 2 节的九条宽松面到表中格，供 Task 7 Step 5 直接消费）

| # | 现状宽松面（行号为接线前） | 表中格 | 现状诊断 | 本批处置 | P3 收紧建议 |
|---|---|---|---|---|---|
| 1 | 比较不校验操作数 `:1965-1967` | 6 个比较位对全 13 类置 1 | 无 | 登记，不接线 | 增加“可比性”判据（结构/序列需要元素可比）后逐类收紧 |
| 2 | 算术门“任一侧数值即可” `:1959` | ADD..MOD 只 {int, dex} | `1 + [int;3]` / `"a" * 2` 不报错地；`"a" * "b"` 报 TB01 | 原样保留（负控钉红） | 改为 ALL 语义（两侧都必须是数值）或引入显式提升规则；须先有全语料证据 |
| 3 | 串拼接优先且单向 `:1946` | 无位，早退规则留代码 | 无 | 原样保留 | 拼接位独立建模（`+` 的 string 合法性上表）；`1 + "a"` 是否为 string 属于语义裁决 |
| 4 | 一元透传 `:1979` | NEG/NOT 对全 13 类置 1 | 无（`-"a"` rc=0） | 原样保留，登记 | 数值性判据（NEG 只收数值类，NOT 只收 bool/int） |
| 5 | 解引用后备透传 `:2016`（加 `:2014`） | DEREF 对全 13 类置 1 | 无（`*x`，x 为 int，rc=0） | 原样保留，登记 | 后备分支改为拒绝（REF/PTR/GPARAM 之外报错） |
| 6 | 索引类型不校验 `:2583` 的 `idx_ti` 没有消费者 | `IP_INDEX` 恰好 {string, sequence}（容器面） | `arr[true]` rc=0 | Task 5 消费格；本批只填位 | 索引表达式类型必须是 int（`IP_INDEX` 是容器侧位，索引侧需要另设位） |
| 7 | 字段落空不报错地 `:2578` | `IP_FIELD` 恰好 {product, named} | `x.a`（x 不是 struct）rc=0 | Task 5 消费格；本批只填位 | 落空分支加诊断（TK/TS 系） |
| 8 | 转换无校验 `:2892-2908` | `IP_AS` 对全 13 类置 1 | `"a" as int` rc=0 | 原样保留，登记 | 转换合法性矩阵（哪些源到目标允许） |
| 9 | dyn = ⊤ 近似 | `IP_METHOD` 恰好 {dyn, named} | 不存在方法时 TF/N 报错（既有） | Task 5 消费格；本批只填位 | dyn 位图 64 上限解除（spec 第 3.3 节已登记） |

收紧清单为空。本批“旧接受变为新拒绝”零条，全部判据都是“旧接受等于新接受”的双向对拍。

---

## 8. 新用例和有效性形状

- 表侧 15 例（`ops.*`）：`arith_gate_eq_legacy`/`arith_permit_count`、`logic_*`、`cond_*`、`all_permit_eq_legacy`/`all_permit_count`、`index/field/method_permit_set`、`entry_row_consistent`。逐格全表对拍（13 类逐 op 与“改动前谓词”内联式对拍，不是抽样），加许可格数哨兵（全 0 表必然失败），加条目面回读一致性。
- 端到端 13 例（经真 `infer_expr`，把“门是否报错”写成诊断增量加诊断码断言）：正控 6 例（int 加、串拼接、指针加 int、dex 支配、逻辑 int 侧、比较不校验），负控 5 例（`"a" - "b"` 的 diag/code/结果三断言，`*T + *T` 的 diag/code/结果三断言，dex 逻辑 diag/code），早退保留 1 例（指针差得到 int），反真空哨兵 1 例（构造节点 kind/op）。必须有这一段的原因：表侧用例证明不了“线接对了”。接线点写错键（例如 ADD 行调用 `iface_kind_of` 之外的行）在表侧会全绿，只有端到端经真函数才暴露，并包含 diag 增量 0/1 的硬断言。
- 行为回归 39 例（`test_iface_ops.py`）：正控 17，负控 14（含 `*T + *T`、`"a" - "b"`、dex 逻辑、`while 1` 与 `if 1` 的不对称），登记面 8（断言现状宽松面不动）。
- 诚实注记：selftest 的端到端用例会向 `g_diags` 追加诊断记录（`check_error` 只追加不打印；`selftest-types` 的 rc 只由用例计数决定）。实测没有输出污染，rc 正常。该性质由 `test_type_engine.py` 的“零 FAIL 加 rc=0”判据覆盖。

---

## 9. 偏差和计划勘误（需 lead 过目）

1. 计划许可格表有两处与“一字等价”自相矛盾，本批按 Step 2 的替换代码为准，DEX 两格为 0：
   - 逻辑组写在“AK_INT/AK_DEX”行，括注却是“允许 bool|int”。实测 `1.5 && true` / `1.5 || false` 报 `error[TC01]`（探针 N7 和 `neg_logic_dex_or`），因此 DEX 的 AND/OR 格必须为 0，填 1 就是放宽。
   - 同一行的 `IP_COND` 同理：`if 1.5` 报 `error[TC01]`（探针 N8），因此 DEX 的 IP_COND 格为 0。
   两处都以“与现状源码一字等价”判据裁决（计划 Step 2 给出的替换代码就是这个要求），并在 `iface_registry.cr:89-91` 就地注记，防止后续“照表填齐”时被改回。
2. `t.0`（无空格）当前无法词法化（计划 Step 1 正控列了 `t.0`）。实测 `t.0` 报词法错误 `invalid integer literal`，lexer 把 `.` 加数字当成数字字面量起点，没有设置 `has_dot`。因此 `t . 0`（带空格）可用，本批正控使用带空格形式。这是既有的词法限制，不是本批引入，登记在案，不属于本批范围（元组字段面属于 Task 5）。
3. `()` 不是表达式（实测 `error: Unexpected token in expression`），因此计划中“unit 操作数”类探针改用字符串、数组等可达形态。
4. 不 bump `CIR_CACHE_VER`：本批不改 IR 发射面（ELF 逐字节、影子、`.ccr` 全同，缓存内容不可能不同），bump 没有必要。TODO #5 家族只在发射面变更时 bump。
5. 计划文件未改（`docs/superpowers/plans/…`）：plan-p2b 仍活跃，避免并发修改同一文件。本报告的变化表可以作其回填输入。
6. `tests/suite/*.cr.{out,rc}`（64 个 scratch）是他人产物，本批未删未入库，路径限定可核。

---

## 10. 未覆盖面和交接

1. Task 5 消费格已就位：`IP_INDEX`/`IP_INDEX_RANGE`/`IP_FIELD`/`IP_METHOD` 四位已按计划填好（含 `ops.index_permit_set` 等 3 例），Task 5 只需在拒绝分支接线，结果规则和诊断面零改动。
2. 全部 4 组“全许可列”（比较 6、NEG、NOT、REF、DEREF、AS）本批不接线。现状没有拒绝路径，没有门可换。表的这些格是 P3 的收紧旋钮，第 7 节事实表逐条给了建议。
3. 性能面（如实登记，不是缺陷）：门每判一次需要 2 次 `iface_kind_of` 加 `iface_entry` 的 13 条线性扫加位构造循环。本批口径是保持语义接线。`test_compile.py` 等全套回归通过，没有超时迹象。如果后续有编译耗时证据，可以加 `(ak 到 entry)` 快表或位集缓存，不在本批。
4. shadow 数字口径：本报告只报本批语料集（32 档）的聚合（`decisions=2826`），不与 findings 第 11 节的 71 文件/26989 口径混比。Task 2 已如实登记两次口径差异。
5. 提交链：Task 2 `31143cd0`，Task 3 `6d2790cd`，Task 4 `a99ee825`。下一批 Task 5 可以直接以 `a99ee825` 为基线。

---

## 11. 证据命令速查（可复核）

```bash
# 判据 1/2
nice -n 19 python3 build_selfhost_native.py            # rc=0 + 3 守卫 clean
nice -n 19 ./build/corec selftest-types | tail -1      # 183/183
# 判据 3（cwd = 仓库根）
nice -n 19 ./build/corec clean-cache && nice -n 19 ./build/corec build tests/suite/ptr_arith.cr --static -o /tmp/x && sha256sum /tmp/x
# 判据 4（本报告脚本：旧/新两编译器 × 同一份源）
nice -n 19 python3 /tmp/p2b4_run.py /tmp/p2b4_base_bin/corec /tmp/p2b4_base
nice -n 19 python3 /tmp/p2b4_run.py ./build/corec              /tmp/p2b4_final
diff -r /tmp/p2b4_base/corpus   /tmp/p2b4_final/corpus     # 空
diff -r /tmp/p2b4_base/shadow   /tmp/p2b4_final/shadow     # 空
diff -r /tmp/p2b4_base/ccr      /tmp/p2b4_final/ccr        # 空
diff    /tmp/p2b4_base/compiler.txt /tmp/p2b4_final/compiler.txt   # 空
# 判据 5/6/7
for t in test_compile test_purity test_ccr_v7 test_type_engine test_lsp test_iface_ops; do nice -n 19 python3 tests/selfhost/$t.py | tail -1; done
# 行为现状探针（接线前/后 32 例逐字节同）
nice -n 19 python3 /tmp/p2b4_probe.py /tmp/p2b4_base_bin/corec   # 32/32（与下面逐字节同）
nice -n 19 python3 /tmp/p2b4_probe.py                            # 32/32
```

基线取值口径（诚实声明）：ELF、`.ccr`、语料、影子、自源诊断的基线，全部由接线前的 `build/corec`（Task 3 完成态）冻结拷贝 `/tmp/p2b4_base_bin/`（sha `7ec070ad…` / `47455109…`）在同一构造路径和 clean-cache 下实测取得。`.ccr` 的四个哈希另与 Task 1-3 报告值逐字一致，跨批可比。
