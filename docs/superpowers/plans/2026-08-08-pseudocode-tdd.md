# Core 源码全量伪代码翻译实现计划（TDD + 形式化基础）

> 受众：执行本计划的 agentic worker。必需子技能：`superpowers:subagent-driven-development`（推荐）或 `superpowers:executing-plans`，按任务逐项实施。进度以复选框（`- [ ]`）跟踪。

目标：将 56 个 Core `.cr` 源文件（19,749 行）翻译为无任何编程语言关键字的汉语伪代码文档（每文件一个 .md，镜像目录结构，内嵌每函数测试要点），并产出全局术语表与质量校验工具。

架构：分三阶段。（1）脚本提取全部共享标识符并人工分配中文名，产出《标识符对照表》作为跨文件一致性定位点；（2）10 个并行翻译 agent 按文件分组翻译，每个 agent 只读自己的源文件与术语表，只写自己的 .md；（3）自动校验（未翻译残留、术语一致性、章节完整性）并修复后结束。

技术栈：Python 3（提取与校验脚本）、Markdown（产出）、jj（版本控制，禁止 git，见 CLAUDE.md 铁律）。

规格参照：`docs/superpowers/specs/2026-08-08-pseudocode-tdd-design.md`（已获用户认可）

---

## 全局约束

以下约定对所有任务生效。

### G1. 版本控制（铁律）

- 禁止 `git`，全程用 `jj`。
- 每任务结束使用固定的提交流程。注意：若 `jj squash` 的源提交被清空且双方都有描述，jj 会调编辑器询问合并描述（非交互环境会卡死）。因此流程是：先建空描述提交，再 squash，最后补描述。
  ```bash
  jj new
  jj squash --from @- --into @ <本任务产出的路径...>
  jj describe @ -m "<提交说明>"
  jj log -r @ --no-graph -T 'description.first_line()'
  ```
  `jj squash` 的 `<paths>` 要精确到本任务的文件，不使用 `.` 或整个目录。

### G2. 翻译约定（所有翻译任务必须遵守）

G2.1 关键字替换表（源码与伪代码）

| 源码 | 伪代码 |
|------|--------|
| `if` / `else` | 如果 条件，那么：… / 否则：… |
| `else if` | 否则如果 条件，那么：… |
| `while` | 循环（当 条件 成立时）：… |
| `for` | 对 集合 遍历（每次取 元素）：… |
| `break` / `continue` | 跳出循环 / 继续下一次循环 |
| `return` | 返回 |
| `match` | 匹配 值：… 分支 值，那么：… |
| `fn` / `struct` / `enum` | 函数 / 结构 / 枚举 |
| `:=` / `: type =` | 令 名字 = 值（声明） |
| `mut` / `pub` / `import` | 可变 / 公开 / 引入 |
| `true` / `false` / `None` | 真 / 假 / 无值（None） |
| `and` / `or` / `not` | 且 / 或 / 非 |
| `==` `!=` `<` `<=` `>` `>=` | 等于 / 不等于 / 小于 / 不大于 / 大于 / 不小于 |
| `+ - * / %` 及位运算符号 | 保留符号（语言中性） |
| 源码注释 | 译成中文，保留在对应位置 |

G2.2 标识符规则（首次中英对照）

- 所有标识符（全局、函数、结构、枚举、字段、局部变量）译成中文语义名；首次出现写作 `中文名（原名）`，之后只用中文名。
- 共享标识符（`g_*` 全局、跨文件函数、struct/enum 名、stdlib 公开函数）必须使用《标识符对照表》中的名字，不自造新名。
- 内置类型：整数（int）、字符串（string）、布尔（bool）、字节（byte）、浮点数（float）；自定义类型按标识符规则。
- 局部变量由各翻译 agent 自行命名，但须记入文件内「标识符对照表」。

G2.3 格式约定

- 4 空格缩进，嵌套层级与源码一一对应。
- 条件块：`如果 条件，那么：` 换行缩进；`否则：` 同层；`否则如果 条件，那么：` 同层。
- 循环：`循环（当 条件 成立时）：` 或 `对 列表 遍历：`。
- 解引用/取地址：`解引用（*ptr）` / `取地址（&x）`。
- 不使用模糊词（"适当地"、"相应地"等）；每个分支与循环条件写全，包含边界情况（之后要做完全形式化）。
- 伪代码正文（逻辑与测试要点节）不使用英文关键字、未翻译的裸英文标识符，以及 `{`、`}`、`;` 符号。允许的英文只有「首次对照」括号内的原名，如 `分词（tokenize）`。

G2.4 详细程度（全量逐语句）

- 所有函数逐语句展开为缩进式伪代码，不做概括（用户 2026-08-08 修订：之后要做完全形式化，信息不可省略）。
- 仅空文件（linker.cr 0 行）与纯引入文件（各 `_import.cr`、entry.cr 2 行）可以用两三句话简述，不建函数节。

G2.5 测试要点

