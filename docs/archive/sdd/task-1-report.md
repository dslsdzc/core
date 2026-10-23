# 任务 1 报告：定长裁决注记（零行为改动）

状态：完成但有保留项（DONE_WITH_CONCERNS）。功能和验收全部通过；保留项是任务说明步骤 3 的校验命令在本环境失效，以及工作副本出现并发改动，均已处置，见第 6 节。

提交：`aa76f7f59f21`，change `wonvqsmyzsol`，3 files changed，19 insertions，0 deletions，单一提交。

判据一句话：七处注记全部落位，完整注记三段与任务说明逐字一致；`jj diff --git` 新增 19 行，19 行全是注释，删除 0 行；步骤 4 复跑 `check` 和 `cir` 逐字节相同，样本二进制 `cmp` IDENTICAL，rc=139 不变；另加自举前端差分，裸源和注记源的输出逐字节相同。

## 1. 改动落点表（7 处，行号为提交后终态）

| # | 文件:行 | 语义位置 | 形式 | 落点判定依据 |
|---|---|---|---|---|
| 1 | `src/compiler/ast.cr:229-233` | `EXPR_ARRAY` 常量定义，值为 19，表示数组字面量或数组类型节点的 kind | 完整段落 | 任务说明行号 229 精确命中 |
| 2 | `src/compiler/ast.cr:321` | `TYP_ARRAY` 类型表条目定义 | 一行式引用 | 任务说明行号 316 偏移 5 行，因为第 1 项插入 5 行；语义是 `TYP_ARRAY : int = 2;` 定义行，精确命中 |
| 3 | `src/compiler/ast.cr:327` | `TYP_SLICE` 类型表条目定义 | 一行式引用 | 任务说明行号 321 偏移 6 行，第 1、2 项累积；语义是 `TYP_SLICE : int = 9;` 定义行，精确命中 |
| 4 | `src/compiler/checker.cr:393-397` | `res_type_node()` 的 `EXPR_ARRAY` 分支，即 `[T;N]` 到 `TYP_ARRAY`、`[T]` 到 `TYP_SLICE` 的裁决点 | 完整段落 | 任务说明行号 392 是分支 `if ast_kind(node) == EXPR_ARRAY {`；注记贴入分支体内首行，紧邻被标注代码 |
| 5 | `src/compiler/checker.cr:1817` | range 到数组类型，即 `return alloc_type(TYP_ARRAY, body_ti, rng_count)` | 一行式引用 | 任务说明行号 1812 偏移 5 行，第 4 项插入；语义是 `alloc_type(TYP_ARRAY, ...)` 返回行，精确命中 |
| 6 | `src/compiler/checker.cr:2207` | 数组字面量类型推导，即 `return alloc_type(TYP_ARRAY, elem_ti, ast_b(node))` | 一行式引用 | 任务说明行号 2201 偏移 6 行；语义是字面量推导返回行，精确命中 |
| 7 | `src/compiler/parser.cr:46-50` | `parse_type()` 的 `[T; N]` 和 `[T]` 分支，即 `if tok_k(t) == T_LBRACKET {`，位于任务说明给的 44-58 区间内 | 完整段落 | 任务说明行号 44 是 `col := tok_cl(t);`，属于函数序言，不是语义落点；按任务说明“语义落点为准”取分支入口行 46，在授权区间 44-58 内，偏移 2 行 |

计数核对：完整段落 3 个，分别是 `的类型构造器身份已退役`，ast 1 个、parser 1 个、checker 1 个；一行式引用 4 个，分别是 `退役为「内联容量存储」`，ast 2 个、checker 2 个；合计 7。`表示层概念` 关键字有 7 行可以检索，对应 R2 接口化检索面。

逐字一致性核对，以任务说明第 28 到 32 行为基准，程序化比对：

```
AST_BLOCK_VERBATIM
PARSER_BLOCK_VERBATIM
CHECKER_BLOCK_VERBATIM
```

三段完整注记的 diff 为空。段落内 `//` 后的空格、`§`、反引号、换行断点都与任务说明一致。

## 2. 步骤 1 基线捕获（原始输出）

```fish
printf 'g : [int;2] = [8,9];\nfn main()->int{return g[1];}\n' > /tmp/r1t1_sample.cr
nice -n 19 ./build/corec check /tmp/r1t1_sample.cr  > /tmp/r1t1_check_before.txt 2>&1   # rc=0
nice -n 19 ./build/corec cir   /tmp/r1t1_sample.cr  > /tmp/r1t1_cir_before.txt   2>&1   # rc=0
nice -n 19 ./build/corec build /tmp/r1t1_sample.cr --static -o /tmp/r1t1_bin_before > /tmp/r1t1_build_before.txt 2>&1  # rc=0
```

