# R2 P0 Task 1 报告：类型项表 + 构造 API + 自测通道骨架

- 状态：DONE_WITH_CONCERNS（判据全部通过；三处与计划代码的偏差、一处计划内部矛盾已按证据裁决，见 第 4 节/第 8 节）
- 提交哈希：（提交后回填，见 第 10 节）
- 判据结论：重建 BUILD SUCCESS + 三 guard clean；`selftest-types` 输出 `5/5 type-engine cases passed`、rc=0、零 FAIL；`tests/selfhost/test_type_engine.py` 通过；`corec run 'fn main()->int{return 42;}'` 得到 rc=42。
- 附加验证：原生压力程序 19/19 PASS（扩容/重索引/翻倍三条路径，第 7 节），本任务最重要的发现由此而来。

---

## 1. 交付物（文件清单）

| 文件 | 动作 | 内容 |
|---|---|---|
| `src/compiler/type_terms.cr`（新建，214 行） | 类型项表 + 构造/去重 + 访问器 + 扩容 | 任务主体（`TT_*`/`ESZ_TYPE_TERM`/`OFF_TT_*`、`tt_hash5`/`tt_mod`、`grow_type_terms`/`grow_tt_index`/`tt_reindex`、`tt_term`、全部构造 API） |
| `src/compiler/type_engine.cr`（新建，23 行） | 原子类常量 `AK_*` + `ty_sub` 桩 | Task 3 替换 |
| `src/compiler/type_selftest.cr`（新建，37 行） | `ts_check` + `type_selftest_run()`（5 例） | 自测通道 |
| `src/compiler/globals.cr`（修改，+17 行） | 表/memo/预算全局声明 | 见 第 5 节 |
| `src/compiler/main.cr`（修改，+4 行） | `cli_cmd("selftest-types", ...)` + 分派（clean-cache 之后、文件类子命令之前） | 不读源文件、不产生产物 |
| `src/compiler/_import.cr`（修改，+3 行） | `import type_terms/type_engine/type_selftest`（checker 之后） | 清单① |
| `build_selfhost_native.py`（修改，+6 行） | `corec_files` 在 `checker.cr` 之后插三行 | 清单② |
| `tests/selfhost/test_compile.py`（修改，+5/-1 行） | `concat_sources()` 同位置插三行 | 清单③ |
| `tests/selfhost/test_type_engine.py`（新建，42 行） | 判据测试 | Step 1 |
| `src/compiler/dyn_arr.cr` | 最终零改动 | 见 第 4 节-D5（Step 4 位置迁移） |

越界检查：`jj diff --git --stat checker.cr ir_gen.cr interp.cr src/arch src/format src/os src/lattice得到 `0 files changed`（P0 硬边界：checker/ir_gen/interp/后端/语义内核一行未动）。

---

## 2. Step 2 失败态原始输出（实现前）

```
$ nice -n 19 python3 tests/selfhost/test_type_engine.py
Traceback (most recent call last):
  File "/home/DslsDZC/core/tests/selfhost/test_type_engine.py", line 41, in <module>
    test_selftest_types_all_pass()
  File "/home/DslsDZC/core/tests/selfhost/test_type_engine.py", line 34, in test_selftest_types_all_pass
    assert m, out
AssertionError: usage: corec [-h] {build,check,cir,ccr,run,clean-cache} [options]
...
    clean-cache Delete incremental compilation cache
...
RC=1
```

失败原因 = `selftest-types` 未注册（子命令表无此条目，于是打印 usage、无 `N/M type-engine cases passed` 行）。与 Step 2 预期一致。

---

## 3. 判据原始输出（最终态）

### 3.1 重建（`nice -n 19 python3 build_selfhost_native.py`，rc=0）

```
[GUARD] corec: manifest OK (40 files)
  Tokens: 128890
