# Core FFI

> 定位:受众 = 维护者/贡献者;状态 = **partial(仅 extern fn)**——@ffi 统一入口为设计态未实现;当前 C ABI 走 extern fn(IR_CALL/syscall);细节见 src/stdlib/io.cr extern 声明

## 设计原则

- **所有语言统一走 `@ffi`，参数描述运行时特征。**
- `@ffi` 是编译控制，不改变语义，只改变编译方式——和 `@inline` 在同一分类。
- C ABI 是默认接口，所有其他语言最终也通过 C ABI 对接。
- **平台接口隔离在后端。** 常规 I/O 走标准库流语义接口（print/println/read_file/write_file 保持），read/write 等系统调用是平台桥后端的实现细节；`extern fn` 直接声明系统接口是绕过语义层的例外入口，属 unsafe 范畴。

## 语法

### C FFI（默认，省略 `@ffi` 时等价）

```core
extern fn read_file(path: *const u8) -> *mut u8;
// 等价于 C 的 char* read_file(const char* path)
```

### 指定语言

```core
@ffi("Python") extern fn py_call(obj: dyn, method: string) -> dyn;
// 编译器：参数转 PyObject*，refcount 管理，返回值转回 dyn

@ffi("Java") extern fn java_call(env: dyn, obj: dyn, method: string) -> dyn;
// 编译器：绑定当前线程 JNIEnv，exception 检查

@ffi("Lua") extern fn lua_call(state: dyn, fn_name: string) -> dyn;
// 编译器：Lua stack 操作包装

@ffi("Rust") extern fn process(data: *mut u8, len: i32);
// 等价于 C ABI，不需要额外处理

@ffi("C") extern fn write(fd: i32, buf: *const u8, len: i32) -> i32;
// 显式指定，和省略时一样
```

## 编译器的应对

| @ffi 参数 | 编译器的行为 | 开销 |
|-----------|------------|------|
| `"C"` | 直通，什么都不插 | 0 |
| `"Python"` | 参数/返回值自动 PyObject* 转换，refcount 管理 | 每次调用 |
| `"Java"` | JNIEnv 线程绑定，exception 检查 | 每次调用 |
| `"Lua"` | 参数到 Lua stack 的映射 | 每次调用 |
| `"Rust"` | 直通，等价于 C ABI | 0 |

## 与 @ 分类的关系

```
@ 分类：
├─ 元数据查询     → @typeInfo, @field, @hasField
├─ 编译控制       → @inline, @unroll, @section, @comptime, @ffi
└─ 安全检查       → @no_bounds_check
```

`@ffi` 是编译控制——不改变语义，只改变编译方式。

## 当前状态

设计完成，未实现。当前编译器只支持 `extern fn` 的 C ABI 调用（通过 `IR_CALL` 和 syscall 实现）。
