# Arena 内存模型实现计划

> **受众**：执行本计划的 agentic worker。**必需子技能**：`superpowers:subagent-driven-development`（推荐）或 `superpowers:executing-plans`，按任务逐项实施。进度以复选框（`- [ ]`）跟踪。

**目标**：将单一全局 bump 分配器替换为多 arena 系统——每个子图（function/loop/for/unsafe）持有独立 arena，分配自动使用当前 arena，子图退出时重置 arena 游标。

**架构**：三层结构——（1）Core 侧的 stdlib arena 生命周期（`arena.cr`）；（2）编译器在子图边界发射 `IR_ARENA_NEW`/`IR_ARENA_RESET`，并做编译期尺寸估算；（3）ELF 后端 `emit_alloc_body` 检查 `g_current_arena`，已设置时从 arena chunk 分配，未设置时回退到全局 bump。

**技术栈**：Core 语言（自举编译器）、x86-64 ELF 后端、GNU as（rt.s）

## 全局约束

- 无固定 `MAX_ARENAS` 上限——元数据数组为动态数组（与 `g_df_nodes` 同机制）
- `alloc()` API 不变——arena 感知对调用方透明
- `g_current_arena = -1` 保留既有全局 bump 行为
- 生命周期管理全部位于 Core 代码（`arena.cr`）；汇编仅承担 bump 路径
- 新增 IR opcode：`IR_ARENA_NEW = 32`、`IR_ARENA_RESET = 33`
- `ESZ_IRINSTR = 48` 字节（6 字段 × 8 字节）。`iri_set_s1(idx, val)` 用于回填指令字段。
- 链式扩展：arena OOM 时从全局堆分配溢出块

---

### 任务 1：BSS 扩展（rt.s）

**涉及文件：**
- 修改：`src/runtime/rt.s`

**接口：**
- 产出：`g_current_arena`（BSS，8 字节）、`g_arena_pool_data`（BSS，8 字节）、`g_arena_free_list`（BSS，8 字节）

- [ ] **步骤 1：新增 arena BSS 变量**

在 `src/runtime/rt.s` 中定位 `.bss` 段，在 `.balign 4096` 之后、`heap_ptr` 之前新增：

```asm
.section .bss
.balign 4096
g_current_arena: .space 8       ; -1 = no arena, use global heap_ptr
g_arena_pool_data: .space 8     ; pool base pointer (filled by arena_init)
g_arena_free_list: .space 8     ; -1 = empty
heap_ptr: .space 8              ; existing, fallback
heap_start: .space 1024 * 1024 * 1024
heap_end:
```

- [ ] **步骤 2：在 _start 中初始化新增全局变量**

在 `_start` 中既有 `heap_ptr` 初始化（`lea rax, [rip + heap_start]; lea r10, [rip + heap_ptr]; mov [r10], rax`）之后新增：

```asm
    # Initialize g_current_arena = -1 (no arena active)
    mov r10, -1
    lea rax, [rip + g_current_arena]
    mov [rax], r10

    # Initialize g_arena_pool_data = heap_start (default, overwritten by arena_init)
    lea rax, [rip + heap_start]
    lea r10, [rip + g_arena_pool_data]
    mov [r10], rax
```

- [ ] **步骤 3：校验汇编**

命令：`as -o /tmp/rt.o src/runtime/rt.s`
预期：无错误。

- [ ] **步骤 4：提交**

```bash
git add src/runtime/rt.s
git commit -m "feat: add arena BSS globals (g_current_arena, g_arena_pool_data, g_arena_free_list)"
```

---

### 任务 2：新增 IR Opcode（ast.cr、dataflow.cr、opt.cr）

**涉及文件：**
- 修改：`src/compiler/ast.cr`
- 修改：`src/compiler/dataflow.cr`
- 修改：`src/compiler/opt.cr`

**接口：**
- 产出：`IR_ARENA_NEW = 32`、`IR_ARENA_RESET = 33`

- [ ] **步骤 1：向 ast.cr 添加 opcode 常量**

定位 IR opcode 段（约第 526-530 行），在 `IR_YIELD` 之后新增：

```core
IR_ARENA_NEW   : int = 32   // dest=arena_var, src1=size_estimate
IR_ARENA_RESET : int = 33   // src1=arena_id (dest=-1)
```

- [ ] **步骤 2：在 dataflow.cr 的 df_opcode_name 中登记**

定位 `fn df_opcode_name`，在 `IR_YIELD` 条目之后（约第 349 行）新增：

