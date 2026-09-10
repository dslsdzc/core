# 语言面收窄 波 R1 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落实 `docs/superpowers/specs/2026-09-10-language-surface-narrowing-design.md` 的波 R1 三项：定长数组「表示层概念」注记、宽度死条目移除 + 词法面对齐（`1_000` / 宽度后缀退役）、全局初始化修复（定长数组全局 SIGSEGV + 静默丢初始化）。

**Architecture:** 三类正交改动——(a) **注释层**（零行为，Task 1）；(b) **词法/语法面收窄**（死 token kind 与死分支移除 + 两编译器对齐 + grammar 同步，Task 2/3）；(c) **全局初始化修复**（前端把当前被静默丢弃/崩溃的全局初始化降级为运行期 IR 序列、解释器补「标量常量初始化」阶段，Task 4）。

**Tech Stack:** Core 自举栈 —— Python bootstrap（`bootstrap/corec/`，构建工具链）+ self-hosted 编译器（`src/compiler/`，用户面编译器）+ x86-64 ELF 后端（`src/arch/x86_64/` × `src/format/elf/` × `src/os/linux/`）+ 解释器（`src/compiler/interp.cr`）。

## Global Constraints

- **jj only**：版本控制一律 `jj`（git 被 hook 机械拦截）；提交 = `jj commit -m '...'`。禁止 `git` 命令。
- **CPU 限速**：所有编译/测试命令必须 `nice -n 19` 前缀（CLAUDE.md 铁律 #6）。
- **文件永久不允许还原**：任何回滚须用户明确许可（铁律 #3）。
- **根因修复**：不得用绕过/变通掩盖问题（铁律 #1/#4）。
- **勿重编号**：`src/compiler/ast.cr` 常量编号空间稳定——删除条目**留墓碑注释**，绝不重排后续编号（先例：`// T_FLOAT_TYPE 91 已删除…`）。
- **行为零变化面**：Task 1（注释）、Task 2（死代码移除）必须输出等价——判据 = 同命令前后输出逐字节相同。
- **行为变化面仅限两处**：Task 3（`_` 分隔符与宽度后缀**均由静默改为响亮报错**——用户裁决 2026-09-10：数字字面量不支持 `_`）、Task 4（原先 SIGSEGV / 静默 0 的全局初始化场景）。**其余一切行为不得变化**。
- **自举守护**：`nice -n 19 python3 tests/selfhost/test_backend_bootstrap.py` 必须 stage 链全 `[PASS]` + `corec2`/`corec3` `cmp` IDENTICAL + N06 = 0。
- **run 门**：任何 `run`/`build` 输出中 `error[` 计数 = 0（不许「rc=0 就算过」）。
- **提交粒度**：每任务一次提交，中文提交信息，前缀 `docs:` / `refactor:` / `fix:` / `test:`。
- **diff 校验命令（Task 1 实现者实测教训，2026-09-10）**：本机 `jj diff` 默认 color-words 输出**新增行不带 `+` 前缀**，任何 `jj diff | grep '^+'` 形式的校验**恒真空通过、零校验力**；且本机 `grep` = ugrep，`'^+ *//'` 这类式样会直接报错（rc=2）。规范式样：
  ```bash
  jj diff --git <paths...> | grep '^[+]' | grep -v -e '^[+][+][+]' -e '^[+][[:space:]]*//' -e '^[+][[:space:]]*$'   # 期望空
  jj diff --git <paths...> | grep -c '^[-]'    # 期望 0（无删除行）
  ```
  并按需加**非真空控制组**（故意构造一条应命中的输入验证该命令真会报）。fish 环境另有 noclobber（`>` 覆盖已存在文件会静默失败）——重定向用 `>|` 或先删目标文件。

---

## 背景与判据（侦查已定，实现者不需要重新论证）

### 定长数组全局崩溃 — root cause（2026-09-10 全链侦查结论）

**类别 = 初始化缺失（storage/pointer 未生成），不是尺寸算错。** 证据链：

1. `src/compiler/ir_gen.cr:2349`（`gtype : ., mut = TI_INT;`）+ `:2365`（`new_ir_var(name, gtype)`）—— 全局一律登记为 `TI_INT`，数组类型/长度不进 IR；`:2336`（`global_init_val` 尾部 `return 0`）对数组字面量静默返回 0（初值丢弃）。
2. `src/os/linux/entry.cr:72-98` `_start` 常量初始化循环只写「`init_val != 0` 的标量」；数组 init_val = 0 → 不发射。全局槽 = BSS 零。
3. `src/arch/x86_64/instr.cr:428-438` `e2_load_var` global 分支 = `lea r11,[rip+slot]; mov reg,[r11]`（取槽**内容**当基指针）→ 槽为 0 时后续 `[r10+idx*8]` 解引用 NULL → SIGSEGV。
4. `src/compiler/interp.cr:67-93` `ir_interpret()` 只跑 main 的 node 区间，**无任何全局初始化阶段**（全文零引用 `g_ir_globals`）→ 解释器同因崩溃；且**可变标量全局也丢初始化**（`x : int, mut = 5` 读回 0）。

### 修复前行为基线（实现者须复现确认，作为 TDD 的「红」）

| 用例（解释器 `./build/corec run`） | 现状 rc | 期望（修复后） |
|---|---|---|
| `g : [int;2] = [8,9]; fn main()->int{return g[1];}` | 139 | 9 |
| `g : [int;2]; fn main()->int{ g[1]=7; return g[1]; }` | 139 | 7 |
| `a : [int;2] = [8,9];\nb : [int;2] = a;\nfn main()->int{return b[1];}` | 139 | 9 |
| `x : int, mut = 5;\nfn main()->int{ x = x + 1; return x; }` | 1（x 读 0） | 6 |
| `x : int = 5; fn main()->int{return x;}`（常量折叠，回归） | 5 | 5 |
| `g : [int;4] = [1,2,3,4]; fn main()->int{return 5;}`（不访问） | 5 | 5 |
| ELF 路径：前三行任一 → `corec build` 后运行二进制 | 139 | 同上 |

### 词法面基线（已核实）

