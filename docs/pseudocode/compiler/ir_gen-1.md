# ir_gen.cr 伪代码（第 1 部分：基础设施与辅助函数）
> 源文件：src/compiler/ir_gen.cr（第 1–226 行）
> 功能概要：定义子图（SG）竞技场跟踪所需全局变量及辅助函数，以及 IR 变量创建、指令发射（emit）、标签生成、局部/全局变量查找、作用域管理、类型判断（指针/字节缓冲）、调用返回类型查询、字符串常量跟踪等底层基础设施函数。

## 标识符对照表

| 中文名 | 原名 | 首次出现函数 |
|--------|------|-------------|
| SG 分配槽总数 | g_sg_alloc_total | （全局状态） |
| SG 分配槽容量 | g_sg_alloc_cap | （全局状态） |
| SG 竞技场变量数组 | g_sg_arena_var | （全局状态） |
| SG 竞技场变量数组容量 | g_sg_arena_var_cap | （全局状态） |
| IR 源文件哈希 | g_ir_source_hash | （全局状态） |
| IR 源文件哈希就绪标记 | g_ir_source_hash_ready | （全局状态） |
| IR 变量总数 | g_ir_var_count | 新建 IR 变量（new_ir_var） |
| IR 指令总数 | g_ir_instr_count | 发射指令（emit） |
| IR 函数个数 | g_ir_func_count | （全局状态） |
| 下一个标签号 | g_next_label | 新建标签（new_label） |
| IR 局部变量数组 | g_ir_locals | 绑定局部变量（bind_local） |
| IR 局部变量计数 | g_ir_local_count | 绑定局部变量（bind_local） |
| IR 全局变量数组 | g_ir_globals | 查找全局变量（find_global） |
| IR 全局变量计数 | g_ir_global_count | 查找全局变量（find_global） |
| 全局声明数组 | g_global_lets | 查找全局常量节点（find_global_const_node） |
| 全局声明计数 | g_global_let_count | 查找全局常量节点（find_global_const_node） |
| IR 局部变量作用域深度 | g_ir_local_depth | 压入 IR 作用域（push_ir_scope） |
| IR 局部作用域栈 | g_ir_local_scopes | 压入 IR 作用域（push_ir_scope） |
| 变量生产者节点映射 | g_df_var_producer | 判断指针变量（is_ptr_var） |
| 数据流节点数组 | g_df_nodes | 判断指针变量（is_ptr_var） |
| 运行时内建函数名数组 | g_rt_builtin_names | IR 调用返回类型（ir_call_return_type） |
| 运行时内建函数返回类型数组 | g_rt_builtin_ret_types | IR 调用返回类型（ir_call_return_type） |
| 运行时内建函数计数 | g_rt_builtin_count | IR 调用返回类型（ir_call_return_type） |
| 类型计数 | g_type_count | 类型大小（type_size） |
| IR 字符串常量数组 | g_ir_str_consts | 追踪字符串常量（track_str） |
| IR 字符串常量计数 | g_ir_str_const_count | 追踪字符串常量（track_str） |
| 结构图计数 | g_sg_count | 压入 SG 分配槽（sg_alloc_push） |
| 结构体计数 | g_struct_count | （全局状态） |
| 扩展 SG 分配数组 | grow_sg_alloc | 扩展 SG 分配数组（grow_sg_alloc） |
| 扩展 SG 竞技场变量数组 | grow_sg_arena_var | 扩展 SG 竞技场变量数组（grow_sg_arena_var） |
| 压入 SG 分配槽 | sg_alloc_push | 压入 SG 分配槽（sg_alloc_push） |
| 弹出 SG 分配槽 | sg_alloc_pop | 弹出 SG 分配槽（sg_alloc_pop） |
| 追踪分配大小 | track_alloc_size | 追踪分配大小（track_alloc_size） |
| 新建 IR 变量 | new_ir_var | 新建 IR 变量（new_ir_var） |
| 发射指令 | emit | 发射指令（emit） |
| 新建标签 | new_label | 新建标签（new_label） |
| 绑定局部变量 | bind_local | 绑定局部变量（bind_local） |
| 查找局部变量 | find_local | 查找局部变量（find_local） |
| 查找全局变量 | find_global | 查找全局变量（find_global） |
| 查找全局常量节点 | find_global_const_node | 查找全局常量节点（find_global_const_node） |
| 压入 IR 作用域 | push_ir_scope | 压入 IR 作用域（push_ir_scope） |
| 弹出 IR 作用域 | pop_ir_scope | 弹出 IR 作用域（pop_ir_scope） |
| 判断指针变量 | is_ptr_var | 判断指针变量（is_ptr_var） |
| 判断字节缓冲变量 | is_byte_buf_var | 判断字节缓冲变量（is_byte_buf_var） |
| IR 调用返回类型 | ir_call_return_type | IR 调用返回类型（ir_call_return_type） |
| 获取 IR 变量名 | get_ir_var_name | 获取 IR 变量名（get_ir_var_name） |
| 追踪字符串常量 | track_str | 追踪字符串常量（track_str） |
| HDFG：创建节点 | df_create_node | 发射指令（emit） |
| IR 变量访问器：ID | irv_id | 新建 IR 变量（new_ir_var） |
| IR 变量访问器：名称 | irv_name | 新建 IR 变量（new_ir_var） |
| IR 变量访问器：类型 | irv_type | 新建 IR 变量（new_ir_var） |
| IR 变量访问器：设置名称 | irv_set_name | 新建 IR 变量（new_ir_var） |
| IR 变量访问器：设置ID | irv_set_id | 新建 IR 变量（new_ir_var） |
| IR 变量访问器：设置类型 | irv_set_type | 新建 IR 变量（new_ir_var） |
| IR 指令访问器：操作码 | iri_op | 发射指令（emit） |
| IR 指令访问器：操作数1 | iri_s1 | 发射指令（emit） |
| IR 指令访问器：操作数2 | iri_s2 | 发射指令（emit） |
| IR 指令访问器：操作数3 | iri_s3 | 发射指令（emit） |
| IR 指令访问器：目标 | iri_dest | 发射指令（emit） |
| IR 指令访问器：类型类别 | iri_tk | 发射指令（emit） |
| IR 指令访问器：设置操作码 | iri_set_op | 发射指令（emit） |
| IR 指令访问器：设置目标 | iri_set_dest | 发射指令（emit） |
| IR 指令访问器：设置操作数1 | iri_set_s1 | 发射指令（emit） |
| IR 指令访问器：设置操作数2 | iri_set_s2 | 发射指令（emit） |
| IR 指令访问器：设置操作数3 | iri_set_s3 | 发射指令（emit） |
| IR 指令访问器：设置类型类别 | iri_set_tk | 发射指令（emit） |
| 压入结构图 | sg_push | 压入 SG 分配槽（sg_alloc_push） |
| 弹出结构图 | sg_pop | 弹出 SG 分配槽（sg_alloc_pop） |
| 第一子节点访问器 | ast_a | 查找全局常量节点（find_global_const_node） |
| 第二子节点访问器 | ast_b | 查找全局常量节点（find_global_const_node） |
| 第三子节点访问器 | ast_c | 查找全局常量节点（find_global_const_node） |
| AST 访问器：数据 | ast_data | 查找全局常量节点（find_global_const_node） |
| AST 访问器：类别 | ast_kind | 查找全局常量节点（find_global_const_node） |
| AST 访问器：整数值 | ast_int_val | 查找全局常量节点（find_global_const_node） |
| 扩展 IR 变量数组 | grow_ir_vars | 新建 IR 变量（new_ir_var） |
| 扩展 IR 指令数组 | grow_ir_instrs | 发射指令（emit） |
| 扩展 IR 局部变量数组 | grow_ir_locals | 绑定局部变量（bind_local） |
| 扩展 IR 局部作用域数组 | grow_ir_local_scopes | 压入 IR 作用域（push_ir_scope） |
| 扩展 IR 字符串常量数组 | grow_ir_str_consts | 追踪字符串常量（track_str） |
| 查找函数 | find_func | IR 调用返回类型（ir_call_return_type） |
| 查找泛型符号 | find_gsym | IR 调用返回类型（ir_call_return_type） |
| 符号类别 | sym_kind | IR 调用返回类型（ir_call_return_type） |
| 符号类型 | sym_type | IR 调用返回类型（ir_call_return_type） |
| 符号节点 | sym_node | IR 调用返回类型（ir_call_return_type） |
| 函数信息访问器：返回类型 | fi_return_type | IR 调用返回类型（ir_call_return_type） |
| 驻留字符串获取 | istr_get | IR 调用返回类型（ir_call_return_type） |
| 字符串驻留 | str_intern | 新建 IR 变量（new_ir_var） |
| 读 64 位 | r64 | 判断指针变量（is_ptr_var） |
| 写 64 位 | w64 | 绑定局部变量（bind_local） |
| 内部：动态拷贝 | _dyncpy | 扩展 SG 分配数组（grow_sg_alloc） |
| 分配内存 | alloc | 扩展 SG 分配数组（grow_sg_alloc） |
| 字符串长度 | str_len | 追踪分配大小（track_alloc_size） |
| 字符串相等比较 | str_eq | IR 调用返回类型（ir_call_return_type） |
| 竞技场重置指令 | IR_ARENA_RESET | 弹出 SG 分配槽（sg_alloc_pop） |
| 内建分配指令 | IR_ALLOC | 判断指针变量（is_ptr_var） |
| 地址索引指令 | IR_ADDR_INDEX | 判断指针变量（is_ptr_var） |
| 引用指令 | IR_REF | 判断指针变量（is_ptr_var） |
| 内建分配结构体指令 | IR_ALLOC_STRUCT | 判断指针变量（is_ptr_var） |
| 内建分配数组指令 | IR_ALLOC_ARRAY | 判断指针变量（is_ptr_var） |
| 函数子图类型 | SG_FUNC | 追踪分配大小（track_alloc_size） |
| 循环子图类型 | SG_LOOP | 追踪分配大小（track_alloc_size） |
| 遍历子图类型 | SG_FOR | 追踪分配大小（track_alloc_size） |
| 标签指令 | IR_LABEL | 新建标签（new_label） |
| 跳转指令 | IR_JUMP | 新建标签（new_label） |
| 条件分支指令 | IR_BRANCH | 新建标签（new_label） |
| 函数符号类型 | SYM_FN | IR 调用返回类型（ir_call_return_type） |
| 共享库函数符号类型 | SYM_SO_FN | IR 调用返回类型（ir_call_return_type） |

