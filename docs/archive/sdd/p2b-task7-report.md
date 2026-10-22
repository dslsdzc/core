# R2 P2b Task 7 报告：收尾（回归 + 自举 + 收紧清单 + 文档）

Status: DONE
提交：`992c037b`（change `lmrwpyll`，父 = Task 6 `30545da7`）`docs: R2 P2b 收尾（回归 + 自举 + 收紧清单 + 文档）…`（路径限定 4 路径 = `TODO.md`(10±) · `docs/superpowers/plans/2026-09-11-r2-p3-capabilities.md`(+94) · `docs/superpowers/specs/2026-09-10-type-interface-unification-design.md`(2±) · `docs/superpowers/implementation/2026-09-10-type-shadow-findings.md`(+23)；共 127 insertions / 2 deletions；64 个 `tests/suite/*.cr.{out,rc}` 他人 scratch 未入库，实核计数 = 0）
计划：`docs/superpowers/plans/2026-09-11-r2-p2b-iface-ops.md` Task 7
概要：全量回归 46 套件 rc=0；零变化复验（ELF/`.ccr`/语料/自源/影子五面）逐字节同；自举 `corec2==corec3` + N06=0 + 冒烟 42；收紧清单 = 空（本批与反向皆零条）；P3 交接包（31 条未接线站点 + 10 项裁决点）写入 P3 计划附录 A，事实表写入 findings 第 12 节。

---

## 0. 本报告「复跑 / 继承」口径（诚实声明）

| 类别 | 内容 |
|---|---|
| 本 Task 实际运行 | ① 全量回归 46 套件（含 `selftest-types` 212/212、`test_iface_ops` 76/76）；② ELF canary 开/关影子两态；③ `.ccr` 4 档（对 base1/base5/cur 三方）；④ 21 档语料 + 自源 check 的同源双编译器对拍（base1/base5/cur 三方）；⑤ 32 档影子通道复跑（base5 vs cur）；⑥ 自举链 + N06 + 冒烟 + 构建确定性；⑦ 构建产物 sha 复核。 |
| 继承（未重跑，理由 = 同批已完成且输入未变） | ① 各任务的突变控制（T2/T3/T4/T5/T6 各自的三/四层探针实验），本 Task 空间上不可重跑（探针已撤、纪律禁还原）；② 各任务的行为探针（T4 32 例 / T5 44 例 / T6 52 例），其永久形态即 `type_selftest.cr` 的 212 例与 `test_iface_ops.py` 的 76 例，本 Task 已复跑并全部通过；③ 计划 第 5 节 记的「计划本未复测」项（ELF 基线、影子 71 文件口径），本 Task 用同源对拍取代历史数字。 |
| 基线二进制（冻结拷贝，sha 已核） | `/tmp/p2b2_base_bin/corec` = `80c1b6c7…`（T1 完成态；T1 报告实测「与 P2b 前逐字节同」因此 可以作为 pre-P2b 行为的代理）· `/tmp/p2b5_base_bin/corec` = `b3a1a6b2…`（T5 完成态 = T6 的直接前驱）。 |

为什么 base1 可作 pre-P2b 代理：Task 1 是纯建层（零消费者），T1 报告 第 2 节 判据 3/4/5 实测「ELF 逐字节同 + `.ccr` 逐字节同 + 32 语料 check 输出逐字节同」；且 T2~T6 各自与其直接前驱的对拍（同源双编译器）逐字节空 因此 传递链为 base1 == base2 == … == base5 == cur（本 Task 亲自复验了链上两端：base1 vs cur、base5 vs cur）。

---

## 1. 全量回归（计划 Step 1）

命令：`for f in tests/bootstrap/*.py tests/selfhost/*.py; do timeout 1200 nice -n 19 python3 "$f"; done`（脚本 `/tmp/p2b7_regress.sh`，摘要 `/tmp/p2b7_regress_run1/summary.txt`）

结果：46/46 rc=0（7 bootstrap + 39 selfhost）。逐套件（rc=0 全部；「判据行」= 各测试自报）：

