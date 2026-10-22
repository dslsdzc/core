# 聚合读丢型（TODO #2026-09-16-16），批报告（#78 批 2 · 2026-09-16）

批名：聚合读丢型 · 批次位置：用户排序的第 2 批（维护者 2026-09-16 派单）
起点：`develop = 99ae6bdd`（T1 时点）· 完成：`develop 66eb9589`（T3 合入后）
性质：只读调查、计划、决定、实施、判定与突变、结束（全程先裁后码、三态规则、路径限定小步提交）
输入：`TODO.md` #78 · `docs/superpowers/implementation/2026-09-16-apx-conversion-audit.md`（1 节 3b/4b/5/6b/8 + 2 节表 B）
计划：`docs/superpowers/plans/2026-09-16-agg-read-type.md`（11 节 T1 记录 · 12 节 T2 记录 · 13 节 T3 记录）

---

## 0. 批终态一行结论

修好：聚合读结果槽固定为 `TI_INT`，因此「按 IR 值型触发」的下游在经聚合读入的值上连锁无法识别，此为最主要根因。
修法 = 读点定型改取声明面形式（dex 声明时取 `TI_DEX_S`；零 alloc 节点判），并 `CIR_CACHE_VER` 17 改为 18 换代。
检查：检查组 A 4/5 通过（R4 按裁-AGG-3 登记 `[GAP]`）· 检查组 B 四条界面见证全部通过 · 检查组 C 断言通过 · canary 5/5 IDENTICAL ·
74 档/29 探针 rc 全同 · 五 CI job rc=0 · 自举链 `corec2≡corec3` · 检查组 D1 突变通过（apx hack 冗余确认）。

## 1. 交付（提交链）

| 提交 | 内容 |
|---|---|
| `（T1 记录）` | 前置 + 固定基线（改前二进制 sha256）+ R1–R7 改前实测（5 项失败 2 断言通过）+ IR 级机理正面证据 + 两条需实证限定 + 归类修正，并提交 PR #89（已合入） |
| `（T2 记录）` | 探针入仓（RED 9 项实证）+ 允许清单登记 + 两条问题写入仓库级文档 + T3 验收形状并提交 PR #90（已合入） |
| `e1680065` | T3 实施：声明面形式判定（4 个节点级零 alloc helper）+ 3 读点接线 + `CIR_CACHE_VER` 17 改为 18 + 换代更新基准值（3 个版本位实现方式 + 2 处陈旧注释）+ 接入点三件套并提交 PR #91（已合入） |
| `5a245777` | T5：`TODO #2026-09-16-36`（元组 + 切片未覆盖家族合并条目）+ `#78` 状态改已修 |
| （本文件） | T5：批报告 |

完成形态：T1/T2/T3 各自独立 PR（squash 合入），每段实现即合，与「小步提交」（402 连接中断风险对策）一致。

## 2. 根因与修法

根因：聚合槽的规范存储形式恒为精确（scaled）（apx 批不变量「聚合面不存在 apx 形式」，写点汇聚点 `dex_slot_norm` 保证），
但四个读点把结果槽固定为 `TI_INT`：字段读 `ir_gen.cr:2590` · 元素读 `:2655` · match 臂载荷 `:2393` · match 结果槽 `:2299`
，因此「按 IR 值型触发」的下游全部无法识别（`dex_store_adjust` / `dex_scale_int` / 二元分流 / extern 边界 / LET 继承 / 泛型键名串）。

修法（裁-AGG-1 1）：读点定型取声明面形式，4 个节点级零 alloc helper：

| helper | 声明面来源 | 手段 |
|---|---|---|
| `agg_read_form_is_dex` | — | `ast_kind(tn)==0 && ast_type_val(tn)==TY_DEX`（不调 `res_type_node`）|
| `agg_field_read_form` | 结构体字段类型节点 | `find_struct` + `si_field_type_node` + 节点判；数字元组下标，因此 `TI_INT` |
| `agg_elem_read_form` | 数组/切片的元素 ti | `elem_ti_of_decl(slot_decl_ti(arr))` 纯表读；`TI_DEX`/`TI_DEX_S` 均归一 `TI_DEX_S` |
| `agg_payload_read_form` | 枚举变体载荷类型节点 | `find_gsym`+`find_enum_row_of`+`ei_variant_type_node` + 节点判 |

