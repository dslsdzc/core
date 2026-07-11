# TODO

## 已完成

### 本阶段（PR #9 合并后，2025-07-09）
- tokenizer 参数化 `tokenize(_src: string)` — 不依赖全局 `g_source` BSS 地址
- `cur_char_at(src, pos, max_len)` / `peek_at()` 替代 `cur_char()`/`peek()`
- `g_extra_lets` drain 修复（`g_global_let_count` 递增）— 批量声明不再丢失
- ELF 后端 rip_patch 复位（`res_labels` 后清空 scratch 污染）
- 诊断非致命 warning
- `ir_gen_globals()` 全局去重
- `.ccr v3` 格式 + key-value 元数据段
- 寄存器分配（线性扫描，14 regs）
- 指令编码去魔数化（`emit_rex`/`emit_modrm`/`emit_sib`）
- 单遍 backpatching
- 多轮 ELF 编码 bug 修复（store8 al→dl, argv 寄存器, REX 编码等）
- `emit_alloc_body` `globals_size` 参数（堆在全局变量之后）

### 之前完成
- 全部 `[int; MAX_*]` → 动态 byte buffer
- 字符串长度 header、lexer int-based char
- EXPR_ARG 链表、SYM_SO_FN 生存期、函数名精简（358 处）
- RawRef\<T\> 方案定稿、Zed 扩展
- Panic handler（`src/stdlib/panic.cr`）
- Arena 内存模型设计（`docs/memory-model.md`）

## 剩余工作

### 1. corec2 tokenizer / 自举阻塞
`build/corec2 check` 仍 SIGSEGV/挂死。
- 约 9 个全局变量（`g_tok_cap`, `g_tokens`, `g_str_count`, `g_line`, `g_source_len`, `g_x86_is_global`, `g_x86_global_cap`, `g_str_hash`, `g_error_count`）未注册到 `g_ir_globals`，`parse_declaration()` 路径不命中。
- tokenizer 已参数化绕过 `g_source` 依赖，但其余未注册全局变量导致崩溃。

**修复方向：** AST 扫描替代 `g_global_lets`——`ir_gen_globals()` 直接遍历 `g_ast` 搜集 `EXPR_LET` 节点。

### 2. corec2 前端性能（~1000x 慢于 build/corec）
ELF 后端全栈操作无寄存器分配。寄存器分配器只作用于用户程序 IR，不影响编译器自身。

### 3. ELF 后端 O1 稳定性
`--opt-level 1` 自举编译可能崩溃（`pass_cse` 大函数/`alloc_registers` 元数据交互）。

### 4. go 并发 + flow + yield
解释器数据流图不包含 IR_SPAWN/CALL 节点。

### 5. 标准库补全、ARM64 移植

## 架构规划

### Arena 内存模型
见 `docs/memory-model.md`。堆按数据流子图划分独立 Arena，指针碰撞分配，游标重置回收。

### RawRef\<T\>
unsafe fn 域内可用，方法式读写/算术，null 允许（UB）。