[GUARD] corec: build log clean (error[ = 0, undefined = 0)
  -> build/corec
[GUARD] corearch: manifest OK (31 files)
[GUARD] x86_64-linux target: manifest OK (3 files)
  Tokens: 119025
[GUARD] corearch: build log clean (error[ = 0, undefined = 0)
  -> build/corearch
[GUARD] corelsp: manifest OK (26 files)
  Tokens: 80641
[GUARD] corelsp: build log clean (error[ = 0, undefined = 0)
  -> build/corelsp

=== BUILD SUCCESS ===
```

本任务新增代码在 bootstrap build 日志中只引入一条（×2）非致命 checker 警告，与既有 ~200 条同类（`Function print arg1: expected string, got int` 等）同族：

```
Function ts_check arg2: expected BaseType(name='int'), got BaseType(name='bool') (in type_selftest_run)
```

来源 = 计划 Step 6 用例行把比较结果（bootstrap 侧类型 `bool`）传给 `ts_check(got: int, want: int)`。自举侧 checker（checker.cr）无实参类型诊断（grep `expected .*arg` 零命中），故 project-mode 自举不会因此产生 `error[`；此处按计划原文保留用例行形状，不改签名。

### 3.2 `nice -n 19 ./build/corec selftest-types`（rc=0）

```
PASS unit.bot_sub_int
PASS unit.int_sub_str
PASS unit.int_sub_int
PASS unit.dedup
PASS unit.notnot
5/5 type-engine cases passed
```

### 3.3 `nice -n 19 python3 tests/selfhost/test_type_engine.py`（rc=0）

```
PASS test_selftest_types_all_pass
```

### 3.4 `nice -n 19 ./build/corec run 'fn main()->int{return 42;}'`（rc=42）

（既有行为不动；stdout 仍为 5 步进度输出。）

### 3.5 `nice -n 19 python3 tests/selfhost/test_compile.py`（清单③被执行面）

```
All selfhost compile tests passed.
```

---

## 4. 与 brief 计划代码的偏差逐条（计划写法、实际写法、原因）

### D1 哈希折叠：FNV-1a 异或改为 FNV-1 加法
- 计划：`h = h ^ byte; h = h * 1099511628211;`
- 实际：`h = h * 1099511628211 + byte;`
- 原因：本语言无位异或算子。实测 lexer.cr 无 caret/CARET token（grep `c == 94` 零命中），`ast.cr` 的 `OP_*` 无 BXOR（1..19 = ADD/SUB/MUL/DIV/MOD/EQ/NE/LT/GT/LE/GE/AND/OR/ASSIGN/SHL/SHR/PTR_ADD/PTR_SUB/PTR_DIFF），bootstrap 侧同样无 `^`。改用本仓库既有 FNV-1 加法折叠（`dyn_arr.cr hash_bytes` 同族：`h = h * 16777619 + byte`），同样确定性、与插入顺序无关，正是 DAG 去重键所需性质。

### D2 槽位取模：负数（错误）改为 `tt_mod` 非负（计划同日同款修正）
- 计划（brief 原文）：`p := h - (h / g_tt_index_cap) * g_tt_index_cap;`
- 实际：`tt_mod(h, cap)`：`m := h % cap; if m < 0 { m = 0 - m; } return m;`
- 原因：h 经 i64 回绕可为负（FNV 乘法溢出是常态），而 i64 除法/取余向零截断，导致上式在 h<0 时落在 `(-cap, 0]`，即负下标：`r64(g_tt_index, p*8)` 读分配区之前的内存，探针读到垃圾，扩容后去重不报错地失效（我的原生压力测试实证：扩容后 `dedup_*` 全灭、`tt_count` 从 712 涨到 1400+）。计划文档已于同日 21:26 同款修正（提交 `b0de99a2`：新增 `tt_mod` 并替换两处调用点，注释即引本任务的压力测试实证），故本项已从「偏差」转为「遵计划」。
- 实现细节差异（相对修正后的计划代码，仍逐条登记）：计划的 `tt_mod` 体为 `m := h / 2; if m < 0 { m = 0 - m; } return m - (m / cap) * cap;`（折半避 i64min 取负溢出）。我用 `h % cap` 再取绝对值：① 函数名为 `tt_mod`，Task 2/3 若复用于真取模场景（奇偶/环状下标）时前者会不报错地给错（`|h/2| mod cap ≠ |h| mod cap`），隐患；② 取余先行使 `|h % cap| < cap ≤ 2^63`，取负不溢出，同样满足计划的溢出约束；③ 本仓库先例 = `str_intern`（`pos := h % cap; if pos < 0 { pos = -pos; }`）。两者皆为确定性槽位函数，正确性（插入/查找/重放三处同式）不受影响。

### D3 键比较：哈希等值并入键改为键只认五字段
- 计划：`if r64(...HASH) == h && tt_tag(idx) == tag && ... { return idx; }`
- 实际：`if tt_tag(idx) == tag && tt_a(idx) == a && tt_b(idx) == b && tt_c(idx) == c && tt_d(idx) == d { ... }`（哈希仅用于槽位定位；`OFF_TT_HASH` 字段与写入不变，`tt_reindex` 仍按存储哈希重放）
- 原因：「存储哈希 == 重算哈希」只在 i64 回绕语义下恒真。bootstrap 解释器（`bootstrap/corec/backend/interpreter.py:166` 起）二元运算不做回绕（Python 任意精度：`res = left * right`），而落盘哈希经 `w64`/`r64` 截断到 i64，等式恒假，引擎在解释器下不报错地退化为「只插不查」（去重失效、表无限膨胀，但不返回错误结果）。实测证据：最小单元经解释器驱动时 `grow.dedup_bot/grow.dedup_atom/grow.no_new` 全 FAIL、`tt_count` 97（应为 52），而同一源码经 x86-64 后端 19/19 PASS。键 = 五字段是语义正解，哈希只是槽位选择器；碰撞（含上述截断差）仅令探测链变长，不改变结果。收益：引擎在两种执行环境下语义一致、可在解释器下做用例验证（Task 3/4 可复用）。

### D4 `tt_term` 重试：递归改为单出口 `loop`
- 计划：`if (count+1)*2 >= cap { grow_tt_index(...); return tt_term(tag, a, b, c, d); }`（递归）
- 实际：装填因子守卫置于探测前、同一轮 `loop` 内重试（`ret` 单出口，函数尾 `return ret`）
- 原因：任务书明确要求「扩容后重试路径用 `loop` 而非递归（避免深递归/重复增长）」；探测前守卫另保证探测到的空槽不会因轮内扩容而失配（计划版在探测后扩容，`p` 会指向旧表位置）。负载上界不变（cap ≥ 2×项数，因此空槽必存在，探测必终止）。

### D5 扩容函数位置：从 `dyn_arr.cr` 移到 `type_terms.cr`（`dyn_arr.cr` 最终零改动）
- 计划：Step 4 追加 `grow_type_terms`/`grow_tt_index` 至 `dyn_arr.cr`（照 `grow_types` 先例）
- 实际：两函数落在 `type_terms.cr`（引擎自持）；`dyn_arr.cr` 未改（Step 11 提交清单中的该条目最终无 diff）
- 原因：实测硬失败。`dyn_arr.cr` 属双 concat 共享面（`build_selfhost_native.py:44` 的 `common_files`，corearch/corelsp 清单同含），而 `type_terms.cr` 只入 corec 清单（计划 Step 9 明令 corearch/corelsp 不加）。按计划放置时 corearch 构建直接死于解析期：

```
--- corearch ---
  Tokens: 119206
  Errors: ['Undefined name: ESZ_TYPE_TERM', 'Undefined name: ESZ_TYPE_TERM', 'Undefined name: tt_reindex']
```

（`sys.exit(1)`，无 BUILD SUCCESS）。把引擎符号留在引擎文件、共享面零改动后三 guard 全部通过。备选（改清单）被计划 Step 9 的明文约束排除。

### D6 惰性 memo 标记值：`g_tt_top < 0` 改为零初值 ready 位
- 计划：`g_tt_top : int, mut;` + `if g_tt_top < 0 { ... }`（期望初值 -1）到 实际：加 `g_tt_top_ok`/`g_tt_nil_ok` 两个零初值位，`if g_tt_top_ok == 0 { ... }`
- 原因：全局 `= -1` 初值在本仓库不可用（不报错地 0）。实测 bootstrap 解析 `g_x : int, mut = -1;` 得 `UnaryOp`（非 `Literal`），导致 `ir_gen.py:gen_let_decl` 的 `isinstance(decl.values[i], Literal)` 不成立，`constant_value = None`，最终 `x86_64_stack_asm.py:619` 落 `.quad 0`。而 corec 正是由 bootstrap 构建，因此 `g_tt_top` 初值为 0（= 合法的项行号）到 `tt_top()` 会返回项 0（通常是 ⊥），不报错地错值。零初值 + ready 位与仓库既有惯例同式（`g_home_dir_ok` / `g_ext_inited` / `g_ir_source_hash_ready`），且不依赖任何初始化调用时序。（备选：`tt_init()` 由 `corec_main` 调用，依赖调用点，未取。）
- 副作用：`globals.cr` 比计划多两行（`g_tt_nil_ok` / `g_tt_top_ok`），并在声明段写明理由。

### D7 字节提取：`v - (v/256)*256` 改为 `v % 256` 加 abs
- 计划：`byte := (v - (v / 256) * 256);`（v 为负时得负字节）
- 实际：`byte := v % 256; if byte < 0 { byte = -byte; }`
- 原因：语义等价（都是确定性字节折叠），更短且对负数不产生负字节；`%` 为本仓库既有用法（`hash_bytes` 的 `load8(...) % 256`）。仅影响哈希分布，不影响正确性（键不依赖哈希，见 D3）。

### D8 判据测试阈值：`total >= 20` 改为 `MIN_CASES = 5`
- 计划 Step 1：`assert passed == total and total >= 20`
- 实际：`MIN_CASES = 5` + 注释（「计划 Step 1 原文的 20 是 spec 第 8 节 全类目标值，Task 3/4 填表后抬回 20」）
- 原因：计划内部矛盾。Step 6 的 P0 用例表恰为 5 例、Step 10 与任务判据都要求 `5/5 ... passed` 与 pytest PASS 同时成立，而 `>= 20` 使二者不可能同时为真。取 5（2 处 vs 1 处），并要求 Task 3/4 填满 第 8 节 全类后抬回 20，阈值已提为命名常量 + 注释，改动点唯一。

### D9 自测文件注释补充分期说明
- 计划：Step 6 头注释仅一行「用例表（数据驱动）+ 自测驱动」
- 实际：补「用例面分期：Task 1 = P0 最小 5 例；Task 3/4 扩充 spec 第 8 节 全类，同步抬 `MIN_CASES` 到 20」+「只依赖公开 API」
- 原因：让 Task 3/4 的实施者知道何处扩、何处抬，避免 20 阈值再次悬空。

### D10 `main.cr` 分派块加注释行
- 计划：仅 `if cli_eq(cmd, "selftest-types") { return type_selftest_run(); }`
- 实际：同语句 + 一行注释（「不读源文件、不产生产物」），并在 `cli_cmd` 注册处按原样落位（clean-cache 之后、`cli_flag` 之前）；分派点选在 clean-cache 块之后、文件类子命令的 `cli_arg_count() < 1` 检查之前（否则 `corec selftest-types` 会先撞「requires a source file」）。
- 原因：无行为差异，注释说明边界。

---

## 5. 清单注册三处：前后对照

### ① `src/compiler/_import.cr`
```diff
 import checker
+import type_terms
+import type_engine
+import type_selftest
 import diag
```

### ② `build_selfhost_native.py`（`corec_files`，`checker.cr` 之后）
```diff
         'src/compiler/checker.cr',
+        # R2 P0 类型项引擎（建层）：…（注释 3 行）
+        'src/compiler/type_terms.cr',
+        'src/compiler/type_engine.cr',
+        'src/compiler/type_selftest.cr',
         'src/compiler/opt.cr',
```

### ③ `tests/selfhost/test_compile.py`（`concat_sources()`，同位置）
```diff
-        'src/compiler/checker.cr', 'src/compiler/opt.cr', 'src/compiler/ptr_analysis.cr',
+        'src/compiler/checker.cr',
+        # R2 P0 类型项引擎（建层，与 build_selfhost_native.py 的 corec 清单同位）：…
+        'src/compiler/type_terms.cr', 'src/compiler/type_engine.cr', 'src/compiler/type_selftest.cr',
+        'src/compiler/opt.cr', 'src/compiler/ptr_analysis.cr',
```

`corelsp` / `corearch` 清单未加（计划 Step 9 明文；且已实证：加不进，见 D5，反向依赖）。
guard 面实证：corec manifest 40 文件（= 37 + 3）、corearch 31、corelsp 26、x86_64-linux target 3，四者均 OK。

---

## 6. 自审

| 项 | 结论 |
|---|---|
| 三个新文件职责单一 | 通过 `type_terms`（表示+构造去重+扩容）/ `type_engine`（原子类常量+桩）/ `type_selftest`（用例+驱动）；`type_selftest` 只调公开 API |
| 清单三处齐 | 通过 第 5 节；corearch/corelsp 未加（实证不可加） |
| 无越界文件 | 通过 第 1 节 越界检查 0 files changed（checker/ir_gen/interp/arch/format/os/lattice） |
| 提交单一 | 通过 一条提交、路径限定（见 第 10 节） |
| selftest 计数与 rc 一致 | 通过 5/5 与 rc=0 同源（`total-fails` / `total`，`fails != 0` 时返回 1） |
| 哈希索引扩容后重建 | 通过 `grow_tt_index` 尾部 `tt_reindex()`；原生压力实测（第 7 节） |
| `g_tt_index` 初值 -1 表示空槽 | 通过 `grow_tt_index` 逐槽 `w64(nb, i*8, -1)`；探针在 `idx < 0` 时 break |

---

## 7. 附加验证：原生引擎压力（本任务发现 D2/D3 的手段，也是扩容路径的唯一实证）

5 例自测远小于初始索引容量 1024，因此 `grow_tt_index`/`tt_reindex`/翻倍循环在 P0 判据下不可达。故另建压力程序（scratch，不入库）：最小单元（io/fmt/ast/globals/dyn_arr + 引擎三件）+ 驱动 main，经 `./build/corec build … --static` 原生编译执行：

```
PASS grow.cap_1024      # 预置 8 槽索引，第 4 项触发装填守卫，执行 grow+tt_reindex+同轮重试
PASS grow.count_4       # 重建后旧 4 项全部命中（无重复插入）
PASS grow.dedup_bot / grow.dedup_atom / grow.dedup_top / grow.dedup_nil
PASS grow.no_new
PASS stress.count_712   # 700 互异 cons + 7 var + 前置 5 项，得到 712（去重精确）
PASS stress.cap_2048    # 自然 1024 容量起步，越过 count=511（同容量重建）/512（翻倍）
PASS stress.dedup_base / stress.dedup_0 / stress.dedup_699 / stress.dedup_bot_after
PASS stress.distinct / stress.no_new
PASS double.cap_4096    # grow_tt_index(3000)，1024、2048、4096 翻倍循环 + 712 项重索引
PASS double.dedup_bot / double.dedup_base / double.count_712
final count=712   index cap=4096
```

19/19 PASS、rc=0（最终源码 = tt_mod 版）。同一压力在解释器下曾全灭（`grow.dedup_*` FAIL、count 97≠52），据此定位 D2/D3 两个不报错地失效源，非原生环境根本测不出。

产物稳定性旁证：同一输入（`/tmp/tt_native.cr`）经改动前 corec 与改动后 corec 编译，ELF `md5` 相同（`e88ab6570b36bc06a84e14839878c819`）到 本批改动不外溢到编译产物。（完整的「零产物变化」判据归 Task 5。）

---

## 8. Concerns（需下环节关注）

1. D2 已由计划同日修正（`b0de99a2`），但 brief 未同步：`docs/archive/sdd/task-1-brief.md` 仍是旧代码（`h - (h/cap)*cap`）。我按修正后的计划实现（`tt_mod`）。建议：把 brief 的 Step 5 与计划对齐，避免后续实施者照 brief 写出负下标缺陷。
2. D5 计划未更新：计划 Step 4 仍写「扩容函数放到 `dyn_arr.cr`」。Task 2 起不新增 grow 函数，暂无影响；但计划文本与实证冲突，建议 Task 5 一并改。
3. D8 阈值矛盾未由上游裁决：我把 `>= 20` 降为 `MIN_CASES = 5`（否则 Task 1 无法达成「5/5 且 pytest PASS」）。Task 3/4 填满 spec 第 8 节 全类后必须抬回 20，否则该常量会长期低于计划意图。若上游认为应保 20，则 Task 1 的用例数需一次到位（与 brief Step 6/Step 10 的 5 例冲突）。
4. `tt_mod` 的两种实现都可（D2 细则）：我用真取模（`%`+abs），计划用折半折叠（`|h/2| mod cap`）。二者皆为确定性槽位函数、正确性等价，但若 Task 2/3 把 `tt_mod` 当通用取模复用，只有我的版本语义正确；若上游坚持计划的实现体，请显式改回（1 行）。
5. `ts_check` 的 bool到int 实参：bootstrap 侧产生 2 条非致命警告（同族 ~200 条既有）。自举侧 checker 无实参类型诊断，故不影响 project-mode 自举门；保留计划原文用例行形状（未改签名/用例）。
6. 原生压力程序不入库：它验证的是 P0 扩容路径，属一次性实证。若希望长期守门，建议 Task 3/4 把「预置小索引、触发扩容、去重仍精确」编成自测用例（用小索引预置可在 5到20 例扩充中低成本纳入，不必构造 512 项）。

---

## 9. 复现命令

```bash
nice -n 19 python3 build_selfhost_native.py            # BUILD SUCCESS + 三 guard clean
nice -n 19 ./build/corec selftest-types                # 5/5 … passed, rc=0
nice -n 19 python3 tests/selfhost/test_type_engine.py  # PASS test_selftest_types_all_pass
nice -n 19 ./build/corec run 'fn main()->int{return 42;}'   # rc=42
nice -n 19 python3 tests/selfhost/test_compile.py      # All selfhost compile tests passed.
```

（原生压力程序为 scratch：`/tmp/gen_native_stress.py` 生成 `/tmp/tt_native.cr`，再用 `./build/corec build /tmp/tt_native.cr --static -o /tmp/tt_native` 编译，最后运行 `/tmp/tt_native`。）

---

## 10. 提交

```
commit 52c15d53549c6459536efcb9a4f6133b9d94d8ce   (change kxxskkvsozltsptmlmzppzxxwrslsnqs)
feat: R2 P0 Task 1，类型项表（DAG + 哈希去重）+ 构造 API + selftest-types 自测通道骨架（checker 零改动）

9 files changed, 351 insertions(+), 1 deletion(-)
build_selfhost_native.py           |   6 +
src/compiler/_import.cr            |   3 +
src/compiler/globals.cr            |  17 +++
src/compiler/main.cr               |   4 +
src/compiler/type_engine.cr        |  23 ++++
src/compiler/type_selftest.cr      |  37 ++++++
src/compiler/type_terms.cr         | 214 +++++++++++++++++++++
tests/selfhost/test_compile.py     |   6 +-
tests/selfhost/test_type_engine.py |  42 +++++++

命令（路径限定；多 agent 共用工作副本）：
nice -n 19 jj commit src/compiler/type_terms.cr src/compiler/type_engine.cr \
  src/compiler/type_selftest.cr src/compiler/globals.cr src/compiler/main.cr \
  src/compiler/_import.cr build_selfhost_native.py tests/selfhost/test_compile.py \
  tests/selfhost/test_type_engine.py -m 'feat: R2 P0 Task 1，…（见上）'
```

与 Step 11 清单的差异（唯一）：清单中的 `src/compiler/dyn_arr.cr` 未提交，该文件经 D5 迁址后最终零改动（`jj diff -r kxxskkvs -- src/compiler/dyn_arr.cr` = 0 行），提交一个无 diff 的路径只会把并发 agent 的工作卷进来，与「路径限定」的目的相悖。

提交后工作副本为空（仅剩未跟踪的 `docs/archive/sdd/*.md` 工作流文档，本报告即其中之一）。提交内容 = 已重建并已跑完全部判据的同一份源码（第 3 节的构建/测试作用于该提交态）。
