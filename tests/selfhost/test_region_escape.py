#!/usr/bin/env python3
"""RegionCheck 三条逃逸检查的**真触发**判据（TODO #2026-09-20-1）。

修前状态（本套件的每颗正钉都在修前实测过，读数见下）：
  · 判定用了 `ni > alloc_exit`，而 SG 区间是半开 [NSTART, EXIT)、EXIT = 区域关闭后
    **第一个节点**的下标 ⇒ 「使用点紧跟区域」这一格被漏掉（最典型的逃逸形状）。
  · 判定把「任何区域关闭」当内存归还点 ⇒ `if` 分支内分配在分支后被误报 rc=1
    （运行期内存根本没释放，本套件的 R2 用 build+run 反证）。
  · pts 是流不敏感并集却当事实用 ⇒ 循环后重赋值给活指针再解引用被误报（R3）。
  · `rc_store_escape` 的判定值被整行丢弃（同行注 `// simplified check`）⇒ 存储逃逸
    检查从不可触发（P4 修前 rc=0）。
  · 返回逃逸误用 B011（应为 B010 = errors.md:245「Reference to local escapes the
    function」，例子即 `return &x`）。

**两向钉子**：每颗正钉断言到**具体错误码 + rc**，并各配一颗反向对照断言 rc=0；
反向对照覆盖 if 型 / 函数级返回型 / 重赋值型 / 循环内使用型四类。

**覆盖面的两条事实（新基 `84a4debe` 实测；勿据此加假钉）**：
  · 本基上 `&局部` 一律是 `TYP_REF`（#153 裁定二），且 `&局部 as *T`（REF→PTR cast）**本身即
    TF01** ⇒ 由 `&局部` **构造不出** `TYP_PTR` 的区域局部形状。**本套件的钉子实际走 REF 分支**；
    判定的 PTR 半边在当前基上对这一面是**惰性的**（并集保留，PTR 侧对 alloc()/FFI 派生值有效）。
    **不得为凑 PTR 形状编造钉子** —— 凑出来的会是假钉。
  · `fn ... -> *int { …; return &arr[0]; }` 在本基上是 **TF01（返回型不符）**，**基线与本批都是**，
    与逃逸面无关（连 `&seed as *int` 亦然）⇒ 钉子的返回型写 `&int`。

运行面 = `ccr`（region_check 在 `check` 面早退 —— main.cr:458-460 在 IR 生成前返回
⇒ 旧 `test_region_cfg.py::test_region_check_pointer_escape` 走的 `check` 面根本不经过
本 pass，其断言只能靠 `or 'error'` 兜底通过，不是钉子）。
"""

import os
import resource
import subprocess
import tempfile


BASE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _no_core_dump():
    # 陷阱程序（SIGILL）在 core_pattern 为 systemd-coredump 管道时会挂起
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def compile_ccr(src: str):
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as source:
        source.write(src)
        source_path = source.name
    output_path = os.path.splitext(source_path)[0] + ".ccr"
    try:
        result = subprocess.run(
            ["./build/corec", "ccr", source_path, "-o", output_path],
            capture_output=True, text=True, cwd=BASE, timeout=60,
        )
        return result, os.path.exists(output_path)
    finally:
        for path in (source_path, output_path):
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass


def assert_rejected(src: str, code: str, needle: str):
    result, artifact = compile_ccr(src)
    output = result.stdout + result.stderr
    assert result.returncode != 0, f"expected rejection, got success:\n{output}"
    assert code in output, f"expected {code!r} in diagnostic:\n{output}"
    assert needle in output, f"expected {needle!r} in diagnostic:\n{output}"
    assert not artifact, f"rejected program still produced an artifact:\n{output}"


def assert_accepted(src: str):
    result, _ = compile_ccr(src)
    output = result.stdout + result.stderr
    assert result.returncode == 0, f"expected success, got {result.returncode}:\n{output}"


def build_and_run(src: str, expect_rc: int = 0):
    """反向对照的运行期腿：被判「合法」的程序必须真的跑出预期结果。"""
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as source:
        source.write(src)
        source_path = source.name
    output_path = os.path.splitext(source_path)[0]
    try:
        build = subprocess.run(
            ["./build/corec", "build", source_path, "-o", output_path, "--static"],
            capture_output=True, text=True, cwd=BASE, timeout=180,
        )
        assert build.returncode == 0, (
            f"native build failed with {build.returncode}:\n"
            f"{build.stdout}{build.stderr}"
        )
        os.chmod(output_path, 0o755)
        run = subprocess.run(
            [output_path], capture_output=True, text=True, cwd=BASE, timeout=10,
            preexec_fn=_no_core_dump,
        )
        assert run.returncode == expect_rc, (
            f"expected runtime rc={expect_rc}, got {run.returncode} "
            f"stdout={run.stdout!r} stderr={run.stderr!r}"
        )
    finally:
        for path in (source_path, output_path, output_path + ".ccr"):
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass


