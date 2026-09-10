# R2 P1（影子对拍）实施计划：旧判定 ∥ 新引擎 → 差异清单

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 P0 的类型项引擎以**影子模式**挂到检查器的类型判定上（旧判定照常生效），对真实语料并跑两套判定、产出**分类差异清单**——收紧面（旧接受→新拒绝 / 旧拒绝→新接受）在 P1 暴露，而不改任何行为。

**Architecture:** 三件新东西 + 一处包装：① 桥接层 `ty_shadow.cr`（checker 的 `ti` → 引擎类型项）；② 影子判定核心（翻译 → `ty_equiv` → 分类：`AGREE` / `OLD_STRICTER`（旧拒新受）/ `OLD_LOOSER`（旧受新拒）/ `UNKNOWN`（引擎 -1，单列不计差异））；③ 通道（CLI `--type-shadow` 开关 + 摘要行 + 转储文件）；挂点 = `type_equal` 包装（原函数改名 `type_equal_core` 供内部递归，外部 8 个决策点经包装自动覆盖）。

**Tech Stack:** Core 自举栈；P0 引擎（`src/compiler/type_terms.cr` / `type_engine.cr` / `type_selftest.cr`）；检查器 `src/compiler/checker.cr`；CLI `src/compiler/main.cr`。

**Spec:** `docs/superpowers/specs/2026-09-10-type-interface-unification-design.md` §4 步 2（旁挂对拍）+ §8 判据 3（对拍层）+ §9 P1。

## Global Constraints

- **jj only**；**提交必须路径限定**（多 agent 共用工作副本）。
- 所有编译/测试命令 `nice -n 19` 前缀；改编译器源码后**必须重建**。
- **P1 行为零变化（强判据）**：`--type-shadow` **关**（默认）= 产物与 P0 基线逐字节相同；**开** = 产物**同样**逐字节相同（影子只观察、不改判定、不写产物）。两态都要过。
- **判据前清缓存**：`nice -n 19 ./build/corec clean-cache`（TODO #5），且 cwd = 仓库根。
- 文件永久不允许还原；不得绕过；**引擎 UNKNOWN（-1）不得计入差异**（未覆盖面 ≠ 收紧面，单列统计）。
- diff 校验式样：`jj diff --git <paths...> | grep '^[+]' | grep -v -e '^[+][+][+]'`；环境陷阱：noclobber（用 `>|`）、变量不分词。
- 新文件三处注册（`src/compiler/_import.cr` / `build_selfhost_native.py` 的 **corec 清单**（checker 段后）/ `tests/selfhost/test_compile.py`）。

---

## Task 1: 桥接层（checker `ti` → 引擎类型项）+ 单元自测

**Files:**
- Create: `src/compiler/ty_shadow.cr`
- Modify: `src/compiler/globals.cr`（影子侧表声明）、`src/compiler/type_selftest.cr`（加桥接用例）、`src/compiler/_import.cr`、`build_selfhost_native.py`、`tests/selfhost/test_compile.py`

**Interfaces（产出；Task 2/3 依赖）：**

```
// ti → 类型项（带 per-ti 缓存；-1 = 无法翻译/预算耗尽）
fn sh_term_of_ti(ti: int) -> int
// 桥接统计（自测断言用）
fn sh_map_hits() -> int        // 缓存命中数
fn sh_map_entries() -> int     // 已翻译条目数
```

**映射表（P0 引擎原子类 ↔ checker 类型 kind；`res_type_node`/`alloc_type` 现状见 spec §11）**：

