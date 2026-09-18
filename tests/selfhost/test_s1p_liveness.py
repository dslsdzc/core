#!/usr/bin/env python3
"""S1′ 打点（批 8 PR-B/F3 · report-only）**活性自证 + 默认零足迹**。

**为什么要有这一档**（方法论 2026-09-18）：打点类扫面的结论有两种假象——**假阳**（grep 裸标识符命中了
源码回显，A 批实测「6 档 30 点」实为 0）与**假阴**（打点根本没装/没生效，「0 点」被当成「真干净」）。
⇒ 必须有一档**必命中**的探针证明打点活着，并且**扫面锚定打印格式**（只认行首 `9917|9918 ` + 字段形状）。

**打点面**：`checker.cr` 直调/方法调用解析尾（**新点**，非泛型直调 + 方法调用；旧点接在
`infer_gen_call` 的泛型推断丢弃处，全语料 0 打点 ⇒ 泛型面未被触碰）。台账格式（数值，零 intern）：

    9917 <line> <col> <param_idx> <param_ti> <arg_ti> <call>     # 主桶
    9918 同形                                                      # extern/C ABI 单列

**开关**：`CORE_S1P=1`（懒读，`globals.cr::g_s1p_on`）。**默认位 = 整块不执行**——不是「执行了但不打印」：
块内的类型引擎调用（`infer_expr`/`res_call_type`/`unify_types`）会向 TYPE(7) 段的项表留项，实测只罩
print 时 `opt_dex_test.cr` 的 `.ccr` 187029→187053（**+24B**，ELF 同）⇒ 必须**整块受门**（判据①）。

**判据**：① 必命中探针在 `CORE_S1P=1` 下逐字段命中（活性）；② 同一探针在默认位/`CORE_S1P=0` 下**零行**；
③ 无失配程序在开位下**零行**（负控：打点只在真不匹配时发）；④ extern 形走 `9918`、默认位零行；
⑤ **全 `tests/suite/*.cr` 在默认位零打点**（「默认零足迹」的语料面；产物逐字节面见批级对拍）；
⑦ **自源台账 bool 桶归零**：`check src/compiler/main.cr` 的台账里 `arg_ti=2`（bool ← int 形参）点必须为 0
（bool 类 171 处已改 `ts_check_b`/`ps_check_b` 签名 helper，逐处留痕见
`docs/superpowers/plans/2026-09-18-bool171-sites.tsv`；残桶 = string↔int，归 S2 路线 1）——
**先断言台账非空**：否则「0 桶」与「打点根本没装」不可区分（本档存在的全部理由）。
"""

import os
import re
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"
# 打点格式：`<码> <行> <列> <形参序> <形参TI> <实参TI> <被调名>` **+ 可选** ` @@ <该行源文本>`
# （源行片段 = 2026-09-18 追加的定位通道；门后 ⇒ 默认位不出现）⇒ 正则必须**容忍可选后缀**，
# 否则「打点活着」会被读成 0 命中（本套件在 CI 上正是这样红过一次）。
HIT = re.compile(r"^(9917|9918) (\d+) (\d+) (\d+) (\d+) (\d+) (\S+)(?: @@ .*)?$")

# ⓪ **正则自检**（钉在本档内，不依赖编译器）：格式漂移会让「活性探针 0 命中」与「打点没装」不可区分
#   ——本档在 CI 上正是这样红过一次（@@ 源行片段追加后正则过窄）。⇒ 用**文档化格式的合成行**钉形状：
#   必匹配（含可选后缀）+ 必不匹配（缺字段 / 行首带前导）。
REGEX_SAMPLES = [
    ("9917 12 5 0 0 2 f", True),
    ("9918 3 7 1 10 2 putchar", True),
    ("9917 12 5 0 0 2 f @@     b := true;", True),
    ("9917 12 5 0 0", False),
    ("  9917 12 5 0 0 2 f", False),
]

# 活性命中探针：`b := bool` 传给 `a: int` 形参（非字面量 ⇒ 不被护栏③跳过）
MISMATCH = """fn f(a: int) -> int { return a; }
fn main() -> int {
    b := true;
    return f(b);
}
"""

CLEAN = """fn g(a: int) -> int { return a + 1; }
fn main() -> int {
    n := 41;
    return g(n);
}
"""

EXTERN = """extern fn putchar(c: int) -> int;
fn main() -> int {
    b := true;
    return putchar(b);
}
"""

