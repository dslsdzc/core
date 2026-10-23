// === json.cr ===
// corelsp JSON parser and serializer. v1 supports integer numbers only, which is
// sufficient for JSON-RPC parameters.
// This module has no imports; it uses runtime builtins and stdlib string helpers.
//
// Node layout: g_json_nodes is a byte buffer with five slots per node, 40 bytes:
// {kind, a, b, c, d}. A node index is its first slot (0, 5, 10, ...).
//   J_NULL  {J_NULL, 0, 0, 0, 0}
//   J_BOOL  {J_BOOL, 0/1, 0, 0, 0}
//   J_NUM   {J_NUM, integer, 0, 0, 0}; overflow fails parsing
//   J_STR   {J_STR, pool byte offset, length, 0, 0}
//   J_ARRAY {J_ARRAY, element table offset, count, 0, 0}
//   J_OBJ   {J_OBJ, member table offset, count, 0, 0}
// Table offsets are byte offsets, not node indexes. Use json_get and json_set for
// node slots; access tables only through json_array_get, json_obj_get, and the
// internal functions.
//
// g_json_tables is separate from the node buffer so the two regions cannot
// overlap. Element tables store node indexes, 8 bytes each. Member tables store
// {key offset, key length, value index}, 24 bytes each. Key bytes live in
// g_json_strs.
//
// g_json_strs stores raw UTF-8 bytes with a separate length.
// \uXXXX escapes are decoded to Unicode code points and UTF-16 surrogate pairs
// are combined. stringify emits uppercase \uXXXX for non-ASCII and a surrogate
// pair outside the BMP.

// Constants. Global initializers must be literals in the ELF backend.
J_NULL : int = 0
J_BOOL : int = 1
J_NUM : int = 2
J_STR : int = 3
J_ARRAY : int = 4
J_OBJ : int = 5

J_NODE_SLOTS : int = 5    // slots per node
J_NODE_BYTES : int = 40   // 5 slots times 8 bytes
J_ELEM_BYTES : int = 8    // bytes per element-table entry
J_MEMBER_BYTES : int = 24 // bytes per member-table entry

// Storage globals.
g_json_nodes : string, mut   // node byte buffer, allocated lazily
g_json_count : int, mut      // node count
g_json_strs : string, mut    // string byte pool
g_json_str_count : int, mut  // number of strings in the pool

// Internal capacities, lengths, and table buffer.
g_json_nodes_cap : int, mut
g_json_strs_len : int, mut
g_json_strs_cap : int, mut
g_json_tables : string, mut
g_json_tables_len : int, mut
g_json_tables_cap : int, mut

// Low-level byte helpers, independent of dyn_arr.cr.

fn _jw64(buf: string, pos: int, val: int):
    cur : ., mut = val
    i : ., mut = 0
    loop:
        if i >= 8:
            break
        byte : ., mut = cur % 256
        if byte < 0:
            byte = byte + 256
        store8(buf, pos + i, byte)
        cur = (cur - byte) / 256
        i = i + 1

fn _jr64(buf: string, pos: int) -> int:
    // Read the low 32 bits unsigned. The high 32 bits are multiplied by 65536
    // twice to preserve sign extension.
    lo := load8(buf, pos) + load8(buf, pos + 1) * 256 + load8(buf, pos + 2) * 65536 + load8(buf, pos + 3) * 16777216
    hi := load8(buf, pos + 4) + load8(buf, pos + 5) * 256 + load8(buf, pos + 6) * 65536 + load8(buf, pos + 7) * 16777216
    hi_part := hi * 65536
    hi_part = hi_part * 65536
    return lo + hi_part

fn _jcopy(src: string, n: int, dst: string):
    ci : ., mut = 0
    loop:
        if ci >= n:
            break
        store8(dst, ci, load8(src, ci))
        ci = ci + 1

// Growth: lazy allocation with doubling.

