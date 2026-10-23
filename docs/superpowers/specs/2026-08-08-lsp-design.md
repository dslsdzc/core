# corelsp 设计

## 概述

Core 前端已经具备词法分析、语法分析和类型检查，诊断结构包含错误码、消息、行和列，类型检查错误是非致命的。

corelsp 是 Core 自举的 LSP 服务器，用 Core 语言实现，直接复用自举编译器的前端模块。第一版覆盖：

- 诊断
- hover
- 跳转定义
- 补全
- 文档符号
- 语义令牌

实现形态是独立 `corelsp` 二进制，与 `corearch` 同模式，不是 `corec` 的子命令。

设计状态：已批准。目录细节、重置清单、测试和风险见 `docs/superpowers/implementation/2026-08-08-lsp-audit.md`。

## 架构

```text
src/lsp/
    _import.cr    导入编译器前端模块
    json.cr       手写 JSON 解析器和序列化器
    rpc.cr        JSON-RPC 2.0 帧读写和方法分发
    lsp.cr        文档状态、检查管线、方法处理器
    analysis.cr   位置到符号查询
    main.cr       lsp_main 入口
```

构建脚本增加第三段 build 调用，复用现有 build 函数，产出 `build/corelsp`。

关键约束：

- stdout 是协议通道。检查管线使用不输出模式，依次调用 `tokenize`、`res_imports`、`parse_all` 和 `check_all`，不能复用带进度输出的 `run_frontend()`。日志写 stderr。
- 只运行前端，到 `check_all` 为止，不生成 IR。

## 生命周期和全局状态重置

进程内重跑检查是主要难点。

每轮检查前调用 `reset_frontend_state()`，集中清零：

- 令牌、AST、错误、诊断、块语句。
- 符号表：函数、结构体、枚举、符号、类型、接口、方法、类型别名、泛型约束和泛型参数。
- 检查器临时状态：作用域边界、借用状态、分配点等。
- 文件表和模块表。

不重置字符串驻留表。字符串跨检查存在，内容去重，内存收敛。

清除 count 但保留 cap，缓冲容量复用，避免每轮重新分配。`reset_frontend_state()` 集中管理，避免遗漏。

代价：bump allocator 不回收内存，字符串内容保留到进程退出。内存上限约等于会话内唯一字符串总量加上各缓冲峰值。数小时编辑会话为几十 MB，可以接受。

验证：连续两次检查，第二次故意改出错误，断言诊断被更新。这能检测重置遗漏导致的残留诊断。

## 诊断记录

诊断记录当前是 32 字节，包含错误码、消息指针、行和列，没有文件 ID。多文件项目的诊断无法按文件分发，因此增加 `file_id` 字段，记录扩展到 40 字节，与文件表配套。

`print_diagnostics()` 同步适配，现有输出格式不变。

## 协议层

### 帧循环

读：循环调用 `read(0, buf, 4096)`，解析 `Content-Length: N\r\n\r\n` 头，再读满 N 字节。

写：组装帧，用 `syscall3(1, 1, s, len)` 写出。

分发：方法名映射到处理器。

### 方法表

| 类别 | 方法 |
|---|---|
| 生命周期 | `initialize`、`initialized`、`shutdown`、`exit` |
| 文档 | `didOpen`、`didChange`、`didSave`、`didClose` |
| 查询 | `hover`、`definition`、`completion`、`documentSymbol`、`semanticTokens/full` |

### 文档状态

- `g_open_docs` 把路径映射到最新缓冲区内容。`textDocumentSync = 1`，第一版使用全量同步，不做增量 diff。
- `didChange` 同步重跑检查，约 100ms，在请求处理内完成，然后发布所有有诊断的文件。检查针对整个项目，编辑 A 文件可能影响导入它的 B 文件，全量发布最简单且正确。
- 打开文件的源文本从缓冲区取，不读磁盘。导入读取路径先查 `g_open_docs`，未打开才读磁盘。支持多文件同时编辑。
- 检查产物只保留诊断、符号表和令牌流。查询只使用这三者，不依赖 IR。

