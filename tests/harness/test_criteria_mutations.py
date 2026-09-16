#!/usr/bin/env python3
"""判据强度**突变自证**（判据网加固批，2026-09-16；纯 python、无需编译器）。

目的（判据强度审计 §0 的机械承接面）：把「**什么坏实现能骗过这条断言？**」
从写注释时的自问，变成**可复跑的证据**——每个被判据网加固批改强的判据，此处
构造一个**能骗过旧（弱）形态、且真的坏**的输入，断言：

  ① **旧形态**对该输入**绿**（= 旧判据确实弱，如实记录弱点而非猜测）；
  ② **新形态**对该输入**红**（= 加固真的咬得住）。

被测判据（→ TODO 条目 → 审计表 B 编号）：
  M1 事件 1-4 step 模板        → #2026-09-16-22 / B2（test_hit_table.ev14_template_problems）
  M2 dump 未用字段值域白名单    → #2026-09-16-24 / B3（test_hit_table.dump_sentinel_problems）
  M3 STR 段冷/暖前缀契约        → #2026-09-16-25 / B4（test_cir_warm_path.str_contract_equal）
  M4 `--dump-tk-terms` 剔除面白名单 → #2026-09-16-26 / B5（test_ccr_types.dump_strip_face_problems）
  M5 零 diff 腿指令边界锁步     → #2026-09-16-28 / B1（test_mw_task2.region_equal_mask_calls）
  M6 慢路径块体逐指令模板       → #2026-09-16-23 / B6（test_mw_task2.parse_slow_block）

口径：全部为**内存内**突变（不改仓库任何文件、不写盘、零副作用）——突变体 =
真实载体（真实 TOML 表文本 / 真实 ELF 区字节 / 真实 dump 文本 / 真实块字节）
的**最小坏实现**式改写；M5/M6 的字节取自本仓真实产物（来源逐条注明）。

判据自身失败即 rc=1（CI 挂 bootstrap-tests；见 src/ci/run.sh）。
"""

import sys
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(BASE / "tests" / "selfhost"))

import test_hit_table as HT          # noqa: E402
import test_ccr_types as CT          # noqa: E402
import test_cir_warm_path as CW      # noqa: E402
import test_mw_task2 as MW           # noqa: E402


# ══════════════════════════════════════════════════════════════════════
# 旧（弱）形态的忠实复刻——**只用作「骗得过」的反证基线**，不参与任何判据
# ══════════════════════════════════════════════════════════════════════

def old_ev14_prefix_ok(events) -> bool:
    """#2026-09-16-22 旧形态：`stream[:2] == want`（只比 REX+opcode 前 2B）。"""
    for eid, want in ((1, [0x4D, 0x29]), (2, [0x4D, 0x21]),
                      (3, [0x4C, 0x8B]), (4, [0x4C, 0x89])):
        ev = HT._ev(events, eid)
        sf = ev["projs"][0]["steps"][0]
        rb = 0x40
        for bit, k in ((8, "rex_w"), (4, "rex_r"), (2, "rex_x"), (1, "rex_b")):
            if k in sf:
                rb |= bit * HT._tbl_int(sf[k])
        stream = ([HT._tbl_int(b) for b in HT._tbl_int_list(sf.get("prefix", "[]"))]
                  if "prefix" in sf else [])
        if rb != 0x40:
            stream.append(rb)
        stream += HT._tbl_int_list(sf["opcode"])
        if stream[:2] != want:
            return False
    return True


def old_dump_blacklist_ok(out: str) -> bool:
    """#2026-09-16-24 旧形态：4 字面量黑名单。"""
    bad = [s for s in ("dst=255", "s2=255", "dst=-1", "s2=-1") if s in out]
    return not bad


def old_str_size_only_ok(cold_seg: bytes, warm_seg: bytes) -> bool:
    """#2026-09-16-25 旧形态：STR 段只登记尺寸、**不入判据**（恒绿——差异被显式豁免）。"""
    return True


