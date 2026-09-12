#!/usr/bin/env python3
"""R2 P4 Task 1：`.ccr` 段机制（TYPE=7 / IFACE=8 + 版本 7→8）结构性断言套件。

本套件 = **机制面**守门（内容面归 Task 2/3——届时本文件追加行表/项 DAG/IFACE
五小节的用例；Task 1 只落两段空壳）：

  ① 段表 = 8 段、tag 序 = 1..8、offset 连续、末段尾 == 文件大小；
  ② header: version = 8、seg_count = 8、reserved = 0；
  ③ TYPE(7)/IFACE(8) 空壳：段体 = count u32 = 0（恰 4B，无余量）；
  ④ loader 负分支（byte mutation，逐个打；全部要求 corearch rc≠0 且**不得
     静默当空表**——三态纪律 C.5-3）：
       · version := 7 → 拒（D10：旧 v7 文件在版本闸整类拒收）；
       · **结构性合法的 v7（6 段）文件整体重建** → 拒（D10 的正面证据：
         非「字节破烂」被拒，而是合法旧文件被版本闸拒）；
       · seg_cnt := 6（末段 size 扩到 EOF——前闸全过）→ 拒（D11 必备集）；
       · 段 tag ∉ 1..8（tag := 9）/ 重复 tag（7 → 6）→ 拒（闸界 + 规范序）；
       · TYPE/IFACE 段体 count := 1（半成品内容）→ 拒（空壳期不接受外部内容）；
       · 段体截断（文件 −1B）→ 拒（越界）。
  ⑤ 端到端（空壳态不回归）：corec build --static + corearch --elf 双路径
     rc=0 + 产物行为正确（rc=42）；
  ⑥ 冷/热两态：TYPE/IFACE 段体逐字节同（Task 1 起新增守门——段内容 = 纯函数
     的前置形态）。STR 段冷/热差异 = 既有已登记面（TODO #5 末条），**非**
     本套件判据——口径同 test_ccr_v7.py::test_v7_cache_hit_restore_path。

字节真相 = docs/superpowers/specs/2026-09-09-lattice-ir-v7-format.md
（v8 = v7 段表架构的加法扩展——D9/D10；文件名/测试名保留「v7」字样）：
  [0]   magic u32 = 0x31524343 ("CCR1")
  [4]   version u32 = 8
  [8]   seg_count u32 = 8
  [12]  reserved u32 = 0
  [16]  段表 8 × 12B {tag u32, offset u32, size u32}（规范序 tag 1..8）
  [112] 段体（tag 升序连续）：
        STR(1) / SYM(2) / NOD(3) / ENT(4) / REG(5) / EDG(6) / TYPE(7) / IFACE(8)
  TYPE(7)  = [row_count u32]（Task 1 空壳 = 0；内容面 Task 2：行表 24B/条 +
             项 DAG 40B/条）
  IFACE(8) = [native_count u32]（Task 1 空壳 = 0；内容面 Task 3：五小节）
"""
import os
import shutil
import struct
import subprocess

BASE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
COREC = os.path.join(BASE, 'build/corec')
COREARCH = os.path.join(BASE, 'build/corearch')

MAGIC = 0x31524343  # "CCR1"
VER = 8             # v8 = v7 段表架构的加法扩展（D10）
SEG_TAGS = [1, 2, 3, 4, 5, 6, 7, 8]  # STR SYM NOD ENT REG EDG TYPE IFACE
HEADER_TABLE = 16 + 8 * 12  # 112
SHELL_TAGS = (7, 8)
SHELL_SIZE = 4  # count u32（空壳）

# 旧格式（v7）参照值——D10 的拒收面
V7_SEG_TAGS = [1, 2, 3, 4, 5, 6]
V7_HEADER_TABLE = 16 + 6 * 12  # 88
V7_VER = 7


