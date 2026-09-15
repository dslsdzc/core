#!/usr/bin/env python3
"""HIT 表模式合成层测试（M1 Task 3）——事件流降低 + 常量池 + 表模式运行闭环。

Task 3 = 合成层：IR 直线子集 → 4 核事件流（sub/nand/load/store）：
- 表模式下 corearch 内部 = IR →（降低）→ 事件流 →（表投影）→ 字节
- 降低规则：sub 直通；add → sub 反减（sub(a, sub(0,b))，0 = 常量池）；常量
  IR_CONST → 常量池槽 load 事件（ELF rodata 写入）；store/load 直通事件
- 超出直线子集的 op（分支/调用/移位/mod/…）→ 编译报错「needs more events」
- 判据 = 运行正确性（旧路径与表模式同 .ccr 运行 exit 一致且等于手算期望值）
  —— Task 2 的逐字节对照随合成层失效（const → 常量池 load 与旧 imm 路径
  字节不同，按计划 Task 3/4 以冒烟运行正确为判据）
- --dump-events 调试输出（事件流 dump 断言）

注（评审挂账）：源语言无位与/位或运算符（&&/|| 恒短路分支化，超 M1 直线
子集）→ and→nand / or→德摩根 规则在 M1 无源码载体，属 IR 层完备性代码。

需先重建自举编译器：nice -n 19 python3 build_selfhost_native.py
"""

import subprocess
import sys
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"
COREARCH = BASE / "build" / "corearch"
TABLE = BASE / "src" / "arch" / "x86_64" / "core-x86.toml"
HIT_SRC = BASE / "src" / "arch" / "hit" / "hit.cr"
LOWER_SRC = BASE / "src" / "arch" / "hit" / "lower_to_core.cr"
SMOKE_ADD = BASE / "tests" / "hit" / "smoke_add.cr"
SMOKE_MEM = BASE / "tests" / "hit" / "smoke_mem.cr"
OPT = "1"  # 与 corec build 默认同（corec/main.cr: g_opt_level 默认 1）

# 载体（直线子集：const/store/add/sub/load/return——无 &&/||（短路分支化超 M1））
SUB_SRC = "fn main() -> int {\n    a := 7;\n    b := 5;\n    return a - b;\n}\n"
SUB_RC = 2  # 7 - 5

ADD_SRC = "fn main() -> int {\n    a := 7;\n    b := 5;\n    return a + b;\n}\n"
ADD_RC = 12  # 7 + 5（add → sub 反减：12 = 7 - (0 - 5)）

MEM_SRC = """fn main() -> int {
    a: ., mut = 6;
    b := 3;
    a = a + b;
    a = a - 4;
    return a;
}
"""
MEM_RC = 5  # 6+3-4（链式加减 + 内存读写，与 tests/hit/smoke_mem.cr 同源同期望）

MOD_SRC = "fn main() -> int {\n    a := 7;\n    b := 3;\n    return a % b;\n}\n"


def run_bin(binary, args):
    return subprocess.run(
        [str(binary)] + args,
        cwd=BASE,
        capture_output=True,
        text=True,
        timeout=300,
    )


def compile_ccr(tmp: Path, name: str, src: str):
    """corec ccr：.cr → .ccr（仅前端，不落 corearch）。"""
    src_p = tmp / f"{name}.cr"
    src_p.write_text(src)
    ccr_p = tmp / f"{name}.ccr"
    r = run_bin(COREC, ["ccr", str(src_p), "-o", str(ccr_p), "--opt-level", OPT])
    if r.returncode != 0:
        raise RuntimeError(f"corec ccr failed: {r.stdout + r.stderr}")
    if not ccr_p.exists():
        raise RuntimeError(f"corec ccr produced no .ccr: {r.stdout + r.stderr}")
    return ccr_p


def emit_bin(ccr: Path, out: Path, table: bool, dump: bool = False):
    args = [str(ccr), "--elf", "--opt-level", OPT, "-o", str(out)]
    if table:
        args += ["--table", str(TABLE)]
    if dump:
        args += ["--dump-events"]
    r = run_bin(COREARCH, args)
    if r.returncode != 0:
        raise RuntimeError(f"corearch failed ({'table' if table else 'old'}): {r.stdout + r.stderr}")
    if not out.exists():
        raise RuntimeError(f"corearch produced no output: {r.stdout + r.stderr}")
    return r


def build_both(tmp: Path, name: str, src: str):
    """同一 .ccr → 旧路径 + --table 路径两 ELF；返回 (old_bytes, tab_bytes, outputs)。"""
    ccr = compile_ccr(tmp, name, src)
    old_out = tmp / f"{name}_old"
    tab_out = tmp / f"{name}_tab"
    old_r = emit_bin(ccr, old_out, table=False)
    tab_r = emit_bin(ccr, tab_out, table=True)
    return old_out.read_bytes(), tab_out.read_bytes(), old_r, tab_r


def run_elf(bin_path: Path):
    r = subprocess.run([str(bin_path)], capture_output=True, text=True, timeout=60)
    return r.returncode


def test_run_closure(tmp: Path, name: str, src: str, expected_rc: int, need_lowered: bool) -> bool:
    """表模式运行闭环：两路径 exit == 手算期望值；表模式须真实经事件流发射。"""
    try:
        _, _, old_r, tab_r = build_both(tmp, name, src)
    except RuntimeError as e:
        print(f"[FAIL] {name}: {e}")
        return False
    out = tab_r.stdout + tab_r.stderr
    # M2a Task 1：schema v2 后事件数 4 → 9（运行时核：1-4 数据 + 5-9 控制/调用/系统）
    if "hit table loaded: 9 events" not in out:
        print(f"[FAIL] {name}: missing 'hit table loaded: 9 events' in --table output")
        print(out)
        return False
    if need_lowered:
        m = out.find(" events emitted")
        if m < 0:
            print(f"[FAIL] {name}: missing 'events emitted' summary in --table output")
            print(out)
            return False
        cnt_txt = out[:m].rsplit("hit table: ", 1)[-1].strip()
        if not cnt_txt.isdigit() or int(cnt_txt) < 1:
            print(f"[FAIL] {name}: events-emitted count invalid: '{cnt_txt}'")
            print(out)
            return False
    old_rc = run_elf(tmp / f"{name}_old")
    tab_rc = run_elf(tmp / f"{name}_tab")
    if old_rc != expected_rc or tab_rc != expected_rc:
        print(f"[FAIL] {name}: run exit codes old={old_rc} table={tab_rc} expected={expected_rc}")
        return False
    print(f"[PASS] {name}: old & --table ELF both exit {expected_rc}")
    return True


def test_dump_events(tmp: Path, name: str, src: str, expect_sub_ev: bool,
                     expect_nand_ev: bool, expect_pool: int) -> bool:
    """--dump-events：事件流可 dump（ev 行 + 常量池条目数断言）。"""
    try:
        ccr = compile_ccr(tmp, name, src)
        dump_out = tmp / f"{name}_dump"
        r = emit_bin(ccr, dump_out, table=True, dump=True)
    except RuntimeError as e:
        print(f"[FAIL] dump/{name}: {e}")
        return False
    out = r.stdout + r.stderr
    ok = True
    m = out.find("hit events lowered:")
    if m < 0:
        print(f"[FAIL] dump/{name}: missing 'hit events lowered:' summary")
        ok = False
    else:
        cnt_txt = out[m:].split("\n", 1)[0].replace("hit events lowered:", "").strip()
        if not cnt_txt.isdigit() or int(cnt_txt) < 1:
            print(f"[FAIL] dump/{name}: event count invalid: '{cnt_txt}'")
            ok = False
    pool_marker = f"hit pool entries: {expect_pool}"
    if pool_marker not in out:
        print(f"[FAIL] dump/{name}: expected '{pool_marker}'")
        ok = False
    for probe, need in (("ev sub", expect_sub_ev), ("ev nand", expect_nand_ev)):
        if need and probe not in out:
            print(f"[FAIL] dump/{name}: expected '{probe}' in dump")
            ok = False
    if ok:
        print(f"[PASS] dump/{name}: event stream + const pool dump ok")
    return ok


