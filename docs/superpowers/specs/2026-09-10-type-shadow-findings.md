# R2 P1 影子对拍差异清单（三档语料 + 归因与裁决建议）

日期：2026-09-10（Task 3 落地日 2026-09-11 复核；**P2a 替换后复跑 = §11**，2026-09-11 Task 4 收官追加；**R2 P5 Task 5（2026-09-13）起影子通道已整体下线 ⇒ 本文件为历史记录，§15 = 终态基线**）
范围：R2 计划 P1「影子对拍」——把 P0 类型判定引擎与旧 `type_equal_core` 在**真实语料**上逐点对账，
产出「收紧面（old_looser = 旧受新拒）暴露清单」与「未覆盖面清单」，供 P2（替换旧判定）裁决。
上游：P0 引擎 + P1 Task 1 桥接层 + Task 2 挂点/通道（`844cec6c` + 评审补强 `514956a1`）+ Task 3 Step 0 拆因 + 本清单（同一提交）。

引擎/通道事实来源：`src/compiler/ty_shadow.cr`（桥接 + 挂点 + 摘要/转储）、`src/compiler/checker.cr`（`type_equal` 包装 + 8 站点）、
`src/compiler/type_engine.cr`（三态 + 成因位）。

---

## 0. 结论（TL;DR）

> **⚠ 影子通道已下线（R2 P5 Task 5，2026-09-13）**：本文件记录的通道（`--type-shadow` / `[type-shadow]` 摘要 / 差异转储 / 站点直方图 / `sh_compare`）**已整体删除**——对照物 `type_equal_legacy` 在 P5 Task 4 删除后对拍停摆（全语料 `decisions=0`），P5 Task 5 按 D24/D26 下线（§15 = 终态基线记录）。判定面回归网自此 = **冻结基线同源对拍 + 行为探针 + 突变控制 + 三态纪律（ICE04）**；**后续批次不得引用本文件的计数/摘要/站点直方图作为判据**（它们只在通道存活期可复现）。
>
> **本清单已闭环（2026-09-11 注记）**：P1 的两条硬项 F1（硬前置）/F2（裁决）已在 **R2 P2a** 实施（用户裁决 = 建表去重根治 / 落常量档长度约束），`type_equal` 判定权已移交引擎。**替换后复跑见 §11**（26,989/26,989 agree、`old_looser`/`old_stricter`/`unknown` 全 0、站点覆盖口径不变）。§1-§10 保留为 **P1 时点**记录（数字随自指语料漂移，跨提交不可逐字复现）；未结项 = F3/F4（TODO #20/#21）与 F5（TODO #25，P2a 新发现）。

1. **真收紧面 = 0**：三档语料（+2 档扩面）共 **67 个有效文件 / 26,704 次判定**（71 个候选中 4 个排除，见 §2），`old_looser=0`、`old_stricter=0`。
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
| `src/compiler/ty_shadow.cr` | `sh_compare`：`a<0 \|\| b<0`（桥接缺口）→ `kind=3` + `g_shadow_unknown_bridge`；`e<0`（引擎负值）→ `kind=0` + `g_shadow_unknown_engine`，并按引擎自报成因位细分 `unc=ty_uncovered()` / `exh=ty_exhausted()`（**必须在第二次 `ty_budget_reset` 之前读**）；`sh_kind_name` 增 `unknown_bridge`；`sh_report` 增 4 个字段（**前 5 组 key=value 前缀不变**，既有 grep 读取方不受影响） |
| `src/compiler/globals.cr` | +4 全局：`g_shadow_unknown_bridge` / `g_shadow_unknown_engine` / `g_shadow_unknown_uncovered` / `g_shadow_unknown_budget` |
| `src/compiler/ty_shadow.cr`（Task 3 扩面） | +站点直方图：`sh_site_begin` 累计 8 个站点的**判定次数**（`g_shadow_site_counts`，8×8B），`sh_report` 增第二行 `[type-shadow-sites]`。理由：环形缓冲（256 条）只装「有差异/未知」的条目，**0 差异语料下「某站点是否真的跑到过」没有别的证据通道**，而 brief 要求登记「站点 4 恒 agree / 站点 6 不可达」 |

摘要行（示例，`tests/suite/ptr_arith.cr`）：

