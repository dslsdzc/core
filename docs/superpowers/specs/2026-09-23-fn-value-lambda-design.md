# 函数值、Lambda 与 callable 设计

## 概述

Core 目前没有函数类型、命名函数值和 lambda。本文给出三者的语法、类型表示、IR 表示、捕获语义、诊断和实施清单。

设计目标是一个统一的 callable 类型，不向用户暴露闭包的内存布局。

## 设计原则

- `fn(T...) -> R` 是唯一的 callable 类型。callable 由可调用实体和可选的捕获环境组成。
- 语义层不规定机器布局。当前 x86-64 后端用 `{code, env}` 实现：无捕获时 `env = 0`，有捕获时 `env` 指向环境。
- `fn.foo` 是带类型的 callable 值，类型是 `fn(...) -> ...`。`@addr(foo)` 是机器地址，类型是 `int`。两者不等价，不能互相赋值。
- `sched_go(@addr(f), arg)` 保持现有低层接口。并发接口的演进不反向决定函数值的类型模型。
- 不新增第二种函数类型。异步和协程相关属性由编译器推导，不进入函数类型。

## 语法

新增四个产生式：

```ebnf
FunctionType =
    'fn' '(' [ Type { ',' Type } ] ')' '->' Type ;

FunctionRef =
    'fn' '.' IDENT ;

LambdaExpr =
    'fn' '(' [ LambdaParamList ] ')'
    (
        '=>' Expr
      | '->' Type Block
    ) ;

LambdaParamList =
    LambdaParam { ',' LambdaParam } ;

LambdaParam =
    IDENT [ ':' Type ] ;
```

接线：

```ebnf
Type    += FunctionType
Primary += FunctionRef
Primary += LambdaExpr
```

规则：

- `->` 右结合。`fn(int) -> fn(int) -> int` 等价于 `fn(int) -> (fn(int) -> int)`。
- 函数类型与 `?`、`[]`、元组组合时必须加括号。`(fn(int) -> int)?` 合法，裸 `fn(int) -> int?` 报错。
- 本轮 `fn.name` 只支持非泛型顶层函数。方法和泛型函数的取值留给后续。
- lambda 的参数类型可以省略。有 expected type 时从上下文推导；没有足够上下文时报“无法推导”，不猜类型。
- lambda 不写捕获列表。捕获哪些变量、只读还是修改、是否需要转移，由编译器分析。

## 类型表示

新增 `TYP_FN = 5`。5 是 `TYP_*` 号段中的空位。

类型行使用 `{kind, data, extra}` 三个槽。按 `TYP_TUPLE` 的先例：

- `data` 保存参数个数。
- `extra` 保存参数类型在侧表中的起始下标。
- 返回类型放在链首。

建行规则：

- 只在第一次用到某个签名时建行。
- 建行前先查是否已有同签名行，命中就复用。
- 不在 `init_types()` 里预建 `TYP_FN` 规范行。预建会让每一档 `.ccr` 的 TYPE 段增加 24 字节，即使程序没有使用函数值，也会改变 canary 基准值。

子类型规则：

- 同签名同型：`ty_sub(T, T) = 1`。
- 参数或返回型不同：`ty_sub(...) = 0`。
- `TYP_FN` 与非函数类型互赋：`0`。

桥接：

- `iface_kind_of(TYP_FN)` 返回 `AK_FN`。
- `sh_term_of_ti` 和 `sh_sig_term_of_ti` 两个构造点都要处理 `TYP_FN`，构造 `tt_atom(AK_FN, -1, [返回项, 参数项…])`，返回项在链首。
- 不给分支时，未知 kind 会回退成命名类，类型引擎得到 `-1`。结果是不报错但判不了，因此两个构造点必须同批修改。

## IR 与后端

- `fn.name` 和 lambda 的代码字复用 `IR_FNADDR`。
- 新增间接调用 opcode。建议槽序为 `s1=callable 变量, s2=第一个实参, s3=实参个数`。
- x86-64 后端发射 `call r/m64`。如果捕获环境需要作为隐藏参数传递，在 `callseq.cr` 中统一处理。
- 需要同步修改的分析面：
  - 纯度与效应：`purity_op_effect` 必须把间接调用列为有副作用。
  - 图与 DOT：`dataflow.cr` 的 use-def 和 opcode 名字表。
  - 格层：`ent_kernel.cr` 的 opcode 名字表。
  - 优化器：`opt.cr` 的跳过模式。
  - 解释器：实现新 op，或明确报“不支持”，不能不报错地算错。
  - 尺寸表：`sizes.cr` 的字节数必须与实际发射一致。
  - 寄存器分配：`regalloc.cr` 的寄存器类和冲突位。
  - 链接：`elf.cr` 的 `IR_FNADDR` 回填。

`.ccr` 影响：

- TYPE 段每新增一行增加 24 字节，每新增一个类型项增加 40 字节。
- 按需建行且固定语料不使用函数值时，TYPE 段不变，canary 五条不变。
- 如果 `.ccr` 发生变化，按现有规则处理：说明原因，运行 D1 确定性检查，更新基准值，保留旧值。

