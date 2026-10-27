# corearch 内核完备化：执行记录与审计

> 对应设计：[2026-09-10-corearch-kernel-completion-design.md](../specs/2026-09-10-corearch-kernel-completion-design.md)

本文保存内核完备化的缺口审计、全量中立化审计、挂账和执行注记。设计正文只保留对象模型、判定中立化、注册契约和检查。

# corearch 内核组件完备化设计（语义对象模型 + 判定中立化 + 注册契约完整）

日期：2026-09-10
状态：已实施（2026-09-10 Task 1-5 完成，plan `2026-09-10-corearch-kernel-completion.md` Tasks 1-5 全实施：对象面 + 调度重建移实例 / A 通道中立化 / B 通道中立化 / 输出面中性化 + 34 声明 + 完成全量回归自举；中立性 guard A+B 全通过 + 行为零变化检查全通过），执行注记见第 7 节
性质：内核完备化裁决文档，补完 `2026-09-09-corearch-rewrite-design.md`（目标架构）第 1.1 节三组件缺口；判定34 形式化声明不实现（用户裁决）；调度重建移实例（用户裁决）。行为零变化。

关联：
- `docs/superpowers/specs/2026-09-09-corearch-rewrite-design.md`（目标架构，第 1.1 节三组件/第 1.2 节实例/第 2 节裁决表/第 3 节演进序）
- `docs/superpowers/specs/2026-09-09-lattice-encoding-boundary-design.md`（边界，C1 输入纯格/C3 核心只含通用机制/G3 实例检查）
- `docs/superpowers/specs/2026-09-09-lattice-ir-v7-carrier-design.md` + `-format.md`（输入实现方式，NOD/EDG/ENT/REG 语义）
- `docs/regalloc-cache-mapping.md`（判定四条，内核引擎族已实现成员）

---

## 0. 背景与缺口审计

目标架构第 1.1 节三组件（范式无关小内核）在步骤 2（内核抽取，2026-09-10 完成）后的完成度：

| 组件 | 目标架构承诺 | 现状 | 缺口 |
|---|---|---|---|
| 1 语义对象模型 | loader/解析 = 内核；对象 = 条目/版本/区域（方法可读） | loader 解析进全局表（ENT 24B 对象化完成；EDG 载入零消费方；NOD 到线性流重建在 loader 内） | 调度重建归属错位（目标架构第 1.2 节：执行者才需要调度 = 实例事务）；无对象访问面 API；EDG（方法边）无消费接口 |
| 2 判定/分配引擎 | 语义判定不读值内容、不知资源名（资源域参数化 = 实例声明传入） | 判定引擎已抽取（ent_kernel.cr），但 verify 规则12 经 `meta_reg_for_var` 直读 g_opt_meta（x86 实例输出布局）；LOC_HOME_BASE=10⁶ + reg# 0..15 编码 seam 在内核 | 资源域未参数化，"内核不知平台"只兑现 95%（两处耦合：meta 读 + 位置编码 seam） |
| 3 注册契约 | {能力声明、资源域/代数参数、请求分派}（双向，判定消费实例输出 + 判定结果回传） | 最小面已立（实例声明表 + 表驱动引导，步骤 2 Task 3）；判定34 无实现 | 资源域代数参数缺失；双向输出面未形式化；34 无形式声明 |

用户裁决（2026-09-10）：
1. 1 边界：调度重建移实例，loader 只产语义对象；线性调度重建 = x86 实例事务（目标架构第 1.2 节 "执行者才需要调度"归属兑现）
2. 判定34：形式化声明不实现，实例能力声明（needs_eviction/needs_call_sites）表示，引擎不实现（静态放置无驱逐事件 + callee-saved 平凡满足，现状论证维持）

---

## 1. 语义对象模型完备化（组件 1）

### 1.1 对象集定稿

内核持有的语义对象 = v7 实现方式内容的进程内形态：

| 对象 | 内存实现方式（现） | 语义 |
|---|---|---|
| 条目 × 版本 | g_ir_entries（24B：var/def/LS/LE/home/flags，dyn_arr.cr:109-115） | 位置 + 方法引用 + 存在区间（闭区间，内核面） |
| 图节点 | NOD 记录（盘 36B 到内存对象视图：op/dest/s1-3/tk + 邻接索引） | 方法种类引用 + 操作数 |
| 图边 | g_v7_edges（8B {to,kind} 邻接，载入缓冲，零消费方） | 方法输入（数据 kind 0 / state kind 1），节点出边 = 方法输入集 |
| 区域 | g_sgs（48B：kind/parent/enter/exit/nstart/ncount） | 嵌套作用域（图绑定） |

