# R2 P2b Task 1 报告：建层，本质条目表、`iface_*` 查询 API 和用例表（零消费者，零行为变化）

状态：DONE_WITH_CONCERNS。交付物完整，全部判据通过；有 1 处受硬判据约束的已登记偏差：条目表的 `name_ni` 列填 `-1`，见 §5.1。

提交：`7f520dce`（change `nrrzvsnt`），信息为 `feat: R2 P2b Task 1——本质条目表 + iface_* 查询 API（建层；零消费者零行为变化）…`。路径限定 7 个路径，327 行纯新增，0 删除。

计划：`docs/superpowers/plans/2026-09-11-r2-p2b-iface-ops.md` 的 Task 1。

---

## 1. 交付物与落点（file:line，全部实测）

| 交付物 | 落点 |
|---|---|
| 新建 `src/compiler/iface_registry.cr`（216 行，纯函数和常量） | 布局常量 `:44-48`（`ESZ_IFACE_ENTRY=40` / `OFF_IE_AK/TI/NAME/LIT/OPS` / `IFACE_ENTRY_COUNT=13`）；`iface_registry_init` `:62-82`（13 条 `iface_put`）；`iface_put` `:85-91`；`iface_ensure` `:95-97`；`iface_count` `:100`；`iface_entry` `:103-112`；`iface_ops` `:115-119`；`iface_permits` `:123-133`；`iface_lit_entry` `:138-148`；`iface_lit_ti` `:151-155`；`iface_lit_ak` `:158-162`；`iface_by_ty_code` `:168-179`；`iface_kind_of` `:183-197`；`iface_ti_of` `:200-204`；`iface_of_term` `:209-216` |
| `src/compiler/globals.cr` | `:246-253`（`g_iface_entries` / `g_iface_entry_count` / `g_iface_registry_ok`）。声明在类型引擎全局块之后，遵循 `g_purity_inst` 的声明位置约束 |
| `src/compiler/checker.cr` | `init_types()` 尾部 `:257`，在 9 行原生 alloc 之后调用 `iface_registry_init()` |
| `src/compiler/_import.cr` | `:15`，在 `type_engine` 之后、`ty_shadow` 之前 |
| `build_selfhost_native.py` | corec 清单 `:312`、corelsp 清单 `:399`，同位置 |
| `tests/selfhost/test_compile.py` | `concat_sources()` `:28`，同位置。清单变化会让该测试的 resolver 报 `Undefined name` |
| `src/compiler/type_selftest.cr` | `:483-567`，`iface.*` 用例段，43 例，纯新增 86 行 |

表数据共 13 条，逐项按语义写死，不按下标推演。8 个原生条目：`AK_INT` 对应 `TI_INT`、`AK_DEX` 对应 `TI_DEX`、`AK_STRING` 对应 `TI_STR`、`AK_BOOL` 对应 `TI_BOOL`、`AK_UNIT` 对应 `TI_UNIT`、`AK_NEVER` 对应 `TI_NEVER`、`AK_CHAR` 对应 `TI_CHAR`、`AK_DYN` 对应 `TI_DYN`。bool 和 string 错位书写，是为了明确下标不是一一对应。结构/命名条目有 `AK_PRODUCT`/`AK_SEQUENCE`/`AK_REF`/`AK_PTR`/`AK_NAMED`，`ti_row = -1`。`lit_code` 列逐格转录自 `infer_expr` 头部的 5 条内联 if（`checker.cr:1892-1897`），格注见文件头 `:28-33`。`ops` 列全为 0，即空集，Task 4/5 填充，本 Task 没有消费者。`iface_by_ty_code` 是 `sh_base_ak`（`ty_shadow.cr:75-88`）的语义拷贝，包含两个已裁决的灰格：`TY_DEX_S` 对应 `AK_DEX`，`TY_GENERIC_PARAM` 对应 `AK_NAMED`。

