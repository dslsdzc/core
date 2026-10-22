# corearch 内核组件完备化实施计划（步骤 2.5）

> 面向执行本计划的 agent：必须使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans，按任务逐项实现。用复选框（`- [ ]`）跟踪进度。

> 状态：实施完成（2026-09-10 Tasks 0-5 结束）。对应提交：Task 0 盘点 8c3e6ad1、Task 1 035ea289（加补正 72c40389）、Task 2 99fc6af3、Task 3 b4d8c74f、Task 4 b9685f5c、Task 5 为结束提交。中立性 guard A 组和 B 组全部通过（零残留），全量回归通过，自举重建快速验证通过，full-bootstrap guard 通过（corec2/corec3 cmp 相同加 N06=0），文档同步完成（设计 spec 状态改为已实施加执行注记第 7 节；方案步骤 2.5 完成注记加第 1.1 节三组件完成态）。执行注记为设计 spec `2026-09-10-corearch-kernel-completion-design.md` 第 7 节。

目标：内核三组件按方案第 1.1 节补完，并做全量中立化。2026-09-10 用户原则：内核零经典概念，寄存器、栈、调度、内存布局、指令任一概念都不得出现。工作包括：语义对象模型（对象面 API 加调度重建移实例）、A 通道中立化（compute 系改 NOD 对象面，内核零线性流引用）、B 通道中立化（登记表不透明位置加 LOC_HOME_BASE 移除）、注册契约完整（34 形式声明）。行为零变化。

结构：现状（步骤 2 结束态）是 ent_kernel.cr（判定引擎加数据面，双 concat）加 regalloc.cr（机器侧）加实例声明表。全量中立化审计（设计 spec 第 4.5 节）结论：全部经典残留来自一个原因族的两条通道。A 是线性流坐标派生读取，有 4 个函数 4 个 iri_* 使用点，涉及 compute 系、dump、rl_rule2。B 是位置通道，meta_reg_for_var 读实例布局，加 LOC_HOME_BASE 编码。本计划做中立化波：写侧 populate_nod_objects（corec 镜像对称），compute 系改 NOD 对象面（同 index，F5），登记表不透明化（实例双面同步责任在实例），输出面中性化加方法查询补体加 34 声明。检查是行为零变化（全回归加 byte-identical 面）加中立性静态 guard（A 组和 B 组 token 从失败改为通过）。

技术栈：ent_kernel.cr（内核）、regalloc.cr（实例机器侧）、ccr_io.cr（loader 收敛加写侧 populate）、corearch.cr（引导和实例侧调用）、build_selfhost_native.py、Python 测试（test_live_ranges.py/test_ccr_v7.py 检查基准加 test_ent_kernel_neutrality.py 中立性 guard）。

设计 spec：`docs/superpowers/specs/2026-09-10-corearch-kernel-completion-design.md`（本计划执行依据：第 1 节对象模型、第 2 节中立化、第 3 节契约、第 4 节检查、第 6 节待办）。

## 全局约束

- 版本控制用 `jj`，见项目规则第 2 条，git 被 hook 拦截。每任务用 `jj commit -m '<msg>'`。
- 构建 `nice -n 19 python3 build_selfhost_native.py`，约 2-3 分钟；测试加 `nice -n 19` 前缀，见项目规则第 6 条；清 .core/cache 跑测试。
- 行为零变化硬约束：全回归通过加 byte-identical 面（backend_bootstrap stage 链加 ccr_v7 产物）。重建移实例和登记表通道属于纯迁移加通道等价，产物不变。
- 迁移和改动纪律：函数体迁移零改动；登记表通道切换是语义等价改写，禁止顺手改判定逻辑；禁止新增接口抽象（现名即 API 的裁决延续，新增面为 kern_loc_*/对象面访问器，且须是设计 spec 明列者）。
- 中立性目标（全量）：ent_kernel.cr 零经典概念引用，包括实例符号（g_opt_meta/寄存器名/ELF 段名）、线性流（g_ir_instrs/iri_*）、位置编码（LOC_HOME_BASE）。test_ent_kernel_neutrality.py 静态 guard 入回归面（A 组 Task 2 通过，B 组 Task 3 通过）。
- corec 写侧不受影响（不经 loader）；interp 不经 loader。
- 判定34 不实现（用户裁决，needs_* 形式声明字段落契约）。

