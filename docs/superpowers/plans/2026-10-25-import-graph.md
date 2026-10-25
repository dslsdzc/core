# Import Graph Plan

Implementation record: `docs/superpowers/implementation/2026-10-25-import-graph.md`.

## Goal

Remove `res_imports` source concatenation. Each source file keeps its own
SourceManager identity, token stream, line base, and AST contribution. Imports
stay open and global.

## Constraints

- Language semantics, import visibility, and declaration order do not change.
- `_import.cr` contributes import edges, never parsed code.
- Diagnostics report the real file path and the file-local line and column.
- `.ccr` output does not depend on the build directory.
- `check src/compiler`, `selfhost-tests`, `suite`, `bootstrap-tests`, and
  `full-bootstrap` stay green.

## Tasks

1. Source identity
   - Add `g_line_base`, `sm_file_line_base`, and `sm_for_line`.
   - Store SourceManager paths as raw strings.
   - Extend `g_files` records with a SourceManager id.
   - Build `g_line_fileid` from SourceManager line ranges.
   - Resolve line-only diagnostics to the owning file.

2. Import graph
   - Scan ancestor and stdlib `_import.cr` manifests for edges only.
   - Scan the main file, then BFS-scan each discovered import.
   - Deduplicate by fileid and keep `g_mods` in discovery order.
   - Do not intern manifest fileids or host paths.

3. Per-file parse
   - Split `parse_reset` from `parse_all`.
   - Add `parse_all_files`, which tokenizes and parses each graph file once.
   - Restore the main file's source, length, fileid, and line base after parsing.
   - Switch every frontend caller to `parse_all_files`.
   - Delete the `<combined>` attribution and the segment tables.

4. Cache and LSP
   - Hash every graph file for the CIR cache fingerprint.
   - Scan every graph file for compiler source markers.
   - Re-tokenize the main file in LSP after parsing.
   - Resolve LSP definition positions through the owning file.

5. Verification
   - Add `tests/selfhost/test_import_graph.py` with sibling, nested, diagnostic,
     same-line, manifest, and cache-invalidation cases.
   - Mount the test in `selfhost-tests`.
   - Re-lock canary values with attribution and old-value records.

## Acceptance

- Two files and nested imports build and run with the expected return code.
- Diagnostics in imported files name the imported path and local line.
- Editing only an imported file invalidates the cache.
- `_import.cr` declarations are not visible to the program.
- The same source in two directories produces identical `.ccr`.
- All five CI jobs pass and the canary gate passes after re-lock.
