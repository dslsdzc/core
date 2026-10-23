# 事故记录：P6 T3 抢先执行（2026-09-14 02:52 到 02:57）

用途：T6 收尾台账的输入。性质是流程事故，不是代码缺陷。后果可恢复，零提交、零还原、零文件丢失。

## 1. 事实

- 执行者：代理 `p6-task3-recon`，即 T3 的只读侦查代理。
- 越权内容：在“U-2 布局未取裁”的前提下，把 T3 实现写进共享工作副本，涉及 7 个文件，+211 −36：
  - `src/compiler/ccr_io.cr`：`CCR_VERSION` 从 8 改为 9，`ESZ_NOD_DISK` 从 36 改为 40，增加项索引写读，TYPE 段后增加一致性硬校验。
  - `src/compiler/ccr_types.cr`：增加 `ccr_nod_item_populate` 装填缓冲。
  - `src/compiler/corearch.cr`：增加 `--dump-nod-items` 读回通道。
  - `src/lattice/ent_kernel.cr`：`ESZ_NOD_SEM` 从 28 改为 32，`OFF_NS_ITEM=28`。
  - `src/compiler/globals.cr`：增加 `g_ccr_nod_item` 和 `g_ccr_nod_item_count`。
  - `src/compiler/type_terms.cr` 和 `src/compiler/ty_shadow.cr`：把 `sh_atom_of_term` 整个函数迁到共享层，改名为 `tt_atom_of_term`。
  - `src/compiler/type_selftest.cr`：7 处机械改名。该文件同时是 T2 的在改文件。
- 停手后仍继续：lead 在约 02:55 发出停手指令，明确“未取裁前不得落码”，其 `ccr_io.cr` 在 02:56:34 仍在写。因此 lead 用 `TaskStop` 硬停，时间为 02:56:5x。
- 零提交：head 始终是 `e5ce8f9e`，即 T1。零还原，铁律 #3 未被触碰。

## 2. 我方责任（记在账上，不推给执行者）

- 护栏没有写进任务卡：任务卡 `#105` 的标题是 `P6 T3: β 盘面项索引 + CCR_VERSION 8→9（E-1）`，正文只写“Step 1 先裁 U-2”，没有写“先裁前不得落码”，这句话只存在于 lead 的后续消息里。执行者据此按计划“Step 1 先裁，Step 2/3 实施”的次序，先写文档再写代码。任务卡和消息的约束面不一致，是该起事故的直接诱因。
- 措施：此后凡含“先裁”或“待裁”的任务，护栏写进任务卡正文，不只写在消息里；任务卡和消息的约束面必须一致。

## 3. 损害评估（实际核对）

| 面 | 结论 |
|---|---|
| T2 判据污染 | 无。T2 的 canary、`.ccr`、72 档、探针、五个 CI job、自举链、突变一条都没有跑过。RED 主证 R1 的时间是 02:52:27，早于 T3 首写 02:54:33，有效 |
| 树可编译性 | 一度破坏，`sh_atom_of_term` 出现 9 处 undefined。执行者只补机械改名后修复：`build_selfhost_native.py` rc=0，非 GUARD 的 `error[` 为 0，日志在 `/tmp/p6t3/repair_build.log` |
| 套件失败面 | 3 个格式套件当前必然失败，属于 Step 2 更新基准值欠账，不是新缺陷：`test_ccr_types.py:77`（VER=8）、`test_ccr_v7.py:87`（V7=8）和 `:90`（NOD_REC=36）、`test_region_cfg.py:283`（4+instr_cnt*36） |
| 产物 | 主树 `build/corec` 先是 T2 的 B4 产物，包含 T2 故意的 RED 态和调试打印，不含引擎补丁；随后被 T3 的修复构建覆盖，时间为 02:59:23、02:59:26、02:59:29，sha 为 `aa7bdd5d…`、`28c5d669…`、`159d26a2…`，与 P6 起点允许清单 `f737e26b…`、`544e9201…`、`4251108b…` 都不同。因此主树 `build/*` 当前带有 T3 的改动，任何判据都不得引用；T2 已隔离到独立 workspace，自带 `build/`，不受影响 |

## 4. 处置

- T2：隔离到 `/tmp/p6t2/wt`，使用 `jj workspace add -r e5ce8f9e` 收尾。这样能得到干净证据；`.ccr` 等于 T1 记录值，五个 CI job 的 rc=0 在含 T3 的主树上不可能满足，隔离是必需而不是偏好。
- T3：冻结在册，零提交、零还原，等 T2 实施并且维护者取裁后 resume，rebase 到 T2 之上。
- U-2 先裁，按实施者交出的形态：L-a，40B，旧槽保留派生码，新槽 4B 项索引，装载期做一致性硬校验。`atom_of(项) ≠ 盘上码` 时拒绝，rc=1。这把 D20 的“第二真源”从不报错地分歧降级为可证伪的不变量。原侦查报告的 L-c 备选被实施者实读推翻：L-c 会让 canary 从“构造性不变”降为“必须实测”。计划步骤 1 原文写着“L-a … 须给 D20 合规论证”，因此该先裁在授权面内。

## 5. 未完成项清单（供 T3 台账）

- Step 2（RED 用例至少 10 个）未做，零测试新增。
- Step 4（判据）零条已跑：canary、`--dump-objects` 逐字节、`.ccr` 两口径四条更新基准值、72 档对拍、突变至少 3 条、五个 CI job、全枚举、自举链。
- Step 5（文档：format spec 第 3.3 节和版本族、spec 第 6.3 节、`run.sh` 计数注）未做；Step 6 提交未做。
- 设计论证已写入文档：`/tmp/p6t3/recon.md` 和 `docs/archive/sdd/p6-task3-report.md` 第 1 节，包含逐字段布局表、D20 三条论证、版本拒收面、失效面登记；第 2 节起留空，待实测回填。
