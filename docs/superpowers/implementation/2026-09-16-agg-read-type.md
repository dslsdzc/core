# 聚合读类型丢失第 2 阶段实施记录

> 对应计划：[plans/2026-09-16-agg-read-type.md](../plans/2026-09-16-agg-read-type.md)

## 概述

聚合读类型丢失第 2 阶段修复 TODO #2026-09-16-16。聚合读的结果槽原先硬定为 `TI_INT`，导致按 `dex` 声明读取时发生不报错的错值，并使总检查级连锁无法检测。T1 在 2026-09-16 固定改前基线并完成 8 档探针的改前实测，T2 把探针入仓并记录两条命令层陷阱，T3 在 3 个读点按声明面形式定型并把 `CIR_CACHE_VER` 从 17 改为 18，T5 完成。终态为分支 A 4/5 通过，R4 按裁-AGG-3 登记为 `[GAP]`；分支 B 四条见证通过；分支 C 断言通过；canary 5/5 IDENTICAL；74 档与 29 档探针的 rc 全同；五个 CI job rc=0；自举链恒等；分支 D① 突变通过。

## 改动

### T1：前置、固定基线与探针

维护者裁决（2026-09-16）：八门全按推荐。裁-AGG-1 取 ①；裁-AGG-2、裁-AGG-3、裁-AGG-4 登记；裁-AGG-5 不删 hack，退役检查要求分支 D① 连续两阶段通过；裁-AGG-6 不改 `IR_ALLOC` 的 tk 与 `IR_DYN_PACK` 的 tag；裁-AGG-7 bump `CIR_CACHE_VER` 从 17 到 18，并补齐四要素；裁-AGG-8 固化突变。U4 裁定 extern 边界规范化为 ABI binary64，因此 R6 进入分支 A，期望为转换。

起点为 `develop = 99ae6bdd`，分支为 `feature/agg-read-type`，本记录是该链首个提交。固定基线使用现成的 `build/corec` 与 `build/corearch`。同源证明为：`jj diff --from e7243955 --to develop --stat -- src/compiler src/arch src/os src/format build_selfhost_native.py` 返回 0 files changed。该二进制所建的源面与 `develop 99ae6bdd` 逐字节相同，因此可以作为改前基线。备份的 sha256 为：`/tmp/agg-t1/pre/corec` 是 `a689de9a205a2c1f…`，`/tmp/agg-t1/pre/corearch` 是 `8dd89647971f6af3…`。

命令纪律在本轮踩到并留痕。`corec build` 必须在仓库根运行，否则报 `error: cannot locate src/runtime/rt.cr`。重定向到已存在的日志文件会被 noclobber 拦住，命令根本没有运行，读到的是上一轮的旧日志，表现为假红。本轮首轮的 8/8「失败」就是这个原因。改用 `>|` 和新路径后恢复正常。

探针共 8 档，包括 R1 至 R7 和 N1。源码如下。

