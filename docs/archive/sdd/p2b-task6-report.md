# R2 P2b 任务 6 报告：`res_type_node` 两份 TY 到 TI 映射合一，并处理同族 6 处内联链

状态：完成，但有保留项（DONE_WITH_CONCERNS）。全部判据通过，三层突变都有判别力，零行为变化的四面对拍逐字节相同。

保留项有两条，请 lead 过目：

① 计划 Interfaces 段的 `TY_DEX_S` 到 `TI_DEX_S` 一格未实现，实测理由见第 6.1 节，属于“保语义优先”的裁决性偏差。

② 计划步骤 3 的字面写法，“逐处改调 `ty_code_to_ti` 并逐处保留尾部回落”，不能做到零行为变化。6 处内联链的域逐站不同，而且有实际载荷，照字面写会不报错地改变判定，突变 M2 已实证，见第 7 节。本报告按“单表加逐站显式域”实施。

提交：`30545da7`（change `trzpvlmo`，父提交为任务 5 的 `7145eea5`）
计划：`docs/superpowers/plans/2026-09-11-r2-p2b-iface-ops.md` 的任务 6

一句话：8 个 TY 到 TI 站点，包括两张表和 6 条内联链，收敛到单表 `ty_code_to_ti`，逐站域差异显式保留。`never` 单元格经探针和插桩实测可达，`res_call_type` 侧现状为 unit，因此显式保留差异，不不报错地合一，并登记为 P3 待裁决项。零行为变化的四面对拍逐字节相同。

## 1. 交付物和落点（file:line，全部实测；行号为提交后）

| 交付物 | 落点 | 说明 |
|---|---|---|
| 单表 `ty_code_to_ti` | `iface_registry.cr:259-270`，注记在 `:236-258` | 8 个可达码逐项分派，域外返回 -1。码 7 格的现状写法原样保留。TY_DEX_S 不入表，见第 6.1 节 |
| 两表之一，基型分支 | `checker.cr:736-746`，域注在 `:738-741` | `res_type_node`：8 行链改为表加 `if mapped < 0 { TI_UNIT }` |
| 两表之二，基型分支 | `checker.cr:1393-1401`，NEVER 门注在 `:1394-1397` | `res_call_type`：7 行链改为表加 `if mapped < 0 || tv == TY_NEVER { TI_UNIT }` |
| 同族内联链 S1 | `checker.cr:1057-1069`，注在 `:1062-1066` | hotpatch 和普通注册（`rt_ti`），域为 {INT,DEX,BOOL,STRING,UNIT} |
| 同族内联链 S2 | `checker.cr:1083-1095`，注在 `:1087-1088` | hotpatch 首版（`first_rt_ti`），域同 S1 |
| 同族内联链 S3 | `checker.cr:1141-1151`，注在 `:1142-1145` | extern 注册（`rt_ti`），域为 {INT,DEX,BOOL,STRING,UNIT,CHAR} |
| 同族内联链 S4 | `checker.cr:1677-1689`，注在 `:1678-1680` | `check_func` 形参（`ti`），域为 {INT,DEX,BOOL,STRING,CHAR} |
| 同族内联链 S5 | `checker.cr:1729-1741`，注在 `:1734-1735` | `check_func` 返回（`ret_ti`），域为 {INT..CHAR}，包含 NEVER，缺 7 |
| 同族内联链 S6 | `checker.cr:2154-2170`，注在 `:2154-2158` | iface 返回（`iface_ret2`，值域本来就是 TI_*，因此把数值撞车比较显式化），域为 {INT..CHAR} |
| selftest 段（11 例，201 变为 212） | `type_selftest.cr:973-1027` | 表侧逐码、两处端到端、NEVER 差异格双向、域外回落、反真空 |
| 行为回归段（增加 16 例，60 变为 76） | `tests/selfhost/test_iface_ops.py:243-313`，新 helper 在 `:94-110` | 新增 `case_diag_lines`，按逐条（码，行号）的多重集判定，这是站点域判据的观测量 |
| 用例数同步 | `src/ci/run.sh:71-72` | selftest 212 例、iface_ops 76 例 |

