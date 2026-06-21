# 更新日志

## 2026-06-21

### 调度器框架
- `src/stdlib/scheduler.cr` — 运行时调度表（无上限 64 位）
- `sched_create`/`sched_set`/`sched_get` 通过逐字节 `*256` 拼装
- `sched_call_0~4` 汇编跳板内建到 ELF（参数移位 + 间接尾调用）
- `e2_li` 支持存放 >= 2^31 的大立即数
- `sizes.cr` 同步更新 `sz_li`

### 硬编码清理
- checker 只保留 `syscall3` 硬编码
- runtime builtins 通过 `init_builtins()` 注册为 SYM_FN
- EXPR_ARG 链表修复（参数传递 node index 假设 bug）
- `check_all()` SYM_SO_FN save/restore
- `find_so_fn` 正向扫描替代 `lookup_sym_global` 反向扫描
- `interp.cr` 改用 SYM_SO_FN tag

### 函数名精简（358 处）
- `dyn_grow_*` → `grow_*`
- `lookup_*` → `find_*`
- `resolve_*` → `res_*`，`register_*` → `reg_*`
- `ir_gen_expr` → `gen_expr`
- `print_int`/`println_int` → `print_i`/`println_i`
- `x86_emit_instr` → `emit_instr`
- `parse_compilation_unit` → `parse_unit`

### 变参与 auto_str
- 从编译器移出，完全交给标准库
- `print_i` = `fn print_i(n: int) { print(int_str(n)); }`
- `dispatch_call` 清空，等待 .so hook 框架

### 文档
- 所有 .md 标题、表格、列表修复
- `·` → `-`，代码块语言标注
- 中二语气修正、预期成果删除

### Zed 扩展
- 独立仓库 `core-plugin-zed`
- Tree-sitter grammar 语法高亮
- `editor/zed` 子模块

---

## 2026-06-19

### 后端偏移量全面修复
- rodataref Phase 2 污染 → SIGILL
- LAST RESORT 乱改 call
- e2_li 大偏移 + e2_ld/e2_st 寄存器编码误触发 → 函数内相对偏移
- sub_rsp 只补最后函数 → 每函数即时补
- sizes.cr 单一声源，`arch_instr_size` 死代码删除
- `emit_start` lea rsi `[rbx+8]` → `[rsp+8]`

---

## 2026-06-18

### CLI 子命令
- corec 从 flag 改为子命令：`build`/`check`/`cir`/`ccr`/`run`
- CLI 基础设施 + project 目录模式

### 稳定性修复
- 6 个未初始化动态数组修复（SIGSEGV）
- parser 3 个修复（`parse_primary`/`parse_block`/`parse_for_expr`）
- 字符串插值无限循环修复
- 边界校验加固（ccr_io/ld）

### 标准库分离
- `io.cr`（I/O）+ `fmt.cr`（格式化）
- 移除全部 `__builtin_*` 前缀
- `tok_lx` `get_char`→`istr_get`（SIGSEGV 根因）
- 变参函数语法 `...name:type`

### .so 扩展
- 索引文件 + SYM_SO_FN 注册
- 变参 + auto_str tag 展开
- alloc 堆初始化修复

---

## 2026-06-17

### 地雷清除
- 全部静态 `[int;N]` → 动态字节缓冲
- 动态链接修复（PLT/GOT/符号表/字符串表）
- 指令编码修复（SHL/SHR/syscall/sub rsp）
- `_start` 大小硬编码 → `emit_start_size()`
- 注册编码与堆栈偏移重叠修复

### 动态数组化
- parser/checker/ir_gen/interp/opt/ld 全部模块

---

## 2026-06-16

### 代码生成优化
- 线性扫描寄存器分配
- CFIR passes：常量折叠/代数化简/分支折叠/跳转链/DCE
- 堆栈槽复用（O2）
- 死代码删除

### 特性
- 接口/trait 系统 + 泛型约束
- 静态链接 `--static --link`
- ELF `_start` + argc/argv
- Neovim 插件同步

---

## 2026-06-15

### 动态数组化（核心）
- 全部 `MAX_*` 静态数组替换为动态字节缓冲
- `grow_*` 系列函数
- 修复 P1-P4 崩溃 + `g_x86_is_global` 边界
- `Option::Some(42)` 解析 + match 子模式 + project 模式

---

## 2026-06-14

### 流水线贯通
- 源码到 ELF 二进制全链路跑通！
- BSS 全局变量支持
- 动态链接 PLT/GOT ✓
- 标准库 .so 文件
- ARM64 后端 + 全流水线

---

## 2026-06-13

### 重构前夜
- `MAX_*` 上限全部提升 4-16x
- 后端文本汇编路径移除
- Chunk linker 恢复

---

## 2026-06-09

### 测试
- 回归测试
- `build_selfhost.py` 修复
- 解释器整除 + `store8` 列表修复

---

## 2026-06-08

### 架构重构
- 后端目录拆分
- resolve 独立 pass
- `main.cr` 拆分
- parser 修复

---

## 2026-06-07

### 自宿主编译器首版
- 完整自宿主编译器
- ELF 输出
- 标准库（print/println）
- Rust 风格诊断
- 错误码系统
- Neovim IDE 集成
- Arch PKGBUILD
- 数据流解释器
- 挂起修复

---

## 2026-05-20 ~ 2026-05-28

### 前端与模块系统
- 引用与模块系统
- `.core` → `.cr` 重命名
- `corec`（前端）+ `corearch`（后端）拆分
- `.ccr`/`.cir` 格式规范 + 文档
- 数据流图 IR 模块

---

## 2026-04-24

### 项目初始化
- 首次提交
- ARM64 本地后端 + 全流水线
- float/string/array 基础类型
- 词法/语法/类型检查/IR 生成
- VSCode 语法高亮
- Neovim 配置
- 借用检查/泛型/for 循环测试
