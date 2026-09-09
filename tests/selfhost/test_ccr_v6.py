#!/usr/bin/env python3
"""v6 测试族（迁移期 Task 1——段契约机械更新至 v7；Task 3 合并进
test_ccr_v7.py，本文件退役）——v7 .ccr 格式 IO 测试：段表架构 + EDG 段必落 +
SYM 归并/REG 坐标化 + NOD 36B 邻接。

注（2026-09-07 regalloc 移后端，D-1=Y/R2）：corec save 不再携带 ENT 条目与
opt_meta（数据面/分配归位 corearch 自算）——ENT 段恒 0 条、SYM func/REG
first_ent/last_ent 恒 -1、param_ents 恒 -1、opt_count 恒 0。段结构与 loader
兼容语义保留（空表对照 pcnt==0 ↔ -1；格式描述 = loader 仍支持的形状）。
Task 1 翻转：EDG 段必落（v7 spec §3.4）——NOD 36B（28B 语义字段 + 邻接
first_edge/edge_count）、段表 6 项、loader 拒 version≠7（v6 读路径退役）。

格式真相：docs/superpowers/specs/2026-09-09-lattice-ir-v7-format.md（§3/§4）
+ ccr_io.cr 头注释（SYM 归并 spec §3.2——globals/funcs/str_consts/structs/
enums/opt_meta；REG 坐标化——kind/parent/enter/exit/first_ent/last_ent）。
落盘布局（全 LE，offset 相对文件头）：
  [0]   magic u32 = 0x31524343 ("CCR1")
  [4]   version u32 = 7
  [8]   seg_count u32 = 6
  [12]  reserved u32 = 0
  [16]  段表 6 × 12B {tag u32, offset u32, size u32}（规范序 tag 1..6）
  [88]  段体（tag 升序）：STR / SYM / NOD / ENT / REG / EDG
  STR(1): str_count + {len u32, data}
  SYM(2): globals 16B（var_idx 槽 → type）前置 + 函数记录内嵌 var 声明区：
    [global_count][globals × {name u32, type u32, init_val i64}]
    [func_count][funcs × {name u32, param_count u32, ret_type u32,
                 root_region i32, first_ent i32, last_ent i32 |
                 param_ents[param_count]×i32（参数 def=-1 条目 id，-1=无）|
                 var_count u32, var_decls[var_count]×{name u32, type u32}}]
    [str_const_count][×4B][structs][enums][opt_meta]
  NOD(3): nod_count + 36B×nod_count
          {op i32, dest i32, s1 i64, s2 i32, s3 i32, tk i32,
           first_edge u32, edge_count u32}（28B = v5 instrs 内容不变；
           NOD id = 文件序；邻接 = 节点出边 EDG 段连续段）
  ENT(4): ent_count + 28B×ent_count
          {var_id i32, version u32, def_nod i32, live_start u32,
           live_end u32（半开 = 最后使用点+1）, home i32, flags u32}
          （Task 1：恒空——Task 2 翻转）
  REG(5): sg_count + 24B×sg_count {kind u32, parent i32, enter_nod u32,
          exit_nod u32, first_ent i32, last_ent i32}（nstart/ncount 由
          enter/exit 派生；first/last = 区内条目范围——定值点 ∈ [enter, exit)）
  EDG(6): edg_count + 8B×edg_count {to_nod u32, kind u32}（v7 必落——边段；
          所属节点 = 邻接隐含；每条边 to_nod > 所属节点；kind 0=数据 1=state）
"""
import os
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


