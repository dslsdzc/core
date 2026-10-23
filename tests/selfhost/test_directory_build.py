#!/usr/bin/env python3
"""Regression tests for building a project through a directory path."""

import shutil
import stat
import subprocess
from pathlib import Path


BASE = Path(__file__).resolve().parents[2]
BUILD = BASE / "build"
COREC = BUILD / "corec"
COREARCH = BUILD / "corearch"
TEST_BUILD = BUILD / "test_directory_build"


def run_corec(args: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["nice", "-n", "19", str(COREC), *args],
        cwd=cwd,
        capture_output=True,
        text=True,
        timeout=180,
    )


def main() -> int:
    if not COREC.exists() or not COREARCH.exists():
        print("build/corec or build/corearch is missing; run build_selfhost_native.py")
        return 1

    shutil.rmtree(TEST_BUILD, ignore_errors=True)
    project = TEST_BUILD / "named-directory"
    project.mkdir(parents=True)

    try:
        (project / "Core.toml").write_text(
            'name = "directory_build_smoke"\n', encoding="utf-8"
        )
        (project / "_import.cr").write_text("import helper\n", encoding="utf-8")
        (project / "helper.cr").write_text(
            "fn imported_result() -> int:\n    return 23\n", encoding="utf-8"
        )
        (project / "main.cr").write_text(
            "fn runtime_symbol_visible() -> string:\n    return g_heap_ptr\nfn main() -> int:\n    return imported_result()\n",
            encoding="utf-8",
        )

        result = run_corec(["build", ".", "--static", "-O", "0"], project)
        if result.returncode != 0:
            print(f"[FAIL] directory build exited {result.returncode}")
            print(result.stdout)
            print(result.stderr)
            return 1

        output = project / "directory_build_smoke"
        ccr_output = project / "directory_build_smoke.ccr"
        if not output.exists() or not ccr_output.exists():
            print("[FAIL] directory build ignored the Core.toml project name")
            print(result.stdout)
            print(result.stderr)
            return 1

        output_mode = output.stat().st_mode
        output.chmod(output_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        run_result = subprocess.run([str(output)], cwd=project, timeout=30)
        if run_result.returncode != 23:
            print(f"[FAIL] directory output returned {run_result.returncode}, expected 23")
            print(result.stdout)
            print(result.stderr)
            return 1
        print(
            "[PASS] `corec build .` resolves _import.cr and emits a working ELF"
        )

        (project / "helper.cr").write_text(
            "fn imported_result() -> int:\n    return 25\n", encoding="utf-8"
        )
        rebuilt = run_corec(["build", ".", "--static", "-O", "0"], project)
        if rebuilt.returncode != 0:
            print(f"[FAIL] changed import rebuild exited {rebuilt.returncode}")
            print(rebuilt.stdout)
            print(rebuilt.stderr)
            return 1
        rebuilt_run = subprocess.run([str(output)], cwd=project, timeout=30)
        if rebuilt_run.returncode != 25:
            print(
                f"[FAIL] changed import reused stale IR: got "
                f"{rebuilt_run.returncode}, expected 25"
            )
            return 1
        print("[PASS] imported source changes invalidate the function cache")

        unnamed = TEST_BUILD / "unnamed-directory"
        unnamed.mkdir()
        (unnamed / "main.cr").write_text(
            "fn main() -> int:\n    return 24\n", encoding="utf-8"
        )
        unnamed_result = run_corec(["build", ".", "--static", "-O", "0"], unnamed)
        unnamed_output = unnamed / "unnamed-directory"
        if unnamed_result.returncode != 0 or not unnamed_output.exists():
            print("[FAIL] unnamed directory build did not use the directory name")
            print(unnamed_result.stdout)
            print(unnamed_result.stderr)
            return 1
        unnamed_output.chmod(
            unnamed_output.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH
        )
        unnamed_run = subprocess.run([str(unnamed_output)], cwd=unnamed, timeout=30)
        if unnamed_run.returncode != 24:
            print(
                f"[FAIL] unnamed directory output returned "
                f"{unnamed_run.returncode}, expected 24"
            )
            return 1
        print("[PASS] an unnamed `.` project falls back to its directory name")

        (TEST_BUILD / "main.cr").write_text(
            "fn main() -> int:\n    return 99\n", encoding="utf-8"
        )
        missing = run_corec(["check", "missing-project"], TEST_BUILD)
        if missing.returncode == 0:
            print("[FAIL] missing directory silently used main.cr from the working directory")
            return 1
        print("[PASS] a missing directory cannot fall back to the working directory")
        return 0
    finally:
        shutil.rmtree(TEST_BUILD, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
