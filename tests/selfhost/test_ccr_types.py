#!/usr/bin/env python3
"""R2 P4 Task 1/2/3：`.ccr` TYPE=7 / IFACE=8 段（机制面 + TYPE/IFACE 内容面）断言套件。

本套件 = **机制面**（Task 1：段表/版本/loader 三闸）+ **TYPE 内容面**（Task 2：
行表 + 项 DAG 序列化 / D13 确定性装填 / corearch 读回重建 / 判定原语跨进程同值）
+ **IFACE 内容面**（Task 3：五小节 = 原生条目 16 行 + 形状名 + 接口签名项化 +
impl 边 + 方法表 / corearch 读回 / 跨段引用域 / 扩列与命名化守门）。

Task 1（机制面）：
  ① 段表 = 8 段、tag 序 = 1..8、offset 连续、末段尾 == 文件大小；
  ② header: version = 8、seg_count = 8、reserved = 0；
  ③ TYPE(7)/IFACE(8) **皆为内容面**（R2 P4 Task 2/3 起——空壳期已退役）；
  ④ loader 负分支（byte mutation，逐个打；全部要求 corearch rc≠0 且**不得
     静默当空表**——三态纪律 C.5-3）：
       · version := 7 → 拒（D10：旧 v7 文件在版本闸整类拒收）；
       · **结构性合法的 v7（6 段）文件整体重建** → 拒（D10 的正面证据：
         非「字节破烂」被拒，而是合法旧文件被版本闸拒）；
       · seg_cnt := 6（末段 size 扩到 EOF——前闸全过）→ 拒（D11 必备集）；
       · 段 tag ∉ 1..8（tag := 9）/ 重复 tag（7 → 6）→ 拒（闸界 + 规范序）；
       · 段体截断（文件 −1B）→ 拒（越界）。
  ⑤ 端到端：corec build --static + corearch --elf 双路径 rc=0 + 产物 rc=42
     + 产物 .ccr 的 TYPE/IFACE 段非空（内容面入真实构建路径）；
  ⑥ 冷/热两态：既有段 + TYPE + IFACE 段体逐字节同（语料 = add/main——ir_gen 不
     新增类型行 ⇒ 行表缓存不变量；见 T2 用例 ⑮ 的分语料拆解）。

Task 2（TYPE 内容面）：
  ⑦ 段结构（两小节计数/长度自洽、行表前 9 行 = 原生行块）；⑧ 段内行表/项表 ==
     corec 侧 dump（内存真值）；⑨ corearch 读回逐行对拍（含 probe 行——判定原语
     跨进程同值）；⑩ DAG 语义（无重行 + 引用槽拓扑 + rowterm dedup 实证）；⑪
     `--dump-types` 零产物影响（带/不带 flag 的 .ccr 逐字节同）；⑫ loader 负分支
     （引用槽拓扑违规 / 计数越界 / 截断 / 尾随字节）；⑬ 标注槽不误拒（ATOM b :=
     5000 接受；负控 = 真引用槽同值拒绝）；⑭ 冷/冷两次编译 TYPE 逐字节同；⑮
     冷/热分语料拆解（缓存不变量语料 TYPE 同；ptr_arith 热态行表 = 冷态前缀 +
     项表/probe 同 + SYM 悬挂引用实测登记）。

Task 3（IFACE 内容面）：见文件末「R2 P4 Task 3：IFACE 内容面」节（⑯..㉕）。

字节真相 = docs/superpowers/specs/2026-09-09-lattice-ir-v7-format.md
（v8 = v7 段表架构的加法扩展——D9/D10；文件名/测试名保留「v7」字样）：
  [0]   magic u32 = 0x31524343 ("CCR1")
  [4]   version u32 = 8
  [8]   seg_count u32 = 8
  [12]  reserved u32 = 0
  [16]  段表 8 × 12B {tag u32, offset u32, size u32}（规范序 tag 1..8）
  [112] 段体（tag 升序连续）：
        STR(1) / SYM(2) / NOD(3) / ENT(4) / REG(5) / EDG(6) / TYPE(7) / IFACE(8)
  TYPE(7)  = [row_count u32] [row_count × 24B {kind,data,extra} i64×3]
             [term_count u32] [term_count × 40B {tag,a..d} i64×5]（哈希不落盘）
  IFACE(8) = 五小节（R2 P4 Task 3，D14；字段宽度见下）：
    ① [native_count u32 = 16] [× 24B {ak i32, ti_row i32, name_ni i32, lit_code i32,
       ops i64}]
    ② [shape_count u32] [× 8B {name_ni i32, term i32}]
    ③ [iface_count u32] [× {name_ni i32, method_count i32, generic_count i32, pad i32}
       + method_count × 80B {name_ni i32, param_count i32, self_mode i32, ret_term i32,
                             param_terms[8] i32, param_codes[8] i32}]
    ④ [impl_count u32] [× 8B {trait_ni i32, type_ni i32}]
    ⑤ [method_count u32] [× 12B {type_ni i32, method_ni i32, mangled_ni i32}]
"""
import os
import re
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
TYPE_TAG = 7
IFACE_TAG = 8
ESZ_TYPE_ROW = 24    # 类型行表记录：{kind,data,extra} i64×3（D12）
ESZ_TYPE_TERM = 40   # 项 DAG 记录：{tag,a,b,c,d} i64×5（哈希不落盘，加载侧重算）
IFACE_NATIVE_N = 16  # R2 P4 Task 3 扩列硬值（13 → 16；见 ccr_io.cr 注）
IFACE_ENTRY_DISK = 24
IFACE_SHAPE_DISK = 8
IFACE_METHOD_DISK = 80
IFACE_IMPL_DISK = 8
IFACE_GMETHOD_DISK = 12
# D17 的六个形状名（生产注册面；corec 侧 iface_shape_builtin_init 逐名 str_intern）
IFACE_SHAPE_NAMES = ('sequence', 'sequence_ro', 'sequence_rw',
                     'indexable', 'iterable', 'product')
