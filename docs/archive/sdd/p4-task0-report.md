# R2 P4 Task 0 报告：引擎核纯化拆分，iface 簇 + `iface_kind_of` 移出，corearch 链接面开路

日期：2026-09-12 · 基线：`3f8885ec`（P4 实现方式批计划定稿；工作副本起点，`selftest-types` 333/333）
任务：计划 `docs/superpowers/plans/2026-09-12-r2-p4-carrier.md` Task 0（前置、纯搬运）：Step 1 失败态、Step 2 拆分、Step 3 清单三面、Step 4 判据、Step 5 提交。
口径：所有命令 `nice -n 19`，cwd = 仓库根，一构建一编译串行；任何 `.ccr`/缓存态比较前 `clean-cache`；数字 = 本轮实跑（例外逐条标注）。

---

## 0. 交付摘要（摘要）

| 项 | 结果 |
|---|---|
| 拆分 | 新建 `src/compiler/iface_axis.cr`（头注 26 行 + `type_engine.cr:613-772` 160 行逐字 + `iface_registry.cr:271-293` 23 行逐字）；原位各留一行指路注释（type_engine.cr 772到612、iface_registry.cr 433到411）。逐字性 = 字节级比对（第 2.1 节） |
| 清单面 | 四处：`build_selfhost_native.py` corec+corelsp（计划列）×`src/compiler/_import.cr`（project-mode，计划括注「可能不动」经实测必须动）×`tests/selfhost/test_compile.py`（计划未列、测试自带副本，被全枚举捕获）×`src/targets/x86_64-linux/_import.cr`（零改动，实测背书） |
| 构建 | rc=0；三守卫全部通过（corec 44 / corearch 30 / corelsp 31 文件；`error[ = 0, undefined = 0`×3） |
| ELF canary | 先 `clean-cache`，得到 `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475` IDENTICAL |
| `.ccr` 面 | `ptr_arith` 88943B `54e3856b…` · `generics_test` 130974B `97be2f9e…`，冷缓存逐字节同（P3b 记录值） |
| 零行为变化 | 同源对拍 72 档 check `diff -r` 空（rc 33×0/39×1 两侧同）；影子 `decisions=30628 agree=30628` 全计数 0、logs+dumps `diff -r` 空；`check src/compiler` = 恰 2 条既有 TF01；`selftest-types` 333/333 |
| 自举链 | `corec2 == corec3` `cmp` IDENTICAL（双 2542222B）+ N06=0/0 + 冒烟 42（corec/corec2 双通道）+ `corec3 --help` rc=1 |
| 回归 | 五 CI job：4×rc=0 + `check` rc=1（既有划界）；全枚举 45/45 selfhost + 7/7 bootstrap |
| 提交 | `7c822003`（路径限定 6 文件） |

---

## 1. Step 1：失败态（链接面实证，不改仓库文件）

计划 Step 1 = 以 `/tmp` 脚本读 `build_selfhost_native.py` 清单、内存中把
`type_terms.cr`/`type_engine.cr`/`iface_registry.cr` 追加进 corearch 集后编译（等价临时清单变更；
硬性规则 3 下不走「改了再还原」）。本轮两面都测（同一失败态的两个观测层）：

### 1.1 concat 面（Python bootstrap；脚本 `/tmp/p4t0/red_step1.py`，日志 `/tmp/p4t0/red/corearch_red.log`）

- 清单 = `common + hit_engine + kernel + arch + flow + os + backend_support`（30）+ 3 追加 = 33 文件。
- 失败表现为构建硬失败 rc=1：`resolver.errors = 16`（`Undefined name: X`）× `checker.errors = 16`
  （`Undefined function X`），`compile_and_assemble` 的 `if resolver.errors: sys.exit(1)` 直接中止。
  守卫②（`guard_build_log`）的等价信号 = 未定义标记计数 16 ≠ 0（该面不产 `error[` 前缀，前缀属
  自主机 corec；守卫②本就双计 `error[` + 两个未定义标记）。