| 整数类型 | TY_INT | IR 调用返回类型（ir_call_return_type） |
| 字符串字面量类型值 | TY_STRING | IR 调用返回类型（ir_call_return_type） |
| 浮点字面量类型值 | TY_FLOAT | IR 调用返回类型（ir_call_return_type） |
| 布尔字面量类型值 | TY_BOOL | IR 调用返回类型（ir_call_return_type） |
| 单元类型 | TY_UNIT | IR 调用返回类型（ir_call_return_type） |
| 字符字面量类型值 | TY_CHAR | IR 调用返回类型（ir_call_return_type） |

| 单元类型信息 | TI_UNIT | IR 调用返回类型（ir_call_return_type） |
| 整数类型索引 | TI_INT | IR 调用返回类型（ir_call_return_type） |
| 浮点类型索引 | TI_FLOAT | IR 调用返回类型（ir_call_return_type） |
| 布尔类型索引 | TI_BOOL | IR 调用返回类型（ir_call_return_type） |
| 字符串类型索引 | TI_STR | IR 调用返回类型（ir_call_return_type） |
| 字符类型索引 | TI_CHAR | IR 调用返回类型（ir_call_return_type） |

| 整数字面量表达式类型 | EXPR_INT | 查找全局常量节点（find_global_const_node） |
| 布尔字面量表达式类型 | EXPR_BOOL | 查找全局常量节点（find_global_const_node） |

