# R2 P5 Task 3b 报告：不变槽元素三态（`te_elem_cmp`），P5 Task 3 §6 残留面收口

日期：2026-09-13。起点：`5a333e0c`，P5 Task 3 收口注；工作副本为空，`jj status` 干净；起点 `build/corec` 为 `10f8d44d…`。
产物：`build/corec` = `f0862d7091513592705f8874bf7c2bb7ba1e79c33695927590145a0bd2639159`。多次构建逐字节相同，包含注释面微调后的重建；注释不进入代码，重建 sha 不变。
报告口径：数字全部为本实例实测，命令和原始输出路径见 §8；未实测的标为“未测”。

---

## 0. 概要

P5 Task 3 停条件②登记的残留面是 `[NA;2]` 对 `[NB;2]` 等不变槽元素非同形时返回 -1 并回落。本步收口：`tt_list_variance_at` 的不变槽分支从“非同形返回 -1 加 uncovered”改为“同形返回 1；否则走 `te_elem_cmp` 三态”。

- 两侧都是身份令牌（AK_UNIT 且 b 大于等于 0）时，按节点同一性判断。
- 两侧都是类型项时，走引擎 `ty_equiv`，0/1/-1 直传。
- 其余情况，即既不是令牌也不是类型项，返回 -1 加未覆盖面，域外不猜。

残留探针 n13/n17/n18 从 `unknown_engine=1 replace_unknown=1` 变为 0/0，rc 和诊断逐条不变。全语料零翻转。新增突变控制 4 条，逐条转红；M2 中和类型项面后，残留复红 1/1，是因果硬证据。另登记一项预存 ¬ 面过判，本步揭开，不是本步引入，不影响生产面，见 §7。

---

## 1. RED 基线（复用 T3 §6.1 交接条目；冻结基线 `/tmp/p5t0/base/corec`）

探针为 `/tmp/p5t3/probes/n13|n17|n18*.cr`；命令为 `corec check F --type-shadow --type-shadow-dump D`，逐档 `clean-cache`。

| 探针（形态） | rc | 诊断 | RED（T3 后二进制） | POST（本步） | 冻结基线 |
|---|---|---|---|---|---|
| n13 `[NA;2]` 对 `[NB;2]` 赋值 | 1 | TA01 Assignment type mismatch | `unknown_engine=1 replace_unknown=1` | 0 / 0 | 同诊断，回落 legacy |
| n17 `*NA` 对 `*NB` 赋值 | 1 | TA01 | 1 / 1 | 0 / 0 | 同诊断 |
| n18 `(NA,int)` 对 `(NB,int)` 赋值 | 1 | TA01 | 1 / 1 | 0 / 0 | 同诊断 |
| n13 计数面 | — | — | `decisions=80 agree=79` | `decisions=80 agree=80` | — |
| n17 / n18 计数面 | — | — | 75/74 · 76/75 | 75/75 · 76/76 | — |

因果钳位，突变 M2，见 §3.3：把类型项面中和回旧行为，即 `te_is_arg_term` 分支返回 -1 加 uncovered，三个探针逐条复红 1/1；复原后 0/0。残留关闭的因果链由突变控制钉死，不只是“改完变好了”。

---

## 2. 实现（`src/compiler/type_engine.cr`）

### 2.1 新增判定核 `te_elem_cmp`（三态，放在 `te_named_pair` 之前）

```
fn te_elem_cmp(p: int, q: int) -> int {
    if p == q { return 1; }
    if te_is_name_token(p) != 0 && te_is_name_token(q) != 0 { return 0; }   // ① 令牌：节点同一性
    if te_is_arg_term(p) != 0 && te_is_arg_term(q) != 0 { return ty_equiv(p, q); }  // ② 类型项：引擎等价
    g_ty_uncovered = 1;                                                     // ③ 域外：不猜
    return -1;
}
```