# 护栏③：字面量多态（`f(3)` 必须**不**打点）
LITERAL = """fn f(a: int) -> int { return a; }
fn main() -> int {
    return f(3);
}
"""

# 护栏⑥：元数不齐（含变参面）⇒ 静默跳过（**不打点**，且不得崩/挂）
ARITY = """fn g2(a: int, b: int) -> int { return a + b; }
fn main() -> int {
    c := true;
    return g2(c);
}
"""

# 护栏②：`None` → `T?` 必须**不**打点；对照腿（同一函数传 bool）**必须**打点
#   ——对照腿是关键：它证明「调用本身到点」，否则 0 打点可能只是没覆盖。
NONE_OPT = """fn h(o: int?) -> int { return 0; }
fn main() -> int {
    return h(None);
}
"""

NONE_OPT_CTRL = """fn h(o: int?) -> int { return 0; }
fn main() -> int {
    b := true;
    return h(b);
}
"""

# ⚠ 覆盖面实测（2026-09-18）：方法调用**不经过本点**（`s.m(b)` 异型 0 打点，而同一函数直调 1 打点）
#   ⇒ ④「方法接收者偏移」代码在本点**不可达**（保留待 S2/S3 扩覆盖；**不得当死码删除**）。
#   本档把该事实钉成判据：S2/S3 扩覆盖后此腿必须翻成 ≥1 打点。
METHOD_GAP = """struct S { f: int }
impl S {
    fn m(self: S, x: int) -> int { return x; }
}
fn main() -> int {
    b := true;
    s : ., mut = S { f = 0 };
    return s.m(b);
}
"""


def clean_cache():
    subprocess.run([str(COREC), "clean-cache"], cwd=BASE, capture_output=True, text=True, timeout=120)


def run_check(src_text, s1p):
    """写临时 .cr → `check`（**冷缓存**：每次先 clean-cache，防暖态 intern 串污染读数）。"""
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as f:
        f.write(src_text)
        path = f.name
    env = dict(os.environ)
    env.pop("CORE_S1P", None)
    if s1p is not None:
        env["CORE_S1P"] = s1p
    try:
        clean_cache()
        r = subprocess.run([str(COREC), "check", path], cwd=BASE, env=env,
                           capture_output=True, text=True, timeout=180)
        hits = [m.groups() for m in (HIT.match(l) for l in r.stdout.split("\n")) if m]
        return r.returncode, hits
    finally:
        os.unlink(path)


