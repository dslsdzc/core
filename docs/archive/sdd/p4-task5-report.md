# R2 P4 Task 5 报告：可选运行期表示，解包侧判断表示（裁决 5）

日期：2026-09-13。基线：`387abf2e`，P4 Task 4。裁决：计划 `2026-09-12-r2-p4-carrier.md` 的裁决 5“解包侧判断表示，与 TYPE 段同批”。缺口来源：P3 计划附录 B.7 的一等条目，`T?` 运行期表示未统一，导致 `Some` 臂双路径 SIGSEGV。
文件面：`src/compiler/ir_gen.cr`、`src/compiler/globals.cr`、`src/arch/x86_64/instr.cr`、`src/compiler/main.cr`、`tests/selfhost/test_optional.py`（12 到 34 例）、`src/ci/run.sh`、计划（Task 5 实施记录加 B.7 收口）、TODO（#43 实施条目加 #14 触发实证②）。

---

## 1. 红态复现（自跑，不引用 B.7 记录）

21 形态矩阵，脚本为 `/tmp/p4t5/probe/gen.py`。每个形态运行 `check`、`build`、产物运行、`corec run` 四路，cwd 为仓库根：

| 形态（简） | 修复前 ELF/interp | 修复后 ELF/interp |
|---|---|---|
| L1 `x : int? = 5` 加 `Some(v)`/`None` 臂（B.7 最小复现） | 139 / 139 | 5 / 5 |
| L2 裸值加纯通配臂（B.7 边界，不崩） | 7 / 7 | 7 / 7 |
| L3 `x : int? = Some(9)` 加 `Some` 臂 | 9 / 9 | 9 / 9 |
| L4 `x : int? = None` 加 `None` 臂 | 8 / 8 | 8 / 8 |
| L5 裸值加 `Some`/通配混合臂 | 139 / 139 | 5 / 5 |
| L6 match 作表达式取值（`y := match x {…}`） | 139 / 139 | 5 / 5 |
| L7 裸值初始化后 `x = Some(7)` | 7 / 7 | 7 / 7 |
| L8 `Some(7)` 初始化后 `x = 3`（裸值改写） | 139 / 139 | 3 / 3 |
| L9 条件写（`if c > 0 { x = Some(4) }`，c=1） | 4 / 4 | 4 / 4 |
| X1 裸值返回，调用方 `Some` 臂 | 139 / 139 | 5 / 5 |
| X2 装箱返回加 `Some` 臂 | 9 / 9 | 9 / 9 |
| X3 裸值返回加通配臂 | 11 / 11 | 11 / 11 |
| X4 裸值形参加 `Some` 臂 | 139 / 139 | 5 / 5 |
| X5 装箱形参加 `Some` 臂 | 6 / 6 | 6 / 6 |
| X6 裸值形参加 `?` 解包 | 3 / 3 | 3 / 3 |
| X7 装箱形参加 `?` 解包（`f(g())`） | 8 / 200，双路径各错各的，不报错地 | 7 / 7 |
| X8 混合返回（同函数两条 return 两种表示） | 4 / 4，碰巧 | 4 / 4，确定 |
| X9 结构体字段裸值加 `Some` 臂 | 139 / 139 | 139 / 139，未覆盖面，见 §4 |
| X10 结构体字段装箱值加 `Some` 臂 | 5 / 5 | 5 / 5 |
| X11 裸值入 `int?` 返回位（不匹配） | 42 / 42 | 42 / 42 |

`check` 和 `build` 对全部形态恒为 rc=0 零诊断，修复前后相同。这个缺口从一开始就不是诊断面。

预存性复核：pre-Task-5 二进制 `/tmp/p4t4/base/corec` 跑同一矩阵，结果等于上表“修复前”列，说明红态是既有问题，不是本任务引入。

---

## 2. 设计（Step 1 实现方式裁定到实施形态）

裁定为候选 (a)“表示位侧表”，这是计划推荐项。实施形态在 IR 层，不使用后端帧旁路字节。

