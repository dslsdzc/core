# R2 P2b Task 5 报告：容器面接线（索引 5、字段 4、转换 1、dyn）

状态：DONE_WITH_CONCERNS。判据全部通过。需要说明的是，本 Task 真正可接线的位置只有 1 处，与计划的名义范围“索引 5、字段 4、转换 1、dyn”差距很大。这不是漏做，而是逐点实测后的裁决：字段面和转换面没有任何拒绝路径，dyn 面的谓词不是类级位。三面的逐条实测依据见 §5，说明和建议见 §9。

提交：见 §11，路径限定 5 个路径。
计划：`docs/superpowers/plans/2026-09-11-r2-p2b-iface-ops.md` 的 Task 5。
总结：18 个候选站点中只有 1 个门接线，即索引面的后备拒绝改为查 `IP_INDEX`，门体就是原来的 `EC_TK_INDEX` 调用，诊断码、文案和位置逐字不变。其余 17 个按 Task 4 的先例“不接线、给出实测理由、登记为 P3 旋钮”，逐条台账见 §5。新用例确实能发现问题，突变控制的三层同时失败，见 §7。全部判据通过。

---

## 1. 交付物与落点（file:line，全部实测）

| 交付物 | 落点 | 说明 |
|---|---|---|
| 唯一接线点（索引面后备门） | `checker.cr:2668`（注释块 `:2659-2667`，诊断调用 `:2669`） | 接线前 `:2659` 是裸 `check_error(EC_TK_INDEX, ...)`，改为 `if iface_permits(iface_kind_of(arr_ti), IP_INDEX) == 0 { <原调用> }`。门体就是原后备调用 |
| 注册表注释同步（Task 5 消费点和四个不接线理由） | `iface_registry.cr:40-47`（头注）、`:117-119`（AK_STRING）、`:129-133`（AK_SEQUENCE）、`:136-139`（AK_DYN）、`:143-145`（AK_PRODUCT）、`:152-155`（AK_NAMED） | 纯注释，不接线；逐位注明“已接线/未接线 + 理由” |
| selftest 用例段（18 例） | `type_selftest.cr:863-971`（段头 `:863-868`） | 表与后备的集合等价（全行枚举）、端到端 11 例（经真实 `infer_expr`）、反真空 2 例 |
| 行为回归（新增 21 例，39 到 60） | `tests/selfhost/test_iface_ops.py:161-217`（`t5_*` 段） | 正控 3、负控 11、登记面 7 |
| 例数同步 | `src/ci/run.sh:71-72` | `selftest-types` 从 183 改为 201 例；`test_iface_ops` 注释补 60 例 |

### 1.1 计划行号变化（按内容定址，不猜）

计划写 `:2581-2636`（索引）、`:2509-2579`（字段）、`:2892-2908`（转换）、`:2066-2082` `:2643-2651` `:2473-2477`（dyn）。接线前实测 `checker.cr` 为 3401 行：

| 站点 | 计划 | 接线前实测 | 变化 |
|---|---|---|---|
| 索引面（range 分支到后备） | `:2581-2636` | `:2606-2660` | +25 |
| 字段面 `EXPR_FIELD` | `:2509-2579` | `:2534-2603` | +25 |
| 转换面 `EXPR_AS` | `:2892-2908` | `:2917-2933` | +25 |
| dyn 消费点 ①（方法分派） | `:2066-2082` | `:2085-2101` | +19 |
| dyn 消费点 ②（`EXPR_LET` 建集） | `:2473-2477` | `:2498-2502` | +25 |
| dyn 消费点 ③（`EXPR_ASSIGN` 建集） | `:2643-2651` | `:2674` | +31 |

变化原因同 Task 3/4：计划侦查的基准是起草时的工作副本，此后 P2b Task 1 到 4 落了新行。接线后索引门在 `:2668`，`EXPR_ASSIGN` 在 `:2685`，`EXPR_AS` 在 `:2928`；`EXPR_FIELD` `:2534` 和 dyn ① ② 在门之前，行号不变。

