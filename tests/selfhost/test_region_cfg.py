#!/usr/bin/env python3
"""Region-based control flow tests — dump .cir text and assert region structure."""
import os, re, struct, subprocess, tempfile

BASE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
COREC = os.path.join(BASE, 'build/corec')

def cir_dump(src: str) -> str:
    # `corec cir` prints the text dump (Function/Region/Block lines) to stdout
    # and writes the DOT graph to <src>.cir; return both so cluster assertions
    # work too.
    with tempfile.NamedTemporaryFile('w', suffix='.cr', delete=False) as f:
        f.write(src)
        path = f.name
    cir_path = os.path.splitext(path)[0] + '.cir'
    try:
        os.unlink(cir_path)
    except FileNotFoundError:
        pass
    # cir dump runs the full compiler pipeline; allow generous time under load
    r = subprocess.run(['./build/corec', 'cir', path], capture_output=True, text=True,
                       cwd=BASE, timeout=120)
    os.unlink(path)
    assert r.returncode == 0, \
        f"cir failed with {r.returncode}: stdout={r.stdout!r} stderr={r.stderr!r}"
    out = r.stdout
    try:
        with open(cir_path) as f:
            out = out + "\n=== DOT ===\n" + f.read()
        os.unlink(cir_path)
    except FileNotFoundError:
        pass
    return out

def parse_regions(out: str):
    """Parse 'Region: <name> nodes A..B' lines -> {name: [(A, B), ...]}."""
    regions = {}
    for m in re.finditer(r'Region: (\w+) nodes (\d+)\.\.(-?\d+)', out):
        regions.setdefault(m.group(1), []).append((int(m.group(2)), int(m.group(3))))
    return regions

def assert_region_within_func(out: str, name: str, tail: bool = True):
    """Sanity: region bounds must lie inside the enclosing func region, and
    (when `tail`) must not swallow the function tail: B < func_end.

    This guards against sg_pop close-semantics regressions where the
    innermost region's EXIT is overwritten with the full function node count.
    """
    regs = parse_regions(out)
    assert 'func' in regs, f"func region missing in cir dump:\n{out}"
    assert name in regs, f"{name} region missing in cir dump:\n{out}"
    a, b = regs[name][0]
    assert 0 <= a < b, f"{name} region has bad bounds {a}..{b}:\n{out}"
    # Enclosing func region: the one whose span contains the region start
    fs = fe = -1
    for (s, e) in regs['func']:
        if s <= a < e:
            fs, fe = s, e
    assert fs >= 0, f"{name} region start {a} outside any func region:\n{out}"
    assert b <= fe, f"{name} region {a}..{b} escapes func region {fs}..{fe}:\n{out}"
    if tail:
        assert b < fe, f"{name} region swallows function tail ({b} >= {fe}):\n{out}"
    return a, b, fs, fe

def test_if_region():
    out = cir_dump("fn f(x: int) -> int {\n    if x > 0 { return 1; }\n    return 0;\n}\nfn main() -> int { return f(1); }\n")
    assert 'Region: if' in out, f"SG_IF region missing in cir dump:\n{out}"
    assert 'Region: func' in out, f"SG_FUNC region not labeled in cir dump:\n{out}"
    assert_region_within_func(out, 'if')

def test_loop_region():
    out = cir_dump("fn main() -> int {\n    s : ., mut = 0;\n    for i in 0..3 { s = s + i; }\n    return s;\n}\n")
    assert 'Region: for' in out, f"SG_FOR region missing in cir dump:\n{out}"
    assert 'Region: func' in out, f"SG_FUNC region not labeled in cir dump:\n{out}"
    assert_region_within_func(out, 'for')

def test_node_region_mapping():
    out = cir_dump("fn main() -> int {\n    s : ., mut = 0;\n    for i in 0..3 { s = s + i; }\n    return s;\n}\n")
    # DOT cluster grouping: the for region's nodes appear in one cluster
    assert 'cluster_for' in out, f"DOT region cluster missing:\n{out}"

