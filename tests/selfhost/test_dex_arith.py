#!/usr/bin/env python3
"""dex 精确运算测试（自举编译器 build/corec）—— 数值迁移 Task 4/6。

定点缩放语义（S = 10^6）：
- 无 apx：dex 运算 = 缩放整数精确算术（0.1+0.2==0.3、3.14+2.86==6.0、1/10 打印 "0.1"）
- 有 apx：dex 运算 = binary64 快路径（现成 float 路径——binary64 行为，以 1/3 判别子断言）
- 字面量 3.14 → 缩放整数 3140000（cir dump 证据）
- 打印：缩放整数 → 十进制（去尾零）

断言点：
- ELF 端到端：精确断言全过（dex_test.cr 思路的主函数内联版）
- apx 分流：同程序带 apx → binary64 行为（1.0b/3.0b != 0.3333333）；不带 apx → 精确（为真）
- apx 打印（Task 6 定稿）：6 位定点舍入（半进）——0.1 → "0.1"、1/3 → "0.333333"、1.0000006 → "1.000001"
- `corec run` 解释器：精确运算结果正确；apx dex 需要 binary64 语义时显式报错
- cir dump：`const dex = 3140000`（精确字面量 = 缩放整数，非二进制位模式）

文档化限制（Task 6 发现）：经典 binary64 演示「0.1b+0.2b != 0.3」在本实现不成立——
str_to_f64_bits 字面量转换按 ~2ulp 截断（lexer.cr 注释），0.1/0.2 各低 1ulp 后相加
恰好落在 0.3 的位模式上。该限制属 apx 快路径字面量转换（保留站点，非回归）；
binary64 行为断言以 1/3 判别子（APX_SRC）为准——±2ulp 字面量误差下依然鲁棒
（缩放 333333 vs 3333333 差三个数量级）。
"""

import os
import re
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"


def run_corec(args, source):
    """Write source to a temp file and run `corec <args> FILE.cr`.

    源文件首行注入唯一注释：改变 source hash，避免命中 .core/cache/cir/
    增量缓存（改源码后需 clean-cache 的地雷，见 CLAUDE.md）。
    """
    src = f"// dex-arith-{uuid.uuid4()}\n" + source
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as f:
        f.write(src)
        path = f.name
    try:
        return subprocess.run(
            [str(COREC)] + args + [path],
            cwd=BASE,
            capture_output=True,
            text=True,
            timeout=180,
        )
    finally:
        os.unlink(path)


EXACT_SRC = (
    "fn main() -> int:\n    a := 3.14 + 2.86\n    if a != 6.0:\n        return 1\n    b := 0.1 + 0.2\n    if b != 0.3:\n        return 2\n    c := 1.0 / 10.0\n    if c != 0.1:\n        return 3\n    d := 1.5 * 2.0\n    if d != 3.0:\n        return 4\n    e := 0.3 - 1.0\n    if e != -0.7:\n        return 5\n    f := 1 + 0.5\n    if f != 1.5:\n        return 6\n    g : dex = 0.1\n    h : dex = 0.2\n    if g + h != 0.3:\n        return 7\n    r := dex_add_fn(0.1, 0.2)\n    if r != 0.3:\n        return 8\n    q := 1.0 / 3.0\n    if q != 0.3333333:\n        return 9\n    return 0\nfn dex_add_fn(a: dex, b: dex) -> dex:\n    return a + b\n"
)

# 同一程序 + apx 标签：x/y 是 binary64 位模式 → z = 1.0b/3.0b = 0.3333333333333333 != 0.3333333
# （1/3 判别子：binary64 与定点 6 位结果必然不同——精确世界 z == 0.3333333 为真）
APX_SRC = (
    "fn main() -> int:\n    x : dex, apx = 1.0\n    y : dex, apx = 3.0\n    z := x / y\n    if z == 0.3333333:\n        return 1\n    return 0\n"
)

APX_LIT_SRC = (
    "fn main() -> int:\n    x : dex, apx = 1.0\n    if x / 3.0 == 0.3333333:\n        return 1\n    return 0\n"
)

# LET 边界转换回归（审查发现）：`y : dex = x`（x 为 apx 变量，存 binary64 bits）时
# 初始值必须按声明类型走 dex_store_adjust——bits → 6 位定点缩放，y 存缩放形式。
# 修复前：y 原样存 bits 且被定型 TI_DEX（无 apx 标签却永久走 binary64），
# 1.0/y 得到垃圾（bits 当缩放整数用）→ != 0.3333333（修复后为真——精确）。
LET_APX_EXACT_SRC = (
    "fn main() -> int:\n    x : dex, apx = 3.0\n    y : dex = x\n    z := 1.0 / y\n    if z != 0.3333333:\n        return 1\n    return 0\n"
)