---

## Task 0: 盘点，对象面和移出面的依赖核对（计划基准）

文件：分析产出，无代码改动，注记回填计划附注。

- 核对 load_ccr 内 NOD 到 g_ir_instrs 重建段的完整依赖面：重建段消费或写哪些全局（g_ir_instrs/g_ir_func_instr_*/g_label_*/g_v7 边缓冲/nod_edge_meta 暂存）；GC-3 root span 上界校验消费什么（nod_count 与 instr 流，确认移出后守卫仍成立）；ENT 校验是否依赖线性流（evr/els/ele 界 = NOD 坐标，确认）；loader 内其余段（STR/SYM/REG）与重建段的顺序依赖。
- 节点到区域映射（region_of_nod）定夺：v7 文件没有 g_df_node_region，loader 现在是否重建（REG enter/exit 端点推导）？对象面 API 是否包含 region_of_nod（包含则重建推导，不包含则区域面只有 REG 行遍历）。产出定夺注记。
- 登记表接入面核对：alloc_registers phase 5（写 g_opt_meta 点）加注入钩子 6+1（写点清单）加 regalloc_debug_dispatch 各 flag 路径（判定何时读登记表：compute 后还是 alloc 后），形成登记 API 调用点清单。
- 判定读 meta 面清单：verify_regalloc_consistency/rl_rule2_func/meta_reg_for_var 的 g_opt_meta 读点全集，作为登记表切换的精确函数面。
- 中立性 guard 设计：扫描 ent_kernel.cr 现引用面（g_opt_meta 引用点即待切清单，其余实例符号即断言排除集）。
- 交付：注记回填本 plan 附注「Task 0 盘点结果」节。

---

## Task 1: 语义对象模型，对象面 API + 调度重建移实例

文件：
- 修改：`src/compiler/ccr_io.cr`（load_ccr：NOD 到 g_ir_instrs 重建段移出，loader 产出对象载入加守卫；重建相关写点清理）
- 修改：`src/arch/linux/ld/regalloc.cr` 或新实例函数位（`build_linear_schedule()`，重建段函数体迁移，corearch concat 内实例侧；corearch.cr 发射前调用）
- 修改：`src/arch/linux/ld/ent_kernel.cr`（对象面 API：nod 面访问器加 v7_edge 访问器加方法查询薄封装，见设计 spec 第 1.2 节；若 Task 0 定夺 region_of_nod 为包含，则加区域推导访问器）
- 修改：`src/compiler/corearch.cr`（load 后调 build_linear_schedule）
- 测试：`tests/selfhost/test_ccr_v7.py`（23/23 保持；对象面新测试：EDG 方法可读断言，节点出边遍历与 v7 Task 0 表一去除伪边后的期望复用）

接口：
- 读取：Task 0 依赖面清单
- 产出：对象面 API（nod_op/nod_dest/nod_s1-3/nod_tk/nod_edge_first/count/v7_edge_to/kind，属于 ent_kernel 内核面）；`build_linear_schedule()`（实例面，从对象重建 g_ir_instrs）
- 检查：ccr_v7 23/23 加 backend_bootstrap stage 链 byte-identical（重建产物相同，纯迁移）加回归快子集
- loader 守卫强度不变（段表/拓扑/root span/ENT 双写，即 Task 0 确认的守卫面）

- [ ] Step 1: 写失败测试：对象面 EDG 方法读断言（节点出边遍历等于已知小程序期望。现在没有 API，预期失败）
- [ ] Step 2: 跑测试确认失败
- [ ] Step 3: 对象面 API 实现（ent_kernel 的 nod/edge 访问器加方法查询；region_of_nod 按 Task 0 定夺）
- [ ] Step 4: 重建段移出：load_ccr 清理加 build_linear_schedule 落实例侧加 corearch 调用接线（load 后、发射前）
- [ ] Step 5: 测试通过（对象面新断言加 ccr_v7 23/23 加 backend_bootstrap stage byte-identical）加回归快子集
- [ ] Step 6: 提交 `feat: 内核完备 Task 1：语义对象模型（对象面 API + 调度重建移实例）`

---

