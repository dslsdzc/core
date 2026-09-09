# corearch 内核组件完备化设计（语义对象模型 + 判定中立化 + 注册契约完整）

日期：2026-09-10
状态：设计定稿（步骤 2.5——内核三组件按蓝图 §1.1 补完；实施计划后置）
性质：**内核完备化裁决文档**——补完 `2026-09-09-corearch-rewrite-design.md`（蓝图）§1.1 三组件缺口；判定③④ 形式化声明不实现（用户裁决）；调度重建移实例（用户裁决）。行为零变化。

关联：
- `docs/superpowers/specs/2026-09-09-corearch-rewrite-design.md`（蓝图——§1.1 三组件/§1.2 实例/§2 裁决表/§3 演进序）
- `docs/superpowers/specs/2026-09-09-lattice-encoding-boundary-design.md`（边界——C1 输入纯格/C3 核心只含通用机制/G3 实例判据）
- `docs/superpowers/specs/2026-09-09-lattice-ir-v7-carrier-design.md` + `-format.md`（输入载体——NOD/EDG/ENT/REG 语义）
- `docs/regalloc-cache-mapping.md`（判定四条——内核引擎族已实现成员）

---

## 0. 背景与缺口审计

蓝图 §1.1 三组件（范式无关小内核）在步骤 2（内核抽取，2026-09-10 收官）后的完成度：

| 组件 | 蓝图承诺 | 现状 | 缺口 |
|---|---|---|---|
| ① 语义对象模型 | loader/解析 = 内核；对象 = 条目/版本/区域（配方可读） | loader 解析进全局表（ENT 24B 对象化 ✓；EDG 载入零消费方；NOD → 线性流重建**在 loader 内**） | 调度重建归属错位（蓝图 §1.2：执行者才需要调度 = 实例事务）；无对象访问面 API；EDG（配方边）无消费接口 |
| ② 判定/分配引擎 | 语义判定不读值内容、不知资源名（资源域参数化 = 实例声明传入） | 判定引擎已抽取（ent_kernel.cr）——但 verify 规则①② 经 `meta_reg_for_var` **直读 g_opt_meta**（x86 实例输出布局）；LOC_HOME_BASE=10⁶ + reg# 0..15 编码 seam 在内核 | 资源域未参数化——"内核不知平台"只兑现 95%（两处耦合：meta 读 + 位置编码 seam） |
| ③ 注册契约 | {能力声明、资源域/代数参数、请求分派}（双向——判定消费实例输出 + 判定结果回传） | 最小面已立（实例声明表 + 表驱动引导——步骤 2 Task 3）；判定③④ 无实现 | 资源域代数参数缺失；双向输出面未形式化；③④ 无形式声明 |

**用户裁决（2026-09-10）**：
1. ① 边界：**调度重建移实例**——loader 只产语义对象；线性调度重建 = x86 实例事务（蓝图 §1.2 "执行者才需要调度"归属兑现）
2. 判定③④：**形式化声明不实现**——实例能力声明（needs_eviction/needs_call_sites）承载，引擎不实现（静态放置无驱逐事件 + callee-saved 平凡满足——现状论证维持）

---

## 1. 语义对象模型完备化（组件 ①）

### 1.1 对象集定稿

内核持有的语义对象 = v7 载体内容的进程内形态：

| 对象 | 内存载体（现） | 语义 |
|---|---|---|
| 条目 × 版本 | g_ir_entries（24B：var/def/LS/LE/home/flags——dyn_arr.cr:109-115） | 位置 + 配方引用 + 存在区间（闭区间，内核面） |
| 图节点 | NOD 记录（盘 36B → 内存对象视图：op/dest/s1-3/tk + 邻接索引） | 配方种类引用 + 操作数 |
| 图边 | g_v7_edges（8B {to,kind} 邻接——载入缓冲，零消费方） | 配方输入（数据 kind 0 / state kind 1）——节点出边 = 配方输入集 |
| 区域 | g_sgs（48B：kind/parent/enter/exit/nstart/ncount） | 嵌套作用域（图锚定） |

