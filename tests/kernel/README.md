# tests/kernel：McTT 到 Core 内核差分测试语料

本目录为 McTT 到 Core 内核移植 M1（见 `docs/superpowers/specs/2026-08-15-mctt-core-kernel-design.md`）
提供差分测试语料：同一批查询文件驱动 OCaml 参考 harness（`tools/mctt_ref/`）与 Core 侧内核
（`src/kernel/`，Task 6），输出逐位比对。本目录只含查询，不含期望值；期望值由参考
harness 在 Task 7 生成并固化到 `tests/kernel/expected/*.expected`。

## 协议

查询文件格式 = Task 3 共享格式协议（`tools/mctt_ref/protocol.md`，S-表达式）：

```
check   <ctx> <exp> <exp>          # accept | reject
infer   <ctx> <exp>                # type: <nf-exp> | reject
convert <ctx> <exp> <exp> <exp>    # yes | no
subtype <ctx> <exp> <exp>          # yes | no
<ctx> ::= (ctx <exp>*)             # 空上下文 (ctx)
<exp> ::= (typ N) | (nat) | (zero) | (succ e) | (natrec A mz ms n)
        | (pi A B) | (fn A M) | (app M N) | (var N) | (sub e s)
<sub> ::= (id) | (weaken) | (compose s s) | (extend s e)
```

每行一条查询。`corpus_exhaustive.txt` 含 `#` 开头的分层注释行（标明来源层），
harness 与 kernel CLI（`kernel_main.cr`）必须跳过 `#` 行（随机层与案卷文件无注释行；
2026-08-28 修正：行级处理是 kernel_main.cr 的职责，term_io 只解析单个 `<exp>`）。

## 固定种子与统计

随机层固定种子 `20260815`（`random.Random(20260815)`），重新生成结果逐字节一致
（已实测）。当前统计（2026-08-15 生成，`gen_corpus.py` 内置自检）：

| 文件 | 行数 | 说明 |
|---|---|---|
| `gen_corpus.py` | 不适用 | 生成器（穷举 + 随机 + 案卷，`python3 tests/kernel/gen_corpus.py`） |
| `cases/corpus_exhaustive.txt` | 45,244 | 穷举层：size ≤ 3 共 4,692 项（size=1: 6 / size=2: 120 / size=3: 4,566），约 2.4 MB |
| `cases/corpus_random.txt` | 1,200 | 随机层：infer 50% / check 20% / convert 15% / subtype 15%，上下文 4 选 1 |
| `cases/corpus_manual.txt` | 25 | 案卷：经典难项（β 归约、Π 逆变/协变、宇宙累积、natrec、显式替换组合） |

穷举层每项发射：`(ctx)` 下 infer + check(nat) + check(typ 0)；类型形态项（首构造子为
`pi`/`typ`/`nat`）加 subtype ×2；前 50 项加 convert；再以 `(ctx (nat))`、`(ctx (typ 0))`
上下文重复 infer/check。

## 穷举层规模（`--max-size`）

生成器默认 `--max-size 3`（穷举层 size ≤ 3，产物约 2.4 MB）。size-4 全量
（221,520 项，产物约 141 MB）超过 GitHub 100MiB 单文件上传限制，须显式开启：

```bash
python3 tests/kernel/gen_corpus.py --max-size 4
```

`--max-size` 只影响穷举层；随机层（种子 20260815）与案卷不随其变化。

## 与 brief（`.superpowers/sdd/task-4-brief.md`）的差异

生成器按 brief Step 1-4 转写，运行后修正了下列实际问题（均不影响验收行数）：

1. `size()` 崩溃修复：brief 原文对 `K_VAR`（子节点是整数索引，`1 + size(t[1])`
   崩溃）与 `K_TYP`（无分支，raise）未正确处理；四类原子一律计为叶节点 size=1
   （`size()` 仅用于 natrec 过滤，实参恒为原子项）。
2. 案卷 6 条 fn 元数修正（含 10/21 两条性质变化，明示）：brief 原文第 8/9/10/16/17/21
   条为 3 元 fn `(fn A B M)`（A=定义域、B=陪域、M=λ 体），与协议 `(fn A M)`
   （= McTT 提取构造子 `ti_fn : λ A M`）不符，删冗余陪域参数 B 修正（如
   `(fn (nat) (nat) (var 0))` 改为 `(fn (nat) (var 0))`）。
   变化披露：第 10/21 条（brief 注释“陪域宇宙”“高宇宙”）原意图是“λ 体为类型”，
   检查 λ 体为类型项的 lambda 对 `(pi (nat) (typ N))`；删 B 后 λ 体保留为 brief 原文 M
   位置的变量项 `(var 0)`，测试性质从“λ 体为类型（陪域宇宙）”变化为“λ 体为变量”
   （`check (ctx) (fn (nat) (var 0)) (pi (nat) (typ 0))` 应被拒绝）。此前“语义不变”的
   表述对这 2 条不准确，此处更正；案卷条目本身不改（保持与已交付 harness 的兼容），
   恢复原性质需把 λ 体改为 `(typ 0)`/`(typ 1)`，留待后续任务。
3. 穷举层无 natrec 项：brief 的简化 natrec 方案（四子项均取 size-1 原子）最小总
   size=5，默认 `max_size=3`（size-4 亦同）下过滤条件恒不命中。按 brief 注记，natrec
   覆盖由随机层（`rand_exp` 的 `K_NATREC` 分支）和案卷第 16/17 条补齐。
4. 跨层重复项：穷举层按 brief 原算法逐层去重（去重域 = 单层），同文本项可出现在
   多个 size 层（如 `(succ (nat))` 在 size 2/3 层）。默认 size-3 下为 6 个文本项
   跨层重复出现 6 次（size-4 全量为 348 个文本项重复出现 354 次）。差分测试两侧
   处理相同行，无影响，故保留。
5. 结构性调整：`gen_exps` 返回按层分组的 dict（扁平列表语义不变，便于逐层加 `#`
   注释）；不导入 brief 中未使用的 `itertools`。

## 重新生成

```bash
cd /home/DslsDZC/core && python3 tests/kernel/gen_corpus.py       # 默认 size-3（约 2.4 MB）
python3 tests/kernel/gen_corpus.py --max-size 4                   # size-4 全量（约 141 MB）
```

生成器内置自检（穷举 ≥ 300 行、随机 = 1200 行、案卷 = 25 行），失败即退出非零。