| 输入 | self-hosted（现状） | bootstrap（现状） |
|---|---|---|
| `1_000` | **静默 0**：lexer 把 `_÷` 当后缀消费 → `T_INT(值 0)`（`add_tok(T_INT, -1, …)`），残余 `000` 再成一枚 `T_INT(0)`；`x := 1_000` → x = 0（cir dump：`const int = 0` ×2）；`return 1_000;` → `error[TF01]` | `1_000` → `INT_LIT '1000'` ✓ |
| `1_000.5` | 小数循环不吃 `_` → 断裂 | `FLOAT_LIT '1000.5'` ✓ |
| `0x1_0` | 16 ✓（十六进制路径早已吃 `_`） | 16 ✓ |
| `10f32` / `1.5f32` | 静默：后缀消费 + dex 路由 hack（`suffix == "f32"` → 走 T_DEX），宽度值从不落地（`W_F32` 分支不可达） | 后缀并入词素（`INT_LIT '10f32'`）→ parser `int()` 抛 `ValueError` |

**裁决（2026-09-10 用户拍板，本批落实）**：数字字面量**不支持 `_` 分隔符**——两编译器**统一响亮报错**（现状双向皆错：self-hosted 静默 0、bootstrap 静默接受；grammar 原注记「以实现为准取不支持」方向正确但两实现均未落实）；**宽度后缀（`f32`/`f64`/`i8..u8`…）退出语言面**，同样**响亮报错**（grammar 早已注明它是「apx CPU 位宽标注」= 机器形状，且全仓 `src/`+`tests/` 零使用）。

全仓数字下划线使用点（精确 grep：`(^|[^A-Za-z0-9_.])[0-9]+_[0-9]+`）**仅一处**：`tests/bootstrap/test_pipeline.py:329` `check_integer_literals`（bootstrap lexer 测试断言 `1_000`→1000）——随裁决改为断言报错。`src/` 与 `tests/` 其余为零，（自举构建不依赖该形态）。

### 关键既有机制（Task 4 复用，不新造）

- `IR_ALLOC_ARRAY(8)`：ELF 侧 `src/arch/x86_64/instr.cr:939-957` → 调运行期 `alloc`；解释器侧 `src/compiler/interp.cr:176-186` → `alloc` + 显式清零。运行期 `alloc`（`src/runtime/rt.s:72-98`）**自带 `rep stosb` 清零** → 两路径语义一致（分配即零初始化）。
- `IR_STORE(9)`：`interp.cr:187` —— `s1`(目标 var) ← `s2`(值 var)；数组字面量 lowering = `src/compiler/ir_gen.cr:2107-2127`（`IR_ALLOC_ARRAY` + 逐元素 `IR_STORE_INDEX` + `irv_set_type(v, alloc_type(TYP_ARRAY, elem_ti, n))`）。
- 全局 var 注册 = `ir_gen_globals()`（`ir_gen.cr:2390`），调用点 `src/compiler/main.cr:408`（**先于**逐函数生成 `main.cr:480 ir_gen_func(fi)` → 序言注入时 `g_ir_globals` 已就绪）。
- 手工验证过的等价形态（可作 oracle）：把初始化写进 main 体内——`fn main()->int{ g = [10,20,30,40]; return g[2]; }` → 现网 rc=30（两路径均正常）。本任务 = 把这段序列**自动化地**搬到序言。

---

## Task 1: 定长裁决注记（零行为改动）

**Files:**
- Modify: `src/compiler/ast.cr:229`（`EXPR_ARRAY`）、`:316-317`（`TYP_ARRAY`）、`:321`（`TYP_SLICE`）
- Modify: `src/compiler/checker.cr:392-401`（`res_type_node` 的 `[T;N]`/`[T]` 分支）、`:2201`（数组字面量类型）、`:1812`（range → 数组类型）
- Modify: `src/compiler/parser.cr:44-58`（`parse_type` 的 `[T; N]` / `[T]` 分支）

**Interfaces:**
- Consumes: 无（纯注释）
- Produces: 无（零行为）；注记短语供后续 R2（接口化）检索：关键字 `表示层概念`

- [x] **Step 1: 捕获基线输出**

```bash
cd /home/DslsDZC/core
printf 'g : [int;2] = [8,9];\nfn main()->int{return g[1];}\n' > /tmp/r1t1_sample.cr
nice -n 19 ./build/corec check /tmp/r1t1_sample.cr  > /tmp/r1t1_check_before.txt 2>&1
nice -n 19 ./build/corec cir   /tmp/r1t1_sample.cr  > /tmp/r1t1_cir_before.txt   2>&1
nice -n 19 ./build/corec build /tmp/r1t1_sample.cr --static -o /tmp/r1t1_bin_before > /tmp/r1t1_build_before.txt 2>&1
```
Expected: `check` 输出 `ok`（rc=0）；`build` rc=0；`/tmp/r1t1_bin_before` 运行 rc=139（已知缺陷，Step 4 复跑时须一致）。

- [x] **Step 2: 逐处贴入注记**

在下列每个位置各贴一段（紧邻被标注代码，同一文件内可共用一次完整注记 + 其余位置一行式引用）：

```core
// 表示层概念（2026-09-10 语言面收窄裁决 §1）：`[T; N]` 的类型构造器身份已退役——
// 语义归处 = product（N 元聚合）/ 序列接口 + 长度 where（N 长序列）/ F11 图（长度事实，
// 可表达依赖长度）。本语法保留为「内联容量存储」表示提示（映射参数层，与 hw-map 同层；
// 随实例选择生效或退化，非经典范式映射可忽略）。见
// docs/superpowers/specs/2026-09-10-language-surface-narrowing-design.md §1
```

落点：`ast.cr:229`、`ast.cr:316`、`ast.cr:321`、`checker.cr:392`、`checker.cr:2201`、`checker.cr:1812`、`parser.cr:44`。

- [x] **Step 3: 校验「仅注释」**

```bash
jj diff | grep '^+' | grep -v '^+++' | grep -v '^\+ *//' | grep -v '^\+$'
```
Expected: **空输出**（新增行全部是注释或空行）。