```core
// R1 · LET 中转丢型
struct S:
    f: dex
fn main() -> int:
    d : dex, apx = 7.0
    s : ., mut = S { f = d }
    x := s.f
    if x * 2.0 != 14.0:
        return 1
    return 7

// R2 · match 臂载荷绑定
enum E:
    V(dex)
fn main() -> int:
    d : dex, apx = 7.0
    e : ., mut = V(d)
    return match e:
        V(x) =>:
            if x * 2.0 != 14.0:
                return 1
            return 7

// R3 · 局部数组元素读
fn main() -> int:
    d : dex, apx = 7.0
    a : [dex; 2] = [d, 1.0]
    if a[0] * 2.0 != 14.0:
        return 1
    return 7

// R4 · 元组元素读（数字下标无声明面）
fn main() -> int:
    d : dex, apx = 7.0
    t := (d, 1.0)
    if (t . 0) * 2.0 != 14.0:
        return 1
    return 7

// R5 · 聚合读写回 apx（binary64）槽
g : dex, apx, mut = 1.0
struct S:
    f: dex
fn main() -> int:
    d : dex, apx = 7.0
    s : ., mut = S { f = d }
    g = s.f
    if g != 7.0:
        return 1
    return 7

// R6 · extern 实参（判定形态 = IR 断言，见 11.6）
struct S:
    f: dex
extern fn dex_agg_arg_check(d: dex) -> int
fn main() -> int:
    d : dex, apx = 7.0
    s : ., mut = S { f = d }
    r := dex_agg_arg_check(s.f)
    return r

// R7（非回归固定用例）· Core 调用实参
struct S:
    f: dex
fn dbl(x: dex) -> dex:
    return x * 2.0
fn main() -> int:
    d : dex, apx = 7.0
    s : ., mut = S { f = d }
    y := dbl(s.f)
    if y != 14.0:
        return 1
    return 7

// N1（非回归固定用例）· apx 阶段已转正的比较/raw 形
struct S:
    f: dex
fn main() -> int:
    d : dex, apx = 7.0
    s : ., mut = S { f = d }
    if @raw_int(s.f) / 1000000 != 7:
        return 1
    if s.f != 7.0:
        return 2
    return 7
```

两条需要实证的结论在 T1 做了实核。第一条是 tag 面，裁-AGG-1 的 ① 收窄了范围。读槽从不作为 `IR_BINARY ADD/SUB` 的 dest，dest 恒为新槽 `bin` 或 `_dx*`。tag 规则 A（`tag2l.cr:117`）只标 ADD/SUB 的 dest。精确路径的结果槽 `_dxm` 与 `bin` 在改前改后同为 `TI_DEX_S`（`ir_gen.cr:1338` 与 `:1342` 硬编码），因此 R1、R3、R4 预期没有 tag 差异。tag 影响只可能出现在非 dex 聚合读的整数路径，而那条路径被声明面门控，所以预期零 tag 影响。最终以 T3 和 T4 的改前改后对比为准，比较帧尺寸与 `.ccr` 尺寸。

第二条是 regalloc 面，读码已确证，影响待对比。`regalloc.cr:680-681` 对 `TI_DEX_S` 不建候选。读槽当前为 `TI_INT`，因此有资格进入候选。是否真的命中窗口、是否存在 hazard 位，需要 T3 对比。预期影响是该槽从「可能驻寄存器」变为「恒栈驻留」。

归类修正在 T1 实测后确定。R7 从「RED 候选」改为「非回归断言」。读码与实测双证，当前 rc=7，修后必须仍绿。R6 从「运行值」改为「IR 级断言」。extern dex 调用的静态链运行路径存在既有崩溃：`tests/suite/ffi_test.cr:8-11` 的头注说明运行时 FFI 被 corearch `--link` 静态路径的既有崩溃阻塞，该档只声明不调用。实测 `run_rc = 139`。因此照既有先例 `tests/selfhost/test_dex_arith.py::test_extern_dex_arg_cir` 使用 cir 断言判定。本次断言是「`load_field` 与 `call_extern` 之间必须出现转换序列」，改前为空，所以 RED 正据已取，见验收结果中的 IR 证据表。U4 裁后约定 extern 边界规范化为 ABI binary64，`ir_gen.cr:1900-1907` 只做 `TI_DEX_S` 到 bits。因此 R6 的期望是转换，不是「不变」，也不是「转 scaled」。

T1 未决事项有三条，转 T2 与 T3。T1-1 是 R1 至 R7 的入仓形态，包括 py 套件内联源、允许清单登记和接入点，由 T2 完成。T1-2 是 R6 的 cir 断言精确正则，转换序列在 computed 值下的实际指令形态由 T3 按实际 cir 实现。T1-3 是 `CIR_CACHE_VER` 从 17 改为 18 的注释文本与 `.ccr` 显式结论的记录位置，由 T3 与 T5 完成。

### T2：探针入仓与陷阱文档

