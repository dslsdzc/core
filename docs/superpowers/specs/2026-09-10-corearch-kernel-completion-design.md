# corearch 内核组件完备化

## 概述

本设计补完 corearch 的范式无关小内核，包含三个组件：

1. 语义对象模型。
2. 判定和分配引擎。
3. 注册契约。

设计状态：已实施，行为零变化。缺口审计、全量中立化审计、挂账和执行注记见 `docs/superpowers/implementation/2026-09-10-corearch-kernel-completion-audit.md`。

## 背景

内核抽取完成后，三个组件仍有缺口：

| 组件 | 目标 | 缺口 |
|---|---|---|
| 语义对象模型 | loader 解析内核，对象是条目、版本和区域，生成方法可读 | 调度重建仍在 loader 内；没有对象访问 API；EDG 已加载但没有消费接口 |
| 判定和分配引擎 | 语义判定不读值内容，不知道资源名 | 判定规则直读 `g_opt_meta`，位置编码包含平台常量 |
| 注册契约 | 能力声明、资源域参数和请求分派，双向 | 资源域代数参数缺失，双向输出面未形式化 |

两项决定：

1. 调度重建移到实例。loader 只产生语义对象，线性调度重建是 x86 实例的事务。
2. 判定 3 和判定 4 只做形式声明，不在引擎中实现。实例能力声明使用 `needs_eviction` 和 `needs_call_sites`。

## 语义对象模型

内核持有的对象是 v7 实现方式内容的进程内形态：

| 对象 | 内存表示 | 语义 |
|---|---|---|
| 条目和版本 | `g_ir_entries`，24 字节 | 位置、生成方法引用、存在区间 |
| 图节点 | NOD 记录 | 生成方法种类和操作数 |
| 图边 | `g_v7_edges`，8 字节 | 方法输入，数据边 kind 0，state 边 kind 1 |
| 区域 | `g_sgs`，48 字节 | 嵌套作用域 |

生成方法可读：值等于产生它的图节点和输入边。从文件内容可以直接读出节点、遍历出边、到达目标节点。EDG 从零消费缓冲升为对象面的正式成员。

### 对象访问 API

节点面：

```text
nod_op / nod_dest / nod_s1 / nod_s2 / nod_s3 / nod_tk
nod_edge_first / nod_edge_count
```

边面：

```text
v7_edge_to / v7_edge_kind
```

条目面使用现有 `ent_*` 族。

区域面使用现有区域访问器。节点到区域的映射不在 v7 文件中，REG 只有 enter 和 exit 端点。当前没有消费者，暂不重建，需要时按 REG 区间推导。区域面只做 REG 行遍历。

方法查询是出边集合的遍历。邻接索引区间是 `[first, first + count)`，逐边读取 `v7_edge_to` 和 `v7_edge_kind`。消费方出现时再封装 `nod_inputs`。

线性流访问器 `iri_*` 不是内核对象面，属于实例调度产物。

### 调度重建移到实例

loader 只负责加载 NOD、EDG、ENT 和 REG，并做校验。校验包括段表规范序、逐段越界、拓扑不变量、根跨度上界和 ENT 双写对照。校验不依赖线性流。

实例侧新增 `build_linear_schedule()`，从对象重建 `g_ir_instrs` 线性流。原 loader 的重建代码搬到这里，由 `corearch` 在发射前调用。

检查：`corearch` 全链行为零变化，重建产物逐字节相同。`corec` 写侧不受影响。解释器直接使用 DF 节点流，不经过 loader。

## 判定引擎中立化

### 位置登记表

内核持有位置登记表，把条目序号映射到不透明整数位置：

```text
kern_loc_assign(entry_idx, loc)
kern_loc_clear(entry_idx)
kern_loc_of(entry_idx)
```

判定规则 12 不再直接读 `g_opt_meta`，改为读登记表。`g_opt_meta` 保留为实例 emit 面的私有结构，由 `instr.cr` 的 `get_reg_for_var` 消费。

