#!/usr/bin/env python3
"""R2 P5 Task 3 回归：命名面判定化（身份链 + 可判定面加强）行为覆盖集。

背景（RED，见 .superpowers/sdd/p5-task3-report.md §RED）：命名型（struct/enum/接口行、
泛型形参、泛型应用）在判定引擎里原本**一律未覆盖**（AK_NAMED 原子不展开 ⇒ `ty_equiv` 回
-1）⇒ 判定回落 legacy（`g_replace_unknown`）：
  * 异名同形命名型（`NA` vs `NB`）= 引擎 -1 + 回落 1（legacy 判 0 = 拒）；
  * 同实参泛型应用两次实例化（`Box[int]` 两处 = **两行**）= 引擎 -1 + 回落 1（legacy 判 1
    = 受）。
本任务把**可判定**的命名面接进引擎：身份 = 桥接层构造的**身份链**（`[名字令牌]` /
`[基名令牌, 实参项…]`），规则 = 同链 ⇒ 1 / 链异且链元素在域内 ⇒ 0 / 域外 ⇒ -1（三态纪律）。
**不是**结构性展开（P3a 实测反证：展开项接进等价面 = 同形不同名 struct 判等）。

判据（本套件 = **行为断言形态**：只读 rc + 诊断 + 产物执行结果，**不依赖影子通道**——
影子层下线（P5 Task 5）后本套件照常可跑）：
  ① **受**（rc=0 + ELF 执行 rc=0）：同名命名互赋 / 泛型应用两次实例化（同实参）/ 嵌套应用 /
     容器与元组含命名（同名）/ 递归命名（*Node）/ 泛型形参 T vs T / 别名一层（透明）
  ② **拒**（rc=1 + 具体诊断 + 无产物）：异名同形命名 / 异实参泛型应用 / 命名 vs 原生 /
     命名 vs 泛型应用 / 可选含命名（异名）/ 泛型形参 T 赋 int
  ③ **行为同值**：以上受/拒集合与 legacy 口径逐条相同（清零 ≠ 放宽，也 ≠ 收紧）——
     判据面 = rc/诊断/产物；清零的**计数证据**（回落归零）在报告与自测段（`t3n.*`）。
  ④ **残留面**（计划停条件②）：参数链**不变槽**元素非同形（`[NA;2]` vs `[NB;2]`、
     `*NA` vs `*NB`、元组含异名）——T3 时仍走 legacy 判定 + 回落（**行为已正确** = 拒），
     **P5 Task 3b 已收口**（`te_elem_cmp` 三态：令牌按节点同一性 / 类型项按 `ty_equiv`）
     ⇒ 本套件只钉行为（清零后不得变成接受）；T4 已把 legacy 与回落面删除。

运行：`python3 tests/selfhost/test_named_face.py`（cwd = 仓库根；需先构建 build/corec）。
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


def _write(source):
    fd, src = tempfile.mkstemp(suffix=".cr")
    with os.fdopen(fd, "w") as f:
        f.write(source)
    return src, src[:-3]


def _cleanup(*paths):
    for p in paths:
        try:
            os.unlink(p)
        except FileNotFoundError:
            pass


def case_accept(name, source):
    """受：ELF 编译 rc=0 ∧ 执行 rc=0（前端 + 发射 + 运行三面同证）。"""
    src, out = _write(source)
    try:
        built = subprocess.run(
            [str(COREC), "build", src, "-o", out, "--static"],
            capture_output=True, text=True, cwd=BASE, timeout=180,
        )
        if built.returncode != 0:
            print(f"[FAIL] {name}: compile rc={built.returncode}: {built.stdout}{built.stderr}")
            return False
        run = subprocess.run([out], capture_output=True, text=True, timeout=10,
                             preexec_fn=_no_core_dump)
        if run.returncode != 0:
            print(f"[FAIL] {name}: run rc={run.returncode}（受却运行失败）")
            return False
        print(f"[PASS] {name}: compile+run rc=0")
        return True
    finally:
        _cleanup(src, out, out + ".ccr")


def case_reject(name, source, needle):
    """拒：`check` rc≠0 ∧ 诊断含 needle；且 `build` 面同诊断在册（发射面同为拒绝语义）。

    注（预存行为，非本任务引入，登记于 P5 Task 3 报告）：TA01 这类**非硬名单**诊断不阻
    `build`（`main.cr` 的硬名单闸只收 R002/TK05/06/TS*/TK02/TM03；实测冻结基线同）——故本
    套件以 `check` 的 rc 为判据（= 项目判据面口径），并断言 build 面诊断文本同现。
    """
    src, out = _write(source)
    try:
        chk = subprocess.run(
            [str(COREC), "check", src],
            capture_output=True, text=True, cwd=BASE, timeout=180,
        )
        if chk.returncode == 0:
            print(f"[FAIL] {name}: check 期望拒绝却 rc=0（静默误编译面复活）")
            return False
        if needle not in (chk.stdout + chk.stderr):
            print(f"[FAIL] {name}: rc={chk.returncode} 但缺诊断 {needle!r}: {chk.stdout}{chk.stderr}")
            return False
        built = subprocess.run(
            [str(COREC), "build", src, "-o", out, "--static"],
            capture_output=True, text=True, cwd=BASE, timeout=180,
        )
        if needle not in (built.stdout + built.stderr):
            print(f"[FAIL] {name}: build 面缺同诊断（判定未在发射面同现）")
            return False
        print(f"[PASS] {name}: check rc={chk.returncode} + {needle!r} + build 面同证")
        return True
    finally:
        _cleanup(src, out, out + ".ccr")


TA01 = "Assignment type mismatch"

NA_NB = "struct NA { x: int }\nstruct NB { x: int }\n"
BOX = "struct Box[T] { v: T }\n"


def main():
    ok = [
        # ── ① 受：命名面同链（身份链逐元素同 ⇒ 1）──
        case_accept("named.same_name_assign", NA_NB.replace("struct NB { x: int }\n", "") +
                    "fn main() -> int {\n"
                    "    a : ., mut = NA { x: 1 };\n"
                    "    b : ., mut = NA { x: 2 };\n"
                    "    a = b;\n"
                    "    return a.x - 2;\n"
                    "}\n"),
        # 泛型应用两次实例化（**两行**同实参）——RED 形态之一，修复前 = 引擎 -1 + 回落。
        # 形参位声明（应用行随每处出现各分配一行）。注：`Box[int] { … }` 字面量形态在本
        # 语言 parser 下不可解析（P01，冻结基线同——预存面，见 T0 探针 d3 变体），故走形参位。
        case_accept("apply.two_instantiations_same_args", BOX +
                    "fn g(a: Box[int], b: Box[int]) -> int {\n"
                    "    a = b;\n"
                    "    return a.v - b.v;\n"
                    "}\n"
                    "fn main() -> int { return 0; }\n"),
        # 嵌套泛型应用（外层实参 = 内层应用，两处**不同行**同实参）⇒ 规范形 ⇒ 同节点
        case_accept("apply.nested_same_args", BOX +
                    "fn g(a: Box[Box[int]], b: Box[Box[int]]) -> int { a = b; return 0; }\n"
                    "fn main() -> int { return 0; }\n"),
        # 泛型应用实参含命名型（同链）
        case_accept("apply.named_arg_same", NA_NB + BOX +
                    "fn g(a: Box[NA], b: Box[NA]) -> int { a = b; return 0; }\n"
                    "fn main() -> int { return 0; }\n"),
        # 容器/元组/指针含命名（同元素）——b 槽标注不入身份 + 同链
        case_accept("named.in_container_same", NA_NB.replace("struct NB { x: int }\n", "") +
                    "fn main() -> int {\n"
                    "    a : [NA; 2] = [NA { x: 1 }, NA { x: 2 }];\n"
                    "    b : [NA; 2] = [NA { x: 3 }, NA { x: 4 }];\n"
                    "    c : NA? = NA { x: 5 };\n"
                    "    d : NA? = NA { x: 6 };\n"
                    "    p : *NA = 0;\n"
                    "    q : *NA = 0;\n"
                    "    a = b; c = d; p = q;\n"
                    "    return 0;\n"
                    "}\n"),
        case_accept("named.in_tuple_same", NA_NB.replace("struct NB { x: int }\n", "") +
                    "fn main() -> int {\n"
                    "    a : ., mut = (NA { x: 1 }, 2);\n"
                    "    b : ., mut = (NA { x: 3 }, 4);\n"
                    "    a = b;\n"
                    "    return 0;\n"
                    "}\n"),
        # 递归命名（*Node 元素位 = 命名行，同链）
        case_accept("named.recursive_ptr_same", "struct Node { val: int, next: *Node }\n"
                    "fn f(p: *Node, q: *Node) -> int { p = q; return 0; }\n"
                    "fn main() -> int { return 0; }\n"),
        # 泛型形参位 T vs T（同链：同一形参行）
        case_accept("named.generic_param_same", "fn pick[T](a: T, b: T) -> int { return 0; }\n"
                    "fn main() -> int { return pick(1, 2); }\n"),
        # 别名一层：透明（alias 解析到 RHS 行，不产生命名行身份）
        case_accept("named.alias_transparent", "type X = int;\n"
                    "fn main() -> int { a : X = 1; b : int = 2; a = b; return a - 2; }\n"),
        # 命名型经函数边界（形参/返回位同链）
        case_accept("named.fn_boundary", NA_NB.replace("struct NB { x: int }\n", "") +
                    "fn take(v: NA) -> int { return v.x; }\n"
                    "fn main() -> int { a : ., mut = NA { x: 7 }; b : ., mut = NA { x: 7 }; a = b; return take(a) - 7; }\n"),
        # ── ② 拒：链异 ⇒ 0（= legacy 拒；清零前的回落面）──
        case_reject("named.diff_name_rejected", NA_NB +
                    "fn main() -> int { a : ., mut = NA { x: 1 }; b : ., mut = NB { x: 2 }; a = b; return a.x; }\n", TA01),
        case_reject("apply.diff_args_rejected", BOX +
                    "fn g(a: Box[int], b: Box[str]) -> int { a = b; return a.v; }\n"
                    "fn main() -> int { return 0; }\n", TA01),
        case_reject("named.vs_base_rejected", "struct NA { x: int }\n"
                    "fn main() -> int { a : NA = NA { x: 1 }; b : int = 2; a = b; return a.x; }\n", TA01),
        case_reject("named.vs_apply_rejected", NA_NB + BOX +
                    "fn g(a: Box[NA], b: Box[int]) -> int { a = b; return 0; }\n"
                    "fn main() -> int { return 0; }\n", TA01),
        case_reject("named.optional_diff_rejected", NA_NB +
                    "fn main() -> int { a : NA? = NA { x: 1 }; b : NB? = NB { x: 2 }; a = b; return 0; }\n", TA01),
        case_reject("named.generic_param_vs_int_rejected",
                    "fn h[T](a: T, b: int) -> int { a = b; return 0; }\n"
                    "fn main() -> int { return h(1, 2); }\n", TA01),
        # ── ③ 残留登记（停条件②面：不变槽元素非同形——行为已正确，本任务不动其清零）──
        case_reject("residual.invariant_slot_arr_rejected", NA_NB +
                    "fn main() -> int {\n"
                    "    a : [NA; 2] = [NA { x: 1 }, NA { x: 2 }];\n"
                    "    b : [NB; 2] = [NB { x: 3 }, NB { x: 4 }];\n"
                    "    a = b;\n"
                    "    return 0;\n"
                    "}\n", TA01),
        case_reject("residual.invariant_slot_ptr_rejected", NA_NB +
                    "fn g(a: *NA, b: *NB) -> int { a = b; return 0; }\n"
                    "fn main() -> int { return 0; }\n", TA01),
    ]
    passed = sum(ok)
    print(f"{passed}/{len(ok)} passed")
    return 0 if passed == len(ok) else 1


if __name__ == "__main__":
    raise SystemExit(main())
