# R2 P2a Task 2（F2）报告：数组长度 N 迁为常量档长度约束

状态：完成，判据全部通过。
提交：jj change `unlquzwxlwuyruyskpqolyoqsmoqtmxv`（短 `unlquzwx`），commit `b36d8e76f972d8a5444099d61595c932eebb1321`（短 `b36d8e76`）。路径限定 2 个文件，+162/-19：`src/compiler/checker.cr`（+104/-19）、`src/compiler/type_selftest.cr`（+58）。
用户裁决落点：F2 采用“常量档长度约束”，保持现状语义，不留不报错地缺口。不是放宽，也不是收紧。

---

## 1. 判据总表

| 序号 | 判据 | 结果 | 原始证据 |
|---|------|------|----------|
| 1 | `selftest-types` 全部通过 | 85/85（77 基线加 8 个新用例，见 §7） | §3.1；`tests/selfhost/test_type_engine.py` 通过 |
| 2 | ELF 与基线逐字节相同 | IDENTICAL（`95084e7b…d475`） | §4 |
| 3 | `.ccr` 实测（冷缓存，逐语料 clean-cache） | 3 个语料全部 IDENTICAL，pre/post sha256 逐字节相同 | §5 |
| 4 | `test_ccr_v7` | 24/24 passed | §6 |
| 5 | `test_compile` | All selfhost compile tests passed. | §6 |
| 6 | 回归抽样（14 个套件） | 全部通过，0 失败 | §6 |
| 7 | 行为等价（P1 三档语料） | 35 个文件 rc 与 P1 记录逐文件一致，即 RC-IDENTICAL；影子对拍 `agree=15476 / 15476`，`old_stricter=0`、`old_looser=0`、`unknown=0` | §6.2 |
| 8 | 拒绝语义（探针 D/G 形态） | 异长报 `error[TF01] Array length constraint not satisfied`，rc=1；同长输出 `ok`，rc=0 | §3.3 |

---

## 2. 实现：数组分支前后对照、约束语义、调用点

### 2.1 `type_equal_core` 的 `TYP_ARRAY` 分支（N 从身份中迁出）

改前（`checker.cr`）：

```core
        if k1 == TYP_ARRAY && k2 == TYP_ARRAY {
            if type_equal_core(get_type_data(t1), get_type_data(t2)) {
                if get_type_extra(t1) == get_type_extra(t2) {   // ← N 在身份内
                    return true;
                }
            }
            return false;
        }
```

改后，身份只判结构，即元素，与引擎面一致，桥接 `AK_SEQUENCE` 的参数链不含 N：

```core
        // F2（R2 P2a Task 2）：本分支**不比 N**——N 已迁出类型身份（与引擎侧一致：桥接的
        // AK_SEQUENCE 参数链不含 N）。长度拒绝语义由 array_len_constraint_ok 在**判定点**
        // 显式补检（type_compat_strict）；身份面只判结构（元素）。
        if k1 == TYP_ARRAY && k2 == TYP_ARRAY {
            return type_equal_core(get_type_data(t1), get_type_data(t2));
        }
```

`type_equal_core` 其余 7 个分支，即 NAMED、TUPLE、REF、PTR、SLICE、GENERIC_APPLY、GENERIC_PARAM，零改动。递归调用点仍有 6 处，数组分支的递归保留。

### 2.2 `array_len_constraint_ok`（新增具名约束，N 的唯一判定点）

```core
fn array_len_constraint_ok(ti_a: int, ti_b: int) -> int   // 1 = 满足；0 = 违反
```

- 语义，本批为常量档：沿两个类型的结构对应位置下钻。下钻位置覆盖身份递归位：数组元素、指针元素、引用元素、切片元素、元组字段、泛型应用实参。在数组位置比较 N，即 `extra` 字面量，不等返回 0。其余情形，包括异 kind、异元数、非数组构造子，长度面无约束，返回 1。
- “同形”限定，评审 M1：仅指递归位覆盖，不指比较项相同。REF 的 `extra`（mut 标记）、TUPLE/APPLY 的元数、APPLY 的基型行号等非长度面一律归身份判定，约束有意不重复。反向也不对称：PTR 的 `extra`（地址空间位 asp）身份本来就不比，约束同样不引入。
- 为什么必须下钻：身份去掉 N 后，N 嵌在非数组构造子内部的位置不再有任何判等负责，例如 `[[int;3];2]` 元素位、`G<[int;3]>` 实参位、`*[int;3]` 元素位、`(int, [int;3])` 字段位。不下钻就是不报错地放宽。覆盖面由 4 条下钻用例逐族钉住，见 §7。
- 无环：`TYP_NAMED`/`TYP_GENERIC_PARAM`/`TYP_BASE`/`TYP_DYN` 不下钻，深度等于类型嵌套深度。
- 边界，如实登记：符号档和动态档未实现，属于 P3 面。本批按字面量比较 extras，不下钻异 kind 或异形；该面由身份判定的 kind 和参数结构比较负责，本函数不越权给 0，因此不误拒。
- `GENERIC_APPLY` 的基型不下钻，与身份一致。身份对 base 只做行号相等比较，不递归，恒等语义保持。