## Task 2: A 通道中立化，compute 系改 NOD 对象面 + 写侧 populate（全量审计 F1/F2/F3/F5）

文件：
- 修改：`src/compiler/ccr_io.cr`（corec 写侧 `populate_nod_objects()`：lower 后单遍 g_ir_instrs 到 g_v7_nod_sem 镜像，28B 语义字段，与 loader 解析对称。写侧实现方式裁决 2026-09-10；save_ccr 调 compute 前（:456 区）接入）
- 修改：`src/arch/linux/ld/ent_kernel.cr`（compute_live_ranges/compute_entries/rl_rule2_func/dump_entries_summary 的 iri_* 4 个使用点（:99/:227-233/:677-680/:367）改为 nod_* 对象面，同 index 机械替换（F5）；函数窗口源中性化（F3。现在 g_ir_func_instr_* 的值 = NOD 坐标，以节点范围语义注记使用；rl_rule2_func 签名 ist/ic/vs/vc 措辞中性化，值不变）；消除头注自证矛盾（:819-823））
- 测试：`tests/selfhost/test_live_ranges.py`（13/13，dump 通道输出逐字节同，坐标值不变）加 `tests/selfhost/test_ccr_v7.py` 24/24（ENT 产物 byte-identical，populate 镜像加 compute 同值）加回归快子集

接口：
- 读取：Task 1 对象面（nod_* 已建；corec 侧 populate 前 nod 缓冲为空，compute 时序在 populate 后）
- 产出：`populate_nod_objects()`（corec 写侧，ccr_io，corec concat 内）
- 检查：ENT 产物 byte-identical（写侧检查）加 dump 通道输出逐字节同加 O2 stage 链 byte-identical。核心检查是内核零 g_ir_instrs/iri_* 代码引用（中立性 guard A 组新增 g_ir_instrs token，本任务改为通过）

- [ ] Step 1: 中立性 guard 文件先写（test_ent_kernel_neutrality.py。排除集 = g_opt_meta 族/LOC_HOME_BASE/OPT_*/E2_*/g_x86_*/寄存器名/g_ir_instrs/iri_*。现态失败，早暴露纪律。A 组（g_ir_instrs/iri_*）与 B 组（meta/LOC）分注，Task 2 通过 A 组，Task 3 通过 B 组）
- [ ] Step 2: 写失败测试：populate 加对象面 compute（corec 写侧产物 ENT byte-identical 检查先行基线）
- [ ] Step 3: `populate_nod_objects()` 实现（g_ir_instrs 到 g_v7_nod_sem，48B 到 28B 字段镜像，同 loader 解析字段序）
- [ ] Step 4: compute 系 4 函数 iri_* 改为 nod_*（同 index，F1/F2）加函数窗口语义注记（F3，值 = NOD 坐标）
- [ ] Step 5: 测试通过（A 组 guard 通过加 ENT byte-identical 加 dump 输出同加 stage 链）加回归快子集
- [ ] Step 6: 提交 `feat: 内核完备 Task 2：A 通道中立化（compute 系改 NOD 对象面 + 写侧 populate，内核零线性流引用）`

---

## Task 3: B 通道中立化，登记表 + meta 改写 + LOC_HOME_BASE 移除

文件：
- 修改：`src/arch/linux/ld/ent_kernel.cr`（位置登记表 {entry 到 loc} 加 kern_loc_assign/kern_loc_clear/kern_loc_of；verify 规则12 读通道切换（meta_reg_for_var 改读登记表，函数体等价改写）；LOC_HOME_BASE 常量移除，引用面（:500/:590/:744）改写。位置是不透明整数，零域分类（第 2.2 节修正：home 面 = 条目字段独立互斥遍；合成若需保留 = 实例侧事务）；无 kern_set_loc_domain，无域参数（废弃，依据 2026-09-10 用户原则：内核无寄存器/域分类概念））
- 修改：`src/arch/linux/ld/regalloc.cr`（alloc_registers phase 5 加注入钩子写 g_opt_meta 后调 kern 登记或清除，双面同步；meta_reg_for_var 函数体等价改写为登记表查询，不删（Task 0 4 修正注：regalloc.cr 注入探针 try_inject_read_gap :254/:261 调用它，须同步改实例侧私有扫描或经登记表等价读；emit 面 instr.cr get_reg_for_var 是独立实现，不受影响））
- 测试：`tests/selfhost/test_live_ranges.py`（13/13，判定失败和通过路径经登记表通道输出与直读时代逐字节同）加 test_ccr_v7.py 24/24