| # | 套件（bootstrap 7） | 判据行 | # | 套件（selfhost 39） | 判据行 |
|---|---|---|---|---|---|
| 1 | test_apx_tag | 5/5 | 8 | test_agg_checks | 20/20 |
| 2 | test_borrow | 4/4 | 9 | test_agg_slots | 13/13 |
| 3 | test_dex_arith | 14/14 | 10 | test_apx_tag | 2/2 |
| 4 | test_dex_type | 3/3 | 11 | test_backend_bootstrap | PASS（stage0/1 O2 smoke=7） |
| 5 | test_generics | 3/3 | 12 | test_borrow | 7/7 |
| 6 | test_modules | PASS | 13 | test_cache_identity | 5/5 |
| 7 | test_pipeline | 29/29 | 14 | test_ccr_v7 | 27/27 |
| | | | 15 | test_compile | PASS |
| | | | 16 | test_dex_arith | 11/11 |
| | | | 17 | test_dex_type | 5/5 |
| | | | 18 | test_directory_build | PASS |
| | | | 19 | test_ent_kernel_neutrality | PASS |
| | | | 20 | test_global_init | 15/15 |
| | | | 21 | test_hit_table | 24/24 |
| | | | 22 | test_iface_ops | 76/76 |
| | | | 23 | test_impl | 7/7 |
| | | | 24 | test_interp_float | ALL PASS |
| | | | 25 | test_interp_parity | 23/23 |
| | | | 26 | test_lexer_parity | PASS |
| | | | 27 | test_live_ranges | 13/13 |
| | | | 28 | test_lsp | ALL PASS (10) |
| | | | 29-34 | test_mw_task1..6 | ALL PASS ×6 |
| | | | 35 | test_named_dedup | PASS |
| | | | 36 | test_native_float | ALL PASS |
| | | | 37 | test_native_memory | 6/6 |
| | | | 38 | test_native_strings | PASS |
| | | | 39 | test_nested_fn | 17/17 |
| | | | 40 | test_params_limit | 5/5 |
| | | | 41 | test_pointer_safety | PASS |
| | | | 42 | test_purity | PASS |
| | | | 43 | test_region_cfg | 22/22 |
| | | | 44 | test_slice_bounds | 7/7 |
| | | | 45 | test_tuple_slots | 14/14 |
| | | | 46 | test_type_engine | PASS（selftest-types 212/212） |

计数口径勘误（诚实声明）：计划/TODO #27 记「38 套件（7 + 31）」。本 Task 实测 = 46（`ls tests/bootstrap/*.py` = 7 · `ls tests/selfhost/*.py` = 39），差 8 = TODO #27 收尾时点之后的新增套件（`test_iface_ops` 本批新增 + 期间他人批次的 test_* 新增），非计划漏算。CI 挂点现状（`src/ci/run.sh` 实核）：`bootstrap-tests` 挂 3 档（pipeline/borrow/generics）、`selfhost-tests` 挂 15 档（compile/type_engine/iface_ops/purity/ccr_v7/impl/borrow/pointer_safety/params_limit/tuple_slots/agg_slots/agg_checks/nested_fn/interp_parity/cache_identity），其余 28 档（39−15 selfhost + 4 bootstrap）未挂 CI（本 Task 照原样回归，全部通过，没有自行改动挂点）。

直接命令复核：`nice -n 19 ./build/corec selftest-types | tail -1` 输出 `212/212 type-engine cases passed`（rc=0）。

---

## 2. 零变化复验（计划 Step 2）

### 2.1 ELF canary（开/关影子两态）

```bash
nice -n 19 ./build/corec clean-cache && nice -n 19 ./build/corec build tests/suite/ptr_arith.cr --static -o /tmp/p2b7_canary_noshadow && sha256sum /tmp/p2b7_canary_noshadow
nice -n 19 ./build/corec clean-cache && nice -n 19 ./build/corec build tests/suite/ptr_arith.cr --static --type-shadow -o /tmp/p2b7_canary_shadow && sha256sum /tmp/p2b7_canary_shadow
```
两态均 = `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475` IDENTICAL（= 计划定值；`--type-shadow` 下同文件同时打出摘要 `decisions=78 agree=78 … 全 0`）。

