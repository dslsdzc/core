# McTT → Core 验证内核移植实现计划（M1）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
> **注意：Task 6（src/kernel/ 内核本体移植）由项目维护者 DslsDZC 手工执行，不由 agent 代做。** 其余任务（1–5、7）由 agent 执行。

**Goal:** 将 McTT（ICFP'25 全验证 MLTT 内核）照抄移植为 Core 实现，通过术语级差分测试验证与 OCaml 参考逐位一致，作为语义保鲜验证管线的信任根。

**Architecture:** 信任根 = 规范转写（kernel-spec.md，移植契约）+ 验证继承（McTT 的 Rocq 定理）+ 差分对拍（同一语料驱动 OCaml 参考与 Core 实现，输出逐位一致）。M1 只做内核本体（Π + ℕ + 累积宇宙 + NbE + 显式替换），不做前端、不做证书管线。

**Tech Stack:** OCaml（McTT 提取代码，dune 构建）、Core 语言（src/kernel/，build/corec 编译）、Python 3（语料生成与差分脚本）。

**Spec:** `docs/superpowers/specs/2026-08-15-mctt-core-kernel-design.md`

## Global Constraints

- **禁止 git**，全部用 `jj`（仓库铁律 #2）；提交信息中文
- 长时间编译/构建必须 `cpulimit -l 10` 或 `nice -n 19` 包裹（仓库铁律 #6）——本计划中所有 dune 构建命令已带
- Core 编译：`./build/corec build FILE.cr -o OUT --static`（工作目录 = 仓库根）
- McTT 参考代码克隆到仓库外 `~/mctt`（不提交）；我们的 harness 在仓库内 `tools/mctt_ref/`
- 术语表示契约（Task 5/6 共同遵守）：扁平节点布局 `{kind, a, b, c, d}`（int），节点存全局 arena `g_kernel_nodes: [int; 8192]`，kind 常量与布局定义在 `src/kernel/term_io.cr`（Task 5 产出），内核代码 import 它
- 查询/输出格式协议：见 Task 3（本计划内定死，两侧实现到同一协议）
- 差分输出只比 accept/reject + 规范化类型文本，不比错误消息（设计文档 §七）

---

### Task 1: 拉取并构建 McTT 参考侧

**Files:**
- Create: `~/mctt`（克隆 McTT 仓库，icfp25 分支）
- 参考实现：McTT driver（OCaml 提取代码，含类型检查器）

**Interfaces:**
- Produces: 可运行的 McTT driver（`~/mctt/driver/_build/default/Main.exe`），后续 Task 3 的 harness 将依赖其提取模块

- [ ] **Step 1: 克隆并检出**

```bash
git clone https://github.com/Beluga-lang/McTT ~/mctt
cd ~/mctt && git checkout icfp25
```

> 说明：克隆 McTT 仓库本身用 git 是允许的（这是第三方仓库操作，不是本仓库的版本控制；本仓库的提交一律 jj）。若 `git` 被 hook 拦截，改用：
> `curl -sL https://github.com/Beluga-lang/McTT/archive/refs/heads/icfp25.tar.gz | tar xz -C ~/ && mv ~/McTT-icfp25 ~/mctt`

- [ ] **Step 2: 检查提取代码是否自带（应已含，无需 Coq 构建）**

```bash
ls ~/mctt/driver/extracted/
ls ~/mctt/driver/dune
```

Expected: `extracted/` 下有 `.ml`/`.mli` 文件与自己的 dune 文件；driver 的 dune 引用它们。若 `extracted/` 为空，则需先 `opam install coq-mctt` 或按 `~/mctt/README.md` 从 Rocq 构建——遇到此情况停下报告，不自行尝试 Coq 全量构建。

- [ ] **Step 3: 构建 driver（限 CPU）**

```bash
cd ~/mctt/driver && nice -n 19 dune build 2>&1 | tail -20
```

Expected: 构建成功，无致命错误。产出 `_build/default/Main.exe`。

- [ ] **Step 4: 冒烟测试：跑 McTT 自带例子**

```bash
cd ~/mctt/driver && ./_build/default/Main.exe ../examples/simple_nat.mctt
```

Expected: 输出类型检查结果（接受）。若命令用法不同，读 `Main.ml` 顶部注释确认参数格式。

- [ ] **Step 5: 记录参考侧验证点**

