#!/usr/bin/env python3
"""int 多字 M1 Task 1：tagged 槽框架（潜在多字变量识别 + tag 区 + 栈布局）。

验证对象（架构轴 src/arch/x86_64/ + 格式轴 src/format/elf/）：
  - mw_setup_tags（tag2l.cr——波 1 Task 4 自 instr.cr 整搬；tag 表 owner）：
    per 函数潜在多字识别 → tag 字节偏移表。
    识别 = 不动点闭包（评审修复：单遍前向对循环携带值不成立——tag 态可沿
    回边携带）：
      A. IR_BINARY(OP_ADD/OP_SUB) 的 dest（add/sub 溢出 = M1 唯一 >64 生产者）；
      B. IR_LOAD 值拷贝 d←s1（as 转换拷贝）：s1 已标 → 标 d；
      B'. IR_STORE 定值拷贝 ρ(s1):=ρ(s2)（ir_gen 赋值形态，真实槽拷贝载体）：
          s2 已标 → 标 s1——变量行（return/比较消费的槽）只经 STORE 得到值，
          只标临时行不够；
    重复全扫至无新标（单调 ⇒ ≤ vc+1 遍收敛）。
  - tag 区栈布局：帧 = vc*8 + tag_count，按 SysV 16 对齐规则取整；
    无 tagged 变量的函数帧公式与旧版逐字节一致（快路径零变化）；
  - 布局可观测面：ELF 中函数 prologue 的 sub rsp 立即数 = 帧总字节。

方法：Python 独立复刻识别规则（对 .ccr 二进制格式的旁路 oracle——不同实现
互相校验），从 .ccr 读 per 函数 var 域/指令流/变量类型，按上述规则做不动点，
算出期望 tag 数与期望帧字节；再从 ELF 文本段定位 main（_start 尾 call main
的模式）并解析其 prologue 的 sub rsp 立即数，断言相等。行为层再跑一遍产物体
核对 exit code。s6（循环携带拷贝）另断言不动点 ⊋ 单遍（防止 oracle/实现被
回退成单遍而重新掩盖评审发现）。

.ccr 读取依赖 v7 段表布局（test_ccr_v7.py 的 V7File 为格式唯一真源——格式
演进时只需改那边；Task 3 v7 收官后 test_ccr_v6.py 已退役合并，本文件别名
V6File 仅为调用点命名惯性——语义 = v7 walker，见 import 行注释）。
"""
import os
import struct
import subprocess
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
BUILD = BASE / "build"
COREC = BUILD / "corec"
SCRATCH = BUILD / "mw_task1_scratch"

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_ccr_v7 import V7File as V6File  # noqa: E402  (v7 段表解析器 = 格式唯一真源；别名保调用点不变)

# IR opcodes (ast.cr)
IR_BINARY = 2
IR_LOAD = 10
IR_STORE = 9
OP_ADD = 1
OP_SUB = 2
TI_INT = 0


def load_ir(ccr_path):
    """v6 .ccr → (funcs, var_types)。

    funcs:  list of {name, var_start, var_count, nodes}——nodes = 本函数节点切片
            （NOD 全表按 REG root region [enter, exit) 切）；
            var_start = globals 行 + 前缀函数块行序游标（SYM func 记录序累加）。
    var_types: {var_idx: tk}（SYM func 内嵌声明区：行序 = 函数块内索引）。
    """
    v = V6File(ccr_path.read_bytes())
    strs = v.str_table()
    sym = v.sym_parse()
    nods = v.nod()
    regs = v.reg()
    var_types = {}
    funcs = []
    vs = len(sym["globals"])
    for f in sym["funcs"]:
        n0, n1 = regs[f["root_region"]][2], regs[f["root_region"]][3]
        if n0 < 0 or n1 > len(nods) or n0 >= n1:
            raise AssertionError(f"func {f['name']}: bad node span [{n0},{n1}) "
                                 f"of {len(nods)}")
        for i, decl in enumerate(f["var_decls"]):
            var_types[vs + i] = decl["type"]
        funcs.append(dict(name=strs[f["name"]], var_start=vs,
                          var_count=f["var_count"], nodes=nods[n0:n1]))
        vs += f["var_count"]
    return funcs, var_types


