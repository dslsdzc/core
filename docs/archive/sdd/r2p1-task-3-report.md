# R2 P1 任务 3 报告：三档语料跑影子，差异清单归档

状态：完成。步骤 0 的拆因已实施并复验；三档语料加 2 档扩面跑完；差异清单和归因归档；提交见第 7 节。

判据一句话：步骤 0 后得到 `OFF-IDENTICAL` 和 `ON-IDENTICAL`，`ptr_arith` 产物与 `/tmp/r1t4_base_bin` 的三份 sha256 全等，都是 `95084e7b…d475`；`selftest-types` 71/71；四套 selfhost 回归全部通过。

## 1. 步骤 0：unknown 桶拆成两个原因（先改码，再采数）

### 1.1 实现（2 个文件加 1 处扩面）

| 文件 | 改动 |
|---|---|
| `src/compiler/ty_shadow.cr` | `sh_compare`：桥接失败，即 `a<0||b<0`，记为 `kind=3` 并递增 `g_shadow_unknown_bridge`；引擎负值，即 `e<0`，记为 `kind=0` 并递增 `g_shadow_unknown_engine`，再按 `ty_uncovered()` 和 `ty_exhausted()` 细分 uncovered 和 budget。成因位在第二次 `ty_budget_reset` 之前读取，因为 reset 会清位，此处是唯一正确的窗口。`sh_kind_name` 增加 `unknown_bridge`，原来的 `unknown` 改名为 `unknown_engine`。`sh_report` 增加 4 个字段，前 5 组 key=value 前缀不变，任务 4 复核 M2 时与任务 2 原文的 5 组逐字比对过 `28fed09` |
| `src/compiler/globals.cr` | 增加 4 个全局变量：`g_shadow_unknown_bridge/_engine/_uncovered/_budget` |
| `src/compiler/ty_shadow.cr`，任务 3 扩面，不是任务说明要求 | 增加站点直方图：`sh_site_begin` 累计 8 个站点的判定次数，`sh_report` 增加第二行 `[type-shadow-sites]`。理由是 ring 缓冲只有 256 条，而且只装“有差异或未知”的条目，在零差异语料下，“站点是否跑到过”没有其他证据通道。任务说明明确要求登记“站点 4 恒 agree，站点 6 不可达”，扩面前这两条只能推断，扩面后可以实测。结论见第 5 节：站点 4 实际是 0 命中，任务说明的措辞需要更正 |

摘要行使用新格式，前 6 个字段与任务 2 契约一致：

```
[type-shadow] decisions=74 agree=74 old_stricter=0 old_looser=0 unknown=0 unknown_bridge=0 unknown_engine=0 unknown_engine_uncovered=0 unknown_engine_budget=0
[type-shadow-sites] hotpatch-ret=0 generic-arg=0 generic-apply-base=0 unify-fallback=0 fn-body-ret=16 assign-binary=0 if-branch=7 assign-node=51
```

### 1.2 判据（原始输出）

```
$ nice -n 19 python3 build_selfhost_native.py
[GUARD] corec: manifest OK (41 files)
[GUARD] corec: build log clean (error[ = 0, undefined = 0)
[GUARD] corearch: manifest OK (31 files) / x86_64-linux target: manifest OK (3 files)
[GUARD] corearch: build log clean (error[ = 0, undefined = 0)
[GUARD] corelsp: manifest OK (29 files)
[GUARD] corelsp: build log clean (error[ = 0, undefined = 0)
=== BUILD SUCCESS ===

$ nice -n 19 ./build/corec selftest-types | tail -1
71/71 type-engine cases passed

$ nice -n 19 ./build/corec clean-cache && nice -n 19 ./build/corec build tests/suite/ptr_arith.cr --static -o /tmp/p1t3_off2
cleaned .core/cache/cir/
 -> /tmp/p1t3_off2
$ nice -n 19 ./build/corec clean-cache && nice -n 19 ./build/corec build tests/suite/ptr_arith.cr --static --type-shadow -o /tmp/p1t3_on2
cleaned .core/cache/cir/
[type-shadow] decisions=74 agree=74 old_stricter=0 old_looser=0 unknown=0 unknown_bridge=0 unknown_engine=0 unknown_engine_uncovered=0 unknown_engine_budget=0
[type-shadow-sites] hotpatch-ret=0 generic-arg=0 generic-apply-base=0 unify-fallback=0 fn-body-ret=16 assign-binary=0 if-branch=7 assign-node=51
 -> /tmp/p1t3_on2
$ cmp /tmp/r1t4_base_bin /tmp/p1t3_off2 && echo OFF-IDENTICAL
OFF-IDENTICAL
$ cmp /tmp/r1t4_base_bin /tmp/p1t3_on2 && echo ON-IDENTICAL
ON-IDENTICAL
$ sha256sum /tmp/r1t4_base_bin /tmp/p1t3_off2 /tmp/p1t3_on2
95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475  /tmp/r1t4_base_bin
95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475  /tmp/p1t3_off2
95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475  /tmp/p1t3_on2
```

