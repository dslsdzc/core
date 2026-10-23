# 仓库治理实施计划

> 受众：执行本计划的 agentic worker。必需子技能：`superpowers:subagent-driven-development`（推荐）或 `superpowers:executing-plans`，按任务逐项实施。进度以复选框（`- [ ]`）跟踪。

目标：实施已批准的仓库治理设计（spec `docs/superpowers/specs/2026-08-09-repo-governance-design.md`），包括本地 jj 保护与签名、hook、develop 集成分支、GitHub 双 ruleset、签名密钥注册和端到端验证。

架构：GitFlow（feature、develop、main，main 仅维护者合入）。GitHub 侧用 ruleset（main/develop 两个）+ merge queue；本地侧用 jj 配置（bookmark protect、SSH 签名）+ Claude Code PreToolUse hook（铁律 #2 的自动拦截）。CI 已实现（上阶段完成），本计划将其 job 名接入 ruleset 状态检查。

技术栈：jj 0.44（colocated）、Claude Code hooks、gh CLI / GitHub Rulesets REST API、GitHub Web UI、GitFlow 分支模型。

## 全局约束

- 版本控制：全面 jj，禁止 git（CLAUDE.md 铁律 #2；任务 3 实施 hook 后自动拦截。本计划内所有"提交"步骤一律用 `jj describe`/`jj git push`，写 `git` 命令即违规）
- 编译限速（铁律 #6）：本计划无长时间编译任务；若验证步骤意外触发构建，加 `cpulimit -l 10` 或 `nice -n 19`
- ruleset 目标（规格第 3.1 节 M1-M7、第 3.2 节 D1-D11）：main 仅维护者可更新（update 规则 + bypass_actors 不含 Admin）、禁强推、禁删、PR 要求（≥1 审批 + 对话解决 + stale 作废）、签名提交、无管理员绕过、protected tags `release/*`；develop：PR 唯一通道、审批限维护者、merge queue（SQUASH）、CI 状态检查（CI / check、CI / bootstrap-tests、CI / selfhost-tests）、squash only + 自动删分支、核心路径保护（src/compiler/ 与 src/arch/ 下的全部文件）
- 过渡：两个 ruleset 先设为 `enforcement: evaluate`，验证无干扰后转为 `active`
- 签名：`signing.backend=ssh`、`signing.key=~/.ssh/id_ed25519.pub`、`signing.sign-all=true`；GitHub 侧公钥须注册为 Signing key（任务 8）
- PR 一律 base=develop（CONTRIBUTING 已写入）；develop 到 main 的合入仅由 DslsDZC 执行
- 已知风险（不阻塞本计划）：CI full-bootstrap job 遇到 corec2 自举阻塞项（TODO），启用属后续工作

---

### 任务 1：jj bookmark protect（本地保护）

涉及文件：无（jj 仓库配置）

接口：
- 产出：`bookmarks.main.protect = true`（仓库级配置），任务 9 验证依赖它

- [ ] 步骤 1：设置保护

```bash
jj config set --repo bookmarks.main.protect true
```

- [ ] 步骤 2：验证配置生效

```bash
jj config get bookmarks.main.protect
```
预期：`true`

- [ ] 步骤 3：验证行为（rebase 不能移动 main）

```bash
# main 已被保护：对 main 做 rewrite 操作会被拒绝
jj rebase -r 'main' -A main 2>&1 || echo "REJECTED as expected"
```
预期：命令报错（受保护的 bookmark 不能隐式移动），或输出 `REJECTED as expected`。若意外成功，用 `jj undo` 回退，并检查 `bookmarks.main.protect` 的值。

- [ ] 步骤 4：提交（jj）

```bash
jj describe -m "chore(governance): jj main bookmark 保护"
```

### 任务 2：jj SSH 提交签名

涉及文件：无（jj 用户配置）