- [x] **Step 4: 复跑 Step 1 命令并比对**

```bash
nice -n 19 ./build/corec check /tmp/r1t1_sample.cr > /tmp/r1t1_check_after.txt 2>&1
nice -n 19 ./build/corec cir   /tmp/r1t1_sample.cr > /tmp/r1t1_cir_after.txt 2>&1
diff /tmp/r1t1_check_before.txt /tmp/r1t1_check_after.txt && diff /tmp/r1t1_cir_before.txt /tmp/r1t1_cir_after.txt && echo IDENTICAL
```
Expected: `IDENTICAL`（`build`/`bin` 不必重跑——注释不进二进制；如需，比对 `cmp /tmp/r1t1_bin_before <新产物>`）。

- [x] **Step 5: 提交**

```bash
jj commit -m 'docs: 语言面收窄 R1 Task 1——定长数组「表示层概念」注记（ast/checker/parser 七处，零行为改动；语义归处 = product/序列+长度约束/F11，语法保留为内联容量存储表示提示）'
```

---

## Task 2: 宽度死条目移除 + parser 死分支清理

**Files:**
- Modify: `src/compiler/ast.cr:81-94`（`T_INT_I8`…`T_INT_I64`,`T_INT_U8`…`T_INT_U64`,`T_FLOAT_F32`,`T_FLOAT_F64` 定义，编号 77-86）
- Modify: `src/compiler/ast.cr:110-119`（`W_I8`…`W_U64`,`W_F32`,`W_F64` 宽度值常量）
- Modify: `src/compiler/parser.cr:392-403`、`:406-411`、`:897-908`（唯一引用面 = 死分支）

**Interfaces:**
- Consumes: 无
- Produces: 无（lexer 从不发射这些 token kind——`parser.cr` 的 `kn == T_INT_I8 …` 链与 `tok_k(t) >= T_INT_I8 && tok_k(t) <= T_INT_U64` 判定**永不可达**；`W_*` 仅被这些链引用）

- [x] **Step 1: 引用面核实（必须只有 parser.cr 死分支）**

```bash
nice -n 19 grep -rn "T_INT_I8\|T_INT_I16\|T_INT_I32\|T_INT_I64\|T_INT_U8\|T_INT_U16\|T_INT_U32\|T_INT_U64\|T_FLOAT_F32\|T_FLOAT_F64\|W_I8\|W_I16\|W_I32\|W_I64\|W_U8\|W_U16\|W_U32\|W_U64\|W_F32\|W_F64" src/ --include='*.cr' | grep -v '^src/compiler/ast.cr'
```
Expected: 命中仅 `src/compiler/parser.cr` 第 392-411 / 897-908 行（若出现其它文件/行号 → **停下并上报**，不得继续）。

- [x] **Step 2: parser.cr 死分支移除**

`parser.cr:392-403` 改为（两处同构，另一处在 `:897`）：

```core
    if tok_k(t) == T_INT {
        advance_tok();
        return alloc_node(EXPR_INT, 0, 0, 0, tok_iv(t), TY_INT, 0, tok_ln(t), tok_cl(t));
    }
```

`parser.cr:406-411` 改为：

```core
    if tok_k(t) == T_DEX {
        advance_tok();
        // 节点字段（数值迁移 Task 4）：a = binary64 位模式（apx 快路径字面量表示，
        // 由 lexer 存入 token 的 lexeme 槽的数字串还原）；int_val = 定点缩放整数
        // （精确表示，默认路径）。宽度后缀退役（2026-09-10 语言面收窄 §2）：data 槽
        // 不再承载宽度标注，恒 0。
        bits : int = 0;
        tl := r64(g_tokens, t * ESZ_TOKEN + OFF_TK_LEXEME);
        if tl >= 0 { bits = str_to_f64_bits(istr_get(tl)); }
        return alloc_node(EXPR_DEX, bits, 0, 0, tok_iv(t), TY_DEX, 0, tok_ln(t), tok_cl(t));
    }
```

- [x] **Step 3: ast.cr 死条目移除（留墓碑，勿重编号）**

`ast.cr:81-94` 整段替换为：

```core
// 77-86 原为宽度后缀 token kind（T_INT_I8..T_INT_U64 / T_FLOAT_F32 / T_FLOAT_F64）。
// 2026-09-10 语言面收窄 §2 删除：lexer 从不发射这些 kind（宽度后缀已退役，改响亮报错），
// parser 侧引用同步移除。**勿重编号**——编号空间稳定（先例：T_FLOAT_TYPE 91 已删除）。
```

`ast.cr:110-119`（`W_I8`…`W_F64`）整段替换为：

```core
// W_I8..W_F64（1..10）原为「宽度标注」值域，仅供宽度后缀 token 分支使用。
// 2026-09-10 语言面收窄 §2 随死分支一并删除。**勿重编号**。
```

- [x] **Step 4: 引用面归零验证**

```bash
nice -n 19 grep -rn "T_INT_I8\|T_INT_I16\|T_INT_I32\|T_INT_I64\|T_INT_U8\|T_INT_U16\|T_INT_U32\|T_INT_U64\|T_FLOAT_F32\|T_FLOAT_F64\|W_I8\|W_I16\|W_I32\|W_I64\|W_U8\|W_U16\|W_U32\|W_U64\|W_F32\|W_F64" src/ --include='*.cr'
nice -n 19 grep -n "T_INT_I64\|W_I64" bootstrap/ -r
```
Expected: **过滤注释行后**零命中（**代码引用面**归零）——注意墓碑注释正文本身含这些标识符字样，故原始 grep 不会全空（Task 2 实现者实测指出此点，判据按「代码引用零命中」执行）：`grep ... | grep -v '^[^:]*:[0-9]*: *//'` 或等价过滤后 rc=1/无输出。

- [x] **Step 5: 重建 + 冒烟 + 回归**

```bash
nice -n 19 python3 build_selfhost_native.py        # 期望 BUILD SUCCESS + [GUARD] manifest OK + 日志守卫零 error[/未定义
nice -n 19 ./build/corec run 'fn main()->int{return 42;}'   # 期望 rc=42、无 error[
nice -n 19 python3 tests/selfhost/test_compile.py  # 期望 All selfhost compile tests passed.
```

