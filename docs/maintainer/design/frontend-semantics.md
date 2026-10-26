# Core 前端语义设计

> 定位：受众 = maintainer；状态 = active（设计基线，部分实现）；出处 = 本页与相关设计文档。
> 范围：类型项、推断、接口、可选/文本、数值、模式匹配、效应、并发、内存、未定义行为、模块、错误、FFI、规约、全局一致性。
> 不包含：编译器后端正确性证明、优化正确性证明、文档与实现逐条审计、测试覆盖。

## 概述

Core 前端以 HDFG 为唯一真相源。类型是图节点上的标注，类型推导是图推导的一种，接口是图上的契约。前端不建立独立于图的类型环境，也不把类型系统作为第二个语义来源。

`.ccr` 是 corec 到 corearch 的稳定契约。类型系统实现可以替换，但 `.ccr` 的结构和语义必须保持；语义升级必须显式升版本。

## 总则

1. 图是本体。节点、边、区域、条目和证据都来自图。
2. 类型是图上的抽象标注。具体路径、资源、并发和全程序事实由各自的图 pass 处理。
3. 类型层只保留可判定、可组合、可单独编译、可信息隐藏的值和接口抽象。
4. 表面语法参照 Core 的现有设定。Core 没有显式泛型参数或类型实参语法。
5. `.` 和 `auto` 是编译器补全占位，用于类型位置。每个 `.` 初始是独立未知类型，由上下文和程序关系约束。
6. 函数类型是 effect-opaque。effect、region、ownership 不进入函数类型。
7. 未知和不可判状态不得当作成功。`Unknown`、`Unsupported`、`-1` 必须显式传播。
8. McTT 是最终验证信任根。类型系统 soundness 不在 McTT 内核中被自动证明；信任边界必须写明。

## 类型项与子类型

### 递归类型

- `μX.τ` 使用等递归语义和 regular tree。
- 良构性要求闭合、正性、守卫性，以及递归经过 `ref`、`ptr` 或装箱。
- 有限数据使用最小不动点。
- 子类型使用余归纳假设集；展开 μ 后命中假设即为成立。
- `μX.X`、`μX.¬X`、`μX.(X∪τ)` 等无守卫或非单调递归在构造期拒绝。
- 需要无限数据时另加 `ν`，不把 `ν` 塞进 `μ` 的核心。

### 否定与补集

- 核心类型项采用 Boolean algebra：支持 `∪`、`∩`、`¬` 和等递归类型。
- 默认实现使用 BAS 风格的集合语义。
- 受限否定保留为可判定子集：`¬μ`、`¬函数`、`¬接口` 不能编码时输出 `Unsupported` 或验证义务，不能静默通过。
- 类型项、判定和序列化使用稳定的 TypeTerm 接口；BAS 内部状态不进入 `.ccr`。

### 变型

- product/struct：只读字段协变，可变字段不变。
- sum/enum：只读 payload 协变，可变 payload 不变。
- sequence/array/slice：只读视图协变，可写视图不变。
- `ref T`：不可变引用协变，可变引用不变。
- `ptr T`：不变。
- 函数类型：参数逆变，返回协变。
- 接口方法：按签名变型，接收者模式参与。
- named/generic：名义身份加声明变型。
- 只采用声明点变型；默认不变。

## 函数

- 函数类型是子图端口签名与值集合的双视角。
- 类型层使用函数值集合语义；运行时不假设已有一等函数值。
- effect、region、ownership 不进入函数类型。
- 高阶参数使用签名；不做 HKT。
- 函数值和闭包暂缓；`@addr` 加整数可表达函数地址。
- McTT 只验证不变片段或编码后的契约；函数逆变是类型层规则，不在 McTT Pi 中直接检查。

## 接口与满足

- `interface` 是命名契约；`impl` 是图上的满足证据边。
- 命名接口的权威证据是显式 `impl` 边，或图 pass 物化出的唯一推导边。
- 推导接口是函数体和用法产生的局部 shape，直接由结构证据满足。
- 推导接口可以提升为命名接口；命名接口不做隐式结构 fallback。
- `iface_satisfies` 返回证据或义务，不返回裸布尔值。
- 命名接口的 `(interface, type)` 只能有一个权威证据；冲突不可合流时图为不良构。
- 孤儿规则表现为证据边的归属和可见性。
- 方法满足检查端口签名包含、接收者模式和契约。
- `impl` 只能实现接口声明的方法；固有方法放在类型自己的实现中。
- 不支持 specialization、negative impl、裸类型变量 blanket impl、接口继承、default method、associated type、泛型方法和 `Self` 类型。
- 不支持 `dyn I`、接口值、存在类型和运行期字典。运行期多态使用 `dyn`、标签或枚举。
- 同一方法名来自多个接口时需要显式限定，否则是歧义错误。

