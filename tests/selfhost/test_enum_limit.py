#!/usr/bin/env python3
"""TODO #35 回归：枚举变体/载荷与结构体字段**写入侧无界**（R2 P4 Task 6 修复）。

背景（RED，修复前实测——三档探针，二进制 = P4 Task 5 收官 `2be26cc5`）：
  * 机制（代码级）：`EnumVariant` 槽区（`MAX_ENUM_VARIANTS=16` 槽 × `OFF_EV_SIZE=272`）与
    `StructInfo` 字段槽区（`MAX_STRUCT_FIELDS=16` 槽）是**定长内嵌槽区**——其后紧跟记录自身
    的 count/generic 槽，再往后是**下一条记录**（同一 buffer）。parser 的写入循环对下标
    `vc`/`tc`/`fc` **零上限闸** ⇒ 「第 17 个」不再属于本记录：
      - 第 17 变体的槽起点 = `OFF_EI_VARIANT_COUNT`（4360 = 8 + 16×272）**自身**，槽尾越过
        `ESZ_ENUMINFO`（4408）**224B**（踩邻记录 / 缓冲区尾部——`grow_enums` 的扩容余量使
        该越界多数落在 buffer 内部＝**静默**，无 SIGSEGV 可观测）；
      - 第 17 个载荷类型写 `OFF_EV_TYPES+16×8 = 136 = OFF_EV_TYPE_COUNT`；第 17 个载荷
        **节点**写 `OFF_EV_TYPE_NODES+16×8 = 272 = OFF_EV_SIZE`（下一变体槽首）。
  * 静默面（修复前实测，三例）：
      ① `enum E17 { V0..V16 }` 声明体 = `check` **rc=0 零诊断**（写入侧越界写完全静默）；
      ② 同一枚举上的 `match` **穷尽性判定被静默禁用**——第 17 变体名槽存的是被 count 覆盖
         的值 ⇒ 「名→变体项」映射失败 ⇒ 域不可展开 ⇒ 三态回落 -1「不判」⇒ 真·非穷尽
         match（补 16 臂、缺 V16）也 **rc=0 零诊断**（对照：16 变体枚举同形必报 TM03）；
      ③ 第 17 变体**不可构造**：`V16()` ⇒ 「Undefined enum constructor 'V16'」（假诊断）。
  * `build` 面：修复前靠 `.ccr` **读回侧**闸兜底（`ccr_io.cr` 的 `vc > MAX_ENUM_VARIANTS` ⇒
    rc=1）——但**写入已在读回闸之前发生**（护栏在读回侧 ≠ 写入侧；读回闸拦不住进程内的
    越界写与其全部前端后果）。

修复（照 TODO #8 收口形态）：① parser 写入点跳过超限槽 + 末尾 `error[P022]`（枚举变体/
载荷）/`error[P023]`（结构体字段）**定位硬错**——由 **parse 阶段诊断闸**（`main.cr` 的
`[3/5] parse...` 之后 `g_diag_count > 0 ⇒ rc=1`，与 P019/P020/P021 同款）拒绝 ⇒ 发生在
**前端**，不进入 lower/写 .ccr/ELF 阶段，**非静默截断**（实测：hard 名单条目对本族**冗余**
——删条目零行为差异，见报告 §突变控制）；② `dyn_arr.cr` 受护访问器（`ei_set_variant_*`/
`si_set_field_*` 写护栏 + `ei_variant_*`/`si_field_*` 读护栏回哨兵）= 未来新调用点亦不可能
越界（读护栏使 count 保持真值仍不越读：`vi ≥ 16 ⇒ 名字/类型节点 -1、计数 0`）。

判据：16（含）以内三面全对（check rc=0 / build rc=0 / 运行值正确）；17 ⇒ 定位硬错 rc=1 +
无产物（bin 与 .ccr 皆无）。
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
        # ── 上界内（16 = 边界值，含）三面全对 ──
        case_run("enum16_exhaustive_ok", enum_exhaustive_src(16, 9), 9),
        case_run("enum16_decl_only_ok", enum_src(16), 0),
        # 两条枚举相邻（跨记录写入的正控：≤16 时邻记录零扰动）
        case_run("enum16_two_enums_ok",
                 enum_src(16, "return 0") + "enum F3 { X, Y, Z }\n"
                 "fn g() -> int { v := Y(); return 2; }\n", 0),
        case_run("payload16_ok", payload_src(16, "x := B(); return 4"), 4),
        # 16 字段结构体 + 全字段字面量（声明序）+ 末字段读取
        case_run("struct16_ok",
                 struct_src(16, "s := S16 { " + ", ".join(f"f{i}: {i}" for i in range(16))
                            + " }; return s.f15"),
                 15),
        # ── 上界外（17）⇒ 定位硬错 + 无产物 ──
        # ① 枚举变体：修复前 check rc=0 零诊断（写入侧静默）
        case_reject("enum17_check_rejected", enum_src(17), ["error[P22]", "too many variants (17 > 16)"],
                    cmd="check"),
        # ② 修复前 build 面虽 rc=1，但那是**读回侧**闸；本用例断言写入侧定位诊断在场 +
        #    拒绝发生在**前端**（不进入 lower/写 .ccr/ELF 阶段）
        case_reject("enum17_build_rejected", enum_src(17),
                    ["error[P22]", "too many variants (17 > 16)"],
                    forbid=("lower to ccr", "save .ccr", "generate ELF")),
        # ③ 静默禁用穷尽性判定的回归钉：真·非穷尽 match（缺 V16）修复前 rc=0 零诊断
        case_reject("enum17_match_not_silently_accepted", enum_missing_arm_src(17),
                    ["error[P22]"], cmd="check"),
        # ④ 第 17 变体假诊断面（修复前 `V16()` ⇒ 「Undefined enum constructor」，P22 缺位）
        case_reject("enum17_use_rejected",
                    enum_src(17, "x := V16(); return 0"), ["error[P22]"], cmd="check"),
        # ⑤ 载荷类型：修复前 check rc=0；第 17 个写 count 槽 / 第 17 节点写下一槽首
        case_reject("payload17_rejected", payload_src(17),
                    ["error[P22]", "payload types (17 > 16)"]),
        case_reject("payload17_check_rejected", payload_src(17), ["error[P22]"], cmd="check"),
        # ⑥ 结构体字段：修复前 check rc=0（第 17 字段踩 field_count/泛型槽与邻记录）
        case_reject("struct17_check_rejected", struct_src(17), ["error[P23]", "too many fields (17 > 16)"],
                    cmd="check"),
        case_reject("struct17_build_rejected", struct_src(17), ["error[P23]"],
                    forbid=("lower to ccr", "save .ccr", "generate ELF")),
    ]
    passed = sum(ok)
    print(f"{passed}/{len(ok)} passed")
    return 0 if passed == len(ok) else 1


if __name__ == "__main__":
    raise SystemExit(main())
