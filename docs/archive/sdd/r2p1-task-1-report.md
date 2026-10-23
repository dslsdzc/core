# R2 P1 Task 1 报告：影子桥接层（checker `ti` 到 引擎类型项）

- 状态：DONE
- 提交：`e4c293b21c815d824f8379438d1190fba5fb1255`（short `e4c293b2`；change `mvorwzqx`）
- 路径限定提交（6 文件，工作副本无他人改动）：`src/compiler/ty_shadow.cr`(新) ·
  `src/compiler/globals.cr` · `src/compiler/type_selftest.cr` · `src/compiler/_import.cr` ·
  `build_selfhost_native.py` · `tests/selfhost/test_compile.py`
- 一行判据：`selftest-types` 67/67（P0 49 到 +18）+ 13 项回归全绿 + 产物与 R1 基线
  逐字节相同（sha256 `95084e7b…d475`）+ 自举链 `corec2/corec3 CMP_IDENTICAL` 且自举产物
  上 selftest-types 67/67。

---

## 1. TDD 红态输出（Step 2，实测）

写入 Step 1 用例（引用 `sh_term_of_ti` / `sh_map_entries` / `sh_map_hits`，实现前）后：

```
=== Building Core native binaries ===

--- Runtime (rt.s) ---
  -> build/runtime.o

[GUARD] corec: manifest OK (40 files)
--- corec ---
  Tokens: 135896
  Errors: ['Undefined name: sh_term_of_ti' ×14,
           'Undefined name: sh_map_entries' ×2, 'Undefined name: sh_map_hits' ×2]
```

`resolver.errors` 非空，`build_selfhost_native.py:257` 的 `sys.exit(1)` 立即终止（rc≠0，无产物）。
即红态 = 构建失败（18 条未定义名，逐条对应用例站点），非「用例不报错地挂」。

---

## 2. `TYP_TUPLE` 布局实读结果（Step 3 的重点项）

计划文写「字段在 `g_tuple_*`，见 checker 侧访问器」，`g_tuple_*` 在本仓库不存在
（全仓 grep 零命中）。实读两处消费点：

| 位置 | 代码 | 语义 |
|---|---|---|
| `src/compiler/checker.cr:118-131`（`type_equal` 的 TUPLE 分支） | `cnt := get_type_data(t1); start1 := get_type_extra(t1); ... r64(g_gen_apply_data, (start1 + i) * 8)` | `data` = 字段数，`extra` = 字段 `ti` 在 `g_gen_apply_data` 的起始下标 |
| `src/compiler/checker.cr:2041-2050`（字段访问 `t.N`） | `tc := get_type_data(actual_ti); data_start := get_type_extra(actual_ti); r64(g_gen_apply_data, (data_start + idx) * 8)` | 同上，第 i 字段 = `(extra + i) * 8` |
| `src/compiler/ast.cr:312` | `TYP_TUPLE : int = 10;  // data = element_count, extra = elem types start in g_gen_apply_data` | 常量注释同证 |

落法：`sh_tuple_to_product(ti)` 按 `(extra + i) * 8` 逐字段 `sh_term_of_ti`，串成 CONS 链。
链逆序构造（i 自末尾向前 `tail = tt_cons(term_i, tail)`），DAG 项不可变，正向追加需改写已建项，
不可行；逆序构造的结果顺序仍 = 声明顺序。任一字段翻译失败（-1）时整项 -1（不缓存半成品）。
守门用例 `bridge.tuple_product`（AK_PRODUCT）+ `bridge.tuple_fields`（链 = `cons(int, cons(str, nil))`，
顺序与内容逐项断言）。

（另：类型表扩容函数 `grow_gen_apply_data` 在 `src/compiler/dyn_arr.cr:496`，自测用例直接调用它铺字段。）

---

## 3. 与 brief 计划代码的偏差逐条

### 3.1 （真缺陷，必改）原生映射「AK_* 与 TI_* 前 7 项 1:1」不成立

计划（brief 表 + Step 3 代码注释）称 `AK_*` 与 `TI_*` 前 7 项 1:1，骨架据此写
`if ti <= TI_CHAR { return tt_atom(ti, ti, -1); }`。实测两序不同：