def old_strip_compare_ok(out_flag: str, out_plain: str) -> bool:
    """#2026-09-16-26 旧形态：黑盒逐行过滤（`[df-tk-terms]` 头 + `^-?\\d+\\t` 数据行）后比对。"""
    import re
    stripped = "\n".join(l for l in out_flag.splitlines()
                         if not l.startswith('[df-tk-terms]')
                         and not re.match(r'^-?\d+\t', l))
    return stripped == "\n".join(out_plain.splitlines())


def old_region_equal_mask_calls(a: bytes, b: bytes):
    """#2026-09-16-28 旧形态：遇 0xE8 字节即跳 5B（含**非指令首**的 0xE8 ⇒ 其后 4B 盲窗）。"""
    if len(a) != len(b):
        return False
    i = 0
    while i < len(a):
        if a[i] != b[i]:
            return False
        if a[i] == 0xE8:
            i = i + 5
            continue
        i = i + 1
    return True


def old_block_prefix_ok(text: bytes, targets) -> bool:
    """#2026-09-16-23 旧形态：只校验 2B 前缀 `4D 19` + 目标序。"""
    return all(text[t:t + 2] == MW.BLK_PREFIX for t in targets)


# ══════════════════════════════════════════════════════════════════════
# 突变体（内存内）
# ══════════════════════════════════════════════════════════════════════

# z2_copy @O0 的 main 区真实字节（本批自 build/mw_task2_scratch/z2_copy_o0 实读；
# 与 tests/selfhost/test_mw_task2.py 的 find_main_region 同源）。其中
# `48 C7 45 E8 40 E2 01 00` = `mov qword [rbp-0x18], 123456`——**disp8 = 0xE8 是
# 数据字节、不是指令首**，其后 4B（imm32 `40 E2 01 00`）正是旧判据的盲窗。
Z2_REGION_HEX = (
    "554889e54883ec3048c7c0ffffffff488945f848c745e840e20100"
    "4c8b55e84c8955f04c8b55f04c8955e04c8b55e04c8955d848c745d064000000"
    "488b45d0e913000000488b7df84885ff7c05e816640000e9000000004883c4305dc3")

# t1_add @O0 慢路径块真实字节（build/mw_task2_scratch/t1_add_o0，块首 = jo 目标）：
# `4D 19 DB | 41 52 41 53 | BF 10 00 00 00 | E8 .. | 41 5B 41 5A | 4C 89 10 |
#  4C 89 58 08 | 48 89 45 C8 | C6 45 C6 01 | E9 ..`
T1_BLOCK_HEX = ("4d19db41524153bf10000000e8a1620000415b415a4c89104c895808"
                "488945c8c645c601e99effffff")


def mut_flip_z2_frame_imm(region: bytes) -> bytes:
    """坏实现：改 z2_copy 帧常数 imm32 的一个字节（落在 0xE8 数据字节后的盲窗内）。"""
    out = bytearray(region)
    k = region.find(bytes.fromhex("48c745e840e20100"))
    assert k > 0, "突变体定位失败（真实字节模式未命中）"
    out[k + 5] = 0xFF          # imm32 第 2 字节 0xE2 → 0xFF（值 123456 → 巨大值）
    return bytes(out)


def mut_block_tag_imm_zero(block: bytes) -> bytes:
    """坏实现：慢路径块 tag 置位立即数 1 → 0（tag 不变量破坏）。"""
    k = block.find(bytes.fromhex("c645c601"))
    assert k > 0, "突变体定位失败"
    out = bytearray(block)
    out[k + 3] = 0
    return bytes(out)


def mut_block_insert_nop(block: bytes) -> bytes:
    """坏实现：块首 2B 前缀后插一个 0x90（前缀仍在、顺序不变——旧判据绿）。"""
    return block[:2] + b"\x90" + block[2:]


def mut_block_dest_reg_swap(block: bytes) -> bytes:
    """坏实现：`4C 89 10`（mov [rax], r10）→ `4C 89 18`（mov [rax], r11）。"""
    k = block.find(bytes.fromhex("4c8910"))
    assert k > 0, "突变体定位失败"
    out = bytearray(block)
    out[k + 2] = 0x18
    return bytes(out)


