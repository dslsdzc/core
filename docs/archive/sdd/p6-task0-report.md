# R2 P6 Task 0 报告：前置侦查 + 冻结基线重建

日期：2026-09-14 · 任务：`docs/superpowers/plans/2026-09-14-r2-p6-tail.md` Task 0（Step 1–6）
起点：`bc4f0a43`（P6 计划定稿；工作副本 `f90cf65e` 空）· 开工与收工双侧 `jj status` = 「no changes」实核（源码零改动、零提交）
纪律：cwd = 仓库根 · 全部命令 `nice -n 19` · 一构建一编译串行（每段前 `ps -eo comm` 实查）· 比较产物前 `clean-cache` · 版本控制仅 `jj`
产物：`/tmp/p6t0/base/{corec,corearch,corelsp}`（从 pinned `9bcb7083` 重建的冻结基线）· `/tmp/p6t0/head/{corec,corearch,corelsp}`（P6 起点二进制重建副本）· `/tmp/p6t0/*`（日志/sha/清点原始输出）· 本报告（工作区文件，不入提交）
未取裁项：裁决门四条（裁-P6-1..4）一律未实施（T0 不涉及；本报告只出侦查数字）

---

## 0. 摘要（摘要）

| 项 | 结果 |
|---|---|
| 表 A 冻结基线重建 | 三 sha 逐条 = 允许清单（`5d2b15ad…` / `493dc490…` / `18b94bd9…`）；与 `/tmp/p5t0/base/` `cmp` 逐字节 IDENTICAL ×3；构建确定性 ×2（二进制 + 构建日志逐字节同）；冒烟 rc=42。停条件未触发 |
| 表 B P6 起点判据 | 五 CI job 全 rc=0 · 全枚举 58/58 · `check src/compiler` rc=0 · `selftest-types` 404/404 · 构建确定性 ×2（`f737e26b…`/`544e9201…`/`4251108b…`）· 自举链 `corec2==corec3` `5559beef…` + N06=0 + 冒烟 42 + `--help` rc=1 · ELF canary `95084e7b…d475`（28822B）· `.ccr` 两口径四条 = 计划值 · `--dump-objects` 3521 行 ×2 · `.cir` DOT 165915B `b1bdf480…` |
| 表 C 语料/探针清点 | 72 档 = 32+2+15+19+4，rc 分布 34×0 / 38×1（与 P5 T7 `parity_post` `diff -rq` 零差异）；探针官方清点 = 29 `.cr`（11 + 18 + 0），P5 记录的「30 档」= 29 实档 + 1 条字面 glob 伪条目（第 3.2 节 证据）；`/tmp/p5t3b/probes` 的 27 件 `.log/.dump` 源未丢（源在 `/tmp/p5t3/probes`，已逐字节复现，第 3.3 节） |
| 表 D 定位点点实核 | 计划定位点点逐条实读；5 条变化 + 1 条码名口径差异（第 4 节） |
| 守门复验 | `test_optional.py` 34/34（未覆盖面裸值 `rc=-11` 双路径同 = 响亮；装箱正确）· `test_enum_limit.py` 13/13 · 越界样本（17 变体 / 17 字段）= P22/P23 定位硬错 rc=1 + 无产物（非不报错地） |
| 停条件 | ① 重建 sha 不符允许清单 因此 未发生；② 与 `/tmp/p5t0/base/` 不一致 因此 未发生 |

---

## 1. 表 A：冻结基线重建（Step 1）

### 1.1 检出（仓库工作树之外）

```
$ jj log -r 9bcb7083 --no-graph -T 'commit_id ++ " | " ++ description.first_line()'
9bcb7083402e1db47e7a8fa6aef30ec2bbaefcf0 | docs: R2 P4 Task 7 收尾（载体批 8 提交链收口），…

$ jj workspace add /tmp/p6t0/src --name p6t0-src --revision 9bcb7083
Created workspace in "../../../tmp/p6t0/src"
Working copy  (@) now at: usrqzzyr 51e926ec (empty) (no description set)
Parent commit (@-)      : nxnzrxtk 9bcb7083 docs: R2 P4 Task 7 收尾…
Added 555 files, modified 0 files, removed 0 files
```

工作副本 = 空提交叠在 `9bcb7083` 上 因此 树 = pinned revision 树；检出在 `/tmp/p6t0/src`（不在仓库根内）。用完 `jj workspace forget p6t0-src`（见 第 7 节）。