def detect_tags(func, var_types, max_passes=None, store_edges=True):
    """复刻 tag2l.cr mw_setup_tags：规则 A + B(IR_LOAD 拷贝) + B'(IR_STORE
    定值拷贝)，重复全扫至无新标。

    退化形态（仅区分性断言用）：
      max_passes = 1 → 单遍前向（含 B'——评审缺陷形态：回边携带漏标）；
      store_edges = False → 无 B'（评审前实现规则：A+B，变量行永不入集）。
    """
    vs = func["var_start"]
    ve = vs + func["var_count"]
    tagged = set()

    def in_dom(x):
        return vs <= x < ve and var_types.get(x, -1) == TI_INT

    npass = 0
    while True:
        changed = False
        for (op, d, s1, s2, s3, tk, fe, ec) in func["nodes"]:
            if op == IR_BINARY:
                if in_dom(d) and s3 in (OP_ADD, OP_SUB) and d not in tagged:
                    tagged.add(d)
                    changed = True
            elif op == IR_LOAD:
                if (in_dom(d) and s1 in tagged and in_dom(s1)
                        and d not in tagged):
                    tagged.add(d)
                    changed = True
            elif op == IR_STORE and store_edges:
                # 定值拷贝 ρ(s1) := ρ(s2)（dest 恒 -1）
                if (in_dom(s1) and s2 in tagged and in_dom(s2)
                        and s1 not in tagged):
                    tagged.add(s1)
                    changed = True
        npass += 1
        if not changed:
            break
        if max_passes is not None and npass >= max_passes:
            break
    return tagged


def frame_total(vc, n, opt):
    """复刻 frame.cr pf_frame_size（含 tag 区 + SysV 16 对齐；x86 实例化波 1
    Task 3 自 instr.cr mw_frame_size 迁入并改名——公式 verbatim）。"""
    sz = vc * 8 + n
    if opt >= 1:
        if sz % 16 != 8:
            pad = (8 - sz % 16) % 16
            sz += pad
    else:
        if sz % 16 != 0:
            sz += 16 - sz % 16
    return sz


# _start 尾模式：mov edi,eax(89 C7) + mov eax,60(B8 3C000000) + syscall(0F 05)
START_TAIL = b"\x89\xc7\xb8\x3c\x00\x00\x00\x0f\x05"


def find_main_frame(elf_path, opt):
    """定位 main（_start 内 call main 的 E8 rel32 紧跟 START_TAIL）并解析帧字节。"""
    b = elf_path.read_bytes()
    text = b[176:]
    idx = text.find(START_TAIL)
    if idx < 5:
        raise AssertionError("cannot locate _start tail in ELF text")
    p = idx - 5  # E8 位置（text 相对）
    rel = struct.unpack_from("<i", text, p + 1)[0]
    main_off = p + 5 + rel  # 相对 text 起点（= 文件 176）的偏移
    if main_off >= len(text):
        raise AssertionError("main offset out of text")
    m = main_off
    # prologue
    if opt >= 1:
        # push rbx(53) push r12-r15(41 54..57) push rbp(55) mov rbp,rsp(48 89 e5)
        assert text[m:m + 13] == b"\x53\x41\x54\x41\x55\x41\x56\x41\x57\x55\x48\x89\xe5", \
            text[m:m + 13].hex()
        m += 13
    else:
        assert text[m:m + 4] == b"\x55\x48\x89\xe5", text[m:m + 4].hex()
        m += 4
    if text[m] == 0x48 and text[m + 1] == 0x83 and text[m + 2] == 0xEC:
        return text[m + 3]
    if text[m] == 0x48 and text[m + 1] == 0x81 and text[m + 2] == 0xEC:
        return struct.unpack_from("<i", text, m + 3)[0]
    return 0


