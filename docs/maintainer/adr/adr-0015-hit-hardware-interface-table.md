# ADR-0015: HIT 硬件接口表：跨平台硬件访问（取代 .crasm 汇编层）

- 日期：2026-09-05
- 状态：accepted（设计定稿；M1 最小核推进中）
- 决策者：DslsDZC

## 背景

`.crasm` 独立汇编层废弃（ADR-0001）后，内核路线的 MMIO/特权/中断访问需要受控入口，要求跨平台统一、可验证，并与 `.cr` 语义衔接。

## 决策

- HIT 是表驱动的硬件接口：最小核提供 4 事件契约 {sub, nand, load, store} 加投影表，更换投影表即可更换平台。
- 跨平台使用 HIT 事件加投影表；MMIO/特权/中断使用 `.cr` unsafe 加 HIT extern 接口事件。
- 事件的可读形态是 v6 NOD 文本 dump；`NOD op` 与 HIT `event_id` 的对齐是实施期事项。
- 硬件访问进图后获得 `provenance`（声明式进图路径，与 `alloc_at` 同构）。

## 后果

- 正面：硬件层有统一契约，通过投影表更换平台；事件级可验证；取代 `.crasm` 的私有映射表。
- 负面：标准硬件表（寄存器/MMIO 区域）工程量大；表外硬件行为需要 unsafe 人工保证。

## 关联

- 文档：specs/2026-09-05-hardware-interface-table.md；docs/maintainer/design/crasm.md（废弃结束）
- 相关 ADR：ADR-0001（.crasm 退役）、ADR-0002（v6 NOD）