```
[type-shadow] decisions=74 agree=74 old_stricter=0 old_looser=0 unknown=0 unknown_bridge=0 unknown_engine=0 unknown_engine_uncovered=0 unknown_engine_budget=0
[type-shadow-sites] hotpatch-ret=0 generic-arg=0 generic-apply-base=0 unify-fallback=0 fn-body-ret=16 assign-binary=0 if-branch=7 assign-node=51
```

转储 kind 空间：`0 = unknown_engine` / `1 = old_stricter` / `2 = old_looser` / `3 = unknown_bridge`（dump 的 `kind` 列同步改名）。
**读 dump 者须知（M4，Task 3 评审）**：Step 0 前 `kind=0` 的名字是 `unknown` → 现名 `unknown_engine`（契约变更）；按字面旧名匹配的分析脚本会漏读该列（仓内已核**无消费者**，破坏面仅限外部/未来脚本）。

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

不变式：`agree + stricter + looser + unknown == decisions` 在**全部 67 条摘要行**成立（71 候选 − 4 排除 = 67；逐行核对，0 违例）。

**「Task 3 时点」注（终审 M-3）**：上表逐行数字为 **Task 3 时点**（提交 `75c20297`）实测，**在最终提交上不可逐字复现**——②③ 含**编译器自身语料**（§2 末「语料自指说明」），Task 4 对 `ty_shadow.cr`/`type_terms.cr`/`type_selftest.cr` 的改动进入该语料 → 自指行一致 **+3**：`main.cr` 3964→3967、`_import.cr` 3844→3847、`ccr_io.cr`（③）4177→4180（Task 4 实测，提交 `7624a53c`）。非自指行不变（源与导入面均未改；抽检 `ptr_arith.cr` = 74、`toml.cr` = 120，与表/§1.2 一致）。机制见 §9.4；跨提交比较判定数须**同源同二进制**。**该组自指数字本身也随编译器自身源码改动而移动**（含注释行）——引用时须连同提交号（本注即为示例）。

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
- 站点 6（`assign-binary`）不可达：parser 已把 `=` 一律降为 `EXPR_ASSIGN`（`parser.cr:222-224`），挂点保留但无样本 → **Task 4 裁决（终审 M-1）：保留挂点，去留归 P2**（零成本、留证据面；不删——删须同步本节与 `ty_shadow.cr` 站点表）；
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
nice -n 19 ./build/corec selftest-types            # 72/72（Task 4 后：+ 第二次重建守门 bridge.grow_rehash2；Task 3 时点 = 71/71）

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

---

## 11. P2a 后复跑（2026-09-11，R2 P2a Task 3 替换 → Task 4 收官复验）

**背景**：本清单的 ①②（F1 硬前置 / F2 裁决）已在 R2 P2a 落地（用户裁决：F1 = 建表去重根治；F2 = 落常量档长度约束保持拒绝语义），`type_equal` 的判定权已移交引擎（`ty_equiv`）。本节记录**替换后**在**同一批语料**上的复跑结果（对拍门）。

**通道差异（与 §1-§5 的关键区别）**：影子对照物的「旧」侧已从 `type_equal_core` 切到 **`type_equal_legacy`**（同一函数体，改名后降级为对照物 + 回落实现）。故分类语义 = **引擎 vs 旧结构判等**——正是替换门要的对账。§3 的 `unknown` 拆因字段（`unknown_bridge` / `unknown_engine*`）保留；另增 `replace_bridge` / `replace_unknown`（**判定路径**的回落计数，与影子侧计数器互为交叉证据：逐文件相等）。

**条件**：cwd = 仓库根；**每文件先 `clean-cache`**（**必须**——`.ccr`/缓存态会让同一二进制二次运行产出不同中间态，见 TODO #5 同族第二实例）；71 候选中 67 有摘要（4 排除同 §2）。

| 指标 | P1（§3.1，Task 3 时点） | **P2a 后（Task 4 复核，final 产物重算）** |
|---|---|---|
| 判定数 / agree | 26,704 / 26,695（unknown 9） | **26,989 / 26,989（unknown 0）** |
| `old_stricter`（旧拒新受） | 0 | **0** |
| `old_looser`（旧受新拒 = 真收紧面） | **0** | **0** |
| `unknown`（引擎未判定） | 9（全部 `AK_NAMED` 不展开） | **0**（F1 去重消除根因） |
| `unknown_bridge`（桥接缺口） | 0（结构性） | **0** |
| `unknown_engine_budget`（预算耗尽） | 0 | **0** |
| `replace_bridge` / `replace_unknown`（判定路径回落） | —（替换前无此计数） | **0 / 0**（语料面未触达；探针面 3 处 =1，逐条登记于 Task 3 报告 §5.4） |

