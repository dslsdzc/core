# LSP 生产化设计（corelsp 到生产可用，以及语义可视化差异化）

日期：2026-08-28
状态：设计已批准（brainstorming 会话，五节决策确认）
关联：`docs/superpowers/specs/2026-08-08-lsp-design.md`（原设计）、`src/lsp/`（实现）、`docs/editor-setup.md`（接入文档）

## 一、背景与动机

`corelsp` 已端到端跑通（Zed 扩展 `wasm` 机制，诊断/补全/悬停/跳转/符号/语义令牌，2026-08-28 验证）。现状存在生产级缺口：单文件检查（跨文件符号未解析，产生假错误）、无增量、无错误恢复边界。Core 还拥有其他语言 LSP 不具备的语义数据（`HDFG` 图、指针三 `pass`、缓存语义、范式标注、验证内核）。生产化的目标不只是补缺口，还包括把语义信息带进 IDE 的差异化实现。

## 二、决策链（2026-08-28 brainstorming 五问定案）

1. 编辑器覆盖面：Zed 优先，VS Code 后置。`LSP` 协议层保持编辑器无关，客户端（渲染）先在 Zed 写一套。
2. 数据通道：混合方案。标准 LSP 包含一切可渲染的内容（`hover` 富内容 / `inlay hints` / 诊断增强 / 语义令牌）；重 UI（图视图、管线探索器）为独立查看器（`coreview`，读取 `.cir`/`.ccr` dump）。Zed 扩展 API 没有面板和 WebView，无法表示全屏 UI。
3. 检查架构：分阶段。P0 为 `import` 闭包级，P1 为项目级分析服务（`rust-analyzer` 式），架构预留策略接口。
4. 查看器形态：Web 应用（`coreview`：静态应用加图渲染库；VS Code 后置时可作 Webview 嵌入）。
5. 代码库演进：`corelsp` 增量演进（方案 A），检查会话抽象为策略，不重写。

## 三、架构总览

```
src/lsp/（corelsp 增量）
├── rpc.cr 协议层（标准 LSP + 富内容格式），不变
├── session.cr 新增：检查会话策略接口（文件级到闭包级到项目级 = 同一接口三实现）
├── analysis.cr 扩展：hover 富内容生成（指针/配方/范式/证明占位）
├── lsp.cr 扩展：inlay hints、诊断增强
coreview/ 新增：Web 查看器（解析 .cir/.ccr dump，图渲染 + 管线分屏）
```

原则：数据源全部来自编译器既有产物（三 `pass` / 图 / dump / 验证内核），LSP 只做接入和呈现，不重复实现分析。

## 四、能力矩阵与分期

| 期 | 能力 | 依赖 | 验收 |
|---|---|---|---|
| P0（现在） | import 闭包检查（复用 `res_imports`）、错误恢复、hover v1（指针 points-to 闭包近似 / 方法 = 产生节点 / 范式标注）、inlay v1（赋值版本链）、诊断增强（unsafe/例外入口区域） | 无（三 pass + 图数据现成） | Zed 日常写 Core 无假错误，指针 hover 可用 |
| P1（格形态 v6 后） | 项目级会话（全项目编译 + 三 pass + 图构建 + 缓存失效）、增量 sync=2、hover v2（证明状态 / 精确 pts）、rename / code actions / workspace symbol / references、coreview v1（图视图 + 管线探索器） | 格形态稳定 | 项目级精度，完整 IDE 体验 |
| P2（随主线） | 惰性显示（inlay）、寄存器/驱逐显示、spec-aware（规约/反例落源码）、coreview 联动（代码与图双向）、VS Code 客户端 | 惰性分析 / 分配器 / 验证管线 | 差异化全部实现 |

## 五、会话策略接口（架构核心）

```core
// session.cr：检查会话策略，包含 open/change/check/diags/query
// 文件级（现状）、闭包级（P0：打开文件 + import 闭包）、项目级（P1：全项目 + 缓存失效）
// 三实现共用同一接口；rpc/lsp 层只面对接口，不感知粒度
```

- P0 实现 `ClosureSession`：复用 `module.cr` 的 `res_imports` 解析闭包，闭包一起过 `checker`；`pts` 等按闭包近似（`interprocedural` 精度 P1 解决）
- P1 实现 `ProjectSession`：全项目编译一次进内存，变更时重编译受影响文件（增量/缓存/失效传播）

## 六、富内容格式（全部标准 LSP，零协议扩展）

- `hover`：结构化 `markdown`（代码块和表格），包含指针 `points-to` 集合、方法、范式标注、证明状态（P1+）
- `inlay hints`：版本链（x₀ 到 x₁ 到 x₂）、惰性标注（P2）、寄存器映射（P2）
- 诊断：`code` 分类（`CORE-E001` 等），`unsafe`/例外入口区域标记
- 语义令牌：现有（keyword/type/function/variable/…）

## 七、coreview（独立查看器）

- 形态：静态 Web 应用（`HTML` + `JS` + `cytoscape.js`），无后端依赖
- 数据源：`corec cir` / `corec ccr` dump（现有命令输出）
- 功能 v1：`HDFG` 图视图（`DFNode`/`DFEdge` + `region` 嵌套 + `state edges`）、管线探索器（源码、`AST`、`HDFG`、格形态 IR、汇编分屏）
- 联动（P1+）：与 LSP 双向高亮（代码与图），使用文件轮询或小服务

## 八、测试与验收

- LSP 协议测试扩展：富内容/`inlay`/诊断 `code` 的协议用例（现有 `test_lsp.py` 体系）
- `coreview`：dump 文件快照测试（图结构断言）
- 验收线：P0 = Zed 日常写 Core 无假错误，指针 `hover` 可用；P1 = 项目级精度，完整 IDE 体验；P2 = 差异化全部实现

## 九、依赖与风险

| 依赖 | 影响 | 处理 |
|---|---|---|
| 格形态 v6 | P1 前不碰 IR 形态（闭包级只用现有 .cir/.ccr） | P0 独立可做 |
| 验证管线（翻译桥/CIC，0 实现） | spec-aware LSP 依赖 | P2，随主线 |
| 惰性分析（lazy.md 判定表，未实施） | 惰性显示依赖 | P2，随主线 |
| 寄存器分配（设计定稿，实现待完成） | 寄存器/驱逐显示依赖 | P2，随主线 |
| 闭包级 pts 精度 | interprocedural 近似 | P1 项目级解决 |

风险：Zed 扩展 API 无面板/WebView（已通过混合方案规避）；闭包级假错误仍有残余（在验收线内控制）。

## 十、实施顺序

1. P0：`session.cr` 策略接口和 `ClosureSession`（`import` 闭包），然后错误恢复、`hover` 富内容 v1、`inlay` v1、诊断增强、协议测试、Zed 验证（验收线）
2. P1：`coreview` v1，项目级会话，增量 `sync=2`，`rename`/`references`，完整 IDE 体验
3. P2：随主线进行（惰性、寄存器、验证管线就位后接入），加 `coreview` 联动和 VS Code 客户端

## 十一、关联

- `docs/superpowers/specs/2026-08-08-lsp-design.md`（原设计，含协议层和方法集）
- `docs/editor-setup.md`（Zed/VS Code 接入）
- `docs/lazy.md`（惰性判定表，P2 显示的数据源）
- `docs/regalloc-cache-mapping.md`（寄存器映射，P2 显示的数据源）
- `docs/verifier/kernel-spec.md` + `src/kernel/`（验证内核，spec-aware 的基础）
- `src/lsp/`、`src/compiler/ptr_analysis.cr`、`src/compiler/dataflow.cr`（实现）
