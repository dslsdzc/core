# 实参推断缺失，只读根因调查（TODO #2026-09-16-31 实际情况）

日期：2026-09-16 · 性质：只读调查（零源码改动、零新构建；用既有二进制 + `.cir` 对照）
缘起：apx 批 T5 发现的 TODO #2026-09-16-31（「模块限定调用直接作实参，因此 SIGSEGV 139」），本调查把「一个 139」查清为一个范围。
规则：全程 `jj`；未改任何源码；探针未入仓的部分在 `/tmp`（本批已把 19 例入仓，见 5 节）。

---

## 0. 一句话结论

`checker.cr` 的 `infer_expr` 在「被调已解析为 Core `fn`」时提前 return（`:2817`），而推实参的循环在函数尾（`:2833-2839`），对任何有名被调都是未使用代码，因此已解析直调的实参表达式从不被推断。1339 只是它在「实参位的内层调用是 `EXPR_FIELD` 被调」下的表现；更危险的另一半是无提示通过（实参里的未定义函数零诊断）。

## 1. 根因（`file:line`）

| 坐标 | 内容 |
|---|---|
| `src/compiler/checker.cr:2817` | `return sym_type(si); // return type`，直调分支里，被调名 `find_gsym` 命中 `SYM_FN`（已注册 Core `fn`）时提前 return |
| `src/compiler/checker.cr:2833-2839` | `// Infer arg types (for side effects)` + `loop { infer_expr(ast_a(an)); an = ast_b(an); }`，在函数尾，仅当 `func_ni < 0`（连名字都没有）时才可达，因此对任何有名被调是未使用代码 |
| `src/compiler/checker.cr:2584` / `:2645` | 模块限定调用 / 方法调用的 `ast_set_data(node, func_ni)`（被调名索引），只有这两个分支会回填 |
| `src/compiler/checker.cr:2623` | 「推实参」循环在模块/方法分支内另有一份（这才是 c4/c9 能正常解析的原因） |
| `src/compiler/ir_gen.cr` 调用发射处 | `func_ni = ast_data(node)`（`EXPR_FIELD` 被调），读出 0 |

### 1.1 139 的产生链

```
实参位的内层调用 = EXPR_FIELD 被调（方法或模块限定）
  其 ast_data（被调名索引）只能由 checker 的模块或方法分支回填（:2584/:2645）
  但该分支从未执行（外层直调在 :2817 已提前 return），字段保持 parser 初值 0
  ir_gen 读出 func_ni = 0，istr_get(0) 返回文件首个 interned 串
        （有 `import` 语句时恰好是 "import"，这就是 .cir 里 `call import(unresolved, int)` 的来源）
  后端按名查不到，落入外部位重定位（未定义符号）
  最终 SIGSEGV 139
```

对照（为什么绑定到变量就正常）：`x := fmt.int_str(7)` 的模块调用在 LET 值位，`infer_expr` 会真正执行，模块分支会补充名字。而 `str_eq(fmt.int_str(7), "7")` 的内层在实参位，外层提前 return，因此从不被推断。

### 1.2 无提示面（同因、更隐蔽）

既然实参不被推断，则已解析直调的实参完全不进检查：`g(nosuchfn(1))`（`g` 为本文件 `fn`）`check` rc=0、零诊断（实测），且运行时同样 139。
因此 #93 的正确标题是「实参推断缺失」：139 会明确报错，无提示通过则不会报错，后者才是本项目最主要的危害。

## 2. 可达性边界

### 2.1 判别矩阵（同形单变量）

| 内层被调形态 | 外层 = 已解析 Core `fn` 直调 | 外层 = 模块限定调用 | 外层 = 方法调用 | 外层 = extern / 未解析 |
|---|---|---|---|---|
| 模块限定 `m.f(x)` | 139 | 通过 | — | 通过 |
| 方法调用 `s.m(x)` | 139 | — | 通过 | — |
| 直调 `f(x)` | 通过 | 通过 | 通过 | 通过 |
| 泛型实例化 `idf(x)` | 通过 | — | — | — |

判定条件：崩溃 = 内层 `EXPR_FIELD` 被调 ∧ 外层已解析 Core `fn` 直调（外层实参推断被跳过）。
外层若是模块限定 / 方法调用（`checker.cr:2623` 有推实参）或 extern / 未解析，实参被推断，因此安全。

### 2.2 日常形态（反直觉）

| 形 | 结果 |
|---|---|
| `println(fmt.int_str(7))` | 通过（`println` 走 extern/未解析路径，因此推实参） |
| `show(p.get())` / `log2(fmt.int_str(7))`（自己的 helper） | 139 |

因此最外层使用 stdlib I/O 反而安全；增加一层自己的 helper 反而崩溃。

## 3. 是否与 apx 批相邻：否（三方差分）

| 二进制 | `str_eq(fmt.int_str(7), "7")` | `.cir` 内层名 |
|---|---|---|
| apx 批 T3 当前 | 139 | `import` |
| apx 批改动前（develop） | 139 | `import` |
| 固定基线 `97f4394f` | 139 | `import` |

因此三者同样崩溃，内层名相同，非 apx 批引入。apx 批的环门读 `find_func(func_ni)`，此处 `func_ni = 0`，因此 `find_func(0) = -1`，因此环不进（与改前同行为）；apx 批未改 checker。

同族历史：这正是 I-3（「模块限定调用生成对伪函数 `"import"` 的调用」，2026-08-29）在 bootstrap 侧修过的同族缺陷（"bootstrap 保留导入元数据并按 alias 解析限定调用"），selfhost 侧从未修此面，`tests/bootstrap/test_modules.py` 的覆盖也只在 bootstrap 面。

## 4. 修法候选（本调查不实施）