class V7File:
    """Parse a v7 .ccr file into its segments. Raises AssertionError on layout
    violations (mirrors load_ccr's segment-table contract)."""

    def __init__(self, data: bytes):
        self.d = data
        assert len(data) >= 88, f"file too small for v7 header+table: {len(data)}"
        (magic, ver, seg_count, reserved) = struct.unpack_from('<4I', data, 0)
        assert magic == MAGIC, f"bad magic {magic:#x}"
        assert ver == V7, f"expected version {V7}, got {ver}"
        assert seg_count == 6, f"expected 6 segments, got {seg_count}"
        assert reserved == 0, f"reserved != 0: {reserved}"
        # Segment table: canonical order, contiguous layout
        self.segs = {}
        cur = 16 + seg_count * 12  # first body follows the whole table
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
        """Parse the whole SYM body (target shape: globals → funcs with embedded
        var-decl areas → str_consts → structs → enums → opt_meta). Asserts
        end == body size (mirrors load_ccr). Returns a structured dict."""
        b = self.body(2)
        pos = 0

        def u32():
            nonlocal pos
            v = struct.unpack_from('<I', b, pos)[0]
            pos += 4
            return v

        def i32():
            nonlocal pos
            v = struct.unpack_from('<i', b, pos)[0]
            pos += 4
            return v

        g = u32()  # global_count
        globals_ = []
        for _ in range(g):
            (name, ty, init) = struct.unpack_from('<IIq', b, pos)
            pos += 16
            globals_.append({'name': name, 'type': ty, 'init': init})
        n = u32()  # func_count
        funcs = []
        for _ in range(n):
            (name, pc, rt, root, fe, le) = struct.unpack_from('<IIiiii', b, pos)
            pos += 24
            param_ents = [i32() for _ in range(pc)]
            vc = u32()  # var_count
            decls = []
            for _ in range(vc):
                (vn, vt) = struct.unpack_from('<II', b, pos)
                pos += 8
                decls.append({'name': vn, 'type': vt})
            funcs.append({'name': name, 'param_count': pc, 'ret_type': rt,
                          'root_region': root, 'first_ent': fe, 'last_ent': le,
                          'param_ents': param_ents, 'var_count': vc,
                          'var_decls': decls})
        scn = u32()  # str_const_count
        pos += scn * 4
        stn = u32()  # struct_count
        for _ in range(stn):
            u32()
            fc = u32()
            pos += fc * 8
        en = u32()  # enum_count
        for _ in range(en):
            u32()
            vc2 = u32()
            for _ in range(vc2):
                u32()
                tc = u32()
                pos += tc * 4
        oc = u32()  # opt_count
        for _ in range(oc):
            u32()
            dl = u32()
            pos += dl
        assert pos == len(b), f"SYM walk ended at {pos} of {len(b)}"
        return {'globals': globals_, 'funcs': funcs,
                'str_const_count': scn, 'struct_count': stn,
                'enum_count': en, 'opt_count': oc}

    def nod(self):
        """NOD 36B: {op, dest, s1, s2, s3, tk, first_edge, edge_count}——28B
        语义字段 + 邻接索引（v7 spec §3.3；loader 由 28B 字段重建线性流，
        发射输入与 v6 逐字段一致）。"""
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
            # var_id i32, version u32, def_nod i32, live_start u32,
            # live_end u32 (half-open), home i32, flags u32
            out.append(struct.unpack_from('<iIiIIiI', b, pos))
            pos += ENT_REC
        return out

    def reg(self):
        """REG rows: {kind, parent, enter_nod, exit_nod, first_ent, last_ent}."""
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
        """EDG records + per-node run reconstruction + v7 §4 校验（镜像 loader）：
        连续邻接（first_edge == 前缀累计）、Σ edge_count == edg_count、行走完
        == 段体大小、每条边 to_nod > 所属节点、kind ∈ {0=数据, 1=state}。
        Returns {node: [(to, kind), ...]}."""
        b = self.body(6)
        (edg_cnt,) = struct.unpack_from('<I', b, 0)
        assert (len(b) - 4) % EDG_REC == 0, "EDG body size not a multiple of 8"
        assert edg_cnt == (len(b) - 4) // EDG_REC, f"EDG count {edg_cnt} != bytes/8"
        pos = 4
        edges = {}
        run_off = 0
        for i, nod_row in enumerate(self.nod()):
            (fe, ec) = nod_row[6:8]
            assert fe == run_off, \
                f"node {i}: first_edge {fe} != cumulative offset {run_off}"
            assert run_off + ec <= edg_cnt, \
                f"node {i}: run exceeds edg_count {edg_cnt}"
            row = []
            for _ in range(ec):
                (to, kind) = struct.unpack_from('<II', b, pos)
                pos += EDG_REC
                assert to > i, f"edge {i}->{to}: not forward (to_nod <= node)"
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
    """Run `corec ccr` on src; returns stdout."""
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

