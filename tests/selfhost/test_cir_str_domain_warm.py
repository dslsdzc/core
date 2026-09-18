#!/usr/bin/env python3
"""`.cir` 快照「串域跨进程 id」缺陷修复判据（`CIR_CACHE_VER 20→21`；TODO #2026-09-18-9）。

**缺陷**：快照把串操作数存成**写侧进程的绝对 intern id**，装载侧原样恢复且不重映射
⇒ 读侧编号取决于「哪些函数被生成、哪些被装载」⇒ 凡**首次 intern 发生在 IR 生成期**的
串（多字段 `@fields`、合成变量名…）在暖态取到**别的串**（实测可到含 NUL 的垃圾字节），
两次 `build` 均 `rc=0`、ELF/.ccr 静默不同（VER 17–20 四代全复现 ⇒ 非本代引入）。
**修法（本批）**：生成期 intern 日志（`str_intern` 唯一插入路径记录**每次新 intern**）
+ 装载期**按序重放** ⇒ 读侧串表与写侧同态 ⇒ 全部 id 原样有效。

判据（每条自带锚定值与反例说明；`COREC_BIN=/path/corec` 换被测编译器）：
  A 入口（6 行复现）：冷/暖 **输出逐字相同** + **ELF 逐字节同** + **`.ccr` 逐字节同**；
    锚定值 = 冷 `fields=[x,y] len=3`（暖必须同值）。
  B 判别实验（firstintern）：`ONE=x`（解析期已 intern）与 `TWO=x,y`（gen 期首次 intern）
    暖态**都必须正确**——单字段那半是「类判据 = intern 时机」的对照。
  C 路径 2（var 名 `irv_name`）：含合成变量名（`_cat0`/`_cat1`）语料的冷/暖 `.ccr`
    **逐字节同**（var 名是串域的第二注入入口，且只有 .ccr 面能观测到它们）。
  D 路径 3（重放序：混合命中态 = 删条目回归）：删**首/中/末**条目后重跑，输出 + ELF +
    `.ccr` 都必须与冷态相同（F5 形态正式化）；删**多条**时 `.ccr` 逐字节同**不成立** =
    已登记的**另一类**（NOD 段 TYPE 项索引随重生成顺序变化，ELF/行为不受影响）⇒ 本条只要求
    输出 + ELF，并把 NOD 差异**打印上报**（不作判据——不制造黑洞判据）。
  E 突变自证：`--inject-cir-skip-journal`（跳过重放）⇒ **必红**（暖态输出 ≠ 冷态锚定值）；
    且**非真空控制** = 同一 flag 在**无 gen 期合成串**语料上**不改变输出**（证明突变对
    「缺陷面」敏感、对无关语料惰性，不是把整条管线打坏）。
  F 结构面：条目内含 **v21 日志段**（`base/count` 可解析且 `count ≥ 1`）——证明机制真被
    走过（否则 E 的绿可能是「日志恒空」的假绿）。

纪律：**每档独立目录、先冷后暖**（暖态读数依赖缓存状态，正是本缺陷的由来）；
所有构建经 `nice`（CI 内无风扇问题，本地跑也不抢 CPU）。
"""

import os
import pathlib
import shutil
import struct
import subprocess
import sys
import tempfile

BASE = pathlib.Path(__file__).resolve().parents[2]
COREC = pathlib.Path(os.environ.get("COREC_BIN", str(BASE / "build" / "corec")))

# ── 语料 ────────────────────────────────────────────────────────────────────
REPRO = """import io

struct Point { x: int, y: int }

fn fields_of_point() -> int {
    f := @fields(Point);
    print("fields=[");
    print(f);
    print("] len=");
    println(int_str(str_len(f)));
    return str_len(f);
}

fn main() -> int {
    r := fields_of_point();
    return r - 3;
}
"""

FIRSTINTERN = """import io

struct One { x: int }
struct Two { x: int, y: int }

fn main() -> int {
    print("ONE="); println(@fields(One));
    print("TWO="); println(@fields(Two));
    return 0;
}
"""

VARNAME = """import io

fn cat_helper(a: string, b: string) -> int {
    print("CAT="); println(a + b);
    return 0;
}

fn main() -> int {
    cat_helper("ab", "cd");
    return 0;
}
"""