def main() -> int:
    cases = []

    # ── M1（#2026-09-16-22/B2）事件 1-4 step 模板：4 个坏实现 ──────────────────────
    tbl = HT.TABLE.read_text()
    _ok0, events0, _rt = HT.load_v2_model(tbl)
    muts = [
        ("modrm_reg_role dst→src1",
         tbl.replace('modrm_reg_role = "src2"\nmodrm_rm_role = "dst"',
                     'modrm_reg_role = "src1"\nmodrm_rm_role = "dst"', 1)),
        ("opcode 尾追加 0x90",
         tbl.replace("opcode = [0x29]", "opcode = [0x29, 0x90]", 1)),
        ("rm_mode 0→1",
         tbl.replace('modrm_rm_role = "dst"\nrm_mode = 0',
                     'modrm_rm_role = "dst"\nrm_mode = 1', 1)),
    ]
    # 注（口径）：`rex_b 1→0` **不列入**——REX 位落在首字节，旧 `[:2]` 也咬得住
    # （它属「旧判据也够」的面，不是弱点样本；弱点是首 2B 之外的部分）。
    for label, mtxt in muts:
        _ok, mev, _r = HT.load_v2_model(mtxt)
        cases.append((f"M1/#2026-09-16-22 事件模板：{label}",
                      old_ev14_prefix_ok(mev), HT.ev14_template_problems(mev)))
    # 正控：真实表必须**零问题**（防「判据恒红」也当咬得住）
    cases.append(("M1/#2026-09-16-22 正控：真实 core-x86.toml",
                  old_ev14_prefix_ok(events0), HT.ev14_template_problems(events0),
                  {"expect_strong_clean": True}))

    # ── M2（#2026-09-16-24/B3）dump 未用字段白名单：5 个坏实现 ─────────────────────
    good_dump = ("hit events lowered: 4\n"
                 "  ev store dst=0 s1=0 s2=0\n"
                 "  ev load dst=1 s1=3 s2=0\n"
                 "  ev sub dst=2 s1=1 s2=3\n"
                 "  ev load dst=3 s1=pool0 s2=0\n"
                 "hit pool entries: 1\nhit pool: 7\n")
    assert not HT.dump_sentinel_problems(good_dump)[0], "M2 正控失败（好 dump 被判红）"
    for label, bad_line in [
            ("store dst=1", "  ev store dst=1 s1=0 s2=0\n"),
            ("store dst=254（0xFE 哨兵）", "  ev store dst=254 s1=0 s2=0\n"),
            ("store dst=4294967295（0xFFFFFFFF 哨兵）", "  ev store dst=4294967295 s1=0 s2=0\n"),
            ("store dst=00（同值异形）", "  ev store dst=00 s1=0 s2=0\n"),
            ("load s2=-2", "  ev load dst=1 s1=3 s2=-2\n")]:
        out = good_dump.replace("  ev store dst=0 s1=0 s2=0\n", bad_line, 1)
        cases.append((f"M2/#2026-09-16-24 dump 值域：{label}",
                      old_dump_blacklist_ok(out),
                      HT.dump_sentinel_problems(out)[0]))
    # 形态白名单（旧黑名单完全看不到的维度）：行内**多出一个字段/尾随垃圾** ⇒
    # 整行不匹配 `ev <n> dst=<v> s1=<v> s2=<v>$` ⇒ 红。
    # 注（口径，勿夸大）：**用于**字段（s1/s2 被该事件消费时）取 255/大值**不是**
    # 哨兵伪影、本判据也不主张覆盖——哨兵契约只针对**未用**字段（store dst /
    # load s2），故「s1=255」不列入突变样本。
    out_junk = good_dump.replace("  ev store dst=0 s1=0 s2=0\n",
                                 "  ev store dst=0 s1=0 s2=0 extra=1\n", 1)
    cases.append(("M2/#2026-09-16-24 ev 行尾随字段（形态白名单维度）",
                  old_dump_blacklist_ok(out_junk), HT.dump_sentinel_problems(out_junk)[0]))

    # ── M3（#2026-09-16-25/B4）STR 冷/暖前缀契约：3 个坏实现 ───────────────────────
    def mk_str(entries):
        import struct as _s
        b = _s.pack("<I", len(entries))
        for e in entries:
            b += _s.pack("<I", len(e)) + e
        return b

    cold = mk_str([b"main", b"a", b"b", b"_eq0"])
    for label, warm in [
            ("同尺寸改内容", mk_str([b"main", b"a", b"XX", b"_eq0"])),
            # 注：**尾部整段截短**（暖 = 冷前缀的更短前缀）正是预存口径允许的差异
            # （暖态不重放 ir_gen 临时名）⇒ 不作突变样本；错位风险在**中间**漏条：
            ("中间漏一条（后续条目错位）", mk_str([b"main", b"b", b"_eq0"])),
            ("暖态多一条", mk_str([b"main", b"a", b"b", b"_eq0", b"bin"]))]:
        ok_s, _det = CW.str_contract_equal(cold, warm)
        cases.append((f"M3/#2026-09-16-25 STR 契约：{label}",
                      old_str_size_only_ok(cold, warm), [] if ok_s else [label]))
    # 正控：合法差异（暖 = 冷前缀）必须**仍绿**
    ok_pfx, det_pfx = CW.str_contract_equal(cold, mk_str([b"main", b"a", b"b"]))
    cases.append(("M3/#2026-09-16-25 正控：暖 = 冷前缀（预存口径允许）仍绿",
                  ok_pfx, [] if ok_pfx else [det_pfx],
                  {"expect_strong_clean": True}))

    # ── M4（#2026-09-16-26/B5）剔除面白名单 + 计数 + 序数：3 个坏实现 ──────────────
    plain = "\n".join(["ccr ok: 12 nodes", "wrote build/x.cir"])
    flag_ok = "\n".join([
        "ccr ok: 12 nodes",
        "[df-tk-terms] nodes=3 with_term=3 bad_term=0 aux_nonzero=0 face_fail=0 "
        "terms=5 rows=12 mint=1,2,4,6,10,49,50",
        "0\t2\t1\t5\t1\t0\t0\t0\t0",
        "1\t2\t1\t5\t1\t0\t0\t0\t0",
        "2\t10\t1\t5\t1\t0\t0\t0\t0",
        "wrote build/x.cir"])
    assert not CT.dump_strip_face_problems(flag_ok, plain)[0], "M4 正控失败"
    extra_row = flag_ok.replace("wrote build/x.cir",
                                "3\t2\t1\t5\t1\t0\t0\t0\t0\nwrote build/x.cir")
    cases.append(("M4/#2026-09-16-26 剔除面：多印一行数据行（未计数）",
                  old_strip_compare_ok(extra_row, plain),
                  CT.dump_strip_face_problems(extra_row, plain)[0]))
    stray = flag_ok.replace("ccr ok: 12 nodes",
                            "ccr ok: 12 nodes\n9\t9\t9\t9\t9\t9\t9\t9\t9")
    cases.append(("M4/#2026-09-16-26 剔除面：非 dump 节处混入数据行",
                  old_strip_compare_ok(stray, plain),
                  CT.dump_strip_face_problems(stray, plain)[0]))
    reorder = flag_ok.replace("1\t2\t1\t5\t1\t0\t0\t0\t0",
                              "7\t2\t1\t5\t1\t0\t0\t0\t0")
    cases.append(("M4/#2026-09-16-26 剔除面：数据行序数错（同数量换行——序数断言维度）",
                  old_strip_compare_ok(reorder, plain),
                  CT.dump_strip_face_problems(reorder, plain)[0]))

    # ── M5（#2026-09-16-28/B1）零 diff 腿指令边界锁步：1 个坏实现 + 1 个合法差异正控 ──
    # 缓冲区 = 真实区字节 + 尾部补零到 40000B：被测函数签名的 `text_*` 是**整个
    # text 段**（call 目标 = 段内绝对偏移，真实调用目标在区内之外）⇒ 合成载体
    # 必须留出目标可达空间，否则命中的是「目标越界」那条独立断言而非本突变面。
    reg = bytes.fromhex(Z2_REGION_HEX)
    span = (0, len(reg))
    t_reg = reg.ljust(40000, b"\x00")
    bad = mut_flip_z2_frame_imm(t_reg)
    ok_bad, why_bad, _n = MW.region_equal_mask_calls(t_reg, span, bad, span)
    cases.append(("M5/#2026-09-16-28 零 diff：改 0xE8 数据字节后的帧常数 imm32（旧盲窗）",
                  old_region_equal_mask_calls(reg, bad[:len(reg)]),
                  [] if ok_bad else [why_bad]))
    # 合法差异正控：真 call rel32 位移不同 ⇒ 必须**仍绿**（不得误伤豁免面）。
    # 真 call 站点 = 解码出的 `is_call` 指令首（**不是** `find(b"\xe8")`——那个
    # 恰好会命中 disp8 数据字节，正是本判据要区分的两件事）。
    call_off = next(off for off, _ln, is_call in MW.x86_walk(reg) if is_call)
    legal = bytearray(t_reg)
    legal[call_off + 1] = (legal[call_off + 1] + 7) % 256   # 只动真 call 的 rel32 首字节
    ok_pos, why_pos, ncalls = MW.region_equal_mask_calls(t_reg, span,
                                                         bytes(legal), span)
    cases.append(("M5/#2026-09-16-28 正控：真 call rel32 位移变化（合法）仍绿",
                  ok_pos, [] if ok_pos else [why_pos],
                  {"expect_strong_clean": True}))
    print(f"       （M5 正控：真 call 站点 @{call_off}，豁免面计数 = {ncalls}"
          f"（>0 = 探针触发非空转））")

    # ── M6（#2026-09-16-23/B6）慢路径块体模板：3 个坏实现 + 1 个正控 ───────────────
    blk = bytes.fromhex(T1_BLOCK_HEX)
    text = b"\x00" * 16 + blk + b"\x00" * 16
    try:
        end, alloc_t, resume_t = MW.parse_slow_block(text, 16, is_sub=False)
        print(f"       （M6 正控：真实块解析 OK end={end} alloc={alloc_t} "
              f"resume={resume_t}）")
    except AssertionError as e:
        cases.append(("M6/#2026-09-16-23 正控：真实块体可解析", True, [f"正控自身失败: {e}"]))
    for label, mut in [
            ("tag 立即数 1→0", mut_block_tag_imm_zero(blk)),
            ("块首插 0x90", mut_block_insert_nop(blk)),
            ("mov [rax],r10 → r11", mut_block_dest_reg_swap(blk))]:
        mtext = b"\x00" * 16 + mut + b"\x00" * 16
        try:
            MW.parse_slow_block(mtext, 16, is_sub=False)
            probs = []
        except AssertionError as e:
            probs = [str(e)]
        cases.append((f"M6/#2026-09-16-23 块体模板：{label}",
                      old_block_prefix_ok(mtext, [16]), probs))

    # ── 汇总 ───────────────────────────────────────────────────────────
    bad_cases = []
    for c in cases:
        name, weak_ok, strong_probs = c[0], c[1], c[2]
        clean = c[3] if len(c) > 3 else {}
        expect_clean = clean.get("expect_strong_clean", False)
        if expect_clean:
            good = weak_ok and not strong_probs
            why = "正控：新判据必须零问题" if good else "正控失败"
        else:
            good = weak_ok and bool(strong_probs)
            why = ("旧形态骗得过（绿）+ 新形态咬住（红）" if good
                   else f"旧绿={weak_ok} 新问题数={len(strong_probs)}")
        print(f"[{'PASS' if good else 'FAIL'}] {name} —— {why}")
        if not good:
            bad_cases.append(name)
    n_mut = sum(1 for c in cases if not (len(c) > 3 and c[3]))
    print(f"[criteria-mutations] {len(cases) - len(bad_cases)}/{len(cases)} PASS"
          f"（突变体 {n_mut} 例 + 正控 {len(cases) - n_mut} 例；"
          f"每例 = 旧形态绿 ∧ 新形态红）")
    return 0 if not bad_cases else 1


if __name__ == "__main__":
    sys.exit(main())
