# v7 格形态（图实现方式）实施计划

> 状态：实施完成（2026-09-10 Task 3 结束）。Task 1 完成 v7 框架：version 7、NOD 36B 邻接、EDG 段必须落盘、伪边初始化修复、CIR_CACHE_VER 14。Task 2 完成 ENT 实记录 compute_entries_v7、SYM/REG 条目回填、loader 激活。Task 3 完成测试族迁移：test_ccr_v6.py 合并移除，改为 test_ccr_v7.py，23/23 全部通过（V7File walker 全量加 cache-hit 恢复路径回归加 ENT 负分支补面 R1/R2），另完成全量回归、自举重建快速验证和文档同步。报告为 `docs/archive/sdd/v7-task-*-report.md`。字节状态以 v7 格式 spec 为准：第 4 节规则 4 和第 6 节开放点 3 是 home/flags 接受不拒绝的裁决（R3），开放点 5 是 per-param/嵌套 REG 内容锁推迟（R4），均已回填。v6 spec 是历史基线（取代注记加差异1 以实现语义为准）。测试期望语义以 regalloc.cr compute_entries 实现为准（Task 0 表二差异1）。

> 面向执行本计划的 agent：必须使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans，按任务逐项实现。用复选框（`- [ ]`）跟踪进度。

目标：.ccr 从 v6（线性 NOD 加始终为空的 ENT）切换到 v7 图实现方式：NOD 36B 邻接加 EDG 段（数据边和 state 边必须落盘）加 ENT 实记录（corec 产时重建），全链行为不变。

结构：写侧数据源现成：corec 进程内 g_df_edges/g_df_var_producer，emit() 双写图与线性 IR 为 1:1，从未落盘。读侧 loader 的 ENT 实记录解析和校验代码已存在，恒空时走不到，激活即可。v7-only 同日切换，corec 和 corearch 双端同提交，管线中间产物零持久生态。行为检查是切换后全量回归通过、backend_bootstrap stage 链 byte-identical、自举重建，与 regalloc 移后端和 MW M1 检查同款。

技术栈：src/compiler/ccr_io.cr（双端共享读写）、dataflow.cr（图构建）、regalloc.cr（条目计算镜像基）、Python 测试（tests/selfhost/）。

设计 spec：`docs/superpowers/specs/2026-09-09-lattice-ir-v7-carrier-design.md`（语义权威）加 `docs/superpowers/specs/2026-09-09-lattice-ir-v7-format.md`（字节权威）。执行时 spec 是字段和接口的权威定义源。

## 全局约束

- 版本控制用 `jj`，见项目规则第 2 条，git 被 hook 拦截。每任务用 `jj commit -m '<msg>'`。
- 构建 `nice -n 19 python3 build_selfhost_native.py`，约 2-3 分钟，改 ccr_io 后必须重建。测试加 `nice -n 19` 前缀，见项目规则第 6 条。
- 行为等价是硬约束：v7 链（corec 产 v7，corearch 读 v7，发射）与 v6 链行为一致。检查是同套测试全部通过（测试是行为断言，与格式无关）加 backend_bootstrap stage 链 byte-identical 加 hit_table 24/24 保持通过（表路径挂起中，但测试仍是行为回归检查）。
- 版本和形状守卫密度高（写侧 ccr_validate_i32_fields 加游标守卫；读侧段表规范序加逐段越界加 REG root span 上界加 ENT 双写对照）。v7 改动必须保持同等守卫强度。Python 侧严格段契约 walker 是一层无需额外成本的格式回归检查，迁移后重新确认。
- 图数据落盘源是 g_df_edges（内存邻接为链表头插，出边序是创建逆序，落盘序任意但必须确定；每条边 to_nod 前向，这是拓扑不变量）。
- 每任务验证包括构建、该任务检查和回归面（mw1-6/live_ranges/region_cfg/compile/backend_bootstrap/hit_table/slice_bounds 快子集，Task 3 做全量）。
- interp（corec run 路径）直接消费 DF 节点流，不经 .ccr，v7 对它零影响，回归验证即可。
- CSE 时序疑点：pass_cse 位于 emit 与 lower_to_ccr 之间，lower 从 g_df_nodes 全量重建，O1 下 CSE 是否被回滚。这个疑点不是本计划修复项（v6 链行为保持是检查），Task 0 实测注记即可。v7 落盘源统一为 df 镜像，与 CSE 无关。

