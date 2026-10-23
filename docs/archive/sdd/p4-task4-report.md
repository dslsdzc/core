# R2 P4 Task 4 报告：DFNode.TK 迁移期双槽（允许清单制项派生 + `.cir` 快照不落槽（计划 D15 修正）+ 发射面零泄漏证明）

日期：2026-09-13 · 基线：`8f4af99b`（P4 Task 3；`check src/compiler` rc=0；selftest 347/347）
任务：计划 `docs/superpowers/plans/2026-09-12-r2-p4-carrier.md` Task 4，按 裁决 8（canary 不变，变即停下上报）、D15（内存双槽）实施；裁决 5/6（Task 5/6）本批不触。
口径：所有命令 `nice -n 19`；cwd = 仓库根；一构建一编译串行；任何 `.ccr`/缓存态比较前 `clean-cache`；数字 = 本轮实跑。无「停下上报」触发（canary IDENTICAL，见 第 5 节）。

---

## 0. 交付摘要（摘要）

| 项 | 结果 |
|---|---|
| 双槽形态（内存） | `ESZ_DFNODE` 从 64B 改为 72B；`OFF_DF_TK=40` 语义/字节零变化；新增 `OFF_DF_TK_TERM=64`（类型项引用，-1 = 无项） |
| 项槽派生 | `sh_tk_term_of_code(opcode, tk)` = 允许清单制：`{IR_CONST, IR_BINARY}` ∧ `0 ≤ tk < g_type_count` 因此 `sh_term_of_ti(tk)`（复用桥接层，无第二套建项逻辑）；其余 -1 |
| 写点 | 唯一 = `df_create_node`（emit 传参）；`dataflow.cr` 零前端/桥接符号引用（共享文件纪律） |
| `.cir` 快照 | 不落项槽（记录仍 8×8B = 64B）；`CIR_CACHE_VER` 保持 17（计划 D15 的「入槽 + 17到18」被实测推翻，第 4 节）；装载侧 emit 等价时点重派生 |
| `.ccr` 面 | NOD 36B/条不变；用户程序八段逐字节同（`ptr_arith` 90823B `fb4a3b59…` · `generics_test` 134701B `cafb4278…`）；`--dump-objects` 逐字节同 |
| 新通道 | corec hidden flag `cir --dump-tk-terms`（逐节点 `op/tk/term/tag/a/b/c` + 头行计数；只读） |
| 判据 | 构建 rc=0（三面 `error[`=0）· `check src/compiler` rc=0 · ELF canary `95084e7b…d475` IDENTICAL · selftest 355/355 · `test_ccr_types` 34/34 · 全枚举 54/54 · 五 CI job rc=0 · `corec2==corec3` cmp IDENTICAL + N06=0 + 冒烟 42 |
| 突变控制 | 2 条逐条变为失败（移除清单门和 hits 复原后，Python ㉖ 和 selftest 4 例失败；移除装载侧派生后，㉙ 失败） |
| 提交 | `387abf2e`（change `knxprmly`），路径限定 13 文件（第 11 节） |

---

## 1. 双槽实现（D15；`dyn_arr.cr` / `dataflow.cr` / `ir_gen.cr`）

```
ESZ_DFNODE : int = 72;   // opcode,dest,s1,s2,s3,type_kind,first_edge,edge_count,tk_term = 9×8
OFF_DF_TK        : int = 40;   // 语义/字节零变化（混用码：类型行 + 旗标/宽度码）
OFF_DF_TK_TERM   : int = 64;   // 类型项引用（-1 = 无项）
```

- `df_create_node(opcode, dest, src1, src2, src3, type_kind, tk_term)`：第七参 = 项引用，仅存储
  （不解释/不校验/不派生）；函数头注写明「共享文件零前端依赖」纪律。唯一调用点 = `ir_gen.cr` 的 `emit`
  （全仓 grep 实证：定义 1 处 + 调用 1 处 + 注释 4 处）。
- `emit`：`df_create_node(..., type_kind, sh_tk_term_of_code(opcode, type_kind))`（时点 = emit 期，
  不后移到 save 前，理由见计划 Step 3：快照逐函数写，后填 = 冷/暖分歧一类）。
- 既有 `tk` 消费者零改动（逐一核对）：`instr.cr`（`iri_tk`）/`regalloc.cr`/`dump.cr`/`ccr_io.cr` 的 NOD
  写读/`interp.cr`/`provenance_verify.cr` ，读的都是 `OFF_DF_TK` 或 `iri_tk`；`w64(g_df_nodes, … OFF_DF_TK)`
  的其它写点（`provenance_verify.cr` 改 s3/s2/dest）与 tk 无关。
