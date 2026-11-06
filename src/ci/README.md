# CI layout

The workflow in `.github/workflows/core-ci.yml` is layered. The test scripts did
not move; `src/ci/selfhost_tests.list` remains the single command list.

## Layers

| Layer | Jobs | When | Purpose |
|---|---|---|---|
| plan | `plan` | always | Map changed paths to test areas, decide heavy jobs |
| build | `build` | always | Build `corec/corearch/corelsp` once, upload `core-build` |
| static | `static-bootstrap` | always | Bootstrap/harness checks that need no compiler |
| PR | `compiler-check`, `core-tests`, `area/*` | `pull_request` | Fast, relevant feedback |
| full | `suite`, `selfhost/*`, `canary` | push/merge_group/manual full | Whole corpus |
| L3 | `full-bootstrap` | manual with `full_bootstrap=true` | Three-stage self-host build |

`pr-gate` aggregates the PR jobs and is the only required PR check.
`full-gate` aggregates the full jobs.

## Areas

`src/ci/areas.toml` classifies every command in `selfhost_tests.list` into one
area. A command belongs to the first area whose `match` regex hits. A changed
path belongs to every area whose `paths` prefix hits, minus `exclude`.

```bash
python3 src/ci/select_tests.py --validate
python3 src/ci/select_tests.py --profile pr --changed-files <(git diff --name-only)
python3 src/ci/select_tests.py --profile full --json
```

Rules:

- `core` always runs on PRs.
- A `src/ci/` or `.github/` change selects every area and the suite.
- A `tests/suite/` change selects the suite.
- A `tests/selfhost/<name>.py` change selects the area that owns that command.
- A docs-only change selects only `core`.

## Running one area locally

```bash
python3 src/ci/run_tests.py --area core --profile pr
python3 src/ci/run_tests.py --area generics --profile pr
python3 src/ci/run_tests.py --area runtime-alloc --dry-run
```

The runner continues after failures, prints every failure, writes
`build/ci/results-<area>.json`, and exits nonzero if any non-quarantined command
failed.

## Quarantine

`src/ci/quarantine.toml` is empty by default. Every entry needs `match`,
`issue`, `expires`, and `reason`. A matching failure is reported as
`QUARANTINED` and does not fail the job; a matching pass is an
`UNEXPECTED PASS` failure; an expired entry is a normal failure.

## Manual full / merge gate

```bash
# Full layer on a branch
gh workflow run core-ci.yml --ref <branch> -f profile=full

# Full layer on refs/pull/<n>/merge (merge gate)
gh workflow run core-ci.yml --ref <branch> -f profile=full -f pr=<number>

# Three-stage bootstrap on a larger runner
gh workflow run core-ci.yml --ref <branch> -f profile=full \
  -f full_bootstrap=true -f runner=<runner-label>
```

The stage-2 self-host build does not fit the standard `ubuntu-latest` runner:
the runner is shut down after roughly eight minutes with no compiler error.
Pass a larger runner label when exercising L3. The full layer without
`full_bootstrap=true` does not depend on it.