维护者 T2 批准（2026-09-16）包含三项。第一，确认 R7 与 R6 的归类修正。第二，两条陷阱必须落入仓级文档，不能只存在于报告中；检查方式是下一个人搜索「noclobber」时能在仓里搜到。第三，T3 检查补「槽型正确」和「无重复转换」两条，两条都要。

新文件为 `tests/selfhost/test_agg_read_type.py`，未接入 CI，允许清单有条目。分支 A 检查语义值，包含 R1 LET 中转、R2 match 载荷、R3 局部数组元素、R4 元组元素、R5 写回 apx 槽，期望 `elf=7`。分支 C 检查非回归断言，包含 R7 Core 调用实参和 N1 apx 阶段已转正形，改前即绿，修后必须仍绿。分支 B 是界面见证：B1 与 B2 为反方向，要求没有 `_dxt`；B3 为正方向，要求 `_dxdiv` 恰好 1；B4 要求 extern 调用点前有转换。

允许清单条目位于 `tests/harness/ci_hook_allowlist.txt`。条目写明「RED 语料，勿接入」，并写明修复阶段的三件套：删条目、接入 `run.sh`、改头注。

两条陷阱写入 `tools/baseline/REBUILD.md`，新增小节 `### 命令层陷阱（假红）`，位置在「换代纪律」之前，与既有的「适用范围限制」和「已知限制」同区。第一条是 `noclobber`：重定向到已存在的日志时，命令根本没有运行，读到的是上一轮旧日志。第二条是 `corec build` 必须在仓库根运行，否则报 `cannot locate src/runtime/rt.cr`。两条叠加时表现为整阶段探针全部失败，实例是 #78 的 T1 首轮 8/8 假红。检查方式为 `grep -rn noclobber tools/`，命中该文件，仓级可搜。阶段报告在 T5 另单列一节。

T3 的验收形状由维护者指定：槽型正确加无重复转换，两条都要。R1 的 IR 证据给出检查形状：修后 `load_field` 的结果槽类型必须是 `TI_DEX_S`，不能是 `TI_INT`；下游不得再出现那次多余的 `× _dsc`。后者检查转换不重复，既不能漏转，也不能转两遍。

落进套件的形态是分支 B，两个方向都取门控忠实的见证。

| 见证 | 门（唯一依据） | 出现后的断言 |
|---|---|---|
| `_dxt`（`const _dsc = 1000000` 加 `binary _dxt = <v> * _dsc`） | `dex_scale_int:1033-1040` 的门 `irv_type(var) == TI_INT` | 出现说明读槽仍是 `TI_INT`，属于反方向，因此 R1 与 R3 要求计数为 0。 |
| `_dxdiv`（`i2f _dxf` 加 `const _dxsc` 加 `binary _dxdiv = _dxf / _dxsc`） | `dex_scaled_to_bits:1016-1029` 的门 `irv_type(var) == TI_DEX_S`，且非字面量 | 出现说明读槽已是 `TI_DEX_S`，属于正方向，因此 R5 要求计数恰好为 1，等于槽型正确且不重复转换。 |
| `load_field` 到 `call_extern` 之间的序列 | extern 分支门 `irv_type(av) == TI_DEX_S`（`:1902`） | 必须非空。R6 的改前为空，这就是 RED 正据。 |

使用门控见证而不直接读槽型，原因是 `.cir` 文本转储不打印普通 IR 变量的类型。`dump.cr:50-60` 的 `type_kind_name` 只在 `alloc` 与 `const` 行输出，且 `TI_DEX`（1）与 `TI_DEX_S`（8）同名「dex」，不可区分。权威通道是 `.ccr` SYM 的 per-var 型字节（`ccr_io.cr:690`），但需要写二进制解析。因此本次先用门控见证；门恰好是需要断言的类型谓词，所以忠实。`.ccr` SYM 解析列为 T3 的可选加固。

裁-AGG-7 的记录位置如下。`CIR_CACHE_VER` 从 17 改为 18，位置在 `cir_cache.cr:51`，由 T3 实施。注释文案必须写清原因：

