# 可选 dex（`dex?`）整族，阶段报告（阶段 5；2026-09-17）

> 条目：`TODO #2026-09-16-29`（原 #91）「可选 dex（`dex?`）整族：形式转换 × 可选表示的交集面全未覆盖」。
> 计划：`docs/superpowers/plans/2026-09-17-opt-dex.md`（含 4 节 bis 十门决定、7 节 bis T0 记录、7 节 ter G7 实现方式清单、7 节 quater 分步实施记录）。
> 工作区/书签：`core-optdex-ws` / `feature/opt-dex`（基点 develop `dbadb8d649ba`）。
> 性质：预存无提示错值族（修复前即存在；非本次引入），本次修复 + 建检查集合。
>
> 合入记录（2026-09-17）：PR #95 到 develop，squash 合并 = `dc2c72d2`。合并方式 = 管理员合并
> （`gh pr merge 95 --squash --admin`）。为何走 admin（如实归因，不是「为了图快」）：
> 仓库规则集要求审阶段，而本仓为单维护者场景，因此1 `gh pr review --approve` 对本人 PR 返回
> `Can not approve your own pull request`（GitHub 禁自审）；2 仓库未启用 auto-merge。
> 两条常规通道都实测试过并失败，因此该门对单人维护者结构性不可达，由维护者授权走 admin。
> 建议：为 develop 增加第二审阶段人，或放宽 develop 的审阶段要求
> （否则该门形同不存在，它挡不住任何东西，只会把合并推向 `--admin`）。
> 跟进 PR（CI 覆盖域 + 合入记录 + 操作教训）：`feature/opt-dex-followup`（PR #96，已合入 = `c1546f9b`）；
> `feature/opt-dex-followup2`（7 节 ter 补 6 处实现方式 + 说明 + 教训 1 两实例并写，本文档当前增量）。

---

## 1. 结论速览