---

## Task 0: 盘点核对（v7 落盘数据源 + 守卫面），计划基准

文件：分析产出，无代码改动。

- 核对 g_df_edges/g_df_var_producer 完备性：df_connect_srcs 按 op 的连边语义表（dataflow.cr:195-315）对照 ast.cr op 全集（0-51）。哪些 op 无数据边（LABEL/JUMP/PHI/ALLOC/编译期标记等于 0 出边，正常）；state 链覆盖（df_connect_state 纯函数判定表：find_func 加 fi_ispure）。产出是 EDG 预期内容清单，列出每个 op 类的出边类别和数量，供 Task 1 测试期望使用。
- CSE 时序 byte 级实测：`corec ccr -O0/-O1` 同源产物的 NOD 区 diff，检查 pass_cse 是否被 lower_to_ccr 回滚。只注记，不修复。
- regalloc.cr:180 `compute_entries` 与 v6 第 4.1 节规则逐条对照（定值点 = IR_STORE 的 s1 并上其余 dest≥0；版本切分；结束 end=min(def-1,last_ref)；参数或无定值 def=-1）。这是 Task 2 的 corec 侧 ENT builder 的镜像基准（corec 二进制不含 regalloc.cr，须独立实现同规则；对照产出是规则差异清单）。
- 落盘序核对：NOD 落盘源是 lower_to_ccr 后的 g_ir_instrs，等于 g_df_nodes 镜像（1:1）。确认 EDG 节点 id 引用与 NOD 文件序一致的前提。
- 交付：清单并入本 plan 附注（文末「Task 0 盘点结果」节）；差异在 Task 1/2 执行前修正。

---

## Task 1: v7 框架切换，version 7 + NOD 36B + EDG 段（写读同改）

文件：
- 修改：`src/compiler/ccr_io.cr`（CCR_VERSION 从 6 改为 7（:87）；CCR_SEG_COUNT 从 5 改为 6（:88）；新增段 tag 6=EDG 常量；save_ccr：NOD writer（:543-556）从 28B 改为 36B 加 first_edge/edge_count、新增 EDG 段 writer、段表从 5 项改为 6 项、扩展 calc_ccr_size（:306）/ccr_nod_seg_size（:292）；load_ccr：NOD 36B 读（:1035-1059 区）、EDG 解析加拓扑校验、段表 tag 6 处理）
- 测试：`tests/selfhost/test_ccr_v7.py`（新建，v7 walker：header/段表 6 段/EDG/36B NOD 解析）加 `tests/selfhost/test_ccr_v6.py`（机械更新：version 常量从 6 改为 7、reject 测试改为「拒 version≠7」；ENT 空断言测试暂留，Task 2 翻转）

接口：
- 读取：Task 0 清单（EDG 内容期望）
- 产出：v7 文件。写侧 EDG 为 g_df_edges 落盘，使用 per-node 邻接连续布局，first_edge 等于前节点 first_edge 加 count 累加；每边 {to_nod u32, kind u32} 8B。loader 读 v7：NOD 36B 跳过 first_edge/count 后重建线性流，发射输入与 v6 逐字段一致；EDG 载入 g_v7_edges 缓冲并校验。
- 校验规则（字节 spec 第 4 节）：每条边 to_nod > 所属节点（前向，数据边和 state 边满足 DAG 拓扑）；edg_count == Σ edge_count；NOD/ENT/REG 引用界内；branch/jump 目标是操作数引用（可以后向），不是边，校验实现不把操作数当边。
- v6 文件读路径删除（v7-only，loader 拒 version≠7；旧 v6 测试文件由 Python 侧改写，无转换工具）。

