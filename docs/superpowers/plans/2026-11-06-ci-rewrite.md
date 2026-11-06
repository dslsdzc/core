# CI Rewrite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Replace the flat nine-job CI with a build-once, area-selected, layered pipeline that keeps the existing test scripts unchanged.

**Architecture:** A `plan` job maps changed paths to test areas; one `build` job produces the compiler artifact; PR jobs run a fixed core set plus the selected areas; full jobs run every area plus suite/canary; `full-bootstrap` moves to nightly/manual L3. A single `pr-gate` (and `full-gate`) job aggregates results so branch protection needs one required check.

**Tech Stack:** GitHub Actions, Python 3.11+ (`tomllib`), existing `tests/selfhost/*.py`, `src/ci/selfhost_tests.list`, `src/ci/run.sh`.

**Spec:** `docs/superpowers/specs/2026-11-05-complete-generics-design.md` (CI behavior only; no generics code changes).

## Global Constraints

- Do not modify test bodies or test semantics except where a test fixture is already broken by an unrelated runtime change.
- Keep `src/ci/selfhost_tests.list` as the single command list; areas select from it, they do not duplicate commands.
- Every command in `selfhost_tests.list` must be assigned to exactly one area; `select_tests.py --validate` fails otherwise.
- PR layer target: build once + core tests + selected areas, under 10 minutes on a standard runner.
- Full layer: all areas + suite + canary; `full-bootstrap` only when explicitly requested (manual, optional larger runner).
- Quarantine entries must carry an issue and an expiry date; expired or unexpectedly passing quarantined tests fail.
- Keep actions pinned by SHA. Preserve `src/ci/scripts/setup-environment.sh` and `src/ci/scripts/run-build-from-ci.sh` usage.
- No CD/release workflow in this change.

## Review Focus

- A change to `src/compiler/checker.cr` must select the generics/type area, not just the core set.
- A change to `src/stdlib/arena.cr` must select runtime/arena/alloc tests.
- A change to `.github/workflows/*` or `src/ci/*` must select all areas (CI changes need broad validation).
- A docs-only change must not run the whole selfhost corpus.
- A failed area job must fail `pr-gate`; a skipped area job must not.
- The build artifact must restore `build/corec`, `build/corearch`, `build/runtime.o`, and `build/alloc_blob/alloc_body.o`; missing files must fail the job, not skip tests.

---

### Task 1: Area manifest and selector

**Files:**
- Create: `src/ci/areas.toml`
- Create: `src/ci/ci_common.py`
- Create: `src/ci/select_tests.py`
- Test: `python3 src/ci/select_tests.py --validate`

**Interfaces:**
- `ci_common.load_commands() -> list[str]` returns stripped commands from `selfhost_tests.list`.
- `ci_common.load_areas() -> dict[str, dict]` returns ordered area definitions.
- `ci_common.assign_area(command: str) -> str` returns the first matching area or `misc`.
- `select_tests.select(profile: str, changed_files: list[str], full_bootstrap: bool = False) -> dict` returns `{"profile", "selected", "areas", "matrix", "full_matrix", "run_suite", "run_canary", "run_full_bootstrap", "counts"}`.

- [x] **Step 1: Write the area manifest**

Create `src/ci/areas.toml` with ordered areas: `core`, `generics`, `ccr-cir`, `runtime-alloc`, `concurrency-runtime`, `concurrency-plan`, `concurrency-flow`, `stdlib`, `canary`, `misc`. Each has `paths` (glob prefixes) and `match` (regex strings). `core` has `always = true`. `misc` has `paths = []` and matches `.*` as the fallback.

- [x] **Step 2: Implement `ci_common.py`**

Load TOML with `tomllib`, load commands by stripping `#` comments, compile regexes, and implement `assign_area`. Add `changed_areas(files)` using path prefixes/globs and test-file ownership.

- [x] **Step 3: Implement `select_tests.py`**

CLI flags: `--profile pr|full|nightly`, `--changed-files PATH`, `--json`, `--github-output PATH`, `--validate`, `--list-areas`. PR selects `core` plus matched areas; full selects all areas; nightly sets full suite/canary; `run_full_bootstrap` is true only with `--full-bootstrap`. If changed paths touch `src/ci/` or `.github/`, select all areas. If no area matches a non-doc path, include `misc`.

- [x] **Step 4: Validate coverage**

Run `python3 src/ci/select_tests.py --validate`.
Expected: `116 commands assigned` (the list had one duplicate), no `unassigned` entries, every area non-empty.

- [x] **Step 5: Commit**

```bash
git add src/ci/areas.toml src/ci/ci_common.py src/ci/select_tests.py
git commit -m "ci: add area manifest and changed-path test selector"
```

### Task 2: Test runner and quarantine

**Files:**
- Create: `src/ci/run_tests.py`
- Create: `src/ci/quarantine.toml`
- Test: `python3 src/ci/run_tests.py --area core --dry-run`

**Interfaces:**
- `run_tests.main()` runs commands for one area in list order and exits nonzero on the first non-quarantined failure (after finishing the area).
- `quarantine.toml` entries: `match`, `issue`, `expires`, `reason`.

