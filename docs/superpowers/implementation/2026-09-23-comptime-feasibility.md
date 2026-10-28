# Core comptime / 元编程方向：工程可行性评估

这是 2026-09-23 的一次性工程可行性评估，不含实施承诺。

输入有两份。第一份是 `/tmp/briefs/comptime-directions-raw.md`，包含三块讨论和前置条件。第二份是 `/tmp/briefs/metaprog-model-raw.md`，内容是 typed semantic metaprogramming 的八个方向，评估见第八到第十一节。

基线修订是 `develop@origin` 的 `6b54107e`。评估没有修改既有文件的正文，同目录的 `comptime.md` 在评估时也没有改动。

只看结论，见第 6.0 节和第九节。想知道哪些数字是实测的，见第 7.2 节和第十一节。想知道卡在哪里，见第 6.2、6.3、9.2、9.3 节。

---

## 〇、这份文档怎么读

标注约定（全篇强制）：

| 标记 | 含义 |
|---|---|
| `[实测]` | 本次在本机跑出数字，或读到了逐字原文。测量条件写在第一节。 |
| `[推理]` | 由 `[实测]` 的数据和算法复杂度常识推出来的判断。不是本次运行得到的。 |
| `[未核实]` | 本次没有能力或没有时间验证的内容。读到时请当成未知，不要当成默认成立。 |

这份文档的价值几乎全在「哪一句是量出来的、哪一句是推断的」。凡是把 `[推理]` 写成 `[实测]` 的地方都是缺陷；凡是把「方向正确」当成「可行」的地方也是缺陷。

不能把别处的结论当作自己的实测：第三节引用了另外两份实核报告的结论，逐处标了出处和是否复核。

---

## 一、测量条件（每个数字都适用，不再逐处重复）

| 项 | 值 |
|---|---|
| 机器 | 本机（Linux 7.2.4-zen2-1-zen），4 核 |
| 负载 | 测量全程 load average ≈ 7–10（4 核机上）。同期有其它代理在跑构建。这是本档最大的测量条件限制。 |
| CPU 限制 | 一律 `nice -n 19`（硬性规则 6）。`cpulimit` 本机没有安装，故只用 `nice`。 |
| 工作区 | `/home/DslsDZC/core-ctfeas-ws`（`@` = `develop@origin` `6b54107e`） |
| 冷热态 | `.cir` 增量缓存每次测量前 `rm -rf .core/cache`（clean-cache）。除非该行显式写「暖」 |
| 取数 | 波动大的量用 min-of-3（外部噪声下 min 最接近真值）；单次读数一律标 `单次` |
| 源代码读数 | 一律 `jj file show -r develop@origin <path>` 或干净检出。未在落后检出上取行号 |

关于噪声的说明 `[实测]`：同一命令（`corec cir` on `s2000.cr`，clean-cache）三次采样得
`3.288 / 11.290 / 21.318 s`，极差 6.5×。因此本档所有结论只用 min-of-3，且幂次类结论是区间判断，不是精确拟合。

---

## 二、编译成本基线 `[实测]`

### 2.1 `build_selfhost_native.py`（Python bootstrap 构建三个二进制）

命令：`nice -n 19 python3 build_selfhost_native.py`（cwd = 干净工作区，空缓存状态）
总时长 = 15.241 s，rc = 0。

| 阶段 | 区间 | 耗时 |
|---|---|---|
| runtime (`rt.s` 生成 `.o`) | 0.051 到 0.070 | 0.019 s |
| corec（45 文件 concat，221,282 tok，1082 函数，5,652,604 B asm） | 0.269 到 7.512 | 7.243 s |
| ├ 词法 | 0.269 到 2.478 | 2.209 s |
| ├ parse + resolve + desugar + check | 2.478 到 4.730 | 2.252 s |
| ├ IR gen | 到 5.504 | 0.774 s |
| ├ asm gen | 到 6.352 | 0.848 s |
| └ `as` + `ld` | 到 7.512 | 1.160 s |
| corearch（32 文件，132,214 tok，726 函数） | 7.605 到 11.493 | 3.888 s |
| corelsp（31 文件，116,748 tok，771 函数） | 11.543 到 15.177 | 3.634 s |

> 对照：`docs/superpowers/implementation/2026-09-17-spec-grammar.md` 记「耗时 25.6s（real；user 12.0s；4 核机）」
> 同一命令。本次实测 15.24 秒。差异的归因未核实（机器负载、修订差、文件系统缓存皆可能）。
> 不要把 25.6 或 15.24 任一当成「该命令的常数」。它是分布，且读数不带采样次数时不可比。

### 2.2 full-bootstrap：「编译器编译自己」的真实负载 `[实测]`

`src/ci/run.sh:350-361` 的 `full-bootstrap` job 逐字方法：

```
./build/corec build src/compiler/main.cr -o /tmp/corec2 --static -O 0
cp ./build/corearch /tmp/corearch
/tmp/corec2 build src/compiler/main.cr -o /tmp/corec3 --static -O 0
cmp /tmp/corec2 /tmp/corec3
```

路径偏离说明：CI 使用固定路径 `/tmp/corec2`、`/tmp/corec3`，多代理并行会互相覆盖（本来就是已知问题）。
本次改用 `/tmp/ctfeas/corec2|corec3|corearch`，其余逐字同方法。

| 阶段 | 区间 | 耗时 |
|---|---|---|
| 前置 `build_selfhost_native.py` | （同第 2.1 节） | ~15 s |
| 1 `corec build main.cr` 生成 `corec2`（冷） | 0.005 到 41.275 | 41.27 s |
| 2 `corec2 build main.cr` 生成 `corec3`（暖） | 41.282 到 97.719 | 56.44 s |
| `cmp corec2 corec3` | 97.723 到 97.990 | IDENTICAL（两文件均 3,030,646 B） |
| 总计 | | 97.999 s，rc = 0 |

阶段 1 内部（从时间戳日志）：

| 子阶段 | 区间 | 耗时 | 占比 |
|---|---|---|---|
| 前端（tokenize、check、ir_gen） | 0.005 到 4.957 | 4.95 s | 12.0 % |
| `df_state_finalize` + `ptr_analysis_all` + `region_check_all` + `provenance_verify_all` | 4.957 到 34.974 | ≈ 30.02 s | 72.7 % |
| `save_ccr` | 34.997 到 36.364 | 1.37 s | 3.3 % |
| `corearch` 发 ELF（1055 funcs / 169,418 instrs） | 36.364 到 41.275 | 4.91 s | 11.9 % |

> 注：这 30 秒不是 `lower_to_ccr`。`main.cr` 的打印顺序是
> `println("lower to ccr...")` 在 `lower_to_ccr()` 之前（`src/compiler/main.cr:654-655`），
> 而 `lower done` 与它只差 0.023 s。因此真正的 30 s 花在 `lower to ccr...` 打印之前，
> 即 `src/compiler/main.cr:596-640` 的 `df_state_finalize()` 和三个
> 「always run, even at opt_level 0」（`main.cr:636` 原文）的 pass。

### 2.3 规模曲线：本档最重要的一张表 `[实测]`

语料 = 脚本合成的 N 个函数（每函数 6 条语句，形状一致，`/tmp/ctfeas/scale/s*.cr`）。
`check` = 只跑前端；`cir` = 前端 + `df_state_finalize`；`ccr` = 前端 + `df_state_finalize` + 三个常开 pass + `lower` + `save`。
min-of-3，clean-cache，nice -n 19。

| 语料 | NOD 节点数 | REG 区段数 | `check` | `cir` | `ccr` | `ccr−check`（分析面） |
|---|---|---|---|---|---|---|
| s1000 | 77,270 | 1,086 | 0.525 s | 1.514 s | 3.063 s | 2.538 s |
| s2000 | 153,270 | 2,086 | 1.109 s | 3.288 s | 13.075 s | 11.966 s |
| 比率（×1.98 节点） | | | ×2.11 | ×2.17 | ×4.27 | ×4.71 |
| 真负载 `src/compiler/main.cr` | 169,418 | 7,638 | 4.96 s | — | 41.27 s | ≈30.0 s |

读出来的三件事：

1. `[实测]` 前端是线性的。`check` 在 250/500/1000/2000/4000 五个点上是 0.135/0.271/0.539/1.103/2.443 s，逐点严格 ×2.0（输入 ×16，时间 ×18.1）。
2. `[实测]` `ccr` 的分析面是超线性的。节点 ×1.98 时分析面 ×4.71（局部幂次 ≈ 2.2）。
   单次采样在 s500 上另得：39,270 节点时分析面约 0.86 s；三点幂次从 1.58 增长到 2.24，说明不是干净的单项幂律。
3. `[实测]` 真负载比合成语料更差：真负载节点数只比 s2000 多 10.5%，分析面却贵 2.5×；其 REG 区段数是 s2000 的 3.66×（7,638 vs 2,086）。

机制候选 `[推理]`（不是实测归因，本次无法在不改源码的前提下逐 pass 计时）：

- `src/compiler/ptr_analysis.cr:15-29` 的 `pa_in_unsafe(node_seq)` 每次调用都全扫 `g_sg_count` 个区段。
- `src/compiler/region_check.cr:15-29` 的 `is_in_unsafe(node_seq)` 逐字同样的全扫（两份副本）。
- 因此两处都是 O(nodes × regions)。
- 本仓自己的文档已记过这条：`docs/maintainer/design/execution-mapping-design.md:1152` 逐字
  「注：且 `pa_in_unsafe()`（`ptr_analysis.cr:15-30`）每次调用都全扫 `g_sg_count` 个 SG。O(SG) per node，
  已被 QC 化为 O(nodes × SGs)。」
- 对照：同文件 `region_check.cr:5-11` 的 `subgraph_containing()` 已经用了 O(1) 显式映射
  （`g_df_node_region`）。O(1) 的修法在同一文件里就有先例，只是没有用到 unsafe 判定上。

对本评估的直接后果 `[推理]`：
任何「让编译器对程序图做更多分析」的方向（本次 15 个方向里绝大多数），都是在已经超线性、
且已占 73% 编译时间的那个面上增加工作。这是本档的核心约束。

### 2.4 编译器自身语料的规模与形状 `[实测]`

`src/compiler/*.cr` = 38 个文件 / 32,089 行；`.ccr` 产物 12,698,096 B，8 段：

| 段 | 量 |
|---|---|
| STR | 6,238 串 / 94,500 B |
| SYM | 955,768 B |
| NOD | 169,418 节点（40 B/条，6,776,724 B） |
| ENT | 122,660 条目（3,434,484 B） |
| REG | 7,638 区段（183,316 B） |
| EDG | 156,217 边（1,249,740 B） |
| TYPE | 23 行 / 61 项（3,000 B） |
| IFACE | 16 条目（452 B） |

NOD 的 opcode 直方图（`IR_*` 名 = `src/compiler/ast.cr:554-604`）：

| opcode | 名 | 数 | 占比 |
|---|---|---|---|
| 9 | `IR_STORE` | 33,158 | 19.57 % |
| 1 | `IR_CONST` | 25,657 | 15.14 % |
| 21 | `IR_LABEL` | 20,390 | 12.04 % |
| 4 | `IR_CALL` | 15,244 | 9.00 % |
| 2 | `IR_BINARY` | 14,834 | 8.76 % |
| 46 | `IR_LAZY_THUNK` | 14,002 | 8.26 % |
| 20 | `IR_JUMP` | 13,128 | 7.75 % |
| 47 | `IR_LAZY_FORCE` | 10,213 | 6.03 % |
| 19 | `IR_BRANCH` | 7,444 | 4.39 % |
| 6 | `IR_ALLOC` | 5,414 | 3.20 % |
| 5 | `IR_RETURN` | 4,302 | 2.54 % |
| 32/33 | `IR_ARENA_NEW` / `_RESET` | 1,948 / 1,948 | 各 1.15 % |
| 3 | `IR_UNARY` | 1,731 | 1.02 % |
| 12 / 7 | `IR_STORE_FIELD` / `IR_ALLOC_STRUCT` | 4 / 1 | ~0 % |

两条量化结论（从实测到推理）：

- 结构性节点占比 ≈ 40.8%：`LABEL + JUMP + BRANCH + LAZY_THUNK + LAZY_FORCE + ARENA_NEW + ARENA_RESET`
  = 69,073 / 169,418。任何「duplicate a subgraph」的策略（PE / polyvariant）都会连同这 40.8% 的结构性节点一起复制。