- [ ] Step 1: 写失败测试（test_ccr_v7.py）：corec ccr 产文件，v7 walker 断言（version=7、段表 6 段含 EDG、NOD 36B 记录、EDG 记录数与内容对照已知小程序的 Task 0 期望）。现在 save 产 v6，预期失败
- [ ] Step 2: 跑测试确认失败
- [ ] Step 3: 写侧实现：CCR_VERSION=7、EDG 段写入（save_ccr 内，落盘前单遍扫 g_df_edges 按节点序收集出边。头插链表遍历得到连续 EDG 数组加 first_edge/edge_count 回填 NOD）、段表和尺寸函数扩展
- [ ] Step 4: 读侧实现：load_ccr 接受 version 7、NOD 36B 读、EDG 解析加拓扑校验、段表 tag 6
- [ ] Step 5: 机械更新 test_ccr_v6.py（header/version 期望从 6 改为 7、V6File walker 段契约 NOD 从 28B 改为 36B 加 EDG 段走查加段表从 5 项改为 6 项、reject 面改为「拒 version≠7」。ENT 空断言与 roundtrip 用例暂留，Task 2 翻转或追加）；test_ccr_v7.py 通过（两文件并存窗口，Task 3 合并）
- [ ] Step 6: 构建加回归快子集（compile/backend_bootstrap/hit_table 24/24，corec build 全链走 v7 文件）
- [ ] Step 7: 提交 `feat: v7 格式框架：version 7 + NOD 36B 邻接 + EDG 段必落（写读同改，v6 读路径移除）`

---

## Task 2: ENT 主干化，corec 产实记录 + loader 激活

文件：
- 修改：`src/compiler/ccr_io.cr`（save：ENT writer（:558-587）从恒 0 改为实记录，corec 侧条目计算加 28B 盘布局 {var_id,version,def_nod,live_start,live_end 半开,home=-1,flags}；calc_ccr_size/ccr_ent_seg_size 扩展；load：ENT 实记录路径激活（:1076-1145 已有解析/校验/函数块对照代码，恒空时从未走到））
- 修改：SYM func 记录写侧（:442-453 first_ent/last_ent 从恒 -1 改为实回填；param_ents 从 -1 改为参数条目 id）与 REG 写侧（:610-611 first_ent/last_ent 实回填），与 ENT 同提交（loader 块对照校验消费）
- 测试：`tests/selfhost/test_ccr_v7.py`（ENT 非空断言加字段语义 spot-check：已知小程序的条目数/版本切分/区间与 Python 独立期望对照，期望按 v6 第 4.1 节规则手算）

接口：
- 读取：Task 0 的 regalloc compute_entries 规则对照清单（corec 侧独立实现，corec 二进制不含 regalloc.cr）
- 产出：`fn compute_entries_v7() -> int`（corec 侧：定值点收集，IR_STORE 的 s1 并上其余 dest≥0，两处 carve-out 为 STORE_INDEX_VAR/STORE_PTR/DYN_DISPATCH 排除；版本切分；区间为图坐标 [def_k, def_{k+1}) 截断 [first_ref, last_ref+1)；参数和全局 def=-1 条目；写入 g_entry_count/ent 缓冲，28B 盘布局含 version 和 live_end 半开转换）；loader 校验（evr≥1、ev 命名空间、els<ele≤instr_cnt、ed==els 加 SYM 块对照）
- home 恒 -1，实例注记：分配决策由 corearch 实例层自算，文件 ENT 不表示；corearch regalloc 保持自算不变，文件 ENT 是校验面和语义消费通道的数据源，也是行为零变化检查的基准。
- 无方法条目（flags bit0）：现 IR 面没有此形态（边界或不可重算未进 .ccr），flags 恒 0 落盘，bit 语义保留（字节 spec 声明）。

- [ ] Step 1: 写失败测试：ENT 实记录断言（现在恒 0 条，预期失败）
- [ ] Step 2: 跑测试确认失败
- [ ] Step 3: corec 侧 `compute_entries_v7()` 实现（镜像 regalloc.cr:180 规则，Task 0 差异清单逐条对齐）加 save ENT 实写加 SYM/REG first_ent/last_ent/param_ents 回填
- [ ] Step 4: loader ENT 路径激活（实记录 parse/校验/块对照，激活后即被全链消费）
- [ ] Step 5: 测试通过（ENT 断言加 reject 面：坏 version 条目、越界区间）加回归快子集（行为零变化，corearch regalloc 自算未动）
- [ ] Step 6: 提交 `feat: ENT 主干化：corec 产实记录（v6 第 4.1 节规则执行化）+ loader 激活 + SYM/REG 条目回填`

