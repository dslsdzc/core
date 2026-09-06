# ADR-0001: .corespec/.crasm 独立格式退役——规约并入 .cr 语法

- 日期:2026-09-05/06
- 状态:accepted
- 决策者:DslsDZC
- 关联提交:`582a1e1`(refactor: .corespec 退役);crasm 废弃标注(2026-09-05)

## 背景

仓库一度存在两套独立格式:`.corespec`(规约/契约文件)与 `.crasm`(统一汇编抽象层)。二者
同构于同一思路——为特定职责发明独立文件格式与语法。代价:格式越多,真源越散(lexer/parser/
ebnf/后端各要维护一套),且独立格式绑定经典硬件过深(寄存器/寻址/ISA 助记符/私有平台映射表)。

## 决策

- **.corespec 退役**(2026-09-06,提交 582a1e1):独立规约格式取消——规约 = .cr 语法唯一表达
- **.crasm 废弃**(2026-09-05):独立汇编格式取消,能力由硬件接口表(HIT)吸收——跨平台 = HIT
  事件 + 投影表;MMIO/特权/中断 = `.cr` unsafe + HIT extern 接口事件
- 语法责任并入 `grammar/core.ebnf`;`.corespec` 文件标注退役,CLAUDE.md 同步

## 后果

- 正面:真源收敛——语言语法只有一个表达(.cr);维护面缩小(无私有格式链)
- 负面:core.ebnf 与 CLAUDE.md 需挂账清理残余 .corespec 引用;spec/ 目录残留 7 行占位文件待清;
  既有 .corespec 资产(regalloc-consistency 已迁 .cr 注释契约)需按新形态改写

## 关联

- 文档:docs/design/crasm.md(废弃收尾);grammar/core.ebnf
- 后续:spec/ 目录 .corespec 占位清理(挂账)
