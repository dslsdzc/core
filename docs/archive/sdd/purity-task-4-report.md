# 效应和纯度修正任务 4 报告：收尾（全量回归、判据复验、文档回填）

状态：完成。
提交：`cc4baad3`，收尾主体，包含 `TODO.md` 和五份 spec，6 个文件 +42/−30；另有 `c9eb2a81`，补遗 S-C 两处残留的“今日取保守规则”措辞，1 个文件。

一句话结论：全量回归 38/38 rc=0；`tests/suite` 语料 20/20 的 build 和 run 都是 rc=0；ELF canary `95084e7b…d475` IDENTICAL；语料级“旧前端（任务 1 之前）加当前后端，对比当前全链”20/20 ELF 逐字节相同，发射面零泄漏；解释器 old 对 new 20/20 完全一致；`.ccr` 变更面只有 chain（kind=1）边的增删，NOD 语义字段零差异，STR、SYM、ENT、REG 逐字节不变；自举连续两次构建产物一致，`corec2b` 和 `corec3b` 的 `cmp` 为 IDENTICAL，N06=0，冒烟 42；TODO #27 已登记，五份 spec 的 S-A、S-C、S-D、S-E、S-B5 纯度事实回填完成。

## 0. 机器状态和前置

- 起点工作副本为 `c7ca4251`，即任务 3，状态干净。`build/corec` 等产物是 9 月 11 日 18:13 版本，对应任务 2 后的源树，`find src -newer build/corec` 为空，因此起跑时构建和源同代，无需预重建。
- 机器负载：4 核，load 7.28，多 agent 并发。全部构建和测试串行，使用 `nice -n 19`，没有并行跑两个重任务。
- 旧编译器，A/B 基线：`/tmp/corec2`，9 月 10 日 23:13，任务 1 之前的前端。身份佐证：`selftest-purity` 子命令不存在，usage 只列出 build、check、cir、ccr、run、clean-cache、selftest-types。
- 配对修正：`/tmp/corearch`（旧后端）与 `build/corearch`（当前）的 sha 不同。为了把 A/B 隔离到前端差异，复制 `corec2` 和当前 `corearch` 到 `/tmp/t4/oldbin/`，不覆盖 `/tmp/corearch`，避免毁掉他人或历史基线。

## 1. 全量回归（38 个套件，串行，`nice -n 19`，cwd 为仓库根）

驱动脚本为 `/tmp/t4/run_regression.sh`，逐套件记录 rc、秒数和全量日志，日志在 `/tmp/t4/logs/{dir}_{name}.log`。

| 套件 | rc | 计数（日志末行） | 秒 |
|---|---|---|---|
| bootstrap/test_apx_tag | 0 | 5/5 passed | 1 |
| bootstrap/test_borrow | 0 | 4/4 passed | 0 |
| bootstrap/test_dex_arith | 0 | 14/14 passed | 0 |
| bootstrap/test_dex_type | 0 | 3/3 passed | 0 |
| bootstrap/test_generics | 0 | 3/3 passed | 1 |
| bootstrap/test_modules | 0 | PASS，末行 `[PASS] import module : alias …` | 0 |
| bootstrap/test_pipeline | 0 | 29/29 passed | 0 |
| selfhost/test_apx_tag | 0 | 2/2 passed | 1 |
| selfhost/test_backend_bootstrap | 0 | `[PASS] stage0 and stage1 O2 smoke ELFs return 7` | 11 |
| selfhost/test_borrow | 0 | 7/7 passed | 0 |
| selfhost/test_ccr_v7 | 0 | 27/27 passed，含任务 3 新增的 3 例 | 1 |
| selfhost/test_compile | 0 | All selfhost compile tests passed. | 4 |
| selfhost/test_dex_arith | 0 | 11/11 passed | 2 |
| selfhost/test_dex_type | 0 | 5/5 passed | 0 |
| selfhost/test_directory_build | 0 | PASS | 0 |
| selfhost/test_ent_kernel_neutrality | 0 | PASS，A clean 等于任务 2 的门；A+B clean 等于完全中立 | 0 |
| selfhost/test_global_init | 0 | 15/15，双路径 | 1 |
| selfhost/test_hit_table | 0 | 24/24 passed | 3 |
| selfhost/test_impl | 0 | 7/7 passed | 0 |
| selfhost/test_interp_float | 0 | 全部通过 | 0 |
| selfhost/test_lexer_parity | 0 | PASS | 1 |
| selfhost/test_live_ranges | 0 | 13/13 passed | 1 |
| selfhost/test_lsp | 0 | 全部通过，10 个测试 | 1 |
| selfhost/test_mw_task1..6 | 0 ×6 | 全部通过 ×6 | 4/5/4/13/3/5 |
| selfhost/test_named_dedup | 0 | PASS | 0 |
| selfhost/test_native_float | 0 | 全部通过 | 1 |
| selfhost/test_native_memory | 0 | 6/6 | 1 |
| selfhost/test_native_strings | 0 | PASS | 0 |
| selfhost/test_pointer_safety | 0 | PASS | 3 |
| selfhost/test_purity | 0 | PASS，selftest-purity 26/26 通道 | 0 |
| selfhost/test_region_cfg | 0 | 22/22 passed | 55 |
| selfhost/test_slice_bounds | 0 | 7/7 passed | 1 |
| selfhost/test_type_engine | 0 | PASS，selftest-types 95/95 通道 | 1 |