- ① 令牌按节点同一性判断，禁止 `ty_equiv`。令牌不是类型集。`tt_atom(AK_UNIT, ni, -1)` 与 `tt_atom(AK_UNIT, row, -1)` 同形，走 `ty_equiv` 会把一切 AK_UNIT 同形项判等，属于 P3 Task 1 实测的令牌碰撞类。不同节点即不同名字或标记，确定不同，返回 0。
- ② 类型项按 `ty_equiv`，三态直传。内层域外或预算耗尽返回 -1，由内层置位上抛，本层不吞、不改标。命名、序列、原生元素各按自己的可判定域递归，`[NA;2]` 对 `[NB;2]` 在这里经 `te_named_pair` 的身份链判 0。
- ③ 域外：既不是令牌也不是类型项，包括 μ 变元、`¬`、`⊤ₖ`、裸值，返回 -1 加未覆盖面。可达面已证：接口形状面把 `⊤ₖ(序列)` 放进可写 ref 的不变槽，守门例为 `x2.rw_view_unexpressible`，突变 M3 会转红。本步对该面保持 -1。

### 2.2 接线（`tt_list_variance_at` 不变槽分支）

```
} else {
    if tt_type_elem_same(ha, hb) != 1 {          // 同形快路径（含序列 b-忽略规则）保持
        d := te_elem_cmp(ha, hb);
        if d == -1 { return -1; }                // 域外（位已置）/ 内层未知（位由内层置）
        if d == 0 { return 0; }                  // 确定不同 = 已判面（本步收益）
    }
}
```

同形快路径逐位保持，包括 `p == q` 和序列项忽略 b 的结构相等。主流路径零额外开销，`[int;3]` 对 `[int;4]` 作实参仍判等，`t3b.equiv_face_not_crushed`。

### 2.3 注释面同步（文件头①、`tt_list_variance_at` 头注、`te_elem_cmp` 头注）

P0 登记①“不变槽非同形等于未覆盖面”改为已收口，并写明当初不做的理由正是本步给出的排序分派，即令牌和类型项两域。`AK_UNIT` 形态二义，原生 unit 项与令牌同形，作为登记项写入头注；失效方向选择见 §3.3 负控。

---

## 3. 三件证据（协调者裁定）

### 3.1 ① 适用域证明：逐构造点排序表（“链元素都是类型项或身份令牌”）

| 构造子（链） | 槽 0 | 槽大于等于 1 | 依据（构造点） |
|---|---|---|---|
| `AK_SEQUENCE`（数组/切片） | 类型项 | — | `sh_seq_term`，元素为 `sh_term_of_ti` 结果 |
| `AK_PTR` | 类型项 | — | `sh_term_of_ti` 的 TYP_PTR 分支 |
| `AK_REF` | 令牌（mut 标记） | 类型项 | `sh_ref_mut_marker` 加元素项；槽 0 由专有分支判断，走 `tt_list_same`，不经过 `te_elem_cmp` |
| `AK_PRODUCT`（元组/struct） | 类型项 | 类型项 | `sh_tuple_to_product` 加展开层 struct 项 |
| `AK_FN`（接口方法签名） | 类型项 | 类型项 | `sh_iface_fn_term` |
| `AK_SUM`（枚举变体，展开层） | 令牌（枚举名） | 令牌（变体名） | `sh_variant_term`，域和模式两个构造点逐位相同 |
| `AK_NAMED`（命名/应用） | 令牌 | 类型项 | 身份链，先分派 `te_named_pair`，不经过本函数 |

同一 (ak, slot) 上不存在排序混排，因为构造点一致。因此 `te_elem_cmp` 先令牌后类型项的分派与全部位置对齐。域外面 μ、¬、⊤ₖ 只有 ③ 一条出口，保持 -1。自测齿是自测 `t3b.elem_out_of_domain_stays_minus1`、既有 `x2.rw_view_unexpressible`、突变 M3 的 3 个 FAIL。

