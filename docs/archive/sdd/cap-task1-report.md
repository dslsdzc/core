# 容量批 T1 报告：前置侦查、冻结基线重建、起点判据、三面失败现状

日期：2026-09-14。任务为计划 `docs/superpowers/plans/2026-09-15-capacity-batch.md` 的任务 1，步骤 1 到 6。
工作地：`/tmp/p7wt`（jj workspace）。证据：`/tmp/capt1/**`。主树 `/home/DslsDZC/core/**` 零写入。仓库源零改动，收工时 `jj status` 为 no changes。
纪律：全部使用 `nice -n 19`，一构建一编译串行，每段前用 `ps` 实查，比较前 `clean-cache`，CI 和扫描期间不碰源，未 commit、restore、rebase。`rebuild.sh` 内部的一次 `jj workspace add` 和 `forget` 随其 `trap` 收尾，属于该脚本的设计行为。
修订：`@` 为 `ce2c5e85`，空工作副本；`@-` 为 `661ae569`，等于容量批计划 `5fe26e73` 加 fail-closed 计划 `661ae569`，两个文档提交叠在 P6 终态 `97f4394f` 之上。

## 0. 摘要和一条重要自我更正

| 项 | 结论 |
|---|---|
| P6 终态树的组成，更正 | `jj diff --from 97f4394f --to @- --stat` 显示只有 2 个文件新增，0 修改，0 删除，即两份 2026-09-15 计划文档。因此当前树的构建输入与 P6 终态树逐字节相同。我在计划里写“本树含 P6 记录之后的修复（TODO #8/#25/#5）”，这个推断是错的。那些修复，包括 `test_params_limit.py`、`MAX_FN_PARAMS=64`、`CIR_CACHE_VER=17` 等，本来就在 `97f4394f` 之内，本实例用 `jj file list -r 97f4394f` 和 `jj file show -r 97f4394f` 实核过。结论反而不变而且更强：P6 记录值与本树逐项相符，下方对照表 14/14 全同，P6 记录值可以作为本批起点 |
| 表 A 冻结基线重建 | `rebuild.sh` rc=0，三个 sha 逐条等于允许清单（`5d2b15ad…`、`493dc490…`、`18b94bd9…`），冒烟 rc=42，耗时 27s。停条件未触发 |
| 表 B 起点判据 | 五个 CI job 全 rc=0；全枚举 58/58；`check src/compiler` rc=0；`selftest-types` 415/415；canary `95084e7b…d475`（28822B）；`.ccr` 四条 96015、96158、142793、142936，差恒为 143B，暖态四条与冷态逐字节相同；`--dump-objects` 3521 行 ×2；`.cir` DOT 165915B `b1bdf480…`；自举链 `corec2==corec3` 为 `0b2e06d0…`，N06=0，冒烟 42，`--help` rc=1；构建确定性 ×2，三个 sha 两次相同；72 档 34×0、38×1 零差异；探针 29 档 17×0、12×1 零差异；`test_optional` 34/34；`test_enum_limit` 13/13。与 P6 记录 14/14 全同 |
| 表 E 三面失败现状，新测 | E-2 四面，包括字段、数组元素、全局槽、match 结果：裸值在 ELF 和解释器双路径都是 139，装箱为 5，全部明确报错，零不报错地；E-3 16 边界通过，17 越界触发 P22、P23 硬错且无产物；E-4 可选程序 build rc=0 且缓存零条目，非可选对照为 16 条目 |
| 停条件 | ① 重建 sha 不符允许清单，未发生；② 与 P6 记录冲突，未发生，全同；③ 被迫改源，未发生，零源码改动 |

## 1. 表 A：冻结基线重建（步骤 1）

### 1.1 配方执行（唯一许可的产生方式）

```
$ ps -eo comm | grep -E '^(corec|corearch|corelsp|cc1|as|ld|python3)$'   # 0 命中（串行前置检查）
$ nice -n 19 bash tools/baseline/rebuild.sh /tmp/capt1/base
[1/4] 检出 pinned revision 9bcb7083 → /tmp/p6-baseline.XXXXXX/src
[2/4] 构建 …… [GUARD] … error[ = 0 行数 = 3
[3/4] sha256 对白名单
  OK corec 5d2b15ad746018619b01143cce400e6f3489ae72a962e12283a7afd3dcdb41e7
  OK corearch 493dc490dfaed7774b46b74ccf1cfeca9fe5f61620e34229afb8991b1628a2a7
  OK corelsp 18b94bd955fa204accf0753095a28f6499871566254d846333a7496c99109d49
[4/4] 拷贝到 /tmp/capt1/base + 冒烟 … OK smoke rc=42
DONE 冻结基线 = /tmp/capt1/base（三 sha 与白名单逐条同；源修订 9bcb7083）
real 27.0s
```