```core
    if opcode == IR_ARENA_NEW { return "arena_new"; }
    if opcode == IR_ARENA_RESET { return "arena_reset"; }
```

- [ ] **步骤 3：在 dataflow.cr 的 df_connect_srcs 中登记**

定位 `fn df_connect_srcs`（搜索其定义）。在函数结尾之前追加：

```core
    if opcode == IR_ARENA_NEW { df_use_var(nid, s1); return; }
    if opcode == IR_ARENA_RESET { df_use_var(nid, s1); return; }
```

- [ ] **步骤 4：在 opt.cr 优化循环中跳过**

定位 `opt.cr` 的主优化循环（搜索 `if op == IR_` 分支）。新增：

```core
    if op == IR_ARENA_NEW { continue; }
    if op == IR_ARENA_RESET { continue; }
```

同时检查 `resolve.cr` 中是否存在 opcode 分支；若存在则补充跳过分支。

- [ ] **步骤 5：提交**

```bash
git add src/compiler/ast.cr src/compiler/dataflow.cr src/compiler/opt.cr
git commit -m "feat: add IR_ARENA_NEW(32) and IR_ARENA_RESET(33) opcodes"
```

---

### 任务 3：CCR 序列化（ccr_io.cr）

**涉及文件：**
- 修改：`src/compiler/ccr_io.cr`

- [ ] **步骤 1：添加 save_ccr 分支**

定位 `fn save_ccr` 中的指令写入循环（opcode 分发处），在 YIELD 分支之后新增：

```core
    if op == IR_ARENA_NEW {
        w64(buf, ip, IR_ARENA_NEW); ip = ip + 8;
        w64(buf, ip, d); ip = ip + 8;         // dest = arena_var
        w64(buf, ip, s1); ip = ip + 8;         // src1 = size estimate
        w64(buf, ip, s2); ip = ip + 8;
        w64(buf, ip, s3); ip = ip + 8;
        w64(buf, ip, tk); ip = ip + 8;         // type_kind (unused, 0)
        ii = ii + 1;
        continue;
    }
    if op == IR_ARENA_RESET {
        w64(buf, ip, IR_ARENA_RESET); ip = ip + 8;
        w64(buf, ip, d); ip = ip + 8;         // dest = -1 (unused)
        w64(buf, ip, s1); ip = ip + 8;         // src1 = arena_id
        w64(buf, ip, s2); ip = ip + 8;
        w64(buf, ip, s3); ip = ip + 8;
        w64(buf, ip, tk); ip = ip + 8;
        ii = ii + 1;
        continue;
    }
```

- [ ] **步骤 2：添加 load_ccr 分支**

定位 `fn load_ccr` 中的指令读取循环，在 YIELD 分支之后新增：

```core
    if op == IR_ARENA_NEW {
        d := r64(buf, ip); ip = ip + 8;
        s1 := r64(buf, ip); ip = ip + 8;
        s2 := r64(buf, ip); ip = ip + 8;
        s3 := r64(buf, ip); ip = ip + 8;
        tk := r64(buf, ip); ip = ip + 8;
        emit(IR_ARENA_NEW, d, s1, s2, s3, tk);
        ii = ii + 1;
        continue;
    }
    if op == IR_ARENA_RESET {
        d := r64(buf, ip); ip = ip + 8;
        s1 := r64(buf, ip); ip = ip + 8;
        s2 := r64(buf, ip); ip = ip + 8;
        s3 := r64(buf, ip); ip = ip + 8;
        tk := r64(buf, ip); ip = ip + 8;
        emit(IR_ARENA_RESET, d, s1, s2, s3, tk);
        ii = ii + 1;
        continue;
    }
```

- [ ] **步骤 3：提交**

```bash
git add src/compiler/ccr_io.cr
git commit -m "feat: save/load IR_ARENA_NEW and IR_ARENA_RESET in ccr_io"
```

---

### 任务 4：Stdlib——arena.cr

**涉及文件：**
- 重写：`src/stdlib/arena.cr`

**接口：**
- 全局变量：`g_current_arena`、`g_arena_cursors`、`g_arena_sizes`、`g_arena_parents`、`g_arena_pool_data`、`g_arena_max_size`、`g_arena_free_list`、`g_arena_count`、`g_arena_cap`
- 函数：`arena_init(pool_size, arena_size)`、`arena_new() -> int`、`arena_reset(ai)`、`arena_avail(ai) -> int`

- [ ] **步骤 1：编写 arena.cr**

