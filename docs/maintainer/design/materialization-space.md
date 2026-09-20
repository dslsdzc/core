# 存在格 / Materialization Space:层定义(七字段 / 归类 / 不变量)

> 定位:受众 = 维护者/贡献者;**状态 = active(已合入)**。
> 决策记录 = `docs/maintainer/adr/adr-0021-existence-space-layer-definition.md`(2026-09-20,维护者裁定);
> 设计意图真源 = 维护者原话逐字稿(`/tmp/briefs/materialization-space-raw.md`;本文件是它的工程化展开)。
> **本文件 = 格层本体的层定义**——格层回答的四问、`Semantic Entry → Materialization` 对象模型、
> 七字段、归类表、不变量改写、划界。**条款 1–7 的内容仍以 `docs/academic/cache-semantics.md` 为权威**
> (本次修订只改它们的外层框定,不改条款内容);本节不复制条款正文,避免第二权威。
> 同批就地改动的文档清单见 §六.0。

**三态标注约定(全文生效,默认 = `[提案]`)**:

| 标注 | 含义 | 必备 |
|---|---|---|
| `[已实现]` | 仓库**现在**已有该行为/字段 | **必须给 file:line** |
| `[已设计未实现]` | 有设计稿,无实现 | 必须给设计出处 |
| `[提案]` | 本文档主张的,仓库现在**没有** | 默认态——**未标注的断言一律按 `[提案]` 读** |

> 本文档**凡涉「仓库现在有什么」逐句标注**;§六 修订账的每行本身即现状陈述
> (「现行措辞」列 = 逐字引用,file:line 已给),按 `[已实现]` 读。
> **默认 `[提案]`**:任何未带 `[已实现]`/`[已设计未实现]` 的断言,读者应默认它是提案而非现状。
> 层定义(§一–§五)本身 = **已随 ADR-0021 合入的层本体**;但 §七 标出的实现距离**依然成立**——
> **层定义已生效 ≠ 字段已实现**。

---

## 零、权威归属(阅读本文档前必读)

本仓曾有「同一层两份文档都自称权威」的事故面。这次修订把归属**一次划清**,后续不得再含糊:

| 内容 | 权威文档 |
|---|---|
| **层本体定义**(四问/对象模型/七字段/归类表/划界/不变量) | **本文件** |
| **条款 1–7 正文**(值=配方 · 驱逐不变量 · 再生等价 · 边界公理 · 4b · 版本化 · 地址=映射 · 映射实例正确性) | `docs/academic/cache-semantics.md` |
| 条款在 IR 中的承载(ENT/NOD/REG) | `docs/maintainer/design/existence-structure.md` |
| 三层关系与阅读路径(导航) | `docs/maintainer/design/memory-model.md` |
| 具体映射实例 | `region-model.md`(经典)· `regalloc-cache-mapping.md`(寄存器行) |

**职责边界**:本文件**不复制条款正文**;cache-semantics.md **不重新定义层**。
两者在本修订后互相指向,不重叠——**这是本次修订不产生第二权威的机制保证**。

---

## 一、修订内容:把「格 = 缓存」降级为特例

### 1.1 修订前措辞(留档:已被本次修订改掉)

修订前,教义把**缓存语义**当作格层的**本体定义**,不是当作一类实例。定义性表述:

| 位置 | 现行措辞(逐字摘句) |
|---|---|
| `docs/academic/cache-semantics.md:4` | `本文件是 Core 存储语义本体的**唯一权威**——七条条款为定义性条款` |
| `docs/academic/cache-semantics.md:12` | `Core 的存储语义本体是**缓存**——范式无关的存储抽象,不是字节内存,也不是寄存器` |
| `docs/project-book.md:216` | `存储语义本体为**缓存语义**(值 = 配方、条目可驱逐可再生、图边界为唯一不可再生来源)` |
| `docs/maintainer/design/memory-model.md:22` | `条款 1-7:缓存语义`(三层图第二层「语义本体」格的唯一内容) |
| `docs/z-vision.md:15` | `存储半边已定稿(语义本体 = 缓存语义,字节内存 = 经典映射实例…)` |

### 1.2 问题:「缓存」一词偷带的六个假设

维护者原话列出的六条隐含假设,逐条对应到现行条款:

| # | 缓存偷带的假设 | 在现行教义里的落点 |
|---|---|---|
| 1 | 有一个原始/权威值 | 条款 1「值 = 配方」隐含「配方产出唯一值」 |
| 2 | 可以复制 | 无条款——**这正是缺口**(现行七条从未讨论复制的合法性) |
| 3 | 可以驱逐 | 条款 2「驱逐不变量」(`cache-semantics.md:25`) |
| 4 | 可以重新物化 | 条款 3「再生等价」(`:26`) |
| 5 | 通常存在 backing store | 条款 4b「必须有 home(持久位置)」(`:28`) |
| 6 | 不同副本原则上表示同一个值 | 无条款——**第二个缺口**(副本同一性从未被陈述) |

假设 3/4 已被条款显式承担;假设 1/5 已被条款隐式承担;
**假设 2 与 6 从未被陈述,却一直在被默认使用**——现行实现里 `.ccr` 的 `home` 字段
(§7.2)与消息传递的 COPY 标签(§7.2 replicability 行)都建立在它们之上,但没有条款为它们负责。

### 1.3 请求的新关系(与原文一致)

```
格层 = Materialization / Existence Space(存在格)
                │
                ├── Cache mapping         ← 现行七条覆盖的那一类
                ├── Register mapping
                ├── Memory mapping
                ├── Persistent mapping
                ├── Linear-resource mapping
                └── Future mapping
```

即:**缓存不再作为整个层的总名字,而是其中一类存在策略**。
原文的措辞是「缓存是一个非常重要的特例」——`cache = {recipe=yes, replicable=yes, evictable=yes, authority 可转移/可重建}`。

**这项修订的代价面(必须明说)**:条款 1–7 中,1/3/4/4b/5/6/7 在新定义下**原样成立**——
它们描述的是「配方 ↔ 存在」的关系,与「缓存」这个名字无关,降级只影响**称谓**;
真正受影响的是条款 2(驱逐不变量):它的**现行措辞**("只要配方还在就能丢")在新定义下
是**充分而非必要**条件(§四)。所以本修订**不是推翻既有设计**——寄存器分配/区域/arena/
residency 的既有结论全部保留(与原文「之前已经做出的设计基本都不用推翻」一致)。

---

## 二、新定义:Materialization / Existence Space

### 2.1 格层回答的四问(原文逐条)

格层只回答这四个问题,**不回答别的**:

1. **哪些 materialization 合法** —— 对某一条 Entry,允许存在什么形态的存在物?
2. **哪些可以共存** —— 两份 materialization 能否同时成立?
3. **哪些代表同一 Entry/version** —— 两份 materialization 是否指同一语义对象?
4. **哪些转换保持语义** —— 从一种 materialization 变到另一种,可观测语义是否不变?

> [已实现] 第 2 问在实现里已落地:`entries_coexist(func_i, e1, e2)`
> (`src/lattice/ent_kernel.cr:429`)——区间相交判定 `ls1 ≤ le2 && ls2 ≤ le1`(闭区间),
> 消费点 = 共存互斥判定 `coexist_home_conflicts`(`src/lattice/ent_kernel.cr:476`)。
> [已实现] 第 3 问部分落地:`coexist_version_conflicts`(`src/lattice/ent_kernel.cr:445`)用「同 var 相邻版本必不交」作为版本化正确性自检。
> [提案] 第 1、4 问无实现对应物(§7.0)。

### 2.2 核心对象

```
Semantic Entry  ──带一组字段──▶  Materialization(存在物)
      │                                  │
   语义身份/版本                      物理位置/存在方式
   (identity/version)                 (location/persistence)
```

**核心对象从 `CacheEntry` 换成 `Semantic Entry → Materialization`**。
一条 Entry 可以有**多份** materialization(寄存器一份、栈槽一份、设备侧一份),
也可以**暂无**任何 materialization(只存在于配方层)。

> ⚠ 术语冲突警告 [已实现]:本仓 `物化` 一词已被占用,语义不同——
> `so_materialize` 指**模块系统把符号索引物化进 SYM 表**
>(`docs/superpowers/plans/2026-09-17-home-repro.md:209` 等)。
> 本文的「materialization / 存在物」与之**无关**;合入时须择一改名或加限定语。

### 2.3 字段级定稿(七字段)

原文只给了字段名;下表把每个字段**穷尽化**为:语义 · 取值域 · 谁写 · 谁读。
**本表整体 = [提案]**——原文未规定取值域与读写方,**这是本文档的补全,不是原文的转述**。

