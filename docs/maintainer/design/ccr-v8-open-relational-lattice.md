# .ccr V8：实体、关系与开放关系域

## 概述

`.ccr` V8 用一个足够弱、开放的结构表达 HDFG 及其分析产生的关系。它只记录关系，不推导关系，不证明关系，也不求不动点。

设计状态：定稿，尚未实现。现状依据、从 v1 到 v2 的逐条删除记录和待裁事项见 `docs/superpowers/implementation/2026-09-23-ccr-v8-revision-audit.md`。

抽象形式：

```text
CCR = (E, D, R)
```

`E` 是开放实体引用集合，`D` 是开放关系域集合，`R` 是建立在实体上的关系实例集合。

文件布局有四节：

```text
Entities
Relation Domains
Relations
Relation Metadata
```

`Relation Metadata` 是 `R` 的附属部分，不是第四个语义集合。

## 目标

`.ccr` 必须满足五条：

1. 能合并多个来源的关系。
2. 能查询。
3. 能验证结构合法性。
4. 能被不同使用方读取。
5. 不封死未来的关系域。

`.ccr` 不负责五件事：

- 怎么推导关系。
- 怎么证明关系。
- 怎么求不动点。
- 怎么尝试 mapping。
- 怎么表达假设。

这五件事分别属于分析器、规约系统、求解器、mapper 和规约上下文。`.ccr` 只负责把结果表示出来。

## 反目标

`.ccr` 不能变成 Core 里的第四门通用逻辑语言。

如果为了“什么都能表达”而引入符号、项、规则、约束、不动点、高阶逻辑、证明、查询语言、上下文、模块和代数，`.ccr` 就会重新长成一门逻辑语言。Core 已经有 HDFG 表达程序语义，有规约系统表达命题和证明，有 Core 语言表达通用编程。`.ccr` 再成为一门完整语言，是糟糕的工程选择。

新增概念时，只要它让 `.ccr` 更像一门语言而不是一份记录，就违反这个反目标。

## EntityRef

EntityRef 是稳定身份。形态示例：

```text
@hdfg.node.17
@hdfg.value.42
@target.reg.r12
@deploy.gpu0
```

Core 不理解这些 ID 指向什么，只保证同一个 ID 表示同一个被引用对象。EntityKind 不做封闭枚举，最多允许开放 tag，例如 `hdfg.value`、`target.register`、`foo.bar.whatever`。tag 是工具提示，不是 Core 的本体分类。

字段：

| 字段 | 含义 | 约束 |
|---|---|---|
| `id` | 稳定身份 | Core 只认相等性，不解析，不比较大小 |
| `tag` | 开放点分提示 | 可选，开放字符串，Core 不要求解释 |
| `name_ni` | 字符串池索引 | 编码细节，不定义语义 |

现行 `.ccr` 没有 entity 段。最接近的是 `STR` 字符串池和 `SYM` 编译器内部命名。`SYM` 不能读成 EntityRef。

## Relation

关系的基本形态是 `R(a₁, a₂, …, aₙ)`，可以带一个可选值 `R(a₁, …, aₙ) = v`。

示例：

```text
depends(A, B)
coexists(x, y)
locatedAt(x, r12)
latency(A, B) = [2, 7]
permission(x) = Writable
```

Core 不特殊区分 fact、mapping、analysis、storage 和 time，它们都是关系。

通用项代数已经删除。值直接挂在关系上：

```text
relation offset(x) = 16
relation interval(eventA, eventB) = [0, 2ms]
relation version(x) = 3
```

关系域可以定义自己的 opaque 值或符号值。不需要为了理论上的无限性引入自由项代数，开放的关系集合已经足够。

字段：

| 字段 | 含义 | 约束 |
|---|---|---|
| `domain_ref` | 所属关系域 | 是否必须由域外关系决定，见未决问题 |
| `args` | 实体引用列表 | 长度等于域的 `arity`，元素是 EntityRef 或域允许的形状 |
| `value` | 可选值 | 可以缺席，缺席不等于假；形态由 `value_shape` 约束 |
| `id` | 关系 ID | 用于关系引用关系，具体形态见未决问题 |
| `metadata` | 溯源信息 | 不进入数学含义 |

关系可以有 ID，用来表达“关于关系的关系”：

```text
%r42 = depends(A, B)
preserves(mapping0, %r42)
```