---

## Task 3: 测试族迁移结束，test_ccr_v7 全量 + 回归 + 自举 + 文档

文件：
- 修改：`tests/selfhost/test_ccr_v6.py`，迁移合并进 `test_ccr_v7.py`（V6File walker 改为 V7File walker 全段游走（段表规范序/连续/走满校验，Python 侧严格段契约保留）加 NOD 36B 加 EDG 解析加 ENT 实记录 shape 加 reject 面：version≠7、坏 EDG（to_nod 非前向或计数不符）、坏 ENT（evr 越界或区间倒置）。byte-mutation 先例沿用（test_ccr_v6.py:302/543 同款））
- 修改：`docs/ir-schema/coreir-schema.md`（.ccr 列从「线性化」改为「图实现方式」，执行序等于投影）
- 修改：`docs/archive/2026-09-05-lattice-ir-v6-format.md`（状态注记：被 v7 取代。原则 6 的 v5 槽模型标为 P1 泄漏源，开放点 1 的边表裁决标为 v7 必落）
- 测试：全量回归面加 `test_backend_bootstrap.py`（stage 链走 v7 文件 byte-identical）加自举重建

接口：
- 读取：Task 1/2 全部
- 验证：全量回归通过（mw1-6/live_ranges/region_cfg/compile/backend_bootstrap/hit_table/slice_bounds 加 bootstrap 三套）；stage 链（stage1.ccr = v7，stage2/stage3 byte-identical）；`nice -n 19 python3 build_selfhost_native.py` 重建后快速验证（corec check/run 小样本）；文档同步

- [ ] Step 1: test_ccr_v7.py 全量合并（V7File walker 加全用例。删 v6 专属断言：version-5-reject 改为 version≠7-reject；ent_optmeta_absent 改为 ent 实记录 shape；roundtrip/build 链用例改 v7 期望）
- [ ] Step 2: 全量回归跑批（面为全局约束中的回归面全项）
- [ ] Step 3: 自举重建加快速验证（新 corec/corearch：backend_bootstrap stage 链加 corec check src/compiler）
- [ ] Step 4: 文档同步（ir-schema 三形态列修订、v6 format spec 状态注记、progress 清单）
- [ ] Step 5: 提交 `feat: v7 结束：测试族迁移（V7File walker 全量）+ 全量回归 + 自举重建 + 文档同步`

---

## 风险注记

- Task 1 是最大任务（写读同改同日切换）。段内中间态只存在于 implementer 工作区，提交时即通过；检查是回归快子集加 hit_table 24/24（表路径是独立的行为回归检查）。
- EDG 出边序是内存头插逆序落盘，序任意但确定；测试断言按「边集合或计数」而不按序（Task 0 期望清单明确）。
- loader 守卫面（段表规范序/逐段越界/root span/ENT 块对照）在 v7 全部保留，测试迁移时重新确认（V7File walker 是无需额外成本的格式回归检查）。
- CSE 疑点不在本计划修复（行为检查要求 v6 链现状保持）；Task 0 注记供后续优化挂载点设计。
- corearch regalloc 自算保持不变（行为零变化的基准）。文件 ENT 与自算的差异面属于未来消费切换的独立决策，本计划不做双算对照。
- Task 1 越界配套注记（2026-09-09 评审裁决，用户批准推迟）：elf.cr hit_rel 回填守卫重构（语义等价规避）随 Task 1 同提交。激活面是既有编译器巨型函数尾代码生成缺陷（v6 时代潜伏，v7 loader 帧轮廓改变陈旧栈值后激活；TODO.md 预存 Bug #4 已注册跟踪，含 repro/gdb 证据/子系统假设）。Task 1 关闭条件是跟踪项注册，已满足。

