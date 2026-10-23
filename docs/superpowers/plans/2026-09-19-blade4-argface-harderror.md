# `(1)` 批 4 与两句语言裁定：联合计划（纸面，未实施）

- 产出：`b8-e1`，2026-09-19
- 基线：`develop@origin` = `c1044645`（落盘时现查；引用一律用符号定位点，行号只作示例）
- 状态：纸面。本轮不改 `checker.cr` 行为、不碰 `ld.cr`（`plan-optdex` 的 B/C 迁移进行中）、不推。
- 本文件的两句裁定来自维护者（lead 转述，原话级），见 A。

---

## 0. 结论前置（失败标记：A 类的「排除」证不出来）

A 类（49 点）无法写出满足正反两条断言的检查式，它与真异型在类型面上逐字段同形，本仓也没有可用来区分的 handle 型。

| 来源 | 清单行（同一台二进制、同一格式） | 形状 |
|---|---|---|
| A 类（语料真样本，`tests/suite/conc_test.cr`） | `9917 523 23 0 3 0 sched_enqueue` | `p=3(string) ← a=0(int)` |
| 真缺陷（对照探针 `fn takes(s: string)` ← `n : int = 7`） | `9917 5 11 0 3 0 takes` | `p=3(string) ← a=0(int)` |

三型分类（实据）：
1. 45 点：实参 = `cur_g := sched_get_curg()` / `recv_wait := r64(ch, 48)`，因此普通 int 变量，AST 看不出 handle（`r64` 按 `-5` 是设计旁路、其 int 返回有契约）；
2. 4 点：`ch := go square(21)`，因此变量中介（`EXPR_GO` 的 int 先落变量再传 `chan_recv`），因此与 `#2026-09-19-4` 的 `await` 那条同型；
3. 无 `TI_HANDLE` 常量：`grep 'TI_HANDLE\|TI_CHAN\|TI_GOROUTINE' src/compiler/ast.cr` = 空（handle 就是 `string`，A₂ 定的模型）。

推理链：抑制 49 点的唯一可实现规则 = 「按 (callee, param) 列全」（`sched_enqueue(g)` · `chan_recv/chan_send/chan_close(ch)` · `g_free(g)`），因此该规则必然让「int 变量传给 `chan_recv`」不再报，因此反向断言按构造不可能存在。
并且 (3) 也退化：要「批 4 不覆盖 A 面」也需要一条抑制规则，因此同样回到 (2)。
因此唯一出路 = (1)：把 A 的产出侧真正改型，因此这正是维护者裁定一（A）。

---

## A 两句维护者裁定（原话级）与各自的性质

### 裁定一（新语言特性）

> `go f(x)` 的型 = 引入句柄类型 `Future<T>`（携带元素型；`await` 从它取值型）。

- 性质 = 新语言特性（不是修补）：新类型构造子 + `await` 取值型规则 + 引擎（`ty_shadow` / `type_terms` / 变型表）+ `res_call_type` 分支 + 语料。
- 连带待定：`chan_recv` / `chan_make` / `g_new` / `sched_go` 这一族要不要一起改成 `Future<T>` / `Chan<T>`，A₂ 当时把它们对齐成了 `string`（裁定原文：「(A)：语料/stdlib 向模型对齐（(C) handle 兼容明令禁止；(B) 改 `alloc` 模型亦否）」），因此那条对齐与本次裁定冲突，必须显式处理（第 7 节第 7 项，本计划最大未决点）。
- 因此批 4 推迟：前置从「三条」变为「三条 + 本特性的实现」。

#### 裁定一的追加裁定（2026-09-19，维护者原话级）：A₂ 的对齐作废，那一族一起改

> A₂ 对齐作废，那一族一起改。

A₂ 的裁定原文（PR #118 / `cc8f1b836669`，逐字保留、标记作废，本仓惯例：只增不删，会报错替换）：
> (A)：语料/stdlib 向模型对齐（(C) handle 兼容明令禁止；(B) 改 `alloc` 模型亦否）

因此作废（2026-09-19 维护者裁定）：(C)「handle 兼容明令禁止」不再成立，改法改为「引入携带元素型的句柄类型，那一族一起改」。
因此 A 面 49 点可全收（含那 45 点）；第 7 节第 7 项由「最大未决点」解封（见第 7.1 节/第 7.2 节/第 7.3 节）。

记录形态：A₂ 原文原文保留在上，作废标记与今日裁定附于其后，不是替换。

### 裁定二（改契约）

> `&x` 改判 `TYP_REF`（不是「调用点拒」）。

- 性质 = 改契约：`&x` 产出 `*int` 是文档化语义，编译器自己的用户可见诊断就这么写（`error[TA02]: Variable declared as &int, got *int`），因此按本仓约定必须单独立项。
- `#2026-09-19-1` 的状态随之变更：「定性待裁」到「已裁：改判 `REF`，待实施」（该条目即本裁定的实现方式）。
- 它独立可做，且消掉了 F 类那 2 点：改判后 `&x` 与 `&T` 同 kind，因此 F 的「REF 形参 ← PTR 实参」自然不再存在，因此 F 的临时排除不必写（第 2.2 节因此从「排除」改为「由裁定二消解」）。

---

## B 依赖序（含本代理意见）

结论：`&x` 改为 `TYP_REF` 先做；`Future<T>` 大而独立，可并行。（与 lead 倾向一致。）

支持理由（补充三条）：
1. 体量：裁定二 = 五层逐处 + 三处实现方式 + `(i)` 允许清单，自足且可在单个小批闭合；裁定一 = 新类型构造子 + 引擎 + 两处定型 + IR 槽 + 语料，量级大一个数量级。
2. 它消掉的不对称正是实参面校验要依赖的东西：F 类 2 点因改判自然消失（不必写临时排除），因此先做它，批 4 的未落环排除从两条减到一条。
3. 它解锁 `#2026-09-19-1` 的验收（该条已「待实施」）。

注意：本次的一条保留（不是反对排序，是同批必须处理的）：裁定二在安全面是「减少检查」，`region_check` 三处 + `provenance_verify` 一处只认 `TYP_PTR`，改判后对 `&x` 派生的值不再生效（不报错地，不会失败）。因此必须与裁定二同批补等价检查（或显式登记「该面覆盖率下降」），否则是用一次不报错地换一次不对称。

---

## C 对批 4 三条前置的影响 + 批 4 的位置

| # | 原前置 | 现状 |
|---|---|---|
| 1 | 清单跳 never（+ 三条标记值族 skip） | 仍成立（`#142` / `c1044645`） |
| 2 | 63 点逐类处置表 | 被替换：A 归裁定一 · F 归裁定二 · D 已修（`#140`）· E 已排除（`#142`），因此表只剩 B/C（迁移，`plan-optdex` 在做） |
| 3 | 批 2 实施 + 重新运行 `0 / 6 / 63` | 仍成立（`#139`）；真面现 = 57（从 63 降到 61，再降到 57） |

因此批 4 的位置：排在「裁定二」之后、与「裁定一」的完成解耦，
- 裁定二实施，因此 F 面消失，因此批 4 的未落环排除只剩 A；
- 但 A 仍受裁定一制约，因此批 4 的实参硬错要覆盖 A 面，必须等裁定一；
- 可选中间态：若要更早拿到硬错价值，可先覆盖 B/C/D/E/F 面（不含 A），并把「A 面不在覆盖内」写进触发条件 + 登记（这是 (3) 的降级版，只在裁定一未完成期间成立；不要在裁定一完成后继续保留）。

