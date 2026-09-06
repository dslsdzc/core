# Core 规约系统设计（v2 — CIC 内核 + SMT 证书架构）

> 定位：受众 = 维护者；状态 = active

> 规约 = 图上的约束。表达力 = CIC（归纳构造演算）。自动化 = SMT 证书外包。

## 一、哲学

Core 的语义中间表示是HDFG（`.cir`），图穷尽了程序的全部语义。规约不是对代码的"另一套描述"，而是**图上的约束标注**。

```
# 正常编译（无规约）
corec build file.cr         → .cir + .ccr

# 编译 + 规约
corec build file.cr -s      → .cir + .ccr + 自动生成 file.csp → .csr

验证 = 证明图的所有可达状态满足图上的约束。
```

## 二、架构总览（v2）

规约语言（一套 Core 语法）编译为 **CIC 项**（归纳构造演算），验证走双通道：

```
Core 规约语言（.corespec / .csp / .cr 内联）
   ↓ 编译（翻译桥：命令式 → 函数式）
CIC 项（归纳构造演算——一切表达力：量词/归纳/依赖类型/递归性质）
   ├─ 目标一阶可表达 → SMT 通道（自动求解 + 用户可选 #smt）
   │      → SMT 返回证书（证明轨迹）
   │      → 翻译成 CIC 证明项 → 内核重新验证 ← 健全性永远在内核
   └─ 归纳/高阶 → CIC 内核直接处理
```

**健全性唯一来源是 CIC 内核。** SMT 是证明搜索器（可以凭启发式甚至不健全地猜），其输出必须经内核验证才被接受——证书校验失败即拒绝，绝不引入不健全。这是 SMTCoq 模式（CAV'17，先例）。

### 表达力边界

CIC 提供 Coq 级别的全部表达力，逐项对应：

| 能力 | CIC 承担 | Core 用户付出 |
|---|---|---|
| 全称/存在量词（无限域） | `forall/exists` 是语言一等构造 | 零——量词是规约语言语法 |
| 归纳类型 + 归纳原理 | 枚举/结构体 → 归纳类型，原理在内核 | 零 |
| 递归函数 + 终止性 | 递归定义 + `loop variant` 标注 | 变体标注（EBNF 已有） |
| 高阶量词（∀f: int→int） | 函数空间原生可量化 | 零（规约层函数类型，见 §10） |
| 依赖类型（`Vec n`） | 内核有，**但 Core 不需要** | 被图验证替代：边界安全由图保证，长度性质由谓词表达（`#ensure(result.len() == |a|)`） |
| 引理/定理复用 | 证明项可组合 | 见 §12 用户入口 |

**Core 对依赖类型的替代**：Coq 用 `Vec n` 在类型层面保证索引不越界/长度匹配；Core 里这两个需求已被其他机制消化——索引越界由指针模型图验证保证（已实现），长度性质由谓词表达。安全性由图承担，性质由谓词承担——这就是 Core 不用付出依赖类型学习成本的根源。

## 三、平民化原理

**不需要写公式，不需要学数理逻辑。规约用 Core 语言本身书写。**

规约分三层，同一语言、同一 IR 格式承载：

| 层级 | 写法 | 谁负责 | 例 |
|------|------|--------|----|
| 编译器自动推导 | 零手写，.csr 自动附带 | 编译器（图结构分析） | `#pure`, `#terminating` 等 |
| 简单范围 | 一行 `#check` / `#ensure` | 用户写，编译器验证 | `#ensure(result > 0)` |
| 检查函数 | 用 Core 写一个纯函数 | 用户写，编译器验证 | `spec fn ... -> bool { ... }` |

三个层级最终都编译为 `.cir` 的规约 DFNode（条件表达式）+ `.csr` 的 TagNode（约束元数据），对验证工具无差别。

## 四、文件格式

### `.cr` — 实现源码（也可内联规约）

