# x86 实例化 波 1（结构波）实施计划

> **状态：实施完成（2026-09-10 波 1 结构波 Task 1-7 收官）——落点：Task 0 盘点 327c2cf01af3（设计定稿 6694f358f376）/ Task 1 三轴搬迁 + 组合根 29d177ac49a5（+ 补正 c927525baf35、docs 58e6be3a1c18）/ Task 2 entry.cr 整搬 b23f008000cf（+ docs 8dcfaeca52b2）/ Task 3 frame.cr 抽取 b0ba8c1c9b01 / Task 4 tag2l.cr 整搬 d65fc1b8f3c3（+ docs c6b6cbfe9a75）/ Task 5 callseq.cr 抽取 3ab39f6eaa16（+ docs 525a872a0ba7）/ Task 6 syscall.cr 抽取 94d1ac15359（+ docs d2f3e0968d8c）/ Task 7 = 收官提交**。判据全绿：**行为零变化**（每任务 stage 链 byte-identical + 收官全量回归逐套计数）+ 自举重建冒烟 + full-bootstrap guard（corec2/corec3 cmp 同 + N06=0）+ syscall4 套件持久覆盖（`tests/suite/syscall4_test.cr`）——逐套计数与未做项见设计 spec `2026-09-10-x86-instance-design.md` §8 执行注记。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 三轴目录重组（架构 × 格式 × OS）+ 序列算法文件化 + 表数据迁架构轴 + 构建清单分段守卫——**行为零变化**（纯搬移/文件化，stage 链 byte-identical）。

**Architecture:** 序列算法现全部内联在 elf_gen（elf.cr 982-1830，849 行）与 emit_instr（instr.cr 986-2183，1198 行）两个巨型函数里——波 1 = 零抽取搬迁（Task 1）优先，随后逐类文件化（entry 整搬 → frame 抽取 → tag2l 整搬 → callseq 抽取 → syscall 抽取），**每任务独立提交 + stage 链 byte-identical 判据**（H1：抽取改变 cp/pos/buf 作用域——绝不合并多个抽取点）。组合根裁决 = `src/targets/x86_64-linux/`（target triple = 三轴组合的正式名）。

**Tech Stack:** elf.cr/instr.cr（拆分源）、module.cr 回退链、build_selfhost_native.py 清单、tests/selfhost/（判据套件）、tools/pseudocode_extract.py。

**设计 spec:** `docs/superpowers/specs/2026-09-10-x86-instance-design.md`（§2 三轴目录/§3 清单分段/§5 波 1/§6 挂账）。

## Global Constraints

- 版本控制 `jj`（铁律 #2）；每任务 `jj commit -m '<msg>'`
- 构建 `nice -n 19 python3 build_selfhost_native.py`；测试 `nice -n 19` 前缀（铁律 #6）；清 .core/cache
- **行为零变化硬约束**：每任务判据 = `test_backend_bootstrap.py` 11/11（stage 链 run 内 byte-identical）+ 相关套件（hit_table 24/24 表路径保持 / ccr_v7 24/24 / live_ranges 13/13 / compile）；收官全量
- **抽取纪律（H1）**：每抽一段 = 独立提交 + stage 链验证；抽段时 cp/pos/buf 三参数显式传递；**帧公式双源（H2）必须单入口**——`sizes.cr:4-10` 头注明令「NEVER hardcode byte counts」；`test_mw_task1.py` 的 sub rsp 立即数断言 = 帧专项判据
- 归属裁决（H3）：`g2_tag_off`/`mw_frame_size` 归 `frame.cr`；`tag2l.cr` 依赖 frame（同轴内）；mw 族 e2_mw_* 纯编码归 tag2l；e2_* 通用编码原语（640-985）**留 instr.cr**
- stage0 硬编码点 `test_backend_bootstrap.py:13` 必须先改后搬（H6）
- TODO #6（双入口 flag 分歧）**不与波 1 混合**——结构波只搬移 + 同步改「两入口行为同构」注记措辞（H7）；flag 收敛留波 2

---

## Task 0: 盘点（锚点已备——本计划附注）

**Files:** 分析产出（勘探已完成，锚点并入本计划文末「盘点结果」节）
- 交付：文末三张表（切分映射/搬迁影响面/路径改点清单）——Task 1-6 依此执行

---

## Task 1: 三轴搬迁 + 组合根 + 清单分段守卫（零抽取）

