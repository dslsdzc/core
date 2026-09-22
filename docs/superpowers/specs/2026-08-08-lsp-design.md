# Core Language Server (corelsp) 设计

日期：2026-08-08
状态：已批准（brainstorming 会话）

## 1. 背景与目标

Core 语言的前端（自举编译器 corec）已具备完整的 lexer / parser / type checker，
诊断数据结构（g_diags：错误码、消息、行、列）健全，类型检查错误非致命。
当前编辑器支持仅为"浅层"：nvim 保存时 shell 调 corec 解析输出进 quickfix、
VS Code 只有 tmLanguage 高亮、Zed 只有 tree-sitter。无 LSP。

目标：写一个 **Core 自举的 LSP 服务器**（吃自己的狗粮）——用 Core 语言本身实现，
直接复用自举编译器的前端模块。v1 覆盖全家桶功能：
diagnostics / hover / go-to-definition / completion / documentSymbol / semanticTokens。

已确认的决策：
- **实现语言**：Core 自举（复用 src/compiler/ 前端模块）
- **二进制形态**：独立 corelsp 二进制（与 corearch 同模式），非 corec 子命令
- **进程模型**：长期进程，进程内重跑前端检查（非 spawn 子进程）
- **客户端**：只做服务器，VS Code / nvim 客户端配置后补

## 2. 架构

### 2.1 目录结构

```
src/lsp/
├── _import.cr      → 导入编译器前端模块（lexer/parser/checker/diag/module）
├── json.cr         → 手写 JSON 解析器 + 序列化器（递归下降，模式同 toml.cr）
├── rpc.cr          → JSON-RPC 2.0：Content-Length 帧读写 + 方法分发表
├── lsp.cr          → LSP 核心：文档状态、检查管线、方法处理器
├── analysis.cr     → 位置→符号查询：hover / goto-def / completion / symbols / tokens
└── main.cr         → lsp_main() 入口（与 corearch_main 同模式）
```

### 2.2 构建

`build_selfhost_native.py` 加第三段 build 调用（复用现有 build 函数，
`wrapper_fn='lsp_main'`），产出 `build/corelsp`。与 corearch 完全相同的先例。

### 2.3 关键约束

- **stdout 是协议通道**：检查管线必须走"静默版"——直接调
  `tokenize → res_imports → parse_all → check_all`，不能复用 `run_frontend()`
  （其含 `println("[1/5]...")` 进度输出）。日志走 stderr。
- **只跑前端**：到 `check_all` 为止，不生成 IR（`corec check` 命令已验证此路径）。

## 3. 生命周期与全局状态重置

进程内重跑检查是唯一硬骨头。

### 3.1 重置策略

每轮检查前调用 `reset_frontend_state()`（新增，集中列出全部清零项）：

- **重置（清 count，保留 cap）**：`g_tokens` / `g_ast` / `g_errors` / `g_diags` /
  `g_block_stmts`、符号表（`g_funcs` / `g_structs` / `g_enums` / `g_syms` /
  `g_types` / `g_ifaces` / `g_methods` / `g_type_aliases` / `g_generic_constr` /
  `g_gen_params` 等）、检查器临时状态（`g_scope_bounds` / `g_borrow_*` /
  `g_alloc_pts` 等）、`g_files` / `g_mods`
- **不重置**：字符串驻留表 `g_strs` / `g_str_hash`（跨检查存活，内容去重，内存收敛）

清 count 保留 cap：缓冲容量复用，避免每轮重新分配。
`reset_frontend_state()` 放 globals.cr 旁边，一处管理，避免漏网。

### 3.2 已知代价

bump allocator 不回收，字符串内容泄漏到进程退出；内存上限 ≈
会话内唯一字符串总量 + 各缓冲峰值。数小时编辑会话量级几十 MB，可接受。

### 3.3 验证手段

集成测试连续两次检查——第二次故意改出错误，断言诊断被更新
（专门抓"重置漏项 → 幽灵诊断"）。

## 4. 诊断记录扩展

diag 记录当前为 32 字节（error_code / msg_ptr / line / col），**无文件 ID**。
多文件项目诊断无法按文件分发 → 需给 `g_diags` 记录加 file_id 字段
（32→40 字节），与已有的 `g_files` 文件表（module.cr）配套。
`print_diagnostics()` 同步适配（保持现有输出格式不变）。

## 5. 协议层与文档状态

### 5.1 帧循环（rpc.cr）

- 读：`read(0, buf, 4096)` 循环 → 解析 `Content-Length: N\r\n\r\n` 头 → 读满 N 字节
  （`syscall3(0, 0, buf, n)`，rt.s 零改动）
- 写：`syscall3(1, 1, s, len)` 组装帧写出
- 分发：方法名 → 处理器映射

### 5.2 v1 方法表

| 类别 | 方法 |
|------|------|
| 生命周期 | `initialize` / `initialized` / `shutdown` / `exit` |
| 文档 | `didOpen` / `didChange` / `didSave` / `didClose` |
| 查询 | `hover` / `definition` / `completion` / `documentSymbol` / `semanticTokens/full` |

### 5.3 文档状态与检查触发

- `g_open_docs`：路径 → 最新缓冲区内容；`textDocumentSync = 1`（全量同步，v1 不做增量 diff）
- **didChange 同步重跑检查**（~100ms，在请求处理内完成），随后 `publishDiagnostics`
  发布**所有有诊断的文件**（检查是整项目的；编辑 A 文件可能影响导入它的 B 文件——
  全量发布最简单且正确）
- 打开文件的源文本**从缓冲区取，不走磁盘**：module.cr 导入读取路径加 helper——
  先查 `g_open_docs`，未打开才读盘。支持多文件同时编辑
