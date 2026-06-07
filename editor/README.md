# Core Language IDE Support

## Neovim

所有文件安装到 `~/.config/nvim/`：

```bash
# 一键安装
cp -r editor/nvim/syntax/*.vim    ~/.config/nvim/syntax/
cp -r editor/nvim/ftdetect/*.vim  ~/.config/nvim/ftdetect/
cp -r editor/nvim/ftplugin/*.vim  ~/.config/nvim/ftplugin/
cp -r editor/nvim/compiler/*.vim  ~/.config/nvim/compiler/
cp -r editor/nvim/snippets/*.json ~/.config/nvim/snippets/
cp -r editor/nvim/plugin/*.lua    ~/.config/nvim/lua/plugins/
```

### 功能一览

| 功能 | 触发方式 | 说明 |
|------|----------|------|
| 语法高亮 | 自动 | `.cr`/`.cir`/`.ccr` 文件 |
| 代码补全 | 自动 | blink.cmp 关键字 + types |
| 代码片段 | `fn⭾` `struct⭾` 等 | 共 20+ 片段 |
| 诊断 | 保存时自动 | 编译器错误显示在行内 |
| Quickfix | `:make` | 编译结果 + 错误列表 |
| 悬浮信息 | `K` | 查看标识符定义 |
| 跳转定义 | `gd` | 跳转到声明位置 |
| 错误导航 | `]e` / `[e` | 上/下一个错误 |
| 类型检查 | `:CoreCheck` | 仅类型检查 |
| 运行文件 | `:CoreRun` | 编译 + 执行 |

### 错误诊断格式

编译器输出 `error CODE: MSG` → `--> LINE:COL` 会被自动解析为：

## VS Code

扩展位于 `editor/vscode-core/`，安装方式：

```bash
code --install-extension editor/vscode-core/
```

或从 VS Code 插件市场搜索 "core-lang"。

## 项目仓库

所有 IDE 配置文件放在 `editor/` 目录下，按编辑器分目录：

```
editor/
├── nvim/          # Neovim 支持
│   ├── syntax/    # 语法高亮
│   ├── ftdetect/  # 文件类型检测
│   ├── ftplugin/  # 文件类型设置
│   ├── compiler/  # 编译器集成
│   ├── snippets/  # 代码片段
│   └── plugin/    # IDE 插件 (Lua)
├── vscode-core/   # VS Code 扩展
│   └── .vscode/   # 构建/调试任务
└── corecheck      # 语法检查脚本 (vim/nvim)
```
