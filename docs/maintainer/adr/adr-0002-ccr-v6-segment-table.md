# ADR-0002: .ccr v6 段表架构 + ENT 存在结构段 + REG 坐标化

- 日期:2026-09-05
- 状态:accepted
- 决策者:DslsDZC
- 关联提交:`3a287cd`(feat: v6 SYM 归并/REG 坐标化)、v6 spec(2026-09-05-lattice-ir-v6-format.md)

## 背景

.ccr(格形态 IR)早期为线性指令投影(v5 前),全局变量/函数记录/寄存器信息分散,缺乏
结构化承载。v6 的目标形状(spec §3.2/§3.5):全局数据段带类型、函数记录声明区并入 vars、
寄存器以"坐标"描述生命周期。

## 决策

- **v6 = 段表架构**:.ccr 按段组织(存在结构段 ENT、数据段、函数记录段等),段表为格式骨架
- **ENT 存在结构段**:声明"什么东西存在"于后续各段,loader 侧有 entries_coexist 上界校验等
  一致性守卫(GC 批)
- **REG 坐标化**:REG 记录带 kind/parent/enter/exit/first/last;root_region span 派生函数边界
- **SYM 归并**:vars 并入函数记录声明区,globals 带 type
- 写读双端(ccr_io.cr)与格式 spec 同步演进

## 后果

- 正面:v5 前 .ccr 的线性形态被结构化段表取代——dump/验证/loader 都有明确格式锚点;
  REG 坐标让寄存器分配元数据可序列化、可对照验证(regalloc-consistency 三层定位)
- 负面:v5 前 .ccr 文件不兼容(格式边界硬切);ELF 发射层需保持零变化前提下适配
  (v6 落地时已验证发射零变化)

## 关联

- 文档:spec 2026-09-05-lattice-ir-v6-format.md;docs/maintainer/design/ir-op-semantics.md
- 提交:88272207(GC 批 3 定向测试)等 v6 系列
