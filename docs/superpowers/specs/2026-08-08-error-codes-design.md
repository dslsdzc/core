# 错误码系统重新设计

日期：2026-08-08
状态：已批准（brainstorming 会话，含心理学/人因研究支撑）

## 1. 背景与动机

### 1.1 现状问题

- 错误码 145 条平铺分段（`L`/`P`/`N`/`I`/`TA`/`TF`/`TB`/`TU`/`TC`/`TM`/`TK`/`TS`/`TG`/`B`/`R`/`E`/`ICE`），**维度混杂无层级**：`L`/`P`/`N`/`I` 是编译阶段，`TA`/`TF` 是类型子系统，`B` 是借用，`R` 是运行时
- **同性质分散**："类型不匹配"因上下文不同分裂在 `TA01`/`TF07`/`TS03`/`TM07` 四个段
- **无严重度维度**：无法支撑致命/警告决策（PR #23 诊断致命化争论的根源）
- 编译器自身源码有数百条类型检查诊断（`dyn_arr.cr` 156 条等），致命化会让自举失败

### 1.2 心理学/人因研究依据

- [Dagstuhl 22052 研讨会](https://drops.dagstuhl.de/storage/04dagstuhl-reports/volume12/issue01/22052/html/DagRep.12.1.119/DagRep.12.1.119.html)：差错误消息对新手麻痹性伤害；呈现是头等设计关切
- [可读性四因素](https://dlnext.acm.org/doi/fullHtml/10.1145/3555009.3555032)：消息长度、行话、句子结构、词汇显著影响可读性
- [标识符研究](https://ieeexplore.ieee.org/document/1631100)：全词 > 缩写（≈全词）> 单字母——但类别位的用途是**快速锁定**（第一性原理），理解靠消息
- [颜色不能唯一编码](https://www.nngroup.com/articles/hostile-error-messages/)：必须冗余线索；终端主题会重映射 ANSI 颜色
- [Google cosmetic changes](https://research.google/pubs/the-impact-of-cosmetic-changes-on-the-usability-of-error-messages/)：呈现改动带来大幅可用性提升

### 1.3 设计原则（brainstorming 定稿）

1. **人机双读分离**：码值给机器（唯一、稳定、可解析），渲染给人（快速锁定、可读）——两层独立设计
2. **severity 可靠编码 = 词**：`error`/`warning`/`note` 词是唯一可靠编码（终端变色、色弱不影响）；颜色仅增强
3. **类别单字母快速锁定**：码的字母段只表达类别（第一性原理：锁类别，理解靠消息）；子类信息在消息里
4. **同性质聚合**：类型系 8 段合并为 `T` 类

## 2. 码值结构（机器层）

**定长 6 位：`T00001`**（类别 1 字母 + 序号 5 位）

```
位 1    位 2-6
类别    序号（00001-99999）
```

### 2.1 类别表（10 类）

| 字母 | 类别 | 覆盖原段 |
|---|---|---|
| `L` | 词法 | L |
| `S` | 语法 | P |
| `U` | 名字解析 | N（用 U 避免与 Note 词/severity 混淆） |
| `T` | 类型 | I + TA + TF + TB + TU + TS + TM + TK（8 段聚合） |
| `G` | 泛型 | TG |
| `B` | 借用/所有权 | B |
| `F` | 控制流 | TC |
| `R` | 运行时 | R |
| `O` | IO/环境 | E |
| `I` | 内部 | ICE |

### 2.2 序号

- 类别内唯一，5 位（00001-99999）——为未来图分析提示（匹配度/业务逻辑建议，大量 `N` 类提示）留足空间
- 序号无语义（不编码检查点），检查点信息在消息文本中

### 2.3 severity 不在码内

severity 是**诊断记录的独立字段**（内部），显示为词，颜色仅增强：

| 内部值 | 词 | 显示色（增强） | check 退出码 |
|---|---|---|---|
| 0 Error | `error` | 红 | 非零（默认） |
| 1 Warning | `warning` | 黄 | 零 |
| 2 Note | `note` | 蓝 | 零 |

覆盖策略：`--fatal-warnings` flag 将 Warning 视为 Error（码不变，报告层覆盖——GCC `-Werror` 模式）。

## 3. 显示规范（人读层）

### 3.1 终端默认渲染

```
error[T00001] cannot assign string to int
  --> examples/bad.cr:3:9
  3 | x : int = "str";
    |          ^^^^^^ expected int, found string
```

- **词开头**：`error`/`warning`/`note`（可靠编码，Rust 式）
- **`[码]`**：类别+序号框起（延续现有 `error[L001]` 视觉血缘）
- 颜色仅增强：词按 severity 着色（红/黄/蓝）；类别位可加粗（与序号区分，形态主题免疫）
- 位置行 `--> file:line:col` 灰色（现有格式延续）
- 源码上下文行 + `^^^` 标注（现有格式延续）
- 消息简短（可读性四因素：短、无行话、建设性措辞；不用 `illegal`/`offending`/`fatal` 语气词）

### 3.2 示例

```
error[T00001] cannot assign string to int
warning[U00012] unused variable 'temp'
note[F00001] loop condition always true (match 100%)
```

## 4. 机器衔接

| 消费者 | 读什么 |
|---|---|
| `check` 退出码 | 诊断记录 severity 字段（E→非零/W,N→零）；`--fatal-warnings` 覆盖 |
| LSP（corelsp） | severity 字段 → DiagnosticSeverity（1/2/3）；码值 → code 字段 |
| grep/脚本 | `^error\[` 或码值 `T\d{5}` |
| 未来图分析提示 | 大量 Note 类（匹配度/业务逻辑建议）挂入，序号 5 位充足 |
| 诊断记录 | 32→40B：加 severity 字段（+ file_id，LSP 需要，见 corelsp 规格） |

## 5. 严重度归属表（145 条逐条）

### 5.1 归属原则

- 语法/语义正确性错误 → Error（编译必须失败）
- 设计警告/可运行代码的风格性问题 → Warning
- 编译器自身源码现存数百条诊断（`TC02` 等）→ Warning（否则自举失败）
- 提示类（未来图分析）→ Note

### 5.2 逐条归属（原码 → 新码 → severity）

**`L` 词法（→ `L` 类）**——全部 Error：
| 原码 | 新码 | 消息 |
|---|---|---|
| L001 | L00001 | Unterminated string literal |
| L002 | L00002 | Unterminated block comment |
| L003 | L00003 | Invalid escape sequence |
| L004 | L00004 | Empty character literal |
| L005 | L00005 | Multi-character character literal |
| L006 | L00006 | Invalid hex escape |
| L007 | L00007 | Invalid integer suffix |
| L008 | L00008 | Integer literal out of range |
| L009 | L00009 | Invalid float literal |
| L010 | L00010 | Invalid float suffix |
| L011 | L00011 | Unknown character |

**`S` 语法（→ `S` 类）**——全部 Error：`P001-019` → `S00001-00019`（按原序）
**`U` 名字（→ `U` 类）**——全部 Error：`N001-021` → `U00001-00021`（按原序）
**`I` 推断（→ `T` 类）**——全部 Error：`I001-006` → `T00001-00006`（接在 TA 系前）

**`T` 类型（→ `T` 类）**：
| 原段 | severity | 新码 |
|---|---|---|
| TA01-07 | Error | T00007-00013 |
| TF01-17 | Error | T00014-00030 |
| TB01-09 | Error | T00031-00039 |
| TU01-03 | Error | T00040-00042 |
| TS01-04 | Error | T00043-00046 |
| TM01-09 | Error | T00047-00055 |
| TK01-08 | Error | T00056-00063 |
| I001-006 | Error | T00001-00006 |

**`G` 泛型（→ `G` 类）**——全部 Error：`TG01-02` → `G00001-00002`
**`B` 借用（→ `B` 类）**——全部 Error：`B001-004`/`B010-011`/`B020-022` → `B00001-00010`（按原序）
**`F` 控制流（→ `F` 类）**：
| 原码 | severity | 新码 | 理由 |
|---|---|---|---|
| TC01 | Error | F00001 | if 条件非 bool——真错误 |
| TC02 | **Warning** | F00002 | 分支类型不一致——编译器自身源码大量存在（数百条），可运行 |
| TC03 | Warning | F00003 | if 无 else 返回值——风格性 |
| TC04 | Error | F00004 | while 条件非 bool |
| TC05 | Error | F00005 | break 带值冲突 |
| TC06 | Error | F00006 | break 在循环外 |
| TC07 | Error | F00007 | continue 在循环外 |

**`R` 运行时（→ `R` 类）**：
| 原码 | severity | 新码 | 理由 |
|---|---|---|---|
| R001 | Error | R00001 | 编译期除零 |
| R002 | Error | R00002 | 编译期越界 |
| R003 | Error | R00003 | 编译期溢出 |
| R004 | Warning | R00004 | 数值转换损失精度——警告性质 |

**`O` IO（→ `O` 类）**——全部 Error：`E001-004` → `O00001-00004`
**`I` 内部（→ `I` 类）**——全部 Error：`ICE01-03` → `I00001-00003`

### 5.3 自举可行性

编译器自身源码现有诊断（`dyn_arr.cr` 156 条等）在归属表下均为 Warning（`TC02` 类）→ `check` 不失败 → 自举不阻塞。PR #23 的"诊断致命化"以"severity 字段 + 退出码判定"替代（`N001` 类 Undefined name → `U` 类 Error → 致命，测试断言成立）。

## 6. 迁移路径

1. 诊断记录 32→40B：+severity 字段、+`file_id` 字段（`corelsp` 需求）
2. `check_error(code, msg, line, col)` → 新签名 `check_error(sev, code, msg, line, col)`（调用点机械替换）
3. 错误码常量重命名：`EC_N_UNDEFINED` → `EC_U_UNDEFINED` 等（以 `ast.cr`/`diag.cr` 实际常量名为准）
4. `print_diagnostics` 输出格式：`error[L001]:` → `error[T00001]:`
5. `error-codes.md` 重写为本规格的映射表
6. `--fatal-warnings` flag
7. 全量回归 + 自举 O0/O1

## 7. 明确不做（YAGNI）

- 消息模板参数化/本地化（保留现有英文消息，仅换码）
- LLM 生成解释（研究显示[效果不一致](https://searchworks-lb.stanford.edu/articles/edsarx__edsarx.2409.18661)，专家手写结构最佳）
- 修复建议/quick-fix 数据（未来图分析提示阶段）
- LSP 的 severity 渲染（`corelsp` 消费端自映射）
