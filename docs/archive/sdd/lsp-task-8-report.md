# LSP Task 8 报告：VS Code / nvim 客户端配置

状态：完成。包含一处服务器 bug 修复，见“偏差与发现”。

## 提交

1. `sytvsoxm`：fix: corelsp semanticTokens 跨行差分编码。deltaLine 大于 0 时，deltaStartChar 应为绝对列。Task 8 客户端冒烟测试暴露了这个问题，补了多行回归用例。
2. `xzttpqxz`：lsp: VS Code / nvim 客户端配置（corelsp Task 8）。

## vscode-core 改动清单

实际目录是 `editor/vscode-core/`。brief 写的是 `vscode-core/`，该目录已在历史提交 e550fb1 中迁移到 `editor/` 下，CLAUDE.md 的目录说明已经过时。本次适配既有结构，没有重建架构。

| 文件 | 改动 | 说明 |
|------|------|------|
| `editor/vscode-core/package.json` | 修改 | 增加 `main: ./client/extension.js`、`activationEvents: ["onLanguage:core"]`、`contributes.configuration`（`corelsp.path` 默认 `build/corelsp`，另有 `corelsp.enabled`）。languages extensions 补 `.cr`，此前缺失，.cr 文件在 VS Code 中没有高亮，也不会触发 LSP。版本从 0.1.0 改为 0.2.0 |
| `editor/vscode-core/client/extension.js` | 新建 | 零依赖 LSP client，约 330 行：手写 JSON-RPC/stdio 帧编解码，spawn `build/corelsp`；生命周期握手；全量文档同步（textDocumentSync=1）；publishDiagnostics 到 DiagnosticCollection；hover/definition/completion/documentSymbol/semanticTokens 五个 provider；服务器路径解析，配置覆盖加工作区根后备；缺失或崩溃时给用户提示。刻意不引入 vscode-languageclient npm 依赖，保持 `code --install-extension` 即装即用，与既有零构建结构一致 |
| `editor/vscode-core/test/client_smoke.js` | 新建 | 无头端到端冒烟测试：mock vscode API 加载真实 extension.js，spawn 真实 build/corelsp，验证握手、didOpen、诊断、hover、semanticTokens、documentSymbol、completion 全链路。命令为 `node editor/vscode-core/test/client_smoke.js` |

client 代码适配服务器 v1 子集的几个特殊行为：请求 id 恒为递增数字，字符串 id 会被服务器当作通知；initialized 通知的 id:null 回帧经“按 id 匹配挂起请求”自然忽略；didChange 传全文，服务器只取 contentChanges[0].text。

## docs/editor-setup.md 内容要点

新建 `docs/editor-setup.md`，中文，与仓库文档惯例一致。

- 服务器能力表：诊断、悬浮、定义、补全（`@` 触发）、文档符号、语义令牌。限制说明：全量同步、快照式语义查询、单文档全局状态机。
- 构建：`python3 build_selfhost_native.py` 产出 build/corelsp。
- nvim（0.10 及以上）两版配置：最简版 `vim.lsp.start({cmd = {'build/corelsp'}})`，需要在项目根启动；健壮版用 `vim.fs.root(0, ...)` 在任意 cwd 定位项目根，并给出键位。诊断自动开启，补全接入 blink.cmp/nvim-cmp，语义着色需要 `@keyword` 高亮组。文档提示与既有 compiler 插件（editor/nvim/plugin/core.lua）互斥，功能重叠，启用 LSP 时建议移除。
- VS Code：安装命令，corelsp.path/enabled 配置，F5 调试入口。
- Zed：说明暂无 LSP 接入，给出 stdio 接入指引。

## 对 brief 的偏差与原因

1. 路径：`vscode-core/` 改为 `editor/vscode-core/`。目录已经迁移，brief 和 CLAUDE.md 的路径过时，改动落在实际目录。
2. 提交路径范围：brief 限定 `vscode-core/ docs/editor-setup.md`，实际还包含 `src/lsp/analysis.cr` 和 `tests/selfhost/test_lsp.py`，作为独立提交，理由见下。
3. 新增冒烟测试：brief 没有要求，作为任务验收和后续维护基准。client 配置必须证明能与真实服务器通信。

## 自审发现（重要）