- [x] **Step 6: 提交**

```bash
jj commit -m 'refactor: 语言面收窄 R1 Task 2——宽度死条目移除（ast.cr 77-86 token kind + W_* 值域，墓碑注释勿重编号）+ parser 两处死分支清理（lexer 从不发射，引用面归零）'
```

---

## Task 3: 词法面收窄（`_` 分隔符拒绝 + 宽度后缀退役——均响亮报错）

**Files:**
- Modify: `src/compiler/lexer.cr`（数字扫描 `:418-470`：十进制/小数/`0x`/`0o`/`0b` 循环**均不接受** `_`；后缀段落改为响亮报错；dex 路由去掉 f32/f64 条件；删空分支）
- Modify: `bootstrap/corec/frontend/lexer.py:85-115`（`_` 与字母后缀 → `self.error(...)`）
- Modify: `tests/bootstrap/test_pipeline.py:327-340`（`check_integer_literals`：断言由「`1_000`→1000」改为「拒绝」）
- Modify: `grammar/tokens.ebnf:22-31`、`grammar/core.ebnf:58`
- Create: `tests/selfhost/test_lexer_parity.py`

**Interfaces:**
- Consumes: Task 2 已删掉宽度 token kind（本任务不再产生它们）
- Produces: 词法契约——数字字面量**不接受** `_` 分隔符、**不接受**任何字母后缀，二者均**响亮报错**；合法形态（十进制/小数/`0x`/`0o`/`0b`/负号）行为不变

- [x] **Step 1: 写失败测试 `tests/selfhost/test_lexer_parity.py`**

```python
#!/usr/bin/env python3
"""词法对照测试：`_` 分隔符与宽度后缀在两编译器均被拒绝（2026-09-10 语言面收窄 §2）。"""
import sys, os, subprocess
sys.path.insert(0, 'bootstrap')
from corec.frontend.lexer import Lexer

BASE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
COREC = os.path.join(BASE, 'build', 'corec')
BAD = ('1_000', '1_000.5', '0x1_0', '10f32', '1.5f64', '10u8')

def selfhost(src):
    r = subprocess.run(['nice', '-n', '19', COREC, 'run', 'fn main()->int{return %s;}' % src],
                       cwd=BASE, capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr

def test_bootstrap_rejects():
    for bad in BAD:
        try:
            Lexer(bad).tokenize()
            assert False, 'bootstrap accepted %s' % bad
        except SyntaxError:
            pass

def test_selfhost_rejects():
    # 断言必须命中**我们自己的诊断文本**——否则 `return 1_000` 既有的 TF01 会假绿。
    # 注意：lexer 诊断走 src/compiler/lexer.cr add_error，输出前缀是 `error: `，
    # **不是** `error[XX]`（实测 `fn main()->int{return 0xZZ;}` → `error: invalid digit
    # in integer literal`，rc=1）——故只断言消息标记 + 出现 `error`，不断言 `error[`。
    for bad, marker in (('1_000', 'not supported'), ('1_000.5', 'not supported'),
                        ('0x1_0', 'not supported'), ('10f32', 'retired'),
                        ('1.5f64', 'retired'), ('10u8', 'retired')):
        rc, out = selfhost(bad)
        assert 'error' in out and marker in out, (bad, rc, out)

def test_legal_forms_unchanged():
    for src, want in (('0x1f', 31), ('0o17', 15), ('0b1010', 10), ('1000', 232)):
        rc, out = selfhost(src)
        assert 'error[' not in out, (src, out)
        assert rc == want, (src, rc, want)

if __name__ == '__main__':
    for fn in (test_bootstrap_rejects, test_selfhost_rejects, test_legal_forms_unchanged):
        fn(); print('PASS', fn.__name__)
```

- [x] **Step 2: 运行测试确认「红」**

```bash
nice -n 19 python3 tests/selfhost/test_lexer_parity.py
```
Expected: 两条 FAIL + 一条对照 PASS —— `test_bootstrap_rejects`（bootstrap 接受 `1_000`）/ `test_selfhost_rejects`（无我们的诊断文本，只有既有 TF01）/ `test_legal_forms_unchanged`（PASS，对照组）。记录实际输出到报告。

- [x] **Step 3: self-hosted lexer 改造（`src/compiler/lexer.cr`）**

(a) 十进制数码循环（`:421-423`）与小数部分循环（`:445`）**保持只吃 digit**（不加 `_`）；hex/oct/bin 三条循环（`:428-430`）各**删除** `|| hc == 95`、`|| oc == 95`、`|| bc == 95`（不再接受 `_`）。

(b) 后缀段落（`:452-468`）整段替换为：

```core
            // 数字词法收窄（2026-09-10 用户裁决，语言面收窄 §2）：`_` 分隔符与宽度后缀
            // （f32/f64/i8..u64）**均不支持**——一律响亮报错且**不消费**残余字符
            // （按标识符继续 tokenize，使后续解析给出第二重信号，不静默、不猜）。
            // 修复前：`_` 被 is_alpha(95) 当后缀静默消费 → T_INT 取「无值」= 0
            // （`x := 1_000` 静默成 0 = 实质误编译）；宽度后缀同样静默丢弃。
            sx := cur_char_at(_src, _pos, _slen);
            if sx == 95 {
                add_error("invalid character '_' in numeric literal (digit separators not supported)");
            } else if is_alpha(sx) != 0 {
                add_error("invalid suffix on numeric literal (width suffixes retired 2026-09-10)");
            }
            num_str := str_sub(_src, start, _pos - start);
            if has_dot != 0 {
                add_tok_int_lex(T_DEX, str_to_scaled(num_str), str_intern(num_str), start_line, start_col);
            } else {
                add_tok_int(T_INT, str_int_literal(num_str), start_line, start_col);
            }