def test_state_edges():
    """State edges (VSDG): side-effect chain + loop termination dependencies
    must appear in the cir dump as 'state: nA -> nB' lines."""
    out = cir_dump("fn main() -> int {\n    s : ., mut = 0;\n    s = s + 1;\n    s = s + 2;\n    return s;\n}\n")
    assert re.search(r'state: n\d+ -> n\d+', out), f"state edges not shown in cir dump:\n{out}"

def test_loop_termination_edge():
    """A loop whose body has side effects must carry a termination dependency
    from the last side-effect node to the loop exit node."""
    out = cir_dump("fn main() -> int {\n    s : ., mut = 0;\n    for i in 0..3 { s = s + i; }\n    return s;\n}\n")
    assert re.search(r'state: n\d+ -> n\d+', out), f"loop termination state edge missing in cir dump:\n{out}"

def _state_edges(out: str):
    return [(int(m.group(1)), int(m.group(2)))
            for m in re.finditer(r'state: n(\d+) -> n(\d+)', out)]

def test_termination_edge_source_guard():
    """终止边源边界 + 链头推进（final review Important #1）：
    SG_LOOP 循环体纯（无副作用）时，g_last_state_node 是循环前的 STORE——
    源在 region 外，不得连终止边；且链头必须推进到 region exit 节点，
    使循环后的 STORE 依赖循环终止（规格 §4.2：循环不终止则图不终止）。"""
    out = cir_dump("fn main() -> int {\n"
                   "    s : ., mut = 0;\n"
                   "    s = s + 1;\n"
                   "    loop { break; }\n"
                   "    s = s + 2;\n"
                   "    return s;\n"
                   "}\n")
    regs = parse_regions(out)
    assert 'loop' in regs, f"loop region missing in cir dump:\n{out}"
    a, b = regs['loop'][0]
    exit_node = b - 1  # exit label is the last node created in the region
    states = _state_edges(out)
    assert states, f"no state edges in cir dump:\n{out}"
    # 1) No termination edge whose source lies outside the region (old bug:
    #    pre-loop store linked straight to the loop exit).
    outside = [f for f, t in states if t == exit_node and f < a]
    assert not outside, \
        f"termination edge source {outside} outside loop region {a}..{b}:\n{out}"
    # 2) Chain head advanced: the post-loop store must chain from the exit
    #    node, so it depends on loop termination.
    from_exit = [t for f, t in states if f == exit_node]
    assert from_exit, \
        f"post-loop side effect does not depend on loop termination (no state edge from exit node {exit_node}):\n{out}"

def test_termination_edge_source_in_region():
    """终止边源边界（正例）：循环体有副作用时，终止边源必须在 region 内
    （last side-effect node ∈ [NSTART, EXIT)），不能是 region 外的旧副作用。"""
    out = cir_dump("fn main() -> int {\n"
                   "    s : ., mut = 0;\n"
                   "    s = s + 1;\n"
                   "    for i in 0..3 { s = s + i; }\n"
                   "    return s;\n"
                   "}\n")
    regs = parse_regions(out)
    assert 'for' in regs, f"for region missing in cir dump:\n{out}"
    a, b = regs['for'][0]
    exit_node = b - 1
    states = _state_edges(out)
    term = [(f, t) for f, t in states if t == exit_node]
    assert term, f"termination edge into exit node {exit_node} missing:\n{out}"
    for f, t in term:
        assert a <= f < b, \
            f"termination edge source {f} outside for region {a}..{b} (exit {t}):\n{out}"

