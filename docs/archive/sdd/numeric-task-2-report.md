# 数值任务 2 报告：apx 标签机制（变量标签和 IR_APPROX 注解）

状态：完成（DONE）。有一个已有的浮动测试与本任务无关，见自审。

## 1. mut 和 pub 的实现路径调研（确认 apx 可以走同一条路）

### 自举编译器（src/compiler/）

- lexer：`mut` 和 `pub` 是关键字（T_MUT=7、T_PUB=19，由 `lookup_keyword` 识别），但变量标签解析不依赖关键字机制。parser 用 `tok_lx(tag_t)` 做字符串比较，即 `tag == "mut"`，任意 token 类型都能作为标签。因此 apx 无需加入 lexer。任务说明中的 lexer 改动是条件性的，“若标签按关键字解析”，实测不是。
- parser（`parse_new_var_decl`）：标签循环为 `if tag == "mut" {...} else if tag == "pub" {...} else { 插件标签查表 }`。未知标签当前被不报错地忽略，不报错。`is_mut` 存入 LET 节点的 `d` 字段：`alloc_node(EXPR_LET, ni, typ, nv, 0, 0, is_mut, ...)`，`is_pub` 解析后即丢弃。
- checker：不验证标签，也不存储 mut。mut 位就在 LET 节点上（`ast_data`）。`def_sym` 只存 name、kind、type、node。类型信息携带位是 LET 节点字段。
- ir_gen：处理 EXPR_LET 时读取 LET 节点字段。mut 位在 ir_gen 中不被读取，mutation 检查在 checker 的赋值路径。
- 结论：apx 走同一条路，即 parser 标签循环字符串比较、LET 节点字段存储（apx 存 `iv` 字段，与 mut 的 `d` 字段并列）、ir_gen 在 EXPR_LET 处读取。

### Python bootstrap（bootstrap/corec/）

- lexer.py：没有 apx 概念。标签按 IDENT 或任意关键字 lexeme 收集（`_parse_var_decl_names_tags_type`）。
- parser.py：收集到 `tags` 列表，不验证。
- type_checker.py：不读 tags。
- ir_gen.py：`gen_let` 取得 `let.tags`，批量声明拆分为 sub_let 时 tags 透传。
- 两侧行为一致：标签在 parser 层做字符串匹配，不需要改 lexer。

## 2. 改动清单

### 自举编译器（src/compiler/ 和 src/arch/）

| 文件 | 改动 |
|---|---|
| `src/compiler/ast.cr` | `IR_APPROX : int = 51`，注释说明这是无操作数注解；`EC_TA_UNKNOWN_TAG : int = 4008`（TA08） |
| `src/compiler/parser.cr` | 标签循环增加 `else if tag == "apx" { is_apx = 1; }`。未知标签，即不在 mut、pub、apx 和插件范围内的标签，产生 TA08 diag，在 parse 阶段 fatal；`alloc_node(EXPR_LET, ..., is_apx, 0, is_mut, ...)` 把 apx 位存入 iv |
| `src/compiler/ir_gen.cr` | EXPR_LET 读取 `is_apx := ast_int_val(node)`。dyn 路径和普通路径在 `bind_local` 之后执行 `emit(IR_APPROX, -1, 0, 0, 0, 0)` |
| `src/compiler/dataflow.cr` | `df_opcode_name` 增加 `IR_APPROX` 到 `"approx"` 的映射 |
| `src/compiler/opt.cr` | O1 通道跳过 IR_APPROX，位置与 IR_FAST 相同 |
| `src/compiler/interp.cr` | 显式跳过：`if op == 51 { ip = ip + 1; continue; }`。不能崩溃，注释说明这是纯注解 |
| `src/arch/linux/ld/instr.cr` | ELF 后端无操作：`if op == IR_APPROX { return 0; }` |
| `src/compiler/ccr_io.cr`、`dump.cr` | 无需修改。序列化是通用的，opcode 按 u32 直通；dump 走 `df_opcode_name`，已经覆盖 |
| `src/compiler/checker.cr` | 未改。按 mut 和 pub 的路径，标签认可在 parser 层完成，checker 从不验证标签；apx 位随 LET 节点，与 mut 同位，checker 天然携带。任务说明列出的 checker 改动经调研不必要 |

### Python bootstrap（bootstrap/corec/）

