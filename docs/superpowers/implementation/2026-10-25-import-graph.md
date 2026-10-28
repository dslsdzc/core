# Import Graph Implementation Record

Plan: `docs/superpowers/plans/2026-10-25-import-graph.md`.

**Status:** implemented in `src/compiler` on top of SourceManager.

**Goal:** Remove `res_imports` source concatenation and parse each import file as
its own SourceManager file.

**Spec:** `docs/superpowers/specs/2026-10-25-import-graph-design.md`

**Approach:** atomic frontend replacement. The old concatenation path was
deleted in the same change as the per-file parse path; there was no
`<combined>` transition state.

## Global Constraints

- Language semantics, import visibility, and declaration order are unchanged.
- `_import.cr` contributes import edges, never parsed code.
- Diagnostics report the real file path and file-local line/column.
- File paths are not interned, so `.ccr` bytes do not depend on the build
  directory.
- Keep `check src/compiler`, `selfhost-tests`, `suite`, `bootstrap-tests`, and
  `full-bootstrap` green.
- Use `jj`, not `git`.

## Review Focus

- Two files fail on the same line: each diagnostic names its own file.
- Main imports a sibling that imports another file: all three parse once in
  main-first order.
- Editing only an imported file invalidates the CIR cache.
- A line-only diagnostic inside an imported file renders that file's text.
- An `_import.cr` manifest contributes no declarations.
- Building the same source in two directories produces identical `.ccr`.

---

### Task 1: Source identity and file-aware diagnostics

**Files:** `src/compiler/source.cr`, `src/compiler/lexer.cr`,
`src/compiler/module.cr`, `src/compiler/diag.cr`, `src/compiler/checker.cr`

- [x] Add `sm_file_line_base(id)`.
- [x] `tokenize(file_id, ...)` sets `g_line_base`; `tokenize_impl` starts
      `g_line = g_line_base + 1`; token spans subtract the base.
- [x] Extend `g_files` to 24-byte records: fileid, path, SourceManager id.
      `reg_fileid_sm` / `file_sm_id` read and write the new column.
- [x] Build `g_line_fileid` from SourceManager ranges in `build_line_fileid`.
- [x] Store SourceManager paths as raw strings, not interned names.
- [x] `read_source_line` resolves the global line to its owning file. The old
      main-text fallback is deleted.
- [x] `check_error`/`diag_type_incompatible` resolve the owning file before
      computing a span; diagnostics print `path:local_line:col`.
- [x] `print_diagnostics` prints no path only for the main file.
- [x] S1P source fragments resolve through SourceManager instead of scanning
      `g_source`.

### Task 2: Import graph discovery

**Files:** `src/compiler/module.cr`, `src/compiler/globals.cr`,
`src/compiler/dyn_arr.cr`

- [x] Add `g_import_sm`, `g_import_count`, `g_import_cap`, `g_main_sm`,
      `g_main_fni`, `g_source_path`, `g_parse_multi_keep`, and
      `grow_import_sms`.
- [x] `import_scan_text` tokenizes one manifest, registers SourceManager lines
      (no fileid, no `g_files` row), and never pushes it to the parse list.
- [x] `import_scan_ancestors` visits root-first so manifest edge order matches
      the old prepend order; stdlib is scanned last.
- [x] `import_scan_tokens` preserves project imports, aliases, `::` paths,
      target roots, and `.so` index registration.
- [x] `import_add` deduplicates by fileid, registers SourceManager + `g_files` +
      `g_mods`, and appends to the parse list.
- [x] `res_imports` seeds main, scans manifests, scans the static prelude
      (when present), scans main, then BFS-scans the growing import list.

### Task 3: Per-file parse

**Files:** `src/compiler/parser.cr`, `src/compiler/main.cr`,
`src/compiler/dump.cr`, `src/compiler/purity_selftest.cr`, `src/lsp/lsp.cr`

- [x] Split the reset block into `parse_reset()`; `parse_all()` keeps the token
      loop and skips the reset when `g_parse_multi_keep != 0`.
- [x] `parse_all_files()` tokenizes and parses each SourceManager id once.
- [x] At the end, restore `g_source`, `g_source_len`, `g_source_file`, and
      `g_line_base` to the main file.
