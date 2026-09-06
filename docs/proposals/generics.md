# Core 泛型

> 定位：受众 = 贡献者；状态 = proposal(讨论中)

## 设计原则

- **尽量靠图推导，不需要用户标注约束。**
- 泛型函数的每次实例化在图上产生独立子图，互不干扰。
- 学习成本：用户只需要会写 `<T>`，不需要学 trait bounds、where 子句、关联类型。

## 语法

### 泛型函数

```core
fn identity<T>(x: T) -> T {
    return x;
}

fn first<T>(arr: [T]) -> T {
    return arr[0];
}
```

### 泛型 struct

```core
struct Box<T> {
    val: T,
}

struct Pair<A, B> {
    first: A,
    second: B,
}
```

### 泛型参数约束

当泛型函数内部调用了类型的方法或字段时，编译器自动推导约束，不需要用户写 `where T: SomeInterface`：

```core
fn print_size<T>(x: T) {
    // 编译器：T 必须有 .size() 方法
    // 调用处推导约束，不是在定义处声明
    println(x.size());
}
```

约束推导：编译器看图，发现 `x.size()` 调用，检查传入的实际类型是否有 `.size()` 方法。

```core
print_size(42);          //  int 没有 .size()
print_size("hello");     //  string 有 .len()，编译器推导约束匹配
```

### 隐式约束推导

尝试使用泛型类型时，编译器关注实际传入的类型是否满足函数内部的操作。规则是从使用点推导约束，而不是在定义点声明约束。

```core
fn add<T>(a: T, b: T) -> T {
    return a + b;    // 编译器推导：T 必须支持 + 运算
}

add(1, 2);           //  int 支持 +
add("a", "b");       //  string 支持 +
```

## 图上的实现

### monomorphization

泛型函数的每次实例化在图上产生独立子图。

```
源代码：
    x := identity(42);
    y := identity("hello");

图：
    ┌─ identity(int) ────┐    ┌─ identity(string) ──┐
    │  CONST(42)          │    │  CONST("hello")      │
    │  RETURN             │    │  RETURN              │
    └────────────────────┘    └──────────────────────┘
    一次实例化                 一次实例化
    独立子图                    独立子图
```

### 跨模块泛型

```core
// lib.cr
pub fn wrap<T>(x: T) -> (T, T) {
    return (x, x);
}

// main.cr
import lib;
p := lib.wrap(42);   // lib 的泛型函数 main 中实例化
                     // 实例化发生在 main 的 ccr 中
```

编译器处理方式：

```
1. 泛型函数的 IR 被序列化到 .ccr 中，作为未实例化的函数模板
2. 调用方在实例化时，将类型参数代入 IR 模板，生成具体类型的子图
3. 子图加入调用方的图
```

这种设计的代价是需要编译器在跨模块实例化时持有泛型函数的 IR 模板，而不是只持有编译后的机器码实例。

## 泛型与 @ 内省

```core
fn serialize<T>(obj: T) -> string {
    result := "";
    for name in @fields(T) {
        val := @field(T, name).get(obj);
        result += name + ":" + to_string(val) + ",";
    }
    return result;
}
```

`@fields` 和 `@field` 在泛型函数中作用于类型参数 `T`，在实例化时展开。

## 编译时求值与泛型

```core
fn make_array<T, N: int>() -> [T; N] {
    result: [T; N];
    i := 0;
    loop {
        if i >= N { break; }
        result[i] = default<T>();
        i = i + 1;
    }
    return result;
}

arr := make_array<int, 10>();
// N 是编译时已知的，在实例化时展开
```

编译器处理方式：`N` 被约束为 `int`，且在调用处必须是 `@comptime` 已知的编译时值。

```core
make_array<int, user_input>();  //  编译错误：泛型参数 N 需要编译时已知
```

## 设计与替代方案

| 特性 | Core | Rust | Zig | C++ |
|------|------|------|-----|-----|
| 泛型函数 | `<T>` | `<T>` | `fn(T)` | `template<T>` |
| 泛型 struct | `<T>` | `<T>` | `fn(T)` | `template<T>` |
| 约束 | 编译时图推导 | trait bounds | `comptime` 类型检查 | concepts/SFINAE |
| 实例化 | 独立子图 | monomorph | 编译时函数 | 模板实例化 |
| 编译时参数 | `@comptime` | const generics | `comptime` | `auto` |

## 当前状态

泛型函数和泛型 struct 已在 checker 和 ir_gen 中实现（`infer_gen_call`、`fi_generic_count`）。
跨模块泛型实例化由 `src/compiler/monomorph.cr` 承担（已纳入自举构建）。
具体实现进度以 `TODO.md` 与源码为准。已知局限：解释器不支持泛型函数（类型检查通过但返回 255，见 TODO.md 预存 bug 3）。