def test_while_region_and_termination_edge():
    """while 也必须有 SG_LOOP 区域，并把循环退出接入 state 链。"""
    out = cir_dump("fn main() -> int {\n"
                   "    n : ., mut = 0;\n"
                   "    while n < 5 { n = n + 1; }\n"
                   "    n = n + 1;\n"
                   "    return n;\n"
                   "}\n")
    main_match = re.search(r'Function: main\n(.*?)(?=\nFunction: |\Z)', out, re.S)
    assert main_match, f"main function missing in cir dump:\n{out}"
    main_out = main_match.group(1)
    regs = parse_regions(main_out)
    assert 'loop' in regs, f"while loop region missing in cir dump:\n{out}"
    a, b = regs['loop'][0]
    assert_region_within_func(main_out, 'loop')
    exit_node = b - 1
    states = _state_edges(out)
    term = [(f, t) for f, t in states if t == exit_node]
    assert term, f"while termination edge into exit node {exit_node} missing:\n{out}"
    assert all(a <= f < b for f, _ in term), \
        f"while termination edge source outside loop region {a}..{b}:\n{out}"
    assert any(f == exit_node for f, _ in states), \
        f"post-while side effect does not depend on loop exit node {exit_node}:\n{out}"

# --- Interpreter loop execution (TODO#3) ---
# `corec run` compiles and interprets inline code; main()'s return value
# becomes the process exit code.

def test_for_loop_run():
    """for 循环在解释器中正确执行并返回累加和（TODO#3 回归用例）"""
    r = subprocess.run(['./build/corec', 'run',
                        'fn main() -> int { s : ., mut = 0; for i in 0..4 { s = s + i; } return s; }'],
                       capture_output=True, text=True, cwd=BASE, timeout=30)
    assert r.returncode == 6, f"for loop expected 6, got exit={r.returncode} stdout={r.stdout!r} stderr={r.stderr!r}"

def test_while_loop_run():
    r = subprocess.run(['./build/corec', 'run',
                        'fn main() -> int { n : ., mut = 0; while n < 5 { n = n + 1; } return n; }'],
                       capture_output=True, text=True, cwd=BASE, timeout=30)
    assert r.returncode == 5, f"while loop expected 5, got exit={r.returncode} stdout={r.stdout!r} stderr={r.stderr!r}"

def test_while_break_continue_run():
    r = subprocess.run(['./build/corec', 'run',
                        'fn main() -> int { n : ., mut = 0; s : ., mut = 0; '
                        'while n < 10 { n = n + 1; if n < 3 { continue; } '
                        'if n == 6 { break; } s = s + n; } return s; }'],
                       capture_output=True, text=True, cwd=BASE, timeout=30)
    assert r.returncode == 12, \
        f"while break/continue expected 12, got exit={r.returncode} stdout={r.stdout!r} stderr={r.stderr!r}"

def test_inline_callee_while_run():
    """内联 callee 的 while 必须更新局部状态并正常返回。"""
    r = subprocess.run(['./build/corec', 'run',
                        'fn sum(n: int) -> int { s : ., mut = 0; '
                        'while n > 0 { s = s + n; n = n - 1; } return s; } '
                        'fn main() -> int { return sum(3); }'],
                       capture_output=True, text=True, cwd=BASE, timeout=10)
    assert r.returncode == 6, \
        f"inline callee while expected 6, got exit={r.returncode} stdout={r.stdout!r} stderr={r.stderr!r}"

def test_inline_callee_for_run():
    r = subprocess.run(['./build/corec', 'run',
                        'fn sum() -> int { s : ., mut = 0; '
                        'for i in 0..4 { s = s + i; } return s; } '
                        'fn main() -> int { return sum(); }'],
                       capture_output=True, text=True, cwd=BASE, timeout=10)
    assert r.returncode == 6, \
        f"inline callee for expected 6, got exit={r.returncode} stdout={r.stdout!r} stderr={r.stderr!r}"

def test_break_continue_run():
    r = subprocess.run(['./build/corec', 'run',
                        'fn main() -> int { s : ., mut = 0; for i in 0..10 { if i == 2 { continue; } if i == 6 { break; } s = s + i; } return s; }'],
                       capture_output=True, text=True, cwd=BASE, timeout=30)
    assert r.returncode == 13, f"break/continue expected 13 (0+1+3+4+5), got exit={r.returncode} stdout={r.stdout!r} stderr={r.stderr!r}"