### (a) 补实参推断（根因修，推荐主体）
- 做法：把 `:2833-2839` 的循环抽成小函数，在 `:2817`（及其它「已解析」return 点）之前调用。
- 改动面：`checker.cr` 一处 + 一个小函数。
- 风险（必须显式设防）：行为放大，实参一旦被真正推断，此前无提示通过的形态会开始出诊断（`g(nosuchfn(1))`，报出 `error[N06]`；类型不符也可能开始报），因此现有语料 `check` 可能由通过变为失败。
因此规则是：检查组1 全语料逐档对照 + 每一条新诊断逐条归因（哪条是「本来就该报的」、哪条是「新引入的误报」）。不许把新增诊断一律当成「修好的证据」（本仓「检查范围混类」之防）。归因不清时停下并上报。
- 检查：检查组 A 各例从 139 变为精确值；检查组 B `g1` 由「零诊断」，报出 `error[N06]`（这一条是「修好了」的正面证据，缺了它本批只修了一半）；检查组1 差异逐条归因；canary / `.ccr` 不变。

### (b) fail-closed 护栏（回退，建议同批）
- 做法：`ir_gen` 的 EXPR_CALL 处，callee 是 `EXPR_FIELD` 且 `ast_data(node) <= 0`（从未被解析），因此报硬错 + 拒绝产物。
- 改动面：`ir_gen.cr` 一处（小）。风险：低；但只把无提示 139 变明确，不修根因，因此按规则「不许绕过」应与 (a) 组合。
- 检查：139 变为 rc=1 + 定位诊断（不得无提示）；通过形态与 canary 不变。

### (c) 预先回填名字（备选方案）
- 做法：parser 构造 `EXPR_CALL` 时，若 callee 是 `EXPR_FIELD` 且 obj 是模块符号，因此立即写 `ast_data`。
- 前提未实证：需模块符号在 parse 期可用（`res_imports` 在 parse 前跑，但符号注册时序未核），因此不可行则本路作废。
- 检查：同 (b) 的 139 例；但 `g1` 仍不报 N06，因此只解决表面问题。

推荐：(a) 为主 + (b) 回退；(c) 备选方案。

## 5. 入仓探针（RED 语料）

`tests/selfhost/test_arg_inference_gap.py`，19 例：检查组 A（139 面）9 例、检查组 B（无提示面）1 例、对照 9 例。
注意：未挂 CI（`tests/harness/ci_hook_allowlist.txt` 有对应条目，注明理由）；修复批次实现时必须同时：1 删该允许清单条目 2 在 `src/ci/run.sh` 挂本套件 3 改文件头注为「已修」。

当前观测矩阵（本文件写进文档时，`build/corec` = develop `0808a8ca`）：

| # | 探针 | 观测 | 修后期望 |
|---|---|---|---|
| A1 | `str_eq(fmt.int_str(7), "7")` | check=0 · elf=139 | elf=0 |
| A2 | `str_eq(fmt.int_str(7), fmt.int_str(7))` | check=0 · 139 | 0 |
| A3 | `m_eq(s.m(6), 7)`（方法作实参） | check=0 · 139 | 0 |
| A4 | `one(fmt.int_str(7))`（helper 收模块调用） | check=0 · 139 | 0 |
| A5 | `show(p.get())`（helper 收方法调用） | check=0 · 139 | 0 |
| A6 | `str_neq_3(fmt.int_str(7), "7", 1)`（三参外层） | check=0 · 139 | 0 |
| A7 | `b := str_eq(fmt.int_str(7), "7")`（实参在 LET 里） | check=0 · 139 | 0 |
| A8 | 同上但实参在 `if` 条件里 | check=0 · 139 | 0 |
| A9 | `log2(fmt.int_str(7))`（helper 包 `println`） | check=0 · 139 | 0 |
| B1 | `g(nosuchfn(1))`（实参含未定义函数） | check=0 · codes=[] （无提示） · 运行时亦 139 | check=1 · codes={N06} |
| C1 | `x := fmt.int_str(7); str_eq(x, "7")` | 0 | 0（对照） |
| C2 | `x := fmt.int_str(7);`（独立语句） | 0 | 0 |
| C3 | `println(fmt.int_str(7))`（外层 stdlib I/O） | 0 | 0 |
| C4 | `str_eq(int_str(7), "7")`（直调嵌套） | 0 | 0 |
| C5 | `ieq(idf(7), 7)`（泛型实例化嵌套） | 0 | 0 |
| C6 | `if !str_eq(int_str(7), "7")` | 0 | 0 |
| C7 | `fmt.int_str(nosuchfn(1))`（外层模块调用，因此推实参） | check=1 · {N06} | {N06}（对照：当前即报） |
| C8 | `seven()`（位置无关性） | 7 | 7 |
| C9 | `s.m2(nosuchfn(1))`（外层方法调用，因此推实参） | check=1 · {N06} | {N06}（对照） |

，因此 C7/C9 是对照组的关键：它们证明「推实参」这条链本来就在（在模块/方法分支里），只是直调分支没接上。

## 6. 未决项

| # | 内容 |
|---|---|
| U1 | (a) 的行为放大面到底有多大，需在实施批做检查组1 全语料对照才能定（本调查为只读，未跑） |
| U2 | `func_ni < 0` 路径的 `return TI_NEVER`（`:2831`）同样在推实参之前，因此该路径下实参也不推断（`nosuchouter(nosuchfn(1))` 只报外层一条）。(a) 的范围是否覆盖此点须定 |
| U3 | (c) 的前提「模块符号 parse 期可用」未实证 |
| U4 | 是否还有第三个「提前 return 但该推实参」的点（本调查只逐行核了直调分支；模块/方法分支已确认有推） |