- 每个函数节下方 `### 测试要点`，纯数字编号列表（1. 2. 3.，不用 emoji）。
- 内容：边界条件（空输入、最大/最小值、溢出、未初始化）、代表性输入与预期输出、错误路径（报错位置、返回值、部分结果）、状态转换（全局变量变化）。简单函数 1-2 条，复杂函数 5-8 条。

G2.6 文档基本结构（每个文件 .md 的结构；注意：同一源文件拆出的多个部分，每部分都独立使用此基本结构）

```markdown
# <文件名>.cr 伪代码
> 源文件：src/<目录>/<文件名>.cr（N 行）
> 功能概要：两句话说明该文件干什么

## 标识符对照表
（表格：| 中文名 | 原名 | 首次出现函数 |）

## 全局状态
（该文件涉及的全局变量，逐条说明含义与初始值）

## 函数 <中文名（原名）>
### 作用
（自然语言解释：该函数在编译管线/模块中的职责、为什么存在、输入输出的语义；
与「逻辑」区分：作用是"为什么和干什么"，逻辑是"怎么做"）
### 逻辑
（缩进式伪代码）
### 测试要点
1. ...
```

G2.7 翻译任务派发指令模板（任务 3-12 共用，按任务替换文件清单）

G2.8 大文件拆分规则（用户补充要求，2026-08-08）

- 源文件达到 800 行及以上时，其伪代码拆分为多个部分文档，文件名 `<源名>-<序号>.md`（如 `checker-1.md`、`checker-2.md`），序号从 1 连续递增
- 每部分覆盖一个逻辑相关的函数组（如按编译阶段/职责分组），每部分伪代码量约 400-600 行
- 拆分后每部分仍独立使用 G2.6 基本结构；「标识符对照表」列出该部分实际用到的标识符；「功能概要」说明该部分对应的源文件行号范围
- 拆分不改变"全量逐语句"要求：所有函数按同一标准处理，不因拆分丢函数
- 命中拆分：parser（1,691 行，拆为 4 部分）、checker（2,404 行，拆为 5 部分）、ir_gen（2,032 行，拆为 4 部分）、arch/elf（1,643 行，拆为 4 部分）、instr（1,203 行，拆为 3 部分）。其余 51 个源文件单文档
- 拆分后文档总数：56 个源文件拆为 71 个 .md（56 + 15 拆分增量）

> 派发 general-purpose agent，指令必须包含：
> 1. 任务：把下列源文件逐个翻译为伪代码文档，输出到指定路径（每文件一个 .md）
> 2. 先读 `docs/pseudocode/标识符对照表.md` 与 `docs/pseudocode/README.md`，共享标识符必须用术语表名字
> 3. 完整阅读每个源文件（一个不漏、一个不多），翻译遵循 G2.1-G2.6 全部约定
> 4. 只写自己的输出 .md 文件；禁止修改任何源文件或其他文档
> 5. 输出格式必须是 G2.6 的基本结构；函数节含「作用」+「逻辑」+「测试要点」三小节
> 6. 返回：产出的文件清单 + 每个文件的行数 + 翻译中遇到的疑难标识符（建议补充到术语表的条目）

### G3. 校验脚本约束

- 校验脚本放 `tools/`，命名 `pseudocode_*.py`，Python 3，无第三方依赖。
- 脚本必须通过 `python3 tools/pseudocode_check.py` 单命令运行，退出码 0 为通过。

---

### 任务 1：提取共享标识符，生成《标识符对照表》

涉及文件：
- 创建：`tools/pseudocode_extract.py`
- 创建：`docs/pseudocode/标识符对照表.md`

接口：
- 产出：`tools/pseudocode_extract.py`（提取脚本，任务 13 复用其解析逻辑思路）
- 产出：`docs/pseudocode/标识符对照表.md`（表格：| 中文名 | 原名 | 类别 | 出现文件数 | 出现文件 |；共享条目必须有中文名，翻译任务依赖它）

- [ ] 步骤 1：创建提取脚本 `tools/pseudocode_extract.py`

```python
#!/usr/bin/env python3
"""提取 Core 源码中的共享标识符，供生成伪代码术语表。用法：python3 tools/pseudocode_extract.py"""
import re, collections
from pathlib import Path

ROOTS = [Path("src/compiler"), Path("src/stdlib"),
         Path("src/runtime"), Path("src/arch/linux/ld")]
RE_FN = re.compile(r'\bfn\s+([a-zA-Z_]\w*)')
RE_STRUCT = re.compile(r'\bstruct\s+([A-Za-z_]\w*)')
RE_ENUM = re.compile(r'\benum\s+([A-Za-z_]\w*)')
RE_GLOBAL = re.compile(r'\bg_([a-zA-Z_]\w*)')

def main():
    counts = collections.Counter()
    per_file = collections.defaultdict(list)
    for root in ROOTS:
        for f in sorted(root.glob("*.cr")):
            text = f.read_text(encoding="utf-8")
            names = set()
            for m in RE_FN.finditer(text):       names.add(("fn", m.group(1)))
            for m in RE_STRUCT.finditer(text):   names.add(("struct", m.group(1)))
            for m in RE_ENUM.finditer(text):     names.add(("enum", m.group(1)))
            for m in RE_GLOBAL.finditer(text):   names.add(("global", "g_" + m.group(1)))
            for kind, n in names:
                counts[(kind, n)] += 1
                per_file[(kind, n)].append(str(f))
    for (kind, n), c in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0][0], kv[0][1])):
        print(f"{kind}\t{n}\t{c}\t{' '.join(per_file[(kind, n)])}")

if __name__ == "__main__":
    main()
```

