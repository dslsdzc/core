# 寄存器分配器一致性契约

寄存器分配器在 Core 的 entry、live interval 和 coexist 模型上承担以下义务。每条义务都对应一个实现位置。`src/arch/x86_64/regalloc.cr` 是唯一真源，本文不复制实现。

## 三个独立问题

1. 程序逻辑：`.corespec` 文件中的 `#check` 和 `#ensure`，由 verifier 检查。
2. 分配器正确性：本文描述的义务。最优性证明留到后续工作。
3. 运行期自检：`verify_regalloc_consistency`，由 corearch 在 O2 路径调用。

## 定义

- entry：一个 IR 变量及其一个版本。每次定义创建一个版本。`def = -1` 表示参数或没有定义的 entry。
- live interval：全局指令顺序中的闭区间 `[live_start, live_end]`。
- coexist：两个 entry 的 interval 相交。该关系对称，不传递。
- location：entry 的物理位置，可以是寄存器或 home slot。分配结果写成 `g_opt_meta` 中的 `REG_ASSIGN` 变量到寄存器对。后端通过 `E2_REG_SLOT_BASE + reg` 哨兵解析寄存器。
- allocation result：corearch 在进程内计算的 `REG_ASSIGN` 对。

## 正确性义务

实现位置：`src/arch/x86_64/regalloc.cr`。

1. coexist 排他：同一 location 中的 entry 不共存。`verify_regalloc_consistency` 的规则 1 对 entry 排序，并在一次遍历中记录每个 location 的最大 `live_end`，避免二次两两检查。
2. 不读取过期版本：每次读取都看到当前 live 版本。规则 2 使用 `rl_rule2_func`。覆盖范围从第一个有版本的定义之后开始，并包括 `ALLOC_ARRAY` 和 `ALLOC_STRUCT` 创建的内存对象。
3. 驱逐配对：被驱逐的 entry 需要对应的写回。规则已经写明，但尚未实现。当前没有驱逐，因为超过五个共存的 entry 会留在栈上，没有可检查的事件。
4. 调用失效：调用点的 caller-saved entry 必须失效或保存。该规则等待 caller-saved 注解。

`--inject-*` 通道证明验证器读取真实数据：规则 1 和规则 2 会产生诊断。驱逐检查和 caller-saved 检查依赖分配器功能，不依赖单独的延迟层。

## 已知缺口

- entry 和 interval 使用文本范围，不使用 CFG liveness。RegionCheck 接入后会收紧该范围。
- `pass_stack_share` 已停用。原实现产生死输出，corearch 运行时该通道始终为空。恢复它需要在同一位置提供使用 alloc 的实现。
- `param_ents` 为 -1。被重新定义的参数没有 incoming-version entry，因为尾部 pass 只在 `prev[lv] < 0` 时添加 entry。`.ccr` 不再保存 `param_ents`，旧的有针对性测试已随 ENT carrier 删除。如果规则 2 需要，可以恢复 incoming-version entry。
- `entries_coexist` 现在拒绝越界的上界。检查位于 `entries_coexist`，`--inject-coexist-oob` 探针已移到 corearch。

## 参考实现

`src/arch/x86_64/regalloc.cr` 包含 `compute_live_ranges`、`compute_entries`、`entries_coexist`、`coexist_version_conflicts`、`verify_regalloc_consistency` 和 `alloc_registers`（context-greedy allocation）。

`grammar/corespec.ebnf` 定义程序逻辑规范语言。其中的 `SpecImplies` 产生式与本文无关。