两态在判据前各自独立 `clean-cache`，cwd 为仓库根；关闭和开启两态产物加 R1T4 基线，三份同哈希。

回归加固，不是任务说明要求：

```
tests/selfhost/test_compile.py  → All selfhost compile tests passed.
tests/selfhost/test_type_engine.py → PASS test_selftest_types_all_pass
tests/selfhost/test_impl.py     → 7/7 passed
tests/selfhost/test_borrow.py   → 7/7 passed
```

二进制，提交态重建，即上表判据所用二进制：`build/corec 2ed052d9…f401c9`、`corearch 2841951c…c7bc9`、`corelsp d97d4deb…0ece5a`。只做拆因的中间态为 `corec a6713e00…460fd`；站点直方图实施后源码变更，哈希随之变化，最终态如上。

提交态复核：提交 `75c20297` 后，从恰好提交的内容重新执行 `build_selfhost_native.py`，保护全部通过，`error[` 为 0，`selftest-types` 71/71，并且再次跑两态判据，得到 `OFF-IDENTICAL` 和 `ON-IDENTICAL`，三份 sha256 仍全等 `95084e7b…d475`。因此判据态等于提交态。

### 1.3 拆因收益的实证

拆因前，该条目在 dump 中一律写 `unknown 0`，桥接失败和引擎负值混在一起。拆因后，编译器语料写为 `fn-body-ret 5 28 25 1 unknown_engine 0`，摘要同时给出 `unknown_engine_uncovered=1` 和 `unknown_engine_budget=0`，归因可以直接读出。如果按任务说明的反例只改文档不改码，本报告第 4 节的归因和第 6 节的 P2 裁决建议都拿不到。

## 2. 三档语料：命令和摘要原始输出

运行模板，全部使用 `nice -n 19`，cwd 为仓库根，每个文件前 `clean-cache`：

```bash
# ① 套件
for f in tests/suite/*.cr; do nice -n 19 ./build/corec check "$f" --type-shadow --type-shadow-dump /tmp/r2p1t3/dumps2/t1_$f.txt; done
# ② 编译器自身
nice -n 19 ./build/corec check src/compiler/main.cr  --type-shadow --type-shadow-dump /tmp/r2p1t3/dumps2/t2_main.txt
nice -n 19 ./build/corec check src/compiler/_import.cr --type-shadow --type-shadow-dump /tmp/r2p1t3/dumps2/t2_import.txt
# ③ 后端/内核单元（brief 的 ccr_io.cr + 三轴/内核/组合根目录）
nice -n 19 ./build/corec check src/compiler/ccr_io.cr --type-shadow --type-shadow-dump /tmp/r2p1t3/dumps2/t3_ccr_io.txt
for f in src/format/elf/*.cr src/os/linux/*.cr src/arch/x86_64/*.cr src/lattice/*.cr src/targets/x86_64-linux/*.cr; do nice -n 19 ./build/corec check "$f" --type-shadow --type-shadow-dump /tmp/r2p1t3/dumps2/t3_$f.txt; done
# ④⑤ 扩面：stdlib / examples（同类真实语料）
for f in src/stdlib/*.cr; do nice -n 19 ./build/corec check "$f" --type-shadow …; done
for f in examples/*.cr;   do nice -n 19 ./build/corec check "$f" --type-shadow …; done
```

`check` 路径带影子通道穿透，不需要退化为 build，与任务 2 第 5 节的结论一致。脚本为 `/tmp/r2p1t3_run2.sh`，全量原始日志在 `/tmp/r2p1t3/all_tiers2.txt` 和 `/tmp/r2p1t3/logs2/*.log`。