未覆盖面变化为无。本步不新增任何“判不出”面；唯一的行为方向变化是从 -1（未知）变为 0（确定不同）的可判定面，见 §5 台账。

### 3.2 ② 全语料对拍（72 档：`tests/suite` 加自源加后端/内核加 stdlib 加 examples）

| 面 | 命令 | 结果 |
|---|---|---|
| check rc 分布 | `bash /tmp/p3t0_run.sh check ./build/corec /tmp/p5t3b/parity2/check` | 34 个 0、38 个 1，逐档相同，与 T3 基线逐档比 |
| check 逐档日志 | 同上，逐档 diff 对 `/tmp/p5t3/parity/final_check/logs` | 72 档中只有 2 档有差异：`t2_src_compiler__import.cr` 和 `t3_src_compiler_ccr_io.cr`，只有诊断行号偏移 +174，等于本步自源码新增行数；行内容、码、列、措辞逐字相同；与 T0 到 T2 的 +34/+147 同因 |
| shadow 汇总 | `bash /tmp/p3t0_run.sh shadow … /tmp/p5t3b/parity2/shadow` | `decisions=agree=32988`；`old_stricter=old_looser=unknown=unknown_bridge=unknown_engine=unknown_engine_uncovered=unknown_engine_budget=replace_bridge=replace_unknown=0`；70 档出摘要 |
| shadow 逐档计数 | 同上，逐档 diff 对 T3 基线 | 非自源 65 档逐字节相同；8 个自源档是源码增长，见下；零差异桶 |
| 站点覆盖 | 同上 | `assign-node=… · fn-body-ret=… · if-branch=… · struct-field-type=4 · array-elem-type=0 · generic-apply-base=0`，结构与 T3 同报 |
| 归类 | 自源档增量 | 32917（T3）到 32922，只有引擎函数增加 5 个决策，5 个自源档各加 1；再到 32988，引擎加自测段增加 66，3 档各加 22，`type_selftest.cr` 不入 corearch 两档，因此不变。全部 agree |

判据：没有任何 `old_stricter`、`old_looser`、`unknown*`、`replace_*` 翻转，因此收紧面为 0，放宽面为 0。行为面与冻结基线逐档相同。

### 3.3 ③ 突变控制 4 条和负控（协调者点名两例）

驱动为 `/tmp/p5t3b/mut.py` 加 `/tmp/p5t3b/mut_run.sh`；回滚校验用源 sha256 前后对拍，加二进制 sha 复原，`f0862d70…` 逐字节回到原值。

| 突变 | 内容 | 转红证据 | 残留探针 |
|---|---|---|---|
| M1 | 令牌面中和，两侧都是令牌时返回 -1 | 自测 4 个 FAIL：`t3b.token_slot_variant_diff_zero`、`t3b.unit_token_shape_collision_guard`、两个 witness 过判钉 | 0/0，类型项面未动 |
| M2 | 类型项面中和，返回 -1 加 uncovered | 自测 7 个 FAIL：4 个不变槽 diff-zero 加 `t3b.unit_elem_type_item_face` 加 `t3b.replace_unknown_zero_arr` 加 `param.elem_class_diff_zero` | 1/1 复红 3 次 |
| M3 | 域外守卫去掉，返回 0 | 自测 3 个 FAIL：`t3b.elem_out_of_domain_stays_minus1`、`param.uncovered_flag`、既有 `x2.rw_view_unexpressible` | 0/0 |
| M4 | 分派次序倒置，类型项先判 | 自测 3 个 FAIL：`t3b.unit_token_shape_collision_guard`、既有 `unf.enum_variant_identity_scoped`（复现 P3 Task 1 令牌碰撞）、`t3b.token_slot_variant_diff_zero` | 0/0 |

负控①“同名令牌会得到不同节点吗”：`t3b.token_same_name_same_node`。`sh_name_token(ni)` 两次调用得到同一节点，因为 DAG 去重按五字段键，ni 相同即同节点。`sh_ref_mut_marker(0/1)` 同式。因此“同名不同节点”在结构上不可达，节点同一性比较不可能把同名令牌判成不同。M1 和 M4 的转红面正是该判据的两侧。

