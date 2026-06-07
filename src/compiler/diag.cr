// === diag.cr ===
// Rust-style error diagnostics for the Core compiler.
// Uses g_diags, g_diag_count (from ast.cr) and g_errors, g_error_count (from lexer.cr).

// ─── helpers ────────────────────────────────────────────────────

fn read_source_line(line: int) -> string {
    slen := __builtin_str_len(g_source);
    cur : ., mut = 1;
    start : ., mut = 0;
    i : ., mut = 0;
    loop {
        if i >= slen { break; }
        if cur == line {
            j : ., mut = i;
            loop {
                if j >= slen { break; }
                c := __builtin_str_get(g_source, j);
                if c == "\n" { break; }
                j = j + 1;
            }
            return __builtin_str_sub(g_source, i, j - i);
        }
        if __builtin_str_get(g_source, i) == "\n" {
            cur = cur + 1;
            start = i + 1;
        }
        i = i + 1;
    }
    return "";
}

fn print_source_line(line: int, col: int, annotation: string) {
    if line <= 0 { return; }
    ltxt := read_source_line(line);
    if __builtin_str_len(ltxt) == 0 { return; }
    ln_str := __builtin_int_to_str(line);
    if line < 10 { ln_str = " " + ln_str; }
    __builtin_print(ln_str);
    __builtin_print(" | ");
    __builtin_println(ltxt);
    // underline: spaces + ^ under the column + annotation
    __builtin_print("   | ");
    ci : ., mut = 0;
    loop {
        if ci >= col - 1 { break; }
        __builtin_print(" ");
        ci = ci + 1;
    }
    __builtin_print("^");
    if __builtin_str_len(annotation) > 0 {
        __builtin_print(" ");
        // Short annotation: first line or up to first " — "
        alen := __builtin_str_len(annotation);
        cutoff : ., mut = alen;
        // Truncate at ' — ' (3 bytes in UTF-8: em dash = 3 bytes)
        ci2 : ., mut = 0;
        loop {
            if ci2 + 3 > alen { break; }
            c := __builtin_load8(annotation, ci2);
            if c == 226 {  // start of em dash (— = U+2014, 3 bytes)
                cutoff = ci2;
                break;
            }
            ci2 = ci2 + 1;
        }
        // Limit to 48 chars max
        if cutoff > 48 { cutoff = 48; }
        __builtin_print(__builtin_str_sub(annotation, 0, cutoff));
    }
    __builtin_println("");
}

fn error_cat_prefix(cat: int) -> string {
    if cat == 1 { return "P"; }
    if cat == 2 { return "N"; }
    if cat == 3 { return "I"; }
    if cat == 4 { return "TA"; }
    if cat == 5 { return "TF"; }
    if cat == 6 { return "TB"; }
    if cat == 7 { return "TU"; }
    if cat == 8 { return "TC"; }
    if cat == 9 { return "TM"; }
    if cat == 10 { return "TK"; }
    if cat == 11 { return "TS"; }
    if cat == 12 { return "TG"; }
    if cat == 13 { return "B"; }
    if cat == 14 { return "R"; }
    if cat == 15 { return "E"; }
    if cat == 16 { return "ICE"; }
    return "E";
}

fn pad_diag_num(num: int) -> string {
    s := __builtin_int_to_str(num);
    if num < 10 { s = "0" + s; }
    return s;
}

// ─── diagnostics (g_diags) ─────────────────────────────────────

fn print_diagnostics() {
    if g_diag_count == 0 { return; }
    di : ., mut = 0;
    loop {
        if di >= g_diag_count { break; }
        d := g_diags[di];
        ec := d.code;
        cat : ., mut = ec / 1000;
        num : ., mut = ec % 1000;
        __builtin_print("error[");
        __builtin_print(error_cat_prefix(cat));
        __builtin_print(pad_diag_num(num));
        __builtin_print("]: ");
        __builtin_println(d.msg);
        __builtin_print(" --> ");
        __builtin_print(__builtin_int_to_str(d.line));
        __builtin_print(":");
        __builtin_println(__builtin_int_to_str(d.col));
        if d.line > 0 {
            __builtin_println("   |");
            print_source_line(d.line, d.col, d.msg);
        }
        __builtin_println("");
        di = di + 1;
    }
}

// ─── parse errors (g_errors) ────────────────────────────────────

fn print_parse_errors() {
    if g_error_count == 0 { return; }
    ei2 : ., mut = 0;
    loop {
        if ei2 >= g_error_count { break; }
        __builtin_println("error: " + g_errors[ei2]);
        ei2 = ei2 + 1;
    }
}