```core
// 简单的范围
fn divide(a: int, b: int) -> int
    #check(b != 0)
    #ensure(result != None)
{
    if b == 0 { return None; }
    return Some(a / b);
}

// 引用外部检查函数
fn sort(a: [int]) -> [int]
    #ensure(auto::sort_check(a, result))
{
    // 冒泡排序实现
}
```

### `.csp` — 编译器自动生成的规约文件

`corec build file.cr -s` 自动生成 `file.csp`：

```core
// file: sort.csp
// 自动生成于 2026-07-11
// 用户在此文件中手写规约，下次 -s 保留已有内容

// [auto] 编译器自动推导的标签（只读区域）
// #pure  #len_preserved  #terminating

// [user] 用户在此书写规约
#check(/* 用户填写前置条件 */)
#ensure(/* 用户填写后置条件 */)

// 检查函数 —— 用 Core 语言写规约
spec fn sort_check(input: [int], result: [int]) -> bool {
    // 编译器生成的骨架：已从图模式推导部分性质
    // ① 长度守恒（已从图结构推导）
    if result.len() != |input| { return false; }
    // ② 有序性（图有比较+交换模式，但需要用户确认）
    // TODO: 填写有序性检查
    // ③ 排列性质（编译器无法完全推导，需要用户补全）
    // TODO: 填写排列检查
    return true;
}

// 类型不变量
spec fn vec_invariant[T](v: Vec[T]) -> bool {
    return v.len <= v.cap && v.data != null;
}
```

生成规则：
- `-s` 第一次运行：生成完整的 `.csp`，包含所有函数的声明骨架
- `-s` 再次运行：保留用户手写内容，新增函数加入，删除的函数移除
- `.csp` 应该入版本库

### `.csr` — 规约约束的二进制序列化

详见 `docs/ir-schema/corespecir-schema.md`。

```
.csr 文件头 → TagNode 数组 → 符号引用表 → 函数约束映射 → 字符串表
```

每条 `#check`、`#ensure`、`#invariant` 以及每个 `spec fn` 的身体，都编译为 `.cir` 的规约 DFNode（条件表达式）+ `.csr` 的 TagNode（约束元数据：类型、验证状态、行列号）。TagNode 通过 `target_node` 指向 `.cir` 中对应的 DFNode，通过 `condition_node` 指向条件表达式所在的 DFNode。

## 五、编译器自动推导（零门槛的核心）

编译器从 `.cir` 图结构中自动推导性质，写入 `.csr`，不需要用户写任何东西。

### 自动推导的标签

| 标签 | 推导条件（图模式） | 例 |
|------|-------------------|----|
| `#pure` | 无 STORE 到外部变量、无 CALL 到非纯函数 | |
| `#deterministic` | 纯 + 无随机/外部依赖 | |
| `#terminating` | 所有循环有可识别变体 | |
| `#no_alloc` | 无 ALLOC/ALLOC_ARRAY/ALLOC_STRUCT/ALLOC_AT 节点 | |
| `#no_throw` | 无异常路径 | |
| `#safe_index` | 所有索引访问在边界内 | |
| `#len_preserved` | 集合长度不变（无插入/删除） | `sort` |
| `#atomic` | 配对操作之间无并发观测点 | `transfer` |

### 自动生成的检查函数（骨架）

编译器识别常见图模式，自动生成检查函数代码。用户可以在 `.csp` 中 `#use` 或忽略。

```
fn sort(a: [int]) -> [int]
         ↓ 编译器从图模式识别：
  - 只有比较+交换，无插入/删除 → 生成 #len_preserved
  - 有比较→分支→交换结构     → 生成 auto::sorted 检查函数
  - 纯函数                     → 生成 #pure
         ↓ .csr 自动包含
  #pure
  #len_preserved
  #ifdef auto::sorted
  #ensure(auto::sorted(input, result))

fn transfer(from: &mut Account, to: &mut Account, amt: int)
         ↓ 编译器从图模式识别：
  - from.balance 和 to.balance 有配对的加减
  - 无 yield/recv 在加减之间
         ↓ .csr 自动包含
  #atomic
  #ifdef auto::守恒(from, to, amt)
  #ensure(auto::守恒(from, to, amt))
```