- [ ] 步骤 2：运行脚本，确认输出合理

运行：`python3 tools/pseudocode_extract.py | head -20`
预期：每行 4 列（类别、原名、出现文件数、出现文件），如 `global	g_tok_cap	3	src/compiler/lexer.cr src/compiler/parser.cr src/compiler/dyn_arr.cr`。总数应覆盖各文件的 `g_` 全局、fn、struct、enum。

- [ ] 步骤 3：人工分配中文名，生成《标识符对照表》

对脚本输出逐一分配中文语义名，写入 `docs/pseudocode/标识符对照表.md`：

```markdown
# Core 标识符对照表（伪代码术语表）

> 本表是全部伪代码文档的跨文件一致性定位点。共享标识符（出现于多个文件、或以 g_ 开头、
> 或为 struct/enum 类型名、或为 stdlib 公开函数）必须使用本表名字，禁止自造。
> 生成方式：python3 tools/pseudocode_extract.py

## 命名规则
- 动词函数：直译动作，如 tokenize 对应分词、res_imports 对应解析引入
- 名词结构：意译含义，如 DFNode 对应数据流节点、Token 对应词法单元
- 缩写展开：calc 对应计算、res 对应解析、tbl 对应表、instr 对应指令、len 对应长度
- g_ 前缀省略：全局性由文档「全局状态」节体现
- 专有名词保持可回源：IR 指令名如 OP_ADD 类常量对应加法运算指令（OP_ADD）

## 对照表
| 中文名 | 原名 | 类别 | 出现文件数 | 出现文件 |
|--------|------|------|-----------|----------|
| Token 数组容量 | g_tok_cap | global | 3 | src/compiler/lexer.cr src/compiler/parser.cr src/compiler/dyn_arr.cr |
| 分词 | tokenize | fn | 2 | src/compiler/lexer.cr src/compiler/interp.cr |
| ……（脚本全部输出，逐条填写） | | | | |
```

- [ ] 步骤 4：自查：对照表覆盖全部 `g_*` 条目；每条中文名能无歧义回源；表格列数对齐。

- [ ] 步骤 5：提交

```bash
jj new -m "docs: 伪代码术语表（标识符对照表）+ 提取脚本"
jj squash --from @- --into @ tools/pseudocode_extract.py docs/pseudocode/标识符对照表.md
jj log -r @ --no-graph -T 'description.first_line()'
```

---

### 任务 2：README 基本结构（约定速查 + 范围说明）

涉及文件：
- 创建：`docs/pseudocode/README.md`

接口：
- 产出：`docs/pseudocode/README.md`（翻译 agent 的必读文件；任务 15 补充最终索引表）

- [ ] 步骤 1：创建 README.md，内容包含：

```markdown
# Core 源码伪代码文档

> 将 src/ 下全部 Core 语言源码（56 个 .cr 文件，19,749 行）翻译为无编程语言关键字的
> 汉语伪代码。用途：TDD 测试要点推导 + 远期完全形式化基础。

## 范围
- 已译：src/compiler/（29 文件）、src/stdlib/（18）、src/runtime/（2）、src/arch/linux/ld/（7）
- 排除：rt.s（汇编）、rt.ccr（编译产物）、bootstrap.c / compiler_rt.c（C 代码）、tests/、examples/
- 本目录结构镜像 src/，每文件一个 .md

## 约定速查
（完整约定见实现计划 Global Constraints G2，此处为速查）
| 源码 | 伪代码 |
|------|--------|
| if / else | 如果…那么： / 否则： |
| while / for | 循环（当…成立时）： / 对…遍历： |
| return | 返回 |
| fn / struct / enum | 函数 / 结构 / 枚举 |
| 声明 := | 令 名字 = 值 |
| true/false/None | 真 / 假 / 无值（None） |
| and/or/not | 且 / 或 / 非 |
| 比较运算符 | 等于/不等于/小于/不大于/大于/不小于 |
| + - * / % 位运算 | 保留符号 |

- 标识符：首次出现写作 中文名（原名），共享标识符必须用《标识符对照表.md》的名字
- 伪代码正文禁止：英文关键字、裸英文标识符、{ } ; 符号；禁止模糊词（"适当地"等）
- 每个函数节含「逻辑」（缩进式逐语句伪代码）+「测试要点」（编号列表）
- 详细程度：全量逐语句，不做概括；仅空文件与纯引入文件可简述

## 文件索引
（Task 15 完成后填写：compiler/ 29 个、stdlib/ 18 个、runtime/ 2 个、arch/linux/ld/ 7 个，
按目录分组列出每个 .md 链接与源文件行数）
```