# ── 正钉：必须触发，断言具体码 ────────────────────────────────────────────

def test_p1_loop_alloc_deref_immediately_after_loop():
    """P1 边界格：循环内分配 → 循环后**紧邻**解引用（修前 rc=0 静默通过）。"""
    assert_rejected(
        "fn main() -> int {\n"
        "    seed := 0;\n"
        "    p : ., mut = &seed;\n"
        "    i : ., mut = 0;\n"
        "    while i < 1 {\n"
        "        arr := [7, 8];\n"
        "        p = &arr[0];\n"
        "        i = i + 1;\n"
        "    }\n"
        "    return *p;\n"
        "}\n",
        "error[B11]", "dangling pointer",
    )


def test_p2_loop_alloc_deref_after_intervening_stmt():
    """P2 修前已能触发的格（隔一条语句）——防「改边界把老格弄丢」。"""
    assert_rejected(
        "fn main() -> int {\n"
        "    seed := 0;\n"
        "    p : ., mut = &seed;\n"
        "    i : ., mut = 0;\n"
        "    while i < 1 {\n"
        "        arr := [7, 8];\n"
        "        p = &arr[0];\n"
        "        i = i + 1;\n"
        "    }\n"
        "    k := 1;\n"
        "    k = k + 1;\n"
        "    return *p;\n"
        "}\n",
        "error[B11]", "dangling pointer",
    )


def test_p3_return_escape_is_b010():
    """P3 返回逃逸：码必须是 B10（EC_B_ESCAPE）。

    ⚠ 形态说明（新基 84a4debe 起）：`&local` 经 #153 改判 `TYP_REF` ⇒
    `fn ... -> *int { ...; return &arr[0]; }` 在本基上是 **TF01（返回型不符）**，
    与逃逸面无关（基线与本批**都是** TF01，已实测）。故本钉写 `-> &int`。
    旧基（38e6c992）读数：同形 `-> *int` 版 = rc=1 但报 **B11**（码位错配）；
    新基线（仅 S6）= rc=0（只放宽 kind 不足以触发，边界缺陷仍在）。"""
    assert_rejected(
        "fn make() -> &int {\n"
        "    seed := 0;\n"
        "    r : ., mut = &seed;\n"
        "    i : ., mut = 0;\n"
        "    while i < 1 {\n"
        "        arr := [7, 8];\n"
        "        r = &arr[0];\n"
        "        i = i + 1;\n"
        "    }\n"
        "    return r;\n"
        "}\n"
        "fn main() -> int {\n"
        "    return 0;\n"
        "}\n",
        "error[B10]", "region escape: returning pointer",
    )


def test_p4_store_escape_now_reachable():
    """P4 存储逃逸：修前判定值被整行丢弃 ⇒ 本形态 rc=0（检查从不触发）。"""
    assert_rejected(
        "fn main() -> int {\n"
        "    seed := 0;\n"
        "    slot : ., mut = &seed;\n"
        "    slotp := &slot;\n"
        "    p : ., mut = &seed;\n"
        "    i : ., mut = 0;\n"
        "    while i < 1 {\n"
        "        arr := [7, 8];\n"
        "        p = &arr[0];\n"
        "        i = i + 1;\n"
        "    }\n"
        "    *slotp = p;\n"
        "    return 0;\n"
        "}\n",
        "error[B11]", "store escape: storing pointer",
    )


def test_p5_alloc_inside_if_inside_loop_escapes_loop():
    """P5 父链上溯：分配在 if 内、循环内 —— 归还它的是**循环**区（不是 if 区）。"""
    assert_rejected(
        "fn main() -> int {\n"
        "    seed := 0;\n"
        "    p : ., mut = &seed;\n"
        "    cond := 1;\n"
        "    i : ., mut = 0;\n"
        "    while i < 1 {\n"
        "        if cond == 1 {\n"
        "            arr := [7, 8];\n"
        "            p = &arr[0];\n"
        "        }\n"
        "        i = i + 1;\n"
        "    }\n"
        "    k := 1;\n"
        "    k = k + 1;\n"
        "    return *p;\n"
        "}\n",
        "error[B11]", "dangling pointer",
    )


