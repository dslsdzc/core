# 动态类型实现设计


> **术语注记（2026-08-15）**：本规格为历史设计记录，其中「数据流图」（及「RVSDG 式」）为当时术语；该结构后定名为 **HDFG（Holographic Dataflow Graph，全息数据流图）**，术语演进见 `docs/project-book.md`。正文保留历史原样。

## 概述

在 Core 中实现 `dyn` 动态类型。声明为 `dyn` 的变量可以在不同路径中持有不同类型的值，编译器从数据流图中推导所有可能的类型，在汇合点生成 `(tag, value)` 对，后续代码根据 tag 分派不同的执行路径。

**核心原则**：
- 动态值不是胖结构，没有装箱。
- 单路径 `dyn` 变量 = 裸值，零运行时开销。
- 多路径 `dyn` 变量 = 编译期确定的 `(tag, value)` 对。
- 编译器全量知道所有分支的可能类型集合。

## 类型系统

### 新增类型常量

```core
T_DYN  : int = 48;   // token: dyn 关键字
TI_DYN : int = 7;    // 类型索引
TYP_DYN : int = 11;  // 类型种类: data = 该点已知的具体类型集合
```

`TYP_DYN` 的 `data` 字段在编译期追踪该点的可能类型集合。单路径时退化为 `TYP_BASE`/`TYP_NAMED`（零开销），多路径时保持 `TYP_DYN`。

### 类型集合编码

```core
// 在 checker 中，每个 dyn 变量关联一个"可能类型集合"。
// 编码为 bitmap (64-bit，支持最多 64 种可能类型):
//   bit 0  = TI_INT
//   bit 1  = TI_FLOAT
//   bit 2  = TI_BOOL
//   bit 3  = TI_STR
//   bit 7  = TI_STRUCT(offset)
//   简化: 使用 g_type_set[] 数组 + count
g_type_set : string, mut;  // 每变量: int[] 可能类型索引
```

## 解析器

### 关键字

在 `src/compiler/keywords.cr` 中添加：

```core
T_DYN : int = 48;
```

### `parse_type` 中处理

```core
// 在 parse_type 中，当遇到 `dyn` 关键字时返回类型节点
if str_eq(lex, "dyn") != 0 {
    return alloc_node(EXPR_DYN, 0, 0, 0, 0, TI_DYN, 0, line, col);
}
```

### 变量声明

```core
x : dyn = 42;
```

标准 `:` 类型标注语法直接支持。解析器在 `parse_decl` 中遇到 `dyn` 时设置 `ast_type_val` 为 `TI_DYN`。

## 类型检查器

### dyn 类型规则

| 赋值 | 行为 |
|------|------|
| `dyn := int` | 记录 int ∈ 类型集合 |
| `dyn := string` | 记录 string ∈ 类型集合 |
| `dyn := dyn` | 合并两个类型集合 |
| `dyn OP int` | 检查 OP 在类型集合中的所有类型上是否合法 |
| `dyn.foo()` | 检查 `.foo()` 在类型集合中的所有类型上是否存在 |

### 控制流合并

在 if/else、match、for 等控制流汇合点检查 `dyn` 变量的类型集合：

```core
// 伪代码: 合并两个路径的类型集合
fn merge_type_sets(target: int, path_a_set: int, path_b_set: int) {
    // 如果两个路径的类型集合相同 → 无需变更
    // 如果两个路径的类型集合不同 → 合并为 TYP_DYN
    // 单路径 → 退化为基础类型（零开销）
}
```

### 方法/函数调用验证

```core
x : dyn = cond ? 42 : "hello";
x.len();
// 路径 A: 42 → int → 无 .len() → 编译错误
// 路径 B: "hello" → string → 有 .len() → OK
// 结果: 编译错误（int 上没有 len 方法）
```

如果类型集合中的所有类型都有对应方法，编译器在 IR 中为每种类型生成一条调用路径。

## IR 表示

### 新增 IR 指令

```core
IR_DYN_TAG   : int = 41;  // dest=tag_var, s1=dyn_var — 提取 dyn 的 tag
IR_DYN_VAL   : int = 42;  // dest=val_var, s1=dyn_var — 提取 dyn 的 value（按已知类型）
IR_DYN_PACK  : int = 43;  // dest=dyn_var, s1=val_var, s2=type_idx — 打包成 dyn
IR_DYN_DISPATCH : int = 44; // s1=dyn_var, s2=type_list_ni — 按 tag 分派执行
```

### 变量宽度

- 单路径 `dyn`：编译期已知确切类型 → 变量宽度 = 该类型宽度（8 字节，零开销）。
- 多路径 `dyn`：编译期已知所有可能类型 → 变量宽度 = 16 字节（`{ tag: int, value: [8]byte }`）。

