# Core 编译时能力

> 定位:受众 = 维护者/贡献者;状态 = **active(部分实现)**——@ 内建原语与编译期机制见 docs/developer/at-intrinsics.md;本设计文档为推导策略蓝图,多数单元格未落地

## 设计原则

- **90% 的编译时执行由HDFG自动推导，用户不需要任何关键字。**
- **用户只需在"必须编译时执行，算不了就报错"时表态。**
- `@` 只负责查询和控制——不负责触发执行。

## 三种场景

| 场景 | 触发方式 | 示例 |
|------|---------|------|
| 常量折叠、纯函数提前执行、边界消错 | 自动——图推导 | `fibonacci(40)` `arr[3]` |
| 编译时 I/O、文件嵌入 | 自动——参数全为常量即可 | `read_file("x.toml")` |
| 强制编译时执行 | `@comptime` | `@comptime { ... }` |

## 自动推导

编译器从HDFG上判定：子图的所有输入来自 CONST 或已执行的编译时子图，且子图内无副作用——则自动在编译时执行。

```core
// 全部自动，不需要任何关键字
x := 40 + 2;
y := fibonacci(x);          // 参数已知，纯函数 → 编译时算
data := read_file("x.toml"); // 参数已知 → 编译时嵌入
z := arr[3];                // offset 已知 → 编译时消错

// 遇到运行时输入自动停
w := fibonacci(user_input); // 参数运行时才确定 → 留给运行时
```

## @comptime

自动推导不能表达"算不了就报错"的意图。`@comptime` 提供这个保证：

```core
@comptime {
    cfg := read_file("config.toml");
    parsed := parse_config(cfg);
    validate(parsed);
    // 以上任意一步算不了 → 编译错误，不留给运行时
}
```

`@comptime` 不改变语义——只改变报错时机。

## 编译时函数（comptime fn）

标记为 `comptime fn` 的函数要求所有调用点在编译时可求值：

```core
comptime fn fibonacci(n: int) -> int {
    if n <= 1 { return n; }
    return fibonacci(n - 1) + fibonacci(n - 2);
}

x := fibonacci(40);              //  编译时算
y := fibonacci(user_input);      //  编译错误：comptime fn 需要已知参数
```

## 可编译时执行的条件

编译器对子图做可达性分析后判定：

| 执行条件 | 自动执行 | @comptime |
|---------|---------|-----------|
| 纯函数，所有输入已知 |  |  |
| read_file，路径已知 |  |  |
| 有未知输入 |  留给运行时 |  编译错误 |
| 调用 FFI / volatile |  |  编译错误 |
| 类型内省（@typeInfo 等） | — |  |
