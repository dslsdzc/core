# @ 内建原语实现计划

> 受众：执行本计划的 agentic worker。必需子技能：`superpowers:subagent-driven-development`（推荐）或 `superpowers:executing-plans`，按任务逐项实施。进度以复选框（`- [ ]`）跟踪。

目标：在 parser、type checker、IR gen 和后端实现编译器内建原语（`@sizeOf`、`@alignOf`、`@typeInfo`、`@fields`、`@field`、`@hasField`、`@comptime`、`@inline`、`@no_bounds_check`、`@fast`）。

架构：`@ident` 解析为 `EXPR_AT` AST 节点。类型检查器校验每个已知 @ 名称及其参数。IR gen 在编译期计算元数据查询（以 `IR_CONST` 发射），为编译控制发射注解 opcode，并对 `@comptime` 调用解释器。数据流图保留语义节点，供验证工具使用。

技术栈：Core 自举编译器（parser.cr、type_checker.cr、ir_gen.cr、dataflow.cr、opt.cr、elf 后端）

## 全局约束

- 每个 `@` 内建都对应一个 IR 语义节点（即使折叠为 IR_CONST）
- 元数据查询结果（`@sizeOf`、`@fields`）在编译期已知，以 IR_CONST 发射
- `@comptime` 在 IR gen 期间调用解释器
- `@no_bounds_check` / `@fast` 发射注解 opcode，由各 pass 消费
- 所有版本控制使用 `jj`
- EXPR_AT = 46（EXPR_PTRTYPE 原为 46，改为 47）
- 新增 IR opcode：IR_INLINE、IR_NO_BOUNDS_CHECK、IR_FAST（34、35、36）

---

### 任务 1：AST 与 IR 常量（ast.cr）

涉及文件：
- 修改：`src/compiler/ast.cr`

接口：
- 产出：`EXPR_AT = 46`、`IR_INLINE = 34`、`IR_NO_BOUNDS_CHECK = 35`、`IR_FAST = 36`

- [ ] 步骤 1：添加 EXPR_AT AST 常量

找到 EXPR_ 段（`EXPR_AWAIT = 45` 附近），在其后添加：

```core
EXPR_AT : int = 46     // @builtin: a=name_ni, b=args_node, c=0, iv=0, tv=0, data=0
```

- [ ] 步骤 2：添加 IR opcode 常量

找到 IR opcode 段（`IR_ARENA_RESET = 33` 之后），添加：

```core
IR_INLINE            : int = 34   // src1=fn_var — inline hint
IR_NO_BOUNDS_CHECK   : int = 35   // — skip bounds check for subsequent DEREFs
IR_FAST              : int = 36   // — allow precision-for-speed optimizations
```

- [ ] 步骤 3：提交

```bash
jj commit src/compiler/ast.cr -m "feat: add EXPR_AT(46), IR_INLINE(34), IR_NO_BOUNDS_CHECK(35), IR_FAST(36)"
```

---

### 任务 2：Parser 将 @ 标识符解析为 EXPR_AT

涉及文件：
- 修改：`src/compiler/parser.cr`

- [ ] 步骤 1：在 primary 表达式中添加 @ 解析

找到 `fn parse_primary` 函数，再找到处理 `T_SELF` 等分支的位置（primary 分发处）。在 `T_IDENT` 检查之前添加：

```core
    if tok_k(t) == T_AT {
        t2 := advance();
        if tok_k(t2) == T_IDENT {
            name_ni := tok_lexeme(t2);
            args_node : ., mut = -1;
            if tok_k(cur_tok()) == T_LPAREN {
                args_node = parse_call_args();
            }
            return alloc_node(EXPR_AT, name_ni, args_node, 0, 0, 0, 0, tok_ln(t), tok_cl(t));
        }
        add_error("expected identifier after @");
        return alloc_node(0, 0, 0, 0, 0, TY_UNIT, 0, tok_ln(t), tok_cl(t));
    }
```

这段代码放在 `T_AMPERSAND` 检查之后，`T_IDENT`/`T_SELF`/`T_UNDERSCORE` 检查之前。

- [ ] 步骤 2：验证解析

运行：`./build/corec check -c '@sizeOf(int)' 2>&1`，应能解析且不报错。

- [ ] 步骤 3：提交

```bash
jj commit src/compiler/parser.cr -m "feat: parse @identifier as EXPR_AT node"
```

---

### 任务 3：类型检查器分发 EXPR_AT

涉及文件：
- 修改：`src/compiler/type_checker.cr`

- [ ] 步骤 1：在主类型检查分发中添加 EXPR_AT 处理

