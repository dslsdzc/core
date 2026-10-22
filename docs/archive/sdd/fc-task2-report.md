# FC 批 T2 报告：fail-closed 检查门实施（默认阻断，豁免登记表 9 条）

日期：2026-09-15 · 任务：FC 计划 `docs/superpowers/plans/2026-09-15-fail-closed-diagnostics.md` 的 T2（设计稿为 `/tmp/fct3/fc-t2-impl-draft.md`；三处裁定来自维护者 2026-09-14：(C) 终局 · `scope=check` 3 条保留为登记 · 零产物只删本次写下者）
工作目录：`/tmp/p7wt` · 起点：`4469ce80`（容量批 T5 收尾） · 提交：`b01a948c2005b227c86d3055a65f49eb130849f7`（change `kptvnznt`；路径限定 8 文件）
纪律：`nice -n 19` · 每段前用 `ps` 实查 · CI/扫描期间不碰源（冻结后重跑五个 job） · `clean-cache` · `ulimit -c 0` · 未 restore/rebase/新建 workspace · 主树 `/home/DslsDZC/core/` 下的路径 仅写授权报告路径

---

## 0. 摘要

| 项 | 结果 |
|---|---|
| 实施 | 类型面检查反转（旧 11 码正向名单退役）· 豁免表 9 条写入 `diag.cr` · `scope` 常量写入 `globals.cr` · 零产物删除点写入 `main.cr` · 新套件 17 例加 `run.sh` 挂点 |
| 语法面/安全检查面 | 不动（后者本来就是「任意新诊断即 rc=1」），照设计稿 |
| 判据 | 五 CI job 5/5 rc=0 · 枚举 60/60 · selftest 415/415 · canary IDENTICAL · `.ccr` 四条同锁值 · 链 `5154425478…` IDENTICAL · `backend_bootstrap` rc=0 |
| 对表 | 无表外命中（T1 `would_block.tsv` 的 7 条 build 行全部放行，34 条 check 行逐条不变，6 档先前失败的套件全部通过） |
| 突变 | 4/4 生效 |
| 偏差 | 72 档日志有 2 档为纯行号偏移 +53（编辑了编译器自身源码；先例 P6 T2 为 +146）· 探针 1 档为进度行（旧硬名单码档） · 进度行保真修正 1 处（设计稿外） |
| 发现 | 预存高危：安全面诊断随 `.cir` 暖缓存不报错地消失，记 TODO #60（本批不修，另批处理） |

---

## 1. 起点复核（S0；重建二进制并重测全套基线）

| 判据 | 实测 | 与 lead 给定值 |
|---|---|---|
| 重建×2 | 逐字节同（日志也逐字节同） | — |
| 二进制 | corec `886a72bb…` · corearch `55ea2a7c…` · corelsp `3889d9ed…` | corec 相同；corearch 与 lead 给的 `f69240ae…` 不符。核实后：`f69240ae…` 是自举链 `corec2`/`corec3` 的 sha（见下表），不是 corearch，口径澄清后无冲突 |
| canary | `95084e7b…d475`（28822B） | 相同 |
| `.ccr` 四条（冷） | 96015 / 96158 / 142793 / 142936（差恒为 143B） | 相同 |
| `--dump-objects` / `.cir` DOT | 3521 行 / 165915B `b1bdf480…` | 相同 |
| `selftest-types` | 415/415 | 相同 |
| 72 档 / 探针 | 34×0/38×1 / 17×0/12×1 | 相同 |
| 全枚举 / 五 CI | 59/59 / 5×rc=0 | 相同（59 是容量批后的档数） |
| 自举链 | `corec2==corec3` `f69240ae…` + N06=0 + 冒烟 42 + `--help` rc=1 | 相同 |

---

## 2. 落码（S2/S3）和豁免表

### 2.1 四处改动加一处保真修正

