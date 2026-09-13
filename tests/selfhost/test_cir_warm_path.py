#!/usr/bin/env python3
"""R2 P5 Task 1 回归：`.cir` 快照暖态 SIGSEGV 根因修复（装载读缓冲累计 ⇒ 堆耗尽 ⇒ NULL ⇒ str_len 解引用）。

RED（修复前 = P5 起点基线 `/tmp/p5t0/base/corec`，同病；P4 T5 §7-5 首次登记）：
    `corec build src/compiler/main.cr -O 0`  冷态 rc=0 / **暖态 rc=139**
    gdb: #0 load64(rdi=0, rsi=-8) ← #1 str_len ← #2 load_cir_cache
根因链（本任务实测；数字见 `.superpowers/sdd/p5-task1-report.md`）：
    ① 装载侧逐函数 `read_file` = `alloc(fsize+1)`，而 bump 分配器（rt.s `alloc`）**不回收**
       ⇒ 各函数读缓冲**累计驻留**（本单根因：瞬态载荷驻留于无回收分配器）
    ② 单文件尺寸是 O(程序) 而非 O(函数)：快照含**全程序边表** + 全程序字符串表
       （实测 `nod_s3`（13 节点函数）条目 2595772B，其中 98.7% = 80100 条全程序边 ×32B）
       ⇒ 946 个快照共 1.1674GiB（1,253,453,548B）> 1GiB 堆（rt.s `heap_start: .space 1024*1024*1024`）
    ③ `alloc` 耗尽返回 0（`.Lalloc_oom`）⇒ `read_file` 把 0 当 string 返回
    ④ `load_cir_cache` 首行 `str_len(0)` → `load64(0, -8)` = SIGSEGV（冷态不读快照故 rc=0）
修复（`src/compiler/cir_cache.cr::cir_read_snapshot`）：快照内容对装载是**瞬态**的
    ⇒ **单一复用缓冲**（峰值 = 最大单文件尺寸，而非全体累计）；open 失败/空文件/短读/
    缓冲不可得 ⇒ -1 = cache miss（三态纪律：载入失败 ⇒ 拒绝，不得静默当空表）。

判据（19 例；`COREC_WARM_SELF=1` 另开 2 例自源语料 ⇒ 共 21 例）：
    A 冷/暖判据（base 探针）7 例：rc 双 0 · 条目已落盘 · ELF 逐字节同 ·
      `.ccr` **段级契约**（SYM..IFACE 七段冷=暖；STR 段冷≠暖为**预存**口径——
      P4 T1 用例已钉：暖态不重放 ir_gen 临时名的 intern ⇒ STR 表更短）·
      暖态**真命中**（条目 size+mtime 不变）· 再暖确定性
    B 变体 4 例：多串 / 0 串 / 大串（4KB 字面量）/ 多函数（24 函数）
    C 可选程序 2 例：两跑产物同 + 缓存关（零条目——本修复不牵动可选面）
    D **累计装载复现例**（本单 RED 的廉价复现；不依赖自源语料）6 例：
      400 条目补零至 3MB（Σ=1.2GB > 1GB 堆）⇒ 暖态 rc=0 · 产物同冷态 ·
      补零条目仍为命中（未被重写）· 暖态峰值 RSS < 512MB（直接钉「不累计」性质；
      堆上限若日后上调，rc 判据会真空通过而 RSS 判据仍能抓住累计回归）
    E 自源暖态（真·红态语料，`COREC_WARM_SELF=1`）2 例

用法：`python3 tests/selfhost/test_cir_warm_path.py`（cwd 任意；缓存与 import 解析均在仓根）。
    `COREC_BIN=/path/to/corec` 换被测编译器（RED 对照用冻结基线）；
    `COREC_WARM_SELF=1` 追加自源语料冷/暖跑（~3 分钟，缺省关闭以保 CI 时长）。
"""

import hashlib
import os
import pathlib
import shutil
import struct
import subprocess
import tempfile

BASE = pathlib.Path(__file__).resolve().parents[2]
COREC = pathlib.Path(os.environ.get("COREC_BIN", str(BASE / "build" / "corec")))
CACHE_DIR = BASE / ".core" / "cache" / "cir"