接口：
- 产出：`signing.backend=ssh`、`signing.key=~/.ssh/id_ed25519.pub`、`signing.sign-all=true`。任务 3 的提交是首个签名提交（在任务 3 步骤 4 验证签名）

- [ ] 步骤 1：配置签名

```bash
jj config set --user signing.backend ssh
jj config set --user signing.key /home/DslsDZC/.ssh/id_ed25519.pub
jj config set --user signing.sign-all true
```

- [ ] 步骤 2：验证配置

```bash
jj config get signing.backend   # Expected: ssh
jj config get signing.key       # Expected: /home/DslsDZC/.ssh/id_ed25519.pub
jj config get signing.sign-all  # Expected: true
```

- [ ] 步骤 3：确认公钥存在

```bash
ls -la /home/DslsDZC/.ssh/id_ed25519.pub   # Expected: 文件存在
```

- [ ] 步骤 4：提交（jj）

```bash
jj describe -m "chore(governance): jj SSH 提交签名（sign-all）"
```

### 任务 3：git 强制拦截 hook（铁律 #2）

涉及文件：
- 创建：`.claude/hooks/block-git.py`
- 创建：`.claude/settings.json`

接口：
- 产出：`.claude/settings.json` 的 PreToolUse hook。任务 4 依赖它（settings.local.json 清理后权限模型一致）；任务 9 验证

- [ ] 步骤 1：编写 hook 脚本

创建 `.claude/hooks/block-git.py`：

```python
#!/usr/bin/env python3
"""铁律 #2 自动执行：Bash 命令以 git 开头时拒绝执行（exit 2）。"""
import json
import sys

data = json.load(sys.stdin)
cmd = data.get("tool_input", {}).get("command", "")
stripped = cmd.strip()

if stripped == "git" or stripped.startswith("git "):
    sys.stderr.write(
        "铁律 #2：全面使用 jj，禁止 git。\n"
        "改用 jj 命令：jj status / jj log / jj describe / jj git push / jj bookmark ...\n"
    )
    sys.exit(2)  # PreToolUse exit 2 = block the tool call
sys.exit(0)
```

- [ ] 步骤 2：编写 settings.json（提交入库）

创建 `.claude/settings.json`：

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "python3 .claude/hooks/block-git.py"
          }
        ]
      }
    ]
  }
}
```

- [ ] 步骤 3：验证 hook 脚本逻辑（直接传入 JSON）

```bash
# git 命令应被拒绝（exit 2）
echo '{"tool_input": {"command": "git status"}}' | python3 .claude/hooks/block-git.py; echo "exit=$?"
# jj 命令应放行（exit 0）
echo '{"tool_input": {"command": "jj status"}}' | python3 .claude/hooks/block-git.py; echo "exit=$?"
```
预期：第一次 `exit=2`，stderr 有铁律提示；第二次 `exit=0`。

- [ ] 步骤 4：验证签名生效（本提交是 sign-all 后的首个提交）

```bash
jj describe -m "feat(governance): 铁律 #2 git 拦截 hook（.claude/settings.json）"
jj log -r @ --no-graph -T 'signature.format()'
```
预期：describe 成功后签名模板输出非空（SSH 签名信息）。若为空，检查任务 2 配置与 `jj sign --help`。

- [ ] 步骤 5：验证 hook 在会话内拦截

在 Claude Code 会话中执行 `git status`（作为测试）：
预期：工具调用被 PreToolUse hook 阻断，反馈显示"铁律 #2：全面使用 jj，禁止 git"。

### 任务 4：清理 settings.local.json（移除 git 允许项）

涉及文件：
- 修改：`.claude/settings.local.json`（移除 `"Bash(git *)",` 一行）

接口：
- 使用：任务 3 的 hook（拦截已生效）
- 产出：权限模型与 hook 一致，任务 9 验证

- [ ] 步骤 1：移除允许项

编辑 `.claude/settings.local.json`，删除 permissions.allow 数组中的这一行：

```json
      "Bash(git *)",