```text
// 18：TODO #2026-09-16-16「聚合读丢型」，聚合读结果槽型由 TI_INT 改为声明面形式（dex 声明，因此 TI_DEX_S）。
//     旧快照里读槽型 = TI_INT，与修复后语义不等价，因此命中旧条目会恢复「丢型」的坏 IR。
//     与 TODO #2026-09-10-4（缓存键缺编译器身份）同族：cache miss = 无害重建。
```

`.ccr` 不 bump，但报告必须写明「dex 程序的 `.ccr` 内容会变，格式不变，内容变」，防止后来人把「版本没 bump」读成「内容没变」。记录位置是阶段报告的检查节与 `.ccr` 段。检查结果为 cache miss，因此无害重建，照 TODO #2026-09-10-4 的结束约定。canary 与五条检查不受影响，因为没有 dex，这与停条件①（非 dex 聚合读任何字节变化就停）互为印证。

T2 未决事项有三条，转 T3。T2-1 是 `.ccr` SYM per-var 型解析，属于可选加固。T2-2 是 `run.sh` 接入点与头注转正，属于 T3 修复后三件套的第二步。T2-3 是 R6 的断言在 T3 实施后按实际 cir 形态复核，转换序列可能随实现约定变化。

### T3：实施、突变与基准值更新

维护者 T3 批准（2026-09-16）包含三项。第一，事故「本次承担一半」与正确方法写入派单约定。第二，门控见证设计获得肯定，理由是「先确认工具链能不能表达 X」。第三，实施约定为声明面形式判定、3 个读点定型、`CIR_CACHE_VER` 从 17 改为 18、分支 A 与分支 B 变为通过、接入点三件套。检查项为分支 A 5/5，但存在 R4 冲突，见下文；分支 B 四条见证；分支 C 断言；停条件①为非 dex 任何字节变化就停；停条件②为关 hack 后分支 A 红就停。

实施采用零分配通道，包含 3 个读点、1 处 bump 和接入点三件套。

| # | 位置 | 改动 |
|---|---|---|
| ① | `ir_gen.cr`，`enum_payload_ti` 之后新增 | 4 个节点级 helper。`agg_read_form_is_dex` 判断 `ast_kind(tn)==0 && ast_type_val(tn)==TY_DEX`，不调 `res_type_node`。`agg_field_read_form` 使用 `si_field_type_node` 加节点判；数字元组下标满足 `ast_type_val>0`，因此为 `TI_INT`。`agg_elem_read_form` 使用 `elem_ti_of_decl(slot_decl_ti(arr))`，是纯表读；`TI_DEX` 与 `TI_DEX_S` 都归一到 `TI_DEX_S`，因为聚合存储恒为 scaled。`agg_payload_read_form` 使用 `find_gsym`、`find_enum_row_of`、`ei_variant_type_node` 加节点判。 |
| ② | 字段读，`:2647` 邻域 | `irv_set_type(v, agg_field_read_form(node, fi))`，在 `fi` 解出之后执行。位序无关，但语义需要 `fi`。非 dex 时返回 `TI_INT`，等于原值，因此零影响。 |
| ③ | 元素读，`:2717` 邻域 | `irv_set_type(v, agg_elem_read_form(arr_var))` |
| ④ | match 载荷绑定，`:2450` 邻域 | `irv_set_type(fv, agg_payload_read_form(arm_pat, fi))`。`EXPR_ENUMPAT` 的 `a` 是变体名 ni。 |
| ⑤ | `cir_cache.cr:51` | `CIR_CACHE_VER` 从 17 改为 18，加注释：旧快照读槽型为 `TI_INT`，与新语义不等价，命中旧条目会恢复坏 IR；与 TODO #2026-09-10-4 同族；cache miss 等于无害重建。历史条目「v18（不 bump，R2 P4 Task 4…）」的标题改为「[曾议 v18 而未 bump]」，避免与本次撞号。 |
| ⑥ | 接入点三件套 | `run.sh` 的 `selfhost-tests` 增加 1 行；`ci_hook_allowlist.txt` 减少 1 条；套件头注改为「已修」。 |