**Files:**
- Move: `src/arch/linux/ld/{elf.cr,resolve.cr,ld.cr}` → `src/format/elf/`；`{instr.cr,sizes.cr,regalloc.cr}` → `src/arch/x86_64/`；`core-x86.toml`（自 `src/arch/hit/`）→ `src/arch/x86_64/`；`{main.cr,_import.cr,Core.toml}` → `src/targets/x86_64-linux/`（组合根裁决——target triple 命名）
- Modify: `src/compiler/module.cr`（回退链 +4：`src/format/elf`、`src/arch/x86_64`、`src/os/linux`、`src/targets/x86_64-linux`——锚点 §2.3；置放序在既有条目前后保持既有命中不漂）
- Modify: `build_selfhost_native.py`（corearch 清单 6 行路径改 + **分段重构**：`common_files`/`kernel_files`/`arch_x86_64_files`/`format_elf_files`/`os_linux_files`/hit 段/`x86_linux_target_files`——组合序确定；**守卫**：清单文件存在性断言 + 构建日志 `error[` 计数非零 = 失败门（TODO #6 建议③））
- Modify: `tests/selfhost/test_backend_bootstrap.py:13`（BACKEND_SOURCE → 组合根——先改后搬）+ `tests/selfhost/test_hit_table.py:28`（TABLE → src/arch/x86_64/core-x86.toml）+ `tools/pseudocode_extract.py:6-7`（ROOTS 替换 ld → 三轴目录）
- Modify: 注释同步（`instr.cr:2189` 表路径注、`src/arch/hit/hit.cr:2`、`lower_to_core.cr:44`、`src/stdlib/toml.cr:163`、`ld/main.cr:11-15` 两入口注记措辞（H7））
- Test: 全回归快子集 + stage 链

**Interfaces:**
- Consumes: 盘点锚点（文末表）
- Produces: 三轴目录骨架 + 组合根（stage0 = `corec build src/targets/x86_64-linux`）+ 分段清单
- 判据: stage 链 byte-identical + hit_table 24/24 + compile + 抽检（文件内容零改动——R 重命名）

- [ ] **Step 1:** 先改 stage0 硬编码点（test_backend_bootstrap:13 → 组合根）+ module.cr 回退链 +4
- [ ] **Step 2:** 文件搬迁（按依赖序——§5.1 第 0 步：format/arch/targets 并行）——`src/os/linux/` 空目录占位（Task 2+ 使用）
- [ ] **Step 3:** 清单分段重构 + 守卫（存在性 + error 计数门）+ hit 表路径改点
- [ ] **Step 4:** 构建 + stage 链 + hit_table + 回归快子集（判据：全绿）
- [ ] **Step 5:** 提交 `refactor: x86 实例化波 1 Task 1——三轴目录搬迁 + 组合根（src/targets/x86_64-linux）+ 清单分段守卫（零抽取）`

---

## Task 2: entry.cr 整搬（低风险）

**Files:**
- Move: `elf.cr` `emit_start`（858-959）+ `emit_start_size`（961-979）→ `src/os/linux/entry.cr`（整函数——外部耦合 = gv_argc/gv_argv/gv_current_arena 索引全局，随迁暴露）
- Modify: `elf.cr`（调用点 1188 → 跨轴调用，回退链已备）

**Interfaces:**
- Consumes: Task 1 骨架
- 判据: stage 链 byte-identical + 全回归快子集
- [ ] **Step 1:** 整函数搬迁 + 调用点接线；**Step 2:** 构建 + 判据；**Step 3:** 提交 `refactor: x86 实例化波 1 Task 2——emit_start 整搬 src/os/linux/entry.cr`

---

## Task 3: frame.cr 抽取（H2 帧公式单源——波 1 最大风险之一）

**Files:**
- Create: `src/arch/x86_64/frame.cr`（导出三入口：`pf_frame_size(vc)`（= mw_frame_size + dry-run 核算合流）/`pf_prologue`（= Phase3 1228-1247 序言段）/`pf_epilogue`（= 1372-1392 尾声段，含 opt≥1 逆序 pop）；形参落槽段（1248-1319）与 ret patch/sub rsp 回填段（1352-1370）随 prologue/epilogue 语义归并——**具体切界以实现为准,原则 = 帧相关段全入 frame.cr**）
- Modify: `elf.cr`（Phase 2 dry-run 1078-1113 与 Phase 3 1197-1442 双调用点各接 `pf_frame_size`/`pf_prologue`/`pf_epilogue`——**双源合流**；`g2_tag_off`/`mw_frame_size` 自 instr.cr 迁入 frame.cr（H3））
- Modify: `instr.cr`（g2_tag_off/mw_frame_size 迁出——mw 族消费点引用调整）
- 判据: stage 链 byte-identical + `test_mw_task1.py`（sub rsp 立即数专项——帧公式错即红）+ 全回归快子集
- [ ] **Step 1:** pf_frame_size 单源合流（dry-run + Phase3 两处改调——最险一步单独验证）；**Step 2:** pf_prologue/pf_epilogue 抽取；**Step 3:** g2_tag_off/mw_frame_size 迁入；**Step 4:** 构建 + stage 链 + mw 套件；**Step 5:** 提交 `refactor: x86 实例化波 1 Task 3——frame.cr 抽取（帧公式双源合流单入口）`

---

## Task 4: tag2l.cr 整搬（mw 族纯编码）