服务器 bug，Task 6 遗留，已修复：`src/lsp/analysis.cr` 的 semanticTokens 差分编码在跨行令牌处输出负的 deltaStartChar。LSP 规范规定 deltaLine 大于 0 时，deltaStartChar 是绝对列。旧实现恒输出 `col0 - prev_col`，跨行时为负值，例如 `}` 在 (2,0) 输出 `2,-13`。VS Code 或任何严格客户端解码后会得到非法列，语义着色错乱。Task 6 测试只用了单行源码 `"fn main() -> int { return 42; }"`，没有覆盖跨行路径。修复：跨行时输出绝对列；补多行回归用例 `test_semantic_tokens_multiline`，注册进 TESTS 列表。修复后 `test_lsp.py` 8 组全部通过，`client_smoke.js` 全部通过。

自检：

- package.json 经 python json 校验，通过。
- extension.js / client_smoke.js 经 `node --check`，通过。
- 端到端 `node editor/vscode-core/test/client_smoke.js`：握手、诊断（空和错误）、hover、semanticTokens（含首令牌位置断言）、documentSymbol、completion 全部通过。
- `python3 tests/selfhost/test_lsp.py`：8 组 ALL PASS。
- corelsp 经 `nice -n 19` 限 CPU 重建。构建警告是既有非致命 checker 警告，与 Task 1-7 相同。

已知边界，文档已注明：server 语义查询基于最后一次成功检查的快照，语法错误时悬停或跳转可能为空。VS Code 端的 semanticTokens legend 与服务器 8 个类型的顺序严格对应，关键字名都属于 VS Code 标准 tokenTypes。

## Fix 2：终审修复补提交（kind 规范值、客户端平移、文档和 EPIPE 修正）

提交：`vsuxqmyx` / `3e67172c`，信息为 `lsp: 终审修复——kind 规范值+客户端平移+文档/EPIPE 修正`。路径限定：src/lsp/analysis.cr、editor/vscode-core/client/extension.js、docs/editor-setup.md、tests/selfhost/test_lsp.py。

### 1. kind 数值（服务器按 LSP 规范，Task 5 brief 的数字有误，实现照抄）

| 位置 | 修正前 | 修正后（LSP 规范值） |
|------|--------|----------------------|
| completion g_syms SYM_TYPE（analysis_sym_item_kind） | 23（Event） | 22（Struct） |
| completion g_syms 中的枚举项（新加 find_enum 名字区分） | 23（走 SYM_TYPE 路径） | 13（Enum） |
| completion g_structs 表 | 23 | 22 |
| completion g_enums 表 | 23 | 13 |
| documentSymbol 枚举（SymbolKind） | 23 | 10（Enum） |

已验证常量不变：completion Keyword=14、Function=3、Variable=6；documentSymbol Function=12、Struct=23。

关键发现，属于实现细节，brief 没有预料到：`collect_decls`（checker.cr）把结构体、枚举、接口统一注册为 SYM_TYPE。候选缓冲按 g_syms、g_funcs、g_structs、g_enums 的顺序追加，并按名字去重。g_enums 表的 kind 对枚举恒被 g_syms 的 SYM_TYPE 项遮蔽。只改 g_enums 循环无效，必须在 g_syms 循环内用 `find_enum(sym_name(i))` 区分枚举，发 13，否则枚举项仍然是 22。修复后枚举变体（Red/Green/Blue）保持 kind=3。变体构造器注册为函数，LSP 语义上属于 EnumMember=20，超出 brief 范围，未改动。

### 2. 客户端平移（VS Code 枚举从 0 开始）

extension.js 两处回填改为 `kind - 1`，并加注释说明。completion 在 provideCompletionItems 中，`vscode.CompletionItemKind[k]` 越界时后备 Text；documentSymbol 在 provideDocumentSymbols 中，kind 越界时后备 SymbolKind.Variable。

### 3. docs/editor-setup.md

删除不存在的命令 `:SemanticTokensEnable` 及括注，改为“nvim 0.10 及以上语义令牌默认开启；如需高亮，需要 colorscheme 把 `@lsp.type.*` 链接到 `@keyword` 等高亮组”。

### 4. extension.js EPIPE 竞态

RpcConnection 构造器新增 `child.stdin.on('error', ...)`。服务器死亡瞬间，在途请求的 write 会触发 EPIPE。Node 对没有监听器的 'error' 事件会抛未捕获异常，击穿 extension host。EPIPE 被吞掉并置 closed，后续请求快速失败，返回“corelsp 未运行”。其他 stdin 错误经 console.error 后也按已关闭处理。

### 5. 测试同步

test_lsp.py 的 test_completion_and_document_symbol 断言同步为规范值：completion Point=22/Color=13；documentSymbol Point=23/Color=10。并加注释说明。

