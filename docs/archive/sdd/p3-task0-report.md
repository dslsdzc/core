# R2 P3 Task 0 报告：引擎展开层（named/struct/enum/generic-apply 转结构项）

状态：DONE_WITH_CONCERNS。全部判据通过，登记 3 项：枚举 payload 表缺类型节点，是 Task 3/4 的前置缺口；witness 原始形态含空析取支，是 Task 3 判据前提；bootstrap 前端不短路 `&&`，是无符号通道的崩溃面。三项都是发现，不是本任务缺陷，见第 5 节。
提交：`61d3a8b4`（change `vwrqnvqo`，父提交 `73a8622d`）。路径限定 5 个文件：`src/compiler/ty_shadow.cr`、`checker.cr`、`type_engine.cr`、`globals.cr`、`type_selftest.cr`。新增 502 行，删除 0 行，纯新增，既有行一行未改、一行未删，这是“桥接与判定分支零改动”的机械证据。
计划：`docs/superpowers/plans/2026-09-11-r2-p3-capabilities.md` Task 0（P3a 前置，计划标为最大风险项）。
起点：`73a8622d`（P2b 阶段评审收口，工作副本干净）。基线二进制是起点树重建的 `build/corec 8f69e346…`，留档在 `/tmp/p3t0_base_bin/`。
计划勾选：本任务未修改计划文件的 Task 0 复选框。计划文件由 plan-p3/lead 侧维护，同期有其他 agent 在编辑，如需勾选请一并处理。

---

## 1. 交付物和落点（file:line，全部实测）

| 交付物 | 落点 |
|---|---|
| 展开层头注（语义边界：只服务满足判定和域查询；等价判定保持原子名义；一层深度；非纯只读如实登记） | `ty_shadow.cr:487-521` |
| 展开项布局约定（b 槽为标注；身份放入参数链；变体项不含 payload 及其理由） | `ty_shadow.cr:509-521` |
| 展开缓存（第二张表：探测、装填守卫、重建重放、回写重探、重置） | `ty_shadow.cr:523-593`（`sh_unf_map_reset`/`sh_unf_cap_init`/`sh_unf_find_nogrow`/`sh_unf_find`/`sh_unf_rehash`/`sh_unf_hits`/`sh_unf_entries`） |
| `sh_struct_term`（struct 命名行和泛型应用行转 AK_PRODUCT，按字段声明序） | `ty_shadow.cr:641-680` |
| `sh_struct_field_term`（字段节点解析加泛型实参代入，照 checker 的 EXPR_FIELD 路径） | `ty_shadow.cr:608-639` |
| `sh_variant_term`（变体名转变体项，身份为枚举名加变体名，放入参数链） | `ty_shadow.cr:682-690` |
| `sh_enum_domain_term`（枚举转为各变体项的并，作为域；空枚举转为 ⊥） | `ty_shadow.cr:692-725` |
| `sh_iface_shape_term`（占位，恒为 -1；理由是接口签名仍是裸 TY，P2b 未交付条目） | `ty_shadow.cr:727-731` |
| `iface_satisfies`（满足判定入口占位，恒返回三态 -1；接管属于 Task 2/6） | `type_engine.cr:486-499` |
| “行到声明”入口（`decl_name_of_ti` / `find_struct_row_of` / `find_enum_row_of`；名字解析归 checker，只读） | `checker.cr:858-886` |
| init_types 挂点（展开缓存随类型表重置失效，原因同 `sh_map_reset` 评审 Critical） | `checker.cr:238-240` |
| 展开缓存全局（第二张表，值语义与桥接表不同，不得共用） | `globals.cr:313-322` |
| 自测夹具 helper（`ts_unf_mk_int_struct` / `ts_unf_union_leaves`，后者独立重算析取支数，不与实现共享计数） | `type_selftest.cr:45-60` |
| 自测用例段 17 例 | `type_selftest.cr:1048-1223` |

接口签名与计划 Interfaces 块逐字一致：`sh_struct_term(ti)` / `sh_enum_domain_term(ti)` / `sh_variant_term(ti, name_ni)` / `sh_iface_shape_term(iface_ni)`。另外增加实现必需的 `sh_struct_field_term(sa, fi, ga)` 以及缓存和统计访问器。