注意：排期更新（2026-09-20，维护者确认 `Buf` 后）：
- 裁定二到 「拆 `string`」整批（`Buf` + `Chan<T>` + `Future<T>` + `G`，必须同批）到批 4；
- 「拆 `string`」不得拆开做：中途会出现「有的句柄是新类型、有的还是 `string`」的双模型并存（第 7.3 节排期注）；
- `(i)` 的最终语义并入该批（与 `Buf` 一起定），在此之前不再单独改（第 7.3 节连锁 3）。

---

## 1. 触发条件的最终形态（逐项硬编码）

```
报错 ⟺  调用位点有 callee
      ∧ ¬内建回退（fi ≥ 0）
      ∧ pti ≥ 0
      ∧ ¬skip族                       /* 见 第 1.1 八条（已全部落环） */
      ∧ ¬A句柄产出通道                 /* 由裁定一处理；未实施前 = 中间态排除（方案 3 降级版） */
      ∧ ¬unify_types(pti, ati)
```

F 的项已删除，裁定二实施后 `&x` 与 `&T` 同 kind，F 面自然消失（A）。

### 1.1. 已落环的八条，因此不会产生硬错（勿再列一遍）

`pti < 0` · `ati == TI_UNIT` · 整型字面量 · `None 到 T?`（既有四条）· `ati == TI_NEVER` · `ati == TI_DYN` · 泛型形参型（`#142` 三条）· 内建回退（无 `FuncInfo`，因此 `fi < 0`，`-5` 的免检契约）。

---

## 2. 未落环的排除（只剩 A，且它归裁定一）

### 2.1. A，不走「排除」，走裁定一的产出侧改型（第 0 节已证排除不可能）

### 2.2. F，由裁定二消解，不写排除
改判后 `&x` 是 `TYP_REF`，与 `&T` 形参同 kind，因此 `n19_ref_named.cr` 的 2 点自然归零。
检查（裁定二的验收）：该档 `CORE_S1P=1` 清单 2 改为 0；反向固定：真正的 REF/PTR 混用若仍存在（如 `*T` 形参 ← `&x` 的值经变量中介）仍须报。

---

## 3. 语料影响预测 + 验法（先硬编码，再取数）

| 面 | 预测（裁定二实施后） | 理由 |
|---|---|---|
| `tests/probes/n19_ref_named.cr` | 2 改为 0 | F 由改判消解 |
| 闭包外清洁档 | 57 改为 55（F 的 2 点消失；A 的 49 点在裁定一前保持） | 逐档实量 |
| `src/compiler`（40 档闭包） | 0 | 自源在实参面本就 0 点 |
| `targets`（24 档闭包） | 0（前提 = B/C 已合） | 未合，因此 B/C 6 点转失败 |
| `ptr_ref_first.cr` / `test_diag_gate.py` / `test_ccr_types.py` | 转失败（须同批改，见第 8 节） | 三处实现方式依赖「`&x` = PTR」 |
| canary 五条 + `.ccr` 四条 | 不变（须实测） | 改判是类型面、不进发射面，但 `@raw_int` 若改允许清单会动判定面，则逐字节对比照旧 |

验法：逐档 `CORE_S1P=1 check` 点集比对 · 两 project 单元（rc + 未定义双零）· `CI_JOB_NAME=suite` · `canary_check.sh` 5/5（对未改动值表）· 同输入 pre/post 逐字节（`out` + `out.ccr`）。

---

## 4. 检查档位结构（先清单不写码）

A 正向（到具体错误码，不只断 rc）：`string` 形参 ← `int` 变量，因此 rc=1 + `error[TF07]` + 定位行号 + build 面零产物；换 `bool`/`dex` 各一；泛型实例化后实参位各一；方法/模块限定/枚举构造三形各一（批 2 的四形态覆盖，因此硬错须同样覆盖）。

B 反向（防误杀）：`g(d, d)`（`T?` 规则）rc=0 · `chan_recv(go work())` rc=0（取决裁定一）· `@str_of(p)` 显式视图（`unsafe` 内）rc=0。

C 对照（防「一律失败」）：完全无关两档 rc=0。

D `skip` 规则 × 断言对照表（七条整张）：`pti < 0` · `TI_UNIT` · 整型字面量（断言必须变量形） · `None到T?` · `TI_NEVER` · `TI_DYN`/泛型形参 · 内建回退，逐条问「这条断言会不会落在它里面」。

E 突变自证（强制形状）：`re.subn` 计数 == 1 · 打印命中上下文 · 剥注释/去串类预处理先单独自证。

注意：F 撤条的连带（这条很重要，是批 4 的一部分、不是顺带）：`diag.cr` 的 TF07 build 豁免自带退出条件写着「退出 = #2026-09-16-1/F3 调用位点完成后撤」，批 4 就是那个调用位点完成。要素：
1. 撤条本体：`diag.cr` 的 TF07 build 豁免（`if scope == GATE_SCOPE_BUILD && code == EC_TF_ARG_TYPE { return 1; }`），且那里重复两份（同一 `if` 写了两遍，`:186` 与 `:190`）；
2. 连带改：`tests/selfhost/test_diag_gate.py`（正控 5 条之一 = TF07；头注还写着「TF07 是 build-scope 豁免码，因此 build 面恒过」）· `tests/selfhost/test_iface_ops.py`（3 处 TF07 计数断言）；
3. 关系：本仓既有约定「`diag.cr` 的 TF07 build 豁免须随硬错化重定」，现在有了确证的退出条件（代码里的原话）。

---

## 5. 损害检查范围核查

`src/compiler` 全闭包在实参面 0 点（四形态下实测），因此硬错不应损害检查自举。但必须实测：`check src/compiler`（rc=0 且仍 0 点）· `check src/targets/x86_64-linux` · `full-bootstrap`（三阶段 `cmp` 逐字节；串行化 + 运行完清 `/tmp/corec2`、`/tmp/corec3`）。

### 5.1. 注意：工作区 stale 处置：强制前置（2026-09-19 由「方法」升为「前置」）

凡本计划涉及的任何 worktree，stale 处置一律：先 `cp -a`（或逐档 `cp`）到仓库外，因此再 `update-stale`，因此再复核 sha。
- 依据（当日第三次实证）：`update-stale` 实测 `modified 1 files, removed 1 files`，它会把工作副本里未快照的内容换掉；那次正是守卫副本接住（`/tmp/guard-blade4-plan-v2.md` 213 行，恢复后 sha 逐字相同）。
- 检查：`update-stale` 之后，逐档 sha256 与守卫副本对比（不是「文件还在盘上」，本仓有四次前科）。
- 因此这条同样适用于第 8 节实施序的每一步（改判期间会频繁切基点）。

### 5.2. 注意：独立验收项：「安全面不得净减」（裁定二专属，不是附注）

> 改判前生效的检查，改判后要么仍生效，要么显式登记为「已知不再生效」并给理由。

- 背景：`region_check`（`rc_return_escape` / `rc_store_escape` / `region_check_func`）与 `provenance_verify`（TU03 门）只认 `TYP_PTR`。注意：但「四处同类」是初判、已被逐处实读否定，见第 5.3.1 节：前三处 = 真·不报错地失去覆盖；第四处（TU03）对 `&x` 从未生效（其 `extra` 恒 0），因此零损失，正确表述是「本处不适用」而非「不再生效」。
- 为什么必须独立立项：「减少检查」不会失败，它是不报错地面，正是本批一路在收的形态（用一次不报错地换一次不对称）。
- 检查：逐处列出「改判前是否生效 / 改判后是否生效」，任一处从「生效」变「不生效」且无显式登记，因此本项失败。
- 处置二选一：（a） 扩展该处接受 `TYP_REF`（等价检查）；（b） 显式登记「已知不再生效 + 理由 + 覆盖面损失」，并在批报告写明。

