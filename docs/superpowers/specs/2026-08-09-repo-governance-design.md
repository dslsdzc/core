# 仓库治理与分支保护

## 概述

Core 的开发流程按最终形态制定规则，执行按当前规模放宽。治理模型参考 Rust 和 Linux：`main` 是正式版线，任何人包括维护者都不能直接推送。所有改动通过 PR、审查和合入要求进入 `main`。

当前角色：

| 角色 | 人 | 权限 |
|---|---|---|
| 维护者 | DslsDZC | 唯一写权限 |
| 贡献者 | RhineIris | fork 加 PR，无写权限 |

仓库使用 jj colocated，`.git` 存在，git 命令物理可用，但流程只使用 jj。

设计状态：设计已批准。CI 和本地配置已实施，部分 ruleset 规则延期。实施偏差和当前状态见 `docs/superpowers/implementation/2026-08-09-repo-governance-audit.md`。

## 治理模型

- `main` 是正式版线，只放正式版内容，对应 semver 发布。
- `develop` 是集成分支，日常 PR 的目标。
- feature 到 `develop` 走 PR，经过审查、CI 和合入要求。
- `develop` 到 `main` 只有维护者可以执行。
- 维护者自己的改动也走 PR。由于 GitHub 不允许作者批准自己的 PR，维护者自己的 PR 使用临时豁免流程。
- 硬性规则由 hook 执行。`CLAUDE.md` 禁止 `git`，全部使用 `jj`，由 hook 拦截。

机制限制：GitHub 没有原生开关禁止以 `main` 为 base 创建 PR。规则组合和 `CONTRIBUTING` 约定共同实现：PR 一律指向 `develop`，指向 `main` 的 PR 没有维护者批准就无法合入。

## main ruleset

| # | 规则 | 配置 |
|---|---|---|
| M1 | 推送限定 | 仅 DslsDZC 可以推送或合入 |
| M2 | 禁止强推 | Block force pushes |
| M3 | 禁止删除分支 | Block deletions |
| M4 | 合入要求 | 必须走 PR，required reviewers 仅 DslsDZC，至少 1 个批准 |
| M5 | 强制签名提交 | Require signed commits，使用 SSH 签名 |
| M6 | 管理员无绕过 | 规则对管理员同样生效 |
| M7 | 保护标签 | `release/*` 标签禁止强推和删除 |

## develop ruleset

| # | 规则 | 配置 |
|---|---|---|
| D1 | 禁止直推 | 必须走 PR |
| D2 | 禁止强推 | Block force pushes |
| D3 | 强制审阶段 | 1 个批准，required reviewers 仅 DslsDZC |
| D4 | 过时审阶段作废 | 新提交推送后作废旧批准 |
| D5 | 对话必须解决 | 合入前解决全部对话 |
| D6 | 合并前更新分支 | 分支必须是最新的 |
| D7 | 核心路径限制 | `src/compiler/` 和 `src/arch/` 的变更需要审阶段 |
| D8 | merge queue | 要求合并队列，入口是审阶段通过且 PR CI 通过 |
| D9 | 合并策略 | 只允许 squash merge，自动删除源分支 |
| D10 | 状态检查 | PR 层 CI job：check、bootstrap-tests、selfhost-tests |
| D11 | 管理员无绕过 | 规则对管理员同样生效 |

## 机制限制

- GitHub 没有原生开关禁止以 `main` 为 base 创建 PR。`M4` 使指向 `main` 的 PR 无法由维护者以外的人合入。
- 两个 ruleset 原计划先用 evaluate 模式试运行。免费计划不支持 evaluate，规则直接 active。
- `merge_queue` 规则在免费计划被 API 拒绝，降级为手动合入。审阶段和 CI 状态检查保留，自动串行合入由人工点击替代。
- GitHub 禁止作者批准自己的 PR。维护者自己的 PR 合入时，临时禁用对应 ruleset，squash 合并，然后恢复。
- 贡献者的审阶段要计入 required approvals，需要 write 权限。fork 贡献者的审阶段不满足要求。
- `M7` 标签保护和 `D7` 路径限制暂缓，列入后续项。

