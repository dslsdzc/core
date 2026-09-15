#!/usr/bin/env python3
"""全局行 operand seam 回归（2026-09-16 批；`src/arch/x86_64/instr.cr` + `src/os/linux/callseq.cr`）。

背景（RED，修复前实测；批计划 `docs/superpowers/plans/2026-09-16-global-operand-seams.md` §T1）：
`g2_slot`（`instr.cr`）对**全局行**（IR var 索引 < 当前函数 `var_start`）返回**帧外伪 rbp 偏移**
（指向调用者帧的合法位移）⇒ 任何直吃 `g2_slot` 的操作数读写点都**静默读写调用者帧**：
  * B1 `IR_BINARY`(TI_DEX) 双操作数 —— `g : dex, apx, mut = -100.0` + `if g > 0.0` ⇒ ELF 判真（7），
    局部对照判假（1）。
  * B2 `IR_I2F` 源 —— `h : dex, mut = -100.0`（全局）→ `d : dex, apx = h` ⇒ ELF 判真；h 局部 ⇒ 判假。
  * B4 `IR_SLICE` 数组指针/低界 —— 全局数组 + 全局低界 ⇒ 实测 ELF 71 vs 解释器 20（期望 20）。
  * B5 `IR_AWAIT` 源 —— `g : int, mut = 5; g = 9; x := await g` ⇒ ELF 26 vs 解释器 9。

**两条硬约束（写全局探针前必读）**：
  ① **必须用 `mut` 全局**：`find_global_const_node`（`ir_gen.cr:592-611`，要求 `ast_data(node) == 0`
     = 非 mut）把「不可变 + 字面量初值」的全局**折叠成 `IR_CONST`** ⇒ 读点根本不碰全局行 ⇒
     探针不触达被测面、假绿（本批 T1 第一轮即栽在此处；亦见 TODO.md dex/apx 迁移遗留节补注）。
  ② **apx 算术无解释器腿**：`corec run` 遇 `IR_I2F/IR_F2I` 的 apx 路径**显式报错 + rc=255**
     （能力边界、非缺陷）⇒ B1/B2 判据只走 ELF 腿，且**不得把 255 当错值信号**；主判据 =
     「**同形局部 vs 全局 ELF 对拍**」。

判据面：B1/B2/B4/B5 = 全局形 + 局部形（同值对拍）+ 正负号差分；B6(b) = **发射字节级**
（静态无 `.so` ⇒ extern 调用必崩 139，与全局实参无关——对照 `seam_ext(1.5)` 同样 139 ⇒ 无运行期腿）；
B7 = 非回归（非 dex 全局返回已正确）。
"""

import os
import resource
import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"


def _no_core_dump():
    # core_pattern 为 systemd-coredump 管道时，崩溃的陷阱程序会挂起——禁用 core dump。
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def _compile(source: str):
    fd, src = tempfile.mkstemp(suffix=".cr")
    with os.fdopen(fd, "w") as f:
        f.write(source)
    out = src[:-3]
    built = subprocess.run(
        [str(COREC), "build", src, "-o", out, "--static"],
        capture_output=True, text=True, cwd=BASE, timeout=180,
    )
    return built, out, src


def _cleanup(*paths):
    for p in paths:
        try:
            os.unlink(p)
        except FileNotFoundError:
            pass


def build_and_run(source: str):
    built, out, src = _compile(source)
    try:
        if built.returncode != 0:
            return f"compile-failed(rc={built.returncode}): {built.stdout}{built.stderr}"
        return subprocess.run(
            [out], capture_output=True, text=True, timeout=10,
            preexec_fn=_no_core_dump,
        )
    finally:
        _cleanup(src, out, out + ".ccr")


def case_run(name, source, expect_rc, interp_rc=None):
    """ELF 腿（build + 跑产物）为主判据；interp_rc 非 None 时附加 `corec run` 腿对照。"""
    r = build_and_run(source)
    if isinstance(r, str):
        print(f"[FAIL] {name}: {r}")
        return False
    if r.returncode != expect_rc:
        print(f"[FAIL] {name}: expected ELF rc {expect_rc}, got {r.returncode}")
        return False
    if interp_rc is not None:
        it = subprocess.run([str(COREC), "run", source], capture_output=True, text=True,
                            cwd=BASE, timeout=60)
        if it.returncode != interp_rc:
            print(f"[FAIL] {name}: expected interp rc {interp_rc}, got {it.returncode}"
                  f" ({it.stdout}{it.stderr})")
            return False
    print(f"[PASS] {name}: ELF rc={r.returncode}" + (f" / interp rc={interp_rc}" if interp_rc is not None else ""))
    return True


def case_elf_has(name, source, fragments):
    """发射字节级判据（无运行期腿时用）：构建产物须含全部正片段。"""
    built, out, src = _compile(source)
    try:
        if built.returncode != 0:
            print(f"[FAIL] {name}: compile-failed(rc={built.returncode}): {built.stdout}{built.stderr}")
            return False
        blob = Path(out).read_bytes()
        for label, want in fragments:
            if blob.find(want) < 0:
                print(f"[FAIL] {name}: 产物缺片段 {label} ({want.hex(' ')})")
                return False
        print(f"[PASS] {name}: 产物含 {len(fragments)} 条正片段（发射字节级）")
        return True
    finally:
        _cleanup(src, out, out + ".ccr")