三态纪律：`iface_ops(-1/未知)` 返回 0，表示无许可，绝不当成 1。`iface_kind_of(负数/越界)` 返回 -1。`iface_lit_*` 对 `-1` 键先行拒绝；`lit_code = -1` 是“无字面量”哨兵，直接扫描会命中无字面量条目。`iface_permits` 的位下标越界（小于 0 或大于 62）返回 0，不得回绕。位构造是乘 2 循环，`op >= 63` 会把 i64 位集推成负数，等于全部命中。本批没有引擎判定调用，因此没有预算窗口；`type_equal_engine` 的 `ty_budget_reset` 前后隔离在本 Task 不适用，从 Task 2 起适用。

---

## 2. 判据（命令与结果）

| 序号 | 判据 | 命令 | 结果 |
|---|---|---|---|
| 1 | 自举构建 | `nice -n 19 python3 build_selfhost_native.py` | rc=0，`=== BUILD SUCCESS ===`（corec/corearch/corelsp） |
| 2 | 自测用例表 | `nice -n 19 ./build/corec selftest-types` | 138/138，零 FAIL。基线 95/95，增加 43 例，见 §3 |
| 3 | ELF 逐字节 | `clean-cache`，然后 `build tests/suite/ptr_arith.cr --static -o /tmp/pa_p2b1_new`，再 `sha256sum` | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`，IDENTICAL。改造前基线同值，本机实测两次 |
| 4 | `.ccr` 逐字节（计划 Step 4） | `clean-cache`，然后 `ccr tests/suite/ptr_arith.cr -o /tmp/t1_new.ccr`，再 `cmp` | `ecd7a9dfd557810651d9f4a31bf5775556b5c15518fb0a9dbacb56af83dcd29d`，IDENTICAL。改前基线同值，冷缓存各取一次 |
| 5 | 诊断零变化（语料） | 32 个 `tests/suite/*.cr` 逐个 `check`，`>|` 落盘 stdout、stderr 和 rc | `diff -r` 逐字节相同，20 个 rc=0，12 个 rc=1，与之前相同 |
| 6 | 诊断零变化（编译器源码） | `nice -n 19 ./build/corec check src/compiler` | 与基线 diff 只有 3 处：① import 清单新增 `-> src/compiler/iface_registry.cr`；②③ 既有 2 条 TF01（`lits_copy` / `ty_memo_slot_no_grow`，`ty_shadow.cr:118` 记载的已知误报）行号 +13 位移，由本批新增行导致。零新增诊断 |
| 7 | 回归 | `test_compile.py` / `test_purity.py` / `test_ccr_v7.py` | 通过（“All selfhost compile tests passed”）/ 通过 / 27/27 通过 |
| 8 | 提交 | `jj commit -m … <7 路径>` | `7f520dce`；`jj show --stat` 显示本任务的 7 个路径，327 insertions / 0 deletions，工作副本中他人改动未卷入 |

---

## 3. 新用例计数：43 例（95 到 138），覆盖口径与理由

计划 Step 1 给了 20 例（`iface.count`、逐条目 `*_ti`、`kind_*`、`lit_*`、`ops_unknown*`），并注明“实现者实测补面，计数以实测为准”。实际落 43 例（`type_selftest.cr:483-567`），多出的 23 例是因为交付面大于计划例表：

- 13 个条目乘两向：计划只覆盖 8 个原生条目中的 5 个 `*_ti`（int/dex/str/bool/dyn，`:490-492`/`:497`）和 4 个 `kind_*`（`:503/505/506/510`）。补充 `unit/never/char` 三个 `*_ti`（`:494-496`）和 `kind_dex/unit/never/char`（`:504`/`:507-509`），并把 5 条结构/命名条目的 `ti_row = -1`（类级，无规范行）立为一例（`:498-501`），防止类级和行级混同。
- 结构行到类（计划 §4.1 的分派全表，此前没有实测用例）：`kind_ptr_ref`（`:516`）、`kind_seq`（ARRAY 加 SLICE，`:520`）、`kind_product`（`:523`）、`kind_named`（NAMED 加 GENERIC_PARAM 加 GENERIC_APPLY，`:527`），共 4 例。
- `iface_by_ty_code`（本 Task 新交付，计划把它的用例划给 Task 2）：原生 8 个码、两条灰格、未映射码，共 3 例（`:535-542`）。
- 其余 API 逐签名：`entry_lookup`，包括负键和越界键不得与行 0 混同（`:531`）；`lit_ak` 5 种（`:550-553`）加负键（`:555`）；`of_term` 的 atom/⊤ₖ/复合/越界 4 例（`:558-562`）；`ops_unknown` 2 例（`:564-565`）；`permits_bad_op`（`:566-567`）。

刻意不写的一例，防止未来出现红例：不断言“`ops` 全 0”。计划要求本 Task 落空集，但 Task 4/5 会逐格填位集，断言空集会在下一批变成必须删除的红例，违背“用例只增不减”。改用持久性质断言：未知原子返回 0，位下标越界返回 0（`:566-567`）。

---

## 4. 零消费者确认（Task 1 硬口径）

全仓 `grep -rn "iface_" src/` 的消费者面只有三处：`iface_registry.cr` 自身、`checker.cr:257` 的 `iface_registry_init()` 调用（计划 Step 3 明列的挂点）、`type_selftest.cr` 用例段。checker 的公理区零改动，`infer_expr` / `res_type_node` / `res_call_type` 一行未动。`ops` 空集期间没有任何判定路径消费它。

---

## 5. 偏差与发现（需要 lead 过目）

### 5.1 偏差，已登记：`name_ni` 列填 `-1`，没有 `str_intern` 显示名

计划把条目的第 3 个字段定为“名字 ni（`str_intern`，供自测/诊断显示）”。实测证明该实现与计划的硬判据冲突。`.ccr` 的 STR 段是编译期 `g_strs` 的全量内容，`ccr_io.cr:537` 起逐串落盘。实测 ptr_arith 的 `.ccr` 含 159 个串，包括 `load64`/`fpow2i`/`g_cir_write_buf` 等与源文件无关的编译器内部串。在 `iface_registry_init`（每次编译一次，位于 `init_types` 尾部）里执行 `str_intern("product")` 之类的调用，会把 13 个新串追加进 `g_strs`，导致 `.ccr` 逐字节变化，直接违反 Global Constraints 的“`.ccr` 预期逐字节不变；若变则停下上报”。

反向实测，控制组：用带一个未用标识符 `zzz_probe_unused_ident` 的探针源编译 `.ccr`，该串唯一地出现在 STR 段。探针 .ccr 有 153 个串，ptr_arith 有 159 个，差集恰好是 `['zzz_probe_unused_ident']`。因此“编译期多 interning 一个串会导致 `.ccr` 字节变化”是实测事实，不是推断。

处置：零消费者阶段没有任何一格需要显示名，所以本 Task 不 interning，`name_ni = -1`，字段和 40B 布局原样保留。理由与实测写进 `iface_registry.cr:51-60` 的建表注记，防止后来者“补全”这一列而打破判据。显示名以及是否接受 STR 段增长，留到首个消费者（P3 诊断/显示）实现时裁决。如果 lead 要求本批就填名，改动是 13 处 `str_intern`，并接受 `.ccr` 字节变化；如果 ELF 也嵌入串表会更糟，实测未嵌入，ELF 没有任何字符串表，见 §6。本报告不建议这样做。

### 5.2 发现，Task 4 硬前置：`IP_*` 位下标常量必须声明在 `globals.cr`

计划 Task 4 的接线形式是 `iface_permits(kind(cond), IP_COND)`，在 `checker.cr` 内直接引用 `IP_*`。但本仓库的变量和常量跨文件按声明序可见，先例是 `globals.cr:290-292` 的 `g_purity_inst`。`checker.cr` 在清单中位于 `iface_registry.cr` 之前，所以把 `IP_*` 声明在 `iface_registry.cr` 会在解析期报 `Undefined name`。函数不受此限制，本批 `iface_*` 全部是函数，checker.cr 未来直接调用没有问题。该约束已写进 `iface_registry.cr:21-26` 的头注，供 Task 4 直接使用。本 Task 未定义 `IP_*`，按计划归属 Task 4，且本 Task 零消费者。

### 5.3 发现，过程面：`selftest-types` 通道未挂 CI

`tests/selfhost/test_type_engine.py` 是 `selftest-types` 的唯一判据驱动，`MIN_CASES=32`，它不在 `src/ci/run.sh` 的 `selfhost-tests` 列表里。这是 P0/P1 遗留，grep 全仓只有 docs/TODO 提及。因此本批 43 个新用例不进 CI 判据，本地判据全部通过，人工可以复核。按 lead 指示“照 P0/P1 批次的做法”，没有擅自修改 `run.sh`，它也不在 Task 1 声明的 Files 内。建议挂一行 `python3 tests/selfhost/test_type_engine.py`，该测试内部已自带 `nice -n 19`。Task 7 还要在同一处挂 `test_iface_ops.py`，可以一并处理。

### 5.4 过程说明：红态没有单独跑

计划 Step 1 到 2 要求先写用例、跑出红。实现和用例在同一编辑序列实施，没有单独跑一次“无 `iface_*` 定义导致解析期失败”的构建，仓库纪律也禁止还原文件来制造红态。红的客观依据是计划侦查 §0 的 `grep -rn "iface_kind_of\|…" src/` 零命中：用例引用的 11 个符号此前不存在，任一缺失都会导致构建期 `Undefined name` 硬失败，不会软通过。用例的非真空性另由 §2 的 138/138 和 13 条目两向断言保证。

### 5.5 工作副本状态（他人改动，未触碰）

- `docs/superpowers/plans/2026-09-11-r2-p2b-iface-ops.md`：plan-p2b 的修订，包含 Task 1/2 的行文更新。本报告读的就是修订后的工作副本。
- `tests/suite/*.out` 加 `*.cr.rc`，32 对，20:52 生成，疑似另一个 agent 的语料 harness 产物。未纳入本任务提交，路径限定生效，`jj show --stat` 可以复核。

---

## 6. 证据命令速查（可复核）

```bash
# 判据 2（用例表）
nice -n 19 ./build/corec selftest-types | tail -1        # 138/138 type-engine cases passed
# 判据 3（ELF 逐字节；必须先 clean-cache 且 cwd = 仓库根）
nice -n 19 ./build/corec clean-cache && nice -n 19 ./build/corec build tests/suite/ptr_arith.cr -o /tmp/x --static && sha256sum /tmp/x
# 判据 4（.ccr 逐字节）
nice -n 19 ./build/corec clean-cache && nice -n 19 ./build/corec ccr tests/suite/ptr_arith.cr -o /tmp/y.ccr && sha256sum /tmp/y.ccr
# 判据 5/6（诊断零变化）
for f in tests/suite/*.cr; do nice -n 19 ./build/corec check "$f"; done        # 与基线 diff -r 逐字节同
nice -n 19 ./build/corec check src/compiler                                    # 仅 2 条既有 TF01（行号 +13）
# 5.1 的控制组实验（interning 导致 .ccr STR 段变化）
printf 'fn main() -> int {\n    zzz_probe_unused_ident : int = 7;\n    return 0;\n}\n' >| /tmp/probe.cr
nice -n 19 ./build/corec ccr /tmp/probe.cr -o /tmp/probe.ccr    # 解析其 STR 段：多出该串、计数 153 vs 159
```

基线取值口径：全部基线（95/95、ELF 和 `.ccr` 的冷缓存哈希、32 个语料的 check 输出、`check src/compiler` 输出）都是在本批第一个提交前，用同一构造路径加 `clean-cache` 实测取得，留档在 `/tmp/p2b1_*`，没有沿用文档中的数字。
