# R2 P2a Task 1（F1）报告：同名 `TYP_NAMED` 建表去重

状态：完成（判据全绿）
提交：jj change `ttvstzsotsmxumtkyvylplpxwoxswurn`（短 `ttvstzso`）/ commit `3c8402e894139bafe92d69edf58986815b2dbab4`（短 `3c8402e8`），路径限定 3 文件 `+178 / -8`：
`src/compiler/checker.cr` · `src/compiler/globals.cr` · `src/compiler/type_selftest.cr`
裁决落点（用户）：根治 = 类型表建表去重（唯一分配点收敛），非桥接层规避。

---

## 1. 判据总表

| # | 判据 | 结果 | 原始证据 |
|---|------|------|----------|
| 1 | `selftest-types` 全 PASS | 77/77（72 基线 + 5 新用例，见 第5 说明） | `77/77 type-engine cases passed`，rc=0；`tests/selfhost/test_type_engine.py` PASS（MIN_CASES=32 下限，不锁总数） |
| 2 | ELF 与基线逐字节相同 | IDENTICAL | 第3 原始输出 |
| 3 | `test_ccr_v7` 结构判据全绿 | 24/24 passed | 第4 |
| 4 | `test_compile` 过 | All selfhost compile tests passed.（冒烟 42） | 第4 |
| 5 | `.ccr` 变化实测并记录 | 3 个语料全部逐字节未变 | 第4（含"仅加用例"对照实验） |
| 6 | 全量回归（项目标准 14 套 + 加固 21 套） | 35/35 套件 rc=0，0 失败 | 第6 |

---

## 2. 实现（侧表 + 唯一分配点）

`checker.cr:19-144`（新块，位于 `alloc_type` 之后）：
`NAMED_DEDUP_INIT_CAP=1024` · `named_dedup_init` · `named_dedup_reset` · `named_dedup_probe` · `named_dedup_rehash` · `named_dedup_slot` · `alloc_named_type` · `named_dedup_rows`

- 侧表 `g_named_dedup`（`globals.cr`，16B/条 `{name_idx, ti}`，开放寻址线性探测，与 `ty_shadow.cr` 的 `g_shadow_map` 同式）。
- P0/P1 三件套逐条实施（文件头注逐条写明缺失后果）：①装填因子守卫（探测前 `(count+1)*2 >= cap` 到 重建）②重建 + 重放既有条目（count 随重放重算；重放借道 `named_dedup_probe` 不经守卫 = 防递归）③回写前重探（`slot2`）。
- 键 = `name_idx`（8 处实参恒 `(TYP_NAMED, name_idx, 0)`，extra 恒 0 不入键）；空槽哨兵 = `-1`。
- 防御分支两条（均注释标注当前不可达）：负键不进侧表（否则与空槽哨兵同形 到 空槽读成命中 到 返回 ti=0 = TI_INT 不报错地错型）；回写重探命中则不覆盖活跃条目（反例写法会丢登记）。
- `init_types()` 增 `named_dedup_reset()`（`cap=0` 到 惰性重建）：类型表重置 = 行号空间作废，陈旧的 name到ti 不得跨重置复用。可达且必需（初版注释误标「不可达防御」，Task 1 评审 C-3① 纠错，已改）：`reset_frontend_state()`（`globals.cr:332`）清 `g_type_count` 却不碰侧表，而 LSP `lsp_check_file`（`src/lsp/lsp.cr:168到172到187`）每请求走 `reset 到 check_all`（`check_all` 首行即 `init_types`）；`reset_frontend_state` 不清字符串表 到 长驻进程内 `str_intern` 下标跨请求稳定 因此 陈旧 name到ti 必然命中并返回上一请求的行号（越界/错行不报错地错型）。

语义面核对结论（实读，非推断）：读取点经 `get_type_data(ti)` 取名字（`:496` 是解引用到名字的唯一入口）到 按名字归一行不改这些点读法。唯一例外已如实登记：`type_equal_core` 的 `TYP_GENERIC_APPLY` 分支（`:143-144`）比 `get_type_data` = `base_ti`（基型行号），去重把「同名字不同出现点 因此 不等」改成「同名 因此 同 base 行，继续比实参」，这正是 F1 修复的目的（P1 差异的对偶面），其放宽面属 Task 3 对拍复跑量化面（见 第7 C-1）。