用户看到这些自动生成的约束，可以：
- `#use auto::sorted` — 接受
- `#ignore auto::sorted` — 跳过（编译器不再生成）
- `#check(result.len() == |a|)` — 手写更精确的替代

**模式匹配库可扩展**：社区可以贡献新的图模式 → 标签映射，编译器新增推导能力。

## 六、标签语法（标注/annotation）

使用 `#` 前缀，与 `@`（外部项目引用）区分。

```core
// 在 .cr 或 .csp 中使用
fn foo() -> int
    #pure
    #check(x > 0)

// 自定义标签
#tag sorted = {
    forall i: 0 <= i < result.len() - 1 -> result[i] <= result[i+1]
}
```

`#` 风格：
- 更干净，视觉上区分于代码逻辑
- 不占用 `@`（后者保留给 `import @project`）
- 语义清晰：`#` 标记的东西不影响运行时语义

## 七、检查函数（规约的主力）

检查函数是用 Core 语言写的纯函数，返回值是 `bool`。它们被编译为 `.cir` 图，然后与实现函数的 `.cir` 并列供验证器消费。

```core
// 检查函数的语法特征：
spec fn 函签名 -> bool
    #pure  // 编译器自动标注
{
    // 函数体 —— 纯 Core 代码
    // 可以有变量、循环、分支
    // 不能有 IO、unsafe、外部调用
    return true_or_false;
}
```

### 检查函数 vs 普通函数的区别

| | 普通函数 | 检查函数 |
|---|---|---|
| 编译 | 生成代码 | 只生成 `.cir` + `.csr`，不生成机器码 |
| 副作用 | 可有 | 必须纯 |
| 验证角色 | 被验证的对象 | 验证的标准 |
| 调用规则 | 可在运行时代码中调用 | 不能在运行时代码中调用 |

### 纯公式支持

对于习惯写公式的人，提供语法糖：

```core
// 检查函数写法
spec fn all_nonneg(arr: [int]) -> bool {
    for x in arr:
        if x < 0 { return false; }
    return true;
}

// 等价公式写法（编译器展开为检查函数）
spec fn all_nonneg(arr: [int]) -> bool
    = forall x in arr: x >= 0;
```

## 八、量词（v2 新增）

`forall x: int => P(x)` 必须是规约语言的一等构造（**不是** for 循环的翻译）——int 域无限，遍历不了；for 循环只是有限域的便利糖（§7 纯公式支持的 `forall x in arr` 是有限域情形）。

```core
// EBNF 已定义（grammar/corespec.ebnf）
forall (x: int) => x >= 0
exists (i: int) => a[i] == target
```

## 九、翻译桥：spec fn（命令式）→ CIC 项（函数式）（v2 新增）

### 9.1 问题定义：两个语言的语义鸿沟

spec fn 用 Core 书写——命令式：变量重复赋值、循环、数组、`return`。CIC 是纯函数式逻辑：lambda 演算、递归定义、归纳类型、没有赋值没有循环。翻译桥把前者确定性变换为后者，**不丢语义、不加语义**。

可行的根本保障：spec fn 是纯的（project-book："规约表达式限于纯逻辑运算"——无副作用、无 IO、无 unsafe、无外部调用）。纯命令式程序与函数式程序的翻译是经典确定性问题。

### 9.2 结构翻译表（Core 构造 → CIC 构造）

| Core 构造 | CIC 翻译 | 示例 |
|---|---|---|
| `x := expr` / 单次赋值 | `let x = expr in ...` | `total := 0` → `let total = 0 in ...` |
| 重复赋值 `x = expr` | SSA 化 → 递归参数传递 | `x = x + 1` → 递归调用参数 `f(x+1)` |
| `return expr` | 直接表达式化 | 函数体即表达式 |
| `if/else` | 条件表达式（ite/match） | `if b { A } else { B }` → `if b then A else B` |
| `for x in arr` | fold/递归遍历 | `for x in arr: acc += x` → 对 list 递归 |
| `for i in 0..n` | 有界递归（参数递减） | 变体 = `n - i` |
| `loop { ... }` + `break` | 尾递归（需要变体） | 变体标注（EBNF 已有） |
| 数组 `a[i]` 读写 | 归纳列表索引 / 数组理论 select-store | 或带长度约束的结构 |
| 结构体/枚举 | 归纳类型构造子 + match | `Point{x, y}` → `mk_point x y` |
| 递归调用 | CIC 递归定义（良基递归） | `fact(n) = n * fact(n-1)` |

