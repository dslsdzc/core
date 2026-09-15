# 核心维护文档重组与首批重写设计(2026-09-06)

状态:已获用户逐节批准(2026-09-06)。本文档为设计定稿,执行按 writing-plans 拆分。

## 一、背景与问题

`docs/` 当前是平铺的单目录,156 份 md ≈ 5.6 万行,包含至少 6 种不同性质的内容:

1. 用户向文档(语法、学习路径、错误码、编辑器配置)
2. 定稿的架构参考(执行模型、内存模型、指针模型、术语表)
3. 未定稿/已实现的特性设计稿(泛型、FFI、并发、惰性求值、概率编程…)
4. 任务产物(CompCert 对照审查、数值类型迁移盘点)
5. 伪代码 TDD 交付物(73 份 ≈ 3.3 万行,自成一体)
6. 工具链约定目录(superpowers/plans、specs)

同一目录混放多种性质文档 → 无导航、状态不明(active/superseded/deprecated 靠各文件自行散落标注)、新维护者无从下手。

## 二、目标形态:分类树

按「主题 × 读者 × 状态」三维分类。目录树:

```
docs/
├── README.md                 【新建】导航索引 + 分类规则说明(每文档唯一职责)
├── language/                 【用户向】不依赖编译器知识
│   ├── syntax.md             ← language-syntax.md
│   ├── learning-path.md      ← learning-path.md
│   ├── error-codes.md        ← error-codes.md
│   └── editor-setup.md       ← editor-setup.md(用户配置部分)
├── design/                   【维护者向·定稿参考】
│   ├── project-book.md       ← project-book.md(重写拆职责,见 §六)
│   ├── execution-model.md    ← execution-model.md
│   ├── dataflow-design.md    ← dataflow-design.md(头注 superseded by execution-model)
│   ├── memory-model.md       ← memory-model.md
│   ├── pointer-model.md      ← pointer-model.md
│   ├── regalloc-cache-mapping.md / ir-op-semantics.md / glossary.md(校准,见 §六)
│   ├── spec-design.md / verifier-kernel.md / at-intrinsics.md
│   ├── corelsp.md           ← editor-setup.md 拆分出的 corelsp 架构/维护部分
│   └── crasm.md             ← crasm.md(废弃收尾,见 §六)
├── proposals/                【讨论中】特性设计
│   ├── generics.md / comptime.md / ffi.md / concurrency.md
│   └── dynamic-typing.md / lazy.md / distributed.md / probabilistic.md
│       (已实现的特性标 active 并指向 design/ 或源码;未实现的保持 proposal)
├── archive/                  【任务产物】
│   ├── compcert-reference.md / compcert-round4-findings.md
│   └── numeric-migration-inventory.md
├── maintainer/               【新建】维护者操作手册
│   ├── onboarding.md         【新建】仓库结构导览 + 构建管线 + 分支模型操作
│   └── testing.md            【新建】测试/验证操作手册
├── adr/                      【新建】决策记录(编号 0001 起)
├── z-vision.md               保留顶层(愿景入口,README.md 链接之)
├── pseudocode/  superpowers/ 不动
└── coq/ ir-schema/ verifier/ 原样,头部定位声明对齐
```

**规则(每份文档强制):**

1. 头部加定位声明块:受众(users/maintainers/contributors)+ 状态(active/superseded/deprecated/archive/proposal)+ 真源声明(源码/grammar/本文件)
2. 一份文档一个职责;状态与内容冲突时更新文档,不添加免责段
3. 分类树 + 定位声明双轨,README.md 为唯一导航索引

## 三、归档处置

- memory-model-capability-lattice.md → archive/(v1-v4 讨论备忘,内容演进并入 memory-model.md)
- crasm.md → 压缩为一页说明 + ADR 链接(见 §六)
- compcert-reference.md / compcert-round4-findings.md / numeric-migration-inventory.md → archive/
- 伪代码/任务产物不做内容清理,只移动与标注

## 四、新增文档:maintainer/onboarding.md

面向新维护者(含第二维护者分工),内容:

1. 仓库结构导览(src/compiler 模块地图、src/arch、src/stdlib、src/runtime)
2. 构建管线:三级自举(Stage 0/1/2)怎么跑、产物是什么
3. 分支模型:feature → develop → main,jj 命令速查(create/move/push)
4. 已知阻塞项与雷区(corec2 tokenizer 全局变量问题等,同步自 TODO.md)
5. 贡献清单检查列表

## 五、新增文档:maintainer/testing.md

1. 三套测试的定位与跑法(tests/bootstrap、tests/selfhost、tests/suite)
2. 每套测试怎么改/怎么加用例(内联 Core 源码字符串约定)
3. 回归验证流程(自举三阶段 + 字节一致性验证)
4. 常见失败模式与定位手段

## 六、存量重写范本(首批三份,覆盖三种典型工作流)

### 6.1 project-book.md — 拆分示范

拆成职责单一的多份:

- 愿景/哲学部分 → 已在 z-vision.md 的归 z-vision.md 管,重复段删(project-book 保留"项目定位"核心)
- IR 系统/验证架构细节 → 已有 spec-design.md、verifier-kernel.md、ir-op-semantics.md,交叉引用而非重复
- 重写后体积目标 < 150 行,成为导航性质文档

### 6.2 glossary.md — 校准示范

- 术语条目与源码逐一对照(lexer.cr 关键字唯一真源等既有惯例)
- 头注定位声明:受众 maintainers + 状态 active
- 失效条目删除或标 archive,不保留"冲突时以源码为准"的免责式堆叠

### 6.3 crasm.md — 废弃收尾示范

- 压缩成 ≤40 行:是什么、为什么废弃(2026-09-05)、替代方案
- 新 ADR 记录决策,正文链接 ADR

## 七、新增文档:ADR(首批 4 份起)

目录 `docs/adr/`,模板:

```markdown
# ADR-000N: 标题
日期/状态(accepted/superseded)/决策者
## 背景
## 决策
## 后果(正面/负面)
## 关联
```

首批选题(从近两月 git 历史决策):

1. ADR-0001: .corespec/.crasm 退役——规约并入 .cr 语法(2026-09-05/06)
2. ADR-0002: ELF 直出 vs .s 汇编产物(2026-08 自举贯通)
3. ADR-0003: .ccr v6 段表架构 + ENT 存在结构段(2026-09-05)
4. ADR-0004: 自举目标锁定 x86-64 ELF(或执行时按历史补选)

原则:先写最近且决策依据仍可追溯的;每个新决策落地时续号;ADR 不重复 design/ 细节,只记"为什么"。

## 八、执行顺序

1. **建目录骨架** + docs/README.md(索引先占位,逐步回填链接)
2. **存量归位迁移**(按 §二/三 清单移动文件,同步更新文件内互链路径)
3. **头部定位声明**逐份补齐(迁移时顺手做)
4. **重写范本三份**(§六),立项标、立规范
5. **maintainer/ 两份手册**新建(§四/五)
6. **ADR-0001~0004** 新建(§七)

## 九、验证方式

- `grep` 检查无残留失效链接(文档间互链路径更新完整)
- 仓库级 md 链接检查脚本(如有)或手工抽查
- README.md 索引与目录树一致
- 新维护者视角走查:onboarding 读完后能否独立跑通构建/测试

## 十、范围外(后续子项目)

- 开发者文档重写(面向外部,将来进文档网站)——另立项
- 文档网站基建(Astro Starlight 等)——另立项,内容成熟后再动
- docs/pseudocode 73 份内容审查——不在本次