---

## 3. ELF 判据原始输出

```
$ nice -n 19 ./build/corec clean-cache
cleaned .core/cache/cir/
$ nice -n 19 ./build/corec build tests/suite/ptr_arith.cr --static -o /tmp/p2a_t1_bin
 -> /tmp/p2a_t1_bin
$ cmp /tmp/r1t4_base_bin /tmp/p2a_t1_bin && echo ELF-IDENTICAL
ELF-IDENTICAL
$ sha256sum /tmp/r1t4_base_bin /tmp/p2a_t1_bin
95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475  /tmp/r1t4_base_bin
95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475  /tmp/p2a_t1_bin
```
不变前提未被破坏 到 类型信息未泄进编码层（无需走「停下上报」分支）。

---

## 4. `.ccr` 变化实测（允许变，须报告）

结论：实测未变。方法 = 改动前（P1 收官二进制，`jj status` 干净）先用 `corec ccr` 冻结 pre 基线，改动后同命令重放。三条语料含结构体密集（`at_test_struct`）与泛型（`generics_test`）面：

| 语料 | pre sha256 | post sha256 | 判定 |
|------|-----------|-------------|------|
| `tests/suite/ptr_arith.cr` | `bb9cbdb87f4f8342f604052204632f76c5114f6f03088d216033ed71c6e734b5` | 同左 | IDENTICAL（`cmp` 无输出） |
| `tests/suite/at_test_struct.cr` | `53ebcf122deb6997a5ba5a2802b554297a716202d2d79e81991e72a3ad729122` | 同左 | IDENTICAL |
| `tests/suite/generics_test.cr` | `2132d565778c866b871700e599a3a58667e5ef3e0430c94cd5b93c75a42c5c42` | 同左 | IDENTICAL |

对照实验（归因隔离）：红态桩阶段（`alloc_named_type` = 裸 `alloc_type` = 旧行为）+ 全部新增用例 + 新 globals 已入树时，两条产物均与 pre 基线逐字节同（`STUB-ELF-IDENTICAL`；桩 `.ccr` sha == pre `.ccr` sha `bb9cbdb8…`）到 用例/全局新增本身不动产物，上述「未变」可归因到去重实现本身而非工程噪声。

覆盖缺口（如实登记）：未测自指语料（编译器自身）的 `.ccr`，那正是 P1 语料（ti 可上数千，最可能暴露行号位移）。归口 Task 3 对拍复跑。

---

## 5. 8 个分配点改动对照（brief Step 4）

| # | 改前（行号 = P2a 计划期） | 改后（本提交行号） | 语义位置 |
|---|---|---|---|
| 1 | `:406 return alloc_type(TYP_NAMED, name_idx, 0);` | `:534 return alloc_named_type(name_idx);` | `res_type_node` 常规命名型（未注册符号） |
| 2 | `:554 type_idx := alloc_type(TYP_NAMED, name_idx, 0);` | `:682 type_idx := alloc_named_type(name_idx);` | struct 注册（`si_name`） |
| 3 | `:598` 同上 | `:726` 同上 | iface 注册（`OFF_IF_NAME`） |
| 4 | `:613 option_ti := alloc_type(TYP_NAMED, option_name_idx, 0);` | `:741 option_ti := alloc_named_type(option_name_idx);` | 内建 `Option` 自动注册 |
| 5 | `:622` 同 #2 | `:750` 同上 | enum 注册（`ei_name`） |
| 6 | `:920 return alloc_type(TYP_NAMED, name_idx, 0);` | `:1048 return alloc_named_type(name_idx);` | `res_call_type` 常规命名型 |
| 7 | `:2191 base_ti := alloc_type(TYP_NAMED, name_ni, 0);` | `:2319 base_ti := alloc_named_type(name_ni);` | 泛型 struct 字面量的基型（`TYP_GENERIC_APPLY.base`） |
| 8 | `:2206 ti := alloc_type(TYP_NAMED, name_ni, 0);` | `:2334 ti := alloc_named_type(name_ni);` | 非泛型 struct 字面量 |