def test_p6_reassign_to_another_dead_pointer_still_reports():
    """P6 重赋值清除规则的**负控**：重赋的值本身也是死指针 ⇒ 不得清除、必须报。"""
    assert_rejected(
        "fn main() -> int {\n"
        "    seed := 0;\n"
        "    p : ., mut = &seed;\n"
        "    q : ., mut = &seed;\n"
        "    i : ., mut = 0;\n"
        "    while i < 1 {\n"
        "        arr := [7, 8];\n"
        "        q = &arr[0];\n"
        "        i = i + 1;\n"
        "    }\n"
        "    i = 0;\n"
        "    while i < 1 {\n"
        "        arr2 := [9, 9];\n"
        "        p = &arr2[0];\n"
        "        i = i + 1;\n"
        "    }\n"
        "    p = q;\n"
        "    return *p;\n"
        "}\n",
        "error[B11]", "dangling pointer",
    )


def test_p7_build_face_is_hard_error_with_zero_artifact():
    """build 面同判：硬错 rc=1 且零产物（诊断不得只记录不拦截）。"""
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as source:
        source.write(
            "fn main() -> int {\n"
            "    seed := 0;\n"
            "    p : ., mut = &seed;\n"
            "    i : ., mut = 0;\n"
            "    while i < 1 {\n"
            "        arr := [7, 8];\n"
            "        p = &arr[0];\n"
            "        i = i + 1;\n"
            "    }\n"
            "    return *p;\n"
            "}\n"
        )
        source_path = source.name
    output_path = os.path.splitext(source_path)[0]
    try:
        result = subprocess.run(
            ["./build/corec", "build", source_path, "-o", output_path, "--static"],
            capture_output=True, text=True, cwd=BASE, timeout=180,
        )
        output = result.stdout + result.stderr
        assert result.returncode != 0, f"expected rejection, got success:\n{output}"
        assert "error[B11]" in output, f"expected error[B11] in diagnostic:\n{output}"
        assert not os.path.exists(output_path), "rejected build produced an artifact"
        assert not os.path.exists(output_path + ".ccr"), "rejected build left a .ccr"
    finally:
        for path in (source_path, output_path, output_path + ".ccr"):
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass


# ── `&x`（TYP_REF）路径钉子：与 S6 的扩谓词正交（PR #153 同批并入）──────
# #153 的 S6 把本文件三处 kind 谓词从 `TYP_PTR` 放宽为 `TYP_PTR ∪ TYP_REF`（裁定二把
# `&x` 改判 REF）。本批抽单源后该放宽**收敛为 rc_var_dead 一处**；以下两钉走的就是
# 那条路——**基线（`84a4debe`，仅 S6）实测 rc=0**（只放宽 kind 不足以触发，边界缺陷
# 仍在）；本批实测 rc=1 + 具体码 ⇒ 证明 REF 值走的是**修好的判定**，而不是被 S6 放宽
# 后绕过去的另一条路。第三钉是它的反向对照。

def test_p9_ref_typed_dangling_deref_is_b011():
    """P9 同上但循环后解引用 ⇒ B11（REF 型走悬垂 DEREF 判定）。基线 rc=0。"""
    assert_rejected(
        "fn main() -> int {\n"
        "    seed := 0;\n"
        "    r : ., mut = &seed;\n"
        "    i : ., mut = 0;\n"
        "    while i < 1 {\n"
        "        arr := [7, 8];\n"
        "        r = &arr[0];\n"
        "        i = i + 1;\n"
        "    }\n"
        "    return *r;\n"
        "}\n",
        "error[B11]", "dangling pointer",
    )


# ── 反向对照：必须保持 rc=0（否则「一律报」会让正钉全绿）─────────────────

def test_r1_function_level_alloc_may_be_returned():
    """R1 函数级返回型：SG_FUNC 分配返回给调用者合法（不属任何归还区）。

    形态同 P3 说明：本基上 `&local` 是 `TYP_REF`，`-> *int` 版是 TF01（与逃逸面无关）
    ⇒ 返回型写 `&int`。"""
    assert_accepted(
        "fn make() -> &int {\n"
        "    arr := [7, 8];\n"
        "    k := 1;\n"
        "    k = k + 1;\n"
        "    return &arr[0];\n"
        "}\n"
        "fn main() -> int {\n"
        "    return 0;\n"
        "}\n"
    )


def test_r2_if_branch_alloc_is_not_released_at_branch_end():
    """R2 if 型：EXPR_IF 只 sg_push/sg_pop、**不建 arena**（ir_gen.cr:2414/2437）
    ⇒ 分支后解引用合法。修前被误报 rc=1（本对照 = 修前实测的红态反例）。"""
    src = (
        "fn main() -> int {\n"
        "    seed := 0;\n"
        "    p : ., mut = &seed;\n"
        "    x := 1;\n"
        "    if x == 1 {\n"
        "        arr := [7, 8];\n"
        "        p = &arr[0];\n"
        "    }\n"
        "    k := 1;\n"
        "    k = k + 1;\n"
        "    return *p - 7;\n"
        "}\n"
    )
    assert_accepted(src)
    # 运行期反证：内存确实没被归还 —— 读回的仍是 7（返回 0）。
    build_and_run(src, expect_rc=0)


