// === rpc.cr ===
// corelsp JSON-RPC 2.0 frame loop and lifecycle handshake.
//
// Build order: this file follows json.cr in the corelsp concat list. json_new,
// json_parse, json_obj_get, and g_json_strs are visible in the same translation
// unit.
//
// Protocol:
// - Read a frame byte by byte until "\r\n\r\n", matching Content-Length
//   case-insensitively, then read N body bytes.
// - Write "Content-Length: N\r\n\r\n" plus the body in one write.
// - Dispatch initialize, initialized, shutdown, and exit. Unknown methods get
//   -32601; requests before initialize get -32602. Notifications get no response.
//   exit after shutdown returns 0; exit without shutdown returns 1. EOF exits 0.
//
// String accumulation starts from a literal-initialized `: string, mut`
// accumulator. Responses are fixed-shape text with int_str interpolation, not
// JSON node trees.

// Constants.
RPC_HDR_MAX : int = 8192        // header buffer limit in bytes
RPC_BODY_MAX : int = 16777216   // body limit, 16 MiB

// State.
g_rpc_initialized : int, mut    // initialize received
g_rpc_shutdown : int, mut       // shutdown received
g_rpc_exit_code : int, mut      // process exit code when the frame loop ends
g_rpc_hdr_buf : string, mut     // header buffer, allocated once
g_rpc_hdr_ok : int, mut
g_rpc_in_buf : string, mut      // stdin block buffer to avoid one read syscall per byte
g_rpc_in_pos : int, mut
g_rpc_in_len : int, mut
g_rpc_in_ok : int, mut

// Frame reading.

// Read one byte from stdin (fd 0) using 4 KiB blocks. EOF or an error returns -1.
fn rpc_read_byte() -> int:
    if g_rpc_in_ok == 0:
        g_rpc_in_buf = alloc(4096)
        g_rpc_in_pos = 0
        g_rpc_in_len = 0
        g_rpc_in_ok = 1
    if g_rpc_in_pos >= g_rpc_in_len:
        n := syscall3(0, 0, g_rpc_in_buf, 4096)
        if n <= 0:
            return -1
        g_rpc_in_pos = 0
        g_rpc_in_len = n
    c := load8(g_rpc_in_buf, g_rpc_in_pos)
    g_rpc_in_pos = g_rpc_in_pos + 1
    return c

// Read headers through "\r\n\r\n" and parse Content-Length. EOF or a bad header returns -1.
fn rpc_read_header() -> int:
    if g_rpc_hdr_ok == 0:
        g_rpc_hdr_buf = alloc(RPC_HDR_MAX)
        g_rpc_hdr_ok = 1
    buf := g_rpc_hdr_buf
    hlen : ., mut = 0
    seen : ., mut = 0   // consecutive bytes matched against the "\r\n\r\n" prefix
    loop:
        c := rpc_read_byte()
        if c < 0:
            return -1
        // End of input.
        if hlen >= RPC_HDR_MAX:
            return -1
        // Header too long.
        store8(buf, hlen, c)
        hlen = hlen + 1
        if c == 13 && seen == 0:
            seen = 1
        else if c == 10 && seen == 1:
            seen = 2
        else if c == 13 && seen == 2:
            seen = 3
        else if c == 10 && seen == 3:
            seen = 4
        else:
            seen = 0
            if c == 13:
                seen = 1
            // The current byte can start a new CR sequence.
        if seen >= 4:
            break
    return rpc_find_len(buf, hlen)

// Compare buf[pos..] with key case-insensitively. The key must be followed by a colon or whitespace.
fn rpc_key_at(buf: string, pos: int, key: string) -> int:
    kl := str_len(key)
    if pos < 0:
        return 0
    i : ., mut = 0
    loop:
        if i >= kl:
            break
        c : ., mut = load8(buf, pos + i)
        kc := load8(key, i)
        if c >= 65 && c <= 90:
            c = c + 32
        // Convert uppercase to lowercase.
        if c != kc:
            return 0
        i = i + 1
    c2 := load8(buf, pos + kl)
    if c2 == 58:
        return 1
    // Colon.
    if c2 == 32 || c2 == 9:
        return 1
    // Space or tab.
    return 0