def test_reject_out_of_subset(tmp: Path) -> bool:
    """超 M1 直线子集 op（mod）→ 表模式拒绝编译（exit 1 + 'needs more events'）。"""
    try:
        ccr = compile_ccr(tmp, "reject_mod", MOD_SRC)
        r = run_bin(COREARCH, [str(ccr), "--elf", "--table", str(TABLE), "-o", str(tmp / "reject_mod.out")])
    except RuntimeError as e:
        print(f"[FAIL] reject: {e}")
        return False
    if r.returncode == 0:
        print("[FAIL] --table on IR_BINARY(OP_MOD) should exit 1 (needs more events)")
        print(r.stdout + r.stderr)
        return False
    if "needs more events" not in (r.stdout + r.stderr):
        print("[FAIL] expected 'needs more events' error message")
        print(r.stdout + r.stderr)
        return False
    print("[PASS] --table on out-of-subset op -> exit 1 with 'needs more events'")
    return True


def test_smoke_files() -> bool:
    """tests/hit/smoke_add.cr + smoke_mem.cr 端到端（源文件载体，Task 4 冒烟同源）。"""
    ok = True
    for src_p, rc, tag in ((SMOKE_ADD, 2, "smoke_add"), (SMOKE_MEM, 5, "smoke_mem")):
        if not src_p.exists():
            print(f"[FAIL] {tag}: missing source {src_p}")
            ok = False
            continue
        with tempfile.TemporaryDirectory(prefix="hit_smoke_") as td:
            tmp = Path(td)
            ccr_p = tmp / f"{tag}.ccr"
            r = run_bin(COREC, ["ccr", str(src_p), "-o", str(ccr_p), "--opt-level", OPT])
            if r.returncode != 0 or not ccr_p.exists():
                print(f"[FAIL] {tag}: corec ccr failed: {r.stdout + r.stderr}")
                ok = False
                continue
            out_p = tmp / tag
            r2 = run_bin(COREARCH, [str(ccr_p), "--elf", "--table", str(TABLE), "-o", str(out_p)])
            if r2.returncode != 0 or not out_p.exists():
                print(f"[FAIL] {tag}: corearch --table failed: {r2.stdout + r2.stderr}")
                ok = False
                continue
            got = run_elf(out_p)
            if got != rc:
                print(f"[FAIL] {tag}: table ELF exit {got}, expected {rc}")
                ok = False
                continue
            print(f"[PASS] {tag}: --table run exit {rc}")
    return ok


def test_table_load_missing_file(tmp: Path) -> bool:
    """表文件缺 → load 失败即退（exit 1），即使给了有效 .ccr。"""
    ccr = compile_ccr(tmp, "missing_tbl", SUB_SRC)
    r = run_bin(COREARCH, [str(ccr), "--elf", "--table", str(tmp / "no" / "such" / "table.toml")])
    if r.returncode == 0:
        print("[FAIL] corearch --table <missing> should exit 1")
        print(r.stdout + r.stderr)
        return False
    print("[PASS] corearch --table <missing> -> exit != 0")
    return True


def test_reject_table_with_link_shared(tmp: Path) -> bool:
    """M2-1: --table × --link/--shared 显式拒绝（池 mov rip disp 链接路径未测试）。"""
    try:
        ccr = compile_ccr(tmp, "rej_tab_link", SUB_SRC)
    except RuntimeError as e:
        print(f"[FAIL] reject-combo: {e}")
        return False
    ok = True
    for extra in (["--link", "auto"], ["--link", "x.so"], ["--shared"]):
        out_p = tmp / "rej_combo.out"
        r = run_bin(COREARCH, [str(ccr), "--elf", "--table", str(TABLE)] + extra
                    + ["-o", str(out_p)])
        if r.returncode == 0:
            print(f"[FAIL] --table with {' '.join(extra)} should exit 1 (explicit reject)")
            print(r.stdout + r.stderr)
            ok = False
            continue
        if "cannot be combined with --link/--shared" not in r.stderr:
            print(f"[FAIL] --table with {' '.join(extra)}: expected rejection msg on stderr")
            print("stderr:", r.stderr)
            print("stdout:", r.stdout)
            ok = False
            continue
        print(f"[PASS] --table with {' '.join(extra)} -> exit 1 (stderr reject)")
    return ok


def test_dump_sentinel_clean(tmp: Path) -> bool:
    """M2-2a: 未用哨兵字段（store dst / load s2）= 0——dump 不得出现 255/−1 读回伪影。

    旧实现存 −1：自持 x86 截断除法写回单字节 0xFF → 读回 255；Python 解释地板
    除四字节全 0xFF → 读回 0xFFFFFFFF——实现分裂，未用字段应恒存 0。
    """
    try:
        ccr = compile_ccr(tmp, "dump_sentinel", MEM_SRC)
        dump_out = tmp / "dump_sentinel_out"
        r = emit_bin(ccr, dump_out, table=True, dump=True)
    except RuntimeError as e:
        print(f"[FAIL] dump/sentinel: {e}")
        return False
    out = r.stdout + r.stderr
    if "hit pool entries: " not in out:
        print("[FAIL] dump/sentinel: missing pool summary")
        return False
    bad = [s for s in ("dst=255", "s2=255", "dst=-1", "s2=-1") if s in out]
    if bad:
        print(f"[FAIL] dump/sentinel: unused-field readback artifacts {bad} in dump")
        print(out)
        return False
    print("[PASS] dump/sentinel: unused fields (store dst / load s2) = 0, no 255/-1 artifacts")
    return True


def test_table_bad_opcode_range(tmp: Path) -> bool:
    """评审项：opcode >255 不得静默截断——表数据值域校验拒绝（exit 1）。

    M2a Task 1 修订：不再对真实表做文本手术（[0x4D, 0x29] 锚在 v1→v2 迁移后
    消失）——改为在表尾追加一个 v1 语法事件（id 50，opcode = [0x300]）。
    """
    ccr = compile_ccr(tmp, "bad_opcode_tbl", SUB_SRC)
    bad = tmp / "bad_opcode.toml"
    content = TABLE.read_text() + (
        "\n[[event]]\nid = 50\nname = \"badop\"\ninputs = 0\noutputs = 0\n"
        "side_effect = \"pure\"\n\n[[event.proj]]\nisa = \"x86-64\"\n"
        "opcode = [0x300]\nmodrm_reg_role = \"dst\"\nmodrm_rm_role = \"src2\"\n"
        "rm_mode = 0\n")
    bad.write_text(content)
    r = run_bin(COREARCH, [str(ccr), "--elf", "--table", str(bad)])
    if r.returncode == 0:
        print("[FAIL] corearch --table <opcode >255> should exit 1 (no silent truncation)")
        print(r.stdout + r.stderr)
        return False
    if "opcode byte >255" not in (r.stdout + r.stderr):
        print("[FAIL] expected 'opcode byte >255' error message")
        print(r.stdout + r.stderr)
        return False
    print("[PASS] corearch --table <opcode byte >255> -> exit 1 with error")
    return True


def test_hit_lower_sources_check_clean() -> bool:
    """hit.cr / lower_to_core.cr 独立 corec check 干净。"""
    ok = True
    for f in (HIT_SRC, LOWER_SRC):
        if not f.exists():
            print(f"[FAIL] missing source: {f}")
            ok = False
            continue
        r = run_bin(COREC, ["check", str(f)])
        if r.returncode != 0:
            print(f"[FAIL] corec check {f.name} exit={r.returncode}")
            print(r.stdout + r.stderr)
            ok = False
        else:
            print(f"[PASS] corec check {f.name} -> exit 0")
    return ok


# ════════════════════════════════════════════════════════════════
# M2a Task 2：事件流注入测试通道（--hit-events-file）——模板解释器 v2 形态
# 发射的对照载体。通道 = --dump-events 逆格式文本文件：`ev <name> [dst=N]
# [s1=[pool]N] [s2=N]` 每事件一行（操作数缺省 = 从所附着指令取——附着规则见
# lower_to_core.cr hit_inject_events 注释）+ `pool v0 v1..` 池值行。注入取代
# 降低（跳过 lower 直接 emit）；只映射到指令的某条事件才走表（未列事件指令 =
# 旧路径）——同源程序表路径 vs 旧路径逐字节对照成立面 = 每事件字节 == 旧路径
# 该指令字节（jump = E9 rel32；sub/load/store 形态 = v2 字段发射 + disp auto）。
# ════════════════════════════════════════════════════════════════

# 注（MW 里程碑后）：int add/sub 定值目标 = 规则 A 恒 tagged → mw 门整条落旧
# 路径——sub/nand 事件在现架构对真 IR 不可达（M2b Task 6/8 快路径走表通道），
# 逐字节对照载体只用非门面指令：store/load（as 槽载入）/jump/cst。
# jump 对照载体：if（无 else）体内 store 链 + 尾 jump 指向合并标签 = if 后首个
# 事件指令（d 的 load——事件序 4）。跳转目标 = 事件序（jump 事件 s1 域）。
JUMP_SRC = """fn main() -> int {
    a : ., mut = 10;
    b := 3;
    if a > b {
        c := a as int;
        a = c;
    }
    d := a as int;
    return d;
}
"""
JUMP_EVENTS = ["ev load", "ev store", "ev store", "ev jump s1=4", "ev load", "ev store"]
JUMP_RC = 10  # 10>3 真 → c=10、a=10 → d=10