fn _json_grow_nodes(needed: int):
    if needed <= g_json_nodes_cap:
        return
    nc : ., mut = g_json_nodes_cap * 2
    if nc < 256:
        nc = 256
    if nc < needed:
        nc = needed + 256
    nb := alloc(nc)
    _jcopy(g_json_nodes, g_json_nodes_cap, nb)
    g_json_nodes = nb
    g_json_nodes_cap = nc

fn _json_grow_tables(needed: int):
    if needed <= g_json_tables_cap:
        return
    nc : ., mut = g_json_tables_cap * 2
    if nc < 256:
        nc = 256
    if nc < needed:
        nc = needed + 256
    nb := alloc(nc)
    _jcopy(g_json_tables, g_json_tables_cap, nb)
    g_json_tables = nb
    g_json_tables_cap = nc

fn _json_grow_strs(needed: int):
    if needed <= g_json_strs_cap:
        return
    nc : ., mut = g_json_strs_cap * 2
    if nc < 256:
        nc = 256
    if nc < needed:
        nc = needed + 256
    nb := alloc(nc)
    _jcopy(g_json_strs, g_json_strs_cap, nb)
    g_json_strs = nb
    g_json_strs_cap = nc

// Node interface.

// Create a node and return its index, which is its first slot.
fn json_new(kind: int) -> int:
    need := g_json_count * J_NODE_BYTES + J_NODE_BYTES
    _json_grow_nodes(need)
    i := g_json_count * J_NODE_SLOTS
    _jw64(g_json_nodes, i * 8, kind)
    _jw64(g_json_nodes, (i + 1) * 8, 0)
    _jw64(g_json_nodes, (i + 2) * 8, 0)
    _jw64(g_json_nodes, (i + 3) * 8, 0)
    _jw64(g_json_nodes, (i + 4) * 8, 0)
    g_json_count = g_json_count + 1
    return i

fn json_set(node: int, slot: int, val: int):
    if node < 0 || node % J_NODE_SLOTS != 0 || node / J_NODE_SLOTS >= g_json_count || slot < 0 || slot >= J_NODE_SLOTS:
        return
    _jw64(g_json_nodes, (node + slot) * 8, val)

fn json_get(node: int, slot: int) -> int:
    if node < 0 || node % J_NODE_SLOTS != 0 || node / J_NODE_SLOTS >= g_json_count || slot < 0 || slot >= J_NODE_SLOTS:
        return -1
    return _jr64(g_json_nodes, (node + slot) * 8)

// Parse state.

g_json_parse_pos : int, mut
g_json_parse_text : string, mut
g_json_parse_failed : int, mut
g_json_parse_depth : int, mut
J_MAX_PARSE_DEPTH : int = 128

fn _jp_len() -> int:
    return str_len(g_json_parse_text)

// Current byte, or -1 at end of input.
fn _jp_peek() -> int:
    if g_json_parse_pos >= _jp_len():
        return -1
    return load8(g_json_parse_text, g_json_parse_pos)

fn _jskip_ws():
    loop:
        if g_json_parse_pos >= _jp_len():
            break
        c := load8(g_json_parse_text, g_json_parse_pos)
        if c == 32 || c == 9 || c == 10 || c == 13:
            g_json_parse_pos = g_json_parse_pos + 1
        else:
            break

// Match and consume true, false, or null. The next byte must not be an identifier character.
fn _jk_match(word: string) -> int:
    wl := str_len(word)
    if g_json_parse_pos + wl > _jp_len():
        return 0
    i : ., mut = 0
    loop:
        if i >= wl:
            break
        if load8(g_json_parse_text, g_json_parse_pos + i) != load8(word, i):
            return 0
        i = i + 1
    if g_json_parse_pos + wl >= _jp_len():
        g_json_parse_pos = g_json_parse_pos + wl
        return 1
    c := load8(g_json_parse_text, g_json_parse_pos + wl)
    if c >= 97 && c <= 122:
        return 0
    // a-z
    if c >= 65 && c <= 90:
        return 0
    // A-Z
    if c >= 48 && c <= 57:
        return 0
    // 0-9
    if c == 95:
        return 0
    // _
    g_json_parse_pos = g_json_parse_pos + wl
    return 1