### 2.2 `.ccr` 实测（冷缓存；三方对拍）

先 `clean-cache`，再 `ccr`，最后取 sha256，每档各跑 base1 / base5 / cur 三个二进制（脚本 `/tmp/p2b7_dual.sh`）：

| 语料 | sha256（三方逐一相同） |
|---|---|
| ptr_arith | `ecd7a9dfd557810651d9f4a31bf5775556b5c15518fb0a9dbacb56af83dcd29d` |
| at_test_struct | `891377232b5b9eeb99abc19e4581d779c108a84f965043826c1b65b2e6218f08` |
| generics_test | `35cf0f261c1bd052d69d660bf0c2c148a4bef815eccab48ee5e13fd2adbf5d23` |
| dyn_test | `dfb82d2b873cc3c90b62a89edbf4f809b197a092cc3946f8216f2bccbba1626f` |

因此 `.ccr` 变更面 = 空（四档与 T1~T6 报告值逐字一致，跨批可比；注册表「不 alloc `g_types` 行」的设计兑现）。

### 2.3 同源双编译器对拍（语料 + 自源 + 影子）

方法：同一份当前源码/语料，分别喂 旧二进制与新二进制 因此 两侧输入逐字节相同 因此 差异只可能来自编译器行为（`clean-cache`；cwd = 仓库根）。

| 面 | base1（≈pre-P2b）× 新源 vs cur × 新源 | base5（直接前驱）× 新源 vs cur × 新源 |
|---|---|---|
| 21 档 `tests/suite/*.cr`（非 mini 非空）`check` 的 stdout+stderr+rc | `diff -r` 空 | `diff -r` 空 |
| 自源 `check src/compiler` | `cmp` IDENTICAL（rc=1；恰 2 条既有 TF01，见 第 3 节） | `cmp` IDENTICAL |
| 32 档影子通道（`check --type-shadow --type-shadow-dump`，逐档 clean-cache） | —（本 Task 用 base5 作对照） | `diff -r` 空（含 dump 全文） |

影子聚合（base5 与 cur 双侧同值）：`decisions=2826 agree=2826 old_stricter=0 old_looser=0 unknown=0 unknown_bridge=0 unknown_engine=0 unknown_engine_uncovered=0 unknown_engine_budget=0 replace_bridge=0 replace_unknown=0`；站点直方图 `assign-node=1816 fn-body-ret=778 if-branch=222 struct-field-type=4 array-elem-type=4 generic-apply-base=2`（其余 4 站点 0），与 T4/T5/T6 报告逐项相同。（30/32 档有摘要行，2 档为空文件；T4~T6 口径同。）

---

## 3. 既有 red 复确认（「2 条 TF01 非本批引入」）

`check src/compiler` 输出（stdout）两编译器在同一份源上逐字节相同，内容恰 2 条：

```
error[TF01]: Function return type mismatch --> 9383:1 | fn lits_copy(p: int) -> int {
error[TF01]: Function return type mismatch --> 9498:1 | fn ty_memo_slot_no_grow(a: int, b: int) -> int {
```
- 行号 9383/9498 = T6 报告值（`checker.cr` 净增 +10 后）；`ty_shadow.cr:118` 已登记为既有误报（loop 落空面）。
- pre-existing 的直接证据：base1（T1 二进制，≈ P2b 前行为）跑同一份当前源的输出与 cur 逐字节相同 因此 这 2 条不是本批任何改动引入，也不是本批修复对象。
- 两段自举 build log（corec2/corec3 编译 `main.cr`）同样各含这 2 条 TF01，无新增/无消失（见 第 4 节）。

---

## 4. 自举链 + 冒烟 + 构建确定性（计划 Step 3）