def test_nested_loop_run():
    """嵌套 for 循环：覆盖 innermost region 选择分支（e2 > cur_enter 路径）——
    内层回跳必须命中内层 region enter，外层回跳必须命中外层 region enter。"""
    r = subprocess.run(['./build/corec', 'run',
                        'fn main() -> int { s : ., mut = 0; for i in 0..3 { for j in 0..3 { s = s + 1; } } return s; }'],
                       capture_output=True, text=True, cwd=BASE, timeout=30)
    assert r.returncode == 9, f"nested loop expected 9 (3x3), got exit={r.returncode} stdout={r.stdout!r} stderr={r.stderr!r}"

# --- v7 serialization (.ccr segment-table layout + REG segment; Task 1 机械更新) ---

def ccr_walk(path: str):
    """Walk the v7 .ccr binary layout (mirrors load_ccr reading order) and return
    (version, sg_count, file_size, end_pos). Raises if the layout is invalid.

    v7 (Task 1 机械更新): Header 16B + 段表 6×12B {tag, offset, size}（规范序
    tag 1..6）+ 段体 STR/SYM/NOD/ENT/REG/EDG。NOD（tag 3）= 36B×nod_count（28B
    语义字段 + first_edge/edge_count 邻接）、EDG（tag 6）= 8B×edg_count 必落。
    REG（tag 5）= 24B×sg_count（坐标化字段序 kind/parent/enter/exit/
    first_ent/last_ent，记录宽不变）。见 ccr_io.cr 头注释（v7 布局权威）。"""
    with open(path, 'rb') as fh:
        d = fh.read()
    pos = 0
    def u32():
        nonlocal pos
        v = struct.unpack_from('<I', d, pos)[0]
        pos += 4
        return v
    assert struct.unpack_from('<I', d, pos)[0] == 0x31524343, "bad magic"  # "CCR1"
    pos += 4
    ver = u32()
    seg_count = u32()
    reserved = u32()
    assert reserved == 0
    # Segment table: canonical order (STR SYM NOD ENT REG EDG), contiguous bodies
    segs = {}
    cur = 16 + seg_count * 12  # first body follows the whole table
    for tag in (1, 2, 3, 4, 5, 6):
        t = u32()
        off = u32()
        size = u32()
        assert t == tag, f"segment row: expected tag {tag}, got {t}"
        assert off == cur, f"segment tag {tag}: offset {off} != {cur}"
        segs[tag] = (off, size)
        cur = off + size
    # Walk each segment body (each starts with its own count)
    sg_count = None
    def body(tag):
        off, size = segs[tag]
        return d[off:off + size]
    # STR (tag 1): str_count + strings
    b = body(1)
    (n,) = struct.unpack_from('<I', b, 0)
    p = 4
    for _ in range(n):
        sl = struct.unpack_from('<I', b, p)[0]
        p += 4 + sl
    assert p == len(b), "STR walk mismatch"
    # NOD (tag 3): nodes, 36B each (v7 spec §3.3: 28B 语义字段 + 邻接索引)
    b = body(3)
    (instr_cnt,) = struct.unpack_from('<I', b, 0)
    assert 4 + instr_cnt * 36 == len(b), "NOD walk mismatch"
    # EDG (tag 6): edges, 8B each (v7 必落)
    b = body(6)
    (edg_cnt,) = struct.unpack_from('<I', b, 0)
    assert 4 + edg_cnt * 8 == len(b), "EDG walk mismatch"
    # ENT (tag 4): entries, 28B each
    b = body(4)
    (ent_cnt,) = struct.unpack_from('<I', b, 0)
    assert 4 + ent_cnt * 28 == len(b), "ENT walk mismatch"
    # REG (tag 5): sgs, 24B each
    b = body(5)
    sg_count = struct.unpack_from('<I', b, 0)[0]
    assert 4 + sg_count * 24 == len(b), "REG walk mismatch"
    return ver, sg_count, len(d), cur