全仓核对：`grep -rn "alloc_type(TYP_NAMED" src/` 仅余 ①侧表内部 2 行（`:117` 负键防御 / `:120` 真分配）②`type_selftest.cr:256` 的 P1 桥接夹具（人造行，刻意走裸分配不登记侧表，已就地加注说明，防「第 9 处漏改」误读）。

### 守门用例（brief Step 1 的 4 条 + 1 条扩容覆盖）
`src/compiler/type_selftest.cr`（追加于 P1 桥接节之后）：
`f1.same_name_one_row` · `f1.row_count` · `f1.diff_name_diff_row`（负控）· `f1.bridge_same_term`（引擎侧同一性）+ `f1.dedup_rehash_survived`。
第 5 条为超出 brief 的补面：入 1700 个互异真名推过两道守卫线（count=511 到 cap 1024到2048；count=1023 到 2048到4096），断 ①cap≥4096（两次重建真的发生，非读码判安全）②重放计数守恒（恰 +1700）③首条仍归原行 ④行数仍 1。理由 = 本任务自身的 P0/P1 教训（「守卫/重建重放路径判据不可达 = 挂死风险只靠读码」，P1 曾为此在 Step 4b 补 `bridge.grow_rehash2`）；brief 的 4 条覆盖不到该路径。总数因此为 72+5=77 而非 72+4=76（计划若须回填请按 77）。

---

## 6. 红态输出（TDD Step 2）

采用断言级红（强于「未定义符号 到 构建失败」）：先落临时桩 `alloc_named_type = alloc_type(TYP_NAMED, …)`（= 旧行为）+ 真 `named_dedup_rows`，使 5 条用例可运行并真实变红：

```
$ nice -n 19 ./build/corec selftest-types     # 桩态
...
FAIL f1.same_name_one_row: got 0 want 1        ← 两次分配得两行（n1 != n2）
FAIL f1.row_count: got 2 want 1                ← 同名占 2 行 = 根因直证
PASS f1.diff_name_diff_row                     ← 负控（旧行为下亦应成立）
FAIL f1.bridge_same_term: got 0 want 1         ← 桥接原子不同 到 引擎判不了（9/9 unknown 根因）
FAIL f1.dedup_rehash_survived: got 0 want 1
73/77 type-engine cases passed
```
实现后（去桩）：
```
PASS f1.same_name_one_row
PASS f1.row_count
PASS f1.diff_name_diff_row
PASS f1.bridge_same_term
PASS f1.dedup_rehash_survived
77/77 type-engine cases passed
```
（桩已删除；最终提交树内不含桩代码。）

---

## 7. 回归与关注点

回归（最终提交态实测）：项目标准 14 套 ①`test_type_engine` PASS ②`test_compile` PASS（冒烟 42）③`test_backend_bootstrap` PASS ④`test_hit_table` 24/24 ⑤`test_ccr_v7` 24/24 ⑥`test_live_ranges` 13/13 ⑦`test_slice_bounds` 7/7 ⑧`test_global_init` 15/15（双路径）⑨`test_lexer_parity` PASS ⑩`bootstrap/test_pipeline` 29/29 ⑪`bootstrap/test_borrow` 4/4 ⑫`bootstrap/test_generics` 3/3 ⑬`test_impl` 7/7 ⑭`test_borrow` 7/7；加固 21 套（本任务加跑，因改动可放宽泛型应用判等）：`test_lsp` 9 tests ALL PASS · `test_directory_build` · `test_pointer_safety` · `test_region_cfg` 22/22 · `test_dex_arith` 11/11 · `test_dex_type` 5/5 · `test_native_float/memory/strings` · `test_interp_float` · `test_apx_tag` · `mw_task1..6` · `bootstrap/test_apx_tag` 5/5 · `bootstrap/test_dex_arith` 14/14 · `bootstrap/test_dex_type` 3/3 · `bootstrap/test_modules`。35/35 全绿，0 失败。

