# 存在格：物化层的定义

Core 的存储语义本体是存在格（Materialization Space，也叫 Existence Space）。它不绑定字节内存，也不绑定寄存器。缓存、寄存器、RAM 和 VRAM 都是这一层的映射实例。

本文件定义层的四个问题、核心对象、七个字段、归类规则、不变量和边界。修订记录、逐文件扫描和源码核对见 `docs/superpowers/implementation/2026-09-20-materialization-space-audit.md`。

## 四个问题

存在格只回答四个问题：

1. 对某一条 Entry，允许存在哪些物化形态。
2. 两份物化能否同时成立，也就是能否共存。
3. 两份物化是否表示同一个 Entry 和同一个版本。
4. 从一种物化变到另一种物化时，可观测语义是否不变。

层不回答“什么时候驱逐”“放寄存器还是 RAM”“是否预取”这类问题。这些属于 mapper 的策略。

## 核心对象

```text
Semantic Entry  --带一组字段-->  Materialization（物化）
     |                                  |
  语义身份和版本                    物理位置和存在方式
```

核心对象是“语义条目到物化”。一条 Entry 可以有多份物化，例如寄存器一份、栈槽一份、设备侧一份。一条 Entry 也可以暂时没有任何物化，只存在于生成方法层。

## 七个字段

七个字段名来自维护者的原始定义。取值域、写入方和读取方是本文的补充。

| 字段 | 含义 | 取值域 | 写入方 | 读取方 |
|---|---|---|---|---|
| `recipe` | 该 Entry 能否由图内方法重新导出等价状态 | `recomputable`、`unrecomputable` | 编译器前端。判断方法是检查定值节点序列是否终止于边界或不可重算标注 | mapper 的驱逐决策；验证器的驱逐不变量检查 |
| `identity` | 这是哪一条 Entry | Entry 标识，即变量标识和版本序；匿名条目使用产生节点身份 | 编译器，在条目生成期写入 | 共存判定、去重、跨边界身份重指 |
| `version` | 该 Entry 在同一身份版本序列中的位置 | 组内 1-based 序，现行实现的做法 | 编译器，在版本切分时写入 | mapper 的共存判定；调试通道 |
| `authority` | 同一 Entry 和版本有多份物化时，哪一份在语义上算数 | `single(ref)`、`shared-readonly`、`unresolved` | runtime 或 mapper，在外部和分布式情形协商后写入；单体情形由编译器写“单一权威” | 验证器；一致性判定 |
| `location` | 当前在哪里存在 | mapper 的位置域。层不定义位置代数，现行约定是位置域由实例侧声明 | mapper，在分配和放置时写入 | mapper 的 emit；验证器的位置无关性判定 |
| `persistence` | 该物化消失前，状态是否必须转移到合法存储位置 | `free`、`transfer-required`、`externally-owned` | 编译器，由 `recipe` 和边界标注推导；外部资源由设备或 OS 写入 | mapper 的驱逐决策；验证器 |
| `replicability` | 该物化是否允许存在多份 | `free`、`readonly-share`、`forbidden` | 编译器，通过线性或仿射分析写入；外部资源由 runtime 写入 | mapper 的跨边界传递和优化；验证器 |

两条字段约束：

```text
recipe = unrecomputable    =>  persistence 属于 {transfer-required, externally-owned}
replicability = forbidden  =>  authority = single
```

两条约束都可以机械检查，逐条比对字段值即可。违反是编译错误，不能降级为警告，也不能当作有效输入接受。

反向不成立。可重算的物化也可能带 `transfer-required` 的状态。例如一个持锁的临时物化，值可以重算，但锁必须在物化消失前转移。

`evictable` 不是第八个字段。它是派生量：

```text
evictable = (recipe = recomputable) 或 persistence 已满足
```

## 归类

把已知形态放进七元组，可以得到三类结果。

### 放得进的形态

| 形态 | recipe | identity | version | authority | location | persistence | replicability |
|---|---|---|---|---|---|---|---|
| cache | recomputable | Entry | 当前版本 | single，可转移 | mapper 选择 | free | free |
| register | recomputable | Entry | 当前版本 | single | 寄存器号 | free | free |
| RAM | recomputable | Entry | 当前版本 | single | 地址 | free | free |
| VRAM | recomputable | Entry | 当前版本 | single | 设备地址 | free | free |
| spill 或 CPU 到 GPU 的迁移 | recomputable | Entry | 当前版本 | single | 迁移前后 | free | free |
| MMIO 读 | unrecomputable | 每次读产生新 Entry | 每次读新版本 | single，设备侧 | 设备端点 | externally-owned | forbidden |
| 随机数 | unrecomputable | Entry | 不适用 | single | 熵源端点 | transfer-required | free |
| 外部输入 | unrecomputable | Entry | 不适用 | single | 外部 | externally-owned | free |