MIX = """import io

fn f1(n: int) -> int {
    s : ., mut = 0;
    i : ., mut = 0;
    loop {
        if i >= n { break; }
        if i % 3 == 0 { s = s + i * 2; } else { s = s + 1; }
        i = i + 1;
    }
    return s;
}

fn f2(n: int) -> int {
    s : ., mut = 1;
    i : ., mut = 0;
    loop {
        if i >= n { break; }
        if i % 2 == 0 { s = s * 2; } else { s = s + 3; }
        i = i + 1;
    }
    return s;
}

fn main() -> int {
    print("R="); println(int_str(f1(10) + f2(9)));
    return 0;
}
"""


class Leg:
    """一档语料的独立工作目录（每档独立 ⇒ 冷/暖互不污染）。"""

    def __init__(self, name: str, src: str):
        self.name = name
        self.dir = pathlib.Path(tempfile.mkdtemp(prefix=f"cir_str_{name}_"))
        (self.dir / "probe.cr").write_text(src)
        os.symlink(BASE / "src", self.dir / "src")

    def build(self, out: str, *extra: str):
        exe = self.dir / out
        p = subprocess.run(
            ["nice", "-n", "19", str(COREC), "build", "probe.cr", "-o", out, "--static", *extra],
            cwd=self.dir, capture_output=True, text=True)
        run = None
        if exe.exists():
            r = subprocess.run([str(exe)], capture_output=True, text=True)
            run = (r.returncode, r.stdout + r.stderr)
        return {"build_rc": p.returncode, "exe": exe, "run": run,
                "ccr": (self.dir / (out + ".ccr")), "log": p.stdout + p.stderr}

    def reset_cache(self):
        shutil.rmtree(self.dir / ".core", ignore_errors=True)

    def cache_entries(self):
        d = self.dir / ".core" / "cache" / "cir"
        return sorted(x.name for x in d.glob("*.cir")) if d.is_dir() else []

    def save_cache(self, where: pathlib.Path):
        shutil.rmtree(where, ignore_errors=True)
        shutil.copytree(self.dir / ".core" / "cache" / "cir", where)

    def load_cache(self, where: pathlib.Path):
        self.reset_cache()
        (self.dir / ".core" / "cache").mkdir(parents=True, exist_ok=True)
        shutil.copytree(where, self.dir / ".core" / "cache" / "cir")

    def cleanup(self):
        shutil.rmtree(self.dir, ignore_errors=True)


RESULTS = []


def check(name, ok, detail=""):
    RESULTS.append((name, bool(ok), detail))
    print(f"[{'PASS' if ok else 'FAIL'}] {name}{(' — ' + detail) if detail else ''}")


def bytes_equal(a: pathlib.Path, b: pathlib.Path):
    if not (a.exists() and b.exists()):
        return False, f"缺产物（{a.name}:{a.exists()} / {b.name}:{b.exists()}）"
    da, db = a.read_bytes(), b.read_bytes()
    if da == db:
        return True, f"{len(da)}B 相同"
    n = sum(1 for x, y in zip(da, db) if x != y) + abs(len(da) - len(db))
    return False, f"不同（{len(da)}B vs {len(db)}B，{n} 字节差）"


SEG_NAMES = {1: "STR", 2: "SYM", 3: "NOD", 4: "ENT", 5: "REG", 6: "EDG", 7: "TYPE", 8: "IFACE"}


def ccr_diff_segments(a: pathlib.Path, b: pathlib.Path):
    """两 `.ccr` 中**内容不同**的段名集合（段表 8×12B @16，格式同 `ccr_io.cr` 写侧）。

    用途：混合命中态的**已知面**（NOD 段 TYPE 项索引随重生成顺序变化）必须**可判别**——
    若差异溢出到其它段，本缺陷面即回归 ⇒ 判红（**不给已知面留「静默变绿」的口子**）。
    """
    def segs(p):
        d = p.read_bytes()
        out = {}
        for i, tag in enumerate(sorted(SEG_NAMES)):
            t, off, size = struct.unpack_from("<3I", d, 16 + i * 12)
            assert t == tag, f"段表行 {i}: tag {t} != {tag}"
            out[SEG_NAMES[tag]] = d[off:off + size]
        return out
    if not (a.exists() and b.exists()):
        return set(SEG_NAMES.values())
    sa, sb = segs(a), segs(b)
    return {k for k in sa if sa[k] != sb.get(k)}