接口：
- 读取：Task 0 登记 API 调用点清单加 Task 1 对象面加 Task 2 A 通道
- 产出：kern_loc_assign/clear/of；登记表（内核数据，loc = 不透明整数）
- 检查：test_live_ranges 13/13（通道切换输出同，先基线后对照）加 O2 全链 byte-identical（--check-regalloc 通过或失败路径经登记通道）加回归快子集；guard B 组改为通过
- 双份同步纪律：实例写点成对（g_opt_meta 加登记），代码注记加注入钩子测试覆盖（失败路径 = 双面一致注入）

- [ ] Step 1: 写失败测试：登记表 API（kern_loc_assign，现在没有，预期失败），确认 guard B 组失败
- [ ] Step 2: 跑测试确认失败
- [ ] Step 3: 登记表加 kern API 实现（ent_kernel）
- [ ] Step 4: 判定读通道切换（verify/rl_rule2 读登记表，等价改写）；LOC_HOME_BASE 移除（引用面改写，home 面 = 条目字段独立互斥遍或实例侧合成，内核零域概念）
- [ ] Step 5: 实例侧双面同步（alloc phase 5 和注入钩子同步写 g_opt_meta 与 kern 登记；try_inject_read_gap :254/:261 同步，用实例侧私有扫描或登记表等价读，注记理由）
- [ ] Step 6: 测试通过（live_ranges 13/13 通道输出同加 ccr_v7 24/24 加 O2 byte-identical 加 guard B 组通过）加回归快子集
- [ ] Step 7: 提交 `feat: 内核完备 Task 3：B 通道中立化（登记表通道 + LOC_HOME_BASE 移除，内核零位置编码/零实例布局读）`

---

## Task 4: 输出面中性化 + 方法查询补体 + 注册契约完整化（34 声明）

文件：
- 修改：`src/arch/linux/ld/ent_kernel.cr`（rl_print_loc :589-595 中性化，不透明 loc 直印，去掉 reg/home slot 分类措辞；rl_report_rule1/2 措辞，「regalloc-consistency」前缀改为中性描述，保留 spec 文件名引用注记；方法查询封装补体（857-860 悬空注：nod_inputs(n) 薄封装函数，遍历 [first, first+count)，审计 API 缺口）；34 形式声明字段文档加 kern_verify_all 输出面注记）
- 修改：`src/compiler/corearch.cr`（g_instance_decl 行扩展：needs_eviction/needs_call_sites 字段加行数据（x86: {0, 0}）。home_base/reg_domain 已从范围删除（第 2.2 节修正））
- 测试：`tests/selfhost/test_live_ranges.py`（13/13，flag 通道输出不变，措辞中性化不影响断言面确认；dump 文本断言如含 reg/home slot 字样则同步更新断言为中性措辞）加方法查询新断言（对象面遍历 = 现 dump_object_surface 内联逻辑的函数化）

接口：
- 读取：Task 2/3（对象面加登记表，方法查询基于 nod_* 加 v7_edge_*）
- 产出：nod_inputs(n)（内核面，方法查询承诺兑现）；声明行 needs_eviction/needs_call_sites
- 检查：flag 通道输出不变（措辞中性化后文本断言同步。测试是行为基准，措辞是输出面）加 test_live_ranges 13/13 加回归快子集

- [ ] Step 1: rl_print_loc/rl_report 措辞中性化（loc 直印，测试断言同步）
- [ ] Step 2: nod_inputs 封装补体加方法查询测试（对象面遍历函数化）
- [ ] Step 3: 声明行 needs_eviction/needs_call_sites 扩展加 34 文档注记（引擎不实现，引用设计 spec 第 3.2 节）加 kern_verify_all 输出面注记
- [ ] Step 4: test_live_ranges 13/13 加回归快子集
- [ ] Step 5: 提交 `feat: 内核完备 Task 4：输出面中性化 + 方法查询补体 + 注册契约完整化（34 声明）`

---

## Task 5: 结束，中立性 guard 全部通过 + 全量回归 + 自举 + 文档