- lazy thunk/force 包装 = 24,215 节点（14.3%），这是求值序包装，不是程序语义。

类型信息覆盖率 `[实测]`（本次自行解析 NOD 段第 28 字节 = `item`，字段序核对过
`src/compiler/ccr_io.cr:495-530` 与 `:1385-1392`）：

> 169,418 节点中 61,149 个带类型项（`item ≥ 0`）= 36.09%；63.91% 无项（`item = −1`）。

`[推理]` 所有以「图上有类型」为前提的方向（typed HDFG fragment、semantic reflection、typed
transformation），其基础当前的实际覆盖率是 36%，且 `TYPE` 段全文只有 23 行 / 61 项。

### 2.5 `.cir` 增量缓存：编译期数据的规模 `[实测]`

跑完第 2.2 节后 `.core/cache/cir` = 1,107 个文件 / 43,690,222 B（41.7 MiB）。

单函数快照尺寸分布（1055 个编译器自身函数）：

| 统计 | 值 |
|---|---|
| min | 3,363 B |
| p50 | 25,025 B |
| p90 | 60,467 B |
| p99 | 328,964 B |
| max | 2,634,377 B（`type_selftest_run`） |
| 合计 | 41.1 MiB |
| top 10 函数 | 占总字节 19.4 % |
| top 50 函数 | 34.7 % |
| top 100 函数 | 43.3 % |

最大的几个：`type_selftest_run` 2.63 MB、`gen_expr` 1.56 MB、`infer_expr` 1.11 MB、`load_ccr` 784 KB、`tokenize` 469 KB。

---

## 三、comptime 现状（逐格实测）：全篇基础

> 为什么先量这个：三块讨论稿的每一条方向都以「现有 comptime 能力」为起点。起点不准，
> 后面所有结论都建立在未验证的假设上。且那三块读的是落后检出（路径写错两处、
> `b8656da8` 是 `main` 旧点而非 `develop`），因此本次全部重核。

### 3.1 `comptime.md` 的三张表逐格核

#### (a) 「三种场景」表（`docs/maintainer/proposals/comptime.md:11-17`）

| 提案单元格 | 实测 | 判定 |
|---|---|---|
| 常量折叠（自动、图推导） | `[实测]` 未实现。唯一调用点 `src/compiler/main.cr:185-196` 的 `ast_optimize_body` 循环整块被 `/* */` 注释掉；`optimize_all()`（`opt.cr:329`）全仓无调用者（`opt.cr:6` 自述）。`[实测]` 探针：`40+2` 在 `.cir` 图上仍是 `const 40 / const 2 / binary`。 | 方案（未实现） |
| 纯函数提前执行（`fibonacci(x)`） | `[实测]` 探针 `sq(7)` 在图上仍是 `const 7` + `call sq`，没有折叠。没有任何编译期求值器接入。 | 方案（未实现） |
| 编译时 I/O、文件嵌入（`read_file("x.toml")`） | `[实测]` `src/stdlib/io.cr:27-52` 的 `read_file` = 运行时 syscall 实现（open/lseek/read 循环）。没有任何编译期执行它的路径。 | 方案（未实现） |
| `@comptime { ... }` 强制 | `[实测]` 块形式不解析：`./build/corec check` 对 `@comptime { x := 1+1; }` 报 `@comptime requires an expression`。 | 方案（未实现） |

#### (b) 「自动推导」节（`comptime.md:19-21`）

> 「编译器从 HDFG 上判定：子图的所有输入来自 CONST 或已执行的编译时子图，且子图内无副作用，
> 则自动在编译时执行。」

`[实测]` 该判定器不存在。全仓 grep `comptime|const_fold|ir_interpret|ctfe` 在
`src/compiler/*.cr` + `src/stdlib/*.cr` 的命中，除 `checker.cr`/`ir_gen.cr` 的 `@comptime`
分派外只有 `interp.cr` 的解释器；而解释器入口 `ir_interpret()`
（`src/compiler/interp.cr:446`）的唯一调用点是 `src/compiler/main.cr:412` 的 `cmd == "run"` 分支。

因此提案的设计原则第 1 条「90% 的编译时执行由 HDFG 自动推导，用户不需要任何关键字」
的实现度 = 0。

#### (c) 「可编译时执行的条件」表（`comptime.md:67-73`）

注：`[实测]` 这张表本身是残缺的。`cat -A` 逐字节核，该表 5 行的「自动执行 / @comptime」两列
在文件里是空的（`| 纯函数，所有输入已知 |  |  |`），两个标记位不存在。
因此该表不能作为「已定稿的语义契约」引用（这也解释了为什么它读起来像方案）。

### 3.2 `at-intrinsics.md` 的 12 个内建逐格核

`docs/developer/at-intrinsics.md:3` 自述「active(12 个内建已实现，2026-07-28 完整实施)」。
逐格实测结果（分派点 = `checker.cr:4177-4345` 与 `ir_gen.cr:1983-2173`；探针 = `./build/corec cir`）：

| 内建 | checker 返回型 | ir_gen 实际发射 | `[实测]` 探针 | 判定 |
|---|---|---|---|---|
| `@sizeOf(T)` | `TI_INT` | `IR_CONST`，来自 `type_size(ti)` | `struct P{a:int,b:int}` 得到 `const _sizeof = 16` | 真值 |
| `@alignOf(T)` | `TI_INT` | `IR_CONST`，来自 `type_align(ti)` | — | 真值 |
| `@hasField(T,n)` | `TI_BOOL` | `IR_CONST`，来自 `ti_has_field` | — | 真值 |
| `@field(T,n)` | `TI_INT` | `IR_CONST`，来自 `ti_field_offset` | 得到 `const _fldoff = 8` | 注：只有偏移。文档 `at-intrinsics.md:22` 说「返回字段的偏移和类型」（还举了 `.get(obj)`），`checker.cr:4217` 的注释说「returns FieldInfo」，实际返回一个 int。 |
| `@fields(T)` | `TI_STR` | `IR_CONST` = 逗号拼起来的字段名串 | 得到 `const _fields = 175`（intern 串下标） | 注：是字符串不是列表。文档 `at-intrinsics.md:21` 说「返回字段名列表，编译期可遍历」，并在 `:31-36` 给了 `for name in @fields(...)` 的示例，遍历能力不存在。 |
| `@typeInfo(T)` | `TI_STR` | `IR_CONST` = 类型名字符串 | 得到 `const _tinfo = 1`（intern 下标，内容是 `"P"`） | 与文档严重不符。文档 `at-intrinsics.md:20` 说「返回类型的完整结构（字段、方法、大小、对齐）」；`ir_gen.cr:2056-2078` 实际只构造 `"int"`/`"bool"`/`"dex"`/`"string"`/`"char"`/`"unit"`/`"unknown"` 或命名行名字。`checker.cr:4226-4229` 的注释自承这曾是 `placeholder — returns handle`。 |
| `@comptime(expr)` | 内层表达式类型 | `gen_expr` + `force_if_thunk` + 直接返回 | `[实测]` `@comptime(argc*2)`（`argc` 是形参，运行期值）rc=0，不报错地通过 | 只有接口，没有实现。`ir_gen.cr:2093-2105` 自承 `// Future: invoke ir_interpret_expr for true forced evaluation.`，而 `ir_interpret_expr` 全仓零定义。文档 `at-intrinsics.md:46` 说「强制编译期执行，算不了报错」，实际零强制、零报错。 |
| `@inline(fn)` | 内层类型 | `IR_INLINE` hint | — | 已实施（hint） |
| `@NoBoundsCheck` | `TI_UNIT` | `IR_NO_BOUNDS_CHECK` | — | 已实施 |
| `@fast` | `TI_UNIT` | `IR_FAST` | — | 已实施 |
| `@unroll(n)` | `TI_UNIT` | `IR_UNROLL` | — | 已实施 |
| `@section(name)` | `TI_UNIT` | `IR_SECTION` | — | 已实施 |
| （文档表外）`@raw_int` / `@addr` / `@ptr_of` / `@str_of` | — | 真分派 | — | 已实施 |

`[实测]` 逐格合计：6 格真值实施，2 格部分实现（`@field`/`@fields`），2 格与文档不符
（`@typeInfo`/`@comptime`），4 格注解实施。
因此 `at-intrinsics.md:5` 的「12 个内建已实现」按「有分派分支」算成立，按「语义与文档一致」算不成立。

### 3.3 今天真正存在的编译期求值：`#check`/`#ensure` 的字面量折叠

`[实测]`（源码级，未复核标志见下）：这是全仓唯一真实存在的编译期常量求值器：

- 词法 `#` sigil：`src/compiler/lexer.cr:682-687`
- 语法 `#check(expr)` / `#ensure(expr)`：`src/compiler/parser.cr:1563-1611`
- 检查：`src/compiler/checker.cr:2323-2375`（`spec_check_func`）+ `:4478-4500`（`spec_check_all`）
- 折叠覆盖面（`checker.cr:4437-4439` 逐字）：「覆盖 = C1 子集里字面量闭合的形态：
  int/bool 字面量、一元 `-`/`!`、二元算术/比较/逻辑。不做代数化简（如 `x*0`）」
- 唯一硬错 = `#check(常量假)`（`EC_V_CHECK_FALSE` = 17001）；「未证」不阻断编译
- 输出通道 = `--dump-vcs`（`src/compiler/dump.cr:497-535`）
- 运行期影响 = 零（`parser.cr:1570-1571`：不进 body 引用，因此 `ir_gen` 走不到）

> 出处与复核声明：本节四段出处来自另一份实核报告（本次委托的检索），本次复核了其中
> `checker.cr:4437-4439`、`parser.cr:1570-1571`、`ast.cr:509-523` 三处的逐字原文（一致）。
> 未复核的：`tests/spec/` 34 档语料、`src/ci/run.sh:296-303` 接入点、48 项自测实际通过。

因此现状是：`#check` 的折叠器是一个只认字面量的布尔表达式求值器。
它离「编译期执行用户函数」的距离 = 调用面为零（`EC_V_CALL_BANNED` = 17006 明确禁止任何调用）。

### 3.4 CIC / SMT / 契约体系现状

> 出处与复核声明：本小节结论来自另一份实核报告；本次复核了 `ccr_io.cr`/`ccr_types` 之外的
> 三条关键句的原文（见每行括注）。

| 层 | 状态 | 定位点 |
|---|---|---|
| CIC 内核（规约信任根） | 0 实现（设计定稿） | `docs/maintainer/adr/adr-0009-spec-system-v2.md:4` `accepted(设计定稿,未实现)`、`:18`「全链未实现」 |
| SMT 通道 | 0 实现（无依赖、无调用、无证书管线） | `docs/maintainer/design/spec-design.md:363-376`（设计）、`docs/superpowers/specs/2026-08-28-lsp-production-design.md:76`「验证管线（翻译桥/CIC，0 实现）」 |
| `#check`/`#ensure` C1 切片 | 端到端实施并进 CI，但 C1 定义里的「编图」被裁掉，转 C1b | `TODO.md:851`「已实施（阶段 6，2026-09-17）」、`:856`「未编图（裁-S4…转 C1b）」 |
| `.csr` 实现方式 / 翻译桥 | 0 实现 | `TODO.md:913` 2「全仓 0 命中（零实现却标 active）」 |
| `src/kernel/`（McTT 移植） | 真实现（1287 行），但是 MLTT 的 Π+ℕ 片段，不是 CIC；未接入、未入 CI | `docs/superpowers/specs/2026-08-15-mctt-core-kernel-design.md:42`「没有 Σ、没有 Id、没有 W-类型」 |
| `coq/fmt_int.v` | 1 个 stdlib 函数的 Coq 证明（`Theorem roundtrip`），文档自明与规约系统无关 | `docs/coq/README.md:6`「这不是规约系统」 |

> `[实测]` 本次另核：`spec/` 目录 = 4 个 7 行的占位文件（内容完全相同，自述「2026-09-06 退役」）；
> `grammar/corespec.ebnf` 仍在但自述退役（`:1-7`），`:9-52` 的旧 EBNF 正文没有消费者。

### 3.5 「第一等程序片段」的表示面现状

> 出处：本节来自另一份实核报告（HDFG、`.cir`、`.ccr` V8、单态化四块）。本次复核了
> `dyn_arr.cr:122-132` 的 `ESZ_DFNODE`/`ESZ_DFEDGE` 常量与 `cir_cache.cr:271/564` 的签名（一致）。

已具备（物理表示层够用）：