合计 38/38 rc=0，零失败，零 flaky。因此本任务没有“已有失败复跑归因”的面。任务 1 报告也是 37/37 rc=0，本任务补上第 38 个套件，并且全部通过。

### 1b. `tests/suite` 语料（CI 的 `suite` job 等价）

驱动脚本为 `/tmp/t4/run_suite_corpus.sh`，先执行 `clean-cache`，排除 `*_mini*` 和非空文件，每个 .cr 执行 `corec build --static` 并运行，rc=0 为通过。

20/20 的 build 为 0、run 为 0：arena_test、at_test、at_test_struct、cache_test、chan_test、conc_test、dex_test、dyn_test、ffi_test、fnaddr_test、generics_test、go_e2e_test、go_final_test、go_parallel_test、go_test、hotpatch_test、lazy_test、ptr_arith、ptr_ref_first、syscall4_test。空文件 `test_control_flow.cr` 和 `test_generics.cr` 按 CI 规则跳过。

## 2. ELF 逐字节复验和运行语义（判据①、②）

### 2.1 Canary（判据②）

```
nice -n 19 ./build/corec clean-cache
nice -n 19 ./build/corec build tests/suite/ptr_arith.cr -o /tmp/t4/pa_cur --static     # rc=0
sha256sum /tmp/t4/pa_cur /tmp/r1t4_base_bin
  95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475  /tmp/t4/pa_cur
  95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475  /tmp/r1t4_base_bin
cmp → ELF_CANARY_IDENTICAL
```

附带：`/tmp/t4/oldbin/corec2` 使用任务 1 之前的前端和当前后端，产出的 ptr_arith 也是同一 sha，三方一致。

### 2.2 语料级 A/B（发射面零泄漏的更强实验）

驱动脚本为 `/tmp/t4/run_ab_interp.sh`。对 20 个语料：

- 旧前端加当前后端，对比当前全链：20/20 的 ELF sha 相同，记为 `ab=SAME`；运行 stdout 相同，记为 `OUTSAME`；rc 都为 0，记为 `oldrun=0`。
- 解释器路径：`corec run "$(cat FILE)"` 的 old 对 new 20/20 完全一致，rc 和全部 stdout 逐字节相同。

### 2.3 解释器和 ELF“两侧输出一致”的限定

计划判据①的字面表述是解释器和 ELF 两侧输出一致。这在本树内无法严格对拍，原因是既有问题，不是本批引入：

1. `corec run` 的 stdout 混入编译器自身的进度日志，位置在 `main.cr:128-137`，例如 `[1/5] tokenize...`，没有 quiet 开关。
2. 解释器路径对本语料不打印程序输出。例如 go_test 的 `ALL PASS` 在 `run` 下不出现，`println` 不实施。用 `fn main()->int{...return 7;}` 探针证实：解释器能算出 main 返回值，rc=7，但不产出 print 文本；old 前端逐字节同样不产出，因此是既有问题。

