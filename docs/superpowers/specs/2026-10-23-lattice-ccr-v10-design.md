# v10 目标无关格形态 `.ccr` 规格

## 状态

设计定稿，待实现。

本规格定义 `.ccr` v10 的语义模型和字节形状。它取代 v9.x 的槽语义，不提供自动迁移：v9.x 文件整类拒绝。

## 1. 定位

`.ccr` 是格形态的落盘表示，不是线性指令流。

```text
.cir  关系空间：图、生成方法、输入边
.ccr  存在空间：节点、边、条目、区域
编码  物理投影：HIT 事件、寄存器、栈、ABI、机器码
```

`.ccr` 必须能重建：

- 图事件和生成方法；
- 数据边和 state 边；
- 变量乘条目的存在版本和区间；
- 区域嵌套和共存关系。

文件序只是生产者选择的合法拓扑调度。它不是唯一执行顺序，不是语义主干。消费方可以按边约束重新调度。

## 2. 硬约束

1. `.ccr` 不包含目标机器事实：位宽、字节偏移、步长、对齐、字节序、寄存器、栈、ABI。
2. 位置的语义是“条目标识 + 路径”，不是字节地址。
3. 赋值语义是版本推进：`STORE` 表达 `ρ(target) := ρ(value)`，不是固定宽度内存写。
4. `TYPE` 是语义域/约束，不是机器类型表。它可以被未来 target 擦除、动态实现或映射为原生域，但 `.ccr` 不假设硬件存在类型。
5. `.ccr` 不依赖 `.coi`。删除全部 `.coi` 后，`.ccr` 仍可加载、验证、投影和执行。
6. `.coi` 是非权威优化知识；它不能补语义、不能补布局、不能决定正确性。
7. target model / DataLayout 是编码输入，不是 `.ccr` 的字段。
8. 文件格式自身的固定字段宽度、段表偏移和 little-endian 编码属于 wire format，不是程序字宽。

## 3. 文件结构

`.ccr` 是 little-endian wire format。下面字段只描述 **wire 角色**；宽度是文件格式契约，不是语言类型、不是目标字宽。

Wire 角色表：

```text
角色      宽度   编码
count     4B     无符号
kind      4B     无符号
opcode    4B     无符号
flags     4B     无符号
offset    4B     无符号
size      4B     无符号
version   4B     无符号
id        4B     有符号，-1 保留为无值/无效
imm       8B     有符号
word      8B     有符号
```

```text
Header 16B
  magic      4B = 0x31524343   // "CCR1"
  version    version = 0x000A0000
  seg_count  count = 9
  flags      flags              // 仅程序特性，见 3.1

Segment table 9 × 12B
  tag     kind
  offset  offset   相对文件头
  size    size

Segments（canonical file order）
  1 STR
  2 TYPE
  3 IFACE
  4 SYM
  5 NOD
  6 ENT
  7 REG
  8 EDG
  9 CASE
```

段表按 tag 升序，段体连续。加载器检查：

- magic/version 精确匹配；
- `seg_count == 9`；
- 段表 offset/size 在文件内，段体不重叠；
- 段体没有未消费尾随字节；
- 未知、缺失或重复段拒绝。

### 3.1 Header flags

```text
bit 0  PORTABLE   无 raw/FFI/外部 ABI 的程序
bit 1  SYSTEM     含 unsafe/runtime/ABI 边界的程序
bit 2  CONCURRENT 含并发/执行策略节点
bit 3+ 保留，必须为 0
```

flags 不携带 target 身份、字宽、字节序或 ABI。一个 `SYSTEM` 程序仍可以是格形态，但不承诺跨目标运行。

### 3.2 流式读取契约

v10 的 canonical file order 是为顺序读取设计的：

```text
STR -> TYPE -> IFACE -> SYM -> NOD -> ENT -> REG -> EDG -> CASE
```

依赖方向：

- STR 只被所有段引用；
- TYPE 在 IFACE/SYM/NOD 前，类型域先就绪；
- IFACE 在 SYM 前；
- SYM 在 NOD 前，函数/全局/结构声明先就绪；
- NOD 在 ENT/REG/EDG/CASE 前，图坐标先就绪；
- ENT 在 REG 前，区域条目范围可校验；
- EDG 在 NOD 后，边可校验；
- CASE 最后，目标 NOD 已全部可见。

读取器可以：

1. 先读 16B header 和 9×12B 段表；
2. 校验 magic/version/seg_count、offset/size 连续、无重叠；
3. 按 canonical order 顺序消费段体；
4. 对固定记录段直接流式解析；
5. 对变长段按 count + length 前缀读取；
6. NOD 控制目标、CASE 目标等前向引用在 NOD/CASE 读完后再解析，不要求文件后向 seek；
7. 语义表可以继续驻留内存；流式指输入路径，不承诺零内存执行。