class CcrFile:
    """`.ccr` 全段解析（8 段规范序契约；违反 = AssertionError）。"""

    def __init__(self, data: bytes):
        self.d = data
        assert len(data) >= HEADER_TABLE, \
            f"file too small for header+8-seg table: {len(data)}"
        (magic, ver, seg_count, reserved) = struct.unpack_from('<4I', data, 0)
        assert magic == MAGIC, f"bad magic {magic:#x}"
        assert ver == VER, f"expected version {VER}, got {ver}"
        assert seg_count == 8, f"expected 8 segments, got {seg_count}"
        assert reserved == 0, f"reserved != 0: {reserved}"
        self.segs = {}
        cur = HEADER_TABLE  # 段体紧随段表
        for i, tag in enumerate(SEG_TAGS):
            (t, off, size) = struct.unpack_from('<3I', data, 16 + i * 12)
            assert t == tag, f"row {i}: expected tag {tag}, got {t}"
            assert off == cur, f"tag {tag}: expected offset {cur}, got {off}"
            assert off + size <= len(data), f"tag {tag}: body out of file"
            self.segs[tag] = (off, size)
            cur = off + size
        assert cur == len(data), \
            f"segments end at {cur} of {len(data)} bytes"
        self.fsize = len(data)

    def body(self, tag: int) -> bytes:
        off, size = self.segs[tag]
        return self.d[off:off + size]

    def count(self, tag: int) -> int:
        """段体首字段（各段自带计数 u32）。"""
        (n,) = struct.unpack_from('<I', self.body(tag), 0)
        return n


def corec_ccr(src: str, out: str) -> str:
    r = subprocess.run([COREC, 'ccr', src, '-o', out],
                       capture_output=True, text=True, cwd=BASE, timeout=180)
    assert r.returncode == 0, f"corec ccr failed rc={r.returncode}: {r.stdout}\n{r.stderr}"
    return r.stdout


def read_ccr(path: str) -> bytes:
    with open(path, 'rb') as fh:
        return fh.read()


def arch_elf(ccr_in: str, elf_out: str, must_fail: bool = False):
    r = subprocess.run([COREARCH, ccr_in, '--elf', '--static', '-o', elf_out],
                       capture_output=True, text=True, cwd=BASE, timeout=180)
    if must_fail:
        assert r.returncode != 0, \
            f"corearch accepted mutated file: rc={r.returncode} " \
            f"(silent-accept = 三态纪律违反)"
        assert 'invalid' in (r.stdout + r.stderr), \
            f"expected invalid-.ccr error, got: {r.stdout!r} {r.stderr!r}"
    else:
        assert r.returncode == 0, \
            f"corearch load failed: rc={r.returncode} {r.stdout!r} {r.stderr!r}"
    return r


def _write(path: str, data: bytes) -> str:
    with open(path, 'wb') as fh:
        fh.write(data)
    return path


def _v7_structure_ok(data: bytes) -> bool:
    """独立 v7 结构校验（6 段规范序/连续/尾部贴合）——证明重建文件 = 合法
    v7 而非「字节破烂」（拒绝必须归因于版本闸，不是畸形）。"""
    if len(data) < V7_HEADER_TABLE:
        return False
    (magic, ver, seg_cnt, rsv) = struct.unpack_from('<4I', data, 0)
    if magic != MAGIC or ver != V7_VER or seg_cnt != 6 or rsv != 0:
        return False
    cur = V7_HEADER_TABLE
    for i, tag in enumerate(V7_SEG_TAGS):
        (t, off, size) = struct.unpack_from('<3I', data, 16 + i * 12)
        if t != tag or off != cur or off + size > len(data):
            return False
        cur = off + size
    return cur == len(data)


