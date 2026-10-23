# Bare Pointer Model 完整实现设计

> 当前指针模型见 [pointer-model.md](../maintainer/design/pointer-model.md)。本文是 2026-07-28 的早期实现设计，部分阶段已经演进，保留作为历史基线。

## 概述

用裸 `TYP_PTR` 模型替换现有的 `TYP_REF`（带借用检查的引用）类型系统，并配套三个数据流分析 pass。规范见 `docs/pointer-model.md`。借用检查器由按图执行的验证取代，用户不需要写标注。

## 架构

```
源码 -> Parser -> Checker(types) -> IRGen -> DataflowGraph -> Passes -> Backend
                                            ^                    |
                                            |                    v
                                     PointerAnalysis <- RegionCheck
                                            |
                                            v
                                     ProvenanceVerify
```

三个 pass 读取 IRGen 阶段构建的数据流图，产出验证结果。不需要单独的类型层借用检查，图里已经记录了全部指针 provenance 信息。

## Phase 1：类型系统与 TYP_PTR

### 新类型种类（ast.cr）

```crystal
TYP_PTR : int = 4;  // data=pointee_type_idx, extra=address_space (0=tracked, 1=external)
```

`TYP_PTR` 替换 `TYP_REF`，成为唯一的指针表示。迁移期间保留 `TYP_REF`，但所有新代码使用 `TYP_PTR`。

### 指针类型语法（parser.cr）

`parse_type()` 增加 `T_STAR` 分支：

```crystal
else if tok_k(t) == T_STAR {
    advance_tok();
    inner := parse_type();
    res = alloc_node(EXPR_PTRTYPE, inner, 0, 0, 0, 0, 0, line, col);
}
```

新增 AST 节点：

```crystal
EXPR_PTRTYPE : int = 41;  // a=inner_type (for *T syntax)
```

### 类型检查器改动（checker.cr）

1. `UOP_REF`（`&x`）：创建 `TYP_PTR(inner_type, 0)`，不再创建 `TYP_REF`。移除借用检查调用（`check_borrow`、`record_borrow_holder`）。

2. `UOP_DEREF`（`*p`）：接受 `TYP_PTR`，解包为 pointee 类型。迁移期间也保留 `TYP_REF`。

3. 指针算术：`OP_ADD/OP_SUB` 中一个操作数是 `TYP_PTR`，另一个是 `TI_INT` 时：
   - 返回 `TYP_PTR`（pointee 类型不变）
   - IR gen 在 `s3` 中使用 `OP_PTR_ADD`/`OP_PTR_SUB`，不再使用 `OP_ADD`/`OP_SUB`
   - `p - q`（两边都是 `TYP_PTR`）使用 `OP_PTR_DIFF`，返回 `TI_INT`

4. `EXPR_AS` cast：`p as *T` 无条件允许（转换安全性由 pass 验证）。

5. `EXPR_UNSAFE`：用 `push_unsafe_scope/pop_unsafe_scope` 替换 `push_borrow_scope/pop_borrow_scope`，并标记子图边界。

6. `res_type_node`：处理 `EXPR_PTRTYPE`，创建 `TYP_PTR`。

### IR gen 改动（ir_gen.cr）

1. `UOP_REF`：emit `IR_REF`，opcode 不变，但类型现在是 `TYP_PTR`，不再是 `TYP_REF`。

2. 指针操作数的 `EXPR_BINARY`：检查器把操作数标记为 `TYP_PTR` 后，emit `IR_BINARY`，其中 `s3 = OP_PTR_ADD`/`OP_PTR_SUB`/`OP_PTR_DIFF`，不使用标准 opcode。检查器把新 opcode 写入 `ast_c(node)`。

3. `IR_DEREF` / `IR_STORE_PTR`：不变，x86 后端已经处理这两个指令。

### 文件改动汇总