核心模式——循环即递归：

```
for i in 0..n: acc += a[i]
        ↓
f(acc, i) = if i >= n then acc
            else f(acc + a[i], i + 1)     // 变体 = n - i，递减保证终止
```

### 9.3 终止性：变体是翻译的前提

CIC 只接受**良基递归**（递归参数严格递减）——非终止的"递归"在 CIC 里无法定义。因此：

- 每个循环/递归翻译必须携带**变体**（loop variant，EBNF 已有）——递减度量
- 编译器自动推导（§五 的 `#terminating` 图模式）优先；推导不出的要求用户标注
- 无变体的循环 → 翻译失败（编译错误），或降级为未解释函数（用户确认语义）

### 9.4 整数语义：机器整数 vs 数学整数（关键决策）

Core 的 `int` 是无上限数学整数（2026-08-23 修订：i64 快路径 + 溢出自动升级堆上 BigInt，永不溢出——见数值类型设计），与 CIC 整数（Z，无界）语义一致。**翻译桥在 int 上无分歧**；位宽语义只出现在其余场合（dex 定点内部表示、显式位宽标注）：

| 选项 | 语义 | 代价 |
|---|---|---|
| 数学整数（默认） | 规约性质在无界整数上证明 | 简单；但 `#ensure(x + y > x)` 在数学域成立、机器域可能因溢出失败——**证明的结论可能不反映实际行为** |
| 机器整数（位向量） | 精确匹配运行语义（SMTCoq 已支持位向量理论） | 复杂；需要位向量 + 溢出模式建模，证明义务更繁 |
| 混合 | 默认数学整数；位宽相关性质用显式位向量类型标注 | 平衡；用户只对溢出敏感的性质声明位宽 |

**已决（2026-08-16，随数值类型设计 dex/apx 落定）**：默认数学语义（精确——规约性质在无界整数上证明）+ **显式授权机器语义**：`apx` 标签授权后端/验证器采用机器语义（CPU 后端兑现为 binary64 FPU 快路径；验证器据此知道用户允许近似）。原「与内核选择（§十七）一并决策」的捆绑随之解除。

**修订（2026-08-23，随 int 无上限化）**：语言层 `int` 已为无界数学整数（i64 快路径 + 溢出自动升级 BigInt），「机器整数 vs 数学整数」分歧对 int 消解——`#ensure(x + y > x)` 在整数上无条件成立，与规约证明一致；`apx` 的机器语义授权仍适用于 `dex` 及其余显式位宽场合。

### 9.5 实现函数进规约的身份

`#ensure(f(x) == y)` 引用实现函数 f——f 不是 spec fn，是运行时代码。它的 CIC 身份是**语义模型**：

- 函数式子集（纯、可翻译）→ 翻译为递归定义（与 spec fn 同路径）
- 其余（有副作用/未翻译）→ **未解释函数**（Uninterpreted Function）：CIC 只知道签名，不知道定义——性质只能由用户另行声明
- 有副作用/非纯的实现函数不能进规约（project-book 规定）

### 9.6 失败情形（翻译不了怎么办）

| 情形 | 处理 |
|---|---|
| 循环无变体 | 编译错误（要求 `variant` 标注）或降级未解释函数 |
| 数组索引可能越界 | 翻译时插入越界条件（`i < len`），越界路径 → 未定义值（⊥） |
| 副作用/IO/unsafe | 翻译拒绝——规约只能引用纯函数 |
| 溢出敏感性质 | 显式位宽标注（见 9.4） |

## 十、函数类型归属（v2 决策：规约专属）

