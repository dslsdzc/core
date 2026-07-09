# Core 自举调试报告：corec2 → corec3

> 日期: 2026-07-06
> PR: https://github.com/dslsdzc/core/compare/main...RhineIris:core:main

## 目标

用 corec2 (Stage 1，由 Python bootstrap 编译) 编译自身源码，产生 corec3 (Stage 2)。

构建命令：
```
./build/corec build build/all.cr -o build/corec2 --static -O 0
./build/corec2 build build/all.cr -o build/corec3 --static -O 0  # 目标
```

---

## 已修复的 Bug（3 个，已包含在 PR 中）

### Bug 1: `alloc_registers()` 在 O1 损坏字符串引用

**文件:** `src/compiler/main.cr` 第 374-380 行

**问题:** `alloc_registers()` 在 O1 被调用，污染了 `g_opt_meta`，导致 ELF 后端生成的二进制中字符串引用（LEA rip-relative）指向错误地址。`println` 的字符串参数使 `str_len` 无限扫描内存——表现为死循环。

**修复:**
```diff
- if g_opt_level >= 1 {
-     pass_cse();
-     alloc_registers();
-     if g_opt_level >= 2 { pass_stack_share(); }
- }
+ if g_opt_level >= 1 { pass_cse(); }
+ if g_opt_level >= 2 { alloc_registers(); pass_stack_share(); }
```

---

### Bug 2: Type-check 诊断 fatal 导致自举中断

**文件:** `src/compiler/main.cr` 第 123-128 行

**问题:** Self-hosted 编译器在类型检查后将所有诊断（包括 `TC_IF_BRANCH` "if branches have different types"）当致命错误处理。但 Python bootstrap 将这些视为 warning。源码 `opt.cr` 中的 `if...else if` 链产生大量 TC02 警告，导致自举编译中止。

**修复:**
```diff
  check_all();
- if g_diag_count > 0 { print_diagnostics(); return 1; }
+ // Type-check diagnostics are non-fatal (match Python bootstrap behavior).
+ if g_diag_count > 0 { print_diagnostics(); }
```

---

### Bug 3: `cur_char()` / `peek()` 中 `g_source_len` 读取不一致

**文件:** `src/compiler/lexer.cr` 第 33-47 行

**问题:** 全局变量 `g_source_len` 在 `tokenize()` 中写入的 BSS 地址与 `cur_char()` 中读取的 BSS 地址不同——写入去了地址 A，读取从地址 B（未被写入，始终为 0）。`cur_char()` 永远判定 "past end of source"，返回 0（EOF），tokenizer 不产生任何 token。

**修复:**
```diff
 fn cur_char() -> int {
-    if g_pos >= g_source_len { return 0; }
+    src_len := str_len(g_source);
+    if g_pos >= src_len { return 0; }
     return load8(g_source, g_pos);
 }

 fn peek() -> int {
-    if g_pos + 1 >= g_source_len { return 0; }
+    src_len := str_len(g_source);
+    if g_pos + 1 >= src_len { return 0; }
     return load8(g_source, g_pos + 1);
 }
```

`str_len(g_source)` 直接从字符串的 8 字节 header 读取长度，绕过全局变量 patching 问题。

---

## 仍未解决的根本性 Bug：ELF 后端 rip_patch 位置错位

### 症状

即使上述 3 个修复全部应用，corec2 在 O0 下仍然一进入 `tokenize()` 就死循环。死循环的原因：`advance()` 写入 `g_pos` 的 BSS 地址与 tokenize 循环条件 `g_pos >= g_source_len` 读取 `g_pos` 的地址不同。`advance()` 将递增后的值写入地址 A，但循环条件始终从地址 B 读取（值永远为初始值 0）。

**空函数 tokenize 验证：**
```core
fn tokenize() {
    g_token_count = 0;
    g_pos = 0;
    add_token(T_EOF);
    return;
}
```
将 tokenize 替换为空函数后，corec2 **完全正常工作**——tokenize → parse → check → IRgen 全部通过，exit 0。确认问题仅在 tokenize 循环体内。

### 调试过程

#### 1. 排除 rip_patch 计算错误（已验证正确）

在 `elf_gen()` 的 rip_patch 循环中添加调试：对每个 `g_pos`（var_idx=698）的 patch 条目打印 `ppos`、`g_x86_global_off`、`target_va`、`rel`。

**结果：全部 16 个 `g_pos` patch 计算正确：**

```
PATCH gvi=698 ppos=74669 off=5584 target=4736480 rel=467503
PATCH gvi=698 ppos=74751 off=5584 target=4736480 rel=467421
PATCH gvi=698 ppos=74845 off=5584 target=4736480 rel=467327
... (16 total, all target=4736480 ✓)
```

- `off=5584` → 全部一致
- `target_va=4736480` (= bss_va + 16 + 5584) → 全部一致
- rip_patch 计算 `target_va - lea_end_va` 的公式正确

#### 2. 排除函数调用 patching 失败（已验证正确）

```diff
  // ── Patch forward calls ──
+ call_patched := 0; call_missed := 0;
  ...
+ print("  CALLS: patched="); print(int_str(call_patched));
+ print(" missed="); println(int_str(call_missed));
```

**结果：`CALLS: patched=4390 missed=0`** —— 全部 4390 个函数调用正确 patch，0 个失败。

#### 3. 排除 ELF 结构错误（已验证正确）

