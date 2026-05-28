# Core IR Schema — 实现层 IR (.ccr)

## 概述

`.ccr`（Core Control-flow Representation）是编译前后端之间的接口文件。`corec`（前端）输出 `.ccr`，`corearch`（后端）读取 `.ccr` 并生成目标平台代码。

## 二进制格式

所有整数采用小端序（little-endian）。

### 文件头（36 字节）

| 偏移 | 大小 | 字段 | 说明 |
|------|------|------|------|
| 0 | 4 | magic | `0x31524343`（ASCII `CCR1`） |
| 4 | 4 | version | 版本号，当前为 1 |
| 8 | 4 | func_count | 函数数量 |
| 12 | 4 | instr_count | IR 指令数量 |
| 16 | 4 | var_count | IR 变量数量 |
| 20 | 4 | str_count | 字符串表条目数 |
| 24 | 4 | str_const_count | 字符串常量索引数 |
| 28 | 4 | struct_count | 结构体定义数 |
| 32 | 4 | enum_count | 枚举定义数 |

### 字符串表

`str_count` 个条目，每个条目：

| 偏移 | 大小 | 字段 | 说明 |
|------|------|------|------|
| 0 | 4 | len | 字符串字节长度 |
| 4 | len | data | UTF-8 字符串内容 |

### 函数元信息

`func_count` 个条目，每个条目 28 字节：

| 偏移 | 大小 | 字段 | 说明 |
|------|------|------|------|
| 0 | 4 | name_idx | 函数名在字符串表中的索引 |
| 4 | 4 | param_count | 参数数量 |
| 8 | 4 | ret_type | 返回类型（TI_* 值） |
| 12 | 4 | instr_start | 指令数组中的起始位置 |
| 16 | 4 | instr_count | 指令数量 |
| 20 | 4 | var_start | 变量数组中的起始位置 |
| 24 | 4 | var_count | 变量数量 |

### IR 指令数组

`instr_count` 个条目，每个条目 24 字节：

| 偏移 | 大小 | 字段 | 说明 |
|------|------|------|------|
| 0 | 4 | opcode | IR 操作码 |
| 4 | 4 | dest | 目标变量索引（-1 = 无结果） |
| 8 | 4 | src1 | 操作数 1 |
| 12 | 4 | src2 | 操作数 2 |
| 16 | 4 | src3 | 额外数据（标签、字段索引等） |
| 20 | 4 | type_kind | 类型信息 |

### IR 变量数组

`var_count` 个条目，每个条目 12 字节：

| 偏移 | 大小 | 字段 | 说明 |
|------|------|------|------|
| 0 | 4 | name_idx | 变量名在字符串表中的索引 |
| 4 | 4 | id | 变量 ID |
| 8 | 4 | type_kind | 变量类型 |

### 字符串常量索引数组

`str_const_count` 个条目，每个条目 4 字节：字符串表索引。

### 结构体定义数组

`struct_count` 个条目：

| 偏移 | 大小 | 字段 | 说明 |
|------|------|------|------|
| 0 | 4 | name_idx | 结构体名在字符串表中的索引 |
| 4 | 4 | field_count | 字段数量 |
| 8 | field_count*8 | fields | 每个字段 `[name_idx(4), type(4)]` |

### 枚举定义数组

`enum_count` 个条目：

| 偏移 | 大小 | 字段 | 说明 |
|------|------|------|------|
| 0 | 4 | name_idx | 枚举名在字符串表中的索引 |
| 4 | 4 | variant_count | 变体数量 |
| 8 | — | variants | 见下方 |

每个变体：

| 偏移 | 大小 | 字段 | 说明 |
|------|------|------|------|
| 0 | 4 | name_idx | 变体名在字符串表中的索引 |
| 4 | 4 | type_count | 变体包含的字段类型数量 |
| 8 | type_count*4 | types | 字段类型（TI_* 值） |

## IR 操作码

| 编号 | 名称 | 语义 |
|------|------|------|
| 0 | NOP | 空操作 |
| 1 | CONST | dest = 常量(src1) |
| 2 | BINARY | dest = src1 OP src2（op 在 src3） |
| 3 | UNARY | dest = OP src1 |
| 4 | CALL | dest = func(src1..src1+src2-1)（func 名在 src3） |
| 5 | RETURN | return src1（src1=-1 表示 void） |
| 6 | ALLOC | 分配栈空间 |
| 7 | ALLOC_STRUCT | 分配结构体（src3=结构体名索引） |
| 8 | ALLOC_ARRAY | 分配数组（src1=元素数量） |
| 9 | STORE | src1 = src2（变量赋值） |
| 10 | LOAD | dest = src1 |
| 11 | LOAD_FIELD | dest = src1.field(src3) |
| 12 | STORE_FIELD | src1.field(src3) = src2 |
| 13 | LOAD_INDEX | dest = src1[常量 src3] |
| 14 | STORE_INDEX | src1[常量 src3] = src2 |
| 15 | LOAD_INDEX_VAR | dest = src1[变量 src2] |
| 16 | STORE_INDEX_VAR | src1[src2] = dest |
| 17 | MAKE_ENUM | 创建枚举实例（src1=变体名索引） |
| 18 | REF | dest = &src1 |
| 19 | BRANCH | if src1 goto src2 else src3 |
| 20 | JUMP | goto src1 |
| 21 | LABEL | 标签 src1 |
| 22 | PHI | dest = phi(src1..src1+src2-1) |
| 23 | LOAD_ENUM_TAG | dest = tag_of(src1) |
| 24 | SLICE | dest = src1[src2:src3] |
| 25 | DEREF | dest = *src1 |
| 26 | STORE_PTR | *src1 = src2 |

## 类型常量（TI_*）

| 值 | 名称 | 说明 |
|----|------|------|
| 0 | TI_INT | 整数 |
| 1 | TI_FLOAT | 浮点数 |
| 2 | TI_BOOL | 布尔值 |
| 3 | TI_STR | 字符串 |
| 4 | TI_UNIT | 空类型 |
| 5 | TI_NEVER | 发散类型 |
| 6 | TI_CHAR | 字符 |
