# corearch 重写：执行状态与模块归属记录

> 对应设计：[2026-09-09-corearch-rewrite-design.md](../specs/2026-09-09-corearch-rewrite-design.md)

本文保存 corearch 重写的执行状态注记、模块归属细节、演进记录和挂账。设计正文只保留目标架构、内核边界、实例边界和演进顺序。

# corearch 重写设计：范式无关内核与实例定制

日期：2026-09-09
状态：设计定稿（目标架构：模块归属裁决加演进序）。演进序步骤 2（内核抽取）已实施完成（2026-09-10，plan `2026-09-10-corearch-kernel-extraction.md` Tasks 1-4）；步骤 2.5（内核组件完备化，中立化阶段，plan `2026-09-10-corearch-kernel-completion.md` Tasks 1-5）已实施完成（2026-09-10）。执行状态注记见第 1.1/2/3 节（步骤 2.5 执行注记 = 设计 spec `2026-09-10-corearch-kernel-completion-design.md` 第 7 节）
性质：裁决性 spec，按 `2026-09-09-lattice-encoding-boundary-design.md`（边界 C1-C3 契约）执行的目标架构方案；方案本身不含代码改动。

关联：
- `docs/superpowers/specs/2026-09-09-lattice-encoding-boundary-design.md`（格层边界，第 3 节转换器契约 C1-C3 = 本设计的裁决依据；C4 = 检查裁决）
- `docs/superpowers/specs/2026-09-09-lattice-ir-v7-carrier-design.md` 加 `2026-09-09-lattice-ir-v7-format.md`（输入侧 = v7 图实现方式）
- `docs/superpowers/plans/2026-09-09-lattice-ir-v7.md`（v7 实施计划，演进序第 1 步）
- `docs/regalloc-cache-mapping.md`（判定四条 = 内核判定引擎族的已实现成员）
- `docs/memory-model.md` 第一节（缓存语义七条加无方法统一规则，内核的语义基座）

---

## 0. 定位与检查

### 0.1 起因与定性

边界 spec 裁决：corearch 的问题是与经典计算机绑定太深（问题出在转换编码层；.ccr 大体成立，局部不纯）。转换器契约（C1-C3）：输入 = 纯格，输出 = 实例形态，核心只含通用机制。用户拍板（2026-09-09）：一个范式无关的小核心，其他架构针对各自范式和机器定制。本设计是该决定的目标架构方案。

### 0.2 本设计回答的问题

1. “小核心”的实际内容是什么（第 1.1 节）
2. 实例层的定制边界是什么、x86 实例由什么组成（第 1.2 节）
3. 现 corearch 每个模块归核心还是实例（第 2 节裁决表）
4. 以什么顺序演进到目标形态（第 3 节）

### 0.3 检查

- 输入 = v7 图实现方式（.ccr 格语义文件，包含边/条目/区域；op 字典 = 显式遗留的方法种类引用）
- 重写检查 = 行为等价加语义正确性方向（边界 C4 已裁：逐字节复刻检查废止，实例算法可自由设计，正确性检查 = 投影/映射正确性方向，缓存语义规则 7）
- 设计约束：内核判定不读值内容（条目泛型）；规则封闭（永不新建）；无格承诺（具体代数 = 映射参数）；最弱理论（共存 = 对称关系）
- 内核不需要理解 op 字典语义。判定作用于条目类别（位置 + 方法 + 存在），方法内容（字典含义）由消费侧解释

---

## 1. 目标架构

```
v7 图实现方式(.ccr) -> 范式无关小内核 -> 实例(每范式/机定制)
 | 1语义对象模型 | x86 实例: 调度重建 + lower/发射
 | 2判定/分配引擎族 | + 帧/ABI/tag 算法 + 实例数据
 | 3实例注册契约 | 范式 B 实例: (未来)
 --------------------
 判定结果(home/共存/驱逐) 回传实例
```

### 1.1 范式无关小内核（三组件）