- `check` 尾部为 `ok`，rc=0，符合任务说明期望。
- `build` rc=0，日志尾部为 `main at [0] off=85 cp=261`，然后输出到 `/tmp/r1t1_bin_before`。
- `/tmp/r1t1_bin_before` 运行 rc=139，符合任务说明标注的已知缺陷，任务 4 修复。
- 基线哈希：`check_before` 为 `b83d97aabcc41675e4ffe0547c2c4c92`，`cir_before` 为 `f5a7bc7a9981534697612fd8020094a1`（54872 B，38 行），`bin_before` 为 `87962c13ca529d66a153dc5f010b55ad`。

## 3. 步骤 3“仅注释”校验

### 3.1 任务说明原命令在本环境不可用（两处独立缺陷）

```fish
jj diff | grep '^+' | grep -v '^+++' | grep -v '^\+ *//' | grep -v '^\+$'
```

- 缺陷 A，正则语法：本机 `grep` 是 ugrep 7.5.0，`^+ *//` 和 `^+$` 被判为 `invalid syntax`，rc=2，不是空输出。

  ```
  ugrep: error: error at position 5
  (?m)^+$
       \___invalid syntax
  ```

- 缺陷 B，空转通过：即便正则合法，本仓库的 `jj diff` 默认使用 color-words 形态，新增行渲染为 `      229: …` 的右侧行号，不带 `+` 前缀。实测 `jj diff | grep -c '^+'` 为 0，因此该管道无论加了多少代码都恒为空输出，校验力为零。

注：这两个缺陷对任务 1 之外的任务同样成立。任务 2、5 如果沿用该命令，实际上没有校验。建议后续任务改用第 3.2 节的形式。

### 3.2 等价校验（POSIX 安全，显式 `--git`，限定本任务的三个文件）

```fish
jj diff --git src/compiler/ast.cr src/compiler/checker.cr src/compiler/parser.cr \
  | grep '^[+]' | grep -v -e '^[+][+][+]' -e '^[+][[:space:]]*//' -e '^[+][[:space:]]*$'   # → 空 ✓
jj diff --git <同三文件> | grep '^[-]' | grep -v '^---'                                      # → 空 ✓（零删除）
jj diff --git <同三文件> | awk '/^\+/ && !/^\+\+\+/ { if ($0 !~ /^\+[ \t]*\/\// && $0 !~ /^\+[ \t]*$/) print "NON-COMMENT: " $0 }'  # → non-comment added = 0 ✓
```

原始输出，三段均为空：

```
=== [3a] brief-intent filter, my 3 files (expect EMPTY) ===
<<<END3a>>>
=== [3b] removals (expect EMPTY) ===
<<<END3b>>>
=== [3c] awk independent (expect 0) ===
non-comment added = 0
```

非空转控制组，用于证明校验有判别力：同一过滤器跑在工作副本里另一份非注释改动上，即计划文档的散文，输出非空：

```
+- **行为变化面仅限两处**：Task 3（`_` 分隔符与宽度后缀**均由静默改为响亮报错**——用户裁决 2026-09-10…
+**裁决（2026-09-10 用户拍板，本批落实）**：数字字面量**不支持 `_` 分隔符**——两编译器**统一响亮报错**…
```

`--git` 全量 diff 佐证：新增 22 行，等于 19 行注释加 3 个 `+++` 头；没有任何 `-` 行，因此是纯增量、零改行。

## 4. 步骤 4 复跑比对（原始输出）

```fish
nice -n 19 ./build/corec check /tmp/r1t1_sample.cr > /tmp/r1t1_check_after.txt 2>&1   # rc=0
nice -n 19 ./build/corec cir   /tmp/r1t1_sample.cr > /tmp/r1t1_cir_after.txt   2>&1   # rc=0
nice -n 19 ./build/corec build /tmp/r1t1_sample.cr --static -o /tmp/r1t1_bin_after > /tmp/r1t1_build_after.txt 2>&1  # rc=0
diff /tmp/r1t1_check_before.txt /tmp/r1t1_check_after.txt && diff /tmp/r1t1_cir_before.txt /tmp/r1t1_cir_after.txt && echo IDENTICAL
```

```
IDENTICAL
```

- `build` 日志 diff 只有输出路径行，即 `-> /tmp/r1t1_bin_before` 对 `_after`，其余逐字节相同。
- `cmp /tmp/r1t1_bin_before /tmp/r1t1_bin_after` 为 BIN_IDENTICAL，md5 两侧都是 `87962c13ca529d66a153dc5f010b55ad`；重跑产物 rc=139，与基线一致，缺陷未动。
- after 哈希：`check` 为 `b83d97aa…`，`cir` 为 `f5a7bc7a…`，与 before 相同。

### 4.1 附加验证：自举前端差分（任务说明未要求，用于补强）

