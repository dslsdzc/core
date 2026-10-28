# 寄存器分配：缓存语义的映射实例

寄存器分配是缓存语义在编码层的一个映射实例。缓存语义的规则以 `docs/academic/cache-semantics.md` 为准；层定义见 `docs/maintainer/design/materialization-space.md`；存在区间的表示见 `docs/maintainer/design/existence-structure.md`。

设计决策记录见 `docs/superpowers/specs/2026-08-27-regalloc-cache-mapping-design.md`。分配器的逻辑契约见 `docs/maintainer/design/regalloc-consistency.md` 的 v6 分支。

## 术语

| 术语 | 含义 |
|---|---|
| 条目 | IR 变量的一个版本。每次赋值产生新版本和新条目；v6 用 ENT 记录表示 |
| 生成方法（recipe） | 条目值的产生方式，由产生它的图节点和输入边组成；v6 用 NOD 表示 |
| 移除（eviction） | 丢弃存储内容，保留生成方法 |
| 重算（regeneration） | 重新执行生成方法，产生可观测等价的值 |
| home | 条目的持久位置。经典映射是栈槽；v6 用 ENT 的 home 字段表示 |
| 存在区间 | 条目在图层上的有效区间，等于图活性；v6 用 ENT 的 `live_start` 和 `live_end` 表示，坐标是 NOD id |
| 共存 | 两个条目的存在区间相交。共存是对称关系，没有传递性；v6 由 sweep 推导，不写入文件 |
| 寄存器映射实例 | 寄存器文件作为缓存层，home 作为栈槽，见缓存语义规则 7 |

## 映射实例

寄存器分配与区域、arena、字节权限属于同一类，是格层到编码层的映射实例：

```text
图（HDFG）    关系空间：值流、生成方法、图活性
格（存在）    条目存在：版本、共存、移除（存在格本体；v6 用 ENT 编码）
编码（物理）  映射实例：寄存器（缓存层）、栈槽（home）、字节
```

由此得到三个结论：

- CFG 系算法（线性扫描、图着色、SSA 弦图）是线性化后的特例，不进入语义本体。
- 正确性对全部可能执行陈述，不对某一条线性化路径陈述。
- 范式映射表就是映射正确性定理表。寄存器实例是其中一行，与字节内存行同构，证明缓存语义包含该实现。

## 语义基础

语义基础是缓存语义规则 1 到 7，其中最重要的是移除不变量：

移除任意条目的存储内容不改变可观测语义。形式化写作 `⟦G ∖ storage(e)⟧ = ⟦G⟧`。

分配器选择寄存器还是栈、保留多久，属于放置和替换策略。算法本身不参与证明，语义保持不依赖具体的贪心选择。生成器和验证器分离，VeriLocc 是同类先例。

判定和定理只在关系层面陈述。共存没有传递性，这是最弱的理论，对一切格成立。

## 对象与 v6 表示

| 对象 | 定义 | v6 表示 |
|---|---|---|
| 条目 | IR 变量版本，每次定值切分新版本 | ENT 记录，键为 `(var_id, version)` |
| 生成方法 | 产生节点加输入边 | NOD 的 `def_nod` |
| 存在区间 | 图活性的有效区间 | ENT 的 `live_start` 和 `live_end`，坐标是 NOD id |
| 共存 | 存在区间相交 | 不写入文件，由 sweep 推导，见 `existence-structure.md` 第 6 节 |
| home | 栈槽 | ENT 的 home 字段，由分配器回填；`-1` 表示寄存器候选 |

无方法条目是边界条目或图内不可重算的条目，规则见缓存语义规则 4 和 4b。无方法条目必须有 home，移除前必须写回，不能按普通条目枚举。v6 用 ENT 的 `flags` bit0 表示无方法。

### 移除前先查生成方法

这条要求来自规则 4b 的义务，不是新增规定。4b 对无方法条目给出的是义务：存储内容必须保留或合法转移，不能重算。寄存器文件只是一份物化结果。如果把存储位置整体当作纯优化处理，不按生成方法分档，实现就会把不可重算的条目当成可丢弃，在不报错的情况下破坏语义。

检查规则与规则 2′ 同形：

```text
Evictable(x)  ⟺  Recoverable(x) ∨ PreserveRequiredState(x)

recipe = recomputable   => 可以移除；需要时重算，没有额外义务
recipe = unrecomputable => 移除前必须已保留存储内容或完成合法转移
                           （写回 home 或重指身份），不能按可重算处理
recipe 无法判定         => 不可移除（失败关闭）
```

“分配算法不参与证明”这一条只在 `recipe = recomputable` 的条目上成立。对无方法条目，放置和移除不是自由策略，它受 4b 义务约束，必须由判定拦截，见第 4 节规则 3。

实现状态：截至 2026-09-20，这个分档还没有实现，ENT 的 `flags` bit0 恒为 0。两个写侧都硬编码，见 `materialization-space.md` 第 7.1 节，因此当前没有任何条目被标记为无方法，判定也无从分档。这不是现存缺陷，因为边界和执行标注还没有进入 `.ccr`。生产者实现时必须和本节同阶段完成，否则这类条目一旦进入 IR 就会在不报错的情况下被丢弃。

## 判定：一致性四条

寄存器映射实例合法，等价于下面四条一致性判定全部成立。四条判定都可判定、都是局部判定，并且只操作位置、生成方法和存在区间，不读取值内容。

1. 共存互斥：每个时刻每个寄存器至多存放一个条目的存储内容。共存的条目必须放在不同寄存器。
2. 读点无陈旧：读到的存储内容与条目当前版本对齐，见规则 5。
3. 移除配对：寄存器被释放时存储内容不能丢，按生成方法分档：
   - `recomputable`：写回 home，或者按生成方法重算。
   - `unrecomputable`：必须保留存储内容或完成合法转移，不能按可重算处理。
   - 无法判定：不可移除。
