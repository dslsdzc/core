# V2.1 Early Clear Implementation Plan

> 状态：V2.1b 后支配版已实现（2026-10-30）。

**目标：** 在同一槽的分配全部死亡后，用 `IR_ARENA_CLEAR` 清空游标/档位/大对象 extent，保留 arena id 和 current，让后续分配立即复用同一槽。

**当前切片：**

- 槽 = FUNC/LOOP/FOR/UNSAFE，以及已 split 的 IF 不在本切片内。
- 候选 label：在该槽内；候选 label 必须后支配该槽“候选点之前”所有分配的全部使用；候选点之后同一基本块内必须有同槽分配。
- 候选点之后不得有跳回 ≤ 候选点的 jump/match（回边拒绝）。
- 非局部出口不 clear。
- 运行期 `arena_clear` 只清空当前 slot、size class 元数据和大对象 extent；不归还 slot，不切 current；区域出口 `arena_reset` 做最终 close。
- 解释器调用解释版 `arena_clear`；未导入 arena 时 ELF fallback stub 为 no-op。

**测试：** `tests/selfhost/test_early_clear.py` 7/7；`generics_test` canary 保持基线值（此前 +56B 的 clear 已因 unit 槽漏计修正撤销）。
