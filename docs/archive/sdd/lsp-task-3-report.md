# LSP Task 3 报告：不报错地检查管线、reset_frontend_state、diag file_id、publishDiagnostics

状态：完成。提交 `xymsstmq 4532a071`（父提交之前的 commit，工作副本已清空）。

## 1. reset_frontend_state() 的实际清零项与 spec 分类

实现在 `src/compiler/globals.cr` 末尾，在 `lsp_check_file` 内 tokenize 之前调用。

实际清零项（计数清零，保留 cap）：

| 类别 | 清零项 |
|---|---|
| lexer | g_token_count, g_error_count |
| AST/parser | g_ast_count, g_block_stmt_count, g_func_count, g_struct_count, g_enum_count, g_iface_count, g_impl_for_count, g_method_count, g_type_alias_count, g_generic_constr_count, g_gen_param_count, g_global_let_count, g_loop_depth |
| checker | g_sym_count, g_type_count, g_scope_depth, g_borrow_count, g_holder_count, g_borrow_scope_depth, g_gen_map_count, g_dyn_type_set_count, g_checker_current_fi, g_unsafe_depth |
| module | g_file_count, g_mod_count, g_seg_count, g_line_count, g_mod_func_count, g_mod_path_count |
| 其他 | g_diag_count, g_alloc_pts_cap |

与 spec 第 3.1 节清单的差异：

1. `g_extra_let_count` 未纳入。它声明在 `parser.cr:8`，而 `globals.cr` 同时被编译进 corearch（corearch concat 不含 parser.cr），引用它会导致 corearch 构建报 `Undefined name`。首次构建实测撞上，已修复。parse_all 自身会清零它，没有实际缺口。
2. `g_open_docs` 明确不重置。它是 LSP 的文档源，跨检查持久。reset 只针对单次检查的前端状态，任务说明的清单也没有列它，与 spec 一致。
3. 补充了任务说明未列、但属于检查器临时状态的项：g_holder_count、g_borrow_scope_depth、g_dyn_type_set_count、g_checker_current_fi、g_unsafe_depth。g_unsafe_depth 只在 push/pop_unsafe_scope 中增减，链内没有全局清零，不加会泄漏到下一次检查。
4. g_strs/g_str_count/g_str_hash/g_str_hash_cap 未动。它们是驻留表，跨检查保留，g_files 的 fni 依赖它。
5. 其余清单项（g_types、g_syms、g_diags、g_files、g_mods 等）在链内函数（init_types/check_all/res_imports）中本来就会清零。reset_frontend_state 是防御性后备，双保险。

为什么需要它（幽灵诊断的根因）：parse 阶段产生诊断时，`lsp_check_file` 会跳过 check_all（AST 不完整），而 check_all 是链内唯一清 g_diags 的地方。没有 reset_frontend_state，上一次检查的诊断会残留并追加到本次结果。测试场景 3 到 4 实测：改好、改坏、改好，没有幽灵诊断。

## 2. diag 布局改动和 file_id 写入点

布局：每条从 32 字节改为 40 字节，格式为 `[ec(8) msg_ptr(8) line(8) col(8) file_id(8)]`。新增常量 `DIAG_REC_SIZE : int = 40`（globals.cr，g_diags 声明旁），所有读写点改用常量，避免步长变化。

改动文件（8 处）：
- `dyn_arr.cr` 的 grow_diags（扩容步长）
- `checker.cr` 的 `check_error()`（中心写入点，第 253 行补 `w64(..., +32, diag_fileid_for_line(line))`）
- `parser.cr` 的 4 处内联写入（parse_type 2 处加 interface 溢出 2 处，均补 file_id）
- `diag.cr` 的 `print_diagnostics()`（步长改用常量；输出格式不变，实测 corec 对 TF01/P01 的输出逐字不变）
- `main.cr` 的 `compile_source()` 诊断读取点（corec 构建共享同一布局，必须同步）
- `lsp.cr` 新增读取点（publish）

file_id 来源：新增 `diag_fileid_for_line(line)`（diag.cr），查询 `g_line_fileid[(line-1)*8]`。该映射由 res_imports 末尾的 `build_line_fileid()` 建立，逐行对应到段的 file_id。诊断行号总是落在 g_source 内（拼接后已剥掉 preamble），映射精确。越界返回 -1，理论上不可达，见自审。

## 3. module.cr 的打开文档机制

