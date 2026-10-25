// === lsp.cr ===
// Document state, the silent check pipeline, and publishDiagnostics.
//
// Build order: this file follows json.cr and rpc.cr in the corelsp concat list.
// json_new, json_obj_get, g_json_strs, and rpc_send are visible in the same
// translation unit.
//
// Check pipeline: lsp_check_file sets g_source, calls reset_frontend_state,
// tokenize, res_imports, parse_all, check_all when parsing produced no
// diagnostics, then publishes diagnostics. Do not call run_frontend: its
// "[1/5]..." progress output would corrupt the protocol stream.
//
// publishDiagnostics: the main file (g_files[0]) is always published, so an
// empty array clears stale diagnostics. Other files with diagnostics are
// published once each. File ids map to paths through g_files, and the URI is
// "file://" plus the path. Diagnostics use a 0-based range, severity 1, and a
// JSON-escaped message.
//
// String accumulation must start from a literal-initialized `: string, mut`
// accumulator; the bootstrap parser requires that form.

g_lsp_snapshot_path : string, mut

fn lsp_request_matches_snapshot(root: int) -> int:
    params := json_obj_get(root, "params")
    if params < 0:
        return 0
    td := json_obj_get(params, "textDocument")
    if td < 0:
        return 0
    un := json_obj_get(td, "uri")
    if un < 0 || json_get(un, 0) != J_STR:
        return 0
    uri : ., mut = lsp_str_pool_copy(json_get(un, 1), json_get(un, 2))
    return str_eq(lsp_uri_to_path(uri), g_lsp_snapshot_path)

// Copy a byte range from the JSON string pool to a stable heap string. The pool
// is reset on each json_parse, so pointers into it expire after the frame.
fn lsp_str_pool_copy(off: int, len: int) -> string:
    s := alloc(len + 1)
    i : ., mut = 0
    loop:
        if i >= len:
            break
        store8(s, i, load8(g_json_strs, off + i))
        i = i + 1
    store8(s, len, 0)
    return s

// Strip file:// from an LSP URI; return the URI unchanged when absent.
fn lsp_uri_to_path(uri: string) -> string:
    ul := str_len(uri)
    if ul >= 7 && load8(uri, 0) == 102 && load8(uri, 1) == 105 && load8(uri, 2) == 108 && load8(uri, 3) == 101 && load8(uri, 4) == 58 && load8(uri, 5) == 47 && load8(uri, 6) == 47:
        return str_sub(uri, 7, ul - 7)
    return uri

// Escape a string for JSON, including quotes, backslashes, and control bytes.
fn lsp_json_escape_str(s: string) -> string:
    sl := str_len(s)
    out : string, mut = "\""
    i : ., mut = 0
    loop:
        if i >= sl:
            break
        c := load8(s, i)
        if c == 34:
            out = out + "\\\""
        else if c == 92:
            out = out + "\\\\"
        else if c == 10:
            out = out + "\\n"
        else if c == 13:
            out = out + "\\r"
        else if c == 9:
            out = out + "\\t"
        else if c < 32:
            out = out + _jhex4(c)
        else:
            out = out + chr(c)
        i = i + 1
    out = out + "\""
    return out

// One diagnostic as a JSON object. Convert 1-based positions to 0-based and use severity 1.
fn lsp_diag_json(di: int) -> string:
    ln := cell_load(g_diags, di * DIAG_REC_SIZE + 16)
    cl := cell_load(g_diags, di * DIAG_REC_SIZE + 24)
    msg := load_str_ptr(g_diags, di * DIAG_REC_SIZE + 8)
    // Diagnostics carry concatenated line coordinates. Convert them back to the
    // owning file so imported files do not report lines past their own EOF.
    off := analysis_line_offset(ln)
    line0 : ., mut = ln - 1 - off
    if line0 < 0:
        line0 = 0
    col0 : ., mut = cl - 1
    if col0 < 0:
        col0 = 0
    out : string, mut = "{\"range\":{\"start\":{\"line\":"
    out = out + int_str(line0)
    out = out + ",\"character\":"
    out = out + int_str(col0)
    out = out + "},\"end\":{\"line\":"
    out = out + int_str(line0)
    out = out + ",\"character\":"
    out = out + int_str(col0 + 1)
    out = out + "}},\"severity\":1,\"message\":"
    out = out + lsp_json_escape_str(msg)
    out = out + "}"
    return out