| checker | 引擎项 |
|---|---|
| `TYP_BASE` + `TY_INT/TY_DEX/TY_STRING/TY_BOOL/TY_UNIT/TY_NEVER/TY_CHAR` | `AK_INT/AK_DEX/AK_STRING/AK_BOOL/AK_UNIT/AK_NEVER/AK_CHAR`（`ti` 存 `b` 槽）——**⚠️ 必须按语义逐项分派，不得按数值直传**：`TI_BOOL=2/TI_STR=3` 与 `AK_STRING=2/AK_BOOL=3` **下标互换**（Task 1 实测：照抄数值直传会把 bool↔string 静默错标，且两侧同错自洽 → 差异清单全成假信号）；`TY_DEX_S`（精确缩放 dex，占位哨兵行）同样归 `AK_DEX` |
| `TYP_DYN` | `AK_DYN` |
| `TYP_ARRAY`（data=元素, extra=N） | `AK_SEQUENCE`，参数链 `[elem]`（**N 不入身份**——R1 裁决） |
| `TYP_SLICE` | `AK_SEQUENCE`，参数链 `[elem]` |
| `TYP_PTR` / `TYP_REF` | `AK_PTR` / `AK_REF`，参数链 `[inner]` |
| `TYP_TUPLE`（**实读布局：`data` = 字段数、`extra` = `g_gen_apply_data` 起始下标**——checker.cr:118 与 :2041 两处消费点同证；计划初稿的「`g_tuple_*`」全仓不存在，Task 1 实测） | `AK_PRODUCT`，参数链 = 逐字段项 |
| `TYP_NAMED` | `AK_NAMED`（`ti` 存 `b` 槽；引擎不展开 → 多为 UNKNOWN，P1 预期） |
| `TYP_GENERIC_PARAM` / `TYP_GENERIC_APPLY` | `AK_NAMED`（同上，未知类） |

- [ ] **Step 1: 加自测用例（`type_selftest.cr`；红）**

```core
    // --- P1 桥接（checker ti → 引擎项）---
    // 说明：调用方需 g_types 已初始化（selftest 里显式 init_types()）
    t_int := sh_term_of_ti(TI_INT);
    total = total + 1; fails = fails + ts_check("bridge.int_atom", tt_tag(t_int), TT_ATOM);
    total = total + 1; fails = fails + ts_check("bridge.int_ak", tt_a(t_int), AK_INT);
    t_arr := sh_term_of_ti(alloc_type(TYP_ARRAY, TI_INT, 3));
    total = total + 1; fails = fails + ts_check("bridge.arr_seq", tt_a(t_arr), AK_SEQUENCE);
    t_arr3 := sh_term_of_ti(alloc_type(TYP_ARRAY, TI_INT, 4));
    total = total + 1; fails = fails + ts_check("bridge.len_not_identity",
        ty_equiv(t_arr, t_arr3), 1);            // N 不入身份（R1 裁决）——3 与 4 等价
    total = total + 1; fails = fails + ts_check("bridge.cache_hit", (sh_term_of_ti(TI_INT) == t_int), 1);
```

- [ ] **Step 2: 运行确认红**（`sh_term_of_ti` 未定义 → 构建失败/用例挂）

- [ ] **Step 3: 实现 `ty_shadow.cr`（桥接层）**