接线 3 读点：字段读（`fi` 解出后 `irv_set_type`）· 元素读 · match 载荷绑定。非 dex 形态恒 `TI_INT`，因此非 dex 程序逐字节不变。

不直接取完整类型的原因：`res_type_node` 对命名/聚合/指针类型会 `alloc_type`（GC12′），因此只用 dex 轴二值判定；
且 `TI_DEX_S` 是预置常量（非新分配的类型行）。

## 3. 检查（全部通过）

| 检查 | 结果 |
|---|---|
| 检查组 A（语义值） | R1 LET 中转 · R2 match 载荷 · R3 局部数组元素 · R5 写回 apx 槽，`elf=7` 全部通过（改前全 = 1，`check` 0 error = 无提示）；R4 见 10 节 |
| 检查组 B（界面见证） | B1/B2 反方向 `_dxt`=0 · B3 正方向 `_dxdiv`=恰好 1 · B4 extern 调用点前有转换，四条全部通过（改前四条全部失败）|
| 检查组 C（非回归断言） | R7（Core 实参，改前已正确）· N1（apx 批已转正形）全部通过 |
| 停条件1（非 dex 零影响） | canary 5/5 IDENTICAL（ELF `95084e7b…d475` 28822B + `.ccr` 四条 96015/96158/142765/142908）|
| 74 档 parity | rc 逐档全同（35×0 / 39×1）· 暖缓存检查组 FAIL=0（41 档真命中）|
| 29 行为探针 | rc 与基线全同 |
| 接入点 harness | `test_ci_hook_coverage.py` PASS（scope=69 hooked=48 unhooked=21）|
| 五 CI job | 全 rc=0：check / bootstrap-tests / selfhost-tests（49/49 ccr_types · 23/23 interp_parity）/ suite（23 档 ALL PASS）/ full-bootstrap（`cmp corec2 corec3` 恒等 2904726B · sha256 `b8e4298ad0d7…`）|

IR 级机理正面证据（改前到 修后）：R1 改前 `load_field 到 const _dsc=1000000 到 binary _dxt = x * _dsc 到 binary _dxm = _dxt * dex`
（读槽被当 int 二次缩放），因此修后该 `_dsc/_dxt` 对消失（检查组 B 的 B1/B2 即此见证）；R5 改前 `load_field 到 call_extern`
中间零转换，因此修后出现转换（B3/B4）。

## 4. 检查组 D1 突变证据（关闭 apx hack 后通用机制仍然成立）

把 `ir_gen.cr:1342-1343`（apx 批的比较/运算点声明面 hack）注释化到 重建到 跑：
apx 批套件 23 例全部通过 + 本批 6 例 + 检查组 B 全部通过，因此声明面机制完全接管 hack 的覆盖面，因此 hack 冗余从推测变实测。
（退役检查 = 「连通过两批」第一步；随后恢复源码+重建+复验全部通过。）

## 5. 二进制同一性论证（必须重跑的条件）

T5 的改动是 docs/TODO-only，但「文档改动」不足以说明检查仍有效，实测：终态重建的 `build/corec`
与检查二进制逐字节相同（sha256 `64c8a7d6…`），因此已跑出的 canary / parity / probes 结论对终态继续成立。

> 约定：检查结果的有效性绑定二进制内容而非提交号。凡「源码到 二进制」映射未变（注释/文档/测试改动、
> 或重建后 `cmp` 相同），检查不必重跑；一旦重建产物不同，则必须重跑受其影响的面。
> 本约定把「必须重跑的条件」从习惯判定变为可判定项。

## 6. 方法：两条对照教训（维护者指定必写）

> 「`.ccr` 没变 ≠ 生成面没变」（#93 批：go 绑定修复改了生成面，而固定语料无该形态，因此 canary 无感）
> 与 「`.ccr` 没变 ≠ 这个面被覆盖了」（本批：固定语料零 dex，因此 canary 5/5 IDENTICAL 是预期，
> 但它对本批目标面零区分力）。

