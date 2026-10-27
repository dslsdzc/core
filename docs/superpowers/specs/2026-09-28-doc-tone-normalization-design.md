# 文档文风规范设计

日期：2026-09-28
状态：草稿，待批准

## 背景

Core 文档已经有两项约定：按读者划分的目录结构，以及每篇文档开头的定位声明（受众、状态、真源）。缺少的是正文怎么写。

现在有三类问题。

第一，命令口吻。`CLAUDE.md` 写“不许”“禁止”，还写明违反的后果。

第二，用比喻代替术语。程序概念被套上身体部位、生死状态一类的词，当作术语使用，但多数没有定义。

第三，符号过多。方括号标签“【高危·预存】”、警告符号、对勾符号，以及平均每行一次的粗体。

以前整理过一次。`CHANGELOG.md` 保留了那次记录：`tone down chuunibyou conclusions`、`remove conversational/promotional language`。那次清理的是宣传式写法，而且只清理了 `docs/`。现在新增的问题主要是检查式写法，集中在 `TODO.md` 和 `docs/superpowers/`。

## 目标写法

参照 LLVM 文档。有三个特点。

用陈述句。规则写出来，后面跟理由。例如：

> There are some conventions that are not uniformly followed in the code base (e.g. the naming convention). This is because they are relatively new, and a lot of code was written before they were put in place. Our long-term goal is for the entire codebase to follow the convention, but we explicitly do not want patches that do large-scale reformatting of existing code.

不用装饰性符号。LLVM 九篇正文约两万行，没有 emoji，没有警告符号；感叹号 23 个，几乎都在代码和网址里。需要提醒读者时写 `Note`、`Warning`。

旧结论不划掉。废弃的命名在正文里平铺一句（`In the past, this namespace had only the name GR …`）。删除线和检查批注交给版本控制。

## 规范

编写 `docs/doc-style.md`，一页以内，用上面这种写法。内容：

- 用陈述句，规则后面跟理由。
- 工程文档只记录事实、动作、证据、决定和结果，不写第一人称和个人意见。
- 不写“不许”“禁止”，也不写违反的后果。
- 不用比喻和拟人。一个概念需要反复使用时，第一次出现给出定义，之后按定义使用。
- 不用 emoji、警告符号、对勾符号和方括号标签。需要提醒时写“注：”“重要：”“警告：”。
- 标题不加编号，标题说明这一节讲什么。已有文档的编号如果被其他位置引用，保留编号。
- 中文正文用全角标点（，。：；），代码、标识符和英文串里用半角。
- 旧结论用带日期的说明保留，不使用删除线。
- 保留现有的定位声明、真源规则和分类结构。这几项本仓库比 LLVM 做得好。

## 实施

1. 编写 `docs/doc-style.md`。
2. 先修改三份文档，用它们检查规范是否合适：
   - `docs/developer/syntax.md`（现状较接近）
   - `docs/maintainer/design/execution-model.md`（半角标点）
   - `docs/superpowers/plans/2026-09-16-criteria-carrier.md`（检查式写法最重）

   修改时发现规范不合适，就回头修改规范。
3. 其余按目录依次修改：根目录和 `docs/developer`，然后 `docs/maintainer`，然后 `docs/academic` 等零散目录，然后 `docs/superpowers`，最后 `docs/pseudocode`。
4. 每改完一组通读一遍，开 PR 交给维护者审阅。

文档是否像工程文档，需要人读了才能判断，不增加自动检查。只有文档之间的链接需要机器确认，修改后检查链接目标是否还在。

## CLAUDE.md

它同时是给 AI 的指令和自动检查的实现方式，与其他文档不同。写法照改，但下面这些内容保持不变：

- 硬性规则的标题和 #1–#6 编号。`tools/baseline/canary_check.sh:22` 按编号引用“硬性规则 6”。
- `TODO #2026-09-10-3` 的引用形式，在 `elf.cr` 未使用文件那一条里。`tests/harness/test_todo_id_migration.py` 的 J4 用例取自这里。
- `jj` / `git` 禁令的含义。`.claude/hooks/block-git.py` 负责这一项。
- 各自动检查的命令、路径和计数。

修改完成后运行这两个测试，确认没有破坏：

```bash
python3 tests/harness/test_todo_id_migration.py
python3 tests/harness/test_block_git.py
```

## 范围

文字和内容分两次修改。第一次只改文字：事实、数字、结论、链接目标、`file:line`、提交 sha 都不动。文档与实现不符的说法，按 `2026-09-16-doc-reality-audit.md` 的 35 条另开一次修改。两类改动放在同一个 diff 里无法审阅。

计划文档和实施记录分开存放：计划写要做什么、怎么做、验收条件；实施记录写实际做了什么、结果和偏差。两者开头互相链接。

`docs/pseudocode/` 由源码生成（`tools/pseudocode_check.py`），修改之前先确认生成器是否也产出这些文字。

`docs/archive/sdd/` 下的 321 份文件不在范围内。它们没有进入版本控制，是 SDD 工具的暂存区。

## 待定

1. 标点使用全角。`glossary.md` 已经是这个分工：中文说明用全角，代码和标识符用半角。
2. 内容修改另开一次，不与文字修改一起做。