文件：
- 测试：中立性 guard 全量通过确认（A 组 Task 2 通过加 B 组 Task 3 通过，记录从失败到通过）加残留清零
- 测试：全量回归（compile/backend_bootstrap/hit_table/region_cfg/mw1-6/slice_bounds/live_ranges/ccr_v7/bootstrap 三套加 full-bootstrap guard）
- 修改：`docs/superpowers/specs/2026-09-10-corearch-kernel-completion-design.md`（状态改为已实施加执行注记回填，含审计结论（第 4.5 节）/写侧实现方式裁决/登记表双份纪律实证/34 声明位置/F4 待办）
- 修改：`docs/superpowers/specs/2026-09-09-corearch-rewrite-design.md`（步骤 2.5 完成注记加第 1.1 节三组件完成态）
- 测试：`nice -n 19 python3 build_selfhost_native.py` 重建加快速验证

接口：
- 读取：Task 2-4 全部
- 验证：中立性 guard 全部通过（内核零实例符号/零线性流/零位置编码）加全量回归通过加自举重建快速验证加文档同步（设计 spec 状态/方案步骤 2.5 注记/progress 清单）

- [ ] Step 1: 中立性 guard 全量通过确认（记录从失败到通过，A/B 组分注）加残留清零（若有，回对应通道补漏）
- [ ] Step 2: 全量回归跑批
- [ ] Step 3: 自举重建加快速验证
- [ ] Step 4: 文档同步（设计 spec 状态回填含审计注记/方案步骤 2.5 注记）
- [ ] Step 5: 提交 `feat: 内核完备结束：中立性 guard 全部通过 + 全量回归 + 自举 + 文档同步`

## 风险注记

- Task 1 重建移出是最大改动面（loader 与发射之间的契约变化）。检查是 backend_bootstrap stage byte-identical（证明重建产物是纯迁移）；loader 守卫面由 Task 0 核对，防止遗漏。
- Task 2 通道切换是判定语义等价改写面。基线对照纪律：直读时代输出与登记表通道输出逐字节同。双份同步漏点由注入失败路径测试覆盖。
- 域参数面已整体废弃（2026-09-10 用户原则修正：内核零域分类概念；原 kern_set_loc_domain/home_base/reg_domain 设计删除，见设计 spec 第 2.2 节修正注）。
- 中立性 guard 若在 Task 4 发现 ent_kernel 残留实例引用，回 Task 2 面对应补漏（guard 先写，早暴露）。
- corec 写侧和 interp 不经 loader，零影响，回归验证即可。

---

## Task 0 盘点结果（已回填，2026-09-10，实施 Task 1-4 依此定基准）

> 基源为设计 spec（权威）加步骤 2 结束态代码（ccr_io.cr 1372 行 / ent_kernel.cr 807 行 / regalloc.cr 795 行 / corearch.cr 492 行现态）。行号是盘点日基准（后续改动若变化，以语义为准）。

### 1 load_ccr 重建段依赖面（Task 1 移出裁决依据）