# disp 对照载体：let 初始化 store ×2 + as 槽 load/store 链 + 变量移动 store
#（事件全部 auto disp8——旧路径 e2_ld/e2_st 同规则；固定 disp32 旧发射会红）
DISP_SRC = """fn main() -> int {
    a : ., mut = 10;
    b := 3;
    c := a as int;
    a = c;
    d := b as int;
    e := a as int;
    a = d;
    return a;
}
"""
DISP_EVENTS = ["ev store", "ev store", "ev load", "ev store", "ev store",
               "ev load", "ev store", "ev load", "ev store", "ev store"]
DISP_RC = 3  # a ← d ← b = 3

# disp32 对照载体：20 槽变量（a16+ 槽偏移 < -128 → disp32；a15 = -128 边界 disp8）
BIG_EVENTS = ["ev store"] * 20 + ["ev store"]
BIG_RC = 18  # a19 = a18


def big_src() -> str:
    lines = ["fn main() -> int {"]
    for i in range(20):
        lines.append(f"    a{i} : ., mut = {i};")
    lines.append("    a19 = a18;")
    lines.append("    return a19;")
    lines.append("}")
    return "\n".join(lines) + "\n"


# imm 对照载体：cst 事件（fixture 表事件 11 = C7 /0 [rbp+disp] imm32——与旧路径
# const e2_li 同字节）。夹具 = 真实表 + 追加 cst 事件（events 9 → 10）。
CST_FIX = TABLE.read_text().replace("events = 9", "events = 10", 1) + (
    "\n[[event]]\nid = 11\nname = \"cst\"\ninputs = 2\noutputs = 1\n"
    "side_effect = \"pure\"\n\n[[event.proj]]\nisa = \"x86-64\"\n"
    "[[event.proj.step]]\nrex_w = 1\nopcode = [0xC7]\nmodrm_reg_digit = 0\n"
    "modrm_rm_role = \"dst\"\nrm_mode = 1\nimm_size = 4\nimm_role = \"src1\"\n")

IMM_SRC = "fn main() -> int {\n    a := 63;\n    return a;\n}\n"
IMM_EVENTS = ["ev cst"]
IMM_RC = 63

# 池对照载体：const → 池 load（M1 语义——字节与旧路径 e2_li 有意不同，判据 = 运行）
POOL_SRC = "fn main() -> int {\n    a := 7;\n    b := 5;\n    return a - b;\n}\n"
POOL_LINES = ["pool 7 5"]
POOL_EVENTS = ["ev load s1=pool0", "ev store", "ev load s1=pool1", "ev store"]
POOL_RC = 2  # a-b 指令 = mw 门旧路径——池载入 + 初始化 store 经表


def emit_inject(tmp: Path, name: str, src: str, ev_lines, pool_lines=(),
                table=TABLE):
    """corearch --table --hit-events-file：.cr → .ccr → 注入发射。
    返回 (r, inj_bytes|None, out_p)。"""
    ccr = compile_ccr(tmp, name, src)
    ev_p = tmp / f"{name}.events"
    ev_p.write_text("\n".join(list(pool_lines) + list(ev_lines)) + "\n")
    out_p = tmp / f"{name}_inj"
    r = run_bin(COREARCH, [str(ccr), "--elf", "--opt-level", OPT,
                           "--table", str(table),
                           "--hit-events-file", str(ev_p), "-o", str(out_p)])
    return r, (out_p.read_bytes() if out_p.exists() else None), out_p


def _ev_count(r) -> int:
    """'hit table: N events emitted' 中 N（无 → -1）。"""
    out = r.stdout + r.stderr
    m = out.find(" events emitted")
    if m < 0:
        return -1
    txt = out[:m].rsplit("hit table: ", 1)[-1].strip()
    return int(txt) if txt.isdigit() else -1


def test_inject_byte_compare(tmp: Path, tag: str, src: str, ev_lines,
                             expected_rc: int, pool_lines=(), table=TABLE) -> bool:
    """注入通道逐字节对照：同源 .ccr 旧路径 ELF vs 注入表路径 ELF 全文件一致
    + 运行 exit 一致 + 注入事件全部经表发射（计数 == 文件事件行数）。"""
    try:
        ccr = compile_ccr(tmp, tag, src)
        old_out = tmp / f"{tag}_old"
        old_r = emit_bin(ccr, old_out, table=False)
        old_b = old_out.read_bytes()
        r, inj_b, out_p = emit_inject(tmp, tag + "_inj", src, ev_lines,
                                      pool_lines=pool_lines, table=table)
    except RuntimeError as e:
        print(f"[FAIL] inject/{tag}: {e}")
        return False
    ok = True

    def chk(cond, msg):
        nonlocal ok
        if not cond:
            print(f"[FAIL] inject/{tag}: {msg}")
            print("  " + (r.stdout + r.stderr).replace("\n", "\n  ")[:800])
            ok = False

    chk(r.returncode == 0 and inj_b is not None, "corearch --hit-events-file failed")
    chk(_ev_count(r) == len(ev_lines),
        f"events-emitted {_ev_count(r)} != file lines {len(ev_lines)}（有事件落旧路径?）")
    chk(inj_b == old_b, f"injected ELF != old-path ELF ({len(old_b)} vs {len(inj_b or b'')} bytes)")
    if ok:
        old_rc = run_elf(old_out)
        inj_rc = run_elf(out_p)
        chk(old_rc == expected_rc and inj_rc == expected_rc,
            f"run exit old={old_rc} inj={inj_rc} expected={expected_rc}")
    if ok:
        print(f"[PASS] inject/{tag}: {len(ev_lines)} 事件注入发射 == 旧路径逐字节 "
              f"({len(old_b)}B) 且运行 exit {expected_rc}")
    return ok


def test_inject_pool_run(tmp: Path) -> bool:
    """池注入运行闭环：const → 池 load 事件（M1 语义）——池值入 rodata、运行
    exit 与旧路径一致（字节有意不同——const 走池 vs 旧路径 imm 直载）。"""
    try:
        r, inj_b, out_p = emit_inject(tmp, "pool", POOL_SRC, POOL_EVENTS,
                                      pool_lines=POOL_LINES)
    except RuntimeError as e:
        print(f"[FAIL] inject/pool: {e}")
        return False
    ok = True

    def chk(cond, msg):
        nonlocal ok
        if not cond:
            print(f"[FAIL] inject/pool: {msg}")
            print("  " + (r.stdout + r.stderr).replace("\n", "\n  ")[:800])
            ok = False

    chk(r.returncode == 0 and inj_b is not None, "corearch --hit-events-file failed")
    chk(_ev_count(r) == len(POOL_EVENTS), f"events-emitted != {len(POOL_EVENTS)}")
    if ok:
        got = run_elf(out_p)
        chk(got == POOL_RC, f"pool-injected ELF exit {got}, expected {POOL_RC}")
    if ok:
        print(f"[PASS] inject/pool: 池注入（pool 7 5）运行 exit {POOL_RC}")
    return ok


def test_inject_rejects(tmp: Path) -> bool:
    """注入通道拒绝面：坏行语法 / 未知事件名 / 不支持事件（branch = Task 3 前
    无指令期望它）/ 越界 jump 目标序 → exit 1 + 错误消息。"""
    cases = [
        ("bad_line", JUMP_SRC, ["ev sub dst=abc"], (), "bad dst"),
        ("unknown_event", JUMP_SRC, ["ev bogus"], (), "unknown event"),
        ("unsupported_branch", JUMP_SRC, ["ev store", "ev branch dst=0 s1=1 s2=0"],
         (), "no instruction"),
        ("jump_target_oob", JUMP_SRC, ["ev load", "ev jump s1=9", "ev store"],
         (), "out of range"),
        ("no_table", JUMP_SRC, ["ev store"], (), "needs --table"),
    ]
    ok = True
    for tag, src, ev_lines, pool_lines, token in cases:
        try:
            ccr = compile_ccr(tmp, "rej_" + tag, src)
            ev_p = tmp / f"rej_{tag}.events"
            ev_p.write_text("\n".join(list(pool_lines) + list(ev_lines)) + "\n")
            args = [str(ccr), "--elf", "--opt-level", OPT, "-o", str(tmp / "rej.out")]
            if tag != "no_table":
                args = [str(ccr), "--elf", "--opt-level", OPT, "--table", str(TABLE),
                        "--hit-events-file", str(ev_p), "-o", str(tmp / "rej.out")]
            else:
                args += ["--hit-events-file", str(ev_p)]
            r = run_bin(COREARCH, args)
        except RuntimeError as e:
            print(f"[FAIL] reject/{tag}: {e}")
            ok = False
            continue
        out = r.stdout + r.stderr
        if r.returncode == 0 or token not in out:
            print(f"[FAIL] reject/{tag}: expected exit 1 + {token!r}")
            print("  " + out.replace("\n", "\n  ")[:600])
            ok = False
            continue
        print(f"[PASS] reject/{tag}: exit 1 with {token!r}")
    return ok