- [x] Switch every frontend caller to `parse_all_files()`.
- [x] Remove the `<combined>` attribution and the `g_source_combined` flag.
- [x] Delete the segment tables (`g_seg_*`, `grow_segs`) that only served the
      concatenated line map.
- [x] `--static` registers `rt.cr` as a prelude SourceManager file instead of
      prepending its text. The prelude parses before main, has no fileid, and
      does not shift user line numbers.

### Task 4: Cache and source consumers

**Files:** `src/compiler/ir_gen.cr`, `src/lsp/analysis.cr`,
`src/lsp/lsp.cr`

- [x] `ccr_source_has_marker` scans the prelude and every graph file.
- [x] `func_fingerprint` hashes the prelude and every graph file in parse order.
- [x] LSP re-tokenizes the main file after parsing.
- [x] LSP path lookup uses 24-byte `g_files` records.
- [x] `analysis_line_offset` returns the SourceManager line base.
- [x] Definition JSON resolves the owning file and file-local line/column.
- [x] Function definition uses the AST node line; struct and enum definition
      scan the import graph and restore the main token stream.
- [x] LSP diagnostic ranges use the source span when present and subtract the
      owning file's line base for line-only diagnostics.
- [x] Semantic tokens operate on the restored main token stream.

### Task 5: Regression coverage and verification

**Files:** `tests/selfhost/test_import_graph.py`, `src/ci/run.sh`

- [x] Two files compile and run (`rc=42`).
- [x] A nested import (main imports `a`, `a` imports `b`) compiles and runs
      (`rc=42`).
- [x] An imported-file type error reports `bad.cr:2:5`, not `<combined>`.
- [x] Two files failing on line 2 each keep their own path.
- [x] `_import.cr` declarations are invisible to the program.
- [x] Editing only `lib.cr` changes the rebuilt binary from 42 to 7.
- [x] LSP reports an imported diagnostic on its file-local line and resolves
      imported function and struct definitions.
- [x] `--static` user diagnostics keep the user file's local line; imported
      files keep their own path.
- [x] Mount `test_import_graph.py` in `selfhost-tests`.
- [x] Re-lock canary values after attribution (see
      `tools/baseline/canary_values.tsv`).

## Verification Evidence

| Command | Result |
| --- | --- |
| `python3 build_selfhost_native.py` | all three binaries built |
| `./build/corec check src/compiler` | `ok` |
| `./build/corec selftest-source` | 16/16 |
| `./build/corec selftest-types` | 417/417 |
| `./build/corec selftest-purity` | 26/26 |
| `python3 tests/selfhost/test_import_graph.py` | 7/7 |
| `python3 tests/selfhost/test_compile.py` | pass |
| `python3 tests/selfhost/test_multibranch_v10.py` | 70/70 |
| `python3 tests/selfhost/test_cir_warm_path.py` | 19/19 |
| `python3 tests/selfhost/test_cache_identity.py` | 6/6 |
| V4 suite (`inference`, `for_sequence`, `auto_constraint`, `no_generic_syntax`, `return_inference`, `field_inference`, `generic_enum`, `len`, `ambiguous_constraint`) | all green |
| `python3 tests/selfhost/test_collections_v4.py` | rc=42 |
| `test_cir_cache_warm_restore_remaps_shifted_case_targets` | passes; `.ccr` is path-independent |
| `CI_JOB_NAME=selfhost-tests src/ci/run.sh` | rc=0, canary 5/5 |
| `CI_JOB_NAME=suite src/ci/run.sh` | rc=0, ALL PASS |
| `CI_JOB_NAME=full-bootstrap src/ci/run.sh` | rc=0, corec2 == corec3 |

## Remaining Boundary

SourceManager now owns every parsed file, including the static runtime and
manifests. Two limits are intentional:

- AST nodes store `(line, col)`, not a file id or span. File ownership is
  recovered from the global line table. Adding a file column would change the
  in-memory AST layout and every accessor.
- LSP analysis runs on the open document's token stream. Imported declarations
  are resolved through the import graph, but interactive analysis is not a
  multi-file token session.
