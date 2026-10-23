# 编辑器接入配置（corelsp）

> 定位：受众 = 开发者；状态 = active；corelsp 行为以 [maintainer/design/corelsp.md](../maintainer/design/corelsp.md) 为准（实现与文档冲突时以源码为准）；仓库内编辑器素材见 [editor/](../../editor/)（扩展源码与说明）。
> 本文是面向用户的接入指南，说明各编辑器接入 corelsp 的步骤。corelsp 的架构（检查管线、诊断通道、能力契约）见 [maintainer/design/corelsp.md](../maintainer/design/corelsp.md)。

corelsp 是 Core 语言的语言服务器，使用标准 LSP 协议，通过 stdio 管道通信。接入后编辑器提供以下功能：

| 功能 | 触发 | 说明 |
|------|------|------|
| 诊断 | 打开/编辑/保存时 | 错误信息与行内定位，自动发布 |
| 悬浮信息 | 悬停 | 标识符类型/签名 |
| 跳转定义 | F12 / gd | 函数/全局/类型声明位置 |
| 补全 | `@` 触发 | 关键字、符号和 `@` 内建 |
| 文档大纲 | 大纲面板 | 函数、结构体和枚举符号 |
| 语义着色 | 自动 | keyword、type、function、variable 等 |

行为要点：

- 每次打开或编辑文件都会触发一次重新检查（全量同步），诊断也随之更新。
- 文档有语法错误时，悬停和跳转可能返回空结果，因为语义查询使用最近一次成功检查的结果。
- 前置条件：仓库根存在 `build/corelsp`。构建命令：`python3 build_selfhost_native.py`（与 build/corec、build/corearch 同批产出）。

## Neovim（内置 LSP，nvim 0.10+）

### 最简配置（需从项目根启动 nvim）

```lua
-- after/ftplugin/core.lua（或在 init.lua 中按文件类型 autocmd 调用）
vim.lsp.start({
  cmd = { 'build/corelsp' },
  name = 'corelsp',
})
```

### 通用配置（任意 cwd，自动定位项目根）

```lua
-- after/ftplugin/core.lua
-- 从当前文件目录向上查找包含 build/corelsp、Core.toml 或 .git 的项目根
local root = vim.fs.root(0, { 'build/corelsp', 'Core.toml', '.git' })
if not root then return end

vim.lsp.start({
  cmd = { root .. '/build/corelsp' },
  name = 'corelsp',
})

-- 常用键位（nvim 内置 LSP 默认键位按需自设）
vim.keymap.set('n', 'K', vim.lsp.buf.hover, { buffer = 0 })
vim.keymap.set('n', 'gd', vim.lsp.buf.definition, { buffer = 0 })
```

### 说明

- 诊断：nvim 自动接收 `publishDiagnostics` 并显示（`vim.diagnostic`），无需额外配置。
- 补全：使用 `vim.lsp.buf.completion`（`<C-x><C-o>`），或由 blink.cmp、nvim-cmp 等补全框架自动接入 LSP source。服务器的补全由 `@` 触发。
- 语义着色：nvim 0.10+ 默认开启语义令牌，不存在 `:SemanticTokensEnable` 命令，不需要配置。如需高亮，需要 colorscheme 将 `@lsp.type.*` 映射到 `@keyword` 等高亮组。
- 与现有 compiler 插件互斥：[editor/nvim/plugin/core.lua](../../editor/nvim/plugin/core.lua)（使用 `corec` 编译器的诊断和跳转）与 LSP 功能重叠。启用 LSP 时建议移除该插件，避免诊断和键位重复。
- 语法高亮、文件类型检测等基础配置的安装见 [editor/README.md](../../editor/README.md)。

## VS Code

扩展位于 [editor/vscode-core/](../../editor/vscode-core/)（语法高亮和 corelsp 客户端）：

```bash
code --install-extension editor/vscode-core/
```

- 服务器路径默认使用工作区根目录下的 `build/corelsp`，可以用设置 `corelsp.path` 覆盖（绝对路径或相对工作区根）。
- 设置 `corelsp.enabled = false` 可以关闭 LSP，只保留语法高亮。
- 从源码调试：在 VS Code 中打开 [editor/vscode-core/](../../editor/vscode-core/) 并按 F5（见 `.vscode/tasks.json`）。

## Zed（2026-08-28 接入）

### 方式一：扩展（推荐，包含语法高亮和 LSP）

扩展仓库为 `dslsdzc/core-plugin-zed`（本地开发路径 `~/core-plugin-zed`；core-language v0.3.0，Rust wasm 扩展：`language_server_command` 返回 corelsp 命令路径，`extension.toml` 中有 `[lib]` 声明；语法 grammar 同源）：

1. 在 Zed 中打开 Extensions（扩展）面板，选择 Install Dev Extension（安装开发扩展），然后选择 `~/core-plugin-zed`
2. 打开 `.cr` 文件后，语法高亮、诊断、悬停、F12 跳转、`@` 补全和语义着色全部生效

扩展结构：`extension.toml`（`[lib]` 和 `language_servers` 段）、`src/lib.rs`（`language_server_command` 返回 corelsp 的绝对路径）、`languages/core/config.toml`（`language_servers = ["corelsp"]`）、`grammars/`（语法）。命令路径位于 Rust 代码中（`~/core-plugin-zed/src/lib.rs`），纯 TOML 无法指定，这是 Zed 扩展的机制约束。构建命令为 `cargo build --release --target wasm32-wasip1`，产物是 `extension.wasm`。

### 方式二：settings.json（没有扩展时只使用 LSP）

本仓库已内置项目配置（[.zed/settings.json](../../.zed/settings.json)，打开即可使用）。binary 的相对路径以工作区根（仓库根）为基准解析：

```json
{
  "lsp": {
    "corelsp": {
      "binary": { "path": "build/corelsp" }
    }
  },
  "languages": {
    "Core": {
      "language_servers": ["corelsp"],
      "file_types": ["cr"]
    }
  }
}
```

其他项目和全局接入：全局 `~/.config/zed/settings.json` 的写法与上面相同，`binary.path` 建议使用绝对路径，因为全局配置没有工作区根，无法解析相对路径。此方式只提供 LSP，没有语法高亮，高亮需要扩展提供的 grammar。

- 此方式可用的功能：诊断、悬浮、跳转定义、补全（`@` 触发）、文档符号、语义令牌。
- Zed 默认键位：`F12` 跳转定义，悬停显示信息，LSP 诊断自动显示。
- 构建 corelsp：`python3 build_selfhost_native.py`（产出 `build/corelsp`）。

## 其他编辑器

其他编辑器（Emacs/LSP-mode、Helix 等）：corelsp 是标准的 stdio LSP 服务器，可以参照各自的
[自定义语言服务器](https://zed.dev/docs/languages) 配置方式接入。要点是使用绝对路径、注册 `.cr` 文件类型，并配置 language_servers。