### 验证证据

- 构建：`nice -n 19 python3 build_selfhost_native.py` BUILD SUCCESS（corec/corearch/corelsp；警告为既有非致命 checker 警告）。
- `python3 tests/selfhost/test_lsp.py`：8 组 ALL PASS，exit 0。
- `nice -n 19 node editor/vscode-core/test/client_smoke.js`：全部通过，exit 0。
- `node --check editor/vscode-core/client/extension.js`：语法通过。
- kind 实测，使用 live corelsp 和临时脚本：completion `fn=14 add=3 Point=22 Color=13`；documentSymbol `add=12 Point=23 Color=10 main=12`。客户端平移后，VS Code 侧 struct 从 22 变为 21，completion enum 从 13 变为 12，documentSymbol enum 从 10 变为 9。节点脚本对照 VS Code 枚举表确认 21=Struct、12=Enum、9=Enum。

## Fix 3：终审顺手修补提交（测试注释、污染扫描限定帧间、mock 值校正和平移断言、read 超时）

提交：`twpxsvkv` / `f1ae458e`，信息为 `lsp: 终审顺手修——测试注释/污染扫描限定帧间/mock 值校正+平移断言/read 超时`。路径限定：tests/selfhost/test_lsp.py、editor/vscode-core/test/client_smoke.js。工作副本在 develop 21ab36e4 之上，没有其他改动卷入。

### 1. test_lsp.py 头注释组数错位

头部注释写“七组”并枚举 7 项，实际是 8 组，缺 Task 8 补的多行 semanticTokens 组。更新为“八组测试按序执行”，并在 6 和 7 之间补 `6b. semanticTokens 多行 — 跨行差分重建位置 + deltaStartChar 非负`。

### 2. 污染标记扫描限定帧间空隙

原实现把污染标记（`b"->"`、`b"!! import fail"`、`b"warning:"`）扫描包含帧体的全字节流，会对诊断消息文本过敏。诊断如果含 `->` 会误报。改为：严格帧扫描（逐字节帧校验）保留，并顺带记录 body 字节范围；污染标记只扫描 body 之外的帧间空隙，即头之前、帧尾之后、帧头本身的字节。附注释说明诊断文本可以合法包含 `->`，因此不能扫描全流。

### 3. client_smoke.js mock 值校正和平移断言

mock 枚举此前误用 LSP 的 1-based 值，VS Code API 是 0-based。修正为 CompletionItemKind Function 3 改为 2、Keyword 14 改为 13、Variable 6 改为 5、Struct 22 改为 21、Enum 23 改为 12；SymbolKind.Variable 13 改为 12。并加注释说明。另补第 7 步真实平移断言：打开含 `struct Point` 的文档，经真实 corelsp 响应验证服务器 completion 返回 Struct=22（LSP），客户端 `kind - 1` 平移后为 21（VS Code CompletionItemKind.Struct）。

实现中发现并修正了 mock 保真度问题。首版断言失败，Point 的 kind 实际为 0，走了 Text 后备。extension.js 的后备判断 `vscode.CompletionItemKind[k] !== undefined` 依赖 TS 数值枚举的反向映射（Enum[value]=name），而原来的 plain-object mock 没有反向映射，`CompletionItemKind[21]` 为 undefined，触发 Text 后备。修复：mock 枚举改由 `numEnum()` 构造双向映射，与真实 VS Code 枚举一致。平移逻辑本身正确，问题只在 mock 失真。

### 4. 污染守卫 read 无超时

第七组 `proc.stdout.read()` 没有超时，服务器挂起时套件会挂起。改为 `select.select([proc.stdout], [], [], 5)` 循环检查可读性：5 秒无数据则 `proc.kill()` 并断言失败，以非零退出；可读时才 `read1()` 分块读取至 EOF。

### 验证证据

- `python3 tests/selfhost/test_lsp.py`：8 组 ALL PASS，exit 0；污染守卫 5 frames / 0 dirty bytes / 891 bytes。
- `nice -n 19 node editor/vscode-core/test/client_smoke.js`：全部通过，含平移断言，exit 0。
- `node --check editor/vscode-core/test/client_smoke.js`：语法通过。
- 二进制未重建。test_lsp.py 和 client_smoke.js 的改动只影响测试脚本。build/corelsp 已包含终审修复 3e67172c 的内容，develop 21ab36e4 已包含；套件断言（Point=22/Color=13 等）通过，即证明二进制是修复后的版本。