# % 截断恒等式（5 指令序列：a - trunc(a/b)·b）——含负数：
#   7.0%2.5=2.0、-7.0%2.5=-2.0、1.0%0.3=0.1、-1.0%0.3=-0.1
MOD_SRC = (
    "fn main() -> int:\n    a := 7.0 % 2.5\n    if a != 2.0:\n        return 1\n    b := -7.0 % 2.5\n    if b != -2.0:\n        return 2\n    c := 1.0 % 0.3\n    if c != 0.1:\n        return 3\n    d := -1.0 % 0.3\n    if d != -0.1:\n        return 4\n    return 0\n"
)

# apx 打印定稿（Task 6）：apx 变量经 dex_str 打印 = 6 位定点舍入（四舍五入半进，
# bits→scaled 转换舍入而非截断）——用户写 0.1 打印 "0.1"（非全精度、非截断 "0.099999"）。
# 判别点：u = 1.0000006 → bits×1e6 ≈ 1000000.6 → 舍入 1000001（"1.000001"）；
# 截断实现会得 1000000（"1"）。负半进：-0.5 → -1。
APX_PRINT_SRC = (
    "import io\nimport fmt\nimport dex\nfn main() -> int:\n    w : dex, apx = 0.1\n    if !str_eq(dex_str(w), \"0.1\"):\n        return 1\n    x : dex, apx = 1.0\n    y : dex, apx = 3.0\n    if !str_eq(dex_str(x / y), \"0.333333\"):\n        return 2\n    u : dex, apx = 1.0000006\n    if !str_eq(dex_str(u), \"1.000001\"):\n        return 3\n    n : dex, apx = 0.1\n    v : dex, apx = 0.0 - n\n    if !str_eq(dex_str(v), \"-0.1\"):\n        return 4\n    return 0\n"
)

# apx 跨函数边界转换（b1/b2 场景）：
#   b1 调用点：apx 变量参数 → F2I(bits×S) 转 scaled（callee 收精确形式）
#   b2 返回点：apx 计算结果（binary64 bits）→ 返回处转 scaled（caller 收精确形式）
# 断言均须为真（精确）——缺任一转换则 bits 被当缩放整数用，断言失败。
APX_BOUNDARY_SRC = (
    "fn main() -> int:\n    x : dex, apx = 3.0\n    r := dex_double_fn(x)\n    if r != 6.0:\n        return 1\n    s := dex_apx_ret_fn()\n    if s != 0.5:\n        return 2\n    return 0\nfn dex_double_fn(a: dex) -> dex:\n    return a * 2.0\nfn dex_apx_ret_fn() -> dex:\n    v : dex, apx = 1.0\n    return v / 2.0\n"
)


def build_run_exit(src):
    """Build to ELF (static) and run; return (exit_code, stdout+stderr)."""
    p = run_corec(["build", "-o", "/tmp/dex_arith_bin", "--static"], src)
    if p.returncode != 0:
        return None, p.stdout + p.stderr
    # （终审 Minor 1：chmod 0o755 删除——Task 6 已修 ELF 输出 0755，此行为无操作）
    r = subprocess.run(["/tmp/dex_arith_bin"], capture_output=True, text=True, timeout=60)
    return r.returncode, r.stdout + r.stderr


def test_exact_arith_elf():
    code, out = build_run_exit(EXACT_SRC)
    if code != 0:
        print(f"[FAIL] exact arith ELF: exit={code}")
        print(out)
        return False
    print("[PASS] exact dex arith (3.14+2.86==6.0, 0.1+0.2==0.3, 1/10==0.1, fn boundary) exit 0")
    return True


def test_apx_binary64_elf():
    # apx：0.1b + 0.2b = 0.30000000000000004 != 0.3 → 程序返回 0
    code, out = build_run_exit(APX_SRC)
    if code != 0:
        print(f"[FAIL] apx binary64: exit={code} (expected 0: z != 0.3)")
        print(out)
        return False
    print("[PASS] apx path is binary64 (1.0b/3.0b != 0.3333333, z == 0.3333333 is false)")
    # apx + 字面量操作数：x / 3.0 同样 binary64
    code2, out2 = build_run_exit(APX_LIT_SRC)
    if code2 != 0:
        print(f"[FAIL] apx with literal operand: exit={code2}")
        print(out2)
        return False
    print("[PASS] apx with literal operand is binary64 (x / 3.0 != 0.3333333)")
    return True