| 文件 | 改动 |
|------|------|
| `ast.cr` | 新增 `TYP_PTR:4`、`EXPR_PTRTYPE:41`、`OP_PTR_ADD:14`、`OP_PTR_SUB:15`、`OP_PTR_DIFF:16` |
| `parser.cr` | `parse_type()`：`*T` 生成 `EXPR_PTRTYPE`；`parse_unary()`：`&x` 不走借用检查 |
| `checker.cr` | `UOP_REF` 使用 `TYP_PTR`；`UOP_DEREF` 处理 `TYP_PTR`；二元运算允许指针算术；`res_type_node` 处理 `EXPR_PTRTYPE`；`unsafe` 使用 push/pop unsafe scope |
| `ir_gen.cr` | 二元运算：指针操作数分派到 `OP_PTR_ADD/SUB/DIFF` |
| `dataflow.cr` | `df_connect_srcs` 为新 opcode 统计 edge |
| `dump.cr` | 输出 `OP_PTR_ADD/SUB/DIFF` 名称 |
| `interp.cr` | 在二元分派中处理 `OP_PTR_ADD/SUB/DIFF` |
| `dataflow.cr` | 为新 opcode 提供 `df_opcode_name` |

## Phase 2：IR 算术扩展

### 新 opcode 常量

```crystal
OP_PTR_ADD  : int = 14;  // p + n  (p: *T, n: int) 结果为 *T, scaled by sizeof(T)
OP_PTR_SUB  : int = 15;  // p - n  (p: *T, n: int) 结果为 *T, scaled by sizeof(T)
OP_PTR_DIFF : int = 16;  // p - q  (both *T) 结果为 int (element count)
```

### ELF 后端（instr.cr）

在 `IR_BINARY` 处理分支中增加：

```crystal
else if s3 == OP_PTR_ADD {
    // imul r11, 8 (element size, hardcoded to 8)
    cp = cp + emit_rex(buf, pos+cp, 1, 11/8, 0, 11/8);
    e2_w8(buf, pos+cp, 107); cp = cp + 1;  // 0x6B IMUL r, r/m, imm8
    cp = cp + emit_modrm(buf, pos+cp, 3, 11%8, 11%8);
    e2_w8(buf, pos+cp, 8); cp = cp + 1;    // *8
    // add r10, r11
    cp = cp + e2_alu(buf, pos+cp, 1);
}
else if s3 == OP_PTR_SUB {
    // imul r11, 8; sub r10, r11
    cp = cp + emit_rex(...); ...  // same MUL sequence
    cp = cp + e2_alu(buf, pos+cp, 41);  // SUB
}
else if s3 == OP_PTR_DIFF {
    // sub r10, r11; sar r10, 3
    cp = cp + e2_alu(buf, pos+cp, 41);  // SUB
    cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 10/8);
    e2_w8(buf, pos+cp, 193); cp = cp + 1;
    cp = cp + emit_modrm(buf, pos+cp, 3, 7, 10%8);
    e2_w8(buf, pos+cp, 3); cp = cp + 1;  // sar r10, 3
}
```

### 解释器（interp.cr）

```crystal
if op == 2 {  // IR_BINARY
    lv := r64(g_ir_vals, s1 * 8); rv := r64(g_ir_vals, s2 * 8);
    if s3 == 1  { w64(g_ir_vals, d * 8, lv + rv); }       // OP_ADD
    if s3 == 2  { w64(g_ir_vals, d * 8, lv - rv); }       // OP_SUB
    if s3 == 14 { w64(g_ir_vals, d * 8, lv + rv * 8); }   // OP_PTR_ADD
    if s3 == 15 { w64(g_ir_vals, d * 8, lv - rv * 8); }   // OP_PTR_SUB
    if s3 == 16 { w64(g_ir_vals, d * 8, (lv - rv) / 8); } // OP_PTR_DIFF
    ...
}
```

### 数据流命名

```crystal
// in dataflow.cr df_opcode_name:
if opcode == IR_BINARY {
    if s3 == OP_PTR_ADD  { return "ptr_add"; }
    if s3 == OP_PTR_SUB  { return "ptr_sub"; }
    if s3 == OP_PTR_DIFF { return "ptr_diff"; }
}
```

## Phase 3：子图基础设施

