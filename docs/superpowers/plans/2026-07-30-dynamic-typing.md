# 动态类型实现计划

> 受众：执行本计划的 agentic worker。必需子技能：`superpowers:subagent-driven-development`（推荐）或 `superpowers:executing-plans`，按任务逐项实施。进度以复选框（`- [ ]`）跟踪。

目标：为 Core 增加 `dyn` 动态类型。声明为 `dyn` 的变量在不同控制流路径上可以持有不同类型，编译器跟踪全部可能类型，并在汇合点生成带标签的联合体。

架构：类型系统使用 `TI_DYN(7)` 与 `TYP_DYN(11)`。运行期表示使用 `IR_DYN_TAG(41)`、`IR_DYN_VAL(42)`、`IR_DYN_PACK(43)`、`IR_DYN_DISPATCH(44)`。类型检查器沿控制流跟踪每个变量的类型集合。

技术栈：Core 自举编译器的 parser、checker、IR gen、ELF 后端

## 全局约束

- `TI_DYN = 7`、`TYP_DYN = 11`、token `T_DYN = 48`
- `IR_DYN_TAG = 41`、`IR_DYN_VAL = 42`、`IR_DYN_PACK = 43`、`IR_DYN_DISPATCH = 44`
- `ESZ_IRV = 24`（既有值），dyn 变量用 `irv_extra` 字段表示宽度
- 单路径 dyn 使用底层类型（8 字节）；多路径 dyn 使用 16 字节（tag + value）
- 版本控制使用 `jj`

---

### 任务 1：token 与类型常量

涉及文件：
- 修改：`src/compiler/ast.cr`
- 修改：`src/compiler/keywords.cr`

- [ ] 步骤 1：在 ast.cr 中添加类型常量

在 `TI_CHAR : int = 6;` 之后添加：
```core
TI_DYN : int = 7    // dynamic type
```

在 `TYP_TUPLE : int = 10;` 之后添加：
```core
TYP_DYN : int = 11  // data = type set bitmap (0 = single known type)
```

在 `IR_SECTION : int = 38;` 之后添加：
```core
IR_DYN_TAG      : int = 41  // dest=tag_var, s1=dyn_var — extract tag
IR_DYN_VAL      : int = 42  // dest=val_var, s1=dyn_var — extract value
IR_DYN_PACK     : int = 43  // dest=dyn_var, s1=val_var, s2=type_idx — pack dyn
IR_DYN_DISPATCH : int = 44  // s1=dyn_var, s2=dispatch_table_ni — dispatch by tag
```

- [ ] 步骤 2：在 keywords.cr 中添加 token

```core
T_DYN : int = 48
```

- [ ] 步骤 3：提交

```bash
jj commit -m "feat: add TI_DYN/TYP_DYN/IR_DYN_* type and IR constants"
```

---

### 任务 2：Parser 处理 dyn 关键字与变量声明

涉及文件：
- 修改：`src/compiler/parser.cr`

- [ ] 步骤 1：在 parse_type 中添加 `dyn`

找到 `parse_type()` 或 `parse_primary()` 中匹配 `int`、`float`、`bool`、`string`、`char` 的位置，添加 `dyn`：

```core
else if lex == "dyn" {
    res = alloc_node(0, 0, 0, 0, 0, TI_DYN, 0, line, col);
}
```

- [ ] 步骤 2：在变量声明中处理 `dyn` 类型

在 `parse_decl()`（或解析 `:` 类型标注的位置），类型为 `TI_DYN` 时将其存为变量类型。既有的 `:` 语法已经会记录类型，`TI_DYN` 可以直接沿用这条路径。

- [ ] 步骤 3：提交

```bash
jj commit src/compiler/parser.cr -m "feat: parse dyn keyword"
```

---

### 任务 3：类型检查器跟踪类型集合

涉及文件：
- 修改：`src/compiler/checker.cr`

- [ ] 步骤 1：添加类型集合跟踪基础设施

```core
// Per-variable type set: bitmap of possible types for dyn variables
g_dyn_type_sets : string, mut  // dyn type info per variable
g_dyn_type_set_count : int, mut
g_dyn_type_set_cap : int, mut

fn grow_dyn_type_sets(needed: int):
    if needed < g_dyn_type_set_cap:
        return
    nc := g_dyn_type_set_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * 8)
    _dyncpy(g_dyn_type_sets, g_dyn_type_set_cap * 8, nb)
    g_dyn_type_sets = nb
    g_dyn_type_set_cap = nc

// Set a bit in the type set for a variable
fn dyn_set_type(var_idx: int, ti: int):
    grow_dyn_type_sets(var_idx + 1)
    old := r64(g_dyn_type_sets, var_idx * 8)
    bit := 1
    if ti >= 0 && ti < 64:
        bit = 1
        shl := ti
        loop:
            if shl <= 0:
                break
            bit = bit * 2
            shl = shl - 1
    w64(g_dyn_type_sets, var_idx * 8, old + bit)

// Check if a type is in the set
fn dyn_has_type(var_idx: int, ti: int) -> int:
    if var_idx < 0 || var_idx >= g_dyn_type_set_count:
        return 0
    set := r64(g_dyn_type_sets, var_idx * 8)
    bit := 1
    if ti >= 0 && ti < 64:
        bit = 1
        shl := ti
        loop:
            if shl <= 0:
                break
            bit = bit * 2
            shl = shl - 1
    if (set / bit) % 2 != 0:
        return 1
    return 0
```

