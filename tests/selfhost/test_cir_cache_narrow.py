#!/usr/bin/env python3
"""缓存膨胀批（`plans/2026-09-17-cir-cache-bloat.md` / `CIR_CACHE_VER 19→20`）判据：

    P1 结构性（体积 ∝ 本函数规模，不 ∝ 程序规模）
    P2 部分 rebuild 正确性（只改一个函数、其余命中 ⇒ 图仍正确）——**承重件**
    P4 健壮性（截断/短文件 ⇒ fail-closed miss，绝不 139/垃圾）——**承重件**

背景（T0/T1 实测，数字见计划 §1.2/§1.5）：修复前每个函数快照携带**全图边表**（单条 2.38MB 中
98.6% 是别的函数的边；全档 97.0% 的缓存字节是边记录）⇒ 全缓存 O(函数数 × 累计图)。修复后只写
本函数边（24B/条、相对 node_start 的有符号偏移）+ 尾部 16B 基线见证 trailer。

突变控制（**必须真红**，否则判据无效；手工执行，配方如下）：
    M1a（P1 必红）：把 `save_cir_cache` 的边段写回全图（`own_edge_count` → `g_df_edge_count`，
        `rel` → 绝对 id）⇒ `P1` 的「tiny 条目 ≤ 4096B」必红。
    M1b（P2 必红）：装载侧把相对 id 映射去掉（`df_add_edge_kind(rel_from, rel_to, ...)` 直接当绝对用）
        ⇒ `P2a` 的「段级同冷态」必红（陈旧节点 id）。
    M1c（P4 必红）：去掉装载侧 `dlen < 64` 与「trailer 须落在扫描终点之后」两条守卫 ⇒ `P4` 必红
        （截断文件读出垃圾/越界 ⇒ 139 或错产物）。
    M1c′（P4 必红·**实测有效**）：把「结构性失败 ⇒ `return -1`（miss）」改成「**静默接受**（`return 0`）」
        ⇒ P4 在 `truncate→56B` 即红（图段 [3,4,5,6] 与冷态不同）。
    ⚠ 实测登记：**弱化**那两条守卫（`dlen<64`→`<8`、`p+16!=dlen`→`>dlen+64`）**并未**使 P4 红
        （段界检 + trailer var_start + 逐节点见证 + 指纹/身份检仍判 miss）⇒ 该两条属**冗余层**，
        承重层是「拒绝即 miss」语义本身（由 M1c′ 证明）。
    注：**尾随字节容忍是既有契约**（`test_cir_warm_path` D5：补零条目仍须命中）⇒ trailer 定位于
    **扫描终点**而非 `dlen−16`；P4 只钉「截断（p+16 > dlen）⇒ miss」。
    ⚠ 每次突变需重建编译器（`nice -n 19 python3 build_selfhost_native.py`）；突变只为自证判据有牙，
    **不得**与修复提交混在一起。

用法：`python3 tests/selfhost/test_cir_cache_narrow.py`（cwd 任意；缓存/import 解析在仓根）。
    `COREC_BIN=/path/to/corec` 换被测编译器。
"""

import os
import pathlib
import shutil
import struct
import subprocess

BASE = pathlib.Path(__file__).resolve().parents[2]
COREC = pathlib.Path(os.environ.get("COREC_BIN", str(BASE / "build" / "corec")))
CACHE_DIR = BASE / ".core" / "cache" / "cir"
WORK = BASE / "build" / "t2"                     # 定路径夹具目录（gitignored）
WORK.mkdir(parents=True, exist_ok=True)

# ── 夹具：N 个「大」函数（累计图大）+ 末尾一个「极小」函数（P1 的被测面）──────────
N_BIG = 24
STMTS = 24


def many_fn_src(node_delta: bool = False, extra_var: bool = False) -> str:
    """夹具生成器（**只改 f0**，其余函数逐字节不变）。

    node_delta=True  ⇒ 只把 f0 第 4 句 RHS 变长（`x3 * 2 + 3` → `x3 * 2 + 3 + a`）：
                       **节点数 +1、变量数不变** ⇒ 其后函数的 var 基线**不变**（仍命中）、
                       节点基线**平移**（P2a 的被测面）。
    extra_var=True   ⇒ 给 f0 加一个新变量 xv（变量数 +1）⇒ 其后函数 var 基线**变化**
                       （P2b 的被测面：条件见证 ⇒ fail-closed miss）。
    """
    out = ["// cache-narrow fixture (tests/selfhost/test_cir_cache_narrow.py)"]
    for i in range(N_BIG):
        body = []
        body.append(f"    x0 := a + {i};")
        for j in range(STMTS):
            if i == 0 and j == 5 and extra_var:
                body.append("    xv := x0 + 7;")
            nxt = "xv" if (i == 0 and extra_var and j >= 5) else f"x{j}"
            if i == 0 and j == 3 and node_delta:
                # 同一 dest（x4）、只多一个参与 `a` 的二元节点（不可被常量折叠掉）
                body.append(f"    x{j + 1} := {nxt} * 2 + {j % 7} + a;")
            else:
                body.append(f"    x{j + 1} := {nxt} * 2 + {j % 7};")
        body.append(f"    return x{STMTS};")
        out.append(f"fn f{i}(a: int) -> int {{")
        out.extend(body)
        out.append("}")
    # 极小函数：自身节点/边极少（P1 的被测面）
    out.append("fn tiny(a: int) -> int { return a + 1; }")
    out.append("fn main() -> int { return tiny(41); }")
    return "\n".join(out) + "\n"


