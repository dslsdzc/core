# ADR-0021: 格层本体 = 存在格(Materialization / Existence Space)——缓存降为该层一类映射实例

- 日期:2026-09-20
- 状态:accepted
- 决策者:DslsDZC

## 背景

ADR-0006(2026-08-15)把存储语义本体定为**缓存语义七条**,并沿用至今。维护者 2026-09-20 指出:「格 = 缓存」若当成本体定义**太窄**——「缓存」一词偷偷带进六个假设:

1. 有一个原始/权威值
2. 可以复制
3. 可以驱逐
4. 可以重新物化
5. 通常存在 backing store
6. 不同副本原则上表示同一个值

这六条在经典 CPU/GPU 内存、寄存器分配、异构 residency 上非常好用,但一批形态落在同一层内而**不满足**它们:MMIO 读、随机数、外部输入、一次性 token、线性资源、事务临时状态、分布式唯一 authority。把「存在」定义成「被缓存」,**会让未来的新范式不得不伪装成缓存系统**。

原文关键句:「'缓存'这个词都可以降级,不再作为整个层的总名字。最核心的抽象应该是:**存在、物化、等价与可恢复性**。这比 Cache 更一般。」

## 决策

- **格层本体 = 存在格 / Materialization Space**;格层回答四问:哪些 materialization 合法 · 哪些可共存 · 哪些代表同一 Entry/version · 哪些转换保持语义。
- **核心对象从 `CacheEntry` 换成 `Semantic Entry → Materialization`**:一条 Entry 可有多份物化,也可暂无物化。
- **缓存语义 = 该层的一类映射实例**(最直接实现条款 1–7 的那一类),**不是本体的名字**。同理,寄存器/内存/持久/线性资源/未来范式各是其他实例。
- **物化的字段模型(七字段)**:`recipe · identity · version · authority · location · persistence · replicability`。
- **条款 1–7 内容不变**(条款 2 的适用范围显式收窄到 `recipe = recomputable` 的条目),并新增 **2′** 把条款 4b 从「例外」并入同一条判据:

  ```
  Evictable(x)  ⟺  Recoverable(x) ∨ PreserveRequiredState(x)
  ```

  判不出归属 ⇒ **不可驱逐**(fail-closed)。
- **cache policy(LRU / write-back / write-through / prefetch / residency)不属于格层**,归 mapper。
- **层定义详版** = docs/maintainer/design/materialization-space.md(四问 / 七字段 / 归类表 / 划界 / 与实现距离)。

## 后果

**正面**

- 缓存/寄存器/residency 的**既有设计全部保留**——只是从「cache 是本体」改成「cache 是一个非常重要的特例」。
- 曾被迫当「缓存特例」的形态(MMIO/线性资源/事务态/分布式权威)获得一等位置;其中三类卡在**缓存之外的另外三根轴**上(使用义务 / 可见性义务 / 权威的协商性),本修订把它们显式登记出来而不是掩盖。
- 条款 4b 从「规则 + 例外」变成一条判据的两支,消除「按配方案别分档」的实现歧义——不分档就会把无配方条目实现成「可丢」,**那是静默语义破坏**。

**负面 / 待办**

- 术语迁移面广(约 46 个文档的框定词),须逐处判「宣布权威」还是「引用条款」。**plans/specs 面(历史设计稿)不动**。
- **实现面存在距离**:`recipe` 字段(ENT flags bit0)**位就位但语义未实现**(恒 0、零生产者、零消费者);`authority`/`persistence`/`replicability` 无实现对应物。本次只改文档,不改行为。
- `.ccr` 若日后为七字段加段,须与已有两个 tag 9+ 主张者(驱逐标注段 / 证书段)对齐,并 bump `CCR_VERSION`。**本次修订不需要加段**(七字段中三个枚举小值可复用 ENT flags 空闲位,其余各有 4B 槽)。

## 关联

- **层定义详版**:docs/maintainer/design/materialization-space.md
- 条款权威(内容不变,框定词已同步):docs/academic/cache-semantics.md
- 总览:docs/maintainer/design/memory-model.md;载体:docs/maintainer/design/existence-structure.md;经典映射:docs/maintainer/design/region-model.md;寄存器映射:docs/maintainer/design/regalloc-cache-mapping.md
- 被取代:ADR-0006(缓存语义 = 存储语义本体);相关:ADR-0005(v4 分层——其「层规则 = 缓存语义七条」的框定词随之收窄,条款数不变)、ADR-0020(.cir/.ccr 双形态)、ADR-0002(.ccr 段表)
- 设计输入:维护者原话逐字稿 `/tmp/briefs/materialization-space-raw.md`
