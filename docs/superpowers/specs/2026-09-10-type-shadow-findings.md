# R2 P1 影子对拍差异清单（三档语料 + 归因与裁决建议）

日期：2026-09-10（Task 3 落地日 2026-09-11 复核）
范围：R2 计划 P1「影子对拍」——把 P0 类型判定引擎与旧 `type_equal_core` 在**真实语料**上逐点对账，
产出「收紧面（old_looser = 旧受新拒）暴露清单」与「未覆盖面清单」，供 P2（替换旧判定）裁决。
上游：P0 引擎（`844cec6c`）+ P1 Task 1 桥接层 + Task 2 挂点/通道（`514956a1`）+ Task 3 Step 0 拆因（本文件对应提交）。

引擎/通道事实来源：`src/compiler/ty_shadow.cr`（桥接 + 挂点 + 摘要/转储）、`src/compiler/checker.cr`（`type_equal` 包装 + 8 站点）、
`src/compiler/type_engine.cr`（三态 + 成因位）。

---

## 0. 结论（TL;DR）

1. **真收紧面 = 0**：三档语料（+2 档扩面）共 **71 个文件 / 26,704 次判定**，`old_looser=0`、`old_stricter=0`。
   全部 9 条差异条目（**去重后仅 3 个类型对**）都落在 `unknown` 桶的 **engine 侧**。
2. **unknown 拆因（Step 0）**：`bridge`（任一侧翻译失败 = 桥接缺口）= **0**；`engine`（引擎三态负值）= **9**，
   其中 **未覆盖面 9 / 预算耗尽 0**。桥接缺口在现有 `TYP_*`×`TY_*` 全集下**结构性不可达**（非语料不足，见 §3.3）。
3. **未覆盖面的实体**：`AK_NAMED` 不展开，且**根因是「同名 named 类型占多行」**——
   `MemLayout`（2 行）、`Box`（5 行）。旧判定按**名**判等（true），桥接按**行号**建原子（两个不同原子 → 引擎判不了 → -1）。
   这是 P2 替换的**硬前置**：不先做名字规范化，替换会把大量「同类型比较」从真变未知（见 §6.F1）。
4. **站点覆盖极不均衡**：74.4% 的判定来自站点 8（`assign-node`），18.4% 来自站点 5（`fn-body-ret`），7.1% 来自站点 7（`if-branch`）；
   **站点 1/2/4/6 全语料 0 命中**，站点 3 仅 2 次。→「零差异」结论**只覆盖赋值/返回/if 合并面**，
   泛型、热补丁、兜底等价面**零证据**（不得据此判这些面收敛）。
5. **三类排除项计数全为 0**（brief 要求单列，见 §5）：dyn 差异 0（且 dyn 行在判定面出现 **0 次**）；
   `&T` vs `&mut T` 差异 0（且 `TYP_REF` 行在判定面出现 **0 次**，源级亦不可构造该对）；
   站点 4 命中 **0**（注意：不是「恒 agree」，而是「本轮语料根本没跑到」）。
6. **另立三类结构性发现**（对 P2/P3 裁决有直接影响，见 §6）：
   F1 同名多行 named 未规范化（P2 硬前置）、F2 数组长度 `N` 旧比引擎不比（替换即放宽，R1 已裁 N 不入身份）、
   F3 调用位点实参类型不匹配**无诊断**（旧判定结果被丢弃）+ F4 泛型函数后续形参声明类型在推断中不生效。

---

## 1. Step 0：unknown 桶拆两因（先改码，再采数）

### 1.1 改动

| 文件 | 改动 |
|---|---|
| `src/compiler/ty_shadow.cr` | `sh_compare`：`a<0 \|\| b<0`（桥接缺口）→ `kind=3` + `g_shadow_unknown_bridge`；`e<0`（引擎负值）→ `kind=0` + `g_shadow_unknown_engine`，并按引擎自报成因位细分 `unc=ty_uncovered()` / `exh=ty_exhausted()`（**必须在第二次 `ty_budget_reset` 之前读**）；`sh_kind_name` 增 `unknown_bridge`；`sh_report` 增 4 个字段（**前 6 字段前缀不变**，既有 grep 读取方不受影响） |
| `src/compiler/globals.cr` | +4 全局：`g_shadow_unknown_bridge` / `g_shadow_unknown_engine` / `g_shadow_unknown_uncovered` / `g_shadow_unknown_budget` |
| `src/compiler/ty_shadow.cr`（Task 3 扩面） | +站点直方图：`sh_site_begin` 累计 8 个站点的**判定次数**（`g_shadow_site_counts`，8×8B），`sh_report` 增第二行 `[type-shadow-sites]`。理由：环形缓冲（256 条）只装「有差异/未知」的条目，**0 差异语料下「某站点是否真的跑到过」没有别的证据通道**，而 brief 要求登记「站点 4 恒 agree / 站点 6 不可达」 |