- 步长单源：全仓 `g_df_nodes` 访问皆 `n * ESZ_DFNODE + OFF_*`（无裸 64 乘数）；`grow_df_nodes` 亦用
  `ESZ_DFNODE` 因此 扩槽对全部既有消费者透明。

## 2. Step 2：允许清单推导（先于实现；产物 = 下表）

两步交集：① 后端按 `ti` 分派发射（`instr.cr` 逐分支审计）× ② 该 op 的 `tk` 由调用点传类型行。

① 后端 `ti` 消费者全表（`instr.cr` 全文件 grep = 5 处，逐条审计）：

| 位置 | op | `ti` 语义 | 分派作用 |
|---|---|---|---|
| `instr.cr:485` | `IR_CONST` | 类型行 | `ti == TI_STR` 时走字符串常量路径（rodata + patch 登记） |
| `instr.cr:502` | `IR_BINARY` | 类型行 | `ti == TI_DEX` 时走 SSE2 binary64 路径 |
| `instr.cr:1089` | `IR_DEREF` | 访问宽度（字节） | 传 `e2_ptr_bounds_check` 的 `access_width` |
| `instr.cr:1120` | `IR_STORE_PTR` | 访问宽度（字节） | 同上 |
| `instr.cr:1319` | `IR_BOUNDS_CHECK` | 旗标 0/1 | `ti != 0` 时启用动态上限（载长度变量） |

（`regalloc.cr:457` 的 `tk == TI_DEX/TI_DEX_S` = dex 危险面（按值面读，非按 op 分派）；`dump.cr:125` 的
`type_kind_name(iri_tk)` 只服务 `IR_ALLOC` 文本面，两者都不构成「按 ti 分派发射」。）

② 调用点 `tk` 实参（`ir_gen.cr` 216 个 `emit(` 逐 op 自动抽取 + 人工复核）：

| op | 调用点传入的 `tk` | 类型行？ |
|---|---|---|
| `IR_CONST` | `TI_INT/TI_DEX/TI_DEX_S/TI_BOOL/TI_STR/TI_CHAR/const_type`（34 处） | 是 |
| `IR_BINARY` | `TI_INT/TI_DEX/TI_DEX_S/TI_BOOL/fti` + 比较族 5 处传 `0`（= `TI_INT` 行） | 是 |
| `IR_BOUNDS_CHECK` | `1`（动态上限，3 处）· `0`（字面量上限，4 处） | 否（旗标） |
| `IR_DEREF`/`IR_STORE_PTR` | `ptr_access_width(...)`（宽度码） | 否（宽度） |
| `IR_ALLOC`/`IR_CALL`/`IR_I2F`/`IR_F2I`/`IR_LOAD` | 类型行（`TI_INT/TI_UNIT/TI_STR/TI_BOOL/call_ti/target_ti/TI_DEX`） | 是，但 ① 不成立 |
| 其余全部 op | `0` / `-1`（`IR_SPAWN`）；无类型语义 | 否 |

因此 ① × ② = 恰 `{IR_CONST, IR_BINARY}`（`IR_BOUNDS_CHECK`/`IR_DEREF`/`IR_STORE_PTR` 在 ① 内但 ② 出局；
`IR_ALLOC`/`IR_CALL`/`IR_I2F`/`IR_F2I`/`IR_LOAD` 反之）。

全语料 (op, tk) 实测直方图（NOD 段读取 = 发射面真值，非抽样）：

- 自源 `src/compiler/_import.cr`（146540 节点）：`op1(const) tk∈{0,2,3}` · `op2(binary) tk∈{0,2}` ·
  `op3/4/5/6/7/9/12/19/20/21/32/33/46/47 tk=0` · `op4(call) tk∈{0,2,3,4}`
- `tests/suite/ptr_arith.cr`（1298 节点）：`op25(deref) tk=8` · `op26(store_ptr) tk=8`，访问宽度 8
  数值上恰是 `TI_DEX_S` 行；无差别派生 = 给指针解引用凭空安 dex 项
- `tests/suite/dex_test.cr`：`op1 tk∈{0,1,2,3,8}` · `op2 tk=1`（真 TI_DEX，SSE2 路径） · `op4 tk=8`
- `IR_BOUNDS_CHECK` 两态（tk=0/1）由探针夹具实测（`sl[lo..hi]` 切片动态界）