| 字段 | 语义 | 取值域 | 谁写 | 谁读 |
|---|---|---|---|---|
| `recipe` | 该 Entry 的存在能否**由图内配方重新导出**等价状态 | `{recomputable, unrecomputable}`(二元) | **编译器前端**(唯一持有图的一方):判定 = 定值节点链是否终止于边界/不可重算标注;Entry 无配方(参数、外部输入)⇒ unrecomputable | **mapper**(驱逐决策)+ **验证器**(驱逐不变量的适用性) |
| `identity` | 这是哪一条 Entry(同一性) | Entry 标识 = (变量标识, 版本序);匿名条目 = 产生节点身份 | **编译器**(条目生成期) | 所有消费方:共存判定、去重、跨边界身份重指 |
| `version` | 该 Entry 在同一 identity 版本序列中的位置 | 1-based 组内序(现行实现口径) | **编译器**(版本切分) | **mapper**(共存判定必须同版本)+ 调试通道 |
| `authority` | 同一 Entry/version 有多份 materialization 时,**哪一份在语义上算数** | `{single(ref), shared-readonly, unresolved}` | **runtime / mapper**(外部/分布式情形协商后写);图内单体情形由编译器写「单一权威 = 本 materialization」 | **验证器**(可观测语义以哪份为准)+ 一致性判定 |
| `location` | 当前在哪里存在 | mapper 的位置域(**格层不定义位置代数**——现行口径:位置域 = 实例侧声明) | **mapper**(分配/放置决策) | mapper(emit)+ 验证器(location 无关性判定的输入) |
| `persistence` | 该 materialization 消失前,**其状态是否必须被转移到某个合法载体** | `{free, transfer-required, externally-owned}` | **编译器**(由 `recipe` + 边界标注推导)+ **外部**(设备/OS 拥有的资源) | **mapper**(驱逐决策)+ 验证器 |
| `replicability` | 该 materialization 是否允许存在多份 | `{free, readonly-share, forbidden}` | **编译器**(线性/仿射分析)+ **runtime**(外部资源) | **mapper**(跨边界传递/优化)+ 验证器 |

**两条蕴含关系(不是等价)**:

```
recipe = unrecomputable        ⟹  persistence ∈ {transfer-required, externally-owned}
replicability = forbidden      ⟹  authority = single           # 多份不合法 ⇒ 权威不可能有歧义
```

反向**不成立**:`recomputable` 的 materialization 也可能带 `transfer-required` 的副作用状态
(例:持锁的临时物——值可重算,但锁必须在消失前转移)。这正是新式子比旧式子宽的地方(§四)。

**关于 `evictable`**:原文把 `evictable` 列为缓存的判定条件之一(`recipe=yes/replicable=yes/evictable=yes/authority 可转移`),
**但它不是第八个字段**——它是**派生量**:`evictable = (recipe=recomputable) ∨ (persistence 已满足)`(§四)。
本文件不把它列为字段,以免与不变量重复陈述。

---

## 三、归类表:把原文点名的形态放进同一模型

### 3.1 判定口径

每个形态给一个七元组读数。约定:
- `—` = 该形态下该字段无意义/不适用;
- 「放得进」= 七元组能**唯一确定**该形态的合法存在行为,无需模型外补充规则;
- 「有保留」= 能描述,但需要一条模型内的附加约定;
- 「放不进」= 七元组**缺一个维度**,硬塞会掩盖该形态的本体差异。

### 3.2 放得进去的(9 例)

| 形态 | recipe | identity | version | authority | location | persistence | replicability | 判定 |
|---|---|---|---|---|---|---|---|---|
| **cache** | recomputable | Entry | 当前版 | single(可转移) | mapper 选 | free | free | **放得进**(定义性的那一类) |
| **register** | recomputable | Entry | 当前版 | single | 寄存器号 | free | free | **放得进** |
| **RAM** | recomputable | Entry | 当前版 | single | 地址 | free | free | **放得进** |
| **VRAM** | recomputable | Entry | 当前版 | single | 设备地址 | free | free | **放得进**(异构 residency = location 取不同值,模型零改动) |
| **spill / CPU↔GPU relocate** | recomputable | Entry | 当前版 | single | 迁移前后 | free | free | **放得进,但注意:它们不是「形态」而是「转移」**——是 materialization 之间的转换,属第 4 问不属第 1 问 |
| **MMIO read** | unrecomputable | Entry(每次读 = 新 Entry) | 每次读新版本 | single(device) | 设备端点 | externally-owned | **forbidden** | **放得进,有保留**:必须约定「volatile 读每次 = 一条新 Entry」,否则 identity 会把两次读混成一条(读清零类寄存器会静默错) |
| **随机数** | unrecomputable | Entry | — | single | 熵源端点 | transfer-required | free | **放得进**(熵源是边界;抽出的值 = recipe=no 的 Entry) |
| **外部输入** | unrecomputable | Entry | — | single | 外部 | externally-owned | free | **放得进**(= 现行条款 4「边界公理」的既有四类:MMIO/FFI/输入/测量) |

### 3.3 放不进去的(4 例,卡点逐条)

**这四条是本文档最重要的产出。** 强行把它们塞进七元组会掩盖真实差异,
导致「未来的新范式不得不伪装成缓存系统」——恰是维护者原话要防的事。

#### (1) 一次性 token — 卡在「使用义务」

- 七元组能表达的:`unrecomputable` / `forbidden` / `transfer-required`——**存在面完全放得进**;
- **放不进的是**:「**必须恰好消费一次**」。
  - `replicability = forbidden` 只说「不许有多份」,**不含**「必须被用掉」;
  - `persistence = transfer-required` 只说「消失前要转移状态」,**不含**「不许不消失」。
  - 缺的维度 = **Entry 上的使用义务(linear/affine use obligation)**,不是 materialization 的属性。
- **该维度在模型里的正确位置**:现行经文已有一句可承此——条款 5 说
  「『可变』不是内存单元的属性,是**绑定**可移动的**许可**」(`cache-semantics.md:29`)。
  即:**存在面(Materialization)与使用面(绑定/许可)在本仓语义里本就是两根轴**。
  本提案的正确做法是**显式承认这根轴的存在**,而不是把它塞进七字段。
  > [已设计未实现] 该轴的设计面在:消息标签 `MOVE`(「发送点之后发送侧与消息条目闭包无『可能读』」,
  > `docs/superpowers/specs/2026-09-04-message-copy-elision-design.md:41`——标签表 `{COPY, MOVE, SHARE}` 表头见 `:37`)与
  > 并发模型新 primitive 集 `{MOVE, LOAN, SPLIT, FILL, COPY}`
  > (`docs/superpowers/specs/2026-09-17-concurrency-model-design.md:58`;
  > SHARE 降级裁定见 `:564`)。

#### (2) 线性资源 — 卡点同上 + 「外部持有」

- 与 (1) 同卡在**使用义务**;
- 额外:线性资源常由**外部**持有(authority = OS/设备,而非图内)。
  七元组里 `authority` 的取值域 `{single, shared-readonly, unresolved}` **能表达**这一点
  (取值 = 一个外部 materialization 引用),所以这半边放得进。
- 结论:**存在面放得进,使用面放不进**——与 (1) 同一条卡点。

#### (3) 事务临时状态 — 卡在「可见性义务」

- 七元组能表达的:`unrecomputable`(回滚 ≠ 重算)/ `transfer-required` / `forbidden`;
- **放不进的是**:「**该物化在事务外不可被观测**」。
  - 这不是「哪个 materialization 合法」的问题,而是「**谁在什么时候可以读它**」的问题;
  - 七元组的每一格都在描述**物化自身**,而这条义务描述的是**物化与观察者的关系**;
  - 缺的维度 = **可见性/隔离域(visibility / isolation domain)**。
- **为什么不能靠 `version` 蒙混**:version 能表达「这是事务内的第几版」,
  但表达不了「这一版**不许被谁**看见」。版本化是**时间**轴,可见性是**观察者**轴。

#### (4) 分布式唯一 authority — 卡在「权威是协商出来的、且可能暂时不存在」

- 七元组里 `authority` 是一个**静态字段**(写入即定),而分布式情形下:
  - 权威可能**暂时无人担任**(分区/脑裂)——模型无法说「当前权威未知」;
  - 权威是**协商/收敛的结果**,不是物化的固有属性;
  - `replicability` 的合法性可能是**有条件的**(「有 quorum 时允许复制」),而取值域 `{free, readonly-share, forbidden}` 是无条件的二/三值。
- 本仓现行口径已把这件事放在**别处**:`authority` 的**授权**归治理层
  (`consult/assume/measure/pass`)——v4 定稿「**能力不提升一等公民**」条
  (`docs/maintainer/adr/adr-0005-memory-model-layers-v4.md:15`:
  `身份 = 图节点、无配方 = 标注、授权归治理层`)。
