# R2 P4 Task 2 报告：TYPE 段内容，类型行表、类型项 DAG、确定性装填和 corearch 读回

日期：2026-09-13。基线：`97febdbf`，P4 Task 1 收尾，`.ccr` v8 加 TYPE(7)/IFACE(8) 空壳。
任务：计划 `docs/superpowers/plans/2026-09-12-r2-p4-carrier.md` 的 Task 2，按 D12（两小节布局）、D13（确定性装填）、D18（段内容构造与序列化解耦）实施。
口径：所有命令 `nice -n 19`，cwd 为仓库根，一次构建一次编译串行，任何 `.ccr` 或缓存态比较前先 `clean-cache`。数字为本轮实跑，例外逐条标注。

---

## 0. 交付摘要

| 项 | 结果 |
|---|---|
| TYPE(7) 段体 | `[row_count u32][row×24B{kind,data,extra} i64×3][term_count u32][term×40B{tag,a..d} i64×5]`；哈希不落盘，加载侧用 `tt_hash5` 重算 |
| 写侧 | 新增 corec-only 的 `src/compiler/ccr_types.cr`（D13 装填、段体缓冲、corec dump 节）；`save_ccr` 只搬运 `g_ccr_type_seg`（D18） |
| 读侧（corearch） | `load_ccr` 解析后重建 `g_types` 行表、`g_type_terms` 项表、`g_tt_index`（用 `grow_tt_index` 到 `tt_reindex` 重放）；逐条不变量违规即整体拒绝 |
| 清单 | `corearch_files` 增加 `type_terms.cr`（在 ccr_io 之前，保证常量可见）；`corec_files` 增加 `ccr_types.cr`；双注册面 `_import.cr` 两处加 `tests/selfhost/test_compile.py` 清单同步，后者由全枚举捕获，见 §9-① |
| 读回证据 | `corec ccr --dump-types` 与 `corearch --dump-types` 使用同一条打印路径：rows/terms/probe 逐行相同，这是核心判据。probe 是 `tt_norm`/`tt_is_dnf`/`tt_is_literal` 在重建表上逐点同值，下标包含新建项，实证索引重建和去重行为 |
| 确定性 | 冷/冷两次编译 TYPE 段逐字节相同；in-process 纯函数性，即判定历史扰动后重新装填仍逐字节相同，已加入 `selftest-types` 用例；冷/热分语料拆解见 §8，其中有一处与计划预测相反 |
| `selftest-types` | 338/338（333 加 5：装填、roundtrip、dedup、确定性、拒绝面） |
| `test_ccr_types.py` | 19/19（T1 机制面 9 例重定，T2 内容面新增 10 例） |
| ELF canary | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`，IDENTICAL，发射面零泄漏 |
| `.ccr` 新记录值（冷缓存） | `ptr_arith` 89859B `0f744675…`（TYPE 888B / rows 15 / terms 13）、`generics_test` 133698B `8380c393…`（TYPE 2696B / 42 / 42）、自源 `src/compiler/_import.cr` 9942142B `3219971f…`（TYPE 1736B / 27 / 27） |
| 全枚举 | 46/46 selfhost 加 7/7 bootstrap，全部 rc=0。第三轮为最终二进制；首轮暴露 2 处清单变化，已修 |
| 提交 | `3d604e11`（change `nqrptwut`），路径限定 16 个文件，见 §10 |

---

## 1. 段布局（D12；实现权威为 `ccr_io.cr` 头注释）

```
TYPE(7) 段体（小端；i64 = 8B/字段——与内存 g_types/g_type_terms 槽逐位同源，无截断面）：
  [row_count u32]
  [row_count × 24B {kind, data, extra}]        ← g_types 0..g_type_count-1 原样
  [term_count u32]
  [term_count × 40B {tag, a, b, c, d}]         ← 项 DAG；索引 = 项行号；**哈希不落盘**
