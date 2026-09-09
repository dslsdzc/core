# v7 格形态（真图载体）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** .ccr 从 v6（线性 NOD + 恒空 ENT）切换到 v7 真图载体——NOD 36B 邻接 + EDG 段（数据/state 边必落）+ ENT 实记录（corec 产时重建），全链行为不变。

**Architecture:** 写侧数据源现成（corec 进程内 g_df_edges/g_df_var_producer——emit() 双写图与线性 IR 1:1，从未落盘）；读侧 loader 的 ENT 实记录解析/校验代码已存在（恒空走不到，激活即可）。v7-only 同日切换（corec/corearch 双端同提交，管线中间产物零持久生态）；行为判据 = 切换后全量回归绿 + backend_bootstrap stage 链 byte-identical + 自举重建（与 regalloc 移后端/MW M1 判据同款）。

**Tech Stack:** src/compiler/ccr_io.cr（双端共享读写）、dataflow.cr（图构建）、regalloc.cr（条目计算镜像基）、Python 测试（tests/selfhost/）。

**设计 spec:** `docs/superpowers/specs/2026-09-09-lattice-ir-v7-carrier-design.md`（语义权威）+ `docs/superpowers/specs/2026-09-09-lattice-ir-v7-format.md`（字节权威）。执行时 spec 为字段/接口的权威定义源。

## Global Constraints

- 版本控制 `jj`（铁律 #2，git 被 hook 拦截）。每任务 `jj commit -m '<msg>'`
- 构建 `nice -n 19 python3 build_selfhost_native.py`（约 2-3 分钟，改 ccr_io 后必重建）；测试 `nice -n 19` 前缀（铁律 #6）
- **行为等价硬约束**：v7 链（corec 产 v7 → corearch 读 v7 → 发射）与 v6 链行为一致——判据 = 同套测试全绿（测试 = 行为断言，与格式无关）+ backend_bootstrap stage 链 byte-identical + hit_table 24/24 保持绿（表路径挂起中但测试是行为回归网）
- 版本/形状守卫密度高（写侧 ccr_validate_i32_fields + 游标守卫；读侧段表规范序 + 逐段越界 + REG root span 上界 + ENT 双写对照）——v7 改动必须保持同等守卫强度，Python 侧严格段契约 walker = 免费格式回归网（迁移后重锁）
- 图数据落盘源 = g_df_edges（内存邻接 = 链表头插——出边序为创建逆序，落盘序任意但须确定；每条边 to_nod 前向 = 拓扑不变量）
- 每任务验证 = 构建 + 该任务判据 + 回归面（mw1-6/live_ranges/region_cfg/compile/backend_bootstrap/hit_table/slice_bounds 快子集——Task 3 全量）
- interp（corec run 路径）直食 DF 节点流，不经 .ccr——v7 零影响（回归验证即可）
- CSE 时序疑点（pass_cse 位于 emit 与 lower_to_ccr 之间，lower 从 g_df_nodes 全量重建——O1 下 CSE 是否被回滚）**非本计划修复项**（v6 链行为保持 = 判据）；Task 0 实测注记即可——v7 落盘源统一为 df 镜像，与 CSE 无关

---

## Task 0: 盘点核对（v7 落盘数据源 + 守卫面）——计划锚点

**Files:** 分析产出（无代码改动）
- 核对 g_df_edges/g_df_var_producer 完备性：df_connect_srcs 按 op 的连边语义表（dataflow.cr:195-315）对照 ast.cr op 全集（0-51）——哪些 op 无数据边（LABEL/JUMP/PHI/ALLOC/编译期标记 = 0 出边正常）；state 链覆盖（df_connect_state 纯函数判定表——find_func + fi_ispure）；**产出 = EDG 预期内容清单**（每 op 类的出边类别/数量，供 Task 1 测试期望）
- CSE 时序 byte 级实测：`corec ccr -O0/-O1` 同源产物的 NOD 区 diff（pass_cse 是否被 lower_to_ccr 回滚）——注记（非修复项）
- regalloc.cr:180 `compute_entries` 与 v6 §4.1 规则逐条对照（定值点 = IR_STORE 的 s1 ∪ 其余 dest≥0；版本切分；收口 end=min(def-1,last_ref)；参数/无定值 def=-1）——**Task 2 corec 侧 ENT builder 的镜像基**（corec 二进制不含 regalloc.cr——须独立实现同规则；对照产出 = 规则差异清单）
- 落盘序核对：NOD 落盘源 = lower_to_ccr 后的 g_ir_instrs = g_df_nodes 镜像（1:1）——EDG 节点 id 引用与 NOD 文件序一致的前提确认
- 交付：清单并入本 plan 附注（文末「Task 0 盘点结果」节）；差异 → Task 1/2 执行前修正

---

## Task 1: v7 骨架切换——version 7 + NOD 36B + EDG 段（写读同改）