| 文件 | 改动 |
|---|---|
| `ir/coreir.py` | 新增 `ApproxInstr(Instr)` dataclass，无字段，纯注解 |
| `frontend/ir_gen.py` | 在 `gen_let` 中判断 `if 'apx' in (let.tags or [])`，成立时 `add_instr(ApproxInstr())`。全局 let 的 `gen_let_decl` 不发射，与自举侧的全局变量行为一致 |
| `ir/cir.py` | `_instr_kind_and_sem` 增加 ApproxInstr，kind 为 "approx"，用于 dataflow 图分类；`extract_graph` 不需要边，因为没有操作数 |
| `backend/interpreter.py` | dispatch 增加 `elif isinstance(instr, ApproxInstr): pass`。原实现会抛 NotImplementedError 导致崩溃，必须处理 |
| `backend/x86_64_stack_asm.py`、`arm64_asm.py` | dispatch 增加 ApproxInstr 时 pass，不生成代码 |
| `frontend/parser.py` | 收集标签时验证：`tag not in ('mut','pub','apx')` 时调用 `self.error("unknown declaration tag ...")`，抛出 SyntaxError |

### 测试和文档

- `tests/selfhost/test_apx_tag.py`，新增，2 个测试、5 个断言：apx 编译通过；bogus_tag 产生 TA08 且 exit≠0；run 语义不变，带 apx 和不带 apx 都是 126；cir dump 中无 apx 时 `approx` 为 0 条，2 个 apx 变量恰好 2 条。测试源首行注入 uuid 注释，打乱 source hash，避免 `.core/cache/cir` 命中旧编译结果，这是三个陷阱之一。
- `tests/bootstrap/test_apx_tag.py`，新增，5 个测试：ApproxInstr 发射计数（2、0、批量 2）、bogus_tag 抛 SyntaxError、interpreter 语义不变（126）。
- `docs/error-codes.md`：注册 TA08，TA 计数从 7 改为 8。

## 3. IR_APPROX 指令编号的选择

现有最大 opcode 是 50（IR_F2I，float 支持时分配）。40 号空缺，39 是 IR_HOTPATCH_ROUTE，41 是 IR_DYN_TAG。51 紧接 50，是自然的下一个，因此取 51，不与任何现有编号冲突，已在 `ast.cr` 全文件核对。

## 4. TDD 证据（从失败到通过）

- 失败（改动前，旧 `build/corec` 加未改的 bootstrap）：
  - `tests/selfhost/test_apx_tag.py`：0/2 通过，bogus_tag 未被拒绝，cir 中没有 `approx`。
  - `tests/bootstrap/test_apx_tag.py`：ImportError，`cannot import name 'ApproxInstr'`，并且 bogus_tag 不报错。
- 通过（实现后）：
  - `tests/selfhost/test_apx_tag.py`：2/2 通过，包含 TA08 诊断、cir 计数、run=126。
  - `tests/bootstrap/test_apx_tag.py`：5/5 通过。

## 5. 测试和自举回归结果

| 项 | 结果 |
|---|---|
| tests/bootstrap/{pipeline,borrow,generics,apx_tag} | 24/24、4/4、2/2、5/5 |
| tests/selfhost/{borrow,impl,compile,apx_tag} | 7/7、7/7、全部通过、2/2 |
| tests/selfhost/test_native_memory | 6/6 |
| tests/selfhost/test_directory_build | 通过 |
| `build_selfhost_native.py`（`nice -n 19`） | BUILD SUCCESS，生成 corec、corearch、corelsp 三个产物。自举链完整，两个编译器都认识 apx |
| 端到端：apx 源码 `corec build --static` 生成 ELF 并运行 | exit 42，验证 ELF 后端对 IR_APPROX 无操作；全局 apx 变量 `g_x : int, apx = 7` 得到 exit 7 |
| 批量声明 `a, b : int, apx = 1, 2` | 自举侧 cir 有 2 条 approx，bootstrap 侧有 2 条 ApproxInstr |

## 6. 对任务说明的偏差和原因