```

偏差登记 1 处，显式说明：T1 空壳期注释写“段体缓冲 = 4 + 缓冲长度”，缓冲不含计数。本实施取“缓冲 = 完整段体”，包含首字段 `row_count`。取后者后 `ccr_type_seg_size()` 等于 `g_ccr_type_seg_len`，单一来源，没有计数和长度两个真源。注释和 spec §3.7 已同步；`g_ccr_type_seg` 的两个声明在 `globals.cr`，必须在双 concat 共享面。如果放在 corec-only 文件，corearch 侧的 `ccr_io.cr` 引用会报 N06。

字段宽度勘误：spec §3.7 的 Task 1 文段写 `{kind i32, data i32, extra i32}`，与自身字节数 24B 自相矛盾。实施权威为 8B 字段，3×8=24、5×8=40，与内存槽同宽。spec 和 `ccr_io.cr` 头注释已同批改正。

---

## 2. Step 1：用例

`tests/selfhost/test_ccr_types.py` 新增 10 例，计划下限为 8 例；T1 的 5 例按新现实重定：

| 序号 | 用例 | 覆盖面 |
|---|---|---|
| ⑦ | `test_p4t2_type_segment_layout` | 两小节计数和长度自洽，行走完等于段体长；原生行块形态；项域检查（tag 在 0..10、a..d 大于等于 -1、引用槽小于自身行号） |
| ⑧ | `test_p4t2_rows_and_terms_match_corec_dump` | 段内行表和项表等于 corec 内存真值，验证内存到缓冲到文件的保真链；rowterm 节与行表同长 |
| ⑨ | `test_p4t2_corearch_readback_parity` | 读回对拍：corearch dump 等于 corec dump（rows/terms/probe 逐行），rowterm 节只有写侧有 |
| ⑩ | `test_p4t2_dag_dedup_topology` | DAG 语义（ptr_arith）：没有同 (tag,a..d) 的重行；引用槽拓扑正确；dedup 实证，至少 2 行命中同一项 |
| ⑪ | `test_p4t2_dump_flag_zero_artifact_effect` | `--dump-types` 零产物影响，带和不带 flag 的 .ccr 逐字节相同，probe 建项不泄入序列化面 |
| ⑫-a | `test_p4t2_loader_rejects_topology_violation` | 自引用、前向引用、远越界引用逐个拒绝 |
| ⑬ | `test_p4t2_loader_accepts_annotation_slot` | ATOM 的 b 为 5000 时接受且 dump 原样打印，防止假校验实现；负控是同值放入 CONS 引用槽必须拒绝 |
| ⑫-b | `test_p4t2_loader_rejects_count_and_truncation` | term_count 加 1、row_count 加 1、行表尾截断（段表 offset 同步重排）、尾插 4B 垃圾，逐个拒绝 |
| ⑭ | `test_p4t2_determinism_cold_cold` | 同源两次冷缓存编译，TYPE 段逐字节相同，整个 .ccr 也逐字节相同 |
| ⑮ | `test_p4t2_cold_warm_type_segment` | 冷/热分语料：缓存不变量语料的 TYPE 相同；ptr_arith 热态行表等于冷态前缀，项表和 probe 相同，SYM 悬挂引用量化见 §8 |
| ①②⑥⑧⑨（T1 例重定） |  | TYPE 从“空壳 4B”改为“内容面非空加两小节自洽”；IFACE 仍为空壳；T1 的冷/热用例加入 TYPE 段 |

红态纪律说明：本任务的实现和用例在同一提交，10 个用例首轮即通过，没有独立红态证据。用例的有效性由突变控制承担，见 §9-④，使用 /tmp 突变构建，仓库文件零改动，遵守纪律 #3。

---

## 3. Step 2：实现（corec 侧，新建 `src/compiler/ccr_types.cr`）

```
fn ccr_type_populate() -> int     // D13：项层复位（含引擎预算/memo/lits）→ 桥接复位
                                  //      → 按行序 0..g_type_count-1 装填（sh_term_of_ti；
                                  //        <0 ⇒ 诊断 + 拒绝 = save 拒落盘）