在 `tools/mctt_ref/README.md`（新建）中记录：构建命令、Main.exe 用法、extracted 模块清单（`ls driver/extracted/*.mli` 的输出粘进去）。这是 Task 3 的输入。

- [ ] **Step 6: 提交**

```bash
cd /home/DslsDZC/core && jj commit -m "tools: McTT 参考侧构建记录（Task 1）"
```

---

### Task 2: 规范转写 kernel-spec.md（移植契约）

**Files:**
- Create: `docs/verifier/kernel-spec.md`
- Read（对照源，转写不二手）：`~/mctt/theories/Core/Syntactic/Syntax.v`、`~/mctt/theories/Core/Syntactic/System.v`、`~/mctt/theories/Core/Syntactic/System/Definitions.v`、`~/mctt/theories/Algorithmic/Typing/Definitions.v`、`~/mctt/theories/Algorithmic/Subtyping/Definitions.v`、`~/mctt/theories/Core/Semantic/{Domain,Evaluation,Readback}/Definitions.v`

**Interfaces:**
- Produces: `docs/verifier/kernel-spec.md`——类型规则、算法规则、NbE 结构、子类型规则的逐条转写，每条带 `源文件:行号` 交叉引用；**上下文/de Bruijn 约定必须在本任务确认并写死**（Task 3 协议与 Task 6 移植都以它为准）

- [ ] **Step 1: 通读 Syntax.v 与 System.v，写出术语/子术语/正规形/中性形的构造子清单**

在 spec 中逐条列出（exp/sub/nf/ne 的构造子、参数、含义），每条标注 `Syntax.v:行号`。同时确认：de Bruijn 索引方向、上下文序（var 0 = 上下文最右元素？）、`q` 替换的定义（`Syntax.v` 中 `Definition q`）。

- [ ] **Step 2: 转写类型规则（System/Definitions.v）**

每条推导规则：结论 `Γ ⊢ t : T` 的规则名、前提、条件。格式：规则名 + 前提列表 + 结论 + 源位置。

- [ ] **Step 3: 转写算法化规则（Algorithmic/Typing/Definitions.v）**

双向类型检查的检查模式（`Γ ⊢ t ⇐ T`）与推断模式（`Γ ⊢ t ⇒ T`）的全部规则，逐条标注源位置。

- [ ] **Step 4: 转写子类型（Algorithmic/Subtyping/Definitions.v）**

累积宇宙 `Type_i ≤ Type_j (i ≤ j)`、Π 逆变/协变规则、判定算法结构。

- [ ] **Step 5: 转写 NbE 结构（Semantic/{Domain,Evaluation,Readback}/Definitions.v）**

语义域定义（闭项/开放项的表示）、求值函数结构、读出函数结构、正常形/中性形判定、转换判定（`t ≡ u : T`）的完整算法描述。

- [ ] **Step 6: 自检**

对 spec 全文核对：每个构造子、每条规则都有来源行号；无「待定」「类似上面」类描述；de Bruijn/上下文约定明确写出。修正后，在 spec 头部注明「本文件由 Task 2 生成，行号对应 McTT icfp25 分支」。

- [ ] **Step 7: 提交**

```bash
cd /home/DslsDZC/core && jj commit -m "docs: kernel-spec 规范转写（McTT→Core 移植契约）"
```

---

### Task 3: 共享格式协议 + OCaml 参考 harness

**Files:**
- Create: `tools/mctt_ref/protocol.md`（协议，定死）
- Create: `tools/mctt_ref/harness.ml`（读查询文件 → 调提取检查器 → 规范输出）
- Create: `tools/mctt_ref/dune`
- Test: `tools/mctt_ref/smoke.txt` + `tools/mctt_ref/smoke.expected`

**Interfaces:**
- Consumes: Task 1 的 `~/mctt` 构建产物与模块清单
- Produces: 可执行 `tools/mctt_ref/harness.exe`；协议文档（Task 4 语料生成器与 Task 5 term_io.cr 都按它实现）

**协议（本任务定死，写进 protocol.md 与后续所有任务）：**

