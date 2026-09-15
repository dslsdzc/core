#!/usr/bin/env python3
"""铁律 #2 机械执行：命令串中出现 git **调用** → 拒绝执行（exit 2）。

加固（2026-09-16，TODO #23）：原实现只拦「整条命令以 git 开头」，
`cd x && git …` / `bash -c 'git …'` / `… | git …` / `$(git …)` 全能绕过。

现覆盖：
  · 以 git 开头（原行为；含 `/usr/bin/git` 等带路径形态）
  · 分隔符之后：`;` `&&` `||` `|` `&` `(` `)` 换行
  · 命令替换 / 子壳：`$(git …)`、反引号、`(git …)`
  · shell 内联脚本：`bash -c '…'` / `sh -c "…"`（递归扫描，深度 ≤ 3）
  · 前缀命令之后：sudo / env / nice / nohup / time / exec / command / xargs /
    timeout / stdbuf / setsid / ionice / cpulimit / watch（含其旗标与数字参数）

**不得误伤（同为零容忍：误伤会让人绕开 hook）**：
  · `jj git push`（git 不是命令词）
  · **引号内**的 git 文本：`jj commit -m '… git log …'` · `echo "use git"`
  · **heredoc 体内**的 git 文本（`<<'PY' … PY`；脚本体是数据不是命令）
  · `grep -n git` · `find . -name .gitignore` · `cat .gitignore`

实现要点：先剥离 heredoc 体（按行扫，遇 `<<[-]?WORD` 丢弃到终止行），
再用 `shlex`（`punctuation_chars`，**尊重引号**）分词，按分隔符 token 切段，
每段跳过前导「环境赋值 / 前缀命令 / shell 名 / 旗标 / 纯数字」后看**首个命令词**。

失败模式：hook 自身异常 **一律放行**（exit 0）—— 宁可漏拦，不可把会话卡死。
"""
import json
import re
import shlex
import sys

PREFIX_CMDS = {
    "sudo", "doas", "env", "nice", "nohup", "time", "exec", "command", "xargs",
    "timeout", "stdbuf", "setsid", "ionice", "cpulimit", "parallel", "watch",
}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "fish"}
MAX_DEPTH = 3
PUNCT = "();|&<>`$\n"
SEP_CHARS = set("();|&`$\n")                      # 切段用；< > 是重定向、不是命令分隔符
ENV_ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
HEREDOC_RE = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
INNER_RE = re.compile(
    r"""(?:^|[;&|(\s])(?:bash|sh|zsh|dash|ksh|fish)\s+(?:-\S+\s+)*-\S*c\S*\s+"""
    r"""(?P<q>['"])(?P<script>.*?)(?P=q)""",
    re.S,
)

MSG = (
    "铁律 #2：全面使用 jj，禁止 git（任何位置的 git 调用都会被拦）。\n"
    "改用 jj：jj status / jj log / jj describe / jj git push / jj bookmark …\n"
    "（本拦截由 .claude/hooks/block-git.py 执行；测试见 tests/harness/test_block_git.py）\n"
)


def strip_heredocs(cmd: str) -> str:
    """丢弃 heredoc 体（脚本体是数据，不是被执行的命令）。"""
    lines = cmd.split("\n")
    out, i = [], 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        m = HEREDOC_RE.search(line)
        if m:
            delim = m.group(2)
            i += 1
            while i < len(lines) and lines[i].strip() != delim:
                i += 1                      # 丢弃体
        i += 1
    return "\n".join(out)


def tokenize(cmd: str):
    try:
        lex = shlex.shlex(cmd, posix=True, punctuation_chars=PUNCT)
        lex.whitespace_split = True
        lex.whitespace = " \t"                  # 换行留给标点 ⇒ 成为独立分隔 token
        return list(lex)
    except ValueError:                      # 引号不配对等 → 退化为空白切分
        return cmd.split()


def split_segments(tokens):
    segs, cur = [], []
    for t in (tokens or []):
        if t and all(c in SEP_CHARS for c in t):
            if cur:
                segs.append(cur)
            cur = []
        else:
            cur.append(t)
    if cur:
        segs.append(cur)
    return segs


def first_command_word(seg):
    i, skipped = 0, 0
    while i < len(seg) and skipped < 6:
        t = seg[i]
        if (ENV_ASSIGN_RE.match(t) or t in PREFIX_CMDS or t in SHELLS
                or t.startswith("-") or t.isdigit()):
            i, skipped = i + 1, skipped + 1
            continue
        break
    return seg[i] if i < len(seg) else None


def is_git_token(tok: str) -> bool:
    base = tok.rsplit("/", 1)[-1]
    return base in ("git", "git.exe")


def scan(cmd: str, depth: int = 0):
    """返回首个命中片段（str），未命中返回 None。"""
    if depth > MAX_DEPTH:
        return None
    text = strip_heredocs(cmd)
    for seg in split_segments(tokenize(text)):
        w = first_command_word(seg)
        if w and is_git_token(w):
            return " ".join(seg[:4])
    for m in INNER_RE.finditer(text):       # bash -c '…' 内联脚本
        hit = scan(m.group("script"), depth + 1)
        if hit:
            return hit
    return None


def main() -> int:
    try:
        data = json.load(sys.stdin)
        cmd = data.get("tool_input", {}).get("command", "") or ""
        if scan(cmd):
            sys.stderr.write(MSG)
            return 2                        # PreToolUse exit 2 = 拦截本次调用
    except Exception as exc:                # 自身异常一律放行
        sys.stderr.write(f"[block-git] hook 内部错误，本次放行：{exc!r}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