### 1.2 构建 ×2（`nice -n 19 python3 build_selfhost_native.py`，cwd = 检出根）

| # | 日志 | 时段 | rc | 结果 |
|---|---|---|---|---|
| 构建 1 | `/tmp/p6t0/build1.log` | 02:16:21 到 02:16:40 | 0 | `=== BUILD SUCCESS ===`；`[GUARD]` 行 ×7（其中 3 条 = `build log clean (error[ = 0, undefined = 0)`）；非 GUARD `error[` 0 |
| 构建 2 | `/tmp/p6t0/build2.log` | 02:16:55 到 02:17:07 | 0 | 同上；`cmp build1.log build2.log` 逐字节同（54565B） |

### 1.3 三 sha 对允许清单（逐条同）

```
$ sha256sum /tmp/p6t0/base/*
5d2b15ad746018619b01143cce400e6f3489ae72a962e12283a7afd3dcdb41e7  corec
493dc490dfaed7774b46b74ccf1cfeca9fe5f61620e34229afb8991b1628a2a7  corearch
18b94bd955fa204accf0753095a28f6499871566254d846333a7496c99109d49  corelsp
```
因此 与允许清单（计划 Step 1 给定值）三条逐字符相同。

### 1.4 与在位副本 `cmp` + 确定性 + 冒烟

```
$ cmp /tmp/p6t0/base/corec    /tmp/p5t0/base/corec    && echo IDENTICAL   # IDENTICAL
$ cmp /tmp/p6t0/base/corearch /tmp/p5t0/base/corearch && echo IDENTICAL   # IDENTICAL
$ cmp /tmp/p6t0/base/corelsp  /tmp/p5t0/base/corelsp  && echo IDENTICAL   # IDENTICAL
$ cmp /tmp/p6t0/src/build/corec /tmp/p6t0/base/corec  # 构建 2 vs 构建 1：IDENTICAL（×3）
$ nice -n 19 /tmp/p6t0/base/corec run 'fn main()->int{return 42;}'
smoke rc=42
```

结论：`/tmp/p5t0/base/` 与本轮重建物互为旁证（两者皆源出 `9bcb7083`）因此 计划停条件②不成立。冻结基线可复现性（E-13 前提）成立：配方 = `jj workspace add --revision 9bcb7083` + `python3 build_selfhost_native.py`。

### 1.5 P6 起点二进制的来源核验（表 B 的「构建确定性 ×2」）

同一配方在 head `bc4f0a43` 上复跑（`/tmp/p6t0/headsrc`，同样仓库外检出）：

```
$ sha256sum /tmp/p6t0/head/*
f737e26bf42fc3d1b8a921d545e0ab601bda154a91709509860f09775ea37d57  corec
544e9201af10de3c9c24853ac21b595ffe2ecd0927f2ed615a218cbf9921424f  corearch
4251108b04cf7fe1afb452b6a4e5fd8cbcc8eb5e9f345066fb865a2fd123dc07  corelsp
$ cmp /tmp/p6t0/headsrc/build/{corec,corearch,corelsp} /home/DslsDZC/core/build/{corec,corearch,corelsp}
（×3 IDENTICAL，构建 2 亦同）
```
因此 ① 与 P5 T7 记录值（`f737e26b…`/`544e9201…`/`4251108b…`）逐字节同；② `build/*`（仓库内在位副本）== 从 `bc4f0a43` 重建物 因此 「源码树 因此 二进制度」对应关系成立；③ head_build1.log == head_build2.log（逐字节，均 57784B）。

---

## 2. 表 B：P6 起点判据（Step 2；`/tmp/p6t0/t0b_criteria.sh`，输出到 `t0b.out`）

