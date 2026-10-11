// === rpc.cr ===
// corelsp JSON-RPC 2.0 帧循环 + 生命周期握手（Task 2）。
//
// 依赖拼接顺序：本文件在 build_selfhost_native.py corelsp 段 concat 列表中
// 位于 json.cr 之后（concat 会剥离 import 行，故不写 import）——
// json_new/json_parse/json_obj_get/g_json_strs 等均为同翻译单元内可见。
//
// ── 协议 ──
//   读帧：逐字节收头到 "\r\n\r\n"（Content-Length 大小写不敏感），再读满 N 字节体。
//   写帧："Content-Length: N\r\n\r\n" + 体（单次 write）。
//   分发：initialize / initialized / shutdown / exit 生命周期；
//         未知方法 → -32601；initialize 前收到其他请求 → -32602；
//         通知（无 id）不回响应；shutdown 后 exit → 退出码 0（未 shutdown 即
//         exit → 1，LSP 规范）。EOF（客户端关闭 stdin）→ 正常退出 0。
//
// 注意（Python bootstrap 地雷）：字符串累加必须从字面量初始化的
// `: string, mut` 累加器出发（裸 BinaryOp 结果变量会被编译成整数 add）；
// 本文件所有拼接均遵循该模式。响应文本为固定形状 + int_str 插值，
// 不经 json 节点树构建（json.cr 无公开的成员表写入接口）。

// ── 常量 ──
RPC_HDR_MAX : int = 8192        // 头缓冲上限（字节）
RPC_BODY_MAX : int = 16777216   // 体上限（16MB 防呆保护）

// ── 状态 ──
g_rpc_initialized : int, mut    // 是否已收到 initialize
g_rpc_shutdown : int, mut       // 是否已收到 shutdown
g_rpc_exit_code : int, mut      // 帧循环结束时的进程退出码
g_rpc_hdr_buf : string, mut     // 头缓冲（惰性 alloc 一次）
g_rpc_hdr_ok : int, mut
g_rpc_in_buf : string, mut      // stdin 分块缓冲，避免 read(1) 系统调用风暴
g_rpc_in_pos : int, mut
g_rpc_in_len : int, mut
g_rpc_in_ok : int, mut

// ── 帧读 ──

// 从 stdin（fd 0）取一个字节；底层按 4KB 分块读取，EOF/错误返回 -1。
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

// 读头直到 "\r\n\r\n"，解析 Content-Length；EOF/坏头返回 -1
fn rpc_read_header() -> int:
    if g_rpc_hdr_ok == 0:
        g_rpc_hdr_buf = alloc(RPC_HDR_MAX)
        g_rpc_hdr_ok = 1
    buf := g_rpc_hdr_buf
    hlen : ., mut = 0
    seen : ., mut = 0   // 已匹配 "\r\n\r\n" 前缀的连续字节数
    loop:
        c := rpc_read_byte()
        if c < 0:
            return -1
        // EOF
        if hlen >= RPC_HDR_MAX:
            return -1
        // 头过长
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
            // 当前字节可作新一轮 \r 起点
        if seen >= 4:
            break
    return rpc_find_len(buf, hlen)

// buf[pos..] 与 key 大小写不敏感比较（键后必须为 ':' 或空白）
fn rpc_key_at(buf: string, pos: int, key: string) -> int:
    kl := str_len(key)
    if pos < 0:
        return 0
    i : ., mut = 0
    loop:
        if i >= kl:
            break
        c := load8(buf, pos + i)
        kc := load8(key, i)
        if c >= 65 && c <= 90:
            c = c + 32
        // 大写转小写
        if c != kc:
            return 0
        i = i + 1
    c2 := load8(buf, pos + kl)
    if c2 == 58:
        return 1
    // ':'
    if c2 == 32 || c2 == 9:
        return 1
    // 空格 / tab
    return 0

// 从头缓冲解析 Content-Length；找不到/非法/超上限返回 -1
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

// 读满 n 字节体；EOF 中断返回已读部分（调用方 json_parse 失败即忽略）
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

// 读一帧体；EOF/坏头返回 ""（str_len == 0 由调用方判定）
fn rpc_read_frame() -> string:
    n := rpc_read_header()
    if n < 0:
        return ""
    return rpc_read_body(n)

// ── 帧写 ──

// 写一帧：Content-Length 头 + 体（单次 write；响应 < PIPE_BUF，原子写）
fn rpc_send(body: string):
    bl := str_len(body)
    hdr : string, mut = "Content-Length: "
    hdr = hdr + int_str(bl)
    hdr = hdr + "\r\n\r\n"
    hdr = hdr + body
    syscall3(1, 1, hdr, str_len(hdr))