### 2.3 判定点接线（`type_compat_strict` 加 `diag_type_incompatible`）

```core
fn type_compat_strict(ti_a: int, ti_b: int) -> int {   // 1 = 兼容；0 = 身份不匹配；-1 = 长度约束违反
    if !type_equal(ti_a, ti_b) { return 0; }           // **总是先调 type_equal**（影子站点采样面不变）
    if array_len_constraint_ok(ti_a, ti_b) == 0 { return -1; }
    return 1;
}
fn diag_type_incompatible(verdict: int, code: int, what: string, line: int, col: int) {
    if verdict == -1 { check_error(code, "Array length constraint not satisfied", line, col); }
    else { check_error(code, what, line, col); }
}
```

| 站点 | 位置（改后行号） | 语义 | 改动 |
|---|---|---|---|
| 1 | `checker.cr:942` | hotpatch 返回类型一致 | `!type_equal(…)` 改为 `type_compat_strict(…) != 1`，并分列成因措辞 |
| 2 | `:1180` | `unify_types` 泛型实参已绑定路径（探针 G） | `return type_equal(…)` 改为 `return type_compat_strict(…) == 1` |
| 3 | `:1193` | `unify_types` 泛型应用基型比较 | 同上，`!= 1` 时 `return false` |
| 4 | `:1208` | `unify_types` 后备结构等价 | 同上 |
| 5 | `:1448` | 函数体返回类型（探针 D） | 同上，并分列成因措辞；`is_flow_fn` 和泛型形参守卫原样保留 |
| 6 | `:1643` | 赋值兼容，`EXPR_BINARY + OP_ASSIGN`，不可达 | 同 1 |
| 7 | `:2036` | if 分支类型合并 | 同 1，`TI_NEVER` 守卫保留 |
| 8 | `:2370` | 赋值兼容，`EXPR_ASSIGN` | 同 1 |

- 判定点条件等价性，也就是“行为完全一致”的论证：旧判定点否决等价于 `¬type_equal_old`。新判定点否决等价于 `¬type_equal_new ∨ ¬constraint`。`type_equal_new` 是旧身份去掉 N 比较，`constraint` 只覆盖旧身份在递归位上的 N 比较，数组位比 `extra`，其余构造子仅透传下钻；REF 的 `extra`/mut、TUPLE/APPLY 的元数、APPLY 的基型行号等非 N 比较仍留在身份内，零改动；APPLY base 只比行号，也与身份一致。因此 `type_equal_old` 等价于 `type_equal_new ∧ constraint`，两者否决集合恒等。
- 码不变，仅成因分列：-1 是长度约束违反，使用专属措辞；0 使用原措辞。错误码仍为 TF01、TA01、TC02。实证：`src/compiler/main.cr` 的两条已知 TF01 误报（`lits_copy` / `ty_memo_slot_no_grow`，见 `ty_shadow.cr` 头注“已知误报面”）改动后仍打印原措辞 `Function return type mismatch`。
- 不误拒：`array_len_constraint_ok` 对异 kind、异元数一律返回 1。只有身份可以通过但 N 不匹配时才返回 -1，使用长度措辞。负控用例 `f2.nonarray_no_constraint` 钉住。

---

## 3. 红态输出（TDD）

### 3.1 断言级红（桩为恒满足，即无约束，也就是 F2 缺口本身）

先落临时桩 `fn array_len_constraint_ok(...) -> int { return 1; }`，即现状无约束行为，加 8 条用例，真实变红：

```
PASS f2.same_len_ok
FAIL f2.diff_len_reject: got 1 want 0          ← 异长看起来"满足"：F2 缺口的直证
PASS f2.engine_len_agnostic
FAIL f2.nested_elem_reject: got 0 want 1
FAIL f2.genapply_arg_reject: got 0 want 1
FAIL f2.ptr_elem_reject: got 0 want 1
FAIL f2.tuple_field_reject: got 0 want 1
PASS f2.nonarray_no_constraint
80/85 type-engine cases passed                 ← rc=1
```