4. 调用点失效契约：调用点是缓存失效边界。caller-saved 寄存器失效，存储内容回到 home；callee-saved 寄存器保留。ABI 就是缓存保留契约。

正确性由判定保证，与分配算法无关。

判定有两个应用位置：

1. 规约契约：`.cr` 内联规约，走 `spec-design` 体系的翻译桥和 CIC 内核，健全性由内核保证。旧格式已经废弃，见 `adr/adr-0001`。
2. 编译器自检：分配器的逻辑契约在 `docs/maintainer/design/regalloc-consistency.md` 的 v6 分支，运行自检在 `opt.cr` 一侧。

## 分配器：上下文贪心

分配算法定为上下文贪心（CAG），是在存在结构上的 First Fit 贪心扫描。上下文包括共存关系、重算成本、区域生命周期、调用点和使用次数。CAG 是唯一分配算法，第 4 节的判定不依赖算法选择。

```text
对每个函数：
1. 构建条目表：变量和版本，按定值点切分。IR_STORE 的例外见 existence-structure.md 第三节。
   得到存在区间 [live_start, live_end]。区间按区域嵌套顺序计算，不使用 CFG 数据流不动点。
2. 遍历顺序：区域嵌套的拓扑序。CFG 退化时等于指令序，也就是经典线性扫描。
3. 活跃集合：当前点存在区间覆盖的条目，由 sweep 维护。
4. 分配：对每个新活跃条目 e：
     空闲寄存器 = 寄存器全集减去活跃集合已占用的寄存器
     有空闲 -> e 取编号最小的空闲寄存器（First Fit）
     没有空闲 -> 选择移除对象 e′，比较
        成本 = 区域深度 × 使用次数 ×（写回成本 + 装载成本）
               与生成方法重算成本的较小者
        选择成本较低的做法：写回 home（spill）或直接重算（remat）
        e 占用释放出的寄存器
5. 调用点：活跃的 caller-saved 条目写回 home，这是缓存失效契约；callee-saved 条目保留
6. 输出：条目到位置的映射，以及移除和装载点表，写入 g_opt_meta 或格形态
```

算法来源是 Poletto-Sarkar 线性扫描的存在结构版本。溢写采用成本感知的移除策略，包含 second-chance 变体和重算。调用点失效对应解锁 caller-saved 寄存器。

复杂度约为 `O(V+E)`。数学结论：CFG 退化情形等于区间序 First Fit，是最优的。Dilworth 定理给出最小寄存器数等于共存偏序的 width；区间图是完美图。非区间序时贪心是近似算法，最优性本质上是 NP-hard。上下文信息可以提高分配质量，验证不依赖它。

## 数学依据

| 结果 | 内容 |
|---|---|
| Dilworth 定理和区间序 | 链分解（chain decomposition）对应分配；width 是最小寄存器数；区间序 First Fit 在退化情形下最优 |
| PCM 和资源代数（Verus、Iris） | 寄存器是可分离资源，可作为验证的可选代数层；第 4 节的判定已经足够 |
| SPL 语法分解（Cai 和 Goharshady，2024 到 2026） | series-parallel 图带溢写的最小代价分配可以多项式时间精确求解，说明 CFG 系是格分配的线性化特例；DP 表可以作为最优性证书的形态参考 |

## 实现状态

| 分支 | `alloc_registers` 现状 | 契约和自检 |
|---|---|---|
| develop（基线） | 朴素线性扫描：first/last 区间，5 个 callee-saved 寄存器，没有溢写；负编码寄存器，由 g2_slot 机械翻译 | 无 |
| lattice-ir-v6（推进中） | CAG 重写，修复 rc=0 的根因，加入真实寄存器分配和 watchdog 验证 | `docs/maintainer/design/regalloc-consistency.md` 记录机制、`opt.cr` 映射和三层正确性定位；verify 运行自检 |

设计与代码的对应：

| 概念 | 代码 |
|---|---|
| 寄存器映射 | `g_opt_meta` 的 `(var_idx, reg)` 对，是判定的检查对象 |
| home 槽共享 | `pass_stack_share`，共存互斥的条目共享 home，条件是不能同时存在 |
| 存在区间 | v6 使用 ENT 的 `live_start` 和 `live_end`；develop 使用变量的 first/last 和 RegionCheck 机制 |
| 物理位置懒查询 | `arch/linux/ld/instr.cr` 的 `g2_slot`，是判定的接入位置 |

## 范围边界

- 不做 SSA 转换。版本化语义已经存在，条目就是版本。
- 不做图着色机制，不做 SPL 分解实现。这些属于 CFG 系，方向已经放弃。
- 不做格代数承诺。判定在关系层面陈述，格是映射参数，将来再挂接。
- 做四件事：确定共存关系、给出判定规约、实现 CAG、加入 checker 自检。

## 关联

- 设计决策：`docs/superpowers/specs/2026-08-27-regalloc-cache-mapping-design.md`
- 规则来源：`docs/academic/cache-semantics.md`
- v6 表示：`docs/maintainer/design/existence-structure.md`
- 背景资料：`docs/archive/memory-model-capability-lattice.md`
- RegionCheck 和存在区间实现：`docs/maintainer/design/pointer-model.md`
- 规约体系：`docs/maintainer/design/spec-design.md`
- 执行标注空间：`docs/maintainer/design/execution-annotation-space.md`
- 契约文档：`docs/maintainer/design/regalloc-consistency.md` 的 v6 分支