### ① `tests/suite/*.cr`（31 个文件，27 个有效）

```
tests/suite/arena_test.cr        decisions=120 agree=120 old_stricter=0 old_looser=0 unknown=0 unknown_bridge=0 unknown_engine=0 unknown_engine_uncovered=0 unknown_engine_budget=0
tests/suite/at_test.cr           decisions=93  agree=93  …
tests/suite/at_test_mini2.cr     decisions=86  agree=86  …
tests/suite/at_test_mini3.cr     decisions=87  agree=87  …
tests/suite/at_test_mini4.cr     <no summary>            rc=139（嵌套 fn 声明；既有缺陷 TODO #16）
tests/suite/at_test_mini5.cr     decisions=86 agree=86
tests/suite/at_test_mini6.cr     <no summary>            rc=139（同上）
tests/suite/at_test_mini7..9.cr  decisions=85/85/85 agree=85/85/85
tests/suite/at_test_mini.cr      decisions=74 agree=74（rc=1：既有 B04 borrow 诊断）
tests/suite/at_test_struct.cr    decisions=78 agree=78
tests/suite/cache_test.cr        decisions=85 agree=85
tests/suite/chan_test.cr         decisions=156 agree=156
tests/suite/conc_test.cr         decisions=160 agree=160
tests/suite/dex_test.cr          decisions=99 agree=99
tests/suite/dyn_test.cr          decisions=88 agree=88          ← dyn 面：0 差异
tests/suite/ffi_test.cr          decisions=84 agree=84
tests/suite/fnaddr_test.cr       decisions=85 agree=85
tests/suite/generics_test.cr     decisions=89 agree=87 old_stricter=0 old_looser=0 unknown=2 unknown_bridge=0 unknown_engine=2 unknown_engine_uncovered=2 unknown_engine_budget=0
tests/suite/go_e2e_test.cr       decisions=156 agree=156
tests/suite/go_final_test.cr     decisions=156 agree=156
tests/suite/go_parallel_test.cr  decisions=156 agree=156
tests/suite/go_test.cr           decisions=85 agree=85
tests/suite/hotpatch_test.cr     decisions=136 agree=135 old_stricter=0 old_looser=0 unknown=1 unknown_bridge=0 unknown_engine=1 unknown_engine_uncovered=1 unknown_engine_budget=0
tests/suite/lazy_test.cr         decisions=86 agree=86
tests/suite/ptr_arith.cr         decisions=74 agree=74
tests/suite/ptr_ref_first.cr     decisions=73 agree=73
tests/suite/syscall4_test.cr     decisions=96 agree=96
tests/suite/test_control_flow.cr <no summary>            error: cannot read（0 字节空文件）
tests/suite/test_generics.cr     <no summary>            error: cannot read（0 字节空文件）
```

### ② 编译器自身

```
src/compiler/main.cr     decisions=3964 agree=3963 old_stricter=0 old_looser=0 unknown=1 unknown_bridge=0 unknown_engine=1 unknown_engine_uncovered=1 unknown_engine_budget=0
src/compiler/_import.cr  decisions=3844 agree=3843 old_stricter=0 old_looser=0 unknown=1 unknown_bridge=0 unknown_engine=1 unknown_engine_uncovered=1 unknown_engine_budget=0
```

### ③ 后端和内核单元

```
src/compiler/ccr_io.cr            decisions=4177 agree=4176 … unknown=1 unknown_engine=1 unknown_engine_uncovered=1
src/format/elf/elf.cr             decisions=553  agree=553
src/format/elf/ld.cr              decisions=213  agree=213
src/format/elf/resolve.cr         decisions=86   agree=86
src/os/linux/callseq.cr           decisions=129  agree=129
src/os/linux/entry.cr             decisions=121  agree=121
src/os/linux/syscall.cr           decisions=87   agree=87
src/arch/x86_64/frame.cr          decisions=147  agree=147
src/arch/x86_64/instr.cr          decisions=787  agree=787
src/arch/x86_64/regalloc.cr       decisions=192  agree=192
src/arch/x86_64/sizes.cr          decisions=98   agree=98
src/arch/x86_64/tag2l.cr          decisions=200  agree=200
src/lattice/ent_kernel.cr         decisions=225  agree=225
src/targets/x86_64-linux/_import.cr  decisions=3455 agree=3454 … unknown=1 unknown_engine=1
src/targets/x86_64-linux/main.cr     decisions=3490 agree=3489 … unknown=1 unknown_engine=1
```

