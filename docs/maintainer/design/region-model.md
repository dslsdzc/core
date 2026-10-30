# 图绑定区域：存在格语义的经典映射（区域/Arena/权限）

> 定位：受众 = 维护者/贡献者（内存管理实现与验证）；状态 = active（arena 层已实现；区域机制部分处于设计阶段，状态见第 6 节）。
> 本文件详细设计存在格 / Materialization Space（层定义 = docs/maintainer/design/materialization-space.md；规则来源 = docs/academic/cache-semantics.md）在经典字节硬件上的映射实例，正确性标准 = 保持规则 1–6 的可观测语义（规则 7）。
> 设计谱系：2026-07-28 多 Arena（已实现，分配器层），2026-08-13 图绑定区域（语义层升级，本文档）；设计依据见第 7 节。

---

## 一、方案概述

Core 采用图绑定区域的统一内存管理：区域（Region）绑定在 HDFG 上，区域是子图节点的字节域，不是词法作用域的对应物。堆按 HDFG 子图划分独立区域；区域内做线性指针碰撞分配（bump allocation），回收 = 游标重置（格式化清空）。

传统区域内存管理（Tofte-Talpin 区域栈、Cyclone、Verona）绑定词法作用域（LIFO 嵌套）。Core 的执行模型是 HDFG，区域与图同构，这是它与经典区域模型的区别，也是非 LIFO 生命周期（go/flow）可行的原因。

两个核心性质：

1. 无碎片，静态已知大小的分配路径保持纯 bump，零碎片
2. 动态模式下工程可控的极低碎片，动态大小分配路径走分档子区域，浪费上限由 size class 表决定（档位越细上限越低：pow2 档约 50%，细分档约 12.5%）。当前规格使用 1.25 倍步长、上限 20%，见 `docs/superpowers/specs/2026-10-28-arena-size-classes.md`

长期运行服务的内存占用上限由并发区域数量决定，因此没有 GC 停顿。

---

## 二、设计动机（区域方案）

| 方案 | 问题 |
|---|---|
| 手动 malloc/free | 悬挂指针、双重释放、内存泄漏 |
| 引用计数（RC） | 循环引用、原子操作开销、cache miss 的连续更新 |
| 跟踪式 GC | 停顿不可预测、内存开销不确定、不适合硬实时 |
| RAII + 所有权（Rust） | 静态正确，但复杂数据结构需要仔细设计借用关系，有运行期开销 |

区域方案的优势：
- 分配 O（1）（指针碰撞）
- 回收 O（1）（整体重置）
- 区域内无碎片
- 可预测（无 GC 停顿）
- cache 友好（同子图数据同区域，空间局部性好）

论文依据：Tofte & Talpin 区域推断（POPL'94，泄漏弱点需显式提前释放）、Gay & Aiken 显式区域（PLDI'98，提前释放工程可用）、Verona/snmalloc（Oopsla'24,size class 分档）、CompCert v2（每字节权限层对应经典映射的权限模型）。细节见 graph-anchored-regions-design。

---

## 三、区域模型

### 3.1 区域与子图策略

| 子图类型 | 区域策略 | 说明 |
|---|---|---|
| DAG（函数/分支/for） | 栈式区域 | 函数入口创建、出口回收，与调用深度同步 |
| 静态循环（loop） | 固定区域 | 循环前分配、结束后回收，容量按循环不变量预计算 |
| Flow | 独立区域 | 每次激活独立区域；并发 flow 各自独立 |
| Go | 独立区域 | 每 goroutine 独立区域（G 的 arena），退出整体回收 |
| Yield/Recv | 消息区域 | 跨 flow 数据在接收端区域重新分配 |

区域可嵌套：子图在父区域内建子区域，子区域回收不影响父区域。

### 3.2 三个推论（与词法绑定模型的区别）

- 推论 A：生命周期 = 图活性，不是 LIFO。RegionCheck 的 cur_seq < exit_seq 判定就是图版本的生命周期定义。因此支持 flow/go 的独立区域（区域栈做不到非 LIFO），也直接给出跨区域引用合法性的检查（outlives 的图形式）。
- 推论 B：区域操作沿图边。区域可以嵌套（树），也可以沿 HDFG 边操作：
 - split：一块字节沿边划给子消费者（字节块独立回收；子区域有自己的游标与重置点）
 - merge：汇合点两个子区域的数据汇入（拷贝或区域合并）
 - share：分叉点一个区域被多个消费者只读共享（共享者必须 outlive 引用）