def test_r3_reassign_to_live_pointer_after_loop():
    """R3 重赋值型：循环后改指活对象，解引用合法（pts 流不敏感并集不得当事实用）。"""
    src = (
        "fn main() -> int {\n"
        "    seed := 5;\n"
        "    p : ., mut = &seed;\n"
        "    i : ., mut = 0;\n"
        "    while i < 1 {\n"
        "        arr := [7, 8];\n"
        "        p = &arr[0];\n"
        "        i = i + 1;\n"
        "    }\n"
        "    p = &seed;\n"
        "    k := 1;\n"
        "    k = k + 1;\n"
        "    return *p - 5;\n"
        "}\n"
    )
    assert_accepted(src)
    build_and_run(src, expect_rc=0)


def test_r4_use_inside_the_loop_stays_clean():
    """R4 循环内使用型：分配在循环内、使用也在循环内 ⇒ 合法。"""
    src = (
        "fn main() -> int {\n"
        "    s : ., mut = 0;\n"
        "    i : ., mut = 0;\n"
        "    while i < 1 {\n"
        "        arr := [7, 8];\n"
        "        p := &arr[0];\n"
        "        s = s + *p;\n"
        "        i = i + 1;\n"
        "    }\n"
        "    return s - 7;\n"
        "}\n"
    )
    assert_accepted(src)
    build_and_run(src, expect_rc=0)


def test_r5_deref_loaded_int_is_not_pointer_escape():
    """R5 非指针面：deref 读出的 int 是普通数据，不做逃逸判定（既有回归钉子）。"""
    assert_accepted(
        "fn main() -> int {\n"
        "    value := 42;\n"
        "    pointer := &value;\n"
        "    loaded := *pointer;\n"
        "    return loaded;\n"
        "}\n"
    )


def test_r6_store_of_live_pointer_stays_clean():
    """R6 存储逃逸反向对照：存入的指针仍活着 ⇒ 不得报（防存储检查「一律报」）。"""
    assert_accepted(
        "fn main() -> int {\n"
        "    seed := 0;\n"
        "    slot : ., mut = &seed;\n"
        "    slotp := &slot;\n"
        "    p : ., mut = &seed;\n"
        "    i : ., mut = 0;\n"
        "    while i < 1 {\n"
        "        i = i + 1;\n"
        "    }\n"
        "    k := 1;\n"
        "    k = k + 1;\n"
        "    p = &seed;\n"
        "    *slotp = p;\n"
        "    return 0;\n"
        "}\n"
    )


def test_r7_loop_without_heap_alloc_stays_clean():
    """R7 无堆分配面：循环内只有标量槽（IR_ALLOC 不参与 pts）⇒ 不得报。"""
    assert_accepted(
        "fn main() -> int {\n"
        "    s : ., mut = 0;\n"
        "    i : ., mut = 0;\n"
        "    while i < 3 {\n"
        "        t := i + 1;\n"
        "        s = s + t;\n"
        "        i = i + 1;\n"
        "    }\n"
        "    return s - 6;\n"
        "}\n"
    )


if __name__ == "__main__":
    tests = [
        test_p1_loop_alloc_deref_immediately_after_loop,
        test_p2_loop_alloc_deref_after_intervening_stmt,
        test_p3_return_escape_is_b010,
        test_p4_store_escape_now_reachable,
        test_p5_alloc_inside_if_inside_loop_escapes_loop,
        test_p6_reassign_to_another_dead_pointer_still_reports,
        test_p7_build_face_is_hard_error_with_zero_artifact,
        test_p9_ref_typed_dangling_deref_is_b011,
        test_r1_function_level_alloc_may_be_returned,
        test_r2_if_branch_alloc_is_not_released_at_branch_end,
        test_r3_reassign_to_live_pointer_after_loop,
        test_r4_use_inside_the_loop_stays_clean,
        test_r5_deref_loaded_int_is_not_pointer_escape,
        test_r6_store_of_live_pointer_stays_clean,
        test_r7_loop_without_heap_alloc_stays_clean,
    ]
    failures = 0
    for test in tests:
        try:
            test()
            print(f"PASS {test.__name__}")
        except AssertionError as error:
            failures += 1
            print(f"FAIL {test.__name__}: {error}")
        except Exception as error:  # noqa: BLE001
            failures += 1
            print(f"ERROR {test.__name__}: {error!r}")
    print(f"{len(tests) - failures}/{len(tests)} passed")
    raise SystemExit(1 if failures else 0)
