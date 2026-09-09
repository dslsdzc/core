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

> 盘点完成（2026-09-09）。基源 = ccr_io.cr 全文件（写侧 save_ccr :345-636/读侧 load_ccr :658-1145）+ dataflow.cr（emit 双写 + df_connect_srcs/df_connect_state + g_df_edges）+ regalloc.cr（compute_entries :180-268）+ test_ccr_v6.py（V6File walker 严格段契约）。关键锚点已内联于各任务 Files/Interfaces 节（2026-09-09 勘探输出）；Task 0 执行者按仓库惯例以代码复核为准。下列三表执行时回填：

**表一：EDG 内容期望清单**（权威 = dataflow.cr `df_connect_srcs` :194-315 / `df_connect_state` :160-177 / `sg_pop` 终止边 :84-99 / `df_use_var` :179-190；op 全集 = ast.cr :538-588，0-51 无 40。Task 1 测试期望 = 本表 + 表一注记的幽灵边规则手算）

| op 类别/区间 | op | 数据边（kind=0，本节点创建时自生产者连入，按操作数角色逐槽一条，平行边不合并） | state 边（kind=1，本节点创建时自 state 头连入 + 本节点成新头） |
|---|---|---|---|
| 字面量 | CONST(1) | 0（s1 = 标量值） | 无 |
| 算术/逻辑 | BINARY(2) | 2（s1、s2；s3 = op 子码非 var） | 无 |
| | UNARY(3) | 1（s1） | 无 |
| 浮点换算 | I2F(49) / F2I(50) | **0**（s1 实为 var 但 df_connect_srcs 未列 → GAP 族） | 无 |
| 指针/索引计算 | ADDR_INDEX(31) | **0**（s1=arr_var/s2=idx_var 实为 var 但未列 → GAP 族；ir_gen.cr:1129 真实发射） | 无 |
| 内存读 | LOAD(10) / LOAD_FIELD(11) / LOAD_INDEX(13) | 1（s1） | 无（读不连 state 链） |
| | LOAD_INDEX_VAR(15) | 2（s1、s2） | 无 |
| | DEREF(25) / LOAD_ENUM_TAG(23) | 1（s1） | 无 |
| | SLICE(24) | 3（s1、s2、s3） | 无 |
| 越界守卫 | BOUNDS_CHECK(30) | s1；type_kind≠0 时 +s2（动态界，ir_gen.cr:105-114 发射 tk=1）→ 1 或 2 | 无 |
| 内存写 | STORE(9) | 2（s1 目标、s2 值） | **入链** |
| | STORE_FIELD(12) | 2（s1、s2） | **入链** |
| | STORE_INDEX(14) | 2（s1=arr、s2=val；s3 = 常量下标） | **入链** |
| | STORE_INDEX_VAR(16) | 2（s1=arr、s2=idx）——**dest = 被存值源（值 var）不入边 → GAP**；s3 = 字面量 0 → 0-slot 幽灵（见注 A） | **入链** |
| | STORE_PTR(26) | 2（s1、s2） | **无 → GAP**（raw 指针内存写不连 state 链） |
| 分配/释放 | ALLOC(6)/ALLOC_STRUCT(7)/ALLOC_ARRAY(8) | 0 | 无 |
| | ARENA_NEW(32) | 名义 s1；**实际发射 s1 = 0 字面量**（ir_gen.cr:1663/1701/1761/2161/2275）→ 0-slot 幽灵边（见注 A），有效数据边 = 0 | 无 |
| | ARENA_RESET(33) | 1（s1 = arena_var 真 var） | **无 → GAP**（arena 复位不连 state 链） |
| 引用/解引用 | REF(18) | 1（s1） | 无 |
| 调用族 | CALL(4) | s2 条（args 自 s1 连续 s1..s1+s2−1 逐参一条；s2=0 → 0 条） | **视纯度**：find_func(s3)（s3 = 函数名 idx）< 0 或 fi_ispure==0 → 入链 |
| | CALL_EXTERN(45) | 1（仅 s2 = 首参）——**多参缺口 → GAP**（s3 = arg_count，args 2..n 不入边） | **无 → GAP**（extern 副作用不连 state 链） |
| | SPAWN(27) | s2 条（同 CALL 参数遍历） | 无 |
| | HOTPATCH_ROUTE(39) | 1（仅 s2 = 首参）——多参缺口同 CALL_EXTERN | 无 |
| | LAZY_THUNK(46) / LAZY_FORCE(47) | 1（s1） | 无 |
| 动态类型 | DYN_TAG(41)/DYN_VAL(42)/DYN_PACK(43)/DYN_DISPATCH(44) | 1（s1；DYN_PACK s2 = type_idx 字面量） | 无 |
| 控制流 | BRANCH(19) | 1（s1 条件 var；**s2/s3 = label id 非 var——v7 §4 边界声明「目标 = 操作数非边」同源佐证**） | 无 |
| | JUMP(20) | 0（s1 = label id） | 无 |
| | RETURN(5) | s1 ≥ 0 → 1，否则 0 | 无 |
| | LABEL(21) | 0 | 无（但可作 state 链头被后续边引用——出边出现在后续 state 节点创建时） |
| 流程/并发 | YIELD(28)（s1=value var）/ AWAIT(29)（dest、s1） | **0**（实为 var 但未列 → GAP 族） | 无 |
| 函数地址 | FNADDR(48) | 0（s1 = name idx int） | 无 |
| 编译期标记 | NO_BOUNDS_CHECK(35)/FAST(36)/UNROLL(37)/SECTION(38)/APPROX(51)/NOP(0) | 0 | 无 |
| 内联提示 | INLINE(34) | 1（s1） | 无 |
| 合并伪节点 | PHI(22) | 0 | 无（注：全仓 ir_gen/pass/interp/instr 无 IR_PHI 发射点——恒不出现） |
| 枚举构造 | MAKE_ENUM(17) | 0（s1 = variant name idx；字段走 STORE_FIELD） | 无 |
| 区域收尾（非 op——sg_pop 附加） | SG_LOOP(1)/SG_FOR(2) 收尾（dataflow.cr:84-99） | — | 区内最后 state 节点 → 区出口 label 节点 kind=1 终止边（条件：`g_last_state_node ≥ NSTART`，纯循环体无区内 state → 不产）；随后 state 头 = 出口 label 节点 |

