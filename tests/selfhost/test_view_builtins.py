#!/usr/bin/env python3
"""2(a) 视图内建（`@ptr_of` / `@str_of`）——**两面一致性 + 零代码生成 + fail-closed + 安全面**判据。

**语义（本批口径）**：视图内建 = **同一个 64 位字的两种看法**（零转换、零拷贝、零运行期动作）：
    `@ptr_of(s: string) -> int`  ·  `@str_of(p: int) -> string`
它不是类型转换：`@ptr_of(@str_of(p)) == p` 对**任意**字成立（本判据的 ok 腿就是这么测的——值 42
既不是有效指针也不是有效 intern 索引，任何真转换/真解引用都会在此暴露）。

**为什么必须有「两面」判据**（team-lead 硬要求①）：
自源（`src/compiler/*.cr`、`src/stdlib/*.cr`）**必须能被 Python bootstrap 编**——
bootstrap 面缺一条产生式，构建期就红（本批已实测过同族两次：`as`、`|`/`&`）。
⇒ 新增内建必须在**两面**都是同一套语义与同一套拒绝规则，只测一面 = 把「自源写不出」留到构建期才炸。

**硬要求②（零代码生成）**：不得靠类比 `@addr(fn)` 论证，必须**由判据证明**——
本档的「往返擦除」腿：`f(p) = @ptr_of(@str_of(p))` 与 `f(p) = p` 的产物（ELF）**逐字节一致**。

**硬要求③（fail-closed）**：未知名两面都必须报错，不得静默当 0。

**安全面（裁 (ii)）**：视图内建**必须出现在 `unsafe` 块内**，块外 ⇒ 两面都硬错（不做软约束）。
"""

import hashlib
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"
BOOTSTRAP = BASE / "bootstrap"

# ── 探针 ─────────────────────────────────────────────────────────────────────
# ok 腿：视图往返。42 既不是有效指针、也不是有效 intern 索引 ⇒ 「视图 = 换看法」成立才可能 = 42。
# （若实现里偷偷做了解引用/查表，本腿在任一运行期腿都会崩或给别的值。）
VIEW_ROUNDTRIP = """fn main() -> int {
    p : ., mut = 42;
    q : ., mut = 0;
    unsafe { s := @str_of(p); q = @ptr_of(s); }
    return q;
}
"""

# 零代码生成（擦除）：两侧**除函数体首行外逐字相同**，函数名/签名也相同
# ⇒ 视图若真被擦除，ELF 应逐字节一致。
# ⚠ 对照必须**同处 `unsafe` 包络内**：实测 `unsafe { return p; }` 与 `return p;` 的 ELF **不同**
#   （`.ccr` 差 +158B = SG_UNSAFE 区域元数据；那是区域面既有效应，与视图无关）⇒
#   跨包络对照测的是 `unsafe` 而不是视图。字符串侧同理用「往返三跳」对照「单跳」。
ERASE_INT_VIEW = """fn f(p: int) -> int {
    unsafe { return @ptr_of(@str_of(p)); }
}
fn main() -> int { return f(42); }
"""
ERASE_INT_PLAIN = """fn f(p: int) -> int {
    unsafe { return p; }
}
fn main() -> int { return f(42); }
"""
ERASE_STR_VIEW = """fn f(s: string) -> int {
    unsafe { return @ptr_of(@str_of(@ptr_of(s))); }
}
fn main() -> int { return f("hi") / 1000000000; }
"""
ERASE_STR_ONE = """fn f(s: string) -> int {
    unsafe { return @ptr_of(s); }
}
fn main() -> int { return f("hi") / 1000000000; }
"""

# 安全面 (ii)：块外 ⇒ 两面都硬错
OUTSIDE_UNSAFE = """fn main() -> int {
    p : ., mut = 42;
    s := @str_of(p);
    return 0;
}
"""

# fail-closed③：未知名 ⇒ 两面都报错
UNKNOWN_BUILTIN = """fn main() -> int {
    p : ., mut = 42;
    unsafe { q := @view_of(p); }
    return 0;
}
"""

# 实参类型：`@ptr_of` 只收 string、`@str_of` 只收 int
ARG_TYPE_PTR = """fn main() -> int {
    p : ., mut = 42;
    unsafe { n := @ptr_of(p); }
    return 0;
}
"""
ARG_TYPE_STR = """fn main() -> int {
    s := "hi";
    unsafe { n := @str_of(s); }
    return 0;
}
"""