## 全局状态

| 变量名 | 说明 | 初始值 |
|--------|------|--------|
| SG 分配槽总数（g_sg_alloc_total） | 每子图累积分配大小（字节数组），每项 8 字节 | 空字符串（动态分配） |
| SG 分配槽容量（g_sg_alloc_cap） | SG 分配槽总数数组容量（项数） | 0 |
| SG 竞技场变量数组（g_sg_arena_var） | 每子图对应的竞技场 IR 变量（8 字节/项） | 空字符串（动态分配） |
| SG 竞技场变量数组容量（g_sg_arena_var_cap） | SG 竞技场变量数组数组容量（项数） | 0 |
| IR 源文件哈希（g_ir_source_hash） | 源码全文哈希值（用于缓存命中检测） | 0 |
| IR 源文件哈希就绪标记（g_ir_source_hash_ready） | 哈希是否已计算的标记 | 0 |

## 函数 扩展 SG 分配数组（grow_sg_alloc）

### 作用
动态扩展 SG 分配槽总数（g_sg_alloc_total）数组的容量。当需要的项数超出当前容量时，分配更大的缓冲区并拷贝旧数据。

### 逻辑
接收 所需项数（needed）：整数
如果 所需项数 小于 SG 分配槽容量（g_sg_alloc_cap），那么：
    返回（无需扩展）

令 新容量 = SG 分配槽容量 * 2
如果 新容量 小于 64，那么：
    令 新容量 = 64
如果 新容量 小于 所需项数，那么：
    令 新容量 = 所需项数 + 64