```core
// === ty_shadow.cr ===
// R2 P1：影子对拍桥接层——把 checker 的类型表行号（ti）翻译成 P0 引擎的类型项。
// 语义映射见计划 Task 1 表；命名/泛型类映射为 AK_NAMED（引擎不展开 → UNKNOWN，
// 这正是 P1 要暴露的「未覆盖面」，与「收紧面」分开统计）。
// 缓存：g_shadow_map（16B/条：ti → term），线性探测开放寻址（与引擎表同式）。

fn sh_map_cap_init() {
    if g_shadow_map_cap <= 0 {
        nc : ., mut = 1024;
        nb := alloc(nc * 16);
        i : ., mut = 0;
        loop { if i >= nc { break; } w64(nb, i * 16, -1); i = i + 1; }
        g_shadow_map = nb;
        g_shadow_map_cap = nc;
    }
}

// ⚠️ 骨架修正（Task 1 评审 M6：**直接照抄初稿骨架会回归缺陷 ②③**）：
//   · 探测前必须有**装填因子守卫**（否则 >cap 条目时探测永不落空 = 挂死）
//   · 扩容 = 重建 + **重放既有条目**（`sh_map_rehash`）
//   · 调用方**回写前必须重探**（递归翻译可能触发扩容/重建，写旧 slot 会写错槽）
fn sh_map_find(ti: int) -> int {   // 命中返回槽位，未命中返回空槽位（不插入）
    sh_map_cap_init();
    if (g_shadow_map_count + 1) * 2 >= g_shadow_map_cap { sh_map_rehash(); }   // 守卫（探测前）
    h : ., mut = ti % g_shadow_map_cap;
    if h < 0 { h = 0 - h; }
    p : ., mut = h;
    loop {
        k := r64(g_shadow_map, p * 16);
        if k < 0 { return p; }
        if k == ti { return p; }
        p = p + 1; if p >= g_shadow_map_cap { p = 0; }
    }
}

// 扩容：容量翻倍（≥2 的幂）+ 逐条重放（保留既有映射）
fn sh_map_rehash() {
    old_map := g_shadow_map;
    old_cap := g_shadow_map_cap;
    nc : ., mut = old_cap * 2;
    if nc < 1024 { nc = 1024; }
    nb := alloc(nc * 16);
    i : ., mut = 0;
    loop { if i >= nc { break; } w64(nb, i * 16, -1); i = i + 1; }
    g_shadow_map = nb;
    g_shadow_map_cap = nc;
    g_shadow_map_count = 0;
    j : ., mut = 0;
    loop {
        if j >= old_cap { break; }
        k := r64(old_map, j * 16);
        if k >= 0 {
            s := sh_map_slot_no_grow(k);      // ⚠️ 重放必须用**无守卫**版（有守卫版会再触发 rehash → 递归）
            w64(g_shadow_map, s * 16, k);
            w64(g_shadow_map, s * 16 + 8, r64(old_map, j * 16 + 8));
            g_shadow_map_count = g_shadow_map_count + 1;
        }
        j = j + 1;
    }
}

// 无守卫探测（仅供 rehash 重放；外部一律走 sh_map_find）
fn sh_map_slot_no_grow(ti: int) -> int {
    h : ., mut = ti % g_shadow_map_cap;
    if h < 0 { h = 0 - h; }
    p : ., mut = h;
    loop {
        k := r64(g_shadow_map, p * 16);
        if k < 0 { return p; }
        if k == ti { return p; }
        p = p + 1; if p >= g_shadow_map_cap { p = 0; }
    }
}

fn sh_term_of_ti(ti: int) -> int {
    if ti < 0 { return -1; }
    // 预置常量：natives **按语义逐项分派**（⚠️ 数值不 1:1：TI_BOOL=2/TI_STR=3 vs
    // AK_STRING=2/AK_BOOL=3 下标互换——直接 tt_atom(ti,ti,-1) 会静默错标，Task 1 实测）
    if ti == TI_INT { return tt_atom(AK_INT, ti, -1); }
    if ti == TI_DEX { return tt_atom(AK_DEX, ti, -1); }
    if ti == TI_BOOL { return tt_atom(AK_BOOL, ti, -1); }
    if ti == TI_STR { return tt_atom(AK_STRING, ti, -1); }
    if ti == TI_UNIT { return tt_atom(AK_UNIT, ti, -1); }
    if ti == TI_NEVER { return tt_atom(AK_NEVER, ti, -1); }
    if ti == TI_CHAR { return tt_atom(AK_CHAR, ti, -1); }
    if ti == TI_DYN { return tt_atom(AK_DYN, ti, -1); }   // 注意：dyn 位图按 ⊤ 近似（过宽）→ Task 3 须单列 dyn 类差异
    if ti == TI_DEX_S { return tt_atom(AK_DEX, ti, -1); } // 精确 dex 与 dex 同语义域
    slot := sh_map_find(ti);
    k := r64(g_shadow_map, slot * 16);
    if k == ti {
        g_shadow_hits = g_shadow_hits + 1;
        return r64(g_shadow_map, slot * 16 + 8);
    }
    // 未命中：按 kind 翻译（递归子项）
    term : ., mut = -1;
    k1 := get_type_kind(ti);
    d1 := get_type_data(ti);
    if k1 == TYP_ARRAY || k1 == TYP_SLICE {
        el := sh_term_of_ti(d1);
        if el >= 0 { term = tt_atom(AK_SEQUENCE, -1, tt_cons(el, tt_nil())); }
    } else if k1 == TYP_PTR {
        in1 := sh_term_of_ti(d1);
        if in1 >= 0 { term = tt_atom(AK_PTR, -1, tt_cons(in1, tt_nil())); }
    } else if k1 == TYP_REF {
        in2 := sh_term_of_ti(d1);
        if in2 >= 0 { term = tt_atom(AK_REF, -1, tt_cons(in2, tt_nil())); }
    } else if k1 == TYP_TUPLE {
        // 逐字段翻译（字段访问器与 g_tuple_* 布局见 checker.cr；实现时以实际访问器为准）
        term = sh_tuple_to_product(ti);
    } else if k1 == TYP_NAMED || k1 == TYP_GENERIC_PARAM || k1 == TYP_GENERIC_APPLY {
        term = tt_atom(AK_NAMED, ti, -1);   // 不展开 → UNKNOWN（P1 预期）
    } else {
        term = tt_atom(AK_NAMED, ti, -1);   // 未知 kind 保守归入命名类
    }
    if term < 0 { return -1; }
    // ⚠️ 缓存表必须：① 装填因子守卫（表满时开放寻址探测永不落空 = 挂死——P0 C2 同族，
    // Task 1 实测：固定 1024 容量在编译器自身语料（数千 ti）下必挂）；② 重建时重放既有
    // 条目；③ **回写前重探**（递归翻译可能触发扩容/重建，直接写旧 slot 会写错槽）。
    slot2 := sh_map_find(ti);
    w64(g_shadow_map, slot2 * 16, ti);
    w64(g_shadow_map, slot2 * 16 + 8, term);
    g_shadow_entries = g_shadow_entries + 1;
    return term;
}
```
（`sh_tuple_to_product`：按 checker 侧 tuple 字段访问器逐字段 `sh_term_of_ti` 后串成 CONS 链——实现者按实际访问器落，签名 `fn sh_tuple_to_product(ti: int) -> int`。）

