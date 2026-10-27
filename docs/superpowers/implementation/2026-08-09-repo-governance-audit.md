# 仓库治理：实施偏差与当前状态

> 对应设计：[2026-08-09-repo-governance-design.md](../specs/2026-08-09-repo-governance-design.md)

本文保存 ruleset 实施偏差、免费计划限制、逐项验证和当前状态。设计正文只保留治理模型、规则清单、CI、本地配置和工作流。

# 仓库治理与分支保护设计

日期：2026-08-09
状态：设计已批准（brainstorming 会话，分节确认）；CI 部分已实现，其余待实施

## 概述

Core 的愿景是成为严肃系统语言（语义保留、内核路线、形式验证）。开发流程按最终形态制定规则，执行按现状规模放宽。治理模型参考 Rust/Linux：`main` 就是 mainline，任何人（包括维护者）不得直接推送，全部改动经 PR、审查和合入要求进入 `main`。

| 事实 | 值 |
|---|---|
| 维护者（唯一写权限） | DslsDZC（你） |
| 贡献者 | RhineIris，fork + PR 模式，无写权限，feature 分支在其 fork 上 |
| 仓库形态 | jj colocated（.git 存在，git 命令物理可用） |
| 合并历史 | 直推 main 为主，偶发 PR 合并 |

## 治理模型

- GitFlow 标准：`main` 是正式版线（仅正式版内容，对应 semver 发布）；`develop` 是集成分支（日常 PR 目标）；feature 到 develop 走 PR（审查 + CI + merge queue）；develop 到 main 的合入只有维护者（DslsDZC）能做（GitFlow 的发布负责人语义）
- 非对称：实际审查只有一项，你审查 RhineIris 的 PR，反向没有审查。你自己的改动也走 PR，合入使用 B 流程（临时豁免，见「机制限制与过渡」）
- 结构按最终形态，执行按现状：规则按最终形态全部制定（将来贡献者增多时自动生效），执行上优先遵循互审约定。2026-08-09 实测修正：GitHub 原生禁止作者批准自己的 PR，「自阶段作为后备」不成立，维护者自己的 PR 合入使用 B 流程临时豁免，见「机制限制与过渡」
- 机制限制（如实记录）：GitHub 没有原生开关禁止以 main 为 base 创建 PR。「PR 不能指向 main」由 main 规则组合强制（restrict pushes 仅 DslsDZC + required reviewers 仅 DslsDZC，指向 main 的 PR 没有维护者批准就无法合入），再加上 CONTRIBUTING 约定（PR 一律指向 develop）实现
- 硬性规则由 hook 强制执行：`CLAUDE.md` 第 2 条（禁止 `git`，全部使用 `jj`）由 hook 拦截

## GitHub 侧的 ruleset 最终清单（`main` 和 `develop` 两个 ruleset）

### `main` ruleset（目标：`main`）：维护者独占

| # | 规则 | 配置 |
|---|---|---|
| M1 | 推送限定 | Restrict pushes：仅 DslsDZC。实际只有维护者能向 main 推送或合入（develop 到 main 的合并只能由你执行） |
| M2 | 禁强推 | Block force pushes |
| M3 | 禁删分支 | Block deletions |
| M4 | 合入要求 | Require a pull request before merging + required reviewers 仅 DslsDZC + ≥1 approval。任何指向 main 的 PR（包括 RhineIris 和未来协作者）没有维护者批准就无法合入 |
| M5 | 强制签名提交 | Require signed commits（SSH 签名；GitHub 合并产生的 squash 提交自带 GitHub 签名，自动通过） |
| M6 | 管理员无绕过 | 规则对仓库管理员同样生效（关闭 admin bypass，否则 M1 无法生效） |
| M7 | Protected tags | `release/*` 标签禁强推、禁删除 |

### `develop` ruleset（目标：`develop` 集成分支）：日常开发入口

| # | 规则 | 配置 |
|---|---|---|
| D1 | 禁直推 | Require a pull request before merging（PR 是唯一合入通道） |
| D2 | 禁强推 | Block force pushes |
| D3 | 强制审阶段 | Require 1 approval + required reviewers 仅 DslsDZC（合入 develop 也需要维护者批准，队列自动执行合并） |
| D4 | 过时审阶段作废 | Dismiss stale pull request approvals when new commits are pushed |
| D5 | 对话必须解决 | Require conversation resolution before merging |
| D6 | 合并前必须更新分支 | Require branches to be up to date（merge queue 下由队列保证，两项要求共同生效） |
| D7 | 文件路径限制 | 核心路径 `src/compiler/`、`src/arch/` 下的文件变更需审阶段（额外的防护检查） |
| D8 | merge queue | Require merge queue（对应 bors）；入口条件是审阶段通过且 PR 层 CI 通过 |
| D9 | 合并策略 | Allow squash merges only + 自动删除已合并源分支 |
| D10 | 状态检查 | PR 层 CI job 名（check / bootstrap-tests / selfhost-tests），CI 已实现（见 CI 一节），配置时直接填入 |
| D11 | 管理员无绕过 | 规则对仓库管理员同样生效 |