令 新缓冲区 = 分配内存（alloc）（新容量 * 8）
内部：动态拷贝（_dyncpy）（SG 分配槽总数, SG 分配槽容量 * 8, 新缓冲区）
令 SG 分配槽总数 = 新缓冲区
令 SG 分配槽容量 = 新容量

### 测试要点
1. 所需项数 小于当前容量时，函数立即返回，数组不变
2. 容量翻倍后仍不够时，以 所需项数 + 64 作为新容量
3. 初始容量为 0 时，翻倍得 0，小于 64 故新容量为 64
4. 旧数据被完整拷贝到新缓冲区

---

## 函数 扩展 SG 竞技场变量数组（grow_sg_arena_var）

### 作用
动态扩展 SG 竞技场变量数组（g_sg_arena_var）数组容量，逻辑与 扩展 SG 分配数组（grow_sg_alloc）完全对称。

### 逻辑
接收 所需项数（needed）：整数
如果 所需项数 小于 SG 竞技场变量数组容量（g_sg_arena_var_cap），那么：
    返回

令 新容量 = SG 竞技场变量数组容量 * 2
如果 新容量 小于 64，那么：
    令 新容量 = 64
如果 新容量 小于 所需项数，那么：
    令 新容量 = 所需项数 + 64

令 新缓冲区 = 分配内存（alloc）（新容量 * 8）
内部：动态拷贝（_dyncpy）（SG 竞技场变量数组, SG 竞技场变量数组容量 * 8, 新缓冲区）
令 SG 竞技场变量数组 = 新缓冲区
令 SG 竞技场变量数组容量 = 新容量

### 测试要点
1. 已满足需求时不执行任何操作
2. 容量翻倍、下限 64、按需补 64 逻辑与 扩展 SG 分配数组（grow_sg_alloc）一致
3. 旧数据被完整拷贝

---

## 函数 压入 SG 分配槽（sg_alloc_push）

### 作用
在进入一个新的子图（SG）区域时调用。扩展两个跟踪数组并压入初始值为 0 的新项，然后调用 压入结构图（sg_push）创建子图节点。

### 逻辑
接收 子图类别（kind）：整数
扩展 SG 分配数组（grow_sg_alloc）（结构图计数（g_sg_count） + 1）
扩展 SG 竞技场变量数组（grow_sg_arena_var）（结构图计数 + 1）
在 SG 分配槽总数 中偏移（结构图计数 * 8）处写入 64 位值 0
压入结构图（sg_push）（子图类别）

### 测试要点
1. 新项的分配总量被初始化为 0
2. 同时扩展两个数组，确保容量足够
3. 之后调用 压入结构图（sg_push）创建数据流子图节点

---

## 函数 弹出 SG 分配槽（sg_alloc_pop）

### 作用
离开当前子图区域时调用。读取当前子图的累计分配总量和竞技场变量，弹出子图节点，并发射竞技场重置指令。

### 逻辑
令 累计分配总量 = 从 SG 分配槽总数 偏移（（结构图计数 - 1） * 8）处读取 64 位
令 竞技场变量 = 从 SG 竞技场变量数组 偏移（（结构图计数 - 1） * 8）处读取 64 位
弹出结构图（sg_pop）（）
发射指令（emit）（竞技场重置指令（IR_ARENA_RESET）, -1, 竞技场变量, 0, 0, 0）

### 测试要点
1. 从SG 分配槽总数 和 SG 竞技场变量数组 中读取当前子图的数据
2. 发射 竞技场重置指令 重置竞技场
3. 调用顺序为先读数据、再弹出 SG、最后发射重置指令

---

## 函数 追踪分配大小（track_alloc_size）

### 作用
在 IR 生成过程中遇到分配操作时调用，将分配大小累加到当前子图的分配总量中，用于编译期大小估算。

### 逻辑
接收 分配大小（size）：整数
如果 结构图计数（g_sg_count） 大于 0 且 SG 分配槽总数的字节长度（通过 str_len 取得） 大于 0，那么：
    令 之前累计 = 从 SG 分配槽总数 偏移（（结构图计数 - 1） * 8）处读取 64 位
    在 SG 分配槽总数 偏移（（结构图计数 - 1） * 8）处写入 64 位值：之前累计 + 分配大小

### 测试要点
1. 在 函数子图类型（SG_FUNC）或 循环子图类型（SG_LOOP）/遍历子图类型（SG_FOR）区域外调用时不执行任何操作（结构图计数 小于等于 0）
2. SG 分配槽总数 为空字符串时不操作
3. 正确累加多次分配的字节数

---

## 函数 新建 IR 变量（new_ir_var）

