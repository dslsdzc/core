# 可解释、可预测、语义增量

## 概述

三条线索使用同一个机制：把编译器做出的决定变成图上的正式对象，即决策记录。

- 解释是读取记录，回答为什么这样做。
- 预测是记录的一个子类，给出这种做法的资源上界。
- 增量是记录的依赖闭包，说明它依赖什么，以及什么变化会使它失效。

可解释面向人，可预测面向调度和约束，语义增量面向机器。三者共用记录表和依赖边，不各自建一套。

确定性报告是同一机制在属性轴上的读法：每个轴的状态是一条决定记录，不确定性 provenance 链是 `evidence` 闭包的另一种读法。它不是第四个系统。

设计状态：定稿，尚未实现。修订记录、决定编号、现状差距和自检见 `docs/superpowers/implementation/2026-09-11-explain-predict-incremental-audit.md`。

## 决策记录

一条记录是一次编译器决策的内容寻址快照：

| 字段 | 语义 |
|---|---|
| `id` | 内容哈希，由 kind、subject、输入摘要和原因码组成，不随构建序号变化 |
| `kind` | 记录类别，开放注册，例如 `check_emitted`、`ptr_verdict`、`reg_choice`、`bound`、`obligation`、`cache_verdict` |
| `subject` | 图对象引用，例如 DFNode、边、区域、IR 指令、符号或源码区间 |
| `phase` | 产生阶段，例如 checker、ir_gen、dataflow、判定引擎、regalloc 或 emit |
| `choice` | `selected`、`rejected`、`forced` 或 `unknown` |
| `cause` | 原因码和参数。原因码是稳定标识符，不是自由文本；人读文本由渲染层生成 |
| `alternatives` | 被拒方案和各自原因码。空值表示没有评估过，不表示拒绝 |
| `evidence` | 输入引用集，同时是增量的依赖边 |
| `determinism` | `det`、`heuristic` 或 `env`。包含启发式或环境依赖的记录不能跨构建复用 |

`evidence` 是记录到输入的边。没有 `evidence` 的记录不能增量复用，只能整块失效。这把记录完整性和失效精度变成同一个变量。

记录生成默认开启，写入轻量字段。记录展开按需进行，只有查询时才渲染 `evidence` 和原因参数。关闭记录通道后，产物必须逐字节相同。

决策记录必须随缓存条目一起存取。否则缓存命中路径上的决定不会被记录，`explain` 在冷缓存和热缓存下会给出不同答案。

## 可解释

### 原则

编译器替用户完成工作，但不隐藏做出决定的过程。可解释的标准不是能打印大量信息，而是：

1. 用户能从一个可以指认的定位点出发，问一个关心的问题类，得到编译器实际做过的决定和原因。
2. 答案只由产物决定，同一产物两次查询逐字节相同。
3. 答不出就说答不出，写入 `unattributed`，不能凭空生成理由。

`explain` 不是又一个 dump 通道。整图转储没有定位点、没有问题类、没有稳定 schema，也不回答为什么。

### 查询面

定位点：

| 定位点 | 形式 |
|---|---|
| 源码位置 | `corec explain FILE.cr:LINE:COL` |
| 符号 | `--fn NAME` 或 `--global NAME` |
| 图对象 | `--node DFN`、`--instr IRN` 或 `--region ID` |
| 记录 | `--record ID` |

问题类由各生产者注册，是开放清单，不是 CLI 硬编码的 switch。

| 问题类 | 问什么 | 生产者 |
|---|---|---|
| `checks` | 这条指针或下标为什么插入运行时检查 | 安全检查 pass、长度侧表、边界检查节点、checker |
| `ptr` | 这条指针为什么判定为安全 | 指针分析三个 pass |
| `placement` | 这个节点为什么放在 CPU 上，为什么被移除或重算 | 寄存器分配 |
| `bounds` | 这个循环或序列的上界来自哪里 | 边界推断 pass |
| `vectorize` | 为什么没有向量化 | 向量化优化器 |

没有记录的问题类必须给确定答案，答案分三种：未实现、未评估、评估后拒绝。三者不能混同。

### 输出

结构化数据是唯一来源，人读文本由它生成。

```json
{
  "schema": "core.explain/1",
  "query": {"anchor": {}, "qclass": "checks"},
  "records": [
    {
      "id": "...",
      "kind": "check_emitted",
      "phase": "ir_gen",
      "subject": {"src": "FILE.cr:42:7", "instr": 118},
      "choice": "selected",
      "cause": {"code": "E-CHK-SLICE-DYN", "args": {"len_source": "var"}},
      "alternatives": [{"code": "E-CHK-NONE", "rejected_because": "E-CHK-SLICE-DYN"}],
      "determinism": "det",
      "evidence": [{"kind": "side_table", "ref": "g_ir_slice_lens:17"}]
    }
  ],
  "unattributed": [{"subject": {}, "qclass": "checks", "why": "no_record"}],
  "truncated": 0
}
```