## CI

CI 参照 rust-lang/rust 模板：

```text
.github/workflows/ci.yml
src/ci/run.sh
src/ci/shared.sh
src/ci/scripts/run-build-from-ci.sh
src/ci/scripts/setup-environment.sh
```

双层触发：

- `pull_request`：快速层，运行 check、bootstrap-tests 和 selfhost-tests。
- `merge_group`：完整层，运行 suite 和 full-bootstrap。

PR 层 job 在 merge 下也运行。

已知风险：

- `full-bootstrap` 涉及自举 tokenizer 死循环和 1GiB bump heap 峰值，完整层按 TODO 逐个启用。
- `opt-regress` 是 O0 和 O1 回归，预留位置。

## 本地配置

| 项 | 配置 | 效果 |
|---|---|---|
| jj bookmark 保护 | `bookmarks.main.protect true` | `main` 不被 rebase 或 rewrite 意外移动 |
| jj 提交签名 | SSH 后端，签名密钥，全部新提交签名 | 满足 M5 |
| git 拦截 hook | `.claude/settings.json` 的 PreToolUse | 以 `git` 开头的命令被拒绝 |
| 权限清理 | 移除 `Bash(git *)` 允许项 | 权限模型和 hook 一致 |
| `CLAUDE.md` | 版本控制流程段 | 文档和机制一致 |

## 工作流

feature 到 `develop`：

```text
jj bookmark create feature/xxx
...开发提交，自动签名...
jj git push -b feature/xxx
gh pr create --base develop --fill
审查，维护者批准
手动 squash 合入 develop，自动删除源分支
jj git fetch && jj bookmark move develop -r develop@origin
```

`develop` 到 `main`：

```text
jj git push -b develop
gh pr create --base main --fill
维护者批准
手动 squash 合入 main
```

维护者自己的 PR 使用临时豁免：禁用 ruleset，squash 合并，恢复 ruleset。

## 验证清单

- 直推 `main` 被拒绝，推 feature 分支成功。
- 指向 `main` 的非维护者 PR 无法被批准合入。
- `develop` 到 `main` 只有维护者成功。
- 维护者自有 feature PR 通过临时豁免合入。
- 贡献者 fork PR 以 `develop` 为 base，维护者批准后合入。
- 未签名提交的 PR 被拒绝，jj 日志可见签名。
- 管理员直推 `main` 同样被拒绝。
- `git` 命令被 hook 拦截，`jj` 正常。
- jj main protect 生效。
- PR 层 CI 通过，完整层按实际状态标记。

## 社区文件

| 文件 | 内容 |
|---|---|
| `.github/pull_request_template.md` | 变更描述、测试、语义保留影响、已知限制 |
| `.github/CONTRIBUTING.md` | fork、PR、审查、queue 流程、禁用 git、构建测试命令、编码约定 |
| `.github/SECURITY.md` | 漏洞报告路径和响应承诺 |
| `.github/CODE_OF_CONDUCT.md` | 贡献者行为规范 |

## 发布

- 版本号使用 semver，即 `MAJOR.MINOR.PATCH`。
- 标签是 `release/vMAJOR.MINOR.PATCH`，对应 `release/*` 保护规则。
- 维护者从 `main` 打标签，标签保护防止强推和删除。
- changelog 按需维护。

## 后续项

- Issue 模板和标签体系，贡献者规模扩大后补。
- Dependabot 不做，仓库零外部依赖。
- CI 优化：缓存 `build/corec`，启用 `full-bootstrap`，启用 `opt-regress`。
- 部署环境前提在没有发布流水线前不做。

## 当前状态

- CI 基础结构已实现，本地验证通过。
- 社区文件已写。
- 本地配置已实施：jj protect、jj 签名、hook、权限清理和 `CLAUDE.md`。
- `develop` 集成分支已创建。

## 关联

- 实施偏差和当前状态：`docs/superpowers/implementation/2026-08-09-repo-governance-audit.md`
- 贡献指南：`.github/CONTRIBUTING.md`
- 本地 hook：`.claude/settings.json`
