#!/usr/bin/env python3
"""存在区间推导 + 条目版本化（v6 数据基础）——O1/O2 编译冒烟：区间表不破坏寄存器分配。

背景：compute_live_ranges 把 alloc_registers 的内联区间构建提取为独立表
（g_ir_live_ranges，每函数每 var 两条 i64：first_ref/last_ref，指令序），
alloc_registers 改读 live_first/live_last——行为必须与内联扫描一致。

Task 2 追加：compute_entries 按定值点切分版本条目（变量 × 版本，24B/条）。
定值指令 = IR_ALLOC（局部槽初定值）与该变量为目标的每次 IR_STORE
（IR_STORE 形态 ρ(s1):=ρ(s2)——目标在 s1 不在 dest，见 ir-op-semantics.md）。
调试通道（2026-09-07 regalloc 移后端随迁）：`corearch FILE.ccr --dump-entries`
（corec cir 原通道——corearch load .ccr 后内存态自算 compute_live_ranges（尾部
compute_entries）再出摘要；NOD 载入流与 corec cir 原 dump 流同构——ccr_v6
conversion 对照测试曾逐条实证 dump ↔ 落盘 ENT 等价，现数据面归 corearch）。

覆盖路径：
- 默认 O1 build：pass_cse 路径（O2 分配在 corearch 侧不运行，仍须正确）
- --opt-level 2 build：corearch 自算 alloc（读新表）+ verify 路径
- corearch --dump-entries：版本条目断言（多定值变量版本切割 / 参数无定值单条目）

fib(10)==55 为行为锚点（递归 + 分支密集，区间表错误会破坏寄存器指派）。

条目版本化断言注记：brief/计划示例 `x:=1;x=x+1;x=x+2` 预期 x 3 条目
（按「let 初始化只发射 IR_ALLOC」的 IR 模型估算）。实际 IR 中 `x := 1` 发射
IR_ALLOC(x) + IR_STORE(x←1) 两条定值（ir_gen.cr EXPR_LET 路径），故 x 定值点 =
ALLOC + 3×STORE = 4 个版本条目。规则照计划原文逐字实现（每次 IR_STORE/IR_ALLOC
定值切分一个版本），测试按实际 IR 断言 4 条目 + 版本区间结构不变量。
"""

import os
import re
import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"
COREARCH = BASE / "build" / "corearch"


def corearch_chan(source: str, *flags) -> tuple:
    """数据面/判定调试通道（随迁 corearch）：corec ccr 产 .ccr（-O0 无 opt
    pass 干扰——NOD = pre-CSE 流）→ corearch load 后自算执行 flag。返回
    (rc, stdout+stderr)。"""
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as f:
        f.write(source)
        path = f.name
    ccr = path[:-3] + ".ccr"
    try:
        b = subprocess.run([str(COREC), "ccr", path, "--opt-level", "0", "-o", ccr],
                           capture_output=True, text=True, cwd=BASE, timeout=120)
        if b.returncode != 0:
            return 999, f"corec ccr failed:\n{b.stdout[-500:]}\n{b.stderr[-500:]}"
        r = subprocess.run([str(COREARCH), ccr] + list(flags),
                           capture_output=True, text=True, cwd=BASE, timeout=120)
        return r.returncode, r.stdout + r.stderr
    finally:
        for p in (path, ccr):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


def build_and_run(source: str, extra_flags) -> int:
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as f:
        f.write(source)
        src = f.name
    out = src[:-3]
    try:
        b = subprocess.run([str(COREC), "build", src, "-o", out, "--static"] + extra_flags,
                           capture_output=True, text=True, cwd=BASE, timeout=120)
        if b.returncode != 0:
            print(f"  build stderr: {b.stderr.strip()[-500:]}")
            return 999
        r = subprocess.run([out], capture_output=True, text=True, timeout=10)
        return r.returncode
    finally:
        for p in (src, out, out + ".ccr"):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


def dump_entries(source: str) -> tuple:
    """corearch --dump-entries 通道：返回 (rc, stdout)。"""
    return corearch_chan(source, "--dump-entries")


ENTRY_LINE = re.compile(
    r"^e (\d+) var (\d+) name=(\S+) v (\d+) def (-?\d+) kind=(\S+) "
    r"live (\d+)\.\.(\d+) home (-?\d+) flags (\d+)$")
HEADER_LINE = re.compile(r"^== entries func (\d+) \((.*)\): (\d+)$")


def parse_entry_blocks(out: str) -> dict:
    blocks = {}
    cur = None
    for raw in out.splitlines():
        ln = raw.strip()
        m = HEADER_LINE.match(ln)
        if m:
            blocks[m.group(2)] = []
            cur = blocks[m.group(2)]
            continue
        m = ENTRY_LINE.match(ln)
        if m and cur is not None:
            cur.append({
                "e": int(m.group(1)), "var": int(m.group(2)), "name": m.group(3),
                "v": int(m.group(4)), "def": int(m.group(5)), "kind": m.group(6),
                "ls": int(m.group(7)), "le": int(m.group(8)),
                "home": int(m.group(9)), "flags": int(m.group(10)),
            })
    return blocks


