#!/usr/bin/env python3
"""int 多字 M1 Task 4：消费者适配（tag 读路径 + tag 卫生）。

验证对象（src/arch/linux/ld/ instr.cr + elf.cr）：
  A. tag 卫生（定义点写，无帧入口清零——每 tagged 行的每个定值点都写 tag）：
     ① 快路径定值清 tag：tagged 变量被快路径 add/sub 重定义（同站点回边再
        执行——临时行 stale tag=1 会给拷贝传播错误值）；
     ② IR_STORE/IR_LOAD 定值拷贝 = 运行时 tag 拷贝（s2/s1 tagged → 拷贝
        tag 字节；untagged 源 → 清 0）；
     ③ 参数行 prologue 保存清 tag（tagged 参数行在函数内首次定值前的读取
        ——stale tag 会把 64 位参数误读为 2-limb 指针）。
  B. tag 读路径（消费者）：
     ① IR_RETURN：tag=1 → 解 2-limb 指针取低 limb → exit 低 8 位 =
        数学值低 8 位（无解引用 = 指针低字节 = 错值/随机）；
     ② 比较（int EQ/NE/LT/GT/LE/GE）：2-limb 参与比较 = 128 位比较
        （先高 limb 带符号、同则低 limb 无符号——低 limb 无符号是判别点）；
     ③ 链式运算：2-limb 值再参与 add/sub = 128 位全精度混合算术
        （2L+快 / 快+2L / 2L+2L——低+低进位链 + 高+高），结果可装回 64 位
        时降级为快值（down-normalize——保持「2L ⟹ |v|≥2^63 ⟹ 非零」不变量，
        IR_BRANCH 指针真值性因此保持正确）、否则新 2-limb 对象（hi 可出
        {0,−1} 域，如 −2^64−8 → hi=−2——128 位码域内无误差）；
     ④ fits-64 判定判别（d1/d2——Critical 修复护栏）：链达 −2^64−2
        （hi==lo==−2）/ 2^64+1（hi==lo==1）须保持 2L 并全 128 断言——
        fits 判据 hi==signmask(lo) 的 cmp 若错编成 hi vs lo（cmp r11,r10）
        即假拟合降级截断（静默错值，其余用例均不可见——唯一判别形态）。

验证通道（沿用 Task 3）：2-limb 对象原始 16B 经 syscall3(1,1,x,16) 写
stdout（x 槽 = 指针——call 参数走 M1 出逃边界，此处恰为直读面）。

需先重建自举编译器：nice -n 19 python3 build_selfhost_native.py
"""
import struct
import subprocess
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
BUILD = BASE / "build"
COREC = BUILD / "corec"
SCRATCH = BUILD / "mw_task4_scratch"

B62 = 1 << 62          # 4611686018427387904
NB63 = -(1 << 63) + 1  # -(2^63-1)：可写字面量下限


def limb_bytes(S):
    """128 位数学值 S（Python int）→ 2-limb 原始 16B（lo 小端 + hi 小端）。"""
    lo = S & ((1 << 64) - 1)
    hi = (S >> 64) & ((1 << 64) - 1)
    return struct.pack("<QQ", lo, hi)


