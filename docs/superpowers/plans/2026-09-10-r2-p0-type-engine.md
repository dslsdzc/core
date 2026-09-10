# R2 P0（建层）实施计划：类型项表 + 语义包含引擎 + 判定用例表

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 R2 建「类型项层 + 语义包含引擎」的地基：集合语义的类型项 DAG 表、NNF/DNF 规范化、包含/等价/不相交/可空/反例判定 API（三态 + 预算守卫）、数据驱动判定用例表与 `corec selftest-types` 自测通道——**checker 零改动、产物零变化**。

**Architecture:** 三个新文件分工：`type_terms.cr`（类型项表 + 构造/去重 + 规范化）、`type_engine.cr`（判定 API + 原子互斥公理 + μ memo + 预算守卫）、`type_selftest.cr`（用例表 + 自测驱动）。引擎自带原子类 id（`AK_*`）与 `g_types` 行解耦，natives 用 1:1 映射，结构/命名原子挂 `g_types` 行（`-1` = 类级）。**不改 checker / ir_gen / 后端 / 解释器**——P0 不改判据行为，只建能力。

**Tech Stack:** Core 自举栈（self-hosted 编译器 `src/compiler/`）；扁平字节缓冲表（`string` + `w64/r64` + `grow_*` + `ESZ_*/OFF_*` 常量，先例 `g_types`/`g_ifaces`）；CLI 通道（`cli_cmd` + `corec_main` 分派）；Python 测试包装（`tests/selfhost/test_*.py` 风格，subprocess 调 `./build/corec`）。

**Spec:** `docs/superpowers/specs/2026-09-10-type-interface-unification-design.md`（§0 裁决 / §1 语义基座 / §3 类型项层与引擎 / §4 步 1 建层 / §9 P0）。

## Global Constraints

- **jj only**：版本控制一律 `jj`（git 被 hook 机械拦截）；**提交必须路径限定**（多 agent 共用工作副本）：
  `jj commit <本次改动的精确文件...> -m '<中文，前缀 feat:/docs:/test:>'`
- **CPU 限速**：所有编译/测试命令必须 `nice -n 19` 前缀（铁律 #6）。
- **文件永久不允许还原**；不得绕过/变通；根因修复。
- **P0 零行为改动**：`checker.cr` / `ir_gen.cr` / `interp.cr` / 后端与内核文件**一行不动**；现有程序的编译产物 **byte-identical**（判据见 Task 5）。
- **diff 校验规范式样**（本机 `jj diff` 默认 color-words 无 `+` 前缀，`grep '^+'` 恒真空通过；grep 实为 ugrep）：
  ```bash
  jj diff --git <paths...> | grep '^[+]' | grep -v -e '^[+][+][+]'      # 逐行核新增
  jj diff --git <paths...> | grep -c '^[-]'                             # 期望 0（除计划性替换）
  ```
- 环境陷阱：noclobber（`>` 覆盖已存在文件失败 → 用 `>|` 或先删）；变量展开不分词。
- **新文件必须注册三处**（否则构建静默缺件）：
  1. `src/compiler/_import.cr`（project-mode 解析链）
  2. `build_selfhost_native.py` 的 **corec 清单**（`corec_files`，顺序 = 行为定义面：置于 `src/compiler/checker.cr` 之后、`ir_gen.cr` 之前）
  3. `tests/selfhost/test_compile.py` 的 `concat_sources()` 清单（同位置）
  （`corelsp` / `corearch` 清单 P0 **不加**：引擎尚无消费者。）
- **判据铁律**：`corec selftest-types` 全 PASS + 末行计数断言 + 无 `FAIL` 行；全回归绿；自举 `corec2/corec3` `cmp` IDENTICAL + N06=0。

---

## 文件结构（P0）

| 文件 | 责任 |
|---|---|
| `src/compiler/type_terms.cr`（新建） | 类型项表 `g_type_terms` + 构造/去重（DAG）+ 访问器 + NNF + DNF 规范化 |
| `src/compiler/type_engine.cr`（新建） | 原子类 id/互斥公理 + 判定 API（`ty_sub`/`ty_equiv`/`ty_disjoint`/`ty_inhabited`/`tt_witness`）+ memo + 预算守卫 |
| `src/compiler/type_selftest.cr`（新建） | 用例表（数据驱动）+ `type_selftest_run()` 驱动（打印 PASS/FAIL + 摘要，返回 rc） |
| `src/compiler/globals.cr`（修改） | 新增表全局声明（`g_type_terms` / `g_tt_*` / memo / budget） |
| `src/compiler/dyn_arr.cr`（修改） | `grow_type_terms` / `grow_tt_index` 扩容 |
| `src/compiler/main.cr`（修改） | `cli_cmd("selftest-types", ...)` + `corec_main` 分派 |
| `src/compiler/_import.cr`（修改） | 注册三个新模块 |
| `build_selfhost_native.py`（修改） | corec 清单加三个文件 |
| `tests/selfhost/test_compile.py`（修改） | concat 清单加三个文件 |
| `tests/selfhost/test_type_engine.py`（新建） | 子进程跑 `corec selftest-types`，断言 rc/摘要/零 FAIL |

---

## Task 1: 类型项表 + 构造 API + 自测通道骨架

**Files:**
- Create: `src/compiler/type_terms.cr`
- Create: `src/compiler/type_selftest.cr`
- Modify: `src/compiler/globals.cr`（表全局声明）、`src/compiler/dyn_arr.cr`（扩容）、`src/compiler/main.cr`（CLI）、`src/compiler/_import.cr`、`build_selfhost_native.py`、`tests/selfhost/test_compile.py`
- Create: `tests/selfhost/test_type_engine.py`

**Interfaces（本任务产出，后续任务依赖，签名不可改）：**

```
// —— 标签常量（type_terms.cr）——
TT_BOT=0  TT_TOP=1  TT_TOP_K=2  TT_UNION=3  TT_INTER=4  TT_NOT=5
TT_MU=6   TT_ATOM=7 TT_VAR=8    TT_NIL=9    TT_CONS=10
ESZ_TYPE_TERM=48   // {tag, a, b, c, d, hash} 各 8B
OFF_TT_TAG=0 OFF_TT_A=8 OFF_TT_B=16 OFF_TT_C=24 OFF_TT_D=32 OFF_TT_HASH=40

// —— 构造（全部返回类型项行号；DAG 去重）——
fn tt_term(tag: int, a: int, b: int, c: int, d: int) -> int   // 构造/复用
fn tt_bot() -> int
fn tt_top() -> int
fn tt_top_k(atom_kind: int) -> int
fn tt_union(a: int, b: int) -> int
fn tt_inter(a: int, b: int) -> int
fn tt_not(a: int) -> int
fn tt_mu(var: int, body: int) -> int
fn tt_var(v: int) -> int
fn tt_atom(atom_kind: int, atom_ti: int, params: int) -> int   // params = CONS 链或 -1
fn tt_nil() -> int
fn tt_cons(head: int, tail: int) -> int

// —— 访问器 ——
fn tt_tag(i: int) -> int
fn tt_a(i: int) -> int
fn tt_b(i: int) -> int
fn tt_c(i: int) -> int
fn tt_d(i: int) -> int
fn tt_count() -> int

// —— 自测（type_selftest.cr）——
fn type_selftest_run() -> int   // 0 = 全过；1 = 有失败（打印每例 PASS/FAIL + 末行 "N/M type-engine cases passed"）
```