// Send publishDiagnostics for one file. fni = -1 sends an empty array to clear diagnostics.
fn lsp_send_file_diags(uri: string, fni: int):
    out : string, mut = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":"
    out = out + lsp_json_escape_str(uri)
    out = out + ",\"diagnostics\":["
    first : ., mut = 1
    i : ., mut = 0
    loop:
        if i >= g_diag_count:
            break
        if cell_load(g_diags, i * DIAG_REC_SIZE + 32) == fni:
            if first == 0:
                out = out + ","
            out = out + lsp_diag_json(i)
            first = 0
        i = i + 1
    out = out + "]}}"
    rpc_send(out)

// Publish every affected file. The main file is always published, which clears stale diagnostics.
fn lsp_publish_diags():
    main_fni : ., mut = -1
    if g_file_count > 0:
        main_fni = cell_load(g_files, 0)
    main_uri : string, mut = "file://"
    if g_file_count > 0:
        mp := load_str_ptr(g_files, 8)
        if str_len(mp) > 0:
            main_uri = "file://" + mp
    lsp_send_file_diags(main_uri, main_fni)
    // Other files are published only when they have diagnostics, deduplicated by file id.
    i : ., mut = 0
    loop:
        if i >= g_diag_count:
            break
        fni := cell_load(g_diags, i * DIAG_REC_SIZE + 32)
        if fni != main_fni && fni >= 0:
            uri : string, mut = "file://"
            fi : ., mut = 0
            loop:
                if fi >= g_file_count:
                    break
                if cell_load(g_files, fi * 24) == fni:
                    fp := load_str_ptr(g_files, fi * 24 + 8)
                    if str_len(fp) > 0:
                        uri = "file://" + fp
                    break
                fi = fi + 1
            if str_len(uri) > 7:
                already : ., mut = 0
                j : ., mut = 0
                loop:
                    if j >= i:
                        break
                    if cell_load(g_diags, j * DIAG_REC_SIZE + 32) == fni:
                        already = 1
                        break
                    j = j + 1
                if already == 0:
                    lsp_send_file_diags(uri, fni)
        i = i + 1

// Run the check pipeline without run_frontend, whose progress output would corrupt the protocol stream.
fn lsp_check_file(path: string, src: string):
    g_lsp_snapshot_path = path
    g_source = src
    g_source_name = path
    g_source_dir = dirname(path)
    reset_frontend_state()
    sm_reset()
    g_source_path = path
    source_file := sm_add_virtual(path, src)
    tokenize(source_file, 0)
    res_imports()
    // res_imports registers the main file with an empty path. Store the real path
    // for the file-id to URI mapping. The record layout is {file_id at 0, path at
    // 8}; analysis reads the path at offset 8.
    if g_file_count > 0:
        store_str_ptr(g_files, 8, path)
    parse_all_files()
    // Restore the open document's token stream. Position analysis (hover,
    // definition, semantic tokens) works on the file the user is editing, not
    // on whichever import happened to be parsed last.
    tokenize(g_main_sm, 0)
    if g_diag_count > 0:
        // Parse diagnostics can leave the AST incomplete, so skip check_all.
        lsp_publish_diags()
        return
    check_all()
    lsp_publish_diags()

// Document synchronization notifications; they send no response.

fn lsp_did_open(root: int):
    params := json_obj_get(root, "params")
    if params < 0:
        return
    td := json_obj_get(params, "textDocument")
    if td < 0:
        return
    uri_node := json_obj_get(td, "uri")
    text_node : ., mut = json_obj_get(td, "text")
    if uri_node < 0 || text_node < 0:
        return
    if json_get(uri_node, 0) != J_STR || json_get(text_node, 0) != J_STR:
        return
    uri := lsp_str_pool_copy(json_get(uri_node, 1), json_get(uri_node, 2))
    src := lsp_str_pool_copy(json_get(text_node, 1), json_get(text_node, 2))
    path := lsp_uri_to_path(uri)
    module_open_doc_set(path, src)
    lsp_check_file(path, src)