- [x] **Step 1: Implement the runner**

Flags: `--area`, `--profile`, `--timeout`, `--dry-run`, `--json-out`. Use `subprocess.run(..., shell=True, executable="/bin/bash")`, `TMPDIR`, `CORE_SAFE=1`, and `ulimit -c 0`. Print `RUN/PASS/FAIL/QUARANTINED/UNEXPECTED PASS` with durations. Write a JSON result file under `build/ci/`.

- [x] **Step 2: Implement quarantine semantics**

Load `quarantine.toml` if present. An expired entry is a normal failure. A matching failed entry is counted as quarantined success. A matching passing entry is counted as failure so stale entries are removed.

- [x] **Step 3: Dry-run the core area**

Run: `python3 src/ci/run_tests.py --area core --dry-run`
Expected: the core commands are listed in `selfhost_tests.list` order.

- [x] **Step 4: Run the core area**

Run: `python3 src/ci/run_tests.py --area core --profile pr`
Expected: all core tests pass (this is the local smoke of the runner).

- [x] **Step 5: Commit**

```bash
git add src/ci/run_tests.py src/ci/quarantine.toml
git commit -m "ci: add area test runner with quarantine support"
```

### Task 3: Rewrite the workflow

**Files:**
- Modify: `.github/workflows/core-ci.yml`
- Modify: `src/ci/run.sh` (add `CI_SKIP_BUILD`)

**Interfaces:**
- Workflow jobs: `plan`, `static-bootstrap`, `build`, `compiler-check`, `core-tests`, `areas`, `suite`, `selfhost`, `canary`, `full-bootstrap`, `pr-gate`, `full-gate`.
- `plan` outputs `profile`, `areas_matrix`, `full_matrix`, `run_suite`, `run_canary`, `run_full_bootstrap`.
- `pr-gate` is the only required PR check; `full-gate` is the post-submit/manual gate.

- [x] **Step 1: Add `CI_SKIP_BUILD` to `run.sh`**

In `build_selfhost()`, return early when `CI_SKIP_BUILD=1`. Keep all existing branches working.

- [x] **Step 2: Write the new workflow**

Triggers: `pull_request`, `push` to `develop`/`main`, `merge_group`, `schedule` nightly, `workflow_dispatch` with `profile`, `full_bootstrap`, `pr`, `runner`. One `build` job uploads the compiler artifact; downstream jobs download it. Dynamic matrices come from `plan`. `pr-gate`/`full-gate` use `if: always()` and fail on any failed/cancelled dependency.

- [x] **Step 3: Pin actions**

Use the existing checkout SHA. Pin `actions/upload-artifact@v4` and `actions/download-artifact@v4` by SHA. Add `chmod +x` after download.

- [x] **Step 4: Validate YAML and expressions**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/core-ci.yml'))"`
Expected: parses without error. Manually check every `needs` name and `fromJson` output name.

- [x] **Step 5: Commit**

```bash
git add .github/workflows/core-ci.yml src/ci/run.sh
git commit -m "ci: replace flat jobs with layered build-once pipeline"
```

### Task 4: Documentation and local validation

**Files:**
- Create: `src/ci/README.md`
- Modify: `src/ci/run.sh` comments if needed

- [x] **Step 1: Document layers and local commands**

Cover `select_tests.py` examples, `run_tests.py --area`, quarantine policy, required checks, merge-gate dispatch, and why `full-bootstrap` is L3.

- [x] **Step 2: Validate selection scenarios**

Run `select_tests.py --profile pr` with changed files `src/compiler/checker.cr`, `src/stdlib/arena.cr`, `docs/x.md`, and `.github/workflows/core-ci.yml`. Expected area sets as in Review Focus; docs-only returns area `none`, and a CI change selects every area plus the suite.

- [x] **Step 3: Run one small area end-to-end**

Run: `python3 src/ci/run_tests.py --area generics --profile pr`
Expected: all selected generic tests pass; duration printed.

- [x] **Step 4: Commit**

```bash
git add src/ci/README.md
git commit -m "ci: document layered pipeline and local reproduction"
```

### Task 5: Validate on GitHub

- [x] **Step 1: Push the branch and open a PR**

Expected PR jobs: `plan`, `static-bootstrap`, `build`, `compiler-check`, `core-tests`, selected `area/*`, `pr-gate`.

- [x] **Step 2: Dispatch a full run on the branch**

Run `gh workflow run core-ci.yml --ref <branch> -f profile=full -f full_bootstrap=false`. This runs every area + suite + canary, not full-bootstrap.
Expected: `suite`, `selfhost/*`, `canary`, `full-gate` pass.

- [x] **Step 3: Dispatch the merge gate**

Run `gh workflow run core-ci.yml --ref <branch> -f profile=full -f pr=<PR-number> -f full_bootstrap=false`.
Expected: the workflow checks out `refs/pull/<N>/merge` and runs the full layer on the merged tree.

- [x] **Step 4: Merge after PR checks pass**

Squash-merge with admin if needed, then update `develop`.