---

## Task 0 盘点结果（执行时回填）

> 盘点完成（2026-09-09）。基源为 ccr_io.cr 全文件（写侧 save_ccr :345-636，读侧 load_ccr :658-1145）加 dataflow.cr（emit 双写加 df_connect_srcs/df_connect_state 加 g_df_edges）加 regalloc.cr（compute_entries :180-268）加 test_ccr_v6.py（V6File walker 严格段契约）。关键基准已内联于各任务 Files/Interfaces 节（2026-09-09 勘探输出）；Task 0 执行者按仓库惯例以代码复核为准。下列三表执行时回填：

表一：EDG 内容期望清单（权威 = dataflow.cr `df_connect_srcs` :194-315 / `df_connect_state` :160-177 / `sg_pop` 终止边 :84-99 / `df_use_var` :179-190；op 全集 = ast.cr :538-588，0-51 无 40。Task 1 测试期望 = 本表加表一注记的伪边规则手算）

| op 类别/区间 | op | 数据边（kind=0，本节点创建时自生产者连入，按操作数角色逐槽一条，平行边不合并） | state 边（kind=1，本节点创建时自 state 头连入 + 本节点成新头） |
|---|---|---|---|
| 字面量 | CONST(1) | 0（s1 = 标量值） | 无 |
| 算术/逻辑 | BINARY(2) | 2（s1、s2；s3 = op 子码非 var） | 无 |
| | UNARY(3) | 1（s1） | 无 |
| 浮点换算 | I2F(49) / F2I(50) | 0（s1 实为 var，但 df_connect_srcs 未列，属 GAP 族） | 无 |
| 指针/索引计算 | ADDR_INDEX(31) | 0（s1=arr_var/s2=idx_var 实为 var 但未列，属 GAP 族；ir_gen.cr:1129 真实发射） | 无 |
| 内存读 | LOAD(10) / LOAD_FIELD(11) / LOAD_INDEX(13) | 1（s1） | 无（读不连 state 链） |
| | LOAD_INDEX_VAR(15) | 2（s1、s2） | 无 |
| | DEREF(25) / LOAD_ENUM_TAG(23) | 1（s1） | 无 |
| | SLICE(24) | 3（s1、s2、s3） | 无 |
| 越界守卫 | BOUNDS_CHECK(30) | s1；type_kind≠0 时加 s2（动态界，ir_gen.cr:105-114 发射 tk=1），共 1 或 2 | 无 |
| 内存写 | STORE(9) | 2（s1 目标、s2 值） | 入链 |
| | STORE_FIELD(12) | 2（s1、s2） | 入链 |
| | STORE_INDEX(14) | 2（s1=arr、s2=val；s3 = 常量下标） | 入链 |
| | STORE_INDEX_VAR(16) | 2（s1=arr、s2=idx）。dest = 被存值源（值 var）不入边，属 GAP；s3 = 字面量 0，产生 0-slot 伪边（见注 A） | 入链 |
| | STORE_PTR(26) | 2（s1、s2） | 无，属 GAP（raw 指针内存写不连 state 链） |
| 分配/释放 | ALLOC(6)/ALLOC_STRUCT(7)/ALLOC_ARRAY(8) | 0 | 无 |
| | ARENA_NEW(32) | 名义 s1；实际发射 s1 = 0 字面量（ir_gen.cr:1663/1701/1761/2161/2275），产生 0-slot 伪边（见注 A），有效数据边 = 0 | 无 |
| | ARENA_RESET(33) | 1（s1 = arena_var 真 var） | 无，属 GAP（arena 复位不连 state 链） |
| 引用/解引用 | REF(18) | 1（s1） | 无 |
| 调用族 | CALL(4) | s2 条（args 自 s1 连续 s1..s1+s2−1 逐参一条；s2=0 则 0 条） | 视纯度：find_func(s3)（s3 = 函数名 idx）< 0 或 fi_ispure==0 时入链 |
| | CALL_EXTERN(45) | 1（仅 s2 = 首参），多参缺口属 GAP（s3 = arg_count，args 2..n 不入边） | 无，属 GAP（extern 副作用不连 state 链） |
| | SPAWN(27) | s2 条（同 CALL 参数遍历） | 无 |
| | HOTPATCH_ROUTE(39) | 1（仅 s2 = 首参），多参缺口同 CALL_EXTERN | 无 |
| | LAZY_THUNK(46) / LAZY_FORCE(47) | 1（s1） | 无 |
| 动态类型 | DYN_TAG(41)/DYN_VAL(42)/DYN_PACK(43)/DYN_DISPATCH(44) | 1（s1；DYN_PACK s2 = type_idx 字面量） | 无 |
| 控制流 | BRANCH(19) | 1（s1 条件 var；s2/s3 = label id，非 var。v7 第 4 节边界声明「目标是操作数不是边」同源佐证） | 无 |
| | JUMP(20) | 0（s1 = label id） | 无 |
| | RETURN(5) | s1 ≥ 0 则 1，否则 0 | 无 |
| | LABEL(21) | 0 | 无（但可作 state 链头被后续边引用，出边出现在后续 state 节点创建时） |
| 流程/并发 | YIELD(28)（s1=value var）/ AWAIT(29)（dest、s1） | 0（实为 var 但未列，属 GAP 族） | 无 |
| 函数地址 | FNADDR(48) | 0（s1 = name idx int） | 无 |
| 编译期标记 | NO_BOUNDS_CHECK(35)/FAST(36)/UNROLL(37)/SECTION(38)/APPROX(51)/NOP(0) | 0 | 无 |
| 内联提示 | INLINE(34) | 1（s1） | 无 |
| 合并伪节点 | PHI(22) | 0 | 无（注：全仓 ir_gen/pass/interp/instr 无 IR_PHI 发射点，恒不出现） |
| 枚举构造 | MAKE_ENUM(17) | 0（s1 = variant name idx；字段走 STORE_FIELD） | 无 |
| 区域结束（非 op，sg_pop 附加） | SG_LOOP(1)/SG_FOR(2) 结束（dataflow.cr:84-99） | 无 | 区内最后 state 节点到区出口 label 节点 kind=1 终止边（条件：`g_last_state_node ≥ NSTART`，纯循环体无区内 state 则不产）；随后 state 头 = 出口 label 节点 |