- **结论**:分布式唯一 authority **不属于格层**——它的权威协商是**治理层**的事。
  格层只需能表达「本 Entry 的权威在多份 materialization 之间**未定**」
  (这正是本文给 `authority` 取值域加了第三值 `unresolved` 的理由),协商过程不进格层。

### 3.4 归类表小结

| 判定 | 例数 | 形态 |
|---|---|---|
| 放得进 | 9 | cache / register / RAM / VRAM / spill / CPU↔GPU relocate / MMIO read(有保留) / 随机数 / 外部输入 |
| 放不进(卡在**使用义务**) | 2 | 一次性 token / 线性资源 |
| 放不进(卡在**可见性义务**) | 1 | 事务临时状态 |
| 放不进(卡在**权威的协商性**;应归治理层) | 1 | 分布式唯一 authority |

**这条小结本身就是修订的理由**:13 例里 9 例落在缓存语义的舒适区,
4 例的卡点**集中在三根不同的轴上**——而这三根轴**没有一根是「缓存 vs 非缓存」**。
若把层定义成「缓存」,这 4 例会以「缓存的特例」被硬塞,卡点被永久掩盖。

---

## 四、不变量改写

### 4.1 旧式子的实际形态

现行条款 2 逐字(`docs/academic/cache-semantics.md:25`):

> `2. **驱逐不变量**。驱逐图内任意条目(丢弃存储物、保留配方)不改变可观测语义——只影响性能,不影响正确性。形式化目标:⟦G ∖ storage(e)⟧ = ⟦G⟧。这是"缓存语义"的定义性质。`

其可操作形式(维护者原话的概括)= **「所有东西都可以驱逐,只要能重算或写回」**。

关键在于:**它是一条「许可」式断言**(给出了驱逐的**条件**),而条款 4b 是补丁
(`:28`:`4b. **图内不可重算**…驱逐不变量/再生等价对其不成立`)。
也就是说:**现行七条把「不可重算」写成驱逐不变量的一条例外**,而不是让它落在同一条式子里。

### 4.2 新式子与逐条对照

原文新式子:

```
Evictable(x)  ⟺  Recoverable(x) ∨ PreserveRequiredState(x)
```

**新式子多涵盖什么**——具体反例形态(只满足新式子、不满足旧式子):

| # | 反例形态 | 为什么不满足旧式子 | 新式子怎么覆盖 |
|---|---|---|---|
| **R1** | **不可重算、且没有可写回的 home**(只写寄存器/不可导出的硬件密钥) | 旧式子对无配方条目要求「必须有 home(持久位置)、驱逐必写回」——但该形态**根本没有可写回的位置** | `Recoverable = false`,`PreserveRequiredState = true`:状态以**非材料形态**(句柄/指认)转移到另一个合法 materialization。旧式子的「写回」以「对象有可复制字节材料」为前提,**这里前提不成立** |
| **R2** | **有配方、但重算不合法**(volatile MMIO read:地址在,重读一次 ≠ 原值,且有副作用) | 旧式子的「只要能重算」读起来是**语法性**的(配方存在 ⇒ 可驱逐)。这正是 4b 必须打补丁的根因 | `Recoverable` 在**语义等价**意义下判定:`recipe` 存在 ≠ `Recoverable`。**4b 从「例外」变成「一个 case」** |
| **R3** | **可重算、但驱逐本身有可观测副作用**(值可重算,但物化持有锁/占用配额) | 旧式子只从**值侧**数可观测变化,判为「驱逐无副作用」 | `PreserveRequiredState = true`:义务显式落在**状态转移**上 |
| **R4** | **不同副本表示同一值的多份合法物化**(SHARE 式只读别名) | 旧七条**从未陈述复制合法性**(§1.2 假设 2/6),因此对「多份是否合法」无话可说 | `replicability = readonly-share` + `authority = shared-readonly` |

**新式子丢掉了什么**(必须明说):旧式子对 `recipe=recomputable` 的对象给出的是
**无条件的、可机械判定的**许可(walk 配方链即得);
新式子多出一个 `PreserveRequiredState` 析取支,它是**义务**而非**事实**——
义务可以被空口声明。**这是新式子的新增失败模式**,必须在同一批里配 fail-closed 规则(§4.4)。

### 4.3 怎么测(判据形状)

三向钉子(缺一不可):

1. **正向钉(Recoverable 侧)** —— 构造 `recipe=recomputable` 的 Entry,
   驱逐其 materialization、重新物化,断言两态**可观测等价**。
   形状:同基 pre/post 对拍(产物逐字节 / 观测读数相同)。
   > [已实现] 该形状的既有资产:自举链 `corec2 == corec3` 逐字节对拍、
   > ELF canary 冻结 sha(`docs/maintainer/design/` 各批判据),可直接复用为对拍骨架。
2. **反向钉(PreserveRequiredState 侧)** —— 构造 `recipe=unrecomputable` 的 Entry,
   驱逐其 materialization **且不做状态转移**,断言**必须拒绝**(rc≠0 或硬错),
   **绝不允许静默通过**。
   > 这是新增判据。旧不变量下该形态不存在,**所以现行判据网对此的覆盖为零**
   > ——一个不会红、只会腐烂的判据面。
3. **边界钉(归属判定,决定前两条怎么用)** —— 对每个进入判定的对象,
   必须**机械地**判定它落在 `Recoverable` 侧还是 `PreserveRequiredState` 侧:
   - 存在一条从该 materialization 到 Entry 配方、且**全在图内**的重算路径 ⇒ `Recoverable`;
   - 存在一条**显式登记的状态转移记录** ⇒ `PreserveRequiredState`;
   - **两者都判不出 ⇒ 不可驱逐**(fail-closed,§4.4)。
   > [已实现] 「全在图内」这个判定的既有近亲 = 指针 provenance 三 pass 的边界验证
   > (`provenance_verify.cr` / `region_check.cr`),判定形状可借鉴,但**不是同一件事**、
   > 不可直接复用(provenance 判的是归属+偏移,不是可重算性)。

### 4.4 新式子的 fail-closed 规则(必配)

```
不可判定 ⇒ 不可驱逐。
```

理由:`PreserveRequiredState` 是义务,义务的**未满足**与**未被检查**在观测上不可区分
——这正是本仓反复收口的「静默类」缺陷的形状(`docs/maintainer/design/` 各批的
「静默面收口」)。所以判据必须是:归属判定返回「未知」时,**判为不可驱逐**,
而不是判为可驱逐。

### 4.5 显式约束:`recipe = unrecomputable` 的驱逐**必须**走 PreserveRequiredState 支

**这条不是本文件的发明——它来自条款 4b 的义务面**(`docs/academic/cache-semantics.md:28`:
「其存储必须持久(home 保有材料),驱逐必须写回」;`:59`:「无配方条目必须有 home(持久位置),
驱逐必写回」),本文件只是把它写成**可执行的显式约束**。

```
recipe = recomputable    ⇒ Evictable 走 Recoverable 支
                            回收 = 驱逐 + 按需再生(条款 3 / remat),零额外义务
recipe = unrecomputable  ⇒ Evictable **只能**走 PreserveRequiredState 支
                            回收前材料已保有(写回 home)或被合法转移(身份重指)
                            **不得**按「可重算」处理——那是把义务当成优化
判不出 recipe            ⇒ 不可驱逐(§4.4 fail-closed)
```

**为什么必须写死**:映射实例侧(尤其 `regalloc-cache-mapping.md` §二「算法零证明」)
把 residency(物化在哪)**整体当优化**处理。这对 `recipe = recomputable` 的条目是**对的**
——放置策略自由,正确性与算法无关。但**一旦不按 `recipe` 分档**,`unrecomputable` 的条目
会被一并当成「放置策略的自由选择」,实现出来就是「**可丢**」——

> **那是静默语义破坏,不是性能优化。**

它恰好是本次修订要消灭的那一类(观测上完全不可区分:丢了材料 vs 从没打算留)。
因此该约束已同批落到 `regalloc-cache-mapping.md` §三.1 与 §四 规则 ③。

> **实现状态 [已实现-反证]**:该分档目前**没有实现**——`ENT.flags` bit0 恒 0
> (§7.1),即当前**没有任何条目被标记为无配方**,判定无从分档。这**不构成现存缺陷**
> (边界/执行标注尚未进入 `.ccr`),但**生产者落地时必须与本节同批**——
> 否则该形态一进 IR 就是静默可丢。

---

## 五、划界:cache policy 不属于格层

### 5.1 明写归属

原文裁定:`LRU` / `write-back` / `write-through` / `prefetch` / `GPU 是否保留 residency`
——**全部归 mapper**,不是格层语义。

格层只描述四问(§2.1);**「什么时候驱逐 / 放寄存器还是 RAM / GPU 是否保留 residency」全给 mapper**。

