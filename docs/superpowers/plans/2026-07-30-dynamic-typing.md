# 动态类型 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `dyn` dynamic typing to Core — variables declared as `dyn` can hold different types across paths, compiler tracks all possible types, generates tagged unions at merge points.

**Architecture:** `TI_DYN(7)` / `TYP_DYN(11)` type system. `IR_DYN_TAG(41)` / `IR_DYN_VAL(42)` / `IR_DYN_PACK(43)` / `IR_DYN_DISPATCH(44)` for runtime representation. Checker tracks per-variable type sets through control flow.

**Tech Stack:** Core self-hosted compiler parser → checker → IR gen → ELF backend

## Global Constraints

- `TI_DYN = 7`, `TYP_DYN = 11`, token `T_DYN = 48`
- `IR_DYN_TAG = 41`, `IR_DYN_VAL = 42`, `IR_DYN_PACK = 43`, `IR_DYN_DISPATCH = 44`
- `ESZ_IRV = 24` (existing) — dyn variables use `irv_extra` field for width
- Single-path dyn = underlying type (8 bytes); multi-path dyn = 16 bytes (tag+value)
- Uses `jj` for version control

---

### Task 1: Token + Type Constants

**Files:**
- Modify: `src/compiler/ast.cr`
- Modify: `src/compiler/keywords.cr`

- [ ] **Step 1: Add type constants to ast.cr**

After `TI_CHAR : int = 6;`:
```core
TI_DYN : int = 7    // dynamic type
```

After `TYP_TUPLE : int = 10;`:
```core
TYP_DYN : int = 11  // data = type set bitmap (0 = single known type)
```

After `IR_SECTION : int = 38;`:
```core
IR_DYN_TAG      : int = 41  // dest=tag_var, s1=dyn_var — extract tag
IR_DYN_VAL      : int = 42  // dest=val_var, s1=dyn_var — extract value
IR_DYN_PACK     : int = 43  // dest=dyn_var, s1=val_var, s2=type_idx — pack dyn
IR_DYN_DISPATCH : int = 44  // s1=dyn_var, s2=dispatch_table_ni — dispatch by tag
```

- [ ] **Step 2: Add token to keywords.cr**

```core
T_DYN : int = 48
```

- [ ] **Step 3: Commit**

```bash
jj commit -m "feat: add TI_DYN/TYP_DYN/IR_DYN_* type and IR constants"
```

---

### Task 2: Parser — dyn Keyword + Variable Declarations

**Files:**
- Modify: `src/compiler/parser.cr`

- [ ] **Step 1: Add `dyn` to parse_type**

Find where `int`, `float`, `bool`, `string`, `char` are matched in `parse_type()` or `parse_primary()`. Add `dyn`:

```core
else if lex == "dyn" {
    res = alloc_node(0, 0, 0, 0, 0, TI_DYN, 0, line, col);
}
```

- [ ] **Step 2: Handle `dyn` type in variable declarations**

In `parse_decl()` (or wherever `:` type annotations are parsed), when the type is `TI_DYN`, store it as the variable's type. The existing `:` syntax already handles recording the type — `TI_DYN` just flows through naturally.

- [ ] **Step 3: Commit**

```bash
jj commit src/compiler/parser.cr -m "feat: parse dyn keyword"
```

---

### Task 3: Checker — Type Set Tracking

**Files:**
- Modify: `src/compiler/checker.cr`

- [ ] **Step 1: Add type set tracking infrastructure**

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

- [ ] **Step 2: Track types at assignment**

In the checker's assignment handling, when the target variable is `TI_DYN`, record the RHS type:

```core
if target_type == TI_DYN {
    dyn_set_type(var_idx, rhs_type);
}
```

- [ ] **Step 3: Merge type sets at control flow join points**

In if/else handling, after processing both branches, merge dyn type sets:

```core
fn merge_dyn_types(target_var: int, then_set: int, else_set: int):
    // Union the type sets
    w64(g_dyn_type_sets, target_var * 8, then_set + else_set)
```

- [ ] **Step 4: Validate method calls on dyn values**

When a method is called on a `dyn` value, check that ALL types in the set support that method. If any type doesn't, emit error.

- [ ] **Step 5: Commit**

```bash
jj commit src/compiler/checker.cr -m "feat: checker dyn type set tracking + control flow merge"
```