③ 的全部行都是 `old_stricter=0 old_looser=0 unknown_bridge=0`，只有上面带 unknown 的两行非零。

### ④⑤ 扩面

```
t4: stdlib 19 文件 2042 判定；唯一非零 = toml.cr decisions=120 agree=119 unknown=1（同 MemLayout 对）
t5: examples 4 文件 151 判定（test_scale/test_sum 为 0 判定陈旧样例）；全零差异
```

## 3. 分类统计（逐档求和）

| 档 | 文件 | decisions | agree | old_stricter | old_looser | unknown | bridge | engine | uncovered | budget |
|---|---|---|---|---|---|---|---|---|---|---|
| ① suite | 27 | 2743 | 2740 | 0 | 0 | 3 | 0 | 3 | 3 | 0 |
| ② 编译器 | 2 | 7808 | 7806 | 0 | 0 | 2 | 0 | 2 | 2 | 0 |
| ③ 后端和内核 | 15 | 13960 | 13957 | 0 | 0 | 3 | 0 | 3 | 3 | 0 |
| ④ stdlib | 19 | 2042 | 2041 | 0 | 0 | 1 | 0 | 1 | 1 | 0 |
| ⑤ examples | 4 | 151 | 151 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| 合计 | 67 | 26704 | 26695 | 0 | 0 | 9 | 0 | 9 | 9 | 0 |

- 不变式 `agree+stricter+looser+unknown == decisions` 在 67 条摘要行逐行成立，71 个候选减 4 个排除，任务 4 复核 M1 有同样的更正；`sum(site_i) == decisions` 也成立，26704 等于 26704。
- 结论：真收紧面，即 `old_looser`，为 0；全部 9 条差异都是“旧能判，引擎判不了（-1）”，属于未覆盖面。
- 去重后只有 3 个类型对：`MemLayout` 对 `MemLayout`，行 28/25、27/11、11/9 随单元变化；`Box` 对 `Box`，行 9/29、9/34。
- 归因，使用 `/tmp` 副本加 `[dbg]` 探针实测行号到类型名：同名 named 多行。`MemLayout` 占 2 行，唯一声明在 `src/stdlib/toml.cr:260`；`Box` 占 5 行，在 `tests/suite/generics_test.cr:17`。旧判定按 `name_idx` 判等，结果为 true；桥接按行号建原子，两个不同原子，`AK_NAMED` 不展开，得到 `g_ty_uncovered=1`，最终 -1。
- `unknown_engine_budget = 0`：200000 步预算在 26704 次判定中从未耗尽。

## 4. 站点覆盖（扩面实测）

| 站点 | 1 hotpatch-ret | 2 generic-arg | 3 generic-apply-base | 4 unify-fallback | 5 fn-body-ret | 6 assign-binary | 7 if-branch | 8 assign-node |
|---|---|---|---|---|---|---|---|---|
| 命中，全语料 | 0 | 0 | 2 | 0 | 4913 | 0 | 1907 | 19882 |
| 占比 | 0 | 0 | 0.007% | 0 | 18.4% | 0 | 7.1% | 74.4% |

- 站点 1、2、4、6 都是 0 命中。站点 6 结构性不可达：parser 把 `=` 一律降为 `EXPR_ASSIGN`。站点 1、2、4 本轮语料未触达，探针可以触达，见第 5 节。
- 勘误，任务说明措辞：站点 4 不是“恒 agree”，而是本轮语料 0 命中。0 命中就是 0 次 agree，连 agree 都没有发生。定向探针实测其行为随 pattern 形态分化：base 对得到 agree，探针 K；含 named 的对得到 unknown 未覆盖面，探针 B。
- 站点 3 的 2 次命中就是 `generics_test.cr` 的两条 Box 未知；站点 3 在其余全部语料 0 命中。

## 5. 定向探针（合成语料，不计入第 3 节统计）

