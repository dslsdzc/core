# `(i)` 小阶段：`@raw_int` 放宽接受指针，实施记录（2026-09-19）

> 对应计划：[plans/2026-09-19-i-raw-int-ptr.md](../plans/2026-09-19-i-raw-int-ptr.md)

交付：PR #134，squash 后 `develop = 08f0b653`（head `ed463544`）。

裁定（team-lead）：只增加实测有证据的那一类；负控写在 `check` 面；`TYP_REF`、`TYP_SLICE`、`TYP_ARRAY` 保持拒绝；`diag.cr` 不动，撤条归 `(1)` 阶段的第 4 步。

同文件约束：本次与 `(1)` 阶段 1 都要改 `checker.cr`，因此等其实施（`802bd24a`）后再开始。开始实施前重新采集 pre 读数。

## 1. 改动

`src/compiler/checker.cr` 的 `@raw_int` 守卫（符号定位点为 `str_eq(name, "raw_int")`，行号每阶段都会变化）：

```core
if av != TI_DEX && av != TI_INT && av != TI_NEVER {
    if !(av > TI_DEX_S && get_type_kind(av) == TYP_PTR) {   // ← 本次新增（唯一改动）
        check_error(EC_TF_ARG_TYPE, "@raw_int requires a dex (or int) or pointer expression", …);
        return TI_NEVER;
    }
}
```

- 加入标准是该类型的原值有语义：dex 缩放位、int 原值、指针地址字。`TYP_REF`、`TYP_SLICE`、`TYP_ARRAY` 等仍然拒绝。聚合类型没有「原值」概念，`TYP_REF` 的语义尚未实测，因此没有证据就不扩大范围。这与子步 0「range 门零命中就不写退出规则」是同一条纪律。
- 上界 `av > TI_DEX_S` 不能省略，这是一个常见问题，见第 7 节。类型表下标 0..8 是标量和占位（`TI_INT`..`TI_DEX_S`），直接对下标调用 `get_type_kind` 会读到占位行的 kind。凡「按下标读 kind」的写法都有这个问题。
- 文案只有一处：全仓仅此一处。bootstrap 侧不识别 `raw_int`，按 fail-closed 处理，因此没有第二份文案。
- 安全面边界：`@raw_int` 目前不要求 `unsafe`，而且本来就接受 `TI_DEX`。指针只是同一「取原值」类别中的又一个类型，不引入新类别。「是否应要求 `unsafe`」是更大的预存问题，不在本条解决。若将来裁定要求，会同时影响 `dex` 和 `int` 的既有形态，则属于修改契约的阶段，须单独立项。

## 2. 读数（以阶段基点 `802bd24a` 重新采集 pre；与开始实施时给出的预期逐字一致，无需归因）

| 面 | pre | post |
|---|---|---|
| `tests/suite/ptr_ref_first.cr` `check` | rc=1 · TF07×2 · TB01×1 | rc=0 · 零诊断（TF07 与其级联 TB01 同阶段消失） |
| 产物 ELF | `fdf8cad6…`（28854B） | 逐字节不变 |
| 产物 `.ccr`（build 侧车） | `3e27595e…`（95571B） | 逐字节不变 |
| 运行 | | native rc=0 · 解释器 rc=0 |

因此本次只放宽诊断面，产物零变化，不是代码生成改动。

## 3. 检查（`tests/selfhost/test_raw_int_ptr.py`，挂 `selfhost-tests`，19 项）

A 正控：诊断面零诊断，并检查两条检查值面。B 负控 6 类：string、bool、array、slice、ref_type（形参 `&int`）、struct，均要求 `check` 面 rc=1、恰好 1 条 TF07、文案含 `or pointer`。B' 检查既有 `dex`/`int` 形态仍受约束。C 检查同源两次构建的 ELF 一致。

类型定名来自实测，不作假设：只增加 `TYP_PTR` 后正控即通过，说明 `&x` 表达式解析到的就是 `TYP_PTR` 行。代码路径也可佐证：一元取地址分支调用 `alloc_type(TYP_PTR, inner, 0)`；类型位 `&T` 则是 `TYP_REF`。

交叉证据（突变 M2）：把放宽面扩大到 `TYP_REF` 时，`ref_type` 负控恰好失败，而 slice、array、string 仍然拒绝。因此该负控固定的确实是 `TYP_REF`，断言按类型区分。