def check_versioned_entries() -> tuple:
    """Task 2：多定值变量版本切割断言（GC 批 2 扩权后同步：定值 = dest≥0 全定值）。

    x := 1 在 IR 中 = IR_ALLOC + IR_STORE（let 初始化发射两条定值），
    再加 x=x+1 / x=x+2 两条 STORE → x 应有 4 个版本条目（1×ALLOC + 3×STORE），
    版本区间按 [def_j, min(def_{j+1}-1, last_ref)] 切割（全局指令序闭区间）：
    e_j.live_end == def_{j+1} - 1（j < 末版），末版 live_end = var 的 last_ref ≥ 其 def。

    GC 批 2（定值识别扩权，格式定稿 §4.1 dest≥0 = 定值点）：producer 临时值
    （CONST/BINARY/ARENA_NEW 等）也按定值切版本——按 name 分组断言（跨组断言
    会因临时值条目数变化而脆弱）；每个 def'd 条目 ls == def 与同组版本链
    不变量仍全表成立。
    """
    src = "fn identity(n:int)->int{return n;}\n" \
          "fn main()->int{x:=1;x=x+1;x=x+2;return x;}\n"
    rc, out = dump_entries(src)
    if rc != 0:
        return False, f"cir --dump-entries rc={rc}\n{out[-500:]}"
    blocks = parse_entry_blocks(out)
    if "main" not in blocks:
        return False, f"no 'main' entry block in dump:\n{out[-500:]}"
    ent = blocks["main"]

    # x 的 4 版本：ALLOC + 3×STORE（GC 批 2 语义下 x 只被 ALLOC/STORE 定值）
    multi = [e for e in ent if e["name"] == "x"]
    if len(multi) != 4:
        return False, f"main/x: expected 4 version entries (ALLOC+3 STORE), got {len(multi)}:\n{out}"
    if [x["kind"] for x in multi] != ["ALLOC", "STORE", "STORE", "STORE"]:
        return False, f"main/x: def kinds != ALLOC,STORE,STORE,STORE:\n{multi}"
    if [x["v"] for x in multi] != [1, 2, 3, 4]:
        return False, f"main/x: version ordinals != 1..4:\n{multi}"
    defs = [x["def"] for x in multi]
    if any(defs[i] >= defs[i + 1] for i in range(3)):
        return False, f"main/x: def points not strictly increasing:\n{defs}"
    for x in multi:
        if x["ls"] != x["def"]:
            return False, f"main/x: version live_start != def ({x}):\n{multi}"
    for i in range(3):
        if multi[i]["le"] != defs[i + 1] - 1:
            return False, f"main/x: version {i+1} live_end != def[{i+1}]-1:\n{multi}"
    if multi[3]["le"] < multi[3]["def"]:
        return False, f"main/x: last version live_end < its def:\n{multi}"

    # GC 批 2 扩权实证：main 里 producer 临时值（CONST/BINARY/ARENA_NEW）也有
    # def'd 版本条目（旧实现止于 ALLOC/STORE——def'd 条目仅 x 一组 4 条）。
    kinds = [e["kind"] for e in ent if e["def"] >= 0]
    for want in ("ALLOC", "CONST", "BINARY", "ARENA_NEW"):
        if want not in kinds:
            return False, f"main: expected a def'd entry kind={want} (dest>=0 producers " \
                          f"versioned), got kinds {sorted(set(kinds))}:\n{out}"
    # 排除集实证：STORE_INDEX_VAR/STORE_PTR/DYN_DISPATCH 的 dest 非定值——不产生条目
    if any(e["kind"] in ("STORE_INDEX_VAR", "STORE_PTR", "DYN_DISPATCH") for e in ent):
        return False, f"main: excluded non-def dest op created an entry:\n{out}"
    # 全表不变量：def'd 条目 ls == def；同 name 组内版本序 1..k（dump v 序）
    for e in ent:
        if e["def"] >= 0 and e["ls"] != e["def"]:
            return False, f"main: def'd entry live_start != def ({e}):\n{ent}"
        if e["def"] < 0 and e["kind"] != "-":
            return False, f"main: no-def entry has a def kind ({e}):\n{ent}"
    if any(e["home"] != -1 or e["flags"] != 0 for e in ent):
        return False, f"main: entries must have home=-1 flags=0 (unassigned):\n{ent}"

    # 无定值但有引用（函数参数）：单条目 def=-1，区间 [first_ref,last_ref]
    if "identity" not in blocks or not blocks["identity"]:
        return False, f"identity: expected an entry block:\n{out}"
    id_ent = blocks["identity"]
    # 参数 n 单条目 def=-1（GC 批 2 后 identity 的 _arena 等 producer 有 def'd 条目）
    n_ent = [e for e in id_ent if e["name"] == "n"]
    if len(n_ent) != 1 or n_ent[0]["def"] != -1 or n_ent[0]["kind"] != "-":
        return False, f"identity/n: param must be a single def=-1 entry:\n{id_ent}"
    if n_ent[0]["ls"] < 0 or n_ent[0]["ls"] > n_ent[0]["le"]:
        return False, f"identity/n: bad no-def live range:\n{n_ent[0]}"
    return True, "entries versioning OK"