因此替代证据是每侧 old 对 new 的不变性，ELF 侧更强，逐字节相同；再加 canary 三方同 sha 和冒烟 rc=42。前两者合起来蕴含运行语义零变化。

### 2.4 编译期诊断面（自举链）

- `build_selfhost_native.py` 日志中有 `[GUARD] corec/corearch/corelsp: build log clean (error[ = 0, undefined = 0)`，三个单元各自断言。grep 命中的 3 条正是 GUARD 行本身。
- `corec2b` 和 `corec3b` 的构建日志各有 2 条 `error[TF01]`，分别是 `lits_copy` 和 `ty_memo_slot_no_grow` 的返回类型误报。这是既有问题：用任务 1 之前的旧前端构建同一份 `src/compiler/main.cr`，复现出同数同位置，2 条，日志第 42 和 48 行。N06 为 0/0。

## 3. `.ccr` 变更实测（冷缓存；解码器为 `tests/selfhost/test_ccr_v7.py` 的 `V7File`）

| 语料 | 编译器 | nod | edg kind=0 | edg kind=1 | size |
|---|---|---|---|---|---|
| CHAIN_SRC（任务 3 fixture，四类效应调用） | 当前 | 1321 | 836 | 329 | 91442 |
| CHAIN_SRC | 旧前端 | 1321 | 836 | 303 | 91234 |
| PROBE_SRC（期望表 fixture） | 当前 | 1296 | 819 | 322 | 89147 |
| PROBE_SRC | 旧前端 | 1296 | 819 | 298 | 88955 |
| ptr_arith | 当前 | 1298 | 810 | 318 | 88953 |
| ptr_arith | 旧前端 | 1298 | 810 | 293 | 88753 |
| 无效应程序 `fn main()->int{return 42;}` | 当前 | 1256 | 780 | 309 | 86131 |
| 无效应程序 | 旧前端 | 1256 | 780 | 285 | 85939 |

- 独立复现任务 3 的数据点：CHAIN_SRC 为 329 对 303，增加 26，逐数吻合。
- 任务 1 到任务 2 的增量：ptr_arith 从 293 到 318。任务 1 报告值为 317，因此任务 2 的 opcode 面，即 `IR_STORE_PTR` 和 `IR_AWAIT`，贡献 1，ptr_arith 含原始指针写。
- 无效应程序也有增加 24：该程序自身零调用，因此增加 24 全部来自编译内建的 runtime 和 builtin 函数体。这些函数可解析但不纯的调用此前被乐观标纯，不入链。结论是 `.ccr` 的变化面与“用户代码是否有效应”无关，只要编译闭包内含有可解析的不纯调用就会变化，这是修复真实缺陷的自然结果。
- 段级和字段级精度，4 个语料一致：STR、SYM、ENT、REG 四段逐字节不变；NOD 段字节有差异，但语义字段 op、dest、s1、s2、s3、tk 零差异，节点序不变，差异全部在 `first_edge` 和 `edge_count` 邻接域，例如 ptr_arith 的 semantic_field_diffs=0、adjacency_diffs=1266；EDG 段是唯一的边集变化。
- opcode 归因，以无效应程序为例，kind=1 入边按目标 opcode 统计：`IR_CALL`(4) 从 41 到 59，增加 18；`IR_STORE`(9) 从 229 到 235，增加 6；`IR_LABEL`(21) 15 到 15。新增入链的正是“可解析但未证明纯的调用”，以及它们前后 store 的链序改写。

## 4. 自举稳定（判据③）

命令和原始输出在 `/tmp/t4/logs/bootstrap_runner.out`：

