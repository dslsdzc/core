# 新维护者入门手册（onboarding）

> 定位：受众 = maintainers；状态 = active；真源 = 源码 + [CLAUDE.md](../../CLAUDE.md)（实现与文档冲突时以源码为准，既有惯例）。
> 文档导航见 [docs/README.md](../README.md)（分类规则：主题 × 读者 × 状态）。本文档聚焦仓库结构、构建、工作流与雷区。

## 一、仓库地图

**仓库协作约定**(人类维护者视角;CLAUDE.md 的"铁律"是面向 AI 助手的会话规则,不直接约束人——但下述约定人机一致):

- **版本控制只用 jj,不用 git 写操作**——仓库工具链统一(jj 分支模型见 §四)
- **不随意还原/回滚文件**——改坏了向前修,不回头抹历史(有争议先讨论)
- **修问题找 root cause**,不绕过、不掩盖、不加临时开关了事
- **长构建/测试注意机器负载**:无人值守或共享机器上建议 `cpulimit -l 10` / `nice -n 19`(减风扇噪音与卡顿;交互式短任务不必)

```
src/compiler/         → 自举编译器主体（corec 前端 + corearch 后端共用）
├── ast.cr            → AST 结点、IR opcode、类型常量（扁平 g_ast/g_ir_instrs，无指针树）
├── lexer.cr          → tokenizer（int 字符访问，热路径零字符串分配）
├── parser.cr         → 递归下降解析 → 扁平 AST
├── checker.cr        → 类型检查 + 借用检查 + 声明收集（两遍：先注册声明再查体）
├── ir_gen.cr         → AST → IR 指令生成
├── dataflow.cr       → HDFG 构建：DFNode/DFEdge（含 state edges）+ 嵌套 region（SG_IF/LOOP/FOR/FLOW/UNSAFE）
├── ccr_io.cr         → .ccr 二进制读写（v6 = 段表 + ENT 存在结构段）
├── opt.cr            → 优化 pass：CSE、寄存器分配、栈共享
├── pass.cr           → AST 级优化（常量折叠）
├── diag.cr           → 编译诊断
├── module.cr         → import 解析、文件 ID 管理
├── project.cr        → Core.toml 工程配置加载
├── interp.cr         → IR 解释器（`run` 命令）
├── dump.cr           → 调试 dump 工具
├── dyn_arr.cr        → 动态字节缓冲扩容 + 字符串驻留
├── globals.cr        → 全部全局变量声明
├── entry.cr          → 入口包装
├── main.cr           → corec CLI + 管线编排
├── corearch.cr       → corearch（后端二进制）入口
└── _import.cr        → 目录共享 import
注：自举推进期另有后增模块（monomorph/region_check/ptr_analysis/linker 等），未列于此表，职责以源码为准。

src/arch/linux/ld/    → x86-64 ELF 直出后端（corearch 用）
├── elf.cr            → ELF header/program header 生成、_start 发射
├── instr.cr          → 指令编码：REX/ModRM/SIB、全部 IR opcode 发射器
├── sizes.cr          → 指令字节数预估（sz_*，label 前向引用依赖）
├── resolve.cr        → label 解析 pass（res_labels）
└── ld.cr             → 动态链接（PLT/GOT、.so 加载）

src/stdlib/           → 标准库：cli/fmt/io/os/toml/panic/math/collections/_import + 后增
                        （arena/assert/dex/goroutine/chan/sched 等，见目录实况）
src/runtime/          → 运行时：rt.s（_start、bump allocator、__builtin_*）+ rt.cr（g_rt_argc/g_rt_argv_ptr）
bootstrap/corec/      → Python bootstrap：纯 Python 单遍管线（syntax/frontend/ir/backend/utils/verifier），
                        无外部依赖，只用于产出第一代原生编译器
tests/                → 三套：
  bootstrap/*.py      → bootstrap 管线测试（Python 驱动内联 Core 源码字符串）：
                        test_pipeline / test_borrow / test_generics 等
  selfhost/*.py       → 自举/后端/原生回归：test_compile / test_backend_bootstrap / test_borrow /
                        test_impl / test_pointer_safety 等
  suite/*.cr          → 集成用例源码，经 ./build/corec 运行
grammar/              → 语言语法 EBNF 唯一真源：core.ebnf（全语言）/ corespec.ebnf（规约）/ tokens.ebnf
docs/                 → 文档分类树（language 用户向 / design 定稿 / proposals 提案 / archive 归档 /
                        maintainer 手册 / adr 决策记录），导航索引 = [docs/README.md](../README.md)
```

## 二、构建管线

三条命令：

