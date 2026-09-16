#!/usr/bin/env python3
"""int 多字 M1 Task 2/3：快路径溢出检测发射（tagged int add/sub + jo → 慢路径块）。

验证对象（架构轴 src/arch/x86_64/ + 格式轴 src/format/elf/）：
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
产物存 build/mw_task2_zdiff/（build 目录不入库）。**缺基线时默认 FAIL**（A5 修复，
判据载体化批 2026-09-16）——原实现「不在就 [SKIP]」使整套零 diff 断言可**静默消失**
（新克隆/CI 恒 SKIP 而 rc=0 = 假绿）；现仅显式 `--allow-skip` / `--skip-zdiff` 才降级。
CI/新克隆需在改动前编译器上自产基线（`--snapshot`）才能跑零 diff 腿。

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

# IR opcodes / ops（ast.cr，oracle 用——与 tag2l.cr mw_setup_tags 同源常量）
IR_BINARY = 2
OP_ADD = 1
OP_SUB = 2

# jo near rel32 = 0F 80 cd（6B）；慢路径块确定性前缀 = sbb r11, r11
# （4D 19——高 limb 修正首操作，add/sub 共用；sub 后随 48 F7 not）
JO_PAT = b"\x0f\x80"
BLK_PREFIX = b"\x4d\x19"


# ══════════════════════════════════════════════════════════════════════
# 判据侧 x86-64 指令长度解码（B1/#90 + B6/#85 修复，2026-09-16 判据网加固批）
#
# 缘起（判据强度审计 §0/表 B，TODO #2026-09-16-28/#85）：
#   - 零 diff 腿原实现「遇 0xE8 字节即跳 5 字节」——0xE8 出现在 disp8/imm32
#     等**非指令首**位置（值 −24 = 0xE8 极常见）时，其后 4 字节**永不比较**
#     = 盲窗（改帧常数低 4B 即可骗过，见 #90）。
#   - 慢路径块原判据只有 2B 前缀锚（4D 19）+ 目标序（#85）。
# 两处都需要「字节流的指令边界」这一事实 ⇒ 本组函数（判据侧独立实现，
# **不复用发射器代码**——发射器改了才可能发现）。
# 口径：**fail-closed**——未登记 opcode/形态 ⇒ InsnDecodeError（判据转红），
# 绝不静默放宽（判据不得悄悄变弱）。解码正确性以 objdump 对拍验证（本批报告：
# 17 个真实 main 区/慢路径块逐指令边界 == objdump --insn-width=16，含 t3 的
# 3272 条指令、含 call/jcc/movabs/SIB 形态）。
# ══════════════════════════════════════════════════════════════════════


class InsnDecodeError(Exception):
    """未登记的指令形态（fail-closed：判据红，不静默跳过）。"""


_LEGACY_PREFIX = {0x66, 0x67, 0xF0, 0xF2, 0xF3, 0x2E, 0x36, 0x3E, 0x26, 0x64, 0x65}
# 无 modrm、无立即数
_OP_NONE = set(range(0x50, 0x60)) | {0x90, 0x98, 0x99, 0xC3, 0xC9, 0xCC, 0xCE, 0xF4}
# 有 modrm、无立即数（ALU 双操作数族 0x01/03/09/0B/11/13/19/1B/21/23/29/2B/31/33/
# 39/3B——**0x19 = sbb r/m64, r64 是慢路径块首指令 4D 19 DB 的 opcode**，未登记
# 时解码器 fail-closed 报错：本批首跑即被它拦下，正证明 fail-closed 有效）
_OP_MODRM = {0x01, 0x03, 0x09, 0x0B, 0x11, 0x13, 0x19, 0x1B, 0x21, 0x23, 0x29, 0x2B,
             0x31, 0x33, 0x39, 0x3B, 0x63, 0x84, 0x85, 0x87, 0x88, 0x89, 0x8A, 0x8B,
             0x8D, 0x8F, 0xD0, 0xD1, 0xD2, 0xD3, 0xFE, 0xFF}
# 0F 双字节：无操作数 / 有 modrm、无立即数
_OP0F_NONE = {0x05, 0x0B, 0x0E, 0x31, 0x34, 0x35, 0x77}
_OP0F_MODRM = (set(range(0x40, 0x50)) | set(range(0x90, 0xA0)) |
               {0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x1F, 0x28, 0x29, 0x2A, 0x2B,
                0x2C, 0x2D, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x5B, 0x5C,
                0x5D, 0x5E, 0x5F, 0x6E, 0x7E, 0xA3, 0xAB, 0xAF, 0xB1, 0xB3, 0xB6,
                0xB7, 0xBE, 0xBF, 0xC0, 0xC1, 0xD6, 0xEF})


def _modrm_end(buf, i):
    """buf[i] = ModRM → (ModRM 含 SIB/disp 之后的下标, reg 字段)。"""
    m = buf[i]
    i += 1
    reg, mod, rm = (m >> 3) & 7, m >> 6, m & 7
    if rm == 4 and mod != 3:               # SIB
        sib = buf[i]
        i += 1
        if mod == 0 and (sib & 7) == 5:
            i += 4
        elif mod == 1:
            i += 1
        elif mod == 2:
            i += 4
    elif mod == 0 and rm == 5:             # RIP-relative
        i += 4
    elif mod == 1:
        i += 1
    elif mod == 2:
        i += 4
    return i, reg


def x86_insn_len(buf, i):
    """解码 buf[i] 起一条指令 → (长度, 是否 call rel32)。未登记形态抛 InsnDecodeError。"""
    n = len(buf)
    start = i
    while i < n and buf[i] in _LEGACY_PREFIX:
        i += 1
    if i >= n:
        raise InsnDecodeError(f"@{start}: 前缀后越界")
    rex = 0
    if 0x40 <= buf[i] <= 0x4F:
        rex = buf[i]
        i += 1
    if i >= n:
        raise InsnDecodeError(f"@{start}: REX 后越界")
    op = buf[i]
    i += 1

    def need(k, what):
        if i + k > n:
            raise InsnDecodeError(f"@{start}: {what} 越界（opcode {op:#04x}）")

    if op == 0x0F:
        need(1, "第二字节")
        op2 = buf[i]
        i += 1
        if op2 in _OP0F_NONE:
            pass
        elif 0x80 <= op2 <= 0x8F:
            need(4, "jcc rel32")
            i += 4
        elif op2 in _OP0F_MODRM:
            need(1, "modrm")
            i, _ = _modrm_end(buf, i)
        else:
            raise InsnDecodeError(f"@{start}: 未登记的 0F {op2:02x}")
        return i - start, False
    if op == 0xE8:
        need(4, "call rel32")
        return i - start + 4, True
    if op == 0xE9:
        need(4, "jmp rel32")
        return i - start + 4, False
    if op == 0xEB or 0x70 <= op <= 0x7F or 0xE0 <= op <= 0xE3:
        need(1, "rel8")
        return i - start + 1, False
    if op in _OP_NONE:
        return i - start, False
    if 0xB8 <= op <= 0xBF:                 # mov r32/r64, imm
        k = 8 if (rex & 8) else 4
        need(k, "mov imm")
        return i - start + k, False
    if op == 0x68:
        need(4, "push imm32")
        return i - start + 4, False
    if op == 0x6A:
        need(1, "push imm8")
        return i - start + 1, False
    if op in (0x05, 0x69, 0x81):
        need(1, "modrm")
        i, _ = _modrm_end(buf, i)
        need(4, "imm32")
        return i - start + 4, False
    if op in (0x6B, 0x80, 0x82, 0x83, 0xC0, 0xC1, 0xC6):
        need(1, "modrm")
        i, _ = _modrm_end(buf, i)
        need(1, "imm8")
        return i - start + 1, False
    if op in (0x04, 0x0C, 0x14, 0x1C, 0x24, 0x2C, 0x34, 0x3C, 0xA8):
        need(1, "imm8")
        return i - start + 1, False
    if op == 0xA9:
        need(4, "imm32")
        return i - start + 4, False
    if op == 0xC7:                         # mov r/m64, imm32
        need(1, "modrm")
        i, _ = _modrm_end(buf, i)
        need(4, "imm32")
        return i - start + 4, False
    if op in (0xF6, 0xF7):                 # group3：/0 /1 带立即数
        need(1, "modrm")
        i, reg = _modrm_end(buf, i)
        if reg in (0, 1):
            k = 1 if op == 0xF6 else 4
            need(k, "group3 imm")
            i += k
        return i - start, False
    if op in _OP_MODRM:
        need(1, "modrm")
        i, _ = _modrm_end(buf, i)
        return i - start, False
    raise InsnDecodeError(f"@{start}: 未登记的 opcode {op:#04x}")


def x86_walk(buf, base=0):
    """线性扫过 buf → [(绝对偏移, 长度, 是否 call)]；未登记形态抛 InsnDecodeError。"""
    out = []
    i = 0
    while i < len(buf):
        ln, is_call = x86_insn_len(buf, i)
        if ln <= 0:
            raise InsnDecodeError(f"@{i}: 长度 {ln}")
        out.append((base + i, ln, is_call))
        i += ln
    return out

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
    # B6/#85 修复附例（判据网加固批 2026-09-16）：**sub 站点**慢路径块 = 块体
    # 模板的 sub 分支（sbb r11,r11 后另 3B `49 F7 D3` not r11）——原三例全为
    # add ⇒ 该分支在块体判据里从未被走到（§0bis 探针触发面缺口），本例补上。
    ("t4_sub_overflow", 16, struct.pack("<QQ", 1 << 63, 0),
     "sub 溢出（2^62 − (−2^62) = 2^63）：慢路径块 sub 版（含 not r11）→ 2-limb "
     "数学 lo=2^63、hi=0"),
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
    "t4_sub_overflow": "fn main() -> int {\n    x : ., mut = 4611686018427387904;\n"
                       "    x = x - -4611686018427387904;\n"   # 2^62 − (−2^62) = 2^63
                       "    r := syscall3(1, 1, x, 16);\n    return r;\n}\n",
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


def mw_site_ops(funcs, var_types):
    """jo 站点顺序的 op 列表（OP_ADD/OP_SUB；与 jo_sites_oracle **同源同序**：
    指令序 = 发射序 ⇒ 第 i 个 jo 站点 ↔ 本列表第 i 项）——慢路径块体判据用
    （op == OP_SUB ⇒ 块内必有 `not r11` 3 字节；add 版必无）。"""
    mains = [f for f in funcs if f["name"] == "main"]
    if len(mains) != 1:
        raise AssertionError(f"expected 1 main, got {[f['name'] for f in funcs]}")
    tags = detect_tags(mains[0], var_types)
    ops = []
    for (op, d, s1, s2, s3, tk, fe, ec) in mains[0]["nodes"]:
        if op == IR_BINARY and s3 in (OP_ADD, OP_SUB) and d in tags:
            ops.append(s3)
    return ops


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


def parse_slow_block(text, t, is_sub):
    """慢路径块体逐指令模板断言（**B6/#85 修复**，2026-09-16 判据网加固批）。

    块 = 2-limb 修正代码（发射器 tag2l.cr `e2_mw_slow_block`；写序 = 模板序）。
    模板（`..` = 站点相关字段：调用位移/槽偏移/回跳位移——**其余字节全钉**）：
      4D 19 DB                      sbb r11, r11        （高 limb = −CF）
      [49 F7 D3]                    not r11             （**仅 sub 站点**）
      41 52 / 41 53                 push r10 / push r11 （call 前保存 lo/hi）
      BF 10 00 00 00                mov edi, 16
      E8 ..×4                       call alloc(16)
      41 5B / 41 5A                 pop r11 / pop r10
      4C 89 10                      mov [rax], r10      （lo）
      4C 89 58 08                   mov [rax+8], r11    （hi）
      48 89 45 .. | 48 89 85 ..×4 | 48/49 89 C0|..  ← mov <dest 槽>, rax
      C6 45 .. 01 | C6 85 ..×4 01   mov byte <tag 字节>, 1  （tag 置位 = 1，硬判）
      E9 ..×4                       jmp resume          （回快路径 store 之后）
    返回 (blk_end, alloc_target, resume_target)。形态不符 ⇒ AssertionError。

    **反例自检（audit §0）：什么坏实现能骗过本断言？**——旧判据（2B 前缀
    `4D 19` + 目标序）能被骗过：把块体余下字节任意改写（`4C 89 10` 换寄存器、
    tag 立即数 1→0、`E9` 回跳目标改到别处、甚至整块截短）都仍绿——它只证明
    「块首两字节在」，不证明块体是那段修正代码。本模板逐指令比字节 + 独立
    断言「tag 立即数 == 1」（慢路径侧 tag 不变量）与「回跳目标 = 区内指令
    边界」（由调用方以 region_offs 判）⇒ 上述任一改写必红。

    **探针触发自检（audit §0bis）**：本函数只在 `len(jos) > 0`（oracle 判定的
    真 jo 站点）时被调用；t1/t2/t3 均 ≥1 站点 ⇒ 模板断言真被走到（t 用例
    在 z 用例之外保证非空转；调用方另断言块间连续 = 长度公式成立）。
    """
    cursor = t

    def insn(what, want=None):
        nonlocal cursor
        try:
            ln, _is_call = x86_insn_len(text, cursor)
        except InsnDecodeError as e:
            raise AssertionError(f"{what}@+{cursor - t}: 解码失败（fail-closed）{e}")
        b = text[cursor:cursor + ln]
        cursor += ln
        if want is not None and b != want:
            raise AssertionError(f"{what}@+{cursor - t - ln}: 字节 {b.hex()} "
                                 f"!= 期望 {want.hex()}")
        return b, cursor - ln

    insn("sbb r11,r11", b"\x4d\x19\xdb")
    if is_sub:
        insn("not r11", b"\x49\xf7\xd3")
    insn("push r10", b"\x41\x52")
    insn("push r11", b"\x41\x53")
    insn("mov edi,16", b"\xbf\x10\x00\x00\x00")
    cb, cp0 = insn("call alloc")
    if cb[0] != 0xE8 or len(cb) != 5:
        raise AssertionError(f"call alloc@+{cp0 - t}: 非 E8 rel32（{cb.hex()}）")
    alloc_t = cp0 + 5 + struct.unpack_from("<i", text, cp0 + 1)[0]
    insn("pop r11", b"\x41\x5b")
    insn("pop r10", b"\x41\x5a")
    insn("mov [rax],r10", b"\x4c\x89\x10")
    insn("mov [rax+8],r11", b"\x4c\x89\x58\x08")
    # 值槽存指针：e2_st(dest) 三形态（reg / [rbp+disp8] / [rbp+disp32]）；源恒 rax
    sb, sp0 = insn("mov <dest>, rax")
    ok_st = ((len(sb) == 3 and sb[0] in (0x48, 0x49) and sb[1] == 0x89
              and (sb[2] >> 6) == 3 and ((sb[2] >> 3) & 7) == 0)
             or (len(sb) == 4 and sb[:3] == b"\x48\x89\x45")
             or (len(sb) == 7 and sb[:3] == b"\x48\x89\x85"))
    if not ok_st:
        raise AssertionError(f"dest 槽存指针@+{sp0 - t}: 形态不符（{sb.hex()}）")
    # tag 字节置位：C6 /0，立即数**必须 == 1**（慢路径侧 tag 不变量）
    tb, tp0 = insn("mov byte <tag>, 1")
    if len(tb) == 4:
        ok_tag = tb[:2] == b"\xc6\x45" and tb[3] == 0x01
    elif len(tb) == 7:
        ok_tag = tb[:2] == b"\xc6\x85" and tb[6] == 0x01
    else:
        ok_tag = False
    if not ok_tag:
        raise AssertionError(f"tag 置位@+{tp0 - t}: 形态/立即数不符（{tb.hex()}）"
                             f"——tag 不变量要求立即数 == 01")
    jb, jp0 = insn("jmp resume")
    if jb[0] != 0xE9 or len(jb) != 5:
        raise AssertionError(f"回跳@+{jp0 - t}: 非 E9 rel32（{jb.hex()}）")
    resume_t = jp0 + 5 + struct.unpack_from("<i", text, jp0 + 1)[0]
    return cursor, alloc_t, resume_t


def region_equal_mask_calls(text_a, span_a, text_b, span_b):
    """untagged main 区域指令流逐字节相等（快路径零变化断言）。

    唯一豁免 = 真 `E8 rel32`（call）的 4 字节位移字段——被调函数地址随 tagged
    函数布局合法移动（E9 jmp rel32 目标在主内，不移动 ⇒ 照常比较）。

    **B1/#90 修复（2026-09-16 判据网加固批）**：旧实现「遇 0xE8 字节即跳 5」
    有盲窗——0xE8 出现在 disp8/imm32 等非指令首位置（值 −24 = 0xE8 常见）时,
    其后 4 字节永不比较。现按**指令边界锁步**（x86_insn_len 解码，两侧边界
    序列必须逐条一致）：非 call 指令全字节比较，call 仅放行 rel32。

    **反例自检（audit §0）：什么坏实现能骗过本断言？**——旧实现能骗过：把帧
    常数/立即数低 4B 改成任意值，只要其前 1..4 字节内有个 0xE8 ⇒ 盲窗吞掉
    ⇒ 绿（退出码可不变）。本实现下该常数位于 `C7 /0 imm32`（或 `48 81 /5`）
    指令体内 ⇒ 整段参与比较 ⇒ 必红。剩余豁免面 = 真 call 的 rel32，其
    **站点位置**由边界序列一致约束、**取值**另有落在各自 text 内的独立断言。
    未登记指令形态 ⇒ InsnDecodeError ⇒ 红（fail-closed，见 x86_insn_len）。

    **探针触发自检（audit §0bis）**：返回的 calls = 实际走到的豁免数；调用方
    对 z 用例断言 calls ≥ 1（=0 ⇒ 豁免面未被走到，判据在空转，判红）。
    本批实测：z1/z2 = 1 处、z3 = 2 处（@O0/O1/O2 同）。

    返回 (ok, detail, calls)。
    """
    a, b = text_a[span_a[0]:span_a[1]], text_b[span_b[0]:span_b[1]]
    if len(a) != len(b):
        return False, f"region len {len(a)} != {len(b)}", 0
    if not a:
        return False, "region 为空（判据空转）", 0
    try:
        ia, ib = x86_walk(a), x86_walk(b)
    except InsnDecodeError as e:
        return False, f"指令解码失败（fail-closed：未登记形态）: {e}", 0
    if ia != ib:
        for x, y in zip(ia, ib):
            if x != y:
                return False, (f"指令边界序列不一致（布局变了，不只是 call "
                               f"位移）: a={x} b={y}"), 0
        return False, f"指令条数不一致: a={len(ia)} b={len(ib)}", 0
    calls = 0
    for off, ln, is_call in ia:
        if not is_call:
            if a[off:off + ln] != b[off:off + ln]:
                k = next(k for k in range(ln) if a[off + k] != b[off + k])
                return False, (
                    f"非 call 指令字节@{off}+{k}（{ln}B 指令内，非豁免面）: "
                    f"a={a[max(0, off - 4):off + ln + 4].hex()} "
                    f"b={b[max(0, off - 4):off + ln + 4].hex()}"), 0
            continue
        if a[off] != 0xE8 or b[off] != 0xE8:
            return False, f"call 站点 @{off} opcode 非 E8", 0
        calls += 1
        ta = span_a[0] + off + 5 + struct.unpack_from("<i", a, off + 1)[0]
        tb = span_b[0] + off + 5 + struct.unpack_from("<i", b, off + 1)[0]
        # 独立断言（不依赖另一侧）：位移必须指向各自 text 内（链接期回填失手 ⇒ 红）
        if not (0 <= ta < len(text_a)):
            return False, f"call@{off} 目标 {ta} 越出当前 text（0..{len(text_a)}）", 0
        if not (0 <= tb < len(text_b)):
            return False, f"call@{off} 目标 {tb} 越出基线 text（0..{len(text_b)}）", 0
    return True, f"指令流逐字节同（{len(ia)} 条指令；call rel32 豁免 {calls} 处）", calls


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
    ap.add_argument("--allow-skip", action="store_true",
                    help="基线缺失时降级为 [SKIP]（默认 **FAIL**——见文件头 A5 修复注）")
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
                # （发射序 = 指令序 → 扫描序；首站点块 = 尾声 ret 后首字节 m1）。
                # B6/#85 修复：块体判据从「2B 前缀锚 + 目标序」升级为**逐指令
                # 模板断言**（parse_slow_block：除调用位移/槽偏移/回跳位移三处
                # 站点相关字段外全字节钉死 + tag 立即数 == 1 硬判），且块间
                # **连续**（块长公式成立）、`not r11` 与站点 op 一致。
                targets = [t for (_, t) in jos]
                if jos[0][1] != m1:
                    print(f"[FAIL] {name} @O{opt}: first jo target {jos[0][1]} "
                          f"!= block region start {m1}")
                    ok = False
                    continue
                bad_ord = [t for t in targets if t < m1]
                if bad_ord:
                    print(f"[FAIL] {name} @O{opt}: block targets pre-epilogue "
                          f"{bad_ord}")
                    ok = False
                    continue
                if any(targets[i] >= targets[i + 1] for i in range(len(targets) - 1)):
                    print(f"[FAIL] {name} @O{opt}: block targets not strictly "
                          f"increasing: {targets}")
                    ok = False
                    continue
                site_ops = mw_site_ops(funcs, var_types)
                if len(site_ops) != len(jos):
                    print(f"[FAIL] {name} @O{opt}: oracle ops {len(site_ops)} != "
                          f"jo sites {len(jos)}（站点 ↔ op 对齐失败）")
                    ok = False
                    continue
                region_offs = {off for off, _, _ in x86_walk(text[m0:m1])}
                blk_err = None
                alloc_targets = set()
                for si, (jo, tgt) in enumerate(jos):
                    try:
                        end, alloc_t, resume_t = parse_slow_block(
                            text, tgt, is_sub=(site_ops[si] == OP_SUB))
                    except AssertionError as e:
                        blk_err = (f"site {si}（jo@{jo}，op={'sub' if site_ops[si] == OP_SUB else 'add'}）"
                                   f" 块体模板不符: {e}")
                        break
                    if si + 1 < len(jos) and end != targets[si + 1]:
                        blk_err = (f"site {si} 块尾 {end} != 下一站点块首 "
                                   f"{targets[si + 1]}（块长公式/块间连续失败）")
                        break
                    # 回跳目标 = 快路径 store 之后：必须在主区内、且是**真指令边界**
                    if not (m0 < resume_t < m1) or (resume_t - m0) not in region_offs:
                        blk_err = (f"site {si} 回跳目标 {resume_t} 不在主区指令边界内 "
                                   f"（[{m0},{m1})，边界集 {len(region_offs)} 项）")
                        break
                    if not (0 <= alloc_t < len(text)):
                        blk_err = f"site {si} alloc 调用目标 {alloc_t} 越出 text"
                        break
                    alloc_targets.add(alloc_t)
                if blk_err:
                    print(f"[FAIL] {name} @O{opt}: {blk_err}")
                    ok = False
                    continue
                if len(alloc_targets) != 1:
                    print(f"[FAIL] {name} @O{opt}: 各站点 alloc 目标不一致 "
                          f"{sorted(alloc_targets)}（应全为同一 alloc 助手）")
                    ok = False
                    continue
                dmax = targets[0] - jos[0][0]  # 首 jo 距其块（= m1 − jo0）
                print(f"[PASS] {name} @O{opt}: {len(jos)} jo -> per-site blocks "
                      f"@{targets[0]}..+{targets[-1] - targets[0]} "
                      f"(first-jo dist {dmax}B; 块体模板逐指令 + 块间连续 + "
                      f"tag=1 + 回跳落指令边界 + alloc 目标唯一 "
                      f"{alloc_targets.pop()}; desc: {desc})")
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
                    same, why, ncalls = region_equal_mask_calls(
                        text, (m0, m1), bt, (b0, b1))
                    if not same:
                        print(f"[FAIL] {name} @O{opt}: main stream differs vs "
                              f"pre-change baseline: {why}")
                        ok = False
                    elif ncalls == 0:
                        # §0bis 探针触发自检：call 豁免面未被走到 ⇒ 断言空转
                        print(f"[FAIL] {name} @O{opt}: zero-diff 腿未走到 call "
                              f"豁免面（{why}）——判据在空转，判红")
                        ok = False
                    else:
                        print(f"[PASS] {name} @O{opt}: main {why} vs "
                              f"pre-change baseline")
                elif args.snapshot:
                    import shutil
                    shutil.copyfile(out, bl)
                    print(f"[SNAP] {name} @O{opt}: baseline saved {bl.name}")
                elif args.allow_skip:
                    # 显式豁免（**唯一**保留 SKIP 的口径）：调用者已知基线不可得并承担缺口。
                    print(f"[SKIP] {name} @O{opt}: no zero-diff baseline "
                          f"({bl}) — **显式 --allow-skip**：判据缺口由调用者承担"
                          f"（run --snapshot on pre-change compiler 产基线）")
                else:
                    # A5 修复（判据载体化批 2026-09-16）：基线在 build/（不入库）而 run.sh
                    # 从不传 --snapshot ⇒ 原实现「不在就 [SKIP]」使**整套零 diff 断言可静默
                    # 消失**（新克隆/CI 恒 SKIP 而 rc=0 = 假绿）。现默认 fail-closed：
                    # 基线缺失 ⇒ FAIL；仅显式 --allow-skip / --skip-zdiff 才降级。
                    print(f"[FAIL] {name} @O{opt}: zero-diff baseline missing "
                          f"({bl}) — 默认 fail-closed（判据不得静默消失）。"
                          f"补救：在**改动前**编译器上跑 --snapshot 产基线；"
                          f"确需跳过请显式 --allow-skip（或 --skip-zdiff）")
                    ok = False
            print()
    print("=== mw task2: " + ("ALL PASS" if ok else "FAILURES") + " ===")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
