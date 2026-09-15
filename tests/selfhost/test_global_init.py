#!/usr/bin/env python3
"""File-scope global initializer semantics — dual path (interpreter + native ELF).

R1 Task 4 判据（语言面收窄 §1.3 / R1 ②）：文件级全局的运行期初始化在两条路径上
语义一致——
  ① 聚合全局（`[T; N]`）无论有无初值都在运行期分配存储并写槽（存储持久）；
  ② 非常量初值的全局在运行期求值并写槽；
  ③ 编译期标量常量初始化（ELF `_start` 常量环 / 解释器初始化阶段）两路径一致。

每例两条断言：编译/执行输出无 `error[` 诊断 + 退出码精确值。
两路径都跑：`corec run`（解释器）与 `corec build --static` + 运行 ELF。

注意：ELF 路径走 per-function cir 增量缓存（.core/cache/cir/），缓存键不含编译器
身份（TODO #5）——本脚本在开跑前清一次缓存，保证判据跑在当次构建的编译器上。
"""

import os
import subprocess
from pathlib import Path


BASE = Path(__file__).resolve().parents[2]
BUILD = BASE / "build"
COREC = BUILD / "corec"

# (name, source, expected rc)
CASES = [
    (
        "array_global_literal",
        "g : [int;2] = [8,9];\nfn main()->int{return g[1];}",
        9,
    ),
    (
        "array_global_no_init",
        "g : [int;2];\nfn main()->int{ g[1]=7; return g[1]; }",
        7,
    ),
    (
        "array_global_copy",
        "a : [int;2] = [8,9];\nb : [int;2] = a;\nfn main()->int{return b[1];}",
        9,
    ),
    (
        "array_global_unused",
        "g : [int;4] = [1,2,3,4];\nfn main()->int{return 5;}",
        5,
    ),
    (
        "scalar_mut_global",
        "x : int, mut = 5;\nfn main()->int{ x = x + 1; return x; }",
        6,
    ),
    (
        "scalar_const_global",
        "x : int = 5;\nfn main()->int{return x;}",
        5,
    ),
    (
        "array_global_cross_func",
        "g : [int;2] = [3,4];\nfn get()->int{return g[1];}\nfn main()->int{return get();}",
        4,
    ),
    (
        "array_global_two_refs",
        "a : [int;2] = [8,9];\nb : [int;2] = a;\nfn main()->int{return a[0]+b[1];}",
        17,
    ),
    # —— 以下为同一修复面（R1 ② 判据）的扩展 pin：非字面量初值的其它形态 + callee 侧
    # 聚合访问（解释器外函数内联路径的聚合族 opcode；ELF 全局基址字段读写）。 ——
    (
        "struct_global_field_read",
        "struct P { x: int, y: int }\ng : P = P { x = 30, y = 12 };\nfn main()->int{return g.y;}",
        12,
    ),
    (
        "struct_global_field_write_callee",
        "struct P { x: int, y: int }\ng : P = P { x = 1, y = 2 };\nfn set()->int{ g.y = 40; return 0; }\nfn main()->int{ set(); return g.y; }",
        40,
    ),
    (
        "string_global",
        'g : string = "hello";\nfn main()->int{ if str_len(g) == 5 { return 7; } return 1; }',
        7,
    ),
    (
        "call_init_global",
        "fn make()->int{ return 33; }\ng : int, mut = make();\nfn main()->int{ return g; }",
        33,
    ),
    (
        "callee_array_var_index",
        "g : [int;3] = [5,6,7];\nfn get(i: int)->int{ return g[i]; }\nfn main()->int{ return get(2); }",
        7,
    ),
    (
        "alias_array_global_literal",
        "type Arr = [int;2];\ng : Arr = [3,4];\nfn main()->int{return g[1];}",
        4,
    ),
    (
        "alias_array_global_no_init",
        "type Arr = [int;2];\ng : Arr;\nfn main()->int{ g[1] = 7; return g[1]; }",
        7,
    ),
]


def clean_cache() -> None:
    """ci 缓存键不含编译器身份（TODO #5）——判据前清缓存，避免旧 IR 冒充新编译器。

    返回码必须检查（Task 4 评审 Minor）：清缓存失败 + 旧缓存 = 判据被静默污染
    （正是本项目大忌）——失败即报错退出，不许继续跑。
    """
    result = subprocess.run(
        ["nice", "-n", "19", str(COREC), "clean-cache"],
        cwd=BASE,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"[FAIL] clean-cache failed (rc={result.returncode})")
        for line in (result.stdout + result.stderr).strip().splitlines()[:10]:
            print(f"       | {line}")
        raise SystemExit(1)


def has_diag(output: str) -> bool:
    return "error[" in output


def run_interp(source: str):
    """解释器路径：corec run '<code>'。返回 (rc, combined_output)。"""
    result = subprocess.run(
        ["nice", "-n", "19", str(COREC), "run", source],
        cwd=BASE,
        capture_output=True,
        text=True,
    )
    return result.returncode, result.stdout + result.stderr


def run_native(name: str, source: str):
    """ELF 路径：corec build --static + 运行产物。返回 (rc, combined_output)。"""
    tag = f"{name}_{os.getpid()}"   # pid 后缀：并发跑同一测试不互踩（终审 Minor）
    src = BUILD / f"global_init_{tag}.cr"
    binary = BUILD / f"global_init_{tag}"
    ccr = Path(str(binary) + ".ccr")
    src.write_text(source.strip() + "\n", encoding="utf-8")
    try:
        built = subprocess.run(
            [
                "nice",
                "-n",
                "19",
                str(COREC),
                "build",
                str(src),
                "-o",
                str(binary),
                "--static",
            ],
            cwd=BASE,
            capture_output=True,
            text=True,
        )
        out = built.stdout + built.stderr
        if built.returncode != 0:
            return built.returncode, out
        if not binary.exists():
            return 127, out + "\n[no ELF produced]"
        run = subprocess.run([str(binary)], cwd=BASE, capture_output=True, text=True)
        return run.returncode, out + run.stdout + run.stderr
    finally:
        for artifact in (src, binary, ccr):
            try:
                artifact.unlink()
            except FileNotFoundError:
                pass


def main() -> int:
    if not COREC.exists():
        print("build/corec is missing; run `python3 build_selfhost_native.py` first")
        return 1
    BUILD.mkdir(exist_ok=True)
    clean_cache()

    failures = []
    for name, source, expected in CASES:
        ok = True
        for path, runner in (("interp", run_interp), ("elf", run_native)):
            if path == "interp":
                rc, out = runner(source)
            else:
                rc, out = runner(name, source)
            diag = has_diag(out)
            if diag or rc != expected:
                ok = False
                detail = f"rc={rc}"
                if diag:
                    detail += " + diagnostic"
                print(f"[FAIL] {name}/{path}: expected {expected}, got {detail}")
                if out.strip():
                    for line in out.strip().splitlines()[:10]:
                        print(f"       | {line}")
            else:
                print(f"[PASS] {name}/{path}: {rc}")
        if not ok:
            failures.append(name)

    print(f"{len(CASES) - len(failures)}/{len(CASES)} global-init cases passed (dual path)")
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