**Files:**
- Modify: `src/compiler/ccr_io.cr`（CCR_VERSION 6→7（:87）；CCR_SEG_COUNT 5→6（:88）；段 tag 6=EDG 常量新增；save_ccr：NOD writer（:543-556）28B→36B + first_edge/edge_count、EDG 段 writer 新增、段表 5→6 项、calc_ccr_size（:306）/ccr_nod_seg_size（:292）扩展；load_ccr：NOD 36B 读（:1035-1059 区）、EDG 解析 + 拓扑校验、段表 tag 6 处理）
- Test: `tests/selfhost/test_ccr_v7.py`（新建——v7 walker：header/段表 6 段/EDG/36B NOD 解析）+ `tests/selfhost/test_ccr_v6.py`（机械更新：version 常量 6→7、reject 测试改「拒 version≠7」；ENT 空断言测试暂留——Task 2 翻转）

**Interfaces:**
- Consumes: Task 0 清单（EDG 内容期望）
- Produces: v7 文件（写侧——EDG = g_df_edges 落盘：per-node 邻接连续布局，first_edge = 前节点 first_edge+count 累加；每边 {to_nod u32, kind u32} 8B）；loader 读 v7（NOD 36B 跳 first_edge/count 后重建线性流——发射输入与 v6 逐字段一致；EDG 载入 g_v7_edges 缓冲 + 校验）
- 校验规则（字节 spec §4）：每条边 to_nod > 所属节点（前向——数据/state 边 DAG 拓扑）；edg_count == Σ edge_count；NOD/ENT/REG 引用界内；branch/jump 目标 = 操作数引用（可后向）非边——校验实现不把操作数当边
- v6 文件读路径：删除（v7-only——loader 拒 version≠7；旧 v6 测试文件由 Python 侧改写，无转换工具）

- [ ] **Step 1:** 写失败测试（test_ccr_v7.py）：corec ccr 产文件 → v7 walker 断言（version=7、段表 6 段含 EDG、NOD 36B 记录、EDG 记录数与内容对照已知小程序的 Task 0 期望）——现 save 产 v6 → FAIL
- [ ] **Step 2:** 跑测试确认失败
- [ ] **Step 3:** 写侧实现：CCR_VERSION=7、EDG 段写入（save_ccr 内：落盘前单遍扫 g_df_edges 按节点序收集出边——头插链表遍历 → 连续 EDG 数组 + first_edge/edge_count 回填 NOD）、段表/尺寸函数扩展
- [ ] **Step 4:** 读侧实现：load_ccr 接受 version 7、NOD 36B 读、EDG 解析 + 拓扑校验、段表 tag 6
- [ ] **Step 5:** 机械更新 test_ccr_v6.py（header/version 期望 6→7、V6File walker 段契约改 NOD 28B→36B + EDG 段走查 + 段表 5→6 项、reject 面改「拒 version≠7」——ENT 空断言与 roundtrip 用例暂留，Task 2 翻转/追加）；test_ccr_v7.py 绿（两文件并存窗口，Task 3 合并）
- [ ] **Step 6:** 构建 + 回归快子集（compile/backend_bootstrap/hit_table 24/24——corec build 全链走 v7 文件）
- [ ] **Step 7:** 提交 `feat: v7 格式骨架——version 7 + NOD 36B 邻接 + EDG 段必落（写读同改，v6 读路径退役）`

---

## Task 2: ENT 主干化——corec 产实记录 + loader 激活

**Files:**
- Modify: `src/compiler/ccr_io.cr`（save：ENT writer（:558-587）恒 0 → 实记录（corec 侧条目计算 + 28B 盘布局 {var_id,version,def_nod,live_start,live_end 半开,home=-1,flags}）；calc_ccr_size/ccr_ent_seg_size 扩展；load：ENT 实记录路径激活（:1076-1145 已有解析/校验/函数块对照代码——恒空从未走到））
- Modify: SYM func 记录写侧（:442-453 first_ent/last_ent 恒 -1 → 实回填；param_ents -1 → 参数条目 id）与 REG 写侧（:610-611 first_ent/last_ent 实回填）——与 ENT 同提交（loader 块对照校验消费）
- Test: `tests/selfhost/test_ccr_v7.py`（ENT 非空断言 + 字段语义 spot-check：已知小程序的条目数/版本切分/区间与 Python 独立期望对照——期望按 v6 §4.1 规则手算）

**Interfaces:**
- Consumes: Task 0 的 regalloc compute_entries 规则对照清单（corec 侧独立实现——corec 二进制不含 regalloc.cr）
- Produces: `fn compute_entries_v7() -> int`（corec 侧：定值点收集（IR_STORE 的 s1 ∪ 其余 dest≥0，两处 carve-out：STORE_INDEX_VAR/STORE_PTR/DYN_DISPATCH 排除）+ 版本切分 + 区间（图坐标 [def_k, def_{k+1}) 截断 [first_ref, last_ref+1)）+ 参数/全局 def=-1 条目；写入 g_entry_count/ent 缓冲——28B 盘布局 version + live_end 半开转换）；loader 校验（evr≥1/ev 命名空间/els<ele≤instr_cnt/ed==els + SYM 块对照）
- home 恒 -1（实例注记——分配决策 = corearch 实例层自算，文件 ENT 不承载）；corearch regalloc **保持自算不变**（文件 ENT = 校验面 + 语义消费通道的数据源；行为零变化判据的锚）
- 无配方条目（flags bit0）：现 IR 面无此形态（边界/不可重算未进 .ccr）——flags 恒 0 落盘，bit 语义保留（字节 spec 声明）

