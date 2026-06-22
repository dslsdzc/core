# TODO

## ✅ 已完成

### ELF 后端全面修复 Phase 2（2025-06-23）
自举 pipeline 完整走通：`build/corec` → `build/corec2`（376KB ELF），`--help` 正常。

| Bug | 文件 | 影响 |
|-----|------|------|
| `emit_start` argv 用错寄存器（`rdi`→`rsi`） | `elf.cr` | argv 不保存 |
| IR_STORE/IR_STORE_PTR REX 编码 `73`→`76`/`79` | `instr.cr` | `mov [r11],rdx`→写空指针崩 |
| `g_x86_rip_patch_count = 0` 重置在 emit_start 之后 | `elf.cr` | 清掉 argc/argv 的 rip patch |
| `.ccr` 无全局变量段（v2 格式） | `ccr_io.cr` | `g_x86_is_global` 全 0→全局走栈偏移 |
| `bss_va` 公式漏 60B sched_call | `elf.cr` | BSS 偏移一页→全局变量错位 |
| IR_RETURN 不检查全局变量 | `instr.cr` | `return g_var` 读返回地址 |
| `g2_str_off` 多算 8B header | `instr.cr` | 字符串常量 LEA 偏移 8 字节 |
| `instr_size` 固定返回 8 | `instr.cr` | 所有偏移量计算错误 |
| `instr_size` IR_STORE 全局/局部路径不匹配 | `instr.cr` | size 算错→跳转目标偏移 |
| `&&` 无短路求值用在 `g_x86_global_cap` 检查 | `instr.cr` | `r64(null, ...)` 崩 |
| 全局标记在 Phase 3 才做（Phase 0 res_labels 用不到） | `elf.cr` | instr_size 无法判断全局变量 |
| `read_file` 字符串常量 LEA 偏移 8 字节 | `instr.cr` | open("/tmp/t.cr") 传垃圾指针→崩 |

### ✅ Panic handler
- `src/stdlib/panic.cr` — Rust 风格，写 stderr + exit(1)，`import panic` 使用
- ⚠️ 开发调试用

### ✅ 之前完成
- 全部 `[int; MAX_*]` → 动态 byte buffer
- `instr_size` + Phase 2 干运行消除
- 全局搜索 O(n²)→O(n)（str_intern 哈希）
- 字符串长度 header、lexer int-based char
- EXPR_ARG 链表、SYM_SO_FN 生存期、硬编码函数名清理、函数名精简（358 处）
- 自举推进（0.4s 关键字检查）
- RawRef\<T\> 方案定稿、Zed 扩展

## 剩余工作

### 1️⃣ build/corec2 self-check SIGSEGV
corec2 简单程序编译正确，但 `check`/`build` 任何源码处理都 SIGSEGV。
跳转到 BSS 区域执行（超越 code section），`instr_size` 与 `emit_instr` 仍有尺寸不匹配。
**仍可能有问题：** STORE_FIELD/STORE_INDEX/LOAD_FIELD 等含条件分支的指令。

### 2️⃣ corearch 大 .ccr 性能
StackAsmGen 32K+ 指令操作 >10min。瓶颈：栈式代码生成循环开销 >10000×。

### 3️⃣ 标准库补全
- collections.cr 泛型数组、字符串插值

### 4️⃣ ARM64 后端移植

### 5️⃣ .so 编译器插件系统

## 架构规划

### Arena 内存模型（统一内存管理方案）
将堆内存划分为与数据流子图绑定的独立 Arena。分配线性指针碰撞（ptr += size），
回收直接将整个 Arena 游标重置回起始地址（格式化清空），所有权系统静态保证区域内
无活跃引用逃逸。长期运行服务内存占用上限由并发区域数量决定，天然无 GC 停顿。

**前提：** 数据流图为 IR 一等公民，每个 flow/go/loop 映射到 DFNode 子图，
Arena 生命周期绑定到子图执行周期。

### RawRef\<T\>（内核路线前置）
unsafe fn 域内可用，方法式读写/算术，null 允许（UB），TOML 控制 volatile。