```
查询文件：每行一条查询
  check   <ctx> <exp> <exp>
  infer   <ctx> <exp>
  convert <ctx> <exp> <exp> <exp>
  subtype <ctx> <exp> <exp>
语法：
  <ctx> ::= (ctx <exp>*)            # 空上下文 (ctx)
  <exp> ::= (typ N) | (nat) | (zero) | (succ <exp>) | (natrec <exp> <exp> <exp> <exp>)
          | (pi <exp> <exp>) | (fn <exp> <exp>) | (app <exp> <exp>) | (var N) | (sub <exp> <sub>)
  <sub> ::= (id) | (weaken) | (compose <sub> <sub>) | (extend <sub> <exp>)
  N     ::= 非负十进制整数
输出：每查询一行
  check:    accept | reject
  infer:    type: <nf-exp> | reject
  convert:  yes | no
  subtype:  yes | no
  <nf-exp> 用同一 S-表达式语法打印（正规化后的正常形/中性形）
de Bruijn 约定：以 kernel-spec.md（Task 2）为准
```

- [ ] **Step 1: 写 protocol.md**

内容 = 上面协议块（含 Task 2 确认的 de Bruijn 约定与一行示例）。

- [ ] **Step 2: 侦查提取模块的入口签名**

```bash
cd ~/mctt/driver && cat dune && ls extracted/*.mli 2>/dev/null && grep -n "module\|val " extracted/*.mli 2>/dev/null | head -60
```

若 `.mli` 不存在，用 `grep -rn "let check\|let infer\|let subtype\|let convert" extracted/*.ml | head -20` 找函数名。Expected: 找到类型检查入口（来自 `theories/Extraction/TypeCheck.v`）、子类型入口、NbE/转换入口，以及术语类型的构造子名（`Typ`/`Nat`/`Zero`/`Succ`/`NatRec`/`Pi`/`Fn`/`App`/`Var`/`Sub` 一类）。**把找到的真实模块名与函数名记录到 `tools/mctt_ref/README.md`（更新 Task 1 建的），后续步骤按真实名接线**；若名字与预期不同，以 grep 结果为准。

- [ ] **Step 3: 写 harness.ml**

结构：读行 → 解析（手写 ~80 行 S-表达式解析器，产出提取模块的术语值）→ 分发到 check/infer/convert/subtype → 打印规范输出（类型结果经读出/正规化后打印）。关键接线点：
- 解析器把 `(typ N)` 映射到提取模块的宇宙构造子，`(natrec A mz ms n)` 映射到 NatRec 构造子（构造子字段顺序以提取代码为准，Step 2 侦查确认）
- 推断输出必须正规化：用提取的求值+读出函数（或转换判定自带的正常化路径）把结果化为 nf 再打印
- 上下文：解析 `(ctx e1 e2 ...)` 为提取模块的 context 类型（顺序按 kernel-spec.md 约定）
- 拒绝路径统一打印 `reject`；convert/subtype 打印 `yes|no`

harness.ml 全文在此任务的执行中按 Step 2 的真实签名完成；本步骤的验收标准 = Step 4 冒烟通过。

- [ ] **Step 4: 写 dune 并构建（限 CPU）**

```bash
cat > tools/mctt_ref/dune <<'EOF'
(executable
 (name harness)
 (libraries mctt_driver))   # 以 Step 2 侦查到的实际库名/依赖为准
EOF
cd ~/mctt/driver && cp /home/DslsDZC/core/tools/mctt_ref/harness.ml . && nice -n 19 dune build harness.exe 2>&1 | tail -20
```

若库名不对，读 `~/mctt/driver/dune` 与 `~/mctt/driver/extracted/dune` 的 `(libraries ...)`/`(modules ...)` 修正。产出 `harness.exe`（放 `~/mctt/driver/_build/default/`）。

- [ ] **Step 5: 冒烟测试**

写 `tools/mctt_ref/smoke.txt`：

```
check (ctx) (zero) (nat)
check (ctx) (zero) (typ 0)
infer (ctx) (succ (zero))
infer (ctx) (app (fn (nat) (var 0)) (zero))
convert (ctx) (nat) (nat) (typ 1)
subtype (ctx) (typ 0) (typ 1)
check (ctx) (app (fn (nat) (var 0)) (zero)) (typ 0)
```

运行 harness，人工核验前七行应为：

```
check: accept
check: reject
infer: type: (nat)
infer: type: (nat)
convert: yes
subtype: yes
check: reject
```

（第 7 行 `fn (nat) (var 0)` 的类型是 `(pi (nat) (nat))`，不是 `(typ 0)`，故 reject——若实际输出不同，记录实际值作为 ground truth，后续语料以 McTT 为准，不以本表为准。）`smoke.expected` 内容 = 实际核验后的七行。