**配方可读承诺（v7 载体设计的兑现）**：对象面必须支持「值 = (产生它的图节点, 输入边)」从文件内容直接读出——节点 → 出边遍历 → 边 → 目标节点。EDG 从"零消费缓冲"升为对象面的正式成员。

### 1.2 对象访问面 API（ent_kernel 扩展——内核接口面）

- 节点面：`nod_op/nod_dest/nod_s1/nod_s2/nod_s3/nod_tk(n)` + `nod_edge_first/count(n)`（读邻接索引）
- 边面：`v7_edge_to(e)/v7_edge_kind(e)`（读 EDG 缓冲）
- 条目面：现有 `ent_*` 族（已 = 内核面）
- 区域面：现有 sg 访问器 + `region_of_nod(n)`（节点 → 所属区域——dataflow g_df_node_region 的 load 侧重建；v7 文件无此表——REG enter/exit 端点推导：**实施盘点项**——loader 是否已重建/需要重建节点→区域映射）
- 配方查询：`nod_inputs(n)` 语义 = 出边集合（邻接索引区间）——查询函数薄封装
  →（2026-09-10 Task 1 评审 M-1 注记）实现 = **文档化遍历模式**（ent_kernel.cr
  :857-860 配方查询节注释：邻接索引区间 [first, first+count) 内逐边读
  v7_edge_to/kind——访问器齐备后遍历即查询，配方可读判据已实证）；`nod_inputs`
  函数封装未交付 = 计划合规（实施计划禁止新增接口抽象）——封装 = 消费方按需
  （YAGNI）。
- 线性流 accessor（iri_*）**不再是内核对象面**——属实例调度产物（§1.3）

### 1.3 调度重建移实例

- **loader 收敛**：load_ccr 的 NOD→g_ir_instrs 线性重建段移出——loader 产出 = 对象（NOD/EDG/ENT/REG 载入 + 校验守卫）。守卫（段表规范序/逐段越界/拓扑不变量/root span 上界/ENT 双写对照）留内核——守卫不依赖线性流存在（盘点确认：GC-3 上界校验消费 nod_count 而非 instr 流——实施 Task 0 核对）
- **实例侧新函数**：`build_linear_schedule()`（x86 实例）——从对象（NOD 文件序 + REG 展开）重建 g_ir_instrs（48B 线性流）——现 loader 重建段的函数体搬移；corearch 发射前置调用
- **判据**：corearch 全链行为零变化（重建产物逐字节同——纯搬移）；corec 写侧不受影响（写侧 g_ir_instrs = lower 产物，不经 loader）
- interp（corec run）直食 DF 节点流——不经 loader——零影响

---

## 2. 判定引擎中立化（组件 ② 资源域参数化）

### 2.1 统一位置登记表（判定输入通道）

- 内核持有位置登记表：{entry 序 → loc i32}（判定输入 = 实例分配结果的统一形态——实例经内核 API 写入）
- 内核 API：`kern_loc_assign(entry_idx, loc)` / `kern_loc_clear(entry_idx)` / `kern_loc_of(entry_idx)`（登记表访问——内核面新增）
- **verify 规则①② 读通道切换**：`meta_reg_for_var`（直读 g_opt_meta = 实例私有布局）→ 改读登记表。`meta_reg_for_var` 函数体 = 表查询改写（同语义——登记表由实例在分配后填充）
- **g_opt_meta 保留** = 实例 emit 面私有结构（instr.cr get_reg_for_var 消费——不动）；实例（alloc_registers phase 5 + 注入钩子）写完 g_opt_meta 后调 kern API 登记/清除——实例动作 → 内核记录的契约方向（双向契约的产物侧）
- 双份数据注记：g_opt_meta（emit 面）+ 登记表（判定面）——同一分配结果的两种视图；同步责任 = 实例（写入点成对）。替代方案（判定直接消费 g_opt_meta 经布局描述）= 否决——布局描述 = 隐性耦合，登记表 = 显式契约

### 2.2 位置域声明化

