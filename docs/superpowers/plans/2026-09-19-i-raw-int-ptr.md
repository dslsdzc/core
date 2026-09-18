# `(i)` 小批：`@raw_int` 放宽接受指针 —— 实施记录（2026-09-19）

**交付**：PR #134 → squash `develop = 08f0b653`（head `ed463544`）。
**裁定**：team-lead——只加**实测有证据的那一类**；负控写 `check` 面；`TYP_REF`/`TYP_SLICE`/`TYP_ARRAY` 保持拒绝；
`diag.cr` 不动（撤条归 `(甲)` 刀 4）。
**同文件约束**：与 `(甲)` 批 1 同占 `checker.cr` ⇒ 等其落地（`802bd24a`）后开工，开工前重采 pre。

## §1 改动

`src/compiler/checker.cr` 的 `@raw_int` 守卫（**符号锚** `str_eq(name, "raw_int")`，行号每批都在漂）：

```core
if av != TI_DEX && av != TI_INT && av != TI_NEVER {
    if !(av > TI_DEX_S && get_type_kind(av) == TYP_PTR) {   // ← 本批新增（唯一改动）
        check_error(EC_TF_ARG_TYPE, "@raw_int requires a dex (or int) or pointer expression", …);
        return TI_NEVER;
    }
}
```

- **加入标准 = 该类型的原值有语义**：dex 缩放位 · int 原值 · **指针地址字**。
  `TYP_REF`/`TYP_SLICE`/`TYP_ARRAY` 等**仍拒**——聚合无「原值」概念、`TYP_REF` 语义未实测 ⇒ **没证据就不扩**
  （与子步 0「range 门零命中就不写退出条款」同一条纪律）。
- **⚠ 上界 `av > TI_DEX_S` 不可省**（通用坑，见 §7）：类型表下标 **0..8 = 标量/占位**（`TI_INT`..`TI_DEX_S`），
  直接 `get_type_kind(标量下标)` 会**读到占位行的 kind**——凡「按下标读 kind」的惯用法都有这个坑。
- **文案单点**：全仓**仅此一处**（bootstrap 侧不识别 `raw_int`，fail-closed ⇒ 无第二份文案）。
- **安全面边界**：`@raw_int` **现状不要求 `unsafe`**，且本就吃 `TI_DEX` ⇒ **指针只是同一「取原值」类别里的又一类型**、
  **不引入新类别**。「是否应要求 `unsafe`」是**预存更大问题、不在本条解决**；若将来裁定要求，
  会**同时影响 `dex`/`int` 既有形态** ⇒ 属**改契约批**，须单独立项。

## §2 读数（批基点 `802bd24a` 重采 pre；与开工单给的预期逐字对上，无需归因）

| 面 | pre | post |
|---|---|---|
| `tests/suite/ptr_ref_first.cr` `check` | rc=1 · TF07×2 · TB01×1 | **rc=0 · 零诊断**（TF07 与其级联 TB01 同批消失） |
| 产物 ELF | `fdf8cad6…`（28854B） | **逐字节不变** |
| 产物 `.ccr`（build 侧车） | `3e27595e…`（95571B） | **逐字节不变** |
| 运行 | —— | native rc=0 · 解释器 rc=0 |

⇒ 本批是**诊断面**放宽：产物零变化（非代码生成改动）。

## §3 判据（`tests/selfhost/test_raw_int_ptr.py`，挂 `selfhost-tests`，19 项）

A 正控（诊断面零诊断 + 两腿值面）· B 负控 6 类（string/bool/array/slice/**ref_type（形参 `&int`）**/struct ⇒
`check` 面 rc=1 + **恰 1 条** TF07 + 文案含 `or pointer`）· B' 既有 `dex`/`int` 形态仍受 · C 同源两次构建 ELF 一致。

**类型定名 = 实测定名（不假设）**：**只加 `TYP_PTR`** 后正控即绿 ⇒ `&x` 表达式解析到的就是 `TYP_PTR` 行
（代码路径佐证：一元取地址分支 `alloc_type(TYP_PTR, inner, 0)`；**类型位** `&T` 则是 `TYP_REF`）。
**交叉证据（突变 M2）**：把放宽面扩到 `TYP_REF` 时，`ref_type` 负控**恰好翻红**，而 slice/array/string 仍拒
⇒ 该负控钉的确实是 `TYP_REF`，且钉子**按类特异**。

