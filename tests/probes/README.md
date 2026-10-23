# 行为探针语料（判定面回归检查分支 2 的实现方式）

来源：R2 P5 各任务在 `/tmp` 侧的探针语料实拷入仓（R2 P6 Task 1 / 交接包 E-13）。

> 子目录 `warm/`（#2026-09-15-5 T3 新增，7 档）：有缓存状态分支专用语料，不进本目录的 29 档清单
> （本 runner 是非递归 glob，不会收集它）。检查、固定路径要求与用法见 `warm/README.md` 与
> `tools/baseline/warm_leg.sh` 头注。

性质：不是编译器编译单元（不在任何清单内、不被任何套件收集）。它们是 `check` 面的行为断言输入，
由 `tools/baseline/probes_run.sh` 逐档运行（`clean-cache`，`check`，记 rc + 日志）。

## 用法

```bash
bash tools/baseline/probes_run.sh ./build/corec /tmp/probes_now          # 当前二进制
bash tools/baseline/probes_run.sh /tmp/p6-baseline/corec /tmp/probes_base # 冻结基线
diff -rq /tmp/probes_now /tmp/probes_base                                # 两态零差异 = 判定面行为未变
```

rc 判读：本目录语料大量为负例（期望 rc=1），`rc=1` 是预期行为（诊断正确拒绝），
不是失败。检查 = 两态逐档 rc + 日志零差异（与 P5 记录值比），不是“全 rc=0”。

## 清点（29 档 = `/tmp/p5t0/probes` 11 + `/tmp/p5t3/probes` 18）

> U-4 收尾：P5 清单曾记“30 档”，该计数不成立：迁移期 runner 的
> `for f in /tmp/p5t3b/probes/*.cr` 在零匹配目录上迭代字面 glob，产生伪条目
> `_tmp_p5t3b_probes_*.cr`（rc=1，log = `error: cannot read …/*.cr`），两态恒等，所以该条对拍没有实际覆盖。
> 正式值 = 29（R2 P6 T0 3.2 节）；`/tmp/p5t3b/probes` 是 T3b 的输出目录
> （21 log + 6 dump），不是语料目录。此后文档一律写 29。