这是 first-class relation identity。不实现 lambda 关系、高阶合一或对任意条件的量化。

## RelationDomain

关系域的存在有两个工程原因：

1. 防止拼写差异造出两种关系。`locatdAt(x, r12)` 和 `locatedAt(x, r12)` 如果都能自由存在，消费者无法判断它们是不是同一种关系。
2. 给消费者提供索引、反序列化和值类型所需的信息。

字段：

| 字段 | 含义 | 约束 |
|---|---|---|
| `id` | 域的稳定名 | 开放字符串，没有允许清单 |
| `version` | 域自身的版本 | 不是 `.ccr` 文件版本 |
| `arity` | 元数 | 可以是 0，表示命题式关系 |
| `argument_shape` | 实参允许的形状 | 具体形式见未决问题 |
| `value_shape` | 值的允许形状 | 必须容纳 opaque 值和符号值 |
| `optional refinement/merge` | 可选的 `⪯` 和 `⊔` | 默认缺席 |

关系域不能再塞入四类东西：

- 证明规则。
- 不动点。
- 求解器。
- 后端实现。

这四类一旦进入关系域，关系域就会重新长成 v1 的 Theory、Rule 和 Constraint。

`.ccr` 当前没有关系域概念。最接近的是 `TYPE` 和 `IFACE` 两段，它们属于 Core 的通用语义关系域。关系进入 `.ccr`，合法性由 checker 负责。

## Refinement

`.ccr` 不要求完整格。完整格要求 `a ⊔ b` 和 `a ⊓ b` 总是存在，甚至要求任意集合的上确界和下确界。工程上通常只需要：已有信息加上新分析结果，得到更精确的信息。

最弱要求是：

```text
a ⪯ b
```

表示 `b` 至少包含或细化了 `a` 表达的信息。某些域如果需要合并，再提供 `a ⊔ b`。

分层：

```text
Core 要求：      预序或偏序
域可选提供：     bottom、join、meet、top、完整格
```

Core 不要求 `⊤`，也不要求 `⊥`。例如 `D = ℕ` 在通常序下没有最大元，如果 Core 要求 `⊤`，就会把这类域排除掉。

`⪯` 和 `⊔` 都是可选的。域没有声明时，查询 `⪯` 或 `⊔` 返回“未声明”，不能临时合成一个偏序或默认取上确界。

## Relation Metadata

元数据记录关系是谁产生的、属于哪个 epoch、证据在哪里：

```text
metadata {
    producer
    epoch
    evidence_ref
}
```

元数据不进入关系的数学含义。改变或清空元数据，关系的语义判定结果不能变化。增量编译可以使用 `producer` 和 `epoch` 判断哪些旧关系需要删除。

如果某条规则读取 `producer` 或 `epoch` 并因此改变结论，元数据就泄漏进了语义，这是错误。

## Unknown 与 bottom

`unknown` 是 `.ccr` 的信息状态，不是关系域的数学 `⊥`。

| | `.ccr` 的 `unknown` | 关系域的数学 `⊥` |
|---|---|---|
| 含义 | `.ccr` 没有说过 `R(a,b)` | 域按 refinement 序存在最小元 |
| 归属 | `.ccr` 层，对任何域都成立 | 某个域，有的域有，有的域没有 |
| 存在性 | 无条件存在 | 不要求存在 |

没有关系记录不等于关系为假。`unknown` 表示没有信息。

`unknown` 也不等于 `⊥`。不能因为 `.ccr` 没有记录某条关系，就要求每个关系域都构造一个 `⊥`。

## 冲突

`.ccr` 本身不采用逻辑爆炸。

假设同时存在 `locatedAt(x, r12)` 和 `locatedAt(x, r13)`。`.ccr` 保留两条关系，不自动推出任何东西。至于这两条关系是否合法、是否是两个候选、是否表示寄存器冲突，由 `locatedAt` 的使用方或 checker 判定。

底线是：`.ccr` 不是经典定理证明器，冲突不导致任意命题成立。

## 开放关系域

`Core` 不特殊区分 fact、mapping、analysis、storage 和 time。关系域的 `id` 是开放字符串，新增域不需要修改 Core。

新增一个此前不存在的关系域时，文件版本、分节集合和 HDFG 字节都不变。这是开放性的验收方式。

开放不等于什么都能装：