def _sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def bootstrap_pipeline(src: str):
    """bootstrap 面：跑完整前端管线（lex→parse→resolve→desugar→check→ir_gen），返回 (errors, ir_ok)。"""
    if str(BOOTSTRAP) not in sys.path:
        sys.path.insert(0, str(BOOTSTRAP))
    from corec.frontend.lexer import Lexer
    from corec.frontend.parser import Parser
    from corec.frontend.name_resolver import NameResolver
    from corec.frontend.desugar import MatchDesugarer
    from corec.frontend.type_checker import TypeChecker
    from corec.frontend.ir_gen import IRGen
    from corec.utils.module_loader import resolve_imports

    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as f:
        f.write(src)
        path = f.name
    try:
        errors = []
        try:
            ast = Parser(Lexer(src).tokenize()).parse_compilation_unit()
            resolve_imports(ast)
            resolver = NameResolver()
            resolver.resolve(ast)
            desugarer = MatchDesugarer(resolver.symtab)
            ast = desugarer.desugar(ast)
            checker = TypeChecker(resolver.symtab)
            checker.check(ast)
            errors = list(resolver.errors) + list(checker.errors)
            ir_ok = True
            if not errors:
                IRGen(resolver.symtab).gen_module(ast)
        except Exception as e:  # 语法/管线异常按「面报错」计入（不是崩溃）
            errors = list(errors) + [f"{type(e).__name__}: {e}"]
            ir_ok = False
        return errors, ir_ok
    finally:
        os.unlink(path)


def bootstrap_run_value(src: str):
    """bootstrap 面 · 运行值：管线 ⇒ **bootstrap 自带解释器**跑 main，返回其返回值。

    为什么用 bootstrap 解释器而不是汇编链接成 ELF：`rt.s` 的 `runtime.o` 引用一堆支持符号
    （`hp_load_config`/`sched_*`/`chan_*`/`g_free`…），探针要独立链接必须把整套 stdlib 一起编 ——
    那是「探针环境」问题，不是**编译器两面**的差异。解释器腿同样走 bootstrap 的 ir_gen ⇒
    「同一探针在两面得到同一个值」这条判据 ✓ 成立（自托管面另有解释器 + 原生两条腿）。
    """
    if str(BOOTSTRAP) not in sys.path:
        sys.path.insert(0, str(BOOTSTRAP))
    from corec.frontend.lexer import Lexer
    from corec.frontend.parser import Parser
    from corec.frontend.name_resolver import NameResolver
    from corec.frontend.desugar import MatchDesugarer
    from corec.frontend.type_checker import TypeChecker
    from corec.frontend.ir_gen import IRGen
    from corec.backend.interpreter import Interpreter
    from corec.utils.module_loader import resolve_imports

    ast = Parser(Lexer(src).tokenize()).parse_compilation_unit()
    resolve_imports(ast)
    resolver = NameResolver()
    resolver.resolve(ast)
    ast = MatchDesugarer(resolver.symtab).desugar(ast)
    checker = TypeChecker(resolver.symtab)
    checker.check(ast)
    if resolver.errors or checker.errors:
        raise RuntimeError(f"bootstrap 面有诊断：{resolver.errors} {checker.errors}")
    mod = IRGen(resolver.symtab).gen_module(ast)
    return Interpreter(mod).run("main", [])


def corec_check(src: str):
    """自托管面：`check` ⇒ (rc, 诊断行)。"""
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as f:
        f.write(src)
        path = f.name
    try:
        env = dict(os.environ)
        env.pop("CORE_S1P", None)
        subprocess.run([str(COREC), "clean-cache"], cwd=BASE, capture_output=True, timeout=120)
        r = subprocess.run([str(COREC), "check", path], cwd=BASE, env=env,
                           capture_output=True, text=True, timeout=300)
        diags = [l for l in r.stdout.split("\n") if re.match(r"^error\[", l)]
        return r.returncode, diags
    finally:
        os.unlink(path)


def corec_run(src: str):
    """自托管面 · 解释器腿：`corec run <源码文本>`（**注意：run 收内联源码，不是文件路径**——
    传路径会得到 `error: Unexpected token in expression`，那是探针错、不是编译器分歧）⇒ rc = 返回值。"""
    subprocess.run([str(COREC), "clean-cache"], cwd=BASE, capture_output=True, timeout=120)
    r = subprocess.run([str(COREC), "run", src], cwd=BASE, capture_output=True,
                       text=True, timeout=300)
    if r.returncode not in range(0, 256) or "error" in r.stdout[:200]:
        print(f"    [interp 诊断] rc={r.returncode} out={r.stdout.strip()[:160]!r} err={r.stderr.strip()[:160]!r}")
    return r.returncode


def corec_build_native(src: str):
    """自托管面 · 原生腿：`build --static` ⇒ (rc, ELF 路径)。"""
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as f:
        f.write(src)
        path = f.name
    out = Path(tempfile.mkdtemp()) / "probe"
    try:
        subprocess.run([str(COREC), "clean-cache"], cwd=BASE, capture_output=True, timeout=120)
        r = subprocess.run([str(COREC), "build", path, "-o", str(out), "--static"],
                           cwd=BASE, capture_output=True, text=True, timeout=600)
        if r.returncode != 0:
            return r.returncode, None
        return 0, out
    finally:
        os.unlink(path)


