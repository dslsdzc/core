#!/usr/bin/env python3
"""LSP completion follows the same library export table as the checker.

The document imports hashmap. Public members must be offered; library-private
members (findKey/grow) must not appear. This is independent of the older
test_lsp integration suite.
"""

import json
import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
BIN = BASE / "build" / "corelsp"


def _read_frame(proc):
    headers = {}
    while True:
        line = proc.stdout.readline()
        if line in (b"\r\n", b"\n"):
            break
        k, _, v = line.decode().partition(":")
        headers[k.strip().lower()] = v.strip()
    n = headers.get("content-length")
    if not n:
        return None
    return json.loads(proc.stdout.read(int(n)))


def _send(proc, msg):
    body = json.dumps(msg).encode()
    proc.stdin.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
    proc.stdin.flush()


def main():
    proc = subprocess.Popen([str(BIN)], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    try:
        _send(proc, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
        _read_frame(proc)
        uri = "file:///tmp/pub_lsp_visibility.cr"
        src = "import hashmap\nfn main() -> int:\n    m : IntMap = intMap()\n    return 0\n"
        _send(proc, {"jsonrpc": "2.0", "method": "textDocument/didOpen",
                     "params": {"textDocument": {"uri": uri, "version": 1, "text": src}}})
        diag = _read_frame(proc)
        assert diag is not None and diag.get("method") == "textDocument/publishDiagnostics", diag
        _send(proc, {"jsonrpc": "2.0", "id": 2, "method": "textDocument/completion",
                     "params": {"textDocument": {"uri": uri},
                                "position": {"line": 3, "character": 2},
                                "context": {"triggerKind": 1}}})
        resp = _read_frame(proc)
        assert resp is not None and "result" in resp, resp
        items = {it["label"] for it in resp["result"]["items"]}
        for name in ("IntMap", "intMap", "intMapWith", "IntMap.put", "IntMap.get"):
            assert name in items, (name, sorted(items))
        for hidden in ("IntMap.findKey", "IntMap.findSlot", "IntMap.grow"):
            assert hidden not in items, (hidden, sorted(items))
        # Hover follows the same export table: the pub type is documented.
        _send(proc, {"jsonrpc": "2.0", "id": 3, "method": "textDocument/hover",
                     "params": {"textDocument": {"uri": uri},
                                "position": {"line": 2, "character": 8}}})
        hov = _read_frame(proc)
        assert hov is not None and hov.get("result"), hov
        assert "struct IntMap" in hov["result"]["contents"], hov

        # Diagnostics for imported files report the imported file's own lines,
        # not the concatenated compilation coordinates.
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            helper = td / "helper.cr"
            helper.write_text('fn compute() -> int:\n    x : int = "bad"\n    return x\n')
            main_path = td / "main.cr"
            main_src = "import helper\nfn main() -> int:\n    return compute()\n"
            main_path.write_text(main_src)
            _send(proc, {"jsonrpc": "2.0", "method": "textDocument/didOpen",
                         "params": {"textDocument": {"uri": "file://" + str(main_path),
                                                     "version": 1, "text": main_src}}})
            got = None
            for _ in range(3):
                frame = _read_frame(proc)
                if frame and frame.get("method") == "textDocument/publishDiagnostics" \
                        and str(helper) in frame["params"]["uri"]:
                    got = frame
                    break
            assert got is not None, "no diagnostics for imported helper.cr"
            diag = got["params"]["diagnostics"]
            assert diag and diag[0]["range"]["start"]["line"] == 1, got
    finally:
        proc.stdin.close()
        proc.wait(timeout=5)
    print("LSP PUB VISIBILITY PASS")


if __name__ == "__main__":
    main()