- [ ] **Step 6: 提交**

```bash
cd /home/DslsDZC/core && jj commit -m "tools: 参考侧 harness + 共享格式协议（术语级差分）"
```

---

### Task 4: 语料生成器（穷举 + 随机 + 案卷）

**Files:**
- Create: `tests/kernel/gen_corpus.py`（生成查询文件，不含期望值）
- Create: `tests/kernel/cases/corpus_exhaustive.txt`、`corpus_random.txt`、`corpus_manual.txt`（生成物）
- Create: `tests/kernel/README.md`（语料说明与固定种子）

**Interfaces:**
- Consumes: 协议（Task 3 的 protocol.md）——生成器输出必须被 harness 与 term_io 都能解析
- Produces: 三个语料文件；期望值在 Task 7 由参考 harness 生成并固化

- [ ] **Step 1: 写穷举生成器（exact code）**

`tests/kernel/gen_corpus.py`：

```python
import itertools, random

K_TYP, K_NAT, K_ZERO, K_SUCC, K_NATREC, K_PI, K_FN, K_APP, K_VAR, K_SUB = range(10)
S_ID, S_WEAKEN, S_COMPOSE, S_EXTEND = range(4)

def size(t):  # 节点计数（含 sub 节点）
    k = t[0]
    if k in (K_NAT, K_ZERO): return 1
    if k in (K_SUCC, K_FN, K_APP, K_VAR): return 1 + size(t[1])
    if k in (K_PI,): return 1 + size(t[1]) + size(t[2])
    if k == K_NATREC: return 1 + size(t[1]) + size(t[2]) + size(t[3]) + size(t[4])
    if k == K_SUB: return 1 + size(t[1]) + ssize(t[2])
    raise ValueError(k)

def ssize(s):
    k = s[0]
    if k in (S_ID, S_WEAKEN): return 1
    if k == S_COMPOSE: return 1 + ssize(s[1]) + ssize(s[2])
    if k == S_EXTEND: return 1 + ssize(s[1]) + size(s[2])

def show_exp(t):
    k = t[0]
    if k == K_TYP: return f"(typ {t[1]})"
    if k == K_NAT: return "(nat)"
    if k == K_ZERO: return "(zero)"
    if k == K_SUCC: return f"(succ {show_exp(t[1])})"
    if k == K_NATREC: return f"(natrec {show_exp(t[1])} {show_exp(t[2])} {show_exp(t[3])} {show_exp(t[4])})"
    if k == K_PI: return f"(pi {show_exp(t[1])} {show_exp(t[2])})"
    if k == K_FN: return f"(fn {show_exp(t[1])} {show_exp(t[2])})"
    if k == K_APP: return f"(app {show_exp(t[1])} {show_exp(t[2])})"
    if k == K_VAR: return f"(var {t[1]})"
    if k == K_SUB: return f"(sub {show_exp(t[1])} {show_sub(t[2])})"

def show_sub(s):
    k = s[0]
    if k == S_ID: return "(id)"
    if k == S_WEAKEN: return "(weaken)"
    if k == S_COMPOSE: return f"(compose {show_sub(s[1])} {show_sub(s[2])})"
    if k == S_EXTEND: return f"(extend {show_sub(s[1])} {show_exp(s[2])})"

def gen_exps(max_size):
    out = {1: [(K_NAT,), (K_ZERO,), (K_VAR, 0), (K_VAR, 1), (K_TYP, 0), (K_TYP, 1)]}
    for n in range(2, max_size + 1):
        res = []
        for i in range(1, n):
            j = n - i
            for a in out.get(i, []): 
                for b in out.get(j, []):
                    res += [(K_SUCC, a), (K_FN, a, b), (K_APP, a, b), (K_PI, a, b)]
        res += [(K_NATREC, a, b, c, d) for a in out.get(1,[]) for b in out.get(1,[]) for c in out.get(1,[]) for d in out.get(1,[]) if n == 1+size(a)+size(b)+size(c)+size(d)]
        res += [(K_SUB, a, (S_ID,)) for a in out.get(n-1, [])]
        seen = set()
        out[n] = []
        for x in res:                       # 按 show_exp 文本去重
            s = show_exp(x)
            if s not in seen:
                seen.add(s)
                out[n].append(x)
    return [t for n in range(1, max_size + 1) for t in out.get(n, [])]
```

