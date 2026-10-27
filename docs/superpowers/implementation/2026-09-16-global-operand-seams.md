# 全局行操作数 seam 统一处理（同族六点）实施记录

> 对应计划：[plans/2026-09-16-global-operand-seams.md](../plans/2026-09-16-global-operand-seams.md)

## 概述

记录覆盖 2026-09-16 的全局行操作数 seam 同族六点处理，包括 T1 的 RED 实测、T2 的 `g2_slot` 全点枚举和写侧初判、T3 的指令迁移、T4 的检查套件，以及 T5 的构建和复验。实际位置为 B1、B2、B4、B5 四点，全部由 mut 全局探针、局部对照和 int 全局对照三重隔离实证。B6(b) 只能检查到发射字节。B6(c) 实测为方法调用的 apx 形式转换缺失，定性为 N-3，不属于本次的全局寻址面。T5 全部检查通过，包括 12/12 探针、五个 CI job rc=0、73 档同源对比零差异。本次还修复了一处自伤缺陷：三个辅助函数漏发 REX.B，导致 B1 和 B2 的全局形从不报错地错值变为 SIGSEGV 139。

## 改动

### T2 `g2_slot` 枚举

T2 是零构建部分，日期 2026-09-16。裁决门已写进文档。T1 因构建槽位被占，先做运行时探针，标“待实证”的条目由 T1 实测确认。

`g2_slot` 全点机械枚举共 56 处，使用 `awk` 按最近的 `if op == IR_*` 归属，文件为 `instr.cr`。

助手函数 5 处：`:55` 定义本体，`:387` 和 `:389` 为 `e2_store_ret` 的 dex 和 int 两支，`:442` 为 `e2_load_var` 局部支，`:456` 为未使用代码 `sz_load_var`。

`emit_instr` 分支 45 处，按 opcode 列出：

- `IR_I2F` 467 和 468。
- `IR_F2I` 475 和 476。
- `IR_CONST` 484。
- `IR_BINARY` 517、520、521。
- `IR_UNARY` 669。
- `IR_CALL` 的 goroutine_wrapper_addr 内置体 815。
- `IR_CALL_EXTERN` 840。
- `IR_HOTPATCH_ROUTE` 861。
- `IR_SPAWN` 873。
- `IR_FNADDR` 908。
- `IR_ALLOC_STRUCT` 936。
- `IR_ALLOC_ARRAY` 956。
- `IR_ARENA_NEW` 976。
- `IR_LOAD` 1018。
- `IR_STORE` 1046，s1 侧，已分派。
- `IR_LOAD_FIELD` 1071 和 1075，已分派。
- `IR_REF` 1096、1099、1110，d 侧未分派。
- `IR_DEREF` 1117。
- `IR_ADDR_INDEX` 1133。
- `IR_LOAD_ENUM_TAG` 1231，死变量。
- `IR_LOAD_INDEX` 1247。
- `IR_LOAD_INDEX_VAR` 1283。
- `IR_MAKE_ENUM` 1320。
- `IR_SLICE` 1334。
- `IR_AWAIT` 1345 和 1346。
- `IR_LAZY_THUNK` 1402。
- `IR_LAZY_FORCE` 1407。
- `IR_YIELD` 1419 和 1420。
- `IR_DYN_PACK` 1428。
- `IR_DYN_TAG` 1437 和 1438。
- `IR_DYN_VAL` 1446 和 1447。
- `IR_DYN_DISPATCH` 1456、1457、1565。

`hit_ev_emit_one` 6 处：1817、1852、1860、1880、1883、1891，属于表实例面。

分类约定：逐条给出直接消费者（`e2_ld`、`e2_st`、`e2_sd_*`、`hit_st_modrm_disp` 等），判断该槽位能否为全局行，并给出依据 `file:line`。本表是坐标出处，分类列在 T1 后回填。T1 的 RED 结果是“能否为全局”的实证来源。

### T2 写侧 d 域初判

全局 var 索引的唯一来源是 `find_global`（`ir_gen.cr:579-587`）和 `global_var_of`（`:3055-3063`）。

`find_global` 实核调用点 3 处：`:524` 表示面分类，只读；`:1116` `EXPR_IDENT` 读值，转为操作数；`:1364` 赋值目标，转为 `emit(IR_STORE, -1, gv, val_var, 0, 0)`，dest 为 -1，全局只作 s1。

`global_var_of` 唯一调用点 `:3074` 改为 `emit(IR_STORE, -1, gv, v, 0, 0)`，用于全局初值注入，同为 s1。

