// === json.cr ===
// corelsp JSON 解析/序列化（v1：仅整数数字；JSON-RPC 参数全整数）。
// 自包含模块：不 import 任何东西（仅依赖运行时内建与 stdlib 字符串函数）。
//
// ── 扁平节点布局（Task 2-6 按此 import 常量与布局）──
// g_json_nodes：节点字节缓冲（string, mut，惰性 alloc + 倍增扩容）。
//   节点 = 五槽一组 {kind, a, b, c, d}（40 字节）；节点索引 = 起始槽（0, 5, 10, …）。
//   J_NULL    {J_NULL, 0, 0, 0, 0}
//   J_BOOL    {J_BOOL, 0/1, 0, 0, 0}
//   J_NUM     {J_NUM,  整数值, 0, 0, 0}          v1 仅整数；溢出 → 解析失败
//   J_STR     {J_STR,  字符串池字节偏移, 长度, 0, 0}
//   J_ARRAY   {J_ARRAY, 元素表偏移, 元素数, 0, 0}
//   J_OBJ     {J_OBJ,  成员表偏移, 成员数, 0, 0}
// 注意：表偏移均为【字节偏移】，与节点索引（槽号）单位不同——用 json_get/json_set
//   访问节点槽；表内容只经 json_array_get/json_obj_get 与内部函数访问。
//
// g_json_tables：元素表/成员表字节缓冲（内部，与节点缓冲分离，避免两区域
//   在同一缓冲内相互覆盖；brief 规定的四个全局保持不变，此缓冲为内部实现）。
//   元素表 = 节点索引连续存放（每元素 8 字节）。
//   成员表 = 三槽一组 {key_off, key_len, value_idx}（24 字节），key_off/key_len
//   指向 g_json_strs 字符串池中的键字节。
//
// g_json_strs：字符串池（原始字节，UTF-8 直通存储；独立长度计数管理）。
//
// \uXXXX：解析为 Unicode 码点并合并 UTF-16 代理对；stringify 对非 ASCII
//   统一使用大写 \uXXXX（非 BMP 输出为一对代理项）。

// ── 常量（全局初始化必须是字面量——ELF 后端限制）──
J_NULL : int = 0
J_BOOL : int = 1
J_NUM : int = 2
J_STR : int = 3
J_ARRAY : int = 4
J_OBJ : int = 5

J_NODE_SLOTS : int = 5    // 每节点槽数
J_NODE_BYTES : int = 40   // 5 × 8
J_ELEM_BYTES : int = 8    // 元素表每元素字节数
J_MEMBER_BYTES : int = 24 // 成员表每组字节数

// ── 存储（brief 规定的接口全局）──
g_json_nodes : string, mut   // 节点字节缓冲（惰性 alloc）
g_json_count : int, mut      // 节点数
g_json_strs : string, mut    // 字符串字节池
g_json_str_count : int, mut  // 池中字符串数

// ── 内部：容量/长度计数 + 元素表/成员表缓冲 ──
g_json_nodes_cap : int, mut
g_json_strs_len : int, mut
g_json_strs_cap : int, mut
g_json_tables : string, mut
g_json_tables_len : int, mut
g_json_tables_cap : int, mut

// ── 低层字节助手（自包含，不依赖 dyn_arr.cr 的 w64/r64）──

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
    // 与 dyn_arr.cr r64 相同策略：低 32 位按无符号读，高 32 位经两次
    // 65536 乘法回绕得到正确的符号扩展（-1 → -1 + (-1 × 2^32)）。
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

// ── 扩容（惰性 alloc + 倍增）──

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

// ── 节点接口（Task 2-6 依赖）──

// 新建节点，返回节点索引（起始槽号）
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

// ── 解析状态 ──

g_json_parse_pos : int, mut
g_json_parse_text : string, mut
g_json_parse_failed : int, mut
g_json_parse_depth : int, mut
J_MAX_PARSE_DEPTH : int = 128

fn _jp_len() -> int:
    return str_len(g_json_parse_text)

// 当前位置的字符；文件尾返回 -1
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

// 关键字匹配（true/false/null）并消费；后随字符必须是边界（非标识符字符）
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

// 数字：可选负号 + 十进制整数；溢出/非法置 g_json_parse_failed
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
    // 尾随 '.' / 'e' / 'E'：v1 不支持浮点 → 失败（不静默截断）
    if g_json_parse_pos < _jp_len():
        c2 := load8(g_json_parse_text, g_json_parse_pos)
        if c2 == 46 || c2 == 101 || c2 == 69:
            g_json_parse_failed = 1
            return 0
    return v

// 十六进制数字值；非法返回 -1
fn _jhex_val(c: int) -> int:
    if c >= 48 && c <= 57:
        return c - 48
    if c >= 97 && c <= 102:
        return c - 87
    if c >= 65 && c <= 70:
        return c - 55
    return -1

// ── 字符串池写入 ──

fn _jstr_byte(b: int):
    need := g_json_strs_len + 1
    _json_grow_strs(need)
    store8(g_json_strs, g_json_strs_len, b)
    g_json_strs_len = g_json_strs_len + 1

// 码点 → UTF-8 编码写入池
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

