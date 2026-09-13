#!/usr/bin/env python3
# test_lsp.py — corelsp 集成测试套件（Task 1-6 功能 + Task 7 统一驱动）
#
# 组织方式（Task 7 统一驱动）：八组测试按序执行，每组独立 spawn corelsp
# （隔离全局状态——corelsp 是单文档全局状态机，跨组复用会串状态）：
#   1. lifecycle                    — initialize/initialized/未知方法/shutdown/exit
#   2. jsonrpc error codes          — initialize 前请求 → -32602
#   3. diagnostics + reset          — didOpen 好/坏文件，发布诊断 + 幽灵诊断回归
#   4. hover + definition           — 语义查询（声明定位）
#   5. completion + documentSymbol  — 候选/前缀过滤/@ 内建/符号表
#   6. semanticTokens/full          — 差分编码令牌流
#   6b. semanticTokens 多行         — 跨行差分重建位置 + deltaStartChar 非负
#   7. stdout 污染守卫              — 原始字节流严格帧扫描，0 脏字节
#
# 结尾打印 "lsp suite: ALL PASS (N tests)"；任一失败 → 打印 FAIL 行并非零退出。

import json, re, select, subprocess, sys

BIN = "build/corelsp"

def read_frame(proc) -> dict:
    headers = {}
    while True:
        line = proc.stdout.readline()
        if line in (b"\r\n", b"\n"):
            break
        k, _, v = line.decode().partition(":")
        headers[k.strip().lower()] = v.strip()
    if "content-length" not in headers:
        return None
    return json.loads(proc.stdout.read(int(headers["content-length"])))

def send(proc, msg: dict) -> dict:
    body = json.dumps(msg).encode()
    proc.stdin.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
    proc.stdin.flush()
    return read_frame(proc)

def raw_send(proc, msg: dict):
    """写一帧但不读（用于通知——didOpen 等会先产生别的帧）"""
    body = json.dumps(msg).encode()
    proc.stdin.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
    proc.stdin.flush()

def shutdown_and_wait(proc):
    send(proc, {"jsonrpc": "2.0", "id": 9, "method": "shutdown"})
    proc.stdin.close()
    proc.wait(timeout=5)

def test_lifecycle():
    proc = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    r = send(proc, {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                    "params": {"capabilities": {}}})
    assert r["result"]["capabilities"]["textDocumentSync"] == 1, r
    send(proc, {"jsonrpc": "2.0", "method": "initialized", "params": {}})
    r = send(proc, {"jsonrpc": "2.0", "id": 2, "method": "bogus/method"})
    assert r["error"]["code"] == -32601, r
    r = send(proc, {"jsonrpc": "2.0", "id": 3, "method": "shutdown"})
    assert r["result"] is None
    proc.stdin.close()
    assert proc.wait(timeout=5) == 0

def test_jsonrpc_error_codes():
    proc = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    # initialize 前发普通请求 → -32602
    r = send(proc, {"jsonrpc": "2.0", "id": 9, "method": "hover", "params": {}})
    assert r["error"]["code"] == -32602, r
    send(proc, {"jsonrpc": "2.0", "id": 10, "method": "initialize", "params": {}})
    r = send(proc, {"jsonrpc": "2.0", "id": 11, "method": "shutdown"})
    proc.stdin.close(); proc.wait(timeout=5)