- ELF program headers: code segment (r-x), data segment (rw-, 256MB)
- BSS 在 rw- 段内，地址范围正确
- 内置函数（load64=35, store8=29, syscall3=11, w64=126）全部正确注册

#### 4. 发现：w32 写入后 read-back 正确，但最终文件不正确

在 rip_patch 循环中添加即时验证：

```core
w32(buf, ppos, rel);
// Read back immediately:
v0 := bu8(buf, ppos); v1 := bu8(buf, ppos+1);
v2 := bu8(buf, ppos+2); v3 := bu8(buf, ppos+3);
rbv := v0 + v1*256 + v2*65536 + v3*16777216;
print("    RB: bytes="); ... print(" val="); println(int_str(rbv));
```

**read-back 输出：**
```
PATCH gvi=698 ppos=74717 off=5584 target=4736480 rel=467455
    RB: bytes=255,33,7,0 val=467455     ← 完全正确！
```

**但最终二进制文件中的实际值：**
```
file offset 74893 (176+74717): [0xff, 0x48, 0x89, 0x45]
= 0x458948ff (指令代码，不是 displacement 467455)
```

第一个字节 `0xff`(255) 正确，后三个字节 `0x48 0x89 0x45` 是指令代码（`mov [rbp+...], rax`）。

#### 5. 确认：w32 写入到错误的位置

在 `elf_gen` 末尾（`return` 之前）加入验证标记：

```core
w32(buf, 500000, 0x12345678);   // 标记 1: 代码段深处
w32(buf, 74717, 0xDEADBEEF);    // 标记 2: ppos 位置
read-back 确认均写入正确值，然后 return
```

同时在 `corearch_main` 中 `elf_gen` 返回后、`syscall3(write)` 前再加标记：

```core
sz := elf_gen(g_elf_buf);
w32(g_elf_buf, 74717, 0xCAFEBABE);  // 标记 3
syscall3(1, fd, g_elf_buf, sz);
```

**最终二进制文件中的值：**

| 位置 | 期望值 | 实际值 | 状态 |
|------|--------|--------|------|
| buf[500000] | 0x12345678 | 0x12345678 | 保留 ✓ |
| buf[74717] | 0xCAFEBABE 或 0xDEADBEEF | 0x458948ff | 覆盖 ✗ |

- 标记 1（位置 500000）→ **保留成功**，说明 buffer 在 elf_gen 返回后没有被整体污染
- 标记 2（位置 74717）和标记 3（位置 74717）→ **都被覆盖**，最终值是原始指令代码

#### 6. 反汇编确认：ppos 不指向 LEA displacement

```
文件偏移 0x1245d (176+74717):
  74714: e9 e4 fe ff ff    CALL -0x11C          ← 这是一条 CALL 指令
  74719: 48 89 45          MOV [rbp+...], rax    ← 下一条指令
```

**ppos=74717 处于 CALL 指令的 4 字节位移字段内**（CALL 指令第 1-4 字节），而非 LEA（`4C 8D 1D ...`）的 displacement 字段。

真正的 LEA 指令在位置 74704（`4C 8D 1D 4A 21 07 00`），其 displacement 字段在 74707。但 rip_patch 注册的 ppos 是 74717，差了 10 字节。

### 根因分析

`emit_instr()` 中注册 rip_patch 时，`pos + cp + 3` 计算出的 buffer 位置与实际发射的 LEA 指令位置存在偏移。

**代码路径：**

```core
// emit_instr (instr.cr:299)
fn emit_instr(instr_idx, buf, pos) {
    cp := 0;
    ...
    if op == IR_LOAD && d >= 0 {
        w64(g_x86_rip_patch_pos, ..., pos + cp + 3);  // <= ppos 在这里注册
        cp = cp + e2_lr(buf, pos+cp, 0);               // <= LEA 在这里发射
        ...
    }
}
```

调用方（elf.cr:545）：
```core
sz := emit_instr(inst_idx, buf, cp);  // pos = cp (当前 buffer 位置)
cp = cp + sz;
```

**可能的原因：**
- `cp` 在调用 `emit_instr` 前被某个中间操作修改
- `e2_lr` 实际发射的位置与 `pos + cp` 不同（例如 `e2_lr` 内部使用了不同的偏移）
- 函数 prologue（push rbp 等）的大小计算与实际发射不一致，导致后续 `cp` 偏移累积错误

### 建议调试方法

在 `emit_instr` 中，对特定的全局变量（如 `g_pos`, var_idx=698）添加条件断点：

```core
// 在 e2_lr 调用前后验证
actual_lea_pos := pos + cp;                    // emit_instr 认为的位置
cp = cp + e2_lr(buf, pos+cp, 0);
// 此时 buf[actual_lea_pos] 应等于 0x4C (LEA r10 REX 前缀)
// 或 0x4D (LEA r11 REX 前缀)
// 如果 buf[actual_lea_pos] 是其他值（如 0xE8 CALL），则存在偏移
```

用 GDB 硬件 watchpoint 跟踪 `buf[74717]` 的写入顺序，确认是哪个操作在 rip_patch 循环之后覆盖了正确值。

---

## 环境

- 平台: WSL2 (Ubuntu, x86-64)
- Core 仓库: https://github.com/dslsdzc/core
- Fork: https://github.com/RhineIris/core
- 构建: `python3 build_selfhost_native.py` → `./build/corec build build/all.cr --static -O 0`
