# ADR-0018: 仓库治理：GitFlow 分支模型 + 双 ruleset + CI 要求

- 日期：2026-08-09
- 状态：accepted（已实施）
- 决策者：DslsDZC（维护者）

## 背景

自举进入协作期（第二维护者 RhineIris 参与 PR #9/#2026-09-10-10），需要分支保护、审批流和 CI；早期直接提交 `main` 的流程不可持续。

## 决策

- 分支模型为 `feature`、`develop`、`main`：`main` 是正式版线（仅维护者可合入，update 规则 + 无管理员绕过）；`develop` 是集成分支（PR + 审批 + merge queue + CI 要求）；`feature` 分支每个改动独立。
- 仓库治理四项：`CODE_OF_CONDUCT`/`CONTRIBUTING`/`SECURITY`/PR 模板，加 CI（`core-ci.yml`）。
- 版本控制工具是 `jj`（禁止 `git` 写操作，仓库约定）；合并方式是手动 `squash` 合入 `develop`（merge queue 因免费计划降级）。

## 后果

- 正面：合入要求（审批 + CI 通过）防止回归；`main` 保持稳定；协作可以并行（PR 通道）。
- 负面：多个会话共享工作副本时存在互相覆盖的风险（后续用独立的 `jj` workspace 解决）；`squash` 合入会丢失分支粒度。

## 关联

- 文档：CLAUDE.md（版本控制流程）；specs/2026-08-09-repo-governance-design.md
