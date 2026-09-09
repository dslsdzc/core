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

## Task 0 盘点结果（已回填——2026-09-10，实施 Task 1-4 依此锚定）

> 基源 = 设计 spec（权威）+ 步骤 2 收官态代码（ccr_io.cr 1372 行 / ent_kernel.cr 807 行 /
> regalloc.cr 795 行 / corearch.cr 492 行现态）。行号 = 盘点日锚点（后续改动若漂移以语义为准）。

### ① load_ccr 重建段依赖面（Task 1 移出裁决依据）

- **重建段实际位置（纠正旧锚点）**：NOD→g_ir_instrs 线性重建 = ccr_io.cr **NOD 段解析 :1207-1236**
  （盘 36B → 内存 48B：grow_ir_instrs(instr_cnt) :1211 + 逐记录 iri_set_op/dest/s1/s2/s3/tk :1228-1233 +
  g_ir_instr_count 递增 :1234）。**不在先前锚 ~:1361-1393**（现文件 1372 行，EDG 校验尾 :1369——
  旧锚点过时，重核如上）。消费 = data 缓冲 + seg_off3/seg_end3（段表局部），**不读任何 g_ir_* 内容**；
  nod_edge_meta = load_ccr **局部**暂存（:1213 alloc 16B/节点 {first_edge, edge_count}——非全局）；
  g_v7_edges/g_v7_edge_count（全局，:1343-1344 写）属 EDG 段、不属重建段。
- **守卫消费面（决定性事实——重建移出后全部成立）**：GC-3 root span 上界校验 :1244-1251 消费
  g_ir_func_instr_start/count（REG 段派生回填 :1186-1202）+ **NOD 段头计数 instr_cnt**（局部变量，
  非 g_ir_instrs/iri_*）→ 线性流零依赖。ENT 校验 :1255-1322（evr≥1/var 命名空间/els≥ele、
  **ele > instr_cnt 拒收 :1275、ed ≥ instr_cnt :1277、ed == els 定值恒等**——界全 = NOD 坐标 +
  SYM var 命名空间；函数块界重建 :1291-1321 读 g_ir_entries 内容 + fn_meta（SYM first/last 双写对照））
  → 线性流零依赖。EDG 校验 :1335-1369 消费 instr_cnt + nod_edge_meta（NOD 邻接域 :1349-1352）→
  线性流零依赖。**load_ccr 全程零 iri_* 读**。
- **移出推论**：loader 仍须读 NOD 段计数（段界校验必需）与每记录邻接域 first_edge/edge_count
  （36B 记录偏移 +24/+28，EDG 守卫消费）——28B 语义字段写线性流 = 唯一可搬体。现 NOD 语义字段
  除 g_ir_instrs 外**无任何保留**（含邻接 = load_ccr 局部）→ Task 1 须裁决 NOD 对象留存形态
  （对象存储 or build_linear_schedule 重扫 data 缓冲——buf 存活至 corearch_main 尾，重扫式可行；
  文件段偏移现为 load_ccr 局部，重扫式需把 NOD 段界传出或段表重走）。
- **顺序依赖**（现实现序 STR→SYM→REG→NOD→ENT→EDG；段按 offset 随机寻址）：SYM funcs 产 fn_meta
  暂存 → REG 根行对照 :1174-1180；REG 根 span → 函数指令边界回填 → GC-3（需 NOD 计数）；
  NOD 计数 → ENT/EDG 界校验；SYM 声明区 → var 命名空间 → ENT var_id 界；ENT↔EDG 互不依赖。
  重建段 loader 内**零下游消费者**——消费全在 load 返回后（见下）。
- **load 后依赖面（接线点裁决）**：corearch_main 内 load_ccr :295 → init_backend_arrays :297
  （仅 g_x86_* 数组——与线性流无关）→ regalloc_debug_dispatch :305。dispatch 各分支直食线性流：
  dump-entries :153 / inject-coexist-oob :158 / dump-coexist :163 的 compute_live_ranges（扫
  iri_dest/s1/s2）、dump-regassign :169 与 check-regalloc :191 的 alloc_registers、:199
  regalloc_verify_all；生产 O2 门 :308-314（alloc → verify）；ELF 发射面（elf.cr/instr.cr/resolve.cr）。
  → **build_linear_schedule() 接线点 = load_ccr 成功（:296）后、dispatch :305 前**（紧邻 load）。
- 另一 load_ccr 调用方 = src/arch/linux/ld/main.cr:56——**死代码**（自注记 2026-09-10 内核抽取
  Task 4：零 concat 引用，实际入口 = src/compiler/corearch.cr）——改签名/搬移无须同步。

### ② region_of_nod 定夺（设计 spec §6 挂账 ① 裁决 = **不含**）

