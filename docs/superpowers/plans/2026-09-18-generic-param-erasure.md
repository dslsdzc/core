# (2) 泛型实例形参擦除，实施计划（规划轮）

> 实施记录：[implementation/2026-09-18-generic-param-erasure.md](../implementation/2026-09-18-generic-param-erasure.md)

> 轮次：2026-09-18 规划轮（只读侦查 + 写进文档）。零构建、零源码改动；本文件是唯一新增物（不碰 `TODO.md`，因此不取号）。
> 起点：`develop = 3e461edd`（本轮实读）；本工作区 `core-cachebloat-ws` 的 `@` = 空提交于 `f9ff306a`。
> 定位：(2) = 表示面（槽型/寄存器类/ABI）；与 (1)/F3 = 检查面的边界见第 6 节。

## 0. 证据分级（本文件每句机理都带标签，无标签即缺陷）

| 标签 | 含义 |
|---|---|
| （实测·转述） | `plan-optdex` 的实测读数，由 team-lead 转述；本轮未复核（零构建，因此无法复核运行面） |
| （实测·本轮只读） | 本轮以只读手段（读盘/读文件头/grep）取得的读数，命令可复现 |
| （读码） | 本轮本次实读 `develop = 3e461edd` 的源码行；定位点均为 file:line |
| （推断·未验证） | 由读码外推、未实测；实施前必须先测 |

硬约束（本轮）：零构建 · 零源码改动 · 只新增本文件。
提交纪律（实施轮）：一批一链一 bookmark；路径限定提交；推前运行对应检查（见第 4.1 节）。

---

## 1. 机理

### 1.1 根因链（全部（读码），行号 = develop 3e461edd）

1. 实例创建只深克隆函数体。`monomorph.cr:600`：
   `if k == EXPR_FN { d2 := gen_clone_tree(d); n := ast_alloc(k, a, b, c, iv, tv, d2, ln, cl); ... }`
   `EXPR_FN` 的 `a`=名、`b`=首形参、`c`=形参数原样复制；只有 `d`（函数体）走克隆。
   因此实例与声明共用同一个形参节点链。
2. `EXPR_PARAM` 的克隆分支存在但走不到：`monomorph.cr:604`
   `if k == EXPR_PARAM { d2 := gen_clone_tree(d); n := ast_alloc(k, a, b, c, iv, tv, d2, ln, cl); ... }`
   克隆 `d`（类型节点）的能力已有；但 `EXPR_FN` 分支从不访问 `b`，该分支对实例的形参恒不可达。
3. 形参序言按「声明面节点」定槽型。`ir_gen.cr:3071-3081`：
   ```
   3071  param_type : ., mut = ast_type_val(pn);      // 泛型形参 = 0
   3072  if param_type < 0 { param_type = TI_INT; }   // => TI_INT（GP 类）
   3073  if param_type == TI_DEX { param_type = TI_DEX_S; }
   3080  else if dex_opt_type_node(ast_data(pn)) != 0 { param_type = TI_DEX_S; }
   3081  pvar := new_ir_var(pname, param_type);
   ```
   泛型形参 `t: T` 的节点 `ast_type_val` = 0，因此槽型恒 `TI_INT`；`t: T?` 的 `dex_opt_type_node` 见下条，因此恒假。
4. `dex_opt_type_node` 看不穿泛型形参。`ir_gen.cr:1127-1134`：要求内层节点 `ast_kind(inner) == 0`；泛型形参引用是 `EXPR_IDENT`（kind 不等于 0），因此对 `T?` 恒返回 0，因此声明面的 dex 门恒假。
5. 调用点对齐环按「声明面参数链」判门，且发生在实例重定向之前。`ir_gen.cr:1964-2008`：
   `cfi := find_func(func_ni)`（= 声明）到环门 `ir_gen.cr:1984-1985`：
   `if ast_type_val(cpn) == TI_DEX || (cfn_ext == 0 && dex_opt_type_node(ast_data(cpn)) != 0)`
   因此泛型形参两个子检查皆假（第 3/4 条同因），因此不转换。
   实例重定向在 `ir_gen.cr:2072-2077`（`spec_ni := gen_find_or_create_*` 改为 `func_ni = fi_name(spec_ni)`），在环之后。
6. ABI 分类由实参 var 的 IR 型决定，与被调形参槽型是两个独立面。`callseq.cr:66-89`（`cs_args_dispatch`）：
   `pt := irv_type(fa + ai); if pt == TI_DEX { 写 XMM(fr_cnt) } else { 写 GP(ir_cnt) }`；栈参判定同规则（`callseq.cr:95-106`）。
   因此调用点按 `TI_DEX` 放 XMM，而被调侧（第 3 条）按 `TI_INT` 读 GP，因此寄存器类失配。
7. `fi_param_type` 无法解决：实例的形参型是逐位抄声明（`monomorph.cr:844-850`，`fi_set_param_type(new_fi, pi, fi_param_type(func_ni, pi))`）。
   （实测·本轮只读）全仓 grep：`fi_param_type(` 的唯一读取点就是这条拷贝自身（`monomorph.cr:849`）；其余全是 `fi_param_count`。
   因此后端 ABI 不读 FuncInfo 形参型（只读实参 var 型），因此 「把 FuncInfo 抄对」不是关键面。

合起来：实例的形参「类型」在三面各说各话，节点面（`ast_type_val` = 0）、类型行面（未解析）、FuncInfo 面（抄声明）。
调用链上唯一把两面拴在一起的是调用点对齐环（第 5 条），而它对泛型形参恒不生效。

### 1.2 实测读数（（实测·转述），本轮未复核）