```core
// Arena memory model — per-subgraph bump allocator.
// Each subgraph (function/loop/for/unsafe) gets its own Arena.
// alloc() checks g_current_arena and uses the arena chunk when set.

// ── Globals (accessed by emit_alloc_body ELF code) ──
g_current_arena : int, mut = -1

// Arena metadata — dynamic arrays (no fixed limit, grows like g_df_nodes)
g_arena_cursors : string, mut     // int[] — bump cursor offset per arena
g_arena_sizes   : string, mut     // int[] — chunk capacity per arena
g_arena_parents : string, mut     // int[] — parent arena ID (for nesting restore)

g_arena_pool_data : string, mut   // pool base address (from alloc)
g_arena_max_size : int, mut       // default chunk size per arena
g_arena_free_list : int, mut = -1 // free list head (-1 = empty)
g_arena_count : int, mut = 0      // total slots allocated
g_arena_cap : int, mut = 0        // metadata array capacity

// ── Internal: grow metadata arrays ──
fn _grow_arena_meta(needed: int):
    if needed < g_arena_cap:
        return
    nc : ., mut = g_arena_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    // cursors
    nb := alloc(nc * 8)
    zi : ., mut = 0
    loop:
        if zi >= nc * 8:
            break
        store8(nb, zi, 0)
        zi = zi + 1
    if g_arena_cap > 0:
        _dyncpy(g_arena_cursors, g_arena_cap * 8, nb)
    g_arena_cursors = nb
    // sizes
    nb2 := alloc(nc * 8)
    zi = 0
    loop:
        if zi >= nc * 8:
            break
        store8(nb2, zi, 0)
        zi = zi + 1
    if g_arena_cap > 0:
        _dyncpy(g_arena_sizes, g_arena_cap * 8, nb2)
    g_arena_sizes = nb2
    // parents
    nb3 := alloc(nc * 8)
    zi = 0
    loop:
        if zi >= nc * 8:
            break
        store8(nb3, zi, 0)
        zi = zi + 1
    if g_arena_cap > 0:
        _dyncpy(g_arena_parents, g_arena_cap * 8, nb3)
    g_arena_parents = nb3
    g_arena_cap = nc

// ── Public API ──

fn arena_init(pool_size: int, arena_size: int):
    g_arena_pool_data = alloc(pool_size)
    g_arena_max_size = arena_size
    g_arena_free_list = -1
    g_arena_count = 0
    g_arena_cap = 0
    g_current_arena = -1

fn arena_new() -> int:
    ai : ., mut = -1

    // Try free list first
    if g_arena_free_list >= 0:
        ai = g_arena_free_list
        g_arena_free_list = r64(g_arena_parents, ai * 8)  // pop head

    if ai < 0:
        // Allocate new slot (grow metadata arrays)
        need := g_arena_count + 1
        _grow_arena_meta(need)
        ai = g_arena_count
        g_arena_count = need

    // Initialize slot
    w64(g_arena_cursors, ai * 8, 0)
    w64(g_arena_sizes, ai * 8, g_arena_max_size)
    w64(g_arena_parents, ai * 8, -1)

    // Set parent = previous current arena
    if g_current_arena >= 0:
        w64(g_arena_parents, ai * 8, g_current_arena)

    // Activate
    g_current_arena = ai
    return ai

fn arena_reset(ai: int):
    if ai < 0 || ai >= g_arena_count:
        return

    // Save parent BEFORE free list overwrites g_arena_parents[ai]
    parent := r64(g_arena_parents, ai * 8)

    // Push to free list
    w64(g_arena_parents, ai * 8, g_arena_free_list)
    g_arena_free_list = ai

    // Restore parent
    if parent >= 0:
        g_current_arena = parent
    else:
        g_current_arena = -1

fn arena_avail(ai: int) -> int:
    if ai < 0 || ai >= g_arena_count:
        return 0
    cursor := r64(g_arena_cursors, ai * 8)
    limit := r64(g_arena_sizes, ai * 8)
    return limit - cursor
```

- [ ] **步骤 2：类型检查**

命令：`./build/corec check src/stdlib/arena.cr`
预期：无编译错误。（若报全局变量相关错误，确认 `arena.cr` 的全局变量已注册——参见 CLAUDE.md 的 Known Issues 中关于未注册全局变量的记录。）

若出现全局变量注册相关错误，将 arena 全局变量加入 parser 的全局注册表（做法与 CLAUDE.md 记录的 tokenizer 全局注册问题相同）。

- [ ] **步骤 3：提交**

