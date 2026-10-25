# match 的决策树编译与统一分支节点

> **v10 实现说明（2026-10-24）**：现行 `.ccr` 是 v10，不是本文写作时的 v9.1。
> 多路分支在 v10 中使用 `IR_MATCH`（opcode 54）+ CASE 24B 记录
> `{value, kind, str_index, target_nod, flags}`；`if`（含作为表达式返回值）、
> `while`、`for`、`&&`/`||` 及内部条件分派都已走同一节点（`VALUE(0)` +
> `DEFAULT`，true 走 fallthrough）。`ir_gen` 默认不再发射 `IR_BRANCH`；
> 该 opcode 仅为历史 `.ccr`/合成 fixture 兼容保留。本文的 v9.1 版本/段表/16B CASE 段落是历史设计，已被
> `docs/superpowers/specs/2026-10-23-lattice-ccr-v10-design.md` §11 取代。
> 已实现范围：int/bool/enum/string/char/struct/tuple/ident 模式、二分与密集
> 跳转表、CIR CASE 区间持久化。下文保留历史决策与推导。

## 概述

`match` 目前在 `src/compiler/ir_gen.cr:2683` 起按 arm 顺序展开为 `IR_CONST`、`IR_BINARY`、`IR_BRANCH` 组成的比较链，corec 的 IR 中只有二元条件分支。字符串、字符、结构体、标识符模式在 `ir_gen` 中没有测试或绑定生成，会静默执行第一个 arm。

本文定义完整版：把 `IR_BRANCH` 从二元条件分支替换为多路决策节点，`if` 是 case 数为 2 的特例，`match` 在 corec 编译成 Maranget 决策树，corearch 只做机器映射。`.ccr` 升到 v9.1，新增 CASE 段。

设计状态：已定，决定见文末“决定”一节。

## 核心决定

1. 一种分支节点。`IR_BRANCH` 的新形式是 scrutinee、case 表、default 三部分。二元 `if` 是 case 数为 2 的特例，`IR_JUMP` 是无条件跳转的紧凑编码。
2. 替换，不并存。旧的 `s1=cond, s2=true, s3=false` 编码退役，所有生成点和消费点改用新形式。不新增 `IR_SWITCH`、`IR_TEST` 或第二种控制流。
3. 决策树在 corec。`match` 使用 Maranget 的模式矩阵算法生成决策树。测试归一化为整数比较、字段投影和 `str_eq` 调用。corearch 不感知模式种类。
4. 机器映射在 corearch。case 数为 2 时发 `cmp/jcc`，密集 case 发跳转表，稀疏 case 发二分。阈值和布局只在 corearch。
5. `.ccr` v9.1。主版本保持 9，header 的 reserved 字段改作 revision，写 1。CASE 段作为 tag 9 追加在 IFACE 之后，存 `int value -> label`。NOD 的 `IR_BRANCH` 存 default label、case 起点和 case 数量。v9.0 文件不再读取。
6. 语义覆盖。string、char、struct、tuple、ident 模式必须有测试或绑定，不能静默命中。
7. HDFG 参与。值域剪枝、纯度 body 共享、region 热度分阶段接入，不改变控制流形状。

## 现状

### IR 形状

| 位置 | 现状 |
|---|---|
| `src/compiler/ast.cr:611` | `IR_BRANCH : int = 19`，操作数为 `s1=cond, s2=true_label, s3=false_label` |
| `src/compiler/ir_gen.cr:2683` | `EXPR_MATCH` 的 IR 生成入口 |
| `src/compiler/ir_gen.cr:2769` | 每个 int arm 生成 `IR_CONST`、`IR_BINARY(OP_EQ)`、`IR_BRANCH` |
| `src/arch/x86_64/instr.cr:1529` | `IR_BRANCH` 发射 `test`、`je`、`jmp`，二元分支各一条跳转 |
| `src/compiler/ccr_io.cr:112` | `CCR_VERSION = 9`，NOD 记录 40 字节；header 的 reserved 字段当前写 0 |
| `src/compiler/dataflow.cr:337` | HDFG 只把 `IR_BRANCH` 的条件变量记为数据依赖 |
| `src/arch/x86_64/regalloc.cr:526` | 活跃性分析按 `s2`、`s3` 两个 label 收集后继 |
| `src/compiler/cir_cache.cr` | 函数级缓存保存 `op/dest/s1/s2/s3/tk`，不保存 case 表 |

