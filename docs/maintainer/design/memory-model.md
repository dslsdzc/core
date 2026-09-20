# 存储语义总览:存在格 → 存在结构 → 经典映射

> 定位:受众 = 维护者/贡献者;状态 = active。
> 本文件是存储语义三层结构的**导航总览**——细节各归其位:**层定义 = materialization-space.md**(存在格 / Materialization Space);条款权威 = cache-semantics.md;IR 载体 = existence-structure.md;经典映射 = region-model.md。
> 分层:三层映射链(图 → 格 → 编码)中「格」层的内容;术语权威见 docs/glossary.md。
> **2026-09-20 层定义修订**(ADR-0021):「格 = 缓存语义」降级为特例——格层本体 = **存在格**,缓存是该层的一类映射实例。本文各处的框定词已同步。

---

## 一、三份文档的分工

| 文档 | 内容 | 谁读 |
|---|---|---|
| [materialization-space.md](materialization-space.md) | **层定义**:存在格 / Materialization Space——格层回答的四问、`Semantic Entry → Materialization`、七字段(recipe/identity/version/authority/location/persistence/replicability)、归类表、不变量改写 | 所有内存讨论的起点;验证器实现者 |
| [cache-semantics.md](../../academic/cache-semantics.md) | 条款 1–7(权威条款)+ 细读 + 范式映射表推论——**缓存映射 = 该层最直接的一类实例,不是层本体** | 验证器实现者 |
| [existence-structure.md](existence-structure.md) | v6 存在结构:ENT/NOD/REG 如何承载条款(语义视角) | ccr_io/分配器/验证器实现者 |
| [region-model.md](region-model.md) | 经典映射:图锚定区域/Arena/字节权限/逃逸规则 | 内存管理实现者 |
| 本文件 | 三层关系、阅读路径、关联 | 所有读者(入口) |

## 二、一张图看懂三层

```
层定义 = 存在格                     存在结构(existence-structure.md)      经典映射(region-model.md)
(materialization-space.md)         ENT:条目(变量 × 版本 × 区间)         区域/Arena:bump 分配
  四问:合法/共存/同一/保持语义        NOD:配方(图事件)                    字节权限:Freeable > ...
  七字段:recipe/identity/version…    REG:存在区间锚定                    逃逸规则:outlives 判定
  条款 1-7(cache-semantics.md)      共存判定:sweep 不落盘                布局/放置:layout()/alloc_at
        │                                    │                                  │
        └────────── 条款 7:映射实例正确性 = 保持 1-6 ─────────────────────────────┘
```

> **层 vs 实例**:上表左列 = 存在格本体;**缓存语义是这层最直接的一类映射实例**
> (值 = 配方 / 驱逐不变量 / 再生等价),但层不等同于它——边界输入、MMIO、线性资源等
> 形态同属该层而不满足缓存假设,见 materialization-space.md §三。

## 三、术语定位

"内存"在仓库里有三层含义,阅读时先判定语境(详见 glossary):

| 术语 | 含义 | 文档 |
|---|---|---|
| 物理内存 | 硬件(DRAM/寄存器/量子存储) | 无(硬件层) |
| 语义存储 | **存在格**(范式无关本体)——物化、配方、共存、驱逐、再生 | materialization-space.md |
| 缓存语义 | 上述本体**最直接的一类映射实例**(recipe=yes / replicable=yes / evictable=yes)——不是本体的名字 | cache-semantics.md |
| 存在结构 | 本体在 IR 中的编码——ENT/NOD/REG | existence-structure.md |
| 映射 | 字节寻址、区域、Arena | region-model.md |
| 格 | 三层链第二层 = 中间存在空间(本组文档整体);「格(Lattice)代数」= 映射参数,见 archive/memory-model-capability-lattice.md §4.4 | 本组 |

## 四、相关文档

- 寄存器分配 = 缓存语义的映射实例:docs/maintainer/design/regalloc-cache-mapping.md(判定四条)
- 指针模型(provenance 三 pass):docs/maintainer/design/pointer-model.md
- 控制流 region(与内存"区域"区分):execution-model.md §二、existence-structure.md REG
- 术语表:docs/glossary.md §二(三层映射)/§四(存在格与缓存映射术语)
- 归档讨论:docs/archive/memory-model-capability-lattice.md(v1-v4 备忘)
