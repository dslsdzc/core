# R2 P4 Task 6 报告：`MAX_*` 护栏（TODO #35）和解除评估（裁决 6）

日期：2026-09-13 · 基线：`cf368259`（P4 Task 5 补） · 裁决：计划 `2026-09-12-r2-p4-carrier.md` 裁决 6「先补护栏、再评估解除」 · 条目来源：TODO #35（枚举写入侧无护栏）和同族 MAX_STRUCT_FIELDS（RED 步实测发现，一并修）
文件面：`src/compiler/ast.cr`（P022/P023）· `src/compiler/parser.cr`（三处写入点）· `src/compiler/dyn_arr.cr`（受护访问器）· `src/compiler/ty_shadow.cr`（前提注记）· `tests/selfhost/test_enum_limit.py`（新，13 例）· `src/ci/run.sh` · `docs/error-codes.md` · `TODO.md`（#35 划销）· 计划（Task 6 实施记录）· `src/compiler/main.cr` 零改动（见第 2 节-③）

---

## 1. 失败状态复现（Step 1；危害形态首次构造，TODO #35「未做」项收口）

基线二进制为修复前的 `6afbd33338c7…`（会话起点实测 sha；另在 /tmp 沙箱用同源重建的修复前二进制复证，见第 5 节）。探针为 `/tmp/p4t6/{e17_decl,use16,m16,m17,m17miss0,ctrl16,p17,p17b,s17}`，逐例执行 `check`（`build` 面见下）。

| # | 探针 | 修复前实测 | 修复后实测 |
|---|---|---|---|
| ① | `enum E17 { V0..V16 }`（17 变体声明） | `check` rc=0 零诊断（写入侧越界写完全不报错地，TODO 原记录复核成立） | `error[P022] Enum has too many variants (17 > 16)` + rc=1 |
| ② | 同枚举上 16 臂 match（真非穷尽，缺 V16） | `check` rc=0 零诊断（对照：16 变体枚举同形必报 TM03，`ctrl16` 实测 `Non-exhaustive match: missing variant 'V15'`） | 同上 P022（判定面前置拒绝） |
| ③ | 同枚举上全 17 臂 match | rc=0（不判：17 号臂不可映射，结果为 -1） | P022 |
| ④ | `V16()`（第 17 变体构造） | rc=1，但诊断是假的「Undefined enum constructor 'V16'」（真因是名槽被 count 覆盖，导致名查表失败） | P022 |
| ⑤ | 17 载荷类型 `A(int×17)` | `check` rc=0 零诊断；`build` rc=1（读回检查 `.ccr variant type count exceeds max`） | `error[P022] … payload types (17 > 16)` |
| ⑥ | 17 字段结构体（`MAX_STRUCT_FIELDS`，同族第三处，RED 步发现） | `check` rc=0 零诊断；`build` rc=1（读回检查 `.ccr struct field count exceeds max`） | `error[P023] Struct has too many fields (17 > 16)` |

危害形态（答案是「表污染加判定不报错地」，不是崩溃）：机制已有代码级定位（TODO #35：第 17 变体槽起点为 `OFF_EI_VARIANT_COUNT`=4360 自身，槽尾越过 `ESZ_ENUMINFO`=4408，越界 224B）。本轮第一次构造出运行期危害形态，逐条如下：