写入器可以为了填写段表先计算各段大小，或使用可 seek 输出；**读取器不得依赖后向 seek**。

随机访问模式仍可用段表 offset/size 直接定位；它和流式模式必须产生相同语义。

### 3.3 分发 bundle

标准分发单位是 `.ccrb`：

```text
.ccrb = Zstandard frame(deterministic tar)
  manifest
  program.ccr
  coi/<target>.coi   (0..N，可选)
```

- zstd 流式解压；tar 条目按固定顺序、固定元数据；
- manifest 只含 bundle/版本/raw `.ccr` 身份/`.coi` 目标和哈希；
- `.ccr` 保持 raw、固定 wire、目标无关；
- `.coi` 可选、可删、可重算；
- 解压后的 raw `.ccr` 用 3.2 的流式读取契约；
- `corearch` 不要求实现 zstd；由分发/安装层解包。

## 4. NOD：图事件

```text
nod_count count
nod_count × 40B
  op          opcode
  dest        id
  src1        imm
  src2        id
  src3        id
  type_id     id
  flags       flags
  first_edge  count
  edge_count  count
```

规则：

- `dest` 是值条目的产生变量，`-1` 表示无产生值。
- `src1` 是源变量、条目、路径、符号或立即数；由 `op` 决定。
- `src2`/`src3` 是操作辅助索引；**不得表示宽度、字节偏移、步长或对齐**。
- `type_id` 是 TYPE 段的行索引，表示该节点的语义域；`-1` 表示无类型/不适用。TYPE 项表只服务 IFACE 签名，不进入 NOD 的常规域选择。
- `flags` 是节点特性，不是目标事实。
- 出边在 EDG 段连续；节点 i+1 的 `first_edge` 等于节点 i 的 `first_edge` 加 `edge_count`。

### 4.1 操作类别

操作名称是本规格的语义权威。数值 opcode 由实现侧的 v10 opcode 表分配；分配规则：

- 每个名称唯一；
- 旧 v9 数值只有在字段语义完全一致时才可复用；
- 任何旧槽语义、宽度或编码选择 opcode 不得复用；
- 加载器按 v10 表解释，不按 v9 表猜测。

数值/计算：

```text
CONST        dest, src1=值或 STR 索引, type_id
UNARY        dest, src1, src3=op, type_id
BINARY       dest, src1, src2, src3=op, type_id
CALL         dest, src1=首实参, src2=实参数, src3=符号, type_id=返回域
RETURN       src1=值
```

存在/位置：

```text
STORE        dest=-1, src1=目标条目/路径, src2=值, type_id=值域
LOAD         dest, src1=源条目/路径, type_id=读取域
ALLOC        dest, src1=数量或 0, type_id=分配域
ALLOC_ARRAY  dest, src1=元素数量, type_id=元素域
ALLOC_STRUCT dest, type_id=结构域
FIELD        dest, src1=基条目/路径, src3=字段号, type_id=字段域
INDEX        dest, src1=基条目/路径, src2=索引, type_id=元素域
STORE_FIELD  src1=基条目, src2=值, src3=字段号, type_id=值域
STORE_INDEX  src1=基条目, src2=索引, src3=值, type_id=值域
DEREF        dest, src1=指针/引用, type_id=指向域
STORE_PTR    src1=指针/引用, src2=值, type_id=值域
SLICE        dest, src1=基条目, src2=低, src3=高, type_id=切片域
BOUNDS_CHECK src1=索引, src2=数量, type_id=元素域
```

控制/关系：

```text
BRANCH       src1=条件, src2=真目标, src3=假目标
JUMP         src1=目标
LABEL        src1=标签号
MATCH        src1=scrutinee, src2=CASE 表索引, type_id=结果域
```

枚举/动态：

```text
MAKE_ENUM       dest, src1=变体符号, src2=字段数, type_id=枚举域
LOAD_ENUM_TAG   dest, src1=枚举值, type_id=标签域
DYN_TAG         dest, src1=动态值
DYN_VAL         dest, src1=动态值, type_id=目标域
DYN_PACK        dest, src1=值, src2=域
DYN_DISPATCH    dest, src1=接收者, src2=方法符号, type_id=返回域
```

执行/系统边界：

```text
ARENA_NEW    dest, type_id=unit     // 容量/实现由 runtime 决定
ARENA_RESET  src1=arena
SPAWN        dest, src1=首实参, src2=实参数, src3=函数符号, type_id=返回域
YIELD        src1=值
AWAIT        dest, src1=值, type_id=结果域
HOTPATCH     dest, src1=首实参, src2=实参数, src3=符号, type_id=返回域
FNADDR       dest, src1=函数符号, type_id=地址域
CALL_EXTERN  dest, src1=首实参, src2=实参数, src3=外部符号, type_id=返回域
INLINE       src1=函数符号
PTR_OF       dest, src1=字符串, type_id=地址域
STR_OF       dest, src1=地址, type_id=字符串域
```

