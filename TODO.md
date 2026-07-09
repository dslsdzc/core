# TODO

## ✅ 已完成

### 本阶段（2025-07-08/09）：自举阻塞——ELF 后端修复 + tokenizer 全本地化

| 修复 | 文件 | 说明 |
|------|------|------|
| `res_labels` 后 rip_patch 复位 | `elf.cr` | scratch 发射不污染 patching |
| `cur_char()`/`peek()` `str_len(g_source)` | `lexer.cr` | 绕过 BSS 读取问题 |
| tokenizer 全本地变量（`_pos`/`_line`/`_col`） | `lexer.cr` | 不依赖 `g_pos`/`g_source_len` 等全局变量 |
| 诊断非致命 | `main.cr` | checker warning 不阻断编译 |
| `ir_gen_globals()` 全局去重 | `ir_gen.cr` | 防止 BSS 偏移覆盖 |
| `g_extra_lets` 修复 `g_global_let_count++` | `parser.cr` | drain 循环漏了递增导致批量声明的非首变量丢失 |
| 编码去魔数化 + `emit_rex`/`emit_modrm`/`emit_sib` | `instr.cr` | |
| 单遍 backpatching | `instr.cr`, `elf.cr` | |
| `.ccr v3` 格式 + key-value 元数据段 | `ccr_io.cr` | |
| 寄存器分配（线性扫描） | `opt.cr` | |
| 多轮 bug 修复（store8 al→dl, argv 寄存器, REX 编码等） | 多处 | |

### Panic handler
- `src/stdlib/panic.cr` — Rust 风格，写 stderr + exit(1)

### 之前完成
- 全部 `[int; MAX_*]` → 动态 byte buffer
- 字符串长度 header、lexer int-based char
- EXPR_ARG 链表、SYM_SO_FN 生存期、函数名精简
- RawRef\<T\> 方案定稿、Zed 扩展

## 剩余工作

### 1️⃣ corec2 tokenizer 死循环（自举阻塞项）

`build/corec2` `check`/`build`/`run` 任何源文件都卡在 tokenizer。

**已修复：** 所有 ELF 后端 rip_patch/bss/instr_size 问题、parser drain 漏递增 `g_global_let_count`。

**仍缺失：** 约 9 个全局变量（`g_tok_cap`, `g_tokens`, `g_str_count`, `g_line`, `g_source_len`, `g_x86_is_global`, `g_x86_global_cap`, `g_str_hash`, `g_error_count`）未注册到 `g_ir_globals`。`check(T_IDENT) && is_new_var_decl()` 不命中它们，但独立测试文件相同模式可正常工作。编译器源码特有的某个 `parse_declaration()` 前置检查可能误吞了这些标识符。需用 GDB 或 syscall 断点追踪 `parse_all()` 中 token 位置跳转。

**修复路线（推荐）：** 用 AST 扫描替代 `g_global_lets` 脆弱机制——`ir_gen_globals()` 遍历 `g_ast` 全量搜集 `EXPR_LET` 节点。

### 2️⃣ corec2 前端性能（~1000x 慢于 build/corec）
ELF 后端全栈操作无寄存器分配。

### 3️⃣ go 并发 + flow + yield
解释器数据流图不包含 IR_SPAWN/CALL 节点。

### 4️⃣ 标准库补全（collections、字符串插值）

### 5️⃣ ARM64 后端移植

## 架构规划

### Arena 内存模型
设计文档见 [`docs/memory-model.md`](docs/memory-model.md)。
堆内存按数据流子图（flow/go/loop）划分独立 Arena，指针碰撞分配，
Arena 游标重置回收，所有权系统防止引用逃逸。

### RawRef\<T\>
unsafe fn 域内可用，方法式读写/算术，null 允许（UB），TOML 控制 volatile。
