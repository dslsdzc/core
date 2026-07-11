# Core IR Schema — 数据流图 (.cir / .csr)

## 概述

Core 编译器使用两种中间表示：

| 格式 | 全称 | 用途 | 生产者 | 消费者 |
|------|------|------|--------|--------|
| `.cir` | Core IR Graph | 数据流图 + 规约约束（验证 IR） | `corec`（前端） | 验证工具 / `corearch` / 解释器 |
| `.ccr` | Core Control-flow Representation | 线性 CFG IR（前后端接口） | `corec`（前端） | `corearch`（后端） |

**`.cir` 是 Core 的验证核心。** 它承载程序的完整语义（数据流图）。验证工具消费 `.cir` + `.csr`（规约约束元数据）进行验证。

自托管编译器在 IR 生成期间同时构建数据流图（`.cir`）和线性 IR（`.ccr`），然后 `lower_to_ccr()` 将图节点拷贝为线性指令数组供 x86-64 后端消费。

---

## 一、核心设计：图即验证

```
.cir = 程序的数据流图 + 规约约束
         ↓
验证工具消费 .cir：
  1. 编译器已证明的约束（自动推导标签）标注为 ✓
  2. 用户写的约束标注为 pending
  3. 验证工具尝试证明 pending 约束
  4. 输出：每个约束绿/黄/红
```

**规约约束是图的一等公民。** `#check`、`#ensure`、`#invariant` 和 `spec fn` 的身体都编译为 `.cir` 图上的节点，与普通指令节点并列。验证工具遍历图时，普通节点描述"程序做什么"，规约节点描述"程序应该做什么"，两者在同一张图上。

---

## 二、二进制 `.csr` 格式（v1）

`.csr` 是规约约束的二进制序列化格式——将内存中的 TagNode（约束元数据）数组序列化为文件，与 `.cir`（DFNode 数据流图）配套。

### 整体布局

```
[文件头：36 字节]
[DFNode 数组：dataflow_node_count × 64 字节]
[约束节点数组（可选）：tag_node_count × 40 字节]
[DFEdge 数组：edge_count × 24 字节]
[字符串表：变长]
[函数元信息数组：func_count × 28 字节]
[符号引用表：变长]
```

### 文件头（36 字节）

| 偏移 | 大小 | 字段 | 说明 |
|------|------|------|------|
| 0 | 4 | magic | `0x31524343`（ASCII `CSR1`） |
| 4 | 4 | version | 版本号，当前为 1 |
| 8 | 4 | dataflow_node_count | 数据流节点数量 |
| 12 | 4 | tag_node_count | 规约约束节点数量 |
| 16 | 4 | edge_count | 边数量 |
| 20 | 4 | func_count | 函数数量 |
| 24 | 4 | str_count | 字符串表条目数 |
| 28 | 4 | symbol_ref_count | 符号引用数 |
| 32 | 4 | reserved | 保留 |

### DFNode（64 字节，同现有内存格式）

| 偏移 | 大小 | 字段 | 说明 |
|------|------|------|------|
| 0 | 8 | opcode | IR 操作码 |
| 8 | 8 | dest_var | 目标变量索引（-1 = 无结果） |
| 16 | 8 | src1 | 操作数 1 |
| 24 | 8 | src2 | 操作数 2 |
| 32 | 8 | src3 | 额外数据 |
| 40 | 8 | type_kind | 类型（TI_* 值） |
| 48 | 8 | first_edge | 首条出边索引（-1 = 无） |
| 56 | 8 | edge_count | 出边数量 |

DFNode 覆盖两种节点：普通指令节点（opcode ≤ IR_AWAIT）和规约约束节点（opcode ≥ IR_SPEC_REQUIRES）。

### 约束节点（TagNode，40 字节）

每个 `#check`、`#ensure`、`#invariant` 或 `spec fn` 中的约束编译为一个 TagNode：

| 偏移 | 大小 | 字段 | 说明 |
|------|------|------|------|
| 0 | 4 | tag_kind | 约束类型（见下文） |
| 4 | 4 | target_node | 绑定的 DFNode 索引（-1 = 全局） |
| 8 | 4 | target_symbol | 绑定的符号引用索引（-1 = 无） |
| 12 | 4 | condition_node | 条件表达式所在的 DFNode 索引 |
| 16 | 4 | status | 验证状态：0=unproven, 1=auto_proven, 2=user_proven |
| 20 | 4 | source_line | 源文件行号 |
| 24 | 16 | reserved | 保留 |

**约束类型（tag_kind）：**