| # | 落点 | 形态 |
|---|---|---|
| 1 | `src/compiler/main.cr` 类型面检查 | 硬判定循环改为 `if diag_gate_exempt(ec, GATE_SCOPE_BUILD) == 0 { hard = 1; }`（旧的 6 语句行和 11 码名单整体退役）；语义为默认阻断 |
| 2 | `src/compiler/main.cr` 零产物 | `exit_code := system(cmd2);` 之后加入 `if exit_code != 0 { system("rm -f \"<ccr_path>\""); }`（只删本次 `save_ccr` 写下的文件） |
| 3 | `src/compiler/diag.cr` | `fn diag_gate_exempt(code, scope)`：表 9 条，每条带「位点证据 / 理由 / 退出条件」；「只减不增」纪律写入头注 |
| 4 | `src/compiler/globals.cr` | `GATE_SCOPE_BUILD = 1` / `GATE_SCOPE_CHECK = 2`（与 `DIAG_REC_SIZE` 同址，即 `:203`） |
| 5 | 设计稿外（保真修正） | `[5/5] frontend done` 从「仅 `hard==0` 路径打印」改为「诊断之后、返回之前一律打印」。否则 25 档语料日志缺这一行（首版把它移到检查门之前，造成顺序差；二次修正为同址打印） |

语法面 `:134/:135` 和安全检查面 `:594-603` 零改动（照设计稿第 1.1/1.3 节）。

### 2.2 豁免表 9 条（scope 分布为 build×6 / check×3）

| # | 码 | scope | 位点证据（T1/T2 实测） | 退出条件 |
|---|---|---|---|---|
| 1 | TF01 | build | 5 档并发族 suite build（chan/conc/go_e2e/go_final/go_parallel_test.cr） | 修前端根因后撤 |
| 2 | TF07 | build | `ptr_ref_first.cr:8`（`@raw_int`；唯一 raise 点 `checker.cr:3727`） | #20/F3 收口后撤 |
| 3 | TB01 | build | `ptr_ref_first` 加 8 档库单元（级联码：ANY 门 `checker.cr:2473-2474`） | 随根因码消失 |
| 4 | TM04 | build | `test_match_exhaust.py:217`（`case_soft`：build rc=0 加产物） | 政策改判 |
| 5 | TK01 | build | `test_xcut_iface.py:234-241`（`case_reject soft=True`） | 政策改判 |
| 6 | B04 | build | `tests/suite/ptr_arith.cr:12:8`（canary 检查） | 裁-FC-3 (c)/(i) 后撤 |
| 7-9 | N01 / N06 / N11 | check（仅登记） | 25 档库单元单独 check | 口径固定；(C) 下对判定惰性（不得据此实现 (B) 活分支） |

---

## 3. 控制面（S4；仓内套件 `tests/selfhost/test_diag_gate.py` 17/17）

- 正控 9：表内 6 个 build 面码仍然放行（`TF01`/`TF07`+`TB01`/`TM04`/`TK01`/`B04`：逐档 `build --static` rc=0 加产物，诊断仍在）；`scope=check` 的 3 条（`N01`/`N06`/`N11`）check rc=1 不变。
- 负控 6（三类面）：语法面 `P21` · 类型面 `TA02`/`R02`/`TM03`/`TK05` · 安全检查面 `TU03`，全部 rc=1 加零产物。
- 零产物 3：前端失败无半成品；corearch 失败删除本次 `.ccr`（用 stub corearch 仿真后端失败，corec 的删除逻辑是被测对象）；既有旧标记值（ELF/`.ccr`）失败后原样仍在（裁-FC-6）。
- B6 项如实保留（不加豁免、不抹平）：安全面负控冷态 PASS（`clean-cache` 后 rc=1 加零产物）；暖态受预存缺陷影响，同源二次构建诊断消失，rc=0 且产出 ELF（见第 7 节，已立 TODO #60）。仓内套件按 runner 纪律逐例 `clean-cache`，因此稳定 PASS。
- 施工期两次失败都已归因并修正：① C2 的原触发源（extern 未解析）不产生 ext rel，改用「stub corearch」；② 输出路径为目录不触发写失败，改用同上方案。