步骤 4 的复跑只证明预编译 corec 是确定性的，没有直接触及被修改的三个源文件。因此追加验证：把三个文件从 `@-` 的裸源还原到 `/tmp/r1t1_pristine/src/` 副本树，用同一个 corec 分别 `check` 裸源树和注记树，整个 `src/compiler/` 全模块，输出 38 行：

```fish
timeout 300 nice -n 19 ./build/corec check /tmp/r1t1_pristine/src/compiler/main.cr >| /tmp/r1t1_probe_pristine.txt 2>&1  # rc=0, tail=ok
timeout 300 nice -n 19 ./build/corec check src/compiler/main.cr                        >| /tmp/r1t1_probe_modified.txt 2>&1  # rc=0, tail=ok
# 归一化 /tmp 前缀后比对：
```

```
FRONTEND_OUTPUT_IDENTICAL
```

因此 19 行注释对 self-hosted 的 lexer、parser、checker 完全惰性，包括反引号、`§`、全角标点和长行；注记后的编译器源码仍能通过自身前端的全量检查，两棵树都输出 `ok`。反引号在 `//` 注释中的先例已经在 `dump.cr:269`、`lexer.cr`、`globals.cr`、`dataflow.cr`、`corearch.cr` 中存在。

## 5. 自审清单

| 项 | 结果 |
|---|---|
| diff 是否只有注释 | 是。19/19 新增行都是 `//` 注释，0 删除行，三种独立校验加非空转控制 |
| 落点是否齐全 7 处 | 是。ast 3 处、checker 3 处、parser 1 处，`表示层概念` 可检索 7 行 |
| 完整注记是否逐字 | 是。三段与任务说明第 28 到 32 行程序化 diff 为空 |
| 提交是否单一 | 是。单提交，3 文件 19 插入 0 删除，不含他人改动，见第 6.2 节 |
| 步骤 1、4 是否复跑比对 | 是。IDENTICAL 和 BIN_IDENTICAL，追加前端差分 IDENTICAL |
| 零行为改动 | 是。无删除、无改行；二进制与前端输出双向逐字节相同 |

## 6. 保留项（均已处置，不影响验收，但需要团队知悉）

### 6.1 任务说明步骤 3 的校验命令在本环境失效（双缺陷，见第 3.1 节）

命令会报错，原因是 ugrep 正则，或者恒为空输出通过，原因是 jj 默认输出没有 `+` 前缀。已用等价校验替代并通过，但该命令对本波其他任务，即任务 2 的死条目移除和任务 4 的全局初始化，同样零校验力。建议任务 2、5 改用 `jj diff --git <paths> | grep '^[+]' | grep -v -e '^[+][+][+]' -e '^[+][[:space:]]*//' -e '^[+][[:space:]]*$'`，并要求用同样方法核对“零删除行”，因为任务说明原式不覆盖删除。如果坚持逐字执行任务说明命令，需要先设置 `alias grep=...`，不推荐；`--git` 必须显式加上。

### 6.2 工作副本的并发改动（已隔离，未被卷入）

开工时 `jj status` 无改动。任务中途，工作副本出现不是本任务所做的 2 行改动，文件是 `docs/superpowers/plans/2026-09-10-language-surface-narrowing-r1.md`，内容是用户 2026-09-10 关于 `_` 分隔符的裁决改写，属于任务 3 范畴。处置：步骤 5 没有按任务说明逐字执行 `jj commit -m …`，因为那会把他人改动一并卷入，破坏“每任务一次提交”的粒度，也污染任务 1 的注释-only 校验。改为路径限定提交：

```fish
jj commit src/compiler/ast.cr src/compiler/checker.cr src/compiler/parser.cr -m '…'
```

结果：本任务的提交只含 3 个文件。计划文档的改动留在工作副本，随后由其作者另行提交为 `qkkwsxxu 29c4e6df`，位于本任务提交之后，没有回溯改写提交 id `aa76f7f5`，内容复核无恙。如果团队要求逐字复现任务说明的步骤 5 命令，请在无并发改动时执行。

末尾工作副本为 `wpkslpnx 8079f5df`，为空。

### 6.3 环境提示（影响复现命令）

- 本机 fish 配置启用了 noclobber：`>` 已存在文件时会不报错地失败并报“文件已存在”。我曾因此拿到一份陈旧的比对文件。复现类命令请用 `>|` 或先删除目标文件。
- fish 不做空格分词：`set F 'a b c'; jj diff $F` 会把 `$F` 当成单一路径，触发 `No matching entries for paths` 的空转通过。路径请逐字写全，或者使用 `(string split ' ' $F)`。
- 三处注记都没有行为面影响。任务 4 修复 SIGSEGV 时，`[T;N]` 全局初始化路径的注记，即 `ast.cr:229` 和 `checker.cr:393`，可以作为“表示提示层”的参考。
