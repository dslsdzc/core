#!/usr/bin/env python3
"""R2 P2a Task 3（C-4）：侧表 ↔ res_type_node **管线内断言**（corec check --verify-named-dedup）。

背景（Task 1 交接必测项）：`f1.*` 自测用例是**人造夹具**（不经 check_all，手工 alloc + 单名查
行数）——证明不了「8 个生产分配点全走侧表」：任一生产点若退回裸 `alloc_type(TYP_NAMED, n, 0)`，
自测照样全绿，而真实编译中该名字会**占两行**（读名字的点仍对，比**行号**的点错——
`type_equal_legacy` 的 TYP_GENERIC_APPLY 基型比较即比行号）。本断言跑在真实流水线（check_all
之后）上，三组检查全部基于本编译期的真实类型表 / 符号表 / AST：

  ① 类型表 → 侧表：每个 TYP_NAMED 行按名查侧表须**命中且回指本行**；
  ② 侧表 → 类型表：每条登记须回指合法行（kind=TYP_NAMED、名字相符）且该名字**恰 1 行**；
  ③ 读取面：AST 中每个解析为已注册命名类型的 EXPR_IDENT，`res_type_node(node)` 须等于侧表
     命中 ti（替弱断言 f1.row_count 的那条）。

判据 = rc=0 ∧ `mismatches=0` ∧ `ident_checks>0`（非空转：至少真的检查到类型名引用）。
负控（注入故障）不在树内：需某生产点绕过侧表后**重建编译器**实测（输出 mismatches>0、rc=1），
见 .superpowers/sdd/r2p2-task-3-report.md 的 C-4 节。

需先重建自举编译器：nice -n 19 python3 build_selfhost_native.py
"""

import re
import subprocess
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"
# 语料 = at_test_struct.cr（brief 指定：结构体密集，命名类型注册 + 多处类型名引用）
CORPUS = BASE / "tests" / "suite" / "at_test_struct.cr"

SUMMARY = re.compile(
    r"\[named-dedup\] named_rows=(\d+) ident_checks=(\d+) mismatches=(\d+)"
)


def run_verify(corpus=CORPUS):
    return subprocess.run(
        ["nice", "-n", "19", str(COREC), "check", str(corpus), "--verify-named-dedup"],
        cwd=BASE, capture_output=True, text=True,
    )


def test_named_dedup_pipeline_assertion():
    r = run_verify()
    out = r.stdout + r.stderr
    m = SUMMARY.search(out)
    assert m, out
    named_rows, ident_checks, mismatches = (int(g) for g in m.groups())
    assert r.returncode == 0, (r.returncode, out)
    assert mismatches == 0, out
    # 非空转：至少检查到一个类型名引用节点（否则断言③恒真）
    assert ident_checks > 0, out
    assert named_rows > 0, out


if __name__ == "__main__":
    test_named_dedup_pipeline_assertion()
    print("PASS test_named_dedup_pipeline_assertion")
