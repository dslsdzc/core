# 泛型参数擦除（实施记录）

> 对应计划：[plans/2026-09-18-generic-param-erasure.md](../plans/2026-09-18-generic-param-erasure.md)


## 11. 实施记录（2026-09-18）
### 11.1 变更清单（提交）
| 提交 | 内容 |
|---|---|
| `e05676ca` | A1（`monomorph.cr::gen_create_instance` 形参链克隆 + `type_val` 重算）+ `--dump-params`（`globals.cr`/`main.cr`/`ir_gen.cr`，隐藏通道：rc 中性 + 零产物 + 纯表读零 alloc） |
| `3d4712f3` | 检查套件 `tests/selfhost/test_generic_param_erasure.py`（C1–C7）+ `src/ci/run.sh` selfhost-tests 挂钩（门内）+ `COREC_BIN` 突变通道（CI 不设） |
| `45b0f85c` | 实现方式同步更新 `tools/baseline/canary_values.tsv`（`gt_ccr`/`gt_static_ccr`，旧值记录 + 归因） |
A2a 无需改代码：develop `f57815ec` 已含 `dex_align_call_args` 与重定向后的第二遍（`ir_gen.cr:2249`）；
A1 让实例形参链具体化后，该第二遍的门（`ast_type_val(cpn) == TI_DEX` / `dex_opt_type_node`）才第一次为真。
### 11.2 实测读数（改前 = `/tmp/ge-pre/corec` `08821a51…`；两侧各自 clean-cache）
| 项 | 改前 | 改后 |
|---|---|---|
| C1 · bits 源 ELF | 21（正控过、被测败） | 0 |
| C1 · bits 源 interp | 255 | 255（= 能力边界 = 期望值） |
| C2 · scaled 源 ELF / interp | 41 / 41（一致地错） | 0 / 0 |
| 槽型 `g1[dex]`（T 形态） | `slot=0 decl=0` | `slot=8 decl=1` |
| 槽型 `g2[dex]`（T? 形态） | `slot=0 decl=0` | `slot=8 decl=0` |
| 调用点 | `call g1[dex](d)`（零 `_dx*`） | `call g1[dex](_dxsc)` |
| 幂等 · `mixed` bits | 0 条 `dest=_dxsc` | 恰 2 条（每 dex 族实参一次） |
| 幂等 · `mixed` scaled | 0 条 | 0 条（两遍都无操作） |
| ELF canary `pa`×3 | — | 逐字节不变（`95084e7b…` / `680a6f98…` / `76f36e6a…`） |
| `generics_test` ELF | — | 逐字节不变（`f1f78686…b20b5`） |
| `gt_ccr` / `gt_static_ccr` | `d92a2727…` / `a1f7b99c…` | `2b364cf1…` / `cd85fd05…`（仅 3 字节，见 11.5） |
gt 归因的机械证据：1 `cmp -l` 差异字节 = 3（offset 12274/12446/12574：`0到3`/`0到3`/`0到2` = TI_STR/TI_STR/TI_BOOL），
尺寸逐条相同（142765/142908）；2 `corec cir` 的逐指令文本 dump 两版逐字节相同（发射面零影响）；
3 同语料 ELF sha 逐字节相同；4 两版运行 `ALL PASS` rc=0；5 与测量2的实例枚举对表（标量形参槽恰 3 处）。
### 11.3 突变矩阵（独立 workspace 构建；每突变一次全量构建；对比两侧各自 clean-cache）
| 突变 | 变的是什么 | 检查失败项 | 「命中目标」证据 |
|---|---|---|---|
| M-α | 只回退 `type_val` 重算（保留形参链克隆） | C3 T 形态 + C1/C2/C4/C5（T? 形态仍通过） | 两形态分列，因此 T 与 T? 路径各自可判 |
| M-β | 只关 `dex_opt_type_node` 分支（断 T? 路径） | 仅 C3 T? 形态（1 项） | 单点隔离：T? 检查非空转 |
| M-γ | 回退 A1 整体 | 10 项（C1/C2/C3×2/C4×3/C5） | 回到 RED 基线读数（21/41） |
| M-δ | 只回退 A2a（第二遍） | C1 + C4×3 + C5（C3 仍通过） | 仪器（槽型）与值检查分工：槽型已具体化但调用点无转换 |
| M-ε | 让 dump 打 `decl` 当 `slot`（仪器自证） | C3×3（值检查全部通过） | 证明 C3 抓的是槽型而非声明面 |
M-δ 顺带抓出检查自身缺陷（已修）：值探针原为「正控在前」，正控的 bits 改为 scaled 转换把 `7000000`
留在某个 GP 寄存器，被测读点靠寄存器残留读到正确值，因此 C1 误报通过。已改为「被测调用在前」并写入套件注释；
复测运行 M-δ，因此 C1 失败（ELF rc=21 / interp rc=21）。这条与阶段 7 的 D5 同类：检查集合修正的是检查自身。
### 11.4 换代判定：不换代（`CIR_CACHE_VER` 保持 20）
- 结构门：含泛型声明的单元整体关缓存（`main.cr:484-490` `fi_generic_count`；`:495-497` `g_optrep_on`）+ 身份哈希自动失效（`cir_cache.cr:142-168` / `:500-502`）；
- 结构性零影响面：`src/` + `examples/` 泛型声明 0（第 10 节/测量2），因此自举链不产生实例；
- 实测条目数（改后，逐档 clean-cache）：非泛型语料（ptr_arith）15 条 / 实例名（含 `[`）0 条；含泛型语料 0 条。
- 因此无重新生效通道，故不换代（检查与约定照第 3.3 节；与 `canary_values.tsv` 的实现方式同步更新是两回事）。
### 11.5 XMM=0 零覆盖（硬编码）
全语料 104 档（parity 75 + probes 29）实例枚举 = 8 实例 / 3 档，dex 族类型实参实例 = 0
因此表示面缺陷在现有语料零覆盖；本次 ABI 面载荷全部由 `test_generic_param_erasure.py` 的新探针承担。
语料通过 不等于 表示面已验，后续任何阶段不得以「语料全部通过」推断本面已覆盖。
### 11.6 回归结果（验于 develop `f57815ec` + 本链；对比两侧各自 clean-cache）
| 检查 | 读数 |
|---|---|
| CI `check` / `bootstrap-tests` / `selfhost-tests` / `suite` | rc=0 / 0 / 0 / 0（suite = ALL PASS） |
| CI `full-bootstrap` | 见报告（corec2 == corec3 判定） |
| canary（`canary_check.sh`，同步更新后） | 5/5 PASS |
| `probes_run.sh`（29 档 + 有缓存状态检查项） | FAIL=0（有缓存状态真命中 15 档） |
| 新套件 | C1–C7 ALL PASS |
### 11.7 遗留 / 未覆盖面（本次不修，各自登记）
- 返回面擦除（本次新发现，兄弟面）：`fn gid[T](x: T) -> T` 的实例返回槽型仍是声明的擦除码
  （`fi_return_type` 逐位拷贝，`monomorph.cr:850`），因此实测 bits 源 rc=55、scaled 源 rc=56（两源皆错）。
  属同一根因族的另一字段（本次范围 = 形参链），因此登记 TODO（编号见提交），不夹带。
- 泛型结构体实例（`Box[T]`，语料 7 档）· 复合形参（`[T;N]`/`&T`/元组），裁 3 不入阶段；
- 模块限定形（`ml.g(…)`），第 10 节已登记不覆盖；`fi_param_type`（无读取点），裁 4 不碰。
---