## 推断与多态

- Core 没有 `<T>`、`[T]` 或显式类型实参语法。
- `.` 和 `auto` 是编译器补全占位。每个占位是独立未知类型。
- `typeof(x)` 表达同一类型关系，不引入类型参数。
- 函数体对参数的操作、字段访问和调用关系形成约束；编译器据此自动泛化。
- 推断是图上的约束生成和求解。`constrain`、`solve`、`generalize` 是工程拆分，不是独立语义层。
- 推断接口：

```text
infer(graph) -> Solved | NeedAnnotation | Ambiguous | Unknown
```

- `Solved` 必须满足图约束。
- `NeedAnnotation` 不得猜默认类型。
- `Ambiguous` 不得选择候选。
- `Unknown` 不得当作成功。
- 不允许隐式接口搜索。
- 自动泛化只在约束可解时发生；方案由推断变量和约束生成，不引入源码级类型参数。
- 类型推断的代数实现可替换；MLstruct 风格 Boolean algebra 是首选，局部/双向推断作为补全和回退。
- `MAX_GENERICS` 之类的固定上限是内部护栏，不是语言语义。

## 可选与文本

### 可选

- `T? = T ∪ Null`。
- `none` 是唯一空值关键字；大写 `None` 是普通标识符。
- 普通 `T` 值直接属于 `T?`，不使用 `Some` 包装。
- `T?? = T?`；需要嵌套可选时使用独立的用户定义类型，不引入内建 `Option<T>`。
- `T?` 对 `T` 协变。
- `T?` 不自动满足命名接口；需要 `T <: I` 且 `Null <: I`。
- 有值类型使用 tag；指针和引用可以使用 null niche；不得出现裸值与包装对象双表示。
- 模式匹配中 `none` 覆盖空值；非空分支的类型精化规则必须一致。
- 不支持字节索引、`s[i]` 返回整数、`char` 类型、`u8` 前端类型或 `*char` 前端类型。

### 文本

- `string` 是有限 Unicode 标量序列。
- UTF-8 是编码层，不是前端类型语义。
- 删除 `char` 类型；`'x'` 是长度为 1 的 `string` 字面量。
- `s[i]` 返回长度为 1 的 `string`；索引单位是 Unicode 标量位置；越界是错误。
- `len(s)` 返回 Unicode 标量数量；字节长度属于编码层。
- NUL 是普通 Unicode 标量，不是字符串终止符。
- 字符串相等是标量序列相等；不自动做 Unicode 规范化。
- 字素簇和规范化由库处理。
- C 字符串和 `*char` 由 FFI 映射层处理；前端不出现 `*char`。

## 数值

- `int = Z`，任意精度整数，不溢出。
- `dex` 是任意精度十进制。
- `apx` 是 `dex` 的近似标注，不是类型或值域。
- 整数运算使用数学语义；除零是运行期错误。
- 前端没有宽度、回绕、溢出或机器字概念。
- ABI 宽度、立即数、BigInt、binary64 和 FFI 边界属于映射层。
- 不引入隐式数值提升；转换显式。
- `int -> dex` 是精确注入；`dex -> int` 使用显式规则。
- `apx` 只授权后端近似；优化器不得自行扩大近似范围。

## 模式匹配

- 模式表示值集合；穷尽是并集等于值域；冗余是被前序覆盖。
- 支持 `_`、绑定、整数字面量、字符串字面量、bool、unit、枚举、tuple、struct、`T?` 的 `none`。
- 不支持 char 模式、字节模式、guard、range 或 or-pattern。
- `|` 是 match arm 分隔符，不是 or-pattern。
- 无限域 `int` 和 `string` 必须有 `_` 或绑定。
- `T?` 需要 `none` 加非空分支；非空分支的类型精化必须一致。
- 空枚举和 `never` 使用零 arm 即穷尽。
- 冗余 arm 是硬错。
- 字符串、struct 和 tuple 模式必须有实际判定路径；不得静默命中首个 arm。
- 标准接口：