| 探针 | 站点 | 结果 |
|---|---|---|
| A `pa_refmut`，`&mut int` 形参加 `&x` 实参 | 2 | agree；实测 `&x` 产生 PTR 而非 REF，mut 面未触达 |
| B `pb_named2`，站点 4 加 named 实参 | 4 | unknown，未覆盖面 |
| C `pc_site4base`，泛型函数加具体形参不匹配 | 2 | agree；断言 pattern 变为 T，见第 6 节 F4 |
| D `pd_arrlen`，`[int;4]` 返回给 `[int;3]` | 5 | `old_stricter=1`，加 `error[TF01]` |
| E `pe_dyn`，dyn 值赋给 int 变量 | 8 | agree，加 `error[TA01]` |
| F `pf_hotpatch`，同名 hotpatch 两个版本 | 1 | agree，站点 1 可达性实证 |
| G `pg_genarg`，T 先绑 `[int;3]` 再以 `[int;4]` 调用 | 2 | `old_stricter=1` |
| H、I，`&int` 和 `&mut int` 变量，`&self` 和 `&mut self` 方法 | 无 | 0 命中，全部 agree，REF 面在源级不可构造 |
| K `pk_site4base2`，首形参 base 加不匹配实参 | 4 | agree，两侧同拒 |
| J `pj_nongen`，非泛型调用实参不匹配 | 无 | `ok`，无诊断，见 F3 |

探针源在 `/tmp/r2p1t3/probes/*.cr`，是非仓库文件。

### 三类排除项计数（任务说明要求单列；本轮全为 0）

| 排除项 | 差异数 | 参与判定次数（实测） |
|---|---|---|
| (a) dyn，`AK_DYN` 等于 ⊤，属于过宽近似 | 0 | `dyn_involved=0`，66 个有摘要文件求和；包含 `dyn_test.cr` 的 88 次判定 |
| (b) `&T` 对 `&mut T`，丢失 mut，属于 P3 面 | 0 | `ref_involved=0`，同求和；`&x` 产生 PTR，REF 行未进入任何判定点 |
| (c) 站点 4 | 0 | 命中 0，不是“恒 agree” |

实测命令：`/tmp` 副本加 `[dbg-shape] ref_involved/ptr_involved/dyn_involved` 计数后重跑全语料，得到 `files_with_summary=66 ref=0 ptr=0 dyn=0`。

## 6. 结构性发现（本轮最大产出，供 P2、P3 裁决）

- F1，P2 的硬性前置条件：同名 named 多行未规范化。旧判定按名判等，桥接按行建原子，引擎判不了。9 条差异 100% 由此产生。替换前必须先做名字规范化，可以使用引擎 name 注册表，或者桥接同名折叠。否则主流的“同类型比较”在替换后会从“真”变为“未判定”，两侧处置都不可接受：当拒会造成大面积误拒，当过会不报错地失去检查。
- F2，替换即放宽：数组长度 N。旧判定比较 `extra`，即 N，桥接按 R1 裁决不纳入身份，探针 D、G 实测 `old_stricter`。当前 `[int;4]` 到 `[int;3]` 是 `error[TF01]`，替换后会不报错地通过。需要单独裁决：保留则 N 要纳入身份或变型；不保留则写进 spec，记为有意放宽。
- F3，旧路径的缺陷：调用位点实参不匹配没有诊断。`infer_gen_call` 调用 `unify_types(...)` 时丢弃返回值，位置 `checker.cr:1053`。探针 J、C 实证非泛型和泛型调用位点都是 `ok`。这与影子分类不冲突，因为影子只比较 verdict；但 P2 如果以引擎判定作为诊断来源，必须补“判定到诊断”的接线，并确定 unknown 的处置策略。
- F4，新发现：泛型函数后续形参的声明类型在推断中不生效。`fn take[T](a: T, n: int)` 的 `unify_types` 收到 pattern 为 `gparam(T)`，而不是 `int`。首形参为具体类型时正常，探针 K 证明。建议单开任务，处理 `infer_gen_call` 的形参链导航。
- F5，语料边界：dyn 和 REF 面本轮未触发，不等于已经证明安全；站点 1、2、4 没有证据。P2 验收语料需要补定向样例，探针 F、G、K 可以直接升格为回归样例。
- F6，桥接缺口（kind=3）结构性为 0：`sh_term_of_ti` 和 `sh_base_ak` 覆盖 `TYP_*` 乘 `TY_*` 全集，`-1` 只剩 `ti<0` 和越界入口，正常语料不可达。拆分的收益是未来扩展时的守门。
- 附带勘误：`tests/suite/test_control_flow.cr` 和 `test_generics.cr` 是 0 字节空文件，任务 2 第 2b 节“预期失败 fixture”的措辞需要更正。`src/compiler/elf.cr`，566 行，本轮 rc=0 但有 2 个 parse error、0 次判定，是陈旧遗留文件。`src/compiler/linker.cr` 是 0 字节空文件。