---

## 2. 判据（命令与结果，逐条）

| 序号 | 判据 | 命令 | 结果 |
|---|---|---|---|
| 1 | 自举构建 | `nice -n 19 python3 build_selfhost_native.py` | rc=0；3 次 `[GUARD] … build log clean (error[ = 0, undefined = 0)`；`=== BUILD SUCCESS ===`（corec/corearch/corelsp） |
| 2 | 自测用例表 | `nice -n 19 ./build/corec selftest-types` | 201/201，零 FAIL，rc=0。基线 183，增加 18 例，例数同步 `run.sh:71` |
| 3 | ELF 逐字节 | `clean-cache`，然后 `build tests/suite/ptr_arith.cr --static -o /tmp/pa_p2b5`，再 `sha256sum` | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`，IDENTICAL。计划定值，共 2 次独立测量：接线后和突变复位后 |
| 4a | 语料面零变化（32 档） | 旧二进制加新源，对比新二进制加新源；每档 `check` 的 stdout、stderr、rc 落盘（`/tmp/p2b5_run.py`） | `diff -r` 逐字节全空 |
| 4b | 编译器自源（三条基线） | ① 旧加新对比新加新；② 旧加旧（`/tmp/p2b5_oldtree` 的 @- 源）；③ 对照计划口径 | ① `cmp` IDENTICAL，隔离输入增长；② 新加旧之差恰好是 2 条既有 TF01 的行号位移 +11（`9362/9477` 变为 `9373/9488`；两侧各 2 条 `error[`，无新增无消失）；③ 位移量等于 checker.cr 净增 11 行（唯一变动的前置文件，`wc -l` 实测） |
| 4c | `.ccr` 逐字节（冷缓存，4 语料） | 每档 `clean-cache`，然后 `ccr`，再 sha256，旧新编译器各一轮 | 4/4 IDENTICAL：ptr_arith `ecd7a9df…d29d`、at_test_struct `891377232b…8f08`、generics_test `35cf0f26…5d23`、dyn_test `dfb82d2b…626f`。与 Task 1 到 4 报告逐字相同，跨批可比 |
| 4d | 影子通道（32 档，冷缓存） | `check --type-shadow --type-shadow-dump`，摘要、站点直方图、dump 全文逐档落盘 | 旧新逐字节全同；聚合 `decisions=2826 agree=2826 old_stricter=0 old_looser=0 unknown=0 unknown_bridge=0 unknown_engine=0 replace_bridge=0 replace_unknown=0`；直方图 `assign-node=1816 fn-body-ret=778 if-branch=222 struct-field-type=4 array-elem-type=4 generic-apply-base=2`，其余 5 站点为 0。与 Task 4 数字逐项相同 |
| 5 | 四套回归 | `test_compile.py`、`test_purity.py`、`test_ccr_v7.py`、`test_type_engine.py` | 通过、通过、27/27、通过 |
| 6 | 行为回归（本 Task 新扩） | `nice -n 19 python3 tests/selfhost/test_iface_ops.py` | 60/60；旧二进制用同源同用例运行，输出与新版逐字节相同（`cmp`，见 §6） |
| 7 | 加宽回归 | `test_impl`、`test_borrow`、`test_pointer_safety`、`test_params_limit`、`test_tuple_slots`、`test_agg_slots`、`test_agg_checks`、`test_slice_bounds`、`test_named_dedup`、`test_interp_parity`、`test_cache_identity`、`test_nested_fn`、`test_lsp` | 全部通过：7/7、7/7、通过、5/5、14/14、13/13、20/20、7/7、通过、23/23、5/5、17/17、ALL PASS (10)。包含计划 Step 3 点名的 `test_slice_bounds` |
| 8 | 突变控制（计划要求的“有自测”实证） | 见 §7 | selftest 197/201 rc=1（4 个失败），行为回归 59/60 rc=1（`t5_neg_index_int: 不报错地放行`）；复位后 201/201、60/60、ELF 同、重建二进制与探针前逐字节相同 |
| 9 | 提交边界 | `jj commit -m … <5 路径>` | 见 §11。`tests/suite/*.cr.{out,rc}` 64 个他人 scratch 未入库 |
| — | 探查先行（计划侦查 §6.2 / Task 5 Step 1） | `nice -n 19 python3 /tmp/p2b5_probe.py <binary>`（44 例） | 接线前后逐字节相同；现状事实见 §4 |

---

## 3. 接线前后逐字对照（转录证据）

```core
// 改动前（checker.cr:2659）
check_error(EC_TK_INDEX, "Cannot index non-array type", ast_line(node), ast_col(node));
return TI_INT;
// 改动后（checker.cr:2668）
if iface_permits(iface_kind_of(arr_ti), IP_INDEX) == 0 {
    check_error(EC_TK_INDEX, "Cannot index non-array type", ast_line(node), ast_col(node));
}
return TI_INT;
```

等价性有三层证据：

1. 可达集：这个门位于三个结果分支之后。`TYP_ARRAY` 走元素加 F2（`:2630`），`TYP_SLICE` 走元素（`:2641`），`arr_ti == TI_STR` 走 `TI_INT`（`:2644`）。range 索引分支（`:2611-2628`）在门之前已经 `return`。因此能走到这个门的类型行集合是 `{kind 不属于 {ARRAY, SLICE} 且 ti 不等于 TI_STR}`。
2. 表的拒绝集等于上面的集合。`IP_INDEX` 只在 `AK_SEQUENCE`（条目 9，包含 ARRAY 和 SLICE 行）与 `AK_STRING`（条目 2）两行置 1。`arr_ti == TI_STR` 等价于 `iface_kind_of == AK_STRING`，因为 `TYP_BASE` 行的唯一分配点是 `init_types:241-253`，实测 STR 行恰好 1 行。逐行枚举的等式由 selftest `idx.gate_deny_covers_fallback` 固定，采用双向计数，包含 `g_type_count` 全行。
3. 行为面：44 例探针、32 档语料、60 例行为回归、4 档 `.ccr`、32 档影子、ELF 哈希全部相同。

与计划原文有一处裁决性偏差，需要 lead 过目。计划 Step 2 写“在 `check_error` 之前加或改为 `if … { <原 TK01 报错> }`，其后保留原后备”。如果按字面“加”并“保留”，拒绝路径会报两条 TK01，即原裸调用加门体，这是可观测行为变化，语料和探针的 `error[TK01]` 计数以及 stdout 都会逐字节变化。本报告采用“门体即原后备调用”，只报一条。理由是计划同一段的硬口径“措辞路径不变、保语义”优先。`check_error` 没有去重，实读 `diag.cr` 没有同码同位置折叠。Rust 式的“双保险”在 `check_error` 语义下不成立。

---

## 4. 现状行为事实表（探针先行，44 例；计划侦查 §2 未测项，本 Task 实测确证）

`/tmp/p2b5_probe.py`，两侧逐字节相同。44 例输出留档在 `/tmp/p2b5_probe_base.txt`（旧）和 `_new.txt`（新）。

| 面 | 探针 | 现状 |
|---|---|---|
| 索引·正控 | `a[1]`（数组）、`s[1]`（切片）、`s[0]`（串）、`a[0..2]`（数组 range） | rc=0。数组得到元素，切片得到元素，串得到 int，数组 range 得到 slice |
| 索引·负控 | `x[0]`，int/bool/dex/char/ptr/named/tuple/dyn/unit 各一例 | 9/9 rc=1 `error[TK01]`，非容器行一律拒绝 |
| 索引·登记 | `s[0..1]`（串 range）、`sl[0..1]`（切片 range）、`x[0..1]`（int range） | rc=0 不报错地。range 分支非数组时落空，`return TI_UNIT`，没有诊断。这是 P3 收紧面 |
| 字段 | `s.a`（struct）、`t . 0`（元组）、`t . 5`（越界元组位）、`x.a`（int/dex/bool/dyn）、`s.len`（串）、`p.a`（指针）、`a.len`（数组）、`s.zzz`（未知字段）、`s.m`（方法当字段） | 12/12 rc=0 且零诊断。EXPR_FIELD 全形态没有拒绝路径。这是 P3 收紧面 |
| 转换 | `1 as int`、`"a" as int`、`1 as string`、`arr as int`、`1.5 as int`、`p as *int`、`p as int`、`1 as *int`、`S{} as int`、`1 as S` | 10/10 rc=0。除 PTR 目标的结果规则外恒等透传，没有拒绝路径。这是 P3 收紧面 |
| dyn | `d.nosuch()`（d: dyn = 5 / "a" / struct） | 3/3 rc=1 `error[N08]`（EC_N_METHOD）。int 和 string 候选行也报，因为 `get_type_name(TI_INT)="int"`，然后按名拼接方法表判定 |
| dyn·正控 | `d.m()`（struct 有 `impl` 方法）、`d = 7`、`d.a`（字段） | rc=0 |

词法限制沿用 Task 4 的记录：`t.0`（无空格）无法词法化，lexer 会把 `.` 加数字当成数字字面量。探针和用例一律用 `t . 0`（带空格）。这是既有问题，不是本批引入。

---

## 5. 站点台账（逐条：落点、处置、实测依据）

口径：“已接线”指判定改为查表，并且存在可被表推翻的拒绝路径。“不接线”按 Task 4 先例处理，lead 明确要求不能零行为变化接线时必须报告，不能硬接。行号是接线前实测值。

### 5.1 索引面 5 条（计划 Task 5 的第一项）

| 序号 | 站点 | 现有语义 | 处置 | 依据（实测） |
|---|---|---|---|---|
| 1 | `:2611-2628` range 索引（`TYP_ARRAY` 得到 slice，否则 `return TI_UNIT`） | 结果规则加不报错地落空 | 不接线 | `IP_INDEX_RANGE` 的拒绝分支（非数组落空）没有诊断，门恒真，等于空转。探针 I14/I15/I16 中，串、切片、int 的 range 索引全部 rc=0 不报错地。登记 P3 旋钮 |
| 2 | `:2630-2640` `TYP_ARRAY` 得到元素加 F2 越界 | 结果规则加既有诊断 | 不接线（保留） | 计划 Task 5 Step 2 明确：三个分支做的是不同的事，必须原地保留。F2 的正证据是 selftest `idx.infer_arr_oob_diag/_code` |
| 3 | `:2641-2643` `TYP_SLICE` 得到元素 | 结果规则 | 不接线（保留） | 同上 |
| 4 | `:2644-2658` `TI_STR` 得到 `TI_INT` 加字面量越界 | 结果规则加既有诊断 | 不接线（保留） | 同上 |
| 5 | `:2659` 后备拒绝 `EC_TK_INDEX` | 非容器行得到 TK01 | 已接线（`IP_INDEX`） | 门体即原调用；可达集等于表拒绝集（逐行枚举 `idx.gate_deny_covers_fallback`）；三层突变实证见 §7 |

### 5.2 字段面 4 条（计划 `:2509-2579`；实测 `EXPR_FIELD` 为 `:2534-2603`）

| 序号 | 站点 | 现有语义 | 处置 | 依据（实测） |
|---|---|---|---|---|
| 1 | `:2538-2542` `TYP_REF` 自动解引用 | 结果规则，落 `actual_ti` | 不接线 | 没有拒绝路径；改查表等于改结果规则 |
| 2 | `:2543-2546` `TYP_GENERIC_APPLY` 解包基型 | 结果规则 | 不接线 | 同上 |
| 3 | `:2547-2589` `TYP_NAMED` 到 struct 字段表（含泛型代换） | 结果规则，名字匹配加返回字段类型行 | 不接线 | 同上；谓词是字段名匹配（`si_field_name == field_ni`），不是类级位 |
| 4 | `:2590-2602` `TYP_TUPLE` 到 `.N` 位 | 结果规则 | 不接线 | 同上 |
| 5 | `:2603` 落空 `return TI_UNIT` | 无诊断不报错地 | 不接线 | `IP_FIELD` 的拒绝集（非 NAMED/PRODUCT）与能走到 `:2603` 的行集在现状同集。探针 F3-F12 中，越界元组位、未知字段、方法当字段，以及 ptr、串、数组、int、dex、bool、dyn 操作数，12/12 rc=0 零诊断，门是恒真门。登记 P3 旋钮，这一格是收紧时加诊断的位置 |

### 5.3 转换面 1 条（计划 `:2892-2908`；实测 `EXPR_AS` 为 `:2917-2933`）

| 序号 | 站点 | 现有语义 | 处置 | 依据（实测） |
|---|---|---|---|---|
| 1 | `:2922-2931` PTR 目标的 asp 传递 | 结果规则，构造 `*T` 行 | 不接线 | 结果规则，不是许可判定 |
| 2 | `:2932` 其余恒等透传 `return target_ti` | 无拒绝路径 | 不接线 | 探针 A1-A10 中 10/10 rc=0，包含 `"a" as int`、`arr as int`、`1 as S`。`IP_AS` 对全 13 类置 1，没有一格能被门推翻。登记 P3 旋钮，即转换合法性矩阵 |

### 5.4 dyn 面 4 条（写集、读集、方法校验、三个消费点）

| 序号 | 站点 | 现有语义 | 处置 | 依据（实测） |
|---|---|---|---|---|
| 1 | `:1829-1838` `dyn_set_type`（写集，64 上限钳位） | 位图并集 | 不接线 | 没有拒绝路径；64 上限是既有登记项（spec §3.3） |
| 2 | `:1840-1849` `dyn_has_type`（读集） | 位测试 | 不接线 | 只读，没有判定面 |
| 3 | `:1865-1888` `validate_dyn_method`（拒绝路径 `:1882` 的 `EC_N_METHOD`） | dyn 类型集里每个具体行都必须有该方法 | 不接线（计划本意是接 `IP_METHOD`） | 谓词是 `type_has_method(get_type_name(ti), method_ni)`，即逐具体行按名拼接方法表做成员判定，不是“原子类是否有方法面”。实测 int 和 string 候选行今天也会发 N08（探针 D1/D4：`d : dyn = 5; d.nosuch()` 得到 N08）。类级门 `permits(kind_of(ti), IP_METHOD)` 对 int 行为 0，会抑制这两条既有诊断，等于放宽；反过来给 int 行开位，又抑制不了 NAMED 行的判定。两种接法都不是逐格转录。登记 P3 旋钮 |
| 4 | `:2085-2101` dyn 方法分派（`obj_ti == TI_DYN`） | 结果规则，早退 `TI_UNIT` | 不接线 | 该处谓词是 dyn 行同一性，不是许可。`IP_METHOD` 在 `AK_NAMED` 也为 1，换成 `permits(...) != 0` 会把 struct 方法调用误吞进 dyn 早退分支，返回 `TI_UNIT`，造成大面积行为变化 |
| 5 | `:2498-2502` `EXPR_LET` 建 dyn 集 | 结果规则 | 不接线 | 没有拒绝路径 |
| 6 | `:2674` `EXPR_ASSIGN` 建 dyn 集 | 结果规则 | 不接线 | 没有拒绝路径 |

### 5.5 汇总

18 个候选站点，1 个接线（索引后备门），17 个不接线，逐条实测理由如上。
收紧清单为空，本批没有“旧接受、新拒绝”的条目。放宽面为空，三层突变和全部判据可以作证。

---

## 6. 零行为变化方法（沿用 Task 4 的同源双编译器对照）

- 基线是接线前的编译器二进制。Task 4 完成态冻结拷贝在 `/tmp/p2b5_base_bin/`：corec `b3a1a6b2…a60b5`，corearch `31d70900…5e39`，与 `build/` 逐字节相同。用基线跑当前源码，对照用新二进制跑同一份源码。两侧输入逐字节相同，因此差异只可能来自编译器行为。cwd 为仓库根，逐档 `clean-cache`。
- 行为回归的对照：用旧二进制再跑一遍 `test_iface_ops.py`，把 COREC 换成冻结基线，脚本为 `/tmp/p2b5_oldbin_test.py`。结果 60/60，输出与新版 `cmp` 逐字节相同。
- 编译器自源：补测“旧加旧”，`/tmp/p2b5_oldtree/` 用 `jj file show -r @-` 复原 4 个改动文件，其余同源。与“新加新”的差异恰好是 2 条既有 TF01 的行号 +11，见 §2 判据 4b，零新增诊断。

---

## 7. 突变控制（计划要求的“有自测”实证；本报告自跑，可复跑）

探针是在 `iface_registry.cr` 的 `AK_INT` 条目 ops 中加上 `iface_bit(IP_INDEX)`，一行，带 `PROBE-M1` 标记。这正是本 Task 最容易放宽的方向：给非容器类开索引许可。重建后：

```
FAIL ops.index_permit_set:            got 0 want 1     ← 表侧（Task 4 的许可集哨兵）
FAIL idx.gate_deny_covers_fallback:   got 1 want 0     ← **集等价判据**（逐行枚举）变红
FAIL idx.infer_int_denied_diag:       got 0 want 1     ← **端到端**：门不再报诊断
FAIL idx.infer_int_denied_code:       got -1 want 10001← 诊断消失（10001 = EC_TK_INDEX）
197/201 type-engine cases passed  (rc=1)
[FAIL] t5_neg_index_int: expected rejection, got rc=0（静默放行 = 放宽面复活）  ← 真实源编译面
59/60 passed  (rc=1)
```

四层同时失败：表侧、集合等价、经真实 `infer_expr` 的端到端、真实 `.cr` 源。这说明新用例确实能发现问题，门也确实在读表，不是接线后仍硬编码的空转。复位时用 `cp` 恢复探针前副本，`cmp` 逐字节相同，`grep -c PROBE` 为 0。重建后 201/201、60/60、ELF 哈希复原，`build/corec` 和 `build/corearch` 的 sha256 与探针前逐字节相同（`c22ff720…a0d54` / `31d70900…5e39`），说明探针零残留，构建确定性成立。该探针是本 agent 自写自撤的临时改动，不是还原既有工作，先例是 Task 2/3/4 的同类钳位实验。

---

## 8. 事实表（供 Task 7 Step 5 直接使用：容器面四行）

| 序号 | 现状宽松面（行号为接线前） | 表中格 | 现状诊断 | 本批处置 | P3 收紧建议 |
|---|---|---|---|---|---|
| A | range 索引的非数组落空不报错地 `:2611-2628`，串、切片、int range 得到 `TI_UNIT` | `IP_INDEX_RANGE` 恰为 {sequence} | 无，探针 I14-I16 rc=0 | 不接线（无诊断，门恒真） | 落空分支加诊断，或者把“串 range”定为 slice 语义。这是语义裁决，须先有全语料证据 |
| B | 索引表达式类型不校验，`:2608` 的 `idx_ti` 没有消费者 | 没有双侧位；`IP_INDEX` 是容器侧位 | `a[true]` rc=0，既有登记，Task 4 §7#6 | 本批未动 | 索引侧另设“须为 int”位。`IP_INDEX` 不能兼职，因为 ALL 语义的 indexee 位与 ANY 语义的容器位语义不同 |
| C | 字段落空不报错地 `:2603`，非 NAMED/TUPLE 得到 `TI_UNIT` | `IP_FIELD` 恰为 {product, named} | 无，探针 F3-F12 全 rc=0 | 不接线（拒绝集与落空集同集） | 落空分支加诊断（TS/TK 系），此时 `IP_FIELD` 才成为可推翻判定的门 |
| D | 转换无校验 `:2932`，除 PTR 结果规则外恒等 | `IP_AS` 对全 13 类置 1 | 无，探针 A1-A10 全 rc=0 | 不接线（无拒绝路径） | 转换合法性矩阵（源到目标的允许表）。`IP_AS` 目前只是“全许可”的可审计记录 |
| E | dyn 按 ⊤ 近似加逐行方法表判定 `:1865-1888` | `IP_METHOD` 恰为 {dyn, named} | `d.nosuch()` 得到 N08，int/string 行也报，探针 D1/D4 | 不接线（类级门会抑制，等于放宽） | ① 表侧补“方法名乘类型”的二维判定，P3 用户轴；② 解除 dyn 位图 64 上限，spec §3.3 已登记 |

---

## 9. 偏差、计划勘误和需要 lead 过目的 concern

1. 实质问题：计划 Task 5 的“索引 5、字段 4、转换 1、dyn”里，只有 1 处可以零行为变化地接线。差异不是漏做。字段面和转换面在现状完全没有拒绝路径，12/12 和 10/10 探针 rc=0 零诊断。dyn 面的拒绝谓词是逐具体行的方法表成员判定，类级 `IP_METHOD` 门要么抑制既有 N08，要么吞掉 struct 方法调用。如果 lead 期望“把表当门装上去”，哪怕恒真，请明确。按 Task 4 先例 (d)，本报告一律不装空转门，并给出逐条实测理由。可选替代口径见 §5.5 和 §8。
2. 计划 Step 2 的“其后保留原后备”按字面执行会报两条 TK01。`check_error` 没有同码同位置折叠，实读 `diag.cr` 确认。本报告采用“门体即原后备调用”。如果 lead 另有裁决，例如保留双调用并接受诊断计数变化，需要回滚本处 3 行改动（`checker.cr:2668-2670`）。
3. `never` 通道未涉及，属于 Task 6 面。本批索引门的可达集分析覆盖全部现有类型行，包括 `TI_NEVER` 行，结果与现状同为拒绝。selftest 逐行枚举自动涵盖，不需要单列。
4. 行号口径修正：Task 4 报告记 TF01 在 `9361/9476`，本批实测基线（旧二进制加 @- 源）为 `9362/9477`，差 1 行，可能是 Task 4 报告取值时点早于其最后一次改动。本报告一律用自测值：基线 `9362/9477`，现址 `9373/9488`，位移等于 checker.cr 净增 11 行。
5. 不做 `CIR_CACHE_VER` bump。本批不改 IR 发射面，ELF 逐字节、影子、`.ccr` 全部相同，缓存内容不可能不同。沿用 Task 4 的同一结论：TODO #5 家族只在发射面变更时 bump。
6. 计划文件未改（`docs/superpowers/plans/…`）。plan-p2b 仍活跃，避免并发修改同一文件。本报告的变化表 §1.1 可以作为其回填输入。
7. `tests/suite/*.cr.{out,rc}` 共 64 个 scratch，是他人产物，本批未删未入库，路径限定可以核对。

---

## 10. 未覆盖面与交接

1. P3 旋钮已就位：`IP_INDEX_RANGE`、`IP_FIELD`、`IP_METHOD`、`IP_AS` 四位都已填好且未接线，注释逐位注明理由。P3 收紧时的动作是“在落空或拒绝分支加诊断，并把该分支的谓词换成查表”，表数据不需要改，或者按 §8 的建议重构位。
2. 性能面：索引门增加一次 `iface_kind_of`、一次 `iface_entry`（13 条线性扫描）和位构造。这些只在索引表达式的后备路径即拒绝路径执行，不在许可路径执行，因为三个结果分支在门之前 return。编译耗时回归未见，全套回归通过。
3. `iface_satisfies`、尺寸对齐、横切轴仍然零消费者，Task 7 收口时并入未覆盖面登记。
4. 提交链：Task 2 `31143cd0`，Task 3 `6d2790cd`，Task 4 `a99ee825`，Task 5 见 §11。

---

## 11. 提交

`7145eea5`（change `svxoxtun`）。

提交信息：`refactor: R2 P2b Task 5——容器面接线（唯一可零行为变化接线点 = 索引后备拒绝 ← IP_INDEX 查表；字段/转换/dyn 三面逐条实测无拒绝路径或谓词非类级位 ⇒ 不接线并登记 P3 旋钮；集等价全行枚举 + 三层突变实证）`

路径限定 5 个路径，`jj show --stat` 实核为 210 insertions / 8 deletions：`src/compiler/checker.cr`（13）、`src/compiler/iface_registry.cr`（23，注释）、`src/compiler/type_selftest.cr`（110）、`tests/selfhost/test_iface_ops.py`（68）、`src/ci/run.sh`（4）。未入库的是 `tests/suite/*.cr.{out,rc}` 共 64 个他人 scratch，提交内该类文件计数为 0；本报告 `docs/archive/sdd/p2b-task5-report.md` 也不入库，该目录不受版本控制。工作副本 `(@)` 为 `833c1358`（空），父提交为 `7145eea5`。

---

## 12. 证据命令速查（可复核）

```bash
# 判据 1/2
nice -n 19 python3 build_selfhost_native.py            # rc=0 + 3 守卫 clean
nice -n 19 ./build/corec selftest-types | tail -1      # 201/201
# 判据 3（cwd = 仓库根）
nice -n 19 ./build/corec clean-cache && nice -n 19 ./build/corec build tests/suite/ptr_arith.cr -o /tmp/x --static && sha256sum /tmp/x
# 判据 4（同源双编译器对拍；$1=二进制 $2=落盘目录）
nice -n 19 python3 /tmp/p2b5_run.py /tmp/p2b5_base_bin/corec /tmp/p2b5_base
nice -n 19 python3 /tmp/p2b5_run.py ./build/corec              /tmp/p2b5_final
diff -r /tmp/p2b5_base/corpus /tmp/p2b5_final/corpus     # 空
diff -r /tmp/p2b5_base/shadow /tmp/p2b5_final/shadow     # 空
diff -r /tmp/p2b5_base/ccr    /tmp/p2b5_final/ccr        # 空
cmp    /tmp/p2b5_base/compiler.txt /tmp/p2b5_final/compiler.txt   # IDENTICAL
# 旧×旧（@- 源复原）→ 与新×新只差 2 条 TF01 行号
cd /tmp/p2b5_oldtree && nice -n 19 /tmp/p2b5_base_bin/corec check src/compiler >| /tmp/p2b5_oldxold.txt
# 判据 5/6/7
for t in test_compile test_purity test_ccr_v7 test_type_engine test_iface_ops test_lsp test_slice_bounds; do nice -n 19 python3 tests/selfhost/$t.py | tail -1; done
# 现状探针（接线前后 44 例逐字节同）
nice -n 19 python3 /tmp/p2b5_probe.py /tmp/p2b5_base_bin/corec >| /tmp/p2b5_probe_base.txt
nice -n 19 python3 /tmp/p2b5_probe.py ./build/corec            >| /tmp/p2b5_probe_new.txt
```

基线取值口径：ELF、`.ccr`、语料、影子、自源诊断的基线全部在接线前取得。使用 `build/corec`（Task 4 完成态）的冻结拷贝 `/tmp/p2b5_base_bin/`（`b3a1a6b2…` / `31d70900…`），在同一构造路径和 `clean-cache` 下实测。`.ccr` 四个哈希另与 Task 1 到 4 报告值逐字一致，跨批可比。
