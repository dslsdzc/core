// main.cr: corelsp entry point.
import _import

fn lsp_main() -> int:
    // stdout is the LSP protocol channel. Any extra byte disconnects strict
    // clients such as VS Code. Suppress res_imports progress and warnings here;
    // the corec command line is unaffected.
    g_silent_stdout = 1
    return rpc_loop()
