#!/usr/bin/env python3
"""v7 .ccr 真图载体 IO 测试（实施计划 Task 1：骨架——version 7 + NOD 36B 邻接
+ EDG 段必落，v6 读路径退役）。

字节真相 = docs/superpowers/specs/2026-09-09-lattice-ir-v7-format.md：
  [0]   magic u32 = 0x31524343 ("CCR1")
  [4]   version u32 = 7
  [8]   seg_count u32 = 6
  [12]  reserved u32 = 0
  [16]  段表 6 × 12B {tag u32, offset u32, size u32}（规范序 tag 1..6）
  [88]  段体（tag 升序连续）：STR(1) / SYM(2) / NOD(3) / ENT(4) / REG(5) / EDG(6)
  STR/SYM/ENT/REG = v6 布局不变（ENT 恒空——Task 2 翻转）
  NOD(3): nod_count + 36B × nod_count
          {op i32, dest i32, s1 i64, s2 i32, s3 i32, tk i32,
           first_edge u32, edge_count u32}
  EDG(6): edg_count + 8B × edg_count {to_nod u32, kind u32}
          节点出边按节点序连续成段（first_edge = 前缀累计——流式零索引重建）；
          每条边 to_nod > 所属节点（数据/state 前向——DAG 拓扑不变量）。

幽灵边修复（Task 0 盘点注 A 裁决——播种修复）后的 EDG 内容语义：
  g_df_var_producer 槽对全部 var 下标恒 -1 播种（未定值 var——全局/参数/
  0 字面量槽——不产数据边）；EDG 数据边 = 纯 def-use（定值节点 → 消费节点，
  平行边不合并）；state 边（kind=1）不变。测试期望 = 表一「去幽灵后」形态
  （期望值派生：对现 v6 线性 NOD 流按 df_connect_srcs 语义重放（Python 侧
  独立模型）+ 幽灵边去除 + state 链按现状（不受播种修复影响）——实现前
  从当前编译器产物导出并锁定，见 test_v7_edge_content_small_program）。
"""
import os
import shutil
import struct
import subprocess
import tempfile

BASE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
COREC = os.path.join(BASE, 'build/corec')
COREARCH = os.path.join(BASE, 'build/corearch')

MAGIC = 0x31524343  # "CCR1"
V7 = 7
SEG_TAGS = [1, 2, 3, 4, 5, 6]  # STR SYM NOD ENT REG EDG
NOD_REC = 36
ENT_REC = 28
REG_REC = 24
EDG_REC = 8
HEADER_TABLE = 16 + 6 * 12  # 88

# 源程序 span 内（pure_add + main 两函数，节点 0..44）期望 EDG 内容——见
# test_v7_edge_content_small_program 的派生说明。
EXPECT_SRC_SPAN = 45  # 源函数节点范围 [0, 45)：pure_add 0..5、main 5..45
# 数据边（kind=0）= {from: [to...]}——纯 def-use（表一「去幽灵后」）；
# 播种修复前这些集合还混有幽灵边 0→X（参数读/0 字面量槽/自环 (0,0)）——
# 断言精确集合即回归网：幽灵边回归 = 集合多出边，立即失败。
EXPECT_DATA = {
    0: [3], 1: [2],
    5: [43],
    6: [16, 24, 27, 30, 39],
    7: [9, 11, 13, 15, 16],
    8: [9], 10: [11], 12: [13], 14: [15],
    17: [19, 23, 24, 29, 30],
    18: [19], 20: [22], 21: [22],
    24: [26, 34], 25: [26], 26: [27],
    28: [31, 33], 30: [31],
    32: [38, 40, 41, 42],
    35: [36], 36: [37], 37: [38], 39: [40], 40: [41],
}
# state 边（kind=1）= STORE 族副作用链（程序序，创建序前向）——播种修复
# 不触及 state 链，期望 = 现状（buggy dump 的 dashed 集逐条核对一致）。
EXPECT_STATE = {
    9: [11], 11: [13], 13: [15], 15: [16], 16: [19], 19: [22],
    22: [24], 24: [27], 27: [31], 31: [33], 33: [34], 34: [38], 38: [41],
}
assert sum(len(v) for v in EXPECT_DATA.values()) == 41, "expectation table drift"
assert sum(len(v) for v in EXPECT_STATE.values()) == 13, "expectation table drift"