def _rebuild_v7(data: bytes) -> bytes:
    """把 v8 文件重建成**字节级合法**的 v7 文件：header 版本 7/6 段 + 段表
    offset 重算（88 起）+ 前六段段体原样（v8 的加法扩展不改前六段体）。"""
    bodies = [CcrFile(data).body(t) for t in V7_SEG_TAGS]
    out = bytearray(struct.pack('<4I', MAGIC, V7_VER, 6, 0))
    cur = V7_HEADER_TABLE
    for i, tag in enumerate(V7_SEG_TAGS):
        out += struct.pack('<3I', tag, cur, len(bodies[i]))
        cur += len(bodies[i])
    for b in bodies:
        out += b
    return bytes(out)


def _prog_src() -> str:
    return ("fn add(a: int, b: int) -> int { return a + b; }\n"
            "fn main() -> int { return add(40, 2); }\n")


def _shell_fixture(name: str):
    """产一个 fixture .ccr 并返回 (ccr_path, data)。调用方负责 cleanup。"""
    src_path = os.path.join(BASE, 'build', f'test_p4t1_{name}.cr')
    ccr_path = os.path.join(BASE, 'build', f'test_p4t1_{name}.ccr')
    for p in (src_path, ccr_path):
        try:
            os.unlink(p)
        except FileNotFoundError:
            pass
    with open(src_path, 'w') as fh:
        fh.write(_prog_src())
    corec_ccr(src_path, ccr_path)
    return src_path, ccr_path


def test_p4t1_layout_eight_segments():
    """① 段表 = 8 段规范序（tag 1..8）+ offset 连续 + 末段尾 == 文件大小；
    header version = 8 / seg_count = 8 / reserved = 0。"""
    src_path, ccr_path = _shell_fixture('layout')
    try:
        c = CcrFile(read_ccr(ccr_path))
        assert c.fsize > HEADER_TABLE
        # 前六段非空（既有内容面不因加段塌陷）；两空壳恰 4B
        for tag in (1, 2, 3, 4, 5, 6):
            assert c.segs[tag][1] > 4, f"segment {tag} unexpectedly empty"
        for tag in SHELL_TAGS:
            assert c.segs[tag][1] == SHELL_SIZE, \
                f"tag {tag} body {c.segs[tag][1]}B != shell {SHELL_SIZE}B"
    finally:
        for p in (src_path, ccr_path):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


def test_p4t1_shell_bodies_zero_count():
    """③ 两空壳 count == 0 且段体恰由一个 u32 构成（无余量/无尾随垃圾）。"""
    src_path, ccr_path = _shell_fixture('shell')
    try:
        c = CcrFile(read_ccr(ccr_path))
        for tag in SHELL_TAGS:
            assert c.count(tag) == 0, f"tag {tag} shell count != 0"
            assert len(c.body(tag)) == 4, f"tag {tag} shell body not bare u32"
    finally:
        for p in (src_path, ccr_path):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


def test_p4t1_loader_rejects_valid_v7_file():
    """④-a D10 正面证据：**结构性合法的 6 段 v7 文件**（段表重新算过 offset、
    段体原样）→ corearch 必须拒（版本闸整类拒收）——不得静默当空表读成
    「两段缺席 = 空」。
    非平凡性控制：先以独立校验器确认重建文件 = 合法 v7（否则「拒绝」可能只是
    畸形字节的副产品）。"""
    src_path, ccr_path = _shell_fixture('v7rej')
    bad = ccr_path + '.v7old'
    try:
        v7 = _rebuild_v7(read_ccr(ccr_path))
        assert _v7_structure_ok(v7), "rebuilt file is not a structurally valid v7"
        # 段体逐字节来自 v8 文件前六段（加法扩展不改前六段）——合法性自证
        c = CcrFile(read_ccr(ccr_path))
        for i, tag in enumerate(V7_SEG_TAGS):
            off, size = struct.unpack_from('<3I', v7, 16 + i * 12)[1:]
            assert v7[off:off + size] == c.body(tag), f"seg {tag} body drifted"
        _write(bad, v7)
        arch_elf(bad, os.path.join(BASE, 'build/test_p4t1_v7old.out'),
                 must_fail=True)
    finally:
        for p in (src_path, ccr_path, bad,
                  os.path.join(BASE, 'build/test_p4t1_v7old.out')):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


