# R2 P1 Task 2 报告：影子判定挂点和 CLI 通道

状态：完成。两态产物逐字节不变；调用点和站点一一对应；36/36 回归套件通过；自举三个二进制重建通过。

---

## 1. 8 个站点 id 和语义对照（实读，含骨架标签勘误）

id 按计划/brief 给出的行号升序赋值，原行号为 711/947/959/973/1212/1405/1796/2127。实施后行号平移，下表给出实施后行号和实读语义。挂点形式是在调用前紧邻一行 `sh_site_begin(id)`，grep 为 `:727/964/977/992/1232/1426/1818/2151`。8 个外部调用点和 8 条标注逐一对应。`grep -n "type_equal(" src/compiler/checker.cr` 得到 1 处定义加 8 处外部调用，无遗漏、无重复。

| id | 实施行 | 原行 | 所在函数 | 实读语义 | 计划骨架标签 |
|---|---|---|---|---|---|
| 1 | 728 | 711 | `collect_decls` | hotpatch 返回类型一致，`rt_ti` 对 `first_rt_ti` | hotpatch 返回，正确 |
| 2 | 965 | 947 | `unify_types` | 泛型实参已绑定路径，`g_gen_map` 命中，已绑型对新具体型 | 泛型实参，正确 |
| 3 | 978 | 959 | `unify_types` | 泛型应用基型比较，`TYP_GENERIC_APPLY` 头部，两侧 `get_type_data` | “match 模式”，错误 |
| 4 | 993 | 973 | `unify_types` | 后备结构等价，非泛型或未匹配路径 | “泛型匹配”，部分正确，实际就是后备 |
| 5 | 1233 | 1212 | `check_func` | 函数体返回类型，`body_ti` 对 `ret_ti` | 函数体返回，正确 |
| 6 | 1427 | 1405 | `infer_expr` | 赋值兼容，`EXPR_BINARY` 加 `OP_ASSIGN`，遗留路径 | 赋值兼容，正确 |
| 7 | 1819 | 1796 | `infer_expr` | if 分支类型合并，`EXPR_IF` | if 分支合并，正确 |
| 8 | 2152 | 2127 | `infer_expr` | 赋值兼容，`EXPR_ASSIGN` 节点 | “索引/其它”，错误 |

勘误，重要：

- 骨架的“3 等于 match 模式”不成立。8 个外部点没有一个在 match 检查路径上，match 模式匹配不经过 `type_equal`。`:959` 实际是 `unify_types` 的泛型应用基型比较。
- 骨架的“8 等于索引”不成立。`:2127` 落在 `infer_expr` 的 `EXPR_ASSIGN` 分支。索引分支 `:2089/2092/2107` 直接返回元素类型，不调用 `type_equal`。
- “内部 8 处递归调用”实测为 6 处，原行为 111/126/132/135/138/150，已一并改名为 `type_equal_core`，见 §8 偏差 D1。

可达性运行时实证，探针为 `/tmp/shadow_probe*.cr`，都不是仓库文件。方法是用“N 不进入身份”这一确定差异源，该差异来自 R1 裁决，让差异条目落进 dump，再从 dump 的 site 列直接读出挂点。

| 探针 | 触发形式 | dump 实测行 |
|---|---|---|
| probe1 | `fn ret4() -> [int;3] { b:[int;4]; return b; }` | `fn-body-ret 5 13 14 0 old_stricter 1` |
| probe1 | `if c { ... }` 语句形式 | 未触发站点 7，见下 |
| probe1 | `a : [int;3], mut; a = b;`，b 为 `[int;4]` | `assign-node 8 21 23 0 old_stricter 1` |
| probe2 | `x := if c { a } else { b };`，表达式位 if | `if-branch 7 16 18 0 old_stricter 1` |
| probe3 | `pair<T>(x:T,y:T)` 以 `pair(a,b)` 调用，T 先绑 `[int;3]` | `generic-arg 2 19 21 0 old_stricter 1` |
| probe4 | `usef<T>(x: Box<T>)` 以 `Bag<int>` 调用 | `generic-apply-base 3 9 10 0 unknown 0` |

