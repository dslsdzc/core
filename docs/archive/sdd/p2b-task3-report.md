# R2 P2b Task 3 报告：字面量定型查表接线（5 处）

Status: DONE（全部判据通过；计划行号变化已按内容定址并记录，见 第 1 节）
提交：`6d2790cd`（change `kyxrvzkpyrsq…`）`refactor: R2 P2b Task 3，字面量定型查表接线…`（路径限定 5 路径 = `src/compiler/checker.cr`(15±) · `src/compiler/iface_registry.cr`(6，纯注释) · `src/compiler/type_selftest.cr`(41) · `src/ci/run.sh`(2，例数注释) · `TODO.md`(2)；共 56 insertions / 10 deletions）
计划：`docs/superpowers/plans/2026-09-11-r2-p2b-iface-ops.md` Task 3

---

## 1. 计划行号变化（按内容定址，未猜）

计划写 5 处 = `checker.cr:1892`/`:1894`/`:1895`/`:1896`/`:1897`。接线时点实测 = `:1896`/`:1898`/`:1899`/`:1900`/`:1901`（偏移 +4），成因：计划侦查底座是起草时点工作副本（`checker.cr` 3376 行），此后实施的批次又动了 `infer_expr` 之前的位置（现 3380 行）。

另一处计划未写明的结构事实（接线必须知道）：5 行不连续，`:1897` 的 `EXPR_NONE` 转发 `if` 夹在 `EXPR_INT`（:1896）与 `EXPR_DEX`（:1898）之间。故「5 行变 5 行」是逐行同构替换，`EXPR_NONE` 行原样保留、不重排（计划的「不得合并成循环」口径正是指此）。已把该变化与不连续性注在接线点注释（`checker.cr:1896-1902`）与注册表注释（`iface_registry.cr:26-27`、`:151-152`）。

---

## 2. 交付物（file:line，实测）

| 交付物 | 落点 | 说明 |
|---|---|---|
| 接线 5 处 | `checker.cr:1901`/`:1903`/`:1904`/`:1905`/`:1906`（注释块 `:1896-1900`） | `return TI_INT;` 改为 `return iface_lit_ti(EXPR_INT);` … 逐行同构；`EXPR_NONE` 行（`:1902`）一字未动 |
| 端到端用例段（10 例） | `type_selftest.cr:621-657`（新增段，段内 10 条 `ts_check`；`iface.lit_*` 段头注释 `:543-544` 同步为「接线后」） | 见 第 4 节 |
| 注册表注释同步 | `iface_registry.cr:26-27`（格注行号）、`:151-152`（接线状态） | 纯注释（Task 2 已证：注释面改动不进二进制；本次亦经 `build/corec` 逐字节复核） |
| 例数同步 | `src/ci/run.sh:71`（145 例增加到 155 例；`P2b-T1/T2` 改为 `P2b-T1/T2/T3`） | 该处是 `selftest-types` 的唯一 CI 挂点 |
| TODO P5 继承项 | `TODO.md` #24「P5 继承项」新增 ④ | 见 第 6 节 |

接线前后的逐字对照（转录证据）：

```core
// 改动前（checker.cr:1896/1898/1899/1900/1901）
if ast_kind(node) == EXPR_INT { return TI_INT; }
if ast_kind(node) == EXPR_DEX { return TI_DEX; }
if ast_kind(node) == EXPR_STRING { return TI_STR; }
if ast_kind(node) == EXPR_BOOL { return TI_BOOL; }
if ast_kind(node) == EXPR_CHAR { return TI_CHAR; }
// 改动后
if ast_kind(node) == EXPR_INT { return iface_lit_ti(EXPR_INT); }
if ast_kind(node) == EXPR_DEX { return iface_lit_ti(EXPR_DEX); }
if ast_kind(node) == EXPR_STRING { return iface_lit_ti(EXPR_STRING); }
if ast_kind(node) == EXPR_BOOL { return iface_lit_ti(EXPR_BOOL); }
if ast_kind(node) == EXPR_CHAR { return iface_lit_ti(EXPR_CHAR); }
```

