#!/usr/bin/env python3
"""v4 layout probe — zero-build text/count criteria for the v4 layout spec.

Spec (the authority this probe mechanically encodes):
    docs/maintainer/design/v4-layout-spec.md

Why a probe and not a test: the v4 migration window has NO buildable
intermediate state, so the layout contract must be checkable without a
compiler.  Every assertion here is pure text/count over source files.

Subcommands
    concat-layout     J-T0-1  concatenation is layout-transparent
    semi-resolvers    J-T0-2  every ';'-dependent ambiguity resolver is listed
    struct-lit-forms  J-T0-4  the unselected struct-literal form is absent (zero-build half)
    tokenize-sites    J-T0-5  every tokenize() call site is classified (static half)

Usage
    python3 tools/v4_layout_probe.py concat-layout
    python3 tools/v4_layout_probe.py concat-layout --sep-col 4 --comment-policy participate
    python3 tools/v4_layout_probe.py semi-resolvers --spec docs/maintainer/design/v4-layout-spec.md
    python3 tools/v4_layout_probe.py struct-lit-forms --form eq

LIMITS (read before trusting a green):
  * This probe is a MODEL of the spec's layout rules, not the compiler.  It
    proves the spec is self-consistent and that the concatenation technique is
    layout-transparent UNDER THAT MODEL.  It does NOT prove the T5 lexer
    implements the model.  The compiler-side gate stays J-T5-3 / J-T5-2.
  * Reading source: by default the probe reads the working tree.  Pass --rev
    to read a pinned revision via `jj file show -r <rev>` instead -- the
    working tree in a multi-workspace repo can lag, and a lagging checkout is
    byte-identical to "the previous generation of values".
"""

import argparse
import os
import re
import subprocess
import sys

# ── comment / string aware line analysis ────────────────────────────────────


class LineInfo:
    __slots__ = ("lineno", "raw", "blank", "comment_only", "first_token_col",
                 "first_comment_col")

    def __init__(self, lineno, raw):
        self.lineno = lineno
        self.raw = raw
        self.blank = True
        self.comment_only = False
        self.first_token_col = None   # 0-based column of first code char
        self.first_comment_col = None # 0-based column of first comment char


def analyze_line(lineno, raw, block_depth):
    """Classify one physical line.

    block_depth: nesting depth of an open /* */ comment carried in from the
    previous line.  Returns (LineInfo, new_block_depth).

    Nestable block comments are v4 §1.1.  A line is:
      blank        -- no code, no comment
      comment_only -- a comment but no code (this INCLUDES a line that merely
                      continues a /* */ block comment)
      code         -- has at least one code character
    """
    info = LineInfo(lineno, raw)
    has_code = False
    has_comment = False
    i = 0
    n = len(raw)
    depth = block_depth
    while i < n:
        c = raw[i]
        if depth > 0:
            has_comment = True
            if c == "*" and i + 1 < n and raw[i + 1] == "/":
                depth -= 1
                i += 2
                continue
            if c == "/" and i + 1 < n and raw[i + 1] == "*":
                depth += 1
                i += 2
                continue
            i += 1
            continue
        if c in " \t\r":
            i += 1
            continue
        if c == "/" and i + 1 < n and raw[i + 1] == "/":
            has_comment = True
            if info.first_comment_col is None:
                info.first_comment_col = i
            break
        if c == "/" and i + 1 < n and raw[i + 1] == "*":
            has_comment = True
            if info.first_comment_col is None:
                info.first_comment_col = i
            depth += 1
            i += 2
            continue
        if c == '"' or c == "'":
            if not has_code:
                pass
            has_code = True
            if info.first_token_col is None:
                info.first_token_col = i
            quote = c
            i += 1
            while i < n:
                if raw[i] == "\\":
                    i += 2
                    continue
                if raw[i] == quote:
                    i += 1
                    break
                i += 1
            continue
        # ordinary code character
        has_code = True
        if info.first_token_col is None:
            info.first_token_col = i
        i += 1

    info.blank = (not has_code) and (not has_comment)
    info.comment_only = (not has_code) and has_comment
    return info, depth


def analyze_text(text):
    """Yield LineInfo for every physical line of `text`."""
    out = []
    depth = 0
    for idx, raw in enumerate(text.split("\n"), start=1):
        info, depth = analyze_line(idx, raw, depth)
        out.append(info)
    return out


# ── layout scanner (the spec's decisions ①②③, made executable) ─────────────


class ScanResult:
    def __init__(self):
        self.events = []    # (lineno, col, depth) for content lines
        self.errors = []    # (lineno, col, msg)
        self.top_col = None

    @property
    def n_top(self):
        if self.top_col is None:
            return 0
        return sum(1 for (_ln, col, _d) in self.events if col == self.top_col)

    def depths(self):
        return {ln: d for (ln, _c, d) in self.events}


