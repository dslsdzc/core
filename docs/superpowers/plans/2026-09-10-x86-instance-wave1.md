# x86 实例化批次 1（结构批次）实施计划

> 状态：实施完成（2026-09-10 批次 1 结构批次 Task 1-7 结束）。对应提交：Task 0 盘点 327c2cf01af3（设计定稿 6694f358f376）、Task 1 三轴迁移加组合根 29d177ac49a5（加补正 c927525baf35、docs 58e6be3a1c18）、Task 2 entry.cr 整体迁移 b23f008000cf（加 docs 8dcfaeca52b2）、Task 3 frame.cr 抽取 b0ba8c1c9b01、Task 4 tag2l.cr 整体迁移 d65fc1b8f3c3（加 docs c6b6cbfe9a75）、Task 5 callseq.cr 抽取 3ab39f6eaa16（加 docs 525a872a0ba7）、Task 6 syscall.cr 抽取 94d1cac15359（加 docs d2f3e0968d8c）、Task 7 为结束提交。检查全部通过：行为零变化（每任务 stage 链 byte-identical 加结束全量回归逐套计数）、自举重建快速验证、full-bootstrap guard（corec2/corec3 cmp 相同加 N06=0）、syscall4 套件持久覆盖（`tests/suite/syscall4_test.cr`）。逐套计数与未做项见设计 spec `2026-09-10-x86-instance-design.md` 第 8 节执行注记。

> 面向执行本计划的 agent：必须使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans，按任务逐项实现。用复选框（`- [ ]`）跟踪进度。

目标：完成三轴目录重组（架构 × 格式 × OS）、序列算法文件化、表数据迁到架构轴、构建清单分段守卫。行为零变化，只做迁移和文件化，stage 链 byte-identical。

结构：序列算法现在全部内联在 elf_gen（elf.cr 982-1830，849 行）与 emit_instr（instr.cr 986-2183，1198 行）两个巨型函数里。批次 1 先做零抽取迁移（Task 1），随后逐类文件化：entry 整体迁移、frame 抽取、tag2l 整体迁移、callseq 抽取、syscall 抽取。每任务独立提交，检查为 stage 链 byte-identical。H1：抽取会改变 cp/pos/buf 作用域，绝不合并多个抽取点。组合根定为 `src/targets/x86_64-linux/`，target triple 是三轴组合的正式名。

技术栈：elf.cr/instr.cr（拆分源）、module.cr 回退链、build_selfhost_native.py 清单、tests/selfhost/（检查套件）、tools/pseudocode_extract.py。

设计 spec：`docs/superpowers/specs/2026-09-10-x86-instance-design.md`（第 2 节三轴目录、第 3 节清单分段、第 5 节批次 1、第 6 节待办）。

## 全局约束

- 版本控制用 `jj`，见项目规则第 2 条；每任务用 `jj commit -m '<msg>'`。
- 构建 `nice -n 19 python3 build_selfhost_native.py`；测试加 `nice -n 19` 前缀，见项目规则第 6 条；清 .core/cache。
- 行为零变化严格约束：每任务检查 = `test_backend_bootstrap.py` 11/11（stage 链 run 内 byte-identical）加相关套件（hit_table 24/24 表路径保持、ccr_v7 24/24、live_ranges 13/13、compile）；结束做全量。
- 抽取纪律（H1）：每抽一段独立提交加 stage 链验证；抽段时 cp/pos/buf 三参数显式传递。帧公式双源（H2）必须单入口。`sizes.cr:4-10` 头注明令「NEVER hardcode byte counts」；`test_mw_task1.py` 的 sub rsp 立即数断言是帧专项检查。
- 归属裁决（H3）：`g2_tag_off`/`mw_frame_size` 归 `frame.cr`；`tag2l.cr` 依赖 frame（同轴内）；mw 族 e2_mw_* 纯编码归 tag2l；e2_* 通用编码原语（640-985）留在 instr.cr。
- stage0 硬编码点 `test_backend_bootstrap.py:13` 必须先改后迁移（H6）。
- TODO #2026-09-10-2（双入口 flag 分歧）不与批次 1 混合。结构批次只迁移，并同步修改「两入口行为同构」注记措辞（H7）；flag 收敛留批次 2。

---

## Task 0: 盘点（基准已备，本计划附注）

文件：分析产出（勘探已完成，基准并入本计划文末「盘点结果」节）。
- 交付：文末三张表（切分映射、迁移影响面、路径改点清单），Task 1-6 依此执行。

---

## Task 1: 三轴迁移 + 组合根 + 清单分段守卫（零抽取）