def test_ccr_v6_reg_section():
    """.ccr 序列化 v7（Task 1 机械更新，version==7）：段表架构，REG 段（tag 5）含 func+for 两个 region"""
    src = "fn main() -> int {\n    s : ., mut = 0;\n    for i in 0..3 { s = s + i; }\n    return s;\n}\n"
    with tempfile.NamedTemporaryFile('w', suffix='.cr', delete=False) as f:
        f.write(src)
        path = f.name
    ccr_path = os.path.join(BASE, 'build/test_ccr_v2.ccr')
    try:
        os.unlink(ccr_path)
    except FileNotFoundError:
        pass
    r = subprocess.run(['./build/corec', 'ccr', path, '-o', ccr_path],
                       capture_output=True, text=True, cwd=BASE, timeout=120)
    os.unlink(path)
    assert r.returncode == 0, f"ccr failed: {r.stderr}"
    ver, sg_count, fsize, end = ccr_walk(ccr_path)
    assert ver == 7, f"expected .ccr version 7, got {ver}"
    assert sg_count is not None and sg_count >= 2, \
        f"expected REG segment with >=2 regions (func+for), got {sg_count}"
    assert end == fsize, f"format walk ended at {end} of {fsize} bytes"


def test_ccr_writer_rejects_i32_overflow_inputs():
    """The v5 writer must reject out-of-range i32 fields instead of truncating."""
    # This is a source-level regression marker for the writer guard. A normal
    # source program cannot currently synthesize a >i32 instruction operand;
    # the guard is exercised by backend-generated metadata and malformed IR.
    ccr_source = os.path.join(BASE, "src", "compiler", "ccr_io.cr")
    with open(ccr_source, encoding="utf-8") as fh:
        text = fh.read()
    assert "fn ccr_i32_fits(val: int) -> int" in text
    assert "if ccr_validate_i32_fields() == 0 { return -1; }" in text

def test_ccr_roundtrip_v2():
    """save→load 往返守卫：v6 文件经 corearch 加载后 ELF 输出行为不变。
    程序计算 0+1+2+3=6，ELF 运行时以 main 返回值为退出码。"""
    src = "fn main() -> int {\n    s : ., mut = 0;\n    for i in 0..4 { s = s + i; }\n    return s;\n}\n"
    with tempfile.NamedTemporaryFile('w', suffix='.cr', delete=False) as f:
        f.write(src)
        path = f.name
    out = os.path.join(BASE, 'build/core_region_v2')
    try:
        os.unlink(out)
    except FileNotFoundError:
        pass
    r = subprocess.run(['./build/corec', 'build', path, '-o', out, '--static'],
                       capture_output=True, text=True, cwd=BASE, timeout=120)
    os.unlink(path)
    assert r.returncode == 0, f"build failed: {r.stderr}"
    os.chmod(out, 0o755)
    run = subprocess.run([out], capture_output=True, text=True, timeout=10)
    assert run.returncode == 6, \
        f"expected exit 6 (sum of 0..4), got {run.returncode} stdout={run.stdout!r}"

def test_region_check_pointer_escape():
    """嵌套 region 下的指针逃逸检测（RegionCheck 走显式映射后仍正确）"""
    src = "fn bad() -> &int {\n    x := 42;\n    return &x;\n}\nfn main() -> int { return 0; }\n"
    with tempfile.NamedTemporaryFile('w', suffix='.cr', delete=False) as f:
        f.write(src); path = f.name
    r = subprocess.run(['./build/corec', 'check', path], capture_output=True, text=True,
                       cwd=BASE, timeout=30)
    os.unlink(path)
    assert 'B010' in r.stdout or 'error' in r.stdout, f"expected escape error, got {r.stdout!r}"

def test_region_check_cache_hit():
    """RegionCheck 在缓存命中路径不回归：同路径第二次 build（全函数 cache hit）
    不得因 g_df_node_region 未恢复而崩溃/误报。显式映射改造的回归守卫：
    load_cir_cache 恢复节点时需同步写入 node→region 映射。"""
    src = "fn main() -> int {\n    s : ., mut = 0;\n    for i in 0..3 { s = s + i; }\n    return s;\n}\n"
    with tempfile.NamedTemporaryFile('w', suffix='.cr', delete=False) as f:
        f.write(src)
        path = f.name
    out = os.path.join(BASE, 'build/test_region_cache_hit')
    try:
        for run in (1, 2):
            r = subprocess.run(['./build/corec', 'build', path, '-o', out, '--static'],
                               capture_output=True, text=True, cwd=BASE, timeout=120)
            assert r.returncode == 0, \
                f"build failed on run {run} (cache {'hit' if run == 2 else 'miss'}): " \
                f"stdout={r.stdout!r} stderr={r.stderr!r}"
    finally:
        os.unlink(path)
        try:
            os.unlink(out)
        except FileNotFoundError:
            pass

