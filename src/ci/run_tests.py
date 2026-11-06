#!/usr/bin/env python3
"""Run one CI area from selfhost_tests.list.

The runner keeps going after a failed command so one job reports every failure
in its area. A non-quarantined failure makes the process exit nonzero.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import subprocess
import sys
import time
import tomllib
from pathlib import Path

from ci_common import ROOT, assign_area, load_area_defs, load_commands

QUARANTINE_FILE = ROOT / "src" / "ci" / "quarantine.toml"


def load_quarantine() -> list[dict]:
    if not QUARANTINE_FILE.exists():
        return []
    with QUARANTINE_FILE.open("rb") as fh:
        data = tomllib.load(fh)
    return data.get("quarantine", [])


def quarantine_for(command: str, entries: list[dict]) -> dict | None:
    for entry in entries:
        pattern = entry.get("match", "")
        if pattern and pattern in command:
            return entry
    return None


def expired(entry: dict) -> bool:
    raw = entry.get("expires", "")
    if not raw:
        return True
    try:
        return dt.date.today() > dt.date.fromisoformat(raw)
    except ValueError:
        return True


def commands_for(area: str) -> list[str]:
    defs = load_area_defs()
    return [command for command in load_commands() if assign_area(command, defs) == area]


def run_one(command: str, timeout: int) -> tuple[int, str, float]:
    env = os.environ.copy()
    env.setdefault("TMPDIR", "/tmp")
    env.setdefault("CORE_SAFE", "1")
    started = time.monotonic()
    try:
        proc = subprocess.run(
            ["bash", "-c", f"ulimit -c 0 2>/dev/null || true; {command}"],
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        elapsed = time.monotonic() - started
        return proc.returncode, (proc.stdout or "") + (proc.stderr or ""), elapsed
    except subprocess.TimeoutExpired as exc:
        elapsed = time.monotonic() - started
        out = (exc.stdout or "") + (exc.stderr or "")
        if isinstance(out, bytes):
            out = out.decode("utf-8", "replace")
        return 124, out + f"\nTIMEOUT after {timeout}s\n", elapsed


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--area", required=True)
    ap.add_argument("--profile", default="pr")
    ap.add_argument("--timeout", type=int, default=1800)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--json-out", default="")
    args = ap.parse_args()

    if args.area == "none":
        print("area none: no tests selected")
        return 0

    commands = commands_for(args.area)
    if not commands:
        if args.area in {"none", "misc"}:
            print(f"area {args.area}: no tests selected")
            return 0
        print(f"area {args.area}: no commands", file=sys.stderr)
        return 1

    entries = load_quarantine()
    if args.dry_run:
        print(f"area {args.area} ({args.profile}): {len(commands)} command(s)")
        for command in commands:
            print(f"  {command}")
        return 0

    results = []
    failures = 0
    quarantined = 0
    unexpected = 0
    print(f"area {args.area} ({args.profile}): {len(commands)} command(s)", flush=True)

    for command in commands:
        q = quarantine_for(command, entries)
        q_expired = q is not None and expired(q)
        print(f"RUN  {command}", flush=True)
        code, output, elapsed = run_one(command, args.timeout)
        ok = code == 0

        if q is not None and not q_expired and not ok:
            status = "quarantined"
            quarantined += 1
            print(f"QUARANTINED ({elapsed:.1f}s) {q.get('issue', '')} until {q.get('expires', '?')}", flush=True)
        elif q is not None and not q_expired and ok:
            status = "unexpected-pass"
            unexpected += 1
            failures += 1
            print(f"UNEXPECTED PASS ({elapsed:.1f}s): quarantined entry {q.get('issue', '')} can be removed", flush=True)
        elif ok:
            status = "pass"
            print(f"PASS ({elapsed:.1f}s)", flush=True)
        else:
            status = "fail"
            failures += 1
            reason = "quarantine expired" if q_expired else f"exit={code}"
            print(f"FAIL ({elapsed:.1f}s, {reason})", flush=True)
            if output:
                print(output, flush=True)

        results.append({
            "command": command,
            "area": args.area,
            "status": status,
            "exit_code": code,
            "seconds": round(elapsed, 2),
            "quarantine": q.get("issue", "") if q else "",
        })

    out_path = Path(args.json_out) if args.json_out else ROOT / "build" / "ci" / f"results-{args.area}.json"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps({
        "area": args.area,
        "profile": args.profile,
        "passed": len(commands) - failures,
        "failed": failures,
        "quarantined": quarantined,
        "unexpected_pass": unexpected,
        "results": results,
    }, indent=2), encoding="utf-8")
    print(f"area {args.area}: {len(commands) - failures} passed, {failures} failed, {quarantined} quarantined; results={out_path}", flush=True)
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
