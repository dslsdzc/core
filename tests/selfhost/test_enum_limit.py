#!/usr/bin/env python3
"""枚举/结构体容量面回归（TODO #35 → **容量批 T3 解除**）。

**旧态（#35 修复，2026-09-12）**：`EnumVariant` 槽区（`MAX_ENUM_VARIANTS=16` 槽 × `OFF_EV_SIZE=272`）
与 `StructInfo` 字段槽区（`MAX_STRUCT_FIELDS=16` 槽）是**定长内嵌槽区** ⇒ >16 越界写（踩 count/邻记录）
⇒ parser 写点护栏 + `error[P022]`/`error[P023]` 定位硬错（rc=1 + 无产物）。

**新态（容量批 T3，裁-CAP-2 (a)「记录布局迁侧表」）**：字段/变体/载荷**迁侧表** ⇒ 三面**无硬上限**；
`P022`/`P023` **退役**（零 raise）；覆盖位自 `2^vi` 单 int 换为**无界位图**（`mc_*`）⇒ ≥63 变体的
穷尽性/冗余臂判定恢复正确（旧态实测 70 变体 SIGFPE rc=136）。

判据（本实例实跑）：≤16 与 >16 一律 **编译 + 运行值正确**（三路同证）；穷尽性/冗余臂的**真错**仍
定位硬错（TM03/TM04）；越界写类旧闸的**死亡证据** = 本批能力变更（旧 17-拒绝用例转正）。
"""

import os
import resource
import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"

# 退出码 = main 返回值低 8 位（见 test_slice_bounds.py 头注）⇒ 期望值一律 < 256。


def _no_core_dump():
    # core_pattern 为 systemd-coredump 管道时，崩溃的陷阱程序会挂起——禁用 core dump。
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def _write(source: str):
    fd, src = tempfile.mkstemp(suffix=".cr")
    with os.fdopen(fd, "w") as f:
        f.write(source)
    return src


def _cleanup(*paths):
    for p in paths:
        try:
            os.unlink(p)
        except FileNotFoundError:
            pass


def build_and_run(source: str):
    src = _write(source)
    out = src[:-3]
    try:
        built = subprocess.run(
            [str(COREC), "build", src, "-o", out, "--static"],
            capture_output=True, text=True, cwd=BASE, timeout=180,
        )
        if built.returncode != 0:
            return f"compile-failed(rc={built.returncode}): {built.stdout}{built.stderr}"
        return subprocess.run(
            [out], capture_output=True, text=True, timeout=10,
            preexec_fn=_no_core_dump,
        )
    finally:
        _cleanup(src, out, out + ".ccr")


def case_run(name, source, expect_rc):
    r = build_and_run(source)
    if isinstance(r, str):
        print(f"[FAIL] {name}: {r}")
        return False
    if r.returncode != expect_rc:
        print(f"[FAIL] {name}: expected rc {expect_rc}, got {r.returncode}")
        return False
    print(f"[PASS] {name}: rc={r.returncode}")
    return True


def case_reject(name, source, needles, cmd="build", forbid=()):
    """拒绝面：rc != 0 + 全部 needle 命中 + 无产物（bin 与 .ccr）+ 全部 forbid 缺席。

    **必须**同时断言 needle（定位诊断文本）——仅断言 rc != 0 会被「读回侧闸」式的兜底
    误当通过：修复前 build 面本来就 rc=1（`.ccr` 读回闸），而写入侧的静默面（check rc=0）
    与「越界写已发生」并不因此消失。
    forbid = 流水线阶段串（如 `save .ccr`）——钉「拒绝发生在**前端**（parse 阶段诊断闸，
    `main.cr` 的 `[3/5] parse...` 之后），**不进入** lower/写 .ccr/ELF」：护栏在读回侧
    （读回闸兜底）≠ 护栏在写入侧（TODO #35 的原话）。
    """
    src = _write(source)
    out = src[:-3]
    try:
        if cmd == "build":
            args = [str(COREC), "build", src, "-o", out, "--static"]
        else:
            args = [str(COREC), "check", src]
        r = subprocess.run(args, capture_output=True, text=True, cwd=BASE, timeout=180)
        blob = r.stdout + r.stderr
        if r.returncode == 0:
            print(f"[FAIL] {name}: expected rejection, got rc=0（静默面复活）: {blob}")
            return False
        for nd in needles:
            if nd not in blob:
                print(f"[FAIL] {name}: rc={r.returncode} 但缺诊断 {nd!r}: {blob}")
                return False
        for fd in forbid:
            if fd in blob:
                print(f"[FAIL] {name}: 拒绝晚于前端——输出含流水线阶段 {fd!r}（越界写已进入 IR/载体面）")
                return False
        if cmd == "build":
            for p in (out, out + ".ccr"):
                if os.path.exists(p):
                    print(f"[FAIL] {name}: 拒绝编译却仍产出 {p}")
                    return False
        print(f"[PASS] {name}: rc={r.returncode} + {needles} + 无产物")
        return True
    finally:
        _cleanup(src, out, out + ".ccr")


# ─── 语料构造 ───
def enum_src(n, extra="return 0"):
    """n 变体枚举 + main（`extra` = main 体）。"""
    vs = ", ".join(f"V{i}" for i in range(n))
    return f"enum E{n} {{ {vs} }}\nfn main() -> int {{ {extra}; }}\n"


