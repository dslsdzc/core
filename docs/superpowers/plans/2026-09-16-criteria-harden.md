# 检查体系加固批（criteria-harden）：接入点扩容（+6 档）与六条弱检查改强

范围：本批只改动检查与接入点，改动面为 `tests/`、`tests/harness/ci_hook_allowlist.txt`、`src/ci/run.sh`、`TODO.md` 与文档。

零源码语义改动：该结论由 `jj diff` 实证，diff 输出中无 `src/compiler` / `src/arch` / `src/format` / `src/runtime` / `src/stdlib` / `src/targets` 命中。

输入：检查强度审计（`docs/superpowers/implementation/2026-09-16-criteria-strength-audit.md` 表 B / 第 4 节）与 `TODO.md` #84–#88/#90。

基点：develop `f7798197`（工作区 `/home/DslsDZC/core-crit-ws`；bookmark `feature/criteria-harden`）。

## 1. T1 接入点扩容

本节按审计 第 4 节的成本序排列。表中的时长列为本机实测值，逐条与 `run.sh` 的行注一致。

| 档 | 时长实测 | 结果 | job | 依据 |
|---|---|---|---|---|
| `test_ent_kernel_neutrality.py` | 0.05s | PASS（A/B clean） | `bootstrap-tests` | 纯 python 静态 guard，无编译器依赖 |
| `test_slice_bounds.py` | 1.4s | 7/7 | `selfhost-tests` | 低（TODO #2026-09-11-13/#89 点名） |
| `test_region_cfg.py` | 0.9s | 22/22 | `selfhost-tests` | 中（与格式批同族，因此漏检面） |
| `test_live_ranges.py` | 1.4s | 13/13 | `selfhost-tests` | 中 |
| `test_hit_table.py` | 2.3s | 24/24 | `selfhost-tests` | 中 + 本批 #84/#86 改强落在其中 |
| `test_backend_bootstrap.py` | 22.5s | PASS（stage0/1/2 + O2 元数据） | `selfhost-tests` | 高：allowlist 自标「最高危」= N06 唯一门（rc=0 但日志带 `error[` 判红；曾致 P3a 33×N06 漏检）。审计只担心「构建面成本」，实测 22.5s，因此可接入 |
| `test_criteria_mutations.py`（本批新增） | <1s | 22/22 | `bootstrap-tests` | 突变自身验证实现方式（第 3 节） |

- `tests/harness/ci_hook_allowlist.txt` 同步删除 6 条，遵循的纪律为「删条目 = 已接入」；头注同步重算（`scope 66 / hooked 45 / 差集 21`）。
- 未接入登记：`test_mw_task1-6` 属标准换代（零 diff 基线须在改动前的编译器上产出，因此 CI 参照物在结构上不可得；机器化需「基线入仓」取裁或改约定）；`test_lsp` 属进程级，未实测；其余历史缺失档在差集中逐条附理由。
- 过程证据（覆盖检查的有效性）：先接入 `run.sh`、未删允许清单条目时，`test_ci_hook_coverage.py` 当场变为失败，并逐条指名 5 个「已接入但允许清单未删」的条目；新增 harness 档未接入时同样变为失败。该表现说明该检查不是形式上的机制（本仓曾因「自称已接入」出现 33 次 N06 漏检）。
- 终态：`[PASS] ci_hook_coverage: scope=66 hooked=45 unhooked(allowlisted)=21`（含内存内「摘接入点必红」自身验证）。

## 2. T2 六条弱检查改强

六条检查均改换为新断言形态；每条含「反例自检 + 探针触发自检」注释。

| # | 旧形态（弱因） | 新断言形态 |
|---|---|---|
| #84 `test_hit_table` 事件 1-4 | `stream[:2] == want`（只比 REX+opcode） | `ev14_template_problems`：1 step 全字段模板（键集+取值逐键相等：opcode 全字节 + REX 全位 + modrm 两角色 + rm_mode）；2 重建流与 M1 模板全等（非前缀）；3 不可达前提显式断言（注入语料不得覆盖 sub/nand，事件 1/2 对真 IR 不可达，因此本表断言是其唯一字节证据） |
| #86 `test_hit_table` 标记值 | 4 字面量排除清单 | `dump_sentinel_problems`：结构化解析 + 允许清单形态（`ev <n> dst=<v> s1=<v> s2=<v>$`；值 `\d+`/`pool\d+`）+ 未用字段逐字符 == "0" + store/load 计数非空转。适用范围：用于字段取任何 `\d+`（含 255）不是伪影、不主张覆盖 |
| #87 `test_cir_warm_path` STR | 只登记尺寸（预存豁免） | `str_contract_equal`：暖 STR = 冷 STR 前缀（`n_warm ≤ n_cold`、同 index 逐条字节同、非空转）。先实测后定检查：A5 181 改为 169 条 / D4 574 改为 562 条，冷多出的正是 ir_gen 临时名（`_arena`/`bin`/`str`/`call`/`_lazy`…） |
| #88 `test_ccr_types` 剔除面 | 黑盒逐行过滤后比对 | `dump_strip_face_problems`：连续段 + 唯一头行 + 剔除行数 == 1 + 头行自报 `nodes=` + 数据行 9 字段且首字段 == 行序数 + `nodes ≥ 1`。约定修正（实测驱动）：`rows=` 是类型表行数不是数据行数，初版按 `rows` 计数真运行当场红，改 `nodes=` 并加序数断言（比原设想更强） |
| #90 `test_mw_task2` E8 未检查范围 | 遇 `0xE8` 字节即跳 5B | 检查侧独立 x86-64 长度解码器（fail-closed：未登记形态，因此判红）+ `region_equal_mask_calls` 指令边界锁步（两侧边界序列逐条一致；非 call 全字节比；call 仅允许 4B rel32 且目标断言落在本 text 内） |
| #85 `test_mw_task2` 块体 | 2B 前缀基准 + 目标序 | `parse_slow_block` 逐指令模板（除 alloc 位移/dest 槽偏移/回跳位移三字段外全字节固定）+ `tag 立即数 == 1` + 回跳落真指令边界 + 块间连续 + 各站点 alloc 目标唯一 |

