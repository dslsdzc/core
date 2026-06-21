# 更新日志

## 2026-06-21

### 调度器框架
- `src/stdlib/scheduler.cr` — 运行时调度表（无上限 64 位）
- `sched_create`/`sched_set`/`sched_get` 通过逐字节 `*256` 拼装，不依赖大常数
- `sched_call_0~4` 汇编跳板内建到 ELF（参数移位 + 间接尾调用）
- 为替代 PLT/GOT 做准备

### 后端大常数修复
- `e2_li` 支持存放 >= 2^31 的立即数（`mov rax, imm64` + `mov [rbp], rax`）
- `sizes.cr` 同步更新 `sz_li`

---

## 2026-06-19

### 硬编码函数名清理
- checker 只保留 `syscall3` 硬编码（OS 通信，无 .cr 函数体）
- `load8`/`store8`/`alloc`/`get_arg`/`load_str_ptr`/`store_str_ptr` 通过 `init_builtins()` 注册为正规 SYM_FN
- stdlib 函数（`str_len`/`int_str`/`concat`/`read_file` 等）走正常 `lookup_sym_global` 查找

### 变参与 auto_str 移出编译器
- 变参展开不再由编译器处理，完全交给标准库
- `print_i` 为标准库函数：`fn print_i(n: int) { print(int_str(n)); }`
- 多参数需用户显式分多次调用
- `dispatch_call` 清空（`pass.cr`），等待 .so hook 框架

### EXPR_ARG 链表修复
- 函数调用参数包装为 `EXPR_ARG(a=expr, b=next_arg)` 链表
- 修复复杂表达式参数（`rem + 48`）因顺序 node index 假设被吞的 bug
- checker + IR gen 全部改走链表遍历

### SYM_SO_FN 生存期修复
- `check_all()` 重置 `g_sym_count` 导致 SO 条目丢失 → save/restore
- `lookup_sym_global` 反向扫描找到 SYM_FN 而非 SYM_SO_FN → 正向 scan
- `ir_gen`/`interp` 改用 `find_so_fn` + tag_flags 替代硬编码函数名

### 函数名精简（358 处改名）
- `dyn_grow_*` → `grow_*`（60+ 函数）
- `lookup_*` → `find_*`，`resolve_*` → `res_*`，`register_*` → `reg_*`
- `ir_gen_expr` → `gen_expr`，`track_str_const` → `track_str`
- `print_int`/`println_int` → `print_i`/`println_i`
- `x86_emit_instr` → `emit_instr`，`arch_instr_size` → `instr_size`

### 后端偏移量全面修复
- rodataref Phase 2 污染 → SIGILL 修复
- LAST RESORT 乱改 call 修复
- e2_li 大偏移 + e2_ld/e2_st 寄存器编码误触发 → 函数内相对偏移
- sub_rsp 只补最后函数 → 每函数即时补
- sizes.cr 单一声源 + `arch_instr_size` 死代码删除

### 文档修复
- 所有 .md 文件增加正确 `#` 标题层级
- 空格对齐表格 → 管道符表格
- `·` 列表 → `-` 列表（Markdown 标准）
- 代码块增加语言标注（`core`/`mermaid`/`dot`/`text`）
- 中二语气修正

### Zed 扩展
- 独立仓库 `core-plugin-zed`
- `editor/zed` 子模块
- Tree-sitter grammar 语法高亮
- `extension.toml` / `highlights.scm` / `LSP 适配器`

---

## 之前的重要更新

### CLI 子命令重构
- corec 从 flag 模式改为子命令模式：`build`/`check`/`cir`/`ccr`/`run`

### 动态数组化
- 全部 `[int;N]` 静态数组 → `string` 动态字节缓冲
- 包括：parser/checker/ir_gen/interp/opt/ld 等模块

### .so 扩展接口
- 索引文件 + SYM_SO_FN 注册
- 动态加载 + PLT/GOT
- `--static` 静态链接
- `core_rt.so` 运行时支持库

### 动态链接修复
- PT_DYNAMIC 程序头、PLT/GOT 布局、符号表/字符串表
- 指令编码修复（SHL/SHR、syscall、sub rsp imm8→imm32）

### 标准库分离
- `io.cr`（I/O）+ `fmt.cr`（格式化/字符串处理）
- 移除全部 `__builtin_*` 前缀