- 未定义符号 13 distinct（16 处） = 拆分覆盖面：
  `find_iface`(2) · `find_func` · `decl_name_of_ti` · `gen_constr_type_ti` · `sh_term_of_ti`(3) ·
  `sh_shape_member_at` · `sh_iface_shape_term` · `sh_iface_self_mode` · `sh_func_self_mode` · `sh_func_sig_term`
  （= iface 簇 `type_engine.cr:613-772`）· `get_type_kind` · `get_type_data`（= `iface_kind_of`）·
  `sh_ref_mut_marker`（= `iface_registry.cr:411` `sh_shape_seq_ro`，不属于移出面，见 第 6 节-②）。
- 证据复原说明：首轮日志被 第 1.3 节的复跑脚本覆盖过一次；已用 VCS 取回拆分前源（`jj file show -r 3f8885ec`）
  原样复跑（`/tmp/p4t0/red_presplit_rerun.py`），数字与首轮逐一相同（16/16、13 distinct），并把结果写回
  `corearch_red.log`（含逐字性核验，见 第 2.1 节）。

### 1.2 project-mode 面（自主机 corec；`/tmp/p4t0/redproj` = 目标 `_import.cr` + 三行 import，纯 /tmp）

`./build/corec build /tmp/p4t0/redproj -o … --static` 到 rc=0（！）+ `error[` 16 行：
2× `error[TF01]`（`type_engine.cr` 入单元后暴露的同一对既有误报）+ 14× `error[N06]: Undefined function`
（11 distinct，第 1.1 节 同族的 project-mode 子集；嵌套调用位的 `get_type_data`/`sh_ref_mut_marker` 未单列）。
= B.6 事故形态（rc=0 + 产物照出 + 诊断只在日志里），正是 `test_backend_bootstrap.py` 的 `error[` 门守的那类。
结论：corearch 链接集直接加引擎三件必然以未定义符号告终；Task 0 是前置必需。

### 1.3 拆分后残差（同集复测；`/tmp/p4t0/postsplit_probe.py`，日志 `/tmp/p4t0/red/corearch_postsplit.log`）

拆分后同一内存清单（type_terms + 新 type_engine + 新 iface_registry）到 未定义符号 = 恰 1 个：
`sh_ref_mut_marker`（1 处）。即：本任务把 13 distinct 的耦合面压到 1 处（该 1 处登记给 T2/T3，见 第 6 节-②）。

## 2. Step 2/3：拆分与清单面

### 2.1 搬迁（逐字；四重核验）

| 文件 | 变化 |
|---|---|
| `src/compiler/iface_axis.cr` | 新建 210 行 = 新文件头注（迁移面 / 为何移出 D16 / 直取跨层符号清单 / 清单面说明）+ `type_engine.cr:613-772`（160 行，`IFACE_SAT_BUDGET` + 7 函数 + 全部段头注）逐字 + 空行 + `iface_registry.cr:271-293`（23 行，`iface_kind_of` + 头注）逐字 |
| `src/compiler/type_engine.cr` | 772 行减为 612 行（删 160），尾留一行指路注释 |
| `src/compiler/iface_registry.cr` | 433 行减为 411 行（删 23），`ty_code_to_ti` 之后留一行指路注释 |

逐字性核验（`red_presplit_rerun.py` 实测，全 True）：① 搬迁块（engine 160 行 / registry 23 行）
== `3f8885ec` 版原文件对应行区间（字节级）；② 两搬迁块在 `iface_axis.cr` 中逐字存在；
③ 两搬迁块在原文件中已不存在；④ `iface_axis.cr == 头注 + engine 块 + 空行 + registry 块`（后缀断言）。
被搬代码零字符改动；新增的只有新文件头注与原位指路注释。

### 2.2 concat 清单（`build_selfhost_native.py`）

- `corec_files`：`iface_registry.cr` 之后插 `'src/compiler/iface_axis.cr'`（+3 行注）。
- `corelsp_files`：同位置插入（`checker.cr` 是 `iface_kind_of` 的消费者 因此 corelsp 必须含本文件）。
- `corearch_files` = 本任务不动（计划明示：加面归 T2/T3）。`corearch` 二进制 sha 逐字节不变（第 3 节 末）佐证。

### 2.3 project-mode 面（`src/compiler/_import.cr`），计划字面需修正的一处（必需，非可选）

