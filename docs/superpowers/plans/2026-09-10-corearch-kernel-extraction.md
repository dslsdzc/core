# corearch 内核抽取实施计划（范式无关内核 + 实例定制——演进序步骤 2）

> **状态：待执行（2026-09-10 计划定稿）**
> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 从 corearch 的 regalloc.cr 抽出范式无关内核（语义判定引擎 + 条目/区间数据面 + 注册契约最小面），机器侧（CAG 分配/meta 写入）留 x86 实例——行为零变化（判定语义不动只搬家）。

**Architecture:** 纯代码搬移 + 单源化收敛 + 最小契约形式化。数据面（g_ir_live_ranges/g_ir_entries = globals.cr 共享声明）已 = 结构化语义对象；判定引擎（共存/规则①②）不读值内容、不含寄存器名/ABI 常量（硬编码点全在 alloc_registers 阶段 1/2/4 与 meta 写入 = 机器侧）；判定→机器侧唯一读通道 = meta_reg_for_var（分配输出输入通道，随判定搬）。双转录第三处（ccr_io.cr compute_entries_v7 写侧镜像）借共享文件约束单源化（corec 与 corearch 共用 globals——内核文件进双 concat 后 corec 写侧直调内核 compute_entries，删镜像）。

**Tech Stack:** src/arch/linux/ld/regalloc.cr（1560 行——拆分源）、src/compiler/ccr_io.cr（loader/写侧）、src/compiler/globals.cr + dyn_arr.cr + ast.cr（共享声明）、build_selfhost_native.py（双 concat 清单）、Python 测试（test_live_ranges.py 13 判据锚 + test_ccr_v7.py 23/23 写侧判据）。

**设计 spec:** `docs/superpowers/specs/2026-09-09-corearch-rewrite-design.md`（§2 裁决表——语义侧 → 内核/机器侧 → x86 实例；§3 演进序步骤 2 = 本计划执行依据）。

## Global Constraints

- 版本控制 `jj`（铁律 #2，git 被 hook 拦截）。每任务 `jj commit -m '<msg>'`
- 构建 `nice -n 19 python3 build_selfhost_native.py`（约 2-3 分钟）；测试 `nice -n 19` 前缀（铁律 #6）；清 .core/cache 跑测试
- **行为零变化硬约束**：判定语义不动只搬家——判据 = test_live_ranges.py 13/13（判定绿/红路径 + dump 通道输出不变）+ test_ccr_v7.py 23/23（写侧单源化后产物 byte-identical）+ 回归面（compile/backend_bootstrap/hit_table/region_cfg/mw1-6/slice_bounds/bootstrap 三套——Task 收官全量）
- **搬移纪律**：逐函数搬移零改动（函数体 byte-identical 搬入新文件——除去重收敛点）；禁止顺手改语义/加接口抽象（蓝图"判定语义不动只搬家"——资源域参数化/双向注册契约 = 后续步骤，非本计划）
- 共享文件约束：globals.cr/dyn_arr.cr/ast.cr/ccr_io.cr 进双二进制；regalloc.cr 只在 corearch concat；新内核文件若需 corec 侧（写侧单源化）→ 进双 concat
- 判定③④ 无实现（文档化 TODO——静态放置无驱逐事件/callee-saved 平凡满足）——本计划不补实现
- src/arch/linux/ld/main.cr = 死代码遗留（零 concat 引用）——本计划不处理（删除待核挂账）

---

## Task 1: 语义侧搬移——新内核文件 + 数据面/判定引擎纯搬

**Files:**
- Create: `src/arch/linux/ld/ent_kernel.cr`（内核——语义判定引擎 + 条目/区间数据面；文件头注：范式无关——不读值内容、无寄存器名/ABI 常量/编码知识）
- Modify: `src/arch/linux/ld/regalloc.cr`（语义侧函数删除 → 调内核；保留机器侧）
- Modify: `build_selfhost_native.py`（corearch concat 加 ent_kernel.cr）