# ── 样例（n 为 oracle 不动点结果，这里只描述意图供人工核对）──
CASES = [
    # (文件名, 意图说明)
    ("s1_noarith", "无 int 算术：识别为 0 tag，帧与旧布局逐字节一致"),
    ("s2_intadd", "add dest（临时行）+ 定值拷贝（c ← add 临时行）"),
    ("s3_sub", "sub dest（临时行）+ 定值拷贝 → 与 s2 同形态"),
    ("s4_addcopy", "add/sub dest + IR_STORE 定值拷贝链（d:=c / f:=e 为 STORE 拷贝）"),
    ("s5_loop", "while 累加：add 临时行 + 变量行（sum/i）经 STORE 定值拷贝入集"),
    ("s6_loopcopy", "评审红用例：循环体内 snap = x as int（IR_LOAD 拷贝链）线性"
                    "先于 x = x + k（tag 源定值）——迭代 ≥2 拷贝 2-limb 值；"
                    "单遍前向漏标 snap 链，不动点收敛后入集"),
    ("s7_framediff", "帧可观测区分用例：8 个 add 定值点 + 1 个拷贝变量行——"
                     "旧规则（A+B）tag 数与小计帧落点不同 → 帧字节在 O1/O2 "
                     "有 16B 差（评审前实现 vs 不动点+B' 的二进制级可观测差）"),
]

SRCS = {
    "s1_noarith": "fn main() -> int {\n    return 7;\n}\n",
    "s2_intadd": "fn main() -> int {\n    a := 2000000000;\n    b := 2000000000;\n    c := a + b;\n    return c;\n}\n",
    "s3_sub": "fn main() -> int {\n    a := 10;\n    b := 3;\n    c := a - b;\n    return c;\n}\n",
    "s4_addcopy": "fn main() -> int {\n    a := 1;\n    b := 2;\n    c := a + b;\n    d := c;\n    e := d + c;\n    f := e;\n    return f;\n}\n",
    "s5_loop": "fn main() -> int {\n    sum := 0;\n    i := 0;\n    while i < 10 {\n        sum = sum + i;\n        i = i + 1;\n    }\n    return sum;\n}\n",
    # 评审场景：snap 的拷贝点线性先于 tag 源（x = x + k）的定值——运行时
    # x 的 tag 态沿回边携带，迭代 ≥2 的 snap = x as int 拷贝的是 2-limb x。
    "s6_loopcopy": "fn main() -> int {\n    x : ., mut = 0;\n    i : ., mut = 0;\n    snap := 0;\n    while i < 3 {\n        snap = x as int;\n        x = x + 1;\n        i = i + 1;\n    }\n    return snap;\n}\n",
    # 8 个 add 定值点（旧规则 tag 数 = 8）后跟一个拷贝变量行 s（新规则 +2）：
    # vc*8 = 160 时 O1/O2 帧 168（旧）vs 184（新）——二进制级可观测差。
    "s7_framediff": "fn main() -> int {\n    r : ., mut = 0;\n    r = r + 1;\n    r = r + 1;\n    r = r + 1;\n    r = r + 1;\n    r = r + 1;\n    r = r + 1;\n    r = r + 1;\n    r = r + 1;\n    s := r;\n    return s;\n}\n",
}

EXPECTED_EXIT = {"s1_noarith": 7, "s2_intadd": 0, "s3_sub": 7,
                 "s4_addcopy": 6, "s5_loop": 45, "s6_loopcopy": 2,
                 "s7_framediff": 8}


