#!/usr/bin/env python3
"""R2 P3 Task 4：联合/可选（`T?` = `T ∪ null`；退役内建 Option 注册）行为覆盖集。

判据（语义见 docs/superpowers/plans/2026-09-11-r2-p3-capabilities.md Task 4 +
docs/superpowers/specs/2026-09-10-type-interface-unification-design.md §5.4）：

  正（**解释器 + ELF 双路径同值**）：`T ⊆ T?`（裸值 `return 5` 入 `int?` 返回位）/
      `null ⊆ T?`（`return None`）/ `Some(1)` 入 `int?` / `T?` 形参位 / `?` 解包回 T /
      `Some(x)` 与 `None` 的 match 两臂（运行时 tag 分派）
  负：`T? ⊄ T`（`fn f(x: int?) -> int { return x; }` ⇒ TF01——**方向性**：可选不是 T 的子类型）/
      `Option` 名退役（`Option[int]` 作类型 = 未定义泛型应用 rc=1——退役前该名由内建注册）
  硬门：`T?` 的 match 缺臂 ⇒ TM03 rc=1 + 具体反例名（'None' / 'Some'）+ 无产物
  登记：载荷**类型节点列**（T0 交接 ①）：`--verify-evp-nodes` 断言每槽有节点（bad=0），
      并数出裸码列丢失真实类型的槽数（collapses>0 = 节点列携带的信息量；旧布局裸码把
      非基型塌缩为 0 = TY_INT）
  表示面（R2 P4 Task 5，裁决 5「解包侧判表示」——本套件下半段）：可选槽配**表示位**
      （0 = 裸值 / 1 = 装箱，运行期值）：写点置位、解包点（`match` 的 Some/None 臂、
      `?`）分派——裸值路径**值即载荷**（Some 臂直取、不读 tag；None 臂不命中），装箱
      路径沿用既有 tag 分派 + 字段 fi+1。跨函数面（返回/形参）走隐藏全局信道（纯 IR）。
      **前置红态（B.7 一等条目）**：裸值 + `Some` 臂 = 双路径 SIGSEGV（check/build rc=0
      零诊断）——修复前后 rc 逐形态见任务报告。
  聚合面（**容量批 T2，裁-CAP-1 (a)「存储边界规范化」**）：结构体字段 / 数组·切片元素 /
      元组元素 / 枚举载荷 / 全局槽的可选值在**写点装箱**（裸 T 值 ⇒ Some(v)），读取侧
      零改动（既有装箱假定）。局部/形参/返回/调用结果仍走表示位机制（P4 T5，可持裸值）。
      **修复前**这四面的裸值形态是**响亮失败**（rc=139 双路径同，非静默）；本批转为正确值
      （下方 `uncovered_*` 四例为**重钉**，死亡证据 = 本批能力变更）。**未覆盖面（登记）**：
      指针写 `IR_STORE_PTR`（同一站点服务局部与聚合 + 别名不可静态闭合）、元组/数组字面量
      的非 ident/调用元素、泛型形参字段实例化为 `T?` 的形态。
"""

import os
import re
import resource
import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"


def _no_core_dump():
    # core_pattern 为 systemd-coredump 管道时，崩溃的陷阱程序会挂起——禁用 core dump。
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def _compile(source: str, cmd="build", extra=None):
    """返回 (result, out_path, src_path)；cmd = build（ELF 产物）| check（仅前端）。"""
    fd, src = tempfile.mkstemp(suffix=".cr")
    with os.fdopen(fd, "w") as f:
        f.write(source)
    out = src[:-3]
    if cmd == "build":
        args = [str(COREC), "build", src, "-o", out, "--static"]
    else:
        args = [str(COREC), "check", src]
    if extra:
        args += list(extra)
    r = subprocess.run(args, capture_output=True, text=True, cwd=BASE, timeout=180)
    return r, out, src


def _cleanup(*paths):
    for p in paths:
        try:
            os.unlink(p)
        except FileNotFoundError:
            pass


def build_and_run(source: str):
    """返回 (compile_result, run_result|None)。"""
    r, out, src = _compile(source)
    try:
        if r.returncode != 0:
            return r, None
        rr = subprocess.run(
            [out], capture_output=True, text=True, timeout=10,
            preexec_fn=_no_core_dump,
        )
        return r, rr
    finally:
        _cleanup(src, out, out + ".ccr")


def run_interp(source: str):
    """解释器路径（共享同一 run_frontend ⇒ 同一判定面）；rc = main 返回值。"""
    return subprocess.run(
        [str(COREC), "run", source], capture_output=True, text=True, cwd=BASE, timeout=180,
    )


