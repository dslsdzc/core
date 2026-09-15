# 寄存器分配:缓存语义映射实例

> 定位:受众 = 维护者(分配器/opt.cr/一致性自检);状态 = active。
> 本文是寄存器分配在 Core 架构中的正式参考文档——缓存语义(权威 = docs/academic/cache-semantics.md)的寄存器映射实例;存在区间载体 = v6 ENT(docs/maintainer/design/existence-structure.md)。
> 设计决策记录(日期/排除方向/讨论):docs/superpowers/specs/2026-08-27-regalloc-cache-mapping-design.md;分配器逻辑契约文档 = src/compiler/regalloc-consistency.cr(v6 分支)。
> 本文 2026-09 重写:v6 对齐(ENT 区间/home/sweep 共存)+ 实现状态分线(develop vs lattice-ir-v6)。

---

## 零、术语

| 术语 | 含义 |
|---|---|
| 条目(entry) | IR 变量版本(缓存语义条款 5:每次赋值 = 新版本 = 新条目;v6 载体 = ENT 记录) |
| 配方(recipe) | 条目值的产生方式 = (产生它的图节点, 输入边)(条款 1;v6 载体 = NOD) |
| 驱逐(eviction) | 丢弃存储物、保留配方(条款 2) |
| 再生(regeneration) | 重跑配方节点产生可观测等价的值(条款 3) |
| home | 条目的持久位置(经典映射 = 栈槽;v6 载体 = ENT home 字段) |
| 存在区间 | 条目在图层上的存活区间 = 图活性(v6 载体 = ENT live_start/live_end,NOD id 坐标) |
| 共存 | 两条目存在区间相交(对称、无传递性;v6 sweep 推导,不落盘) |
| 寄存器映射实例 | 寄存器文件 = 缓存层、home = 栈槽(条款 7) |

## 一、定位:分配是映射实例,不是编译器 pass

寄存器分配与区域/arena/字节权限同族,是格 → 编码的映射实例(条款 7):

```
图(HDFG)    关系空间:值流、配方、图活性
格(存在)    条目存在:版本、共存、驱逐(cache-semantics 本体;v6 ENT 编码)
编码(物理)  映射实例:寄存器(缓存层)/ 栈槽(home)/ 字节
```

推论:

- CFG 系算法(线性扫描/图着色/SSA 弦图)是**线性化退化实例**——不进入语义本体
- 正确性 **order-free**:对全部可能执行陈述,不对某条线性化路径
- 范式映射表 = 映射正确性定理表——寄存器实例是其中一行(经典行),与字节内存行同构:证明缓存语义 ⊇ 该实现

## 二、语义基座:驱逐不变量 = 语义保持定理

公理 = 缓存七条(docs/academic/cache-semantics.md)。其中:

- **驱逐不变量(条款 2)**:⟦G ∖ storage(e)⟧ = ⟦G⟧——驱逐任意条目不改变可观测语义
- 分配器放寄存器还是栈、放多久 = 放置/替换策略——**算法零证明**,语义保持不依赖具体贪心(生成器 + 验证器分离;VeriLocc 同构先例)
- **无格承诺**:判定/定理只在关系层面陈述——共存无传递性(最弱理论);对一切格成立

## 三、对象与 v6 载体

| 对象 | 定义 | v6 载体 |
|---|---|---|
| 条目 | IR 变量版本(每次定值切分新版本) | ENT 记录(var_id × version) |
| 配方 | 产生节点 + 输入边 | NOD(def_nod) |
| 存在区间 | 图活性存活区间 | ENT live_start/live_end(NOD id 坐标) |
| 共存 | 存在区间相交 | 不落盘——sweep 推导(existence-structure.md §六) |
| home | 栈槽 | ENT home(分配器回填;-1 = 寄存器候选) |

**无配方条目**(边界 + 图内不可重算,cache-semantics 条款 4/4b):必须有 home、驱逐必写回——不按范式枚举。v6 载体 = ENT flags bit0(无配方)。

## 四、判定(验证):一致性四条

「寄存器映射实例合法」= 一致性判定,全部**可判定、局部、条目泛型**(只操作位置 + 配方 + 存在,不读值内容):

1. **共存互斥**:每时刻每寄存器至多一个条目的材料(共存条目不同寄存器)
2. **读点无陈旧**:读到的材料与条目当前版本对齐(条款 5)
3. **驱逐配对**:寄存器回收(驱逐)时材料不丢——写回 home,或配方可再生(条款 3 = remat);无配方条目必写回
4. **调用点失效契约**:调用点 = 缓存失效边界——caller-saved 失效(材料归 home)、callee-saved 保留(ABI = 缓存保留契约)

**算法零证明**:正确性由判定保证,与分配算法无关。分配算法 = 上下文贪心(§五,定案)。