```bash
git add src/stdlib/arena.cr
git commit -m "feat: arena lifecycle allocator — init/new/reset with dynamic metadata"
```

---

### 任务 5：IR Gen 集成（ir_gen.cr）

**涉及文件：**
- 修改：`src/compiler/ir_gen.cr`

- [ ] **步骤 1：添加子图级 arena 跟踪全局变量**

在 `ir_gen.cr` 顶部（注释块之后）新增：

```core
// Subgraph-level arena tracking for compile-time size estimation
g_sg_alloc_total : string, mut    // per-sg: cumulative alloc size
g_sg_alloc_cap   : int, mut
g_sg_arena_var   : string, mut    // per-sg: IR var for arena ID
g_sg_arena_var_cap : int, mut

fn grow_sg_alloc(needed: int):
    if needed < g_sg_alloc_cap:
        return
    nc := g_sg_alloc_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * 8)
    _dyncpy(g_sg_alloc_total, g_sg_alloc_cap * 8, nb)
    g_sg_alloc_total = nb
    g_sg_alloc_cap = nc

fn grow_sg_arena_var(needed: int):
    if needed < g_sg_arena_var_cap:
        return
    nc := g_sg_arena_var_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * 8)
    _dyncpy(g_sg_arena_var, g_sg_arena_var_cap * 8, nb)
    g_sg_arena_var = nb
    g_sg_arena_var_cap = nc
```

- [ ] **步骤 2：添加 sg_alloc_push/pop 与 track_alloc_size**

```core
fn sg_alloc_push(kind: int):
    grow_sg_alloc(g_sg_count + 1)
    grow_sg_arena_var(g_sg_count + 1)
    w64(g_sg_alloc_total, g_sg_count * 8, 0)
    sg_push(kind)

fn sg_alloc_pop():
    total := r64(g_sg_alloc_total, (g_sg_count - 1) * 8)
    arena_var := r64(g_sg_arena_var, (g_sg_count - 1) * 8)
    sg_pop()
    emit(IR_ARENA_RESET, -1, arena_var, 0, 0, 0)

fn track_alloc_size(size: int):
    if g_sg_count > 0:
        old := r64(g_sg_alloc_total, (g_sg_count - 1) * 8)
        w64(g_sg_alloc_total, (g_sg_count - 1) * 8, old + size)
```

- [ ] **步骤 3：在 ir_gen_func 的函数入口与出口接入 arena**

在 `ir_gen_func` 中定位 body 生成的起点，替换 `sg_push(kind)` 的调用模式。该函数本身不直接调用 `sg_push`（由 `df_begin_func` 调用），arena 生命周期需加在函数 body 外围。

定位 `if body >= 0 { gen_expr(body); }`，替换为：

```core
    // Function-level arena
    sg_alloc_push(SG_FUNC);
    arena_var := new_ir_var("_arena", TI_INT);
    w64(g_sg_arena_var, (g_sg_count - 1) * 8, arena_var);
    emit(IR_ARENA_NEW, arena_var, total, 0, 0, 0);

    if body >= 0 { gen_expr(body); }

    sg_alloc_pop();
```

该顺序存在问题：`IR_ARENA_NEW` 需要 `total`，而 `total` 须在 body 生成之后才可得；`arena_var` 则须在 body 生成之前确定。调整顺序如下：

```core
    // Function-level arena
    sg_alloc_push(SG_FUNC);
    arena_var := new_ir_var("_arena", TI_INT);
    w64(g_sg_arena_var, (g_sg_count - 1) * 8, arena_var);
    // Emit placeholder IR_ARENA_NEW (size patched at sg_alloc_pop)
    emit(IR_ARENA_NEW, arena_var, 0, 0, 0, 0);
    // Store instruction index for size patching
    arena_instr := g_ir_instr_count - 1;

    if body >= 0 { gen_expr(body); }

    // Patch size estimate
    total := r64(g_sg_alloc_total, g_sg_count - 1);
    if total > 0 { iri_set_s1(arena_instr, total); }

    sg_alloc_pop();
```

- [ ] **步骤 4：在 loop/for/unsafe 边界接入 arena**

定位 `ir_gen.cr` 中既有的 `sg_push`/`sg_pop` 调用点。

LOOP（约第 659 行）：
```core
    sg_alloc_push(SG_LOOP);
    arena_var := new_ir_var("_arena", TI_INT);
    w64(g_sg_arena_var, (g_sg_count - 1) * 8, arena_var);
    emit(IR_ARENA_NEW, arena_var, 0, 0, 0, 0);
    arena_instr := g_ir_instr_count - 1;
    // ... loop body gen ...
    total := r64(g_sg_alloc_total, g_sg_count - 1);
    if total > 0 { iri_set_s1(arena_instr, total); }
    sg_alloc_pop();
```