### 5.2 可检验的划界判据

原文给的判据形状:**格层描述里出现「何时/多久/顺序」这类词 = 越界**。

**这条判据有一个反例,必须先处理掉,否则判据是假的**:
`.ccr` 的 ENT 里有 `live_start` / `live_end`(存在区间)——**它就是一个「何时」**,
而且它 [已实现] 在格层载体里(`src/lattice/ent_kernel.cr:217-218` 访问器;
填充 = `compute_live_ranges`)。若照字面用原判据,现行实现自己就越界了。

**修正后的判据(本文件提议)**:

> 格层可以陈述**由图唯一决定的**时序坐标(存在区间、版本切分点——它们是图上已确定事实的投影);
> 格层**不得**陈述**含自由参数的**时序决策(何时驱逐、预取多远、驻留多久——这些依赖策略输入)。

**可机械检验的形式**:

```
给定该时序值,能否只由图+Entry 字段唯一确定?
  能  ⇒ 属格层(例:live_end = 版本区间终点 = 图上已定)
  不能 ⇒ 属 mapper(例:某 materialization 何时被回收 = 自由)
```

判据形态:**「能否由图上已确定的事实唯一决定」**——
比「有没有出现『何时』二字」可检验,且不会把现行实现判成越界。

> 补充检验 [已实现]:现行实现已按此划界——
> `home`(放置决策)**恒 -1 不写回格式**(`src/compiler/ccr_io.cr:85`:
> `home 恒 -1(实例注记——分配决策不写回格式,字节 spec §3.5)`),
> 而 `live_start`/`live_end`(图上已定)写回。
> **现行实现是这条修正判据的正面样本。**

---

## 六、修订账:旧教义在仓库里的落点

### 6.0 实际执行记录(2026-09-20)

**处置口径**:逐处判类别,**不做机械替换**——「宣布权威」类必改;「引用条款 N」类
**指针仍然有效**(条款 1–7 内容未变),只改外层框定词;**plans/specs/archive 不动**(历史留痕)。

**同批就地改动(12 个既有文件 + 1 新增 ADR)**:

| 文件 | 改动 |
|---|---|
| `docs/project-book.md` | `:109` 存储即缓存→存在格物化;`:216` 本体为存在格(缓存=该类映射实例) |
| `docs/z-vision.md` | `:15` 语义本体 = 存在格 |
| `docs/README.md` | `:27` 存储语义索引行重排(层定义置首);`:37` 权威宣告降为「条款 1–7 · 缓存映射一类」 |
| `docs/maintainer/design/memory-model.md` | 标题链 + §一 分工表(**层定义条目置首**)+ 三层图 + §三 术语表(新增「缓存语义」行)+ §四 关联 |
| `docs/academic/cache-semantics.md` | 标题/权威自述/§零 重写(六假设 + 边界)+ 条款 2 适用范围收窄 + **新增条款 2′** + §二 条款 2/3 细读 + 4/4b 小节 + 条款 7 细读 + §三 映射表 + §四 关联 |
| `docs/maintainer/design/existence-structure.md` | `:4` + §九 关联;**`:59` 加实现状态更正注**(位就位 ≠ 语义就位) |
| `docs/maintainer/design/regalloc-cache-mapping.md` | 标题/定位 + 三层图「格(存在)」行 + §二 公理措辞 + **新增 §三.1 显式约束** + §四 规则 ③ 按 recipe 分档 |
| `docs/maintainer/design/region-model.md` | 标题/定位 + `:102` 权限投影措辞 + §七 关联 |
| `docs/maintainer/design/pointer-model.md` | `:4` 定位 + `:48` 「存储语义」→「地址语义」(条款 6 指针仍有效) |
| `docs/academic/lattice-theory.md` | `:4` + `:48` 规则行 + `:70` 映射表 ⊇ 措辞 + `:82` + §七 关联 |
| `docs/maintainer/design/dataflow-design.md` | `:6` + `:235`(条款 4b 指针保留,补 `recipe = unrecomputable` 与 2′ 指向) |
| `docs/glossary.md` | §二 格(层) 行 + 新增「存在格七字段」行 + §四 标题/表(新增物化/驱逐完整判据/无配方条目)+ §五 标题 |
| `docs/maintainer/adr/README.md` | `:34` ADR-0006 状态 → `superseded by ADR-0021`;索引表追加 ADR-0021 |
| **新增** `docs/maintainer/adr/adr-0021-existence-space-layer-definition.md` | 本修订的决策记录 |

**ADR 处理(遵 `adr/README.md` 规则:不修改已 accepted 的历史记录)**:
- `adr-0006` **只改状态行**为 `superseded by ADR-0021`(正文逐字保留,含「语义本体 = 缓存语义七条」原文)——`jj diff` 实核 **1 行改动**;
- **新起 ADR-0021** 承载本次决策;**注意 `adr-0020` 已被 `adr-0020-ir-dual-form.md` 占用**,故取 0021(取号前已 `jj file list` 实查当日最大号)。

**明确不动**:`docs/superpowers/plans/**`、`docs/superpowers/specs/**`(≥8 份引用,历史设计稿)、
`docs/archive/**`(归档即历史、`adr/README.md` 规则)、`docs/developer/concepts/memory.md:39`(纯链接,无权威宣告)。

### 6.0.1 收窄口径与回退(2026-09-20 二次校订)

维护者随后把范围**收窄**,并给出**最终判据**——**不按「类」判,按「这句话有没有宣告权威」判**:

| 判据 | 处置 |
|---|---|
| **含权威宣告**(形如「权威 = cache-semantics.md」「本体唯一权威」) | **必须改**,重指新权威 |
| **纯描述**(形如「X 是缓存语义的映射实例」,不含权威宣告) | **不动** |

**「内部一致是硬要求」**——这是本判据的主因:同类句若一处改一处不改,文档自相矛盾。

**逐处重判结果**:

| 处 | 判定 | 依据 |
|---|---|---|
| `memory-model.md` §四 关联 bullet | **不动**(已回退) | 「寄存器分配 = 缓存语义的映射实例:<doc>」= 纯描述,无权威宣告 |
| `regalloc-cache-mapping.md:1` 标题 | **不动**(已回退) | 「# 寄存器分配:缓存语义映射实例」= 纯描述 |
| `regalloc-cache-mapping.md:4` 定位行 | **改权威半句** | **含**「权威 = docs/academic/cache-semantics.md」⇒ 重指;「映射实例」框定**保留** |
| `dataflow-design.md:235` | **不动**(已回退) | 「映射实例侧(寄存器分配 = 缓存语义映射实例)见 …」= 纯描述 |
| `glossary.md` §五 标题 | **不动**(已回退) | 「寄存器分配(缓存语义映射实例)」= 纯描述 |
| `region-model.md:4` | **改权威半句** | **含**「权威 = docs/academic/cache-semantics.md」⇒ 重指;「映射实例」框定保留 |
| `region-model.md:102` | **不动**(已回退我的改动) | 「权限层不是语义本体,是缓存语义在…的权限投影」= 否定式纯描述,无权威指向 |
| `region-model.md:156` | **保留我的改动** | 原句「**语义本体**:docs/academic/cache-semantics.md(七条…)」**含权威宣告** ⇒ 须重指;改后 = 「层定义:materialization-space.md」+「条款权威:cache-semantics.md」 |
| `regalloc-cache-mapping.md:29` | **保留**(三层图行) | 「(cache-semantics **本体**;v6 ENT 编码)」**含权威宣告** ⇒ 改「存在格本体」 |
| `cache-semantics.md:122` | **改** | 「语义本体总览:memory-model.md」= 该层词被用来指称导航文档 ⇒ 改「存储语义总览」(与 memory-model.md 现行标题一致) |

**合计**:回退 **6 处**（5 处首轮过改 + `region-model.md:102` 二次回退）· 保留/新改 **4 处**（`regalloc:4` · `region-model:4` · `region-model:156` · `cache-semantics:122`；另 `regalloc:29` 首轮已改对）。

**一致性回归**:回退后全仓**纯描述**类陈述口径统一为「缓存语义映射实例」
(与原本未动的 `project-book.md:111`、`TODO.md:2161/2313` 一致);**权威宣告**类则一律已重指到新权威。

**经判断**不属本次修订范围、**未改**的一处(列此备查):`adr-0005:13`「层规则 = 缓存语义七条,永不新建」——
该行是 accepted ADR 正文,且属**层定义条款**而非权威宣告;按规则不得就地改。已登记见 §九。

### 6.1 扫法与边界