### 作用
创建新的 IR 变量，分配唯一的变量索引，设置名称（驻留字符串索引）和类型索引，返回变量索引。

### 逻辑
接收 变量名（name）：字符串，类型索引（type_idx）：整数
令 索引 = IR 变量总数（g_ir_var_count）
扩展 IR 变量数组（grow_ir_vars）（索引 + 1）
IR 变量访问器：设置名称（irv_set_name）（索引, 字符串驻留（str_intern）（变量名））
IR 变量访问器：设置ID（irv_set_id）（索引, 索引）
IR 变量访问器：设置类型（irv_set_type）（索引, 类型索引）
令 IR 变量总数 = 索引 + 1
返回 索引

### 测试要点
1. 索引从当前 IR 变量总数 开始，创建后全局计数加一
2. 变量名通过 字符串驻留（str_intern）转为驻留索引存储
3. 变量 ID 等于其索引
4. 数组空间不足时 扩展 IR 变量数组 自动扩容

---

## 函数 发射指令（emit）

### 作用
向线性 IR（ccr）指令数组追加一条新指令，同时同步调用 HDFG：创建节点（df_create_node）构建并行 HDFG（cir）节点。这是 IR 生成的唯一指令出口。

### 逻辑
接收 操作码（opcode）：整数，目标变量（dest）：整数，源操作数一（src1）：整数，源操作数二（src2）：整数，源操作数三（src3）：整数，类型类别（type_kind）：整数
令 索引 = IR 指令总数（g_ir_instr_count）
扩展 IR 指令数组（grow_ir_instrs）（索引 + 1）
IR 指令访问器：设置操作码（iri_set_op）（索引, 操作码）
IR 指令访问器：设置目标（iri_set_dest）（索引, 目标变量）
IR 指令访问器：设置操作数1（iri_set_s1）（索引, 源操作数一）
IR 指令访问器：设置操作数2（iri_set_s2）（索引, 源操作数二）
IR 指令访问器：设置操作数3（iri_set_s3）（索引, 源操作数三）
IR 指令访问器：设置类型类别（iri_set_tk）（索引, 类型类别）
令 IR 指令总数 = 索引 + 1
（同步构建 HDFG）
HDFG：创建节点（df_create_node）（操作码, 目标变量, 源操作数一, 源操作数二, 源操作数三, 类型类别）

### 测试要点
1. 每条指令在 .线性指令流（ccr）（线性 IR 格式）和 HDFG格式（cir）中同时创建，保持同步
2. 指令索引由全局计数器 IR 指令总数 分配
3. 所有六个字段（操作码、目标、三个源操作数、类型类别）均写入

---

## 函数 新建标签（new_label）

### 作用
生成唯一的跳转标签编号，用于 IR 中的 标签指令（IR_LABEL）和 跳转指令（IR_JUMP）/条件分支指令（IR_BRANCH）指令。

### 逻辑
令 标签号 = 下一个标签号（g_next_label）
令 下一个标签号 = 下一个标签号 + 1
返回 标签号

### 测试要点
1. 每次调用返回递增的整数，从初始值 1 开始
2. 返回值用于后续 标签指令 指令的源操作数

---

## 函数 绑定局部变量（bind_local）

### 作用
将变量名（驻留字符串索引）与 IR 变量索引关联，存入 IR 局部变量数组（g_ir_locals）。查找时从后往前扫描，因此最近绑定的优先级最高（作用域遮蔽）。

### 逻辑
接收 名字索引（name_idx）：整数，变量索引（var_idx）：整数
扩展 IR 局部变量数组（grow_ir_locals）（IR 局部变量计数（g_ir_local_count） + 1）
在 IR 局部变量数组 偏移（IR 局部变量计数 * 16）处写入 64 位值：名字索引
在 IR 局部变量数组 偏移（IR 局部变量计数 * 16 + 8）处写入 64 位值：变量索引
令 IR 局部变量计数 = IR 局部变量计数 + 1

### 测试要点
1. 每条局部绑定占 16 字节：前 8 字节为名字索引，后 8 字节为变量索引
2. 多次绑定同一名字时，新绑定追加在末尾，查找时优先命中

---

## 函数 查找局部变量（find_local）

### 作用
从 IR 局部变量数组 中查找给定名字索引对应的 IR 变量索引。从后往前扫描，实现最近绑定优先的作用域遮蔽语义。

