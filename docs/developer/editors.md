# 编辑器接入配置（corelsp）

> 定位：受众 = users/contributors；状态 = active；真源 = corelsp 行为见 [design/corelsp.md](docs/maintainer/design/corelsp.md)（实现与文档冲突时以源码为准）；仓库内编辑器素材见 [editor/](../../editor/)（扩展源码与说明）。
> 本文是纯用户向接入指南——各编辑器怎么接 corelsp；corelsp 的架构（检查管线/诊断通道/能力契约）见 [design/corelsp.md](docs/maintainer/design/corelsp.md)。

corelsp 是 Core 语言的语言服务器（标准 LSP 协议，stdio 管道）。接入后编辑器可获得：

| 功能 | 触发 | 说明 |
|------|------|------|
| 诊断 | 打开/编辑/保存时 | 错误信息 + 行内定位，自动发布 |
| 悬浮信息 | 悬停 | 标识符类型/签名 |
| 跳转定义 | F12 / gd | 函数/全局/类型声明位置 |
| 补全 | `@` 触发 | 关键字 + 符号 + `@` 内建 |
| 文档大纲 | 大纲面板 | 函数/结构体/枚举符号 |
| 语义着色 | 自动 | keyword/type/function/variable 等 |

行为要点：

- 每次打开/编辑文件都会触发一次重新检查（全量同步），诊断随之更新。
- 文档有语法错误时，悬停/跳转可能返回空——语义查询基于最近一次成功检查的结果。
- 前置条件：仓库根存在 `build/corelsp`。构建：`python3 build_selfhost_native.py`（与 build/corec、build/corearch 同批产出）。

## Neovim（内置 LSP，nvim 0.10+）

### 最简配置（需从项目根启动 nvim）

```lua
-- after/ftplugin/core.lua（或在 init.lua 中按文件类型 autocmd 调用）
vim.lsp.start({
  cmd = { 'build/corelsp' },
  name = 'corelsp',
})
```

### 健壮版（任意 cwd，自动定位项目根）

```lua
-- after/ftplugin/core.lua
-- 从当前文件目录向上查找包含 build/corelsp / Core.toml / .git 的项目根
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

- **诊断**：nvim 自动接收 `publishDiagnostics` 并显示（`vim.diagnostic`），无需额外配置。
- **补全**：`vim.lsp.buf.completion`（`<C-x><C-o>`），或 blink.cmp / nvim-cmp 等补全框架自动接入 LSP source。服务器补全为 `@` 触发。
- **语义着色**：nvim 0.10+ 语义令牌默认开启（不存在 `:SemanticTokensEnable` 命令，无需配置）；如需高亮，需 colorscheme 将 `@lsp.type.*` 链接到 `@keyword` 等高亮组。
- **与既有 compiler 插件互斥**：[editor/nvim/plugin/core.lua](../../editor/nvim/plugin/core.lua)（基于 `corec` 编译器的诊断/跳转）与 LSP 功能重叠——启用 LSP 时建议移除该插件，避免诊断与键位重复。
- 安装语法高亮/文件类型检测等基础配置见 [editor/README.md](../../editor/README.md)。

## VS Code

扩展位于 [editor/vscode-core/](../../editor/vscode-core/)（语法高亮 + corelsp 客户端）：

```bash
code --install-extension editor/vscode-core/
```

- 服务器路径默认取工作区根目录下 `build/corelsp`，可用设置 `corelsp.path` 覆盖（绝对路径或相对工作区根）。
- 设置 `corelsp.enabled = false` 可关闭 LSP（仅保留语法高亮）。
- 从源码调试：VS Code 打开 [editor/vscode-core/](../../editor/vscode-core/) 按 F5（见 `.vscode/tasks.json`）。

## Zed（2026-08-28 接入）

### 方式一：扩展（推荐，完整形态：语法高亮 + LSP）

扩展仓库 = **`dslsdzc/core-plugin-zed`**（本地开发路径 `~/core-plugin-zed`；core-language v0.3.0——Rust wasm 扩展：`language_server_command` 返回 corelsp 命令路径 + `extension.toml` `[lib]` 声明；语法 grammar 同源）：

1. Zed → Extensions（扩展）面板 → **Install Dev Extension（安装开发扩展）** → 选择 `~/core-plugin-zed`
2. 打开 `.cr` 文件：语法高亮 + 诊断 + 悬停 + F12 跳转 + `@` 补全 + 语义着色全部生效

扩展结构：`extension.toml`（`[lib]` + `language_servers` 段）、`src/lib.rs`（`language_server_command` → corelsp 绝对路径）、`languages/core/config.toml`（`language_servers = ["corelsp"]`）、`grammars/`（语法）。**命令路径在 Rust 代码里**（`~/core-plugin-zed/src/lib.rs`）——纯 TOML 无法指定，这是 Zed 扩展的机制约束。构建：`cargo build --release --target wasm32-wasip1` → `extension.wasm`。

### 方式二：settings.json（无扩展时的 LSP 兜底）

本仓库已内置项目配置（[.zed/settings.json](../../.zed/settings.json)，打开即用）——binary 相对路径以工作区根（仓库根）解析：

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

**其他项目/全局接入**：全局 `~/.config/zed/settings.json` 同上，`binary.path` 建议用 **绝对路径**（全局配置无工作区根可解析相对路径）。此方式只有 LSP，无语法高亮（高亮需扩展的 grammar）。

- 此方式可用能力：诊断、悬浮、跳转定义、补全（`@` 触发）、文档符号、语义令牌。
- Zed 默认键位：`F12` 跳转定义；悬停即看；LSP 诊断自动显示。
- 构建 corelsp：`python3 build_selfhost_native.py`（产出 `build/corelsp`）。

## 其他编辑器

其余编辑器（Emacs/LSP-mode、Helix 等）：corelsp 为标准 stdio LSP 服务器，参照各自
[自定义语言服务器](https://zed.dev/docs/languages) 配置模式接入（要点：绝对路径 + `.cr` 文件类型注册 + language_servers 挂载）。
