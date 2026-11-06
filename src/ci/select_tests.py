#!/usr/bin/env python3
"""Plan which CI areas and heavy jobs a change needs.

Examples:
    python3 src/ci/select_tests.py --validate
    python3 src/ci/select_tests.py --profile pr --json
    python3 src/ci/select_tests.py --profile full --github-output "$GITHUB_OUTPUT"
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from ci_common import changed_areas, counts, load_area_defs, load_commands, validate


def select(profile: str, changed_files: list[str], full_bootstrap: bool = False) -> dict:
    defs = load_area_defs()
    areas, suite_touched, ci_change = changed_areas(changed_files)

    if profile == "pr":
        selected = ["core"] + [name for name in defs if name in areas]
        # A CI change is a broad contract change: run every area.
        if ci_change:
            selected = ["core"] + [name for name in defs if name not in {"core", "misc"}]
        matrix_areas = [name for name in selected if name != "core"]
        if not matrix_areas:
            matrix_areas = ["none"]
        run_suite = suite_touched or ci_change
        run_canary = "canary" in selected
        run_full_bootstrap = False
    else:
        selected = [name for name in defs if name != "misc"]
        matrix_areas = [name for name in selected if name != "core"]
        run_suite = True
        run_canary = True
        run_full_bootstrap = bool(full_bootstrap)

    matrix = {"include": [{"area": name} for name in matrix_areas]}
    full_matrix = {"include": [{"area": name} for name in defs if name not in {"core", "misc"}]}

    return {
        "profile": profile,
        "selected": selected,
        "areas": matrix_areas,
        "matrix": matrix,
        "full_matrix": full_matrix,
        "run_suite": run_suite,
        "run_canary": run_canary,
        "run_full_bootstrap": run_full_bootstrap,
        "counts": counts(defs),
        "changed_files": changed_files,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--profile", choices=["pr", "full", "nightly"], default="pr")
    ap.add_argument("--changed-files", default="", help="file containing one changed path per line")
    ap.add_argument("--full-bootstrap", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--github-output", default="")
    ap.add_argument("--validate", action="store_true")
    ap.add_argument("--list-areas", action="store_true")
    args = ap.parse_args()

    if args.validate:
        return validate()
    if args.list_areas:
        for name, spec in load_area_defs().items():
            print(f"{name}: {len(spec.get('match', []))} matchers")
        return 0

    changed: list[str] = []
    if args.changed_files:
        changed = [line.strip() for line in Path(args.changed_files).read_text(encoding="utf-8").splitlines() if line.strip()]
    result = select(args.profile, changed, args.full_bootstrap)
    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    if args.github_output:
        with Path(args.github_output).open("a", encoding="utf-8") as fh:
            fh.write(f"profile={result['profile']}\n")
            fh.write(f"areas_matrix={json.dumps(result['matrix'], separators=(',', ':'))}\n")
            fh.write(f"full_matrix={json.dumps(result['full_matrix'], separators=(',', ':'))}\n")
            fh.write(f"run_suite={'true' if result['run_suite'] else 'false'}\n")
            fh.write(f"run_canary={'true' if result['run_canary'] else 'false'}\n")
            fh.write(f"run_full_bootstrap={'true' if result['run_full_bootstrap'] else 'false'}\n")
    if not args.json and not args.github_output:
        print(f"profile: {result['profile']}")
        print(f"areas: {', '.join(result['areas'])}")
        print(f"suite: {result['run_suite']} canary: {result['run_canary']} bootstrap: {result['run_full_bootstrap']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