def check_array_birth_versions() -> tuple:
    """GC 批 2（Task 2 评审 Important #2）：内存对象诞生 = 定值点。

    `a : [int; 3]` 无初值声明不发 IR_ALLOC——旧实现只认 ALLOC/STORE 定值 →
    a 首个版本化定值 = 后续 STORE 重定值，诞生与重定值之间的读窗口无条目覆盖。
    dest≥0 全定值扩权后：a 的版本 = [ALLOC_ARRAY(诞生), STORE(重定值)] 两条，
    区间按 [def_j, def_{j+1}-1] 切割——诞生版覆盖元素写/拷贝读（a[0]=5、
    b := a），STORE 版覆盖重定值后读（a[0]+a[1]+a[i]）。"""
    src = "fn main()->int{\n" \
          "  a : [int; 3];\n" \
          "  a[0] = 5; a[1] = 7;\n" \
          "  b := a;\n" \
          "  a = [1, 2, 3];\n" \
          "  i := 0;\n" \
          "  a[i] = 9;\n" \
          "  return a[0] + a[1] + b[0] + a[i];\n" \
          "}\n"
    rc, out = dump_entries(src)
    if rc != 0:
        return False, f"cir --dump-entries rc={rc}\n{out[-500:]}"
    blocks = parse_entry_blocks(out)
    if "main" not in blocks:
        return False, f"no 'main' entry block in dump:\n{out[-500:]}"
    ent = blocks["main"]

    a_ent = [e for e in ent if e["name"] == "a"]
    if len(a_ent) != 2:
        return False, f"main/a: expected 2 versions (ALLOC_ARRAY birth + STORE), got {len(a_ent)}:\n{out}"
    if [e["kind"] for e in a_ent] != ["ALLOC_ARRAY", "STORE"]:
        return False, f"main/a: kinds != ALLOC_ARRAY,STORE:\n{a_ent}"
    if [e["v"] for e in a_ent] != [1, 2]:
        return False, f"main/a: version ordinals != 1,2:\n{a_ent}"
    d0, d1 = a_ent[0]["def"], a_ent[1]["def"]
    if d0 >= d1:
        return False, f"main/a: def points not increasing:\n{a_ent}"
    if a_ent[0]["ls"] != d0 or a_ent[1]["ls"] != d1:
        return False, f"main/a: version live_start != def:\n{a_ent}"
    # 诞生版区间止于重定值前（元素写/读在定值点之后——ALLOC_ARRAY 版覆盖它们）
    if a_ent[0]["le"] != d1 - 1:
        return False, f"main/a: birth version live_end != def2-1:\n{a_ent}"
    if a_ent[1]["le"] < d1:
        return False, f"main/a: STORE version live_end < its def:\n{a_ent}"
    # b := a（读 a）的指令在 a 诞生版区间内——元素写读窗口被条目覆盖的实证：
    # a_ent[0] 区间 [d0, d1-1] 必须非空（有读才叫「窗口无覆盖」场景成立）
    if a_ent[0]["le"] <= a_ent[0]["ls"]:
        return False, f"main/a: birth version window empty (no reads between birth " \
                      f"and redef?):\n{a_ent}"
    # b 的版本 = [ALLOC, STORE]（拷贝声明）；i 同构
    for nm, expect in (("b", ["ALLOC", "STORE"]), ("i", ["ALLOC", "STORE"])):
        g = [e["kind"] for e in ent if e["name"] == nm]
        if g != expect:
            return False, f"main/{nm}: kinds != {expect}:\n{ent}"
    # 排除集实证（动态索引写 a[i]=9：被存值 var 的 dest 直写不产生条目——
    # 该值 var 组内版本数 = producer 数 1，无 STORE_INDEX_VAR 伪造 def）
    for e in ent:
        if e["def"] >= 0 and e["kind"] in ("STORE_INDEX_VAR", "STORE_PTR", "DYN_DISPATCH"):
            return False, f"main: excluded non-def dest op created an entry ({e}):\n{ent}"
    return True, "memory-object birth versioning OK"


def run_smoke() -> tuple:
    """Task 1 存量冒烟：fib(10)==55 at O1-default / O2。"""
    src = "fn fib(n:int)->int{if n<2{return n;}return fib(n-1)+fib(n-2);}\n" \
          "fn main()->int{return fib(10);}\n"
    passed = 0
    total = 2
    detail = []
    for name, flags in (("O1-default", []), ("O2", ["--opt-level", "2"])):
        rc = build_and_run(src, flags)
        ok = rc == 55
        print(f"[{'PASS' if ok else 'FAIL'}] {name} live-range smoke: rc={rc}")
        if ok:
            passed += 1
        else:
            detail.append(f"{name} rc={rc}")
    return passed == total, "; ".join(detail) if detail else ""


def dump_coexist(source: str) -> tuple:
    """corearch --dump-coexist 通道：返回 (rc, stdout)。"""
    return corearch_chan(source, "--dump-coexist")


COEXIST_LINE = re.compile(
    r"^== coexist func (\d+) \((\S+)\): ver_conf (\d+) home_conf (\d+)$",
    re.MULTILINE)