// Number: optional minus and decimal digits. Overflow or invalid input sets g_json_parse_failed.
fn _jnum() -> int:
    neg : ., mut = 0
    if g_json_parse_pos < _jp_len() && load8(g_json_parse_text, g_json_parse_pos) == 45:
        neg = 1
        g_json_parse_pos = g_json_parse_pos + 1
    dstart := g_json_parse_pos
    loop:
        if g_json_parse_pos >= _jp_len():
            break
        c := load8(g_json_parse_text, g_json_parse_pos)
        if c >= 48 && c <= 57:
            g_json_parse_pos = g_json_parse_pos + 1
        else:
            break
    if g_json_parse_pos == dstart:
        g_json_parse_failed = 1
        return 0
    if g_json_parse_pos - dstart > 1 && load8(g_json_parse_text, dstart) == 48:
        g_json_parse_failed = 1
        return 0
    v : ., mut = 0
    i : ., mut = dstart
    loop:
        if i >= g_json_parse_pos:
            break
        digit := load8(g_json_parse_text, i) - 48
        // Accumulate negative values negatively so INT64_MIN is representable.
        if neg != 0:
            if v < -922337203685477580 || (v == -922337203685477580 && digit > 8):
                g_json_parse_failed = 1
                return 0
            v = v * 10 - digit
        else:
            if v > 922337203685477580 || (v == 922337203685477580 && digit > 7):
                g_json_parse_failed = 1
                return 0
            v = v * 10 + digit
        i = i + 1
    // Trailing dot or exponent: v1 does not support floating point, so fail instead of truncating.
    if g_json_parse_pos < _jp_len():
        c2 := load8(g_json_parse_text, g_json_parse_pos)
        if c2 == 46 || c2 == 101 || c2 == 69:
            g_json_parse_failed = 1
            return 0
    return v

// Hex digit value, or -1 when invalid.
fn _jhex_val(c: int) -> int:
    if c >= 48 && c <= 57:
        return c - 48
    if c >= 97 && c <= 102:
        return c - 87
    if c >= 65 && c <= 70:
        return c - 55
    return -1

// String pool writes.

fn _jstr_byte(b: int):
    need := g_json_strs_len + 1
    _json_grow_strs(need)
    store8(g_json_strs, g_json_strs_len, b)
    g_json_strs_len = g_json_strs_len + 1

// Encode a code point as UTF-8 in the pool.
fn _jstr_cp(cp: int):
    if cp < 128:
        _jstr_byte(cp)
    else if cp < 2048:
        _jstr_byte(192 + cp / 64)
        _jstr_byte(128 + cp % 64)
    else if cp < 65536:
        _jstr_byte(224 + cp / 4096)
        _jstr_byte(128 + (cp / 64) % 64)
        _jstr_byte(128 + cp % 64)
    else if cp <= 1114111:
        _jstr_byte(240 + cp / 262144)
        _jstr_byte(128 + (cp / 4096) % 64)
        _jstr_byte(128 + (cp / 64) % 64)
        _jstr_byte(128 + cp % 64)
    else:
        g_json_parse_failed = 1

fn _jparse_hex4(pos: int) -> int:
    cp : ., mut = 0
    i : ., mut = 0
    loop:
        if i >= 4:
            break
        hv := _jhex_val(load8(g_json_parse_text, pos + i))
        if hv < 0:
            g_json_parse_failed = 1
            return -1
        cp = cp * 16 + hv
        i = i + 1
    return cp