| 值 | 名称 | 说明 |
|----|------|------|
| 0 | TAG_AUTO_LABEL | 编译器自动推导的标签（如 `#pure`） |
| 1 | TAG_CHECK | 前置条件（`#check(...)`） |
| 2 | TAG_ENSURE | 后置条件（`#ensure(...)`） |
| 3 | TAG_INVARIANT | 类型不变量（`#invariant(...)`） |
| 4 | TAG_LOOP_INVARIANT | 循环不变量 |
| 5 | TAG_VARIANT | 终止度量 |
| 6 | TAG_SPEC_FN | 检查函数引用 |
| 7 | TAG_USER_TAG | 自定义标签 |

### DFEdge（24 字节，同现有内存格式）

| 偏移 | 大小 | 字段 | 说明 |
|------|------|------|------|
| 0 | 8 | from_node | 源节点 ID |
| 8 | 8 | to_node | 目标节点 ID |
| 16 | 8 | next_out | 同一源节点的下一条出边索引（-1 = 结尾） |

边使用邻接列表结构：每个节点通过 `first_edge` → `next_out` 链表遍历其出边。

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
| 12 | 4 | node_start | DFNode 中的起始位置 |
| 16 | 4 | node_count | 节点数量 |
| 20 | 4 | tag_start | TagNode 中的起始位置 |
| 24 | 4 | tag_count | TagNode 数量 |

### 符号引用表

规约约束指向实现层符号（函数、变量、类型）的引用表：

| 偏移 | 大小 | 字段 | 说明 |
|------|------|------|------|
| 0 | 4 | name_idx | 符号名在字符串表中的索引 |
| 4 | 4 | kind | 符号类型：0=func, 1=var, 2=type, 3=field |
| 8 | 4 | scope | 作用域（函数索引或 -1 表示全局） |

---

## 三、规约操作码（新增 DFNode opcode）

原有指令节点 opcode 不变（0-29），新增规约相关 opcode：

| 编号 | 名称 | 语义 | dest | src1 | src2 | src3 |
|------|------|------|------|------|------|------|
| 30 | SPEC_CONSTRAINT | 规约约束断言 | — | 条件 DFNode 索引 | 约束类型 | 符号引用索引 |
| 31 | SPEC_FORALL | 全称量词 | 量词变量索引 | 集合 DFNode | 条件 DFNode | — |
| 32 | SPEC_EXISTS | 存在量词 | 量词变量索引 | 集合 DFNode | 条件 DFNode | — |
| 33 | SPEC_IMPLY | 逻辑蕴含 | — | 前提 DFNode | 结论 DFNode | — |
| 34 | SPEC_OLD | 旧值标记 | 结果变量 | 状态变量 DFNode | — | — |
| 35 | SPEC_ASSUME | 假设（检验用） | — | 条件 DFNode | — | — |

这些节点与普通指令节点并列在同一张图中，边同样表示数据依赖。验证工具遍历图时，普通节点和规约节点同等对待。

---

## 四、自动推导标签

编译器从图结构分析自动推导以下标签，写入 `.csr` 的 TagNode 数组（status=auto_proven）：

| 标签 | 图模式匹配规则 | 说明 |
|------|---------------|------|
| `#pure` | 函数的所有 DFNode 中：无 CALL 到非纯函数、无 STORE 到外部全局变量 | 无副作用 |
| `#deterministic` | #pure + 无依赖于外部状态（IO、env、随机源）的路径 | 确定性 |
| `#terminating` | 所有循环（DFNode 中的回边）有可识别的单调递减度量 | 终止性 |
| `#no_alloc` | 无 ALLOC / ALLOC_ARRAY / ALLOC_STRUCT 节点 | 不分配 |
| `#no_throw` | 无可达的异常路径（无分支导向 panic/error 节点） | 不抛异常 |
| `#safe_index` | 所有 LOAD_INDEX/STORE_INDEX 节点的索引输入 ≤ 数组长度变量 | 安全索引 |
| `#len_preserved` | 输入集合变量和输出集合变量之间的 DFNode 无插入/删除操作（STORE_INDEX 不超出边界，无 ALLOC 替换） | 长度守恒 |
| `#atomic` | 配对操作（如 LOAD → STORE）之间无 YIELD/AWAIT/SPAWN 节点 | 不可分割 |
| `#conservation` | 图上两条 STORE 边的修改值之和为零或常数（编译器需要识别配对模式） | 守恒律 |
| `#ordered` | 图中有比较（CMP）→ 条件分支（BRANCH）→ 交换（STORE_INDEX）的子图模式 | 有序结果 |

---

## 五、数据流图构建规则

### 辅助数组

| 数组 | 元素大小 | 用途 |
|------|----------|------|
| `g_df_var_producer[]` | 8 字节 | 每个 IR 变量，记录产生该变量的节点 ID |
| `g_df_func_node_start[]` | 8 字节 | 每个函数在 `g_df_nodes[]` 中的起始索引 |
| `g_df_func_node_count[]` | 8 字节 | 每个函数中的节点数 |
| `g_df_tag_start[]` | 8 字节 | 每个函数在 TagNode 数组中的起始位置 |
| `g_df_tag_count[]` | 8 字节 | 每个函数的 TagNode 数量 |

