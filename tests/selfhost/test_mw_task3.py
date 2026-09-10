#!/usr/bin/env python3
"""int 多字 M1 Task 3：慢路径 + 2-limb 表示运行时（jo 后数学修正 + 堆对象 + tag 写）。

验证对象（src/arch/x86_64/ instr.cr e2_mw_slow_block + src/format/elf/ elf.cr 函数尾块发射）：
  溢出（jo/OF=1）后 128 位真值修正：低 limb = 快路径环绕结果 r10；高 limb =
    add：CF ? -1 : 0（sbb r11,r11——正溢出 CF=0/负溢出 CF=1 推演）；
    sub：CF ? 0 : -1（sbb+not——正溢出借位 CF=1/负溢出混合符号无借位 CF=0）。
  存储：alloc(16)（与 IR_ALLOC_* 同 bump/arena 语义）→ [+0] lo / [+8] hi →
  dest 值槽存指针（含 O1/O2 reg 形态）+ tag 字节置位（g2_tag_off）→ jmp 回
  快路径 store 之后（resume）。

验证通道（全 128 位可观测）：溢出结果 2-limb 对象 16 原始字节经
  syscall3(1,1,x,16)（SYS_write，x 槽 = 对象指针——`x 值槽存指针`的直接可
  观测面）写 stdout → Python 断言 lo/hi。判别矩阵（CF/op 四象限，任一规则
  回退成另一 op 的规则即红）：
    m1 add 正溢出（CF=0）→ hi=0；m2 add 负溢出（CF=1）→ hi=-1；
    m3 sub 正溢出（CF=1）→ hi=0（若用 add 规则 → hi=-1 红）；
    m4 sub 负溢出（CF=0）→ hi=-1（若用 add 规则 → hi=0 红）；
    m5 同函数双 add 站点（两块独立发射）；m6 同函数 add+sub 混站（两块形状）。

需先重建自举编译器：nice -n 19 python3 build_selfhost_native.py
"""
import os
import struct
import subprocess
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
BUILD = BASE / "build"
COREC = BUILD / "corec"
SCRATCH = BUILD / "mw_task3_scratch"

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_mw_task1 import detect_tags, load_ir  # noqa: E402
from test_mw_task2 import jo_sites_oracle  # noqa: E402


def limb_bytes(S):
    """128 位数学值 S（Python int，∈ [-2^64, 2^64)）→ 2-limb 原始 16B
    （lo 小端 8B + hi 小端 8B——与 e2_mw_slow_block 的 [+0]/[+8] 布局一致）。"""
    return struct.pack("<QQ", S % (1 << 64), (S % (1 << 128)) >> 64)


# (name, src, 期望 128 位值, 意图)
S64 = 1 << 63
CASES = [
    ("m1_add_pos",
     "fn main() -> int {\n"
     "    x : ., mut = 4611686018427387904;\n"      # 2^62
     "    x = x + 4611686018427387904;\n"           # S = 2^63：正溢出 CF=0 → hi=0
     "    r := syscall3(1, 1, x, 16);\n    return r;\n}\n",
     S64, "add 正溢出：CF=0 → 高 limb = 0（lo=2^63 环绕 0x8000..0）"),
    ("m2_add_neg",
     "fn main() -> int {\n"
     "    x : ., mut = -9223372036854775807;\n"     # -(2^63-1)
     "    x = x + -2;\n"                            # S = -2^63-1：负溢出 CF=1 → hi=-1
     "    r := syscall3(1, 1, x, 16);\n    return r;\n}\n",
     -S64 - 1, "add 负溢出：CF=1 → 高 limb = -1（lo=2^63-1、hi=0xFF..F）"),
    ("m3_sub_pos",
     "fn main() -> int {\n"
     "    x : ., mut = 4611686018427387904;\n"      # 2^62
     "    x = x - -4611686018427387904;\n"          # S = 2^63：正溢出借位 CF=1 →
     "    r := syscall3(1, 1, x, 16);\n    return r;\n}\n",  # sub 规则 hi=0（add 规则会给 -1 → 红）
     S64, "sub 正溢出：CF=1 → 高 limb = 0（判别：add 规则在此给 -1）"),
    ("m4_sub_neg",
     "fn main() -> int {\n"
     "    x : ., mut = -4611686018427387905;\n"     # -(2^62+1)
     "    x = x - 4611686018427387904;\n"           # S = -2^63-1：负溢出（混合符号
     "    r := syscall3(1, 1, x, 16);\n    return r;\n}\n",  # 无借位 CF=0）→ sub 规则 hi=-1
     -S64 - 1, "sub 负溢出：CF=0 → 高 limb = -1（判别：add 规则在此给 0）"),
    ("m5_two_add_sites",
     "fn main() -> int {\n"
     "    x : ., mut = 4611686018427387904;\n"
     "    x = x + 4611686018427387904;\n"           # 站点 1：2^63
     "    r1 := syscall3(1, 1, x, 16);\n"
     "    y : ., mut = -9223372036854775807;\n"
     "    y = y + -2;\n"                            # 站点 2：-2^63-1
     "    r2 := syscall3(1, 1, y, 16);\n"
     "    return r1 + r2;\n}\n",
     None, "同函数双 add 站点：两独立块都执行、都正确（rc=32 + 32B 流）"),
    ("m6_mix_sites",
     "fn main() -> int {\n"
     "    a : ., mut = 4611686018427387904;\n"
     "    a = a - -4611686018427387904;\n"          # sub 正溢出 → 2^63
     "    r1 := syscall3(1, 1, a, 16);\n"
     "    b : ., mut = -4611686018427387905;\n"
     "    b = b - 4611686018427387904;\n"           # sub 负溢出 → -2^63-1
     "    r2 := syscall3(1, 1, b, 16);\n"
     "    c : ., mut = -9223372036854775807;\n"
     "    c = c + -2;\n"                            # add 负溢出 → -2^63-1
     "    r3 := syscall3(1, 1, c, 16);\n"
     "    return r1 + r2 + r3;\n}\n",
     None, "add+sub 混站：sub 块（含 not 修正）与 add 块同函数共存"),
]