实测 IR：4 路整数 `match` 生成 4 组 `const pval`、`binary cmp`、`branch`，每组两个跳转。64 路 `match` 是 64 组顺序比较。corearch 没有多路分支可以映射成跳转表。

### 模式覆盖

`src/compiler/parser.cr:1410` 的 `parse_pattern` 支持下列模式。`ir_gen` 的 `EXPR_MATCH` 只处理前四项。

| 模式 | parser | ir_gen | 当前结果 |
|---|---|---|---|
| wildcard `_` | 支持 | 支持 | 默认分支 |
| int 字面量 | 支持 | 支持 | 逐 arm 比较 |
| bool 字面量 | 支持 | 支持 | 逐 arm 比较 |
| enum 变体 | 支持 | 支持 | 读 tag 后比较 |
| string 字面量 | 支持 | 没有测试 | 静默执行第一个 arm |
| char 字面量 | 支持 | 没有测试 | 静默执行第一个 arm |
| struct 模式 | 支持 | 没有测试 | 静默执行第一个 arm；checker 不校验字段存在性，也不把字段子模式的 ident 加入作用域 |
| tuple 模式 | `grammar/core.ebnf` 有定义，`parse_pattern` 没有 `(` 分支 | 没有测试 | 语法错误 |
| ident 绑定 | 支持 | 没有绑定 | 变量不可用 |

char 的运行期值当前是字符驻留字符串的索引。实测 `'A' as int` 得到 14，不是 65。`EXPR_CHAR.int_val` 存的也是驻留索引。char 模式直接比较 `ast_int_val` 与运行期值一致；把 char 全局改成码点是独立的语言变更，不在本文范围。

### HDFG

`src/compiler/dataflow.cr` 构造 HDFG：每个 IR 节点是 `DFNode`，数据边是 def-use，state 边表示顺序和终止依赖，region 嵌套用 `SG_IF`、`SG_LOOP`、`SG_FOR`、`SG_FLOW`、`SG_UNSAFE` 表示。现有分析包括：

- `compute_all_purity`：函数和指令级的纯度。
- `ptr_analysis.cr`：过程间 Andersen 式 points-to，调用结果保守。
- `region_check.cr`：DEREF 目标必须在活 region 内。
- `provenance_verify.cr`：DEREF 偏移必须在 allocation size 内。
- type engine：枚举和 optional 的穷尽性判定。

这些信息可以在 match 编译时使用，但当前 `ir_gen` 没有读取。

## 设计

### 统一分支节点

`IR_BRANCH` 改成多路决策节点。字段含义：

| 字段 | 含义 |
|---|---|
| `dest` | default label；`-1` 表示没有 default，运行到未命中时 trap |
| `s1` | scrutinee 变量 |
| `s2` | CASE 段的起始索引 |
| `s3` | case 数量 |
| `type_kind` | 比较宽度，保留现有含义 |

CASE 记录：

| 字段 | 含义 |
|---|---|
| `value` | int 值、枚举 tag、bool 值或字符驻留索引 |
| `target` | 命中后的目标 label |

约束：

- CASE 记录只存整数值。字符串、结构体和 tuple 模式在 corec 归一化，不进入 CASE 段。
- `if` 编码为一个 case `{1 -> then}` 加 `dest=else`。corearch 对 `s3 == 1` 且 `value == 1` 发射 `test`、`jne`，与现有 `IR_BRANCH` 的机器码相同。
- `while` 的条件分支使用相同编码，回边由 `IR_JUMP` 表示。
- `IR_JUMP` 保留，表示无条件跳转。语义上它是没有 case、只有一个 default 的决策节点，编码上继续使用 `s1=label`。
- `IR_LABEL` 保留，表示基本块入口。
- 旧的 `IR_BRANCH` 二元编码不再生成。