# ── B1：IR_BINARY(TI_DEX) 双操作数（全局 vs 局部同形对拍 + 正负号差分）──
B1_NEG = """
g : dex, apx, mut = -100.0;
fn main() -> int {
    if g > 0.0 { return 7; }
    return 1;
}
"""
B1_POS = """
g : dex, apx, mut = 100.0;
fn main() -> int {
    if g > 0.0 { return 7; }
    return 1;
}
"""
B1_NEG_LOCAL = """
fn main() -> int {
    g : dex, apx, mut = -100.0;
    if g > 0.0 { return 7; }
    return 1;
}
"""

# ── B2：IR_I2F 源（scaled 全局 → apx；局部同形对照）──
B2_NEG = """
h : dex, mut = -100.0;
fn main() -> int {
    d : dex, apx = h;
    if d > 0.0 { return 7; }
    return 1;
}
"""
B2_POS = """
h : dex, mut = 100.0;
fn main() -> int {
    d : dex, apx = h;
    if d > 0.0 { return 7; }
    return 1;
}
"""
B2_NEG_LOCAL = """
fn main() -> int {
    h : dex, mut = -100.0;
    d : dex, apx = h;
    if d > 0.0 { return 7; }
    return 1;
}
"""

# ── B4：IR_SLICE 数组指针 + 低界（全局数组；局部对照；字面量低界隔离 s1/s2）──
B4_GLOBAL = """
g : [int;4] = [10, 20, 30, 40];
lo : int, mut = 1;
fn main() -> int {
    s := g[lo..3];
    return s[0];
}
"""
B4_LOCAL = """
fn main() -> int {
    g : [int;4] = [10, 20, 30, 40];
    lo : int, mut = 1;
    s := g[lo..3];
    return s[0];
}
"""

# ── B5：IR_AWAIT 源（int 全局运行期赋值 ⇒ 不可折叠；局部对照）──
B5_GLOBAL = """
g : int, mut = 5;
fn main() -> int {
    g = 9;
    x := await g;
    return x;
}
"""
B5_LOCAL = """
fn main() -> int {
    g : int, mut = 5;
    g = 9;
    x := await g;
    return x;
}
"""

# ── B6(b)：callseq dex 实参（单实参 extern = 恒不打包 ⇒ 全局实参直达分派）──
# 静态无 .so ⇒ 调用未解析符号必崩（对照 seam_ext(1.5) 同样 139）⇒ 判据只到发射字节。
B6B_EXTERN = """
g : dex, apx, mut = 1.5;
extern fn seam_ext(x: dex) -> dex;
fn main() -> int {
    y := seam_ext(g);
    if y != 3.0 { return 1; }
    return 7;
}
"""

# ── B7：非回归（非 dex 全局返回走 rax 路径，修复前后同字节）──
B7_RET_GLOBAL = """
g : int, mut = 5;
fn ret_g() -> int { return g; }
fn main() -> int { return ret_g(); }
"""


def main():
    # B6(b) 正片段：lea r11,[rip+disp32]（4c 8d 1d ??×4）后紧跟 movsd xmm0,[r11]（f2 0f 10 03）
    b6b_frags = [
        ("lea r11,[rip+disp32]", bytes.fromhex("4c8d1d")),
        ("movsd xmm0,[r11]", bytes.fromhex("f20f1003")),
    ]
    ok = [
        # B1：全局形判假（1）——修复前 ELF 判真（7）
        case_run("b1_global_neg_mut", B1_NEG, 1),
        case_run("b1_global_pos_mut", B1_POS, 7),
        case_run("b1_local_neg_mut_control", B1_NEG_LOCAL, 1),
        # B2：全局形判假（1）；局部对照同值
        case_run("b2_global_neg_mut", B2_NEG, 1),
        case_run("b2_global_pos_mut", B2_POS, 7),
        case_run("b2_local_neg_mut_control", B2_NEG_LOCAL, 1),
        # B4：切片首元素 = 20（修复前 ELF 71）；局部对照同值；解释器腿可用
        case_run("b4_slice_global", B4_GLOBAL, 20, interp_rc=20),
        case_run("b4_slice_local_control", B4_LOCAL, 20, interp_rc=20),
        # B5：await 全局读 = 9（修复前 ELF 26）；局部对照同值
        case_run("b5_await_global", B5_GLOBAL, 9, interp_rc=9),
        case_run("b5_await_local_control", B5_LOCAL, 9, interp_rc=9),
        # B6(b)：发射字节级（无运行期腿）
        case_elf_has("b6b_extern_global_arg_rip_form", B6B_EXTERN, b6b_frags),
        # B7：非回归
        case_run("b7_non_dex_global_return", B7_RET_GLOBAL, 5),
    ]
    passed = sum(ok)
    print(f"{passed}/{len(ok)} passed")
    return 0 if passed == len(ok) else 1


if __name__ == "__main__":
    raise SystemExit(main())
