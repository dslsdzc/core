#!/usr/bin/env python3
"""int 多字 M1 Task 2/3：快路径溢出检测发射（tagged int add/sub + jo → 慢路径块）。

验证对象（src/arch/linux/ld/）：
  - emit_instr IR_BINARY int（TI_INT）ADD/SUB：dest ∈ tagged 集（g2_tag_off(d)
    != -1——Task 1 规则 A 对域内 add/sub dest 无条件标记）→ e2_alu 后紧跟
    jo（0F 80 rel32——rel8 对函数尾附加的慢路径块在 >127B 函数体上不可达，
    t3 是此必要性的行为级断言）。
  - Task 3 起：函数尾每 jo 站点独立真实慢路径块（2-limb 修正 + alloc(16) +
    写 2-limb + dest 回存 + tag 置位 + 跳回 e2_st 之后——e2_mw_slow_block）；
    无 jo 的函数不发块、untagged 快路径零变化（z 用例逐字节验证）。
  - 块前缀 = push r10（41 52，确定性）——站点块定位锚。

行为层：无溢出 add（t1）jo 不触发、exit 正常；溢出 add（t2）jo 触发 →
慢路径块 → 2-limb 结果经测试钩子（syscall3 原始 16B 写 stdout——验全 128
位通道）assert 数学正确（本文件验 2^63 一例，全套验算在 test_mw_task3.py）；
t3 大函数 250 次 +1 无溢出 exit 250。

零 diff：z 用例（无 int 算术）需与改动前编译器输出逐字节一致。基线快照：
  python3 tests/selfhost/test_mw_task2.py --snapshot   # 改动前执行一次
产物存 build/mw_task2_zdiff/（build 目录不入库——缺基线时零 diff 断言 SKIP，
其余断言照跑；CI/新克隆需在改动前编译器上自产基线）。

需先重建自举编译器：nice -n 19 python3 build_selfhost_native.py
"""
import argparse
import os
import struct
import subprocess
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
BUILD = BASE / "build"
COREC = BUILD / "corec"
SCRATCH = BUILD / "mw_task2_scratch"
ZDIFF = BUILD / "mw_task2_zdiff"

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_mw_task1 import START_TAIL, detect_tags, find_main_frame, load_ir  # noqa: E402

# IR opcodes / ops（ast.cr，oracle 用——与 instr.cr mw_setup_tags 同源常量）
IR_BINARY = 2
OP_ADD = 1
OP_SUB = 2

# jo near rel32 = 0F 80 cd（6B）；慢路径块确定性前缀 = sbb r11, r11
# （4D 19——高 limb 修正首操作，add/sub 共用；sub 后随 48 F7 not）
JO_PAT = b"\x0f\x80"
BLK_PREFIX = b"\x4d\x19"

CASES = [
    # (name, exit, stdout_want(16B)/None, intent)
    ("t1_add", 0, None,
     "add 快路径无溢出（2e9+2e9=4e9 < 2^63）：jo 在但恒不触发——jo 发射断言 + 行为不变"),
    ("t2_add_overflow", 16, struct.pack("<QQ", 1 << 63, 0),
     "溢出（2^62+2^62=2^63 > i64max）触发 jo → 慢路径块 → 2-limb 数学正确："
     "测试钩子（syscall3 原始 16B 写 stdout）验 lo=2^63、hi=0（全 128 位通道）"),
    ("t3_bigfunc", 250, None,
     "250 次 +1（>127B 函数体）：jo rel32 必需性——每个 jo 仍可达其函数尾块，"
     "首 jo 距块 >127B（rel8 编码在回退时不可达）"),
    ("z1_noarith", 7, None, "untagged：无 int 算术——零 diff（与改动前快照逐字节一致）"),
    ("z2_copy", 100, None, "untagged：const/STORE 拷贝链（B' 无 tag 源）——零 diff"),
    ("z3_branch", 9, None, "untagged：BINARY cmp/分支/循环（无 ADD/SUB）——零 diff"),
]