摘要行（示例，`tests/suite/ptr_arith.cr`）：

```
[type-shadow] decisions=74 agree=74 old_stricter=0 old_looser=0 unknown=0 unknown_bridge=0 unknown_engine=0 unknown_engine_uncovered=0 unknown_engine_budget=0
[type-shadow-sites] hotpatch-ret=0 generic-arg=0 generic-apply-base=0 unify-fallback=0 fn-body-ret=16 assign-binary=0 if-branch=7 assign-node=51
```

转储 kind 空间：`0 = unknown_engine` / `1 = old_stricter` / `2 = old_looser` / `3 = unknown_bridge`（dump 的 `kind` 列同步改名）。

### 1.2 判据（全部通过，原始输出）

```
$ nice -n 19 python3 build_selfhost_native.py
[GUARD] corec: manifest OK (41 files) ; build log clean (error[ = 0, undefined = 0)  -> build/corec
[GUARD] corearch / x86_64-linux target / corelsp 全绿 ; === BUILD SUCCESS ===
$ nice -n 19 ./build/corec selftest-types | tail -1
71/71 type-engine cases passed

$ nice -n 19 ./build/corec clean-cache
cleaned .core/cache/cir/
$ nice -n 19 ./build/corec build tests/suite/ptr_arith.cr --static -o /tmp/p1t3_off2
$ nice -n 19 ./build/corec clean-cache
$ nice -n 19 ./build/corec build tests/suite/ptr_arith.cr --static --type-shadow -o /tmp/p1t3_on2
$ cmp /tmp/r1t4_base_bin /tmp/p1t3_off2 && echo OFF-IDENTICAL
OFF-IDENTICAL
$ cmp /tmp/r1t4_base_bin /tmp/p1t3_on2 && echo ON-IDENTICAL
ON-IDENTICAL
$ sha256sum /tmp/r1t4_base_bin /tmp/p1t3_off2 /tmp/p1t3_on2
95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475  /tmp/r1t4_base_bin
95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475  /tmp/p1t3_off2
95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475  /tmp/p1t3_on2
```

回归（加固判据，非 brief 要求）：`tests/selfhost/test_compile.py` All passed · `test_type_engine.py` PASS ·
`test_impl.py` 7/7 · `test_borrow.py` 7/7。

### 1.3 拆因必要性实证（拆因前后同一条目可复归）

拆因前 dump 里该条目写作 `… unknown 0`，无法分辨「桥接没译出来」与「引擎判不了」。
拆因后同一条目（编译器语料）写作 `fn-body-ret 5 28 25 1 unknown_engine 0`，且摘要给出 `unknown_engine_uncovered=1 / unknown_engine_budget=0`
——**归因可直接读出**（探针副本进一步解析出两侧类型名，见 §4.2）。

---

## 2. 语料、命令与排除

三档 = brief 指定；t4/t5 为**扩面**（同类真实语料，成本 ~1.5s/文件）。全部运行 cwd = 仓库根，**每文件前 `clean-cache`**，
命令模板 = `nice -n 19 ./build/corec check <file> --type-shadow --type-shadow-dump <dump>`。