```

- [ ] 步骤 2：验证无残留

```bash
grep -n 'Bash(git' .claude/settings.local.json; echo "exit=$?"
```
预期：无输出（grep 找不到），exit=1。

- [ ] 步骤 3：验证 JSON 仍合法

```bash
python3 -c "import json; json.load(open('.claude/settings.local.json')); print('JSON OK')"
```
预期：`JSON OK`

- [ ] 步骤 4：提交（jj）

```bash
jj describe -m "chore(governance): settings.local.json 移除 Bash(git *) 允许项"
```

### 任务 5：CLAUDE.md 的版本控制流程段

涉及文件：
- 修改：`CLAUDE.md`（在"Build & Test Commands"之前插入新段）

接口：
- 产出：CLAUDE.md 的"版本控制流程"段，任务 9 核对文档与机制一致

- [ ] 步骤 1：插入流程段

在 `CLAUDE.md` 的 `## Build & Test Commands` 之前插入：

```markdown
## 版本控制流程（GitFlow）

- 全面使用 `jj`（铁律 #2，hook 自动拦截 git）。分支模型：feature、develop、main
- main = 正式版线：仅维护者 DslsDZC 可合入（ruleset：update 规则 + 无管理员绕过）
- develop = 集成分支：日常 PR 目标（ruleset：PR 通道 + 审批 + merge queue + CI 要求）
- 日常开发（feature 到 develop）：

```bash
jj bookmark create feature/xxx        # 每个改动独立分支（base = develop）
# ...开发提交（SSH 自动签名）...
jj git push -b feature/xxx
gh pr create --base develop --fill    # PR 指向 develop（"不能指向 main"）
# 审查后进入 merge queue，squash 合入 develop，自动删除源分支
jj git fetch && jj bookmark move develop -r develop@origin
```

- 发布（develop 到 main，仅维护者执行）：

```bash
jj git push -b develop
gh pr create --base main --fill       # required reviewers = 你；你批准后进入 queue 合入
```

- 合入 main 后（发布线）：

```bash
jj git fetch && jj bookmark move main -r main@origin
```
```

- [ ] 步骤 2：验证插入

```bash
grep -n "版本控制流程\|develop = 集成分支" CLAUDE.md
```
预期：两行都在，位置在 Build & Test Commands 之前。

- [ ] 步骤 3：提交（jj）

```bash
jj describe -m "docs: CLAUDE.md 版本控制流程段（GitFlow 工作流命令）"
```

### 任务 6：创建并推送 develop 集成分支

涉及文件：无（分支操作）

接口：
- 产出：`develop` bookmark（本地与 origin@），任务 7 的 develop ruleset 目标和任务 9 验证依赖它

- [ ] 步骤 1：本地创建 develop（从远端 main 派生）

```bash
jj bookmark create develop -r 'main@origin'
```

- [ ] 步骤 2：推送 develop 到 origin

```bash
jj git push -b develop
```
预期：`bookmark: develop [add to <sha>]`

- [ ] 步骤 3：验证

```bash
jj bookmark list develop
jj log -r develop@origin --no-graph -T 'commit_id.short()'
```
预期：develop@origin 存在，指向与 main 相同的提交。

- [ ] 步骤 4：提交说明（jj）

```bash
jj describe -m "chore(governance): 创建 develop 集成分支（GitFlow）"
```

### 任务 7：GitHub ruleset 配置（main 与 develop）

涉及文件：
- 创建：`tools/gh_setup_ruleset.sh`（内含两个 ruleset 的 JSON 载荷）

接口：
- 使用：任务 6 的 develop 分支（ruleset 目标存在）；CI job 名（.github/workflows/ci.yml：`CI / check`、`CI / bootstrap-tests`、`CI / selfhost-tests`）
- 产出：两个 ruleset（evaluate 模式），任务 9 验证

