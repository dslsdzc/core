#!/usr/bin/env python3
"""TODO #2026-09-10-7 判据：解释器 callee 内联路径 ≡ 主循环路径（≡ ELF oracle）。

R1 终审实测：`interp.cr` 的 callee 内联分派相对主循环缺 18 个 opcode
（4/17/18/23/24/25/26/27/28/29/30/41/42/43/44/45/48/51）——同一段源码写在
main 里正确、写进普通函数（被内联执行）里错值 / SIGSEGV，ELF 侧均正确。

本判据把三条路径钉在一起（每例两条断言 + 一条 oracle 断言）：
  ① interp(callee) —— 内联路径（被内联的 probe()）
  ② interp(main)   —— 主循环路径（同一段源码，省一次 ELF 构建）
  ③ elf(callee)    —— ELF oracle（本修复不改动发射面）

三类用例：
  - `parity`：① == ② == ③ == 期望值（纯值语义；ELF 即 oracle）
  - `loud`  ：①/② 必须响亮失败（非零 rc，动态分发/extern/深度守卫另有诊断），
              绝不静默 0；③ 单列期望（ELF 侧自身行为：越界 SIGILL / extern·
              深递归 SIGSEGV / 动态分发占位 no-op）
  - `approx`：解释器的显式近似（IR_FNADDR 无真实地址 = 0）——只要求 ① == ②
              （两路径一致的近似才不算分叉），③ 单列

对 parity/approx 追加「诊断奇偶性」断言：同一段源码在两种形态（包进 probe() /
内联进 main）下，前端诊断的**存在性必须相等**——前端两形态共享，诊断只出现在
一条路径上才是分叉信号；两形态共有的既存诊断（B04 借用报错、apx dex 的
N01/TA01）属于前端既有行为，不属本判据判域。

ELF 侧 SIGILL/SIGSEGV 在 subprocess.returncode 里是负信号号（-4 / -11）；解释器
侧越界陷阱与深度守卫的 rc 是 255（main 返回 -1，低 8 位）。

判据前清 cir 缓存（缓存键不含编译器身份，TODO #2026-09-10-1）：否则旧 IR 冒充新编译器，
本判据会被静默污染（见 test_global_init.py 同款说明）。
"""

import os
import resource
import subprocess
from pathlib import Path


BASE = Path(__file__).resolve().parents[2]
BUILD = BASE / "build"
COREC = BUILD / "corec"

# 信号退出码（subprocess 语义）：SIGILL = -4，SIGSEGV = -11
SIGILL = -4
SIGSEGV = -11