逐条等于允许清单，允许清单值在 `tools/baseline/REBUILD.md` 表中，冒烟 42。`/tmp/capt1/base` 就是本批判定面回归网路径①的“pre 侧”二进制。

### 1.2 允许清单换代（建议，未执行。T1 纪律“零仓库改动”）

`REBUILD.md` 的“换代纪律 1/2”规定：基线换代时，下一批以本批收尾为 pre 侧，旧值留痕。建议换代如下：

| 项 | 旧 | 新（建议） | 依据 |
|---|---|---|---|
| `PINNED_REV` | `9bcb7083`（P4 收尾） | `97f4394f`（P6 终态，本批起点） | 批内对拍应以本批起点为 pre 侧 |
| 三个 sha 允许清单 | `5d2b15ad…`、`493dc490…`、`18b94bd9…` | `ae01de75…`、`228f82e9…`、`90eb19c6…`（下表 1.3 实测） | 同源重建等于确定性构建，×2 已实测 |

未实测项，如实登记：换代后的 `rebuild.sh` 复跑未执行，因为纪律禁止新建 workspace，不能跑第二次 `jj workspace add`。改用树等价证明：`jj diff --from 97f4394f --to @- --stat` 为“2 files changed, 662 insertions(+), 0 deletions(-)”，两个文件都是 `docs/superpowers/plans/*.md`，不是构建输入。因此从 `97f4394f` 重建必然得到与 1.3 相同的三个 sha，构建确定性已 ×2 实测，且与 P6 T5 记录值相同。换代实施，即修改 `REBUILD.md`，留给提交面。

### 1.3 当前树构建（步骤 1 后段；本批起点二进制）

```
$ nice -n 19 python3 build_selfhost_native.py >| /tmp/capt1/build1.log   # rc=0, 15.4s
$ sha256sum build/{corec,corearch,corelsp}
ae01de7534ea8428e3e062fccbc5fef5d45abfc5d3dafb90b3c85e08f354cce2  build/corec      (1852720B)
228f82e948cfaf8170ada982d80f1ebddfd3847e71cdf04ca4b42d9226373d2e  build/corearch   (1075432B)
90eb19c6d3bd4e3234b4328d8b8f3284cca6d1644d3959bb83f07b7e71473032  build/corelsp    (992952B)
$ nice -n 19 python3 build_selfhost_native.py >| /tmp/capt1/build2.log   # 第二次（确定性 ×2）
$ sha256sum build/{corec,corearch,corelsp}   # ⇒ 与上三 sha 逐字节同（build2 rc=0）
```

与 P6 T5 记录值逐条相同。记录在 `plans/2026-09-14-r2-p6-tail.md` 任务 5：重建得到 `corec ae01de75…`、`corearch 228f82e9…`、`corelsp 90eb19c6…`，与编辑前逐字节相同。因此起点二进制身份成立。

## 2. 表 B：起点判据（步骤 2），实测与 P6 记录对照

命令口径：cwd 为 `/tmp/p7wt`；`CC = nice -n 19 ./build/corec`；逐段用 `ps` 实查，0 命中；比较前 `clean-cache`。原始输出在 `/tmp/capt1/t1b.out`、`/tmp/capt1/{ci_*.log,check_self.log,selftest.log,canary.log,*_ccr.log,enum_list.txt}`。

