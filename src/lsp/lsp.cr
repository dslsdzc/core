// === lsp.cr ===
// 文档状态（g_open_docs）+ 静默检查管线 + publishDiagnostics（Task 3）。
//
// 依赖拼接顺序：本文件在 build_selfhost_native.py corelsp 段 concat 列表中
// 位于 json.cr / rpc.cr 之后——json_new/json_obj_get/g_json_strs、
// rpc_send 等均为同翻译单元内可见。
//
// ── 检查管线 ──
//   lsp_check_file(path, src)：g_source 置源文本 → reset_frontend_state()
//   → tokenize → res_imports → parse_all →（parse 阶段有诊断则跳过
//   check_all，AST 可能不完整）→ check_all → publishDiagnostics。
//   禁止 run_frontend()——它含 println("[1/5]...") 进度输出会污染 stdout
//   协议通道。
//
// ── publishDiagnostics ──
//   主文件（g_files[0]，当前检查文档）无条件发布——无诊断即空数组清旧；
//   其余有诊断的文件（file_id 去重）逐个发布。file_id → 路径经 g_files
//   路径表，uri = "file://" + path。诊断字段：range（1-based → 0-based
//   减 1）、severity=1、message（JSON 转义）。
//
// 注意（Python bootstrap 地雷）：字符串累加必须从字面量初始化的
// `: string, mut` 累加器出发；本文件所有拼接均遵循该模式。

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
    uri := lsp_str_pool_copy(json_get(un, 1), json_get(un, 2))
    return str_eq(lsp_uri_to_path(uri), g_lsp_snapshot_path)

// 从 JSON 字符串池复制字节段 → 稳定堆字符串。
// 池在每次 json_parse 会被重置复用，直接存池内指针会在下一帧失效。
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

// "file:///tmp/x.cr" → "/tmp/x.cr"；无前缀原样返回
fn lsp_uri_to_path(uri: string) -> string:
    ul := str_len(uri)
    if ul >= 7 && load8(uri, 0) == 102 && load8(uri, 1) == 105 && load8(uri, 2) == 108 && load8(uri, 3) == 101 && load8(uri, 4) == 58 && load8(uri, 5) == 47 && load8(uri, 6) == 47:
        return str_sub(uri, 7, ul - 7)
    return uri

// JSON 字符串转义（诊断消息含引号/反斜杠/控制符时保证合法 JSON）
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

// 单条诊断 → JSON 片段（范围 1-based → 0-based 减 1；severity=1 错误）
fn lsp_diag_json(di: int) -> string:
    ln := r64(g_diags, di * DIAG_REC_SIZE + 16)
    cl := r64(g_diags, di * DIAG_REC_SIZE + 24)
    msg := load_str_ptr(g_diags, di * DIAG_REC_SIZE + 8)
    line0 : ., mut = ln - 1
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

// 发送某文件（file_id = fni）的 publishDiagnostics 通知；fni = -1 时无匹配
// 诊断 → 空数组（清诊断用）
fn lsp_send_file_diags(uri: string, fni: int):
    out : string, mut = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":"
    out = out + lsp_json_escape_str(uri)
    out = out + ",\"diagnostics\":["
    first : ., mut = 1
    i : ., mut = 0
    loop:
        if i >= g_diag_count:
            break
        if r64(g_diags, i * DIAG_REC_SIZE + 32) == fni:
            if first == 0:
                out = out + ","
            out = out + lsp_diag_json(i)
            first = 0
        i = i + 1
    out = out + "]}}"
    rpc_send(out)