- [ ] 步骤 2：在赋值处记录类型

在类型检查器的赋值处理中，目标变量为 `TI_DYN` 时记录右侧表达式的类型：

```core
if target_type == TI_DYN {
    dyn_set_type(var_idx, rhs_type);
}
```

- [ ] 步骤 3：在控制流汇合点合并类型集合

在 if/else 处理中，两个分支都处理完后合并 dyn 类型集合：

```core
fn merge_dyn_types(target_var: int, then_set: int, else_set: int):
    // Union the type sets
    w64(g_dyn_type_sets, target_var * 8, then_set + else_set)
```

- [ ] 步骤 4：校验 dyn 值上的方法调用

在 `dyn` 值上调用方法时，检查集合中的所有类型都支持该方法。有任一类型不支持则报错。

- [ ] 步骤 5：提交

```bash
jj commit src/compiler/checker.cr -m "feat: checker dyn type set tracking + control flow merge"
```

---

### 任务 4：注册 IR opcode

涉及文件：
- 修改：`src/compiler/dataflow.cr`
- 修改：`src/compiler/opt.cr`
- 修改：`src/compiler/ccr_io.cr`
- 修改：`src/compiler/dyn_arr.cr`（如有需要，添加 ESZ_IRV_NEW）

- [ ] 步骤 1：在 df_opcode_name 中登记

```core
if opcode == IR_DYN_TAG { return "dyn_tag"; }
if opcode == IR_DYN_VAL { return "dyn_val"; }
if opcode == IR_DYN_PACK { return "dyn_pack"; }
if opcode == IR_DYN_DISPATCH { return "dyn_dispatch"; }
```

- [ ] 步骤 2：在 df_connect_srcs 中登记

```core
if opcode == IR_DYN_TAG { df_use_var(nid, s1); return; }
if opcode == IR_DYN_VAL { df_use_var(nid, s1); return; }
if opcode == IR_DYN_PACK { df_use_var(nid, s1); return; }
if opcode == IR_DYN_DISPATCH { df_use_var(nid, s1); return; }
```

- [ ] 步骤 3：在 opt.cr 中跳过

```core
if op == IR_DYN_TAG { ii = ii + 1; continue; }
if op == IR_DYN_VAL { ii = ii + 1; continue; }
if op == IR_DYN_PACK { ii = ii + 1; continue; }
if op == IR_DYN_DISPATCH { ii = ii + 1; continue; }
```

- [ ] 步骤 4：加入 ccr_io.cr 的 save/load

每个新 opcode 按标准的 6 字段模式处理。

- [ ] 步骤 5：提交

```bash
jj commit -m "feat: register IR_DYN_TAG/VAL/PACK/DISPATCH in dataflow/passes/ccr"
```

---

### 任务 5：IR Gen 的 dyn 打包与分发

涉及文件：
- 修改：`src/compiler/ir_gen.cr`

- [ ] 步骤 1：处理 dyn 变量声明

声明并赋值 `dyn` 变量时，判断它是单路径（类型已知）还是多路径：

```core
if var_type == TI_DYN {
    // Check the RHS type
    rhs_type := get_type(rhs_node);
    // If rhs_type is known and unique, emit bare value (no tag)
    // Single-path dyn: just emit as-is

    // If rhs_type varies by path, emit IR_DYN_PACK
    // Multi-path dyn: pack with tag
    tag := rhs_type;
    emit(IR_DYN_PACK, dyn_var, val_var, tag, 0, 0);
}
```

- [ ] 步骤 2：处理 dyn 值上的运算

遇到 `dyn + int` 这类二元运算时：
1. dyn 是单路径且类型已知时，走普通代码路径
2. dyn 是多路径时，发射 DISPATCH，为每个跟踪到的类型提供一个分支
3. 需要动态转换时（int + string），发射转换代码

- [ ] 步骤 3：处理 dyn 值上的方法调用