约束：

- 同一产物两次 `explain` 的输出逐字节相同，不包含时间戳、PID、地址或绝对路径。排序先按记录 id。
- `schema` 在破坏性变更时递增。
- `unattributed` 必须显式列出无法归因的情况，不能用空的 `records` 表示没有发生决策。
- 人读模式使用稳定的原因码措辞表。`--json` 输出结构化数据。
- LSP hover 使用 markdown 渲染同一结构，coreview 读取 JSON，不新增 LSP 方法。

### 前端分工

| 前端 | 场景 | 读取内容 |
|---|---|---|
| `corec explain` | 批处理、CI、golden 快照、无编辑器 | 产物和决策记录旁路文件 |
| corelsp | 光标处按需查询 | 同一查询核，只读快照 |
| coreview | 图级和管线级浏览 | `.cir`、`.ccr` dump 加记录叠加 |

`explain` 是答案，coreview 是全景，LSP 是就近。三者共用查询核和记录表。coreview 的图渲染不重算语义。

## 确定性报告

`corec analyze --determinism` 不是新工具，它是查询核在程序级定位点上的视图。

报告包含轴族逐项状态和不确定性 provenance 链：

```text
axis         status    evidence / residual
D_value      PROVED    merge_deterministic @12:3，没有可达边界
D_effect     UNKNOWN   state edge 覆盖 #41、#44；print@#58 未入链，保守降级
D_memory     PROVED    region 绑定和 bump/reset 全静态
D_timing     UNKNOWN   residual：循环 #61 的迭代次数依赖外部输入
D_resource   PROVED    结构层：进行中任务不超过 4
D_external   EXPLICIT  boundary #27（stdin），归属方是边界节点
D_mapping    PROVED    没有机器相关假设

uncertainty provenance:
  boundary #27 -> parser -> branch #61 -> output "report"
```

状态值域是 `{PROVED, MODELED, UNKNOWN, EXPLICIT}`。

`D_timing` 只使用前三个值：

- `PROVED` 是机器无关上界，例如分配次数、字节数、进行中任务数和通信量。
- `MODELED` 是成本模型估计，必须标注“模型估计，非证明”。
- `UNKNOWN` 是无法判断、模型不可用或链断。

分配次数和进行中任务数不是时间。报告必须把机器无关量和时间分列，不能让读者把指令数上界读成时间上界。

每一行必须带证据或残余。空证据加空残余是非法的。

链的每一跳必须能在记录表中查到。查不到时记为 `UNKNOWN` 并登记断链位置。链终止于边界节点或显式语义源。到达既不是边界又没有生成方法的内部节点时，记为断链。

状态沿依赖闭包合并：

- 任一环节 `UNKNOWN`，整体 `UNKNOWN`。
- 没有 `UNKNOWN` 但含 `MODELED`，整体 `MODELED`。
- 没有 `UNKNOWN` 和 `MODELED` 但含 `EXPLICIT`，整体 `EXPLICIT`。
- 全部 `PROVED`，整体 `PROVED`。
- `MODELED` 和 `EXPLICIT` 不可比，同时存在时并列标注，并让 `EXPLICIT` 的源可指认。

报告自身必须确定：同一产物两次运行逐字节相同，排序按轴名和记录 id。

### 与成本模型

```text
cost_model_query(kind, subject, mapping_desc) -> {
    cost,
    band,
    model_id,
    model_ver,
    assumptions[]
}
```

报告只做三件事：调用、贴标签、把模型标识和假设写入记录的 `evidence`。模型版本变化后，报告和依赖它的记录失效。

报告不重造成本模型，不读模型内部状态，不缓存模型结果。模型不可用时必须是 `UNKNOWN`，不能用经验常数回退成 `MODELED`。

## 可预测

上界分三层：

| 层 | 量 | 可判定性 | 归属 |
|---|---|---|---|
| 结构层 | 最大进行中任务数、最大通信条数、循环迭代次数上界、每个 arena 的值个数上界 | 由图、区域、state edge 和 spawn 计数直接判定 | 本设计 |
| 映射层 | 最大字节内存、最大通信字节量、峰值存储 | 需要尺寸和对齐标注 | S-C 和硬件映射 |
| 时间层 | deadline、墙钟上界 | 语义层不可判，依赖成本模型和共享机器调度 | 只能 enforce 或 proof-required |

三层不能混报。结构层上界不蕴含映射层上界。把两层混成一个内存上界是过度承诺。

上界状态和轴族共用同一个值域：

