# 内核抽取 Task 4 报告：收官（全量回归、自举重建、文档和台账同步）

状态：完成。回归面全部通过，guard 证据完整，文档同步已落盘。提交信息为 `feat: 内核抽取收官，全量回归 + 自举重建 + 蓝图步骤 2 完成注记 + cir cache 指纹缺陷挂账（TODO #5）`。

基线声明：任务开始时 build/corec 加 build/corearch（02:17 构建）与提交源码一致（最新源码改动是 02:16 的 Task 3 corearch.cr），工作树干净，因此回归使用同源二进制判据。所有测试前执行 `rm -rf .core/cache`（ccr_v7 套件内部也会自清）。全程 `nice -n 19`。

## Step 1：全量回归跑批（逐套件计数）

驱动脚本 /tmp/kernel-t4/drive.sh，顺序跑批，逐套件记录日志和 summary。汇总如下：

| 套件 | 结果 | 计数 |
|---|---|---|
| compile（test_compile.py） | rc=0 | All selfhost compile tests passed |
| backend_bootstrap（test_backend_bootstrap.py） | rc=0 | stage 链全部 [PASS]：stage1/stage2 发射 smoke ELF，stage0-2 smoke ELF 返回 7，O2 metadata CCR 构建和读回，stage0-1 O2 smoke 返回 7。没有计数行，逐条 [PASS] 且 rc=0 |
| hit_table（test_hit_table.py） | rc=0 | 24/24 passed |
| region_cfg（test_region_cfg.py） | rc=0 | 22/22 passed |
| mw1-6（test_mw_task1..6.py） | rc=0，6 次 | mw task1..6: ALL PASS，6 次 |
| slice_bounds（test_slice_bounds.py） | rc=0 | 7/7 passed |
| live_ranges（test_live_ranges.py） | rc=0 | 13/13 passed |
| ccr_v7（test_ccr_v7.py） | rc=0 | 23/23 passed |
| bootstrap 三套（test_pipeline/test_borrow/test_generics） | rc=0，3 次 | 29/29 加 4/4 加 3/3 passed |

全套件日志 grep FAIL/Traceback/Error，零命中。backend_bootstrap 没有计数行，已逐条核对 [PASS] 并用 rc=0 确认。

## Step 1b：run.sh full-bootstrap guard（amended regression surface 成员）

清 cache 后，按 run.sh full-bootstrap job 的语义执行（跳过 build_selfhost，因为二进制已经同源）：
- `nice -n 19 ./build/corec build src/compiler/main.cr -o /tmp/corec2 --static -O 0` 得到 rc=0，N06 计数 = 0（src/compiler 单源自编译单元包含内核，保护性断言通过）。
- `/tmp/corec2 build src/compiler/main.cr -o /tmp/corec3 --static -O 0` 得到 rc=0，N06=0。
- `cmp /tmp/corec2 /tmp/corec3` 得到 IDENTICAL。
- 冒烟：`/tmp/corec3 run 'fn main()->int{return 42;}'` 得到 exit 42。

## Step 2：自举重建和冒烟

`nice -n 19 python3 build_selfhost_native.py` 得到 rc=0，=== BUILD SUCCESS ===（build/corec 02:29:44，build/corearch 02:29:47，build/corelsp）。
冒烟使用重建后的二进制：
- backend_bootstrap stage 链重跑得到 rc=0，全部 [PASS]（包含 stage0-2 smoke ELF 返回 7 和 O2 metadata 链）。
- corec check 小样本：`./build/corec check tests/suite/arena_test.cr` 得到 rc=0（[1/5] 到 [5/5] frontend done）。
- corec run 小样本：`./build/corec run 'fn main()->int{return 42;}'` 得到 exit 42。
- 注：`corec check tests/suite/test_control_flow.cr` 报 cannot read，因为该文件是 0 字节占位文件（4 月 24 日创建，不是本任务产物）。inline run 含 println 但没有 import，属于样本选择错误。两者都不是编译器缺陷，换样本后通过。

## Step 3：文档同步（docs 修改清单）

1. TODO.md：在预存 Bug 区新增 #5“cir cache 跨编译器重建不失效”（Task 3 concern ①，reviewer 已确认）。内容包括现象（旧条目跨重建存在，导致 g_strs 顺序错位，dump 通道 var 名从 806 变成 381，已实证）、机制（指纹由 magic、版本、源 AST 组成，没有编译器身份分量）、证据（kernel-task-3-report.md concern ①，清 cache 后逐字节复现）、修复方向（cir_cache.cr 缓存键增加编译器指纹或内容哈希；后备是 CIR_CACHE_VER bump 加测试前清 cache）。
2. 蓝图 `docs/superpowers/specs/2026-09-09-corearch-rewrite-design.md`：顶部状态行、第 2 节执行状态注记、第 3 节步骤 2 完成标记。
   - 第 2 节注记块：regalloc 拆分执行化（ent_kernel.cr 内核双 concat，regalloc.cr 是 x86 实例机器侧）；ccr_io 写侧单源化（删除 compute_entries_v7/ccr_grow_*，双转录 R5 收敛，23/23 byte-identical）；corearch.cr 引导收敛（g_instance_decl 两行加表驱动 dispatch，48/48 逐字节相同）；新发现注册契约需要双向（判定到 meta 的读通道，meta_reg_for_var 纯读随判定进入内核，写入侧 meta_set/append/remove/meta_reg_assign_total 留在实例，实例产出经内核读通道消费）；grow 和 accessor 收敛成果（grow 单实例化，loader 与写侧同调内核 ent_kernel grow，ccr_ent_* 按真实引用保留）；挂账注记（rl_print_loc 的 x86 注释待清，ent_kernel.cr:593；按实例钳制时记起 corearch.cr:255-256 钳制点，以及 :244 拒绝消息 --table 措辞参数化点，M1/M4；实例侧双份头注 M5）。
   - 第 3 节步骤 2 划线并标完成（判据清单：13/13、23/23、全量回归、guard、重建冒烟；范围克制保持注：资源域参数化、双向契约 home 回填、loader 语义对象化未做，属于后续步骤）。
3. `docs/superpowers/plans/2026-09-10-corearch-kernel-extraction.md`：顶部状态行从待执行改为“实施完成（Task 1-4 落点摘要：b0d24b1b / edc70fbe+c138c44c / 6413dd80 / 收官提交）”，沿用已完成计划的状态行惯例（regalloc-backend plan 先例），复选框不动。
4. `src/arch/linux/ld/ent_kernel.cr`：M3 顺手修注释层。头注函数名变化 2 处，`reg_assign_total` 改为 `meta_reg_assign_total`（实际函数名在 regalloc.cr:157，replace_all 两个位置）。
5. `src/arch/linux/ld/main.cr`：增加死代码遗留注记，只注记不删除。内核抽取计划 Global Constraints 的裁决是：已用 build_selfhost_native.py 的 concat 清单核实零 concat 引用，删除要等专项核对 corearch.cr 功能重合面后另行决策。

本任务零源码语义改动，只改了 ent_kernel.cr/main.cr 的注释行，行为零变化判据全部通过。

## 设计纪律注记（供评审）

- 没有回归失败，未触发 Escalation，没有偏差处置。
- 判据定位点与 Task 2/3 完全相同（13/13、23/23、24/24、22/22、7/7、mw1-6，bootstrap 三套计数与 Task 3 复跑一致，backend_bootstrap 冒烟链一致）。
- cir cache 缺陷是预存的，不是本任务引入。已按 reviewer 判据挂账 TODO #5，修复方向已记录（缓存键增加编译器指纹）。测试纪律“清 cache”是现状的后备措施。
