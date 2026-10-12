# 文档文风规范设计

日期：2026-09-28
状态：草稿，待批准

## 为什么

Core 的文档已经有两套规矩：按读者分的目录树，和每篇开头的定位声明（受众 / 状态 / 真源）。缺的是怎么写。

问题有三类。

一是用命令口吻。`CLAUDE.md` 写「不许」「禁止」，还写明违反的后果。

二是拿比喻当名词用。判据叫「有牙」，执行分支叫「腿」，没修的缺陷叫「还活着」，关掉的条目叫「划销」。这些词当术语在用，却多数没有定义。

三是满屏符号。方括号标签「【高危·预存】」、`⚠`、`✅`、平均每行一次的粗体。

以前清过一次。`CHANGELOG.md` 里留着那次记录：`tone down chuunibyou conclusions`、`remove conversational/promotional language`。那次清的是宣传式的写法，且只清了 `docs/`。现在多出来的是审计式的写法，主要在 `TODO.md` 和 `docs/superpowers/`。

## 写成什么样

照 LLVM 写。三个特征：

**用陈述句。** 规则说出来，后面跟理由，三句讲完：

> There are some conventions that are not uniformly followed in the code base (e.g. the naming convention). This is because they are relatively new, and a lot of code was written before they were put in place. Our long-term goal is for the entire codebase to follow the convention, but we explicitly do not want patches that do large-scale reformatting of existing code.

**不修饰。** LLVM 九篇正文约两万行，没有 emoji，没有 `⚠`；感叹号 23 个，几乎都在代码和网址里。要提醒读者就写 `Note`、`Warning`。

**旧结论不划掉。** 废弃的命名在正文里平铺一句（`In the past, this namespace had only the name GR …`）。删除线和审计批注交给版本控制。

## 规范

写 `docs/doc-style.md`，一页以内，用上面那种写法写。内容：

- 用陈述句。规则后面跟理由。
- 不写「不许」「禁止」，也不写违反的后果。
- 比喻不当术语。一个概念要反复用，第一次出现时给定义，之后当普通词用。
- 不用 emoji、`⚠`、`✅` 和方括号标签。要提醒时写「注：」「重要：」「警告：」。
- 标题不加编号，标题说明这节讲什么。
- 中文正文用全角标点（`，` `：` `；`），代码、标识符和英文串里用半角。
- 旧的结论用带日期的说明留住，不划删除线。
- 保留现有的定位声明、真源条款和分类树。这几项本仓比 LLVM 做得好。

## 怎么做

1. 写 `docs/doc-style.md`。
2. 先改三份，用它们试出规范哪里不对：
   - `docs/developer/syntax.md`（现状已较接近）
   - `docs/maintainer/design/execution-model.md`（半角标点）
   - `docs/superpowers/plans/2026-09-16-criteria-carrier.md`（审计式写法最重）

   改的时候发现规范写得不对，就回头改规范。
3. 其余按目录依次改：根目录和 `docs/developer` → `docs/maintainer` → `docs/academic` 等零散目录 → `docs/superpowers` → `docs/pseudocode`。
4. 每改完一批通读一遍，开 PR 给人看。

像不像工程文档，要人读了才算，不加自动检查。只有文档之间的链接需要机器确认，改完看链接目标还在不在。

## CLAUDE.md

它同时是给 AI 的指令和机械门的载体，跟别的文档不一样。写法照改，但下面这些一字不动：

- 铁律的标题和 #1–#6 编号。`tools/baseline/canary_check.sh:22` 按编号引用「铁律 6」。
- `TODO #2026-09-10-3` 的引用形式，在 `elf.cr` 死文件那一条里。`tests/harness/test_todo_id_migration.py` 的 J4 用例取自这里。
- `jj` / `git` 禁令的意思。`.claude/hooks/block-git.py` 管着这一面。
- 各机械门的命令、路径和计数。

改完跑这两个测试确认没坏：

```bash
python3 tests/harness/test_todo_id_migration.py
python3 tests/harness/test_block_git.py
```

## 范围

文字和内容分两次改。第一次只改文字：事实、数字、结论、链接目标、`file:line`、提交 sha 都不动。文档里跟实现不符的说法，按 `2026-09-16-doc-reality-audit.md` 的 35 条另开一次改。两类改动混在一个 diff 里没法审。

`docs/pseudocode/` 由源码生成（`tools/pseudocode_check.py`），改之前先看生成器是不是也产出这些文字。

`.superpowers/sdd/` 下的 321 份不在范围内。它们没进版本控制，是 SDD 工具的暂存区。

## 待定

1. 标点按全角。`glossary.md` 已经是这个分工：中文说明用全角，代码和标识符用半角。
2. 改内容另开一次，不跟改文字一起做。
