# (A) 批 T1 报告：前置侦查 + 冻结基线重建 + 起点判据 + 四形态 RED + 取址面完备性勘察

日期：2026-09-16 · 起点：`230e5a1c`（develop，含本批计划）· 工作地 `/tmp/p7wt`（`@` = `6b1f5045` 空）
证据 `/tmp/capt6/` · 状态件 `/tmp/capt6/state.md` · 纪律：`nice -n 19` + 每段 `ps` · `clean-cache` · 崩溃态 `ulimit -c 0` · 主树零写入 · 源码零改动
取裁：REP-1 = (iii) 逃逸域化恒装箱 · REP-2 登记（指针算术边界）· REP-3 维持登记（`&s.a`）· REP-4 接受（取址预扫）

---

## 1. 冻结基线（Step 1）与起点二进制

```
$ nice -n 19 bash tools/baseline/rebuild.sh /tmp/capt6/base     # 23.3s
  OK corec ae01de75…  OK corearch 228f82e9…  OK corelsp 90eb19c6…   # = 白名单（现行代 97f4394f）
  OK smoke rc=42      DONE …（源修订 97f4394f）
$ nice -n 19 python3 build_selfhost_native.py    # 当前树（×2，日志尾部逐字节同）
  corec 129d55a6… · corearch 22e96d03… · corelsp f4514365…
```
因此 冻结基线可复现（三 sha 逐条 = 允许清单 + 冒烟 42）；当前树重建确定性 ×2 通过。

## 2. 起点判据（Step 2；全套重测，未沿用容量批值）

