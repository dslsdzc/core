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

// Hex digit value (0-15), -1 if not a hex digit.
fn _toml_hex_digit(c: int) -> int {
    if c >= 48 && c <= 57 { return c - 48; }
    if c >= 65 && c <= 70 { return c - 55; }   // 'A'-'F'
    if c >= 97 && c <= 102 { return c - 87; }  // 'a'-'f'
    return -1;
}

// Extract an int array value: key = [a, b, c]（项支持十进制与 0x/0X 十六进制，
// 非负整数；值写入 out，每项 4B 小端）。供 HIT 表 opcode = [0x48, 0x29] 类
// 条目使用（见 src/arch/x86_64/core-x86.toml）。
// Returns item count on success（遇 ']' 收尾）；-1 = key 缺 / 值非数组 /
// 项格式错 / 项数超过 max_items（不静默截断）。
fn toml_get_int_list(content: string, key: string, out: string, max_items: int) -> int {
    slen := str_len(content);
    klen := str_len(key);
    pos : ., mut = 0;
    loop {
        if pos >= slen { return -1; }
        if !_is_at_line_start(content, pos) {
            pos = _next_line_start(content, pos);
            continue;
        }
        spos := _skip_whitespace(content, pos);
        if spos + klen > slen {
            pos = _next_line_start(content, pos);
            continue;
        }
        sub := str_sub(content, spos, klen);
        if str_eq(sub, key) == 0 {
            pos = _next_line_start(content, pos);
            continue;
        }
        eq_pos := _skip_whitespace(content, spos + klen);
        if load8(content, eq_pos) != 61 {  // 非 '=' 的行不算命中
            pos = _next_line_start(content, pos);
            continue;
        }
        val_pos := _skip_whitespace(content, eq_pos + 1);
        if load8(content, val_pos) != 91 {  // 值非 '[' 开头 → 非数组，继续找下一条
            pos = _next_line_start(content, pos);
            continue;
        }
        // Parse list items
        p : ., mut = val_pos + 1;
        n : ., mut = 0;
        loop {
            if p >= slen { return -1; }
            // Skip whitespace (incl. newlines: lists may span lines)
            ch : ., mut = 0;
            loop {
                if p >= slen { return -1; }
                ch = load8(content, p);
                if ch == 32 || ch == 9 || ch == 10 || ch == 13 {
                    p = p + 1;
                } else { break; }
            }
            if ch == 93 { break; }   // ']' → list end（此处 return n）
            if ch == 44 { p = p + 1; continue; }  // ',' — 宽容跳过分隔符
            if n >= max_items { return -1; }  // 项数超限（不静默截断）
            v : ., mut = 0;
            // Hex item: 0x/0X prefix
            if ch == 48 && p + 1 < slen &&
               (load8(content, p + 1) == 120 || load8(content, p + 1) == 88) {
                p = p + 2;
                if p >= slen { return -1; }
                hd := _toml_hex_digit(load8(content, p));
                if hd < 0 { return -1; }
                v = hd;
                p = p + 1;
                loop {
                    if p >= slen { break; }
                    ch = load8(content, p);
                    hd2 := _toml_hex_digit(ch);
                    if hd2 < 0 { break; }
                    v = v * 16 + hd2;
                    p = p + 1;
                }
            } else {
                // Decimal item（须以数字开头）
                if ch < 48 || ch > 57 { return -1; }
                v = ch - 48;
                p = p + 1;
                loop {
                    if p >= slen { break; }
                    ch = load8(content, p);
                    if ch >= 48 && ch <= 57 {
                        v = v * 10 + (ch - 48);
                        p = p + 1;
                    } else { break; }
                }
            }
            // Item terminator must be ws / ',' / ']'
            if ch != 32 && ch != 9 && ch != 10 && ch != 13 &&
               ch != 44 && ch != 93 { return -1; }
            store8(out, n * 4 + 0, v % 256);
            store8(out, n * 4 + 1, (v / 256) % 256);
            store8(out, n * 4 + 2, (v / 65536) % 256);
            store8(out, n * 4 + 3, (v / 16777216) % 256);
            n = n + 1;
        }
        return n;
    }
    return -1;
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