方法可读承诺（v7 实现方式设计的兑现）：对象面必须支持“值 = (产生它的图节点, 输入边)”从文件内容直接读出，节点到出边遍历，再到边，再到目标节点。EDG 从"零消费缓冲"升为对象面的正式成员。

### 1.2 对象访问面 API（ent_kernel 扩展，内核接口面）

- 节点面：`nod_op/nod_dest/nod_s1/nod_s2/nod_s3/nod_tk(n)` + `nod_edge_first/count(n)`（读邻接索引）
- 边面：`v7_edge_to(e)/v7_edge_kind(e)`（读 EDG 缓冲）
- 条目面：现有 `ent_*` 族（已 = 内核面）
- 区域面：现有 sg 访问器 + `region_of_nod(n)`（节点到所属区域，dataflow g_df_node_region 的 load 侧重建；v7 文件无此表，REG enter/exit 端点推导：实施盘点项，loader 是否已重建/需要重建节点到区域映射）。已决（2026-09-10 Task 0 盘点定夺：不含），零现消费方（corearch concat 内 g_sgs 唯一消费者 = loader 自身）+ 预计算表 = 无消费者内核数据（YAGNI）+ EDG 方法可读承诺不依赖区域；区域面 = 仅 REG 行遍历，按需后补推导可行（REG enter/exit 层流嵌套区间）
- 方法查询：`nod_inputs(n)` 语义 = 出边集合（邻接索引区间），查询函数薄封装。2026-09-10 Task 1 评审 M-1 注记：实现 = 文档化遍历模式（ent_kernel.cr
 :857-860 方法查询节注释：邻接索引区间 [first, first+count) 内逐边读
 v7_edge_to/kind，访问器齐备后遍历即查询，方法可读检查已实证）；`nod_inputs`
 函数封装未交付 = 计划合规（实施计划禁止新增接口抽象），封装 = 消费方按需
 （YAGNI）。已交付（Task 4，2026-09-10，评审 M1 取代注记）：`nod_inputs`
 于消费者出现时实施（dump_object_surface 收敛调用，ent_kernel.cr:1046，YAGNI 门开启如预期）。
- 线性流 accessor（iri_*）不再是内核对象面，属实例调度产物（第 1.3 节）

### 1.3 调度重建移实例

- loader 收敛：load_ccr 的 NOD到g_ir_instrs 线性重建段移出，loader 产出 = 对象（NOD/EDG/ENT/REG 载入 + 校验守卫）。守卫（段表规范序/逐段越界/拓扑不变量/root span 上界/ENT 双写对照）留内核，守卫不依赖线性流存在（盘点确认：GC-3 上界校验消费 nod_count 而非 instr 流，实施 Task 0 核对）
- 实例侧新函数：`build_linear_schedule()`（x86 实例），从对象（NOD 文件序 + REG 展开）重建 g_ir_instrs（48B 线性流），现 loader 重建段的函数体搬移；corearch 发射前置调用
- 检查：corearch 全链行为零变化（重建产物逐字节同，纯搬移）；corec 写侧不受影响（写侧 g_ir_instrs = lower 产物，不经 loader）
- interp（corec run）直食 DF 节点流，不经 loader，零影响

---

## 2. 判定引擎中立化（组件 2 资源域参数化）

### 2.1 统一位置登记表（判定输入通道）

- 内核持有位置登记表：{entry 序到 loc i32}（判定输入 = 实例分配结果的统一形态，实例经内核 API 写入）
- 内核 API：`kern_loc_assign(entry_idx, loc)` / `kern_loc_clear(entry_idx)` / `kern_loc_of(entry_idx)`（登记表访问，内核面新增）
- verify 规则12 读通道切换：`meta_reg_for_var`（直读 g_opt_meta = 实例私有布局）改为读登记表。`meta_reg_for_var` 函数体 = 表查询改写（同语义，登记表由实例在分配后填充）
- g_opt_meta 保留 = 实例 emit 面私有结构（instr.cr get_reg_for_var 消费，不动）；实例（alloc_registers phase 5 + 注入钩子）写完 g_opt_meta 后调 kern API 登记/清除，实例动作到内核记录的契约方向（双向契约的产物侧）
- 双份数据注记：g_opt_meta（emit 面）+ 登记表（判定面），同一分配结果的两种视图；同步责任 = 实例（写入点成对）。替代方案（判定直接消费 g_opt_meta 经布局描述）= 否决，布局描述 = 隐性耦合，登记表 = 显式契约