注 A（0-slot 伪边，本表最关键的实测发现）：`g_df_var_producer` 只在节点 `dest ≥ 0` 时写入 nid。执行 -1 初始化循环（init_df dataflow.cr:28-34）时 `g_ir_var_count == 0`（main.cr:396-408 的顺序是先清零，再 init_df，再 ir_gen_globals）。`grow_df_arrays`（dyn_arr.cr:516）的新段来自 alloc 零页，因此从未被定值的 var（全局、参数、未定值临时）producer 槽 = 0，即「节点 0」。`df_use_var`（判 `producer >= 0`）因此产出 0 号节点到消费者的伪数据边。节点 0 是 func0 的 arena_new（每函数首节点是 arena_new，ir_gen.cr:2275），所以每次编译都会出现自环 (0,0)。双程序实测（v7t0_probe / v7t0_cse 的 cir DOT）：n0 到 n0 的自环存在；参数读始终是 0 号节点到读点的伪边。这与 v7 字节 spec 第 4 节不变量 1「每条边 to_nod > 所属节点」直接冲突。Task 1 必须先定夺一种处置：(a) 修 dataflow.cr 的初始化（grow 后新区写 -1，或把 init_df 延后到 globals 注册后），这会改 .cir 视图，但不动发射行为；(b) v7 写侧过滤自环和 0 到 X 的伪边（写侧净化，loader 校验面不动）；(c) 放宽校验（自环合法），不建议，因为会削弱图 DAG 语义。本计划的判定线是任务内定夺，不影响 Task 2/3（ENT 规则不涉及边集）。

表二：compute_entries 规则对照（权威 = regalloc.cr `compute_live_ranges` :48-111 加 `compute_entries` :180-268；corearch 专属，build_selfhost_native.py 清单确认 regalloc.cr 仅在 corearch concat 列表；src/compiler/regalloc-consistency.cr 是两个二进制都不编译的文档残留。Task 2 的 corec 侧 `compute_entries_v7` 镜像对齐清单）