class V7File:
    """Parse a v7 .ccr file into its segments. Raises AssertionError on layout
    violations (mirrors load_ccr's segment-table contract)."""

    def __init__(self, data: bytes):
        self.d = data
        assert len(data) >= HEADER_TABLE, f"file too small for v7 header+table: {len(data)}"
        (magic, ver, seg_count, reserved) = struct.unpack_from('<4I', data, 0)
        assert magic == MAGIC, f"bad magic {magic:#x}"
        assert ver == V7, f"expected version {V7}, got {ver}"
        assert seg_count == 6, f"expected 6 segments, got {seg_count}"
        assert reserved == 0, f"reserved != 0: {reserved}"
        # Segment table: canonical order, contiguous layout
        self.segs = {}
        cur = HEADER_TABLE  # first body follows the whole table
        for i, tag in enumerate(SEG_TAGS):
            (t, off, size) = struct.unpack_from('<3I', data, 16 + i * 12)
            assert t == tag, f"row {i}: expected tag {tag}, got {t}"
            assert off == cur, f"tag {tag}: expected offset {cur}, got {off}"
            assert off + size <= len(data), f"tag {tag}: body out of file"
            self.segs[tag] = (off, size)
            cur = off + size
        assert cur == len(data), f"segments end at {cur} of {len(data)} bytes"
        self.fsize = len(data)

    def body(self, tag: int):
        off, size = self.segs[tag]
        return self.d[off:off + size]

    # --- segment record walkers (each body starts with its count) ---

    def str_table(self):
        b = self.body(1)
        (n,) = struct.unpack_from('<I', b, 0)
        pos = 4
        strs = []
        for _ in range(n):
            (ln,) = struct.unpack_from('<I', b, pos)
            pos += 4
            strs.append(b[pos:pos + ln].decode('utf-8', 'replace'))
            pos += ln
        assert pos == len(b), f"STR walk ended at {pos} of {len(b)}"
        return strs

    def sym_parse(self):
        """SYM body: globals → funcs (embedded var-decl areas) → str_consts →
        structs → enums → opt_meta. Asserts end == body size. (v6 布局不变)"""
        b = self.body(2)
        pos = 0

        def u32():
            nonlocal pos
            v = struct.unpack_from('<I', b, pos)[0]
            pos += 4
            return v

        g = u32()
        globals_ = []
        for _ in range(g):
            (name, ty, init) = struct.unpack_from('<IIq', b, pos)
            pos += 16
            globals_.append({'name': name, 'type': ty, 'init': init})
        n = u32()
        funcs = []
        for _ in range(n):
            (name, pc, rt, root, fe, le) = struct.unpack_from('<IIiiii', b, pos)
            pos += 24
            param_ents = []
            for _ in range(pc):
                param_ents.append(struct.unpack_from('<i', b, pos)[0])
                pos += 4
            vc = u32()
            decls = []
            for _ in range(vc):
                (vn, vt) = struct.unpack_from('<II', b, pos)
                pos += 8
                decls.append({'name': vn, 'type': vt})
            funcs.append({'name': name, 'param_count': pc, 'ret_type': rt,
                          'root_region': root, 'first_ent': fe, 'last_ent': le,
                          'param_ents': param_ents, 'var_count': vc,
                          'var_decls': decls})
        scn = u32()
        pos += scn * 4
        stn = u32()
        for _ in range(stn):
            u32()
            fc = u32()
            pos += fc * 8
        en = u32()
        for _ in range(en):
            u32()
            vc2 = u32()
            for _ in range(vc2):
                u32()
                tc = u32()
                pos += tc * 4
        oc = u32()
        for _ in range(oc):
            u32()
            dl = u32()
            pos += dl
        assert pos == len(b), f"SYM walk ended at {pos} of {len(b)}"
        return {'globals': globals_, 'funcs': funcs,
                'str_const_count': scn, 'struct_count': stn,
                'enum_count': en, 'opt_count': oc}

    def nod(self):
        """NOD 36B: {op, dest, s1, s2, s3, tk, first_edge, edge_count} —
        adjacency indices first_edge/edge_count (validated against EDG by the
        walker / tests; loader rebuilds the linear stream from the 28B semantic
        fields, emission input identical to v6)."""
        b = self.body(3)
        (n,) = struct.unpack_from('<I', b, 0)
        assert (len(b) - 4) % NOD_REC == 0, "NOD body size not a multiple of 36"
        assert n == (len(b) - 4) // NOD_REC, f"NOD count {n} != bytes/36"
        pos = 4
        out = []
        for _ in range(n):
            (op, dest) = struct.unpack_from('<Ii', b, pos)
            (s1,) = struct.unpack_from('<q', b, pos + 8)
            (s2, s3) = struct.unpack_from('<ii', b, pos + 16)
            (tk,) = struct.unpack_from('<I', b, pos + 24)
            (fe, ec) = struct.unpack_from('<II', b, pos + 28)
            out.append((op, dest, s1, s2, s3, tk, fe, ec))
            pos += NOD_REC
        return out

    def ent(self):
        b = self.body(4)
        (n,) = struct.unpack_from('<I', b, 0)
        assert (len(b) - 4) % ENT_REC == 0, "ENT body size not a multiple of 28"
        pos = 4
        out = []
        for _ in range(n):
            out.append(struct.unpack_from('<iIiIIiI', b, pos))
            pos += ENT_REC
        return out

    def reg(self):
        b = self.body(5)
        (n,) = struct.unpack_from('<I', b, 0)
        assert (len(b) - 4) % REG_REC == 0, "REG body size not a multiple of 24"
        assert n == (len(b) - 4) // REG_REC, f"REG count {n} != bytes/24"
        pos = 4
        out = []
        for _ in range(n):
            out.append(struct.unpack_from('<6i', b, pos))
            pos += REG_REC
        return out

    def edg(self):
        """EDG records parsed + per-node run reconstruction + v7 §4 不变量
        校验（镜像 load_ccr 的 EDG 校验）：
          - 节点 i 出边运行 = [first_edge, first_edge+edge_count)，连续邻接
            （节点 i+1 first_edge == 前节点 first_edge + edge_count）；
          - Σ edge_count == edg_count；行走完 == 段体大小；
          - 每条边 to_nod > 所属节点（前向拓扑）；kind ∈ {0=数据, 1=state}。
        返回 edges: {node: [(to, kind), ...]}（文件序）。"""
        b = self.body(6)
        nod = self.nod()
        n = len(nod)
        (edg_cnt,) = struct.unpack_from('<I', b, 0)
        assert (len(b) - 4) % EDG_REC == 0, "EDG body size not a multiple of 8"
        assert edg_cnt == (len(b) - 4) // EDG_REC, \
            f"EDG count {edg_cnt} != bytes/8"
        pos = 4
        edges = {}
        run_off = 0
        for i in range(n):
            (fe, ec) = nod[i][6:8]
            assert fe == run_off, \
                f"node {i}: first_edge {fe} != cumulative offset {run_off}"
            assert run_off + ec <= edg_cnt, \
                f"node {i}: run [{run_off},{run_off + ec}) exceeds edg_count {edg_cnt}"
            row = []
            for _ in range(ec):
                (to, kind) = struct.unpack_from('<II', b, pos)
                pos += EDG_REC
                assert to > i, \
                    f"edge {i}->{to} violates forward invariant (to_nod <= node)"
                assert kind <= 1, f"edge {i}->{to}: unknown kind {kind}"
                row.append((to, kind))
            if row:
                edges[i] = row
            run_off += ec
        assert run_off == edg_cnt, \
            f"Σ edge_count {run_off} != edg_count {edg_cnt}"
        assert pos == len(b), f"EDG walk ended at {pos} of {len(b)}"
        return edges