# (名称, 文件级前言, 函数体, 模式, 期望 interp rc, 期望 elf rc)
# 函数体 = 不含 return 类型的语句序列（两条路径同源：callee 包进 probe()、
# main 直接内联）。
CASES = [
    # —— 枚举族（17 MAKE_ENUM / 23 LOAD_ENUM_TAG / payload 走 11/12）——
    (
        "enum_payload_in_callee",
        "enum Choice { First(int), Second(int), Third(int) }",
        "c := Third(33); return match c { First(x) => x, Second(x) => x, Third(x) => x, };",
        "parity", 33, 33,
    ),
    (
        # 构造在 callee（MAKE_ENUM）、match 在 main（LOAD_ENUM_TAG 跨函数）
        "enum_construct_callee_match_main",
        "enum Choice { First(int), Second(int), Third(int) }\n"
        "fn make()->Choice { return Third(33); }",
        "c := make(); return match c { First(x) => x, Second(x) => x, Third(x) => x, };",
        "parity", 33, 33,
    ),
    (
        "enum_tag_variant_in_callee",
        "enum Color { Red, Green, Blue }",
        "c := Green(); return match c { Red => 1, Green => 2, Blue => 3, };",
        "parity", 2, 2,
    ),
    (
        "enum_payload_tag_only_in_callee",
        "enum Choice { First(int), Second(int), Third(int) }",
        "c := Third(33); return match c { First(x) => 1, Second(x) => 2, Third(x) => 3, };",
        "parity", 3, 3,
    ),
    # —— 裸指针族（18 REF / 25 DEREF / 26 STORE_PTR / 31 ADDR_INDEX）——
    (
        # TODO #2026-09-10-7 复现原件：g:[int;3]=[5,6,7]; fn f(){ p:=&g[2]; return *p; }
        "bare_ptr_deref_callee",
        "g : [int;3] = [5,6,7];",
        "p := &g[2]; return *p;",
        "parity", 7, 7,
    ),
    (
        "ptr_store_callee",
        "",
        "x : ., mut = 5; p := &x; *p = 42; return x;",
        "parity", 42, 42,
    ),
    (
        "addr_index_deref_callee",
        "",
        "a := [10,20,30]; p := &a[1]; return *p;",
        "parity", 20, 20,
    ),
    # —— 切片 / 边界检查族（24 SLICE / 30 BOUNDS_CHECK）——
    (
        "slice_runtime_bounds_callee",
        "",
        "a : [int;5] = [10,20,30,40,50]; lo := 1; hi := 3; s := a[lo..hi]; return s[1];",
        "parity", 30, 30,
    ),
    (
        "slice_literal_bounds_callee",
        "",
        "a : [int;5] = [10,20,30,40,50]; s := a[1..3]; return s[1];",
        "parity", 30, 30,
    ),
    (
        # 越界：interp 陷阱 = 中止码 -1（rc 255，与主循环 return -1 同语义）；
        # ELF = ud2 SIGILL。两路径都非静默（rc 非 0）。
        "slice_oob_callee_loud",
        "",
        "a : [int;5] = [10,20,30,40,50]; lo := 1; hi := 3; s := a[lo..hi]; return s[2];",
        "loud", 255, SIGILL,
    ),
    # —— dyn 族（43 DYN_PACK / 42 DYN_VAL / 41 DYN_TAG / 44 DYN_DISPATCH）——
    (
        "dyn_pack_val_callee",
        "",
        "x : dyn = 42; if x != 42 { return 1; } return 0;",
        "parity", 0, 0,
    ),
    (
        # 动态分发：interp 响亮报错（rc 2 + 诊断，与主循环同文案）；ELF 占位 no-op
        "dyn_dispatch_callee_loud",
        "struct Counter { n: int }\nimpl Counter {\n    fn bump(self) { }\n}\n",
        "c : Counter = Counter { n = 7 }; d : dyn = c; d.bump(); return 3;",
        "loud", 2, 3,
    ),
    # —— 调用族（4 CALL：嵌套内联 / 递归 / 互递归）——
    (
        "nested_call_callee",
        "fn g2()->int { return 7; }\n",
        "return g2();",
        "parity", 7, 7,
    ),
    (
        "recursion_fib_callee",
        "fn fib(n: int)->int { if n < 2 { return n; } return fib(n-1) + fib(n-2); }\n",
        "return fib(10);",
        "parity", 55, 55,
    ),
    (
        "mutual_recursion_callee",
        "fn is_even(n: int)->int { if n == 0 { return 1; } return is_odd(n - 1); }\n"
        "fn is_odd(n: int)->int { if n == 0 { return 0; } return is_even(n - 1); }\n",
        "return is_even(10);",
        "parity", 1, 1,
    ),
    (
        # 深度守卫：无界递归必须响亮中止（rc 255 + 诊断），不挂死
        "depth_guard_runaway_loud",
        "fn r(n: int)->int { return r(n + 1); }\n",
        "return r(0);",
        "loud", 255, SIGSEGV,
    ),
    # —— 并发族（27 SPAWN：range go；28 YIELD / 29 AWAIT eager 近似）——
    (
        "range_go_spawn_callee",
        "fn square(x: int) -> int { return x * x; }\n",
        "arr := go i 0..3 square(i); return arr[0] + arr[1] + arr[2];",
        "parity", 5, 5,
    ),
    (
        # 19 BRANCH / 20 JUMP / 21 LABEL：callee 内的回边（主循环用 region 表、
        # callee 路径只用 label_poses——两条机制各走各的，必须同值）
        "loop_in_callee",
        "",
        "s : ., mut = 0; for i := 0..5 { s = s + i; } return s;",
        "parity", 10, 10,
    ),
    (
        "yield_in_callee",
        "",
        "yield; return 11;",
        "parity", 11, 11,
    ),
    (
        "await_in_callee",
        "",
        "x := await 5; return x;",
        "parity", 5, 5,
    ),
    # —— 45 CALL_EXTERN：响亮报错（interp rc 2 + 诊断；ELF 静态构建运行期
    # SIGSEGV——两侧都非静默）——
    (
        "extern_call_callee_loud",
        "extern fn putchar(c: int) -> int;\n",
        "return putchar(65);",
        "loud", 2, SIGSEGV,
    ),
    # —— 48 FNADDR / 51 IR_APPROX ——
    (
        # 解释器无真实地址（FNADDR 恒 0）——显式近似：只断言 callee ≡ main
        "fnaddr_callee_approx",
        "fn square(x: int) -> int { return x * x; }\n",
        "p := @addr(square); if p == 0 { return 1; } return 0;",
        "approx", 1, 0,
    ),
    (
        # IR_APPROX (51)：apx 标注（`apx dex` 不是合法语法——真形式是 `dex, apx`
        # 标签）。先前写成 `d : apx dex = 2.0` 时 checker 发 N01/TA01、IR_APPROX
        # 根本未发射，判据形同虚设（两形态的诊断奇偶断言也掩盖了它）。
        "approx_apx_dex_callee",
        "",
        "d : dex, apx = 2.0; return 7;",
        "parity", 7, 7,
    ),
]