FOR（约第 724 行）：
```core
    sg_alloc_push(SG_FOR);
    arena_var := new_ir_var("_arena", TI_INT);
    w64(g_sg_arena_var, (g_sg_count - 1) * 8, arena_var);
    emit(IR_ARENA_NEW, arena_var, 0, 0, 0, 0);
    arena_instr := g_ir_instr_count - 1;
    // ... for body gen ...
    total := r64(g_sg_alloc_total, g_sg_count - 1);
    if total > 0 { iri_set_s1(arena_instr, total); }
    sg_alloc_pop();
```

UNSAFE（约第 1005 行）：
```core
    sg_alloc_push(SG_UNSAFE);
    arena_var := new_ir_var("_arena", TI_INT);
    w64(g_sg_arena_var, (g_sg_count - 1) * 8, arena_var);
    emit(IR_ARENA_NEW, arena_var, 0, 0, 0, 0);
    arena_instr := g_ir_instr_count - 1;
    ret := gen_expr(ast_a(node));
    total := r64(g_sg_alloc_total, g_sg_count - 1);
    if total > 0 { iri_set_s1(arena_instr, total); }
    sg_alloc_pop();
```

- [ ] **步骤 5：将 track_alloc_size 接入全部 ALLOC 指令发射点**

`track_alloc_size` 可在各 ALLOC 发射点分别调用，也可在 `emit()` 内统一调用。选定位置为 `emit()` 内部：写入指令之后判断 opcode 是否为 ALLOC 变体，是则记录尺寸。

在 `emit()` 末尾（`g_ir_instr_count = idx + 1;` 与 `df_create_node(...);` 之后）新增：

```core
    // Track allocation size for subgraph arena size estimation
    if opcode == IR_ALLOC && src1 > 0:
        track_alloc_size(src1)
    if opcode == IR_ALLOC_STRUCT:
            // struct size = field_count * 8 (from name_ni in s3)
            // For now, just track as default — refined in future passes
        track_alloc_size(64)
    if opcode == IR_ALLOC_ARRAY && src1 > 0:
        track_alloc_size(src1 * 8)
```

- [ ] **步骤 6：提交**

```bash
git add src/compiler/ir_gen.cr
git commit -m "feat: ir_gen arena lifecycle — sg_alloc_push/pop, size estimation, subgraph binding"
```

---

### 任务 6：ELF 后端——emit_alloc_body 双路径（elf.cr）

**涉及文件：**
- 修改：`src/arch/linux/ld/elf.cr`

- [ ] **步骤 1：阅读现有 emit_alloc_body**

阅读 `emit_alloc_body` 现有实现（`elf.cr` 中约第 23-84 行），其结构如下：
- 发射 `_start` 初始化代码
- 含边界检查（`cmp rdi, 64MB`）
- 从 BSS 递增 `heap_ptr`
- 以 `rep stosb` 清零内存
- 写入长度头，返回数据指针

- [ ] **步骤 2：改写 emit_alloc_body 为双路径**

改写 `emit_alloc_body` 函数体，在入口处检查 `g_current_arena`。新逻辑如下：