Concerns（交下游/评审）
- C-1（语义面，须 Task 3 量化）：去重把 `TYP_GENERIC_APPLY` 的基型行号比较从「同名字不同出现点 因此 不等」放宽为「同名 因此 继续比实参」。这是 F1 的目的面，但属真实语义变化；现有语料 ELF/`.ccr` 均未显形（`ptr_arith` 无泛型应用；`generics_test` `.ccr` 未变 = 该文件未被触发）。建议 Task 3 对拍复跑专列「同名字泛型应用跨站点」探针，确认差异归零且无新增放宽误判。
- C-2（覆盖强度）：`f1.row_count` 断的是「行数 = 1」，不能直接断言「8 个生产分配点全部走侧表」，生产路径的覆盖靠 ELF + `.ccr` + 35 套件（弱于单元断言）。若要硬断言，需在 8 点各加计数器（超出本任务范围）。
- C-3（防御分支口径，评审已裁决 + 已收口）：①`named_dedup_reset()` 可达且必需（初版「不可达」标注错误 到 评审 C-3① 纠错，注释已改写，见 第2）②负键分支「任意 ti」理由已按评审 C-3② 改写（bump 不置零 到 未初始化 value 槽，不是特指 `ti=0`）③`named_dedup_probe` 注释 `ret`到`slot` 对齐（评审 Minor③）。仍标「不可达」的仅回写重探命中分支（`alloc_type` 不回入本函数，已在码内写明反例写法后果）。
- C-4（容量面）：`NAMED_DEDUP_INIT_CAP=1024`，装填 0.5 触发翻倍；自测已覆盖 1024到2048到4096 两次重建。真实自指语料的命名型总数与表终容量未实测（Task 3 面）。
- C-5（用例数偏离计划）：见 第5 末，77 而非 76，新增 1 条扩容覆盖，评审已确认合规、计划已按 77 回填。

---

## 8. 评审收口（P2a Task 1 评审 = spec 通过 + Approved，0C/0I/3M）

收口提交：jj change `rxzpsuwqszvwksmpkvyumnruxkkzomwp`（短 `rxzpsuwq`）/ commit `8c9d773fa8363973344f14dbea32c67ad1890764`（短 `8c9d773f`），路径限定 1 文件 `src/compiler/checker.cr`，纯注释 `+12 / -5`。

| finding | 处置 |
|---|---|
| C-3①（最重要，评审纠错）`named_dedup_reset` 的「不可达防御」标注是错的 | 已改写为「可达且必需（LSP 每请求 reset 场景）」并写明机制链（`reset_frontend_state` 到 `check_all` 到 `init_types`；长驻进程 `str_intern` 下标稳定 因此 删之即不报错地错型）。实现者复核确认评审正确：`reset_frontend_state` 确清 `g_type_count` 且零触及字符串表；初版误判源于只 grep 了 `init_types()` 调用点、漏了 LSP 长驻进程的 `reset_frontend_state()` 路径 |
| C-3② 负键分支理由不严 | 已改为「bump 分配不置零 到 返回未初始化 value 槽的任意 ti（非特指 `ti=0 = TI_INT`）」 |
| Minor③ `named_dedup_probe` 注释 `ret` 与实参名 `slot` 不一致 | 已对齐为「槽位变量 `slot` + break + 尾 return」 |

复验（纯注释改动，按评审给定路径只跑最小面）：`build_selfhost_native.py` 到 BUILD SUCCESS（三阶段 GUARD 全 `error[ = 0, undefined = 0`）；`selftest-types` 到 77/77。其余判据（ELF/`.ccr`/回归 35 套）不重跑，注释不入码（词法器剥离），且评审已独立复现全部判据。
评审确认项：76到77 用例数偏离合规；8 个生产分配点全改；侧表三件套（装填守卫/重建重放/回写重探）齐。