def check_coexistence() -> tuple:
    """Task 3：共存推导断言。

    (a) 版本冲突扫描 = 0（版本按定值点切割，同 var 跨版本必不交——数据自检）；
    (b) home 冲突 = 0（未分配态 home=-1 不参与，共存互斥判定输入雏形）；
    (c) 概念断言（Python 侧用 --dump-entries 区间数据）：a/b 两变量条目
        存在区间相交（共存），同一变量两版本区间不相交（不共存）。
    """
    src = "fn main()->int{a:=1;b:=2;return a+b;}\n"
    rc, out = dump_coexist(src)
    if rc != 0:
        return False, f"cir --dump-coexist rc={rc}\n{out[-500:]}"
    m = COEXIST_LINE.search(out)
    if not m:
        return False, f"no coexist line in dump:\n{out[-500:]}"
    vc, hc = int(m.group(3)), int(m.group(4))
    if vc != 0 or hc != 0:
        return False, f"coexist: ver_conf={vc} home_conf={hc}, expected 0/0:\n{out}"

    # (c) 区间相交概念断言（Python 侧）
    rc2, out2 = dump_entries(src)
    if rc2 != 0:
        return False, f"dump-entries rc={rc2}"
    blocks = parse_entry_blocks(out2)
    if "main" not in blocks:
        return False, "no main block"
    ent = blocks["main"]
    av = [x for x in ent if x["name"] == "a"]
    bv = [x for x in ent if x["name"] == "b"]
    if not av or not bv:
        return False, f"a/b entries missing:\n{out2}"
    # 取末版本（return 处活跃的是最后定值版——ALLOC 空版区间短暂不相交属正常；
    # a/b 在此程序各有 ALLOC+STORE 两版本）
    if len(av) < 2 or len(bv) < 2:
        return False, f"a/b should each have >=2 versions (ALLOC+STORE):\n{out2}"
    a0, b0 = av[-1], bv[-1]
    coexist = a0["ls"] <= b0["le"] and b0["ls"] <= a0["le"]
    if not coexist:
        return False, f"a/b should coexist, ranges {a0['ls']}..{a0['le']} vs {b0['ls']}..{b0['le']}"
    # a 两版本（ALLOC 空版 vs STORE 值版）区间不相交——同变量版本不共存
    if av[0]["ls"] <= av[1]["le"] and av[1]["ls"] <= av[0]["le"]:
        return False, f"a versions should not coexist: {av[0]['ls']}..{av[0]['le']} vs {av[1]['ls']}..{av[1]['le']}"
    return True, "coexistence OK"


def check_regalloc(source: str, extra_flags) -> tuple:
    """corearch --check-regalloc 通道：O2 强制分配 + 判定自检，返回 (rc, stdout)。"""
    return corearch_chan(source, "--check-regalloc", *extra_flags)


# 措辞注记（Task 4 输出面中性化——测试 = 行为锚, 措辞 = 输出面）：内核违反
# 诊断前缀 "regalloc-consistency" → "entry-consistency"（条目版本表一致性——
# 中性语义名；内核措辞批，判定语义/规则号/数值结构不变）；SUMMARY_LINE/
# ASSIGN_LINE 前缀 = 实例侧（corearch.cr 通道名 --check-regalloc 命名空间）
# 输出——措辞批范围外，断言保持。
SUMMARY_LINE = re.compile(r"^regalloc-consistency: funcs (\d+) violations (\d+)$", re.MULTILINE)
VIOLATION_LINE = re.compile(r"^entry-consistency: func \d+ \(.+\): rule (\d+) violation", re.MULTILINE)
ASSIGN_LINE = re.compile(r"^regalloc-assign: (\d+) pairs$", re.MULTILINE)


def check_regalloc_consistency() -> tuple:
    """Task 5 绿路径 + CAG 真实化回归：O2 分配的**正确程序**自检静默通过
    （rc=0、无 violation 行）。

    CAG 前（2026-09-06 注记，opt.cr alloc 区头）：分配结果恒为空（rc=0 缺陷
    ——free 遍时机 + 循环末只收仍活跃 var → g_opt_meta 无 REG_ASSIGN 对），规则
    ①/② 在真实数据上平凡通过（无寄存器驻留条目）。CAG 挂账清项后分配真实化：
    本绿路径消费真实分配结果——寄存器组规则 ①/② 在真数据上必须仍绿（判定
    消费端首次吃到真数据；误报即红）。规则 ①/② 的实际触发证据 = 注入红路径
    （check_regalloc_violations / check_regalloc_read_gap_nonfunc0，注入现以
    改写真实分配输出为手段）；fib/6 变量绿程序按行为锚点保留。"""
    for name, src in (
        ("fib", "fn fib(n:int)->int{if n<2{return n;}return fib(n-1)+fib(n-2);}\n"
                "fn main()->int{return fib(10);}\n"),
        ("multi-var", "fn main()->int{a:=1;b:=2;c:=3;d:=4;e:=5;f:=6;"
                      "return a+b+c+d+e+f;}\n"),
    ):
        rc, out = check_regalloc(src, [])
        if rc != 0:
            return False, f"check-regalloc({name}) rc={rc}:\n{out[-500:]}"
        m = SUMMARY_LINE.search(out)
        if not m:
            return False, f"check-regalloc({name}): no summary line:\n{out[-500:]}"
        if int(m.group(2)) != 0:
            return False, f"check-regalloc({name}): violations != 0:\n{out[-500:]}"
        if VIOLATION_LINE.search(out):
            return False, f"check-regalloc({name}): violation lines on correct program:\n{out[-500:]}"
    return True, "regalloc consistency self-check OK"