- [ ] **Step 4: 表全局声明（`globals.cr`）+ 三处注册**

```core
// R2 P1 影子对拍：ti → 类型项 缓存 + 统计
g_shadow_map : string, mut;        g_shadow_map_cap : int, mut;
g_shadow_map_count : int, mut;     // 已占用槽数（装填因子守卫用）
g_shadow_hits : int, mut;          g_shadow_entries : int, mut;
// 影子判定（Task 2）：开关 + 站点 + 分类计数 + 环形缓冲
g_shadow_on : int, mut;            g_shadow_site : int, mut;
g_shadow_total : int, mut;         g_shadow_agree : int, mut;
g_shadow_old_stricter : int, mut;  g_shadow_old_looser : int, mut;
g_shadow_unknown : int, mut;       g_shadow_buf : string, mut;
g_shadow_buf_count : int, mut;     g_shadow_buf_cap : int, mut;
```

- [ ] **Step 5: 跑绿 + 提交**

```bash
nice -n 19 python3 build_selfhost_native.py && nice -n 19 ./build/corec selftest-types   # 期望 49+N 全 PASS
```
提交（路径限定）：`feat: R2 P1 Task 1——影子桥接层（checker ti → 引擎类型项，含 N 不入身份断言）`

---

## Task 2: 影子判定核心 + `type_equal` 包装 + 通道

**Files:**
- Modify: `src/compiler/ty_shadow.cr`（判定与分类）、`src/compiler/checker.cr`（`type_equal` 改名 + 包装 + 站点标注）、`src/compiler/globals.cr`、`src/compiler/main.cr`（CLI）

**Interfaces：**