下钻 4 例是双断：“同结构同长返回 1”且“同结构异长返回 0”。桩态下后半不成立，因此失败。

### 3.2 行为级红（身份去 N、判定点未接线，即不报错地通过）

`probe_d` 是 P1 探针 D 的最小复现：`fn ret4() -> [int;3] { b : [int;4] = [1,2,3,4]; return b; }`。

- 改前，现状：`error[TF01]: Function return type mismatch`，rc=1。
- 去 N 后未接线：`ok`，rc=0。这正是 F2 现象，替换即不报错地通过。
- 接线后，最终态见 §3.3。

### 3.3 接线后（最终态），拒绝语义保持和措辞

```
$ nice -n 19 ./build/corec check /tmp/p2a_t2/probe_d.cr          # 异长（站点 5）
error[TF01]: Array length constraint not satisfied
rc=1
$ nice -n 19 ./build/corec check /tmp/p2a_t2/probe_same.cr       # 同长（对照）
ok
rc=0
$ nice -n 19 ./build/corec check /tmp/p2a_t2/probe_assign.cr     # 异长赋值（站点 8）
error[TA01]: Array length constraint not satisfied
$ nice -n 19 ./build/corec check /tmp/p2a_t2/probe_if_diff.cr    # 异长 if 分支（站点 7）
error[TC02]: Array length constraint not satisfied
$ nice -n 19 ./build/corec check /tmp/p2a_t2/probe_if.cr         # 同长 if 分支（对照）
ok
```

---

## 4. ELF 判据原始输出（冷缓存）

```
$ nice -n 19 ./build/corec clean-cache
cleaned .core/cache/cir/
$ nice -n 19 ./build/corec build tests/suite/ptr_arith.cr --static -o /tmp/p2a_t2_bin
 -> /tmp/p2a_t2_bin
$ cmp /tmp/r1t4_base_bin /tmp/p2a_t2_bin && echo ELF-IDENTICAL
ELF-IDENTICAL
$ sha256sum /tmp/r1t4_base_bin /tmp/p2a_t2_bin
95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475  /tmp/r1t4_base_bin
95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475  /tmp/p2a_t2_bin
```

自举构建三阶段守卫（`build_selfhost_native.py`）：`[GUARD] corec / corearch / corelsp: build log clean (error[ = 0, undefined = 0)`，编译器自身语料零诊断，包含措辞面。

---

## 5. `.ccr` 变化实测（冷缓存；允许变化，但必须报告）

方法：改动前，父提交 `8c9d773f`，即 Task 1 收口态，逐语料 `clean-cache` 后冻结 pre。改动后用同一方法重放 post，每次先 `clean-cache`，cwd 为仓库根。Task 1 评审实测过，缓存态会让同一二进制二次运行产出不同 `.ccr`。

| 语料 | pre sha256 | post sha256 | 判定 |
|------|-----------|-------------|------|
| `tests/suite/ptr_arith.cr` | `bb9cbdb87f4f…4b5` | 同左 | IDENTICAL |
| `tests/suite/at_test_struct.cr` | `53ebcf122deb…122` | 同左 | IDENTICAL |
| `tests/suite/generics_test.cr` | `2132d565778c…c42` | 同左 | IDENTICAL |

结论：实测未变。归因：本改动零类型行分配，约束只读 `g_types` 和 `g_gen_apply_data`，不调用 `alloc_type`，行号空间和 IR 生成路径都不动，索引不位移。

覆盖缺口，如实登记：未单独做自指语料的 `.ccr` pre/post 对比，pre 二进制未保留。替代证据是自指语料 `src/compiler/main.cr` 影子对拍 4029 个判定全部 agree（§6.2），加上零分配归因。

---

## 6. 回归和 P1 语料对拍

### 6.1 套件（14 个，全部通过）

| 套件 | 结果 |
|---|---|
| `test_ccr_v7` | 24/24 passed |
| `test_compile` | All selfhost compile tests passed. |
| `test_type_engine` | 通过 `test_selftest_types_all_pass` |
| `test_hit_table` | 24/24 passed |
| `test_impl` / `test_borrow` / `test_slice_bounds` | 7/7、7/7、7/7 |
| `test_live_ranges` / `test_global_init` | 13/13、15/15，双路径 |
| `test_lexer_parity` / `test_dex_type` | 通过，TF01 门按码级匹配；5/5 |
| `test_pointer_safety` / `test_region_cfg` / `test_lsp` / `test_backend_bootstrap` | 通过、22/22、ALL PASS(9)、通过（O2 冒烟 rc=7） |
| `bootstrap/test_pipeline` `test_borrow` `test_generics` `test_modules` `test_apx_tag` `test_dex_arith` `test_dex_type` | 29/29、4/4、3/3、通过、5/5、14/14、3/3 |