- [ ] **Step 1: 写失败测试 `tests/selfhost/test_type_engine.py`**

```python
#!/usr/bin/env python3
"""R2 P0 判据：类型项引擎自测通道（corec selftest-types）。

引擎 = 集合语义的包含判定（spec docs/superpowers/specs/2026-09-10-type-interface-unification-design.md §3）。
P0 只建层：checker 零改动、产物零变化；判据 = 用例表全 PASS + 零 FAIL + 计数行。
"""

import re
import subprocess
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"


def run_selftest():
    return subprocess.run(
        ["nice", "-n", "19", str(COREC), "selftest-types"],
        cwd=BASE, capture_output=True, text=True,
    )


def test_selftest_types_all_pass():
    r = run_selftest()
    out = r.stdout + r.stderr
    assert "FAIL" not in out, out
    m = re.search(r"(\d+)/(\d+) type-engine cases passed", out)
    assert m, out
    passed, total = int(m.group(1)), int(m.group(2))
    assert passed == total and total >= 20, (passed, total, out)
    assert r.returncode == 0, (r.returncode, out)


if __name__ == "__main__":
    test_selftest_types_all_pass()
    print("PASS test_selftest_types_all_pass")
```

- [ ] **Step 2: 运行确认「红」**

```bash
nice -n 19 python3 tests/selfhost/test_type_engine.py
```
Expected: FAIL —— `selftest-types` 未注册（`corec` 打印未知子命令/无 `N/M ... passed` 行）。

- [ ] **Step 3: 表全局声明（`src/compiler/globals.cr`）**

追加（与既有表声明同风格）：

```core
// R2 P0 类型项引擎：类型项 DAG 表 + 结构哈希索引 + 判定 memo + 预算守卫
g_type_terms : string, mut;        g_type_term_count : int, mut;   g_type_term_cap : int, mut;
g_tt_index : string, mut;          g_tt_index_cap : int, mut;      g_tt_index_count : int, mut;
g_tt_nil : int, mut;               g_tt_top : int, mut;
g_ty_memo_keys : string, mut;      g_ty_memo_vals : string, mut;
g_ty_memo_count : int, mut;        g_ty_memo_cap : int, mut;
g_ty_steps : int, mut;             g_ty_budget_max : int, mut;     g_ty_exhausted : int, mut;
g_ty_lits : string, mut;           g_ty_lits_cap : int, mut;       g_ty_lits_count : int, mut;
g_ty_uncovered : int, mut;         // 未覆盖面命中位（如 AK_NAMED 具体行不展开）——P0 只登记不消费
```

- [ ] **Step 4: 扩容函数（`src/compiler/dyn_arr.cr`）**

追加（照 `grow_types` 先例）：

```core
fn grow_type_terms(needed: int) {
    if needed < g_type_term_cap { return; }
    nc : ., mut = g_type_term_cap * 2;
    if nc < 256 { nc = 256; }
    if nc < needed { nc = needed + 64; }
    nb := alloc(nc * ESZ_TYPE_TERM);
    _dyncpy(g_type_terms, g_type_term_cap * ESZ_TYPE_TERM, nb);
    g_type_terms = nb;
    g_type_term_cap = nc;
}

fn grow_tt_index(needed: int) {
    // 开放寻址索引：容量取 2 的幂、≥ 2×项数（重建式扩容，见 type_terms.cr 的 tt_reindex）
    if needed < g_tt_index_cap { return; }
    nc : ., mut = 1024;
    loop { if nc >= needed { break; } nc = nc * 2; }
    nb := alloc(nc * 8);
    i : ., mut = 0;
    loop { if i >= nc { break; } w64(nb, i * 8, -1); i = i + 1; }
    g_tt_index = nb;
    g_tt_index_cap = nc;
    g_tt_index_count = 0;
    tt_reindex();
}
```

- [ ] **Step 5: 类型项表 + 构造 API（`src/compiler/type_terms.cr`）**