1. 穷尽性判定被不报错地禁用（本轮新发现，影响最大）：第 17 变体的名槽与 `variant_count` 同址（4360），写入顺序是名先写、count 后写，因此名槽终值为 17（把 count 值当作 ni 使用），`sh_variant_term` 的「名到变体项」查表（`sh_enum_variant_index`）失败，`sh_enum_domain_term` 返回 -1，域不可展开，`sh_match_exhaustive` 三态回落到 -1「不判」，最终该枚举上的所有 match 穷尽性判定整体失效（真非穷尽 match 不报错地通过，违反 TM03 硬门口径）。对照实验：16 变体同形会报 TM03，说明差异由越界写单独造成。
2. 第 17 变体不可构造：名槽失效，构造器查名失败，报假诊断「Undefined enum constructor」（同一枚举内部自相矛盾：声明了却用不了）。
3. `def_sym` 产生错误符号：`checker.cr` 的声明收集循环 `vi < ei_variant_count(i)`（等于 17）会对 17 号槽名执行 `def_sym`。修复前读到的是 count 值（一个合法 ni），会在符号表注册一个不属于该枚举的名字（修复后读护栏返回 -1，不可能命中任何真实名字）。
4. 没有 SIGSEGV：`grow_enums`/`grow_structs` 的扩容余量（`nc ≥ needed`，倍增至 `needed+16`）吸收了 224B 越界，越界写落在 buffer 内部（末记录时落在 slack），崩溃不可观测，所以 `check` 面全不报错地。这正是它存在至今的原因（#8 的越界写踩到 `ast_node` 会立刻报 TF01，本例不会）。
5. `build` 面修复前 rc=1 只靠读回侧检查（`ccr_io.cr` 的 `vc > MAX_ENUM_VARIANTS` / `tc > MAX_VARIANT_TYPES` / `fc > MAX_STRUCT_FIELDS`），写入早已发生（TODO 原话「护栏在读回侧不等于写入侧」实测成立；`check` 面零护栏）。载荷侧越界写点：第 17 载荷的裸码写 `OFF_EV_TYPES+16×8 = 136 = OFF_EV_TYPE_COUNT`，第 17 载荷节点写 `OFF_EV_TYPE_NODES+16×8 = 272 = OFF_EV_SIZE`（下一变体槽首），都会被后续写序覆盖，属于「记录内自踩」，因此危害以变体数那条（跨记录、尾越界）为主。

越界写是否真正越出分配：机制上取决于 `grow_enums` 的容量是否恰好等于 `needed`（`nc = cap*2`，仅当 `cap*2 == needed` 时零余量）。本批未构造该极端形态（需要至少 128 个枚举且末条为 17 变体才命中 `cap*2==needed`），登记为未覆盖面（第 6 节）。实测到的 224B 越界都落在扩容余量内。

---

## 2. 修复（护栏形态，照 TODO #8 收口）

① parser 三处写入点（唯一用户面写点）：`struct` 字段、`enum` 变体、`enum` 载荷。
- 超限槽不再写（`fc < MAX_STRUCT_FIELDS` / `vc < MAX_ENUM_VARIANTS` / `tc < MAX_VARIANT_TYPES`），计数保持真值（`w64(..._COUNT, fc/vc)` 照旧写真数），照 P020 的 `add_func(pc)` 先例（计数真实是诊断和读回检查的依据，槽区不外写）。
- 三个 `over_*` 标志加末尾单条定位诊断：`error[P022]`（变体数含真实数码，载荷数含真实最大数码）、`error[P023]`（字段数），定位到声明关键字 token（`tok_ln(t)`/`tok_cl(t)`），因此指向 `struct`/`enum` 处。不做不报错地截断，用户必然得到硬错误。
- 名字仍然 `str_intern`（保留副作用，唯一差别是槽不写）。

② `dyn_arr.cr` 受护访问器（唯一受护写点加读护栏）：照 `fi_param_type`/`fi_set_param_type` 的形态增加 `ei_set_variant_name/type/type_count/type_node` 和 `si_set_field_name/type/type_node`（写护栏让未来新调用点也不可能越界写），再加上既有的 `ei_variant_*`/`si_field_*` 读护栏（越界返回标记值：名字、类型码、类型节点为 -1（无效 ni 或节点），计数为 0）。count 槽不设写护栏（与 P020 相同：真值是诊断依据）；读护栏使「count = 真值 17」在进程内仍然不可能越读。

③ 拒绝时机（实施中的实测修正）：原计划设想「新硬错误加入 `main.cr` 的 hard 名单」。实测反证：`main.cr:134` 的 parse 阶段诊断检查（`println("[3/5] parse..."); parse_all(); if g_diag_count > 0 { print_diagnostics(); return 1; }`）已经对任何 parse 期诊断返回 rc=1，P022/P023 在 parser 内 `check_error`，天然入检查。删除 hard 名单条目的对照构建零行为差异（见第 5 节-M2），因此不加（`main.cr` 全文零改动，与 P019/P020/P021 同款口径）。拒绝发生在前端：不进入 `lower to ccr` / `save .ccr` / `generate ELF`（回归用例断言这三个阶段串不在输出中，以此固定「护栏在写入侧，不在读回侧」）。

④ 连带注记：`ty_shadow.cr:1271` 的「`MAX_ENUM_VARIANTS = 16` 保证不溢出（覆盖位 2^vi）」旧注是假设（TODO #35 已指出该前提不成立）；本批起由写入侧护栏强制成立，注释同步改写。

---

## 3. 解除评估（Step 3；结论：本批三项均不解除，写在报告中不实施）