- 表示位是一个普通 int IR 变量，每个可选槽一个，包括局部、形参、调用结果。值 0 表示裸值，槽内就是 T 值，Some 臂载荷为槽值本身；值 1 表示装箱，即 `IR_MAKE_ENUM` 对象 `[tag][payload…]`，载荷是字段 `fi+1`。
- 写点置位使用 `emit_rep_set`。静态已知时发 `IR_CONST`；源槽已有表示位时拷贝。写点覆盖 `EXPR_LET`（显式 `T?` 标注，推断槽按初值表示面补配）和 `EXPR_ASSIGN`（ident 目标）。
- 解包点分派，判决点在本任务核心：
  - `match` 的 `EXPR_ENUMPAT` 臂。臂条件：`Some` 模式在裸值时直接命中，不读 tag，因为裸值不是对象，读 tag 就是原来的 SIGSEGV；装箱走既有 tag 比对。`None` 模式在裸值时不命中，因为裸值不是 null；装箱走 tag 比对。臂体载荷绑定：裸值时 `fld <- 槽值`，装箱时 `load_field fld = 槽.1`。
  - `?`（`EXPR_TRY`）：裸值直取槽值，装箱取字段 1。
  - 没有表示位的槽逐字走既有路径，即装箱假定等于 P3 前语义。这是“未覆盖面不出现不报错地分歧”的结构保证。
- 跨函数面使用隐藏全局信道，纯 IR。返回信道在返回点写，值求值完成后、紧邻 `IR_RETURN`；调用点读，紧跟 `IR_CALL`，其间没有写入，嵌套调用不会覆写。形参信道每个形参位一个单元；调用点在全部实参求值后、紧邻 `IR_CALL` 写；被调在序言最早处读，先于任何可能改写信道的调用。
- 纯 IR 意味着零 ABI、帧布局、opcode 改动，ELF 后端和解释器天然同源。本任务全部判据都是“双路径同值”，没有一例分歧。
- 零影响门：AST 没有 `EXPR_OPTIONAL` 且没有 `Some`/`None` 构造时，整面不启用，不注册隐藏全局，不发任何表示指令，非可选程序的发射面逐字节不变，§5 有实测。

---

## 3. 五个根因（逐条：现象、定位、修法、证据）

实施中逐个实测挖出，后四个是计划未列的面，均按纪律 #1“找根因直接修”处理。

① 表示位侧表的空槽哨兵，本任务自身实现缺陷，实测暴露。
- 现象：`Some` 初值的表示位被写成 0，等于裸值，解包走错分支，L3 从 9 变成 8。
- 定位：侧表“无表示位”哨兵是 -1，但 `alloc` 零初始化，未写槽读 0，等于“表示位是 var 0”，每个值都被判成有表示位。gdb 实测 `emit_rep_set(rep_var=26, enc=0)`。
- 修法：`grow_ir_var_rep` 的新槽填 -1，照 `tag2l.cr` 的 tag 区初始化先例。

② ELF 后端逐 op 的“全局行分派”缺口，既有后端缺口。本任务触发两处，另实测发现一处。
- 现象：X5 装箱形参在 ELF 恒返回 8，即对象指针低字节，interp 正确返回 6，双路径分歧。
- 定位：`instr.cr` 的 `IR_CONST` 用 `g2_slot(d)` 帧槽直写，没有 `g_x86_is_global` 分派。落到全局行时会写帧外伪偏移，不报错地丢写；解释器对同一 IR 直写 `g_ir_vals`，于是分歧。本任务首次出现“IR_CONST 落全局行”的发射点，即形参信道单元。
- 修法：`instr.cr` 加全局行分支，常量入 r10，用 `e2_lrb` RIP 取址，记录 patch，与 `IR_LOAD`/`IR_STORE` 的全局分派同款。修在根因，不在 ir_gen 侧改用“临时变量加 IR_STORE”绕开，因为绕开仍会保留后端不报错地丢写。

