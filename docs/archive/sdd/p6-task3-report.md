# R2 P6 任务 3 报告：E-1 β，`.ccr` NOD 盘面项索引、`CCR_VERSION` 从 8 到 9、corearch `atom_of` 读回

日期：2026-09-14。起点：`e5ce8f9e`，T1 收尾。隔离 workspace：`/tmp/p6t3/wt`，自带 `build/`，与主树无关。纪律：全部使用 `nice -n 19`，逐段用 `ps` 实查，比较前 `clean-cache`，版本控制只用 `jj`。

先裁：U-2 采用 L-a（40B）；U-3 采用 (i)，协调者已裁。论证见第 1 节。

## 1. 步骤 1：先裁（布局表、D20 论证、失效面）

### 1.1 逐字段布局（盘上 40B，内存 32B）

| 盘偏移 | 宽 | 字段 | 语义 | 写 | 读 |
|---|---|---|---|---|---|
| +0 | u32 | op | IR opcode | `save_ccr` NOD 段 | `load_ccr` NOD 段 |
| +4 | i32 | dest | 目标 var，-1 表示无 | 同 | 同 |
| +8 | i64 | s1 | 常量或名索引 | 同 | 同 |
| +16 | i32 | s2 | 操作数 2 | 同 | 同 |
| +20 | i32 | s3 | 操作数 3 | 同 | 同 |
| +24 | u32 | tk | 派生码，来自 `sh_dfn_code_of_slots`，字节和语义与 v8 相同 | `iri_tk` | 写入 `OFF_NS_TK` |
| +28 | i32 | item | TYPE 段文件空间项索引，-1 表示无项 | `g_ccr_nod_item`，由 ccr_types 装填 | 写入 `OFF_NS_ITEM` |
| +32 | u32 | first_edge | 邻接起点，前缀累计 | `edge_offs` | 写入 `g_v7_nod_meta` |
| +36 | u32 | edge_count | 出边数 | `edge_counts` | 写入 `g_v7_nod_meta+8` |

内存 sem 记录 `ESZ_NOD_SEM = 32`，等于盘上前 32B，剥离邻接；`OFF_NS_ITEM = 28`；访问器 `nod_item` 为 i32，-1 必须读到 -1。取位依据是“语义字段在前”的自 v5 惯例，邻接域追加在后，因此项索引属于语义区，邻接顺移。

### 1.2 U-2 采用 L-a（D20 合规论证三条）

① 跨边界引用零新增：只引入 TYPE 段文件内项索引，这是 D20-② 唯一许可的形态；不引入进程内索引，因此 D20-③ 不受影响。② “码等于派生量”不变：两个值同源于唯一写点，即 `ccr_types.cr:ccr_nod_item_populate` 在保存期的单遍处理，没有第二套建项逻辑。分类使用 `sh_tk_face_of_code`，建项使用 `sh_term_of_ti`，都是既有单源。③ 分歧即硬性拒绝：`load_ccr` 在 TYPE 段解析后校验 `item < -1`、`item ≥ tt_count()`、`tt_atom_of_term(item) ≠ 盘上码`，任一成立就拒绝，rc=1，消除“盘面值不报错地胜出”的危害模型。

L-b 排除：单槽“项索引或辅码”加分类表判读，读侧不可判定。分类表对类型面 op 的 face 分派依赖派生码本身；单槽后槽值域，即项索引和复合行码，发生重叠，反例是 `tests/suite/ptr_ref_first.cr` 的 `IR_BINARY tk=10`。

登记未取：更严格的单源形态 L-c，旧槽改载辅码，码完全在装载侧重派生，没有并存，但会改发射路径输入，使 canary 和 `--dump-objects` 从构造性变为必须实测。本轮写侧的装填、校验、回读通道在 L-c 下可以整体复用。

### 1.3 U-3 采用 (i)，已裁，以及失效面

`.cir` 不动，`CIR_CACHE_VER` 保持 17。依据是项索引只在 `ccr_type_populate()`（`ccr_types.cr:54-81`，含 `tt_layer_reset`）重建后的文件空间中成立，而 `.cir` 写点在 `main.cr:553`，早于该空间。因此 (ii) 只能落进程内索引，对应 D20-③ 和 `bad_term=329`；而且快照已经载入派生码，保存期重派生即可得到，零收益。

失效面是已有的 `.ccr` 文件，版本检查整类拒收，位置在 `ccr_io.cr:960`；以及 `.cir` 条目，v17 编译器身份字段会自动失效，无需升级版本。

## 2. 步骤 2：用例（新增 8 例，`test_ccr_types` 从 40 到 48）

