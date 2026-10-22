# @ 内建原语实现设计

## 概述

在 Core 中实现编译器内建原语系统。`@` 开头的标识符是编译器直接识别的能力入口，不通过标准库实现。对应 Zig 的 `@sizeOf`、`@typeInfo` 等内建机制。

三类功能：元数据查询、编译控制、安全检查。

## 核心原则

- 每个 `@` 有对应的 IR 语义节点（`IR_CONST` 带 provenance 标注），验证工具能从 IR 图看到原始操作
- 元数据查询在 IR gen 时已经算出值，emit 为 `IR_CONST`，不引入运行时指令
- `@comptime` 在编译期调用解释器执行，不产生运行时指令
- 编译控制和安全检查 emit 标注指令，由 pass 或后端消费

## IR 指令

| 内建 | IR 表示 | 说明 |
|------|---------|------|
| `@sizeOf(T)` | `IR_CONST dest, n, 0, 0, TI_INT` | 编译期已知 |
| `@alignOf(T)` | `IR_CONST dest, n, 0, 0, TI_INT` | 编译期已知 |
| `@fields(T)` | `IR_CONST dest, str_arr_ni, 0, 0, TI_STR` | 编译期构造数组 |
| `@field(T,n)` | `IR_CONST dest, field_info_ni` | 编译期构造结构体 |
| `@hasField(T,n)` | `IR_CONST dest, 0/1, 0, 0, TI_BOOL` | 编译期已知 |
| `@typeInfo(T)` | `IR_CONST dest, type_info_ni` | 编译期构造结构体 |
| `@comptime(e)` | 无 IR 节点（IR gen 时直接执行） | 解释器执行 |
| `@inline(fn)` | `IR_INLINE src1` | 优化提示 |
| `@no_bounds_check` | `IR_NO_BOUNDS_CHECK` | 后续 DEREF 跳过检查 |
| `@fast` | `IR_FAST` | 精度换速度 |

## 解析器

新增 `EXPR_AT` AST 节点：

```core
EXPR_AT : int = 46  // @内建: a=name_ni, b=args_node, c=0, iv=0, tv=0, data=0
```

在 `parse_primary` 中识别 `T_AT`：

```
T_AT：advance
  if next is T_IDENT:
    name_ni = tok_lexeme(next)
    if cur_tok == T_LPAREN: args = parse_call_args()
    return alloc_node(EXPR_AT, name_ni, args, 0, ...)
  else:
    error("expected identifier after @")
```

## 类型检查器

在 `checker` 中识别 `EXPR_AT`，根据 `name_ni` 分发：

```core
fn check_expr_at(node):
    name = istr_get(ast_a(node))
    args = ast_b(node)
    
    if name == "sizeOf":
        ti = type_of(ast_a(args))  // 参数是类型
        check_type_exists(ti)
        set_type(node, TI_INT)
        
    elif name == "alignOf":
        ti = type_of(ast_a(args))
        set_type(node, TI_INT)
        
    elif name == "fields":
        ti = type_of(ast_a(args))
        set_type(node, TI_STR)  // []string
        
    elif name == "hasField":
        ti = type_of(ast_a(args))
        field_name = ast_strval(ast_b(args))
        set_type(node, TI_BOOL)
        
    elif name == "field":
        ti = type_of(ast_a(args))
        set_type(node, TY_FIELDINFO)
        
    elif name == "typeInfo":
        ti = type_of(ast_a(args))
        set_type(node, TY_TYPEINFO)
        
    elif name == "comptime":
        inner = ast_a(args)
        check_expr(inner)
        set_type(node, get_type(inner))  // 透传内部表达式类型
        
    elif name == "inline":
        inner = ast_a(args)
        check_expr(inner)
        set_type(node, get_type(inner))  // 透传
        
    elif name == "no_bounds_check" or name == "fast":
        set_type(node, TI_UNIT)
        
    else:
        error("unknown @ builtin: " + name)
```