```bash
python3 build_selfhost_native.py       # Stage 0：Python bootstrap → build/corec + build/corearch
./build/corec build FILE.cr -o OUT --static   # 前端：.cr → .ccr（自动调后端出 ELF）；另有 check/run/cir/ccr 子命令
./build/corearch FILE.ccr --elf --static -o OUT  # 后端独立驱动：.ccr → ELF
```

三级自举（回归必验）：

- **Stage 0** — Python bootstrap 编译 `src/compiler/*.cr` → corec（第一代原生编译器）
- **Stage 1** — corec 编译 `src/compiler/*.cr` → corec2
- **Stage 2** — corec2 编译 `src/compiler/*.cr` → corec3；闭环判据 = corec2/corec3 输出逐字节一致（可加 O1，历史 O0/O1 均已贯通）

任何长时间构建/测试任务建议 `cpulimit -l 10` 或 `nice -n 19`(机器负载与噪音考虑;交互式短任务不必)。

## 三、分支模型与 jj 速查

模型：feature → develop → main。

- **main** = 正式版线：仅维护者 DslsDZC 可合入（ruleset：update 规则 + 无管理员绕过）
- **develop** = 集成分支：日常 PR 目标（ruleset：PR 通道 + 审批 + merge queue + CI 门槛）
- 日常开发 feature 分支 base = develop；PR 一律指向 develop

jj 速查（仓库 hook 机械拦截 git；提交经 SSH 自动签名，无需人工操作）：

```bash
jj bookmark create feature/xxx         # 每个改动独立分支
# ……开发提交……
jj git push -b feature/xxx             # 推送 GitHub
gh pr create --base develop --fill     # 不能指向 main
# → 审查（审批 + CI 绿）→ 手动 squash 合入 develop（merge queue 因免费计划降级，见 gitflow spec §3.3）
jj git fetch && jj bookmark move develop -r develop@origin   # 同步远端 develop
```

发布（develop → main，仅维护者）：`jj git push -b develop` → `gh pr create --base main --fill` → 合入后 `jj git fetch && jj bookmark move main -r main@origin`。

## 四、已知雷区

- **corec2 tokenizer 死循环**：约 9 个全局变量（`g_tok_cap`/`g_tokens`/`g_str_count`/`g_line`/`g_source_len` 等）未被 parser 注册到 `g_ir_globals` 时，赋值语句被静默丢弃 → tokenizer 卡死。曾以 tokenizer 参数化（PR #9）规避 `g_source` 依赖，残留项待根治。机理全文见 [CLAUDE.md Known Issues](../../CLAUDE.md)；遇 tokenizer 卡住先查 `g_pos`/`g_tok_cap` 是否递增。
- **O1 不稳定**：`--opt-level 1`（pass_cse 与 alloc_registers 元数据交互）在自举编译大函数时可能崩溃；遇崩降 O0 定位，详见 [CLAUDE.md Known Issues](../../CLAUDE.md)。
- **core dump 挂起（桌面环境）**：trap 类测试进程 SIGILL 后，内核写 core 经 systemd-coredump 管道唤醒服务，拥堵时进程挂起。2026-09-05 起 `src/ci/run.sh` 全局 `ulimit -c 0`、trap 测试内置 `RLIMIT_CORE=0`；根治方向 = 图推导边界判定 pass。详见 [TODO.md](../../TODO.md)。
- **测试总览与回归流程**：命令与跑法见 [CLAUDE.md Build & Test](../../CLAUDE.md)，历史修复记录在 [TODO.md](../../TODO.md)。

## 五、贡献清单（检查列表）

分工约定：第二维护者负责 TODO 横向扩展与 bug 修复；验证闭环主线归 DslsDZC。

- [ ] 读 [docs/README.md](../README.md) 定位文档；背景从 [design/project-book.md](../project-book.md)（项目定位）与 [design/execution-model.md](design/execution-model.md)（执行模型）入手
- [ ] 从 [TODO.md](../../TODO.md) 挑一个明确任务；不启动归属验证闭环主线的改动
- [ ] `jj bookmark create feature/xxx`（base = develop）；全程只用 jj
- [ ] 开发；改动只限目标文件；提交前 `jj st` 复查无意外文件
- [ ] 构建 + 测试:`python3 build_selfhost_native.py` 后跑相关套件(长任务建议 `cpulimit -l 10` / `nice -n 19`)
- [ ] 若动文档：头部定位声明、链接指向真实新路径、不复制职责重叠内容
- [ ] `jj git push -b feature/xxx` → `gh pr create --base develop --fill`
- [ ] 审查意见闭环（审批 + CI 绿）后手动 squash 合入 develop；不自行合入 main