def check_regalloc_real_use() -> tuple:
    """CAG 挂账清项（opt.cr alloc_registers rc=0 缺陷）：寄存器真实分配实证。

    --check-regalloc 在 O2 强制分配后打印看门狗行 regalloc-assign（g_opt_meta
    REG_ASSIGN 对总数）。修复前 rc 恒为 0（free 遍 `last_ref < ii` 复位 + reg_idx
    单调不复用 + 循环末只收集仍活跃 var → meta 恒空 → 后端全栈发射——正确但无
    寄存器加速）→ 本断言红；真实分配后 pairs > 0 → 绿。

    计数载体注记（评审 I-2 措辞修正）：看门狗数的是**整语料** REG_ASSIGN 对
    （被测 main + 15 个自动并入的标准库函数，funcs 16）——断言对象是总数 ≥ 5
    （证明分配真实发生、防 rc=0 回退），不断言被测 main 的 6 变量各获分配。
    6 共存 int var 的作用是把共存压力拉到 5 callee-saved 上限，使分配必然发生
    且必有栈驻留余数（不分配 = 保留栈 home；分配器无驱逐事件，不设驱逐路径）。
    """
    src = "fn main()->int{a:=1;b:=2;c:=3;d:=4;e:=5;f:=6;return a+b+c+d+e+f;}\n"
    rc, out = check_regalloc(src, [])
    if rc != 0:
        return False, f"check-regalloc rc={rc}:\n{out[-500:]}"
    m = ASSIGN_LINE.search(out)
    if not m:
        return False, (f"regalloc-assign watchdog line missing in check-regalloc "
                       f"output:\n{out[-500:]}")
    n = int(m.group(1))
    if n <= 0:
        return False, (f"regalloc-assign: {n} pairs — 寄存器从未真实分配（rc=0 "
                       f"缺陷回退）：\n{out[-500:]}")
    if n < 5:
        return False, (f"regalloc-assign: {n} pairs < 5 — 全语料（main + stdlib）"
                       f"共存压力下应远超 5 对：\n{out[-500:]}")
    return True, f"regalloc real assignment OK ({n} pairs)"


LOOP_CARRY_SRC = (
    "fn main()->int{\n"
    "  i:=0;s:=0;\n"
    "  loop {\n"
    "    if i>=4 { break; }\n"
    "    i = i + 1;\n"
    "    d := 5;\n"
    "    s = s + d;\n"
    "  }\n"
    "  return s;\n"
    "}\n"
)


def check_regalloc_loop_carry() -> tuple:
    """CAG 上下文贪心——循环携带值语义锚（region 生命周期上下文）。

    i 的读点（cond）在文字序上先于其重定值（i=i+1）→ 每轮迭代末写入的值跨回边
    存活（cond 读的是上一轮 i 的值）。朴素 [first_ref, last_ref] 文字窗口序
    First Fit 会把 i 的寄存器（窗口止于其末引用 = 重定值点）与循环尾文字区间不
    交的 var（d := 5 的 ALLOC/STORE 在 i 末引用之后）共享 → d 的定值在回边前
    污染 i 的寄存器 → 下轮 cond 读到 5 → 提前 break（s=5）。上下文贪心把携带
    值（region 内首引用为读）窗口扩至整函数 → 不共享 → s = 4×5 = 20。

    断言 O2（真实分配）行为 == 20；O1（无分配路径基线）同断言。
    """
    for name, flags in (("O1-baseline", []), ("O2-regalloc", ["--opt-level", "2"])):
        rc = build_and_run(LOOP_CARRY_SRC, flags)
        ok = rc == 20
        print(f"[{'PASS' if ok else 'FAIL'}] loop-carry {name}: rc={rc}")
        if not ok:
            return False, f"loop-carry {name} rc={rc}, expected 20"
    return True, "loop-carried register semantics OK"


