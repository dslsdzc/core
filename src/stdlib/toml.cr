// === toml.cr ===
// Minimal TOML parser for Core.toml configuration.
//
// Supported keys:
//   [project]
//   name = "myapp"
//
//   [target]
//   format = "linux-elf"
//
//   [memory]
//   stack_size = 1048576
//   heap_size  = 268435456
//   text_base  = 4194304    # 0x400000
//   data_base  = 6291456    # 0x600000

// --- low-level helpers ---

fn _skip_whitespace(content: string, pos: int) -> int {
    slen := str_len(content);
    p : ., mut = pos;
    loop {
        if p >= slen { break; }
        ch := get_char(content, p);
        if ch != " " && ch != "\t" { break; }
        p = p + 1;
    }
    return p;
}

fn _is_at_line_start(content: string, pos: int) -> bool {
    if pos == 0 { return true; }
    prev := get_char(content, pos - 1);
    return prev == "\n";
}

fn _skip_to_next_line(content: string, pos: int) -> int {
    slen := str_len(content);
    p : ., mut = pos;
    loop {
        if p >= slen { break; }
        if get_char(content, p) == "\n" { return p + 1; }
        p = p + 1;
    }
    return slen;
}

fn _next_line_start(content: string, pos: int) -> int {
    slen := str_len(content);
    i : ., mut = pos;
    loop {
        if i >= slen { return slen; }
        if get_char(content, i) == "\n" { return i + 1; }
        i = i + 1;
    }
    return slen;
}

// --- public API ---

// Extract a string value: name = "value"
// Returns empty string if not found.
fn toml_get_str(content: string, key: string) -> string {
    slen := str_len(content);
    klen := str_len(key);
    pos : ., mut = 0;
    loop {
        if pos >= slen { return ""; }
        if !_is_at_line_start(content, pos) {
            pos = _next_line_start(content, pos);
            continue;
        }
        spos := _skip_whitespace(content, pos);
        npos : ., mut = 0;
        tlen : ., mut = 0;
        // Check if this line starts with the key
        if spos + klen <= slen {
            sub := str_sub(content, spos, klen);
            if str_eq(sub, key) != 0 {
                // Skip key and look for =
                eq_pos := spos + klen;
                // Skip whitespace before =
                eq_pos = _skip_whitespace(content, eq_pos);
                if get_char(content, eq_pos) == "=" {
                    // Skip whitespace after =
                    val_pos := _skip_whitespace(content, eq_pos + 1);
                    if get_char(content, val_pos) == "\"" {
                        start := val_pos + 1;
                        end : ., mut = start;
                        loop {
                            if end >= slen { return ""; }
                            if get_char(content, end) == "\"" {
                                return str_sub(content, start, end - start);
                            }
                            end = end + 1;
                        }
                    }
                }
            }
        }
        pos = _next_line_start(content, pos);
    }
    return "";
}

// Extract an integer value: key = 123
// Returns 0 if not found or invalid.
fn toml_get_int(content: string, key: string) -> int {
    slen := str_len(content);
    klen := str_len(key);
    pos : ., mut = 0;
    loop {
        if pos >= slen { return 0; }
        if !_is_at_line_start(content, pos) {
            pos = _next_line_start(content, pos);
            continue;
        }
        spos := _skip_whitespace(content, pos);
        if spos + klen <= slen {
            sub := str_sub(content, spos, klen);
            if str_eq(sub, key) != 0 {
                eq_pos := _skip_whitespace(content, spos + klen);
                if get_char(content, eq_pos) == "=" {
                    val_pos := _skip_whitespace(content, eq_pos + 1);
                    // Read integer digits
                    val : ., mut = 0;
                    lp : ., mut = val_pos;
                    neg : ., mut = 0;
                    if get_char(content, lp) == "-" { neg = 1; lp = lp + 1; }
                    loop {
                        if lp >= slen { break; }
                        c := load8(content, lp);
                        if c >= 48 && c <= 57 {
                            val = val * 10 + (c - 48);
                            lp = lp + 1;
                        } else { break; }
                    }
                    if neg == 1 { val = -val; }
                    return val;
                }
            }
        }
        pos = _next_line_start(content, pos);
    }
    return 0;
}

// Extract project name (shorthand for toml_get_str(content, "name"))
fn extract_toml_name(content: string) -> string {
    return toml_get_str(content, "name");
}

// Memory layout configuration
struct MemLayout {
    stack_size: int,
    heap_size: int,
    text_base: int,
    data_base: int,
}

fn toml_read_memlayout(content: string) -> MemLayout {
    return MemLayout {
        stack_size = toml_get_int(content, "stack_size"),
        heap_size = toml_get_int(content, "heap_size"),
        text_base = toml_get_int(content, "text_base"),
        data_base = toml_get_int(content, "data_base"),
    };
}