- 重建段实际位置（纠正旧基准）：NOD 到 g_ir_instrs 线性重建在 ccr_io.cr 的 NOD 段解析 :1207-1236（盘 36B 到内存 48B：grow_ir_instrs(instr_cnt) :1211 加逐记录 iri_set_op/dest/s1/s2/s3/tk :1228-1233 加 g_ir_instr_count 递增 :1234）。不在先前基准约 :1361-1393（现文件 1372 行，EDG 校验尾 :1369，旧基准过时，重核如上）。消费的是 data 缓冲加 seg_off3/seg_end3（段表局部），不读任何 g_ir_* 内容。nod_edge_meta 是 load_ccr 的局部暂存（:1213 alloc 16B/节点 {first_edge, edge_count}，非全局）。g_v7_edges/g_v7_edge_count（全局，:1343-1344 写）属于 EDG 段，不属于重建段。
- 守卫消费面（决定性事实，重建移出后全部成立）：GC-3 root span 上界校验 :1244-1251 消费 g_ir_func_instr_start/count（REG 段派生回填 :1186-1202）加 NOD 段头计数 instr_cnt（局部变量，不是 g_ir_instrs/iri_*），因此线性流零依赖。ENT 校验 :1255-1322（evr≥1/var 命名空间/els≥ele、ele > instr_cnt 拒收 :1275、ed ≥ instr_cnt :1277、ed == els 定值恒等；界全是 NOD 坐标加 SYM var 命名空间；函数块界重建 :1291-1321 读 g_ir_entries 内容加 fn_meta，SYM first/last 双写对照）因此线性流零依赖。EDG 校验 :1335-1369 消费 instr_cnt 加 nod_edge_meta（NOD 邻接域 :1349-1352），因此线性流零依赖。load_ccr 全程零 iri_* 读。
- 移出推论：loader 仍须读 NOD 段计数（段界校验必需）与每记录邻接域 first_edge/edge_count（36B 记录偏移 +28/+32，即 first_edge@+28、edge_count@+32，s1 为 8B 占 +8..+16；EDG 守卫消费）。28B 语义字段写入线性流是唯一可迁移的部分。现 NOD 语义字段除 g_ir_instrs 外无任何保留（含邻接 = load_ccr 局部），因此 Task 1 须裁决 NOD 对象留存形态：对象存储，或 build_linear_schedule 重扫 data 缓冲（buf 存在至 corearch_main 尾，重扫式可行；文件段偏移现为 load_ccr 局部，重扫式需要把 NOD 段界传出或重走段表）。
- 顺序依赖（现实现序 STR、SYM、REG、NOD、ENT、EDG，段按 offset 随机寻址）：SYM funcs 产 fn_meta 暂存，REG 根行对照 :1174-1180；REG 根 span，函数指令边界回填，GC-3（需要 NOD 计数）；NOD 计数，ENT/EDG 界校验；SYM 声明区，var 命名空间，ENT var_id 界；ENT 与 EDG 互不依赖。重建段在 loader 内零下游消费者，消费全在 load 返回后（见下）。
- load 后依赖面（接线点裁决）：corearch_main 内 load_ccr :295，然后 init_backend_arrays :297（仅 g_x86_* 数组，与线性流无关），然后 regalloc_debug_dispatch :305。dispatch 各分支直接消费线性流：dump-entries :153 / inject-coexist-oob :158 / dump-coexist :163 的 compute_live_ranges（扫 iri_dest/s1/s2）、dump-regassign :169 与 check-regalloc :191 的 alloc_registers、:199 regalloc_verify_all；生产 O2 门 :308-314（alloc 然后 verify）；ELF 发射面（elf.cr/instr.cr/resolve.cr）。因此 build_linear_schedule() 的接线点是 load_ccr 成功（:296）后、dispatch :305 前，紧邻 load。
- 旧结论（已修正）：另一 load_ccr 调用方是 src/arch/linux/ld/main.cr:56，曾判为死代码（2026-09-10 内核抽取 Task 4 自注记：零 concat 引用，实际入口是 src/compiler/corearch.cr），并判定改签名或迁移无须同步。2026-09-10 Task 1 评审 I-1 驳斥了这一点。证据见 Task 1 报告第 3 节偏差 1：该调用方是 backend_bootstrap stage 链活入口（project 模式 corec build src/arch/linux/ld，然后目录 main.cr corearch_main，然后 load_ccr :56，然后 build_linear_schedule）。Task 1 已接线，改签名或迁移须双入口同步。

### 2 region_of_nod 定夺（设计 spec 第 6 节待办 1 裁决 = 不包含）

- v7 文件没有 g_df_node_region；loader 不重建节点到区域映射，REG 段只派生 nstart/ncount（:1172-1173，即 enter/exit 副本写回 g_sgs 行），不产映射数组。corec 构建侧映射是构建期快照（dataflow.cr df_create_node:110 写 g_df_node_region[nid] = g_cur_sg，-1 = 无），不落盘。
- 零消费方事实：corearch concat 内 g_sgs 的唯一消费者是 ccr_io.cr loader 自身；ent_kernel/regalloc/instr/elf/resolve 全部零 g_sgs 读（判定12 不消费区域）。另注：设计第 1.2 节「现有 sg 访问器」表述不准确，corearch 侧没有 sg_* 访问器函数，读写全为 r64/w64 直偏移。
- 推导可行性（后补注）：REG 行是压栈序加 parent 链加 enter/exit 节点坐标（层流嵌套区间；SG_FUNC 根 span = 函数指令范围，save :759-765/load GC-3 双侧校验过）。region_of_nod(n) 是包含 n 的最深行：每次查询 O(函数 REG 行数) 扫描，或 O(nodes) 栈扫预计算。数据无损，可以后补。
- 定夺注记：对象面 API 不包含 region_of_nod，区域面只有 REG 行遍历。理由：零现消费方，预计算表是没有消费者的内核数据（YAGNI），EDG 方法可读承诺不依赖区域。因此 Task 1 不加区域推导访问器；Task 4 文档同步时在 spec 第 1.2 节表注 region_of_nod = 待办已决（不包含，按需后补）。