# ════════════════════════════════════════════════════════════════
# M2a Task 1：schema v2 加载 walker + 字段解析断言（TDD：v2 加载器未实现前红）
# ════════════════════════════════════════════════════════════════
# 静态夹具（自包含，不随真实表迁移变动）：
#   F1 = v1 子集语法事件 1-4（兼容面：M1 表形态 = v2 子集，加载不变）
#        + v2 语法事件 5-9（jump/branch/call/ret/extern——真实 x86 投影声明，
#        语义绑定 = Task 4 降低对照定稿）+ [runtime.x86] 小节
#   F2 = F1 + 事件 3 第二 proj（多 proj 条目）
#   F3 = F1 + 事件 10（v2 全字段：prefix/rex 全位/3 字节 opcode/SIB/digit/imm/rel8/cond）

V2_TABLE_HEAD = """[table]
name = "core-x86-min"
events = 9            # 运行时核：1-4 数据 + 5-9 控制/调用/系统（M2a）
"""

# 事件 1-4：v1 子集语法（字段直置 proj 层——M2a 兼容面，等价迁移前表）
V2_EV1_4 = """
[[event]]
id = 1                # sub
name = "sub"
arith = "sub"         # 语义锚：规约层引用（加载不消费）
inputs = 2
outputs = 1
side_effect = "pure"

[[event.proj]]
isa = "x86-64"
opcode = [0x4D, 0x29]        # REX.W+R+B + sub r/m64,r64（v1 行内字节惯例）
modrm_reg_role = "src2"
modrm_rm_role = "dst"
rm_mode = 0

[[event]]
id = 2
name = "nand"
inputs = 2
outputs = 1
side_effect = "pure"

[[event.proj]]
isa = "x86-64"
opcode = [0x4D, 0x21]        # and r/m64,r64（nand 单步占位——M1 语义不变）
modrm_reg_role = "src2"
modrm_rm_role = "dst"
rm_mode = 0

[[event]]
id = 3
name = "load"
inputs = 1
outputs = 1
side_effect = "effect"

[[event.proj]]
isa = "x86-64"
opcode = [0x4C, 0x8B]        # REX.W+R + mov r64, r/m64（rm = rbp+disp32 槽寻址）
modrm_reg_role = "dst"
modrm_rm_role = "addr"
rm_mode = 1

[[event]]
id = 4
name = "store"
inputs = 2
outputs = 0
side_effect = "effect"

[[event.proj]]
isa = "x86-64"
opcode = [0x4C, 0x89]        # REX.W+R + mov r/m64, r64（写 [rbp+disp32] ← val）
modrm_reg_role = "val"
modrm_rm_role = "addr"
rm_mode = 1
"""

# 事件 5-9：v2 语法（[[event.proj.step]] 步小节——多步序列表达）
V2_EV5_9 = """
[[event]]
id = 5
name = "jump"
inputs = 1            # 目标 = 事件流位置（IR_JUMP s1 → 标签映射）
outputs = 0
side_effect = "pure"

[[event.proj]]
isa = "x86-64"
# jump = E9 rel32（无条件转移；rel kind = event → 事件流位置回填表）
[[event.proj.step]]
opcode = [0xE9]
rel_role = "src1"
rel_kind = "event"
rel_size = 32

[[event]]
id = 6
name = "branch"
inputs = 3            # 条件 s1（≠0 真）、真目标 s2、假目标 s3
outputs = 0
side_effect = "pure"

[[event.proj]]
isa = "x86-64"
# branch = cmp + jne 两步序列：cmp r10(=条件载入), 0 → ZF=(s1==0)；
# jne（ZF=0 → 条件≠0 → 真目标 s2）。假目标 = 事件流下一条（相邻跳过选型 =
# 降低层 Task 4 定稿——此处仅模板声明）
[[event.proj.step]]
rex_w = 1             # REX.W+B（rm = r10 需 B 位；/7 digit 组不得 REX.R）
rex_b = 1
opcode = [0x83]       # 83 /7 ib = cmp r/m64, imm8
modrm_reg_digit = 7
modrm_rm_role = "dst"
rm_mode = 0
imm_size = 1
imm_role = "lit"
imm_lit = 0
cond_role = "src1"    # 条件源槽（判定语义 Task 4 对照定稿）

[[event.proj.step]]
opcode = [0x0F, 0x85]   # jne rel32（ZF=0 → 真目标）
rel_role = "src2"
rel_kind = "event"
rel_size = 32

[[event]]
id = 7
name = "call"
inputs = 1            # 目标 = 函数索引（.ccr SYM func 行序）
outputs = 0           # 值返回 = 调用点序列槽协议（R2/R7 算法保留代码，Task 4）
side_effect = "effect"

[[event.proj]]
isa = "x86-64"
# call = E8 rel32（rel kind = func → 函数体事件流位置回填表）
[[event.proj.step]]
opcode = [0xE8]
rel_role = "src1"
rel_kind = "func"
rel_size = 32

[[event]]
id = 8
name = "ret"
inputs = 0
outputs = 0
side_effect = "pure"

[[event.proj]]
isa = "x86-64"
# ret = C3（调用栈机制 = [runtime.x86] 条目；返回序列 = R7 算法保留代码）
[[event.proj.step]]
opcode = [0xC3]

[[event]]
id = 9
name = "extern"
inputs = 1            # 外部符号
outputs = 0
side_effect = "effect"

[[event.proj]]
isa = "x86-64"
# extern = E8 rel32 + 外部重定位标记（rel kind = extern → ext_rel 同族回填）
[[event.proj.step]]
opcode = [0xE8]
rel_role = "src1"
rel_kind = "extern"
rel_size = 32
"""

V2_RUNTIME = """
[runtime.x86]
# 运行时条目最小描述（spec §6）：x86-64 一档。现行约定 = SysV 寄存器传参
# （rdi/rsi/rdx/rcx/r8/r9——elf.cr R2 参数拷贝：callee 帧槽保存，与分配器一致）；
# save 集 = callee-saved rbx/r12-15；extern = call rel32 + ext_rel 符号解析
call_mechanism = "stack"
call_ret_addr = "pushed"
call_stack_grow = "down"
param_mode = "regs"
param_regs = "rdi rsi rdx rcx r8 r9"
save_regs = "rbx r12 r13 r14 r15"
extern_entry = "call_rel32"
extern_resolve = "ext_rel"
"""

V2_FIX = V2_TABLE_HEAD + V2_EV1_4 + V2_EV5_9 + V2_RUNTIME

V2_F2 = V2_FIX.replace(
    "[[event]]\nid = 4",
    "[[event.proj]]        # 事件 3 第二形态（M2a 多 proj 条目：rm_mode 0 寄存器寻址形——\n"
    "isa = \"x86-64\"        #   形态占位，选择语义 = 发射器 Task 9+；proj0 = M1 兼容视区）\n"
    "opcode = [0x49, 0x8B]\n"
    "modrm_reg_role = \"dst\"\n"
    "modrm_rm_role = \"addr\"\n"
    "rm_mode = 0\n"
    "\n[[event]]\nid = 4",
    1,
)

