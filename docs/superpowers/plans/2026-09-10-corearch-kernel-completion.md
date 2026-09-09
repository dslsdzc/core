# corearch 内核组件完备化实施计划（步骤 2.5）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 内核三组件按蓝图 §1.1 补完——语义对象模型（对象面 API + 调度重建移实例）、判定中立化（登记表通道 + 位置域声明化）、注册契约完整（资源域代数 + ③④ 形式声明 + 双向输出面）——行为零变化。

**Architecture:** 现状（步骤 2 收官态）= ent_kernel.cr（判定引擎 + 数据面，双 concat）+ regalloc.cr（机器侧）+ 实例声明表。本计划 = 三组件完备：loader 收敛为对象产出（线性重建段搬实例侧 build_linear_schedule）；判定读通道从 g_opt_meta 直读切换为内核登记表（实例写完 g_opt_meta 后经 kern_loc_* API 登记——双份视图同步责任在实例）；LOC_HOME_BASE/域参数随实例声明；③④ 形式声明不实现。判据 = 行为零变化（全回归 + byte-identical 面）+ test_live_ranges 13/13 经新通道同输出 + 中立性静态 guard。

**Tech Stack:** ent_kernel.cr（内核）、regalloc.cr（实例机器侧）、ccr_io.cr（loader 收敛）、corearch.cr（引导/实例侧调用）、build_selfhost_native.py、Python 测试（test_live_ranges.py/test_ccr_v7.py 判据锚）。

**设计 spec:** `docs/superpowers/specs/2026-09-10-corearch-kernel-completion-design.md`（本计划执行依据——§1 对象模型/§2 中立化/§3 契约/§4 判据/§6 挂账）。

## Global Constraints

- 版本控制 `jj`（铁律 #2，git 被 hook 拦截）。每任务 `jj commit -m '<msg>'`
- 构建 `nice -n 19 python3 build_selfhost_native.py`（约 2-3 分钟）；测试 `nice -n 19` 前缀（铁律 #6）；清 .core/cache 跑测试
- **行为零变化硬约束**：全回归绿 + byte-identical 面（backend_bootstrap stage 链 + ccr_v7 产物）——重建移实例/登记表通道 = 纯搬移 + 通道等价，产物不变
- **搬移/改动纪律**：函数体搬移零改动；登记表通道切换 = 语义等价改写（禁止顺手改判定逻辑）；禁止新增接口抽象（现名即 API 裁决延续——新增面 = kern_loc_*/对象面访问器 = 设计 spec 明列者）
- **中立性目标**：ent_kernel.cr 零实例符号引用（g_opt_meta/寄存器名/ELF 段名——Task 4 静态 guard 入回归面）
- corec 写侧不受影响（不经 loader）；interp 不经 loader
- 判定③④ 不实现（用户裁决——needs_* 形式声明字段落契约）

---

## Task 0: 盘点——对象面/移出面的依赖核对（计划锚点）

**Files:** 分析产出（无代码改动——注记回填计划附注）
- 核对 load_ccr 内 NOD→g_ir_instrs 重建段的**完整依赖面**：重建段消费/写哪些全局（g_ir_instrs/g_ir_func_instr_*/g_label_*/g_v7 边缓冲/nod_edge_meta 暂存）；GC-3 root span 上界校验消费什么（nod_count vs instr 流——确认移出后守卫仍成立）；ENT 校验依赖线性流吗（evr/els/ele 界 = NOD 坐标——确认）；loader 内其余段（STR/SYM/REG）与重建段的顺序依赖
- **节点→区域映射（region_of_nod）定夺**：v7 文件无 g_df_node_region——loader 现是否重建（REG enter/exit 端点推导）？对象面 API 是否含 region_of_nod（含 = 重建推导; 不含 = 区域面仅 REG 行遍历）——**产出定夺注记**
- 登记表接入面核对：alloc_registers phase 5（写 g_opt_meta 点）+ 注入钩子 6+1（写点清单）+ regalloc_debug_dispatch 各 flag 路径（判定何时读登记表——compute 后/alloc 后时序）——登记 API 调用点清单
- 判定读 meta 面清单：verify_regalloc_consistency/rl_rule2_func/meta_reg_for_var 的 g_opt_meta 读点全集——登记表切换的精确函数面
- 中立性 guard 设计：ent_kernel.cr 现引用面扫描（g_opt_meta 引用点 = 待切清单; 其余实例符号 = 断言排除集）
- 交付：注记回填本 plan 附注「Task 0 盘点结果」节

---

## Task 1: 语义对象模型——对象面 API + 调度重建移实例

