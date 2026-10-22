# 类型系统方向设计：学术对照与修订记录

> 对应设计：[2026-08-30-type-system-direction-design.md](../specs/2026-08-30-type-system-direction-design.md)

本文保存类型系统方向的论文地图、缺口补偿、战略定位和原始论证。设计正文只保留 14 条定案、推理、代价和演进顺序。

# 类型系统方向设计备忘：图本体与接口统一（2026-08-30 定稿）

> 摘要（十六字）：图是本体，接口是契约，类型是推导，编码是映射。
>
> 自动化原则：类型概念不显式。类型等于值集合，集合运算自动判定；显式性最小集是 where 值约束。
>
> 声明式边界：声明式上限（类型、契约、验证）加命令式下限（执行、副作用、内存），两者共用一张图。

## 一、定案清单（14 条）

### 图本体（1-4）

1. 图本体原则：图（HDFG）是唯一真相层。类型 = 图节点的标注（投影），接口 = 图上声明的契约（行为约束），类型检查 = 图的良构性验证 pass（与 PointerAnalysis / RegionCheck / ProvenanceVerify 同级，不建第二套数据结构）。
2. 接口统一：用户面和检查层只有接口一个概念。int / dex / string / bool 是原生接口条目（规则内建在编译器，公理引用规约层，用户不可实现；公理由编译器负责，防止伪造证明）。
3. 实现决策：一张 interface 注册表（动态表，int = 表头原生条目）；检查器删掉所有类型特判，统一查表验证；发射层原语映射不动（`+` 对应 addq 是机器知识，归 hw-map 编码层，不做表驱动化的大重构）。
4. 类型检查 = 图验证 pass：标注一致性、操作数兼容性按注册表规则判定，与指针三 pass 同一层级。

### 约束与泛型（5-6）

5. where 值约束：实现内联的轻量前置条件。三档语义分级：编译期常量约束得到编译错误或通过；符号约束产生 VC 义务（验证管线消费）；动态约束生成运行时检查（避免“证明不了也不不报错地”）。与 .corespec 前置条件映射（一条语法，两层消费：checker + VC）。
6. 泛型 = 编译期接口具体化：类型参数即“实现了某接口的具体类型”，声明处接口绑定加实例化检查，不做运行期字典。

### 自动推导（7-13）

7. 宽度移出语言：见 TODO `width-out-of-language`（单标签单范式；机器形状归 hw-map）。语言侧清理（T_INT_I8.. 死条目移除、`_f32/_f64` 后缀死路径、`1_000` 两编译器分歧复核）可立即做；v6 编码层宽度由目标自动决定。
8. 类型标注自动：子类型关系自动判定（集合包含）；枚举自动化为联合类型（`int | string`，穷尽性 = 补集空性检查）；可选/可空是联合类型的副产品（`Node?` = `Node | Null`）；类型等价自动（双向包含）；元组/记录 = product 自动组合；数组/切片 = 序列接口 + 元素接口 + 长度值约束（F11 长度走 where 三档语义）；转换 = 集合包含判定（provenance/asp 维度归 hw-map）；借用已经自动（逃逸检查是 pass，释放是 arena，用户零标注，Rust 的 `&`/`&mut` 标注体系在 Core 中不存在）。
9. 借用收缩而非取消：借用检查职责分三部分。逃逸安全由 RegionCheck pass 替代（可判定、成本低，保留）；释放安全由 arena 结构性消除（不需要）；并发共享需要在借用或验证中二选一（多 M 未验证，这里必须有一个机制，是唯一尚未确定的地方）。完全验证化替代借用会再记一笔必须偿还的代价（VC 不一定能证明，借用永远可判定）。保留可判定的逃逸 pass 作为默认，验证处理借用覆盖不到的共享。
10. 递归类型隐式化：递归 = 注册表引用图上的环，环检测自动（无 `rec` 关键字）；值递归自动拒绝（无限大小导致编译错误，这是唯一必须存在的规则）；引用递归自动支持（大小固定）；归纳原理自动派生（VC 消费）。CDuce 已证明语义子类型中递归加子类型判定可判定。
11. 函数类型隐式化：函数 = 子图（region，机制已有：arena 绑定、callee 内联、region 实例化）；函数类型 = 子图端口签名自动派生；函数值 = 子图引用（`@addr` 机制已有）；高阶参数 = 签名（不是独立的“函数类型”概念）；闭包（捕获环境）后置，从纯引用开始。规约挂在子图接口上，VC 自动生成。
12. 接口声明自动（用法驱动推导）：接口 = 用法集合，函数体对参数的操作和字段访问自动构成参数的接口（约束推断路线，qualified types / HM(X) 家族理论）；调用点自动检查。可读性对策：coreview 显示推导出的接口视图（扩展“源码与图双向高亮”）；报错时机：全推断的错误在调用点报告（图到源码的映射缓解）。
13. 显式性最小集 = where 值约束：语义层不能自动（`b != 0` 是语义属性，用法推不出来，它本身就是验证内容，是 .corespec 的语法入口）。返回类型可推断，是否保留可选。