def corec_ccr(src: str, out: str) -> str:
    """Run `corec ccr` on src (unique temp path per call → cache miss →
    fresh deterministic compile); returns stdout."""
    with tempfile.NamedTemporaryFile('w', suffix='.cr', delete=False) as f:
        f.write(src)
        path = f.name
    try:
        r = subprocess.run([COREC, 'ccr', path, '-o', out],
                           capture_output=True, text=True, cwd=BASE, timeout=120)
        assert r.returncode == 0, f"corec ccr failed rc={r.returncode}: {r.stderr}"
        return r.stdout
    finally:
        os.unlink(path)


def read_ccr(path: str) -> bytes:
    with open(path, 'rb') as fh:
        return fh.read()


# --- tests ---

PROBE_SRC = (
    "fn pure_add(a: int, b: int) -> int { return a + b; }\n"
    "fn main() -> int {\n"
    "    arr : [int; 4], mut = [0, 0, 0, 0];\n"
    "    i : int = 1;\n"
    "    v : int = 9;\n"
    "    arr[i] = v;\n"
    "    arr[0] = v + 1;\n"
    "    x := arr[i];\n"
    "    s : int = pure_add(x, v);\n"
    "    s = s + arr[0];\n"
    "    return s;\n"
    "}\n")


def test_v7_layout_and_walk():
    """段表架构：magic/version=7/6 段规范序（EDG=tag 6 必落）/offset 连续/
    NOD 36B + 邻接域/EDG 段完整走查 == 文件大小。"""
    src = ("fn add(a: int, b: int) -> int { return a + b; }\n"
           "fn main() -> int {\n"
           "    s : ., mut = 0;\n"
           "    for i in 0..4 { s = s + i; }\n"
           "    return s;\n"
           "}\n")
    ccr_path = os.path.join(BASE, 'build/test_v7_layout.ccr')
    for p in (ccr_path,):
        try:
            os.unlink(p)
        except FileNotFoundError:
            pass
    try:
        corec_ccr(src, ccr_path)
        v7 = V7File(read_ccr(ccr_path))
        assert v7.fsize > HEADER_TABLE
        assert len(v7.str_table()) >= 2
        sym = v7.sym_parse()  # validates the full SYM body layout
        assert len(sym['funcs']) >= 1 and len(sym['globals']) >= 1
        n = v7.nod()
        assert len(n) > 4, f"expected nodes, got {len(n)}"
        assert len(v7.reg()) >= 2
        e = v7.ent()
        assert e == [], "ENT not empty (Task 1: ENT still empty until Task 2)"
        edg = v7.edg()  # full EDG walk + forward/kind invariant checks
        # EDG 段必落且至少一条边（每函数 arena_new→arena_reset def-use 存在）
        assert sum(len(v) for v in edg.values()) >= 2, \
            f"EDG unexpectedly small: {edg}"
    finally:
        try:
            os.unlink(ccr_path)
        except FileNotFoundError:
            pass