def test_header_segment_table_and_walk():
    """段表架构：magic/version=7/6 段规范序（EDG tag 6 必落）/offset 连续/
    NOD 36B/EDG 走查 == 文件大小。"""
    src = ("fn add(a: int, b: int) -> int { return a + b; }\n"
           "fn main() -> int {\n"
           "    s : ., mut = 0;\n"
           "    for i in 0..4 { s = s + i; }\n"
           "    return s;\n"
           "}\n")
    ccr_path = os.path.join(BASE, 'build/test_v6_layout.ccr')
    try:
        os.unlink(ccr_path)
    except FileNotFoundError:
        pass
    try:
        corec_ccr(src, ccr_path)
        v7 = V7File(read_ccr(ccr_path))
        # every segment body present and non-empty beyond its count
        assert v7.fsize > 88
        strs = v7.str_table()
        assert len(strs) >= 2, f"expected >=2 strings, got {len(strs)}"
        sym = v7.sym_parse()  # validates the full SYM body layout
        assert len(sym['funcs']) >= 1 and len(sym['globals']) >= 1
        n = v7.nod()
        assert len(n) > 4, f"expected nodes, got {len(n)}"
        reg = v7.reg()
        assert len(reg) >= 2, f"expected >=2 regions (func+for), got {len(reg)}"
        e = v7.ent()
        assert e == [], "ENT not empty (regalloc move: corec no longer saves entries)"
        edg = v7.edg()  # EDG 段必落 + 邻接/拓扑/Σ 校验走查
        assert sum(len(v) for v in edg.values()) >= 2, \
            f"EDG unexpectedly small: {edg}"
    finally:
        try:
            os.unlink(ccr_path)
        except FileNotFoundError:
            pass


def test_ent_optmeta_absent_after_move():
    """regalloc 移后端（D-1=Y/R2，2026-09-07）：corec save 不再携带 ENT 与
    opt_meta——ENT 段恒 0 条、SYM func/REG first_ent/last_ent 恒 -1、
    param_ents 恒 -1、opt_count 恒 0（格式结构与 loader 空表语义保留：
    loader 对照 pcnt==0 ↔ -1 已支持）。数据面正确性 = corearch 自算通道
    （--dump-entries/--check-regalloc，载体 = test_live_ranges）。"""
    src = ("fn identity(n: int) -> int { return n; }\n"
           "fn main() -> int {\n"
           "    x := 1;\n"
           "    x = x + 1;\n"
           "    x = x + 2;\n"
           "    return x;\n"
           "}\n")
    ccr_path = os.path.join(BASE, 'build/test_v6_ent.ccr')
    try:
        os.unlink(ccr_path)
    except FileNotFoundError:
        pass
    try:
        corec_ccr(src, ccr_path)
        v7 = V7File(read_ccr(ccr_path))
        assert v7.ent() == [], f"ENT not empty after regalloc move: {v7.ent()}"
        sym = v7.sym_parse()
        assert sym['opt_count'] == 0, f"opt_meta not empty: {sym['opt_count']}"
        for f in sym['funcs']:
            assert f['first_ent'] == -1 and f['last_ent'] == -1, \
                f"func {f} first/last_ent != -1"
            assert all(pe == -1 for pe in f['param_ents']), \
                f"func {f} param_ents not all -1"
        for r in v7.reg():
            assert r[4] == -1 and r[5] == -1, f"REG row carries entry range: {r}"
    finally:
        try:
            os.unlink(ccr_path)
        except FileNotFoundError:
            pass


def test_loader_rejects_non_v7_version():
    """v7-only（v6 读路径退役）：version 字段改成 6（v6 文件——旧生态直接
    拒绝，无转换工具）或任意非 7 → corearch 必须拒绝。"""
    src = "fn main() -> int { return 42; }\n"
    ccr_path = os.path.join(BASE, 'build/test_v6_reject.ccr')
    try:
        os.unlink(ccr_path)
    except FileNotFoundError:
        pass
    try:
        corec_ccr(src, ccr_path)
        for bad_ver in (6, 5):
            data = bytearray(read_ccr(ccr_path))
            struct.pack_into('<I', data, 4, bad_ver)  # patch version
            bad_path = ccr_path + f'.v{bad_ver}'
            with open(bad_path, 'wb') as fh:
                fh.write(bytes(data))
            r = subprocess.run([COREARCH, bad_path, '--elf', '--static',
                                '-o', os.path.join(BASE, 'build/test_v6_reject.out')],
                               capture_output=True, text=True, cwd=BASE, timeout=60)
            assert r.returncode != 0, \
                f"corearch accepted a version-{bad_ver}-patched file: rc={r.returncode} {r.stdout!r}"
            assert 'invalid' in (r.stdout + r.stderr), \
                f"expected invalid-.ccr error, got: {r.stdout!r} {r.stderr!r}"
    finally:
        for p in (ccr_path, ccr_path + '.v6', ccr_path + '.v5',
                  os.path.join(BASE, 'build/test_v6_reject.out')):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