（注：natrec 组合处保持简单——只枚举 a,b,c,d 均为 size-1 项的组合，覆盖归约路径即可；完整枚举在随机层补。）

- [ ] **Step 2: 写查询发射逻辑**

对每个穷举项 t（size ≤ 4）发射：
- `infer (ctx) {t}`
- `check (ctx) {t} (nat)` 与 `check (ctx) {t} (typ 0)`
- `convert (ctx) {t} (nat) (typ 0)`（仅对前 50 项）
对类型形态的项（首构造子为 pi/typ/nat 的）额外发 `subtype (ctx) {t} (nat)` 与 `subtype (ctx) (nat) {t}`。
对 (ctx (nat)) 与 (ctx (typ 0)) 上下文重复发射 infer/check。输出 `corpus_exhaustive.txt`，行首带 `#` 注释标明来源层。

- [ ] **Step 3: 写随机生成器**

```python
def rand_exp(rng, depth, max_var):
    k = rng.randrange(10)
    if k in (K_NAT, K_ZERO): return (k,)
    if k == K_VAR: return (K_VAR, rng.randrange(max_var))
    if k in (K_SUCC, K_FN, K_APP, K_PI) and depth > 0:
        a = rand_exp(rng, depth-1, max_var); b = rand_exp(rng, depth-1, max_var)
        return (k, a) if k == K_SUCC else (k, a, b)
    if k == K_NATREC and depth > 1:
        return (K_NATREC, rand_exp(rng, depth-2, max_var), rand_exp(rng, depth-2, max_var),
                rand_exp(rng, depth-2, max_var), rand_exp(rng, depth-2, max_var))
    if k == K_SUB and depth > 0:
        return (K_SUB, rand_exp(rng, depth-1, max_var), rng.choice([(S_ID,), (S_WEAKEN,)]))
    return (K_NAT,)
```

固定种子 `seed=20260815`，生成 1200 条随机查询（infer 为主 + check/convert/subtype 混合），上下文随机选自 `(ctx)`、`(ctx (nat))`、`(ctx (typ 0))`、`(ctx (nat) (nat))`。输出 `corpus_random.txt`。

- [ ] **Step 4: 写案卷（≥ 20 条，exact content）**

`corpus_manual.txt`，至少包含（编号从 1 起，全部具体写出）：

```
1  check (ctx) (zero) (nat)                                          # 基例检查
2  check (ctx) (zero) (typ 0)                                        # 类型错误
3  infer (ctx) (succ (succ (zero)))                                  # 嵌套 succ
4  check (ctx) (app (fn (nat) (var 0)) (zero)) (nat)                 # β 归约后正确
5  check (ctx) (app (fn (nat) (var 0)) (zero)) (typ 0)               # 类型不匹配
6  check (ctx) (app (var 0) (zero)) (nat)                            # 变量类型未知（ctx 空）
7  check (ctx (nat)) (app (var 0) (zero)) (nat)                      # 上下文中变量可用
8  infer (ctx) (fn (nat) (nat) (var 0))                              # λ 推断
9  check (ctx) (fn (nat) (nat) (var 0)) (pi (nat) (nat))             # Π 检查
10 check (ctx) (fn (nat) (typ 0) (var 0)) (pi (nat) (typ 0))         # 陪域宇宙
11 subtype (ctx) (typ 0) (typ 1)                                     # 累积
12 subtype (ctx) (typ 1) (typ 0)                                     # 反向拒绝
13 subtype (ctx) (nat) (nat)                                         # 自反
14 convert (ctx) (app (fn (nat) (var 0)) (zero)) (zero) (nat)        # β 转换
15 convert (ctx) (pi (nat) (nat)) (pi (nat) (nat)) (typ 1)           # Π 自反
16 infer (ctx) (natrec (nat) (zero) (fn (nat) (nat) (succ (var 0))) (succ (zero)))   # natrec 全展开
17 check (ctx) (natrec (nat) (zero) (fn (nat) (nat) (succ (var 0))) (zero)) (nat)    # natrec zero 分支
18 check (ctx) (sub (var 0) (weaken)) (nat)                          # 显式替换：weaken
19 check (ctx (nat) (nat)) (sub (var 0) (compose (weaken) (id))) (nat)   # 替换组合
20 infer (ctx) (sub (succ (var 0)) (extend (id) (zero)))             # extend 替换
21 check (ctx) (fn (nat) (typ 1) (var 0)) (pi (nat) (typ 1))         # 高宇宙
22 infer (ctx) (app (fn (typ 0) (var 0)) (nat))                      # 宇宙作为类型（多层）
23 check (ctx (typ 0)) (var 0) (typ 1)                               # 上下文类型变量
24 convert (ctx) (sub (var 0) (extend (id) (zero))) (zero) (nat)     # q 替换展开
25 check (ctx) (nat) (typ 0)                                         # 类型 Type
```