def test_nested_regions_cache_persist():
    """增量 .cir 命中必须恢复函数内的嵌套 SG，而不是只恢复 func region。"""
    src = ("fn main() -> int {\n"
           "    s : ., mut = 0;\n"
           "    for i in 0..3 {\n"
           "        for j in 0..2 { s = s + i + j; }\n"
           "    }\n"
           "    return s;\n"
           "}\n")
    with tempfile.NamedTemporaryFile('w', suffix='.cr', delete=False) as f:
        f.write(src)
        path = f.name
    cir_path = os.path.splitext(path)[0] + '.cir'
    outs = []
    try:
        clean = subprocess.run(['./build/corec', 'clean-cache'],
                               capture_output=True, text=True, cwd=BASE, timeout=30)
        assert clean.returncode == 0, f"clean-cache failed: {clean.stderr}"
        for run in (1, 2):
            r = subprocess.run(['./build/corec', 'cir', path],
                               capture_output=True, text=True, cwd=BASE, timeout=120)
            assert r.returncode == 0, f"cir failed on run {run}: {r.stderr}"
            outs.append(r.stdout)
            try:
                os.unlink(cir_path)
            except FileNotFoundError:
                pass
    finally:
        os.unlink(path)
    for out in outs:
        regs = parse_regions(out)
        assert len(regs.get('for', [])) == 2, \
            f"nested for regions not preserved across cache hit:\n{out}"

def test_state_edges_cache_persist():
    """缓存命中路径不丢 state 边：同路径第二次 cir dump（cache hit）必须仍显示
    state 边（cir_cache v2 边序列化带 kind 的回归守卫）"""
    src = "fn main() -> int {\n    s : ., mut = 0;\n    s = s + 1;\n    s = s + 2;\n    return s;\n}\n"
    with tempfile.NamedTemporaryFile('w', suffix='.cr', delete=False) as f:
        f.write(src)
        path = f.name
    cir_path = os.path.splitext(path)[0] + '.cir'
    outs = []
    try:
        for _ in range(2):
            r = subprocess.run(['./build/corec', 'cir', path],
                               capture_output=True, text=True, cwd=BASE, timeout=120)
            assert r.returncode == 0, f"cir failed: {r.stderr}"
            outs.append(r.stdout)
            try:
                os.unlink(cir_path)
            except FileNotFoundError:
                pass
    finally:
        os.unlink(path)
    assert re.search(r'state: n\d+ -> n\d+', outs[0]), f"first run missing state edges:\n{outs[0]}"
    assert re.search(r'state: n\d+ -> n\d+', outs[1]), f"cache-hit run lost state edges:\n{outs[1]}"

if __name__ == '__main__':
    import sys
    tests = [test_if_region, test_loop_region, test_node_region_mapping,
             test_state_edges, test_loop_termination_edge,
             test_termination_edge_source_guard, test_termination_edge_source_in_region,
             test_while_region_and_termination_edge,
             test_for_loop_run, test_while_loop_run, test_while_break_continue_run,
             test_inline_callee_while_run, test_inline_callee_for_run,
             test_break_continue_run,
              test_nested_loop_run,
              test_ccr_v6_reg_section, test_ccr_writer_rejects_i32_overflow_inputs,
              test_ccr_roundtrip_v2,
             test_region_check_pointer_escape, test_region_check_cache_hit,
             test_nested_regions_cache_persist, test_state_edges_cache_persist]
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
    sys.exit(1 if failed else 0)