清单门（`sh_tk_term_of_code`）：`opcode ∉ {IR_CONST, IR_BINARY}` 时返回 -1；`tk < 0 ∨ tk ≥ g_type_count` 时返回 -1；
否则 `sh_term_of_ti(tk)`（原生快路径 / 桥接缓存，同项）。副纪律：该调用复原 `g_shadow_hits`
（hits = 判定站点缓存效率统计；emit 期派生不是判定站点），不复原 `g_shadow_entries`（装填因子输入 =
真实占用槽数，复原即欺骗扩容守卫）。

## 3. 用例（实施 = 用例与实现同提交，有效性由突变控制承担；同 T2/T3 纪律）

`selftest-types` +8 例（从 347 增加到 355）：`t4.tk_const_int`（const×TI_INT 因此 与桥接层同项且 AK_INT）·
`t4.tk_binary_dex`（binary×TI_DEX 因此 AK_DEX）· `t4.tk_const_dex_s_row8`（行 8 = dex_s 因此 AK_DEX，同值域不同表示）·
`t4.tk_bounds_flag1_rejected`（旗标 1 被拒 ∧ 直译 `sh_term_of_ti(1)` 有值，证明拒绝出自清单门而非「行不可译」）·
`t4.tk_deref_width8_rejected`（同款宽度 8=行 8 陷阱）· `t4.tk_unlisted_op_valid_row_rejected`（行合法但 op 不在清单：
`IR_STORE`/`IR_CALL`/`IR_ALLOC` × TI_INT）· `t4.tk_row_range_rejected`（`g_type_count` / `+7` / `-1`）·
`t4.tk_derivation_not_a_shadow_site`（非原生行数组行预热后二次调用 因此 hits 不变；用 TI_INT 测会恒真）。

`test_ccr_types.py` +6 例（从 28 增加到 34；㉖..㉛）：

| # | 用例 | 覆盖面 |
|---|---|---|
| ㉖ | `test_p4t4_tk_slot_rule_per_node` | 逐节点：清单内 op 因此 `term ≥ 0 ∧ tag == TT_ATOM ∧ b == tk`；清单外 因此 `-1`；三陷阱非空断言（deref_w8 / store_w8 / bounds_flag0+flag1 / call_row）；正控四行（0到AK_INT · 2到AK_BOOL · 3到AK_STRING · 8到AK_DEX） |
| ㉗ | `test_p4t4_tk_slot_dex_binary_corpus` | `dex_test.cr` 语料：`IR_BINARY×TI_DEX` 与 `IR_CONST×{TI_DEX,TI_DEX_S}` 因此 dex 原子（非空断言防没有实际作用） |
| ㉘ | `test_p4t4_ccr_nod_tk_equals_graph_tk` | NOD 36B/条（独立解析）+ NOD `(op,tk)` 与 DF 节点 `(op,tk)` 逐位置相同（1:1 同序），tk 零变化的 .ccr 侧证据 |
| ㉙ | `test_p4t4_cold_warm_term_slot_symmetry` | 冷（emit 填）/暖（快照恢复 + 装载侧重派生）两态 (op,tk,term,tag,a,b,c) 逐行相同 + 头行相同 + `bad_term=0` + 命中证据（暖运行不重写缓存） |
| ㉚ | `test_p4t4_dump_flag_zero_artifact_effect` | 带/不带 flag 的 `.cir` 产物与 stdout（剔 dump 节）逐字节同（两轮之间清缓存以避开既有冷/热渲染差异） |
| ㉛ | `test_p4t4_cir_snapshot_layout_unbumped` | 快照条目版本位 == 17 + 节点小节 = 8B 计数 + n×64B（`>0` 节点防没有实际作用），「不落槽、不 bump」的格式事实 |

## 4. `.cir` 快照面：计划 D15「入项槽 + 17到18」被实测推翻（本任务最重要的实施偏差，显式登记）

计划文本（D15/Step 4）：写点加第 9 槽、读点对称、`CIR_CACHE_VER` 17到18；理由 =「不入槽则 cache-hit
恢复路径与冷路径分歧」。

实测（本任务新增 `--dump-tk-terms` 通道，`ptr_arith`，全命中暖运行）：