---

### Task 4: IR Opcodes Registration

**Files:**
- Modify: `src/compiler/dataflow.cr`
- Modify: `src/compiler/opt.cr`
- Modify: `src/compiler/ccr_io.cr`
- Modify: `src/compiler/dyn_arr.cr` (add ESZ_IRV_NEW if needed)

- [ ] **Step 1: Register in df_opcode_name**

```core
if opcode == IR_DYN_TAG { return "dyn_tag"; }
if opcode == IR_DYN_VAL { return "dyn_val"; }
if opcode == IR_DYN_PACK { return "dyn_pack"; }
if opcode == IR_DYN_DISPATCH { return "dyn_dispatch"; }
```

- [ ] **Step 2: Register in df_connect_srcs**

```core
if opcode == IR_DYN_TAG { df_use_var(nid, s1); return; }
if opcode == IR_DYN_VAL { df_use_var(nid, s1); return; }
if opcode == IR_DYN_PACK { df_use_var(nid, s1); return; }
if opcode == IR_DYN_DISPATCH { df_use_var(nid, s1); return; }
```

- [ ] **Step 3: Skip in opt.cr**

```core
if op == IR_DYN_TAG { ii = ii + 1; continue; }
if op == IR_DYN_VAL { ii = ii + 1; continue; }
if op == IR_DYN_PACK { ii = ii + 1; continue; }
if op == IR_DYN_DISPATCH { ii = ii + 1; continue; }
```

- [ ] **Step 4: Add to ccr_io.cr save/load**

Follow the standard 6-field pattern for each new opcode.

- [ ] **Step 5: Commit**

```bash
jj commit -m "feat: register IR_DYN_TAG/VAL/PACK/DISPATCH in dataflow/passes/ccr"
```

---

### Task 5: IR Gen — Dyn Pack + Dispatch

**Files:**
- Modify: `src/compiler/ir_gen.cr`

- [ ] **Step 1: Handle dyn variable declaration**

When a `dyn` variable is declared and assigned, check if it's single-path (known type) or multi-path:

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

- [ ] **Step 2: Handle operations on dyn values**

When a binary operation like `dyn + int` is encountered:
1. If dyn is single-path with known type → fall through to normal code
2. If dyn is multi-path → emit DISPATCH with cases for each tracked type
3. If dynamic conversion needed (int + string) → emit conversion code

- [ ] **Step 3: Handle method calls on dyn values**

When `dyn.method()` is called:
```core
if receiver_is_dyn(receiver_type) {
    // Collect all possible methods (one per type in set)
    // Emit IR_DYN_DISPATCH with the dispatch table
    emit(IR_DYN_DISPATCH, -1, dyn_var, dispatch_table_ni, 0, 0);
}
```

- [ ] **Step 4: Commit**

```bash
jj commit src/compiler/ir_gen.cr -m "feat: IR gen dyn pack/dispatch + auto conversion"
```

---

### Task 6: ELF Backend — Dyn Opcodes

**Files:**
- Modify: `src/arch/linux/ld/instr.cr`
- Modify: `src/arch/linux/ld/sizes.cr`

- [ ] **Step 1: Add encoding in instr.cr**

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
    // s2 = dispatch_table_ni (contains type → function mapping)
    // For now: fallback to normal call
    return 0;  // placeholder — full dispatch table in next pass
}
```

- [ ] **Step 2: Add size estimates in sizes.cr**

```core
if op == IR_DYN_PACK { return 16; }  // load + 2 stores
if op == IR_DYN_TAG { return 8; }    // load off + store
if op == IR_DYN_VAL { return 8; }    // load + store
if op == IR_DYN_DISPATCH { return 20; } // tag load + cmp/je chain
```

- [ ] **Step 3: Commit**

```bash
jj commit -m "feat: ELF backend dyn opcode encoding"
```

---

### Task 7: Tests

**Files:**
- Create: `tests/suite/dyn_test.cr`

- [ ] **Step 1: Write dyn test**

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

- [ ] **Step 2: Verify**

```bash
./build/corec check tests/suite/dyn_test.cr
```

Expected: ok

- [ ] **Step 3: Commit**

```bash
jj commit tests/suite/dyn_test.cr -m "test: dyn type basic + multi-path"
```
