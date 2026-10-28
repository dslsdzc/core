# 视图内建（2a）实施记录

> 对应计划：[plans/2026-09-18-view-builtins-2a.md](../plans/2026-09-18-view-builtins-2a.md)

## 概述

本记录覆盖 2a 视图内建的机制实施、迁移和检查，包括 bootstrap 面和自托管面。结论是 `@` 视图内建已经实现，`unsafe` 在 bootstrap 面从零支持补到可用，`src/stdlib/cli.cr`、`src/compiler/interp.cr`、`src/compiler/parser.cr` 的 68 个点迁移到 0，`tests/selfhost/test_view_builtins.py` 的 15 项全部通过，两条突变都命中目标。返回位覆盖缺口和 `unsafe` 块分号陷阱已经登记为 `#2026-09-18-19(A)` 和 `#2026-09-18-19(B)`。

## 改动

### 机制实施（A 加安全面 (ii)）

bootstrap 面位于 `bootstrap/corec/`。`ast.py` 新增 `Builtin`。`parser.py` 在表达式位对 `@` 做三形态分流，形态是 `@name(args)`、`@name`、`@project file::symbol`，按紧随 token 判断。`type_checker.py` 新增 `_infer_builtin`，处理未知名 fail-closed、实参类型和 unsafe 区块检查，并新增 `Unsafe` 分支和 `unsafe_depth`。

bootstrap 此前对 `unsafe` 零支持。实测旧行为是：checker 报 `Unsupported expression`，ir_gen 报 `NotImplementedError`。自源去掉注释和字符串后，`unsafe` 行数为 0，因此从未触发。`ir_gen.py` 有两处直通。

自托管面：`checker.cr` 的 EXPR_AT 链增加两条检查。`g_unsafe_depth == 0` 时报 N01 硬错。实参类型不符时报 TF07。`ir_gen.cr` 做真直通，代码是 `return force_if_thunk(gen_expr(arg))`，零指令，零新变量。

没有采用 `@raw_int` 的「新建变量加 IR_STORE」方案。原因有两个。第一，那是在 dex 和 int 之间转换，XMM 与 GP 是两条不同的机器路径。第二，int 和 string 都是同一个 GP 字，搬运只会多一条 IR_STORE 并破坏可擦除性。实测该版本检查 ② 失败。

### 迁移结果（68 变为 0）

| 档 | 点数 | 修法 |
|---|---|---|
| `src/stdlib/cli.cr` | 29 | 注册 `@ptr_of`，读取 `@str_of`，`_cli_find_flag` 比较 `@str_of`。另修 2 处返回位，即 `cli_get` 和 `cli_arg`，清单不收，见覆盖面发现一节。 |
| `src/compiler/interp.cr` | 30 | 地址字当缓冲时用 `@str_of(ptr)`。`alloc` 结果即 string 当字存时用 `@ptr_of(bp)`。 |
| `src/compiler/parser.cr` | 9 | 名字表存 `tok_lx`，用 `@ptr_of`。读回 `str_intern(r64(...))`，用 `@str_of`。 |

`CORE_S1P=1 corec check src/compiler/main.cr` 的结果是 68 变为 0，bool 桶保持 0。

旁证来自 bootstrap 面的 oracle：构建期 `Checker warnings (non-fatal)` 从 330 变为 165，本次视图点逐条消失。

### 覆盖面发现

S1P 插模拟覆盖的是直调和方调用的实参，返回位不在覆盖内。`cli_get` 和 `cli_arg` 声明 `-> string`，却执行 `return r64(...)`，68 点清单从未收录。本次一并修复。因此 S3 升硬错之前必须补返回位，否则同类点仍然不报错。

### 检查与证据

`tests/selfhost/test_view_builtins.py` 已经接入 `selfhost-tests`，15 项全部通过。检查内容包括：① 两面一致，比较 check、解释器、native、bootstrap 四个读数；② 擦除逐字节，覆盖 int 和 string 两对；③ 未知名两面 fail-closed；④ unsafe 块外两面硬错；⑤ 实参类型两面拒绝；⑥ cli e2e，使用 `tests/suite/cli_view_test.cr`，覆盖注册到帮助的逐子串检查和查询面，补上 `cli.cr` 今日零覆盖的检查集合。

