# R1 Task 2 报告：宽度死条目移除和 parser 死分支清理

状态：完成
提交：change `kqnooxnryzry` / commit `ce3e541c2740`
父提交为 R1 计划 Task 3 修正 commit `ac4a2859`。工作副本已回空提交（`nvzxtzvo c41a431e`），未卷入任何 lead 文档改动。

## Step 1 引用面核实（原始输出）

```
$ nice -n 19 grep -rn "T_INT_I8\|...\|W_F64" src/ --include='*.cr' | grep -v '^src/compiler/ast.cr'
src/compiler/parser.cr:397:    if tok_k(t) == T_INT || (tok_k(t) >= T_INT_I8 && tok_k(t) <= T_INT_U64) {
src/compiler/parser.cr:401:        if kn == T_INT_I8 { w = W_I8; }
src/compiler/parser.cr:402:        else if kn == T_INT_I16 { w = W_I16; }
src/compiler/parser.cr:403:        else if kn == T_INT_I32 { w = W_I32; }
src/compiler/parser.cr:404:        else if kn == T_INT_I64 { w = W_I64; }
src/compiler/parser.cr:405:        else if kn == T_INT_U8 { w = W_U8; }
src/compiler/parser.cr:406:        else if kn == T_INT_U16 { w = W_U16; }
src/compiler/parser.cr:407:        else if kn == T_INT_U32 { w = W_U32; }
src/compiler/parser.cr:408:        else if kn == T_INT_U64 { w = W_U64; }
src/compiler/parser.cr:411:    if tok_k(t) == T_DEX || tok_k(t) == T_FLOAT_F32 || tok_k(t) == T_FLOAT_F64 {
src/compiler/parser.cr:415:        if kn == T_FLOAT_F32 { w = W_F32; }
src/compiler/parser.cr:416:        else if kn == T_FLOAT_F64 { w = W_F64; }
src/compiler/parser.cr:902:    if tok_k(t) == T_INT || (tok_k(t) >= T_INT_I8 && tok_k(t) <= T_INT_U64) {
src/compiler/parser.cr:906:        if kn == T_INT_I8 { w = W_I8; }
src/compiler/parser.cr:907:        else if kn == T_INT_I16 { w = W_I16; }
src/compiler/parser.cr:908:        else if kn == T_INT_I32 { w = W_I32; }
src/compiler/parser.cr:909:        else if kn == T_INT_I64 { w = W_I64; }
src/compiler/parser.cr:910:        else if kn == T_INT_U8 { w = W_U8; }
src/compiler/parser.cr:911:        else if kn == T_INT_U16 { w = W_U16; }
src/compiler/parser.cr:912:        else if kn == T_INT_U32 { w = W_U32; }
src/compiler/parser.cr:913:        else if kn == T_INT_U64 { w = W_U64; }
```

判定：命中只在 parser.cr 的三段死分支，没有其他文件，因此继续。
行号相对任务说明的 392-403 / 406-411 / 897-908 各加 5，原因是 Task 1 插入了“表示层概念”注释，代码文本与任务说明逐字一致。

额外佐证（任务说明之外，用于确认“死”的判断）：`src/compiler/lexer.cr:460-468` 对带后缀字面量一律发射 `T_DEX`（含点、f32、f64 后缀）或 `T_INT`。其中后缀分支走 `add_tok(T_INT, -1, ...)`，从不发射 T_INT_I8 到 T_FLOAT_F64 的任何 kind。因此 `tok_k(t) >= T_INT_I8 && <= T_INT_U64` 链和 `== T_FLOAT_F32` / `== T_FLOAT_F64` 判定永不可达。后缀退役和响亮报错属于 R1 Task 3 的词法面。
另外，全仓扫描 `bootstrap/ tests/ tools/` 也零命中（`vscode-core/` 在本检出中不存在）。

## Step 2 parser.cr 改动对照

### 2a. `parse_primary()` 的 int 分支（改后 :397-400）

改前（:397-409）：

