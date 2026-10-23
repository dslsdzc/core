# 共享格式协议（McTT 到 Core 内核移植 M1 术语级差分）

> 本协议由 Task 3 确定，是 Task 4（语料生成器 `tests/kernel/gen_corpus.py`）、
> Task 5（`src/kernel/term_io.cr`）、Task 6（Core 内核移植）与 Task 7（差分）
> 的唯一格式基准。任何实现与本文不符即为协议违反。
> 语义基准 = McTT 提取代码（`~/mctt/driver/extracted/`，icfp25 分支），
> 权威规则文档 = `docs/verifier/kernel-spec.md`（Task 2）。

## 1. 查询文件格式

- 每行一条查询；`#` 开头的行（允许前导空白）是注释行，读取时必须跳过，
  不产生输出。空行同样跳过。
- 每行由命令名与若干 S-表达式组成，以空白分隔：
  - `check   <ctx> <exp> <exp>`   判定第二项 : 第三项（项在前、类型在后）
  - `infer   <ctx> <exp>`         推断类型
  - `convert <ctx> <exp> <exp> <exp>`  第二、三项在第四项类型下可转换性
  - `subtype <ctx> <exp> <exp>`   子类型判定（第二项 ≤ 第三项）

## 2. 文法

```
<ctx> ::= (ctx <exp>*)
<exp> ::= (typ N) | (nat) | (zero) | (succ <exp>)
        | (natrec <exp> <exp> <exp> <exp>)      # A MZ MS M（动机、zero 分支、succ 分支、被归纳项）
        | (pi <exp> <exp>) | (fn <exp> <exp>) | (app <exp> <exp>)
        | (var N) | (sub <exp> <sub>)
<sub> ::= (id) | (weaken) | (compose <sub> <sub>) | (extend <sub> <exp>)
N     ::= 非负十进制整数
```

构造子与 McTT `Syntax.exp`/`Syntax.sub` 一一对应（`Coq_a_typ/…`），字段顺序同
提取代码（`natrec` 为 `A MZ MS M`，见 kernel-spec.md 0.3 节）。`(typ N)` 即 `Type@N`，
`(nat)` 即 `ℕ`。

## 3. de Bruijn 约定（kernel-spec.md 0.1 节，唯一基准）

- 上下文是头部扩展的 list：`(ctx e1 … en)` 中 `e1` 是头部（最右、最近绑定），
  直接映射为提取代码的 `exp list`（`e1 :: … :: en`，不做反转）。
- var 0 是上下文头部（最近绑定元素），索引随绑定深度向外递增。
- 注意：`(ctx e1 … en)` 的条目是类型；`check` 的目标、`pi/fn` 的域等都须
  按同一约定解读。

## 4. 输出格式

每查询一行（注释行和空行无输出）：

```
check:   accept | reject
infer:   type: <nf-exp> | reject
convert: yes | no
subtype: yes | no
```

- `<nf-exp>` 是正规化结果（正常形/中性形），用第 2 节同一 S-表达式语法打印
  （中性形经 `(var N)` / `(app …)` / `(natrec …)` 打印）。
- 推断输出必须正规化：参考侧直接使用 `type_infer` 返回的 nf（提取实现已经
  正规化），两侧均不得打印未正规化项。

## 5. 语义约定（总化规则）

判定语义为 McTT 提取算法的直译（`TypeCheck.type_check/type_infer`、
`Subtyping.subtyping_impl`、`NbE.nbe_impl` + `Syntax.nf_eq_dec`），并约定
“判定前提不满足”的处理：

- 提取代码中标注 `assert false` 的荒谬分支（读出的类型或值形状不匹配、
  应用非函数值、natrec 荒谬情形等；即定理中不可达、但输入可触达的情形），
  参考侧（OCaml）以异常捕获实现，Core 侧（Task 6）以失败传播实现，
  统一按拒绝态处理：check/infer 返回 `reject`；convert/subtype 返回 `no`。
- 由此两侧实现的是同一全函数：凡 McTT 有定义处输出逐位一致；凡 McTT
  崩溃处输出拒绝态。
- 典型推论（均已由参考侧实测）：
  - `infer` 对任意语法良构项为全函数（`type_infer` 不求值未定型项），
    越界 `(var N)`、顶层 `(sub …)`、病型项一律 `reject`（顶层 `sub` 在
    提取中恒为 `None`，即使其语义良型）。
  - `check` 的目标类型若不是合法类型（如 `(zero)`、`(app …)` 未归约为类型），
    参考侧按 `reject`（McTT 直译在此崩溃）；`check` 的参数序是项在前、
    类型在后（提取的 `type_check` 为 `(ctx, 类型, 项)`，接线时交换）。
  - `subtype` 两侧若不是类型形态（求值结果非 `ℕ/Π/Type@i/中性`），按 `no`。
  - `convert` 两侧经 `nbe_impl ctx t ty` 正规化后按 `nf_eq_dec` 比较
    （`nbe_impl` 参数序为 `(ctx, 项, 类型)`）。

## 6. 示例

```
# 单行示例（注释行）
check (ctx) (zero) (nat)           # check: accept
infer (ctx) (succ (zero))          # infer: type: (nat)
convert (ctx) (nat) (nat) (typ 1)  # convert: yes
subtype (ctx) (typ 0) (typ 1)      # subtype: yes
```

## 7. 参考侧实现（本目录）

- `harness.ml` + `dune`：OCaml 参考 harness，链接提取库 `McttExtracted`
  （wrapped，模块经 `McttExtracted.Syntax` 等显式别名引用）。
- 构建方法见 `README.md`；快速验证 `smoke.txt` 对照 `smoke.expected`。
- 运行方式：`harness.exe QUERY_FILE...`；malformed 行的处理为：stderr 诊断、
  无 stdout 输出、退出码 1（语料须良构）。