def check_regalloc_cond_def_carry() -> tuple:
    """CAG 复审 Critical 回归（条件定值跨回边存活）：条件定值 = span 内首引用
    是定值指令（def-form）但未必每轮执行——跳过路径上旧值仍跨回边存活。

    复现 A（v_noz）：x 的定值 `if i==0 { x = 7; }` 是回边 span 内 x 的首引用
    （def-form），但 i==1 轮该 STORE 不执行 → s=s+x 读到的是上一轮的值——
    x 实际携带。旧判定（只认「span 内首引用为读」为携带）把 x 判不携带 →
    阶段 4 按文字窗口终点归还 x 的寄存器，循环尾 `i=i+1` 的文字区间不交的临时
    var 拿到同一寄存器 → 每轮回边前污染 → 下轮读 x 读到 i+1 临时值（8=7+1）。
    复现 B（conddef_repro3）：同形 + 尾 `z:=5; s=s+z;`（期望 24，错读 22）。

    pre-CAG O2（rc=0 全栈发射）正确（14/24）→ 误编译由 CAG 寄存器真实分配引入。
    断言 O2（真实分配）== 期望；O1（无分配路径基线）同断言。
    """
    for name, src, expect in (
        ("v_noz", "fn main()->int{\n"
                  "  i:=0;s:=0;\n"
                  "  x : int, mut = 3;\n"
                  "  loop {\n"
                  "    if i>=2 { break; }\n"
                  "    if i==0 { x = 7; }\n"
                  "    s = s + x;\n"
                  "    i = i + 1;\n"
                  "  }\n"
                  "  return s;\n"
                  "}\n", 14),
        ("conddef-z", "fn main()->int{\n"
                      "  i:=0;s:=0;\n"
                      "  x : int, mut = 3;\n"
                      "  loop {\n"
                      "    if i>=2 { break; }\n"
                      "    if i==0 { x = 7; }\n"
                      "    s = s + x;\n"
                      "    i = i + 1;\n"
                      "    z := 5;\n"
                      "    s = s + z;\n"
                      "  }\n"
                      "  return s;\n"
                      "}\n", 24),
    ):
        for mode, flags in (("O1-baseline", []), ("O2-regalloc", ["--opt-level", "2"])):
            rc = build_and_run(src, flags)
            ok = rc == expect
            print(f"[{'PASS' if ok else 'FAIL'}] cond-def-carry {name} {mode}: rc={rc}")
            if not ok:
                return False, f"cond-def-carry {name} {mode} rc={rc}, expected {expect}"
    return True, "conditional-def loop-carried register semantics OK"


def check_regalloc_else_def_carry() -> tuple:
    """CAG 复审第二轮回归（else 臂条件定值 = BRANCH-skip 差分残留）。

    同族机制残留于 else 臂：if-else 发射布局
      BRANCH c, L_then, L_else; L_then: A; JUMP L_merge; L_else: B; JUMP L_merge;
    中 else 体 B（`x = 7`）被 then 尾的无条件 JUMP 结构性跳过——阶段 2 差分标记
    只扫 IR_BRANCH 的 forward 目标（B 正落在 BRANCH 自身 else 目标的标号处、
    区间 [pp+1, t−1] 不含终点 t），漏 IR_JUMP → B 内定值 x 判「每轮必执行、
    不携带」→ 阶段 4 文字窗口终点归还 x 寄存器 → 循环尾临时同寄存器 → 回边前
    污染 → 下轮读 x 错值（p_else1/p_while 应 22 实得 20；pre-CAG O2 正确）。

    修复 = 对 span 内 forward IR_JUMP (u, t)（t ∈ (u, b0]）同样生成 [u+1, t−1]
    差分。over-mark 只损利用率、方向安全（continue/else 臂/链式 JUMP 推演无害）。

    复现 A（p_else1）：loop + break 头 + `if i<2 {s=s+1} else {x=7}`（应 22）。
    复现 B（p_while）：while 头条件同形 if-else（应 22）。
    断言 O2（真实分配）== 期望；O1（无分配路径基线）同断言。
    """
    for name, src, expect in (
        ("else1", "fn main()->int{\n"
                  "  i:=0;s:=0;\n"
                  "  x : int, mut = 3;\n"
                  "  loop {\n"
                  "    if i>=4 { break; }\n"
                  "    if i<2 { s = s + 1; } else { x = 7; }\n"
                  "    s = s + x;\n"
                  "    i = i + 1;\n"
                  "  }\n"
                  "  return s;\n"
                  "}\n", 22),
        ("else-while", "fn main()->int{\n"
                       "  i:=0;s:=0;\n"
                       "  x : int, mut = 3;\n"
                       "  while i < 4 {\n"
                       "    if i<2 { s = s + 1; } else { x = 7; }\n"
                       "    s = s + x;\n"
                       "    i = i + 1;\n"
                       "  }\n"
                       "  return s;\n"
                       "}\n", 22),
    ):
        for mode, flags in (("O1-baseline", []), ("O2-regalloc", ["--opt-level", "2"])):
            rc = build_and_run(src, flags)
            ok = rc == expect
            print(f"[{'PASS' if ok else 'FAIL'}] else-def-carry {name} {mode}: rc={rc}")
            if not ok:
                return False, f"else-def-carry {name} {mode} rc={rc}, expected {expect}"
    return True, "else-arm conditional-def loop-carried register semantics OK"