def enum_exhaustive_src(n, pick):
    """n 变体枚举 + 全臂 match（返回被选变体下标 ⇒ 逐变体可判值正确）。"""
    vs = ", ".join(f"V{i}" for i in range(n))
    arms = ", ".join(f"V{i} => {i}" for i in range(n))
    return (f"enum E{n} {{ {vs} }}\n"
            f"fn main() -> int {{ x := V{pick}(); return match x {{ {arms}, }}; }}\n")


def enum_missing_arm_src(n):
    """n 变体枚举 + n-1 臂 match（缺最后一变体 ⇒ 真·非穷尽）。"""
    vs = ", ".join(f"V{i}" for i in range(n))
    arms = ", ".join(f"V{i} => {i}" for i in range(n - 1))
    return (f"enum E{n} {{ {vs} }}\n"
            f"fn main() -> int {{ x := V0(); return match x {{ {arms}, }}; }}\n")


def payload_src(n, extra="return 0"):
    ps = ", ".join("int" for _ in range(n))
    return f"enum P {{ A({ps}), B }}\nfn main() -> int {{ {extra}; }}\n"


def struct_src(n, extra="return 0"):
    fs = ", ".join(f"f{i}: int" for i in range(n))
    return f"struct S{n} {{ {fs} }}\nfn main() -> int {{ {extra}; }}\n"


def main():
    ok = [
        # ── 16 = 旧边界（含）：三面全对（回归钉）──
        case_run("enum16_exhaustive_ok", enum_exhaustive_src(16, 9), 9),
        case_run("enum16_decl_only_ok", enum_src(16), 0),
        case_run("payload16_ok", payload_src(16, "x := B(); return 4"), 4),
        case_run("struct16_ok",
                 struct_src(16, "s := S16 { " + ", ".join(f"f{i}: {i}" for i in range(16))
                            + " }; return s.f15"),
                 15),
        # ── >16（17/40）：旧 P022/P023 拒绝面的**转正**（死亡证据 = 侧表解除）──
        case_run("enum17_now_ok", enum_exhaustive_src(17, 13), 13),
        case_run("enum40_now_ok", enum_exhaustive_src(40, 33), 33),
        case_run("payload17_now_ok", payload_src(17, "x := A(1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17); return match x { A(a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12,a13,a14,a15,a16,a17) => { return a17; } B => { return 0; } }"), 17),
        case_run("struct17_now_ok",
                 struct_src(17, "s := S17 { " + ", ".join(f"f{i}: {i}" for i in range(17))
                            + " }; return s.f16"),
                 16),
        case_run("struct40_now_ok",
                 struct_src(40, "s := S40 { " + ", ".join(f"f{i}: {i}" for i in range(40))
                            + " }; return s.f39"),
                 39),
        # ── 跨记录完整性（侧表基址不重叠：宽记录 + 邻记录）──
        case_run("enum40_plus_small_ok",
                 enum_src(40, "v := V39(); return 0") + "enum F3 { X, Y, Z }\n"
                 "fn g() -> int { w := Z(); return match w { X => { return 1; } Y => { return 2; } Z => { return 3; } }; }\n", 0),
        # 记录碰撞敏感面（**判别性**）：大枚举之后声明小枚举 ⇒ 大枚举的**判定面**
        # （穷尽性）仍须正确（侧表基址不重叠的机器抓手）
        case_reject("enum40_then_small_missing_arm_rejected",
                    enum_src(40, "v := V0(); return 0") + "enum H4 { S, T, U }\n"
                    "fn hm(x: E40) -> int { return match x { "
                    + ", ".join(f"V{i} => {{ return {i}; }}" for i in range(39)) + " }; }\n",
                    ["error[TM03]", "missing variant 'V39'"], cmd="check"),
        case_run("enum40_then_small_then_match_big_ok",
                 enum_src(40, "v := V0(); return 0") + "enum H3 { S, T, U }\n"
                 "fn hm(x: E40) -> int { return match x { " + ", ".join(f"V{i} => {{ return {i}; }}" for i in range(40)) + " }; }\n"
                 "fn main3() -> int { return 0; }\n", 0),
        case_run("enum40_plus_small_match_ok",
                 enum_src(40, "v := V7(); return 0") + "enum G3 { P, Q, R }\n"
                 "fn gm(x: G3) -> int { return match x { P => { return 41; } Q => { return 42; } R => { return 43; } }; }\n"
                 "fn main2() -> int { return 0; }\n", 0),
        case_run("struct40_plus_pair_ok",
                 struct_src(40, "a := S40 { " + ", ".join(f"f{i}: {i}" for i in range(40)) + " }; return a.f39")
                 + "struct P2 { x: int, y: int }\n"
                 "fn h() -> int { p : ., mut = P2 { x: 7, y: 8 }; return p.y; }\n", 39),
        # ── 覆盖位无界（≥63 变体）：穷尽性判定仍正确 ──
        case_run("enum64_exhaustive_ok", enum_exhaustive_src(64, 63), 63 % 256),
        case_run("enum70_exhaustive_ok", enum_exhaustive_src(70, 69), 69),
        # ── 负控：覆盖位的**真错**仍定位硬错（TM03 缺臂 / TM04 冗余臂）──
        case_reject("enum64_missing_arm_rejected", enum_missing_arm_src(64),
                    ["error[TM03]", "missing variant 'V63'"], cmd="check"),
        case_reject("enum70_missing_arm_rejected", enum_missing_arm_src(70),
                    ["error[TM03]", "missing variant 'V69'"], cmd="check"),
    ]
    passed = sum(ok)
    print(f"{passed}/{len(ok)} passed")
    return 0 if passed == len(ok) else 1


if __name__ == "__main__":
    raise SystemExit(main())