# 响亮失败用例必须出现的诊断标记（interp 侧）——缺诊断说明是静默失败
LOUD_MARKERS = {
    "dyn_dispatch_callee_loud": "IR_DYN_DISPATCH",
    "extern_call_callee_loud": "无法调用外部函数",
    "depth_guard_runaway_loud": "IR_INTERP_MAX_DEPTH",
}

# 覆盖自检：每例必须在 probe() 的 DFG 节点区内**真的**出现这些 opcode。
# 内联路径只执行 probe() 的节点区（g_df_func_node_start..+count），故节点区
# 里没有目标 opcode 的用例等于没测（空转）——写法错（如 `apx dex`）或前端
# 不再发射该 opcode 时，用例会静默失去判据价值，此处用 `corec cir` 钉死。
# TODO #2026-09-10-7 清单里唯一无法覆盖的是 41 IR_DYN_TAG：ir_gen.cr 无发射点
# （regalloc/instr/sizes/dataflow/opt/interp 均已有处理器）——该 opcode 当前
# 不可达，内联路径的处理器是纯防御性对齐，不列入下表。
EXPECT_OPS = {
    "enum_payload_in_callee": {"make_enum", "load_enum_tag"},
    "enum_construct_callee_match_main": {"call", "load_enum_tag"},
    "enum_tag_variant_in_callee": {"make_enum", "load_enum_tag"},
    "enum_payload_tag_only_in_callee": {"make_enum", "load_enum_tag"},
    "bare_ptr_deref_callee": {"addr_index", "deref"},
    "ptr_store_callee": {"ref", "store_ptr"},
    "addr_index_deref_callee": {"addr_index", "deref"},
    "slice_runtime_bounds_callee": {"slice", "bounds_check"},
    "slice_literal_bounds_callee": {"slice"},
    "slice_oob_callee_loud": {"slice", "bounds_check"},
    "dyn_pack_val_callee": {"dyn_pack", "dyn_val"},
    "dyn_dispatch_callee_loud": {"dyn_dispatch", "dyn_pack"},
    "nested_call_callee": {"call"},
    "recursion_fib_callee": {"call"},
    "mutual_recursion_callee": {"call"},
    "depth_guard_runaway_loud": {"call"},
    "range_go_spawn_callee": {"spawn"},
    "loop_in_callee": {"jump", "branch"},
    "yield_in_callee": {"yield"},
    "await_in_callee": {"await"},
    "extern_call_callee_loud": {"call_extern"},
    "fnaddr_callee_approx": {"fnaddr"},
    "approx_apx_dex_callee": {"approx"},
}


