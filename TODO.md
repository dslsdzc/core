# TODO

## 已完成

### P0（2026-07-23）
- **ELF struct/array/enum 寻址修复**：`emit_instr()` 的 disp32 写入补上当前指令基址 `pos`，修复字段、常量索引和 enum tag 位移写到 ELF 缓冲区错误位置的问题。
- **变量数组索引修复**：修正 `IR_LOAD_INDEX_VAR` 的 REX.X，以及 `IR_STORE_INDEX_VAR` 的 REX/ModRM/SIB 寄存器角色。
- **corec2 自举阻塞解除**：全新构建验证 `corec2 --help`、tokenizer/check 和 `corec2 -> corec3` 均正常。
- **O1 自举稳定性验证**：完整 `corec -> corec2 -> corec3` 在 O0/O1 下均成功，产物可继续 check/build。
- **原生回归测试**：新增 struct 读写、array 常量/变量索引读写、enum tag 与 O1 aggregate ELF 运行测试。

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

### 1. 解释器局限
- **for 循环**: label/branch 与 dataflow 顺序执行不兼容
- **递归/跨函数调用**: inline 执行不支持 IR_CALL（仅 main→callee 单层可用）
- **字符串**: syscall3 在解释器返回 0，print/str_len 等不可用
- **泛型函数**: 类型检查通过但解释器返回 255

### 2. go 并发 + flow + yield
解释器数据流图不包含 IR_SPAWN/CALL 节点。

### 3. 标准库补全
- 字符串操作（split/join/replace）
- JSON 序列化
- 集合类完整实现

## 架构规划

### Arena 内存模型
见 `docs/memory-model.md`。堆按数据流子图划分独立 Arena，指针碰撞分配，游标重置回收。

### RawRef\<T\>
unsafe fn 域内可用，方法式读写/算术，null 允许（UB）。