```core
// 在 IR 变量表中新增字段
OFF_IRV_WIDTH : int = 24;  // 8 或 16
ESZ_IRV_NEW   : int = 32;  // 旧 24 → 新 32（兼容现有 3 字段布局）
```

### 单路径优化

```core
x : dyn = 42;     // 编译期知道: x 的类型 = int（退化为裸值）
y := x + 1;       // 直接加法，不需要 tag 检查
```

```core
x : dyn = cond ? 42 : "hello";
// 编译期知道: x ∈ {int, string}
// x 在 IR 中是 { tag: int|string, value: 8bytes }
y := x + 1;
// → 编译为:
//   if x.tag == int: y = x.value_int + 1
//   if x.tag == string: y = str_to_int(x.value_str) + 1
```

## IR 生成

### `EXPR_DYN` 处理

```core
// 在 gen_expr 中:
if ast_kind(node) == EXPR_DYN {
    // dyn 类型表达式（仅类型位置，无值）
    return -1;
}

// 在变量声明中:
if declared_type == TI_DYN {
    // 检查 RHS 类型初值
    // 如果 RHS 类型已知 → 单路径 dyn，emit 裸值
    // 否则 → 多路径 dyn
}
```

### 控制流汇合点

```core
// if/else 汇合:
if cond {
    x = 42;       // 路径 A: x = int
} else {
    x = "hello";  // 路径 B: x = string
}
// 汇合后: x ∈ {int, string}
// IR gen:
//   路径 A: IR_DYN_PACK x, 42, TI_INT
//   路径 B: IR_DYN_PACK x, "hello", TI_STR
//   汇合: x 是 {tag, value} 对
```

### 方法派发

```core
x.len();
// IR gen:
//   IR_DYN_DISPATCH x, [int_methods, str_methods]
//   → emit 跳转表 (tag→method)
//   → 每个 case: IR_DYN_VAL + IR_CALL
```

## 后端（ELF）

### `IR_DYN_TAG` / `IR_DYN_VAL` / `IR_DYN_PACK` / `IR_DYN_DISPATCH`

| 指令 | 编码 |
|------|------|
| IR_DYN_TAG | 从 16 字节 dyn 中读前 8 字节（tag） |
| IR_DYN_VAL | 从 16 字节 dyn 中读后 8 字节（value） |
| IR_DYN_PACK | 写 tag + value 到 16 字节对 |
| IR_DYN_DISPATCH | 查跳转表（tag→地址），间接跳转 |

### 跳转表布局

```asm
; IR_DYN_DISPATCH 编译为:
load x.tag
cmp tag, 0
je .case_int
cmp tag, 1
je .case_str
jmp .type_error

.case_int:
  load x.value → rdi
  call int_method
  jmp .done

.case_str:
  load x.value → rdi
  call string_method
  jmp .done

.type_error:
  panic

.done:
```

## 自动类型转换

边界转换在 IR gen 时静态插入：

```core
x : dyn = 42;
y := x + 1;     // int + int → 直接加法（x 在这是裸 int）
```

```core
x : dyn = "42";
y := x + 1;     // string + int → str_to_int + 加法（自动插转换）
```

转换规则表（编译期，不依赖运行时）：

| 源类型 → 目标类型 | 行为 |
|------------------|------|
| int → string | `int_str()` |
| string → int | `str_int()` |
| int → float | `int_to_float()` |
| float → int | `float_to_int()` |

跨 `dyn` 边界访问时，编译器如果发现「期望类型 ≠ 实际类型」且存在转换路径，自动插入转换代码；不存在转换路径时报编译错误。

## 实现清单

| # | 文件 | 改动 |
|---|------|------|
| 1 | `src/compiler/ast.cr` | TI_DYN(7), TYP_DYN(11), IR_DYN_TAG/VAL/PACK/DISPATCH(41-44) |
| 2 | `src/compiler/keywords.cr` | T_DYN(48) token |
| 3 | `src/compiler/parser.cr` | `dyn` keyword + parse_type 处理 + 变量声明 |
| 4 | `src/compiler/checker.cr` | 类型集合追踪 + 控制流合并 + 方法验证 |
| 5 | `src/compiler/ir_gen.cr` | IR_DYN_PACK 在赋值时 emit、IR_DYN_DISPATCH 在调用时 emit、自动转换 |
| 6 | `src/compiler/dataflow.cr` | 注册新 opcode |
| 7 | `src/compiler/opt.cr` | 跳过新 opcode |
| 8 | `src/compiler/ccr_io.cr` | 序列化 |
| 9 | `src/arch/linux/ld/elf.cr` | g_type_set 全局变量 |
| 10 | `src/arch/linux/ld/instr.cr` | DYN_TAG/VAL/PACK/DISPATCH 编码 |
| 11 | `src/arch/linux/ld/sizes.cr` | 大小估算 |
| 12 | `tests/suite/dyn_test.cr` | 测试 |
