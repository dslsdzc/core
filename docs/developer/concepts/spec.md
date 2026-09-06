# 概念:规约——验证不换语言

> 定位:受众 = 开发者;状态 = 设计定稿(未实现——见注)。

## 写性质,不用学逻辑语言

Core 的验证入口写在函数上,表达式就是 Core 表达式:

```core
fn divide(a: int, b: int) -> int?
    #check(b != 0)                       // 前置:调用方必须满足
    #ensure(result.is_some() implies (a / b) == result.unwrap())
{
    if b == 0 { return None; }
    return Some(a / b);
}
```

- `#check(...)`:调用方义务
- `#ensure(...)`:实现方保证;`result` = 返回值,`old(x)` = 入口时的值
- `spec fn`:表达复杂性质用纯 Core 写的检查函数(验证的标准)

## 三层自动化的哲学

1. 编译器自动推导能推导的一切(`#pure`/`#terminating` 等标签——不用你写)
2. 推导不出的简单性质:一行 `#check`/`#ensure`
3. 复杂性质:`spec fn`——还是 Core,不是公式

验证的回报不只是安全:证明过的性质可流回优化器(证明驱动优化,设计态)——写的证明越多,优化越狠。

## 为什么可行:语义保鲜

编译中间表示保留全部语义——验证器消费 IR 即获得完整程序语义模型,不需要你为验证重写一遍程序,也不需要验证器自己猜语义。

## 现状注记

规约语法(#check/#ensure/.cr 内联)为 2026-09 设计定稿;**语法与验证管线均未实现**——当前标注不改变运行行为。推进见 TODO 与 `../../maintainer/design/spec-design.md`。

## 延伸

- 语法参考:`../syntax.md` 第十章
- 系统设计:`../../maintainer/design/spec-design.md`