- DFNode = 72 B 定长九槽、无指针（`dyn_arr.cr:122-127`）；DFEdge = 32 B；SG = 48 B。
  「一个片段」本身 = 几段连续字节 + 几个 `(start, count)`。
- 相对偏移 + 基线平移已在 `.cir` v20 跑通并被实测确认（`cir_cache.cr:416-417` 写、
  `:826-840` 读；`:828-829` 自述「相对 id 在节点基线平移时仍指向正确节点」）。
- 「盘值不信任、由重放重建」的规则已经成熟（`:770-773`）。
- 先全量校验、后落任何写的两阶段装载已实现（`:607-609`）。

缺什么（每条都有源码依据）：

| 缺 | 依据 |
|---|---|
| 「片段」边界概念：现在唯一的边界是函数 | `save_cir_cache(path, source_fi, ir_fi)`：三个取界全来自函数级数组（`cir_cache.cr:291-294, 308`）；`:225-226`「The function SG is recreated by `df_begin_func`… only nested records are stored」 |
| 节点身份稳定性：节点没有名字，只有下标 | DFNode 九槽无 id/name 槽；`.ccr` NOD id = 文件序索引（`ccr_io.cr:63-64`） |
| var 域可重映射：原文自述「无法低成本重映射」 | `cir_cache.cr:652-654`「var 域是唯一无法低成本重映射的镜像域…因此恒校验：不符 = miss」 |
| 类型项可迁移：项引用是进程内的 | `dyn_arr.cr:113-119` 契约4「进程内项引用不得跨进程（D20）」；`cir_cache.cr:760-769` 只存派生码、装载时重派生 |
| 任意位置插入：只有尾部追加 | `cir_cache.cr:742` `base_node := g_df_node_count` 写死追加语义；区段 parent 把「片段根 = 函数 SG」写死为 `-1`（`:242-249`） |
| 编译期程序调用图构造 API 的语言面入口 | `df_create_node` 全仓唯一调用点 = `ir_gen.cr:713`；且其头注（`dataflow.cr:92-98`）要求调用方自己先跑 `sh_tk_split`，而 `sh_tk_split` 的消费面按 `globals.cr:456-457` 只有两个（emit 与装载侧）。语言侧 `@comptime` 只有接口（第 3.2 节）。 |
| 单表达式求值入口 | 解释器 `ir_interp_run_fn(cfi, arg_base, argc)`（`interp.cr:183`）是逐函数原语，但入口 `ir_interpret()` 是全程序级（唯一调用点 `main.cr:412`）。没有「求值一个表达式并返回值」的通道。 |
| state 链归属片段 | `cir_cache.cr:15-18`：state 链不随快照持久化；重建需要全程序 IR 体（`dataflow.cr:176-184`）。因此「有语义关系的片段」其关系是插入后由主机图全局重放决定的，不是自带的。 |
| 容量余量 | 底层是 1 GiB 只增不减的 bump 堆（`src/runtime/rt.s:15-17` `heap_start: .space 1024*1024*1024`；`:82-84` 越界进入 `.Lalloc_oom`）。已经因此出现过一次不报错的 SIGSEGV（`cir_cache.cr:505-521` 逐字记录：946 个读缓冲累计 1.1674 GiB > 1 GiB，`alloc` 返回 0，被当 string，`str_len(0)` 崩溃）。 |

`.ccr` V8 关系 `[实测]`：

- 现行 = v9，段表 8 段（`src/compiler/ccr_io.cr:135` `CCR_VERSION : int = 9`；
  `:138` `CCR_SEG_COUNT : int = 8`）。
- V8 设计档 = `docs/maintainer/design/ccr-v8-open-relational-lattice.md`，
  `:5-6` 自述「状态 = 设计定稿（未实现）· 第二版（v2）」，`:112-115`「V8 几乎全是 `[提案]`」。
- 注：team-lead 转述的「有限的关系理论呈现」在仓库里不存在。最接近的是 v1 的
  「有限的关系理论描述」（`:67`）与公理名 `Finite Presentation, Unbounded Denotation`（`:338`），
  而 `:338` 的裁定是「删掉 v1 那条旧承诺」，此后唯一合法写法 = 「`.ccr` 本身有限，但 relation universe 是开放的」。
- 判断 `[推理]`：V8 的目标是收窄而不是扩展 `.ccr` 的语义职责
  （`:288` 逐字「CCR 再成为第四门完整语言是非常糟糕的工程选择。」）。
  因此它不能作为 `HDFGFragment<T>` 的表示面依据；而且它本身还是提案，不是可用的前置。

### 3.6 最接近「特化」的现有机制：泛型单态化

`[实测]`（源码级）：

- 粒度 = `(泛型函数, 类型实参元组)` 对应的整函数 AST 深克隆（`monomorph.cr:1-8`）。
- 缓存键 = `(func_ni, type_args)`，查找是线性扫描 + intern 串相等（`monomorph.cr:780-793` 的
  `gen_find_cached`），因此每次查询 O(实例数)。
- 实例数无上限：`g_gen_instances` 正常翻倍增长（`monomorph.cr:37-41`），全仓 grep
  `MAX_INSTANCES|INSTANCE_CAP|实例上限` = 零命中。唯一的上限在泛型形参数量上：
  `src/compiler/ast.cr:123` `MAX_GENERICS : int = 4`。
- `monomorph.cr` 里没有与「代码膨胀」相关的注释或警告；但仓库别处有一条实例数因修复而增加的实测：
  `docs/superpowers/plans/2026-09-11-r2-p3-capabilities.md:443`「S1 `f[unit]`（折叠！）变为 `f[A]`+`f[B]`（反折叠）」，
  即 1 份变 2 份；连带 `.ccr` 变化 `docs/superpowers/specs/2026-09-10-type-interface-unification-design.md:284`
  「T5 = `generics_test` +370 B 反折叠」。

---

## 四、既有性能问题记录（原文，供引用）

> 注：team-lead 给的线索「corearch 大 `.ccr` 性能问题排查，30K+ instrs 超时」，
> 本次在 `develop@origin` 上做了穷举检索（`corearch`×22 处 md 全读、`30K/30k/30000/30,000/3 万` 全文件、
> `超时/timeout/rc=124/看门狗`、`instrs/指令数`、`jj log -r 'all()'` 全历史提交信息），
> 该条记录不存在。最接近的三条都不是它（下方 (a)/(b)/(c) 已逐条标出差异）。
> 因此不得以「本仓有过 corearch 大 .ccr 超时」为前提做设计。
> 该说法只存在于代理记忆文件，不是 `develop@origin` 的入库内容。

真实存在、且与本评估直接相关的四条：

(a) `.cir` 快照曾是「净负收益」 `[实测原文]`
`docs/superpowers/plans/2026-09-17-cir-cache-bloat.md:504-505`：
> 「`.cir` 缓存此前是「净负收益」：暖跑 13+ min（看门狗杀）> 冷跑 231 s 且卡死（D 态）」
> 「本次后第一次「暖 < 冷」（32.50 s < 39.77 s），从「25× 负收益」变成「正收益」」

(b) 有缓存状态大文件的问题仍未完全解决 `[实测原文]`
`TODO.md:1315`：
> 「另：`warm_leg.sh` 全清单（74 档）在干净窗口下 901 s 硬超时截断（停在 35/74），
> 因此第3条广度层对大文件没有覆盖」

(c) 单条快照固定开销约 150 s 下限（未修） `[实测原文]`
`TODO.md:1417`（条目 `#2026-09-17-16`）：
> 「注：（性能·实测触发条件）`.cir` 快照「每条目固定开销」≈0.13–0.24 s × 1011 条 ≈ 150 s 下限，
> 候选 3（单文件/打包缓存）的立项依据（2026-09-17 缓存膨胀阶段 T1 实测登记，本次不修）」

(d) 「编译时间线性化」计划：文字细化完成，一行未实施 `[实测原文]`
`TODO.md:874`：
> 「状态：细化完成，未实施（T1..T10 待裁后开工）」

该计划已登记未实测的 O(·) 嫌疑点（`docs/superpowers/plans/2026-09-04-compile-time-linearity.md`）：
`:39` `checker.cr:215 find_sym`/`:225 find_gsym` O(U×S)、`:64-66` `elf.cr:1475` O(C×F)、`elf.cr:1200` O(F²)。

> `[推理]` (d) 对本评估的意义：仓库已经认定编译时间存在多个超线性点，
> 并且已经写好了修法，但一行没做。因此「先修成本面、再谈增加能力」这条路径在本仓已有起点，
> 不需要新立项。

---

## 五、逐方向评估

### 5.0 表头与判定说明

四栏 = 编译期成本（相对第二节基线的量级 + 推理依据）、膨胀风险、缓解手段（含代价）、判定。

判定词定义（本篇一致）：

- 可行：前置齐备，且 `[推理]` 成本落在 ×1.0–1.3 区间。
- 有条件可行：前置明确可写清；或成本落在 ×1.3–2.0，但可以用预算或惰性压回。
- 不可行：要么缺前置且前置本身是多年期，要么在 2.3 节的已超线性面上引入不动点或乘法，
  使自编译成本越过可接受线。

成本量级的分母 `[实测]` = 自编译冷启 41.3 s（第 2.2 节）；其中分析面 ≈ 30.0 s，且已经超线性（第 2.3 节）。
因此任何「在图上多做一遍分析」的成本，分母不是 41 s，而是那 30 s，并且要乘超线性因子。

### 5.1 块一 7 方向

| # | 方向 | 编译期成本 | 膨胀风险 | 缓解手段（代价） | 判定 |
|---|---|---|---|---|---|
| 1 | 自动 Partial Evaluation / BTA | `[推理]` ≥ ×3，且无法定上界。BTA 是不动点分析（绑定时间沿 def-use/state 边传播到收敛）；本仓 169,418 节点 / 156,217 边 / 7,638 区段。落在已经超线性的 `ptr_analysis`/`region_check` 同一面上。 | `[推理]` 极高：residual graph 与 polyvariant 同源（见 5.9）。`[实测]` 结构性节点已占 40.8%，会连同复制。 | 预算上限、深度限制、只在显式 `@comptime` 时做。代价：预算会引入一个新的不收敛失败面（本仓对不报错地零容忍，因此必须 fail-closed 报错，这又成为用户可见的新错误类）。 | 不可行（当前） |
| 2 | Typed Multi-Stage Programming（`Code[T]`） | `[推理]` 实现方式成本低（无新分析），但前提是 typed fragment 存在（见 5.12），成本记在那一栏。 | `[推理]` 中：stage 数 × 生成代码量。 | 限制 stage 层数。代价：`Code(Code(T))` 是本方向的核心卖点（块二第 5 节），限制层数就削掉了卖点。 | 有条件可行（前置于 5.12 和类型覆盖率从 36% 提高到较高水平） |
| 3 | 自动 staging + effect preservation | `[推理]` ×1.5–2.5：需要在既有 pass 之上再加 effect 推理链（`df_state_finalize` 已存在，是起点）。`[实测]` 该 pass 已占 30 s 的一部分。 | `[推理]` 低（只搬 stage，不复制代码）。 | 只在 `@comptime` 标注处做（退回 Zig 语义）。代价：与提案「用户零学习成本」的核心卖点冲突。 | 有条件可行，但必须去掉「零标注」这一条 |
| 4 | Polyvariant specialization | `[推理]` ×2–×N（N = 变体数）。`[实测]` 15,244 个 `IR_CALL` 是变体的上界基数。 | `[推理]` 本方向最著名的问题，本仓数字尤其不利：见 5.9。 | 变体上限、只对显式标注的函数做、去重。代价：`monomorph.cr` 的实例缓存已经是线性扫描（`monomorph.cr:780-793`），变体数上去后查询本身变成 O(N)，在已经超线性的面上再叠一层。 | 不可行（当前） |
| 5 | Library-level compiler / DSL staging（LMS） | `[推理]` ×1.2–×1.5 于库的编译，但本仓是自举，编译器自己也是「库」。 | `[推理]` 中高（每个库自带 rewrite 集）。 | 各库自行限量。代价：`[实测]` 没有沙箱。1 GiB bump 堆、零回收（`rt.s:15-17`），失控的库 rewrite 直接 OOM，且失败形态是返回 0 指针（`cir_cache.cr:505-521` 记录过一次不报错的 SIGSEGV）。 | 有条件可行（必须先有资源预算与失败面） |
| 6 | Typed / Hygienic semantic macro | `[推理]` 低成本（若只生成 declaration）；高成本（若生成 HDFG）。 | `[推理]` 中。 | 卫生性（hygiene）本身是已知的硬工程问题。 | 有条件可行（仅限 declaration 层，见 5.13） |
| 7 | Dependent staged computation | `[推理]` ×10 以上或不可估计。需要依赖类型内核参与编译期判定。 | `[推理]` 极高。 | 无。 | 不可行（前置 = CIC 内核，现为 0 实现，且 `src/kernel/` 只有 MLTT 的 Π+ℕ 片段，未接入） |