第 16 条预期推断为 `(nat)`；全部条目的期望值由参考 harness 生成固化（Task 7），不以本表人工预期为准（人工预期只在 Step 5 冒烟用）。

- [ ] **Step 5: 运行生成器并统计**

```bash
cd /home/DslsDZC/core && python3 tests/kernel/gen_corpus.py && wc -l tests/kernel/cases/*.txt
```

Expected: `corpus_exhaustive.txt` ≥ 300 行，`corpus_random.txt` = 1200 行，`corpus_manual.txt` = 25 行。写 `tests/kernel/README.md` 记录种子与统计。

- [ ] **Step 6: 提交**

```bash
cd /home/DslsDZC/core && jj commit -m "tests: 内核差分语料生成器（穷举+随机+案卷）"
```

---

### Task 5: Core 侧 term_io.cr（格式读取器 + 打印器）

**Files:**
- Create: `src/kernel/term_io.cr`（协议实现：S-表达式解析 → 扁平 arena；扁平节点 → 规范文本）
- Test: `src/kernel/test_term_io.cr`（用 `./build/corec run` 直跑）

**Interfaces:**
- Consumes: 协议（Task 3 protocol.md）；Task 2 的 de Bruijn 约定
- Produces: 全局 `g_kernel_nodes: [int; 8192]`（{kind,a,b,c,d} 五槽一组，节点索引 = 槽起点/5）、kind 常量（`K_TYP=0 K_NAT=1 K_ZERO=2 K_SUCC=3 K_NATREC=4 K_PI=5 K_FN=6 K_APP=7 K_VAR=8 K_SUB=9`；sub 用 `S_ID=0 S_WEAKEN=1 S_COMPOSE=2 S_EXTEND=3` 存于节点 d 槽）、`kernel_parse(text: string) -> int`（返回根节点索引，失败返回 -1）、`kernel_print(idx: int) -> string`（节点 → S-表达式文本）。Task 6 的内核代码 import 本文件的常量与 arena。

- [ ] **Step 1: 核对 Core stdlib API 名**

```bash
grep -n "^fn \|^pub fn " src/stdlib/fmt.cr | head -30; grep -n "fn str_len\|fn chr\|fn int_str" src/stdlib/fmt.cr src/stdlib/io.cr
```

Expected: 确认 `str_len(s)`、`chr(n)`、`int_str(n)`、字符串比较/拼接可用；记录到本任务执行笔记。若名字不同，以下代码按实际 API 调整（签名一致即可，行为不变）。

- [ ] **Step 2: 写 term_io.cr（exact code）**

```core
// src/kernel/term_io.cr —— 共享格式协议实现（Task 5）
// 扁平 arena：g_kernel_nodes 五槽一组 {kind, a, b, c, d}，索引 = 起始槽
// 槽 0..4 = 节点 0，槽 5..9 = 节点 1，……
g_kernel_nodes : [int; 8192] = [0; 8192]
g_kernel_count : int = 0

// 常量
K_TYP : int = 0
K_NAT : int = 1
K_ZERO : int = 2
K_SUCC : int = 3
K_NATREC : int = 4
K_PI : int = 5
K_FN : int = 6
K_APP : int = 7
K_VAR : int = 8
K_SUB : int = 9
S_ID : int = 0
S_WEAKEN : int = 1
S_COMPOSE : int = 2
S_EXTEND : int = 3

fn kern_new(k: int) -> int:
    i := g_kernel_count * 5
    g_kernel_nodes[i] = k
    g_kernel_nodes[i+1] = 0
    g_kernel_nodes[i+2] = 0
    g_kernel_nodes[i+3] = 0
    g_kernel_nodes[i+4] = 0
    g_kernel_count = g_kernel_count + 1
    return i
fn kern_set(n: int, slot: int, v: int):
    g_kernel_nodes[n + slot] = v
fn kern_get(n: int, slot: int) -> int:
    return g_kernel_nodes[n + slot]
```