| # | v6 第 4.1 节规则或计划文字 | regalloc.cr 实现 | 差异 / Task 2 对齐项 |
|---|---|---|---|
| 1 | 定值点 = IR_STORE 的 s1 并上其余 dest≥0（carve-out：STORE_INDEX_VAR/STORE_PTR/DYN_DISPATCH 排除） | :206-212 逐条一致（STORE 先判 s1；三 op else-if 排除；其余 dest）；追加约束：目标 var 须 ∈ [vs, vs+vc) 本函数 var 窗口 | 无差异。corec 侧同窗口约束；坐标 = NOD id 全局序（等于实现侧 `inst = ist + ii` 的全局坐标；corec 侧 ist 同源，即 df func start，ii 序 = NOD 序） |
| 2 | 版本切分；结束 end = min(def−1, last_ref) | :218-224 结束上一版本 `pend = min(inst−1, last_global)`，last_global = var 级 last_ref（含定值自身，dest 列计入引用，恒 ≥ 次定值，因此 min 恒取 def−1，数学与 spec 截断式等价）；末版 le 直接等于 last_ref | 无差异（版本号不落盘：save 侧 vcnt 计数槽 :561-587 已实现，Task 2 激活） |
| 3 | 参数/全局条目 def_nod = -1，区间 = [函数首节点, last_ref+1) | :240-262 只对函数窗口内从未定值但有引用的 var 产 def=-1 条目，区间为 [first_ref, last_ref] 闭区间（live_start = 首引用指令，非函数首节点） | 差异1（文档面）：v6 第 4.1 节 3 文字「区间 = [函数首节点…]」与实现不符。实测 pure_add 参数 a/b 条目 live 1..1（首引用 = BINARY @n1，函数首节点 = 0）。Task 2 镜像按实现（loader 只校验 els < ele ≤ instr_cnt、def≥0 时 ed == els，两语义都过，但「双写对照一致」要求两侧同规则）；测试手算期望按实现语义 |
| 4 | 参数/全局 def_nod = -1 | 全局 var（SYM 前缀 0..G−1）不在任何函数 var 窗口，因此恒无条目（flags bit2「全局」永不落） | 差异2（文档面）：v6 spec 第 3.2/4.1 节的「全局条目」面在实现中不存在，SYM globals 记录是全局的唯一存在面。Task 2 同实现（v7 字节 spec 第 3.5 节 flags bit2 语义保留，即零实例声明） |
| 5 | 活区间（first/last_ref 扫描）为结束前提 | compute_live_ranges :48-111：逐函数逐指令扫 d/s1/s2 三列 ∈ 窗口，得到 [first_ref, last_ref]（未用则双 -1） | 对齐项（实现前提）：corec 二进制没有 regalloc.cr，`compute_entries_v7` 须自含同规则引用扫描（或等价的 df 出边反扫。注意 df 边有注 A 的伪边缺陷，不得以 df 边替代三列扫描） |
| 6 | 条目按函数升序成块；函数块界由 loader 按 var 窗口切 | :105-110 compute_live_ranges 尾部逐函数调 compute_entries（func_i==0 整表重置）；块内序 = 定值指令序，尾部 def=-1 补丁按 var 序扫 | 无差异（loader 分块 :1114-1145：pv ∈ [fvs, fvs+fvc)，fvc≤0 时块断，pcnt=0 对照 ffe==-1；与 SYM func first/last 双写对照已实现） |
| 7 | home/flags | 恒 home=-1、flags=0（:232/:255） | 无差异（v7 字节 spec：home 恒 -1 直通、无方法/参数/全局/驱逐位零实例） |

表三：落盘序核对（权威 = ir_gen.cr `emit` :193-206 / main.cr ccr 与 build 路径 :527-583 / dataflow.cr `lower_to_ccr` :351-391 / cir_cache.cr 恢复 :242-415）