```core
// R2 P0：类型项表（集合语义的类型项 DAG）
// 语义见 spec §1：τ ::= ⊥ | ⊤ | ⊤ₖ | τ₁∪τ₂ | τ₁∩τ₂ | ¬τ | μX.τ | X | k(τ₁…τₙ)
// 条目 48B {tag, a, b, c, d, hash}；同构项共享（DAG），索引 = 开放寻址哈希表 g_tt_index。
// 本文件只做「表示 + 规范化」；判定在 type_engine.cr。

// 标签常量
TT_BOT : int = 0;   TT_TOP : int = 1;   TT_TOP_K : int = 2;
TT_UNION : int = 3; TT_INTER : int = 4; TT_NOT : int = 5;
TT_MU : int = 6;    TT_ATOM : int = 7;  TT_VAR : int = 8;
TT_NIL : int = 9;   TT_CONS : int = 10;
ESZ_TYPE_TERM : int = 48;
OFF_TT_TAG : int = 0;  OFF_TT_A : int = 8;   OFF_TT_B : int = 16;
OFF_TT_C : int = 24;   OFF_TT_D : int = 32;  OFF_TT_HASH : int = 40;

fn tt_tag(i: int) -> int { return r64(g_type_terms, i * ESZ_TYPE_TERM + OFF_TT_TAG); }
fn tt_a(i: int) -> int { return r64(g_type_terms, i * ESZ_TYPE_TERM + OFF_TT_A); }
fn tt_b(i: int) -> int { return r64(g_type_terms, i * ESZ_TYPE_TERM + OFF_TT_B); }
fn tt_c(i: int) -> int { return r64(g_type_terms, i * ESZ_TYPE_TERM + OFF_TT_C); }
fn tt_d(i: int) -> int { return r64(g_type_terms, i * ESZ_TYPE_TERM + OFF_TT_D); }
fn tt_count() -> int { return g_type_term_count; }

fn tt_hash5(tag: int, a: int, b: int, c: int, d: int) -> int {
    // FNV-1a 变体：逐槽 fold（确定性、与插入顺序无关——DAG 去重的键）
    h : ., mut = 1469598103934665603;
    slot : ., mut = 0;
    loop {
        if slot >= 5 { break; }
        v : ., mut = tag;
        if slot == 1 { v = a; } else if slot == 2 { v = b; }
        else if slot == 3 { v = c; } else if slot == 4 { v = d; }
        k : ., mut = 0;
        loop {
            if k >= 8 { break; }
            byte := (v - (v / 256) * 256);
            h = h ^ byte;
            h = h * 1099511628211;
            v = v / 256;
            k = k + 1;
        }
        slot = slot + 1;
    }
    return h;
}

fn tt_mod(h: int, cap: int) -> int {
    // 非负取模（**必须用这个，不要写 h - (h/cap)*cap**）：
    // i64 除法向零截断——h 为负时上式得到负下标 → 探针越界 → 去重静默失效
    // （2026-09-10 P0 Task 1 压力测试实证：扩容后 dedup 全灭）。
    m : ., mut = h / 2;          // 折半再去符号：避免 i64min 直接取负溢出
    if m < 0 { m = 0 - m; }
    return m - (m / cap) * cap;
}

fn tt_reindex() {
    // 重建索引（扩容后调用）：遍历现有项，重放开放寻址插入
    i : ., mut = 0;
    loop {
        if i >= g_type_term_count { break; }
        h := r64(g_type_terms, i * ESZ_TYPE_TERM + OFF_TT_HASH);
        p : ., mut = tt_mod(h, g_tt_index_cap);
        loop {
            if r64(g_tt_index, p * 8) < 0 { break; }
            p = p + 1; if p >= g_tt_index_cap { p = 0; }
        }
        w64(g_tt_index, p * 8, i);
        g_tt_index_count = g_tt_index_count + 1;
        i = i + 1;
    }
}

fn tt_same(i: int, j: int) -> int {
    if tt_tag(i) != tt_tag(j) { return 0; }
    if tt_a(i) != tt_a(j) { return 0; }
    if tt_b(i) != tt_b(j) { return 0; }
    if tt_c(i) != tt_c(j) { return 0; }
    if tt_d(i) != tt_d(j) { return 0; }
    return 1;
}

fn tt_term(tag: int, a: int, b: int, c: int, d: int) -> int {
    // 构造/复用：查哈希索引（开放寻址），未命中则追加
    if g_tt_index_cap <= 0 { grow_tt_index(2); }
    h := tt_hash5(tag, a, b, c, d);
    p : ., mut = tt_mod(h, g_tt_index_cap);   // 非负取模（见 tt_mod 注释：负数取模是越界静默失效源）
    loop {
        idx := r64(g_tt_index, p * 8);
        if idx < 0 { break; }
        if r64(g_type_terms, idx * ESZ_TYPE_TERM + OFF_TT_HASH) == h {
            if tt_tag(idx) == tag && tt_a(idx) == a && tt_b(idx) == b
               && tt_c(idx) == c && tt_d(idx) == d { return idx; }
        }
        p = p + 1; if p >= g_tt_index_cap { p = 0; }
    }
    grow_type_terms(g_type_term_count + 1);
    if (g_type_term_count + 1) * 2 >= g_tt_index_cap { grow_tt_index((g_type_term_count + 1) * 2); return tt_term(tag, a, b, c, d); }
    i := g_type_term_count;
    w64(g_type_terms, i * ESZ_TYPE_TERM + OFF_TT_TAG, tag);
    w64(g_type_terms, i * ESZ_TYPE_TERM + OFF_TT_A, a);
    w64(g_type_terms, i * ESZ_TYPE_TERM + OFF_TT_B, b);
    w64(g_type_terms, i * ESZ_TYPE_TERM + OFF_TT_C, c);
    w64(g_type_terms, i * ESZ_TYPE_TERM + OFF_TT_D, d);
    w64(g_type_terms, i * ESZ_TYPE_TERM + OFF_TT_HASH, h);
    g_type_term_count = i + 1;
    w64(g_tt_index, p * 8, i);
    g_tt_index_count = g_tt_index_count + 1;
    return i;
}

fn tt_bot() -> int { return tt_term(TT_BOT, 0, 0, 0, 0); }
fn tt_top() -> int { if g_tt_top < 0 { g_tt_top = tt_term(TT_TOP, 0, 0, 0, 0); } return g_tt_top; }
fn tt_top_k(k: int) -> int { return tt_term(TT_TOP_K, k, 0, 0, 0); }
fn tt_union(a: int, b: int) -> int {
    if a == b { return a; }
    if tt_tag(a) == TT_BOT { return b; }
    if tt_tag(b) == TT_BOT { return a; }
    if tt_tag(a) == TT_TOP || tt_tag(b) == TT_TOP { return tt_top(); }
    return tt_term(TT_UNION, a, b, 0, 0);
}
fn tt_inter(a: int, b: int) -> int {
    if a == b { return a; }
    if tt_tag(a) == TT_TOP { return b; }
    if tt_tag(b) == TT_TOP { return a; }
    if tt_tag(a) == TT_BOT || tt_tag(b) == TT_BOT { return tt_bot(); }
    return tt_term(TT_INTER, a, b, 0, 0);
}
fn tt_not(a: int) -> int {
    if tt_tag(a) == TT_BOT { return tt_top(); }
    if tt_tag(a) == TT_TOP { return tt_bot(); }
    if tt_tag(a) == TT_NOT { return tt_a(a); }   // 双重否定免费
    return tt_term(TT_NOT, a, 0, 0, 0);
}
fn tt_mu(v: int, body: int) -> int { return tt_term(TT_MU, v, body, 0, 0); }
fn tt_var(v: int) -> int { return tt_term(TT_VAR, v, 0, 0, 0); }
fn tt_nil() -> int { if g_tt_nil < 0 { g_tt_nil = tt_term(TT_NIL, 0, 0, 0, 0); } return g_tt_nil; }
fn tt_cons(head: int, tail: int) -> int { return tt_term(TT_CONS, head, tail, 0, 0); }
fn tt_atom(ak: int, ti: int, params: int) -> int { return tt_term(TT_ATOM, ak, ti, params, 0); }
```

- [ ] **Step 6: 自测骨架（`src/compiler/type_selftest.cr`）**