文件：
- 移动：`src/arch/linux/ld/{elf.cr,resolve.cr,ld.cr}` 到 `src/format/elf/`；`{instr.cr,sizes.cr,regalloc.cr}` 到 `src/arch/x86_64/`；`core-x86.toml`（自 `src/arch/hit/`）到 `src/arch/x86_64/`；`{main.cr,_import.cr,Core.toml}` 到 `src/targets/x86_64-linux/`（组合根裁决，target triple 命名）
- 修改：`src/compiler/module.cr`（回退链加 4 项：`src/format/elf`、`src/arch/x86_64`、`src/os/linux`、`src/targets/x86_64-linux`，见基准第 2.3 节；置放序在既有条目前后，保持既有命中不变化）
- 修改：`build_selfhost_native.py`（corearch 清单 6 行路径改，并做分段重构：`common_files`/`kernel_files`/`arch_x86_64_files`/`format_elf_files`/`os_linux_files`/hit 段/`x86_linux_target_files`，组合序确定。守卫：清单文件存在性断言加构建日志 `error[` 计数非零即失败（TODO #2026-09-10-2 建议3））
- 修改：`tests/selfhost/test_backend_bootstrap.py:13`（BACKEND_SOURCE 改为组合根，先改后迁）加 `tests/selfhost/test_hit_table.py:28`（TABLE 改为 src/arch/x86_64/core-x86.toml）加 `tools/pseudocode_extract.py:6-7`（ROOTS 从 ld 改为三轴目录）
- 修改：注释同步（`instr.cr:2189` 表路径注、`src/arch/hit/hit.cr:2`、`lower_to_core.cr:44`、`src/stdlib/toml.cr:163`、`ld/main.cr:11-15` 两入口注记措辞（H7））
- 测试：全回归快子集加 stage 链

接口：
- 读取：盘点基准（文末表）
- 产出：三轴目录框架加组合根（stage0 = `corec build src/targets/x86_64-linux`）加分段清单
- 检查：stage 链 byte-identical 加 hit_table 24/24 加 compile 加抽检（文件内容零改动，纯重命名）

- [ ] Step 1: 先改 stage0 硬编码点（test_backend_bootstrap:13 改为组合根）加 module.cr 回退链加 4
- [ ] Step 2: 文件迁移（按依赖序，第 5.1 节第 0 步：format/arch/targets 并行）。`src/os/linux/` 空目录占位，Task 2 及之后使用
- [ ] Step 3: 清单分段重构加守卫（存在性加 error 计数）加 hit 表路径改点
- [ ] Step 4: 构建加 stage 链加 hit_table 加回归快子集（检查：全部通过）
- [ ] Step 5: 提交 `refactor: x86 实例化批次 1 Task 1：三轴目录迁移 + 组合根（src/targets/x86_64-linux）+ 清单分段守卫（零抽取）`

---

## Task 2: entry.cr 整体迁移（低风险）

文件：
- 移动：`elf.cr` 的 `emit_start`（858-959）加 `emit_start_size`（961-979）到 `src/os/linux/entry.cr`（整函数迁移。外部耦合是 gv_argc/gv_argv/gv_current_arena 索引全局，随迁暴露）
- 修改：`elf.cr`（调用点 1188 改为跨轴调用，回退链已备）

接口：
- 读取：Task 1 框架
- 检查：stage 链 byte-identical 加全回归快子集
- [ ] Step 1: 整函数迁移加调用点接入；Step 2: 构建加检查；Step 3: 提交 `refactor: x86 实例化批次 1 Task 2：emit_start 整体迁移到 src/os/linux/entry.cr`

---

## Task 3: frame.cr 抽取（H2 帧公式单源，批次 1 最大风险之一）

文件：
- 新建：`src/arch/x86_64/frame.cr`（导出三个入口：`pf_frame_size(vc)`，等于 mw_frame_size 加 dry-run 核算合并；`pf_prologue`，等于 Phase3 1228-1247 序言段；`pf_epilogue`，等于 1372-1392 尾声段，含 opt≥1 逆序 pop。形参落槽段（1248-1319）与 ret patch/sub rsp 回填段（1352-1370）随 prologue/epilogue 语义归并。具体切界以实现为准，原则是帧相关段全入 frame.cr）
- 修改：`elf.cr`（Phase 2 dry-run 1078-1113 与 Phase 3 1197-1442 两个调用点各接 `pf_frame_size`/`pf_prologue`/`pf_epilogue`，双源合并；`g2_tag_off`/`mw_frame_size` 从 instr.cr 迁入 frame.cr（H3））
- 修改：`instr.cr`（g2_tag_off/mw_frame_size 迁出，mw 族消费点引用调整）
- 检查：stage 链 byte-identical 加 `test_mw_task1.py`（sub rsp 立即数专项，帧公式错即失败）加全回归快子集
- [ ] Step 1: pf_frame_size 单源合并（dry-run 加 Phase3 两处改调，风险最高的一步单独验证）；Step 2: pf_prologue/pf_epilogue 抽取；Step 3: g2_tag_off/mw_frame_size 迁入；Step 4: 构建加 stage 链加 mw 套件；Step 5: 提交 `refactor: x86 实例化批次 1 Task 3：frame.cr 抽取（帧公式双源合并为单入口）`

---

## Task 4: tag2l.cr 整体迁移（mw 族纯编码）