def write_fixture(name: str, src: str) -> pathlib.Path:
    p = WORK / name
    p.write_text(src)
    return p


def clean_cache():
    shutil.rmtree(CACHE_DIR, ignore_errors=True)


def run_ccr(src: pathlib.Path, out: pathlib.Path):
    """跑 ccr；返回 (rc, stdout+stderr)。cwd = 仓根（import 解析与 .core 缓存均相对 cwd）。"""
    r = subprocess.run([str(COREC), "ccr", str(src.relative_to(BASE)), "-o", str(out)],
                       cwd=str(BASE), capture_output=True, text=True, timeout=900)
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def entry_of(src: pathlib.Path, fn: str) -> pathlib.Path:
    key = str(src.relative_to(BASE)).replace("/", "_")
    return CACHE_DIR / f"{key}::{fn}.cir"


def sha(p: pathlib.Path) -> str:
    return __import__("hashlib").sha256(p.read_bytes()).hexdigest()


def segs(p: pathlib.Path):
    """解析 .ccr 段表 → {tag: bytes}（口径：段表 = 8 段，tag 1..8；见 test_ccr_v7.py）。"""
    d = p.read_bytes()
    n = struct.unpack_from("<I", d, 8)[0]
    out = {}
    for i in range(n):
        tag, off, size = struct.unpack_from("<3I", d, 16 + i * 12)
        out[tag] = d[off:off + size]
    return out


# ═══════════════ P1：结构性（体积 ∝ 本函数规模）═══════════════

def test_p1_tiny_entry_bounded():
    """P1：大累计图语料里，**极小函数**的条目尺寸必须有界（修复前 = 全图边表 ⇒ 与程序规模同阶）。

    非空转保证：① 条目数 ≥ N_BIG；② **最大条目 ≥ 10 × tiny 条目**（证明语料确有「大累计图」，
    tiny 的「小」不是因为所有条目都小）。"""
    src = write_fixture("p1_many.cr", many_fn_src())
    clean_cache()
    rc, log = run_ccr(src, WORK / "p1.ccr")
    assert rc == 0, f"ccr rc={rc}\n{log[-800:]}"
    entries = sorted(CACHE_DIR.glob("*.cir"))
    assert len(entries) >= N_BIG, f"non-vacuous: only {len(entries)} entries"
    tiny = entry_of(src, "tiny")
    assert tiny.exists(), "tiny entry missing"
    tsz = tiny.stat().st_size
    big = max(e.stat().st_size for e in entries)
    assert tsz <= 4096, f"P1 RED: tiny entry {tsz}B > 4096B（收窄未生效？）"
    assert big >= 10 * tsz, f"non-vacuous: big={big}B tiny={tsz}B（语料未形成「大累计图」）"
    print(f"  [P1] tiny={tsz}B max={big}B ({big // max(tsz,1)}x) entries={len(entries)}")


# ═══════════════ P2：部分 rebuild 正确性（承重件）═══════════════