| 探针 | 前态 ELF / interp | 读法 |
|---|---|---|
| 泛型 `h(ds)` | 77 / 85 | 两条检查分歧 |
| 泛型 `h(da)` | 两条检查均偏离期望 | 两条检查同错（非仅 ELF） |
| 非泛型 `f_i(d)` | 2 / 0 且 `check` = 0 诊断 | 不报错地（零诊断） |
| `h[dex]` 体内 `@raw_int(t)` | `error[TF07]` | 实例体从未按 `dex` 检查（检查面，见第 6 节） |

另（（实测·转述））：ELF 侧读数随构建变化（63 改为 247），因此读的是未定义寄存器，与第 1.1-6/7 条的失配解释自洽。
归因待复核项：`h(ds)` 的实参形态（是否为 `dex` 族 var）本轮未能核实（探针源码不在本工作区）；第 4 节的检查必须自建最小探针，不引用这两个数当定位点。

### 1.3 已核读点清单（谁看形参链 / 形参型）

| 读点 | 定位点 | 现状 | 修 A1 后 |
|---|---|---|---|
| 形参序言（槽型 + 表示位/decl_ti） | `ir_gen.cr:3071-3091` | 声明面 | 自动跟随（实例链已具体化） |
| 调用点 dex 对齐环 | `ir_gen.cr:1964-2008` | 声明面 + 重定向前 | 不自动（须 A2，见第 2 节） |
| 检查器登记形参符号 | `checker.cr:2169-2210` | 用 scope 符号解析（泛型形参注册为 `TYP_GENERIC_PARAM` 行，`checker.cr:2177-2187`） | 不受影响（检查的是声明） |
| 对齐环之外的另一 `ast_b` 读点 | `checker.cr:2016` | 调用检查（声明面） | 不受影响 |
| 实例 FuncInfo 形参型拷贝 | `monomorph.cr:844-850` | 抄声明 | 不受影响；无读取点（第 1.1 节第 7 项） |
| mangling（实例名） | `monomorph.cr:836-841`（`orig_name + "[" + type_args + "]"`） | 由调用点类型实参拼 | 不受影响 |
| 实例缓存键 | `inst_key_of_ti`（`monomorph.cr:177-230`） | 由调用点类型实参行拼 | 不受影响 |

### 1.4 未验证面（实施前必须先测，不得据本文件推定）

- （推断·未验证）泛型结构体实例是否有同族面（`g[dex]` 之类的结构实例）；本文件只覆盖 `EXPR_FN` 实例路径。
- （推断·未验证）复合形参面的代入完备性：`[T; N]` / `&T` / `*T` / 元组形参在 `gen_clone_tree` 下的产物（`inst_type_node_of_ti` 对元组/复合实参已知回 -1，因此有未覆盖面，见 `monomorph.cr:160-175` 契约注释）。
- （推断·未验证）`-O 1` 与 `run` 两形态下同一实例的行为是否与 `build` 一致（对齐环只在 `build`/`run` 共用的 ir_gen 路径上，理论上同源，未测）。
- （推断·未验证）`.ccr` TYPE 段是否新增行（实例代入出的类型行多半已由调用点存在；须实测段计数）。

> 第 1.4 节追加（2026-09-18，见第 10 节）：模块限定调用形（`ml.g(1,d)`）由「未验证」转 （实测·转述）；
> 方法形（`impl X[T]`）= 排除性证据（全仓 0 处），因此属「不可表达」而非「没测」。

---

## 2. 修法候选（≥2）与影响面矩阵

### 候选 A（推荐）：实例侧形参链具体化 + 调用点按实例签名对齐（A1 + A2 成对）

- A1（被调面）：在 `gen_create_instance`（`monomorph.cr:812-870`）克隆体之后，同一趟克隆声明形参链：
  逐形参克隆 `EXPR_PARAM`（复用 `monomorph.cr:604` 分支语义，因此类型节点经 `EXPR_IDENT`/`EXPR_OPTIONAL` 分支代入），
  组成新的参数 run，`ast_set_b(new_fn_node, <新首形参>)`（`c` 保持 = 形参数）。
  必须同时重算 `param.type_val`：现有 `EXPR_PARAM` 分支把 `tv` 原样拷贝，因此泛型形参的 `type_val` 仍是 0，
  第 1.1 节第 3 项 的槽型仍会是 `TI_INT`。做法对齐 parser 的写点（`parser.cr:1472-1476`：基类型时 `param.type_val` = 基类型码）。
- A2（调用面）：让调用点对齐环看到实例签名。两条实现路线（择一，不得两都做）：
  - A2a 后置第二遍：在重定向后（`ir_gen.cr:2076` 之后、IR_CALL 发射前）用实例 `cfi` 再运行一遍对齐环；
    前提 = 环已抽成 cfi 参数化、幂等的函数（这正是 `aaa054fe` 半成品的形态，见第 7 节）。
  - A2b 前置换序：把泛型解析（`ir_gen.cr:2072`）移到对齐环之前，使 `cfi` 一开始就是实例。
    注意 `type_args` 的回落路径（`ir_gen.cr:2048-2066`）按实参 var 型取名字串，`TI_DEX`/`TI_DEX_S` 同映射 "dex"
    因此换序对键无影响（读码）；但换序会改动所有调用的路径（面大、回归风险高）。

A 的代价：A1 增 AST 节点（每实例每形参 + 类型子树）；A2 触及调用发射前的公共段。A1 单独无效，调用点仍按声明面判门，因此实参仍以 `TI_DEX` 走 XMM（第 1.1 节第 5 项/6），失配只是换向而不是消失。

> A2a 覆盖面限定（2026-09-18，见第 10 节）：A2a 只覆盖直调形（`g(1,d)`，因此 `EXPR_IDENT`）；
> 模块限定形（`ml.g(1,d)`，因此 `EXPR_FIELD` ∧ `is_module_call`）不进重定向块，因此本批不覆盖（显式登记，见第 10 节第 1 项）。

