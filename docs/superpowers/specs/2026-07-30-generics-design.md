# 泛型完整实现设计

## 概述

在自托管 Core 编译器中完整实现泛型。支持泛型函数（`fn foo<T>(x: T)`）和泛型结构体（`struct Box<T> { val: T }`），多参数（`<A, B>`），自动类型推导，编译期 monomorphization。

## 核心原则

- **不需要 trait bounds / where 子句 / 关联类型**：类型检查不通过的用法在 monomorphization 时报错，报错路径与普通函数一致。
- **自动推导**：`identity(42)` → `T = int`，不需要写 `identity<int>(42)`。
- **Monomorphization 是编译期展开**：每次实例化产生独立函数/结构体，后端不感知泛型。
- **零运行时开销**：特化后的代码和手写具体类型版本完全一样。

## 用户语法

### 泛型函数

```core
fn identity<T>(x: T) -> T { return x; }
fn first<T>(arr: [T]) -> T { return arr[0]; }

// 调用时类型自动推导
x := identity(42);     // T = int
y := first(arr);       // T = 元素类型
```

### 泛型结构体

```core
struct Box<T> { val: T }
struct Pair<A, B> { first: A; second: B }

// 构造时推导
b := Box{val=42};                // T = int
p := Pair{first=1, second="hi"}; // A=int, B=string
```

### 泛型方法

```core
impl<T> Box<T> {
    fn get(self) -> T { return self.val; }
    fn set(self, val: T) { self.val = val; }
}

b := Box{val=42};
x := b.get();  // T = int
```

## 实现架构

### 文件结构

| 文件 | 职责 | 代码量 |
|------|------|--------|
| `parser.cr` | 解析 `<T, U>` 语法 | ~30 行 |
| `checker.cr` | 泛型参数注册、类型替换 | ~200 行 |
| `monomorph.cr` | **新建**：实例表管理、特化生成 | ~200 行 |
| `ir_gen.cr` | 调用特化版本 | ~20 行 |
| 测试 | 泛型函数/结构体/方法/多参数 | ~80 行 |

### 1. 解析器（`parser.cr`）

在 `parse_fn` 中识别 `fn name<T, U>(...)`：

```
解析 fn 关键字 → 解析函数名 → cur_tok 为 < → 进入泛型参数列表
  loop: 解析 T_IDENT → 注册为 GENERIC_PARAM → 检查 T_COMMA 继续 → T_GT 结束
```

在 `parse_struct` 中同理处理 `struct Box<T>`。

在 `parse_type` 中处理 `Box<int>`（泛型类型的显式特化）：

```
解析类型名 → cur_tok 为 < → 解析类型参数列表 → 创建 TYP_GENERIC_APPLY
```

### 2. 类型检查器（`checker.cr`）

**泛型参数注册**：遇到 `<T>` 时注册 `T` 为 `TYP_GENERIC_PARAM`，存储在符号表中。

**实例化**：当检测到 `identity(42)` 调用时：
1. 检查函数是否有泛型参数。
2. 从参数类型推导具体类型（`42` 是 `int` → `T = int`）。
3. 检查 `g_gen_instances` 缓存中是否已有 `identity<int>`。
4. 如果没有，注册新实例，触发 monomorphization。

**类型替换**：在实例化时将函数/结构体定义中所有 `T` 替换为具体类型。

```core
// 实例化 identity<int>:
// 原始: fn identity<T>(x: T) -> T { return x; }
// 特化: fn identity$int(x: int) -> int { return x; }
```

### 3. Monomorphization（`monomorph.cr`）— 新文件

```core
// 实例表
g_gen_instances : string, mut;   // 缓存已特化的函数索引
g_gen_instance_count : int, mut;

// 查找或创建实例
fn gen_find_instance(func_ni: int, type_args: string) -> int {
    // 扫描 g_gen_instances 查找已缓存的实例
    // 如果找到，返回函数索引
    // 如果没找到，创建新实例
}

// 生成特化版本
fn gen_monomorphize(func_ni: int, type_args: string) -> int {
    // 1. 复制函数 AST
    // 2. 将 T 替换为具体类型
    // 3. 注册新函数到 g_funcs
    // 4. 返回新函数索引
}
```

### 4. IR 生成（`ir_gen.cr`）

在 `gen_expr` 的 `EXPR_CALL` 处理中：

```core
// 调用普通函数 → 已有逻辑
// 调用泛型函数 → 查找/创建特化版本 → 调用特化版本
if is_generic_func(func_ni) {
    concrete_ni := gen_find_instance(func_ni, inferred_types);
    emit(IR_CALL, dest, first_arg, arg_count, concrete_ni, 0);
}
```

## 实现清单

| # | 文件 | 改动 |
|---|------|------|
| 1 | `src/compiler/parser.cr` | parse_fn/parse_struct 处理 `<T>` + parse_type 处理 `Box<int>` |
| 2 | `src/compiler/checker.cr` | GENERIC_PARAM 注册 + 调用时类型推导 + 类型替换 |
| 3 | `src/compiler/monomorph.cr` | 新建：gen_find_instance + gen_monomorphize + 实例缓存 |
| 4 | `src/compiler/ir_gen.cr` | 泛型调用 → 查实例表 → 调用特化版本 |
| 5 | `tests/suite/gen_test.cr` | 泛型函数/结构体/多参数/方法测试 |