```core
    if tok_k(t) == T_INT || (tok_k(t) >= T_INT_I8 && tok_k(t) <= T_INT_U64) {
        advance_tok();
        kn := tok_k(t);
        w : ., mut = 0;
        if kn == T_INT_I8 { w = W_I8; }
        else if kn == T_INT_I16 { w = W_I16; }
        else if kn == T_INT_I32 { w = W_I32; }
        else if kn == T_INT_I64 { w = W_I64; }
        else if kn == T_INT_U8 { w = W_U8; }
        else if kn == T_INT_U16 { w = W_U16; }
        else if kn == T_INT_U32 { w = W_U32; }
        else if kn == T_INT_U64 { w = W_U64; }
        return alloc_node(EXPR_INT, 0, 0, 0, tok_iv(t), TY_INT, w, tok_ln(t), tok_cl(t));
    }
```

改后（照任务说明原文）：

```core
    if tok_k(t) == T_INT {
        advance_tok();
        return alloc_node(EXPR_INT, 0, 0, 0, tok_iv(t), TY_INT, 0, tok_ln(t), tok_cl(t));
    }
```

### 2b. `parse_primary()` 的 dex 分支（改后 :401-411）

改前（:411-423）为 `if tok_k(t) == T_DEX || ...T_FLOAT_F32... || ...T_FLOAT_F64...`，加 `kn`/`w` 宽度选择链，末行注释是“data = 宽度标注（_f32/_f64，保留）”，并调用 `alloc_node(..., TY_DEX, w, ...)`。
改后照任务说明原文，data 槽恒为 0：

```core
    if tok_k(t) == T_DEX {
        advance_tok();
        // 节点字段（数值迁移 Task 4）：a = binary64 位模式（apx 快路径字面量表示，
        // 由 lexer 存入 token 的 lexeme 槽的数字串还原）；int_val = 定点缩放整数
        // （精确表示，默认路径）。宽度后缀退役（2026-09-10 语言面收窄 第2）：data 槽
        // 不再承载宽度标注，恒 0。
        bits : int = 0;
        tl := r64(g_tokens, t * ESZ_TOKEN + OFF_TK_LEXEME);
        if tl >= 0 { bits = str_to_f64_bits(istr_get(tl)); }
        return alloc_node(EXPR_DEX, bits, 0, 0, tok_iv(t), TY_DEX, 0, tok_ln(t), tok_cl(t));
    }
```

Task 4 的 a/int_val 语义注释原样保留，只把末行“data = 宽度标注（保留）”按任务说明改为恒 0 说明。

### 2c. `parse_pattern()` 的 int 分支（改后 :902 起）

改前（:902-914）与 2a 同构，使用同一段宽度链。改后照任务说明原文：

```core
    if tok_k(t) == T_INT {
        advance_tok();
        return alloc_node(EXPR_INT, 0, 0, 0, tok_iv(t), TY_INT, 0, tok_ln(t), tok_cl(t));
    }
```

## Step 3 ast.cr 墓碑文本（已就位，勿重编号）

`ast.cr:84-86`（原 :84-94 英文注释加 T_INT_I8 到 T_FLOAT_F64 十条定义）：

```core
// 77-86 原为宽度后缀 token kind（T_INT_I8..T_INT_U64 / T_FLOAT_F32 / T_FLOAT_F64）。
// 2026-09-10 语言面收窄 第2 删除：lexer 从不发射这些 kind（宽度后缀已退役，改响亮报错），
// parser 侧引用同步移除。勿重编号，编号空间稳定（先例：T_FLOAT_TYPE 91 已删除）。
```

`ast.cr:101-102`（原 :109-119 注释加 W_I8 到 W_F64 十条）：

```core
// W_I8..W_F64（1..10）原为「宽度标注」值域，仅供宽度后缀 token 分支使用。
// 2026-09-10 语言面收窄 第2 随死分支一并删除。勿重编号。
```

编号邻接性保持：77-86 段前是 `T_SLASH_EQ : int = 76;`，段后是 `T_NONE : int = 87;`，都没有改动，没有任何重编号。

## Step 4 引用面归零验证

```
$ nice -n 19 grep -rn "T_INT_I8\|...\|W_F64" src/ --include='*.cr'
src/compiler/ast.cr:84:// 77-86 原为宽度后缀 token kind（T_INT_I8..T_INT_U64 / T_FLOAT_F32 / T_FLOAT_F64）。
src/compiler/ast.cr:101:// W_I8..W_F64（1..10）原为「宽度标注」值域，仅供宽度后缀 token 分支使用。

$ 上述结果再过滤注释行（grep -v '^[^:]*:[0-9]*: *//'）到 rc=1（代码引用零命中）

$ nice -n 19 grep -n "T_INT_I64\|W_I64" bootstrap/ -r 到 rc=1（零命中）
```