真运行证据（全部本机实测）：`test_hit_table` 24/24；`test_ccr_types` 49/49；`test_cir_warm_path` 19/19；`test_mw_task2` ALL PASS，其中 z 用例零 diff 9/9、豁免面计数 1/1/2、t3 250 站点、新增 `t4_sub_overflow` 三档。解码器与 `objdump --insn-width=16` 对比 17 个真实 region（含 t3 3272 条指令），逐指令边界一致。

## 3. 突变自身验证

本批的突变条目要求为 ≥3 条，实交 22/22 条，且已固化入仓。

`tests/harness/test_criteria_mutations.py`（纯 python、内存内、零副作用；接入 `bootstrap-tests`）含 19 突变体与 3 正控；每例的检查为「旧形态骗得过（绿）∧ 新形态能捕获（失败）」，M1 #84（角色换向/opcode 尾加 1B/rm_mode）· M2 #86（1 / 0xFE / 0xFFFFFFFF / `00` / 行尾随字段）· M3 #87（同尺寸改内容/中间漏条/有缓存状态多一条）· M4 #88（多印未计数行/非 dump 处混入/同数量换行）· M5 #90（改 `48 C7 45 E8 …` 的 imm32，0xE8 是数据字节，旧未检查范围跳过，因此旧绿新红）· M6 #85（tag 1 改为 0 / 插 `0x90` / `4C 89 10` 改为 `18`）。

## 4. 本批抓到的新假绿

本批抓到两条新假绿，已追加进审计 spec 第 0bis 节，并附判别法。

1. `t4_sub_overflow`：检查内部 `sub` 分支从未被走到，块体模板的 `is_sub` 分支断言（`not r11`）在原三例（全 add）下从未执行，因此属 第 0bis 节 第二类假绿（探针不触发）。判别法 = 逐分支覆盖检查（检查每个条件分支问「哪条语料走到它」）。
2. 解码器 fail-closed 当场抓到未登记 opcode `0x19`（慢路径块首 `4D 19 DB` = `sbb r11,r11`），因此这是「宁可红会报错」的现场实证；若当初写成「未知，所以跳过」，则该缺失会不报错地留存。

## 5. 全量检查（T3）

下表逐项列出本批的全量检查与结果。

| 检查 | 结果 |
|---|---|
| ELF canary + `.ccr` 四条 | 5/5 PASS（值源 `tools/baseline/canary_values.tsv`）：`95084e7b…d475`(28822B) · `680a6f98…cd7a`(96015) · `76f36e6a…f329c`(96158) · `d92a2727…2c95`(142765) · `a1f7b99c…82ea`(142908) |
| 分支1 固定基线同源对比 | 空缓存状态（`check` 面）73 档日志 + `parity.out` 逐档 `diff -rq` 空 = 零差异（固定基线 = `/tmp/apx-t1/baseline/corec`，sha 与 REBUILD 允许清单 `ae01de75…` 一致）。暖广度检查备注：`stats.tsv` 有 2/73 档差异（`at_test_mini.cr` build 面 rc 0 改为 1 + 条目 17 改为 0；`global_seam_test.cr` 条目 16 改为 15），均为跨批 delta（PINNED `97f4394f`，再 本基点 `f7798197`），非本批所致（本批零编译器输入 diff）；其中 N06 build 面阻断正是 FC 批裁-FC-1(A) 的显式登记变更（`docs/superpowers/plans/2026-09-15-fail-closed-diagnostics.md:117`） |
| 行为探针 | 29 档 · FAIL=0（有缓存状态生效 ≥1 真命中 = 15 档） |
| `selftest-types` | 415/415 |
| 五 CI job（`check` / `bootstrap-tests` / `selfhost-tests` / `suite` / `full-bootstrap`） | 全部 rc=0（31s / 4s / 142s / 29s / 237s），新接入 6 档在 job 日志内逐档留痕；`full-bootstrap` 含 `cmp corec2 corec3`（不报错地 = 逐字节同）+ `corec3 --help` |
| 自举链 + N06 + 快速验证 | `error[N06]` 计数 = 0（full-bootstrap 日志）· 快速验证 `corec run 'fn main()->int{return 42;}'`，再 rc=42 |
| 接入点覆盖检查 | `[PASS] scope=66 hooked=45 unhooked(allowlisted)=21` |
| 枚举（实读） | `tests/selfhost/test_*.py` 55 · `tests/bootstrap/*.py` 7 · `tests/harness/test_*.py` 4 · `tests/probes/*.cr` 29 · `tests/suite/*.cr` 33 |

## 6. 未覆盖面与交接

- `test_mw_task1-6` 仍未接入（标准换代，需取裁）；`#90` 的检查虽已改强，但该条检查仍靠手工运行（同因）。
- 本批新增的 `t4_sub_overflow` 为行为覆盖用例（不改源码语义）；`t3` 的 250 站点块体模板断言随语料规模线性增长（实测可接受）。
- 检查侧解码器（`x86_insn_len`）为检查专用：发射器新增指令形态时它会判红（fail-closed），需按新形态登记，这是有意的维护点，不得改回「未知即跳过」。