### corec 决策树

输入是 match arms 的 pattern 矩阵。第一列选择按 Maranget 的规则：选第一个包含 refutable pattern 的列。对单列标量模式，corec 生成一个 `s3=N` 的多路 `IR_BRANCH`，只对 case 值排序和去重，不拆成二叉。二分和跳转表都由 corearch 决定。对嵌套模式，corec 递归生成多个 `IR_BRANCH` 和字段投影。

测试归一化：

| 模式 | 归一化 | 使用的现有指令 |
|---|---|---|
| int、bool、char | 整数值 | `IR_CONST`、`IR_BRANCH` |
| enum | `IR_LOAD_ENUM_TAG` 后按 tag 分派 | `IR_LOAD_ENUM_TAG`、`IR_BRANCH` |
| optional | 先按表示位（裸值或装箱）分派，再按 tag 或值分派 | 现有表示位指令、`IR_BRANCH` |
| struct、tuple | `IR_LOAD_FIELD` 后对子值测试 | `IR_LOAD_FIELD`、`IR_BRANCH` |
| string | `IR_CALL str_eq` 返回 0 或 1，再按结果分派 | `IR_CALL`、`IR_BRANCH` |
| ident | irrefutable，绑定 scrutinee 或子值 | `IR_STORE` 或直接绑定 |
| wildcard | default 分支 | `IR_BRANCH` 的 `dest` |

optional 的处理有现成逻辑：`ir_gen.cr:2737` 起在枚举 tag 分派前判断裸值和装箱，裸 optional 不是指针，直接读 tag 会出错。完整版把表示位纳入 Maranget 的列模型，见“决定”第 2 条。第一版保留现有 optional 特例链，其他模式走决策树。

字符串模式的完整版策略：

1. 先按字符串长度分组，生成长度 `IR_BRANCH`。
2. 同一长度内按首字节分组，生成首字节 `IR_BRANCH`。
3. 组内逐条调用 `str_eq`，按返回值生成二路 `IR_BRANCH`。
4. 没有命中的路径走 default。

分组只减少 `str_eq` 调用次数，不改变语义。第一版可以只做逐条 `str_eq`，分组作为后续优化。

列选择启发式：

- case 值排序后生成一个多路节点。corearch 的二分实现负责平衡。
- Scott 和 Ramsey 的实验结论是，多数程序上不同启发式生成的树大小相同；机器生成的程序可能差 2 到 20 倍。corec 第一版采用排序加去重，不实现 necessity 启发式。
- arm 数量小于 4 时保留顺序比较，避免多路节点的管理开销。

重复值：

- 同一个 case 值出现多次时，保留第一个 arm，后续 arm 是冗余。checker 对枚举和 optional 已经报 `EC_TM_REDUNDANT`；字面量冗余检查在完整版补齐。
- test 本身没有副作用，case 的测试顺序不影响语义。

body 共享：

- `compute_all_purity` 在 `df_state_finalize` 里运行，晚于 match 的 IR 生成。生成期不能直接读取被调函数的纯度。
- 完整版在纯度计算之后增加一次延迟重定向：两个 arm 的 body 是相同 AST，且纯度判定为纯时，把两个 case 的 target 指向同一个 label。
- 第一版不做 body 共享。阶段 5 实现延迟重定向，并保证绑定环境一致。

值域剪枝：

- scrutinee 的 producer 是常量、`load8`、bool 比较或 `IR_LOAD_ENUM_TAG` 时，记录可能值集合。
- case 值与可能值集合不相交时，不生成该 case。
- 值域分析只做函数内、沿 HDFG 数据边回溯。跨过程和 points-to 不在完整版第一轮。

### corearch 映射