---

## 4. 突变控制（S5；4/4 生效，全部在仓库外实拷贝，测后清理）

| # | 突变 | 实测（期望到实得） |
|---|---|---|
| M1 | 豁免表删除 B04 条 | ptr_arith（canary 检查）再次失败：build rc=1 加无产物，报出 `error[B04]` |
| M2 | `scope` 字段失效（去掉 9 条的全部 scope 条件） | `N01` 源在 build 面不报错地放行（rc=0 加出 ELF），不报错地面复现 |
| M3 | 去掉零产物删除点 | corearch 失败后 `.ccr` 半成品残留 |
| M4 | 表尾 `return 0` 改为 `return 1`（全放行） | 负控 `R02`/`N01` 转为通过（rc=0 加出 ELF） |

---

## 5. report-only 复跑和对表（S6；无表外命中）

| 腿 | 结果 |
|---|---|
| build 面 7 档（T1 `would_block.tsv` 的 build 行） | 全部放行：`chan_test`/`conc_test`/`go_e2e_test`/`go_final_test`/`go_parallel_test`/`ptr_arith`/`ptr_ref_first` 逐档 rc=0 加 ELF |
| 72 档 check 面（34 条 rc=1 行） | rc 逐条不变（34×0/38×1），诊断逐条相同 |
| 探针 29 档 | 12×1 逐条不变（唯一差异见第 6 节-②） |
| T1 的 6 档先前失败的套件 | 全部通过（ccr_types · interp_float · interp_parity · match_exhaust · native_float · xcut_iface），枚举 60/60 |
| 表外命中 | 0（T1 预测的全部命中面都被 9 条表覆盖） |
| 豁免码在豁免面外触发 | 0（没有新的假阳性） |

---

## 6. 判据全套（S7；冻结源后重跑）

| # | 判据 | 实测 |
|---|---|---|
| 1 | 五 CI job | 5/5 rc=0（`check`/`bootstrap-tests`/`suite`/`selfhost-tests`/`full-bootstrap`；新套件在 job 内跑出 `17/17 passed`） |
| 2 | 全枚举 | 60/60（59 加本批新套件） |
| 3 | `selftest-types` | 415/415 |
| 4 | ELF canary | `95084e7b…d475`（28822B）IDENTICAL（无豁免，变化即停） |
| 5 | `.ccr` 四条 | 96015 / 96158 / 142793 / 142936（差恒为 143B；sha 逐条同锁值） |
| 6 | `--dump-objects` / `.cir` DOT | 3521 行 / 165915B `b1bdf480…` |
| 7 | 72 档对拍 | rc 零差异（34×0/38×1）；日志差异见第 8 节-① |
| 8 | 探针 29 | 12×1；差异见第 8 节-② |
| 9 | 自举链 | `corec2==corec3` IDENTICAL（`5154425478…`，新值，编译器源变更所致）加 N06=0 加冒烟 42 加 `--help` rc=1 |
| 10 | `test_backend_bootstrap` | rc=0 |
| 11 | 仓内套件 | `test_diag_gate.py` 17/17（已挂 `run.sh`） |

---

## 7. 单列一节：预存缺陷，安全面诊断随 `.cir` 暖缓存不报错地消失（TODO #60）

| 状态 | P6 期二进制 `ae01de75…`（本批之前） | 本批二进制 `d107b34b…` |
|---|---|---|
| 冷（`clean-cache` 后） | 报出 `error[TU03]` | rc=1 加无产物 |
| 暖（同源二次构建） | `error[TU03]` 消失 | rc=0 加产出 ELF（28822B） |