**站点覆盖（与差异数同报——P1 交接硬性要求）**：直方图（final 重算）= `fn-body-ret=4949 · if-branch=1919 · assign-node=20119 · generic-apply-base=2 · hotpatch-ret/generic-arg/unify-fallback/assign-binary = 0`，合计 26,989 = decisions（逐文件恒等，独立重算 67 行 0 违例；**原运行脚本不做该校验**，见 Task 3 报告 §5.3 更正）。
- **覆盖面 = 站点 5（返回位）/ 7（if 分支）/ 8（赋值）**；站点 3 仅 2 次（`generics_test`）；**站点 1/2/4/6 语料零命中（同 P1）**。
- ⇒ 「差异归零」的效力范围**仍是赋值/返回/if 面**（口径与 §9.1 一致，未因替换扩大）；站点 1/2/4 面由定向探针承担，站点 6 无生产点（TODO #17）。

**N 面口径（Task 2 评审裁决，硬性）**：F2 之后影子对 **N 面已「失明」**——对照物 `type_equal_legacy` 的数组分支自身已 N-free ⇒ `old_stricter` 在 N 面**必为 0**（同义反复、无诊断力；P1 探针 D 的 `old_stricter=1` 已随 F2 消失）。故**本节的「对拍归零」不得作为 N 面证据**；N 面验收 = **行为探针**（异长拒绝 / 同长通过），覆盖位：顶层数组、嵌套元素位、泛型实参位、指针元素位、元组字段位（单节点元素）+ **元组字段位（复合表达式元素）= 漏检，登记 F5 衍生**（见 §6.1 / TODO #25）。探针在 `--type-shadow` 下同时跑：影子全 agree（证明「N 不入身份」）而 rc=1（证明「拒绝只来自 `array_len_constraint_ok`」）= 该面正确的证据形态。

**残留与交 P5**：① 命名类型 / 泛型应用面的等价判定**仍由 legacy 承担**（`AK_NAMED`/`TYP_GENERIC_APPLY` 不展开 → 引擎 -1 → 回落+计数）；**P5 删 `type_equal_legacy` 的前提 = 引擎命名展开落地 + `replace_unknown` 清零**（否则「回落」变「未判定」）；② 站点 6 挂点去留随 P5 站点面清理；③ F3/F4（调用位点无诊断 / 泛型后续形参类型不生效）仍未接线（TODO #20/#21）。

---

## 12. P2b 后：公理区事实表（2026-09-11，R2 P2b 收官——供 P3 收紧直接消费）

**背景**：R2 P2b 把 `infer_expr` 的公理区（操作许可 / 字面量定型）接入 `iface_registry.cr` 的本质条目表，并把 `res_type_node`/`res_call_type` 的双份 TY→TI 映射合成单表 `ty_code_to_ti`（提交链 `7f520dce`→`31143cd0`→`6d2790cd`→`a99ee825`→`7145eea5`→`30545da7` + 收官提交）。本批硬口径 = **保语义（零行为变化）**：表的每一格 = 现状代码逐格转录 ⇒ 现状「宽松面」**原样保留**；本节的表 = 这些宽松面的**实测事实**（行号 = P2b 末提交实测，括注 = Task 4/5 报告的接线前行号）。

**判据口径（本节的证据形态）**：表中「现状诊断」列全部来自**行为探针**（Task 4 的 32 例 + Task 5 的 44 例，接线前/后逐字节同）与**行为回归**（`tests/selfhost/test_iface_ops.py` 76 例：正控 / 负控 / 登记面三类）；「不接线」列的理由全部来自**全行枚举 / 集等价 / 突变控制**（各任务报告 §突变节），不是读码推断。

