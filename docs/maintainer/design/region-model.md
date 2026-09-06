# 图锚定区域:缓存语义的经典映射(区域/Arena/权限)

> 定位:受众 = 维护者/贡献者(内存管理实现与验证);状态 = active(arena 层已实现;区域机制部分设计态,状态见 §六)。
> 本文件 = 缓存语义(权威 = docs/design/cache-semantics.md)在经典字节硬件上的**映射实例**详细设计——正确性标准 = 保持七条条款的可观测语义(条款 7)。
> 设计谱系:2026-07-28 多 Arena(已实现,分配器面)→ 2026-08-13 图锚定区域(语义面升级,本文档);设计依据 specs 见 §七。

---

## 一、方案概述

Core 采用**图锚定区域**的统一内存管理:区域(Region)锚定在 HDFG 上——**区域是子图节点的字节域**,不是词法作用域的影子。堆按 HDFG 子图划分独立区域,区域内线性指针碰撞分配(bump allocation),回收 = 游标重置(格式化清空)。

传统区域内存管理(Tofte-Talpin 区域栈、Cyclone、Verona)锚定词法作用域(LIFO 嵌套);Core 的执行模型是 HDFG,区域与图同构——这是与经典区域模型的分野,也是非 LIFO 生命周期(go/flow)可行的原因。

不可放弃的两个核心价值:

1. **无碎片**——静态已知大小的分配路径保持纯 bump,零碎片
2. **动态模式下工程可控的极低碎片**——动态大小分配路径走分档子区域,浪费上界由 size class 表决定(档位越细上界越低:pow2 档约 50%,细分档约 12.5%)

长期运行服务的内存占用上限由并发区域数量决定,天然无 GC 停顿。

---

## 二、设计动机(为什么区域)

| 方案 | 问题 |
|---|---|
| 手动 malloc/free | 悬挂指针、双重释放、内存泄漏 |
| 引用计数(RC) | 循环引用、原子操作开销、cache miss 链式更新 |
| 跟踪式 GC | 停顿不可预测、内存开销不确定、不适合硬实时 |
| RAII + 所有权(Rust) | 静态正确,但复杂数据结构需精细设计借用关系,运行期开销 |

区域方案优势:分配 O(1)(指针碰撞)、回收 O(1)(整体重置)、区域内无碎片、可预测(无 GC 停顿)、cache 友好(同子图数据同区域,空间局部性好)。