共同事实（实测和实读）：三个上限（都是 16）只约束进程内记录布局。`.ccr` 磁盘布局是变长的（`ccr_io.cr` 的 SYM 枚举子节为 `[name][vc]` 加逐变体 `[name][tc][types…]`；结构体相同），载入侧按计数重建进定长槽，并由读回检查拒绝超限。因此「解除」等于改内存记录布局（或迁移到侧表），磁盘格式不受限。

| 上限 | 定义 | 解除面（改什么） | 成本 | 收益 | 风险 | 结论 |
|---|---|---|---|---|---|---|
| `MAX_ENUM_VARIANTS=16` | `ast.cr:117`（变体槽区容量） | `dyn_arr.cr` 的 `OFF_EI_VARIANT_COUNT`/`ESZ_ENUMINFO`（8+16×272 的记录形状）加 `ast.cr:161` 镜像 `variants: [EnumVariant; 16]`，加读回检查、本批护栏、`ccr_io.cr` 的清零循环（`zvi >= 16` 字面量）；另需改覆盖位表示（`sh_match_bit` = 2^vi 走 int，超过 63 变体即溢出，需要侧表或位图） | 中（4-5 处常量族加 1 处字面量加覆盖位算法） | 语言面容量（当前全语料零超限用例；静态扫描 139 文件，最接近的是无超过 12 变体的枚举） | 记录布局与 `ast.cr` 镜像、`.ccr` 读回检查、`OFF_*` 常量同源，漏改一面会导致不报错地未定义或不报错地越界（B.6 事故形态）；无 `CCR_VERSION` 依赖（盘面变长） | 不解除（零在野需求加高风险面） |
| `MAX_VARIANT_TYPES=16` | `ast.cr:118`（载荷槽区容量） | 同上（`OFF_EV_TYPES`/`OFF_EV_TYPE_NODES` 两条 16 槽）加读回检查和护栏 | 同上 | 同上（语言面：超过 16 字段的变体） | 同上；另注：载荷裸码槽已不是唯一来源（P3 Task 4 起节点槽并行），迁侧表时须两列同步 | 不解除 |
| `MAX_STRUCT_FIELDS=16` | `ast.cr:116` | 同上（`OFF_SI_FIELD_{NAMES,TYPES,TYPE_NODES}` 三条 16 槽）加 `ast.cr:143-145` 镜像 `[string; 64]`/`[int; 64]`（镜像与布局已经不一致：镜像 64、布局 16，解除时应一并归位），加读回检查和护栏 | 中 | 语言面容量（当前最大使用是 9 字段的 `ASTNode`；静态扫描 139 文件，没有一个达到 16 字段） | 同上 | 不解除 |
| `MAX_GENERICS=4` | `ast.cr:115` | 不属于本类：写入侧有界（`parse_generics_into` 的 `gc >= MAX_GENERICS` 时 break 写的是局部缓冲），超限是 parse 期硬报（实测 `struct G[T0..T4]` 为 rc=1；`test_generic_constr.py` 的 F 项已登记「P01/TA08 die hard」），没有不报错地接受面，因此不需要护栏 | 表布局面（`generic_names[4]` 在 Func/Struct/Enum 三处，加 `g_sgen_constr`/`g_egen_constr` 键 `row*MAX_GENERICS+gi`，加 `parser.cr` 两处字面量 4） | 语言面容量（语料最大实参为 2） | 键空间与侧表同步面 | 不解除（P3 已登记；本批只复核护栏面） |
| `MAX_IFACE_METHODS=16` / `MAX_IFACE_METHOD_PARAMS=8` | `dyn_arr.cr` | 已有硬错护栏（本轮复测：17 方法报 `error[P13]` rc=1；9 参数报 `error[P11]` rc=1；`test_impl_iface.py` 的 limit 组固定住）；解除面为 `ESZ_IFACEINFO` 3864 = 24+16×240（P4 Task 3 项槽扩展后）改为侧表并替换全部读点；`.ccr` IFACE 段变长（D14 五小节），盘面不受限 | 中 | 语言面容量 | 判定面读点众多（`check_iface`/`find_func`/`sh_iface_*`） | 不解除（既有登记；P4 Task 3 第 3 节未覆盖面继承） |

