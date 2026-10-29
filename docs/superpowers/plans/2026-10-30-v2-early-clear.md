# V2.1 Early Clear Implementation Plan

> 状态：保守切片已实现（2026-10-30）；V2.1b 完整后支配/活跃性待实施。

**目标：** 在同一槽的分配全部死亡后，用 `IR_ARENA_CLEAR` 清空游标/档位/大对象 extent，保留 arena id 和 current，让后续分配立即复用同一槽。

**当前切片：**

- 槽 = FUNC/LOOP/FOR/UNSAFE，以及已 split 的 IF 不在本切片内。
- 候选 label：在该槽内、最后一次使用之后；候选点之前该槽的分配全部死亡；候选点之后同一基本块内必须有同槽分配。
- 候选点之后不得有跳回 ≤ 候选点的 jump/match（回边拒绝）。
- 非局部出口不 clear。
- 运行期 `arena_clear` 只清空当前 slot、size class 元数据和大对象 extent；不归还 slot，不切 current；区域出口 `arena_reset` 做最终 close。
- 解释器调用解释版 `arena_clear`；未导入 arena 时 ELF fallback stub 为 no-op。

**测试：** `tests/selfhost/test_early_clear.py` 4/4；`generics_test` canary +56B 为一条合法 clear，已授权重锁。