def test_ccr_v6_roundtrip_elf():
    """v7 落盘 → corec build 全链路（corec save v7 → corearch load v7 → ELF）：
    程序计算 0+1+2+3+4+5 = 15，ELF 运行时以 main 返回值为退出码。"""
    src = ("fn main() -> int {\n"
           "    s : ., mut = 0;\n"
           "    for i in 0..6 { s = s + i; }\n"
           "    return s;\n"
           "}\n")
    ccr_path = os.path.join(BASE, 'build/test_v6_rt.ccr')
    out = os.path.join(BASE, 'build/test_v6_rt')
    try:
        os.unlink(ccr_path)
    except FileNotFoundError:
        pass
    try:
        os.unlink(out)
    except FileNotFoundError:
        pass
    try:
        with tempfile.NamedTemporaryFile('w', suffix='.cr', delete=False) as f:
            f.write(src)
            path = f.name
        # 1) corec build (its own corearch invocation) round-trips v7
        r = subprocess.run([COREC, 'build', path, '-o', out, '--static'],
                           capture_output=True, text=True, cwd=BASE, timeout=120)
        assert r.returncode == 0, f"corec build failed: {r.stderr}"
        os.chmod(out, 0o755)
        run = subprocess.run([out], capture_output=True, text=True, timeout=10)
        assert run.returncode == 15, \
            f"expected exit 15 (sum 0..5), got {run.returncode} stdout={run.stdout!r}"
        assert os.path.exists(ccr_path), "corec build did not save .ccr alongside output"
        v7 = V7File(read_ccr(ccr_path))  # the built artifact is v7
        assert v7.ent() == [], "built .ccr should carry no ENT (regalloc move: corearch self-computes)"
        assert sum(len(v) for v in v7.edg().values()) >= 2, "built .ccr EDG empty"
        # 2) direct corearch invocation on the same .ccr
        out2 = os.path.join(BASE, 'build/test_v6_rt2')
        try:
            os.unlink(out2)
        except FileNotFoundError:
            pass
        r = subprocess.run([COREARCH, ccr_path, '--elf', '--static', '-o', out2],
                           capture_output=True, text=True, cwd=BASE, timeout=120)
        assert r.returncode == 0, f"corearch load v7 failed: {r.stdout} {r.stderr}"
        os.chmod(out2, 0o755)
        run2 = subprocess.run([out2], capture_output=True, text=True, timeout=10)
        assert run2.returncode == 15, \
            f"corearch-only run expected 15, got {run2.returncode} stdout={run2.stdout!r}"
        try:
            os.unlink(out2)
        except FileNotFoundError:
            pass
    finally:
        os.unlink(path)
        for p in (ccr_path, out):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


def test_sym_reg_target_shape():
    """SYM 归并/REG 坐标化目标形状（spec §3.2/§3.5 落地）：
    - SYM func 记录 = {name/param_count/ret_type/root_region/first_ent/last_ent}
      + param_ents + var 声明区（v5 vars 表并入）；globals 记录带 type；
    - REG 记录 = {kind, parent, enter_nod, exit_nod, first_ent, last_ent}；
    - 根 region（SG_FUNC）行与 func 记录 1:1，span 连续铺满 NOD 空间，
      first/last = 本函数条目块；嵌套 region 条目范围 = 定值点 ∈ [enter, exit)
      （文件条目序连续一段）；变量命名空间行数覆盖 ENT/NOD 引用。"""
    src = ("fn main() -> int {\n"
           "    s : ., mut = 0;\n"
           "    for i in 0..4 { s = s + i; }\n"
           "    return s;\n"
           "}\n")
    ccr_path = os.path.join(BASE, 'build/test_v6_symreg.ccr')
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
        # 全局记录：有数据（>=1 条），全局行数 = var 行序前缀（func0 var 基准）
        assert len(globs) >= 1
        g_base = len(globs)
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
            # 邻接域自洽（完整校验在 edg() 走查）
            assert fe >= 0 and ec >= 0
    finally:
        try:
            os.unlink(ccr_path)
        except FileNotFoundError:
            pass