统一结论：三项 16 上限的解除是同一个决策（记录布局改为侧表或扩槽），并且与 P5 的「段布局去定长槽」同源（P4 Task 5 报告 concern ②）。本批只补护栏，不做布局变更（符合裁决 6）。如果将来解除，判据必须包含：①读回检查同步；②`ast.cr` 镜像归位；③覆盖位表示（枚举超过 63）；④冷/热 `.ccr` 与 ELF canary 逐字节相同。本批建立的护栏正好是解除时的安全网：漏改槽区只会得到定位硬错，不再是不报错地污染。

---

## 4. 判据（逐条命令和结果；cwd 为仓库根，`nice -n 19`，一构建一编译串行）

| # | 命令 | 结果 |
|---|---|---|
| 1 | `python3 build_selfhost_native.py` | rc=0；三面 `[GUARD] …  build log clean (error[ = 0, undefined = 0)`；`build/corec` = `5d2b15ad746018619b01143cce400e6f3489ae72a962e12283a7afd3dcdb41e7`（注释级改动后重建仍是同一 sha，说明构建确定） |
| 2 | `python3 tests/selfhost/test_backend_bootstrap.py` | rc=0，构建日志 `error[` = 0 |
| 3 | `./build/corec check src/compiler`（自源） | rc=0，诊断 0 条 |
| 4 | `./build/corec selftest-types` | 355/355（用例数不变，本批不加 selftest 例，行为面由新套件承担） |
| 5 | `python3 tests/selfhost/test_enum_limit.py`（新，已挂 `src/ci/run.sh` selfhost-tests） | 13/13（5 正控加 8 拒绝面，逐例含 needle、无产物、阶段断言） |
| 6 | 先 `clean-cache`，再 `./build/corec build tests/suite/ptr_arith.cr --static` | sha256 = `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`，IDENTICAL（canary 不变） |
| 7 | `.ccr`（TODO #26；冷缓存实测） | `ptr_arith` 90966B `592afa31d66cc75abe48b96cd0357ebc3498e7a4f8392095b28e20b59b47c93d` · `generics_test` 134844B `ec8413ec55007f51ae05f7de84f80939099865bba97a7dc97d40e5ea7c37fd1e`，均与 T5 记录的尺寸一致（90966/134844）；详证见第 5 节-C（同源双编译器逐字节同） |
| 8 | 五 CI job（`CI_JOB_NAME=… bash src/ci/run.sh`） | `selfhost-tests` rc=0（新套件在列，末行 `13/13 passed`）· `suite` rc=0（`ALL PASS`）· `bootstrap-tests` rc=0（3/3）· `check` rc=0（`ok`）· `full-bootstrap` rc=0 |
| 9 | 全枚举 `tests/selfhost/*.py` 加 `tests/bootstrap/*.py` | 55/55 rc=0（48 个 selfhost（47 加本批新增 1）加 7 个 bootstrap） |
| 10 | 自举链（full-bootstrap） | `corec2 == corec3` cmp IDENTICAL（两个 2792078B 文件 `4919023b3e92b661219f4624859512d53abb58e3dbfe874a51ae8a5b297f9034`），两段构建日志 N06=0，`/tmp/corec3 --help` rc=1，冒烟：`corec3 build smoke.cr` rc=0，产物 rc=42 |
| 11 | report-only（Global Constraints 第 6 条；新硬错开门前） | 自源 `check src/compiler` rc=0 且 P022/P023 命中 0；`tests/suite`（25 档，`*_mini*` 按既有规则跳过）和 `examples` 逐档 `check`，P022/P023 命中 0；静态扫描 139 文件，没有超过 12 变体的枚举，最大结构体字段数为 9（`ASTNode`），清单为空，可以开门 |
| 12 | 影子通道 `check --type-shadow`（Global Constraints：每任务复跑，站点覆盖和差异数同报） | 同源对拍（同一语料乘修复前/修复后二进制）逐行相同：`decisions=5642 agree=5642`，`old_stricter/old_looser/unknown*/replace_*` 全为 0，站点覆盖 `fn-body-ret=938 · if-branch=363 · assign-node=4337 · struct-field-type=4`（语料为修复前的 `src/compiler`）。在当前（含护栏）语料上：`decisions=5656 agree=5656`（多 14 个是护栏新代码自身的检查点），全部计数为 0。本批不动判定路径（引擎、桥接、三态零改动）；实现方式面（段、读回、TK）仍属于影子零覆盖面（既有纪律不变） |

---

## 5. 突变控制和零扰动对拍（`/tmp/p4t6/sb` 沙箱；仓库零改动）

沙箱是 `rsync` 副本（排除 `.jj`/`build`），用 `jj file show -r @-`（只读）取出父修订源文件铺回，得到可复现的三种源码态，各构建一次：