分支 D① 突变在 13.3 执行。把 `:1342-1343` 的两行 hack 注释化，重建，运行检查。apx 阶段套件 23 例全部通过，本次 6 例通过，分支 B 全部通过。通用机制独立成立，hack 的覆盖面被声明面机制完全接管，hack 冗余得到确认。退役检查「分支 D① 连续两阶段通过」的第一步达成。随后恢复源码、重建、复验，全部通过。

R4 与 T3 约定存在冲突，需要维护者裁定。T3 约定写「分支 A 5/5 变为通过（R1 至 R5）」，但裁-AGG-3 已裁「元组没有声明面，登记，不纳入本次」。实测事实是：元组构造（`ir_gen.cr` 的 `EXPR_TUPLE` 分支）给元组 var 定型 `TI_INT`，不携带元素 ti。数字下标读（`t . 0`）因此取不到声明面，本次通道覆盖不到它，R4 修后仍为 1。

处置按裁-AGG-3 执行。3 个读点不包含元组。套件把 R4 移入 `[GAP]` 组，只观测，不计入检查，打印期望值与实测值，并注明裁决与出处。后续阶段修复时须把它移回 `CASES`。如果现在就要覆盖元组，最小机制是在元组构造点按「全元素同形」把该形式登记进既有声明侧表，即 `irv_set_decl_ti(tv, TI_DEX_S)`，2 行，零分配；数字下标读再查 `slot_decl_ti(obj_var)`。代价与风险是：`slot_decl_ti(tv)` 变为 `TI_DEX_S` 会波及唯一取址面 `ir_gen.cr:1530`，即 `&tuple` 的 pointee 型行身份从 `TYP_PTR(TI_INT)` 改为 `TYP_PTR(TI_DEX_S)`，需要一条实证；这是新机制，与最小改动约定相抵。建议维持裁-AGG-3，登记。

基准值更新按裁-AGG-7 的四要素执行：旧值、新值、归因、出处。

| 实现方式 | 旧值与新值 | 处置 |
|---|---|---|
| `cir_cache.cr:51` | `CIR_CACHE_VER` 从 17 改为 18 | 改常量并加注释，归因写清 |
| `tests/selfhost/test_ccr_types.py` 的 ㉛ 与 ㊲，以及模块头注 | 断言 `ver == 17` 改为 18 | 断言改 18，三处注释写明「旧值 17、新值 18、归因、出处」 |
| `tests/selfhost/test_cache_identity.py` | `VER_EXPECTED` 从 17 改为 18 | 同上。布局未变，因此 `layout()` 的 v17 分支按 `VER_EXPECTED` 复用，无需新分支 |
| `src/compiler/dyn_arr.cr:112` 与 `src/compiler/ccr_io.cr:137` | 陈旧注释「CIR_CACHE_VER=17 不 bump」 | 更新注释并指向本次，仅注释，零行为 |
| `.ccr`（`CCR_VERSION=9`） | 不 bump | 交付格式没有快照复用语义。报告须写明「dex 程序的 `.ccr` 内容会变」，防止「版本没 bump」被读成「内容没变」 |

基准值更新过程有三次红色。首轮 `selfhost-tests` rc=1，两例因为版本位失败，分别是 `test_p4t4_cir_snapshot_layout_unbumped` 与 `test_p5t2_snapshot_disk_code_preserved`。更新基准值后重跑又红，但那次是环境抖动：同套件在干净缓存下 49/49 通过；改前二进制对照运行为 47/49，恰好是那两例版本断言，属于预期。第三次红是 `test_cache_identity.py` 的 `VER_EXPECTED` 未同步，即上表第三行；一并更新后 rc=0。