负控②“令牌乘原生 unit 项同形”：`t3b.unit_token_shape_collision_guard`。实证 `ty_equiv(unit 项, 令牌) == 1`，是假等，也是令牌碰撞类的直接证据；而 `te_elem_cmp(unit 项, 令牌) == 0`，先判令牌，绝不产生假等；`te_elem_cmp(unit 项, unit 项) == 1`，唯一 unit 节点走快路径。因此“先判令牌”是失效方向的要求，M4 倒置即复现假等和碰撞红例，不是风格选择。

---

## 4. 判据复验（全部本实例实跑；命令和原始输出）

| 序号 | 判据 | 结果 |
|---|---|---|
| 1 | `nice -n 19 python3 build_selfhost_native.py` | rc=0；`build/corec` 为 `f0862d70…`，多构建逐字节相同，含注释微调后重建 |
| 2 | `tests/selfhost/test_backend_bootstrap.py` | rc=0；日志 `error[` 计数为 0 |
| 3 | `./build/corec check src/compiler` | rc=0 |
| 4 | 残留关闭（§1） | n13/n17/n18 的 `unknown_engine`/`replace_unknown` 从 1 变 0，rc 和诊断逐条不变；冻结基线同诊断 |
| 5 | `selftest-types` | 401/401。386 减 1（残留例迁出）加 13（`t3b.*` 段）加 3（witness 合取式拆项）；3 处重钉见 §5 |
| 6 | `test_named_face.py` | 18/18，包含 `residual.*` 两例，T3 交接要求的“行为不变”成立 |
| 7 | 全枚举（57 档：48 个 selfhost 加 9 个 bootstrap，按路径编码日志名） | 57/57 rc=0。首跑 4 例 rc 不为 0，是日志 basename 撞名加不可复现的环境瞬扰，见 §6-3；逐档改名重跑，4 例单跑两次全 rc=0 |
| 8 | ELF canary | `clean-cache` 后 `build tests/suite/ptr_arith.cr --static`，得到 `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`（28822B），IDENTICAL |
| 9 | `.ccr`（两口径乘两语料，冷态） | `ptr_arith` 90823B `fb4a3b59…` / 90966B `592afa31…`；`generics_test` 135341B `ddec1ce6…` / 135484B `cd2af565…`。四件与 T3 后状态逐字节相同；本步零新项行，`te_elem_cmp` 不构造项，T3 的 +640B 归因不变 |
| 10 | `--dump-objects`（`ccr` 口径，`generics_test`） | 逐字节相同，3521 行；基线 `gt_do.txt`/`gt_do_base.txt` 都比对通过 |
| 11 | `.cir` DOT（`generics_test`） | 逐字节相同，165915B |
| 12 | 五个 CI job | `check`/`bootstrap-tests`/`suite`/`selfhost-tests`/`full-bootstrap` 全部 rc=0 |
| 13 | 自举链 | `cmp /tmp/corec2 /tmp/corec3` IDENTICAL，两个文件都是 `0c4b0a9e…`；N06=0；冒烟 42；`--help` rc=1 |
| 14 | 突变控制 | 见 §3.3，4 条转红加精确回滚 |
| 15 | 域外守卫回归 | 既有 `x2.rw_view_unexpressible` 在本步后仍通过，⊤ₖ 落可写 ref 不变槽返回 -1；M3 证明它有自测 |

---

## 5. 翻转和登记（收紧面台账）