### 3 登记 API 接入面（Task 2 调用点清单）

- alloc_registers phase 5（regalloc.cr :733-792，逐函数尾）：g_opt_meta 原语直写（store8 头/count/对 @+12，g_opt_meta_count = ei+1 :789；已分配 var = asg_lv/var_asg，全局 var id = vs + lvp、reg = r64(var_asg,…)）。登记调用点是 phase 5 尾每函数：对每个已分配 var，其全部版本条目 e ∈ [entry_start(fi), entry_start(fi)+entry_count(fi))（ent_var(e) == vw）逐一 kern_loc_assign(e, rn)。var 级分配意味着同 var 全条目同 loc，这是与现 meta_reg_for_var 投影语义精确等价的前提，实施时保持全条目登记。
- 注入钩子写点（6+1 的实写点是 3 个 try_*；顶层 inject_* 是纯遍历）：
  - try_inject_home_conflict :40-67：meta_remove_var(v1/v2) :56-57（配对 = 清两 var 全条目登记）加 home=7 直写条目表 :58-59（g_ir_entries 是内核数据面，无需登记；读侧由 ent_home 加域 home_base 合成，与现 ent_home 直读等价）。
  - try_inject_reg_conflict :192-217：meta_set_reg(v1/v2, 3) :208-209（配对 = 登记两 var 全条目到 3）。
  - try_inject_read_gap :235-283：条件 meta_remove_var(:267) 加 meta_set_reg(gv,3)(:275)（配对 = 清共存 var 条目加登记 gv 条目）加 live_end 截断 :277（条目表直写，无需登记）。
  - inject_coexist_oob :22-29：零 meta 写，无配对。
- 配对点取舍：meta 写辅助函数体内嵌（meta_set_reg :107-111 / meta_remove_var :115-154 / meta_append_reg_assign :171-186）覆盖全部注入路径，因此最小配对面是 phase 5 写点加 meta_set_reg 加 meta_remove_var，共 3 处（phase 5 原语直写不经辅助函数，须单独配对）。
- flag 路径时序（判定读登记表时点）：判定唯一读面是 regalloc_verify_all :798-807，调用点有两处。check-regalloc 分支（corearch.cr :199，保序：强制 O2 :190，然后 alloc :191（phase 5 登记完成），然后看门狗 meta_reg_assign_total :194（直读 g_opt_meta，实例面 viewer，不经登记表），然后注入 :196-198（配对保持同步），然后 verify :199 读表）。生产 O2 门（:309 alloc，然后 :312 verify）。其余分支（dump-entries/dump-coexist/inject-coexist-oob）只跑 compute_live_ranges 加条目表 dump，不触发判定，不需要登记表；dump-regassign :167-187 直读 g_opt_meta（实例面）。verify 没有不经 alloc 的路径（生产门 = g_opt_level≥2 加 needs_alloc 声明；check 分支强制 2），因此登记表进程起点空表等价于现状（meta 空加 home 全 -1，0 违反）。

### 4 判定读 meta 面全集（通道切换精确函数面）