本次的未覆盖面登记如下。U7 是 `IR_SLICE` 产物的元素读。切片 var 的 IR 型恒为 `TI_INT`，且 `is_ptr_var:627` 对 `TI_DEX_S` 提前返回 0，因此改切片 var 型会改变指针判断，不能用「给切片 var 定型」的办法。切片元素的声明形式无处寄存，若要覆盖，需要新增侧表或更换寄存面。U1 是 match 结果槽（裁-AGG-2）。U2 与 U4 是元组和泛型（裁-AGG-3 与裁-AGG-4）。这些在第 10 节已登记，本次未动。

T3 未决事项有四条。T3-1 是 `.ccr` SYM per-var 型的直接断言，属于可选加固；本次用门控见证加 canary 与 parity 覆盖。T3-2 是 R4 的取裁。T3-3 是分支 D①「连续两阶段通过」的第二次，下阶段重新运行本套件与 apx 套件且 hack 仍关，达成后可删 hack（TODO #2026-09-16-16 追记）。T3-4 是 `.cn` 与 `.cir` 之外是否有第三处落 per-var 型的产物；本轮扫描到 `ccr_io.cr:631`、`ccr_io.cr:690` 与 `cir_cache.cr:259` 两处，未见第三处。

### T5：交付与完成

`TODO #2026-09-16-36` 为本次新条目。编号按 develop `66eb9589` 的现状取，等于最大编号 #97 加 1。条目把元组数字下标与 `IR_SLICE` 产物元素读合成一条，内容包括现象、最小机制（元组构造点按「全元素同形」登记 `irv_set_decl_ti`，2 行零分配）、代价与待实证（`&tuple` 的 pointee 型行身份）、切片侧三候选、同族互引（#97 与 #91）、修复时检查和状态登记未修。

`TODO #2026-09-16-16` 的状态改为完成，内容包含修法、检查和未覆盖面指向 #98。阶段报告位于 `docs/superpowers/implementation/2026-09-16-agg-read-type-batch-report.md`，共 13 节：第 0 节一行结论；第 1 节提交链；第 2 节根因修法；第 3 节检查；第 4 节分支 D① 突变；第 5 节二进制同一性论证；第 6 节镜像教训；第 7 节 GC12 顺序；第 8 节陷阱落仓；第 9 节换代更新基准值；第 10 节 R4 的 `[GAP]` 处置与裁决出处；第 11 节检查可行性经验；第 12 节未覆盖面；第 13 节诚实边界。

提交为 `5a245777`（TODO）、`9de1c4c0`（报告）和本记录。

### 报告约定

阶段报告必须写两条。第一条是镜像教训：「`.ccr` 没变 ≠ 生成面没变」（#93 阶段）与「`.ccr` 没变 ≠ 这个面被覆盖了」（本次）合起来才完整。检查的「绿」只在它的覆盖域内有意义。

第二条是 GC12 的自修正顺序。先查出 `res_type_node` 对基类型节点是纯查表、零分配，把规则改准，再决定不用它。本次一律不调它。这体现的顺序是「先把规则改准，再决定用不用」。

## 验收结果

### 改前实测（固定基线编译与 `--static` 产物运行）

| 探针 | 期望 | 改前实测 | 判定 |
|---|---|---|---|
| R1 LET 中转 | 7 | 1 | RED，不报错地错值 |
| R2 match 载荷 | 7 | 1 | RED |
| R3 局部数组元素 | 7 | 1 | RED |
| R4 元组元素 | 7 | 1 | RED |
| R5 写回 apx 槽 | 7 | 1 | RED |
| R6 extern 实参 | IR 断言，见下文 | `run_rc = 139`，静态链既有崩溃面 | RED，正据在 IR 面 |
| R7 Core 实参（断言） | 7 | 7 | 绿，与读码判定一致，归类已修正 |
| N1 apx 阶段已转正形（断言） | 7 | 7 | 绿 |

全部 8 档 `check` 都是 0 error。没有诊断，这正是「不报错地」的实测证据。

### IR 级机理正据