# (name, src, 期望 stdout 流（None = 只看 exit）, 期望 exit, 意图)
CASES = [
    # ── B① return 解指针（无解引用 = exit = 指针低字节 ≠ 期望）──
    ("r1_ret_big_pos",
     "fn main() -> int {\n"
     "    x : ., mut = 4611686018427387910;\n"     # 2^62 + 6
     "    x = x + 4611686018427387904;\n"          # = 2^63+6（正溢出 2-limb）
     "    return x;\n}\n",
     None, 6, "return 2L：exit 低 8 位 = 数学值 2^63+6 的低字节 6（无 deref = 指针字节）"),
    ("r2_ret_big_neg",
     "fn main() -> int {\n"
     "    x : ., mut = -9223372036854775807;\n"    # -(2^63-1)
     "    x = x + -2;\n"                           # = -2^63-1（负溢出 2-limb）
     "    return x;\n}\n",
     None, 255, "return 2L 负值：低字节 0xFF = 255"),
    # ── B② 比较（判别：指针比较给反 / 低 limb 有符号给反）──
    ("c1_cmp_neg_lt_zero",
     "fn main() -> int {\n"
     "    x : ., mut = -9223372036854775807;\n"
     "    x = x + -2;\n"                           # -2^63-1（2-limb，hi=-1）
     "    if x < 0 { return 1; }\n"
     "    return 2;\n}\n",
     None, 1, "2L 负数 < 0 = 真（指针为正 → 指针比较给 2——判别）"),
    ("c2_cmp_2l_vs_fast_neg",
     "fn main() -> int {\n"
     "    x : ., mut = -9223372036854775807;\n"
     "    x = x + -2;\n"                           # -2^63-1（2-limb）
     "    if x > -5 { return 1; }\n"
     "    return 2;\n}\n",
     None, 2, "2L(-2^63-1) > -5 = 假（指针为正 → 给 1——判别）"),
    ("c3_cmp_lo_unsigned",
     "fn main() -> int {\n"
     "    x : ., mut = 4611686018427387904;\n"
     "    x = x + 1;\n"                            # 2^63+1（2L：hi=0 lo=2^63+1）
     "    if 5 < x { return 1; }\n"                # 快操作数在 s1（快+2L 分派）
     "    return 2;\n}\n",
     None, 1, "5 < 2^63+1 = 真——低 limb 须无符号比较（有符号 lo：5 > -2^63+1 → 给 2）"),
    ("c4_cmp_eq_diff_obj",
     "fn main() -> int {\n"
     "    a : ., mut = 4611686018427387904;\n"
     "    a = a + 4611686018427387904;\n"          # 2^63 对象 1
     "    b : ., mut = 4611686018427387904;\n"
     "    b = b + 4611686018427387904;\n"          # 2^63 对象 2（不同指针）
     "    if a == b { return 1; }\n"
     "    return 2;\n}\n",
     None, 1, "2L == 2L（同值异对象）：指针比较给 2——判别 128 位 EQ"),
    ("c5_cmp_ge_2l",
     "fn main() -> int {\n"
     "    a : ., mut = 4611686018427387904;\n"
     "    a = a + 4611686018427387904;\n"          # 2^63
     "    b : ., mut = 4611686018427387904;\n"
     "    b = b + 4611686018427387904;\n"          # 2^63
     "    if a >= b && a <= b { return 1; }\n"     # GE + LE（2L vs 2L 同值）
     "    return 2;\n}\n",
     None, 1, "2L GE/LE 同值链（布尔合并 = 比较结果再参与运算）"),
    # ── B③ 链式运算（2L 再参与 add/sub——128 位混合算术）──
    ("a1_chain_mixed_add",
     "fn main() -> int {\n"
     "    x : ., mut = 4611686018427387904;\n"
     "    x = x + 4611686018427387904;\n"          # 2^63（2-limb）
     "    x = x + 5;\n"                            # 2L + 快 → 2^63+5
     "    r := syscall3(1, 1, x, 16);\n    return r;\n}\n",
     limb_bytes((1 << 63) + 5), 16, "2L + 快正值：2^63+5（钩子验全 128）"),
    ("a2_chain_fast_first",
     "fn main() -> int {\n"
     "    x : ., mut = 4611686018427387904;\n"
     "    x = x + 4611686018427387904;\n"          # 2^63（2-limb）
     "    y : ., mut = 6;\n"
     "    y = y + x;\n"                            # 快在 s1 + 2L 在 s2（分派 B 路）
     "    r := syscall3(1, 1, y, 16);\n    return r;\n}\n",
     limb_bytes((1 << 63) + 6), 16, "快 + 2L（操作数序反转）：2^63+6"),
    ("a3_chain_sub_2l_fast",
     "fn main() -> int {\n"
     "    x : ., mut = 4611686018427387911;\n"     # 2^62 + 7
     "    x = x + 4611686018427387904;\n"          # 2^63+7（2-limb）
     "    x = x - 1;\n"                            # 2L − 快 → 2^63+6（仍 2L）
     "    r := syscall3(1, 1, x, 16);\n    return r;\n}\n",
     limb_bytes((1 << 63) + 6), 16, "2L − 快：2^63+6（保持 2L）"),
    ("a4_chain_sub_downnorm",
     "fn main() -> int {\n"
     "    x : ., mut = 4611686018427387904;\n"
     "    x = x + 4611686018427387904;\n"          # 2^63（2-limb）
     "    x = x - 5;\n"                            # = 2^63-5：可装 64 位 → 降级快值
     "    return x;\n}\n",
     None, 251, "2L − 快降级回 64 位：2^63−5 低字节 0xFB = 251"),
    ("a5_chain_2l_2l_neg_correc",
     "fn main() -> int {\n"
     "    x : ., mut = 4611686018427387904;\n"
     "    x = x + 4611686018427387904;\n"          # 2^63（2-limb）
     "    y : ., mut = -9223372036854775807;\n"
     "    y = y + -2;\n"                           # -2^63-1（2-limb，hi=-1）
     "    z : ., mut = x + y;\n"                   # 2L + 2L = -1 → 降级快值
     "    w : ., mut = z + 7;\n"
     "    return w;\n}\n",
     None, 6, "2L+2L 降级（2^63 + (-2^63-1) = -1 → 快值）+ 快链继续 → 6"),
    ("a6_chain_2l_2l_borrow",
     "fn main() -> int {\n"
     "    m : ., mut = -9223372036854775807;\n"
     "    m = m + -4;\n"                           # -2^63-3（2-limb hi=-1 lo=2^63-3）
     "    a : ., mut = 4611686018427387904;\n"
     "    a = a + 4611686018427387904;\n"          # 2^63
     "    b : ., mut = a + 5;\n"                   # 2^63+5（2-limb hi=0 lo=2^63+5）
     "    d : ., mut = m - b;\n"                   # (-2^63-3)-(2^63+5) = -2^64-8：
     "    r := syscall3(1, 1, d, 16);\n    return r;\n}\n",  # hi=-2（出 {0,-1} 域）lo=2^64-8
     limb_bytes(-(1 << 64) - 8), 16, "2L−2L 双 limb 借位链：−2^64−8 → hi=−2（128 码域内精确）"),
    ("a7_chain_loop_hi1",
     "fn main() -> int {\n"
     "    x : ., mut = 0;\n"
     "    i : ., mut = 0;\n"
     "    while i < 6 {\n"
     "        x = x + 4611686018427387904;\n"      # 每轮 +2^62：2^62→2^63(溢出 2L)
     "        i = i + 1;\n"                        # →3·2^62→2^64(hi=1)→…
     "    }\n"                                     # 6 轮 = 6·2^62 = 2^64+2^63
     "    r := syscall3(1, 1, x, 16);\n    return r;\n}\n",
     limb_bytes((1 << 64) + (1 << 63)), 16,
     "循环携带链：同站点 快→溢出→混合→hi=1（6·2^62 = 2^64+2^63）"),
    # ── 判别回归（fits-64 假拟合——hi==lo 恰在 {0,−1} 之外，其余用例不可见）──
    # d1/d2 链终值 hi==lo（−2^64−2 → hi=lo=−2；2^64+1 → hi=lo=1）：真 fits
    # 判据 hi == sar63(lo)（lo=−2 → −1 ≠ hi；lo=1 → 0 ≠ hi）→ 必须保持 2L。
    # fits 检查若错编成 cmp hi, lo（reg 字段误指 r10 而非 rdx）→ 假拟合 →
    # 降级截断（−2 / 1 快值落槽 + tag 0）→ syscall3 把快值当指针 → EFAULT
    # （红证据：stdout 空 + exit ≠ 16）。
    ("d1_chain_neg_fitdisc",
     "fn main() -> int {\n"
     "    m : ., mut = -9223372036854775807;\n"
     "    m = m + -2;\n"                            # -2^63-1（2L：hi=-1 lo=2^63-1）
     "    b : ., mut = 4611686018427387904;\n"
     "    b = b + 4611686018427387904;\n"           # 2^63（2L：hi=0 lo=2^63）
     "    b = b + 1;\n"                             # 2^63+1（2L：hi=0 lo=2^63+1）
     "    d : ., mut = m - b;\n"                    # (-2^63-1)-(2^63+1) = -2^64-2
     "    r := syscall3(1, 1, d, 16);\n    return r;\n}\n",
     # （lo=2^64-2 hi=2^64-2——同值非同 fit：lo 负 → signmask = -1 ≠ hi）
     limb_bytes(-(1 << 64) - 2), 16, "假拟合判别：−2^64−2 → hi==lo==−2 须保持 2L（错编 cmp hi,lo 截断 −2）"),
    ("d2_chain_pos_fitdisc",
     "fn main() -> int {\n"
     "    a : ., mut = 4611686018427387904;\n"
     "    a = a + 4611686018427387904;\n"           # 2^63（2L：hi=0 lo=2^63）
     "    b : ., mut = 4611686018427387904;\n"
     "    b = b + 4611686018427387904;\n"           # 2^63（2L：hi=0 lo=2^63）
     "    b = b + 1;\n"                             # 2^63+1（2L：hi=0 lo=2^63+1）
     "    c : ., mut = a + b;\n"                    # 2^63+(2^63+1) = 2^64+1
     "    r := syscall3(1, 1, c, 16);\n    return r;\n}\n",
     # （lo=1 hi=1——lo 正 → signmask = 0 ≠ hi）
     limb_bytes((1 << 64) + 1), 16, "假拟合判别：2^64+1 → hi==lo==1 须保持 2L（错编 cmp hi,lo 截断 1）"),
    # ── A 卫生：溢出后重定义/拷贝/参数，快值不得被误读为 2L ──
    ("h1_hygiene_store_redef",
     "fn main() -> int {\n"
     "    x : ., mut = 4611686018427387904;\n"
     "    x = x + 4611686018427387904;\n"          # 2^63（2-limb，tag=1）
     "    x = 7;\n"                                # 常量定值（IR_STORE 清 tag）
     "    return x;\n}\n",
     None, 7, "卫生：2L 后常量重定义 → return 快值 7（stale tag 会解引用 7 → 崩）"),
    ("h2_hygiene_site_reexec",
     "fn main() -> int {\n"
     "    x : ., mut = 4611686018427387904;\n"
     "    i : ., mut = 0;\n"
     "    while i < 3 {\n"
     "        x = x + 4611686018427387904;\n"      # 同站点回边：快(2^62)→溢出(2^63)
     "        x = x - 4611686018427387904;\n"      # 混合减法：→2^62（降级快）
     "        i = i + 1;\n"
     "    }\n"                                     # 每轮归位 → 终值 2^62
     "    x = x - 4611686018427387904;\n"          # → 0
     "    return x;\n}\n",
     None, 0, "卫生：同站点快/慢交替（stale tag=1 会把快值 2^62 解引用 → 崩）"),
    ("h3_hygiene_copy_prop",
     "fn main() -> int {\n"
     "    x : ., mut = 4611686018427387904;\n"
     "    x = x + 4611686018427387904;\n"          # 2^63（2-limb，tag=1）
     "    y := x;\n"                               # IR_STORE 拷贝 → tag 传播
     "    r := syscall3(1, 1, y, 16);\n"
     "    z := x as int;\n"                        # IR_LOAD 拷贝（as）→ tag 传播
     "    r2 := syscall3(1, 1, z, 16);\n"
     "    return r + r2;\n}\n",
     limb_bytes(1 << 63) * 2, 32, "拷贝链 tag 传播：y/z 都读到 2^63（无传播 = 指针低字节）"),
    ("h4_hygiene_param",
     # 参数行 prologue 清 tag 的回归护栏：call 1 令 p 以 2L 态（tag=1）离开
     # （函数内最后一次 p 定值 = 溢出的 p=p+2^62），call 2 若不清参数 tag，
     # p=p+2^62 站点会把 64 位参数值当 2L 指针解引用（值 ~4.6e18 → 崩）。
     "fn fb(p: int) -> int {\n"
     "    p = p + 4611686018427387904;\n"          # 2^62+6 → 2^63+6（2L tag=1）
     "    q : ., mut = p - p;\n"                   # 2L − 2L 同值 = 0 → 降级快值
     "    return q;\n}\n"
     "fn main() -> int {\n"
     "    r1 := fb(4611686018427387910);\n"        # 参数 2^62+6（64 位可载）
     "    r2 := fb(4611686018427387910);\n"        # 第 2 次调用（栈帧复用）
     "    return r1 + r2;\n}\n",
     None, 0, "卫生：参数 prologue 清 tag（2 次调用都须把 64 位参数当快值）"),
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
            os = __import__("os")
            os.chmod(out, 0o755)
            r = subprocess.run([str(out)], cwd=BASE, capture_output=True,
                               timeout=60)
            if want_stream is not None and r.stdout != want_stream:
                print(f"[FAIL] {name} @O{opt}: stdout {r.stdout.hex()} != "
                      f"{want_stream.hex()}\n  {desc}")
                ok = False
                continue
            if r.returncode != want_exit:
                print(f"[FAIL] {name} @O{opt}: exit {r.returncode} != "
                      f"{want_exit}\n  {desc}")
                ok = False
                continue
            print(f"[PASS] {name} @O{opt}: exit {r.returncode}"
                  + (f" stream={want_stream.hex()}" if want_stream else "")
                  + f"\n    {desc}")
        print()
    print("=== mw task4: " + ("ALL PASS" if ok else "FAILURES") + " ===")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