def main():
    ok = True
    fails = []

    def expect(name, cond, detail=""):
        nonlocal ok
        print(("  PASS  " if cond else "  FAIL  ") + name + ("" if cond else f"  ← {detail}"))
        if not cond:
            ok = False
            fails.append(name)

    # ── ① 两面一致：ok 腿（同一探针：自托管 check/run/native + bootstrap 管线/ELF） ──
    rc_c, diags_c = corec_check(VIEW_ROUNDTRIP)
    errs_b, ir_b = bootstrap_pipeline(VIEW_ROUNDTRIP)
    rc_i = corec_run(VIEW_ROUNDTRIP)
    rc_n, elf_n = corec_build_native(VIEW_ROUNDTRIP)
    rc_elf = subprocess.run([str(elf_n)], capture_output=True).returncode if elf_n else -1
    rc_b = bootstrap_run_value(VIEW_ROUNDTRIP)
    print(f"[① 两面一致·ok 腿] 自托管 check rc={rc_c} {diags_c} · 解释器 rc={rc_i} · native rc={rc_elf} "
          f"· bootstrap errors={errs_b} · bootstrap 运行值 {rc_b}")
    expect("ok_selfhost_check", rc_c == 0 and not diags_c, diags_c)
    expect("ok_bootstrap_pipeline", not errs_b and ir_b, errs_b)
    expect("ok_value_42_all_faces", rc_i == 42 and rc_elf == 42 and rc_b == 42,
           f"解释器 {rc_i} · native {rc_elf} · bootstrap {rc_b}")

    # ── ② 零代码生成（擦除）：往返写法 vs 直写，ELF 逐字节一致 ──
    _, elf_a = corec_build_native(ERASE_INT_VIEW)
    _, elf_b = corec_build_native(ERASE_INT_PLAIN)
    sha_view = _sha(elf_a) if elf_a else "n/a"
    sha_plain = _sha(elf_b) if elf_b else "n/a"
    print(f"[② 擦除·int] 往返写法 {sha_view[:16]}… · 直写 {sha_plain[:16]}…")
    expect("erase_int_view_byte_identical", elf_a and elf_b and sha_view == sha_plain,
           f"{sha_view} != {sha_plain}")

    _, elf_c = corec_build_native(ERASE_STR_VIEW)
    _, elf_d = corec_build_native(ERASE_STR_ONE)
    sha_view_s = _sha(elf_c) if elf_c else "n/a"
    sha_one_s = _sha(elf_d) if elf_d else "n/a"
    print(f"[② 擦除·string] 三跳 {sha_view_s[:16]}… · 单跳 {sha_one_s[:16]}…")
    expect("erase_str_view_byte_identical", elf_c and elf_d and sha_view_s == sha_one_s,
           f"{sha_view_s} != {sha_one_s}")

    # ── ③ fail-closed：未知名两面都报错 ──
    rc_u, diags_u = corec_check(UNKNOWN_BUILTIN)
    errs_ub, _ = bootstrap_pipeline(UNKNOWN_BUILTIN)
    print(f"[③ fail-closed] 自托管 rc={rc_u} {diags_u} · bootstrap errors={errs_ub}")
    expect("unknown_selfhost_rejected", rc_u == 1 and any("unknown @ builtin" in d for d in diags_u),
           (rc_u, diags_u))
    expect("unknown_bootstrap_rejected", any("unknown @ builtin" in str(e) for e in errs_ub), errs_ub)

    # ── ④ 安全面 (ii)：块外 ⇒ 两面都硬错 ──
    rc_o, diags_o = corec_check(OUTSIDE_UNSAFE)
    errs_ob, _ = bootstrap_pipeline(OUTSIDE_UNSAFE)
    print(f"[④ unsafe 面] 自托管 rc={rc_o} {diags_o} · bootstrap errors={errs_ob}")
    expect("outside_unsafe_selfhost_rejected",
           rc_o == 1 and any("unsafe" in d for d in diags_o), (rc_o, diags_o))
    expect("outside_unsafe_bootstrap_rejected",
           any("unsafe" in str(e) for e in errs_ob), errs_ob)

    # ── ⑤ 实参类型：两面都报错 ──
    for nm, src in (("ptr_of", ARG_TYPE_PTR), ("str_of", ARG_TYPE_STR)):
        rc_t, diags_t = corec_check(src)
        errs_tb, _ = bootstrap_pipeline(src)
        print(f"[⑤ 实参类型 {nm}] 自托管 rc={rc_t} {diags_t} · bootstrap errors={errs_tb}")
        expect(f"argtype_{nm}_selfhost_rejected", rc_t == 1 and bool(diags_t), (rc_t, diags_t))
        expect(f"argtype_{nm}_bootstrap_rejected", bool(errs_tb), errs_tb)

    print(("VIEW BUILTINS " + ("PASS" if ok else "FAIL")) + f" · 失败项 = {fails}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