注 A（**0-slot 幽灵边——本表最要命实测发现**）：`g_df_var_producer` 只在节点 `dest ≥ 0` 时写入 nid；-1 播种循环（init_df dataflow.cr:28-34）执行时 `g_ir_var_count == 0`（main.cr:396-408 序：先清零后 init_df 再 ir_gen_globals），`grow_df_arrays`（dyn_arr.cr:516）新段靠 alloc 零页 → **从未被定值的 var（全局、参数、未定值临时）producer 槽 = 0 =「节点 0」** → `df_use_var`（`producer >= 0` 判）产出幽灵数据边 0→消费者；节点 0 = func0 的 arena_new（每函数首节点 = arena_new，ir_gen.cr:2275）→ **每编译恒出自环 (0,0)**。双程序实测（v7t0_probe / v7t0_cse 的 cir DOT）：n0→n0 自环存在；参数读恒 = 幽灵边 0→读点。⇒ **与 v7 字节 spec §4 不变量 1「每条边 to_nod > 所属节点」直接冲突** —— Task 1 必先定夺其一：(a) dataflow.cr 修播种（grow 后新区写 -1 / init_df 延后到 globals 注册后）——改 .cir 视图但不动发射行为；(b) v7 写侧滤自环与 0→X 幽灵边（写侧净化，loader 校验面不动）；(c) 放宽校验（自环合法）——不建议（图 DAG 语义掺水）。本计划判定线 = 任务内定夺，**不影响 Task 2/3**（ENT 规则无涉边集）。

**表二：compute_entries 规则对照**（权威 = regalloc.cr `compute_live_ranges` :48-111 + `compute_entries` :180-268；corearch 专属——build_selfhost_native.py 清单确认 regalloc.cr 仅在 corearch concat 列表；src/compiler/regalloc-consistency.cr = 双二进制均不编译的文档残留。Task 2 corec 侧 `compute_entries_v7` 的镜像对齐清单）

