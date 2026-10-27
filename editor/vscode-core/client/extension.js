// extension.js — corelsp 语言服务器客户端（零依赖，手写 JSON-RPC/stdio 管道）。
//
// 设计要点：
//   - 不引入 vscode-languageclient npm 依赖——保持扩展目录即装即用
//     （`code --install-extension editor/vscode-core/`），与既有纯高亮
//     结构一致（仅新增 client/ 一个目录 + package.json 三处字段）。
//   - 服务器为 LSP v1 兼容子集（见 src/lsp/rpc.cr）：
//       * 请求 id 仅支持数字；字符串 id 被视作通知（本客户端恒用递增整数）。
//       * initialized 通知会额外回一帧 id:null 响应（测试契约，规范不要求）；
//         帧匹配按 id 查找挂起请求，id:null 无匹配即自然忽略，无需特判。
//       * textDocumentSync = 1（全量同步）：didChange 的 contentChanges[0].text
//         必须为完整新文本，故这里传 document.getText()。
//   - 服务器按文档打开顺序维护"最后一次成功检查的快照"（单文档全局状态机），
//     hover/definition/completion/documentSymbol/semanticTokens 均使用快照，
//     客户端按当前活动文档发起请求即可。

const vscode = require('vscode');
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const LANGUAGE_IDS = ['core'];

// 服务器 semanticTokens legend（与 src/lsp/rpc.cr rpc_send_initialize 的
// tokenTypes 顺序严格一致——analysis.cr 按该下标编码差分 data）。
const TOKEN_TYPES = [
  'keyword', 'type', 'function', 'variable',
  'comment', 'string', 'operator', 'number',
];

// ── JSON-RPC 帧编解码 ─────────────────────────────────────────────

class RpcConnection {
  constructor(child) {
    this.child = child;
    this.buf = Buffer.alloc(0);
    this.pending = new Map(); // id → {resolve, reject}
    this.listeners = new Map(); // method → fn[]（通知）
    this.nextId = 1;
    this.closed = false;
    child.stdout.on('data', (d) => this._onData(d));
    child.on('error', () => { this.closed = true; });
    child.on('exit', () => { this.closed = true; });
    // stdin EPIPE 竞态：服务器死亡瞬间，在途请求的 write 可能触发 EPIPE
    // ——Node 对无监听器的 'error' 事件会抛未捕获异常，击穿 extension host。
    // EPIPE 即服务器已退出的正常信号：吞掉并置 closed（后续请求快速失败
    // 返回 "corelsp 未运行"）；其余 stdin 错误记录后同样按已关闭处理。
    child.stdin.on('error', (e) => {
      this.closed = true;
      if (!e || e.code !== 'EPIPE') { console.error('corelsp stdin error:', e); }
    });
  }