### 逻辑
接收 名字索引（name_idx）：整数
令 扫描位置 = IR 局部变量计数（g_ir_local_count） - 1
循环：
    如果 扫描位置 小于 0，那么：
        返回 -1
    如果 从 IR 局部变量数组 偏移（扫描位置 * 16）处读取的 64 位值 等于 名字索引，那么：
        返回 从 IR 局部变量数组 偏移（扫描位置 * 16 + 8）处读取的 64 位值
    令 扫描位置 = 扫描位置 - 1
返回 -1

### 测试要点
1. 未找到时返回 -1
2. 同一名字多次绑定时返回最近绑定的变量索引
3. 空表（IR 局部变量计数 等于 0）时直接返回 -1

---

## 函数 查找全局变量（find_global）

### 作用
从 IR 全局变量数组（g_ir_globals）中查找给定名字索引对应的 IR 变量索引。扫描逻辑与 查找局部变量（find_local）类似，但每条记录占 24 字节。

### 逻辑
接收 名字索引（name_idx）：整数
令 扫描位置 = IR 全局变量计数（g_ir_global_count） - 1
循环：
    如果 扫描位置 小于 0，那么：
        返回 -1
    如果 从 IR 全局变量数组 偏移（扫描位置 * 24）处读取的 64 位值 等于 名字索引，那么：
        返回 从 IR 全局变量数组 偏移（扫描位置 * 24 + 8）处读取的 64 位值
    令 扫描位置 = 扫描位置 - 1
返回 -1

### 测试要点
1. 未找到时返回 -1
2. 全局 IR 变量每条记录占 24 字节（名字 + 变量索引 + 初始值）
3. 空表时直接返回 -1

---

## 函数 查找全局常量节点（find_global_const_node）

### 作用
查找模块级不可变常量（不可变（immutable）全局声明（let））的编译时常量 AST 节点。仅返回类型为整数（EXPR_INT）或布尔（EXPR_BOOL）的常量值，用于编译期常量折叠。不处理可变变量（mut）和运行时初始化的常量。

### 逻辑
接收 名字索引（name_idx）：整数
令 扫描位置 = 全局声明计数（g_global_let_count） - 1
循环：
    如果 扫描位置 小于 0，那么：
        跳出循环
    令 当前声明节点 = 从 全局声明数组（g_global_lets）偏移（扫描位置 * 8）处读取 64 位
    如果 AST 第一子节点访问器（ast_a）（当前声明节点）等于 名字索引 且 AST 访问器：数据（ast_data）（当前声明节点）等于 0，那么：
        令 值节点 = AST 第三子节点访问器（ast_c）（当前声明节点）
        如果 值节点 大于等于 0，那么：
            令 值类别 = AST 访问器：类别（ast_kind）（值节点）
            如果 值类别 等于 整数字面量表达式类型（EXPR_INT）或 值类别 等于 布尔字面量表达式类型（EXPR_BOOL），那么：
                返回 值节点
    令 扫描位置 = 扫描位置 - 1
返回 -1

### 测试要点
1. 只返回不可变常量（ast_data 等于 0）的整数/布尔初始值
2. 可变变量（mut）或在类型检查阶段被标记为非零数据（data）的声明被跳过
3. 未找到或非编译时常量时返回 -1
4. 空表时返回 -1

---

## 函数 压入 IR 作用域（push_ir_scope）

### 作用
进入新的词法作用域（如函数体、代码块）时调用，记录当前 IR 局部变量计数，以便退出作用域时回滚（pop_ir_scope）。

### 逻辑
扩展 IR 局部作用域数组（grow_ir_local_scopes）（IR 局部变量作用域深度（g_ir_local_depth） + 1）
在 IR 局部作用域栈（g_ir_local_scopes）偏移（IR 局部变量作用域深度 * 8）处写入 64 位值：IR 局部变量计数（g_ir_local_count）
令 IR 局部变量作用域深度 = IR 局部变量作用域深度 + 1

### 测试要点
1. 保存当前 IR 局部变量计数 作为回滚点
2. 作用域深度递增
3. 可在同一深度多次压入/弹出形成嵌套作用域

---

## 函数 弹出 IR 作用域（pop_ir_scope）

### 作用
退出当前词法作用域，将 IR 局部变量计数 恢复到进入该作用域前的值，丢弃该作用域内绑定的所有局部变量。

### 逻辑
令 IR 局部变量作用域深度（g_ir_local_depth） = IR 局部变量作用域深度 - 1
令 IR 局部变量计数（g_ir_local_count） = 从 IR 局部作用域栈 偏移（IR 局部变量作用域深度 * 8）处读取 64 位

### 测试要点
1. 作用域退出后，内部绑定的变量不再可见（查找局部变量 从后往前扫描到更小索引）
2. 深度减一
3. 深度为 0 时不能再弹出