- [ ] 步骤 2：提交

```bash
jj new -m "docs: 伪代码文档 README 基本结构"
jj squash --from @- --into @ docs/pseudocode/README.md
jj log -r @ --no-graph -T 'description.first_line()'
```

---

### 任务 3：翻译组 1，lexer.cr + parser.cr

涉及文件：
- 创建：`docs/pseudocode/compiler/lexer.md`（源：src/compiler/lexer.cr，393 行）
- 创建：`docs/pseudocode/compiler/parser-1.md` ~ `parser-4.md`（源：src/compiler/parser.cr，1,691 行，按 G2.8 拆 4 部分）

接口：
- 使用：术语表 `docs/pseudocode/标识符对照表.md`、README `docs/pseudocode/README.md`
- 产出：上述 5 个 .md，供任务 13 校验

- [ ] 步骤 1：派发翻译 agent（按 G2.7 指令模板；parser 按 G2.8 拆 4 部分）
- [ ] 步骤 2：验收：5 个 .md 存在；每个含 G2.6 全部章节；抽查 lexer 的 `tokenize`（分词）函数节为逐语句级；抽查无裸英文残留（除对照括号）
- [ ] 步骤 3：提交

```bash
jj new
jj squash --from @- --into @ docs/pseudocode/compiler/lexer.md docs/pseudocode/compiler/parser-1.md docs/pseudocode/compiler/parser-2.md docs/pseudocode/compiler/parser-3.md docs/pseudocode/compiler/parser-4.md
jj describe @ -m "docs: 伪代码 lexer + parser"
jj log -r @ --no-graph -T 'description.first_line()'
```

---

### 任务 4：翻译组 2，checker.cr + ast.cr

涉及文件：
- 创建：`docs/pseudocode/compiler/checker-1.md` ~ `checker-5.md`（源：src/compiler/checker.cr，2,404 行，按 G2.8 拆 5 部分）
- 创建：`docs/pseudocode/compiler/ast.md`（源：src/compiler/ast.cr，629 行）

接口：
- 使用：术语表、README
- 产出：上述 6 个 .md

- [ ] 步骤 1：派发翻译 agent（按 G2.7 指令模板；checker 按 G2.8 拆 5 部分）
- [ ] 步骤 2：验收：6 个 .md 存在且章节完整；checker 各部分的函数节合计与 checker.cr 的 fn 数一致
- [ ] 步骤 3：提交

```bash
jj new
jj squash --from @- --into @ docs/pseudocode/compiler/checker-1.md docs/pseudocode/compiler/checker-2.md docs/pseudocode/compiler/checker-3.md docs/pseudocode/compiler/checker-4.md docs/pseudocode/compiler/checker-5.md docs/pseudocode/compiler/ast.md
jj describe @ -m "docs: 伪代码 checker + ast"
jj log -r @ --no-graph -T 'description.first_line()'
```

---

### 任务 5：翻译组 3，ir_gen.cr

涉及文件：
- 创建：`docs/pseudocode/compiler/ir_gen-1.md` ~ `ir_gen-4.md`（源：src/compiler/ir_gen.cr，2,032 行，按 G2.8 拆 4 部分）

接口：
- 使用：术语表、README
- 产出：上述 4 个 .md

- [ ] 步骤 1：派发翻译 agent（按 G2.7 指令模板；ir_gen 按 G2.8 拆 4 部分）
- [ ] 步骤 2：验收：4 个 .md 存在且章节完整；各部分的函数节合计与 fn 数一致
- [ ] 步骤 3：提交

```bash
jj new
jj squash --from @- --into @ docs/pseudocode/compiler/ir_gen-1.md docs/pseudocode/compiler/ir_gen-2.md docs/pseudocode/compiler/ir_gen-3.md docs/pseudocode/compiler/ir_gen-4.md
jj describe @ -m "docs: 伪代码 ir_gen"
jj log -r @ --no-graph -T 'description.first_line()'
```

---

### 任务 6：翻译组 4，dataflow.cr + ccr_io.cr + cir_cache.cr

涉及文件：
- 创建：`docs/pseudocode/compiler/dataflow.md`（源：src/compiler/dataflow.cr，521 行）
- 创建：`docs/pseudocode/compiler/ccr_io.md`（源：src/compiler/ccr_io.cr，594 行）
- 创建：`docs/pseudocode/compiler/cir_cache.md`（源：src/compiler/cir_cache.cr，314 行）

接口：
- 使用：术语表、README
- 产出：上述三个 .md

- [ ] 步骤 1：派发翻译 agent（按 G2.7 指令模板）
- [ ] 步骤 2：验收：三个 .md 存在且章节完整
- [ ] 步骤 3：提交

