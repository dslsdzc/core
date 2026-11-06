#!/usr/bin/env python3
"""Shared CI area/command classification.

The command list in ``selfhost_tests.list`` stays the single source of truth.
``areas.toml`` only classifies those commands and maps changed paths to areas.
"""

from __future__ import annotations

import fnmatch
import re
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
COMMANDS_FILE = ROOT / "src" / "ci" / "selfhost_tests.list"
AREAS_FILE = ROOT / "src" / "ci" / "areas.toml"

AREA_ORDER = ["core", "generics", "ccr-cir", "runtime-alloc", "concurrency", "stdlib", "canary", "misc"]


def load_area_defs() -> dict[str, dict]:
    with AREAS_FILE.open("rb") as fh:
        data = tomllib.load(fh)
    # Preserve manifest order, then append any area the manifest forgot so
    # validation reports it instead of silently dropping commands.
    ordered: dict[str, dict] = {}
    for name in AREA_ORDER:
        if name in data:
            ordered[name] = data[name]
    for name in data:
        if name not in ordered:
            ordered[name] = data[name]
    return ordered


def load_commands() -> list[str]:
    commands: list[str] = []
    for raw in COMMANDS_FILE.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if line:
            commands.append(line)
    return commands


def _compiled(area_defs: dict[str, dict]) -> dict[str, list[re.Pattern[str]]]:
    out: dict[str, list[re.Pattern[str]]] = {}
    for name, spec in area_defs.items():
        out[name] = [re.compile(pattern) for pattern in spec.get("match", [])]
    return out


def assign_area(command: str, area_defs: dict[str, dict] | None = None) -> str:
    defs = area_defs or load_area_defs()
    for name, regexes in _compiled(defs).items():
        for regex in regexes:
            if regex.search(command):
                return name
    return "misc"


def command_index() -> list[tuple[str, str]]:
    defs = load_area_defs()
    return [(command, assign_area(command, defs)) for command in load_commands()]


def _matches_path(path: str, patterns: list[str]) -> bool:
    for pattern in patterns:
        if pattern.endswith("/"):
            if path.startswith(pattern):
                return True
        elif path == pattern or path.startswith(pattern):
            return True
        elif fnmatch.fnmatch(path, pattern):
            return True
    return False


def changed_areas(files: list[str]) -> tuple[set[str], bool, bool]:
    """Return (areas, suite_touched, ci_change).

    ``areas`` excludes ``core`` (which the workflow always runs) and excludes
    ``misc`` unless an unknown non-doc file needs a fallback.
    """
    defs = load_area_defs()
    areas: set[str] = set()
    suite_touched = False
    ci_change = False
    unknown = False

    for raw in files:
        path = raw.replace("\\", "/").strip()
        if not path:
            continue
        if path.startswith("src/ci/") or path.startswith(".github/"):
            ci_change = True
        if path.startswith("tests/suite/"):
            suite_touched = True
            continue
        if path.startswith("tests/selfhost/") and path.endswith(".py"):
            name = Path(path).name
            area = assign_area(f"python3 tests/selfhost/{name}", defs)
            if area != "core":
                areas.add(area)
            continue
        if path.startswith("tests/harness/"):
            if "canary" in path:
                areas.add("canary")
            continue
        if path.startswith("tests/bootstrap/"):
            continue
        if path.startswith("docs/") or path.endswith(".md") or path.startswith("README"):
            continue

        matched = False
        for name, spec in defs.items():
            if name in {"core", "misc"}:
                continue
            patterns = spec.get("paths", [])
            excludes = spec.get("exclude", [])
            if not patterns:
                continue
            if _matches_path(path, patterns) and not _matches_path(path, excludes):
                areas.add(name)
                matched = True
        if not matched:
            unknown = True

    if ci_change:
        areas.update(name for name in defs if name not in {"core", "misc"})
    if unknown:
        areas.add("misc")
    areas.discard("core")
    return areas, suite_touched, ci_change


def counts(defs: dict[str, dict] | None = None) -> dict[str, int]:
    defs = defs or load_area_defs()
    out: dict[str, int] = {name: 0 for name in defs}
    for command in load_commands():
        area = assign_area(command, defs)
        out[area] = out.get(area, 0) + 1
    return out


def validate() -> int:
    defs = load_area_defs()
    commands = load_commands()
    area_counts = counts(defs)
    unassigned: list[str] = []
    for command in commands:
        area = assign_area(command, defs)
        if area not in area_counts:
            unassigned.append(f"{command} -> {area}")
    print(f"{len(commands)} commands assigned")
    for name in defs:
        print(f"  {name}: {area_counts.get(name, 0)}")
    if unassigned:
        print("unassigned:")
        for line in unassigned:
            print(f"  {line}")
        return 1
    if area_counts.get("misc", 0) > 0:
        print(f"unclassified commands in misc: {area_counts['misc']}")
        for command in load_commands():
            if assign_area(command, defs) == "misc":
                print(f"  {command}")
        return 1
    empty = [name for name, count in area_counts.items() if count == 0 and name != "misc"]
    if empty:
        print(f"empty areas: {', '.join(empty)}")
        return 1
    return 0