| 探针 | cir 证据（改前） | 读法 |
|---|---|---|
| R1 | `load_field field = s.0` 改为 `const _dsc = 1000000`，再 `binary _dxt = x * _dsc`，再 `binary _dxm = _dxt * dex` | 读槽被当 int 二次缩放，`dex_scale_int` 的 ×S 使值放大 10⁶ |
| R3 | `--dump-entries`：`var 40 name=elem kind=LOAD_INDEX` 之后依次是 `_dsc`（1e6 常量）、`_dxt`（BINARY）、`_dxm`（BINARY） | 同上，另一个读点 |
| R6 | `load_field field = s.0` 改为 `call_extern dest=call s1=6 s2=36 s3=1`，中间零转换，既没有 scaled，也没有 bits，也没有位模式常量重发射 | extern 契约破坏的正据，当前为空序列 |
| R7（断言） | `load_field field = s.0` 改为 `call dbl(field)`，零转换且正确 | Core 形参物化 scaled 与读值 scaled 同形，因此直传正确 |

### T2 改前实测

固定基线为 `build/corec`，sha 为 `a689de9a…`。分支 A 5/5 红，`elf=1`，`check` 0 error。分支 C 2/2 绿，`elf=7`。分支 B 4/4 红，读数分别为 `_dxt` 1、`_dxt` 1、`_dxdiv` 0、无转换。整档 9 项失败，与 T1 实测一致。

### T3 检查

| 检查 | 结果 |
|---|---|
| 分支 A（语义值） | R1 LET 中转、R2 match 载荷、R3 局部数组元素、R5 写回 apx 槽，`elf=7` 全部通过，改前全为 1。R4 见 R4 冲突节。 |
| 分支 B（界面见证） | B1 反方向 `_dxt=0`；B2 反方向 `_dxt=0`；B3 正方向 `_dxdiv` 恰好 1；B4 extern 的 `load_field` 与 `call_extern` 之间有转换。四条全部通过，改前四条全部失败。 |
| 分支 C（断言） | R7 Core 实参和 N1 apx 已转正形全部通过。 |
| 停条件①（非 dex 零影响） | canary 5/5 IDENTICAL，包含 ELF `95084e7b…d475`、28822B 和 `.ccr` 四条。`generics_test` 含 int 与 str 字段读而零 dex，因此这条同时是「非 dex 读槽恒为 `TI_INT`」的行为证据。 |
| 74 档 parity | rc 逐档全同，35 档 rc=0，39 档 rc=1。有缓存状态分支 FAIL=0，41 档真命中。 |
| 29 行为探针 | rc 与基线全同。 |
| 接入点 harness | `test_ci_hook_coverage.py` PASS，`scope=69`，`hooked=48`，`unhooked=21`。 |
| 二进制同一性 | 注释与测试改动后重建得到 `64c8a7d6…`，与检查二进制逐字节相同。因此已运行的 canary、parity、probes 结论对终态成立。 |

### 分支 D① 突变

关掉 apx hack 后，重建并运行检查。apx 阶段套件 23 例全部通过，本次 6 例通过，分支 B 全部通过。通用机制独立成立，hack 的覆盖面被声明面机制完全接管，hack 冗余确认，「分支 D① 连续两阶段通过」的第一步达成。恢复源码、重建、复验后全部通过。

### 五个 CI job 与自举链

| job | rc | 关键内证 |
|---|---|---|
| `check` | 0 | corearch 与 corelsp 的 `build log clean (error[ = 0, undefined = 0)`；`check src/compiler` 0 error |
| `bootstrap-tests` | 0 | bootstrap 套件全部通过 |
| `selfhost-tests` | 0 | `test_ccr_types.py` 49/49；`interp_parity` 23/23；本次套件在接入点后随 job 运行，全部通过 |
| `suite` | 0 | 23 档 ALL PASS，包含 `apx_conversion_test.cr` |
| `full-bootstrap` | 0 | `cmp /tmp/corec2 /tmp/corec3` 恒等，2904726 B，sha256 为 `b8e4298ad0d7…` |