SRCS = {
    "t1_add": "fn main() -> int {\n    a := 2000000000;\n    b := 2000000000;\n"
              "    c := a + b;\n    return c;\n}\n",
    "t2_add_overflow": "fn main() -> int {\n    x : ., mut = 4611686018427387904;\n"
                       "    x = x + 4611686018427387904;\n"
                       "    r := syscall3(1, 1, x, 16);\n    return r;\n}\n",
    "t3_bigfunc": None,  # Python 生成（250 次 x = x + 1）
    "z1_noarith": "fn main() -> int {\n    return 7;\n}\n",
    "z2_copy": "fn main() -> int {\n    a := 123456;\n    b := a;\n"
               "    c := b;\n    return 100;\n}\n",
    "z3_branch": "fn main() -> int {\n    x : ., mut = 0;\n"
                 "    while x > 0 {\n        x = 0;\n    }\n    return 9;\n}\n",
}
SRCS["t3_bigfunc"] = ("fn main() -> int {\n    x : ., mut = 0;\n"
                      + "\n".join("    x = x + 1;" for _ in range(250))
                      + "\n    return x;\n}\n")


def jo_sites_oracle(funcs, var_types):
    """期望 jo 数 = 该函数 IR 中 dest ∈ tagged 的 int ADD/SUB（发射侧
    g2_tag_off(d) != -1 条件的 oracle 同构——规则 A 使域内 add/sub dest
    恒入集，dest ∈ tags 等价于发射侧判定）。"""
    mains = [f for f in funcs if f["name"] == "main"]
    if len(mains) != 1:
        raise AssertionError(f"expected 1 main, got {[f['name'] for f in funcs]}")
    mainf = mains[0]
    tags = detect_tags(mainf, var_types)
    n = 0
    for (op, d, s1, s2, s3, tk, fe, ec) in mainf["nodes"]:
        if op == IR_BINARY and s3 in (OP_ADD, OP_SUB) and d in tags:
            n = n + 1
    return mainf, n


def find_main_region(elf_path, opt, frame):
    """main 代码区间 [start, ret_end)（text 相对偏移）：
    start = _start 尾 call main；main 区终点 = 其尾声 ret 之后（慢路径块即附
    于此、下一函数之前）——尾声字节模板由 opt 与 oracle 帧字节构造
    （add rsp,frame + pop rbp [+ pop r15..rbx] + ret——用户函数 ret 仅尾声
    一处，模板在函数体内出现的概率可忽略；main 之后是 stdlib 函数，不能用
    _init_globals 定位）。"""
    b = elf_path.read_bytes()
    text = b[176:]
    idx = text.find(START_TAIL)
    if idx < 5:
        raise AssertionError("cannot locate _start tail in ELF text")
    p = idx - 5
    rel = struct.unpack_from("<i", text, p + 1)[0]
    start = p + 5 + rel
    if start >= len(text):
        raise AssertionError("main offset out of text")
    if frame == 0:
        # 无帧函数：尾声 = pop rbp; ret（无 add rsp）
        tail = b"\x5d\xc3" if opt < 1 else b"\x5d\x41\x5f\x41\x5e\x41\x5d\x41\x5c\x5b\xc3"
    elif frame > 127:
        tail = b"\x48\x81\xc4" + struct.pack("<i", frame)
        tail += b"\x5d\xc3" if opt < 1 else b"\x5d\x41\x5f\x41\x5e\x41\x5d\x41\x5c\x5b\xc3"
    else:
        tail = b"\x48\x83\xc4" + bytes([frame])
        tail += b"\x5d\xc3" if opt < 1 else b"\x5d\x41\x5f\x41\x5e\x41\x5d\x41\x5c\x5b\xc3"
    e = text.find(tail, start + 8)
    if e < 0:
        raise AssertionError(f"cannot locate main epilogue tail ({tail.hex()}) "
                             f"after main@{start}")
    ret_end = e + len(tail)
    return text, start, ret_end