V2_SINK = """
[[event]]
id = 10
name = "sink"
inputs = 2
outputs = 1
side_effect = "effect"

[[event.proj]]        # 形态 A：rm_mode 2 SIB 族 + rex 全位 + 3 字节 opcode（域解析
isa = "x86-64"        #   载体——movbe r64,m64 真实字节；绑定 = 数据化批 3 E 族索引寻址）
rex_w = 1
rex_r = 1
rex_x = 1
rex_b = 1
opcode = [0x0F, 0x38, 0xF0]
modrm_reg_role = "dst"
modrm_rm_role = "addr"
rm_mode = 2
sib_scale = 3
sib_index_role = "src2"
sib_base_role = "addr"
disp_size = 4
disp_src = "addr"

[[event.proj]]        # 形态 B：/digit + imm 字面量（C7 /0 mov r/m64, imm32 域——
isa = "x86-64"        #   绑定 = 数据化批 1 B1 imm32→槽；imm_lit = 63 字面量）
rex_w = 1
opcode = [0xC7]
modrm_reg_digit = 0
modrm_rm_role = "dst"
rm_mode = 1
imm_size = 4
imm_role = "lit"
imm_lit = 63

[[event.proj]]        # 形态 C：前缀 + rel8 + cond（前缀域解析载体：66 90 = 2 字节
isa = "x86-64"        #   nop 真实字节——消费面 = SSE/串行系 Task 12/13 预留）
prefix = [0x66]
opcode = [0x90]

[[event.proj]]        # 形态 D：rel8（jne rel8——G2 rel.size {8|32} 的 8 侧）
isa = "x86-64"
opcode = [0x75]
rel_role = "src2"
rel_kind = "event"
rel_size = 8
cond_role = "src1"

[[event.proj]]        # 形态 E：imm64 回填 kind（movabs rax, [fnaddr] 域——B2 movabs
isa = "x86-64"        #   imm64 回填 kind = fnaddr；reg 嵌 opcode 字面量 = Task 12 扩展）
rex_w = 1
opcode = [0x48, 0xB8]
imm_size = 8
imm_kind = "fnaddr"
"""

V2_F3 = V2_FIX.replace("events = 9", "events = 10", 1) + V2_SINK

# 事件 10：单事件双 proj、双双用步小节（Task 1 评审项 1 锁——步小节解析循环
# 不得越过 [[event.proj]] 头续行吸收后续投影步小节：旧缺陷 p0 步数吞并 p1
# 的步 + 步记录重复入库，加载静默成功但表已错）。proj0/1 步字节取互异 1 字节
# opcode（90-93），读回即可判别归属。
V2_SECSEC = """
[[event]]
id = 10
name = "secsec"
inputs = 0
outputs = 0
side_effect = "pure"

[[event.proj]]
isa = "x86-64"
[[event.proj.step]]
opcode = [0x90]
[[event.proj.step]]
opcode = [0x91]

[[event.proj]]
isa = "x86-64"
[[event.proj.step]]
opcode = [0x92]
[[event.proj.step]]
opcode = [0x93]
"""

V2_F4 = V2_FIX.replace("events = 9", "events = 10", 1) + V2_SECSEC


def _write_fixture(tmp: Path, name: str, content: str) -> Path:
    p = tmp / f"{name}.toml"
    p.write_text(content)
    return p


# ── schema v2 walker：独立 Python 结构校验（与 hit.cr 加载器双实现互证） ──

_STEP_KEYS = {
    "prefix", "opcode", "rex_w", "rex_r", "rex_x", "rex_b",
    "modrm_reg_role", "modrm_reg_digit", "modrm_rm_role", "rm_mode",
    "modrm_base_role", "sib_scale", "sib_index_role", "sib_base_role",
    "disp_size", "disp_src", "imm_size", "imm_role", "imm_lit", "imm_kind",
    "rel_role", "rel_kind", "rel_size", "cond_role",
}
_EVENT_KEYS = {"id", "name", "arith", "inputs", "outputs", "side_effect"}
_PROJ_KEYS = {"isa"}
_RUNTIME_KEYS = {
    "call_mechanism", "call_ret_addr", "call_stack_grow",
    "param_mode", "param_regs", "save_regs", "extern_entry", "extern_resolve",
}
_ROLE_NAMES = {"dst", "src1", "src2", "addr", "val", "cond"}
_REG_NAMES = {"rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
              "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"}
_ROLE_OR_REG = _ROLE_NAMES | _REG_NAMES


def _val_token(s: str) -> str:
    """取原始值（剥行内注释/空白）——int 列表取 [..]，字符串取 ".."。"""
    s = s.strip()
    if s.startswith('"'):
        end = s.find('"', 1)
        if end < 0:
            raise ValueError(f"unterminated string: {s!r}")
        return s[: end + 1]
    if s.startswith("["):
        end = s.find("]")
        if end < 0:
            raise ValueError(f"unterminated list: {s!r}")
        return s[: end + 1]
    for i, ch in enumerate(s):
        if ch in " #\t":
            return s[:i]
    return s


def _tbl_int(s: str) -> int:
    s = _val_token(s)
    return int(s, 0) if s.startswith(("0x", "0X")) else int(s)


def _tbl_int_list(s: str) -> list:
    s = _val_token(s).strip()
    if not (s.startswith("[") and s.endswith("]")):
        raise ValueError(f"not an int list: {s!r}")
    inner = s[1:-1].strip()
    if not inner:
        return []
    return [_tbl_int(t) for t in inner.split(",")]


def _tbl_str(s: str) -> str:
    s = _val_token(s).strip()
    if not (len(s) >= 2 and s[0] == '"' and s[-1] == '"'):
        raise ValueError(f"not a string: {s!r}")
    return s[1:-1]


def load_v2_model(text: str):
    """节式解析 core-x86.toml → (table dict, events, runtime dict|None)。
    event = {fields, projs:[{fields, steps:[fields-dict...]}]}；proj 无步小节
    （flat v1 子集）时 steps 为空、字段留在 proj.fields。"""
    table, events, runtime = {}, [], None
    cur_ev = cur_proj = cur_step = None
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line == "[table]":
            cur_ev = cur_proj = cur_step = None
            continue
        if line == "[[event]]":
            cur_ev = {"fields": {}, "projs": []}
            events.append(cur_ev)
            cur_proj = cur_step = None
            continue
        if line == "[[event.proj]]":
            cur_proj = {"fields": {}, "steps": []}
            cur_ev["projs"].append(cur_proj)
            cur_step = None
            continue
        if line == "[[event.proj.step]]":
            cur_proj["steps"].append({})
            cur_step = cur_proj["steps"][-1]
            continue
        if line.startswith("[runtime.") and line.endswith("]"):
            runtime = {}
            cur_ev = cur_proj = cur_step = None
            continue
        if "=" not in line:
            raise ValueError(f"malformed line: {line!r}")
        k, _, v = line.partition("=")
        if cur_step is not None:
            cur_step[k.strip()] = v.strip()
        elif cur_proj is not None:
            cur_proj["fields"][k.strip()] = v.strip()
        elif cur_ev is not None:
            cur_ev["fields"][k.strip()] = v.strip()
        elif runtime is not None:
            runtime[k.strip()] = v.strip()
        else:
            table[k.strip()] = v.strip()
    return table, events, runtime


def _ev(events, eid: int):
    for e in events:
        if _tbl_int(e["fields"]["id"]) == eid:
            return e
    return None


