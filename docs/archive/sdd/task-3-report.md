# Task 3 报告：词法面收窄（拒绝 `_` 分隔符，宽度后缀退役）

状态：完成
提交：`51d74be3`（change id `yptxltxk`，mutable。提交后 lead 做过一次 squash 修正，原 hash `aee25c67` 已失效、不可寻址。本报告内所有原始证据与原始提交内容一致，只有 hash 变化）。提交信息为 `fix: 语言面收窄 R1 Task 3，数字词法收窄…`（6 个文件，新增 97 行，删除 43 行）。
分支定位：`@-`（父提交 `99a3318c`，docs: R1 计划 Task 4 补 cir 缓存交互前置）。

## 1. Step 2 红态原始输出（改动前实测，真红）

```
$ nice -n 19 python3 tests/selfhost/test_lexer_parity.py
Traceback (most recent call last):
  File "/home/DslsDZC/core/tests/selfhost/test_lexer_parity.py", line 43, in <module>
    fn(); print('PASS', fn.__name__)
  File "/home/DslsDZC/core/tests/selfhost/test_lexer_parity.py", line 20, in test_bootstrap_rejects
    assert False, 'bootstrap accepted %s' % bad
AssertionError: bootstrap accepted 1_000
RC=1
```

逐条单跑（第一条失败会中断脚本，因此单独取每条的真实结果）：

```
=== test_bootstrap_rejects ===   RESULT: FAIL -> AssertionError bootstrap accepted 1_000
=== test_selfhost_rejects ===    RESULT: FAIL -> AssertionError ('1_000', 0,
    '...error[TF01]: Function return type mismatch...')
=== test_legal_forms_unchanged === RESULT: PASS
```

结果是两条 FAIL 加一条对照 PASS，与任务说明预期逐字一致。`test_selfhost_rejects` 的红是“只有既有 TF01，没有我们的诊断文本”，证明该断言确实咬在自有诊断上，不会假通过。

修复前基线（佐证“不报错地误编译”主张）：

```
$ ./build/corec run 'fn main()->int{x := 1_000; return x;}'
[1/5] tokenize... [2/5] resolve imports... [3/5] parse... [4/5] type check... [5/5] frontend done
RC=0                     ← 静默成功，x = 0（`1_000` 被当后缀消费 到 T_INT 取「无值」0）
$ ./build/corec run 'fn main()->int{return 10f32;}'
error[TF01]: Function return type mismatch ...   ← 宽度后缀静默丢弃，只剩类型错
RC=0
```

真红不是假通过：三条红线都由“bootstrap 接受”或“self-hosted 没有自有诊断”构成，不是断言本身失效。

## 2. 两处 lexer 改动（改前到改后）

### 2a. `src/compiler/lexer.cr`（Step 3）

进制前缀的三条循环（`:428-430`）：各删除 `|| hc == 95` / `|| oc == 95` / `|| bc == 95`，hex、oct、bin 都不再接受 `_`。加两行注释说明遗留的 `_` 交给下面的后缀段落报错。

后缀段落和 dex 路由（`:445-469` 原样，整段替换）：

```core
// 修复前（静默）：
suffix : ., mut = "";
if is_alpha(sx) != 0 { ...消费整段字母... suffix = str_sub(...); }   // '_' 属 is_alpha(95) 到 被当后缀吃掉
num_str := str_sub(_src, start, _pos - start - str_len(suffix));
if has_dot != 0 || suffix == "f32" || suffix == "f64" { T_DEX } else {
    ival := str_int_literal(num_str);
    if suffix == "u8" ... { } else if suffix == "i8" ... { } else if str_len(suffix) > 0 { }
    if str_len(suffix) > 0 { add_tok(T_INT, -1, ...); }              // 宽度后缀 到 无效 T_INT(-1)
    else { add_tok_int(T_INT, ival, ...); }
}

// 修复后（响亮，且不消费残余字符）：
sx := cur_char_at(_src, _pos, _slen);
if sx == 95 {
    add_error("invalid character '_' in numeric literal (digit separators not supported)");
} else if is_alpha(sx) != 0 {
    add_error("invalid suffix on numeric literal (width suffixes retired 2026-09-10)");
}
num_str := str_sub(_src, start, _pos - start);
if has_dot != 0 {
    add_tok_int_lex(T_DEX, str_to_scaled(num_str), str_intern(num_str), start_line, start_col);
} else {
    add_tok_int(T_INT, str_int_literal(num_str), start_line, start_col);
}
```

不消费残余字符，后续按标识符继续 tokenize（`1_000` 变成 `T_INT(1)` 加 `IDENT(_000)`），让 parser/checker 给出第二重信号，不不报错地也不猜。

Step 3(c) 遵守：`str_int_literal:221` 的 `if c == 95 { i = i + 1; continue; }`，以及 `str_to_scaled`、`str_to_f64_bits` 内部的 `_` 跳过逻辑都保留不动（diff 零改动）。

### 2b. `bootstrap/corec/frontend/lexer.py`（Step 4）