- 扫法:全仓 `grep`,pattern = `缓存语义|驱逐不变量|CacheEntry|cache-semantics|值 = 配方|值即条目|再生等价|无配方条目|缓存是本体`,
  加同义补漏(`本体|语义本体|存储即|唯一权威|权威条款|格层本体|中间存在空间|规则封闭|无格承诺|范式无关|零签名`);
  排除:纯路径引用/链接、目录列表、计划条目编号、无关 `cache`(.cir 缓存 / `cir_cache.cr` / 编译缓存);
- 命中规模:**约 150 行 / 约 46 个文件**;
- **本账的可靠性边界**:§6.3 与 §6.4 中标注「✓实核」的行由我**逐字复核**过 line 与摘句;
  其余行按同一 grep 口径登记,**未逐行复核**。

### 6.2 甲类:已就地改(把缓存当**本体定义**说的)

这些位置删除「本体/定义」措辞后语义**不变**——改动是措辞收口,零行为变化。

| file:line | 现行措辞(逐字摘句) | 新定义下该怎么读 | 建议处置 |
|---|---|---|---|
| `docs/academic/cache-semantics.md:1` ✓实核 | `# 缓存语义:存储语义本体(权威条款)` | 标题的「本体」是**过度自称**——本文件是**一类映射实例**的条款权威,不是层本体的权威 | 就地改标题 |
| `docs/academic/cache-semantics.md:4` ✓实核 | `本文件是 Core 存储语义本体的**唯一权威**` | 改为「缓存映射这一类实例的条款权威」;**且新层定义的权威须另有归属**(§九 A) | 就地改 |
| `docs/academic/cache-semantics.md:12` ✓实核 | `Core 的存储语义本体是**缓存**——范式无关的存储抽象` | 层本体 = 存在格;缓存 = 其中一类。本句改为「缓存映射 = 存在格的一类实例」 | 就地改 |
| `docs/academic/cache-semantics.md:6` ✓实核 | `分层位置:三层映射链(图 → 格 → 编码)的「格」层语义本体` | 同上——「格层语义本体」= 存在格;缓存是其子类 | 就地改 |
| `docs/academic/cache-semantics.md:43` | `驱逐不变量是"缓存语义"的定义性质:任何存储都可以被丢弃,只要配方还在。` | **「定义性质」不成立**(§4.2 R2/R3);且「任何…只要配方还在」是旧式子的充分形态 | 就地改(与 §四同批) |
| `docs/maintainer/design/memory-model.md:1` ✓实核 | `# 存储语义总览:缓存 → 存在结构 → 经典映射` | 首段链应改为「存在格 → 存在结构 → 经典映射」 | 就地改 |
| `docs/maintainer/design/memory-model.md:22` | `条款 1-7:缓存语义`(三层图) | 该格 = 存在格;(现状注:此图第二层唯一的框内内容就是缓存语义) | 就地改 |
| `docs/maintainer/design/memory-model.md:37` | `\| 语义存储 \| 缓存(范式无关本体)——条目、配方、驱逐、再生 \|` | 「范式无关本体」改为「存在格」 | 就地改 |
| `docs/project-book.md:109` ✓实核 | `值即条目(配方可重算),存储即缓存(范式无关),内存只是经典映射` | 「存储即缓存」→「存储即存在格的物化」;「值即条目」仍成立 | 就地改 |
| `docs/project-book.md:216` ✓实核 | `存储语义本体为**缓存语义**(值 = 配方、条目可驱逐可再生、图边界为唯一不可再生来源)` | 「本体为缓存语义」→「本体为存在格;缓存语义是经典映射的理论面」 | 就地改 |
| `docs/z-vision.md:15` ✓实核 | `存储半边已定稿(语义本体 = 缓存语义,字节内存 = 经典映射实例…)` | 「语义本体 = 缓存语义」→「语义本体 = 存在格」 | 就地改 |
| `docs/glossary.md:20` ✓实核 | `\| 格(层) \| 存在空间:如何存在——条目、配方、驱逐、再生 \|` | 定义已正确(「存在空间」),**但四要素列的是缓存四要素**——须换成七字段口径 | 就地改 |
| `docs/README.md:37` ✓实核 | `[cache-semantics.md]— 缓存语义七条(存储语义本体,权威)` | 「存储语义本体」→「缓存映射条款」 | 就地改 |
| `docs/maintainer/adr/README.md:34` ✓实核 | `\| ADR-0006 \| 缓存语义 = 存储语义本体(2026-08-15 纠偏) \| accepted \|` | ADR 标题是**历史决策的记录** | **加注**(见下) |
| `docs/maintainer/adr/adr-0006-cache-semantics.md:1,11` ✓实核 | `# ADR-0006: 缓存语义 = 存储语义本体(2026-08-15 纠偏)` / `语义本体 = **缓存语义七条**` | **不改正文**——ADR 是决策记录,改写它是篡改历史 | **加修订注 / 新 ADR 标 `superseded-by`** |
| `docs/maintainer/adr/adr-0005-memory-model-layers-v4.md:13` ✓实核 | `**规则封闭、对象开放**:层规则 = 缓存语义七条,永不新建` | 层规则应从「缓存七条」改为「存在格的字段与不变量」;这是**层定义条款**,须与 §二同批 | **加修订注 / 新 ADR** |
| `docs/academic/lattice-theory.md:48` ✓实核 | `- **规则(封闭,永不新建)**:缓存语义七条 + 最弱理论(关系层面)。新范式出现时层本体一字不改` | 「层本体一字不改」在本修订下**恰好被满足**——改的是缓存**在层内的位置**,不是加新规则 | 加注 |
| `docs/maintainer/design/regalloc-cache-mapping.md:29` | `格(存在) 条目存在:版本、共存、驱逐(cache-semantics 本体;v6 ENT 编码)` | 「cache-semantics 本体」→「存在格本体」 | 就地改 |
| `docs/maintainer/design/existence-structure.md:4` ✓实核 | `七条缓存语义条款(权威 = docs/academic/cache-semantics.md)如何在 .ccr 中落成 IR 一等结构` | 载体不变;条款的**地位**变了(从层本体 → 一类映射的条款) | 加注 |
| `docs/maintainer/design/dataflow-design.md:6` ✓实核 | `执行标注空间是 cache-semantics 条款 4b「图内不可重算」与 glossary 的出处,修改需先改条款` | 条款 4b 在新定义下变成「`recipe=unrecomputable` 的判定来源」;**出处关系不变** | 加注 |
| `docs/superpowers/specs/2026-09-09-lattice-encoding-boundary-design.md:8,35,105` | `docs/memory-model.md §一(缓存语义七条 = 格层语义本体)` / `**ENT 是格层本体在 v6 里最纯的成分**` | 层本体改称后,这些句子的指称对象不变(仍是 ENT),只换名字 | 加注 |
| `docs/superpowers/specs/2026-08-27-lattice-form-ir-design.md:15,30` | `\| **格形态** \| 格 = 存在空间 \|` / `格形态 = 格层(存在空间)的承载格式` | **已经是新定义的表述**——「格 = 存在空间」而非「格 = 缓存」 | **不动**(正面样本) |
| `TODO.md:2137` ✓实核 | `v4 定稿:**规则封闭对象开放**(层规则零签名 = 缓存七条;对象无界…)` | 层规则换称;`无格承诺` 与 `能力不提升一等公民` **不受影响** | 加注 |

### 6.3 乙类:已就地改框定词(派生引用,条款指针不变)

这些位置引用的是**条款本身**(配方/驱逐/再生/无配方),而条款 1/3/4/4b/5/6/7
在新定义下**原样成立**(§1.3),因此**不需要改**,只需在权威文档处加一条修订注让读者找到本文档。

代表行(非穷举,完整清单见 §6.4 的 grep 口径复跑):

