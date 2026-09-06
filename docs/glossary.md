# 术语表(Glossary)——Core 架构术语

> 定位:受众 = maintainers(兼 contributors);状态 = active;真源 = 各术语「出处」列的文档与
> `src/compiler/lexer.cr`(语言关键字唯一真源,本表不重复);实现与文档冲突时以源码为准(既有惯例)。
> 规则:本表只收**架构级术语**,实现细节与设计论证在出处文档,不在本表展开。
> 演进:2026-08-27 v3 全量扩充 → 2026-09-06 v4 校准(去 .corespec 退役残留、出处链接对齐、重复表压缩)。

## 一、设计出发点

| 术语 | 含义 | 出处 |
|---|---|---|
| 语义保鲜 | 设计出发点:IR 保留全部语义,与执行硬件解耦——范式迁移语义不动、只换后端映射 | z-vision.md |
| 范式普适 / 零硬件惯例 | 语言跨越所有计算范式;核心语义纯数学/逻辑/结构,硬件惯例只作后端实现选择 | z-vision.md |

## 二、三层映射

| 术语 | 含义 | 出处 |
|---|---|---|
| 图(HDFG) | 关系空间:发生什么——节点/边/region/state edges;超图灵性属于图 | maintainer/design/execution-model.md |
| 格(层) | 存在空间:如何存在——条目、配方、驱逐、再生 | design/memory-model.md |
| 编码(层) | 物理编码空间:如何实现(2026-08-27 更名,原「二进制」) | design/memory-model.md |
| 格(Lattice) | 层内组织代数成分——映射参数,非层本体承诺(无格承诺) | design/memory-model.md |
| 范式映射表 | 映射正确性定理表——证明缓存语义 ⊇ 该实现;寄存器映射实例为其一行 | design/memory-model.md |

## 三、IR 形态

| 术语 | 含义 | 出处 |
|---|---|---|
| `.cr` / `.cir` / `.ccr` | 源码 / 图形态(HDFG + 规约约束)/ 格形态(v6 = 段表 + ENT 存在结构段,v6-only) | specs/2026-09-05-lattice-ir-v6-format.md |
| HDFG | 全息数据流图——Core 唯一执行语义 | maintainer/design/execution-model.md |
| region(SG 段) | 图锚定存在结构(kind/enter/exit/parent/nstart/ncount) | maintainer/design/execution-model.md |
| state edges | 顺序约束(副作用链 + 循环终止依赖) | maintainer/design/execution-model.md |
| 线性投影 | v5 格形态 = 从图线性化的投影;v6 升级为存在结构本体 | specs/lattice-ir-v6-format |
| 部署配置 | 执行方式由部署配置声明决定,图语义不变 | maintainer/design/execution-model.md |

> 注:.corespec/.csr 独立规约形态已退役(2026-09-06)——规约 = .cr 语法内约束,见 maintainer/adr/adr-0001。

## 四、缓存语义(核心七条 + 边界)

| 术语 | 含义 | 条款 |
|---|---|---|
| 条目(entry)/ 配方(recipe) | 存储的一项 = (产生它的图节点, 输入边);配方 = 值的产生方式 | 1 |
| 驱逐不变量 | ⟦G ∖ storage(e)⟧ = ⟦G⟧——驱逐任意条目不改变可观测语义(order-free) | 2 |
| 再生(regeneration) | 重跑配方节点产生可观测等价的值 | 3 |
| 边界(boundary) | 图边界无配方条目(MMIO/FFI/输入/测量);语法层 = unsafe | 4 |
| 版本化 | 赋值 = 版本化:x₁ 创建、x₀ 失效、绑定移动 | 5 |
| 地址 = 映射 | `&x` = (条目标识, 偏移);字节地址只是经典投影 | 6 |
| 映射实例正确性 | 映射实例保持条款 1-6 = 范式映射表的行定理 | 7 |

> 完整七条 + 字节权限层/home/存在区间/驱逐配对等扩展术语:design/memory-model.md。

## 五、寄存器分配(缓存语义映射实例)

一致性判定/共存互斥/读点无陈旧/调用点失效契约/remat/共存偏序 width/order-free/
上下文贪心 CAG/spill/栈槽/装载存储/写回——全部术语定义与论证见
design/regalloc-cache-mapping.md(正式参考),本表不重复。

## 六、执行标注空间

| 术语 | 含义 |
|---|---|
| ITER | 迭代语义(因果循环,现状) |
| FIXPT | 一致解语义(非因果环)——声明性、执行后置 |
| 一致解 | 环上算子的不动点——值使环自洽,不迭代执行 |

## 七、编译器管线

| 术语 | 含义 | 出处 |
|---|---|---|
| corec / corearch | 前端(lex→check→ir→ccr)/ 后端(.ccr→ELF),.ccr 为接口契约 | maintainer/adr/adr-0004 |
| 三级自举 | Stage 0(Python)→ Stage 1(corec)→ Stage 2(corec2);三阶段字节一致 | maintainer/onboarding.md |
| 自举阻塞项 | corec2 tokenizer 死循环(9 全局变量未注册 g_ir_globals) | TODO.md |

## 八、验证体系

| 术语 | 含义 | 出处 |
|---|---|---|
| 规约层 | 程序"应该做什么"的约束——2026-09 起并入 .cr 语法(独立格式退役) | maintainer/adr/adr-0001、maintainer/design/spec-design.md |
| CIC 内核 / SMT 证书 | 信任根 = CIC;自动化 = 证书外包(计算在外、健全性在内) | design/verifier-kernel.md |
| 证明驱动优化 | 已证性质回流入优化器 | maintainer/design/spec-design.md |

## 九、讨论判据与术语演进

- 判据(何时一个新词值得进本表):跨文档引用 ≥2 处且语义唯一;否则留在出处文档
- v3(2026-08-27)全量扩充 → v4(2026-09-06)校准;历史演进细节见 git 历史,不设演进记录节