```bash
jj new -m "docs: 伪代码 dataflow + ccr_io + cir_cache"
jj squash --from @- --into @ docs/pseudocode/compiler/dataflow.md docs/pseudocode/compiler/ccr_io.md docs/pseudocode/compiler/cir_cache.md
jj log -r @ --no-graph -T 'description.first_line()'
```

---

### 任务 7：翻译组 5，opt.cr + pass.cr + dyn_arr.cr + interp.cr + dump.cr

涉及文件：
- 创建：`docs/pseudocode/compiler/opt.md`（源：src/compiler/opt.cr，525 行）
- 创建：`docs/pseudocode/compiler/pass.md`（源：src/compiler/pass.cr，24 行）
- 创建：`docs/pseudocode/compiler/dyn_arr.md`（源：src/compiler/dyn_arr.cr，786 行）
- 创建：`docs/pseudocode/compiler/interp.md`（源：src/compiler/interp.cr，384 行）
- 创建：`docs/pseudocode/compiler/dump.md`（源：src/compiler/dump.cr，334 行）

接口：
- 使用：术语表、README
- 产出：上述五个 .md

- [ ] 步骤 1：派发翻译 agent（按 G2.7 指令模板）
- [ ] 步骤 2：验收：五个 .md 存在且章节完整
- [ ] 步骤 3：提交

```bash
jj new
jj squash --from @- --into @ docs/pseudocode/compiler/opt.md docs/pseudocode/compiler/pass.md docs/pseudocode/compiler/dyn_arr.md docs/pseudocode/compiler/interp.md docs/pseudocode/compiler/dump.md
jj describe @ -m "docs: 伪代码 opt + pass + dyn_arr + interp + dump"
jj log -r @ --no-graph -T 'description.first_line()'
```

---

### 任务 8：翻译组 6，main.cr + corearch.cr + module.cr + project.cr + diag.cr + globals.cr + entry.cr + _import.cr + elf.cr + linker.cr

涉及文件：
- 创建：`docs/pseudocode/compiler/main.md`（源：src/compiler/main.cr，587 行）
- 创建：`docs/pseudocode/compiler/corearch.md`（源：src/compiler/corearch.cr，149 行）
- 创建：`docs/pseudocode/compiler/module.md`（源：src/compiler/module.cr，552 行）
- 创建：`docs/pseudocode/compiler/project.md`（源：src/compiler/project.cr，56 行）
- 创建：`docs/pseudocode/compiler/diag.md`（源：src/compiler/diag.cr，154 行）
- 创建：`docs/pseudocode/compiler/globals.md`（源：src/compiler/globals.cr，182 行）
- 创建：`docs/pseudocode/compiler/entry.md`（源：src/compiler/entry.cr，2 行；纯引入，简述）
- 创建：`docs/pseudocode/compiler/_import.md`（源：src/compiler/_import.cr，34 行；纯引入，简述）
- 创建：`docs/pseudocode/compiler/elf.md`（源：src/compiler/elf.cr，566 行）
- 创建：`docs/pseudocode/compiler/linker.md`（源：src/compiler/linker.cr，0 行；空文件，简述）

接口：
- 使用：术语表、README
- 产出：上述十个 .md

- [ ] 步骤 1：派发翻译 agent（按 G2.7 指令模板；entry/_import/linker 三文件按 G2.4 简述规则）
- [ ] 步骤 2：验收：十个 .md 存在；entry.md、_import.md、linker.md 为简述型
- [ ] 步骤 3：提交

```bash
jj new
jj squash --from @- --into @ docs/pseudocode/compiler/main.md docs/pseudocode/compiler/corearch.md docs/pseudocode/compiler/module.md docs/pseudocode/compiler/project.md docs/pseudocode/compiler/diag.md docs/pseudocode/compiler/globals.md docs/pseudocode/compiler/entry.md docs/pseudocode/compiler/_import.md docs/pseudocode/compiler/elf.md docs/pseudocode/compiler/linker.md
jj describe @ -m "docs: 伪代码 main + corearch + module + project + diag + globals + entry + _import + elf + linker"
jj log -r @ --no-graph -T 'description.first_line()'
```

---

### 任务 9：翻译组 7，ext_mgr.cr + ext_safety.cr + monomorph.cr + provenance_verify.cr + ptr_analysis.cr + region_check.cr

涉及文件：
- 创建：`docs/pseudocode/compiler/ext_mgr.md`（源：src/compiler/ext_mgr.cr，93 行）
- 创建：`docs/pseudocode/compiler/ext_safety.md`（源：src/compiler/ext_safety.cr，37 行）
- 创建：`docs/pseudocode/compiler/monomorph.md`（源：src/compiler/monomorph.cr，438 行）
- 创建：`docs/pseudocode/compiler/provenance_verify.md`（源：src/compiler/provenance_verify.cr，90 行）
- 创建：`docs/pseudocode/compiler/ptr_analysis.md`（源：src/compiler/ptr_analysis.cr，283 行）
- 创建：`docs/pseudocode/compiler/region_check.md`（源：src/compiler/region_check.cr，156 行）