```asm
emit_alloc_body:
    ; Entry: rdi = size
    ; Save original size for header
    mov r9, rdi

    ; Check g_current_arena
    lea r10, [rip + g_current_arena]
    mov r10d, [r10]           ; 32-bit load (arena ID fits in int32)
    test r10d, r10d
    js .Lglobal_alloc          ; if < 0, use global bump

    ; ── Arena allocation path ──
    ; r10d = ai (arena index)

    ; Load arena_cursors[ai]
    lea r11, [rip + g_arena_cursors]
    mov r11, [r11]             ; load cursor array pointer
    mov rcx, [r11 + r10*8]     ; rcx = cursors[ai] = old_cursor

    ; Load arena_sizes[ai]
    lea r11, [rip + g_arena_sizes]
    mov r11, [r11]             ; load sizes array pointer
    mov r8, [r11 + r10*8]      ; r8 = sizes[ai] = chunk max

    ; Load g_arena_pool_data
    lea r11, [rip + g_arena_pool_data]
    mov r11, [r11]             ; r11 = pool_base address

    ; Compute chunk start: pool_base + ai * g_arena_max_size
    ; g_arena_max_size is stored in BSS
    lea rdx, [rip + g_arena_max_size]
    mov rax, [rdx]             ; rax = g_arena_max_size
    mul r10d                   ; rax = ai * arena_max_size (low 64 bits)
    add r11, rax               ; r11 = pool_base + ai * arena_max_size (= chunk start)

    ; Align size
    mov rdi, r9                ; reload original size
    add rdi, 15
    and rdi, -8

    ; Bump
    mov rax, rcx               ; rax = old_cursor
    add rcx, rdi               ; rcx = new_cursor
    cmp rcx, r8                ; new_cursor > chunk_size?
    ja .Lchain_expand

    ; Update cursor
    lea rdx, [rip + g_arena_cursors]
    mov rdx, [rdx]
    mov [rdx + r10*8], rcx     ; cursors[ai] = new_cursor

    ; Return chunk_start + old_cursor
    add rax, r11               ; rax = chunk_start + old_cursor
    ; Store length header (hidden 8 bytes before data ptr)
    mov [rax], r9
    lea rax, [rax + 8]         ; return data ptr after header
    ret

.Lchain_expand:
    ; Arena OOM — chain expand: allocate from global heap
    ; Save current arena ID
    push r10
    ; Temporarily disable arena mode
    mov qword [rip + g_current_arena], -1
    ; Fall through to global alloc path

.Lglobal_alloc:
    ; ── Global bump path (existing logic, slightly adapted) ──
    ; (Original emit_alloc_body code goes here)
    mov r8, r9                 ; r8 = original size (for header)
    add rdi, 15
    and rdi, -8
    lea r10, [rip + heap_ptr]
    mov rax, [r10]
    lea rdx, [rax + rdi]
    lea rcx, [rip + heap_end]
    cmp rdx, rcx
    ja .Loom
    mov [r10], rdx
    mov [rax], r8
    ; zero-init
    push rax
    push rdx
    lea rdi, [rax + 8]
    xor eax, eax
    sub rdx, rdi
    mov rcx, rdx
    cld
    rep stosb
    pop rdx
    pop rax
    lea rax, [rax + 8]
    ; If we came from chain_expand, restore arena
    ; Check if stack has saved arena ID
    ; (Simplification: chain expand just returns this global alloc ptr)
    ret

.Loom:
    xor eax, eax
    ret
```

注：上述汇编为示意。实际实现须为与既有 `emit_alloc_body` 接口兼容的精确 x86-64 机器码发射。要点如下：
1. 函数入口不变（`rdi = size`）
2. 函数出口不变（`rax = pointer` 或 0）
3. arena 路径通过 RIP 相对寻址读取全局变量
4. 链式扩展落至全局 bump 路径

实际发射使用 `w8(buf, pos+cp, byte)` 等原语，遵循既有模式。

- [ ] **步骤 3：更新阶段 2 尺寸估算中 emit_alloc_body 的返回签名**

在 `elf_gen` 中预计算 `emit_alloc_body` 尺寸的位置（现为硬编码 84 字节），上调估算尺寸以容纳扩展后的函数（约为原值的两倍，约 160-180 字节）。

```core
    total_code = total_code + 180;  // arena-aware alloc body
```

- [ ] **步骤 4：提交**

```bash
git add src/arch/linux/ld/elf.cr
git commit -m "feat: emit_alloc_body dual-path arena alloc + chain expansion fallback"
```

---

### 任务 7：ELF 后端——arena NEW/RESET 编码（instr.cr、resolve.cr）

**涉及文件：**
- 修改：`src/arch/linux/ld/instr.cr`
- 修改：`src/arch/linux/ld/elf.cr`（新增 `arena_new_impl` / `arena_reset_impl` 发射）
- 修改：`src/arch/linux/ld/resolve.cr`

- [ ] **步骤 1：向 instr.cr 添加 IR_ARENA_NEW 编码**

定位 `instr.cr` 的主指令编码函数（IR opcode 分发处，约 `if op == IR_ALLOC` 段），在末尾 `return cp` 之前新增：

```core
    if op == IR_ARENA_NEW {
        // dest = arena_var (IR var that receives the arena ID)
        // src1 = size_estimate (currently advisory, 0 = use default)
        // Emit: call arena_new_impl
        // After call, store the result (arena ID) to dest slot
        do2 := g2_slot(d);
        grow_alloc_patch(g_x86_alloc_patch_count + 1);
        w64(g_x86_alloc_patch_pos, g_x86_alloc_patch_count * 8, pos + cp);
        g_x86_alloc_patch_count = g_x86_alloc_patch_count + 1;
        e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;  // call placeholder
        // Store returned arena ID to dest variable
        cp = cp + e2_st(buf, pos+cp, 0, do2);
        return cp;
    }
```