  // 发起请求（数字 id）；服务器从不回错误响应以外的失败帧，超时兜底
  request(method, params, timeoutMs = 30000) {
    if (this.closed) { return Promise.reject(new Error('corelsp 未运行')); }
    const id = this.nextId++;
    const body = JSON.stringify({ jsonrpc: '2.0', id, method, params });
    this.child.stdin.write(`Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`corelsp ${method} 超时`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
    });
  }

  notify(method, params) {
    if (this.closed) { return; }
    const body = JSON.stringify({ jsonrpc: '2.0', method, params });
    this.child.stdin.write(`Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
  }

  on(method, fn) {
    if (!this.listeners.has(method)) { this.listeners.set(method, []); }
    this.listeners.get(method).push(fn);
  }

  _onData(d) {
    this.buf = Buffer.concat([this.buf, d]);
    for (;;) {
      const idx = this.buf.indexOf('\r\n\r\n');
      if (idx < 0) { return; }
      const head = this.buf.slice(0, idx).toString();
      const m = /Content-Length:\s*(\d+)/i.exec(head);
      if (!m) { this.buf = this.buf.slice(idx + 4); continue; }
      const len = parseInt(m[1], 10);
      if (this.buf.length < idx + 4 + len) { return; }
      const body = this.buf.slice(idx + 4, idx + 4 + len).toString();
      this.buf = this.buf.slice(idx + 4 + len);
      this._dispatch(body);
    }
  }

  _dispatch(body) {
    let msg;
    try { msg = JSON.parse(body); } catch { return; } // 非协议字节：忽略
    if (msg.id !== undefined && msg.id !== null) {
      const p = this.pending.get(msg.id);
      if (p) {
        clearTimeout(p.timer);
        this.pending.delete(msg.id);
        if (msg.error) { p.reject(new Error(msg.error.message || 'corelsp 错误')); }
        else { p.resolve(msg.result); }
      }
      return;
    }
    if (msg.method && this.listeners.has(msg.method)) {
      for (const fn of this.listeners.get(msg.method)) { fn(msg.params); }
    }
  }
}

// ── 服务器进程管理 ────────────────────────────────────────────────

function resolveServerPath() {
  const cfg = vscode.workspace.getConfiguration('corelsp');
  const p = cfg.get('path', 'build/corelsp');
  if (path.isAbsolute(p)) { return p; }
  const root = vscode.workspace.workspaceFolders && vscode.workspace.workspaceFolders[0];
  return root ? path.join(root.uri.fsPath, p) : p;
}

function spawnServer(output) {
  const bin = resolveServerPath();
  if (!fs.existsSync(bin)) {
    vscode.window.showWarningMessage(
      `找不到 corelsp 服务器（${bin}）。请先构建（python3 build_selfhost_native.py），` +
      '或在设置 corelsp.path 中指定二进制路径。');
    return null;
  }
  const child = spawn(bin, [], { stdio: ['pipe', 'pipe', 'pipe'] });
  child.stderr.on('data', (d) => output.append(d.toString()));
  child.on('exit', (code) => {
    if (code !== 0) { output.appendLine(`corelsp 退出码 ${code}`); }
  });
  return child;
}

// ── 激活 ──────────────────────────────────────────────────────────

async function activate(context) {
  const cfg = vscode.workspace.getConfiguration('corelsp');
  if (!cfg.get('enabled', true)) { return; }

  const output = vscode.window.createOutputChannel('Core LSP');
  context.subscriptions.push(output);
  output.appendLine(`启动 corelsp：${resolveServerPath()}`);

  const child = spawnServer(output);
  if (!child) { return; }
  context.subscriptions.push({ dispose: () => { try { child.kill(); } catch { /* 已退出 */ } } });

  const conn = new RpcConnection(child);
  const diags = vscode.languages.createDiagnosticCollection('core');
  context.subscriptions.push(diags);

  // ── 初始化握手 ──
  const rootUri = vscode.workspace.workspaceFolders
    ? vscode.workspace.workspaceFolders[0].uri.toString() : null;
  try {
    await conn.request('initialize', {
      processId: process.pid,
      rootUri,
      capabilities: {},
    });
  } catch (e) {
    vscode.window.showErrorMessage(`corelsp 初始化失败：${e.message}`);
    return;
  }
  conn.notify('initialized', {});

  // ── 诊断 ──
  conn.on('textDocument/publishDiagnostics', (params) => {
    const uri = vscode.Uri.parse(params.uri);
    const items = (params.diagnostics || []).map((d) => {
      const sev = d.severity === 1 ? vscode.DiagnosticSeverity.Error
        : d.severity === 2 ? vscode.DiagnosticSeverity.Warning
        : d.severity === 3 ? vscode.DiagnosticSeverity.Information
        : vscode.DiagnosticSeverity.Error;
      return new vscode.Diagnostic(
        new vscode.Range(d.range.start.line, d.range.start.character,
                         d.range.end.line, d.range.end.character),
        d.message, sev);
    });
    diags.set(uri, items);
  });

  // ── 文档同步（全量：textDocumentSync=1）──
  const isCoreDoc = (doc) => LANGUAGE_IDS.indexOf(doc.languageId) >= 0;
  const openDoc = (doc) => {
    if (!isCoreDoc(doc)) { return; }
    conn.notify('textDocument/didOpen', {
      textDocument: { uri: doc.uri.toString(), languageId: doc.languageId,
                      version: doc.version, text: doc.getText() },
    });
  };
  const changeDoc = (doc) => {
    if (!isCoreDoc(doc)) { return; }
    conn.notify('textDocument/didChange', {
      textDocument: { uri: doc.uri.toString(), version: doc.version },
      contentChanges: [{ text: doc.getText() }],
    });
  };
  const saveDoc = (doc) => {
    if (!isCoreDoc(doc)) { return; }
    conn.notify('textDocument/didSave', { textDocument: { uri: doc.uri.toString() } });
  };
  const closeDoc = (doc) => {
    if (!isCoreDoc(doc)) { return; }
    conn.notify('textDocument/didClose', { textDocument: { uri: doc.uri.toString() } });
    diags.delete(doc.uri);
  };

  context.subscriptions.push(
    vscode.workspace.onDidOpenTextDocument(openDoc),
    vscode.workspace.onDidChangeTextDocument((e) => changeDoc(e.document)),
    vscode.workspace.onDidSaveTextDocument(saveDoc),
    vscode.workspace.onDidCloseTextDocument(closeDoc),
  );
  // 扩展激活时已打开的 core 文档（onDidOpen 在激活前已派发）
  for (const doc of vscode.workspace.textDocuments) { openDoc(doc); }

  // ── 语义功能（均使用服务器快照；错误 → 空结果，不打扰用户）──
  const docParam = (doc) => ({ textDocument: { uri: doc.uri.toString() } });

  context.subscriptions.push(
    vscode.languages.registerHoverProvider({ language: 'core' }, {
      async provideHover(doc, pos) {
        try {
          const r = await conn.request('textDocument/hover', {
            ...docParam(doc),
            position: { line: pos.line, character: pos.character },
          });
          if (!r || !r.contents) { return null; }
          return new vscode.Hover(new vscode.MarkdownString(r.contents));
        } catch { return null; }
      },
    }),

    vscode.languages.registerDefinitionProvider({ language: 'core' }, {
      async provideDefinition(doc, pos) {
        try {
          const r = await conn.request('textDocument/definition', {
            ...docParam(doc),
            position: { line: pos.line, character: pos.character },
          });
          if (!r) { return null; }
          const u = vscode.Uri.parse(r.uri);
          return new vscode.Location(u, new vscode.Range(
            r.range.start.line, r.range.start.character,
            r.range.end.line, r.range.end.character));
        } catch { return null; }
      },
    }),

    // 触发字符 '@' 与服务器 completionProvider.triggerCharacters 一致
    vscode.languages.registerCompletionItemProvider({ language: 'core' }, {
      async provideCompletionItems(doc, pos) {
        try {
          const r = await conn.request('textDocument/completion', {
            ...docParam(doc),
            position: { line: pos.line, character: pos.character },
            context: {},
          });
          if (!r || !r.items) { return []; }
          // LSP CompletionItemKind 为 1-based，VS Code 枚举为 0-based，
          // 需平移 -1（如 Struct 22 → 21、Enum 13 → 12）；越界兜底 Text。
          return r.items.map((it) => {
            const item = new vscode.CompletionItem(it.label);
            if (typeof it.kind === 'number') {
              const k = it.kind - 1;
              item.kind = vscode.CompletionItemKind[k] !== undefined
                ? k : vscode.CompletionItemKind.Text;
            }
            return item;
          });
        } catch { return []; }
      },
    }, '@'),

    vscode.languages.registerDocumentSymbolProvider({ language: 'core' }, {
      async provideDocumentSymbols(doc) {
        try {
          const r = await conn.request('textDocument/documentSymbol', docParam(doc));
          if (!Array.isArray(r)) { return []; }
          const toSym = (s) => {
            const range = new vscode.Range(
              s.range.start.line, s.range.start.character,
              s.range.end.line, s.range.end.character);
            const sel = s.selectionRange ? new vscode.Range(
              s.selectionRange.start.line, s.selectionRange.start.character,
              s.selectionRange.end.line, s.selectionRange.end.character) : range;
            // LSP SymbolKind 为 1-based，VS Code 枚举为 0-based，
            // 需平移 -1（如 Enum 10 → 9、Struct 23 → 22）。
            const k = typeof s.kind === 'number'
              ? s.kind - 1 : vscode.SymbolKind.Variable;
            return new vscode.DocumentSymbol(s.name,
              typeof s.detail === 'string' ? s.detail : '',
              k, range, sel);
          };
          return r.map(toSym);
        } catch { return []; }
      },
    }),

    vscode.languages.registerDocumentSemanticTokensProvider({ language: 'core' }, {
      async provideDocumentSemanticTokens(doc) {
        try {
          const r = await conn.request('textDocument/semanticTokens/full', docParam(doc));
          if (!r || !r.data) { return new vscode.SemanticTokens(new Uint32Array(0)); }
          const builder = new vscode.SemanticTokensBuilder();
          const data = r.data;
          let line = 0, char = 0;
          for (let i = 0; i + 4 < data.length; i += 5) {
            line += data[i];
            char = data[i] === 0 ? char + data[i + 1] : data[i + 1];
            builder.push(line, char, data[i + 2], data[i + 3], data[i + 4]);
          }
          return builder.build();
        } catch { return new vscode.SemanticTokens(new Uint32Array(0)); }
      },
    }, { tokenTypes: TOKEN_TYPES, tokenModifiers: [] }),
  );
}

function deactivate() {
  // 服务器进程随 extension host 终止自动回收（kill 已挂 dispose）；
  // 规范顺序 shutdown→exit 由进程终止替代，corelsp 对 stdin EOF 亦正常退出。
}

module.exports = { activate, deactivate };