| 状态 | 含义 |
|---|---|
| `PROVED` | 对声明的全部执行成立，机器无关，附假设列表 |
| `MODELED` | 依赖成本模型，必须附不确定带和模型版本 |
| `UNKNOWN` | 无法判断，不能渲染为界 |
| `EXPLICIT` | 由显式输入的边界或声明给出 |

`PROVED` 的结构层数量可以称为保证，但不能称为时间保证。`MODELED` 不是证明。`UNKNOWN` 不能渲染成任何界。

## 语义增量

四段变化：

| 段 | 输入到输出 | 当前机制 | 失效面 |
|---|---|---|---|
| ΔSource 到 ΔGraph | 源变化引起图变化 | 函数级指纹 | 变更的函数、调用它的函数、导入闭包、单态化实例 |
| ΔGraph 到 ΔProof | 图变化引起义务或证明变化 | 引擎进程内缓存 | 义务的输入摘要，包括类型项、约束和引擎版本 |
| ΔProof 到 ΔBinary | 证明变化引起产物变化 | 没有增量，整体运行 | 段级和节点身份稳定性 |

缓存键从单哈希升级为依赖集：

| 分量 | 内容 |
|---|---|
| `src_fp` | 函数体原文哈希 |
| `sig_fp` | 签名指纹，最终升级为类型项指纹 |
| `deps_fp` | 导入和调用闭包摘要 |
| `policy_fp` | policy 集摘要，S-A 后启用 |
| `unit_fp` | 编译器产物哈希加目标配置，例如 `--static`、opt-level、target 和表模式 |
| `phase_ver` | 各阶段格式版本、判定引擎版本、成本模型版本 |
| `det` | 记录中的确定性分级。含启发式或环境依赖的记录不能跨构建复用 |

现状差距包括：缓存键缺编译器身份，导致重建后旧条目仍有效；`.ccr` 输出与缓存状态相关；缓存命中跳过全局初始化注入；缓存与单态化交互脆弱；命中检查不含构建配置和 policy 集。

正确性检查：

1. 产物级：冷缓存和热缓存两态的 ELF、`.ccr` 和 `.cir` 逐字节相同。
2. 记录级：`explain` 输出在冷热两态相同，包括 `unattributed`。
3. 义务级：义务和证明集合在 ΔProof 后相同。

反向检查必须同时存在：增量必须真实生效。只测等价而不测节省，删除缓存也能全部通过。

失效时明确回退全量重编。缓存条目损坏、版本不认识或指纹分量缺失时，不能按旧条目无提示采用。

## 公共基建

一套记录表，三个视图，一条追踪：

- 解释视图读 `cause` 和 `alternatives`。
- 归因视图读 `evidence` 闭包，终止于边界或显式源。
- 失效视图读 `evidence` 和 `determinism`。

失效追踪就是决策记录的输入依赖闭包。不能为失效追踪另建一套依赖表，否则会出现“记录说 A 依赖 B，依赖表说 A 依赖 C”的双源不一致。

依赖图分三层：

| 层 | 内容 |
|---|---|
| 图内 | HDFG 节点、边、区域嵌套、state edge，既有 |
| 记录内 | 记录到 `evidence` 的输入引用 |
| 单元间 | 文件、符号、导入闭包、单态化实例、构建配置 |

记录先写入旁路文件，最终进入 `.ccr` 决策记录段。段化前旁路文件是唯一实现方式。段化后，开启和关闭记录通道的两态产物必须逐字节相同。

## 最小切片

四个切片独立验收，顺序如下。

### 语义增量缓存键 v1

范围：键升级为多分量，包括 `src_fp`、`sig_fp`、`unit_fp`、`phase_ver`、粗粒度 `deps_fp`，并让记录随缓存条目存取。

不做：`policy_fp`、记录分级的复用面、ΔProof、ΔBinary、增量后端、`.ccr` 格式改动、单态化改动、命中路径产物保真。

检查：

1. 跨编译器重建不复用旧条目。
2. 冷热两态的 `.ccr` 仍可能不同，必须附根因清单。整体目标保留为冷热两态逐字节相同。
3. 负向对照覆盖重建、stdlib 依赖、构建配置和引擎版本。
4. 未变更函数的条目字节未变。
5. 全套件和自举比较保持。

### 可解释：运行时检查必要性

范围：决策记录表、`checks` 问题类的生产者接线、`corec explain FILE:LINE`、`--json` 和人读输出、`unattributed` 通道。

检查：

1. 三条真实决策产生记录：字面量界、变量下标加字面量长度、切片长度变量。
2. 恒越界路径能回答检查码。
3. 没有记录时进入 `unattributed`。
4. 关闭记录通道后产物逐字节相同。
5. 同一产物两次查询输出逐字节相同。
6. golden 快照进入套件。