1 语义对象模型（输入契约 C1 的执行者）
- v7 图实现方式得到条目 × 版本 × 区域语义对象流（loader/解析 = 内核职责，包括格式校验、拓扑不变量、ENT 校验，属于内核输入契约守卫）
- 对象 = 条目（位置 + 方法 + 存在）、版本区间、区域嵌套、无方法/持久条目（统一规则，规则 4b）
- op 字典：NOD 的 op = 方法种类引用。内核持有引用但不解释语义（最弱理论：判定不需要知道值怎么算出来的，只需要知道它存在、由谁产生、何时失效）
- 归一化角色：v7 实现方式的“槽语义投影”解释（v7 设计第 2.3 节双通道的槽语义通道）不在内核，那是执行型实例的翻译事务

2 判定/分配引擎族（语义侧通用，regalloc-cache-mapping 判定四条的推广）
- 共存关系推导（sweep，条目泛型，v6 第 4.2 节算法 = 内核成员）
- 资源互斥约束（判定四条：共存互斥/读点无陈旧/驱逐配对/调用失效，属于与资源域无关的语义判定）
- 驱逐候选/写回规则（持久条目 home 保真，规则 4b 的判定形态）
- 资源域参数化：引擎判定互斥，但不知道资源是寄存器、槽还是量子位。资源域由实例声明（无格承诺：实例的资源代数作为映射参数传入引擎）
- 先例确认：regalloc-cache-mapping 判定四条是本引擎族第一个已实现成员。内核抽取 = 从 regalloc.cr 拆出语义侧（第 2 节裁决）

3 实例注册契约
- 实例 = {能力声明（接受什么语义对象流、产出什么）、资源域/代数参数、请求分派形态（实例消费判定服务的方式）}
- 注册/校验/选择机制：corearch 引导时选实例
- 注册契约是内核与实例的唯一耦合面。新范式实例 = 新注册，不改内核（规则封闭对象开放）

核心不包含：任何机器编码知识（寄存器名/帧/ABI/ELF）、任何调度/执行序知识（执行者才需要调度，验证器消费不需要）、op 字典语义解释、HIT 表概念（表 = 实例数据形态，不是内核概念，边界 spec C4 已定位表为实例数据实现方式）。

三组件完成态（2026-09-10 步骤 2.5 完成注记：plan `2026-09-10-corearch-kernel-completion.md` Tasks 1-5，执行注记详见设计 spec 第 7 节）：内核 = 范式无关三组件完整。1 语义对象模型（对象面 API nod_*/v7_edge_*/方法查询 nod_inputs 完整，调度重建移实例 = 实例侧 build_linear_schedule，loader 收敛为纯对象载入加校验守卫；region_of_nod 定夺为不包含，区域面只用 REG 行遍历）。2 判定/分配引擎（位置登记表 kern_loc_* 通道加 home 字段独立遍，中立性 guard A+B 全通过 = 内核零线性流引用、零实例布局读、零位置编码、零域分类，`tests/selfhost/test_ent_kernel_neutrality.py` 进入回归面）。3 实例注册契约（实例声明行扩 needs_eviction/needs_call_sites 34 形式声明 {0,0}，引擎不实现 = 演进点，加 kern_verify_all 双向输出面确认）。检查：行为零变化（全量回归加 backend_bootstrap stage 链/ccr_v7 产物/28/28 判定通道 byte-identical）加自举重建加 full-bootstrap guard（corec2/corec3 cmp 同加 N06=0）。x86 实例化（演进序步骤 3）= 纯实例内工作，接口 = 登记 API 加实例声明加对象面。

### 1.2 实例层（每范式/机定制）

实例是该范式或机器把语义对象变成自己编码的全部定制内容，没有跨范式共性，不强行建立通用翻译层：

x86 实例组成（从现 corearch 模块归位，第 2 节）：
1. 调度重建（v7 设计第 3 节投影契约）：图实现方式到线性调度（文件序合法化加 REG 展开）。只有执行型实例需要；合法性校验（沿边约束）在实例内，内核不做调度承诺。
2. lower/发射翻译：语义对象/调度到 x86 编码（现 instr.cr 发射加 lower_to_core 的翻译逻辑下放。其泄漏面（帧/ABI/调用）在实例内不再叫泄漏，因为实例是经典绑定的合法域）。
3. 实例算法族：帧布局（prologue/epilogue/帧公式）、调用序列（参数拷贝/返回协议）、tag/2L 编码选择、寄存器物理分配（CAG）。按边界 C2/C3：映射参数实例（推广 regalloc-cache-mapping 先例，同族必同类）。
4. 实例数据：HIT 表/模板/投影条目（M1/M2 资产 = 实例数据机制；字节层数据化 = x86 实例的内部优化，检查 = 行为等价/投影正确性，C4 裁决）。
5. 运行时/ELF/链接/syscall 输出面（编码层合法内容）。