def _chk_step_fields(sf, where, probs):
    """单步字段值域 + 关联规则（与 hit.cr v2 加载器规则镜像）。"""
    for k in sf:
        if k not in _STEP_KEYS:
            probs.append(f"{where}: unknown key {k!r}")
    # opcode：必选、1..3 字节、每字节 0..255
    if "opcode" not in sf:
        probs.append(f"{where}: missing opcode")
    else:
        try:
            op = _tbl_int_list(sf["opcode"])
        except ValueError as e:
            probs.append(f"{where}: opcode parse: {e}")
            op = []
        if not (1 <= len(op) <= 3):
            probs.append(f"{where}: opcode count {len(op)} not 1..3")
        for b in op:
            if not (0 <= b <= 255):
                probs.append(f"{where}: opcode byte {b} > 255")
    # prefix：≤2 字节、每字节 ≤255
    if "prefix" in sf:
        try:
            pfx = _tbl_int_list(sf["prefix"])
        except ValueError as e:
            probs.append(f"{where}: prefix parse: {e}")
            pfx = []
        if len(pfx) > 2:
            probs.append(f"{where}: prefix count {len(pfx)} > 2")
        for b in pfx:
            if not (0 <= b <= 255):
                probs.append(f"{where}: prefix byte {b} > 255")
    # rex 位 ∈ {0,1}
    for rk in ("rex_w", "rex_r", "rex_x", "rex_b"):
        if rk in sf:
            try:
                rv = _tbl_int(sf[rk])
            except ValueError as e:
                probs.append(f"{where}: {rk} parse: {e}")
                continue
            if rv not in (0, 1):
                probs.append(f"{where}: {rk} = {rv} not 0/1")
    # modrm 存在性：任一 modrm/sib/disp 键 ⇒ reg 侧（role|digit）+ rm_role 齐备
    modrm_keys = [k for k in sf if k.startswith(("modrm_", "rm_mode", "sib_", "disp_"))]
    has_role = "modrm_reg_role" in sf
    has_digit = "modrm_reg_digit" in sf
    if modrm_keys:
        if not has_role and not has_digit:
            probs.append(f"{where}: modrm keys present but no reg role/digit")
        if "modrm_rm_role" not in sf:
            probs.append(f"{where}: modrm keys present but no rm role")
        if has_role and has_digit:
            probs.append(f"{where}: reg_role and reg_digit both present")
    elif "rm_mode" in sf:
        probs.append(f"{where}: rm_mode without modrm roles")
    # rm_mode 0..2 + 模式关联规则
    rm_mode = _tbl_int(sf["rm_mode"]) if "rm_mode" in sf else 0
    if rm_mode not in (0, 1, 2):
        probs.append(f"{where}: rm_mode {rm_mode} not 0..2")
    if rm_mode == 2 and ("sib_scale" not in sf or "sib_base_role" not in sf):
        probs.append(f"{where}: rm_mode 2 needs sib_scale and sib_base_role")
    for k in ("sib_scale", "sib_index_role", "sib_base_role"):
        if k in sf and rm_mode != 2:
            probs.append(f"{where}: {k} outside rm_mode 2")
    if "modrm_base_role" in sf and rm_mode == 0:
        probs.append(f"{where}: modrm_base_role needs rm_mode 1/2")
    for k in ("disp_size", "disp_src"):
        if k in sf and rm_mode == 0:
            probs.append(f"{where}: {k} needs rm_mode 1/2")
    if "sib_scale" in sf:
        sv = _tbl_int(sf["sib_scale"])
        if sv not in (0, 1, 2, 3):
            probs.append(f"{where}: sib_scale {sv} not 0..3")
    # 角色名值域（base 键额外收 rip）
    for k in ("modrm_reg_role", "modrm_rm_role", "disp_src", "rel_role", "cond_role"):
        if k in sf:
            nm = _tbl_str(sf[k])
            if nm not in _ROLE_OR_REG:
                probs.append(f"{where}: {k} bad role {nm!r}")
    for k in ("modrm_base_role", "sib_base_role"):
        if k in sf:
            nm = _tbl_str(sf[k])
            if nm not in _ROLE_OR_REG and nm != "rip":
                probs.append(f"{where}: {k} bad base {nm!r}")
    if "sib_index_role" in sf:
        nm = _tbl_str(sf["sib_index_role"])
        if nm not in _ROLE_OR_REG:
            probs.append(f"{where}: sib_index_role bad {nm!r}")
    if has_digit:
        dv = _tbl_int(sf["modrm_reg_digit"])
        if not (0 <= dv <= 7):
            probs.append(f"{where}: reg digit {dv} not 0..7")
    # disp
    if "disp_size" in sf:
        ds = sf["disp_size"].strip()
        if ds not in ('"auto"', "1", "4"):
            probs.append(f"{where}: disp_size {ds!r} not auto/1/4")
    # imm 组
    if "imm_size" in sf:
        iv = _tbl_int(sf["imm_size"])
        if iv not in (1, 2, 4, 8):
            probs.append(f"{where}: imm_size {iv} not 1/2/4/8")
        if "imm_role" not in sf and "imm_kind" not in sf:
            probs.append(f"{where}: imm_size without imm_role/imm_kind")
    if "imm_role" in sf:
        nm = _tbl_str(sf["imm_role"])
        if nm != "lit" and nm not in _ROLE_OR_REG:
            probs.append(f"{where}: imm_role bad {nm!r}")
    if "imm_lit" in sf:
        lv = _tbl_int(sf["imm_lit"])
        if lv < 0:
            probs.append(f"{where}: imm_lit negative ({lv}) unsupported")
    if "imm_kind" in sf:
        nm = _tbl_str(sf["imm_kind"])
        if nm != "fnaddr":
            probs.append(f"{where}: imm_kind bad {nm!r}")
        elif "imm_size" not in sf or _tbl_int(sf["imm_size"]) != 8:
            probs.append(f"{where}: imm_kind fnaddr needs imm_size 8")
    # rel 组：三者同现、kind 域、size 域
    rel_here = [k for k in ("rel_role", "rel_kind", "rel_size") if k in sf]
    if rel_here and len(rel_here) != 3:
        probs.append(f"{where}: rel fields incomplete ({sorted(rel_here)})")
    if "rel_kind" in sf:
        nm = _tbl_str(sf["rel_kind"])
        if nm not in ("event", "func", "extern"):
            probs.append(f"{where}: rel_kind bad {nm!r}")
    if "rel_size" in sf:
        rv = _tbl_int(sf["rel_size"])
        if rv not in (8, 32):
            probs.append(f"{where}: rel_size {rv} not 8/32")


def v2_walk(text: str) -> list:
    """schema v2 全字段结构校验 → 问题串列表（空 = 通过）。"""
    probs = []
    try:
        table, events, runtime = load_v2_model(text)
    except ValueError as e:
        return [f"structure: {e}"]
    # [table]
    for k in table:
        if k not in ("name", "events"):
            probs.append(f"table: unknown key {k!r}")
    if "name" not in table:
        probs.append("table: missing name")
    if "events" in table:
        try:
            want = _tbl_int(table["events"])
        except ValueError as e:
            probs.append(f"table: events parse: {e}")
            want = -1
        if want != len(events):
            probs.append(f"table: events = {want} but {len(events)} event sections")
    # 事件：id 唯一 + 每事件 ≥1 proj + 每 proj ≥1 步
    seen = {}
    for e in events:
        f = e["fields"]
        for k in f:
            if k not in _EVENT_KEYS:
                probs.append(f"event: unknown key {k!r}")
        if "id" not in f:
            probs.append("event: missing id")
            eid = -1
        else:
            try:
                eid = _tbl_int(f["id"])
            except ValueError:
                probs.append("event: bad id")
                eid = -1
        if eid < 1:
            probs.append(f"event: id {eid} < 1")
        if eid in seen:
            probs.append(f"event: duplicate id {eid}")
        seen[eid] = True
        if "name" not in f:
            probs.append(f"event {eid}: missing name")
        if f.get("side_effect") not in ('"pure"', '"effect"'):
            probs.append(f"event {eid}: side_effect {f.get('side_effect')!r} not pure/effect")
        for k in ("inputs", "outputs"):
            if k in f:
                try:
                    if _tbl_int(f[k]) < 0:
                        probs.append(f"event {eid}: {k} < 0")
                except ValueError as e:
                    probs.append(f"event {eid}: {k} parse: {e}")
        projs = e["projs"]
        if not projs:
            probs.append(f"event {eid}: no projection")
        for pi, p in enumerate(projs):
            pf = p["fields"]
            where = f"event {eid} proj {pi}"
            for k in pf:
                if k not in _PROJ_KEYS | _STEP_KEYS:
                    probs.append(f"{where}: unknown proj key {k!r}")
            isa = pf.get("isa")
            if isa != '"x86-64"':
                probs.append(f"{where}: isa {isa!r} not x86-64")
            if p["steps"]:
                for k in pf:
                    if k != "isa":
                        probs.append(f"{where}: key {k!r} outside step sections")
                steps = p["steps"]
            else:
                # flat v1 子集：isa 以外的字段 = 单步字段
                steps = [{k: v for k, v in pf.items() if k != "isa"}]
            for si, sf in enumerate(steps):
                _chk_step_fields(sf, f"{where} step {si}", probs)
    # runtime 小节
    if runtime is not None:
        for k in runtime:
            if k not in _RUNTIME_KEYS:
                probs.append(f"runtime.x86: unknown key {k!r}")
        for k in _RUNTIME_KEYS:
            if k not in runtime:
                probs.append(f"runtime.x86: missing {k}")
        want = {"call_mechanism": "stack", "call_ret_addr": "pushed",
                "call_stack_grow": "down", "param_mode": "regs",
                "extern_entry": "call_rel32", "extern_resolve": "ext_rel"}
        for k, v in want.items():
            if k in runtime and runtime[k].strip() != f'"{v}"':
                probs.append(f"runtime.x86: {k} = {runtime[k]!r} (want {v!r})")
        for k in ("param_regs", "save_regs"):
            if k in runtime:
                try:
                    regs = _tbl_str(runtime[k]).split()
                except ValueError as e:
                    probs.append(f"runtime.x86: {k} parse: {e}")
                    regs = []
                for r in regs:
                    if r not in _REG_NAMES:
                        probs.append(f"runtime.x86: {k} unknown register {r!r}")
    return probs


