#!/usr/bin/env python3
"""int 多字 M1 Task 5：D6 分配器适配——现状确认 + 测试加固（裁决：不改）。

plan D6 原案：「tagged（潜在多字）变量排除寄存器分配（只栈）」。执行前核
实现状（Task 4 concern #1 消费点确认）后裁决：**reg 形态自洽成立，D6 排除
不实施**。依据：

  1. 表示演进使 D6 原始动机失效：plan 写作时的「多字值不可驻单寄存器」前提
     在最终 D1a 表示（值槽 = 64 位快值或 2-limb 堆对象**指针** + 帧旁路 tag
     字节）下不成立——寄存器驻留的是指针，128 位载荷在堆对象；
  2. 单 seam 结构保证：全部变量值读写经 g2_slot（含 Task 3 jo 慢路径块回存
     e2_mov(dst_reg,rax)、Task 4 2L 操作数块装载、return 解指针、tag 卫生
     落值）——tag 读写经 g2_tag_off（帧字节，与值形态无关）；强制栈例外仅
     prologue 参数保存/寄存器参数装载（消费任何 tag 之前）；表（HIT）路径
     preflight 已拒 reg 形态变量（hit_ev_slot_addr_ok → 落旧路径）；
  3. O2 实证：tagged 变量**确实**被 CAG 分配寄存器（含 2L 态驻留——本测试
     元断言），且 task3/4 电池 60 组 O2 全绿（16B 通道全 128 断言）——
     reg 形态下 2L 语义可运行且精确；
  4. 排除零收益有代价：发射侧无独立 reg/栈路径可删（块对 g2_slot 参数化，
     单代码路径），排除只损 O2 性能（tagged = 最常见的 add 循环变量行）。

本测试 = 该裁决的可执行形态（若将来翻案改只栈，下列 O2 元断言会红——届时
须同步更新本文件并给出新证据）：

  A. 行为（O0/O1/O2）：三类 2L 态用例全绿（exit + syscall3 16B 全 128
     通道）——与 task3/4 语义面重叠，但此处与 B 的元断言同用例链接；
  B. 元断言（2026-09-07 regalloc 移后端后载体 = corearch --dump-regassign：
     .ccr 不再携带 REG_ASSIGN（R2/D-1=Y）——corearch load 后自算；dump 通道
     按 --opt-level 门逐对输出 var→reg。oracle 识别规则 = test_mw_task1）：
     - O1：corearch -O1 dump = 空（分配门 = opt_level ≥ 2——O1 tagged 变量
       恒全栈，只栈平凡成立）；
     - O2：corearch -O2 dump：指定函数（运行时确实发生 2L 溢出的函数）
       tagged∩REG_ASSIGN ≠ ∅ ——「2L 态值驻寄存器 + 行为全绿」链接成立 =
       reg 形态自洽的活体实证。

.ccr 结构读取 = test_mw_task1.load_ir/detect_tags（oracle 复刻识别规则）；
meta 元数据改经 corearch --dump-regassign（分配真相源 = corearch 内存态）。
"""
import os
import re
import struct
import subprocess
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
BUILD = BASE / "build"
COREC = BUILD / "corec"
COREARCH = BUILD / "corearch"
SCRATCH = BUILD / "mw_task5_scratch"

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_mw_task1 import load_ir, detect_tags  # noqa: E402

REGASSIGN_LINE = re.compile(r"^regassign: (\d+) (\d+)$", re.MULTILINE)


def limb_bytes(S):
    """128 位数学值 S → 2-limb 原始 16B（lo 小端 + hi 小端）。"""
    lo = S & ((1 << 64) - 1)
    hi = (S >> 64) & ((1 << 64) - 1)
    return struct.pack("<QQ", lo, hi)


def dump_regassign(ccr_path, opt_level) -> dict:
    """corearch --dump-regassign 通道（regalloc 移后端）：corearch load .ccr
    后按 --opt-level 门自算（O2 = 分配）并逐对输出 var→reg。O0/O1 → 空。

    返回 {var_idx: reg}（.ccr 不再携带 REG_ASSIGN——分配结果同进程消费，
    元断言改从此通道取分配真相源）。"""
    r = subprocess.run(["nice", "-n", "19", str(COREARCH), str(ccr_path),
                        "--dump-regassign", "--opt-level", str(opt_level)],
                       cwd=BASE, capture_output=True, text=True, timeout=120)
    if r.returncode != 0:
        raise RuntimeError(f"corearch --dump-regassign rc={r.returncode}: "
                           f"{r.stdout[-500:]} {r.stderr[-500:]}")
    pairs = {}
    for ln in r.stdout.splitlines():
        m = REGASSIGN_LINE.match(ln.strip())
        if m:
            pairs[int(m.group(1))] = int(m.group(2))
    return pairs


