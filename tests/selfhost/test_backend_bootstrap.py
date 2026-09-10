#!/usr/bin/env python3
"""Regression test for the independently self-hosted corearch backend."""

import os
import subprocess
from pathlib import Path


BASE = Path(__file__).resolve().parents[2]
BUILD = BASE / "build"
COREC = BUILD / "corec"
COREARCH = BUILD / "corearch"
# 组合根（三轴组合的 target triple 命名）——project-mode 入口 = 该目录 main.cr
BACKEND_SOURCE = BASE / "src" / "targets" / "x86_64-linux"


def run_checked(args: list[str], label: str, env: dict[str, str]) -> bool:
    command = ["nice", "-n", "19", *map(str, args)]
    result = subprocess.run(
        command,
        cwd=BASE,
        env=env,
        capture_output=True,
        text=True,
        timeout=180,
    )
    if result.returncode == 0:
        print(f"[PASS] {label}")
        return True
    print(f"[FAIL] {label}: exit {result.returncode}")
    print(result.stdout)
    print(result.stderr)
    return False


def main() -> int:
    if not COREC.exists() or not COREARCH.exists():
        print("build/corec or build/corearch is missing; run build_selfhost_native.py")
        return 1

    BUILD.mkdir(exist_ok=True)
    stage1 = BUILD / "test_corearch_stage1"
    stage2 = BUILD / "test_corearch_stage2"
    stage3 = BUILD / "test_corearch_stage3"
    stage1_ccr = Path(str(stage1) + ".ccr")
    smoke_src = BUILD / "test_backend_smoke.cr"
    smoke0 = BUILD / "test_backend_smoke_stage0"
    smoke1 = BUILD / "test_backend_smoke_stage1"
    smoke2 = BUILD / "test_backend_smoke_stage2"
    smoke_ccr = Path(str(smoke0) + ".ccr")
    smoke_o2_0 = BUILD / "test_backend_smoke_o2_stage0"
    smoke_o2_1 = BUILD / "test_backend_smoke_o2_stage1"
    smoke_o2_ccr = Path(str(smoke_o2_0) + ".ccr")
    artifacts = [
        stage1,
        stage2,
        stage3,
        stage1_ccr,
        smoke_src,
        smoke0,
        smoke1,
        smoke2,
        smoke_ccr,
        smoke_o2_0,
        smoke_o2_1,
        smoke_o2_ccr,
    ]
    env = os.environ.copy()
    env["PATH"] = str(BUILD) + os.pathsep + env.get("PATH", "")

    try:
        if not run_checked(
            [COREC, "build", BACKEND_SOURCE, "-o", stage1, "--static", "-O", "0"],
            "stage0 builds corearch stage1",
            env,
        ):
            return 1
        if not stage1.exists() or not stage1_ccr.exists():
            print("[FAIL] stage1 backend or CCR was not created")
            return 1
        if not run_checked(
            [stage1, stage1_ccr, "--static", "-o", stage2],
            "stage1 emits corearch stage2",
            env,
        ):
            return 1
        if not run_checked(
            [stage2, stage1_ccr, "--static", "-o", stage3],
            "stage2 emits corearch stage3",
            env,
        ):
            return 1
        if stage1.read_bytes() != stage2.read_bytes() or stage2.read_bytes() != stage3.read_bytes():
            print("[FAIL] self-hosted backend output is not reproducible")
            return 1
        print("[PASS] stage1, stage2, and stage3 are byte-identical")

        smoke_src.write_text("fn main() -> int { return 7; }\n", encoding="utf-8")
        if not run_checked(
            [COREC, "build", smoke_src, "-o", smoke0, "--static", "-O", "0"],
            "stage0 builds smoke CCR",
            env,
        ):
            return 1
        if not run_checked(
            [stage1, smoke_ccr, "--static", "-o", smoke1],
            "stage1 emits smoke ELF",
            env,
        ):
            return 1
        if not run_checked(
            [stage2, smoke_ccr, "--static", "-o", smoke2],
            "stage2 emits smoke ELF",
            env,
        ):
            return 1

        for binary in (smoke0, smoke1, smoke2):
            os.chmod(binary, 0o755)
            result = subprocess.run([str(binary)], cwd=BASE, timeout=30)
            if result.returncode != 7:
                print(f"[FAIL] {binary.name}: expected 7, got {result.returncode}")
                return 1
        print("[PASS] stage0, stage1, and stage2 smoke ELFs return 7")

        if not run_checked(
            [COREC, "build", smoke_src, "-o", smoke_o2_0, "--static", "-O", "2"],
            "stage0 builds O2 metadata CCR",
            env,
        ):
            return 1
        if not run_checked(
            [stage1, smoke_o2_ccr, "--static", "-o", smoke_o2_1],
            "stage1 reads O2 metadata and emits ELF",
            env,
        ):
            return 1
        for binary in (smoke_o2_0, smoke_o2_1):
            os.chmod(binary, 0o755)
            result = subprocess.run([str(binary)], cwd=BASE, timeout=30)
            if result.returncode != 7:
                print(f"[FAIL] {binary.name}: expected 7, got {result.returncode}")
                return 1
        print("[PASS] stage0 and stage1 O2 smoke ELFs return 7")
        return 0
    finally:
        for artifact in artifacts:
            try:
                artifact.unlink()
            except FileNotFoundError:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