接口：
- 使用：术语表、README
- 产出：上述六个 .md

- [ ] 步骤 1：派发翻译 agent（按 G2.7 指令模板）
- [ ] 步骤 2：验收：六个 .md 存在且章节完整
- [ ] 步骤 3：提交

```bash
jj new
jj squash --from @- --into @ docs/pseudocode/compiler/ext_mgr.md docs/pseudocode/compiler/ext_safety.md docs/pseudocode/compiler/monomorph.md docs/pseudocode/compiler/provenance_verify.md docs/pseudocode/compiler/ptr_analysis.md docs/pseudocode/compiler/region_check.md
jj describe @ -m "docs: 伪代码 ext_mgr + ext_safety + monomorph + provenance_verify + ptr_analysis + region_check"
jj log -r @ --no-graph -T 'description.first_line()'
```

---

### 任务 10：翻译组 8，stdlib 全部 18 个文件

涉及文件：
- 创建：`docs/pseudocode/stdlib/_import.md`（源：src/stdlib/_import.cr，3 行；纯引入，简述）
- 创建：`docs/pseudocode/stdlib/arena.md`（源：src/stdlib/arena.cr，99 行）
- 创建：`docs/pseudocode/stdlib/assert.md`（源：src/stdlib/assert.cr，125 行）
- 创建：`docs/pseudocode/stdlib/chan.md`（源：src/stdlib/chan.cr，181 行）
- 创建：`docs/pseudocode/stdlib/cli.md`（源：src/stdlib/cli.cr，373 行）
- 创建：`docs/pseudocode/stdlib/collections.md`（源：src/stdlib/collections.cr，126 行）
- 创建：`docs/pseudocode/stdlib/fmt.md`（源：src/stdlib/fmt.cr，192 行）
- 创建：`docs/pseudocode/stdlib/goroutine.md`（源：src/stdlib/goroutine.cr，70 行）
- 创建：`docs/pseudocode/stdlib/hotpatch.md`（源：src/stdlib/hotpatch.cr，47 行）
- 创建：`docs/pseudocode/stdlib/io.md`（源：src/stdlib/io.cr，52 行）
- 创建：`docs/pseudocode/stdlib/math.md`（源：src/stdlib/math.cr，77 行）
- 创建：`docs/pseudocode/stdlib/os.md`（源：src/stdlib/os.cr，104 行）
- 创建：`docs/pseudocode/stdlib/panic.md`（源：src/stdlib/panic.cr，48 行）
- 创建：`docs/pseudocode/stdlib/sched.md`（源：src/stdlib/sched.cr，205 行）
- 创建：`docs/pseudocode/stdlib/scheduler.md`（源：src/stdlib/scheduler.cr，154 行）
- 创建：`docs/pseudocode/stdlib/toml.md`（源：src/stdlib/toml.cr，168 行）
- 创建：`docs/pseudocode/stdlib/trace.md`（源：src/stdlib/trace.cr，23 行）
- 创建：`docs/pseudocode/stdlib/variadic.md`（源：src/stdlib/variadic.cr，34 行）

接口：
- 使用：术语表、README
- 产出：上述 18 个 .md（stdlib 公开函数名是共享标识符，必须与术语表一致；编译器文件里的同名 stdlib 调用也用它）

- [ ] 步骤 1：派发翻译 agent（按 G2.7 指令模板）
- [ ] 步骤 2：验收：18 个 .md 存在；stdlib 公开函数（如 打印（print）、读文件（read_file））的中文名与术语表一致
- [ ] 步骤 3：提交

```bash
jj new
jj squash --from @- --into @ docs/pseudocode/stdlib
jj describe @ -m "docs: 伪代码 stdlib 全部 18 文件"
jj log -r @ --no-graph -T 'description.first_line()'
```

---

### 任务 11：翻译组 9，arch/linux/ld 全部 7 个文件

涉及文件：
- 创建：`docs/pseudocode/arch/linux/ld/_import.md`（源：src/arch/linux/ld/_import.cr，15 行；纯引入，简述）
- 创建：`docs/pseudocode/arch/linux/ld/elf-1.md` ~ `elf-4.md`（源：src/arch/linux/ld/elf.cr，1,643 行，按 G2.8 拆 4 部分）
- 创建：`docs/pseudocode/arch/linux/ld/instr-1.md` ~ `instr-3.md`（源：src/arch/linux/ld/instr.cr，1,203 行，按 G2.8 拆 3 部分）
- 创建：`docs/pseudocode/arch/linux/ld/ld.md`（源：src/arch/linux/ld/ld.cr，477 行）
- 创建：`docs/pseudocode/arch/linux/ld/main.md`（源：src/arch/linux/ld/main.cr，136 行）
- 创建：`docs/pseudocode/arch/linux/ld/resolve.md`（源：src/arch/linux/ld/resolve.cr，91 行）
- 创建：`docs/pseudocode/arch/linux/ld/sizes.md`（源：src/arch/linux/ld/sizes.cr，75 行）

