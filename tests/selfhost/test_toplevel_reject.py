#!/usr/bin/env python3
"""顶层兜底「静默吞 token」收口（批 8 条目 4；自举编译器 build/corec）。

**现象（修复前实测，计划 §1 条目 4）**：`parse_declaration()` 末尾为**裸 `advance_tok()`** ⇒ 无法识别的
顶层 token 被无声消费（既无诊断、也无定位）；① 顶层多余 `}` ⇒ check=0 · build=0 · 运行 7；
② `stuct S { f: int }`（typo、未使用）⇒ check=0（声明被无声丢弃）；③ 同上但使用 `S` ⇒ TF01 误报 + build=0
⇒ 运行期 139（与条目 6 同族）。

**修复（批 8 条目 4，`parser.cr`）**：兜底改 `error[P25]`（`EC_P_TOPLEVEL_TOKEN = 1025`）定位硬错，
且**仍然消费该 token**（P6：只报错不 `advance` ⇒ `parse_all` 空转 = **挂起**，CI 超时不是红）。

**同批前置修（本轮实测暴露，同一「依赖静默吞」家族）**：`parse_all` 的 import 跳过段只吞 `import`
关键字本身，其后的**路径/别名 token** 一直靠兜底静默吞 ⇒ 新硬错会误伤**每一条合法 import**（实测
`import io` 的 `io`、注入的 `src/runtime/rt.cr` 的 `import arena_globals`）。修复 = 按 `module.cr`
res_imports 的扫描形状**逐字**消费 `[@proj] [a(::b)*] [: alias] [;]`（不得放宽成「吞到分号」）。

**判据要件（计划 §1 条目 4）**：① 非法顶层 token ⇒ check rc=1 + 定位 + **build rc=1 且零产物**；
② 合法顶层形态（import / mod / `@` 注解 / 全局声明（含**无初值** `g : int, mut;`）/ type 别名）
**逐字节不变**（本档以 check+build+run 三面钉子承担；产物面由批级 canary 承担）；
③ 与条目 6 同批核对（③ 的 TF01 属同族）；④ **不挂起**（超时 = 红）。

**突变自证（批级留痕）**：把兜底退回裸 `advance_tok()` ⇒ ① 组回 `check=0` ⇒ 必红。
**全语料对拍（批级留痕）**：212 档 `.cr` × `check`，前态二进制 vs 本修复 ⇒ 差异仅 7 档，且
**全部本就 rc=1**（spec 负例 5 + 探针 1 + 旧 fixture 1，期望码 V02/V03 仍在）⇒ 合法语料零差异。
"""

import os
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"
HANG_LIMIT = 60          # 秒；超过即判「挂起」（P6）


def _run(args, path=None, timeout=HANG_LIMIT):
    t0 = time.time()
    try:
        r = subprocess.run([str(COREC)] + args, cwd=BASE, capture_output=True,
                           text=True, timeout=timeout)
        return r.returncode, r.stdout, time.time() - t0, False
    except subprocess.TimeoutExpired:
        return None, "", time.time() - t0, True


def run_case(name, source, expect_reject):
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as f:
        f.write(f"// toplevel-{uuid.uuid4()}\n" + source)
        path = f.name
    out = str(BASE / "build" / f"_toplevel_{uuid.uuid4().hex[:8]}")
    try:
        if expect_reject:
            rc, so, dt, hang = _run(["check", path])
            if hang:
                return False, f"check 挂起（>{HANG_LIMIT}s）——P6 违背"
            diag = "error[P25]" in so
            b_rc, _, b_dt, b_hang = _run(["build", path, "-o", out, "--static"])
            art = os.path.exists(out) or os.path.exists(out + ".ccr")
            ok = rc == 1 and diag and not b_hang and b_rc == 1 and not art
            return ok, (f"check={rc} P25={diag} 定位={'-->' in so} build={b_rc} "
                        f"产物={art} 耗时={dt:.1f}s/{b_dt:.1f}s")
        rc, so, dt, hang = _run(["check", path])
        if rc != 0 or hang:
            return False, f"check={rc} 挂起={hang}（合法形态不得报错）"
        b_rc, _, _, b_hang = _run(["build", path, "-o", out, "--static"])
        if b_rc != 0 or b_hang:
            return False, f"build={b_rc} 挂起={b_hang}"
        run_rc = subprocess.run([out], cwd=BASE, capture_output=True, timeout=60).returncode
        return run_rc == 0, f"check=0 build=0 run={run_rc}"
    finally:
        os.unlink(path)
        for p in (out, out + ".ccr"):
            if os.path.exists(p):
                os.unlink(p)


REJECTS = [
    ("stray_rbrace", "fn main() -> int { return 0; }\n}\n", "① 顶层多余 `}`（修前 check=0·build=0·运行 7）"),
    ("typo_struct", "stuct S { f: int }\nfn main() -> int { return 0; }\n", "② typo 声明（修前被无声丢弃）"),
    ("typo_struct_used", "stuct S { f: int }\nfn main() -> int { s := S { f: 1 }; return s.f; }\n",
     "③ 同上 + 使用（修前 TF01 误报 + 运行 139）"),
    ("stray_semi", ";\nfn main() -> int { return 0; }\n", "游离 `;`"),
    ("bogus_kw", "fnn main() -> int { return 0; }\n", "typo 关键字 `fnn`"),
]

ACCEPTS = [
    ("import_io", 'import io\nfn main() -> int { println("hi"); return 0; }\n',
     "合法 import（**本轮新修**：路径/别名 token 此前靠静默吞）"),
    ("import_alias", "import io : i\nfn main() -> int { return 0; }\n", "带别名 import"),
    ("global_no_init", "g : int, mut;\nfn main() -> int { g = 1; return g - 1; }\n",
     "无初值全局声明（注入运行时源 `rt.cr:4` 同形；此前靠静默吞）"),
    ("global_init", "g : int, mut = 2;\nfn main() -> int { return g - 2; }\n", "有初值全局声明"),
    ("mod_decl", "mod m;\nfn main() -> int { return 0; }\n", "`mod` 声明"),
    ("type_alias", "type T = int;\nfn main() -> int { x : T = 0; return x; }\n", "type 别名"),
    ("hotpatch_ann", "@hotpatch(ver=1)\nfn f() -> int { return 0; }\nfn main() -> int { return f(); }\n",
     "`@` 注解 + 函数"),
]


def main():
    ok = 0
    fails = []
    for name, src, note in REJECTS:
        passed, detail = run_case(name, src, True)
        print(f"[{'PASS' if passed else 'FAIL'}] {name}: {detail}  # {note}")
        if passed:
            ok += 1
        else:
            fails.append(name)
    for name, src, note in ACCEPTS:
        passed, detail = run_case(name, src, False)
        print(f"[{'PASS' if passed else 'FAIL'}] {name}: {detail}  # {note}")
        if passed:
            ok += 1
        else:
            fails.append(name)
    total = len(REJECTS) + len(ACCEPTS)
    print(f"\n{ok}/{total} 通过")
    if fails:
        print("失败档：" + ", ".join(fails))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
