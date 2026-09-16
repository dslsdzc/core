#!/usr/bin/env python3
"""TODO #2026-09-10-12 回归：函数体内嵌套 `fn` 声明 → 编译段错误 rc=139（2026-09-11 修复）。

语言面判定（为何修成「定位报错」而非「支持嵌套 fn」）：
  * grammar/core.ebnf：`TopLevelDecl = FunctionDecl | ...` 且
    `Statement = Expr ';' | LetStmt | ReturnStmt | YieldStmt | BreakStmt | ContinueStmt`
    —— 函数声明**只是顶层构造**，Statement 不含 FunctionDecl
    ⇒ 函数体内的嵌套 `fn` 不在语言面内。
  * bootstrap 参考实现（bootstrap/corec/frontend/parser.py）对同一输入给出定位错误
    `SyntaxError: 2:6: Unexpected token: fn`（不崩、不静默通过）。
  * docs/spec-design.md:341：实现层函数值（TYP_FN/闭包）按 YAGNI 挂起。
  ⇒ 正确修复 = 响亮定位错误（rc=1 + error[P21]），不是「支持」，更不是崩溃。
    （原 TODO 记的「判据 = 最小复现 rc=0」隐含「应支持」，与本判定冲突；
     本文件与 src/ci/run.sh 的 SKIP 理由一并记录裁决。）

RED（修复前实测 2026-09-11，核心版 0390f0f4）：
  * 最小件 `fn outer(){ fn inner(a:int)->int{return a+1;} return inner(1); }` rc=139，
    日志止于 `[3/5] parse...`（`[4/5]` 未打印）。
  * gdb -batch -ex run -ex "info registers" --args ./build/corec check ...
    → 崩点 `grow_ast` 内 `rep movsb`：rdi(目的地)=0、rcx=0x12000000
    （g_ast_cap=4M 节点 × ESZ_ASTNODE=72 = 288MB）。即 bump allocator 触顶后
    rt.s 的 .Lalloc_oom 返回 NULL，grow_ast 仍向 NULL 拷贝 ⇒ SIGSEGV。
  * 临时插桩（已移除，仅取证）在 parse_primary 的 struct 字面量循环打点：
    `SPIN_DIAG struct-literal-loop iter=500000 tokpos=1900 kind=0`
    （kind=0 = T_EOF）⇒ 自旋点 = 该循环，非 checker。

根因链（两处缺陷叠加）：
  1. 嵌套 `fn` 无诊断：parse_primary 无 T_FN 分支，落回通用兜底
     「Unexpected token in expression」——只消费 `fn` 一个 token，解析失步。
  2. 失步后 `int {`（内层 fn 的返回类型 + 函数体花括号）被当作 struct 字面量
     （IDENT + `{`）解析，把外层 `}` 当字段吃掉直至 EOF；而该循环只认 `}`，
     advance_tok 在 EOF 是空操作 ⇒ 自旋，每轮分配 AST 节点直至 OOM。

修复：
  1. parser.parse_stmt：语句位置遇 `fn`/`flow`（含 `pub fn`）→ P021 定位诊断 +
     花括号配平整段跳过该声明，后续语句恢复正常解析（不再失步）。
  2. parser 同族 6 处 `}`-键循环补 EOF 护栏（struct 字面量 / struct 模式 /
     struct 体 / enum 体 / interface 体 / impl 体）：失步至 EOF 一律退出。

判据：嵌套形态 rc=1 + error[P21] + 定位行号 + 无 139 + 毫秒级；失步型 EOF 探针
（各构造截断在 EOF）rc=1 且不崩；扁平对照 rc=0 且运行结果正确；两个 suite fixture
由 rc=139 变为 rc=1 + P21。
"""

import os
import resource
import subprocess
import tempfile
import time
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"

# 修复前该形态 ~12–16s 后 SIGSEGV；修复后毫秒级。阈值放宽以抗共享机负载。
BOUND_SEC = 5.0
PROC_TIMEOUT = 30

# 嵌套 fn 的最小件（TODO #2026-09-10-12 原文形态）
NESTED_MIN = """fn outer() -> int {
    fn inner(a: int) -> int { return a + 1; }
    return inner(1);
}

fn main() -> int { return outer(); }
"""

# 同逻辑扁平对照（语言面内形态）：inner(1) = 2 ⇒ 退出码 2
FLAT_CONTROL = """fn inner(a: int) -> int { return a + 1; }

fn outer() -> int {
    return inner(1);
}

fn main() -> int { return outer(); }
"""


def _no_core_dump():
    # core_pattern 为 systemd-coredump 管道时，崩溃的陷阱程序会挂起——禁用 core dump。
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def _write(source: str):
    fd, src = tempfile.mkstemp(suffix=".cr")
    with os.fdopen(fd, "w") as f:
        f.write(source)
    return src


def _check(source: str):
    """check 编译：返回 (returncode, output, elapsed)。"""
    src = _write(source)
    try:
        t0 = time.monotonic()
        r = subprocess.run(
            [str(COREC), "check", src],
            capture_output=True, text=True, cwd=BASE, timeout=PROC_TIMEOUT,
        )
        return r.returncode, r.stdout + r.stderr, time.monotonic() - t0
    finally:
        os.unlink(src)