命令形式为 `CI_JOB_NAME=<job> bash src/ci/run.sh`。argv 写法会造成假红，见 `tools/baseline/REBUILD.md` 的命令层陷阱节。

### T5 最终检查

| 检查 | 结果 |
|---|---|
| canary | PASS 5/5，ELF 与 `.ccr` 四条 IDENTICAL |
| `check` | rc=0，corearch 与 corelsp 的 `build log clean (error[ = 0, undefined = 0)` |
| `bootstrap-tests` | rc=0 |
| `selfhost-tests` | rc=0，包含本次套件接入点，`ccr_types` 49/49，`interp_parity` 23/23 |
| `suite` | rc=0，23 档 ALL PASS |
| `full-bootstrap` | rc=0，`cmp corec2 corec3` 恒等，2904726 B |
| 二进制同一性 | T5 重建得到 `64c8a7d6…`，与检查二进制逐字节相同。因此 canary、parity、probes 结论对终态成立 |

### 阶段终态结论

聚合读结果槽原先硬定 `TI_INT`，造成总检查级连锁无法检测。读点定型改为声明面形式，采用零分配的节点判，并把 `CIR_CACHE_VER` 从 17 改为 18。分支 A 4/5 变为通过，R4 按裁-AGG-3 登记 `[GAP]`。分支 B 四条见证通过，分支 C 断言通过，canary 5/5 IDENTICAL，74 档与 29 探针 rc 全同，五个 CI job rc=0，自举链恒等，分支 D① 突变通过，hack 冗余确认。

## 遗留问题

- R4 元组读按裁-AGG-3 登记为 `[GAP]`，本次只观测，不计入检查。后续阶段修复时须移回 `CASES`。
- TODO #2026-09-16-36 覆盖元组数字下标与 `IR_SLICE` 产物元素读，状态为登记未修。
- U7 的 `IR_SLICE` 元素读没有覆盖。切片 var 的 IR 型恒为 `TI_INT`，`is_ptr_var:627` 对 `TI_DEX_S` 提前返回 0，因此不能直接给切片 var 定型。切片元素的声明形式需要新增侧表或更换寄存面。
- U1 的 match 结果槽没有覆盖，依据裁-AGG-2。
- U2 与 U4 的元组和泛型没有覆盖，依据裁-AGG-3 与裁-AGG-4。
- `.ccr` SYM per-var 型的直接断言没有实施，属于可选加固。本次使用门控见证，并由 canary 与 parity 覆盖。
- 分支 D①「连续两阶段通过」只完成第一次。第二次需要下阶段重新运行本套件与 apx 套件，且保持 hack 关闭，达成后才能删除 hack（TODO #2026-09-16-16 追记）。
- R6 的运行值无法测试，原因是 `tests/suite/ffi_test.cr:8-11` 记录的静态链 FFI 既有崩溃。本次改用 IR 级断言。
- `.ccr` 的 `CCR_VERSION=9` 没有 bump，但 dex 程序的 `.ccr` 内容会变，格式不变。报告已写明这一点。
- `.cn` 与 `.cir` 之外未发现第三处落 per-var 型的产物。本轮扫描到 `ccr_io.cr:631`、`ccr_io.cr:690` 与 `cir_cache.cr:259` 两处。

## 不包含

- 不 bump `.ccr` 的 `CCR_VERSION`，保持 9。
- 不修改 `IR_ALLOC` 的 tk 与 `IR_DYN_PACK` 的 tag（裁-AGG-6）。
- 不删除 apx hack（裁-AGG-5），退役检查留到下一组。
- 不实现 R4 的元组数字下标读（裁-AGG-3）。
- 不实现 U7 的切片元素读、U1 的 match 结果槽、U2 与 U4 的元组和泛型。
- 不做 `.ccr` SYM per-var 型的直接断言。
- 不做 extern dex 调用的运行值测试，只做 IR 级断言。
- 不为切片元素新增侧表，也不更换寄存面。
- 不在本次执行分支 D① 的第二次连续验证。