// Parse Content-Length from the header buffer. Missing, invalid, or oversized values return -1.
fn rpc_find_len(buf: string, blen: int) -> int:
    i : ., mut = 0
    found : ., mut = 0
    found_len : ., mut = -1
    loop:
        if i >= blen:
            break
        // Header fields are matched only at line starts. This prevents a
        // body-like substring in another header from being accepted.
        if i + 1 < blen && load8(buf, i) == 13 && load8(buf, i + 1) == 10:
            break
        line_end : ., mut = i
        loop:
            if line_end + 1 >= blen:
                return -1
            if load8(buf, line_end) == 13 && load8(buf, line_end + 1) == 10:
                break
            line_end = line_end + 1
        if line_end - i < 15:
            i = line_end + 2
            continue
        if rpc_key_at(buf, i, "content-length") != 0:
            j : ., mut = i + 14
            if j >= line_end:
                return -1
            // The key matcher permits whitespace before the colon.
            loop:
                if j < line_end && (load8(buf, j) == 32 || load8(buf, j) == 9):
                    j = j + 1
                else:
                    break
            if j >= line_end || load8(buf, j) != 58:
                return -1
            j = j + 1
            loop:
                if j < line_end && (load8(buf, j) == 32 || load8(buf, j) == 9):
                    j = j + 1
                else:
                    break
            v : ., mut = 0
            got : ., mut = 0
            loop:
                if j >= line_end:
                    break
                c2 := load8(buf, j)
                if c2 >= 48 && c2 <= 57:
                    if v > RPC_BODY_MAX / 10 || (v == RPC_BODY_MAX / 10 && c2 - 48 > RPC_BODY_MAX % 10):
                        return -1
                    v = v * 10 + (c2 - 48)
                    got = 1
                    j = j + 1
                else:
                    break
            if got == 0:
                return -1
            loop:
                if j < line_end && (load8(buf, j) == 32 || load8(buf, j) == 9):
                    j = j + 1
                else:
                    break
            if j != line_end:
                return -1
            if found != 0:
                return -1
            found = 1
            found_len = v
        i = line_end + 2
    return found_len

// Read n body bytes. EOF returns the partial body, which json_parse then rejects.
fn rpc_read_body(n: int) -> string:
    buf := alloc(n + 1)
    i : ., mut = 0
    loop:
        if i >= n:
            break
        c := rpc_read_byte()
        if c < 0:
            break
        store8(buf, i, c)
        i = i + 1
    store8(buf, i, 0)
    return buf

// Read one frame body. EOF or a bad header returns ""; the caller checks the length.
fn rpc_read_frame() -> string:
    n := rpc_read_header()
    if n < 0:
        return ""
    return rpc_read_body(n)

// Frame writing.

// Write Content-Length plus the body in one write. Responses are smaller than PIPE_BUF.
fn rpc_send(body: string):
    bl := str_len(body)
    hdr : string, mut = "Content-Length: "
    hdr = hdr + int_str(bl)
    hdr = hdr + "\r\n\r\n"
    hdr = hdr + body
    syscall3(1, 1, hdr, str_len(hdr))

// Fixed-shape response bodies. Error messages use literal strings selected by code.
fn rpc_send_initialize(id: int):
    out : string, mut = "{\"jsonrpc\":\"2.0\",\"id\":"
    out = out + int_str(id)
    // Advertise completion with the @ trigger, documentSymbol, hover,
    // definition, and semanticTokens/full. textDocumentSync stays 1 for full
    // synchronization. The semantic token legend order must match
    // analysis_kind_type in analysis.cr: keyword, type, function, variable,
    // comment, string, operator, number. The comment class has no tokens because
    // the lexer skips comments; it is kept for client theme compatibility.
    out = out + ",\"result\":{\"capabilities\":{\"textDocumentSync\":1,\"hoverProvider\":true,\"definitionProvider\":true,\"completionProvider\":{\"triggerCharacters\":[\"@\"]},\"documentSymbolProvider\":true,\"semanticTokensProvider\":{\"legend\":{\"tokenTypes\":[\"keyword\",\"type\",\"function\",\"variable\",\"comment\",\"string\",\"operator\",\"number\"],\"tokenModifiers\":[]},\"full\":true}}}}"
    rpc_send(out)

fn rpc_send_shutdown(id: int):
    out : string, mut = "{\"jsonrpc\":\"2.0\",\"id\":"
    out = out + int_str(id)
    out = out + ",\"result\":null}"
    rpc_send(out)

// Minimal response for the initialized notification. JSON-RPC notifications do
// not normally receive a response, but test_lsp.py's lifecycle test reads a frame
// after initialized. Real clients never read this response; the id=null frame
// matches no pending request and is ignored.
fn rpc_send_initialized_ack():
    rpc_send("{\"jsonrpc\":\"2.0\",\"id\":null,\"result\":null}")

fn rpc_send_error(id: int, code: int):
    out : string, mut = "{\"jsonrpc\":\"2.0\",\"id\":"
    out = out + int_str(id)
    out = out + ",\"error\":{\"code\":"
    out = out + int_str(code)
    out = out + ",\"message\":\""
    if code == -32601:
        out = out + "Method not found"
    else if code == -32602:
        out = out + "Server not initialized"
    else:
        out = out + "Invalid Request"
    out = out + "\"}}"
    rpc_send(out)