corearch 只看 `IR_BRANCH` 的 case 数量和 value 分布，不看模式种类。

| 条件 | 映射 |
|---|---|
| `s3 == 1` 且 `value == 1` | `test/jne`，与现有二元分支同码 |
| `s3 == 2` 且 default 只有一个 | `cmp/jcc` |
| `s3 > 2` 且 value 密集 | 跳转表 |
| `s3 > 2` 且 value 稀疏 | 二分比较树 |
| `s3 == 0` 且 `dest >= 0` | 无条件跳转 |
| `dest == -1` 且没有 case 命中 | trap 或 `ud2` |

密集的初始判据：`s3 >= 8` 且 `max(value) - min(value) + 1 <= 2 * s3`。阈值在 benchmark 后调整。

跳转表布局：

- 表项是 32 位相对偏移，放在 rodata。
- 目标地址等于表项地址加偏移。静态 ELF 下不需要绝对地址重定位。
- 表前先做范围检查；value 在 `[min, max]` 外时跳 default。
- 表的标签地址由现有 label patch 机制解析。

字符串模式不进入 corearch 的多路映射。corec 已经把它归一化成 `str_eq` 调用和二路 `IR_BRANCH`，corearch 只处理整数。

### .ccr v9.1

版本和段表：

- `CCR_VERSION` 保持 9。header 的 reserved 字段改作 revision，写 1。
- 段表从 8 项增加到 9 项。现有 tag 1 到 8 保持不变，CASE 作为 tag 9 追加在 IFACE 之后。
- NOD 记录仍为 40 字节。`IR_BRANCH` 的 `dest` 存 default label，`s2` 存 CASE 起始索引，`s3` 存 case 数量。
- CASE 记录为 16 字节：`value` 为 8 字节有符号整数，`target` 为 4 字节 label，保留 4 字节对齐。

加载校验：

- 版本等于 9 且 revision 等于 1，段表为 9 项。
- `first_case + case_count` 不超过 CASE 段项数。
- 每个 `target` 和 `dest` 都在函数的 label 范围内。
- case 数量为 0 时允许，表示只有 default。
- v9.0 文件（revision 为 0、段表为 8 项）不再读取。缓存目录需要清理一次。

### 语义

- 首个匹配。重复 case 值保留第一个 arm。
- case 测试按决策树顺序执行；测试没有副作用，body 只在命中时执行。
- 绑定在目标基本块内建立。enum payload、struct 字段和 ident 绑定使用现有 `bind_local` 或 `IR_LOAD_FIELD`。
- 字面量 match 要求 `_` 或 irrefutable arm；缺少时 checker 报 `EC_TM_EXHAUST`，见“决定”第 4 条。
- `dest` 为 `-1` 且没有 case 命中时，运行到 trap。该形态只在 checker 放行的程序中出现。
- 字符串比较使用 `str_eq`。空字符串和嵌入 NUL 按现有 string 语义处理。
- 枚举和 optional 的穷尽性沿用 checker 现有判定。字面量、字符串、char、struct 的穷尽性在完整版补齐。

### HDFG 接入

| 信息 | 用途 | 阶段 |
|---|---|---|
| 常量、`load8`、bool、enum tag 的值域 | 删除不可达 case，缩小跳转表范围 | 决策树落地后 |
| `compute_all_purity` | 合并相同 body | 纯度计算后的延迟 pass |
| `SG_LOOP`、`SG_FOR` | 给 corearch 热路径提示，优先跳转表 | 跳转表落地后 |
| points-to 和跨过程摘要 | 推断函数返回值的可能集合 | 后续 |
| provenance | 不直接参与 match 编译 | 不在本次范围 |

HDFG 的 region 信息已经写入 `.ccr` 的 REG 段，corearch 可以直接读取，不需要为热度新增字段。

## 约束