| 钉 | 位置 | 处置 | 依据 |
|---|---|---|---|
| `param.unknown_p0`，断言 `[int]` 对 `[str]` 的元素位使 `ty_sub == -1` | `type_selftest.cr:1681` | 重钉为 `param.elem_class_diff_zero`（0）；uncovered 触发器改用仍属域外的面，即 μ 变元作元素 | 不变槽元素异原生类属于确定不同，是语义加强；与 spec §2.2 `sequence<⊤>` 无冲突，后者走 `⊤ₖ` 分支，`[T] <: ⊤_SEQUENCE` 恒 1；legacy `type_equal([int],[str]) = false` 即 0，替换门同结论；M2 覆盖 |
| `t3n.invariant_slot_residual_negative`，断言残留 -1 | `type_selftest.cr:1081` | 删除，断言迁到 `t3b.inv_slot_seq_named_diff_zero`：0 加零未覆盖面 | 残留面已关闭，见 §1 |
| `t3.counterexample_named_variant` 的合取项 `ty_equiv(w,b) == -1` | `type_selftest.cr:3106` | 拆项：`ty_sub(w,b)=1`、可空、覆盖位命名保留；反向和等价改钉 0，即 `t3.witness_reverse_over_claim` / `t3.witness_equiv_over_claim`，另加最小复现 `t3.product_neg_over_claim` | 见下 |

逐条推导，基于实测和代码路径，不是猜测。`w` 是空覆盖反例，等于 `q1 ∪ q2 ∪ q3`。q1/q2 是含自否字面的空析取支，q3 是 `B ∩ ¬R ∩ ¬G`，即变体 B。

1. `ty_sub(B, q1)`：q1 的字面集含异变体令牌，`lit_implies(B, R)` 改前为 -1，令牌不变槽未知；改后为 0，令牌同一性即确定不同。
2. 外层并分支 `x := sub_cover(B, q1∪q2)` 因此改前为 -1 上抛，改后为 0。
3. `ty_sub(B, w)` 改前为 -1，因为 x=-1 上抛；改后为 0。`ty_equiv(w, B)` 随之从 -1 变为 0。

登记：`ty_sub(B, q3) = 0` 改前改后相同，是预存缺陷被揭开，不是本步引入。`sub_cover` 的 product 规则要求逐字面覆盖，撞上 `lit_implies` 的 ¬ 面规则：lp 和 ¬x 同类原子时 `ak_disjoint` 返回 0，判为“不含”。值集语义下 `B ⊆ ¬R` 成立，因为异变体不交，所以这个 0 是过判，应为 1 或至少 -1。本步只是撤掉了原先掩盖它的 -1。影响面实测只在 witness 项：生产 `ty_exhaustive` 走 `tt_norm` 加 `ty_inhabited`，不判包含；`gen_constr_witness_str` 只做 `tt_display`。全语料 72 档零翻转，见 §3.2。因此登记为后续步，即 ¬ 面“异身份原子不交”的加强，本步不修、不近似。自测断言已命名为 `*_over_claim`，并把最小复现 `t3.product_neg_over_claim` 钉成单点；该面加强实施后应转 1 并重钉。

收紧面总数：行为面，即语料 rc、日志、影子，为 0；自测断言面 3 处，见上表，另有登记 1 项。没有放宽面。

---

## 6. 执行偏差（如实登记）