def test_v7_edge_content_small_program():
    """EDG 内容 = 表一「去幽灵后」形态（Task 0 注 A 裁决语义）——源程序两函数
    （pure_add/main，节点 0..44 = 文件前 45 节点——源函数先于 stdlib 模块函数
    编译，节点编号稳定）的精确边集合：

    期望派生（实现前锁定）：对当前 v6 编译产物 NOD 线性流按 df_connect_srcs
    opcode 语义 + g_df_var_producer 播种后语义（producer = 最近定值节点，未
    定值 = -1——幽灵边缺陷修复后）重放 —— Python 侧独立模型（df 语义镜像）
    与 buggy .cir dump 交叉核对：模型边 ⊆ buggy 实发边，差集 = 幽灵边
    （全 0→X 形态：参数读/0 字面量槽/自环 (0,0)）——即修复将去除的边。
    state 边（kind=1）= 现状不变（播种修复不触及 state 链机制）。

    断言 = 精确多重集合——幽灵边回归（如播种回退）→ 集合多出 0→X/自环边，
    立即失败。"""
    ccr_path = os.path.join(BASE, 'build/test_v7_edges.ccr')
    try:
        os.unlink(ccr_path)
    except FileNotFoundError:
        pass
    try:
        corec_ccr(PROBE_SRC, ccr_path)
        v7 = V7File(read_ccr(ccr_path))
        strs = v7.str_table()
        sym = v7.sym_parse()
        funcs = sym['funcs']
        regs = v7.reg()
        # 源函数定位（SYM func 记录按声明序：pure_add = func0、main = func1）
        names = [strs[f['name']] for f in funcs]
        assert names[0] == 'pure_add', f"func0 = {names[0]!r}"
        assert names[1] == 'main', f"func1 = {names[1]!r}"
        # root region 行（kind=0）按函数序 1:1 —— span = 节点范围
        roots = [i for i, r in enumerate(regs) if r[0] == 0]
        assert roots[0] == funcs[0]['root_region']
        assert roots[1] == funcs[1]['root_region']
        span_pure = (regs[roots[0]][2], regs[roots[0]][3])  # pure_add
        span_main = (regs[roots[1]][2], regs[roots[1]][3])  # main
        assert span_pure[1] == span_main[0] == 5
        assert span_main[1] == EXPECT_SRC_SPAN, \
            f"main span {span_main} != expected end {EXPECT_SRC_SPAN}"
        assert len(v7.nod()) >= EXPECT_SRC_SPAN

        edges = v7.edg()
        # 源节点域出边 = 期望集（data ∪ state 按 kind 分类）
        got_data = {f: sorted(t for (t, k) in row if k == 0)
                    for f, row in edges.items() if f < EXPECT_SRC_SPAN}
        got_state = {f: sorted(t for (t, k) in row if k == 1)
                     for f, row in edges.items() if f < EXPECT_SRC_SPAN}
        got_data = {f: ts for f, ts in got_data.items() if ts}
        got_state = {f: ts for f, ts in got_state.items() if ts}
        assert got_data == EXPECT_DATA, \
            f"data edges mismatch:\n  got      {got_data}\n  expected {EXPECT_DATA}"
        assert got_state == EXPECT_STATE, \
            f"state edges mismatch:\n  got      {got_state}\n  expected {EXPECT_STATE}"
        # 域内无跨函数数据边（def-use 不出函数——全局/参数无生产者）
        for f, row in edges.items():
            if f < EXPECT_SRC_SPAN:
                for (t, k) in row:
                    if k == 0:
                        assert t < EXPECT_SRC_SPAN, \
                            f"data edge {f}->{t} escapes source span"
    finally:
        try:
            os.unlink(ccr_path)
        except FileNotFoundError:
            pass


