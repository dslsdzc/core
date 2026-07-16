# TODO

## 已完成

### 本阶段（2025-07-17 大规模修复）
- **Token 冲突修复**: T_YIELD/T_INTERFACE(67→97), T_UNSAFE/T_COLON_EQ(68→98)
- **Lexer 关键字补全**: 补充 flow, yield, interface, type, mod, as, auto, fileid, move, in, None, Some, unit 共 14 个
- **解释器修复**:
  - 结构体字段访问（LOAD_FIELD/STORE_FIELD ptr+offset 解引用）
  - 数组索引/修改（LOAD_INDEX/STORE_INDEX/LOAD_INDEX_VAR/STORE_INDEX_VAR）
  - 动态堆分配（ALLOC_STRUCT/ALLOC_ARRAY 真正分配内存）
- **ELF 后端 BSS 修复**:
  - BSS 地址自动计算（基于实际 cp + 4096，确保在代码段后）
  - `return 42` → 正常工作 ✅
  - 函数调用 → 正确传参/返回 ✅
  - type 别名 → 正确解析 ✅

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

## 编译器扩展系统
- **ext_mgr.cr**: 插件注册表 + 钩子调度 | `ext_reg(hook, plugin_id)`, `ext_dispatch_*()`
- **ext_safety.cr**: 安全检查插件 | `CORE_SAFE=1` 启用，监听 `EXT_HOOK_ARRAY_ACCESS`
- **pass.cr**: 钩子调度器 | `pass_before_array_access()` 分发到已注册插件
- **未来**: `.so` 动态加载插件（架构已留好）

## 标准库新增
- **trace.cr**: `trace_assert()`, `trace_dbg()` 运行时诊断
- **assert.cr**: `assert()`, `assert_eq()`, `debug_assert()`, `unreachable()`, `todo()`, `check_bounds()`

## 剩余工作

### 1. ELF 后端 struct/array 指令编码错误
- struct 字段访问返回 20（应为 10），字段 0 和 1 都读到字段 1 的值
- 数组索引返回 20（应为 30），类似偏移问题
- **怀疑**: ALLOC/LOAD/STORE 指令发射层的偏移计算 bug，非 BSS 问题

### 2. corec2 tokenizer / 自举阻塞
`build/corec2` 在任何模式（run/build/check）下立即 SIGSEGV。
- 约 9 个全局变量未注册到 `g_ir_globals`，导致 tokenizer 访问空指针
- `ir_gen_globals()` Phase 3 已尝试显式注册但不足
- **根因**: ELF 后端地址计算 + 全局变量初始化顺序问题

### 3. 解释器局限
- **for 循环**: label/branch 与 dataflow 顺序执行不兼容
- **递归/跨函数调用**: inline 执行不支持 IR_CALL（仅 main→callee 单层可用）
- **字符串**: syscall3 在解释器返回 0，print/str_len 等不可用
- **泛型函数**: 类型检查通过但解释器返回 255

### 4. ELF 后端 O1 稳定性
`--opt-level 1` 自举编译可能崩溃（`pass_cse` 大函数/`alloc_registers` 元数据交互）。

### 5. go 并发 + flow + yield
解释器数据流图不包含 IR_SPAWN/CALL 节点。

### 6. 标准库补全
- 字符串操作（split/join/replace）
- JSON 序列化
- 集合类完整实现

## 架构规划

### Arena 内存模型
见 `docs/memory-model.md`。堆按数据流子图划分独立 Arena，指针碰撞分配，游标重置回收。

### RawRef\<T\>
unsafe fn 域内可用，方法式读写/算术，null 允许（UB）。
