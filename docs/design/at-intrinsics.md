# Core @ 内建原语

> 定位：受众 = 维护者；状态 = active

`@` 是编译器提供的能力入口，不通过标准库实现。分三类：

| 类别 | 能力 | 使用场景 |
|------|------|---------|
| 元数据查询 | `@typeInfo` `@field` `@hasField` `@fields` `@sizeOf` `@alignOf` | 泛型、序列化、反射 |
| 编译控制 | `@comptime` `@inline` `@unroll` `@section` | 性能调优、底层控制 |
| 安全检查 | `@no_bounds_check` `@fast` | unsafe 优化 |

## 元数据查询

编译期查询类型的结构。全部在编译期求值，零运行时开销。

```core
@sizeOf(T)            // 返回类型 T 的大小
@alignOf(T)           // 返回类型 T 的对齐
@typeInfo(T)          // 返回类型的完整结构（字段、方法、大小、对齐）
@fields(T)            // 返回字段名列表，编译期可遍历
@field(T, name)       // 返回字段的偏移和类型
@hasField(T, name)    // 返回 bool，字段是否存在
```

示例——无运行时反射的序列化：

```core
fn serialize(buf: &[u8], obj: any) {
    for name in @fields(typeof(obj)) {
        val := @field(typeof(obj), name).get(obj);
        write_field(buf, name, val);
    }
}
// 编译期展开，不涉及运行时反射调用
```

## 编译控制

不改变语义，只改变编译方式。

```core
@inline(fn)           // 提示编译器内联
@unroll(n)            // 展开循环 n 次
@section(name)        // 放到指定代码段
@comptime(expr)       // 强制编译期执行，算不了报错
@comptime { ... }     // 块形式
```

## 安全检查

跳过硬性安全检查。unsafe 范畴，调用方自己保证安全。

```core
@no_bounds_check      // 跳过边界检查
@fast                 // 允许精度换速度
```

## 与其他语言的对比

| 能力 | Zig | Core |
|------|-----|------|
| 类型结构查询 | `@typeInfo` | `@typeInfo` |
| 字段遍历 | `@typeInfo(T).Struct.fields` | `@fields(T)` |
| 字段偏移 | `@offsetOf` | `@field` |
| 大小/对齐 | `@sizeOf` `@alignOf` | `@sizeOf` `@alignOf` |
| 编译期强制 | `comptime` | `@comptime` |
| 内联 | `@inline` | `@inline` |
| 代码段 | `@section` | `@section` |
| 嵌入文件 | `@embedFile` | `read_file`（自动推导） |

Zig 用 `@` 做所有编译期事情。Core 只用 `@` 做**查询和控制**——求值是图自动做的。