| # | 现状宽松面（P2b 末行号 ← T4/T5 报告号） | 现状事实（行为探针） | 表中格 | P2b 处置 | P3 收紧建议 |
|---|---|---|---|---|---|
| 1 | 比较不校验操作数 `:1975-1977` ←`:1965-1967` | 6 个比较 op 恒 `TI_BOOL`，`(1,"a")`/struct/数组比较零诊断 | 6 比较位对**全 13 类**置 1（无拒绝路径） | 不接线（无门可换） | 加「可比性」判据（结构/序列需元素可比）后逐类收紧 |
| 2 | 算术门「任一侧数值即可」`:1969` ←`:1959` | `1 + [int;3]` / `"a" * 2` **静默为 int**；`"a" * "b"` / `*T + *T` → `error[TB01]`（负控钉红） | ADD..MOD **只含 {int, dex}**（门 = ANY 语义，两侧皆非数值才报错） | **原样保留**（接线后逐字等价） | 改 ALL 语义（两侧都须数值）或引入显式提升规则；须先有全语料证据 |
| 3 | 串拼接优先且单向 `:1951` ←`:1946` | `1 + "a"` → string（`OP_ADD` 一侧为串即成） | **无位**（早退规则留代码 = 结果规则） | 原样保留 | 拼接位独立建模（`+` 的 string 合法性上表）；`1 + "a"` 是否应为 string 属语义裁决 |
| 4 | 一元透传 `:1994-1996` ←`:1979-1981` | `-"a"` rc=0（直接返回操作数类型） | NEG/NOT 对全 13 类置 1 | 原样保留（登记） | 数值性判据（NEG 只收数值类、NOT 只收 bool/int） |
| 5 | 解引用兜底透传 `:2018-2029`（兜底 `:2029`）←`:2003-2014` | `*x`（x: int）rc=0（非 REF/PTR/GPARAM 原样返回） | DEREF 对全 13 类置 1 | 原样保留（登记） | 兜底分支改为拒绝（REF/PTR/GPARAM 之外报错） |
| 6 | 索引**表达式**类型不校验 `:2618` 的 `idx_ti` 无消费者 ←`:2583` | `arr[true]` rc=0 | **无双侧位**：`IP_INDEX` 是**容器侧**位 | 本批未动 | 索引侧另设「须 int」位（ALL 语义；`IP_INDEX` 不能兼职） |
| 7 | 字段落空静默 `:2613` ←`:2603` | `x.a`（x 非 struct）/越界元组位/未知字段/方法当字段 **12/12 rc=0 零诊断** | `IP_FIELD` 恰 {product, named}（拒绝集与落空集**同集** = 恒真门） | 不接线（登记 P3 旋钮） | 落空分支加诊断（TS/TK 系）；此时 `IP_FIELD` 才可被门推翻 |
| 8 | 转换无校验 `:2953` ←`:2932` | `"a" as int` / `arr as int` / `1 as S` … **10/10 rc=0**（除 PTR 结果规则外恒等透传） | `IP_AS` 对全 13 类置 1 | 不接线（无拒绝路径） | 转换合法性矩阵（源→目标允许表） |
| 9 | dyn = ⊤ 近似 + **逐行**方法表判定 `:1870-1893` ←`:1865-1888`（64 钳位 `:1834-1843`） | `d.nosuch()` → `error[N08]`——**int/string 候选行也报**（名拼接方法表判定，非类级） | `IP_METHOD` 恰 {dyn, named}（类级位表达不了逐行谓词；装上 = 抑制既有 N08 = 放宽） | 不接线 | ① (方法名 × 类型行) 二维判定；② 解除位图 64 上限（spec §3.3） |
| 10 | **range 索引非数组落空静默** `:2637` ←`:2611-2628` | 串/切片/int 的 range 索引 **rc=0 静默**（落空 `return TI_UNIT` 无诊断） | `IP_INDEX_RANGE` 恰 {sequence}（未接线） | 不接线（无诊断 ⇒ 门恒真） | 落空分支加诊断，或把「串 range」定为 slice 语义（**语义裁决**，须先有全语料证据） |