1. bootstrap desugar 前置。`bootstrap/corec/frontend/desugar.py` 的 `_desugar_match` 当前只支持 Wildcard 和 EnumPattern，其他模式抛 `NotImplementedError`。corec 源码一旦在 `match` 里使用 int、char、string、struct 模式，`build_selfhost_native.py` 的 stage 1 就会失败。实施前必须扩展 bootstrap desugar，覆盖 corec 源码实际用到的模式，或限制 corec 源码只使用 Wildcard 和 EnumPattern。
2. 编译器源码禁用 `|`、`&` 和 `as`。决策树生成代码也遵守这条限制。
3. 自举要求 stage 2 和 stage 3 逐字节相同。stage 1 由 Python bootstrap 构建，可以和新决策树代码不同。
4. 所有长编译和测试使用 `nice -n 19` 或 `cpulimit -l 10`。
5. `cir_cache.cr` 必须同步。函数级缓存的记录只有 `op/dest/s1/s2/s3/tk`，不包含 CASE 表。含多路 `IR_BRANCH` 的函数如果命中缓存，恢复后 case 索引会指向空表或别的函数的表。阶段 1 必须扩展缓存记录，保存每个函数的 CASE 区间，或对含多路分支的函数禁用缓存。

## 实施清单

阶段 1 和阶段 2 必须同批落地。阶段 1 单独切换 `.ccr` 和 corearch 时，`ir_gen` 还在发旧编码，`if` 和 `loop` 会被新后端误读，中间状态不能构建。

| 阶段 | 文件 | 改动 | 验收 |
|---|---|---|---|
| 0 | `tools/baseline/`、`tests/` | 记录 if、loop、match 的机器码和基准 | 基准可重复 |
| 1+2 | `src/compiler/ast.cr`、`globals.cr`、`ccr_io.cr` | 新 `IR_BRANCH` 字段、CASE 段、v9.1 读写 | 手工构造的 v9.1 文件可读写；v9.0 被拒绝 |
| 1+2 | `src/compiler/cir_cache.cr` | 保存 CASE 区间，或禁用含多路分支的函数缓存 | warm build 不 miscompile |
| 1+2 | `src/compiler/ir_gen.cr` | `match` 生成多路节点；if、while、`&&`、`||` 改用新编码 | 现有 suite 和 probes 通过 |
| 1+2 | `src/compiler/dataflow.cr`、`dump.cr`、`interp.cr` | 多 successor、case 表打印、解释执行 | 解释执行结果与现有 match 相同 |
| 1+2 | `src/arch/x86_64/regalloc.cr`、`sizes.cr`、`instr.cr` | 多 successor 活跃性、case 表读取、二路映射 | if/loop 机器码与阶段 0 相同 |
| 3 | `src/arch/x86_64/instr.cr`、`sizes.cr` | 密集 case 跳转表、稀疏 case 二分 | 64 路基准达到目标 |
| 4 | `src/compiler/ir_gen.cr`、`parser.cr`、`checker.cr` | string、char、struct、tuple、ident 模式；字面量穷尽性；struct 字段校验和 ident 绑定 | 覆盖用例不再静默命中；无 `_` 的字面量 match 报 `EC_TM_EXHAUST` |
| 4 | `bootstrap/corec/frontend/desugar.py` | 扩展模式支持，保持两前端语义 | bootstrap-tests 通过 |
| 5 | `src/compiler/checker.cr`、`ir_gen.cr` | HDFG 值域剪枝、纯度 body 共享、optional 表示位纳入决策树、热度提示 | 基准和诊断用例通过 |

## 测试与验收