两句合起来才完整：检查的「通过」只在它的覆盖域内有意义。本批因此把「canary IDENTICAL」写成结论的一部分
而非证据的全部，真正的证据 = 检查组 A/B/C + 突变 + `[GAP]` 显式登记。

## 7. 方法：GC12 规则的修正顺序（维护者指定必写）

调查时发现：`ir_gen.cr:2455` 当前已有非 optrep 条件控制的 `res_type_node`（带注解 LET），且 `res_type_node` 对
基类型节点走 `ty_code_to_ti`（`iface_registry.cr:274`）是纯查表零 alloc，只有命名/聚合/指针类型才 `alloc`。
，因此把 GC12 从「不得新增 `alloc_type` 站点」收紧为「不得新增可能 alloc 的类型站点」（更准），
然后仍然不用它（本批一律走节点判 + 纯表读）。

> 顺序本身就是方法：先把规则改准，再决定用不用，若先按粗约定办事（「res_type_node 一律禁止」），
> 会误伤正确的路径；若先松后紧（「基类型不 alloc，可任意使用」），则会漏掉聚合/命名类型的 alloc 面。

## 8. 命令层问题写入仓库（维护者要求：必须写入仓库，不能只写在报告里）

`tools/baseline/REBUILD.md` 新增 `### 命令层陷阱（误报失败）`（与既有「适用范围限制 / 已知限制」同区）：

- `noclobber`：重定向到已存在的日志文件，因此该重定向失败、命令实际未运行，`tail`/`grep` 读到的是上一轮旧日志
 （本批 T1 首轮 8/8「失败」均由该原因产生；同一陷阱为第二次命中，首次在 #93 批的 CI job 轮询）。
- `corec build` 必须在仓库根跑：在 `/tmp` 下，因此 `error: cannot locate src/runtime/rt.cr`（与既有「cwd 决定 import 解析」同族）。

检查：`grep -rn noclobber tools/` 命中该文件（仓级可搜）。

## 9. 换代更新基准值清单（裁-AGG-7 四要素：旧值 · 新值 · 归因 · 出处）

| 实现方式 | 旧到 新 | 处置 |
|---|---|---|
| `cir_cache.cr:51` | `CIR_CACHE_VER` 17 改为 18 | 改常量 + 注释（旧快照读槽型 `TI_INT` 与新语义不等价，因此命中旧条目会重新生效坏 IR；与 TODO #2026-09-10-4 同族；cache miss = 无害重建）|
| `tests/selfhost/test_ccr_types.py` ㉛㊲ + 模块头注 | 断言 `== 17` 到 18 | 断言 + 三处注释（旧/新/归因/出处）；㉛ 的结构面（节点小节 64B stride、项槽不写入磁盘）不变 |
| `tests/selfhost/test_cache_identity.py` | `VER_EXPECTED` 17 改为 18 | 同上；布局未变（v18 与 v17 对应），因此 `layout()` 的 v17 分支按 `VER_EXPECTED` 复用 |
| `src/compiler/dyn_arr.cr:112` · `src/compiler/ccr_io.cr:137` | 陈旧注释「`CIR_CACHE_VER=17` 不 bump」 | 注释更新 + 指向本批（注释-only，零行为）|
| `.ccr`（`CCR_VERSION=9`） | 不 bump | 交付格式、无快照复用语义；注意：但报告显式写明：dex 程序的 `.ccr` 内容会变（格式不变、内容变），防「版本没 bump」被读成「内容没变」|

更新基准值过程留痕：首轮 `selfhost-tests` rc=1（两例版本位断言） 到更新基准值后复跑再次变为失败，经隔离（干净缓存 49/49；
改前二进制对照 47/49 恰为该两例）判定为环境 flake，非本批引入到 第三次变为失败 = `VER_EXPECTED` 未同步，因此一并更新基准值后 rc=0。

## 10. R4（元组）的 `[GAP]` 处置与决定出处（维护者指定必写）