函数类型在两个层面是两个不同的东西，**必须拆分决策**：

| | 规约层 | 实现层 |
|---|---|---|
| 函数是什么 | 数学对象（映射）——CIC 的 lambda | 运行时对象（代码/闭包） |
| 机制 | 箭头类型 `int -> int` → CIC 原生 | TYP_FN + 闭包/捕获/调用约定 |
| 需求 | 高阶量词 `forall f: int -> int => P(f)` | 函数值编程（map/filter 传函数、回调表） |

**决策：规约专属函数类型。** `int -> int` 只存在于规约语言（`.corespec` 类型宇宙的一部分），直接映射 CIC 箭头；量化的是数学函数，不需要实现层有函数值。零污染 Core 语言（checker/ir_gen/后端/内存模型不动），符合"规约是独立源文件"的哲学。

**实现层函数值（TYP_FN/闭包）按 YAGNI 挂起**：现状 `@addr(f)` + int 能表达函数地址（内核函数表、中断向量表）；闭包与 arena 内存模型（捕获变量归属）交互复杂，无真实用例不做。

## 十一、验证器：CIC 内核 + SMT 证书（v2 新增）

> 内核选型与融合架构的完整论证见 `docs/design/verifier-kernel.md`（理论谱系、2025–2026 论文扫描、融合决策、自举路线）。

### 内核

CIC 类型检查器（Coq 内核级别：约数千行的信任根）。初期绑定成熟实现，后期自举为 Core 版（见 §14 与 `docs/design/verifier-kernel.md`）。

### SMT 通道（证书架构，SMTCoq 模式）

```
目标（CIC 项）
   → 一阶化翻译（数组/算术/UF 理论）
   → SMT 求解器（Z3/veriT/CVC5 类）
   → 证书（unsat 证明/求解轨迹）
   → 翻译成 CIC 证明项（refl/omega/... 构造）
   → CIC 内核重新验证 ← 健全性唯一来源
```

- SMT 不求信任：可以跑不健全启发式，证书校验失败即拒绝
- 用户可**主动选择** SMT：目标标注 `#smt`（hammer 的手动挡）
- 覆盖范围：线性算术、数组边界、位向量、UF——"绝大多数"；SMT 表达不了的目标（归纳/高阶）直接走内核——**表达力边界由 CIC 决定，SMT 只是加速器**

### 反例调试

SMT 解不出时返回**反例模型**（哪个输入违反性质）——开发期黄金能力：`#check(b != 0)` 被违反 → SMT 给出 `b = 0` 的具体反例。验证报告区分三种状态：**绿**（证明）/ **黄**（部分）/ **红**（反例或未证明）。

## 十二、约束的验证与用户入口

验证器（外部贡献）的操作：

1. 加载 `.cir`（程序图）+ `.csr`（图上约束）
2. 从图结构推导自动标签（标签 = 编译器已证明）
3. 对 `#check`/`#ensure`：生成证明义务 → SMT 通道 / CIC 内核
4. 对 `spec fn`：检查实现函数的图是否蕴含检查函数的图
5. 输出：每条约束绿（证明）/ 黄（部分证明）/ 红（反例或未证明）

约束可以同时在开发期插桩运行时 assert 检查，验证器到位前也有保障。

### 用户入口分层（自动化失败时降级，v2 新增）

| 层 | 入口 | 用户要做什么 | 学习成本 |
|---|---|---|---|
| 0 | 默认全自动 | 什么都不做 | 零 |
| 1 | `#induct x` 归纳引导 | 标注"对哪个变量做结构归纳" | 一句话 |
| 2 | `#lemma` 引理拆解 | 写中间性质（Core 规约语言） | 理解"拆解"思维 |
| 3 | CIC 证明项逃逸 | 直接给证明项 | 高（最后手段，对应 unsafe 的位置） |

- 层 1 本质：生成 CIC 归纳原理实例化（基例 + 归纳步两个目标），各回自动化——归纳框架是 CIC 的，步骤求解是 SMT 的
- 层 3 远期演化：Core 自举 CIC 内核成熟后，可变成"用户用 Core 写证明"（Curry-Howard 在 Core 呈现）