需要定义新类型 `TY_FIELDINFO` 和 `TY_TYPEINFO`，用于 `@field`/`@typeInfo` 的返回类型。

## IR 生成

在 `gen_expr` 中处理 `EXPR_AT`。元数据查询全部在编译期折叠为常量：

```core
fn gen_expr_at(node):
    name = istr_get(ast_a(node))
    args = ast_b(node)
    
    if name == "sizeOf":
        ti = ast_type_val(ast_a(args))
        sz = calc_type_size(ti)  // 类型大小
        v = new_ir_var("_sizeof", TI_INT)
        emit(IR_CONST, v, sz, 0, 0, TI_INT)
        return v
        
    elif name == "fields":
        ti = ast_type_val(ast_a(args))
        // 构建字符串数组常量
        arr_ni = build_field_names_array(ti)
        v = new_ir_var("_fields", TI_STR)
        emit(IR_CONST, v, arr_ni, 0, 0, TI_STR)
        return v
        
    elif name == "hasField":
        ti = ast_type_val(ast_a(args))
        fn2 = ast_b(args)  // field name expression
        // 检查字段是否存在
        exists = ti_has_field(ti, fn2)
        v = new_ir_var("_hasf", TI_BOOL)
        emit(IR_CONST, v, exists, 0, 0, TI_BOOL)
        return v
        
    elif name == "comptime":
        // 使用解释器执行表达式
        inner = ast_a(args)
        val = ir_interpret_expr(inner)
        return val  // 已经是 IR 变量
        
    elif name == "no_bounds_check":
        emit(IR_NO_BOUNDS_CHECK, -1, 0, 0, 0, 0)
        return -1
        
    elif name == "inline":
        inner_var = gen_expr(ast_a(args))
        emit(IR_INLINE, -1, inner_var, 0, 0, 0)
        return inner_var
```

## 需要的新类型

```core
// TypeInfo 结构体，@typeInfo(T) 的返回类型
TY_TYPEINFO : int = ...;  // struct { name: string, size: int, align: int, fields: []FieldInfo }

// FieldInfo 结构体，@field(T, name) 的返回类型
TY_FIELDINFO : int = ...;  // struct { name: string, offset: int, type: int }
```

具体实现方案：在 `checker`/`ir_gen` 中使用编译期已知的 struct layout 来构造返回值。`@typeInfo` 和 `@field` 返回的结构体在编译期构造，不需要运行时定义。

## @comptime 实现

`@comptime(expr)` 或 `@comptime { block }` 强制表达式在编译期执行：

1. IR gen 遇到 `@comptime` 时递归调用解释器执行表达式
2. 解释器执行并返回结果（IR 变量索引）
3. 该 IR 变量在解释器中已有值
4. IR gen 直接使用该变量

如果表达式无法在编译期求值（如依赖运行时输入），解释器报错。

## 实现清单

| # | 文件 | 改动 |
|---|------|------|
| 1 | `src/compiler/ast.cr` | 新增 EXPR_AT(46), IR_INLINE, IR_NO_BOUNDS_CHECK, IR_FAST 常量 |
| 2 | `src/compiler/parser.cr` | parse_primary 中识别 T_AT + T_IDENT，生成 EXPR_AT |
| 3 | `src/compiler/type_checker.cr` | 处理 EXPR_AT，按名称分发，验证参数 |
| 4 | `src/compiler/ir_gen.cr` | 处理 EXPR_AT，元数据查询折叠为 IR_CONST |
| 5 | `src/compiler/dataflow.cr` | 注册新 opcode 名字 |
| 6 | `src/compiler/opt.cr` | 跳过新 opcode |
| 7 | `src/arch/linux/ld/instr.cr` | IR_INLINE 等（仅标注，emit NOP） |
| 8 | `tests/suite/at_test.cr` | 测试 @ 内建 |

## 不包含的功能

- walk/step（属于并发模型）
- `@unroll` / `@section`（编译控制后续扩展）