def test_p4t1_loader_rejects_missing_type_iface():
    """④-b D11：段表被改成 6 段且末段 size 扩到 EOF（tag 序/连续/越界三闸
    全过）→ 拒绝必须来自**必备集**（have7/have8 == 0），不得静默当空表。"""
    src_path, ccr_path = _shell_fixture('segsix')
    bad = ccr_path + '.six'
    try:
        data = bytearray(read_ccr(ccr_path))
        c = CcrFile(bytes(data))
        edg_off, _ = c.segs[6]
        struct.pack_into('<I', data, 8, 6)                      # seg_cnt := 6
        struct.pack_into('<I', data, 16 + 5 * 12 + 8,
                         len(data) - edg_off)                   # 末段扩到 EOF
        _write(bad, bytes(data))
        arch_elf(bad, os.path.join(BASE, 'build/test_p4t1_six.out'),
                 must_fail=True)
    finally:
        for p in (src_path, ccr_path, bad,
                  os.path.join(BASE, 'build/test_p4t1_six.out')):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


def test_p4t1_loader_rejects_tag_mutations():
    """④-c 段 tag 闸族：tag(7) := 9（出 1..8 界）/ tag(7) := 6（重复 tag）/
    tag(8) := 7（规范序失配）逐个 byte mutation → 拒绝。"""
    src_path, ccr_path = _shell_fixture('tagmut')
    try:
        base = read_ccr(ccr_path)
        for i, new_tag in ((6, 9), (6, 6), (7, 7)):
            data = bytearray(base)
            struct.pack_into('<I', data, 16 + i * 12, new_tag)
            bad = ccr_path + f'.tag{i}_{new_tag}'
            _write(bad, bytes(data))
            try:
                arch_elf(bad, os.path.join(BASE, 'build/test_p4t1_tag.out'),
                         must_fail=True)
            finally:
                try:
                    os.unlink(bad)
                except FileNotFoundError:
                    pass
    finally:
        for p in (src_path, ccr_path,
                  os.path.join(BASE, 'build/test_p4t1_tag.out')):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


def test_p4t1_loader_rejects_nonempty_shell():
    """④-d 空壳期不接受外部内容：TYPE(7)/IFACE(8) 段体 count := 1 → 拒绝
    （内容面落地前，非零计数 = 半成品，不得静默忽略）。"""
    src_path, ccr_path = _shell_fixture('shellne')
    try:
        base = read_ccr(ccr_path)
        for tag in SHELL_TAGS:
            data = bytearray(base)
            c = CcrFile(bytes(data))
            off, _ = c.segs[tag]
            struct.pack_into('<I', data, off, 1)  # count := 1
            bad = ccr_path + f'.c{tag}'
            _write(bad, bytes(data))
            try:
                arch_elf(bad, os.path.join(BASE, 'build/test_p4t1_ne.out'),
                         must_fail=True)
            finally:
                try:
                    os.unlink(bad)
                except FileNotFoundError:
                    pass
    finally:
        for p in (src_path, ccr_path,
                  os.path.join(BASE, 'build/test_p4t1_ne.out')):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


def test_p4t1_loader_rejects_truncated_body():
    """④-e 段体截断（文件 −1B）→ 越界拒绝（末段 size 不再被文件容纳）。"""
    src_path, ccr_path = _shell_fixture('trunc')
    bad = ccr_path + '.cut'
    try:
        data = read_ccr(ccr_path)
        _write(bad, data[:-1])
        arch_elf(bad, os.path.join(BASE, 'build/test_p4t1_cut.out'),
                 must_fail=True)
    finally:
        for p in (src_path, ccr_path, bad,
                  os.path.join(BASE, 'build/test_p4t1_cut.out')):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


