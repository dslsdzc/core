# R2 P4 任务 3 报告：IFACE 段内容，包括扩列到 16、形状命名化、签名项化、impl 边和方法表、读回

日期：2026-09-13。基线：`6822102a`，TF01 收口，`check src/compiler` rc=0，corearch 清单包含 `type_engine.cr`。

任务：计划 `docs/superpowers/plans/2026-09-12-r2-p4-carrier.md` 的任务 3，按 D14（五小节）、裁决 1（形状命名化并接受 STR 增长）、裁决 2（impl 边等于声明元数据）、裁决 3 和 7（条目扩列 13 到 16，`AK_NULL` 独立槽）、D17（六个形状的 ASCII 名）、D18（段内容构造与序列化解耦）实施。

口径：所有命令使用 `nice -n 19`，cwd 为仓库根，一构建一编译串行，任何 `.ccr` 或缓存态比较前先 `clean-cache`。数字为本轮实跑，例外逐条标注。

## 0. 交付摘要

| 项 | 结果 |
|---|---|
| IFACE(8) 段体 | 五小节（D14）：① 原生条目 16×24B；② 形状 6×8B；③ 用户接口，头 16B 加方法 80B；④ impl 边 8B；⑤ 方法表 12B。实测 452B（ptr_arith）和 744B（2 接口夹具） |
| 扩列 | `IFACE_ENTRY_COUNT` 从 13 改为 16，增加 AK_NULL、AK_SUM、AK_FN，`ops = 0`，属于纯信息面；`name_ni` 逐名注册，20 名一张表，等于 16 个条目名加 4 个形状独有名 |
| 形状命名化 | `iface_shape_builtin_init()` 使用 D17 的六个名字，在 `init_types` 尾部调用，D13 重建时重跑；判定语义零变化 |
| 签名项化 | `ret_term` 和 `param_terms` 由 `sh_iface_sig_*` 写入磁盘；`ESZ_IFMETHOD` 从 168 改为 240，`ESZ_IFACEINFO` 从 2712 改为 3864，新槽为 `OFF_IFM_PARAM_TERMS=168` 和 `OFF_IFM_RET_TERM=232` |
| 写侧 | `ccr_types.cr` 增加 `ccr_iface_populate`，不可建时拒绝写入磁盘，并增加 `ccr_iface_seg_build`；入口更名为 `ccr_seg_prepare_save`，处理 TYPE 和 IFACE 两段 |
| 读侧（corearch） | `load_ccr` 解析五小节，重建 `g_iface_entries`（ok=1 表示段为真源）、形状表、`g_ifaces`（节点槽为 -1，项槽取段值）、`g_impl_for`、`g_methods`；有跨段引用域检查；失败时整体拒绝 |
| 读回通道 | `corec ccr --dump-ifaces` 和 `corearch --dump-ifaces` 使用同一条打印路径 `ccr_iface_surface_dump`；`ifaceprobe` 摘要跨进程同值；`ifacesig*` 活算节只在 corec 侧 |
| `selftest-types` | 347/347，从 338 增加 9，即 ct2.* 8 例加 x2.shape_builtin_names |
| `test_ccr_types.py` | 28/28，包含 T1 机制面重定的 8 例、T2 的 10 例、T3 新增的 10 例 |
| ELF canary | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`，IDENTICAL |
| 自举链 | `corec2 == corec3` 的 cmp 为 IDENTICAL，双 2737902B `55dc7cda…`；N06=0；冒烟 42（corec 和 corec2）；`corec3 --help` rc=1 |
| `.ccr` 新记录值（冷缓存） | `ptr_arith` 90823B `fb4a3b59…`；`generics_test` 134701B `cafb4278…`；自源 10418710B `3d617813…`。STR 增加 16 串、156B（用户程序），自源为 0 |
| 回归 | 五个 CI job 全部 rc=0，包含 `check`；全枚举 54/54，即 47 个 selfhost 加 7 个 bootstrap；同源对拍的 check 和 shadow 两侧 diff 为空，`decisions=32280=agree` |
| 提交 | 见第 11 节，路径限定 13 个文件 |

## 1. 段布局（D14；实现权威为 `ccr_io.cr` 头注释、`ccr_types.cr` 头注释和 spec 第 3.8 节）

```
IFACE(8) 段体（小端；offset 相对段首；各小节自带 count u32）：
  ① [native_count u32 = IFACE_ENTRY_COUNT = 16]
     [× 24B {ak i32, ti_row i32, name_ni i32, lit_code i32, ops i64}]   ← g_iface_entries 原样
  ② [shape_count u32] [× 8B {name_ni i32, term i32}]                   ← 名 + 形状项（六 D17 名）
  ③ [iface_count u32] [× {name_ni i32, method_count i32, generic_count i32, pad i32}
        + method_count × 80B {name_ni i32, param_count i32, self_mode i32, ret_term i32,
                              param_terms[8] i32, param_codes[8] i32}]
  ④ [impl_count u32]   [× 8B {trait_ni i32, type_ni i32}]              ← g_impl_for
  ⑤ [method_count u32] [× 12B {type_ni i32, method_ni i32, mangled_ni i32}]  ← g_methods