- ent_kernel.cr 代码级 g_opt_meta 读点只有函数 meta_reg_for_var :504-525（全文 12 处 g_opt_meta 提及，即 12 行：7 条注释加 5 处代码读。评审修正：原 11+5 计数矛盾）。循环界 g_opt_meta_count :507、块 key :509、data_len :511、对 var :515、对 reg :517。布局：OPT_META_STRIDE = 64（ast.cr:642）、OPT_KEY_REG_ASSIGN = 0（ast.cr:641）@+0 / data_len @+4 / count @+8（跳过）/ 对 var@+12 reg@+16，8B 步进，与 loader opt_meta 段（ccr_io :1117-1140）及 emit 侧同布局。
- 调用点（切换 = meta_reg_for_var 函数体等价改写为登记表查询，3 个调用点不动）：rl_rule2_func :643（寄存器驻留过滤，须保持 var 级语义：var 有任一已登记条目即驻留）、verify_regalloc_consistency 计数遍 :726 加记录构建遍 :742（逐条目投影）。
- LOC_HOME_BASE 代码面：常量 :500 加 rl_print_loc :590（分类打印）加 verify home 编码 :744（home 组投影 = LOC_HOME_BASE + ent_home(e)），属于域参数化替换面（kern_set_loc_domain 接 {home_base, reg_domain}）。注：reg_domain 现在没有分组消费点（规则1 组别 = meta 投影并上 ent_home 投影，天然不相交：reg 0..15 与 home ≥ 10⁶），reg_domain 是声明面参数加防相交护栏。
- emit 面独立实现（已核）：instr.cr get_reg_for_var :34-53 是与 meta_reg_for_var 字节级同构的独立函数（g2_slot :55-73 消费；elf.cr:1309/resolve.cr:36-37 = get_reg_for_var/g2_slot 面）。通道切换不动 emit 面。
- 计划假设被实证反驳（修正注，Task 2 必须同步）：plan Task 2 写「删掉 meta_reg_for_var，确认 emit 面无引用（instr.cr get_reg_for_var 是独立实现，已核）」，这只核了 emit 面。regalloc.cr 注入探针 try_inject_read_gap :254/:261 调用了 meta_reg_for_var（实例侧读内核函数）。删除或改写时须同步这两处：换成实例侧直读 g_opt_meta 的私有扫描，或经登记表等价读。前者更贴近实例面语义。corec concat 无引用（定义随 concat 编译，未用不报错）。

### 5 中立性 guard 设计（Task 4 前置设计）

- ent_kernel.cr 实例相关符号面（代码级全集）：g_opt_meta/g_opt_meta_count 加 OPT_KEY_REG_ASSIGN/OPT_META_STRIDE（全经 meta_reg_for_var 体，Task 2 切换后清零）加 LOC_HOME_BASE（:500，Task 2 移除）。注释层实例提及（guard 剥注释后不拦，记录在案）：x86/机器侧/regalloc.cr（头注 :4-30）、instr.cr g2_slot/get_reg_for_var（:478/:502）、rl_print_loc x86 寄存器枚举注（:593「3=rbx, 12-15=r12-r15」）、alloc_registers() 前置条件注（:704）。
- 结构性守卫（现成）：ent_kernel.cr 双 concat 共享（corec concat 没有 regalloc/instr/elf/hit/corearch.cr），因此指向实例独有文件的符号会导致 corec 编译失败。文本 guard 真正防的是共享声明文件里的实例符号（g_opt_meta/opt 常量在 globals.cr/ast.cr，双 concat 都有，结构守卫拦不住，这正是静态 guard 的必要性）。
- 断言排除集（代码面 token 级）：g_opt_meta、g_opt_meta_count、LOC_HOME_BASE、OPT_KEY_*/OPT_META_STRIDE、E2_REG_SLOT_BASE/E2_*、g_x86_*、寄存器名 token（rbx/r12-r15 等实例枚举名）、ELF 面（ELF/elf_gen 等）。NOD/EDG/ENT/REG 是文件格式语义名，不拦（第 4.3 节例外）。实现注：必须先剥注释（// 与 /* */）再扫 identifier；rl_print_loc 的 x86 注记在注释层，不剥会误报。可选强化：引用标识符与实例独有文件函数定义集的交集为空（结构守卫的文本镜像，成本低）。
- 测试文件：tests/selfhost/ 新文件 test_ent_kernel_neutrality.py（纯源码文本扫描，无 build 依赖，与 selfhost 套件同风格入回归面）。guard 设置点是 Task 2 Step 1（评审 Minor 3 修正，与登记表 API 失败测试同批前置写）。现态 meta_reg_for_var 仍在，失败；Task 2 切换后改为通过。若 Task 4 才首写，首跑即通过，失败状态验证丢失，而且坏剥注释或正则空转无法察觉。