def test_diagnostics_and_reset():
    proc = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    send(proc, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
    uri = "file:///tmp/test_sample.cr"
    def open_doc(text):
        # 注意：不能用 send()——它自带 read_frame，会吞掉 publishDiagnostics 帧；
        # 直接写帧再读一帧（didOpen 是通知，服务器只回 publishDiagnostics 通知）
        body = json.dumps({"jsonrpc": "2.0", "method": "textDocument/didOpen",
                           "params": {"textDocument": {"uri": uri, "version": 1,
                                                       "text": text}}}).encode()
        proc.stdin.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
        proc.stdin.flush()
        return read_frame(proc)
    r = open_doc(SAMPLE)
    assert r is not None and r["method"] == "textDocument/publishDiagnostics", r
    assert r["params"]["diagnostics"] == [], r
    # 重置回归：改坏 → 诊断必须更新（抓幽灵诊断）
    r = open_doc(BAD)
    assert r["params"]["diagnostics"] != [], r
    shutdown_and_wait(proc)

def test_hover_and_definition():
    proc = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    send(proc, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
    uri = "file:///tmp/hover_test.cr"
    #       0: fn add(a: int, b: int) -> int {
    #       1:     return a + b;
    #       2: }
    #       3: (空行)
    #       4: fn main() -> int {
    #       5:     x := add(1, 2);
    #       6:     return x;
    #       7: }
    src = "fn add(a: int, b: int) -> int {\n    return a + b;\n}\n\nfn main() -> int {\n    x := add(1, 2);\n    return x;\n}\n"
    # 注意：didOpen 不能用 send()——它自带 read_frame 会吞掉 publishDiagnostics
    # 帧（brief 原文 send()+read_frame() 双读会永久阻塞）；直接写帧再读一帧。
    body = json.dumps({"jsonrpc": "2.0", "method": "textDocument/didOpen",
                       "params": {"textDocument": {"uri": uri, "version": 1,
                                                   "text": src}}}).encode()
    proc.stdin.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
    proc.stdin.flush()
    read_frame(proc)  # 丢弃 publishDiagnostics 通知
    # hover 在 add 调用处（0-based line=5, character=10 即 add 起点）
    r = send(proc, {"jsonrpc": "2.0", "id": 2, "method": "textDocument/hover",
                    "params": {"textDocument": {"uri": uri},
                               "position": {"line": 5, "character": 10}}})
    assert "fn add" in r["result"]["contents"], r
    # definition 同位置 → 声明在 line 0
    r = send(proc, {"jsonrpc": "2.0", "id": 3, "method": "textDocument/definition",
                    "params": {"textDocument": {"uri": uri},
                               "position": {"line": 5, "character": 10}}})
    assert r["result"]["uri"] == uri, r
    assert r["result"]["range"]["start"]["line"] == 0, r
    shutdown_and_wait(proc)

def test_completion_and_document_symbol():
    proc = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    send(proc, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
    uri = "file:///tmp/symbols_test.cr"
    #       0: fn add(a: int, b: int) -> int {
    #       1:     return a + b;
    #       2: }
    #       3: (空行)
    #       4: struct Point { x: int, y: int }
    #       5: (空行)
    #       6: enum Color { Red, Green, Blue }
    #       7: (空行)
    #       8: fn main() -> int {
    #       9:     poi := add(1, 2);
    #      10:     return @sizeOf(int);
    #      11: }
    src = ("fn add(a: int, b: int) -> int {\n    return a + b;\n}\n\n"
           "struct Point { x: int, y: int }\n\n"
           "enum Color { Red, Green, Blue }\n\n"
           "fn main() -> int {\n    poi := add(1, 2);\n    return @sizeOf(int);\n}\n")
    body = json.dumps({"jsonrpc": "2.0", "method": "textDocument/didOpen",
                       "params": {"textDocument": {"uri": uri, "version": 1,
                                                   "text": src}}}).encode()
    proc.stdin.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
    proc.stdin.flush()
    read_frame(proc)  # 丢弃 publishDiagnostics 通知
    # completion 在空行（line 3）→ 全候选：关键字 + 已声明符号
    r = send(proc, {"jsonrpc": "2.0", "id": 2, "method": "textDocument/completion",
                    "params": {"textDocument": {"uri": uri},
                               "position": {"line": 3, "character": 0},
                               "context": {"triggerKind": 1}}})
    assert "error" not in r, r
    labels = {it["label"]: it["kind"] for it in r["result"]["items"]}
    assert labels["fn"] == 14, r
    assert labels["add"] == 3 and labels["main"] == 3, r
    # kind 为 LSP CompletionItemKind 规范值：Keyword=14/Function=3/
    # Struct=22/Enum=13（终审修正；Task 5 brief 误为 23）
    assert labels["Point"] == 22 and labels["Color"] == 13, r
    # 符号候选前缀过滤（大小写不敏感）：line 9 的 "po"（character 6）→ 仅 Point
    r = send(proc, {"jsonrpc": "2.0", "id": 3, "method": "textDocument/completion",
                    "params": {"textDocument": {"uri": uri},
                               "position": {"line": 9, "character": 6},
                               "context": {"triggerKind": 1}}})
    assert "error" not in r, r
    labels = [it["label"] for it in r["result"]["items"]]
    assert labels == ["Point"], r
    # 关键字前缀过滤："fn" 只匹配关键字 fn（无符号以 fn 开头）
    r = send(proc, {"jsonrpc": "2.0", "id": 4, "method": "textDocument/completion",
                    "params": {"textDocument": {"uri": uri},
                               "position": {"line": 8, "character": 2},
                               "context": {"triggerKind": 1}}})
    assert "error" not in r, r
    labels = [it["label"] for it in r["result"]["items"]]
    assert labels == ["fn"], r
    # completion 在 "@size" 后（line 10，character 16）→ @ 内建过滤
    r = send(proc, {"jsonrpc": "2.0", "id": 5, "method": "textDocument/completion",
                    "params": {"textDocument": {"uri": uri},
                               "position": {"line": 10, "character": 16},
                               "context": {"triggerKind": 1}}})
    assert "error" not in r, r
    assert [it["label"] for it in r["result"]["items"]] == ["sizeOf"], r
    # documentSymbol → 顶层 4 个符号，源顺序 + kind
    r = send(proc, {"jsonrpc": "2.0", "id": 6, "method": "textDocument/documentSymbol",
                    "params": {"textDocument": {"uri": uri}}})
    assert "error" not in r, r
    syms = r["result"]
    assert [s["name"] for s in syms] == ["add", "Point", "Color", "main"], r
    kinds = {s["name"]: s["kind"] for s in syms}
    assert kinds["add"] == 12 and kinds["main"] == 12, r
    # documentSymbol kind 为 LSP SymbolKind 规范值：Function=12/Struct=23/
    # Enum=10（终审修正；Task 5 brief 误为 23）
    assert kinds["Point"] == 23 and kinds["Color"] == 10, r
    shutdown_and_wait(proc)

def test_semantic_tokens():
    proc = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    send(proc, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
    uri = "file:///tmp/semantic_test.cr"
    src = "fn main() -> int { return 42; }"
    body = json.dumps({"jsonrpc": "2.0", "method": "textDocument/didOpen",
                       "params": {"textDocument": {"uri": uri, "version": 1,
                                                   "text": src}}}).encode()
    proc.stdin.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
    proc.stdin.flush()
    read_frame(proc)  # 丢弃 publishDiagnostics 通知
    r = send(proc, {"jsonrpc": "2.0", "id": 2, "method": "textDocument/semanticTokens/full",
                    "params": {"textDocument": {"uri": uri}}})
    assert "error" not in r, r
    data = r["result"]["data"]
    assert data, r                                   # 非空
    assert len(data) % 5 == 0, r                     # 5 的倍数（差分编码格式）
    assert data[0] == 0 and data[1] == 0, r          # 首令牌 delta_line/delta_start == 0
    # 源码 "fn main() -> int { return 42; }"（尾空格 + 收尾 }）应为 11 个
    # 主文件令牌（不含 EOF；res_imports 拼接的 stdlib 令牌被范围过滤排除）
    groups = [data[i:i+5] for i in range(0, len(data), 5)]
    assert len(groups) == 11, r
    # 差分重建位置（delta 恒相对上一令牌起点）→ 与源码肉眼核对
    line = col = 0
    toks = []
    for g in groups:
        line += g[0]
        col += g[1]
        toks.append((line, col, g[2], g[3]))
    # fn=keyword(0)@0:0 len2 | main=function(2)@0:3 len4 | ( @0:7 |
    # ) @0:8 | -> @0:10 len2 | int=type(1)@0:13 len3 | { @0:17 |
    # return=keyword(0)@0:19 len6 | 42=number(7)@0:26 len2 | ; @0:28 |
    # } @0:30
    assert toks[0] == (0, 0, 2, 0), toks
    assert toks[1] == (0, 3, 4, 2), toks
    assert toks[2] == (0, 7, 1, 6), toks
    assert toks[5] == (0, 13, 3, 1), toks
    assert toks[7] == (0, 19, 6, 0), toks
    assert toks[8] == (0, 26, 2, 7), toks
    assert toks[9] == (0, 28, 1, 6), toks
    assert toks[10] == (0, 30, 1, 6), toks
    shutdown_and_wait(proc)

# ── 第 6b 组：semanticTokens 多行差分（Task 8 补）──────────────────────────
# 单行用例不覆盖跨行路径——旧实现 deltaLine>0 时 deltaStartChar 输出相对差，
# 跨行令牌产生负列（LSP 规范要求绝对列）。本组回归：多行源码重建位置必须
# 与源码逐令牌一致，且 deltaStartChar 全为非负。

def test_semantic_tokens_multiline():
    proc = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    send(proc, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
    uri = "file:///tmp/semantic_ml.cr"
    src = "fn main() -> int {\n    return 42;\n}\n"
    body = json.dumps({"jsonrpc": "2.0", "method": "textDocument/didOpen",
                       "params": {"textDocument": {"uri": uri, "version": 1,
                                                   "text": src}}}).encode()
    proc.stdin.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
    proc.stdin.flush()
    read_frame(proc)  # 丢弃 publishDiagnostics 通知
    r = send(proc, {"jsonrpc": "2.0", "id": 2, "method": "textDocument/semanticTokens/full",
                    "params": {"textDocument": {"uri": uri}}})
    assert "error" not in r, r
    data = r["result"]["data"]
    assert data and len(data) % 5 == 0, r
    groups = [data[i:i+5] for i in range(0, len(data), 5)]
    # 差分重建位置：deltaLine==0 → 列累加；deltaLine>0 → 列取绝对 deltaStartChar
    line = col = 0
    toks = []
    for g in groups:
        line += g[0]
        col = col + g[1] if g[0] == 0 else g[1]
        assert g[1] >= 0, f"deltaStartChar 必须非负：{g}"
        toks.append((line, col, g[2], g[3]))
    # fn@0:0 | main@0:3 | (@0:7 | )@0:8 | ->@0:10 | int@0:13 | {@0:17 |
    # return@1:4 | 42@1:11 | ;@1:13 | }@2:0
    assert toks[0] == (0, 0, 2, 0), toks
    assert toks[7] == (1, 4, 6, 0), toks      # return：跨行后列=绝对列 4
    assert toks[8] == (1, 11, 2, 7), toks     # 42
    assert toks[10] == (2, 0, 1, 6), toks     # }：跨行后列=绝对列 0（旧实现 -13）
    shutdown_and_wait(proc)

# ── 第 7 组：stdout 污染守卫 ────────────────────────────────────────────────
# 背景（Task 3 Fix 1）：res_imports 的加载进度/失败/toML 警告曾直接 print 到
# stdout，污染 LSP 帧协议通道（严格客户端无法解析）。修复为 g_silent_stdout
# 门控后，本组做协议卫生回归：完整 didOpen 流程的原始 stdout 字节流必须
# 逐字节全部落在合法帧内（0 脏字节），且不含进度/失败/警告标记。
# （原 pollution_check.py 工作副本脚本，Task 7 并入本套件）

def test_stdout_pollution_guard():
    proc = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    raw_send(proc, {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                    "params": {"capabilities": {}}})
    raw_send(proc, {"jsonrpc": "2.0", "method": "initialized", "params": {}})
    uri = "file:///tmp/pollution_check.cr"
    for text in (SAMPLE, BAD):
        raw_send(proc, {"jsonrpc": "2.0", "method": "textDocument/didOpen",
                        "params": {"textDocument": {"uri": uri, "version": 1,
                                                    "text": text}}})
    raw_send(proc, {"jsonrpc": "2.0", "id": 9, "method": "shutdown"})
    raw_send(proc, {"jsonrpc": "2.0", "method": "exit"})
    proc.stdin.close()
    # read 加超时（终审）：服务器挂起时套件不能跟着挂死——select 检查可读性，
    # 5s 内无数据即 kill 并断言失败（非零退出）
    chunks = []
    while True:
        ready, _, _ = select.select([proc.stdout], [], [], 5)
        if not ready:
            proc.kill()
            assert False, "stdout read 超时（5s）——corelsp 未在 exit 后退出"
        chunk = proc.stdout.read1(1 << 16)
        if not chunk:
            break
        chunks.append(chunk)
    data = b"".join(chunks)
    assert proc.wait(timeout=5) == 0
    # 1) 严格帧扫描：每个字节都必须属于 Content-Length 帧 + 合法 JSON 体；
    #    帧前/帧间/帧后任何脏字节即断言失败（VS Code 严格客户端解析标准）；
    #    同时记录 body 字节范围，供污染标记只扫帧间空隙
    frames = []
    body_ranges = []
    i = 0
    while i < len(data):
        m = re.match(rb"Content-Length: (\d+)\r\n\r\n", data[i:])
        assert m, f"dirty bytes at offset {i}: {data[i:i+60]!r}"
        n = int(m.group(1))
        start = i + m.end()
        body = data[start:start + n]
        assert len(body) == n, f"truncated frame body at offset {start}"
        json.loads(body)  # 必须可解析为合法 JSON
        frames.append(body)
        body_ranges.append((start, start + n))
        i = start + n
    assert len(frames) == 5, frames   # init 响应 + initialized ack + 好/坏文件
    #                               # publishDiagnostics ×2 + shutdown 响应
    # 2) 污染标记（终审修正）：只扫帧间空隙——body 之外的字节（头之前/帧尾
    #    之后/帧头本身）。诊断消息文本可合法含 '->'（如类型不匹配报错），对
    #    含帧体的全字节流扫标记会对诊断过敏误报；空隙是纯协议字节，加载进度
    #    '->'、'!! import fail'、'warning:' 等污染不得出现
    gaps = bytearray()
    prev = 0
    for s, e in body_ranges:
        gaps += data[prev:s]
        prev = e
    gaps += data[prev:]
    for marker in (b"->", b"!! import fail", b"warning:"):
        assert marker not in gaps, f"frame gap contains marker {marker!r}: {bytes(gaps)!r}"
    # 3) 帧形状抽查：好文件空诊断 / 坏文件非空诊断（与 test_diagnostics_and_reset
    #    互补——那边走 lenient 读取，这边证明帧本身结构健全）
    pub_good = json.loads(frames[2])
    pub_bad = json.loads(frames[3])
    assert pub_good["method"] == "textDocument/publishDiagnostics", pub_good
    assert pub_good["params"]["diagnostics"] == [], pub_good
    assert pub_bad["method"] == "textDocument/publishDiagnostics", pub_bad
    assert pub_bad["params"]["diagnostics"] != [], pub_bad
    print(f"  POLLUTION CHECK: {len(frames)} frames, 0 dirty bytes, "
          f"{len(data)} bytes")


def test_large_frame_body():
    """A body larger than the input buffer must still be framed exactly."""
    proc = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    initialize = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                  "params": {"capabilities": {}}}
    body = json.dumps(initialize).encode()
    proc.stdin.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
    proc.stdin.flush()
    response = read_frame(proc)
    assert response["id"] == 1, response

    # Keep the request valid while forcing several 4KB stdin refills.
    uri = "file:///tmp/large_frame.cr"
    text = "fn main() -> int { return 0; }\n" + ("// padding\n" * 600)
    request = {"jsonrpc": "2.0", "method": "textDocument/didOpen",
               "params": {"textDocument": {"uri": uri, "version": 1,
                                              "text": text}}}
    body = json.dumps(request).encode()
    assert len(body) > 4096, len(body)
    proc.stdin.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
    proc.stdin.flush()
    diagnostics = read_frame(proc)
    assert diagnostics["method"] == "textDocument/publishDiagnostics", diagnostics
    assert diagnostics["params"]["diagnostics"] == [], diagnostics
    shutdown_and_wait(proc)

def test_double_open_bridge_cache_reset():
    """R2 P2a Task 3 评审 Critical：桥接缓存（g_term_map；P5 T5 前名 g_shadow_map）必须随类型表重置失效。

    机制：R2 P2a Task 3 起判定路径**无条件**调用 sh_term_of_ti（此前仅 --type-shadow 下译项；
    该旗标已随 R2 P5 Task 5 影子层下线删除），
    而桥接缓存 key = ti 本体；corelsp 每请求 `reset_frontend_state → check_all → init_types`
    会清空重建类型表（**行号空间复用**）→ 陈旧 ti→term 命中即返回 ⇒ 两个不同类型被判等
    （静默漏报）。本用例：同 URI 两次 didOpen，只把 `a` 的数组**元素型** int→bool，第二次
    必须报出 1 条 `Assignment type mismatch`（新进程单跑 V2 = 1 条，见 fixture 注释）。
    修复前实测 RED：V1=0 / V2=0（应为 V2=1）——证据见 r2p2-task-3-report §13。
    """
    proc = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    send(proc, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
    uri = "file:///tmp/bridge_cache_reset.cr"

    def open_doc(text, version):
        # didOpen 是通知：直接写帧再读一帧（不能用 send()——它会吞掉 publishDiagnostics）
        body = json.dumps({"jsonrpc": "2.0", "method": "textDocument/didOpen",
                           "params": {"textDocument": {"uri": uri, "version": version,
                                                       "text": text}}}).encode()
        proc.stdin.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
        proc.stdin.flush()
        return read_frame(proc)

    r1 = open_doc(BRIDGE_V1, 1)
    assert r1 is not None and r1["method"] == "textDocument/publishDiagnostics", r1
    assert r1["params"]["diagnostics"] == [], r1      # 同为 [int;3] → 无诊断
    r2 = open_doc(BRIDGE_V2, 2)
    assert r2 is not None and r2["method"] == "textDocument/publishDiagnostics", r2
    diags = r2["params"]["diagnostics"]
    assert len(diags) == 1, r2                        # [bool;3] ← [int;3]：必须报出
    assert "Assignment type mismatch" in diags[0]["message"], r2
    shutdown_and_wait(proc)


# ── 统一驱动（Task 7）───────────────────────────────────────────────────────
# 按序执行全部测试组（每组独立 spawn，隔离全局状态）；失败即非零退出。

TESTS = [
    test_lifecycle,
    test_jsonrpc_error_codes,
    test_diagnostics_and_reset,
    test_hover_and_definition,
    test_completion_and_document_symbol,
    test_semantic_tokens,
    test_semantic_tokens_multiline,
    test_stdout_pollution_guard,
    test_large_frame_body,
    test_double_open_bridge_cache_reset,
]

def main() -> int:
    failures = []
    for fn in TESTS:
        try:
            fn()
            print(f"  PASS {fn.__name__}")
        except Exception as e:
            failures.append((fn.__name__, e))
            print(f"  FAIL {fn.__name__}: {e!r}")
    if failures:
        for name, e in failures:
            print(f"FAILED: {name}: {e!r}")
        print(f"lsp suite: FAIL ({len(failures)}/{len(TESTS)} tests failed)")
        return 1
    print(f"lsp suite: ALL PASS ({len(TESTS)} tests)")
    return 0

SAMPLE = 'fn main() -> int { return 42; }'
BAD = 'fn main() -> int { return ; }'

# 桥接缓存跨请求失效回归（R2 P2a Task 3 评审 Critical）——两版只差 `a` 的元素型：
# V1 `[int;3]` → 新进程 rc=0（ok）；V2 `[bool;3]` → 新进程 1 条 error[TA01] Assignment
# type mismatch。两次 didOpen 之间类型行号被复用（同 URI 重开），故缓存不失效即漏报。
BRIDGE_V1 = ("fn f() -> int {\n"
             "    a : [int;3] = [1,2,3];\n"
             "    b : [int;3], mut = [4,5,6];\n"
             "    b = a;\n"
             "    return 0;\n"
             "}\n"
             "fn main() -> int { return f(); }\n")
BRIDGE_V2 = ("fn f() -> int {\n"
             "    a : [bool;3] = [true,false,true];\n"
             "    b : [int;3], mut = [4,5,6];\n"
             "    b = a;\n"
             "    return 0;\n"
             "}\n"
             "fn main() -> int { return f(); }\n")

if __name__ == "__main__":
    sys.exit(main())