- [ ] **Step 1:** 写失败测试：ENT 实记录断言（现恒 0 条 → FAIL）
- [ ] **Step 2:** 跑测试确认失败
- [ ] **Step 3:** corec 侧 `compute_entries_v7()` 实现（镜像 regalloc.cr:180 规则——Task 0 差异清单逐条对齐）+ save ENT 实写 + SYM/REG first_ent/last_ent/param_ents 回填
- [ ] **Step 4:** loader ENT 路径激活（实记录 parse/校验/块对照——激活后即被全链消费）
- [ ] **Step 5:** 测试绿（ENT 断言 + reject 面：坏 version 条目/越界区间）+ 回归快子集（行为零变化——corearch regalloc 自算未动）
- [ ] **Step 6:** 提交 `feat: ENT 主干化——corec 产实记录（v6 §4.1 规则执行化）+ loader 激活 + SYM/REG 条目回填`

---

## Task 3: 测试族迁移收官——test_ccr_v7 全量 + 回归 + 自举 + 文档

**Files:**
- Modify: `tests/selfhost/test_ccr_v6.py` → 迁移合并进 `test_ccr_v7.py`（V6File walker → V7File walker 全段游走（段表规范序/连续/走满校验——Python 侧严格段契约保留）+ NOD 36B + EDG 解析 + ENT 实记录 shape + reject 面：version≠7/坏 EDG（to_nod 非前向/计数不符）/坏 ENT（evr 越界/区间倒置）——byte-mutation 先例沿用（test_ccr_v6.py:302/543 同款）
- Modify: `docs/ir-schema/coreir-schema.md`（.ccr 列：「线性化」→「图载体」——执行序 = 投影）
- Modify: `docs/superpowers/specs/2026-09-05-lattice-ir-v6-format.md`（状态注记：被 v7 取代——原则 6 v5 槽模型 = P1 泄漏源标注、开放点 1 边表裁决 = v7 必落）
- Test: 全量回归面 + `test_backend_bootstrap.py`（stage 链走 v7 文件 byte-identical）+ 自举重建

**Interfaces:**
- Consumes: Task 1/2 全部
- 验证: 全量回归绿（mw1-6/live_ranges/region_cfg/compile/backend_bootstrap/hit_table/slice_bounds + bootstrap 三套）;stage 链（stage1.ccr = v7 → stage2/stage3 byte-identical）;`nice -n 19 python3 build_selfhost_native.py` 重建后冒烟（corec check/run 小样本）;文档同步

- [ ] **Step 1:** test_ccr_v7.py 全量合并（V7File walker + 全用例——删 v6 专属断言：version-5-reject → version≠7-reject；ent_optmeta_absent → ent 实记录 shape；roundtrip/build 链用例改 v7 期望）
- [ ] **Step 2:** 全量回归跑批（面 = Global Constraints 回归面全项）
- [ ] **Step 3:** 自举重建 + 冒烟（新 corec/corearch：backend_bootstrap stage 链 + corec check src/compiler）
- [ ] **Step 4:** 文档同步（ir-schema 三形态列修订、v6 format spec 状态注记、progress 台账）
- [ ] **Step 5:** 提交 `feat: v7 收官——测试族迁移（V7File walker 全量）+ 全量回归 + 自举重建 + 文档同步`

---

## 风险注记

- Task 1 为最大任务（写读同改同日切换）——段内中间态只存在于 implementer 工作区，提交即绿；判据 = 回归快子集 + hit_table 24/24（表路径 = 独立行为回归网）
- EDG 出边序 = 内存头插逆序落盘——序任意但确定；测试断言按「边集合/计数」而非序（Task 0 期望清单明确）
- loader 守卫面（段表规范序/逐段越界/root span/ENT 块对照）在 v7 全部保留——测试迁移重锁（V7File walker = 免费格式回归网）
- CSE 疑点非本计划修复（行为判据要求 v6 链现状保持）；Task 0 注记供后续优化挂载点设计
- corearch regalloc 自算保持不变（行为零变化锚）——文件 ENT 与自算的差异面 = 未来消费切换的独立决策（本计划不做双算对照）

---

## Task 0 盘点结果（执行时回填）

> 盘点完成（2026-09-09）。基源 = ccr_io.cr 全文件（写侧 save_ccr :345-641/读侧 load_ccr :658-1145）+ dataflow.cr（emit 双写 + df_connect_srcs/df_connect_state + g_df_edges）+ regalloc.cr（compute_entries :180-268）+ test_ccr_v6.py（V6File walker 严格段契约）。关键锚点已内联于各任务 Files/Interfaces 节（2026-09-09 勘探输出）；Task 0 执行者按仓库惯例以代码复核为准。下列三表执行时回填：