- [ ] **步骤 2：向 instr.cr 添加 IR_ARENA_RESET 编码**

```core
    if op == IR_ARENA_RESET {
        // src1 = arena_id (IR variable)
        // Load arena_id into edi, call arena_reset_impl
        cp = cp + e2_load_var(buf, pos+cp, 7, s1);  // mov edi, arena_id
        grow_alloc_patch(g_x86_alloc_patch_count + 1);
        w64(g_x86_alloc_patch_pos, g_x86_alloc_patch_count * 8, pos + cp);
        g_x86_alloc_patch_count = g_x86_alloc_patch_count + 1;
        e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;  // call placeholder
        return cp;
    }
```

注：`e2_load_var(buf, pos+cp, 7, s1)` 将 IR 变量 `s1` 载入 rdi（`edi` 的编号为 7）。寄存器编号约定以 `instr.cr` 为准，发射代码须匹配调用约定（`rdi` = 第一个参数）。

- [ ] **步骤 3：在 sizes.cr 中为新 opcode 添加尺寸估算**

定位 `src/arch/linux/ld/sizes.cr` 的指令尺寸函数，新增尺寸分支：

```core
    if op == IR_ARENA_NEW {
        // call(5) + store(4) = 9 bytes
        return 9;
    }
    if op == IR_ARENA_RESET {
        // load_var edi(4) + call(5) = 9 bytes
        return 9;
    }
```

- [ ] **步骤 4：向 elf.cr 添加 arena_new_impl / arena_reset_impl**

在 `elf.cr` 中（`emit_alloc_body` 之后）新增两个发射函数：

```core
// Emit arena_new_impl — creates a new arena slot.
// Called from IR_ARENA_NEW. Returns arena ID in rax.
// For initial implementation: just call the Core arena_new() function.
// This is a placeholder that expands into:
//   call arena_new   (via PLT if available, or direct reloc)
// We emit a call instruction that gets patched similarly to alloc calls.
fn emit_arena_new_impl(buf: string, pos: int) -> int:
    // mov edi, 0 (no size hint for now)
    e2_w8(buf, pos, 191)
    e2_w32(buf, pos+1, 0)  // mov edi, 0
    // call arena_new — placeholder, patched at link time
    grow_alloc_patch(g_x86_alloc_patch_count + 1)
    w64(g_x86_alloc_patch_pos, g_x86_alloc_patch_count * 8, pos + 5)
    g_x86_alloc_patch_count = g_x86_alloc_patch_count + 1
    e2_w8(buf, pos+5, 232)
    e2_w32(buf, pos+6, 0)  // call placeholder
    // ret
    e2_w8(buf, pos+10, 195)  // ret
    return 11

// Emit arena_reset_impl — resets an arena slot.
// Called from IR_ARENA_RESET. Takes arena ID in edi, void return.
fn emit_arena_reset_impl(buf: string, pos: int) -> int:
    // edi already contains arena_id from caller
    // call arena_reset — placeholder, patched at link time
    grow_alloc_patch(g_x86_alloc_patch_count + 1)
    w64(g_x86_alloc_patch_pos, g_x86_alloc_patch_count * 8, pos)
    g_x86_alloc_patch_count = g_x86_alloc_patch_count + 1
    e2_w8(buf, pos, 232)
    e2_w32(buf, pos+1, 0)  // call placeholder
    // ret
    e2_w8(buf, pos+5, 195)  // ret
    return 6
```

- [ ] **步骤 5：在 elf_gen 中登记 arena_new_impl / arena_reset_impl**

在 `elf_gen` 中，alloc body 发射及其偏移登记之后新增：

```core
    // arena_new_impl
    grow_func_offsets(g_x86_func_off_count * 2 + 2);
    w64(g_x86_func_offsets, g_x86_func_off_count * 16, str_intern("arena_new_impl"));
    w64(g_x86_func_offsets, g_x86_func_off_count * 16 + 8, total_code);
    g_x86_func_off_count = g_x86_func_off_count + 1;
    total_code = total_code + 11;  // emit_arena_new_impl size

    // arena_reset_impl
    grow_func_offsets(g_x86_func_off_count * 2 + 2);
    w64(g_x86_func_offsets, g_x86_func_off_count * 16, str_intern("arena_reset_impl"));
    w64(g_x86_func_offsets, g_x86_func_off_count * 16 + 8, total_code);
    g_x86_func_off_count = g_x86_func_off_count + 1;
    total_code = total_code + 6;  // emit_arena_reset_impl size
```