### 5.3. 注意：裁定二的影响面三分（2026-09-20 实核；第 5.2 节只覆盖类 1）

扫面：`src/` 全扫 `TYP_PTR` = 51 处（`type_selftest.cr` 11 处为测试构造，因此生产 `.cr` 39 处）。按「会不会因改判失效」三分，处置方式不同，不得混为一谈：

| 类 | 处数 | 站点（符号定位点） | 改判后 | 可否「登记了事」 |
|---|---|---|---|---|
| 1 安全门 | 3 真损失 + 1 不适用 | `region_check.cr:63`（`rc_return_escape`）· `:99`（`rc_store_escape`，变量名 `val_ti`，非 `ptr_ti`）· `:119`（`region_check_func`）· `provenance_verify.cr:67`（TU03 门） | 前三：早退，因此不报错地失去覆盖；第四：前后皆不生效 | 见第 5.3.1 节（不是四个同类问题） |
| 2 `@raw_int` 实参门 | 1 | `checker.cr:4239` | 硬错（非不报错地） | 不可以，归批 4 实参面家族 |
| 3 类型身份 / 实例键 / mangling | 见下 | `monomorph.cr:207`/`:214` · `ty_shadow.cr:349`/`:903` · `iface_axis.cr:206`/`:207` | 类型项变，因此产物字节变 | 不可以，须一次 byte 对比 |

#### 5.3.1. 类 1 逐处定论（2026-09-20 逐处实读；四站点不是四个同类问题）

| 站点 | 检查形态 | 改判后 | 处置 |
|---|---|---|---|
| `region_check.cr:63` `rc_return_escape` | `ptr_ti < 0 \|\| kind != TYP_PTR 则 return` | 真·不报错地失去覆盖（返回 `&local` 不再查子图逃逸） | （a） 加 `\|\| kind == TYP_REF` |
| `region_check.cr:99` `rc_store_escape`（`val_ti`） | 同上 | 真·不报错地失去覆盖（存 ref 不再查寿命） | （a） 同上 |
| `region_check.cr:119` `region_check_func`（`IR_DEREF` 分支） | 同上 | 真·不报错地失去覆盖（解引用 ref 不再查子图寿命） | （a） 同上 |
| `provenance_verify.cr:67`（TU03） | `kind == TYP_PTR && extra != 0 则 报 EC_TU_DEREF`（条件触发硬错，不是早退跳过） | 零损失：`&x` 的 `extra` 恒 0（`checker.cr:2966` 硬编码），因此该门对 `&x` 从未生效，前后一致 | (b′) 登记「本处不适用」（非「不再生效」）+ 反向断言 |

- 三处 （a） 安全的原因：这三处只判 kind、不读 `extra`，因此不触碰「REF 的 `extra` = mut 标记」那个问题；加一个 `|| kind == TYP_REF` 即等价扩。
- 第四处为什么不能 blanket（且是个好消息）：它是四处里唯一读 `extra` 的。若做成 `kind == TYP_PTR || kind == TYP_REF`，而改判按自然落法写 `alloc_type(TYP_REF, inner, is_mut)`（`is_mut` 今天已在 `checker.cr:2949` 在手、并在 `:2966` 被丢弃，则那正是 `TYP_REF` 的 `extra` 槽存在的意义；此落法待确认），则 `&mut x` 的 `extra` = 1，因此每一个 `&mut` 解引用都会报「external pointer dereference requires unsafe」（`tests/suite/ptr_arith.cr` 的 `*q = 99`、`opt_dex_test.cr` 的 `*p = d` 立即失败）。
- 两个失效模态不同（须分别定固定）：一~三处 = 不报错地失去覆盖；第四处 naive 扩 = 高声假阳（更好抓，但不能因此就扩）。
- 正反两条断言：1 三处 （a） 正向断言 = 改判后「返回 `&local` / 存 ref / 解引用 ref」仍报（防 （a） 落空）；2 第四处反固定 = naive 扩，因此 `&mut` 解引用假阳（失败状态固定，固定「不得 blanket」）。
- 语料侧确证（2026-09-20）：`tests/selfhost/test_pointer_safety.py`（305 行 / 21 例）里打 `EC_TU_DEREF` 的恰 4 例，`:132`（`p := 4096 as *int; return *p;`）· `:142`（同形 + `*p = 1;`）· `:153`（变量中介：`address := 4096; p := address as *int;`）· `:165`（算术后仍带地址空间：`p := (4096 as *int) + 1;`），全部是 `as *T` 转换形，无一处用 `&x`，因此该门的实际覆盖 100% 在 cast 面，因此第四处改判后覆盖率不可能减少（由「读码推出」升级为「语料确证」）；该 4 例改判后照旧通过（它们不碰 `&x`）。
- 两固定的落点：就在该档（这面既有的套件，不另开），正向断言（三处 （a） 改判后仍报）与反固定（naive 扩，因此 `&mut` 假阳）都落 `test_pointer_safety.py`。
- 顺带登记（不属本批）：同档 `:173` `test_alloc_buffer_cast_remains_tracked` 用的是 `alloc(8)`，因此属第 7.3 节（`alloc` 改为 `Buf`） 批的核心影响点，改判批勿顺带动它。

类 2 的实据（代码里自带教条 + 受害者点名）：`checker.cr:4239` 的分支注释原文写着「`TYP_REF`/`TYP_SLICE`/`TYP_ARRAY` 等仍报错……，因此没证据就不扩」，并在注释里点名 `tests/suite/ptr_ref_first.cr`（`@raw_int(q) - @raw_int(p)` 取字节差）。
- 逐档实读（2026-09-20）：该档 = `p := &x; q := p + 1; …@raw_int(q) - @raw_int(p)…`，因此确证会硬错（`p` 改判后是 REF）。其 `q := p + 1` 另落空 `checker.cr:2903-2910` 的 PTR 分支，那半条归 S3 裁决（指针算术纳入 REF），而 `@raw_int` 这半条无人认领。
- 同形语料共 4 档，但确证者只 1 档：`ptr_arith.cr`（`*p` / `*q = 99`）· `opt_dex_test.cr:56,64`（`*p = d` + `match *p`）· `apx_conversion_test.cr:59`（`*p = d`，且 `@raw_int` 施加于 `px` 而非 `p`），这 3 档的 `&x` 都用在解引用 / 写上（REF 的本职），因此待实测；不得从「形式相同」推结论（本批纪律：观察 不等于 已核验机理）。

类 3 的实据：`monomorph.cr:207` 与 `:214` 分别产 `"&"+inner` / `"*"+inner`，因此实例键变；`ty_shadow.cr:349`/`:903` + `iface_axis.cr:206`/`:207` 把 `&T`/`*T` 落成 `AK_REF`(11) 与 `AK_PTR`(12) 两个不同原子（`type_engine.cr:29` 原文），因此在引擎里本就不相等，因此语义包含判定会变，因此必然动产物字节（`.ccr` interned 串面），因此归「登记」不成立。
- 范围收窄（避免虚报）：生产 39 处里，已按 `PTR ‖ REF` 同族处理的不受影响（实测例：`ir_gen.cr:790/989/1009/1036` · `checker.cr:392/1733` · `ty_shadow.cr:903`），因此该族本来就承认这两者同族，唯安全门那 4 处没跟上（这恰是第 5.2 节的由来）。只认 PTR 的须逐处定 / 对比，计数在实施时现取。

