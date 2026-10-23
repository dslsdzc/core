# ADR-0020: IR 双形态确立：.cir 图形态 + .ccr 格形态

- 日期：2026-05-28（.cir/.ccr 格式与 spec 文档）
- 状态：accepted（演进中：.cir 图形态保持，.ccr 经历 v2-v6 段表升级，见 ADR-0002）
- 决策者：DslsDZC

## 背景

自托管编译器需要中间产物格式表示“语义保留”：单一 IR 要么偏图（对验证友好），要么偏线性（对后端友好）。早期（2026-05-28）确立两种产物：数据流图描述（`.cir`）和二进制格式（`.ccr`）。

## 决策

- `.cir` 是数据流图格式描述（图形态，供验证和分析消费）。
- `.ccr` 是二进制格式（格形态的线性投影，供后端消费；早期版本包含变量段和指令段）。
- `corec` 产出两者，`corearch` 消费 `.ccr`（前后端以 `.ccr` 为契约，见 ADR-0004）。
- v6（2026-09）把 `.ccr` 升级为以存在结构为主体（段表 + ENT/NOD/REG），`.cir` 语义是图坐标的真源。

## 后果

- 正面：验证面（`.cir`）与执行表示（`.ccr`）分离；格式演进有 spec 文档和 schema（`ir-schema/`）。
- 负面：双格式同步有成本（`.cir`/`.ccr` 的表述需要一致）；v5 到 v6 不兼容（中间产物没有持久生态，可以接受）。

## 关联

- 文档：docs/ir-schema/（schema）；docs/maintainer/design/existence-structure.md（v6）；docs/archive/2026-08-27-lattice-form-ir-design.md（方向）
- 相关 ADR：ADR-0002、ADR-0004
