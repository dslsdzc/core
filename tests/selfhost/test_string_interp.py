#!/usr/bin/env python3
"""字符串插值 `${...}` 的**词法契约**判据（自举前端；2026-09-18 批 8 插队修复）。

**为什么有这一档**：本特性在修复前**全域零覆盖**——`tests/` 与 `examples/` 里 `grep '\\${'` = **0 命中**，
`src/` 唯一命中是 `src/lsp/analysis.cr:1024` 的注释 ⇒ 它烂掉没人知道（这条判据存在的理由）。

**修复前实测（根因）**：`lexer.cr` 插值分支**双推进**——分支内 skip 循环已推进到 `}` 之后，循环尾那句
**通用** `_pos = _pos + 1` 又吃一字节 ⇒ ① `}` 后第一个字符静默丢失（`"A${7}B"` 得 `A`）；
② 若那正是**收尾引号** ⇒ 串不以引号结束、一路吞到**行尾** ⇒ 同行的 `;` 与 **`}`** 一并进串 ⇒ parser
停在嵌套态 ⇒ 其后每个顶层 `fn` 报 **P21 级联**（实测单行 `fn main() -> int { s := "x=${7}"; return 0; }`
= **15 条 P21**；把 `}` 换行 = **0 条** ⇒ 判别实验）。引入点 = `wqorlmrz`（2026-07-09，本分支加入处；
其父修订里 "Interpolation" 出现 0 次）。

**本档判据（三层）**：
- **A 解析完整性**：插值所在**同一行**含 `}`/后续语句时，**不得**出现 P21 级联；程序照常编译运行（rc 判据）。
- **B 语义（现状钉住）**：本前端**不展开**插值——**原文逐字进串值**（与 bootstrap 词法一致：
  bootstrap lexer 对 `"A${7}B"` 产出的 token lexeme = `A${7}B`，实测）。⇒ 展开与否属**另案**；
  本档把「不展开但**不丢字**」钉死，防止再退回静默丢字。
- **C 两前端一致**：逐例把自举侧串值与 **bootstrap 词法 lexeme** 对拍（跨前端契约）。

**突变自证（可复跑）**：`COREC_BIN=/tmp/lexpre/build/corec python3 tests/selfhost/test_string_interp.py`
——指向**修复前**二进制（同一 develop 源码 + 回退 lexer.cr）⇒ 本档**必须红**（A/B 两组至少一击）；
绿 = 突变打空（未命中目标）。默认 `COREC_BIN` 缺省 = 本仓 `build/corec`。
"""

import os
import re
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = os.environ.get("COREC_BIN") or str(BASE / "build" / "corec")
P21 = re.compile(r"error\[P21\]")

# (名, 串字面量, 期望串值 = 原文, 备注)
LITERALS = [
    ("plain", "plain", "plain", "对照：无插值"),
    ("var", "x=${n}", "x=${n}", "变量"),
    ("expr", "${1 + 2}", "${1 + 2}", "表达式（含空格，原文保留）"),
    ("multi", "${a}-${b}", "${a}-${b}", "多段"),
    ("adjacent", "${a}${b}", "${a}${b}", "相邻插值"),
    ("nested_call", "${f(1)}", "${f(1)}", "嵌套调用"),
    ("nested_braces", "${S{f=1}}", "${S{f=1}}", "嵌套花括号（扫至**首个** `}`，其余逐字进串）"),
    ("escape_mix", "a\\n${n}\\tb", "a\n${n}\tb", "转义与插值混排（`\\n`/`\\t` 仍生效）"),
]


def build_run(lit, body_extra=""):
    """写临时源（含 `import io` + println）→ build → run，返回 (rc, 打印值, P21 数)。"""
    src = ('import io\n'
           'fn main() -> int {\n'
           '    n := 7;\n'
           '    a := "A";\n'
           '    b := "B";\n'
           '    s := "%s";\n'
           '    println(s);\n'
           '%s'
           '    return 0;\n'
           '}\n') % (lit, body_extra)
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as f:
        f.write(src)
        path = f.name
    out = str(BASE / "build" / f"_interp_{uuid.uuid4().hex[:8]}")
    try:
        b = subprocess.run([COREC, "build", path, "-o", out, "--static"], cwd=BASE,
                           capture_output=True, text=True, timeout=300)
        p21 = len(P21.findall(b.stdout + b.stderr))
        if b.returncode != 0 or not Path(out).exists():
            return b.returncode, None, p21
        r = subprocess.run([out], capture_output=True, text=True, timeout=60)
        return r.returncode, r.stdout.rstrip("\n"), p21
    finally:
        for p in (path, out, out + ".ccr"):
            if os.path.exists(p):
                os.unlink(p)