| 档 | 内容 | 文件数 | 有摘要 | 排除（原因） |
|---|---|---|---|---|
| ① | `tests/suite/*.cr` | 31 | 27 | `test_control_flow.cr` / `test_generics.cr` = **0 字节空文件**（`error: cannot read`；Task 2 报告曾记为「预期失败 fixture」，实为空文件——勘误）；`at_test_mini4.cr` / `at_test_mini6.cr` = rc=139（**函数体内嵌套 fn 声明**，既有缺陷，TODO #16 已登记，非本批回归） |
| ② | `src/compiler/main.cr` + `src/compiler/_import.cr` | 2 | 2 | 无。**注意**：`src/compiler/*` 任一文件的 check 都会经该目录 `_import.cr` 加载**整个编译器**（前端 + stdlib + lattice），故两行是**同一语料**的两次运行（`main.cr` 额外汇总 main.cr 自身的重复贡献 ~120 判定）；「纯整编译器」数取 `_import.cr` 行 |
| ③ | `src/compiler/ccr_io.cr` + 后端/内核单元（`src/format/elf/*` `src/os/linux/*` `src/arch/x86_64/*` `src/lattice/*` `src/targets/x86_64-linux/*`） | 15 | 15 | 无（`src/compiler/elf.cr` 在本轮单独扫描中 rc=0 但 2 个 parse error、decisions=0——**陈旧遗留文件**，不在本档命令内） |
| ④（扩面） | `src/stdlib/*.cr` | 19 | 19 | 无 |
| ⑤（扩面） | `examples/*.cr` | 4 | 4 | `test_scale.cr` / `test_sum.cr` decisions=0（陈旧样例，parse 不通过） |

原始日志：`/tmp/r2p1t3/all_tiers2.txt`（逐文件主行 + 站点行）、`/tmp/r2p1t3/logs2/*.log`（全文）、`/tmp/r2p1t3/dumps2/*.txt`（差异转储）。

**语料自指说明**：②③ 的语料是编译器自身，而 Step 0/扩面对 `ty_shadow.cr`/`globals.cr` 的改动本身也进入该语料 →
同档判定数在仪表化前后有 **+4/+2 的漂移**（如 `main.cr` 3960 → 3964，探针副本再 +2）。这是自指语料的预期行为，不影响分类。

---

## 3. 计数表

### 3.1 主计数（逐档，全部为原始摘要行求和）

| 档 | 文件 | decisions | agree | old_stricter | **old_looser** | unknown | unk_bridge | unk_engine | engine_uncovered | engine_budget |
|---|---|---|---|---|---|---|---|---|---|---|
| ① suite | 27 | 2,743 | 2,740 | 0 | **0** | 3 | 0 | 3 | 3 | 0 |
| ② 编译器自身 | 2 | 7,808 | 7,806 | 0 | **0** | 2 | 0 | 2 | 2 | 0 |
| ③ 后端/内核 | 15 | 13,960 | 13,957 | 0 | **0** | 3 | 0 | 3 | 3 | 0 |
| ④ stdlib | 19 | 2,042 | 2,041 | 0 | **0** | 1 | 0 | 1 | 1 | 0 |
| ⑤ examples | 4 | 151 | 151 | 0 | **0** | 0 | 0 | 0 | 0 | 0 |
| **合计** | **67**（+4 排除） | **26,704** | **26,695** | **0** | **0** | **9** | **0** | **9** | **9** | **0** |

不变式：`agree + stricter + looser + unknown == decisions` 在**全部 71 行**成立（逐行核对，0 违例）。

### 3.2 站点直方图（逐档）

| 档 | hotpatch-ret(1) | generic-arg(2) | generic-apply-base(3) | unify-fallback(4) | fn-body-ret(5) | assign-binary(6) | if-branch(7) | assign-node(8) |
|---|---|---|---|---|---|---|---|---|
| ① suite | 0 | 0 | 2 | 0 | 760 | 0 | 215 | 1,766 |
| ② 编译器自身 | 0 | 0 | 0 | 0 | 1,401 | 0 | 647 | 5,760 |
| ③ 后端/内核 | 0 | 0 | 0 | 0 | 2,217 | 0 | 864 | 10,879 |
| ④ stdlib | 0 | 0 | 0 | 0 | 501 | 0 | 166 | 1,375 |
| ⑤ examples | 0 | 0 | 0 | 0 | 34 | 0 | 15 | 102 |
| **合计** | **0** | **0** | **2** | **0** | **4,913** | **0** | **1,907** | **19,882** |

两行互为校验：`sum(site) == decisions` 全部成立（26,704 = 26,704）。

**占比**：站点 8 = 74.4%、站点 5 = 18.4%、站点 7 = 7.1%、站点 3 = 0.007%；站点 1/2/4/6 = **0**。

### 3.3 桥接缺口（kind=3）= 0 的结构性解释