def layout_scan(lines, comment_policy="noop"):
    """Offside-rule scan of already-analyzed lines.

    comment_policy:
      'noop'        -- decision ① clauses 1+2: blank and comment-only lines
                       produce no token, change no anchor, and do NOT
                       participate in "the first non-blank line establishes
                       the anchor".
      'participate' -- MUTANT, for reverse controls only.  A comment-only line
                       is treated as a content line for anchor purposes.

    v4 §1.6: deeper = subordinate, same column = sibling, shallower = leave one
    or more regions.  Width carries no meaning, so this pops to the nearest
    enclosing level <= col and pushes a new level when col is strictly deeper.
    Only "shallower than the unit's base anchor" is a layout error.
    """
    res = ScanResult()
    stack = []
    for info in lines:
        if info.blank:
            continue
        if info.comment_only:
            if comment_policy == "noop":
                continue
            col = info.first_comment_col
            if col is None:
                continue
        else:
            col = info.first_token_col
        if res.top_col is None:
            res.top_col = col
            stack.append(col)
            res.events.append((info.lineno, col, 0))
            continue
        while len(stack) > 1 and col < stack[-1]:
            stack.pop()
        if col > stack[-1]:
            stack.append(col)
        elif col < stack[-1]:
            res.errors.append(
                (info.lineno, col,
                 "anchor %d is shallower than the unit base anchor %d"
                 % (col, stack[-1])))
            stack[0] = col
        res.events.append((info.lineno, col, len(stack) - 1))
    return res


# ── concat(): mirror of build_selfhost_native.py:138-158 ────────────────────


def concat(files, read, sep_fmt="// === {f} ===", wrapper_fn=None,
           import_filter=True):
    """Reproduce build_selfhost_native.py's concat() exactly.

    :138-158 (as read at develop@origin e08df3d9):
      * read + .strip() the file
      * drop every line whose lstrip starts with 'import '   (":" + "import")
      * prefix each part with the column-0 separator line
      * '\n\n'.join(parts)
      * optional wrapper line at column 0
    sep_fmt is parameterized so the reverse controls can move the separator's
    column or turn it into non-comment content.
    """
    parts = []
    for f in files:
        content = read(f).strip()
        if not content:
            continue
        if import_filter:
            content = "\n".join(
                line for line in content.splitlines()
                if not line.strip().startswith("import "))
        parts.append(sep_fmt.format(f=f) + "\n" + content)
    src = "\n\n".join(parts)
    if wrapper_fn:
        src += "\n\nfn main() -> int { return %s(); }\n" % wrapper_fn
    return src


def split_concat_lines(files, read, sep_fmt="// === {f} ===",
                       import_filter=True):
    """Return the concatenated text plus, per file, the 1-based line range it
    occupies in the concatenation (used for the depth-trace assertion)."""
    parts = []
    ranges = {}
    line = 1
    for f in files:
        content = read(f).strip()
        if not content:
            continue
        if import_filter:
            content = "\n".join(
                ln for ln in content.splitlines()
                if not ln.strip().startswith("import "))
        text = sep_fmt.format(f=f) + "\n" + content
        n = len(text.split("\n"))
        ranges[f] = (line, line + n - 1)
        line += n + 2   # '\n\n' join
        parts.append(text)
    src = "\n\n".join(parts)
    return src, ranges


# ── source reading ──────────────────────────────────────────────────────────

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class ProbeError(Exception):
    """Hard failure: the probe could not obtain its input.

    Never swallowed into a PASS.  A criterion that finds no input must go RED
    (fail-closed), otherwise a lagging or empty checkout reads as success --
    the "empty shell green" failure mode.
    """


class Reader:
    def __init__(self, rev=None):
        self.rev = rev
        self.cache = {}
        self._file_list = None

    def __call__(self, path):
        if path in self.cache:
            return self.cache[path]
        if self.rev:
            p = subprocess.run(
                ["jj", "file", "show", "-r", self.rev, path],
                cwd=REPO, capture_output=True, text=True)
            if p.returncode != 0:
                raise ProbeError(
                    "cannot read %s at rev %s: %s\n"
                    "  (a stale working copy makes every jj command fail; "
                    "the criterion must NOT pass on missing input)"
                    % (path, self.rev, p.stderr.strip().splitlines()[0]
                       if p.stderr.strip() else "no stderr"))
            txt = p.stdout
        else:
            try:
                with open(os.path.join(REPO, path), encoding="utf-8",
                          errors="replace") as fh:
                    txt = fh.read()
            except OSError as exc:
                raise ProbeError("cannot read %s: %s" % (path, exc))
        self.cache[path] = txt
        return txt

    def list_cr(self, prefixes=("",)):
        """List .cr paths, coherent with the source of the file CONTENTS.

        `prefixes` are literal path prefixes; the default ("",) matches every
        relative path.  With --rev the list comes from `jj file list -r <rev>`,
        NOT from the working tree: a lagging checkout must not silently shrink
        the corpus (the file list and the contents have to come from the same
        revision).
        """
        if self.rev:
            if self._file_list is None:
                p = subprocess.run(
                    ["jj", "file", "list", "-r", self.rev],
                    cwd=REPO, capture_output=True, text=True)
                if p.returncode != 0:
                    raise ProbeError(
                        "cannot list files at rev %s: %s\n"
                        "  (a stale working copy makes every jj command fail)"
                        % (self.rev, p.stderr.strip().splitlines()[0]
                           if p.stderr.strip() else "no stderr"))
                self._file_list = sorted(p.stdout.split("\n"))
            out = []
            for rel in self._file_list:
                if not rel.endswith(".cr"):
                    continue
                if not any(rel.startswith(x) for x in prefixes):
                    continue
                if rel.startswith(("build/", ".jj/", ".core/")):
                    continue
                out.append(rel)
            return sorted(out)
        out = []
        for dp, dn, fn in os.walk(REPO):
            dn[:] = [d for d in dn if d not in (".jj", ".git", "build", ".core")]
            for f in fn:
                if not f.endswith(".cr"):
                    continue
                rel = os.path.relpath(os.path.join(dp, f), REPO)
                if not any(rel.startswith(x) for x in prefixes):
                    continue
                out.append(rel)
        return sorted(out)

    def abspath(self, path):
        return os.path.join(REPO, path)