- `g_open_docs`（globals.cr 声明）：每条 24 字节 `{path_ptr(8), src_ptr(8), src_len(8)}`，沿用 g_files/g_mods 的扁平记录风格。
- `module_open_doc_set(path, src)`：已打开则原地更新 src，否则追加。路径和源都是调用方（lsp.cr）复制的稳定堆字符串。JSON 字符串池在每次 json_parse 时会重置复用，存池内指针必然悬垂，lsp_str_pool_copy 解决这个问题。
- `module_open_doc_remove(path)`：线性扫描，然后前移压实。
- `module_get_source(path)`：先查打开文档（str_eq 精确匹配），未打开则 `read_file`。corec 构建下 g_open_doc_count 恒为 0，行为与原来完全一致，保持向后兼容。
- res_imports 的读文件点改走 module_get_source：`load_imports()`（_import.cr，含 stdlib 和祖先目录链）、project 分支、5 级回退链（g_source_dir、src/stdlib、src/runtime、src/compiler、cwd）。so 索引和 Core.toml 仍直接读盘，因为它们不是 .cr 源，LSP 用户不会编辑。

## 4. lsp.cr 实现要点

- `lsp_check_file(path, src)`：设置 `g_source = src; g_source_dir = dirname(path); reset_frontend_state();`，然后依次执行 tokenize、res_imports、parse_all。如果有诊断，就发布并返回，跳过 check_all，防止 AST 崩溃；否则执行 check_all 并发布。这里没有使用 `run_frontend()`，因为它包含 println 进度输出，会污染 stdout 协议通道。
- res_imports 之后，把主文件 g_files[0] 的空路径补成真实 path（`store_str_ptr(g_files, 16, path)`）。publish 的 file_id 到 uri 映射依赖它。
- publish：主文件（g_files[0] 的 fni）无条件发布，无诊断时发布空数组清掉旧诊断。其余有诊断的文件按 file_id 去重发布。uri 为 `"file://" + 路径`。诊断字段为 `{range{start/end{line,character}}（1-based 转 0-based，减 1）、severity=1、message}`。JSON 转义方面，引号、反斜杠、控制符转成 \uXXXX，复用 json.cr 的 _jhex4。
- 处理器：didOpen/didChange（contentChanges[0].text 全量，textDocumentSync=1）/didSave（重跑检查，源取打开文档）/didClose（移除并发布空数组）。通知一律不回响应。
- rpc.cr 分发新增 4 条 did* 路由，位于 initialized/shutdown 检查之后、未知方法之前。

## 5. TDD 证据

- RED：先加 test_diagnostics_and_reset，运行旧二进制。read_frame 没有帧可读，被 `timeout` 杀掉（exit 124，无响应）。符合任务说明预期的“无响应”。
- GREEN：实现后 `tests/selfhost/test_lsp.py` 三组全部通过（lifecycle、error codes、diagnostics_and_reset）。
- 手工扩展回归：好、坏、好、坏连续 4 次打开，没有幽灵诊断；第二个文档的 parse 错误（P01）uri 归属正确；didChange 清空、didClose 清空、didSave 重查均实测通过；publish 帧经 json.loads 解析合法，包括 em-dash 消息。

## 6. 回归结果

- `tests/selfhost/test_compile.py`：PASS（全部自举编译测试通过）。
- `tests/selfhost/test_region_cfg.py`：PASS。
- `test_borrow.py` / `test_impl.py` / `test_backend_bootstrap.py`：预存在失败，引用了已删除的 `src/compiler/backend/x86_64.cr`（backend 早已迁到 src/arch/linux/ld），与本次改动无关。失败发生在读取测试源码阶段，报 FileNotFoundError。
- corec 手工验证：`check` 的 TF01（检查器诊断）和 P01（parser 诊断）输出格式与改动前逐字一致；`cir` 正常。

## 7. 与任务说明的偏差及原因

1. 提交范围扩大（4 个文件变为 9 个文件）：40 字节布局必须原子实施。checker.cr/parser.cr（写入）、dyn_arr.cr（扩容）、main.cr（corec 读取）与 globals.cr/diag.cr 属于同一布局，拆开提交会出现 32/40 混用。lsp.cr 加入 build_selfhost_native.py 的 concat 也必须同提交。
2. 测试代码微调：任务说明的 open_doc 用 `send()`（自带 read_frame）再 read_frame，会读两次帧，GREEN 时必然挂起，因为 didOpen 只产生一帧 publishDiagnostics。改为直接写帧再读一帧，语义与任务说明注释中的“读一帧接收 publishDiagnostics”一致。
3. reset_frontend_state 不含 g_extra_let_count，见第 1 节差异 1（corearch 构建约束）。
4. diag file_id 用行号查 g_line_fileid，而不是用“检查器上下文里的当前文件 id”。check_error 有约百处调用点，改签名会触及整个文件。行号到 file_id 的映射在 parse 和 check 两个阶段都精确（build_line_fileid 在 res_imports 末尾建立，期间 g_source 不变），parser 诊断也能受益。

