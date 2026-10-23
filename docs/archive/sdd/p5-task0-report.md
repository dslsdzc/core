# R2 P5 Task 0 报告：前置侦查和冻结基线（源码零改动）

日期：2026-09-13。任务：`docs/superpowers/plans/2026-09-13-r2-p5-cleanup.md` 的 Task 0，Step 1 到 7。
起点：`93ac3291`，P5 计划定稿提交；工作副本 `7ccbc389` 为空，`jj status` 干净。
口径：cwd 为仓库根；全部命令 `nice -n 19`；一次构建一次编译串行，开工和每段之间用 `ps` 实查，没有他人构建；本轮唯一并发源是仓库外的 PhoneToolbox cc1plus，不写本仓 `build/`；比较任何 `.ccr` 或缓存态产物前执行 `clean-cache`；源码零改动，`jj status` 收尾为空。
产物：本报告，工作区文件，不入提交；冻结二进制 `/tmp/p5t0/base/{corec,corearch,corelsp}`；原始输出留档 `/tmp/p5t0/**`。

---

## 0. 交付摘要

| 项 | 结果 |
|---|---|
| 冻结基线（Step 1） | `build_selfhost_native.py` 两次构建逐字节相同；`corec 5d2b15ad…`、`corearch 493dc490…`、`corelsp 18b94bd9…`；冒烟 42，冻结副本和仓库二进制各跑一次，输出逐字节相同；副本 `/tmp/p5t0/base/` 可独立运行 `check`/`run`/`build` |
| ELF canary | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`（28822B），IDENTICAL |
| 自举链和枚举 | `corec2 == corec3`，`cmp` IDENTICAL，两个文件都是 `4919023b…`，等于 P4 T7 值；N06=0；`corec3 --help` rc=1；冒烟 42；全枚举 55/55 rc=0（48 个 selfhost 加 7 个 bootstrap） |
| 语料基线（Step 2，表 C） | 72 档（32+2+15+19+4）；`check` 面 rc 分布 34 个 0、38 个 1；影子面 70 档出摘要，`decisions=32620 agree=32620`，全计数 0，站点覆盖 `assign-node=24721 · fn-body-ret=5828 · if-branch=2037 · struct-field-type=28 · array-elem-type=4 · generic-apply-base=2`，总和 32620 |
| 表 A（Step 3） | 51 个 opcode 逐行分类：类型行 9、旗标 1、宽度 2、无 38、填充伪值 1（op39，附实测红证）；后端 `ti` 消费者恰好 5 个分支，机器审计 |
| 表 B（Step 4） | 10 个站点评级：语料命中 5 个站点（8/5/7/9/10），5 个零命中（1/2/3/4/6）；站点 6 不可达，parser 三面和全语料 0 命中；判定点全部保留 |
| 表 D（Step 5） | 9 个探针逐形态：2 个形态实测引擎 -1，分别是异名同形命名和同实参泛型应用两次实例化，都带 `unknown_engine_uncovered` 加 `replace_unknown` 回落；其余 7 个形态 0 负值；`ty_sub` 负值不可测，没有计数通道，用读码审计代替；预算耗尽面在用户语料中不可达 |
| 关键新发现 | ① `IR_HOTPATCH_ROUTE` 的 tk 是填充伪值，5 参调用 6 参函数导致 r9 残留，实测 0/4 两态；② `atom_of` 对复合行不可逆，实测 BINARY tk=10 是指针行，派生码不变量 D22-① 在复合行上不成立；③ op22/41/0 零 emit 点，是死 opcode；④ op35/36 仅在 `@x()` 括号形态可达 |
| 检查单（Step 6） | D-4 六项逐项有结论，见 §7 |
| 源码改动 | 0。`jj status` 干净；提交只有计划文件 Task 0 记录，见 §9 |

---

## 1. 表 C：P5 起点基线（Step 1 和 Step 2）

### 1.1 冻结二进制（Step 1）

| 项 | 命令 | 结果 |
|---|---|---|
| 构建确定性 | `nice -n 19 python3 build_selfhost_native.py`，build1 到 `/tmp/p5t0/build1.log`，build2 到 `build2.log` | 两次 rc=0；三面 `[GUARD] … build log clean (error[ = 0, undefined = 0)`，7 条 GUARD 行；两次 sha 逐字节相同 |
| `build/corec` | `sha256sum` | `5d2b15ad746018619b01143cce400e6f3489ae72a962e12283a7afd3dcdb41e7`，等于 P4 T6/T7 记录值；源未变，二进制相同 |
| `build/corearch` | `sha256sum` | `493dc490dfaed7774b46b74ccf1cfeca9fe5f61620e34229afb8991b1628a2a7` |
| `build/corelsp` | `sha256sum` | `18b94bd955fa204accf0753095a28f6499871566254d846333a7496c99109d49` |
| 冒烟 | `corec run 'fn main()->int{return 42;}'` | 42。冻结副本 `/tmp/p5t0/base/corec` 和仓库 `./build/corec` 各 42，stdout 逐字节相同 |
| 冻结副本可用性 | `/tmp/p5t0/base/corec check tests/suite/ptr_arith.cr` | rc=1，是 B04 借用诊断，该档 check 面既有 rc，见 §1.2；`run`/`build`/`cir` 都正常。后文实测均由冻结副本或同 sha 的 `./build/corec` 产出 |
| 副本路径 | `cp build/{corec,corearch,corelsp} /tmp/p5t0/base/` | sha 与上表逐条相同 |

### 1.2 语料基线（Step 2；runner 为 `/tmp/p3t0_run.sh`，sha `12dc571f…`，2026-09-12 版，实查存在可用）

72 档为 `tests/suite/*.cr` 32 档、自源 2 档（`src/compiler/main.cr`、`_import.cr`）、后端/内核/目标单元 15 档（`ccr_io.cr` 加 `src/{format/elf,os/linux,arch/x86_64,lattice,targets/x86_64-linux}/*.cr`）、`src/stdlib/*.cr` 19 档、`examples/*.cr` 4 档。逐档 `clean-cache`。

| 面 | 命令 | 结果 |
|---|---|---|
| `check` | `bash /tmp/p3t0_run.sh check /tmp/p5t0/base/corec /tmp/p5t0/parity/base_check` | 72 档；rc 分布 34 个 0、38 个 1，等于 P4 T7 收尾侧同值；逐档日志在 `parity/base_check/logs/*.log` |
| `shadow` | `bash /tmp/p3t0_run.sh shadow /tmp/p5t0/base/corec /tmp/p5t0/parity/base_shadow` | 70 档出摘要，2 档是空文件，见下；`decisions=32620`，`agree=32620`；`old_stricter/old_looser/unknown/unknown_bridge/unknown_engine/unknown_engine_uncovered/unknown_engine_budget/replace_bridge/replace_unknown` 全为 0 |
| 站点覆盖（shadow） | 上表汇总 | `assign-node=24721 · fn-body-ret=5828 · if-branch=2037 · struct-field-type=28 · array-elem-type=4 · generic-apply-base=2`；其余 4 个站点（hotpatch-ret / generic-arg / unify-fallback / assign-binary）为 0；总和 32620，与 decisions 互检 |
| `.ccr` 记录值（冷态，两套口径） | `corec ccr F -o O` 与 `corec build F -o O --static`，各 `clean-cache` | `ccr` 口径：`ptr_arith` 90823B `fb4a3b59103f4e0c…`，`generics_test` 134701B `cafb42781f8a4f9b…`；`--static` 口径：90966B `592afa31d66cc75a…`，134844B `ec8413ec55007f51…`。四条与 P4 附录 D-1 逐条同值，差恒 143B 也已复验 |
| 自源 check | `./build/corec check src/compiler` | rc=0，输出 ok，诊断 0 条 |
| `selftest-types` | `./build/corec selftest-types` | 355/355，rc=0 |
| 自举链 | `./build/corec build src/compiler/main.cr -o /tmp/p5t0/corec2 --static -O 0`，再用 corec2 同命令产 corec3，然后 `cmp` | 见 §1.3 |
| 全枚举 | 55 档（48 个 `tests/selfhost/test_*.py` 加 7 个 `tests/bootstrap/*.py`），逐档 rc | 见 §1.3 |
| 语料既有失败，登记，非本任务引入 |  | ① `tests/suite/test_generics.cr` 和 `test_control_flow.cr` 是 0 字节文件，报 `cannot read` rc=1，shadow 面无摘要，因此是 70 不是 72；② `at_test_mini4/6.cr` 是嵌套 fn 声明，P21 定位拒绝，`run_suite` 有既有 SKIP 规则；③ `examples/test_scale.cr` 和 `test_sum.cr` 解析错误 rc=1，CI `suite` job 不覆盖 examples，没有回归面 |

判据口径继承 D28：`.ccr` 记录值引用必须带口径和缓存态；上表两套口径都是冷态，`clean-cache` 后即时采集。

### 1.3 自举链和全枚举（Step 2 收尾；命令和原始输出）

见 §8 证据路径。结果为本实例实测，`/tmp/p5t0/baseline_run.out` 第 6/7 段：

| 判据 | 命令 | 结果 |
|---|---|---|
| 自举链构建 | `./build/corec build src/compiler/main.cr -o /tmp/p5t0/corec2 --static -O 0`，再用 `/tmp/p5t0/corec2 build … -o /tmp/p5t0/corec3 …` | 两段 rc=0；`corec2` 和 `corec3` 都是 `4919023b3e92b661219f4624859512d53abb58e3dbfe874a51ae8a5b297f9034`，等于 P4 T7 记录值，逐字节相同 |
| `cmp` | `cmp /tmp/p5t0/corec2 /tmp/p5t0/corec3` | IDENTICAL，rc=0 |
| N06 | `grep -c -F 'error[N06]' /tmp/p5t0/chain_corec{2,3}.log` | 0 / 0 |
| `--help` 约定 | `/tmp/p5t0/corec3 --help` | rc=1，既有约定 |
| 冒烟 | `/tmp/p5t0/corec3 run 'fn main()->int{return 42;}'` | 42 |
| 全枚举 | `for f in tests/selfhost/test_*.py tests/bootstrap/*.py; do python3 $f; done` | 55/55 rc=0（48 个 selfhost 加 7 个 bootstrap；逐档 `/tmp/p5t0/enum_chain.out`，非零 0 行） |

执行偏差，如实登记：`/tmp/p5t0/baseline_run.sh` 首次运行时 corec3 段 rc=127。脚本漏拷 `corearch` 到 corec2 同目录，CI `full-bootstrap` 有 `cp ./build/corearch /tmp/corearch`，本脚本漏了。corec2 在 ELF 阶段报 `/bin/sh: /tmp/p5t0/corearch: No such file or directory`。已修复：补拷 `build/corearch` 到 `/tmp/p5t0/corearch`，再重跑 corec2 到 corec3，corec2 复用同 sha 产物 `4919023b…`，不是重建。上表数字为修复后实测。corec2 的 frontend 段产物未受缺失影响，其 sha 与 P4 记录逐字节相同，可以佐证。

---

## 2. 表 A：全 op 的 `tk` 语义分类表（Step 3；Task 2 的判据输入）

方法有三条独立证据面，逐 op 交叉：

1. 后端消费者机器审计。对 `src/arch/x86_64/instr.cr` 的 `emit_instr`（459-1510 行）按 `if op == IR_*` 切段，机器统计各段是否引用 `ti`，脚本一次产出。恰好 5 个分支引用：`IR_CONST`（:485 的 `ti == TI_STR`）、`IR_BINARY`（:518 的 `ti == TI_DEX`）、`IR_DEREF`（:1101 到 `e2_ptr_bounds_check` 的 `access_width`）、`IR_STORE_PTR`（:1132 同款）、`IR_BOUNDS_CHECK`（:1340 的 `ti != 0`）。其余 45 个分支零引用。旁路消费者有 `regalloc.cr:457`（`tk == TI_DEX||TI_DEX_S`，dex 危险面，按值面不按 op）、`lower_to_core.cr:250`（`IR_CONST` 的 `ti == TI_STR`）、`:574`（`hit_inj_line_expected` 的 `IR_CONST && ti != TI_STR`）、`dump.cr:125`（仅 `IR_ALLOC` 文本）、`interp.cr:256/:546`（仅 `IR_BINARY` 传 `ir_interp_binary`）、`ir_gen.cr:129`（DF 节点 `IR_CONST && tk == TI_STR`）、`provenance_verify.cr:57`（`IR_DEREF`/`IR_STORE_PTR` 读宽度）。
2. emit 调用点静态审计。`ir_gen.cr` 有 250 个 `emit(` 调用，含 1 个 5 参缺省调用，见 F1；`ext_safety.cr` 有 3 个（`IR_CONST` 1 个、`IR_BOUNDS_CHECK` 2 个）。逐 op 抽取第 6 实参。
3. 全语料 `(op,tk)` 实测直方图。`corec cir FILE --dump-tk-terms` 在 66 档成功，另有 9 个定向探针（`/tmp/p5t0/probes/`）。合计 777948 个节点，`with_term=202882`，`bad_term=0`。

读数口径：`tk` 值分为类型行、旗标、宽度、无。“入项槽”指现行 P4 允许清单 `sh_tk_term_of_code`（`{IR_CONST, IR_BINARY}`）与否，并给出 T2 的再裁建议，D19 语义是类型面入项槽。

| op | 名称 | tk 语义 | 后端消费者（`ti`） | 实测 tk 值（语料加探针） | 入项槽（现行） | T2 建议 | 证据 |
|---|---|---|---|---|---|---|---|
| 0 | `IR_NOP` | 无 | — | 零发射点 | — | 无 | 读码：全仓零 `emit(IR_NOP` |
| 1 | `IR_CONST` | 类型行（原子） | `instr.cr:485` / `lower_to_core:250` / `interp` 值面 | `0,1,2,3,8`，8 是 TI_DEX_S 行 | 是 | 类型行 | 实测加读码 |
| 2 | `IR_BINARY` | 类型行（原子或复合） | `instr.cr:518` / `interp.cr:256·546` / `regalloc:457` | `0,1,2,10`，10 是指针行，见 F2 | 是 | 类型行，须处理复合行，F2 | 实测加读码 |
| 3 | `IR_UNARY` | 无 | — | `0` | 否 | 无 | 实测 |
| 4 | `IR_CALL` | 类型行 | —，无 `ti` 分支 | `0,2,3,4,8` | 否，P4 排除项 | 类型行，返回类型行，可能复合，F2 | 实测加读码 |
| 5 | `IR_RETURN` | 无 | — | `0` | 否 | 无 | 实测 |
| 6 | `IR_ALLOC` | 类型行 | `dump.cr:125` 文本 | 语料 `4`，即 TI_UNIT；探针 `0`/`4` | 否，P4 排除项 | 类型行，值域实测 {TI_INT,TI_UNIT} | 实测加读码 |
| 7 | `IR_ALLOC_STRUCT` | 无，类型在 s3 | — | `0` | 否 | 无 | 实测 |
| 8 | `IR_ALLOC_ARRAY` | 无 | — | `0` | 否 | 无 | 实测 |
| 9 | `IR_STORE` | 无 | — | `0`，16.3 万节点 | 否 | 无 | 实测 |
| 10 | `IR_LOAD` | 类型行 | — | 探针 `0`，cast 行；语料零命中 | 否，P4 排除项 | 类型行，`target_ti` 可为 `*T` 行，即复合行，F2 | 实测加读码 |
| 11 | `IR_LOAD_FIELD` | 无 | — | `0` | 否 | 无 | 实测 |
| 12 | `IR_STORE_FIELD` | 无 | — | `0` | 否 | 无 | 实测 |
| 13 | `IR_LOAD_INDEX` | 无 | — | `0` | 否 | 无 | 实测 |
| 14 | `IR_STORE_INDEX` | 无 | — | `0` | 否 | 无 | 实测 |
| 15 | `IR_LOAD_INDEX_VAR` | 无 | — | `0` | 否 | 无 | 实测 |
| 16 | `IR_STORE_INDEX_VAR` | 无 | — | `0` | 否 | 无 | 实测 |
| 17 | `IR_MAKE_ENUM` | 无 | — | `0`，探针 p_enum/p_opt | 否 | 无 | 实测 |
| 18 | `IR_REF` | 无 | — | `0` | 否 | 无 | 实测 |
| 19 | `IR_BRANCH` | 无 | — | `0` | 否 | 无。注：`res_labels` 会把它覆写为 `IR_RESOLVED=1`，该函数没有 live 调用者，只有 `legacy_asm_backend` 调用，属于死路径覆写 | 实测加读码 |
| 20 | `IR_JUMP` | 无 | — | `0` | 否 | 无，同上 | 实测加读码 |
| 21 | `IR_LABEL` | 无 | — | `0`，9.2 万节点 | 否 | 无 | 实测 |
| 22 | `IR_PHI` | 无 | — | 零发射点 | 否 | 无，死 opcode，仅被 `ptr_analysis`/`dump` 消费 | 读码 |
| 23 | `IR_LOAD_ENUM_TAG` | 无 | — | `0`，探针 p_enum | 否 | 无 | 实测 |
| 24 | `IR_SLICE` | 无 | — | `0`，探针 p_bounds | 否 | 无 | 实测 |
| 25 | `IR_DEREF` | 宽度 | `instr.cr:1101` | `8`，ptr_arith | 否 | 宽度，aux | 实测加读码 |
| 26 | `IR_STORE_PTR` | 宽度 | `instr.cr:1132` | `8` | 否 | 宽度，aux | 实测加读码 |
| 27 | `IR_SPAWN` | 辅码，spawn_count；-1 表示动态 | — | `-1`，探针 p_spawn | 否 | 辅码，aux；负值，与“0 表示无”的哨兵不冲突，但分类表须显式容纳 | 实测加读码 |
| 28 | `IR_YIELD` | 无 | — | `0` | 否 | 无 | 实测 |
| 29 | `IR_AWAIT` | 无 | — | `0`，探针 p_go | 否 | 无 | 实测 |
| 30 | `IR_BOUNDS_CHECK` | 旗标，1 为动态上限，0 为字面量上限 | `instr.cr:1340` | `0`，7 个站点；`1`，4 个站点；两态都实测 | 否 | 旗标，aux | 实测加读码 |
| 31 | `IR_ADDR_INDEX` | 无 | — | `0` | 否 | 无 | 实测 |
| 32 | `IR_ARENA_NEW` | 无 | — | `0`，1 万以上 | 否 | 无 | 实测 |
| 33 | `IR_ARENA_RESET` | 无 | — | `0`，1 万以上 | 否 | 无 | 实测 |
| 34 | `IR_INLINE` | 无 | — | `0` | 否 | 无 | 实测 |
| 35 | `IR_NO_BOUNDS_CHECK` | 无 | — | `0`，仅 `@x()` 括号形态可达，见 F4 | 否 | 无 | 实测加读码 |
| 36 | `IR_FAST` | 无 | — | `0`，同上 | 否 | 无 | 实测加读码 |
| 37 | `IR_UNROLL` | 无 | — | `0`，探针 p_annots | 否 | 无 | 实测 |
| 38 | `IR_SECTION` | 无 | — | `0`，探针 p_annots | 否 | 无 | 实测 |
| 39 | `IR_HOTPATCH_ROUTE` | 填充伪值，非语义 | — | `0` 或 `4`，随程序形状变化，见 F1 | 否 | 须先修调用点，见 F1/§7-Q1 | 实测加读码 |
| 41 | `IR_DYN_TAG` | 无 | — | 零发射点，全仓零 `emit(IR_DYN_TAG` | 否 | 无，死 opcode | 读码 |
| 42 | `IR_DYN_VAL` | 无 | — | `0` | 否 | 无 | 实测 |
| 43 | `IR_DYN_PACK` | 无 | — | `0` | 否 | 无 | 实测 |
| 44 | `IR_DYN_DISPATCH` | 无 | — | 未命中。唯一 emit 点是 :1751，条件为 dyn 接收者方法调用 | 否 | 无 | 读码，证据级为未定 |
| 45 | `IR_CALL_EXTERN` | 无 | — | `0`，探针 p_ffi2 | 否 | 无 | 实测 |
| 46 | `IR_LAZY_THUNK` | 无 | — | `0`，5.2 万以上 | 否 | 无 | 实测 |
| 47 | `IR_LAZY_FORCE` | 无 | — | `0`，3.5 万以上 | 否 | 无 | 实测 |
| 48 | `IR_FNADDR` | 无 | — | `0` | 否 | 无 | 实测 |
| 49 | `IR_I2F` | 类型行，恒 TI_DEX | — | 零覆盖，语料和探针都未命中；3 个 emit 点都传 `TI_DEX` | 否，P4 排除项 | 类型行，基行，无复合行风险 | 读码，零实测 |
| 50 | `IR_F2I` | 类型行，恒 TI_DEX | `regalloc:457`，dex 危险面 | `1`，dex_test | 否，P4 排除项 | 类型行 | 实测加读码 |
| 51 | `IR_APPROX` | 无 | — | `0` | 否 | 无 | 实测 |

现行允许清单的量化复核，实测 790828 个节点，即 66 个语料档加 10 个探针档：`term >= 0` 的节点数恰好等于 `{IR_CONST, IR_BINARY}` 节点数，206203 等于 121195 加 81687 加探针面；清单外节点带项的计数为 0；`bad_term = 0` 全档。因此 P4 的“清单制派生”在当前语料和探针面没有可疑点。本任务的增量在分类语义，即哪些 op 应该进入清单，见下表与 F1/F2。

影子 dump 目录空洞性声明，继承 P4 T7 口径：`/tmp/p5t0/parity/base_shadow/dumps` 为 0 文件，`sh_dump_write` 在“无差异条目”时提前返回。因此“dumps diff 空”不能作为强证据引用。判定面证据是摘要加站点覆盖，见上表。

P4 六个排除项再裁，Task 0 硬性要求：`IR_ALLOC`、`IR_CALL`、`IR_I2F`、`IR_F2I`、`IR_LOAD`、`IR_LOAD_ENUM_TAG`。前五者的 tk 语义就是类型行，调用点显式传 `TI_*` 或类型行变量，建议 T2 归入“类型行”类。`IR_LOAD_ENUM_TAG` 的两个调用点显式传字面量 `0`，不是类型语义，归入“无”。但 `IR_CALL`/`IR_LOAD`/`IR_BINARY` 的 tk 可以是复合行，包括指针、序列、命名、泛型应用行，与 D21 的 `atom_of` 契约冲突，见 F2。这是 T2 必须先裁的形态问题。

### 2.1 F1：`IR_HOTPATCH_ROUTE` 的 tk 是调用点缺省填充的残留寄存器值（实测红证）

- 静态事实：`ir_gen.cr:1758` 的 `emit(IR_HOTPATCH_ROUTE, dest, func_ni, first_arg_var, ac)` 只传 5 个实参，`emit` 形参有 6 个。
- 实测两态，均确定：1 次 hotpatch 调用的探针 `/tmp/p5t0/probe_hotpatch.cr` 得到 `op39 tk=0`；3 次 hotpatch 调用的探针 `probe_hotpatch3.cr` 和语料 `tests/suite/hotpatch_test.cr`（3 次调用）得到 `op39 tk=4`，4 是 `TI_UNIT` 行，纯属巧合。
- 机制，读码：corec 由 Python bootstrap 生成。bootstrap 的调用序列（`bootstrap/corec/backend/x86_64_stack_asm.py:222-226`）只为实际存在的实参写寄存器，从 rdi 到 r8，第 6 个寄存器 r9 保持前序计算的残留。被调 `emit` 的序言把 r9 溢写到第 6 形参槽（同文件 `:486-489`），于是 `type_kind` 等于残留值。自托管编译语义下缺省实参为 0，独立实测 `f(1,2,3,4,5)` 对 6 参函数，第 6 参为 0。
- 影响：op39 的 tk 当前没有消费者，后端不按 ti 分派，interp 和 DF 消费者不读，所以是潜伏问题，不是在野错误。但 T2 的派生码不变量 D22-①“全语料逐节点对拍”会被它挡住：如果按“无”分类，派生码从 4 变 0，直方图和 dump 有差异，合法但需要登记；如果按“类型行”分类，能保住 4，但语义错误。建议 T2 在同一提交给 `ir_gen.cr:1758` 补第 6 实参显式 `0`，只改一处，并把“op39 派生码 4 变 0”作为已裁决偏差登记。该值本来就是垃圾，没有消费者。
- 派生面：该值经 `iri_tk` 到 `ccr_io.cr:511` 的 NOD 盘记录和 `cir_cache.cr:323` 的快照落盘。因此语料 `hotpatch_test.cr` 的 `.ccr` NOD 字节面会随该决定变化；canary 语料 `ptr_arith` 不含 hotpatch，canary 不受影响。

### 2.2 F2：`atom_of` 对复合行不可逆（D21 契约的边界；实测）

- 实测：`tests/suite/ptr_ref_first.cr` 节点 9 为 `op2(BINARY) tk=10`，其项为 `TT_ATOM/AK_PTR`，`b=-1`，即 `sh_term_of_ti` 的 PTR 分支 `tt_atom(AK_PTR, -1, chain)`，于是 `atom_of(term)` 为 -1，不等于 10。
- 同类面，读码：`IR_LOAD` 的 `target_ti`（`ir_gen.cr:2481` 的 cast 路径为 `alloc_type(TYP_PTR,…)` 行）、`IR_CALL` 的 `call_ti`（返回类型行，可为命名、序列、元组行）、`IR_BINARY` 的操作数行（任意行，实测已见指针行）。
- 后果：如果这些 op 归入“类型行”并且只存项，`df_rebuild_ir` 按 `atom_of` 派生出的 `iri_tk` 不等于旧值，D22-① 派生码不变量不成立。这是“分类表一格错导致不报错地错码”风险的另一种形态：不是错点，而是不可逆。
- T2 的三条候选路，须先裁，Task 0 不预判：
  - (i) 扩 `atom_of` 契约。D21 扩第三态：类型行进入项，并且行号可从项中回读。需要给复合行建携行项，例如新原子类 `AK_TYREF(row)`，或者让 `sh_tk_term_of_code` 返回携行包装。会动桥接和引擎面。
  - (ii) 复合行走 aux。term 为 -1，aux 为原始行码，派生码等于 aux，等于旧值，零变化。代价是 D19 的“aux 为非类型辅码”定义需要扩为“非类型辅码或不可入项的原始类型行”。
  - (iii) 分类表限定“类型行”只含原子行，即 base 和 TI_DEX_S 等 b 可复用的行，复合行的 op 全部归入 (ii)。
  - 三者的共同前置是 T2 必须先出“哪些 op 的 tk 实测或可能出现复合行”的清单。本表加直方图是输入；`(op,tk)` 直方图需要覆盖更多语料才能捕捉复合行，当前 66 档只有 BINARY 命中一次。

### 2.3 F4：两处可达性登记（不修，供 T2/T5 参考）

- `IR_NO_BOUNDS_CHECK`(35) 和 `IR_FAST`(36) 的 emit 点在 `ir_gen.cr:1527/:1533`，只有当注解以 `@x()` 括号形态出现在表达式位，即 EXPR_CALL 包裹 EXPR_AT 时才可达。语句形态 `@no_bounds_check;`（at_test.cr 现行写法）不产生任何 IR，因为 `ir_gen` 没有顶层 EXPR_AT 分支。读码和实测双证：探针 `p_annots.cr` 没有 35/36，`p_annots2.cr` 的括号形态出现 35/36。
- 死 opcode：`IR_NOP`(0)、`IR_PHI`(22)、`IR_DYN_TAG`(41) 全仓零 emit 点，读码确认，只有消费面存在。T2 分类表可以不为它们定义 term/aux 行为，仍建议保留行，避免未来新增发射点时出现“未定义面”。

---

## 3. 表 B：影子站点评级表（Step 4；D25 的判据输入）

方法：`sh_site_begin` 的 10 个挂点逐点读码（`checker.cr` / `ty_shadow.cr:472-483` 站点表），加全语料实测命中（`/tmp/p5t0/parity/base_shadow`，70 档摘要），加结构面可达性证明。行号为当前工作树 `checker.cr`。

| 站点 | 位置（工作树） | 语义 | 可达性 | 语料命中 | 判定点保留 | 挂点去留 | 证据 |
|---|---|---|---|---|---|---|---|
| 1 | `checker.cr:1535` | hotpatch 返回类型一致，collect_decls 中后续声明对首版，使用 `type_compat_sym` | 可达，需要同名 hotpatch 至少 2 次声明 | 0 | 保留 | 去挂点（D25） | 读码加实测 |
| 2 | `checker.cr:1916` | `unify_types` 泛型实参已绑定路径，`g_gen_map` 命中 | 可达，探针 d6 命中 2 次 | 0（语料）/ 2（探针） | 保留 | 去挂点 | 读码加实测 |
| 3 | `checker.cr:1930` | `unify_types` 泛型应用基型比较 | 可达 | 2 | 保留 | 去挂点 | 读码加实测 |
| 4 | `checker.cr:1946` | `unify_types` 后备结构等价 | 可达，非泛型或未匹配路径 | 0 | 保留 | 去挂点 | 读码加实测 |
| 5 | `checker.cr:2247` | 函数体返回类型，`check_func` | 可达 | 5828 | 保留 | 去挂点 | 读码加实测 |
| 6 | `checker.cr:2460` | `EXPR_BINARY + OP_ASSIGN` 赋值兼容 | 不可达，三面证明见下 | 0 | 删除判定点（D25；`ir_gen.cr:927-929` 同分支一并删） | 删挂点并删分支 | 读码加实测 |
| 7 | `checker.cr:2877` | if 分支类型合并，`EXPR_IF` | 可达 | 2037 | 保留 | 去挂点 | 读码加实测 |
| 8 | `checker.cr:3345` | 赋值兼容，`EXPR_ASSIGN` 节点 | 可达 | 24721 | 保留 | 去挂点 | 读码加实测 |
| 9 | `checker.cr:3472` | struct 字面量字段类型对声明 | 可达 | 28 | 保留 | 去挂点 | 读码加实测 |
| 10 | `checker.cr:3538` | 数组字面量元素同质性 | 可达 | 4 | 保留 | 去挂点 | 读码加实测 |

站点 6 不可达，三面证明，本轮独立复核成立：

1. `tok2op`（`parser.cr:170-184`）的全部返回值是 `{OP_ADD, OP_SUB, OP_MUL, OP_DIV, OP_MOD, OP_EQ, OP_NE, OP_LT, OP_GT, OP_LE, OP_GE, OP_AND, OP_OR}` 加 `{0}`，没有 `OP_ASSIGN`。
2. `T_EQ`（`=`）在 `parse_binary` 直接构造 `EXPR_ASSIGN`（`parser.cr:227`），不经过 `EXPR_BINARY`。
3. `+=` 族（`parser.cr:216-224`）显式构造 `EXPR_ASSIGN(left, EXPR_BINARY(left, right, op∈{ADD,SUB,MUL,DIV}))`，内层 `EXPR_BINARY` 的 op 恒在 {ADD,SUB,MUL,DIV}。

因此全仓唯一构造 `EXPR_BINARY(op=OP_ASSIGN)` 的可能路径不存在。`grep OP_ASSIGN` 全仓命中为 `ast.cr:281` 定义、`checker.cr:2456` 判定、`ir_gen.cr:928` 同分支和注释；语料 0 命中（`assign-binary=0`，70 档）可以佐证。站点 id 不重编号，D25 规定，6 退役为 0 槽并加注记落表。

---

## 4. 表 D：`-1` 面清点（Step 5；report-only，Task 3 的输入清单）

方法：9 个定向探针文件（`/tmp/p5t0/negprobes/d*.cr`）逐形态运行 `check --type-shadow --type-shadow-dump`，使用冻结基线二进制，读取摘要的逐桶计数。成因位 `g_ty_uncovered`/`g_ty_exhausted` 就是 `sh_compare` 在第二次 `ty_budget_reset` 前读出的值，P1 Step 0 口径。`unknown_engine_uncovered` 和 `unknown_engine_budget` 两列是该归因。

| 形态 | 探针 | `decisions` | 引擎负值 | 归因 | 回落 `replace_unknown` | 备注 |
|---|---|---|---|---|---|---|
| 同名字命名（A 对 A） | `d1_named_same` | 4 | 0 | — | 0 | 同行，走快路径 |
| 异名同形命名（A 对 B） | `d2_named_diff` | 4 | 1 | `uncovered` | 1 | 引擎 `AK_NAMED` 不展开（`type_engine.cr:192/:198`），真值面缺口是 Task 3 主目标；legacy 判 0，旧拒，现状靠回落保行为 |
| 同实参泛型应用两次实例化 | `d3b_generic_apply` | 3 | 1 | `uncovered` | 1 | `Box[int]` 两次出现是不同行（`alloc_type` 裸分配），引擎判未知，必须判等，Task 3 用例① |
| 递归命名（`struct Node{next:*Node}`） | `d4_recursive_named` | 6 | 0 | — | 0 | 6/6 agree，包含 4 次字段位；探针本身 rc=1，因为 `next: 0` 字段类型，与本面无关，登记 |
| 容器含命名（`[NA;2]`/`NA?`/`*NA`） | `d5_named_in_container` | 12 | 0 | — | 0 | 元素同行，链元素同项 |
| 泛型形参位（`T` 对 `T`） | `d6_generic_param` | 4 | 0 | — | 0 | 站点 2 命中 2 次 |
| 泛型形参位（`T` 对 `int`） | `d9_t_vs_int` | 2 | 0 | — | 0 | — |
| union/μ 面（`T?` 即 union） | `d7_optional_union` | 3 | 0 | — | 0 | `int?` 同行，同项；μ 面探针数据为 d4，即递归 |
| 元组含命名 | `d8b_tuple_named` | 4 | 0 | — | 0 | — |
| 预算耗尽面 | 用户语料不可达 | — | — | — | — | 全语料 `unknown_engine_budget=0`（70 档）；引擎预算探针只在 `type_selftest.cr` 的 `tt_probe_wide_union`，默认窗口 200000 步 |

`ty_sub` 负值面不可测，用读码审计代替，须在 T3/T4 报告显式标注证据级。冻结二进制没有 `ty_sub` 负值计数通道。`g_ty_uncovered`/`g_ty_exhausted` 只在 `sh_compare` 的 `ty_equiv` 路径被读出并落摘要。`ty_sub` 调用点是 `ti_subsumes`（`checker.cr:470`，T? 注入面，-1 则回 0 不放行）和 `iface_satisfies`/`type_engine` 内部（满足判定或穷尽性域），都没有对外计数。因此表 D 的 `ty_sub` 列没有实测值；如果需要，必须插桩，本任务禁止改源码，转 T3 决定是否用行为探针替代。

清零点，Task 3 Step 2 判据的输入：全语料 72 档加探针语料的 `g_replace_unknown`/`g_replace_bridge` 基线为 0/0。表 C 实测 `replace_unknown=0`，70 档。命名面 -1 只在探针形态出现，语料未覆盖。这解释了语料回落计数为 0 而清零判据仍可能在探针面失败。

---

## 5. 冻结基线产物路径（下游任务的比较基准）

| 用途 | 路径 |
|---|---|
| 冻结三个二进制（pre-P5 同源对拍基准） | `/tmp/p5t0/base/{corec,corearch,corelsp}` |
| 构建日志，2 次，确定性证明 | `/tmp/p5t0/build1.log`、`build2.log` |
| 语料基线（check 面） | `/tmp/p5t0/parity/base_check/{logs,dumps}` 加汇总 `/tmp/p5t0/parity_base_check.out` |
| 语料基线（shadow 面：摘要、站点覆盖、落盘） | `/tmp/p5t0/parity/base_shadow/...` 加 `/tmp/p5t0/parity_base_shadow.out` |
| canary ELF（28822B） | `/tmp/p5t0/pa_base`，sha `95084e7b…` |
| `.ccr` 记录值（两套口径，冷态） | `/tmp/p5t0/pa_ccr.out`（90823B）、`gen_ccr.out`（134701B）、`pa_static.out.ccr`（90966B）、`gen_static.out.ccr`（134844B） |
| 全 op 直方图原始 dump | `/tmp/p5t0/tkhist/*.out`（66 档）加 `/tmp/p5t0/probes/*.out`（9 个探针）加逐档 rc `/tmp/p5t0/tkhist/files.rc` |
| -1 面探针（含 dump 和日志） | `/tmp/p5t0/negprobes/d*.{cr,log,dump}` |
| 自举链、枚举、判据原始输出 | `/tmp/p5t0/{corec2,corec3}`（`4919023b…`）、`/tmp/p5t0/enum_chain.out`（55 档逐档 rc）、`/tmp/p5t0/baseline_run.out`、`/tmp/p5t0/{build1,build2,chain_corec2,chain_corec3,check_self,selftest,canary_build}.log`、`/tmp/p5t0/corearch`（corec2 的同目录后端副本，复现链时必需） |

下游用法，T1 到 T7 的零行为变化判据：`bash /tmp/p3t0_run.sh {check,shadow} <新二进制> <新目录>`，与 `parity/base_*` 逐档 diff，比较 rc 和日志；canary 和 `.ccr` 与上表逐条比。继承口径：比较前 `clean-cache`；`.ccr` 带口径和缓存态；影子“站点覆盖与差异数同报”，Task 5 之前。

---

## 6. 给 T1 到 T6 的输入（哪些测量是哪些任务的前置）

| 任务 | 本任务提供的输入 | 仍缺或未决 |
|---|---|---|
| T1（`.cir` 暖态 SIGSEGV） | 冻结二进制，红态复现基准；`.cir` 缓存面读写点行号（`cir_cache.cr` 430-560）；clean-cache 口径 | 暖态根因本体，由 T1 自测；`CIR_CACHE_VER` 是否需要 bump |
| T2（单槽化 α） | 表 A，51 行分类加后端 ti 消费者 5 分支机器审计加 P4 六个排除项再裁建议；`(op,tk)` 语料直方图；F1 的 op39 伪值；F2 的复合行不可逆；F4 的死 opcode；写点唯一性复核，`df_create_node` 唯一调用点为 `ir_gen.cr:345`，全仓实证 | F1 处置，修调用点还是视作类型行；F2 三条候选先裁；`.cir` 装载侧重派生面（`cir_cache.cr:448-457`）在单槽语义下的等价性，由 T2 自证；`.ccr` NOD 36B 面是否受 op39 决定影响，已知只影响含 hotpatch 的程序 |
| T3（unknown 清零） | 表 D，2 个形态实测 -1 加归因加回落；探针文件可复跑；语料回落计数基线 0/0；站点 2/3/4 的命中面 | `ty_sub` 负值没有计数通道，是否接受读码证据；命名面清零是否覆盖 union/μ，探针负控形态已备；`sh_sig_term_of_ti`（:951）与 `sh_term_of_ti` 两个构造点同构性，由 T3 自证 |
| T4（删 legacy 和回落和站点 6） | 表 B，10 个站点评级加站点 6 三面不可达证明加语料 0 命中；5 处回落钉行号（`type_selftest.cr:1814/:1821/:2487/:2492/:2691`） | 残留 -1 政策，P-A/P-B 推荐 P-A；站点 1/2/4 零命中但在野可达，删挂点前后 `check` 面必须相同 |
| T5（影子层下线和回归检查切换） | 冻结基线的全部比较基准（§5）；站点覆盖基线，可用于“删挂点后判定面不变”的对拍；影子通道引用面（`main.cr:182/236-238/244` 加 `ty_shadow.cr` 站点、环、摘要、转储） | `g_shadow_map` 改名引用面计数，T5 实施时数；corelsp 清单面同核 |
| T6（`EXPR_LET` 判定点） | 冻结基线，红态复现基准：`x: [int;3] = s;` 等三个形态在旧二进制上的 rc | report-only 命中清单，由 T6 自跑；新码还是复用码，需要裁决 |
| T7（收尾） | §5 全部基准加本报告台账 | — |

---

## 7. D-4 开工检查单（Step 6；逐项结论）

| D-4 项 | 结论 |
|---|---|
| 读 D-1 两套口径和冷/热豁免表；新 `.ccr` 记录值带口径与缓存态 | 已读，并实测复现四条（§1.2，差恒 143B 也复核相同）。本报告新增记录值一律标“口径加冷态” |
| D-3-2（项引用稳定形态）先裁再动单槽化 | 计划 D20 已裁，本批不跨进程引用，未来形态为 TYPE 段文件内索引加禁令。本轮追加实测支撑：`.cir` 快照不落项槽（`cir_cache.cr:270-273` 只写 8 字段）；语料 `bad_term=0`，777948 个节点 |
| D-3-4（unknown 清零 (a)/(b)）先裁 | 计划裁-2 为 (a)，命名面判定化。表 D 实测给出该路的实际边界输入：-1 面是异名命名加同实参泛型应用两次实例化，两个形态都是 `uncovered`，不是预算 |
| D-3-7 和 D-3-8 合并评估 | 计划裁-4 为 P6 合批，未覆盖面不得退化为不报错地错值的守门复验留在 P5。本任务不触布局面 |
| D-3-9-(ii) 暖态 SIGSEGV 是否随 P5 先修 | 计划 Task 1 排入，独立可做。冻结二进制是红态复现基准 |
| D-3-14（#32）排入 P5 任务面 | 计划 Task 6 排入，report-only 先行 |
| 全部判据沿用（五个 CI job、全枚举、canary、cmp、N06、冒烟、同源对拍） | 计划 Global Constraints 逐字继承，本报告给出全部基准值 |

本任务新增的开工前未决项，交维护者或 T2 裁决，不预判：§6 的 F1 处置和 F2 三条候选，T2 开工前必须落纸，否则 Task 2 Step 1-⑤ 的派生码不变量不可满足。

---

## 8. 证据路径和运行时间线

- 驱动脚本：`/tmp/p5t0/baseline_run.sh`（Step 1/2 判据全量）、`/tmp/p5t0/tk_hist.sh`（表 A 直方图）、runner `/tmp/p3t0_run.sh`，sha `12dc571f…`。
- 逐段原始输出：`/tmp/p5t0/baseline_run.out`（含时间戳）、`/tmp/p5t0/parity_base_{check,shadow}.out`、`/tmp/p5t0/tkhist/*.out`、`/tmp/p5t0/negprobes/d*/log`、`/tmp/p5t0/probes/*.out`。
- 并发面：全程用 `ps` 抽查，没有第二个构建者；唯一并行是仓库外 PhoneToolbox 的 cc1plus，不写本仓；本任务内所有 corec 调用串行，探针、直方图、对拍各段之间不重叠。

---

## 9. 提交和源码零改动（Step 7）

- 源码改动为 0。`src/**`、`tests/**`、`build_selfhost_native.py` 零命中；`jj status` 收尾除本任务提交外无改动；`jj diff -r <提交> --summary` 实核恰好 1 个路径。
- 提交为 `2b9b5463`（change `qrsppwnx`，路径限定 `docs/superpowers/plans/2026-09-13-r2-p5-cleanup.md` 单个文件，内容是计划 Task 0 七步勾选加“Task 0 实施记录”块）。本报告与其他 `docs/archive/sdd/*` 报告同档，不入版本控制，`jj status` 不含该目录，已实核。
- 提交后工作副本为 `354df25c`，空提交，供下游任务从 T1 起继续。