```bash
nice -n 19 env CI_JOB_NAME=full-bootstrap bash src/ci/run.sh   # rc=0
cmp /tmp/corec2 /tmp/corec3                                     # IDENTICAL
nice -n 19 ./build/corec run 'fn main() -> int { return 42; }'   # rc=42
```

| 判据 | 结果 |
|---|---|
| `build_selfhost_native.py` 三守卫 | `[GUARD] corec/corearch/corelsp: build log clean (error[ = 0, undefined = 0)` ×3；`=== BUILD SUCCESS ===` |
| `cmp /tmp/corec2 /tmp/corec3` | IDENTICAL；共 sha `c201916d3fa03338f76e1aebb270a78304c6a91329b7e4e0f6efe60e1a2ba7d9`（= T6 报告值，跨批可复现） |
| N06 = 0 | `grep -c 'error\[N06\]' /tmp/p2b7_bootstrap.log` = 0（两段 build log 全文 1801 行，零命中） |
| `--help` | run.sh rc=0 内含 `--help \|\| [ $? -eq 1 ]` 判据通过 |
| 冒烟 | rc=42 |
| 构建确定性 | `build/corec` 重建后 sha = `8f69e346…858b`（与重建前逐字节同；= T6 报告 post-change 值）；`build/corearch` = `31d70900…5e39`（未动） |

---

## 5. 收紧清单（计划 Step 4）：= 空

- 本批「旧接受到新拒绝」= 零条；反向「旧拒绝到新接受」= 零条。
- 证据方法（计划指定口径）：旧二进制 × 新源 vs 新二进制 × 新源，① 21 档语料 `check` 输出（stdout+stderr+rc）逐字节同；② 自源 `check src/compiler` 逐字节同；③ 32 档影子通道逐字节同；④ 4 档 `.ccr` 三方同；⑤ ELF canary 开/关两态同。旧侧取 base1（T1 完成态 = pre-P2b 行为代理，传递链见 第 0 节）与 base5（直接前驱）双基准。
- 与任务侧台账一致：T4/T5/T6 各自报「收紧清单 = 空」且各自与前一任务基线同源对拍空，本 Task 在批级上把链的两端亲自复验（base1↔cur、base5↔cur），故「空」不是逐任务声明的简单叠加。
- 为什么预期为空（结构性）：表的每一格 = 现状代码逐格转录（格注现状 `file:line`）；且本批 36 个候选站点中仅 5 个门可零行为变化接线（读表 = 同判定的寻址替换）。未接线站点逐条实测理由见 第 6 节。

---

## 6. P3 交接包（本 Task 最有价值产出；计划 Step 5 + lead 加码）

落点选择（已声明）：① P3 计划新增「附录 A：R2 P2b 交接包」（`docs/superpowers/plans/2026-09-11-r2-p3-capabilities.md`，+94 行），主实现方式（P3 实施者的第一读物；且在该计划「与 P2b 的交接面」节就地加了重定注释：交接契约 ① `iface_satisfies` 未交付、条目无变型字段 因此 Task 2/6 开工前先补）；② findings 文档新增第 12 节「P2b 后：公理区事实表」（+23 行），计划 Step 5 指定的九条宽松面落格记录。

