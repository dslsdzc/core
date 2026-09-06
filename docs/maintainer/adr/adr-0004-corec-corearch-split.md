# ADR-0004: corec/corearch 前后端二进制拆分(.ccr 为接口契约)

- 日期:2026-05-28(拆分,随 .core → .cr 更名);2026-08(自举贯通后职责定格,corearch 独立发射)
- 状态:accepted
- 决策者:DslsDZC
- 关联提交:main.cr/corearch.cr 拆分批(CLAUDE.md 已记录)

## 背景

2026-05-28 将单编译器拆为前后端(.core → .cr 更名同期);自举管线进一步要求"前端编译 .cr → 中间产物 → 后端发射 ELF"两步可独立驱动:corec2 自我编译
时,前端需反复调用后端;若前后端同体,则无法单独验证后端对同一 .ccr 的发射一致性,
也无法分离调试(前端死循环与后端 SIGFPE 会互相掩盖)。

## 决策

- 拆为两个二进制:**corec**(前端:lex→parse→check→ir→ccr 写出)与 **corearch**(后端:
  .ccr 读入 → ELF 发射),corearch 亦可单独跑 `--elf --static`
- **.ccr 文件 = 前后端接口契约**:v5 线性指令/变量段(后演进为 v6 段表,见 ADR-0002)
- corec `build` 子命令内部自动调用 corearch;用户也可手工分步(如逐字节对比发射)

## 后果

- 正面:三阶段自举可逐字节验证(corec→corec2→corec3 发射一致);后端可独立回归
  (O0/O1/O2 CCR 与原生 ELF 运行验证);.ccr 成为稳定的格式边界与 dump 载体
- 负面:两二进制分发的复杂度(CLI 入口两份);.ccr 格式稳定性成为硬约束——
  格式一变,前后端必须同步(版本耦合)

## 关联

- 文档:docs/design/project-book.md(系统骨架);CLAUDE.md(Build & Test 命令)
- 相关 ADR:ADR-0002(.ccr v6 段表)、ADR-0003(ELF 直出)
