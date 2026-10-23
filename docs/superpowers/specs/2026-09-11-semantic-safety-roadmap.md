# 语义安全计划：共享契约

## 论题

Core 把尽可能多的漏洞和风险类别，从程序员需要遵守的规范，变成非法语义或不能无提示消失的义务。

两条线索支持这个方向：

- CWE 和 OWASP 中，内存安全之外仍有大量类别。
- C++ 和系统软件调查中，依赖管理、构建时间和并发复杂度比内存安全问题更常见。

两者在 Core 上使用同一个机制：图上的正交属性轴加义务分级。

属性轴是“类型等于图标注”的直接推广。义务分级把 `where` 三档补成四档。判定器使用类型接口设计中的引擎。

## 共享术语

| 术语 | 定义 |
|---|---|
| 属性轴 | 图对象和边上的开放标注维度：`trust`、`secrecy`、`integrity`、`authority`、`lifetime`、`state-version`、`effect` |
| 义务 | 由属性轴导出的、必须在编译或验证期处理的判定要求 |
| 四档义务 | 1 prove 静态证明，2 enforce 运行时强制，3 proof-required 要求 proof 或 contract，4 reject 拒绝编译 |
| policy | 一组图上约束，是数据不是语法。新增安全模型不改 Graph 本体，不加关键字 |
| declassify | 显式降密或放行节点。`Secret` 到 `Public` 的唯一合法通道，同构地用于 `Untrusted` 到 `Trusted` 的净化 |
| source 和 sink 模型 | 领域库声明不可信来源和危险落入点。语言只提供流规则和义务分级 |

放行和声明条目是绕过义务的唯一通道。条目的 `kind` 有五类：

```text
declassify  显式降密或净化
grant       授予已有对象或权限
deny        拒绝已有对象或权限
mint        创建能力，例如根声明或 alloc_at
stability   治理层稳定性声明
```

每条放行和声明条目必须进入清单，字段包括主体或身份、目标或范围、理由、派生源和义务引用。默认形态是图上显式节点。偏离节点形态时，必须显式豁免并补齐审计字段，不能无记录地绕过。

## 原则

1. 属性不提升为语言 primitive。属性是开放标注，只有义务可以拒绝编译。
2. 策略面归库，规则面归语言。SQL、HTML 和 shell 的语法正确性由领域库用类型化构造器表达。语言只负责“不可信数据不能到达解释器语法位”这类流规则。不能把某类漏洞做成内建特判。
3. 义务不会无提示消失。证不出时必须归入 2、3 或 4，不能当作通过。不承诺自动证明所有程序安全。
4. 判定统一走引擎。义务判定使用类型项判定，策略只提供形状项和约束，不另建判定体系。
5. 声明式上限加命令式下限。本计划只改声明式上限。执行、副作用和内存的命令式下限，例如 state edge、区域和调度，不动。

## determinism 族

目标不是宣称 Core 是最确定的语言，而是保证：

> 每条可观测的不确定性，必须能归因到显式语义源，或者已经证明汇合与调度无关。

物理不确定性不能推出语义不确定性，除非源码明确允许。

轴族：

| 轴 | 含义 | 现状 |
|---|---|---|
| `D_value` | 值和结果确定性 | 强，纯函数语言层面 |
| `D_effect` | 副作用顺序确定性 | 有基础，state edge 显式 |
| `D_memory` | 内存行为和生命周期确定性 | 强，区域绑定加 bump/reset |
| `D_timing` | 时间和最坏执行时间 | 三值化，不允许给出错误结论 |
| `D_resource` | 资源上界确定性 | 有基础，需要静态上界 |
| `D_external` | 外部输入依赖确定性 | 边界节点可以归档 |
| `D_mapping` | 跨机器语义确定性 | Core 特有轴，映射改变而语义不变 |

归入四档：

| 情形 | 档位 |
|---|---|
| 依赖和 state edge 足以证明汇合与调度无关 | 1 prove |
| 顺序由显式顺序源固定 | 落到确定实现，不新增档 |
| 语义明确允许 `race` 或 `select_any` | 显式不确定，必须进入报告部分 |
| 既没有证明也没有标注，属于隐式竞争 | 4 reject |