文件：
- 移动：`instr.cr` 的 mw 族（144-637，除 g2_tag_off/mw_frame_size，已入 frame）到 `src/arch/x86_64/tag2l.cr`（e2_mw_jo/slow_block/t8/b8/ld8/st8/tag_clr/tag_cpy/oc_new/oc_check/ld2/sext/opnd_block 加 mw_setup_tags/mw_int_arith_jo_needed，整函数迁移）
- 注：elf.cr 慢块和 2L 块发射循环（1394-1441）随 frame 尾声（Task 3 已并入），本任务只迁移纯编码
- 检查：stage 链 byte-identical 加 mw1-6 全套加回归快子集
- [ ] Step 1: mw 族迁移（逐函数，两文件同轴）加消费点接入；Step 2: 构建加 mw 套件加 stage 链；Step 3: 提交 `refactor: x86 实例化批次 1 Task 4：tag2l.cr 整体迁移（mw 族纯编码）`

---

## Task 5: callseq.cr 抽取（H1 最大风险，emit_instr 内联段落）

文件：
- 新建：`src/os/linux/callseq.cr`（抽 5 个函数：`cs_args_dispatch`（寄存器参数分派，合并 IR_CALL 1201-1220、EXTERN 1443-1453、SPAWN 1488-1506 三处同源）/`cs_stack_args`（栈参右到左压，1221-1245 加 1507-1531）/`cs_stack_cleanup`（1414-1424 加 1538-1549）/`cs_ret_value`（IR_RETURN 值序列 1578-1611，含 tag 读路径）/`cs_call_direct`（通用调用 1389-1408））
- 修改：`instr.cr`（emit_instr 四处 `if op ==` 块改调，覆盖 IR_CALL/IR_CALL_EXTERN/IR_SPAWN/IR_RETURN）
- 检查：stage 链 byte-identical 加调用密集程序（fib 等，backend_bootstrap 快速验证加 compile）加回归快子集
- [ ] Step 1: cs_args_dispatch 三处同源抽取（风险最高，单独验证）；Step 2: cs_stack_args/cs_stack_cleanup/cs_call_direct；Step 3: cs_ret_value；Step 4: 构建加 stage 链加快速验证；Step 5: 提交 `refactor: x86 实例化批次 1 Task 5：callseq.cr 抽取（参数/栈/返回序列五函数，SysV 三处同源合并）`

---

## Task 6: syscall.cr 抽取

文件：
- 新建：`src/os/linux/syscall.cr`（`sys_syscall3_stub`/`sys_syscall4_stub`，instr.cr 1247-1268，r10 第四参注记随迁；builtin 名扫描段（elf.cr 990-1008）中 syscall 条目相关面。扫描段整体可以延后到参数化批次（设计第 1.4 节），本任务只抽发射两函数，扫描段保留原位加注）
- 修改：`instr.cr`（builtin 链改调）
- 检查：stage 链 byte-identical 加回归快子集
- [ ] Step 1: 两函数抽取加接入；Step 2: 构建加检查；Step 3: 提交 `refactor: x86 实例化批次 1 Task 6：syscall.cr 抽取（syscall3/4 内置体）`

---

## Task 7: 结束，全量回归 + 自举 + 文档

文件：
- 测试：全量回归（compile/backend_bootstrap/hit_table/region_cfg/mw1-6/slice_bounds/live_ranges/ccr_v7/bootstrap 三套加 full-bootstrap guard 加中立性 guard）
- 修改：设计 spec（`2026-09-10-x86-instance-design.md` 状态改为批次 1 已实施加执行注记）加计划状态行加 TODO #2026-09-10-2 注记同步（批次 1 已迁移未收敛）
- 测试：`nice -n 19 python3 build_selfhost_native.py` 重建加快速验证
- 检查：全部通过加文档同步
- [ ] Step 1: 全量回归；Step 2: 重建加快速验证；Step 3: 文档同步；Step 4: 提交 `refactor: x86 实例化批次 1 结束：全量回归 + 自举 + 文档同步`

---

## 风险注记

- H1 巨型函数切分（Task 3/5）：每段独立提交加 stage 链；cp/pos/buf 显式参数化。
- H2 帧公式双源（Task 3）：pf_frame_size 单源合并，首步单独验证；mw_task1 的 sub rsp 立即数断言是专项检查。
- H5 跨轴衔接点 6 处（elf 到 arch）：回退链是唯一通道，Task 1 Step 1 先完成。
- H6 stage0 硬编码先改后迁。
- H7 TODO #2026-09-10-2 不与批次 1 混合（仅注记措辞同步）。
- 文件内容零改动检查：迁移任务（Task 1/2/4/6）应使用重命名（内容 verbatim）；抽取任务（Task 3/5）内容进新文件加调用点替换。diff 可读性是评审基准。

---

## 盘点结果（勘探已备，2026-09-10）

> 基源为勘探基准清单（docs/archive/sdd 勘探产出，权威为设计 spec 第 2 节）。关键事实：elf.cr 1830 行 = elf_gen 单巨函数 982-1830（849 行）加 10 段体 helper；instr.cr 2588 行 = emit_instr 单巨函数 986-2183（1198 行）加 HIT 编码器 2185-2588 加 e2_* 原语 640-985 加 mw 族 144-637。全部序列算法内联，没有现成阶段函数。三表（切分映射、迁移影响面、路径改点）见勘探清单；Task 1-6 的 Files 节已内联全部行号基准。