fn ccr_type_seg_build() -> int    // 段体缓冲（D12 布局）→ g_ccr_type_seg/_len
fn ccr_type_prepare_save() -> int // 两调用点单入口（populate → build）
fn ccr_type_selftest_dump()       // 共享 dump（ccr_io）+ corec-only rowterm 节
```

前置核查，计划 Step 2 指定，逐站点核对成立。`save_ccr` 有两处调用点：`main.cr:612` 的 `ccr` 分支，其后只有 `--dump-types` 打印和 `return 0`；`main.cr:636` 的 `build` 分支，其后只有拼 corearch 命令行并 `syscall` 执行子进程。`sh_finish`（影子摘要）在 `run_frontend()` 之后、本函数之前，因此 populate 之后没有类型项消费者，项层复位不成问题。

复位面（D13）：`tt_layer_reset()` 在 `type_terms.cr` 的共享层新增，包含项表计数、索引、惰性 memo，以及引擎面（steps/budget/exhausted/uncovered、memo 表和 cap、lits 计数，直接写全局，理由见下），还有桥接层 `sh_map_reset()`/`sh_unf_map_reset()`（corec-only）。

登记：计划 Task 2 ③ 的空转。接口签名项装填和 `iface_shape_builtin_init()` 形状重注册属于 Task 3，本任务空转，重置面零变化。

偏差登记，引擎面复位位置：`ty_budget_reset`/`ty_lits_reset` 在 `type_engine.cr`，不进入 corearch 清单，原因见 §9-② 的 TF01 边界。因此其等价复位以直写全局的形式落在 `tt_layer_reset()`，共享层可以在 corearch 侧调用。语义等价，覆盖 steps/budget/exhausted/uncovered、memo ok 加 cap（照该函数 N1 修复注记）、lits count，逐项对照已核。

---

## 4. Step 3：loader（`ccr_io.cr`）

解析后重建，唯一复位点是 `g_type_count = 0; tt_layer_reset()`。行表用 `grow_types` 加逐行 3 字段，然后设置 `g_type_count`；项表用 `grow_type_terms` 加逐行 5 字段、`tt_hash5` 重算、计数递增；再用 `grow_tt_index(count+1)`，cap 已清零，必定走 `tt_reindex` 重放。

逐条不变量，违规即 `return -1` 整体拒绝，遵守三态纪律：

① 计数和长度自洽，`count × 记录尺寸 ≤ 段余量`，逐记录用 `ccr_has_bytes` 双保险。
② 段体恰好两小节，行走完等于 `seg_end7`，尾随字节拒绝。
③ `tag` 在 0..10（TT_*）；`a..d` 大于等于 -1。
④ 子项引用拓扑：`-1` 或小于自身行号。字段表按 tag 分派，使用 `ccr_type_term_ref_ok`。`UNION/INTER/CONS` 检查 a、b；`NOT` 检查 a；`MU` 检查 b（a 是绑定变量）；`ATOM` 检查 c（参数链头，a 是 ak，b 是标注）；`BOT/TOP/TOP_NIL` 没有引用槽；`TOP_K/VAR` 的 a 是标注。

ATOM 的 b 不检查。它可能是自类型行号、固定性位、令牌值、mut 标记，可达数千，`sh_ref_mut_marker`/`sh_name_token`/`sh_seq_term` 三个构造点都有这种语义。用例 ⑬ 就是防止假校验的守门。

IFACE(8) 空壳校验保留，Task 3 实施时退役。T1 的 Concern ② 已收口：TYPE 侧的检查从“非空即拒”改为上述不变量，save 和 load 同批实施，自产物不再被自己拒绝。

---

## 5. Step 4：corearch 面

- 清单：在 `backend_support_files` 头部和 `src/targets/x86_64-linux/_import.cr` 同批插入 `type_terms.cr`，位置在 `ccr_io.cr` 之前，保证常量可见：`ESZ_TYPE_TERM`/`ESZ_TYPE_TERM_DISK`/`OFF_TT_*`/`TT_*`。
- `--dump-types`（corearch，`corearch.cr`，照 `--dump-objects` 先例；load 后、`build_linear_schedule` 前返回 0），与 corec 侧 `ccr --dump-types` 使用同一条打印路径 `ccr_io.cr:ccr_type_surface_dump`，跨进程行格式没有分歧。
- 行格式契约（`tests/selfhost/test_ccr_types.py:parse_type_dump`）：`rows: N`、`row i kind K data D extra E`、`terms: M`、`term i tag T a A b B c C d D`、`probe: n N norm_ok X norm_unknown Y dnf_ok Z lit_ok W exhausted E digest H`，corec-only 还有 `rowterms: N` 和 `rowterm i T`。

读回证据是判据 5 的实物，见 §6-#5：三方逐字段对拍，Python 直解段字节、corec 内存 dump、corearch 载入重建 dump，probe 摘要跨进程同值。

---

## 6. 判据（逐条：命令与结果）

| 序号 | 判据 | 命令 | 结果 |
|---|---|---|---|
| 1 | 三个二进制构建 | `nice -n 19 python3 build_selfhost_native.py` | rc=0；GUARD 显示 corec 45 文件、corearch 31（增加 type_terms.cr）、target 3、corelsp 31；三条 `build log clean (error[ = 0, undefined = 0)` |
| 2 | project-mode 守卫 | `nice -n 19 python3 tests/selfhost/test_backend_bootstrap.py` | rc=0，stage1 等于 stage2 等于 stage3 逐字节同，各 stage 冒烟 7 |
| 3 | 类型引擎自测 | `nice -n 19 ./build/corec selftest-types` | 338/338，增加 5 例 |
| 4 | ELF canary | `clean-cache`，然后 `build tests/suite/ptr_arith.cr -o /tmp/… --static`，再 sha256 | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`，IDENTICAL |
| 5 | 读回证据 | `corec ccr FILE --dump-types` 对比 `corearch FILE.ccr --dump-types` 对比 Python 直解段字节 | rows/terms/probe 逐行相同。ptr_arith 15 行、13 项；probe `n 13 … digest` 两侧同值；Python 直解与两侧 dump 逐字段相同 |
| 6 | 结构性断言套件 | `test_ccr_types.py` / `test_ccr_v7.py` / `test_region_cfg.py` / `test_cache_identity.py` | 19/19、27/27、22/22、5/5 |
| 7 | 全枚举 | `bash /tmp/p4t2/enumerate.sh`，tests/selfhost 46 档加 tests/bootstrap 7 档 | 53/53 全部 rc=0，两轮。首轮暴露 2 处清单变化，见 §9-①，修复后第二轮全绿，定稿后第三轮复跑全绿 |
| 8 | 自举链 | `full-bootstrap` job，然后 `cmp /tmp/corec2 /tmp/corec3`、N06、冒烟、`--help` | 见 §6 附表 |
| 9 | 五个 CI job | `CI_JOB_NAME=<j> bash src/ci/run.sh` 共 5 次 | 见 §6 附表 |
| 10 | report-only（新拒绝面全语料） | 56 档 `corec ccr` 加 `corearch --dump-types`（tests/suite、examples、src/stdlib、自源） | 失败集与 pre-T1 基线逐条相同，共 10 档，全部是既有问题：0 字节文件、parse 错、重复定义、嵌套 fn、热态既有崩溃。因此新拒绝面零命中 |
| 11 | 冷/冷确定性 | `test_p4t2_determinism_cold_cold` | TYPE 段和整个 .ccr 逐字节相同 |
| 12 | 冷/热（分语料） | `test_p4t2_cold_warm_type_segment` 加实测量化 | 见 §8 |
| 13 | 同源对拍（check 面） | `bash /tmp/p3t0_run.sh check`，分别用 pre-T1 基线 `c05df756…` 和新二进制，然后 diff 输出 | 差异为空，78 行逐行相同；rc 分布两侧相同，33 个 0、39 个 1 |
| 14 | 影子对拍（判定面零变化） | `bash /tmp/p3t0_run.sh shadow`，同上 | 输出 diff 为空，`decisions=31270 agree=31270`，两侧同值；全部计数为 0；`logs` 的 `diff -r` 为空，`dumps` 的 `diff -r` 为空；站点覆盖两侧同报：`assign-node=23637 · fn-body-ret=5604 · if-branch=1995 · struct-field-type=28 · array-elem-type=4 · generic-apply-base=2`，总和 31270 等于 decisions。继承声明：影子通道对实现方式面零覆盖 |
| 15 | 变异控制（有效性） | /tmp 突变构建，仓库零改动 | 见 §9-④ |

CI job 附表，命令为 `CI_JOB_NAME=<j> bash src/ci/run.sh`：

| job | rc | 结果 |
|---|---|---|
| `check` | 1 | 既有 red 划界保持：`build_selfhost` 全绿，`corec check src/compiler` 恰好 2 条 `error[TF01]`，分别是 `lits_copy`（真类型洗白）和 `ty_memo_slot_no_grow`（loop 落空误报）。同一对诊断的行号 10236/10459 相对 T1 的 10162/10385 前移，原因是本批在册文件行数变化，属于行号变化而非诊断增减。同源对拍（§6-#13）两侧输出 diff 为空，划界成立 |
| `suite` | 0 | 21 档 build+run 全部通过（ALL PASS）。本批新增的 save/load 面在全部 suite 语料上往返正常 |
| `full-bootstrap` | 0 | `corec2 == corec3`，`cmp` IDENTICAL，两个 2592598B 文件 sha 为 `308d93d8…`；N06/undefined 标记为 0，日志中 `undefined = 0` 出现 3 次；冒烟 `run 'fn main()->int{return 42;}'` rc=42，corec 和 corec2 双通道；`corec3 --help` rc=1 |
| `bootstrap-tests` / `selfhost-tests` | 未单跑 | 执行体是 tests/bootstrap 3 档加 tests/selfhost 全部档，已由全枚举（§6-#7，53/53）和四套件逐一覆盖。job 级差异只有每个 job 前置的 `build_selfhost`，已多次复跑。口径登记，T7 收尾按五个 job 全跑 |

判据对最终二进制的有效性：定稿后唯一的源码改动是 `ts_ccr_run` 内的确定性夹具，只有 `selftest-types` 路径可达。`ts_ccr_purity_ok` 只被 `ts_ccr_run` 和 `type_selftest_run` 调用，编译和发射路径零差异。在其上复跑的是 `selftest-types` 338/338、ELF canary IDENTICAL、`test_ccr_types` 19/19、全枚举第三轮（§6-#7）。

---

## 7. 尺寸实测报告（计划 Step 5 指定，不用估算代替）

| 语料 | `.ccr` 尺寸 | sha256（冷缓存） | TYPE 段尺寸 | `g_type_count`（行） | `tt_count`（项） |
|---|---|---|---|---|---|
| `tests/suite/ptr_arith.cr` | 89859B | `0f744675639f369059c22ae8d0f4253b68592d54c2f7c3e1485f3cdd53139edd` | 888B | 15 | 13 |
| `tests/suite/generics_test.cr` | 133698B | `8380c3930cd4fd353a878c7318fe477b0391a60a50308645e1aedd5eac66e9b2` | 2696B | 42 | 42 |
| 自源 `src/compiler/_import.cr` | 9942142B | `3219971ffb93bfeb9750a384db4d5285d1e14dbdf5295c8e614d34a42b6ce23c` | 1736B | 27 | 27 |

旧值是 T1 记录：`ptr_arith` 88975B `15645387…`，`generics_test` 131006B `f2e566b6…`。差值为 +884B 和 +2692B，等于 TYPE 段实内容减去 4B 空壳，即 rows×24 加 terms×40 加 4。

风险面①，`.ccr` 尺寸增长实测：TYPE 段占比不超过 0.02%，自源为 1736B/9.9MB，远低于“自源翻倍”的上报阈值，不需要启用 D12 的“只落引用闭包”替代面。

`generics_test` 的 TYPE 尺寸和行数为 42/42，比自源更大，符合预期。`g_types` 行数等于命名类型数加 ir_gen 期数组/指针行，与源文件大小无关。自源代码以平铺全局和字节缓冲为主，命名类型只有 18 个。冷/热行数拆解见 §8。

---

## 8. 确定性（D13 的实测结果，含一处与计划预测相反）

三种证据，逐条说明。

① in-process 纯函数性，D13 的核心承诺，成立。`selftest-types` 的 `ct.seg_determinism` 用例做装填、建缓冲、判定历史扰动（`ty_sub`/`ty_disjoint`/`ty_equiv` 触发 NNF/DNF 规范化并向项表追加新项）、重新装填，段体逐字节相同。“直接序列化活表”的旧实现必然在这里变化，该用例就是 D13 的有效性证明。

② 冷/冷确定性，成立。同源两次冷缓存编译，TYPE 段和整个 `.ccr` 逐字节相同，用例 ⑭。

③ 冷/热两态。计划预测“TYPE 段逐字节相同”，实测只有一半成立，根因在外，已量化：

| 语料 | 冷 rows/terms | 热 rows/terms | TYPE 段 | 结论 |
|---|---|---|---|---|
| `add/main`（夹具语料） | 9 / 9 | 9 / 9 | 逐字节同 | 缓存不变量语料，D13 守门成立（用例 ⑮-①） |
| `generics_test`（含泛型，缓存整体关闭） | 42 / 42 | 42 / 42 | 逐字节同，整个 `.ccr` 同 | 同上 |
| `ptr_arith` | 15 / 13 | 12 / 13 | 差 72B，3 行 | 行表分歧，项表和 probe 同值 |

`ptr_arith` 分歧的实测根因，已量化：

- 热态行表是冷态行表的前缀，`rw_rows == rc_rows[:len(rw_rows)]`，用例 ⑮-② 断言。
- 项表逐位相同，13/13；probe 摘要逐位相同。因此 D13 承诺的“段内容等于类型表纯函数”在项面上完全成立。
- 差异来自冷路径 ir_gen 期 `alloc_type` 新增的 3 行：`[int;5]` 数组行和 2 个 `*int` 指针行，来自 `&arr[2]` 和 `&x`。`.cir` 缓存命中路径跳过 `ir_gen_func`，这些行不会重建。含泛型的文件整体关闭 `cache_enabled`，所以泛型语料没有这个分歧。
- 连带发现，既有实现方式自洽缺口，本任务暴露并量化：热态 `.ccr` 的 SYM 段有 6 处类型行引用指向大于等于热态行数的编号，即 12/13/14，这些行冷态存在、热态缺席；冷态为 0 处。两侧引用都不出冷态行表，用例 ⑮ 断言，悬挂只是“缺后缀行”造成的。根因同上，缓存路径跳过行分配，属于 TODO #5 末条“冷/热 `.ccr` 分歧未修”家族。本任务不修，因为修它要改 `.cir` 缓存语义或行分配时点，超出 D12/D13 范围；强行在 loader 拒绝会让暖态构建整类失败，属于新硬错误，必须先 report-only 并由维护者裁决。

计划文本偏差，显式登记：plan Global Constraints 写“TYPE 段内容由 D13 保证为纯函数，因此冷/热两态 `ptr_arith` 的 TYPE 段应逐字节同”。前半句成立，项面已证；后半句在行面不成立。行表本身的冷/热分歧是前端行分配的既有性质，D13 的复位面管不到。实测已量化并锁进用例 ⑮。该用例断言实际成立的不变量：前缀关系、项表和 probe 同值、引用域不出冷态表，并把悬挂计数打印到日志。如果未来行分配修好，前缀断言仍然成立，用例不会假红。

---

## 9. 登记面和关注项

① 清单第 4 面：`tests/selfhost/test_compile.py` 自带文件清单。全枚举首轮捕获，报 `Undefined name: ccr_type_prepare_save/…`。它与 `build_selfhost_native.py` 的 corec 清单同为清单面，本任务同批补 `ccr_types.cr` 并留注记，T0 的 `iface_axis.cr` 有同样教训。T3/T4 再动清单时务必全枚举。

② 判定原语（`ty_sub` 族）跨进程同值，本任务未覆盖，登记。计划 Task 2 的架构句包含“判定原语跨进程同值”。实施中一度把 `type_engine.cr` 放入 corearch 清单，concat 和 project-mode 两面都加，以跑 ty_sub 探针，结果 project-mode 门失败：`corec build src/targets/x86_64-linux` 报 2 条 `error[TF01]`。`lits_copy` 是真类型洗白 TF01，返回 string 却声明 int，是既有 `check` 作业 rc=1 的划界之一；`ty_memo_slot_no_grow` 是 loop 落空误报，`ty_shadow.cr:118` 有记载。二者都是既有诊断，入清单即触发 `test_backend_bootstrap` 的 `error[`=0 门。因此回退到计划 Step 4 的清单形，corearch 只入 `type_terms.cr`，探针改用项层原语 `tt_norm`/`tt_is_dnf`/`tt_is_literal`，并把规范化结果下标放入摘要，后者等价覆盖“重建索引 `g_tt_index` 与去重行为”。

收口路径，供 T3/T4/P5 选择：(a) 修两条 TF01，改源码等于动 `check` 作业的 rc=1 划界，可能动 IR，需要维护者裁决；(b) 门加允许清单；(c) 维持现状，判定原语跨进程同值不覆盖。本任务不擅动。

2026-09-13 收口，路径 (a) 已兑现，详版在 `docs/archive/sdd/tf01-cleanup-report.md` 和 TODO #40。`lits_copy` 是真类型洗白：`alloc` 模型返回 `TI_STR`，声明 `-> int` 错误；修法是返回型改为 `string`，并同步 `lits_contradictory_buf` 形参。`ty_memo_slot_no_grow` 是 checker 落空分析缺失；修法是 `checker.cr` 新增 `stmt_cannot_fall_through`/`loop_body_has_break`，站点 5 只在函数体确定不能落空时豁免。`check src/compiler` 现在 rc=0；`type_engine.cr` 已进入 corearch 清单两面（`backend_support_files` 32 文件加 target `_import.cr`），project-mode `error[`=0 门（`test_backend_bootstrap`）通过。判据面（ELF canary `95084e7b…d475` IDENTICAL、全枚举、自举链）见该报告。

③ 既有面，不是本任务引入，登记不修：

- 自源 `src/compiler/_import.cr` 的 `corec ccr`：冷态 rc=0，热态 rc=139（段错误）。pre-T1 基线二进制同样复现，冷 0、热 139，属于既有问题，缓存命中路径缺陷，TODO #5 家族。`_import.cr` 是“import-only 加注入 main wrapper 调未定义的 `compiler_main`”的畸形输入。因此自源 `.ccr` 记录值取冷态。
- `tests/suite/test_control_flow.cr` 是 0 字节文件，standalone `ccr` 必然失败；`examples/test_sum.cr` parse 错；`at_test_mini4/6.cr` 不支持嵌套 fn；`src/stdlib/{chan,goroutine,sched}.cr` standalone 编译重复定义，`_import.cr` 重复收编。这些都由 §6-#10 的失败集与 pre-T1 逐条相同证明。
- STR 段冷/热差异（T1 已登记）和“`.ccr` 逐字节同”类判据作废。本任务按 TODO #26 口径，以结构性断言、语义零变化、自举稳定为准。

④ 变异控制，两条，均用 /tmp 侧的“清单照旧、内容替换”构建，仓库文件零改动，遵守纪律 #3。harness 为 `/tmp/p4t2/mutmut/build_mut.py`，`MUT_ONLY` 单目标。

| 突变 | 内容 | 期望 | 实测 |
|---|---|---|---|
| A（loader 拓扑校验关闭） | `ccr_io.cr:ccr_type_ref_before` 恒 `return 1` | 拓扑拒绝用例转红 | 转红：`test_p4t2_loader_rejects_topology_violation` FAIL，报 `corearch accepted mutated file: rc=0 (silent-accept = 三态纪律违反)`；同源负控 `test_p4t2_loader_accepts_annotation_slot` 也 FAIL，CONS 引用槽负控失去拒绝；其余 17/19 仍通过，突变面窄 |
| B（跳过确定性装填） | `ccr_types.cr:ccr_type_prepare_save` 直接调 `ccr_type_seg_build`，序列化活表 | 确定性用例转红 | 转红：`ct.seg_determinism` FAIL，报 `buffer length changed 147040 -> 147080`，唯一标注项在第二次构造时被追加进活表；337/338 |

突变 B 有一处实证修正，登记。首版确定性用例只用判定扰动（`ty_sub`/`ty_disjoint`/`ty_equiv`），实测对突变 B 不转红，因为该夹具上下文里这些判定可能与既有项同构，零新增项，活表和重建表相同。因此用例补“唯一标注项” `tt_atom(AK_DEX, 900001, [int])`，保证追加新项，之后转红。这条本身说明用例的有效性必须实测：未做突变控制时，该用例对“跳过装填”类实现是假绿。

⑤ corearch 二进制变大，不是判据面，B.4-18 有先例。concat 文件数从 30 变为 31，增加 `type_terms.cr`。定稿二进制 sha：`build/corec c910df2d…`、`build/corearch 32166aae…`、`build/corelsp 2d94c39c…`。对照口径：T1 前置基线只保留 pre-T1 二进制 `/tmp/p4t1/bin_pre/`，corearch 959224B、corec 1663232B。精确的 pre-T2 值需要重建父提交，不是判据面，不采。

突变构建出树证据，即“仓库零改动”的可核事实：突变二进制 sha 为 `runA/corearch b59dda50…`、`runB/corec 27f0ab44…`，与仓库两件都不同，路径在 /tmp 侧。仓库源码在突变前后由 `jj status` 干净和本报告 §10 的提交面证明。

⑥ 影子通道零覆盖实现方式面，继承声明。本任务复跑影子对拍（§6 附表）只作为“判定面零变化”的必要条件，不能当作实现方式正确性的证据。

⑦ T3 交接：IFACE 空壳检查 `count != 0` 拒绝仍在，T3 实施时须自产物同批放开，模式同 T1 到 T2 的 Concern ②。`ccr_types.cr` 的 `ccr_type_populate()` ③ 段（接口签名项装填）和形状重注册是空转待填。`globals.cr` 的 `g_ccr_type_seg` 两件如果 T3 要复用 IFACE 段，须另加同名族缓冲，不要挪进 corec-only 文件，corearch 清单理由见 §1。

---

## 10. 提交

```
3d604e11（change nqrptwut）feat: R2 P4 Task 2——TYPE 段（类型行表 + 类型项 DAG 序列化 +
         确定性装填 D13 + corearch 读回重建）；corearch 链接 type_terms.cr
16 文件：src/compiler/ccr_types.cr(A) · ccr_io.cr · type_terms.cr · globals.cr · dyn_arr.cr ·
        checker.cr · main.cr · corearch.cr · type_selftest.cr · _import.cr ·
        src/targets/x86_64-linux/_import.cr · build_selfhost_native.py ·
        tests/selfhost/test_ccr_types.py · test_compile.py · src/ci/run.sh ·
        docs/superpowers/specs/2026-09-09-lattice-ir-v7-format.md
```

`jj diff -r 3d604e11 --summary` 核对为上述 16 个路径，15 个修改加 1 个新增。提交后 `jj status` 工作副本干净，空提交 `e89cb8e6`。提交说明包含段布局、实现、判据全量、推翻计划一处预测的实测、未覆盖面和收口路径、突变控制结论。

## 11. 证据路径（本机）

- 构建：`/tmp/p4t2/build{1,2,3,4}.log`。1 是首建；3 是回退引擎面后定稿；4 是确定性夹具补自测后。
- 判据：`/tmp/p4t2/st4.log`（selftest 338/338）、`/tmp/p4t2/pa_p4t2b` 加 `canary.log`（canary IDENTICAL）、`/tmp/p4t2/tc_final.log`（ccr_types 19/19）。
- `.ccr` 记录值：`/tmp/p4t2/final_{pa,gen,src}_cold.ccr` 加 `sha256sum`。
- 冷/热与三档测量：`/tmp/p4t2/{pg,pl,pa}_{cold,warm}.*`、`dump_{cold,warm,corec,corearch}.txt`。
- 全枚举：`/tmp/p4t2/enumerate.sh` 加 `/tmp/p4t2/enum_all{2,3}.log`（53/53 两轮）加逐档 `/tmp/p4t2/enum/*.log`。
- report-only：`/tmp/p4t2/ro_fails_{bin_pre,build}.txt`，diff 为空。
- 同源对拍：`/tmp/p4t2/parity_{check,shadow}_{pre,new}.{out,diff}` 加 `shadow_{logs,dumps}.diff`，全部为空。
- CI：`/tmp/p4t2/ci_{check,suite,full-bootstrap}.log` 加 `/tmp/corec{2,3}`。
- 突变控制：`/tmp/p4t2/mutmut/`，包含 `build_mut.py`、`ccr_io.mutA.cr`、`ccr_types.mutB.cr`、`runA/runB` 构建与日志 `mut{A,B}_*.log`。