- 检查产物只保留：诊断（带 file ID）、符号表（`g_funcs`/`g_structs`/`g_syms`/...）、
  令牌流（`g_tokens`，带 line/col/kind）。查询全部基于这三者，不依赖 IR

### 5.4 坐标转换（序列化层统一处理）

- 编译器行/列 1-based → LSP 0-based，输出时 -1
- 列偏移 v1 按字节近似（ASCII 精确；中文注释内的错误列会偏，TODO 注明，后补 UTF-16 转换）

## 6. 查询功能

五个功能全部走同一模式：**位置 → 令牌查找 → 符号表查询**（analysis.cr 一个模块）。

| 功能 | 逻辑 |
|------|------|
| `hover` | 扫 `g_tokens` 找光标处令牌（令牌带 line/col）→ 查符号表 → 返回签名（函数：参数类型 + 返回类型；变量：类型；结构体：字段列表） |
| `definition` | 同令牌查找 → 符号声明记录 → 返回 `{uri, range}`，支持跨文件跳转（file ID → 路径）。位置来源：函数经 `fi_ast_node(fi)` → AST 节点 line/col（已验证）；结构体/枚举声明位置从 AST 顶层节点按名字反查（实现时确认反查路径） |
| `completion` | 光标前扫标识符前缀 → 关键字表 + 当前可见符号（函数/全局变量/结构体/枚举）按前缀过滤 → `CompletionItem`（kind 区分 Keyword/Function/Variable/Struct）。**关键字表唯一来源：`src/compiler/lexer.cr` 的 `lookup_keyword()`（33 个）**——tokens.ebnf 与 language-syntax.md 均过时（ebnf 漏 `while`/`extern`/`in`，多 `requires`/`ensures` 等 6 个未实现关键字）。**`@` 后输入时补全 @ 内建**：名单唯一来源是 `checker.cr` EXPR_AT 分发的 str_eq 名字（14 个：sizeOf/addr/alignOf/fields/hasField/field/typeInfo/comptime/inline/no_bounds_check/fast/unroll/section/hotpatch）+ parser.cr 的 `@ffi`——tokens.ebnf 只定义 `AT` 符号本身，无内建覆盖 |
| `documentSymbol` | 扫描 AST 顶层 `FUNC_DEF`/`STRUCT_DEF`/`ENUM_DEF` 节点（扁平 AST 自带 line/col）→ 树形大纲 |
| `semanticTokens` | 令牌流 → tokenType 映射（keyword/type/function/variable/comment/string）→ 差分编码（相对行/列/长度）。**tokenType 分类以实际 token kind 为准**，不以语言文档为准 |

**所有查询查"最后一次成功检查"的快照，查询本身不触发检查**
（检查只由 didChange/didOpen 驱动）——LSP 标准异步模型，hover 延迟稳定在个位数毫秒。

## 7. 错误处理

- JSON-RPC 错误码按规范：`-32700` 解析错误 / `-32601` 方法不存在 / `-32602` 参数无效
  （如 hover 缺 position）
- `initialize` 之前收到其他请求：回 `-32602` 并继续
- 服务器崩溃（编译器自身 bug）：v1 不设防——客户端自动重启 LSP 进程
  （VS Code/nvim 内置行为）。panic handler 是否接 stderr 日志放实现阶段定
- 文件读不到/解析失败：按编译器现有行为（`g_diags` 非致命）继续，不崩

## 8. 测试（三层）

| 层 | 载体 | 覆盖 |
|----|------|------|
| JSON 单元 | Python 驱动（tests/bootstrap/ 或 tests/suite/） | json.cr 解析/序列化往返、转义、嵌套、错误输入 |
| 重置回归 | 集成测试内嵌 | 连续两次检查，第二次故意改错，断言诊断更新（抓幽灵诊断） |
| LSP 集成 | `tests/selfhost/test_lsp.py` | Python 模拟客户端：spawn `build/corelsp`，按协议发 initialize → didOpen → hover/definition/completion/documentSymbol/semanticTokens，断言响应 JSON 字段 |

集成测试是标准做法（LSP 服务器都这么测），同时即协议级文档。

## 9. v1 明确不做（YAGNI）

- 增量同步（diff）
- 代码格式化
- rename / 重构
- workspace 级符号搜索
- 跨文件 goto-def 的精确类型解析（v1 符号表按名字查，同名符号可能跳错——TODO 注明，后补作用域精确化）
- UTF-16 列偏移（字节近似，TODO）

## 10. 里程碑

1. json.cr + JSON 单元测试
2. rpc.cr 帧循环 + 生命周期握手（initialize/shutdown/exit）
3. 静默检查管线 + `reset_frontend_state()` + diag file_id + publishDiagnostics
4. hover + go-to-definition
5. completion + documentSymbol
6. semanticTokens
7. 集成测试套件 + 构建脚本第三段（corelsp 二进制）
8. （后补）VS Code / nvim 客户端配置

## 11. 风险与 TODO 清单

- [ ] 全局重置遗漏 → 幽灵诊断（缓解：reset 集中管理 + 重置回归测试）
- [ ] 驻留表内存增长（接受，上限 ≈ 会话唯一字符串总量）
- [ ] 中文注释错误列偏移（UTF-16 转换后补）
- [ ] 同名符号跨文件跳转可能不准（作用域精确化后补）
- [ ] **仓库文档部分已过时**（CHANGELOG 止于 2026-06-21、DEBUG_REPORT 止于 2026-07-06、grammar/tokens.ebnf 关键字表与 lexer.cr 不符且无 @ 内建覆盖、pointer-model 等"当前状态"段与实现不符）——实现时以源码为准（关键字表唯一依据 `lexer.cr lookup_keyword()`；@ 内建名单唯一依据 `checker.cr` EXPR_AT 分发），文档仅作设计参考