---

## 函数 判断指针变量（is_ptr_var）

### 作用
判断给定 IR 变量是否为指针语义（由 内建分配指令（IR_ALLOC）、地址索引指令（IR_ADDR_INDEX）、引用指令（IR_REF）、内建分配结构体指令（IR_ALLOC_STRUCT）、内建分配数组指令（IR_ALLOC_ARRAY）等指令产生）。用于指针算术检测（区分普通加减与指针加减/差值运算）。

### 逻辑
接收 变量索引（var_idx）：整数
如果 变量索引 小于 0，那么：
    返回 0
令 生产者节点索引 = 从 变量生产者节点映射（g_df_var_producer）偏移（变量索引 * 8）处读取 64 位
如果 生产者节点索引 小于 0，那么：
    返回 0
令 生产者操作码 = 从 数据流节点数组（g_df_nodes）偏移（生产者节点索引 * ESZ_DFNODE + OFF_DF_OPCODE）处读取 64 位
如果 生产者操作码 等于 内建分配指令（IR_ALLOC），那么：
    令 变量类型索引 = IR 变量访问器：类型（irv_type）（变量索引）
    如果 变量类型索引 等于 整数类型索引（TI_INT）或 等于 浮点类型索引（TI_FLOAT）或 等于 布尔类型索引（TI_BOOL）或 等于 字符类型索引（TI_CHAR），那么：
        返回 0
    返回 1
如果 生产者操作码 等于 地址索引指令（IR_ADDR_INDEX）或 等于 引用指令（IR_REF）或 等于 内建分配结构体指令（IR_ALLOC_STRUCT）或 等于 内建分配数组指令（IR_ALLOC_ARRAY），那么：
    返回 1
返回 0

### 测试要点
1. 变量索引无效（小于 0）时返回 0
2. 基本类型（整数（int）/浮点（float）/布尔（bool）/字符（char））的内建分配指令 不被视为指针
3. 结构体、数组、枚举的内建分配指令 被视为指针
4. 地址索引指令、引用指令、内建分配结构体指令、内建分配数组指令 的直接产物总是指针

---

## 函数 判断字节缓冲变量（is_byte_buf_var）

### 作用
判断给定 IR 变量是否为原始字节缓冲区（由 分配内存（alloc）（）生成，类型为 单元类型信息（TI_UNIT）内部标记值，对应 Core 语言的字符串（string）类型）。字节缓冲区的地址运算不进行元素大小缩放。

### 逻辑
接收 变量索引（var_idx）：整数
如果 变量索引 小于 0，那么：
    返回 0
令 生产者节点索引 = 从 变量生产者节点映射（g_df_var_producer）偏移（变量索引 * 8）处读取 64 位
如果 生产者节点索引 小于 0，那么：
    返回 0
令 生产者操作码 = 从 数据流节点数组（g_df_nodes）偏移（生产者节点索引 * ESZ_DFNODE + OFF_DF_OPCODE）处读取 64 位
如果 生产者操作码 等于 内建分配指令（IR_ALLOC），那么：
    返回 1
返回 0

### 测试要点
1. 变量索引无效时返回 0
2. 仅 内建分配指令 产生的变量被视为字节缓冲区
3. 用于指针算术检测时决定是否跳过缩放

---

## 函数 IR 调用返回类型（ir_call_return_type）

### 作用
根据函数名字索引查询其 IR 级别的返回类型（整数类型索引（TI_INT）/浮点类型索引（TI_FLOAT）/布尔类型索引（TI_BOOL）/字符串类型索引（TI_STR）/单元类型信息（TI_UNIT）/字符类型索引（TI_CHAR））。覆盖内置函数（alloc）返回 单元类型索引 的特殊处理、运行时内置函数表查找、用户定义函数查找，以及共享库（.so）外部函数（SYM_SO_FN）的类型编码解析。

### 逻辑
接收 函数名字索引（func_ni）：整数
如果 函数名字索引 小于 0，那么：
    返回 单元类型信息（TI_UNIT）

（特殊处理：分配内存函数 返回原始字节缓冲区，保持 单元类型索引 标记值）
如果 驻留字符串获取（istr_get）（函数名字索引）的结果指向 分配内存函数（alloc），那么：
    返回 单元类型索引