def run_checked(args, label):
    cmd = ["nice", "-n", "19", *map(str, args)]
    r = subprocess.run(cmd, cwd=BASE, capture_output=True, text=True, timeout=300)
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
    for name, desc in CASES:
        src = SCRATCH / f"{name}.cr"
        src.write_text(SRCS[name], encoding="utf-8")
        for opt in (0, 1, 2):
            out = SCRATCH / f"{name}_o{opt}"
            ccr = Path(str(out) + ".ccr")
            if not run_checked([COREC, "build", src, "-o", out, "--static", "-O", str(opt)],
                               f"{name} @O{opt} build"):
                ok = False
                continue
            if not ccr.exists():
                print(f"[FAIL] {name} @O{opt}: no .ccr at {ccr}")
                ok = False
                continue
            funcs, var_types = load_ir(ccr)
            mains = [f for f in funcs if f["name"] == "main"]
            if len(mains) != 1:
                print(f"[FAIL] {name} @O{opt}: expected 1 main, got {[f['name'] for f in funcs]}")
                ok = False
                continue
            mainf = mains[0]
            tags = detect_tags(mainf, var_types)
            n = len(tags)
            expect_f = frame_total(mainf["var_count"], n, opt)
            try:
                got_f = find_main_frame(out, opt)
            except AssertionError as e:
                print(f"[FAIL] {name} @O{opt}: prologue parse: {e}")
                ok = False
                continue
            if got_f != expect_f:
                print(f"[FAIL] {name} @O{opt}: frame {got_f} != expected {expect_f} "
                      f"(vc={mainf['var_count']}, tags={n}, desc={desc})")
                ok = False
            else:
                print(f"[PASS] {name} @O{opt}: frame {got_f} == vc*8({mainf['var_count'] * 8}) "
                      f"+ {n} tags aligned (desc: {desc})")
            # 行为
            os.chmod(out, 0o755)
            r = subprocess.run([str(out)], cwd=BASE, timeout=30)
            want = EXPECTED_EXIT[name]
            if r.returncode != want:
                print(f"[FAIL] {name} @O{opt}: run exit {r.returncode}, want {want}")
                ok = False
            else:
                print(f"[PASS] {name} @O{opt}: run exit {r.returncode}")
            # 区分性断言（oracle 级，防实现/测试共同退化掩盖评审缺陷）
            if name == "s6_loopcopy" and opt == 0:
                # 不动点必须 ⊋ 单遍前向——s6 的拷贝链只经回边跨遍收敛
                sp = detect_tags(mainf, var_types, max_passes=1)
                if not sp < tags:
                    print(f"[FAIL] {name} @O{opt}: fixpoint {sorted(tags)} "
                          f"not a strict superset of single-pass {sorted(sp)} — "
                          f"case no longer discriminates the review defect")
                    ok = False
                else:
                    print(f"[PASS] {name} @O{opt}: fixpoint({len(tags)}) > "
                          f"single-pass({len(sp)}) — 循环携带拷贝链被收敛捕获")
        # s7：帧级可观测性——至少一个 opt 下旧规则（A+B 单遍，评审前实现）
        # 的帧与新规则帧不同（否则帧断言无法区分新旧实现）
        if name == "s7_framediff":
            old_tags = detect_tags(mainf, var_types, max_passes=1, store_edges=False)
            obs = [o for o in (0, 1, 2)
                   if frame_total(mainf["var_count"], len(old_tags), o)
                   != frame_total(mainf["var_count"], len(tags), o)]
            if not obs:
                print(f"[FAIL] {name}: 旧规则帧 == 新规则帧 at all opt "
                      f"(old={len(old_tags)}, new={len(tags)}) — 样例失去帧级区分力")
                ok = False
            else:
                print(f"[PASS] {name}: old-rules({len(old_tags)} tags) vs "
                      f"fixpoint({len(tags)} tags) frame differs at O{obs}")
        print()
    print("=== mw task1: " + ("ALL PASS" if ok else "FAILURES") + " ===")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