| 例 | 内容 | 判据 |
|---|---|---|
| ㊳ `test_p6t3_version_gate_rejects_v8` | v9 接受，作为非平凡性控制；v8 补丁后拒绝 | rc≠0 且无产物 |
| ㊴ `test_p6t3_nod_record_40b_field_order` | 段体为 4 + n×40；op、tk 六列与 `--dump-objects` 比较 | 步长、fe 累计、跨通道相同 |
| ㊵ `test_p6t3_nod_items_roundtrip` | 项索引写入磁盘和读回对拍，核心用例：`mism == 0`、`with_item > 0`、非退化，即存在 `idx ≠ code` | corearch `--dump-nod-items` rc=0 |
| ㊶ `test_p6t3_items_match_memory_face` | `(item ≥ 0) ⟺ (内存 term ≥ 0)` 逐节点成立，`with_item == with_term`；盘上 `tk` 等于内存派生码，D22-① | 两个通道面一致 |
| ㊷ `test_p6t3_aux_face_and_composite_preserved` | 辅码面 5 个 op 时 `item == -1`；复合行，即 `ptr_ref_first` 的指针行，`item == -1` 且码保真 | 三语料合计非空转 |
| ㊸ `test_p6t3_item_oob_rejected` | 越界 `tt_count()`、负域外 -2、域内非原子项，均应拒绝 | 三个子例 rc≠0 且无产物 |
| ㊹ `test_p6t3_nod_count_overflow_rejected` | `nod_count := n+1` 时段界检查拒绝 | rc≠0，正控 rc=0 |
| ㊺ `test_p6t3_d18_purity_static` | `ccr_io.cr` 代码面零 `sh_*` 和 `get_type_*`，验证 D18 纯度 | 正则扫描，剔除注释 |

更新基准值欠账，三处原本必然失败，现已通过：`test_ccr_types.py:77` 的 VER 从 8 改为 9；`test_ccr_v7.py:87` 的 V7 从 8 改为 9，`:90` 的 NOD_REC 从 36 改为 40，邻接偏移从 +28 改为 +32，`:1183` 从 +32 改为 +36；`test_region_cfg.py:283` 从 36 改为 40，`:316` 的 version 从 8 改为 9，这一处计划漏列。另有 `ccr_nod_rows` 步长改为 40，新增 `ccr_nod_records`，包含 fe 前缀累计不变量。

## 3. 步骤 3：实现（写侧、读侧、回读）

- 写侧：`ccr_types.cr:ccr_nod_item_populate`，在 `ccr_seg_prepare_save` 尾部调用。保存期由盘上派生码经 `sh_tk_face_of_code` 和 `sh_term_of_ti` 重派生，写入 `g_ccr_nod_item`。该变量只在 corec 侧；D18 要求 `ccr_io.cr` 在 corearch 清单内，只做缓冲搬运。计划步骤 3 原文“同出 emit 期那一次拆分”不能照字面实施，因为 `tt_layer_reset` 在 save 前会作废 emit 期引用，`bad_term=329` 是同类问题。本实现是同一桥接函数的重派生，与 `.cir` 装载侧同构。
- 读侧：`ccr_io.cr` 的 NOD 段读取 `item`（i32），写入 sem 的 `OFF_NS_ITEM`。TYPE 段解析后增加一致性硬校验 pass，三态处理：域外或不一致就拒绝，不得不报错地当作无项。
- 回读通道：`corearch.cr:dump_nod_items`，参数为 `--dump-nod-items`。逐节点执行 `item` 到项表取项，再 `tt_atom_of_term` 取行，并输出计数头；`with_item` 作为非空转门。
- 共享层迁移：`ty_shadow.cr:sh_atom_of_term` 迁到 `type_terms.cr:tt_atom_of_term`，整函数迁入，逻辑逐字相同，9 处调用点改名。corearch 清单不包含 `ty_shadow.cr`，而 `load_ccr` 校验和回读通道需要它。B.6 三面核对：`type_terms.cr` 在两个清单中都已包含，因此无需增删清单，`test_backend_bootstrap` 通过。
- 版本：`CCR_VERSION` 从 8 改为 9，`ESZ_NOD_DISK` 从 36 改为 40，`ESZ_NOD_SEM` 从 28 改为 32。

## 4. 步骤 4：判据（全部通过）