注意：同构陷阱（「（a） 必须逐处谓词、不得 blanket」的第二处依据）：`ast.cr:295-296` 的 `extra` 槽不对称（`TYP_REF.extra` = mut 标记 · `TYP_PTR.extra` = 地址空间）在引擎侧同构存在，`type_engine.cr:461`/`498`/`502` 里 `AK_REF` 槽 0 = mut 标记（参与身份）、`AK_PTR` 槽 0 = 元素（不变），因此凡「统一二者」的改动，`checker`/`ir_gen` 侧与 `type_engine` 侧都要逐槽处理。

---

## 6. 回退条件（满足任一，因此停，不上报为完成）

1. 任何 `tests/suite/*.cr` 在 `build`/`run` 面转失败，且不属第 3 节预测面；
2. `src/compiler` 出现任何新点；
3. canary 五条任一变（且非「D1 通过 + 真实码面变化」的正当同步更新路径）；
4. 语料点集与预测不符，因此不符本身不是回退理由，是归因对象（多出的点逐个读，判「真缺陷」还是「排除漏了一条」；不许把新增点一律当修好的证据）；
5. B/C 未合，因此不得开硬错（`targets` 会出错）；
6. 第 5.2 节安全面出现净减且未登记；第 5.3 节类 2 / 类 3 未处置就开硬错（类 3 无 byte 对比记录，因此同上）。

---

## 7. 裁定一（`Future<T>`）实施面清单（实施图）

| # | 面 | 现址（符号定位点） | 要做什么 |
|---|---|---|---|
| 1 | 类型构造子 | `ast.cr` 的 `TYP_*` 表（已用 0/1/2/3/4/7/8/9/10/11/12/13，因此 5、6 两个空号） | 新增 `TYP_FUTURE`（`data` = 元素型 ti），或复用 `GENERIC_APPLY` + 内建类型名（两者取舍见下） |
| 2 | 引擎·kind到原子 | `iface_axis.cr::iface_kind_of`（现覆盖 `BASE/DYN/NAMED/GENERIC_PARAM/GENERIC_APPLY/ARRAY/SLICE/REF/PTR/TUPLE`） | 新增一个 `AK_*` 原子（变型表要给槽位语义：`Future<T>` 对 `T` 应不变还是协变） |
| 3 | 引擎·形状层 | `ty_shadow.cr::sh_term_of_ti` / `sh_sig_term_of_ti` · `type_terms.cr` 的 tag 表 | 新分支（形状项/签名项各一） |
| 4 | `EXPR_GO` 定型 | `checker.cr::infer_expr` 的 `EXPR_GO` 单发分支 `return body_ti` | 改为 `alloc_type(TYP_FUTURE, body_ti, …)`；range 形（返回数组）须同步 |
| 5 | `EXPR_AWAIT` | `checker.cr::infer_expr` 的 `EXPR_AWAIT`（现「`TYP_ARRAY`，因此 elem，否则原样返回」） | 新增「`TYP_FUTURE`，因此 `data`」；array 分支保留 |
| 6 | `ir_gen` 同改 | `ir_gen.cr:1922-1924`（`new_ir_var("_go_ch", TI_INT)` + `emit(…, TI_INT)`） | 与 #4 必须同改；IR `type_kind` 槽变，因此 `.ccr` 字节面变，因此先看 D1（失败，因此非确定性不得同步更新；通过，因此真实码面变化走正常同步更新） |
| 7 | `chan_*` / `g_*` / `sched_*` 那一族（2026-09-19 解封：A₂ 对齐作废，因此一起改） | 见第 7.1 节逐条清单 | 逐条给「改 / 不改 + 理由」；含 `alloc` 一条待维护者确认（第 7.3 节）；11 例重定不删（第 7.2 节） |
| 8 | A 的 45 点另需 | `sched.cr::sched_get_curg() -> int` + `bi_add("g_get_curg", TI_INT)`（`checker.cr:302`） | 两处同改（`-4` 产出侧 #3），否则即使 `go` 改型，45 点仍异型（实参来自 `sched_get_curg()`/`r64`） |
| 9 | 语料影响 | A 49 = 45（`sched_enqueue`）+ 4（`chan_recv`） | 见 #7/#8：两族都改型，因此 49 改为 0；只改一族，因此归零不全 |
| 10 | 检查（正反两条断言） | | 正：`go f(x)` 的型 = `Future<T>`、`await h` 取 `T`（运行值 + `--dump-types` 双读）；反：把 `Future<T>` 当 `int` 用必须报（防「新类型不可判」）；对照：非 `go` 的普通 `int` 变量仍按原样 |

### 7.1. 「那一族」逐条清单（禁止用「那一族」当枚举；逐条给改/不改 + 理由）

全仓枚举方法（可粘可运行）：
```
grep -rn '^fn .*(\(handle\|chan_\|g_new\|g_free\|sched_go\|sched_enqueue\|fiber_\)' src/stdlib/*.cr src/compiler/*.cr
```
注意：静态枚举只是起点：本仓约定「扫描只作起点，收敛检查必须是被修对象自己的输出」（`verify_command_traps` 第 9 条：静态扫描会漏经调用派生的传递闭包，A₂ 当年「仅 2 处」实为 3 处就是栽在这里），则改完须以 TF01 / 清单读数逐档清点收敛。

| 函数（符号定位点） | 现签名 | 改 / 不改 | 理由 |
|---|---|---|---|
| `src/stdlib/chan.cr::chan_make` | `(elemsize: int, cap: int) -> string` | 改（返回型改为 `Chan<T>`） | 通道句柄产出方；只改 `go` 不改它，因此 `chan_recv(ch)` 4 点仍异型 |
| `chan.cr::chan_send` | `(ch: string, val: int)` | 改（第 1 形参） | 收句柄 |
| `chan.cr::chan_recv` | `(ch: string) -> int` | 改（第 1 形参）；返回型另议 | 第 1 形参 = 句柄；返回型 = 元素的值，性质不同（不是句柄），须单独定 |
| `chan.cr::chan_close` | `(ch: string)` | 改（第 1 形参） | 收句柄 |
| `goroutine.cr::g_new` | `(entry_fn: int, arg: int, arg_type: int) -> string` | 改（返回型） | G 句柄产出方 |
| `goroutine.cr::g_free` | `(g: string)` | 改（第 1 形参） | 收 G 句柄。注意：Core 侧调用点 = 0（`plan-optdex` 侦查实读：只被 `rt.s` 汇编调用），因此 「改」的动作在 ABI 面、不在调用点，实施者别去找不存在的 Core 调用点 |
| `sched.cr::sched_go` | `(fn_ptr: int, arg: int) -> string` | 改（返回型） | 产出结果通道；必须与 `go` 表达式的型一致（否则两面继续不一致，批 4 的 A 类正是这个形状）。注意：Core 侧调用点 = 0（只由 `ir_gen` 合成发射，名字 intern 后发射），因此动作在合成面，同上 |
| `sched.cr::sched_enqueue` | `(g: string)` | 改（第 1 形参） | A 类 45 点的形参侧 |
| `scheduler.cr::fiber_*`（`fiber_init` 等 6 个） | 多为 `(fi: int)` 索引 | 不改（显式列出） | 1 该档不在任何构建清单（`CLAUDE.md` 明载；`build_selfhost_native.py` 逐档核定）；2 `fiber_init` 名字碰撞是已知潜伏项（`#2026-09-19-6`），因此本族不含它，但必须在这里显式写「不改」，否则读者会以为漏了 |
| `dyn_arr.cr::alloc` | `(n: int) -> string`（`bi_add("alloc", TI_STR)`） | 不动（已裁，见第 7.3 节：`alloc 到 Buf`） | 它产出的是裸缓冲、不是句柄 |

