#!/usr/bin/env python3
"""字符串插值 `${...}`：**词法契约 + 展开语义**判据（自举前端；批 8 插队修复 + 展开）。

**为什么有这一档**：本特性修复前**全域零覆盖**——`tests/` 与 `examples/` 里 `grep '\\${'` = **0 命中**，
`src/` 唯一命中是 `src/lsp/analysis.cr:1024` 的注释 ⇒ 它烂掉约两个月没人知道（这条判据存在的理由）。

**修复前实测（词法根因）**：`lexer.cr` 插值分支**双推进**（skip 循环已到 `}` 之后，循环尾通用
`_pos = _pos + 1` 又吃一字节）⇒ ① `}` 后首字符静默丢（`"A${7}B"` 取回值 = `A`）；② 若那正是收尾引号
⇒ 串吞到**行尾** ⇒ 同行 `;`/`}` 一并进串 ⇒ parser 停在嵌套态 ⇒ 顶层 `fn` **P21 级联**（实测单行 15 条，
`}` 换行 0 条）。引入点 = `wqorlmrz`（2026-07-09，其父修订无 "Interpolation"）。

**本批两步**：① **词法修复**（分支自行推进 + `continue` 收口，原文逐字进串值——即**修复前后一版是
「原文保留」的静默空转**，该语义保留为本档的对照腿 / 突变腿）；② **展开实现**（维护者裁定 (b)）：
lexer 把含洞字面量拆成 part（段 = T_STRING、洞 = T_INTERP，**洞内 `{}` 配平**、洞内字符串整体跳过），
parser 串成 `seg + hole + seg` 链（**只连同一字面量的 part**），checker 按洞类型**就地改写**转换：
`string` 恒等 · `int → int_str` · `bool → bool_str`（**不经 int**——遵「bool 不隐式转 int」裁定）·
其它（`dex` 两表示 / `char` / 结构体…）⇒ **P028 硬错**；畸形插值（未闭合 / `${}` 空 / 洞内尾随垃圾）⇒ **P027 硬错**。

**⚠ bootstrap 面分歧（已知、已登记）**：bootstrap lexer 仍按「原文逐字进串值」处理 `${...}`（不展开）
⇒ 两前端对含插值源的语义**不同**（本档 D 组把该事实**记为事实**，不是相等判据）。

**突变自证（可复跑）**：`COREC_BIN=<展开前二进制> python3 tests/selfhost/test_string_interp.py`
⇒ B 组按「原文保留」全红（= 判据命中目标）；`<修复前二进制>` ⇒ A/B 两组皆红。
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

PRELUDE = ('import io\nimport fmt\nstruct S { f: int }\n'
           'fn f(v: int) -> int { return v * 3; }\n'
           'fn g(s: string) -> int { return str_len(s); }\nfn f42(c: int) -> int { return 42; }\n')

# (名, 串字面量, 期望值, 备注) —— 值 = **展开后**语义
VALUES = [
    ("plain", "plain", "plain", "对照：无插值"),
    ("var", "x=${n}", "x=7", "变量（int ⇒ int_str）"),
    ("expr", "${1 + 2}", "3", "表达式"),
    ("bool_true", "${b}", "true", "bool ⇒ bool_str（**不经 int**）"),
    ("string_identity", "s=${str}", "s=S", "string ⇒ 恒等"),
    ("multi", "${n}-${n}", "7-7", "多段/多洞"),
    ("adjacent", "${n}${str}", "7S", "相邻插值"),
    ("nested_call", "${f(n)}", "21", "洞内嵌套调用"),
    ("nested_braces", "${S{f=1}.f}", "1", "洞内花括号配平（结构体字面量 + 字段访问）"),
    ("escaped", "\\${n}", "${n}", "`\\${` = 字面 `$` 且**不触发**插值"),
    # ── 扫描硬化三例（对抗复核点名的「手写 `{}` 计数」漏点；lexer 洞扫描现跳过这三类）──
    # 洞内 char 字面量：用「返回常量」的函数 ⇒ 值与该 char 的运行期表示无关（只测扫描不被 `'}'` 截断）
    ("char_lit_in_hole", "${f42('}')}", "42", "洞内 char 字面量 `'}'` 不得截断洞扫描（f42 返常量，避开 char 表示面）"),
    ("nested_str_in_hole", '${g("}!")}', "2", "洞内嵌套字符串整体跳过（含其内花括号；g 返回 str_len ⇒ 期望 2 = '}!' 的长度）"),
    ("block_comment_in_hole", "${n /* } */ }", "7", "洞内块注释整体跳过（含其内 `}`）"),
]


def build_run(lit, extra_prelude="", extra_body=""):
    src = (PRELUDE + extra_prelude +
           'fn main() -> int {\n'
           '    n := 7;\n'
           '    b := true;\n'
           '    str := "S";\n'
           '    s := "%s";\n'
           '    println(s);\n'
           '%s'
           '    return 0;\n'
           '}\n') % (lit, extra_body)
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as fh:
        fh.write(src)
        path = fh.name
    out = str(BASE / "build" / f"_interp_{uuid.uuid4().hex[:8]}")
    try:
        b = subprocess.run([COREC, "build", path, "-o", out, "--static"], cwd=BASE,
                           capture_output=True, text=True, timeout=300)
        p21 = len(P21.findall(b.stdout + b.stderr))
        val = None
        if b.returncode == 0 and Path(out).exists():
            r = subprocess.run([out], capture_output=True, text=True, timeout=60)
            val = r.stdout.rstrip("\n")
        return b.returncode, val, p21, b.stdout + b.stderr
    finally:
        for p in (path, out, out + ".ccr"):
            if os.path.exists(p):
                os.unlink(p)


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

    # A 解析完整性：插值**同一行**含 `}`/后续语句 ⇒ 不得 P21 级联，且同行后续语句仍生效
    same_line = [
        ("same_line_return", 'fn main() -> int { s := "x=${7}"; return 7; }', 7),
        ("same_line_if", 'fn main() -> int { s := "A${7}"; if 1 == 1 { return 5; } return 0; }', 5),
        ("same_line_call", 'import io\nimport fmt\nfn main() -> int { println("n=${7}"); return 3; }', 3),
    ]
    for name, src, want_rc in same_line:
        with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as fh:
            fh.write(src + "\n")
            path = fh.name
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

    # B 展开语义（值判据）
    for name, lit, want, note in VALUES:
        rc, val, p21, out = build_run(lit)
        print(f"[B {name}] 期望=[{want}] 实测=[{val}] build_rc={rc} P21={p21}  ({note})")
        expect(f"B.{name}.value", val == want, f"得 {val!r}（build_rc={rc}）")

    # B' 实参位 / let 初值（位置形态）
    rc, val, p21, out = build_run("v=${n}", extra_body='    println(int_str(g(s)));\n')
    last = (val or "").splitlines()[-1] if val else None
    print(f"[B arg_position] 串作实参 g(s) ⇒ 末行={last}（整输出=[{val}]）build_rc={rc}")
    expect("B.arg_position", last == "3", f"得 {val!r}（期望末行 3 = 'v=7' 长度）")

    # C 错误面：畸形插值 P027 · 不支持类型 P028（check rc=1 + 码 + build rc=1 + 零产物）
    errs = [
        ("unclosed_newline", "x=${n", "P27", "未闭合（**换行终止**形态）"),
        ("empty", "x=${}", "P27", "空洞 `${}`"),
        ("linecomment_hole", "x=${n // }", "P27", "洞内行注释 ⇒ 本行无配对 `}` ⇒ 未闭合"),
        ("struct_type", "${S{f=1}}", "P28", "不支持类型（结构体）"),
        ("dex_scaled", "${d}", "P28", "不支持类型（dex **scaled** 形态）"),
        ("dex_bits", "${db}", "P28", "不支持类型（dex **bits**（apx）形态）"),
    ]
    # 泛型洞（真泛型上下文；洞型在实例化前不可得 ⇒ P028 + 未覆盖面）
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as fh:
        fh.write(PRELUDE + 'fn h[T](x: T) -> string { return "${x}"; }\n'
                 'fn main() -> int { return 0; }\n')
        gpath = fh.name
    gout = str(BASE / "build" / f"_interp_{uuid.uuid4().hex[:8]}")
    try:
        chk = subprocess.run([COREC, "check", gpath], cwd=BASE, capture_output=True, text=True, timeout=180)
        diag = "error[P28]" in chk.stdout
        bld = subprocess.run([COREC, "build", gpath, "-o", gout, "--static"], cwd=BASE,
                             capture_output=True, text=True, timeout=300)
        art = os.path.exists(gout) or os.path.exists(gout + ".ccr")
        print(f"[C generic_hole] check_rc={chk.returncode} 诊断={diag} build_rc={bld.returncode} 产物={art}")
        expect("C.generic_hole.reject", chk.returncode == 1 and diag and bld.returncode == 1 and not art,
               f"check={chk.returncode} diag={diag} build={bld.returncode} art={art}")
    finally:
        for q in (gpath, gout, gout + ".ccr"):
            if os.path.exists(q):
                os.unlink(q)

    for name, lit, code, note in errs:
        pre = "    d : dex = 1.5;\n    db : dex, apx = 1.5;\n    t : int = 7;\n"
        with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as fh:
            fh.write(PRELUDE + 'fn main() -> int {\n    n := 7;\n' + pre + f'    s := "{lit}";\n    return 0;\n}}\n')
            path = fh.name
        out = str(BASE / "build" / f"_interp_{uuid.uuid4().hex[:8]}")
        try:
            chk = subprocess.run([COREC, "check", path], cwd=BASE, capture_output=True, text=True, timeout=180)
            diag = f"error[{code}]" in chk.stdout
            bld = subprocess.run([COREC, "build", path, "-o", out, "--static"], cwd=BASE,
                                 capture_output=True, text=True, timeout=300)
            art = os.path.exists(out) or os.path.exists(out + ".ccr")
            print(f"[C {name}] check_rc={chk.returncode} 诊断={diag} build_rc={bld.returncode} 产物={art}  ({note})")
            expect(f"C.{name}.reject", chk.returncode == 1 and diag and bld.returncode == 1 and not art,
                   f"check={chk.returncode} diag={diag} build={bld.returncode} art={art}")
        finally:
            for p in (path, out, out + ".ccr"):
                if os.path.exists(p):
                    os.unlink(p)

    # D 事实记录：bootstrap lexer 仍「原文保留」（不展开）⇒ 两前端**分歧**（已知、登记）
    sys.path.insert(0, str(BASE / "bootstrap"))
    try:
        from corec.frontend.lexer import Lexer
        toks = Lexer('s := "x=${n}";').tokenize()
        lexeme = [t.lexeme for t in toks if getattr(t.type, "name", "") == "STRING_LIT"]
        print(f"[D bootstrap 面] lexeme={lexeme}（**未展开**：本批只改自举前端；分歧已登记）")
        expect("D.bootstrap_unexpanded_fact", lexeme == ["x=${n}"], f"得 {lexeme}")
    except Exception as e:  # noqa: BLE001
        expect("D.bootstrap_unexpanded_fact", False, f"bootstrap 导入失败：{e}")

    # E 回退守卫（源码形状；**非**突变自证——突变自证见档头 COREC_BIN 配方）
    lex_src = (BASE / "src" / "compiler" / "lexer.cr").read_text(encoding="utf-8")
    p_src = (BASE / "src" / "compiler" / "parser.cr").read_text(encoding="utf-8")
    c_src = (BASE / "src" / "compiler" / "checker.cr").read_text(encoding="utf-8")
    expect("E.lexer_emits_interp_tok", "add_tok_str(T_INTERP" in lex_src, "lexer 未发 T_INTERP")
    expect("E.parser_interp_run", "fn parse_interp_run()" in p_src, "parser 无 parse_interp_run")
    expect("E.checker_rewrites_hole", "EXPR_INTERP_HOLE" in c_src, "checker 无洞改写")
    expect("E.bool_str_present", "fn bool_str" in (BASE / "src" / "stdlib" / "fmt.cr").read_text(encoding="utf-8"),
           "fmt.cr 无 bool_str")

    print(("STRING-INTERP " + ("PASS" if ok else "FAIL")) + f" · 失败项 = {fails}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
