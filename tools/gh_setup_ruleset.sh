#!/bin/bash
# 仓库治理 ruleset 配置脚本（spec §3 清单落地，路径 A）
# 用法：gh auth refresh 后运行本脚本；或按脚本内 JSON 在网页版手动配置（路径 B）
# API 事实：restrict-pushes = update 规则 + bypass_actors（不含 Admin 角色=关闭管理员绕过）；
#           enforcement: evaluate 仅 Enterprise（免费计划不可用，用 active）；
#           merge_queue 规则在本计划被拒（"Invalid rule"）——已降级为手动合入（审阶段+CI 门槛保留）；
#           squash-only 经 pull_request 参数 allowed_merge_methods=["squash"] 强制；
#           pull_request 参数 5 个必填布尔（含 require_code_owner_review）；required_status_checks 字段名非 checks
#           required_reviewers 为 pull_request 规则的 beta 参数（Team 型）——个人用户用
#           bypass_actors 空集 + 权限模型（仅 DslsDZC 有写权限）实现。
set -euo pipefail
REPO="dslsdzc/core"

main_ruleset() {
cat <<'JSON'
{
  "name": "main-only-maintainer",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["refs/heads/main"], "exclude": []}},
  "bypass_actors": [],
  "rules": [
    {"type": "update", "parameters": {"update_allows_fetch_and_merge": false}},
    {"type": "pull_request", "parameters": {
      "required_approving_review_count": 1,
      "dismiss_stale_reviews_on_push": true,
      "require_code_owner_review": false,
      "require_last_push_approval": false,
      "required_review_thread_resolution": true,
      "allowed_merge_methods": ["squash"]
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
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["refs/heads/develop"], "exclude": []}},
  "bypass_actors": [],
  "rules": [
    {"type": "pull_request", "parameters": {
      "required_approving_review_count": 1,
      "dismiss_stale_reviews_on_push": true,
      "require_code_owner_review": false,
      "require_last_push_approval": false,
      "required_review_thread_resolution": true,
      "allowed_merge_methods": ["squash"]
    }},
    {"type": "required_status_checks", "parameters": {
      "required_status_checks": [
        {"context": "CI / check"},
        {"context": "CI / bootstrap-tests"},
        {"context": "CI / selfhost-tests"}
      ],
      "strict_required_status_checks_policy": true
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
  echo "gh 不可用：请按上方 JSON 在网页版 Settings → Rules → Rulesets 手动创建（路径 B）"
fi