### .csr 状态

`.csr` 的 status 字段（0=unproven, 1=auto_proven, 2=user_proven）承接验证结果：

| 来源 | status |
|---|---|
| 编译器自动推导标签 | auto_proven |
| SMT 证书经内核验证 | user_proven |
| 用户入口产物 | user_proven |
| 未证明 | unproven（不拦编译——证明失败 ≠ 程序不安全） |

## 十三、规约的回报：证明驱动的优化（v2 新增）

**写的证明越多，编译器优化越狠。** 规约不只是验证负担——证明过的性质流入优化器，成为激进变换的前提。这是"语义保鲜"的闭环：用户注入的语义（规约）流经验证变成**可证明的事实**，再流进优化器，验证的回报不只是安全，还有性能。

### 机制：证明状态门控的优化信息流

```
用户写规约 → 验证（SMT/内核）→ 状态 proven / unproven
                                    │
                    proven 的性质 ──┼──→ 优化 pass（变换前提）
                    unproven 的性质 ──→ 丢弃（绝不喂优化器）
```

**关键：只有被证明的性质才进优化器。** `.csr` 的证明状态（auto_proven / user_proven）就是优化器的许可证——unproven 的性质可能为假，喂给优化器 = 优化器引入 bug。**证明错误 = 优化错误，门控是机制核心。**

### 收益清单（证明 → 优化映射）

| 证明的性质 | 优化器能做什么 |
|---|---|
| `#check(b != 0)` 已证 | 除法免零检查 |
| `#safe_index` 已证 | DEREF 运行时边界检查（cmp+jae+ud2）直接消除——编译期证明免检的规约版，覆盖运行时数组 |
| `#pure` 已证 | CSE / 死代码删除 / 重排（纯调用可删可移） |
| `#no_alloc` 已证 | 栈分配替代堆分配（区域路径：静态大小预计算 → 纯 bump 零碎片） |
| `loop invariant` + `#terminating` 已证 | 循环变换（向量化/强度削减/展开）前提满足 |
| 指针分离/别名规约已证 | 内存访问重排（否则保守不重排） |
| `#deterministic` 已证 | 更激进的缓存/重算策略 |

### 动机闭环

**规约从"验证负担"变成"性能投资"**——普通程序员为性能写 `#check`/`#ensure`，验证顺手完成。这解决了"为什么要写规约"的动机问题。先例：LLVM 的 `llvm.assume`（用户声明的事实喂优化器）。

### 两个注意点

1. **编译器内部回读通道**：`.csr` 现在只服务外部验证器——需要编译器内部读取已证性质表（管线：编译 → 规约 → 证明 → 已证性质表 → 优化 pass）
2. **证明时效**：代码改动后证明需重验——增量缓存已有函数级 `.cir` 缓存，证明缓存同理

## 十四、完整管线

```
# 编译（无规约）
corec build file.cr
  → tokenize/parse/check/ir_gen/lower
  → file.cir + file.ccr

# 编译 + 规约
corec build file.cr -s
  → tokenize/parse/check/ir_gen/lower
  → file.cir + file.ccr
  → 自动生成/更新 file.csp
      ├── 所有函数的声明骨架
      ├── 编译器自动推导的标签（从 .cir 图结构分析）
      └── 用户上次手写的规约（保留）
  → 解析 file.csp → spec ir_gen → 输出 file.csr
      ├── DFNode[]（指令节点 + 规约约束节点）
      ├── TagNode[]（约束元数据：check/ensure/invariant/标签）
      └── 符号引用表（指向 .cir 中的函数/变量）

# 验证（外部工具）
verify file.csr
  → 加载 .cir + .csr
  → 验证 pending 约束（SMT 通道 / CIC 内核）
  → 输出验证报告（绿/黄/红）
```

编译器输出的 `.csr` 包含：
- 编译器自动推导的全部标签（status=auto_proven）
- 用户写的 `#check/#ensure/#invariant`（status=pending）
- `spec fn` 编译为 spec 图节点（status=pending）