计划 Step 3 括注「本任务不引入新依赖，若两文件均未列新文件则不动」。实测该前提不成立：
`src/compiler` 目录的 project-mode 文件集 = `_import.cr` 单清单（全目录仅 `_import.cr` 带 `import` 行；
`module.cr:397+ res_imports` 逐 token 收编，无目录自动发现）。`iface_axis.cr` 是全新文件，无人 import
因此 自举链上 `iface_kind_of`/`iface_satisfies` 全族不报错地未定义（P3a 的 monomorph 事故同族）。
故 `_import.cr` += `import iface_axis`（`import iface_registry` 之后，+ 6 行说明注释，把因果写进注释）。

必要性实证（剔除法，/tmp 副本，不改仓库文件）：把 `src/compiler/*.cr` 全量复制到
`/tmp/p4t0/noaxis2/`，仅删 `_import.cr` 的 `import iface_axis` 一行后构建 `main.cr`：
rc=0 + 23×`error[N06]` + 2×`error[TA01]` 级联（checker.cr:8855/:8911 的 `iface_kind_of` 返回值失型）
，符号全表 = `iface_satisfies` 12 · `iface_satisfies_term` 6 · `iface_find_method` 3 ·
`iface_user_satisfies_ii` 1 · `iface_kind_of` 1。即：去掉这一行 = 一个 rc=0 的坏编译器（B.6 原形）。
（对照：不删该行时同一副本构建 = 与正式构建同形，0×N06。）

`src/targets/x86_64-linux/_import.cr` 零改动，该 project 不含引擎三件、对 `iface_axis` 零引用；
由 `test_backend_bootstrap.py` rc=0 + `error[`=0 实测背书（本任务「投射面零变化」登记成立）。

### 2.4 第 4 面：`tests/selfhost/test_compile.py`（计划未列；全枚举捕获）

`tests/selfhost/test_compile.py::concat_sources()` 自带一份 corec 清单副本（文件自注「与
build_selfhost_native.py 的 corec 清单同位」）。首轮全枚举 44/45：该测试 rc=1，日志 =
`Compiler source errors: ['Undefined name: iface_find_method', …]` 全族未定义，正是本测试自己的
清单变化守卫在报。补齐该条目（+ 5 行注）后 rc=0（第 4 节）。
教训：本项目「清单面」实为四处（concat ×2 + project-mode ×2 [corec/_import.cr 与 target/_import.cr] +
测试副本），本轮由全枚举（不是 grep）补出第 4 面；建议 T2/T3 每次改清单后必跑全枚举，
不要依赖静态 grep（本轮首个 grep 因 `head -30` 截断曾漏掉该文件）。

## 3. Step 4：判据（逐条 = 命令 + 结果）