| 位置 | 改前 | 改后 |
|---|---|---|
| 前缀进制 digits 循环 `:92` | `while self.current() in digits or self.current() == '_'` | `while self.current() in digits`，循环后 `if self.current() == '_': self.error("invalid character '_' in numeric literal (digit separators not supported)")` |
| 十进制循环 `:103` | `while self.current().isdigit() or self.current() == '_'` | `while self.current().isdigit()`，并加同样的 `_` 报错 |
| 小数部分循环 `:108` | `while self.current().isdigit() or self.current() == '_'` | `while self.current().isdigit()`，并加同样的 `_` 报错 |
| 后缀段 `:110-114` | 消费 alpha 和 digit，拼进词素 `n += suffix` | `if self.current().isalpha(): self.error("invalid suffix on numeric literal (width suffixes retired 2026-09-10)")` |

`n = n.replace('_', '')`（现在 `:122`）按任务说明保留。现在已经没有输入可清理，保留无害。
诊断文本与 self-hosted 逐字一致，两条消息使用同一个双语实现来源。

## 3. bootstrap 既有测试改写（Step 5）

`tests/bootstrap/test_pipeline.py:check_integer_literals`：
- `Lexer('0x1f 0o17 0b1010 1_000')` 改为 `Lexer('0x1f 0o17 0b1010')`，期望 `[31, 15, 10]`。
- 新增拒绝环：`('1_000', '0x1_0', '10f32', '1_000.5')` 必须报 `SyntaxError`，任一被接受即 FAIL。
- `0x` 空进制位拒绝回路保留。PASS 行改为 `hex/octal/binary; separators/suffixes rejected`。

`tests/selfhost/test_lexer_parity.py` 按任务说明逐字新建，包含 bootstrap 拒绝、self-hosted 拒绝且断言自有诊断标记、合法形态对照三个函数。

## 4. grammar diff（Step 6）

`grammar/tokens.ebnf`：
- 注释段改写为“数字字面量不支持 `_` 分隔符，不支持任何宽度后缀（2026-09-10 语言面收窄 第2 用户裁决：两个实现统一响亮报错，宽度后缀是机器形状，归映射层）”。
- `INT_LIT = DIGIT { DIGIT } ;`，去掉 `[ INT_SUFFIX ]`。
- 删除 `INT_SUFFIX` 产生式整行。
- `DEX_LIT = ( DIGIT { DIGIT } [ '.' DIGIT { DIGIT } ] | '.' DIGIT { DIGIT } ) ;`，去掉 `[ 'f32' | 'f64' ]`，保留括号分组。
- DEX 注释段改写为退役记述。

`grammar/core.ebnf:57-59`：把“f32/f64 后缀 = apx CPU 位宽标注”改为“f32/f64 后缀已退役（2026-09-10 语言面收窄 第2）。词法对数字字面量的字母后缀一律响亮报错，宽度是机器形状，归映射层”。

核心约束满足：两条字面量产生式中已经没有 `_`，也没有任何后缀分支。

## 5. 重建（Step 7 前置）

```
$ nice -n 19 python3 build_selfhost_native.py      RC=0
[GUARD] corec: manifest OK (37 files)
[GUARD] corec: build log clean (error[ = 0, undefined = 0)
[GUARD] corearch: manifest OK (31 files)
[GUARD] x86_64-linux target: manifest OK (3 files)
[GUARD] corearch: build log clean (error[ = 0, undefined = 0)
[GUARD] corelsp: manifest OK (26 files)
[GUARD] corelsp: build log clean (error[ = 0, undefined = 0)
=== BUILD SUCCESS ===
```

重建后没有再改动任何源文件，`build/corec` 与提交内容同源。

## 6. Step 7 全部命令的 rc 和关键输出

| # | 命令 | rc | 关键输出 |
|---|---|---|---|
| 1 | `python3 tests/selfhost/test_lexer_parity.py` | 0 | `PASS test_bootstrap_rejects` / `PASS test_selfhost_rejects` / `PASS test_legal_forms_unchanged`，三条全 PASS |
| 2 | `python3 tests/bootstrap/test_pipeline.py` | 0 | `29/29 passed`（含 `[PASS] integer literal forms: hex/octal/binary; separators/suffixes rejected`） |
| 3 | `./build/corec run 'fn main()->int{x := 1_000; return x;}'` | 1 | `error: invalid character '_' in numeric literal (digit separators not supported)`（前缀是 `error: `，不是 `error[`） |
| 4 | `./build/corec run 'fn main()->int{return 1000;}'` | 232 | 五行阶段输出，`error` 计数为 0 |
| 5 | `python3 tests/selfhost/test_compile.py` | 0 | `All selfhost compile tests passed.` |

追加回归（超出任务说明判据，用于确认“合法形态零变化”）：

| 套件 | rc | 结果 |
|---|---|---|
| `tests/selfhost/test_dex_arith.py` | 0 | 11/11 passed |
| `tests/selfhost/test_dex_type.py` | 0 | 5/5 passed |
| `tests/selfhost/test_interp_float.py` | 0 | ALL PASS |