x86 实例与内核的接口：实例向内核注册（资源域 = 寄存器/槽的代数），内核判定（共存/互斥/驱逐写回），判定结果（home 分配等）回传实例，实例完成物理编码。语义对象流 = 内核输出、实例输入。

---

## 2. 现 corearch 模块归属裁决表

| 模块（现） | 现状职责 | 裁决 |
|---|---|---|
| ccr_io.cr loader 侧（load_ccr/段表/校验/ENT parse） | 文件到内存指令流 + ENT 校验 | 内核（语义对象模型，v7 后对象 = 边/条目/区域） |
| ccr_io.cr ENT/区间校验 + REG root span 守卫 | 输入契约守卫 | 内核 |
| regalloc.cr compute_live_ranges/compute_entries | 存在区间/版本推导 | 内核（判定引擎，v6 第 4.1 节规则 = 语义侧） |
| regalloc.cr entries_coexist/判定四条 | 共存/互斥/驱逐/失效 | 内核（引擎族核心，参数化资源域后实例复用） |
| regalloc.cr CAG alloc_registers/物理分配 | 寄存器物理分配 | x86 实例（实例算法，寄存器 = x86 资源域） |
| regalloc.cr verify/注入钩子 | 判定自检/测试通道 | 判定部分 = 内核、分配部分 = 实例（随拆分） |
| dataflow 概念（corearch 侧无图，重建线性） | 无 | 实例调度重建（v7 第 3 节，输入图实现方式的重建方 = x86 实例） |
| instr.cr emit_instr 发射 | 线性指令到 x86 字节 | x86 实例（lower/翻译，泄漏面在实例内合法化） |
| instr.cr 帧/ABI/调用/ret_patch 序列（R1-R12 面） | 实例算法硬编码 | x86 实例，按 C2/C3 参数化为实例算法（数据 + 序列函数） |
| elf.cr/ld.cr/resolve.cr | ELF/链接/回填 | x86 实例（编码层输出面） |
| HIT hit.cr/表/模板解释器/注入通道/lower_to_core | 表驱动编码 | x86 实例（实例数据机制，表 = x86 实例的编码数据实现方式） |
| corearch.cr 编排/flag 分派 | 引导/测试通道 | 内核引导 + 实例注册（flag = 实例选择参数） |
| MW tag 语义与编码 | 耦合在帧/op 面 | 语义（int 无上限/2L 值域） = 格/图层（文件）；编码 = x86 实例算法 |
| v7 EDG/ENT 消费 | （v7 后新增） | 语义对象 = 内核；EDG 的调度消费 = x86 实例 |

拆分原则：语义侧（存在/区间/共存/驱逐/写回/互斥，不读值内容、不知道资源名）归内核；机器侧（物理资源/编码/布局/协议）归实例。含糊处按 G3-2 先例类推（对缓存语义的机器侧资源决策 = 实例算法；对条目的语义判定 = 内核）。