`sh_term_of_ti` 对 `TYP_BASE/NAMED/ARRAY/SLICE/PTR/REF/TUPLE/DYN/GENERIC_PARAM/GENERIC_APPLY` **全集有分支**
（未知 kind 兜底 → `AK_NAMED`，不是失败）；`sh_base_ak` 对 `TY_*` 全码（`INT/DEX/DEX_S/BOOL/STRING/UNIT/NEVER/CHAR/GENERIC_PARAM`）**逐项有映射**。
故 `-1` 只剩「`ti<0` / 行号越界」两条入口——正常语料不可达。
→ 本桶本轮 = **结构性 0**；拆分的收益是「未来新增 kind/码或行号竞态」的**守门**，不是本轮语料结论。

---

## 4. 差异清单

### 4.1 原始条目（9 条；转储文件逐字）

| # | site | t1 | t2 | old_ok | kind | 来源（档/文件） |
|---|---|---|---|---|---|---|
| 1 | fn-body-ret (5) | 28 | 25 | 1 | unknown_engine (0) | ② `src/compiler/main.cr`、`src/compiler/_import.cr`、③ `ccr_io.cr`（同一整编译器语料，3 行） |
| 2 | fn-body-ret (5) | 27 | 11 | 1 | unknown_engine (0) | ③ `src/targets/x86_64-linux/main.cr` + `_import.cr`（同一组合根语料，2 行） |
| 3 | fn-body-ret (5) | 11 | 9 | 1 | unknown_engine (0) | ① `hotpatch_test.cr`、④ `toml.cr`（同一 stdlib 预导入语料，2 行） |
| 4 | generic-apply-base (3) | 9 | 29 | 1 | unknown_engine (0) | ① `generics_test.cr` |
| 5 | generic-apply-base (3) | 9 | 34 | 1 | unknown_engine (0) | ① `generics_test.cr` |

**旧/新对照**：全部 9 条的旧判定 = **受**（`old_ok=1`），引擎 = **-1（未判定）**，成因位 `unc=1 exh=0`。
即：**没有一条是「旧受新拒」（真收紧面）**，也没有一条是「旧拒新受」——差异全部是「旧能判、引擎判不了」。

### 4.2 归因（行号 → 类型名，探针副本实测）

行号是**类型表行号**（0..8 为原生占位行，用户类型从 9 起；同名类型占多行）。用 `/tmp` 仓库副本加 `[dbg]` 探针（**未触碰仓库文件**）读出行号对应的类型名：

| #（去重对） | 实测 | 旧判定依据 | 引擎判定 | 归因 |
|---|---|---|---|---|
| MemLayout | `named(MemLayout)` vs `named(MemLayout)`（行号随编译单元变化：28/25、27/11、11/9） | `type_equal_core` 的 `TYP_NAMED` 分支比较 **name_idx**（`get_type_data`）→ 同名 = **true** | 桥接把**行号**建成原子 `tt_atom(AK_NAMED, ti, -1)` → 两个不同原子 → `sub_cover` 命中 `AK_NAMED` 不展开 → `g_ty_uncovered=1` → **-1** | **未覆盖面（同名多行）**：`MemLayout`（`src/stdlib/toml.cr:260` 唯一声明）在编译器单元占 **2 行**（`[dbg-dup] MemLayout rows=2`） |
| Box | `named(Box)` vs `named(Box)`（行 9 vs 29、行 9 vs 34） | 同上（按名） | 同上（按行 → 不同原子 → -1） | **未覆盖面（同名多行）**：`Box`（`tests/suite/generics_test.cr:17` 唯一声明）在泛型实例化后占 **5 行**（`[dbg-dup] Box rows=5`） |

**同名多行是语言侧既存事实**（`res_call_type` 在符号不可见处 `alloc_type(TYP_NAMED, name_idx, 0)` 新建行；泛型实例化另建行），
不是影子层的构造。影子层只是**如实按行建原子**，于是暴露了它。

---

## 5. 三类排除项（brief 要求单列；本轮计数**全为 0**）