# ── J-T0-1: concat-layout ───────────────────────────────────────────────────

DEFAULT_FILES = ["src/compiler/project.cr", "src/compiler/dump.cr"]


def cmd_concat_layout(a):
    files = [f.strip() for f in a.files.split(",") if f.strip()]
    read = Reader(a.rev)

    sep = a.sep_fmt
    if a.sep_col:
        sep = (" " * a.sep_col) + sep
    if a.sep_kind == "code":
        # a separator that is NOT comment-only: same shape, no comment marker
        sep = sep.replace("//", "").strip()

    per_file = {}
    for f in files:
        per_file[f] = layout_scan(analyze_text(read(f)),
                                  comment_policy=a.comment_policy)
    expected = sum(r.n_top for r in per_file.values())
    if a.wrapper_fn:
        expected += 1

    src, ranges = split_concat_lines(files, read, sep_fmt=sep,
                                     import_filter=not a.no_import_filter)
    if a.wrapper_fn:
        src += "\n\nfn main() -> int { return %s(); }\n" % a.wrapper_fn

    whole = layout_scan(analyze_text(src), comment_policy=a.comment_policy)

    print("=" * 72)
    print("J-T0-1 concat-layout probe")
    print("=" * 72)
    print("source        : %s" % ("rev " + a.rev if a.rev else "working tree"))
    print("files         : %s" % ", ".join(files))
    print("separator     : %r  (column %d, %s)"
          % (sep, a.sep_col or 0, a.sep_kind))
    print("comment policy: %s" % a.comment_policy)
    print("wrapper       : %s" % (a.wrapper_fn or "(none)"))
    print("-" * 72)
    for f in files:
        print("  %-36s top-level lines = %d" % (f, per_file[f].n_top))
    print("  %-36s expected sum      = %d" % ("", expected))
    print("  %-36s concatenation     = %d" % ("", whole.n_top))
    print("-" * 72)

    a1 = (whole.n_top == expected)
    a2 = (len(whole.errors) == 0)

    print("A1  top-level count preserved ...... %s" % ("PASS" if a1 else "FAIL"))
    print("A2  concatenation is layout-clean .. %s" % ("PASS" if a2 else "FAIL"))
    for (ln, col, msg) in whole.errors:
        print("      line %d col %d: %s" % (ln, col, msg))

    # A3: per-file, not just the total.  A1 compares sums, so a layout bug that
    # adds one top-level line inside file A and drops one inside file B would
    # keep A1 green.  A3 pins each file's own line range.
    a3 = True
    base = whole.top_col if whole.top_col is not None else 0
    for f in files:
        lo, hi = ranges[f]
        got_n = sum(1 for (ln, col, _d) in whole.events
                    if lo <= ln <= hi and col == base)
        want_n = per_file[f].n_top
        if got_n != want_n:
            a3 = False
            print("      %s: %d top-level line(s) in range %d-%d, standalone %d"
                  % (f, got_n, lo, hi, want_n))
    print("A3  per-file counts, not just sum .. %s"
          % ("PASS" if a3 else "FAIL"))

    print("=" * 72)
    ok = a1 and a2 and (a3 is not False)
    print("VERDICT: %s" % ("GREEN" if ok else "RED"))
    return 0 if ok else 1


# ── J-T0-2: semi-resolvers ──────────────────────────────────────────────────

PARSER_FILES = ["src/compiler/parser.cr", "bootstrap/corec/frontend/parser.py"]
SEMI_RE = re.compile(r"\bT_SEMI\b|\bSEMI\b")


def scan_semi_sites(read):
    sites = []
    for f in PARSER_FILES:
        for i, line in enumerate(read(f).split("\n"), start=1):
            code = line.split("//")[0]
            if f.endswith(".py"):
                code = code.split("#")[0]
            if SEMI_RE.search(code):
                sites.append((f, i, line.strip()))
    return sites


SITE_BLOCK_RE = re.compile(
    r"<!--\s*semi-sites\s*-->(.*?)<!--\s*/semi-sites\s*-->", re.S)