def scan_jos(text, start, end):
    """main 区域内 0F 80 jo rel32 扫描 → [(site, target)]（text 相对偏移）。"""
    out = []
    i = start
    while True:
        j = text.find(JO_PAT, i, end)
        if j < 0:
            break
        rel = struct.unpack_from("<i", text, j + 2)[0]
        out.append((j, j + 6 + rel))
        i = j + 6
    return out


def region_equal_mask_calls(a, b):
    """untagged main 区域指令流逐字节相等（快路径零变化断言）——例外：call
    rel32（E8）整窗跳过（位移目标 = 布局因 tagged 函数增长而合法移动的
    stdlib/runtime 函数）；E9 jmp rel32 目标在主内（epilogue/标签）不移动，
    照常比较。返回 (ok, 首差描述)。"""
    if len(a) != len(b):
        return False, f"region len {len(a)} != {len(b)}"
    i = 0
    while i < len(a):
        if a[i] != b[i]:
            return False, (f"byte@{i}: {a[i]:02x} != {b[i]:02x} "
                           f"ctx {a[max(0, i - 4):i + 6].hex()} vs "
                           f"{b[max(0, i - 4):i + 6].hex()}")
        if a[i] == 0xE8:
            i = i + 5  # call rel32：位移随被调函数布局移动——合法差异
            continue
        i = i + 1
    return True, None


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
    ap = argparse.ArgumentParser()
    ap.add_argument("--snapshot", action="store_true",
                    help="生成零 diff 基线（须在改动前编译器上运行）")
    ap.add_argument("--skip-zdiff", action="store_true",
                    help="跳过零 diff 字节比较（即使基线存在）")
    args = ap.parse_args()
    if not COREC.exists():
        print("build/corec missing; run build_selfhost_native.py")
        return 1
    SCRATCH.mkdir(exist_ok=True)
    if args.snapshot:
        ZDIFF.mkdir(exist_ok=True)
    ok = True
    for name, want_exit, want_out, desc in CASES:
        src = SCRATCH / f"{name}.cr"
        src.write_text(SRCS[name], encoding="utf-8")
        for opt in (0, 1, 2):
            out = SCRATCH / f"{name}_o{opt}"
            ccr = Path(str(out) + ".ccr")
            if not run_checked([COREC, "build", src, "-o", out, "--static",
                                "-O", str(opt)], f"{name} @O{opt} build"):
                ok = False
                continue
            if not ccr.exists():
                print(f"[FAIL] {name} @O{opt}: no .ccr at {ccr}")
                ok = False
                continue
            funcs, var_types = load_ir(ccr)
            mainf, exp = jo_sites_oracle(funcs, var_types)
            try:
                frame = find_main_frame(out, opt)
            except AssertionError as e:
                print(f"[FAIL] {name} @O{opt}: prologue parse: {e}")
                ok = False
                continue
            try:
                text, m0, m1 = find_main_region(out, opt, frame)
            except AssertionError as e:
                print(f"[FAIL] {name} @O{opt}: region parse: {e}")
                ok = False
                continue
            jos = scan_jos(text, m0, m1)
            # ── jo 个数断言（untagged 用例：exp=0 → 不得有任何 0F 80）──
            if len(jos) != exp:
                print(f"[FAIL] {name} @O{opt}: jo sites {len(jos)} != oracle {exp} "
                      f"(tags={len(detect_tags(mainf, var_types))}) — {desc}")
                ok = False
                continue
            if exp == 0:
                print(f"[PASS] {name} @O{opt}: no jo (oracle {exp}); region "
                      f"[{m0},{m1}) len={m1 - m0} (desc: {desc})")
            else:
                # Task 3：每站点独立慢路径块——jo rel32 目标 = 各自块
                # （发射序 = 指令序 → 扫描序；首站点块 = 尾声 ret 后首字节
                # m1；块前缀 = sbb r11,r11 4D 19 确定性锚）。
                targets = [t for (_, t) in jos]
                if jos[0][1] != m1:
                    print(f"[FAIL] {name} @O{opt}: first jo target {jos[0][1]} "
                          f"!= block region start {m1}")
                    ok = False
                    continue
                bad_pre = [t for t in targets if text[t:t + 2] != BLK_PREFIX]
                bad_ord = [t for t in targets if t < m1]
                if bad_pre or bad_ord:
                    print(f"[FAIL] {name} @O{opt}: block targets invalid — "
                          f"prefix-miss {[t for t in bad_pre]} "
                          f"pre-epilogue {bad_ord}")
                    ok = False
                    continue
                if any(targets[i] >= targets[i + 1] for i in range(len(targets) - 1)):
                    print(f"[FAIL] {name} @O{opt}: block targets not strictly "
                          f"increasing: {targets}")
                    ok = False
                    continue
                dmax = targets[0] - jos[0][0]  # 首 jo 距其块（= m1 − jo0）
                print(f"[PASS] {name} @O{opt}: {len(jos)} jo -> per-site blocks "
                      f"@{targets[0]}..+{targets[-1] - targets[0]} "
                      f"(first-jo dist {dmax}B, desc: {desc})")
                if name == "t3_bigfunc" and opt == 0:
                    # rel32 必需性：最远 jo 距块 >127B——rel8 编码不可达，回退必红
                    if dmax <= 127:
                        print(f"[FAIL] {name} @O{opt}: farthest jo-block dist "
                              f"{dmax} <= 127 — t3 失去 rel32 判别力")
                        ok = False
            # ── 行为（t2 溢出 → 2-limb 修正 + 测试钩子验 16B；其余 exit 码）──
            os.chmod(out, 0o755)
            r = subprocess.run([str(out)], cwd=BASE, capture_output=True, timeout=60)
            if r.returncode != want_exit:
                print(f"[FAIL] {name} @O{opt}: run exit {r.returncode}, "
                      f"want {want_exit}")
                ok = False
            else:
                print(f"[PASS] {name} @O{opt}: run exit {r.returncode}")
            if want_out is not None:
                if r.stdout != want_out:
                    print(f"[FAIL] {name} @O{opt}: stdout {r.stdout.hex()} != "
                          f"expected {want_out.hex()} (lo/hi 2-limb 全 128 位)")
                    ok = False
                else:
                    print(f"[PASS] {name} @O{opt}: stdout 16B == {want_out.hex()} "
                          f"(2-limb lo/hi 正确)")
            # ── 零 diff：untagged 用例 main 指令流 == 改动前快照（E8 call
            # 位移例外——stdlib 函数因 tagged 代码合法增长而整体后移）──
            if name.startswith("z") and not args.skip_zdiff:
                bl = ZDIFF / f"{name}_o{opt}.bin"
                if bl.exists():
                    bt, b0, b1 = find_main_region(bl, opt, frame)
                    same, why = region_equal_mask_calls(text[m0:m1],
                                                        bt[b0:b1])
                    if not same:
                        print(f"[FAIL] {name} @O{opt}: main stream differs vs "
                              f"pre-change baseline: {why}")
                        ok = False
                    else:
                        print(f"[PASS] {name} @O{opt}: main instruction stream "
                              f"identical vs pre-change baseline")
                elif args.snapshot:
                    import shutil
                    shutil.copyfile(out, bl)
                    print(f"[SNAP] {name} @O{opt}: baseline saved {bl.name}")
                else:
                    print(f"[SKIP] {name} @O{opt}: no zero-diff baseline "
                          f"(run --snapshot on pre-change compiler)")
            print()
    print("=== mw task2: " + ("ALL PASS" if ok else "FAILURES") + " ===")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