| # | v6 §4.1 / 计划文字规则 | regalloc.cr 实现 | 差异 / Task 2 对齐项 |
|---|---|---|---|
| 1 | 定值点 = IR_STORE 的 s1 ∪ 其余 dest≥0（carve-out：STORE_INDEX_VAR/STORE_PTR/DYN_DISPATCH 排除） | :206-212 逐条一致（STORE 先判 s1；三 op else-if 排除；其余 dest）；追加约束：目标 var 须 ∈ [vs, vs+vc) 本函数 var 窗口 | 无差异——corec 侧同窗口约束；坐标 = NOD id 全局序（= 实现侧 `inst = ist + ii` 的全局坐标；corec 侧 ist 同源 = df func start，ii 序 = NOD 序） |
| 2 | 版本切分；收口 end = min(def−1, last_ref) | :218-224 收口上一版本 `pend = min(inst−1, last_global)`，last_global = var 级 last_ref（含定值自身——dest 列计入引用，恒 ≥ 次定值 → min 恒取 def−1，数学与 spec 截断式等价）；末版 le 直接 = last_ref | 无差异（版本号不落盘：save 侧 vcnt 计数槽 :561-587 已实现，Task 2 激活） |
| 3 | 参数/全局条目 def_nod = -1，区间 = [函数首节点, last_ref+1) | :240-262 只对**函数窗口内从未定值但有引用**的 var 产 def=-1 条目，区间 = **[first_ref, last_ref] 闭区间**（live_start = 首引用指令非函数首节点） | **差异①（文档面）**：v6 §4.1 ③ 文字「区间 = [函数首节点…]」与实现不符——实测 pure_add 参数 a/b 条目 live 1..1（首引用 = BINARY @n1，函数首节点 = 0）。Task 2 镜像按实现（loader 只校验 els < ele ≤ instr_cnt、def≥0 时 ed == els——两语义都过，但「双写对照一致」要求两侧同规则）；测试手算期望按实现语义 |
| 4 | 参数/全局 def_nod = -1 | 全局 var（SYM 前缀 0..G−1）**不在任何函数 var 窗口 → 恒无条目**（flags bit2「全局」永不落） | **差异②（文档面）**：v6 spec §3.2/§4.1 的「全局条目」面在实现中不存在——SYM globals 记录是全局的唯一存在面。Task 2 同实现（v7 字节 spec §3.5 flags bit2 语义保留 = 零实例声明） |
| 5 | 活区间（first/last_ref 扫描）为收口前提 | compute_live_ranges :48-111：逐函数逐指令扫 d/s1/s2 三列 ∈ 窗口 → [first_ref, last_ref]（未用 = 双 -1） | **对齐项（实现前提）**：corec 二进制无 regalloc.cr——`compute_entries_v7` 须自含同规则引用扫描（或等价的 df 出边反扫——注意 df 边有幽灵缺陷表一注 A，**不得**以 df 边替代三列扫描） |
| 6 | 条目按函数升序成块；函数块界由 loader 按 var 窗口切 | :105-110 compute_live_ranges 尾部逐函数调 compute_entries（func_i==0 整表重置）；块内序 = 定值指令序，尾部 def=-1 补丁按 var 序扫 | 无差异（loader 分块 :1114-1145：pv ∈ [fvs, fvs+fvc)，fvc≤0 块断 → pcnt=0 对照 ffe==-1；与 SYM func first/last 双写对照已实现） |
| 7 | home/flags | 恒 home=-1、flags=0（:232/:255） | 无差异（v7 字节 spec：home 恒 -1 直通、无配方/参数/全局/驱逐位零实例） |

**表三：落盘序核对**（权威 = ir_gen.cr `emit` :193-206 / main.cr ccr·build 路径 :527-583 / dataflow.cr `lower_to_ccr` :351-391 / cir_cache.cr 恢复 :242-415）