def clean_cache() -> None:
    """cir 缓存键不含编译器身份（TODO #2026-09-10-1）——判据前清缓存，失败即报错退出。"""
    result = subprocess.run(
        ["nice", "-n", "19", str(COREC), "clean-cache"],
        cwd=BASE, capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"[FAIL] clean-cache failed (rc={result.returncode})")
        for line in (result.stdout + result.stderr).strip().splitlines()[:10]:
            print(f"       | {line}")
        raise SystemExit(1)


def has_diag(output: str) -> bool:
    return "error[" in output


def no_core_dump():
    # TODO:125：core_pattern 为 systemd-coredump 管道时陷阱程序会挂起——测试
    # 禁用 core dump 让 SIGILL/SIGSEGV 立即终止。
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def run_interp(source: str):
    result = subprocess.run(
        ["nice", "-n", "19", str(COREC), "run", source],
        cwd=BASE, capture_output=True, text=True, timeout=120,
    )
    return result.returncode, result.stdout + result.stderr


def run_native(name: str, source: str):
    tag = f"{name}_{os.getpid()}"
    src = BUILD / f"interp_parity_{tag}.cr"
    binary = BUILD / f"interp_parity_{tag}"
    ccr = Path(str(binary) + ".ccr")
    src.write_text(source.strip() + "\n", encoding="utf-8")
    try:
        built = subprocess.run(
            ["nice", "-n", "19", str(COREC), "build", str(src),
             "-o", str(binary), "--static"],
            cwd=BASE, capture_output=True, text=True, timeout=120,
        )
        out = built.stdout + built.stderr
        if built.returncode != 0:
            return built.returncode, out
        if not binary.exists():
            return 127, out + "\n[no ELF produced]"
        run = subprocess.run(
            [str(binary)], cwd=BASE, capture_output=True, text=True,
            timeout=30, preexec_fn=no_core_dump,
        )
        return run.returncode, out + run.stdout + run.stderr
    finally:
        for artifact in (src, binary, ccr):
            try:
                artifact.unlink()
            except FileNotFoundError:
                pass


def callee_src(prelude: str, body: str) -> str:
    """内联路径：函数体包进 probe()，main 调 probe()。"""
    return f"{prelude}\nfn probe()->int {{ {body} }}\nfn main()->int {{ return probe(); }}"


def main_src(prelude: str, body: str) -> str:
    """主循环路径：同一段函数体直接内联进 main。"""
    return f"{prelude}\nfn main()->int {{ {body} }}"


def probe_ops(name: str, source: str):
    """probe() 节点区里的 opcode 名集合（= 内联路径实际会执行的节点）。

    与 interp 同一数据源（g_df_nodes 的函数节点区），经 `corec cir` 打印；
    cir 缓存需已 clean（调用方保证），否则旧 IR 会冒充。
    """
    tag = f"cover_{name}_{os.getpid()}"
    src = BUILD / f"interp_parity_{tag}.cr"
    src.write_text(source.strip() + "\n", encoding="utf-8")
    try:
        dumped = subprocess.run(
            ["nice", "-n", "19", str(COREC), "cir", str(src)],
            cwd=BASE, capture_output=True, text=True, timeout=120,
        )
        ops, in_probe = set(), False
        for line in (dumped.stdout + dumped.stderr).splitlines():
            if line.startswith("Function: "):
                in_probe = line.strip() == "Function: probe"
                continue
            if in_probe and line.startswith("      ") and not line.startswith("       "):
                tok = line.strip().split(" ")[0]
                if tok:
                    ops.add(tok)
        return ops, dumped.returncode
    finally:
        # 源文件 + cir 缓存一起删（缓存就落在源文件旁）——判据不留垃圾
        for artifact in (src, src.with_suffix(".cir")):
            try:
                artifact.unlink()
            except FileNotFoundError:
                pass