**Files:**
- Modify: `src/compiler/ccr_io.cr`（load_ccr：NOD→g_ir_instrs 重建段移出——loader 产出 = 对象载入 + 守卫; 重建相关写点清理）
- Modify: `src/arch/linux/ld/regalloc.cr` 或新实例函数位（`build_linear_schedule()`——重建段函数体搬移——corearch concat 内实例侧; corearch.cr 发射前置调用）
- Modify: `src/arch/linux/ld/ent_kernel.cr`（对象面 API：nod 面访问器 + v7_edge 访问器 + 配方查询薄封装——见设计 spec §1.2; 若 Task 0 定夺 region_of_nod = 含 → 区域推导访问器）
- Modify: `src/compiler/corearch.cr`（load 后调 build_linear_schedule）
- Test: `tests/selfhost/test_ccr_v7.py`（23/23 保持——对象面新测试：EDG 配方可读断言——节点出边遍历 vs v7 Task 0 表一去幽灵后期望复用）

**Interfaces:**
- Consumes: Task 0 依赖面清单
- Produces: 对象面 API（nod_op/nod_dest/nod_s1-3/nod_tk/nod_edge_first/count/v7_edge_to/kind——ent_kernel 内核面）;`build_linear_schedule()`（实例面——从对象重建 g_ir_instrs）
- 判据：ccr_v7 23/23 + backend_bootstrap stage 链 byte-identical（重建产物同——纯搬移）+ 回归快子集
- loader 守卫强度不变（段表/拓扑/root span/ENT 双写——Task 0 确认的守卫面）

- [ ] **Step 1:** 写失败测试：对象面 EDG 配方读断言（节点出边遍历 = 已知小程序期望——现无 API → FAIL）
- [ ] **Step 2:** 跑测试确认失败
- [ ] **Step 3:** 对象面 API 实现（ent_kernel——nod/edge 访问器 + 配方查询; region_of_nod 按 Task 0 定夺）
- [ ] **Step 4:** 重建段移出：load_ccr 清理 + build_linear_schedule 落实例侧 + corearch 调用接线（load 后、发射前）
- [ ] **Step 5:** 测试绿（对象面新断言 + ccr_v7 23/23 + backend_bootstrap stage byte-identical）+ 回归快子集
- [ ] **Step 6:** 提交 `feat: 内核完备 Task 1——语义对象模型（对象面 API + 调度重建移实例）`

---

## Task 2: 判定中立化——登记表通道 + 位置域声明化

**Files:**
- Modify: `src/arch/linux/ld/ent_kernel.cr`（位置登记表 {entry→loc} + kern_loc_assign/kern_loc_clear/kern_loc_of; verify 规则①② 读通道切换（meta_reg_for_var 改读登记表——函数体等价改写）; LOC_HOME_BASE 常量移除 → 域参数读实例声明（或经 kern 设置函数——设计 spec §2.2: 位置分类按实例声明域 {home_base, reg_domain}——内核读声明数据（g_instance_decl 扩展先行? 依赖 Task 3 声明扩展——**顺序裁决：域参数先经内核设置面（kern_set_loc_domain(home_base, reg_domain)——corearch 引导按实例行调）落地, Task 3 声明表字段接同一数据源**））
- Modify: `src/arch/linux/ld/regalloc.cr`（alloc_registers phase 5 + 注入钩子写 g_opt_meta 后调 kern 登记/清除——双面同步; meta_reg_for_var 删（判定不再读 g_opt_meta）——确认 emit 面无引用（instr.cr get_reg_for_var = 独立实现——已核））
- Test: `tests/selfhost/test_live_ranges.py`（13/13——判定红/绿路径经登记表通道输出与直读时代逐字节同）+ test_ccr_v7.py 23/23

**Interfaces:**
- Consumes: Task 0 登记 API 调用点清单 + Task 1 对象面
- Produces: kern_loc_assign/clear/of; kern_set_loc_domain; 登记表（内核数据）
- 判据：test_live_ranges 13/13（通道切换输出同——先基线后对照）+ O2 全链 byte-identical（--check-regalloc 绿/红路径经登记通道）+ 回归快子集
- 双份同步纪律：实例写点成对（g_opt_meta + 登记）——代码注记 + 注入钩子测试覆盖（红路径 = 双面一致注入）

- [ ] **Step 1:** 写失败测试：登记表 API + 域参数（kern_loc_assign/domain——现无 → FAIL）
- [ ] **Step 2:** 跑测试确认失败
- [ ] **Step 3:** 登记表 + kern API 实现（ent_kernel）
- [ ] **Step 4:** 判定读通道切换（verify/rl_rule2 读登记表——等价改写）; LOC_HOME_BASE 域参数化（kern_set_loc_domain + 引导调用——corearch 按实例行传域）
- [ ] **Step 5:** 实例侧双面同步（alloc phase 5/注入钩子 → g_opt_meta + kern 登记成对）
- [ ] **Step 6:** 测试绿（live_ranges 13/13 通道输出同 + ccr_v7 23/23 + O2 byte-identical）+ 回归快子集
- [ ] **Step 7:** 提交 `feat: 内核完备 Task 2——判定中立化（登记表通道 + 位置域声明化, g_opt_meta 直读解除）`

