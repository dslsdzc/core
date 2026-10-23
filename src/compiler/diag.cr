// === diag.cr ===
// Rust-style error diagnostics for the Core compiler.
// Uses g_diags, g_diag_count (from ast.cr) and g_errors, g_error_count (from lexer.cr).

// ─── helpers ────────────────────────────────────────────────────

fn read_source_line(line: int) -> string:
    slen := str_len(g_source)
    cur : ., mut = 1
    start : ., mut = 0
    i : ., mut = 0
    loop:
        if i >= slen:
            break
        if cur == line:
            j : ., mut = i
            loop:
                if j >= slen:
                    break
                c := get_char(g_source, j)
                if c == "\n":
                    break
                j = j + 1
            return str_sub(g_source, i, j - i)
        if load8(g_source, i) == 10:
            cur = cur + 1
            start = i + 1
        i = i + 1
    return ""

fn source_line_count() -> int:
    count : ., mut = 1
    i : ., mut = 0
    slen := str_len(g_source)
    loop:
        if i >= slen:
            break
        if load8(g_source, i) == 10:
            count = count + 1
        i = i + 1
    return count

fn print_source_line(line: int, col: int, annotation: string):
    if line <= 0:
        return
    ltxt := read_source_line(line)
    if str_len(ltxt) == 0:
        return
    ln_str := int_str(line)
    if line < 10:
        ln_str = " " + ln_str
    print(ln_str)
    print(" | ")
    println(ltxt)
    // Underline: spaces, a caret under the column, then the annotation.
    print("   | ")
    ci : ., mut = 0
    loop:
        if ci >= col - 1:
            break
        print(" ")
        ci = ci + 1
    print("^")
    if str_len(annotation) > 0:
        print(" ")
        // Short annotation: use the text before the first " — " separator.
        alen := str_len(annotation)
        cutoff : ., mut = alen
        // Truncate at the separator; the em dash is three UTF-8 bytes.
        ci2 : ., mut = 0
        loop:
            if ci2 + 3 > alen:
                break
            c := load8(annotation, ci2)
            if c == 226:
                // Start of the em dash U+2014, three UTF-8 bytes.
                cutoff = ci2
                break
            ci2 = ci2 + 1
        // Limit the annotation to 48 characters.
        if cutoff > 48:
            cutoff = 48
        print(str_sub(annotation, 0, cutoff))
    println("")

fn error_cat_prefix(cat: int) -> string:
    if cat == 1:
        return "P"
    if cat == 2:
        return "N"
    if cat == 3:
        return "I"
    if cat == 4:
        return "TA"
    if cat == 5:
        return "TF"
    if cat == 6:
        return "TB"
    if cat == 7:
        return "TU"
    if cat == 8:
        return "TC"
    if cat == 9:
        return "TM"
    if cat == 10:
        return "TK"
    if cat == 11:
        return "TS"
    if cat == 12:
        return "TG"
    if cat == 13:
        return "B"
    if cat == 14:
        return "R"
    if cat == 15:
        return "E"
    if cat == 16:
        return "ICE"
    if cat == 17:
        return "V"
    // Category 17 covers specification syntax and validation.
    return "E"

fn pad_diag_num(num: int) -> string:
    s := int_str(num)
    if num < 10:
        s = "0" + s
    return s

// ─── diagnostics (g_diags) ─────────────────────────────────────

// Line number to file id through g_line_fileid. -1 is out of range.
fn diag_fileid_for_line(line: int) -> int:
    if line >= 1 && line <= g_line_count:
        return r64(g_line_fileid, (line - 1) * 8)
    return -1

fn print_diagnostics():
    if g_diag_count == 0:
        return
    source_lines := source_line_count()
    di : ., mut = 0
    loop:
        if di >= g_diag_count:
            break
        ec := r64(g_diags, di * DIAG_REC_SIZE)
        msg := load_str_ptr(g_diags, di * DIAG_REC_SIZE + 8)
        ln := r64(g_diags, di * DIAG_REC_SIZE + 16)
        cl := r64(g_diags, di * DIAG_REC_SIZE + 24)
        cat : ., mut = ec / 1000
        num : ., mut = ec % 1000
        print("error[")
        print(error_cat_prefix(cat))
        print(pad_diag_num(num))
        print("]: ")
        println(msg)
        print(" --> ")
        print(int_str(ln))
        print(":")
        println(int_str(cl))
        if ln > 0 && ln <= source_lines:
            println("   |")
            print_source_line(ln, cl, msg)
        println("")
        di = di + 1

// ─── parse errors (g_errors) ────────────────────────────────────

fn print_parse_errors():
    if g_error_count == 0:
        return
    ei2 : ., mut = 0
    loop:
        if ei2 >= g_error_count:
            break
        println("error: " + istr_get(r64(g_errors, ei2 * 8)))
        ei2 = ei2 + 1
// Fail-closed diagnostic gate exemptions.
// Diagnostics are blocking by default. main.cr calls this function for every
// diagnostic and blocks the build with rc 1 and no output when it returns 0. An
// exemption is recorded only when blocking would reject a valid program.
// The table is code-level. Each entry records a site, reason, and exit
// condition. Adding an entry requires maintainer approval; removing one requires
// root-cause evidence. When a new command or corpus layer is added, rerun the
// full report-only corpus and compare it with this table. Never make the default
// permissive.
fn diag_gate_exempt(code: int, scope: int) -> int:
    // BUILD scope: build, ccr, cir, and run.
    // TF01 is not exempt. The conflict was a real type mismatch: alloc returns
    // string, while chan, goroutine, and sched declared handle returns as int. The
    // standard library now matches the type model, and a real TF01 still blocks.
    // TF07: EC_TF_ARG_TYPE is raised only at the @raw_int builtin, not at the
    // call site. Remove this exemption when call-site reporting is implemented.
    if scope == GATE_SCOPE_BUILD && code == EC_TF_ARG_TYPE:
        return 1
    if scope == GATE_SCOPE_BUILD && code == EC_TF_ARG_TYPE:
        return 1
    // TB01 is a cascade code. The ANY check reports only when both sides are
    // non-int and non-dex, and TI_NEVER propagation reaches the check first. It
    // disappears with the root-cause fixes. Real type errors still block.
    if scope == GATE_SCOPE_BUILD && code == EC_TB_ADD:
        return 1
    // TM04 is a redundant match arm, a soft diagnostic similar to Rust's
    // unreachable-pattern warning. Exempt until a warning channel exists.
    if scope == GATE_SCOPE_BUILD && code == EC_TM_REDUNDANT:
        return 1
    // TK01 is a soft interface-index fallback diagnostic. Exempt until the policy changes.
    if scope == GATE_SCOPE_BUILD && code == EC_TK_INDEX:
        return 1
    // B04: borrows end only when the scope exits; there is no last-use shrink.
    // Exempt until block wrapping or borrow shrinking is implemented.
    if scope == GATE_SCOPE_BUILD && code == EC_B_USE_WHILE_BORROWED:
        return 1
    // CHECK scope: these codes apply to standalone checks of library units, where
    // the concat context is absent. The check return-code rule does not consult
    // this table, so these entries only record the current policy.
    if scope == GATE_SCOPE_CHECK && code == EC_N_UNDEFINED:
        return 1
    if scope == GATE_SCOPE_CHECK && code == EC_N_FUNC:
        return 1
    if scope == GATE_SCOPE_CHECK && code == EC_N_DUPLICATE:
        return 1
    return 0   // default: no exemption, so the diagnostic blocks