// 固定形状响应体（错误消息按 code 选字面量，避免字符串参数拼接）
fn rpc_send_initialize(id: int):
    out : string, mut = "{\"jsonrpc\":\"2.0\",\"id\":"
    out = out + int_str(id)
    // Task 5：声明 completion（@ 触发）/ documentSymbol 能力——客户端据此
    // 才发送对应请求；textDocumentSync 保持 1（全量同步，Task 3 契约）。
    // Task 6：semanticTokensProvider/full——legend 顺序与 analysis.cr
    // analysis_kind_type 的下标严格一致（keyword/type/function/variable/
    // comment/string/operator/number）；comment 类无令牌（lexer 跳过注释），
    // 保留仅为客户端主题对齐。
    // Task 4 能力通告（2026-08-28）：hover/definition 处理器已接线
    // （rpc_dispatch L292-293），此前缺通告——客户端（Zed 等）只在通告后
    // 才发送对应请求。
    out = out + ",\"result\":{\"capabilities\":{\"textDocumentSync\":1,\"hoverProvider\":true,\"definitionProvider\":true,\"completionProvider\":{\"triggerCharacters\":[\"@\"]},\"documentSymbolProvider\":true,\"semanticTokensProvider\":{\"legend\":{\"tokenTypes\":[\"keyword\",\"type\",\"function\",\"variable\",\"comment\",\"string\",\"operator\",\"number\"],\"tokenModifiers\":[]},\"full\":true}}}}"
    rpc_send(out)

fn rpc_send_shutdown(id: int):
    out : string, mut = "{\"jsonrpc\":\"2.0\",\"id\":"
    out = out + int_str(id)
    out = out + ",\"result\":null}"
    rpc_send(out)

// initialized 通知的最小响应帧。JSON-RPC 规范：通知（无 id）不应回响应；
// 但 brief 的集成测试（test_lsp.py test_lifecycle）对 initialized 调用
// read_frame 等待一帧（测试契约优先，逐字实现）——真实 LSP 客户端从不
// 读取 initialized 的响应，多余帧以 id=null 不匹配任何挂起请求而被忽略。
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

// ── 分发 ──

// method 节点与名字比较（J_STR 槽：1 = 字符串池偏移，2 = 长度）
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

// 分发一帧请求；返回 0 = 继续循环，1 = 退出
fn rpc_dispatch(req: int) -> int:
    if json_get(req, 0) != J_OBJ:
        return 0
    // 非对象：v1 忽略
    mnode := json_obj_get(req, "method")
    idnode := json_obj_get(req, "id")
    has_id : ., mut = 0
    id_val : ., mut = 0
    if idnode >= 0:
        if json_get(idnode, 0) == J_NUM:
            // v1 仅整数 id；字符串 id 视作通知
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
    // 生命周期
    if rpc_method_eq(mnode, "exit") != 0:
        // exit 通知：shutdown 已收到 → 退出码 0，否则 1（LSP 规范）
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
        // 重复 initialize：v1 再回一次
        return 0
    if rpc_method_eq(mnode, "initialized") != 0:
        // 通知：按规范不回；brief 测试契约要求回一帧（见 rpc_send_initialized_ack）
        rpc_send_initialized_ack()
        return 0
    if g_rpc_initialized == 0:
        // initialize 前的其他请求 → -32602
        if has_id != 0:
            rpc_send_error(id_val, -32602)
        return 0
    if g_rpc_shutdown != 0:
        // shutdown 后的请求 → -32600
        if has_id != 0:
            rpc_send_error(id_val, -32600)
        return 0
    // 文档同步（Task 3）：通知，不回响应——检查结果经 publishDiagnostics 通知回
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
    // 语义查询（Task 4）：请求，回响应——基于快照，不触发检查
    if rpc_method_eq(mnode, "textDocument/hover") != 0:
        lsp_hover(req)
        return 0
    if rpc_method_eq(mnode, "textDocument/definition") != 0:
        lsp_definition(req)
        return 0
    // 语义查询（Task 5）：completion / documentSymbol——同一快照模式
    if rpc_method_eq(mnode, "textDocument/completion") != 0:
        lsp_completion(req)
        return 0
    if rpc_method_eq(mnode, "textDocument/documentSymbol") != 0:
        lsp_document_symbol(req)
        return 0
    // 语义查询（Task 6）：semanticTokens/full——快照令牌流 → 差分编码
    if rpc_method_eq(mnode, "textDocument/semanticTokens/full") != 0:
        lsp_semantic_tokens(req)
        return 0
    // 未知方法 → -32601（通知静默忽略）
    if has_id != 0:
        rpc_send_error(id_val, -32601)
    return 0

// ── 帧循环 ──

// 读帧 → 分发 → 写响应，直到 exit 通知或 stdin EOF；返回进程退出码
fn rpc_loop() -> int:
    loop:
        body := rpc_read_frame()
        if str_len(body) == 0:
            break
        // EOF
        root := json_parse(body)
        if root < 0:
            continue
        // 非法 JSON：v1 忽略
        if rpc_dispatch(root) != 0:
            break
    return g_rpc_exit_code
