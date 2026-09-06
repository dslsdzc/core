# 存储语义总览:缓存 → 存在结构 → 经典映射

> 定位:受众 = 维护者/贡献者;状态 = active。
> 本文件是存储语义三层结构的**导航总览**——细节各归其位:条款权威 = cache-semantics.md;IR 载体 = existence-structure.md;经典映射 = region-model.md。
> 分层:三层映射链(图 → 格 → 编码)中「格」层的内容;术语权威见 docs/design/glossary.md。

---

## 一、三份文档的分工

| 文档 | 内容 | 谁读 |
|---|---|---|
| [cache-semantics.md](../../academic/cache-semantics.md) | 缓存语义七条(权威条款)+ 细读 + 范式映射表推论 | 验证器实现者、所有内存讨论的起点 |
| [existence-structure.md](existence-structure.md) | v6 存在结构:ENT/NOD/REG 如何承载七条(语义视角) | ccr_io/分配器/验证器实现者 |
| [region-model.md](region-model.md) | 经典映射:图锚定区域/Arena/字节权限/逃逸规则 | 内存管理实现者 |
| 本文件 | 三层关系、阅读路径、关联 | 所有读者(入口) |

## 二、一张图看懂三层

```
语义本体(cache-semantics.md)        存在结构(existence-structure.md)      经典映射(region-model.md)
  条款 1-7:缓存语义                    ENT:条目(变量 × 版本 × 区间)         区域/Arena:bump 分配
  值 = 配方(条款 1)                    NOD:配方(图事件)                    字节权限:Freeable > ...
  驱逐/再生(条款 2/3)                  REG:存在区间锚定                    逃逸规则:outlives 判定
  版本化(条款 5)                      共存判定:sweep 不落盘                布局/放置:layout()/alloc_at
        │                                    │                                  │
        └────────── 条款 7:映射实例正确性 = 保持 1-6 ─────────────────────────────┘
```

## 三、术语定位

"内存"在仓库里有三层含义,阅读时先判定语境(详见 glossary):

| 术语 | 含义 | 文档 |
|---|---|---|
| 物理内存 | 硬件(DRAM/寄存器/量子存储) | 无(硬件层) |
| 语义存储 | 缓存(范式无关本体)——条目、配方、驱逐、再生 | cache-semantics.md |
| 存在结构 | 本体在 IR 中的编码——ENT/NOD/REG | existence-structure.md |
| 映射 | 字节寻址、区域、Arena | region-model.md |
| 格 | 三层链第二层 = 中间存在空间(本组文档整体);「格(Lattice)代数」= 映射参数,见 archive/memory-model-capability-lattice.md §4.4 | 本组 |

## 四、相关文档

- 寄存器分配 = 缓存语义的映射实例:docs/design/regalloc-cache-mapping.md(判定四条)
- 指针模型(provenance 三 pass):docs/design/pointer-model.md
- 控制流 region(与内存"区域"区分):execution-model.md §二、existence-structure.md REG
- 术语表:docs/design/glossary.md §二(三层映射)/§四(缓存语义术语)
- 归档讨论:docs/archive/memory-model-capability-lattice.md(v1-v4 备忘)