> **Task 1 评审落地注记（M1/M4，Task 2 一并办）**：
> ① **native 分派改用 `get_type_data` 显式比对 `TY_*` 码**（而非 `TI_*` 行号）——现状「`init_types` 行号序恰与 `TY_*` 码序一致」属**隐式依赖**（当前真、不保证），显式化后不随表布局变化而坏。
> ② `ty_shadow.cr` 头注**点明「`AK_*` 与 `TI_*` 下标不 1:1（bool/str 互换）」**这一反直觉事实，防后人照数值直传（Task 1 已留守门用例 `bridge.str_ak`/`bridge.bool_ak`）。

```
// 影子判定：翻译两侧 → ty_equiv → 分类计数（old = 旧判定的结果）
fn sh_compare(t1: int, t2: int, old_ok: int) -> void
fn sh_site_begin(site: int) -> void        // 8 个外部决策点各设一个站点 id
fn sh_report() -> int                      // 打印摘要行；返回 0
fn sh_dump_write(path_ni: int) -> int      // 转储差异条目（-1 = 未启用）
// 分类计数访问器（自测/摘要用）
fn sh_count_agree() -> int     fn sh_count_old_stricter() -> int
fn sh_count_old_looser() -> int   fn sh_count_unknown() -> int
```

- [ ] **Step 1: 包装（`checker.cr`）**：`fn type_equal(t1: int, t2: int) -> bool` 改名为 `type_equal_core`（**内部 8 处递归调用一并改名**），新增：

```core
// R2 P1 影子对拍包装：旧判定照常返回；影子判定只观察（--type-shadow 开时）
fn type_equal(t1: int, t2: int) -> bool {
    r := type_equal_core(t1, t2);
    if g_shadow_on != 0 { sh_compare(t1, t2, r ? 1 : 0); }
    return r;
}
```
（`r ? 1 : 0`：**本语言无三元运算符**——用 `ok : ., mut = 0; if r { ok = 1; }` 显式写。）

- [ ] **Step 2: 站点标注**：在 8 个外部调用点（`checker.cr:711/947/959/973/1212/1405/1796/2127`）调用前 `sh_site_begin(<id>)`。
  **实读修正（Task 2 落地，取代初稿标签）**：8 个外部点**无一是 match 路径**；站点 4 = 泛型匹配（pattern 侧恒 `TI_UNIT` → 难产差异）；站点 6 = `EXPR_BINARY+OP_ASSIGN` 遗留路径（**当前不可达**——parser 已把 `=` 统一降为 `EXPR_ASSIGN`，挂点保留但永不产样本，去留待 P2 裁决）；站点 8 = `EXPR_ASSIGN` 节点（**非「索引」**）。站点 ↔ 语义以 `ty_shadow.cr` 头注（实读表）为准。

- [ ] **Step 3: 分类核心（`ty_shadow.cr`）**

```core
fn sh_compare(t1: int, t2: int, old_ok: int) -> void {
    g_shadow_total = g_shadow_total + 1;
    a := sh_term_of_ti(t1);
    b := sh_term_of_ti(t2);
    if a < 0 || b < 0 { g_shadow_unknown = g_shadow_unknown + 1; return; }
    ty_budget_reset(200000);
    e := ty_equiv(a, b);
    ty_budget_reset(200000);                 // 影子运行不污染后续
    if e == -1 { g_shadow_unknown = g_shadow_unknown + 1; sh_record(0, t1, t2, old_ok); return; }
    // 注意语义：旧 true ⇔ 引擎 1
    if e == old_ok { g_shadow_agree = g_shadow_agree + 1; return; }
    if old_ok == 0 && e == 1 { g_shadow_old_stricter = g_shadow_old_stricter + 1; }   // 旧拒新受
    else { g_shadow_old_looser = g_shadow_old_looser + 1; }                           // 旧受新拒 = 收紧面
    sh_record(1, t1, t2, old_ok);
}
```
`sh_record(flag, t1, t2, old)`：环形缓冲（前 256 条差异/未知）——每槽 `{site, t1, t2, old_ok, kind}`；满则只计数。