```

偏差登记一处，显式说明：计划 Interfaces 块对方法记录给了两处次序相反的列表。声明行是 `× {name_ni, param_count, self_mode, ret_term, param_terms[8], param_codes[8]}`，尺寸式是 `{name_ni, param_count, self_mode, ret_term} 4×4B + param_codes[8] 32B + param_terms[8] 32B`。本任务取声明行的次序，因为前者带逐字段 i32 标注，属于布局声明文本，后者只是尺寸计算。因此盘上顺序是项槽在裸码槽之前。写侧 `ccr_iface_seg_build`、读侧 `load_ccr`、测试的独立解析器 `parse_iface_segment`、spec 第 3.8 节四处同序，已逐字节对拍，见第 6 节判据 3 和 4。

实测尺寸，冷态：`tests/suite/ptr_arith.cr` 有 0 个用户接口，段体 452B，等于 4+16×24+4+6×8+4+4+4，三段空计数。`/tmp/p4t3/fixsrc.cr` 有 2 个接口、3 个方法、1 个 impl，段体 744B，等于 388+52+(4+96+176)+12+16。

## 2. 步骤 1：用例（至少 10 例，实际 10 例加机制面重定）

`tests/selfhost/test_ccr_types.py` 新增 T3 节，编号 ⑯ 到 ㉕：

| # | 用例 | 覆盖面 |
|---|---|---|
| ⑯ | `test_p4t3_iface_segment_layout` | 五小节的计数和长度逐条等于内存真值，行走完等于段体，没有尾随字节；逐记录不变量包括 ak 域、ti_row 域、name 域、term 域、self_mode 域，扩列硬值为 16，三新行 ops=0、lit=-1，六个 D17 形状名按 STR 解析 |
| ⑰ | `test_p4t3_bytes_match_corec_dump` | 段字节由 Python 直接解析，结果等于 corec 侧 dump 的内存真值；五小节逐字段比较，包括方法 80B 的项槽和裸码槽分列 |
| ⑱ | `test_p4t3_corearch_readback_parity` | 读回对拍：corearch `--dump-ifaces` 与 corec 侧逐行相同，包含五小节和 `ifaceprobe`；`ifacesig*` 节只在 corec 侧 |
| ⑲ | `test_p4t3_signature_itemization_matches_live` | 签名项化：段内 `ret_term` 和 `param_terms` 等于缓冲构造后活算的 `sh_iface_sig_*`，装填零变化；未用槽为 -1；接收者槽是 unit 项，大于等于 0；正控要求至少一个有效项，防止全 -1 的虚假通过 |
| ⑳ | `test_p4t3_shape_name_registration` | 形状命名化：六个名字入段并按 STR 解析，项入 TYPE 域，顶层结构独立对拍；TT_TOP_K 和 TT_UNION 到原子类集的映射等于语义定义：sequence={SEQ}、sequence_ro={SEQ,REF}、indexable={SEQ,STR}、product={PROD} |
| ㉑ | `test_p4t3_cross_process_term_probe` | 跨段引用域探针：`slots == Σ(1+pc)`、`built+unbuilt == slots`、`bad == 0`，corec 和 corearch 的 digest 同值 |
| ㉒ | `test_p4t3_loader_rejects_iface_mutations` | loader 负分支，逐字节变异：native_count≠16、形状 term 越域、方法 ret_term 越域、方法名 ni 越 STR、尾插 4B、尾截 4B |
| ㉓ | `test_p4t3_dump_flag_zero_artifact_effect` | `--dump-ifaces` 只读，带 flag 和不带 flag 的 `.ccr` 逐字节相同，活算节不进入序列化面 |
| ㉔ | `test_p4t3_determinism_cold_cold` | 冷态对冷态：IFACE 和 TYPE 段逐字节相同，整个 `.ccr` 相同 |
| ㉕ | `test_p4t3_cold_warm_iface_segment` | 冷态对暖态：IFACE、TYPE 和既有的 2 到 6 段逐字节相同；命中证据是暖运行不重写缓存 |

机制面重定，T1 用例随内容面实施翻转，逐条如下：

- ③“IFACE 空壳 count == 0”用例 `test_p4t1_shell_bodies_zero_count` 退役删除，因为没有适用对象，空壳门已由第 4 节的内容门替代。
- ④-d“IFACE 非零计数拒绝”用例改为“两段段体必须大于 4B”，防止空壳门不报错地恢复。
- ① 和 ⑥ 的 `SHELL_TAGS` 改为 IFACE 内容面非空断言，以及 IFACE 段冷热同判。
- `test_p4t1_loader_rejects_missing_type_iface`（D11 必备集）和 tag 变异例语义不变，零改动。

失败态纪律说明：与 T2 相同，用例和实现放在同一提交，首轮就通过，判别力由第 9 节的突变控制承担。

## 3. 步骤 2：扩列和命名化（`iface_registry.cr`、`dyn_arr.cr`、`checker.cr`）

- 布局常量迁入 `dyn_arr.cr`，包括 `ESZ_IFACE_ENTRY`、`OFF_IE_*`、`IFACE_ENTRY_COUNT` 和 `iface_shape_grow`。IFACE 段在 corearch 侧的 loader 要重建条目表和形状表，而 `iface_registry.cr` 不在 corearch 清单中，因此常量和 grow 助手必须放在双 concat 共享面，与 `ESZ_IFACEINFO`、`ESZ_IFMETHOD` 放在同一处是已有先例。迁入只放宽声明顺序，零语义变化。
- 扩列，裁决 3 和 7：`iface_put(13..15, …)` 使用 `AK_NULL`(15)、`AK_SUM`(9)、`AK_FN`(13)，值为 `{ti_row = -1, lit_code = -1, ops = 0}`，属于纯信息面。`iface_permits` 对 0 位集恒为 0，与“未登记”同值，因此三行不改变任何判定。
- `name_ni` 逐名注册，裁决 1 翻转 T1、T2 的“留 -1”口径。原文注记保留，另加翻转注记。16 个条目名加 4 个形状独有名，共 20 名。`str_intern` 幂等，长驻进程重复 `init_types` 零增长。
- `iface_kind_of` 零改动，`iface_axis.cr` 逐字未动。`TYP_NULL`、`TYP_OPTIONAL`、`TYP_DYN` 的行分派与 P2b 域逐格保持，判定面零变化。守卫用例是 selftest 的 `ct2.kind_of_no_new_mapping`，枚举全类型行并显式检查两行为 -1。
- 形状命名化：`iface_shape_builtin_init()` 用六个名字调用 `sh_shape_*()` 构造点，同名覆盖幂等。调用点是 `init_types()` 尾部，在 `iface_registry_init()` 之后，无条件执行，是生产唯一入口。D13 重建路径 `ccr_type_populate` 会重跑。

## 4. 步骤 3 和 5：签名项化、写侧、读侧

写侧，corec-only 的 `ccr_types.cr`，D18：

- `ccr_iface_populate()` 按接口声明顺序、方法、形参遍历，调用 `sh_iface_sig_ret_term` 和 `sh_iface_sig_param_term`，写入 `g_ifaces` 的 `OFF_IFM_RET_TERM` 和 `OFF_IFM_PARAM_TERMS`，未用槽显式写 -1。不可建时拒绝写入磁盘，返回 -1 并给诊断。触发面实测是 `dyn` 位图行，`sh_sig_term_of_ti` 对 `TYP_DYN` 返回 -1；接收者槽是 unit 占位项，不触发。先 report-only，第 8 节中 61 档零命中后才启用硬门。`method_count` 和 `param_count` 越界同样拒绝，这是双保险，parser 已有硬错。
- `ccr_iface_seg_build()` 把五小节写入 `g_ccr_iface_seg/_len`，缓冲包含首字段，因此尺寸只有一个来源。`ccr_seg_prepare_save()` 更名自 `ccr_type_prepare_save`，三个调用点同步，流程为 populate、TYPE 段、IFACE 段。
- D13 顺序实施：`tt_layer_reset`、桥接和展开复位、形状重注册、行序装填、签名装填。`ccr_type_populate` 第 ③ 段由空实现改为 `return ccr_iface_populate()`。

读侧，corearch 的 `ccr_io.cr` 中 `load_ccr`：解析五小节并重建。唯一复位点是状态重置块新增 6 个计数清零。

- ① 条目表：`native_count == IFACE_ENTRY_COUNT` 是硬门，逐行检查域，ak 在 0..AK_NULL、ti_row 在 {-1} 并上行域、name_ni 在 STR 域、lit 大于等于 -1。通过后设 `g_iface_registry_ok = 1`，表示段是真源，防止常量表覆盖。
- ② 形状表：检查 name 和 term 域，写入 `g_iface_shape_*`。
- ③ 接口表：解析头和逐方法，检查 name 域、pc ≤ 8、self_mode 在 0..3、ret_term 和 param_terms 在 {-1} 并上项域、裸码大于等于 -1。写入 `g_ifaces`，记录先清零；节点槽恒为 -1，因为 corearch 没有 AST；项槽取段值。
- ④、⑤ impl 边和方法表：检查三元组的 ni 域。
- 收尾检查 `pos == seg_end8`，不允许尾随字节。
- `.ccr` 尺寸面不变：NOD 36B 每条等前六段布局零改动。`.cir` 快照不包含 `g_ifaces`，快照字段清单是 vars、DF 节点、SG、指令、串常量，第 10 节第②项已逐项核对。因此内存槽扩容不触发 `CIR_CACHE_VER`。

读回通道：`ccr_iface_surface_dump` 在 `ccr_io.cr`，双侧共用；`ccr_iface_selftest_dump` 为 corec-only 活算节。`corearch --dump-ifaces` 在 `build_linear_schedule` 之前返回 0，不触发发射路径。

## 5. 清单面和链接面（B.6）

- 零清单改动：没有新文件，`build_selfhost_native.py`、两处 `_import.cr`、`test_compile.py` 四个面都没有动。IFACE 段读侧只使用共享层符号，即 `dyn_arr`、`globals`、`type_terms`、`ccr_io` 自身。`iface_registry.cr`、`ty_shadow.cr`、`iface_axis.cr` 一个符号都不引用，这正是第 3 节把常量迁入 `dyn_arr.cr` 的目的。
- 证据：构建三面 `error[ = 0, undefined = 0`，见第 6 节判据 1；`test_backend_bootstrap` rc=0 且 `error[` 为 0，见判据 2。

## 6. 判据（逐条给出命令和结果；全部在最终二进制上复跑）

| # | 判据 | 命令 | 结果 |
|---|---|---|---|
| 1 | 三个二进制构建 | `nice -n 19 python3 build_selfhost_native.py` | rc=0；GUARD 为 corec 45、corearch 32、target 3、corelsp 31；三条 `build log clean (error[ = 0, undefined = 0)` |
| 2 | project-mode 守卫 | `nice -n 19 python3 tests/selfhost/test_backend_bootstrap.py` | rc=0，`error[` 命中 0；stage0、1、2 逐字节相同，smoke 7，O2 metadata |
| 3 | 自源 check | `nice -n 19 ./build/corec check src/compiler` | rc=0，诊断 0 条，TF01 收口后本批保持 |
| 4 | 类型引擎自测 | `nice -n 19 ./build/corec selftest-types` | 347/347，从 338 增加 9 |
| 5 | ELF canary | `clean-cache`，然后 `build tests/suite/ptr_arith.cr -o /tmp/p4t3/pa_final --static`，再 sha256 | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`，IDENTICAL |
| 6 | 读回证据 | `corec ccr --dump-ifaces` 对比 `corearch --dump-ifaces`，再对比 Python 直接解析段字节 | 五小节和 `ifaceprobe` 逐行相同，probe 的 `slots N built B unbuilt U bad 0 digest H` 两侧同值；Python 直接解析与两侧 dump 逐字段相同，见用例 ⑰、⑱、㉑ |
| 7 | 结构性断言套件 | `test_ccr_types.py`、`test_ccr_v7.py`、`test_region_cfg.py`、`test_cache_identity.py` | 28/28、27/27、22/22、5/5 |
| 8 | 全枚举 | `bash /tmp/p4t3/enumerate.sh`，47 个 selfhost 加 7 个 bootstrap | 54/54 全部 rc=0。第三轮使用最终二进制，包含 #31 未挂 CI 档 `test_backend_bootstrap` |
| 9 | 五个 CI job | `CI_JOB_NAME=<j> bash src/ci/run.sh` 执行 5 次 | `check` 为 0，rc=0，TF01 收口后判据口径更新；`bootstrap-tests` 为 0，29/29、4/4、3/3；`selfhost-tests` 为 0，包含新挂的 28/28；`suite` 为 0，ALL PASS；`full-bootstrap` 为 0 |
| 10 | 自举链 | full-bootstrap job，然后 `cmp /tmp/corec2 /tmp/corec3`，检查 N06、冒烟和 `--help` | cmp IDENTICAL，双 2737902B `55dc7cda7498fd3faa92fa26ca7fbddd8e9be02af05f45a92680098cddfba41a`；N06 和 undefined 为 0；冒烟 `run 'fn main()->int{return 42;}'` 得到 42（corec 和 corec2）；`corec3 --help` rc=1 |
| 11 | 同源对拍，check 面 | `bash /tmp/p3t0_run.sh check`，基线 `6822102a` 构建和新构建各跑 72 档，然后 diff | 输出 diff 为空；rc 分布两侧相同，34×0、38×1 |
| 12 | 影子对拍，判定面零变化 | `bash /tmp/p3t0_run.sh shadow`，同上 | 输出 diff 为空，两侧都是 `decisions=32280 agree=32280`；全计数为 0；logs 和 dumps 的 `diff -r` 为空；站点覆盖两侧同报：`assign-node=24495`、`fn-body-ret=5741`、`if-branch=2010`、`struct-field-type=28`、`array-elem-type=4`、`generic-apply-base=2`，合计 32280。继承声明：影子通道对实现方式面零覆盖，只能作为判定面零变化的必要条件 |
| 13 | report-only，新硬错误面 | 61 档 `corec ccr`，基线和新构建各一轮 | 失败集逐条相同，共 11 档，全部是既有问题：0 字节 fixture、parse 错、重复定义、standalone 缺上下文。新拒绝面零命中，`save refused` 诊断 0 条 |
| 14 | 突变控制，判别力 | /tmp 下的突变构建，仓库零改动 | 第 9 节中 3 条逐条失败，复位后重建逐字节相同 |
| 15 | `.ccr` 记录和尺寸实测 | 冷缓存，3 个语料，加 Python 直接解析 | 第 7 节 |
| 16 | 构建确定性，revert 面 | `build_selfhost_native.py` 执行 2 次 | corec `6da65418…`、corearch `f78cf788…`、corelsp `dcf91936…`，两次逐字节相同 |

## 7. 尺寸和记录值实测（不以估算代替）

| 语料 | 基线（`6822102a` 构建） | 新（本任务） | Δ | STR 串数 | IFACE 段 | TYPE 段 |
|---|---|---|---|---|---|---|
| `tests/suite/ptr_arith.cr` | 89859B `0f744675639f3690…` | 90823B `fb4a3b59103f4e0c6231cd557df5a07467281cc7cf82a804f392e98aabfb6f58` | +964B | 158 变为 174，增加 16 串、156B | 4（空壳）变为 452B | 888 变为 1248B，增加 9 项 × 40B |
| `tests/suite/generics_test.cr` | 133698B `8380c3930cd4fd35…` | 134701B `cafb42781f8a4f9bc40ab3bc91b06d8fe1b621b09e9502eb68262ccba5235644` | +1003B | 222 变为 238，增加 16 串、155B | 4 变为 452B | 2696 变为 3096B，增加 10 项 |
| 自源 `src/compiler/_import.cr`（同源树） | 10417862B `b74a05a642f57de8…` | 10418710B `3d6178130a88a518…` | +848B | 5470 到 5470，增加 0 串 | 4 变为 452B | 1736 变为 2136B，增加 10 项 |

- T2 记录值的承接：基线侧实测 `ptr_arith` 89859B `0f744675…`，与 T2 报告记录值逐字节相同，父提交可复现。本表的旧值是 T2 值的可信复现。
- STR 增长逐名列举，兑现裁决 1。阈值面是 20 名一张表，其中源已驻留的名字不新增。
  - `ptr_arith` 新增 16 个：`dex bool unit never char dyn product sequence ptr named null sum sequence_ro sequence_rw indexable iterable`。已存在的有 `int string ref fn`。
  - `generics_test` 新增 16 个：同上，但包含 `ref`，不包含 `bool`。
  - 自源新增 0 个，编译器源码已经驻留全部 20 名，即“自源 STR 零增长”。
- TYPE 段的连带增长为 +360 到 400B。形状注册发生在 `init_types`，六个形状项加 3 个 union 和 cons 尾项先于行装填进入项表，因此项数从 13 变为 22、从 42 变为 52、从 27 变为 37。段内容仍是表的纯函数，见第 6 节判据 12 的确定性用例。
- 前六段逐字节面，实测登记：`selfsrc` 的前六段逐字节相同。`ptr_arith` 的 SYM 和 `generics_test` 的 SYM、NOD 同长但值不同。根因是新驻留名使“晚于 `init_types` 首次驻留”的串 ni 整体后移。NOD 差异实测为 6 条 `IR_CALL` 的 `src3`，即 callee 名 ni，加 17，逐条指向同一个串，例如 `identity[int]`。布局不变，语义不变，ELF canary 不变，属于裁决 1 接受面的连带量化。判据按 TODO #26 使用结构性断言，不要求“与旧版逐字节相同”。

## 8. report-only（新硬错误启用前的全语料扫描）

- 扫描面是计划 Global Constraints 明列的清单：`tests/suite` 21 档、`examples` 6 档、`src/stdlib` 8 档、自源 `src/compiler/_import.cr`（自指，包含全部编译器文件）、`main.cr`、后端和内核单元 4 档，共 61 档。基线和新二进制各跑一轮 `corec ccr`。
- 结果：失败集逐条相同，共 11 档：`at_test_mini4/6.cr` 是嵌套 fn；`test_control_flow.cr` 是 0 字节；`test_generics.cr`；`examples/test_scale|test_sum.cr`；`src/stdlib/{chan,goroutine,sched}.cr` 是 standalone 重复定义；`src/compiler/{ccr_io,ccr_types}.cr` 是 standalone 缺上下文。新诊断 `save refused` 命中 0，两侧都是 0。
- `tests/selfhost` 的内联源由全枚举承担，见第 6 节判据 8，54/54。任一档触发新拒绝都会 rc≠0。
- 因此新硬门“IFACE 装填不可建时拒绝 save”零命中，按计划启用。门体是 `ccr_types.cr:ccr_iface_populate` 的两处 `(save refused)` 诊断加 rc=1。

## 9. 突变控制（判别力；在 /tmp 侧用“清单照旧、内容替换”构建，仓库文件零改动）

harness 在 `/tmp/p4t3/mutmut/`，`build_mut.py` 复用 T2 的产物，`make_mut.py` 生成突变源，`mktree.sh` 构造可运行树，`MUT_ONLY` 指定单目标。突变器第一版遇到问题，登记如下：突变 A 首轮构建的是 corec，`MUT_ONLY=corec`，而 loader 在 corearch，`ccr_io.cr` 同时出现在两个清单中。因此 28/28 全部通过是虚假通过。改为 `MUT_ONLY=corearch` 后才失败。教训是突变必须打在“该文件真实链接的产物”上，本仓库的 `ccr_io.cr` 是双侧共享文件。

| 突变 | 内容 | 期望 | 实测 |
|---|---|---|---|
| A，loader 跨段引用域检查关闭 | `ccr_io.cr` 中形状 term、方法 ret_term、形参 term、形状 name 四处域检查改为注释，构建 corearch | ㉒ 失败 | 失败：`test_p4t3_loader_rejects_iface_mutations` FAIL，消息为 "corearch accepted mutated file: rc=0 (silent-accept = 三态纪律违反)"；27/28，其余 27 例仍通过，突变面较窄 |
| B，跳过签名装填 | `ccr_types.cr:ccr_iface_populate` 首行起 `return 0`，项槽停留零初值，构建 corec | ⑲ 失败 | 失败：`test_p4t3_signature_itemization_matches_live` FAIL，`method 0.0 ret term 0 != live 10`；27/28 |
| C，生产形状注册面缺失 | 删除 `checker.cr:init_types` 尾部的 `iface_shape_builtin_init()`，构建 corec | `ct2.shape_face_from_init_types` 失败 | 失败：346/347，唯一 FAIL 是 `ct2.shape_face_from_init_types: got 0 want 1` |

C 的用例补强说明，登记：初版 `ct2.*` 全部显式调用 `iface_shape_builtin_init()`，因为夹具需要，所以对“init_types 接线缺失”是虚假通过。突变 C 首轮 346/346 全部通过，实测如此。补上 `ct2.shape_face_from_init_types` 后失败，该用例依次执行 `iface_shape_reset()`、`init_types()`，断言 count==6 且逐名同项，不经过显式注册调用。这条本身就说明用例的判别力必须实测，与 T2 的突变 B 修正相同。

出树证据，证明仓库零改动：三条突变二进制的 sha 分别是 runA/corearch `7bcdbfdf…`、runB/corec `1f1d962f…`、runC/corec `7e9a2702…`，都与仓库两件 `6da65418…`、`f78cf788…` 不同，路径在 `/tmp` 侧。仓库源码在两轮突变前后由 `jj status` 干净，加上第 6 节判据 16 的重建逐字节同来证明，`build5` 复跑得到 `6da65418/f78cf788/dcf91936` 三件同 sha。

## 10. 登记面和待说明的问题

① 形状名的 TYPE 段连带增长，增加 9 到 10 项、360 到 400B。形状项必须存在才能注册 name 到 term，这是裁决 1 的生产注册面，而 `init_types` 是唯一生产注册点，因此项表前段多出形状项。这不是缺陷，段内容仍是表的纯函数，但属于可量化副作用，登记。如果未来要压缩，把形状项挪到项表尾部或改为惰性注册，会与“名字面可查”的时序冲突，需要另行裁决。

② 内存布局扩槽不写入磁盘、不进入快照的证据：`ESZ_IFMETHOD` 从 168 改为 240，`ESZ_IFACEINFO` 从 2712 改为 3864，只影响内存。`.cir` 快照字段清单逐项核对为 `var_count + vars{name,id,type}`、`node_count + nodes{8 字段}`、`sg_count + sg{6 字段}`、instrs、str_consts，没有 `g_ifaces`、`g_iface_entries`、`g_shape_*`、`g_impl_for`、`g_methods`。因此不会逐项影响缓存。冷态和暖态一致由用例 ㉕ 和 `test_cache_identity` 5/5 复证。`CIR_CACHE_VER` 保持 17，升级归任务 4。

③ corearch 侧的 IFACE 段目前没有判定消费者，`iface_satisfies`、`iface_find_method` 等仍在 corec-only 文件中。项槽、形状项、条目表在 corearch 侧只是数据和 dump 通道。P5 的 `atom_of` 承接面，即第 6.3 节，是消费入口。本任务兑现的是“信息始终随实现方式，且可读回、可对拍”。

④ 签名编码面，计划步骤 7，只落证据，没有动用例。`isat.axis_c_ret_code`（selftest）和 `inst_encoding_limit_named_ret_rejected`（`test_iface_satisfies.py`）按计划未改。同构证据是用例 ⑲（段内项等于活算项）、用例 ⑰（段字节等于内存真值）、T2 的项表读回同构、用例 ㉑（跨进程 digest 同值）。因此“段内项与进程内项同节点、同判定”成立，改走类型项的收尾归 P5。

⑤ `iface_registry.cr` 头注的历史口径翻转：T1、T2 的“name_ni 留 -1”长注记原文保留，追加 R2 P4 任务 3 的翻转注记，依据裁决 1，避免制造第二个真源。

⑥ 未覆盖面，由 P5 承接：命名消费语法 `T: 可索引` 未开工；整形状 `ty_sub` 路由仍不可用，判定走逐成员；`g_impl_for` 入段但不入判定，依据裁决 2；IFACE 段的项槽在 corearch 侧的引擎消费未接，见第③项。

⑦ `.cir` 缓存面：本任务不触 DF 记录布局和语义，`CIR_CACHE_VER` 保持 17。`test_cache_identity` 5/5，`test_ccr_types` 的 cache-hit 恢复用例通过。

⑧ 报告内有两处与计划文本的偏差：方法记录字段序，见第 1 节；突变器首轮目标错位，见第 9 节。两处都已显式登记。

## 11. 提交（路径限定）

```
8f4af99b（change nkkwxlxo）feat: R2 P4 Task 3——IFACE 段内容（原生条目扩列 13→16 + 形状命名化
        + 接口签名项化 + impl 边/方法表序列化 + corearch 读回）；STR 段增长按裁决 1 接受
14 文件（M×14）：src/compiler/dyn_arr.cr · iface_registry.cr · checker.cr · globals.cr ·
        ccr_types.cr · ccr_io.cr · main.cr · corearch.cr · type_selftest.cr ·
        tests/selfhost/test_ccr_types.py · src/ci/run.sh ·
        docs/superpowers/specs/2026-09-09-lattice-ir-v7-format.md ·
        docs/superpowers/plans/2026-09-12-r2-p4-carrier.md（Task 3 九步勾选）· TODO.md（#41）
```

`jj diff -r 8f4af99b --summary` 核对过，恰好是上列 14 个路径。提交后 `jj status` 显示工作副本干净，空提交 `e0816eec`。

## 12. 证据路径（本机）

- 构建：`/tmp/p4t3/build{1,2,3,4,5}.log`。1 是首建；2、3 修 selftest 夹具；4 加生产注册面用例；5 是最终确定稿复跑。
- 判据：`/tmp/p4t3/st*.log` 没有，使用 inline；`/tmp/p4t3/pa_final` 和 `canary_final.log` 用于 canary；`check_self.log`；`tbb.log`。
- `.ccr` 记录：`/tmp/p4t3/rec/{ptr_arith,generics_test,selfsrc}_{base,new}.ccr` 和 `ccrstat.py`，统计段尺寸和串数；`/tmp/p4t3/fixsrc.ccr`，含接口夹具 744B。
- 全枚举：`/tmp/p4t3/enumerate.sh`，`enum_all.log` 首轮，`enum_final.log` 最终二进制 54/54，逐档日志在 `/tmp/p4t3/enum/*.log`。
- report-only：`/tmp/p4t3/report_only.sh`、`ro_all.log`、`/tmp/p4t3/ro/*.fails.txt`。
- 同源对拍：`pc_{pre,new}.out` 用于 check；`ps_{pre,new}.out` 和 `parity_shadow_{pre,new}/{logs,dumps}` 用于 shadow。
- 自举链：`/tmp/corec2` 和 `/tmp/corec3`，cmp IDENTICAL `55dc7cda…`，加 `ci_full-bootstrap.log`。
- CI：`/tmp/p4t3/ci_{check,bootstrap-tests,selfhost-tests,suite,full-bootstrap}.log`。
- 突变控制：`/tmp/p4t3/mutmut/`，包含 `make_mut.py`、`run.sh`、`mktree.sh`、`run{A,B,C}/`、`build_*.log`。
- 基线二进制，父提交 `6822102a`：`/tmp/p4t3/base/build/{corec,corearch}`，加 `mkbase.sh` 和 `build_base.log`。