### 边界（14）

14. 声明式边界：声明式上限（类型、契约、验证）加命令式下限（执行、副作用、内存），两者共用一张图（数据依赖是声明式，状态依赖是命令式：state edges / region / 调度）。8 项验证清单第 8 条（格层不重新引入顺序执行）即此边界。声明式化是验证的必要条件（验证器只能消费声明），不是风格选择；执行层必须保持命令式，否则内核路线（HIC/crasm/MMIO）会偏离。

### 明确不做

- 完整接口一等化（存在类型/运行期字典）：推迟到平台桥或 hw-map 实施时做受限接口值
- “不需要类型系统”（全动态化）：已被实证为危险（ASE 2024：3 万仓库，无检查集成导致 type confusion）
- HKTs（高阶泛型）

## 二、设计推理

- 单范式原则：一个概念树（接口）贯穿原语到用户类型，没有第二标签范式、没有第二类型体系。
- 语义保持：图保留一切，类型、接口、契约全部是可以从图推导的投影。标注可以自动算出，用户不需要标注（这是自动化原则的来源）。
- 数学语义：int 无上限，dex 精确，二者都是公理化接口加原生实现，原语语义也可以对照验证（CompCert 精神推广到原语层）。
- 与既有定案一致：M1（身份 = 图节点）、无方法 = 标注、授权归治理层、8 项 Graph 到 Lattice 验证清单。内存模型 v4 已是图本体，类型系统在同一层补充一致性。
- 接口 = 信息 + 规则：节点上存储的标注（附加信息）加解释标注的规则（良构性规则在验证 pass，公理在规约层）。
- 先例形态：Verus / Dafny / F* = 声明式规约加命令式代码。Core 的不同之处：契约层和实现层共用同一张图（语义保持区别于所有先例）。

## 三、损失账本（必须显式偿还的代价）

| 损失 | 说明 | 偿还方式 |
|------|------|---------|
| 构造期的循环依赖 | 图构造需要类型来选择操作，类型又依赖图分析 | 临时标注，事后验证，重新发射（现有管线已是此形态，本次显式化） |
| 报错时机 | 全推断和用法推导缺少标注时，错误在调用点报告而不是声明处 | 图到源码映射，LSP 基建（已在建），参数标注可选保留 |
| 枚举穷尽性 | match 覆盖检查属于类型层性质 | 由集合论类型补偿（第 5.2 节） |
| 变型/子类型规则 | 接口需要显式变型规则，否则会留下不报错地的健全性漏洞 | 语义子类型可判定化（第 5.2 节） |
| 健全性定理 | 不再从标准类型系统继承 | 变为验证管线的证明义务（语义保持项目本来也要证明） |
| 类型级结构信息不报错地丢失 | 忘记重新编码的信息会被不报错地丢弃（有重演 dex 问题的风险） | 显式设计“标注加公理”的防漏清单 |
| 验证化替代借用的可判定性 | VC 不一定能证明，借用永远可判定 | 保留可判定的逃逸 pass 作为默认，验证处理高级共享 |