### 子图表（dyn_arr.cr 中的新数据结构）

```crystal
// Subgraph entry (48 bytes each)
ESZ_SG   : int = 48;
OFF_SG_KIND   : int = 0;   // 0=func, 1=loop, 2=for, 3=flow, 4=unsafe
OFF_SG_ENTER  : int = 8;   // enter instr seq
OFF_SG_EXIT   : int = 16;  // exit instr seq
OFF_SG_PARENT : int = 24;  // parent subgraph index
OFF_SG_NSTART : int = 32;  // first node index
OFF_SG_NCOUNT : int = 40;  // node count

SG_KINDS:
SG_FUNC   : int = 0;
SG_LOOP   : int = 1;
SG_FOR    : int = 2;
SG_FLOW   : int = 3;
SG_UNSAFE : int = 4;
```

### 子图构建函数（dataflow.cr）

```crystal
g_sg_count : int, mut;
g_sgs : string, mut;  // subgraph entries

fn sg_push(kind: int) {
    // Record current subgraph nesting
    // Called at: df_begin_func, IR_LABEL(loop/for start), EXPR_UNSAFE
}

fn sg_pop() {
    // Finalize current subgraph (set exit_seq, node_count)
}
```

### 调用位置

| 位置 | 调用 | 子图类型 |
|------|------|----------|
| `df_begin_func` | `sg_push(SG_FUNC)` | 函数体 |
| `df_end_func` | `sg_pop()` | 无 |
| `ir_gen.cr` loop header | `sg_push(SG_LOOP)` | 循环体 |
| `ir_gen.cr` loop exit | `sg_pop()` | 无 |
| `ir_gen.cr` for header | `sg_push(SG_FOR)` | 循环体 |
| `ir_gen.cr` for exit | `sg_pop()` | 无 |
| `ir_gen.cr` EXPR_UNSAFE | `sg_push(SG_UNSAFE)` | unsafe 块 |
| `ir_gen.cr` after unsafe | `sg_pop()` | 无 |

### Points-to 与 offset 存储（dyn_arr.cr）

```crystal
// Per-variable points-to bitmap (bits indexed by ALLOC node ID)
g_pts : string, mut;       // flat bitmap: bit i = var points-to alloc_i
g_pts_count : int, mut;    // number of tracked vars

// Per-variable offset from base allocation
g_offsets : string, mut;   // i64 per variable
```

### DFNode 扩展

```crystal
// New fields (total: 80 bytes from 64)
OFF_DF_PTS      : int = 64;   // points-to bitmap word (lower 64 bits, inline for hot vars)
OFF_DF_OFFSET   : int = 72;   // accumulated offset from base alloc (conservative)
ESZ_DFNODE_NEW  : int = 80;
```

## Phase 4：PointerAnalysis Pass

### 文件

`src/compiler/ptr_analysis.cr`（约 200 行）

### 接口

```crystal
fn ptr_analysis_func(nstart: int, ncount: int, vstart: int, vcount: int) {
    // Single-function pointer analysis
    // Walks DFNodes in topological order (creation order is valid)
    // For each node, updates pts/offset of destination variable
}
```

### 伪代码

```
for each node n in [nstart, nstart + ncount):
    op = node.opcode
    d  = node.dest
    if d < 0: continue

    if op == IR_ALLOC || op == IR_ALLOC_STRUCT || op == IR_ALLOC_ARRAY:
        pts[d] = {n}           // points to itself
        offset[d] = 0

    elif op == IR_REF || op == IR_ADDR_INDEX:
        pts[d] = pts[node.s1]  // propagate
        offset[d] = offset[node.s1] + known_offset(node)

    elif op == IR_BINARY && (s3 == OP_PTR_ADD || s3 == OP_PTR_SUB):
        pts[d] = pts[node.s1]
        if node.s2 is constant:
            delta = const_val(node.s2) * 8
            offset[d] = offset[node.s1] + (s3 == PTR_ADD ? delta : -delta)
        else:
            offset[d] = UNKNOWN  // variable offset，需要运行时检查

    elif op == IR_LOAD_VAR || op == IR_STORE:
        pts[d] = pts[node.s1]

    else:
        pts[d] = {}              // no pointer provenance
        offset[d] = 0
```