## 十五、信任根与自举路线（v2 新增）

验证的信任根是 CIC 内核——内核有 bug = 一切证明皆空。路线（与 corec 自举同构）：

1. **初期**：绑定成熟内核（候选：Rocq / Lean 4，决策挂起，见 §16）
2. **自举**：有人用 Core 写出 CIC 内核版本 → 替换外部依赖
3. 先例：Coq Coq Correct!（被 Coq 证明正确的 Coq 内核）、Milawa（链式自举：A 验证 B，B 验证 C…，信任降到最小可审计内核）

## 十六、内核场景的应用

普通开发者的代码：编译器自动推导 + 可能几行 `#ensure`。

内核级别的代码：

```core
spec fn pagetable_invariant(pt: &PageTable) -> bool {
    for virt in pt.mappings {
        entry := pt.mappings[virt];
        // 虚拟地址到物理地址的映射
        if entry.present {
            // 物理地址必须在有效范围
            if entry.phys < PHYS_START || entry.phys >= PHYS_END {
                return false;
            }
            // 用户态不能映射内核页
            if virt < USER_END && entry.privilege == KERNEL {
                return false;
            }
        }
    }
    return true;
}

fn map_page(pt: &mut PageTable, virt: Addr, phys: Addr, flags: u64)
    #check(PHYS_START <= phys && phys < PHYS_END)
    #check(virt < USER_END)   // 用户态进程不能映射内核地址
    #ensure(pagetable_invariant(pt))
```

即使在这里，规约还是 Core 代码——变量、循环、分支。不是公式，是你能读也能写的代码。

内核的量词（`for all mappings`）写成了 `for` 循环，编译器把它编译成纯逻辑约束。纯公式语法糖（`forall`）也存在，但只是编译器的展开。

## 十七、实现里程碑（建议）

1. `.corespec` 解析（量词/函数类型/变体）+ 规约类型检查
2. 翻译桥：spec fn → CIC 项（循环→递归、数组→归纳列表）
3. SMT 通道：目标翻译 + 证书校验 + 内核验证（绑定内核起步）
4. 用户入口：`#induct` → `#lemma` → 逃逸
5. 自举 CIC 内核（Core 版）

## 十八、开放决策点（挂起，待外部贡献者参与）

| 决策点 | 状态 |
|---|---|
| **内核选择：Rocq vs Lean 4** |  挂起——两者都是 CIC 类，规约语言/SMT 证书/翻译桥/自举路线不受影响，等社区参与 |
| 实现层函数值（TYP_FN/闭包） |  YAGNI 挂起，等真实用例 |
| 证明项逃逸的最终形态 |  随内核选择与自举进度演化 |

## 十九、总结

```
不需要学新语言 ── 规约 = Core 函数
不需要写公式  ── 编译器从图推导能推导的一切
不需要自己来  ── 剩下的用同一门语言写检查函数
表达力无上限  ── 编译为 CIC，量词/归纳/高阶全在内核
健全性有保证  ── SMT 证书经内核验证，信任根最小化
```

完全形式化的代价被压缩到最低：只有编译器推导不了的函数正确性需要手写检查函数，而检查函数本身也是 Core 代码，不是数理逻辑公式。

## 参考

- **SMTCoq**（Ekici/Mebsout/…, CAV'17）— SMT 证书 → Coq 证明项，求解器不可信、健全性只在内核
- **Why3**（POPL'24 论文）— 中间验证语言：一套规约语言编译到 SMT + Coq 多后端
- **Liquid Types / LiquidHaskell**（Jhala 系）— 谓词表达性质 + SMT 自动证明义务
- **Sledgehammer**（Blanchette 系）— 外部证明器找证明 → 在内核重建（LCF 哲学）
- **Coq Coq Correct!**（Sozeau 等, 2020）— 被 Coq 证明正确的 Coq 内核
- **Milawa / Self-certification**（POPL'12）— 链式自举，信任降到最小可审计内核