def test_p4t1_end_to_end_shells():
    """⑤ 空壳态全链不回归：corec build --static（走 corec→.ccr→corearch）
    与 corec ccr + corearch --elf 两路径产物行为正确（rc=42）。"""
    src_path, ccr_path = _shell_fixture('e2e')
    elf1 = os.path.join(BASE, 'build/test_p4t1_e2e1.out')
    elf2 = os.path.join(BASE, 'build/test_p4t1_e2e2.out')
    try:
        r = subprocess.run([COREC, 'build', src_path, '-o', elf1, '--static'],
                           capture_output=True, text=True, cwd=BASE, timeout=180)
        assert r.returncode == 0, f"corec build failed: {r.stdout}\n{r.stderr}"
        arch_elf(ccr_path, elf2)
        for p in (elf1, elf2):
            os.chmod(p, 0o755)
            rr = subprocess.run([p], capture_output=True, timeout=10)
            assert rr.returncode == 42, \
                f"{os.path.basename(p)} exit {rr.returncode} != 42"
    finally:
        for p in (src_path, ccr_path, elf1, elf2):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


def test_p4t1_cold_warm_shell_stability():
    """⑥ 冷/热两态：TYPE/IFACE 段体逐字节同（段内容 = 纯函数的前置形态）。
    命中证据 = 暖运行不重写缓存文件（mtime 不变）；同时复核既有五段（2..6）
    冷/热逐字节同（继承 test_ccr_v7 口径），STR 差异不入本判据。"""
    cache_dir = os.path.join(BASE, '.core', 'cache')
    cir_dir = os.path.join(cache_dir, 'cir')
    src_path, ccr_path = _shell_fixture('cw')
    out_cold = os.path.join(BASE, 'build/test_p4t1_cw_cold.ccr')
    out_warm = os.path.join(BASE, 'build/test_p4t1_cw_warm.ccr')
    try:
        shutil.rmtree(cache_dir, ignore_errors=True)
        corec_ccr(src_path, out_cold)
        snap = {os.path.join(cir_dir, f): os.stat(
                    os.path.join(cir_dir, f)).st_mtime_ns
                for f in os.listdir(cir_dir)}
        assert snap, "cold run did not populate cir cache"
        corec_ccr(src_path, out_warm)
        for p, ns in snap.items():
            assert os.stat(p).st_mtime_ns == ns, \
                f"warm run rewrote cache file {p} (not a full hit?)"
        cc = CcrFile(read_ccr(out_cold))
        cw = CcrFile(read_ccr(out_warm))
        for tag in (2, 3, 4, 5, 6) + SHELL_TAGS:
            assert cc.body(tag) == cw.body(tag), \
                f"segment {tag} drifted cold→warm"
    finally:
        for p in (src_path, ccr_path, out_cold, out_warm):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass
        shutil.rmtree(cache_dir, ignore_errors=True)


if __name__ == '__main__':
    tests = [test_p4t1_layout_eight_segments,
             test_p4t1_shell_bodies_zero_count,
             test_p4t1_loader_rejects_valid_v7_file,
             test_p4t1_loader_rejects_missing_type_iface,
             test_p4t1_loader_rejects_tag_mutations,
             test_p4t1_loader_rejects_nonempty_shell,
             test_p4t1_loader_rejects_truncated_body,
             test_p4t1_end_to_end_shells,
             test_p4t1_cold_warm_shell_stability]
    failed = 0
    for t in tests:
        try:
            t()
            print(f"PASS {t.__name__}")
        except AssertionError as e:
            failed += 1
            print(f"FAIL {t.__name__}: {e}")
        except Exception as e:
            failed += 1
            print(f"ERROR {t.__name__}: {e!r}")
    print(f"{len(tests) - failed}/{len(tests)} passed")
    raise SystemExit(1 if failed else 0)