## 8. 自审发现

- corearch 构建约束（第 1 次构建撞出）：globals.cr 被三个二进制共用，reset_frontend_state 只能引用 globals.cr/ast.cr 内声明的全局变量。parser.cr/lexer.cr 私有的全局变量（g_extra_let_count、g_token_pos、g_source 等）由各自模块入口函数自清，不进入 reset。
- rpc.cr 命名失误（第 2 次构建撞出）：rpc_dispatch 的参数名是 `req`，误写成 `lsp_did_open(root)`，产生 4 处 "Undefined name: root"，已改。
- 已知边界（理论上不可达，记录在案）：diag_fileid_for_line 越界返回 -1 时，该诊断不属于任何文件，不会出现在“其余文件”循环中，也不匹配主文件 fni。行号永远来自 token/AST 行，小于等于 g_line_count，不会发生。
- 已导入文件的 uri 是相对路径（`file://src/stdlib/fmt.cr`）：res_imports 对非主文件存的就是相对路径。LSP 客户端对已打开文档（主文件）没有影响；绝对化留待后续任务。
- 空文档 didSave 会因 `str_len(src) > 0` 门控跳过重查（打开文档的 src 为 ""），didOpen/didChange 不受影响。

---

## Fix 1：res_imports 污染 stdout 协议通道（Critical 修复）

提交：`sunkmxsp 8fb56fb6`。工作副本另含未提交的 `tests/selfhost/pollution_check.py` 验证脚本，未卷入本提交。

### 门控实现位置

| 文件 | 改动 |
|---|---|
| `src/compiler/globals.cr` | 新增 `g_silent_stdout : int, mut;`（默认 0，bss 清零），声明在 g_open_docs 旁 |
| `src/compiler/module.cr` | 3 处 print/println 全部加门控 `if g_silent_stdout == 0 { ... }`：toml 警告（501-505 区）、`!! import fail`（551）、`  -> ` 加载进度（570） |
| `src/lsp/main.cr` | `lsp_main()` 首行设置 `g_silent_stdout = 1`（在 rpc_loop 之前） |

全量排查结果：module.cr 全文件只有上述 3 处 stdout 输出。前端管线其他文件（lexer/parser/checker/ir_gen/pass/interp/project）没有 stdout 输出。diag.cr 的 `print_diagnostics()` 走 stdout，但调用点只在 corec CLI（main.cr:133/139/489、dump.cr:235/347），LSP 管线的 `lsp_check_file` 不调用它（诊断经 lsp.cr 的 JSON publish 发送），无需门控。dump.cr 的输出只被 `cir`/`ccr` CLI 命令使用。corelsp 构建（build_selfhost_native.py concat）包含 globals.cr/module.cr/lsp/main.cr，三处改动都进入 corelsp 二进制。

### 污染验证（实测证据）

`tests/selfhost/pollution_check.py` 是严格解析脚本。它跑完整的 didOpen 流程（initialize、initialized、didOpen 好文件、didOpen 坏文件、shutdown、exit），抓取 corelsp 的原始 stdout 字节流（635 字节）：

```
POLLUTION CHECK PASS: 5 frames, all strictly parseable, 0 dirty bytes outside frames, no '->'/'import fail'/'warning:' in stdout
```

断言内容：
1. 原始字节流中没有 `->`、`!! import fail`、`warning:` 标记。didOpen 坏文件会触发 import 重扫，覆盖进度行路径。
2. 严格帧扫描：每个字节都必须匹配 `Content-Length: N\r\n\r\n` 加 N 字节合法 JSON。帧前、帧间、帧后任何脏字节都会导致断言失败。5 帧全部通过，0 脏字节，与 VS Code 严格客户端的解析标准一致。

### 测试结果

- `tests/selfhost/test_lsp.py`：三组全部通过（test_lifecycle、test_jsonrpc_error_codes、test_diagnostics_and_reset，ALL PASS，exit 0）。
- `tests/selfhost/test_compile.py`：PASS（"All selfhost compile tests passed"）。回归确认 corec CLI 行为不变：测试输出中 ` -> /home/DslsDZC/core/build/test_self_compile` 进度行仍在打印，门控默认 0 生效。
- 重建：`nice -n 19 python3 build_selfhost_native.py` BUILD SUCCESS（corec/corearch/corelsp 三个产物）。