**P2b 收紧清单（「旧接受 → 新拒绝」）= 空**（零条；反向「旧拒绝 → 新接受」亦零条）。证据 = 同源双编译器对拍（旧二进制 × 新源 == 新二进制 × 新源）：21 档 `tests/suite` 语料 check 输出（stdout+stderr+rc）逐字节同 · 自源 `check src/compiler` 逐字节同（仅既有 2 条 TF01 误报 `lits_copy`/`ty_memo_slot_no_grow`，两侧一致）【**2026-09-13 更新（TODO #40 TF01 收口）**：`lits_copy` 为真·类型洗白（返回型改 `string`），`ty_memo_slot_no_grow` 为 checker 落空分析缺失（`stmt_cannot_fall_through` 落空分析入 checker.cr）⇒ `check src/compiler` 现 rc=0；本句为当期实跑记录】· 4 档 `.ccr` 逐字节同（`ecd7a9df…`/`891377232b…`/`35cf0f26…`/`dfb82d2b…`）· 32 档影子通道逐字节同 · ELF canary `95084e7b…d475`（开/关两态同）；逐任务另有各自的前一任务基线对拍（Task 1~6 报告 §判据）。**站点台账（31 个未接线站点 + 接线面清单 + P3 裁决点）见 `docs/superpowers/plans/2026-09-11-r2-p3-capabilities.md` 附录 A。**

---

## 13. P3a 后复跑（2026-09-12，R2 P3 收官——P3a 终态）

**背景**：R2 P3a（Task 0/1/3/4/5，提交链 `61d3a8b4`→`ef61f002`→`e9818d62`→`c8c7731b`→`9c0a83ec` + 收官提交）落地：§6 的 F4 由 Task 5 关闭（F1 已在 P2a、F2 的**方向/变型面**由 Task 1 接续）+ 三条新面（引擎展开层 / match 穷尽性 / 联合可选）。本节 = **终态**在同一批 72 档语料上的复跑（口径同 §11/§12：逐档 `clean-cache`、cwd = 仓库根、对拍 = 旧二进制 × 新源 vs 新二进制 × 新源；站点覆盖与差异数**同报**）。

**终态数字（2026-09-12 收官复跑；新旧两二进制逐值同）**：

| 指标 | 值 |
|---|---|
| 文件 | 72（70 有摘要；2 = 0 字节空 fixture，同 §2 排除项） |
| 判定数 / agree | **30,128 / 30,128** |
| `old_stricter` / `old_looser` | 0 / 0 |
| `unknown`（含 bridge/engine/uncovered/budget 四拆因） | 0 |
| `replace_bridge` / `replace_unknown`（判定路径回落） | 0 / 0 |
| check 面对拍（rc + 日志） | `diff -r` **空**；rc 分布 33×rc=0 / 39×rc=1（两二进制同） |
| shadow 日志 / dump 对拍 | `diff -r` **空**（两处） |
| 站点直方图 | `assign-node=22785 · fn-body-ret=5338 · if-branch=1971 · struct-field-type=28 · array-elem-type=4 · generic-apply-base=2`；站点 1/2/4/6 零命中、3 = 2 次 |
| `sum(sites)==decisions` / `agree==decisions` | True / True（独立重算校验） |

**判定数口径变化（30,338 → 30,128，−210）——精确归因**：唯一来源 = 收官发现的回归修复（计划附录 B.6：删 `src/targets/x86_64-linux/_import.cr` 的 `import monomorph`）⇒ monomorph.cr 退出 target project 两档（`main.cr` / `_import.cr`）的导入闭包。**逐档切换实测**：target `main.cr` 3577 → **3472**、target `_import.cr` 3542 → **3437**（各 −105，合计恰 −210 = 总差）；同两档的 `error[N06]` 从 **33 → 0**（该修复的直接目的）。语义面零变化 = 同源对拍三面空（上表）。

**P3a 逐任务对拍（汇总，不重推导；出处 = 各任务报告 §3/§4）**：

| 任务 | 对拍结果（旧二进制 × 新源 vs 新二进制 × 新源） | 判定数（同批口径） |
|---|---|---|
| T0 | check/shadow/dump 三面 `diff -r` 空 | 29,090 / agree 29,090 |
| T1 | 三面空 | 29,267 / agree 29,267 |
| T3 | check 面**仅 2 处行号位移**（既有 TF01 误报随新增源码行漂移；诊断集合/条数/rc 全同）；shadow/dump 空 | 29,442 / agree 29,442 |
| T4 | check 面逐档**诊断码集合与 rc 同**（3 档自源行号位移）；dump 与 T3 逐字节同 | 29,687 / agree 29,687 |
| T5 | **0 档差异**（rc + 诊断码 + 逐条消息含行号全等）；dump 与 T4 逐字节同 | 30,338 / agree 30,338 |
| 收官 | 三面空（修复后源；上表） | **30,128 / agree 30,128** |

