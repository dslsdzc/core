# Core 规约系统设计

> 状态：2026-10-24 按 Q18 决策同步。McTT 是最终验证信任根；CIC、`spec fn` 和 `where` 均为过期设计。
> 定位：规约是图上的约束，不是另一套程序语言。
> 相关：`docs/verifier/kernel-spec.md`、`docs/superpowers/specs/2026-09-17-spec-grammar.md`、`docs/superpowers/plans/2026-09-17-spec-grammar.md`。

## 一、基本思路

Core 的语义中间表示是 HDFG。规约不是对实现的另一套描述，而是图上的约束标注。

```text
# 正常编译
corec build file.cr
  -> .cir + .ccr

# 编译并生成规约约束
corec build file.cr -s
  -> .cir + .ccr + file.csr
```

- `.cir`：关系空间/图。
- `.ccr`：存在空间/编码输入。
- `.csr`：规约约束 sidecar，不改变 `.ccr` 与运行时产物。
- `#` 标注不影响运行时语义，不产 IR/机器码。

## 二、表面语法

### 2.1 标注

```core
fn divide(a: int, b: int) -> int?:
    #check(b != 0)
    #ensure(result != none)

    if b == 0:
        return none

    return a / b
```

- `#check(expr)`：前置条件。
- `#ensure(expr)`：后置条件。
- `#invariant(expr)`：循环不变量。
- `#variant(expr)`：循环终止度量。
- `result` 只在后置条件中绑定返回值。
- `old(expr)` 指函数入口时的值。
- `forall` / `exists` 是规约表达式的一等构造。
- 不引入 `where`。
- 不引入 `spec fn`。

### 2.2 检查函数

不设独立 `spec fn`。普通 `fn` 在同时满足以下条件时可作为检查函数：

- 纯；
- 终止；
- 可判定；
- 无 IO、`unsafe`、FFI、并发副作用。

检查函数与普通函数的区别只在验证层的使用方式，不由新关键字区分。

```core
fn valid(x: int) -> bool:
    return x >= 0
```

```core
fn divide(a: int, b: int) -> int?:
    #check(b != 0)
    #ensure(result != none)
    #ensure(valid(a))
```

## 三、三档

| 档 | 写法 | 负责方 |
|---|---|---|
| 自动推导 | 不需要写 | 编译器从图推导：pure、deterministic、no_alloc、safe_index 等 |
| 简单条件 | `#check` / `#ensure` / `#invariant` | 用户写，验证器检查 |
| 检查函数 | 纯、终止、可判定的普通 `fn` | 用户写，验证器检查 |

三档最终都进入 `.csr` 的 VC 记录；自动推导标签与用户条件使用同一状态机。

## 四、信任根与义务

### 4.1 信任根

最终信任根是 McTT 内核，不是 CIC。

- McTT 是小内核：`Type@i`、`Nat`、`Pi`、λ/app、`natrec`、显式替换、NbE。
- 不扩大内核来容纳完整 CIC。
- 表达力通过编码、库、公理、外部证书扩展。

### 4.2 义务

```text
Obligation =
  Encoded
  | Axiom
  | External
  | Unsupported
```

| 类型 | 含义 |
|---|---|
| `Encoded` | 可翻译为 McTT 项，由内核检查 |
| `Axiom` | 显式信任的公理/契约 |
| `External` | 外部证书或 IO 契约；必须显式登记 |
| `Unsupported` | 当前不能编码；不得静默通过 |

- 任何 `Unsupported` 不得标为 `proved`。
- `Axiom`/`External` 必须出现在报告中。
- 不允许求解器、优化器或插件隐式引入公理。

## 五、McTT 翻译边界

McTT 能力有限，翻译必须显式分档：

| Core 构造 | 处理 |
|---|---|
| `int`（Z） | 编码为 McTT 的整数表示；不可编码时为 `Unsupported` |
| `bool` | 编码为有限类型/Nat 子集 |
| `Nat`/递归 | `natrec` |
| 函数 | Pi/λ |
| 枚举/结构体 | 编码或 `Axiom`/`Unsupported` |
| 数组/切片 | 列表/索引编码或 `External` |
| `dex` | 精确十进制编码未定；未定前 `Unsupported` |
| `forall`/`exists` | 可编码片段由 McTT 检查；否则 `External`/`Unsupported` |
| 高阶量词 | 仅在 McTT Pi 可编码范围内 |
| 归纳类型/一般归纳 | 不假设内核支持；需编码或外部证书 |
| 函数外延性 | 不在内核；需要时显式 `Axiom` |