也就是说，代码引用面归零。残留的两行命中是任务说明本步骤要求的墓碑注释正文，任务说明自带文本中就含这些名字，不是引用。`bootstrap/ tests/ tools/` 全都没有对应常量。

## Step 5 重建、冒烟、回归

```
$ nice -n 19 python3 build_selfhost_native.py    # 退出码 0
6:[GUARD] corec: manifest OK (37 files)
12:[GUARD] corec: build log clean (error[ = 0, undefined = 0)
16:[GUARD] corearch: manifest OK (31 files)
17:[GUARD] x86_64-linux target: manifest OK (3 files)
23:[GUARD] corearch: build log clean (error[ = 0, undefined = 0)
27:[GUARD] corelsp: manifest OK (26 files)
33:[GUARD] corelsp: build log clean (error[ = 0, undefined = 0)
37:=== BUILD SUCCESS ===

$ nice -n 19 ./build/corec run 'fn main()->int{return 42;}'
rc=42；输出 [1/5]..[5/5]，error[ 计数 = 0

$ nice -n 19 python3 tests/selfhost/test_compile.py    # 退出码 0
=== Test 1: Basic Interpreter Run ===
=== Test 2: Self-Hosted Compiler Lexer Source ===
=== Test 3: Self-Compilation (native) ===
  Binary exit code: 42
  PASS: native corec compiled .cr to working ELF binary
All selfhost compile tests passed.
```

## diff 形状自审（规范式样）

```
$ jj diff --git src/compiler/ast.cr src/compiler/parser.cr | grep '^[+]' | grep -v -e '^[+][+][+]' -e '^[+][[:space:]]*//' -e '^[+][[:space:]]*$'
+    if tok_k(t) == T_INT {
+        return alloc_node(EXPR_INT, 0, 0, 0, tok_iv(t), TY_INT, 0, tok_ln(t), tok_cl(t));
+    if tok_k(t) == T_DEX {
+        tl := r64(g_tokens, t * ESZ_TOKEN + OFF_TK_LEXEME);
+        return alloc_node(EXPR_DEX, bits, 0, 0, tok_iv(t), TY_DEX, 0, tok_ln(t), tok_cl(t));
+    if tok_k(t) == T_INT {                                    # parse_pattern
+        return alloc_node(EXPR_INT, 0, 0, 0, tok_iv(t), TY_INT, 0, tok_ln(t), tok_cl(t));

$ jj diff ... | grep '^[-]' | grep -v '^[-][-][-]' | wc -l 到 54
   = 11（英文头注加 10 条 token kind）+ 11（宽度头注加 10 条 W_*）+ 12 + 12 + 12（三段死分支）
```

移除的行全部是预期条目，没有附带删除。新增的非注释行全部是任务说明指定的代码。

## 提交

```bash
jj commit src/compiler/ast.cr src/compiler/parser.cr -m 'refactor: 语言面收窄 R1 Task 2，宽度死条目移除（ast.cr 77-86 token kind + W_* 值域，墓碑注释勿重编号）+ parser 两处死分支清理（lexer 从不发射，引用面归零）'
```

结果为 `kqnooxnryzry ce3e541c2740`。提交后 `jj status` 没有残留改动（路径限定，未卷入任何文档改动）。

## 自审结论

- 引用面：代码零命中。只有墓碑注释正文含名字，这是任务说明指定文本。
- diff 只含 `src/compiler/ast.cr`、`src/compiler/parser.cr`。
- 单一提交，路径限定，消息照任务说明。
- 墓碑就位，零重编号（76 到 87 邻接、90.. 和 92.. 邻接都没有动）。
- 行为等价性依据：`w` 槽此前只由死分支赋值（T_INT/T_DEX 无后缀路径本来就是 w=0），删除后恒为 0；`ast_data(...)` 的消费者（monomorph/checker/ir_gen）都不读 int/dex 节点的 data 槽；重建、冒烟、test_compile（3 个测试）全部通过。

## 备注（无阻塞）

- 任务说明 Step 4 的“两条命令均零命中”字面上无法成立，因为任务说明自己规定的墓碑注释正文就含 `T_INT_I8..T_INT_U64` / `W_I8..W_F64` 字样。已按“代码引用零命中”核验并留证。
- `vscode-core/` 目录在本检出中不存在（CLAUDE.md 有描述，但仓库没有提供），该扫描面为空。
