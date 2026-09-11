# ADR-0003: 自举后端 x86-64 ELF 直出(放弃 .s 汇编中介)

- 日期:2026-08(自举贯通 2026-07-27)
- 状态:accepted
- 决策者:DslsDZC

## 背景

自举需要编译器自身编译自身。若后端产出 `.s` 汇编再经外部 `as`/`ld` 汇编链接,则:
(1) 依赖外部工具链,自举链脆弱;(2) 汇编器行为差异导致构建不可复现;(3) 无法做
字节级一致性验证。早期 Python 后端(StackAsmGen/arm64_asm)走 .s 路线,自举阶段发现
需要 ELF 直出能力。

## 决策

- 后端直接发射 **x86-64 ELF 二进制**(`src/arch/linux/ld/`:elf.cr/instr.cr/sizes.cr/
  resolve.cr/ld.cr),跳过 `.s` 中介
- 动态链接能力保留(PLT/GOT、.so 加载,ld.cr),静态链接为默认路径
- corec/corearch 拆分(见 ADR-0004)后由 corearch 承担发射;rt.s 手工汇编保留为运行时种子
- legacy_asm_backend/ 移出主链,Python 后端仅用于 bootstrap 构建

## 后果

- 正面:三阶段自举(corec→corec2→corec3)可连续发射且**二进制逐字节一致**(2026-07-27 贯通);
  无外部 as/ld 依赖;O0/O2 寄存器分配元数据可序列化并由自举后端读取
- 负面:指令编码(REX/ModRM/SIB)全部自维护——每修一个编码 bug 都是全链回归;
  新平台支持成本高(需重写发射器,ARM64 仍走 .s)

## 关联

- 提交:2026-07-27 自举贯通批;后端修复批(SIGFPE/SIGSEGV 解除、64 位编码、CCR 有符号字段)
- 文档:docs/maintainer/design/execution-model.md(后端管线);docs/pseudocode/arch/linux/ld/(TDD 交付物)
- 相关 ADR:ADR-0004(corec/corearch 拆分)