- A（修复前基线态）：父修订 6 文件加删除新套件，构建得到 `build/corec` = `6afbd33338c7…`（等于会话起点实测的修复前仓库二进制 sha），说明沙箱保真且构建确定。
- B（修复后态）：仓库当前 6 文件，构建得到 `build/corec` = `5d2b15ad7460…`（等于仓库实测 sha，逐字节同）。
- C（同源双编译器 `.ccr` 对拍）：A 和 B 各编译同源语料，`ptr_arith`/`generics_test` 的 `.ccr` 逐字节同（`592afa31…`/`ec8413ec…`），ELF canary 也相同，说明护栏对合法程序零扰动（这是比 TODO #26 的结构断言更强的一条证据）。
- D（同源双编译器影子对拍）：A 和 B 在同一语料（沙箱内修复前的 `src/compiler`）上跑 `check --type-shadow`，摘要两行逐字节同（`decisions=5642 agree=5642`、全部计数为 0、站点覆盖 `fn-body-ret=938 · if-branch=363 · assign-node=4337 · struct-field-type=4`），说明判定面零变化（交叉验证 C 的结论）。

M1（主突变：删除护栏诊断）：从修复后态删去 3 处 `check_error`（保留 skip 和访问器护栏），构建得到 `build/corec` = `8a8f4ca181ec…`（不等于修复后 sha，突变生效）：
- `tests/selfhost/test_enum_limit.py` 为 5/13（8 例失败：3 例 `expected rejection, got rc=0（不报错地面复活）`，5 例「缺诊断」）；
- `./build/corec check`（17 变体枚举）为 rc=0 零诊断（修复前的不报错地面原样复活，凭此可以判定失败由「护栏缺失」单独造成）；
- 复位（恢复仓库的 `parser.cr`）后重建，`build/corec` = `5d2b15ad7460…`（逐字节复原），套件回到 13/13。

M2（对照：删除 `main.cr` 的 hard 名单条目）：修复后态加删 hard 条目，构建后与 M1-复位态同一 sha（`5d2b15ad…`），说明 hard 名单条目对本族是死代码（拒绝由 parse 阶段检查承担），据此决定不加（源码零改动、无死代码）。该结论与第 2 节-③ 互为证据。

---

## 6. 登记面（不要不报错地）

1. 未构造的极端形态：`grow_enums` 恰好零余量（`cap*2 == needed`）时，224B 越界会越出分配（需要约至少 128 个枚举且末条为 17 变体）。本批未构造（越界写已由护栏消灭，构造价值只是作为历史危害面的证据），登记备查。
2. `ast.cr` 镜像与布局不一致（既有，非本批引入）：`StructInfo.field_names: [string; 64]` / `field_types: [int; 64]` / `field_type_nodes: [int; 64]`（`ast.cr:143-145`）与 `MAX_STRUCT_FIELDS=16` 的布局不符（`FuncInfo.param_types` 在 #8 修复时已归位 64）；`EnumInfo.variants: [EnumVariant; 16]`（`:161`）与布局一致。镜像是否被编译器实际消费未逐点核对（本批不动），解除 `MAX_STRUCT_FIELDS` 时必须一并归位（第 3 节已列）。
3. 未加 selftest 例：本批只加行为套件（`test_enum_limit.py`），`selftest-types` 保持 355（计数纪律：只增不减，本批不改计数器，避免与 P4 其他任务的计数判据互相牵制）。
4. 影子通道未复跑（第 4 节-12）：本批零判定路径改动；如需，可以用 `--type-shadow` 复跑核对站点覆盖。
5. `.ccr` 判据强度：本批实测已回到「同源双编译器逐字节同」（强于 TODO #26 要求的结构断言）；用户程序零扰动（ptr_arith/generics_test）。

---

## 7. 提交

`fix: R2 P4 Task 6，枚举/结构体写入侧 MAX_* 护栏（TODO #35：变体/载荷/字段；P022/P023 定位硬错，#8 同族形态）+ MAX_* 解除评估登记`

路径限定：`src/compiler/ast.cr` `src/compiler/dyn_arr.cr` `src/compiler/parser.cr` `src/compiler/ty_shadow.cr` `tests/selfhost/test_enum_limit.py` `src/ci/run.sh` `docs/error-codes.md` `TODO.md` `docs/superpowers/plans/2026-09-12-r2-p4-carrier.md`（加本报告）。