**P3a 面在语料上的命中 = 0**：新能力面（展开层/方向/变型/mut/穷尽性/`T?`/Some·None/泛型约束）在 72 档语料**全部零命中**（§3 语料事实：零 match、零 enum 声明、零 `T?`、零约束语法）。⇒ 上表「零差异」**不是**新能力的正确性证据，正确性由各任务行为探针（T1 19 · T3 22 · T4 14 · T5 16 例）+ 用例表（288）+ 新套件（16+12+14 例）+ 突变控制承担（同 §11/§12 的效力范围口径）。

**§12 事实表（九条宽松面）在 P3a 后的状态 = 全部未动**（比较不校验操作数 / 算术门 ANY / 串拼接单向 / 一元透传 / 解引用兜底 / 索引表达式类型 / 字段落空静默 / 转换无校验 / dyn 逐行 + 64 钳位 / range 索引落空静默）——P3a 的能力面在 §6 与计划任务面；§12 的「公理区操作许可」面仍是 P3b/P4 的收紧对象。与 §12 相邻、P3a 已动的只有 **N/固定性面**（§6-F2 的方向/变型收口，§12 未列）。

**收紧/放宽台账（P3a 汇总）**：收紧 **18** 条（T0 0 / T1 6 / T3 6 / T4 3 / T5 3；其中 1 条 rc 不变、仅诊断码集合扩张）+ 诊断面新增 1（TM04 软）+ 放宽 **8** 条（T4 7 含 1 条非语义放宽 / T5 1）+ 实例名忠实化 6（T5）+ 挂死修复 2 端（T4）；**全语料零命中** ⇒ 自举源码零改造。逐条 = `docs/superpowers/plans/2026-09-11-r2-p3-capabilities.md` **附录 B.2**；报告 = `.superpowers/sdd/p3-task{0,1,3,4,5,7}-report.md`。

**新登记面（P3a 引入/更新；详版 = 附录 B.4）**：非枚举域不判穷尽 · 空枚举域 = 空洞穷尽（判据 1）· 空递归保守 -1 · MAX_* 族处置（MAX_GENERICS / MAX_ENUM_VARIANTS / MAX_VARIANT_TYPES）· 运行期可选表示未统一 · witness 空析取支（反例走覆盖位）· `EXPR_ENUMPAT` 名字槽 = `ast_a` · bootstrap `&&`/`||` 短路根因（T4 只关触发链）· `EXPR_LET` 无检查（TODO #32）· 符号档长度约束（VC 义务，显式登记不实现）。

**残差与交 P5**：同 §11 尾（`type_equal_legacy` / `sh_*_ak_legacy` / 站点 6 / 影子层下线）——**状态更新**：T0 的展开层按设计只服务满足判定/域查询 ⇒ §11 的「unknown 清零前提 = 引擎命名展开」**不会被满足**（等价面展开属裁决）；P5 须裁「接受命名展开（推翻 P2a 对拍基线）」或「legacy 长期化」（见计划附录 B.5）。

## 14. P4 后复跑（2026-09-13，R2 P4 收官——载体批终态）

**口径**：pre-P4 二进制（P3b 终态构建，sha `9a583215…`）× **当前源** vs 当前二进制（`5d2b15ad…`）× **当前源**；语料 = 72 档（`tests/suite` + 自源 `main.cr`/`_import.cr` + 后端/内核单元 + `src/stdlib` + `examples`；runner `/tmp/p3t0_run.sh`，冷缓存逐档 `clean-cache`），两面 {`check`, `check --type-shadow --type-shadow-dump`}。

| 面 | pre-P4 侧 | 当前侧 | 结论 |
|---|---|---|---|
| 影子摘要（70 档出摘要） | `decisions=32620 agree=32620`，`old_stricter`/`old_looser`/`unknown*`/`replace_*` 全 0 | 同值（逐档同） | **判定面零变化** |
| 站点覆盖 | assign-node=24721 · fn-body-ret=5828 · if-branch=2037 · struct-field-type=28 · array-elem-type=4 · generic-apply-base=2（其余 0） | 逐项同（Σ = 32620 = decisions） | 同上 |
| check 日志面 | 8 档差异，**100% = TF01 收口类**（5 处 `ty_memo_slot_no_grow` 误报消失 + 3 档 rc 1→0） | — | P4 内**有意修复**，非语义回归 |
| rc 分布（72 档） | 31×0 / 41×1 | 34×0 / 38×1（恰 3 档 1→0） | 同上 |