不做：其他问题类、新的 LSP 方法、图级交互 UI。

### 可预测：静态 go 子集的进行中任务上界

范围：对 `IR_SPAWN` 的 `spawn_count` 非负部分，在区域和依赖结构上求最大进行中任务数和并发区域清单。动态 spawn 归入 `UNKNOWN`。

检查：

1. 固定 `go` 数量的例程产生确定上界，与运行时并发峰值一致。
2. 动态 spawn 例归入 `UNKNOWN`，不渲染为界。
3. 关闭记录通道后产物逐字节相同。
4. 输出标明结构层，不冒充字节数或时间。

不做：字节内存上界、时间 deadline、自动并发。

### 确定性报告只读版

范围：报告七个轴的逐项状态和不确定性 provenance 链，输出残余清单。只报告，不执行，不拒绝编译。

无成本模型时 `D_timing` 恒为 `UNKNOWN`。`EXPLICIT` 的来源有两类：边界节点链，今天可用；轴标注登记，待 S-A。

检查：

1. 无边界纯函数程序的 `D_value` 和 `D_memory` 为 `PROVED`。
2. 外部输入驱动程序的链非空，终止于边界节点，状态为 `EXPLICIT`。
3. 断链例归入 `UNKNOWN` 并登记位置。
4. 空证据加空残余非法。
5. 同一产物两次运行逐字节相同。
6. 无模型时 `D_timing` 不得出现 `MODELED`。
7. 含 `print` 类调用的输出，`D_effect` 不能仅凭 state edge 全序判为 `PROVED`。

不做：拒绝编译、隐式竞争拒绝、汇合语义、成本模型、图级交互 UI。

## 不承诺

| 类别 | 处理 |
|---|---|
| 错误的 specification | `explain` 报告编译器为什么这样做，不证明这样做正确。原因码不是正确性证明。增量等价只是同一编译器的两态一致，不是语义正确性证据 |
| 恶意或失陷外部实体 | 记录存储在磁盘上，可以被篡改。伪造记录可以让 `explain` 给出不实结论，也可以让增量复用错误决定。输出不是安全证据；对抗篡改依靠可复现构建和签名；记录必须随缓存条目一起校验 |
| 需求本身允许危险行为 | 本设计不禁止能力。上界是约束数据，解释是只读视图。隔离边界和上界声明是两件事 |

本设计另外不承诺：

1. 所有决策都可解释。启发式内部状态可能无法归因，必须进入 `unattributed` 并登记。
2. 上界对所有程序可判。动态 spawn、外部输入驱动的循环、无尺寸标注的映射层和无成本模型的时间都落在 `UNKNOWN`。
3. 增量对所有变更正确。承诺的是检查可测、失效面覆盖、未覆盖时明确回退全量。
4. `MODELED` 是证明。报告只归因，不消除不确定性。`EXPLICIT` 是用户明文请求的不确定，呈现它，不替用户消除。`UNKNOWN` 是合法终局，不能用启发式常数补成 `MODELED`。

## 不做项

- 不把 `explain` 做成 dump 通道。
- 不为每条线索另建记录表。
- 不重造成本模型。
- 不做全量决策解释。
- 不做增量后端。
- 不做 `.ccr` 格式改动，先行使用旁路文件。
- 不做图级交互 UI。
- 不做自动并行。

## 开放问题

| # | 问题 | 状态 |
|---|---|---|
| 1 | 记录旁路文件的命名和目录 | 实施批确定 |
| 2 | 决策记录段的段名和布局 | 随格式批次确定 |
| 3 | 原因码措辞表的维护方式 | 照错误码表先例 |
| 4 | 问题类注册接口 | 开放注册表，新增 pass 不改 CLI |
| 5 | 记录 id 哈希算法 | 需要确定性和跨平台一致性 |
| 6 | 缓存键各分量的具体编码 | 实施批确定 |
| 7 | 成本模型 `band` 和 `confidence` 的关系 | 与 S-C 对齐 |
| 8 | 节点级 ΔBinary | 前置是稳定节点身份，待确定 |

## 关联

- 修订记录和自检：`docs/superpowers/implementation/2026-09-11-explain-predict-incremental-audit.md`
- 共享契约：`docs/superpowers/specs/2026-09-11-semantic-safety-roadmap.md`
- 类型接口引擎：`docs/superpowers/specs/2026-09-10-type-interface-unification-design.md`
- 汇合语义：`docs/superpowers/specs/2026-09-11-merge-semantics-design.md`
- 缓存语义：`docs/academic/cache-semantics.md`
- 现有缓存实现：`src/compiler/cir_cache.cr`