| # | 入仓文件 | 原路径（`/tmp`） | 出处 | 形态 | P6 起点 rc |
|---|---|---|---|---|---|
| 1 | `p_annots.cr` | `/tmp/p5t0/probes/p_annots.cr` | P5 T0 2 节（表 A 探针） | `@NoBoundsCheck` 语句形态（`IR_NO_BOUNDS_CHECK`/`IR_FAST` 零 IR，F4 登记） | 0 |
| 2 | `p_annots2.cr` | 同目录 | P5 T0 2.3 节（F4） | `@NoBoundsCheck()` 括号形态（唯一可达形态） | 0 |
| 3 | `p_dex.cr` | 同目录 | P5 T0 2 节（表 A） | dex 算术 + `as int`（`IR_I2F`/`IR_F2I`/`IR_BINARY` 行值为 `TI_FLOAT`） | 0 |
| 4 | `p_dyn.cr` | 同目录 | 同上 | `dyn` 槽（`TYP_DYN` 行面） | 0 |
| 5 | `p_enum.cr` | 同目录 | 同上 | 枚举构造 + match（`IR_MAKE_ENUM`/`IR_LOAD_ENUM_TAG`） | 0 |
| 6 | `p_ffi.cr` | 同目录 | 同上 | `extern "C" fn`（字面量 ABI 形态），期望 rc=1（该形态不可解析） | 1 |
| 7 | `p_ffi2.cr` | 同目录 | 同上 | `extern fn`（`IR_CALL_EXTERN` 可达形态） | 0 |
| 8 | `p_go.cr` | 同目录 | 同上 | `go work()`（`IR_SPAWN`/`IR_YIELD`/`IR_AWAIT`） | 0 |
| 9 | `p_i2f.cr` | 同目录 | 同上 | int 到 dex 返回位（`IR_I2F` 恒 `TI_FLOAT` 行） | 0 |
| 10 | `p_opt.cr` | 同目录 | 同上 | `T?` + `Some` + `?` 解包（可选表示面） | 0 |
| 11 | `p_spawn.cr` | 同目录 | P5 T0 2 节（`IR_SPAWN` 的 `aux=-1` 辅码面） | `go i 0..3 f(i)`（动态 spawn 计数） | 0 |
| 12 | `n02_diff_named.cr` | `/tmp/p5t3/probes/n02_diff_named.cr` | P5 T3（表 D d2） | 异名同形命名互赋（命名面判定化主例） | 1 |
| 13 | `n03_apply_twice.cr` | 同目录 | P5 T3（表 D d3b） | 同实参泛型应用两次实例化（必须判等） | 0 |
| 14 | `n04_apply_diff_args.cr` | 同目录 | P5 T3 | 异实参应用（判不等） | 1 |
| 15 | `n05_recursive.cr` | 同目录 | P5 T3（表 D d4） | 递归命名 `struct Node { next: *Node }` | 1 |
| 16 | `n09_t_vs_int.cr` | 同目录 | P5 T3（表 D d9） | 泛型形参位 `T` vs `int` | 0 |
| 17 | `n10_named_vs_int.cr` | 同目录 | P5 T3（混类收紧面） | 命名 × 原生（混类得到 0） | 1 |
| 18 | `n12_alias.cr` | 同目录 | P5 T3 | 类型别名一层透明 | 0 |
| 19 | `n13_arr_diff_named.cr` | 同目录 | P5 T3b（1 节残留面） | `[NA;2]` vs `[NB;2]`（不变槽元素三态） | 1 |
| 20 | `n14_optional_diff_named.cr` | 同目录 | P5 T3 | 可选异名 `NA?` vs `NB?` | 1 |
| 21 | `n15_apply_named_arg.cr` | 同目录 | P5 T3 | 应用含命名实参 | 1 |
| 22 | `n16_nested_apply.cr` | 同目录 | P5 T3 | 嵌套应用 `Box[Box[int]]` 两次实例化 | 0 |
| 23 | `n17_ptr_named.cr` | 同目录 | P5 T3b | `*NA` vs `*NB` | 1 |
| 24 | `n18_tuple_named.cr` | 同目录 | P5 T3b | 元组含异名 `(NA,int)` vs `(NB,int)` | 1 |
| 25 | `n19_ref_named.cr` | 同目录 | P5 T3 | `&NA` vs `&NB`（引用元素位） | 0 |
| 26 | `n20_apply_named_vs_int.cr` | 同目录 | P5 T3（混类） | `Box[NA]` vs `Box[int]` | 1 |
| 27 | `n21_t_assign_int.cr` | 同目录 | P5 T3（混类） | `T` 赋 `int` | 1 |
| 28 | `n22_named_struct_field.cr` | 同目录 | P5 T3 | 命名结构体字段位 | 0 |
| 29 | `n23_enum_named.cr` | 同目录 | P5 T3 | 异枚举同名变体（身份域） | 0 |

起点 rc 分布：17×0 / 12×1（R2 P6 T0 实际运行，与 P5 T7 `/tmp/p5t7/probes_post/rc.txt` 的 29 条实档逐档相同）。

逐档 sha256 交叉核：入仓 29 档 sha 与 T0 的 `/tmp/p6t0/probes_manifest.txt` 29/29 逐条相同
（实拷、未改写。不要在探针源里加注释：逐字节保真才能复现 rc/日志）。

## 运行条件（均为硬性要求）

1. 变异态证据不在本目录：T3b 的 `n13/n17/n18` 在变异二进制（M1..M4）下转为失败的证据
   （`/tmp/p5t3b/probes/*.M{1..4}.log`、`.M2.dump`，共 15 件）须先重造变异二进制才能重新运行，
   方法见 `p5-task3b-report.md` 3.3 节，不随语料入仓（登记在案，不声称可重复运行）。
2. 影子通道产物不可复现：T3b 的 42 行 `[type-shadow…]` 摘要行（21 log × 2）没有二进制可产出
   （通道已随 P5 T5 删除），因此不得引用为证据（三态纪律：不可产出的读数 = 无读数）。
3. 失败态复现（`n13/n17/n18` 的 pre-T3b 行为）须用固定基线（其仍带影子旗标）。
   R2 P6 T0 3.3 节已实测：固定基线 × 三档 + `--type-shadow*` 得到的 `red.log`/`red.dump` 与 `p5t3b` 的
   对应文件逐字节相同（log 归一化 dump 路径行后）。
4. cwd = 仓库根（runner 已 `cd`；`/tmp` cwd 会改变相对 import 解析域，产生假 rc）。
5. 探针语料只增不减：新增或删除须同步 `tools/baseline/probes_run.sh` 的 `PROBE_TOTAL` 与本表
   （计数不符 = runner 硬失败）。