- 复现源：`fn main() -> int { p := 4096 as *int; return *p; }`（即 `tests/selfhost/test_pointer_safety.py:131-138` 的形态）
- 两面目：`build --static` 和 `ccr` 同病（各自冷态报出、暖态不报错地）
- 性质：预存（P6 期二进制同值复现，不是 TC02、容量批或本批引入）；危害是不安全程序从第二次编译起不报错地通过
- 疑似根因（待实证）：`.cir` 快照只落指令和节点，provenance 侧表（`g_pts`/`g_offsets`）在 `ir_gen`/`ptr_analysis` 期建立，命中路径未重建或未重算
- 判据盲区：全部 runner（`parity_run.sh:35` / `probes_run.sh`）逐档 `clean-cache`，因此该面永远在判据网之外
- 派生建议（本批不实施，须独立批）：给两条 runner 加暖态腿（同源二次构建后对拍 rc 和诊断）
- 处置：本批不修（章程是检查门反转）；登记为独立批候选（TODO #60）

---

## 8. 偏差和差异（逐条归因，不抹平）

1. 72 档日志差异 2 档（`t2_src_compiler__import.cr` · `t3_src_compiler_ccr_io.cr`）：纯行号偏移 +53（29935 到 29988 / 23506 到 23559）。语料包含编译器自身源码，本批编辑了 `main.cr`(+)、`diag.cr`(+48)、`globals.cr`(+5)，导致拼接行号位移；rc 和诊断文本逐条相同。先例是 P6 T2「两档自源日志差异为纯行号偏移 +146」。
2. 探针 1 档差异（`n05_recursive.cr`）：多一行 `[5/5] frontend done`。它的诊断 `TS03` 属于旧硬名单，S0 提前返回时没有该行；本批把该行改为「诊断后、返回前一律打印」后补上。rc 和诊断同。
3. 进度行保真修正（设计稿外）：见第 2.1 节-#5（首版移到检查门之前，造成 25 档顺序差；二次修正为同址打印，差异降到上述 2+1）。
4. corearch sha 口径澄清：lead 给的 `f69240ae…` 是自举链 sha（不是 corearch）；本批 corearch 为 `22e96d03…`（`globals.cr` 变更所致）。
5. B6 暖态：如实保留（第 3 节末），冷态 PASS，暖态受预存缺陷影响；未加豁免、未改判据。

---

## 9. 登记项

1. 豁免表纪律：只减不增（撤条须带根因证据，加条须维护者批准，每次开新面重跑 report-only 并对表）。
2. `scope=check` 的 3 条：在 (C) 下惰性；(B) 不是活选项，不得据此实现活分支（仅注释保留）。
3. 零产物边界：只删本次写下的文件；既有旧 `<out>` 和旧 `.ccr` 不动（前端失败路径原样；corearch 失败路径的 `.ccr` 因 `save_ccr` 已覆盖而被删除，不造成额外损失）。
4. TODO #60（预存高危缓存缺陷）加派生建议「runner 暖态腿」（本批不实施）。
5. 施工期两次测试装置失败（C2 触发源不成立、目录输出不触发写失败）已改法，并在报告中留痕。

---

## 10. 证据路径

| 用途 | 路径 |
|---|---|
| 本文 | `/tmp/fct3/t2-report.md`，归位到 `/home/DslsDZC/core/docs/archive/sdd/fc-task2-report.md` |
| 状态盘（防断线） | `/tmp/fct3/t2-state.md` |
| 设计稿 | `/tmp/fct3/fc-t2-impl-draft.md` |
| 控制面 | `/tmp/fct3/controls.py` · `controls2.py` · `/tmp/fct3/ctl*/` |
| 突变 | `/tmp/fct3/mutations.py`（mut1..mut4 构建/测试日志） |
| 判据原始件 | `/tmp/fct3/{parity_t2c,probes_t2c,enum_t2b,ci_t2b_*}` · `build_t2*.log` · `pa_t2b`（canary） · `pa_c.ccr`/`pa_s.ccr`/`gt_c.ccr`/`gt_s.ccr` · `gt.cir` |
| 预存缺陷证据 | `/tmp/fct3/ctl2/b6_{rc,rc2}.bin`（冷/暖态产物）加第 7 节对照表 |