### 5.2 块二 8 方向

| # | 方向 | 编译期成本 | 膨胀风险 | 缓解手段（代价） | 判定 |
|---|---|---|---|---|---|
| 1 | 第一等「程序片段」`HDFGFragment<T>` | `[推理]` 实现成本高，但运行成本可以低（若只保存/插回）。前置成本极高（见 5.12）。 | `[推理]` 高：片段 = 图的复制，而 `[实测]` 图上 40.8% 是结构性节点、14.3% 是 thunk/force。 | 片段去重、引用共享。代价：本仓「节点无稳定身份」（只有下标），去重需要先造身份。 | 不可行（当前），前置 8 项见 5.12 |
| 2 | 任意 declaration generation | `[推理]` ×1.1–×1.3（比 HDFG 类方向低一个量级）：声明生成发生在前端，而 `[实测]` 前端是线性的（第 2.3 节第 1 条），且 `build_selfhost_native` 的前端只占总时间约 1/3。 | `[推理]` 取决于生成量；`[实测]` 声明收集器（checker 两遍）是标准结构，可重入性未核实。 | 生成量上限、与泛型单态化共用实例缓存。代价：`monomorph.cr` 的实例缓存无上限且线性查找（`monomorph.cr:37-41` / `:780-793`），不能直接复用，需要先改数据结构。 | 有条件可行，是本次 15 个方向里前置最少的一个 |
| 3 | Semantic Reflection（`@effects`/`@regionOf`/`@dependencies`…） | `[推理]` ×1.2–×1.5（每次都调用一个已有分析结果，不重算）；但 `[实测]` 类型项覆盖率只有 36.09%，需要先把 `pie` 结果补到高覆盖。 | `[推理]` 低（查询不复制代码）。 | 只读查询 + 缓存。代价：需要先把 `TYPE` 段从 23 行/61 项扩到有意义的规模，且 `OFF_DF_TK` 的填充点只有 emit 与装载两处（`globals.cr:456-457`）。 | 有条件可行（前置 = 类型项覆盖 + 查询 API） |
| 4 | 编译期 typed semantic transformation | `[推理]` ×2 以上（同 5.1-1 的 PE 面）。 | `[推理]` 高。 | 同上。 | 不可行（当前） |
| 5 | 真正的 Multi-stage（Stage 0/1/2/3） | `[推理]` 每多一个 stage 就是一次完整编译。`[实测]` 一次自编译 = 41.3 s 冷。 | `[推理]` 高。 | 无。 | 不可行（数量级冲突，见 5.11 的同款论证） |
| 6 | 程序级查询（whole-program query） | `[推理]` ×1.5–×3，且 `[实测]` 已有先例：`.cir` 快照的「全程序表随每函数落盘」就是这一类错误。`cir_cache.cr:406-410` 逐字记录它导致二次膨胀（「实测 4,314 万条边记录 vs 20.6 万节点记录」「它正是本条二次膨胀的起点」）。 | `[推理]` 中（查询结果大小）。 | 惰性 + 索引。代价：索引本身要维护，且在已经超线性的图上建索引 = 又一遍全图遍历。 | 有条件可行（前置 = 索引结构 + 成本实测） |
| 7 | Hygienic + type-directed syntax metaprogramming | `[推理]` ×1.2–×1.5（前端面，线性）。 | `[推理]` 中。 | 限量。代价：学习成本（提案自己标「非第一优先，会增加学习成本」）。 | 有条件可行 |
| 8 | Proof-directed comptime（`@provable(P)`） | `[推理]` 时间尺度完全不同：编译期 SMT 是毫秒到秒到分钟级。见 5.10。 | — | 超时/预算。代价：超时就是「未证」，而未证在当前设计里不阻断编译（`checker.cr:4424-4431` 裁-V6），用户得到一个不报错地降级的实现，这正是本仓明令禁止的失败形态。 | 不可行 |

### 5.3 两稿收敛清单（11 项）：与上表的映射

块一收敛 5 项，对应上表 `5.1-1`（Automatic PE）、`5.1-4`（Polyvariant）、`5.1-2`（Typed HDFG staging）、
`5.1-3`（Effect-aware staging）、`5.2-1+5.1-6`（Typed semantic metaprogramming）。
判定汇总：4 项不可行或有条件，1 项（effect-aware）有条件可行，但必须去掉「零标注」。

块二收敛 6 项，对应 `5.2-1`（新增 1）、`5.2-2`（新增 2）、`5.2-3+5.2-6`（新增 3）、`5.2-4`（新增 4）、
`5.2-5`（新增 5）、`5.2-8`（新增 6）。
判定汇总：3 项不可行，3 项有条件可行。

`[推理]` 跨表观察：两稿都把「新增 2 = 任意 declaration generation」排在能力列表里，但它不是
它们最推荐的方向。而按本仓实测的成本结构，它恰恰是唯一前置最少、且落在「前端是线性的」这一侧的。

### 5.4 独立小节：Partial Evaluation + Binding-Time Analysis

复杂度落在哪 `[推理]`：

BTA 是对绑定时间格（`{Static, Dynamic}` 或含 `⊥` 的三点格）求不动点。传播沿
def-use 边、state 边和调用图进行。本仓的规模量（`[实测]`）：
169,418 节点、156,217 边、7,638 区段、15,244 调用点。

工作集估算 `[推理]`：每个节点一个绑定时间（1 byte）+ 每边一个传播记录，最小 0.5–1 MB 级，
相对现有 41.7 MiB 的 `.cir` 缓存不算大。问题不是内存，是迭代次数：
调用图有环（`[实测]` 编译器自身是递归的，`sq`/`gen_expr`/`checker` 全有自递归），
因此不动点迭代 ≥ 调用图 SCC 数 × 图规模。

落在哪个成本面上（从实测到推理）：这是 O(nodes × iter) 或 O(edges × iter) 的遍历，
与第 2.3 节里已经占 30 s 且超线性的 `ptr_analysis`/`region_check` 是同一形状。
因此自然位置不是「41 s 变成 60 s」，而是那 30 s 变成 30 s × k，k = 迭代数。

编译器自己的 38 个文件里有没有会因此显著增长的形态？ `[实测 + 推理]`

有，而且量出来了：

| 形态 | `[实测]` | `[推理]` 对 PE/BTA 的意义 |
|---|---|---|
| 大函数（HDFG 单函数级） | 最大单函数快照 2.63 MB（`type_selftest_run`）、1.56 MB（`gen_expr`）、1.11 MB（`infer_expr`） | 不动点在函数内先跑；这三个函数的图规模是 p50 的 63×–105× |
| 巨型平坦函数 | `[实测]` `.cir` 缓存 top 100 函数 = 43.3% 字节；p50 25 KB vs max 2.63 MB（105× 长尾） | 预算/超时策略必须按函数而不是全局设置，否则长尾函数会单独触顶 |
| 递归 + 互递归 | `[实测]` 调用点 15,244；`checker`/`ir_gen`/`parser` 互为环 | 不动点迭代数 = SCC 深度，不可预知 |
| thunk/force 包装 | `[实测]` 24,215 节点 = 14.3% 是 `IR_LAZY_THUNK`/`IR_LAZY_FORCE` | 绑定时间必须穿透这层包装，否则每个 thunk 都是一个伪「动态」点，PE 收益会被自己的包装抵消 |
| 结构性节点 | `[实测]` 40.8% 是 LABEL/JUMP/BRANCH/THUNK/FORCE/ARENA_* | residual graph 复制时全部跟着复制 |
| 类型项覆盖不足 | `[实测]` 只有 36.09% 节点带项 | 「这个子图可执行」的判定需要类型信息，64% 的节点上无法判定 |

判定：不可行（当前）。
不是因为方向错，是因为三条同时成立：
1 前置（编译期求值器）为 0；2 位置面已经超线性，且已占 73% 编译时间；
3 不动点迭代数在本仓语料上不可预估（递归 + 长尾）。

最小可行切片（若维护者仍想推进）`[推理]`：
先做「单函数内、无调用、无环」的 BTA（即今天的 `#check` 折叠器 + 局部变量传播），
且必须有预算上限。这一步的检查可以完全复用 `#check` 的 V01/V05/V06 三态机制。

### 5.5 独立小节：Polyvariant specialization 的代码膨胀量级

这是它最著名的问题，本仓的数字尤其不利。

膨胀来源一：连结构性节点一起复制 `[实测]`
编译器自身图的 40.8% 是结构性节点、14.3% 是 thunk/force。
因此一个「语义上只有 55 条指令」的函数，复制一份实际要复制约 93 个节点。

膨胀来源二：变体基数 `[实测]`
`IR_CALL` = 15,244 个调用点（编译器自身）。每个调用点若按 N 个静态值分裂，
最坏 15,244 × N 个变体。对照：现有 monomorphization 只在泛型上做，
`[实测]` 其例子是 1 份变 2 份（`plans/2026-09-11-r2-p3-capabilities.md:443`），且 `.ccr` 只涨 +370 B。
polyvariant 把它推广到「任何静态关系」，基数从「泛型实例数」放大到「调用点数 × 静态值域」。

膨胀来源三：缓存本身变成 O(N) 查找 `[实测]`
`monomorph.cr:780-793` 的 `gen_find_cached` 是线性扫描 + intern 串比较。
今天实例少（`[推理]` 数十量级）没问题；变体上到千、万量级时，
每次查缓存是 O(N)，总成本 O(N²)，又叠在第 2.3 节的已超线性面上。

膨胀来源四：产物侧 `[实测]`
`.ccr` 12,698,096 B 对应 169,418 节点。若变体使节点数 ×3，`.ccr` ≈ 38 MB，
`corearch` 要处理它（`[实测]` 今天 4.91 s）。而 `.cir` 缓存已经是 41.7 MiB，
底层 1 GiB bump 堆、零回收（`rt.s:15-17`）。`cir_cache.cr:505-521` 已记录过一次因此发生的 OOM/SIGSEGV。

缓解手段与代价：

| 手段 | 代价 |
|---|---|
| 变体上限（数量/深度） | 触顶时的语义是什么？本仓禁止不报错地降级，因此必须硬错（新错误类） |
| 只对显式标注的函数特化 | 退回 Zig 语义，削掉「自动」卖点 |
| 变体去重 | 需要节点身份（现在没有，只有下标） |
| 惰性/按需 | 编译期节省、运行期付费，且与「编译期成本可预测」冲突 |

判定：不可行（当前）。
膨胀不是「可能会有的风险」，而是在本仓已经量出的三个数字（40.8% / 15.3K / O(N) 查找）上直接相乘。

### 5.6 独立小节：Proof-directed comptime 的编译期 SMT

时间尺度 `[推理]`：SMT 求解是毫秒到秒到分钟级（取决于理论与目标），
而本仓的全量构建 = 15.2 s（第 2.1 节）、一次自编译 = 41.3 s（第 2.2 节）。
因此一个目标的 SMT 超时（常见默认 10–30 s）就会占掉一次完整自编译的时间。
数量级直接冲突，不是调优问题。

CIC + SMT 现状（team-lead 要求本次再核一遍）`[实测]`：

- CIC：`src/compiler/` 内 0 实现。设计定稿在
  `docs/maintainer/design/spec-design.md` + `adr-0009`（`:4` 逐字 `accepted(设计定稿,未实现)`；
  `:18`「全链未实现（解析/翻译桥/SMT 通道/内核绑定）」）。
- SMT：0 实现。`grep -rnwE 'smt|z3|cvc5|solver' src/ bootstrap/ tools/` = 0 命中
  （不带词边界会误命中 `NameResolver`，是假阳性）。设计里的 `#smt` 标签也未实现。
- `#check`/`#ensure` 的 C1 切片：已实施并进 CI，但需要打折。
  C1 定义（`docs/superpowers/plans/2026-09-16-verification-slice.md:32`）含「编入图」，
  实际把「编图」砍掉了（`TODO.md:856`「未编图（裁-S4…转 C1b）」）。
  因此实施的是词法、语法、检查和 dump，中间不经过 IR 图。