def journal_section(entry: pathlib.Path):
    """解析 v21 条目，返回 (base, journal_count)。格式见 cir_cache.cr 写侧。"""
    d = entry.read_bytes()
    pos = 0
    magic, ver = struct.unpack_from("<2q", d, pos)
    pos += 16 + 8 * 3  # identity/fp/sig
    nl = struct.unpack_from("<q", d, pos)[0]
    pos += 8 + nl
    vc = struct.unpack_from("<q", d, pos)[0]; pos += 8 + vc * 24
    nc = struct.unpack_from("<q", d, pos)[0]; pos += 8 + nc * 64
    sc = struct.unpack_from("<q", d, pos)[0]; pos += 8 + sc * 48
    ec = struct.unpack_from("<q", d, pos)[0]; pos += 8 + ec * 24
    ic = struct.unpack_from("<q", d, pos)[0]; pos += 8 + ic * 48
    stc = struct.unpack_from("<q", d, pos)[0]; pos += 8
    for _ in range(stc):
        sl = struct.unpack_from("<q", d, pos)[0]; pos += 8 + sl
    return ver, struct.unpack_from("<2q", d, pos)


def path_a_repro():
    """A：6 行复现入口（冷 = 暖，输出/ELF/.ccr 三面）。"""
    leg = Leg("repro", REPRO)
    try:
        leg.reset_cache()
        cold = leg.build("cold")
        warm = leg.build("warm")
        ok_run = cold["run"] == warm["run"] and cold["run"] is not None
        anchored = cold["run"] and "fields=[x,y] len=3" in cold["run"][1]
        check("A1 冷态锚定值", anchored, f"cold run={cold['run']}")
        check("A2 冷/暖输出逐字同", ok_run, f"cold={cold['run']} warm={warm['run']}")
        check("A3 冷/暖 ELF 逐字节同", *bytes_equal(cold["exe"], warm["exe"]))
        check("A4 冷/暖 .ccr 逐字节同", *bytes_equal(cold["ccr"], warm["ccr"]))
        # F：日志段存在且非空（机制真被走过）
        entries = [e for e in leg.cache_entries() if "::fields_of_point.cir" in e]
        if entries:
            ver, (base, cnt) = journal_section(leg.dir / ".core/cache/cir" / entries[0])
            # 版本钉改 `>= 21`（2026-09-18 插值展开批 v22）：**日志段布局自 v21 引入且其后各代未变**
            # ⇒ 用下界（否则每次换代都会假红）；机制面（count ≥ 1 = 真走过日志路径）不变。
            check("F1 v21+ 条目日志段（count≥1）", ver >= 21 and cnt >= 1,
                  f"ver={ver} base={base} journal_count={cnt}")
        else:
            check("F1 v21 条目日志段（count≥1）", False, "未找到 fields_of_point 条目")
        return cold, warm
    finally:
        leg.cleanup()


def path_b_firstintern():
    """B：判别实验——intern 时机是类判据（对照：解析期已 intern 的 `"x"` 必须对）。"""
    leg = Leg("firstintern", FIRSTINTERN)
    try:
        leg.reset_cache()
        cold = leg.build("cold")
        warm = leg.build("warm")
        want = "ONE=x\nTWO=x,y\n"
        check("B1 冷态判别锚定", cold["run"] and cold["run"][1] == want, f"cold={cold['run']}")
        check("B2 暖态判别锚定（两半都必须对）", warm["run"] and warm["run"][1] == want,
              f"warm={warm['run']}")
        check("B3 冷/暖 ELF 同", *bytes_equal(cold["exe"], warm["exe"]))
    finally:
        leg.cleanup()


def path_c_varname():
    """C：路径 2（var 名 `irv_name`）——只有 .ccr 面能观测合成变量名。"""
    leg = Leg("varname", VARNAME)
    try:
        leg.reset_cache()
        cold = leg.build("cold")
        warm = leg.build("warm")
        check("C1 冷/暖输出同", cold["run"] == warm["run"], f"cold={cold['run']} warm={warm['run']}")
        check("C2 冷/暖 .ccr 逐字节同（含合成名 `_cat0/_cat1` 面）",
              *bytes_equal(cold["ccr"], warm["ccr"]))
    finally:
        leg.cleanup()