### 候选 B：消费点按实例绑定解析（不改 AST）

- 实例创建时把代入后的形参类型行持久化（现表 `g_gen_instances` 只存 `(源 fi, 键串, 新 fi)` 三元组，`monomorph.cr:861-866`，因此需新表或键串回解）；
- 新增单入口 helper（如 `inst_param_slot_ti(fi, pi)`），把 `ir_gen.cr:3071-3081` 与 `ir_gen.cr:1984-1985` 两处都改为经它取值。

B 的代价：替换逻辑要在没有 `gen_clone_tree` 代入机制的情况下重写一遍（`T`、`T?`、`[T;N]`… 都要自己解），
且「两处读点都要改」，漏一处即不报错地类（正是本条要消灭的形态）。收益 = 零 AST 扰动。
结论：机制上可行、工程上比 A 贵且更易漏；只在前者被实测证否时启用。

### 候选 C：只修 dex 族（分层最小面）

只对「代入后为 `dex` 族」的形参做具体化（序言 + 对齐门）。面最小、最快拿到失败到通过，但：
1 概念上只治 ABI 面的一半（`T=string` 等槽型仍错，语义保留哲学里 IR 型不忠实）；
2 若作为终态交付即是变通（硬性规则 1）。定位 = 可选的实施分期（先 dex 族完成到再一般化），不是替代方案；是否分期由维护者裁。

### 影响面矩阵（每格：该候选是否改变 / 需要注意什么）

| 面 | A（A1+A2） | B | C |
|---|---|---|---|
| 形参槽型（`new_ir_var` 的 IR 型） | 改（T=dex，因此 `TI_DEX_S`，其余按代入型） | 改（同左，经 helper） | 仅 dex 族改 |
| 寄存器类 / ABI（`callseq.cr:66-89`） | 必须 A2 成对才改（实参由 `TI_DEX` 改为 `TI_DEX_S` 转 GP） | 同左（同样须改对齐门） | 仅 dex 族改 |
| `.ccr` TYPE 段 | 预计不新增行（代入型行由调用点已建）（推断·未验证）；NOD/instr 段必变（实例体槽型） | 同左 | 仅 dex 族变 |
| `.cir` 快照 | 不涉（含泛型声明的单元整体关缓存，见第 3 节） | 同左 | 同左 |
| `inst_key_of_ti`（实例键） | 不改（键自调用点类型实参拼） | 不改 | 不改 |
| mangling | 不改（`orig_name[type_args]`） | 不改 | 不改 |
| 需要同步的读点数 | 2（序言 + 对齐环）；A2a 增量式、A2b 改公共路径 | 2（同上，且要自建代入） | 2（门内加允许清单） |
| 主要风险 | 参数 run 的布局契约与 dedup 交互（见下） | 漏读点，因此不报错地；键串回解脆 | 半修被当成修完（约定风险） |

### A1 的实现陷阱（实施轮必须逐条核）

1. 参数 run 的扫描契约：序言与对齐环都靠「`pn = pn+1` 起向前扫到下一个 `EXPR_PARAM`」（`ir_gen.cr:3116-3120`、`ir_gen.cr:2003-2007`）定位下一形参；
   克隆必须保持「形参节点与其类型子树相邻、且按形参顺序分配」，否则扫描会跨过形参或串位。
2. dedup 交互：`gen_dedup_add` 按源节点去重（`monomorph.cr:479-483`）。两个形参共享同一类型节点时，第二次克隆命中 dedup
   因此类型子树不会重复分配（扫描仍能落在下一个形参上，但须实测确认）。
3. `type_val` 重算（第 2 节-A1）：不重算 = 槽型仍 `TI_INT`，整个修复白做，这是最易漏的一步。
4. `ast_data(pn)` 的消费点：`ir_gen.cr:3086-3091`（`ptn := ast_data(pn)` 改为 `irv_set_decl_ti` / optrep 形参信道）在 `g_optrep_on` 下走 `res_type_node(ptn)`；
   代入后的类型节点必须能 `res_type_node` 成功（`inst_type_node_of_ti` 合成的节点满足「根节点占单槽」契约，`monomorph.cr:170-175`）。

---

## 3. 换代问题（按实测决定；禁止写「实施时必须换代」）

### 3.1 结构性事实（（读码））

- 两道缓存门都关：`main.cr:484-490` 扫描全部函数，任一 `fi_generic_count > 0`，因此 `cache_enabled = 0`；`main.cr:495-497` 可选表示面开启，因此同样关。
  因此任何含泛型声明的编译单元整体不读不写 `.cir`（实例是在 IR 生成期由泛型声明派生的，因此无声明则无实例；扫描在 IR 生成之前，因此声明必被看到）。
- 身份自动失效：`.cir` 头含运行中编译器 ELF 的全文件 FNV-1 哈希（`cir_cache.cr:142-168`），装载时比对
  （`cir_cache.cr:500-502`：`if cid == 0 || entry_cid != cid { return -1; }`），因此重建后的编译器天然拒绝旧二进制写的条目。

### 3.2 本轮只读实测（（实测·本轮只读））

| 缓存目录 | 条目数 | 版本分布 | 名字含 `[`（实例形） |
|---|---|---|---|
| `/home/DslsDZC/core/.core/cache/cir` | 81 | 全 17（≠ 现行 20） | 0 |
| `/home/DslsDZC/core-optdex-ws/.core/cache/cir` | 95 | 全 20 | 0 |
| `/home/DslsDZC/core-cachebloat-ws/.core/cache/cir` | 0 | — | — |

