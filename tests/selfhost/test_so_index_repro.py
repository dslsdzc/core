#!/usr/bin/env python3
"""第 4 批（TODO #2026-09-16-20/#2026-09-16-21/#2026-09-17-1/#2026-09-17-2）：`.so` 扩展索引的**可复现性 / 承重面 / 内存安全**判据。

被验对象：编译器解析 `import` 时读 `$HOME/.core/lib/<模块>/index` 的行为
（`src/compiler/module.cr` 的原读点 + 侧表 + `find_gsym`/`find_so_fn` 回退）。

口径（**夹具入仓 = 判据自己必须可复现**）：两态对拍所需的索引一律取
`tests/fixtures/so_index/`（放进临时 HOME），**不得**用各机自备的 `$HOME` 索引。

判据（逐条对应计划 §4）：
  C1 = J1  正常档（含 io.cr 未声明的 `print_int`/`println_int`）⇒ 两态 `.ccr` **逐字节同**
           （两条口径：`ccr` 与 `build --static`）
  C2 = J2  **良性档**（每条名字都已在 io.cr 声明）⇒ 两态逐字节同（反例测试：证明
           「敏感性 = 索引存在性」已被消除，不只是「新名数量」）
  C3 = J3  **承重面**：调用索引独有名字 ⇒ 有索引 rc=0；**无索引必须响亮失败**
           （rc=1 + `error[N06]`，**无产物**）——本批红线：查不到时**不得放行**
  C4 = J9  索引行数不再是行为分界：N=2/200/2000 三档 ⇒ 产物逐字节同 **且进程 rc 正常**
           （不得 139/崩溃——内存破坏的判据不能只看产物：N=200 那次产物正常但堆已坏）
  C5 = J5  `env -u HOME`（unset）与空 HOME 目录 ⇒ 产物逐字节同（#83）
  C6 = J7  ELF 面（`--static`）跨两态逐字节同
  C7 = J4  静态：`src/` 内**零命中**硬编码家目录常量（#83）

需先构建：nice -n 19 python3 build_selfhost_native.py
跑法：python3 tests/selfhost/test_so_index_repro.py
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

BASE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
COREC = os.path.join(BASE, "build", "corec")
FX = os.path.join(BASE, "tests", "fixtures", "so_index")
GT = "tests/suite/generics_test.cr"          # import io/fmt；不引用索引独有名字
USE_EXT = "tests/fixtures/so_index/use_ext.cr"  # 调用索引独有名字（承重面）

# 进程异常退出码（内存破坏的可见面；正常码只允许 0/1）
def _abnormal(rc: int) -> bool:
    return rc not in (0, 1)


def make_home(tmp: str, index_lines: list) -> str:
    """造一个受控 HOME：<tmp>/.core/lib/io/index = index_lines。"""
    home = os.path.join(tmp, "home")
    lib = os.path.join(home, ".core", "lib", "io")
    os.makedirs(lib, exist_ok=True)
    with open(os.path.join(lib, "index"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(index_lines) + "\n")
    return home


def gen_index(n: int) -> list:
    """确定性生成 N+1 行索引（首行 print，其余 ghost{i}）——与 fixtures README 同规。"""
    return ["print: string, variadic, auto_str"] + [f"ghost{i}: int" for i in range(n)]


def fixture_index(name: str) -> list:
    with open(os.path.join(FX, name), encoding="utf-8") as fh:
        return [ln for ln in fh.read().splitlines()
                if ln.strip() and not ln.strip().startswith("//")]


def run_corec(args: list, home, unset_home: bool = False) -> subprocess.CompletedProcess:
    """HOME 受控地跑一次 corec（先 clean-cache，冷态）。"""
    env = dict(os.environ)
    env.pop("HOME", None)
    if not unset_home:
        env["HOME"] = home
    subprocess.run([COREC, "clean-cache"], cwd=BASE, env=env,
                   capture_output=True, text=True)
    return subprocess.run([COREC] + args, cwd=BASE, env=env,
                          capture_output=True, text=True)


def ccr_bytes(home, src: str, out: str, unset_home: bool = False):
    r = run_corec(["ccr", src, "-o", out], home, unset_home)
    blob = open(out, "rb").read() if os.path.exists(out) else None
    return r.returncode, blob


def main() -> int:
    if not os.path.exists(COREC):
        print("build/corec missing; run build_selfhost_native.py")
        return 1
    fails, passes = [], []
    tmp = tempfile.mkdtemp(prefix="soidx_")
    try:
        empty = os.path.join(tmp, "empty")           # 空 HOME（无索引）
        os.makedirs(empty, exist_ok=True)
        h_norm = make_home(os.path.join(tmp, "n"), fixture_index("io.index"))
        h_benign = make_home(os.path.join(tmp, "b"), fixture_index("io_benign.index"))

        # ── C1 = J1 正常档：两条口径（ccr / build --static；后者的 .ccr 在 <out>.ccr） ──
        for tag, verb, suffix in (("ccr", "ccr", ""), ("build --static", "build", ".ccr")):
            o_empty = os.path.join(tmp, "j1_empty_" + verb)
            o_idx = os.path.join(tmp, "j1_idx_" + verb)
            extra = ["--static"] if verb == "build" else []
            r0 = run_corec([verb, GT, "-o", o_empty] + extra, empty)
            r1 = run_corec([verb, GT, "-o", o_idx] + extra, h_norm)
            p0, p1 = o_empty + suffix, o_idx + suffix
            if r0.returncode != 0 or r1.returncode != 0:
                fails.append(f"C1[{tag}] rc: 空 HOME={r0.returncode} 有索引={r1.returncode}")
            elif not (os.path.exists(p0) and os.path.exists(p1)):
                fails.append(f"C1[{tag}] 产物缺失")
            elif open(p0, "rb").read() != open(p1, "rb").read():
                fails.append(f"C1[{tag}] 两态 .ccr 不同 "
                             f"({os.path.getsize(p0)} vs {os.path.getsize(p1)})")
            else:
                passes.append(f"C1/J1[{tag}] 两态逐字节同（{os.path.getsize(p0)}B）")

        # ── C2 = J2 良性档 ──
        o_b = os.path.join(tmp, "j2.ccr")
        rc_b, b_b = ccr_bytes(h_benign, GT, o_b)
        o_e = os.path.join(tmp, "j2e.ccr")
        _, b_e = ccr_bytes(empty, GT, o_e)
        if rc_b != 0 or b_b is None:
            fails.append(f"C2 良性档 rc={rc_b}")
        elif b_b != b_e:
            fails.append(f"C2/J2 良性档与空 HOME 不同（{len(b_b)} vs {len(b_e)}）")
        else:
            passes.append("C2/J2 良性索引零足迹（同尺寸同 sha）")

        # ── C3 = J3 承重面 ──
        o_y = os.path.join(tmp, "j3y.ccr")
        rc_y, _ = ccr_bytes(h_norm, USE_EXT, o_y)
        r_n = run_corec(["check", USE_EXT], empty)
        if rc_y != 0:
            fails.append(f"C3/J3 有索引时 use_ext 应 rc=0，实际 {rc_y}")
        elif r_n.returncode != 1 or "N06" not in (r_n.stdout + r_n.stderr):
            fails.append(f"C3/J3 无索引时应 rc=1 + error[N06]（响亮失败），"
                         f"实际 rc={r_n.returncode}")
        else:
            passes.append("C3/J3 承重面保住（有索引 rc=0；无索引 rc=1 + N06 响亮）")

        # ── C4 = J9 行数不再是分界（含 rc 正常性） ──
        ref = os.path.join(tmp, "j9ref.ccr")
        _, bref = ccr_bytes(empty, GT, ref)
        ok9 = True
        for n in (2, 200, 2000):
            hn = make_home(os.path.join(tmp, f"n{n}"), gen_index(n))
            on = os.path.join(tmp, f"j9_{n}.ccr")
            rcn, bn = ccr_bytes(hn, GT, on)
            if _abnormal(rcn):
                fails.append(f"C4/J9 N={n} **进程异常退出 rc={rcn}**（内存破坏信号）")
                ok9 = False
            elif bn != bref:
                fails.append(f"C4/J9 N={n} 产物与空 HOME 不同（{len(bn or b'')} vs {len(bref or b'')}）")
                ok9 = False
        if ok9:
            passes.append("C4/J9 N=2/200/2000 三档产物逐字节同 + rc 均正常（#99 越界面已消除）")

        # ── C5 = J5 HOME unset vs 空目录 ──
        o_u = os.path.join(tmp, "j5u.ccr")
        rc_u, b_u = ccr_bytes(None, GT, o_u, unset_home=True)
        if rc_u != 0 or b_u != bref:
            fails.append(f"C5/J5 unset HOME 与空 HOME 不同（rc={rc_u}）")
        else:
            passes.append("C5/J5 HOME unset ≡ 空 HOME（#83：不再读任何家目录）")

        # ── C6 = J7 ELF 面跨两态 ──
        e0 = os.path.join(tmp, "j7e"); e1 = os.path.join(tmp, "j7i")
        r0 = run_corec(["build", GT, "-o", e0, "--static"], empty)
        r1 = run_corec(["build", GT, "-o", e1, "--static"], h_norm)
        if r0.returncode or r1.returncode:
            fails.append(f"C6/J7 ELF 构建 rc={r0.returncode}/{r1.returncode}")
        elif open(e0, "rb").read() != open(e1, "rb").read():
            fails.append("C6/J7 ELF 两态不同")
        else:
            passes.append("C6/J7 ELF 跨两态逐字节同（发射面零泄漏）")

        # ── C7 = J4 静态：无硬编码家目录**字面量** ──
        # 口径 = 「**字符串字面量**里的绝对家目录路径」（如 `"/home/<名>"`）——那是被当作值
        # 使用的常量（原缺陷形态）。散文/注释里出现的 `/home/` 不算（实测：`ccr_io.cr:174`
        # 的 `live_end/home/flags` 是字段列表，宽正则误报过一次 ⇒ 本条按字面量判定）。
        pat = re.compile(r'"[^"\n]*/home/[A-Za-z0-9_]+[^"\n]*"')
        hits = []
        for root, _dirs, files in os.walk(os.path.join(BASE, "src")):
            for fn in files:
                if not fn.endswith(".cr"):
                    continue
                p = os.path.join(root, fn)
                with open(p, encoding="utf-8", errors="replace") as fh:
                    for no, ln in enumerate(fh, 1):
                        if pat.search(ln):
                            hits.append(f"{os.path.relpath(p, BASE)}:{no}")
        if hits:
            fails.append("C7/J4 硬编码家目录字面量命中：" + ", ".join(hits[:5]))
        else:
            passes.append("C7/J4 src/ 零命中硬编码家目录字面量（#83 静态判据）")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    for p in passes:
        print(f"[PASS] {p}")
    for f in fails:
        print(f"[FAIL] {f}")
    print("=== so_index_repro: " + ("ALL PASS" if not fails else "FAILURES") +
          f"（pass={len(passes)} fail={len(fails)}） ===")
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())