#### `Chan<T>` 与 `Future<T>` 必须同批、同一组调用点（`plan-optdex` 侦查，2026-09-20）

`chan_recv` 的 12 个调用点里：5 个实参来自 `chan_make`、7 个来自 `go f(x)`。
因此两族共用同一个调用点集合，因此不得先拆一半：
- 先拆 `Chan<T>`，因此那 7 点悬空；
- 先拆 `Future<T>`，因此那 5 点悬空。
因此写进排期（C）：`Chan<T>` 与 `Future<T>` 是同一步，不是两步。

### 7.2. `test_chan_handle_model.py` 的 11 例：重定 不等于 删掉

- 机械核验：该套件 = `CORPORA(5) × 2 + 1 = 11`，实测 `11/11 通过`（`CORPORA = chan_test · conc_test · go_e2e_test · go_final_test · go_parallel_test`）。
- 它编码的是 A₂ 的契约：其头注逐字记录了「3 处返回型 + 5 处 handle 形参」与四条检查（5 档 `check` rc=0 且无 TF01 / `build` rc=0 / `run` rc=0 / 对齐形态自证）。
- 因此该契约已作废（今日裁定），但删掉这 11 例 = 丢掉「曾经有过这条契约」的证据。
- 重定 + 记录（两组并存）：
  1. 原 11 例整体保留（可在组头加一条注：「本组前提已由 2026-09-19 裁定作废，保留供追溯」）；
  2. 新语义另写一组（`Chan<T>` / `Future<T>` 形态：`ch := chan_make(8,1)` 的型 = `Chan<int>`；`chan_recv(ch)` 收 `Chan<int>`；`go f(x)` 的型 = `Future<T>`；`await h` 取 `T`）；
  3. 读者能看出契约怎么变的，这是「记录」的目的，不是「多留一份垃圾」。

### 7.3. `alloc`，已裁：换成自己的缓冲类型 `Buf`（2026-09-20 维护者原话级）

> 取候选 (i)：`alloc` 换成「自己的缓冲类型 `Buf`」。

形态硬编码：`alloc(size: int) -> Buf`（与 `string` 解耦）。
因此本代理的推测被确认：本意就是把 `string` 这个「万能不透明类型」拆开，缓冲归缓冲、句柄归句柄、通道归通道。

#### `Buf` 不是孤立的一条，它与 `Chan<T>` / `Future<T>` / `G` 同属一个批（「拆 `string`」）

因此排期（lead 定，2026-09-20）：
1. 裁定二（`&x` 改为 `TYP_REF`）仍先动，自足、体量小、且消掉 F 面；
2. 「拆 `string`」整批（`Buf` + `Chan<T>` + `Future<T>` + `G`）排在裁定二之后，且必须同批，
   否则中途会出现「有的句柄是新类型、有的还是 `string`」的双模型并存，那正是本批在收的东西。
3.，因此第 7.3 节不得被写成「一个独立的小改动」：它是那一整批的第一块。

#### 连锁三条，各给「要定什么」，并在本节给答案（不留实施者临场决定）

1. `@ptr_of` / `@str_of` 的立足点，已裁（2026-09-20 维护者原话级）：候选 （b）
   - 裁定：`@ptr_of` / `@str_of` 改到 `Buf` 侧，因此 `string` 退回真字符串，视图内建改到 `Buf` 侧，彻底。
   - （原文保留 · 已被上裁取代）（本仓「只增不删」惯例）：原写「取向：保留 `string` 作为『裸字视图的另一端』，即视图内建语义不动，`Buf 到 string` 走一次显式转换。理由：2（a） 已按『裸字 ↔ `string`』立了 63 处先例（`@ptr_of` 27 + `@str_of` 36），且 B/C 的迁移刚按该范式合入（`79e0395c`），因此不动视图面就不必重做那 6 处。注意：状态 = lead 的倾向（待确认）。」
   - 注意：规模数字更正（旧值记录，会报错改）：原写「那 6 处」「63 处先例」，实测是低估。`plan-optdex` 侦查实读：`@ptr_of` 24 + `@str_of` 36 = 至少 60 个调用点（`interp.cr` 22 · `cli.cr` 23 · `parser.cr` 7 · `ld.cr` 6 · `checker.cr` 1 · `test` 1），其中三档（`interp` / `cli` / `parser`）是生产代码。因此按 ≥60 处计，原写 6 处是低估。
   - 代价（维护者是在看全代价后选的）：60 处要在 `Buf` 侧重做；`plan-optdex` 刚合的 B/C 迁移（`79e0395c`）那 6 处也在内，因此同样重做。当事人已认这笔账，并注明「当时按 2（a） 现行契约做，属当时正确」，该句保留（它把「当时的正确」与「现在的过时」分开）。
2. B/C 的 `79e0395c` 是否重做，已定（随连锁 1）
   - 连锁 1 取 （b），因此第二种后果成立，因此那 6 处（`ld.cr` 的 `ctx_add_so`/`ctx_add_plt`/`ctx_emit_static` 等）必须在 `Buf` 的新语义下重做（成本 = 一次已合并迁移的返工，如实计入本批）。
   - （原文保留）原写两条后果：「若视图内建不动，则不必重做、维持现状；若视图语义随 `Buf` 变，则必须重做」，现取后者。
   - 另记（`plan-optdex` 侦查）：编译器自身的 149 个 `string` 全局是裸缓冲（零串面消费），因此 「拆 `string`」在编译器自源里的主战场是 `globals.cr` 的表指针，而那会动编译器自身，因此牵连 `.ccr` / canary 面（本条与 canary 同步更新同批）。
3. `(i)` 允许清单，列为联合决策，本批不再单独改它
   - `(i)` 已因 S2（加 `TYP_REF`）要改一次；若 `Buf` 再动类型面，同一个门会被连续改第三次，则检查与理由各自变化。
   - 因此硬编码为联合决策：`(i)` 的最终语义（收哪些类型、理由是什么）在「拆 `string`」批里与 `Buf` 一起定；在此之前不再单独改 `(i)`（S2 只做「加 `TYP_REF` + 重写理由」这一件，且理由里要写明它还会随 `Buf` 再变一次）。

## 8. 实施序（裁定二：`&x` 改为 `TYP_REF`），可执行

> 注意：本节 2026-09-20 恢复：v7 提交（`9b264fa5` / PR #148 描述里的「排期重排」）把本节标题与正文整体删去，只留下 `### 拆的条件` 与 `### 第 8.10 节`，而第 8.10 节自述「与 S3/第 7.3 节无关」却从此挂在第 7.3 节之下（无主化）。该删除未在提交说明中登记（违反本批「替换理由必须读得到」的约定）。因此本节按 v6（`37d19fa5`）逐字恢复，2026-09-20 的裁定与实测加在其上（原文不覆盖，本仓「只增不删」惯例）。
> 检查范围教训：`第 8 节` 被删后，`:132`（「须同批改，见第 8 节」）与 `:167`（「适用于第 8 节实施序的每一步」）两处交叉引用悬空，删一节前先 grep 它的引用面（与「修了前置能力要同批清点『把它当现状写』的陈述」同族）。
> 注意：协作面教训（lead 补，2026-09-20）：本节被删期间，lead 一路按「S1–S8」在消息里发指令，而那套编号在文件里已经不存在，双方都记得，所以执行得很顺。
> 因此编号/交叉引用在对话里是动态的、在文件里是静态的。固定动作（两侧各半）：
> 1 发指令侧：凡按编号/节号下指令，受令方应先确认该编号在文件里存在；
> 2 受令侧：不存在就报，不要默默按记忆执行，沉默执行会把「文件缺节」一直藏到某个下游读不到东西的时候（本节就是这么藏了四轮）。