def main():
    ok = True
    fails = []

    def expect(name, cond, detail):
        nonlocal ok
        print(("  PASS  " if cond else "  FAIL  ") + name + ("" if cond else f"  ← {detail}"))
        if not cond:
            ok = False
            fails.append(name)

    # ⓪ 正则自检（不依赖编译器）：形状漂移 ⇒ 「0 命中」不再可解释为「打点死了」
    bad_regex = [(s, want) for s, want in REGEX_SAMPLES if bool(HIT.match(s)) != want]
    print(f"[⓪ 正则自检]  {len(REGEX_SAMPLES)} 例 · 不合形 = {len(bad_regex)}")
    expect("hit_regex_shape_pinned", not bad_regex, bad_regex)

    # ① 活性：必命中探针（逐字段钉：`f` 第 0 形参 int(0) ← 实参 bool(2)）
    rc, hits = run_check(MISMATCH, "1")
    print(f"[① 活性]  rc={rc} · 打点 {len(hits)} 条：{hits}")
    expect("probe_hits_once", len(hits) == 1, f"期望恰 1 条，得 {len(hits)}")
    if hits:
        tag, ln, col, pi, pti, ati, call = hits[0]
        expect("probe_tag_arg", tag == "9917", tag)
        expect("probe_param_ti_int", pti == "0", pti)
        expect("probe_arg_ti_bool", ati == "2", ati)
        expect("probe_param_idx", pi == "0", pi)
        expect("probe_call_name", call == "f", call)
        expect("probe_loc_line", ln.isdigit() and int(ln) > 0, ln)

    # ② 默认位 / 显式 0 ⇒ 零行（**这一条就是「只发不阻断」在默认位的前提**）
    rc_d, hits_d = run_check(MISMATCH, None)
    rc_0, hits_0 = run_check(MISMATCH, "0")
    print(f"[② 静默]  默认 rc={rc_d} 打点 {len(hits_d)} · CORE_S1P=0 rc={rc_0} 打点 {len(hits_0)}")
    expect("default_silent", not hits_d, hits_d)
    expect("explicit_off_silent", not hits_0, hits_0)

    # ③ 负控：无失配 ⇒ 开位下也零行（打点只在 `unify_types` 判假时发）
    rc_c, hits_c = run_check(CLEAN, "1")
    print(f"[③ 负控]  rc={rc_c} · 打点 {len(hits_c)}")
    expect("clean_zero_hits", not hits_c, hits_c)

    # ④ extern 单列（`9918`）
    rc_e, hits_e = run_check(EXTERN, "1")
    print(f"[④ extern] rc={rc_e} · 打点 {len(hits_e)}：{hits_e}")
    expect("extern_tagged", bool(hits_e) and all(h[0] == "9918" for h in hits_e), hits_e)
    expect("extern_call_putchar", any(h[6] == "putchar" for h in hits_e), hits_e)
    rc_e0, hits_e0 = run_check(EXTERN, None)
    expect("extern_default_silent", not hits_e0, hits_e0)

    # ⑥ 护栏有效性（每条都在**同一台机器上**跑「该跳的跳、该报的报」两侧）
    rc_l, hits_l = run_check(LITERAL, "1")
    print(f"[⑥ 护栏③字面量] rc={rc_l} · 打点 {len(hits_l)}")
    expect("guard3_literal_silent", not hits_l, hits_l)

    rc_a, hits_a = run_check(ARITY, "1")
    print(f"[⑥ 护栏⑥元数]   rc={rc_a} · 打点 {len(hits_a)}")
    expect("guard6_arity_silent", not hits_a, hits_a)

    rc_n, hits_n = run_check(NONE_OPT, "1")
    rc_nc, hits_nc = run_check(NONE_OPT_CTRL, "1")
    print(f"[⑥ 护栏②None]   None 腿 rc={rc_n} 打点 {len(hits_n)} · 对照(bool 腿) rc={rc_nc} 打点 {len(hits_nc)}")
    expect("guard2_none_silent", not hits_n, hits_n)
    expect("guard2_control_hits", len(hits_nc) == 1 and hits_nc[0][4] == "10",
           f"对照腿应恰 1 条且形参 TI=10（可选），得 {hits_nc}")

    rc_m, hits_m = run_check(METHOD_GAP, "1")
    print(f"[⚠ 覆盖面]      方法调用 rc={rc_m} · 打点 {len(hits_m)}（**实测不可达**，见档头注）")
    expect("method_call_not_covered", len(hits_m) == 0,
           f"若此处非 0 ⇒ 方法面已覆盖，请同步更新档头注与 (ii) 覆盖面；得 {hits_m}")

    # ⑤ 语料面：默认位全 tests/suite/*.cr 零打点（冷缓存逐档）
    corpus_hits = []
    files = sorted(BASE.glob("tests/suite/*.cr"))
    for f in files:
        clean_cache()
        r = subprocess.run([str(COREC), "check", str(f)], cwd=BASE, capture_output=True,
                           text=True, timeout=300)
        bad = [l for l in r.stdout.split("\n") if HIT.match(l)]
        if bad:
            corpus_hits.append((f.name, bad[:2]))
    print(f"[⑤ 语料]  {len(files)} 档 · 默认位带打点的档 = {len(corpus_hits)}")
    for name, bad in corpus_hits[:5]:
        print(f"    {name}: {bad}")
    expect("corpus_default_silent", not corpus_hits, corpus_hits[:3])

    # ⑦ 自源台账：bool 桶必须归零（**先证扫面非空**——「0」与「没装」必须可区分）
    clean_cache()
    env = dict(os.environ)
    env["CORE_S1P"] = "1"
    r = subprocess.run([str(COREC), "check", str(BASE / "src" / "compiler" / "main.cr")],
                       cwd=BASE, env=env, capture_output=True, text=True, timeout=1800)
    rows = [m.groups() for m in (HIT.match(l) for l in r.stdout.split("\n")) if m]
    bools = [x for x in rows if x[5] == "2"]
    print(f"[⑦ 自源台账] rc={r.returncode} · 总点 {len(rows)} · bool 桶 {len(bools)}"
          + (f" ← {bools[:3]}" if bools else ""))
    expect("selfsource_ledger_nonvacuous", len(rows) > 0,
           "台账为空 ⇒ 扫面没生效（打点没装/锚定格式漂了）——此时 bool 桶=0 无意义")
    expect("selfsource_bool_bucket_zero", not bools, bools[:3])

    print(("S1P LIVENESS " + ("PASS" if ok else "FAIL")) + f" · 失败项 = {fails}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