| # | 判据 | 命令 | 结果 |
|---|---|---|---|
| 1 | 三二进制构建 | `nice -n 19 python3 build_selfhost_native.py` | rc=0；`[GUARD] corec: manifest OK (44 files)` / corearch (30) / x86_64-linux target (3) / corelsp (31)；三条 `build log clean (error[ = 0, undefined = 0)` |
| 2 | project-mode 守卫 | `nice -n 19 python3 tests/selfhost/test_backend_bootstrap.py` | rc=0 + `error[` = 0；stage1/2/3 逐字节同 + smoke/O2 smoke 全部通过 |
| 3 | 类型引擎自测 | `nice -n 19 ./build/corec selftest-types` | 333/333（用例数零增减） |
| 4 | ELF canary | 先 `clean-cache`，再 `build tests/suite/ptr_arith.cr --static`，最后取 sha256 | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475` IDENTICAL |
| 5 | `.ccr` 逐字节同（冷缓存） | 先 `clean-cache`，再 `ccr`（`-o` 出到 /tmp，顺带证路径无关） | `ptr_arith` 88943B `54e3856b383301be5daecaf61f75ce120e56ef4d1569c3008009fc368b750df9` · `generics_test` 130974B `97be2f9e7431fde54de99e29394903a431aeafa591159c900e0175dfa064c8b1`，与 P3b 记录值逐字节同 |
| 6 | 同源对拍（check） | `/tmp/p3t0_run.sh check` × {旧 `/tmp/p4t0/bin_old/corec`（`9a583215…`）, 新 `build/corec`（`c05df756…`）}，然后 `diff -r` | 72 档日志目录 diff 空；rc 分布两侧同（33×0 / 39×1） |
| 7 | 影子对拍 | 同 runner `shadow` 模式 × 两二进制 | decisions=30628 agree=30628（两侧同值）；全计数 0；`sum(sites)==decisions`；logs `diff -r` 空 + dumps `diff -r` 空；站点覆盖同报：`assign-node=23150 · fn-body-ret=5464 · if-branch=1980 · struct-field-type=28 · array-elem-type=4 · generic-apply-base=2`（1/2/4/6 零命中、3=2 次）。 继承声明：影子通道对实现方式面零覆盖，此处只作判定面零变化的必要条件 |
| 8 | 自源 check | `nice -n 19 ./build/corec check src/compiler` | rc=1（既有划界）= 恰 2 条 `error[TF01]`：`lits_copy`（10162）/ `ty_memo_slot_no_grow`（10385），与 P3b 记录同对同行号 |
| 9 | 自举链 | `./build/corec build src/compiler/main.cr -o corec2 -O 0`，再 `corec2 build … -o corec3`，最后 `cmp` | cmp IDENTICAL（双 2542222B，`bec6e379…`）+ N06=0/0（两日志；`error[` 各 = 2 = 同一对 TF01，行号 10177/10400 = check 路径 +15 偏移，与 P3b 记载同）+ `corec3 --help` rc=1 |
| 10 | 冒烟 | `./build/corec run 'fn main()->int{return 42;}'` + corec2 同 | rc=42 / rc=42 |
| 11 | 五 CI job | 见 第 4 节 | 4×rc=0 + `check` rc=1（既有划界） |
| 12 | 全枚举 | 见 第 4 节 | 45/45 selfhost + 7/7 bootstrap（补齐 第 2.4 节 后） |

二进制 sha 面（登记，非判据）：`corearch` `599ee275…` 与基线逐字节同（其清单未动）；
`corec` `9a583215…`到`c05df756…`、`corelsp` `5190e8f4…`到`337505f3…`（源跨文件重排 因此 代码布局变，预期内）；
`corec2` 绝对 sha `03c9812f…`到`bec6e379…`（同上因），判据是链固定点（`corec2==corec3`），非与旧记录比。

## 4. 回归面（五 CI job + 全枚举）

| job | rc | 本轮要点 |
|---|---|---|
| `check` | 1（既有划界） | `check src/compiler` rc=1 = 恰 2 条 TF01（`lits_copy`/`ty_memo_slot_no_grow`）；日志 `error[` 命中 5 行 = 2 诊断 + 3 条 `[GUARD] … (error[ = 0 …)` 守卫行 |
| `bootstrap-tests` | 0 | 3 档：29/29 + 4/4 + 3/3 |
| `selfhost-tests` | 0（复跑） | 首轮 rc=1 = 第 2.4 节的 `test_compile.py` 清单变化；补齐该条目后复跑 rc=0（末档 `test_impl_iface` 20/20） |
| `suite` | 0 | `tests/suite` 21 档编译 + 运行全过（`*_mini*` / 空 fixture 按 run.sh 既有规则跳过） |
| `full-bootstrap` | 0 | `corec2==corec3` cmp IDENTICAL + `--help` rc=1 |

全枚举（`/tmp/p4t0/enumerate.sh`，含 #31 未挂 CI 档）：首轮 selfhost 44/45（唯一失败 = 第 2.4 节）到
补齐清单条目后复跑 45/45；bootstrap 7/7（两轮同）。

## 5. 提交（路径限定）

```
7c822003 refactor: R2 P4 Task 0，引擎核纯化拆分（iface 簇移到 iface_axis.cr；iface_kind_of 移出注册表）
         为 corearch 链接面开路；零行为变化
6 文件：build_selfhost_native.py · src/compiler/_import.cr · src/compiler/iface_axis.cr(A) ·
        src/compiler/iface_registry.cr · src/compiler/type_engine.cr · tests/selfhost/test_compile.py
```
`jj diff -r 7c822003 --summary` 核过 = 恰上列 6 路径；提交后工作副本干净（未卷入其他 agent 改动）。

## 6. 登记面与后续任务须知（Concerns）

① `_import.cr` 与 `test_compile.py` 是本任务偏离计划字面的两处（计划均未列）。二者都不是可选项：
不动的后果分别 = 自举链 rc=0 坏编译器（第 2.3 节 剔除实证）与 CI job rc=1（第 2.4 节 实测）。计划 Task 1 起
每一步动清单者，务必四面同核 + 全枚举，别只 grep。

② `iface_registry.cr` 残留一处 ty_shadow 耦合：`sh_shape_seq_ro`（`:411`）调 `sh_ref_mut_marker`
（`ty_shadow.cr:231`）。本任务按计划只移 `iface_kind_of`，未动该处 因此 T2/T3 把 `iface_registry.cr` 加进
corearch 清单时仍会撞上它（第 1.3 节 残差实测 = 恰此 1 个符号）。届时需一并处置（搬 `sh_ref_mut_marker`
入注册表 / corearch 侧自足实现），否则 `guard_build_log` + project-mode `error[` 门会拦下（这正是它们的价值）。
建议 T3 开工前，用 `/tmp/p4t0/postsplit_probe.py` 同款内存 concat 先量一次残差清单。

③ 拆分后纯核链接面：`type_engine.cr`（1-612）非注释行对外引用只剩 type_terms/ast/globals 层
（本轮 grep 复核 = 0 命中 checker/桥接/注册表）；`iface_registry.cr` 除 第 6 节-② 外同。因此 T2 的
`corearch_files += type_terms.cr` 可直接做；T3 再加 `type_engine.cr`/`iface_registry.cr` + 处置 第 6 节-②。

④ `error[` 双面口径（报告纪律）：concat 面（Python bootstrap）的失败和通过信号 = `Undefined function`/
`Undefined name` 标记（该面不产 `error[`）；project-mode 面（自主机 corec）才是 `error[N06]` + rc=0 的
不报错地形态。后续任务勿把 concat 面 `error[`=0 误读为通过。

⑤ 文档面未动（计划 Task 0 未列文档改点）：TODO.md / spec / P3 附录 C 中「iface 簇在 type_engine.cr」
一类的行号/文件引用自本提交起变化（现行位置 = `iface_axis.cr`）。建议 T2 或 T7 顺手校正，本任务不复述
具体引用面以免制造第二真源。

## 7. 证据路径（本机）

- 失败态：`/tmp/p4t0/red_step1.py` · `/tmp/p4t0/red_presplit_rerun.py` · `/tmp/p4t0/postsplit_probe.py` ·
  `/tmp/p4t0/red/corearch_red.log`（拆分前配置，VCS 复原复跑）· `/tmp/p4t0/red/corearch_postsplit.log`（拆分后残差）·
  `/tmp/p4t0/redproj/` + `/tmp/p4t0/red/redproj.log`（project-mode 面）· `/tmp/p4t0/presplit/`（VCS 取回的拆分前源）
- 必要性剔除实验：`/tmp/p4t0/noaxis2/`（`_import.cr` 少一行的副本）+ `/tmp/p4t0/noaxis2.log`
- 构建：`/tmp/p4t0/build1.log`；基线二进制与 sha 表 `/tmp/p4t0/bin_old/`
- 判据：`/tmp/p4t0/pa_p4t0`（canary）· `/tmp/p4t0/{ptr_arith,generics_test}.ccr` · `/tmp/p4t0/check_self.log` · `/tmp/p4t0/tbb.log`
- 自举链：`/tmp/p4t0/{corec2,corec3}` · `/tmp/p4t0/bs_corec2.log` · `/tmp/p4t0/bs_corec3.log`
- 语料/影子：`/tmp/p4t0/corpus_{old,new}/` · `/tmp/p4t0/shadow_{old,new}/`（+ 各自 `.out` 与 `.diff`）
- CI/枚举：`/tmp/p4t0/ci_*.log`（`ci_selfhost-tests_rerun.log` = 复跑）· `/tmp/p4t0/enum/` · `/tmp/p4t0/enum2_sh_*.log`