顺序图：`F0、S1、S2、（S3 决策）、S4、S5、S6、S7、S8、S9`
注意：S6（安全面）的处置必须在 S1 之前就定好，它是不报错地面，事后补等于没补（第 5.2 节）。（2026-09-20：已裁，见 S6/第 5.3.1 节，因此该前置已满足。）
注意：每一步都适用第 5.1 节的 stale 强制前置（改判期间会频繁切基点）。

### F0 固定基线（先硬编码，再取数），已完成（2026-09-20）

原文（v6）：存档 `build/corec`（pre）· `--dump-types` 读数（`&x` 的 kind、`p := &x` 的变量行）· 清单基线（F 面 2 点逐点）· 三处实现方式现状（`ptr_ref_first.cr` / `test_diag_gate.py` / `test_ccr_types.py` 的 rc + 产物）。检查 = 上述四项读数先硬编码；后续每步与此对比。

实测（源修订 `7a6f734b`；产物留档 `/tmp/f0-base/b1/`）：

| 项 | 读数 |
|---|---|
| 确定性 ×2（清空 `build/` 后重建两次） | `corec` `58ecb44a…` · `corearch` `9af0b8b3…` · `corelsp` `0e1d6c96…`，因此三者逐字节 IDENTICAL |
| 快速验证 | `run 'fn main()->int{return 42;}'`，因此 rc=42 |
| 清单基线（F 面） | `tests/probes/n19_ref_named.cr` + `CORE_S1P=1`，因此 2 行 |
| `--dump-types`（探针 `p := &a; q := &mut b;`） | TYPE 段 13 行，row 9/10/11/12 全 = `kind 4`(TYP_PTR) `extra 0`，因此 `&x` 与 `&mut x` 不可区分（`checker.cr:2966` 硬编码 `extra=0` 的可见后果）；PTR 行不去重（仅登记） |
| 实现方式 `ptr_ref_first.cr` | check rc=0 · ELF `fdf8cad6…`(28854B) · `.ccr` `8b4b2b42…`(95428B) |
| 实现方式 `opt_dex_test.cr` | check rc=0，0 诊断 |
| 实现方式 `ptr_arith.cr` | check rc=1，1× `error[B04]` @ `12:8`（`if x != 99`，借仍活），因此非「0 诊断」；全语料 B04 扫面 = 恰 2 档（+`apx_conversion_test.cr`），与 `REBUILD.md` 登记的「B04 ×2」逐档吻合（不是新缺陷） |

- 注意：sha 约定：这三个不等于 `REBUILD.md` 允许清单（`ae01de75…` @ `97f4394f`），那是历史固定基线的 pre-侧（P6 终态）；本批 pre-侧 = 当前 develop，则不同是预期；允许清单属另一条检查，本批不换代。
- 注意：命令形式：`--dump-types` 须用 `corec ccr <file> --dump-types`（`build` 不吐段表，已试错一次）。

### S1 定型点改判（两侧同批：`checker` 与 `ir_gen`），已实施（2026-09-20；CI 失败待 S3，见下）

> 注意：约定修正（2026-09-20 lead 裁）：S1 不是「`checker.cr:2966` 的一处改判」，而是「`&x` 的定型在 `checker` 与 `ir_gen` 两侧的同批改判」。
> 为什么：`checker` 只决定语义视图；`region_check` / `provenance_verify` / `ptr_analysis` / 后端读的是 `irv_type()`（= IR 变量型）。
> 因此只改 `checker`，因此三道安全门看到的仍是 `TYP_PTR`，因此 S6 的 （a） 扩法对着一个「永不出现的 kind」生效 = 不报错地空转，正是「正向断言必须验到『检查真的触发』」那条所防的形态，而它这次出现在本计划自己的 S1 原文里。

| # | 站点 | 改动 |
|---|---|---|
| 1 | `checker.cr:2966`（`UOP_REF` 分支） | `alloc_type(TYP_PTR, inner, 0)` 改为 `alloc_type(TYP_REF, inner, is_mut)`（`is_mut` 见 `:2949`，此前被硬编码 `0` 丢弃） |
| 2 | `ir_gen.cr:1858`（v9 原文未列；实施侦查所得） | `new_ir_var("ref", alloc_type(TYP_PTR, pti, 0))` 改为 `alloc_type(TYP_REF, pti, ast_int_val(node))` |

因此同一个 `alloc_type` 调用的两个实参（kind、extra）也必须同批，只换 kind 不写 extra，因此 REF 的 `extra` 恒 0，因此与 `AK_REF` 槽 0（mut，参与身份）不一致 = 一个新的不一致，正是本批在收的东西。

检查（全过，2026-09-20 实测）
- S1-1 `--dump-types`：改判前 row 9/10/11/12 全 `kind 4`(PTR) `extra 0`（不可区分），因此改判后 `kind 3`(TYP_REF)，且 `extra 0` 与 `extra 1` 两行并存，因此 `&x` 与 `&mut x` 可区分（新增断言1 达成）。
- S1-2 清单：`n19_ref_named.cr` + `CORE_S1P=1`，因此 2 改为 0。
- 损害检查范围 `check src/compiler` rc=0 / 0 诊断 · 自举 `build_selfhost_native.py` SUCCESS。
- 行为影响面 = 恰 1 档 1 条：`ptr_ref_first.cr` `0/0` 改为 `1/1 error[TF07]`（正是第 5.3 节已确证的 S2 靶心）；`ptr_arith` / `opt_dex_test` / `apx_conversion_test` 全不变。

注意：CI 失败 = S3 未实施（不是 S1 的缺陷）：`selfhost-tests`，因此 `selftest-types` 413/415，恰 2 例：
```
FAIL ops.infer_ptr_add_int: got 0 want 1
FAIL ops.infer_ptr_diff:     got 1 want 0
```
归因（逐行读过）：`type_selftest.cr` 的 `o4_` 族用 `EXPR_UNARY/UOP_REF` 构造 `&int` 节点（`:2748-2749`）当指针操作数，则断言 `TYP_PTR`（`:2778`）与「`TI_INT` 且 0 诊断」（`:2812`），则现在都落空 `checker.cr:2903`/`:2906`/`:2910` 的算术门（仍只认 `TYP_PTR`） = 第 8 节 S3 本体。
因此 S1 与 S3 是同一批的先后半个：S1 实施后，S3 的失败是必然而非意外。

- 新增断言2（反向固定 · 约定已修正）：实现方式 = `opt_dex_test.cr`（`*p = d`，rc=0）· `ptr_arith.cr`（`*q = 99`，rc=1 + B04×1），因此检查 = 「B04 计数保持 1，且不得新增 `EC_TU_DEREF`」，不是「0 诊断」（naive 扩第 4 处会在 `*q = 99` 处造假阳）。
- 失败，因此停（这是本裁定的本体；S1 本体已过）。
- 注意：一处待裁：`ir_gen.cr:1826` 的 `&arr[i]`（`IR_ADDR_INDEX`）仍是 `TYP_PTR`，因此现态两种取址形式类型不同。实施时未擅自扩（裁定二字面只写 `&x`），因此待 lead 裁 (1) 本批一并改 / (2) 独立条目。