def _partial_vs_cold(name: str, src_v1: str, src_v2: str, tag: str):
    """**同一路径**先写 v1 建缓存，再覆写为 v2 跑（部分命中）⇒ 与 v2 冷跑对拍。

    ⚠ 关键：缓存键 = `源路径::函数名` ⇒ v1/v2 **必须同路径**，否则两轮条目互不相干、
    判据空转（本用例首版即栽在此处：hits=41/misses=0 的假绿）。
    """
    path = WORK / name
    path.write_text(src_v1)
    clean_cache()
    rc1, l1 = run_ccr(path, WORK / f"{tag}_v1.ccr")
    assert rc1 == 0, f"v1 rc={rc1}\n{l1[-500:]}"
    before = {e.name: (e.stat().st_size, e.stat().st_mtime_ns) for e in CACHE_DIR.glob("*.cir")}
    path.write_text(src_v2)          # 同路径覆写 ⇒ 键不变、指纹变
    rc2, l2 = run_ccr(path, WORK / f"{tag}_partial.ccr")
    assert rc2 == 0, f"partial rc={rc2}（不得 139）\n{l2[-500:]}"
    assert "SIGSEGV" not in l2, "partial run crashed"
    after = {e.name: (e.stat().st_size, e.stat().st_mtime_ns) for e in CACHE_DIR.glob("*.cir")}
    hits = [n for n, v in before.items() if n in after and after[n] == v]
    misses = [n for n, v in before.items() if n in after and after[n] != v]
    clean_cache()
    rc3, l3 = run_ccr(path, WORK / f"{tag}_cold.ccr")
    assert rc3 == 0, f"cold rc={rc3}\n{l3[-500:]}"
    sa, sb = segs(WORK / f"{tag}_partial.ccr"), segs(WORK / f"{tag}_cold.ccr")
    # STR(1)/SYM(2) 段不参与对拍：暖态不重放 ir_gen 期临时串的 intern ⇒ 该两段冷≠暖是**预存**口径
    # （TODO #2026-09-11-9）。**对照实证（本批）**：同一夹具同一「冷跑 → 截断 → 再跑」场景下，
    # **修复前二进制**给出**逐段相同**的差异签名（STR 2003→1933、SYM 同尺寸异内容；图段全同）
    # ⇒ 非本批引入。本判据只钉**图面**（NOD/ENT/REG/EDG/TYPE/IFACE）。
    diff = [t for t in sa if t not in (1, 2) and sa[t] != sb.get(t)]
    return hits, misses, diff


def test_p2a_partial_rebuild_after_node_delta():
    """P2a（**承重件**）：改**一个**函数（f0）使其**节点数变** ⇒ 其后函数条目按 **var 基线恒校验
    fail-closed 全 miss**（不静默），且产物**图面与冷跑逐段同**。

    **实测校正（本用例首版的设计假设被自己证伪）**：原设计假定「节点数变、var 数不变 ⇒ 其后函数
    仍命中、只节点基线平移」——实测**不可由单函数编辑构造**：任何表达式增删都伴随 temp var
    （本夹具 f0：node 152→153 时 var 125→126）⇒ var 基线**同步平移**、被恒校验拦下
    （trailer 实证：f1 的 `var_start_w` 145→146、`node_start_w` 152→153）。
    ⇒ **活跃拦截者 = `var_start` 恒校验**；相对 id 是**纵深防御**（在「var 基线对齐而节点基线平移」
    的场合仍正确——该形态当前不可构造，故以 P2c 的命中保真判据间接覆盖恢复面）。
    """
    hits, misses, diff = _partial_vs_cold("p2a.cr", many_fn_src(),
                                          many_fn_src(node_delta=True), "p2a")
    assert not diff, f"P2a RED: 图段 {diff} 与冷态不同"
    assert len(misses) >= 5, f"P2a: 期望 var 基线平移 ⇒ 其后条目 fail-closed 重写；实测 misses={len(misses)}"
    print(f"  [P2a] node-delta: hits={len(hits)} misses={len(misses)} graph-segments-identical(excl STR/SYM)")


def test_p2b_partial_rebuild_after_var_delta():
    """P2b（**承重件**）：改一个函数使其 **var 数变** ⇒ 其后函数 var 基线与写者不同 ⇒
    **恒校验 fail-closed**（全部 miss，不静默）——判据 = ① 图面仍与冷态逐段同；
    ② 后续条目**被重写**（确为 miss，而非碰巧同态）。"""
    hits, misses, diff = _partial_vs_cold("p2b.cr", many_fn_src(),
                                          many_fn_src(extra_var=True), "p2b")
    assert not diff, f"P2b RED: 图段 {diff} 与冷态不同"
    assert len(misses) >= 5, f"P2b: 期望 var 基线变化 ⇒ 后续条目重写；实测 misses={len(misses)}"
    print(f"  [P2b] var-delta: hits={len(hits)} misses={len(misses)} graph-segments-identical(excl STR/SYM)")