复现命令（只读、无构建）：
```bash
python3 -c "
import glob,struct
for f in sorted(glob.glob('.core/cache/cir/*')):
    b=open(f,'rb').read(64); m,v,i,fp,s,nl=struct.unpack_from('<qqqqqq',b,0)
    print(v, b[48:48+nl].decode('utf8','replace'))" | sort | uniq -c | sort -rn | head
```
读数结论：现存快照中零条实例 IR（`[` 名条目为 0）。与第 3.1 节的读码结论一致。

### 3.3 检查（实施轮照此执行，不得预先承诺结论）

1. 实施后、重新构建后，再数一次上表三列（含「当次构建产出的新条目」）。
2. > 0（出现实例名条目），因此必须 `CIR_CACHE_VER` 19 改为 20 式换代并给出归因（哪条路径写出的、为何门没挡住）；
   同时按批 5/批 7 的实现方式清单纪律 grep 全量枚举并同步更新版本实现方式。
3. = 0，因此登记「无重新生效通道，故不换代」，并把第 3.1 节两条结构性事实写进归因（不是「忘了换」）。
4. 无论 0 与否：禁止在计划/实现里写「实施时必须换代」这类预置结论（本轮约定，逐字遵守）。

---

## 4. 验收要求

### 4.1 先扫「既有检查集合会不会拦截」（实施前第一步；（本轮只做清单，未运行））

必须逐条实际运行并分类（失败 = 三类之一：1 真被修好的缺陷 2 预期同步更新 3 停，见第 5 节）：
`src/ci/run.sh` 五档 job（`check` / `bootstrap-tests` / `selfhost-tests` / `suite` / `full-bootstrap`）+
`tools/baseline/` 回归检查（canary / parity / probes / warm）+
高相关套件：`tests/selfhost/test_ccr_v7.py` · `test_ccr_types.py` · `test_optional.py` · `test_apx_conversion.py` · `test_generic_constr.py` · `test_compile.py` · `tests/suite/generics_test.cr` · `tests/probes/*`。
特别注意：`tests/harness/test_diag_gate.py:77` 一类正控（要求某诊断必现），本修复若改动诊断面必咬；
实现方式清单（版本/哈希锁）必须grep 全量枚举，与批 5 第 7ter 节同法，不得凭印象列。

### 4.2 新检查（关键件）

- P1（两条检查同判 + 机理无关定位点）：最小泛型探针（`T=dex` 族），固定值由规范/算纸给出（不是「ELF 给什么就是什么」）；
  `interp` 与 `ELF` 两条检查都必须等于固定值；且检查面（`check`）零诊断（区分第 6 节的第 1 类）。
- P2（ABI 面显式断言）：对实例形参槽型断言（IR 面读回：`dex` 族形参槽 = `TI_DEX_S`），
  并对调用点断言实参转换（转换后实参 var 型 = `TI_DEX_S`），两面同判，防「只改一侧」。
- P3（不变性 / 零产物断言，落 build 面）：不含泛型实例的语料，ELF 与 `.ccr` 逐字节不变
  （检查落在 `build` 产物面，不是 `check`/`cir` 面）；含泛型的语料允许变，但必须能逐条归因到本修复。
- P4（三态安全）：本修复不涉缓存，但仍须覆盖 `check`（诊断）/ `build`（ELF）/ `run`（interp）三态同源；
  另加 `.cir` 缓存开关两态（空缓存/有缓存），有缓存状态只对「不含泛型」的语料要求（含泛型本就关缓存）。
- P5（突变自证 / 可证伪）：预置至少 2 个突变，每个必须让 ≥1 条检查转失败：
  1 去掉 A1 的 `type_val` 重算（第 2 节-A1-3），因此 P2 槽型断言必失败；
  2 去掉 A2（保留声明面环），因此 P1 两条检查分歧必失败。
  突变不失败 = 检查无效，不得交付。

### 4.3 与既有检查集合的关系

本修复会改变含泛型单元的 IR/产物，因此任何以「该语料字节哈希」为检查的条目都可能需要同步更新（带归因）。
同步更新清单要在实施轮用 grep 全量枚举（实现方式纪律），不得只改运行失败的那条。

---

## 5. 停条件（机械可判）

- S1 · 路径集：出现「本批路径集之外」的改动需求
  （路径集 = `src/compiler/monomorph.cr` + `src/compiler/ir_gen.cr`（序言段/调用点段）+ 检查文件 + 计划文件），因此停、回报。
- S2 · 套件转失败：任一既有套件转失败且不能归入「预期同步更新清单」，因此停、回报。
- S3 · 引文逐字比对：实施后把第 1.1 节引用的每一行与代码逐字比对；行变化或语义不符（如 `monomorph.cr:600` 的 `b/c` 复制被改过、门位置变了），因此停，先校正机理段再继续。
- S4 · 单根因 vs 双根因：A1+A2 实施后检查仍失败，因此判「是否第二条独立根因」：
  若第二条根因不属于表示面（例如落入检查面第 6 节的第 1 类），则停，登记为独立条目，不顺带扩面。
- S5 · 突变未失败：任一预定突变未使检查转失败，因此停，检查无效，重做检查。

---

## 6. 与 (1)/F3 的边界（可独立验证 + 哪条检查区分）