### S2 `(i)` 允许清单整体重写（裁 1：不是加一行常量）

- 现状：`checker.cr:4239` 的 `if !(av > TI_DEX_S && get_type_kind(av) == TYP_PTR)`，其注释理由 = 「`&x` 解析到 `TYP_PTR`」；`tests/suite/ptr_ref_first.cr` 的头注自证依赖它。
- 要做三件：1 加 `TYP_REF`；2 重新论证语义，原语义「只认指针」已站不住，候选新语义 = 「只认地址型（REF 与 PTR 皆是）」，按实现定、但理由必须重写；3 显式登记「原前提已失效」（`&x` 不再是 `TYP_PTR`）。
- 注意：范围扩大（2026-09-20 lead 裁）：不止允许清单那一行，`S2` = 「门本体 + 那 ≥4 档语料」一起重定，检查必须包含这些档的处置：

| 档 | 形态 | 现状 |
|---|---|---|
| `tests/suite/ptr_ref_first.cr` | `@raw_int(q) - @raw_int(p)`（`p := &x`） | 确证会硬错（改判后 `p` 是 REF）；其 `q := p + 1` 另半条归 S3 |
| `tests/suite/ptr_arith.cr` | `p := &x` + `*q = 99` | 待实测（且 rc=1+B04，见 F0） |
| `tests/suite/opt_dex_test.cr` | `p := &x` + `*p = d` | 待实测 |
| `tests/suite/apx_conversion_test.cr` | `p := &px` + `*p = d`，`@raw_int` 施加于 `px` 而非 `p` | 待实测（不在类 2 命中面，「形式相同 不等于 同一受影响面」） |

- 注意：`checker.cr:4239` 的教条注释必须同批更新：那里写着「`TYP_REF`/`TYP_SLICE`/`TYP_ARRAY` 等仍报错……，因此没证据就不扩」，并点名 `tests/suite/ptr_ref_first.cr`，因此改完还留着它，等于让下一个人按旧前提行事。
- 注意：批 4 触发条件留一条对账：本门的判定面变了，因此批 4 的「已落环/未落环」清单须跟着更新（别让批的清单停在改判前）。
- 正反两条断言（同批，缺一不算）：
  - 正（防误杀）：`@raw_int(&x)`（传 REF）必须仍被接受，因此 `ptr_ref_first.cr` 仍 rc=0；
  - 反（防漏放）：`(i)` 当初拒的那些，`string` / `bool` / `array` / `slice`，必须仍被拒，则逐类各一探针，断言 `error[TF07]` + rc=1；
  - 对照（防「一律」）：`@raw_int(n : int)` 与 `@raw_int(d : dex)` 仍接受。

### S3 指针算术门（已裁：纳入 `TYP_REF`）

- 现状（v6 原文）：`checker.cr::infer_expr` 的 `ptr±int` / `ptr-ptr` 三点只认 `TYP_PTR`；两条处置 （a） 纳入 `TYP_REF` / （b） 保持只认 PTR（后果：`&x + 1` 失效，因此 `ptr_ref_first.cr` 转失败）。
- 因此 2026-09-20 维护者裁 = （a）（指针算术纳入 REF）。
- 先读：`ptr_ref_first.cr` 头注说它测的是「占位表项占住下标 8，因此 `PTR_ADD` 按 8 字节缩放」，因此改判后 REF 是否仍走 `PTR_ADD` 是该档存废的分界。
- 检查：`&x + 1` 的 `--dump-types` 行 + 该档 rc/产物。
- 正反两条断言的「改判前」基线（实测硬编码，避免将来把「改判前本来就通」当成「放宽成功」）：见第 8.10 节下方 S3 段。

### S4 自动解引用（`obj.field`）

- 现状：自动解引用只解 `TYP_REF`，因此改判后 `&x` 的取值语义反转（原本是 PTR、不自动解）。
- 要做：逐点读 `EXPR_FIELD` 的解引用分支，列出「改判后行为变化的点」（不许笼统说「语义反转」）。
- 检查：逐点探针（`p := &x; p.f` 形）。

### S5 引擎身份 / 变型

- `iface_kind_of` 的 `TYP_REF 到 AK_REF` 已有（无需新映射）；但变型语义变（`AK_REF` 槽 0 = mut 标记、槽 1 只读协变；`AK_PTR` 槽 0 恒不变），因此核 `&x` 的 `mut` 标记来源正确。
- 注意：并入：「同槽不同义」的第二处实例（2026-09-20），`ast.cr:295-296` 的 `extra` 槽（`TYP_REF` = mut 标记 · `TYP_PTR` = 地址空间）在引擎侧同构存在：`type_engine.cr:461`/`498`/`502` 里 `AK_REF` 槽 0 = mut 标记（参与身份）· `AK_PTR` 槽 0 = 元素（不变）。因此凡「统一 REF/PTR」的改动，`checker`/`ir_gen` 侧与 `type_engine` 侧都要逐槽处理（三层证据：值层 `ast.cr` · 引擎层 `type_engine.cr` · 常量层 `TI_DYN`/`TYP_GENERIC_PARAM`）。
- 检查：`selftest-types` 全部通过，注意：`type_selftest.cr` 里有一条同一断言同时固定 `TYP_PTR` 与 `TYP_REF`（`:2881`），因此此处必变成错误，须同批改。

### S6 安全面（裁 4 · 独立验收项 = 第 5.2 节「安全面不得净减」），已裁（2026-09-20）

- 现状（v6 原文）：`region_check::{rc_return_escape, rc_store_escape, region_check_func}` 三处 + `provenance_verify::provenance_verify_func` 一处只认 `TYP_PTR`。
- 因此逐处读完后裁定（四站点不是四个同类问题，逐处定论见第 5.3.1 节）：

| 站点 | 处置 |
|---|---|
| `region_check.cr:63`（`rc_return_escape`）· `:99`（`rc_store_escape`，变量名 `val_ti`）· `:119`（`region_check_func` 的 `IR_DEREF` 分支） | （a） 加 `\|\| kind == TYP_REF`（只判 kind、不读 `extra`，因此等价扩） |
| `provenance_verify.cr:67`（TU03） | (b′) 登记「本处不适用」，从未对 `&x` 生效（`extra` 恒 0），因此不在覆盖净减面上；不给它写谓词（对不生效的门写谓词 = 凭空造检查） |

- 注意：记录更正（lead 裁）：第 4 处 naive 扩的后果是假阳（loud），走 `check_error(EC_TU_DEREF, …)`，不是「不报错地语义错」（最初写成「不报错地」，已改）。因此假阳与不报错地的处置优先级不同，别把假阳写成不报错地。
- 注意：（a） 的非真空性已实测：三处拿到 `pts` 后还有 `if pts == 0 { return; }`，因此若 REF 无 provenance，扩了也空转（假修法）。实测证明非真空：`&x` 发 `IR_REF`（`ir_gen.cr:1859`）且 `ptr_analysis.cr:224` 按 opcode 不按 kind 填充，因此 REF 值有 `pts`，因此 （a） 是真·等价扩。
  因此正向断言必须验到「检查真的触发」（rc=1 + 具体错误码），不能只验「没崩/没报」。
