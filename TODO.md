# TODO

## 2025-06-15 大重构：全部数组动态化 + 大量 Bug 修复

### 已完成

#### 全部 `[int; MAX_*]` → 动态 byte buffer
- `globals.cr`: 所有 x86 后端数组 + IR 栈数组 + g_strs + g_diags + g_files/g_mods/g_mod_funcs
- `parser.cr`: g_global_lets, g_loop_stack, g_type_aliases, g_methods, g_mod_paths
- `checker.cr`: g_scope_bounds, g_borrow_scope_markers, g_gen_map_*, g_borrow_vars/g_holder_*
- `dataflow.cr`: g_df_* + 移除 MAX_* 守卫
- `instr.cr` (两个后端): g_x86_func_offsets, g_x86_emit_vars, g_x86_ret_patch_pos, g_x86_alloc_patch_pos
- `ast.cr`: 清理所有无用的 MAX_* 常量定义
- `cli.cr`: g_cli_cmds/flags/args
- `ld.cr`: g_so_paths, g_plts
- `module.cr`: g_seg_starts/fileids, g_line_fileid

#### Bug 修复
- `checker.cr` & `ir_gen.cr`: g_block_stmts 字节偏移计算（`(stmt_start+i)*8`）
- `checker.cr`: find_func 中 fi_name(i) 与 name_idx 的 int 与 string 类型混淆
- `x86_64_stack_asm.py`: P2 \_init_globals 始终输出（无条件）
- `arch/linux/ld/instr.cr`: g_x86_is_global 越界访问（Core 的 && 不短路，需嵌套 if）
- `arch/linux/ld/elf.cr`: g_x86_is_global 标记 + enum 变量标记
- `arch/linux/ld/instr.cr`: IR_LOAD/STORE 全局变量检测加 `g_x86_global_cap` 边界

#### 优化
- `x86_64_stack_asm.py`: 内联 r64/w64/r32/w32/bu8/w8/\_dyncpy（消除 92 个 `call`）

#### 解析器
- `parser.cr`: Option::Some(42) 路径式 enum 构造函数解析
- `parser.cr`: match 模式 `Some(v)` 中子模式从"只数个数"改为递归解析

#### 基础设施
- `build_selfhost.py`: 同步文件列表（添加 dyn_arr.cr 等缺失文件）
- `Core.toml` + `_import.cr` + `entry.cr`: 项目模式支持
- `tools/module_to_ccr.py`: Python Module → .ccr 桥接（实验性）

## 已知问题

### ELF 后端 enum 字段偏移
- MAKE_ENUM 存 tag 在 offset 0，字段在 offset 8
- LOAD_FIELD/STORE_FIELD 需要 +8 偏移
- g_x86_is_enum 检查需避免内联 r64（会导致 arch_instr_size 不匹配）
- 方案: 在 resolve 阶段将偏移预计算到指令的 s3 中

### ELF 后端匹配/枚举
- match 表达式编译通过但运行时 SIGSEGV（字段偏移错误）
- 待 enum 偏移修复后验证

### 自举性能
- build/corec 编译 332KB 源码仍 >10 分钟
- 栈式 x86 代码生成器是根本瓶颈
- 当前状态：小文件正常，大文件极慢
- 自举需要性能突破（ELF 后端直出或 .ccr 桥接）

### Python bootstrap 与自宿主 parser 不同步
- build_selfhost.py（解释器模式）已恢复工作
- 但 Python 前端缺少自宿主 parser 的部分特性
- 长期：完全迁移到自宿主编译器后弃用 Python 引导