### 坐标转换

编译器行列从 1 开始，LSP 从 0 开始，输出时减 1。

列偏移第一版按字节近似。ASCII 精确，中文注释内的错误列会偏移。UTF-16 转换后续补。

## 查询

五个功能使用同一模式：根据位置查找令牌，再查询符号表。

| 功能 | 逻辑 |
|---|---|
| `hover` | 扫描令牌找光标处令牌，查询符号表，返回签名。函数返回参数类型和返回类型，变量返回类型，结构体返回字段列表 |
| `definition` | 查找令牌，再查符号声明记录，返回 URI 和区间，支持跨文件跳转。函数位置来自 AST 节点，结构体和枚举声明位置按名字反查 |
| `completion` | 扫描光标前的标识符前缀，过滤关键字表和当前可见符号，生成补全项。关键字表唯一来源是 `lexer.cr` 的 `lookup_keyword()`。`@` 后补全内建，名单唯一来源是 `checker.cr` 的 `EXPR_AT` 分发和 `parser.cr` 的 `@ffi` |
| `documentSymbol` | 扫描 AST 顶层函数、结构体和枚举节点，生成树形大纲 |
| `semanticTokens` | 令牌流映射到 tokenType，再做差分编码。分类以实际 token kind 为准，不以文档为准 |

所有查询读取最后一次成功检查的快照。查询本身不触发检查，检查只由 `didChange` 和 `didOpen` 驱动。hover 延迟在个位数毫秒。

## 错误处理

- JSON-RPC 错误码按规范：解析错误 `-32700`，方法不存在 `-32601`，参数无效 `-32602`。
- `initialize` 之前收到其他请求，回复 `-32602` 并继续。
- 服务器崩溃时，第一版不做额外处理，由客户端自动重启。
- 文件读不到或解析失败时，按编译器现有行为继续，`g_diags` 非致命，不崩溃。

## 测试

| 层 | 实现方式 | 覆盖 |
|---|---|---|
| JSON 单元 | Python 驱动 | 解析和序列化往返、转义、嵌套、错误输入 |
| 重置回归 | 集成测试 | 连续两次检查，第二次改错，断言诊断更新 |
| LSP 集成 | `tests/selfhost/test_lsp.py` | 模拟客户端，发送 initialize、didOpen 和五类查询，断言响应字段 |

集成测试同时兼作协议级文档。

## 第一版不做

- 增量同步。
- 代码格式化。
- rename 和重构。
- workspace 级符号搜索。
- 跨文件跳转的精确类型解析。第一版按名字查，同名符号可能跳错。
- UTF-16 列偏移。第一版按字节近似。

## 阶段

1. `json.cr` 和 JSON 单元测试。
2. `rpc.cr` 帧循环和生命周期握手。
3. 不输出检查管线、`reset_frontend_state()`、诊断 `file_id` 和诊断发布。
4. `hover` 和跳转定义。
5. `completion` 和文档符号。
6. 语义令牌。
7. 集成测试和构建脚本第三段。
8. VS Code 和 nvim 客户端配置。

## 风险

- 全局重置遗漏导致残留诊断。缓解是集中管理加重置回归测试。
- 驻留表内存增长。接受，上限约为会话唯一字符串总量。
- 中文注释错误列偏移。UTF-16 转换后补。
- 同名符号跨文件跳转可能不准。作用域精确化后补。
- 部分仓库文档过时。实现时以源码为准：关键字表唯一依据是 `lexer.cr`，`@` 内建名单唯一依据是 `checker.cr` 和 `parser.cr`。

## 关联

- 实施记录和风险：`docs/superpowers/implementation/2026-08-08-lsp-audit.md`
- 前端结构：`src/compiler/`
- 编辑器和 LSP 文档：`docs/developer/editors.md`
- 可解释接口：`docs/superpowers/specs/2026-09-11-explain-predict-incremental-design.md`