| 排除项 | 差异条目数 | 参与判定的次数（实测） | 备注 |
|---|---|---|---|
| (a) `dyn`（映射 `AK_DYN`=⊤ 的过宽近似） | **0** | `dyn_involved = **0**`（全语料 66 个有摘要文件求和） | 连 `dyn_test.cr`（88 判定）都 0 参与 → 风险**未触发**（≠ 不存在）；探针 E（`dyn` 值赋给 `int` 变量）在站点 8 判定为 **agree**（旧拒 + 引擎 0），且旧路径另发 `error[TA01]`——dyn 的 ⊤ 过宽在本轮**没有**产生假等价 |
| (b) `&T` vs `&mut T`（桥接丢 mut，旧比 mut = by-design，P3 面） | **0** | `ref_involved = **0**`（同上求和） | 且**源级不可构造**：`&x` 产 **PTR**（探针 A 实测 `q := &x` → `ptr(to=int)`）而非 `TYP_REF`；`TYP_REF` 仅出现在**声明型位置**（`&T`/`&mut T` 形参、`&self`/`&mut self`），而这些行本轮未进入任何判定点（探针 H/I 均 0 命中）。→ 该 by-design 面本轮**零证据**，P3 建模时须补定向样例 |
| (c) 站点 4（`res_call_type` 无 `EXPR_ARRAY`/tuple 分支 → 曾判「恒 agree」） | **0** | `unify-fallback 命中 = **0**` | **勘误**：不是「恒 agree」，而是**本轮语料根本没跑到**（0 命中 = 0 agree）。定向探针实测其行为随 pattern 侧形态分化：**base 对 → agree**（探针 K：`int` vs `str` → 两侧同拒）、**含 named 的对 → unknown（未覆盖面）**（探针 B：`int` vs `named(Q)` → 引擎 -1）。→ 不得据此面判收敛（brief 的告诫成立，理由需更正为「零命中」） |

三项均**未计入**收紧面/宽松面统计（上表与 §3.1 相互独立）。

---

## 6. 结构性发现（本轮最大产出；对 P2/P3 裁决直接相关）

### F1（P2 硬前置）同名 named 多行未规范化 → 替换旧判定会把「真」变「未知」
- 事实：`type_equal_core` 的 `TYP_NAMED` 按 **name_idx** 判等；类型表同一名字可占**多行**（`MemLayout` 2 行、`Box` 5 行；编译器语料 `named_rows=20, dup_groups=1`；generics_test `named_rows=6, dup_groups=1`）。
- 桥接按**行号**建原子 → 同名不同行 = 两个不同原子 → 引擎 **-1**。
- 影响：**9 条差异全部由此产生**（占差异总数 100%）；且这正是 8 个站点的主流量（命名类型比较极常见）。
- 裁决建议：P2 替换**前**必须二选一——① 引擎侧引入 named 身份的规范化（同名 → 同一原子，需 name 注册表）；② 桥接把同名行折叠到同一项（会掩盖「同名不同声明域」的区分，需先裁决同名是否恒等价）。
  未做则该面在替换后从「真」变「未判定」；若 P2 把未判定当拒绝 → **大面积假拒**，若当通过 → **静默失去命名类型检查**。二者都不可接受。

### F2（替换即放宽）数组长度 `N`：旧比、引擎不比
- 事实：`type_equal_core` 的 `TYP_ARRAY` 分支比较 `extra`（= N）；桥接按 R1 裁决**不把 N 入身份**（`AK_SEQUENCE` 参数链只含元素项）。
- 探针 D（`fn ret4() -> [int;3] { b:[int;4]; return b; }`）：旧 = 拒（`error[TF01]`），引擎 = 受 → `old_stricter=1`；探针 G（泛型形参先绑 `[int;3]` 再以 `[int;4]` 调用）：站点 2 同样 `old_stricter=1`。
- 影响：**替换后 N 不匹配的代码会静默通过**（当前是编译错误）。本轮语料 0 触发 → 影响面取决于用户代码。
- 裁决建议：R1 的「N 不入身份」是 IR 侧身份裁决；checker 侧是否保留 N 检查需**单独裁决**（保留 → 需在引擎/桥接把 N 作为维度/字面量入判定；不保留 → 记为有意的语言放宽并写进 spec）。

### F3（旧路径的洞，P2 需接线）调用位点实参类型不匹配**无诊断**
- 事实：`infer_gen_call` 调 `unify_types(pattern_ti, concrete_ti);`（`checker.cr:1053`）**丢弃返回值**；非泛型调用位点同样不报。
  探针证据：`fn take2(n: int)->int` 以 `take2("s")` 调用 → 输出 `ok`（无诊断）；`fn take[T](a: T, n: str)` 以 `take(1, 2)` 调用 → `ok`。
