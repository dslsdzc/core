// === diag.cr ===
// Rust-style error diagnostics for the Core compiler.
// Uses g_diags, g_diag_count (from ast.cr) and g_errors, g_error_count (from lexer.cr).

// ─── helpers ────────────────────────────────────────────────────

fn read_source_line(line: int) -> string:
    // Every parsed line belongs to a SourceManager file. Manifest lines have no
    // fileid and resolve through the line-range fallback.
    sm : ., mut = file_sm_id(diag_fileid_for_line(line))
    if sm < 0:
        sm = sm_for_line(line)
    if sm < 0:
        return ""
    local := line - sm_file_line_base(sm)
    return sm_line_text(sm, local)

fn print_source_text(line: int, col: int, ltxt: string, annotation: string):
    if line <= 0:
        return
    if str_len(ltxt) == 0:
        return
    ln_str : ., mut = int_str(line)
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
            c := cell_load_byte(annotation, ci2)
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

// Render a line through the SourceManager line map. Used when a diagnostic has
// no source span.
fn print_source_line(line: int, col: int, annotation: string):
    if line <= 0:
        return
    print_source_text(line, col, read_source_line(line), annotation)

fn error_cat_prefix(cat: int) -> string:
    return match cat:
        1 => "P"
        2 => "N"
        3 => "I"
        4 => "TA"
        5 => "TF"
        6 => "TB"
        7 => "TU"
        8 => "TC"
        9 => "TM"
        10 => "TK"
        11 => "TS"
        12 => "TG"
        13 => "B"
        14 => "R"
        15 => "E"
        16 => "ICE"
        17 => "V"   // 规约语法与校验
        _ => "E"

fn pad_diag_num(num: int) -> string:
    s : ., mut = int_str(num)
    if num < 10:
        s = "0" + s
    return s

// ─── diagnostics (g_diags) ─────────────────────────────────────

// Line number to file id. -1 is out of range.
fn diag_fileid_for_line(line: int) -> int:
    return fileid_of_line(line)

fn print_diagnostics():
    if g_diag_count == 0:
        return
    di : ., mut = 0
    loop:
        if di >= g_diag_count:
            break
        ec := cell_load(g_diags, di * DIAG_REC_SIZE)
        msg := cell_load_str(g_diags, di * DIAG_REC_SIZE + 8)
        ln := cell_load(g_diags, di * DIAG_REC_SIZE + 16)
        cl := cell_load(g_diags, di * DIAG_REC_SIZE + 24)
        smf := cell_load(g_diags, di * DIAG_REC_SIZE + 40)
        slo := cell_load(g_diags, di * DIAG_REC_SIZE + 48)
        pln : ., mut = ln
        pcl : ., mut = cl
        pltext : ., mut = ""
        attributed : ., mut = 0
        path_txt : ., mut = ""
        if smf >= 0 && smf < sm_file_count():
            pln = sm_location_line(smf, slo)
            pcl = sm_location_col(smf, slo)
            pltext = sm_line_text(smf, pln)
            if smf != g_main_sm:
                path_txt = sm_file_path(smf)
            if str_len(pltext) > 0:
                attributed = 1
        else:
            fni := diag_fileid_for_line(ln)
            sm : ., mut = file_sm_id(fni)
            if sm < 0:
                sm = sm_for_line(ln)
            if sm >= 0:
                pln = ln - sm_file_line_base(sm)
                pcl = cl
                pltext = sm_line_text(sm, pln)
                if sm != g_main_sm:
                    path_txt = sm_file_path(sm)
                if str_len(pltext) > 0:
                    attributed = 1
        cat : ., mut = ec / 1000
        num : ., mut = ec % 1000
        print("error[")
        print(error_cat_prefix(cat))
        print(pad_diag_num(num))
        print("]: ")
        println(msg)
        print(" --> ")
        if str_len(path_txt) > 0:
            print(path_txt)
            print(":")
        print(int_str(pln))
        print(":")
        println(int_str(pcl))
        if attributed != 0:
            println("   |")
            print_source_text(pln, pcl, pltext, msg)
        else if ln > 0:
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
        println("error: " + istr_get(cell_load(g_errors, ei2 * 8)))
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