| 设计 | 冷路径 | 暖路径 | 结论 |
|---|---|---|---|
| 入槽版（首轮实现，`17到18`） | `nodes=1298 with_term=329 bad_term=0 terms=13` | `nodes=1298 with_term=329 bad_term=329 terms=10` | 暖路径恢复来的项引用全数越出暖进程项表 |
| 不落槽 + 装载侧重派生（最终） | `… bad_term=0 terms=13` | `… bad_term=0 terms=13`，1298 行逐行相同 | 冷/暖同项同索引 |

根因：`g_type_terms` 是进程内内容寻址表、项按需惰性创建（emit 期本语料新增 3 项）因此 快照里的
项索引只在写侧进程的索引空间成立；暖路径若跳过 emit（全命中）则项表更短（10 < 13），恢复出的索引
整体悬空，一旦有消费者，读到的就是错项或越界内存（正是本批要消灭的不报错地类）。附因：把 `f(tk)` 的
纯函数值与其入参 `tk` 并存于同一记录 = 第二真源（本仓反复治过的病），分歧时盘面值不报错地胜出。

修正（根因级）：盘记录仍 8×8B（布局零变化 因此 不 bump）；装载侧在 emit 的等价时点（逐函数、逐
节点序）用 `sh_tk_term_of_code(opcode, tk)` 重派生 因此 ① 值在当前进程有效；② 项表追加序与冷路径
一致 因此 冷/暖同项同索引（㉙ 锁住）。旧条目无需失效：格式未变 + v17 身份字段已覆盖跨二进制面
（`CIR_CACHE_VER` 的手工 bump 因此无对象，本任务未 flip `test_cache_identity.py:VER_EXPECTED`，
该 pin 保持 17 正是因为格式未变；这一点与「格式一变必 bump」的既有纪律无冲突：没变）。

登记（P5 前置裁决项）：单槽化时 `tk` 本身成为项引用 因此 项引用的稳定形态（内容寻址 / 落盘项 ID /
同款重派生）必须先定；不得直接落进程内索引（本次 `bad_term=329` 即该形态的失败证据）。

## 5. 判据（逐条 = 命令 + 结果；全部在最终二进制 `1cc18c7d…` 上复跑）