格对应 = 注册表 `lit_code` 列（Task 1 落）：`EXPR_INT`(entry0,ti=TI_INT) / `EXPR_DEX`(entry1,TI_DEX) / `EXPR_STRING`(entry2,TI_STR) / `EXPR_BOOL`(entry3,TI_BOOL) / `EXPR_CHAR`(entry6,TI_CHAR)。表内容一字未改（本次零表格数据改动；`ops` 列仍空集，Task 4/5 填）。

---

## 3. 判据（命令 + 结果）

| # | 判据 | 命令 | 结果 |
|---|---|---|---|
| 1 | 自举构建 | `nice -n 19 python3 build_selfhost_native.py` | rc=0；3× `[GUARD] … build log clean (error[ = 0, undefined = 0)`；`=== BUILD SUCCESS ===` |
| 2 | 自测用例表 | `nice -n 19 ./build/corec selftest-types` | 155/155，零 FAIL，rc=0（基线 145，增加 10 例，见第 4 节） |
| 3 | ELF 逐字节 | 先 `clean-cache`，再 `build tests/suite/ptr_arith.cr -o … --static`，最后 `sha256sum` | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475` IDENTICAL（改前/改后各实测） |
| 4 | 行为零变化（语料） | 32 个 `tests/suite/*.cr` 逐个 `check`，stdout+stderr+rc 落盘（改前二进制 × 同源语料 vs 改后二进制 × 同源语料） | `diff -r` 逐字节全空（32 档；rc 分布 20×0 / 12×1 同前），方法见 第 5 节 |
| 5 | `.ccr` 逐字节 | 4 语料逐档先 `clean-cache`，再 `ccr`，最后取 sha | 4/4 同哈希：ptr_arith `ecd7a9df…d29d` · at_test_struct `891377232b…8f08` · generics_test `35cf0f26…5d23` · dyn_test `dfb82d2b…626f` |
| 6 | 影子通道 | 32 档 tier-1 语料 `check --type-shadow` 输出逐档比较 | 逐字节全同（改前/改后） |
| 7 | 诊断面（编译器自源） | 改前二进制 × 改后源码 vs 改后二进制 × 改后源码：`check src/compiler` | 逐字节相同（隔离输入增长，见 第 5 节）；与「改前×改前」基线比仅既有 2 条 TF01 误报（`lits_copy` / `ty_memo_slot_no_grow`，`ty_shadow.cr:118` 记载）行号 +5，零新增诊断 |
| 8 | 回归（计划 Step 3 的 4 套） | `test_compile.py` · `test_purity.py` · `test_ccr_v7.py` · `test_type_engine.py` | 全部通过：PASS · PASS · 27/27 · PASS |
| 9 | 回归加宽（本报告自加） | `test_impl` · `test_borrow` · `test_pointer_safety` · `test_params_limit` · `test_tuple_slots` · `test_agg_slots` · `test_agg_checks` · `test_named_dedup` · `test_interp_parity` | 全部通过：7/7 · 7/7 · PASS · 5/5 · 14/14 · 13/13 · 20/20 · PASS · 23/23 |
| 10 | 突变控制（非真空性） | 见 第 4 节 | 6 例报错（149/155 rc=1），复位后 155/155 且二进制逐字节复原 |
| 11 | 提交边界 | `jj commit -m … <5 路径>` | `jj show --stat` = 我的 5 路径；工作副本 64 个 `tests/suite/*.cr.{out,rc}` scratch 未入库（`jj file list -r @- \| grep -c '\.cr\.\(out\|rc\)$'` = 0） |

---

## 4. 新用例（10 例）与判别力实证

### 4.1 形状：端到端经真 `infer_expr`，不是「再断一次表」

表侧（`iface.lit_*`，Task 1 落）只能证明表格对；证明不了接线正确，若把 `EXPR_INT` 行写成 `iface_lit_ti(EXPR_DEX)`，表侧用例全部通过。故本 Task 的判据本体 = 用与 parser 同族的 `alloc_node` 构造 5 个字面量 AST 节点，经真 `infer_expr` 跑（`alloc_node` 定义 `parser.cr:13`；`infer_expr` 即 checker 生产函数）：

| 用例 | 断言 | 防的是什么 |
|---|---|---|
| `lit.node_kinds` | 5 个构造节点 `ast_kind` 各为预期 kind | 防空过标记：`alloc_node` 参数错位 因此「拿错节点比错值」假通过 |
| `lit.infer_int/dex/str/bool/char`（5 例） | `infer_expr(节点)` == 改动前的字面常量（`TI_INT/TI_DEX/TI_STR/TI_BOOL/TI_CHAR`） | 接线点写错键/接错函数（表正确但接线错误） |
| `lit.infer_is_table` | 5 个 kind 上「端到端结果 == 表查表结果」 | 端到端 ↔ 表 一致性（防两侧各自变化） |
| `lit.none_forwards` | `EXPR_NONE`（a=内层 int 节点）得到 `TI_INT` | 短路顺序逐字保持：转发行在 `EXPR_INT` 与 `EXPR_DEX` 之间、且仍转发 |
| `lit.none_empty_unit` | `EXPR_NONE`（a=-1）得到 `TI_UNIT` | 转发行不命中时落函数中部的 `EXPR_NONE` 分支（未被接线挤掉） |
| `lit.neg_node_unit` | `infer_expr(-1)` 得到 `TI_UNIT` | 函数头行负值检查未被接线挤掉 |

计划 Step 1 的「`ty_code_to_ti` 交叉断言」按计划原文顺延 Task 6（该函数 Task 6 才实施；计划原文「本 Task 先断前 5 个 `iface.lit_*` 用例不变」）。本 Task 用更强的替代（上表 5 例端到端）覆盖同一风险面。

### 4.2 突变控制（Task 2 先例，实测记录）

1. 探针：注册表 `iface_put(0, AK_INT, TI_INT, -1, EXPR_INT, 0)` 的 `lit_code` 由 `EXPR_INT` 改为 `EXPR_DEX`（一行，带 `PROBE` 标记），然后重建，运行 `selftest-types`：

```
FAIL iface.lit_int: got -1 want 0          （表侧：无条目 lit_code == EXPR_INT
FAIL iface.lit_dex: got 0 want 1           （表侧：entry0 抢走 EXPR_DEX 的命中
FAIL iface.lit_ak: got 0 want 1
FAIL lit.infer_int: got -1 want 0          （端到端：infer_expr(int 节点) 随表变
FAIL lit.infer_dex: got 0 want 1           （端到端
FAIL lit.none_forwards: got -1 want 0      （转发行指向内层 int 节点，查表后随表变化
149/155 type-engine cases passed  (rc=1)
```

2. 复位：先用 `cp` 回到探针前副本，`cmp` 逐字节同、`grep -c PROBE` = 0，然后重建，得到 155/155 rc=0，且 `build/corec` / `build/corearch` sha256 与探针前逐字节相同（`7ec070ad…f4bfc5e` / `47455109…a7b117`）因此 探针零残留、构建确定性。该实验同时证明两件事：① 新用例有效（改表必然报错）；② 接线确在读表（表变 因此 真 `infer_expr` 输出变），非「接线后仍硬编码常量」的没有实际作用。纪律说明：探针是本 agent 自写自撤的临时改动（非还原既有工作），证据 = 空 `PROBE` 计数 + 二进制 sha 复原。

---

## 5. 零行为变化方法学（含对上一批方法的修正）

- 语料面（判据 4）：基线 = 改动前的编译器二进制（Task 2 完成态 `build/corec` 冻结拷贝 `/tmp/p2b3_base_bin/corec`，sha `86eaf8cc…`）跑同一份语料；改后 = 新二进制跑同一份语料。语料文件本 Task 零改动 因此 两侧输入相同，比较即「编译器行为差」，这正是比「与历史数字比」更硬的同源对拍。
- 编译器自源面（判据 7，方法学修正）：`check src/compiler` 的输入 = 编译器源码，而本 Task 改了源码（+5 行）因此 直接比「旧×旧 vs 新×新」会把输入增长误算成行为变化（Task 1 报告已遇到这个问题，登记为行号位移）。故本报告补测 旧二进制 × 新源码：其输出与新二进制 × 新源码逐字节相同因此 诊断行为零变化；与「旧×旧」基线之差仅 = 2 条既有 TF01 的行号 +5（新增 5 行的机械位移）。
- `.ccr` / 影子 / ELF：冷缓存（每档起始 `clean-cache`，cwd = 仓库根）逐档实测；`.ccr` 预期「零扰动」兑现（注册表不 alloc 类型行、不改行号）。

---

## 6. TODO 登记（协调者指派的顺带项）

`TODO.md` #24「P5 继承项（须在删 legacy 前清零/实施）」新增 ④（2 行）：`sh_native_ak_legacy`/`sh_base_ak_legacy`（`ty_shadow.cr:91-113`，零生产调用，仅 `type_selftest.cr` 的 `iface.by_ty_code_all_codes`/`iface.native_ak_all_rows`/`iface.compare_is_live` 三例引用）删除归 P5；删时须同步调整该三例（对拍面改为「生产入口 vs 表」或随影子层下线一并撤）。

---

## 7. 未覆盖面 / 交接

1. 「接线确在读表」不可由永久用例静态断言（硬编码常量与查表在行为上不可区分）因此 该性质由突变控制（第 4.2 节，评审时可复跑）承担，不是漏测；永久用例只能固定行为（`lit.infer_*`）与端到端↔表一致（`lit.infer_is_table`）。
2. 性能面（如实登记，非缺陷）：`iface_lit_ti` = 13 条线性扫 + `iface_ensure` 检查，每个字面量节点一次（`infer_expr` 热路径）。本批口径 = 保语义接线；若后续有编译耗时回归证据，可加「(kind 到 entry) 侧表」或把 5 条常量的查询缓存（不在本批）。
3. `ops` 列仍空集（Task 4/5 填）；本 Task 未新增对 `iface_permits` 的任何消费者。
4. `name_ni` 列仍 -1（Task 1 的登记偏差，本 Task 未动，未 interning 任何串 因此 `.ccr` STR 段零扰动）。
5. 计划 Task 2 的遗留：`tests/suite/*.cr.{out,rc}` 64 个 scratch 仍在工作副本（他人 20:52 语料捕获产物），本 Task 未删、未入库（非我创建，删除需明确许可）；建议 Task 7 收尾统一处置。
6. crash 面：`corearch` 未在本 Task 改动（checker 变更不进后端）；ELF 逐字节为证。

---

## 8. 证据命令速查（可复核）

```bash
# 判据 2
nice -n 19 ./build/corec selftest-types | tail -1                 # 155/155
# 判据 3（先 clean-cache，cwd = 仓库根）
nice -n 19 ./build/corec clean-cache && nice -n 19 ./build/corec build tests/suite/ptr_arith.cr -o /tmp/x --static && sha256sum /tmp/x
# 判据 4/5/6/7（本报告脚本：同源双编译器对拍；$1 = 二进制，$2 = 落盘目录）
bash /tmp/p2b3_run.sh /tmp/p2b3_base_bin/corec /tmp/p2b3_base   # 改动前（基线）
bash /tmp/p2b3_run.sh ./build/corec              /tmp/p2b3_final  # 改动后
diff -r /tmp/p2b3_base/corpus /tmp/p2b3_final/corpus               # 空
diff -r /tmp/p2b3_base/shadow /tmp/p2b3_final/shadow               # 空
nice -n 19 /tmp/p2b3_base_bin/corec check src/compiler >| /tmp/a  # 旧二进制 × 新源码
nice -n 19 ./build/corec            check src/compiler >| /tmp/b  # 新二进制 × 新源码
cmp /tmp/a /tmp/b                                                  # IDENTICAL
```

基线取值口径（诚实声明）：ELF/`.ccr`/语料/影子全部基线均为改动前由 `build/corec`（Task 2 完成态）冻结拷贝 `/tmp/p2b3_base_bin/` 在同一构造路径 + clean-cache 下实测取得（落盘 `/tmp/p2b3_base*/`），非沿用文档或上一批报告的哈希。