- `[实测]` 另外两条本次核到、两份评估档都没提的事：
  1 `coq/fmt_int.v` 是用外部 Coq 验证 stdlib 函数的证明（`Theorem roundtrip`），
     `docs/coq/README.md:6` 自明「这不是规约系统」，它不构成 CIC 通道的任何实现。
  2 `src/kernel/` 有 1287 行真实现的依赖类型内核（McTT 移植：`nbe.cr` 261、
     `term_io.cr` 301、`kernel_main.cr` 192 等），带差分对拍语料与冻结期望值。
     但 `docs/superpowers/specs/2026-08-15-mctt-core-kernel-design.md:42` 逐字
     「没有 Σ、没有 Id、没有 W-类型」，因此是 MLTT 的 Π+ℕ 片段，不是 CIC；
     `src/compiler/` 对它零引用；`src/ci/run.sh` 零接入点；且 2026-09-20 那份最新评估
     （`docs/superpowers/plans/2026-09-20-safety-verification-plan.md:193`）对 `McTT`/`src/kernel`
     零提及，直接写「五阶段目标全部未启动」。
     这是评估文档面与仓库现实之间的一条真实差异，本身值得登记。

判定：不可行。
卡住它的约束：编译速度（数量级冲突）和前置（CIC/SMT 通道 0 实现，且 `src/kernel/`
即使按最乐观估计也只是 Π+ℕ 片段）。两条同时成立，任一条单独就足够。

### 5.7 独立小节：Typed HDFG fragment 作第一等 comptime 值

与 `.cir` / `.ccr` / V8 的关系 `[实测 + 推理]`：

| 关系面 | `[实测]` 事实 | `[推理]` 判断 |
|---|---|---|
| `.cir`（函数快照） | 粒度 = 函数；`save_cir_cache(path, source_fi, ir_fi)` 三个取界全来自函数级数组 | `HDFGFragment` 想做的事，`.cir` 已经做了 80%，但只对「整函数形状」成立。补齐「任意片段」需要：片段边界概念、节点身份、var 域平移、类型项可迁移（第 3.5 节表，8 项） |
| `.ccr`（存在格实现方式） | v9 / 8 段 / NOD 40 B；`item` 槽 = 类型项索引（`[实测]` 覆盖 36.09%） | 片段的表示面够，语义面不够 |
| V8（设计中） | `[实测]` 全是 `[提案]`（`:112-115`）；且目标是收窄 `.ccr` 的语义职责（`:288`「CCR 再成为第四门完整语言是非常糟糕的工程选择」） | team-lead 问「V8 可能反而让 fragment 更自然，也可能相反」，答案是「相反」，而且更弱：V8 是提案（不可依赖），取向是收窄不是扩展 |
| state 链归属 | `cir_cache.cr:15-18`：state 链不随快照持久化，重建需要全程序 IR 体 | 正面冲突：`HDFGFragment<T>` 想要「有语义关系的片段」，而语义关系（state 序）在本仓是主机图的全局性质 |

判定：不可行（当前）。卡住它的是前置，不是编译速度：
第 3.5 节表列出的 8 项缺失里，至少 3 项是设计级而非工程级
（节点身份、var 域重映射、state 链归属）。

唯一低成本的前身 `[推理]`：把 `.cir` 快照的函数边界抽象成任意 `(node_start, node_count)`，
并接受 var 域不可平移（片段只能用于同一次编译内的重排，不能跨编译或跨上下文）。
这条路径不需要节点身份，不需要类型项跨进程，检查可以复用 v20/v21 的既有结构。

### 5.8 独立小节：Semantic reflection / whole-program query

全程序查询在编译期执行的代价 `[实测]`：

- 本仓有过一次同类错误，并被逐字记录：`.cir` 快照曾把全程序边表/字符串表随每个函数落盘，
  `cir_cache.cr:406-410` 逐字：「实测 4,314 万条边记录 vs 20.6 万节点记录」
  「它正是本条二次膨胀的起点」。修法（v20）是收窄到本函数。
- `[实测]` 今天的规模：6,238 串 / 156,217 边 / 169,418 节点 / 7,638 区段。
  「全程序查询」在这个规模上是每次查询 O(全图)；若无索引，N 次查询 = O(N × 全图)。
- `[实测]` 查询所需的语义事实大部分已经存在（`g_sgs` 区段表、`g_df_edges` 的
  `kind=1` state 边、`g_type_terms` 类型项、`g_gen_instances` 泛型实例表、
  `func_ispure` 纯度位），缺的是查询 API 和索引，不是数据。

判定：有条件可行。条件：
1 查询必须离线或汇总（一次遍历产出索引），不是每次从零扫描；
2 检查必须带成本测量（本仓已有先例：`docs/superpowers/plans/2026-09-11-effect-purity-fix.md:100`
   「风险：1 `find_func` O(F²)（大项目下变慢，可先测编译耗时，超阈值再换哈希）」）；
3 类型项覆盖面必须先从 36.09% 提到足以支撑查询语义的水平（否则查询结果会不报错地缺格，
   本仓对不报错地零容忍）。

---

## 六、总体判定

### 6.0 一句话

> 方向没错，但它今天不是「要不要做」的问题，是「基础能力为空、速度面已经超线性」的问题。
> `[实测]` comptime 的自动推导（提案的第一原则）实现度 0；`@comptime` 只有接口，没有实现；
> 唯一的编译期求值是 `#check` 的字面量折叠器。同时 `[实测]` 自编译 41.3 s 里，
> 30.0 s（72.7%）花在常开的 HDFG 分析 pass 上，而这个面已经实测超线性
> （节点 ×1.98，分析面 ×4.71）。本次 15 个方向里，需要「在图上多做分析或多复制图」的那些，
> 全部落在这个面上。

### 6.1 现在就能做的方向（不依赖未实施的东西）

按前置多少排序（越靠前越可做）：

| 序 | 内容 | 前置 | `[推理]` 成本 | 依据 |
|---|---|---|---|---|
| T0 | 修第 2.3 节的超线性：`pa_in_unsafe`/`is_in_unsafe` 改用 O(1) 映射 | 无（`region_check.cr:5-11` 的 `subgraph_containing` 就是现成先例） | 负成本 | `[实测]` 分析面占 72.7% 且超线性；`execution-mapping-design.md:1152` 已登记该 O(·) |
| T1 | `@comptime(expr)` 从只有接口变成真正强制 | 无。解释器已在 `corec` 内（`interp.cr` 在 `corec_files` 清单），且有 `ir_interp_run_fn(cfi, arg_base, argc)` 逐函数原语 | ×1.0–1.1（只在标注点跑） | `[实测]` `ir_gen.cr:2093-2105` 自承 `Future: invoke ir_interpret_expr` |
| T2 | `@fields` 从逗号串改成真正可遍历；`@field` 补类型 | 无（数据已在 `si_field_*` 表） | ×1.0 | `[实测]` 第 3.2 节两格部分实施 |
| T3 | `@typeInfo` 从类型名串改成真正结构 | 无（`g_structs` 表齐全） | ×1.0 | `[实测]` 第 3.2 节该格与文档不符 |
| T4 | `#check` 折叠器扩到纯函数调用 | 纯度时序（`checker.cr:4424-4431` 裁-V5 明说「纯度时序陷阱未被解决、只被绕开」） | ×1.0–1.1 | `[实测]` 出处同第 3.3 节 |

> T0–T4 的共同点：都在线性面上，都不引入新分析，都不复制图。
> `[推理]` 五条合起来的总成本 < ×1.2，且 T0 是负成本。

### 6.2 必须先有前置的方向

| 方向 | 前置 |
|---|---|
| declaration generation（5.2-2） | 1 声明收集器可重入性核实（`[未核实]`）；2 实例缓存数据结构换成哈希（现为线性扫描，`monomorph.cr:780-793`）；3 生成物的 `.ccr`/`.cir` 字节变化检查（本仓 `tests/spec/` 的 Δ 公式是现成范式） |
| semantic reflection（5.2-3） | 1 类型项覆盖率从 36.09% 提高到较高水平（填充点只有 emit/装载两处，`globals.cr:456-457`）；2 region/edge/purity 的只读查询 API；3 成本检查 |
| whole-program query（5.2-6） | 同 23，加索引结构（本仓已有一次「全程序表随函数落盘」的膨胀先例，`cir_cache.cr:406-410`） |
| effect-aware staging（5.1-3） | effect/纯度系统的真值化（`fi_ispure` 现为「生成期乐观默认值」，`checker.cr:4526-4531` 头注。注：同一句的出处引用 `checker.cr:4430` 指向的「本文件 3968-3977」是陈旧标注，`[实测]` 该区间实际是「泛型结构体字段绑定」代码，真注记在 `:4526-4531`） |
| HDFGFragment（5.2-1） | 第 3.5 节表的 8 项，其中 3 项是设计级（节点身份、var 域重映射、state 链归属） |
| LMS（5.1-5） | 资源预算 + 失败面（1 GiB bump 堆、零回收、失败形态 = 返回 0 指针） |
| typed multi-stage（5.1-2） | HDFGFragment + 类型覆盖 |

### 6.3 不可行或代价不可接受的方向

| 方向 | 卡在哪个约束 |
|---|---|
| 自动 PE / BTA（5.1-1） | 编译速度（位置已超线性且占 73%）+ 缺前置（求值器为 0）+ 迭代数不可预估（递归 + 长尾函数）。三条同时成立。 |
| Polyvariant specialization（5.1-4） | 编译速度 + 膨胀：`[实测]` 结构性节点 40.8%、调用点 15,244、缓存 O(N) 查找、`.cir` 已 41.7 MiB，对 1 GiB 堆。膨胀是三个已量出数字的直接乘积。 |
| Dependent staged computation（5.1-7） | 缺前置：CIC 内核（0 实现；`src/kernel/` 只是 MLTT 的 Π+ℕ 片段且未接入）。多年期。 |
| Proof-directed comptime（5.2-8） | 编译速度（SMT 毫秒到分钟，对比全量构建 15.2 s、自编译 41.3 s）+ 缺前置（CIC+SMT 0 实现）。 |
| 真正的 multi-stage（5.2-5） | 编译速度：每个 stage = 一次完整编译（`[实测]` 41.3 s 冷）。 |
| typed semantic transformation（5.2-4） | 同 PE。 |

### 6.4 计划草案（可行部分）

> 注：按指令，这不是正式计划档，只是草案。正式计划是下一步。
> 且本草案的前提是先把第 6.0 节的两条约束（基础能力为空、速度面超线性）处理掉。

工序与检查：

| 步 | 内容 | 检查 | 依赖 |
|---|---|---|---|
| S0 | 成本面处理：`pa_in_unsafe`/`is_in_unsafe` 改 O(1)（复用 `g_df_node_region` 先例）；顺带把 `find_gsym` 的 O(U×S) 评估一遍 | 1 `build_selfhost_native.py` 墙钟不劣化；2 合成语料的规模曲线（本档第 2.3 节的表格就是现成基线）幂次从 ~2.2 降到 ~1.0；3 自编译墙钟下降（这才是本步的验收面） | 无，可立即开工 |
| S1 | `@comptime` 真强制：接 `ir_interp_run_fn`，加「算不了 = 硬错」 | 1 负例：`@comptime(运行时值)` 必须 rc=1（今天 rc=0，本档第 3.2 节探针就是现成的 RED 用例）；2 正例：`@comptime(f(常量))` 产物里不出现对 f 的 IR_CALL；3 自编译墙钟 Δ ≤ +2% | 无 |
| S2 | 反射三格补齐（`@fields` 可遍历、`@field` 补类型、`@typeInfo` 结构） | 1 逐格对照 `at-intrinsics.md` 的措辞写探针（本档第 3.2 节的表就是逐格检查）；2 `.ccr` Δ 公式（`tests/spec/` 范式） | 无 |
| S3 | `#check` 折叠器扩到纯函数调用（前置 = 纯度时序结束） | 1 纯函数调用折叠为绿；2 不纯函数调用仍 V06 硬错（反向对照）；3 编译成本 Δ ≤ +2% | 纯度时序结束（已知未解） |
| S4 | declaration generation 最小切片 | 1 生成物进入普通语义管线（不是字符串拼代码）；2 实例缓存换哈希后成本不劣化；3 生成量上限 + 触顶硬错 | S0（哈希改造） |
| S5 | semantic reflection 查询 API（只读，离线索引） | 1 类型覆盖率提升后的查询结果完整性（不得不报错地缺格）；2 编译成本 Δ 带测量（`effect-purity-fix.md:100` 范式）；3 「同类但不该报」的对照探针（防类别误报） | S2（类型覆盖） |