| # | 判据 | 命令 | 实测 | 计划期望 | 判定 |
|---|---|---|---|---|---|
| 1 | 五 CI job | `CI_JOB_NAME={check,bootstrap-tests,suite,selfhost-tests,full-bootstrap} nice -n 19 bash src/ci/run.sh` | 全 rc=0（`ci_*.log`） | 全 0 | 通过 |
| 2 | `check src/compiler` | `nice -n 19 ./build/corec check src/compiler` | rc=0（`[5/5] frontend done`） | rc=0 | 通过 |
| 3 | `selftest-types` | `nice -n 19 ./build/corec selftest-types` | rc=0 · `404/404 type-engine cases passed` | 404/404 | 通过 |
| 4 | 全枚举 | `for f in tests/selfhost/test_*.py tests/bootstrap/*.py`（51+7） | 58/58 rc=0（`enum_list.txt`，非零 0 行） | 58/58 | 通过 |
| 5 | 构建确定性 ×2 | 第 1.5 节 | 三二进制 + 日志逐字节同 | ×2 | 通过 |
| 6 | 自举链 | full-bootstrap job + 复核 | `corec2 == corec3 = 5559beef2abf…`（2854910B）· N06 计数 0 · `/tmp/corec3 --help` rc=1 · corec3 冒烟 rc=42 · repo corec 冒烟 rc=42 | 同 | 通过 |
| 7 | ELF canary（硬检查） | 先 `clean-cache`，再 `build tests/suite/ptr_arith.cr --static` | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`（28822B） | 同值 | 通过 |
| 8 | `.ccr` 两口径四条（冷态） | `corec ccr F -o O` / `corec build F -o O --static`（各 `clean-cache`） | pa ccr 90823B `fb4a3b59…` · pa `--static` 90966B `592afa31…` · gt ccr 135341B `ddec1ce6…` · gt `--static` 135484B `cd2af565…`（差恒 143B） | 同四条 | 通过 |
| 9 | `--dump-objects` | `corearch {gt.ccr,gt_st.ccr} --dump-objects` | 两口径各 3521 行；与 T5 记录 `cmp` IDENTICAL（`DO-GT`/`DO-GT-ST`） | 3521 行 | 通过 |
| 10 | `.cir` DOT | 先 `clean-cache`，再 `corec cir tests/suite/generics_test.cr -o gt.cir` | 165915B `b1bdf480d1c1defbd6093d3eeec03bba0d853f53997a9678d67a9d81efebaee0`，与 T5 记录 IDENTICAL | 165915B `b1bdf480…` | 通过 |

全部 10 项与计划期望逐条同（并含与 T5/T7 记录的 `cmp` 交叉证据）；`t0b_criteria.sh` 首行即记录 P6 起点三 sha，与 第 1.5 节 一致。

---

## 3. 表 C：语料与探针清点（Step 3）

### 3.1 语料 72 档（逐档实核 + rc 分布）

清单构成（`ls` 实核，与 P5 T0 第 1.2 节 相同）：

| 层 | 命令 | 实测档数 |
|---|---|---|
| t1 | `ls tests/suite/*.cr` | 32 |
| t2 自源 | `src/compiler/main.cr` + `_import.cr` | 2 |
| t3 后端/内核/目标 | `src/compiler/ccr_io.cr`（1）+ `src/{format/elf,os/linux,arch/x86_64,lattice,targets/x86_64-linux}/*.cr`（14） | 15 |
| t4 stdlib | `ls src/stdlib/*.cr` | 19 |
| t5 examples | `ls examples/*.cr` | 4 |
| 计 | | 72 |

rc 分布（P6 起点二进制 `./build/corec`，`/tmp/p3t0_run.sh check`，逐档 `clean-cache`）：

```
cd /home/DslsDZC/core && bash /tmp/p3t0_run.sh check ./build/corec /tmp/p6t0/parity_start/check
corpus runner rc=0
rc 分布（全 72）:   34 0 / 38 1
```
- 逐档明细：`/tmp/p6t0/corpus_rc.txt`（72 行）· 原始 runner 输出 `/tmp/p6t0/parity_start.out`（72 行 tab 记录）。
- 同源同比交叉：`diff -rq /tmp/p6t0/parity_start/check /tmp/p5t7/parity_post/check` 因此 零输出（与 P5 T7 收尾跑逐档 rc + 日志逐字节同）。

rc=1 的 38 档划界（逐档首条 error 行实取；全部为既有失败，不得当回归）：

| 类 | 档数 | 档（首条诊断；逐档首条 error 行实取） |
|---|---|---|
| 0 字节 fixture | 2 | `test_generics.cr` / `test_control_flow.cr`（`error: cannot read`） |
| P21 嵌套 fn 负例 | 2 | `at_test_mini4.cr` / `at_test_mini6.cr`（`error[P21]`） |
| examples 解析错 | 2 | `test_scale.cr` / `test_sum.cr`（`error: Unexpected token in expression`） |
| 库单元单独 check（N01/N06/N11，本该由 concat 供货） | 25 | t2 `_import.cr` 1 + t1 `at_test_mini.cr` 1（N06）+ t3 13/15（N01×5：frame/instr/regalloc/sizes/ent_kernel · N06×7：tag2l/elf/ld/resolve/callseq/entry/syscall · N11×1：ccr_io）+ t4 10/19（N06×5：assert/cli/hotpatch/os/trace · N11×4：chan/fmt/goroutine/sched · N01×1：collections） |
| TF01 返回型不匹配（并发/goroutine 族） | 5 | t1 `chan_test` / `conc_test` / `go_e2e_test` / `go_final_test` / `go_parallel_test` |
| TF07 实参类型 | 1 | t1 `ptr_ref_first.cr`（`@raw_int requires a dex (or int) expression`） |
| 借用诊断（非硬名单 因此 不阻 `build`） | 1 | t1 `ptr_arith.cr`（`error[B04] Cannot use 'x' while it is borrowed` 12:8），同一档 `build --static` rc=0 且产出 canary ELF（第 2 节#7）因此 E-14「非硬名单诊断不阻 build」的活证据 |
| 计 | 38 | = 12(t1) + 1(t2) + 13(t3) + 10(t4) + 2(t5) 通过 |

> 附注（本轮新读）：`t1_tests_suite_at_test_mini.cr` 的既有失败是 `error[N06]: Undefined function 'print'`（不是 P21 族）；P5 记录只点名 mini4/6 为 P21，与实读相符。

### 3.2 探针清点：官方值 = 29 `.cr`（U-4 收口）

```
$ for d in /tmp/p5t0/probes /tmp/p5t3/probes /tmp/p5t3b/probes; do
    echo "$d: $(find $d -name '*.cr' | wc -l) .cr / $(ls $d | wc -l) entries"; done
/tmp/p5t0/probes: 11 .cr / 32 entries
/tmp/p5t3/probes: 18 .cr / 62 entries
/tmp/p5t3b/probes: 0 .cr / 27 entries
$ find /tmp/p5t0/probes /tmp/p5t3/probes /tmp/p5t3b/probes -name '*.cr' | wc -l
29
```
逐档 sha256 清单：`/tmp/p6t0/probes_manifest.txt`（29 行）。

「30 档」的账（P5 记录 30、本轮实得 29 的原因，实读证据）：P5 T5/T7 的探针 rc 表有 30 行，其中一行是未展开的字面 glob：

```
$ cat /tmp/p5t7/probes_post/rc.txt | grep 'p5t3b'
_tmp_p5t3b_probes_*.cr	rc=1
$ cat "/tmp/p5t7/probes_post/_tmp_p5t3b_probes_*.cr.log"
error: cannot read /tmp/p5t3b/probes/*.cr
```
根因 = bash 未匹配 glob 时保留字面量（`/tmp/p5t4/run_probes.sh` 无 `nullglob`）：`for f in /tmp/p5t3b/probes/*.cr` 在零匹配目录上仍迭代一次，把模式串本身当文件名传 `check` 因此 得一条 rc=1 的伪条目（不是「不报错地空跑」，它产出一条恒等的错误条目；因两态都同样产生，`diff -rq` 对拍恒过 因此 该条对拍是空洞证据，与计划「不报错地空跑」口径一致但形态更精确）。正式清点值 = 29 `.cr`（11+18+0）；「30」此后不得引用（U-4 结论）。

本轮复跑（P6 起点二进制）：
```
$ bash /tmp/p5t4/run_probes.sh ./build/corec /tmp/p6t0/probes_start
--- 探针 rc 统计 --- 17 rc=0 / 13 rc=1（30 行，含 1 条字面 glob 伪条目）
$ diff -rq /tmp/p6t0/probes_start /tmp/p5t7/probes_post    # 零输出（与 P5 收尾逐字节同）
```

### 3.3 `/tmp/p5t3b/probes`（27 件 `.log`/`.dump`）三栏判定，源未丢，已实测复现

27 件 = 3 tag（`n13_arr_diff_named` / `n17_ptr_named` / `n18_tuple_named`）× 9 形态（`red.log/.red.dump/.post.log/.M1..M4.log/.M2.dump/.final.log`）。P5 T3b 报告 第 1 节（第 23 行）实读：「探针 = `/tmp/p5t3/probes/n13|n17|n18*.cr`」因此 三档探针源本就在 `/tmp/p5t3/probes`（18 档清单内含之），`p5t3b/probes` 只是 T3b 的输出目录。本轮以两个在位二进制实测复现：

```
# 失败态（pre-T3b 行为）：冻结基线 /tmp/p6t0/base/corec + 影子旗标（该二进制仍带旗标）
$ nice -n 19 /tmp/p6t0/base/corec check /tmp/p5t3/probes/n13_arr_diff_named.cr \
      --type-shadow --type-shadow-dump …/n13.frozen.dump
  n13: frozen-baseline.log == p5t3b red.log （归一化 dump 路径行后逐字节同）
  n13: dump 逐字节同            # n17 / n18 同款：3/3 log 同 + 3/3 dump 同
# post/final 态（P6 起点行为）：当前二进制（影子通道已下线 因此 去掉 shadow 行后比）
  n13/n17/n18: cur-binary（去 shadow 行）== p5t3b final.log（去 shadow 行）   # 3/3 同
```

| 栏 | 件数 | 依据 |
|---|---|---|
| 可复原·逐字节（red 态） | 6 = `{n13,n17,n18}.red.log`（3）+ `.red.dump`（3） | 冻结基线 `5d2b15ad…` + `/tmp/p5t3/probes/{n13,n17,n18}.cr` 实测 `cmp` 逐字节同（log 归一化 dump 路径行后、dump 直接同） |
| 可复原·rc/诊断面 | 6 = `{n13,n17,n18}.final.log`（3，实测 3/3 同）+ `.post.log`（3，同源推断，未逐件 `cmp`） | P6 起点二进制（去 `[type-shadow*]` 行）比较；影子行不在比对面 |
| 需重建（须先复造变异二进制） | 15 = `.M1..M4.log`（12）+ `.M2.dump`（3） | 变异态 = T3b 第 3.3 节的 4 条突变；配方在 T3b 报告，变异二进制不在位 |
| 计 | 27 通过（21 log + 6 dump） | |
| （内容级）不可复原 | 42 行 shadow 摘要（21 个 `.log` × 2 行；`grep -l '^\[type-shadow'` = 21，`grep -c` Σ = 42） | 影子通道已随 P5 T5 删除（`--type-shadow` 旗标不存在）：red 态计数可由冻结基线重产，final/post/M\* 态计数无二进制可产 |
| 源丢失 | 0 件 | 29 `.cr` 全在位（含 3 tag） |

> 对计划「探针语料已开始腐坏 / T3b 残留探针源已丢」的修正：腐坏面 = 只有 `/tmp/p5t3b/probes` 的输出目录无 `.cr`（它从来是输出目录）；源档全在位。E-13 的「探针腿退化」仍成立但形态不同：退化的是 runner 的字面 glob 伪条目（第 3.2 节）与配方无实现方式（入仓后即可闭合），不是源丢失。Task 1 的探针入仓 = 29 档实拷 + 3 tag 的复现配方（无需重建源）。

---

## 4. 表 D：任务定位点点实核（计划值和实读值）

结论：计划定位点点逐条实读，绝大多数逐字符相符（下方「准条」为抽查原文），5 条变化 + 1 条码名口径（行号全部以本轮实读为准）。

| # | 计划定位点（出处） | 计划值 | 实读值 | 判定 |
|---|---|---|---|---|
| D-1 | `src/compiler/ent_kernel.cr`（技术栈行 + 侦查底座「语义对象侧表…定义在 `src/compiler/ent_kernel.cr`」+ Task 3 Files） | `src/compiler/ent_kernel.cr` | 文件不存在；实际 = `src/lattice/ent_kernel.cr`（`ESZ_NOD_SEM=28` :1010 · `OFF_NS_TK=24` :1017 · 访问器 :1026-1033）；`ls src/compiler/ \| grep -i ent` 仅命中 `entry.cr` | 变化（路径错） |
| D-2 | `main.cr:149-176` 硬名单「八条 `hard = 1`」 | 8 条 | 6 条语句行（:152 / :153 / :154 / :160 / :166 / :174），覆盖 11 个码常量（`EC_R_OOB`/`EC_TK_SLICE_BOUNDS`/`EC_TK_SLICE_LEN` · `EC_TS_MISSING_FIELD`/`EC_TS_UNKNOWN_FIELD`/`EC_TS_FIELD_TYPE`/`EC_TS_FIELD_DUP` · `EC_TK_ELEM_TYPE` · `EC_TM_EXHAUST` · `EC_ICE_TY_INDET` · `EC_TA_DECL`）；`if hard != 0 { return 1; }` 在 :178（超出 149-176） | 变化（条数计法） |
| D-3 | `dyn_arr.cr` 「契约注 :104-107」 | :104-107 | 契约四条实际 :103-118（:119 起为 `ESZ_DFNODE`） | 变化（区间） |
| D-4 | `src/ci/run.sh:68-109` selfhost-tests「14 档 py 挂点」 | 14 | `grep -c 'python3 tests/selfhost/'` = 28 | 变化（计数陈旧） |
| D-5 | 探针「30 档」（前置状态/附录 E/page 多处） | 30 | 29 `.cr`（第 3.2 节；30 = 29 + 字面 glob 伪条目） | 变化（U-4 已出正式清点） |
| D-6 | 越界护栏码名「P022/P023」（计划守门复验节） | P022 / P023 | `ast.cr:372-373` 定义注释 = P022/P023（`EC_P_ENUM_LIMIT=1022`）；编译器用户面实际打印 `error[P22]` / `error[P23]`（第 5.3 节 原文） | 口径注（码名两式并存） |

准条（逐字符相符，抽查原文）：`ccr_io.cr` :135 `CCR_VERSION=8` / :143 `ESZ_NOD_DISK=36` / :353 `4 + g_ir_instr_count*36` / :511 `OFF_NS_TK 取 iri_tk(ii)` / :1367 `(seg_end3-seg_off3)/ESZ_NOD_DISK` / :1373 `ccr_has_bytes(pos, ESZ_NOD_DISK, seg_end3)` / NOD 写 :757-772 / 读 :1384-1389 · `ccr_types.cr` :54/:94/:160/:196/:300 · `cir_cache.cr:51 CIR_CACHE_VER=17` · `ty_shadow.cr` :321/:424/:443/:451/:474/:487/:491/:513/:523/:535-536/:539/:608/:885 · `type_engine.cr` `ak_disjoint`(:69)/`te_elem_cmp`(:269)/`te_named_pair`(:278)/`lit_implies`(:299)/`sub_cover`(:596)/`ty_exhaustive`(:749) · `checker.cr` :1891（定义）/:2000（丢弃点：`unify_types(pattern_ti, concrete_ti);` 无接收）/:3433（使用点 `if !unify_types(...)`）/:2234（`body_ti != TI_NEVER`）/:522+:526（`check_let_annot_compat` 豁免③ `val_ti == TI_NEVER`）/:2929-2940（`EXPR_FOR`：`infer_expr(iter)` 弃结果 + `def_sym(var_ni, SYM_LOCAL, TI_INT, -1)`）/ :3683（`EC_TF_ARG_TYPE` 唯一 raise，全仓 grep 实证）· `ast.cr` :115-118（`MAX_GENERICS=4`/`MAX_STRUCT_FIELDS=16`/`MAX_ENUM_VARIANTS=16`/`MAX_VARIANT_TYPES=16`）/:143-145（镜像 `[.;64]`）/:407-428（错误码表，TF07=5007 :423）/:488-489（`EC_TG_ARG_COUNT=12001`/`EC_TG_BOUND=12002`）· `main.cr` :477-491（`cache_enabled` 扫描 + :488-490 `g_optrep_on != 0 因此 cache_enabled=0`）· `dyn_arr.cr` :119 `ESZ_DFNODE=72` / :122 `OFF_DF_TK=40` / :124 `OFF_DF_AUX=64` / 受护访问器 :481-548 · `run.sh` :73-76（自述「本 job 内无法复现」）/:82（selftest 404 注）/:86（test_ccr_types 40 注）/:105（test_enum_limit 13 例）· `test_type_engine.py:20 MIN_CASES=32` + :37 `assert passed == total and total >= MIN_CASES` · format spec 第 3.3 节 NOD（36B）（:60 节名实核）· type-iface spec 第 6.3 节 corearch 读回（:242，「接线 = β 批次（P6）」+「前置已齐」原文在位）· `explain-predict` spec :371 `CIR_CACHE_VER = 14`（陈旧值，实为 17）+ `:84/:127/:181/:447` 的 `--type-shadow` 先例（4 处全在位）· `policy-injection` spec :275（先例引用在位）· `error-codes.md` :100-101（TA01/TA02）/:114（TF02）/:263（ICE04）/:275-287（码族统计，总计 ~146）· `tools/module_to_ccr.py` 12784B（`:219-220` `out.extend(b'CCR1')` + `wu32(1)` = version 1）· `/tmp/p3t0_run.sh` sha `12dc571fdcd80d8b2e6faf1573df191d9483661d1f57c0d327ff0fe697cbc725`（实核）+ `shadow` 模式引用已删旗标（死码实读：`--type-shadow`/`--type-shadow-dump` 调用在 :15，摘要解析 `[type-shadow]`/`[type-shadow-sites]` 在 :23-24）。

---

## 5. 守门复验（Step 5）

### 5.1 `tests/selfhost/test_optional.py`（未覆盖面不得退化为不报错地错值）

```
$ nice -n 19 python3 tests/selfhost/test_optional.py      # rc=0
[PASS] uncovered_field_bare_is_loud: ELF+interp rc=-11（未覆盖面：双路径同，响亮）
[PASS] uncovered_field_boxed_ok: ELF+interp rc=5
… 34/34 passed
```
因此 结构体字段裸值 = `rc=-11`（SIGSEGV，ELF 与解释器双路径同 = 响亮失败，非不报错地错值）；装箱形态正确（rc=5）。

### 5.2 `tests/selfhost/test_enum_limit.py`（13 例）

```
$ nice -n 19 python3 tests/selfhost/test_enum_limit.py    # rc=0
[PASS] enum17_check_rejected: rc=1 + ['error[P22]', 'too many variants (17 > 16)'] + 无产物
[PASS] enum17_build_rejected / enum17_match_not_silently_accepted / enum17_use_rejected
[PASS] payload17_rejected / payload17_check_rejected
[PASS] struct17_check_rejected / struct17_build_rejected: rc=1 + ['error[P23]', …] + 无产物
… 13/13 passed
```

### 5.3 越界样本（本实例独立复造，17 变体 / 17 字段）

```
$ nice -n 19 ./build/corec check /tmp/p6t0/bounds_17var.cr，得到 rc=1
error[P22]: Enum has too many variants (17 > 16)     # 定位硬错（1:1 指声明）
$ nice -n 19 ./build/corec build /tmp/p6t0/bounds_17var.cr -o /tmp/p6t0/b17var.bin --static，得到 rc=1
$ ls /tmp/p6t0/b17var.bin /tmp/p6t0/b17var.bin.ccr，均显示「没有那个文件或目录」（无产物）
$ … bounds_17field.cr：check rc=1 / build rc=1；error[P23]: Struct has too many fields (17 > 16)  # 无产物
```
因此 越界仍为定位硬错 + 无产物（P22/P23），未退化为不报错地通过。

---

## 6. 关键结论与对计划的影响（供 T1–T5 直接引用）

1. E-13 前提成立且已闭合一半：冻结基线可复现（sha 逐条同 + 与 `/tmp/p5t0/base/` 逐字节同 + 确定性 ×2）。Task 1 的配方 = 第 1.1 节 + 第 1.2 节的两条命令（`jj workspace add --revision 9bcb7083` + `python3 build_selfhost_native.py`），无需任何二进制入库。
2. U-4 收口：探针正式清点 = 29 `.cr`；「30」= 29 + 1 条字面 glob 伪条目（`_tmp_p5t3b_probes_*.cr`）。后续文档不得再写 30；Task 1 的 runner 必须修掉未匹配 glob（`nullglob` 或显式清单），否则对拍腿在探针面恒空洞。
3. 「探针源已丢」按下述修正登记：源档（29）全在位；`/tmp/p5t3b/probes` 是 T3b 的输出目录（27 件 = 21 log + 6 dump）。其中 6 件可由冻结基线逐字节复现（red 族）、rc/诊断面 6 件可由当前二进制复现（final 族实测 3/3 + post 族同源推断）、15 件需重造变异二进制（M1..M4 + M2.dump），42 行 shadow 摘要不可复现（通道已死；第 3.3 节）。因此 Task 1 Step 3 的工作量 = 29 档实拷 + 配方注，不含源重建。
4. 定位点点变化 5 条（表 D-1..D-5）：其中 D-1 会影响 Task 3 的文件清单（Task 3 Files 写的 `src/compiler/ent_kernel.cr` 不存在，应落 `src/lattice/ent_kernel.cr`）；D-2/D-4/D-5 影响文档叙述数字；D-3 是注释区间。
5. E-14 的反向面有活证据：`tests/suite/ptr_arith.cr` 在 `check` 面 rc=1（B04 借用诊断，非硬名单）而 `build --static` rc=0 且产出 canary ELF，「非硬名单诊断不阻 `build`」在 72 档语料内可观测（可作裁-P6-2(b) 的事实输入，本任务不做任何裁决）。
6. 告警面：`check src/compiler` 与构建日志中的 checker 警告（`Arithmetic type error between string and int` 等）为既有非致命面（构建日志 `[GUARD] … error[ = 0` 三行佐证），本轮零变化。

---

## 7. 证据路径（`/tmp/p6t0/`）

| 用途 | 路径 |
|---|---|
| 冻结基线（产物） | `base/{corec,corearch,corelsp}`（`5d2b15ad…`/`493dc490…`/`18b94bd9…`） |
| P6 起点二进制（重建副本） | `head/{corec,corearch,corelsp}`（`f737e26b…`/`544e9201…`/`4251108b…`） |
| 冻结基线检出（已 `jj workspace forget`） | `src/`（树 = `9bcb7083`）· `headsrc/`（树 = `bc4f0a43`） |
| 构建日志 | `build1.log`/`build2.log`（逐字节同）· `head_build1.log`/`head_build2.log` |
| 表 B 驱动/输出 | `t0b_criteria.sh` · `t0b.out` · `ci_{check,bootstrap-tests,suite,selfhost-tests,full-bootstrap}.log` · `check_self.log` · `selftest.log` · `enum_list.txt` + `enum/*.log`（58） |
| 判据原始件 | `pa`（canary ELF，28822B）· `pa.ccr`/`pa_st.ccr`/`gt.ccr`/`gt_st.ccr` · `gt_do.txt`/`gt_st_do.txt` · `gt.cir` |
| 表 C 驱动/输出 | `t0c_corpus.sh` · `t0c.out` · `parity_start/{check/logs,check/dumps}`（72 档）· `parity_start.out` · `corpus_rc.txt` · `probes_start/` + `probes_start.out` · `probes_manifest.txt`（29 档 sha256） |
| p5t3b 复现证据 | `repro_p5t3b/{n13,n17,n18}.{frozen,cur}.log(+.norm)` · `*.frozen.dump` |
| 守门复验 | `bounds_17var.{check,build}.log` · `bounds_17field.{check,build}.log` · `bounds_17{var,field}.cr` |
| 冻结基线旁证（继承） | `/tmp/p5t0/base/*` · `/tmp/p3t0_run.sh`（`12dc571f…`）· `/tmp/p5t4/run_probes.sh` · `/tmp/p5t5/`、`/tmp/p5t7/` 记录 |

清理：`jj workspace forget p6t0-src` / `jj workspace forget p6t0-head` 已执行（`jj workspace list` 中 p6t0 条目 = 0）；主工作树不受影响（`jj status` 收工「no changes」）。

---

## 8. 诚实项（不不报错地）

1. 未测：`COREC_WARM_SELF=1` 的自源暖态两例（`test_cir_warm_path` 的可选分支，~3 分钟）；LSP 进程级会话（枚举 58/58 内的 `test_lsp.py` rc=0 为间接佐证）。
2. 未做：本任务未跑突变控制（计划未要求；T1–T5 各任务自证）；未跑冻结基线 × 当前源的 72 档同源对拍（属 T1 Step 2；本轮只跑了「起点二进制 × 当前源」并与其 P5 记录对拍）。
3. `.M2..M4` / `.post.log` 未单件复现（第 3.3 节 三栏）：`.post.log` 归入「rc/诊断面可复原」是同源推断（与 `.final.log` 同族、同 rc/诊断），未逐件 `cmp`；`.M1..M4` 判「需重建」依据 = 变异二进制不在位（未尝试复造）。
4. ps 实查口径：`ps -eo comm` 过滤 `python3|corec|corearch|corelsp|cc1|as|ld`；首轮曾用 `ps aux | grep` 误捕到本会话自己的 zsh 包装进程（已改用 comm 允许清单，各段开跑前 0 命中）。
5. 共享 `/tmp` 名：CI `full-bootstrap` job 写 `/tmp/corec2`、`/tmp/corec3`、`/tmp/corearch`（run.sh 内固定名），多 agent 并发时可能互相覆盖；本段 runs 前后 `ps` 实查无并发编译进程，且 `corec2==corec3` 结果自洽（`5559beef…`）。
6. 数字来源：本报告所有数字为本实例实跑（命令 + 原始输出见 第 7 节 路径）；凡引用 P5 既存值处均已标注（T5/T7 记录，且以 `cmp`/`diff -rq` 交叉）。未实测者一律标「未测」（第 1/3 条）。