- 冲突：T3 约定写「检查组 A 5/5（R1–R5）」，而裁-AGG-3 已确定「元组（无声明面）登记，不纳入本批」。
- 事实：`EXPR_TUPLE` 给元组 var 定型 `TI_INT` + `IR_ALLOC_ARRAY`，不携带元素 ti，因此数字下标（`t . 0`）取不到声明面。
- 处置（按决定执行，不会无提示、不越权）：实施不含元组；套件把 R4 移入 `[GAP]` 组，只观测、不计检查、
 打印期望值 + 实测值 + 决定出处（后续批修复时须把它移回 `CASES`）。
- 决定（维护者 2026-09-16）：维持裁-AGG-3。理由：1 冲突源于任务卡措辞（决定优先）；2 现在覆盖元组 =
 引入新机制 + 二次改生成面（`&tuple` 的 pointee 型行身份），因此与本批已改的 `.cir` 版本 + dex 生成面检查范围混类；
 3 `[GAP]` 是「缺失项可见而非被藏起来」的正确形态；4 元组属既有未覆盖家族（#97 泛型字段/元素 · 切片产物）
，因此应并成一条处理。
- 实现位置：`TODO #2026-09-16-36`（元组 + 切片产物合并条目，含最小机制/代价/待实证/同族互引）。

## 11. 检查可行性经验（工具链的表达能力）

验收设计的前置条件 = 先确认工具链具备该表达能力：本轮拟直接断言「读槽型 = `TI_DEX_S`」，实核发现

- `.cir` 文本转储不打印普通 IR 变量类型（`dump.cr:50-60` 的 `type_kind_name` 只在 `alloc`/`const` 行输出）；
- 且 `TI_DEX`(1) 与 `TI_DEX_S`(8) 在该表同名 `"dex"`，不可区分；
- 权威通道 = `.ccr` SYM 的 per-var 型字节（`ccr_io.cr:690`），但需自写二进制解析。

，因此改成条件控制忠实见证：`dex_scale_int`（门 = `irv_type(var) == TI_INT`）的唯一产物 `binary _dxt = …` 出现，因此读槽仍是 int；
`dex_scaled_to_bits`（门 = `irv_type(var) == TI_DEX_S`）的非字面量产物 `binary _dxdiv = …` 出现，因此读槽已是 scaled。
见证的门恰好就是所断言的类型谓词，因此忠实；两条合起来同时覆盖「槽型正确」与「无重复转换」（维护者指定的两条验收）。
（`.ccr` SYM 解析列为可选加固，未做。）

## 12. 未覆盖面与遗留

| # | 内容 | 状态 |
|---|---|---|
| #98 | 元组数字下标 + `IR_SLICE` 产物元素读（声明面取不到） | 登记（裁-AGG-3 维持）；最小机制 + 代价见条目 |
| 裁-AGG-2 | match 结果槽（多臂可异型） | 登记不纳入 |
| 裁-AGG-4 | 泛型字段/元素（声明型 = 类型参数） | 登记不纳入（与 #97 同族）|
| 裁-AGG-5 | apx hack 不删 | 退役检查 = 检查组 D1 连通过两批（本批为第一次）|
| U6 | 超大 scaled 值与 tag/2L 语义 | 计划 3.2 节登记（本批未观测到 tag 影响差异）|
| — | `IR_SLICE` 产物元素读的 `is_ptr_var:627` 早退约束 | 并入 #98 |

## 13. 已知边界

- R4 未修（按决定登记）；检查组 A 的「5/5」在任务卡里出现，但实际交付 = 4/5 + 1 个显式 `[GAP]`。
- 一次环境 flake（三例「warm run rewrote cache file」）经隔离判定与本批无关，但留痕在此，未当「已修」处理。
- exon extern 面：R6 的判定形态是 IR 断言（运行路径被 `corearch --link` 静态链既有崩溃阻塞，实测 rc=139），
 期望按维护者 U4 决定 = 规范化成 ABI binary64。
- `.ccr` 内容会变（dex 程序）但版本号不变，这是显式结论，不是遗漏。