def parse_spec_sites(text):
    """Sites the spec claims, for the J-T0-2 coverage assertion.

    Preferred form: an explicit `<!-- semi-sites -->` block, one line per file,
    `path:NNN,NNN,...`.  That form is exact -- no ranges, no prose -- so both
    directions of the comparison (missing / stale) are meaningful.  Falls back
    to scraping `file:line` out of prose when the block is absent.
    """
    out = set()
    m = SITE_BLOCK_RE.search(text)
    if m:
        for line in m.group(1).split("\n"):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if ":" not in line:
                continue
            f, nums = line.rsplit(":", 1)
            for n in nums.split(","):
                n = n.strip()
                if n.isdigit():
                    out.add((f.strip(), int(n)))
        return out
    for m in re.finditer(r"([A-Za-z0-9_./\-]+\.(?:cr|py)):(\d+(?:[,\-]\d+)*)",
                         text):
        f = m.group(1)
        spec = m.group(2)
        for chunk in spec.split(","):
            if "-" in chunk:
                lo, hi = chunk.split("-", 1)
                try:
                    for n in range(int(lo), int(hi) + 1):
                        out.add((f, n))
                except ValueError:
                    continue
            else:
                try:
                    out.add((f, int(chunk)))
                except ValueError:
                    continue
    return out


def cmd_semi_resolvers(a):
    read = Reader(a.rev)
    sites = scan_semi_sites(read)
    if not sites:
        print("PROBE ERROR: no T_SEMI/SEMI occurrence found in %s -- "
              "cannot pass on empty input" % ", ".join(PARSER_FILES))
        return 1
    print("=" * 72)
    print("J-T0-2 ';'-dependent resolver sites")
    print("=" * 72)
    print("source: %s" % ("rev " + a.rev if a.rev else "working tree"))
    cur = None
    for (f, ln, txt) in sites:
        if f != cur:
            print("\n-- %s" % f)
            cur = f
        print("   %5d  %s" % (ln, txt[:96]))
    print("\nTOTAL: %d sites" % len(sites))

    rc = 0
    if a.spec:
        spec = open(a.spec, encoding="utf-8").read()
        listed = parse_spec_sites(spec)
        have = {(f, ln) for (f, ln, _t) in sites}
        missing = sorted(have - listed)
        stale = sorted(
            (f, n) for (f, n) in listed
            if f in PARSER_FILES and (f, n) not in have)
        print("\n-- coverage against %s" % a.spec)
        print("   listed in spec and present : %d" % len(have & listed))
        print("   MISSING from spec          : %d" % len(missing))
        for (f, n) in missing:
            print("       %s:%d" % (f, n))
        print("   spec lines with no site    : %d" % len(stale))
        for (f, n) in stale:
            print("       %s:%d" % (f, n))
        if missing:
            print("   => J-T0-2 INCOMPLETE (a site is not listed)")
            rc = 1
        elif stale:
            print("   => spec references lines that carry no site (line drift?)")
            rc = 1
        else:
            print("   => J-T0-2 list is complete for these two files")
    print("=" * 72)
    return rc


# ── J-T0-4: struct-lit-forms (zero-build half) ──────────────────────────────

STRUCT_DECL_RE = re.compile(
    r"\bstruct\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:\[[^\]]*\])?\s*[{:]")
DECL_PREFIX_RE = re.compile(r"\b(?:struct|enum|impl|interface|for)\s*$")
FIELD_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:")


def parse_struct_table(text):
    """name -> set(field names), from `struct N { f: T, ... }` (v3) or the
    indented `struct N:` block (v4).  This is the 'intersect with the struct
    declaration table' step: it is what separates a real literal from a
    function whose RETURN TYPE happens to end in `{`."""
    table = {}
    for m in STRUCT_DECL_RE.finditer(text):
        name = m.group(1)
        fields = set()
        rest = text[m.end() - 1:]
        if rest.startswith("{"):
            body = rest[1:]
            depth = 1
            end = 0
            for i, ch in enumerate(body):
                if ch == "{":
                    depth += 1
                elif ch == "}":
                    depth -= 1
                    if depth == 0:
                        end = i
                        break
            body = body[:end]
            for part in re.split(r"[,\n]", body):
                fm = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)\s*:", part)
                if fm:
                    fields.add(fm.group(1))
        else:
            # v4 `struct N:` — fields are the following indented `f: T` lines
            lines = rest.split("\n")[1:]
            for ln in lines:
                if ln.strip() == "":
                    continue
                if ln[:1] not in (" ", "\t"):
                    break
                fm = FIELD_RE.match(ln)
                if fm:
                    fields.add(fm.group(1))
        if fields:
            table[name] = fields
    return table


def check_struct_lit_guard(read):
    """Decision ④ reverse half, zero-build part: the field separator of a struct
    literal must be VALIDATED in the parser, not skipped blindly.

    Today: src/compiler/parser.cr:552-554
        ft := advance_tok();
        fni := str_intern(tok_lx(ft));
        advance_tok();            <-- return value dropped: both forms accepted
    Required after T5: a `check(T_EQ)` guard at that position.
    """
    txt = read("src/compiler/parser.cr")
    lines = txt.split("\n")
    anchor = None
    for i, line in enumerate(lines):
        if "fni := str_intern(tok_lx(ft))" in line:
            anchor = i
            break
    if anchor is None:
        return None, ["anchor `fni := str_intern(tok_lx(ft))` not found in "
                      "src/compiler/parser.cr"]
    window = []
    for line in lines[anchor + 1:anchor + 6]:
        code = line.split("//")[0].strip()
        if not code:
            continue
        window.append(code)
        if len(window) >= 3:
            break
    if any("check(T_EQ)" in w for w in window):
        return True, window
    return False, window