```core
// R2 P0：类型项引擎判定用例表（数据驱动）+ 自测驱动。
// 判据：corec selftest-types → 每例一行 PASS/FAIL，末行 "N/M type-engine cases passed"，rc=0 全过。
// 说明：本文件只依赖 type_terms.cr / type_engine.cr 的公开 API（签名见计划 Task 1/Task 3）。

fn ts_check(name: string, got: int, want: int) -> int {
    if got == want {
        print("PASS "); println(name);
        return 0;
    }
    print("FAIL "); print(name);
    print(": got "); print(int_str(got));
    print(" want "); println(int_str(want));
    return 1;
}

fn type_selftest_run() -> int {
    fails : ., mut = 0;
    total : ., mut = 0;

    // --- P0 最小用例（Task 3/4 扩充为 spec §8 全类：子类型/等价/不相交/可空/反例/穷尽性/递归/参数化/预算）---
    a_int := tt_atom(AK_INT, TI_INT, -1);
    a_str := tt_atom(AK_STRING, TI_STR, -1);

    total = total + 1; fails = fails + ts_check("unit.bot_sub_int", ty_sub(tt_bot(), a_int), 1);
    total = total + 1; fails = fails + ts_check("unit.int_sub_str",  ty_sub(a_int, a_str), 0);
    total = total + 1; fails = fails + ts_check("unit.int_sub_int",  ty_sub(a_int, a_int), 1);
    total = total + 1; fails = fails + ts_check("unit.dedup",       (tt_union(a_int, a_str) == tt_union(a_int, a_str)), 1);
    total = total + 1; fails = fails + ts_check("unit.notnot",      (tt_not(tt_not(a_int)) == a_int), 1);

    print(int_str(total - fails)); print("/"); print(int_str(total)); println(" type-engine cases passed");
    if fails != 0 { return 1; }
    return 0;
}
```

- [ ] **Step 7: `type_engine.cr` 最小桩（供 Step 6 编译通过；Task 3 补全判定）**

```core
// R2 P0：类型项判定引擎（语义包含）。
// 本文件在 Task 3 补全；Task 1 只放原子类常量 + ty_sub 桩（保证骨架可编译可跑）。
AK_INT : int = 0;      AK_DEX : int = 1;     AK_STRING : int = 2;   AK_BOOL : int = 3;
AK_UNIT : int = 4;     AK_NEVER : int = 5;   AK_CHAR : int = 6;     AK_DYN : int = 7;
AK_PRODUCT : int = 8;  AK_SUM : int = 9;     AK_SEQUENCE : int = 10;
AK_REF : int = 11;     AK_PTR : int = 12;    AK_FN : int = 13;      AK_NAMED : int = 14;

fn ty_sub(a: int, b: int) -> int {   // 桩：Task 3 替换为真判定（三态 1/0/-1）
    if a == b { return 1; }
    if tt_tag(b) == TT_TOP { return 1; }
    if tt_tag(a) == TT_BOT { return 1; }
    return 0;
}
```

- [ ] **Step 8: CLI 注册（`src/compiler/main.cr`）**

在 `corec_main()` 的子命令注册段（`cli_cmd("clean-cache", ...)` 之后）追加：

```core
    cli_cmd("selftest-types", "Run type-engine self tests (R2 P0)");
```

并在命令分派区（与 `cli_eq(cmd, "run")` 等同级）追加：

```core
    if cli_eq(cmd, "selftest-types") { return type_selftest_run(); }
```

- [ ] **Step 9: 清单注册（三处）**

1. `src/compiler/_import.cr`：在 `import checker` 之后加 `import type_terms` / `import type_engine` / `import type_selftest`
2. `build_selfhost_native.py`：`corec_files` 列表在 `'src/compiler/checker.cr',` 之后插入三行
3. `tests/selfhost/test_compile.py`：`concat_sources()` 的 `files` 列表同样位置插入三行

- [ ] **Step 10: 重建 + 跑测试**

```bash
nice -n 19 python3 build_selfhost_native.py      # BUILD SUCCESS + [GUARD] manifest OK + build log clean
nice -n 19 ./build/corec selftest-types          # 期望 5/5 ... passed、rc=0
nice -n 19 python3 tests/selfhost/test_type_engine.py   # 期望 PASS
nice -n 19 ./build/corec run 'fn main()->int{return 42;}'   # 期望 rc=42（既有行为不动）
```
Expected: 全绿。

- [ ] **Step 11: 提交（路径限定）**

```bash
jj commit src/compiler/type_terms.cr src/compiler/type_engine.cr src/compiler/type_selftest.cr \
  src/compiler/globals.cr src/compiler/dyn_arr.cr src/compiler/main.cr src/compiler/_import.cr \
  build_selfhost_native.py tests/selfhost/test_compile.py tests/selfhost/test_type_engine.py \
  -m 'feat: R2 P0 Task 1——类型项表（DAG + 哈希去重）+ 构造 API + selftest-types 自测通道骨架（checker 零改动）'
```

---

## Task 2: NNF + DNF 规范化

**Files:**
- Modify: `src/compiler/type_terms.cr`
- Modify: `src/compiler/type_selftest.cr`（加用例）

**Interfaces:**
- Consumes: Task 1 的构造 API
- Produces:
```
fn tt_nnf(i: int) -> int          // 否定下推：¬(∪) → ∩(¬)、¬(∩) → ∪(¬)、¬¬ 消、¬ATOM/¬VAR/¬μ 保留为字面
fn tt_norm(i: int) -> int         // 规范化到 DNF：UNION of INTER-of-literals（literals = ATOM/¬ATOM/VAR/¬VAR/TOP_K）
fn tt_is_dnf(i: int) -> int       // 自测辅助：检查项是否已是 DNF 形态
```

- [ ] **Step 1: 加失败用例（`type_selftest.cr`）**

```core
    // --- 规范化（Task 2）---
    total = total + 1; fails = fails + ts_check("norm.demorgan",
        ty_equiv(tt_not(tt_union(a_int, a_str)), tt_inter(tt_not(a_int), tt_not(a_str))), 1);
    total = total + 1; fails = fails + ts_check("norm.dnf_shape", tt_is_dnf(tt_norm(tt_intersect_union_probe())), 1);
    total = total + 1; fails = fails + ts_check("norm.union_inter_dist",
        ty_equiv(tt_inter(tt_union(a_int, a_str), a_int), a_int), 1);
```
（`tt_intersect_union_probe()` = 构造 `(int ∪ string) ∩ bool` 的探针函数，Task 2 一并加上——它测的是「∩ 分配到 ∪ 后 DNF 不丢项」。）

- [ ] **Step 2: 运行确认「红」**

```bash
nice -n 19 python3 build_selfhost_native.py && nice -n 19 ./build/corec selftest-types
```
Expected: FAIL（`tt_norm`/`tt_is_dnf`/`tt_equiv` 未实现或桩返回 0）。

- [ ] **Step 3: 实现 NNF（`type_terms.cr`）**