因此前端从不把全局索引传给任何 `emit` 的 dest。一切全局写都是 `IR_STORE` 的 s1，该分支已分派，位置为 `instr.cr:1048-1056`。写侧 d 域包括 `IR_REF` dst、`IR_ALLOC_STRUCT`、`IR_FNADDR`、`IR_MAKE_ENUM`、`e2_store_ret` 的 387 和 389、`IR_SPAWN`、`IR_HOTPATCH_ROUTE`、`IR_LAZY_*` dst、`IR_DYN_*` dst，初判无实际位置。依据为 emit dest 恒为 `new_ir_var` 产物，例如 `IR_CALL` 的 `dest := new_ir_var("call", call_ti)` 位于 `:1925`。

残余风险：若任何前端路径把全局索引传给 dest，该点即错。例如 `IR_REF` 的 d 侧 1110 把 `&g` 存入全局指针槽。裁-SEAM-1 定为只清点不修，因此 T1 用全局指针槽探针实测复核，结果回填本表。

### T2 B6 可达性修正

实参块只在非连续时才打包进连续 `_arg` 临时。`first_arg_var = arg_vars[0]`，逐对检查 `cur == prev + 1`。全连续时 `need_pack = 0`，不打包，全局实参直达后端。打包支在 `need_pack != 0` 时逐个执行 `emit(IR_STORE, -1, packed, av)`，只搬值，不换形式，`at := irv_type(av)` 原样。

`ac == 1` 恒不打包。单实参调用的全局实参直达 `cs_args_dispatch`，因此 B6(b) 的 extern 单参形在寻址面可达，探针按此形设计。

多实参且索引连续同样不打包，例如相继注册的全局 `g1` 和 `g2`，因此全局实参直达。

方法调用 `s.m(g)` 的 `ac >= 2`，因为接收者加实参。`ir_gen.cr:1779-1786` 显式前置 `self_var`，已实读。接收者是局部或临时，其索引与全局索引几乎必然不连续，因此 `need_pack` 触发，实参被打包进 `_arg`，寻址缺陷被掩蔽。B6(c) 的寻址面可达性因此大幅收窄，仅“接收者恰为 `g+1`”的偶合形仍可达，须 T1 实证。

第二个根因是转换环缺失，不被掩蔽。打包只搬值、不换形式，因此方法调用里的 apx 实参仍以 bits 交付，而 callee 形参侧按 `TI_DEX_S` 解释，位置为 `ir_gen.cr:2866`，所以不报错地值错。该问题与寻址无关，任何方法调用都可触发。

对裁-SEAM-3 的直接影响：按 T2 初判，B6(c) 的 RED 三选一中“明确 139”不出现，“不报错地错值”出现。按加硬规则，同阶段修转换环。

探针设计修正：B6(b) 使用单实参 extern，恒不打包，作为寻址面检查。B6(c) 使用方法调用，作为值面检查。报告显式注明寻址面被 `need_pack` 掩蔽。

### T2 转换环改动面

环本体位于 `ir_gen.cr:1810-1841`。启用该修法不是简单删除 `ast_kind(func_node) == EXPR_IDENT`。

`func_ni` 对方法调用可用，`:1777` 由 checker 写 `ast_data(node)`，因此 `find_func` 可解析。

实参和形参的位置错开一格。`arg_vars[0]` 是接收者，位置 `:1783`，被调方的 `EXPR_PARAM` 链不含 self。因此环内“arg i 对应 param i”必须对方法调用改为“arg i 对应 param i-1”，须引入 `is_method` 位。

环只对 `ast_type_val(cpn) == TI_DEX` 的形参动作，因此非 dex 形参零影响。

初判改动面为单函数约 10 至 15 行，加一个 `is_method` 位。该范围未超预算，因此不触发“停下报 lead”规则。前置条件为 T1 实测确认现象（不报错地或明确），以及 `find_func(func_ni)` 对方法调用可用性的实测。

### 提交链