// Parse a JSON string at a quote and return a J_STR node, or -1 on failure.
fn _jparse_str() -> int:
    if _jp_peek() != 34:
        g_json_parse_failed = 1
        return -1
    g_json_parse_pos = g_json_parse_pos + 1   // consume the quote
    off := g_json_strs_len
    loop:
        if g_json_parse_pos >= _jp_len():
            g_json_parse_failed = 1
            return -1
        // Unclosed string.
        c := load8(g_json_parse_text, g_json_parse_pos)
        if c == 34:
            g_json_parse_pos = g_json_parse_pos + 1
            n := json_new(J_STR)
            json_set(n, 1, off)
            json_set(n, 2, g_json_strs_len - off)
            g_json_str_count = g_json_str_count + 1
            return n
        if c == 92:
            // Backslash.
            g_json_parse_pos = g_json_parse_pos + 1
            if g_json_parse_pos >= _jp_len():
                g_json_parse_failed = 1
                return -1
            e := load8(g_json_parse_text, g_json_parse_pos)
            g_json_parse_pos = g_json_parse_pos + 1
            if e == 34:
                _jstr_byte(34)
            else if e == 92:
                _jstr_byte(92)
            else if e == 47:
                _jstr_byte(47)
            else if e == 98:
                _jstr_byte(8)
            else if e == 102:
                _jstr_byte(12)
            else if e == 110:
                _jstr_byte(10)
            else if e == 114:
                _jstr_byte(13)
            else if e == 116:
                _jstr_byte(9)
            else if e == 117:
                // Unicode escape.
                if g_json_parse_pos + 4 > _jp_len():
                    g_json_parse_failed = 1
                    return -1
                cp := _jparse_hex4(g_json_parse_pos)
                if cp < 0:
                    return -1
                g_json_parse_pos = g_json_parse_pos + 4
                if cp >= 55296 && cp <= 56319:
                    // A high surrogate must be followed by a low surrogate
                    // escape; store the resulting scalar as UTF-8.
                    if g_json_parse_pos + 6 > _jp_len() || load8(g_json_parse_text, g_json_parse_pos) != 92 || load8(g_json_parse_text, g_json_parse_pos + 1) != 117:
                        g_json_parse_failed = 1
                        return -1
                    low := _jparse_hex4(g_json_parse_pos + 2)
                    if low < 56320 || low > 57343:
                        g_json_parse_failed = 1
                        return -1
                    g_json_parse_pos = g_json_parse_pos + 6
                    cp = 65536 + (cp - 55296) * 1024 + (low - 56320)
                else if cp >= 56320 && cp <= 57343:
                    g_json_parse_failed = 1
                    return -1
                _jstr_cp(cp)
            else:
                g_json_parse_failed = 1
                return -1
            // Unknown escape.
        else if c < 32:
            g_json_parse_failed = 1
            return -1   // control characters must be escaped
        else:
            _jstr_byte(c)   // raw UTF-8 byte
            g_json_parse_pos = g_json_parse_pos + 1

// Value parsing, recursive descent.

fn _jparse_obj(depth: int) -> int:
    if depth > J_MAX_PARSE_DEPTH:
        g_json_parse_failed = 1
        return -1
    g_json_parse_pos = g_json_parse_pos + 1   // consume the opening brace
    tbl : ., mut = -1      // member table offset; allocated on the first member
    count : ., mut = 0
    loop:
        _jskip_ws()
        if _jp_peek() == 125:
            // Closing brace.
            g_json_parse_pos = g_json_parse_pos + 1
            break
        if count > 0:
            if _jp_peek() != 44:
                g_json_parse_failed = 1
                return -1
            // Comma.
            g_json_parse_pos = g_json_parse_pos + 1
            _jskip_ws()
        key_node := _jparse_str()
        if key_node < 0:
            return -1
        _jskip_ws()
        if _jp_peek() != 58:
            g_json_parse_failed = 1
            return -1
        // Colon.
        g_json_parse_pos = g_json_parse_pos + 1
        val := parse_value(depth + 1)
        if val < 0:
            return -1
        // The member table is a growing list. Copy existing members to the
        // current end before adding a new member; child tables are allocated
        // later, so this keeps each table contiguous.
        if count == 0:
            tbl = g_json_tables_len
            _json_grow_tables(tbl + J_MEMBER_BYTES)
            g_json_tables_len = tbl + J_MEMBER_BYTES
        else:
            npos := g_json_tables_len
            need := npos + (count + 1) * J_MEMBER_BYTES
            _json_grow_tables(need)
            ci : ., mut = 0
            loop:
                if ci >= count * J_MEMBER_BYTES:
                    break
                store8(g_json_tables, npos + ci, load8(g_json_tables, tbl + ci))
                ci = ci + 1
            tbl = npos
            g_json_tables_len = need
        _jw64(g_json_tables, tbl + count * J_MEMBER_BYTES, json_get(key_node, 1))
        _jw64(g_json_tables, tbl + count * J_MEMBER_BYTES + 8, json_get(key_node, 2))
        _jw64(g_json_tables, tbl + count * J_MEMBER_BYTES + 16, val)
        count = count + 1
    if count == 0:
        tbl = g_json_tables_len
    n := json_new(J_OBJ)
    json_set(n, 1, tbl)
    json_set(n, 2, count)
    return n