def same_line_cases():
    """A 组：插值**同一行**含 `}` 与后续语句 —— 修复前必 P21 级联 / 行为丢失。"""
    return [
        ("same_line_return", 'fn main() -> int { s := "x=${7}"; return 7; }', 7),
        ("same_line_if", 'fn main() -> int { s := "A${7}"; if 1 == 1 { return 5; } return 0; }', 5),
        ("same_line_call", 'import io\nfn main() -> int { println("A${7}"); return 3; }', 3),
    ]


def main():
    ok = True
    fails = []

    def expect(name, cond, detail):
        nonlocal ok
        print(("  PASS  " if cond else "  FAIL  ") + name + ("" if cond else f"  ← {detail}"))
        if not cond:
            ok = False
            fails.append(name)

    print(f"[二进制] {COREC}")
    # A 组：解析完整性（P21 级联 + 同行后续语句仍生效）
    for name, src, want_rc in same_line_cases():
        with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as f:
            f.write(src + "\n")
            path = f.name
        out = str(BASE / "build" / f"_interp_{uuid.uuid4().hex[:8]}")
        try:
            b = subprocess.run([COREC, "build", path, "-o", out, "--static"], cwd=BASE,
                               capture_output=True, text=True, timeout=300)
            p21 = len(P21.findall(b.stdout + b.stderr))
            rc = subprocess.run([out], capture_output=True, text=True, timeout=60).returncode \
                if Path(out).exists() else None
            print(f"[A {name}] build_rc={b.returncode} 运行_rc={rc} P21={p21}")
            expect(f"A.{name}.no_p21", p21 == 0, f"P21={p21}")
            expect(f"A.{name}.rc", rc == want_rc, f"期望 rc={want_rc}，得 {rc}")
        finally:
            for p in (path, out, out + ".ccr"):
                if os.path.exists(p):
                    os.unlink(p)

    # B 组：串值 = 原文（不展开、不丢字）
    for name, lit, want, note in LITERALS:
        rc, val, p21 = build_run(lit)
        print(f"[B {name}] 期望值=[{want}] 实测=[{val}] rc={rc} P21={p21}  ({note})")
        expect(f"B.{name}.value", val == want, f"得 {val!r}")

    # C 组：与 bootstrap 词法 lexeme 对拍（跨前端一致）
    sys.path.insert(0, str(BASE / "bootstrap"))
    try:
        from corec.frontend.lexer import Lexer
        agree = []
        for name, lit, want, _ in LITERALS:
            if "\\" in lit:
                continue  # 转义形两侧 lexeme 语义不同（此处只对原始形）
            toks = Lexer('s := "%s";' % lit).tokenize()
            lexeme = [t.lexeme for t in toks if getattr(t.type, "name", "") == "STRING_LIT"]
            agree.append((name, lexeme[0] if lexeme else None, want))
        bad = [(n, lx, w) for n, lx, w in agree if lx != w]
        print(f"[C bootstrap 对拍] {len(agree)} 例 · 不一致 {len(bad)}")
        for n, lx, w in bad:
            print(f"    {n}: bootstrap=[{lx}] 自举期望=[{w}]")
        expect("C.cross_frontend_lexeme", not bad, bad[:3])
    except Exception as e:  # noqa: BLE001
        expect("C.cross_frontend_lexeme", False, f"bootstrap 导入失败：{e}")

    # D 组：静默回退守卫（源码形状；**不是**突变自证——突变自证见档头 COREC_BIN 配方）
    lex_src = (BASE / "src" / "compiler" / "lexer.cr").read_text(encoding="utf-8")
    guard = re.search(r'cc == 36 && peek_at\(_src, _pos, _slen\) == 123 \{.*?\n\s*\}\s*continue;',
                      lex_src, re.S)
    print(f"[D 回退守卫] 插值分支以 `continue` 收口 = {bool(guard)}")
    expect("D.interp_branch_continues", bool(guard), "lexer.cr 插值分支未以 continue 收口（疑似回退）")

    print(("STRING-INTERP " + ("PASS" if ok else "FAIL")) + f" · 失败项 = {fails}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