| 下标 | checker `TI_*`（`ast.cr:286-293`，spec 第11 同） | 引擎 `AK_*`（`type_engine.cr:19-22`） |
|---|---|---|
| 2 | `TI_BOOL` | `AK_STRING` |
| 3 | `TI_STR` | `AK_BOOL` |

即下标 2/3 互换。照抄骨架 到 `TI_STR` 译成 `AK_BOOL` 原子、`TI_BOOL` 译成 `AK_STRING`
（两侧同错且互相自洽 到 P1 Task 3 的差异清单将全是假信号，且无一用例能发现）。
改法：`sh_native_ak(ti)` / `sh_base_ak(ty)` 按语义逐项对应（`TI_STR 到 AK_STRING`、
`TI_BOOL 到 AK_BOOL`、`TY_STRING 到 AK_STRING` …），不依赖任何下标序假设。
守门用例：`bridge.str_ak` / `bridge.bool_ak`（用例名即缺陷面）。

### 3.2 （真缺陷，必改）骨架缓存表无扩容 到 表满时死循环

骨架 `sh_map_find` 只有「探测到空槽或命中」两个出口，容量固定 1024、无装填因子守卫：
条目数 > 1024（P1 Task 3 语料 = 编译器自身，`alloc_type` 每处数组/切片/元组/命名类型各占一行，
数千行规模）时探测永不落空 = 挂死。P0 终审 C2（memo 表满开放寻址空转 98% CPU）
与修复轮自抓的 `grow_tt_index` 重放死循环是同一族缺陷。
改法：探测前 `(g_shadow_entries + 1) * 2 >= g_shadow_map_cap` 到 `sh_map_rehash()`
（重建 + 重放既有条目；计数随重放重算，它就是守卫读的那个量，故不另设 count 全局，全局表
仍是计划给的 4 个）。
守门用例：`bridge.grow_rehash`（600 条互异 ti 逼出一次重建；断言条目数恰 +600 = 重放守恒
且重建前已入表的条目仍命中）+ `bridge.grow_cap_doubled`（cap ≥ 2048）。
（该路径常规用例不可达，初始容量 1024 vs 8 条，正是 P0「扩容路径判据不可达」教训的同款处理。）

### 3.3 （真缺陷，必改）骨架「先探槽位 到 递归翻译 到 回写该槽」在扩容后写错槽

骨架把 `slot := sh_map_find(ti)` 的槽位留到递归翻译全部子项之后才写回；子项翻译期间的插入
可触发扩容（表指针与容量变更）到 回写槽位索引失效 = 不报错地错写/丢条目（P0「扩容后去重不报错地失效」同族）。
改法：翻译完成后重探再写（`slot2 := sh_map_find(ti)`）。重探必落空槽，`ti` 图无环、
子项 `ti` 恒小于父项（`alloc_type` 单调追加），故不会自撞；命中分支仅为防未来改动的后备。

### 3.4 （偏差）原生快路径的覆盖与判定

- `TI_DYN` 一并纳入快路径（`sh_native_ak` 返回 `AK_DYN`），而非骨架的独立 `if ti == TI_DYN`，
  同式合并，语义不变（`tt_atom(AK_DYN, 7, -1)`）。
- 新增 `k1 < 0 到 return -1`：`ti` 越界（≥ `g_type_count`，`get_type_kind` 返回 -1）时骨架会落
  `else` 分支产出 `tt_atom(AK_NAMED, ti, -1)`（把不存在的行当命名类型缓存）。改为
  「无法翻译」-1，与接口约定（`-1 = 无法翻译`）一致，且 `g_types` 未初始化时不再产出伪项。

### 3.5 （偏差）`TYP_BASE` 走语义分派（计划表只列了 7 个 TY_*，未列 `TY_DEX_S`）

`TYP_BASE` 的 `data` 可能是 `TY_DEX_S`（下标 8 的占位表项，`ast.cr:113` 注记「永不参与解析/运算」）。
计划表未列此项。落法：`TY_DEX_S 到 AK_DEX`（其值域仍是 dex，只是缩放整数表示，表示层差异
不进类型身份）。这是判断项，请复审确认；备选是归 `AK_NAMED`（到 UNKNOWN，更保守但会把
dex 哨兵行降级成「未知类」）。已知该哨兵在实践中不会作为解析结果出现在 `ti` 位（`res_type_node`
两处映射 `checker.cr:367-380`/`:886-893` 均不产它），故风险面≈0。