fn _jparse_arr(depth: int) -> int:
    if depth > J_MAX_PARSE_DEPTH:
        g_json_parse_failed = 1
        return -1
    g_json_parse_pos = g_json_parse_pos + 1   // consume the opening bracket
    tbl : ., mut = -1      // element table offset; allocated on the first element
    count : ., mut = 0
    loop:
        _jskip_ws()
        if _jp_peek() == 93:
            // Closing bracket.
            g_json_parse_pos = g_json_parse_pos + 1
            break
        if count > 0:
            if _jp_peek() != 44:
                g_json_parse_failed = 1
                return -1
            g_json_parse_pos = g_json_parse_pos + 1
            _jskip_ws()
        v := parse_value(depth + 1)
        if v < 0:
            return -1
        if count == 0:
            tbl = g_json_tables_len
            _json_grow_tables(tbl + J_ELEM_BYTES)
            g_json_tables_len = tbl + J_ELEM_BYTES
        else:
            npos := g_json_tables_len
            need := npos + (count + 1) * J_ELEM_BYTES
            _json_grow_tables(need)
            ci : ., mut = 0
            loop:
                if ci >= count * J_ELEM_BYTES:
                    break
                store8(g_json_tables, npos + ci, load8(g_json_tables, tbl + ci))
                ci = ci + 1
            tbl = npos
            g_json_tables_len = need
        _jw64(g_json_tables, tbl + count * J_ELEM_BYTES, v)
        count = count + 1
    if count == 0:
        tbl = g_json_tables_len
    n := json_new(J_ARRAY)
    json_set(n, 1, tbl)
    json_set(n, 2, count)
    return n

fn parse_value(depth: int) -> int:
    if depth > J_MAX_PARSE_DEPTH:
        g_json_parse_failed = 1
        return -1
    _jskip_ws()
    c := _jp_peek()
    if c < 0:
        return -1
    if c == 123:
        return _jparse_obj(depth)
    if c == 91:
        return _jparse_arr(depth)
    if c == 34:
        return _jparse_str()
    if c == 116:
        // true
        if _jk_match("true") != 0:
            n1 := json_new(J_BOOL)
            json_set(n1, 1, 1)
            return n1
        return -1
    if c == 102:
        // false
        if _jk_match("false") != 0:
            n2 := json_new(J_BOOL)
            json_set(n2, 1, 0)
            return n2
        return -1
    if c == 110:
        // null
        if _jk_match("null") != 0:
            return json_new(J_NULL)
        return -1
    if c == 45 || (c >= 48 && c <= 57):
        // Minus or digit.
        v := _jnum()
        if g_json_parse_failed != 0:
            return -1
        n3 := json_new(J_NUM)
        json_set(n3, 1, v)
        return n3
    return -1

// Public parsing interface.

