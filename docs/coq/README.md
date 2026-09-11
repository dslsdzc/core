# 用 Coq 验证 Core stdlib 纯函数

> 定位:受众 = 维护者/验证者;状态 = active(方向与入口);真源 = 本文件(coq/ 证明待建)。

> 目标：用 Coq（Rocq）做**程序验证**——验证 Core 系统里**几乎永远不会改**的部分（stdlib 纯函数）。
> 注意：这不是规约系统（`.corespec` / 翻译桥那套基础设施），是直接用 Coq 验证程序本身的性质。

## 为什么选 stdlib 纯函数

- **几乎永不变**：`int_str`（数字→字符串）、`str_eq` 等是语言无关的经典算法，语言怎么演进都不变。验证是长期投入，选会变动的代码证明就过时了。
- **纯函数**：无副作用，语义干净，Coq 里建模没有状态/内存干扰。
- **规模适中**：每个函数几十行，翻译 + 证明一晚上一个闭环。

## 第一刀目标：`int_str` ↔ `str_int` 互逆

源码：`src/stdlib/fmt.cr:96`（int_str）、`src/stdlib/fmt.cr:134`（str_int）。

**要证明的性质（非负情形）**：

```
对任意非负整数 n：str_int(int_str(n)) == n
```

即：数字转成字符串，再解析回来，等于原数。这是 fmt.cr 的灵魂性质（数字转换正确性）。

## 验证工作流（5 步）

```
① 建模约定     Core 程序怎么"翻译"进 Coq 世界（抽象哪些、保留哪些）
② 翻译 int_str  循环 → 递归（核心技能）
③ 声明性质     互逆定理长什么样
④ 证明         归纳 + div/mod 引理
⑤ 验证         coqc 编译通过 = 证明成立
```

---

## 第 ① 步：建模约定（已完成）

**关键概念：验证不是逐行翻译代码，而是用 Coq 的语言重新表达同一个算法语义。** 要回答的问题："int_str 的语义是什么？"——不是"它怎么操作内存"，而是"它把一个数字变成了什么"。

对照 `fmt.cr:96` 的 int_str，逐项消去：

| Core 里的东西 | 为什么能消去 | Coq 里的表达 |
|---|---|---|
| `alloc(n)` / `load8` / `store8` | 内存布局是实现细节，语义 = "产生一个字符串" | `list`（字符串就是字符列表） |
| 字符串 header（`str_len` 读 -8 偏移） | 长度已内建在 list 里 | `length` |
| `+ 48` / `- 48`（ASCII 转换） | 字符编码是实现细节，语义 = "数字的十进制位" | 数字 `0..9` |
| `int`（64 位机器整数） | **先只验证非负情形**，负数/溢出留到后面 | `nat` |

**消去后 int_str 的算法语义**：

```
int_str(n) = n 的十进制 digits 序列
   比如 int_str(123) = [1, 2, 3]
```

**str_int 的语义**（`fmt.cr:134`）：

```
str_int(s) = 从左往右读 digits，每读一位 res = res*10 + d
   [1,2,3] → ((0*10+1)*10+2)*10+3 = 123
```

**待确认点**：int_str 里有两个循环（数位数的循环 + 填位的循环）——翻译成 Coq 时两个循环会合体成一个递归函数。

## 进度

- [x] 第①步 建模约定
- [x] 第②步 翻译 int_str（循环 → 递归）
- [x] 第③步 声明性质
- [x] 第④步 证明
- [x] 第⑤步 coqc 验证 —— **2026-08-11 编译通过**

## 成果

- **证明文件**：`coq/fmt_int.v`（编译命令：`coqc coq/fmt_int.v`）
- **主定理**：`roundtrip : forall n : nat, parse_fwd 0 (digits n) = n` —— 即 `str_int(int_str(n)) == n`（非负情形）
- **引理**：
  - `parse_rev_digits_rev` — 核心引理：逆序 digits 解析回来等于原数（良基归纳 + div_mod）
  - `parse_fwd_snoc` / `parse_fwd_rev` — 桥引理：正序解析 = 逆序解析
  - 终止性义务：`n/10 < n`（Function measure 证明）

## 过程中踩的坑（Rocq 9.1 实测）

1. **除法递归不被 Fixpoint 接受**（guard condition）——`n / 10` 不是结构子项，需 `Function` + measure
2. **`Function f (n : nat) {measure n}` 语法在 Rocq 9.1 坏了**——报 "Illegal application: n cannot be applied to n"；须写 `{measure (fun x => x) n}`
3. **`simpl` 会展开 wf 包装 / divmod / 乘法**——`Function` 定义展开带证明项，`mod`/`div` 内部是 `divmod` fix，`10 * x` 展开成加法链。解法：`Opaque Nat.div Nat.modulo Nat.mul` + 用 `digits_rev_equation` 精确展开
4. **`rewrite` 替换所有匹配**——`rewrite (Nat.div_mod (S m) 10) at 1` 限定只替换最外层
5. **归纳需要泛化累加器**——`induction l in acc |- *`，否则 IH 里的 acc 与目标不匹配

## 下一步候选

- `int_str` 负数分支（neg 处理，用 Z）
- 溢出语义（64 位机器整数，用 bitvector 或 mod 2^64）
- `concat` 正确性（`str_len(concat a b) = str_len a + str_len b`）
- `str_eq` 等价关系
- `collections.sum` / `reverse`（`rev (rev l) = l`）

## 环境

- Rocq Prover 9.1.1（opam，`~/.opam/default/bin/coqc`）
- 无 coqide，用命令行 coqc 编译 + 编辑器