- 正反两条断言：1 正（三处 （a））：改判后「返回 `&local` / 存 ref / 解引用 ref」仍报；2 反（第 4 处）：naive 扩，因此 `&mut` 解引用假阳（失败状态固定，实现方式见 S1 断言2），且 PTR 侧 external 判定必须仍生效（否则「REF 不触发」也可能是「整个门坏了」）。
- （b） 不取：会撞第 5.2 节（安全面净减）。唯一可接受的「不再生效」=「该检查对 REF 语义上不适用」，而那是重定义，属 （a） 的一部分。

### S7 三处转失败实现方式的处置

`tests/suite/ptr_ref_first.cr`（头注自证双依赖，因此视 S2/S3 抉择改写语料或其检查）· `tests/selfhost/test_diag_gate.py`（夹具）· `tests/selfhost/test_ccr_types.py` ㉜（三处）。
检查：三处全转通过，且改的是它们的前提、不是把断言删掉（删断言 = 把检查固化的旧前提留下）。

### S8 完成检查

F 面 2 改为 0 · 两个 project 单元 0 / 6 · 语料逐档与第 3 节预测比对 · canary 5/5（对未改动值表）· 逐字节 pre/post（`out` + `out.ccr`）· `full-bootstrap` · `selftest-types` / `test_diag_gate.py` / `test_ccr_types.py` / `test_todo_id_migration.py` 全部通过。

### S9 类 3 产物字节对比（含 `.ccr`），新增步（2026-09-20 lead 裁）

- 对象：类型身份 / 实例键 / mangling 面，`monomorph.cr:207`/`:214`（`"&"+inner` vs `"*"+inner`，因此实例键变）· `ty_shadow.cr:349`/`:903` · `iface_axis.cr:206`/`:207`（`AK_REF`(11) 不等于 `AK_PTR`(12)，两个不同原子），因此产物字节会变。
- 纪律照 canary/ELF：实测 pre/post；变了，因此必须先过 `D1` 确定性检查（失败，因此非确定性不得同步更新），再谈由维护者声明 + 同批同步更新。「登记」在这里不成立，产物变了就是变了。
- 注意：必须连 `.ccr` 一起（不只 ELF）：实例键变，因此泛型实例的名字/mangling 变，因此可能连带 `.ccr` 的 SYM 段（本仓有 STR/SYM 段前科）。
- 基线：F0 已留 `ptr_ref_first.cr` 的 ELF `fdf8cad6…` + `.ccr` `8b4b2b42…`（实施时按 `parity_run.sh` 扩到整个对比面，F0 只留了单档定位点）。
- 位置说明：放在 S8 之后、同步更新之前（字节对比只有在类型面全部落定后才有意义）；若 lead 要更早，说一声。

### 拆的条件
裁定二实施，因此 F 的「临时排除」不存在了（第 2.2 节），因此批 4 的未落环排除只剩 A（A 归裁定一）。

### 8.10. S1/S2 检查档位结构（先清单不写码；与 S3/第 7.3 节无关，故可先行）

档名（拟）：`tests/selfhost/test_ref_retype.py`（挂 `selfhost-tests` 门内，`suite` 检查不在 PR 门内，本仓有「glob 收编 不等于 进门」前科）。

S1（定型点改判）检查
| # | 用例 | 期望 | 反例（防真空） |
|---|---|---|---|
| S1-1 | `p := &x;` 后 `--dump-types` 读 `p` 的变量行 | kind = `TYP_REF` | 改判前该行 = `TYP_PTR`，因此若改判后仍读 `TYP_PTR`，本项失败 |
| S1-2 | `tests/probes/n19_ref_named.cr` 清单（`CORE_S1P=1`） | 2 改为 0 | 若仍 2 行，则失败 |
| S1-3 | `fn g(a: &int)` ← `&x`（直给，不经变量） | 清单 0 行 | 改判前此处 1 行，因此若仍 1 行，则失败 |
| S1-4 | `r : &int = &x;` 的既有 `error[TA02]` | 消失（同 kind 不再报），改判成功的正向证据 | 改判前基线已实测硬编码：本档 `check`，因此 `error[TA02]: Variable declared as &int, got *int`（该文案即「`&x` = `*int`」的文档化语义原话），因此改判后该诊断必须不再出现；若仍出现，则失败（说明 `&x` 没真的变成 REF） |

S2（`(i)` 允许清单整体重写）检查，三颗断言同批
| # | 方向 | 用例 | 期望 |
|---|---|---|---|
| S2-1 | 正（防误杀） | `@raw_int(&x)`（传 REF，`unsafe` 内） | 接受（rc=0；且 `ptr_ref_first.cr` 仍 rc=0） |
| S2-2 | 反（防漏放） | `string` / `bool` / array / slice 各一 | 逐类各失败：`error[TF07]` + rc=1 + `build` 面零产物 |
| S2-3 | 对照（防「一律」） | `@raw_int(n : int)` · `@raw_int(d : dex)` | 仍接受 |
| S2-4 | 前提已失效的登记 | 源码注释里不再出现「`&x` 解析到 `TYP_PTR`」 | 结构检查（剥注释后 grep），原前提的措辞必须被替换，不是留着 |

突变自证（强制形状，逐条）：`re.subn` 计数 == 1 · 打印命中上下文 · 剥注释预处理先单独自证。
- S1 突变：把 `UOP_REF` 改回 `alloc_ptr_type(inner, 0)`，因此 S1-1/S1-2/S1-3 必失败；
- S2 突变1：允许清单只加常量不改理由，因此 S2-4 必失败（措辞未换）；
- S2 突变2：允许清单「一律放宽」，因此 S2-2 必失败；
- 对照突变：S2-3 的 `int`/`dex` 路径不受 S2-1/S2-2 影响。

注意：一条已填的期望值 + 一处自纠（2026-09-19，S3 裁定到达后）

- S1-4 的期望值已填（原留白）：`error[TA02]` 改判后必须消失。依据 = 裁定二本体（`&x` 改判 `TYP_REF`，因此与 `&int` 注解同 kind），因此与 S3 无关。
- 注意：自纠：此前把这条标注为「与 S3 绑定」，那是错的。S3 管的是指针算术（`ptr±int` 三点），不管注解兼容。
  因此 S3 真正的耦合点是另一处：`ptr_ref_first.cr` 的算术断言（`p+1` 按元素缩放），不是 TA02。
- S3 正反两条断言的「改判前」基线（实测硬编码，避免将来把「改判前本来就通」当成「放宽成功」）：
  - `q := &x + 1;`，因此今天 0 诊断（`&x` 现为 PTR，算术门接受它），因此改判后同一源必须仍 0 诊断；
  - `a + b`（`int + int`），因此今天 0 错误，因此改判后仍须不受影响（这是「扩面没把非地址型一起放进来」的对照）。

## 9. 两句裁定各自的正反两条断言（改契约类尤其要防误杀）

| 裁定 | 正向（该变的变了） | 反向（防误杀） | 对照（防「一律」） |
|---|---|---|---|
| 一（`Future<T>`） | `go f(x)` 的型 = `Future<T>`；`await h` 取 `T`（运行值 + `--dump-types` 双读） | 合法 `await` 链不报（`p_go.cr` 形） | 非 `go` 的普通值不受影响 |
| 二（`&x` 改为 REF） | `&x` 的 kind = `TYP_REF`（`--dump-types`）；`g(p)`（`&NA` 形参 ← `&x`）不报 | `@raw_int(&x)` 仍须可用（第 8.3 节的抉择结果）；`*T` 形参 ← REF 值仍须报 | 同 kind 的 REF/REF 与 PTR/PTR 不受影响；`int` 改为 `string` 的真异型仍报 |