**落点**(双层消费同一规约):①规约契约(.cr 内联,spec-design 体系:翻译桥 → CIC 内核,健全性由内核保证;格式退役见 adr/adr-0001);②编译器内 checker 实现期自检——分配器逻辑契约文档 src/compiler/regalloc-consistency.cr(v6 分支)+ 运行自检(opt.cr 侧)。

## 五、分配器(定案):上下文贪心(CAG)

**正式名:上下文贪心**——存在结构上的 First Fit 贪心扫描。上下文 = 共存关系 + 再生成本(配方)+ region 生命周期 + 调用点 + 使用次数。定案(2026-08-27):CAG 为唯一分配算法;判定(§四)不依赖算法选择。

```
对每个函数:
1. 条目表构建:变量 × 版本(定值点切分,IR_STORE carve-out 见 existence-structure.md §三)
   → 存在区间 [live_start, live_end](图活性;region 嵌套序结构化计算,非 CFG 数据流不动点)
2. 遍历序:region 嵌套序(存在结构拓扑序)——CFG 退化时 = 指令序 = 经典线性扫描
3. 活跃集合:当前点存在区间覆盖的条目 = 共存集合(sweep 维护)
4. 分配:对每个新活跃条目 e:
     free = 寄存器全集 \ 活跃集合已占
     free 非空 → e 取最小空闲寄存器(First Fit)
     无 free → 驱逐决策:对候选驱逐者 e′ 比较
       cost = region 深度 × 使用次数 ×(写回 + 装载)vs 配方重算代价(remat)
       选便宜者:材料写回 home(spill)或直接重算(remat);e 占释放的寄存器
5. 调用点:活跃 caller-saved → 驱逐写回(缓存失效契约);callee-saved 保留
6. 输出:条目 → 位置(寄存器/home)映射 + 驱逐/装载点表 → g_opt_meta / 格形态
```

谱系:主干 = Poletto-Sarkar 线性扫描的**存在结构版本**;spill = 成本感知驱逐(second-chance 变体 + remat);调用点失效 = 解锁 caller-saved。复杂度 ~O(V+E)。数学闭合:CFG 退化情形 = 区间序 First Fit = 最优(Dilworth:最小寄存器数 = 共存偏序 width;区间图 = 完美图);非区间序 = 贪心近似(最优性本质 NP-hard),质量靠上下文拉高,验证不依赖它。

## 六、数学支撑

| 结果 | 内容 |
|---|---|
| Dilworth / 区间序 | 链分解 = 分配;width = 最小寄存器数;区间序 First Fit = 最优(退化情形精确性) |
| PCM / 资源代数(Verus/Iris) | 寄存器 = 可分离资源——验证的可选代数层(非必需,§四 判定已足够) |
| SPL 语法分解(Cai & Goharshady 2024-2026) | series-parallel 带 spill 最小代价分配多项式精确——证实 CFG 系 = 格分配线性化特例;DP 表可作最优性证书形态参考 |

## 七、实现状态(两线)

| 线 | alloc_registers 现状 | 契约/自检 |
|---|---|---|
| develop(基线) | 朴素线性扫描(first/last 区间、5 callee-saved、无 spill;负编码寄存器,g2_slot 机械翻译) | — |
| lattice-ir-v6(推进中) | CAG 重写——rc=0 根因修复 + 寄存器真实分配 + 看门狗实证(v6 挂账清项) | regalloc-consistency.cr(分配器逻辑契约:机制 + opt.cr 映射 + 三层正确性定位)+ verify 运行自检 |

与实现的对应(设计概念 → 代码):

| 概念 | 代码 |
|---|---|
| 寄存器映射 | g_opt_meta(var_idx, reg)对——判定的检查对象 |
| home 槽共享 | pass_stack_share(共存互斥条目共享 home,条件:不同时存在) |
| 存在区间 | v6:ENT live_start/live_end;develop:vars first/last + RegionCheck 机制 |
| 物理位置懒查询 | arch/linux/ld/instr.cr g2_slot(判定的挂接处) |

## 八、范围边界(YAGNI)

- 不做 SSA 转换(版本化语义已在:条目 = 版本)
- 不做图着色机制、不做 SPL 分解实现(CFG 系,方向已弃)
- 不做格代数承诺(关系层面陈述;格 = 映射参数,将来挂接)
- 做:共存关系落定 → 判定规约 → CAG 实现 → checker 自检

## 九、关联

- 设计决策:docs/superpowers/specs/2026-08-27-regalloc-cache-mapping-design.md
- 条款权威:docs/academic/cache-semantics.md;v6 载体:docs/maintainer/design/existence-structure.md
- 备忘:docs/archive/memory-model-capability-lattice.md(v4 分层/无格承诺/图内不可重算)
- RegionCheck/存在区间实现:docs/maintainer/design/pointer-model.md
- 规约体系:docs/maintainer/design/spec-design.md;执行标注空间:docs/maintainer/design/dataflow-design.md §8
- 契约文档:src/compiler/regalloc-consistency.cr(v6 分支)