### 3.6 （偏差）`TYP_DYN`（位图）按表落 `AK_DYN`，但是过宽近似（保留注记）

`TYP_DYN` 的 `data` = 类型集位图（≤64 型）。引擎 `AK_DYN` 语义 = ⊤（与一切相容，
`ak_disjoint` 注记）。两者不同型：把 n 元 dyn 集译成 ⊤ 会让引擎判「与任意类型等价」，
而旧判定可能区分 到 Task 3 里同源 dyn 集之间可能出现假 OLD_STRICTER 信号。
P1 不动引擎，按计划表落 + 代码内注记（`ty_shadow.cr` 的 `TYP_DYN` 分支），供 Task 3 归因时排除。

### 3.7 （偏差）`TYP_REF` 的 `extra`（mut 标记）不入参数链；`TYP_ARRAY` 的 `extra`（N）同理

与任务约束（N 不入身份 = R1 裁决）一致，`mut` 同款处理（引擎无只读/可写区分 = P3 条目化面）。
计划表对 PTR/REF 只写「参数链 `[inner]`」，即已隐含此裁决，此处仅显式化 + 注记。

### 3.8 （偏差）实现形态：`tt_mod` 复用、探测循环写法

- 非负取模直接复用引擎 `tt_mod`（`type_terms.cr:62`），不照抄骨架的
  `ti % cap; if h < 0 { h = 0 - h; }` 内联式：两者等价（cap 恒为 2 的幂、先取余后取绝对值不溢出），
  但复用避免本仓库出现第三份取模式各自变化。ty_shadow.cr 与 type_terms.cr 同属 corec 单元
  （均不在 corearch/corelsp 清单），无共享面越界。
- `sh_map_find_nogrow` 的探测循环用 `ret + break + 尾 return`（同 `tt_term` 的探测循环），
  不用「循环体内裸 return 收尾」。原因：自托管 checker 对「函数体以无 break 的 loop 收尾」
  判落空 到 报 `error[TF01] Function return type mismatch`（实跑 `check src/compiler/main.cr`
  基线在 `lits_copy`/`ty_memo_slot_no_grow` 各报一条，均为既有误报）。改用尾 return 后
  `check src/compiler/main.cr` 的 TF01 仍是 2 条（未新增），P1 Task 3 的语料日志不添新噪声。
  语义等价、无死代码（尾 return 就是真实出口）。
- 自测用例的前置：`type_selftest_run` 不走 `check_all()`（`init_types` 的唯一调用点，
  `checker.cr:2402`），故 g_types 未初始化 到 桥接段显式 `init_types()`（brief Step 1 注释
  已提示）+ `ty_budget_reset(200000)` 清干净窗口（P0 修复复审 N5 同款卫生）。
- 自测用例 +18 而非 brief 的 +5：brief 的 5 例逐字保留，另按计划映射表逐行补
  `str_ak/bool_ak`（3.1 缺陷面）、`dyn_ak`、`ptr_inner/ref_inner`（两分支不得互串）、
  `slice_seq`、`named_ak_b`、`tuple_product/tuple_fields`（第 2 节布局面）、
  `entries_delta/hit_delta`（缓存语义精确断言：+1 入表 / +1 命中）、
  `grow_rehash/grow_cap_doubled`（3.2/3.3 扩容面）。49 到 67。

### 3.9 与 brief 一致、未改动的部分

文件与函数名（`ty_shadow.cr` / `sh_term_of_ti` / `sh_map_hits` / `sh_map_entries` /
`sh_map_cap_init` / `sh_map_find` / `sh_tuple_to_product`）、全局 4 项（`g_shadow_map` /
`g_shadow_map_cap` / `g_shadow_hits` / `g_shadow_entries`）与声明位置（P0 引擎全局块之后）、
16B/条 `{ti, term}` 布局、AK 槽位语义（`ti` 存 `b` 槽 / 参数存 `c` 槽）、
`AK_SEQUENCE`+`[elem]`（不带 N）、`AK_NAMED` 不展开 到 UNKNOWN、三处注册与位置（corec 清单 checker 段后）、
提交信息文本。

---

## 4. 重建守卫行（`nice -n 19 python3 build_selfhost_native.py`）