| 维度 | (2) 表示面（本计划） | (1)/F3 检查面 |
|---|---|---|
| 定义 | 实例形参的槽型/寄存器类/ABI 与 IR 型保真 | 实例体检查/诊断（按 `T` 未解析检查，`h[dex]` 体内 `@raw_int(t)` 报 TF07（实测·转述）） |
| 现象面 | `interp` ↔ `ELF` 值分歧（检查面零诊断） | `check` 面诊断有无/归属错（运行值可正确） |
| 修复触碰面 | `monomorph.cr` + `ir_gen.cr`（序言/调用点） | checker/诊断侧（不改 IR 槽型） |
| 区分检查 | P1（两条检查同判 + check 零诊断） | 第 1 类检查 = `check` 面诊断断言（正控 `test_diag_gate.py` 形态） |
| 交叉风险 | 若 (2) 修完 P1 仍失败且 `check` 面出现诊断，则可能触发方案 1 的联锁 | 方案 1 若用「实例体复检」实现，需确保不改变 IR 槽型（否则越界到方案 2） |

独立性检查：两批各自的检查都必须在对方未实施时能失败/通过自证（方案 2 看值、方案 1 看诊断）；两批共用同一探针语料但断言面不同。

---

## 7. `aaa054fe` 半成品（环抽函数 `dex_align_call_args`）评估

它是什么（读码 `aaa054fe`）：
- `ir_gen.cr:1254-1300`：把原内联的对齐环抽成 `dex_align_call_args(cfi, ac, arg_vars, arg_nodes, arg_nodes_cap)`，
  cfi 参数化 + 幂等（只对 `irv_type(av) == TI_DEX` 生效，因此重定向前后各运行一遍安全）；
- 两个调用点：`aaa054fe:2178`（重定向前，原位置）与 `aaa054fe:2246`（重定向后第二遍，正是 (2)-A2a 需要的缝）；
- 同一提交还带 `tests/selfhost/test_opt_eq.py`(+174) 与 `src/ci/run.sh`(+12)。

结论（回答 lead 的第 7 问）：
1. 形态上正是 A2a 的一半（「重定向后按实例签名再运行一遍」的机制已就位，且幂等性已论证）；
2. 对 (2) 自身零效果（（读码确证））：第二遍的门（`aaa054fe:1274-1275`）读实例形参链，
   而实例链 = 声明的共享链（第 1.1 节第 1 项），因此门恒假（`T` 的 `ast_type_val`=0；`T?` 的 inner kind≠0），与 plan-optdex 实测一致；
3. 不可原样复用：1 它在另一条链上（未进 develop）；2 热路径遗留调试打印 `println("DBG gate …")`（`aaa054fe:1276`）必删；
4. 建议：若批 8 先合入 develop，则以 develop 上的形态为基线，只补 A1；若未合，则在新链上重做等价抽取（不带 DBG），
   并不把 `aaa054fe` 当依赖 cherry-pick（跨链 + 未过检查）。两条路线都须在计划里登记批次顺序依赖。

> 更新（2026-09-18）：上述第 4 条的「批次顺序依赖」已被第 9 节「第 7 节更新」 取代，批 8 已切成两个 PR，
> PR-A（含环抽 + 检查集合） 合入后 (2) 才开链；本节主体作为历史评估保留。

---

## 8. 未决（交维护者裁）

1. A2 走 A2a（增量第二遍，需先有环抽） 还是 A2b（换序，面大但无前置依赖）？
2. 是否按候选 C 分期（先 dex 族到再一般化），还是直接上 A（一般化）？
3. 第 1.4 节的未验证面（泛型结构体实例、`[T;N]` 等复合形参）是否纳入本批范围，还是各自独立条目标记？
4. 是否需要在本批一并把 `fi_param_type` 更新为代入后代码（无读取点，纯语义保留；成本低但会动 `monomorph.cr:844-850`）。

### 裁定（2026-09-18，lead。原文未决四条保留在上述不动；本节 = 后加的裁定层）

- 裁 1｜A2 走 A2a（增量第二遍），A2b 不做。
  依据：A2a 是加法式改动（重定向前后各运行一遍，环幂等）；A2b 把实例键计算面挪到环前，可能动 mangling/实例键，面大且无必要。
  前置条件（一票否决）：动手前须在改前构建上实测「泛型 `d : dex, apx` 调用点的 `.cir` 中不含转换指令（`dex_opt_dex`/`IR_APPROX` 类）」，
  证实「第一遍被门 `ir_gen.cr:1984-1985` 整个跳过」，因此第二遍是唯一一次转换，无叠加风险；
  若实测发现第一遍已发过某种转换，则停、报 lead（性质变为撤销/幂等处理，另裁）。
- 裁 2｜直接上 A（一般化），不做 C 分期。
  依据：C = 给已知普遍缺失打专属补丁（(1) 批次已被同一理由否掉）。
  前置条件：先做一遍全语料影响面扫面（照 F3 的 S1 形态），枚举「实例形参链被具体化」的影响面
  （哪些语料 / 哪些函数 / 多少实例 / 分别落在 GP 类还是 XMM 类），报 lead 之后才进实现。
- 裁 3｜复合形参不入批（泛型结构体实例、`[T;N]` / `&T` 等）：未验证面入批 = 让检查建立在假设上
  （第 1.4 节三项未被验证）；各自登记为独立条目，本批只做已验证的标量形参链。
- 裁 4｜`fi_param_type` 不动：无读取点，因此无观测面，因此没有检查能发现「改错的时刻」；
  在 (2) 条目内注明可选语义保留项，本批不碰（见第 1.1 节第 7 项、第 2 节矩阵）。
- 裁 5｜检查范围补一条（幂等/不重复转换）：构造「第一遍已正确」的用例，断言第二遍是无操作
  （`.cir` 逐字节或指令计数不变），与第 4.2 节-P5 的突变配套（突变不失败 = 检查无效）。