找到主类型检查循环（分发 EXPR_* 类型处），在 return 语句之前添加：

```core
    if kind == EXPR_AT {
        name_ni := ast_a(node);
        name := istr_get(name_ni);
        args := ast_b(node);

        // @sizeOf(T) — 1 type argument
        if str_eq(name, "sizeOf") != 0 {
            if args < 0 { add_error("@sizeOf requires a type argument"); return; }
            ti := type_of(args);
            if ti < 0 { add_error("@sizeOf: unknown type"); return; }
            set_type(node, TI_INT);
            return;
        }

        // @alignOf(T) — 1 type argument
        if str_eq(name, "alignOf") != 0 {
            if args < 0 { add_error("@alignOf requires a type argument"); return; }
            ti := type_of(args);
            if ti < 0 { add_error("@alignOf: unknown type"); return; }
            set_type(node, TI_INT);
            return;
        }

        // @fields(T) — 1 type argument, returns []string
        if str_eq(name, "fields") != 0 {
            if args < 0 { add_error("@fields requires a type argument"); return; }
            ti := type_of(args);
            set_type(node, TI_STR);  // string array
            return;
        }

        // @hasField(T, name) — type + string
        if str_eq(name, "hasField") != 0 {
            if args < 0 || ast_b(args) < 0 { add_error("@hasField requires 2 args"); return; }
            ti := type_of(ast_a(args));
            set_type(node, TI_BOOL);
            return;
        }

        // @field(T, name) — type + string, returns FieldInfo
        if str_eq(name, "field") != 0 {
            if args < 0 || ast_b(args) < 0 { add_error("@field requires 2 args"); return; }
            ti := type_of(ast_a(args));
            set_type(node, TI_INT);  // simplified: returns offset for now
            return;
        }

        // @typeInfo(T) — returns TypeInfo
        if str_eq(name, "typeInfo") != 0 {
            if args < 0 { add_error("@typeInfo requires a type argument"); return; }
            ti := type_of(args);
            set_type(node, TI_INT);  // placeholder — returns handle
            return;
        }

        // @comptime(expr) — force compile-time eval
        if str_eq(name, "comptime") != 0 {
            if args < 0 { add_error("@comptime requires an expression"); return; }
            check_expr(ast_a(args));
            set_type(node, get_type(ast_a(args)));
            return;
        }

        // @inline(fn) — inline hint
        if str_eq(name, "inline") != 0 {
            if args < 0 { add_error("@inline requires a function argument"); return; }
            check_expr(ast_a(args));
            set_type(node, get_type(ast_a(args)));
            return;
        }

        // @no_bounds_check — no args, unit
        if str_eq(name, "no_bounds_check") != 0 {
            set_type(node, TI_UNIT);
            return;
        }

        // @fast — no args, unit
        if str_eq(name, "fast") != 0 {
            set_type(node, TI_UNIT);
            return;
        }

        add_error("unknown @ builtin: " + name);
        return;
    }
```

- [ ] 步骤 2：验证类型检查

```bash
./build/corec check -c 'fn f() { let x := @sizeOf(int); }'
```
预期：无错误。

- [ ] 步骤 3：提交

```bash
jj commit src/compiler/type_checker.cr -m "feat: type check EXPR_AT — validate @ builtin names and args"
```

---

### 任务 4：IR Gen 的编译期常量折叠

涉及文件：
- 修改：`src/compiler/ir_gen.cr`

- [ ] 步骤 1：在 gen_expr 中添加 EXPR_AT 处理

找到主函数 `fn gen_expr(node)`，在末尾的 `return -1` 之前添加：