def case_dual(name, source, expect_rc):
    """**双路径**（ELF 产物 + 解释器）同值断言——本任务主判据形。

    ⚠️ 附加 `check` rc=0 断言（**必要**，实测教训）：本仓库多数类型诊断（TF01/TA01…）是
    **软诊断**——`build` 路径 rc=0 + 产物照出，仅 `check` 因「有诊断即 rc=1」暴露。只断
    「build+run rc」会让「判定面整体失效」的突变**照样全绿**（M1 实测：注入失效后
    plain_value_into_optional 仍 PASS）。故正例 = 三路同证：check rc=0 ∧ build/run rc=N ∧ interp rc=N。
    """
    rc_chk, outc, srcc = _compile(source, cmd="check")
    try:
        if rc_chk.returncode != 0:
            print(f"[FAIL] {name}: check rc={rc_chk.returncode}（应有零诊断）: {rc_chk.stdout}{rc_chk.stderr}")
            return False
    finally:
        _cleanup(srcc, outc, outc + ".ccr")
    r, rr = build_and_run(source)
    if rr is None:
        print(f"[FAIL] {name}: compile rc={r.returncode}: {r.stdout}{r.stderr}")
        return False
    if rr.returncode != expect_rc:
        print(f"[FAIL] {name}: ELF expected rc {expect_rc}, got {rr.returncode}")
        return False
    ri = run_interp(source)
    if ri.returncode != expect_rc:
        print(f"[FAIL] {name}: interp expected rc {expect_rc}, got {ri.returncode}: {ri.stdout}{ri.stderr}")
        return False
    print(f"[PASS] {name}: ELF+interp rc={rr.returncode}")
    return True


def case_dual_rc(name, source, expect_rc):
    """双路径**同 rc**（不要求 check rc=0）：用于**未覆盖面登记**——钉「未覆盖面要么正确、
    要么响亮失败（elf rc == interp rc），**绝不静默分歧**」；rc=139 = 既有装箱假定下的
    响亮失败（非本任务面，逐形态实测见任务报告 §未覆盖面）。"""
    r, rr = build_and_run(source)
    if rr is None:
        print(f"[FAIL] {name}: compile rc={r.returncode}: {r.stdout}{r.stderr}")
        return False
    ri = run_interp(source)
    if rr.returncode != expect_rc or ri.returncode != expect_rc:
        print(f"[FAIL] {name}: expected rc {expect_rc} both paths, got ELF={rr.returncode} interp={ri.returncode}")
        return False
    print(f"[PASS] {name}: ELF+interp rc={rr.returncode}（未覆盖面：双路径同，响亮）")
    return True


def case_dual_softdiag(name, source, expect_rc, diag="B04"):
    """双路径同值 + check 面**已知软诊断**钉死（(A) 批新增面特有）。

    面特性：`p := &x` 借出 x 后**再读 x** ⇒ 既有 B04（`Cannot use 'x' while it is
    borrowed`）——**非本批引入**（T1 四形态探针同一诊断），属软诊断：`build` 路径
    rc=0 + 产物照出。判据 = 诊断码集**恰为** {diag}（多一条即红，防新诊断混入）
    ∧ build/ELF/interp 同值。
    """
    rc_chk, outc, srcc = _compile(source, cmd="check")
    try:
        codes = set(re.findall(r"error\[([A-Za-z0-9]+)\]", rc_chk.stdout + rc_chk.stderr))
        if codes != {diag}:
            print(f"[FAIL] {name}: check 诊断码集 {sorted(codes)} != ['{diag}'] (rc={rc_chk.returncode})")
            return False
    finally:
        _cleanup(srcc, outc, outc + ".ccr")
    r, rr = build_and_run(source)
    if rr is None:
        print(f"[FAIL] {name}: compile rc={r.returncode}: {r.stdout}{r.stderr}")
        return False
    if rr.returncode != expect_rc:
        print(f"[FAIL] {name}: ELF expected rc {expect_rc}, got {rr.returncode}")
        return False
    ri = run_interp(source)
    if ri.returncode != expect_rc:
        print(f"[FAIL] {name}: interp expected rc {expect_rc}, got {ri.returncode}: {ri.stdout}{ri.stderr}")
        return False
    print(f"[PASS] {name}: ELF+interp rc={rr.returncode}（check 面既有软诊断 {diag} 钉死）")
    return True


def case_reject(name, source, needles, cmd="build"):
    r, out, src = _compile(source, cmd)
    try:
        if r.returncode == 0:
            print(f"[FAIL] {name}: expected rejection, got rc=0（静默通过面复活）")
            return False
        text = r.stdout + r.stderr
        for n in needles:
            if n not in text:
                print(f"[FAIL] {name}: rc={r.returncode} 但缺诊断 {n!r}: {text}")
                return False
        if cmd == "build" and os.path.exists(out):
            print(f"[FAIL] {name}: 拒绝编译却仍产出二进制 {out}")
            return False
        print(f"[PASS] {name}: rc={r.returncode} + {needles!r}")
        return True
    finally:
        _cleanup(src, out, out + ".ccr")