```

(c) `str_int_literal`（`:221`）、`str_to_scaled`、`str_to_f64_bits` 内部既有的 `_` 跳过逻辑**保留不动**（防御性；删除属无谓风险，且未来若恢复分隔符即插即用）。

- [x] **Step 4: bootstrap lexer 对齐（`bootstrap/corec/frontend/lexer.py:85-115`）**

十进制分支：

```python
        else:
            while self.current().isdigit():
                n += self.advance()
            if self.current() == '_':
                self.error("invalid character '_' in numeric literal (digit separators not supported)")
            if self.current() == '.' and self.peek().isdigit():
                is_float = True
                n += self.advance()
                while self.current().isdigit():
                    n += self.advance()
                if self.current() == '_':
                    self.error("invalid character '_' in numeric literal (digit separators not supported)")
            if self.current().isalpha():
                # 宽度后缀退役（2026-09-10 语言面收窄 §2）——与 self-hosted lexer 同款
                # 响亮报错；此前后缀被并入词素（'10f32'）→ parser int() 抛 ValueError。
                self.error("invalid suffix on numeric literal (width suffixes retired 2026-09-10)")
```

前缀进制分支（`:88-99`）：digits 循环去掉 `or self.current() == '_'`，并在其后加同款 `_` 报错。`n = n.replace('_', '')`（`:117`）已无输入可清，保留无害。

- [x] **Step 5: bootstrap 既有测试同步（`tests/bootstrap/test_pipeline.py:327-340`）**

```python
def check_integer_literals():
    tokens = Lexer('0x1f 0o17 0b1010').tokenize()
    values = [int(t.lexeme) for t in tokens[:-1]]
    if values != [31, 15, 10]:
        print(f'[FAIL] integer literal forms: got {values}')
        return False
    for bad in ('1_000', '0x1_0', '10f32', '1_000.5'):
        try:
            Lexer(bad).tokenize()
        except SyntaxError:
            continue
        print(f'[FAIL] rejected form was accepted: {bad}')
        return False
    try:
        Lexer('0x').tokenize()
    except SyntaxError:
        pass
    else:
        print('[FAIL] empty prefixed integer was accepted')
        return False
    print('[PASS] integer literal forms: hex/octal/binary; separators/suffixes rejected')
    return True
```

- [x] **Step 6: grammar 同步（`grammar/tokens.ebnf` / `grammar/core.ebnf`）**

`INT_LIT` 行去掉 `[ INT_SUFFIX ]` 并删除 `INT_SUFFIX` 规则；`DEX_LIT` 行去掉 `[ 'f32' | 'f64' ]`。注释段改写为：

```ebnf
(* 字面量 *)
(* 数字字面量不支持 '_' 分隔符、不支持任何宽度后缀（2026-09-10 语言面收窄 §2 用户裁决：
   两实现统一响亮报错——修复前 self-hosted 把 '_' 当后缀静默消费成取值 0、bootstrap
   静默接受；宽度后缀 = 机器形状，归映射层）。 *)