- T1：`ab17f428` 初稿，`7151b90c` 决定性 RED。四点 RED 全达标，即 B1、B2、B4、B5，均使用 mut 形三重隔离。
- T2：`4d786e00`。`g2_slot` 全点 56 处枚举，写侧 d 域结构性初判，B6 `need_pack` 掩蔽修正，转换环改动面评估。
- 裁决和登记：`6cac7df3`。裁-SEAM-3 证伪与改判留痕，TODO #2026-09-16-12 和 #75，dex 和 apx 节两条补注 N-2 和 N-4。
- T3：`619827c6`。`instr.cr` 新增 `e2_lea_glob`、`e2_is_glob`、`e2_sd_ld_var`、`e2_sd_cvt_var`、`e2_sd_st_var`、`e2_st_var`。迁移 B1（585、586 和 593 dest）、B2（532 和 533 dest）、B4（1398-1403）、B5（1411-1416）、B6（`callseq.cr:75` 和 `:129`）、B7（`cs_ret_value` 全局支按型分派）、B8（1886、1921、1952）。删除未使用代码 `sz_ofs` 和 `sz_load_var`，以及死变量 `o1`。
- T4：`9df6b835`。新增 `tests/selfhost/test_global_seams.py` 12 例，其中 B6(b) 为发射字节级；新增 `tests/suite/global_seam_test.cr`；接入 `src/ci/run.sh`。
- T5：构建和检查复验。构建使用 `nice -n 19`，构建前实查无本仓 corec 进程。

### T5 构建与自伤修复

构建命令为 `nice -n 19 python3 build_selfhost_native.py`，rc=0，产出 corec、corearch、corelsp 三件。构建槽位在开运行前用 `ps` 实查，无本仓 corec 进程。当时 CPU 占用者是用户自己的 Qt 和 CMake 构建。全程单构建串行，共 3 次构建：首建、REX.B 修复重建、两次 `/tmp` 突变构建，均逐个排队。

自伤缺陷：`e2_sd_ld_var`、`e2_sd_cvt_var`、`e2_sd_st_var` 的 `movsd` 和 `cvt [r11]` 漏发 REX.B，实际寻址 `[rbx]`。B1 和 B2 的全局形因此从不报错地错值变为 SIGSEGV 139。int 写侧的 `e2_st_var` 未犯该错，按 `IR_STORE` 先例带了 `emit_rex`。修复为三处补 `0x41`，cvt 形补 `0x49`，提交为 `b1792681`。

B6(b) 原检查把 `4c8d1d` 与 `f20f1003` 逐片段独立 find，缺少 REX.B 的坏序列照样通过。该弱检查放过了上述自伤缺陷。收紧为连续序列正则，失败消息按文本渲染。`\xNN` 由正则引擎解释，`.hex()` 会 dump 文本，误导排查。

新增 suite 语料使分支①的计数断言硬失败，因此显式把 72 改为 73。`tools/baseline/parity_run.sh` 的注写明“语料数变化为硬失败，须显式改本文件”，`src/ci/run.sh` 注释同步。

## 验收结果

### T1 RED 实测

基线二进制为 `/tmp/p7t3/build/corec` 和 `corearch`，构建时刻 03:23。`diff -rq` 实核 `src/` 与当前树逐 `.cr` 文件一致，仅 `src/ci/run.sh` 和构建产物不同，因此等价于当前树的二进制。探针为微秒级运行，不占构建槽位。工作目录为仓库根，避免 `/tmp` 的 import 解析陷阱。`ulimit -c 0`，避免 systemd-coredump 暂停。

分支①为 `corec run`。分支②为 `build --static` 加运行产物。决定性形为 mut 全局，依据 N-4。

| 点 | 探针，决定性形 | interp rc | ELF rc | 判定 |
|---|---|---|---|---|
| B1 | `g : dex, apx, mut = ±100.0` 改为 `if g > 0.0` | 1/7 | 7/7 | RED 是。ELF 符号不随初值变化。同形 int 全局对照 1/1 正确，局部形 ELF 1 正确。mut 形排除常量折叠，因此读面坏。 |
| B2 | `h : dex, mut = -100.0` 为全局，改为 `d : dex, apx = h`，再 `if d > 0.0` | 255 | 7 | RED 是，最干净。同源仅 h 位置不同。h 为全局时 ELF 7 错，h 为局部时 ELF 1 对。 |
| B4 | `g : [int;4] = [10,20,30,40]; lo : int = 1; s := g[lo..3]; return s[0];` | 20 | 71 | RED 是。期望 20。局部对照 20/20。注：数组不参与折叠，s1 为真全局读。`lo` 不可变，被折叠成常量，所以本例实际只测到 s1。 |
| B5 | `g : int, mut = 5; g = 9; x := await g; return x;` | 9 | 26 | RED 是。mut 形是关键。早先 `g : int = 5` 形“未复现”，因为不可变 int 全局被常量折叠，读点根本不碰全局行，探针未触达。 |
| B6(a) | `dbl(g)`，裸标识符调 Core 函数，apx 全局 | 7 | 7 | 未复现，与审计“已排除”一致。 |
| B6(b) | `seam_ext(g)`，单实参 extern，加对照 `seam_ext(1.5)`，无全局 | 2/2 | 139/139 | 139 非判别。对照无全局实参同样为 139，因此 extern 在静态构建下调用未解析符号必崩，没有 `.so`。B6(b) 检查只能到发射字节。裁-SEAM-2 原判正确，U6 修正。 |
| B6(c) | `s.m(g)`，不可变 apx 全局和 mut apx 全局 | 7/1 | 7/1 | 不可变形未触达，被折叠。mut 形双路径同错，1/1，期望 7。因此不是本次 seam 特征，本次特征是 ELF-only 分歧。登记 N-3，形式转换缺失，取裁见“对 T3 范围的影响”。 |
| B7 | `ret_g()` 返回 int 全局 | 5 | 5 | 非回归是。B7 全局支不可达。同族 `-> dex` 返回路径的可达形态归 apx 阶段，见“实际位置清单”B7 行的跨阶段更新。 |