def case_evp(name, source, needles):
    """载荷类型节点列**入库断言**（隐藏调试通道 `--verify-evp-nodes`；T0 交接 ① 的判据）。"""
    r, out, src = _compile(source, cmd="check", extra=["--verify-evp-nodes"])
    try:
        if r.returncode != 0:
            print(f"[FAIL] {name}: verify rc={r.returncode}: {r.stdout}{r.stderr}")
            return False
        text = r.stdout + r.stderr
        for n in needles:
            if n not in text:
                print(f"[FAIL] {name}: 缺 {n!r}: {text}")
                return False
        print(f"[PASS] {name}: rc=0 + {needles!r}")
        return True
    finally:
        _cleanup(src, out, out + ".ccr")


# ── 源形 ──────────────────────────────────────────────────────────────

# 裸值入 T?（`int ⊆ int ∪ null`）：判定点注入面（type_compat_strict 的可选目标分支）
PLAIN_INTO_OPT = """fn g() -> int? { return 5; }
fn main() -> int { return 42; }
"""
NONE_INTO_OPT = """fn g() -> int? { return None; }
fn main() -> int { return 42; }
"""
SOME_INTO_OPT = """fn g() -> int? { return Some(1); }
fn main() -> int { return 42; }
"""
# T? 形参位 + `?` 解包（EXPR_TRY 按类型项结构）
UNWRAP_SRC = """fn f(x: int?) -> int { return x?; }
fn main() -> int { return f(3); }
"""
# 运行时两形态：Some 值（枚举对象 + tag）与 None
SOME_FLOW = """fn g() -> int? { return Some(1); }
fn main() -> int { v := g(); return match v { Some(x) => x + 100, None => 0, }; }
"""
NONE_FLOW = """fn g() -> int? { return None; }
fn main() -> int { v := g(); return match v { Some(x) => x + 100, None => 7, }; }
"""

# ── R2 P4 Task 5（裁决 5：解包侧判表示）：B.7 四形态 + 跨函数面 ──────────────
# 语义口径：裸值入 `T?` = 该值本身（`T ⊆ T?`）⇒ Some 臂**命中**且载荷 = 裸值。
BARE_SOME_ARM = """fn main() -> int { x : int? = 5; return match x { Some(v) => { return v; } None => { return 0; } }; }
"""
BARE_SOME_WILDCARD = """fn main() -> int { x : int? = 5; return match x { Some(v) => { return v; } _ => { return 6; } }; }
"""
BARE_MATCH_EXPR = """fn main() -> int { x : int? = 5; y := match x { Some(v) => v, None => 0, }; return y; }
"""
BARE_WILDCARD = """fn main() -> int { x : int? = 5; return match x { _ => { return 7; } }; }
"""
BARE_THEN_BOXED_WRITE = """fn main() -> int { x : int? = 5; x = Some(7); return match x { Some(v) => { return v; } None => { return 0; } }; }
"""
BOXED_THEN_BARE_WRITE = """fn main() -> int { x : int? = Some(7); x = 3; return match x { Some(v) => { return v; } None => { return 0; } }; }
"""
# 条件写：同一槽两条路径两种表示 ⇒ 表示位必须是**运行期值**（静态收窄无法覆盖）
COND_ON = """fn main() -> int { x : int? = 5; c := 1; if c > 0 { x = Some(4); } return match x { Some(v) => { return v; } None => { return 0; } }; }
"""
COND_OFF = """fn main() -> int { x : int? = 5; c := 0; if c > 0 { x = Some(4); } return match x { Some(v) => { return v; } None => { return 0; } }; }
"""
# 跨函数面（返回信道 / 形参信道）
BARE_RET_SOME_ARM = """fn g() -> int? { return 5; }
fn main() -> int { v := g(); return match v { Some(x) => { return x; } None => { return 0; } }; }
"""
BOXED_RET_SOME_ARM = """fn g() -> int? { return Some(9); }
fn main() -> int { v := g(); return match v { Some(x) => { return x; } None => { return 0; } }; }
"""
BARE_RET_WILDCARD = """fn g() -> int? { return 5; }
fn main() -> int { v := g(); return match v { _ => { return 11; } }; }
"""
BARE_PARAM_SOME_ARM = """fn f(x: int?) -> int { return match x { Some(v) => { return v; } None => { return 0; } }; }
fn main() -> int { return f(5); }
"""
BOXED_PARAM_SOME_ARM = """fn f(x: int?) -> int { return match x { Some(v) => { return v; } None => { return 0; } }; }
fn main() -> int { return f(Some(6)); }
"""
BARE_PARAM_TRY = """fn f(x: int?) -> int { return x?; }
fn main() -> int { return f(3); }
"""
# `?` 解包装箱值：修复前 ELF 返回指针、解释器返回内部地址（**双路径分歧的静默错值**）
BOXED_PARAM_TRY = """fn g() -> int? { return Some(7); }
fn f(x: int?) -> int { return x?; }
fn main() -> int { return f(g()); }
"""
# 混合返回（同函数两条 return 两种表示；表示位运行期分派 ⇒ 两条路径各自正确）
MIXED_RET_BARE = """fn g(c: int) -> int? { if c > 0 { return 5; } return Some(4); }
fn main() -> int { v := g(1); return match v { Some(x) => { return x; } None => { return 0; } }; }
"""
MIXED_RET_BOXED = """fn g(c: int) -> int? { if c > 0 { return 5; } return Some(4); }
fn main() -> int { v := g(0); return match v { Some(x) => { return x; } None => { return 0; } }; }
"""
# 装箱值 + 通配臂（既有语义保持）
BOXED_WILDCARD = """fn main() -> int { x : int? = Some(9); return match x { _ => { return 12; } }; }
"""
# 未覆盖面（登记，非本任务面）：结构体字段裸值 + Some 臂 ⇒ 既有装箱假定 ⇒ 响亮失败
# （rc=139 双路径**同**：钉「未覆盖面不静默分歧」，不钉错误值本身）
UNCOVERED_FIELD_BARE = """struct S { a: int? }
fn main() -> int { s : ., mut = S { a: 5 }; return match s.a { Some(v) => { return v; } None => { return 0; } }; }
"""
# 未覆盖面之装箱形态：照常正确（登记双面）
UNCOVERED_FIELD_BOXED = """struct S { a: int? }
fn main() -> int { s : ., mut = S { a: Some(5) }; return match s.a { Some(v) => { return v; } None => { return 0; } }; }
"""
# 全局槽（无表示位 = 未覆盖面，走既有装箱假定）：装箱形态照常正确（**前提 = tag 读取
# 源支持全局行**——修复前 ELF 读帧外伪偏移 ⇒ 静默走空臂返回 0，与解释器 5 分歧）
UNCOVERED_GLOBAL_BOXED = """g : int? = Some(5);
fn main() -> int { return match g { Some(v) => { return v; } None => { return 0; } }; }
"""
UNCOVERED_GLOBAL_NONE = """g : int? = None;
fn main() -> int { return match g { Some(v) => { return v; } None => { return 9; } }; }
"""