- [ ] **Step 4: 通道（`main.cr`）**

```core
    cli_flag_bool("type-shadow", "", "R2 P1: shadow type decisions with the engine (observation only)");
    cli_flag("type-shadow-dump", "", "R2 P1: dump shadow diff entries to file");
```
分派处：解析两旗标 → `g_shadow_on = 1` / dump 路径；编译结束前 `sh_report()`（摘要行 `[type-shadow] decisions=… agree=… old_stricter=… old_looser=… unknown=…`）+ 若给了 dump → `sh_dump_write(...)`。

- [ ] **Step 5: 判据（两态零变化 + 摘要可得）**

```bash
nice -n 19 ./build/corec clean-cache
nice -n 19 ./build/corec build tests/suite/ptr_arith.cr --static -o /tmp/p1_off   # 默认关
nice -n 19 ./build/corec build tests/suite/ptr_arith.cr --static --type-shadow -o /tmp/p1_on
cmp /tmp/r1t4_base_bin /tmp/p1_off && echo OFF-IDENTICAL
cmp /tmp/r1t4_base_bin /tmp/p1_on  && echo ON-IDENTICAL     # 影子不得改产物
nice -n 19 ./build/corec check src/compiler/checker.cr --type-shadow | tail -3   # 摘要行出现
```

- [ ] **Step 6: 提交**：`feat: R2 P1 Task 2——影子判定挂点（type_equal 包装 + 8 站点）+ 分类计数 + CLI 通道（两态产物逐字节不变）`

---

## Task 3: 语料运行 + 差异清单归档

**Files:**
- Create: `docs/superpowers/specs/2026-09-10-type-shadow-findings.md`

- [ ] **Step 0（前置，评审硬性要求）：未知桶拆两因（**先改代码再采数**）**——`sh_compare` 里把「任一侧翻译失败（`sh_term_of_ti` 返回 -1）」与「引擎三态负值（-1/-2，含预算耗尽）」分记两个 kind（如 `kind=3` = 桥接 -1 / `kind=0` = 引擎负值）。理由（Task 2 评审）：dump 现存条已混记，**若只做文档不拆代码，Task 3 的归因不可恢复**。

- [ ] **Step 1: 三档语料跑影子（各自 clean-cache + cwd=仓库根）**

```bash
# ① 套件样本
for f in tests/suite/*.cr; do nice -n 19 ./build/corec check "$f" --type-shadow; done >| /tmp/p1_suite.log 2>&1
# ② 编译器自身（最大真实语料）
nice -n 19 ./build/corec check src/compiler/main.cr --type-shadow >| /tmp/p1_corec.log 2>&1
# ③ 后端/内核单元
nice -n 19 ./build/corec check src/compiler/ccr_io.cr --type-shadow >> /tmp/p1_corec.log 2>&1
```
（`check` 路径若不带影子通道穿透，改用 `build … --type-shadow` 并丢弃产物；实现者按实际可用路径落，报告写明。）

- [ ] **Step 2: 汇总差异**：从日志抽 `[type-shadow]` 摘要行；若有 dump 文件则按 `kind` 分类统计 Top 差异（`old_looser` 优先——那是真正的收紧面）。
  **未知桶须拆两因**（Task 2 落地时同记 `kind=0`）：① **任一侧无法翻译**（桥接返回 -1，如未支持的 kind）；② **引擎三态 -1**（AK_NAMED 未展开 / 预算耗尽 / 未覆盖面）。Task 3 归因前**必须先把这两类分开统计**（否则「设计预期的 AK_NAMED 未知」会与「桥接缺口」混为一谈）。
  **dyn 类必须单列**：`TYP_DYN`（dyn 位图）按计划映射为 `AK_DYN`（=⊤）属**潜在**过宽近似（Task 1 评审：全仓仅 row 7 一处且今日被快路径截获、无位图 dyn 构造点）→ 凡两侧任一带 dyn 条目的差异一律归入「近似噪声」类，**不得计入收紧面/宽松面**，报告中单列计数与样本。
  **`&T` vs `&mut T` 必须单列**：桥接把 `TYP_REF` 译为 `AK_REF[inner]`（**丢 mut**）而旧 `type_equal` 比较 mut → 该对会**稳定产出**差异；归「已知 by-design（引用可变性 = P3「条目化 + 变型」面）」，**不得计入收紧面**（同款：PTR 的 `address_space` 旧亦不比 → 无差异，无需处理）。