```text
coverage(scrutinee, arms) -> Exhaustive | Missing | Redundant | Unknown
```

- `.` 在进入 coverage 前已被补全；`_` 归一化为值域全集。
- 决策 DAG 由 pattern matrix 和类型项生成，保持首匹配语义。
- `.ccr` 的 CASE 段记录分支、判别式和默认路径；`.cir` 缓存必须包含 CASE 信息。

## 效应与纯度

状态：草案。以下为当前基线，不是完整定案。

- 效应、纯度和 state 是图事实，不是类型语义。
- `purity_op_effect` 是 effectful opcode 的单一依据；新增 opcode 必须同步。
- 纯度使用 `compute_all_purity` 和 `fi_ispure`；不使用第二套启发式。
- state edge 使用 DFEdge `kind=1`；来源是副作用序列和循环终止依赖。
- 当前 state 链每个函数重置，跨函数不连接；跨函数连接是待补缺口。
- `effect` 轴和 HIT 副作用类 `pure`、`effect`、`volatile` 是既有定义。
- 不新建 `EffectAtom`、`EffectSummary` 或 `PurityFacts` 语义本体。
- 效应查询接口：

```text
effect_of(graph, node) -> pure | effect | volatile | unknown
purity_of(graph, function) -> pure | effect | volatile | unknown
state_chain(graph, function) -> [DFEdge kind=1]
effect_equiv(a, b) -> bool | unknown
```

- `.ccr` v10 没有 EFF 段；效应事实从既有 NOD/EDG/ENT/REG 推导，新增持久化字段需要升版本。

## 并发

- 未显式声明的调度差异不得改变值、效应、控制去向、终止类别和预算向量。
- 默认 share-nothing；没有跨执行体的共享可变状态。
- 源语言没有 lock、mutex、atomic 或 ownership 语法。
- 传输 primitive 是 MOVE、LOAN、SPLIT、FILL、COPY；STREAM 是调度策略，SHARE 不是 primitive。
- 未声明的冲突访问是数据竞争，拒绝编译。
- 显式 `race(k)` 和 `select_any` 的结果集必须确定；不可枚举时高安全模式拒绝。
- 弱内存映射必须保持 race-free 程序的顺序一致性观测。
- G 级弱公平；全部阻塞且无外部事件属于 nontermination。
- 默认路径没有用户数据锁；实验 shared mapping 的内部同步只在映射层，必须证明观测等价和无死锁。
- `select` 首版即 W2：未标注的 `select` 拒绝；不保留“最早到达”语义。
- 多 M 启用前必须完成 wait list 无锁正确性验证；channel 强制 SPSC，直到有无锁 MPMC 实现。
- 跨执行体消息使用子区域或句柄加值移动。

## 内存、区域与指针

- 存储语义的本体是存在格；缓存、寄存器、RAM、VRAM 是映射实例。
- 存在结构使用 ENT、NOD、REG：
  - ENT 记录条目、版本、存在区间和 home；
  - NOD 记录图事件和数据边/state 边；
  - REG 记录区域嵌套和条目范围。
- 区域是图绑定的字节域，不是词法作用域；arena 使用 bump 分配。
- 区域支持 split、merge、share 和 outlives。
- 指针安全由 PointerAnalysis、RegionCheck 和 ProvenanceVerify 三个 pass 负责。
- 字节权限只有两个独立位：`readable` 和 `writable`。
- 权限状态是 `none`、read-only、write-only、read-write；只允许下降。
- 可执行属性不是字节权限；可执行代码必须可读。
- `Nonempty`/`Empty` 归 ENT/REG；`Freeable` 归区域所有权；`shared`/`volatile` 归区域、effect 或 HIT。
- 当前实现差距包括参数逃逸、流不敏感 points-to、byte permission 和 split/merge/share。

## 未定义行为

- Safe Core 不声明 UB。
- 部分操作只能产生编译期拒绝、运行期 trap 或显式 nontermination。
- trap 是定义行为，不是 UB。
- 整数除零和模零是运行期 trap。
- 越界访问是静态拒绝或运行期 trap。
- `null` 解引用只在 unsafe/FFI 边界；`T?` 使用 `none`。
- 未初始化读在 safe Core 中拒绝；分配块零初始化。
- 移位使用数学语义；编码无法实现时 trap 或拒绝，不静默使用机器掩码。
- 未对齐访问在 safe Core 由布局保证；raw/FFI 未对齐属于边界契约。
- 数据竞争按并发规则拒绝或显式声明。
- FFI、asm 和外部指针属于信任边界。