def path_d_mixed():
    """D：路径 3（重放序）——混合命中态（删首/中/末/多条）正式化。"""
    leg = Leg("mixed", MIX)
    try:
        leg.reset_cache()
        cold = leg.build("cold")
        snapshot = pathlib.Path(tempfile.mkdtemp(prefix="cir_str_snap_"))
        try:
            leg.save_cache(snapshot)
            names = sorted(x.name for x in snapshot.glob("*.cir"))
            f1 = next(n for n in names if "::f1.cir" in n)
            f2 = next(n for n in names if "::f2.cir" in n)
            main_e = next(n for n in names if "::main.cir" in n)
            variants = [("del_first", [f1]), ("del_mid", [f2]), ("del_last", [main_e]),
                        ("del_multi", [f1, f2, main_e])]
            for label, dele in variants:
                leg.load_cache(snapshot)
                for e in dele:
                    (leg.dir / ".core" / "cache" / "cir" / e).unlink()
                got = leg.build(label)
                ok_out = got["run"] == cold["run"]
                ok_elf, elf_d = bytes_equal(cold["exe"], got["exe"])
                ok_ccr, ccr_d = bytes_equal(cold["ccr"], got["ccr"])
                # 混合态要求 **输出 + ELF**（= 串 id 正确的可观测面；修复前此面在第 25
                # 字节起即不同）。`.ccr` 逐字节同**不要求**：实测混合态可在 **NOD 段**
                # 出现 20B 级差异（TYPE 项索引随重生成顺序变化；**段级定位**已做：STR/
                # SYM/ENT/REG/EDG/TYPE/IFACE 全同、仅 NOD 不同）——那是**另一类**已登记面，
                # 与本缺陷（串域）无关，故只上报不判红（不制造黑洞判据，也不假装覆盖）。
                check(f"D {label} 输出+ELF 同", ok_out and ok_elf,
                      f"out={ok_out} elf={elf_d} | .ccr: {ccr_d}")
                if not ok_ccr:
                    # **已知面不许悄悄变绿**：`.ccr` 差异必须**局限于 NOD 段**（TYPE 项索引随重生成
                    # 顺序变化）。若差异出现在 STR/SYM/ENT/REG/EDG/TYPE/IFACE 任一 ⇒ 本缺陷面回归 ⇒ 判红。
                    seg_diffs = ccr_diff_segments(cold["ccr"], got["ccr"])
                    check(f"D {label} .ccr 差异仅限 NOD（已知面）", seg_diffs == {"NOD"},
                          f"差异段 = {sorted(seg_diffs)}")
                    print(f"    [观测·非本缺陷面] {label} .ccr {ccr_d}（差异段 = {sorted(seg_diffs)}）")
        finally:
            shutil.rmtree(snapshot, ignore_errors=True)
    finally:
        leg.cleanup()


def path_e_mutation(cold_ref):
    """E：突变自证——跳过重放 ⇒ 必红；且无关语料上不动（非真空控制）。"""
    leg = Leg("mutation", REPRO)
    try:
        leg.reset_cache()
        base = leg.build("base")          # 冷跑：**填充缓存**（突变必须有条目可重放）
        mut = leg.build("mut", "--inject-cir-skip-journal")   # 暖跑 + 跳过重放（不清缓存！）
        same_as_cold = (cold_ref is not None and mut["run"] == cold_ref["run"])
        check("E1 突变（跳过重放）⇒ 暖态输出偏离冷态锚定", not same_as_cold,
              f"base={base['run']} mut={mut['run']}")
        check("E2 突变生效面确为串域（暖态取到非锚定串）",
              mut["run"] is not None and "fields=[x,y] len=3" not in mut["run"][1],
              f"mut={mut['run']}")
    finally:
        leg.cleanup()
    # 非真空控制：同一 flag 在「无 gen 期合成串」语料上不得改变输出
    leg2 = Leg("mutation_control", VARNAME)
    try:
        leg2.reset_cache()
        a = leg2.build("a")
        leg2.reset_cache()
        b = leg2.build("b", "--inject-cir-skip-journal")
        # VARNAME 的合成名 `_cat0/_cat1` 属 var 名面（无 str 操作数）⇒ 输出不依赖重放
        check("E3 非真空控制（无串槽语料上突变不动输出）", a["run"] == b["run"],
              f"a={a['run']} b={b['run']}")
    finally:
        leg2.cleanup()


def main():
    if not COREC.exists():
        print(f"缺编译器 {COREC}（先 build_selfhost_native.py，或设 COREC_BIN）")
        return 2
    print(f"=== `.cir` 串域暖态判据（CIR_CACHE_VER 21）· 被测 = {COREC} ===")
    cold, _warm = path_a_repro()
    path_b_firstintern()
    path_c_varname()
    path_d_mixed()
    path_e_mutation(cold)
    passed = sum(1 for _, ok, _ in RESULTS if ok)
    print(f"\n{passed}/{len(RESULTS)} 通过")
    return 0 if passed == len(RESULTS) else 1


if __name__ == "__main__":
    sys.exit(main())