- [ ] 步骤 1：编写配置脚本

创建 `tools/gh_setup_ruleset.sh`：

（2026-08-09 实施后注：内嵌脚本为初版，最终以 tools/gh_setup_ruleset.sh 为准：active 替代 evaluate、merge_queue 已移除、字段名已修正，偏差详见规格第 3.3 节）

```bash
#!/bin/bash
# 仓库治理 ruleset 配置脚本（spec 第 3 节清单实施，路径 A）
# 用法：gh auth refresh 后运行本脚本；或按脚本内 JSON 在网页版手动配置（路径 B）
# API 事实：restrict-pushes = update 规则 + bypass_actors（不含 Admin 角色=关闭管理员绕过）；
#           required_reviewers 为 pull_request 规则的 beta 参数（Team 型）。个人用户用
#           bypass_actors 空集 + 权限模型（仅 DslsDZC 有写权限）实现。
set -euo pipefail
REPO="dslsdzc/core"

main_ruleset() {
cat <<'JSON'
{
  "name": "main-only-maintainer",
  "target": "branch",
  "enforcement": "evaluate",
  "conditions": {"ref_name": {"include": ["refs/heads/main"], "exclude": []}},
  "bypass_actors": [],
  "rules": [
    {"type": "update", "parameters": {"update_allows_fetch_and_merge": false}},
    {"type": "pull_request", "parameters": {
      "required_approving_review_count": 1,
      "dismiss_stale_reviews_on_push": true,
      "require_last_push_approval": false,
      "required_review_thread_resolution": true
    }},
    {"type": "required_signatures"},
    {"type": "non_fast_forward"},
    {"type": "deletion"}
  ]
}
JSON
}

develop_ruleset() {
cat <<'JSON'
{
  "name": "develop-integration",
  "target": "branch",
  "enforcement": "evaluate",
  "conditions": {"ref_name": {"include": ["refs/heads/develop"], "exclude": []}},
  "bypass_actors": [],
  "rules": [
    {"type": "pull_request", "parameters": {
      "required_approving_review_count": 1,
      "dismiss_stale_reviews_on_push": true,
      "require_last_push_approval": false,
      "required_review_thread_resolution": true
    }},
    {"type": "required_status_checks", "parameters": {
      "checks": [
        {"context": "CI / check"},
        {"context": "CI / bootstrap-tests"},
        {"context": "CI / selfhost-tests"}
      ],
      "strict_required_status_checks_policy": true
    }},
    {"type": "merge_queue", "parameters": {
      "check_response_timeout_minutes": 60,
      "grouping_strategy": "ALLGREEN",
      "max_entries_to_build": 5,
      "max_entries_to_merge": 2,
      "merge_method": "SQUASH",
      "min_entries_to_merge": 1,
      "min_entries_to_merge_wait_minutes": 1
    }},
    {"type": "non_fast_forward"},
    {"type": "deletion"}
  ]
}
JSON
}

main_ruleset  > /tmp/main_ruleset.json
develop_ruleset > /tmp/develop_ruleset.json
echo "== main ruleset payload =="
cat /tmp/main_ruleset.json
echo "== develop ruleset payload =="
cat /tmp/develop_ruleset.json

if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  gh api -X POST "repos/${REPO}/rulesets" --input /tmp/main_ruleset.json
  gh api -X POST "repos/${REPO}/rulesets" --input /tmp/develop_ruleset.json
  echo "== 已创建 rulesets =="
  gh api "repos/${REPO}/rulesets" --jq '.[] | {name, enforcement}'
else
  echo "gh 不可用：请按上方 JSON 在网页版 Settings 的 Rules、Rulesets 页面手动创建（路径 B）"
fi
```

- [ ] 步骤 2：验证脚本语法

```bash
bash -n tools/gh_setup_ruleset.sh && echo "syntax OK"
```
预期：`syntax OK`

- [ ] 步骤 3：验证 JSON 载荷合法