## 四、演进顺序（每一步建立在前一步之上）

1. where 值约束（验证切片的语法入口）
2. 泛型 = 编译期接口（第 1 层，成本低）
3. 验证切片（支持主线：规约，VC，自动证明）
4. v6 格形态（IR 根基改造）
5. 类型概念收敛（自动推导全量实施，远期，不改动根基）

约束：两条根基改造（v6 与类型收敛）不得同时进行，交叉区域是 checker/ir_gen 的全部。

## 五、学术支撑（前沿对照）

### 5.1 论文地图

| 支柱 | 论文 | 印证/提示 |
|------|------|----------|
| 图本体 IR | [R-HLS（IEEE 2024 / arXiv 2408.08712）](https://ieeexplore.ieee.org/document/11126294)：RVSDG dialect，region + state edges + 内存消歧 | HDFG 设计在硬件综合领域独立平行出现 |
| 接口统一 + 图验证 | [Webs and Flow-Directed Well-Typedness（PLDI 2025）](https://pldi25.sigplan.org/details/pldi-2025-papers/31/Webs-and-Flow-Directed-Well-Typedness-Preserving-Program-Transformations) | “生产者/消费者必须就接口达成一致 + 统一化类型分析”是定案 1/2/4 的平行印证 |
| 图 IR 形式语义 | [Denotational Semantics of SSA（2024，Lean 机械化）](https://www.emergentmind.com/papers/2411.09347) | 图 IR 获得形式语义基础，是语义保持的学术形态 |
| 接口自动推导 | qualified types / HM(X) 约束推断家族（Jones） | 用法驱动接口推导的成熟理论 |
| 精化类型/易用验证 | [Flux（UCSD）](https://comunicaciones.dcc.uchile.cl/events/310-charla-flux-ergonomic-verification-of-rust-programs-with-liquid-types/)（liquid 推断）· [DML index-sensitive（ECOOP 2026）](https://drops.dagstuhl.de/storage/00lipics/lipics-vol372-ecoop2026/LIPIcs.ECOOP.2026/LIPIcs.ECOOP.2026.pdf)（索引敏感嵌套数组 = F11 方向） | where 值约束和推断验证路线成熟 |
| 系统级验证 | [Verus（SOSP 2024）](https://dl.acm.org/doi/10.1145/3694715) | 验证管线工程化前沿 |
| 健全性成本 | [Generic Refinement Types（POPL 2025）](https://dl.acm.org/doi/10.1145/3704885) · RefinedRust（Coq 机械化） | 必须偿还代价的量化证据 |
| 借用替代：区域 | [Tofte-Talpin region inference](https://cristal.inria.fr/attapl/emlti-long.pdf)（Cyclone 线） | arena 模型的历史来源，无借用规则的区域安全 |
| 借用替代：自动 RC | [Perceus（PLDI 2021）](https://pldi21.sigplan.org/details/pldi-2021-papers/7/Perceus-Garbage-Free-Reference-Counting-with-Reuse) + [FP²（ICFP 2023）](https://icfp23.sigplan.org/details/icfp-2023-papers/10/FP-Fully-In-Place-Functional-Programming) | 无 GC、无借用规则的自动内存管理（Koka 生产级） |
| 借用替代：验证 | [Verus linear ghost types（OOPSLA 2023）](https://2023.splashcon.org/details/splash-2023-oopsla/11/Verus-Verifying-Rust-Programs-using-Linear-Ghost-Types) | 反向观察：线性/借用是验证的工具而不是负担，ghost 权限可以证明借用规则覆盖不到的共享 |
| 内存 provenance | [CHERI C 形式化（ASPLOS 2024）](https://www.semanticscholar.org/paper/Formal-Mechanised-Semantics-of-CHERI-C%3A-Undefined-Zaliva-Memarian/606074ae655cbd43468b080e8ae35dde827ff395) · [时态安全（CPP 2025）](https://www.research.ed.ac.uk/en/publications/a-cheri-c-memory-model-for-verified-temporal-safety/) · [ISO TS 6010:2025 provenance-aware memory model](https://www.cl.cam.ac.uk/~pes20/papers/topic.Cerberus.html) | 指针模型与 ISO 标准方向一致 |
| 整数与指针 | [双非确定性内存模型（2024，已集成 CompCert）](https://lib.pusan.ac.kr/lawlib/resource/e-article/?db_id=edskci&mod=detail&page_number=1&record_id=edskci.ARTI.10554258) | asp=1（整数转指针标记）的同题前沿解 |

### 5.2 缺口补偿图

| 缺口 | 补偿 | 怎么补 |
|------|------|--------|
| 枚举穷尽性 | 语义子类型/集合论类型（[Frisch-Castagna-Benzaken, JACM 2008](https://www.lri.fr/~benzaken/papers/semantic_subtyping.pdf)）：类型 = 值的集合，union/intersection/negation，子类型 = 集合包含，可判定 | 穷尽性 = 集合运算；match 覆盖可判定（CDuce typecase 先例） |
| 变型/子类型 | 同上（子类型可判定）加 [行多态（Rose POPL 2019 泛化；POPL 2026 行多态 + type classes + Lean 4 机械化）](https://dl.acm.org/doi/full/10.1145/3776662) | 结构、约束和机械化健全性的完整形态 |
| 递归类型 | 同上（CDuce 已证明递归加子类型可判定） | 环检测自动，值递归拒绝，归纳原理自动派生 |
| 健全性债 | [Gradually Typed Languages Should Be Vigilant!（OOPSLA 2024）](https://dl.acm.org/doi/full/10.1145/3649842) | 判断“静态系统真的被强制执行”的精确语义检查（vigilance） |
| 无类型系统的设想 | [Typed and Confused（ASE 2024）](https://conf.researchr.org/details/ase-2024/ase-2024-research/149/Typed-and-Confused-Studying-the-Unexpected-Dangers-of-Gradual-Typing)：3 万仓库实证 | 无检查集成导致 type confusion 攻击的实证证据 |
| 决议机制 | [POPL 2026 elaboration 健全性](https://dl.acm.org/doi/full/10.1145/3776662)（源到目标演算，Lean 机械化） | 约束决议编译有机械化样板 |
| 子类型表达力边界 | [Structural Subtyping as Parametric Polymorphism（OOPSLA 2023）](https://scirate.com/arxiv/cs.PL?date=2023-05-07&range=31#3) | 全子类型不可编码为多态，接口系统子类型需要自备机制 |

### 5.3 战略定位

- PLDI 2025 Webs 是“接口统一 + 图验证”的独立平行印证，说明方向处于当前编译研究前沿，不是空想。
- 语义子类型是完整解：“类型 = 值的集合”与本备忘“类型 = 图上约束信息”同构，标注的语义解释有现成数学，同时解决穷尽性、子类型、递归、等价、报错质量（非空反例给出具体值）。
- 自动化原则有成熟论文基础：约束推断（qualified types / HM(X)）已有半个世纪的研究；CDuce 递归可判定；Perceus 提供无借用的自动内存管理。每一项“自动”都有成熟先例。
- 借用收缩而非取消：arena 加逃逸 pass 已替代大部分场景；唯一未确定的是并发共享（多 M），需要在借用或验证中二选一，这是后续设计决策点。
- ISO TS 6010：provenance 已进入 C 标准路线，“指针模型与标准方向一致”可以作为资助材料的有力论据。
- ASE 2024 是对“不需要类型系统”最直接的实证反驳。

## 六、关联

- TODO.md：`type-system-direction`（本备忘挂账条目）、`width-out-of-language`、`dex-precision`、`apx-degrade`
- docs：`memory-model.md`（能力 + 格 v4）、`pointer-model.md`、`docs/archive/2026-08-27-lattice-form-ir-design.md`（格形态 v6）
- 本备忘的定位：类型系统增强总纲（14 条定案），后续实现以本备忘和 TODO 挂账为准