执行/系统边界节点要求文件的 `SYSTEM` 标志置 1；它们不承诺跨目标可运行。`PTR_OF`/`STR_OF`/`CALL_EXTERN`/`HOTPATCH`/`ARENA_*` 不得出现在纯 `PORTABLE` 程序中。

## 5. ENT：存在主干

```text
ent_count count
ent_count × 24B
  var_id     id
  version    version
  def_nod    id
  live_start count
  live_end   count
  flags      flags
```

- `var_id` 是变量/条目身份；同一变量的不同版本各占一条。
- `version` 从 1 开始，每次 `STORE` 推进。
- `def_nod` 是产生该版本的 NOD id；参数和全局为 `-1`。
- `live_start` 包含，`live_end` 不包含，坐标是 NOD id。
- `flags`：
  ```text
  bit 0 无生成方法
  bit 1 参数
  bit 2 全局
  bit 3 移除候选
  bit 4+ 保留，必须为 0
  ```

`home` 不再出现在 `.ccr`。寄存器、栈槽、home、分配结果、物理位置属于 `.coi` 或实例侧。需要无生成方法条目的持久绑定时，由 `.coi` 提供候选；`.ccr` 本身只保留存在事实。

`STORE` 是 ENT 版本推进的唯一规范点；`STORE_FIELD`、`STORE_INDEX`、`STORE_PTR` 是路径投影，不改变 `var_id` 的存在身份。具体版本选择由数据边和 ENT 区间决定。

## 6. REG：区域

```text
reg_count count
reg_count × 24B
  kind       kind   // func/loop/if/flow/unsafe 等语义种类
  parent     id
  enter_nod  count
  exit_nod   count
  first_ent  count
  last_ent   count
```

区域坐标是 NOD id；`first_ent/last_ent` 是 ENT 半开索引。区域表达图绑定、存在范围和共存约束，不表达栈帧、字节范围或寄存器。

## 7. EDG：边

```text
edg_count count
edg_count × 8B
  to_nod  count
  kind    kind
```

- `kind 0`：数据边，def-use 值流。
- `kind 1`：state 边，副作用顺序。
- `kind 2+`：保留；v10 不定义语义时拒绝或跳过策略必须由版本级规则固定。

`from` 由所属 NOD 的 `first_edge/edge_count` 隐含。数据边和 state 边都是前向边；循环由 REG 和 state 链表达，不用后向边。

加载器验证：

- 边所属节点小于 `to_nod`；
- `edg_count` 等于所有 `edge_count` 之和；
- 文件序是合法拓扑调度；否则拒绝。

## 8. STR / SYM

### 8.1 STR：字符串表

```text
str_count count
str_count × {len count, data[len]}
```

字符串只保存源码标识、符号名和规范化字面量；不保存目标内存布局或指针宽度。

### 8.2 SYM：符号与声明

SYM 保存函数、全局、结构体、枚举和外部符号。函数保存参数域和返回域；结构体保存字段名和字段域；全局保存名称和域。SYM 不保存：

- 参数栈序、寄存器分配、调用约定；
- 字段字节偏移、结构体 size/align；
- 全局地址、段选择、重定位。

## 9. TYPE：语义域

TYPE 保留现有两小节结构，但语义改为“域约束”，不存机器布局：

```text
row_count count
row_count × 24B {kind word, data word, extra word}

term_count count
term_count × 40B {tag kind, a word, b word, c word, d word}
```

- 不存 size、align、offset、stride、endian。
- `TYP_ARRAY` 的 `extra` 是元素数量，不是字节长度。
- `TYP_PTR`/`TYP_REF` 只存指向域，不存指针宽度。
- `TYP_OPTIONAL` 只存内层域，不存 tag 字节布局。
- `TYP_NAMED` 的结构字段在 SYM 段；字段没有字节偏移。
- `TYP_FN` 只有参数/返回域，不存 ABI。

未来 target 可以没有“类型”这个概念；它在验证后可按自己的原生域擦除或动态表示 TYPE 约束。`corearch` 不得把 TYPE 行直接当机器类型尺寸使用。

## 10. IFACE：接口

保持五小节结构，但只保存语义接口：

- 原生条目、形状、接口、impl、方法表；
- `ret_term`/`param_terms` 是 TYPE 项引用；
- 不存调用约定、寄存器分配、参数栈序、返回寄存器。

## 11. CASE：match 关系

```text
case_count count
case_count × 24B
  value       imm
  kind        kind   // 值/枚举/字符串/默认等语义种类
  str_index   id
  target_nod  id
  flags       flags
```