```core
// NNF：否定下推（De Morgan + 双重否定消除）；μ 体内照推
fn tt_nnf(i: int) -> int {
    t := tt_tag(i);
    if t == TT_BOT { return tt_top(); }
    if t == TT_TOP { return tt_bot(); }
    if t == TT_NOT { return tt_nnf_neg(tt_a(i)); }
    if t == TT_UNION { return tt_union(tt_nnf(tt_a(i)), tt_nnf(tt_b(i))); }
    if t == TT_INTER { return tt_inter(tt_nnf(tt_a(i)), tt_nnf(tt_b(i))); }
    if t == TT_MU { return tt_mu(tt_a(i), tt_nnf(tt_b(i))); }
    if t == TT_CONS { return tt_cons(tt_nnf(tt_a(i)), tt_nnf(tt_b(i))); }
    if t == TT_ATOM { return tt_atom(tt_a(i), tt_b(i), tt_nnf_list(tt_c(i))); }
    return i;   // 字面：ATOM 参数已推 / VAR / NIL
}

fn tt_nnf_neg(i: int) -> int {   // 计算 ¬i 的 NNF（负位置）
    t := tt_tag(i);
    if t == TT_BOT { return tt_top(); }
    if t == TT_TOP { return tt_bot(); }
    if t == TT_NOT { return tt_nnf(tt_a(i)); }
    if t == TT_UNION { return tt_inter(tt_nnf_neg(tt_a(i)), tt_nnf_neg(tt_b(i))); }
    if t == TT_INTER { return tt_union(tt_nnf_neg(tt_a(i)), tt_nnf_neg(tt_b(i))); }
    if t == TT_MU { return tt_mu(tt_a(i), tt_nnf_neg(tt_b(i))); }
    return tt_not(i);   // 字面取反：¬ATOM / ¬VAR
}
```
（`tt_nnf_list`：对 CONS 链逐元素 `tt_nnf`——新加的小工具函数。）

- [ ] **Step 4: 实现 DNF（`type_terms.cr`）**

```core
// DNF：把 NNF 形态分配到「union of inter-of-literals」。
// 入口先 tt_nnf；分配律在 INTER 节点上做（左右各自 DNF 后笛卡尔积）。
// 简化：单元素 union/inter 不建节点；∩ 左/右为 union 时展开（分配律）；结果项去重靠 tt_term 的 DAG。
fn tt_norm(i: int) -> int { return tt_dnf(tt_nnf(i)); }

fn tt_dnf(i: int) -> int {
    t := tt_tag(i);
    if t == TT_UNION { return tt_union(tt_dnf(tt_a(i)), tt_dnf(tt_b(i))); }
    if t == TT_INTER {
        l := tt_dnf(tt_a(i)); r := tt_dnf(tt_b(i));
        if tt_tag(l) == TT_UNION { return tt_dnf(tt_inter(tt_a(l), r)); }   // (A∪B)∩C → (A∩C)∪(B∩C)
        if tt_tag(r) == TT_UNION { return tt_dnf(tt_inter(l, tt_a(r))); }
        return tt_inter(l, r);   // 已规范化（若为 ∩-链，由构造保证扁平）
    }
    if t == TT_MU { return tt_mu(tt_a(i), tt_dnf(tt_b(i))); }
    return i;   // 字面
}

// DNF 形态判定：UNION 的每个子项必须是「product 或 literal」（不得再嵌 UNION）；
// INTER 链的叶子必须全是 literal；literal = ATOM / ¬ATOM / VAR / ¬VAR / TOP_K / ⊥
fn tt_is_dnf(i: int) -> int {
    t := tt_tag(i);
    if t == TT_UNION {
        if tt_is_dnf(tt_a(i)) == 0 { return 0; }
        return tt_is_dnf(tt_b(i));
    }
    // 非 UNION 位置：不许出现 UNION（上面已递归剥掉），检查 product/literal 形态
    if t == TT_INTER { return tt_is_product_chain(i); }
    return tt_is_literal(i);
}

fn tt_is_product_chain(i: int) -> int {
    if tt_tag(i) == TT_INTER {
        if tt_tag(tt_a(i)) == TT_UNION || tt_tag(tt_b(i)) == TT_UNION { return 0; }
        if tt_is_product_chain(tt_a(i)) == 0 { return 0; }
        return tt_is_product_chain(tt_b(i));
    }
    return tt_is_literal(i);
}
```
（`tt_is_literal` 已在 Task 3 Step 3 定义——**依赖顺序**：Task 2 落地时先补一个最小 `tt_is_literal`（语义同 Task 3 版本），Task 3 再替换为最终版；两版语义必须一致。）

- [ ] **Step 5: 跑测试确认变绿**

```bash
nice -n 19 python3 build_selfhost_native.py && nice -n 19 ./build/corec selftest-types
nice -n 19 python3 tests/selfhost/test_type_engine.py
```
Expected: 全部 PASS（计数行 ≥ 8）。

- [ ] **Step 6: 提交**

```bash
jj commit src/compiler/type_terms.cr src/compiler/type_selftest.cr -m 'feat: R2 P0 Task 2——NNF（否定下推）+ DNF 规范化（∪/∩ 分配律）+ 形态自测'
```

---

## Task 3: 判定引擎（三态 + 原子互斥 + μ memo + 预算守卫）

**Files:**
- Modify: `src/compiler/type_engine.cr`（替换 Task 1 的桩）
- Modify: `src/compiler/type_selftest.cr`（加用例）

**Interfaces:**
- Consumes: Task 1/2 的 API
- Produces（**API 稳定，Task 4/后续 P 期依赖**）：
```
// 三态：1 = 成立；0 = 不成立；-1 = 预算耗尽/不可判定（禁止当 0 用）
fn ty_sub(a: int, b: int) -> int
fn ty_equiv(a: int, b: int) -> int
fn ty_disjoint(a: int, b: int) -> int
fn ty_inhabited(a: int) -> int
fn tt_witness(a: int, b: int) -> int   // A\B 的具体类型项（不可满足时 -1）
fn ty_budget_reset(limit: int)          // 每次顶层判定前调用
fn ty_exhausted() -> int                // 上一次判定是否预算耗尽
// —— 本任务一并实现的内部辅助（签名固定，供 Task 4 复用）——
fn lit_collect(i: int) -> int           // product/字面 → 字面数组（写入 g_ty_lits 侧缓冲），返回字面个数
fn lit_at(k: int) -> int                // 第 k 个字面项（g_ty_lits 读取）
fn lits_contradictory() -> int          // 当前 g_ty_lits 内是否含 X 与 ¬X、或两个互斥原子类 → 1
fn lit_set_covers(n: int, q: int) -> int // 前 n 个字面集合是否覆盖字面 q（lit_covers 扫描）
fn ak_disjoint(x: int, y: int) -> int
```

- [ ] **Step 1: 加失败用例（`type_selftest.cr`）**