与现有阶段的先后关系 `[推理]`：

- S0 与任何在飞的阶段都不冲突（它只改两个函数的循环形状），且对所有后续阶段都是净收益，
  `[实测]` 分析面占自编译 72.7%。建议最优先。
- S1/S2 独立、小、检查现成，可以作为「comptime 面从 0 到 1」的第一步，
  形态与本仓 C1 切片（`#check`，阶段 6）同构，有先例可循。
- S3 有已知未解前置（纯度时序），不要与 S1/S2 同阶段。
- S4/S5 及之后的一切（PE / polyvariant / fragment / multi-stage / proof-directed）
  不应在本档通过。它们需要第 6.2 节的前置，而前置本身是独立阶段。

---

## 七、未能核实清单（这项最重要）

### 7.1 无法核实的内容（能力、权限或时间所限）

| # | 未核实项 | 为什么 | 影响 |
|---|---|---|---|
| 1 | `ccr` 超线性的逐 pass 归因 | 不许改既有文件，因此无法插计时点。本次归因是机制候选（`pa_in_unsafe`/`is_in_unsafe` 的 O(nodes×regions)），不是实测。 | 第 2.3 节的机制判断是 `[推理]`。做 S0 前应先自证（最省的办法：临时把 `g_sg_count` 人为压到 1 看落差，或对 `is_in_unsafe` 加计数）。 |
| 2 | 幂次 2.2 是否在更大规模上保持 | 只有 3 个规模点，且幂次本身在增长（1.58 到 2.24）。 | 第 2.3 节的幂次是局部值，不可外推。 |
| 3 | `build_selfhost_native.py` 的 15.24 s 与文档 25.6 s 的差异归因 | 无对照条件（不同日、不同负载、可能不同修订）。 | 第 2.1 节的两个数都是分布样本，不可当常数。 |
| 4 | 机器负载对本档全部数字的影响 | 负载 7–10 / 4 核（有其它代理）。`[实测]` 同命令三次采样极差 6.5×。 | 所有绝对值只能作量级参考；比率（×2.11 / ×4.27 / ×4.71）比绝对值可信，但也受同样污染。 |
| 5 | `#check`/`#ensure` 的 34 档语料 / 48 项自测是否全绿 | 本次未运行 `python3 tests/selfhost/test_spec_grammar.py`。 | 第 3.3 节的「已实施」依据源码分派点和另一份实核报告，未做端到端复跑。 |
| 6 | `src/kernel/` 的 1287 行是否真能跑（构建/对拍是否通过） | 未构建（`build/kernel` 不存在；不在 CI）。 | 第 3.4/5.6 节只断言「存在、未接入、非 CIC」，未断言其正确性。 |
| 7 | 声明收集器（checker 两遍）的可重入性 | 未读代码。 | 第 5.2-2 节「declaration generation」的前置1未核实。 |
| 8 | `.cir` 有缓存状态在本档 full-bootstrap 里的真实贡献 | stage 2 暖跑 56.4 s 慢于 stage 1 冷跑 41.3 s，本次未归因（可能含缓存写入/读取开销）。 | 不据此推断 `.cir` 的收益或损失；本仓文档自有该账（`TODO.md:1322-1323`）。 |
| 9 | `docs/superpowers/plans/2026-09-04-compile-time-linearity.md` 的 O(·) 清单逐条是否成立 | 该计划自述「未实施」，且部分条目自标「未读到显式 O(F²)…T1 精确定位后再改」。 | 第四节 (d) 只做「仓库自己已认定存在超线性点」的存在性引用，未采纳其具体行号。 |
| 10 | 三块讨论稿引用的 11 篇论文的任何具体结论 | 未读原文。 | 本档不对论文内容做任何判断；论文只在讨论稿里作为动机出现。 |

### 7.2 `[实测]` 与 `[推理]` 的逐条归属（供复核）

> 本轮（第四块输入）新增的归属见第十一节末尾。本小节只覆盖第一到第七节。

`[实测]`（本次运行得到的数字）：
第 2.1 节全表、第 2.2 节全表、第 2.3 节全表（min-of-3，clean-cache，nice -n 19）、第 2.4 节全表（`.ccr` 段解析 +
opcode 直方图 + `item` 覆盖率自解析）、第 2.5 节全表（`.core/cache/cir` 文件统计）、
第 3.1 节四个探针、第 3.2 节逐格分派点 + 四个探针、第 3.5 节 V8 状态与 CCR_VERSION=9、
第 3.6 节单态化源码事实、第四节四条原文、第 5.6 节 CIC/SMT 的 0 命中检索。

`[推理]`（推理判断）：
第 2.3 节的机制归因（超线性 = `pa_in_unsafe`/`is_in_unsafe` 的 O(nodes×regions)）、
第 2.4 节的两条量化结论（40.8% 结构性节点 / 36% 覆盖率的后果）、
第五节全部 15 个方向的四栏评估、第六节全部判定与计划草案。

`[未核实]`：第 7.1 节的 10 条。

### 7.3 推翻或更正的既有说法（供归档）

| 说法 | 出处 | 本次实测 |
|---|---|---|
| 「corearch 大 `.ccr` 性能问题排查，30K+ instrs 超时」 | team-lead 转述（代理记忆） | `[实测]` 在 `develop@origin` 上不存在。穷举检索（含 `jj log -r 'all()'` 全历史提交信息）零命中。不得作为设计前提。 |
| 「Core 已有 `pass.cr` 做 AST 常量折叠」 | `CLAUDE.md` 架构节「`pass.cr` 到 AST-level optimization (constant folding)」 | `[实测]` `src/compiler/pass.cr` 全文 24 行，是编译器扩展钩子调度器（`pass_before_array_access` / `pass_after_binary` / `dispatch_call`），与常量折叠无关。常量折叠在 `opt.cr`，且调用点被注释掉。 |
| 「`.ccr` = 有限的关系理论呈现」 | team-lead 转述 V8 | `[实测]` 该字符串在仓库中不存在。最接近的是 v1 的「有限的关系理论描述」，且 `ccr-v8-open-relational-lattice.md:338` 的裁定是删除该承诺。 |
| 「`comptime.md` 自述『多数单元格未实施』」 | 该档头部 | `[实测]` 比「多数未实施」更弱：其设计原则第 1 条（自动推导）实现度 = 0，且「可编译时执行的条件」表的两列标记位在文件里是空的（`cat -A` 逐字节核）。 |
| 「CIC+SMT 通道 0 实现，C1 切片已实施」 | 另一份文档 | `[实测]` 成立但要打折：C1 定义里的「编图」被裁掉，转 C1b（`TODO.md:856`），因此实施的是 C1 的语法、检查和 dump 部分。另加两条该说法未提的事实：`coq/` 与规约系统无关（其 README 自明）；`src/kernel/` 有 1287 行真内核，但是 MLTT 的 Π+ℕ 片段，未接入、未入 CI。 |

> 本清单在第十节有本轮补充（三条）。

---

## 八、总方向（typed semantic metaprogramming）八项逐项评估

> 输入 = `/tmp/briefs/metaprog-model-raw.md`（第四块，team-lead 指定为本档的主要目标；
> 前三块是它的分解与前置）。该稿自述读 `main` 的 `docs/comptime.md` / `docs/at-intrinsics.md` /
> `docs/spec-design.md`。前两条路径不在该位置（实际 = `docs/maintainer/proposals/comptime.md`、
> `docs/developer/at-intrinsics.md`），且 `main` 不是 `develop` 当前点，因此现状断言本次逐条重核。
> 本节的所有「现状」句一律以第三节、第 3.5 节、第 8.5 节的重核为准，不采信该稿的自述。

### 8.0 前言「不新增任何语言」的现状核 `[实测]`

| 检索 | 结果 |
|---|---|
| `grammar/core.ebnf`（67 条产生式）里的 macro / hygien / quote / splice / comptime 产生式 | 0 |
| `src/` 中 `macro` / `quote` / `splice` / `egraph` / `equality saturation` / `saturation` | 均 0 个文件命中 |
| `src/` 中 `hygien` | 1 命中 = `src/ci/run.sh:158` 的 `test_suite_hygiene.py`（测试套件卫生，与宏卫生无关，假阳性） |
| `Fragment` / `Goal<` / `Proof<` / `Rewrite<` 作为语言类型 | `src/` `bootstrap/` `grammar/` 全 0；`docs/` 的命中全是本档自身或 `Rewrite:` 任务标签 |
| `e-graph` | `docs/` 仅 2 命中，都在 `.coi` 档里作为「不该落盘的临时物」举例（`coi-…:536` / `:680`） |

因此有两条结论：
1 `[实测]` 提案「不新增 macro/template/tactic 语言」的取向与本仓现状一致（本仓本来就没有）；
2 `[实测]` 但它要建立的全部一等对象（`Fragment` / `Decl` / `Relation` / `SemanticEnv` / `Goal` /
`Proof` / `Rewrite` / `Syntax`）今天一个都不存在，且 `E`/`S`/`D` 三个维度没有数据源（见第 8.1 节 1）。

### 8.1 八项逐项表（同一张四栏表）

检查范围同第 5.0 节（分母 = `[实测]` 自编译冷启 41.3 s，其中分析面 ≈30.0 s，且已经超线性）。

| # | 项 | 编译期成本 | 膨胀风险 | 缓解手段（代价） | 判定 |
|---|---|---|---|---|---|
| 1 | `Fragment⟨Γ,T,E,S,D⟩` 表示与推导（五个维度全自动） | `[推理]` ×1.5–×3：Γ（自由绑定）与 T 可在前端线性面推导；但 E 的数据源 `func_ispure` 今天是「生成期乐观默认值」（`checker.cr:4526-4531` 逐字：「`fi_set_ispure(..., 1)`（乐观默认）有意保留」），真纯度只在 `df_state_finalize` 之后可得；S（stage）与 D（semantic domain）的数据源 = Target Model / `.coi`，两者 `[实测]` 零实现（第 8.5 节） | `[推理]` 高：Γ 要求「片段携带自己的语义上下文」，上下文本身要成为图的一部分，而 `[实测]` 片段当前唯一的边界是函数（第 3.5 节表） | 只推 Γ/T，E/S/D 退化为保守默认。代价：E 一旦退化，第八项（effect-aware staging）的整个卖点消失，而该稿自己说 E「不是装饰」 | 不可行（E/S/D 无数据源；且这是设计级缺失，不是工程量） |
| 2 | 反射三层（syntax / elaborated / semantic） | syntax 层 = 前端面，`[实测]` 前端是线性的（第 2.3 节第 1 条），×1.1–1.3；elaborated 层约等于今天的 `@typeInfo` 面（×1.0）；semantic 层 = 全程序查询，见第 8.3 节 | `[推理]` 低（查询不复制代码） | 只做 syntax + elaborated 两层。代价：semantic 层正是该稿自评「Core 最容易形成辨识度的地方」，砍掉它等于砍掉提案的核心 | 半可行：syntax/elaborated 有条件可行；semantic 层见第 8.3 节 |
| 3 | semantic pattern matching（`for` 与 `map` 进 HDFG 同构即同时匹配） | `[推理]` 无法给出可用量级：一般形的「语义结构匹配」= 子图同构，最坏 NP-hard（子图同构的经典结果）。本仓规模 `[实测]` 169,418 节点 / 156,217 边 / 7,638 区段 | `[推理]` 低 | 限制 pattern 形状（只允许线性、树形、带根可达的 pattern）。代价：限形之后「`for` 与 `map` 同构」这类非线性匹配目标恰好落在被限掉的那一类 | 不可行（一般形是子图同构；限形则削掉该稿自己举的核心例子） |
| 4 | `Rewrite<T> = (before, after, obligations)`：元程序无最终决定权 | 生成成本低；验证成本 = 义务交给 checker / CIC / SMT，见第 8.4 节 | `[推理]` 中（before+after 两份图） | — | 不可行，卡在未实现的前置（第 8.4 节） |
| 5 | `Goal<P>` / `Proof<P>`（复用既有 spec/CIC/SMT，不造 tactic 语言） | 与 4 同源，见第 8.4 节 | — | — | 不可行，卡在未实现的前置（第 8.4 节） |
| 6 | equality saturation（egg 方向 Core 化） | `[推理]` 经典的高增长来源：饱和 = 在带等价类的图上跑不动点，e-graph 节点数没有先验上界；且它与第 5.4 节的 PE/BTA 落在同一条已超线性的分析面上，见第 8.3 节 | `[推理]` 极高（本项最著名的问题） | 迭代上限、e-graph 节点上限、只跑用户点名的规则。代价：触顶后的语义是什么？本仓禁止不报错地降级，因此必须硬错（新错误类） | 不可行 |
| 7 | 阶段不止 compile/runtime（含 target-bind / load / JIT） | `[推理]` 每多一个 stage 约等于一次完整编译：`[实测]` 一次自编译冷启 41.27 s、三 stage 全链 98.0 s | `[推理]` 高 | 无 | 不可行（数量级冲突；且 `[实测]` target-bind/load/JIT 在本仓零实现，见第 8.5 节） |
| 8 | `E`（effects）进 `Fragment` 类型 | 同 1（E 无真值源） | — | — | 不可行（前置 = `fi_ispure` 真值化，本仓自述该时序未解决、只被绕开） |