def _build_run(source: str):
    """build + 运行：返回 (build_rc, run_rc, output)。"""
    src = _write(source)
    out = src[:-3]
    try:
        b = subprocess.run(
            [str(COREC), "build", src, "-o", out, "--static"],
            capture_output=True, text=True, cwd=BASE, timeout=PROC_TIMEOUT,
        )
        if b.returncode != 0:
            return b.returncode, None, b.stdout + b.stderr
        r = subprocess.run([out], capture_output=True, text=True, timeout=PROC_TIMEOUT)
        return 0, r.returncode, r.stdout + r.stderr
    finally:
        for p in (src, out):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


def case_reject_nested(name: str, source: str, fn_name: str = "inner"):
    """嵌套 fn 形态：rc=1 + error[P21] + 定位 + 无 139 + 有界耗时。"""
    rc, out, el = _check(source)
    problems = []
    if rc != 1:
        problems.append(f"rc={rc}（期望 1；139/负值 = 信号崩溃）")
    if "error[P21]" not in out:
        problems.append("缺 error[P21]")
    if fn_name and f"Nested function declaration '{fn_name}'" not in out:
        problems.append(f"缺诊断文本（'{fn_name}'）")
    if " --> " not in out:
        problems.append("缺定位（` --> line:col`）")
    if el > BOUND_SEC:
        problems.append(f"耗时 {el:.2f}s > {BOUND_SEC}s（自旋未除）")
    if problems:
        return f"FAIL {name}: " + "; ".join(problems) + "\n--- output ---\n" + out
    return None


def case_reject_desync(name: str, source: str):
    """失步型输入截断在 EOF：必须 rc=1（或非零）收场，绝不 139 / 挂死。"""
    rc, out, el = _check(source)
    problems = []
    if rc == 0:
        problems.append("rc=0（期望拒绝）")
    if rc < 0 or rc == 139:
        problems.append(f"rc={rc}（信号崩溃 = 回归）")
    if el > BOUND_SEC:
        problems.append(f"耗时 {el:.2f}s > {BOUND_SEC}s（EOF 自旋未除）")
    if problems:
        return f"FAIL {name}: " + "; ".join(problems) + "\n--- output ---\n" + out
    return None


def main() -> int:
    _no_core_dump()
    failures = []
    checks = 0

    # ① 主判据：TODO #2026-09-10-12 最小复现形态（修复前 rc=139）
    checks += 1
    f = case_reject_nested("nested_min_todo16", NESTED_MIN, "inner")
    if f:
        failures.append(f)

    # ② suite fixture 两例（修复前 rc=139；现应指向 P21 诊断）
    for fx in ("at_test_mini4", "at_test_mini6"):
        checks += 1
        path = BASE / "tests" / "suite" / f"{fx}.cr"
        src = path.read_text()
        f = case_reject_nested(f"fixture_{fx}", src, "add")
        if f:
            failures.append(f)

    # ③ 变体：@inline 调用形 / 无 @inline 形 / pub 前缀 / 双层嵌套 / 嵌套后仍有语句
    variants = [
        ("nested_inline_hint", """import io

fn test_inline_hint() -> int {
    fn add(a: int, b: int) -> int { return a + b; }
    result := @inline(add)(3, 4);
    if result != 7 { return 1; }
    return 0;
}

fn main() -> int { return test_inline_hint(); }
""", "add"),
        ("nested_plain_call", """fn test() -> int {
    fn add(a: int, b: int) -> int { return a + b; }
    return add(3, 4);
}

fn main() -> int { return test(); }
""", "add"),
        ("nested_pub_fn", """fn outer() -> int {
    pub fn inner() -> int { return 1; }
    return inner();
}

fn main() -> int { return outer(); }
""", "inner"),
        ("nested_double", """fn outer() -> int {
    fn mid() -> int {
        fn deep() -> int { return 1; }
        return deep();
    }
    return mid();
}

fn main() -> int { return outer(); }
""", "mid"),
        ("nested_then_stmt", """fn outer() -> int {
    fn inner() -> int { return 1; }
    x := 41;
    return x + 1;
}

fn main() -> int { return outer(); }
""", "inner"),
    ]
    for name, src, fn_name in variants:
        checks += 1
        f = case_reject_nested(name, src, fn_name)
        if f:
            failures.append(f)

    # ④ 失步型 EOF 探针（修复前同族 139：自旋 + 分配 → OOM → NULL 拷贝）
    desync = [
        ("eof_struct_literal_open", "fn main() -> int {\n    x := Foo{\n"),
        ("eof_struct_literal_tokens", "fn main() -> int {\n    x := Foo{ a\n"),
        ("eof_struct_decl_body", "struct S { a: int\n"),
        ("eof_enum_decl_body", "enum E { A,\n"),
        ("eof_impl_body", "struct S { a: int }\nimpl S {\n"),
        ("eof_interface_body", "interface I {\n"),
        ("eof_fn_param_list", "fn main() -> int {\n"),
        ("eof_match_struct_pat", """fn main() -> int {
    match 1 {
        Foo { a
"""),
    ]
    for name, src in desync:
        checks += 1
        f = case_reject_desync(name, src)
        if f:
            failures.append(f)

    # ⑤ 正控：同逻辑扁平形态必须 rc=0 且运行结果正确（防「把语言面内的东西一起禁掉」）
    checks += 1
    brc, rrc, out = _build_run(FLAT_CONTROL)
    if brc != 0 or rrc != 2:
        failures.append(
            f"FAIL flat_control: build_rc={brc} run_rc={rrc}（期望 0 / 2）\n--- output ---\n{out}"
        )

    total = checks - len(failures)
    print(f"{total}/{checks} passed")
    for f in failures:
        print(f)
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