### 2.2 位置域声明化（2026-09-10 修正，用户原则：内核不得有寄存器/域分类概念）

- 删除域参数方案：原设计（kern_set_loc_domain + home_base/reg_domain 分类语义“loc < reg_domain = reg 类”）废弃，分类/编码合成 = 实例侧事务，内核不解释位置
- 修正后形态：位置 = 不透明整数，内核只做相等、排序（sweep 检查）、同值互斥；判定1 = 两条独立同值互斥规则：
  1. 登记表 loc 相等（实例分配输出的统一登记，reg 面；若实例选择把 home 也登记，合成发生在其登记动作内，内核只见不透明值）
  2. 条目 home 字段相等（g_ir_entries.home = 语义对象字段，纯语义遍，独立于登记表；现状 home 恒 -1 = 无事件面，规则照旧）
- LOC_HOME_BASE 完全不出现在内核（现常量 :500 + 引用面 :590/:744 = Task 2 移除/改写，home 合成若需保留 = 实例侧（regalloc.cr 现有常量本就在实例文件））
- reg_domain/home_base 实例声明字段（原 第 3.1 节）= 从完备化范围删除（无内核消费点，YAGNI；实例 emit 面如需域描述 = 实例私有数据，本就不在内核）

### 2.3 注入钩子通道

- 实例侧注入钩子（try_inject_*：改分配结果制造判定红），现直写 g_opt_meta，改为写 g_opt_meta（emit 面一致）+ 调 kern 登记（判定面一致），注入 = 双面同步的实例测试通道

---

## 3. 注册契约完整化（组件 3）

### 3.1 实例声明扩展（g_instance_decl 行）

| 字段（现） | 字段（新增） | 语义 |
|---|---|---|
| id/name/opt_min/opt_max/allow_table/allow_link/needs_alloc/needs_verify | — | 能力 + 引导（已有） |
| — | `needs_eviction i32` | 判定3 形式声明（x86 = 0，静态放置无驱逐事件） |
| — | `needs_call_sites i32` | 判定4 形式声明（x86 = 0，callee-saved 平凡满足） |

（home_base/reg_domain 域字段 = 已从完备化范围删除，第 2.2 节修正：内核无域分类概念，实例侧域编码 = 实例私有数据）

### 3.2 判定34 形式化（不实现，用户裁决）

- needs_eviction/needs_call_sites = 实例能力声明字段；引擎不实现两判定（现状论证：3 无事件面/4 平凡真，目标架构注记引用）；契约完整性 = 字段存在 + 文档（未来实例声明 = 1 时引擎扩展 = 注册契约演进点）

### 3.3 双向输出面形式化

- 内核判定结果输出 API：`kern_verify_all()`（现 regalloc_verify_all，violations 计数）命名/位置确认 = 内核面；共存证据查询（entries_coexist 族 = 内核面既有）
- home 生产回填：保持无（分配决策 = 实例事务，目标架构后续注记维持）；双向契约的"判定结果回传实例" = violations/证据查询面（实例自取），非内核写实例结构

---

## 4. 检查与中立性自检

1. 行为零变化：全回归（compile/backend_bootstrap 链/hit_table/region_cfg/mw1-6/slice_bounds/live_ranges/ccr_v7/bootstrap 三套）+ byte-identical 面（backend_bootstrap stage 链 + ccr_v7 产物）全通过
2. 判定通道检查：test_live_ranges 13/13，判定红/绿路径经登记表通道输出与 g_opt_meta 直读时代逐字节同
3. 中立性静态 guard（新，防平台知识回渗内核）：ent_kernel.cr 零实例符号引用断言，g_opt_meta/寄存器名（rbx/r12 等）/ELF/段名（NOD/EDG 除外语义名），测试或脚本守卫，入回归面
4. 对象面检查：EDG 消费接口测试（方法可读，节点出边遍历断言，已知小程序的边集 = v7 Task 0 表一去幽灵后期望的复用）

---

## 4.5 全量中立化审计（2026-09-10，用户原则：内核零经典概念, 全部中立化）