CASE 只表达 scrutinee 域到目标节点的关系。跳转表、比较指令、二分形态和 case 排序属于 corearch 投影，不进入 `.ccr`。

## 12. 文件序与投影

1. NOD 文件序是生产者选择的合法拓扑调度，沿 EDG 前向边约束。
2. 加载器可以重建图语义；后端可以按不同 target 重新调度。
3. `NOD id` 是图坐标。ENT 区间、REG 边界、CASE 目标都使用 NOD id。
4. 文件序不是程序顺序，不是执行顺序，不是语义主干。
5. 同源程序的不同合法调度必须产生等价的存在格；后端可以选择不同投影。

## 13. 消费与编码

```text
corec:   HDFG / 关系图 -> 重建 ENT -> 拓扑投影 -> .ccr
corearch: 加载 .ccr -> 重建图/存在格 -> target model -> HIT 事件 -> 编码
interp:  加载 .ccr -> 使用自己的运行时值表示执行
.coi:    可选优化知识 -> 候选 -> 后端独立验证
```

HIT 最小核仍是编码层契约：

```text
sub / nand / load / store
```

它们没有位宽、寄存器、寻址。宽度、寄存器、寻址、ABI、字节序属于 HIT 投影、target model 或 runtime。`.ccr` 不复制 HIT 事件，也不把 HIT 事件当格语义。

## 14. `.coi` 边界

`.ccr` 的字段、段、加载检查和验证不读取 `.coi`。

`.coi` 可以保存：

- 寄存器分配候选；
- 栈/home 候选；
- CSE、布局偏好、向量宽度、调度候选；
- target-specific 优化知识；
- 从 `.cir`/`.ccr` 重算的索引和代价。

`.coi` 不能保存：

- 语义事实；
- 必需的布局；
- 程序正确性条件；
- 目标模型/硬件能力本身；
- 机器码。

删除 `.coi` 只允许增加编译成本或降低优化质量；不得改变 `.ccr` 的语义。

## 15. 验证规则

1. Header、段表、段体边界和版本必须精确。
2. NOD 的 `type_id` 在 TYPE 范围内；`src*` 按 op 的字段约定验证。
3. NOD 的 `src2/src3` 不得被解释为字节宽度；遇到旧版宽度语义按损坏拒绝。
4. ENT 的 `var_id/def_nod/live_start/live_end/flags` 自洽；区间不越 NOD 界。
5. REG 的 parent/enter/exit/entry 范围自洽；区域嵌套无环。
6. EDG 前向、邻接连续、计数守恒。
7. TYPE/IFACE 行表和项表自洽；跨段引用在界内。
8. CASE 目标和值域引用自洽。
9. `PORTABLE` 程序不得含 `SYSTEM` 节点或 raw/FFI/ABI 边界。
10. `.ccr` 加载不读取 `.coi`；`.coi` 缺失不改变 `.ccr` 结构。

## 16. 版本与迁移

- `.ccr` v10.0；v9.x 整类拒收。
- `.cir` 缓存版本随格语义/操作码迁移 bump。
- 实现迁移顺序：
  1. 先落 v10 读写器和图重建检查；
  2. 再改 `ccr_lower`/`ir_gen`，去掉 `mp_*`；
  3. 再改 corearch 的 target layout/HIT 投影；
  4. 再删普通语言 API 的 `w64/r64`；
  5. 最后处理 `.coi` 候选和 canary 重锁。
- 不允许在 v10 中同时保留 v9 槽语义作为隐式后备。

## 17. 判定问句

任何新增字段或操作先回答：

1. 换目标机时，这个字段的语义会变吗？会变，属于 target model/`.coi`，不进入 `.ccr`。
2. 这个字段是否让位置变成字节地址？是，拒绝。
3. 这个操作是否依赖固定字宽、对齐、字节序或 ABI？是，放编码层或 `SYSTEM` 边界。
4. 删除它是否会改变可观测语义？会，属于 `.ccr`；不会但会变慢，属于 `.coi`。
5. 它是否参与存在/版本/区域/边？是，属于 ENT/REG/EDG/NOD 的格语义。

## 18. 关联

- 格形态语义：`docs/superpowers/specs/2026-09-09-lattice-ir-v7-carrier-design.md`
- 格层边界：`docs/superpowers/specs/2026-09-09-lattice-encoding-boundary-design.md`
- 字节格式前身：`docs/superpowers/specs/2026-09-09-lattice-ir-v7-format.md`
- IR schema：`docs/ir-schema/coreir-schema.md`
- HIT：`docs/superpowers/specs/2026-09-05-hardware-interface-table.md`
- `.coi`：`docs/maintainer/design/coi-optimization-knowledge-sidecar.md`