（解析与打印函数在本任务执行中补齐：`kernel_parse` 手写递归下降（跳过空白、读 `(token ...)`、数字用 `int_str` 反向解析——`str_to_int` 若无则用逐位 `(ch-'0')` 累加）；`kernel_print` 按协议对节点递归打印，var/succ 等单子节点直接递归。测试先写。）

- [ ] **Step 3: 写测试并运行**

`src/kernel/test_term_io.cr`（main 里对三个固定字符串调用 kernel_parse 再 kernel_print，比对往返一致）：

```
输入: (succ (succ (zero)))   → 往返必须等于原文
输入: (natrec (nat) (zero) (fn (nat) (nat) (succ (var 0))) (succ (zero)))
输入: (sub (var 0) (compose (weaken) (id)))
```

```bash
cd /home/DslsDZC/core && ./build/corec run src/kernel/test_term_io.cr
```

Expected: 打印往返一致（三行全部与原输入相同）。失败则修解析/打印。

- [ ] **Step 4: 协议互验**

把 `tests/kernel/cases/corpus_manual.txt` 前 3 行喂给 term_io（写一个临时 main 打印 `kernel_parse` 结果），再人工核对第 16 条 `infer` 术语解析后打印一致。Expected: 解析成功（无 -1）。

- [ ] **Step 5: 提交**

```bash
cd /home/DslsDZC/core && jj commit -m "src: term_io 共享格式读取器/打印器（协议实现）"
```

---

### Task 6: 用户手工移植内核本体（DslsDZC 执行）

**Files:**
- Create: `src/kernel/mctt.cr`（arena 访问辅助、kind 常量复用 term_io、上下文结构）
- Create: `src/kernel/subst.cr`（显式替换操作：id/weaken/compose/extend 的语义实现）
- Create: `src/kernel/nbe.cr`（求值 + 读出：语义域、正常形/中性形）
- Create: `src/kernel/subtype.cr`（协变子类型判定）
- Create: `src/kernel/check.cr`（双向类型检查：检查 + 推断）
- Create: `src/kernel/kernel_main.cr`（CLI：读查询文件 → 分发 → 输出协议格式）
- Test: `src/kernel/test_kernel.cr`（冒烟：零/继承/应用/natrec 的 check/infer）

**Interfaces:**
- Consumes: `term_io.cr` 的常量/arena/parse/print（Task 5）；`docs/verifier/kernel-spec.md`（Task 2，逐规则移植）；`~/mctt/driver/extracted/`（行为参考）
- Produces: `kernel_main` 可执行（`./build/corec build src/kernel/kernel_main.cr -o build/kernel --static`），输出 = Task 3 协议

**本任务由维护者手工执行（非 agent）。执行节奏（每文件一个 checkpoint）：**

- [ ] **Step 1: mctt.cr**——术语/上下文的数据结构与辅助函数；对照 kernel-spec.md 的构造子清单；`./build/corec check` 通过后进入下一步
- [ ] **Step 2: subst.cr**——显式替换语义（对照 spec 的替换规则）；用 term_io 造测试项冒烟（如案卷 18/19/20 的替换项），`./build/corec run` 通过
- [ ] **Step 3: nbe.cr**——求值 + 读出（对照 spec 的 NbE 结构）；冒烟：`convert` 案卷 14/24 语义
- [ ] **Step 4: subtype.cr**——子类型判定（案卷 11/12/13 冒烟）
- [ ] **Step 5: check.cr**——双向类型检查（案卷 1–10、16–17 冒烟）
- [ ] **Step 6: kernel_main.cr**——CLI 接线 + 协议输出；`./build/corec build src/kernel/kernel_main.cr -o build/kernel --static` 成功
- [ ] **Step 7: 全案卷自跑**——`./build/kernel tests/kernel/cases/corpus_manual.txt` 无崩溃；输出与人工预期目测一致即可（正式对拍在 Task 7）
- [ ] **Step 8: 提交**

```bash
cd /home/DslsDZC/core && jj commit -m "src: McTT→Core 内核移植（mctt/subst/nbe/subtype/check/main）"
```

---

### Task 7: 差分对拍 + 全绿验收

**Files:**
- Create: `tests/kernel/run_diff.py`（三语料 × 两侧 → 逐行比对）
- Create: `tests/kernel/expected/*.expected`（参考 harness 生成的期望值，静态固化）