未纳入合并，计划已明确记录，仅登记：`init_types` 的位置公理（`checker.cr:241-253`，8 行顺序分配加 TY_DEX_S 占位行）和 `get_type_name`（`checker.cr:863-868`，反向的 TY 到名字映射）。两者未动，`jj diff` 可核。

### 1.1 计划行号变化（按内容定址）

| 站点 | 计划 | 提交前实测 | 变化 |
|---|---|---|---|
| A `res_type_node` | `:732-744` | `:736-748` | +4 |
| B `res_call_type` | `:1382-1392` | `:1386-1396` | +4 |
| S1、S2 hotpatch | `:1055-1061`、`:1080-1085` | `:1058-1066`、`:1082-1090` | +3、+2 |
| S3 extern | `:1133-1140` | `:1138-1144` | +5 |
| S4 形参 | `:1671-1675` | `:1673-1680` | +2 |
| S5 返回 | `:1724-1730` | `:1726-1734` | +2 |
| S6 iface | `:2129-2134` | `:2148-2154` | +19 |

成因与任务 3、4、5 相同：侦查底座是起草时点的工作副本，`checker.cr` 现在 3422 行。

## 2. 判据（命令和结果，逐条）

| # | 判据 | 命令 | 结果 |
|---|---|---|---|
| 1 | 自举构建 | `nice -n 19 python3 build_selfhost_native.py` | rc=0；3 次 `[GUARD] … build log clean (error[ = 0, undefined = 0)`；`=== BUILD SUCCESS ===`（corec、corearch、corelsp） |
| 2 | 自测用例表 | `nice -n 19 ./build/corec selftest-types` | 212/212，零 FAIL，rc=0。基线 201，增加 11 例；用例数已同步到 `run.sh:71` |
| 3 | ELF 逐字节 | `clean-cache`，然后 `build tests/suite/ptr_arith.cr --static -o /tmp/pa_p2b6_final`，再 `sha256sum` | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`，IDENTICAL，等于计划定值。改动后复测 2 次，突变复位后再测 1 次 |
| 4a | 语料面零变化（32 档） | 旧二进制配新源，对比新二进制配新源；逐档 `check` 的 stdout、stderr、rc 写入磁盘（`/tmp/p2b6_run.py`） | `diff -r` 逐字节全空。rc 分布为 20×0、12×1，与任务 3、5 相同 |
| 4b | 编译器自源 | ① 旧配新对比新配新；② 旧配旧，使用 `/tmp/p2b6_oldtree`，由 `jj file show -r @-` 复原 3 个改动文件 | ① `cmp` IDENTICAL，隔离了输入增长；② 与“新配新”的差异恰好是 2 条既有 TF01 的行号加 10，从 `9373/9488` 变为 `9383/9498`，与 `checker.cr` 净增 10 行逐字吻合。零新增、零消失诊断 |
| 4c | `.ccr` 逐字节（冷缓存 4 档） | 逐档 `clean-cache`，然后 `ccr`，再 sha256，旧新各一轮 | 4/4 IDENTICAL：ptr_arith `ecd7a9df…d29d`、at_test_struct `891377232b…8f08`、generics_test `35cf0f26…5d23`、dyn_test `dfb82d2b…626f`，与任务 1 至 5 的报告逐字相同，跨批可比 |
| 4d | 影子通道（32 档，冷缓存） | 逐档 `check FILE --type-shadow --type-shadow-dump`，比较摘要、站点直方图和 dump 全文 | 旧新逐字节全同。聚合为 `decisions=2826 agree=2826 old_stricter=0 old_looser=0 unknown=0 unknown_bridge=0 unknown_engine=0 unknown_engine_uncovered=0 unknown_engine_budget=0 replace_bridge=0 replace_unknown=0`。直方图为 `assign-node=1816 fn-body-ret=778 if-branch=222 struct-field-type=4 array-elem-type=4 generic-apply-base=2`，其余 4 个站点为 0，与任务 5 逐项相同 |
| 5 | 五套回归 | `test_compile`、`test_purity`、`test_ccr_v7`、`test_type_engine`、`test_iface_ops` | PASS、PASS、27/27、PASS、76/76 |
| 6 | 加宽回归 | `test_impl`、`test_borrow`、`test_pointer_safety`、`test_params_limit`、`test_tuple_slots`、`test_agg_slots`、`test_agg_checks`、`test_slice_bounds`、`test_named_dedup`、`test_interp_parity`、`test_cache_identity`、`test_nested_fn`、`test_lsp` | 全部通过：7/7、7/7、PASS、5/5、14/14、13/13、20/20、7/7、PASS、23/23、5/5、17/17、ALL PASS（10） |
| 7 | 自举链 | `CI_JOB_NAME=full-bootstrap bash src/ci/run.sh` | rc=0；`cmp /tmp/corec2 /tmp/corec3` IDENTICAL（`c201916d…a7d9`）；`--help` rc=1，符合脚本口径 |
| 8 | 冒烟 | `nice -n 19 ./build/corec run 'fn main()->int{return 42;}'` | rc=42 |
| 9 | 现状探针（先行） | `/tmp/p2b6_probe{1,2,3,4}.py`，A、B、C、F、R 五组共 52 例，旧新各一轮 | 逐字节相同，4/4 档。事实见第 4 节 |
| 10 | 插桩可达性探针 | 临时 build，在 `check_error` 打点，见第 5 节；跑探针和语料，然后撤销并重建 | NEVER 格命中：`x : never = 1` 在 `res_type_node` 命中 1 次；调用 `fn g[T](a:T)->never` 在 `res_call_type` 命中 1 次；32 档语料加自源为 0 次，真实源码没有 `never` 类型。撤销后 `grep -c PROBE6` 为 0，重建二进制与插桩前逐字节相同 |
| 11 | 突变控制（判别力实证） | 三层，逐条复位 | 见第 7 节：selftest 和行为两层都失败，撤销后 `build/corec` sha 复原（`8f69e346…858b`） |
| 12 | 提交边界 | `jj commit -m … <5 路径>` | `jj diff --name-only @--..@-` 恰好 5 个路径（240 insertions、53 deletions）。`tests/suite/*.cr.{out,rc}` 共 64 个他人 scratch 未入库，提交内计数为 0 |

## 3. 站点台账（逐站点说明合一或保留差异，并给出依据）

口径承接任务 4、5：“合一”指判定改经单表；“域差异保留”指表给出值、站点给出域，域是改动前链覆盖的 TY 码集合，域差异不得被“表加尾回落”一刀切抹平。

| # | 站点（提交后行号） | 改动前域（覆盖的 TY 码） | 处置 | 依据或差异的载荷 |
|---|---|---|---|---|
| A | `res_type_node` 基型 `:736-746` | {INT,DEX,BOOL,STRING,UNIT,NEVER,CHAR} 并上 {7} | 合一，表加 `-1 → TI_UNIT` 尾回落 | 域等于表全域；7 码格可达，探针 B2 中 `x : dyn = 5; x.nosuch()` 产生 N08，走 `res_type_node` 的 7 格 |
| B | `res_call_type` 基型 `:1393-1401` | {INT,DEX,BOOL,STRING,UNIT,CHAR,7}，没有 NEVER | 合一并显式保留差异（`|| tv == TY_NEVER`） | NEVER 可达，第 5 节的插桩命中，加上 `@raw_int` 行为面的 TF07。因此保留 unit 现状，不不报错地合一 |
| S1 | hotpatch 和普通注册 `:1057-1069` | {INT,DEX,BOOL,STRING,UNIT} | 表加域门，排除 CHAR、NEVER、7 | F1：`fn f() -> char` 的符号类型为 unit，main 的 `-> char` 报 TF01@2。突变 M2 放宽本域后该诊断消失，说明域有载荷 |
| S2 | hotpatch 首版 `:1083-1095` | 同 S1 | 同 S1 | 与 S1 逐字同域，属于同族站点对 |
| S3 | extern 注册 `:1141-1151` | {INT,DEX,BOOL,STRING,UNIT,CHAR} | 表加域门，排除 NEVER、7 | F4 同形对照：`extern fn f() -> char` 的符号类型为 char，rc=0；F1 的非 extern 同形结果为 unit。两者结果不同，说明域差异有载荷。注：F4 单独看是弱判据，突变 M3 下两侧同步移动仍然 rc=0；载荷性由 M2 的 S1 侧直接证明 |
| S4 | `check_func` 形参 `:1677-1689` | {INT,DEX,BOOL,STRING,CHAR}，缺 UNIT、NEVER、7 | 表加域门，排除 NEVER、7 | F7：`fn f(b: never)` 的形参符号类型为 unit，`@raw_int(b)` 产生 TF07@1。UNIT 缺失不是载荷，因为表值就是初值 TI_UNIT |
| S5 | `check_func` 返回 `:1729-1741` | {INT,DEX,BOOL,STRING,UNIT,CHAR,NEVER}，缺 7 | 表加域门，排除 7 | F10：`fn f() -> never` 的体检查使用 never，TF01@1；F11：`-> dyn` 落 unit 后备 |
| S6 | iface 返回 `:2154-2170` | {INT,DEX,BOOL,STRING,UNIT,CHAR}，缺 NEVER、7 | 表加域门，排除 NEVER、7，并把撞车比较显式化 | F12、F13、F14：iface 约束方法调用的三个变体，`-> int` rc=0，`-> never` 在调用点得到 unit 并报 TF07@4，`-> char` rc=0。现状中 `iface_ret2 == TY_*` 与值域 TI_* 的数值撞车，按语义改写 |

汇总：2 处合一定义，6 处表值合一，全部 8 处保留各自的域。收紧清单为空，没有“旧接受、新拒绝”的条目。放宽面为空，有四面对拍、三层突变和 52 例探针为证。

## 4. 现状行为事实表（探针先行，52 例；计划侦查第 6 节的未测项，本任务实测确证）

探针和落盘：`/tmp/p2b6_probe{1,2,3,4}.py`，基线输出 `/tmp/p2b6_probe*_base.txt`，新版 `*_new.txt`，两侧逐字节相同。

| 面 | 探针 | 现状（改动前） | 说明 |
|---|---|---|---|
| NEVER，两表差异格 | A8、F13、B6：`fn g[T](a:T)->never` 调用位点加 `@raw_int(x)` | TF07，x 为 unit | `res_call_type` 没有 NEVER 格，落尾 TI_UNIT。对照 A9（`-> int`）rc=0，证明 `:1615` 路径确实在判定，否则符号表回落也会给 unit，必然报 TF07 |
| NEVER，参数位点 | A11、F7 | A11 rc=0；F7 形参类型为 unit | `:1554` 的形参和 `:1615` 的返回同格 |
| NEVER，类型位点 | 插桩：`x : never = 1` | `res_type_node` 命中该格，得到 TI_NEVER | 与 `res_call_type` 的 unit 形成唯一差异 |
| DYN 码 7 | R1、B2、A10、B3 | `x : dyn = 5` rc=0；`.nosuch()` 产生 N08 | 计划勘误：计划称“parser 从不产 `type_val=7`”，实测 `parser.cr:98` 对 `dyn` 类型名正产 `TY_DYN` 值域码 7，该格可达，并且是 N08 路径的依赖 |
| CHAR 跨站差异 | F1 对比 F4 | 非 extern 得到 unit，报 TF01@2；extern 得到 char，rc=0 | 同形不同站点，说明域差异有载荷 |
| 其它字符位面 | R2、F8、F9、F14 | 各 rc=0 | 见各站点注 |

## 5. `never` 单元格探针（计划步骤 2 的绑定项，实测为可达）

三层证据必须并列，缺一不可。

1. 行为面，使用未改动的编译器：`fn g[T](a: T) -> never { loop { } }` 加 `fn main() -> int { x := g(1); y := @raw_int(x); return 0; }`，产生 `TF01@1`（函数体自身）和 `TF07@2`（`@raw_int requires a dex (or int) expression`）。`@raw_int` 接受 {dex,int,never}，TF07 存在说明调用结果不是 never，因此该格产出 unit。
2. 路径执行面：对照 A9，同形但 `-> int`，rc=0。如果 `:1615` 未执行而走符号表回落，泛型函数注册的 `rt_ti` 就是 TI_UNIT，`@raw_int` 也会报 TF07。A9 没有诊断，说明 `:1615` 确实执行并映射出 TI_INT。
3. 插桩面：临时 build 在该格打点（`check_error(…, "PROBE6_CALL_NEVER", …)`），上述程序命中 1 次；`x : never = 1` 在 `res_type_node` 侧命中 1 次；32 档语料加 `check src/compiler` 命中 0 次，真实源码没有 `never` 类型位。探针 build 的 sha 为 `844c5e0d…`。撤销后 `grep -c PROBE6` 为 0，重建二进制与插桩前逐字节相同。

裁决按计划步骤 2 的分支：可达，因此保留现状。在 `res_call_type` 处显式写 `|| tv == TY_NEVER`（`checker.cr:1398` 加注记），并把“`never` 形参和返回在调用位点被当作 unit，而类型位点是 never”登记为 P3 待裁决项。这属于语义争议，按 spec 第 4 节裁决 6 停下上报，本批不动。

## 6. 偏差、计划勘误和需要 lead 过目的地方

### 6.1 `TY_DEX_S` 到 `TI_DEX_S` 未入表（计划 Interfaces 段列了该格）

- 计划注原文是：“`TY_DEX_S→TI_DEX_S`（占位行，仅 init_types 面用；不属两表并集）”，计划也明确记录 `init_types` 的位置公理“不入合并仅登记”。因此没有调用点需要该格。
- 实测：全 `src/` 内 `TY_DEX_S` 只出现在 `checker.cr:253` 的 init_types 位置公理、`ast.cr` 的定义和注释中。`parser.cr` 的类型名表只产 {int,dex,bool,string,char,never,dyn} 七个码，没有任何 parser 或铸点写 `type_val = 8`。
- 不加的理由：如果入表，两处基型分支对 `tv = 8` 会返回 `TI_DEX_S`(8)，而改动前是 TI_UNIT，造成函数级行为变化。selftest 的 `t6.dex_s_oob_unit` 正是把“码 8 到 TI_UNIT”固定住的用例。保语义口径下，该格只能“入表并在每个调用点再加一条排除”，净收益为负，因此选择不入表，并在表头注记理由。
- 如果 lead 要求严格照计划执行，一行即可加回，即 `if ty == TY_DEX_S { return TI_DEX_S; }`，代价是 8 处站点各加一条 `!= TI_DEX_S` 排除，或者接受上述函数级差异。

### 6.2 计划步骤 3 的字面写法“表加尾部落 TI_UNIT”不能做到零行为变化（本任务最大发现）

计划写的是“6 处逐处改调 `ty_code_to_ti`，逐处保留各自的尾部回落”。但 6 处链的域，也就是覆盖的码集合，各不相同：S1 和 S2 缺 CHAR，S3 和 S4 缺 NEVER，S5 缺 7，S6 缺 NEVER 和 7。域外码落到尾回落属于可观测行为。

- 突变 M2，把 S1 的域放宽到包含 CHAR，等于一刀切写法的效果：`fn f() -> char { return 'a'; }` 加 `fn main() -> char { x := f(); return x; }` 从 TF01@2、rc=1 变成 rc=0，不报错地改变了判定。
- 因此本报告按“单表给值，站点给域”实施。站点用 `v != TI_CHAR/TI_NEVER/TI_DYN` 之类的显式排除来表达自己的域，排除项恰好是现状链未覆盖的码，而且都是表内会造成差异的码。UNIT 缺失是 no-op，因为表值就是初值 TI_UNIT。等价性论证由逐格转录、每站点注记和行为用例组成，见第 2 节判据 5。

### 6.3 计划勘误：“parser 从不产 type_val=7”不成立

计划任务 6 写“下行字面量节点不受影响，parser 从不产 `type_val=7`”。实测 `parser.cr:98`：`else if lex == "dyn" { res = alloc_node(0, 0, 0, 0, 0, TI_DYN, 0, line, col); }`，`dyn` 类型名正产码 7，值域常量名写作 TI_DYN，与 TY_GENERIC_PARAM 同值。后果是该格在 `res_type_node` 侧可达且有载荷，`x : dyn = 5` 的 N08 判据依赖它。本批未改该格语义，现状写法和注释原样保留。勘误仅供后续批次参考，例如 P4、P5 的命名空间分家。

### 6.4 证据缺口（如实登记）

1. S4、S6 的 CHAR 格没有判别性探针。`type_compat_strict` 对 char 比较宽松，`y : char = b` 和 `y : char = x` 不能区分 char 与 unit，F8、F9、F14 全部 rc=0。因此这两站的 CHAR 包含性靠逐格转录，即改动前的链包含 `TY_CHAR`，而不是行为对照。S3 的 CHAR 载荷性由 M2 在 S1 侧间接证明。
2. S6 面，即泛型约束方法分派，在现状语料和示例中零声明。全仓 `.cr` 没有 `interface` 声明，`impl` 只有 inherent 形式。本任务自造了三个脚手架 F12、F13、F14 才使该站可达，生产路径的覆盖面仍然小。
3. `res_call_type` 的 7 码格，即 dyn，可达性没有判别探针。dyn 方法的 N08 依赖符号的 dyn 位图，由 `EXPR_LET` 写入，而 `x := g(1)` 的推断型不建位图，实测 `x : dyn = 5; y := x; y.nosuch()` 为 0 诊断。因此该格只能靠逐格转录和表侧用例 `t6.dyn_cell_both` 固定。

### 6.5 其它

1. 不做 `CIR_CACHE_VER` 升级。本批不改 IR 发射面，ELF、`.ccr`、影子都逐字节相同，缓存内容不可能不同。沿用任务 4、5 的结论：TODO #5 家族只在发射面变更时升级版本。
2. 计划文件未改（`docs/superpowers/plans/…`）。plan-p2b 仍活跃，本报告第 1.1 节的变化表可以作为回填输入。
3. `tests/suite/*.cr.{out,rc}` 共 64 个 scratch，是他人产物，本批未删除、未入库，路径限定可核。
4. 性能面如实登记：单表是至多 8 次比较的常量分派，站点多在注册和声明路径，不在热路径。字面量、索引等热路径不受影响，本任务未触碰。编译耗时回归未见，全套回归和影子 32 档的耗时在同一量级。

## 7. 突变控制（判别力实证；三层，逐条复位，二进制逐字节复原）

| 突变 | 内容（一行，带 `PROBE-M*` 标记） | selftest | 行为回归 | 结论 |
|---|---|---|---|---|
| M1 | 删除 `res_call_type` 的 NEVER 门，等于错误地统一两张表 | 211/212：`FAIL t6.never_cell_diff: got 0 want 1` | 75/76：`FAIL t6_C_never_call_unit`，TF07 消失，调用位点变成 never | 差异格判据和行为面同时有判别力，门确实被读取 |
| M2 | S1 的域放宽到包含 CHAR，等于计划的字面一刀切写法 | 212/212，不失败，因为站点不在表侧 | 75/76：`FAIL t6_S1_char_unit`，rc=0，TF01 消失 | 行为层不可省，一刀切写法确实改变判定 |
| M3 | 表 `TY_CHAR → TI_UNIT` 翻转 | 209/212：`t6.ty_code_tail`、`t6.R_codes`、`t6.C_codes` | 73/76：`t6_R_char_ret`、`t6_S1_char_unit`（行号位移）、`t6_S6_iface_char_covered` | 表侧和行为侧双层都有判别力 |

复位证据：`grep -c "PROBE-M"` 在两个文件中都为 0，重建后 `build/corec` 的 sha 为 `8f69e3469721a876c5e397c563487a355d43662fc0fff460931f05300db8858b`，与突变前逐字节相同。selftest 212/212，iface_ops 76/76，ELF 定值复原，语料、影子、`.ccr`、自源四面对拍全空。

纪律说明：三个探针都是本 agent 自写自撤的临时改动，不是还原既有工作。先例是任务 2、3、4、5 的同类钳位实验。

## 8. 未覆盖面和交接

1. P3 待裁决项，新增：`never` 在调用位点，即 `res_call_type` 的形参和返回两条路径，现状为 unit；而类型位点 `res_type_node` 为 never。语义上“never 形参”应如何参与调用位点类型，属于 P3 语义裁决。本批按 spec 第 4 节裁决 6 停下上报，不顺便修改。
2. P4、P5 的命名空间分家：码 7 的 TY_GENERIC_PARAM 与 TI_DYN 撞车格，本批原样保留并显式注记；`TY_DEX_S` 的归位见第 6.1 节。
3. 站点域的表达形态，属于可选项，不是缺陷：6 处站点用“表值加排除项”表达域。如果 P3 收紧时想统一为“站点域位集”形态，参照 `iface_*_ops` 的位集先例，本批注记已逐站给出域集合，可以直接转录。
4. `sh_*_ak_legacy`（任务 2 的对照物）和 P5 删除项不变，本批未动。
5. 提交链：任务 2 `31143cd0`，任务 3 `6d2790cd`，任务 4 `a99ee825`，任务 5 `7145eea5`，任务 6 `30545da7`，即本报告提交。

## 9. 证据命令速查（可复核）

```bash
# 判据 1/2
nice -n 19 python3 build_selfhost_native.py            # rc=0 + 3 守卫 clean
nice -n 19 ./build/corec selftest-types | tail -1      # 212/212
# 判据 3（cwd = 仓库根）
nice -n 19 ./build/corec clean-cache && nice -n 19 ./build/corec build tests/suite/ptr_arith.cr -o /tmp/x --static && sha256sum /tmp/x
# 判据 4（同源双编译器对拍；$1=二进制 $2=落盘目录）
nice -n 19 python3 /tmp/p2b6_run.py /tmp/p2b6_base_bin/corec /tmp/p2b6_base
nice -n 19 python3 /tmp/p2b6_run.py ./build/corec              /tmp/p2b6_final2
diff -r /tmp/p2b6_base/corpus /tmp/p2b6_final2/corpus   # 空
diff -r /tmp/p2b6_base/shadow /tmp/p2b6_final2/shadow   # 空
diff -r /tmp/p2b6_base/ccr    /tmp/p2b6_final2/ccr      # 空
cmp    /tmp/p2b6_base/compiler.txt /tmp/p2b6_final2/compiler.txt   # IDENTICAL
# 旧×旧（@- 源复原）→ 与新×新只差 2 条 TF01 行号 +10
cd /tmp/p2b6_oldtree && nice -n 19 /tmp/p2b6_base_bin/corec check src/compiler >| /tmp/p2b6_oldxold.txt
# 判据 5/6/7/8
for t in test_compile test_purity test_ccr_v7 test_type_engine test_iface_ops; do nice -n 19 python3 tests/selfhost/$t.py | tail -1; done
env CI_JOB_NAME=full-bootstrap nice -n 19 bash src/ci/run.sh
nice -n 19 ./build/corec run 'fn main()->int{return 42;}'    # rc=42
# 现状探针（改动前后 52 例逐字节同）
nice -n 19 python3 /tmp/p2b6_probe2.py /tmp/p2b6_base_bin/corec >| /tmp/p2b6_probe2_base.txt
nice -n 19 python3 /tmp/p2b6_probe2.py ./build/corec           >| /tmp/p2b6_probe2_new.txt
```

基线取值口径，如实声明：ELF、`.ccr`、语料、影子、自源诊断的基线全部由改动前 `build/corec`（任务 5 完成态）的冻结拷贝 `/tmp/p2b6_base_bin/` 在同一构造路径加 clean-cache 下实测取得。`.ccr` 的四个哈希另与任务 1 至 5 的报告值逐字一致，跨批可比。构建确定性：同源重建 4 次均得到 `c22ff720…a0d54`，等于任务 5 的报告值；改动后得到 `8f69e346…858b`。
