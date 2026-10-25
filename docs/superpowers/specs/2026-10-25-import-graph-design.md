# Import Graph Design

Implementation record: `docs/superpowers/implementation/2026-10-25-import-graph.md`.

## Goal

Stop `res_imports` from concatenating every import into one `g_source` string.
Each source file keeps its own SourceManager identity, token stream, line base,
and AST contribution. Imports stay open/global (no namespace change), so the
checker and IR pipeline see the same declarations in the same order as before.

## Invariants

- Language semantics and import visibility do not change.
- `_import.cr` remains an import manifest; it contributes import edges, not code.
- A diagnostic reports the real file path and the file-local line/column.
- No `<combined>` virtual file is used.
- Import order is deterministic: main file first, then imports in the order the
  old pass loop discovered them.
- File paths are diagnostic metadata, not interned names. Interning them would
  leak absolute build paths into the IR string table and make `.ccr` output
  depend on the build directory.
- `.ccr`/ELF changes require a canary re-lock with attribution.

## Architecture

### Source records

Each file is registered with `sm_add_file(path, text)`. SourceManager assigns a
global line base (`OFF_SMF_LINE_BASE`) and a file-local line count. Paths are
stored as raw strings (`cell_store_str`), not interned indexes.

The tokenizer keeps emitting file-local offsets. Token lines are offset by the
file's base, so `g_line_fileid` remains a flat table from a global line to a fileid.

`g_files` (fileid name and path) gains a SourceManager id column at `+16`
(record size 24). `reg_fileid_sm(fileid_str, path, sm_id)` registers both
spaces; `file_sm_id(fni)` maps back. Main file is always SourceManager id 0.

### Discovery

`res_imports` is a graph builder:

1. Register the main file (text, path, fileid) and push its SourceManager id.
2. Scan `_import.cr` manifests for import edges only. Ancestor manifests are
   visited root-first, then `src/stdlib/_import.cr`, matching the old prepended
   order. Manifest files get SourceManager lines but no `g_files` row and no
   fileid: they never enter the parse list and must not add a compiler-internal
   identifier to the program string table. Line-only diagnostics resolve their
   text through `sm_for_line`.
3. Scan the main file's `T_IMPORT` tokens for edges.
4. BFS: for each queued file, tokenize it and scan its `T_IMPORT` tokens with the
   same resolution rules as before (project imports, aliases, `::` paths,
   target import roots, `$HOME/.core/lib` indexes). Resolve each edge to text +
   path + fileid, deduplicate by fileid, append to the worklist and to `g_mods`
   (the module row stores alias, fileid, and path).
5. Build the flat line table from SourceManager line bases and restore `g_source`
   to the main file text.

The parse order is main first, then imports in discovery order (manifest edges,
main edges, BFS waves). This preserves the old declaration order.

### Parsing

`parse_all()` keeps its reset block behind `g_parse_multi_keep`: the first call
resets declaration tables, later calls only reset the token cursor and
`g_want_value`. `parse_all_files()` walks `g_import_sm`:

1. `tokenize(sm_id, 0)` (sets `g_source_file`, `g_source`, line base).
2. `parse_all()`.

AST node lines are global. AST nodes keep their existing layout (no file
column), so there is no AST or `.ccr` schema change.

### Diagnostics and source text

- Attributed diagnostics keep using `smf/slo` spans.
- Line-only diagnostics resolve through `g_line_fileid`, which is built from
  SourceManager line bases instead of scanning concatenated text.
- `read_source_line(line)` resolves `(fileid, local_line)` and reads that file's
  own text. The old `g_source` scan remains only as a fallback for unattributed
  lines.
- `g_source` remains the main file text for legacy sites (S1P fragment,
  `ccr_source_dir_is_compiler`).
- `ccr_source_has_marker` scans every graph file.
- The CIR cache source hash is FNV over every graph file in parse order. Hashing
  only the main file would let an imported-file edit reuse a stale cache entry.

### LSP

`lsp_check_file` re-tokenizes the main file after parsing, so hover, definition,
completion, and semantic tokens operate on the open document rather than the
last parsed import. Definition JSON resolves the declaration's owning file via
`g_line_fileid`/`file_sm_id` and emits file-local line/column. Function
definition uses the AST node line, which works for imported declarations.

## Non-goals

- Module namespaces, visibility, or separate compilation.
- Incremental per-file cache entries.
- Per-file identity for project mode (directory builds still pass one
  concatenated source string as the main file) and for the static runtime prefix.
- Concurrency/ownership/transfer planning.
