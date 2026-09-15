#!/usr/bin/env python3
"""TODO #23：`.claude/hooks/block-git.py`（铁律 #2 机械执行）的加固判据。

原缺口：hook 只拦「整条命令以 git 开头」⇒ `cd x && git …` / `bash -c 'git …'` /
`… | git …` / `$(git …)` 全能绕过（2026-09-11 R2 P1 Task 3 评审登记）。

判据两组：
  · BLOCK —— 必须 rc=2（拦截）
  · ALLOW —— 必须 rc=0（放行；**误伤 = 同样的失败**：把 jj 用法的常用命令拦掉会让人绕开 hook）

跑法：python3 tests/harness/test_block_git.py
"""

import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HOOK = os.path.join(ROOT, ".claude", "hooks", "block-git.py")

BLOCK = [
    ("原行为：裸 git", "git status"),
    ("原行为：带路径", "/usr/bin/git status"),
    ("原行为：git 无参数", "git"),
    ("&& 串联", "cd /tmp && git status"),
    ("; 串联", "cd /tmp; git log --oneline -3"),
    ("管道", "echo x | git apply"),
    ("|| 串联", "false || git reset --hard"),
    ("& 后台", "sleep 1 & git stash"),
    ("子壳", "(git stash)"),
    ("命令替换 $()", "echo $(git rev-parse HEAD)"),
    ("反引号", "echo `git rev-parse HEAD`"),
    ("bash -c 单引号", "bash -c 'git checkout .'"),
    ("sh -c 双引号", 'sh -c "git reset --hard"'),
    ("sudo 前缀", "sudo git fetch"),
    ("nice + 旗标 + 数字", "nice -n 19 git status"),
    ("env + 赋值", "env FOO=1 git push"),
    ("xargs 前缀", "xargs git add"),
    ("timeout + 数字", "timeout 5 git log"),
    ("嵌套 bash -c", "bash -c 'bash -c \"git status\"'"),
    ("heredoc 之后有真调用", "cat <<EOF\nhi\nEOF\ngit status"),
]

ALLOW = [
    ("jj git push（git 非命令词）", "jj git push"),
    ("jj git fetch + bookmark", "jj git fetch && jj bookmark set develop -r develop@origin"),
    ("jj log 含 git 字面", "jj log -r 'git'"),
    ("echo git", "echo git"),
    ("grep 搜 git", "grep -rn git src/"),
    ("find .gitignore", "find . -name .gitignore"),
    ("cat .gitignore", "cat .gitignore"),
    ("引号内的 git（非命令位）", 'echo "use git for that"'),
    ("grep hook 名（含 -git 子串）", 'grep -rn "block-git" .claude'),
    ("python 脚本名含 git", "python3 tests/harness/test_block_git.py"),
    ("gitignore 形态词", "ls .gitignore .github/"),
    # ↓ 误伤用例（首版实现的真缺陷：切段未尊重引号/heredoc ⇒ 数据里的 git 文本被当成调用）
    ("提交信息含 git 文本（单引号）", "jj commit -m 'fix: 禁 git 钩子（例：cd x && git log）' TODO.md"),
    ("双引号内的分隔符+git 文本", 'echo "use git; git log"'),
    ("heredoc 体内（引号定界符）", "python3 - <<'PY'\nprint('cd /tmp && git status')\nPY"),
    ("heredoc 体内（裸定界符）", "cat <<EOF\ncd /tmp && git log\nEOF"),
    ("grep 搜 git 调用形态", "grep -rn 'git checkout' docs/"),
]


def run_hook(cmd):
    proc = subprocess.run(
        [sys.executable, HOOK],
        input=json.dumps({"tool_input": {"command": cmd}}),
        capture_output=True, text=True, timeout=30,
    )
    return proc.returncode


def main():
    if not os.path.exists(HOOK):
        print(f"[FAIL] 缺 hook：{HOOK}")
        return 1
    fails = 0
    for name, cmd in BLOCK:
        rc = run_hook(cmd)
        if rc == 2:
            print(f"[PASS] BLOCK  {name}: rc={rc}")
        else:
            print(f"[FAIL] BLOCK  {name}: rc={rc}（应 =2）  cmd={cmd!r}")
            fails += 1
    for name, cmd in ALLOW:
        rc = run_hook(cmd)
        if rc == 0:
            print(f"[PASS] ALLOW  {name}: rc={rc}")
        else:
            print(f"[FAIL] ALLOW  {name}: rc={rc}（应 =0，误伤）  cmd={cmd!r}")
            fails += 1
    total = len(BLOCK) + len(ALLOW)
    print(f"{total - fails}/{total} passed"
          f"（BLOCK {len(BLOCK)} · ALLOW {len(ALLOW)}）")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