### 8.2 新评估对象：`Fragment<T>` 的表示与推导

这是 team-lead 指定的新评估对象，也是该提案的核心。判定 = 不可行（当前），卡在表示面而非速度面。

该稿的要求（`metaprog-model-raw.md:65-83` 逐字）：`Fragment<T>` = 「已经类型化、已经解析 binding、
已经建立 semantic identity 的 HDFG 子图。不是字符串，也不是裸 AST。」

与 `.cir` / `.ccr` / V8 的关系 `[实测 + 推理]`：

| 面 | `[实测]` 事实 | `[推理]` 判断 |
|---|---|---|
| `.cir`（函数快照缓存） | 粒度 = 函数（`save_cir_cache(path, source_fi, ir_fi)`，三个取界全来自函数级数组 `cir_cache.cr:291-294/308`）；`:225-226` 逐字「The function SG is recreated by `df_begin_func` on a cache hit, so only nested records are stored」 | `.cir` 已经实现了 `Fragment` 想要的约 80%，但只对「整函数形状」成立。缺的 8 项见第 3.5 节表 |
| `.ccr`（存在格实现方式） | `CCR_VERSION = 9` / 8 段（`ccr_io.cr:135/138`）；NOD 40 B，`item` 槽 = 类型项索引，`[实测]` 覆盖率 36.09% | 表示面够，语义面不够：`Fragment<T>` 的 `<T>` 要落在项表上，而项表全文 23 行 / 61 项 |
| V8（team-lead 特别问的那条） | `docs/maintainer/design/ccr-v8-open-relational-lattice.md:5-6` 逐字「状态 = 设计定稿（未实现）· 第二版（v2）」；`:112-115`「V8 几乎全是 `[提案]`」；`:288`「CCR 再成为第四门完整语言是非常糟糕的工程选择。」 | 答案是「相反」，而且比「相反」更弱：1 V8 是提案（不可作为可用前置）；2 它的取向是收窄 `.ccr` 的语义职责（`:288`），而 `Fragment<T>` 要的是扩展；3 team-lead 转述的「有限的关系理论呈现」该字符串在仓库中不存在，最接近的是 v1 的「有限的关系理论描述」（`:67`），且 `:338` 的裁定是删除该承诺（此后唯一合法写法 = 「`.ccr` 本身有限，但 relation universe 是开放的」）。因此拿 V8 当 `Fragment` 的表示依据，方向是反的。 |

`[推理]` 结论：`Fragment<T>` 最省的前身不是 V8，是 `.cir` 快照。把函数边界抽象成
任意 `(node_start, node_count)`，并接受 var 域不可平移（片段只能用于同一次编译内的重排）。
这条不需要节点身份、不需要类型项跨进程，检查可以复用 v20/v21 的既有结构。
但它给不出该稿要的「携带 Γ/E/S/D 的开放代码」。

### 8.3 2（全程序查询）与 6（equality saturation）的成本量级 `[推理]`

2 semantic 层 / whole-program query：

- `[实测]` 本仓已有一次同类的实际错误：`.cir` 快照曾把全程序边表随每个函数落盘，
  `cir_cache.cr:406-410` 逐字：「实测 4,314 万条边记录 vs 20.6 万节点记录」「它正是本条
  二次膨胀的起点」。修法（v20）= 收窄到本函数。
- `[实测]` 今天规模：6,238 串、156,217 边、169,418 节点、7,638 区段、15,244 调用点。
- `[推理]` 无索引时每次查询 O(全图)；N 次查询 O(N × 全图)。量级 = ×1.5–×3，
  且要为索引付一次全图遍历（又一次落在第 2.3 节的超线性面上）。
- 注：`[实测]` 另一个关键细节：查询要的语义事实大部分存在，但有一半是假的。
  `fi_ispure` 是「生成期乐观默认值」（`checker.cr:4526-4531`），`item` 覆盖只有 36.09%。
  拿它做查询会导致不报错地缺格，而本仓对不报错地零容忍。

6 equality saturation：

- `[推理]` 饱和 = 在带等价类的图上跑不动点；e-graph 大小没有先验上界（这是该技术最著名的
  性质，也是 egg 论文自己承认的工程约束）。本仓基数：`[实测]` 15,244 个调用点、
  40.8% 是结构性节点、14.3% 是 lazy thunk/force。
- `[推理]` 即使每次重写只新增 1 个等价类，收敛也要一遍全图迭代，与第 5.4 节的 PE/BTA 是
  同一条已超线性面上的不动点。分母不是 41 s，是那 30 s × 迭代数。
- 缓解的代价：设节点/迭代上限，触顶后的语义必须是硬错；而 equality saturation 的
  价值恰恰来自跑到收敛。限制上限就是削掉该方法的核心。

### 8.4 45 的前置：CIC + SMT 现状（二次实核）

team-lead 要求本次再核一遍。本次核对了两轮，并另请一份独立检索复核，三处一致：

| 检索（`[实测]`，本轮二次执行） | 结果 |
|---|---|
| `grep -rnwE 'smt\|z3\|cvc5\|veriT' src/ bootstrap/ tools/ grammar/` | 0 命中 |
| `grep -rnwE 'CIC\|cic' src/ bootstrap/` | 0 命中 |
| `grep -rn 'src/kernel\|kernel/' src/ci/run.sh build_selfhost_native.py src/compiler/*.cr` | 0 命中（零引用） |
| `ls src/kernel/` | 9 个 `.cr`（`nbe.cr` 13,205 B、`term_io.cr` 11,898 B、`kernel_main.cr` 7,897 B …）= 1287 行真代码 |
| `ls build/` | 只有 corec / corearch / corelsp，没有 `build/kernel`（从未构建） |

旁证（两份仓库自有文档，逐字）：

- `docs/maintainer/adr/adr-0009-spec-system-v2.md:4` `- 状态:accepted(设计定稿,未实现)`；`:18`
  `- 负面:全链未实现(解析/翻译桥/SMT 通道/内核绑定);CIC 内核选择挂起(Rocq vs Lean 4,等社区)`
- `docs/superpowers/specs/2026-08-28-lsp-production-design.md:76` 表格行
  `| 验证管线（翻译桥/CIC，0 实现） | spec-aware LSP 依赖 | P2，随主线 |`
- 注：另加两条该稿与 team-lead 转述都未提的事实（本次核到）：
  1 `coq/fmt_int.v` 是用外部 Coq 验证 stdlib 函数（`Theorem roundtrip`），
     `docs/coq/README.md:6` 自明「这不是规约系统」，因此它不构成 CIC 通道的任何实现；
  2 `src/kernel/` 那 1287 行是 McTT 移植的 MLTT 内核，
     `docs/superpowers/specs/2026-08-15-mctt-core-kernel-design.md:42` 逐字
     「没有 Σ、没有 Id、没有 W-类型；唯一归纳方案是 ℕ + natrec」，因此是 MLTT 的 Π+ℕ 片段，不是 CIC；
     且最新评估 `plans/2026-09-20-safety-verification-plan.md:193` 对它零提及，直接写
     「（`spec-design.md:526-532`）五阶段目标全部未启动」。

因此 45 的判定（按 team-lead 要求明写）：

> 不可行，卡在未实现的前置。
> 「不可行」的理由不是「难」，是：45 的全部机制就是把 `Rewrite` 的 obligations 交给
> CIC / SMT / translation validator 去验证（该稿 `:118-126` 自述「由 Core 的正常 checker /
> CIC / SMT / translation validator 检查」）。而这三者在本仓的现状是
> CIC = 0 实现、SMT = 0 实现、translation validator 不存在。
> 因此 45 今天不是「实现一个功能」，是「实现之后再去实现它的验证器」。

### 8.5 78 与 `.ccr` / Target Model / `.coi` 三层：核实结论是三层不成立

该稿 `:164` 逐字自称：「这样 staging 与既有的 CCR / Target Model / COI 分层完全一致」。
team-lead 要求核「是否真的一致」。核实结论：该前提不成立，逐条如下。

(a) 仓库里没有这个「三层」。`[实测]` 全仓没有任何一句话把
`.ccr`(target-independent) / Target Model / `.coi`(target-specific) 并列成三层。
仓库真实的「三层映射链」是另一条：

- `docs/z-vision.md:17` 记录了三层映射链（2026-08-27 正式晋升）：范式、图、格、编码
- `docs/project-book.md:111` 记录了三层映射（2026-08-27 正式晋升）：语义、图、格、编码
- `docs/glossary.md` `## 二、三层映射`（表体列图(HDFG) / 格(层) / 编码(层)）

因此提案把一条链（图、格、编码）与一份 2026-09-23 的口述管线图混为一谈。

(b) 三层里只有一层是真的。`[实测]`：

| 层 | 设计文档 | 源码 | 判定 |
|---|---|---|---|
| `.ccr` | 有权威（`specs/2026-09-09-lattice-ir-v7-format.md`） | `ccr_io.cr` 完整实现（v9 / 8 段 / 版本检查 / 段号检查） | 真实存在，已实现 |
| Target Model | 不是仓库术语，只在维护者口述原文的管线图里出现一次框名（`coi-…:197`），被同档 `:224` 标 `[已设计未实现]`；仓库自有最近物 = `execution-mapping-design.md` 第 3.8 节 `PerformanceProfile`（`:3` 状态行「设计定稿（未实现）」） | 零（无任何 `.cr` 符号） | 仅提案，零实现 |
| `.coi` | `docs/maintainer/design/coi-optimization-knowledge-sidecar.md:4` 逐字「状态 = 设计定稿（未实现）」；同档 `:77-80` 自设 `K-3` 条：「`.coi` 在本仓零对应物」 | `[实测]` `grep -rIl coi src/ tools/ tests/` = 0 命中 | 不存在，纯提案 |

(c) 78 赖以立论的两句话，与仓库现状的关系：

| 提案的规则 | `[实测]` 核实 |
|---|---|
| 「target-bound metaprogram 不允许回写 target-independent 的 CCR semantics」 | 仓库里没有等价表述：`target_bind` / `target-bind` / `target bound` 全仓 0 命中。最接近的是同族但不同物的一条：`specs/2026-09-09-lattice-encoding-boundary-design.md:175-176` 逐字「事件流与表数据 = 编码层事务（x86 实例的投影内容），不入格形态段。格形态携带语义对象，不携带任何目标机的投影中间物」。主体是「实例数据/编码层事务」，不是「target-bound metaprogram」。 |
| 「`.ccr` 仍然只保存 target-independent program relations」 | 该定性在本仓没有权威出处：全仓 `target-independent` 仅 3 处命中，全在 `.coi` 档转述维护者口述原文的引文块内（`:144` / `:150` / `:1463`）。仓库自有的定性恰好相反：`lattice-encoding-boundary-design.md:21` 逐字「`.ccr 局部不纯`」，`:96-99` 点名 123 三类经典机泄漏（含 3「tag/2L 相关 op 与帧 tag 语义在 op/类型码面」= x86 编码选择），`:128-131` 列 P1–P4 不纯点。 |

(d) `[实测]` 一条该稿与转述都没提、且方向更微妙的事实：`.ccr` 格式里已经有一个
target-specific 载荷槽。

