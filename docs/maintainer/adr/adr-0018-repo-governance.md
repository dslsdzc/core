# ADR-0018: 仓库治理——GitFlow 分支模型 + 双 ruleset + CI 门槛

- 日期:2026-08-09
- 状态:accepted(已落地)
- 决策者:DslsDZC(维护者)

## 背景
自举进入协作期(第二维护者 RhineIris 参与 PR #9/#14),需要分支保护、审批流与 CI;早期直接提交 main 的流程不可持续。

## 决策
- **分支模型 feature → develop → main**:main = 正式版线(仅维护者可合入,update 规则 + 无管理员绕过);develop = 集成分支(PR + 审批 + merge queue + CI 门槛);feature 分支每改动独立
- 仓库治理四件套:CODE_OF_CONDUCT/CONTRIBUTING/SECURITY/PR 模板 + CI(core-ci.yml)
- 版本控制工具 = jj(禁 git 写操作,铁律);合并 = 手动 squash 合入 develop(merge queue 因免费计划降级)

## 后果
- 正面:合入门槛(审批 + CI 绿)防回归;main 稳定线;协作并行(PR 通道)
- 负面:多会话共享工作副本互踩风险(后续用独立 jj workspace 根治);squash 合入丢失分支粒度

## 关联
- 文档:CLAUDE.md(版本控制流程);specs/2026-08-09-repo-governance-design.md