def test_sym_func_shapes():
    """SYM func 记录形状（ENT 恒空后——原参数 def=-1 条目/条目块序断言载体已
    随 regalloc 移后端消亡，数据面断言归 test_live_ranges/corearch 通道）：
    add/main 行序 = 声明序；参数 = var 声明区前 param_count 个（行序 = 参数序，
    类型 int）；root_region 行序 1:1、span 连续铺满 NOD 空间；恒空字段 =
    first/last_ent 与 param_ents 全 -1。"""
    src = ("fn add(a: int, b: int) -> int { return a + b; }\n"
           "fn main() -> int {\n"
           "    x := 1;\n"
           "    x = x + 1;\n"
           "    x = x + 2;\n"
           "    return x;\n"
           "}\n")
    ccr_path = os.path.join(BASE, 'build/test_v6_symparams.ccr')
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
        assert strs[funcs[0]['name']] == 'add'
        assert strs[funcs[1]['name']] == 'main'
        # add: 参数声明 = var 声明区前 2 个（a, b, TI_INT=0）
        add = funcs[0]
        assert add['param_count'] == 2
        assert add['var_count'] >= 3
        pdecls = add['var_decls'][:2]
        assert [strs[d['name']] for d in pdecls] == ['a', 'b']
        assert [d['type'] for d in pdecls] == [0, 0], "int param type != TI_INT"
        # 恒空字段（regalloc 移后端：.ccr 无 ENT——参数字段与条目范围全 -1）
        for f in funcs:
            assert f['first_ent'] == -1 and f['last_ent'] == -1, f
            assert all(pe == -1 for pe in f['param_ents']), f
        # 根 region（kind=0）行序 = 函数序 1:1；span 连续铺满 NOD 空间
        roots = [(i, r) for i, r in enumerate(regs) if r[0] == 0]
        assert len(roots) == len(funcs)
        assert funcs[0]['root_region'] == roots[0][0]
        assert funcs[1]['root_region'] == roots[1][0]
        prev_end = 0
        for k, (rid, r) in enumerate(roots):
            assert funcs[k]['root_region'] == rid
            assert r[2] == prev_end, f"root {k} enter {r[2]} != prev end {prev_end}"
            prev_end = r[3]
        assert prev_end == nod_cnt, \
            f"root spans end at {prev_end}, nod_count {nod_cnt}"
    finally:
        try:
            os.unlink(ccr_path)
        except FileNotFoundError:
            pass


def test_loader_rejects_root_span_beyond_nod_space():
    """GC-3（SYM 评审 M1）：REG root span 对 NOD 空间上界校验。

    loader 解析序 REG → NOD：root region（SG_FUNC 行）的 enter/exit 在 REG
    段解析时就回填成函数指令边界，但 instr_cnt 直到 NOD 段才可知——彼时
    无上界校验（ENT 有 ele > instr_cnt 拒绝先例）。损坏文件把末函数 root
    region 的 exit_nod 推出 NOD 空间（exit == instr_cnt + 1）→ corearch 必须
    拒绝（'invalid .ccr'）。守卫缺失时 loader 静默接受并在缓冲外读指令
    发射（GC-1 同族数据面缺陷）。"""
    src = ("fn main() -> int {\n"
           "    s : ., mut = 0;\n"
           "    for i in 0..4 { s = s + i; }\n"
           "    return s;\n"
           "}\n")
    ccr_path = os.path.join(BASE, 'build/test_v6_rootspan.ccr')
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
                            '-o', os.path.join(BASE, 'build/test_v6_rootspan.out')],
                           capture_output=True, text=True, cwd=BASE, timeout=60)
        assert r.returncode != 0, \
            f"corearch accepted root span beyond NOD space: rc={r.returncode} {r.stdout!r}"
        assert 'invalid' in (r.stdout + r.stderr), \
            f"expected invalid-.ccr error, got: {r.stdout!r} {r.stderr!r}"
    finally:
        for p in (ccr_path, ccr_path + '.oob',
                  os.path.join(BASE, 'build/test_v6_rootspan.out')):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


def test_save_rejects_var_block_misalignment():
    """GC-4（SYM 评审 M2）：save var 行序位置级守卫。

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
    ccr_path = os.path.join(BASE, 'build/test_v6_varshift.ccr')
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


if __name__ == '__main__':
    tests = [test_header_segment_table_and_walk,
             test_ent_optmeta_absent_after_move,
             test_sym_reg_target_shape,
             test_sym_func_shapes,
             test_loader_rejects_non_v7_version,
             test_loader_rejects_root_span_beyond_nod_space,
             test_save_rejects_var_block_misalignment,
             test_ccr_v6_roundtrip_elf]
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