- v7 文件无 g_df_node_region；loader **不重建**节点→区域映射——REG 段只派生 nstart/ncount
  （:1172-1173 = enter/exit 副本写回 g_sgs 行），不产映射数组。corec 构建侧映射 = 构建期快照
  （dataflow.cr df_create_node:110 写 g_df_node_region[nid] = g_cur_sg，-1 = 无）——不落盘。
- **零消费方事实**：corearch concat 内 g_sgs 唯一消费者 = ccr_io.cr loader 自身；ent_kernel/
  regalloc/instr/elf/resolve 全部零 g_sgs 读（判定①② 不消费区域）。另注：设计 §1.2「现有 sg
  访问器」表述不确——corearch 侧无 sg_* 访问器函数（读写全为 r64/w64 直偏移）。
- **推导可行性（后补注）**：REG 行 = 压栈序 + parent 链 + enter/exit 节点坐标（层流嵌套区间；
  SG_FUNC 根 span = 函数指令范围，save :759-765/load GC-3 双侧校验过）。region_of_nod(n) = 含 n
  的最深行：每查询 O(函数 REG 行数) 扫描或 O(nodes) 栈扫预计算——数据无损、可后补。
- **定夺注记**：对象面 API **不含 region_of_nod——区域面仅 REG 行遍历**。理由：零现消费方 +
  预计算表 = 无消费者内核数据（YAGNI）+ EDG 配方可读承诺不依赖区域。→ Task 1 不加区域推导
  访问器；Task 4 文档同步时在 spec §1.2 表注 region_of_nod = 挂账已决（不含，按需后补）。

### ③ 登记 API 接入面（Task 2 调用点清单）

- **alloc_registers phase 5**（regalloc.cr :733-792，逐函数尾）：g_opt_meta 原语直写（store8
  头/count/对 @+12，g_opt_meta_count = ei+1 :789；已分配 var = asg_lv/var_asg，全局 var id =
  vs + lvp、reg = r64(var_asg,…)）。→ **登记调用点 = phase 5 尾每函数**：对每个已分配 var，其
  全部版本条目 e ∈ [entry_start(fi), entry_start(fi)+entry_count(fi))（ent_var(e) == vw）逐一
  kern_loc_assign(e, rn)（var 级分配 → 同 var 全条目同 loc——与现 meta_reg_for_var 投影语义
  精确等价的前提，实施时保持全条目登记）。
- **注入钩子写点（6+1 的实写点 = 3 个 try_*；顶层 inject_* = 纯遍历）**：
  - try_inject_home_conflict :40-67：meta_remove_var(v1/v2) :56-57（配对 = 清两 var 全条目登记）
    + home=7 直写条目表 :58-59（g_ir_entries = 内核数据面，无需登记——读侧由 ent_home + 域
    home_base 合成，与现 ent_home 直读等价）。
  - try_inject_reg_conflict :192-217：meta_set_reg(v1/v2, 3) :208-209（配对 = 登记两 var 全条目 → 3）。
  - try_inject_read_gap :235-283：条件 meta_remove_var(:267) + meta_set_reg(gv,3)(:275)（配对 =
    清共存 var 条目 + 登记 gv 条目）+ live_end 截断 :277（条目表直写，无需登记）。
  - inject_coexist_oob :22-29：零 meta 写——无配对。
- **配对点取舍**：meta 写辅助函数体内嵌（meta_set_reg :107-111 / meta_remove_var :115-154 /
  meta_append_reg_assign :171-186）覆盖全部注入路径 → 最小配对面 = **phase 5 写点 + meta_set_reg
  + meta_remove_var 共 3 处**（phase 5 原语直写不经辅助函数，须单独配对）。
- **flag 路径时序（判定读登记表时点）**：判定唯一读面 = regalloc_verify_all :798-807，调用点两处：
  check-regalloc 分支（corearch.cr :199——保序 = 强制 O2 :190 → alloc :191（phase 5 登记完成）→
  看门狗 meta_reg_assign_total :194（**直读 g_opt_meta，实例面 viewer，不经登记表**）→ 注入
  :196-198（配对保持同步）→ verify :199 读表）与生产 O2 门（:309 alloc → :312 verify）。
  其余分支（dump-entries/dump-coexist/inject-coexist-oob）只跑 compute_live_ranges + 条目表
  dump——不触发判定、不需登记表；dump-regassign :167-187 直读 g_opt_meta（实例面）。verify 无
  不经 alloc 的路径（生产门 = g_opt_level≥2 + needs_alloc 声明；check 分支强制 2）→ 登记表进程
  起点空表 = 等价现状（meta 空 + home 全 -1 → 0 违反）。

### ④ 判定读 meta 面全集（通道切换精确函数面）