（查运行时内置函数返回类型表）
令 扫描位置 = 0
循环：
    如果 扫描位置 大于等于 运行时内建函数计数（g_rt_builtin_count），那么：
        跳出循环
    如果 从 运行时内建函数名数组（g_rt_builtin_names）偏移（扫描位置 * 8）处读取的 64 位值 等于 函数名字索引，那么：
        返回 从 运行时内建函数返回类型数组（g_rt_builtin_ret_types）偏移（扫描位置 * 8）处读取的 64 位值
    令 扫描位置 = 扫描位置 + 1

（查用户定义函数）
令 函数信息索引 = 查找函数（find_func）（函数名字索引）
如果 函数信息索引 大于等于 0，那么：
    令 返回类型 = 函数信息访问器：返回类型（fi_return_type）（函数信息索引）
    如果 返回类型 等于 整数字面量类型值（TY_INT），那么：返回 整数类型索引
    如果 返回类型 等于 浮点字面量类型值（TY_FLOAT），那么：返回 浮点类型索引
    如果 返回类型 等于 布尔字面量类型值（TY_BOOL），那么：返回 布尔类型索引
    如果 返回类型 等于 字符串字面量类型值（TY_STRING），那么：返回 字符串类型索引
    如果 返回类型 等于 单元类型值（TY_UNIT），那么：返回 单元类型索引
    如果 返回类型 等于 字符字面量类型值（TY_CHAR），那么：返回 字符类型索引

（查 .so 外部函数符号）
令 符号索引 = 查找泛型符号（find_gsym）（函数名字索引）
如果 符号索引 小于 0，那么：
    返回 单元类型索引
如果 符号类别（sym_kind）（符号索引）等于 函数符号类型（SYM_FN），那么：
    返回 符号类型（sym_type）（符号索引）
如果 符号类别（sym_kind）（符号索引）等于 共享库函数符号类型（SYM_SO_FN），那么：
    令 类型编码 = 符号节点（sym_node）（符号索引）
    令 返回码 = 类型编码 - （类型编码 / 100） * 100
    如果 返回码 等于 0，那么：返回 整数类型索引
    如果 返回码 等于 1，那么：返回 字符串类型索引
    如果 返回码 等于 2，那么：返回 单元类型索引
    如果 返回码 等于 3，那么：返回 浮点类型索引
    如果 返回码 等于 4，那么：返回 布尔类型索引
返回 单元类型索引

### 测试要点
1. 函数名字索引无效（小于 0）时返回 单元类型索引
2. 分配内存（alloc）函数始终返回 单元类型索引
3. 运行时内置函数表中找到匹配时直接返回内置返回类型
4. 用户函数按中间表示类型值（TY_*）到中间表示类型索引（TI_*）映射返回
5. .so 外部函数按类型编码尾部两位数字解析返回类型
6. 所有路径均未找到时返回 单元类型索引

---

## 函数 获取 IR 变量名（get_ir_var_name）

### 作用
根据 IR 变量索引返回其可读名称字符串（通过 驻留字符串获取（istr_get）反查）。用于调试和诊断输出。

### 逻辑
接收 变量索引（var_idx）：整数
如果 变量索引 大于等于 0 且 变量索引 小于 IR 变量总数（g_ir_var_count），那么：
    令 名字索引 = IR 变量访问器：名称（irv_name）（变量索引）
    返回 驻留字符串获取（istr_get）（名字索引）
返回 空字符串 ""

### 测试要点
1. 合法索引返回变量名称字符串
2. 索引超出范围或为负数时返回空字符串
3. 变量名通过驻留字符串系统管理，返回的是驻留（Intern）池中的字符串

---

## 函数 追踪字符串常量（track_str）

### 作用
将字符串驻留索引记录到 IR 字符串常量数组（g_ir_str_consts）中，用于后续生成只读数据（.rodata）段中的字符串常量数据。已存在的字符串索引不重复添加。

### 逻辑
接收 字符串索引（str_idx）：整数
令 扫描位置 = 0
循环：
    如果 扫描位置 大于等于 IR 字符串常量计数（g_ir_str_const_count），那么：
        跳出循环
    如果 从 IR 字符串常量数组（g_ir_str_consts）偏移（扫描位置 * 8）处读取的 64 位值 等于 字符串索引，那么：
        返回（已存在，不重复添加）
    令 扫描位置 = 扫描位置 + 1

（未找到，追加新项）
扩展 IR 字符串常量数组（grow_ir_str_consts）（IR 字符串常量计数 + 1）
在 IR 字符串常量数组 偏移（IR 字符串常量计数 * 8）处写入 64 位值：字符串索引
令 IR 字符串常量计数 = IR 字符串常量计数 + 1

### 测试要点
1. 重复添加同一字符串索引时只保留一条记录
2. 空表时直接追加
3. 数组容量不足时自动扩展
