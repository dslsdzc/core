#!/usr/bin/env python3
"""int 多字 M1 Task 6：溢出程序边界套件（M1 收官回归语料补全）。

Task 3 已覆盖 CF/op 判别矩阵（m1-m6），Task 4 已覆盖消费者判别
（return/比较/链式/卫生 r-a/h/d 系列）——本套件补 plan Task 6 要求的
**边界值组合**：i64max（2^63−1，最大可写字面量）±1 链、i64min（−2^63，
不可写为字面量——恰在编码边界的快值形态）邻域、负数与快慢混合、2L 在
上下边界处参与比较/链式/循环携带。全部用例 × {O0, O1, O2}。

边界事实（语料构造依据）：
- i64max = 9223372036854775807 是最大合法字面量（lexer i64max 幅守卫）；
  −2^63 字面量被拒 → i64min 快值只能经 −(2^63−1) + −1 构造（该步**不**
  溢出——OF 只发生在和 < −2^63，硬件判定与 128 码域在此分界）。
- 2L 值观测 = syscall3(1,1,x,16) 原始 16B 通道（spec §5：exit 只给低 8 位；
  全 128 断言经测试钩子）；快值终点 = return 低字节数学断言。
- 期望值全部为 Python 独立计算（limb_bytes），非从编译器输出回读。

验证面（每用例）：
1. 16B 流（期望 2L 的站点）逐字节 == 数学值 2-limb 表示——越界点确实走了
   慢路径且 128 位真值正确；
2. exit 码 == 16×对象数（有流）或 return 数学值低 8 位（快值终点）；
3. 边界比较真值表（e5-e7 判别：128 语义下唯一正确结果，任一「指针比较/
   低 limb 有符号/分派漏读」实现给反）。

需先重建自举编译器：nice -n 19 python3 build_selfhost_native.py
"""
import os
import subprocess
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
BUILD = BASE / "build"
COREC = BUILD / "corec"
SCRATCH = BUILD / "mw_task6_scratch"

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_mw_task4 import limb_bytes  # noqa: E402

S64 = 1 << 63
IMAX = S64 - 1          # 9223372036854775807（i64max——最大可写快值字面量）
IMIN1 = -IMAX           # -(2^63-1)（最小可写负字面量 = i64min+1）

