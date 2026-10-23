# R2 P4 Task 1 报告：`.ccr` 段机制，TYPE=7 和 IFACE=8，版本从 7 到 8，加段四面（两段空壳）

日期：2026-09-12。基线：`7c822003`（P4 Task 0 收官，工作副本起点，`selftest-types` 333/333，ELF canary IDENTICAL）。
任务：计划 `docs/superpowers/plans/2026-09-12-r2-p4-carrier.md` 的 Task 1（Step 1 红态，Step 2/3 加段四面，Step 4 测试面重定，Step 5 spec 同步，Step 6 判据，Step 7 提交）。按 D9（TYPE=7/IFACE=8，预留顺移 9/10）和 D10（版本 7 到 8）实施。
口径：所有命令使用 `nice -n 19`；cwd 为仓库根；一次构建一次编译串行执行；任何 `.ccr` 或缓存态比较前先 `clean-cache`；数字是本轮实跑，例外逐条标注。

---

## 0. 交付摘要

| 项 | 结果 |
|---|---|
| 段表 | 8 段规范序（tag 1 到 8 依次为 STR、SYM、NOD、ENT、REG、EDG、TYPE(7)、IFACE(8)）；header 为 `version = 8` / `seg_count = 8` / `reserved = 0`；表长为 `16 + 8×12 = 112` |
| 两段空壳 | 段体为计数 u32 等于 0，恰好 4B；loader 侧要求必备（D11）、计数等于 0、段体恰好一个 u32，非空则拒绝（三态纪律） |
| 加段成本 | 规范序检查 `tg == ri+1` 和段体连续检查 `soff == cursor` 形状不变（D9 的直接收益）。检查界从 6 改为 `CCR_SEG_COUNT`（1 处），加标量族 `seg_off7/8`、`seg_end7/8`、`have7/8`，段表增加 2 行，段体增加 8B |
| 旧文件拒收 | 前置二进制（`c05df756…`）产生的 v7 六段 .ccr（`ptr_arith` 88943B `54e3856b…`、`generics_test` 130974B `97be2f9e…`、small 86121B）由新 corearch 处理，结果为 rc=1 和“error: invalid .ccr file”，无产物（第 3 节） |
| `.ccr` 变更面 | 纯加法：前六段体逐字节相同（实测 3 档），增加 32B（等于 2×12 段表加 2×4 空壳）；冷缓存新记录值见第 5 节 |
| ELF canary | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475` IDENTICAL（clean-cache，发射面零泄漏） |
| 回归 | 五个 CI job：4 个 rc=0，`check` 为 rc=1（既有划界：恰好 2 条 TF01 `lits_copy`/`ty_memo_slot_no_grow`，行号 10162/10385 与 T0 相同）；全枚举 46/46 selfhost 加 7/7 bootstrap；自举链 `cmp` IDENTICAL 加 N06=0 加冒烟 42；影子全计数 0 |
| 提交 | 见第 8 节（路径限定 6 个文件） |

---

## 1. Step 1：用例（红）

新建 `tests/selfhost/test_ccr_types.py`，包含机制面 9 例（计划下限为至少 6）：

| # | 用例 | 覆盖 |
|---|---|---|
| ① | `test_p4t1_layout_eight_segments` | 8 段规范序、offset 连续、末段尾等于 fsize、version 8、seg_count 8、前六段非空且两空壳恰好 4B |
| ② | `test_p4t1_shell_bodies_zero_count` | 两空壳 count 等于 0，段体恰好一个 u32，没有尾随垃圾 |
| ③ | `test_p4t1_loader_rejects_valid_v7_file` | 结构性合法的 6 段 v7 文件（段表 offset 重算，前六段体原样）被拒绝；非平凡性控制是独立 v7 校验器先证明“合法”，段体逐字节来自 v8 文件，防止“畸形字节副产品”造成假拒 |
| ④ | `test_p4t1_loader_rejects_missing_type_iface` | `seg_cnt := 6`，末段 size 扩到 EOF（前检查全过），仍被拒绝。拒绝来自必备集 D11，不是其他检查 |
| ⑤ | `test_p4t1_loader_rejects_tag_mutations` | tag(7) 改为 9（出界）、改为 6（重复）、tag(8) 改为 7（规范序失配），逐个拒绝 |
| ⑥ | `test_p4t1_loader_rejects_nonempty_shell` | TYPE/IFACE 的 count 改为 1，拒绝（空壳期不接受外部半成品） |
| ⑦ | `test_p4t1_loader_rejects_truncated_body` | 文件减 1B，越界拒绝 |
| ⑧ | `test_p4t1_end_to_end_shells` | `corec build --static` 加 `corec ccr` 到 `corearch --elf` 双路径 rc=0，产物运行 rc=42 |
| ⑨ | `test_p4t1_cold_warm_shell_stability` | 冷热两态下 TYPE/IFACE 加 SYM/NOD/ENT/REG/EDG 逐字节相同（命中证据是暖运行不重写缓存 mtime） |

红态证据（改动前的二进制）：2/9 passed。7 例 FAIL（`expected version 8, got 7` / `corearch accepted mutated file: rc=0`），2 例 PASS（截断拒绝和端到端是不依赖新格式的回归守卫，改动前后都必须通过）。

## 2. Step 2/3：实现（加段四面）

### 2.1 `src/compiler/ccr_io.cr`（唯一源码改动）

| 面 | 改动 |
|---|---|
| 常量 | `CCR_VERSION 7` 改为 8，`CCR_SEG_COUNT 6` 改为 8，新增 `CCR_SEG_TYPE = 7` / `CCR_SEG_IFACE = 8` |
| 尺寸 | 新增 `ccr_type_seg_size()` / `ccr_iface_seg_size()`（各 `return 4`；注释钉住“Task 2/3 起扩为 4 加段体缓冲长度”），`calc_ccr_size` 增加两段 |
| 写侧 | 增加 `s7/s8` 和 `o7/o8`；段表从 6 行改为 8 行（沿用规范序字面量风格）；段体末尾两处 `count = 0`（8B） |
| 读侧 | 标量族增加 `seg_off7/8`、`seg_end7/8`、`have7/8`；检查界 `tg > 6` 改为 `tg > CCR_SEG_COUNT`；段 tag 分派增加两行；必备集增加 `have7/have8`（D11，独立错误路径）；段体末尾空壳校验（`count == 0` 且 `pos == seg_end`，两段各 4 行） |
| 注释 | 文件头的“字节真相”全部同步（v8、8 段、TYPE(7)/IFACE(8) 定义、空壳纪律、必备性）；load 段头注释、解析序、状态复位面注同步（“T1 无新内存表”） |

偏差登记（1 处，显式）：计划 Interfaces 块列了 `g_ccr_type_seg/g_ccr_type_seg_len` 两个缓冲和 `4 + 段体缓冲长度` 的尺寸形。本任务未引入缓冲全局，因为 T1 空壳没有内容可搬，预置就是死代码。缓冲随 D18 的内容构造者（T2 的 `ccr_types.cr`）实施，届时尺寸函数和 save 搬运同步扩形。代码内已留指路注释（`ccr_type_seg_size` 注释加段体写点注释）。

### 2.2 空壳期纪律（新增拒绝路径，逐条）

1. `have7 == 0 || have8 == 0` 时拒绝（段缺席不等于空表，ENT 的“缺段等于空”先例不外推）。
2. TYPE 段体不是 4B，或者 count 不等于 0，拒绝；IFACE 同理。
3. 版本不等于 8，拒绝（包含全部 v7 文件）。

三条都是新增 rc≠0 面，方向是“旧接受变为新拒绝”。因为内容面尚未实施，没有可奏效的旧合法输入被误拒（旧 v7 文件本来就是 D10 要拒的对象）。按 Global Constraints“新硬错误先 report-only”的适用边界，这三道检查不引入新检查语义（不判内容），而是格式完备性和版本检查的机械延伸。全语料实测零命中（第 6 节：72 档 check 加 21 档 suite build/run 加 46 个 selfhost 套件全部通过，没有一条落入新拒绝路径）。

## 3. Step 6-③：旧文件拒收证据（D10 核心）

前置二进制（P4 T0 收官物，`/tmp/p4t1/bin_pre/corec` 等于 `c05df756…`，与 T0 报告 sha 相同）在 `clean-cache` 后产生：

```
ptr_arith_v7.ccr     88943B 54e3856b383301be5daecaf61f75ce120e56ef4d1569c3008009fc368b750df9   ← 与 P3b 记录值逐字节同
generics_test_v7.ccr 130974B 97be2f9e7431fde54de99e29394903a431aeafa591159c900e0175dfa064c8b1  ← 同上
small_v7.ccr          86121B c9591f9985b3551d5bf09f7635eb4643541e9d9259b615996eaec0b5873d57b8
```

旧 corearch 载入 `ptr_arith_v7.ccr` 得到 rc=0（有效文件自证）。新 corearch（本任务产物）：

| 输入 | rc | 输出 | 产物 |
|---|---|---|---|
| `ptr_arith_v7.ccr` | 1 | `error: invalid .ccr file` | 无（`ls` 确认文件不存在） |
| `small_v7.ccr` | 1 | 同上 | 无 |

加法性反证（同源三档，冷缓存）：v8 文件的前六段体与 v7 文件逐字节相同，header 从 `(7,6,88943)` 变为 `(8,8,88975)`，增加 32B（段表 2×12 加空壳 2×4；`generics_test` 从 130974 变为 131006，同样增加 32B）。因此“旧文件被拒”不是内容不可读，而是版本检查整类拒收。D10 的设计意图达成，v8 是 v7 的纯加法扩展。

## 4. Step 4：测试面重定（改动面逐例登记）

| 文件 | 改动 | 理由 |
|---|---|---|
| `tests/selfhost/test_ccr_v7.py` | `SEG_TAGS` 改为 `[1..8]`；`HEADER_TABLE` 改为 `16+8*12 = 112`；`V7 = 7` 改为 8（常量名保留，加注释“v7 = 段表架构代号”）；`seg_count == 6` 改为 8；坏版本三元组 `(6,5,8)` 改为 `(7,6,5)`（8 已合法；7 是旧 v7 文件拒收的正面用例）；`test_v7_layout_and_walk`/`roundtrip` 的 docstring 同步；cache-hit 恢复用例段集 `(2..6)` 改为 `(2..8)`；模块 docstring 字节真相表同步 | 结构性断言重定（计划 Step 4 逐条） |
| `tests/selfhost/test_region_cfg.py` | 自带 `ccr_walk` 段集 `(1..6)` 改为 `(1..8)`，加 `assert ver == 7` 改为 8（2 处），docstring 同步 | 计划未列的第 5 面（见第 7 节第 ① 条） |
| `tests/selfhost/test_ccr_types.py` | 新建 9 例加 `__main__` runner | 机制面守门 |
| `src/ci/run.sh` | `selfhost-tests` 挂 `test_ccr_types.py` | CI 挂钩 |

其余既有用例零改动（实跑确认）：`test_ccr_v7.py` 27/27（ENT/REG/EDG 走查、GC-3/GC-4、负分支等经 `segs[tag]` 寻址，加段透明）；`test_region_cfg.py` 22/22。

## 5. Step 6-④⑤：`.ccr` 记录值（冷缓存实测，P3b 旧值作废）

| 语料 | 旧（v7，作废） | 新（v8，本任务产物） | 变化 |
|---|---|---|---|
| `tests/suite/ptr_arith.cr` | 88943B `54e3856b383301be…` | 88975B `15645387ea174df87b29735bb46ea776b5175439fccc523b8951296767e5ae10` | 增加 32B |
| `tests/suite/generics_test.cr` | 130974B `97be2f9e7431fde5…` | 131006B `f2e566b68165584697b120614d3b08e472ba4c329aae63065bc9412e30ba0ff8` | 增加 32B |

冷热两态（`ptr_arith`）：SYM/NOD/ENT/REG/EDG/TYPE/IFACE 七段逐字节相同；只有 STR 段不同（1555 变为 1423B，暖态更小），这是既有已登记面（TODO #5 末条：缓存命中路径不复现冷路径的字符串驻留，不是本任务引入，本任务不修）。因此本任务新增段面冷热相同，全局冷热相同仍受既有面阻塞，这里如实登记。
判据（TODO #26 口径）：`test_ccr_v7.py` 27/27 加 `test_ccr_types.py` 9/9 结构性断言全部通过，加语义零变化（第 6 节），加自举稳定（第 6 节）。不以“与旧版逐字节相同”为准，旧值已按计划作废并留档。

## 6. Step 6 判据（逐条为命令和结果）

| # | 判据 | 命令 | 结果 |
|---|---|---|---|
| 1 | 三二进制构建 | `nice -n 19 python3 build_selfhost_native.py` | rc=0；`[GUARD] corec: manifest OK (44 files)` / corearch (30) / x86_64-linux target (3) / corelsp (31)；三条 `build log clean (error[ = 0, undefined = 0)` |
| 2 | project-mode 守卫 | `nice -n 19 python3 tests/selfhost/test_backend_bootstrap.py` | rc=0，`error[` 命中 0 |
| 3 | 类型引擎自测 | `nice -n 19 ./build/corec selftest-types` | 333/333（用例数零增减，本任务不触判定路径） |
| 4 | ELF canary | `clean-cache`，然后 `build tests/suite/ptr_arith.cr -o /tmp/pa_p4t1 --static`，再 sha256 | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475` IDENTICAL |
| 5 | 旧文件拒收 | 前置二进制产 v7 三档，新 corearch 载入 | 全部 rc=1 加“error: invalid .ccr file”加无产物（第 3 节） |
| 6 | 结构性断言 | `test_ccr_v7.py` / `test_ccr_types.py` / `test_region_cfg.py` | 27/27、9/9、22/22 |
| 7 | 编译、纯度、类型套件 | `test_compile` / `test_purity` / `test_type_engine` 等 | 全部通过（详见第 7 节套件表） |
| 8 | 自举链 | `full-bootstrap` job，然后 `cmp /tmp/corec2 /tmp/corec3` | IDENTICAL（双 2550414B `db2b63dd…`）加 N06=0（构建日志未定义符号标记为 0）加冒烟 `run 'fn main()->int{return 42;}'` 得到 42（corec 和 corec2 双通道）加 `corec3 --help` rc=1 |
| 9 | 五个 CI job | `CI_JOB_NAME=<j> bash src/ci/run.sh`，5 次 | `check` rc=1（既有划界：恰好 2 条 TF01，行 10162/10385 为 `lits_copy`/`ty_memo_slot_no_grow`，与 T0 同对同行号）；`bootstrap-tests` 0（29/29 加 4/4 加 3/3）；`selfhost-tests` 0（含新挂 `test_ccr_types` 9/9）；`suite` 0（21 档 build 和 run 全过）；`full-bootstrap` 0 |
| 10 | 全枚举 | 逐档 rc（`/tmp/p4t1/enumerate.sh`） | 46/46 selfhost 加 7/7 bootstrap，全部 rc=0 |
| 11 | 同源对拍（check 面） | `p3t0_run.sh check` 分别用前置 `c05df756…` 和新二进制跑 72 档，然后 `diff` 输出 | 差异为空；rc 分布两侧相同（33 档 0、39 档 1） |
| 12 | 影子对拍 | `p3t0_run.sh shadow` 同上 | `decisions=30736 agree=30736`（两侧同值）；全部计数为 0；`logs` 的 `diff -r` 为空，`dumps` 的 `diff -r` 为空；站点覆盖两侧同报：`assign-node=23246`、`fn-body-ret=5476`、`if-branch=1980`、`struct-field-type=28`、`array-elem-type=4`、`generic-apply-base=2`（站点 1/2/4/5/6 零命中、8 为 0、9 为 28、10 为 4；总和等于 30736，等于 decisions）。继承声明：影子通道对实现方式面零覆盖，这里只作“判定面零变化”的必要条件 |

CI-wired 套件逐档（selfhost-tests job 内）：`test_compile` PASS、`test_type_engine` PASS、`test_iface_ops` 76/76、`test_purity` PASS、`test_ccr_v7` 27/27、`test_ccr_types` 9/9（新挂）、`test_impl` 7/7、`test_borrow` 7/7、`test_pointer_safety` PASS、`test_params_limit` 5/5、`test_tuple_slots` 14/14、`test_agg_slots` 13/13、`test_agg_checks` 20/20、`test_nested_fn` 17/17、`test_interp_parity` 23/23、`test_cache_identity` 5/5、`test_match_exhaust` 16/16、`test_optional` 12/12、`test_generic_constr` 15/15、`test_iface_satisfies` 17/17、`test_xcut_iface` 12/12、`test_impl_iface` 20/20。

`.cir` 缓存面：本任务不触 DF 记录布局和语义，`CIR_CACHE_VER` 保持 17（bump 归 Task 4）。`test_cache_identity` 5/5 加 cache-hit 恢复用例（在 `test_ccr_v7` 内）通过，缓存面零扰动。

阶段二构建确定性（登记）：注释微调后重建，`build/corec` sha `254f53ac…`、`build/corearch` sha `9248e666…` 与微调前逐字节相同（注释不影响代码生成）。因此判据 10/11/12 的语料结果对最终二进制有效。

## 7. 登记面和后续任务须知

① 计划外第 5 面：`tests/selfhost/test_region_cfg.py`。它自带 `.ccr` 解析器（`ccr_walk`，段集硬编码 `(1..6)`，加 `assert ver == 7`）。本任务被全枚举捕获（首轮 21/22，唯一 FAIL 为 `expected .ccr version 7, got 8`），与 P4 T0 的 `test_compile.py` 清单是同类教训。T2/T3/T4 修改 `.ccr` 布局或版本时，务必做全枚举（tests/suite 21 档加 46 个 selfhost 加 7 个 bootstrap），不要只 grep。

② T2/T3 必须同步放宽本任务的空壳检查：loader 现在对 TYPE/IFACE 的“count 不等于 0 或段体不是 4B”拒绝。T2/T3 内容实施时，必须同批修改 save（写实际内容）和 load（按 D12/D14 解析加重建），否则自产物会被自己拒绝。这是响亮失败，不是不报错地，设计如此，但会阻塞 T2/T3 的首次自测。

③ 两段必备（D11）的既有先例边界：ENT 仍然“缺段等于空表”（本任务未动）；TYPE/IFACE 走必备。后续如果有人以“ENT 可以缺”为由质疑 D11，口径是第 4 节规则 6（可选段等于两种 `.ccr` 在野，等于不报错地降级面）。

④ 计划 Interfaces 偏差（第 2.1 节）：缓冲两件套推迟到 T2（内容构造者）。如果 T2 实施者按计划原文找 `g_ccr_type_seg`，位置应当新建于 `globals.cr`（双 concat 共享面）加 `ccr_types.cr`（D18）。

⑤ 陈旧工具（不是本任务引入，登记不修）：`tools/module_to_ccr.py` 仍写 version=1 的远古 .ccr（固定计数头，没有段表），仓库内零调用者（v5 起即失效），本任务不触。另外 `pkg/`（未跟踪的安装树）内有一份陈旧 `ccr_io.cr` 副本，不是构建输入。

⑥ 文档面未动的两处（归 T7）：`CLAUDE.md` 的 Key Conventions 中 `.ccr` 行仍写“v6 = 段表架构加 ENT（v6-only）”，在 T1 之前就已经陈旧；`TODO.md` 的 P4 实施条目按计划归 T7（本任务只按 Global Constraints 在本报告作废旧记录值）。文件名和测试名按 D10 保留“v7”字样（等于段表架构代号），新读者须看 spec 第 1 节 v8 列或本报告。

⑦ 测试面 e2e 语料：`test_ccr_types` 第 3 节的“合法 v7 重建”用例依赖“v8 前六段体等于 v7 前六段体”这一加法性事实（本轮实测成立，也是 D9/D10 的设计前提）。如果将来某任务非加法地修改前六段布局，该用例的重建前提须重审。届时 v7 文件已无在野消费者，可以直接删除该例。

## 8. 提交（路径限定）

```
97febdbf（change unynrwnp）feat: R2 P4 Task 1，`.ccr` 段机制：TYPE(7)/IFACE(8) 加段 + 版本 7到8
         + 加段四面（两段空壳落盘）
6 文件：src/compiler/ccr_io.cr · docs/superpowers/specs/2026-09-09-lattice-ir-v7-format.md ·
        tests/selfhost/test_ccr_types.py(A) · tests/selfhost/test_ccr_v7.py ·
        tests/selfhost/test_region_cfg.py · src/ci/run.sh
```

`jj diff -r 97febdbf --summary` 核过，恰好是上列 6 个路径（M 5 个加 A 1 个）。提交后工作副本干净，只剩空提交 `2eed644d`。
报告文件在 `docs/archive/sdd/`，不入库，沿用 T0 先例。

## 9. 证据路径（本机）

- 前置基线：`/tmp/p4t1/bin_pre/`（corec `c05df756…` / corearch `599ee275…`），前置 v7 产物 `/tmp/p4t1/pre/*.ccr`
- 拒收证据：`/tmp/p4t1/rej1.log`（ptr_arith v7 得到 rc=1）、`/tmp/p4t1/rej2.log`（small v7 得到 rc=1）
- 加法性对比：`/tmp/p4t1/{ptr_arith,generics_test,small}_v8.ccr` 对比 `/tmp/p4t1/pre/*_v7.ccr`（逐段脚本内联）
- 构建：`/tmp/p4t1/build1.log`（红后首建）、`/tmp/p4t1/build2.log`（注释微调后，sha 复核）
- 判据：`/tmp/pa_p4t1`（canary）、`/tmp/p4t1/final/*.ccr`（冷热实测）、`/tmp/p4t1/tbb.log`、`/tmp/p4t1/canary.log`
- CI：`/tmp/p4t1/ci_{check,bootstrap-tests,selfhost-tests,suite,full-bootstrap}.log`
- 枚举：`/tmp/p4t1/enumerate.sh`、`/tmp/p4t1/enum_all.log`、逐档 `/tmp/p4t1/enum/*.log|*.tail`
- 语料和影子：`/tmp/p4t1/corpus_{old,new}.out`（加 `corpus.diff` 为空）、`/tmp/p4t1/shadow_{old,new}.out`、`shadow_logs.diff`/`shadow_dumps.diff` 为空
- 自举链：`/tmp/corec2` / `/tmp/corec3`（cmp IDENTICAL `db2b63dd…`）