def test_v7_loader_rejects_version_ne_7():
    """v7-only：version 改成 6（v6 读路径退役——旧文件直接拒绝）或任意非 7
    → corearch 必须拒绝。"""
    src = "fn main() -> int { return 42; }\n"
    ccr_path = os.path.join(BASE, 'build/test_v7_reject.ccr')
    try:
        os.unlink(ccr_path)
    except FileNotFoundError:
        pass
    try:
        corec_ccr(src, ccr_path)
        for bad_ver in (6, 5, 8):
            data = bytearray(read_ccr(ccr_path))
            struct.pack_into('<I', data, 4, bad_ver)  # patch version
            bad_path = ccr_path + f'.v{bad_ver}'
            with open(bad_path, 'wb') as fh:
                fh.write(bytes(data))
            r = subprocess.run([COREARCH, bad_path, '--elf', '--static',
                                '-o', os.path.join(BASE, 'build/test_v7_reject.out')],
                               capture_output=True, text=True, cwd=BASE, timeout=60)
            assert r.returncode != 0, \
                f"corearch accepted version-{bad_ver}-patched file: rc={r.returncode}"
            assert 'invalid' in (r.stdout + r.stderr), \
                f"expected invalid-.ccr error, got: {r.stdout!r} {r.stderr!r}"
    finally:
        for p in (ccr_path, ccr_path + '.v6', ccr_path + '.v5', ccr_path + '.v8',
                  os.path.join(BASE, 'build/test_v7_reject.out')):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


def test_v7_loader_rejects_backward_edge():
    """拓扑不变量（v7 §4 规则 1）：EDG 边 to_nod 必须 > 所属节点——byte
    mutation 把 node 0 唯一出边（0→3 arena def-use）的 to_nod 改成 0（自环）
    → corearch 必须拒绝（'invalid .ccr'）。"""
    src = "fn main() -> int { return 42; }\n"
    ccr_path = os.path.join(BASE, 'build/test_v7_selfloop.ccr')
    try:
        os.unlink(ccr_path)
    except FileNotFoundError:
        pass
    try:
        corec_ccr(src, ccr_path)
        data = bytearray(read_ccr(ccr_path))
        v7 = V7File(bytes(data))
        nod = v7.nod()
        assert nod[0][7] >= 1, f"node 0 has no out edges: {nod[0]}"
        edg_off, _ = v7.segs[6]
        # node 0 的 EDG 记录 = edg_count(4B) 后第一条：to_nod 字段 = 前 4B
        struct.pack_into('<I', data, edg_off + 4, 0)  # to_nod := 0 → (0,0) 自环
        bad_path = ccr_path + '.loop'
        with open(bad_path, 'wb') as fh:
            fh.write(bytes(data))
        r = subprocess.run([COREARCH, bad_path, '--elf', '--static',
                            '-o', os.path.join(BASE, 'build/test_v7_selfloop.out')],
                           capture_output=True, text=True, cwd=BASE, timeout=60)
        assert r.returncode != 0, \
            f"corearch accepted backward (self-loop) edge: rc={r.returncode}"
        assert 'invalid' in (r.stdout + r.stderr), \
            f"expected invalid-.ccr error, got: {r.stdout!r} {r.stderr!r}"
    finally:
        for p in (ccr_path, ccr_path + '.loop',
                  os.path.join(BASE, 'build/test_v7_selfloop.out')):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


