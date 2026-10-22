# `bi_add` 内建表设计

## 概述

`bi_add` 表保存编译器内建函数的名称和返回类型，共 22 条。表里不保存参数类型。本文说明表的分类、使用点、参数面不检查的决定，以及已知的遮蔽和名字碰撞。

## 表结构

表在运行时构造，使用三个平行数组：

- `g_rt_builtin_names`：内建名称。
- `g_rt_builtin_ret_types`：返回类型。
- `g_rt_builtin_count`：条目数量。

三个使用点都按名称扫描，因此增加列不会改变条目编号：

1. `checker.cr` 的调用回退分支。
2. `checker.cr` 的内建注册分支。
3. `ir_gen.cr` 的 `ir_call_return_type`。

表不序列化进 `.ccr`。修改表结构不会改变 `.ccr` 的段布局。

## 分类

22 条中有 20 条的参数是机器字、字节、地址、下标、计数或打包字。ABI 直接使用寄存器值，参数类型不匹配不算错。

有 2 条的参数包含字符串：

| 名称 | 返回类型 | 参数 |
|---|---|---|
| `load_str_ptr` | `string` | `(buf: string, pos: int)` |
| `store_str_ptr` | `int` | `(buf: string, pos: int, val: string)` |

其余 20 条见证据文档。

## 决定：参数面不检查

`bi_add` 表继续只保存名称和返回类型，不增加参数类型列，也不为内建合成 `FuncInfo` 或参数符号。

理由：

- 20/22 条的参数语义就是裸字，ABI 使用的也是裸寄存器值。参数面免检是有意设计的边界。
- 给内建合成 `FuncInfo` 会为每个未被 `.cr` 遮蔽的内建建立一行 `SYM_FN`，改变符号编号，可能改变 `.ccr` 的 SYM 段。为 2 条有类型条目付出这个代价不成立。
- 参数面免检需要登记为契约，不能只在代码里默认存在。

契约写法：

> 未被 `.cr` 定义遮蔽的 `bi_add` 条目，参数面不做类型检查。

## 已知边界

有 6 条被 `.cr` 真定义遮蔽：

| 名称 | `.cr` 定义位置 |
|---|---|
| `r64` | `src/compiler/dyn_arr.cr` |
| `w32` | `src/compiler/dyn_arr.cr`、`src/compiler/elf.cr` |
| `w64` | `src/compiler/dyn_arr.cr`、`src/compiler/elf.cr` |
| `_dyncpy` | `src/compiler/dyn_arr.cr` |
| `fiber_init` | `src/stdlib/scheduler.cr` |
| `sched_go` | `src/stdlib/sched.cr` |

遮蔽规则是用户定义优先。引用这些条目时，必须写“未被 `.cr` 遮蔽的内建条目”。

`sched_call_0` 到 `sched_call_4` 只在后端发射和注册，没有 `.cr` 调用点。给它们补参数类型没有可保护的调用点。

### `fiber_init` 名字碰撞

- 内建侧：`fiber_init(stack_bottom, entry_fn) -> int`，两个参数。
- `.cr` 侧：`fn fiber_init()`，零参数，初始化调度全局。
- 调用点：`fiber_init(stack_top, wrap_addr)`，两个参数，意图是调用内建侧。
- 可达性：全仓没有 `import scheduler`，所以零参数 `.cr` 定义和两参数调用当前不在同一个编译单元，不可达。
- 可达后果：如果同一个单元同时引入两者，零参数 `.cr` 定义会遮蔽两参数内建，而当前不校验实参个数，会不报错地产生错误行为。

这是潜伏缺陷，不是当前缺陷。需要登记到 TODO。

## 实施清单

| # | 动作 | 位置 |
|---|---|---|
| 1 | 在 TODO 登记参数面免检契约，使用上面的契约写法 | `TODO.md` |
| 2 | 登记 `fiber_init` 名字碰撞，注明“潜伏、当前不可达” | `TODO.md` |
| 3 | 保留 22 条逐条分类和取证位置 | `docs/superpowers/implementation/2026-09-19-builtin-table-evidence.md` |

## 不包含

- 不增加参数类型列。
- 不为内建合成 `FuncInfo` 或参数符号。
- 不改变条目编号或顺序。
- 不改变 `.cr` 定义优先的遮蔽规则。
- 不修 `fiber_init` 碰撞；本轮只登记。

## 未决问题

没有。参数面免检和 `fiber_init` 登记都由维护者在 2026-09-19 决定。