1. 未改 lexer.cr：任务说明是条件式要求，“若标签按关键字解析”。实测 mut 和 pub 标签走 parser 字符串比较（`tok_lx`），不是关键字机制，apx 以 IDENT 出现即可。加入关键字反而有风险，会占用标识符。两个编译器一致。
2. 未改 checker.cr：任务说明列了 checker，但 mut 和 pub 的路径证明标签认可和类型信息携带都在 parser 和 LET 节点完成，checker 不验证标签，`def_sym` 不存 mut。apx 位随 LET 节点的 iv 字段，checker 和 monomorph 天然透传，monomorph 克隆时 iv 原样保留，已核对 `monomorph.cr:271`。
3. 未知标签报错（TA08）是新行为：任务说明的测试要求 bogus_tag 报错，但两侧现状都是不报错地接受。按任务说明实现为 parser 阶段错误，parse diag 为 fatal，exit 1。自举侧保留插件标签，`find_plugin_entry` 优先；bootstrap 侧没有插件系统，因此使用严格集合 {mut, pub, apx}。已核对仓库内源码（`src/compiler`、`src/stdlib`、`src/runtime`、`tests/suite`、`examples`），只使用 mut 和 pub 标签，无回归风险。
4. 全局（文件级）apx 变量不发射 IR_APPROX：全局 let 不进入 ir_gen 的 EXPR_LET 路径，而是注册为 BSS 全局并在启动时写入。apx 位留在 LET 节点，供后续任务消费。任务 4、5 的语义消费点在 IR，本任务保持“机制先行”。
5. IR_APPROX 的发射位置是声明处，每条 apx 变量一条。任务说明中的“运算处”按“变量标签”的最小一致实现解读为在声明处注解该变量。使用点发射需要 IR 变量级的 apx 标志位，超出本任务的机制范围。测试断言按声明处计数，每个变量恰好一条。
6. 补充文档 `docs/error-codes.md`，注册 TA08。任务说明未列，属于错误码引用的一致性维护。

## 7. 自审发现

### 本任务范围内

- interp 的显式跳过必须使用 `ip = ip + 1; continue;`，因为循环尾部才统一自增，裸 `continue` 会死循环。已正确处理并加注释。
- `.core/cache/cir` 缓存按 source hash 键控，测试源注入 uuid 注释可以避免失败阶段的缓存污染通过阶段的结果，这是三个陷阱之一。
- bootstrap 侧的 interpreter、x86_64_stack_asm、arm64_asm 原本对未知指令抛 NotImplementedError，ApproxInstr 不注册必然崩溃，三处都已注册跳过。
- `x : int, apx = 42` 中的 `apx` 是 IDENT token。自举侧标签循环对任意 token 取 `tok_lx`，bootstrap 侧也按 lexeme 收集，两侧都无需改 lexer 即可识别，验证通过。
- monomorph 克隆 LET 节点时保留 iv，即 apx 位，已核对，泛型函数内的 apx 位不会丢失。

### 与本任务无关的已有问题（均已在基线编译器复现）

1. `tests/selfhost/test_pointer_safety.py` 浮动失败：`test_dynamic_out_of_bounds_load_traps` 偶发超时，编译产物应该 trap 却挂起。证据：基线使用父提交原样源码全新重建，三次运行结果为 PASS、FAIL、FAIL；本分支两次为 13/14、12/14。两侧同型浮动，不是本任务引入。疑似动态边界检查路径中，IR_DEREF 的 s2、s3 由 ptr_analysis 填充，读取未初始化内存，导致生成代码时好时坏。建议单独立项排查根因。本任务不迁移 float 站点，不动该路径。
2. `tests/selfhost/test_backend_bootstrap.py`：stage1 产物没有执行位，`corec build` 输出 0644，exit 126。基线同样失败。`pointer_safety` 的 `build_and_run` 显式执行 `chmod 0o755`，该测试没有做。属于已有问题。
3. `tests/suite/at_test_mini4.cr`、`at_test_mini6.cr`：`corec check` 在解析阶段 SIGSEGV，exit 139，基线同样 139。疑似 `@inline(add)(3,4)` 注解调用解析路径的缺陷。属于已有问题。
4. `tests/suite/test_control_flow.cr`、`test_generics.cr`：仓库里就是 0 字节文件，空文件没有 main，自然失败。属于已有提交状态。
5. cir dump 中 IR_ADDR_INDEX（op 31）显示为 `?`：`df_opcode_name` 缺少 IR_ADDR_INDEX 条目。顺手发现，不在本任务范围，未修改，避免越界改动。