1. 行为对拍：`tests/suite`、`tests/probes`、`tests/selfhost` 全部通过。
2. 自举：`build_selfhost_native.py` 完成三阶段构建，stage 2 和 stage 3 的 `cmp` 结果为 IDENTICAL。
3. `./build/corec check src/compiler` 返回 0，`error[` 计数为 0。
4. if、loop、`&&`、`||` 的机器码和阶段 0 逐字节相同，确认二路特化没有回归。
5. 16 路和 64 路整数 `match` 的基准不低于现有 if 链。64 路由 corearch 的二分实现达到约 6 次比较，corec 只生成一个多路节点。
6. 合成字符分派基准：0 到 255 的字符值与 40 个 case 的分派，不低于现有线性链；密集 case 在跳转表落地后应明显低于线性链。`src/compiler/lexer.cr` 的改写是后续独立任务，不在本文实施范围。
7. 编译时间和峰值内存不显著增加。决策树生成的复杂度为 O(n log n)，case 表大小与 arm 数线性相关。
8. canary：ELF 和 `.ccr` 基准值会变化，更新 `tools/baseline/canary_values.tsv` 并在同一批记录原因。
9. 语义覆盖：无 `_` 的 int/char/string match 报 `EC_TM_EXHAUST`；optional 裸值和装箱两种形态的结果与现有实现一致；char 的 match 值与当前 `'A' as int` 一致。

## 不包含

1. guard、range pattern、or-pattern。Core 当前没有这些语法。
2. profile-guided 分支排序。
3. 跨过程值域分析和函数摘要。
4. 新的后端或外部链接器。
5. match 语法变更。
6. v9.0 兼容读取。
7. 字符串 pattern 的插值语义。字符串 pattern 只支持无插值的字面量；带插值的 pattern 报诊断。
8. `src/compiler/lexer.cr` 的 match 改写。它是后续独立任务。
9. char 改成 Unicode 码点。它是独立语言变更，不在本文范围。

## 决定

1. char 运行期值。match 第一版直接比较当前 char 值，即字符驻留字符串的索引，不改变 char 语义。char 改成 Unicode 码点作为独立语言变更另行实施。依据是 Rust `char` 和 Haskell `Char` 都使用码点，驻留索引属于编译器内部表示。影响范围包括 lexer、parser、`as int`、ABI 和缓存，不在本文范围。
2. optional 表示位。完整版把表示位纳入 Maranget 的列模型，作为“表示”伪列；第一版保留现有裸值和装箱特例链。依据是 Rust 的 niche optimization 在 MIR 里仍按 enum 处理，Maranget 的列模型可以扩展表示列。影响阶段 5 和 optional 测试。
3. tuple 和 struct 模式。完整版补 parser 的 tuple 模式，补 checker 的 struct 字段存在性校验和 ident 绑定。依据是 Rust、Haskell、OCaml 和 SML 都把 tuple 与 struct 模式当作一等模式。影响阶段 4，文件包括 `parser.cr` 和 `checker.cr`。
4. 字面量穷尽性。要求 `_` 或 irrefutable arm；缺少时 checker 报 `EC_TM_EXHAUST`。依据是 Rust 报 non-exhaustive patterns，Haskell 和 OCaml 也要求穷尽，Maranget 的 usefulness 算法把整数和字符串视为无限域。影响 checker，现有 match 需要扫一遍。
5. 跳转表阈值。初始判据是 `s3 >= 8` 且 `max-min+1 <= 2*s3`，之后用 benchmark 调整。依据是 LLVM 的 switch lowering 按 case 密度在跳转表、位测试和二分之间选择。影响 corearch。
6. 跳转表重定位。表项使用 32 位相对偏移，目标是静态 ELF；不支持 PIE 和动态链接。依据是 LLVM 的 PIC 跳转表普遍使用相对偏移。影响 corearch。
7. bootstrap desugar 范围。覆盖 corec 源码实际使用的模式，不追求覆盖 parser 支持的全部模式。依据是 stage 0 只需要支持 bootstrap 源码。影响 bootstrap；lexer 重写前必须覆盖 int 和 char。
8. `IR_JUMP`。保留，作为没有 case 的紧凑编码；语义上仍是统一决策节点的特例。依据是 LLVM 和 MIR 都保留无条件跳转 terminator。影响阶段 1 的改动面。
9. `IR_DYN_DISPATCH`。不并入统一分支节点，保留独立。依据是 dyn 分派属于运行时类型的 vtable 语义，和静态 case 表不同；Rust 的 dyn Trait 也不走 switch。影响后续。