| 判据 | 实测 | 与 lead 参照值 |
|---|---|---|
| 五 CI job | check / bootstrap-tests / suite / selfhost-tests / full-bootstrap 全 rc=0 | 同 |
| 全枚举 | 61/61（51 selfhost + 7 bootstrap + 新增套件） | 同（61） |
| `selftest-types` | 415/415 | 同 |
| `check src/compiler` | rc=0 | 同 |
| ELF canary（硬检查） | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`（28822B）IDENTICAL | 同 |
| `.ccr` 两口径四条（冷+暖） | 96015 `680a6f98…` / 96158 `76f36e6a…` / 142793 `41e9d845…` / 142936 `704316c8…` | 同 |
| `--dump-objects` | 3521 行 ×2 口径 | 同 |
| `.cir` DOT | 165915B `b1bdf480…` | 同 |
| 自举链 | `corec2==corec3` `006e58e1…` + N06=0 + 冒烟 42 + `--help` rc=1 | 链 sha 为本树新值（比 P6 代更新） |
| 72 档同源对拍（腿①：`/tmp/capt6/base/corec` × 当前源 vs 当前二进制 × 当前源） | rc 分布两侧 34×0/38×1；`diff -rq logs` 零差异 通过 | 同 |
| 探针 29 档 | 两侧 17×0/12×1；逐档 diff 仅 1 档差异：`n05_recursive.cr.log` 多一行 `[5/5] frontend done`（进度横幅；rc 同），冻结基线（P6 终态）到 本树之间后续批次引入的横幅，与 (A) 无关（登记） | 记录差异并归因 |
| 暖态腿（runner 新挂） | parity_frozen 暖生效 64/72 · parity_post 40/72 · probes_frozen 23/29；FAIL=0 |，|

## 3. 四形态 RED + 三子形态（Step 3；本树实测，逐条 = check / build / ELF / interp）

| # | 形态（实现方式） | check | build | ELF | interp | 判定 |
|---|---|---|---|---|---|---|
| ① | 局部：`x : int? = Some(5); p := &x; *p = 7`（位=1 写裸） | 1（B04 软） | 0 | 139 | 139 | 响亮（= `c2`） |
| ①b | 同槽写装箱 `*p = Some(7)` | 1 | 0 | 7 | 7 | 正确（位=1 与装箱值自洽） |
| ② | 数组元素：`p := &a[0]; *p = 7` | 0 | 0 | 139 | 139 | 响亮 |
| ②b | 写装箱 `*p = Some(7)` | 0 | 0 | 7 | 7 | 正确 |
| ③ | 全局：`p := &g; *p = 5` | 1 | 0 | 0 | 139 | 双路径分歧（T2 记录同） |
| ③b | 全局写装箱 `*p = Some(5)` | 1 | 0 | 0 | 5 | 新证据：不报错地分歧（ELF 错值 0 / interp 正确 5），T2 未测该形态 |
| ④ | 结构体字段：`p := &s.a; *p = 5`（裸） | 0 | 0 | 0 | 0 | 写入丢失（两路径同 0 = 字段未被写；`&s.a` 取临时量地址 因此 REP-3 登记） |
| ④b | 字段写装箱 `*p = Some(5)` | 0 | 0 | 0 | 0 | 同（写入丢失，与表示无关） |
| c1 | `x : int? = 5`（位=0）到 `*p = 7` | 1 | 0 | 7 | 7 | 正确但脆弱（位与值恰好同态） |
| c2 | `x : int? = Some(5)`（位=1）到 `*p = 7` | 1 | 0 | 139 | 139 | 响亮（与 ① 同） |
| c3 | `x : int? = 5`（位=0）到 `*p = Some(9)` | 1 | 0 | 8 | 96 | 双路径分歧的不报错地错值（根因条目） |

变化登记（与 T2 记录比）：① `c3` 的 interp 值 = 96（T2 记 216），分歧类不变（两边各自错值），具体数值随分配/布局状态而变；② ③b 为本轮新增形态（全局 + 装箱写 因此 不报错地分歧），T2 只测了裸写；③ 四形态其余逐条与 T2 记录一致（①/② 139 · ③ ELF 0/interp 139 · ④ 写入丢失）。
因此 四形态 + 三子形态全部复现；无「与记录不符且无法归因」项（计划停条件②未触发）。

## 4. 取址面完备性勘察（Step 4；(iii) 的全部论证押在此）

### 4.1 能产生指针的构造（全仓枚举 + 逐条分类）

| # | 构造 | IR 发射点（实读） | 目标可否在 IR-gen 期分类 | 归属 |
|---|---|---|---|---|
| 1 | `&ident`（局部 / 形参 / 全局） | `ir_gen.cr:1410` `IR_REF`（operand 为 EXPR_IDENT 因此 `gen_expr` 直返槽 var） | 可（operand 节点 kind + `find_local`/`find_global` 均在 IR-gen 可用） | 本律主面（局部/形参 因此 预扫标记；全局 因此 E-2 已恒装箱） |
| 2 | `&arr[i]`（数组 / 切片元素） | `ir_gen.cr:1404` `IR_ADDR_INDEX`（真元素地址） | 可（聚合面；元素恒装箱 = E-2 律） | E-2 面（已闭合） |
| 3 | `&<其它表达式>`（字段 / 临时 / 调用结果） | 同 #1 路径，但 operand 非 ident 因此 `gen_expr` 先 LOAD 因此 取临时量地址 | 可分类为「非槽地址」 | 不适用本律（`&s.a` 即此形 = 写入丢失，REP-3 登记；本批不动） |
| 4 | 指针算术（`p ± n`） | `ir_gen.cr:1208` `OP_PTR_ADD/SUB/DIFF` | 不可分类（地址由运行期算术派生，可指向任意相邻槽） | REP-2 边界（已裁：登记 + 探针；本律不覆盖） |
| 5 | `@addr(fn)` / 函数地址 | `ir_gen.cr:1462`/`:1690` `IR_FNADDR` | 不适用（函数地址，非槽） | 出界 |
| 6 | 切片视图（`IR_SLICE`） | `ir_gen.cr:2469` | 可（经切片的下标写仍走元素路径；T2 已覆盖 `TYP_SLICE` 元素类型） | E-2 面（已闭合） |
| 7 | extern/FFI 写（被调方经指针写回） | `IR_CALL_EXTERN`（`callseq` 面） | 不可分类（外部代码行为不可见） | 登记（须实证是否有「可选 pointee 传 extern」形态；语料零命中） |

结论：直接取址面 100% 可在 IR-gen 期分类（#1/#2/#3/#6）；不可分类者仅两类且均为已裁边界或登记面：#4（指针算术派生，REP-2）与 #7（extern）。因此 (iii) 的闭包论证成立（在既有取裁边界内），计划停条件③未触发。

### 4.2 自源 / 语料同现清点（计划未清点项，本任务补）

| 面 | 取址（`&x` 真形态） | 可选类型 | 同现 |
|---|---|---|---|
| `src/compiler/` + `src/stdlib/`（自源） | 0（全仓 `&` 用例仅：注释 · 类型位 `&T`/`&mut T` · 闭包串字面量 `"&mut "`（`monomorph.cr:211`）） | 9 档含可选语法/注释（ty_shadow/ast/parser/ir_gen/monomorph/type_selftest/type_engine/checker/globals） | 0 |
| `tests/suite/`（canary 族） | 有（`ptr_arith.cr:10` `&x`（int）· `ptr_ref_first.cr:8-9` `&x` + `p+1`） | 0（复核空） | 0 |
| `tests/selfhost/`（CI 套件内联源） | 有（12 档含 `&`，如 `test_ccr_types.py:1434` `p := &arr[1]` · borrow/impl/xcut 族） | 严格式（`int?`/`]?` 等）0 命中 | 0 |

因此 自源「可选 + 取址」同现档数 = 0（自源根本无真取址）因此 本批对自举链/自源编译的发射面影响预期为 0（预扫标记在自源上永不触发）；语料与套件同样零同现 因此 canary/`.ccr`/72 档/探针/CI 的「零变化」预期有语料面证据支撑（仍须实施时实测）。

### 4.3 既有先例（可复用的地址分类面）
`src/compiler/ptr_analysis.cr` 已有指针来源分类面（`:200-215` 区逐 opcode 分派 `IR_ALLOC_STRUCT/ARRAY`·`IR_REF`·`IR_ADDR_INDEX`·`IR_SLICE` 的 pts/provenance）因此 (iii) 的取址预扫可参照其枚举面（同一 IR 写/取址全集），并作为「分类完备性」的交叉核对面（T3 Step 5 审计时用）。

## 5. 结论与放行
- 四形态 + 三子形态复现 且与记录一致（变化仅 c3 数值 + ③b 新形态，均已归因/登记）。
- 取址面 100% 可分类（直接取址面）因此 (iii) 可行，无需转 (iv)/(i)。
- 自源/语料/套件「可选 + 取址」同现 = 0 因此 零影响预期有语料证据。
- 计划停条件 ①②③ 均未触发。

## 6. 诚实项
1. `c3` 的 interp 值随状态变化（T2=216 / 本树=96），分歧类是稳定判据，具体数值不是（判据设计时须用「双方是否与正确值一致」而非固定数）。
2. ③b（全局 + 装箱写）为本轮新增形态：ELF 0 / interp 5 因此 不报错地分歧；T2 未测，属本批新证据（(iii) 后应转正确）。
3. extern 面（4.1 #7）未做实证（是否有「可选 pointee 传 extern」形态），语料零命中，须 T3 时补探针。
4. 探针 leg 的 1 档差异（`n05_recursive` 横幅）为后续批次引入，非本批面；已归因。
5. 本任务零源码改动（纯测量）：`jj status` 收工应干净，报告与状态件落 `/tmp/capt6/`（仓库外），计划文件的 T1 记录回填另计（见提交）。

## 7. 证据路径
`/tmp/capt6/{base/,build1.log,build2.log,t1crit.out,ci_*.log,enum_list.txt,parity_frozen/,parity_post/,probes_frozen/,probes_post/,probes/,probes_out/,state.md}`