def test_exact_literal_scaled_in_cir():
    # cir dump：精确字面量 3.14 → 缩放整数常量 3140000（非 binary64 位模式）
    src = "fn main() -> int:\n    a := 3.14\n    return 1\n"
    r = run_corec(["cir"], src)
    out = r.stdout + r.stderr
    if re.search(r"const\s+dex\s*=\s*3140000", out) is None:
        print("[FAIL] literal const should be scaled int 3140000 in cir dump")
        print(out)
        return False
    print("[PASS] cir dump: const dex = 3140000 (exact scaled literal)")
    return True


def test_dex_run_interp():
    # corec run 解释器：精确运算（裸 64 位整数路径）——run 取内联代码，非文件
    code = "fn main() -> int:\n    a := 0.1 + 0.2\n    if a == 0.3:\n        return 42\n    return 1\n"
    r = subprocess.run(
        [str(COREC), "run", code],
        cwd=BASE,
        capture_output=True,
        text=True,
        timeout=120,
    )
    if r.returncode != 42:
        print(f"[FAIL] corec run exact: exit={r.returncode}")
        print(r.stdout + r.stderr)
        return False
    print("[PASS] corec run interp: 0.1+0.2 == 0.3 (exit 42)")
    return True


def test_let_apx_to_exact_boundary():
    # 审查发现回归：LET 初始化按声明类型走槽位形式转换——`y : dex = x`（x apx bits）
    # 必须 bits → 6 位定点缩放（y 存缩放形式）；修复前 y 无 apx 标签却永久走 binary64
    code, out = build_run_exit(LET_APX_EXACT_SRC)
    if code != 0:
        print(f"[FAIL] LET apx→exact boundary: exit={code} (expected 0: 1.0/y == 0.3333333)")
        print(out)
        return False
    print("[PASS] LET apx→exact: y : dex = x (x apx 3.0), 1.0/y == 0.3333333 (scaled slot)")
    return True


def test_dex_mod_trunc_identity():
    # % 截断恒等式（5 指令序列 a - trunc(a/b)·b），含负数
    code, out = build_run_exit(MOD_SRC)
    if code != 0:
        print(f"[FAIL] dex mod trunc identity: exit={code} (expected 0)")
        print(out)
        return False
    print("[PASS] dex mod trunc identity (7.0%2.5=2.0, -7.0%2.5=-2.0, 1.0%0.3=0.1, -1.0%0.3=-0.1)")
    return True


def test_apx_cross_fn_boundary():
    # b1 调用点：apx 参数 bits → scaled（callee 收精确形式）；b2 返回点：apx bits → scaled
    code, out = build_run_exit(APX_BOUNDARY_SRC)
    if code != 0:
        print(f"[FAIL] apx cross-fn boundary: exit={code} (expected 0: call/ret bits→scaled)")
        print(out)
        return False
    print("[PASS] apx cross-fn boundary: call site (r==6.0) + return site (s==0.5) exact")
    return True


def test_apx_print_rounding():
    # Task 6 定稿：apx 打印 = 6 位定点舍入（半进）——0.1 → "0.1"（截断会得
    # "0.099999"）、1.0/3.0 → "0.333333"、1.0000006 → "1.000001"（截断得 "1"）、
    # -0.1 → "-0.1"（负半进）
    code, out = build_run_exit(APX_PRINT_SRC)
    if code != 0:
        print(f"[FAIL] apx print rounding: exit={code} (expected 0: 6-digit round-half-away)")
        print(out)
        return False
    print("[PASS] apx print = 6-digit rounding (0.1->'0.1', 1/3->'0.333333', 1.0000006->'1.000001', -0.1->'-0.1')")
    return True


def test_interp_rejects_apx_dex():
    # The interpreter has no binary64 conversion instructions. Reject the
    # path explicitly instead of returning a stale or silently truncated value.
    src = "fn main() -> int:\n    x : dex, apx = 0.1\n    return @raw_int(x)\n"
    r = subprocess.run(
        [str(COREC), "run", src],
        cwd=BASE,
        capture_output=True,
        text=True,
        timeout=120,
    )
    if r.returncode == 0 or "binary64" not in (r.stdout + r.stderr):
        print(f"[FAIL] interp should reject apx dex: exit={r.returncode}")
        print(r.stdout + r.stderr)
        return False
    print(f"[PASS] interp rejects apx dex with explicit error (exit={r.returncode})")
    return True