接口：
- 使用：术语表、README
- 产出：上述 11 个 .md

- [ ] 步骤 1：派发翻译 agent（按 G2.7 指令模板；elf/instr 按 G2.8 拆分；本组包含汇编指令编码细节，条件/边界必须写全）
- [ ] 步骤 2：验收：11 个 .md 存在；instr 各部分的每个指令发射函数节都有测试要点
- [ ] 步骤 3：提交

```bash
jj new
jj squash --from @- --into @ docs/pseudocode/arch/linux/ld
jj describe @ -m "docs: 伪代码 arch/linux/ld 全部 7 文件"
jj log -r @ --no-graph -T 'description.first_line()'
```

---

### 任务 12：翻译组 10，runtime 2 个文件

涉及文件：
- 创建：`docs/pseudocode/runtime/rt.md`（源：src/runtime/rt.cr，14 行）
- 创建：`docs/pseudocode/runtime/arena_globals.md`（源：src/runtime/arena_globals.cr，4 行）

接口：
- 使用：术语表、README
- 产出：上述 2 个 .md

- [ ] 步骤 1：派发翻译 agent（按 G2.7 指令模板；两文件极小，逐语句翻译即可）
- [ ] 步骤 2：验收：2 个 .md 存在且章节完整
- [ ] 步骤 3：提交

```bash
jj new
jj squash --from @- --into @ docs/pseudocode/runtime/rt.md docs/pseudocode/runtime/arena_globals.md
jj describe @ -m "docs: 伪代码 runtime 2 文件"
jj log -r @ --no-graph -T 'description.first_line()'
```

---

### 任务 13：质量校验脚本

涉及文件：
- 创建：`tools/pseudocode_check.py`

接口：
- 使用：`docs/pseudocode/` 全部产物、`docs/pseudocode/标识符对照表.md`
- 产出：校验结果清单（任务 14 修复依据）

- [ ] 步骤 1：创建校验脚本 `tools/pseudocode_check.py`

```python
#!/usr/bin/env python3
"""校验 docs/pseudocode/ 伪代码文档质量。用法：python3 tools/pseudocode_check.py
检查项：
1) 表格行外、首次对照括号外不允许出现任何英文标识符残留
2) 任何位置不允许 { } ; 符号
3) 必需章节存在（标识符对照表 / 全局状态）
4) 每个「### 函数」节必须含「### 作用」与「### 测试要点」
5) 术语一致性：文件中共享标识符的对照必须与全局术语表一致
退出码 0 = 通过，1 = 有错误。"""
import re, sys
from pathlib import Path

ROOT = Path("docs/pseudocode")
GLOSSARY = ROOT / "标识符对照表.md"
RE_TOKEN = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
RE_PARA = re.compile(r"（[^（）]*）")          # 首次对照括号
RE_TABLE_ROW = re.compile(r"^\s*\|")
RE_FN_SEC = re.compile(r"^### 函数[^\n]*\n(.*?)(?=^### |^## )", re.M | re.S)

errors = []

# 读全局术语表：原名 -> 中文名（共享条目）
glossary = {}
if GLOSSARY.exists():
    for line in GLOSSARY.read_text(encoding="utf-8").splitlines():
        if not line.startswith("|") or "原名" in line:
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if len(cells) >= 2 and re.fullmatch(r"[A-Za-z_]\w*", cells[1]):
            glossary[cells[1]] = cells[0]

for md in sorted(ROOT.rglob("*.md")):
    if md.name in ("README.md", "标识符对照表.md"):
        continue
    text = md.read_text(encoding="utf-8")
    for ln, line in enumerate(text.splitlines(), 1):
        if any(ch in line for ch in "{};"):
            errors.append(f"{md}:{ln}: 禁止符号 {[c for c in '{};' if c in line]}")
        if RE_TABLE_ROW.match(line):
            continue
        clean = RE_PARA.sub("", line)          # 去掉（原名）括号内容
        for tok in RE_TOKEN.findall(clean):
            errors.append(f"{md}:{ln}: 英文残留 {tok}")
    for sec in ("## 标识符对照表", "## 全局状态"):
        if sec not in text:
            errors.append(f"{md}: 缺少章节 {sec}")
    for m in RE_FN_SEC.finditer(text):
        if "### 作用" not in m.group(1):
            errors.append(f"{md}: 函数节 {m.group(0).splitlines()[0]} 缺少作用说明")
        if "### 测试要点" not in m.group(1):
            errors.append(f"{md}: 函数节 {m.group(0).splitlines()[0]} 缺少测试要点")
    # 术语一致性：文件对照表中出现的共享标识符必须与术语表同名
    file_map = {}
    for line in text.splitlines():
        if not line.startswith("|") or "原名" in line:
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if len(cells) >= 2 and re.fullmatch(r"[A-Za-z_]\w*", cells[1]):
            file_map[cells[1]] = cells[0]
    for orig, zh in file_map.items():
        if orig in glossary and glossary[orig] != zh:
            errors.append(f"{md}: 术语不一致 {orig}: 术语表={glossary[orig]} 本文件={zh}")

if errors:
    print(f"{len(errors)} 个问题：")
    for e in errors[:100]:
        print(" ", e)
    sys.exit(1)
print(f"OK: {len(list(ROOT.rglob('*.md'))) - 2} 个文档全部通过")
```

