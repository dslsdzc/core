#!/usr/bin/env python3
"""v7 .ccr 真图载体 IO 测试（Task 3 收官——本文件 = v7 测试族唯一真源：
Task 1 骨架（version 7 + NOD 36B 邻接 + EDG 段必落）+ Task 2 ENT 主干化
（corec 产实记录 + loader 激活 + SYM/REG 回填）+ Task 3 迁移吸收 test_ccr_v6.py
全量用例（SYM/REG 目标形状、GC-3 root span 上界、GC-4 save 位置级守卫、
ENT 实记录 + opt_meta 恒空）+ cache-hit 恢复路径回归（Task 1 review Minor M2）
+ ENT 负分支补面（Task 2 review R1/R2——块重推导/ev 命名空间/ed 越界与失配）。

Task 3 吸收说明（v6 专属断言退役去向）：
  · test_header_segment_table_and_walk → test_v7_layout_and_walk（同源同断言，
    v7 版已含 reg ≥ 2/EDG 走查/ENT 形状——更强吸收）；
  · test_loader_rejects_non_v7_version → test_v7_loader_rejects_version_ne_7
    （v7 版覆盖 (6, 5, 8) 三值——更强吸收）；
  · test_ccr_v6_roundtrip_elf → test_v7_roundtrip_elf（同源同期望 + corearch
    直载双跑——更强吸收）；
  · test_ent_real_optmeta_absent → test_v7_ent_real_optmeta_absent（迁移本
    文件，opt_meta 恒 0 断言保留）；
  · test_sym_reg_target_shape / test_sym_func_shapes /
    test_loader_rejects_root_span_beyond_nod_space /
    test_save_rejects_var_block_misalignment → test_v7_* 同名迁移。

字节真相 = docs/superpowers/specs/2026-09-09-lattice-ir-v7-format.md：
  [0]   magic u32 = 0x31524343 ("CCR1")
  [4]   version u32 = 7
  [8]   seg_count u32 = 6
  [12]  reserved u32 = 0
  [16]  段表 6 × 12B {tag u32, offset u32, size u32}（规范序 tag 1..6）
  [88]  段体（tag 升序连续）：STR(1) / SYM(2) / NOD(3) / ENT(4) / REG(5) / EDG(6)
  STR/SYM/NOD/REG/EDG = v7 布局（Task 1）；ENT = 实记录（Task 2）——28B
  {var_id i32, version u32, def_nod i32, live_start u32, live_end u32（半开 =
  最后使用点 +1）, home i32（恒 -1）, flags u32}——corec 写侧按 v6 §4.1 规则
  （regalloc compute_entries 镜像，Task 0 表二差异①/②实现语义）重建
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

Task 2 条目期望（Python 独立模型 + 手算对照——均按 regalloc.cr compute_entries
实现语义转写，见 test_v7_ent_* 的派生说明；loader 校验面 = 同文件内自洽：
evr ≥ 1 / ev 命名空间 / els < ele ≤ instr_cnt / def ≥ 0 → ed == els / SYM
func 块对照——reject 测试逐个 byte mutation 打）。
Task 3 新增（2026-09-10）：
  · test_v7_cache_hit_restore_path——cache-hit 恢复路径回归（冷/暖五段体逐
    字节相同 + STR 前缀关系 + corearch 行为一致 + hybrid 单函数改动产物 ==
    全冷编译 byte-identical）；Minor 3 注记见该测试 docstring。
  · test_v7_loader_rejects_ent_var_foreign_block（R1）/ _ent_var_namespace_oob /
    _ent_def_nod_oob / _ent_def_ne_live_start（R2）——ENT 校验负分支补面。
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
        assert n == (len(b) - 4) // ENT_REC, f"ENT count {n} != bytes/28"
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


def parse_object_dump(out: str):
    """Parse corearch --dump-objects output (kernel object surface channel —
    Task 1 语义对象模型): lines are
      `objects: <count>`
      `nod <i> op <o> dest <d> s1 <s> s2 <x> s3 <y> tk <t> fe <f> ec <c>`
      `edge <i> to <to> kind <k>`   (one per out-edge of node i, index order)
    Returns (count, {i: (op, dest, s1, s2, s3, tk, fe, ec)}, {i: [(to, kind)]})."""
    lines = out.splitlines()
    assert lines and lines[0].startswith('objects: '), \
        f"dump missing count header: {lines[:3]!r}"
    count = int(lines[0].split()[1])
    nodes = {}
    edges = {}
    for ln in lines[1:]:
        p = ln.split()
        if not p:
            continue
        if p[0] == 'nod':
            idx = int(p[1])
            vals = [int(p[k + 1]) for k in range(2, len(p), 2)]
            assert len(vals) == 8, f"nod line fields {vals}"
            nodes[idx] = tuple(vals)
        elif p[0] == 'edge':
            idx = int(p[1])
            edges.setdefault(idx, []).append((int(p[3]), int(p[5])))
    return count, nodes, edges


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


# --- Task 2: ENT 实记录期望（Python 独立模型 + 手算对照）---

# 模型 opcode 常量（规则需要判别的四个 op——与 ast.cr 编号一致）
IR_STORE = 9
IR_STORE_INDEX_VAR = 16
IR_STORE_PTR = 26
IR_DYN_DISPATCH = 44

ENT_SRC = (
    "fn identity(n: int) -> int { return n; }\n"
    "fn main() -> int {\n"
    "    x := 1;\n"
    "    x = x + 1;\n"
    "    x = x + 2;\n"
    "    return x;\n"
    "}\n")


def model_compute_entries(nod, funcs, gcount, regs):
    """v6 §4.1 条目重建规则（regalloc.cr compute_live_ranges/compute_entries
    镜像）的 Python 独立实现——.cr 侧 compute_entries_v7 无共享代码，同为
    regalloc.cr 规则文本转写，测试即交叉验证。

    规则（Task 0 表二逐条）：
      · 每函数三列引用扫描（d/s1/s2 ∈ [vs, vs+vc) 函数 var 窗口，局部坐标
        存 [first_ref, last_ref]——不得以 df 边替代）；
      · 定值点 = IR_STORE 的 s1 ∈ 窗口 ∪ 其余 op（STORE_INDEX_VAR/STORE_PTR/
        DYN_DISPATCH 排除）的 dest ∈ 窗口；
      · 版本切分：上一版本收口 end = min(def−1, last_ref)（dest/s1 列含定值
        自身 → last_ref ≥ 次定值 → 恒 def−1）；末版 LE = last_ref（全局坐标）；
      · 从未定值但有引用的 var（参数等）：def=-1 条目，区间 = [first_ref,
        last_ref]（差异①实现语义——loader 只校验 els < ele ≤ instr_cnt）；
      · 全局 var（SYM 前缀 0..G-1）不在任何函数窗口 → 恒无条目（差异②）；
      · home/flags 恒 -1/0；版本 = 文件序同 var 组内 1-based 序数。
    返回 (rows, blocks)：
      rows:  [(var_id, version, def_nod, live_start, live_end_halfopen,
               home, flags)]（文件序）
      blocks: [(start_index, count)] per func（文件序块界）
    """
    defs_out = []  # entries in creation order (def-point order per func)
    blocks = []
    row_no = 0  # global entry counter across funcs (== file order)
    var_start = gcount
    for k, f in enumerate(funcs):
        root = regs[f['root_region']]
        ist, ex = root[2], root[3]
        ic = ex - ist
        vc = f['var_count']
        vs = var_start
        var_start += vc
        ent0 = row_no
        if ic > 0 and vc > 0:
            first = [-1] * vc
            last = [-1] * vc
            for ii in range(ic):
                inst = ist + ii
                op, d, s1, s2, s3, tk, fe, ec = nod[inst]
                for col in (d, s1, s2):
                    if vs <= col < vs + vc:
                        lv = col - vs
                        if first[lv] < 0:
                            first[lv] = ii
                        last[lv] = ii
            prev = [-1] * vc  # open-version entry id per local var
            for ii in range(ic):
                inst = ist + ii
                op, d, s1, s2, s3, tk, fe, ec = nod[inst]
                dv = -1
                if op == IR_STORE:
                    if vs <= s1 < vs + vc:
                        dv = s1
                elif op != IR_STORE_INDEX_VAR and op != IR_STORE_PTR and \
                        op != IR_DYN_DISPATCH:
                    if vs <= d < vs + vc:
                        dv = d
                if dv >= 0:
                    lv = dv - vs
                    last_global = ist + last[lv] if last[lv] >= 0 else -1
                    pe = prev[lv]
                    if pe >= 0:
                        pend = inst - 1
                        if last_global >= 0 and last_global < pend:
                            pend = last_global
                        # closure: overwrite LE of the still-open version
                        row = defs_out[pe]
                        defs_out[pe] = (row[0], row[1], row[2], row[3], pend,
                                        row[5], row[6])
                    defs_out.append((dv, 1, inst, inst, last_global, -1, 0))
                    prev[lv] = len(defs_out) - 1
                    row_no += 1
            for lv2 in range(vc):
                if prev[lv2] < 0 and first[lv2] >= 0 and last[lv2] >= 0:
                    defs_out.append((vs + lv2, 1, -1, ist + first[lv2],
                                     ist + last[lv2], -1, 0))
                    row_no += 1
        blocks.append((ent0, row_no - ent0))
    # version = 同 var 文件序组内 1-based 序数
    seen = {}
    rows = []
    for (var_id, _, dn, ls, le, ho, fl) in defs_out:
        ord_ = seen.get(var_id, 0) + 1
        seen[var_id] = ord_
        rows.append((var_id, ord_, dn, ls, le + 1, ho, fl))
    return rows, blocks


def model_func_ranges(rows, blocks, funcs, gcount):
    """从模型 rows/blocks 派生 SYM/REG 侧期望：per-func (first_ent, last_ent,
    param_ents)；per-func param var 全局 id 列表（前 param_count 个 decl）。"""
    out = []
    vs = gcount
    for k, f in enumerate(funcs):
        st, cnt = blocks[k]
        fe = st if cnt else -1
        le = st + cnt - 1 if cnt else -1
        pes = []
        for p in range(f['param_count']):
            pvar = vs + p
            pid = -1
            for i in range(st, st + cnt):
                if rows[i][0] == pvar and rows[i][2] == -1:
                    pid = i
            pes.append(pid)
        out.append((fe, le, pes))
        vs += f['var_count']
    return out


def test_v7_ent_hand_expected_small():
    """ENT 实记录 + 字段语义手算期望（Task 2 测试载体——已知小程序
    identity/main，文件前两函数 = 节点 0..17，每函数首节点 = arena_new）：

    手算（v6 §4.1 规则 + regalloc 实现语义——差异① def=-1 条目区间 =
    [first_ref, last_ref] 闭区间、盘上 live_end 半开 = +1；版本 = 组内 1-based）：

    identity func0 nodes[0:4) decls ['n','_arena']（n = var 窗口首行）:
      n0 ARENA_NEW d=_arena；n1 RETURN s1=n；n2 ARENA_RESET s1=_arena；
      n3 RETURN -1
      → _arena: def@0，refs {0(d), 2(s1)} → 版本 1 [0,2] 闭 → 盘 (0, 3)
      → n: 无定值，ref@1(s1) → def=-1 条目 (ls 1, le 2)  ← 差异① 参数条目
    main func1 nodes[4:17) decls ['_arena','x','int','int','bin','int','bin']:
      _arena def@4 refs{4,15} → (4, 16)
      x defs@5(ALLOC),7,10,13(STORE)，refs{5,7,9,10,12,13,14} → 版本 1..4
        版本 1 [5,6]→(5,7)；版本 2 [7,9]→(7,10)；版本 3 [10,12]→(10,13)；
        版本 4 [13,14]→(13,15)
      临时（RESOLVED/BINARY dest）：decl2 def@6 ref@7 → (6,8)；
        decl3 def@8 ref@9 → (8,10)；decl4 def@9 ref@10 → (9,11)；
        decl5 def@11 ref@12 → (11,13)；decl6 def@12 ref@13 → (12,14)
    行 = (var_decl_row, version, def_nod, live_start, live_end_半开)；
    home/flags 恒 -1/0。条目文件序 = 函数序块拼接：identity 块 = 文件行 0..1
    （def 升序在前，def=-1 补丁按 var 行序在后），main 块 = 行 2..11。
    """
    ccr_path = os.path.join(BASE, 'build/test_v7_ent_hand.ccr')
    try:
        os.unlink(ccr_path)
    except FileNotFoundError:
        pass
    try:
        corec_ccr(ENT_SRC, ccr_path)
        v7 = V7File(read_ccr(ccr_path))
        strs = v7.str_table()
        sym = v7.sym_parse()
        funcs = sym['funcs']
        names = [strs[f['name']] for f in funcs]
        assert names[0] == 'identity' and names[1] == 'main', names
        ents = v7.ent()
        # 手算表（var 以声明行序引用——与文件命名空间解耦）
        exp = [
            # identity block（文件行 0..1）
            (1, 1, 0, 0, 3), (0, 1, -1, 1, 2),
            # main block（文件行 2..11）
            (0, 1, 4, 4, 16), (1, 1, 5, 5, 7), (2, 1, 6, 6, 8),
            (1, 2, 7, 7, 10), (3, 1, 8, 8, 10), (4, 1, 9, 9, 11),
            (1, 3, 10, 10, 13), (5, 1, 11, 11, 13), (6, 1, 12, 12, 14),
            (1, 4, 13, 13, 15),
        ]
        # func var 窗口起点 = globals + 前缀 var_count
        vs0 = len(sym['globals'])
        vs1 = vs0 + funcs[0]['var_count']
        var_of = {}
        for di in range(funcs[0]['var_count']):
            var_of[(0, di)] = vs0 + di
        for di in range(funcs[1]['var_count']):
            var_of[(1, di)] = vs1 + di
        # 手算表只覆盖文件前两函数块（identity 2 + main 10 = 文件行 0..11——
        # 函数块按函数序拼接，其余函数块在其后，本测试只断言前缀 12 行）
        assert len(ents) >= len(exp), \
            f"entries {len(ents)} < hand-expected {len(exp)}"
        for k, (fidx, erow) in enumerate(zip([0] * 2 + [1] * 10, exp)):
            evar, ever, edef, els, ele, eho, efl = ents[k]
            assert evar == var_of[(fidx, erow[0])], \
                f"row {k}: var {evar} != decl-row {erow[0]} var " \
                f"{var_of[(fidx, erow[0])]}"
            assert (ever, edef, els, ele) == erow[1:], \
                f"row {k} {evar}: got ({ever},{edef},{els},{ele}) " \
                f"expected {erow[1:]}"
            assert eho == -1 and efl == 0, \
                f"row {k}: home/flags ({eho},{efl}) != (-1,0)"
        # SYM func 记录：块界回填 = 文件行 0..1 / 2..11；param_ents 实回填
        # （identity 参数 n 的 def=-1 条目 = 文件行 1）
        f0, f1 = funcs[0], funcs[1]
        assert (f0['first_ent'], f0['last_ent']) == (0, 1), \
            f"identity range {f0['first_ent']}..{f0['last_ent']}"
        assert f0['param_ents'] == [1], \
            f"identity param_ents {f0['param_ents']} != [1]"
        assert (f1['first_ent'], f1['last_ent']) == (2, 11), \
            f"main range {f1['first_ent']}..{f1['last_ent']}"
        assert f1['param_count'] == 0
        # REG 根行（SG_FUNC）first/last 与 SYM func 记录双写一致
        regs = v7.reg()
        roots = [i for i, r in enumerate(regs) if r[0] == 0]
        assert regs[roots[0]][4] == 0 and regs[roots[0]][5] == 1
        assert regs[roots[1]][4] == 2 and regs[roots[1]][5] == 11
    finally:
        try:
            os.unlink(ccr_path)
        except FileNotFoundError:
            pass


def test_v7_ent_model_replay_pure_add():
    """整文件条目 = Python 独立模型预测（模型 = §4.1/regalloc 规则转写，与
    .cr 实现无共享代码）——PROBE_SRC（pure_add 参数 def=-1 + main 全形态：
    ALLOC/STORE/STORE_INDEX/STORE_INDEX_VAR carve-out 读/LAZY 族/多定值）。
    对照面：
      · ENT 段逐行 == 模型行（var_id/version/def/ls/le 半开/home/flags）；
      · SYM func first_ent/last_ent/param_ents == 模型块界/参数条目派生；
      · REG 每行 first/last == 模型派生（根行 = 函数块含 def=-1；嵌套 =
        定值点 def ∈ [enter, exit) 的连续段，无 = -1）。"""
    ccr_path = os.path.join(BASE, 'build/test_v7_ent_model.ccr')
    try:
        os.unlink(ccr_path)
    except FileNotFoundError:
        pass
    try:
        corec_ccr(PROBE_SRC, ccr_path)
        v7 = V7File(read_ccr(ccr_path))
        sym = v7.sym_parse()
        funcs = sym['funcs']
        nod = v7.nod()
        regs = v7.reg()
        ents = v7.ent()
        rows, blocks = model_compute_entries(nod, funcs, len(sym['globals']),
                                             regs)
        assert rows == ents, \
            f"ENT rows != independent model:\n  file {ents[:8]}...\n  model {rows[:8]}..."
        # func 名对照（模型按 SYM func 序——须 = 期望序）
        strs = v7.str_table()
        assert strs[funcs[0]['name']] == 'pure_add'
        assert strs[funcs[1]['name']] == 'main'
        # SYM func 块界 + param_ents 对照
        exp_ranges = model_func_ranges(rows, blocks, funcs,
                                       len(sym['globals']))
        for k, f in enumerate(funcs):
            fe, le, pes = exp_ranges[k]
            assert (f['first_ent'], f['last_ent']) == (fe, le), \
                f"func {k} ({strs[f['name']]}) first/last " \
                f"({f['first_ent']},{f['last_ent']}) != model ({fe},{le})"
            assert f['param_ents'] == pes, \
                f"func {k} param_ents {f['param_ents']} != model {pes}"
        # REG first/last 对照（根行 = 函数块；嵌套 = def ∈ span 连续段）
        rfc = -1
        for rid, r in enumerate(regs):
            kind, par, en, ex, rfe, rle = r
            if kind == 0:
                rfc += 1
            st, cnt = blocks[rfc]
            if kind == 0:
                me = st if cnt else -1
                ml = st + cnt - 1 if cnt else -1
            else:
                in_span = [i for i in range(st, st + cnt)
                           if rows[i][2] >= en and rows[i][2] < ex]
                me = min(in_span) if in_span else -1
                ml = max(in_span) if in_span else -1
            assert (rfe, rle) == (me, ml), \
                f"REG row {rid} (kind {kind}) range ({rfe},{rle}) " \
                f"!= model ({me},{ml})"
        # loader 语义不变量显式断言（与 load_ccr ENT 校验同面）
        instr_cnt = len(nod)
        for k, (ev, evr, ed, els, ele, eho, efl) in enumerate(ents):
            assert evr >= 1, f"row {k}: version {evr} < 1"
            assert 0 <= ev < len(sym['globals']) + sum(fn['var_count']
                                                       for fn in funcs), \
                f"row {k}: var_id {ev} outside namespace"
            assert els < ele <= instr_cnt, \
                f"row {k}: interval [{els},{ele}) invalid vs instr_cnt"
            if ed >= 0:
                assert ed == els, f"row {k}: def {ed} != live_start {els}"
    finally:
        try:
            os.unlink(ccr_path)
        except FileNotFoundError:
            pass


def test_v7_ent_hand_expected_pure_add_block():
    """pure_add（PROBE_SRC func0，nodes[0:5) decls ['a','b','_arena','bin']）
    条目块手算（= 差异① def=-1 参数条目形态的直接锁定）：

      n0 ARENA_NEW d=_arena(decl2)；n1 BINARY d=bin(decl3) s1=a s2=b；
      n2 RETURN s1=bin；n3 ARENA_RESET s1=_arena；n4 RETURN -1
      → _arena def@0 refs{0,3} → 版本 1 (ls 0, le 4 半开)
      → bin def@1 refs{1,2} → 版本 1 (ls 1, le 3)
      → a def=-1 ref@1 → (ls 1, le 2)；b def=-1 ref@1 → (ls 1, le 2)
    块 = 文件行 0..3（def 条目在前、def=-1 补丁按 var 行序 = a 先于 b）；
    first/last_ent = 0..3；param_ents = [2, 3]（a/b 的 def=-1 条目文件行）。"""
    ccr_path = os.path.join(BASE, 'build/test_v7_ent_pure.ccr')
    try:
        os.unlink(ccr_path)
    except FileNotFoundError:
        pass
    try:
        corec_ccr(PROBE_SRC, ccr_path)
        v7 = V7File(read_ccr(ccr_path))
        sym = v7.sym_parse()
        funcs = sym['funcs']
        strs = v7.str_table()
        assert strs[funcs[0]['name']] == 'pure_add'
        ents = v7.ent()
        vs0 = len(sym['globals'])
        exp = [
            (vs0 + 2, 1, 0, 0, 4), (vs0 + 3, 1, 1, 1, 3),
            (vs0 + 0, 1, -1, 1, 2), (vs0 + 1, 1, -1, 1, 2),
        ]
        got = [(ev, ever, edef, els, ele) for (ev, ever, edef, els, ele,
                                                eho, efl) in ents[:4]]
        assert got == exp, f"pure_add block:\n  got      {got}\n  expected {exp}"
        for (ev, ever, edef, els, ele, eho, efl) in ents[:4]:
            assert eho == -1 and efl == 0
        f0 = funcs[0]
        assert (f0['first_ent'], f0['last_ent']) == (0, 3), \
            f"pure_add range ({f0['first_ent']},{f0['last_ent']}) != (0,3)"
        assert f0['param_ents'] == [2, 3], \
            f"pure_add param_ents {f0['param_ents']} != [2,3]"
        # main 内多定值 var 版本切分 spot-check（手算）：
        #   v(decl9): ALLOC@20 + STORE@22 + STORE_INDEX_VAR@24 读(carve-out)
        #     值读@26/@34 → 版本1 (20,22) 版本2 (22,35)
        #   x(decl13): ALLOC@28 + STORE@31 → 版本1 (28,31) 版本2 (31,34)
        #   s(decl15): ALLOC@32 + STORE@38 + STORE@41, 末读@42 RETURN
        #     → 版本1 (32,38) 版本2 (38,41) 版本3 (41,43)
        mvs = vs0 + funcs[0]['var_count']  # main var 窗口起点
        main = funcs[1]
        # main 条目块 = SYM 实回填范围（块长 = 条目数 ≠ var_count）
        block = ents[main['first_ent']:main['last_ent'] + 1]
        assert len(block) >= 20, f"main block too small: {len(block)}"
        by_decl = {}
        for (ev, ever, edef, els, ele, eho, efl) in block:
            by_decl.setdefault(ev - mvs, []).append((ever, edef, els, ele))
        assert by_decl[9] == [(1, 20, 20, 22), (2, 22, 22, 35)], \
            f"main v versions {by_decl[9]}"
        assert by_decl[13] == [(1, 28, 28, 31), (2, 31, 31, 34)], \
            f"main x versions {by_decl[13]}"
        assert by_decl[15] == [(1, 32, 32, 38), (2, 38, 38, 41),
                               (3, 41, 41, 43)], \
            f"main s versions {by_decl[15]}"
    finally:
        try:
            os.unlink(ccr_path)
        except FileNotFoundError:
            pass


def _mutate_ent_field(data, rec_idx, field_off, value, fmt='<I'):
    """ENT 段第 rec_idx 条记录（0-based）字段偏移 field_off（记录内 0/4/8/
    12/16/20/24）改写为 value。返回 (ent_off, rec0_version_ok)。"""
    v7 = V7File(bytes(data))
    ents = v7.ent()
    assert len(ents) > 0, "precondition: ENT must carry real records"
    ent_off, _ = v7.segs[4]
    at = ent_off + 4 + rec_idx * ENT_REC + field_off
    struct.pack_into(fmt, data, at, value)
    return ents


def test_v7_loader_rejects_bad_ent_version():
    """loader ENT 实记录校验（激活面）：version 字段 = 0 → 拒绝。"""
    src = "fn main() -> int { return 42; }\n"
    ccr_path = os.path.join(BASE, 'build/test_v7_entver.ccr')
    try:
        os.unlink(ccr_path)
    except FileNotFoundError:
        pass
    try:
        corec_ccr(src, ccr_path)
        data = bytearray(read_ccr(ccr_path))
        _mutate_ent_field(data, 0, 4, 0)  # version := 0（evr < 1）
        bad_path = ccr_path + '.v0'
        with open(bad_path, 'wb') as fh:
            fh.write(bytes(data))
        r = subprocess.run([COREARCH, bad_path, '--elf', '--static',
                            '-o', os.path.join(BASE, 'build/test_v7_entver.out')],
                           capture_output=True, text=True, cwd=BASE, timeout=60)
        assert r.returncode != 0, \
            f"corearch accepted version-0 entry: rc={r.returncode}"
        assert 'invalid' in (r.stdout + r.stderr), \
            f"expected invalid-.ccr error, got: {r.stdout!r} {r.stderr!r}"
    finally:
        for p in (ccr_path, ccr_path + '.v0',
                  os.path.join(BASE, 'build/test_v7_entver.out')):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


def test_v7_loader_rejects_ent_liveend_oob():
    """loader ENT 区间校验：live_end（半开）越出 NOD 空间（ele > instr_cnt）
    → 拒绝。"""
    src = "fn main() -> int { return 42; }\n"
    ccr_path = os.path.join(BASE, 'build/test_v7_entle.ccr')
    try:
        os.unlink(ccr_path)
    except FileNotFoundError:
        pass
    try:
        corec_ccr(src, ccr_path)
        data = bytearray(read_ccr(ccr_path))
        v7 = V7File(bytes(data))
        nod_cnt = len(v7.nod())
        _mutate_ent_field(data, 0, 16, nod_cnt + 1)  # live_end := oob
        bad_path = ccr_path + '.oob'
        with open(bad_path, 'wb') as fh:
            fh.write(bytes(data))
        r = subprocess.run([COREARCH, bad_path, '--elf', '--static',
                            '-o', os.path.join(BASE, 'build/test_v7_entle.out')],
                           capture_output=True, text=True, cwd=BASE, timeout=60)
        assert r.returncode != 0, \
            f"corearch accepted live_end beyond NOD space: rc={r.returncode}"
        assert 'invalid' in (r.stdout + r.stderr), \
            f"expected invalid-.ccr error, got: {r.stdout!r} {r.stderr!r}"
    finally:
        for p in (ccr_path, ccr_path + '.oob',
                  os.path.join(BASE, 'build/test_v7_entle.out')):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


def test_v7_loader_rejects_ent_ls_ge_le():
    """loader ENT 区间校验：live_start ≥ live_end（半开区间倒置/退化）→
    拒绝。"""
    src = "fn main() -> int { return 42; }\n"
    ccr_path = os.path.join(BASE, 'build/test_v7_entls.ccr')
    try:
        os.unlink(ccr_path)
    except FileNotFoundError:
        pass
    try:
        corec_ccr(src, ccr_path)
        data = bytearray(read_ccr(ccr_path))
        ents = _mutate_ent_field(data, 0, 16, 0)  # live_end := 0 → 0 ≥ ls
        bad_path = ccr_path + '.inv'
        with open(bad_path, 'wb') as fh:
            fh.write(bytes(data))
        r = subprocess.run([COREARCH, bad_path, '--elf', '--static',
                            '-o', os.path.join(BASE, 'build/test_v7_entls.out')],
                           capture_output=True, text=True, cwd=BASE, timeout=60)
        assert r.returncode != 0, \
            f"corearch accepted inverted interval: rc={r.returncode}"
        assert 'invalid' in (r.stdout + r.stderr), \
            f"expected invalid-.ccr error, got: {r.stdout!r} {r.stderr!r}"
    finally:
        for p in (ccr_path, ccr_path + '.inv',
                  os.path.join(BASE, 'build/test_v7_entls.out')):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


def test_v7_loader_rejects_sym_ent_block_mismatch():
    """loader 双写对照（激活面）：SYM func first_ent 与 ENT 实块界失配 →
    拒绝。byte mutation：func0 记录 first_ent 字段 +1（REG 根行对照与
    ENT 块界对照双路径同源拒绝）。"""
    src = ("fn add(a: int, b: int) -> int { return a + b; }\n"
           "fn main() -> int { return 42; }\n")
    ccr_path = os.path.join(BASE, 'build/test_v7_entblk.ccr')
    try:
        os.unlink(ccr_path)
    except FileNotFoundError:
        pass
    try:
        corec_ccr(src, ccr_path)
        data = bytearray(read_ccr(ccr_path))
        v7 = V7File(bytes(data))
        sym = v7.sym_parse()
        f0 = sym['funcs'][0]
        assert f0['first_ent'] >= 0, \
            f"precondition: func0 first_ent real, got {f0['first_ent']}"
        sym_off, _ = v7.segs[2]
        # SYM 体：global_count(4) + globals(16B×G) + func_count(4) + func0 头
        # 24B——first_ent = 头内 +16
        g = len(sym['globals'])
        at = sym_off + 4 + g * 16 + 4 + 0 * 24 + 16
        struct.pack_into('<i', data, at, f0['first_ent'] + 1)
        bad_path = ccr_path + '.blk'
        with open(bad_path, 'wb') as fh:
            fh.write(bytes(data))
        r = subprocess.run([COREARCH, bad_path, '--elf', '--static',
                            '-o', os.path.join(BASE, 'build/test_v7_entblk.out')],
                           capture_output=True, text=True, cwd=BASE, timeout=60)
        assert r.returncode != 0, \
            f"corearch accepted SYM/ENT block mismatch: rc={r.returncode}"
        assert 'invalid' in (r.stdout + r.stderr), \
            f"expected invalid-.ccr error, got: {r.stdout!r} {r.stderr!r}"
    finally:
        for p in (ccr_path, ccr_path + '.blk',
                  os.path.join(BASE, 'build/test_v7_entblk.out')):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


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
        # Task 2: ENT 实记录（corec 产条目）——函数有 var 即有条目（参数/本地
        # 引用 + _arena 定值），本程序条目数 > 0；全行字段自洽
        assert len(e) > 0, f"ENT empty — Task 2: corec should write entries: {e}"
        for (ev, evr, ed, els, ele, eho, efl) in e:
            assert evr >= 1 and 0 <= ev and eho == -1 and efl == 0
            assert els < ele and (ed < 0 or ed == els)
        edg = v7.edg()  # full EDG walk + forward/kind invariant checks
        # EDG 段必落且至少一条边（每函数 arena_new→arena_reset def-use 存在）
        assert sum(len(v) for v in edg.values()) >= 2, \
            f"EDG unexpectedly small: {edg}"
    finally:
        try:
            os.unlink(ccr_path)
        except FileNotFoundError:
            pass


def test_v7_object_surface_recipe_readable():
    """内核语义对象模型（内核完备 Task 1）——对象面配方可读判据（设计 spec
    §4.4）：corearch 直载 .ccr 后经 --dump-objects 通道（对象面访问器
    nod_op/nod_dest/nod_s1-3/nod_tk + nod_edge_first/count + v7_edge_to/kind
    读内核对象缓冲）输出逐节点语义字段 + 出边遍历。断言三层：

      · 全图逐节点/逐边 == V7File 文件解析（loader 对象缓冲 = 文件语义投影
        ——语义字段与邻接域载入无损；现任务前 NOD 语义字段除 g_ir_instrs
        线性流外无任何保留——本通道 = 对象留存形态的直接证据）；
      · 节点出边遍历（邻接索引区间 [first, first+count) → v7_edge_to/kind）
        == 文件 EDG 走查（配方输入集逐边一致——v7_edge_* 缓冲与邻接元数据
        圆通）；
      · 源函数域（节点 < EXPECT_SRC_SPAN）数据边/state 边 = 表一「去幽灵后」
        期望（EXPECT_DATA/EXPECT_STATE 复用——已知小程序期望锚）。

    说明：dump 通道经 loader（NOD/EDG 段载入对象缓冲）→ build_linear_schedule
    （调度重建移实例后 g_ir_instrs 仍须就位——dump 分支在重建后、发射前）。"""
    ccr_path = os.path.join(BASE, 'build/test_v7_objects.ccr')
    try:
        os.unlink(ccr_path)
    except FileNotFoundError:
        pass
    try:
        corec_ccr(PROBE_SRC, ccr_path)
        v7 = V7File(read_ccr(ccr_path))
        nod = v7.nod()
        file_edges = v7.edg()
        r = subprocess.run([COREARCH, ccr_path, '--dump-objects'],
                           capture_output=True, text=True, cwd=BASE,
                           timeout=120)
        assert r.returncode == 0, \
            f"corearch --dump-objects rc={r.returncode}: {r.stdout!r} {r.stderr!r}"
        count, nodes, edges = parse_object_dump(r.stdout)
        assert count == len(nod), \
            f"object count {count} != NOD count {len(nod)}"
        assert len(nodes) == len(nod), \
            f"dumped nodes {len(nodes)} != file nodes {len(nod)}"
        for i, rec in enumerate(nod):
            assert i in nodes, f"node {i} missing from dump"
            assert nodes[i] == rec, \
                f"node {i}: object surface {nodes[i]} != file record {rec}"
        # 出边遍历 == 文件 EDG（空出边节点两侧都缺省）
        for i, row in file_edges.items():
            assert edges.get(i) == row, \
                f"node {i}: traversal edges {edges.get(i)} != file EDG {row}"
        assert set(edges) == set(file_edges), \
            f"traversal edge nodes {sorted(edges)} != file {sorted(file_edges)}"
        # 表一复用：源函数域数据/state 边 = 去幽灵后期望
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
        ents = v7.ent()
        # Task 2: build 链中间产物携带实条目（corearch 已 load 校验 + 发射）
        assert len(ents) > 0, "built .ccr should carry real ENT records"
        for (ev, evr, ed, els, ele, eho, efl) in ents:
            assert evr >= 1 and eho == -1 and efl == 0
            assert els < ele and (ed < 0 or ed == els)
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


# === Task 3（收官）迁移用例——吸收 test_ccr_v6.py 全量（v7 命名/路径）；
# 删除面（version-reject / roundtrip / layout-walk）由 v7 版更强吸收，见模块
# docstring「Task 3 吸收说明」。===


def test_v7_ent_real_optmeta_absent():
    """（迁移 test_ent_real_optmeta_absent）ENT 实记录 + opt_meta 恒空面：
    ENT 段携带实条目；opt_meta 仍恒 0（分配结果归位 corearch 自算，.ccr
    不传）；SYM func first/last_ent 与 param_ents 实回填。Python 侧独立块
    切分（loader 块对照同语义）：
      · 每函数块 = 文件序连续段（var ∈ 函数 var 窗口）——块界 == SYM
        first_ent/last_ent；
      · param_ents 每参数 = -1 或该参数 var 的 def=-1 条目（identity 参数 n
        未定值 → 实条目）；
      · REG 根行（SG_FUNC）first/last 与 SYM func 记录双写一致（实值）。"""
    ccr_path = os.path.join(BASE, 'build/test_v7_optmeta.ccr')
    try:
        os.unlink(ccr_path)
    except FileNotFoundError:
        pass
    try:
        corec_ccr(ENT_SRC, ccr_path)
        v7 = V7File(read_ccr(ccr_path))
        ents = v7.ent()
        assert len(ents) > 0, f"ENT empty: {ents}"
        sym = v7.sym_parse()
        assert sym['opt_count'] == 0, f"opt_meta not empty: {sym['opt_count']}"
        funcs = sym['funcs']
        assert len(funcs) >= 2
        # Python 侧块切分（loader 块对照同语义）：块序 = 函数序，块 = 连续段
        vs = len(sym['globals'])
        pos = 0
        for f in funcs:
            win = range(vs, vs + f['var_count'])
            start = pos
            while pos < len(ents) and ents[pos][0] in win:
                pos += 1
            pcnt = pos - start
            if pcnt == 0:
                assert (f['first_ent'], f['last_ent']) == (-1, -1), f
            else:
                assert f['first_ent'] == start, \
                    f"func first_ent {f['first_ent']} != block start {start}"
                assert f['last_ent'] == start + pcnt - 1, \
                    f"func last_ent {f['last_ent']} != block end {start + pcnt - 1}"
            # param_ents：-1 或该参数 var 的 def=-1 条目（块内唯一）
            for p in range(f['param_count']):
                pvar = vs + p
                pid = -1
                for i in range(start, start + pcnt):
                    (ev, evr, ed, els, ele, eho, efl) = ents[i]
                    if ev == pvar and ed == -1:
                        pid = i
                assert f['param_ents'][p] == pid, \
                    f"func param_ents[{p}] {f['param_ents'][p]} != {pid}"
            vs += f['var_count']
        assert pos == len(ents), "block partition did not cover all entries"
        # REG 根行 first/last 与 SYM func 记录双写一致（实值）
        regs = v7.reg()
        roots = [(i, r) for i, r in enumerate(regs) if r[0] == 0]
        for k, (rid, r) in enumerate(roots[:len(funcs)]):
            assert r[4] == funcs[k]['first_ent'], \
                f"root {rid} first_ent {r[4]} != SYM {funcs[k]['first_ent']}"
            assert r[5] == funcs[k]['last_ent'], \
                f"root {rid} last_ent {r[5]} != SYM {funcs[k]['last_ent']}"
    finally:
        try:
            os.unlink(ccr_path)
        except FileNotFoundError:
            pass


def test_v7_sym_reg_target_shape():
    """（迁移 test_sym_reg_target_shape）SYM 归并/REG 坐标化目标形状
    （v7 spec §3.2/§3.5 落地）：
    - SYM func 记录 = {name/param_count/ret_type/root_region/first_ent/last_ent}
      + param_ents + var 声明区；globals 记录带 type；
    - REG 记录 = {kind, parent, enter_nod, exit_nod, first_ent, last_ent}；
    - 根 region（SG_FUNC）行与 func 记录 1:1，span 连续铺满 NOD 空间，
      first/last = 本函数条目块；嵌套 region 条目范围 = 定值点 ∈ [enter, exit)
      （文件条目序连续一段）；变量命名空间行数覆盖 ENT/NOD 引用。"""
    src = ("fn main() -> int {\n"
           "    s : ., mut = 0;\n"
           "    for i in 0..4 { s = s + i; }\n"
           "    return s;\n"
           "}\n")
    ccr_path = os.path.join(BASE, 'build/test_v7_symreg.ccr')
    try:
        os.unlink(ccr_path)
    except FileNotFoundError:
        pass
    try:
        corec_ccr(src, ccr_path)
        v7 = V7File(read_ccr(ccr_path))
        sym = v7.sym_parse()
        globs = sym['globals']
        funcs = sym['funcs']
        strs = v7.str_table()
        nod_cnt = len(v7.nod())
        ents = v7.ent()
        regs = v7.reg()
        # func 记录
        assert len(funcs) >= 1
        f = funcs[0]
        assert strs[f['name']] == 'main', f"func0 is {strs[f['name']]!r}"
        assert f['param_count'] == 0
        assert f['var_count'] >= f['param_count']
        decl_names = [strs[d['name']] for d in f['var_decls']]
        assert len(decl_names) == f['var_count']
        # 局部变量声明随函数记录落盘（for 循环变量内部名 = for_i）
        for want in ('s', 'for_i'):
            assert want in decl_names, \
                f"local {want} missing from func var decls: {decl_names}"
        # 全局记录：>=1 条，全局行数 = var 行序前缀（func0 var 基准）
        assert len(globs) >= 1
        # REG: 根行（kind=0）与 func 1:1；span 连续铺满 NOD 空间
        roots = [(i, r) for i, r in enumerate(regs) if r[0] == 0]
        assert len(roots) == len(funcs), \
            f"SG_FUNC rows {len(roots)} != func records {len(funcs)}"
        prev_end = 0
        for k, (rid, r) in enumerate(roots):
            assert funcs[k]['root_region'] == rid, \
                f"func {k} root_region {funcs[k]['root_region']} != row {rid}"
            assert r[2] == prev_end, \
                f"root {k} enter {r[2]} != previous end {prev_end}"
            prev_end = r[3]
            # 根 region 条目范围 == 函数条目块（SYM func 记录同值）
            assert funcs[k]['first_ent'] == r[4] and funcs[k]['last_ent'] == r[5]
            assert (r[4] == -1) == (r[5] == -1)
        assert prev_end == nod_cnt, \
            f"root spans end at {prev_end}, nod_count {nod_cnt}"
        # 嵌套 region：first/last = def_nod ∈ [enter, exit) 的文件序连续段
        for rid, r in enumerate(regs):
            if r[0] == 0:
                assert r[1] == -1, f"root {rid} parent != -1: {r}"
                continue
            if r[1] >= 0:
                p = regs[r[1]]
                assert r[2] >= p[2] and r[3] <= p[3], \
                    f"region {rid} escapes parent span: {r} vs {p}"
            exp = {ei for ei, en in enumerate(ents)
                   if en[2] >= 0 and r[2] <= en[2] < r[3]}
            if not exp:
                assert r[4] == -1 and r[5] == -1, \
                    f"empty region {rid} has range {r[4]}..{r[5]}"
            else:
                assert r[4] == min(exp) and r[5] == max(exp), \
                    f"region {rid} range {r[4]}..{r[5]} != expected {min(exp)}..{max(exp)}"
                got = set(range(r[4], r[5] + 1))
                assert got == exp, \
                    f"region {rid} run not exactly the def'd-in-range set"
        # 变量命名空间（globals + 各 func var_count）覆盖 ENT var id / NOD dest
        total_vars = len(globs) + sum(fn['var_count'] for fn in funcs)
        for en in ents:
            assert 0 <= en[0] < total_vars, \
                f"ENT var_id {en[0]} outside var namespace 0..{total_vars - 1}"
        for (op, dest, s1, s2, s3, tk, fe, ec) in v7.nod():
            if dest >= 0:
                assert dest < total_vars, f"NOD dest {dest} outside var namespace"
            assert fe >= 0 and ec >= 0  # 邻接域自洽（完整校验在 edg() 走查）
    finally:
        try:
            os.unlink(ccr_path)
        except FileNotFoundError:
            pass


def test_v7_sym_func_shapes():
    """（迁移 test_sym_func_shapes）SYM func 记录形状：add/main 行序 = 声明序；
    参数 = var 声明区前 param_count 个（行序 = 参数序，类型 int）；root_region
    行序 1:1、span 连续铺满 NOD 空间；first/last_ent 实回填（add 参数 a/b 从未
    定值 → def=-1 条目 → param_ents = 其条目 id；main 无参；条目范围 = 块界）。"""
    src = ("fn add(a: int, b: int) -> int { return a + b; }\n"
           "fn main() -> int {\n"
           "    x := 1;\n"
           "    x = x + 1;\n"
           "    x = x + 2;\n"
           "    return x;\n"
           "}\n")
    ccr_path = os.path.join(BASE, 'build/test_v7_symparams.ccr')
    try:
        os.unlink(ccr_path)
    except FileNotFoundError:
        pass
    try:
        corec_ccr(src, ccr_path)
        v7 = V7File(read_ccr(ccr_path))
        sym = v7.sym_parse()
        funcs = sym['funcs']
        strs = v7.str_table()
        regs = v7.reg()
        nod_cnt = len(v7.nod())
        ents = v7.ent()
        assert strs[funcs[0]['name']] == 'add'
        assert strs[funcs[1]['name']] == 'main'
        # add: 参数声明 = var 声明区前 2 个（a, b, TI_INT=0）
        add = funcs[0]
        assert add['param_count'] == 2
        assert add['var_count'] >= 3
        pdecls = add['var_decls'][:2]
        assert [strs[d['name']] for d in pdecls] == ['a', 'b']
        assert [d['type'] for d in pdecls] == [0, 0], "int param type != TI_INT"
        # 条目范围/param_ents 实回填——Python 侧块切分自洽（loader 块对照同
        # 语义）：add = 文件首块（func0 起点 0，含 a/b 的 def=-1 条目）
        vs = len(sym['globals'])
        pos = 0
        block_of = []
        for f in funcs:
            win = range(vs, vs + f['var_count'])
            start = pos
            while pos < len(ents) and ents[pos][0] in win:
                pos += 1
            block_of.append((start, pos - start))
            vs += f['var_count']
        assert pos == len(ents), "block partition did not cover all entries"
        for k, f in enumerate(funcs):
            st, pcnt = block_of[k]
            fe = st if pcnt else -1
            le = st + pcnt - 1 if pcnt else -1
            assert (f['first_ent'], f['last_ent']) == (fe, le), \
                f"func {k} range ({f['first_ent']},{f['last_ent']}) != " \
                f"block ({fe},{le})"
        # add 参数 a/b 从未定值但有引用 → def=-1 条目；param_ents 指向它们
        g0 = len(sym['globals'])
        for p in range(add['param_count']):
            pid = add['param_ents'][p]
            assert pid >= 0, \
                f"add param_ents[{p}] == -1 (expected def=-1 entry id)"
            (ev, evr, ed, els, ele, eho, efl) = ents[pid]
            assert ed == -1 and ev == g0 + p, \
                f"add param_ents[{p}] -> row {pid} var {ev} (want {g0 + p})"
        assert funcs[1]['param_count'] == 0 and funcs[1]['param_ents'] == []
        # 根 region（kind=0）行序 = 函数序 1:1；span 连续铺满 NOD 空间
        roots = [(i, r) for i, r in enumerate(regs) if r[0] == 0]
        assert len(roots) == len(funcs)
        prev_end = 0
        for k, (rid, r) in enumerate(roots):
            assert funcs[k]['root_region'] == rid
            assert r[2] == prev_end, f"root {k} enter {r[2]} != prev end {prev_end}"
            prev_end = r[3]
            # 根行 first/last = 函数块界（与 SYM 双写一致）
            assert (r[4], r[5]) == (funcs[k]['first_ent'],
                                    funcs[k]['last_ent'])
        assert prev_end == nod_cnt, \
            f"root spans end at {prev_end}, nod_count {nod_cnt}"
    finally:
        try:
            os.unlink(ccr_path)
        except FileNotFoundError:
            pass


def test_v7_loader_rejects_root_span_beyond_nod_space():
    """（迁移 GC-3——SYM 评审 M1）REG root span 对 NOD 空间上界校验。

    loader 解析序 REG → NOD：root region（SG_FUNC 行）的 enter/exit 在 REG
    段解析时就回填成函数指令边界，但 instr_cnt 直到 NOD 段才可知——彼时
    无上界校验（ENT 有 ele > instr_cnt 拒绝先例）。损坏文件把末函数 root
    region 的 exit_nod 推出 NOD 空间（exit == instr_cnt + 1）→ corearch 必须
    拒绝（'invalid .ccr'）。"""
    src = ("fn main() -> int {\n"
           "    s : ., mut = 0;\n"
           "    for i in 0..4 { s = s + i; }\n"
           "    return s;\n"
           "}\n")
    ccr_path = os.path.join(BASE, 'build/test_v7_rootspan.ccr')
    try:
        os.unlink(ccr_path)
    except FileNotFoundError:
        pass
    try:
        corec_ccr(src, ccr_path)
        data = bytearray(read_ccr(ccr_path))
        v7 = V7File(bytes(data))
        regs = v7.reg()
        nod_cnt = len(v7.nod())
        # 末函数 root region（最后一个 kind==0 行）：span 末 = NOD 空间末
        # （根行 span 连续铺满 NOD 空间的不变量），exit_nod += 1 → 越界
        roots = [i for i, r in enumerate(regs) if r[0] == 0]
        assert roots, f"no SG_FUNC rows in REG: {regs}"
        rid = roots[-1]
        assert regs[rid][3] == nod_cnt, \
            f"last root exit {regs[rid][3]} != nod_count {nod_cnt}: {regs[rid]}"
        reg_off, _ = v7.segs[5]
        patch_at = reg_off + 4 + rid * REG_REC + 12  # exit_nod field (+12 in row)
        struct.pack_into('<i', data, patch_at, regs[rid][3] + 1)
        bad_path = ccr_path + '.oob'
        with open(bad_path, 'wb') as fh:
            fh.write(bytes(data))
        r = subprocess.run([COREARCH, bad_path, '--elf', '--static',
                            '-o', os.path.join(BASE, 'build/test_v7_rootspan.out')],
                           capture_output=True, text=True, cwd=BASE, timeout=60)
        assert r.returncode != 0, \
            f"corearch accepted root span beyond NOD space: rc={r.returncode} {r.stdout!r}"
        assert 'invalid' in (r.stdout + r.stderr), \
            f"expected invalid-.ccr error, got: {r.stdout!r} {r.stderr!r}"
    finally:
        for p in (ccr_path, ccr_path + '.oob',
                  os.path.join(BASE, 'build/test_v7_rootspan.out')):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


def test_v7_save_rejects_var_block_misalignment():
    """（迁移 GC-4——SYM 评审 M2）save var 行序位置级守卫。

    计数级守卫（Σ func var_count == var_count + var_idx==gi）总量守恒时察觉
    不到块错位——func0 声明区起点左移 1（--inject-var-shift 测试钩子，真实
    构建路径永不注入）后 Σ 不变，旧实现静默落盘行序错位的文件（声明区/
    var 命名空间漂移）。位置级守卫（vs == 前缀累计）必须拒绝：rc != 0、
    不落盘。"""
    src = ("fn add(a: int, b: int) -> int { return a + b; }\n"
           "fn main() -> int {\n"
           "    x := 1;\n"
           "    return x + 1;\n"
           "}\n")
    ccr_path = os.path.join(BASE, 'build/test_v7_varshift.ccr')
    with tempfile.NamedTemporaryFile('w', suffix='.cr', delete=False) as f:
        f.write(src)
        path = f.name
    try:
        os.unlink(ccr_path)
    except FileNotFoundError:
        pass
    try:
        r = subprocess.run([COREC, 'ccr', path, '-o', ccr_path,
                            '--inject-var-shift'],
                           capture_output=True, text=True, cwd=BASE, timeout=120)
        out = r.stdout + r.stderr
        assert r.returncode != 0, \
            f"save accepted misaligned var block (rc=0):\n{out}"
        assert 'inject-var-shift: precondition' not in out, \
            f"hook precondition failed — test not exercising the guard:\n{out}"
        assert not os.path.exists(ccr_path), \
            "save wrote a .ccr file despite rejecting"
    finally:
        os.unlink(path)
        try:
            os.unlink(ccr_path)
        except FileNotFoundError:
            pass


# === Task 3 新增一：ENT 负分支补面（Task 2 review R1/R2——loader 校验路径
# 从未被现测试击中的分支逐个 byte mutation 打）===


def test_v7_loader_rejects_ent_var_foreign_block():
    """Task 2 review R1——ENT↔SYM 块重推导 reject 面（ccr_io.cr :1469-1478）。

    现存 sym_ent_block_mismatch 只打 SYM func first_ent——REG↔SYM 对照
    （:1331-1337）先于 ENT 解析触发，块重推导路径（:1452-1478）恒空走不到。
    本 mutation：func0（add）块首条目的 var_id 改写进 func1（main）var 窗口
    起点 → 逐条语义校验（ev 命名空间 :1431/区间 :1432/def 关系 :1433-1436）
    全过（只动 var_id 一字段）→ 块重推导见 func0 首条 var 不在其窗口 →
    pcnt=0 与 SYM first_ent 实值失配 → 拒绝。命中点唯一 = :1471-1478。"""
    src = ("fn add(a: int, b: int) -> int { return a + b; }\n"
           "fn main() -> int { return 42; }\n")
    ccr_path = os.path.join(BASE, 'build/test_v7_entblk2.ccr')
    try:
        os.unlink(ccr_path)
    except FileNotFoundError:
        pass
    try:
        corec_ccr(src, ccr_path)
        data = bytearray(read_ccr(ccr_path))
        v7 = V7File(bytes(data))
        sym = v7.sym_parse()
        funcs = sym['funcs']
        ents = v7.ent()
        assert funcs[0]['first_ent'] == 0, \
            f"precondition: func0 first entry at 0, got {funcs[0]['first_ent']}"
        vs1 = len(sym['globals']) + funcs[0]['var_count']  # func1 窗口起点
        assert ents[0][0] < vs1, \
            f"precondition: entry0 var {ents[0][0]} already outside func0 window"
        _mutate_ent_field(data, 0, 0, vs1, '<i')  # var_id := func1 窗口起点
        bad_path = ccr_path + '.fblk'
        with open(bad_path, 'wb') as fh:
            fh.write(bytes(data))
        r = subprocess.run([COREARCH, bad_path, '--elf', '--static',
                            '-o', os.path.join(BASE, 'build/test_v7_entblk2.out')],
                           capture_output=True, text=True, cwd=BASE, timeout=60)
        assert r.returncode != 0, \
            f"corearch accepted entry in foreign func window: rc={r.returncode}"
        assert 'invalid' in (r.stdout + r.stderr), \
            f"expected invalid-.ccr error, got: {r.stdout!r} {r.stderr!r}"
    finally:
        for p in (ccr_path, ccr_path + '.fblk',
                  os.path.join(BASE, 'build/test_v7_entblk2.out')):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


def test_v7_loader_rejects_ent_var_namespace_oob():
    """Task 2 review R2——ENT var_id 命名空间校验（ccr_io.cr :1431）：var_id
    改写出 SYM 行重建总量（= loader 侧 g_ir_var_count）→ 逐条校验拒绝。"""
    src = "fn main() -> int { return 42; }\n"
    ccr_path = os.path.join(BASE, 'build/test_v7_entns.ccr')
    try:
        os.unlink(ccr_path)
    except FileNotFoundError:
        pass
    try:
        corec_ccr(src, ccr_path)
        data = bytearray(read_ccr(ccr_path))
        v7 = V7File(bytes(data))
        sym = v7.sym_parse()
        total = len(sym['globals']) + sum(f['var_count'] for f in sym['funcs'])
        ents = _mutate_ent_field(data, 0, 0, total, '<i')  # ev := 命名空间外
        assert ents[0][0] != total, "precondition: var_id already == total"
        bad_path = ccr_path + '.ns'
        with open(bad_path, 'wb') as fh:
            fh.write(bytes(data))
        r = subprocess.run([COREARCH, bad_path, '--elf', '--static',
                            '-o', os.path.join(BASE, 'build/test_v7_entns.out')],
                           capture_output=True, text=True, cwd=BASE, timeout=60)
        assert r.returncode != 0, \
            f"corearch accepted var_id outside namespace: rc={r.returncode}"
        assert 'invalid' in (r.stdout + r.stderr), \
            f"expected invalid-.ccr error, got: {r.stdout!r} {r.stderr!r}"
    finally:
        for p in (ccr_path, ccr_path + '.ns',
                  os.path.join(BASE, 'build/test_v7_entns.out')):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


def _first_def_entry(ents):
    """首个 def_nod ≥ 0 的条目下标（定值条目——mutation 需维持 ed ≥ 0 才走
    :1433-1436 分支；恒存在：每函数 _arena 定值条目）。"""
    for i, e in enumerate(ents):
        if e[2] >= 0:
            return i
    raise AssertionError("no def entry found (def_nod >= 0)")


def test_v7_loader_rejects_ent_def_nod_oob():
    """Task 2 review R2——ENT def_nod 越界（ccr_io.cr :1434）：定值条目的
    def_nod 改写为 instr_cnt（= NOD 空间外第一个坐标）→ 拒绝。"""
    src = "fn main() -> int { return 42; }\n"
    ccr_path = os.path.join(BASE, 'build/test_v7_entdef.ccr')
    try:
        os.unlink(ccr_path)
    except FileNotFoundError:
        pass
    try:
        corec_ccr(src, ccr_path)
        data = bytearray(read_ccr(ccr_path))
        v7 = V7File(bytes(data))
        nod_cnt = len(v7.nod())
        idx = _first_def_entry(v7.ent())  # 定值条目（ed >= 0 才走 :1433-1436）
        _mutate_ent_field(data, idx, 8, nod_cnt, '<i')  # def_nod := instr_cnt
        bad_path = ccr_path + '.oob'
        with open(bad_path, 'wb') as fh:
            fh.write(bytes(data))
        r = subprocess.run([COREARCH, bad_path, '--elf', '--static',
                            '-o', os.path.join(BASE, 'build/test_v7_entdef.out')],
                           capture_output=True, text=True, cwd=BASE, timeout=60)
        assert r.returncode != 0, \
            f"corearch accepted def_nod beyond NOD space: rc={r.returncode}"
        assert 'invalid' in (r.stdout + r.stderr), \
            f"expected invalid-.ccr error, got: {r.stdout!r} {r.stderr!r}"
    finally:
        for p in (ccr_path, ccr_path + '.oob',
                  os.path.join(BASE, 'build/test_v7_entdef.out')):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


def test_v7_loader_rejects_ent_def_ne_live_start():
    """Task 2 review R2——ENT 定值条目 def == live_start 失配（ccr_io.cr
    :1435）：定值条目 def_nod 改写为 els+1（仍在 NOD 空间内 → 只触发
    ed != els 分支）→ 拒绝。"""
    src = "fn main() -> int { return 42; }\n"
    ccr_path = os.path.join(BASE, 'build/test_v7_entdls.ccr')
    try:
        os.unlink(ccr_path)
    except FileNotFoundError:
        pass
    try:
        corec_ccr(src, ccr_path)
        data = bytearray(read_ccr(ccr_path))
        v7 = V7File(bytes(data))
        nod_cnt = len(v7.nod())
        ents = v7.ent()
        idx = _first_def_entry(ents)
        (ev, evr, ed, els, ele, eho, efl) = ents[idx]
        assert els + 1 < nod_cnt, \
            f"precondition: els {els}+1 must stay in NOD space ({nod_cnt})"
        _mutate_ent_field(data, idx, 8, els + 1, '<i')  # def_nod := els+1
        bad_path = ccr_path + '.dne'
        with open(bad_path, 'wb') as fh:
            fh.write(bytes(data))
        r = subprocess.run([COREARCH, bad_path, '--elf', '--static',
                            '-o', os.path.join(BASE, 'build/test_v7_entdls.out')],
                           capture_output=True, text=True, cwd=BASE, timeout=60)
        assert r.returncode != 0, \
            f"corearch accepted def_nod != live_start: rc={r.returncode}"
        assert 'invalid' in (r.stdout + r.stderr), \
            f"expected invalid-.ccr error, got: {r.stdout!r} {r.stderr!r}"
    finally:
        for p in (ccr_path, ccr_path + '.dne',
                  os.path.join(BASE, 'build/test_v7_entdls.out')):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


# === Task 3 新增二：cache-hit 恢复路径回归（Task 1 review Minor M2）===
# 全测试族惯例清 .core/cache → 恢复路径（cir_cache load）零覆盖；本测试锁定
# 观察流（2026-09-10 探针实测，断言 = 实测关系）：
#   冷（fresh 全编译）vs 暖（全函数 cache-hit 恢复）：SYM/NOD/ENT/REG/EDG
#   五段体逐字节相同——EDG/ENT 经恢复路径零漂移（本测试核心锁）；
#   STR：暖表 = 冷表前缀——冷多出尾部无引用字符串（Minor 3 现象级注记：
#   编译器内名（_arena 等）二次 interning，review 实测 ~108B 级；本程序实测
#   16 条 ~143B，方向/数量随程序形态变——良性：无引用、walker 走满校验过、
#   其余段全等，断言只锁前缀关系不锁字节数）；
#   暖运行不重写缓存文件（miss → load 失败 → 重编译 → save → mtime 变）。
#   hybrid（单函数改动，同路径再编译）产物 == 清缓存后冷编译同一源文件，
#   全文件 byte-identical（full-file rewrite 观察流）；corearch 双载行为一致。


def test_v7_cache_hit_restore_path():
    cache_dir = os.path.join(BASE, '.core', 'cache')
    cir_dir = os.path.join(cache_dir, 'cir')
    src_path = os.path.join(BASE, 'build', 'test_v7_cache_src.cr')
    out_cold = os.path.join(BASE, 'build', 'test_v7_cache_cold.ccr')
    out_warm = os.path.join(BASE, 'build', 'test_v7_cache_warm.ccr')
    out_hyb = os.path.join(BASE, 'build', 'test_v7_cache_hyb.ccr')
    out_cold2 = os.path.join(BASE, 'build', 'test_v7_cache_cold2.ccr')
    elf_cold = os.path.join(BASE, 'build', 'test_v7_cache_cold.elf')
    elf_warm = os.path.join(BASE, 'build', 'test_v7_cache_warm.elf')
    elf_hyb = os.path.join(BASE, 'build', 'test_v7_cache_hyb.elf')
    elf_cold2 = os.path.join(BASE, 'build', 'test_v7_cache_cold2.elf')
    artifacts = [src_path, out_cold, out_warm, out_hyb, out_cold2,
                 elf_cold, elf_warm, elf_hyb, elf_cold2]
    src1 = ("fn mul2(x: int) -> int { return x * 2; }\n"
            "fn main() -> int {\n"
            "    s : ., mut = 0;\n"
            "    for i in 0..4 { s = s + mul2(i); }\n"
            "    return s;\n"   # Σ mul2(0..3) = 0+2+4+6 = 12
            "}\n")
    src2 = src1.replace('0..4', '0..6')  # Σ mul2(0..5) = 30

    def ccr_run(out: str) -> None:
        r = subprocess.run([COREC, 'ccr', src_path, '-o', out],
                           capture_output=True, text=True, cwd=BASE, timeout=120)
        assert r.returncode == 0, f"corec ccr failed rc={r.returncode}: {r.stderr}"

    def arch_elf(ccr_in: str, elf_out: str) -> None:
        r = subprocess.run([COREARCH, ccr_in, '--elf', '--static', '-o', elf_out],
                           capture_output=True, text=True, cwd=BASE, timeout=120)
        assert r.returncode == 0, \
            f"corearch load failed: {r.stdout!r} {r.stderr!r}"
        os.chmod(elf_out, 0o755)

    try:
        shutil.rmtree(cache_dir, ignore_errors=True)
        with open(src_path, 'w') as fh:
            fh.write(src1)
        ccr_run(out_cold)                      # 冷：全编译 + 播种缓存
        cold = read_ccr(out_cold)
        # 命中证据：暖运行不重写缓存文件（miss → 重编译 → save → mtime 变）
        snap = {os.path.join(cir_dir, f): os.stat(
                    os.path.join(cir_dir, f)).st_mtime_ns
                for f in os.listdir(cir_dir)}
        assert snap, "cold run did not populate cir cache"
        ccr_run(out_warm)                      # 暖：全函数恢复路径
        for p, ns in snap.items():
            assert os.stat(p).st_mtime_ns == ns, \
                f"warm run rewrote cache file {p} (not a full hit?)"
        warm = read_ccr(out_warm)
        vc = V7File(cold)
        vw = V7File(warm)
        # 核心锁：恢复路径下 SYM/NOD/ENT/REG/EDG 五段体逐字节相同
        for tag in (2, 3, 4, 5, 6):
            assert vc.body(tag) == vw.body(tag), \
                f"segment {tag} drifted on cache-hit restore"
        # STR：暖表 = 冷表前缀（冷多出尾部 = 无引用内名二次 interning）
        sc, sw = vc.str_table(), vw.str_table()
        assert len(sw) <= len(sc), \
            f"warm STR {len(sw)} > cold STR {len(sc)} (restore bloat?)"
        assert sc[:len(sw)] == sw, \
            "warm STR not a prefix of cold STR"
        # corearch 行为一致：冷/暖双载 + 运行同退出码
        arch_elf(out_cold, elf_cold)
        arch_elf(out_warm, elf_warm)
        for p in (elf_cold, elf_warm):
            r = subprocess.run([p], capture_output=True, timeout=10)
            assert r.returncode == 12, \
                f"{p} exit {r.returncode} != 12 (cold/warm divergence)"
        # hybrid：单函数改动（main 体 + 循环上界）→ 再编译（部分/全量命中
        # 视指纹失效粒度——产物断言不依赖）→ 产物 == 清缓存冷编译全文件
        with open(src_path, 'w') as fh:
            fh.write(src2)
        ccr_run(out_hyb)
        shutil.rmtree(cache_dir, ignore_errors=True)
        ccr_run(out_cold2)
        assert read_ccr(out_hyb) == read_ccr(out_cold2), \
            "hybrid cache output != full-cold compile (stale graph/STR drift?)"
        arch_elf(out_hyb, elf_hyb)
        arch_elf(out_cold2, elf_cold2)
        for p in (elf_hyb, elf_cold2):
            r = subprocess.run([p], capture_output=True, timeout=10)
            assert r.returncode == 30, \
                f"{p} exit {r.returncode} != 30"
    finally:
        for p in artifacts:
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass
        shutil.rmtree(cache_dir, ignore_errors=True)


if __name__ == '__main__':
    shutil.rmtree(os.path.join(BASE, '.core', 'cache'), ignore_errors=True)
    tests = [test_v7_layout_and_walk,
             test_v7_edge_content_small_program,
             test_v7_object_surface_recipe_readable,
             test_v7_ent_hand_expected_small,
             test_v7_ent_hand_expected_pure_add_block,
             test_v7_ent_model_replay_pure_add,
             test_v7_ent_real_optmeta_absent,
             test_v7_sym_reg_target_shape,
             test_v7_sym_func_shapes,
             test_v7_loader_rejects_bad_ent_version,
             test_v7_loader_rejects_ent_liveend_oob,
             test_v7_loader_rejects_ent_ls_ge_le,
             test_v7_loader_rejects_ent_var_foreign_block,
             test_v7_loader_rejects_ent_var_namespace_oob,
             test_v7_loader_rejects_ent_def_nod_oob,
             test_v7_loader_rejects_ent_def_ne_live_start,
             test_v7_loader_rejects_sym_ent_block_mismatch,
             test_v7_loader_rejects_root_span_beyond_nod_space,
             test_v7_loader_rejects_version_ne_7,
             test_v7_loader_rejects_backward_edge,
             test_v7_loader_rejects_edg_count_mismatch,
             test_v7_save_rejects_var_block_misalignment,
             test_v7_cache_hit_restore_path,
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