执行状态注记（2026-09-10，演进序步骤 2 = plan `2026-09-10-corearch-kernel-extraction.md` Tasks 1-4 全部实施，行为零变化检查通过）：
- regalloc.cr 拆分（本表首四行裁决执行化）：语义侧（compute_live_ranges/compute_entries/共存族/verify 判定面/诊断通道/dump）逐函数纯搬入 `src/arch/linux/ld/ent_kernel.cr`（内核，双 concat 共享，同时进 corec 与 corearch 二进制）；CAG alloc_registers 加 g_opt_meta 写入（meta_set/append/remove/meta_reg_assign_total）加注入钩子留在 `regalloc.cr`，属于 x86 实例机器侧。LOC_HOME_BASE 裁决修正为单份随判定进入内核（双份不可构建已有实证：concat 单编译单元自举 NameResolver 拒绝重复顶层声明，且机器侧零引用）。
- ccr_io 写侧单源化：`compute_entries_v7` 镜像加 `ccr_grow_*` 副本删除，corec 写侧直调内核 `compute_live_ranges`（尾部逐 func 调 compute_entries），loader/写侧均单源 = 双转录 R5 收敛（产物 byte-identical 检查 23/23）；半开盘布局转换（写 +1/读 −1）保留在 ccr_io 写点（内核算闭区间）。
- corearch.cr 引导收敛为实例声明表加表驱动 dispatch（本表“corearch.cr 编排/flag 分派”行裁决的最小面实施）：`g_instance_decl` 两行（INST_X86 [0,3] allow_link=1 needs_alloc/needs_verify=1；INST_TABLE [0,0] 恒 O0 职责窗口 allow_table=1），经 instance_select() 选择，决策逐点查询活动实例行。`--check-regalloc` 顺序保序（强制 O2，alloc，看门狗，注入，verify_all）；三路分派（--table×opt 门/--opt-level/O2 verify）收敛后行为不变（评审独立 48/48 通道 base 与 head 逐字节同）。
- 注册契约需要双向（勘探发现，本设计第 1.1 节3 表述为单向“实例向内核注册”不完整）：实证数据流为实例（分配器）写入 g_opt_meta（meta_set/append/remove/meta_reg_assign_total），内核判定（verify 规则12）经 `meta_reg_for_var`（纯读通道）消费实例输出。该读通道随判定进入内核（Task 1 裁决）。注册契约的请求/消费面天然双向：实例产出，内核读通道消费；后续“资源域参数化/双向契约（home 回填）”步骤在此基础上扩展。判定到机器侧的唯一读通道 = meta_reg_for_var（分配输出输入通道）。
- grow/accessor 收敛成果：ccr_io 局部 lr 表机制/ccr_grow_entries/ccr_grow_func_entry_meta 删除后，grow 单实例化。loader 与写侧同调内核 ent_kernel 的 grow（共享 globals.cr 声明加内核文件进双 concat = 单源化路径已有实证）；ccr_ent_* 访问器按真实引用保留。
- 挂账注记：1 rl_print_loc 内的 x86 注释随搬入内核（ent_kernel.cr:593“x86 寄存器枚举号（3=rbx, 12-15=r12-r15）”，属于注释层遗留，范式无关声明以代码为准，清理留待后续步骤）；2 按实例钳制时记起 corearch.cr:255-256 钳制点（现钳制直写 x86 实例行窗口，不查活动实例行，Task 3 评审 Minor M1）与 :244 拒绝消息带 `--table` 措辞（未来非表实例 allow_link=0 的误伤面，今日不可达，M4，消息措辞参数化时处理）；3 实例侧描述有两份头注（ent_kernel.cr/regalloc.cr，存在演进变化风险，当前互引一致，M5）；4 ent_kernel.cr 头注函数名变化已顺手修正（reg_assign_total 改为 meta_reg_assign_total，Task 3 评审 Minor M3）。

---

## 3. 演进序（方案裁决，实施另立）