```core
    // 深递归探针：μX₀. product<μX₁. product<… int>>（深度 256）——判定展开会耗尽小预算
    // （放在 type_selftest.cr 内，仅自测使用）
    fn tt_mu_probe_deep() -> int {
        acc : ., mut = tt_atom(AK_INT, TI_INT, -1);
        d : ., mut = 0;
        loop {
            if d >= 256 { break; }
            acc = tt_mu(0, tt_atom(AK_PRODUCT, -1, tt_cons(acc, tt_nil())));
            d = d + 1;
        }
        return acc;
    }

    // --- 判定（Task 3）---
    u_is := tt_union(a_int, a_str);
    total = total + 1; fails = fails + ts_check("sub.union_right", ty_sub(a_int, u_is), 1);
    total = total + 1; fails = fails + ts_check("sub.union_left_neg", ty_sub(u_is, a_int), 0);
    total = total + 1; fails = fails + ts_check("sub.inter", ty_sub(tt_inter(a_int, a_str), a_int), 1);
    total = total + 1; fails = fails + ts_check("equiv.absorb", ty_equiv(tt_union(a_int, a_int), a_int), 1);
    total = total + 1; fails = fails + ts_check("disjoint.atoms", ty_disjoint(a_int, a_str), 1);
    total = total + 1; fails = fails + ts_check("disjoint.same", ty_disjoint(a_int, a_int), 0);
    total = total + 1; fails = fails + ts_check("inh.atom", ty_inhabited(a_int), 1);
    total = total + 1; fails = fails + ts_check("inh.contra", ty_inhabited(tt_inter(a_int, tt_not(a_int))), 0);
    total = total + 1; fails = fails + ts_check("inh.mixed_atoms",
        ty_inhabited(tt_inter(a_int, tt_atom(AK_SEQUENCE, -1, -1))), 0);
    total = total + 1; fails = fails + ts_check("topk.sub", ty_sub(a_int, tt_top_k(AK_INT)), 1);
    total = total + 1; fails = fails + ts_check("topk.neg", ty_sub(a_str, tt_top_k(AK_INT)), 0);
    // 预算守卫（深递归爆炸项 + 极小预算 → 三态 -1，且不与"不成立"混淆）
    ty_budget_reset(64);
    total = total + 1; fails = fails + ts_check("budget.unknown", ty_sub(tt_mu_probe_deep(), a_int), -1);
    total = total + 1; fails = fails + ts_check("budget.flag", ty_exhausted(), 1);
    ty_budget_reset(200000);
```

- [ ] **Step 2: 运行确认「红」**（桩返回 0，断言 1/-1 的用例必挂）

- [ ] **Step 3: 实现互斥公理 + 逐字面覆盖（`type_engine.cr`）**

```core
// 原子类互斥（P0 公理表）：不同原子类两两不相交；AK_DYN = ⊤（与所有类相交）。
// 例外：AK_NAMED 的具体行可能展开为其它类——P0 不展开（登记为未覆盖面），按未知处理。
fn ak_disjoint(x: int, y: int) -> int {
    if x == y { return 0; }
    if x == AK_DYN || y == AK_DYN { return 0; }
    if x == AK_NEVER || y == AK_NEVER { return 1; }
    return 1;
}

fn tt_is_literal(i: int) -> int {
    t := tt_tag(i);
    if t == TT_ATOM || t == TT_VAR || t == TT_TOP_K || t == TT_BOT { return 1; }
    if t == TT_NOT {
        it := tt_tag(tt_a(i));
        if it == TT_ATOM || it == TT_VAR || it == TT_TOP_K { return 1; }
    }
    return 0;
}

// 字面覆盖：literal p 是否蕴含 literal q（q 的语义包含 p 的）
fn lit_covers(p: int, q: int) -> int {
    if p == q { return 1; }
    pt := tt_tag(p); qt := tt_tag(q);
    // ⊤ₖ 覆盖同类原子
    if qt == TT_TOP_K {
        if pt == TT_ATOM { return ty_ak_of(p) == tt_a(q); }
        if pt == TT_TOP_K { return tt_a(p) == tt_a(q); }
        return 0;
    }
    if pt == TT_NOT && qt != TT_NOT { return 0; }   // ¬A 不蕴含正字面（除 A=B 已排除）
    return 0;   // 其余一律不覆盖（⊥ 早退由调用方 lits_contradictory 处理）
}
```
（`ty_ak_of(lit)`：ATOM → `tt_a(lit)`；`¬ATOM` → `tt_a(tt_a(lit))`。）

- [ ] **Step 4: 实现判定的 product 覆盖 + μ 展开 + memo + 预算（`type_engine.cr`）**

```core
// 顶层入口：每次重置步数/耗尽位，规范化两侧，逐 product 覆盖判定
fn ty_sub(a: int, b: int) -> int {
    if a == b { return 1; }
    nav := tt_norm(a); nbv := tt_norm(b);
    if nav == nbv { return 1; }
    if tt_tag(nbv) == TT_TOP { return 1; }
    if tt_tag(nav) == TT_BOT { return 1; }
    // A = ⋃ products；每个 product 必须被 B 的某个 product 覆盖
    r := sub_union_covered(nav, nbv, 0);
    if g_ty_exhausted != 0 { return -1; }
    return r;
}

// products 分解：DNF 形态下按 UNION 拆分，叶子 = product（∩-链）或字面
fn prod_covered(p: int, b: int) -> int {
    // b 拆 union：任一 product 覆盖即可
    if tt_tag(b) == TT_UNION { if prod_covered(p, tt_a(b)) == 1 { return 1; } return prod_covered(p, tt_b(b)); }
    // p 与 b 均为 product/字面：收集双方字面集后做覆盖（b ⊆ p）
    //   —— p 是待检查的「更小集合」，b 是候选「更大集合」：需要 b 的每个字面被 p 的某字面蕴含
    plits := lit_collect(p); blits := lit_collect(b);
    bi : ., mut = 0;
    loop {
        if bi >= blits_count { break; }
        bq := blits[bi];
        // ⊥ 早退：p 的字面集内部矛盾 → 空集，覆盖一切
        if lits_contradictory(plits) != 0 { return 1; }
        if !lit_set_covers(plits, bq) { return 0; }
        bi = bi + 1;
    }
    return 1;
}
```
（实现者按此语义实现：`lit_collect` 把 product 拆成字面数组（µ 展开点见下），`lit_set_covers` 用 `lit_covers` 扫描，`lits_contradictory` 检查 `ATOM(k1)` 与 `ATOM(k2)`（k1≠k2 且互斥）或 `X` 与 `¬X`。）