# ── 容量批 T2：聚合面存储边界规范化（裁-CAP-1 (a)）——A 类 8 写点逐点覆盖 ──────────
# 每例 = 裸值写入可选聚合槽后解包（修复前 139；现须给精确值）；装箱/None 形为对照。
CAP_FIELD_ASSIGN = """struct S { a: int? }
fn main() -> int { s : ., mut = S { a: Some(0) }; s.a = 5; return match s.a { Some(v) => { return v; } None => { return 0; } }; }
"""
CAP_FIELD_LITERAL = """struct S { a: int? }
fn main() -> int { s : ., mut = S { a: 6 }; return match s.a { Some(v) => { return v; } None => { return 0; } }; }
"""
CAP_FIELD_NONE = """struct S { a: int? }
fn main() -> int { s : ., mut = S { a: None }; return match s.a { Some(v) => { return v; } None => { return 3; } }; }
"""
CAP_ARR_ASSIGN_LIT = """fn main() -> int { a : [int?;2] = [Some(0), None]; a[0] = 7; return match a[0] { Some(v) => { return v; } None => { return 0; } }; }
"""
CAP_ARR_ASSIGN_DYN = """fn main() -> int { a : [int?;2] = [Some(1), None]; i := 1; a[i] = 8; return match a[i] { Some(v) => { return v; } None => { return 0; } }; }
"""
CAP_ARR_LITERAL_IDENT = """fn main() -> int { x : int? = 5; a : [int?;2] = [x, None]; return match a[0] { Some(v) => { return v; } None => { return 0; } }; }
"""
CAP_ARR_BOXED_LITERAL = """fn main() -> int { a : [int?;2] = [Some(4), None]; return match a[0] { Some(v) => { return v; } None => { return 0; } }; }
"""
CAP_GLOBAL_ASSIGN = """g : int? = None;
fn main() -> int { g = 9; return match g { Some(v) => { return v; } None => { return 0; } }; }
"""
CAP_GLOBAL_INIT_BARE = """g : int? = 10;
fn main() -> int { return match g { Some(v) => { return v; } None => { return 0; } }; }
"""
CAP_MATCHRES_COND = """fn f(c: int) -> int? { return match c { 0 => 11, _ => None, }; }
fn main() -> int { v := f(0); return match v { Some(x) => { return x; } None => { return 0; } }; }
"""
CAP_ENUM_PAYLOAD = """enum E { V(int?), W }
fn main() -> int { e := V(12); return match e { V(x) => { return match x { Some(v) => { return v; } None => { return 0; } }; } W => { return 1; } }; }
"""
CAP_TUPLE_ELEM = """fn main() -> int { x : int? = 13; t := (x, 3); return match t . 0 { Some(v) => { return v; } None => { return 0; } }; }
"""
CAP_FIELD_BARE_CROSSFN = """struct S { a: int? }
fn f(s: S) -> int { return match s.a { Some(v) => { return v; } None => { return 0; } }; }
fn main() -> int { s : ., mut = S { a: Some(0) }; s.a = 14; return f(s); }
"""
# 负控：非可选聚合槽不受本律影响（值形态不变）
CAP_NONOPT_FIELD = """struct S { a: int }
fn main() -> int { s : ., mut = S { a: 15 }; s.a = 16; return s.a; }
"""