实例在分配完成后同时写 `g_opt_meta` 和登记表。两份数据是同一分配结果的两个视图，同步责任在实例，写入点必须成对。

### 位置是不透明整数

内核不解释位置，只做相等、排序和同值互斥。没有位置域分类，没有 home 基址常量。

判定 1 拆成两条独立的同值互斥规则：

1. 登记表中的位置相等。实例把分配结果登记进来。如果实例选择把 home 也登记，合成发生在实例的登记动作内，内核只看到不透明值。
2. 条目 `home` 字段相等。`home` 是语义对象字段，独立于登记表。当前 `home` 恒为 -1，规则照旧。

`LOC_HOME_BASE` 不出现在内核。home 合成如果需要保留，属于实例侧。

`reg_domain` 和 `home_base` 实例声明字段从完备化范围删除。内核没有域分类概念，实例 emit 面如果需要域描述，使用实例私有数据。

### 注入钩子

实例的注入钩子用于制造判定失败。它现在同时写 `g_opt_meta` 和登记表，保持 emit 面和判定面一致。注入是双面同步的实例测试通道。

## 注册契约

实例声明增加两个字段：

| 字段 | 语义 |
|---|---|
| `needs_eviction` | 判定 3 的形式声明。x86 为 0，静态放置没有移除事件 |
| `needs_call_sites` | 判定 4 的形式声明。x86 为 0，callee-saved 平凡满足 |

这两个字段只做能力声明，引擎不实现判定。未来出现 `needs_* = 1` 的实例时，再扩展引擎，这是注册契约的演进点。

双向输出面：

- 内核判定结果输出使用 `kern_verify_all()`，返回 violations 计数。
- 共存证据查询使用现有 `entries_coexist` 族。
- 分配决策不写回内核。判定结果由实例自取，内核不写实例结构。

## 检查

1. 行为零变化：全回归和逐字节检查全部通过，包括编译、bootstrap、HIT、region CFG、多字、切片边界、活跃区间、CCR v7 和 bootstrap 套件。
2. 判定通道：活跃区间测试 13/13。判定失败和成功路径通过登记表输出的结果，与直接读 `g_opt_meta` 时逐字节相同。
3. 中立性静态检查：`ent_kernel.cr` 不引用实例符号，不出现 `g_opt_meta`、寄存器名、ELF 或段名，语义段名 NOD 和 EDG 除外。检查脚本进入回归面。
4. 对象面：EDG 消费接口测试节点出边遍历，断言已知小程序的边集。

## 与实例化的关系

完备后，内核的三个组件齐全：

- 对象面。
- 判定通过登记表和声明域服务任意实例。
- 契约包含资源域代数和判定 3、4 的形式声明。

x86 实例化是纯实例工作，包括帧、ABI、调用、tag 参数化和 HIT 表数据化。接口是登记 API、实例声明和对象面。

规则封闭：新范式实例只需要新声明和新登记实现，内核零改动。这获得了实证基础。

## 未包含

- 节点到区域映射 `region_of_nod`。当前没有消费者，需要时按 REG 区间推导。
- 判定 3 和判定 4 的引擎实现。等出现需要它们的实例再扩展。
- 双坐标域的内部一致性。属于内核自有表的内部问题，不是中立性阻塞。
- 注释层的中性化清理。已登记，留给后续文档批次。

## 关联

- 执行记录和审计：`docs/superpowers/implementation/2026-09-10-corearch-kernel-completion-audit.md`
- 目标架构：`docs/superpowers/specs/2026-09-09-corearch-rewrite-design.md`
- 格层边界：`docs/superpowers/specs/2026-09-09-lattice-encoding-boundary-design.md`
- IR 语义设计：`docs/superpowers/specs/2026-09-09-lattice-ir-v7-carrier-design.md`
- IR 格式：`docs/superpowers/specs/2026-09-09-lattice-ir-v7-format.md`
- 寄存器分配：`docs/maintainer/design/regalloc-cache-mapping.md`