调用 `dyn.method()` 时：
```core
if receiver_is_dyn(receiver_type) {
    // Collect all possible methods (one per type in set)
    // Emit IR_DYN_DISPATCH with the dispatch table
    emit(IR_DYN_DISPATCH, -1, dyn_var, dispatch_table_ni, 0, 0);
}
```

- [ ] 步骤 4：提交

```bash
jj commit src/compiler/ir_gen.cr -m "feat: IR gen dyn pack/dispatch + auto conversion"
```

---

### 任务 6：ELF 后端的 dyn opcode

涉及文件：
- 修改：`src/arch/linux/ld/instr.cr`
- 修改：`src/arch/linux/ld/sizes.cr`

- [ ] 步骤 1：在 instr.cr 中添加编码

```core
if op == IR_DYN_PACK {
    // Write tag (type index) and value to 16-byte dyn slot
    // Load value var into r10, get type index from s2
    do2 := g2_slot(d);     // dyn_var slot (16 bytes)
    s1do := g2_slot(s1);    // value var slot
    // mov r10, [rbp + s1do] — load value
    cp = cp + e2_load_var(buf, pos+cp, 10, s1);
    // mov [rbp + do2], r10 — store value to dyn low 8 bytes
    cp = cp + e2_st(buf, pos+cp, 10, do2);
    // Store tag (s2 = type index) to dyn high 8 bytes
    // mov qword [rbp + do2 + 8], s2
    cp = cp + emit_rex(...) + modrm(...) + disp8(...);  // immediate store
    return cp;
}

if op == IR_DYN_TAG {
    do2 := g2_slot(d);
    s1do := g2_slot(s1);
    // mov r10, [rbp + s1do + 8] — load tag from high 8 bytes
    // REX.WB + 0x8B + ModRM(disp8) + disp8
    cp = cp + e2_load_var_off(buf, pos+cp, 10, s1, 8);  // load with +8 offset
    cp = cp + e2_st(buf, pos+cp, 10, do2);
    return cp;
}

if op == IR_DYN_VAL {
    do2 := g2_slot(d);
    s1do := g2_slot(s1);
    // mov r10, [rbp + s1do] — load value from low 8 bytes
    cp = cp + e2_load_var(buf, pos+cp, 10, s1);
    cp = cp + e2_st(buf, pos+cp, 10, do2);
    return cp;
}

if op == IR_DYN_DISPATCH {
    // Load tag from dyn_var
    s1do := g2_slot(s1);
    cp = cp + e2_load_var_off(buf, pos+cp, 10, s1, 8);  // load tag
    // Compare and jump table
    // (Simplified for initial implementation: compare against each known type)
    // s2 = dispatch_table_ni (contains type to function mapping)
    // For now: fallback to normal call
    return 0;  // placeholder — full dispatch table in next pass
}
```

- [ ] 步骤 2：在 sizes.cr 中添加尺寸估算

```core
if op == IR_DYN_PACK { return 16; }  // load + 2 stores
if op == IR_DYN_TAG { return 8; }    // load off + store
if op == IR_DYN_VAL { return 8; }    // load + store
if op == IR_DYN_DISPATCH { return 20; } // tag load + cmp/je chain
```

- [ ] 步骤 3：提交

```bash
jj commit -m "feat: ELF backend dyn opcode encoding"
```

---

### 任务 7：测试

涉及文件：
- 创建：`tests/suite/dyn_test.cr`

- [ ] 步骤 1：编写 dyn 测试

```core
import io

fn test_dyn_basic() -> int:
    x : dyn = 42
    // Single-path dyn should work like normal value
    if x != 42:
        return 1
    return 0

fn test_dyn_reassign() -> int:
    x : dyn = 42
    x = "hello"
    // After reassignment, x should be string
    if str_len(x) < 1:
        return 1
    return 0

fn test_dyn_multi_path() -> int:
    cond : int = 1
    x : dyn = 0
    if cond != 0:
        x = 42
    else:
        x = "hello"
    // x could be int or string
    // Just verify it compiles and runs
    return 0

fn main() -> int:
    r1 := test_dyn_basic()
    if r1 != 0:
        print("FAIL basic: ")
        println(int_str(r1))
        return r1
    r2 := test_dyn_reassign()
    if r2 != 0:
        print("FAIL reassign: ")
        println(int_str(r2))
        return r2
    r3 := test_dyn_multi_path()
    if r3 != 0:
        print("FAIL multipath: ")
        println(int_str(r3))
        return r3
    println("ALL PASS")
    return 0
```

- [ ] 步骤 2：验证

```bash
./build/corec check tests/suite/dyn_test.cr
```

预期：ok

- [ ] 步骤 3：提交

```bash
jj commit tests/suite/dyn_test.cr -m "test: dyn type basic + multi-path"
```