## 模块与单独编译

- 模块身份是项目名加模块路径。
- 顶层声明默认属于当前库内部；跨库导出使用 `pub`（函数/全局尾部标签，类型尾部 `, pub`（`struct S, pub:` / `enum E, pub:` / `interface I, pub:`；`pub struct` 前缀仅兼容旧源））。
- `pub` 出现在函数、类型和全局声明上时表示跨库导出；未标记的顶层声明只在所属库内可见。
- 模块依赖图必须是无环 DAG；循环导入拒绝。
- 初始化顺序按模块依赖拓扑序；循环初始化拒绝。
- 模块摘要包含模块 ID、依赖、全部顶层导出、签名/类型/接口、错误摘要、效应摘要、初始化依赖、FFI 边界和摘要哈希。
- v1 的前端单独编译只生成模块摘要；最终仍构建全程序 HDFG 和 `.ccr`。
- 不定义跨模块 points-to/region graph fact ABI；这些事实在链接后的全程序图上重算。
- 模块摘要缓存键包含编译器版本、配置、源哈希和依赖摘要哈希。
- 全程序图缓存键包含全部模块源或函数体哈希。
- 缺失摘要、重复模块、重复符号和摘要版本不匹配都拒绝。

## 错误处理

- 函数状态使用 `Ok` 和 `Err`。
- `return value` 等价于 `Ok value`。
- `return Err error` 是错误状态。
- 删除 `fail`、`try`、`fallback`、`Result<T,E>` 和错误传播 `?`。
- 错误值是普通值：枚举、字符串、结构体等；没有统一 Error 基类。
- `catch:` 保持后置形式，只处理紧邻表达式的错误范围。
- `catch` 模式匹配错误值，不匹配 `Err` 包装。
- 成功值直接通过；未匹配错误继续传播。
- handler 内 `return Err e` 重抛。
- 错误集合自动推断：`Err` 加入类型，调用加入被调函数错误集合，`catch` 移除已匹配错误。
- 有限错误集可检查覆盖性；开放错误必须有 catch-all。
- `main` 未处理错误运行期 abort。
- 顶层声明默认属于当前库内部，外部不可见；跨库导出使用 `pub`。
- V4 语法文档和 EBNF 已同步；LEXER、parser、checker 的 Ok/Err 和 catch 语义仍待实现。

## FFI、ABI 与 dyn

- 前端只使用 Core 类型；不出现 `i32`、`u8`、`f64`、`char`。
- ABI 映射层负责宽度、寄存器、栈、对齐、结构体传值和 variadic。
- 超出机器表示或 ABI 参数上限是硬错。
- `@ffi` 只描述编组，不引入第二套类型系统。
- FFI 错误进入 `Err` 摘要；编组失败也是错误。
- `extern` 不默认 pure。
- 所有权由图内 provenance、region、liveness 和 escape 自动判断。
- 外部指针和 FFI 返回值没有图内 provenance，属于信任边界，必须走 unsafe、alloc_at 或边界契约。
- 无法证明时拒绝或返回 `Unknown`。
- `dyn` 是编译期类型集合或静态 union，不是运行时 tagged value。
- 图内全知；转换和分派在编译期完成；运行时使用具体类型原表示。
- 不支持运行时 tag、vtable、boxing 或 16 字节 `(tag, value)` 对。
- 类型集合未知或开放时编译错误或 `Unknown`；不得回退到运行时 dispatch。
- 旧 `IR_DYN_PACK` 和 `IR_DYN_DISPATCH` 的 tagged 表示不是 dyn 语义。
- FFI 边界的 `dyn` 是外部 opaque 句柄，由 ABI 映射层编组，和内部编译期 dyn 不混用。
- `@` 内建统一分类为查询、编译控制、映射控制和边界；用户不可定义 `@`。

## 规约与验证

