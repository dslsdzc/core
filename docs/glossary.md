# 术语表：Core 架构术语

> 定位：受众 = 维护者和贡献者；状态 = active；出处 = 各术语“出处”列的文档，以及
> `src/compiler/lexer.cr`（语言关键字以它为准，本表不重复）。实现与文档冲突时以源码为准。
> 规则：本表只收架构级术语。实现细节和设计论证在出处文档，不在本表展开。
> 版本：v5（2026-10-24）。

## 一、设计出发点

| 术语 | 含义 | 出处 |
|---|---|---|
| 语义保留 | 设计出发点：IR 保留全部语义，与执行硬件解耦。范式迁移时语义不变，只更换后端映射 | z-vision.md |
| 范式普适与零硬件惯例 | 语言跨越所有计算范式；核心语义是纯数学、逻辑和结构，硬件惯例只作为后端实现选择 | z-vision.md |

## 二、三层映射

| 术语 | 含义 | 出处 |
|---|---|---|
| 图（HDFG） | 关系空间：发生什么。节点、边、region、state edges；超图灵性属于图 | maintainer/design/execution-model.md |
| 格层（存在格） | 存在空间（Materialization Space 或 Existence Space）：如何存在，包括物化、方法、共存、驱逐、再生。缓存是该层的一类映射实例，不是本体的名字 | maintainer/design/materialization-space.md |
| 编码层 | 物理编码空间：把格映射为目标机器的地址、字节和指令 | maintainer/design/memory-model.md |
| 格（Lattice） | 映射实例的组织代数，是映射参数，不是层本体的承诺 | maintainer/design/memory-model.md |
| 存在格七字段 | recipe、identity、version、authority、location、persistence、replicability，描述一条 Entry 的物化 | maintainer/design/materialization-space.md |
| 范式映射表 | 映射正确性定理表：证明规则 1–6 ⊇ 该实现；寄存器映射实例是其中一行 | maintainer/design/memory-model.md |

## 三、IR 形态

| 术语 | 含义 | 出处 |
|---|---|---|
| `.cr` | Core 源码，实现和规约写在同一个文件 | grammar/core.ebnf |
| `.cir` | 图形态：HDFG 加规约约束的验证表示 | maintainer/design/execution-model.md |
| `.ccr` | 格形态的落盘格式。当前 v10，共 9 段：STR、TYPE、IFACE、SYM、NOD、ENT、REG、EDG、CASE | src/compiler/ccr_io.cr |
| `.csr` | 规约约束的序列化格式，设计态，当前零实现 | ir-schema/corespecir-schema.md |
| `.coi` | 可选、非权威的优化知识附属文件，保存通用和目标特定的优化知识。删除它不改变 `.ccr` 和产物字节。设计定稿，当前零实现 | maintainer/design/coi-optimization-knowledge-sidecar.md |
| `.ccrb` | 分发包：一个 zstd 帧包裹确定性 tar，固定包含 `manifest` 和 `program.ccr`，可选 `coi/<target>.coi`。打包和解包由 `tools/ccrb.py` 完成，`corearch` 不读 `.ccrb` | tools/ccrb.py |
| HDFG | 全息数据流图，Core 唯一的执行语义 | maintainer/design/execution-model.md |
| region（SG 段） | 图绑定存在结构（kind、enter、exit、parent、nstart、ncount） | maintainer/design/execution-model.md |
| state edges | 顺序约束（副作用序列和循环终止依赖） | maintainer/design/execution-model.md |
| 线性投影 | v5 格形态：从图线性化得到的投影。v6 起改为存在结构本体，该术语仅用于历史文档 | archive/2026-09-05-lattice-ir-v6-format.md |
| 部署配置 | 执行方式由部署配置声明决定，图语义不变 | maintainer/design/execution-model.md |
| CASE 段 | `.ccr` 第 9 段，`IR_MATCH` 的分支表：值、类别、字符串索引、目标节点、旗标 | src/compiler/ccr_io.cr |
| 决策 DAG | 模式匹配编译后形成的分支结构，CASE 段是它的序列化 | maintainer/design/frontend-semantics.md |

> 注：`.corespec` 独立规约格式已退役（2026-09-06），规约使用 `.cr` 语法表达，见 `maintainer/adr/adr-0001`。`.csr` 是 `.cir` 的约束 sidecar，设计态，尚未实现，见 `ir-schema/corespecir-schema.md`。

## 四、存在格规则（1–7 + 2′）与边界

| 术语 | 含义 | 规则 |
|---|---|---|
| 物化（materialization） | 一条 Entry 的一次具体存在（位置和存在方式）；一条 Entry 可以有多份，也可以暂时没有 | 层定义 |
| 条目（entry）与方法（recipe） | 存储的一项 = (产生它的图节点, 输入边)；方法 = 值的产生方式 | 1 |
| 驱逐不变量 | ⟦G ∖ storage(e)⟧ = ⟦G⟧。对可再生条目，驱逐不改变可观测语义（order-free） | 2 |
| 驱逐完整检查 | `Evictable(x) ⟺ Recoverable(x) ∨ PreserveRequiredState(x)`。2 与 4b 是同一检查的两个分支（式的主副本 = cache-semantics.md 规则 2′） | 2′ |
| 再生（regeneration） | 重跑方法节点产生可观测等价的值 | 3 |
| 边界（boundary） | 图边界无方法条目（MMIO、FFI、输入和测量）；语法层是 unsafe | 4 |
| 无方法条目 | `recipe = unrecomputable`：边界和图内不可重算；必须保有或合法转移材料，不可再生 | 4b |
| 版本化 | 赋值 = 版本化：x₁ 创建、x₀ 失效、绑定移动 | 5 |
| 地址 = 映射 | `&x` = (条目标识, 偏移)；字节地址只是经典投影 | 6 |
| 映射实例正确性 | 映射实例保持规则 1-6 = 范式映射表的行定理 | 7 |

