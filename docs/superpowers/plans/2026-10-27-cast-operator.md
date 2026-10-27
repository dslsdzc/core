# `cast` 运算符：替换 `as` 并固定转换集合

> 状态：已实施（2026-10-27）
> 日期：2026-10-27
> 关联：`grammar/core.ebnf` · `docs/developer/syntax.md` §5.5、§7.5、§12.1 · `TODO.md` 2026-09-16-34

## 概述

`as` 值转换当前不做转换。检查器对任意类型对放行，生成器只发一次 `IR_LOAD`，把源值的位原样解释成目标类型。`1.5 as int` 返回 96，因为 1.5 的定点表示是 1500000，取低 8 位得到 96。本文把运算符改名为 `cast`，删除 V3 残留的 `cast<T>(expr)`，并把允许的类型对固定成白名单。

## 决定

1. 中缀关键字 `cast` 取代 `as`，形式为 `expr cast Type`。语法位置与 `as` 相同：在 `parse_unary` 中，后缀表达式之后、算术运算之前。
2. 删除 `cast<T>(expr)`。V4 不接受 `<T>`，这个形式是 V4 迁移的遗漏。
3. `cast` 进入关键字表，`as` 退出。关键字总数保持 39。
4. 转换按白名单判定。白名单外的类型对报 `error[TA09]`，不产生值，也不退化成位重解释。
5. 值转换有真实语义。dex 的语义是精确十进制，保留 6 位小数。默认表示是缩放 10⁶ 的 int64；标注 `apx` 的变量改用 binary64 快路径，属于显式放宽精度的模式。`int cast dex` 产生精确形式，即乘以 10⁶；`dex cast int` 对精确形式整除 10⁶ 并向零截断，对 `apx` 形式用 F2I 截断。存入 `apx` 槽时由既有的 `dex_store_adjust` 完成表示转换。
6. 指针族转换沿用现有指针模型：转换本身不要求 `unsafe`，外部地址的解引用仍由 `TU03` 要求 `unsafe`。`asp` 的取值沿用现有实现：int 转指针得到 1，引用转指针得到 0，指针转指针保留源值的 `asp`。
7. `char` 与 `int` 的互转暂时保留，语义是当前内部表示，即字符驻留表的索引，不是 Unicode 码点。match 的字面量分支依赖 `'A' cast int` 取到这个值，因此不能在本批直接关闭。码点化是独立任务。实施时这两条转换的语义随之改变，并补负例。

## 白名单

| 源类型 | 目标类型 | 语义 | 前提 |
|---|---|---|---|
| `T` | `T` | 恒等，不生成指令 | 无 |
| `int` | `dex` | 乘以 10⁶ | 无 |
| `dex` | `int` | 除以 10⁶，向零截断 | 无。有损，但由代码显式写出 |
| `int` | `*T` | 整数地址转指针 | 任意位置，解引用时检查 |
| `*T` | `*U` | 指针重解释，保留 `asp` | 任意位置，解引用时检查 |
| `&T` | `*T` | 引用转裸指针，`asp` 为 0 | 任意位置，解引用时检查 |
| `&mut T` | `*T` | 同上 | 任意位置，解引用时检查 |
| `char` | `int` | 字符驻留索引，临时语义 | 无 |
| `int` | `char` | 同上 | 无 |

白名单外的组合包括：`int` 与 `bool` 互转、`int` 与 `string` 互转、`dex` 与指针互转、`bool` 与指针互转、带 payload 的枚举与整数互转。这些组合此前静默通过，改后报 `error[TA09]`。

## 语法

```ebnf
Unary = ('-' | '!' | '&' | '&mut') Unary | Cast ;
Cast = CallOrField { 'cast' Type } ;
CallOrField = Primary { '(' [ ArgList ] ')' | '.' IDENT | '[' Expr ']' } ;
```

示例：

```core
d : dex = 7 cast dex
n : int = d cast int
unsafe:
    p := 0x7fff0000 cast *int
    q := p cast *int
```

`cast` 左结合，允许链式书写：`x cast int cast dex`。

## 实施清单

| 顺序 | 文件 | 改动 |
|---|---|---|
| 1 | `grammar/core.ebnf` | 新增 `Cast` 产生式，`Unary` 引用它 |
| 2 | `docs/developer/syntax.md` | §1.3 关键字表 `as` 改 `cast`；§5.5、§7.5、§12.1 的示例改用 `cast`；写明白名单 |
| 3 | `docs/maintainer/design/pointer-model.md` | `cast<int*>(p)` 改为 `p cast *int`；`0x7fff0000 as *int` 改为 `0x7fff0000 cast *int` |
| 4 | `docs/developer/tutorial.md` | `cast<T>(p)` 改为 `p cast *T` |
| 5 | `src/compiler/lexer.cr` | 关键字表 `"as"` 改 `"cast"` |
| 6 | `src/compiler/ast.cr` | `T_AS` 改名 `T_CAST`；新增 `EC_TA_CAST = 4009` |
| 7 | `src/compiler/parser.cr` | `expr cast Type` 中缀解析；删除 `cast<T>(expr)` 分支 |
| 8 | `src/compiler/checker.cr` | `EXPR_AS` 分支改成白名单判定，不通过报 `TA09` |
| 9 | `src/compiler/ir_gen.cr` | 值转换发真实的乘除指令；恒等转换直接返回源变量 |
| 10 | `bootstrap/corec/syntax/tokens.py` | 关键字 `"as"` 改 `"cast"`，保持三张关键字表一致 |
| 11 | `tests/` | 语料里的 `as` 改为 `cast`；新增正例与负例 |

## 验收

1. `d : dex = 7 cast dex` 后 `@raw_int(d) == 7000000`。
2. `1.5 cast int` 返回 1，不返回 96。
3. `x cast int` 其中 `x: string` 报 `error[TA09]`，构建零产物。
4. `p := 0 cast *int` 可以构造；在非 `unsafe` 域解引用报 `TU03`。
5. `x as int` 报语法错误，`cast<int>(x)` 报语法错误。
6. 三张关键字表差集仍为空：自举 39、bootstrap 39、V4 目标 39。
7. `check src/compiler` 通过，`full-bootstrap` 的 corec2 与 corec3 逐字节相同。
8. canary 值如有变化，按 `tools/baseline/REBUILD.md` 的规则记录旧值和原因，再更新锁定值。

## 不包含

1. `char` 的码点化。本批只把现有表示暴露为显式转换，不改变表示。
2. 枚举与整数互转。
3. 结构体双关。类型双关继续用指针完成。
4. `@` 内建形式的转换。`@` 是控制编译器的原语，不承担运行期值转换。
5. 隐式转换。转换一律显式写出。

## 未决问题

1. 精确形式转 `int` 的负数截断方向。整数除法在 x86 上向零截断，与 C 一致；实施时用 `-1.5 cast int` 得到 `-1` 作为断言。
2. `*T cast int` 未开放。实测 `n cast *int cast int` 得到 `2n`，说明 int 的带标签表示与指针字之间的转换不正确。该方向没有使用者，等表示问题查清后再开放。
3. `int cast char` 的开放时间，由 char 码点化批次决定。