EXPECT_STREAM = {
    "m1_add_pos": limb_bytes(S64),
    "m2_add_neg": limb_bytes(-S64 - 1),
    "m3_sub_pos": limb_bytes(S64),
    "m4_sub_neg": limb_bytes(-S64 - 1),
    "m5_two_add_sites": limb_bytes(S64) + limb_bytes(-S64 - 1),
    "m6_mix_sites": limb_bytes(S64) + limb_bytes(-S64 - 1) + limb_bytes(-S64 - 1),
}


def run_checked(args, label):
    cmd = ["nice", "-n", "19", *map(str, args)]
    r = subprocess.run(cmd, cwd=BASE, capture_output=True, text=True, timeout=600)
    if r.returncode != 0:
        print(f"[FAIL] {label}: exit {r.returncode}")
        print(r.stdout[-3000:])
        print(r.stderr[-3000:])
        return False
    return True


def main() -> int:
    if not COREC.exists():
        print("build/corec missing; run build_selfhost_native.py")
        return 1
    SCRATCH.mkdir(exist_ok=True)
    ok = True
    for name, src, _val, desc in CASES:
        srcf = SCRATCH / f"{name}.cr"
        srcf.write_text(src, encoding="utf-8")
        for opt in (0, 1, 2):
            out = SCRATCH / f"{name}_o{opt}"
            ccr = Path(str(out) + ".ccr")
            if not run_checked([COREC, "build", srcf, "-o", out, "--static",
                                "-O", str(opt)], f"{name} @O{opt} build"):
                ok = False
                continue
            # 站点数 oracle（同 test_mw_task2——发射侧 jo 数 = dest∈tagged 的
            # int ADD/SUB 指令数）：多站点用例要求站点数 == 溢出运算点数
            funcs, var_types = load_ir(ccr)
            _mainf, nsites = jo_sites_oracle(funcs, var_types)
            os.chmod(out, 0o755)
            r = subprocess.run([str(out)], cwd=BASE, capture_output=True,
                               timeout=60)
            want = EXPECT_STREAM[name]
            ns = len(want) // 16  # 期望写的对象数（单站 1 / 双站 2 / 三站 3）
            if r.stdout != want:
                print(f"[FAIL] {name} @O{opt}: stdout {r.stdout.hex()} != "
                      f"{want.hex()} — 2-limb 128 位值数学不正确 "
                      f"(sites={nsites}, 期望对象 {ns})\n  {desc}")
                ok = False
                continue
            if r.returncode != 16 * ns:
                print(f"[FAIL] {name} @O{opt}: exit {r.returncode} != "
                      f"{16 * ns}（16B × {ns} 对象）")
                ok = False
                continue
            print(f"[PASS] {name} @O{opt}: {ns} 对象 2-limb 流 == "
                  f"{want.hex()}（exit {r.returncode}，sites={nsites}，"
                  f"{desc}）")
        print()
    print("=== mw task3: " + ("ALL PASS" if ok else "FAILURES") + " ===")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