fn lsp_did_change(root: int):
    params := json_obj_get(root, "params")
    if params < 0:
        return
    td := json_obj_get(params, "textDocument")
    changes := json_obj_get(params, "contentChanges")
    if td < 0 || changes < 0:
        return
    uri_node := json_obj_get(td, "uri")
    if uri_node < 0 || json_get(uri_node, 0) != J_STR:
        return
    // Full sync: contentChanges[0].text is the complete new text.
    c0 := json_array_get(changes, 0)
    text_node : ., mut = -1
    if c0 >= 0:
        text_node = json_obj_get(c0, "text")
    if text_node < 0 || json_get(text_node, 0) != J_STR:
        return
    uri := lsp_str_pool_copy(json_get(uri_node, 1), json_get(uri_node, 2))
    src := lsp_str_pool_copy(json_get(text_node, 1), json_get(text_node, 2))
    path := lsp_uri_to_path(uri)
    module_open_doc_set(path, src)
    lsp_check_file(path, src)

fn lsp_did_save(root: int):
    params := json_obj_get(root, "params")
    if params < 0:
        return
    td := json_obj_get(params, "textDocument")
    if td < 0:
        return
    uri_node := json_obj_get(td, "uri")
    if uri_node < 0 || json_get(uri_node, 0) != J_STR:
        return
    uri := lsp_str_pool_copy(json_get(uri_node, 1), json_get(uri_node, 2))
    path := lsp_uri_to_path(uri)
    // Recheck using the open document text; editor content takes priority over disk.
    src := module_get_source(path)
    if str_len(src) > 0:
        lsp_check_file(path, src)

fn lsp_did_close(root: int):
    params := json_obj_get(root, "params")
    if params < 0:
        return
    td : ., mut = json_obj_get(params, "textDocument")
    if td < 0:
        return
    uri_node := json_obj_get(td, "uri")
    if uri_node < 0 || json_get(uri_node, 0) != J_STR:
        return
    uri := lsp_str_pool_copy(json_get(uri_node, 1), json_get(uri_node, 2))
    path := lsp_uri_to_path(uri)
    module_open_doc_remove(path)
    if str_eq(path, g_lsp_snapshot_path) != 0:
        g_lsp_snapshot_path = ""
    // Clear diagnostics by publishing an empty array.
    lsp_send_file_diags("file://" + path, -1)

// Hover and definition. Requests carry an id and receive a response. Queries use
// the snapshot from the last successful check in analysis.cr and do not run a
// check. Positions are LSP 0-based; no result sends result:null.

// Response: {"contents": text} when contents is non-empty, otherwise null.
fn lsp_send_hover_resp(root: int, contents: string):
    idnode := json_obj_get(root, "id")
    id_val : ., mut = 0
    if idnode >= 0 && json_get(idnode, 0) == J_NUM:
        id_val = json_get(idnode, 1)
    out : string, mut = "{\"jsonrpc\":\"2.0\",\"id\":"
    out = out + int_str(id_val)
    if str_len(contents) == 0:
        out = out + ",\"result\":null}"
    else:
        out = out + ",\"result\":{\"contents\":"
        out = out + lsp_json_escape_str(contents)
        out = out + "}}"
    rpc_send(out)

// Response: a {uri, range} Location when loc is non-empty, otherwise null.
fn lsp_send_def_resp(root: int, loc: string):
    idnode := json_obj_get(root, "id")
    id_val : ., mut = 0
    if idnode >= 0 && json_get(idnode, 0) == J_NUM:
        id_val = json_get(idnode, 1)
    out : string, mut = "{\"jsonrpc\":\"2.0\",\"id\":"
    out = out + int_str(id_val)
    out = out + ",\"result\":"
    if str_len(loc) == 0:
        out = out + "null"
    else:
        out = out + loc
    out = out + "}"
    rpc_send(out)

