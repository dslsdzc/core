#!/usr/bin/env python3
"""R2 P3 Task 3：match 穷尽性真判定（补集空性 + 具体变体反例）行为覆盖集。

判据（正/负/边界/登记；语义见 docs/superpowers/plans/2026-09-11-r2-p3-capabilities.md Task 3）：

  正：全覆盖过（**解释器 + ELF 双路径同值**）/ 通配臂吸收 / 绑定臂吸收 / 限定名模式
      / payload 变体 / 泛型枚举实例 / 单变体枚举 / 枚举形参位
  负：缺臂 ⇒ rc=1 + `error[TM03]` + 反例含具体缺失**变体名** + **无产物**（绝不静默 rc=0——
      修复前实测：缺臂产物照出，未匹配值静默得 0）；无臂 ⇒ 同上；`check` 子命令同拒
  登记：非枚举域不判穷尽（int 匹配 rc=0）；不可映射模式（枚举匹配里混字面量臂）不判穷尽 rc=0
  软面：重复臂 ⇒ `error[TM04]` **非硬门**（rc=0 + 产物照出）——诊断面登记，非 rc 面收紧

背景（Task 3 前实测，本套件即其回归）：`EC_TM_*`（9001-9009）此前仅定义零 raise，match
**零检查**；`match c { Red => 1, Green => 2 }`（缺 Blue）check/build rc=0、产物可跑，
`c := Blue()` 时静默落空得 0（探针 p1b 实测 rc=100 = 0 + 100）。
"""

import os
import resource
import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"


def _no_core_dump():
    # core_pattern 为 systemd-coredump 管道时，崩溃的陷阱程序会挂起——禁用 core dump。
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def _compile(source: str, cmd="build"):
    """返回 (result, out_path, src_path)；cmd = build（ELF 产物）| check（仅前端）。"""
    fd, src = tempfile.mkstemp(suffix=".cr")
    with os.fdopen(fd, "w") as f:
        f.write(source)
    out = src[:-3]
    if cmd == "build":
        args = [str(COREC), "build", src, "-o", out, "--static"]
    else:
        args = [str(COREC), "check", src]
    r = subprocess.run(args, capture_output=True, text=True, cwd=BASE, timeout=180)
    return r, out, src


def _cleanup(*paths):
    for p in paths:
        try:
            os.unlink(p)
        except FileNotFoundError:
            pass


def build_and_run(source: str):
    """返回 (compile_result, run_result|None)。"""
    r, out, src = _compile(source)
    try:
        if r.returncode != 0:
            return r, None
        rr = subprocess.run(
            [out], capture_output=True, text=True, timeout=10,
            preexec_fn=_no_core_dump,
        )
        return r, rr
    finally:
        _cleanup(src, out, out + ".ccr")


def run_interp(source: str):
    """解释器路径（共享同一 run_frontend ⇒ 同一判定面）；rc = main 返回值。"""
    return subprocess.run(
        [str(COREC), "run", source], capture_output=True, text=True, cwd=BASE, timeout=180,
    )


def case_run(name, source, expect_rc):
    r, rr = build_and_run(source)
    if rr is None:
        print(f"[FAIL] {name}: compile rc={r.returncode}: {r.stdout}{r.stderr}")
        return False
    if rr.returncode != expect_rc:
        print(f"[FAIL] {name}: expected rc {expect_rc}, got {rr.returncode}")
        return False
    print(f"[PASS] {name}: rc={rr.returncode}")
    return True


def case_reject(name, source, needles, cmd="build"):
    r, out, src = _compile(source, cmd)
    try:
        if r.returncode == 0:
            print(f"[FAIL] {name}: expected rejection, got rc=0（静默通过面复活）")
            return False
        text = r.stdout + r.stderr
        for n in needles:
            if n not in text:
                print(f"[FAIL] {name}: rc={r.returncode} 但缺诊断 {n!r}: {text}")
                return False
        if cmd == "build" and os.path.exists(out):
            print(f"[FAIL] {name}: 拒绝编译却仍产出二进制 {out}")
            return False
        print(f"[PASS] {name}: rc={r.returncode} + {needles!r}")
        return True
    finally:
        _cleanup(src, out, out + ".ccr")


def case_interp(name, source, expect_rc):
    r = run_interp(source)
    if r.returncode != expect_rc:
        print(f"[FAIL] {name}: expected interp rc {expect_rc}, got {r.returncode}: {r.stdout}{r.stderr}")
        return False
    print(f"[PASS] {name}: interp rc={r.returncode}")
    return True


def case_run_reject(name, source, needles):
    """run（解释器）路径：判定在共享 run_frontend ⇒ 同拒（rc=1 + TM03）。"""
    r = run_interp(source)
    if r.returncode == 0:
        print(f"[FAIL] {name}: run 路径 expected rejection, got rc=0")
        return False
    text = r.stdout + r.stderr
    for n in needles:
        if n not in text:
            print(f"[FAIL] {name}: rc={r.returncode} 但缺诊断 {n!r}: {text}")
            return False
    print(f"[PASS] {name}: rc={r.returncode} + {needles!r}")
    return True


