# 核心维护文档重组与首批重写 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `docs/` 平铺的 156 份 md 按「主题 × 读者 × 状态」分类树重组,并完成首批新增/重写范本(含 jj 提交策略,遵守仓库铁律)。

**Architecture:** 机械性重组(目录移动 + 链接修复)先行并独立提交;内容性工作(新建手册/ADR/重写范本)逐个任务产出,每任务可独立验收。全程用 `jj` 不用 `git`(CLAUDE.md 铁律 #2)。

**Tech Stack:** jj 版本控制、bash(grep/sed/mv)、Markdown。无代码构建。

**Spec:** `docs/superpowers/specs/2026-09-06-core-maintainer-docs-reorg-design.md`

## Global Constraints

1. 版本控制只用 `jj`(禁 `git`,铁律 #2);提交必须经用户许可,计划中的提交步骤执行前先向用户确认工作副本 src 改动的归属
2. 文件永久不允许还原(铁律 #3)——移动不复制,mv 前确认目标不存在
3. 每份文档头部强制加定位声明:受众(users/maintainers/contributors)+ 状态(active/superseded/deprecated/archive/proposal)+ 真源声明
4. 一份文档一个职责;状态与内容冲突时更新文档,不添加免责段
5. docs/README.md 为唯一导航索引,与目录树一致
6. docs/pseudocode/ 与 docs/superpowers/ 不动;coq/ ir-schema/ verifier/ 原样只加头注
7. 文档互链一律相对路径,指向新位置;旧路径引用必须在引用方(含 CLAUDE.md/README.md/TODO.md/CHANGELOG.md)同步更新,验收用 grep 断链检查

---

### Task 1: 建目录骨架 + 存量文件归位(机械移动)

**Files:**
- Create 目录:`docs/language/ docs/design/ docs/proposals/ docs/archive/ docs/maintainer/ docs/adr/`
- Move(29 份顶层 md → 新位置,见下)
- 不触碰:`docs/pseudocode/ docs/superpowers/ docs/coq/ docs/ir-schema/ docs/verifier/ docs/LICENSE`

**归位表(源 → 目标,逐条执行,先查目标不存在再 mv):**

| 源 | 目标 |
|---|---|
| language-syntax.md | language/syntax.md |
| learning-path.md | language/learning-path.md |
| error-codes.md | language/error-codes.md |
| editor-setup.md | language/editor-setup.md(用户配置部分;corelsp 架构段先随文件走,Task 5 拆分) |
| project-book.md | design/project-book.md |
| execution-model.md | design/execution-model.md |
| dataflow-design.md | design/dataflow-design.md |
| memory-model.md | design/memory-model.md |
| pointer-model.md | design/pointer-model.md |
| regalloc-cache-mapping.md | design/regalloc-cache-mapping.md |
| ir-op-semantics.md | design/ir-op-semantics.md |
| glossary.md | design/glossary.md |
| spec-design.md | design/spec-design.md |
| verifier-kernel.md | design/verifier-kernel.md |
| at-intrinsics.md | design/at-intrinsics.md |
| crasm.md | design/crasm.md |
| generics.md | proposals/generics.md |
| comptime.md | proposals/comptime.md |
| ffi.md | proposals/ffi.md |
| concurrency.md | proposals/concurrency.md |
| dynamic-typing.md | proposals/dynamic-typing.md |
| lazy.md | proposals/lazy.md |
| distributed.md | proposals/distributed.md |
| probabilistic.md | proposals/probabilistic.md |
| compcert-reference.md | archive/compcert-reference.md |
| compcert-round4-findings.md | archive/compcert-round4-findings.md |
| numeric-migration-inventory.md | archive/numeric-migration-inventory.md |
| memory-model-capability-lattice.md | archive/memory-model-capability-lattice.md |

z-vision.md 保留 docs/ 顶层(愿景入口)。

- [ ] **Step 1: 自检 git 状态,确认基线**

```bash
cd /home/DslsDZC/core
jj st   # 预期:docs/superpowers/specs/2026-09-06-...-design.md(新增)+ src/compiler 三份改动(用户工作,勿动)
```

- [ ] **Step 2: 建目录**

```bash
mkdir -p docs/language docs/design docs/proposals docs/archive docs/maintainer docs/adr
```

- [ ] **Step 3: 逐条 mv(示例,共 28 条,按归位表)**

```bash
mv docs/language-syntax.md docs/language/syntax.md
# ...按表逐条...
mv docs/memory-model-capability-lattice.md docs/archive/memory-model-capability-lattice.md
```

每条执行前:`[ -e docs/<目标> ] && echo 目标已存在,中止`——目标存在则停下报告,不覆盖(铁律 #3)。

- [ ] **Step 4: 验证文件数守恒**

```bash
before=$(find docs -name '*.md' | wc -l)   # 移动前记下
find docs -name '*.md' | wc -l             # 应与 before 相等
ls docs/*.md                                # 只剩 README.md? + z-vision.md
```

- [ ] **Step 5: 不提交,继续 Task 2(批量移动 + 链接修复一次验收后一起提)**

---

### Task 2: 全仓 docs 引用路径修复 + CLAUDE.md 同步

**Files:**
- Modify: 所有引用旧路径的 md(引用源清单见下)
- Modify: `CLAUDE.md`(Key Conventions 段,见 Step 3)

**旧 → 新路径映射(引用方需全部替换):**
`docs/language-syntax.md→docs/language/syntax.md`、`docs/project-book.md→docs/design/project-book.md`、`docs/memory-model.md→docs/design/memory-model.md`、`docs/pointer-model.md→docs/design/pointer-model.md`、`docs/execution-model.md→docs/design/execution-model.md`、`docs/dataflow-design.md→docs/design/dataflow-design.md`、`docs/regalloc-cache-mapping.md→docs/design/regalloc-cache-mapping.md`、`docs/spec-design.md→docs/design/spec-design.md`、`docs/verifier-kernel.md→docs/design/verifier-kernel.md`、`docs/glossary.md→docs/design/glossary.md`、`docs/crasm.md→docs/design/crasm.md`、`docs/error-codes.md→docs/language/error-codes.md`、`docs/editor-setup.md→docs/language/editor-setup.md`、`docs/at-intrinsics.md→docs/design/at-intrinsics.md`、`docs/ir-op-semantics.md→docs/design/ir-op-semantics.md`、`docs/learning-path.md→docs/language/learning-path.md`、`docs/z-vision.md` 不变、`docs/compcert-reference.md→docs/archive/compcert-reference.md`、`docs/compcert-round4-findings.md→docs/archive/compcert-round4-findings.md`、`docs/numeric-migration-inventory.md→docs/archive/numeric-migration-inventory.md`、`docs/memory-model-capability-lattice.md→docs/archive/memory-model-capability-lattice.md`(另:generics/comptime/ffi/concurrency/dynamic-typing/lazy/distributed/probabilistic → docs/proposals/ 同名)

- [ ] **Step 1: 找出全部引用方,逐个 sed 替换**

引用方(2026-09-06 扫描):CLAUDE.md、README.md、TODO.md、CHANGELOG.md 及 docs/ 内各文件(含 language/design/proposals/archive 下移动后的、docs/ir-schema/ 两份、docs/learning-path.md 等)。逐文件按映射做精确替换,例如:

```bash
cd /home/DslsDZC/core
sed -i 's|docs/language-syntax\.md|docs/language/syntax.md|g' CLAUDE.md README.md TODO.md CHANGELOG.md
# 其余映射同理;对 docs/ 树用:
grep -rl 'docs/\(language-syntax\|project-book\|memory-model\|pointer-model\|execution-model\|dataflow-design\|regalloc-cache-mapping\|spec-design\|verifier-kernel\|glossary\|crasm\|error-codes\|editor-setup\|at-intrinsics\|ir-op-semantics\|learning-path\|compcert-reference\|compcert-round4-findings\|numeric-migration-inventory\|memory-model-capability-lattice\|generics\|comptime\|ffi\|concurrency\|dynamic-typing\|lazy\|distributed\|probabilistic\)\.md' --include='*.md' . 2>/dev/null | grep -v build/ | grep -v docs/superpowers/
# 逐文件替换对应映射(可用 sed -i 循环;注意 .corespec 后缀文件不在本次范围)
```

注意:执行顺序必须先于 Task 1 之外的所有读者可见产出;Task 1 的移动与此步必须同一次验收。

- [ ] **Step 2: 验证零残留旧路径**

```bash
grep -rn 'docs/\(language-syntax\|project-book\|memory-model\|pointer-model\|execution-model\|dataflow-design\|regalloc-cache-mapping\|spec-design\|verifier-kernel\|glossary\|crasm\|error-codes\|editor-setup\|at-intrinsics\|ir-op-semantics\|learning-path\|compcert-reference\|compcert-round4-findings\|numeric-migration-inventory\|memory-model-capability-lattice\)\.md' --include='*.md' --include='CLAUDE.md' --include='README.md' --include='TODO.md' --include='CHANGELOG.md' . 2>/dev/null | grep -v build/
```

预期:零输出。允许残留:`.corespec` 引用(另案)、`docs/superpowers/` 内历史计划对旧路径的引用(历史档案不改)。

- [ ] **Step 3: CLAUDE.md Key Conventions 与 Known Issues 段同步**

CLAUDE.md 中若出现已移动路径(如 "Spec files in `spec/`" 段、Architecture 段内 `docs/superpowers/specs/...` 引例),逐处按新路径更新;并把 docs/ 分类树一句话加入 CLAUDE.md(docs 区定位:language/ 用户向、design/ 定稿、proposals/ 讨论、archive/ 任务产物、maintainer/ 手册、adr/ 决策记录、pseudocode/superpowers 工具链目录)。

- [ ] **Step 4: 断链复查**

```bash
# 对每个新目标路径抽查引用存在性(新路径在引用方出现、文件确实在新位置)
for f in docs/language/syntax.md docs/design/project-book.md docs/archive/compcert-reference.md; do
  [ -f "$f" ] && echo "OK $f" || echo "MISSING $f"
done
```

- [ ] **Step 5: 提交(先向用户确认 src 改动归属与许可)**

```bash
jj commit -m "docs: 分类树落地——docs/ 按主题×读者重组(29 份顶层文档归位 + 全仓引用路径修复 + CLAUDE.md 同步)"
```

---

### Task 3: docs/README.md 导航索引(新建)

**Files:**
- Create: `docs/README.md`

- [ ] **Step 1: 起草 README.md**

内容结构(与分类树一致,引用真实新路径):

```markdown
# Core 文档中心

> 分类规则:按「主题 × 读者 × 状态」组织;每份文档头部有定位声明(受众/状态/真源)。
> 一份文档一个职责;实现与文档冲突时以源码为准(既有惯例)。

## 用户向(language/)
- [语言语法](language/syntax.md)— 词法/类型/声明/表达式/规约,真源 = grammar/core.ebnf + src/compiler/
- [学习路径](language/learning-path.md)
- [错误码参考](language/error-codes.md)
- [编辑器与 LSP 配置](language/editor-setup.md)

## 定稿参考(design/)— 维护者向
- [项目书](design/project-book.md)— 项目定位
- [执行模型](design/execution-model.md)(dataflow-design.md 已被其取代,留档)
- [内存模型](design/memory-model.md)、[指针模型](design/pointer-model.md)、[寄存器分配缓存映射](design/regalloc-cache-mapping.md)
- [IR 操作语义](design/ir-op-semantics.md)、[术语表](design/glossary.md)
- [规约系统设计](design/spec-design.md)、[验证内核](design/verifier-kernel.md)、[@ 内建原语](design/at-intrinsics.md)
- corelsp 设计(editor-setup 拆分后,见 design/corelsp.md)

## 特性提案(proposals/)
generics / comptime / ffi / concurrency / dynamic-typing / lazy / distributed / probabilistic(状态见各文件头注)

## 任务产物归档(archive/)
compcert 对照审查四轮材料与修复记录、数值类型迁移盘点、内存模型能力格讨论备忘

## 维护者手册(maintainer/)
- onboarding.md — 新维护者入门
- testing.md — 测试/验证操作手册

## 决策记录(adr/)
ADR-0001 起,见 [adr/](adr/)

## 工具链目录(不动)
pseudocode/(TDD 交付物)、superpowers/(specs + plans)、coq/、ir-schema/、verifier/
```

- [ ] **Step 2: 按 Task 4-8 实际产出校正条目(Task 4-8 完成后回填缺失链接;新文档完成后把对应行补真)。** 本步只保证:README 提到的每个路径在 Task 1-2 完成后真实存在。

- [ ] **Step 3: 提交(连同 Task 1-2 一次提交,或本步独立小提交,依用户许可)**

```bash
jj commit -m "docs: docs/README.md 导航索引(分类规则 + 目录树)"   # 或并入 Task 2 提交
```

---

### Task 4: 新建 maintainer/onboarding.md(新维护者入门手册)

**Files:**
- Create: `docs/maintainer/onboarding.md`

素材:CLAUDE.md(铁律/分支模型/构建命令/架构树)、TODO.md、docs/design/ 各文件头注、README.md(仓库结构)。

- [ ] **Step 1: 起草内容(章节固定,每节 3-10 行,链接真实路径)**

1. 定位声明块:受众 maintainers;状态 active;真源 = 源码 + CLAUDE.md
2. 仓库地图:`src/compiler/*.cr` 各模块一句话职责(ast/lexer/parser/checker/ir_gen/dataflow/ccr_io/opt/pass/diag/module/project/interp/dump/dyn_arr/globals/entry/main/corearch/_import);`src/arch/linux/ld/`(elf/instr/sizes/resolve/ld);`src/stdlib/`、`src/runtime/`(rt.s/rt.cr);`bootstrap/corec/` 定位;tests 三套;grammar/;docs/ 分类树(链接 README.md)
3. 构建管线:三条命令(build_selfhost_native.py → build/corec+corearch;./build/corec build FILE.cr;./build/corearch FILE.ccr)+ 三级自举 Stage0/1/2 含义
4. 分支模型与 jj 速查:feature → develop → main;`jj bookmark create feature/x`、`jj git push -b feature/x`、`jj git fetch && jj bookmark move develop -r develop@origin`;SSH 自动签名说明
5. 已知雷区:corec2 tokenizer 死循环(9 个全局变量未注册,详见 TODO.md);pass_cse/O1 稳定性;core_pattern/trap 测试禁 core dump(近期修复)
6. 贡献清单:读 README → 挑 TODO → feature 分支 → 开发+测试 → PR → develop(检查列表)

- [ ] **Step 2: 验证:全部互链路径真实存在**

```bash
grep -oE '\]\([^)]+\)' docs/maintainer/onboarding.md   # 逐条 [ -f ] 检查
```

- [ ] **Step 3: 提交**

```bash
jj commit -m "docs: maintainer/onboarding.md——新维护者入门(仓库地图/构建/分支/jj 速查/雷区)"
```

---

### Task 5: 新建 maintainer/testing.md + 拆分 editor-setup

**Files:**
- Create: `docs/maintainer/testing.md`
- Create: `docs/language/editor-setup.md`(纯用户配置,截自原 editor-setup.md §1-§7 配置部分)
- Create: `docs/design/corelsp.md`(corelsp 架构/维护向部分:构建服务器、LSP 协议细节)
- Delete: 原 editor-setup.md(已随 Task 1 移到 docs/language/,本任务原地改写为纯用户版,并把架构内容抽到 design/corelsp.md)

- [ ] **Step 1: 读原 editor-setup.md,按 §划分两类内容;rewrite docs/language/editor-setup.md 为用户配置版(Neovim/VS Code/Zed 接入步骤 + 触发表),新建 docs/design/corelsp.md 收架构向内容(构建服务器/诊断通道/LSP 细节),两文件头部互链**

- [ ] **Step 2: 起草 testing.md**(章节固定)

1. 定位声明:受众 maintainers;状态 active;真源 = 源码
2. 测试三套定位:tests/bootstrap(test_pipeline/test_borrow/test_generics,Python 驱动内联源码)、tests/selfhost(test_compile/test_impl/test_borrow,自举管线)、tests/suite(.cr 集成走 ./build/corec)
3. 跑法命令清单(逐条真实命令,自 CLAUDE.md Build & Test)
4. 回归流程:自举三阶段 + 字节一致验证(corec→corec2→corec3,corearch 逐字节一致);CPU 限制:`cpulimit -l 10`/`nice -n 19`(铁律 #6)
5. 改测试指引:加用例 = 内联 Core 源码字符串 + 断言;borrow 测试按 7 规则分类
6. 失败定位常见路径:tokenizer 死循环(检查 g_pos 递增)、O1 崩溃(pass_cse)、ELF 字节不一致(先查 instr 编码)

- [ ] **Step 3: 验证**

```bash
[ -f docs/language/editor-setup.md ] && [ -f docs/design/corelsp.md ] && [ -f docs/maintainer/testing.md ]
grep -rn 'docs/editor-setup\.md' --include='*.md' . | grep -v build/ | grep -v superpowers   # 应全部指向 docs/language/editor-setup.md 或 docs/design/corelsp.md
```

- [ ] **Step 4: 提交**

```bash
jj commit -m "docs: maintainer/testing.md 测试手册 + editor-setup 拆分(用户配置/design 两部分)"
```

---

### Task 6: ADR 目录 + 首批 4 份决策记录

**Files:**
- Create: `docs/adr/README.md`(ADR 模板 + 编号规则:0001 起,accepted/superseded/date/决策者/背景/决策/后果/关联)
- Create: `docs/adr/adr-0001-corespec-crasm-retired.md`
- Create: `docs/adr/adr-0002-ccr-v6-segment-table.md`
- Create: `docs/adr/adr-0003-selfhost-elf-direct-emit.md`
- Create: `docs/adr/adr-0004-corec-corearch-split.md`

- [ ] **Step 1: 挖 git 历史取决策素材**

```bash
jj log --limit 40    # 近 40 提交扫决策类提交(corespec 退役 2026-09-06 / crasm 退役 2026-09-05 / v6 段表 2026-09-05 / corec-corearch 拆分 / ELF 直出)
jj show <rev> --stat # 需要细节时展开具体提交
```

- [ ] **Step 2: 逐份起草,每份格式**(20-60 行):

```markdown
# ADR-000N: 标题

- 日期:YYYY-MM-DD
- 状态:accepted(或 superseded by ADR-000M)
- 决策者:DslsDZC(或 + 第二维护者)

## 背景
(问题/上下文,2-5 句,链接 design/ 相关文档)

## 决策
(选择与理由,含被否选项一句)

## 后果
- 正面:
- 负面:
(各 1-3 条)

## 关联
- 相关 ADR:ADR-000X
- 文档:docs/design/...
```

四份草案要点:
- **ADR-0001**:.corespec/.crasm 独立格式退役(2026-09-05/06);规约并入 .cr 语法、crasm 能力由硬件接口表(HIT)吸收;理由:独立规约格式同构于 crasm,语法唯一表达;后果:grammar/core.ebnf 并入、spec/ 目录 .corespec 残留待清、CLAUDE.md 已同步
- **ADR-0002**:.ccr v6 段表架构(2026-09-05);ENT 存在结构段;REG 坐标化(SYM 归并/REG kind/parent/enter/exit/first/last/root_region span);后果:v5 前 .ccr 不兼容、ccr_io.cr 读写双端、spec/2026-09-05-lattice-ir-v6-format.md 为格式权威
- **ADR-0003**:自举后端 x86-64 ELF 直出(2026-08,三阶段字节一致贯通);放弃 .s 汇编中介;理由:跳过 as/ld 依赖、字节级可复现;后果:rt.s 手工汇编保留、legacy_asm_backend/ 移出
- **ADR-0004**:corec/corearch 前端后端二进制拆分(2026-08);.ccr 为接口契约;理由:自举需要后端独立驱动;后果:CLI 分工(main.cr/corearch.cr)、.ccr 为格式边界

- [ ] **Step 3: 验证:格式一致 + README 索引链接**

```bash
for f in docs/adr/adr-*.md; do head -1 "$f" | grep -q '^# ADR-000' || echo "BAD HEADER $f"; done
```

- [ ] **Step 4: 提交**

```bash
jj commit -m "docs: adr/ 目录 + ADR-0001~0004(corespec/crasm 退役·ccr v6 段表·ELF 直出·corec 拆分)"
```

---

### Task 7: 重写范本 A——project-book.md 拆职责

**Files:**
- Rewrite: `docs/design/project-book.md`(已随 Task 1 到位)
- Modify: `docs/z-vision.md`(愿景承接段,若 project-book 原含愿景/哲学)

- [ ] **Step 1: 读现 project-book.md 全篇,按职责切分:**

- 愿景/哲学段 → 若与 z-vision.md 重复则删,不重复的并入 z-vision.md
- IR 系统/执行模型/验证架构细述 → 不复制,链接 design/ 对应文件(execution-model.md、spec-design.md、verifier-kernel.md、memory-model.md、pointer-model.md、ir-op-semantics.md)
- 项目定位保留重写:目标 ≤150 行,结构 = 定位声明块 + 一、项目概述(是什么/不是承诺一句) + 二、核心思想三句话(语义保鲜/单一事实源/单执行模型,各链设计文档) + 三、系统骨架图(文本图:前端→IR→后端→验证,标注对应 .cr 模块与 design/ 文档) + 四、状态速览(自举阶段 + 链 TODO.md + README.md 状态表)

- [ ] **Step 2: 写新 project-book.md(≤150 行,无免责段堆叠),改 z-vision.md 关联段**

- [ ] **Step 3: 验证**

```bash
wc -l docs/design/project-book.md        # ≤150
grep -n 'docs/design/\|docs/language/' docs/design/project-book.md   # 链接全部指向新路径
```

- [ ] **Step 4: 提交**

```bash
jj commit -m "docs: project-book.md 重写——定位导航化(≤150 行,愿景归 z-vision,细节链 design/)"
```

---

### Task 8: 重写范本 B——glossary.md 校准 + 范本 C——crasm.md 废弃收尾

**Files:**
- Rewrite: `docs/design/glossary.md`(17 节 → 校准)
- Rewrite: `docs/design/crasm.md`(205 行 → ≤40 行废弃说明)

- [ ] **Step 1: 校准 glossary.md**

读全篇,逐节核对:术语定义与 design/ 定稿文档(execution-model/memory-model/pointer-model/spec-design)表述一致;关键字类术语与 `src/compiler/lexer.cr` 核对(唯一真源惯例);失效条目删或标注 archive;演进记录节(十七)压缩为一行指向 ADR 与 git 历史。目标体积:较现 241 行只减不增,头部加定位声明(受众 maintainers;状态 active;真源 = design/ 各文档 + src/compiler/lexer.cr)。

- [ ] **Step 2: 压缩 crasm.md → 废弃收尾版**

结构(≤40 行):定位声明块(状态 deprecated,2026-09-05,原因一句)+ 是什么(一段)+ 为什么废弃(绑定经典硬件过深;被硬件接口表 HIT 吸收,链接 docs/superpowers/specs/2026-09-05-hardware-interface-table.md)+ 去向(规则并入 .cr 语法 + unsafe;另见 ADR-0001)+ 历史正文指针(原全文已删,需要细节看 jj 历史)。原 205 行设计细节删除。

- [ ] **Step 3: 验证**

```bash
wc -l docs/design/crasm.md            # ≤40
head -5 docs/design/crasm.md          # 含 deprecated 定位声明
grep -rn 'crasm' CLAUDE.md README.md docs/README.md | head   # 上层引用一致性
```

- [ ] **Step 4: 提交**

```bash
jj commit -m "docs: 重写范本 B/C——glossary 校准(源对照)+ crasm 废弃收尾(ADR-0001 衔接)"
```

---

### Task 9: 总验收 + README 回填

**Files:**
- Modify: `docs/README.md`(Task 4-8 产出的新条目回填)

- [ ] **Step 1: 回填 README.md**(onboarding/testing/corelsp/ADR 目录项,设计分节里已列)

- [ ] **Step 2: 总验收命令**

```bash
cd /home/DslsDZC/core
# 1) 旧路径零残留(排除 build/、docs/superpowers/ 历史)
grep -rn 'docs/\(language-syntax\|project-book\|memory-model\|pointer-model\|execution-model\|dataflow-design\|regalloc-cache-mapping\|spec-design\|verifier-kernel\|glossary\|crasm\|error-codes\|editor-setup\|at-intrinsics\|ir-op-semantics\|learning-path\|compcert-reference\|compcert-round4-findings\|numeric-migration-inventory\|memory-model-capability-lattice\)\.md' --include='*.md' --include='CLAUDE.md' . 2>/dev/null | grep -v build/ | grep -v superpowers || echo PASS
# 2) 新路径文件数守恒(移动前后一致)
# 3) 新增文档齐备
for f in docs/README.md docs/maintainer/onboarding.md docs/maintainer/testing.md docs/design/corelsp.md docs/adr/adr-0001-corespec-crasm-retired.md docs/adr/adr-0002-ccr-v6-segment-table.md docs/adr/adr-0003-selfhost-elf-direct-emit.md docs/adr/adr-0004-corec-corearch-split.md; do [ -f "$f" ] && echo "OK $f" || echo "MISSING $f"; done
# 4) 定位声明抽查:每个移动文件头部有受众/状态/真源
for f in docs/language/*.md docs/design/*.md docs/proposals/*.md docs/archive/*.md; do grep -q '受众' "$f" || echo "NO-DECL $f"; done
# 5) crasm ≤40 行、project-book ≤150 行
wc -l docs/design/crasm.md docs/design/project-book.md
```

- [ ] **Step 3: 编译相关改动零牵连验证**

```bash
jj st          # 除 docs/ 变更与用户 src 三件套外无意外文件
jj diff --stat | tail -5
```

- [ ] **Step 4: 提交 README 回填(如与 Task 3 未合并)**

```bash
jj commit -m "docs: README 索引回填(Task 4-8 产物)+ 总验收通过"
```

---

### Task 10: 收尾——提交策略与用户确认

- [ ] **Step 1: 汇总提交清单给用户,列出每提交改动的文件数与 docs/ 范围**

- [ ] **Step 2: 向用户确认:工作副本中 src/compiler 三件套(ccr_io.cr/opt.cr/regalloc-consistency.cr)改动归属(用户自留/另行提交),以及 docs 各提交是否推送 develop**

- [ ] **Step 3: 待用户许可后执行最终 jj 操作(如用户要求 push feature 分支:jj git push -b feature/docs-reorg)**