> 完整规则以及字节权限层、home、存在区间和驱逐配对等扩展术语，见 `maintainer/design/memory-model.md`。
> 层本体是存在格，包括四个问题、七个字段、归类表和划界，见 `maintainer/design/materialization-space.md`。

## 五、寄存器分配（缓存语义映射实例）

出处：`maintainer/design/regalloc-cache-mapping.md`。

| 术语 | 含义 |
|---|---|
| 条目 | IR 变量的一个版本。每次赋值产生新版本和新条目；v6 用 ENT 记录表示 |
| 生成方法（recipe） | 条目值的产生方式，由产生它的图节点和输入边组成；v6 用 NOD 表示 |
| 移除（eviction） | 丢弃存储内容，保留生成方法 |
| 重算（regeneration） | 重新执行生成方法，产生可观测等价的值 |
| home | 条目的持久位置。经典映射是栈槽；v6 用 ENT 的 home 字段表示 |
| 存在区间 | 条目在图层上的有效区间，等于图活性；v6 用 ENT 的 live_start 和 live_end 表示，坐标是 NOD id |
| 共存 | 两个条目的存在区间相交。共存是对称关系，没有传递性；v6 由 sweep 推导，不写入文件 |
| 寄存器映射实例 | 寄存器文件作为缓存层，home 作为栈槽，见缓存语义规则 7 |
| 一致性判定 | 共存互斥、读点无陈旧、移除配对、调用点失效契约。四条都成立时，寄存器映射实例合法 |
| 共存互斥 | 每个时刻每个寄存器至多存放一个条目的存储内容。共存的条目必须放在不同寄存器 |
| 读点无陈旧 | 读到的存储内容与条目当前版本对齐，见缓存语义规则 5 |
| 移除配对 | 寄存器释放时存储内容不能丢，按生成方法分档：recomputable 写回 home 或重算；unrecomputable 必须保留或合法转移；无法判定时不可移除 |
| 调用点失效契约 | 调用点是缓存失效边界。caller-saved 寄存器失效，存储内容回到 home；callee-saved 寄存器保留。ABI 是缓存保留契约 |
| CAG（上下文贪心） | 存在结构上的 First Fit 贪心扫描。上下文包括共存关系、重算成本、区域生命周期、调用点和使用次数 |
| spill 与 remat | spill 是写回 home；remat 是直接重算 |
| 共存偏序 width | Dilworth 定理给出的最小寄存器数，等于共存偏序的 width |

## 六、执行标注空间

出处：`maintainer/design/execution-annotation-space.md`。

| 术语 | 含义 |
|---|---|
| ITER | 迭代语义（因果循环，现状） |
| FIXPT | 一致解语义（非因果环）：声明性，执行后置 |
| 一致解 | 环上算子的不动点：值使环自洽，不迭代执行 |
| FUZZY | 模糊语义：格值隶属度，加权分支汇合，使用剩余格代数 |
| CORE | 共归纳语义：环加 ν 语义，最大不动点，用于同步硬件和数据流 |
| Oracle 节点 | 超图灵结构：节点计算任意决策函数，函数可以不可计算 |
| 超限循环 | FIXPT 加序数深度，对应无限时间图灵机 |
| 连续节点 | 实数语义，对应 BSS 机器 |

## 七、编译器管线

| 术语 | 含义 | 出处 |
|---|---|---|
| corec / corearch | 前端（词法、语法、类型检查、IR、`.ccr`）和后端（`.ccr` 到 ELF）。`.ccr` 是两者的接口契约 | maintainer/adr/adr-0004 |
| 三级自举 | Stage 0 用 Python bootstrap 生成 corec，Stage 1 用 corec 生成 corec2，Stage 2 用 corec2 生成 corec3。验收条件是 corec2 和 corec3 的输出逐字节一致 | maintainer/onboarding.md |
| HIT（硬件接口表） | 把目标特定操作映射为目标指令序列的表，位于 `src/arch/hit/` | src/arch/hit/hit.cr |
| CIR 缓存 | 函数级 `.cir` 快照缓存，位于 `.core/cache/cir/` | src/compiler/cir_cache.cr |
| pass | 对图或指令序列的一次独立处理，例如 CSE、指针分析、region 检查和 provenance 验证 | src/compiler/pass.cr |
| purity 与 state chain | 纯度和状态依赖链。纯函数没有副作用；state edge 记录副作用顺序和循环终止依赖 | maintainer/design/frontend-semantics.md |

## 八、验证体系

| 术语 | 含义 | 出处 |
|---|---|---|
| 规约层 | 程序“应该做什么”的约束。已并入 `.cr` 语法，独立格式已退役 | maintainer/adr/adr-0001、maintainer/design/spec-design.md |
| McTT | 当前验证信任根。CIC 选型已于 2026-10-24 废止，仅作历史对照 | academic/verifier-kernel.md |
| SMT 证书 | 自动化采用证书外包：计算在外，健全性在内 | maintainer/design/spec-design.md |
| 证明驱动优化 | 已证性质回传给优化器 | maintainer/design/spec-design.md |

## 九、收录规则

- 一个术语进入本表，需要跨文档引用至少 2 处，且语义唯一。否则留在出处文档。
- 版本：v3（2026-08-27）全量扩充，v4（2026-09-06）校准，v5（2026-10-24）更新 `.ccr` v10、McTT 信任根、自举阶段和执行标注术语。
