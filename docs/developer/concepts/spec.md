# 概念：规约，验证不换语言

> 定位：受众 = 开发者；状态 = 设计定稿（未实现，见注）。

## 性质表达：不引入独立逻辑语言

Core 的验证条件写在函数上，表达式就是 Core 表达式：

```core
fn divide(a: int, b: int) -> int?
    #check(b != 0)                       // 前置条件：调用方必须满足
    #ensure(result.is_some() implies (a / b) == result.unwrap())
{
    if b == 0 { return None; }
    return Some(a / b);
}
```

- `#check(...)`：调用方义务
- `#ensure(...)`：实现方的保证；`result` 是返回值，`old(x)` 是进入函数时的值
- `spec fn`：用纯 Core 编写的检查函数，用于表达复杂性质，作为验证的标准

## 三层自动化

1. 编译器自动推导可以推导的所有性质（`#pure`/`#terminating` 等标签无需手写）
2. 无法推导的简单性质：写一行 `#check`/`#ensure`
3. 复杂性质：使用 `spec fn`，仍然是 Core，不是公式

验证的作用不只是安全。已经证明的性质可以提供给优化器使用（证明驱动优化，设计态）。写出的证明越多，可用的优化越强。

## 可行性：语义保留

编译中间表示保留全部语义。验证器使用 IR 就能得到完整的程序语义模型，不需要为验证重写程序，也不需要验证器自行推测语义。

## 现状注记

规约语法（`#check`/`#ensure`/`.cr` 内联）于 2026-09 设计定稿，语法和验证管线均未实现。当前这些标注不改变运行行为。推进计划见 TODO 和 `../../maintainer/design/spec-design.md`。

## 延伸

- 语法参考：`../syntax.md` 第十章
- 系统设计：`../../maintainer/design/spec-design.md`