# ── (A) 批 T2：表示位随存储走（裁-REP-1 (iii)：取址槽恒装箱）──────────────────
# 载体 = 指针写（`p := &slot; *p = v`）。**四形态 × {裸, 装箱, None, 条件写}**：
#   INV-1 取址槽恒持装箱值 ⇒ 裸值经指针写 ⇒ 写点装箱（W5）。
# 判据形态：`case_dual_softdiag`（这些源带**既有** B04 软诊断：&x 借出后读 x；T1 探针同），
# `case_dual`（check 零诊断面：数组元素 / 非可选对照），`case_dual_rc`（登记面：REP-2/REP-3）。
# **形态③（全局）另钉第二根因**：ELF 后端 `IR_REF` 全局取址修复（`&g` 曾取帧外伪偏移 ⇒
# 与全局槽脱钩）——负控 `a_neg_nonopt_global_ptr` 即其钉子（修复前 ELF 恒初值）。
A_LOCAL_BARE = """fn main() -> int { x : int? = Some(0); p := &x; *p = 7; return match x { Some(v) => { return v; } None => { return 0; } }; }
"""
A_LOCAL_BOXED = """fn main() -> int { x : int? = Some(0); p := &x; *p = Some(8); return match x { Some(v) => { return v; } None => { return 0; } }; }
"""
A_LOCAL_NONE_WRITE = """fn main() -> int { x : int? = Some(0); p := &x; *p = None; return match x { Some(v) => { return v; } None => { return 3; } }; }
"""
A_LOCAL_COND = """fn main() -> int { x : int? = None; p := &x; c := 1; if c > 0 { *p = 5; } else { *p = Some(6); } return match x { Some(v) => { return v; } None => { return 0; } }; }
"""
A_ARR_BARE = """fn main() -> int { a : [int?;2] = [Some(0), None]; p := &a[0]; *p = 7; return match a[0] { Some(v) => { return v; } None => { return 0; } }; }
"""
A_ARR_COND = """fn main() -> int { a : [int?;2] = [Some(1), None]; p := &a[0]; c := 0; if c > 0 { *p = 5; } else { *p = 9; } return match a[0] { Some(v) => { return v; } None => { return 0; } }; }
"""
A_GLOBAL_BARE = """g : int? = None;
fn main() -> int { p := &g; *p = 5; return match g { Some(v) => { return v; } None => { return 0; } }; }
"""
A_GLOBAL_BOXED = """g : int? = None;
fn main() -> int { p := &g; *p = Some(5); return match g { Some(v) => { return v; } None => { return 0; } }; }
"""
A_GLOBAL_NONE_WRITE = """g : int? = Some(1);
fn main() -> int { p := &g; *p = None; return match g { Some(v) => { return v; } None => { return 4; } }; }
"""
A_GLOBAL_COND = """g : int? = None;
fn main() -> int { p := &g; c := 1; if c > 0 { *p = 5; } else { *p = Some(6); } return match g { Some(v) => { return v; } None => { return 0; } }; }
"""
# ④ 结构体字段取址：**裁-REP-3 维持登记**（`UOP_REF` 无字段分支 ⇒ 取临时量地址 ⇒ 写入丢失；
# 属另一缺陷，须新增 `IR_ADDR_FIELD` 面才能修）——本例只钉「双路径同 rc（响亮同态）**不静默分歧**」，
# 不钉错值本身（修好后本例会照常通过：rc=0 面两支同）。
A_FIELD_ADDR = """struct S { a: int? }
fn main() -> int { s : ., mut = S { a: Some(0) }; p := &s.a; *p = 5; return match s.a { Some(v) => { return v; } None => { return 0; } }; }
"""
# ①d 形参槽（W4：形参序言**条件装箱** + 表示位钉 1）——裸值经信道入形参后被取址
A_PARAM_BARE = """fn f(x: int?) -> int { p := &x; *p = 7; return match x { Some(v) => { return v; } None => { return 0; } }; }
fn main() -> int { return f(3); }
"""
# 三子形态（T1 记录：c1 正确但脆弱 / c2 139 双路径 / c3 双路径分歧静默错值）
A_C1_BIT0_BARE = """fn main() -> int { x : int? = 5; p := &x; *p = 7; return match x { Some(v) => { return v; } None => { return 0; } }; }
"""
A_C2_BIT1_BARE = """fn main() -> int { x : int? = Some(5); p := &x; *p = 7; return match x { Some(v) => { return v; } None => { return 0; } }; }
"""
# c3 转正判据按 T1 修正：**断言「= 正确值」不钉历史观测数值**（T1 实测 ELF 8 / interp 96，
# 数值随状态漂移）——判据内置：写入载荷 = 9 ⇒ 解包值须 == 9（自证，非外部钉数）。
A_C3_BIT0_BOXED_SELFCHECK = """fn main() -> int { x : int? = 5; p := &x; *p = Some(9); return match x { Some(v) => { if v == 9 { return 1; } return 0; } None => { return 0; } }; }
"""
# REP-2 边界（指针算术伪造地址，裁-REP-2 登记 + 探针）：`p + 1` 落**非取址**槽——记录现实
# 行为（当前布局下 y 未受影响 ⇒ 6，双路径同）。本律不覆盖该面；
A_REP2_PTRADD = """fn main() -> int { x : int? = 5; y : int? = 6; p := &x; q := p + 1; *q = 7; return match y { Some(v) => { return v; } None => { return 0; } }; }
"""
# 负控：**非可选**取址槽不受本律影响（不装箱、值形态不变）；第二例同时钉 ELF 全局取址修复
A_NEG_NONOPT_LOCAL = """fn main() -> int { n : int, mut = 1; p := &n; *p = 5; return n; }
"""
A_NEG_NONOPT_GLOBAL = """g : int, mut = 1;
fn main() -> int { p := &g; *p = 5; return g; }
"""