- 站点 5/7/8/2/3 已实测触发并归因正确，dump 的 site 列等于预期站点。
- 站点 6 当前不可达。`parser.cr:222-224` 把 `=` 一律降为 `EXPR_ASSIGN`，`EXPR_BINARY + OP_ASSIGN` 只剩 `ir_gen.cr:829` 自注的“遗留路径”。挂点保留，brief 强制 8 个站点，但不产生样本。
- 站点 4 可达，但难以产生差异。其 pattern 侧来自 `res_call_type`，而该函数没有 `EXPR_ARRAY`/tuple 分支，实测返回 `TI_UNIT`（`checker.cr:898-950`）。因此“N 不进入身份”这一主要差异源在站点 4 被压成 `TI_UNIT` 对 `TYP_ARRAY`，两侧都判不等，结果为 agree。站点 1 的 hotpatch 需要声明组，本轮未造样本。
- 站点 3 的 `unknown` 是设计预期。两侧基型是 `TYP_NAMED`，桥接为 `AK_NAMED`，引擎不展开，三态为 -1，正是 P1 要暴露的未覆盖面。`AK_NAMED` 原子在 P0 自测中已有“命名原子未知”条目。

---

## 2. 两态零变化判据（原始输出）

```
$ nice -n 19 ./build/corec clean-cache
cleaned .core/cache/cir/
$ nice -n 19 ./build/corec build tests/suite/ptr_arith.cr --static -o /tmp/p1_off
 -> /tmp/p1_off
$ nice -n 19 ./build/corec clean-cache          # 额外：ON 态也做 clean-cache 独立建
cleaned .core/cache/cir/
$ nice -n 19 ./build/corec build tests/suite/ptr_arith.cr --static --type-shadow -o /tmp/p1_on
 -> /tmp/p1_on
$ cmp /tmp/r1t4_base_bin /tmp/p1_off && echo OFF-IDENTICAL
OFF-IDENTICAL
$ cmp /tmp/r1t4_base_bin /tmp/p1_on && echo ON-IDENTICAL
ON-IDENTICAL
$ sha256sum /tmp/r1t4_base_bin /tmp/p1_off /tmp/p1_on
95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475  /tmp/r1t4_base_bin
95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475  /tmp/p1_off
95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475  /tmp/p1_on
```

- cwd 为仓库根；两态判据前都执行 `clean-cache`。ON 态额外独立建，排除 `.cir` 缓存复用削弱判据。
- 结论：OFF 等于 ON，也等于 R1T4 基线，三份 sha256 全等，值都是 `95084e7b…d475`。
- 开关关闭时零输出的旁证：`check tests/suite/ptr_arith.cr` 不带旗标，stdout 没有 `[type-shadow]` 行；只给 `--type-shadow-dump` 不给 `--type-shadow`，不建文件、零输出，影子关闭时连读取都不发生。

### 2b. 扩面复核（判据加强，不是 brief 要求）

brief 判据只用 `ptr_arith.cr` 单例。为排除小样例偶然和缓存复用掩盖，另跑两轮全量：

| 轮次 | 内容 | 结果 |
|---|---|---|
| A | `tests/suite/*.cr` 31 个程序，每个先 clean-cache，OFF 建一份，ON 再 clean-cache 建一份，逐字节 cmp | 27/27 可比且 IDENT；4 个 SKIP 是 2 个既有崩溃（rc=139，见下）加 2 个预期失败 fixture（`test_control_flow`/`test_generics`，rc=1，两态一致） |
| B | 同上 31 个，用 Task 2 之前的编译器（jj workspace @ `qsytsxzu` 独立构建）建 OFF 态产物，与新版 OFF 态逐字节 cmp | 27/27 可比且 SAME。“包装加改名”对本仓全部 suite 语料的编译行为零扰动，关态等价性不止 ptr_arith 一例 |

- 不报错地开关关闭时连编译行为都不变，说明“关态等于影子代码完全不入”这一设计成立，不只是“影子不开时结果恰好相同”。
- `at_test_mini4`/`at_test_mini6` 是 `@inline` fixture，两版编译器都 rc=139。基线 workspace 独立复现，说明是既有缺陷，不是本任务回归，记入关注点，本次未修。
- 语料规模参考，ON 态 decisions：最小 73（`ptr_ref_first`），最大 160（`conc_test`），`hotpatch_test` 136，命中站点 1 的声明组，`generics_test` 90，含 2 个 unknown。

---

## 3. 摘要行样本