```
[GUARD] corec: manifest OK (41 files)
[GUARD] corec: build log clean (error[ = 0, undefined = 0)
[GUARD] corearch: manifest OK (31 files)
[GUARD] x86_64-linux target: manifest OK (3 files)
[GUARD] corearch: build log clean (error[ = 0, undefined = 0)
[GUARD] corelsp: manifest OK (26 files)
[GUARD] corelsp: build log clean (error[ = 0, undefined = 0)
=== BUILD SUCCESS ===
```
（corelsp 段的 checker warnings 为既有 stdlib chan/sched 面，与本改动无关；三 guard 全 clean。）

## 5. selftest 计数行

```
67/67 type-engine cases passed      （PASS 行 67 条、FAIL 行 0 条；rc=0）
```
分段：P0 全类 49 + 桥接 16（brief 5 + 映射表/缓存细面 11）+ 扩容/重放 2。

## 6. 「P1 行为零变化」判据

```
nice -n 19 ./build/corec clean-cache
nice -n 19 ./build/corec build tests/suite/ptr_arith.cr --static -o /tmp/p1t1_v2
cmp /tmp/r1t4_base_bin /tmp/p1t1_v2   到 相同
sha256 95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475（两者同）
```
与 P0 收官引用的基线 sha256 `95084e7b…d475` 一致。

## 7. 回归（13 项清单，P0 Task 5 同款；末树实测）

| 项 | 结果 |
|---|---|
| `corec selftest-types` | 67/67 rc=0 |
| `test_type_engine.py` | OK |
| `test_compile.py` | OK（native corec 编译 .cr 到 ELF，冒烟 rc=42） |
| `test_backend_bootstrap.py` | OK（stage1/2/3 byte-identical + 冒烟 7） |
| `test_hit_table.py` / `test_ccr_v7.py` / `test_live_ranges.py` / `test_slice_bounds.py` / `test_global_init.py` / `test_lexer_parity.py` | 全 OK |
| `bootstrap/test_pipeline.py` / `test_borrow.py` / `test_generics.py` | 全 OK |

## 8. 自举链（计划归 Task 4；本任务顺带跑，因 `_import.cr` 正落在该路径上）

```
nice -n 19 ./build/corec build src/compiler/main.cr -o /tmp/p1t1_f2 --static -O 0     # rc=0
nice -n 19 /tmp/p1t1_f2 build src/compiler/main.cr -o /tmp/p1t1_f3 --static -O 0      # rc=0
cmp /tmp/p1t1_f2 /tmp/p1t1_f3 到 CMP_IDENTICAL
/tmp/p1t1_f2 selftest-types   到 67/67 type-engine cases passed     ← 自举产物上自测全绿
grep -c 'error\[' 两个构建日志 到 各 2 条（= 既有 lits_copy / ty_memo_slot_no_grow 两条 TF01，零新增）
```
`[2/5] resolve imports` 段可见 `-> src/compiler/ty_shadow.cr`，`import ty_shadow` 在
project-mode 导入链上实测被加载（非「注册了但没人走」）。

---

## 9. 遗留 / 供复审与后续任务注意

1. 3.5 `TY_DEX_S 到 AK_DEX` 是判断项（计划表未列），备选 `AK_NAMED`；请复审裁决。
2. 3.6 `TYP_DYN`（位图）到 `AK_DYN`(=⊤) 是过宽近似：Task 3 归因差异时须把「同源 dyn 集」
   类差异单列，不得计入「收紧面」。
3. `AK_NAMED` 不展开 到 判定 UNKNOWN：P1 预期（未覆盖面，与收紧面分开统计），Task 2
   `sh_compare` 已按此设计（`e == -1 到 unknown`）。桥接层把「命名/泛型/未知 kind」与
   「无法翻译（越界）」区分开：前者产出项（判 UNKNOWN），后者 -1（`sh_compare` 计入 unknown）。
4. 影子表扩容用 bump alloc（旧表不回收）：一次语料运行内多代旧表并存，规模 = 2×cap×16B 的
   几何和（cap 2048 到 ~96KB 峰值），可接受；若 Task 3 遇到更大语料再评估。
5. 自测用例的 `init_types()` 在 `selftest-types` 通道内重置 `g_type_count = 0` 后重铺 9 项
  ，该通道不走编译管线（`main.cr:363` 直接返回），无外溢；但若未来有人在编译路径中调用
   `type_selftest_run()`，需先拆出 `init_types()` 调用。