注意：时序依赖（硬）：A2a 依赖批 8 的环抽 `dex_align_call_args`（`aaa054fe`，见第 7 节）。
因此 1 实施链等批 8 合入后再开（lead 已令 `plan-optdex` 摘掉 `aaa054fe:1276` 的 DBG `println`、保留环抽，
并在其提交信息注明「(2) 的 A2a 依赖此抽取」，防被当不可达代码删）；
2 在此之前不得在任何分支复制一份环抽（两条链各带一份必然在合并时打架）。

执行序（不许压缩）：先测后改，两测都是一票否决，1 A2a 前置实测（第一遍是否整个被门跳过）2 全语料影响面扫面
因此报 lead，因此才进 A1 + A2a。纪律依据：本仓两次失败（第 1 节第 1 项 / 第 1 节第 5 项 机理）都是「先信机理、后补实测」。

---

## 9. 复核修正（2026-09-18，对抗复核到 lead 裁定；原文一字不动，本节为修正层）

> 写进文档纪律同第 8 节：原文保留、本节叠加；凡本节与原文冲突，以本节为准。

### M1｜P1 三态化（dex 家族三态纪律；修正第 4.2 节-P1）

- 依据（本轮实读）：`interp.cr:264-266` 与 `interp.cr:705-707`，`IR_I2F(49)`/`IR_F2I(50)` 在解释器里显式报错 + 中止（"needs binary64 semantics (apx dex)"）；
  批 5 已把该读数制度化（`src/ci/run.sh:207-210`）：bits 源 interp 检查 = 255 是期望值（能力边界），出现第三个值一律判失败，且不许单条检查通过结案（ELF 通过 ∧ interp 第三态，因此仍失败）。
- 修正：P1 由「两条检查都必须 = 固定值」改为三态，
  1 bits 源主探针：interp ∈ {255，固定值}，第三值才失败；
  2 另列 scaled 源探针（该源 interp 可执行，因此两条检查均须 = 固定值，严格判）。
- 与 D3-2 的张力（两者并存，不互斥）：突变论证要求主探针必须用 apx(bits) 源（否则环空转与否同结果，因此恒通过）。
  因此主探针 = bits（三态判）；补充探针 = scaled（两条检查严格判）。

### M2｜A1 换定位点 + `T` / `T?` 两形态分列（修正第 2 节-A1 及其陷阱 3）

- 原引定位点错误（本轮实读确认）：`parser.cr:1472-1476` 是 FuncInfo 写点（`fi_set_param_type(fi, …, ast_type_val(pstore_n))`，只读节点字段，不写 `param.type_val`）。
- 真定位点：`parser.cr:1427`（普通形参）/ `parser.cr:1612`（方法形参）的
  `alloc_node(EXPR_PARAM, pn, 0, 0, 0, unpack_type(pty), pty, …)`；`unpack_type` 定义 = `parser.cr:150-153`（`if ast_kind(typ) == 0 { return ast_type_val(typ); } return 0;`）。
- `T` / `T?` 生效路径不同（新写进文档推论）：`t: T?` 代入为 `dex?` 后，`unpack_type(EXPR_OPTIONAL)` 仍返 0
  因此该形参槽型不由 `type_val` 决定，而由 `ir_gen.cr:3080` 的 `dex_opt_type_node(ast_data(pn))` 分支决定。
  因此 `T`：靠 `type_val` 重算；`T?`：靠类型节点代入（两者缺一即有一形态不回通过）。
- 裁定：检查（P1/P2）与突变（第 4.2 节-P5）按 `T` / `T?` 两形态分列：
  突变 M-α = 只回退 `type_val` 重算（应只让 `T` 形态失败）· 突变 M-β = 只回退类型节点代入（应只让 `T?` 形态失败）。
- 旁注：原文 `monomorph.cr:604` 实为 `:603`（符号定位点对、行号 ±1）；EXPR_FN 分支仍为 `:600`。

### M3｜既有关键锁点名（修正第 4.1 节/第 4.3 节）

- 实读：`tools/baseline/canary_values.tsv:16`（语料 B = `tests/suite/generics_test.cr`；该语料含 `:11 fn identity[T]` · `:17 struct Box[T]` · `:23 fn get_val[T]` · `:29 fn pair[A,B]`）
  + `:91-92`（`gt_ccr` = `d92a2727…`/142765B · `gt_static_ccr` = `a1f7b99c…`/142908B）。
  因此 A1 重写实例形参链，因此这两条值大概率变。
- 检查形态（实读 `:83-86`）：值变，因此归因成立才换代（记「旧值 + 新值 + 归因 + 出处提交」，旧值记录）；归因不出 = 按回归处理、停下上报（默认动作），因此实施轮必被此 fail-closed 检查拦下。
- 裁定：1 `gt_ccr` / `gt_static_ccr` 显式列入「预期同步更新」清单（按 `:85` 约定记录 + 归因）；
  2 ELF canary `pa` / `pa_static` 不受影响（语料 A = `tests/suite/ptr_arith.cr`：零 import、非泛型）；
  3 `suite` job 在 PR 门之外（PR 门只 3/5：`check` / `bootstrap-tests` / `selfhost-tests`），因此改完必须手动派发完整层：
  `gh workflow run .github/workflows/core-ci.yml --ref <branch>`（必须给文件路径，见重名 workflow 陷阱）。
- 第三方背书：`canary_values.tsv:73-74` 自注「`generics_test` 含泛型，因此 `main.cr:480-486`（`:484` 置 0）`cache_enabled = 0`，因此冷≡暖按构造」
  因此这两条锁无「有缓存状态读旧 IR」的误报通过通道。

### M4｜探针与方案 1 面解耦 + 检查三态（修正第 6 节与第 4.2 节-P1）