```
nice -n 19 python3 build_selfhost_native.py   # run1 rc=0 → run2 rc=0
sha 两次逐项相同（BSN_TWO_RUNS_IDENTICAL）：
  build/corec    ff1c81c1a3610a1d75704e670b4c4bf5ed9f66fe5b97029dff20a3c9372defd4
  build/corearch 152dbce35255e96e319a60f2ee3662e46d05ae48e4b7e9f4ee7930d5c48f69b1
  build/corelsp  1c2f50ed0e88cbc889dc9046b218e05e61f9d54af3c5c475d1ae59e992bceb7f
  （且 corec 的 sha 与起跑前既有 build/corec 相同 = 源树决定论的三方一致）

./build/corec build src/compiler/main.cr -o /tmp/t4/sh/corec2b --static -O 0      # rc=0
cp build/corearch /tmp/t4/sh/corearch
/tmp/t4/sh/corec2b build src/compiler/main.cr -o /tmp/t4/sh/corec3b --static -O 0 # rc=0
cmp /tmp/t4/sh/corec2b /tmp/t4/sh/corec3b → CMP_IDENTICAL
  sha 77c056bf1afbc8d5df87f26ec4dd4078fc60ca475dea2ec2989e70568d082df4（两者同）
N06：0 / 0        error[：2 / 2（既有 TF01；旧前端复现同数同位置，见 §2.4）
nice -n 19 ./build/corec run 'fn main() -> int { return 42; }' → rc=42
```

注：任务说明中的安全写法是 `cp build/corearch /tmp/corearch`。本任务改用 `/tmp/t4/sh/corearch`，以免覆盖 `/tmp/corearch` 旧后端。那是 `/tmp/corec2` 的配对件，也可能是他人依赖的历史基线。语义等价：corec 按 `<exe_dir>/corearch` 查找，见 `main.cr:621-639`。

## 5. 文档回填（逐处 file:line，均为修改后的行号）

### 5.1 `TODO.md`

- 新增 #27“效应/纯度修正批实施”，从 `TODO.md:262` 起，包含落点、提交链、修了什么、链覆盖范围、残余面、收尾实测、`.ccr` 变更面，共 7 段。
- “控制流自动惰性”节新增“行号复核（2026-09-11）”子条，在 `TODO.md:462`。THUNK 判定现在位于 `ir_gen.cr:1588-1599`，其中 `fi_ispure` 在 `:1590`，`g_var_use_count` 在 `:1592`；`compute_usage_counts()` 现在位于 `dataflow.cr:405`，调用点在 `:461`。文档明示 use_count 时序缺陷独立存在，未修，本批有意冻结 lazy。
- auto-memo 条，在 `TODO.md:480`：补充 `IR_DYN_DISPATCH` 间接调用，以及 extern、spawn、yield、hotpatch、原始指针写的保守入链注，并说明消费侧时点，生成期旗标冻结。

### 5.2 spec（5 份）

| 文件 | 落点 | 改法 |
|---|---|---|
| S-A `semantic-safety-obligations-design.md` | 第 1.7 节外来注记和回填记录，`:171-172` | 保守面“今日等价于所有调用”改为“已退化为字面定义”；补充 `compute_all_purity` 和 `purity_op_effect` 底座，含 `IR_DYN_DISPATCH`；补回填实测；保留清单唯一硬约束，并追加“opcode 清单另一份唯一” |
| S-C `performance-without-commitment-design.md` | 第 1 节表纯度行 `:89`、第 1 节效应规则和回填 `:96-97`、第 2.2 节 C2 `:129`、第 2.1 节合法性行 `:124`、第 6 节事实 `:231`、第 6 节前置 1 `:237` | 缺陷标为已修，附 commit id；门禁放宽，首切片可以消费真纯度；增加硬性时点约束，必须在 `compute_all_purity` 写回后，生成期旗标冻结；use_count 时序前置保持，本批未动；校正行号为 1588-1599、405、461 |
| S-D `explain-predict-incremental-design.md` | 第 1.6 节缺清单 `:182`、第 1.7.1 节硬约束 8 `:227` | 把“效应事实不可靠”从“缺”中移出；约束 8 保留，要求证据声明覆盖，但覆盖现状改为修复后口径并列出残余，即 lazy 冻结和链每函数重置 |
| S-E `merge-semantics-design.md` | 依赖头 `:13`、第 1.1(a) 节前提 `:100-107`、`(a)` 注 `:111`、第 4.1 节序缺口 `:293`、N6 `:402`、第 5 节收敛表 `:503-504` | 前提改为“已满足”，加三条残余限定：链每函数重置、opcode 清单完备性、lazy 冻结；保守方向保证无假阴性；第 4.1 节三个后果逐条闭合或限定；N6 负控按新执法面重述；收敛表的⑦和未闭合两行改为“已回填”和“已闭合” |
| S-B5 `policy-state-version-toctou-design.md` | 第 1.2 节注解面 `:61`、事实底座和修链归属 `:64-65`、回填记录 `:67` | “外部效应无保证的序通道”改为“已有函数内保证的序通道”，含 extern 调用节点；修链从“单独立项”改为“已实施”，门禁口径不变，族切片仍不以其为前置；标明“图外变更无节点等于 TOCTOU 本体，不受影响”；行号从 `dataflow.cr:166-172` 改为 `:153-159` |
| 补遗 `c9eb2a81` | S-C `:89` 来源列、`:124` 合法性行 | 残留的“今日取保守规则”清理为真纯度事实，时点约束指向第 2.2 节 C2 |

