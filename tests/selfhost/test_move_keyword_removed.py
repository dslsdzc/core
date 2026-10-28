#!/usr/bin/env python3
"""`move` 关键字退役判定依据（TODO #2026-09-17-18）。

判定依据：
  M1 `move x` 作为表达式 ⇒ check rc≠0，诊断为未定义名 `move`。
  M2 `move x = 1` ⇒ check rc≠0，不能被当成合法 move 声明。
  M3 `move := 1` ⇒ check rc=0，拼写进入普通名字域。
  M4 生产源码和 grammar 不再出现 `T_MOVE`、`EXPR_MOVE`、`'move'`。
"""

import os
import subprocess
import sys
import tempfile

BASE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
COREC = os.path.join(BASE, "build", "corec")

CASES = (
    ("move_expr", "fn main() -> int:\n    move x\n    return 0\n", 1),
    ("move_decl", "fn main() -> int:\n    move x = 1\n    return 0\n", 1),
    ("move_ident", "fn main() -> int:\n    move := 1\n    return move\n", 0),
)


def check_source(src):
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "probe.cr")
        with open(path, "w", encoding="utf-8") as f:
            f.write(src)
        r = subprocess.run([COREC, "check", path], capture_output=True, text=True)
        return r.returncode, (r.stdout or "") + (r.stderr or "")


def static_scan():
    bad = []
    for root, _, files in os.walk(os.path.join(BASE, "src", "compiler")):
        for name in files:
            if not name.endswith(".cr"):
                continue
            path = os.path.join(root, name)
            text = open(path, encoding="utf-8").read()
            for needle in ("T_MOVE", "EXPR_MOVE"):
                if needle in text:
                    bad.append(f"M4 红：{os.path.relpath(path, BASE)} 仍含 {needle}")
    tokens = open(os.path.join(BASE, "grammar", "tokens.ebnf"), encoding="utf-8").read()
    if "'move'" in tokens:
        bad.append("M4 红：grammar/tokens.ebnf 仍含 'move'")
    core = open(os.path.join(BASE, "grammar", "core.ebnf"), encoding="utf-8").read()
    if "Move =" in core:
        bad.append("M4 红：grammar/core.ebnf 仍含 Move 产生式")
    return bad


def main():
    if not os.path.exists(COREC):
        print("[FAIL] 缺 build/corec（本判定依据需先 build_selfhost）")
        return 1
    bad = []
    for name, src, want in CASES:
        rc, log = check_source(src)
        if want == 0:
            if rc != 0:
                bad.append(f"M3 红：{name} check rc={rc}（应为 0）；输出={log.strip()[:120]}")
        else:
            if rc == 0:
                bad.append(f"M1/M2 红：{name} check rc=0（应拒收）")
            elif "Undefined name 'move'" not in log:
                bad.append(f"M1/M2 红：{name} 拒收但诊断不含 Undefined name 'move'：{log.strip()[:120]}")
    bad += static_scan()
    for b in bad:
        print("[FAIL]", b)
    if bad:
        return 1
    print("[PASS] M1 `move x` 被拒收（未定义名）")
    print("[PASS] M2 `move x = 1` 被拒收")
    print("[PASS] M3 `move := 1` 合法（关键字已退役，拼写进入普通名字域）")
    print("[PASS] M4 源码与 grammar 无 T_MOVE / EXPR_MOVE / 'move'")
    print("4/4 通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
