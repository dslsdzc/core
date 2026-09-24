# FFI 实现设计

## 概述

在 Core 中实现完整的 FFI。支持 `extern fn` 声明外部函数、C ABI 调用、多语言 `@ffi` 注解自动类型编组。利用现有的 `.so` 动态链接基础设施（PLT/GOT/符号解析）。

## 核心原则

- **C ABI 是默认接口**：所有语言最终通过 C ABI 对接。
- **`@ffi` 是编译控制**：不改变语义，只改变调用方式的生成。
- **类型编组在 IR gen 时静态插入**：`@ffi("Python")` 在每个调用点插入 `PyObject*` 转换代码。
- **`.so` 链接已有基础设施**：`ctx_add_plt`/`g_x86_ext_rel` 等直接复用。

## 语法

### `extern fn` 声明

```core
extern fn read_file(path: *const u8) -> *mut u8;
extern fn write(fd: i32, buf: *const u8, len: i32) -> i32;
extern fn getchar() -> i32;
```

### `@ffi` 多语言注解

```core
@ffi("C") extern fn printf(fmt: *const u8, ...) -> i32;
@ffi("Python") extern fn py_call(obj: dyn, method: string) -> dyn;
@ffi("Java") extern fn java_call(env: dyn, obj: dyn, method: string) -> dyn;
```

## 类型映射

### C 类型 ↔ Core 类型

| C 类型 | Core 类型 | 说明 |
|--------|----------|------|
| `int`, `i32` | `int` | 32 位整数 |
| `i64` | `int` | 64 位整数 |
| `float` | `float` | 32 位浮点 |
| `double` | `float` | 64 位浮点 |
| `char` | `char` | 8 位字符 |
| `*const u8` | `string` | 只读字节指针 |
| `*mut u8` | `string` | 可写字节指针 |
| `void` | `unit` | 无返回值 |
| `...` | variadic | 可变参数 |

### Python 类型编组

| Python → Core | Core → Python |
|---------------|---------------|
| `PyObject*` → `dyn` | `dyn` → `PyObject*` |
| `int` → `int` | `int` → `PyLong_FromLong` |
| `str` → `string` | `string` → `PyUnicode_FromString` |
| `list` → `[dyn]` | `[dyn]` → `PyList_New` |
| `dict` → `dyn` | `dyn` → `PyDict_New` |

## 实现架构

### 文件结构

| 文件 | 职责 | 代码量 |
|------|------|--------|
| `parser.cr` | `extern fn` + `@ffi` 解析 | ~40 行 |
| `checker.cr` | extern 函数类型检查 | ~50 行 |
| `ir_gen.cr` | extern 调用 + 类型编组生成 | ~100 行 |
| `linker.cr` | `.so` 自动加载 + PLT 注册 | ~60 行 |

### 1. 解析器

**新增 Token**：
```core
T_EXTERN : int = 100;  // extern 关键字
```

**`parse_extern_fn`**：在 `parse_declaration` 中处理 `extern fn`：

```core
if tok_k(cur_tok()) == T_EXTERN {
    advance_tok();
    // 检查 @ffi("...") 注解
    ffi_lang : ., mut = "C";
    if tok_k(cur_tok()) == T_AT {
        // @ffi("Python") 解析
        ffi_lang = parse_ffi_annotation();
    }
    // 解析 fn name(args) -> ret;
    fn_node := parse_fn_declaration();
    // 标记为 extern 函数
    ast_set_data(fn_node, str_intern(ffi_lang));
    // 不解析函数体
    return fn_node;
}
```

### 2. 检查器

- `extern fn` 不需要函数体，只做签名检查。
- 参数类型和返回类型校验（是否可编组）。
- `@ffi("Python")` 的参数类型校验（`dyn` 类型是否合理）。

### 3. IR 生成

**`extern` 调用点的代码生成**：

```core
if is_extern_func(func_ni) {
    ffi_lang := get_ffi_lang(func_ni);
    if str_eq(ffi_lang, "C") != 0 {
        // C ABI：直通调用
        emit(IR_CALL_EXTERN, dest, func_ni, first_arg, arg_count, 0);
    } else if str_eq(ffi_lang, "Python") != 0 {
        // Python：插入 PyObject* 转换
        // 参数：dyn → PyObject*
        // 返回值：PyObject* → dyn
        // 插入 refcount 管理
        emit_python_marshal(dest, func_ni, first_arg, arg_count);
    }
}
```

### 4. 链接器集成

在链接阶段，`extern` 函数自动触发 `.so` 加载：

```core
// 在 ldd.cr 中处理 extern 函数
fn link_extern_func(func_ni: int) {
    // 根据函数名查找 .so
    // 如果已经通过 reg_so_funcs 注册，直接使用
    // 否则搜索默认路径
    lib_name := "lib" + get_func_module(func_ni) + ".so";
    ctx_add_so(lib_name);
    ctx_add_plt(func_name, so_idx);
}
```

## 已有基础设施（直接复用）

| 组件 | 文件 | 用途 |
|------|------|------|
| `ctx_add_so` | `ld.cr` | 添加 .so 到链接列表 |
| `ctx_add_plt` | `ld.cr` | 添加 PLT 条目 |
| `so_find` | `ld.cr` | .so 符号查找 |
| `g_x86_ext_rel_*` | `elf.cr` | 外部重定位追踪 |
| `patch_relocs` | `ld.cr` | 调用地址修复 |
| `reg_so_funcs` | `module.cr` | .so 函数签名注册 |

## 实现清单

| # | 文件 | 改动 |
|---|------|------|
| 1 | `src/compiler/ast.cr` | T_EXTERN token, EXPR_EXTERN node, IR_CALL_EXTERN(45) |
| 2 | `src/compiler/parser.cr` | `extern fn` 解析 + `@ffi` 注解 |
| 3 | `src/compiler/checker.cr` | extern 签名检查 |
| 4 | `src/compiler/ir_gen.cr` | extern 调用 + 类型编组 |
| 5 | `src/arch/linux/ld/instr.cr` | IR_CALL_EXTERN 编码 |
| 6 | `src/arch/linux/ld/sizes.cr` | 大小估算 |
| 7 | `tests/suite/ffi_test.cr` | 测试 |
