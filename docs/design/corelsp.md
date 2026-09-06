# corelsp 架构（语言服务器设计）

> 定位：受众 = maintainers；状态 = active；真源 = [src/lsp/](../../src/lsp/) + [build_selfhost_native.py](../../build_selfhost_native.py)（corelsp 段）；实现与文档冲突时以源码为准。
> 用户接入（Neovim/VS Code/Zed 配置步骤）见 [language/editor-setup.md](../language/editor-setup.md)。
> 早期设计稿（历史，细节以源码为准）：2026-08-08 [lsp-design](../superpowers/specs/2026-08-08-lsp-design.md)、2026-08-28 [lsp-production-design](../superpowers/specs/2026-08-28-lsp-production-design.md)。

## 一、是什么

corelsp = 用 Core 自举编译器**前端子集**拼接出的语言服务器：LSP over stdio，rpc 循环收请求、按请求跑一次静默检查、回协议帧。与 corec 共享 lexer/parser/checker/diag/module/globals 等前端模块；**不含** corec 的 main.cr/entry.cr（corec_main 不参与 corelsp 构建）。

`src/lsp/` 文件职责：

| 文件 | 职责 |
|---|---|
| main.cr | 入口 `lsp_main`：`g_silent_stdout = 1`（import 进度等输出在协议通道静默）→ `rpc_loop()` |
| rpc.cr | LSP 帧读取/回写循环（`rpc_loop`） |
| json.cr | JSON 解析/序列化，字符串池复用（`g_json_strs` 每帧解析重置，跨帧引用须显式拷贝——见 lsp.cr `lsp_str_pool_copy`） |
| lsp.cr | 文档状态（`g_open_docs`）+ 静默检查管线 + `publishDiagnostics` + 语义查询快照比对（`g_lsp_snapshot_path` / `lsp_request_matches_snapshot`） |
| analysis.cr | 语义分析相关（具体职责见文件头注释） |
| _import.cr | 目录共享 import |

## 二、构建接线

`build_selfhost_native.py` 的「corelsp」段：前端依赖子集（lexer/parser/checker/diag/module/globals 及其依赖链）+ `src/lsp/` 六文件，按依赖序 concat 后包装为 `lsp_main`，产出 `build/corelsp`。拼接顺序约束（json → rpc → lsp 同翻译单元内可见）见 lsp.cr 头部注释；给 src/lsp/ 加新文件时需同步该 concat 列表。

## 三、检查管线与诊断通道

管线（lsp.cr 注释实录，改动前先读源码）：

- **禁止 `run_frontend()`**——它含 `println("[1/5]...")` 进度输出，会污染 stdout 协议通道。检查固定走 `lsp_check_file`。
- `lsp_check_file(path, src)`：`g_source` 置源文本 → `reset_frontend_state()` → tokenize → `res_imports` → parse_all →（parse 阶段有诊断则跳过 check_all，AST 可能不完整）→ check_all → publishDiagnostics。
- **publishDiagnostics**：主文件（`g_files[0]`，当前检查文档）无条件发布——无诊断也发空数组以清旧；其余有诊断的文件（file_id 去重）逐个发布。`file_id → 路径` 经 g_files 路径表，`uri = "file://" + path`。诊断字段：range 1-based → 0-based 减 1、severity=1、message 做 JSON 转义（含引号/反斜杠/控制符时保证合法 JSON）。

## 四、同步模型与能力契约

- **同步模式**：`textDocumentSync=1`（全量同步，无增量），单文档全局状态机——每次 `didOpen` 重新检查主文档；检查覆盖 import 链（res_imports/parse_all），链上文件有诊断也会发布。
- **语义查询 = 快照查询**：hover/definition 等基于「最后一次成功检查」的结果——请求 uri 与 `g_lsp_snapshot_path` 比对（`lsp_request_matches_snapshot`），文档有语法错误（本次检查失败）时返回空。取舍：不为查询阻塞重建，结果可能滞后一次检查。
- **能力通告**（initialize 响应）：诊断（publishDiagnostics）、hover、definition、completion（`triggerCharacters = ["@"]`——关键字 + 符号 + `@` 内建）、documentSymbol、semanticTokens/full（差分编码令牌流；跨行差分重建位置，deltaStartChar 非负）。

## 五、stdout 通道纪律

协议通道是 stdout——任何非协议字节都会使严格客户端（VS Code）断连（main.cr 注释）。corelsp 相关输出一律静默或改道，不得新增 println 类进度。

## 六、客户端接线现状

用户配置步骤见 [language/editor-setup.md](../language/editor-setup.md)，仓库内接线：

- **VS Code**：[editor/vscode-core/](../../editor/vscode-core/)（语法高亮 + 客户端；`corelsp.path`/`corelsp.enabled` 设置）
- **Zed**：扩展仓库 `dslsdzc/core-plugin-zed`（Rust wasm：`language_server_command` 返回命令路径——纯 TOML 无法指定命令，Zed 机制约束）；[.zed/settings.json](../../.zed/settings.json) 内置兜底配置（仅 LSP，无高亮）
- **Neovim**：内置 LSP 直连 stdio；旧 compiler 插件 [editor/nvim/plugin/core.lua](../../editor/nvim/plugin/core.lua)（基于 corec）功能重叠，启用 LSP 时移除

## 七、集成测试

[tests/selfhost/test_lsp.py](../../tests/selfhost/test_lsp.py)：八组场景按序执行——lifecycle、jsonrpc 错误码、diagnostics+reset、hover+definition、completion+documentSymbol、semanticTokens（含跨行差分）、stdout 污染守卫。**每组独立 spawn corelsp**（隔离全局状态——单文档全局状态机跨组复用会串状态）；结尾打印 `lsp suite: ALL PASS`，任一失败打印 FAIL 并非零退出。