| # | 判据 | 命令（摘要） | 实测 | P6 记录 | 判定 |
|---|---|---|---|---|---|
| 1 | 五个 CI job | `CI_JOB_NAME=<j> nice -n 19 bash src/ci/run.sh`，j 为 check、bootstrap-tests、suite、selfhost-tests、full-bootstrap | 全 rc=0；日志尾为 `ok`、`3/3 passed`、`ALL PASS`、`29/29 passed`、链段通过 | 全 rc=0 | 相同 |
| 2 | `check src/compiler` | `$CC check src/compiler` | rc=0，`[5/5] frontend done` 加 `ok` | rc=0 | 相同 |
| 3 | `selftest-types` | `$CC selftest-types` | rc=0，`415/415 type-engine cases passed` | 415/415 | 相同 |
| 4 | 全枚举 | `for f in tests/selfhost/test_*.py tests/bootstrap/*.py`，51+7 | 58/58 rc=0，`/tmp/capt1/enum_list.txt` 有逐档名单，非零 0 行 | 58/58 | 相同 |
| 5 | 构建确定性 ×2 | 1.3 的两次构建 | 三个二进制和日志相同 | ×2 | 相同 |
| 6 | 自举链 | full-bootstrap job 加复核 | `corec2 == corec3` 为 `0b2e06d0c8b2f78402d08950364fb224db697fdf2e5b6e5d0d6a06e85fc581c1`（2880022B）；`grep -c -F 'error[N06]' ci_full-bootstrap.log` 为 0；`/tmp/corec3 --help` rc=1；corec3 冒烟 rc=42；repo corec 冒烟 rc=42 | `0b2e06d0…` 加 N06=0、冒烟 42、`--help` rc=1 | 相同 |
| 7 | ELF canary，硬性要求 | `clean-cache`，然后 `build tests/suite/ptr_arith.cr --static -o /tmp/capt1/pa` | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`（28822B） | 同值，28822B | 相同 |
| 8 | `.ccr` 两口径四条，冷态 | `ccr F -o O` 和 `build F -o O --static`，各自 `clean-cache`，static 取 `O.ccr` | pa 96015B `680a6f98…`；pa_st 96158B `76f36e6a…`；gt 142793B `41e9d845…`；gt_st 142936B `704316c8…` | 同四条 | 相同 |
| 8b | 口径差恒为 143B | 96158−96015=143；142936−142793=143 | 无 | 143 | 相同 |
| 8c | `.ccr` 暖态，无 `clean-cache` 第二跑，本轮新增测量 | 同上四条重跑 | pa 96015 `680a6f98…`；pa_st 96158 `76f36e6a…`；gt 142793 `41e9d845…`；gt_st 142936 `704316c8…`。暖态与冷态逐字节相同，四条全部 | P6 未记暖值 | 新增，登记 |
| 9 | `--dump-objects` | `corearch {gt.ccr,gt_st.ccr} --dump-objects` | 两口径各 3521 行；`gt_do.txt` 与 `/tmp/p5t5/gt_do.txt` IDENTICAL | 3521 行 | 相同 |
| 10 | `.cir` DOT | `clean-cache`，然后 `ccr cir tests/suite/generics_test.cr -o gt.cir` | 165915B `b1bdf480d1c1defbd6093d3eeec03bba0d853f53997a9678d67a9d81efebaee0` | 同值 | 相同 |
| 11 | 72 档同源对拍 | `parity_run.sh /tmp/capt1/base/corec …/parity_frozen` 对 `…/build/corec …/parity_post` | 两侧 34×0、38×1；`diff -rq logs` 零输出 | 34×0、38×1 | 相同 |
| 12 | 探针 29 档 | `probes_run.sh` 两态 | 两侧 17×0、12×1；`diff -rq` 除 `*.out` 外零输出 | 17×0、12×1 | 相同 |
| 13 | `test_optional` | 枚举内 | 34/34 通过 | 34 | 相同 |
| 14 | `test_enum_limit` | 枚举内 | 13/13 通过 | 13 | 相同 |

结论：14/14 全同，P6 记录值就是本批起点基线值，无需另行更新基准值。唯一新增量是 `.ccr` 暖态四条，见 8c：本树这两个档位冷态等于暖态，逐字节相同，可供 E-4 和 T4 的冷热判据直接引用。

## 3. 表 C：语料和探针清点，以及 `tests/suite/*.cr` 逐档诊断面（fail-closed 线输入）

### 3.1 语料 72 档，探针 29 档

- 72 档的构成和 rc 分布：`parity_post/parity.out` 共 72 行，34×0、38×1，与 P6 T0 表 C 逐档相同，`diff -rq` 零输出对 P6 记录也成立，两态就是本树和冻结基线。
- 探针 29 档：`probes_post/rc.txt`，17×0、12×1，`diff -rq` 零输出。
- 原始路径：`/tmp/capt1/parity_{frozen,post}/logs/*.{log,rc}`、`/tmp/capt1/probes_{frozen,post}/`。

### 3.2 `tests/suite/*.cr` 逐档（`/tmp/capt1/t1c.out`；命令为逐档 `check`，有诊断的再 `build --static`）

| 档（32） | check rc | build rc | 产物 | 诊断码 | 归类 |
|---|---|---|---|---|---|
| 22 档：arena_test、at_test、mini2/3/5/7/8/9、at_test_struct、cache_test、dex_test、dyn_test、ffi_test、fnaddr_test、generics_test、go_test、hotpatch_test、lazy_test、params_many、syscall4_test | 0 | 无 | 无 | 无 | 干净 |
| at_test_mini4、at_test_mini6 | 1 | 1 | 无 | P21 | 硬拒，嵌套 fn |
| at_test_mini | 1 | 0 | ELF 和 ccr | N06 | 诊断不阻 build |
| chan_test、conc_test、go_e2e_test、go_final_test、go_parallel_test，共 5 档 | 1 | 0 | ELF 和 ccr | TF01 | 诊断不阻 build |
| ptr_arith | 1 | 0 | ELF 和 ccr | B04 | 诊断不阻 build，canary 检查本身 |
| ptr_ref_first | 1 | 0 | ELF 和 ccr | TB01、TF07 | 诊断不阻 build |
| test_control_flow、test_generics | 1 | 1 | 无 | 0 字节 fixture，无边码诊断 | 既有失败 |

非硬名单诊断面，也就是 fail-closed 线中“裸反转后会转红”的集合：8 档，包括 `at_test_mini`(N06)、`chan_test`(TF01)、`conc_test`(TF01)、`go_e2e_test`(TF01)、`go_final_test`(TF01)、`go_parallel_test`(TF01)、`ptr_arith`(B04)、`ptr_ref_first`(TB01+TF07)。它们都在 `check` 面 rc=1，而 `build` 面 rc=0 且有产物。硬名单码 R002、TK05、TK06、TS01-04、TK02、TM03、ICE04、TA02 在本 tier 零命中，判据是 `main.cr:150-175` 六条语句覆盖的 11 个常量，逐档码串比对。

### 3.3 全 72 档：`check` 日志含 `error[` 的档（36 档加 2 个零字节）

- t1，10 档：上表 8 档加 `at_test_mini4/6`(P21)；另 2 档是零字节 fixture，没有边码诊断。
- t2，1 档：`src/compiler/_import.cr`(N06)，单独 check 本该由 concat 供货。
- t3，13/15 档：N01、N06、TA01、TB01，属于库单元单独 check 的既有形态，P6 T0 第 3.1 节已划界。
- t4，12/19 档：N06、N11、N01、TF01，同族。
- 逐档码串原始件：`/tmp/capt1/t1c.out` 第三节，从 `parity_post/logs/*.log` 提取。

## 4. 表 D：定位点点实核（步骤 4），计划 8 条逐条复读当前树

| # | 计划条目 | 实核结果，当前树 | 判定 |
|---|---|---|---|
| 1 | `docs/archive/sdd/` 不在 `/tmp/p7wt` | `ls -d .superpowers` 不存在，jj-ignored；实体 `/home/DslsDZC/core/docs/archive/sdd/p6-task0-report.md` 在位 | 成立 |
| 2 | 本树含 P6 记录之后的修复 | 更正：所谓“之后”的修复全部在 `97f4394f` 之内。`jj file list -r 97f4394f` 实核 `test_params_limit.py` 等，`jj file show -r 97f4394f src/compiler/dyn_arr.cr` 为 `MAX_FN_PARAMS : int = 64;`，`cir_cache.cr` 为 `CIR_CACHE_VER : int = 17;`。`97f4394f..@-` 只有 2 个文档提交，`jj log` 和 `jj diff --stat` 双证 | 更正，结论方向不变：P6 记录值可用，已由表 B 实测确证 |
| 3 | `CIR_CACHE_VER` 实值为 17，提示词“18→19”不成立 | `src/compiler/cir_cache.cr:51: CIR_CACHE_VER   : int = 17;` | 成立 |
| 4 | `ast.cr` 镜像不一致面宽于登记，多 3 处 | `ast.cr:143/144/145` 的 `[string;64]`、`[int;64]`、`[int;64]` 对布局 16 槽，依据是 `dyn_arr.cr:98` 的 `OFF_SI_FIELD_TYPES=136` 减 `:97` 的 `OFF_SI_FIELD_NAMES=8` 等于 128B；`:147` 的 `generic_names:[string;16]` 对 `OFF_SI_GENERIC_COUNT(432)−OFF_SI_GENERIC_NAMES(400)` 等于 32B，即 4 槽；`:154` 的 `types:[int;64]` 对 `OFF_EV_SIZE(272)` 内的 16 槽；`:164` 同 `:147` 形态。另注：镜像类型的使用点为 0，`grep -rn ": StructInfo\|: EnumInfo\|: FuncInfo\b" src/` 零命中 | 成立，另加“疑为死声明”证据和使用点为 0 |
| 5 | 受护访问器区间为 `dyn_arr.cr:462-549`，P6 计划写 `:481-548` | 契约注在 `:518-528`；最后一个写护栏是 `:547 si_set_field_type_node`，从 `:462 fi_param_type` 起 | 成立 |
| 6 | 合批理由更正，E-2 推荐案不触布局 | 分析性条目，无需复测；本轮 E-2 探针（表 E）未见任何布局变更需求 | 维持 |
| 7 | E-4 机制未复现，`irv_rep` 读取点全在同函数生成内 | 静态：`grep -n "irv_rep(\|irv_set_rep(" src/compiler/ir_gen.cr` 得到 `:304/:1148/:1762/:1987/:2108/:2443/:2544`，全在 ir_gen 内；动态新增：可选程序 build rc=0 且缓存零条目，见表 E-3，“门生效”实测，机制仍须 T4 步骤 1 RED 实证 | 成立，另加新增实测 |
| 8 | `sh_match_bit` 的 63 是 i64 位宽边界 | `ty_shadow.cr:1204-1206` 头注原文“vi < 63 由 MAX_ENUM_VARIANTS = 16 保证不溢出，该前提自 R2 P4 Task 6 起由写入侧护栏强制”，`:1207` 循环乘 2 实现 | 成立 |

## 5. 表 E：三面失败现状（步骤 5，全部本轮新测）

命令：逐档 `clean-cache`，然后 `check`，再 `build --static`，再运行 ELF，使用 `ulimit -c 0` 和 `timeout 10`，最后 `run '$(cat F)'`。源为 `/tmp/capt1/probes/*.cr`，原始日志同目录。

### E-1 E-2 四面（裸值和装箱）

| 面 | 源（摘要） | check | build | ELF rc | interp rc | 判定 |
|---|---|---|---|---|---|---|
| 结构体字段，裸 | `s := S { a: 5 }; match s.a { Some(v) => … }` | 0 | 0 | 139 | 139 | 明确报错，双路径相同 |
| 结构体字段，装箱 | `s := S { a: Some(5) }` | 0 | 0 | 5 | 5 | 正确 |
| 数组元素，裸，赋值为实现方式 | `a : [int?;2] = [Some(5), None]; a[1] = 7; match a[1] {…}` | 0 | 0 | 139 | 139 | 明确报错 |
| 数组元素，装箱 | `a : [int?;2] = [Some(5), None]; match a[0] {…}` | 0 | 0 | 5 | 5 | 正确 |
| 全局槽，裸 | `g : int? = 5; match g { Some(v) => … }` | 0 | 0 | 139 | 139 | 明确报错 |
| 全局槽，装箱 | `g : int? = Some(5)` | 0 | 0 | 5 | 5 | 正确 |
| match 结果，裸 | `fn f(c:int)->int? { return match c { 0 => 5, _ => None, }; }` | 0 | 0 | 139 | 139 | 明确报错 |
| match 结果，装箱 | 同上，但臂为 `Some(5)` | 0 | 0 | 5 | 5 | 正确 |

附面，登记，不是本面靶：数组字面量直接写裸元素，即 `[5, None]` 或 `[None,None]` 后赋 7，在 `check` 就 rc=1 并报 TA02、TK02，属于数组同质性和声明位判定面。同属明确报错形态，但成因不同，不是表示位面。

测量口径注，已遇到问题并更正：ELF 崩溃态必须在 `ulimit -c 0` 或等价禁用 coredump 下测，否则 systemd-coredump 管道会让进程挂起，`timeout` 先杀，得到 rc=124，而不是 139。`tests/selfhost/test_optional.py` 的 `preexec_fn=_no_core_dump` 就是同一处理。

### E-2 E-3 边界

| 样本 | check | build | ELF | 诊断 |
|---|---|---|---|---|
| `enum E16`，16 变体加全臂 match，取 V9 | 0 | 0 | 9 | 无 |
| `enum E17`，17 变体 | 1 | 1 | 无产物，bin 和 `.ccr` 都没有 | `error[P22]: Enum has too many variants (17 > 16)` |
| `struct S17`，17 字段 | 1 | 1 | 无产物 | `error[P23]: Struct has too many fields (17 > 16)` |

### E-3 E-4 缓存门

```
$ ls .core/cache/cir | wc -l        # 0（前置）
$ build e4_opt.cr   --static        # 含 int? + Some ⇒ g_optrep_on=1；rc=0
$ ls .core/cache/cir | wc -l        # 0（零新增；grep -c e4_opt = 0）
$ build e4_plain.cr --static        # 无可选；rc=0
$ ls .core/cache/cir | wc -l        # 16（grep -c e4_plain = 16）
```

因此“可选程序关缓存”的门生效，位置 `main.cr:488-490`，非可选程序正常落条目。

## 6. 表 F：E-3 四条前置实核（步骤 5 后段；结论与计划一致，逐条补实测证据）

| 前置 | 结论 | 本轮证据 |
|---|---|---|
| ① 读回检查同步 | 未满足 | `ccr_io.cr:1203` 的 `fc > MAX_STRUCT_FIELDS ⇒ rc=1`，加 `:1245`、`:1272` 三检查，清零循环 `:1208-1219`、`:1250-1265` 硬编码 16 和 4。盘面已经变长，见 `:324/:332` 布局注和 `ccr_sym_seg_size`（`:309-336`）按 `si_field_count` 动态求和。因此只需改读回侧和进程内记录 |
| ② `ast.cr` 镜像归位 | 未满足，且比登记宽 3 处 | 见定位点点 #4；另“镜像类型使用点为 0”，归一或删除属于文档面，实施时须实证 bootstrap 侧处理 |
| ③ 覆盖位表示 | 未满足 | `ty_shadow.cr:1204-1213` 的 `sh_match_bit` 循环乘 2，63 前提自述；`checker.cr:3036` 的 `m_cover` 单 int 累积 |
| ④ 冷热 `.ccr` 与 canary 判据 | 未满足，判据须更新基准值或重设 | 本轮实测，表 B 的 7、8、8c：canary 和 `.ccr` 四条等于 P6 值，起点不变量成立；E-3 迁移后须逐条更新基准值，预期不变，但须实测 |

## 7. 停条件核查（步骤 6 前置）

| # | 停条件 | 结果 |
|---|---|---|
| ① | 重建 sha 不符允许清单 | 未触发，三条逐字符相同，冒烟 42 |
| ② | 判据与 P6 记录冲突 | 未触发，表 B 14/14 全同；唯一的“异”是我自己的推断被更正，见第 0 节 |
| ③ | 被迫改源才能测 | 未触发，零源码改动，`jj status` 为 no changes，`jj diff 97f4394f→@-` 只有 2 个新增 md |
| ④ | 既有失败档划界 | 沿用 P6 T0 第 3.1 节：0 字节 fixture 2 个、P21 负例 2 个、examples 解析错 2 个、库单元单独 check 25 个、TF01 族 5 个、TF07 1 个、B04 1 个，合计 38。本轮逐档复核无变化 |

## 8. 需要说明的事项（不不报错地）

1. 未测：`COREC_WARM_SELF=1` 的自源暖态 2 例，即 `test_cir_warm_path.py`，约 3 分钟，与 P6 T0 同一豁免；LSP 进程级会话，枚举 58/58 内 `test_lsp.py` rc=0 是间接佐证。
2. 未实测：允许清单换代后的 `rebuild.sh` 复跑，因为纪律禁止新建 workspace，改用 `jj diff` 树等价证明，见第 1.2 节，换代实施留给提交面。
3. 测量陷阱已登记：ELF 崩溃态 rc 需要 `ulimit -c 0` 才稳定为 139，coredump 管道挂起会得到 124。
4. `.ccr` 暖态是本轮新增测量，P6 只记冷态：本树 pa 和 gt 两档冷态等于暖态，逐字节相同。“非可选程序冷态不等于热态为预设豁免”在这两档上未观察到分歧，不作全局结论。
5. E-2 探针的“数组元素”实现方式选择：字面量形被 TA02、TK02 拦下，明确报错但成因不同，因此取赋值形作为实现方式，测得 139。该选择已写入文档，避免 T2 误用字面量形当 RED 证据。
6. 数字来源：本报告全部数字为本实例实跑，命令和原始输出见第 9 节路径；引用 P6 记录处都标了出处，并已用实测对照，见表 B。

## 9. 证据路径（`/tmp/capt1/`）

| 用途 | 路径 |
|---|---|
| 冻结基线产物 | `base/{corec,corearch,corelsp}`，`5d2b15ad…`、`493dc490…`、`18b94bd9…` |
| 当前树构建日志 | `build1.log`、`build2.log`，两次构建 rc=0，三个 sha 同 |
| 表 B 驱动和输出 | `t1b_criteria.sh`、`t1b.out`、`ci_{check,bootstrap-tests,suite,selfhost-tests,full-bootstrap}.log`、`check_self.log`、`selftest.log`、`canary.log`、`{pa,pa_st,gt,gt_st}.{ccr,bin}` 加 `*_w*.ccr` 暖态、`gt_do.txt` 和 `gt_st_do.txt`、`gt.cir`、`enum_list.txt` 加 `enum/` 的 58 份逐档日志 |
| 对拍 | `parity_{frozen,post}/` 72 档 logs 和 rc；`probes_{frozen,post}/` 29 档加 rc.txt |
| 表 C | `t1c_suite_table.sh`、`t1c.out`、`suitebuild/*.{check,build}.log` |
| 表 E | `t1d_probes.sh`、`probes/*.cr` 加 `*.{check,build,interp}.log` 和 `*.bin` |
| 判据原始件 | `pa`，canary ELF，28822B |

清理：`rebuild.sh` 内部的 workspace 已随其 `trap` forget 并删除临时目录，`jj workspace list` 没有 `p6-baseline-build` 残留，脚本自证；`jj status` 收工为 no changes；主树 `/home/DslsDZC/core/**` 全程只读。

## 10. 允许清单换代（执行记录；2026-09-14，维护者批准）

实施提交 `4607624c251d9894e7066cb027e5ef2161ae0db8`，路径限定为 `tools/baseline/REBUILD.md` 和 `tools/baseline/rebuild.sh`，`2 files changed, 23 insertions(+), 12 deletions(-)`。

- `rebuild.sh`：`PINNED_REV` 从 `9bcb7083` 改为 `97f4394f`；三个 `WHITELIST_*` 改为 `ae01de75…`、`228f82e9…`、`90eb19c6…`；允许清单块加换代注，旧三个 sha 的全值指向 `REBUILD.md` 历史表。
- `REBUILD.md`：允许清单表换成现行代，新增“允许清单历史”表，初代 `5d2b15ad…`、`493dc490…`、`18b94bd9…`（`9bcb7083`）与第 2 代并录，理由和出处逐条给出。

换代自证，本实例实跑，证据在 `/tmp/capt1/base_v2*`：

```
$ nice -n 19 bash tools/baseline/rebuild.sh /tmp/capt1/base_v2     # 29.1s
  OK corec ae01de75…  OK corearch 228f82e9…  OK corelsp 90eb19c6…
  OK smoke rc=42   DONE …（源修订 97f4394f）
$ nice -n 19 bash tools/baseline/rebuild.sh /tmp/capt1/base_v2b    # 78.0s（同配方，二次）
  OK smoke rc=42
$ for b in corec corearch corelsp; do cmp base_v2/$b base_v2b/$b; done   # ⇒ IDENTICAL ×3（确定性 ×2）
```

因此新基线可复现：三个 sha 对允许清单，冒烟 42，确定性 ×2，且与第 1.3 节的直接构建产物同 sha。树等价证明为 `jj diff --from 97f4394f --to 661ae569`，只有 2 个计划 md 新增。

批内用法：路径①的 pre 侧使用 `bash tools/baseline/rebuild.sh <dir>` 的产物，即现行代；T2 到 T4 开工前必须用本配方重新取得，不得沿用 `/tmp/capt1/base`（初代）或 `base_v2`（本次实跑件）等临时副本。