Phase 3（发射）中，在调用 `emit_alloc_body` 之后调用新增的发射函数：

```core
    // arena_new_impl
    cp = cp + emit_arena_new_impl(buf, cp);
    // arena_reset_impl
    cp = cp + emit_arena_reset_impl(buf, cp);
```

- [ ] **步骤 6：在 resolve.cr 标签解析中处理新 opcode**

在 `resolve.cr` 中确认各标签相关 pass 跳过新增 opcode（新增 opcode 不使用标签）。

- [ ] **步骤 7：提交**

```bash
git add src/arch/linux/ld/instr.cr src/arch/linux/ld/elf.cr src/arch/linux/ld/sizes.cr src/arch/linux/ld/resolve.cr
git commit -m "feat: ELF backend arena_new/reset opcode encoding + impl stubs"
```

---

### 任务 8：测试

**涉及文件：**
- 创建：`tests/suite/arena_test.cr`

- [ ] **步骤 1：编写 arena 生命周期测试**

```core
// Arena memory model test suite
// Tests basic arena lifecycle, nesting, and alloc integration

fn test_arena_basic() -> int:
    arena_init(1048576, 65536)  // 1MB pool, 64KB chunks

    // Create arena
    a1 := arena_new()
    if a1 < 0:
        return 1
    // arena_new failed
    if g_current_arena != a1:
        return 2
    // not activated

    // Alloc should now use arena
    p := alloc(64)
    if p == 0:
        return 3
    // alloc failed

    // Reset
    arena_reset(a1)
    if g_current_arena >= 0:
        return 4
    // should be -1 after reset

    // Re-use arena from free list
    a2 := arena_new()
    if a2 != a1:
        return 5
    // should reuse same ID

    arena_reset(a2)
    return 0  // pass

fn test_arena_nesting() -> int:
    arena_init(1048576, 65536)

    a1 := arena_new()    // parent
    p1 := alloc(32)
    if p1 == 0:
        return 1

    a2 := arena_new()    // child (arena in loop)
    if g_current_arena != a2:
        return 2
    p2 := alloc(64)
    if p2 == 0:
        return 3

    // Child reset should restore parent
    arena_reset(a2)
    if g_current_arena != a1:
        return 4

    // Parent still works
    p3 := alloc(16)
    if p3 == 0:
        return 5

    arena_reset(a1)
    return 0

fn test_arena_free_list_reuse() -> int:
    arena_init(1048576, 65536)

    // Allocate multiple arenas
    a1 := arena_new()
    arena_reset(a1)
    a2 := arena_new()
    arena_reset(a2)
    a3 := arena_new()
    arena_reset(a3)

    // Next new should reuse a3 (LIFO free list)
    a4 := arena_new()
    if a4 != a3:
        return 1
    // should reuse most recently freed

    arena_reset(a4)
    return 0

fn main() -> int:
    r1 := test_arena_basic()
    if r1 != 0:
        print("FAIL basic: ")
        println(int_str(r1))
        return r1

    r2 := test_arena_nesting()
    if r2 != 0:
        print("FAIL nesting: ")
        println(int_str(r2))
        return r2

    r3 := test_arena_free_list_reuse()
    if r3 != 0:
        print("FAIL freelist: ")
        println(int_str(r3))
        return r3

    println("ALL PASS")
    return 0
```

- [ ] **步骤 2：以解释器运行测试**

```bash
./build/corec run -f tests/suite/arena_test.cr
```

（注：`-f` 标志可能不存在——`run` 子命令接受文件路径或内联代码，正确语法以 `./build/corec --help` 为准。）

若 `run` 命令不支持导入 stdlib 文件，改用：
```bash
./build/corec build tests/suite/arena_test.cr -o /tmp/arena_test --static
/tmp/arena_test
echo $?
```

或将 arena 代码直接内联进测试文件（不使用 `import`），直接以解释器测试。

- [ ] **步骤 3：运行既有测试确认无回归**

```bash
python3 tests/bootstrap/test_pipeline.py
python3 tests/selfhost/test_compile.py
```

预期：既有测试全部通过（非 arena 测试不会触发 arena 代码路径）。

- [ ] **步骤 4：提交**

```bash
git add tests/suite/arena_test.cr
git commit -m "test: arena lifecycle, nesting, and free-list reuse"
```