fn lsp_hover(root: int):
    if lsp_request_matches_snapshot(root) == 0:
        lsp_send_hover_resp(root, "")
        return
    params := json_obj_get(root, "params")
    pos : ., mut = -1
    if params >= 0:
        pos = json_obj_get(params, "position")
    if pos < 0 || json_get(pos, 0) != J_OBJ:
        lsp_send_hover_resp(root, "")
        return
    line_node := json_obj_get(pos, "line")
    col_node := json_obj_get(pos, "character")
    if line_node < 0 || col_node < 0 || json_get(line_node, 0) != J_NUM || json_get(col_node, 0) != J_NUM:
        lsp_send_hover_resp(root, "")
        return
    lsp_send_hover_resp(root, analysis_hover(json_get(line_node, 1), json_get(col_node, 1)))

fn lsp_definition(root: int):
    if lsp_request_matches_snapshot(root) == 0:
        lsp_send_def_resp(root, "")
        return
    params := json_obj_get(root, "params")
    pos : ., mut = -1
    if params >= 0:
        pos = json_obj_get(params, "position")
    if pos < 0 || json_get(pos, 0) != J_OBJ:
        lsp_send_def_resp(root, "")
        return
    line_node := json_obj_get(pos, "line")
    col_node := json_obj_get(pos, "character")
    if line_node < 0 || col_node < 0 || json_get(line_node, 0) != J_NUM || json_get(col_node, 0) != J_NUM:
        lsp_send_def_resp(root, "")
        return
    lsp_send_def_resp(root, analysis_definition(json_get(line_node, 1), json_get(col_node, 1)))

// Completion and documentSymbol. Queries use the snapshot from the last
// successful check in analysis.cr and do not run a check. Responses reuse the
// "result": json shape from lsp_send_def_resp.

// textDocument/completion: params.position is 0-based. The context field is
// ignored because the trigger kind does not affect candidates. The result is
// {"items":[...]}; bad parameters produce an empty array.
fn lsp_completion(root: int):
    if lsp_request_matches_snapshot(root) == 0:
        lsp_send_def_resp(root, "{\"items\":[]}")
        return
    params := json_obj_get(root, "params")
    pos : ., mut = -1
    if params >= 0:
        pos = json_obj_get(params, "position")
    if pos < 0 || json_get(pos, 0) != J_OBJ:
        lsp_send_def_resp(root, "{\"items\":[]}")
        return
    line_node := json_obj_get(pos, "line")
    col_node := json_obj_get(pos, "character")
    if line_node < 0 || col_node < 0 || json_get(line_node, 0) != J_NUM || json_get(col_node, 0) != J_NUM:
        lsp_send_def_resp(root, "{\"items\":[]}")
        return
    lsp_send_def_resp(root, analysis_completion(json_get(line_node, 1), json_get(col_node, 1)))

// textDocument/documentSymbol: params.textDocument.uri only has to be present;
// symbols come from the snapshot. The result is a JSON array.
fn lsp_document_symbol(root: int):
    if lsp_request_matches_snapshot(root) == 0:
        lsp_send_def_resp(root, "[]")
        return
    params := json_obj_get(root, "params")
    td : ., mut = -1
    if params >= 0:
        td = json_obj_get(params, "textDocument")
    if td < 0:
        lsp_send_def_resp(root, "[]")
        return
    uri_node := json_obj_get(td, "uri")
    if uri_node < 0 || json_get(uri_node, 0) != J_STR:
        lsp_send_def_resp(root, "[]")
        return
    lsp_send_def_resp(root, analysis_document_symbol())

// textDocument/semanticTokens/full: params.textDocument.uri only has to be
// present; tokens come from the snapshot. The result is {"data":[...]} with the
// differential encoding from analysis.cr. Bad parameters produce empty data.
fn lsp_semantic_tokens(root: int):
    if lsp_request_matches_snapshot(root) == 0:
        lsp_send_def_resp(root, "{\"data\":[]}")
        return
    params := json_obj_get(root, "params")
    td : ., mut = -1
    if params >= 0:
        td = json_obj_get(params, "textDocument")
    if td < 0:
        lsp_send_def_resp(root, "{\"data\":[]}")
        return
    uri_node := json_obj_get(td, "uri")
    if uri_node < 0 || json_get(uri_node, 0) != J_STR:
        lsp_send_def_resp(root, "{\"data\":[]}")
        return
    lsp_send_def_resp(root, analysis_semantic_tokens())