- 规约使用 `#check`、`#ensure`、`#invariant`、`#variant`。
- 不引入 `where`。
- `spec fn` 退役；普通 `fn` 在纯、终止、可判定时可作为检查函数。
- `#` 标注不改变运行时语义。
- 义务类型是 `Encoded`、`Axiom`、`External`、`Unsupported`。
- McTT 是最终信任根；CIC 不是。
- `.csr` 是规约约束 sidecar，不改变 `.ccr`。
- VC 状态是 `proved`、`unproven`、`failed`、`unsupported`。
- `#check(常量假)` 是硬错；默认未证不阻断，strict 模式阻断。
- SMT 只作搜索器；证书能编码时由 McTT 检查，否则登记 `External`。
- 循环和递归必须有结构递减或 `#variant`；推导失败是 `Unsupported` 或编译错误。
- FFI 外部实现不证明；只检查 IO 契约合法性，外部实现登记为 `Axiom` 或 `External`。
- `docs/maintainer/design/spec-design.md` 是本节的详细设计。

## 全局一致性

- 不声称全局 soundness theorem 已证明。
- Safe Core 的目标是：被接受的程序不因类型判定错误产生 UB；部分操作只产生已定义的 trap 或 nontermination。
- `never` 是底类型：`never <: T` 恒真；`T <: never` 仅 `T = never`。
- `bool` 和 `int` 不同；`if`、`while` 条件只接受 `bool`；取消 `bool ⊆ int` 隐式。
- `&x` 和 `&mut x` 产生引用；`*T` 是原始指针；REF 和 PTR 不隐式互转。
- `*T` 形参必须解析为指针，不得退化为 `unit`。
- 类型判定严格三态；`-1` 不得当 0 或 1；`-1` 触发 `ICE04` 或显式 `Unknown`。
- 除声明的子类型和显式转换外，不自动转换。
- checker 和类型引擎对同一判定不得给出相反结论。
- 信任边界包括 McTT、parser/checker、`.ccr`/`.csr`、后端、runtime、FFI/asm 和显式公理。自举 stage2 与 stage3 相同只是经验证据，不是 soundness 证明。

## 实现状态

| 区域 | 状态 |
|---|---|
| 类型项、BAS、μ | 部分实现；`never` 和 μ 良构性未完成 |
| 函数类型与变型 | 设计基线；函数值未实现 |
| 接口与 coherence | 设计基线；`pub` 可见性未实现 |
| 推断与自动泛化 | 设计基线；推断接口未实现 |
| 可选与文本 | 方向确定；`char` 迁移和 bootstrap 未完成 |
| 数值 | 语义确定；dex 任意精度未实现 |
| 模式匹配 | 设计基线；字符串/struct/tuple 模式未完整 |
| 效应与纯度 | 草案；跨函数 state 链未连接 |
| 并发 | 设计定稿；merge/select 未实现 |
| 内存与区域 | 部分实现；参数逃逸、权限、split/merge/share 未完成 |
| UB | 分类基线；部分 opcode 未同步 |
| 模块 | 设计基线；源码拼接仍存在 |
| 错误处理 | 语法文档已同步；实现未同步 |
| FFI/dyn | 边界基线；旧 dyn 路径未清理 |
| 规约 | 设计基线；McTT 翻译/SMT/.csr 未实现 |

## 不包含

- 编译器语义保持证明。
- 优化 pass 正确性证明。
- 后端编码正确性证明。
- 文档与实现的逐条审计。
- 测试覆盖和 canary。

## 未决问题

1. 类型推导的 principal 性边界和自动泛化范围。
2. 接口推导证据与命名接口提升规则。
3. `.ccr` 的只读/可写视图编码。
4. McTT 的 BAS/十进制/结构体/枚举编码。
5. 跨函数 state 链和 effect 等价。
6. 多 M、SPSC 强制和锁-free MPMC。
7. 字节权限的持久化表示。
8. 模块摘要的 `.ccr` 字段和缓存边界。
9. 错误处理的实现落地和 extern 错误契约。
10. FFI 所有权边界和 ABI 映射表。

## 参考

- `docs/developer/syntax.md`
- `grammar/core.ebnf`
- `docs/maintainer/design/spec-design.md`
- `docs/maintainer/design/memory-model.md`
- `docs/maintainer/design/materialization-space.md`
- `docs/maintainer/design/region-model.md`
- `docs/maintainer/design/pointer-model.md`
- `docs/maintainer/design/execution-model.md`
- `docs/superpowers/specs/2026-09-17-concurrency-model-design.md`
- `docs/superpowers/specs/2026-09-11-merge-semantics-design.md`
- `docs/superpowers/specs/2026-10-23-lattice-ccr-v10-design.md`