附录 A 内容（dense 表 + file:line）：
- A.1 已接线面（P3 的「已就位」清单）：字面量定型 5 处 `checker.cr:1906/1908/1909/1910/1911` · 算术门 `:1969` · 逻辑门 `:1984` · `if` 门 `:2298` · `while` 门 `:2411` · 索引后备门 `:2678` · TY 到 TI 单表 8 站点（`:742/:1397/:1063/:1089/:1146/:1682/:1737/:2159` 对应 `iface_registry.cr:259-270`）。
- A.2 未接线站点台账 31 条（= T4 的 14 + T5 的 17），逐条：站点行号（P2b 末，报告接线前的行号）· 现状语义 · 不接线的实测理由 · P3 动作。理由三分类：结果规则 / 无拒绝路径 / 谓词非类级位 ，全部有探针或全行枚举或突变实证支持（引用 T4/T5 报告节号）。
- A.3 P3 裁决点 10 项：① `iface_satisfies` 未交付（P3 先补）② `name_ni=-1`（.ccr STR 段约束，首个消费者裁决）③ `TY_DEX_S` 不入表 ④ `never` 调用位点=unit 而类型位点=never（插桩实测可达）⑤ 「全许可列」11 位 × 13 类（比较 6 / 一元 4 / 转换 1）⑥ 字段·转换面无拒绝路径 ⑦ dyn 逐行谓词 + 位图 64 上限 ⑧ 索引侧缺「须 int」位 ⑨ 枚举域无 `AK_SUM`/`AK_FN` 条目（Task 3/4 走桥接展开，勿查注册表）⑩ 性能面（13 条线性扫；扩到热路径前先看编译耗时）。
  - 勘误一（计数）：lead 简报记「20 个全许可列站点」，无法复现；实测 = 11 个 op 位 × 13 类 = 143 格，未接线站点合计 31（已写入 A.3-⑤，逐条见 A.2）。
- A.4 表结构事实：40B × 5 字段布局 · 位下标约定（`OP_*` 直用 / `UOP_*`+20 / `IP_*`=25..31）与「`IP_*` 必须落 `globals.cr`」的声明序约束 · 三态纪律 · 初始化挂点与「不得 `str_intern`」 · 桥接单源化边界（`sh_native_ak(TI_DYN) == -1`） · 单表码 7 撞车格与 `TY_DEX_S` 归 P4/P5 · AK↔TI 语义分派守卫。
- A.5 指 findings 第 12 节。
- findings 第 12 节：从九条宽松面到表中格、现状诊断（全部行为探针来源）、P2b 处置、P3 收紧建议（10 行表：比较/算术门/串拼接/一元/解引用/索引类型/字段落空/转换/dyn/range 索引）+ 收紧清单=空声明与证据。

---

## 7. 文档（计划 Step 6）

| 文档 | 改动 |
|---|---|
| `docs/superpowers/plans/2026-09-11-r2-p3-capabilities.md` | 「与 P2b 的交接面」加契约重定注（`iface_satisfies` 未交付等）+ 新增附录 A（94 行） |
| `docs/superpowers/implementation/2026-09-10-type-shadow-findings.md` | 新增第 12 节「P2b 后：公理区事实表」（23 行） |
| `docs/superpowers/specs/2026-09-10-type-interface-unification-design.md` | 第 9 节 P2 行 (b) 标为已实施（落点/提交链七提交/判据/未覆盖面/P5 继承项），照 P0/P1/P2a 行的格式 |
| `TODO.md` | 新增 #30「R2 P2b 实施」（落点 / 提交链七提交 / 判据兑现 / P3 交接指针 / 未覆盖面 / P5 继承项）；#24 末行「P2b 待办」划销并转指 #30；另记 CI 挂点现状（selfhost-tests 15 档含 `test_type_engine.py`（212 例）与 `test_iface_ops.py`（76 例），前者此前 P0/P1/P2a 一路漏挂，本批补挂） |

---

## 8. 偏差 / concerns（需 lead 过目）

1. 计数勘误（计划数字）：计划 Task 7 Step 1 记「38 套件（7 bootstrap + 31 selfhost）」，实测 46（39 selfhost，差 8 = 期间新增）。本报告一律用实测值；未改计划文件正文（plan-p2b 已收尾，改动面收敛在 TODO/spec/附录）。
2. lead 简报的「20 个全许可列站点」不可复现，实测 11 位/143 格（见第 6 节勘误一）。若该「20」指别的口径（如 18+18 候选站点或某报告行数），请指出，我可回填；当前以实测口径写入交接包。
3. 未挂 CI 的 28 档：本 Task 只做回归（全部通过），未扩 CI 挂点（计划未授权、且扩挂点会改 `run.sh` 判据面）。建议单开一条「测试挂点补全」条目（Bootstrap 侧 4 档 + selfhost 侧 24 档）。注：本批新挂的两处（type_engine/iface_ops）是计划 Step 6 明列的，已挂。
4. 继承而非复跑的项：突变控制与三组行为探针（T4/T5/T6）未重跑（探针已撤、纪律禁还原），其永久形态（selftest 212 + iface_ops 76）已由本 Task 复跑并全部通过，覆盖了该面；如需批级突变复验，须重开探针（建议留给 P3 首任务，照 T6 的三层法）。
5. `tests/suite/*.cr.{out,rc}`（64 个他人 scratch）仍在工作副本（未删、未入库；路径限定可核）。建议由创建者处置或另立清理条目（删需许可）。
6. 交接面重定属「实质性」改动：P3 计划原文的交接契约 ① 要求 `iface_satisfies`，P2b 未交付（范围明标零调用者）。附录 A 与交接面注均已写明「P3 Task 2/6 开工前先补」，若 lead 期望 P2b 收口前补出该 API，需另开任务（本 Task 范围 = 收尾，未扩面）。