- 问题：原文探针用 `h[dex]` 体内 `@raw_int(t)`，因此该构造报 `error[TF07]`（方案 1 面现象）；若方案 1实施为硬诊断，则语料编不过，则方案 2的 P1（要求 check 零诊断 + 两条检查取值）连运行都进不去。
- 裁定：1 方案 2的主探针避开方案 1 面构造（不用 `@raw_int`；改 dex 算术/比较 + `match` 解包）；
  2 第 6 节改为「同一族语料、两个独立探针」（不是共用一个探针）；
  3 检查三态为通过、失败（值分歧）、失败（不可运行）；
  4 停条件补 S6：若方案 1 先实施，则 P1 的「check 零诊断」规则须重述（否则方案 2 被方案 1 的诊断误失败）。

### 中项 1｜P2 仪器待定（修正第 4.2 节-P2）

- 实读：现 CLI 的 dump 面 = `main.cr:250/251/252`（`--dump-types` / `--dump-ifaces` / `--dump-tk-terms`）+ `:255-258`（`verify-named-dedup` / `verify-evp-nodes` / `--diag-gate-report` / `--dump-vcs`），
  无「IR 变量槽型」直读；最接近的 `--dump-tk-terms` 是 DFNode.TK = 派生面，不是槽型本体。
- 裁定：P2 不得以「TK 面通过」结案。实现前二选一：1 写明读回命令 + 断言字段（新增隐藏 dump，或复用既有面并证明其表示槽型）；2 证明代理 ≡ 槽型（附反例搜索）。
  未落定前，P2 记为「仪器待定」（不得进实施）。

### 中项 2｜D3 突变矩阵按 {形态 × 实参形态} 分格（修正第 4.2 节-P5）

- 已知「退回仍通过」的四条通道：1 只回退 `type_val` 重算 + 探针只用 `T?`（恒通过）；2 只回退 A2 + 只用 scaled 实参（恒通过）；
  3 只回退 A1 + `T` 代入 int/string（恒通过）；4 原文突变2（去 A2）与「完全不修」等价，因此不证明 A1 有效。
- 补一条突变：只改 A2 不改 A1（槽型仍 `TI_INT`、实参变 `TI_DEX_S`，因此寄存器类一致但语义错）。
  复核判断它很可能不失败，因此必须显式设计值语义断言（两条检查 + 固定值）发现它；不失败即停（S5 纪律已有）。

### 中项 3｜D4 入仓与接入点

- 新增 `tests/selfhost/test_generic_param_erasure.py`，挂 `src/ci/run.sh` 的 `selfhost-tests` 检查
  （`tests/harness/ci_hook_allowlist.txt` 只登记未挂项，因此挂钩即无需允许清单）。

### 7. 更新（时序依赖已解；取代第 7 节第 4 条的「批次顺序依赖」表述）

- 批 8 在 F3 处切成两个 PR：PR-A = 条目 2/3/4/5/6，含环抽 `dex_align_call_args`（摘掉 `aaa054fe:1276` 的 DBG `println`），
  `tests/selfhost/test_opt_eq.py`（+174）与 `run.sh`（+12）随 PR-A 一起进 develop。
- 因此 (2) 只等 PR-A 合入：不自复制环抽、不会丢检查集合（原「若未合则新链重做等价抽取」的备选作废）。

---

## 10. 三形态实测通报（2026-09-18；来源 `plan-optdex` T0，lead 转述（实测·转述）；本节定位点本轮实读）

### 10.1 读数（（实测·转述），本轮未复核运行面）

| 泛型调用形态 | 路径检查 | check | build | run |
|---|---|---|---|---|
| 直调 `g(1,d)` | `EXPR_IDENT`，因此进重定向块 | 0 | 0 | ELF 变化 / interp 15 |
| 模块限定 `ml.g(1,d)` | `EXPR_FIELD` + `is_module_call`，因此不进该块 | 1（TF01 误报） | 0（TF01 在构建豁免表内） | 139 |
| 方法形 | 不可表达（`impl X[T]` 全仓 0 处） | — | — | — |

本轮实读定位点（检查范围）：
- 重定向块条件 = `ir_gen.cr:2015`：`if func_ni >= 0 && (ast_kind(func_node) == EXPR_IDENT) {`，因此只认 `EXPR_IDENT`；
  模块限定形在 `ir_gen.cr:1926`（`if !is_module_call`）另走分支；`is_module_call` 定义 = `ir_gen.cr:1735`（`call_flags == CALL_FLAG_MODULE || …+ CALL_FLAG_INLINE`）。
- TF01 = `EC_TF_RETURN`，已在构建豁免表内（`diag.cr:172` `diag_gate_exempt`，TF01 条目见 `:174-176`；粒度 = 码级、加条须维护者批、换代纪律「只减不增」见 `:165-171` 头注），因此模块限定形是已登代码的新位点，不是表外新码。
- 方法形排除性证据（本轮只读实测，可复现）：`grep -rn "^impl .*\[" --include='*.cr' src/ tests/ examples/ | wc -l` = 0（另测 `impl [A-Za-z_]*\[` 亦 = 0），因此属「不可表达」，不是「没测」。

### 10.2 对 (2) 的四条（全部落为约束，不留隐含假设）

1. A2a 覆盖面收窄（硬）：A2a = 「重定向后运行第二遍环」，而模块限定形压根不进重定向块，因此第二遍在那里不会发生。
   因此本节登记：本批 A2a 覆盖 = 直调形；模块限定形 = 本批不覆盖，承接方 = 独立条目（编号由 lead 在其清单取，本文不取号）。
   不得留成隐含假设（M4 同类：共用探针，因此误读）。