// Parse JSON text to a root node index, or -1 on failure. Each call resets all pools.
fn json_parse(text: string) -> int:
    g_json_count = 0
    g_json_str_count = 0
    g_json_strs_len = 0
    g_json_tables_len = 0
    g_json_parse_failed = 0
    g_json_parse_depth = 0
    g_json_parse_text = text
    g_json_parse_pos = 0
    idx := parse_value(0)
    if g_json_parse_failed != 0:
        return -1
    if idx < 0:
        return -1
    _jskip_ws()
    if g_json_parse_pos < _jp_len():
        return -1
    // Trailing content after the root value.
    return idx

// Serialization.

fn _jhex_digit(v: int) -> string:
    if v < 10:
        return chr(48 + v)
    return chr(65 + v - 10)   // uppercase A through F

// Code point to an uppercase \uXXXX escape.
fn _jhex4(v: int) -> string:
    // Accumulate into a literal-initialized string. The bootstrap parser does not
    // propagate string types through a bare BinaryOp chain and would compile it as
    // integer addition.
    out : string, mut = "\\u"
    out = out + _jhex_digit((v / 4096) % 16)
    out = out + _jhex_digit((v / 256) % 16)
    out = out + _jhex_digit((v / 16) % 16)
    out = out + _jhex_digit(v % 16)
    return out

g_json_utf8_cp : int, mut   // decoded code point from _jutf8_dec

// Decode a UTF-8 sequence at off and return the byte advance. An invalid sequence returns 1 and leaves the original byte as the code point.
fn _jutf8_dec(off: int) -> int:
    b0 := load8(g_json_strs, off)
    if b0 < 128:
        g_json_utf8_cp = b0
        return 1
    if b0 < 224:
        if off + 1 < g_json_strs_len:
            b1 := load8(g_json_strs, off + 1)
            if b1 >= 128 && b1 < 192:
                g_json_utf8_cp = (b0 - 192) * 64 + (b1 - 128)
                return 2
        g_json_utf8_cp = b0
        return 1
    if b0 < 240:
        if off + 2 < g_json_strs_len:
            b1 := load8(g_json_strs, off + 1)
            b2 := load8(g_json_strs, off + 2)
            if b1 >= 128 && b1 < 192 && b2 >= 128 && b2 < 192:
                g_json_utf8_cp = (b0 - 224) * 4096 + (b1 - 128) * 64 + (b2 - 128)
                return 3
        g_json_utf8_cp = b0
        return 1
    if off + 3 < g_json_strs_len:
        b1 := load8(g_json_strs, off + 1)
        b2 := load8(g_json_strs, off + 2)
        b3 := load8(g_json_strs, off + 3)
        if b1 >= 128 && b1 < 192 && b2 >= 128 && b2 < 192 && b3 >= 128 && b3 < 192:
            g_json_utf8_cp = (b0 - 240) * 262144 + (b1 - 128) * 4096 + (b2 - 128) * 64 + (b3 - 128)
            return 4
    g_json_utf8_cp = b0
    return 1

// Convert a pool byte range to JSON string text, including quotes. Non-ASCII bytes become uppercase \uXXXX escapes.
fn _jstr_out(off: int, len: int) -> string:
    out : string, mut = "\""
    i : ., mut = 0
    loop:
        if i >= len:
            break
        b := load8(g_json_strs, off + i)
        if b == 34:
            out = out + "\\\""
            i = i + 1
        else if b == 92:
            out = out + "\\\\"
            i = i + 1
        else if b == 10:
            out = out + "\\n"
            i = i + 1
        else if b == 13:
            out = out + "\\r"
            i = i + 1
        else if b == 9:
            out = out + "\\t"
            i = i + 1
        else if b < 32:
            out = out + _jhex4(b)
            i = i + 1
        else if b < 128:
            out = out + chr(b)
            i = i + 1
        else:
            adv := _jutf8_dec(off + i)
            cp := g_json_utf8_cp
            if cp >= 65536:
                // Outside the BMP: emit a surrogate pair of \uXXXX escapes.
                c0 := cp - 65536
                hi := 55296 + c0 / 1024    // 0xD800 + (cp-0x10000)>>10
                lo := 56320 + c0 % 1024    // 0xDC00 + (cp-0x10000)&0x3FF
                out = out + _jhex4(hi) + _jhex4(lo)
            else:
                out = out + _jhex4(cp)
            i = i + adv
    out = out + "\""
    return out