---

## Task 3: 注册契约完整化——声明扩展 + ③④ 形式声明 + 输出面

**Files:**
- Modify: `src/compiler/corearch.cr`（g_instance_decl 行扩展: home_base/reg_domain/needs_eviction/needs_call_sites 字段 + 行数据（x86: {10⁶, 16, 0, 0}; 表路径行: 同域或 0——盘点定）; 引导按实例行调 kern_set_loc_domain（或声明表 = kern 域数据源——与 Task 2 接缝一致））
- Modify: `src/arch/linux/ld/ent_kernel.cr`（判定结果输出面形式化——kern_verify_all 命名确认 + 共存证据查询面确认 = 现函数集即 API 注记）;③④ 形式声明字段文档（不实现注记）
- Test: `tests/selfhost/test_live_ranges.py`（13/13——flag 通道输出不变）+ flag 组合面

**Interfaces:**
- Consumes: Task 2 登记/域面
- Produces: 实例声明完整行（能力 + 资源域代数 + ③④ 形式声明）; 域数据源 = 声明表
- 判据：flag 通道输出逐字节不变 + test_live_ranges 13/13 + 回归快子集

- [ ] **Step 1:** 声明行扩展 + 域数据源接线（corearch 引导 → kern_set_loc_domain 或声明表直供——与 Task 2 接缝一致）
- [ ] **Step 2:** ③④ 形式声明字段 + 文档注记（引擎不实现——设计 spec §3.2 引用）
- [ ] **Step 3:** 输出面形式化注记（kern_verify_all/共存证据 = 现名即 API——注释层）
- [ ] **Step 4:** test_live_ranges 13/13 + 回归快子集
- [ ] **Step 5:** 提交 `feat: 内核完备 Task 3——注册契约完整化（资源域代数 + ③④ 形式声明 + 输出面注记）`

---

## Task 4: 收官——中立性 guard + 全量回归 + 自举 + 文档

**Files:**
- Test: 中立性静态 guard 新建（ent_kernel.cr 零实例符号断言——g_opt_meta/寄存器名/ELF 段名; 脚本或 Python 测试——设计 spec §4.3）入回归面
- Test: 全量回归（compile/backend_bootstrap/hit_table/region_cfg/mw1-6/slice_bounds/live_ranges/ccr_v7/bootstrap 三套 + full-bootstrap guard）
- Modify: `docs/superpowers/specs/2026-09-10-corearch-kernel-completion-design.md`（状态 → 已实施 + 执行注记回填——含 Task 0 定夺（region_of_nod）/登记表双份纪律实证/③④ 声明落点）
- Modify: `docs/superpowers/specs/2026-09-09-corearch-rewrite-design.md`（步骤 2.5 完成注记 + §1.1 三组件完成态）
- Test: `nice -n 19 python3 build_selfhost_native.py` 重建 + 冒烟

**Interfaces:**
- Consumes: Task 1-3 全部
- 验证: 中立性 guard 绿（内核零实例符号）+ 全量回归绿 + 自举重建冒烟 + 文档同步（设计 spec 状态/蓝图步骤 2.5 注记/progress 台账）

- [ ] **Step 1:** 中立性 guard 测试写 + 绿（清 ent_kernel 残留实例引用——若有, 回 Task 2 通道切换补漏）
- [ ] **Step 2:** 全量回归跑批
- [ ] **Step 3:** 自举重建 + 冒烟
- [ ] **Step 4:** 文档同步（设计 spec 状态回填/蓝图步骤 2.5 注记）
- [ ] **Step 5:** 提交 `feat: 内核完备收官——中立性 guard + 全量回归 + 自举 + 文档同步`

---

## 风险注记

- Task 1 重建移出 = 最大动面（loader 与发射之间契约变化）——判据 = backend_bootstrap stage byte-identical（重建产物纯搬移证明）; loader 守卫面 Task 0 核对防漏
- Task 2 通道切换 = 判定语义等价改写面——基线对照纪律（直读时代输出 vs 登记表通道输出逐字节同）;双份同步漏点 = 注入红路径测试覆盖
- 域参数接缝（Task 2 kern_set_loc_domain vs Task 3 声明表）——顺序已裁（Task 2 设置面先立, Task 3 声明表接同源）——实施时防双源漂移（Task 3 接线 = 声明表 → 设置面调用, 不并行双源）
- 中立性 guard 若在 Task 4 发现 ent_kernel 残留实例引用 → 回 Task 2 面补漏（guard 先写 = 早暴露）
- corec 写侧/interp 不经 loader——零影响（回归验证即可）

---

## Task 0 盘点结果（执行时回填）

> 盘点完成（2026-09-10）。基源 = 设计 spec（权威）+ 步骤 2 收官态代码。下列注记执行时回填：