```
$ nice -n 19 ./build/corec check src/compiler/checker.cr --type-shadow | tail -4
   | ^ Function return type mismatch
[5/5] frontend done
[type-shadow] decisions=4291 agree=4290 old_stricter=0 old_looser=0 unknown=1
$ nice -n 19 ./build/corec check src/compiler/checker.cr --type-shadow --type-shadow-dump /tmp/shadow_dump.txt | tail -2
[type-shadow] decisions=4291 agree=4290 old_stricter=0 old_looser=0 unknown=1
type-shadow dump: 1 entries -> /tmp/shadow_dump.txt
```

- 自语料，即 checker.cr 自身：4291 次判定，0 差异，1 个未知，来自站点 5 的 `TYP_NAMED` 对，见 §1。
- 其余语料样本：`run 'fn main()->int{return 42;}' --type-shadow` 得到 `decisions=73 agree=73 …`；probe1 得到 `decisions=76 agree=73 old_stricter=3`；probe3 得到 `decisions=77 agree=76 old_stricter=1`；probe4 得到 `decisions=77 agree=76 unknown=1`。
- 不变式 `agree+old_stricter+old_looser+unknown == total` 在以上全部样本成立。

---

## 4. dump 文件样本（文件头和前几条）

```
# R2 P1 type-shadow diff dump (first 256 entries; overflow = counts only)
# site	site_id	t1	t2	old_ok	kind	kind_id
fn-body-ret	5	13	14	0	old_stricter	1
fn-body-ret	5	18	19	0	old_stricter	1
assign-node	8	21	23	0	old_stricter	1
```

上为 probe1 的三条。`checker.cr` 自语料有 1 条，为 `fn-body-ret 5 29 26 1 unknown 0`；probe4 有 1 条，为 `generic-apply-base 3 9 10 0 unknown 0`。

列依次为 site 名、site id、t1、t2、old_ok、kind 名、kind_id。kind 中 0 是 unknown，1 是 old_stricter（旧拒新受），2 是 old_looser（旧受新拒，即收紧面）。满 256 条后只计数不覆盖，P1 要首批样本，不要滚动窗口。

---

## 5. `check` 和 `build` 的穿透结论

`check` 路径生效，不需要换 build 路径。开关在 `corec_main` 的 `cli_parse()` 之后、子命令分派之前统一解析，`main.cr:214` 执行 `g_shadow_on = cli_has("type-shadow")`。`run`、`check`、`cir`、`ccr`、`build` 五个子命令共用。`check` 实测输出摘要行，见 §3；`build --type-shadow` 实测产物不变，见 §2。摘要和转储收尾 `sh_finish()` 挂在 `run_frontend()` 返回处，文件路径在 `main.cr:400-402`，run 路径在 `:361-363`；诊断存在时也出摘要，代码为 `fe_rc := run_frontend(); sh_finish(); if fe_rc != 0 { return 1; }`。

---

## 6. 重建守卫行（`nice -n 19 python3 build_selfhost_native.py`）

```
[GUARD] corec: manifest OK (41 files)
  Tokens: 138115
  Type check passed
  Functions: 734
[GUARD] corec: build log clean (error[ = 0, undefined = 0)
  -> build/corec
[GUARD] corearch: manifest OK (31 files)
[GUARD] x86_64-linux target: manifest OK (3 files)
  Tokens: 119115 ; Type check passed ; Functions: 596
[GUARD] corearch: build log clean (error[ = 0, undefined = 0)
  -> build/corearch
[GUARD] corelsp: manifest OK (29 files)
  Tokens: 88952 ; Type check passed ; Functions: 566
[GUARD] corelsp: build log clean (error[ = 0, undefined = 0)
  -> build/corelsp
=== BUILD SUCCESS ===
```

- 三个二进制哈希：`corec f871ad50…c23e`、`corearch 1281335c…fd4f`、`corelsp 2544efb6…e219`。
- 本批新增的 checker 警告数为 0。构建日志中 `sh_*`/`ty_shadow`/`type_equal` 出现 0 次；既有 `cli_*`/`chan_*`/`sched_*` 等非致命警告与改动无关。
- 自测通道：`./build/corec selftest-types` 得到 67/67 passed，M1 改后 `bridge.*` 全部通过。
- 回归：36/36 套件通过，0 FAIL，包括 `tests/bootstrap/*.py` 7 个加 `tests/selfhost/*.py` 29 个。

---

## 7. 提交（路径限定，jj）