**Interfaces:**
- Consumes: harness（Task 3）、语料（Task 4）、kernel_main（Task 6）
- Produces: 差分报告；M1 完成判定

- [ ] **Step 1: 生成期望值**

```bash
cd ~/mctt/driver && for f in exhaustive random manual; do
  ./_build/default/harness.exe /home/DslsDZC/core/tests/kernel/cases/corpus_$f.txt > /home/DslsDZC/core/tests/kernel/expected/corpus_$f.expected
done
wc -l /home/DslsDZC/core/tests/kernel/expected/*.expected
```

Expected: 行数与语料一致。

- [ ] **Step 2: 写 run_diff.py（exact code）**

```python
import subprocess, sys, pathlib

CORE = pathlib.Path("/home/DslsDZC/core")
HARNESS = "/home/DslsDZC/mctt/driver/_build/default/harness.exe"
KERNEL = str(CORE / "build/kernel")

def run(cmd, inp):
    p = subprocess.run(cmd, input=inp, capture_output=True, text=True)
    return p.stdout.splitlines()

def main():
    cases = CORE / "tests/kernel/cases"
    expd = CORE / "tests/kernel/expected"
    fails = []
    total = 0
    for name in ["exhaustive", "random", "manual"]:
        txt = (cases / f"corpus_{name}.txt").read_text()
        exp = (expd / f"corpus_{name}.expected").read_text().splitlines()
        a = run([HARNESS], txt)
        b = run([KERNEL], txt)
        assert len(a) == len(exp) == len(b), (name, len(a), len(exp), len(b))
        for i, (x, y, e) in enumerate(zip(a, b, exp)):
            total += 1
            if x != e or y != e:
                fails.append((name, i, x, y, e))
    print(f"total={total} ok={total-len(fails)} fail={len(fails)}")
    for f in fails[:20]:
        print(f)
    sys.exit(1 if fails else 0)

main()
```

- [ ] **Step 3: 跑对拍**

```bash
cd /home/DslsDZC/core && python3 tests/kernel/run_diff.py
```

Expected 第一轮：`fail > 0`（Core 侧尚未对齐）。逐类排查：
- 两侧都 ≠ 期望 → 期望固化问题（回到 Step 1 检查 harness 输出）
- 仅 Core ≠ 期望 → 内核 bug：对照 kernel-spec.md 对应规则修复（用户或 agent 协作定位，差分失败行即线索）

- [ ] **Step 4: 修复至全绿**

循环：修 → 重跑 → 直到 `total=… ok=… fail=0`。注意规则：**不许改期望值迁就 Core**——期望 = McTT ground truth，唯一可改的是内核。

- [ ] **Step 5: 验收清单**

- [ ] 穷举层全绿（corpus_exhaustive）
- [ ] 随机 ≥ 1000 条全绿（corpus_random = 1200）
- [ ] 案卷 ≥ 20 条全绿（corpus_manual = 25）
- [ ] `docs/verifier/kernel-spec.md` 与 Rocq 源码逐规则对应（Task 2 完成时已核）
- [ ] 理论范围无增删（Π + ℕ + 累积宇宙 + NbE + 显式替换）

- [ ] **Step 6: 提交并记录**

```bash
cd /home/DslsDZC/core && jj commit -m "tests: 差分对拍全绿——M1 内核完成（McTT 验证继承落地）"
```

在 `docs/verifier/kernel-spec.md` 头部追加「M1 完成：差分全绿 N 条（日期）」一行（先改后提交，随 Step 6 一起提交）。

---

## Self-Review 记录

- **Spec 覆盖**：设计文档 §三架构 → Task 5/6；§四分工 → 各任务分工注记；§五数据流/格式 → Task 3 协议 + Task 7；§六语料 → Task 4；§七错误处理 → Task 3/5 实现约定；§八里程碑 → Task 1–7 一一对应；§九验收 → Task 7 Step 5。
- **占位符**：Task 3 harness 的具体接线留作侦查后确定（Step 2 有明确侦查命令与验收标准，非 TBD）；Task 5 解析函数体标注「执行中补齐」但测试先行、协议固定——已尽量收紧。
- **类型一致性**：协议格式在 Task 3 定死，Task 4/5/6/7 全部引用同一协议；kind 常量在 Task 5 定义，Task 6 消费；`kernel_parse`/`kernel_print` 签名跨 Task 5→6 一致；`harness.exe` 路径跨 Task 3→7 一致。