### 边构建规则

由 `df_connect_srcs()` 根据操作码类型自动构建：

- `IR_CONST`：所有 src 为标量值，不产生边
- `IR_BINARY`：src1 和 src2 均为变量 → 两条边
- `IR_CALL`/`IR_SPAWN`：src1 到 src1+src2-1 为连续参数变量 → 多条边
- `IR_RETURN`：src1 >= 0 时为返回值变量 → 一条边
- `IR_BRANCH`：src1 为条件变量 → 一条边（标签在 src2/src3，非变量）
- `IR_STORE`/`IR_STORE_FIELD`/`IR_STORE_INDEX`：目标 + 值 → 两条边
- `IR_LABEL`/`IR_JUMP`/`IR_PHI`/`IR_ALLOC` 等：无变量输入 → 无边
- `SPEC_CONSTRAINT`：condition_node 为条件 DFNode → 一条边
- `SPEC_FORALL`/`SPEC_EXISTS`：集合 DFNode + 条件 DFNode → 两条边
- `SPEC_IMPLY`：前提 + 结论 → 两条边

---

## 六、线性化（数据流图 → `.ccr`）

`lower_to_ccr()` 将数据流图线性化为线性 IR 指令数组供后端消费。规约约束节点（opcode ≥ 30）照常线性化，但 `corearch` 后端在代码生成时跳过它们。

---

## 七、文本 `.cir` 转储格式

自托管编译器的 `cmd_cir()` 生成人类可读的 `.cir` 文本转储，扩展为显示规约约束：

```
Function: sort
  #pure (auto_proven)
  #len_preserved (auto_proven)
  #ensure auto::sort_check (pending)
    ── Node 0: const: a = input
    ── Node 1: const: len = |a|
    ── Node 2: binary: i = 0
    ── Node 3: ...
    ══ Node 8: SPEC_CONSTRAINT: check(auto::sort_check)
```

指令文本格式由 `ir_instr_str()` 生成，现有格式不变：

| 指令 | 文本格式 |
|------|----------|
| CONST | `d = 值` |
| BINARY | `d = s1 OP s2` |
| CALL | `d = call func(args...)` |
| RETURN | `value` 或 `void` |
| SPEC_CONSTRAINT | `constraint: type(kind) = cond` |

---

## 八、操作码助记符

`df_opcode_name()` 在原有基础上新增：

```
const, binary, unary, call, return,         // 0-4
alloc, alloc_struct, alloc_array,           // 5-7
store, load, load_field, store_field,       // 8-11
load_index, store_index, load_index_var,    // 12-14
store_index_var, make_enum, ref,            // 15-17
branch, jump, label, phi, load_enum_tag,    // 18-23
slice, deref, store_ptr,                    // 24-26
spawn, yield, await,                        // 27-29
spec_constraint, spec_forall, spec_exists,  // 30-32
spec_imply, spec_old, spec_assume           // 33-35
```

---

## 九、验证管线

```
# 正常编译
corec build file.cr
  → tokenize / parse / type check / ir_gen / lower_to_ccr()
  → file.cir + file.ccr

# 编译 + 规约
corec build file.cr -s
  → tokenize / parse / type check / ir_gen
  → 构建 DFNode 数组（指令节点 + 规约约束节点）
  → 自动生成/更新 file.csp（函数骨架 + 用户规约 + 自动推导标签）
  → 解析 file.csp → 构建 TagNode 数组（约束元数据）
  → lower_to_ccr() → file.ccr（跳过约束节点）
  → save_csr() → file.csr（二进制序列化）
      包含：TagNode[] + 符号引用表 + 函数约束映射
      同时输出 file.cir（DOT 可视化 + 完整 DFNode 数据）

验证工具加载 file.csr + file.cir：
  TagNode[].status 初始为 auto_proven / pending
  尝试证明 pending 约束
  输出验证报告
```

---

## 十、代码文件索引

| 文件 | 角色 |
|------|------|
| `src/compiler/ast.cr` | DFNode/DFEdge/TagNode 结构体、IR 操作码常量、TI_* 常量 |
| `src/compiler/dataflow.cr` | 图构建、边连接、线性化、DOT 输出 |
| `src/compiler/ccr_io.cr` | `.ccr` / `.csr` 二进制读写 |
| `src/compiler/ir_gen.cr` | AST → IR 生成，含规约约束节点生成 |
| `src/compiler/dump.cr` | 文本 `.cir` 转储（含规约标注） |
| `src/compiler/interp.cr` | 数据流图解释器（跳过约束节点） |