### 6.2 P1 三档语料复跑（影子通道；F2 面看 old_stricter）

对照物是 P1 语料日志 `/tmp/r2p1t3/all_tiers2.txt`。Tier 1 为 `tests/suite/*.cr`，Tier 2 为 `src/compiler/main.cr` 和 `_import.cr`，Tier 3 为 `src/compiler/ccr_io.cr` 和 `src/format/elf/elf.cr`，共 35 个文件。

- rc 逐文件与 P1 记录一致，即 RC-IDENTICAL，包含既有非类型面错误：`ptr_arith` rc=1，报 `error[B04]` 借用检查，改动前后相同；`main.cr` rc=1，两条已知 TF01 误报，见 §2.3；`at_test_mini4/6` rc=139，TODO #16 嵌套 fn，不是本批。
- 影子计数合计：`decisions=15476 agree=15476`，`old_stricter=0`、`old_looser=0`、`unknown=0`，逐文件零差异。P1 时代的 F2 证据，即探针 D/G 的 `old_stricter=1`，在语料层面本来就 0 触发。改动后身份和引擎在 N 面已经一致。探针 D 影子为 `decisions=74 agree=74 old_stricter=0`，P1 时该处为 `old_stricter=1`，F2 面消除。
- 站点覆盖同报，P1 交接要求：语料内 `fn-body-ret=16/21/25/717`、`if-branch=7/7/7/332`、`assign-node=51/50/55/2980`、`generic-apply-base=2`（generics_test）。站点 1/2/4/6 语料 0 命中，与 P1 记录一致，由探针面覆盖。
- 自指语料 `src/compiler/main.cr`：`decisions=4029 agree=4029 unknown=0`。P1 记录 unknown=1，F1 已消除，与 Task 1 评审实测吻合。

---

## 7. 用例清单（`type_selftest.cr` 追加 8 条；85 等于 77 加 8）

brief 的 3 条逐字落位，只把内联 `alloc_type` 提为局部变量，以便双断：

| 用例 | 断言 |
|---|---|
| `f2.same_len_ok` | 两个不同行的同长 `[int;3]` 返回 1，约束不是 ti 同一性 |
| `f2.diff_len_reject` | `[int;4]` 对 `[int;3]` 返回 0 |
| `f2.engine_len_agnostic` | `ty_equiv(sh_term_of_ti([int;4]), sh_term_of_ti([int;3]))` 返回 1，N 不进入身份 |

超出 brief 的 5 条，覆盖下钻承重面和负控，理由见 §2.2：

| 用例 | 断言 |
|---|---|
| `f2.nested_elem_reject` | `[[int;3];2]` 同结构同长返回 1，`[[int;4];2]` 对 `[[int;3];2]` 返回 0 |
| `f2.genapply_arg_reject` | `G<[int;3]>` 自反返回 1，`G<[int;4]>` 对 `G<[int;3]>` 返回 0；base 裸分配不入侧表 |
| `f2.ptr_elem_reject` | `*[int;3]` 自反返回 1，`*[int;4]` 对 `*[int;3]` 返回 0 |
| `f2.tuple_field_reject` | `(int,[int;3])` 自反返回 1，`(int,[int;4])` 对 `(int,[int;3])` 返回 0 |
| `f2.nonarray_no_constraint` | `[int;3]` 对 `int` 双向返回 1，防止“一律拒绝”的退化实现 |

用例数偏离计划：计划按 3 条估 80，实际落 8 条，得到 85。Task 1 有同类先例，77 而不是 76，评审确认合规。请评审确认本条合规性。

---

## 8. 交接（Task 3）和关注项

交接，Task 3 替换 `type_equal` 时：

- 站点侧的 `type_compat_strict` 和 `diag_type_incompatible` 绕不过。Task 3 换掉 `type_equal` 实现后，长度拒绝由站点检查独立提供，不依赖身份实现。不要把 N 再放回身份，否则与引擎面再次分叉，P1 差异会重现。
- `type_equal_core` 改名为 `type_equal_legacy` 时，其数组分支已经是 N-free，与引擎 `ty_equiv` 在 N 面天然一致，探针 D 现在 agree，对拍复跑可以直接进行。
- 三档语料 rc 和影子计数，见 §6.2，已经是 F2 后基线，Task 3 可以逐文件对比。站点覆盖须同报。

关注项，交下游和评审：