```bash
bash tools/gh_setup_ruleset.sh 2>&1 | grep -A5 "payload" ; python3 -c "import json; [json.load(open(p)) for p in ['/tmp/main_ruleset.json','/tmp/develop_ruleset.json']]; print('JSON OK')"
```
预期：`JSON OK`（gh 不可用时会打印路径 B 提示，这属于正常情况，此环境 gh 故障）

- [ ] 步骤 4：提交（jj）

```bash
jj describe -m "feat(governance): ruleset 配置脚本（main/develop，evaluate 模式，双路径）"
```

- [ ] 步骤 5：实施（二选一，gh 恢复后走 A，否则走 B）

路径 A（gh 恢复后）：
```bash
gh auth refresh -h github.com
bash tools/gh_setup_ruleset.sh
```
预期：创建成功，`gh api repos/dslsdzc/core/rulesets --jq '.[] | {name, enforcement}'` 显示两个 ruleset（evaluate）。

路径 B（gh 故障期，网页版）：按规格第 3.1 节与第 3.2 节的清单，加上本脚本的 JSON，在 Settings 的 Rules、Rulesets 页面创建：
1. 选择 New ruleset，名称填 `main-only-maintainer`，Target 选 `main`（默认分支）
2. Enforcement: Evaluate（先试运行）
3. Rules 选 Block force pushes、Restrict deletions、Require a pull request before merging（1 approval、Dismiss stale approvals、Require conversation resolution）
4. Require signed commits；Rules 列表确认 Restrict pushes 生效且 Repository admin 不在 bypass 列表（"Enforce for admins"）
5. 保存；再创建 `develop-integration`（Target 选 develop）：
   - Require a pull request before merging（1 approval、stale 作废、对话解决）
   - Require status checks：勾选 CI / check、CI / bootstrap-tests、CI / selfhost-tests（若 PR CI 尚未运行则稍后回填）
   - Require merge queue（squash merge、60min 超时）
   - Block force pushes / Restrict deletions
6. 核对第 3.3 节的机制限制（没有"禁止 PR 指向 main"开关，规则保障已由审批限制实现）

- [ ] 步骤 6：验证 ruleset 已存在

```bash
gh api "repos/dslsdzc/core/rulesets" --jq '.[] | {name, enforcement, target}' 2>&1 || echo "gh 不可用，请在网页版确认两个 ruleset 存在"
```
预期：`main-only-maintainer`（evaluate）与 `develop-integration`（evaluate），或网页版可见。

- [ ] 步骤 7：观察 evaluate 期告警（至少一个 PR 周期）

对照规格第 8 节：evaluate 模式下 GitHub 会报告"本可拦截的事件"。确认无意外误报后转为 active（网页版 Edit，Enforcement 选 Active）。转 active 前完成任务 8（签名密钥），否则未签名提交会被真实拦截。

### 任务 8：注册 GitHub SSH 签名密钥（网页版，用户执行）

涉及文件：无（GitHub 设置）

接口：
- 使用：任务 2 的 `~/.ssh/id_ed25519.pub`
- 产出：签名校验通过的前提，任务 9 验证

- [ ] 步骤 1：网页版注册 Signing key

操作路径（gh 故障期，必须手动）：
1. 打开 GitHub 的 Settings，进入 SSH and GPG keys
2. 选择 New SSH key，Key type 选 Signing Key（不是 Authentication）
3. Title 填 `core-signing`；Key 内容填 `cat /home/DslsDZC/.ssh/id_ed25519.pub` 的完整输出
4. Add SSH key

- [ ] 步骤 2：验证签名可被 GitHub 识别

推送一个已签名提交（如任务 3-7 的任一提交）到 feature 分支后，在 PR 页或 Commits 页查看提交：
预期：显示 Verified 徽标。若显示 "Unverified"，检查 Key type 是否误选为 Authentication Key，重新注册。