MMIO 读有一个附加约定：volatile 读每次产生一条新 Entry。否则两次读会被合并成一条，读清零类寄存器会在不报错的情况下出错。

spill 和 CPU 到 GPU 的迁移不是形态，而是物化之间的转换。它们属于第 4 个问题，不属于第 1 个问题。

### 放不进的形态

有四种形态不能完整放进七元组。强行纳入会掩盖它们与缓存系统的差异。

#### 一次性 token

存在格可以表达：`unrecomputable`、`replicability = forbidden`、`persistence = transfer-required`。

放不进的是“必须恰好消费一次”。

- `replicability = forbidden` 只表示不允许有多份，不表示必须被使用。
- `persistence = transfer-required` 只表示消失前要转移状态，不表示不许不消失。

缺少的维度是 Entry 上的使用义务，属于线性或仿射使用规则，不是物化的属性。存在格和使用规则是两条轴。使用义务应当显式记录，不能放进七个字段。

#### 线性资源

线性资源与一次性 token 使用同一条使用义务，因此卡点相同。

额外的差异是线性资源通常由外部持有，`authority` 是 OS 或设备，不是图内。七元组里的 `authority` 可以取一个外部物化引用，所以存在格可以表达。

结论：存在格放得进，使用规则放不进。

#### 事务临时状态

存在格可以表达：`unrecomputable`，因为回滚不等于重算；`persistence = transfer-required`；`replicability = forbidden`。

放不进的是“该物化在事务外不可被观测”。

这不是“哪种物化合法”的问题，而是“谁在什么时候可以读它”的问题。七个字段描述物化自身，这条义务描述物化和观察者的关系。缺少的维度是可见性或隔离域。

版本字段不能替代可见性。版本表达“这是事务内的第几版”，表达不了“这一版不允许被谁看见”。版本是时间轴，可见性是观察者轴。

#### 分布式唯一权威

七元组里的 `authority` 是静态字段，写入后就确定。分布式情形下：

- 权威可能暂时无人担任，例如分区或脑裂，模型需要表达“当前权威未知”。
- 权威是协商和收敛的结果，不是物化的固有属性。
- `replicability` 的合法性可能带条件，例如有 quorum 时允许复制，而取值域 `{free, readonly-share, forbidden}` 是无条件的。

本仓库把授权归治理层。格层只需要能表达“本 Entry 的权威在多份物化之间未定”，这就是 `authority` 有第三个值 `unresolved` 的原因。协商过程不进入格层。

### 归类结果

| 判定 | 数量 | 形态 |
|---|---:|---|
| 放得进 | 8 | cache、register、RAM、VRAM、spill 或迁移、MMIO 读、随机数、外部输入 |
| 放不进，卡在使用义务 | 2 | 一次性 token、线性资源 |
| 放不进，卡在可见性义务 | 1 | 事务临时状态 |
| 放不进，卡在权威协商，归治理层 | 1 | 分布式唯一权威 |

这四类问题分别属于使用义务、可见性和治理，不是“缓存与非缓存”的区别。如果把层定义成缓存，这四类会被当成缓存的特例，问题会被长期掩盖。

## 不变量

物化可以被移除，当且仅当满足下面任一条件：

```text
Evictable(x)  <=>  Recoverable(x) 或 PreserveRequiredState(x)
```

- `Recoverable`：之后能重新得到等价状态。
- `PreserveRequiredState`：消失前已经把必须保留的状态转移到其他合法物化。

这条规则取代旧规则“所有东西都可以驱逐，只要能重算或写回”。旧规则把不可重算条目写成例外，新规则把它并入同一个检查。

新规则覆盖四种旧规则覆盖不到的情形：

| 情形 | 旧规则的问题 | 新规则的处理 |
|---|---|---|
| 不可重算，且没有可写回的 home，例如只存在寄存器或不可导出的硬件密钥 | 旧规则要求有 home 并写回，但该形态没有可写回的位置 | 状态以句柄或指认的形式转移到另一个合法物化 |
| 有生成方法，但重算不合法，例如 volatile MMIO 读 | 旧规则把“方法存在”当成“可以重算” | `Recoverable` 按语义等价判定。方法存在不等于可以重算 |
| 可重算，但移除本身有可观测副作用，例如物化持有锁或占用配额 | 旧规则只从值侧统计可观测变化 | `PreserveRequiredState` 为真，义务显式落在状态转移上 |
| 多份副本表示同一个值，例如只读别名 | 旧规则没有陈述复制合法性 | 使用 `replicability = readonly-share` 和 `authority = shared-readonly` |

新规则新增了一个失败模式：`PreserveRequiredState` 是义务，义务可以仅凭声明成立。因此必须配合失败关闭规则：