合法形态实测（`./build/corec run`，rc 即返回值）：`0x1f` 得到 31，`0o17` 得到 15，`0b1010` 得到 10，`1000` 得到 232（1000 mod 256），`0xDEADBEEF` 得到 239，`42-3` 得到 39，`x:=1000; x/10` 得到 100，`_x := 7; return _x;` 得到 7（`_` 作标识符不受影响），`for i in 0..4` 得到 0（`..` 范围没有被 `.` 消费破坏），`loop/break` 得到 4，`x : auto = 5` 得到 5。

响亮性另测（`check` 和 `build` 路径，不只 `run`）：

```
$ ./build/corec check /tmp/t3_bad.cr        到 error: invalid character '_' ...  RC=1
$ ./build/corec build /tmp/t3_bad.cr -o ... 到 error: invalid character '_' ...  RC=1，且未产出二进制
$ ./build/corec build /tmp/t3_suf.cr -o ... 到 error: invalid suffix ... (width suffixes retired 2026-09-10) RC=1，且未产出二进制
```

bootstrap 侧单测（`:88-115` 新逻辑）：合法的 `0x1f/0o17/0b1010/1000/3.14/0.5/1.5/0xDEADBEEF/0b0` 全部按原样 tokenize；`1_000`/`1_000.5`/`0x1_0`/`0o1_7`/`0b1_0` 报“not supported”；`10f32`/`1.5f64`/`10u8` 报“retired”；`0x` 报“invalid integer literal”。

## 7. 提交

```
51d74be386ff  fix: 语言面收窄 R1 Task 3，数字词法收窄（_ 分隔符与宽度后缀一律响亮报错：
              消灭 1_000 静默 0 误编译；bootstrap/self-hosted 双侧对齐；grammar + bootstrap
              测试同步；新增词法对照测试）
bootstrap/corec/frontend/lexer.py   | 23 ++++++++++++--------
grammar/core.ebnf                   |  5 ++--
grammar/tokens.ebnf                 | 15 +++++++------
src/compiler/lexer.cr               | 41 ++++++++++++++++++-------------------
tests/bootstrap/test_pipeline.py    | 13 ++++++++---
tests/selfhost/test_lexer_parity.py | 43 +++++++++++++++++++++++++++++++++++++++
6 files changed, 97 insertions(+), 43 deletions(-)
```

我的原始提交是 `aee25c67`，5 个文件，新增 54 行，删除 43 行。lead 随后把被其并发提交收走的测试文件 `tests/selfhost/test_lexer_parity.py` squash 回本提交，所以现在是 `51d74be3`，6 个文件，新增 97 行，删除 43 行。测试文件因此归位本任务提交，concern ① 由 lead 侧完整流程。

没有越界文件。提交后工作副本状态为 `The working copy has no changes.`。本报告在 `.superpowers/`（`.gitignore:33` 已忽略），是本地工件，不入提交。

## 8. 自审

- 两个编译器一致：拒绝消息文本逐字相同（`invalid character '_' in numeric literal (digit separators not supported)` / `invalid suffix on numeric literal (width suffixes retired 2026-09-10)`），合法形态判定一致（含贪心 hex `0x1f32`，双方都按 hex 收，属于既有语义）。
- 合法形态零变化：见第 6 节追加回归和形态实测。
- `error: ` 前缀：新断言只断言消息标记和出现 `error`，没有断言 `error[`。对照组合法形态仍断言 `'error[' not in out`。
- 提交单一：一次路径限定提交，5 个文件，没有越界。

## 9. 待关注项和注记（3 条，均不阻塞）

1. 测试文件落在父提交而不是本提交，已经完整流程（lead 处置）：`tests/selfhost/test_lexer_parity.py` 由我在 18:42 创建，被 lead 的并发提交 `99a3318c`（xvywpzqo，docs 提交）一并收走。lead 随后用 `jj squash -u --from 99a3318c --into <本提交>` 把该文件归位，本提交现在是 `51d74be3`（6 个文件，新增 97 行，删除 43 行），change id 不变。文件内容与任务说明逐字一致，未被我或 lead 改动。
2. lexer 错误重复 4 次：`corec` 对 `1_000` 打印同一条 lexer 诊断 4 遍（res_imports 多轮 tokenize 累积错误，加两处 import 展开）。这是既有行为（lexer.cr 的 `tokenize()` 头部注释明确写了“不再清零 g_error_count”），不是本任务引入。如果后续要收敛为单条，属于独立任务。
3. 机制差异（不是语义分歧）：`0x1_0` 在 self-hosted 会先由既有 `bad_prefix_digit` 报“invalid digit in integer literal”，再报本文的收窄消息，共两条；bootstrap 只报后者一条。两者都响亮，都含同一核心文本，测试断言按标记匹配，因此稳定。如果需要逐字对齐消息条数，需要另立条目。