**负控的面（纪律）**：`TF07` 是 **build-scope 豁免码**（`diag.cr::diag_gate_exempt`）⇒ **「build 面零产物」在本批恒假**
（豁免未撤）⇒ 负控只写 `check` 面。**凡写「零产物」先问「这个面上有没有豁免」**。

## §4 突变自证（均断言命中目标）

- **M1（回退放宽）**：正控回到 pre 读数（rc=1 · TF07×2 · TB01×1）⇒ 正控有牙。
- **M2（放宽过头 = +`TYP_REF`）**：`ref_type` 负控翻红；slice/array/string 仍拒 ⇒ 钉子按类特异。

**实测红项计数（本批唯一权威读数，team-lead 复核认可）**：
`test_diag_gate.py` **1 项**（`pos_tf07_tb01_ptr_check_clean`）· `test_raw_int_ptr.py` **1 项**（`pos_check_clean`）⇒ **合计 2**。

### §4.1 ⚠ **豁免面证据（通用纪律的实证附件）**

**同一 M1 突变下，`build_ok("tf07_tb01_ptr_clean", …)`（build 面「rc=0 + 有产物」）仍然 PASS。**

⇒ **在人眼可读的一句话里**：**豁免面上的「能过」断言对该类回归完全不敏感**——TF07 被 build-scope 豁免，
所以只要豁免还在，`rc=0 + 产物` 与「有没有诊断」**无关**。**能抓住这条回归的只有 `check` 面的缺席断言。**
这比「零产物先问有没有豁免」这句抽象纪律更有说服力：它是**一次突变同时证伪了弱判据、证实了强判据**。

## §5 既有判据的重定（换夹具保意图、不删断言）

`tests/selfhost/test_diag_gate.py` 的 build 面正控原写
`build_ok("tf07_tb01", "tests/suite/ptr_ref_first.cr", ("TF07","TB01"))`——把「该夹具产 TF07+TB01 且被豁免放行」钉成契约；
本批**合法地**改变了该行为 ⇒ 实测红（`pos_tf07_tb01`）。

- **改法**：改用**仍被拒**的串实参级联夹具（2×TF07 → 两侧 `TI_NEVER` → 1×TB01，与旧夹具**同形**）继续钉
  「豁免码仍放行（rc=0 + 产物）**且仍被报出**」；**原夹具另钉新语义**，且按复核意见**拆成两条**：
  - **`check` 面** `pos_tf07_tb01_ptr_check_clean`：rc=0 且**无 TF07、无 TB01**（**只有 check 面有意义**）；
  - **`build` 面** `build_ok("tf07_tb01_ptr_clean", …)`：钉「能过 + 有产物」那一半。
  两条**合起来**才是「放宽后指针形态干净通过」；**单留 build 面那条 = 注释强于代码**（见 §7）。
- **自查（同档其它裸 `build_ok`）**：`tf01_build_clean` 已有 check 面缺席断言配对 ✓；`b04` 注释只声称
  「仍放行（rc=0 + 产物）」与代码一致、无越权声称 ✓ ⇒ 无同类落差。
- 复跑：`test_diag_gate.py` **21/21 passed**。

## §6 批报告登记（**未落 `diag.cr`**，撤条归 `(甲)` 刀 4）

`diag.cr` 的 TF07 条目（**含重复块 `183-186 ≡ 187-190`**）四处失准：
① 「`EC_TF_ARG_TYPE` 全仓**唯一** raise 点」已因 2(a) 变为 **3 处**（`checker.cr:4123` @raw_int · `:4191` @ptr_of · `:4197` @str_of）；
② 引用行号 `3727` → 实际 `4123`；③ 位点锚 `ptr_ref_first.cr:8（@raw_int）` 实为 **`:10`**（第 8 行是 `p := &x;`）；
④ 第二处引用 `test_ccr_types.py:1805` 与该码无关（实读为 tk-dump 解析代码）。

## §7 两条通用纪律（本批实测逼出）

1. **「面 × 豁免」先于结论**：凡判据写「零产物 / rc=1」，先查 `diag_gate_exempt` 在该**面 × 码**上的取值——
   `check` 面「零产物」**恒真**；被 build-scope 豁免的码在 build 面「零产物」**恒假**。
2. **断言弱于注释**：写完断言回头逐词读注释——**注释写「零诊断」而代码只钉「能过」**就属此类（§4.1 是其实证）。
   **「缺席类」断言必须落在不在豁免内的面**，并与「能过类」**成对**。