INT_LIT = DIGIT { DIGIT } ;
```
（实现者按语法惯例给出等价 EBNF；核心约束 = 无 `_`、无任何后缀产生式。）
`grammar/core.ebnf:58` 的「f32/f64 后缀 = apx CPU 位宽标注」注释改为退役记述。

- [x] **Step 7: 重建 + 测试全绿**

```bash
nice -n 19 python3 build_selfhost_native.py
nice -n 19 python3 tests/selfhost/test_lexer_parity.py      # Expected: 三条全 PASS
nice -n 19 python3 tests/bootstrap/test_pipeline.py         # Expected: 全 PASS（含改后的 check_integer_literals）
nice -n 19 ./build/corec run 'fn main()->int{x := 1_000; return x;}'   # 期望含 'not supported'（lexer 诊断前缀 = `error: `，非 `error[`）
nice -n 19 ./build/corec run 'fn main()->int{return 1000;}'            # 期望 rc=232、无任何 error
nice -n 19 python3 tests/selfhost/test_compile.py
```

- [x] **Step 8: 提交**

```bash
jj commit -m 'fix: 语言面收窄 R1 Task 3——数字词法收窄（_ 分隔符与宽度后缀一律响亮报错：消灭 1_000 静默 0 误编译；bootstrap/self-hosted 双侧对齐；grammar + bootstrap 测试同步；新增词法对照测试）'
```

---

## Task 4: 全局初始化修复（定长数组全局 SIGSEGV + 静默丢初始化）

**Files:**
- Modify: `src/compiler/ir_gen.cr`（新增 `global_needs_runtime_init` / `global_var_of` / `inject_global_inits`；`ir_gen_func:2222` 在 main 序言调用注入）
- Modify: `src/compiler/interp.cr:67-93`（`ir_interpret` 跑 main 前补「标量常量初始化」阶段）
- Create: `tests/selfhost/test_global_init.py`

**Interfaces:**
- Consumes: `g_global_lets`（`{a=name_idx, b=type_node, c=value_node, int_val=apx 位模式|null}`）；`g_ir_globals`（每 24B：`+0 name_idx`、`+8 ir_var`、`+16 init_val`，已由 `main.cr:408 ir_gen_globals()` 填充）；`IR_ALLOC_ARRAY(8)`、`IR_STORE(9)`、`IR_STORE_INDEX`；`gen_expr(node)`、`new_ir_var`、`irv_set_type`、`emit`
- Produces: 全局初始化语义——(1) 聚合全局（`[T;N]`/`[T]`）无论有无初值都在运行期分配 + 写槽（存储持久，`alloc` 语义）；(2) 非常量初值的全局在运行期求值并写槽；(3) 编译期标量常量初始化保持既有通道（ELF `_start` 常量循环），解释器补同语义阶段

- [x] **Step 1: 写失败测试 `tests/selfhost/test_global_init.py`**

覆盖下表（解释器 `run` 与 ELF `build --static` + 运行二进制**双路径**；ELF 调用模式照抄 `tests/selfhost/test_native_memory.py:110-130`）：

| # | 源 | 期望 rc |
|---|---|---|
| 1 | `g : [int;2] = [8,9];\nfn main()->int{return g[1];}` | 9 |
| 2 | `g : [int;2];\nfn main()->int{ g[1]=7; return g[1]; }` | 7 |
| 3 | `a : [int;2] = [8,9];\nb : [int;2] = a;\nfn main()->int{return b[1];}` | 9 |
| 4 | `g : [int;4] = [1,2,3,4];\nfn main()->int{return 5;}` | 5 |
| 5 | `x : int, mut = 5;\nfn main()->int{ x = x + 1; return x; }` | 6 |
| 6 | `x : int = 5;\nfn main()->int{return x;}`（回归：常量折叠） | 5 |
| 7 | `g : [int;2] = [3,4];\nfn get()->int{return g[1];}\nfn main()->int{return get();}`（跨函数访问） | 4 |
| 8 | `a : [int;2] = [8,9];\nb : [int;2] = a;\nfn main()->int{return a[0]+b[1];}` | 17 |

每例两条断言：**无 `error[`** + rc 精确值。

- [x] **Step 2: 运行确认「红」（两路径）**

**前置（必须先做）——清增量缓存**：`inject_global_inits` 的注入点在 `ir_gen_func` 内（`main.cr:480` 调用），而**函数命中 cir 缓存时根本不走 `ir_gen_func`**（`main.cr:483` 的 cache-hit 分支）——叠加已知缺陷 TODO #5（缓存键不含编译器身份，跨重建不失效），**旧缓存会让本次修复看起来"没生效"**。故每次判据前：

```bash
nice -n 19 ./build/corec clean-cache      # 若子命令不可用：rm -rf .core/cache（先 ls 确认路径）
```

并在报告里记录该交互（缓存键/失效面 = TODO #5，不在本批修）。测试脚本自身不必清缓存，但**判据运行必须在清缓存后进行**。

```bash
nice -n 19 python3 tests/selfhost/test_global_init.py
```
Expected: 例 1/2/3/7/8 双路径 FAIL（rc=139）；例 5 FAIL（rc=1）；例 4/6 PASS。记录原始输出（rc + 信号）到报告。

- [x] **Step 3: 捕获 ELF 产物基线（零变化判据）**

```bash
nice -n 19 ./build/corec build tests/suite/<无运行期初始化全局的样本>.cr --static -o /tmp/r1t4_base_bin
sha256sum /tmp/r1t4_base_bin | tee /tmp/r1t4_base_sha
```
（样本自选：`tests/suite/` 中不含文件级聚合/非常量全局的用例，例如 control-flow 类。）

- [x] **Step 4: 前端修复（`src/compiler/ir_gen.cr`）**

新增（建议置于 `global_init_val` 之后）：

```core
// 文件级 let 是否需要「运行期初始化」（2026-09-10 语言面收窄 §1.3 / R1 ②）。
// 判据（与 global_init_val 互补——它只认编译期标量常量，其余静默归 0）：
//   ① 声明类型是聚合（语法节点 EXPR_ARRAY，含 `[T; N]` 与 `[T]`）→ 必须运行期分配存储；
//   ② 初值存在且不是 int/bool/dex 字面量（含负号字面量）→ 必须运行期求值。
fn global_needs_runtime_init(name_idx: int) -> int {
    i : ., mut = g_global_let_count - 1;
    loop {
        if i < 0 { break; }
        node := r64(g_global_lets, i * 8);
        if ast_a(node) == name_idx {
            tn := ast_b(node);
            if tn >= 0 && ast_kind(tn) == EXPR_ARRAY { return 1; }
            vn := ast_c(node);
            if vn < 0 { return 0; }
            vk := ast_kind(vn);
            if vk == EXPR_INT || vk == EXPR_BOOL || vk == EXPR_DEX { return 0; }
            if vk == EXPR_UNARY && ast_c(vn) == UOP_NEG {
                inner := ast_a(vn);
                ik := ast_kind(inner);
                if ik == EXPR_INT || ik == EXPR_BOOL || ik == EXPR_DEX { return 0; }
            }
            return 1;
        }
        i = i - 1;
    }
    return 0;
}

// 按 name_idx 查已注册的全局 IR var（未注册 = -1）。
fn global_var_of(name_idx: int) -> int {
    gi : ., mut = 0;
    loop {
        if gi >= g_ir_global_count { break; }
        if r64(g_ir_globals, gi * 24) == name_idx { return r64(g_ir_globals, gi * 24 + 8); }
        gi = gi + 1;
    }
    return -1;
}

// 把需要运行期初始化的文件级 let 降级为 IR 序列（写进当前函数 = main 序言）。
// 顺序 = g_global_lets 源序（跨全局依赖如 `b : [int;2] = a;` 因此正确）。
fn inject_global_inits() {
    i : ., mut = 0;
    loop {
        if i >= g_global_let_count { break; }
        lnode := r64(g_global_lets, i * 8);
        name_idx := ast_a(lnode);
        if global_needs_runtime_init(name_idx) != 0 {
            gv := global_var_of(name_idx);
            if gv >= 0 {
                vn := ast_c(lnode);
                v : ., mut = -1;
                if vn >= 0 {
                    v = gen_expr(vn);
                    v = force_if_thunk(v);
                } else {
                    // 无初值聚合：整流分配（零初始化由 alloc 语义保证——rt.s:94-98 rep stosb；
                    // 解释器 IR_ALLOC_ARRAY 显式清零 interp.cr:182-183）。
                    // 仅 `[T; N]`（N ≥ 1）注入；`[T]`（切片无长度，ast_int_val = 0）**不注入**
                    // ——保持 BSS 零 = 空切片/哑指针，空切片解引用属独立 null 陷阱类，不在本批。
                    tn := ast_b(lnode);
                    cnt : ., mut = 0;
                    if tn >= 0 { cnt = ast_int_val(tn); }
                    if cnt > 0 {
                        v = new_ir_var("ginit", TI_UNIT);
                        emit(IR_ALLOC_ARRAY, v, cnt, 0, 0, 0);
                        irv_set_type(v, alloc_type(TYP_ARRAY, TI_INT, cnt));
                    }
                }
                if v >= 0 { emit(IR_STORE, -1, gv, v, 0, 0); }
            }
        }
        i = i + 1;
    }
}
```

在 `ir_gen_func`（`ir_gen.cr:2222`）内、`emit(IR_ARENA_NEW, …)`（`:2269-2271`）之后、`gen_expr(body)` 之前插入：

```core
    // 程序启动期全局初始化（2026-09-10 R1 ②）：只在 main 序言注入——run 与 build
    // 两路径都从 main 进入（interp.cr:74-79 按名查找 main；ELF _start call main），
    // 因此无需新 IR 函数/新 .ccr 段/新 _start 指令 = 无序列化与字节布局扰动。
    if str_eq(istr_get(name_idx), "main") != 0 { inject_global_inits(); }
```

- [x] **Step 5: 解释器修复（`src/compiler/interp.cr`）**

`ir_interpret()`（`:67`）在「清零 value store」（`:86-93`）之后、预扫描 label 之前插入：

```core
    // 编译期标量常量全局初始化阶段——与 ELF _start 的常量初始化循环（os/linux/entry.cr:72-98）
    // 同语义、同数据源（g_ir_globals +16 的 init_val）。此前解释器无此阶段，
    // 可变标量全局读回 0（不可变标量因 find_global_const_node 折叠而侥幸正确）。
    gi2 : ., mut = 0;
    loop {
        if gi2 >= g_ir_global_count { break; }
        iv2 := r64(g_ir_globals, gi2 * 24 + 16);
        gv2 := r64(g_ir_globals, gi2 * 24 + 8);
        if iv2 != 0 && gv2 >= 0 && gv2 < need { w64(g_ir_vals, gv2 * 8, iv2); }
        gi2 = gi2 + 1;
    }
```

- [x] **Step 6: 重建 + 测试全绿 + 零变化判据**

```bash
nice -n 19 python3 build_selfhost_native.py
nice -n 19 python3 tests/selfhost/test_global_init.py      # Expected: 全 PASS（双路径）
nice -n 19 ./build/corec build tests/suite/<同 Step 3 样本>.cr --static -o /tmp/r1t4_head_bin
cmp /tmp/r1t4_base_bin /tmp/r1t4_head_bin && echo BYTE-IDENTICAL
nice -n 19 python3 tests/selfhost/test_compile.py
nice -n 19 python3 tests/bootstrap/test_pipeline.py
```
Expected: `BYTE-IDENTICAL`（无运行期初始化全局的程序 ELF 产物逐字节不变）。

- [x] **Step 7: 提交**

```bash
jj commit -m 'fix: 语言面收窄 R1 Task 4——全局初始化修复（聚合/非常量全局降级为 main 序言 IR 序列：alloc+逐元素存+写槽；解释器补标量常量初始化阶段）——修 139 崩溃与静默 0；新增双路径测试'
```

---

## Task 5: 收官（回归 + 自举 + 文档 + 台账）

**Files:**
- Modify: `docs/superpowers/specs/2026-09-10-language-surface-narrowing-design.md`（状态行 + §3 波 R1 标记）
- Modify: `TODO.md`（宽度清理三项划销 + 定长裁决挂账处置 + 定长全局修复记录）
- Modify: `.superpowers/sdd/progress.md`（台账）
- Modify: `tests/selfhost/test_compile.py:20-38`（陈旧清单路径——见 Step 5）

- [x] **Step 1: 全量回归**

```bash
nice -n 19 python3 tests/selfhost/test_compile.py
nice -n 19 python3 tests/selfhost/test_backend_bootstrap.py
nice -n 19 python3 tests/selfhost/test_hit_table.py
nice -n 19 python3 tests/selfhost/test_ccr_v7.py
nice -n 19 python3 tests/selfhost/test_live_ranges.py
nice -n 19 python3 tests/selfhost/test_slice_bounds.py
nice -n 19 python3 tests/selfhost/test_global_init.py
nice -n 19 python3 tests/selfhost/test_lexer_parity.py
nice -n 19 python3 tests/bootstrap/test_pipeline.py
nice -n 19 python3 tests/bootstrap/test_borrow.py
nice -n 19 python3 tests/bootstrap/test_generics.py
```
Expected: 全绿。

- [x] **Step 2: 自举全链 + 守护**

```bash
nice -n 19 python3 build_selfhost_native.py       # BUILD SUCCESS + 两处 [GUARD] OK
# corec 前端三代链（corec2/corec3）**不在** test_backend_bootstrap 覆盖内——那套覆盖的是
# corearch 的 stage1/2/3 byte-identical；corec 链按 src/ci/run.sh 的 full-bootstrap 段亲跑：
nice -n 19 ./build/corec build src/compiler/main.cr -o /tmp/corec2 --static -O 0
/tmp/corec2 build src/compiler/main.cr -o /tmp/corec3 --static -O 0
cmp /tmp/corec2 /tmp/corec3                        # 期望 IDENTICAL
nice -n 19 ./build/corec run 'fn main()->int{return 42;}'   # rc=42
```
（口径修正来源 = Task 5 实现者实测：计划原写「由 test_backend_bootstrap 覆盖」不实，已按 run.sh 同款。）

- [x] **Step 3: 文档同步**

- spec 状态行 → 「**已实施（R1）**」+ §3 波 R1 三项逐条标记完成 + 记录三处行为变化（`1_000`、宽度后缀、全局初始化）
- `TODO.md`：宽度类型移出语言条目内三项（死条目移除 / `_f32/_f64` 后缀 / `1_000` 复核）划销并注记落点；定长裁决条目注记「类型身份退役 = R2 落实，R1 注记 + 全局路径已修」；新增「全局初始化机制」记录（main 序言注入 + 解释器常量阶段；未来若支持非 main 入口/库形态需迁移到独立 init 区）
- `TODO.md` **新登记**（R1 实测发现）：**lexer 诊断前缀不一致**——lexer 走 `add_error`（`lexer.cr:38-44`）输出 `error: <msg>`（**无错误码**），checker/其余走 `diag.cr:134` 的 `error[XX]`；既有守卫与测试门（扫 `error[`）对 lexer 诊断**零覆盖**（实测 `return 0xZZ;` → `error: invalid digit in integer literal`，全无 `error[`）。建议统一格式或扩展守卫扫描面
- `TODO.md` **新登记（Task 3 评审 Minor）**：① lexer 诊断**重复打印 4 遍**（多轮 tokenize 累积、`tokenize()` 不清零 `g_error_count`——既有行为，父版同款注释）；② 边缘形态分歧（既有，超出本批判据集）：`1._5`（SH 响亮报错 vs bootstrap 词法层 INT(1)+DOT+IDENT(_5)，整管线下仍报错、无静默接受）、`1.`（既有分歧）；③ `0x_` 诊断措辞优先级变化（现报分隔符消息，原报 invalid integer literal——两者皆错误，仅措辞）
- `TODO.md` **新登记（Task 4 评审发现）**：
  - **Important（既有缺口，双路径分叉）**：解释器 callee 内联路径仍缺枚举族 opcode（如 `IR_MAKE_ENUM(17)`）——枚举值在 callee 内构造时 interp 与 ELF 结果分叉（复现件：`build/review_t4/p14_enum_in_callee.cr` interp 0 vs ELF 33；`p15_enum_split.cr` interp -11 vs ELF 33）；本批 15 例未覆盖。建议按 Task 4 §6.2 同款「与主循环同语义同守卫」补齐
  - **Minor**：类型别名仅**一层**解析（`type A = [int;2]; type B = A; g : B;` 仍双路径 SIGSEGV；有初值形态工作）——`agg_elem_count_of` 需递归/迭代至底
  - **Minor（测试卫生，随本任务修）**：`tests/selfhost/test_global_init.py` 的 `clean_cache()` 返回码未检查（清缓存失败 + TODO #5 旧缓存 = 判据被静默污染——正是本项目大忌）→ 改为断言 rc=0；另删未用的 `import sys`
  - **Minor（记录，不修）**：Task 4 报告 §6.5 称注入在 `g_cur_ret_ti = ret_ti` **之后**，实际在**之前**（`ir_gen.cr:2282`，= brief 指定位置）——报告措辞与代码不符（读码无歧义）；`alloc_type(TYP_ARRAY, TI_INT, cnt)` 硬编码元素类型 TI_INT（无观测差异，元素尺寸恒 8）
- **Task 2 评审遗留（Minor）随本步清账**：
  - M1：`parser.cr` dex 分支恢复被替换文本丢掉的**行尾注释** `// 词素串下标（-1 = 无）`（信息有损、零行为——纯注释恢复）
  - M3：**文档面随迁**（Task 2 只动 `src/`）——`docs/pseudocode/compiler/parser-2.md:167-205,729-740`、`docs/pseudocode/compiler/ast.md:87-118,445-490`、`docs/numeric-migration-inventory.md:29,32,51,148,190,230-231,244` 中引用已删条目处逐条更新/标注（其中 `:148` 声称 `src/lsp/analysis.cr:895` 有 `(k >= T_INT_I8 && k <= T_FLOAT_F64)` 区间——**实测不存在**，该行本身即过时，按实测修正）
  - Info（不处理，仅记录）：`build/all.cr`、`build/bootstrap_self.cr`、`build/selfhost_compiler.cr` = 陈旧拼接产物（忽略项，不入树）

- [x] **Step 4: 台账**

`.superpowers/sdd/progress.md` 追加 R1 段（各任务提交哈希 + 判据结果）。

- [x] **Step 5: 测试清单陈旧路径核对（`tests/selfhost/test_compile.py:20-38`）**

`concat_sources()` 的 `if os.path.exists(path)` 会**静默跳过**缺失文件——现清单含三条已搬迁路径（`src/compiler/backend/x86_64.cr`、`src/compiler/backend/x86_64/instr.cr`、`src/compiler/backend/resolve.cr` 均已不存在；波 1 三轴搬迁后为 `src/arch/x86_64/*.cr` + `src/format/elf/*.cr` + `src/os/linux/*.cr`）。

处理：把条目更新为三轴现状路径（对照 `build_selfhost_native.py` 的 `corearch_files`/`arch_x86_64_files`/`format_elf_files`/`os_linux_files`），并把 `exists` 静默跳过改为**存在性断言**（`build_selfhost_native.py:144-152 guard_manifest` 同款）。复跑 `test_compile.py` 必须仍全绿。

若补入后测试失败 → 说明原清单是刻意裁剪：改为在原处加**显式注释**说明裁剪意图（保 `exists` 语义）+ 在 `TODO.md` 登记本次发现——**不得**用还原/静默跳过掩盖。

- [x] **Step 6: 提交**

```bash
jj commit -m 'docs: 语言面收窄 R1 收官——全量回归 + 自举守护全绿 + spec/TODO/台账同步 + test_compile 清单陈旧路径修正（存在性断言）'
```

---

## 自检记录（写完计划后复核）

- **spec 覆盖**：§1（定长裁决）→ Task 1（注记）+ Task 4（全局路径修复）；§1.3「checker 落实时点 = R2」→ 明确不在本批；§2（宽度三项）→ Task 2（死条目）+ Task 3（后缀/`1_000`）；§3 波 R1 判据 → Task 5。**无遗漏，无越界**（表示提示机制留 R3、checker 类型判定重构留 R2）。
- **占位符扫描**：无 TBD/TODO；所有代码块为可落地的具体代码；所有命令带期望输出。
- **类型/命名一致性**：`global_needs_runtime_init` / `global_var_of` / `inject_global_inits` 三名在 Task 4 内自洽；`IR_ALLOC_ARRAY`=8、`IR_STORE`=9 与 `interp.cr:176-187` 一致；`emit(IR_STORE, d, s1, s2, …)` 参数序与 `interp.cr:187` 一致（`s1` 目标、`s2` 值）。
- **风险注记**：Task 4 的序言注入只对「需要运行期初始化」的全局生效 → 其余程序 IR 不变（Step 3/6 的 byte-identical 判据即此保证）；注入点选择 main 序言的理由（无新 IR 函数/无 .ccr 段变更/无 `_start` 字节扰动）已写明，若未来出现非 main 入口或库形态，需迁移到独立 init 区（已记入 TODO）。