fn _jstringify_rec(idx: int) -> string:
    k := json_get(idx, 0)
    if k == J_NULL:
        return "null"
    if k == J_BOOL:
        if json_get(idx, 1) != 0:
            return "true"
        return "false"
    if k == J_NUM:
        return int_str(json_get(idx, 1))
    if k == J_STR:
        return _jstr_out(json_get(idx, 1), json_get(idx, 2))
    if k == J_ARRAY:
        tbl := json_get(idx, 1)
        cnt := json_get(idx, 2)
        out : string, mut = "["
        i : ., mut = 0
        loop:
            if i >= cnt:
                break
            if i > 0:
                out = out + ","
            out = out + _jstringify_rec(_jr64(g_json_tables, tbl + i * J_ELEM_BYTES))
            i = i + 1
        out = out + "]"
        return out
    if k == J_OBJ:
        tbl := json_get(idx, 1)
        cnt := json_get(idx, 2)
        out : string, mut = "{"
        i : ., mut = 0
        loop:
            if i >= cnt:
                break
            if i > 0:
                out = out + ","
            koff := _jr64(g_json_tables, tbl + i * J_MEMBER_BYTES)
            klen := _jr64(g_json_tables, tbl + i * J_MEMBER_BYTES + 8)
            v := _jr64(g_json_tables, tbl + i * J_MEMBER_BYTES + 16)
            out = out + _jstr_out(koff, klen) + ":" + _jstringify_rec(v)
            i = i + 1
        out = out + "}"
        return out
    return "null"

// Node to JSON text; an invalid index returns an empty string.
fn json_stringify(idx: int) -> string:
    if idx < 0 || idx % J_NODE_SLOTS != 0 || idx / J_NODE_SLOTS >= g_json_count || g_json_count == 0:
        return ""
    return _jstringify_rec(idx)

// Lookup interface.

// Look up an object member by key with a linear scan. Return -1 when absent.
fn json_obj_get(obj: int, key: string) -> int:
    if obj < 0 || obj % J_NODE_SLOTS != 0 || obj / J_NODE_SLOTS >= g_json_count || json_get(obj, 0) != J_OBJ:
        return -1
    tbl := json_get(obj, 1)
    cnt := json_get(obj, 2)
    kl := str_len(key)
    found_value : ., mut = -1
    i : ., mut = 0
    loop:
        if i >= cnt:
            break
        koff := _jr64(g_json_tables, tbl + i * J_MEMBER_BYTES)
        klen := _jr64(g_json_tables, tbl + i * J_MEMBER_BYTES + 8)
        if klen == kl:
            matched : ., mut = 1
            j : ., mut = 0
            loop:
                if j >= kl:
                    break
                if load8(g_json_strs, koff + j) != load8(key, j):
                    matched = 0
                    break
                j = j + 1
            if matched != 0:
                found_value = _jr64(g_json_tables, tbl + i * J_MEMBER_BYTES + 16)
        i = i + 1
    return found_value

// Get an array element by index. Return -1 when out of range or not an array.
fn json_array_get(arr: int, i: int) -> int:
    if arr < 0 || arr % J_NODE_SLOTS != 0 || arr / J_NODE_SLOTS >= g_json_count || json_get(arr, 0) != J_ARRAY:
        return -1
    cnt := json_get(arr, 2)
    if i < 0 || i >= cnt:
        return -1
    tbl := json_get(arr, 1)
    return _jr64(g_json_tables, tbl + i * J_ELEM_BYTES)