# (name, src, 期望 stdout 流（None = 只看 exit）, 期望 exit, 意图)
CASES = [
    # ── 上边界：i64max +1 = 恰好一步越界（jo 正溢出 hi=0）──
    ("e1_max_plus1",
     "fn main() -> int {\n"
     "    x : ., mut = 9223372036854775807;\n"       # i64max（最大快值）
     "    x = x + 1;\n"                              # = 2^63 → 2L（hi=0 lo=0x8000..0）
     "    r := syscall3(1, 1, x, 16);\n    return r;\n}\n",
     limb_bytes(S64), 16, "上边界 +1：i64max → 2^63 恰好一步越界"),
    # ── 上边界往返：三步连续越界 + 降级回快值 + 再越界（fits 判据 lo 符号位）──
    ("e2_max_chain_roundtrip",
     "fn main() -> int {\n"
     "    x : ., mut = 9223372036854775807;\n"
     "    x = x + 1;\n"                               # 2^63（2L）
     "    x = x + 1;\n"                               # 2^63+1（2L+快链）
     "    x = x + 1;\n"                               # 2^63+2（2L）
     "    r1 := syscall3(1, 1, x, 16);\n"             # 流 1：2^63+2
     "    x = x - 3;\n"                               # = 2^63-1 = i64max → 降级快值
     "    x = x + 1;\n"                               # → 2^63（快→再越界 2L）
     "    r2 := syscall3(1, 1, x, 16);\n"             # 流 2：2^63
     "    return r1 + r2;\n}\n",
     limb_bytes(S64 + 2) + limb_bytes(S64), 32,
     "上边界往返：3 步越界链（2L+快）→ −3 降级回 i64max（fits：hi==signmask(2^63−1)==0）→ +1 再越界"),
    # ── 下边界邻域：快值恰在 −2^63（不溢出）+ add/sub 双越界 + 回升降级 ──
    ("e3_min_edge_addsub",
     "fn main() -> int {\n"
     "    x : ., mut = -9223372036854775807;\n"      # i64min+1（可写最小字面量）
     "    x = x + -1;\n"                             # = -2^63 **快值**（恰下边界——不 OF）
     "    x = x + -1;\n"                             # = -2^63-1 → 2L（hi=-1 lo=2^63-1）
     "    r1 := syscall3(1, 1, x, 16);\n"            # 流 1：-2^63-1
     "    x = x - 1;\n"                              # = -2^63-2 → 2L（sub 负溢出）
     "    r2 := syscall3(1, 1, x, 16);\n"            # 流 2：-2^63-2（lo=2^63-2）
     "    x = x + 3;\n"                              # = -2^63+1 → 降级快值（hi=-1==signmask(lo)）
     "    return x;\n}\n",                           # exit = (-2^63+1) 低字节 0x01
     limb_bytes(-S64 - 1) + limb_bytes(-S64 - 2), 1,
     "下边界：−(2^63−1)+−1 = −2^63 快值不溢出（负 OF 只发生在 < −2^63）→ add/sub 连续越界 → +3 降级回快值 return 1"),
    # ── sub 形式的上边界（i64max − −n）+ 降级后再越界 ──
    ("e4_sub_neg_edge",
     "fn main() -> int {\n"
     "    x : ., mut = 9223372036854775807;\n"       # i64max
     "    x = x - -1;\n"                             # = 2^63 → 2L（sub 正溢出 CF=1 → hi=0）
     "    r1 := syscall3(1, 1, x, 16);\n"            # 流 1：2^63
     "    x = x - 1;\n"                              # = 2^63-1 → 降级快值 i64max
     "    x = x - -2;\n"                             # = 2^63+1 → 快+快再越界（jo）
     "    r2 := syscall3(1, 1, x, 16);\n"            # 流 2：2^63+1
     "    return r1 + r2;\n}\n",
     limb_bytes(S64) + limb_bytes(S64 + 1), 32,
     "sub 边界：i64max − −1 = 2^63（CF 判别）→ −1 降级 → − −2 快→溢再越界"),
    # ── 上下边界同函数双站越界 + 2L vs 2L 高 limb 符号判别 ──
    ("e5_two_edge_cross_cmp",
     "fn main() -> int {\n"
     "    a : ., mut = 9223372036854775807;\n"
     "    a = a + 1;\n"                               # 2^63（2L hi=0——上边界越界）
     "    b : ., mut = -9223372036854775807;\n"
     "    b = b + -1;\n"                              # -2^63 快值
     "    b = b + -1;\n"                              # -2^63-1（2L hi=-1——下边界越界）
     "    r : ., mut = syscall3(1, 1, a, 16);\n"      # 流 1：2^63
     "    r = r + syscall3(1, 1, b, 16);\n"           # 流 2：-2^63-1
     "    if a > b { r = r + 1; }\n"                  # 2L(hi=0) > 2L(hi=-1)：高 limb 符号判别
     "    return r;\n}\n",                            # 16+16+1 = 33
     limb_bytes(S64) + limb_bytes(-S64 - 1), 33,
     "上下边界混合：双站（上/下各一步越界）+ 2L vs 2L 高 limb 判别（同低 limb 无符号形给反）"),
    # ── i64max 边界 fast↔2L 比较真值表（LT/GT 双分派 + EQ/GE 假性）──
    ("e6_max_cmp_dispatch",
     "fn main() -> int {\n"
     "    x : ., mut = 9223372036854775807;\n"
     "    x = x + 1;\n"                               # 2^63（2L）
     "    ok : ., mut = 0;\n"
     "    if 9223372036854775807 < x { ok = ok + 1; }\n"     # fast(s1) < 2L(s2)：B 路——紧贴边界的最大快值
     "    if x > 9223372036854775807 { ok = ok + 1; }\n"     # 2L(s1) > fast(s2)：A 路镜像
     "    if x == 9223372036854775807 { ok = ok - 10; }\n"   # 128 EQ 必须假（值不等）——恒真实现给 248
     "    if 9223372036854775807 >= x { ok = ok - 10; }\n"   # GE 必须假——(i64max, 2^63) 最紧假例
     "    return ok;\n}\n",
     None, 2, "i64max 边界比较真值表：max<2^63 两分派方向真、EQ/GE 假（−10 哨兵）"),
    # ── i64min 边界：快值 −2^63 vs 2L −2^63−1——同 hi 低 limb 无符号判别 ──
    ("e7_min_cmp_lo_unsigned",
     "fn main() -> int {\n"
     "    m : ., mut = -9223372036854775807;\n"
     "    m = m + -1;\n"                              # -2^63 快值（恰下边界，不 2L）
     "    n : ., mut = m;\n"
     "    n = n + -1;\n"                              # -2^63-1 → 2L（hi=-1 lo=2^63-1）
     "    o : ., mut = 0;\n"
     "    if n < m { o = o + 1; }\n"                  # hi 同为 -1（m 快值符号扩展）→ 低 limb 无符号：
     "    if m > n { o = o + 1; }\n"                  # n lo=2^63-1 < m lo=2^63 才真——有符号 lo 给反
     "    if n > m { o = o + 100; }\n"                # 反哨兵（错序 + 100）
     "    return o;\n}\n",
     None, 2, "i64min 边界：快值 −2^63 vs 2L −2^63−1——同 hi(−1) 低 limb 无符号判别（有符号 lo 给 101）"),
    # ── 循环携带越过上边界（同站点回边逐轮 2L 化）+ 独立快计数器 ──
    ("e8_loop_max_chain",
     "fn main() -> int {\n"
     "    x : ., mut = 9223372036854775807;\n"
     "    i : ., mut = 0;\n"
     "    while i < 3 {\n"
     "        x = x + 1;\n"                           # 每轮 +1：2^63 → 2^63+1 → 2^63+2
     "        i = i + 1;\n"                           # 快计数器（永不越界）
     "    }\n"
     "    r := syscall3(1, 1, x, 16);\n    return r;\n}\n",
     limb_bytes(S64 + 2), 16,
     "循环携带越过上边界：i64max 起每轮 +1（快→2L 同站点回边链）+ 独立快计数"),
]


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
    for name, src, want_stream, want_exit, desc in CASES:
        srcf = SCRATCH / f"{name}.cr"
        srcf.write_text(src, encoding="utf-8")
        for opt in (0, 1, 2):
            out = SCRATCH / f"{name}_o{opt}"
            if not run_checked([COREC, "build", srcf, "-o", out, "--static",
                                "-O", str(opt)], f"{name} @O{opt} build"):
                ok = False
                continue
            os.chmod(out, 0o755)
            r = subprocess.run([str(out)], cwd=BASE, capture_output=True,
                               timeout=60)
            if want_stream is not None:
                if r.stdout != want_stream:
                    print(f"[FAIL] {name} @O{opt}: stdout "
                          f"{r.stdout.hex()} != {want_stream.hex()} — "
                          f"2-limb 128 位流数学不正确\n  {desc}")
                    ok = False
                    continue
                ns = len(want_stream) // 16
                want_rc = want_exit if want_exit is not None else 16 * ns
                if r.returncode != want_rc:
                    print(f"[FAIL] {name} @O{opt}: exit {r.returncode} != "
                          f"{want_rc}（16B×{ns} 对象{'+比较加分' if want_exit != 16 * ns else ''}）")
                    ok = False
                    continue
            else:
                if r.returncode != want_exit:
                    print(f"[FAIL] {name} @O{opt}: exit {r.returncode} != "
                          f"{want_exit}（return 数学值低 8 位判别）\n  {desc}")
                    ok = False
                    continue
            print(f"[PASS] {name} @O{opt}: exit {r.returncode}"
                  + (f"，流 {len(want_stream)}B == {want_stream.hex()}"
                     if want_stream is not None else "")
                  + f"\n  {desc}")
        print()
    print("=== mw task6: " + ("ALL PASS" if ok else "FAILURES") + " ===")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