```
Change ID : ovrzqynlqsyrqmwzmvyolozxqwsuzvnw
Commit ID : 844cec6caf23df90bf47d517b59ff2d5204d8801   （最终；含注释修订后 squash）
             19b9d629c128c1f2971e9b42563df9d71f8f1820   （首版，注释修订前）
jj commit -m "feat: R2 P1 Task 2——影子判定挂点（type_equal 包装 + 8 站点）+ 分类计数 + CLI 通道（两态产物逐字节不变）" \
  build_selfhost_native.py src/compiler/checker.cr src/compiler/globals.cr src/compiler/main.cr src/compiler/ty_shadow.cr
```

提交内容恰好是 5 个文件：`build_selfhost_native.py` 11 增 11 减、`checker.cr` 44、`globals.cr` 11、`main.cr` 20、`ty_shadow.cr` 181。工作副本提交后为空。报告本体在 `.superpowers/`，.gitignore 第 33 行，不入库，与 Task 1 同例。

注释修订 squash 进同一 change：`ty_shadow.cr` 头注站点表的行号改为双列，即实施后行号和计划期行号，并在站点 6 注明“parser 已无生产点，属于遗留路径，无样本”。修订后重建三个二进制，sha256 与修订前逐一相同，`corec f871ad50…`、`corearch 1281335c…`、`corelsp 2544efb6…`，证明是纯注释改动、零 codegen 影响。判据和自测已在最终状态重跑：OFF-IDENTICAL、ON-IDENTICAL（§2），67/67 type-engine cases passed。

---

## 8. 偏差清单（相对 brief/plan 骨架，逐条理由）

| 序号 | 骨架 | 实施 | 理由 |
|---|---|---|---|
| D1 | “内部 8 处递归调用一并改名” | 6 处，111/126/132/135/138/150 | 实读计数。`grep type_equal(` 全仓为定义 1、外部 8、内部 6 |
| D2 | `sh_record(flag,…)`：unknown 为 0，差异为 1 | kind 为 0/1/2，2 是 old_looser | 槽位字段骨架自称 `kind`。多存一个方向，即收紧面或放松面，才有归档价值，0/1 语义与骨架一致 |
| D3 | `sh_dump_write(path_ni: int)` | `sh_dump_write(path: string)` | 本文件路径实参来自 `cli_get()`，是 `string`。本仓 dump 面，例如 `save_ccr(out)`，一律使用 `string` 形参 |
| D4 | `if e == -1 { unknown }` | `if e < 0 { unknown }` | 三态语义是任何负值都未判定。写死 -1 会把引擎其他负数出口不报错地漏进分类，P0 已为 `tt_witness` 引入 -2 先例 |
| D5 | 站点 3/8 标签、内部 8 处 | 见 §1 表 | 实读勘误 |
| D6 | 只改 4 个 .cr 文件 | 另改 `build_selfhost_native.py`，corelsp 清单加 3 个文件 | 不修则构建失败。corelsp 清单包含 checker.cr 但不含影子层，Task 2 起 checker 引用 `sh_compare/sh_site_begin`，报 `Undefined name` 9 次，构建中止，首次重建已实证；corearch 没有 checker，仍不含引擎 |
| D7 | `sh_report()`：摘要行 | 增加关态提前 return，零输出 | 保证关态 stdout 也零变化，是两态判据 stdout 侧的对偶 |

---

## 9. M1 和 M4 实施

- M1：`sh_native_ak` 改为读表本体判定，代码为 `if get_type_kind(ti) != TYP_BASE { return -1; }  return sh_base_ak(get_type_data(ti));`。“init_types 行号序恰与 TI_* 码序一致”的隐式等价被消除，表布局变化不再不报错地错标。行为等价性核对：TI_DYN(7) 走 TYP_DYN 分支不变；TY_DEX_S 占位行(8) 由通用路径改走原生路径，产出项逐字段相同，都是 `tt_atom(AK_DEX, ti, -1)`，差异只在是否占缓存条目。`bridge.*` 用例，包括 `bridge.entries_delta`/`bridge.hit_delta`/`bridge.grow_rehash`，实测全部通过。
- M4：`ty_shadow.cr` 文件头注新增醒目段。`AK_*` 和 `TI_*` 下标 2/3 互换，`AK_STRING=2` 对 `TI_BOOL=2`，`AK_BOOL=3` 对 `TI_STR=3`，必须按语义分派，禁止数值直传，并指明守门用例 `bridge.str_ak`/`bridge.bool_ak`。原位于 `sh_native_ak` 上方的重复长注收敛为指向头注的短注。