严苛透镜逐函数审计结论（审计报告 = docs/archive/sdd 审计产出，本节约 = 权威注记）：全部 (C) 类集中于一个根因族（两条通道），无清单外新类别：

- 通道 A 线性流坐标派生与读取（4 函数 4 个 iri_\* 使用点）：compute_live_ranges :99 / compute_entries :227/:230/:233 / rl_rule2_func :677-680（F1，判定2 读点扫描） / dump_entries_summary :367（F2）；F3 = verify/rl_rule2_func 段窗口表消费（g_ir_func_instr_* :711-714）+ 签名带实例流窗口参数（ist/ic/vs/vc）；F4 = 双坐标域（live 表函数内 vs 条目全局，挂账：内核自有表内部一致性，非中立性阻塞）；F5 = v7 index 对齐（NOD 节点序 = 指令序）到 中立化 = 同 index 机械替换
- 通道 B 位置通道：meta_reg_for_var（返回 x86 寄存器号语义）+ LOC_HOME_BASE 合成（第 2.1 节/2.2 修正方案）
- 文本层：rl_print_loc/rl_report 措辞 + 头注自证矛盾（:819-823 宣称 iri_\* 非对象面却 4 处直读，中立化后自洽）

写侧实现方式裁决（2026-09-10 用户授权，语义最纯 + 速度最快）：corec 写侧（不经 loader）在 lower 后单遍 `populate_nod_objects()`（g_ir_instrs 到 g_v7_nod_sem 的镜像，与 loader 解析对称），compute 系单实现只读对象面；线性流退役时该点 = 现成写路径。F4 挂账。判定 = ENT 产物 byte-identical（同坐标同值）+ 全回归。

## 5. 与步骤 3 的关系

完备后：内核 = 范式无关三组件完整（对象面 + 判定经登记表/声明域服务任意实例 + 契约含资源域代数与34 形式声明）；x86 实例化（步骤 3）= 纯实例内工作，帧/ABI/调用/tag 参数化 + HIT 表数据化推进，接口 = 登记 API + 实例声明 + 对象面。规则封闭（新范式实例 = 新声明 + 新登记实现，零内核改动）获得实证基座。

## 6. 挂账注记

- 节点到区域映射（region_of_nod）：v7 文件无 g_df_node_region 表，REG enter/exit 端点推导或实例重建期派生，Task 0 盘点定夺 = 不含（零现消费方 + YAGNI；区域面仅 REG 行遍历，按需后补推导可行，见第 1.2 节注）
- 登记表与 g_opt_meta 双份同步责任 = 实例，写入点成对纪律（代码注记 + 注入钩子测试覆盖），实证（2026-09-10 Task 3/5：28/28 判定通道 byte-identical 语料 + test_live_ranges 红路径断言面，见第 7 节）
- 判定34 引擎实现 = 注册契约演进点（needs_* = 1 的实例出现时），不属本设计，位置实证：needs_eviction/needs_call_sites 声明字段已实施（g_instance_decl 行扩展，行数据 {0,0}，见第 7 节）
- F4 挂账（双坐标域：live 表函数内 vs 条目全局，内核自有表内部一致性，非中立性阻塞），随完成留挂（见第 4.5 节/第 7 节，后续专项）
- 中性化注释层残留（中立性原则达注释层，Task 4 review Minor 3），登记清单入 第 7 节（只登记不入代码，措辞阶段范围克制，注释清理 = 未来 doc pass）

## 7. 执行注记（2026-09-10 Task 1-5 完成回填）

> 本节约 = 设计实施确认（plan `2026-09-10-corearch-kernel-completion.md` Tasks 1-5）。
> 提交位置：Task 1 = 035ea289（+ 补正 72c40389）/ Task 2 = 99fc6af3 / Task 3 = b4d8c74f /
> Task 4 = b9685f5c / Task 5（完成）= 本状态行随完成提交落盘。行为零变化检查（第 4 节检查 1-2）
> 与中立性 guard（第 4 节检查 3，tests/selfhost/test_ent_kernel_neutrality.py 入回归面；注：
> src/ci/run.sh 现仅跑四旧套件族，guard 与新内核套件由每阶段显式调用，CI 聚合层恢复时补入）全通过。
> Task 4 终态：方法查询 nod_inputs 已交付（第 1.2 节 M-1 注记取代，见第 1.2 节）。

### 7.1 第 4.5 节审计结论实施确认（A/B 通道清零，红到绿记录核）