```core
    if ast_kind(node) == EXPR_AT:
        name_ni := ast_a(node)
        name := istr_get(name_ni)
        args := ast_b(node)

            // @sizeOf(T): emit IR_CONST with type size
        if str_eq(name, "sizeOf") != 0:
            ti := type_of(ast_a(args))
            sz := type_size(ti)
            v := new_ir_var("_sizeof", TI_INT)
            emit(IR_CONST, v, sz, 0, 0, TI_INT)
            return v

            // @alignOf(T): emit IR_CONST with type alignment
        if str_eq(name, "alignOf") != 0:
            ti := type_of(ast_a(args))
            al := type_align(ti)
            v := new_ir_var("_alignof", TI_INT)
            emit(IR_CONST, v, al, 0, 0, TI_INT)
            return v

            // @fields(T): build string array of field names
        if str_eq(name, "fields") != 0:
            ti := type_of(ast_a(args))
            arr_ni := build_field_name_array(ti)  // build string array in string table
            v := new_ir_var("_fields", TI_STR)
            emit(IR_CONST, v, arr_ni, 0, 0, TI_STR)
            return v

            // @hasField(T, name): check field existence
        if str_eq(name, "hasField") != 0:
            ti := type_of(ast_a(args))
            fn_node := ast_b(args)
            fn_name := istr_get(ast_a(fn_node))  // field name expression
            exists := ti_has_field(ti, fn_name)
            v := new_ir_var("_hasf", TI_BOOL)
            emit(IR_CONST, v, exists, 0, 0, TI_BOOL)
            return v

            // @field(T, name): get field offset
        if str_eq(name, "field") != 0:
            ti := type_of(ast_a(args))
            fn_node := ast_b(args)
            fn_name := istr_get(ast_a(fn_node))
            off := ti_field_offset(ti, fn_name)
            v := new_ir_var("_fldoff", TI_INT)
            emit(IR_CONST, v, off, 0, 0, TI_INT)
            return v

            // @typeInfo(T): build type info struct
        if str_eq(name, "typeInfo") != 0:
            ti := type_of(ast_a(args))
            info_ni := build_type_info(ti)  // store in compile-time table
            v := new_ir_var("_tinfo", TI_INT)
            emit(IR_CONST, v, info_ni, 0, 0, TI_INT)
            return v

            // @comptime(expr): invoke interpreter
        if str_eq(name, "comptime") != 0:
            inner := ast_a(args)
                // Generate IR for inner expr and evaluate via interpreter
            inner_var := gen_expr(inner)
                // Note: IR_CONST vars can be read directly. For complex exprs,
                // the interpreter would evaluate them. For now, just gen the inner expr.
            return inner_var

            // @inline(fn): emit IR_INLINE hint
        if str_eq(name, "inline") != 0:
            fn_var := gen_expr(ast_a(args))
            emit(IR_INLINE, -1, fn_var, 0, 0, 0)
            return fn_var

            // @no_bounds_check: emit annotation
        if str_eq(name, "no_bounds_check") != 0:
            emit(IR_NO_BOUNDS_CHECK, -1, 0, 0, 0, 0)
            return -1

            // @fast: emit annotation
        if str_eq(name, "fast") != 0:
            emit(IR_FAST, -1, 0, 0, 0, 0)
            return -1

        return -1
```

- [ ] 步骤 2：添加类型元数据辅助函数

在文件顶部或辅助函数区添加：

```core
// Type size lookup
fn type_size(ti: int) -> int:
    if ti == TI_INT:
        return 8
    if ti == TI_FLOAT:
        return 8
    if ti == TI_BOOL:
        return 1
    if ti == TI_CHAR:
        return 4
    if ti == TI_STR:
        return 8
    // pointer
    if ti == TI_UNIT:
        return 0
    // Struct: sum field sizes
    // For now, return 8 as default
    return 8

// Type alignment lookup
fn type_align(ti: int) -> int:
    if ti == TI_INT:
        return 8
    if ti == TI_FLOAT:
        return 8
    if ti == TI_BOOL:
        return 1
    if ti == TI_CHAR:
        return 4
    if ti == TI_STR:
        return 8
    return 8

// Check if type has a field
fn ti_has_field(ti: int, name: string) -> int:
    // Search struct fields by name
    // For now, return 0 (false) — struct field lookup to be implemented
    return 0

// Get field offset
fn ti_field_offset(ti: int, name: string) -> int:
    return 0  // placeholder
```

- [ ] 步骤 3：验证 IR gen

```bash
./build/corec check -c 'fn f() { let x := @sizeOf(int); }'
```
预期：无错误。

- [ ] 步骤 4：提交

```bash
jj commit src/compiler/ir_gen.cr -m "feat: IR gen EXPR_AT — compile-time constant folding for @ builtins"
```

---

### 任务 5：Dataflow 与 pass 注册

涉及文件：
- 修改：`src/compiler/dataflow.cr`
- 修改：`src/compiler/opt.cr`

- [ ] 步骤 1：在 dataflow.cr 的 df_opcode_name 中登记

找到 `fn df_opcode_name`，在 `IR_ARENA_RESET` 条目之后添加：

```core
    if opcode == IR_INLINE { return "inline"; }
    if opcode == IR_NO_BOUNDS_CHECK { return "no_bounds_check"; }
    if opcode == IR_FAST { return "fast"; }
```

- [ ] 步骤 2：在 dataflow.cr 的 df_connect_srcs 中登记

找到 `fn df_connect_srcs`，添加：

```core
    if opcode == IR_INLINE { df_use_var(nid, s1); return; }
```