| file:line | 现行措辞摘句 | 性质 |
|---|---|---|
| `docs/maintainer/design/regalloc-cache-mapping.md:1,4,41,43,57,65` | `# 寄存器分配:缓存语义映射实例` / `**驱逐不变量(条款 2)**:⟦G ∖ storage(e)⟧ = ⟦G⟧` | **D 类,不受影响**——「X = 缓存语义的映射实例」在降级后反而**更自然** |
| `docs/maintainer/design/region-model.md:1,4,102` | `# 图锚定区域:缓存语义的经典映射` / `权限层不是语义本体,是缓存语义在字节寻址机器上的权限投影(条款 7)` | D 类;(:102 的「不是语义本体」在新定义下仍成立) |
| `docs/maintainer/design/pointer-model.md:4,48` | `存储语义本体(条目标识 + 偏移)见 …条款 6` | B 类(条款 6 原样成立) |
| `docs/glossary.md:23,38,42-48,52` | `## 四、缓存语义(核心七条 + 边界)` | B 类;:20 归甲类 |
| `docs/maintainer/design/existence-structure.md:16,57,126` | `**格层 vs 编码层**:ENT/NOD/REG 的语义…属格层,范式无关` | A 类(层定义,只需换称) |
| `docs/superpowers/specs/2026-09-09-lattice-ir-v7-carrier-design.md:54,60,77,98,153` | `驱逐不变量 / 再生等价 / 版本化(条款 1/2/3/5)成为可在载体上陈述的性质` / `home = 实例映射注记` | B/D 类;**:60/:83「home = 实例注记、格本体最小集不含 home 的决策权」与新定义完全一致**——正面样本 |
| `docs/superpowers/specs/2026-08-27-regalloc-cache-mapping-design.md:16,30,31,44` | `**公理 = 缓存语义七条**` / `**驱逐不变量 = 语义保持定理**` | B 类(条款 2 措辞须与 §四同批) |
| `docs/superpowers/specs/2026-09-17-concurrency-model-design.md:359,497,560,564` | `「无配方条目(不可重算,必须有 home,永不重建材料)」,语义不完全相同…` | B 类;**:564 是新定义 §3.3(1) 的**使用义务轴**所在,须与 §三同批读 |
| `docs/superpowers/specs/2026-09-04-message-copy-elision-design.md:12,37,51,55,57` | `标签 ∈ {COPY, MOVE, SHARE}` / `**COPY** = 双 home:双方各执材料,配方同源(再生等价)` | B/D 类;MOVE/SHARE/COPY 与新定义 §二 字段的对应关系见 §3.3 |
| `src/arch/x86_64/regalloc.cr:336,371` | `// 语义:寄存器文件 = 缓存层、栈槽 = home 的映射实例(缓存语义条款 7)。` | **源码注释**——D 类不受影响;但若合入,注释措辞可同批顺修 |
| `TODO.md:2137,2152,2159,2161,2162,2168` | `无配方标记 = ENT flags bit0 字段就位` | B 类;**:2159 `ENT flags 无配方完整语义(条款 4b)` 是 §7.1 的关键锚点** |

### 6.4 丙类:明确不动

| file:line | 现行措辞摘句 | 不动的理由 |
|---|---|---|
| `docs/archive/memory-model-capability-lattice.md:6,17,99,123,241,253` 等 26 行 | `状态:**v4 发布——方向定稿**:…` / `层本体 = 缓存语义七条(零签名、无恒等式 → 无封顶)` | **归档文档**——归档即历史,改动等于伪造历史 |
| `docs/superpowers/plans/2026-08-15-cache-semantics.md`(32 行) | `Core 的存储语义本体是**缓存**——范式无关的存储抽象。以下七条为定义性条款` | **已执行的计划**——计划记录当时的意图,不回改 |
| `docs/superpowers/specs/2026-08-15-cache-semantics-design.md`(13 行) | `把存储语义本体正式定稿为**缓存语义**(范式无关)…` | **设计依据 spec**,已被 cache-semantics.md 消费;按仓规「被修订」应**标注状态行**而非改正文 |

### 6.5 本账的已知边界(必读)

- 本账是 **grep 口径的产物**,不是「穷尽性证明」:
  同义措辞若不在 §6.0 的 pattern 里,**会漏**(§八 列了已知的可疑漏网方向);
- 「必改/加注/不动」是**本文档的建议**,**不是裁定**(§九 B);
- **archive/ 与已执行计划被归入「不动」的判据 = 本仓「归档即历史」的既有惯例**,非本文档发明。

---

## 七、实核:新定义与实现的距离

> 本节全部读数由我在 `develop@origin`(commit `psnmnrln` / `38e6c992`)的检出上**亲自读源码**得出,
> 每条给 file:line。**未核实处一律标注**(§八)。

### 7.0 结论摘要

| 字段 | 实现状态 | 关键锚点 |
|---|---|---|
| `recipe` | **槽位就位,语义未实现**(恒 0,零生产者、零语义消费者) | `src/compiler/dyn_arr.cr:143`;`src/lattice/ent_kernel.cr:295,318` |
| `identity` | **部分**(var_id + version 作为 Entry 键;「身份 = 产生节点」的等价/去重面未实现) | `src/compiler/dyn_arr.cr:138`;`src/lattice/ent_kernel.cr:215` |
| `version` | **部分**(盘面有 28B 字段;内存表 24B **无** version) | `src/compiler/ccr_io.cr:74-76,177,812-815`;`src/compiler/ccr_io.cr:175-176` |
| `authority` | **无**(源码与设计文档均零命中) | — |
| `location` | **部分**(`home` 字段存在但**恒 -1**;真值在实例侧旁路表) | `src/lattice/ent_kernel.cr:294,317`;`src/compiler/ccr_io.cr:85` |
| `persistence` | **无独立字段**(义务被「必须有 home」这句措辞隐式承担) | `docs/academic/cache-semantics.md:59` |
| `replicability` | **无实现**;有设计面(两套,且互相修订中) | `docs/superpowers/specs/2026-09-04-message-copy-elision-design.md:41`;`…2026-09-17-concurrency-model-design.md:58,564` |

### 7.1 `recipe` 是不是一个真 bit —— **不是**

**结论:该位在 schema 里「就位且被文档占名」,但在实现里恒为 0——没有生产者、没有语义消费者。**

逐环节实核:

| 环节 | 位置 | 事实 |
|---|---|---|
| 字段声明 | `src/compiler/dyn_arr.cr:143` | `OFF_ENTRY_FLAGS : int = 20;   // 位 0 预留：无配方（条款 4b）` |
| 布局注释 | `src/compiler/globals.cr:232` | `flags(20) u32 = 0（位 0 预留：无配方，条款 4b）` |
| **写侧 1** | `src/lattice/ent_kernel.cr:295` | `w32(g_ir_entries, eo + OFF_ENTRY_FLAGS, 0);` **(硬编码 0)** |
| **写侧 2** | `src/lattice/ent_kernel.cr:318` | `w32(g_ir_entries, eo + OFF_ENTRY_FLAGS, 0);` **(硬编码 0)** |
| 读访问器 | `src/compiler/ccr_io.cr:473` | `fn ccr_ent_flags(e) -> int { return buf_read_i32(...OFF_ENTRY_FLAGS); }` |
| 落盘 | `src/compiler/ccr_io.cr:811,820` | `efl := ccr_ent_flags(ej);` → `buf_write_u32(buf, pos, efl)`——**纯直通** |
| 加载 | `src/compiler/ccr_io.cr:1431,1447` | `efl := buf_read_u32(data, pos);` → `w32(..., OFF_ENTRY_FLAGS, efl)`——**纯回环** |
| 诊断 dump | `src/lattice/ent_kernel.cr:415` | `print(" flags "); println(int_str(ent_flags(e)));`——**只打印** |
| 语义消费 | **全仓无** | 无任何 pass 对 `flags` 分支 |

**源码自己的口径(两句自述,互相印证)**:

- `src/compiler/ccr_io.cr:85`:
  `home 恒 -1(实例注记——分配决策不写回格式,字节 spec §3.5);flags 恒 0(无配方/参数/全局/驱逐位零实例——位语义保留)`;
- `TODO.md:2159`(挂账项):
  `后续挂账:…ENT flags 无配方完整语义(条款 4b)…`。

**其余两处旁证**:

- `docs/superpowers/plans/2026-09-09-lattice-ir-v7.md:72`:
  `无配方条目(flags bit0):现 IR 面无此形态(边界/不可重算未进 .ccr)`;
- `docs/superpowers/specs/2026-09-09-lattice-ir-v7-carrier-design.md:153`:
  `无配方条目(边界/图内不可重算):flags 标注 + home 必须`——**这是设计意图,不是实现状态**。

> **因此,`docs/maintainer/design/existence-structure.md:59` 的这句话**:
> `ENT flags bit0 = 无配方(图内不可重算)——必须有 home。`
> **作为 schema 声明是准确的**(位 0 确实按此语义预留),
> **但作为实现状态描述是误导的**:读者会以为「无配方」这个形态已经在 `.ccr` 里被表达。
> 事实是:**位就位 ≠ 语义就位**——零生产者、零消费者、恒 0。
> 建议在合入时把该句拆成两句:「位 0 已按此语义**预留**」+「**判定与写入未实现**(见 §7.1)」。

**`recipe=unrecomputable` 的生产者(边界/不可重算标注)在实现里也不存在**:
`unsafe` 块虽被解析(`src/compiler/ir_gen.cr:3146` `sg_alloc_push(SG_UNSAFE)`——建 region),
但**不写任何 ENT 标志**;执行标注空间(神谕/FIXPT/BSS/模糊融合)在 `src/` 下**只有注释级提及**,无实现
(设计出处 = `docs/maintainer/design/dataflow-design.md:235`,自述「本节不可重算标注 = 图内无配方条目」)。