- 与影子的关系：影子只对账 `type_equal` 的 verdict（此例两侧皆「拒」= agree），**不负责诊断**；但 P2 若以引擎判定作为诊断来源，必须补「判定 → 诊断」这一环（含 `unknown` 的处置策略）。
- 建议：单开任务（属 checker 缺陷面，非影子层）。

### F4（新发现，建议单开任务）泛型函数后续形参的声明类型在推断中不生效
- 事实：`fn take[T](a: T, n: int)` 以 `take(1, "s")` 调用时，`unify_types` 收到的 pattern 是 **`gparam(T)`** 而非 `int`（探针副本 `[dbg-unify]` 实测）；
  `fn take[T](a: T, n: str)` 以 `take(1, 2)` 调用同样收到 `gparam(T)`。而**首个形参为具体类型**时正常（探针 K：`fn take[T](n: int, a: T)` → pattern = `base(int)`，正确进站点 4）。
- 影响：泛型函数的非泛型形参类型约束在调用推断中被绕过（与 F3 叠加 → 完全无诊断）。
- 建议：单开任务定位 `ast_data(pn)` / 形参链导航（`infer_gen_call`，checker.cr:1030-1060）。

---

## 7. 定向探针（**合成语料，不计入 §3 统计**）

| 探针 | 意图 | 站点 | 结果 | 结论 |
|---|---|---|---|---|
| A `pa_refmut` | `&mut T` 形参 + `&x` 实参 | 2 | agree（两侧同拒） | `&x` 是 **PTR** 不是 REF → mut 面未触达 |
| B `pb_named2` | 站点 4 + named 实参 | **4** | **unknown**（engine/uncovered） | 站点 4 **不是恒 agree**（含 named → 未覆盖面） |
| C `pc_site4base` | 泛型函数 + 具体形参不匹配 | （2） | agree | 印证 F4：pattern 变 T，站点 4 未命中 |
| D `pd_arrlen` | `[int;4]` 返回给 `[int;3]` | 5 | **old_stricter**（旧拒新受）+ `error[TF01]` | F2 实证（N 面） |
| E `pe_dyn` | `dyn` 值赋给 `int` 变量 | 8 | agree（另发 `error[TA01]`） | dyn ⊤ 近似本轮未产假等价 |
| F `pf_hotpatch` | 同名 hotpatch 两版本 | **1** | agree | 站点 1 可达（语料未触达，探针补上） |
| G `pg_genarg` | `T` 先绑 `[int;3]` 再以 `[int;4]` 调用 | **2** | **old_stricter** | 站点 2 可达；N 面在泛型实参位同样暴露 |
| H `ph_refmut2` / I `pi_selfmut` | `&int`/`&mut int` 变量、`&self`/`&mut self` 方法 | — | 0 命中、全 agree | 印证 (b)：REF 面源级不可构造 |
| K `pk_site4base2` | 泛型函数**首**形参为 base + 不匹配实参 | **4** | agree | 站点 4 的 base 对行为 = 两侧同拒（真判等） |
| J `pj_nongen` | 非泛型调用实参不匹配 | — | `ok`（无诊断） | F3 实证 |

探针源：`/tmp/r2p1t3/probes/*.cr`（非仓库文件）。

---

## 8. 裁决建议（后续任务清单）

**P2（替换旧判定）前置/清单**：
1. **F1 必须先行**：named 身份规范化（引擎侧 name 注册表，或桥接同名折叠）——否则替换会把主流「同类型比较」变未判定。建议 P2 第一项即此，并补同名多行的守门用例。
2. **F2 需裁决**：数组 `N` 是否保留检查（R1 已裁 IR 身份不含 N；checker 侧需显式裁决 + spec 记档）。
3. **F3/F4 接线**：判定结果 → 诊断的接线（含 `unknown` 策略：拒绝 / 降级警告 / 放行，需与「语义保鲜」目标一致）；泛型形参类型推断修复（F4）。
4. **替换清单的验收判据**：不能只看「差异数 = 0」，须同时报告**站点覆盖**（本轮 4 个站点 0 命中）——否则「零差异」无法区分「一致」与「没跑到」。