- **dumps 通道说明（勿当强证据）**：两侧 `dumps/` 目录**均无文件** ⇒ 常被引用的「dumps `diff -r` 空」是**空洞证据**——`sh_dump_write`（`ty_shadow.cr:651`）在无差异条目（`g_shadow_ring_count ≤ 0`）时早退、不落盘。真证据 = 上列摘要全 0 + 站点覆盖同报 + rc 分布差恰为 TF01 面。
- **效力范围（继承 §11/§13 口径）**：影子通道只覆盖 `type_equal` 站点面——**对 P4 载体面（TYPE/IFACE 段、corearch 读回、DFNode.TK 项槽、运行期表示位）零覆盖**；载体正确性证据 = 结构性断言（`test_ccr_types` 34 例）+ corearch 读回对拍（`--dump-types`/`--dump-ifaces`）+ 定向探针，见计划 Task 1–6。
- **承接 P5**（同附录 D-3）：`type_equal_legacy` 删除 / unknown 清零（前提不会被自动满足，须二选一裁决）/ `sh_*_ak_legacy` 桥接缓存退出生产路径 / 站点 6 去留（须先补站点评级说明）/ 影子层下线。P4 未新增站点、未改站点语义（本表可作 P5 的基线）。

## 15. 影子通道终态（R2 P5 Task 5，2026-09-13——**通道下线；本节 = 最后一次基线**）

**通道下线**（D24/D26）：对照物 `type_equal_legacy` 已在 P5 Task 4 删除 ⇒ 判定对账 `sh_compare` 无调用点、停摆（中间态）；P5 Task 5 按 D26-① **整体删除**——站点挂点（checker 9 处）/ 判定对账 / 差异环缓冲（前 256 条）/ 摘要 `[type-shadow]` / 站点直方图 `[type-shadow-sites]` / 转储 `--type-shadow-dump` / CLI 旗标 `--type-shadow` / 全局态 `g_shadow_*`（17 个）/ 桥接调试计数 `g_shadow_hits`（含存-复原补偿 hack）。桥接缓存**保留**（生产面）并改名 `g_shadow_map` → `g_term_map`。**本文件此后的任何计数均不可复现**（通道已不存在；`--type-shadow` 不再是合法旗标）。

**终态基线（本任务实测，起点二进制 `eae13428…`（P5 T4）× 72 档语料，逐档 `clean-cache`；runner `/tmp/p3t0_run.sh shadow …`）**：

| 面 | 终值 |
|---|---|
| 影子摘要（70 档出摘要） | **70/70 档 `decisions=0 agree=0 old_stricter=0 old_looser=0 unknown=0 unknown_bridge=0 unknown_engine=0 unknown_engine_uncovered=0 unknown_engine_budget=0`** |
| 站点直方图 | `assign-node=24996 · fn-body-ret=5911 · if-branch=2045 · struct-field-type=28 · array-elem-type=4 · generic-apply-base=2`（`assign-binary`/`generic-arg`/`hotpatch-ret`/`unify-fallback` = 0） |
| `check` rc 分布 | 34×0 / 38×1 |

**沿革对照（各时点口径，仅历史）**：P1 26,704 次判定（`old_looser=0`，unknown 9 = 同名多行）→ P2a 26,989 agree 全额 → P3a 收官 30,128 → P3b 收官 32,620 → P5 T2 `32767` → P5 T3 `32917` → P5 T3b `32922` → P5 T4 `32988`（**最后一次有 meaning 的读数**：`decisions=agree`，全差异桶 0）→ **P5 T4 后停摆 `decisions=0`**（对照物已删）→ **P5 T5 通道下线**。

**口径继承（对后续批次 = 强制）**：① **N 面（数组长度）对拍恒 0 是失明而非等价**（legacy N-free）⇒ N 面证据只能来自行为探针；② 本通道对**载体面**（TYPE/IFACE 段、corearch 读回、DFNode.TK 槽、运行期表示位）**零覆盖**——载体正确性证据 = 结构性断言 + 读回对拍 + 定向探针；③ 「零差异」只在通道存活期 = 证据，此后引用 = 空洞。**替代网与判据见 `TODO.md` #48 与 `.superpowers/sdd/p5-task5-report.md` §5。**