def test_v7_loader_rejects_edg_count_mismatch():
    """Σ 校验（v7 §4 规则 3）：NOD edge_count 总和 ≠ EDG edg_count → corearch
    必须拒绝。byte mutation：node 0 edge_count 1 → 2（EDG 段未加记录）。"""
    src = "fn main() -> int { return 42; }\n"
    ccr_path = os.path.join(BASE, 'build/test_v7_edgcnt.ccr')
    try:
        os.unlink(ccr_path)
    except FileNotFoundError:
        pass
    try:
        corec_ccr(src, ccr_path)
        data = bytearray(read_ccr(ccr_path))
        v7 = V7File(bytes(data))
        nod = v7.nod()
        assert nod[0][7] >= 1, f"node 0 has no out edges: {nod[0]}"
        nod_off, _ = v7.segs[3]
        row0_ec = nod_off + 4 + 0 * NOD_REC + 32  # edge_count field (+32 in 36B row)
        struct.pack_into('<I', data, row0_ec, nod[0][7] + 1)
        bad_path = ccr_path + '.cnt'
        with open(bad_path, 'wb') as fh:
            fh.write(bytes(data))
        r = subprocess.run([COREARCH, bad_path, '--elf', '--static',
                            '-o', os.path.join(BASE, 'build/test_v7_edgcnt.out')],
                           capture_output=True, text=True, cwd=BASE, timeout=60)
        assert r.returncode != 0, \
            f"corearch accepted Σ edge_count != edg_count: rc={r.returncode}"
        assert 'invalid' in (r.stdout + r.stderr), \
            f"expected invalid-.ccr error, got: {r.stdout!r} {r.stderr!r}"
    finally:
        for p in (ccr_path, ccr_path + '.cnt',
                  os.path.join(BASE, 'build/test_v7_edgcnt.out')):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


def test_v7_roundtrip_elf():
    """v7 落盘 → corec build 全链路（corec save v7 → corearch load v7 → ELF）：
    0+1+2+3+4+5 = 15 → ELF 退出码 15；corearch 直载同文件同结果；中间产物 =
    v7（version 7/EDG 必落/走查全绿）。"""
    src = ("fn main() -> int {\n"
           "    s : ., mut = 0;\n"
           "    for i in 0..6 { s = s + i; }\n"
           "    return s;\n"
           "}\n")
    ccr_path = os.path.join(BASE, 'build/test_v7_rt.ccr')
    out = os.path.join(BASE, 'build/test_v7_rt')
    with tempfile.NamedTemporaryFile('w', suffix='.cr', delete=False) as f:
        f.write(src)
        path = f.name
    try:
        for p in (ccr_path, out, out + '2'):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass
        r = subprocess.run([COREC, 'build', path, '-o', out, '--static'],
                           capture_output=True, text=True, cwd=BASE, timeout=120)
        assert r.returncode == 0, f"corec build failed: {r.stderr}"
        os.chmod(out, 0o755)
        run = subprocess.run([out], capture_output=True, text=True, timeout=10)
        assert run.returncode == 15, \
            f"expected exit 15 (sum 0..5), got {run.returncode} stdout={run.stdout!r}"
        assert os.path.exists(ccr_path), "corec build did not save .ccr alongside output"
        data = read_ccr(ccr_path)
        v7 = V7File(data)  # built artifact is v7: header/segments/NOD36/EDG walk
        assert v7.ent() == [], "built .ccr should carry no ENT (Task 1: empty until Task 2)"
        assert sum(len(v) for v in v7.edg().values()) >= 2
        # direct corearch invocation on the same .ccr
        r = subprocess.run([COREARCH, ccr_path, '--elf', '--static', '-o', out + '2'],
                           capture_output=True, text=True, cwd=BASE, timeout=120)
        assert r.returncode == 0, f"corearch load v7 failed: {r.stdout} {r.stderr}"
        os.chmod(out + '2', 0o755)
        run2 = subprocess.run([out + '2'], capture_output=True, text=True, timeout=10)
        assert run2.returncode == 15, \
            f"corearch-only run expected 15, got {run2.returncode} stdout={run2.stdout!r}"
    finally:
        os.unlink(path)
        for p in (ccr_path, out, out + '2'):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


if __name__ == '__main__':
    shutil.rmtree(os.path.join(BASE, '.core', 'cache'), ignore_errors=True)
    tests = [test_v7_layout_and_walk,
             test_v7_edge_content_small_program,
             test_v7_loader_rejects_version_ne_7,
             test_v7_loader_rejects_backward_edge,
             test_v7_loader_rejects_edg_count_mismatch,
             test_v7_roundtrip_elf]
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