def check_regalloc_else_controls() -> tuple:
    """else 臂修复的控制组（无过标/无回归）：同族形状的既有绿行为必须保持。

    - then2（p_then2）：`if i<2 {x=7} else {s=s+1}`——定值在 then 臂（BRANCH
      else 目标区间已覆盖，第一轮修复路径）→ 30 保持（新增 JUMP 差分不得扰动）。
    - cont（p_cont）：continue 臂 + then 臂定值 + else 读先行自刷新 s → 31 保持
      （continue 回跳目标 ≤ 跳源，JUMP 差分不计回跳——误标会扩窗损利用率，
      行为断言兜底正确性）。
    断言 O2（真实分配）== 期望。
    """
    for name, src, expect in (
        ("then2", "fn main()->int{\n"
                  "  i:=0;s:=0;\n"
                  "  x : int, mut = 3;\n"
                  "  loop {\n"
                  "    if i>=4 { break; }\n"
                  "    if i<2 { x = 7; } else { s = s + 1; }\n"
                  "    s = s + x;\n"
                  "    i = i + 1;\n"
                  "  }\n"
                  "  return s;\n"
                  "}\n", 30),
        ("cont", "fn main()->int{\n"
                 "  i:=0;s:=0;\n"
                 "  x : int, mut = 3;\n"
                 "  loop {\n"
                 "    if i>=5 { break; }\n"
                 "    if i==0 { i = i + 1; continue; }\n"
                 "    if i<2 { x = 7; } else { s = s + 1; }\n"
                 "    s = s + x;\n"
                 "    i = i + 1;\n"
                 "  }\n"
                 "  return s;\n"
                 "}\n", 31),
    ):
        rc = build_and_run(src, ["--opt-level", "2"])
        ok = rc == expect
        print(f"[{'PASS' if ok else 'FAIL'}] else-control {name} O2: rc={rc}")
        if not ok:
            return False, f"else-control {name} O2 rc={rc}, expected {expect}"
    return True, "else-arm control shapes unchanged (then2=30, cont=31)"


def check_regalloc_violations() -> tuple:
    """Task 5 红路径：注入冲突条目 → verify 返回违反（rc=1 + rule N 诊断行）。
    注入经测试钩子（cir 隐藏 debug 标志——真实构建路径永不注入）：
    - --inject-home-conflict: 两条共存不同 var 条目 home 置同槽 → 规则 1（home 组）
    - --inject-reg-conflict : 未分配 var f 伪造 meta 对 (f, e 的寄存器) → 规则 1（寄存器组）
    - --inject-read-gap     : 寄存器驻留 var 末版区间截断到定值点 → 规则 2（读点无版本）
    O2 正确程序（无注入）rc=0 已在 check_regalloc_consistency 断言——同一二进制
    注入后 rc=1 即证明 verify 真消费了分配/条目数据而非恒真。"""
    src = "fn main()->int{a:=1;b:=2;c:=3;d:=4;e:=5;f:=6;return a+b+c+d+e+f;}\n"
    for flag, rule in (("--inject-home-conflict", "1"),
                       ("--inject-reg-conflict", "1"),
                       ("--inject-read-gap", "2")):
        rc, out = check_regalloc(src, [flag])
        if rc != 1:
            return False, f"check-regalloc +{flag}: rc={rc}, expected 1:\n{out[-500:]}"
        m = SUMMARY_LINE.search(out)
        if not m or int(m.group(2)) == 0:
            return False, f"check-regalloc +{flag}: summary missing or 0 violations:\n{out[-500:]}"
        v = VIOLATION_LINE.search(out)
        if not v or v.group(1) != rule:
            return False, f"check-regalloc +{flag}: no rule {rule} violation line:\n{out[-500:]}"
    return True, "regalloc violations detected (rules 1/1/2)"


def check_regalloc_read_gap_nonfunc0() -> tuple:
    """F1 回归（评审发现）：规则 ② 注入目标 = 非 func 0 函数。

    rl_rule2_func 曾以局部扫描下标 ii 对照条目表全局坐标（ent_def/ent_live_end
    存 ist+局部），非 func 0 函数（ist > 0）上规则 ② 失明（只漏报不误报）——
    func 0 上 ii == inst 掩盖缺陷。本用例要求 --inject-read-gap 注入到非 func 0
    函数：旧实现漏报 rc=0（红），修复（三处比较改用 inst := ist + ii）后
    rc=1 + 非 func 0 规则 ② 诊断行（绿）。

    GC 批 2 注记：定值扩权后每函数的 _arena 等首条 def 使 func 0 恒可注入——
    inject_read_gap 的迭代序改为 1..n-1 再 0（调试钩子，真实路径永不注入），
    注入恒落非 func 0 函数；注入目标函数不再固定为 sum6（按函数序首个可注入
    者定，此处为 ist>0 的 stdlib/用户函数）——断言 = func > 0 + rule 2。"""
    src = "fn main()->int{return n0(1,2);}\n" \
          "fn n0(a:int,b:int)->int{return a+b;}\n" \
          "fn n1(a:int,b:int)->int{return a+b;}\n" \
          "fn n2(a:int,b:int)->int{return a+b;}\n" \
          "fn n3(a:int,b:int)->int{return a+b;}\n" \
          "fn n4(a:int,b:int)->int{return a+b;}\n" \
          "fn n5(a:int,b:int)->int{return a+b;}\n" \
          "fn n6(a:int,b:int)->int{return a+b;}\n" \
          "fn n7(a:int,b:int)->int{return a+b;}\n" \
          "fn sum6()->int{a:=1;b:=2;c:=3;d:=4;e:=5;f:=6;return a+b+c+d+e+f;}\n"
    rc, out = check_regalloc(src, ["--inject-read-gap"])
    if rc != 1:
        return False, f"check-regalloc +--inject-read-gap (non-func0): rc={rc}, expected 1:\n{out[-500:]}"
    m = SUMMARY_LINE.search(out)
    if not m or int(m.group(2)) == 0:
        return False, f"check-regalloc +--inject-read-gap (non-func0): summary missing or 0 violations:\n{out[-500:]}"
    v = re.search(r"^entry-consistency: func (\d+) \((\S+)\): rule (\d+) violation",
                  out, re.MULTILINE)
    if not v:
        return False, f"check-regalloc +--inject-read-gap (non-func0): no violation line:\n{out[-500:]}"
    if v.group(3) != "2" or int(v.group(1)) == 0:
        return False, (f"check-regalloc +--inject-read-gap (non-func0): violation not on "
                       f"non-func-0 rule 2 (got func {v.group(1)} ({v.group(2)}) rule "
                       f"{v.group(3)}):\n{out[-500:]}")
    return True, f"read-gap detected on non-func-0 func (rule 2, func {v.group(1)} {v.group(2)})"