```text
无法判定 => 不可移除。
```

如果归属判定返回“未知”，判为不可移除，不判为可移除。否则“义务未满足”和“义务未被检查”在观测上无法区分，会破坏语义而不报错。

### 不可重算条目的移除

```text
recipe = recomputable    => 走 Recoverable 支
                            移除 = 驱逐 + 按需再生，没有额外义务
recipe = unrecomputable  => 只能走 PreserveRequiredState 支
                            移除前材料已保留在 home，或已合法转移身份
                            不能按可重算处理
recipe 无法判定          => 不可移除
```

这条约束来自存储规则 4b 的义务，不是新增规定。映射实例侧如果把存储位置整体当作优化，`unrecomputable` 条目会被当成可丢弃，结果是在不报错的情况下破坏语义。因此移除决策必须先按 `recipe` 分档。

## 层与 mapper 的边界

`LRU`、write-back、write-through、prefetch、GPU 是否保留 residency，全部归 mapper，不属于格层语义。

格层可以陈述由图唯一决定的时序坐标，例如存在区间和版本切分点。这些是图上已经确定的事实。

格层不得陈述带自由参数的时序决策，例如何时移除、预取多远、驻留多久。这些依赖策略输入。

可机械检查的形式：

```text
给定该时序值，能否只由图和 Entry 字段唯一确定？
  能   => 属于格层
  不能 => 属于 mapper
```

现行实现符合这条边界。`home` 是放置决策，恒为 -1，不写回格式；`live_start` 和 `live_end` 是图上已定的事实，写回格式。

## 实现状态

| 字段 | 状态 | 说明 |
|---|---|---|
| `recipe` | 字段预留，语义未实现 | ENT 的 flags bit0 在 schema 中预留为无方法，但两个写侧都硬编码 0，没有生产者，也没有消费者 |
| `identity` | 部分实现 | 使用 `var_id` 和 `version` 作为 Entry 键。“身份等于产生节点”的等价和去重尚未实现 |
| `version` | 部分实现 | 文件格式有 `version` 字段，内存表没有。版本在写入时按同变量定值顺序派生 |
| `authority` | 无实现 | 源码和设计文档都没有对应物 |
| `location` | 部分实现 | `home` 字段存在但恒为 -1，真实分配结果在实例侧旁路表中 |
| `persistence` | 无独立字段 | 义务目前由“必须有 home，移除必写回”这句话承担 |
| `replicability` | 无实现 | 有两套设计：消息标签 `{COPY, MOVE, SHARE}` 和并发原语 `{MOVE, LOAN, SPLIT, FILL, COPY}`，尚未统一 |

`recipe` 的位已经预留，但语义没有实现。边界和执行标注还没有进入 `.ccr`，因此当前没有条目会被标记为无方法。这不是现存缺陷，但生产者实现时必须和移除规则同批完成，否则这类条目一旦进入 IR 就会在不报错的情况下被丢弃。

## 未决问题

| # | 问题 | 影响 | 当前倾向 |
|---|---|---|---|
| 1 | `location` 是否进入格层 | 现行实现故意把 `home` 恒为 -1，放置决策属于 mapper。如果格层要陈述当前位置，会与现行边界冲突 | 不入。格层只承认存在多份物化这一事实 |
| 2 | `replicability` 与两套活跃设计的关系 | `{COPY, MOVE, SHARE}` 和 `{MOVE, LOAN, SPLIT, FILL, COPY}` 未收敛 | 字段不取代标签。字段是格层陈述，标签是跨边界决策，需要对齐表 |
| 3 | `version` 是存储字段还是派生字段 | 现行实现是写入时派生，内存表不存 | 派生。由图坐标唯一决定，属于格层，但不必占存储 |
| 4 | 七个字段的 `.ccr` 表示 | `location` 不能打包，ENT 没有空槽，REG 已满。真正施工要提升 `CCR_VERSION` | 单独立项，先对齐段位和布局 |
| 5 | `recipe` 的生产者和消费者何时实现 | 当前 flags bit0 恒为 0 | 和移除规则同批实现，不与文档修订混批 |
| 6 | “物化”一词与 `so_materialize` 冲突 | `so_materialize` 指模块系统把符号索引写入 SYM 表，含义不同 | 改名或加限定语 |

## 关联

- 存储规则：`docs/academic/cache-semantics.md`
- 存储语义总览：`docs/maintainer/design/memory-model.md`
- 存在结构的 IR 表示：`docs/maintainer/design/existence-structure.md`
- 寄存器映射实例：`docs/maintainer/design/regalloc-cache-mapping.md`
- 层定义决策：`docs/maintainer/adr/adr-0021-existence-space-layer-definition.md`
- 修订记录和源码核对：`docs/superpowers/implementation/2026-09-20-materialization-space-audit.md`