# 项引用槽字段表（tag → 槽下标；未列 tag = 无引用槽——标注/保留槽不得按
# 「< 自身行号」校验）：TT_UNION/TT_INTER/TT_CONS = a,b；TT_NOT = a；
# TT_MU = b（a = 绑定变量）；TT_ATOM = c（参数链头；a = ak、b = 标注）。
# 与 ccr_io.cr:ccr_type_term_ref_ok 同域（独立复述——防同源同错自洽假绿）。
TERM_REFS = {3: (0, 1), 4: (0, 1), 5: (0,), 6: (1,), 7: (2,), 10: (0, 1)}

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
        # 前六段非空（既有内容面不因加段塌陷）
        for tag in (1, 2, 3, 4, 5, 6):
            assert c.segs[tag][1] > 4, f"segment {tag} unexpectedly empty"
        # TYPE(7) = 内容面（R2 P4 Task 2 起）：至少原生 9 行 + 项段
        tbody = c.body(TYPE_TAG)
        assert len(tbody) >= 4 + 9 * ESZ_TYPE_ROW + 4 + ESZ_TYPE_TERM, \
            f"TYPE body {len(tbody)}B < native 9-row minimum"
        # IFACE(8) = 内容面（R2 P4 Task 3 起；空壳期已退役——原 SHELL_TAGS 断言
        # 由 `test_p4t3_iface_segment_layout` 的五小节结构断言取代）
        ibody = c.body(IFACE_TAG)
        assert len(ibody) >= 4 + IFACE_NATIVE_N * IFACE_ENTRY_DISK + 4 + 6 * IFACE_SHAPE_DISK, \
            f"IFACE body {len(ibody)}B < native 16 rows + 6 shapes minimum"
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
    """④-d **退役（R2 P4 Task 3）**：IFACE「空壳期不接受外部内容」断言随内容面落地
    退役——非零计数 = 正常内容（其 loader 负分支改由 T3 用例的跨段引用域/结构闸
    承担：见 `test_p4t3_loader_rejects_iface_mutations`）。
    本用例保留占位：TYPE 段体的**首字段语义**（row_count）仍受 T2 用例 ⑫ 的
    计数闸管辖；空壳闸（TYPE/IFACE count == 0 且恰 4B）自 T1 起已无适用对象。"""
    # 空壳期无对象可打 ⇒ 断言「内容面段体必然远大于 4B」（防「空壳闸静默复活」误判）
    src_path, ccr_path = _shell_fixture('shellne')
    try:
        c = CcrFile(read_ccr(ccr_path))
        for tag in (TYPE_TAG, IFACE_TAG):
            assert c.segs[tag][1] > 4, \
                f"tag {tag} body collapsed to shell size {c.segs[tag][1]}B"
    finally:
        for p in (src_path, ccr_path):
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
    """⑤ 全链不回归：corec build --static（走 corec→.ccr→corearch）
    与 corec ccr + corearch --elf 两路径产物行为正确（rc=42）；且真实构建路径
    产出的 .ccr 带**非空 TYPE 段**（内容面入盘——R2 P4 Task 2 起）。"""
    src_path, ccr_path = _shell_fixture('e2e')
    elf1 = os.path.join(BASE, 'build/test_p4t1_e2e1.out')
    elf2 = os.path.join(BASE, 'build/test_p4t1_e2e2.out')
    try:
        r = subprocess.run([COREC, 'build', src_path, '-o', elf1, '--static'],
                           capture_output=True, text=True, cwd=BASE, timeout=180)
        assert r.returncode == 0, f"corec build failed: {r.stdout}\n{r.stderr}"
        # build 路径的 .ccr（elf1 + '.ccr'）——TYPE 段非空 + 两小节自洽
        bccr = elf1 + '.ccr'
        try:
            rows, terms = parse_type_segment(CcrFile(read_ccr(bccr)).body(TYPE_TAG))
            assert len(rows) >= 9 and len(terms) > 0, \
                f"build-path TYPE segment empty: {len(rows)} rows {len(terms)} terms"
        finally:
            try:
                os.unlink(bccr)
            except FileNotFoundError:
                pass
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
    """⑥ 冷/热两态：TYPE/IFACE 段体逐字节同。语料 = add/main（ir_gen 不新增
    类型行 ⇒ 行表缓存不变量——分语料拆解见 T2 用例 ⑮）。
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
        for tag in (2, 3, 4, 5, 6, TYPE_TAG, IFACE_TAG):
            assert cc.body(tag) == cw.body(tag), \
                f"segment {tag} drifted cold→warm"
    finally:
        for p in (src_path, ccr_path, out_cold, out_warm):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass
        shutil.rmtree(cache_dir, ignore_errors=True)


# ═════════════════════ R2 P4 Task 2：TYPE 内容面 ═════════════════════

P4T2_ROW_RE = re.compile(r'^row (\d+) kind (-?\d+) data (-?\d+) extra (-?\d+)$')
P4T2_TERM_RE = re.compile(
    r'^term (\d+) tag (-?\d+) a (-?\d+) b (-?\d+) c (-?\d+) d (-?\d+)$')
P4T2_ROWT_RE = re.compile(r'^rowterm (\d+) (-?\d+)$')
P4T2_PROBE_RE = re.compile(r'^probe: (.*)$')


def parse_type_dump(text: str):
    """解析 `--dump-types` 输出（corec 与 corearch **同一条打印路径**，行格式
    契约见 ccr_io.cr:ccr_type_surface_dump）：

        rows: N
        row i kind K data D extra E          （i = 0..N-1）
        terms: M
        term i tag T a A b B c C d D         （i = 0..M-1）
        probe: n N sub1 X sub0 Y unknown Z digest H
        [rowterms: N / rowterm i T]          （corec-only 节——本解析器忽略）

    返回 (rows, terms, probe, rowterms)；行号必须无洞（契约）。"""
    rows, terms, rowterms = {}, {}, {}
    probe = None
    for ln in text.splitlines():
        m = P4T2_ROW_RE.match(ln)
        if m:
            rows[int(m.group(1))] = (int(m.group(2)), int(m.group(3)), int(m.group(4)))
            continue
        m = P4T2_TERM_RE.match(ln)
        if m:
            terms[int(m.group(1))] = tuple(int(m.group(k)) for k in (2, 3, 4, 5, 6))
            continue
        m = P4T2_ROWT_RE.match(ln)
        if m:
            rowterms[int(m.group(1))] = int(m.group(2))
            continue
        m = P4T2_PROBE_RE.match(ln)
        if m:
            probe = m.group(1)
    assert rows, "dump has no 'row' lines"
    assert terms, "dump has no 'term' lines"
    assert probe is not None, "dump has no 'probe' line"
    assert sorted(rows) == list(range(len(rows))), "row ids not contiguous"
    assert sorted(terms) == list(range(len(terms))), "term ids not contiguous"
    return ([(rows[i]) for i in range(len(rows))],
            [(terms[i]) for i in range(len(terms))],
            probe, rowterms)


def parse_type_segment(body: bytes):
    """TYPE 段字节 → (rows, terms)（D12 布局直解——独立于 dump 的第三方实现；
    行走完必须恰等于段体长度 = 无尾随字节）。"""
    (rc,) = struct.unpack_from('<I', body, 0)
    pos = 4
    rows = []
    for _ in range(rc):
        rows.append(struct.unpack_from('<qqq', body, pos))
        pos += ESZ_TYPE_ROW
    (tc,) = struct.unpack_from('<I', body, pos)
    pos += 4
    terms = []
    for _ in range(tc):
        terms.append(struct.unpack_from('<qqqqq', body, pos))
        pos += ESZ_TYPE_TERM
    assert pos == len(body), \
        f"TYPE body length drift: walked {pos}, body {len(body)}"
    return rows, terms


def corec_dump(src: str, out: str) -> str:
    """corec ccr --dump-types（写侧内存真值 dump）→ stdout。"""
    r = subprocess.run([COREC, 'ccr', src, '-o', out, '--dump-types'],
                       capture_output=True, text=True, cwd=BASE, timeout=180)
    assert r.returncode == 0, \
        f"corec ccr --dump-types failed rc={r.returncode}: {r.stdout}\n{r.stderr}"
    return r.stdout


def arch_dump(ccr_in: str) -> str:
    """corearch --dump-types（读侧载入重建后的 dump）→ stdout。"""
    r = subprocess.run([COREARCH, ccr_in, '--dump-types'],
                       capture_output=True, text=True, cwd=BASE, timeout=180)
    assert r.returncode == 0, \
        f"corearch --dump-types failed rc={r.returncode}: {r.stdout}\n{r.stderr}"
    return r.stdout


def type_seg(data: bytes) -> bytes:
    return CcrFile(data).body(TYPE_TAG)


def _resize_type_tail(data: bytes, delta: int) -> bytes:
    """TYPE 段体尾增(+)/删(-) |delta| 字节，并同步段表（TYPE size、IFACE offset）
    ——产出「段表仍自洽、TYPE 内容被破坏」的文件（拒收必须归因于内容闸）。"""
    d = bytearray(data)
    (t_off, t_size) = struct.unpack_from('<2I', d, 16 + 6 * 12 + 4)
    struct.pack_into('<I', d, 16 + 6 * 12 + 8, t_size + delta)
    (i_off,) = struct.unpack_from('<I', d, 16 + 7 * 12 + 4)
    struct.pack_into('<I', d, 16 + 7 * 12 + 4, i_off + delta)
    cut = t_off + t_size
    if delta > 0:
        return bytes(d[:cut]) + b'\x00' * delta + bytes(d[cut:])
    return bytes(d[:cut + delta]) + bytes(d[cut:])


def sym_type_refs(data: bytes):
    """SYM 段里全部类型行引用（globals type + func var_decls type）——检查载体
    自洽（引用域必须 < TYPE 段行数；T2 用例 ⑮ 的根因量化用）。"""
    c = CcrFile(data)
    off, size = c.segs[2]
    end = off + size
    p = off
    refs = []
    (gc,) = struct.unpack_from('<I', data, p)
    p += 4
    for _ in range(gc):
        _nm, ty = struct.unpack_from('<II', data, p)
        p += 16
        refs.append(ty)
    (fc,) = struct.unpack_from('<I', data, p)
    p += 4
    for _ in range(fc):
        _nm, pc, _rt, _root, _ffe, _fle = struct.unpack_from('<6i', data, p)
        p += 24 + 4 * pc
        (vc,) = struct.unpack_from('<I', data, p)
        p += 4
        for _ in range(vc):
            _nm2, ty2 = struct.unpack_from('<II', data, p)
            p += 8
            refs.append(ty2)
    assert p <= end, "SYM walk overran segment"
    return refs


def test_p4t2_type_segment_layout():
    """⑦ 段结构：两小节计数/长度自洽（行走完 == 段体长）+ 行表前 7 行 = 原生
    基础行块（kind 同族、data = 0..6——checker.init_types 的 9 行原生表）。"""
    src_path, ccr_path = _shell_fixture('t2layout')
    try:
        rows, terms = parse_type_segment(type_seg(read_ccr(ccr_path)))
        assert len(rows) >= 9, f"row table too small: {len(rows)}"
        assert len(terms) > 0, "term DAG empty"
        for i in range(7):   # 原生 int/dex/bool/string/unit/never/char
            assert rows[i][0] == rows[0][0] and rows[i][1] == i, \
                f"native row {i} drifted: {rows[i]}"
        for i, t in enumerate(terms):   # D12 加载侧同域不变量
            assert 0 <= t[0] <= 10, f"term {i} tag out of 0..10: {t[0]}"
            assert all(v >= -1 for v in t[1:]), f"term {i} field < -1: {t}"
            for slot in TERM_REFS.get(t[0], ()):
                r = t[1 + slot]
                assert r == -1 or r < i, \
                    f"term {i} ref slot {slot} = {r} not < own row (topology)"
    finally:
        _cleanup(src_path, ccr_path)


def test_p4t2_rows_and_terms_match_corec_dump():
    """⑧ 段内行表/项表 == corec 侧内存表（dump 打印内存真值）——写侧装填 +
    序列化的保真链：内存 → 缓冲 → 文件（Python 直解字节）。"""
    src_path, ccr_path = _shell_fixture('t2rows')
    try:
        dump = corec_dump(src_path, ccr_path)
        d_rows, d_terms, _probe, d_rowt = parse_type_dump(dump)
        b_rows, b_terms = parse_type_segment(type_seg(read_ccr(ccr_path)))
        assert [tuple(r) for r in b_rows] == d_rows, "file rows != memory rows"
        assert [tuple(t) for t in b_terms] == d_terms, "file terms != memory terms"
        assert len(d_rowt) == len(d_rows), \
            f"rowterm map size {len(d_rowt)} != rows {len(d_rows)}"
    finally:
        _cleanup(src_path, ccr_path)


def test_p4t2_corearch_readback_parity():
    """⑨ 读回证据（spec §6.3 + 判定原语跨进程同值）：corearch `--dump-types`
    与 corec 侧 dump 的共享节（rows/terms/probe）逐行一致——载入段重建的行表 /
    项 DAG / 引擎判定结果与写侧进程逐位同。"""
    src_path, ccr_path = _shell_fixture('t2par')
    try:
        corec_out = corec_dump(src_path, ccr_path)
        arch_out = arch_dump(ccr_path)
        c_rows, c_terms, c_probe, c_rowt = parse_type_dump(corec_out)
        a_rows, a_terms, a_probe, a_rowt = parse_type_dump(arch_out)
        assert c_rows == a_rows, "read-back row table drifted"
        assert c_terms == a_terms, "read-back term DAG drifted"
        assert c_probe == a_probe, \
            f"probe diverged across processes: {c_probe!r} vs {a_probe!r}"
        assert 'digest' in c_probe and 'norm_unknown' in c_probe and 'lit_ok' in c_probe
        assert c_rowt and not a_rowt, "rowterm section must be corec-only"
    finally:
        _cleanup(src_path, ccr_path)


def test_p4t2_dag_dedup_topology():
    """⑩ DAG 语义（ptr_arith 语料——含 &arr[i]/&x 的指针行）：
    ① 项表无同 (tag,a..d) 重行（tt_term 去重的不变量，重建路径的牙）；
    ② rowterm 映射：重复构造的指针行全部命中**同一项**（dedup 实证）且 `[int;5]`
       与 `*int` 命中不同项；③ 引用槽 < 自身行号 + 引用值在项表域内。"""
    src = os.path.join(BASE, 'tests/suite/ptr_arith.cr')
    ccr = os.path.join(BASE, 'build/test_p4t2_dedup.ccr')
    try:
        dump = corec_dump(src, ccr)
        d_rows, d_terms, _probe, d_rowt = parse_type_dump(dump)
        b_rows, b_terms = parse_type_segment(type_seg(read_ccr(ccr)))
        assert [tuple(t) for t in b_terms] == d_terms
        assert len(set(b_terms)) == len(b_terms), "duplicate term rows (no dedup)"
        for i, t in enumerate(b_terms):
            for slot in TERM_REFS.get(t[0], ()):
                r = t[1 + slot]
                assert r == -1 or r < i, f"term {i} ref {r} not < own row"
        assert all(0 <= v < len(b_terms) for v in d_rowt.values()), \
            "rowterm index out of term table"
        assert len(d_rowt) == len(d_rows)
        # dedup 实证：ptr_arith 的 5 个 `*int` 行（&arr[2]/&x 等）→ 同一项
        from collections import Counter
        cnt = Counter(d_rowt.values())
        assert cnt.most_common(1)[0][1] >= 2, \
            f"no term shared by >=2 rows (dedup not exercised): {cnt}"
        assert len(set(d_rowt.values())) >= 2, "all rows map to one term?"
    finally:
        try:
            os.unlink(ccr)
        except FileNotFoundError:
            pass


def test_p4t2_dump_flag_zero_artifact_effect():
    """⑪ `--dump-types` 是**只读通道**：带/不带 flag 的 .ccr 逐字节同——probe 的
    规范化建项发生在段体缓冲构造**之后**，不得泄入序列化面。"""
    src_path, ccr_path = _shell_fixture('t2flag')
    with_dump = ccr_path + '.dump'
    try:
        corec_ccr(src_path, ccr_path)                 # 不带 flag
        corec_dump(src_path, with_dump)               # 带 flag
        assert read_ccr(ccr_path) == read_ccr(with_dump), \
            "--dump-types changed the emitted .ccr"
    finally:
        _cleanup(src_path, ccr_path, with_dump)


def test_p4t2_loader_rejects_topology_violation():
    """⑫-a 子项引用拓扑违规（自引用 / 前向引用 / 远越界）⇒ 拒绝。"""
    src = os.path.join(BASE, 'tests/suite/ptr_arith.cr')
    ccr = os.path.join(BASE, 'build/test_p4t2_topo.ccr')
    try:
        corec_dump(src, ccr)
        data = read_ccr(ccr)
        rows, terms = parse_type_segment(type_seg(data))
        t_off, _ = CcrFile(data).segs[TYPE_TAG]
        base = t_off + 4 + len(rows) * ESZ_TYPE_ROW + 4
        # 挑一个带引用槽的项（CONS/UNION/INTER/NOT/MU/ATOM-c）
        idx = next(i for i, t in enumerate(terms) if TERM_REFS.get(t[0]))
        slot = TERM_REFS[terms[idx][0]][0]
        for bad_val in (idx, idx + 1, len(terms) + 1000):
            d = bytearray(data)
            struct.pack_into('<q', d, base + idx * ESZ_TYPE_TERM + 8 * (1 + slot),
                             bad_val)
            bad = ccr + f'.topo{bad_val}'
            _write(bad, bytes(d))
            try:
                arch_elf(bad, os.path.join(BASE, 'build/test_p4t2_topo.out'),
                         must_fail=True)
            finally:
                try:
                    os.unlink(bad)
                except FileNotFoundError:
                    pass
    finally:
        _cleanup(ccr, os.path.join(BASE, 'build/test_p4t2_topo.out'))


def test_p4t2_loader_accepts_annotation_slot():
    """⑬ 标注槽不得被误拒：ATOM 的 b（自类型行号/固定性位/令牌值——可达数千）
    改 5000 ⇒ 载入成功且 dump 原样打印（突变真实 = 防「假接受」）。
    负控：同值写进**真引用槽**（CONS 的 a）⇒ 拒绝（⑫-a 的反面）。"""
    src = os.path.join(BASE, 'tests/suite/ptr_arith.cr')
    ccr = os.path.join(BASE, 'build/test_p4t2_ann.ccr')
    try:
        corec_dump(src, ccr)
        data = read_ccr(ccr)
        rows, terms = parse_type_segment(type_seg(data))
        t_off, _ = CcrFile(data).segs[TYPE_TAG]
        base = t_off + 4 + len(rows) * ESZ_TYPE_ROW + 4
        ai = next(i for i, t in enumerate(terms) if t[0] == 7)      # TT_ATOM
        ci = next(i for i, t in enumerate(terms) if t[0] == 10)     # TT_CONS
        d = bytearray(data)
        struct.pack_into('<q', d, base + ai * ESZ_TYPE_TERM + 8 * 2, 5000)  # b := 5000
        ok = ccr + '.annok'
        _write(ok, bytes(d))
        try:
            out = arch_dump(ok)
            rows2, terms2, _p, _r = parse_type_dump(out)
            assert tuple(terms2[ai]) == tuple(terms[ai][:2]) + (5000,) + \
                tuple(terms[ai][3:]), "mutation not visible in dump (fake accept?)"
            assert len(terms2) == len(terms)
        finally:
            try:
                os.unlink(ok)
            except FileNotFoundError:
                pass
        d2 = bytearray(data)
        struct.pack_into('<q', d2, base + ci * ESZ_TYPE_TERM + 8, 5000)     # CONS a
        bad = ccr + '.annbad'
        _write(bad, bytes(d2))
        try:
            arch_elf(bad, os.path.join(BASE, 'build/test_p4t2_ann.out'),
                     must_fail=True)
        finally:
            try:
                os.unlink(bad)
            except FileNotFoundError:
                pass
    finally:
        _cleanup(ccr, os.path.join(BASE, 'build/test_p4t2_ann.out'))


def test_p4t2_loader_rejects_count_and_truncation():
    """⑫-b 计数/长度闸：term_count := tc+1 / row_count := rc+1 / 行表末 8B 截断
    （段表 offset 同步重排）/ 段体尾插 4B 垃圾（尾随字节）——逐个拒绝。"""
    src_path, ccr_path = _shell_fixture('t2cnt')
    try:
        corec_ccr(src_path, ccr_path)
        data = read_ccr(ccr_path)
        rows, terms = parse_type_segment(type_seg(data))
        c = CcrFile(data)
        t_off, _t_size = c.segs[TYPE_TAG]
        tc_off = t_off + 4 + len(rows) * ESZ_TYPE_ROW
        i_off, _i_size = c.segs[8]
        mutations = {}
        d = bytearray(data)
        struct.pack_into('<I', d, tc_off, len(terms) + 1)     # term_count +1
        mutations['termcount'] = bytes(d)
        d = bytearray(data)
        struct.pack_into('<I', d, t_off, len(rows) + 1)       # row_count +1
        mutations['rowcount'] = bytes(d)
        mutations['trunc'] = _resize_type_tail(data, -8)      # 行表尾截断
        mutations['trail'] = _resize_type_tail(data, 4)       # 尾随 4B 垃圾
        for name, mdata in mutations.items():
            # 段表仍自洽（前闸全过——拒绝必须归因于 TYPE 内容闸）
            assert CcrFile(mdata).segs[TYPE_TAG][0] == t_off
            if name in ('trunc', 'trail'):
                assert CcrFile(mdata).segs[8][0] != i_off   # 重排后 offset 已移
            else:
                assert CcrFile(mdata).segs[8][0] == i_off
            bad = ccr_path + '.' + name
            _write(bad, mdata)
            try:
                arch_elf(bad, os.path.join(BASE, 'build/test_p4t2_cnt.out'),
                         must_fail=True)
            finally:
                try:
                    os.unlink(bad)
                except FileNotFoundError:
                    pass
    finally:
        _cleanup(src_path, ccr_path, os.path.join(BASE, 'build/test_p4t2_cnt.out'))


def test_p4t2_determinism_cold_cold():
    """⑭ 确定性（D13 直接守门）：同源两次**冷缓存**编译 ⇒ TYPE 段逐字节同
    （且整 .ccr 逐字节同——冷/冷两态本不应有任何差异）。"""
    cache_dir = os.path.join(BASE, '.core', 'cache')
    src = os.path.join(BASE, 'tests/suite/ptr_arith.cr')
    a = os.path.join(BASE, 'build/test_p4t2_det_a.ccr')
    b = os.path.join(BASE, 'build/test_p4t2_det_b.ccr')
    try:
        for out in (a, b):
            shutil.rmtree(cache_dir, ignore_errors=True)
            corec_ccr(src, out)
        da, db = read_ccr(a), read_ccr(b)
        assert type_seg(da) == type_seg(db), "TYPE segment not deterministic"
        assert da == db, ".ccr drifted between two cold builds"
    finally:
        _cleanup(a, b)


def test_p4t2_cold_warm_type_segment():
    """⑮ 冷/热两态 TYPE 段（分语料拆解）：
    ① 缓存不变量语料（add/main：ir_gen 不新增类型行）⇒ TYPE 段逐字节同；
    ② ptr_arith（ir_gen 在冷路径新增行：&arr[2]/&x 的 ptr/array 行）⇒ 热态行表 =
       冷态行表**前缀**、项表与 probe 逐位同；热态 SYM 中引用被跳过行的编号
       （≥ 热态行数）数量实测登记——根因 = `.cir` 缓存命中路径跳过 ir_gen 的
       alloc_type（前端行分配），**既有已登记面**（TODO #5 末条同族），本任务不修；
       不变量：两侧 SYM 引用都不超出**冷态**行表（悬挂仅为「缺后缀行」所致）。"""
    cache_dir = os.path.join(BASE, '.core', 'cache')
    src_path, ccr_path = _shell_fixture('t2cw')
    cold = ccr_path + '.cold'
    warm = ccr_path + '.warm'
    pa = os.path.join(BASE, 'tests/suite/ptr_arith.cr')
    pa_cold = os.path.join(BASE, 'build/test_p4t2_pa_cold.ccr')
    pa_warm = os.path.join(BASE, 'build/test_p4t2_pa_warm.ccr')
    try:
        # ① 缓存不变量语料
        shutil.rmtree(cache_dir, ignore_errors=True)
        corec_ccr(src_path, cold)
        corec_ccr(src_path, warm)
        assert type_seg(read_ccr(cold)) == type_seg(read_ccr(warm)), \
            "TYPE drifted cold->warm on a cache-invariant corpus"
        # ② ptr_arith：冷/热行表前缀关系 + 项表/probe 同值
        shutil.rmtree(cache_dir, ignore_errors=True)
        out_cold = corec_dump(pa, pa_cold)    # 冷（no cache）
        out_warm = corec_dump(pa, pa_warm)    # 热（全命中）
        dc, dw = read_ccr(pa_cold), read_ccr(pa_warm)
        rc_rows, rc_terms = parse_type_segment(type_seg(dc))
        rw_rows, rw_terms = parse_type_segment(type_seg(dw))
        assert rc_terms == rw_terms, \
            f"term DAG drifted cold->warm ({len(rc_terms)} vs {len(rw_terms)})"
        assert len(rw_rows) <= len(rc_rows), "warm row table larger than cold?"
        assert rw_rows == rc_rows[:len(rw_rows)], \
            "warm row table is not a prefix of the cold row table"
        pc = [ln for ln in out_cold.splitlines() if ln.startswith('probe:')]
        pw = [ln for ln in out_warm.splitlines() if ln.startswith('probe:')]
        assert pc == pw and pc, "probe diverged cold->warm"
        # 悬挂引用量化（登记，不修）：两侧引用均不出冷态行表
        for tag, name in ((dc, 'cold'), (dw, 'warm')):
            refs = sym_type_refs(tag)
            assert max(refs) < len(rc_rows), \
                f"{name}: SYM type ref outside cold row table"
        d_cold = sum(1 for r in sym_type_refs(dc) if r >= len(rc_rows))
        d_warm = sum(1 for r in sym_type_refs(dw) if r >= len(rw_rows))
        print(f"  [info] ptr_arith SYM dangling type refs: cold={d_cold} "
              f"warm={d_warm} (rows cold={len(rc_rows)} warm={len(rw_rows)}; "
              f"root cause = .cir cache hit skips ir_gen alloc_type)")
        assert d_cold == 0, f"cold .ccr has {d_cold} dangling type refs"
    finally:
        _cleanup(src_path, ccr_path, cold, warm, pa_cold, pa_warm,
                 pa_cold + '.d', pa_warm + '.d')


# ═════════════════════ R2 P4 Task 3：IFACE 内容面 ═════════════════════
# 字节布局 = 文件头 docstring（D14 五小节；方法记录字段序取计划「声明行」序：
# {name_ni, param_count, self_mode, ret_term, param_terms[8], param_codes[8]}）。

P4T3_NATIVE_RE = re.compile(r'^native (\d+) ak (-?\d+) ti (-?\d+) name (-?\d+) lit (-?\d+) ops (-?\d+)$')
P4T3_SHAPE_RE = re.compile(r'^shape (\d+) name (-?\d+) term (-?\d+)$')
P4T3_IFACE_RE = re.compile(r'^iface (\d+) name (-?\d+) methods (\d+) generics (-?\d+)$')
P4T3_METHOD_RE = re.compile(r'^method (\d+) (\d+) name (-?\d+) params (\d+) self (-?\d+) ret (-?\d+)$')
P4T3_MPARAM_RE = re.compile(r'^mparam (\d+) (\d+) (\d+) code (-?\d+) term (-?\d+)$')
P4T3_IMPL_RE = re.compile(r'^impl (\d+) trait (-?\d+) type (-?\d+)$')
P4T3_GMETHOD_RE = re.compile(r'^gmethod (\d+) type (-?\d+) method (-?\d+) mangled (-?\d+)$')
P4T3_PROBE_RE = re.compile(
    r'^ifaceprobe: slots (\d+) built (\d+) unbuilt (\d+) bad (\d+) digest (-?\d+)$')
P4T3_SIG_RE = re.compile(r'^ifacesig (\d+) (\d+) ret (-?\d+) pc (\d+)$')
P4T3_SIGP_RE = re.compile(r'^ifacesigp (\d+) (\d+) (\d+) (-?\d+)$')


def parse_iface_segment(body: bytes):
    """IFACE 段字节 → (natives, shapes, ifaces, impls, methods)
    （D14 布局直解——独立于 dump 的第三方实现；行走完必须恰等于段体长度）。
    natives = [(ak, ti, name_ni, lit, ops)]；shapes = [(name_ni, term)]；
    ifaces = [(name_ni, method_count, generic_count, pad, [(mname, pc, self_mode,
    ret_term, param_terms(8), param_codes(8))])]；impls = [(trait_ni, type_ni)]；
    methods = [(type_ni, method_ni, mangled_ni)]。"""
    p = 0
    (nat,) = struct.unpack_from('<I', body, p)
    p += 4
    natives = []
    for _ in range(nat):
        ak, ti, nm, lit = struct.unpack_from('<4i', body, p)
        (ops,) = struct.unpack_from('<q', body, p + 16)
        natives.append((ak, ti, nm, lit, ops))
        p += IFACE_ENTRY_DISK
    (shn,) = struct.unpack_from('<I', body, p)
    p += 4
    shapes = []
    for _ in range(shn):
        nm, term = struct.unpack_from('<2i', body, p)
        shapes.append((nm, term))
        p += IFACE_SHAPE_DISK
    (ifn,) = struct.unpack_from('<I', body, p)
    p += 4
    ifaces = []
    for _ in range(ifn):
        nm, mc, gc, pad = struct.unpack_from('<4i', body, p)
        p += 16
        meths = []
        for _ in range(mc):
            mname, pc, sm, rt = struct.unpack_from('<4i', body, p)
            p += 16
            terms = struct.unpack_from('<8i', body, p)
            p += 32
            codes = struct.unpack_from('<8i', body, p)
            p += 32
            meths.append((mname, pc, sm, rt, terms, codes))
        ifaces.append((nm, mc, gc, pad, meths))
    (ic,) = struct.unpack_from('<I', body, p)
    p += 4
    impls = []
    for _ in range(ic):
        tr, ty = struct.unpack_from('<2i', body, p)
        impls.append((tr, ty))
        p += IFACE_IMPL_DISK
    (mcnt,) = struct.unpack_from('<I', body, p)
    p += 4
    methods = []
    for _ in range(mcnt):
        ty, mn, mg = struct.unpack_from('<3i', body, p)
        methods.append((ty, mn, mg))
        p += IFACE_GMETHOD_DISK
    assert p == len(body), \
        f"IFACE body length drift: walked {p}, body {len(body)}"
    return natives, shapes, ifaces, impls, methods


def parse_iface_dump(text: str):
    """解析 `--dump-ifaces` 输出（corec 与 corearch **同一条打印路径**，行格式
    契约见 ccr_io.cr:ccr_iface_surface_dump）。返回 dict；"ifacesig*" 节
    （corec-only 活算）另存 'sig'/'sigp'。"""
    out = {'natives': [], 'shapes': [], 'ifaces': [], 'method': [], 'mparam': [],
           'impls': [], 'gmethods': [], 'probe': None, 'sig': {}, 'sigp': {}}
    for ln in text.splitlines():
        m = P4T3_NATIVE_RE.match(ln)
        if m:
            out['natives'].append(tuple(int(m.group(k)) for k in range(2, 7)))
            continue
        m = P4T3_SHAPE_RE.match(ln)
        if m:
            out['shapes'].append((int(m.group(2)), int(m.group(3))))
            continue
        m = P4T3_IFACE_RE.match(ln)
        if m:
            out['ifaces'].append((int(m.group(2)), int(m.group(3)), int(m.group(4))))
            continue
        m = P4T3_METHOD_RE.match(ln)
        if m:
            out['method'].append((int(m.group(1)), int(m.group(2)), int(m.group(3)),
                                  int(m.group(4)), int(m.group(5)), int(m.group(6))))
            continue
        m = P4T3_MPARAM_RE.match(ln)
        if m:
            out['mparam'].append((int(m.group(1)), int(m.group(2)), int(m.group(3)),
                                  int(m.group(4)), int(m.group(5))))
            continue
        m = P4T3_IMPL_RE.match(ln)
        if m:
            out['impls'].append((int(m.group(2)), int(m.group(3))))
            continue
        m = P4T3_GMETHOD_RE.match(ln)
        if m:
            out['gmethods'].append((int(m.group(2)), int(m.group(3)), int(m.group(4))))
            continue
        m = P4T3_PROBE_RE.match(ln)
        if m:
            out['probe'] = tuple(int(m.group(k)) for k in range(1, 6))
            continue
        m = P4T3_SIG_RE.match(ln)
        if m:
            out['sig'][(int(m.group(1)), int(m.group(2)))] = (int(m.group(3)), int(m.group(4)))
            continue
        m = P4T3_SIGP_RE.match(ln)
        if m:
            out['sigp'][(int(m.group(1)), int(m.group(2)), int(m.group(3)))] = int(m.group(4))
            continue
    assert out['natives'], "iface dump has no 'native' lines"
    assert out['probe'] is not None, "iface dump has no 'ifaceprobe' line"
    return out


def corec_dump_ifaces(src: str, out: str) -> str:
    r = subprocess.run([COREC, 'ccr', src, '-o', out, '--dump-ifaces'],
                       capture_output=True, text=True, cwd=BASE, timeout=180)
    assert r.returncode == 0, \
        f"corec ccr --dump-ifaces failed rc={r.returncode}: {r.stdout}\n{r.stderr}"
    return r.stdout


def arch_dump_ifaces(ccr_in: str) -> str:
    r = subprocess.run([COREARCH, ccr_in, '--dump-ifaces'],
                       capture_output=True, text=True, cwd=BASE, timeout=180)
    assert r.returncode == 0, \
        f"corearch --dump-ifaces failed rc={r.returncode}: {r.stdout}\n{r.stderr}"
    return r.stdout


def str_table(data: bytes):
    """STR 段 → 串列表（ni → 串——跨段引用域断言的独立解析面）。"""
    off, size = CcrFile(data).segs[1]
    p = off
    (n,) = struct.unpack_from('<I', data, p)
    p += 4
    out = []
    for _ in range(n):
        (l,) = struct.unpack_from('<I', data, p)
        p += 4
        out.append(data[p:p + l].decode('utf-8', 'replace'))
        p += l
    assert p == off + size, "STR walk overran segment"
    return out


def iface_seg(data: bytes) -> bytes:
    return CcrFile(data).body(IFACE_TAG)


# 夹具源：2 接口（self 接收者 + &self + 带参方法）+ 1 结构 + impl 块
# （g_impl_for 边 + g_methods 方法表 + 接口方法签名项——五小节全非空）
_T3_SRC = ("interface Show { fn show(self) -> int; }\n"
           "interface Pair2 { fn first(&self) -> int; fn second(self, x: int) -> int; }\n"
           "struct S { a: int }\n"
           "impl Show for S { fn show(self: S) -> int { return 2; } }\n"
           "fn main() -> int { s := S { a = 2 }; return s.a; }\n")


def _t3_fixture(name: str):
    src_path = os.path.join(BASE, 'build', f'test_p4t3_{name}.cr')
    ccr_path = os.path.join(BASE, 'build', f'test_p4t3_{name}.ccr')
    for p in (src_path, ccr_path):
        try:
            os.unlink(p)
        except FileNotFoundError:
            pass
    with open(src_path, 'w') as fh:
        fh.write(_T3_SRC)
    corec_ccr(src_path, ccr_path)
    return src_path, ccr_path


def _resize_iface_tail(data: bytes, delta: int) -> bytes:
    """IFACE 段体尾增(+)/删(-) |delta| 字节（段表有尾随量可容纳时用——本段是末段，
    增删会改变文件长度；调用方负责只做「可容纳」的破坏）。"""
    d = bytearray(data)
    (i_off, i_size) = struct.unpack_from('<2I', d, 16 + 7 * 12 + 4)
    struct.pack_into('<I', d, 16 + 7 * 12 + 8, i_size + delta)
    cut = i_off + i_size
    if delta > 0:
        return bytes(d[:cut]) + b'\x00' * delta + bytes(d[cut:])
    return bytes(d[:cut + delta]) + bytes(d[cut:])


def test_p4t3_iface_segment_layout():
    """⑯ 五小节结构自洽：计数/长度逐小节与内存真值一致（native 16 == 扩列硬值、
    形状 6 == D17 生产注册面、接口/方法/impl/方法表逐条 == dump）+ 行走完 == 段体
    长度（无尾随字节）+ 逐记录不变量（ak ∈ 0..15、ti_row ∈ {-1} ∪ 行域、name_ni
    入 STR 域、term 入 TYPE 项域、self_mode ∈ 0..3）。"""
    src_path, ccr_path = _t3_fixture('layout')
    try:
        data = read_ccr(ccr_path)
        natives, shapes, ifaces, impls, methods = parse_iface_segment(iface_seg(data))
        names = str_table(data)
        rows, terms = parse_type_segment(type_seg(data))
        # ① 原生条目：扩列硬值 + 三新行（AK_NULL=15 / AK_SUM=9 / AK_FN=13）纯信息面
        assert len(natives) == IFACE_NATIVE_N, f"native count {len(natives)} != 16"
        aks = [r[0] for r in natives]
        assert len(set(aks)) == len(aks), f"duplicate ak rows: {aks}"
        new_rows = {r[0]: r for r in natives if r[0] in (15, 9, 13)}
        assert set(new_rows) == {15, 9, 13}, f"missing extended rows: {aks}"
        assert new_rows[15][4] == 0 and new_rows[9][4] == 0 and new_rows[13][4] == 0, \
            "extended rows must be pure-info (ops == 0)"
        assert new_rows[15][3] == -1 and new_rows[9][3] == -1 and new_rows[13][3] == -1, \
            "extended rows must have no lit_code"
        # ② 形状：6 条 D17 生产名（按 STR 解析，逐名）
        assert len(shapes) == 6, f"shape count {len(shapes)} != 6"
        sh_names = sorted(names[nm] for nm, _ in shapes)
        assert sh_names == sorted(IFACE_SHAPE_NAMES), f"shape names drifted: {sh_names}"
        # ③ 用户接口：夹具 2 接口 + Pair2 双方法；签名项槽逐条入域
        assert len(ifaces) == 2, f"iface count {len(ifaces)} != 2"
        for nm, mc, gc, pad, meths in ifaces:
            assert 0 <= nm < len(names)
            assert mc == len(meths) and 0 < mc <= 16
            for (mname, pc, sm, rt, pterms, pcodes) in meths:
                assert 0 <= mname < len(names)
                assert 0 <= pc <= 8 and 0 <= sm <= 3
                assert rt == -1 or 0 <= rt < len(terms), f"ret term {rt} out of domain"
                for t in pterms:
                    assert t == -1 or 0 <= t < len(terms), f"param term {t} out of domain"
                for c in pcodes:
                    assert c >= -1
        # ④ impl 边 + ⑤ 方法表：逐条 ni 入 STR 域
        assert len(impls) >= 1, "fixture has no impl edge"
        assert len(methods) >= 1, "fixture has no g_methods rows"
        for tr, ty in impls:
            assert 0 <= tr < len(names) and 0 <= ty < len(names)
        for ty, mn, mg in methods:
            assert 0 <= ty < len(names) and 0 <= mn < len(names) and 0 <= mg < len(names)
    finally:
        _cleanup(src_path, ccr_path)


def test_p4t3_bytes_match_corec_dump():
    """⑰ 段内五小节 == corec 侧 dump（内存真值）——写侧装填 + 序列化保真链
    （内存 → 缓冲 → 文件，Python 直解字节逐字段对拍）。"""
    src_path, ccr_path = _t3_fixture('rows')
    try:
        dump = corec_dump_ifaces(src_path, ccr_path)
        d = parse_iface_dump(dump)
        data = read_ccr(ccr_path)
        natives, shapes, ifaces, impls, methods = parse_iface_segment(iface_seg(data))
        assert [tuple(r) for r in natives] == [tuple(r) for r in d['natives']], \
            "file natives != memory natives"
        assert shapes == d['shapes'], "file shapes != memory shapes"
        assert impls == d['impls'], "file impls != memory impls"
        assert methods == d['gmethods'], "file g_methods != memory g_methods"
        # ③ 用户接口（含方法 80B 记录逐字段：项槽/裸码槽分别对拍）
        d_if = d['ifaces']
        d_me = [m for m in d['method']]
        d_mp = {(i, j, k): (c, t) for (i, j, k, c, t) in d['mparam']}
        assert len(ifaces) == len(d_if), "iface count drift"
        for i, (nm, mc, gc, pad, meths) in enumerate(ifaces):
            assert (nm, mc, gc) == d_if[i], f"iface {i} header drift"
            for j, (mname, pc, sm, rt, pterms, pcodes) in enumerate(meths):
                mrow = next(m for m in d_me if m[0] == i and m[1] == j)
                assert (mname, pc, sm, rt) == mrow[2:], f"method {i}.{j} drift"
                for k in range(8):
                    assert (pcodes[k], pterms[k]) == d_mp[(i, j, k)], \
                        f"method {i}.{j} param {k} slot drift"
    finally:
        _cleanup(src_path, ccr_path)


def test_p4t3_corearch_readback_parity():
    """⑱ 读回证据（spec §6.3）：corearch `--dump-ifaces` 与 corec 侧 dump 的共享节
    逐行一致（条目表/形状表/接口表/impl 边/方法表 + ifaceprobe 行——跨段项索引在
    重建项表上解析同值）；corec-only 的活算节（ifacesig*）只在写侧存在。"""
    src_path, ccr_path = _t3_fixture('par')
    try:
        corec_out = corec_dump_ifaces(src_path, ccr_path)
        arch_out = arch_dump_ifaces(ccr_path)
        c = parse_iface_dump(corec_out)
        a = parse_iface_dump(arch_out)
        for key in ('natives', 'shapes', 'ifaces', 'method', 'mparam', 'impls', 'gmethods'):
            assert c[key] == a[key], f"read-back {key} drifted"
        assert c['probe'] == a['probe'], \
            f"ifaceprobe diverged across processes: {c['probe']} vs {a['probe']}"
        assert c['probe'][3] == 0, f"cross-segment probe bad != 0: {c['probe']}"
        assert c['sig'] and not a['sig'], "ifacesig section must be corec-only"
        assert c['sigp'] and not a['sigp'], "ifacesigp section must be corec-only"
    finally:
        _cleanup(src_path, ccr_path)


def test_p4t3_signature_itemization_matches_live():
    """⑲ 签名项化：段内 ret_term/param_terms == corec 侧**活算**签名项
    （sh_iface_sig_ret_term/sh_iface_sig_param_term——缓冲构造后独立读点）⇒
    装填与签名来源零漂移；未用形参槽 = -1；接收者槽 = unit 占位项（>= 0）。"""
    src_path, ccr_path = _t3_fixture('sig')
    try:
        dump = corec_dump_ifaces(src_path, ccr_path)
        d = parse_iface_dump(dump)
        data = read_ccr(ccr_path)
        natives, shapes, ifaces, impls, methods = parse_iface_segment(iface_seg(data))
        for i, (nm, mc, gc, pad, meths) in enumerate(ifaces):
            for j, (mname, pc, sm, rt, pterms, pcodes) in enumerate(meths):
                live_ret, live_pc = d['sig'][(i, j)]
                assert live_pc == pc, f"live param count {live_pc} != file {pc}"
                assert rt == live_ret, \
                    f"method {i}.{j} ret term {rt} != live {live_ret}"
                for k in range(8):
                    if k < pc:
                        live = d['sigp'][(i, j, k)]
                        assert pterms[k] == live, \
                            f"method {i}.{j} param {k} term {pterms[k]} != live {live}"
                        assert live >= 0, f"live signature item unbuildable at {i}.{j}.{k}"
                    else:
                        assert (i, j, k) not in d['sigp'], \
                            "live section must not print unused param slots"
                        assert pterms[k] == -1, "unused param term slot must be -1"
        # 签名项确实**非空**（防「全 -1 空签名」假绿）：至少一个有效项 >= 0
        assert any(t >= 0 for _, _, _, _, ms in ifaces for m in ms for t in m[4]), \
            "no effective signature terms in fixture"
    finally:
        _cleanup(src_path, ccr_path)


def test_p4t3_shape_name_registration():
    """⑳ 形状命名化（裁决 1 + D17）：六生产名入段（name_ni → STR 解析逐名）+
    形状项在 TYPE 项域内（跨段引用域）；`shape` 行的 term 与接口轴 A 的
    形状项同域（判定 `arr <: 形状项` 语义见 selftest `x2.shape_builtin_names`）。"""
    src_path, ccr_path = _t3_fixture('shape')
    try:
        data = read_ccr(ccr_path)
        natives, shapes, ifaces, impls, methods = parse_iface_segment(iface_seg(data))
        names = str_table(data)
        rows, terms = parse_type_segment(type_seg(data))
        got = {names[nm]: term for nm, term in shapes}
        assert sorted(got) == sorted(IFACE_SHAPE_NAMES), f"shape names: {sorted(got)}"
        for nm, term in shapes:
            assert 0 <= term < len(terms), f"shape {nm} term {term} out of TYPE domain"
        # 形状项结构（与 iface_registry.cr 的构造点语义独立对拍）：顶层展开收集原子类
        # ——TT_TOP_K(2) → a = 原子类；TT_UNION(3) → 两操作数；TT_ATOM(7) → a = 原子类。
        # 期望值 = 六形状的**语义定义**（D17/spec §2.2）：序列本体 = ⊤_SEQUENCE；
        # 只读 = 序列 ∪ ref 视图（AK_REF=11）；可索引 = 序列 ∪ 字符串（AK_STRING=2）；
        # product = ⊤_PRODUCT（AK_PRODUCT=8）。
        AK_STRING, AK_PRODUCT, AK_SEQUENCE, AK_REF = 2, 8, 10, 11
        exp = {'sequence': sorted([AK_SEQUENCE]),
               'sequence_ro': sorted([AK_SEQUENCE, AK_REF]),
               'sequence_rw': sorted([AK_SEQUENCE]),
               'indexable': sorted([AK_SEQUENCE, AK_STRING]),
               'iterable': sorted([AK_SEQUENCE]),
               'product': sorted([AK_PRODUCT])}

        def top_classes(ti):
            tag, a, b = terms[ti][0], terms[ti][1], terms[ti][2]
            if tag == 2:      # TT_TOP_K
                return [a], tag
            if tag == 7:      # TT_ATOM
                return [a], tag
            if tag == 3:      # TT_UNION：两操作数各递归（各为 TOP_K/ATOM）
                out = []
                for op in (a, b):
                    assert 0 <= op < len(terms), f"union operand {op} out of domain"
                    sub, _ = top_classes(op)
                    out.extend(sub)
                return sorted(out), tag
            raise AssertionError(f"unexpected shape term tag {tag}")

        for nm, term in shapes:
            classes, tag = top_classes(term)
            assert classes == exp[names[nm]], \
                f"shape {names[nm]} classes {classes} != expected {exp[names[nm]]}"
    finally:
        _cleanup(src_path, ccr_path)


def test_p4t3_cross_process_term_probe():
    """㉑ 跨段引用域探针：`ifaceprobe` 行的 slots == Σ(方法数 × (1 + pc))、
    built + unbuilt == slots、bad == 0，且逐槽 **解析摘要跨进程同值**
    （corec 与 corearch 两侧 digest 同 ⇒ 段内项索引在重建项表上解析到同构项）。"""
    src_path, ccr_path = _t3_fixture('probe')
    try:
        corec_out = corec_dump_ifaces(src_path, ccr_path)
        arch_out = arch_dump_ifaces(ccr_path)
        c = parse_iface_dump(corec_out)
        a = parse_iface_dump(arch_out)
        data = read_ccr(ccr_path)
        natives, shapes, ifaces, impls, methods = parse_iface_segment(iface_seg(data))
        exp_slots = sum(1 + m[1] for _, _, _, _, ms in ifaces for m in ms)
        for probe, tag in ((c['probe'], 'corec'), (a['probe'], 'corearch')):
            slots, built, unbuilt, bad, digest = probe
            assert slots == exp_slots >= 1, \
                f"{tag}: probe slots {slots} != expected {exp_slots}"
            assert built + unbuilt == slots, f"{tag}: built+unbuilt != slots"
            assert bad == 0, f"{tag}: cross-segment probe bad {bad} != 0"
        assert c['probe'][4] == a['probe'][4], \
            f"probe digest diverged: {c['probe']} vs {a['probe']}"
    finally:
        _cleanup(src_path, ccr_path)


def test_p4t3_loader_rejects_iface_mutations():
    """㉒ loader 负分支（跨段引用域 + 结构闸 + 尾随字节，逐个 byte mutation
    → 必须拒绝，不得静默接受）：
      · native_count := 15（≠ 扩列硬值）
      · 形状行的 term 越 TYPE 项域（term := tt+1）
      · 接口方法 ret_term 越 TYPE 项域
      · 方法名的 name_ni 越 STR 串数
      · 段体尾插 4B 垃圾（五小节行走完 ≠ 段体长）
      · 段体尾截 4B（计数 × 记录尺寸 > 段余量）
    """
    src_path, ccr_path = _t3_fixture('mut')
    try:
        data = read_ccr(ccr_path)
        c = CcrFile(data)
        i_off, i_size = c.segs[IFACE_TAG]
        natives, shapes, ifaces, impls, methods = parse_iface_segment(iface_seg(data))
        rows, terms = parse_type_segment(type_seg(data))
        names = str_table(data)
        sh_off = i_off + 4 + len(natives) * IFACE_ENTRY_DISK
        if_off = sh_off + 4 + len(shapes) * IFACE_SHAPE_DISK
        # ③ 第一节：夹具首接口首方法记录基址
        rec = if_off + 4 + 16
        muts = {}
        d = bytearray(data)
        struct.pack_into('<I', d, i_off, IFACE_NATIVE_N - 1)          # native_count
        muts['nativecnt'] = bytes(d)
        d = bytearray(data)
        struct.pack_into('<i', d, sh_off + 4 + 4, len(terms) + 1)     # shape term oob
        muts['shapeterm'] = bytes(d)
        d = bytearray(data)
        struct.pack_into('<i', d, rec + 12, len(terms) + 1)           # ret_term oob
        muts['retterm'] = bytes(d)
        d = bytearray(data)
        struct.pack_into('<i', d, rec, len(names) + 5)                # method name ni oob
        muts['nameni'] = bytes(d)
        muts['trail'] = _resize_iface_tail(data, 4)
        muts['trunc'] = _resize_iface_tail(data, -4)
        for name, mdata in muts.items():
            bad = ccr_path + f'.{name}'
            _write(bad, mdata)
            try:
                arch_elf(bad, os.path.join(BASE, 'build/test_p4t3_mut.out'),
                         must_fail=True)
            finally:
                _cleanup(bad)
    finally:
        _cleanup(src_path, ccr_path, os.path.join(BASE, 'build/test_p4t3_mut.out'))


def test_p4t3_dump_flag_zero_artifact_effect():
    """㉓ `--dump-ifaces` 是**只读通道**：带/不带 flag 的 .ccr 逐字节同
    （活算节在段体缓冲构造**之后**运行，不得泄入序列化面）。"""
    src_path, ccr_path = _t3_fixture('flag')
    with_dump = ccr_path + '.dump'
    try:
        corec_ccr(src_path, ccr_path)
        corec_dump_ifaces(src_path, with_dump)
        assert read_ccr(ccr_path) == read_ccr(with_dump), \
            "--dump-ifaces changed the emitted .ccr"
    finally:
        _cleanup(src_path, ccr_path, with_dump)


def test_p4t3_determinism_cold_cold():
    """㉔ 确定性（D13 对 IFACE 段的直接守门）：同源两次**冷缓存**编译 ⇒ IFACE 段
    逐字节同（且整 .ccr 逐字节同——形状重注册/条目注册名/签名装填皆纯函数）。"""
    cache_dir = os.path.join(BASE, '.core', 'cache')
    src_path, ccr_path = _t3_fixture('det')
    a = ccr_path + '.a'
    b = ccr_path + '.b'
    try:
        for out in (a, b):
            shutil.rmtree(cache_dir, ignore_errors=True)
            corec_ccr(src_path, out)
        da, db = read_ccr(a), read_ccr(b)
        assert iface_seg(da) == iface_seg(db), "IFACE segment not deterministic"
        assert type_seg(da) == type_seg(db), "TYPE segment not deterministic"
        assert da == db, ".ccr drifted between two cold builds"
    finally:
        _cleanup(src_path, ccr_path, a, b)


def test_p4t3_cold_warm_iface_segment():
    """㉕ 冷/热两态（缓存不变量语料 = 夹具源：.cir 命中不改变类型行/接口表）⇒
    IFACE + TYPE 段体逐字节同；命中证据 = 暖运行不重写缓存文件。"""
    cache_dir = os.path.join(BASE, '.core', 'cache')
    cir_dir = os.path.join(cache_dir, 'cir')
    src_path, ccr_path = _t3_fixture('cw')
    cold = ccr_path + '.cold'
    warm = ccr_path + '.warm'
    try:
        shutil.rmtree(cache_dir, ignore_errors=True)
        corec_ccr(src_path, cold)
        snap = {os.path.join(cir_dir, f): os.stat(
                    os.path.join(cir_dir, f)).st_mtime_ns
                for f in os.listdir(cir_dir)}
        assert snap, "cold run did not populate cir cache"
        corec_ccr(src_path, warm)
        for p, ns in snap.items():
            assert os.stat(p).st_mtime_ns == ns, \
                f"warm run rewrote cache file {p} (not a full hit?)"
        dc, dw = read_ccr(cold), read_ccr(warm)
        assert iface_seg(dc) == iface_seg(dw), "IFACE drifted cold->warm"
        assert type_seg(dc) == type_seg(dw), "TYPE drifted cold->warm"
        for tag in (2, 3, 4, 5, 6):
            assert CcrFile(dc).body(tag) == CcrFile(dw).body(tag), \
                f"segment {tag} drifted cold->warm"
    finally:
        _cleanup(src_path, ccr_path, cold, warm)
        shutil.rmtree(cache_dir, ignore_errors=True)


def _cleanup(*paths):
    for p in paths:
        try:
            os.unlink(p)
        except FileNotFoundError:
            pass


if __name__ == '__main__':
    tests = [test_p4t1_layout_eight_segments,
             test_p4t1_loader_rejects_valid_v7_file,
             test_p4t1_loader_rejects_missing_type_iface,
             test_p4t1_loader_rejects_tag_mutations,
             test_p4t1_loader_rejects_nonempty_shell,
             test_p4t1_loader_rejects_truncated_body,
             test_p4t1_end_to_end_shells,
             test_p4t1_cold_warm_shell_stability,
             test_p4t2_type_segment_layout,
             test_p4t2_rows_and_terms_match_corec_dump,
             test_p4t2_corearch_readback_parity,
             test_p4t2_dag_dedup_topology,
             test_p4t2_dump_flag_zero_artifact_effect,
             test_p4t2_loader_rejects_topology_violation,
             test_p4t2_loader_accepts_annotation_slot,
             test_p4t2_loader_rejects_count_and_truncation,
             test_p4t2_determinism_cold_cold,
             test_p4t2_cold_warm_type_segment,
             test_p4t3_iface_segment_layout,
             test_p4t3_bytes_match_corec_dump,
             test_p4t3_corearch_readback_parity,
             test_p4t3_signature_itemization_matches_live,
             test_p4t3_shape_name_registration,
             test_p4t3_cross_process_term_probe,
             test_p4t3_loader_rejects_iface_mutations,
             test_p4t3_dump_flag_zero_artifact_effect,
             test_p4t3_determinism_cold_cold,
             test_p4t3_cold_warm_iface_segment]
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