def check_coexist_oob_guard() -> tuple:
    """GC-1（M-5）上界防御：entries_coexist 对越界条目索引（e1/e2 ≥
    g_entry_count）必须返回 0——不越界读。守卫缺失时槽后区域是分配器零
    填充（rt.s alloc zero-init；条目表容量 ≥ 计数），全零条目区间 [0,0]
    与任何区间相交 → 误判共存返回 1（或读到缓冲外崩溃）。

    --inject-coexist-oob 探针通道：输出 "coexist-oob-guard: <r>"，
    r != 0（探针自检失败）→ 退出码 1。与 dump-coexist 摘要同源同前置
    （compute_live_ranges），真实构建路径永不注入。"""
    src = "fn main()->int{a:=1;b:=2;return a+b;}\n"
    rc, out = corearch_chan(src, "--inject-coexist-oob")
    if rc != 0:
        return False, f"corearch --inject-coexist-oob rc={rc}\n{out[-500:]}"
    m = re.search(r"^coexist-oob-guard: (\d+)$", out, re.MULTILINE)
    if not m:
        return False, f"no coexist-oob-guard line:\n{out[-500:]}"
    if m.group(1) != "0":
        return False, f"coexist-oob-guard: OOB probe returned {m.group(1)}, want 0:\n{out[-500:]}"
    return True, "coexist OOB guard OK"


def main() -> int:
    if not COREC.exists():
        print("[FAIL] missing build/corec")
        return 1
    passed = 0
    total = 13
    ok, msg = run_smoke()
    if ok:
        passed += 1
    print(f"[{'PASS' if ok else 'FAIL'}] live-range smoke: {msg}")
    ok, msg = check_versioned_entries()
    if ok:
        passed += 1
    print(f"[{'PASS' if ok else 'FAIL'}] entries versioning: {msg}")
    ok, msg = check_array_birth_versions()
    if ok:
        passed += 1
    print(f"[{'PASS' if ok else 'FAIL'}] array-birth versioning: {msg}")
    ok, msg = check_coexistence()
    if ok:
        passed += 1
    print(f"[{'PASS' if ok else 'FAIL'}] coexistence: {msg}")
    ok, msg = check_coexist_oob_guard()
    if ok:
        passed += 1
    print(f"[{'PASS' if ok else 'FAIL'}] coexist OOB guard: {msg}")
    ok, msg = check_regalloc_consistency()
    if ok:
        passed += 1
    print(f"[{'PASS' if ok else 'FAIL'}] regalloc consistency: {msg}")
    ok, msg = check_regalloc_real_use()
    if ok:
        passed += 1
    print(f"[{'PASS' if ok else 'FAIL'}] regalloc real use: {msg}")
    ok, msg = check_regalloc_loop_carry()
    if ok:
        passed += 1
    print(f"[{'PASS' if ok else 'FAIL'}] regalloc loop carry: {msg}")
    ok, msg = check_regalloc_cond_def_carry()
    if ok:
        passed += 1
    print(f"[{'PASS' if ok else 'FAIL'}] regalloc cond-def carry: {msg}")
    ok, msg = check_regalloc_else_def_carry()
    if ok:
        passed += 1
    print(f"[{'PASS' if ok else 'FAIL'}] regalloc else-def carry: {msg}")
    ok, msg = check_regalloc_else_controls()
    if ok:
        passed += 1
    print(f"[{'PASS' if ok else 'FAIL'}] regalloc else controls: {msg}")
    ok, msg = check_regalloc_violations()
    if ok:
        passed += 1
    print(f"[{'PASS' if ok else 'FAIL'}] regalloc violations: {msg}")
    ok, msg = check_regalloc_read_gap_nonfunc0()
    if ok:
        passed += 1
    print(f"[{'PASS' if ok else 'FAIL'}] regalloc read-gap non-func0: {msg}")
    print(f"{passed}/{total} passed")
    return 0 if passed == total else 1


if __name__ == "__main__":
    raise SystemExit(main())