- [ ] 步骤 2：运行脚本

运行：`python3 tools/pseudocode_check.py`
预期：输出 "OK: 69 个文档全部通过" 且退出码 0（此时 69 个翻译产物 + README + 术语表 = 71 个 .md，含拆分增量）。
若出现误报（如「测试要点」里引用了英文常量名）：修正文档而非放宽脚本（先对照括号补原名，或把常量名也纳入对照表翻译）。

- [ ] 步骤 3：提交

```bash
jj new
jj squash --from @- --into @ tools/pseudocode_check.py
jj describe @ -m "tools: 伪代码质量校验脚本"
jj log -r @ --no-graph -T 'description.first_line()'
```

---

### 任务 14：修复阶段

涉及文件：
- 修改：`docs/pseudocode/` 下的全部文件（按任务 13 报错清单修复）

接口：
- 使用：任务 13 的报错清单
- 产出：全部通过的校验结果

- [ ] 步骤 1：逐条修复任务 13 报出的问题（英文残留则补翻译或对照括号；缺章节则补；缺测试要点则补；术语不一致则改用术语表名字）
- [ ] 步骤 2：重新运行校验直到全部通过

运行：`python3 tools/pseudocode_check.py`
预期：`OK: 69 个文档全部通过`，退出码 0

- [ ] 步骤 3：抽查至少 10 个文档（约 20%）的测试要点质量（各取 2-3 条，核对是否覆盖边界/错误路径）
- [ ] 步骤 4：提交

```bash
jj new
jj squash --from @- --into @ docs/pseudocode
jj describe @ -m "docs: 伪代码校验修复"
jj log -r @ --no-graph -T 'description.first_line()'
```

---

### 任务 15：README 索引填充 + 最终验收

涉及文件：
- 修改：`docs/pseudocode/README.md`（填充「文件索引」节）

接口：
- 使用：全部 54 个翻译产物
- 产出：最终交付（56 个 .md + 2 个工具脚本）

- [ ] 步骤 1：填充 README「文件索引」：按 4 个目录分组列出全部 71 个 .md（compiler/ 29 个源文件对应 39 个文档、stdlib/ 18 个、runtime/ 2 个、arch/linux/ld/ 7 个源文件对应 11 个文档），每个条目链接 + 源文件行数（拆分文档标注所属部分）

```markdown
## 文件索引
### compiler/（29 个源文件对应 39 个文档）
- [lexer.md](compiler/lexer.md)（源 393 行）
- [parser-1.md](compiler/parser-1.md)（源 1,691 行，第 1/4 部分）
- ……全部列出……
### stdlib/（18 个源文件对应 18 个文档）
### runtime/（2 个源文件对应 2 个文档）
### arch/linux/ld/（7 个源文件对应 11 个文档）
```

- [ ] 步骤 2：最终验收

运行：`python3 tools/pseudocode_check.py`
预期：`OK: 69 个文档全部通过`，退出码 0
运行：`find docs/pseudocode -name '*.md' | wc -l`
预期：`71`（69 翻译产物 + README + 术语表）
运行：`find docs/pseudocode -name '*.md' | xargs wc -l | tail -1`
预期：伪代码总量不少于源码总量的一半（约 ≥10,000 行），验证全量逐语句翻译到位

- [ ] 步骤 3：提交

```bash
jj new
jj squash --from @- --into @ docs/pseudocode/README.md
jj describe @ -m "docs: 伪代码 README 索引 + 最终验收"
jj log -r @ --no-graph -T 'description.first_line()'
```

- [ ] 步骤 4：向用户报告交付：71 个 .md 路径、校验结果、测试要点抽查结论、术语表与工具脚本位置

---

## 执行前自查记录

- 规格覆盖：范围（56 文件）对应任务 1/3-12；术语表对应任务 1；目录结构对应任务 1/2/3-12；翻译约定 G2 对应 全局约束；全量逐语句对应 G2.4；测试要点对应 G2.5；并行分组对应任务 3-12；质量控制对应任务 13/14；完成标准对应任务 13/15。全部覆盖。
- 占位符扫描：无 TBD/TODO；每个任务的验收与提交命令均为具体命令。
- 类型与命名一致性：校验脚本与提取脚本的表格解析列序一致（中文名|原名|…）；术语表键为原名、值为中文名，两脚本一致；输出文件路径在任务 3-12 与任务 13 校验范围、任务 15 索引三处一致（56 个 .md 的路径逐一核对）。