| 核对面 | 结论 |
|---|---|
| NOD 落盘源 = lower_to_ccr 后的 g_ir_instrs？ | ✓ save_ccr :542-556 逐条读 g_ir_instrs；main.cr :534 lower_to_ccr 先于 :557/:581 save（ccr/build 两路径同）；lower_to_ccr = g_ir_instr_count 清零后自 g_df_nodes 0..count−1 逐字段重建（:356-371）+ func 边界自 df func start/count 复制（:375-383）——**NOD = g_df_nodes 镜像 1:1 同序** |
| emit 双写之外有无第三写点破坏 1:1？ | 全线性流写点审计：emit（双写同参）、cir_cache 恢复（load_cir_cache :242-407——节点 :288-318/SG :321-356/边 :358-374/指令 :376-392 同快照双写，cache-hit 函数两表同参恢复，1:1 保持）、pass_cse（opt.cr :194-290 只 iri_set_op/iri_set_s1-3 改线性——lower 后回滚，见表后 CSE 注记）、lower_to_ccr。ir_gen 直改线性后补丁（arena size `iri_set_s1` ir_gen.cr:1711/:2287 等，另 :1674/:1772/:2165）只落线性侧、df 节点保持 emit 原值 → lower 后 NOD = emit 原值（既有行为，v7 同构，非本计划面） |
| EDG 节点 id 与 NOD 文件序一致的前提 | ✓ 节点 id 全局单调追加（init_df 每编译一次 main.cr:407，无逐函数清空）；df func 切片 = start/count 视图（df_begin_func/df_end_func :395-410）；lower 后指令 i ≡ df 节点 i ≡ NOD 文件序 i——EDG to_nod 引用与文件序一致前提成立；REG enter/exit 同坐标系（loader 回填 func 边界 :1017-1033 与 GC-3 上界校验 :1061-1074） |
| g_df_edges 节点 id 空间 = g_df_nodes（无跨函数泄漏？） | from/to 均在创建时点取节点 id，缓存恢复边同快照 → id 空间一致；**跨函数数据边存在两种形态**：(a) 表一注 A 幽灵边（node 0 → 任意函数消费者，实为跨函数）；(b) 缓存快照边——缓存命中恢复 save 时点**全图**边（cir_cache.cr :167-179 存全量），源不变时与重建同态；**源变（前序函数指纹 miss 重建、后续函数仍命中）时快照边陈旧——既有 .cir 缓存设计潜在面，待核注记**。state 链无跨函数（df_begin_func 重置 g_last_state_node :401）。Task 1 测试建议：新路径/清 .core/cache 跑（避免缓存面混入期望） |
| 逐函数图清空机制 | 不存在——df 数组编译期全局追加；「每函数一图」只是切片视图。v7 写侧「按节点序收集出边」单遍扫 g_df_edges 即可（头插链表 → 落盘序任意但确定，节点出边连续布局由写侧回填 first_edge/count） |

**CSE 时序 byte 级实测（注记——非修复项，Global Constraints 判定线确认）**：源 = 双函数含重复纯子表达式（x*x 双现 ×2、helper a*a 双现 + 循环内双现，NOD 解析证实 3 组 CSE-able 重复）。命令（每跑前 rm -rf .core 清缓存）：
`nice -n 19 /home/DslsDZC/core/build/corec ccr /tmp/v7t0_cse_test.cr -o /tmp/v7t0_O0.ccr --opt-level 0` 与同源 `--opt-level 1` → **全文件 byte-identical**（cmp 一致；sha256 均 38cf7880d0db54ce…；NOD 段 = 72 节点 2020B 两版逐字节同）。代码路径佐证：main.cr:530-534 `pass_cse()`（opt.cr :194-290，只 NOP/改写线性 g_ir_instrs）位于 `lower_to_ccr()` 之前；lower 自 g_df_nodes 全量重建 → **O1 CSE 被整体回滚，NOD 落盘与 O0 恒同**（注：corec g_opt_level 默认 = 1，main.cr:203——默认跑即走此回滚路径，v6 现状如此）。结论：CSE 疑点坐实为「无效果 pass」，v7 落盘源 = df 镜像与其无涉，保持非修复项。
