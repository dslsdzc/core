# 用 Coq 验证 Core stdlib 纯函数

> 定位：受众 = 维护者/验证者；状态 = active（方向与入口）；本文件即入口（`coq/` 证明待建）。

> 目标：用 Coq（Rocq）做程序验证，验证 Core 系统里几乎不随语言演进而改动的部分（stdlib 纯函数）。
> 注意：这不是规约系统（`.corespec` / 翻译桥那套基础设施），而是直接用 Coq 验证程序本身的性质。

## 选取 stdlib 纯函数的依据

- 几乎不变：`int_str`（数字转字符串）、`str_eq` 等是语言无关的经典算法，不随语言演进变动。验证是长期投入，选取会变动的代码作证明对象会随之过时。
- 纯函数：无副作用，语义简单，Coq 里建模没有状态或内存干扰。
- 规模适中：每个函数几十行，翻译和证明可以在一天内完成一个完整流程。

## 首个目标：`int_str` 与 `str_int` 互逆

源码：`src/stdlib/fmt.cr:96`（`int_str`）、`src/stdlib/fmt.cr:134`（`str_int`）。

要证明的性质（非负情形）：

```
对任意非负整数 n：str_int(int_str(n)) == n
```

即：数字转成字符串，再解析回来，等于原数。这是 `fmt.cr` 的核心性质（数字转换正确性）。

## 验证工作流（5 步）

```
1 建模约定     Core 程序怎么"翻译"进 Coq 世界（抽象哪些、保留哪些）
2 翻译 int_str  循环改为递归（核心技能）
3 声明性质     互逆定理长什么样
4 证明         归纳 + div/mod 引理
5 验证         coqc 编译通过 = 证明成立
```

---

## 第 1 步：建模约定（已完成）

关键概念：验证不是逐行翻译代码，而是用 Coq 的语言重新表达同一个算法语义。需要回答的问题是 `int_str` 的语义，即它把一个数字变成了什么，而不是它如何操作内存。

对照 `fmt.cr:96` 的 `int_str`，逐项消去：

| Core 里的东西 | 为什么能消去 | Coq 里的表达 |
|---|---|---|
| `alloc(n)` / `load8` / `store8` | 内存布局是实现细节，语义 = "产生一个字符串" | `list`（字符串就是字符列表） |
| 字符串 header（`str_len` 读 -8 偏移） | 长度已内建在 list 里 | `length` |
| `+ 48` / `- 48`（ASCII 转换） | 字符编码是实现细节，语义 = "数字的十进制位" | 数字 `0..9` |
| `int`（64 位机器整数） | 先只验证非负情形，负数/溢出留到后面 | `nat` |

消去后 `int_str` 的算法语义：

```
int_str(n) = n 的十进制 digits 序列
   比如 int_str(123) = [1, 2, 3]
```

`str_int` 的语义（`fmt.cr:134`）：

```
str_int(s) = 从左往右读 digits，每读一位 res = res*10 + d
   [1,2,3] 得到 ((0*10+1)*10+2)*10+3 = 123
```

待确认点：`int_str` 里有两个循环（数位数的循环和填位的循环），翻译成 Coq 时两个循环会合并为一个递归函数。

## 进度

- [x] 第1步 建模约定
- [x] 第2步 翻译 int_str（循环改为递归）
- [x] 第3步 声明性质
- [x] 第4步 证明
- [x] 第5步 coqc 验证：2026-08-11 编译通过

## 成果

- 证明文件：`coq/fmt_int.v`（编译命令：`coqc coq/fmt_int.v`）
- 主定理：`roundtrip : forall n : nat, parse_fwd 0 (digits n) = n`，即 `str_int(int_str(n)) == n`（非负情形）
- 引理：
  - `parse_rev_digits_rev`：核心引理，逆序 digits 解析回来等于原数（良基归纳 + div_mod）
  - `parse_fwd_snoc` / `parse_fwd_rev`：衔接引理，正序解析等于逆序解析
  - 终止性义务：`n/10 < n`（Function measure 证明）

## 实现过程中遇到的问题（Rocq 9.1 实测）

1. 除法递归不被 Fixpoint 接受（guard condition）：`n / 10` 不是结构子项，需 `Function` + measure。
2. `Function f (n : nat) {measure n}` 语法在 Rocq 9.1 失效，报 "Illegal application: n cannot be applied to n"；须写 `{measure (fun x => x) n}`。
3. `simpl` 会展开 wf 包装、divmod 和乘法：`Function` 定义展开带证明项，`mod`/`div` 内部是 `divmod` fix，`10 * x` 展开成加法序列。解法：`Opaque Nat.div Nat.modulo Nat.mul` + 用 `digits_rev_equation` 精确展开。
4. `rewrite` 替换所有匹配：`rewrite (Nat.div_mod (S m) 10) at 1` 限定只替换最外层。
5. 归纳需要泛化累加器：`induction l in acc |- *`，否则 IH 里的 acc 与目标不匹配。

## 下一步候选

- `int_str` 负数分支（neg 处理，用 Z）
- 溢出语义（64 位机器整数，用 bitvector 或 mod 2^64）
- `concat` 正确性（`str_len(concat a b) = str_len a + str_len b`）
- `str_eq` 等价关系
- `collections.sum` / `reverse`（`rev (rev l) = l`）

## 环境

- Rocq Prover 9.1.1（opam，`~/.opam/default/bin/coqc`）
- 无 coqide，用命令行 coqc 编译和编辑器