# ── 探针源（无 import、无泛型、无可选 ⇒ 缓存全开）──────────────────────────
BASE_PROBE = """// warm-path probe (tests/selfhost/test_cir_warm_path.py)
fn add(a: int, b: int) -> int {
    return a + b;
}

fn scale(x: int) -> int {
    return x * 3;
}

fn pick(i: int) -> string {
    if i > 0 { return "alpha"; }
    if i > 1 { return "beta"; }
    return "gamma";
}

fn main() -> int {
    s : ., mut = add(1, 2);
    s = s + scale(4);
    t := pick(0);
    return s;
}
"""

ZERO_STR_PROBE = """// warm-path probe: 无字符串常量
fn twice(x: int) -> int {
    return x * 2;
}

fn main() -> int {
    a : ., mut = 0;
    i : ., mut = 1;
    loop {
        if i > 8 { break; }
        a = a + twice(i);
        i = i + 1;
    }
    return a;
}
"""

BIG_STR_PROBE = """// warm-path probe: 大字符串字面量（4KB）
fn big() -> string {
    s := "%s";
    return s;
}

fn main() -> int {
    t := big();
    return 42;
}
""" % ("A" * 4096)


def many_funcs_probe(n: int) -> str:
    parts = ["// warm-path probe: %d 函数" % n]
    for i in range(n):
        parts.append("fn f%d(x: int) -> int { return x + %d; }" % (i, i))
    parts.append("fn main() -> int { return f0(0) + f1(1) + f2(2); }")
    return "\n".join(parts) + "\n"


OPTIONAL_PROBE = """// warm-path probe: 可选程序（表示面启用 ⇒ .cir 缓存关闭）
fn g() -> int? { return Some(1); }

fn main() -> int {
    x : int? = 5;
    y := g();
    return match x { Some(v) => v, None => 0, };
}
"""

PAD_FUNCS = 400
PAD_BYTES = 3 * 1024 * 1024          # 每条目补零到 3MB ⇒ Σ = 1.2GB > 1GB 堆
RSS_BOUND_KB = 512 * 1024            # 暖态峰值 RSS 上限（证「读缓冲不累计」）


def entry_key(src: pathlib.Path) -> str:
    return str(src).replace("/", "_")


def probe_entries(src) -> list:
    return sorted(CACHE_DIR.glob(f"{entry_key(pathlib.Path(src))}::*.cir"))


def clean_entries(src):
    for p in probe_entries(src):
        try:
            p.unlink()
        except FileNotFoundError:
            pass


def run_corec(args, timeout=1800):
    """跑被测编译器（cwd=仓根：import 解析与 .core/cache 都在仓根）。"""
    r = subprocess.run([str(COREC), *args], capture_output=True, text=True,
                       cwd=BASE, timeout=timeout)
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def run_corec_rss(args, timeout=1800):
    """同 run_corec，另回该子进程峰值 RSS（KB）。os.wait4 ⇒ 只算本进程，不受先跑子进程污染。"""
    out_path = tempfile.mktemp(prefix="core_warm_rss_")
    try:
        with open(out_path, "w") as fh:
            p = subprocess.Popen([str(COREC), *args], stdout=fh,
                                 stderr=subprocess.STDOUT, cwd=BASE)
            _pid, status, ru = os.wait4(p.pid, 0)
            p.returncode = os.waitstatus_to_exitcode(status)
        return p.returncode, open(out_path).read(), ru.ru_maxrss
    finally:
        try:
            os.unlink(out_path)
        except FileNotFoundError:
            pass


def entry_stamp(p: pathlib.Path):
    st = p.stat()
    return (st.st_size, st.st_mtime_ns)


# ── `.ccr` 段级判据 ────────────────────────────────────────────────────────
# 冷/暖**全文件**逐字节同**不成立**且**预存**（P4 T1 用例已定口径：`STR` 段
# 冷=1811B / 暖=1703B——暖态不重放 ir_gen 临时名（`_eq0`/`bin` 等）的 intern ⇒
# STR 表更短；其余七段逐字节同）。本套件因此钉**段级契约**：SYM/NOD/ENT/REG/
# EDG/TYPE/IFACE 必须冷=暖，STR 只登记尺寸（真产物 = ELF，恒逐字节同）。
SEG_NAMES = {1: "STR", 2: "SYM", 3: "NOD", 4: "ENT", 5: "REG",
             6: "EDG", 7: "TYPE", 8: "IFACE"}
CONTRACT_TAGS = (2, 3, 4, 5, 6, 7, 8)


def ccr_segments(path: pathlib.Path):
    d = pathlib.Path(path).read_bytes()
    segs = {}
    for i, tag in enumerate(sorted(SEG_NAMES)):
        t, off, size = struct.unpack_from("<3I", d, 16 + i * 12)
        assert t == tag, f"segment table row {i}: tag {t} != {tag}"
        segs[tag] = d[off:off + size]
    return segs