## 9b. Task 1 评审补强实施（M2/M3；M1 已在 §9）

评审三点，即 row 7 陷阱、M2 ptr class、M3 native 路径覆盖，处理如下：

- row 7 陷阱已经天然规避，现在被用例钉死。M1 实现是 kind 先行，`if get_type_kind(ti) != TYP_BASE { return -1; }`（`ty_shadow.cr:51`）。因此 `TI_DYN`（row 7，kind 为 `TYP_DYN`，data 为 0，等于 `TY_INT`）根本进不了 native 路径，随后由 `sh_term_of_ti` 的 `TYP_DYN` 分支译成 `AK_DYN`。`bridge.dyn_ak` 是因为 kind 分支而通过，不是巧合。为防止后人改回“先比 data 再判 kind”，新增两条断言钉死陷阱：`sh_native_ak(TI_DYN) == -1`，且 `tt_a(sh_term_of_ti(TI_DYN)) == AK_DYN`。
- M2：新增 `bridge.ptr_ak`，断言 `tt_a(t_ptr) == AK_PTR`，与既有 `bridge.ptr_inner` 只断参数链并列。整支误译成 `AK_SEQUENCE` 或 `AK_REF` 不再可能全部通过。
- M3：native 分派在 M1 后成为主路径，此前零用例，现在全表覆盖。`bridge.native_row_table` 对行 0..7 逐行对照 data 语义到 AK，包含 bool 和 str 不互换，不抽样；`bridge.native_dyn_kind_branch` 是 row 7 双保险；`bridge.native_dex_s` 验证 row 8 占位行在 M1 后走 native 路径，两侧同为 `AK_DEX`。

负控实证，守门用例具备判别力，不是恒绿。在 `/tmp` 的仓库副本，未触碰仓库文件，把 `sh_native_ak` 改成 data-first 版本并重建，得到 57/71，14 例失败。其中恰好包含评审预告的 `bridge.dyn_ak: got 0 want 7`，0 是 `AK_INT`，即 dyn 被不报错地译成 int 的实锤，还包含新增的 `native_dyn_kind_branch` 和 `native_row_table`。

补强提交独立于 Task 2 主体，因为主体已被上位计划提交引用，不做 history 重写：

```
Change ID : qqzwtqzq
Commit ID : 514956a1
test: R2 P1 Task 2 评审补强——M2 ptr class 断言 + M3 native 分派全表覆盖（row 7 dyn 陷阱守门）
  （仅 src/compiler/type_selftest.cr）
```

补强后复跑：`selftest-types` 71/71，原 67 加 4 个新例；`test_type_engine.py` 通过；OFF-IDENTICAL、ON-IDENTICAL；`tests/suite` 31 个程序两态扫 27/27 IDENT，4 个 SKIP 同 §2b。二进制哈希：`corec 77d20bb2…c420`，含测试增量；`corearch 1281335c…fd4f` 和 `corelsp 2544efb6…e219` 都与补强前相同，两个清单不含 `type_selftest.cr`，零 codegen 影响。

---

## 10. 关注点和遗留（供 Task 3 和评审）

1. 站点 6 不可达。parser 已无 `EXPR_BINARY+OP_ASSIGN` 生产点，挂点保留但永远不进样本。如果 Task 3 需要 8 个站点全样本，需要先裁决该遗留路径的去留，属于另一任务面。
2. 站点 4 的差异面被 `res_call_type` 压平。该函数没有 `EXPR_ARRAY`/tuple 分支，恒为 `TI_UNIT` 侧。P1 阶段站点 4 大概率恒 agree，不代表引擎或旧判定在数组面收敛。
3. unknown 桶未细分。“任一侧无法翻译”和“引擎三态 -1”都记 kind=0。自语料 1 例、probe4 1 例都属于后者，即 `AK_NAMED` 未展开。如果 Task 3 归档需要区分，可以在 kind 上加子类。
4. 未做性能判定。影子关闭时每站一次全局读 `g_shadow_on` 加一次全局写 `g_shadow_site`；开启时每次判定一次桥接查询加规范化/判定。本轮只证明产物零影响，未测吞吐回归。
5. `--type-shadow` 未接入 corearch/corelsp。影子层只作用于 corec 前端；corelsp 仅因 checker 引用而被动链接，LSP 进程内 `g_shadow_on` 恒为 0。