| 核对面 | 结论 |
|---|---|
| NOD 落盘源 = lower_to_ccr 后的 g_ir_instrs？ | 是。save_ccr :542-556 逐条读 g_ir_instrs；main.cr :534 lower_to_ccr 先于 :557/:581 save（ccr/build 两路径同）；lower_to_ccr 先清零 g_ir_instr_count，再自 g_df_nodes 0..count−1 逐字段重建（:356-371），func 边界自 df func start/count 复制（:375-383）。因此 NOD = g_df_nodes 镜像，1:1 同序 |
| emit 双写之外有无第三写点破坏 1:1？ | 全线性流写点审计：emit（双写同参）、cir_cache 恢复（load_cir_cache :242-407，节点 :288-318/SG :321-356/边 :358-374/指令 :376-392 同快照双写，cache-hit 函数两表同参恢复，1:1 保持）、pass_cse（opt.cr :194-290 只 iri_set_op/iri_set_s1-3 改线性，lower 后回滚，见表后 CSE 注记）、lower_to_ccr。ir_gen 直改线性后补丁（arena size `iri_set_s1` ir_gen.cr:1711/:2287 等，另 :1674/:1772/:2165）只落线性侧，df 节点保持 emit 原值，因此 lower 后 NOD = emit 原值（既有行为，v7 同构，非本计划面） |
| EDG 节点 id 与 NOD 文件序一致的前提 | 是。节点 id 全局单调追加（init_df 每编译一次 main.cr:407，无逐函数清空）；df func 切片是 start/count 视图（df_begin_func/df_end_func :395-410）；lower 后指令 i 等于 df 节点 i 等于 NOD 文件序 i，EDG to_nod 引用与文件序一致的前提成立；REG enter/exit 同坐标系（loader 回填 func 边界 :1017-1033 与 GC-3 上界校验 :1061-1074） |
| g_df_edges 节点 id 空间 = g_df_nodes（无跨函数泄漏？） | from/to 都在创建时点取节点 id，缓存恢复边同快照，id 空间一致。跨函数数据边有两种形态：(a) 表一注 A 的伪边（node 0 到任意函数消费者，实际跨函数）；(b) 缓存快照边，缓存命中恢复 save 时点的全图边（cir_cache.cr :167-179 存全量），源不变时与重建同态。源变时（前序函数指纹 miss 重建、后续函数仍命中）快照边陈旧，这是既有 .cir 缓存的潜在问题，待核注记。state 链无跨函数（df_begin_func 重置 g_last_state_node :401）。Task 1 测试建议使用新路径或清 .core/cache 运行，避免缓存面混入期望 |
| 逐函数图清空机制 | 不存在。df 数组编译期全局追加，「每函数一图」只是切片视图。v7 写侧「按节点序收集出边」单遍扫 g_df_edges 即可（头插链表，落盘序任意但确定，节点出边连续布局由写侧回填 first_edge/count） |

CSE 时序 byte 级实测（注记，非修复项，全局约束判定线确认）：源为双函数含重复纯子表达式（x*x 双现 ×2、helper a*a 双现加循环内双现，NOD 解析证实 3 组可 CSE 的重复）。命令（每跑前 rm -rf .core 清缓存）：
`nice -n 19 /home/DslsDZC/core/build/corec ccr /tmp/v7t0_cse_test.cr -o /tmp/v7t0_O0.ccr --opt-level 0` 与同源 `--opt-level 1`，结果全文件 byte-identical（cmp 一致；sha256 均为 38cf7880d0db54ce…；NOD 段 = 72 节点 2020B，两版逐字节同）。代码路径佐证：main.cr:530-534 `pass_cse()`（opt.cr :194-290，只 NOP 或改写线性 g_ir_instrs）位于 `lower_to_ccr()` 之前；lower 自 g_df_nodes 全量重建，因此 O1 CSE 被整体回滚，NOD 落盘与 O0 始终相同。注：corec g_opt_level 默认 = 1，main.cr:203，默认运行即走此回滚路径，v6 现状如此。结论：CSE 疑点核实为「无效果 pass」，v7 落盘源是 df 镜像，与它无关，保持非修复项。