def main() -> int:
    if not COREC.exists():
        print("build/corec is missing; run `python3 build_selfhost_native.py` first")
        return 1
    BUILD.mkdir(exist_ok=True)
    clean_cache()

    failures = []
    for name, prelude, body, mode, exp_interp, exp_elf in CASES:
        ok = True
        src_callee = callee_src(prelude, body)
        src_main = main_src(prelude, body)

        # ⓪ 覆盖自检：内联路径必须真的执行到目标 opcode（否则用例空转）
        want = EXPECT_OPS.get(name, set())
        if want:
            ops, dump_rc = probe_ops(name, src_callee)
            missing = want - ops
            if dump_rc != 0 or missing:
                ok = False
                print(f"[FAIL] {name}/opcodes: missing {sorted(missing)} in probe() "
                      f"(dump rc={dump_rc}, 节点区 ops={sorted(ops)})")

        # ① 内联路径（解释器）
        rc, out = run_interp(src_callee)
        if mode == "loud":
            if rc == 0 or has_diag(out):
                ok = False
                print(f"[FAIL] {name}/interp-callee: loud failure expected, rc={rc}, diag={has_diag(out)}")
            marker = LOUD_MARKERS.get(name)
            if rc != exp_interp or (marker and marker not in out):
                ok = False
                print(f"[FAIL] {name}/interp-callee: expected rc={exp_interp}"
                      f"{' + marker ' + marker if marker else ''}, got rc={rc}")
                for line in out.strip().splitlines()[:6]:
                    print(f"       | {line}")
            else:
                print(f"[PASS] {name}/interp-callee: rc={rc} (loud)")
        else:
            if rc != exp_interp:
                ok = False
                print(f"[FAIL] {name}/interp-callee: expected {exp_interp}, got rc={rc}"
                      f"{' + diagnostic' if has_diag(out) else ''}")
                for line in out.strip().splitlines()[:6]:
                    print(f"       | {line}")
            else:
                print(f"[PASS] {name}/interp-callee: {rc}")

        # ② 主循环路径（解释器）——同一段源码不写进 probe()：两路径必须同值
        rc_m, out_m = run_interp(src_main)
        expect_main = exp_interp
        if rc_m != expect_main:
            ok = False
            print(f"[FAIL] {name}/interp-main: expected {expect_main}, got rc={rc_m}"
                  f"{' + diagnostic' if has_diag(out_m) else ''}")
        else:
            print(f"[PASS] {name}/interp-main: {rc_m}")

        # 诊断奇偶性（parity/approx）：前端（lexer/parser/checker）为两形态共享，
        # 同一段源码包进 probe() 与内联进 main 必须得到同一套诊断。只有诊断
        # 「只在一条路径上出现」才是分叉信号——要求的是存在性相等，不是必须为零：
        # 两形态共有的既存诊断（如 B04 借用报错、apx dex 的 N01/TA01）是前端既有
        # 行为，不属本判据判域；rc 已单独断言，不存在被诊断掩盖的通道。
        if mode != "loud" and has_diag(out) != has_diag(out_m):
            ok = False
            print(f"[FAIL] {name}/diag-parity: callee diag={has_diag(out)}, "
                  f"main diag={has_diag(out_m)} — 同一源码两形态诊断不一致")
            for line in (out if has_diag(out) else out_m).strip().splitlines()[:6]:
                print(f"       | {line}")

        # ③ ELF oracle（内联路径形态）
        rc_e, out_e = run_native(name, src_callee)
        if rc_e != exp_elf:
            ok = False
            print(f"[FAIL] {name}/elf-callee: expected {exp_elf}, got rc={rc_e}")
            for line in out_e.strip().splitlines()[:6]:
                print(f"       | {line}")
        else:
            print(f"[PASS] {name}/elf-callee: {rc_e}")

        if not ok:
            failures.append(name)

    print(f"{len(CASES) - len(failures)}/{len(CASES)} interp-parity cases passed "
          f"(interp callee ≡ interp main ≡ ELF oracle)")
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
