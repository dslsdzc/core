// main.cr — corelsp 入口
import _import

fn lsp_main() -> int:
    // LSP 协议通道是 stdout——任何非协议字节都会使严格客户端（VS Code）断连。
    // res_imports 的进度/警告输出在此静默（corec 命令行不受影响，默认 0）。
    g_silent_stdout = 1
    return rpc_loop()