def test_extern_dex_arg_cir():
    """M2 终审回归：extern fn 的 dex 实参必须按 C ABI 传 binary64 bits。

    module.cr ABI 契约：dex 编码 3 = binary64 跨 C 边界。旧实现"原样直传"——
    字面量 3.14（缩放整数 3140000）被当 bits 直传。修复：extern 分支 TI_DEX_S 实参
    → dex_scaled_to_bits（字面量重发射位模式常量）。断言（cir dump）：
    main 内 extern 调用点前必须出现"缩放常量 + 位模式常量"序列（bits != 3140000）。
    运行时路径由 `test_extern_dex_static_link` 覆盖；本测试同时保留 IR
    断言，确认转换发生在调用点。
    """
    src = (
        "extern fn dex_ffi_bits_check(d: dex) -> int\nfn main() -> int:\n    r := dex_ffi_bits_check(3.14)\n    return r\n"
    )
    r = run_corec(["cir"], src)
    out = r.stdout + r.stderr
    m = re.search(
        r"const\s+dex\s*=\s*(\d+)\s*\n\s*const\s+dex\s*=\s*(\d+)\s*\n\s*call_extern",
        out,
    )
    if m is None:
        print("[FAIL] extern dex call site should show scaled-const + bits-const + call_extern")
        print(out)
        return False
    scaled, bits = int(m.group(1)), int(m.group(2))
    if scaled != 3140000:
        print(f"[FAIL] first const should be the scaled literal 3140000, got {scaled}")
        print(out)
        return False
    if bits == 3140000 or bits <= 0 or bits >= 1 << 63:
        print(f"[FAIL] second const should be binary64 bits of 3.14, got {bits}")
        print(out)
        return False
    print(f"[PASS] extern dex arg converted at call site: {scaled} (scaled) -> {bits} (binary64 bits)")
    return True


def test_extern_dex_static_link():
    """Static --link must relocate an extern call after embedding .so text."""
    src = (
        "extern fn dex_ffi_bits_check(d: dex) -> int\nfn main() -> int:\n    return dex_ffi_bits_check(3.14)\n"
    )
    ccr = BASE / "build" / "dex_ffi_runtime.ccr"
    binary = BASE / "build" / "dex_ffi_runtime"
    shim = BASE / "build" / "core_dex_ffi.so"
    try:
        compile_shim = subprocess.run(
            ["gcc", "-shared", "-fPIC", "-O2",
             str(BASE / "tests" / "fixtures" / "dex_ffi_shim.c"),
             "-o", str(shim)],
            cwd=BASE, capture_output=True, text=True, timeout=60,
        )
        if compile_shim.returncode != 0:
            print(f"[FAIL] extern dex shim build: exit={compile_shim.returncode}")
            print(compile_shim.stdout + compile_shim.stderr)
            return False
        r = run_corec(["ccr", "-o", str(ccr)], src)
        if r.returncode != 0:
            print(f"[FAIL] extern dex ccr generation: exit={r.returncode}")
            print(r.stdout + r.stderr)
            return False
        r = subprocess.run(
            [str(BASE / "build" / "corearch"), str(ccr), "--elf",
             "--link", str(shim), "--static", "-o", str(binary)],
            cwd=BASE, capture_output=True, text=True, timeout=180,
        )
        if r.returncode != 0 or not binary.exists():
            print(f"[FAIL] extern dex static link: exit={r.returncode}")
            print(r.stdout + r.stderr)
            return False
        os.chmod(binary, 0o755)
        run = subprocess.run([str(binary)], cwd=BASE, capture_output=True,
                             text=True, timeout=30)
        if run.returncode != 0:
            print(f"[FAIL] extern dex static runtime: exit={run.returncode}")
            print(run.stdout + run.stderr)
            return False
        print("[PASS] extern dex static --link relocates and runs")
        return True
    finally:
        for path in (ccr, binary):
            try:
                path.unlink()
            except FileNotFoundError:
                pass


def main():
    if not COREC.exists():
        print(f"[FAIL] missing native compiler: {COREC}")
        return 1
    results = [
        test_exact_arith_elf(),
        test_apx_binary64_elf(),
        test_exact_literal_scaled_in_cir(),
        test_dex_run_interp(),
        test_let_apx_to_exact_boundary(),
        test_dex_mod_trunc_identity(),
        test_apx_cross_fn_boundary(),
        test_apx_print_rounding(),
        test_interp_rejects_apx_dex(),
        test_extern_dex_arg_cir(),
        test_extern_dex_static_link(),
    ]
    passed = sum(results)
    print(f"{passed}/{len(results)} passed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