1. ③ 的域外面是可达面。初稿注释写“防御分支”，实测 `x2.rw_view_unexpressible` 是 ⊤ₖ 落可写 ref 不变槽，M3 会转红。因此注释和报告按实测改正；本步对该面保持 -1，未动。
2. 自测用例数净变化 +15，从 386 到 401：减 1（残留例迁出）加 13（`t3b` 段）加 3（witness 合取式拆项）。`src/ci/run.sh:71` 的计数注释同步。
3. 首跑枚举 4 例 rc 不为 0，是环境瞬扰：`tests/bootstrap/test_apx_tag|test_borrow|test_dex_arith|test_dex_type`。原因一，这 4 个 basename 与 `tests/selfhost/` 撞名，首跑日志被覆盖，内容误导，终跑改为路径编码日志名。原因二，这 4 例都是 Python bootstrap 测试，不调用 `build/corec`，与本步代码面无交集，单跑两次全 rc=0，终跑 57/57 rc=0，因此判为瞬扰，可能是并发或 IO，不是本步引入。
4. `.ccr` 判据口径：本步按“四件与 T3 后状态逐字节相同”验收。T3 已按“无语料命名行档逐字节同加 delta 归因”重定口径；本步 delta 为 0，无需再归因。
5. cwd 陷阱，本实例踩到并记录。`.ccr` 首次测量在 `cwd=/tmp/p5t3b` 下进行，得到 6205B/6358B，是假值，因为相对 import 的解析域变化。回到仓库根重测即得 90823B/90966B，与 T3 逐字节相同。判据命令一律在仓库根运行，`/tmp/p3t0_run.sh` 自带 `cd`。
6. 未改 `globals.cr`，没有新计数，清零证据走影子摘要加自测直断。`CIR_CACHE_VER`、`CCR_VERSION`、段布局、`OFF_*`、NOD 36B、`.cir` 快照零触碰，`.cir` DOT 逐字节相同为证。
7. `ty_shadow.cr` 零改动。域证明只读构造点，桥接面无需变更，本步是引擎侧加强。

---

## 7. 登记（不不报错地）

1. ¬ 面过判，预存，被本步揭开。`lp ⊆ ¬x` 时 lp 和 ¬x 是同类原子，返回 0，见 §5。值集语义对异身份同形原子，包括变体令牌和命名链，应为 1。影响面是 witness 项的包含判定，生产不可观测。后续步实施时应重钉 `t3.*_over_claim` 三例。
2. `AK_UNIT` 形态二义。原生 unit 项和令牌结构不可辨，b 大于等于 0 时同形。本步以先判令牌规避假等，M4 反证；unit 项只有一个节点，DAG 保证 unit 乘 unit 恒走快路径。
3. 域外保持面：μ 变元、`¬`、`⊤ₖ` 元素返回 -1 加 uncovered，未动；`x2.rw_view_unexpressible` 是其生产守门例。
4. ③ 的判据位：`te_elem_cmp` 在域外分支自己置 `g_ty_uncovered`，调用方不再重复置位。-1 的其他来源，即内层预算或未覆盖，由内层置位，两层不重复计数。
5. 未测 `ty_sub` 负值的独立计数通道，沿用 T0 表 D 登记，没有该通道。本步证据走影子摘要加自测直断加突变控制。

---

## 8. 证据路径

| 用途 | 路径 |
|---|---|
| RED/POST/终态探针（`*.red.log`/`*.post.log`/`*.final.log`/`*.M{1..4}.log` 加 dump） | `/tmp/p5t3b/probes/` |
| 语料对拍（引擎面版和终版，含逐档 logs） | `/tmp/p5t3b/parity{,_2}/{check,shadow}/` 加 `parity2_{check,shadow}.out` |
| 构建日志（9 次加突变 5 次加终版） | `/tmp/p5t3b/build{1..9,final}.log`、`mut_M*_build.log`、`mut_restore_build.log` |
| 自测日志 | `/tmp/p5t3b/selftest{1..3}.log` |
| 五个 CI job | `/tmp/p5t3b/ci_{check,bootstrap-tests,suite,selfhost-tests,full-bootstrap}.log` |
| 全枚举（路径编码日志 57 档加首跑对照） | `/tmp/p5t3b/enum2_*.log`、`enum_*.log` |
| 突变控制驱动 | `/tmp/p5t3b/mut.py`、`mut_run.sh`、`mut_M*_selftest.log` |
| canary、`.ccr`、dump、cir | `/tmp/pa_p5t3b`、`/tmp/p5t3b/{pa,pa_st,gt,gt_st}.ccr`、`gt_do2.txt`、`gt.cir`，对照 `/tmp/p5t3/f_*`、`gt_do*.txt`、`gt.cir` |
| 自举链 | `/tmp/corec2`、`/tmp/corec3`（`0c4b0a9e…`）加 `ci_full-bootstrap.log` |