def ccr_contract_equal(cold_path: pathlib.Path, warm_path: pathlib.Path):
    a, b = ccr_segments(cold_path), ccr_segments(warm_path)
    bad = [SEG_NAMES[t] for t in CONTRACT_TAGS if a[t] != b[t]]
    detail = (f"STR {len(a[1])}B→{len(b[1])}B（预存口径，不入判据）；"
              + ("其余七段逐字节同" if not bad else "契约段异: " + ",".join(bad)))
    return (not bad), detail


def sha16(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()[:16]


def main():
    failures = []
    checks = 0

    def check(name, cond, detail=""):
        nonlocal checks
        checks += 1
        print(f"[{'PASS' if cond else 'FAIL'}] {name}{(' — ' + detail) if detail else ''}")
        if not cond:
            failures.append(name)

    if not COREC.exists():
        print(f"[FAIL] 缺被测编译器 {COREC}（先跑 build_selfhost_native.py）")
        return 1

    tmpdir = pathlib.Path(tempfile.mkdtemp(prefix="core_warm_"))
    probes = []

    def write_probe(name: str, text: str) -> pathlib.Path:
        p = tmpdir / name
        p.write_text(text)
        probes.append(p)
        return p

    try:
        # ── A：base 探针 冷/暖判据 ────────────────────────────────────────
        src_a = write_probe("base.cr", BASE_PROBE)
        out_cold, out_warm = tmpdir / "base_cold", tmpdir / "base_warm"
        clean_entries(src_a)
        rc_c, log_c = run_corec(["build", str(src_a), "-o", str(out_cold), "--static"])
        check("A1_cold_rc0", rc_c == 0, f"rc={rc_c}")
        if rc_c != 0:
            print(log_c[-2000:])
            return 1
        entries_a = probe_entries(src_a)
        check("A2_cold_entries_written", len(entries_a) >= 3, f"entries={len(entries_a)}")
        stamp_before = {p.name: entry_stamp(p) for p in entries_a}
        rc_w, log_w = run_corec(["build", str(src_a), "-o", str(out_warm), "--static"])
        check("A3_warm_rc0", rc_w == 0, f"rc={rc_w}")
        if rc_w != 0:
            print(log_w[-2000:])
            return 1
        check("A4_cold_warm_elf_identical",
              out_cold.read_bytes() == out_warm.read_bytes(),
              f"sha256[:16]={sha16(out_warm.read_bytes())}")
        ok_ccr, ccr_detail = ccr_contract_equal(str(out_cold) + ".ccr",
                                                str(out_warm) + ".ccr")
        check("A5_cold_warm_ccr_contract_segments", ok_ccr, ccr_detail)
        stamp_after = {p.name: entry_stamp(p) for p in probe_entries(src_a)}
        check("A6_warm_is_real_hit", stamp_before == stamp_after,
              "暖态条目 (size, mtime_ns) 全等 ⇒ 真命中（非空跑）")
        out_warm2 = tmpdir / "base_warm2"
        rc_w2, _ = run_corec(["build", str(src_a), "-o", str(out_warm2), "--static"])
        check("A7_warm_repeat_deterministic",
              rc_w2 == 0 and out_warm2.read_bytes() == out_cold.read_bytes())

        # ── B：变体（多串 / 0 串 / 大串 / 多函数）────────────────────────
        variants = [
            ("B1_multi_string", "multi_string.cr", BASE_PROBE),
            ("B2_zero_string", "zero_string.cr", ZERO_STR_PROBE),
            ("B3_big_string", "big_string.cr", BIG_STR_PROBE),
            ("B4_many_funcs", "many_funcs.cr", many_funcs_probe(24)),
        ]
        for name, fname, text in variants:
            src_v = write_probe(fname, text)
            oc, ow = tmpdir / (fname + ".cold"), tmpdir / (fname + ".warm")
            clean_entries(src_v)
            rc1, l1 = run_corec(["build", str(src_v), "-o", str(oc), "--static"])
            rc2, l2 = run_corec(["build", str(src_v), "-o", str(ow), "--static"])
            same = (rc1 == 0 and rc2 == 0 and oc.read_bytes() == ow.read_bytes())
            check(name, same, f"cold rc={rc1} warm rc={rc2}")
            if not same:
                print((l2 if rc2 != 0 else l1)[-1500:])

        # ── C：可选程序（表示面 ⇒ 缓存关；本修复不牵动该面）────────────
        src_c = write_probe("optional.cr", OPTIONAL_PROBE)
        clean_entries(src_c)
        oc, ow = tmpdir / "opt_cold", tmpdir / "opt_warm"
        rc1, l1 = run_corec(["build", str(src_c), "-o", str(oc), "--static"])
        rc2, l2 = run_corec(["build", str(src_c), "-o", str(ow), "--static"])
        check("C1_optional_two_runs_identical",
              rc1 == 0 and rc2 == 0 and oc.read_bytes() == ow.read_bytes(),
              f"cold rc={rc1} warm rc={rc2}")
        check("C2_optional_cache_off_zero_entries", len(probe_entries(src_c)) == 0,
              f"entries={len(probe_entries(src_c))}（可选面 = P4 T5 关缓存，本修复不涉及）")

        # ── D：累计装载复现例（补零条目 Σ=1.2GB > 1GB 堆）────────────────
        src_d = write_probe("pad.cr", many_funcs_probe(PAD_FUNCS))
        clean_entries(src_d)
        oc, ow = tmpdir / "pad_cold", tmpdir / "pad_warm"
        rc_c, log_c = run_corec(["build", str(src_d), "-o", str(oc), "--static"])
        check("D1_pad_cold_rc0", rc_c == 0, f"rc={rc_c}")
        if rc_c != 0:
            print(log_c[-2000:])
            return 1
        entries = probe_entries(src_d)
        for p in entries:                     # 补零到 3MB（稀疏；装载只读声明段）
            with open(p, "ab") as fh:
                fh.truncate(PAD_BYTES)
        total = sum(p.stat().st_size for p in entries)
        check("D2_pad_total_exceeds_heap", total > (1 << 30),
              f"{len(entries)} 条目 Σ={total} B > 1GiB 堆")
        stamp_before = {p.name: entry_stamp(p) for p in entries}
        rc_w, log_w, rss = run_corec_rss(["build", str(src_d), "-o", str(ow), "--static"])
        check("D3_pad_warm_rc0", rc_w == 0, f"rc={rc_w}（修复前此处 rc=139）")
        if rc_w != 0:
            print(log_w[-2000:])
            return 1
        ok_ccr, ccr_detail = ccr_contract_equal(str(oc) + ".ccr", str(ow) + ".ccr")
        check("D4_pad_warm_cold_identical",
              oc.read_bytes() == ow.read_bytes() and ok_ccr,
              f"ELF 逐字节同；{ccr_detail}")
        stamp_after = {p.name: entry_stamp(p) for p in entries}
        check("D5_pad_entries_still_hits", stamp_before == stamp_after,
              "补零条目 (size, mtime_ns) 全等 ⇒ 暖态走命中路径（非退化为 miss 重写）")
        check("D6_pad_warm_rss_bounded", 0 < rss < RSS_BOUND_KB,
              f"峰值 RSS={rss} KB < {RSS_BOUND_KB} KB（钉「读缓冲不累计」；"
              f"Σ 读取载荷={total // 1024} KB）")

        # ── E：自源暖态（真·红态语料；COREC_WARM_SELF=1 才跑）────────────
        if os.environ.get("COREC_WARM_SELF") == "1":
            oc, ow = tmpdir / "self_cold", tmpdir / "self_warm"
            run_corec(["clean-cache"])
            rc1, l1 = run_corec(["build", "src/compiler/main.cr", "-O", "0",
                                 "-o", str(oc), "--static"])
            rc2, l2 = run_corec(["build", "src/compiler/main.cr", "-O", "0",
                                 "-o", str(ow), "--static"])
            check("E1_self_cold_rc0", rc1 == 0, f"rc={rc1}")
            check("E2_self_warm_rc0_and_identical",
                  rc1 == 0 and rc2 == 0 and oc.read_bytes() == ow.read_bytes(),
                  f"cold rc={rc1} warm rc={rc2}（修复前暖态 rc=139）")
        else:
            print("[SKIP] E1/E2 自源暖态（置 COREC_WARM_SELF=1 开启；~3 分钟、1.25GB 缓存）")

        print(f"{checks - len(failures)}/{checks} passed")
        for f in failures:
            print(f"  FAILED: {f}")
        return 0 if not failures else 1
    finally:
        for p in probes:
            clean_entries(p)
        shutil.rmtree(tmpdir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