def cmd_struct_lit_forms(a):
    read = Reader(a.rev)
    targets = [p for p in read.list_cr()
               if not p.startswith("legacy_asm_backend/")]
    if not targets:
        print("PROBE ERROR: no .cr source found -- cannot pass on empty input")
        return 1

    texts = {}
    struct_table = {}
    for rel in targets:
        txt = read(rel)          # ProbeError propagates: never a silent skip
        texts[rel] = txt
        struct_table.update(parse_struct_table(txt))

    eq_hits, co_hits = {}, {}
    for rel, txt in texts.items():
        if a.subset and not any(rel.startswith(s) for s in a.subset):
            continue
        lines = txt.split("\n")
        stripped = analyze_text(txt)
        for i, line in enumerate(lines):
            for m in re.finditer(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\{", line):
                name = m.group(1)
                if name not in struct_table:
                    continue
                info = stripped[i]
                if info.first_token_col is None:
                    continue
                # ignore matches inside comments
                cstart = info.first_comment_col
                if cstart is not None and m.start() >= cstart:
                    continue
                pre = line[:m.start()]
                # ignore the DECLARATION form: `struct Name {`, `impl Tr for Name {`
                if DECL_PREFIX_RE.search(pre):
                    continue
                # ignore a RETURN TYPE that happens to end in `{` (the body brace)
                if pre.rstrip().endswith("->"):
                    continue
                fname, sep = _first_field(lines, i, m.end())
                # the plan's method: intersect with the struct declaration table
                if fname is None or fname not in struct_table[name]:
                    continue
                if sep == "=":
                    eq_hits.setdefault(rel, []).append(i + 1)
                elif sep == ":":
                    co_hits.setdefault(rel, []).append(i + 1)

    def show(label, hits):
        n = sum(len(v) for v in hits.values())
        print("\n%s form: %d site(s) in %d file(s)" % (label, n, len(hits)))
        for rel in sorted(hits):
            print("   %-52s %s" % (rel, hits[rel]))
        return n

    print("=" * 72)
    print("J-T0-4 struct-literal forms (zero-build half)")
    print("=" * 72)
    print("source    : %s" % ("rev " + a.rev if a.rev else "working tree"))
    print("method    : strip comments/strings, brace-scan each 'Name {' whose")
    print("            Name is a declared struct, read its first field's")
    print("            separator (multi-line aware)")
    print("structs   : %d declared name(s) with a parsed field list"
          % len(struct_table))
    n_eq = show("'='", eq_hits)
    n_co = show("':'", co_hits)
    print("\nTOTAL: %d site(s)" % (n_eq + n_co))

    rc = 0
    if a.form:
        want = eq_hits if a.form == "eq" else co_hits
        other_label = "':'" if a.form == "eq" else "'='"
        bad = {k: v for k, v in (co_hits if a.form == "eq" else eq_hits).items()
               if a.allow_file not in k}
        if bad:
            print("\nFAIL: selected form is '%s' but the unselected %s form is"
                  % (a.form, other_label))
            print("      still present outside the negative-probe file:")
            for k in sorted(bad):
                print("        %-52s %s" % (k, bad[k]))
            rc = 1
        else:
            print("\nPASS: unselected %s form is absent outside %s"
                  % (other_label, a.allow_file))
    if a.require_guard:
        ok, window = check_struct_lit_guard(read)
        print("\n-- decision ④ reverse half, zero-build part: separator guard")
        for w in (window or []):
            print("     %s" % w)
        if ok is None:
            print("   => anchor not found; probe needs updating")
            rc = 1
        elif ok:
            print("   => PASS: the struct-literal field separator is validated")
        else:
            print("   => FAIL: the separator is still skipped blindly "
                  "(both forms accepted); T5 must add `check(T_EQ)`")
            rc = 1
    print("=" * 72)
    return rc


def _first_field(lines, i, start_col):
    """From start_col on line i, find the first `name <sep>`; return (name, sep)."""
    pat = re.compile(r"\s*([A-Za-z_][A-Za-z0-9_]*)\s*(:=|[=:])")
    m = pat.match(lines[i], start_col)
    if m:
        return m.group(1), m.group(2)[-1]
    for j in range(i + 1, min(i + 40, len(lines))):
        s = lines[j].strip()
        if not s:
            continue
        m = re.match(r"([A-Za-z_][A-Za-z0-9_]*)\s*(:=|[=:])", s)
        if m:
            return m.group(1), m.group(2)[-1]
        if s[0] in "}/":
            return None, None
    return None, None


# ── J-T0-5: tokenize-sites (static half) ────────────────────────────────────

TOKENIZE_RE = re.compile(r"tokenize\s*\(")


def cmd_tokenize_sites(a):
    """J-T0-5 static half, with the scope breakdown the count depends on.

    The count is scope-sensitive, so report every scope explicitly:
      raw lines matching in src/compiler/*.cr       (includes def + comments)
      - the definition line
      - pure comment mentions
      = real call sites in src/compiler/
      + real call sites elsewhere under src/ (src/lsp/lsp.cr)
      = real call sites in src/**
    """
    read = Reader(a.rev)
    hits = []
    mentions = []
    raw = 0
    srcs = read.list_cr(("src/",))
    if not srcs:
        print("PROBE ERROR: no .cr source under src/ -- "
              "cannot pass on empty input")
        return 1
    for rel in srcs:
        for i, line in enumerate(read(rel).split("\n"), start=1):
            if not TOKENIZE_RE.search(line):
                continue
            if rel.startswith("src/compiler/"):
                raw += 1
            code = line.split("//")[0]
            if not TOKENIZE_RE.search(code):
                mentions.append((rel, i, "COMMENT", line.strip()))
                continue
            if re.search(r"fn\s+tokenize\s*\(", code):
                kind = "DEFINITION"
            else:
                kind = "call"
            hits.append((rel, i, kind, line.strip()))

    if not hits:
        print("PROBE ERROR: no tokenize() found under src/ -- "
              "cannot pass on empty input")
        return 1

    print("=" * 72)
    print("J-T0-5 tokenize() call sites (static half)")
    print("=" * 72)
    print("source: %s" % ("rev " + a.rev if a.rev else "working tree"))
    calls = [h for h in hits if h[2] == "call"]
    defs = [h for h in hits if h[2] == "DEFINITION"]
    for (rel, ln, kind, txt) in sorted(hits + mentions):
        print("  %-10s %-32s %5d  %s" % (kind, rel, ln, txt[:68]))
    c_compiler = [h for h in calls if h[0].startswith("src/compiler/")]
    c_other = [h for h in calls if not h[0].startswith("src/compiler/")]
    print("")
    print("  raw lines matching in src/compiler/*.cr : %d" % raw)
    print("  minus definition line(s)                : %d" % len(defs))
    print("  minus pure comment mention(s)           : %d" % len(mentions))
    print("  = real calls in src/compiler/           : %d" % len(c_compiler))
    for (rel, ln, _k, _t) in c_other:
        print("  + real call elsewhere (%s:%d)" % (rel, ln))
    print("  = real calls in src/**                  : %d" % len(calls))

    rc = 0
    if a.require_bypass:
        holes = [h for h in calls if h[0] == "src/compiler/parser.cr"]
        ok = all(a.require_bypass in h[3] for h in holes)
        print("\nbypass flag %r threaded at the hole call site(s): %s"
              % (a.require_bypass, "YES" if ok else "NO"))
        for (rel, ln, _k, txt) in holes:
            print("    %s:%d  %s" % (rel, ln, txt[:70]))
        if not ok:
            print("    => hole re-entry still tokenizes with the ambient layout")
            print("       state (J-T0-5 零构建半 NOT satisfied)")
            rc = 1
    print("=" * 72)
    return rc


# ── CLI ─────────────────────────────────────────────────────────────────────


def blank_comments(text):
    """Return `text` with every comment character replaced by a space.

    Offsets and line numbers are preserved exactly, so callers can keep using
    the original 1-based line numbers.  Nesting block comments (v4 §1.1) and
    string/char literals are handled; a newline inside a block comment is kept
    so line counting stays correct.
    """
    out = list(text)
    n = len(text)
    i = 0
    depth = 0
    while i < n:
        c = text[i]
        if depth > 0:
            if c == "*" and i + 1 < n and text[i + 1] == "/":
                out[i] = out[i + 1] = " "
                depth -= 1
                i += 2
                continue
            if c == "/" and i + 1 < n and text[i + 1] == "*":
                out[i] = out[i + 1] = " "
                depth += 1
                i += 2
                continue
            if c != "\n":
                out[i] = " "
            i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                out[i] = " "
                i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            out[i] = out[i + 1] = " "
            depth = 1
            i += 2
            continue
        if c == '"' or c == "'":
            quote = c
            i += 1
            while i < n:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == quote:
                    i += 1
                    break
                if text[i] == "\n":
                    break
                i += 1
            continue
        i += 1
    return "".join(out)


# ── decision ② : ':' position classification ────────────────────────────────

# A line-end ':' opens a region iff the line is one of these headers.
LINE_END_OPENER = "LINE_END/region-opener"
LINE_END_CANDIDATE = "LINE_END/CANDIDATE-ANNOTATION"
LINE_INTERNAL = "LINE_INTERNAL/annotation"

COLON_OPEN_KW = re.compile(
    r"^(?:pub\s+)?(?:fn|if|else|elif|loop|while|for|match|struct|enum|impl|"
    r"interface|unsafe|catch|flow|go|spec|extern)\b")
COLON_LAMBDA = re.compile(r":=\s*fn\s*\(")
# a header is still open after a line that ends with one of these
COLON_CONT = ("->", ",", ":", "(", "[", "=")


def _balanced(s):
    depth = 0
    for ch in s:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
            if depth < 0:
                return False
    return depth == 0


def classify_colons(text, skip_comments=True):
    """Classify every ':' token in comment/string-stripped text.

    Excluded (not ':' tokens at all): the second char of '::' (path separator)
    and the first char of ':=' (declaration/binding operator).

    A line-end ':' is a region opener iff it terminates a REGION HEADER.  That
    needs cross-line state, because a header's terminator can land on a
    continuation line (`fn f(a: int,\\n     b: int):`).  A header is open while
    its accumulated text has unbalanced brackets or ends with a continuation
    character; a signature-only declaration (`extern fn read(...) -> int`)
    closes it with no terminator.

    skip_comments=False is the reverse control for the trailing-comment clause:
    a comment then counts as a following token, so `fn f(): // note` is
    misclassified as line-internal.
    """
    code = blank_comments(text) if skip_comments else text
    out = []
    in_header = False
    hdr = ""
    for idx, line in enumerate(code.split("\n"), start=1):
        head = line.strip()
        if not head:
            continue
        positions = []
        for i, ch in enumerate(line):
            if ch != ":":
                continue
            if i + 1 < len(line) and line[i + 1] in ":=":
                continue
            if i > 0 and line[i - 1] == ":":
                continue
            positions.append(i)
        if COLON_OPEN_KW.match(head) or COLON_LAMBDA.search(head):
            if not in_header:
                in_header = True
                hdr = ""
        for i in positions:
            if line[i + 1:].strip():
                out.append((idx, i, LINE_INTERNAL, head))
                continue
            acc = (hdr + " " + line[:i]).strip()
            if in_header and _balanced(acc):
                out.append((idx, i, LINE_END_OPENER, head))
                in_header = False
                hdr = ""
            else:
                out.append((idx, i, LINE_END_CANDIDATE, head))
        if in_header:
            hdr = (hdr + " " + head).strip()
            if _balanced(hdr) and not hdr.rstrip().endswith(COLON_CONT):
                in_header = False      # signature-only declaration: no terminator
                hdr = ""
    return out


# In-memory fixtures (no files written -- same discipline as
# tests/harness/test_criteria_mutations.py).  Each entry:
#   (label, source, [expected classification of each ':' in source order])
COLON_FIXTURES = [
    ("fn header", "fn add(a: int, b: int) -> int:\n    return a + b\n",
     [LINE_INTERNAL, LINE_INTERNAL, LINE_END_OPENER]),
    ("fn header, inferred ret", "fn add_inferred(a: int, b: int):\n    return a\n",
     [LINE_INTERNAL, LINE_INTERNAL, LINE_END_OPENER]),
    ("spec fn header", "spec fn valid(x: int) -> bool:\n    return true\n",
     [LINE_INTERNAL, LINE_END_OPENER]),
    ("lambda header", "f := fn(x: int) -> int:\n    return x\n",
     [LINE_INTERNAL, LINE_END_OPENER]),
    ("match header", "match x:\n | A => a\n", [LINE_END_OPENER]),
    ("catch header", "catch:\n | E => recover()\n", [LINE_END_OPENER]),
    ("struct header", "struct User:\n    id: int\n", [LINE_END_OPENER, LINE_INTERNAL]),
    ("enum header", "enum Mode:\n | Server\n", [LINE_END_OPENER]),
    ("impl header", "impl Eq for Point:\n    fn eq(&self, o: &Self) -> bool\n",
     [LINE_END_OPENER, LINE_INTERNAL]),
    ("var annotation", "x : int = 5\n", [LINE_INTERNAL]),
    ("tag form", "count : int, mut = 0\n", [LINE_INTERNAL]),
    ("batch form", "a, b : int = 1, 2\n", [LINE_INTERNAL]),
    ("mod path is not a ':' token", "mod examples::pi\n", []),
    ("import alias", "import math : m\n", [LINE_INTERNAL]),
    ("param list, multi-line", "fn f(a: int,\n     b: int):\n    return a\n",
     [LINE_INTERNAL, LINE_INTERNAL, LINE_END_OPENER]),
    # ── the trailing-comment clause (ruling, connected consequence 2) ──
    ("fn header + trailing comment", "fn f(): // note\n    return 0\n",
     [LINE_END_OPENER]),
    ("annotation + trailing comment", "x : int = 5 // note\n", [LINE_INTERNAL]),
    ("fn header + block comment", "fn f(): /* note */\n    return 0\n",
     [LINE_END_OPENER]),
    ("fn header + cross-line block comment",
     "fn f(): /* note\n still note */\n    return 0\n", [LINE_END_OPENER]),
]

# Known-bad inputs, used only by the reverse controls (must turn the
# criterion red).  Same discipline as test_criteria_mutations.py.
COLON_BAD_FIXTURES = [
    ("annotation split across lines", "x :\n    int = 5\n"),
    ("field annotation split", "struct User:\n    id:\n        int\n"),
    ("param annotation split", "fn f(a:\n     int):\n    return a\n"),
]


def cmd_colon_positions(a):
    read = Reader(a.rev)
    rc = 0
    print("=" * 72)
    print("J-T0-2b ':' position classification (decision ②, ruling (b))")
    print("=" * 72)
    print("skip trailing comment when judging line-end: %s"
          % ("YES" if a.skip_trailing_comment else "NO (reverse control)"))
    if a.mutate:
        print("mutation injected: %s" % a.mutate)

    # A1: the fixture table
    print("\n-- A1 in-memory v4 fixtures (expected label per ':')")
    bad = 0
    for (label, src, want) in COLON_FIXTURES:
        got = classify_colons(src, a.skip_trailing_comment)
        if len(got) != len(want):
            bad += 1
            print("   FAIL %-38s %d ':' found, %d expected"
                  % (label, len(got), len(want)))
            continue
        for (entry, exp) in zip(got, want):
            (ln, col, kind, txt) = entry
            if kind != exp:
                bad += 1
                print("   FAIL %-38s line %d col %d: got %s want %s | %s"
                      % (label, ln, col, kind, exp, txt))
    if bad == 0:
        print("   PASS: every fixture's ':' carries its expected label "
              "(%d fixtures, %d ':' tokens)"
              % (len(COLON_FIXTURES),
                 sum(len(w) for (_l, _s, w) in COLON_FIXTURES)))
    else:
        print("   FAIL: %d fixture mismatch(es)" % bad)
        rc = 1

    # A2: zero annotation-at-line-end over the scanned corpus (+ injection)
    print("\n-- A2 zero annotation-at-line-end")
    if a.fixture_only:
        srcs = [(label, src) for (label, src, _w) in COLON_FIXTURES]
    else:
        rels = read.list_cr()
        if not rels:
            print("PROBE ERROR: no .cr source found -- "
                  "cannot pass on empty input")
            return 1
        srcs = [(rel, read(rel)) for rel in rels]   # ProbeError propagates
    if a.mutate == "annotation-line-end":
        srcs = list(srcs) + list(COLON_BAD_FIXTURES)
    n_end = n_open = n_cand = 0
    for (rel, src) in srcs:
        for (ln, col, kind, txt) in classify_colons(src, a.skip_trailing_comment):
            if kind == LINE_END_OPENER:
                n_open += 1
            elif kind == LINE_END_CANDIDATE:
                n_cand += 1
                print("   CANDIDATE %s:%d  %s" % (rel, ln, txt))
            else:
                n_end += 1
    print("   scanned: %d source(s)" % len(srcs))
    print("   LINE_INTERNAL ':'      : %d" % n_end)
    print("   LINE_END/region-opener : %d" % n_open)
    print("   LINE_END/CANDIDATE     : %d" % n_cand)
    if n_cand:
        print("   => FAIL: a declaration annotation has its ':' at line end;")
        print("      decision ②-1 forbids this (T4/T5 must reflow or reject)")
        rc = 1
    else:
        print("   => PASS: every line-end ':' is a region opener")
    print("=" * 72)
    return rc


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="v4 layout probe (zero-build criteria)")
    ap.add_argument("--rev", default=None,
                    help="read sources at this revision via jj file show")
    # also accepted after the subcommand; SUPPRESS keeps the top-level value
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--rev", default=argparse.SUPPRESS,
                        help="read sources at this revision via jj file show")
    sub = ap.add_subparsers(dest="cmd")

    p1 = sub.add_parser("concat-layout", help="J-T0-1", parents=[common])
    p1.add_argument("--files", default=",".join(DEFAULT_FILES))
    p1.add_argument("--sep-col", type=int, default=0,
                    help="column of the separator line (reverse control)")
    p1.add_argument("--sep-kind", choices=["comment", "code"], default="comment")
    p1.add_argument("--sep-fmt", default="// === {f} ===")
    p1.add_argument("--comment-policy", choices=["noop", "participate"],
                    default="noop")
    p1.add_argument("--wrapper-fn", default=None)
    p1.add_argument("--no-import-filter", action="store_true")
    p1.set_defaults(func=cmd_concat_layout)

    p2 = sub.add_parser("semi-resolvers", help="J-T0-2", parents=[common])
    p2.add_argument("--spec", default=None,
                    help="spec file; enables the coverage assertion")
    p2.set_defaults(func=cmd_semi_resolvers)

    p3 = sub.add_parser("struct-lit-forms", help="J-T0-4 (zero-build half)",
                        parents=[common])
    p3.add_argument("--form", choices=["eq", "colon"], default=None,
                    help="selected form; enables 'unselected form absent'")
    p3.add_argument("--allow-file", default="tests/harness/negative_",
                    help="path prefix exempt from the absence assertion")
    p3.add_argument("--subset", action="append", default=None,
                    help="restrict to a path prefix (repeatable)")
    p3.add_argument("--require-guard", action="store_true",
                    help="also assert the parser validates the field separator")
    p3.set_defaults(func=cmd_struct_lit_forms)

    p4 = sub.add_parser("tokenize-sites", help="J-T0-5 (static half)",
                        parents=[common])
    p4.add_argument("--require-bypass", default=None,
                    help="flag name that must appear at the hole call site")
    p4.set_defaults(func=cmd_tokenize_sites)

    p5 = sub.add_parser("colon-positions", help="J-T0-2b (decision ②)",
                        parents=[common])
    p5.add_argument("--skip-trailing-comment", action="store_true",
                    default=True, help="default: trailing comments are skipped")
    p5.add_argument("--no-skip-trailing-comment", dest="skip_trailing_comment",
                    action="store_false",
                    help="reverse control: count a trailing comment as a token")
    p5.add_argument("--mutate", choices=["annotation-line-end"], default=None,
                    help="reverse control: inject a known-bad input")
    p5.add_argument("--fixture-only", action="store_true",
                    help="scan only the in-memory fixtures, not the corpus")
    p5.set_defaults(func=cmd_colon_positions)

    a = ap.parse_args(argv)
    if not getattr(a, "rev", None):
        a.rev = None
    if not getattr(a, "func", None):
        ap.print_help()
        return 2
    try:
        return a.func(a)
    except ProbeError as exc:
        print("PROBE ERROR: %s" % exc)
        print("=> rc=1 (fail-closed: a criterion must never pass on "
              "unreadable or empty input)")
        return 1


if __name__ == "__main__":
    sys.exit(main())