| # | 判据 | 命令 | 结果 |
|---|---|---|---|
| 1 | 三二进制构建 | `nice -n 19 python3 build_selfhost_native.py` | rc=0；GUARD：corec 45 / corearch 32 / target 3 / corelsp 31；三条 `build log clean (error[ = 0, undefined = 0)` |
| 2 | project-mode 守卫 | `nice -n 19 python3 tests/selfhost/test_backend_bootstrap.py` | rc=0 + `error[` 命中 = 0 |
| 3 | 自源 check | `nice -n 19 ./build/corec check src/compiler` | rc=0（`ok`） |
| 4 | 类型引擎自测 | `nice -n 19 ./build/corec selftest-types` | 355/355（从 347 增加 8 例） |
| 5 | ELF canary（裁决 8 硬判据） | 先 `clean-cache`，再 `build tests/suite/ptr_arith.cr -o /tmp/p4t4/pa_final --static`，最后取 sha256 | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475` IDENTICAL（无「停下上报」触发） |
| 6 | `.ccr` 零扰动（用户程序） | 冷缓存 `ccr` × {基线 `8f4af99b` 构建，新构建} + 八段逐段 cmp | `ptr_arith` 90823B `fb4a3b59…` · `generics_test` 134701B `cafb4278…`：八段全 IDENTICAL |
| 7 | `.ccr` 自源（源已变，登记） | 同上（`src/compiler/_import.cr`） | 10476106B `49c94c7f…`（新记录值）；源本身变更（新代码 + 新串）因此 与 T3 的 10418710B 不可比；TYPE/IFACE 同尺寸但内容随 STR 索引移动（裁决 1 接受面） |
| 8 | `--dump-objects` | 基线/新 corearch × 同 `.ccr` | 逐字节同（2427 行） |
| 9 | 结构性断言套件 | `test_ccr_types.py` / `test_ccr_v7.py` / `test_region_cfg.py` / `test_cache_identity.py` | 34/34 · 27/27 · 22/22 · 5/5（全枚举内含） |
| 10 | 全枚举 | `bash /tmp/p4t4/enumerate.sh`（47 selfhost + 7 bootstrap） | 54/54 全 rc=0 |
| 11 | 五 CI job | `CI_JOB_NAME=<j> bash src/ci/run.sh` ×5 | 全 rc=0（check / bootstrap-tests / selfhost-tests / suite / full-bootstrap） |
| 12 | 自举链 | full-bootstrap job | `cmp /tmp/corec2 /tmp/corec3` IDENTICAL（双 2754918B `55237ec1639cac1b…`）+ N06 = 0（grep 全日志）+ 冒烟 `run 'fn main()->int{return 42;}'` = 42（corec/corec2）+ `corec3 --help` rc=1 |
| 13 | 同源对拍（check 面） | `bash /tmp/p3t0_run.sh check` × {基线和 新} 72 档后执行 diff | diff 空 |
| 14 | 影子对拍（判定面零变化） | `bash /tmp/p3t0_run.sh shadow` × 同上 | diff 空 + trees `diff -r` 空 + 两侧 `decisions=32355 agree=32355`、全计数 0；站点覆盖同报：`assign-node=24561 · fn-body-ret=5747 · if-branch=2013 · struct-field-type=28 · array-elem-type=4 · generic-apply-base=2`（Σ = 32355）。 与 T3 的 32280 不可直接比：语料含编译器自源，本任务改了源（+75 站点）。 继承声明：影子通道对实现方式面零覆盖 |
| 15 | 构建确定性 | `build_selfhost_native.py` ×2（build4/build5） | corec `1cc18c7d…` / corearch `d6340020…` / corelsp `3907000d…` 两次逐字节同 |
| 16 | 突变控制（有效性） | /tmp 侧突变树（`mutA`/`mutB`，仓库零改动） | 第 6 节：2 条逐条变为失败 |
| 17 | 编译耗时抽样 | 6000 语句合成源（≈24k const/binary 发射）×3 + 小语料 | 基线 min 2957ms，新 min 2933ms（噪声内，无回退）；`dex_test` 36 到 36ms · `generics_test` 26 到 27ms |

## 6. 突变控制（有效性；/tmp 侧「清单照旧 + 内容替换」构建，仓库源码零改动）

harness = `/tmp/p4t4/mutA`、`/tmp/p4t4/mutB`（`build_selfhost_native.py` + `bootstrap`/`src` 实拷贝 + `tests` 软链）；
驱动 = `/tmp/p4t4/run_t4.py`（把测试模块的 `COREC`/`COREARCH` 指向突变二进制）。

| 突变 | 内容 | 期望 | 实测 |
|---|---|---|---|
| A（清单门 + hits 复原同时移除） | `ty_shadow.cr`：`sh_tk_term_of_code` 删 `opcode ∉ {CONST,BINARY}` 时返回 -1 一行；删 `g_shadow_hits` 复原两行 | ㉖ 变为失败 + selftest 4 例变为失败 | ㉖ FAIL（`node 0: non-allowlisted op 32 got term 10`）；selftest 351/355（`t4.tk_bounds_flag1_rejected` / `t4.tk_deref_width8_rejected` / `t4.tk_unlisted_op_valid_row_rejected` / `t4.tk_derivation_not_a_shadow_site` 四条变为失败），两类陷阱（旗标 1 / 宽度 8）逐条被固定 |
| B（装载侧重派生移除） | `cir_cache.cr`：删恢复循环里的 `w64(... OFF_DF_TK_TERM, sh_tk_term_of_code(...))` | ㉙ 变为失败 | ㉙ FAIL：暖态 `with_term=1354`（全节点带陈旧值）vs 冷 `348` 因此 冷/暖分歧被抓 |

出树证据：两条突变分别建在 `/tmp/p4t4/mut{A,B}/build/`，与仓库二进制（`1cc18c7d…`/`d6340020…`）不同文件；
仓库在突变前后 `jj status` 干净 + 第 5 节-#15 的重建逐字节同证明源码零改动。

## 7. 登记面与 Concerns

① `.cir` 快照不载项槽（第 4 节）：格式零变化 因此 无 bump、无失效面；代价 = 暖路径每节点一次桥接查询
（仅清单内 op 有实际工作），实测耗时无回归（第 5 节-#17）。P5 单槽化时若要「盘上有项」，须先定稳定引用形态。

② `tk_term` 本批无生产消费者：价值由 ㉖/㉗ 的内容断言 + ㉙ 的对称断言兑现（不假装有外部消费者，
计划 Step 6 要求）。`.csr`/TagNode 图消费面（spec 第 6.4 节）仍无调用者。

③ 项槽的「项索引 = 进程内表索引」天性未消除（只是不落盘）：同一进程内跨编译（corelsp 长驻 /
D13 的 `tt_layer_reset`）后旧索引失效，本批的读点只在 emit 期与装载期（同进程、表未复位），
无跨复位消费者；引入消费者（P5）时必须同时解决。

④ `--dump-tk-terms` 的 `bad_term` 计数是有意的三态暴露面（越界项不得不报错地读内存）；冷/暖等值由 ㉙ 断言。

⑤ 既有冷/热 `cir` 文本 dump 渲染差异（变量名 vs 数字）：baseline 二进制度量 = 1620 行 diff
（`/tmp/p4t4/base_coldwarm.diff`）因此 非本任务引入（TODO #5 末条）；本任务的新通道打印原始整数，
不受其影响（㉙ 用 `--dump-tk-terms` 而非全文对拍）。

⑥ pin flip 清单（逐条）：`src/ci/run.sh` 的 selftest-types 计数注释 346 改为 355；`test_ccr_types.py`
计数注释 28 改为 34。未 flip：`tests/selfhost/test_type_engine.py:MIN_CASES = 32`（下限而非等式；
建议后续批次收紧到实测值，本批不动，登记）；`test_cache_identity.py:VER_EXPECTED = 17`（格式未变，
按 第 4 节 保持）。消费者改动清单：`ir_gen.cr` 的 `emit`（传参）、`cir_cache.cr` 装载循环（派生）、
`dump.cr`（新函数）、`main.cr`（新 flag 注册 + cir 分支调用）、`dyn_arr.cr`（布局）、`dataflow.cr`
（签名 + 存储），其余消费者零改动。

⑦ 陈旧文档（非本任务引入，登记）：`docs/superpowers/specs/2026-09-11-explain-predict-incremental-design.md:371`
称 `CIR_CACHE_VER = 14`（T3 时已为 17），该文件是 spec 的现状快照，未随批更新；本任务不顺手改（避免扩面）。

⑧ 自源 `.ccr` 记录值不可与 T3 直比（源已变）；用户程序零扰动证据（㉓/第 5 节-#6）才是本任务的判据面。

## 8. 提交（路径限定 13 文件）

```
387abf2e（change knxprmly）feat: R2 P4 Task 4，DFNode.TK 迁移期双槽（ESZ_DFNODE 64到72…）+ .cir 快照
        CIR_CACHE_VER 保持 17 …；发射面零泄漏 …