- ent_kernel.cr 代码级 g_opt_meta 读点 = **唯一函数 meta_reg_for_var :504-525**（全文 12 处
  g_opt_meta 提及：11 注释 + 本函数 5 代码读——循环界 g_opt_meta_count :507、块 key :509、
  data_len :511、对 var :515、对 reg :517）。布局：OPT_META_STRIDE = 64（ast.cr:642）、
  OPT_KEY_REG_ASSIGN = 0（ast.cr:641）@+0 / data_len @+4 / count @+8（跳过）/ 对 var@+12 reg@+16
  8B 步进——与 loader opt_meta 段（ccr_io :1117-1140）及 emit 侧同布局。
- **调用点（切换 = meta_reg_for_var 函数体等价改写为登记表查询，3 调用点不动）**：rl_rule2_func
  :643（寄存器驻留过滤——var 级语义须保持：var 有任一已登记条目 = 驻留）、
  verify_regalloc_consistency 计数遍 :726 + 记录构建遍 :742（逐条目投影）。
- **LOC_HOME_BASE 代码面**：常量 :500 + rl_print_loc :590（分类打印）+ verify home 编码 :744
  （home 组投影 = LOC_HOME_BASE + ent_home(e)）→ 域参数化替换面（kern_set_loc_domain 接
  {home_base, reg_domain}）。注：reg_domain 现无分组消费点（规则① 组别 = meta 投影 ∪
  ent_home 投影天然不相交：reg 0..15 vs home ≥ 10⁶）——reg_domain = 声明面参数 + 防相交护栏。
- **emit 面独立实现（已核）**：instr.cr get_reg_for_var :34-53 = 与 meta_reg_for_var 字节级同构
  的独立函数（g2_slot :55-73 消费；elf.cr:1309/resolve.cr:36-37 = get_reg_for_var/g2_slot 面）——
  通道切换不动 emit 面。
- **计划假设被实证反驳（修正注——Task 2 必须同步）**：plan Task 2 写「meta_reg_for_var 删——确认
  emit 面无引用（instr.cr get_reg_for_var = 独立实现——已核）」只核了 emit 面——但
  **regalloc.cr 注入探针 try_inject_read_gap :254/:261 调用 meta_reg_for_var**（实例侧读内核
  函数）。删除/改写时须同步这两处（换实例侧直读 g_opt_meta 的私有扫描，或经登记表等价读——
  前者贴实例面语义）；corec concat 无引用（定义随 concat 编译，未用不报错）。

### ⑤ 中立性 guard 设计（Task 4 前置设计）

- **ent_kernel.cr 实例味符号面（代码级全集）**：g_opt_meta/g_opt_meta_count + OPT_KEY_REG_ASSIGN/
  OPT_META_STRIDE（全经 meta_reg_for_var 体——Task 2 切换后清零）+ LOC_HOME_BASE（:500——Task 2
  移除）。注释层实例提及（guard 剥注释后不拦，记录在案）：x86/机器侧/regalloc.cr（头注 :4-30）、
  instr.cr g2_slot/get_reg_for_var（:478/:502）、rl_print_loc x86 寄存器枚举注（:593「3=rbx,
  12-15=r12-r15」）、alloc_registers() 前置条件注（:704）。
- **结构性守卫（现成）**：ent_kernel.cr 双 concat 共享（corec concat 无 regalloc/instr/elf/
  hit/corearch.cr）→ 指向实例独有文件的符号 = corec 编译失败。文本 guard 真正防的 =
  **共享声明文件里的实例符号**（g_opt_meta/opt 常量 = globals.cr/ast.cr，双 concat 都有 →
  结构守卫拦不住——正是静态 guard 必要性）。
- **断言排除集（代码面 token 级）**：g_opt_meta、g_opt_meta_count、LOC_HOME_BASE、OPT_KEY_* /
  OPT_META_STRIDE、E2_REG_SLOT_BASE/E2_*、g_x86_*、寄存器名 token（rbx/r12-r15 等实例枚举名）、
  ELF 面（ELF/elf_gen 等）——NOD/EDG/ENT/REG = 文件格式语义名**不拦**（§4.3 例外）。
  实现注：必须先剥注释（// 与 /* */）再扫 identifier——rl_print_loc x86 注记在注释层，不剥则
  误报；可选强化 = 引用标识符 ∩ 实例独有文件函数定义集 = ∅（结构守卫的文本镜像，成本低）。
- **测试落点**：tests/selfhost/ 新文件 test_ent_kernel_neutrality.py（纯源码文本扫描，无 build
  依赖，与 selfhost 套件同风格入回归面）。Task 4 Step 1 先写先红（现态 meta_reg_for_var 仍在 →
  红），Task 2 切换后转绿——guard 先写 = 早暴露纪律。