**Interfaces:**
- 搬入内核的函数（regalloc.cr 现位 → ent_kernel.cr，逐函数零语义改动）：
  - 数据面：grow_live_ranges (:18)/live_range_slot (:25)/live_first (:35)/live_last (:40)/compute_live_ranges (:48)/grow_entries (:139)/grow_func_entry_meta (:146)/ent_off/ent_var/ent_def/ent_live_start/ent_live_end/ent_home/ent_flags (:161-167)/entry_start (:170)/entry_count (:175)/compute_entries (:180-268)
  - 共存：entries_coexist (:364)/coexist_version_conflicts (:380)/coexist_home_conflicts (:411)
  - sweep 门禁：rl_rec_lt (:515)/rl_merge_sort (:525)
  - 诊断：dump_entries_summary (:314)/dump_coexist_summary (:440)/rl_print_loc (:576)/rl_func_name (:584)——注意 rl_print_loc 内 x86 注释（:580 "3=rbx"）随搬（注释层——本计划不清理，注记待后续）
  - 常量：LOC_HOME_BASE (:486)（位置编码约定 = 判定与实例的共享 seam——**裁决修正（Task 1 实证）：单份随判定搬内核**——concat 单编译单元下自举 NameResolver 拒重复顶层声明（name_resolver.py:73 无去重守卫 + symbol_table.py:28 NameError），且机器侧实证零引用）