- target-specific 的优化知识放在 `.coi`。
- target 本身的 capability、topology 和语义放在 Target Model。
- 其余 target-independent 的程序关系放在 `.ccr`。

Theory 降级为模块或包，只承担三个工程职能：

- 命名空间，避免域名冲突。
- schema 打包，一次导出多个关系域。
- 工具钩子，用 `checker = <identity>` 指向外部检查器。

`checker` 是外部工具的引用，不是 `.ccr` 要执行的逻辑。Core 只保存这个指称，不解析、不求值。否则 Constraint、Rule 和推理语义会重新进入 Core。

## 文件布局

| 部分 | 语义 | 内容 |
|---|---|---|
| Entities | `E` | EntityRef 集合，稳定 ID 加可选开放 tag |
| Relation Domains | `D` | 关系域声明，包括 `id`、`version`、`arity`、两个 shape 和可选 refinement |
| Relations | `R` | 关系实例，包括带值和不带值的形式 |
| Relation Metadata | `R` 的附属部分 | `producer`、`epoch`、`evidence_ref` |

文件布局只是语义的呈现。`.ccr` 不是关系的总和，只是一处记录。

## 验收

主验收：一个新的关系域入场，Core 零修改。

1. 写一个此前不存在的关系域，包括 `id`、`version`、`arity`、`argument_shape` 和 `value_shape`。
2. 用该域写关系实例，可以带值，也可以不带值。
3. 先不声明 refinement，再声明 `⪯`，再声明 `⊔`，三种情况都能接受。
4. 加载 `.ccr`，返回码正常。
5. 与入场前对比，文件版本、分节集合和 HDFG 字节不变。

反例检查：

1. 同一 `.ccr` 里写 `locatedAt(x, r12)` 和 `locatdAt(x, r12)`。后者不属于任何已声明域，必须被拒绝或产生显式诊断，不能被接受为第二条独立关系。
2. 给关系域声明证明规则、不动点、求解器或后端实现。Core 必须无法表达，不能留下非正式入口字段。
3. 给某个域写 `checker = <identity>`。Core 只保存指称。把 identity 换成指向不存在工具的字符串，加载仍应成功；如果加载失败或行为改变，说明 Core 在求值它。
4. 同时存在 `p(a)` 和一条表达其否定的关系。两条都必须保留，不能后写覆盖先写。查询一个完全无关的 `q(a)` 时，结果必须仍是 `unknown`；如果变成 `true`，说明发生了逻辑爆炸。

## 不包含

- 不做 Rule。
- 不做 Constraint 通用语言。
- 不做 μ/ν 不动点。
- 不做 Assumption。
- 不做 Query Language。查询是工具 API。
- 不做高阶逻辑、lambda 关系和高阶合一。
- 不做全局完备格。
- 不做四值冲突逻辑。
- 不做 Bridge Theory。
- 不做 Rule Dependency Graph。

## 未决问题

| # | 问题 | 影响 |
|---|---|---|
| 1 | `tag` 和 `id` 的切分：整串是 id、点分前缀兼作 tag，还是前缀是 tag、末段是 id | EntityRef 编码 |
| 2 | 关系 ID 的具体形态 | 关系引用关系 |
| 3 | 关系域是否必须声明，域外关系是否允许 | Relation 的 `domain_ref` |
| 4 | `argument_shape` 和 `value_shape` 的形式：是否引用 EntityRef 的 tag，是否闭集 | 关系域校验 |
| 5 | refinement 是预序还是偏序；`refinement` 和 `merge` 是否各需一套 | 域的可选代数 |
| 6 | 元数据是否恰好三个字段，是否可扩展 | 元数据格式 |
| 7 | 文件首行和版本号形态，文本格式还是二进制格式 | `.ccr` 文件格式 |
| 8 | 现行 `TYPE` 和 `IFACE` 段如何映射到通用语义关系域 | 实现迁移 |

## 关联

- 修订记录和现状核对：`docs/superpowers/implementation/2026-09-23-ccr-v8-revision-audit.md`
- 存在格层定义：`docs/maintainer/design/materialization-space.md`
- 优化知识格式：`docs/maintainer/design/coi-optimization-knowledge-sidecar.md`
- 执行映射：`docs/maintainer/design/execution-mapping-design.md`
- IR schema：`docs/ir-schema/coreir-schema.md`