---

## 2. 判据（命令和结果）

| # | 判据 | 命令 | 结果 |
|---|---|---|---|
| 1 | 自举构建 | `nice -n 19 python3 build_selfhost_native.py` | rc=0，`=== BUILD SUCCESS ===`；三守卫 `build log clean (error[ = 0, undefined = 0)`（corec/corearch/corelsp） |
| 2 | 自测用例表 | `nice -n 19 ./build/corec selftest-types` | 229/229（基线 212/212，增加 17 例，零 FAIL，rc=0） |
| 3 | 接口查表回归 | `nice -n 19 python3 tests/selfhost/test_iface_ops.py` | 76/76 passed |
| 4 | ELF canary 逐字节 | `clean-cache`，然后 `build tests/suite/ptr_arith.cr --static -o /tmp/pa_p3t0_new`，再 `sha256sum` | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475` IDENTICAL（与基线二进制同源同值） |
| 5 | 判定面零行为变化（72 档） | base 二进制配新源对比 new 二进制配新源：`check` 的 stdout、stderr 全文和 rc | `diff -r` 为空；rc 分布两侧相同，33 档 rc=0、39 档 rc=1（t1=32、t2=2、t3=15、t4=19、t5=4） |
| 6 | 影子对拍门复跑（72 档，2 个二进制） | `check --type-shadow --type-shadow-dump`，逐档 clean-cache | 日志 `diff -r` 为空，dump 全文 `diff -r` 为空；聚合为 `decisions=29090 agree=29090 old_stricter=0 old_looser=0 unknown=0 unknown_bridge=0 unknown_engine=0 unknown_engine_uncovered=0 unknown_engine_budget=0 replace_bridge=0 replace_unknown=0`；`agree == decisions` 成立，`sum(sites) == decisions` 成立（两个二进制同值） |
| 7 | 回归套件 | `test_compile.py`、`test_purity.py`、`test_ccr_v7.py`、`test_type_engine.py` | 全部通过（`All selfhost compile tests passed` / PASS / 27/27 / PASS） |
| 8 | `.ccr` 逐字节（计划预期不变） | `clean-cache`，然后 `ccr tests/suite/ptr_arith.cr`（旧新二进制各一次） | `ecd7a9dfd557810651d9f4a31bf5775556b5c15518fb0a9dbacb56af83dcd29d` IDENTICAL（等于 P2b 记录值） |
| 9 | CI selfhost-tests 全套 | `nice -n 19 env CI_JOB_NAME=selfhost-tests bash src/ci/run.sh` | 见第 2.1 节 |
| 10 | 突变控制（用例非真空性） | 见第 6 节 | M1 得到 227/229（两例失败）；M2 得到 228/229（一例失败）；复位后 229/229，三个二进制 sha 逐字节复原 |

### 2.1 CI selfhost-tests（全套 15 档）

`nice -n 19 env CI_JOB_NAME=selfhost-tests bash src/ci/run.sh` 得到 rc=0，0 FAIL。`build_selfhost` 重建的三个二进制 sha 与第 6 节复位后逐字节相同，构建具有确定性。逐档结果：`test_compile`（All selfhost compile tests passed）、`test_type_engine` PASS、`test_iface_ops` 76/76、`test_purity` PASS、`test_ccr_v7` 27/27、`test_impl`、`test_borrow`、`test_pointer_safety`、`test_params_limit`、`test_tuple_slots`、`test_agg_slots`、`test_agg_checks`、`test_nested_fn`、`test_interp_parity`（23/23）、`test_cache_identity`（5/5）全部通过。

### 2.2 站点覆盖（与差异数同报，这是 P1 交接的硬性要求）

影子直方图（两个二进制同值，求和等于 decisions）：`assign-node=21996 · fn-body-ret=5179 · if-branch=1881 · struct-field-type=28 · array-elem-type=4 · generic-apply-base=2`。
站点 1（hotpatch-ret）、2（generic-arg）、4（unify-fallback）、6（assign-binary）在语料中零命中（与 P1/P2a/P2b 口径相同），站点 3（generic-apply-base）只有 2 次。

因此“零差异”的效力范围仍然是赋值、返回、if 面。本任务的新能力面（展开层）在语料中零命中（本批零生产消费者）。零差异不等于面收敛，展开层的正确性由第 3 节的定向用例和第 6 节的突变控制承担，不得用对拍归零充当其证据。

语料自指（诚实声明）：语料包含 `src/compiler/` 下的全部文件，因此本批新增代码进入语料，判定数从 28,829（起点树）变为 29,090（增加 261，等于新增行自身的判定）。分类和站点覆盖口径不变。另外，计划基线记的是 71 候选、67 有效、26,989 判定。本复跑逐档同源，但文件数已经随树变化（现在 `tests/suite` 有 32 档，t1 到 t5 合计 72 档，70 档有摘要；2 个无摘要是 `test_control_flow.cr`/`test_generics.cr` 的 0 字节空文件，与 P1 findings 第 2 节的排除项一致）。

---

## 3. 新用例 17 例（212 到 229）：口径和理由

计划 Step 1 给 6 例（四个正向形态、名义不变量双钉、缺口上抛、缓存命中）。实际落 17 例（`type_selftest.cr:1048-1223`）。多出的 11 例理由是交付面大于计划例表，计划中的“至少 101”是下限，可以增加不能减少：

| 组 | 用例 | 断言要点 |
|---|---|---|
| 泛型代入 2 | `unf.ga_arg_subst` / `unf.ga_unapplied_nominal` | `UnfBoxU[int]`/`[string]` 的字段项为 AK_INT/AK_STRING，且两项不等，说明代入是活的。未应用形态的形参保持名义（不等于 AK_INT，不凭空代入） |
| 字段形态 2 | `unf.struct_field_order` / `unf.struct_field_node_not_code` | 声明序（int 到 string 的链序断言，不是集合断言）；裸码槽为 0 而类型节点是数组的字段得到 AK_SEQUENCE，这是只读裸码实现的守门例，第 6 节 M1 实证 |
| 名义不变量 3（计划“双钉”落实） | `unf.nominal_structural_equal` / `unf.nominal_equiv_atomic_unknown` / `unf.nominal_type_equal_false` | 两个同形不同名 struct：展开项的 `ty_equiv == 1`（满足面结构相等，符合设计意图），桥接项的 `ty_equiv == -1`（等价面仍原子名义），`type_equal` 仍为 false，`g_replace_unknown` 恰好加 1 |
| 枚举域 4 | `unf.enum_domain_count` / `unf.enum_variant_in_domain` / `unf.enum_variant_identity_scoped` / `unf.enum_empty_domain_bot` | 3 个变体的域有 3 个析取支（独立重算 union 树叶子数）；各变体属于域，未声明变体名返回 -1；异枚举同名变体不得判等价（身份入链的守门例，第 6 节 M2 实证）；空枚举域为 ⊥（登记语义） |
| 穷尽性端到端 3（Task 3 判据种子） | `unf.exhaust_cover_all` / `unf.exhaust_missing_one` / `unf.exhaust_witness_subset` | tag 加 payload 的混合枚举：全覆盖为 1，缺一个变体为 0，witness 非空且属于缺失变体 |
| 缓存 1 | `unf.cache_hit_and_no_neg_cache` | 新 ti 恰好入表 1 条，第二次调用恰好命中 1 次且项相同；失败不入表（-1 不缓存） |
| 缺口上抛 1 | `unf.neg_paths` | 行号越界、-1、未声明名字行、裸泛型形参行、非枚举变体名，一律返回 -1，不得不报错地判否 |
| 接口占位 1 | `unf.iface_stub_three_state` | `sh_iface_shape_term(-1) == -1` 且 `iface_satisfies(-1, 0) == -1` 且 `iface_satisfies(TI_INT, 越界) == -1`。负键和越界键断言在 Task 2/6 实施后仍成立，是持久性质，遵循 P2b Task 1 的教训“不写会变红的现状断言” |

夹具口径：`init_types()` 干净起点后人工落 `g_structs`/`g_enums` 行，照 parser 的写槽序（字段名、裸码槽、类型节点、字段数；枚举变体名、载荷计数、载荷裸码）。类型节点照 `parse_type` 的产物形态（基型 `kind=0 + type_val=TY_*`，`EXPR_IDENT` 表示泛型形参或命名类型，`EXPR_ARRAY` 表示 `[T;N]`）。struct 泛型形参照 `collect_decls`（`checker.cr:941-950`）用 `def_sym` 登记。生产路径的形参必须在符号表中（`res_type_node` 经 `find_gsym` 解析），照此登记就是走真实解析路径，也是第 5 节第 ③ 条的规避面。

---

## 4. 语义边界和实现裁决（计划未定、实现者定的 5 点）

1. 边界落实（本 Task 的第一性约束）：`sh_term_of_ti` 的 NAMED/GENERIC_* 分支一行未动，等价面身份仍是原子名义。展开函数是独立入口，零生产消费者。三个 `unf.nominal_*` 用例把边界钉成可执行判据（双钉加回落计数）。
2. 展开项布局：`struct` 转为 `tt_atom(AK_PRODUCT, ti, 字段链)`；`variant` 转为 `tt_atom(AK_SUM, ti, [枚举名 ni, 变体名 ni])`；域为各变体项的并。身份必须放入参数链的理由：引擎的 `lit_implies` 只比较 `a`（原子类）和 `c`（参数链）两个槽，`b` 槽是标注（AK_NAMED 的 b 为行号就是此约定）。身份如果只放在 `b` 或省去，异枚举同名变体会被不报错地合并（`ty_sub` 判 1），导致穷尽性假通过。守门例是 `unf.enum_variant_identity_scoped`，M2 已实证。
3. 变体项不含 payload（登记缺口）：枚举表只存 payload 的裸 TY 码（`parser.cr:1601` 的 `unpack_type`，非基型塌缩为 `0 = TY_INT`，与“payload 是 int”不可区分）。把它包含进项会不报错地谎报，因此不放入。影响 Task 3/4，见第 5 节第 ① 条。
4. 展开缓存是第二张表（键空间同为 ti，值语义不同：展开项与原子名义项），不得与 `g_shadow_map` 共用。共用会让展开项进入等价判定，正是本任务要防的变化。生命周期同桥接缓存：`init_types()` 调用 `sh_unf_map_reset()`。行号空间会复用，陈旧的 ti 到展开项映射必须作废；长驻 corelsp 每个请求执行一次。
5. 接口面两块占位恒为 -1（`sh_iface_shape_term` / `iface_satisfies`）：P2b 未交付条目和满足关系（附录 A.3-①），接口签名仍是裸 TY（Task 6 类型项化），形状项无处可建。三态 -1 表示保守不判，不可能不报错地放宽。接管属于 Task 2/6。

非纯只读（诚实登记）：`sh_struct_field_term` 经 checker 的 `res_type_node` 解析字段类型节点，这是唯一实现，本层不复制其语义。因此对非基型字段可以追加类型行（`alloc_type`/`alloc_named_type`），并可能报 `EC_N_GENERIC_TYPE`。这与 `checker.cr` 的 EXPR_FIELD 字段解析同源同径。本批零生产消费者。接入判定路径（Task 2/6）前，必须评估“判定中途分配类型行”的时序影响。深度为一层：子项走 `sh_term_of_ti`，命名和泛型不展开，因此递归结构在第二层终止。嵌套代入（`Box[Box[T]]`）现状不可达，属于 F4 同族缺陷（TODO #21，Task 5 收口）。本层与 checker 现状一致，没有单独走另一套。

---

## 5. 发现（登记，影响后续任务，需 lead 过目）

### ① 枚举 payload 表缺类型节点，是 Task 3/4 的前置缺口（本次未修，超出 Task 0 文件面）

`struct` 存字段类型节点（`OFF_SI_FIELD_TYPE_NODES`），而 `enum` 只存变体载荷裸码（`OFF_EV_TYPES`，`parser.cr:1601`），非基型塌缩为 `0 = TY_INT`。因此：① spec 第 5.4 节的“enum = sum（变体 × payload product）”在这张表上无法忠实表达；② Task 4 的“`Some(1)` 满足 `int?`”需要 payload 代入，开工前必须先扩展枚举表，照 struct 先例存 payload 类型节点，parser 写 `unpack_type` 的地方同步补节点槽，否则该能力只能做“身份级”半场；③ Task 3 的穷尽性按变体身份判定，不受影响（现状模式面也不按 payload 分解，`EXPR_ENUMPAT` 子模式是另一条路径）。建议 Task 3 先行，Task 4 前置补表。

### ② `ty_exhaust_witness` 原始形态含空析取支，Task 3 判据前提不成立

缺变体时，`witness = norm(域 ∩ ¬⋃模式)`，等于各析取支的并（例如 `(A∩¬A) ∪ (B∩¬A)`）。`tt_norm` 不做空支净化，因此：① `ty_equiv(witness, 缺失变体) == 0`，Task 3 计划用例“witness = 该变体”按现状不成立；② “反例给具体值”必须先取有住户的析取支。本 Task 用例只断言 `ty_inhabited(witness) == 1 ∧ witness ⊆ 缺失变体`，这个断言成立。处置选项有两个：Task 3 侧取支，不改引擎；或者引擎加净化，但 `type_engine.cr` 不在 Task 3 声明的 Files 内，需要 lead 裁决。
同族问题：不可展开域（`AK_NAMED` 原子）在引擎侧 `ty_exhaustive` 给 1 或 0，而不是 -1（P0 引擎没有“未知域”规则）。因此 Task 3 计划用例“域不可展开 = -1”同样须由 checker 侧守卫或引擎新规则承担。

### ③ bootstrap 前端不短路 `&&`/`||`（实测 SIGSEGV 加反证）

现象：Task 0 首轮实现触发 `selftest-types` rc=139，gdb 栈是 `sym_kind ← res_type_node` 的 `si >= 0 && sym_kind(si)`，在 `g_syms = NULL` 时读 `NULL-24`。机制实测（反汇编）：两侧都求值后按位与，`call sym_kind` 无条件执行，只有 `si = -1`（无符号）时才崩。自托管前端是短路的（探针 `/tmp/p3t0_probe/shortcirc.cr`：LHS 为假时 RHS 没有副作用，rc=1，证明 D11“IR 层分支化短路”成立）。
归因（源码实读）：短路是前端行为，由 `ir_gen` 分支化实现。自托管 `ir_gen.cr` 分支化（D11），但 Python bootstrap 的 `ir_gen.gen_binary`（`bootstrap/corec/frontend/ir_gen.py:226-235`）把两侧无条件求值后发 `BinaryInstr`。因此由它构建的编译器二进制（corec/corearch/corelsp）自身按“两侧都求值”执行，同一份源码经自托管前端编译出的程序则短路。所以这是 bootstrap 构建面的特性，不是自托管语义。生产路径的 `g_syms` 必然已经分配，没有外部表现（本批 72 档语料加全回归零异常）。
影响面：任何 `guard && 表读(idx)` 形态（本仓库常见）在符号表未分配的通道可能崩溃。生产路径 `g_syms` 必然已分配，没有外部表现（本批 72 档语料加全回归零异常）。本任务处置是夹具按 `collect_decls` 先例用 `def_sym` 注册形参，走真实路径，未改后端短路语义（超出 Task 0 范围）。登记供裁决，修复面是 bootstrap ir_gen 分支化，或者全线给该形态加护栏。

### ④ corearch 二进制 sha 变化（行为零泄漏，原因已定位）

`2b835710…` 不等于基线 `31d70900…`。`globals.cr` 属于 `common_files`（corearch 清单包含它），新增 4 个展开缓存全局改变了它的数据段布局（corearch 自身零引用、零行为变化）。产品面零泄漏的证据：ELF canary 逐字节 `95084e7b…d475` IDENTICAL（经 corearch 发射的用户程序），72 档 check 面和影子面全同。口径说明：corearch 二进制字节相同不是本计划的判据。P2b Task 1 有同样情形，`g_iface_*` 进入 `globals.cr` 也改变了 corearch 字节，当时未列为判据。如果要让 corearch 逐字节相同，可以把 4 个全局移入 `ty_shadow.cr`（corearch 不含该文件）。本批按 P2b 惯例保留在 `globals.cr`，留 lead 定夺。

### ⑤ 缓存扩容和重建路径的覆盖面（自证口径）

展开缓存初始容量 256，装填守卫 50%，本批用例只入约 10 条，扩容和重建重放路径在语料中不可达（P0/P1 有同类教训）。本层刻意照抄 `sh_map_find/rehash` 的已验证形态（同式同因，逐行对应），没有新写算法。如果 lead 要求判据级覆盖，需要另加至少 256 个互异 ti 的夹具，可以增加不能减少，成本是一个 loop。

---

## 6. 突变控制（用例非真空性，复位后二进制逐字节复原）

| # | 突变（临时，已复位） | 预期 | 实测 |
|---|---|---|---|
| M1 | `sh_struct_field_term` 末段改读裸码槽（`ty_code_to_ti(si_field_type(...))`），替代类型节点解析 | 只读裸码实现应被守门例抓住 | 227/229：`unf.struct_field_node_not_code` FAIL 加 `unf.ga_unapplied_nominal` FAIL（form/gen 两类字段面都被抓住） |
| M2 | `sh_variant_term` 参数链去掉枚举名（身份只留变体名） | 异枚举同名变体应被不报错地合并，守门例失败 | 228/229：`unf.enum_variant_identity_scoped` FAIL，其余 228 例全部通过，证明该例专门针对身份维度 |
| 无 | 复位（两处还原为原实现） | 229/229 加二进制逐字节复原 | 229/229 rc=0；`build/corec 8c759c6c…` / `corearch 2b835710…` / `corelsp 9a365a2a…` 三个 sha 与突变前逐字节相同（构建确定性和复位完整） |

---

## 7. 过程诚实项

- 红态未单独跑（同 P2b Task 1 第 5.4 节口径）：实现和用例在同一编辑序列实施，未单独构建“无 `sh_*` 符号”的红态。红的客观依据是这 5 个符号此前全仓零定义，构建期会因 `Undefined name` 硬失败。
- `unf.nominal_*` 的 `g_replace_unknown` 断言依赖“回落计数在 `type_equal` 路径自增且与影子开关无关”（`checker.cr:492-508` 码级事实）。本批未改该路径，与既有 `t3.unknown_fallback_legacy` 同源。
- 语料运行器不是仓库文件（`/tmp/p3t0_run.sh`，逐档 clean-cache，cwd 为仓库根）。逐档日志和 dump 留档在 `/tmp/p3t0_{base2,new}_{check,shadow}/`，基线二进制在 `/tmp/p3t0_base_bin/`。
- 本报告与 `docs/archive/sdd/` 的其他报告一致，不入提交（未被 jj 跟踪）。

---

## 8. 证据命令速查（可复核）

```bash
# 判据 2（用例表，229）
nice -n 19 ./build/corec selftest-types | tail -1
# 判据 4（ELF canary；必须先 clean-cache、cwd = 仓库根）
nice -n 19 ./build/corec clean-cache && nice -n 19 ./build/corec build tests/suite/ptr_arith.cr -o /tmp/x --static && sha256sum /tmp/x
# 判据 5/6（72 档两模式；与基线二进制对拍）
bash /tmp/p3t0_run.sh check  /tmp/p3t0_base_bin/corec /tmp/p3t0_base2_check   # 旧二进制 × 新源
bash /tmp/p3t0_run.sh check  ./build/corec           /tmp/p3t0_new_check     # 新二进制 × 新源
diff -r /tmp/p3t0_base2_check/logs /tmp/p3t0_new_check/logs                     # 空
bash /tmp/p3t0_run.sh shadow /tmp/p3t0_base_bin/corec /tmp/p3t0_base2_shadow
bash /tmp/p3t0_run.sh shadow ./build/corec           /tmp/p3t0_new_shadow
diff -r /tmp/p3t0_base2_shadow/logs /tmp/p3t0_new_shadow/logs                    # 空
nice -n 19 python3 /tmp/p3t0_agg.py /tmp/p3t0_new_shadow                          # 聚合 + agree==decisions 校验
# 判据 8（.ccr 不变）
nice -n 19 ./build/corec clean-cache && nice -n 19 ./build/corec ccr tests/suite/ptr_arith.cr -o /tmp/y.ccr && sha256sum /tmp/y.ccr
# 短路探针（第 5 节第 ③ 条）
nice -n 19 ./build/corec build /tmp/p3t0_probe/shortcirc.cr -o /tmp/sc --static && /tmp/sc; echo $?   # 期望 1
```