### 7.2 其余六字段逐格读数

**`identity`——部分**

- [已实现] `var_id` 是 Entry 的键:`src/compiler/dyn_arr.cr:138`(offset 0)、访问器 `src/lattice/ent_kernel.cr:215`;
- [已实现] 「同一 Entry 的哪一版」用 `version` 给粒度(§7.3);
- [已实现] 「一条 Entry 何时存在」用区间给:`ent_live_start`/`ent_live_end`(`src/lattice/ent_kernel.cr:217-218`);
- **未实现的部分**:经文说的「身份 = 产生节点」(`docs/academic/cache-semantics.md:59`:
  `统一规则:无配方条目必须有 home(持久位置),驱逐必写回;身份 = 产生节点`)
  ——`def_nod` 字段 [已实现](`dyn_arr.cr:139`),但**没有任何判定按「产生节点相同」合并/识别条目**
  (即无 Entry 等价/去重机制)。匿名常量条目(`var_id = -1`,设计见
  `docs/maintainer/design/existence-structure.md:59`)在 `src/` 下**零命中** ⇒ 未实现。

**`version`——部分**。见 §7.3。

**`authority`——无**

- `src/` 下 `authorit` 的全部命中(如 `src/compiler/checker.cr:562` `判定 = 引擎唯一权威`)都指
  **类型判定引擎的权威**,与「哪份 materialization 有权威」无关;
- 设计文档里「授权归治理层」(`adr-0005:16`)是**否决**把能力/授权做成一等公民,
  不是描述 `authority` 字段;
- ⇒ **`authority` 在实现里没有任何对应物**。

**`location`——部分(且现行设计**故意**不写它)**

- [已实现] 字段 `home` 存在:`src/compiler/dyn_arr.cr:142`(`OFF_ENTRY_HOME = 16`,`-1 = 未分配`)、访问器 `ent_kernel.cr:219`;
- **两条写侧都硬编码 -1**:`src/lattice/ent_kernel.cr:294`、`:317`(`w32(..., OFF_ENTRY_HOME, -1)`);
- [已实现] 唯一写非 -1 的路径 = **测试探针**:`src/arch/x86_64/regalloc.cr:58-59`
  (注头 `:30-31` 自述「真实构建路径**永不调用**」;载体 = `corearch --inject-home-conflict`);
- [已实现] 真实分配结果走**实例侧旁路表**:`g_opt_meta`(emit 面私有)+ 内核位置登记表
  (`src/lattice/ent_kernel.cr:574` `kern_loc_assign` / `:594` `kern_loc_clear` / `:599` `kern_loc_of`;
  API 面清单见该文件头 `:26-28`);
- 源码自述:`src/compiler/ccr_io.cr:85` `home 恒 -1(实例注记——分配决策不写回格式)`;
- **这不是缺陷,是现行划界**(§5.2):放置决策属 mapper,**格层不承载**。
  ⇒ 新定义的 `location` 字段若要求「格层陈述当前位置」,则**与现行划界冲突**,
  须由维护者裁(§九 C)。

**`persistence`——无独立字段**

- `src/` 下 `persist` 的命中全在 `src/compiler/cir_cache.cr`(指 `.cir` 快照持久化,含义无关);
- 该义务在现行教义里被**一句话隐式承担**:`docs/academic/cache-semantics.md:59`
  `无配方条目必须有 home(持久位置),驱逐必写回`;
- ⇒ **`persistence` 与 `location`(home)在现行教义里是混同的**:
  「必须有 home」同时表达了「要有位置」和「要保状态」。
  新定义把二者拆成 `location` + `persistence` 两个字段,是本提案的**实质性改写**(§九 C)。

**`replicability`——无实现,有设计面(且两套设计互相修订中)**

- `src/` 下零命中;
- [已设计未实现] 设计面 A:`docs/superpowers/specs/2026-09-04-message-copy-elision-design.md:41`
  ——子区域标签 `∈ {COPY, MOVE, SHARE}`(表头 `:37`),逐条给义务;`:51` `COPY = 双 home:双方各执材料,配方同源(再生等价)`
  ——**这就是 `replicability = free` 的语义**,但以「跨边界传递标签」的形态,不是 Entry 字段;
- [已设计未实现] 设计面 B:`docs/superpowers/specs/2026-09-17-concurrency-model-design.md:58`
  ——新 primitive 集 `{MOVE, LOAN, SPLIT, FILL, COPY}`;`:564` **裁定 SHARE 降级为 mapping 优化**、
  两份 spec 的标签集**不一致**须出对齐表;
- ⇒ **两套设计互相修订,尚未收敛**;新定义若要求 `replicability` 字段,
  须先解决与这两份 spec 的对应关系(§九 D)。

### 7.3 版本面:`version` 字段与既有版本化机制的关系

Core 是**版本化赋值模型**(条款 5:`X = X + 1` ≙ `x₁ 创建、x₀ 失效、绑定移动`;
`docs/academic/cache-semantics.md:29`)。实核结论:

| 面 | 事实 | 锚点 |
|---|---|---|
| 盘面字段 | **有**:`version u32`,28B 磁盘记录的**第 2 字段** | `src/compiler/ccr_io.cr:74-76`;`ESZ_ENTRY_DISK = 28`(`:177`) |
| 内存表字段 | **无**:内存态 24B/条,六字段 `{var_id,def,live_start,live_end,home,flags}` | `src/compiler/ccr_io.cr:175-176`(`no version field` 逐字);`ESZ_ENTRY = 24`(`dyn_arr.cr:137`) |
| 版本从哪来 | **落盘时现算**:同 var 组内定值升序的 1-based 序数(单遍扫描即升序) | `src/compiler/ccr_io.cr:794,812-815`;`src/lattice/ent_kernel.cr:188` |
| 版本怎么切 | 变量每次定值切一个新版本条目,区间按定值点切割 | `src/lattice/ent_kernel.cr:154-190`(两处 carve-out:IR_STORE 单列、三 op 排除) |
| 正确性自检 | [已实现]同 var 相邻版本**必不交**(返回 0 = 版本化正确) | `src/lattice/ent_kernel.cr:445` `coexist_version_conflicts` |
| 消费点 | 分配器按版本条目共存判定;TOCTOU 类判定按版本推进 | `src/lattice/ent_kernel.cr:429`;`docs/superpowers/specs/2026-09-11-policy-state-version-toctou-design.md:47` |

⇒ **`version` 与既有版本化机制是同一件事,不是新概念**;
但它在实现里是**落盘期派生量**,不是**Entry 的存储字段**(内存态不存)。
新定义把 `version` 列为 Materialization 字段时须明确:它是**派生字段**还是**存储字段**——§九 E。

### 7.4 flag 位预算:现有多少位被占用、还剩几位

**先确认「全 `.ccr` 只有一个 flags 字段」**:

| 段 | 记录字段 | 有 flags 字段? | 锚点 |
|---|---|---|---|
| NOD | `{op,dest,src1,src2,src3,tk,item,first_edge,edge_count}`(盘 40B) | **无** | `src/compiler/ccr_io.cr:146-150`;`ESZ_NOD_DISK = 40`(`:150`) |
| **ENT** | `{var_id,version,def_nod,live_start,live_end,home,flags}`(盘 28B) | **有,唯一一处** | `src/compiler/ccr_io.cr:74-76` |
| REG | `{kind,parent,enter_nod,exit_nod,first_ent,last_ent}`(盘 24B) | **无** | `src/compiler/ccr_io.cr:87-89`;`ESZ_SG_DISK = 24`(`:162`) |
| EDG | `{to_nod,kind}` | 无 | `src/compiler/ccr_io.cr:65`;`ESZ_EDGE_DISK = 8`(`:154`) |
| 其余(STR/SYM/TYPE/IFACE) | 无条目级 flags | 无 | `grep -i flag src/compiler/ccr_io.cr` 全部命中均在 ENT 语境 |

`grep -i flag src/compiler/ccr_io.cr` 的全部命中(6 处)都在 ENT 语境:`:76,85,174,473,811,820,1431`。

**位占用(两种口径,须并列给出)**:

| 口径 | 已占位 | 剩余 | 依据 |
|---|---|---|---|
| **代码口径**(实核) | **1 位**(bit0) | **31 位** | `src/compiler/dyn_arr.cr:143` 只声明 bit0;`globals.cr:232` 同 |
| **设计文档口径** | **4 位**(bit0 无配方 / bit1 参数 / bit2 全局 / bit3 驱逐候选(v6.1)) | **28 位** | `docs/maintainer/design/existence-structure.md:45` |

> ⚠ **两口径不一致本身是一个登记项**:bit1/bit2/bit3 在**设计文档里被分配**、
> 在**代码里连注释都没有**。这不是矛盾(代码口径更保守),但意味着:
> 若照设计文档口径规划新字段,会**误以为**已有 3 位在用。