- **LOC_HOME_BASE 出内核**：10⁶ 编码约定 → 实例声明字段（home 段编码起始——x86 实例 = 10⁶）
- 位置分类：判定① 需区分 loc 类别分组扫描（reg 组 vs home 组——现 coexist_home_conflicts 按 HOME 段边界分）——分类依据 = 实例声明的域参数（{home_base i32, reg_count i32}——x86 = {10⁶, 16}）；内核按声明域做 loc 分组，不解释编码内容
- 内核只做：位置相等、排序（sweep 门禁）、按声明分类分组——位置 = 不透明整数 + 实例域声明

### 2.3 注入钩子通道

- 实例侧注入钩子（try_inject_*：改分配结果制造判定红）——现直写 g_opt_meta——改为写 g_opt_meta（emit 面一致）+ 调 kern 登记（判定面一致）——注入 = 双面同步的实例测试通道

---

## 3. 注册契约完整化（组件 ③）

### 3.1 实例声明扩展（g_instance_decl 行）

| 字段（现） | 字段（新增） | 语义 |
|---|---|---|
| id/name/opt_min/opt_max/allow_table/allow_link/needs_alloc/needs_verify | — | 能力 + 引导（已有） |
| — | `home_base i32` | home 段编码起始（位置域——x86 = 1000000） |
| — | `reg_domain i32` | 寄存器域大小（x86 = 16——loc < reg_domain = reg 类, ≥ home_base = home 类；声明驱动分组） |
| — | `needs_eviction i32` | 判定③ 形式声明（x86 = 0——静态放置无驱逐事件） |
| — | `needs_call_sites i32` | 判定④ 形式声明（x86 = 0——callee-saved 平凡满足） |

### 3.2 判定③④ 形式化（不实现——用户裁决）

- needs_eviction/needs_call_sites = 实例能力声明字段；引擎**不实现**两判定（现状论证：③ 无事件面/④ 平凡真——蓝图注记引用）；契约完整性 = 字段存在 + 文档（未来实例声明 = 1 时引擎扩展 = 注册契约演进点）

### 3.3 双向输出面形式化

- 内核判定结果输出 API：`kern_verify_all()`（现 regalloc_verify_all——violations 计数）命名/位置确认 = 内核面；共存证据查询（entries_coexist 族 = 内核面既有）
- home 生产回填：**保持无**（分配决策 = 实例事务——蓝图后续注记维持）；双向契约的"判定结果回传实例" = violations/证据查询面（实例自取），非内核写实例结构

---

## 4. 判据与中立性自检

1. **行为零变化**：全回归（compile/backend_bootstrap 链/hit_table/region_cfg/mw1-6/slice_bounds/live_ranges/ccr_v7/bootstrap 三套）+ byte-identical 面（backend_bootstrap stage 链 + ccr_v7 产物）全绿
2. **判定通道判据**：test_live_ranges 13/13——判定红/绿路径经登记表通道输出与 g_opt_meta 直读时代逐字节同
3. **中立性静态 guard**（新——防平台知识回渗内核）：ent_kernel.cr 零实例符号引用断言——g_opt_meta/寄存器名（rbx/r12 等）/ELF/段名（NOD/EDG 除外语义名）——测试或脚本守卫，入回归面
4. **对象面判据**：EDG 消费接口测试（配方可读——节点出边遍历断言——已知小程序的边集 = v7 Task 0 表一去幽灵后期望的复用）

---

## 5. 与步骤 3 的关系

完备后：内核 = 范式无关三组件完整（对象面 + 判定经登记表/声明域服务任意实例 + 契约含资源域代数与③④ 形式声明）；x86 实例化（步骤 3）= 纯实例内工作——帧/ABI/调用/tag 参数化 + HIT 表数据化推进，接缝 = 登记 API + 实例声明 + 对象面。规则封闭（新范式实例 = 新声明 + 新登记实现，零内核改动）获得实证基座。

## 6. 挂账注记

- 节点→区域映射（region_of_nod）：v7 文件无 g_df_node_region 表——REG enter/exit 端点推导或实例重建期派生——**Task 0 盘点定夺**（对象面 API 是否含 region_of_nod，或区域面仅 REG 行遍历）
- 登记表与 g_opt_meta 双份同步责任 = 实例——写入点成对纪律（代码注记 + 注入钩子测试覆盖）
- 判定③④ 引擎实现 = 注册契约演进点（needs_* = 1 的实例出现时）——不属本设计