### 机制限制与过渡

- GitHub 没有原生开关禁止以 main 为 base 创建 PR。`M4`（`required reviewers` 仅 DslsDZC）使指向 `main` 的 PR 无法由维护者以外的人合入。「PR 不能指向 `main`」由规则组合和 `CONTRIBUTING` 约定（PR 一律指向 `develop`）实现
- 实施过渡：两个 ruleset 先以 evaluate（试运行）模式启用，观察确认无干扰后转为 active
- 2026-08-09 实施偏差（免费计划限制，已实测）：
  - `enforcement: evaluate` 仅 Enterprise 可用。免费计划已直接以 active 创建，没有试运行期，规则立即生效
  - `merge_queue` 规则被 API 拒绝（"Invalid rule 'merge_queue'" 空原因），降级为手动合入：审阶段和 CI 状态检查要求保留，D1/D3/D8 的自动串行合入部分由人工点击合入替代
  - `pull_request` 参数 schema 实测：5 个必填布尔（含 `require_code_owner_review`）、`allowed_merge_methods: ["squash"]` 强制 squash-only
  - `required_status_checks` 参数数组字段名是 `required_status_checks`（非 `checks`）
  - 2026-08-09 实测（流程验证）：
    - GitHub 原生禁止作者批准自己的 PR（"Can not approve your own pull request"），「自阶段作为后备」的前提不成立；管理员强制合并也会被 bypass_actors 空集拦截
    - B 流程（既定路径）：维护者自己的 PR 合入时，临时禁用对应 ruleset，squash 合并，然后恢复 active（PR #26 首次执行，2026-08-09）
    - RhineIris 的审阶段要计入 required approvals，需要 write 权限（fork 贡献者的审阶段不满足要求），待决策是否授予 collaborator
    - CI 工作流注册冻结持续（GitHub 侧，注册表包含已删文件、缺少新文件），`develop` 的 `required_status_checks` 暂时移除，注册恢复后回填
  - M7（release/* 标签保护）与 D7（文件路径限制）未实施：脚本和已建 ruleset 都没有包含（免费计划可用但暂缓），列入后续项

## GitHub 侧的实施方式

- 路径 A（gh 恢复后）：运行 `tools/gh_setup_ruleset.sh`，使用 `gh api` 按上述清单创建 ruleset（脚本内嵌规则 JSON）
- 路径 B（现在可用）：在网页版 Settings 的 Rules 和 Rulesets 页面，按「GitHub 侧的 ruleset 最终清单」逐项配置
- 前置条件：SSH 签名密钥（`~/.ssh/id_ed25519.pub`）在 GitHub Settings 的 SSH keys 注册为 Signing key（仅注册为认证 key 会导致签名校验失败）

## CI（已实现，2026-08-09）

参照 rust-lang/rust 模板（`~/rust`）重写，已在本地验证：

```
.github/workflows/ci.yml              矩阵 job + 双层触发
src/ci/run.sh                         job 分发器（本地复现入口）
src/ci/shared.sh                      helper
src/ci/scripts/run-build-from-ci.sh   GHA 入口
src/ci/scripts/setup-environment.sh   环境转储
```

- 双层触发：`pull_request`（PR 快速层：`check` / `bootstrap-tests` / `selfhost-tests`）+ `merge_group`（完整层：`suite` / `full-bootstrap`）。PR 层 job 在 merge 下也运行（Rust 的 PR-jobs-auto-register 语义）
- 移除：`citool`（静态矩阵内联）、全部 `install-*.sh`（Core 零工具链依赖）、`docker/`、`artifacts`
- 已知风险（如实标记）：`full-bootstrap` 涉及 `corec2` tokenizer 死循环（TODO 自举阻塞项）和预存 bug 1（1GiB bump heap 峰值），完整层按 TODO 逐个启用；`opt-regress`（O0/O1 回归）预留位置
- 本地验证：`CI_JOB_NAME=bootstrap-tests src/ci/run.sh` 端到端通过

## 本地配置

| 项 | 命令/文件 | 效果 |
|---|---|---|
| jj bookmark 保护 | `jj config set --repository bookmarks.main.protect true` | main 不被 rebase/rewrite 意外移动 |
| jj 提交签名 | `jj config set --user signing.backend ssh`、`signing.key ~/.ssh/id_ed25519.pub`、`signing.sign-all true` | 全部新提交 SSH 签名（满足规则 M5（强制签名提交）） |
| git 硬拦截 hook | `.claude/settings.json`（提交入库）：PreToolUse 检测以 `git` 开头的 Bash 命令，输出报错并返回非零退出码，命令被拒绝 | 规则 #2 由 hook 强制执行 |
| settings.local.json 清理 | 移除 `Bash(git *)` 允许项 | 权限模型与 hook 一致 |
| CLAUDE.md | 新增"版本控制流程"段（下述命令序列） | 文档与机制一致 |

## 新工作流（维护者）

```
日常开发（feature 到 develop）：
jj bookmark create feature/xxx        # feature 分支（base = develop）
...开发提交（自动签名）...
jj git push -b feature/xxx
gh pr create --base develop --fill        # PR 指向 develop（"不能指向 main"）
审查（RhineIris 的 PR 由你审查；你自己的 PR 走 B 流程临时豁免），然后手动合入（PR CI 通过）
squash 合入 develop + 自动删源分支
jj git fetch && jj bookmark move develop -r develop@origin   # 本地 develop 对齐

develop 到 main（只有你能）：
jj git push -b develop                # 你有写权限
gh pr create --base main --fill       # develop 到 main 的 PR（required reviewers = 你）
你批准，然后手动 squash 合入 main
```

## 验证清单（合入后端到端）

- [ ] 直推 `main` 被拒（403）；推 `feature` 分支成功
- [ ] 指向 `main` 的 PR（非维护者创建）无法被批准合入，`required reviewers` 仅 DslsDZC
- [ ] `develop` 到 `main` 合并只有维护者执行成功
- [ ] 维护者自有 `feature` PR：B 流程（临时豁免），squash 合入 `develop`，源分支自动删除
- [ ] RhineIris fork PR：`base=develop`，完整流程，维护者审阶段后合入 `develop`
- [ ] 未签名提交的 PR 被拒（签名规则生效）；`jj log --no-graph -T 'signature'` 可见签名
- [ ] 管理员账号直推 `main` 同样被拒（绕过已关闭）
- [ ] `git` 命令被 hook 拦截；`jj` 一切正常
- [ ] `jj` main protect 生效（rebase 移不动 `main`）
- [ ] PR 层 CI 通过；完整层 job 状态按实际情况标记

## 社区协作基础设施（2026-08-09 补充）

| 文件 | 内容 |
|---|---|
| `.github/pull_request_template.md` | PR 模板：变更描述 / 测试 / 语义保留影响 / 已知限制 |
| `.github/CONTRIBUTING.md` | 贡献指南：fork、PR、审查、queue 流程、硬性规则（禁 git）、构建测试命令、编码约定、审查标准 |
| `.github/SECURITY.md` | 漏洞报告路径（GitHub 私有漏洞报告）与响应承诺 |
| `.github/CODE_OF_CONDUCT.md` | 贡献者行为规范（Contributor Covenant 2.1 中文版，执行联系人 dsls.dzc@gmail.com） |

## 发布规范

- 版本号：semver（`MAJOR.MINOR.PATCH`）
- 标签：`release/vMAJOR.MINOR.PATCH`（对应 protected tags 规则 `release/*`）
- 发布流程：维护者从 main 打 tag，标签保护防止强推和删除
- changelog：按需维护（后续项）

## 后续项（明确延期）

- Issue 模板（bug/特性请求）、标签体系，贡献者规模扩大后补
- Dependabot：不做（仓库零外部依赖）
- CI 优化：actions/cache 缓存 `build/corec`（多 job 共享构建产物）；`full-bootstrap` 启用（依赖自举阻塞项修复）；`opt-regress`（O0/O1 回归）启用
- 部署环境前提（required deployment）：没有发布流水线前不做

## 当前状态

- CI 基础结构：已实现（2026-08-09），本地验证通过，随首个 PR 上线
- 社区四件套：PR 模板 / `CONTRIBUTING` / `SECURITY` / `CODE_OF_CONDUCT` 已写（2026-08-09），随本 spec 首 PR 上线
- 本地配置：jj protect / jj 签名（behavior=own）/ hook / settings 清理 / CLAUDE.md，全部实施（2026-08-09）
- `develop` 集成分支已创建并表示 PR #25
- GitHub ruleset：`main-only-maintainer`（id 20601201）+ `develop-integration`（id 20601189）已创建并 active（2026-08-09）；`gh` TLS 间歇性故障期间通过重试创建成功；squash-only（`allowed_merge_methods=['squash']`）已应用于两个 ruleset；`delete_branch_on_merge=True` 已设置
- 首个 PR（#25 到 develop）与发布 PR（#26 到 main，B 流程）已完成；治理全流程已端到端验证