- 推论 C：每字节归属 = 图的 provenance 边。“字节序列 + 宽度 + 边界”与类型无关，provenance（归属）、offset（偏移）、alloc_size 是图上本有的信息（缓存规则 6 的经典视图）。

> 术语注意：dataflow 的“region”（控制流嵌套，见 execution-model.md 第 2 节与 existence-structure.md REG 段）与本文的“区域”（内存字节域）不同。v6 REG 段 first_ent/last_ent 提供“子图边界 = 存在域边界”的直接查询，区域机制在 IR 层的依据。

### 3.3 逃逸规则（2026-08-13 修订）

区域方案的核心前提：子图内分配的引用不会逃逸到子图外，编译器静态分析保证：

1. 向下逃逸禁止：区域 A 内分配的对象不能作为参数传给生命周期比 A 长的子图
2. 向上逃逸禁止：区域 A 内分配的对象不能作为返回值给生命周期比 A 长的调用者
3. 全局逃逸禁止：区域 A 内分配的对象不能赋值给全局变量
4. 跨区域引用：outlives 顺序判定（修订），区域 A 的指针可以指向区域 B 的对象，当且仅当 B 的有效区间 ⊇ 引用的使用区间（RegionCheck 判定）。不再一律禁止

例外（图边界）：编译器无法追踪 provenance 的入口（外部地址、FFI 返回值、inline asm）走 `unsafe`，语义是“标注图边界入口”（进入图内后编译器重新获得追踪能力），不是“关闭检查”。

---

## 四、分配器层：Arena（已实现）

2026-07-28 的多 Arena 设计沿用至今，作为分配器层实现。概念关系：

| 语义层（区域） | 分配器层（Arena） |
|---|---|
| 区域（Region） | Arena slot |
| 子区域 split | 子图嵌套 arena / 分档子分配器 |
| 图活性生命周期 | arena_new / arena_reset 插模拟（IR_ARENA_NEW=32 / IR_ARENA_RESET=33） |
| 策略推导 | 大小预计算（IR 层） |