论文依据:Tofte & Talpin 区域推断(POPL'94,泄漏弱点需显式提前释放)、Gay & Aiken 显式区域(PLDI'98,提前释放工程可用)、Verona/snmalloc(Oopsla'24,size class 分档)、CompCert v2(每字节权限层 = 经典映射的权限面)。细节见 graph-anchored-regions-design。

---

## 三、区域模型

### 3.1 区域与子图策略

| 子图类型 | 区域策略 | 说明 |
|---|---|---|
| DAG(函数/分支/for) | 栈式区域 | 函数入口创建、出口回收,与调用深度同步 |
| 静态循环(loop) | 固定区域 | 循环前分配、结束后回收,容量按循环不变量预计算 |
| Flow | 独立区域 | 每次激活独立区域;并发 flow 各自独立 |
| Go | 独立区域 | 每 goroutine 独立区域(G 的 arena),退出整体回收 |
| Yield/Recv | 消息区域 | 跨 flow 数据在接收端区域重新分配 |

区域可嵌套:子图在父区域内建子区域,子区域回收不影响父区域。

### 3.2 三个推论(与词法锚定模型的分野)

- **推论 A:生命周期 = 图活性,不是 LIFO**。RegionCheck 的 cur_seq < exit_seq 判定就是图版本的生命周期定义。天然支持 flow/go 的独立区域(区域栈做不到非 LIFO),也天然给出跨区域引用合法性的判据(outlives 的图形式)。
- **推论 B:区域操作沿图边**。区域不仅嵌套(树),还能沿 HDFG 边操作:
  - split:一块字节沿边划给子消费者(字节块独立回收;子区域有自己的游标与重置点)
  - merge:汇合点两个子区域的数据汇入(拷贝或区域合并)
  - share:分叉点一个区域被多个消费者只读共享(共享者必须 outlive 引用)
- **推论 C:每字节归属 = 图的 provenance 边**。"字节序列 + 宽度 + 边界"与类型无关——provenance(归属)、offset(偏移)、alloc_size 是图上本有的信息(缓存条款 6 的经典视图)。

> 术语注意:dataflow 的「region」(控制流嵌套,见 execution-model.md §二与 existence-structure.md REG 段)与本文的「区域」(内存字节域)不同。v6 REG 段 first_ent/last_ent 提供"子图边界 = 存在域边界"的直接查询——区域机制在 IR 层的锚点。

### 3.3 逃逸规则(2026-08-13 修订)

区域方案的核心前提:子图内分配的引用不会逃逸到子图外——编译器静态分析保证:

1. **向下逃逸禁止**:区域 A 内分配的对象不能作为参数传给生命周期比 A 长的子图
2. **向上逃逸禁止**:区域 A 内分配的对象不能作为返回值给生命周期比 A 长的调用者
3. **全局逃逸禁止**:区域 A 内分配的对象不能赋值给全局变量
4. **跨区域引用:outlives 顺序判定**(修订)——区域 A 的指针可以指向区域 B 的对象,当且仅当 B 的存活区间 ⊇ 引用的使用区间(RegionCheck 判定)。不再一刀切禁止

例外(图边界):编译器无法追踪 provenance 的入口(外部地址、FFI 返回值、inline asm)走 `unsafe`——语义是"标注图边界入口"(进入图内编译器重新获得追踪权),不是"关掉检查"。

---

## 四、分配器面:Arena(已实现)

2026-07-28 的多 Arena 设计原样继承,作为分配器面实现。概念关系:

| 语义面(区域) | 分配器面(Arena) |
|---|---|
| 区域(Region) | Arena slot |
| 子区域 split | 子图嵌套 arena / 分档子分配器 |
| 图活性生命周期 | arena_new / arena_reset 插桩(IR_ARENA_NEW=32 / IR_ARENA_RESET=33) |
| 策略推导 | 大小预计算(IR 层) |

实现要点(已落地):
- stdlib arena.cr 完整生命周期(init/new/reset)、动态元数据、free list、嵌套
- IR 子图绑定:函数/loop/for/unsafe 自动 arena lifecycle + 编译期大小预计算(ir_gen.cr)
- ELF 后端双路径 alloc:arena 感知(g_current_arena 检查)+ 全局 bump 回退;mmap 堆扩展(BSS 打满自动 mmap)
- emit_alloc_body 零初始化 + 链式扩容

运行时:每区域单线程访问,bump pointer 无需原子操作(无锁分配);go 创建独立区域(G 的 arena),返回值拷贝到父区域;区域池制——活跃区域数 = 当前并发子图数,上限 = MAX_CONCURRENCY,耗尽时新 go/flow 阻塞等待;无 GC。

---

## 五、字节权限层与用户面

### 5.1 字节权限层(经典投影的权限面)

经典映射 = 图 + 字节权限层(CompCert v2):权限层不是语义本体,是缓存语义在字节寻址机器上的权限投影(条款 7)。每字节权限序:**Freeable > Writable > Readable > Nonempty > Empty**。

- 区域树 = 图的子图结构;布局元数据、ALLOC_AT 边界、outlives 结论全部从图导出——验证器消费图即消费全部内存语义

### 5.2 布局与放置(用户面,零管理负担)

| 事项 | 谁做 |
|---|---|
| 区域划分/生命周期 | 图活性推导(子图边界即区域) |
| 回收时机(指定回收) | 图分析生成回收点(IR 层)——推断在编译器内部,用户看不到 |
| 碎片策略 / size class | 图分析推导分配策略 |
| 跨区域合法性 | RegionCheck 自动判定 |
| 所有验证 | 三点 pass 自动 |

用户只表达两件只有用户自己知道的事实:

```core
// 1. 布局声明(例外入口)——默认布局全自动(字段顺序 + 自然对齐),用户不写任何东西;
//    layout(...) 仅当默认布局不合用时:packed(FFI)、强制对齐、硬件结构
struct PackedHeader layout(packed, align(4)) {
    a: u8,       // 偏移 0
    b: u32,      // 偏移 4
    c: u16,      // 偏移 8
}

// 2. 放置声明——地址是物理事实,只有用户知道;声明式进图,之后全图追踪
mmio := alloc_at(0x7fff0000, 4096, align(4096));
```

- 不提供显式区域/回收语法(YAGNI)
- 0x 字面量仍是 unsafe 外部入口;alloc_at 是声明式进图(获得 provenance 的节点)——声明是唯一信任点,之后全图追踪

---

## 六、设计状态与差距

**已实现**:
- 多 Arena 模型(2026-07-28):stdlib arena + IR 子图绑定 + ELF 双路径 + mmap 扩展(§四)
- 三点 pass(provenance/region/bounds,与 pointer-model 共享)

**设计态(M1-M3 推进,以计划为准)**:
- split/merge/share 沿图边操作、IR 层回收点生成(自动 early deallocation)
- size class 分档策略推导(动态路径碎片上界)
- 字节权限层消费(验证器侧)

**待解决问题**:
- 区域级空间浪费(小分配占大区域;动态区域大小调整——设计已定分档,待实现)
- 逃逸分析精度:函数指针/接口间接逃逸、条件性逃逸、RawRef 与 unsafe 交互——需验证
- 区域复用清零(敏感数据/跨安全边界,部署配置控制,非默认)

---

## 七、关联

- 语义本体:docs/design/cache-semantics.md(七条,条款 7 = 本方案正确性标准)
- IR 锚点:docs/design/existence-structure.md(REG first_ent/last_ent)
- 指针模型:docs/design/pointer-model.md(provenance 三 pass、RegionCheck)
- 并发衔接:execution-model.md §四(每 G arena 生命周期)
- 设计依据:docs/superpowers/specs/2026-08-13-graph-anchored-regions-design.md、2026-07-28-arena-model-design.md
- 术语索引:docs/design/glossary.md