## 6. 文件变更和复现

本任务提交的变更文件为 `TODO.md` 和 5 份 spec，即 S-A、S-C、S-D、S-E、S-B5，提交 `cc4baad3`；S-C 补遗提交 `c9eb2a81`。工作副本其后为空，没有卷入他人改动，提交前后 `jj status` 只列出本任务文件。

本报告和临时脚手架都在 `/tmp/t4/`，包含驱动脚本、日志和产物，未入库；`docs/archive/sdd/` 整个目录未跟踪。

复现命令集：

```sh
cd /home/DslsDZC/core
nice -n 19 /tmp/t4/run_regression.sh              # 38 套件表
nice -n 19 /tmp/t4/run_suite_corpus.sh            # tests/suite 20/20
nice -n 19 /tmp/t4/run_ab_interp.sh               # 语料级 A/B + 解释器 old/new
nice -n 19 python3 /tmp/t4/ccr_delta.py           # .ccr 变更表（需 /tmp/t4/oldbin/corec2）
nice -n 19 /tmp/t4/run_bootstrap.sh               # 自举稳定 + 链 cmp + 冒烟
```

## 7. 待说明的问题（如实）

1. `cc4baad3` 的提交信息有一处笔误：“（ISO 发射面零泄漏）”应为“（发射面零泄漏）”。铁律和派发令都禁止 rewrite，`jj describe` 修改已提交 change 属于改写面，因此未修正。内容和结论不受影响，特此登记以免误读。
2. 解释器和 ELF“两侧输出一致”无法严格对拍，见第 2.3 节，属于既有问题：`corec run` 混入编译器日志，解释器不实施 print。已用每侧 old 对 new 加 ELF 逐字节替代。如果评审要求字面判据，需要先给 `run` 增加 quiet 分离，或者让解释器 print 实施，作为独立批次。
3. `.ccr` 变化面比“效应程序”更宽：编译闭包含有 runtime 和 stdlib 的可解析不纯调用，因此任何程序的 `.ccr` 都会变，增加 24 起。这不是退化，而是修复的必然结果。但它会冲击所有以 `.ccr` 逐字节为判据的外部流程。本批已按 #26 重定；缓存不失效问题见 TODO #5 家族，本任务每次比较前都执行 `clean-cache`。
4. 无效应程序增加 24 的归因是“闭包内函数”，不是逐函数点名。按 opcode 归因，增加 18 个 CALL 入边、6 个 STORE 入边，与总量一致，但没有逐函数列出，缺少 node 到 function 的低成本映射。如果评审需要逐函数清单，可以增加探针。
5. `test_region_cfg` 55 秒、`test_backend_bootstrap` 11 秒，是高负载下仅有的两个超过 10 秒的套件，其余都不超过 5 秒。回归总墙钟约 2 分钟，环境 load 为 7。
6. `build_selfhost_native.py` 连续执行两次会覆盖 `build/*`。期间如果他人并发使用 `build/corec`，会撞上重建窗口。本任务已串行自控，但无法控制他人。事后 sha 与起跑前一致，没有残留影响。
7. 任务 4 之外未动，这是有意的：`docs/superpowers/plans/2026-09-11-effect-purity-fix.md` 的任务 1 到 4 复选框仍全为空，任务 1 到 3 也没有维护复选框，保持同一惯例；批次完整流程记录在 TODO #27 和本报告中。