**这决定了新字段是「塞进 flag」还是「加段」**:

- 现有一个 32 位字段、**最小口径下 31 位空闲**;
- 但 §7.0 的七个字段里,**只有 `recipe` / `replicability` / `persistence` 是真正的枚举小值**
  (2–3 值,合计 ≤2+2+3 = 需要 ≤ 若干位);
- **`identity` / `version` / `location` 是大值域**(标识、序数、位置号),**塞不进 flag**——
  其中 `version` 与 `location` 已有各自的 4B 字段,`identity` 用 `var_id`;
- ⇒ **结论:七个字段不需要新段**;`recipe`/`replicability`/`persistence` 可复用现有
  ENT `flags` 的空闲位(以代码口径计余量充足);真正的工程量在**生产者与消费者**,
  不在格式空间。
- ⚠ 但**格式一改就要动 `CCR_VERSION`**(现 `= 9`,`src/compiler/ccr_io.cr:135`;
  `load` 严格等值、旧版整类拒收——D10),且**同批须重锁 `.ccr`/ELF 判据网**。
  这属于施工面,不在本提案范围(§九 F)。

---

## 八、未核实锚点与本次扫面的边界

**未核实(本文件不得据其推断)**:

1. **`.ccr` 运行时字节级验证**:本节的字段读数全部来自**源码与注释**,**没有实跑一次构建**去
   切一个真实 `.ccr` 看 flags 的字节值。「flags 恒 0」的判据 = 两个写侧硬编码 0 + 全仓无写入者 +
   源码自述——**三条都是源码面证据,不是产物面证据**。要产物面证据须
   `corec build` 一个样例 + dump ENT 段(本任务未做)。
2. **`docs/superpowers/plans/2026-09-09-lattice-ir-v7.md:72` 的「现 IR 面无此形态」**:
   未复核该结论是否仍适用于当前 HEAD(该计划早于 v9)。
3. **`src/lattice/` 的单元归属**:`ent_kernel.cr` 存在于 `src/lattice/`(本文件实核其存在),
   但 CLAUDE.md 的 `src/compiler/` 清单里**没有它**;它在 `build_selfhost_native.py` 的哪个清单
   ——**未核**。
4. **§6 修订账**:抽检 11 处(file:line + 逐字摘句)**全部通过**;
   其余约 139 行按同一 grep 口径登记,**未逐行复核**。
5. **可能的漏网方向**(§6.0 的 pattern 覆盖不到,未展开扫):
   英文表述(`cache semantics` 作为层名的用法)、
   `docs/developer/concepts/memory.md`(仅 1 命中,疑为纯链接)、
   `docs/superpowers/specs/2026-08-15-cache-semantics-design.md` 之外的推理链
   (如把「缓存」当**动词**用的段落)。
6. **`authority` / `replicability` 的「零命中」**:基于 `grep -rni` 于 `src/` 与
   `docs/maintainer/design/` 与 `docs/academic/`;未扫全 `docs/superpowers/`。
   故只能说「**在这两个目录内零命中**」,不能说「全仓零命中」。

**本次扫面的方法学声明**:

- 所有 file:line 断言均由**真跑 grep/sed** 得到;
- 所有摘句均**逐字**来自文件,未改写;
- **凡未能核实者,本文件标注「未核」,不猜测。**

---

## 九、待维护者裁 / 已裁事项

> 下表区分**已由 ADR-0021 裁定**与**仍需维护者明示**两类。

| # | 事项 | 状态 |
|---|---|---|
| **A** | **合入方式与权威归属** | ✅ **已裁**:同批就地改(维护者 2026-09-20 裁定);权威归属见 §零——层定义 = 本文件,条款 1–7 = cache-semantics.md,ADR 走 supersede |
| **B** | 修订账三条分组(必改/加注/不动) | ✅ **已执行**:§6.0 为实际记录 |
| **C** | **`location` 字段是否入格层**:现行实现**故意**把 `home` 恒 -1(放置决策 = mapper);新定义若要求格层陈述 `location`,则与现行划界冲突 | ⏳ **待裁**。倾向**不入**:`location` 属 mapper 注记,格层只承认「存在多份 materialization」这一事实。若照原文列为字段,须重新划界 |
| **D** | **`replicability` 与两份活跃 spec 的对应**:`{COPY,MOVE,SHARE}`(2026-09-04)与 `{MOVE,LOAN,SPLIT,FILL,COPY}`(2026-09-17)未收敛;`replicability` 字段是否取代它们? | ⏳ **待裁**。倾向**不取代**:字段是**格层陈述**,标签是**跨边界决策**;须出对齐表(该批已自行挂账) |
| **E** | **`version` 是存储字段还是派生字段**:现实现为落盘期派生(内存表无此字段) | ⏳ **待裁**。倾向**派生**:由图坐标唯一决定 ⇒ 依 §5.2 修正判据属格层,但不必占存储 |
| **F** | **格式施工面**:七个字段不须新段(§7.4),但真实施工要动 `CCR_VERSION`(现 9)+ 重锁 `.ccr`/ELF 判据网 | ⏳ **待裁**。**建议单独立项**。另注(lead 转来):`.ccr` 段位 tag 9+ **已有两个具名主张者**(驱逐标注段 / 证书段)——若日后加段须先与之对齐,不得各加各的。**本修订不需要加段**(§7.4) |
| **G** | **`recipe` 的施工**:§7.1 已证「位就位、语义未实现」;是否本批一并实现生产者与消费者? | ⏳ **待裁**。倾向**分开**:文档修订与语义实现是两个批次,混批会让「文档变了但行为没变」不可判别。落地时必须与 §4.5 同批 |
| **H** | **术语冲突**:`物化` 一词已被 `so_materialize`(模块系统符号物化)占用 | ⏳ **待裁**:须择一改名或加限定语 |
| **I** | **`adr-0005:13`「层规则 = 缓存语义七条,永不新建」的框定词** | ✅ **已裁 = 出路 ①**:维护者裁定**再起一份 ADR 记录收窄** ⇒ **ADR-0022**(2026-09-20)承载;`adr-0005` **正文不动**,状态行注「部分框定被 ADR-0021 收窄」,索引表补行 |
| **K** | **`TODO.md:2137`**「v4 定稿:…层规则零签名 = **缓存七条**…」 | ✅ **已裁 = 不动 + 登记指针**。它是**历史 v4 定稿的引用,不是权威宣告** ⇒ 按判据(纯描述/历史引用 ⇒ 不动)不改原文;**已在 ADR-0022 §关联 立一条登记**(指针在、原文不动),读者据该条即知现口径读法 |
| **J** | 本次修订**只改文档、不改行为**——判据面影响 = 零 | ✅ **已确认**:全仓改动仅 `.md`,无源码/产物/判据面改动 |

---

## 十、附:本修订与既有定稿的兼容性声明

维护者原话:「之前已经做出的 cache/regalloc/residency 设计基本都不用推翻,只是从
『cache 是本体』改成『cache 是一个非常重要的特例』。」

本文件逐条核对如下(**全部 = 不受影响**):

| 既有定稿 | 新定义下的地位 | 依据 |
|---|---|---|
| 寄存器分配 = 缓存语义映射实例 | **不受影响,原文保留**(该类陈述已是「实例」框架,方向与新定义一致 ⇒ 按收窄口径**不动**;见 §6.0 注) | `docs/maintainer/design/regalloc-cache-mapping.md` |
| 图锚定区域 / Arena / 字节权限 = 经典映射 | 不受影响(条款 7 原样成立) | `docs/maintainer/design/region-model.md` |
| 判定四条(共存互斥/版本/读点无陈旧/调用点失效) | 不受影响 | `src/lattice/ent_kernel.cr`;`docs/maintainer/design/regalloc-cache-mapping.md` §三 |
| 条款 1 值 = 配方 / 条款 3 再生等价 / 条款 5 赋值 = 版本化 / 条款 6 地址 = 映射 | **原样成立** | `docs/academic/cache-semantics.md:24,26,29,30` |
| 条款 4 / 4b 无配方条目 | **原样成立**,且从「驱逐不变量的例外」变为「`recipe=unrecomputable` 的一个 case」 | §4.2 R2 |
| v4 定稿:规则封闭对象开放 / 无格承诺 / 能力不提升一等公民 | **原样成立**(本修订换的是层**称谓与字段**,不是规则数) | `docs/maintainer/adr/adr-0005-memory-model-layers-v4.md:13-16` |
| **条款 2 驱逐不变量的措辞** | **须改写**(§四) | `docs/academic/cache-semantics.md:25,43` |

**唯一需要实质改写的条款 = 条款 2**;其余六条与全部既有映射结论**不受影响**。