- 键定义：`src/compiler/ast.cr:660` `OPT_KEY_REG_ASSIGN : int = 0;  // [var_idx:u32, reg_num:u8]...`
- 写侧：`src/arch/x86_64/regalloc.cr`（`g_opt_meta` 写点；`meta_reg_pair_off` 读回）
- 落盘：`src/compiler/ccr_io.cr:749-750`（SYM 段末 `opt_meta` 子节，`:59` 布局 `[opt_count][opt_count×{key,len,data}]`）
- 读侧：`src/compiler/corearch.cr:190`
- 但是 `[实测]` 今天发出的文件里它是空的：同一源文件 `-O 0` 与 `-O 2` 的 `.ccr`
  逐字节相同（3,245,935 B / `cmp` 无差异）；且 `[实测]` corearch 从不回写 `.ccr`
  （`grep save_ccr|write_file src/compiler/corearch.cr` = 0 命中）。
  因此与仓库注释「regalloc 移后端（2026-09-07）…`.ccr` 不表示分配结果」（`main.cr:650`）一致。

> 8.5 的净结论：提案的规则方向（不把 target 绑定回写 target-independent 层）与仓库原则
> 大体同向（`lattice-encoding-boundary-design.md:175-176` 是它的同族先例）；但
> 1 它用来立论的「既有三层」不存在；2 `.ccr` 的「target-independent」定性没有仓库权威出处，
> 而格式里留着一个 target-specific 槽（当前恰好为空）。
> 因此「完全一致」这个自评不成立，必须重述为：「与仓库的『编码层事务不入格形态段』原则同向，
> 但该原则今天靠的是没人写，而不是格式禁止写。」

### 8.6 78 的 stage 现状 `[实测]`

| 概念 | 现状 |
|---|---|
| 编译 stage 链（stage0/1/2/3） | 真实存在且是实现级检查（`src/ci/run.sh:351`「Three-stage frontend bootstrap. corec2 and corec3 must be byte-identical.」） |
| 元编程意义的 staging | `[实测]` `src/` 里 `staging` 0 命中；`stage` 一词的 12 处命中全部指自举链 |
| `target-bind` | 全仓 0 命中 |
| `load time` | `load time` / `load-time` 全仓 0 命中；`加载时/装载时` 仅 2 处且非机制 |
| `link time` | 真实存在，但指链接期重定位/地址回填（`ast.cr:601` `IR_FNADDR … link-time patch`），与元编程无关 |
| JIT | 0 实现（5 处命中全是安全设计文档里的举例） |
| `src/stdlib/hotpatch.cr` | 不是 load-time 机制：它是 `SIGHUP` 触发的运行期配置热重载（`:11-17` `hp_load_config` 重读 `.hotpatch.toml`）+ in-flight 计数 |

---

## 九、总判定（team-lead 指定的单独一句）

> 问题：这八项里，哪几项现在就能做、哪几项卡在未实现的前置、哪几项在自举约束下代价不可接受？

### 9.1 现在就能做：0 项

`[实测]` 八项共同的最小前置，即「编译期元对象」这一层的表示，在本仓一个都不存在
（第 8.0 节：`Fragment`/`Decl`/`Goal`/`Proof`/`Rewrite` 在 `src/`+`grammar/` 全 0 命中；
`grammar/core.ebnf` 67 条产生式里零元编程面）。
`[推理]` 因此八项里没有任何一项可以在不先建这一层的前提下开工。

与第 6.1 节的关系：第 6.1 节的 T0–T4 是前三块的前置小切片（且 T0/T1/T2/T3 不需要元对象层），
它们仍然成立、仍然可以立即开工，但它们不构成本节八项的任何一项。

### 9.2 卡在未实现的前置：5 项

| 项 | 前置 | 前置的现状 `[实测]` |
|---|---|---|
| 1 `Fragment⟨Γ,T,E,S,D⟩` | E 的真值源 | `fi_ispure` = 「生成期乐观默认值」（`checker.cr:4526-4531`），本仓自述该时序未解决、只被绕开 |
| 1（续） | S / D 的真值源 | Target Model = 非仓库术语、零实现；`.coi` = 零对应物（第 8.5 节） |
| 4 `Rewrite<T>` | CIC / SMT / translation validator | 三者皆 0 实现（第 8.4 节，两轮实核） |
| 5 `Goal<P>`/`Proof<P>` | 同上 | 同上 |
| 8 E 进类型 | 同 1 的 E | 同上 |

### 9.3 在自举约束下代价不可接受：3 项

| 项 | 卡住它的约束 |
|---|---|
| 3 semantic pattern matching | 问题本身是子图同构（NP-hard 一般形），不是自举约束，是问题本身的复杂度；限形则削掉提案自己举的核心例子（`for` 与 `map` 同构） |
| 6 equality saturation | 编译速度：不动点 + e-graph 无先验上界，落在第 2.3 节的已超线性面上；`[实测]` 该面已占自编译 72.7% |
| 7 多 stage（target-bind / load / JIT） | 编译速度：每 stage 约等于一次完整编译（`[实测]` 41.27 s 冷）；且 `[实测]` 该三项在本仓零实现 |

### 9.4 八项之外，但必须先做的一件事 `[推理]`

> 八项里有 6 项（13678 + 45 的验证面）的位置都在同一个面上：对整张 HDFG 做
> 全程序、不动点或同构级分析。而 `[实测]` 那个面今天已经是自编译成本的 72.7%，且已经超线性。
> 因此无论最终做哪几项，第 6.4 节的 S0（把 `pa_in_unsafe`/`is_in_unsafe` 改 O(1)）都是前置中的前置。

---

## 十、更正清单（对前文的补充）

接第 7.3 节，本轮新增三条：

| 说法 | 出处 | `[实测]` 核实 |
|---|---|---|
| 「staging 与既有的 CCR / Target Model / COI 分层完全一致」 | 第四块讨论稿 `:164` | 不成立：「三层」在本仓不存在；真实的三层是范式、图、格、编码（`z-vision.md:17`）。三层里只有 `.ccr` 是真的（Target Model 非仓库术语、`.coi` 零对应物）。见第 8.5 节 |
| 「`.ccr` 仍然只保存 target-independent program relations」 | 第四块讨论稿 `:148` | 该定性无仓库权威出处：全仓 `target-independent` 仅 3 处，全在转述口述原文的引文块里。仓库自有定性相反 = 「`.ccr 局部不纯`」（`lattice-encoding-boundary-design.md:21`），且格式里留着 target-specific 槽 `opt_meta`/`OPT_KEY_REG_ASSIGN`（`[实测]` 当前为空）。见第 8.5(d) 节 |
| 该稿自述读了 `docs/comptime.md` / `docs/at-intrinsics.md` / `docs/spec-design.md` | 第四块讨论稿 `:4` | 前两条路径不在该位置（实际 = `docs/maintainer/proposals/comptime.md` / `docs/developer/at-intrinsics.md`）；且它读的 `main` 不是 `develop` 当前点。本档现状断言一律以重核为准 |

---

## 十一、未能核实清单（本轮补充）

接第 7.1 节。本轮新增：

| # | 未核实项 | 为什么 | 影响 |
|---|---|---|---|
| 11 | `opt_meta` 在「最重」的构建路径上是否真为空 | 本次只测了 `-O 0` vs `-O 2`（同源、`ccr` 子命令）逐字节同，未逐 opt-level × 全 build 路径穷举。 | 第 8.5(d) 节的「当前为空」是实测于该条件，不可外推为「任何条件下恒空」。 |
| 12 | `fi_ispure` 乐观默认值的实际误导率 | 未跑探针量化「有多少函数的纯度被误标为 1」。 | 第 8.1 节 1/8 的「E 无真值源」是结构性断言（源码头注自承），未量化后果。 |
| 13 | semantic pattern matching 的可判定子类边界 | 未做文献调研（本档不对论文内容做判断）。 | 第 9.3 节 3 的「子图同构导致 NP-hard 一般形」是复杂度常识推理，不是对本仓某个具体 pattern 语言的实测。 |
| 14 | `.coi` 的两份文档是否已被维护者采纳为方向 | 超出本次的核实范围（本次只核它们的内容与状态行）。 | 第 8.5 节只断言「`.coi` 零实现」，未断言「该方向不应做」。 |
| 15 | 第 8.1 节的八栏成本量级 | 与第五节同性质：全部是 `[推理]`，无一项是本轮新跑的数字。分母沿用第二节的实测基线。 | 八项的 ×N 只作量级用。 |

本轮 `[实测]` 的新增项（供复核）：第 8.0 节的元编程面 grep 表、第 8.4 节的两轮 CIC/SMT 实核（含 `ls src/kernel/` 与 `ls build/`）、
第 8.5 节的 `.coi` 零命中与三层链原文、第 8.5(d) 节的 `OPT_KEY_REG_ASSIGN` 四处接入 + `-O 0` vs `-O 2` 的 `.ccr` 逐字节相同、
第 8.6 节的 stage/load-time/JIT/hotpatch 检索表。
本轮 `[推理]`：第 8.1 节全表、第 8.3 节、第九节全节。

---

## 十二、附录：复现命令

```bash
# 环境
cd /home/DslsDZC/core && jj git fetch
jj workspace add ../core-ctfeas-ws --name ctfeas-ws --revision develop@origin
cd ../core-ctfeas-ws

# 2.1 基线（记得 nice -n 19；硬性规则 6）
nice -n 19 python3 build_selfhost_native.py

# 2.2 full-bootstrap（路径偏离 CI 的固定 /tmp/corec2|c3，防多代理互覆）
nice -n 19 ./build/corec build src/compiler/main.cr -o /tmp/ctfeas/corec2 --static -O 0
cp ./build/corearch /tmp/ctfeas/corearch
nice -n 19 /tmp/ctfeas/corec2 build src/compiler/main.cr -o /tmp/ctfeas/corec3 --static -O 0
cmp /tmp/ctfeas/corec2 /tmp/ctfeas/corec3

# 2.3 规模曲线（clean-cache 是必须的，否则暖态污染读数）
rm -rf .core/cache && nice -n 19 ./build/corec ccr <FILE> -o /tmp/o.ccr

# 3.1/3.2 现状探针（未折 = 图上仍是 const+binary / const+call）
./build/corec cir <FILE.cr>          # 看 main 的 region
./build/corec check <FILE.cr>        # 看 @comptime 是否报错

# 8.0 元编程面现状（全部应为 0 命中）
grep -rIl -e macro -e splice -e egraph -e 'equality saturation' src/ grammar/
grep -in 'macro\|hygien\|quote' grammar/core.ebnf

# 8.4 CIC/SMT 二次实核（应全为空）
grep -rnwE 'smt|z3|cvc5|veriT' src/ bootstrap/ tools/ grammar/
grep -rnwE 'CIC|cic' src/ bootstrap/
grep -rn 'src/kernel' src/ci/run.sh build_selfhost_native.py src/compiler/*.cr
ls src/kernel/                       # 9 个 .cr；ls build/ 应只有 corec/corearch/corelsp

# 8.5(a) 真实的"三层"是范式到图到格到编码（不是 .ccr/Target Model/.coi）
sed -n '17p' docs/z-vision.md ; sed -n '111p' docs/project-book.md ; sed -n '15,19p' docs/glossary.md

# 8.5(d) .ccr 的 target-specific 槽当前为空（两产物应逐字节相同）
rm -rf .core/cache && nice -n 19 ./build/corec ccr <FILE.cr> -o /tmp/o0.ccr -O 0
rm -rf .core/cache && nice -n 19 ./build/corec ccr <FILE.cr> -o /tmp/o2.ccr -O 2
cmp /tmp/o0.ccr /tmp/o2.ccr
grep -n 'save_ccr\|write_file' src/compiler/corearch.cr   # 应 0 命中 = corearch 不回写

# 8.6 stage / load-time / JIT / hotpatch 检索
grep -rnw stage src/ ; grep -rn 'load.time' docs/ src/ ; grep -rn 'target.bind' docs/ src/
sed -n '1,17p' src/stdlib/hotpatch.cr   # = SIGHUP 运行期配置重载，非 load-time
```

工件位置（本次评估的现场证据，不在仓库内）：
`/tmp/ctfeas/build1.log`（第 2.1 节时间戳日志）、`/tmp/ctfeas/fullboot.log`（第 2.2 节）、
`/tmp/ctfeas/bench.json`（第 2.3 节）、`/tmp/ctfeas/self.ccr`（第 2.4 节的 12.7 MB `.ccr`）、
`/tmp/ctfeas/scale/`（合成语料 + 产物）、`/tmp/ctfeas/attrib.json`（per-file token 归属）。