// 解析 JSON 字符串（当前位置必须是 '"'），返回 J_STR 节点；失败返回 -1
fn _jparse_str() -> int:
    if _jp_peek() != 34:
        g_json_parse_failed = 1
        return -1
    g_json_parse_pos = g_json_parse_pos + 1   // 消费 '"'
    off := g_json_strs_len
    loop:
        if g_json_parse_pos >= _jp_len():
            g_json_parse_failed = 1
            return -1
        // 未闭合
        c := load8(g_json_parse_text, g_json_parse_pos)
        if c == 34:
            g_json_parse_pos = g_json_parse_pos + 1
            n := json_new(J_STR)
            json_set(n, 1, off)
            json_set(n, 2, g_json_strs_len - off)
            g_json_str_count = g_json_str_count + 1
            return n
        if c == 92:
            // '\'
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
                // 'u'
                if g_json_parse_pos + 4 > _jp_len():
                    g_json_parse_failed = 1
                    return -1
                cp := _jparse_hex4(g_json_parse_pos)
                if cp < 0:
                    return -1
                g_json_parse_pos = g_json_parse_pos + 4
                if cp >= 55296 && cp <= 56319:
                    // A high surrogate must be immediately followed by a low
                    // surrogate escape; store the resulting scalar as UTF-8.
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
            // 未知转义
        else if c < 32:
            g_json_parse_failed = 1
            return -1   // 控制字符必须转义
        else:
            _jstr_byte(c)   // 原始字节（UTF-8 直通）
            g_json_parse_pos = g_json_parse_pos + 1

// ── 值解析（递归下降）──

fn _jparse_obj(depth: int) -> int:
    if depth > J_MAX_PARSE_DEPTH:
        g_json_parse_failed = 1
        return -1
    g_json_parse_pos = g_json_parse_pos + 1   // 消费 '{'
    tbl : ., mut = -1      // 成员表偏移（惰性：首成员时分配）
    count : ., mut = 0
    loop:
        _jskip_ws()
        if _jp_peek() == 125:
            // '}'
            g_json_parse_pos = g_json_parse_pos + 1
            break
        if count > 0:
            if _jp_peek() != 44:
                g_json_parse_failed = 1
                return -1
            // ','
            g_json_parse_pos = g_json_parse_pos + 1
            _jskip_ws()
        key_node := _jparse_str()
        if key_node < 0:
            return -1
        _jskip_ws()
        if _jp_peek() != 58:
            g_json_parse_failed = 1
            return -1
        // ':'
        g_json_parse_pos = g_json_parse_pos + 1
        val := parse_value(depth + 1)
        if val < 0:
            return -1
        // 表 = 可增长列表：新成员时把已有成员迁移到当前末尾（子容器表在下方，
        // 不受影响），再写入新成员——保证成员表连续且不与子容器表重叠。
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
    g_json_parse_pos = g_json_parse_pos + 1   // 消费 '['
    tbl : ., mut = -1      // 元素表偏移（惰性：首元素时分配）
    count : ., mut = 0
    loop:
        _jskip_ws()
        if _jp_peek() == 93:
            // ']'
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
        // 't' → true
        if _jk_match("true") != 0:
            n1 := json_new(J_BOOL)
            json_set(n1, 1, 1)
            return n1
        return -1
    if c == 102:
        // 'f' → false
        if _jk_match("false") != 0:
            n2 := json_new(J_BOOL)
            json_set(n2, 1, 0)
            return n2
        return -1
    if c == 110:
        // 'n' → null
        if _jk_match("null") != 0:
            return json_new(J_NULL)
        return -1
    if c == 45 || (c >= 48 && c <= 57):
        // '-' 或数字
        v := _jnum()
        if g_json_parse_failed != 0:
            return -1
        n3 := json_new(J_NUM)
        json_set(n3, 1, v)
        return n3
    return -1

// ── 公开解析接口 ──

// 解析 JSON 文本 → 根节点索引；失败返回 -1。每次调用重置全部池。
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
    // 尾部多余内容
    return idx

// ── 序列化 ──

fn _jhex_digit(v: int) -> string:
    if v < 10:
        return chr(48 + v)
    return chr(65 + v - 10)   // 大写 A-F

// 码点 → \uXXXX（大写十六进制）
fn _jhex4(v: int) -> string:
    // 逐段累加：Python bootstrap 对 BinaryOp 结果变量不做字符串类型传播，
    // 裸表达式链会被编译成整数 add（见 Task 1 报告）；累加器从字面量初始化
    // 则类型正确，两条管线（bootstrap/corec 与自举 corec）行为一致。
    out : string, mut = "\\u"
    out = out + _jhex_digit((v / 4096) % 16)
    out = out + _jhex_digit((v / 256) % 16)
    out = out + _jhex_digit((v / 16) % 16)
    out = out + _jhex_digit(v % 16)
    return out

g_json_utf8_cp : int, mut   // _jutf8_dec 的解码结果（内部暂存）

// 从字符串池 off 处解码 UTF-8 序列；返回字节推进数（非法序列返回 1，cp = 原字节）
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

// 池中字节段 → JSON 字符串文本（含引号；转义反转义；非 ASCII 一律 \uXXXX）
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
                // 非 BMP：编码为代理对两个 \uXXXX（JSON 规范要求）
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

// 节点 → JSON 文本；非法索引返回空串
fn json_stringify(idx: int) -> string:
    if idx < 0 || idx % J_NODE_SLOTS != 0 || idx / J_NODE_SLOTS >= g_json_count || g_json_count == 0:
        return ""
    return _jstringify_rec(idx)

// ── 查找接口（Task 2-6 依赖）──

// 对象按键查找：线性扫描成员表；找不到返回 -1
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

// 数组按下标取元素；越界或非数组返回 -1
fn json_array_get(arr: int, i: int) -> int:
    if arr < 0 || arr % J_NODE_SLOTS != 0 || arr / J_NODE_SLOTS >= g_json_count || json_get(arr, 0) != J_ARRAY:
        return -1
    cnt := json_get(arr, 2)
    if i < 0 || i >= cnt:
        return -1
    tbl := json_get(arr, 1)
    return _jr64(g_json_tables, tbl + i * J_ELEM_BYTES)