def test_v2_walker_real_table() -> bool:
    """真实 core-x86.toml（v2 迁移后）walker 全字段 + 事件 5-9 存在性/形态断言。"""
    text = TABLE.read_text()
    probs = v2_walk(text)
    if probs:
        print(f"[FAIL] walker: {TABLE} schema violations ({len(probs)}):")
        for p in probs[:25]:
            print("  " + p)
        return False
    _, events, runtime = load_v2_model(text)
    ids = [_tbl_int(e["fields"]["id"]) for e in events]
    if ids != list(range(1, 10)):
        print(f"[FAIL] walker: event ids {ids}, expected 1..9 (运行时核事件 5-9 存在)")
        return False
    ok = True

    def chk(cond, msg):
        nonlocal ok
        if not cond:
            print(f"[FAIL] walker: {msg}")
            ok = False

    # 事件 1-4 迁移后 legacy 字节视区 = M1 模板字节（REX 组装 + opcode 拼接序）
    for eid, want in ((1, [0x4D, 0x29]), (2, [0x4D, 0x21]), (3, [0x4C, 0x8B]), (4, [0x4C, 0x89])):
        ev = _ev(events, eid)
        sf = ev["projs"][0]["steps"][0]
        rb = 0x40
        for bit, k in ((8, "rex_w"), (4, "rex_r"), (2, "rex_x"), (1, "rex_b")):
            if k in sf:
                rb |= bit * _tbl_int(sf[k])
        stream = ([_tbl_int(b) for b in _tbl_int_list(sf.get("prefix", "[]"))]
                  if "prefix" in sf else [])
        if rb != 0x40:
            stream.append(rb)
        stream += _tbl_int_list(sf["opcode"])
        chk(stream[:2] == want, f"event {eid} legacy stream {stream[:2]} != {want} (M1 字节等价)")
    # 5 jump：E9 rel32 kind=event
    ev = _ev(events, 5)
    st = ev["projs"][0]["steps"][0]
    chk(_tbl_int_list(st["opcode"]) == [0xE9], "jump opcode != [0xE9]")
    chk(_tbl_str(st["rel_role"]) == "src1" and _tbl_str(st["rel_kind"]) == "event"
        and _tbl_int(st["rel_size"]) == 32, "jump rel fields != src1/event/32")
    # 6 branch：2 步（digit+imm cmp / jne rel32）
    ev = _ev(events, 6)
    chk(len(ev["projs"]) == 1 and len(ev["projs"][0]["steps"]) == 2, "branch != 2 steps")
    s0, s1 = ev["projs"][0]["steps"]
    chk(_tbl_int(s0["modrm_reg_digit"]) == 7 and _tbl_int(s0["imm_lit"]) == 0
        and _tbl_str(s0["cond_role"]) == "src1", "branch step1 digit/imm/cond fields")
    chk(_tbl_int_list(s1["opcode"]) == [0x0F, 0x85] and _tbl_str(s1["rel_kind"]) == "event",
        "branch step2 != jne rel32")
    # 7 call：E8 kind=func；8 ret：C3 无 modrm/rel
    ev = _ev(events, 7)
    st = ev["projs"][0]["steps"][0]
    chk(_tbl_int_list(st["opcode"]) == [0xE8] and _tbl_str(st["rel_kind"]) == "func",
        "call != E8 kind=func")
    ev = _ev(events, 8)
    st = ev["projs"][0]["steps"][0]
    chk(_tbl_int_list(st["opcode"]) == [0xC3], "ret opcode != [0xC3]")
    chk(not any(k.startswith(("modrm_", "rel_", "rm_mode")) for k in st), "ret has modrm/rel keys")
    # 9 extern：E8 kind=extern
    ev = _ev(events, 9)
    st = ev["projs"][0]["steps"][0]
    chk(_tbl_int_list(st["opcode"]) == [0xE8] and _tbl_str(st["rel_kind"]) == "extern",
        "extern != E8 kind=extern")
    # runtime：save 集 = callee-saved rbx/r12-15（spec §6）
    save = set(_tbl_str(runtime["save_regs"]).split())
    chk(save == {"rbx", "r12", "r13", "r14", "r15"}, f"runtime save_regs {save} != rbx/r12-15")
    chk(_tbl_str(runtime["call_mechanism"]) == "stack"
        and _tbl_str(runtime["param_mode"]) == "regs"
        and _tbl_str(runtime["extern_resolve"]) == "ext_rel", "runtime mechanism fields")
    if ok:
        print("[PASS] walker: core-x86.toml v2 全字段 + 事件 5-9 + runtime 小节校验通过")
    return ok


def test_v2_fixture_load_f1(tmp: Path) -> bool:
    """F1 夹具：v1 子集语法事件 1-4（兼容面）+ v2 事件 5-9 + runtime → 加载 9 events
    + 事件 1-4 发射闭环（v1 子集模板在 v2 加载器下运行语义不变）。"""
    try:
        ccr = compile_ccr(tmp, "f1_sub", SUB_SRC)
        f1 = _write_fixture(tmp, "f1", V2_FIX)
        out_p = tmp / "f1_sub_tab"
        r = run_bin(COREARCH, [str(ccr), "--elf", "--table", str(f1), "-o", str(out_p)])
    except RuntimeError as e:
        print(f"[FAIL] f1: {e}")
        return False
    out = r.stdout + r.stderr
    if r.returncode != 0 or not out_p.exists():
        print("[FAIL] f1: corearch --table <v2 fixture> failed (expect load + emit ok)")
        print(out)
        return False
    if "hit table loaded: 9 events" not in out:
        print("[FAIL] f1: missing 'hit table loaded: 9 events'")
        print(out)
        return False
    if "hit table: " not in out:
        print("[FAIL] f1: missing 'hit table: N events emitted' summary")
        print(out)
        return False
    got = run_elf(out_p)
    if got != SUB_RC:
        print(f"[FAIL] f1: v1-subset events under v2 loader run exit {got}, expected {SUB_RC}")
        return False
    print(f"[PASS] f1: v1 子集 + v2 事件 5-9 + runtime 加载（9 events）且运行 exit {SUB_RC}")
    return True


def test_v2_fixture_multi_proj(tmp: Path) -> bool:
    """F2 夹具：事件 3 多 proj 条目 → 加载通过（proj0 = M1 兼容视区，发射不变）。"""
    try:
        ccr = compile_ccr(tmp, "f2_sub", SUB_SRC)
        f2 = _write_fixture(tmp, "f2", V2_F2)
        out_p = tmp / "f2_sub_tab"
        r = run_bin(COREARCH, [str(ccr), "--elf", "--table", str(f2), "-o", str(out_p)])
    except RuntimeError as e:
        print(f"[FAIL] f2: {e}")
        return False
    out = r.stdout + r.stderr
    if r.returncode != 0 or not out_p.exists():
        print("[FAIL] f2: corearch --table <multi-proj fixture> failed")
        print(out)
        return False
    if "hit table loaded: 9 events" not in out:
        print("[FAIL] f2: missing 'hit table loaded: 9 events'")
        print(out)
        return False
    got = run_elf(out_p)
    if got != SUB_RC:
        print(f"[FAIL] f2: multi-proj load run exit {got}, expected {SUB_RC}")
        return False
    print(f"[PASS] f2: 多 proj 条目加载（9 events）且 proj0 发射运行 exit {SUB_RC}")
    return True


def test_v2_fixture_sink_fields(tmp: Path) -> bool:
    """F3 夹具：事件 10 v2 全字段（prefix/rex 全位/3 字节 opcode/SIB/digit/imm/rel8/cond）
    → 逐字段解析通过（加载 10 events）。"""
    try:
        ccr = compile_ccr(tmp, "f3_sub", SUB_SRC)
        f3 = _write_fixture(tmp, "f3", V2_F3)
        r = run_bin(COREARCH, [str(ccr), "--elf", "--table", str(f3), "-o", str(tmp / "f3.out")])
    except RuntimeError as e:
        print(f"[FAIL] f3: {e}")
        return False
    out = r.stdout + r.stderr
    if r.returncode != 0 or "hit table loaded: 10 events" not in out:
        print("[FAIL] f3: v2 全字段事件加载失败（期望 10 events 通过）")
        print(out)
        return False
    print("[PASS] f3: v2 全字段解析（prefix/rex/SIB/digit/imm/rel8/cond）加载通过")
    return True