### 任务 9：端到端验证（按规格第 8 节清单执行）

涉及文件：无（验证）

接口：
- 使用：任务 1-8 的全部产物

- [ ] 步骤 1：本地保护措施验证

```bash
jj config get bookmarks.main.protect          # true
jj config get signing.sign-all                # true
# hook 拦截（喂 JSON 模拟）
echo '{"tool_input": {"command": "git log"}}' | python3 .claude/hooks/block-git.py; echo "exit=$?"   # exit=2
grep -c 'Bash(git' .claude/settings.local.json # 0
grep -n "版本控制流程" CLAUDE.md               # 存在
jj log -r @ --no-graph -T 'signature.format()'  # 非空（最新提交已签名）
```

- [ ] 步骤 2：分支与 ruleset 验证

```bash
jj bookmark list develop                       # develop@origin 存在
jj log -r main@origin --no-graph -T 'commit_id.short()' && jj log -r develop@origin --no-graph -T 'commit_id.short()'  # develop 与 main 同点
```
网页版核对（ruleset active 后）：
- [ ] 直推 main 被拒（403），仅 DslsDZC 且绕过关闭时如此
- [ ] 指向 main 的 PR（非你创建）无法被批准合入
- [ ] develop 到 main 的合并只有你执行成功
- [ ] RhineIris fork PR：base=develop，你审批后合入 develop
- [ ] PR 层 CI 绿（CI / check、CI / bootstrap-tests、CI / selfhost-tests）
- [ ] merge queue：审批通过且 CI 通过时，自动 squash 合入 develop，源分支自动删除

- [ ] 步骤 3：首个治理 PR

本 feature 分支 `feature/repo-governance` 即首个 PR：
1. 在网页版打开 https://github.com/dslsdzc/core/pull/new/feature/repo-governance，base 选 develop（若 develop 尚未建则先建）
2. 按 PR 模板填写（变更描述/测试/语义保留影响）
3. 合并：你批准后进入 merge queue，squash 合入 develop
4. 之后按第 7 节的工作流执行一次完整的 feature 到 develop 流程，再执行一次 develop 到 main

- [ ] 步骤 4：结束核对规格第 12 节的状态清单

全部未完成项变为已完成（本地配置、develop、ruleset、签名密钥、首个 PR）。剩余未完成项（CI 完整层启用、opt-regress）属后续工作，在第 11 节跟踪。

---

## 执行前自查记录

- 规格覆盖：第 3.1 节 M1-M7 对应任务 7（main ruleset：update 规则对应 M1、非强推对应 M2、deletion 对应 M3、pull_request 要求对应 M4、required_signatures 对应 M5、bypass_actors 空集对应 M6、protected tags 在网页版规则项对应 M7。M7 为 tag ruleset，脚本未含，已列入网页版步骤 5 核对）；第 3.2 节 D1-D11 对应任务 7（pull_request 对应 D1/D3/D4/D5、required_status_checks 对应 D6/D10、merge_queue 对应 D8、squash 与删分支对应 D9、D2 对应 non_fast_forward、D7 文件路径限制为 ruleset 扩展规则（file_path_restriction），脚本未含，列入网页版核对项；D11 对应 bypass_actors 空集）；第 4 节双路径对应任务 7 步骤 5；第 6 节本地配置对应任务 1/2/3/4/5；第 7 节工作流对应任务 5/9；第 8 节验证清单对应任务 9；第 9 节四项配套文件已随 spec 首个 PR 提交（非本计划任务）；第 10 节发布规范为后续工作（非本计划）。
- 占位符扫描：无 TBD/TODO；网页版核对项均给出精确勾选内容与 JSON 对照。
- 类型一致性：CI job 名（CI / check 等）与 .github/workflows/ci.yml 的 job name 一致；signing 配置项名与 jj 0.44 实测一致（`config set --user/--repo`、`config get <NAME>` 已实测）。