| 判据 | 实测 |
|---|---|
| ELF canary | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`（28822B），IDENTICAL |
| `--dump-objects` 两口径 | 与 T0 记录做 `cmp`，IDENTICAL。`generics_test` 3521 行 ×2 口径；`ptr_arith` 2427 行 |
| `.ccr` 两口径四条，更新基准值 | pa ccr 96015B `680a6f98…`，原 90823 `fb4a3b59…`；pa static 96158B `76f36e6a…`，原 90966 `592afa31…`；gt ccr 142793B `41e9d845…`，原 135341 `ddec1ce6…`；gt static 142936B `704316c8…`，原 135484 `cd2af565…`。增量为 4B 乘节点数：pa 增加 5192，等于 4×1298；gt 增加 7452，等于 4×1863。口径差恒为 143B，不变 |
| 72 档 `check` 同源对拍 | rc 分布 34×0、38×1，两态相同，`diff -rq logs` 零差异。构造性隔离：`check` 在 `main.cr:448/:450` 早退，不读不写 `.ccr` 和 `.cir` |
| 探针 29 档 | rc 分布 17×0、12×1，两态相同，零差异 |
| 五个 CI job | check、bootstrap-tests、suite、selfhost-tests、full-bootstrap 全部 rc=0 |
| 全枚举 | 58/58 rc=0 |
| `selftest-types` | 404/404 rc=0 |
| `check src/compiler` | rc=0 |
| 自举链 | `corec2 == corec3` IDENTICAL（2859006B）；N06=0；冒烟 rc=42；`--help` rc=1 |
| `test_backend_bootstrap` | rc=0，项目模式 `error[` 为 0 |
| 三个格式套件 | `test_ccr_types` 48/48，`test_ccr_v7` 27/27，`test_region_cfg` 22/22，另有 `test_mw_task1` 全部通过 |

## 5. 突变控制（M1 到 M5；在仓库外实拷贝 `/tmp/p6t3/mut`，逐条精确回滚）

| # | 改法 | 结果 |
|---|---|---|
| M1 | `ccr_types.cr` 写槽改填派生码，而不是项索引 | 失败：loader 拒绝，报 `invalid .ccr file`，㊵、㊶、㊷ 失败，36/48 |
| M2 | 删除 `ccr_io.cr` 整段域检查和一致性校验 | 失败：越界或不一致项被不报错地接受，㊸ 失败，47/48 |
| M3 | 写侧改用 emit 期活表索引，即 `OFF_DF_TK` | 失败：loader 拒绝，㊵、㊶ 失败，37/48。这是“save 期重派生”硬约束的唯一机器判据 |
| M4 | 版本检查放宽，`!=` 改为 `>` | 失败：带 v8 标签的 v9 文件被接受，㊳ 失败，47/48 |
| M5 | 只删除交叉校验，保留域检查 | 失败：域内非原子项被接受，㊸ 失败，47/48 |
| 回滚 | 两个文件从 pristine 拷回 | 与 workspace 逐字节相同，`diff -q` 零输出 |

## 6. 偏差和残留（登记，不不报错地）

1. 计划步骤 3 有顺序矛盾，原文为“同出 emit 期拆分”。实际改为保存期重派生，见第 3 节，由突变 M3 保护。
2. 计划 Files 漏项：`type_terms.cr`，共享层迁移；`src/arch/x86_64/regalloc.cr`，在 L-a 下零改动，但是读回实体之一；`tests/selfhost/test_region_cfg.py`，第三和第四个格式断言点。corearch 读回被挂在 `main.cr`，文件归属有误，实际位置是 `corearch.cr:243` 加 `regalloc.cr:877`。
3. 定位点点勘误：`src/compiler/ent_kernel.cr` 实际为 `src/lattice/ent_kernel.cr`；`run.sh:82/:86` 实际为 `:85/:89`，T1 之后；`dyn_arr.cr:104-107` 实际为 `:103-118`。
4. 残留：暖态项面是部分的。缓存命中会跳过 ir_gen，暖进程未分配的类型行因此 `item = -1`，码由 `tk` 保真；冷态完整；冷态和热态各自的确定性不变。
5. 未取形态 L-c 的登记，见第 1.2 节末尾。

## 7. 证据路径

- 隔离 workspace `/tmp/p6t3/wt`，本提交；突变沙箱 `/tmp/p6t3/mut` 和 pristine `/tmp/p6t3/mut_pristine/`。
- 日志：`/tmp/p6t3/{wt_build1.log, t_ccr_types.log, t_ccr_v7.log, t_region_cfg.log, ci_*.log, enum_list.txt (+enum_*.log 58 份), mut_build.log}`
- 对拍：`/tmp/p6t3/parity_{frozen,post}/`，72 档；`/tmp/p6t3/probes_{frozen,post}/`，29 档。
- 产物：`/tmp/p6t3/probe/{pa_c,pa_s,gt_c,gt_s}.ccr`、`pa`（canary ELF）、`{gt,gt_s,pa}_do.txt`。
