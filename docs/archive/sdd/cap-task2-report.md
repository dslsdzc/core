# 容量批 T2 报告：E-2 表示面聚合扩展（裁-CAP-1 (a) 存储边界规范化）

日期：2026-09-15 · 任务：`docs/superpowers/plans/2026-09-15-capacity-batch.md` 的 Task 2
起点：`7f53305d`（TC02 实施） · 工作目录：`/tmp/p7wt` · 证据：`/tmp/capt2/` 下的文件
纪律：`nice -n 19` · 每段用 `ps` 实查 · 崩溃态 `ulimit -c 0` · 主树零写入 · 未 commit/restore/新建 workspace · 突变在仓库外沙箱
取裁：裁-CAP-1 选择 (a) 存储边界规范化（写点装箱、零布局变更、纯 IR、canary 无豁免）；match 面采用裁决 (i) 表示位案；#9 指针面采用裁 (A) 登记不修（`:1192` 一行未动）；B 类可达，升为 A 类改造。

---

## 1. 起点基线（TC02 后重测，未沿用 T1 值）

| 项 | 实测 | 与 T1（P6 终态）比较 |
|---|---|---|
| 构建 | corec `269d0a47…` · corearch `228f82e9…`（不变，清单不含 checker.cr）· corelsp `956cb82c…` | corec/corelsp 变化（TC02 改了 checker.cr） |
| 五 CI job | 全部 rc=0 | 相同 |
| canary | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`（28822B） | 相同 |
| `.ccr` 四条（冷/暖） | 96015 `680a6f98…` / 96158 `76f36e6a…` / 142793 `41e9d845…` / 142936 `704316c8…` | 相同（差恒为 143B） |
| 自举链 | `corec2==corec3` `c8c63985…` + N06=0 + 冒烟 42 + `--help` rc=1 | 变化（TC02 后的新值） |
| `selftest-types` | 415/415 | 相同 |
| 全枚举 | 59/59（TC02 增加 `test_tc02_branch.py`） | 多 1 档 |
| 72 档对拍 / 探针 29 | 34×0/38×1 · 17×0/12×1；与 T1 侧 `diff` 只有 2 档行号 +28 位移、内容零变（TC02 影响归因） | 语义零变 |

## 2. Step 2：B 类三点的 RED 实证（实测；`/tmp/capt2/probes_out/`）

| 点 | 实现方式 | check | build | ELF | interp | 结论 |
|---|---|---|---|---|---|---|
| #10 枚举载荷 | `enum E { V(int?) }` + `V(5)` | 0 | 0 | 139 | 139 | 可达，升为 A 类（已改） |
| #11 元组元素 | `x : int? = 5; t := (x,3); match t . 0 {…}` | 0 | 0 | 139 | 139 | 可达，升为 A 类（已改）；装箱形态为 5。语法注：`t . 0`（带空格）是必要的，`t.0` 会在 lexer 层报 `invalid integer literal`（数字字面量扫描吞掉 `.0`），已登记 |
| #9 指针写 | 局部、数组元素、全局、结构体字段四种形态 | — | — | 见第 7 节五形态表 | | 裁 (A) 登记不修（同站点双语义，别名不可静态闭合） |

## 3. Step 3：实现（`src/compiler/globals.cr` +5 · `src/compiler/ir_gen.cr` +230）

新增单源件：`g_ir_var_decl_ti/_cap`（声明类型侧表，进程内，零布局）· `grow_ir_var_decl`/`irv_decl_ti`/`irv_set_decl_ti` · `ti_is_optional` · `slot_decl_ti` · `elem_ti_of_decl`/`elem_ti_of` · `field_ti_of_node`（结构体名字取自 checker 写入的 `ast_c`）· `struct_row_field_ti` · `global_decl_ti` · `enum_payload_ti`（`find_gsym`，再到 `sym_type`、`find_enum_row_of`、名字匹配，最后到载荷类型节点）· `elem_node_optional`（ident/调用保守判定）· `emit_box_some`（`IR_MAKE_ENUM` + `IR_STORE_FIELD`，没有新 opcode）· `box_for_slot_flag`/`box_for_optional_slot`（三态：静态裸值就直接装箱；源槽带表示位就做运行期条件装箱；已装箱或不可选就原样零 IR）。`optrep_begin` 复位声明表。

接线（A 类 8 点加 B 类 2 点）：字段赋值、结构体字面量、数组元素赋值（字面量下标、动态下标、全局数组声明面回退）、数组字面量（wrapper 解引用后判定）、全局赋值、全局初值、match 臂（裁决 (i)：`result_var` 配表示位，各臂 `emit_rep_set`）、枚举载荷、元组元素、LET/形参声明类型登记。全部由既有的零影响门 `g_optrep_on` 门控。

global 面双根因（预存，本批修）：① 读点常量折叠：`gen_expr` 的 EXPR_IDENT 分支 `find_global_const_node` 把 `g : int? = 5` 的读折成裸常量，match 的 tag 读会解引用裸值（实测 139，IR dump 实证：`CONST 5` 对应 `LOAD_ENUM_TAG` 的源是该临时量，不是全局槽）；② 写点静态度量初值：`global_needs_runtime_init` 对字面量初值返回 0，值经 `.quad` 静态写入（裸值）。两处都只对可选全局抑制或改道。

零影响事故和修复（本任务自查抓到）：首版实现（未门控）使非可选语料 `generics_test.cr` 的 `.ccr` 增加 168B（全在 TYPE 段，STR 零变），根因是我的辅助函数无条件调用 `res_type_node`（对数组或命名类型节点每次都分配新类型行）。修复方法是 12 处全部加 `g_optrep_on != 0` 门（含 `global_needs_runtime_init` 的新判据和常量折叠抑制）。修复后 `gt.ccr` 逐字节回到 `41e9d845…`（142793B）。登记为过程教训：新增类型面查询前必须核实「该调用是否会 alloc」。

## 4. Step 4：用例（`tests/selfhost/test_optional.py` 从 34 增加到 48 例，全部通过）

- 原未覆盖面 4 例重新固定（旧行为失效是本批能力变更的证据）：`uncovered_field_bare_is_loud`（-11）改为 `uncovered_field_bare_now_ok`（5）；其余三例保持（装箱/None 形态）。
- 新增 14 例（`case_dual` 三路同证：check rc=0，ELF rc=N，interp rc=N，断言精确值）：字段赋值 5、字段字面量 6、字段 None 3、跨函数字段 14、数组字面量下标 7、动态下标 8、数组字面量 ident 元素 5、数组装箱 4、全局赋值 9、全局初值 10、match 结果条件写 11、枚举载荷 12、元组元素 13、负控非可选字段 16。
- 实测：`48/48 passed`（CI 的 `selfhost-tests` 内也是 48/48）。

## 5. `str_intern`/STR 段影响（实测，不是推断）

方法：用 `/tmp/capt2/pret2/build/corec`（从 `7f53305d` 原样重建的 pre-T2 编译器）和当前编译器编译同一组可选程序，逐段比较 `.ccr` 并列出 STR 差集。

| 程序 | 总 Δ | 段级 | STR 增 | STR 删 |
|---|---|---|---|---|
| `m7_global_init`（`g : int? = 10`） | +351 | STR +15 · SYM +16 · NOD +160 · ENT +56 · EDG +8 · TYPE +96 | `box` · `match_res_rep` | `const`（折叠抑制，该 IR 变量名不再驻留） |
| `m2_field_literal`（`S { a: 6 }`） | +264 | STR +24 · SYM +16 · NOD +120 · ENT +56 · EDG +24 · TYPE +24 | `box` · `match_res_rep` | 无 |
| `m3_arr_assign_lit` | +240 | STR +24 · … | 同上 | 无 |

字节账（与上表逐条一致）：`box`(3+4=7) + `match_res_rep`(13+4=17) = +24；m7 再减去 `const`(5+4=9)，得到 +15。结论：STR 增长只来自本批新增的两个 IR 变量名（`Some` 在含 `Some` 模式或构造的程序里本已驻留，因此「新增 Some 字符串」的原推断不成立，以实测为准）；只影响可选程序，非可选程序的 STR 零变（`generics_test` 的 STR 差集为空）。

## 6. Step 5：判据全套（全部通过；`/tmp/capt2/t2g.out`）

| 判据 | 实测 |
|---|---|
| ELF canary（硬检查，无豁免） | `95084e7b…d475`（28822B）IDENTICAL |
| `.ccr` 两口径四条（冷和暖） | 96015 `680a6f98…` / 96158 `76f36e6a…` / 142793 `41e9d845…` / 142936 `704316c8…`，逐字节同起点（冷等于暖；非可选程序零影响） |
| `--dump-objects` | 3521 行×2 口径，与 P5T5 件 IDENTICAL |
| `.cir` DOT | 165915B `b1bdf480…`（不变） |
| 72 档同源对拍 | 34×0/38×1；`diff -rq` 只有 2 档（`_import.cr` / `ccr_io.cr`）行号 +231 位移、内容零变（等于本任务净增行数，已归因） |
| 探针 29 档 | 17×0/12×1；零差异 |
| 五 CI job | 全部 rc=0（含 `selfhost-tests` 48/48） |
| 全枚举 | 59/59 |
| `selftest-types` | 415/415 |
| `check src/compiler` | rc=0 |
| 自举链 | `corec2==corec3` `819af35c…` + N06=0 + 冒烟 42 + `--help` rc=1 |
| 构建确定性 | 多次构建逐字节同（含 CI 内重建） |

## 7. Step 5：突变控制（4 条，全部按设计变为失败；沙箱 `/tmp/capt2/mut/<M>/`）

| # | 改法 | 结果 | 判别价值 |
|---|---|---|---|
| M1 | 结构体字面量写点不装箱（保留赋值点） | `cap_field_bare_literal`（期望 6）变成 -11，`uncovered_field_bare_now_ok` 失败；46/48；赋值点用例保持通过 | 证明「字面量」和「赋值」是两个独立写点 |
| M3 | 全局初值点不装箱（保留赋值点） | `cap_global_bare_init`（期望 10）变成 -11；47/48；`cap_global_bare_assign` 通过 | 证明初值和赋值是两个独立代码点 |
| M4 | 双重装箱（已装箱值再装箱） | 4 例失败且全部为 rc=0 的错值（`got 24` / `8` / `8` / `24`），属于不报错地错误类，只因为用例断言精确值才被抓到 | 证明「只对裸值装箱」必要，并证明本用例矩阵能抓到不报错地错误类 |
| M8 | 去掉「目标可选」门控（`ti_is_optional` 恒真） | canary 变化：`ae24c9cd…` 不等于 `95084e7b…`（28822B 同尺寸） | 证明零影响门确实有效（canary 不是装饰） |

回滚：突变在仓库外的全树副本中进行（`pret2` 基底加两文件覆盖），主工作树源码零改动（`jj diff` 只含本任务 4 文件），因此无需回滚。

## 8. 登记（四项，按裁决要求逐条带证据）

### 8-1 指针写可选槽：五形态证据表（`/tmp/capt2/probes_out*/`；裁 (A) 登记不修）

| 形态 | 实现方式 | check | build | ELF | interp | 判定 |
|---|---|---|---|---|---|---|
| 局部可选槽 | `x : int? = None; p := &x; *p = 5;` | 1（B04 软） | 0 | 139 | 139 | 可达（局部为表示位面） |
| 数组元素 | `p := &a[0]; *p = 7;`（`IR_ADDR_INDEX` 给真元素地址） | 0 | 0 | 139 | 139 | 可达（聚合面） |
| 全局槽 | `p := &g; *p = 5;` | 1（B04 软） | 0 | 0 | 139 | 可达，双路径分歧（预存） |
| 结构体字段 | `p := &s.a; *p = 5;` | 0 | 0 | 0 | 0 | 不可达且写入丢失：`UOP_REF` 没有字段分支，`gen_expr` 先 LOAD 再取址，取到的是临时量地址（预存缺陷） |
| 聚合恒装箱路径（对照） | `s.a = 5` 等直接写点 | 0 | 0 | 正确值 | 正确值 | 本批已闭合 |

### 8-2 根因链

`ir_gen.cr:1192 IR_STORE_PTR` 同一站点同时服务局部和聚合槽（局部权威是表示位，聚合权威是本律），指针写绕过了 `emit_rep_set`（表示位只在直接写点置位）；并且「指针指向哪类存储」的别名无法静态闭合（`q := p` 拷贝就会漏判），所以无条件装箱会新增不报错地错值（实测 `c1`：位为 0 时 `*p = 7` 今天返回 7（正确），装箱后位仍为 0，解包读对象指针得到不报错地错值）。因此本批在结构上做不到（彻底闭合需要「表示位随存储走」，属于布局变更，与裁-CAP-1 (a) 互斥）。

### 8-3 高优先单列（非本批引入，本批不修）：`c3` 双路径分歧不报错地错值

`fn main() -> int { x : int? = 5; p := &x; *p = Some(9); return match x { Some(v) => v, None => 0 }; }`（`x` 的表示位为 0 裸值，经指针写入了装箱值），结果为 ELF rc=8 / interp rc=216，是双路径分歧的不报错地错值，而且今天就存在（pre-T2 编译器同值实测，不是本批引入，也不是未覆盖面）。建议独立 TODO 条目（与 8-1 指针面登记分开）：指针写与表示位/规范化互斥（三个子形态：`c1` 正确但脆弱，`c2` 139 直接报错，`c3` 不报错地分歧）。

### 8-4 待裁候选 (D)：语言面拒绝 `*p = v`（pointee 为 `T?`）

影响面（须实读确认，已读）：`UOP_REF`（`checker.cr:2522-2542`）对 `x : int?` 返回 `TYP_PTR[TYP_OPTIONAL]`，没有拒绝；拒绝点只能落在 `EXPR_ASSIGN` 的 `UOP_DEREF` 目标分支或 `UOP_REF` 本身。取舍草案：① 若在 UOP_REF 拒绝，会拒掉 `&x`/`&a[i]`/`&g` 全部取址形态（含今天正确的聚合路径 `*p = 5`；若 pointee 为 `T?`，目前 139/0/139 三形态，无一正确；对照：非可选 pointee 的指针写不受影响）；② 若在赋值位拒绝，范围相同；③ 本批不取：会新增 rc=1 门并拒掉今天可编译的代码，须独立裁定，且只做 report-only。注：8-1 表中「聚合恒装箱正确」指直接写点；指针路径下的聚合目前无一正确（139/0）。因此 (D) 的真实影响面是「拒绝今天已经错误的形态」，不是「拒绝正确代码」，与 lead 的措辞一致（须实读确认的那条已核实）。

### 8-5 其它未覆盖面（如实登记）

- 元组或数组字面量中的非 ident、非调用元素（如 `t := (g()->int?, 3)` 之外的内联形态），`elem_node_optional` 保守判 0（不装箱）；
- `struct S[T] { a: T }` 实例化为 `T = int?` 的字段（字段类型节点是泛型形参 ident，不判可选）；
- `&s.a` 写入丢失（8-1 第 4 行，预存缺陷）；
- 局部可选槽经指针写（表示位面，8-3 同族）。

## 9. 提交和差异面

`src/compiler/globals.cr`（+5）· `src/compiler/ir_gen.cr`（+230）· `tests/selfhost/test_optional.py`（+88/−13）· `src/ci/run.sh`（计数注）。未动：`:1192`（裁 (A)）、`.ccr`/`.cir` 格式、清单三面、任何后端。

## 10. 诚实项

- 突变 M1/M3/M4 在门控修复前的版本上跑（当时 4 例结果）；门控只影响非可选程序路径，突变靶全在可选程序，失败面不受影响（未重跑，登记该口径）。
- pre-T2 对照编译器从 `7f53305d` 重建（不是 TC02 原始二进制，但同源同树，逐字节等价由构建确定性保证）。
- T1 的「`Some` 新驻留」推断被实测推翻（`Some` 早已驻留；新增的是 `box`/`match_res_rep`），已按实测修正。
- 未跑 `COREC_WARM_SELF=1` 自源暖态 2 例（同 T1 豁免）；LSP 会话级未测。