def main():
    ok = [
        # 正：裸值入 T? 返回位（旧判定：TF01 拒绝——joint 语义落地后放行；双路径）
        case_dual("plain_value_into_optional", PLAIN_INTO_OPT, 42),
        # 正：None 入 T? 返回位（`null ⊆ T?`；双路径）
        case_dual("none_into_optional", NONE_INTO_OPT, 42),
        # 正：Some(1) 入 T?（类型项相等；双路径）
        case_dual("some_into_optional", SOME_INTO_OPT, 42),
        # 正：T? 形参位 + `?` 解包回 T（双路径）
        case_dual("unwrap_optional_in_param", UNWRAP_SRC, 3),
        # 正：Some 值流经 match 的 Some 臂（运行时 tag 分派；双路径）
        case_dual("some_flow_some_arm", SOME_FLOW, 101),
        # 正：None 值流经 match 的 None 臂（双路径）
        case_dual("none_flow_none_arm", NONE_FLOW, 7),
        # 负：T? ⊄ T（方向性——可选**不是**裸类型的子类型；钉死 soundness 面）。
        # 口径：TF01 是**软诊断**（本仓库硬门名单只含 R002/TK05-06/TS01-04/TK02/TM03，
        # build 路径 rc=0 + 产物照出）⇒ 判据走 `check`（有诊断即 rc=1）+ 措辞断言。
        case_reject("optional_not_assignable_to_plain",
                    "fn f(x: int?) -> int { return x; }\nfn main() -> int { return f(1); }\n",
                    ["error[TF01]"], cmd="check"),
        # 硬门：T? 的 match 缺 None 臂 ⇒ TM03 + 具体反例名（'None'）+ 无产物
        case_reject("optional_match_missing_none",
                    "fn main() -> int { x: int? = Some(3); return match x { Some(v) => v, }; }\n",
                    ["error[TM03]", "missing variant 'None'"]),
        # 硬门：T? 的 match 缺 Some 臂 ⇒ TM03 + 'Some'
        case_reject("optional_match_missing_some",
                    "fn main() -> int { x: int? = Some(3); return match x { None => 0, }; }\n",
                    ["error[TM03]", "missing variant 'Some'"]),
        # 正：通配臂吸收 ⇒ 穷尽（零诊断）
        case_dual("optional_match_wildcard",
                  "fn main() -> int { x: int? = None; return match x { _ => 9, }; }\n", 9),
        # 负：退役内建 Option 注册——`Option` 不再是语言内建类型名。
        # 旧行为：collect_decls 自动注册命名行 ⇒ `Option[int]` 零诊断通过；新行为：该名未声明
        # ⇒ `Undefined type in generic application`（EC_N_GENERIC_TYPE，**软诊断**：rc 面
        # build 仍 0——故判据走 `check` 的 rc=1 + 措辞）。用户自声明 `enum Option` 时按普通
        # 枚举解析（Task 3 的 p20 语义保持，见 test_match_exhaust.py）。
        case_reject("builtin_option_name_retired",
                    "fn f(x: Option[int]) -> int { return 0; }\nfn main() -> int { return f(0); }\n",
                    ["Undefined type in generic application"], cmd="check"),
        # 登记：载荷类型节点列入库（每槽有节点 = bad=0）+ 裸码列丢失真实类型的信息量
        # （`V(S)` 命名类型载荷与 `Some(T)` 泛型形参载荷在裸码列都塌缩为 0 = TY_INT）
        case_evp("payload_type_nodes_recorded",
                 "struct S { a: int }\nenum E { V(S), W(int) }\nenum Opt[T] { N, Some(T) }\n"
                 "fn main() -> int { return 0; }\n",
                 ["[enum-payload-verify]", "slots=3", "collapses=2", "bad=0"]),

        # ── R2 P4 Task 5：解包侧判表示（B.7 四形态；修复前多个形态双路径 139）──
        # 裸值 + Some 臂（B.7 最小复现）：裸值即载荷 ⇒ 5
        case_dual("bare_value_some_arm", BARE_SOME_ARM, 5),
        # 裸值 + Some/通配混合臂（B.7 边界形态）
        case_dual("bare_value_some_wildcard", BARE_SOME_WILDCARD, 5),
        # match 作表达式取值（B.7 边界形态）
        case_dual("bare_value_match_expr", BARE_MATCH_EXPR, 5),
        # 纯通配臂（B.7 边界形态；修复前即不崩——**不得回退**）
        case_dual("bare_value_wildcard", BARE_WILDCARD, 7),
        # 写点置位的运行期性：裸→装箱、装箱→裸，最后一次写点决定表示
        case_dual("bare_then_boxed_write", BARE_THEN_BOXED_WRITE, 7),
        case_dual("boxed_then_bare_write", BOXED_THEN_BARE_WRITE, 3),
        # 条件写：两路径两种表示 ⇒ 表示位必须是运行期值（两臂各自正确）
        case_dual("conditional_write_boxed_taken", COND_ON, 4),
        case_dual("conditional_write_bare_taken", COND_OFF, 5),
        # ── 跨函数面（返回信道 / 形参信道）──
        case_dual("bare_return_some_arm", BARE_RET_SOME_ARM, 5),
        case_dual("boxed_return_some_arm", BOXED_RET_SOME_ARM, 9),
        case_dual("bare_return_wildcard", BARE_RET_WILDCARD, 11),
        case_dual("bare_param_some_arm", BARE_PARAM_SOME_ARM, 5),
        case_dual("boxed_param_some_arm", BOXED_PARAM_SOME_ARM, 6),
        case_dual("bare_param_try", BARE_PARAM_TRY, 3),
        # `?` 解包装箱值：修复前 ELF/解释器**各错各的**（指针 vs 内部地址 = 双路径分歧）
        case_dual("boxed_param_try", BOXED_PARAM_TRY, 7),
        # 混合返回：同函数两条 return 两种表示
        case_dual("mixed_return_bare_taken", MIXED_RET_BARE, 5),
        case_dual("mixed_return_boxed_taken", MIXED_RET_BOXED, 4),
        # 装箱值 + 通配臂（既有语义保持）
        case_dual("boxed_value_wildcard", BOXED_WILDCARD, 12),
        # ── 原未覆盖面（**容量批 T2 重钉**：裸值形态已由写点装箱闭合）──
        # 死亡证据 = 本批能力变更：修复前 `uncovered_field_bare_is_loud` 期望 -11（响亮
        # 失败），本批后为正确值 5 ⇒ 改判 `case_dual` 断言精确值（**禁令**：只断 rc 会
        # 让「静默错值」类突变假绿——突变 M4 即此形态）。
        case_dual("uncovered_field_bare_now_ok", UNCOVERED_FIELD_BARE, 5),
        case_dual("uncovered_field_boxed_ok", UNCOVERED_FIELD_BOXED, 5),
        # 全局槽：装箱/None 形态照常正确（钉 tag 读取源的全局行分派）
        case_dual("uncovered_global_boxed_ok", UNCOVERED_GLOBAL_BOXED, 5),
        case_dual("uncovered_global_none_ok", UNCOVERED_GLOBAL_NONE, 9),

        # ── 容量批 T2：聚合面存储边界规范化（裁-CAP-1 (a)；A 类 8 写点逐点）──
        # 字段：赋值点 / 字面量点（**两个独立写点**，突变 M1 专测其可判别性）
        case_dual("cap_field_bare_assign", CAP_FIELD_ASSIGN, 5),
        case_dual("cap_field_bare_literal", CAP_FIELD_LITERAL, 6),
        case_dual("cap_field_none", CAP_FIELD_NONE, 3),
        case_dual("cap_field_bare_crossfn", CAP_FIELD_BARE_CROSSFN, 14),
        # 数组元素：字面量下标 / 动态下标 / 字面量元素（ident）/ 装箱对照
        case_dual("cap_array_bare_assign_lit_idx", CAP_ARR_ASSIGN_LIT, 7),
        case_dual("cap_array_bare_assign_dyn_idx", CAP_ARR_ASSIGN_DYN, 8),
        case_dual("cap_array_literal_ident_elem", CAP_ARR_LITERAL_IDENT, 5),
        case_dual("cap_array_boxed_literal", CAP_ARR_BOXED_LITERAL, 4),
        # 全局槽：赋值点 / **初值点**（两个独立代码点；初值点另涉常量折叠抑制——见实现注）
        case_dual("cap_global_bare_assign", CAP_GLOBAL_ASSIGN, 9),
        case_dual("cap_global_bare_init", CAP_GLOBAL_INIT_BARE, 10),
        # match 结果（裁决 (i) 表示位案）：条件写两表示共存
        case_dual("cap_matchres_cond_bare_arm", CAP_MATCHRES_COND, 11),
        # 枚举载荷（B 类 #10 实证可达 ⇒ 升 A）
        case_dual("cap_enum_payload_bare", CAP_ENUM_PAYLOAD, 12),
        # 元组元素（B 类 #11 实证可达 ⇒ 升 A；读语法须带空格 `t . 0`）
        case_dual("cap_tuple_elem_bare", CAP_TUPLE_ELEM, 13),
        # 负控：非可选聚合槽不受本律影响
        case_dual("cap_nonopt_field_unaffected", CAP_NONOPT_FIELD, 16),

        # ── (A) 批 T2：表示位随存储走（裁-REP-1 (iii)；四形态 × 值形态）──
        # ① 局部槽（T1: 139 双路径）
        case_dual_softdiag("a_local_bare_ptrwrite", A_LOCAL_BARE, 7),
        case_dual_softdiag("a_local_boxed_ptrwrite", A_LOCAL_BOXED, 8),
        case_dual_softdiag("a_local_none_ptrwrite", A_LOCAL_NONE_WRITE, 3),
        case_dual_softdiag("a_local_cond_ptrwrite", A_LOCAL_COND, 5),
        # ①d 形参槽（W4 条件装箱）
        case_dual_softdiag("a_param_bare_ptrwrite", A_PARAM_BARE, 7),
        # ② 数组元素（T1: 139 双路径）
        case_dual("a_arr_bare_ptrwrite", A_ARR_BARE, 7),
        case_dual("a_arr_cond_ptrwrite", A_ARR_COND, 9),
        # ③ 全局槽（T1: ELF 0 / interp 139 分歧）+ ③b 装箱写（T1: ELF 0 / interp 5 静默分歧）
        case_dual_softdiag("a_global_bare_ptrwrite", A_GLOBAL_BARE, 5),
        case_dual_softdiag("a_global_boxed_ptrwrite", A_GLOBAL_BOXED, 5),
        case_dual_softdiag("a_global_none_ptrwrite", A_GLOBAL_NONE_WRITE, 4),
        case_dual_softdiag("a_global_cond_ptrwrite", A_GLOBAL_COND, 5),
        # ④ 结构体字段取址：裁-REP-3 维持登记（只钉「双路径同 rc」）
        case_dual_rc("a_field_addr_registered", A_FIELD_ADDR, 0),
        # 三子形态：c1 保持 / c2 转正 / c3 转正（自证式断言，不钉历史数值）
        case_dual_softdiag("a_c1_bit0_bare", A_C1_BIT0_BARE, 7),
        case_dual_softdiag("a_c2_bit1_bare", A_C2_BIT1_BARE, 7),
        case_dual_softdiag("a_c3_bit0_boxed_selfcheck", A_C3_BIT0_BOXED_SELFCHECK, 1),
        # REP-2 边界（指针算术）：登记 + 记录现实行为（双路径同）
        case_dual("a_rep2_ptradd_boundary", A_REP2_PTRADD, 6),
        # 负控：非可选取址槽不受本律影响
        case_dual_softdiag("a_neg_nonopt_local_ptr", A_NEG_NONOPT_LOCAL, 5),
        case_dual_softdiag("a_neg_nonopt_global_ptr", A_NEG_NONOPT_GLOBAL, 5),
    ]
    passed = sum(1 for x in ok if x is True)
    print(f"{passed}/{len(ok)} passed")
    return 0 if passed == len(ok) else 1


if __name__ == "__main__":
    raise SystemExit(main())