- 通道 A（线性流，4 函数 4 使用点）清零（Task 2）：compute_live_ranges/compute_entries/
 rl_rule2_func/dump_entries_summary 的 iri_\* 4 使用点改为 nod_* 对象面同 index 机械替换
 （F5：v7 NOD 节点序 = 指令序 index-aligned），guard A 组红（10 token：iri_op×3/iri_s1×3/
 iri_dest×2/iri_s2×2）转为通过。F3 随附（函数窗口 g_ir_func_instr_\* 值 = NOD 节点坐标语义
 注记 + rl_rule2_func 签名 ist/ic 改为 nst/nc 措辞中性化，值不变）。
- 通道 B（位置通道）清零（Task 3）：meta_reg_for_var 函数体等价改写 = 登记表查询
 （var 级驻留语义保持，调用点 rl_rule2_func + regalloc.cr 注入探针不动）；LOC_HOME_BASE
 常量 + 引用面（rl_print_loc 分类打印/verify home 合成）移除，规则1 = 登记表遍 + home
 字段遍两条独立同值互斥遍（双态条目不可达 = else-if 语义保持），guard B 组红（11 token：
 LOC_HOME_BASE×4/OPT_KEY_REG_ASSIGN×1/OPT_META_STRIDE×1/g_opt_meta×4/g_opt_meta_count×1）
 转为通过。
- 文本层（Task 4）：rl_print_loc 不透明 loc 直印（去 reg/home slot 分类措辞）+ rl_report
 前缀 "regalloc-consistency" 改为检查域语义名 "entry-consistency"（spec 文件名引用保留于
 判定区头注注释层）；头注自证矛盾（宣称 iri_\* 非对象面却直读）随 A 通道中立化消除。
- 终态（Task 5 完成复跑）：guard A+B 全通过零残留（`[PASS] neutrality A ... clean /
 [PASS] neutrality B ... clean` rc=0），无 ent_kernel 代码面残留，无回通道补漏发生。

### 7.2 写侧实现方式裁决实证（populate，Task 2）

- corec 写侧 `populate_nod_objects()`（ccr_io.cr，lower 后、save_ccr 内 compute_live_ranges
 前单遍 g_ir_instrs 48B 到 g_v7_nod_sem 28B 的镜像，字段序/宽度与 loader 解析逐字节对称），
 compute 系单实现只读对象面（corec/corearch 双进程同值）。
- 实证检查：test_ccr_v7 24/24（ENT 产物 byte-identical，Python 独立模型逐行断言 + loader
 负分支 9 测试）+ Task 2 冷编译语料 3/3 整文件 byte-identical（同源三程序 cmp）+ dump 通道
 9/9 byte-identical（3 程序 × 3 通道）。g_v7_nod_sem 进程内留存 = 线性流退役时的现成写路径
 （裁决注兑现）。

### 7.3 登记表双份纪律实证（Task 3/5）

- 登记 API = kern_loc_assign/kern_loc_clear/kern_loc_of（4B/槽，-1 = 未登记）+ 位置 =
 不透明整数零域分类（第 2.2 节修正执行，无 kern_set_loc_domain/无域参数）；登记表代际清理 =
 loc_registry_reset 挂 compute_entries func_i==0 整代重建点（内核数据面自身不变量承担，
 实例配对只负责与 g_opt_meta 同步）。
- 实例写点成对实证 = phase 5 尾逐函数登记 + meta_set_reg/meta_remove_var 辅助
 （reg_assign_var_entries/reg_clear_var_entries，全条目登记/清除）；注入钩子
 try_inject_read_gap 经登记表等价读（判定与探针单出处）。
- 实证检查：判定通道输出逐字节同 28/28 对（4 程序 × 7 通道，含注入红路径 "loc" 违规行，
 Task 3 基线/对照语料 docs/archive/sdd/kc-task-3-base|post）+ test_live_ranges 13/13
 （check_regalloc_violations 规则 1/1/2 红 + read_gap_nonfunc0 + 绿路径全过 + watchdog 93
 pairs）+ test_backend_bootstrap 11/11 O2 stage 链 byte-identical（--check-regalloc 红/绿
 路径经登记通道）。

### 7.4 34 声明位置（Task 4）