突变自证有两条，均断言命中目标。① 回退 `_cli_find_flag` 的首个视图点，清单从 0 变为 2，`str_len` 和 `str_eq` 复现。② 移除 `checker.cr` 的 unsafe 守卫，块外探针的 `check` 由 rc=1 变为 rc=0，检查④必然失败。

全量层包括 canary 5/5、selftest 双档逐字节、五个 job，见 PR 描述。

## 验收结果

### 迁移读数

`CORE_S1P=1 corec check src/compiler/main.cr` 的结果是 68 变为 0，bool 桶保持 0。

bootstrap 面构建期 `Checker warnings (non-fatal)` 从 330 变为 165。

### 关键实测

1. 擦除成立。`@ptr_of(@str_of(p))` 与直写 `p` 的 ELF 逐字节一致，int 和 string 两对都成立。注意对照必须同处 unsafe 包络，因为 `unsafe` 本身带 +158B `.ccr` 区域元数据，跨包络对照测的是 `unsafe`，不是视图。
2. `unsafe` 零成本，限视图场景。后端仅当块内有分配时才发 `arena_new`，位置是 `arch/x86_64/instr.cr:1042` 的 `s1 > 0` 分支。视图块没有 alloc，因此不产生任何运行期动作。
3. 两面一致。同一探针的值是 42，既不是有效指针，也不是有效 intern 索引。该探针在 corec `check`、解释器、native 与 bootstrap 管线、解释器五处读数一致。
4. 解释器对裸内存是近似，属于预存问题，不是本次引入。`alloc` 加 `w64` 或 `r64` 的程序在解释器侧检查不产出或给 0。迁移前后同为 166B，cli e2e 同源对比也一致，因此与该分歧无关。
5. 块内分号陷阱。本次损害检查一次，已经修复。`unsafe { x; }` 块值为 unit，因此 `return unsafe { x; };` 使该路径返回 unit。bootstrap 面仅给出非致命警告，解释器仍按值运行。self-hosted 面报 `TF01` 硬错。两面诊断面分歧，已经登记 `#2026-09-18-19(B)`。

### 测试和突变

`tests/selfhost/test_view_builtins.py` 的 15 项全部通过。覆盖两面一致、擦除逐字节、未知名 fail-closed、unsafe 块外硬错、实参类型拒绝和 cli e2e。

两条突变均命中目标。回退 `_cli_find_flag` 首个视图点后，清单从 0 变为 2。移除 `checker.cr` 的 unsafe 守卫后，块外探针 `check` 由 rc=1 变为 rc=0，检查④失败。

### 全量层

canary 5/5。selftest 双档逐字节。五个 job 的结果见 PR 描述。

## 遗留问题

1. `#2026-09-18-19(A)` 返回位覆盖缺口。S1P 插模拟覆盖直调和方调用的实参，不覆盖返回位。`cli_get` 和 `cli_arg` 声明 `-> string`，却执行 `return r64(...)`，68 点清单从未收录。本次已经修复这两处，但覆盖机制本身仍然缺返回位。S3 升硬错之前必须补返回位，否则同类点仍然不报错。
2. `#2026-09-18-19(B)` `unsafe` 块分号陷阱。`unsafe { x; }` 的块值为 unit，因此 `return unsafe { x; };` 使该路径返回 unit。bootstrap 面仅给出非致命警告，解释器仍按值运行；self-hosted 面报 `TF01` 硬错。两面诊断面分歧，尚未统一。
3. 解释器对裸内存是近似，属于预存问题。`alloc` 加 `w64` 或 `r64` 的程序在解释器侧检查不产出或给 0。迁移前后同为 166B，与本次视图内建无关，但仍是解释器能力边界。
4. `cli.cr` 此前零覆盖。本次通过 `tests/suite/cli_view_test.cr` 补上注册到帮助的逐子串检查和查询面，但覆盖范围仍限于该测试文件列出的行为。

## 不包含

本记录只覆盖视图内建 2a，也就是 A 加安全面 (ii)。

本次不包含 S3 硬错。

本次不包含返回位的覆盖机制。`cli_get` 和 `cli_arg` 两处已经修复，但 S1P 插模拟本身仍然不覆盖返回位。

本次不包含 `unsafe` 块分号陷阱的修复。该事项只登记为 `#2026-09-18-19(B)`。

本次不包含解释器裸内存近似的修复。该事项是预存问题，不是本次引入。

本次不包含 `@raw_int` 的「新建变量加 IR_STORE」方案。该方案已经被排除。