```core
// μ 展开 + memo（假设-判定，最大不动点）：遇到 MU 单步展开，并在假设集中登记 (子项对)
// 预算：每次 sub 调用 g_ty_steps += 1；超 g_ty_budget_max → g_ty_exhausted = 1，返回 -1
fn sub_step(a: int, b: int) -> int {
    g_ty_steps = g_ty_steps + 1;
    if g_ty_steps > g_ty_budget_max { g_ty_exhausted = 1; return -1; }
    mk := ty_memo_find(a, b);
    if mk >= 0 { return r64(g_ty_memo_vals, mk * 8); }
    ...   // 1) a 为 MU → 展开（tt_subst(a 的 var, a 的 body)）后递归
          // 2) b 为 MU → 展开后递归
          // 3) 结果写 memo（三态值）
    return r;
}
```

- [ ] **Step 5: 实现 `ty_equiv` / `ty_disjoint` / `ty_inhabited` / 预算重置**

```core
fn ty_equiv(a: int, b: int) -> int {
    x := ty_sub(a, b); if x != 1 { return x; }
    y := ty_sub(b, a); if y != 1 { return y; }
    return 1;
}
fn ty_disjoint(a: int, b: int) -> int {
    x := ty_inhabited(tt_inter(a, b));
    if x == -1 { return -1; }   // 三态传播：未知不得降级为 0
    if x == 0 { return 1; }
    return 0;
}
fn ty_inhabited(a: int) -> int {
    n := tt_norm(a);
    // DNF 下：存在一个 product，其字面集不矛盾且所有原子类两两相容
    return prod_inhabited_any(n);
}
fn ty_budget_reset(limit: int) { g_ty_steps = 0; g_ty_budget_max = limit; g_ty_exhausted = 0; }
fn ty_exhausted() -> int { return g_ty_exhausted; }
```
（`prod_inhabited_any`：UNION 拆分 + 每个 product 做 `lits_contradictory` 检查；`AK_NAMED` 具体行 P0 不展开——**登记为未覆盖面**，遇到即 `g_ty_exhausted` 语义之外的 `unknown`：返回 -1 并置一个 `g_ty_uncovered` 位，自测里不出现。）

- [ ] **Step 6: 跑测试（含预算用例）**

```bash
nice -n 19 python3 build_selfhost_native.py && nice -n 19 ./build/corec selftest-types
nice -n 19 python3 tests/selfhost/test_type_engine.py
```
Expected: 全 PASS（计数 ≥ 20，含 2 例预算三态）。

- [ ] **Step 7: 提交**

```bash
jj commit src/compiler/type_engine.cr src/compiler/type_selftest.cr \
  -m 'feat: R2 P0 Task 3——语义包含判定（子类型/等价/不相交/可空 + 原子互斥公理 + μ 展开 memo + 三态预算守卫）'
```

---

## Task 4: 反例（witness）+ 穷尽性 + 递归/参数化用例补齐

**Files:**
- Modify: `src/compiler/type_engine.cr`（`tt_witness`、`ty_exhaustive`）
- Modify: `src/compiler/type_selftest.cr`（用例补齐到 spec §8 全类）

**Interfaces:**
- Consumes: Task 3 的判定 API
- Produces:
```
fn tt_witness(a: int, b: int) -> int   // A\B 的类型项（规范化后）；不可满足 → -1
fn ty_exhaustive(domain: int, patterns: int) -> int   // patterns = CONS 链；1 = 穷尽；0 = 有遗漏；-1 = 未知
```

- [ ] **Step 1: 加失败用例（`type_selftest.cr`）**

```core
    // --- 反例 + 穷尽性（Task 4）---
    a_bool := tt_atom(AK_BOOL, TI_BOOL, -1);
    w := tt_witness(a_int, a_str);
    total = total + 1; fails = fails + ts_check("witness.nonempty", (w >= 0), 1);
    total = total + 1; fails = fails + ts_check("witness.sub_of_a", ty_sub(w, a_int), 1);
    total = total + 1; fails = fails + ts_check("witness.not_sub_of_b", ty_sub(w, a_str), 0);
    total = total + 1; fails = fails + ts_check("witness.empty", tt_witness(a_int, a_int), -1);

    dom := tt_union(tt_union(a_int, a_str), a_bool);
    pats := tt_cons(a_int, tt_cons(a_str, tt_nil()));
    total = total + 1; fails = fails + ts_check("exhaust.incomplete", ty_exhaustive(dom, pats), 0);
    miss := ty_exhaust_witness(dom, pats);
    total = total + 1; fails = fails + ts_check("exhaust.witness_bool", ty_equiv(miss, a_bool), 1);
    total = total + 1; fails = fails + ts_check("exhaust.complete",
        ty_exhaustive(dom, tt_cons(a_int, tt_cons(a_str, tt_cons(a_bool, tt_nil())))), 1);

    // --- 递归 + 参数化（Task 4）---
    rec_abs := tt_mu(0, tt_union(a_int, tt_var(0)));   // μX. int ∪ X ≡ int
    total = total + 1; fails = fails + ts_check("rec.absorb", ty_equiv(rec_abs, a_int), 1);
    rec_list := tt_mu(0, tt_union(a_int, tt_atom(AK_PRODUCT, -1, tt_cons(tt_var(0), tt_nil()))));
    total = total + 1; fails = fails + ts_check("rec.inh", ty_inhabited(rec_list), 1);
    total = total + 1; fails = fails + ts_check("rec.sub_self", ty_sub(rec_list, rec_list), 1);
    seq_i := tt_atom(AK_SEQUENCE, -1, tt_cons(a_int, tt_nil()));
    seq_s := tt_atom(AK_SEQUENCE, -1, tt_cons(a_str, tt_nil()));
    total = total + 1; fails = fails + ts_check("param.same", ty_sub(seq_i, seq_i), 1);
    total = total + 1; fails = fails + ts_check("param.invariant_p0", ty_sub(seq_i, seq_s), 0);  // P0 参数不变；变型规则 P3
```

- [ ] **Step 2: 运行确认「红」**（`tt_witness`/`ty_exhaustive` 未实现）

- [ ] **Step 3: 实现 witness（`type_engine.cr`）**

```core
// 反例 = A\B 的规范化项；不可满足（= ⊥）→ -1（无遗漏/无反例值）
fn tt_witness(a: int, b: int) -> int {
    r := tt_norm(tt_inter(a, tt_not(b)));
    if ty_inhabited(r) != 1 { return -1; }
    if tt_tag(r) == TT_BOT { return -1; }
    return r;
}

// 穷尽性：¬(⋃patterns) ∩ domain 可满足 → 有遗漏；witness = 遗漏的具体类型项
fn ty_exhaust_witness(domain: int, patterns: int) -> int {
    acc : ., mut = tt_bot();
    p : ., mut = patterns;
    loop {
        if tt_tag(p) != TT_CONS { break; }
        acc = tt_union(acc, tt_a(p));
        p = tt_b(p);
    }
    return tt_witness(domain, acc);   // domain \ ⋃patterns
}
fn ty_exhaustive(domain: int, patterns: int) -> int {
    w := ty_exhaust_witness(domain, patterns);
    if g_ty_exhausted != 0 { return -1; }
    if w < 0 { return 1; }   // 补集空 = 穷尽
    return 0;
}
```