实现要点（已实现）：
- stdlib arena.cr 完整生命周期（init/new/reset）、动态元数据、arena slot free list（复用整个 slot，不是对象级 free list）、嵌套
- IR 子图绑定：函数/loop/for/unsafe 自动 arena lifecycle + 编译期大小预计算（ir_gen.cr）
- ELF 后端双路径 alloc:arena 感知(`g_current_arena` 检查）+ 全局 bump 回退；mmap 堆扩展（BSS 用满后自动 mmap）
- `emit_alloc_body` 零初始化 + 按需扩容

运行时：每区域单线程访问，`bump pointer` 无需原子操作（无锁分配）；go 创建独立区域（G 的 arena），返回值拷贝到父区域；区域池制，活跃区域数 = 当前并发子图数，上限 = `MAX_CONCURRENCY`，耗尽时新 go/flow 阻塞等待；无 GC。

---

## 五、字节权限层与用户接口

### 5.1 字节权限层（经典映射的权限部分）

经典映射 = 图 + 字节权限层（CompCert v2）：权限层不是语义本体，是缓存语义在字节寻址机器上的权限表示（规则 7）。每字节权限序：Freeable > Writable > Readable > Nonempty > Empty。

- 区域树 = 图的子图结构；布局元数据、`ALLOC_AT` 边界、`outlives` 结论全部从图导出，验证器读取图数据即可获得全部内存语义

### 5.2 布局与放置（用户接口，无需手动管理）

| 事项 | 谁做 |
|---|---|
| 区域划分/生命周期 | 图活性推导（子图边界即区域） |
| 回收时机（指定回收） | 图分析生成回收点（IR 层），推断在编译器内部，用户看不到 |
| 碎片策略 / size class | 图分析推导分配策略 |
| 跨区域合法性 | RegionCheck 自动判定 |
| 所有验证 | 四个 pass 自动 |

用户只表达两件只有用户自己知道的事实：

```core
// 1. 布局声明(例外入口)，默认布局全自动(字段顺序 + 自然对齐),用户不写任何东西;
//    layout(...) 仅当默认布局不合用时:packed(FFI)、强制对齐、硬件结构
struct PackedHeader layout(packed, align(4)):
    a: u8,       // 偏移 0
    b: u32,      // 偏移 4
    c: u16,      // 偏移 8

// 2. 放置声明，地址是物理事实,只有用户知道;声明式进图,之后全图追踪
mmio := alloc_at(0x7fff0000, 4096, align(4096))
```

- 不提供显式区域/回收语法（YAGNI）
- 0x 字面量仍是 unsafe 外部入口；`alloc_at` 是声明式进图（获得 provenance 的节点），声明是唯一信任点，之后全图追踪

---

## 六、设计状态与差距

已实现：
- 多 Arena 模型（2026-07-28）：stdlib arena + IR 子图绑定 + ELF 双路径 + mmap 扩展（第 4 节）
- size class 分档（2026-10-28 规格，2026-10-29 边界收尾）：25 档 + 大对象区；
  动态 arena 按 1MiB slot 增长，`>1MiB` 请求走独立 extent；simple/arena 共用
  Core blob；tagged BigInt、失败 trap 和解释器 parity 已覆盖
  （`tests/selfhost/test_alloc_arena_parity.py`、`test_arena_interp.py`）
- 四个 pass（provenance/region/byte permission/bounds，与 pointer-model 共享）
- 字节权限层验证器侧（2026-10-29）：`src/compiler/byte_permission.cr`，两 bit 权限格、按分配/槽位推断、`unsafe` 跳过、`cell_store` 形参写入摘要，错误码 B012
- `alloc_at` 声明式放置（2026-10-29）：`IR_ALLOC_AT`（opcode 55）+ 前端识别 + provenance/边界 + 后端地址常量；v1 限制见 pointer-model
- V2.0 IF split（2026-10-29）：无逃逸 `if` 获得子 arena，出口 reset；两阶段 IR 生成 + 保守 plan（`src/compiler/region_plan.cr`）。逃逸判定覆盖嵌套在非释放 IF 内、实际落入该子槽的 allocation
- V2.1 early clear（2026-10-30）：`IR_ARENA_CLEAR`（opcode 56）+ `arena_clear`；V2.1b 用控制邻接上的后支配集合选择 clear 点，清空并保留槽
- V2.2 merge 复制窄切片（2026-10-30）：单个常量长度标量数组存入外层局部槽；在赋值分支出口复制到父槽副本并重绑，子槽在汇合点 reset；副本大小在 IF 入口计入父槽 peak，merge IF 不进入任何 IF 子槽。同期修正 arena peak 记账：alloc 累计按当前打开子图（`g_cur_sg`）而不是高水位末项，非 split 子图关闭时把总量加到记录的 parent。`IR_STORE_INDEX_VAR` 的 DF 映射修正为 dest=值、s1=数组、s2=下标（s3 为字面量 0），避免 `arr[i]=i` 自环

设计阶段（M1-M3 推进，以计划为准）：
- V2.3 share、V2.4 清零配置；V2.2 扩展到字符串、POD 聚合、多分支汇合

待解决问题：
- 区域复用清零（敏感数据/跨安全边界，部署配置控制，非默认）；普通分配在复用时
  已通过 `_arena_zero`/`_memzero` 清零
- 逃逸分析精度：函数指针/接口间接逃逸、条件性逃逸、RawRef 与 unsafe 交互；
  具体 RegionCheck 缺口（B010 零 raise、B011 零覆盖、store/call/区域内返回逃逸、
  pts 流不敏感）见 `TODO.md` 条目 `#2026-09-20-1`
- 字节权限的持久化/运行期表示、每字节子区间尚未实现
- `alloc_at` v1 只接受编译期字面量、固定 `*int`、8 字节 cell；部署配置地址、显式元素类型、对齐的运行时落实尚未实现
- 并发区域：每 G 独立 arena 尚未实现；本轮 arena 边界设计明确不含并发

---

## 七、关联

- 层定义：docs/maintainer/design/materialization-space.md（存在格 / Materialization Space）
- 规则来源：docs/academic/cache-semantics.md（规则 1–7；规则 7 = 本方案正确性标准）
- IR 定位点：docs/maintainer/design/existence-structure.md（REG first_ent/last_ent）
- 指针模型：docs/maintainer/design/pointer-model.md（四个 pass、RegionCheck）
- 并发衔接：execution-model.md 第 4 节（每 G arena 生命周期）
- 设计依据：docs/archive/2026-08-13-graph-anchored-regions-design.md、2026-07-28-arena-model-design.md
- 术语索引：docs/glossary.md