// 对所有有诊断的文件发布；主文件无条件发布（空数组清旧诊断）
fn lsp_publish_diags():
    main_fni : ., mut = -1
    if g_file_count > 0:
        main_fni = r64(g_files, 0)
    main_uri : string, mut = "file://"
    if g_file_count > 0:
        mp := load_str_ptr(g_files, 8)
        if str_len(mp) > 0:
            main_uri = "file://" + mp
    lsp_send_file_diags(main_uri, main_fni)
    // 其余文件：仅发布有诊断者（按 file_id 去重，经 g_files 路径表映射 uri）
    i : ., mut = 0
    loop:
        if i >= g_diag_count:
            break
        fni := r64(g_diags, i * DIAG_REC_SIZE + 32)
        if fni != main_fni && fni >= 0:
            uri : string, mut = "file://"
            fi : ., mut = 0
            loop:
                if fi >= g_file_count:
                    break
                if r64(g_files, fi * 16) == fni:
                    fp := load_str_ptr(g_files, fi * 16 + 8)
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
                    if r64(g_diags, j * DIAG_REC_SIZE + 32) == fni:
                        already = 1
                        break
                    j = j + 1
                if already == 0:
                    lsp_send_file_diags(uri, fni)
        i = i + 1

// 静默检查管线（禁止 run_frontend——进度 println 污染协议通道）
fn lsp_check_file(path: string, src: string):
    g_lsp_snapshot_path = path
    g_source = src
    g_source_dir = dirname(path)
    reset_frontend_state()
    tokenize(g_source)
    res_imports()
    // res_imports 把主文件注册到 g_files[0] 时路径为空串——补上真实路径
    // （供 publishDiagnostics 的 file_id → uri 映射；path 为稳定堆字符串）。
    // 记录布局 {file_id@0, path@8}（module.cr reg_fileid）——旧代码误写 +16
    // （记录 1 的 id 槽）仅靠读写同侧巧合工作，Task 4 的 analysis 按真实布局
    // 读 +8 会拿到空串，故统一为 +8（root cause 修复）。
    if g_file_count > 0:
        store_str_ptr(g_files, 8, path)
    parse_all()
    if g_diag_count > 0:
        // parse 阶段诊断：AST 可能不完整，跳过 check_all（与 run_frontend 一致）
        lsp_publish_diags()
        return
    check_all()
    lsp_publish_diags()

// ── 文档同步处理器（通知，不回响应）───────────────────────────────

fn lsp_did_open(root: int):
    params := json_obj_get(root, "params")
    if params < 0:
        return
    td := json_obj_get(params, "textDocument")
    if td < 0:
        return
    uri_node := json_obj_get(td, "uri")
    text_node := json_obj_get(td, "text")
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
    // 全量同步（textDocumentSync=1）：contentChanges[0].text = 完整新文本
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
    // 重跑检查（源文本取打开文档——编辑器内存内容优先于磁盘）
    src := module_get_source(path)
    if str_len(src) > 0:
        lsp_check_file(path, src)

fn lsp_did_close(root: int):
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
    module_open_doc_remove(path)
    if str_eq(path, g_lsp_snapshot_path) != 0:
        g_lsp_snapshot_path = ""
    // 清诊断：发布空数组
    lsp_send_file_diags("file://" + path, -1)

// ── hover / definition（Task 4）──────────────────────────────
// 请求（带 id）→ 响应。查询基于最后一次成功检查的快照（analysis.cr），
// 不触发检查。position 为 LSP 0-based；无结果 → result:null。

// 响应体：contents 非空 → {"contents": "<文本>"}，否则 null
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

// 响应体：loc 非空 → {"uri","range"} Location，否则 null
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

// ── completion / documentSymbol（Task 5）────────────────────────
// 请求（带 id）→ 响应。查询基于最后一次成功检查的快照（analysis.cr），
// 不触发检查。响应体复用 lsp_send_def_resp 的 "result":<json> 形状。

// textDocument/completion：params.position（0-based）+ context（当前仅
// 忽略——触发类型不影响候选）；result 为 {"items":[...]}，坏参数 → 空 items。
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

// textDocument/documentSymbol：params.textDocument.uri 只需存在即可
// （符号来自快照，与 uri 具体值无关）；result 为 JSON 数组。
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

// ── semanticTokens（Task 6）──────────────────────────────────
// textDocument/semanticTokens/full：params.textDocument.uri 只需存在即可
// （令牌来自快照，与 uri 具体值无关——与 documentSymbol 同模式）；result
// 为 {"data":[...]}（差分编码见 analysis.cr）。坏参数 → 空 data。
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