---

## 9. 证据命令速查（可复核）

```bash
# 第 1 节 全量回归（46 套件）
bash /tmp/p2b7_regress.sh run1 && cat /tmp/p2b7_regress_run1/summary.txt
nice -n 19 ./build/corec selftest-types | tail -1            # 212/212
nice -n 19 python3 tests/selfhost/test_iface_ops.py | tail -1 # 76/76
# 第 2.1 节 ELF canary 开/关两态（cwd = 仓库根）
nice -n 19 ./build/corec clean-cache && nice -n 19 ./build/corec build tests/suite/ptr_arith.cr --static -o /tmp/x && sha256sum /tmp/x
nice -n 19 ./build/corec clean-cache && nice -n 19 ./build/corec build tests/suite/ptr_arith.cr --static --type-shadow -o /tmp/y && sha256sum /tmp/y
# 第 2.2 节/2.3 同源双编译器对拍（$1=二进制 $2=落盘目录）
bash /tmp/p2b7_dual.sh /tmp/p2b2_base_bin/corec /tmp/p2b7_base1
bash /tmp/p2b7_dual.sh /tmp/p2b5_base_bin/corec /tmp/p2b7_base5
bash /tmp/p2b7_dual.sh ./build/corec              /tmp/p2b7_cur
diff -r /tmp/p2b7_base1/corpus /tmp/p2b7_cur/corpus && echo EMPTY
diff -r /tmp/p2b7_base5/corpus /tmp/p2b7_cur/corpus && echo EMPTY
cmp /tmp/p2b7_base1/compiler.out /tmp/p2b7_cur/compiler.out   # IDENTICAL（自源）
sha256sum /tmp/p2b7_{base1,base5,cur}/ccr/*.ccr              # 三方逐文件同
# 第 2.3 节 影子通道（$1=二进制 $2=落盘目录）
bash /tmp/p2b7_shadow.sh /tmp/p2b5_base_bin/corec /tmp/p2b7_shadow_base5
bash /tmp/p2b7_shadow.sh ./build/corec              /tmp/p2b7_shadow_cur
diff -r /tmp/p2b7_shadow_base5 /tmp/p2b7_shadow_cur && echo IDENTICAL
# 第 4 节 自举链 + 冒烟
nice -n 19 env CI_JOB_NAME=full-bootstrap bash src/ci/run.sh >| /tmp/p2b7_bootstrap.log 2>&1; echo rc=$?
grep -c 'error\[N06\]' /tmp/p2b7_bootstrap.log      # 0
cmp /tmp/corec2 /tmp/corec3 && sha256sum /tmp/corec2  # IDENTICAL c201916d…
nice -n 19 ./build/corec run 'fn main() -> int { return 42; }'; echo rc=$?   # 42
sha256sum build/corec build/corearch                  # 8f69e346… / 31d70900…
```

提交链（完整 P2b）：`7f520dce`(T1)、`31143cd0`(T2)、`9b15fd2a`(测试挂 CI)、`6d2790cd`(T3)、`a99ee825`(T4)、`7145eea5`(T5)、`30545da7`(T6)、`992c037b`(T7 本报告)。