RED 检查达成情况：计划要求至少 B1、B2、B4、B5，四项全部达标，且均为 mut 全局形、局部对照、int 全局对照三重隔离。B6(b) 降级为字节检查，U6 修正。B6(c) 转为 N-3，属于形式转换缺失而非寻址面，须 lead 重新取裁。

### T1 附加发现

- N-1：`s.m(…, lx)` 把局部 apx 量作第 9 个 binary64 栈参，interp 1，ELF 1，双路径同错，期望 7。因此不是全局寻址面缺陷，而是 dex 形式转换在栈参位。双路径同错说明是独立缺陷，登记。
- N-2：多条 dex 转换探针出现 interp rc=255，全局和局部同现，属于解释器侧既有行为，不是本次的判别子。T4 用例须以“全局与局部同形对比”为主要检查，避免被 interp 既有偏差污染。
- N-3：方法调用的 apx 实参不做从 bits 到 scaled 的形式转换。环门 `ir_gen.cr:1810` 以 `EXPR_IDENT` 为门，因此 `EXPR_FIELD` 方法调用整段跳过，双路径同错。证据链有三条。① `s.m(apx_mut_global)` 的 interp 1、ELF 1，期望 7。② 局部对照 `s.m(lx)`，`lx : dex, apx, mut` 为局部，同样 interp 1、ELF 1，因此与全局行无关。双路径同错说明是前端形式转换缺失，不是寻址面。③ 直调对照 `dbl(g)`，g 为 apx mut 全局，ELF 1。此例的错值可归因 B1 seam，因为环内 `dex_bits_to_scaled` 发 `IR_BINARY(TI_DEX)`，s1 为全局，正落在 B1 迁移点。
- N-4：探针设计硬约束。`find_global_const_node`（`ir_gen.cr:592-611`）接受 `EXPR_INT`、`EXPR_BOOL`、`EXPR_DEX`，并要求 `ast_data(node) == 0`，即非 mut。因此不可变且字面量初值的全局被折叠成 `IR_CONST`，读点不碰全局行。一切寻址面探针必须使用 mut 全局，否则测不到。该约束必须写入 T4 用例。

### T1 对 T3 范围的影响

确认实际位置为 B1、B2、B4、B5，四项 RED 实证，均为 mut 形三重隔离；加 B6(b)，检查只能到发射字节；加 B8，待表实例实核。

B6(c) 的定性更新为 N-3。证据显示它是方法调用的 apx 形式转换缺失。局部对照同错，因此与全局行无关；双路径同错，因此不是本次“ELF-only 不报错地”类。裁-SEAM-3 的原判前提“B6(c) 属全局 seam 案”已被实测证伪，需 lead 重新取裁：

- (a) 按原裁“不报错地，所以同阶段修”照修转换环。本次范围扩一条，T3 加转换环任务，改动面初判约 10 至 15 行加 `is_method` 位。检查为局部和全局两形方法调用探针，加全套回归。
- (b) 按“非全局面、双路径同错属于另一缺陷类”单列 N-3，交后续阶段。本次只落 seam。本计划推荐 (b)，理由是本次根因单一，即 `g2_slot` 帧外伪偏移和分派散落；N-3 与 `g2_slot` 无关，局部量同样错，并入会污染本次的判别面，T4 用例需区分两类检查。

原裁为“不许留给下一组”，因此本条必须由 lead 明确追认后才算结案。

### T5 检查

全部通过。