# (name, src, 2L 溢出所在函数名, 期望 stdout（None = 只看 exit）, 期望 exit, 意图)
CASES = [
    # h4 同形：参数行 2L 态 + 跨调用帧复用（O2 下 fb 的 p/q 驻 callee-saved）
    ("t5_param_2l_reg",
     "fn fb(p: int) -> int {\n"
     "    p = p + 4611686018427387904;\n"          # 2^62+6 → 2^63+6（2L，tag=1）
     "    q : ., mut = p - p;\n"                   # 2L − 2L 同值 = 0 → 降级快值
     "    return q;\n}\n"
     "fn main() -> int {\n"
     "    r1 := fb(4611686018427387910);\n"
     "    r2 := fb(4611686018427387910);\n"
     "    return r1 + r2;\n}\n",
     ["fb"], None, 0, "O2 元断言目标：fb 的 p/q tagged 且驻寄存器；2 次调用绿"),
    # a7 同形：循环携带 2L 态跨迭代驻 reg（每轮 jo 慢路径 + alloc 新对象）
    ("t5_loop_carry_2l_reg",
     "fn main() -> int {\n"
     "    x : ., mut = 0;\n"
     "    i : ., mut = 0;\n"
     "    while i < 6 {\n"
     "        x = x + 4611686018427387904;\n"      # 每轮 +2^62：→2^63(2L)…
     "        i = i + 1;\n"
     "    }\n"                                     # 6 轮 = 2^64+2^63（hi=1）
     "    r := syscall3(1, 1, x, 16);\n    return r;\n}\n",
     ["main"], limb_bytes((1 << 64) + (1 << 63)), 16,
     "O2 元断言目标：循环携带 x 驻 reg 且运行时达 2L 态（hi=1）——16B 通道验证"),
    # c5 同形：双 2L 对象比较（a/b 各自溢出生 2L 堆对象，比较读 tag 解指针）
    ("t5_two2l_cmp_reg",
     "fn main() -> int {\n"
     "    a : ., mut = 4611686018427387904;\n"
     "    a = a + 4611686018427387904;\n"          # 2^63（2-limb 对象 1）
     "    b : ., mut = 4611686018427387904;\n"
     "    b = b + 4611686018427387904;\n"          # 2^63（2-limb 对象 2）
     "    if a >= b && a <= b { return 1; }\n"
     "    return 2;\n}\n",
     ["main"], None, 1, "O2 元断言目标：a/b 2L 态驻 reg；128 位比较绿"),
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
    for name, src, ovf_funcs, want_stream, want_exit, desc in CASES:
        srcf = SCRATCH / f"{name}.cr"
        srcf.write_text(src, encoding="utf-8")
        for opt in (0, 1, 2):
            out = SCRATCH / f"{name}_o{opt}"
            if not run_checked([COREC, "build", srcf, "-o", out, "--static",
                                "-O", str(opt)], f"{name} @O{opt} build"):
                ok = False
                continue
            ccr = SCRATCH / f"{name}_o{opt}.ccr"
            if not ccr.exists():
                print(f"[FAIL] {name} @O{opt}: .ccr missing at {ccr}")
                ok = False
                continue
            funcs, var_types = load_ir(ccr)
            if opt == 1:
                regs = dump_regassign(ccr, 1)
                if regs:
                    print(f"[FAIL] {name} @O1: corearch dump REG_ASSIGN = "
                          f"{len(regs)} != 0（O1 不应有寄存器分配——分配门 = O2）")
                    ok = False
                else:
                    print(f"[PASS] {name} @O1: REG_ASSIGN = 0（全栈，tagged 只栈平凡）")
            if opt == 2:
                regs = dump_regassign(ccr, 2)
                # 元断言：运行时 2L 溢出所在函数内 tagged∩REG_ASSIGN ≠ ∅
                hit = False
                for f in funcs:
                    if f["name"] not in ovf_funcs:
                        continue
                    vs = f["var_start"]
                    ve = vs + f["var_count"]
                    tg = detect_tags(f, var_types)
                    ins = sorted(v for v in tg if vs <= v < ve and v in regs)
                    if ins:
                        hit = True
                        print(f"[PASS] {name} @O2 元断言: func {f['name']} "
                              f"tagged∩regs={[(v, regs[v]) for v in ins]}")
                if not hit:
                    print(f"[FAIL] {name} @O2 元断言: {ovf_funcs} 内无 tagged 变量"
                          "被分配寄存器——reg 形态裁决失效（详见测试头注释）")
                    ok = False
            # 行为断言（与 task3/4 同语义面；此处与上列元断言同用例链接）
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
    print("=== mw task5: " + ("ALL PASS" if ok else "FAILURES") + " ===")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