def case_soft(name, source, needle):
    """软诊断面（非硬门）：编译 rc=0 + 产物照出 + 诊断在文本中。"""
    r, rr = build_and_run(source)
    if rr is None:
        print(f"[FAIL] {name}: 软诊断面应为 rc=0（非硬门），compile rc={r.returncode}: {r.stdout}{r.stderr}")
        return False
    if needle not in r.stdout + r.stderr:
        print(f"[FAIL] {name}: 缺软诊断 {needle!r}: {r.stdout}{r.stderr}")
        return False
    print(f"[PASS] {name}: rc=0 + 产物照出 + {needle!r}")
    return True


# ── 源形 ──────────────────────────────────────────────────────────────

COLOR = "enum Color { Red, Green, Blue }\n"
CHOICE = "enum Choice { First(int), Second(int), Third(int) }\n"


def missing_arm_src(scrutinee="Blue"):
    return COLOR + f"""fn main() -> int {{
    c := {scrutinee}();
    v := match c {{
        Red => 1,
        Green => 2,
    }};
    return v + 100;
}}
"""


def main():
    ok = [
        # 正：全覆盖 ELF 路径（Green ⇒ 2）
        case_run("exhaustive_elf", COLOR + "fn main() -> int { c := Green(); "
                 "return match c { Red => 1, Green => 2, Blue => 3, }; }\n", 2),
        # 正：同源解释器路径（Blue ⇒ 3；与 ELF 路径共享判定面）
        case_interp("interp_exhaustive",
                    COLOR + "fn main() -> int { c := Blue(); return match c { Red => 1, Green => 2, Blue => 3, }; }\n", 3),
        # 正：通配臂吸收（⊤）
        case_run("wildcard_absorbs", COLOR + "fn main() -> int { c := Blue(); "
                 "return match c { Red => 1, _ => 7, }; }\n", 7),
        # 正：绑定臂吸收
        case_run("binding_absorbs", COLOR + "fn main() -> int { c := Red(); "
                 "return match c { x => 9, }; }\n", 9),
        # 正：限定名模式（Enum.Variant）
        case_run("qualified_pattern", COLOR + "fn main() -> int { c := Blue(); "
                 "return match c { Color.Red => 1, Color.Green => 2, Color.Blue => 3, }; }\n", 3),
        # 正：payload 变体（三臂全列）
        case_run("payload_exhaustive", CHOICE + "fn main() -> int { c := Third(33); "
                 "return match c { First(v) => v, Second(v) => v, Third(v) => v, }; }\n", 33),
        # 正：泛型枚举实例（Opt[int]）
        case_run("generic_enum_exhaustive",
                 "enum Opt[T] { N, S(T) }\nfn main() -> int { c := S(5); "
                 "return match c { N => 1, S(x) => x, }; }\n", 5),
        # 正：单变体枚举（域最小边界）
        case_run("single_variant_exhaustive",
                 "enum Only { One }\nfn main() -> int { c := One(); "
                 "return match c { One => 4, }; }\n", 4),
        # 正：枚举形参位（scrutinee 来自形参 ti 而非构造器）
        case_run("enum_param_exhaustive", COLOR + "fn f(c: Color) -> int { "
                 "return match c { Red => 1, Green => 2, Blue => 3, }; }\n"
                 "fn main() -> int { return f(Green()); }\n", 2),
        # 负：缺臂 ⇒ rc=1 + TM03（含具体缺失变体名）+ 无产物
        case_reject("missing_arm_rejected", missing_arm_src(),
                    ["error[TM03]", "Non-exhaustive match", "missing variant 'Blue'"]),
        # 负：无臂（空 match 体）⇒ 同上（未覆盖面 = 全域，首个变体即反例）
        case_reject("no_arms_rejected",
                    COLOR + "fn main() -> int { c := Red(); return match c { }; }\n",
                    ["error[TM03]", "missing variant 'Red'"]),
        # 负：check 子命令同拒（判定在共享前端，非 ELF 路径专属）
        case_reject("check_path_rejected", missing_arm_src(), ["error[TM03]"], cmd="check"),
        # 负：run（解释器）路径同拒（同一 run_frontend ⇒ 同一判定面）
        case_run_reject("run_path_rejected",
                        COLOR + "fn main() -> int { c := Blue(); return match c { Red => 1, Green => 2, }; }\n",
                        ["error[TM03]", "missing variant 'Blue'"]),
        # 登记：非枚举域不判穷尽（int 字面量匹配 ⇒ 零诊断，rc=0）
        case_run("non_enum_domain_not_judged",
                 "fn main() -> int { n := 3; return match n { 1 => 10, 2 => 20, }; }\n", 0),
        # 登记：不可映射模式（枚举匹配混字面量臂）不判穷尽（-1 = 不判，不得当「不穷尽」）
        case_run("unmappable_pattern_not_judged",
                 "enum Color2 { Red2, Green2, Blue2 }\nfn main() -> int { c := Blue2(); "
                 "return match c { Red2 => 1, 5 => 2, }; }\n", 0),
        # 软面：重复臂 ⇒ TM04 非硬门（rc=0 + 产物照出）
        case_soft("redundant_arm_soft",
                  COLOR + "fn main() -> int { c := Red(); "
                  "return match c { Red => 1, Red => 2, Green => 3, Blue => 4, }; }\n",
                  "error[TM04]"),
    ]
    passed = sum(1 for x in ok if x is True)
    print(f"{passed}/{len(ok)} passed")
    return 0 if passed == len(ok) else 1


if __name__ == "__main__":
    raise SystemExit(main())