- needs_eviction/needs_call_sites 声明字段 = g_instance_decl 行扩展（INST_DECL_STRIDE
 32 到 40 + INST_OFF_NEEDS_EVICTION=32/CALL_SITES=36 + 访问器 inst_needs_eviction/
 inst_needs_call_sites + instance_decl_add 签名扩展，corearch.cr）；行数据 x86/表路径
 = {0, 0}（表路径无驱逐/调用点事件，恒 O0 直线）。引擎不实现（用户裁决，第 3.2 节引用：
 静态放置无驱逐事件 + callee-saved 平凡满足）；契约完整性 = 字段存在 + 判定区头注文档
 （34 TODO 尾追加位置注）；kern_verify_all（现名 regalloc_verify_all）输出面注记 + 第 3.3 节
 双向输出面确认。needs_* = 1 的未来实例出现时 = 注册契约演进点（第 6 节挂账维持）。

### 7.5 F4 挂账 + region_of_nod 已决 + 注释层残留清单（Task 5 完成）

- F4 挂账（维持）：双坐标域（live 表函数内窗口坐标 vs 条目全局坐标），内核自有表内部
 一致性，非中立性阻塞；统一 = 后续专项（不属本计划范围克制）。
- region_of_nod 已决：对象面 API 不含（Task 0 盘点，零消费方 + YAGNI），区域面仅 REG
 行遍历，按需后补推导可行（见第 1.2 节/第 6 节）。
- 注释层残留清单（Task 4 review Minor 3 登记化，中立性原则达注释层）：guard 剥注释
 后不拦（代码面 = 中立性已证），注释层寄存器时代术语 ~10 主簇（终态扫描，行号 = 2026-09-10
 完成日定位点，ent_kernel.cr），只登记不入代码（措辞阶段范围克制；注释清理 = 未来 doc
 pass，本清单 = 工作集）：

  1. 头注 :3-8， 来源句“自 regalloc.cr 逐函数纯搬”+ 中立声明反证句“无寄存器名/ABI
 常量…资源域（寄存器/槽的代数）= 实例侧声明”+ 实例侧行“机器侧（x86 实例）=
 regalloc.cr：CAG alloc_registers + g_opt_meta”
  2. 头注 :11-14， B 通道节“meta_reg_for_var…调用点 = rl_rule2_func + regalloc.cr 注入
 探针”“instr.cr get_reg_for_var 消费”
  3. 头注 :32-35/:39， 实例侧行复述 +“x86 实例 + 表模式路径声明”
  4. 数据面节 :54-57/:100/:106/:153，“alloc_registers 改读本表，与原内联 iv_buf 构建
 逻辑…”“同 alloc_registers 的 iv_buf 初始化语义”“live_range_slot 前缀累计”
 “alloc_registers（O2）两处被调”
  5. 访问器节 :206-209，“不能调 r32：Python bootstrap 的 StackAsmGen 把名为 r32 的调用
 内联成 `mov eax,[rdi+rsi]`”“w32 内联为 `mov [rdi+rsi],edx`”（x86 助记符背景注）
  6. :328-329/:538-539， “自 regalloc.cr 迁入，机器侧零引用”来源注（2 函数位）
  7. 判定区头注 :514-521：“实例侧 g_opt_meta 的 OPT_KEY_REG_ASSIGN 对（var_idx 到
 位置，x86 寄存器号；instr.cr g2_slot/get_reg_for_var 发射时按对落寄存器 = emit
 面）”“元数据表 + 后端 g2_slot 查询”“alloc_registers（CAG 升级后仍）是变量级”
  8. :525-530， 规则1 表述注“同寄存器两 var 的窗口相交”+ 34 TODO 帧“静态放置失败 =
 栈驻留”“spill/调用点解锁”“callee-saved”
  9. :782/:953， 规则2 框架句“寄存器驻留变量的读点必须有活跃版本覆盖”（判定框架措辞
，中立面表述 =“已登记位置驻留变量”，最实质清理候选）
  10. :890/:967/:554-555，“统一登记，现 = 寄存器面”“regalloc_verify_all = x86 时代
 历史名保留”“旧名 g_loc_reg_buf 的 reg 缩写 = 寄存器时代措辞…改全词 registry”
 （自指/历史名记录注）

 分类：类 A = 实例分裂面/历史名/来源注（保留信息必需，doc pass 措辞整饰候选：簇 1-4/
 6-7/10）；类 B = 内核自身描述措辞（清理候选：簇 5 背景注措辞化、簇 8 34 TODO 帧随
 实例化推进消除、簇 9 规则框架句中立措辞改写）。