## 捕获语义

- 捕获默认按引用。
- 捕获环境放在外层栈帧。
- 逃逸由 region 分析判定。判不了就报错，不猜，不不报错地改为堆分配。
- 无捕获 lambda 不创建空环境，`env = 0`。
- 不引入 `Fn`、`FnMut`、`FnOnce`，也不引入显式 closure object 类型。
- 不写捕获列表。

## 诊断

“无法推导 lambda 参数类型”不是类型错误，需要单独一类诊断。

- 建议族号 18，前缀 `U`。
- 同批修改 `error_cat_prefix`、`ast.cr` 的错误码注释表、`docs/developer/errors.md` 的族节和统计表。
- 新码必须在 `diag_gate_exempt` 中有明确归属：要么有真实 raise 点，要么按豁免表格式登记。
- 未知 `@` 内建仍然报 `N01`，不能不报错地忽略。

## 实施清单

| # | 文件 | 改动 |
|---|---|---|
| 1 | `grammar/core.ebnf` | 增加 `FunctionType`、`FunctionRef`、`LambdaExpr`、`LambdaParamList`、`LambdaParam`，并把它们接入 `Type` 和 `Primary` |
| 2 | `src/compiler/ast.cr` | 新增 `TYP_FN = 5`、`EXPR_FNREF`、`EXPR_LAMBDA`、间接调用 opcode |
| 3 | `src/compiler/parser.cr` | `parse_type()` 识别 `fn(`；表达式主元识别 `fn.name` 和 `fn(...)` lambda |
| 4 | `src/compiler/checker.cr` | 解析函数类型、按签名去重建行、推导 lambda 参数和返回型、分析 capture、发出新诊断 |
| 5 | `src/compiler/ty_shadow.cr` | `sh_term_of_ti` 和 `sh_sig_term_of_ti` 增加 `TYP_FN` 分支 |
| 6 | `src/compiler/iface_axis.cr` | `iface_kind_of` 把 `TYP_FN` 映射到 `AK_FN` |
| 7 | `src/compiler/ir_gen.cr` | 生成 `IR_FNADDR`；被调者是 callable 值时发射间接调用 |
| 8 | `src/arch/x86_64/instr.cr` | 发射间接 `call` |
| 9 | `src/arch/x86_64/sizes.cr` | 新 opcode 的字节数 |
| 10 | `src/arch/x86_64/regalloc.cr` | 新 opcode 的寄存器类和冲突位 |
| 11 | `src/os/linux/callseq.cr` | 捕获环境作为隐藏参数时的调用序列 |
| 12 | `src/format/elf/elf.cr` | 间接调用目标的链接期回填 |
| 13 | `src/compiler/interp.cr` | 实现间接调用，或明确报不支持 |
| 14 | `src/compiler/dataflow.cr` | use-def 和 DOT 名字 |
| 15 | `src/lattice/ent_kernel.cr` | 格层 opcode 名字 |
| 16 | `src/compiler/opt.cr` | 优化器跳过模式 |
| 17 | `src/compiler/type_selftest.cr` | 更新 `ts_ccr2_kind_domain_ok` 和“零 ops 行恰三行”检查 |
| 18 | `tests/` | 新增函数类型、`fn.name`、lambda、捕获、间接调用、诊断的测试 |

## 不包含

- currying
- higher-kinded function abstraction
- operator sections
- 专门的函数组合语法
- partial application（本轮不做，后续按使用频率决定）
- `flow fn(...) -> ...` 作为类型
- `async fn`
- `Future[T]`
- `Coroutine[T]`
- `GeneratorState`
- `Suspend`
- `FnAsync`
- 显式 closure object 类型
- 捕获列表
- `Fn` / `FnMut` / `FnOnce`
- 本轮不支持 `fn.Type::method` 和 `fn.obj.method`

`flow` 作为 region kind 和声明前缀的现有用法不受影响。被否决的只是 `flow fn(...) -> R` 作为类型。

## 未决问题

| # | 问题 | 需要谁决定 |
|---|---|---|
| 1 | 间接调用 opcode 的编号和槽序 | 维护者 |
| 2 | `TYP_FN` 行的槽分配：`data` 加侧表，还是 `data` 存返回型、参数走侧表 | 维护者 |
| 3 | `flow counter()` 的函数类型是什么，`fn.counter` 是否可用 | 维护者 |
| 4 | 逃逸判定放在哪个 pass，`region_check.cr` 能否直接使用 | 维护者 |
| 5 | 新 opcode 是否要提升 `CIR_CACHE_VER` | 维护者 |
| 6 | `flow fn name()` 与 `flow name()` 哪种拼写是规范形 | 维护者 |
| 7 | 间接调用是否需要“强制动态”开关，用来证明静态化和动态化行为相同 | 维护者 |

## 参考

设计所依据的现状定位点、行号差异、未核实项和原始讨论记录见 [2026-09-23-fn-value-lambda-evidence.md](../implementation/2026-09-23-fn-value-lambda-evidence.md)。