| 检查 | 读数 | 状态 |
|---|---|---|
| 主要检查 = 四态对照 | `{fs_bare_bits 7, fs_bare_scaled 7, fs_boxed_bits 7, fs_boxed_scaled 7}`，因此四格互等 = 7（含绑定格） | 通过 |
| 禁第三态（G10 规则 2） | bits 源 interp = 255（F2I 能力边界 = 转换在场正面证据）· scaled 源 interp = 绑定值 | 通过 |
| 家族面（12 项失败降到 0） | 逐条归因见 2 节 | 通过 |
| 本次套件 | 30/30 全部通过（四态 + 家族 + G2 判别 ×2 + M1 行为固定 ×2 + 自校验 + 拒绝面） | 通过 |
| suite 语料 `tests/suite/opt_dex_test.cr` | build rc=0 · 运行 rc=0（改前 = 1） | 通过 |
| canary ELF | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475` 28822B IDENTICAL | 通过 |
| `.ccr` 四条 | `pa_ccr 680a6f98…` 96015 · `pa_static_ccr 76f36e6a…` 96158 · `gt_ccr d92a2727…` 142765 · `gt_static_ccr a1f7b99c…` 142908，全 IDENTICAL | 通过 |
| 五 CI job | check / bootstrap-tests / selfhost-tests / suite / full-bootstrap = 全 rc=0 | 通过 |
| 判定面回归检查 | 检查组1 本次隔离零差异（75 档）· 探针 29 本次隔离零差异 · 暖缓存检查组两侧 FAIL=0（见 5 节 bis） | 通过 |
| 自举链 | `corec2 == corec3` IDENTICAL（`c0f1cbf528c066db860428830227a1e727daf2cedfac6b5590c0d637f13d8a5a`）· `[GUARD] build log clean（error[ = 0）` ×3（corec/corearch/corelsp）· 快速验证 42 | 通过 |
| 类型引擎自测 / 自源 check | `selftest-types` 415/415 · `check src/compiler` rc=0 | 通过 |
| apx 阶段套件（跨阶段核对） | 23 例 + 自校验 + 双形对照全部通过（标记值更新基准值后无变为失败 = 无「真发现」） | 通过 |
| J3 检查标准换代（跨阶段决定） | J3 PASS（旧号 100 / `—` 1 / 新 id 103 / 标题 103）+ M-a/M-b/M-c 三条突变全部失败 | 通过 |

---

## 2. 家族问题从 12 项失败降到 0：逐条归因（改前与改后双列读数）

> 读数 = ELF rc / interp rc（interp 255 = `IR_I2F/IR_F2I` 能力边界拒收，是期望值，见 G10 规则 2）。
> 归属 = 该条由哪一步修好：R2 装箱序（5 处）· R1 写点门 + 槽型按声明 · R3 声明面/ABI · G2 读点定型。

| # | 探针 | 改前 | 改后 | 归属 |
|---|---|---|---|---|
| 1 | `fs_bare_bits`（裸 + apx） | 15 / 15 | 7 / 255 | R1（LET 槽型按声明 + 初值归一） |
| 2 | `fs_bare_scaled` | 7 / 7 | 7 / 7 | —（绑定格，起点即通过） |
| 3 | `fs_boxed_bits` | 7 / 255 | 7 / 255 | —（`Some(...)` 由 apx 阶段汇聚点覆盖，断言） |
| 4 | `fs_boxed_scaled` | 7 / 7 | 7 / 7 | —（绑定格） |
| 5 | `assign_bits`（赋值写点） | 15 / 15 | 7 / 255 | R1（槽型改后，`dex_store_adjust` 自动生效） |
| 6 | `ptr_write_bits`（指针写 · INV-2） | 15 / 15 | 7 / 255 | R2（序修正） |
| 7 | `addr_read_bits`（取址槽 · INV-1 交点） | 15 / 15 | 7 / 255 | R1（槽型按声明，因此装箱载荷 = scaled） |
| 8 | `ret_bits`（`-> dex?` 返回） | 15 / 15 | 7 / 255 | R3（W5 返回门 + `g_cur_ret_dex_opt`） |
| 9 | `param_bits`（`dex?` 来自 apx 实参） | 0 / 15（双路径分歧） | 7 / 255 | R3（W3 形参槽型 + W4 实参环） |
| 10 | `param_branch_bits`（判别形） | 101 / 172（双路径分歧） | 100 / 255 | R3（同上；分歧消灭） |
| 11 | `field_lit_bits`（结构体字面量字段） | 15 / 15 | 7 / 255 | R2（序修正） |
| 12 | `global_bits`（全局槽） | 15 / 15 | 7 / 255 | R1（`reg_one_global` 的 `dex?` 分支） |
| 13 | `enum_payload_opt_bits`（用户枚举载荷） | 15 / 15 | 7 / 255 | R2（序修正） |
| 14 | `mw_tag_coexist_bits`（M1 tag 对行为固定） | 1 / 1（同判 ≠ 正确） | 0 / 255 | R3（其 dex 侧走形参面） |
| 15 | `field_assign_bits` · `try_unpack_bits` · `try_to_dex_bits` · `dexopt_apx_tag` · `param_scaled` · `param_branch_scaled` · `ret_scaled` · `param_some_bits` · `nonopt_direct_bits` · `int_opt_{lit,var,some,none}` | 全部通过 | 全部通过 | —（非回归断言，改法未改坏） |
| 16 | `g2_payload_dex_arith_{scaled,bits}`（G2 判别检查，本次新增） | 193 / 193（= 7000001 mod 256，双倍缩放） | 8 / 255 | G2（读点定型） |

总计：R2 修 3 · R1 修 4 · R3 修 4 · G2 修 1（判别面），得到 12 失败清零。

归因要点（维护者点名要进报告）：
- 形式决定权从「值型」搬回「声明型」是主修（R1 一行改定）；R2 的序修是 3 条路径的必要条件（指针写/结构体字面量字段/枚举载荷）；
- R3 的 W4 是全场风险最高处（ABI 寄存器类 XMM 到 GP）：修前 `dex?` 形参槽型 = `TI_INT`（`unpack_type(EXPR_OPTIONAL)` 返 0）而实参按 `TI_DEX` 分类走 XMM，因此按 XMM 传、按 GP 读 = 垃圾值 + 双路径分歧（#9/#10 两行）；
- G2 判别力自校验：`?` 解包路径无判别力（其 dest 型 = `irv_type(inner)` = 槽型，本来自洽），因此 G2 检查必须走 match 载荷绑定读点（否则做出来的是空检查）。该注已写入套件。

---

## 3. 四态对照（主要检查）与分步收敛

| 阶段 | 矩阵读数 | 结论 |
|---|---|---|
| 改前（起点树 `dbadb8d649ba`） | `{15, 7, 7, 7}` | 互等失败（「裸+bits」离群） |
| R2 后 | `{15, 7, 7, 7}` | 未收敛，因此 R2 单独不够 |
| R1 后 | `{7, 7, 7, 7}` | 收敛（四格互等 = 7，含绑定格） |

，因此归因：「R2 单独不收敛；R1 一落即收敛」，形式决定权从值型搬回声明型是主修，R2 的序修是那 3 条路径的必要条件。

---

## 4. 检查集合（本次新增/改动）

| 实现方式 | 内容 | 检查形态 |
|---|---|---|
| `tests/selfhost/test_opt_dex.py`（新档，挂 `selfhost-tests`） | 四态对照 + 家族 12 条 + 断言 13 条 + G2 判别 ×2 + M1 行为固定 ×2 + 非 dex 对照 ×4 + 编译期拒绝面 | 四态对照（关系式）+ 禁第三态 + 不许单条检查通过（G10 三条规则全部写进断言） |
| `tests/suite/opt_dex_test.cr`（新档，suite 自动枚举） | 14 面正例 + 返回码 1..14 定位 | 常规检查（改前 rc=1 到改后 rc=0） |
| `tests/selfhost/test_apx_conversion.py`（改） | 标记值 `SENTINEL_optional_dex_pinch` 15，得到 `relocked_optional_dex_pinch` 7 | 三件套：显式归因 + 同阶段更新基准值 + 旧值留痕；`test_sentinel_annotation_present` 改两态约定（无 15 行 = 退役断言，因此抄回 15 时断言 + 读数两项失败） |
| M1 tag 对行为检查（新） | 同函数共置「走 M1 tag 编码的多字 int 链」与 `dex?` 值（形参 + 局部），断言两侧往返一致（int 侧精确 `4000000000`、dex 侧绑定 7） | 行为往返（不是「不再编码」）；改前 `1/1` 到改后 `0/255`；精确形对照 `0/0` |
| G2 判别检查（新） | match 载荷 + dex 算术（`v + 1.0`） | 改前 193 到改后 8（判别力自校验见 2 节要点） |
| `tests/harness/test_todo_id_migration.py`（改，J3 约定） | 见 7 节 | 三条突变自校验（M-a/M-b/M-c 全部失败） |

探针自纠（如实登记）：M1 检查初版写 `r := match x { Some(v) => { return … } }`，臂内 `return` 使函数提前返回，读数失效（ELF 7/7 误判通过，属「探针不触发」族）。已改 `?` 解包 + 顺序断言并单独提交（`ed34ba3f`）。检查集合可信度依赖这类自纠的登记。

---

## 5. 零影响（非 `dex?` 程序逐字节不变）

| 面 | 读数 |
|---|---|
| canary ELF | `95084e7b…d475`（28822B）IDENTICAL |
| `.ccr` 四条（出处 `tools/baseline/canary_values.tsv`） | `pa_ccr 680a6f9843747b521213c3bcca1cf8724657943410f182e97ed63dcc11c7cd7a` 96015 · `pa_static_ccr 76f36e6a6b6eb2f18fa5541550d09e5e73bb0e8dfc7df2ebbe3d747c382f329c` 96158 · `gt_ccr d92a2727d0c51aa887d7053305a26bdf85451303e08d268898cf1de76bae2c95` 142765 · `gt_static_ccr a1f7b99c68c7d433834593100a776b74f883de291482f20762fe7399ec5182ea` 142908，全 IDENTICAL |
| `corearch` 逐字节同（正交性证据） | 构建后 `corearch` sha 恒为 `072f2c7ccc243cc2a23fb5a0ad8dd97046bbd38c4f1a0aaafd137b660a1617be`（后端源码未动，因此 dex 规范化不涉及后端）；同轮 `corec` sha 变（源码变） |
| 五 CI job | check 0 · bootstrap-tests 0 · selfhost-tests 0 · suite 0 · full-bootstrap 0 |
| 自举链 + N06 | `corec2 == corec3` IDENTICAL（`c0f1cbf5…`）· `[GUARD] … build log clean（error[ = 0, undefined = 0）` ×3（corec/corearch/corelsp） |
| 快速验证 / 自测 | `corec run 'fn main()->int{return 42;}'` = 42 · `selftest-types` 415/415 · `check src/compiler` rc=0 |

> 注意：CI 覆盖域 ≠ 检查全集（2026-09-17 补记）：`.github/workflows/core-ci.yml` 的 `pr` 作业矩阵只覆盖 3/5 档
> （`check` / `bootstrap-tests` / `selfhost-tests`）；`suite` 与 `full-bootstrap` 属 `full` 作业，其触发面 =
> `merge_group`（免费计划无 merge queue，因此等待）或 `workflow_dispatch`。因此对值语义 / ABI 分类类改动
> （正是本次的性质），「PR CI 通过」天然覆盖不到行为保存档，必须手动派发全量层：
> `gh workflow run .github/workflows/core-ci.yml --ref <branch>`（必须给文件路径，本仓 GitHub 侧注册着
> 仓库里已不存在的同名 workflow，只给名字会歧义）。
> 本次实测：派发 run `35213394732`（`feature/opt-dex`），因此五档全部通过（check · bootstrap-tests ·
> selfhost-tests · suite · full-bootstrap），其中 `full-bootstrap` 日志含 `-> /tmp/corec2` +
> 作业 success（`cmp corec2 corec3` 成功无提示），因此自举链恒等在 CI 侧复现。

---

## 5bis 判定面回归检查（检查组1 + 探针 29 + 暖缓存检查组；本次隔离约定）

> 约定说明（为何要「本次隔离」）：固定基线 = pinned `97f4394f`（P6 终态，2026-09-14）。任何 P6 之后的阶段用「固定基线 × 当前源 vs 当前二进制 × 当前源」都会看到自 pin 起各阶段累积的判定面演进，不是本次的。因此本次另加一条隔离检查：改前二进制（`/tmp/optdex-pre/corec`，= 起点树 `dbadb8d649ba` 构建，sha `899e3090ad8d…`）vs 改后二进制（`c0f1cbf5…` 之构建）。

| 检查 | 命令（`cwd=仓库根`） | 读数 | 判定 |
|---|---|---|---|
| 1-A 本次隔离（决定性） | `parity_run.sh /tmp/optdex-pre/corec /tmp/parity_pre` vs `… ./build/corec /tmp/parity_post`；`diff -rq …/logs` | 零差异（75 档 rc + 日志） | 本次判定面零变化 |
| 1-B 固定基线对照（累积面） | `parity_run.sh /tmp/optdex-baseline/corec /tmp/parity_frozen` vs post；`diff -rq` | 11 档不同（`t3` 后端/OS/格式/格核 9 档 + `t4` hotpatch 1 档 + …） | 归因为自 pin 起的累积演进（由 1-A 零差异反证非本次），逐条不入本次清单，按本仓惯例归「固定基线与当前树的历史差」 |
| 探针 29-A 本次隔离（决定性） | `probes_run.sh /tmp/optdex-pre/corec /tmp/probes_pre` vs `… ./build/corec /tmp/probes_post`；冷缓存状态 `diff` | 0 处冷缓存状态日志差异（29 档） | 本次对探针面零变化 |
| 探针 29-B 固定基线对照 | `probes_base` vs `probes_post` | 1 档：`n05_recursive.cr` 多一行 `[5/5] frontend done`（新编译器打印流程行） | 累积/日志面差异（非语义），由 29-A 反证非本次 |
| 暖缓存检查组（广度层） | `warm_leg.sh`（由 runner 内嵌调用） | pre 侧 DONE：75 档 · 真命中档数 39 · FAIL=0；post 侧 DONE：75 档 · 38 · FAIL=0；探针侧 23 / 15 · FAIL=0 | 两侧自判均 FAIL=0；档数差（39与38 · 23与15）= 缓存命中计数（`stats.tsv` 的 hits 列），非语义（warm 日志差异实测 = 临时目录名 + 命中计数） |
| 暖缓存检查组（固定基线侧） | 同上 | 运行中无响应（21:30 elapsed / CPU 0.0% / I/O 冻结），因此按无响应规则终止 | 注意：如实登记：该侧判定行「WARM LEG FAILED」是「被 kill」的产物，不是检测到空缓存/有缓存分歧（不得读成分歧） |

固定基线可复现性复核：`rebuild.sh` 重跑，因此三 sha 与允许清单逐条同（`corec ae01de75…` · `corearch 228f82e9…` · `corelsp 90eb19c6…`）+ 快速验证 42，因此方法可复现是。
runner 计数同步：本次新增 suite 语料，因此 `parity_run.sh` 硬失败报「CORPUS COUNT 75 != 74」，因此已显式更新 `CORPUS_TOTAL=75` + 层清单注（t1 33 改为 34）后重跑通过（该硬失败本身即「语料构成不得无提示不一致」的正面证据）。

---

## 6. G7：`CIR_CACHE_VER` 18 改为 19 + 实现方式更新基准值

为什么 bump（不是保险起见）：本次改变 `dex?` 槽的形式约定，因此旧快照里那些槽是修复前形态（未规范化装箱 bits / 读槽 `TI_INT`），与新语义不等价，因此命中旧条目会把坏 IR 原地重新生效成活产物 rc=0（`TODO #2026-09-10-4`/#8 事故同族）。

实现方式机械枚举（不用手数，手数正是漏点的原因）：

```bash
grep -rn "CIR_CACHE_VER\s*:\s*int\s*=\|VER_EXPECTED = \|ver == 1[89]" src/ tests/ --include="*.cr" --include="*.py"
```
，因此写死点 4 处（`cir_cache.cr:63` 常量 · `test_cache_identity.py:57` `VER_EXPECTED` · `test_ccr_types.py:1865` 与 `:2022` 两处断言）+ 历史注 2 处（`ccr_io.cr:137` · `dyn_arr.cr:112`）= 6 处全部更新基准值；18 代说明保留（旧值留痕）。
> `:2022` 是 T0 清单之外的第三实现方式（T0 手列 4 处时漏了它），由「grep 全量枚举」在推进中抓到并补锁；7 节 ter 已写入新约定。

`.ccr` 不 bump：`CCR_VERSION` 仍 9（交付格式；段布局/字段序未动，内容仅 `dex?` 程序变），因此 `.ccr` 四条预期不变，实测 IDENTICAL 是。

---

## 7. J3 检查标准换代（维护者 2026-09-17 跨阶段决定；阶段 5 实现）

冲突：`#2026-09-17-4`（本次 G3 登记条目）从未有过旧号（编号迁移已生效），因此旧 J3（`max_old = max(table)` + 只数数字行式 + 表新 id 集合 == 标题集合）必然失败且无法用合法数据修（塞数字 = 造历史不存在的号 = 新假引用类，维护者否决「清单槽号」方案）。

新约定（`j3_problems` 纯函数）：1 总体性不放松（表新 id 集合含 `—` 行 == 标题集合）2 旧号列 ∈ {数字, `—`}，数字部分仍须 `#1..#101`（`SEALED_MAX`）全覆盖（`#66` 空号例外）3 越过封存上界的数字，因此失败 4 行数自洽 + 新 id 唯一 + 行式可解析（`malformed`）。
旧约定原文 + 「为何放松」留痕于 `j3_problems` 头注（不会无提示改史）；J1/J2/J4 语义未动。

三条突变自校验（关键件；缺一不可）：

| 突变 | 期望 | 实测 |
|---|---|---|
| M-a 删掉一行已迁移条目（有旧号） | J3 失败（映射缺号 + 总体性） | 失败（`映射缺号（1..101）: [1]`） |
| M-b 把已迁移条目的旧号列改成 `—` | J3 失败（`1..101` 覆盖不完备） | 失败 |
| M-c 给 `—` 行塞封存上界外的旧号（`#102`） | J3 失败（数字列受 `SEALED_MAX` 约束） | 失败（`越过封存上界 #101 的号 [102]`） |

约定入册：`TODO.md` 头部「编号约定」+ `docs/superpowers/plans/2026-09-17-todo-id-migration.md` 「表尾约定」（含合规写法表 + 禁用写法 + 三条突变表），因此后续阶段不再重复撞墙。
最终读数：J1 PASS · J2 PASS · J3 PASS（旧号 100 / `—` 1 / 新 id 103 / 标题 103） · 突变三条全部失败 · J4 PASS，得到 5/5。

---

## 8. 性能注 + 环境状态（测量可归因）

`regalloc.cr:680-681`（`dex?` 槽的 `-O2` 面）
- 改前：槽型 `TI_INT`，因此可进寄存器分配；
- 改后：槽型 `TI_DEX_S`，因此排除寄存器分配 = 全窗口栈驻留（仓注自述「正确但零加速」）。
- 范围：仅 `-O2` 生效、仅 `dex?` 程序；本次不测 O2 性能回归，仅登记状态变化（正确性不受影响）。

环境状态（逐步实测；机器当日处于换页抖动）：

| 时点 | loadavg | 内存（总/已用/可用 MB） |
|---|---|---|
| R1 构建（44.8s） | ~5–13 | 7871 / ~5000 / ~2700 |
| R2 构建（57.6s，冷缓存状态 57.6s，缓存已清） | 14.7 / 16.3 / 17.2（维护者实核） | 7871 / 5437 /，|
| G7 构建（55.5s，bump 后冷缓存状态） | 12.67 / 10.74 / 7.67 | 7871 / 4975 / 2895 |
| T3 五 job（逐 job） | 同上量级 | 同上 |

读数的归因限制（如实声明）：当日磁盘有效吞吐被压到 ~1.8MB/s（swap 5.8GB 已用 · 12 个进程 D 态），墙钟数字不可与他日直接比较；本次检查均为功能性读数（rc/sha/值），不受吞吐影响。

---

## 9. 过程教训（给后续阶段）

1. 定位点/常量类改动：人工清单会漏、手抄会错，因此必须「机械枚举（grep）+ 编辑后 diff 复核」双保险（同一条教训的两个实例，分开写会被读成两件小事，实为一件事：凡「清单/常量」必有不一致，只有机械源可依赖）。
 - 实例 A（清单不一致）：T0 手列 G7 实现方式（5 处）漏了 `test_ccr_types.py:2022`（同文件第二处断言、与 `:1865` 相隔 157 行），因此由实现推进中的 grep 全量枚举抓出并同阶段补锁（代码侧最终 = 6 处全部更新基准值）；但计划 7 节 ter 表当时未同步（代码改了、手抄表没跟上），因此该表在跟进 PR 补齐第 6 行 + 说明。
，因此约定：实现方式清单以 `grep` 输出为准，不以手抄为准，每代应由命令重跑生成（命令原文见 6 节）。
 - 实例 B（常量抄错）：编辑中误截断 `CIR_CACHE_MAGIC`（`-4485090715960753727`，得到 `-5090715960753727`），因此当场发现 + 复原 + `jj diff` 复核确认 magic 逐字节未动（仅注释与 `VER` 变更）。
 - 共同动作：改定位点/常量前后各跑一次机械枚举；编辑后必须 `jj diff` 逐字复核改动面。
 - 这条防的是以后每一组。
2. 「同判 ≠ 正确」：`mw_tag_coexist_bits` 改前 `ELF 1 / interp 1` 是两条检查同错；检查必须写成「期望值 + 禁第三态」（本次 = `0/255`，不翻即上报）。
3. 判别力自校验：G2 那条检查若走 `?` 解包路径，改前改后同值（空检查），因此检查必须自问「什么坏实现能骗过这条断言」。
4. 标记值换代 = 两态约定：不是「改成新值就完」，而是「旧值出现即失败」（本次 = 断言无「期望 15」行）。
5. 无主进程 + 互斥：上一轮死会话遗留的后台构建曾与新构建重叠（本次已如实登记）；维护者随后把互斥规则改为「非空最多等 2 分钟，否则直接开跑并注明并发」，并新增「CPU<2% 且 >3 分钟无进展，因此判已知缓存膨胀（阶段 6 登记的条目），因此杀 + 清缓存 + 重跑」。
6. 检查自身的可伸缩性缺陷（本次实测发现并修复）：`tests/harness/test_todo_id_migration.py` 的 `EX_DIRS` 漏了 `.core/`（编译器增量缓存在仓根生成，本工作区实测 1.4GB / 1657 条），因此 J1/J2 的全仓扫描会逐个读这些二进制快照（检查进程 `rchar` 2.4GB+、CPU 0.7%、打开 fd = `…/cache/cir/src_compiler_main.cr::dirname.cir`），因此检查无响应 14+ 分钟（远超它自述的「毫秒级」定位）。
 - 修复：`EX_DIRS` 补 `.core`（与已排除的 `build/` 同类：编译产物、非仓库文本）。
 - 判定中立的证据（两态对照）：排除前后 J1 = 0 残留 · J2 = 0 悬空 · 标题 103 · J3 PASS 逐项相同；且排除后检查从无响应 14+ 分钟降到 56s。
 - 副作用（好）：修好后立刻抓出一条真悬空，本报告原引用了阶段 6 在自己分支上登记的一条缓存膨胀条目（其 id 在本树无对应标题），因此 J2 报「悬空: …:167: #2026-09-17-N」，因此本报告已改为描述性引用（不引用未落在本树的 id，这正是 J2 该有的自测）。
 - 教训：全仓扫描类检查必须显式排除生成物目录（缓存/构建产物）；否则检查的耗时随缓存的 O(函数数 × 串表) 膨胀而爆掉（同源问题见 TODO `#2026-09-17-1` 家族与阶段 6 的缓存条目）。
7. 操作陷阱（本次实测）：`corec build --static` 定位 `src/runtime/rt.cr` 只有 cwd 相对 / exe 目录相对两条（`main.cr:112-122`），因此冻结二进制放 `/tmp` 时必须以 `cwd=仓库根` 运行，否则 `error: cannot locate src/runtime/rt.cr`（build rc=1 误报失败）；py 套件用 `cwd=BASE` 即正解。
8. bookmark 不随提交前进（本次实测命中）：jj 的 bookmark 是手动指针，本次 Step 0 设的 `feature/opt-dex` 停在链基点 `a37236aa`，链尖已是 `d4a44b25`。推前必须核 `jj bookmark list` 与链尖一致（不一致，因此 `jj bookmark set <bm> -r <链尖>`），并在 push 后 `jj git fetch` 复核 `<bm>@origin` == 链尖。
 - 若不核：推上去只有旧顶端，因此 PR 内容不全（本仓此前踩过同款），且「推成功」的输出不会报错。
9. 合并后本工作区的处置顺序（stale 修复）：PR 被 squash 合入后，本工作区 `@` 的父提交仍是旧 develop，因此工作副本 stale。
 正确顺序 = 先写入磁盘守卫（确认无未快照文件） 到再 `jj workspace update-stale`（本次由协调者按上次事故教训执行，0 个未快照文件、无损失）。
 接着不要在新基上提旧链：`jj new develop` 起新链 + 新 bookmark（本次的跟进 PR 即如此起链）；旧链内容已进 develop，属冗余，不是丢失。
 - 附：远端分支被「合并后自动删分支」删除后，本地 bookmark 会随之 prune，因此 `jj log -r <bm>` 报「doesn't exist」是预期，不是数据丢失。
 - 注意：本次实测事故（2026-09-17 跟进 2；数据丢失 + 重做）：`update-stale` 会以 jj 快照状态重写工作树，因此未快照的编辑被丢弃。
 本次正是如此：编辑在盘上（本次使用的守卫只查了「文件在盘上」= 通过），但未被 jj 快照（stale 期间所有 jj 命令报错，因此无法 snapshot），因此 update-stale 后 2 文件改动丢失，只能按记忆重做（重做提交 = `b1598efd`）。
，因此修正「写入磁盘守卫」的定义：守卫 = 「确认改动已被 jj 快照（`jj status` 可见）」，不是「确认文件在盘上」；盘上存在 ≠ 安全（update-stale 覆盖盘面）。
，因此正确处置（stale 且确有未快照改动）：先把改动文件复制到仓库外（如 `/tmp` 备份） 到再 `update-stale` 到从备份恢复到 立即提交。
，因此预防：多代理共享同一仓库时，编辑与提交之间的窗口越短越好（本次后半段教训：commit-early 不只是防连接中断，也是防 stale 覆盖）。

---

## 10. 未覆盖面（登记，不在本次）

| # | 面 | 处置 |
|---|---|---|
| U1 | 泛型实例化后的 `dex?`（`fn f[T](x: T?)` + `dex?` 实参） | 登记（类型参数面声明不可得，同 #78 裁-AGG-4） |
| U2 | `dex?` 切片/元组元素（`[dex?]` 切片、`(d?, …)`） | 登记（`[dex?;N]` 字面量被编译期明确拒绝 TK02/TA02，见套件拒绝面检查） |
| U3 | `extern` 边界的 `dex?` | 登记（W4 实参环不扩 extern，C ABI 无可选表示） |
| U4 | 比较面：`x == Some(d)` / `x == None` | 登记（走比较点声明面查表面，本次不扩） |
| U5 | `??`/`?` 于装箱载荷的形式一致性 | 本次已复测（`try_unpack_bits` 通过）；其余形态登记 |
| U6 | `dex?` 数组字面量元素类型推断（`[dex?;2] = [d, None]`，因此 TK02/TA02） | 登记为新条目候选（元素类型推断面，非本次） |
| U7 | `dex?, apx` 标签语义（无提示忽略） | 已立 `TODO #2026-09-17-4`（G3 决定：应收敛为 fail-closed，本次不改）+ 检查固定 |

> 注意：U1 更正注（2026-09-18；阶段 8（无提示面结束）T0 实测推翻本表登记的机理，原文逐字保留不删）：
> 本表 U1 所指向的 `TODO #2026-09-17-5`，其机理段不成立，`monomorph.cr:600` 的实例化只深克隆函数体 `d`，
> `a`/`b`/`c` 槽原样复制，因此实例与泛型声明共用形参节点，因此实例形参槽型恒为 `TI_INT`(GP)，
> 不存在「callee 按实例判，因此槽 = `TI_DEX_S`」这一半边（该半边是分诊期读码推断，未实测）。
>，因此真问题分裂为：(1) 调用位点实参类型不校验（fail-closed 缺失项，与 `TODO #2026-09-17-7` 同族）；
> (2) 泛型实例形参擦除（另立新条目）。该旧机理不得再被引用（不得据它写检查/实施点/归因）；
> 现象读数（ELF 142 / interp 15，期望 7/7）为实测有效，保留。

> 〔补注（2026-09-18 · `plan-verikernel` 核查）〕上句「`ELF 142` … 期望 7/7 为实测有效，保留」已作废：`ELF 142` 是分布样本
> （97 次运行命中 1 次；复跑 60 次 0 次；关 ASLR 稳定 `rc=208`），因此不得作绑定值；且 「期望 7/7」作废，`g(1, d)` 的 `T` 由首实参绑为 `int`，
> 第二实参 `dex` 与 `int?` 不符，因此应拒（要「得 7」需另裁推断方向）。现行约定 = 计划 1 节-1 T0 回填块 2：
> Ⅰ 确定性检查为主（interp `15` + `.cir` 调用点机械检查 + `--dump-params` 槽型）/ Ⅱ ELF 侧检查降为弱检查（仅「≠7」+ N≥10 次采样不复现 7）；
> 「禁第三态」对非确定值域不适用，因此改判「必须可复现」。

---

## 11. 附录：提交链（从 develop 到本次）

```
a37236aa plan  调查 + 19 例 RED + 三分根因 + 10 裁决门
eb550ad2 docs  TODO #2026-09-17-4（G3 登记）
1eab82da plan  4bis 节 十门决定 + 7bis 节 T0 记录（G4 盘点 = 干净）
5aa9e2f2 test  本次套件入仓（RED 先行）
244946a4 test  suite 常规检查组语料入仓
5d243edc ci    selfhost-tests 挂钩
1cb8e408 plan  7ter 节 T2 预备（G7 实现方式清单）
fde9d9b1 fix   R2 装箱序 5 处
ea214426 test  M1 tag 对行为固定
ed34ba3f test  M1 探针设计自纠（臂内 return 所以 读数失效）
d67efb02 fix   R1 写点门 + 槽型按声明（四态收敛）
d4dc08bd fix   R3 + G2（形参槽/实参环/返回门/读点定型；套件 30/30）
fe7c81df fix   G7：CIR_CACHE_VER 18 到 19 + 实现方式更新基准值
7896ff8d test  G9：apx 哨兵更新基准值 15 到 7 + 退役断言
269d63db fix   J3 约定版本更新（跨阶段决定）+ 三条突变自校验 + 约定入册
```

复现要点：所有构建 `nice -n 19`、前台、条件控制（`pgrep` 空才跑）；检查命令见 1 节/5 节/7 节各行。
