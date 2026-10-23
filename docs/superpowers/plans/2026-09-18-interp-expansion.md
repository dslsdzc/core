# 字符串插值展开（批 8 插队，(b) 裁定）：实施计划与复核项处置记录

> 实施记录：[implementation/2026-09-18-interp-expansion.md](../implementation/2026-09-18-interp-expansion.md)
> 状态：计划（已实施；实施记录见上述文件）。本文件保留目标、签字面与三段实现的设计。
> 前置：`#124`（词法修复：插值分支双推进导致首字符被不报错地丢弃、结束引号被吞，引起 P21 级联）已合入（`2dbe528b`）。

## 0. 目标与签字面

- 裁定 (b)：修 lexer，并在同一批实现展开；规则 A–E 分两次签收（类型表、转义与嵌套、多段拼接、落点）。
- 落点修正（已批准）：parser 建链，checker 就地把洞节点改写成带类型转换的调用，ir_gen 不改动。理由 2 是决定性的：硬错落在 checker，因此受既有 fail-closed 门禁覆盖；ir_gen 侧报错不在门禁内。

## 1. 实现（三段）

1. lexer：含洞字面量拆成 part token（段为 `T_STRING`，洞为 `T_INTERP`，lexeme 为洞内原文）。iv 回填时加法不使用按位或，因为 bootstrap 后端不支持 `|` 和 `&`，见 `#2026-09-18-15`。取值含义：`+1` 表示属于本插值字面量，`+2` 表示其后还有 part，`4` 表示只有洞且已闭合。
2. parser：`parse_interp_run` 把各段串成 `seg + hole …` 链，只连接同一字面量的 part；无洞字面量逐字保持旧行为。洞表达式在 `parse_all` 末尾统一解析。此时 token 流已经用完，因此可以安全地重新 `tokenize`；洞内嵌套插值自然覆盖。
3. checker：`EXPR_INTERP_HOLE` 就地改写。扁平 AST 的父节点只存索引，因此不需要父指针。`string` 保持恒等，`int` 转为 `int_str`，`bool` 转为 `bool_str`，其余类型报 P028；畸形插值报 P027。

> 对抗复核处置、零影响与换代、未覆盖面、纪律增量、门禁分工（原第 2–6 节）见 [implementation/2026-09-18-interp-expansion.md](../implementation/2026-09-18-interp-expansion.md)。