def test_p2c_hit_path_rebuild_fidelity():
    """P2c（**承重件·命中恢复保真**）：v1 冷跑建条目 ⇒ **同源再跑（全命中）**⇒ 恢复出的图必须与冷跑
    **逐段相同**（NOD/ENT/REG/EDG/TYPE/IFACE）。

    这一条直接钉**装载期链重建**（本批新写点）：`first_edge/edge_count` 归零后由 df_add_edge_kind
    按写者序前插重放，任何**序错/漏边/多边**都会让 EDG/NOD 段与冷跑分叉。"""
    path = WORK / "p2c.cr"
    path.write_text(many_fn_src())
    clean_cache()
    rc1, l1 = run_ccr(path, WORK / "p2c_cold.ccr")
    assert rc1 == 0, f"cold rc={rc1}\n{l1[-400:]}"
    before = {e.name: (e.stat().st_size, e.stat().st_mtime_ns) for e in CACHE_DIR.glob("*.cir")}
    rc2, l2 = run_ccr(path, WORK / "p2c_warm.ccr")
    assert rc2 == 0, f"warm rc={rc2}\n{l2[-400:]}"
    after = {e.name: (e.stat().st_size, e.stat().st_mtime_ns) for e in CACHE_DIR.glob("*.cir")}
    hits = [n for n in before if n in after and before[n] == after[n]]
    assert len(hits) >= 5, f"non-vacuous: 真命中仅 {len(hits)} 条（命中路径未走到）"
    sa, sb = segs(WORK / "p2c_warm.ccr"), segs(WORK / "p2c_cold.ccr")
    gdiff = [t for t in sa if t not in (1, 2) and sa[t] != sb.get(t)]
    assert not gdiff, f"P2c RED: 命中恢复的图段 {gdiff} 与冷跑不同（链重建保真被破）"
    print(f"  [P2c] hits={len(hits)}/{len(before)} 图段与冷跑相同（链重建保真）")


# ═══════════════ P4：截断/短文件 ⇒ fail-closed miss（承重件）═══════════════

def test_p4_truncated_entries_fail_closed():
    """P4（**承重件**）：把合法条目 `truncate` 成各种长度（含 < 头长、恰缺 trailer、trailer 半截、
    载荷中途截断、空文件）⇒ 装载侧必须 **miss 并重建**：rc=0、无 139、**图段（NOD/ENT/REG/EDG/
    TYPE/IFACE）与冷跑逐段同**（STR/SYM 属预存暖态串面口径，不参与本判据）。

    逐轮：先由保存的完好副本重铺条目 → 截断 → 跑 → 断言。修复前/突变 M1c 下 ⇒ 139 或错产物。"""
    src = write_fixture("p4.cr", many_fn_src())
    clean_cache()
    rc, log = run_ccr(src, WORK / "p4_cold.ccr")
    assert rc == 0, f"cold rc={rc}\n{log[-400:]}"
    cold = (WORK / "p4_cold.ccr").read_bytes()
    assert len(cold) > 0, "non-vacuous: empty cold product"
    ent = entry_of(src, "main")
    assert ent.exists(), "main entry missing"
    good = ent.read_bytes()
    lengths = [0, 1, 8, 47, 48, 55, 56, 63, 64, 65, len(good) - 17, len(good) - 16,
               len(good) - 15, len(good) - 8, len(good) - 1, len(good) // 2]
    checked = 0
    for L in sorted(set(x for x in lengths if 0 <= x <= len(good))):
        ent.write_bytes(good[:L])
        rc2, log2 = run_ccr(src, WORK / "p4.out.ccr")
        assert rc2 == 0, f"truncate→{L}B: rc={rc2}（不得 139/非零）\n{log2[-400:]}"
        sa, sb = segs(WORK / "p4.out.ccr"), segs(WORK / "p4_cold.ccr")
        # 图面（NOD/ENT/REG/EDG/TYPE/IFACE）必须逐段同；STR(1)/SYM(2) 属**预存**暖态串面口径
        # （本轮以修复前二进制对照实测同签名；见 _partial_vs_cold 同注），不参与本判据。
        gdiff = [t for t in sa if t not in (1, 2) and sa[t] != sb.get(t)]
        assert not gdiff, f"truncate→{L}B: 图段 {gdiff} 与冷态不同（装载吃进半份载荷？）"
        assert ent.stat().st_size == len(good), f"truncate→{L}B: 条目未被重建（未走到 miss？）"
        checked += 1
    print(f"  [P4] {checked} 种截断长度全部 rc=0 + 图段同冷 + 条目重建")


TESTS = [
    ("P1 极小条目有界", test_p1_tiny_entry_bounded),
    ("P2a 部分 rebuild fail-closed + 图同冷", test_p2a_partial_rebuild_after_node_delta),
    ("P2c 命中恢复保真（链重建）", test_p2c_hit_path_rebuild_fidelity),
    ("P2b var 基线变化 fail-closed", test_p2b_partial_rebuild_after_var_delta),
    ("P4 截断 fail-closed", test_p4_truncated_entries_fail_closed),
]


def main() -> int:
    ok = 0
    fail = []
    for name, fn in TESTS:
        try:
            fn()
            ok += 1
            print(f"PASS {name}")
        except AssertionError as e:
            fail.append((name, str(e)))
            print(f"FAIL {name}: {e}")
        finally:
            clean_cache()
    print(f"\n{ok}/{len(TESTS)} PASS")
    if fail:
        print("FAILURES:")
        for n, e in fail:
            print(f"  - {n}: {e.splitlines()[0]}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