1. v7 实施（计划 d76d14c3 已就绪）：图实现方式落盘加 loader 双端改，是内核输入契约的前提。先行理由：内核对象模型的数据源 = v7 文件；ENT/EDG 不落盘则内核没有对象可管
2. 内核抽取：loader 到语义对象模型，判定引擎从 regalloc 拆出（compute_entries/live_ranges/共存/判定四条入内核；CAG 留实例）。行为检查：抽取中每步回归通过（判定语义不动，只迁移代码，与 regalloc 移后端先例同款流程）；内核接口 = 注册契约最小面先立。已完成（2026-09-10，plan `2026-09-10-corearch-kernel-extraction.md` Tasks 1-4；执行状态注记见第 2 节）：判定语义引擎族（compute_entries/live_ranges/共存/verify 规则12/诊断通道）纯搬 `ent_kernel.cr` 进双 concat 加写侧镜像消除加注册契约最小面（实例声明表加表驱动引导）实施；检查：test_live_ranges 13/13 加 test_ccr_v7 23/23（byte-identical）加全量回归通过（compile/backend_bootstrap 链/hit_table 24/24/region_cfg 22/22/mw1-6/slice_bounds 7/7/bootstrap 三套）加 full-bootstrap guard（corec2 N06=0、corec2/corec3 cmp=0、快速验证通过）加自举重建快速验证。范围克制保持：资源域参数化/双向契约 home 回填/loader 语义对象化（loader = 段表读取面，对象模型改造 = 后续步骤）未做，最小面已立
2.5. 内核组件完备化（步骤 2.5，中立化阶段）：三组件按第 1.1 节补完加全量中立化（用户原则 2026-09-10：内核零经典概念）。对象模型补完（对象面 API 加调度重建移实例）、A 通道中立化（compute 系改 NOD 对象面加写侧 populate）、B 通道中立化（登记表加 LOC_HOME_BASE 移除）、注册契约完整（34 形式声明）。已完成（2026-09-10，plan `2026-09-10-corearch-kernel-completion.md` Tasks 1-5，提交 035ea289+72c40389 / 99fc6af3 / b4d8c74f / b9685f5c / 完成提交；执行注记 = 设计 spec 第 7 节）：内核 = 范式无关三组件完整（完成态声明见第 1.1 节）；检查：中立性 guard A+B 全通过（从失败到通过的记录：A 组 10 token 红，Task 2 转绿；B 组 11 token 红，Task 3 转绿；Task 5 终态复跑零残留）加行为零变化（全量回归通过：compile/backend_bootstrap 11/11 链 byte-identical/hit_table 24/24/region_cfg 22/22/mw1-6/slice_bounds 7/7/live_ranges 13/13/ccr_v7 24/24/bootstrap 三套 29+4+3 加判定通道 28/28 逐字节同加冷编译语料 3/3）加自举重建快速验证加 full-bootstrap guard（corec2/corec3 N06=0、cmp 同、快速验证 rc 42）。范围克制保持：F4 双坐标域统一 = 挂账（后续专项）；判定34 引擎实现 = 注册契约演进点（needs_* = 1 实例出现时）
3. x86 实例化（= M2 复启的接续形态）：实例边界内的数据化/参数化（帧/ABI/调用序列/tag 编码改为实例算法加 HIT 表数据化推进）。检查按边界 C4 重定（行为等价/投影正确性，不是逐字节复刻）；M2 挂起实现的承接点。接口就绪（步骤 2.5 产物）= 登记 API（kern_loc_*）加实例声明（needs_* 行）加对象面（nod_*/v7_edge_*/nod_inputs），步骤 3 = 纯实例内工作
4. 第二范式/非经典实例验证（远期）：注册契约的实证。范式 B 实例 = 新注册加新算法数据，零内核改动（规则封闭的验收）

时机注记：步骤 1（v7）与步骤 2-3（重写）可分可合。v7 的 loader 改动若按内核对象模型的形状做（loader 产出语义对象而不是线性流假设），可避免二次重构（实施计划的接口优化项）。

---

## 4. 风险与挂账

- 内核抽取的最大风险是 regalloc 拆分的行为零变化：判定四条语义不动，只迁移代码。检查 = 每步回归通过（O2 分配加 verify 通道先例）；拆分时禁止顺手改语义
- 调度重建归属：内核不做调度承诺（语义消费不需要）。若未来验证器消费发现需要调度无关的图接口，作为语义对象模型的扩展（对象 API 先立最小面）
- HIT 表定位：表 = x86 实例数据形态。方案不承诺其他范式实例使用表（“换表即换平台”的表述校准为“换实例即换平台”；表 = x86 实例的数据化方式）
- op 字典：内核不解释。验证器（语义消费通道）需要字典语义时，属于字典语义文档化/形式化的独立工作（语义层大改，v7 设计第 2.2 节显式遗留的后续）
- M2 既有实现（Task 0/1/2 完成品）：实例数据机制的既有实现，实例化推进（步骤 3）时按 C4 检查承接，不废弃
- 本设计不包含：任务分解（实施另立）、x86 实例内部的具体数据/算法设计（实例化推进时按 C2/C3 输出）

---

## 5. 关联同步项

- 边界 spec：本设计 = C1-C3 的实质化。C6 总表中“corearch 模块”行按第 2 节裁决表更新（实施时）
- v7 设计/格式/计划：输入侧（步骤 1 先行）；v7 实施计划 Task 1/2 的 loader 改动接口 = 第 3 节时机注记
- regalloc-cache-mapping：判定四条 = 内核引擎族成员，文档定位随内核抽取更新（实施时）
- M2 计划/spec：复启 = 步骤 3 的接续形态，检查按 C4 修订后承接（复启时执行）
- TODO.md：corearch 重写方向挂账（本 spec 落盘后）