`D_timing` 分三值：

- `PROVED` 是机器无关上界，例如分配次数、字节数、进行中任务数和通信量。
- `MODELED` 是机器相关成本模型估计，必须标注“模型不是证明”。
- `UNKNOWN` 是无法判定。

不能把 `MODELED` 当作最坏执行时间证明。

迁移窗口默认一个发布周期。窗口内保留 `select` 的现有语义并给具名诊断，窗口后强制标注。窗口内 `select` 不能作为显式顺序源用于 prove。

`race` 的胜者身份可以作为显式出参，即 witness。witness 是显式语义源，登记为 `EXPLICIT` 不确定源并附带报告义务，不新增语义。

默认强度：

- 本地开发：登记并继续编译。
- 严格模式或 CI：拒绝编译。
- 档 2 默认启用，能强制就强制。高安全档关闭强制通道。
- 未声明的边界条目取 `unknown`，不拒绝编译，但报告中可见。

## 三类不可消的残留

每份安全规格的“不承诺”节必须引用这三类，并说明本族落在哪一类。

1. 错误的 specification。Core 只能证明程序忠实实现了规则，不能证明规则本身正确。
2. 恶意或失陷的外部实体。供应链、编译机、密钥和硬件后门只能通过可复现构建、签名、provenance 和最小权限缩小，不能用语言语义证明。
3. 需求本身允许危险行为。shell、浏览器、内核和 JIT 必须执行外来代码。目标是证明隔离边界，不是禁止能力。

## 九份设计

| 编号 | 文件 | 范围 |
|---|---|---|
| S-A | `2026-09-11-semantic-safety-obligations-design.md` | 属性轴、四档义务、policy 接口、放行和声明条目、未证明义务的处理 |
| S-B1 | `2026-09-11-policy-injection-design.md` | 注入族：不可信数据到达解释器语法位是非法边，区分值位和语法位 |
| S-B2 | `2026-09-11-policy-authorization-design.md` | 授权族：`Can(a,o,r,v)` 等价于存在合法 capability path；有副作用的操作必须产出证明 |
| S-B3 | `2026-09-11-policy-information-flow-design.md` | 信息流族：`Secret` 不能到 `Public`，除非显式降密；登记隐式流边界 |
| S-B4 | `2026-09-11-policy-resource-confinement-design.md` | 路径限制族：`Path<Root>`，`..` 无法构造目标 capability |
| S-B5 | `2026-09-11-policy-state-version-toctou-design.md` | 状态版本族：检查和使用的版本分离，handle 绑定身份而不是按 pathname 重查 |
| S-C | `2026-09-11-performance-without-commitment-design.md` | 性能不承诺具体实现，纯度、效应、依赖、局部性和精度标注到优化器和目标描述 |
| S-D | `2026-09-11-explain-predict-incremental-design.md` | 可解释、可预测、语义增量，以及确定性报告部分 |
| S-E | `2026-09-11-merge-semantics-design.md` | 汇合语义的四种形态，物理顺序不能推出语义降级，`select` 重新确定和兼容窗口 |

## 实施顺序

1. S-A 先定稿并实现最小切片。属性轴、四档和义务判定走引擎是其余八份的基础。
2. S-B 五族在 S-A 定稿后逐族出实施计划。每族独立验收，不并行开工，避免语义争议交叉。
3. S-C 与 x86 实例化波 2/3、R3 映射侧合批。
4. S-D 的可解释面可以先做。语义增量依赖缓存键修复。
5. 本计划不打断 R2 剩余批次。S-A 的实施排在 R2 收线之后。

## 关联

- 编号对照和修订记录：`docs/superpowers/implementation/2026-09-11-semantic-safety-roadmap-audit.md`
- 类型系统方向：`docs/superpowers/specs/2026-08-30-type-system-direction-design.md`
- 类型接口判定引擎：`docs/superpowers/specs/2026-09-10-type-interface-unification-design.md`
- 能力格：`docs/archive/memory-model-capability-lattice.md`
- 存储规则：`docs/academic/cache-semantics.md`
- 指针模型：`docs/maintainer/design/pointer-model.md`