③ 负值文件级常量在自举链二进制里不报错地读 0，这是 TODO #14 的 live 触发。
- 现象：两个表示码常量 `OE_BARE = -1`、`OE_BOXED = -2` 读成 0，两码合一，全部置位取 0。gdb 实测常量槽读 0。
- 定位：Python bootstrap 的 `gen_let_decl`（`bootstrap/corec/frontend/ir_gen.py:68-74`）只对裸 `Literal` 记 `constant_value`。`-1` 被解析成 `UnaryOp`，初值丢失，`x86_64_stack_asm.py:622-626` 发出 `.quad 0`。
- 修法：改用函数 `oe_bare()`/`oe_boxed()`，返回值表达式不受该路径限制。常量先放 `ir_gen.cr`、后移 `globals.cr` 都同病，证明与文件位置无关，纯粹是“初值形态”面。
- 连带实证，TODO #14 增补：`cir_cache.cr` 的 `CIR_CACHE_MAGIC : int = -4485090715960753727` 在自举二进制里同样读 0，落盘 `.cir` 头部 magic 用 `od` 实测全 0，应为 C1C1…。写读两侧使用同一常量，所以自洽，不炸测试，属于同族问题。

④ 返回类型判据取错字段。`fi_return_type` 是裸码，`T?` 的节点 `type_val` 为 0。
- 现象：X1 裸值返回时，调用方表示位回落装箱，解包仍崩。
- 定位：`fi_return_type` 是 parser 存的裸类型码。`T?` 的类型节点 `type_val` 为 0，读成 int 行，判据恒假。既有注释已写明 `ast_type_val(fn_node)` 才是返回类型节点下标。
- 修法：两侧同改。被调序言（`ir_gen_func` 的 `g_cur_ret_opt`）和调用点（新增 `callee_ret_optional()`）都改走返回类型节点加 `res_type_node`。

⑤ 惰性 thunk 把调用推迟到 force 点，返回信道读点悬空。
- 现象：`v := g()`，`g` 被判纯，走 `IR_LAZY_THUNK`，调用点在 force 处，返回信道读点在 `IR_CALL` 后，读到陈旧值，X1 复崩。
- 修法：被调返回可选时禁用 thunk。代价只有这一类不做延迟，其余程序不受影响。

⑥ `IR_LOAD_ENUM_TAG` 的 tag 读取源同样缺全局行分派，与②同族，实测发现，基线同病。
- 现象：全局可选槽 `g : int? = Some(5)` 加 `Some` 臂时，ELF 为 0，interp 为 5，双路径分歧，属于不报错地类。
- 定位：`IR_LOAD_ENUM_TAG` 用 `e2_ld(o1 = g2_slot(s1))` 帧槽读 tag。全局行读帧外伪偏移，tag 读到垃圾，match 不报错地走空臂，结果槽未写，得到 0。基线二进制同病，同一命令 ELF=0/interp=5，是预存问题，不是本任务引入。本任务在 §4 未覆盖面实测时发现。
- 修法：tag 源改走 `e2_load_var`，局部和全局双态，与 `IR_LOAD_FIELD` 同款。目的槽的全局行未接，当前零发射点，已注释登记。修后 U2 为 5/5，U2b（None）为 9/9，ELF canary 不变，该路径不在 canary 语料内。

---

## 4. 未覆盖面（硬性登记：逐形态实测三态）

按计划 Step 1 的硬约束“保持响亮失败或保守拒绝，不得退化为不报错地错值”，下列形态不配表示位，解包回落既有装箱假定，实测如下：

| 形态 | 装箱值 | 裸值 |
|---|---|---|
| 结构体字段（`S{a:int?}`） | 正确（5 / 5） | 响亮失败 rc=139，双路径相同 |
| 全局槽（`g : int? = Some(5)`） | 正确（5 / 5，None 臂 9/9）。前提是⑥的 tag 源全局行分派已修；修复前 ELF=0、interp=5，是不报错地分歧 | 同上，响亮 139，双路径相同 |
| 数组元素 / match 结果 / 可选的惰性 thunk | 按同结构走既有路径，未逐一探针，登记 | 同上 |
| 可选的惰性 thunk | 不存在：被调返回可选者已禁 thunk，见⑤，该面关闭 | 无 |