### 调度

```crystal
fn ptr_analysis_all() {
    fi := 0;
    loop { if fi >= g_ir_func_count { break; }
        nstart = r64(g_df_func_node_start, fi * 8);
        ncount = r64(g_df_func_node_count, fi * 8);
        vstart = r64(g_ir_func_var_start, fi * 8);
        vcount = r64(g_ir_func_var_count, fi * 8);
        ptr_analysis_func(nstart, ncount, vstart, vcount);
        fi = fi + 1;
    }
}
```

## Phase 5：RegionCheck Pass

### 文件

`src/compiler/region_check.cr`（约 150 行）

### 伪代码

```
for each DEREF node:
    ptr_var = node.s1
    allocs = pts[ptr_var]        // set of possible ALLOC targets
    
    for each alloc_id in allocs:
        alloc_node = get_node(alloc_id)
        sg_alloc = subgraph_containing(alloc_node)
        cur_seq = node_seq(deref_node)
        
        if cur_seq > sg_alloc.exit_seq:
            error("dangling pointer: alloc exits at ", sg_alloc.exit_seq,
                  " deref at ", cur_seq)
```

### 子图归属查询

```crystal
fn subgraph_containing(node_id: int) -> int {
    // Linear scan subgraph table for node_id in [nstart, nstart + ncount)
    // Returns innermost subgraph index
}
```

## Phase 6：ProvenanceVerify Pass

### 文件

`src/compiler/provenance_verify.cr`（约 200 行）

### 伪代码

```
for each DEREF node:
    ptr_var = node.s1
    allocs = pts[ptr_var]
    off = offset[ptr_var]
    
    for each alloc_id in allocs:
        alloc_node = get_node(alloc_id)
        alloc_size = get_alloc_size(alloc_node)
        
        if alloc_size == UNKNOWN_SIZE:
            emit_bounds_check(node, off, alloc_size)
        else:
            if off < 0 || off >= alloc_size:
                error("out of bounds: offset ", off, " >= size ", alloc_size)
```

### 运行时边界检查生成

`alloc_size` 由运行时决定时（变长数组），在 DEREF 之前 emit `IR_BOUNDS_CHECK`：

```crystal
fn emit_bounds_check(deref_instr: int, offset_var: int, size_var: int) {
    // Insert IR_BOUNDS_CHECK(deref_instr - 1) before the DEREF
}
```

`IR_BOUNDS_CHECK` 的 ELF 后端目前是空操作，需要实现：

```crystal
if op == IR_BOUNDS_CHECK && s2 >= 0 {
    // cmp s1, s2
    // jae .panic
    // .panic: ud2
}
```

## 从 Borrow Checker 迁移到 Passes

借用检查器（`checker.cr` 第 258-343 行、第 1186-1210 行）分阶段替换：

1. Phase 1：`UOP_REF` 停止调用 `check_borrow()`。同一个变量被多次引用时不再报错。
2. Phases 4-6：三个 pass 在 IRGen 之后运行，任何可以证明的不安全访问在这里被发现。
3. 借用作用域函数（`push_borrow_scope/pop_borrow_scope`）在 Phase 1 由 `push_unsafe_scope/pop_unsafe_scope` 替换，因为借用追踪不再需要它们。

错误码 `EC_B_BORROW_*` 不删除。它们已标记为废弃，可能在迁移警告中触发。

## 阶段顺序与依赖

```
Phase 1 (Types)               无前置
Phase 2 (IR Arith)            依赖 P1
Phase 3 (Subgraph)            独立于 P1/P2
Phase 4 (PtrAnalysis)         依赖 P1 + P2 + P3
Phase 5 (RegionCheck)         依赖 P3 + P4
Phase 6 (ProvenanceVerify)    依赖 P4
```

Phase 1 和 Phase 3 可以并行开发。Phase 2 依赖 Phase 1。Phases 4-6 依赖前面所有阶段。