2. 第 1.4 节迁移：模块限定形由「未验证」转 （实测·转述）（第 1.4 节已加指针）；方法形按排除性证据写（见 10.1）。
3. 第 6 节边界检查收紧（机械可分辨）：同一探针双形态运行（`g(1,d)` vs `ml.g(1,d)`），看「实例是否生成 / `IR_CALL` 目标名是否含 `[`」，
   走 `EXPR_IDENT`，因此归 (2)；走 `EXPR_FIELD` ∧ `CALL_FLAG_MODULE`，因此归模块限定条目（承接方）。两批各自可独立失败/通过自证。
4. 不在 (2) 里重复研究 TF01 链：`check=1（TF01 误报）到 build 豁免 则 rc=0 坏产物 到 run 139` 是条目 6 的实际正控（lead 已令 `plan-optdex` 写成其真实可达路径），因此与 (2) 无关，本批不研究（显式硬编码，防后代重复遇到）。

### 10.3 时序（不变，等待更长）

- PR-A 的完成度延后（条目 5、6 未做，lead 已令 `plan-optdex` 先做完再开 PR-A），因此 (2) 等待时间再长一点是有意顺序。
- (2) 仍只等 PR-A 合入；开始实施序不变：A2a 前置实测（第一遍是否整个被门跳过）到全语料影响面扫面则报 lead 到才进 A1/A2a。

---

## 附录 A：本轮实读定位点清单（file:line，develop = 3e461edd）

- `src/compiler/monomorph.cr:600`（EXPR_FN 克隆：只深克隆 `d`）· `:604`（EXPR_PARAM 分支，实例路径不可达）
- `src/compiler/monomorph.cr:177-230`（`inst_key_of_ti`）· `:836-841`（mangling）· `:844-850`（FuncInfo 形参型抄声明）· `:858`（`fi_set_generic_count(new_fi,0)`）
- `src/compiler/ir_gen.cr:1127-1134`（`dex_opt_type_node` 契约）· `:1964-2008`（调用点对齐环；门 `:1984-1985`）· `:2048-2066`（键回落路径）· `:2072-2077`（实例重定向）· `:3071-3091`（形参序言）· `:3116-3120`（形参链扫描）
- `src/compiler/checker.cr:2016` / `:2169-2210`（形参链读点；泛型形参注册 `:2177-2187`）
- `src/compiler/dyn_arr.cr:462/466/472`（`fi_param_count`/`fi_param_type`/`fi_set_param_type`）· `src/compiler/parser.cr:1472-1476`（parser 写形参型）
- `src/os/linux/callseq.cr:66-89`（寄存器分派按实参 var 型）· `:95-106`（栈参同规则）
- `src/compiler/main.cr:484-490`（泛型关缓存）· `:495-497`（optrep 关缓存）· `:539`/`:573`（读/写调用点）
- `src/compiler/cir_cache.cr:80`（`CIR_CACHE_VER = 20`）· `:142-168`（身份 = 全文件 FNV-1）· `:500-502`（身份拒绝）
- `aaa054fe`：`src/compiler/ir_gen.cr:1254-1300`（环抽）· `:1276`（DBG println）· `:2178` / `:2246`（两遍调用点）

附录 A 追加（2026-09-18 第 9 节复核修正轮实读，同一 develop = 3e461edd）

- `src/compiler/parser.cr:1427`（普通形参 `alloc_node(EXPR_PARAM, …, unpack_type(pty), pty, …)`）· `:1612`（方法形参同构）
- `src/compiler/parser.cr:150-153`（`unpack_type` 定义：非 kind-0 返 0）· `:1472-1476`（FuncInfo 写点：只读 `ast_type_val(pstore_n)`）
- `src/compiler/monomorph.cr:603`（EXPR_PARAM 克隆分支；EXPR_FN 仍 `:600`）
- `src/compiler/interp.cr:264-266` / `:705-707`（`IR_I2F(49)`/`IR_F2I(50)` 报错 + 中止）
- `src/ci/run.sh:207-210`（三态纪律：bits 源 interp = 255 是期望值；第三值判失败；不许单条检查通过结案）
- `src/compiler/main.cr:250-252`（`--dump-types`/`--dump-ifaces`/`--dump-tk-terms`）· `:255-258`（`verify-named-dedup`/`verify-evp-nodes`/`--diag-gate-report`/`--dump-vcs`），无「IR 变量槽型」直读
- `tools/baseline/canary_values.tsv:16`（语料 B = `tests/suite/generics_test.cr`）· `:73-74`（含泛型，因此 `cache_enabled=0`，因此冷≡暖按构造）· `:83-86`（换代纪律：归因不出 = 停下上报）· `:91-92`（`gt_ccr`/`gt_static_ccr` 固定值）· `:13`（语料 A = `tests/suite/ptr_arith.cr`）
- `tests/suite/generics_test.cr:11/17/23/29`（`identity[T]` / `struct Box[T]` / `get_val[T]` / `pair[A,B]`）· `tests/harness/ci_hook_allowlist.txt`（只登记未挂项）

附录 A 追加二（2026-09-18 第 10 节三形态通报轮实读，同一 develop = 3e461edd）

- `src/compiler/ir_gen.cr:2015`（重定向块条件 `if func_ni >= 0 && (ast_kind(func_node) == EXPR_IDENT)`）· `:1926`（`if !is_module_call` 分支）· `:1735`（`is_module_call := call_flags == CALL_FLAG_MODULE || call_flags == CALL_FLAG_MODULE + CALL_FLAG_INLINE`）
- `src/compiler/diag.cr:172`（`diag_gate_exempt`）· `:174-176`（TF01 = `EC_TF_RETURN` 构建豁免条目）· `:165-171`（豁免表语义 + 换代纪律「只减不增 / 加条须维护者批 / 表外命中，因此停」）
- 排除性证据命令（本轮只读实测）：`grep -rn "^impl .*\[" --include='*.cr' src/ tests/ examples/ | wc -l` = 0