**Files:**
- Move: `instr.cr` mw 族（144-637，除 g2_tag_off/mw_frame_size 已入 frame）→ `src/arch/x86_64/tag2l.cr`（e2_mw_jo/slow_block/t8/b8/ld8/st8/tag_clr/tag_cpy/oc_new/oc_check/ld2/sext/opnd_block + mw_setup_tags/mw_int_arith_jo_needed——**整函数搬**）
- 注: elf.cr 慢块/2L 块发射循环（1394-1441）随 frame 尾声（Task 3 已并）——本任务只搬纯编码
- 判据: stage 链 byte-identical + mw1-6 全套 + 回归快子集
- [ ] **Step 1:** mw 族搬迁（逐函数,两文件同轴）+ 消费点接线；**Step 2:** 构建 + mw 套件 + stage 链；**Step 3:** 提交 `refactor: x86 实例化波 1 Task 4——tag2l.cr 整搬（mw 族纯编码）`

---

## Task 5: callseq.cr 抽取（H1 最大风险——emit_instr 内联段落）

**Files:**
- Create: `src/os/linux/callseq.cr`（抽 5 函数：`cs_args_dispatch`（寄存器参数分派——IR_CALL 1201-1220 + EXTERN 1443-1453 + SPAWN 1488-1506 三处同源合流）/`cs_stack_args`（栈参右到左压——1221-1245 + 1507-1531）/`cs_stack_cleanup`（1414-1424 + 1538-1549）/`cs_ret_value`（IR_RETURN 值序列 1578-1611，含 tag 读路径）/`cs_call_direct`（通用调用 1389-1408））
- Modify: `instr.cr`（emit_instr 四处 `if op ==` 块改调——IR_CALL/IR_CALL_EXTERN/IR_SPAWN/IR_RETURN）
- 判据: stage 链 byte-identical + 调用密集程序（fib 等——backend_bootstrap 冒烟 + compile）+ 回归快子集
- [ ] **Step 1:** cs_args_dispatch 三处同源抽取（最险——单独验证）；**Step 2:** cs_stack_args/cs_stack_cleanup/cs_call_direct；**Step 3:** cs_ret_value；**Step 4:** 构建 + stage 链 + 冒烟；**Step 5:** 提交 `refactor: x86 实例化波 1 Task 5——callseq.cr 抽取（参数/栈/返回序列五函数,SysV 三处同源合流）`

---

## Task 6: syscall.cr 抽取

**Files:**
- Create: `src/os/linux/syscall.cr`（`sys_syscall3_stub`/`sys_syscall4_stub`（instr.cr 1247-1268——r10 第四参注记随迁）；builtin 名扫描段（elf.cr 990-1008）中 syscall 条目相关面——**扫描段整体可延后参数化波**（设计 §1.4——本任务只抽发射两函数,扫描段保留原位加注）
- Modify: `instr.cr`（builtin 链改调）
- 判据: stage 链 byte-identical + 回归快子集
- [ ] **Step 1:** 两函数抽取 + 接线；**Step 2:** 构建 + 判据；**Step 3:** 提交 `refactor: x86 实例化波 1 Task 6——syscall.cr 抽取（syscall3/4 内置体）`

---

## Task 7: 收官——全量回归 + 自举 + 文档

**Files:**
- Test: 全量回归（compile/backend_bootstrap/hit_table/region_cfg/mw1-6/slice_bounds/live_ranges/ccr_v7/bootstrap 三套 + full-bootstrap guard + 中立性 guard）
- Modify: 设计 spec（`2026-09-10-x86-instance-design.md` 状态 → 波 1 已实施 + 执行注记）+ 计划状态行 + TODO #6 注记同步（波 1 已搬未收敛）
- Test: `nice -n 19 python3 build_selfhost_native.py` 重建 + 冒烟
- 判据: 全绿 + 文档同步
- [ ] **Step 1:** 全量回归；**Step 2:** 重建 + 冒烟；**Step 3:** 文档同步；**Step 4:** 提交 `refactor: x86 实例化波 1 收官——全量回归 + 自举 + 文档同步`

---

## 风险注记

- H1 巨型函数切分（Task 3/5）：每段独立提交 + stage 链；cp/pos/buf 显式参数化
- H2 帧公式双源（Task 3）：pf_frame_size 单源合流 = 首步单独验证；mw_task1 sub rsp 立即数断言 = 专项判据
- H5 跨轴缝 6 处（elf → arch）：回退链是唯一通道——Task 1 Step 1 先落
- H6 stage0 硬编码先改后搬
- H7 TODO #6 不与波 1 混合（仅注记措辞同步）
- 文件内容零改动判据：搬迁任务（Task 1/2/4/6）应 R 重命名（内容 verbatim）；抽取任务（Task 3/5）内容进新文件 + 调用点替换——diff 可读性 = 评审锚

---

## 盘点结果（勘探已备——2026-09-10）

> 基源 = 勘探锚点清单（.superpowers/sdd 勘探产出,权威 = 设计 spec §2）。关键事实：**elf.cr 1830 行 = elf_gen 单巨函数 982-1830（849 行）+ 10 段体 helper；instr.cr 2588 行 = emit_instr 单巨函数 986-2183（1198 行）+ HIT 编码器 2185-2588 + e2_* 原语 640-985 + mw 族 144-637**——全部序列算法内联，无现成阶段函数。三表（切分映射/搬迁影响面/路径改点）见勘探清单（Task 1-6 的 Files 节已内联全部行锚）。