**引擎需补规则**：
- named 身份（F1，最高优先）；
- `AK_REF`/`AK_PTR` 的可变性/地址空间变型（P3「条目化 + 变型」面，本轮 0 证据但 by-design 已知）；
- （若裁决保留）数组长度维度进入身份。

**未覆盖面登记**（P1 输出）：本轮 9 条差异**全部**属「`AK_NAMED` 不展开」；`AK_DYN` 的 ⊤ 近似本轮未触发；
`unknown_engine_budget = 0`（预算 200000 步在全部 26,704 次判定中**从未耗尽**）。

**其他已登记项（非本任务范围）**：
- 站点 6（`assign-binary`）不可达：parser 已把 `=` 一律降为 `EXPR_ASSIGN`（`parser.cr:222-224`），挂点保留但无样本 → 建议 Task 4 决定去留；
- 站点 4 的分类行为（§5(c)）需在 P2 语料里补定向样例；
- `tests/suite/test_control_flow.cr` / `test_generics.cr` 为 0 字节空文件（勘误 Task 2 的「预期失败 fixture」措辞）；`at_test_mini4/6` rc=139 属 TODO #16（嵌套 fn）；
- `src/compiler/elf.cr`（566 行）在本轮 rc=0 但 2 个 parse error、0 判定 → 陈旧遗留文件，建议单开清理；
- `src/compiler/linker.cr` 为 0 字节空文件。

---

## 9. 限制（诚实边界）

1. **零收紧面 ≠ 收紧面为空**：本轮「零差异」仅覆盖站点 5/7/8 主导的面（99.99% 决策）；站点 1/2/4 **零命中**、站点 3 仅 2 次。
   泛型实参/泛型应用基型/兜底等价/热补丁声明组四个面**无证据**。
2. **探针是合成语料**：§7 的差异（`old_stricter`）不计入 §3 统计，仅证明「面可达 + 分类正确」。
3. **dyn/REF 面为「未触发」而非「已证安全」**：两者参与判定 0 次，过宽/丢 mut 的风险**未被本轮语料检验**。
4. **自指语料漂移**：②③ 的判定数随仪表化代码变化（+4/+2），跨提交比较判定数需同源码同二进制。
5. **`AK_NAMED` 的具体判定语义仍未建模**（引擎不去名、不比对声明）——本轮只把它判为「未判定」，未回答「同名是否恒等价」这一语义问题（F1 裁决所需）。
6. **未测吞吐**：本轮只证「产物零影响 + 判定正确性」，影子开销（开态）未做基准。

---

## 10. 复现命令

```bash
# 构建 + 自测（CPU 限制）
nice -n 19 python3 build_selfhost_native.py
nice -n 19 ./build/corec selftest-types            # 71/71

# 两态判据（开/关均须与基线逐字节相同；每次判据前 clean-cache，cwd = 仓库根）
nice -n 19 ./build/corec clean-cache
nice -n 19 ./build/corec build tests/suite/ptr_arith.cr --static -o /tmp/off
nice -n 19 ./build/corec clean-cache
nice -n 19 ./build/corec build tests/suite/ptr_arith.cr --static --type-shadow -o /tmp/on
cmp /tmp/r1t4_base_bin /tmp/off && cmp /tmp/r1t4_base_bin /tmp/on

# 三档语料（逐文件 dump；脚本见 /tmp/r2p1t3_run2.sh）
for f in tests/suite/*.cr; do nice -n 19 ./build/corec check "$f" --type-shadow --type-shadow-dump /tmp/d.txt; done
nice -n 19 ./build/corec check src/compiler/main.cr --type-shadow --type-shadow-dump /tmp/d.txt
nice -n 19 ./build/corec check src/compiler/ccr_io.cr --type-shadow --type-shadow-dump /tmp/d.txt

# 归因（行号 → 类型名）：/tmp 仓库副本 + [dbg] 探针（未触碰仓库文件）
rsync -a --exclude .jj --exclude .git --exclude build --exclude .core ./ /tmp/r2p1t3_probe/
# 在副本内给 sh_compare 加 [dbg]/[dbg-shape]/[dbg-dup] 打印并重建，再跑上表语料
```

摘要行读取：`grep '^\[type-shadow\] '`（主计数）/ `grep '^\[type-shadow-sites\]'`（站点直方图，串内 `name=N` 逐项）。
