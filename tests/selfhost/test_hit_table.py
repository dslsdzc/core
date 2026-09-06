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
TABLE = BASE / "src" / "arch" / "hit" / "core-x86.toml"
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
    if "hit table loaded: 4 events" not in out:
        print(f"[FAIL] {name}: missing 'hit table loaded: 4 events' in --table output")
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
    """评审项：opcode >255 不得静默截断——表数据值域校验拒绝（exit 1）。"""
    ccr = compile_ccr(tmp, "bad_opcode_tbl", SUB_SRC)
    bad = tmp / "bad_opcode.toml"
    content = TABLE.read_text().replace("[0x4D, 0x29]", "[0x4D, 300]")
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
        ]
    passed = sum(results)
    print(f"{passed}/{len(results)} passed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