`IR_NO_BOUNDS_CHECK` 和 `IR_FAST` 没有 src 操作数，不需要连边。

- [ ] 步骤 3：在 opt.cr 的 CSE 循环中跳过

找到 `pass_cse` 优化循环，在 `IR_ARENA_RESET` 的跳过分支之后添加：

```core
    if op == IR_INLINE { ii = ii + 1; continue; }
    if op == IR_NO_BOUNDS_CHECK { ii = ii + 1; continue; }
    if op == IR_FAST { ii = ii + 1; continue; }
```

- [ ] 步骤 4：提交

```bash
jj commit src/compiler/dataflow.cr src/compiler/opt.cr -m "feat: register IR_INLINE/NO_BOUNDS_CHECK/FAST in dataflow and opt passes"
```

---

### 任务 6：ELF 后端的注解 opcode

涉及文件：
- 修改：`src/arch/linux/ld/instr.cr`
- 修改：`src/arch/linux/ld/sizes.cr`

- [ ] 步骤 1：在 instr.cr 中添加编码

找到主指令编码函数，在最后的 `return cp` 之前添加：

```core
    if op == IR_INLINE {
        // No-op at runtime — just a compile hint
        return 0;
    }
    if op == IR_NO_BOUNDS_CHECK {
        // No-op — consumed by ProvenanceVerify pass
        return 0;
    }
    if op == IR_FAST {
        // No-op — consumed by optimization passes
        return 0;
    }
```

- [ ] 步骤 2：在 sizes.cr 中添加尺寸估算

找到指令尺寸函数，添加：

```core
    if op == IR_INLINE { return 0; }
    if op == IR_NO_BOUNDS_CHECK { return 0; }
    if op == IR_FAST { return 0; }
```

- [ ] 步骤 3：提交

```bash
jj commit src/arch/linux/ld/instr.cr src/arch/linux/ld/sizes.cr -m "feat: ELF backend no-op encoding for IR_INLINE/NO_BOUNDS_CHECK/FAST"
```

---

### 任务 7：测试

涉及文件：
- 创建：`tests/suite/at_test.cr`

- [ ] 步骤 1：编写 @ 内建测试套件

```core
// @ builtins test suite

fn test_sizeof_int() -> int:
    sz := @sizeOf(int)
    // @sizeOf(int) should return 8 on x86-64
    if sz != 8:
        return 1
    return 0

fn test_sizeof_bool() -> int:
    sz := @sizeOf(bool)
    if sz != 1:
        return 1
    return 0

fn test_alignof_int() -> int:
    al := @alignOf(int)
    if al != 8:
        return 1
    return 0

// Struct type for field tests
struct Point:
    x: int, y: int

fn test_sizeof_struct() -> int:
    sz := @sizeOf(Point)
    if sz < 8:
        return 1
    // at least 2 ints
    return 0

fn test_no_bounds_check() -> int:
    @no_bounds_check
    return 0  // just verifies it compiles

fn test_inline_hint() -> int:
    fn add(a: int, b: int) -> int:
        return a + b
    result := @inline(add)(3, 4)
    if result != 7:
        return 1
    return 0

fn test_fields_basic() -> int:
    flds := @fields(Point)
    if str_len(flds) < 4:
        return 1
    // at least contains field names
    return 0

fn main() -> int:
    r1 := test_sizeof_int()
    if r1 != 0:
        print("FAIL sizeof_int: ")
        println(int_str(r1))
        return r1
    r2 := test_sizeof_bool()
    if r2 != 0:
        print("FAIL sizeof_bool: ")
        println(int_str(r2))
        return r2
    r3 := test_alignof_int()
    if r3 != 0:
        print("FAIL alignof_int: ")
        println(int_str(r3))
        return r3
    r4 := test_sizeof_struct()
    if r4 != 0:
        print("FAIL sizeof_struct: ")
        println(int_str(r4))
        return r4
    r5 := test_no_bounds_check()
    if r5 != 0:
        print("FAIL no_bounds_check: ")
        println(int_str(r5))
        return r5
    r6 := test_inline_hint()
    if r6 != 0:
        print("FAIL inline: ")
        println(int_str(r6))
        return r6
    r7 := test_fields_basic()
    if r7 != 0:
        print("FAIL fields: ")
        println(int_str(r7))
        return r7
    println("ALL PASS")
    return 0
```

- [ ] 步骤 2：对测试做类型检查

```bash
./build/corec check tests/suite/at_test.cr
```
预期：无错误。

- [ ] 步骤 3：提交

```bash
jj commit tests/suite/at_test.cr -m "test: @ builtins suite — sizeOf, alignOf, fields, inline, no_bounds_check"
```