- [ ] **Step 4: 跑测试（用例表到 spec §8 全类）**

```bash
nice -n 19 python3 build_selfhost_native.py && nice -n 19 ./build/corec selftest-types
nice -n 19 python3 tests/selfhost/test_type_engine.py
```
Expected: 全 PASS，`N/N ... passed` 且 N ≥ 32（子类型/等价/不相交/可空/反例/穷尽性/递归/参数化/预算全类齐）。

- [ ] **Step 5: 提交**

```bash
jj commit src/compiler/type_engine.cr src/compiler/type_selftest.cr \
  -m 'feat: R2 P0 Task 4——反例（witness = A\B 具体类型项）+ 穷尽性（补集空性 + 遗漏 witness）+ 递归/参数化用例补齐（用例表覆盖 spec §8 全类）'
```

---

## Task 5: 收官（回归 + 自举 + 零产物变化 + 文档/台账）

**Files:**
- Modify: `docs/superpowers/specs/2026-09-10-type-interface-unification-design.md`（§9 P0 标记完成）
- Modify: `TODO.md`（登记 P0 落点 + 未覆盖面）
- Modify: `.superpowers/sdd/progress.md`（台账）

- [ ] **Step 1: 全量回归**

```bash
nice -n 19 ./build/corec clean-cache
nice -n 19 python3 tests/selfhost/test_type_engine.py
nice -n 19 python3 tests/selfhost/test_compile.py
nice -n 19 python3 tests/selfhost/test_backend_bootstrap.py
nice -n 19 python3 tests/selfhost/test_hit_table.py
nice -n 19 python3 tests/selfhost/test_ccr_v7.py
nice -n 19 python3 tests/selfhost/test_live_ranges.py
nice -n 19 python3 tests/selfhost/test_slice_bounds.py
nice -n 19 python3 tests/selfhost/test_global_init.py
nice -n 19 python3 tests/selfhost/test_lexer_parity.py
nice -n 19 python3 tests/bootstrap/test_pipeline.py
nice -n 19 python3 tests/bootstrap/test_borrow.py
nice -n 19 python3 tests/bootstrap/test_generics.py
```
Expected: 全绿（13 项）。

- [ ] **Step 2: 零产物变化判据（P0 的硬锚）**

P0 前后各构建同一「无新能力程序」样本，产物必须逐字节相同：

```bash
# 在**本批第一个任务提交之前**的基点捕获基线（若未捕获，用 jj 取父修订重建编译器的做法不可行——
# 改以「同源两次构建」+ 既有套件全绿替代，并在报告显式记录该替代）
nice -n 19 ./build/corec build tests/suite/ptr_arith.cr --static -o /tmp/r2p0_head_bin
cmp /tmp/r1t4_base_bin /tmp/r2p0_head_bin && echo BYTE-IDENTICAL
```
Expected: `BYTE-IDENTICAL`（`/tmp/r1t4_base_bin` = R1 批捕获的同一样本产物，sha256 `95084e7b…d475`；若该文件不在盘上 → 从 `tests/suite/ptr_arith.cr` 重建并在报告记录不可比对）。

- [ ] **Step 3: 自举全链**

```bash
nice -n 19 python3 build_selfhost_native.py                 # BUILD SUCCESS + [GUARD] OK + 日志守卫 clean
nice -n 19 ./build/corec build src/compiler/main.cr -o /tmp/corec2 --static -O 0
/tmp/corec2 build src/compiler/main.cr -o /tmp/corec3 --static -O 0
cmp /tmp/corec2 /tmp/corec3 && echo CMP_IDENTICAL
nice -n 19 ./build/corec run 'fn main()->int{return 42;}'   # rc=42
```
Expected: `CMP_IDENTICAL` + rc=42 + 无 `error[`/N06。

- [ ] **Step 4: 文档与台账**

- spec §9 表 P0 行标 ✅ 已完成 + 记录落点（提交哈希）
- `TODO.md` 新增条目：**P0 未覆盖面登记**（`AK_NAMED` 具体行不展开 → 判定返回 unknown；参数变型规则 = P3；用户接口/载体 = P2/P4）
- `.superpowers/sdd/progress.md` 追加 R2 P0 段

- [ ] **Step 5: 提交**

```bash
jj commit docs/superpowers/specs/2026-09-10-type-interface-unification-design.md TODO.md \
  -m 'docs: R2 P0 收官——用例表全绿 + 全回归 + 零产物变化（byte-identical）+ 自举 cmp IDENTICAL；spec/TODO/台账同步（未覆盖面登记）'
```

---

## 自检记录（写完计划后复核）

- **spec 覆盖**：spec §4 步 1（建层：类型项表 + 引擎 + 查询 API + 用例表；checker 不动）→ Task 1-4；§3.2 判定 API 五函数 → Task 3（三态）/Task 4（witness）；§3.3 规范化/记忆化/位集合快路径/预算守卫 → Task 2（规范化）· Task 3（memo + 预算）· 位集合快路径**不在 P0**（属 P3 穷尽性快路径，已在本计划 Task 4 用判定实现穷尽性）；§8 用例表分层 → Task 4；§9 P0 判据 → Task 5
- **P0 边界守住**：checker/ir_gen/后端/解释器零改动（清单仅加三文件）；查询 API（`iface_*`）= P2 的接线面，P0 只出判定 API（`ty_*`）——spec §3.2 与 §2.5 的分工在计划里明确（`iface_*` 属 P2）
- **占位符扫描**：无 TBD/TODO；Task 2 Step 4 的 `tt_is_dnf` 与 Task 3 Step 4 的 `prod_covered` 给了语义级骨架 + 明确要求（实现者补完辅助函数），非「稍后填」
- **命名一致性**：`tt_*`（构造/访问/规范化）、`ty_*`（判定/预算）、`ak_*`/`AK_*`（原子类）、`ts_check`（自测）在四任务间签名一致；`AK_NAMED` 的两处引用（Task 3 Step 3 与 Step 5）语义一致
- **风险注记**：Task 1 的开放寻址索引在扩容时用 `tt_reindex()` 重建（O(n)），实现者须保证 `grow_tt_index` 后 `tt_reindex` 被调用（计划代码已含）；预算用例依赖 `g_ty_steps` 全局——多例连续跑时每例前须 `ty_budget_reset`（用例表已按此写）