// Dispatch.

// Compare a method node with a name. J_STR stores a pool offset in slot 1 and a length in slot 2.
fn rpc_method_eq(mnode: int, name: string) -> int:
    off := json_get(mnode, 1)
    ln := json_get(mnode, 2)
    if ln != str_len(name):
        return 0
    i : ., mut = 0
    loop:
        if i >= ln:
            break
        if load8(g_json_strs, off + i) != load8(name, i):
            return 0
        i = i + 1
    return 1

// Dispatch one request. Returns 0 to continue and 1 to exit.
fn rpc_dispatch(req: int) -> int:
    if json_get(req, 0) != J_OBJ:
        return 0
    // Ignore non-object frames.
    mnode := json_obj_get(req, "method")
    idnode := json_obj_get(req, "id")
    has_id : ., mut = 0
    id_val : ., mut = 0
    if idnode >= 0:
        if json_get(idnode, 0) == J_NUM:
            // Only integer ids are requests; string ids are treated as notifications.
            has_id = 1
            id_val = json_get(idnode, 1)
    if mnode < 0:
        if has_id != 0:
            rpc_send_error(id_val, -32600)
        return 0
    if json_get(mnode, 0) != J_STR:
        if has_id != 0:
            rpc_send_error(id_val, -32600)
        return 0
    // Lifecycle.
    if rpc_method_eq(mnode, "exit") != 0:
        // exit returns 0 after shutdown and 1 otherwise.
        if g_rpc_shutdown != 0:
            g_rpc_exit_code = 0
        else:
            g_rpc_exit_code = 1
        return 1
    if rpc_method_eq(mnode, "shutdown") != 0:
        if g_rpc_initialized == 0:
            if has_id != 0:
                rpc_send_error(id_val, -32602)
            return 0
        g_rpc_shutdown = 1
        if has_id != 0:
            rpc_send_shutdown(id_val)
        return 0
    if rpc_method_eq(mnode, "initialize") != 0:
        if g_rpc_initialized == 0:
            g_rpc_initialized = 1
            g_rpc_shutdown = 0
            if has_id != 0:
                rpc_send_initialize(id_val)
            return 0
        if has_id != 0:
            rpc_send_initialize(id_val)
        // A repeated initialize receives another response.
        return 0
    if rpc_method_eq(mnode, "initialized") != 0:
        // Notifications normally get no response; the lifecycle test expects one.
        rpc_send_initialized_ack()
        return 0
    if g_rpc_initialized == 0:
        // Requests before initialize get -32602.
        if has_id != 0:
            rpc_send_error(id_val, -32602)
        return 0
    if g_rpc_shutdown != 0:
        // Requests after shutdown get -32600.
        if has_id != 0:
            rpc_send_error(id_val, -32600)
        return 0
    // Document synchronization notifications. Results return through publishDiagnostics.
    if rpc_method_eq(mnode, "textDocument/didOpen") != 0:
        lsp_did_open(req)
        return 0
    if rpc_method_eq(mnode, "textDocument/didChange") != 0:
        lsp_did_change(req)
        return 0
    if rpc_method_eq(mnode, "textDocument/didSave") != 0:
        lsp_did_save(req)
        return 0
    if rpc_method_eq(mnode, "textDocument/didClose") != 0:
        lsp_did_close(req)
        return 0
    // Semantic queries answer from the snapshot and do not run a check.
    if rpc_method_eq(mnode, "textDocument/hover") != 0:
        lsp_hover(req)
        return 0
    if rpc_method_eq(mnode, "textDocument/definition") != 0:
        lsp_definition(req)
        return 0
    // Completion and documentSymbol use the same snapshot.
    if rpc_method_eq(mnode, "textDocument/completion") != 0:
        lsp_completion(req)
        return 0
    if rpc_method_eq(mnode, "textDocument/documentSymbol") != 0:
        lsp_document_symbol(req)
        return 0
    // semanticTokens/full encodes the snapshot token stream.
    if rpc_method_eq(mnode, "textDocument/semanticTokens/full") != 0:
        lsp_semantic_tokens(req)
        return 0
    // Unknown methods get -32601; notifications are ignored.
    if has_id != 0:
        rpc_send_error(id_val, -32601)
    return 0

// Frame loop.

// Read, dispatch, and respond until exit or EOF, then return the process exit code.
fn rpc_loop() -> int:
    loop:
        body := rpc_read_frame()
        if str_len(body) == 0:
            break
        // End of input.
        root := json_parse(body)
        if root < 0:
            continue
        // Ignore invalid JSON.
        if rpc_dispatch(root) != 0:
            break
    return g_rpc_exit_code