负控面的纪律：`TF07` 是 build-scope 豁免码（`diag.cr::diag_gate_exempt`），因此「build 面零产物」在本次始终为假（豁免未撤）。负控只写 `check` 面。凡要写「零产物」，先问这个面上有没有豁免。

## 4. 突变自证（均断言命中目标）

- M1（回退放宽）：正控回到 pre 读数（rc=1 · TF07×2 · TB01×1），说明正控有效。
- M2（放宽过头，增加 `TYP_REF`）：`ref_type` 负控失败；slice、array、string 仍然拒绝，说明断言按类型区分。

实测失败项计数（本次唯一权威读数，team-lead 复核认可）：`test_diag_gate.py` 1 项（`pos_tf07_tb01_ptr_check_clean`），`test_raw_int_ptr.py` 1 项（`pos_check_clean`），合计 2。

### 4.1 豁免面证据（通用纪律的实证附件）

同一 M1 突变下，`build_ok("tf07_tb01_ptr_clean", …)`（build 面「rc=0 + 有产物」）仍然 PASS。

因此在人眼可读的一句话里：豁免面上的「能过」断言对该类回归完全不敏感。TF07 被 build-scope 豁免，只要豁免还在，`rc=0 + 产物` 与「有没有诊断」无关。能发现这条回归的只有 `check` 面上「诊断不出现」的断言。这比「零产物先问有没有豁免」这句抽象纪律更有说服力：一次突变同时否定了弱检查、证实了强检查。

## 5. 既有检查的重定（换夹具，保留意图，不删断言）

`tests/selfhost/test_diag_gate.py` 的 build 面正控原来写的是 `build_ok("tf07_tb01", "tests/suite/ptr_ref_first.cr", ("TF07","TB01"))`，把「该夹具产生 TF07+TB01 且被豁免放行」固定成契约。本次合法地改变了该行为，因此实测失败（`pos_tf07_tb01`）。

- 改法：改用仍被拒绝的串实参级联夹具（2×TF07 到两侧 `TI_NEVER`，再到 1×TB01，与旧夹具同形），继续固定「豁免码仍放行（rc=0 + 产物）且仍被报出」。原夹具另固定新语义，并按复核意见拆成两条：
  - `check` 面 `pos_tf07_tb01_ptr_check_clean`：rc=0，且无 TF07、无 TB01。只有 check 面有意义；
  - `build` 面 `build_ok("tf07_tb01_ptr_clean", …)`：固定「能过 + 有产物」这一半。
  两条合起来才是「放宽后指针形态干净通过」。只保留 build 面那条，会出现注释强于代码的情况（见第 7 节）。
- 自查同档其它裸 `build_ok`：`tf01_build_clean` 已有 check 面「诊断不出现」的断言配对；`b04` 的注释只声称「仍放行（rc=0 + 产物）」，与代码一致，没有越权声称，因此不存在同类落差。
- 复测：`test_diag_gate.py` 21/21 passed。

## 6. 阶段报告登记（未落 `diag.cr`，撤条归 `(1)` 阶段的第 4 步）

`diag.cr` 的 TF07 条目（含重复块 `183-186 ≡ 187-190`）有四处失准：

1 「`EC_TF_ARG_TYPE` 全仓唯一 raise 点」已因 2(a) 变为 3 处（`checker.cr:4123` @raw_int、`:4191` @ptr_of、`:4197` @str_of）；
2 引用行号 `3727` 到实际 `4123`；
3 位点定位点 `ptr_ref_first.cr:8（@raw_int）` 实际为 `:10`（第 8 行是 `p := &x;`）；
4 第二处引用 `test_ccr_types.py:1805` 与该码无关（实读为 tk-dump 解析代码）。

## 7. 两条通用纪律（本次实测得出）

1. 「面 × 豁免」先于结论：凡检查写「零产物 / rc=1」，先查 `diag_gate_exempt` 在该面 × 码上的取值。`check` 面的「零产物」始终为真；被 build-scope 豁免的码在 build 面的「零产物」始终为假。
2. 断言弱于注释：写完断言后回头逐词读注释。注释写「零诊断」而代码只锁「能过」，就属于此类，4.1 节是其实证。断言诊断不出现的检查必须落在不在豁免内的面，并与「能过类」断言成对。