不新增不报错地错值。本条的关键性质是未覆盖面不产生双路径分歧。修复前 X7 那种“ELF 一个值、interp 另一个值”的不报错地类已被本任务消灭；未覆盖面两侧一致。

修复面边界：结构体字段和数组元素需要在对象布局里放表示位，packed 位图会改变结构体尺寸，数组 element stride 也会变，不在本任务 Files 面内。登记为 P5/P6 承接项，与 `MAX_*` 定长槽评估同批。

登记用例：`test_optional.py` 的 `uncovered_field_bare_is_loud`，钉“双路径同 rc=139”；`uncovered_field_boxed_ok`，钉装箱形态照常正确。

---

## 5. 判据（逐条命令与结果）

| 序号 | 判据 | 命令 | 结果 |
|---|---|---|---|
| 1 | 构建 | `nice -n 19 python3 build_selfhost_native.py` | rc=0；三面 `error[`=0 / `undefined`=0 |
| 2 | 自举回归套件 | `tests/selfhost/test_backend_bootstrap.py` | rc=0，`error[` 为 0 |
| 3 | 自源检查 | `./build/corec check src/compiler` | rc=0 |
| 4 | 自测 | `./build/corec selftest-types` | 355/355。用例数不变，本任务不动类型层 |
| 5 | 行为覆盖集 | `tests/selfhost/test_optional.py` | 34/34。从 12 到 34：B.7 四形态加写点/条件写加跨函数 6 面加未覆盖面 4 例，即结构体字段裸/装箱加全局槽装箱/None |
| 6 | ELF canary（裁决 8 硬判据） | `clean-cache`，然后 `build tests/suite/ptr_arith.cr --static`，再 sha256 | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`，IDENTICAL。未触发允许面变化，理由是非可选程序零影响 |
| 7 | `.ccr` 面（TODO #26） | 冷缓存 `ptr_arith` / `generics_test`，基线编译器和新编译器同源 | 逐字节 IDENTICAL：`ptr_arith` 90966B，`generics_test` 134844B，用户程序零扰动。与 Task 4 记录值 90823B/134701B 的 +143B 差不是本任务：用基线编译器重建同源也得到 143 差，期间 `arena_globals` 导入引入 4 个全局和 1 个串，已逐段点名。本任务新记录值为 90966B / 134844B |
| 8 | 可选程序 `.ccr` | 冷/热两态同源 | IDENTICAL，99757B，见 §7 缓存面 |
| 9 | `--dump-objects` | `ptr_arith`，基线编译器同源和新编译器 | 逐字节相同，2427 行 |
| 10 | 自举链 | `corec build src/compiler/main.cr -O 0` 得到 corec2，再得到 corec3 | `cmp /tmp/corec2 /tmp/corec3` IDENTICAL，两个 2783750B 文件 sha `5492d9ad…`；N06=0；冒烟 `run 'fn main()->int{return 42;}'` 为 42（corec/corec2）；`corec3 --help` rc=1 |
| 11 | 全枚举 | 47 个 selfhost 加 7 个 bootstrap，逐档 rc | 54/54 rc=0 |
| 12 | CI job | `CI_JOB_NAME={check,bootstrap-tests,suite,selfhost-tests} bash src/ci/run.sh` | check rc=0；bootstrap-tests 3/3；suite ALL PASS；selfhost-tests rc=0 |
| 13 | 同源对拍（判定面零变化） | `bash /tmp/p3t0_run.sh {check,shadow}`，pre-Task5 二进制和新二进制 | 两侧 diff 空，check 和 shadow 各 0 行；`decisions=32564 agree=32564`，全计数 0；站点覆盖同报：assign-node=24709、fn-body-ret=5793、if-branch=2028、struct-field-type=28、array-elem-type=4、generic-apply-base=2，两侧相同 |
| 14 | 交叉对照（红态基线） | pre-Task5 二进制 `/tmp/p4t4/base/corec` 跑同 21 形态 | 等于 §1 的“修复前”列，红态可复现，不是本任务引入 |
| 15 | 编译耗时抽样 | 200 函数可选密集合成源 3 次取最小；`generics_test` 3 次取最小 | 可选：基线 315ms，新 282ms；非可选：55ms 到 55ms，无回退。使用 `nice -n 19` |

---

## 6. 台账

放宽（旧拒绝、新接受）为 0，判定面零变化，§5-13 反证。
收紧（旧接受、新拒绝）为 0，没有新诊断或新硬门，本任务不动判定面。
修复（旧崩溃或不报错地、新正确值）为 8 个形态，包括 L1/L5/L6/L8/L9 的裸值路径、X1、X4、X6 的裸值路径，另有 1 类不报错地错值 X7：`?` 解包装箱值，修复前 ELF 和 interp 各错各的。
未覆盖面登记，不不报错地：结构体字段、数组元素、全局槽、match 结果、可选的惰性 thunk，见 §4。

---

## 7. 登记面（不得不报错地）

1. `.cir` 缓存对可选程序关闭。`main.cr` 文件路径中 `g_optrep_on != 0` 时 `cache_enabled = 0`。理由是表示位侧表是编译期进程内状态，快照不载它，命中恢复路径与冷路径会产生产物分歧，同 Task 4 `bad_term=329` 的教训形态。代价是可选程序每次全量重建，影响编译耗时，不影响产物；非可选程序照常缓存，缓存身份字段 v17 已覆盖跨二进制面。P5 承接：如果要把可选程序重新纳入缓存，须给快照加表示位面，或者在装载侧重派生，与 D15/P5 单槽化同批裁。
2. `IR_CONST` 的 TI_STR 加全局行仍未分派，同②。当前零发射点，字符串常量入全局走 `.data`/`_init_globals`，已在 `instr.cr` 注释登记。
3. 未覆盖面由 P5 承接，见 §4：在对象布局里放表示位，结构体 packed 位图、数组 stride，与 `MAX_*` 定长槽评估同批。
4. TODO #14 触发实证②，负值文件级常量：本任务实证加 `CIR_CACHE_MAGIC` live 实例，见 §3-③，已写入 TODO #14。
5. 预存缺陷登记，实测发现，不是本任务引入：冷/热缓存下 `corec build src/compiler/main.cr -O 0` 暖态 SIGSEGV，路径是 `load_cir_cache` 到 `str_len` 再到 `load64`，有 gdb 栈实测。基线二进制同病，冷 rc=0、暖 rc=139，属于预存。本任务可选面“关闭 .cir 缓存”的措施顺带规避了这个面，仅限可选程序。归属 `.cir` 缓存恢复面，与 TODO #5 末条同族，转主批。
6. 影子通道零覆盖实现方式面，继承声明。`--type-shadow` 只覆盖 `type_equal` 站点面，本任务正确性证据一律来自行为探针和双路径同值，见 §1/§5，不用影子归零充当证据。

---

## 8. 提交

`2be26cc5`（change `urwwzszylqpnzutzovvmnpkrsxyxzolt`，路径限定 10 个文件，见头部文件面加 TODO）。提交信息：`fix: R2 P4 Task 5——运行期可选表示统一（裁决 5「解包侧判表示」）：B.7 裸值 + Some 臂双路径 SIGSEGV（rc=139）闭合`。详版提交信息包含形态、判据、五个根因、未覆盖面、登记面。

diff stat：`src/compiler/ir_gen.cr` +391、`globals.cr` +32、`main.cr` +10、`src/arch/x86_64/instr.cr` +16、`test_optional.py` +127、文档和脚本 37，合计 10 个文件，+591/−25。

`cf368259` 是补提交，5 个文件：`src/arch/x86_64/instr.cr`、`tests/selfhost/test_optional.py`、`src/ci/run.sh`、计划、TODO。提交信息：`fix: R2 P4 Task 5 补——IR_LOAD_ENUM_TAG tag 读取源补全局行分派（②同族第三处；实测发现的预存不报错地双路径分歧）`，见 §3-⑥。

本报告与其他 `docs/archive/sdd/*` 报告同档，不入版本控制，随工作树本地保留。

报告路径：`/home/DslsDZC/core/docs/archive/sdd/p4-task5-report.md`。