- C-1，设计选择，请评审核：约束函数按“身份递归位同形”下钻，约 40 行，而不是只比顶层数组。理由是不下钻时，`G<[int;3]>` 对 `G<[int;4]>`、`*[int;3]` 对 `*[int;4]`、`(int,[int;3])` 对 `(int,[int;4])`、`[[int;3];2]` 对 `[[int;4];2]` 会在身份去 N 后不报错地通过，等于放宽，违反“不是放宽”。等价性见 §2.3 论证。如果评审认为超出 brief 的“两侧都是 `[T;N]`”字面定义，收窄就要接受上述放宽面，不建议。
- C-2，措辞改动的影响面：长度约束违反时措辞为 `Array length constraint not satisfied`，码不变。非长度成因保留原措辞，`main.cr` 两条已知 TF01 误报仍打印原措辞，是实证。仓库内 TF01 匹配均为码级，`test_dex_type` 和 `test_lexer_parity` 都通过；如果有按措辞匹配的外部工具，需要知悉。
- C-3，参数面无诊断出口：站点 2/3/4，即 `unify_types`，已经补约束，但其返回值在 `infer_gen_call` 被丢弃，F3 等于 TODO #20，改动前也如此，旧 `type_equal` 判 false 同样被丢弃。参数位异长当前没有诊断，不是本任务引入。约束在这里的价值是 Task 3 替换后该面不回退，F3 一旦接线即生效。
- C-4，用例数偏离：见 §7，85 而不是 80，请评审确认。
- C-5，未实测面，如实登记：① 自指语料 `.ccr` 的 pre/post 未直接对比，pre 二进制未保留，因此以“零类型行分配”归因加自指语料影子全 agree 替代。Task 4 收尾已直接采样收口：用 Task 3 终态二进制（pre）乘 Task 3 冻结源树，与 Task 4 终态二进制（post）乘同一冻结源树两路编译 `src/compiler/main.cr`，`.ccr` 逐字节 IDENTICAL，`e94e488f10c4…`；另用 post 乘真实 Task 4 源树隔离“源内容变化”分量，增加 168 条指令，属于新增用例的预期变化，不是编译器影响。② 全语料诊断文本的 pre/post 逐条 diff 未做，以 P1 三档 35 文件 rc 逐文件一致加自举三阶段守卫 `error[ = 0` 替代。
- C-6，站点 6：`EXPR_BINARY + OP_ASSIGN` 不可达，parser 已降为 `EXPR_ASSIGN`。按 8 个站点对称接线，零风险；去留仍归 Task 3/4 裁决，TODO #17 已登记。

---

## 9. 评审核定（Task 2 评审为 Approved，spec 已标完成；0 个 Critical，只有 1 个 Minor）

评审裁决：C-1 保留下钻，评审给出结构归纳证明和嵌套位实证，并明确 Task 3 不得把 N 放回身份；C-3 和 C-4 都成立，8 条用例判为合规偏离。M2，即补 REF/SLICE 下钻位和 0/-1 分派用例，归 Task 4 收紧清单，不在本任务范围。

M1 是 Minor，注释精度，已收口。改前头注称下钻位“与 `type_equal_core` 递归同形”，但 REF 处实际不同形，身份另比 `extra`/mut，约束有意不重复。

- 提交：jj change `qswkslpvopwu`（短 `qswkslpv`），commit `507daf7a5d1f`（短 `507daf7a`），路径限定 1 个文件 `src/compiler/checker.cr`，+8/-1，纯注释。
- 改动（`checker.cr:247-253`）：补“同形”限定。① 仅指递归位覆盖，不指比较项相同；② REF 的 `extra`（mut）、TUPLE/APPLY 的元数、APPLY 的基型行号等非长度面一律归身份判定，约束有意不重复；③ 反向不对称，PTR 的 `extra`（地址空间位 asp）身份本来就不比，约束同样不引入；④ 末句“切勿据‘同形’推断两者判等项一致（评审 M1 收口）”。同时把易腐的绝对行号引用改为符号定位点点，即 `type_equal_core` 的 TYP_REF 分支和 `infer_expr` 的指针升格分配点。
- 复验，超出“无需重建”的最低要求：`build_selfhost_native.py` 得到 BUILD SUCCESS，三阶段 GUARD `error[ = 0, undefined = 0`；`selftest-types` 得到 85/85。其余判据不重跑，注释不进入代码，词法器会剥离。
- 报告同步：§2.2/§2.3 的“同形”表述已按 M1 同款限定改写，等价性论证相应写明“非 N 比较仍留在身份内，零改动”。