def test_v2_bad_field_rejects(tmp: Path) -> bool:
    """坏文件拒绝面：F1 逐字段注入坏值 → exit 1 + 对应错误消息（值域校验）。"""
    try:
        ccr = compile_ccr(tmp, "badf_sub", SUB_SRC)
    except RuntimeError as e:
        print(f"[FAIL] badf: {e}")
        return False
    variants = [
        # (tag, 旧串, 新串, 期望错误消息, 替换次数)
        ("rex bit", "rex_w = 1", "rex_w = 2", "bad rex bit", 1),
        ("rel kind", 'rel_kind = "event"', 'rel_kind = "bogus"', "bad rel kind", 1),
        ("rel size", "rel_size = 32", "rel_size = 16", "bad rel size", 1),
        ("disp size", "opcode = [0x4C, 0x8B]", 'opcode = [0x4C, 0x8B]\ndisp_size = "wide"',
         "bad disp_size", 1),
        ("opcode count", "opcode = [0x4C, 0x8B]", "opcode = [0x4C, 0x8B, 0x90, 0x90]",
         "opcode >3 bytes", 1),
        ("prefix count", "opcode = [0x4C, 0x89]",
         "opcode = [0x4C, 0x89]\nprefix = [0x66, 0xF2, 0x67]", "prefix >2 bytes", 1),
        ("imm size", "imm_size = 1", "imm_size = 3", "bad imm_size", 1),
        ("reg digit", "modrm_reg_digit = 7", "modrm_reg_digit = 9", "bad reg digit", 1),
        ("side effect", 'side_effect = "pure"', 'side_effect = "weird"', "bad side_effect", 1),
        ("sib mode", "opcode = [0x4C, 0x89]", "opcode = [0x4C, 0x89]\nsib_scale = 1",
         "sib fields need rm_mode 2", 1),
        ("unknown key", 'modrm_reg_role = "dst"', 'modrm_reg_role = "dst"\nmodrm_reg_rol = "dst"',
         "unknown key", 1),
        ("runtime value", 'call_mechanism = "stack"', 'call_mechanism = "heap"',
         "bad call_mechanism", 1),
        ("dup event id", "id = 8", "id = 5", "duplicate event id", 1),
        ("count mismatch", "events = 9", "events = 8", "mismatch", 1),
    ]
    ok = True
    for tag, old, new, token, cnt in variants:
        if V2_FIX.count(old) < cnt:
            print(f"[FAIL] badf/{tag}: anchor {old!r} not found in fixture")
            ok = False
            continue
        p = _write_fixture(tmp, f"badf_{tag.replace(' ', '_')}", V2_FIX.replace(old, new, cnt))
        r = run_bin(COREARCH, [str(ccr), "--elf", "--table", str(p)])
        if r.returncode == 0 or token not in (r.stdout + r.stderr):
            print(f"[FAIL] badf/{tag}: expected exit 1 + {token!r}")
            print("  " + (r.stdout + r.stderr).replace("\n", "\n  ")[:600])
            ok = False
            continue
        print(f"[PASS] badf/{tag}: exit 1 with {token!r}")
    return ok


def test_v2_fixture_multi_step_sections(tmp: Path) -> bool:
    """F4 夹具（Task 1 评审项 1 锁）：单事件 ≥2 proj 且 ≥2 proj 用步小节 →
    加载后逐 proj 步数与逐步归属正确（p0 = 2 步，不得吸收 p1 的 90-93 步）。

    读回通道 = corearch --dump-table（hit_dump_table_state：proj 表记录逐条
    + 每步 v2 字段区 opcode 探针（108B 整条复制后偏移 32 读）+ runtime 槽掩码
    ——评审项 4 的 v2 字段区写读一致实证一并覆盖）。旧缺陷下本测试红：
    ev=10 p0=4（吞并 92/93 两步）+ 额外 'p=0 s=2/3' 步行。"""
    try:
        ccr = compile_ccr(tmp, "f4_sub", SUB_SRC)
        f4 = _write_fixture(tmp, "f4", V2_F4)
        out_p = tmp / "f4_sub_tab"
        r = run_bin(COREARCH, [str(ccr), "--elf", "--table", str(f4),
                               "--dump-table", "-o", str(out_p)])
    except RuntimeError as e:
        print(f"[FAIL] f4: {e}")
        return False
    out = r.stdout + r.stderr
    ok = True

    def chk(cond, msg):
        nonlocal ok
        if not cond:
            print(f"[FAIL] f4: {msg}")
            print("  " + out.replace("\n", "\n  ")[:800])
            ok = False

    chk(r.returncode == 0 and out_p.exists(), "corearch --table <F4> failed")
    chk("hit table loaded: 10 events" in out, "missing 'hit table loaded: 10 events'")
    # proj 步数归属：p0/p1 各 2——旧缺陷 p0 吞并 p1 后 p0=4
    chk("hit proj: ev=10 projs=2 p0=2 p1=2" in out,
        "ev10 proj counts != 'projs=2 p0=2 p1=2'（p0 吸收 p1 步?）")
    # 逐步归属 + v2 字段区读回（opb = opcode 首字节十进制：90→144 … 93→147）
    for tag in ("hit step: ev=10 p=0 s=0 opb=144", "hit step: ev=10 p=0 s=1 opb=145",
                "hit step: ev=10 p=1 s=0 opb=146", "hit step: ev=10 p=1 s=1 opb=147"):
        chk(tag in out, f"missing {tag}")
    chk("hit step: ev=10 p=0 s=2" not in out, "ev10 p0 越界吸收 p1 步（s=2 出现）")
    # 既有形态不受扰：branch（ev6）两步序列 p0=2；runtime 槽位掩码读回
    chk("hit proj: ev=6 projs=1 p0=2" in out, "ev6 branch 步数 != 2")
    chk("hit rt: param_regs=966" in out, "runtime param_regs 读回 != 966（rdi rsi rdx rcx r8 r9）")
    chk("hit rt: save_regs=61448" in out, "runtime save_regs 读回 != 61448（rbx r12-15）")
    if ok:
        print("[PASS] f4: 多 proj 步小节归属正确（p0=2 p1=2 无吸收）+ v2 字段区读回一致")
    return ok


def main():
    if not COREC.exists() or not COREARCH.exists():
        print("[FAIL] missing build/corec or build/corearch (run build_selfhost_native.py first)")
        return 1
    with tempfile.TemporaryDirectory(prefix="hit_t3_") as td:
        tmp = Path(td)
        results = [
            test_run_closure(tmp, "sub", SUB_SRC, SUB_RC, need_lowered=True),
            test_run_closure(tmp, "add", ADD_SRC, ADD_RC, need_lowered=True),
            test_run_closure(tmp, "mem", MEM_SRC, MEM_RC, need_lowered=True),
            # 载体与 test_run_closure 同源；事件流 dump 断言（sub 事件 + 常量池 3 条目）
            test_dump_events(tmp, "dump_add", ADD_SRC, expect_sub_ev=True, expect_nand_ev=False, expect_pool=3),
            test_reject_out_of_subset(tmp),
            test_smoke_files(),
            test_table_load_missing_file(tmp),
            test_table_bad_opcode_range(tmp),
            test_reject_table_with_link_shared(tmp),
            test_dump_sentinel_clean(tmp),
            test_hit_lower_sources_check_clean(),
            # M2a Task 1：schema v2（真实表 walker + v2 夹具 + 坏文件拒绝面）
            test_v2_walker_real_table(),
            test_v2_fixture_load_f1(tmp),
            test_v2_fixture_multi_proj(tmp),
            test_v2_fixture_sink_fields(tmp),
            test_v2_fixture_multi_step_sections(tmp),
            test_v2_bad_field_rejects(tmp),
            # M2a Task 2：事件流注入通道 + v2 形态发射（跳转/disp/imm 逐字节对照）
            test_inject_byte_compare(tmp, "simple", "fn main() -> int {\n    a : ., mut = 7;\n    return a;\n}\n",
                                     ["ev store"], 7),
            test_inject_byte_compare(tmp, "jump", JUMP_SRC, JUMP_EVENTS, JUMP_RC),
            test_inject_byte_compare(tmp, "disp", DISP_SRC, DISP_EVENTS, DISP_RC),
            test_inject_byte_compare(tmp, "bigframe", big_src(), BIG_EVENTS, BIG_RC),
            test_inject_byte_compare(tmp, "imm", IMM_SRC, IMM_EVENTS, IMM_RC,
                                     table=_write_fixture(tmp, "cst_fix", CST_FIX)),
            test_inject_pool_run(tmp),
            test_inject_rejects(tmp),
        ]
    passed = sum(results)
    print(f"{passed}/{len(results)} passed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