- 保留 regalloc.cr（机器侧）：meta_reg_for_var (:491——**裁决：随判定搬入内核**——它是判定输入通道（verify 读分配输出），纯读取；meta_set/append/remove/reg_assign_total (:849-936) 留实例侧（写入 = 实例动作）；alloc_registers (:1136-1560) 留；注入钩子 (:805-1125) 留（注入 = 改分配结果 → 属实例侧测试通道）；ir_op_kind_name (:278) 留（dump 诊断公共，或随搬——裁决：留 regalloc.cr，两文件同 concat 可互调）
- verify 判定面（规则①②合成）——**裁决：本任务搬 verify_regalloc_consistency (:693-781)/rl_rule2_func (:624)/rl_report_rule1/2 (:590/:602)/regalloc_verify_all (:785)**：它们读 meta_reg_for_var（已随判定搬内核）——搬移后 verify 全在内核；regalloc.cr 机器侧经 alloc_registers 尾/外部调用内核 verify（现调用点 corearch.cr:69/:163 不变——函数名不变即可）
- 判据：test_live_ranges.py 13/13 + 回归快子集（O2 check-regalloc 路径绿——corearch.cr 调用点签名不变）

- [ ] **Step 1:** 建 ent_kernel.cr（文件头 + 搬移函数骨架——先搬数据面 grow/live/ent accessor + compute_live_ranges/compute_entries）
- [ ] **Step 2:** corearch concat 加 ent_kernel.cr；构建确认无符号冲突（函数跨文件调用 OK——concat 单编译单元）
- [ ] **Step 3:** 搬共存/sweep/诊断/dump 函数
- [ ] **Step 4:** 搬 verify 判定面（meta_reg_for_var + rl_* + verify_*）
- [ ] **Step 5:** regalloc.cr 删已搬函数（保留机器侧 + 对外调用面）；构建 + test_live_ranges 13/13（判据：dump-entries/coexist 输出与搬移前逐字节同——先跑基线再跑搬移后对照）
- [ ] **Step 6:** 回归快子集（compile/backend_bootstrap/hit_table/region_cfg）
- [ ] **Step 7:** 提交 `refactor: 内核抽取 Task 1——语义侧搬移 ent_kernel.cr（判定引擎 + 数据面纯搬,零语义改动）`

---

## Task 2: 写侧单源化——compute_entries_v7 镜像消除

**Files:**
- Modify: `src/compiler/ccr_io.cr`（删 compute_entries_v7 :458-579 + ccr_grow_entries/ccr_grow_func_entry_meta :419-433 + 局部 lr 表机制——写侧直调内核 compute_entries/compute_live_ranges; save_ccr ENT 写调用点 :611 适配）
- Modify: `src/arch/linux/ld/regalloc.cr` + `src/arch/linux/ld/ent_kernel.cr`（**迁 RPT_MAX + ir_op_kind_name 自 regalloc.cr 入 ent_kernel.cr**——Task 1 评审 Important: 两声明机器侧零剩余使用（ir_op_kind_name 唯一调用方 = 内核 dump_entries_summary; RPT_MAX 唯一使用方 = 内核 rl_rule2_func/verify_regalloc_consistency），regalloc.cr 不在 corec concat → 内核进 corec concat 前不迁则 corec 构建解析失败; 迁移零风险）
- Modify: `build_selfhost_native.py`（**ent_kernel.cr 进 corec concat**——corec 二进制需要内核 compute_entries）
- Test: `tests/selfhost/test_ccr_v7.py`（23/23——ENT 实记录产物 byte-identical 判据）

**Interfaces:**
- 内核 compute_entries/compute_live_ranges 现用全局 g_ir_live_ranges/g_ir_entries（globals.cr 共享声明——corec 进程内可用；corec 侧时序：save 前调用（main.cr ccr/build 路径 lower_to_ccr 后）——compute_live_ranges 扫 g_ir_instrs（lower 后 = df 镜像）同 corearch 语义）
- 差异消解（Task 0 勘探注记）：①表载体（ccr_io 局部 lr → 内核全局 g_ir_live_ranges——corec 侧 grow/init 检查）②整表重置时序（compute_entries func_i==0 分支 vs compute_entries_v7 函数头清零——统一为内核语义）③grow 单实例（删 ccr_* 副本）④半开转换（写侧盘布局 +1 逻辑保留在 ccr_io 写点——内核算闭区间,写盘转换归 ccr_io）
- 判据：test_ccr_v7.py 23/23（含 ENT 手算期望/独立模型 replay——产物与 Task 2 原实现 byte-identical 即镜像消除无损）+ test_live_ranges 13/13（corearch 侧不动）

- [ ] **Step 1:** RPT_MAX + ir_op_kind_name 迁入 ent_kernel.cr（自 regalloc.cr——Task 1 评审 Important 携带）→ corec concat 加 ent_kernel.cr；构建（corec 二进制含内核）
- [ ] **Step 2:** ccr_io 写侧适配：save ENT 前调内核 compute_live_ranges + 逐函数 compute_entries（func_i 循环——内核 compute_live_ranges 尾部已逐 func 调 compute_entries：直接调 compute_live_ranges 即可）→ 写盘（半开转换保留）
- [ ] **Step 3:** 删 compute_entries_v7/ccr_grow_*/局部 lr 机制（ccr_param_entry_id/ccr_ent_* 访问器如仍被 loader/写侧用则保留——按实际引用删）
- [ ] **Step 4:** test_ccr_v7.py 23/23 绿（产物 byte-identical——若差异：先比对 ENT 段,差异 = 单源化语义偏差,修内核调用序而非弯判据）
- [ ] **Step 5:** 回归快子集
- [ ] **Step 6:** 提交 `refactor: 内核抽取 Task 2——写侧单源化（compute_entries_v7 镜像消除,双转录 R5 收敛）`

---

## Task 3: 注册契约最小面——实例声明表 + 内核引导

**Files:**
- Modify: `src/compiler/corearch.cr`（分派形式化：三路分派（--table×opt 门/--opt-level/O2 verify/调试 flag）→ 实例声明表 + 表驱动 dispatch）
- Modify: `ent_kernel.cr`（内核入口函数族：kern_ 前缀导出——kern_compute_entries/kern_verify_all/kern_dump_* 封装现函数名；实例能力声明数据结构/注册函数最小面）
- Test: `tests/selfhost/test_live_ranges.py`（13/13——flag 通道输出不变）

**Interfaces:**
- 实例声明表最小形态（Core 无高阶函数——数据表 + switch 分派）：
  - `g_instance_decl : {id i32, name str_idx, opt_min i32, opt_max i32, allow_table i32, allow_link i32, needs_alloc i32, needs_verify i32}` × n（表数据 = x86 实例声明 + 表模式路径声明——表模式 = 独立实例路径雏形（蓝图 §2 表裁决））
  - 引导：corearch_main 读 flag → 查表选实例（现三路分派逻辑收敛为表查询 + switch 调用）
  - 内核入口：现有函数名加 kern_ 别名或直接以现名作为内核 API（裁决：现名即 API——加头注"内核接口面 = 本文件函数集",不加包装层——YAGNI）
- 行为判据：flag 测试通道输出逐字节不变（dump-entries/coexist/check-regalloc 全同）——纯形式化重构
- **范围克制注**：本任务 = 最小面（声明表 + 引导收敛）——资源域代数参数化（判定读 g_opt_meta 的耦合）/双向契约（判定结果回填 home）= 蓝图后续步骤,本计划不做（Global Constraints 搬移纪律）

- [ ] **Step 1:** 内核头注 + 接口面声明（kern_ API 面 = 现函数集,文档化——不动代码）
- [ ] **Step 2:** 实例声明表（corearch.cr 数据 + 查询函数）
- [ ] **Step 3:** 三路分派收敛为表驱动 dispatch（--check-regalloc 顺序 :58-75 保序: 强制 O2 → alloc → 看门狗 → 注入 → verify_all——行为不变）
- [ ] **Step 4:** test_live_ranges 13/13 + 回归快子集
- [ ] **Step 5:** 提交 `feat: 内核抽取 Task 3——注册契约最小面（实例声明表 + 表驱动分派,行为不变）`

---

## Task 4: 收官——全量回归 + 自举重建 + 文档/台账

**Files:**
- Test: 全量回归面（compile/backend_bootstrap/hit_table/region_cfg/mw1-6/slice_bounds/live_ranges/ccr_v7 + bootstrap 三套）
- Modify: `docs/superpowers/specs/2026-09-09-corearch-rewrite-design.md`（§2 裁决表执行状态注记 + 步骤 2 完成标记;新发现注记: 判定→meta 读通道随判定入内核/写入留实例——注册契约需双向的勘探发现）
- Modify: `src/arch/linux/ld/main.cr` 死代码注记（删除待核挂账——TODO 或删除 = 本任务裁决：**只注记不删**——非本计划范围确认）
- Test: `nice -n 19 python3 build_selfhost_native.py` 重建 + 冒烟（corec check/run 小样本 + backend_bootstrap stage 链）

**Interfaces:**
- Consumes: Task 1-3 全部
- 验证: 全量回归绿 + 自举重建冒烟;文档同步（蓝图步骤 2 完成、裁决表状态、双转录收敛注记 R5 消除）;progress 台账

- [ ] **Step 1:** 全量回归跑批
- [ ] **Step 2:** 自举重建 + 冒烟
- [ ] **Step 3:** 文档同步（蓝图状态/裁决表/新发现注记——判定→meta 读通道方向、grow/accessor 收敛成果、rl_print_loc x86 注释待清挂账）
- [ ] **Step 4:** 提交 `docs: 内核抽取收官——蓝图步骤 2 完成 + 全量回归 + 文档同步`

---

## 风险注记

- Task 1 为最大风险（搬移 30+ 函数跨文件）——判据 = dump/verify 输出与搬移前逐字节同（先基线后对照）；逐函数零改动纪律防语义漂移
- 双 concat 符号共享：ent_kernel.cr 进 corec concat（Task 2）时,ccr_io 内残留同名函数（ccr_grow_* 等已删）——删除完整性以构建 + 测试判
- LOC_HOME_BASE = 单份随判定入内核（裁决修正——双份不可构建 + 机器侧零引用实证; 实例 seam 常量单源化 = 注册契约参数化步骤的天然内容——届时实例侧经内核导出访问）
- corec 侧 compute_live_ranges 首次运行时序（g_ir_live_ranges grow/init——corec 进程 init_df 无此表初始化? globals 声明即零态——compute 前自 grow——与 corearch 同路径,回归验证）
- 判定③④ 无实现不补（Global Constraints）——verify 覆盖 = 规则①②,test_live_ranges 现有绿/红路径即判据锚