- [ ] **Step 3: 写 findings 文档**（`docs/superpowers/specs/2026-09-10-type-shadow-findings.md`）：逐语料的计数表 + 差异样本（site/t1/t2/旧/新）+ 初步归因（结构性 vs 未覆盖面 vs 真收紧）+ 后续裁决建议（哪些进 P2 的替换清单、哪些需补引擎规则）。

- [ ] **Step 4: 提交**：`docs: R2 P1 Task 3——影子对拍差异清单（三档语料计数 + 分类样本 + 归因与裁决建议）`

---

## Task 4: 收官（回归 + 自举 + 文档/台账）

- [ ] **Step 1: 全量回归**（同 P0 Task 5 的 13 项清单 + `selftest-types`）
- [ ] **Step 2: 两态零变化复验**（Task 2 Step 5 的命令，含 `check` 与 `build` 两条路径）
- [ ] **Step 3: 自举链**（`corec2`→`corec3` `cmp` IDENTICAL + N06=0 + 冒烟 rc=42）
- [ ] **Step 4: 文档**：spec §9 P1 行标 ✅ + 落点；TODO 登记（影子模式开关的默认值与产物影响、差异清单的后续裁决归属）；台账
- [ ] **Step 4b: 挂账清零**（按 Task 1/Task 2 评审实际状态更新）：
  - ~~① `build_selfhost_native.py:309` 注释更正~~ ——**已被 Task 2 提交完成，核销即可**（Task 2 评审 M2 提示勿重复劳动）
  - ② Task 1 评审「>1024 条目第二次重建无实测」——补一条守门用例或如实登记
  - ③ **既有缺陷登记（最小复现已由 Task 2 评审更正）**：**函数体内嵌套 `fn` 声明 → 编译 rc=139**（min4/min6 同族；mini6 **无** `@inline`——原报告措辞有误）；崩点在 parse→checker 之间（日志止于 `[3/5] parse...`）；**两版编译器均复现**（非影子层引入）→ TODO #16
  - ④ **Task 2 评审 M3**：`src/compiler/type_terms.cr:73` 头注「corearch/corelsp 不受影响」半句陈旧（corelsp 自 Task 2 起必须链接引擎层）→ 更正
  - ⑤ Task 2 评审 M5：站点 4 因 `res_call_type` 无 `EXPR_ARRAY`/tuple 分支将**恒 agree** → Task 3 findings 中不得据「站点 4 零差异」判该面收敛（写入 findings 文档的限制说明）
- [ ] **Step 5: 提交**（路径限定）

---

## 自检记录

- **spec 覆盖**：§4 步 2（旁挂对拍）→ Task 1-2；§8 判据 3（对拍层：零差异门才允许替换）→ Task 3（清单产出，替换门属 P2）；§9 P1 行 → Task 4。
- **占位符扫描**：无 TBD；`sh_tuple_to_product` 明确要求实现者按实际 tuple 访问器落并给签名（非「稍后填」）。
- **命名一致性**：`sh_*`（影子）与 `tt_*`/`ty_*`（引擎）分工清晰；`type_equal_core` 改名后内部递归与外部调用边界在 Task 2 Step 1 写明。
- **风险注记**：① 影子必须**不改变** `ty_budget_reset`/memo 的语义外溢 → `sh_compare` 前后各重置一次预算；② `check` 路径能否穿透旗标未验证 → Task 3 Step 1 给了退路（`build` + 丢产物）并要求报告写明；③ 差异量可能很大 → 环形缓冲上限 256 条 + 计数不封顶。