13 文件（M×13）：src/compiler/{dyn_arr,dataflow,ir_gen,ty_shadow,cir_cache,dump,main,type_selftest}.cr ·
        tests/selfhost/test_ccr_types.py · src/ci/run.sh ·
        docs/superpowers/plans/2026-09-12-r2-p4-carrier.md（Task 4 七步 + D15 修正）·
        docs/superpowers/specs/2026-09-10-type-interface-unification-design.md（第 6.2 节 落地记录）· TODO.md（#42）
```

`jj diff -r 387abf2e --summary` 核过 = 恰上列 13 路径；提交后 `jj status` = 工作副本干净（空提交 `a6f24f5d`）。

## 9. 证据路径（本机）

- 基线（父提交 `8f4af99b` 构建）：`/tmp/p4t4/base/{corec,corearch,pa_pre,pa_pre.ccr,gen_pre.ccr,self_pre.ccr}`
- 构建日志：`/tmp/p4t4/build{1..5}.log`（5 = 最终确定稿；1 = 入槽版、3 = 派生版）
- 判据：`/tmp/p4t4/pa_final`（canary） · `check_self.log` · `tbb.log` · `enum_all.log` + `/tmp/p4t4/enum/*.log`
- CI：`/tmp/p4t4/ci_{check,bootstrap-tests,selfhost-tests,suite,full-bootstrap}.log` · `/tmp/corec2`·`/tmp/corec3`
- 冷/暖与规则：`/tmp/p4t4/pa.{cold,warm}.txt` · `pa.cold.rows.txt`/`pa.warm.rows.txt` · `pa.dump.txt` ·
  `base_coldwarm.diff`（既有冷/热渲染差异基线）
- 记录值：`/tmp/p4t4/rec_{pa,gen,self}.ccr` + `/tmp/p4t4/{cmp_seg.py,seg.py}`
- 对拍：`/tmp/p4t4/parity/{pc,ps}_{pre,new}.out` + `parity/ps_{pre,new}/{logs,dumps}`
- 突变：`/tmp/p4t4/mut{A,B}/` + `mut{A,B}.log` + `/tmp/p4t4/run_t4.py`
- 耗时：`/tmp/p4t4/timeit.py` + `/tmp/p4t4/big.cr`（6000 语句）