不得把“CIC 能做”当作“McTT 能做”。

## 六、终止

循环和递归翻译为 McTT 递归定义时必须给出递减度量：

- `#variant(expr)`：显式度量；
- 编译器可自动推导结构递减时使用自动度量；
- 推导失败：`Unsupported` 或编译错误；
- 不接受无终止证明的递归进入内核；
- 终止性按 Coq 式结构/良基递归要求，不按机器执行时间。

```core
i : int, mut = 0
loop:
    #invariant(i >= 0 && i <= count)
    #variant(count - i)

    if i == count:
        break

    i += 1
```

## 七、SMT

SMT 只作证明搜索器，不是信任根。

```text
VC
  -> SMT solver
  -> certificate / trace
  -> 可编码：McTT 检查
  -> 不可编码：External（显式登记）
```

- 不信任 SMT 的“unsat”输出。
- 证书检查失败：拒绝。
- 覆盖范围：线性算术、数组边界、位向量、未解释函数等可编码片段。
- 归纳/高阶/不可编码目标直接走 McTT 或 `External`/`Unsupported`。
- 用户可用 `#smt` 请求 SMT 搜索，但不改变信任边界。

## 八、`.csr`

`.csr` 是规约约束 sidecar。

```text
.csr = Header
     + VC records
     + TagNode metadata
     + symbol refs
     + string table
```

VC 状态：

| 状态 | 含义 |
|---|---|
| `proved` | 已有 McTT/外部证书检查通过的证明 |
| `unproven` | 未证明 |
| `failed` | 反例或证明失败 |
| `unsupported` | 当前不能编码/验证 |

规则：

- `.csr` 版本化。
- `.csr` 不改变 `.ccr`。
- 缓存键包含函数体、规约、编译器版本、内核版本。
- `#check(常量假)` 硬错。
- 默认 `unproven` 不阻断编译；strict 模式阻断。
- 不得把 `unproven`/`unsupported` 写成 `proved`。
- 证明状态是优化器使用该性质的唯一依据。

## 九、FFI / IO

- FFI/外部调用不进入纯规约表达式。
- 外部实现正确性不证明，登记为 `Axiom`/`External`。
- 验证外部只检查 IO 契约合法性：
  - 调用是否越权；
  - 读写/错误/所有权是否声明；
  - 是否违反纯函数约束。
- IO 非法：拒绝。
- IO 合法但实现未知：`External`，不得标 `proved`。
- FFI 错误进入 Q16 的 `Err` 摘要。

## 十、管线

```text
corec build file.cr -s
  -> tokenize
  -> parse
  -> check
  -> ir_gen
  -> lower
  -> 解析 #check/#ensure/#invariant/#variant
  -> 生成 VC 记录
  -> file.cir + file.ccr + file.csr

verify file.csr
  -> 加载 .cir / .csr
  -> 生成 McTT 义务或 External/Axiom
  -> McTT/外部证书检查
  -> 输出 proved / unproven / failed / unsupported
```

## 十一、信任边界

明确列出：

- McTT 内核实现；
- lexer/parser/checker；
- `.ccr`/`.csr` 读写；
- SMT 求解器仅作搜索，不信任；
- 显式 `Axiom`/`External`；
- FFI/IO 外部实现；
- 自举 stage2==stage3 只是经验证据，不是 soundness 证明。

## 十二、当前实现状态

已实现：

- `#` 词法/语法/部分 VC dump 切片；
- `#check`/`#ensure` 最小表达式子集。

未实现：

- `.csr`；
- `#invariant`/`#variant` 完整语义；
- 量词/`old`/`result` 完整检查；
- 纯检查函数验证；
- McTT 翻译层；
- SMT 证书通道；
- FFI/IO 契约验证；
- 证明驱动的优化回读。

## 十三、过期设计

以下内容不再有效：

- CIC 作为最终信任根；
- SMTCoq 路线的 CIC 证明项；
- `spec fn` 关键字；
- `where` 关键字；
- 把 SMT 当信任根；
- 把未证/`Unsupported` 当通过。