| 检查 | 结果 |
|---|---|
| T4 探针套件 12 例 | 12/12。B1、B2、B4、B5 全局形转正，局部对照同值，B6(b) 字节级，B7 非回归。 |
| `tests/suite/global_seam_test.cr` | build rc=0，run rc=0 |
| 快速验证 | 42 |
| ELF canary | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`（28822B）IDENTICAL |
| `.ccr` 两种形式四条 | 逐条 clean-cache 和空缓存状态：96015 `680a6f98…`、96158 `76f36e6a…`、142793 `41e9d845…`、142936 `704316c8…`，全部 IDENTICAL |
| `check src/compiler` | rc=0，0 条 `error[`，自源语料干净 |
| `selftest-types` | 415/415 |
| 五个 CI job | `selfhost-tests`、`suite`、`check`、`bootstrap-tests`、`full-bootstrap` 全部 rc=0 |
| 自举链 | `corec2 == corec3` IDENTICAL（`093ba2305c204fdd…`），N06=0，五个 job 日志零命中，快速验证 42 |
| 分支①同源对比，73 档 | 参考为固定基线 `/tmp/capt6/base/corec` 配当前源，候选为当前二进制配当前源，`diff -rq` 零差异，146 条目，rc 分布 35 档 0 和 38 档 1 |
| 探针 29 档 | `rc.txt` 与 (A) 阶段 post 输出零差异，cold 日志零差异，有缓存状态 `warm.out` 的条目和命中零差异。`warm/` 逐档日志仅临时路径差异，即 `/tmp/warm_leg.*` |

突变控制 ①（全局分支）：Mu1 把 `e2_lea_glob` 补丁位置从 `pos+3` 到 `pos+4`。B1 和 B2 的全局形变红，rc=139。B6(b) 字节检查红。局部对照和 int 面保持绿。canary IDENTICAL。

突变控制 ②（非全局分支）：Mu2 把 `e2_ld` 的 disp8 形 ModRM 从 `rm=5` 改为 `rm=4`。探针 11/12 红，canary 变化，`a7ef9ddf…` 不等于基准值。

### 检查修正

`tools/baseline/parity_run.sh` 的语料计数从 72 改为 73。本次新增 `tests/suite/global_seam_test.cr`，因此 t1 从 32 改为 33。runner 自身注写明“语料数变化为硬失败，须显式改本文件”。`src/ci/run.sh` 注释同步。

## 遗留问题

- B6(c) 定性为 N-3，是方法调用的 apx 形式转换缺失，不属于全局寻址面。T1 阶段需 lead 重新取裁，本次不把它计入修复面。
- B6(b) 只能检查发射字节，不能做运行时检查。静态构建下 extern 调用未解析符号必然 rc=139，对照无全局实参同样如此。
- 写侧 d 域的“无实际位置”是结构性初判。若任何前端路径把全局索引传给 dest，该点即错。裁-SEAM-1 只清点不修。
- B8 的迁移包含在 T3 提交中，T1 阶段的“待表实例实核”没有在 T5 表中单列。
- N-1 的局部 apx 栈参双路径同错是独立缺陷，本次未修。
- N-3 的局部对照同错说明问题与全局行无关，后续批处理。
- N-4 要求所有寻址面探针使用 mut 全局，T4 用例已按此约束设计。
- 自伤缺陷 REX.B 已修，但该缺陷曾让 B1 和 B2 从不报错地错值变为 rc=139。修复提交为 `b1792681`。
- B6(b) 的弱检查已收紧为连续序列正则。`\xNN` 在失败消息中由正则引擎解释，`.hex()` 会误 dump 文本。
- 语料计数已显式从 72 改为 73。后续新增语料须同步 runner 和 `src/ci/run.sh`。

## 不包含

- 未修复 B6(c) 的方法调用 apx 形式转换缺失。该问题定性为 N-3，交后续阶段。
- 未实现裁-SEAM-3 的 (a) 方案。转换环扩面未在本次执行。
- 未对写侧 d 域做修复。裁-SEAM-1 只清点。
- 未对 B6(b) 做运行时检查。只检查发射字节。
- 未修 N-1 的局部 apx 栈参双路径同错。
- 未把 N-3 计入本次的 seam 修复面。
- 未修改非全局寻址路径。Mu2 只作为突变对照。
- 未并发执行构建。全程单构建串行。
- 未不报错地更新语料计数。72 改为 73 是显式修改。
- 未新增第五个语料而不更新 runner 和 `src/ci/run.sh`。
- 未把 B6(c) 的寻址面检查当作有效检查。该面被 `need_pack` 掩蔽。
- 未在 T1 使用源码插模拟。#81 的裁定使用直调和方法调用的行为差分。