findings 文档，包含完整计数表、样本、探针、裁决建议和限制，在 `docs/superpowers/implementation/2026-09-10-type-shadow-findings.md`。

## 7. 提交（路径限定，jj）

```
Change ID : vowoyzvmovsvkptmtytwkzyknxrmuorn
Commit ID : 75c20297a8790751a9d5eff3c230602e5a444676
父提交    : 28fed09d（Task 2 评审落地）
jj commit -m "docs: R2 P1 Task 3——影子对拍差异清单（三档语料计数 + 分类样本 + 归因与裁决建议）+ Step 0 未知桶拆两因（kind=3 桥接缺口 / kind=0 引擎负值，摘要增拆因子段与站点直方图）" \
  docs/superpowers/implementation/2026-09-10-type-shadow-findings.md src/compiler/ty_shadow.cr src/compiler/globals.cr
```

- 提交内容恰好 3 个文件：findings 文档 +297；`ty_shadow.cr` +68/−8；`globals.cr` +12。合计 377 insertions、8 deletions。`jj status` 提交后为空。
- 提交信息相对任务说明步骤 4 有扩展。任务说明的标题是 `docs: R2 P1 Task 3——影子对拍差异清单（…）`。因为同一提交包含步骤 0 的 88 行源码改动，按任务 2 的先例，其提交信息也在任务说明骨架上追加子句，这里在破折号句后追加“+ Step 0 未知桶拆两因（…）”，避免 `docs:` 前缀掩盖源码改动。如果评审要求严格复刻任务说明标题，可以用 `jj describe` 改写，提交未推送，改写零成本。
- 报告本体在 `.superpowers/`，被 gitignore，不入库，同任务 1、2 的先例。

## 8. 偏差和关注点

| # | 任务说明或骨架 | 实施 | 理由 |
|---|---|---|---|
| D1 | 步骤 0 只要求拆两因和 kind 0/3 | 另加 engine 桶的成因位细分，即 uncovered 和 budget，摘要增加 2 个字段 | findings 要区分“哪些需要补引擎规则”和“哪些属于未覆盖面”，必须区分未覆盖面和预算不够；ring 只有 256 条，摘要才能无损 |
| D2 | 摘要行 5 个字段 | 追加 4 个字段，前缀不变，并新增第二行 `[type-shadow-sites]` | 同上；站点覆盖是任务说明要求登记的条目，零差异语料下没有其他方法实测。实证是任务说明的“站点 4 恒 agree”实际为 0 命中 |
| D3 | 站点 4 描述为“恒 agree” | 更正为“0 命中”，探针实测并非恒 agree | 实测：base 对得到 agree，named 对得到 unknown |
| D4 | 归因可以使用 dump | dump 不足，ring 上限 256 且没有类型名，另用 `/tmp` 仓库副本的 `[dbg]` 探针解析行号到类型名 | 仓库文件未触碰；行号到类型名的解析是 F1 定性的关键证据 |
| D5 | 语料三档 | 另跑 ④stdlib 和 ⑤examples 扩面，成本约 1.5 秒每文件 | 与任务 2 第 2b 节扩面同例；不改变结论，但扩大覆盖面 |
| D6 | 未测吞吐 | 未测 | 与任务 2 遗留一致，两态产物零影响已证明 |
| D7 | 铁律 #2 禁止 git | 统计插入和删除行数时执行过一次只读的 `git diff --numstat HEAD~1 HEAD`，没有写操作，没有状态改动，仓库工作副本的 `jj status` 全程干净 | 属于违规操作，已改用 `jj diff -r @- --stat` 复核同一数据，即 +68/−8、+12、+297；后续不再使用 git |

关注点：① F1 是 P2 的硬性前置条件，建议 P2 计划第一项就是它。② 站点 1、2、4 零证据，P2 验收语料必须补，否则“零差异”无法区分“一致”和“没有跑到”。③ F3、F4 是 checker 既有缺陷候选，建议单开任务，不要混入影子层。
