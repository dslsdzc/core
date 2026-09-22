# ccr_io.cr 伪代码
> 源文件：src/compiler/ccr_io.cr（594 行）
> 功能概要：.线性指令流（ccr） 二进制序列化的完整实现——编译器前端（corec）与后端（corearch）之间的接口。支持版本 1-5 的读写，包括：魔数 + 版本头、各类计数、字符串表、函数元数据、指令流、IR 变量、字符串常量、结构体/枚举定义、全局变量、优化元数据和 SG（region）段。所有整数以小端序（little-endian）存储，含边界检查与版本兼容判断。

## 标识符对照表
| 中文名 | 原名 | 首次出现函数 |
|--------|------|-------------|
| 按位移取字节 | bw_byte | 按位移取字节 |
| 缓冲区写入u32 | buf_write_u32 | 缓冲区写入u32 |
| 缓冲区写入i32 | buf_write_i32 | 缓冲区写入i32 |
| 缓冲区读取u32 | buf_read_u32 | 缓冲区读取u32 |
| 缓冲区读取i32 | buf_read_i32 | 缓冲区读取i32 |
| 缓冲区读取i64 | buf_read_i64 | 缓冲区读取i64 |
| 计算 CCR 大小 | calc_ccr_size | 计算 CCR 大小 |
| 保存 .ccr 文件 | save_ccr | 保存 .ccr 文件 |
| 加载 .ccr 文件 | load_ccr | 加载 .ccr 文件 |
| 驻留字符串长度 | istr_len | 计算 CCR 大小 |
| 驻留字符串获取 | istr_get | 保存 .ccr 文件 |
| 字符串驻留 | str_intern | 加载 .ccr 文件 |
| 字符串按字节读取 | str_load8 | 保存 .ccr 文件 |
| 分配 | alloc | 保存 .ccr 文件 |
| 输出行 | println | 加载 .ccr 文件 |
| 写 32 位 | w32 | 缓冲区写入u32 |
| 写 64 位 | w64 | 保存 .ccr 文件 |
| 写单字节字节存储 | store8 | 保存 .ccr 文件 |
| 读 32 位 | r32 | 计算 CCR 大小 |
| 读 64 位 | r64 | 保存 .ccr 文件 |
| 无符号单字节读取 | load8 | 缓冲区读取u32 |
| IR 指令访问器：操作码 | iri_op | 保存 .ccr 文件 |
| IR 指令访问器：目标 | iri_dest | 保存 .ccr 文件 |
| IR 指令访问器：操作数1 | iri_s1 | 保存 .ccr 文件 |
| IR 指令访问器：操作数2 | iri_s2 | 保存 .ccr 文件 |
| IR 指令访问器：操作数3 | iri_s3 | 保存 .ccr 文件 |
| IR 指令访问器：类型类别 | iri_tk | 保存 .ccr 文件 |
| IR 指令访问器：设置操作码 | iri_set_op | 加载 .ccr 文件 |
| IR 指令访问器：设置目标 | iri_set_dest | 加载 .ccr 文件 |
| IR 指令访问器：设置操作数1 | iri_set_s1 | 加载 .ccr 文件 |
| IR 指令访问器：设置操作数2 | iri_set_s2 | 加载 .ccr 文件 |
| IR 指令访问器：设置操作数3 | iri_set_s3 | 加载 .ccr 文件 |
| IR 指令访问器：设置类型类别 | iri_set_tk | 加载 .ccr 文件 |
| IR 变量访问器：名称 | irv_name | 保存 .ccr 文件 |
| IR 变量访问器：ID | irv_id | 保存 .ccr 文件 |
| IR 变量访问器：类型 | irv_type | 保存 .ccr 文件 |
| IR 变量访问器：设置名称 | irv_set_name | 加载 .ccr 文件 |
| IR 变量访问器：设置ID | irv_set_id | 加载 .ccr 文件 |
| IR 变量访问器：设置类型 | irv_set_type | 加载 .ccr 文件 |
| 结构体信息访问器：名称 | si_name | 保存 .ccr 文件 |
| 结构体信息访问器：字段计数 | si_field_count | 计算 CCR 大小 |
| 结构体信息访问器：字段名称 | si_field_name | 保存 .ccr 文件 |
| 结构体信息访问器：字段类型 | si_field_type | 保存 .ccr 文件 |
| 枚举信息访问器：变体计数 | ei_variant_count | 计算 CCR 大小 |
| 枚举信息访问器：变体类型计数 | ei_variant_type_count | 计算 CCR 大小 |
| 枚举信息访问器：名称 | ei_name | 保存 .ccr 文件 |
| 枚举信息访问器：变体名称 | ei_variant_name | 保存 .ccr 文件 |
| 枚举信息访问器：变体类型 | ei_variant_type | 保存 .ccr 文件 |
| 扩展 IR 变量数组 | grow_ir_vars | 加载 .ccr 文件 |
| 扩展 IR 指令数组 | grow_ir_instrs | 加载 .ccr 文件 |
| 扩展 IR 函数元数据数组 | grow_ir_func_meta | 加载 .ccr 文件 |
| 扩展 IR 字符串常量数组 | grow_ir_str_consts | 加载 .ccr 文件 |
| 扩展结构数组 | grow_structs | 加载 .ccr 文件 |
| 扩展枚举数组 | grow_enums | 加载 .ccr 文件 |
| 扩展 IR 全局变量数组 | grow_ir_globals | 加载 .ccr 文件 |
| 扩展优化元数据数组 | grow_opt_meta | 加载 .ccr 文件 |
| 扩展结构图数组 | grow_sg | 加载 .ccr 文件 |
| 字符串常量计数 | g_str_count | 计算 CCR 大小 |
| IR 函数个数 | g_ir_func_count | 计算 CCR 大小 |
| IR 指令总数 | g_ir_instr_count | 计算 CCR 大小 |
| IR 变量总数 | g_ir_var_count | 计算 CCR 大小 |
| IR 字符串常量计数 | g_ir_str_const_count | 计算 CCR 大小 |
| IR 全局变量计数 | g_ir_global_count | 计算 CCR 大小 |
| 优化元数据计数 | g_opt_meta_count | 计算 CCR 大小 |
| 结构图计数 | g_sg_count | 计算 CCR 大小 |
| 结构体计数 | g_struct_count | 计算 CCR 大小 |
| 枚举计数 | g_enum_count | 计算 CCR 大小 |
| IR 函数名索引数组 | g_ir_func_name_idx | 保存 .ccr 文件 |
| IR 函数参数计数数组 | g_ir_func_param_count | 保存 .ccr 文件 |
| IR 函数返回类型数组 | g_ir_func_ret_type | 保存 .ccr 文件 |
| IR 函数指令起始索引数组 | g_ir_func_instr_start | 保存 .ccr 文件 |
| IR 函数指令计数数组 | g_ir_func_instr_count | 保存 .ccr 文件 |
| IR 函数变量起始索引数组 | g_ir_func_var_start | 保存 .ccr 文件 |
| IR 函数变量计数数组 | g_ir_func_var_count | 保存 .ccr 文件 |
| IR 字符串常量数组 | g_ir_str_consts | 保存 .ccr 文件 |
| IR 全局变量数组 | g_ir_globals | 保存 .ccr 文件 |
| 优化元数据数组 | g_opt_meta | 保存 .ccr 文件 |
| 结构体数组 | g_structs | 加载 .ccr 文件 |
| 枚举数组 | g_enums | 加载 .ccr 文件 |
| 结构图数组 | g_sgs | 加载 .ccr 文件 |
| CCR 魔数 | CCR_MAGIC | （文件级常量） |
| 磁盘 SG 条目大小 | ESZ_SG_DISK | （文件级常量） |
| IR 函数名索引容量 | g_ir_func_name_idx_cap | （全局） |
| 结构体条目大小 | ESZ_STRUCTINFO | （结构体常量） |
| 结构体条目名称偏移 | OFF_SI_NAME | （结构体字段偏移） |
| 结构体条目字段计数偏移 | OFF_SI_FIELD_COUNT | （结构体字段偏移） |
| 结构体条目字段名称偏移 | OFF_SI_FIELD_NAMES | （结构体字段偏移） |
| 结构体条目字段类型偏移 | OFF_SI_FIELD_TYPES | （结构体字段偏移） |
| 结构体条目字段类型节点偏移 | OFF_SI_FIELD_TYPE_NODES | （结构体字段偏移） |
| 结构体条目泛型计数偏移 | OFF_SI_GENERIC_COUNT | （结构体字段偏移） |
| 结构体条目泛型名称偏移 | OFF_SI_GENERIC_NAMES | （结构体字段偏移） |
| 枚举条目大小 | ESZ_ENUMINFO | （结构体常量） |
| 枚举条目名称偏移 | OFF_EI_NAME | （结构体字段偏移） |
| 枚举条目变体计数偏移 | OFF_EI_VARIANT_COUNT | （结构体字段偏移） |
| 枚举条目变体数组偏移 | OFF_EI_VARIANTS | （结构体字段偏移） |
| 枚举条目泛型计数偏移 | OFF_EI_GENERIC_COUNT | （结构体字段偏移） |
| 枚举条目泛型名称偏移 | OFF_EI_GENERIC_NAMES | （结构体字段偏移） |
| 枚举变体条目名称偏移 | OFF_EV_NAME | （结构体字段偏移） |
| 枚举变体条目类型计数偏移 | OFF_EV_TYPE_COUNT | （结构体字段偏移） |
| 枚举变体条目类型数组偏移 | OFF_EV_TYPES | （结构体字段偏移） |
| 枚举变体偏移大小 | OFF_EV_SIZE | （常量） |
| 优化元数据步幅 | OPT_META_STRIDE | （常量） |
| SG 条目大小（内存） | ESZ_SG | （结构体常量） |
| SG 条目类别偏移 | OFF_SG_KIND | （结构体字段偏移） |
| SG 条目入口偏移 | OFF_SG_ENTER | （结构体字段偏移） |
| SG 条目出口偏移 | OFF_SG_EXIT | （结构体字段偏移） |
| SG 条目父节点偏移 | OFF_SG_PARENT | （结构体字段偏移） |
| SG 条目节点起始偏移 | OFF_SG_NSTART | （结构体字段偏移） |
| SG 条目节点计数偏移 | OFF_SG_NCOUNT | （结构体字段偏移） |
| 系统调用3 | syscall3 | 保存 .ccr 文件 |
| 最大结构体字段数 | MAX_STRUCT_FIELDS | （常量） |
| 最大枚举变体数 | MAX_ENUM_VARIANTS | （常量） |
| 最大变体类型数 | MAX_VARIANT_TYPES | （常量） |

## 全局状态
- **魔数（CCR_MAGIC）**：文件标识（CCR1 魔数值）（小端序值为 827474755）
- **磁盘 SG 条目大小（ESZ_SG_DISK）**：磁盘格式下每条 SG 记录大小 = 24 字节（6 个有符号 32 位整数），与内存中的 SG 条目大小（ESZ_SG）（48 字节，无符号 64 位字段）不同

## 函数 按位移取字节（bw_byte）
### 作用
从整数 值（val） 中提取指定移位（shift）位置的字节值（0~255）。通过整数除法和取模运算模拟位运算——因为 Core 语言不支持按位操作。
### 逻辑
    如果 移位值（shift） 等于 0，那么：返回 值（val） 除以 256 的余数
    如果 移位值（shift） 大于等于 24，那么：返回 （值（val） / 16777216） 除以 256 的余数
    如果 移位值（shift） 大于等于 16，那么：返回 （值（val） / 65536） 除以 256 的余数
    如果 移位值（shift） 大于等于 8，那么：返回 （值（val） / 256） 除以 256 的余数
    返回 0
### 测试要点
1. 移位（shift）=0 时返回最低字节（值（val） % 256）
2. 移位（shift）=8 时返回第二字节
3. 移位（shift） 为非法值（如负数或超过 24）时返回 0
4. 负数值的正确性取决于源语言除法语义（此处假设数学取模）

## 函数 缓冲区写入u32（buf_write_u32）
### 作用
将无符号 32 位整数按小端序写入缓冲区的指定位置。委托给写 32 位（w32）。
### 逻辑
    写 32 位（w32）（缓冲区（buf），位置（pos），值（val））
### 测试要点
1. 写入后再用缓冲区读取无符号 32 位函数读回的值与写入值一致
2. 位置参数可指定任意偏移

## 函数 缓冲区写入32位整数（i32）（buf_write_i32）
### 作用
将有符号 32 位整数按小端序写入缓冲区的指定位置。委托给写 32 位（w32）（低位字节相同）。
### 逻辑
    写 32 位（w32）（缓冲区（buf），位置（pos），值（val））
### 测试要点
1. 负数（如 -1 = 0xFFFFFFFF）写入后可用缓冲区读取有符号 32 位函数正确读回

## 函数 缓冲区读取u32（buf_read_u32）
### 作用
从缓冲区指定位置读取小端序无符号 32 位整数。通过逐字节读取并加权求和还原数值。
### 逻辑
    令 字节0（b0） = 无符号单字节读取（load8）（缓冲区（buf），位置（pos））
    令 字节1（b1） = 无符号单字节读取（load8）（缓冲区（buf），位置（pos） + 1）
    令 字节2（b2） = 无符号单字节读取（load8）（缓冲区（buf），位置（pos） + 2）
    令 字节3（b3） = 无符号单字节读取（load8）（缓冲区（buf），位置（pos） + 3）
    返回 字节0（b0） + 字节1（b1） * 256 + 字节2（b2） * 65536 + 字节3（b3） * 16777216
### 测试要点
1. 全零字节读取返回 0
2. 最大无符号值（0xFFFFFFFF）读取返回 4294967295
3. 位置超出缓冲区边界时行为取决于无符号单字节读取函数 的实现

## 函数 缓冲区读取32位整数（i32）（buf_read_i32）
### 作用
从缓冲区指定位置读取小端序有符号 32 位整数。最高字节（b3）若 大于等于 128 则视为负数（符号扩展）。
### 逻辑
    令 字节0（b0） = 无符号单字节读取（load8）（缓冲区（buf），位置（pos））
    令 字节1（b1） = 无符号单字节读取（load8）（缓冲区（buf），位置（pos） + 1）
    令 字节2（b2） = 无符号单字节读取（load8）（缓冲区（buf），位置（pos） + 2）
    令 字节3（b3） = 无符号单字节读取（load8）（缓冲区（buf），位置（pos） + 3）
    令 值（val） = 字节0（b0） + 字节1（b1） * 256 + 字节2（b2） * 65536
    如果 字节3（b3） 大于等于 128，那么：返回 值（val） + （字节3（b3） - 256） * 16777216
    返回 值（val） + 字节3（b3） * 16777216
### 测试要点
1. 零值读取返回 0
2. 正数（字节3（b3） 小于 128）正常读取
3. 负数（字节3（b3） >= 128，如 -1 = 0xFFFFFFFF）正确进行符号扩展
4. 最大正数（0x7FFFFFFF）读取返回 2147483647

## 函数 缓冲区读取64位整数（i64）（buf_read_i64）
### 作用
从缓冲区指定位置读取小端序有符号 64 位整数。低 32 位按无符号读取（避免对负数的双重符号扩展），高 32 位对高 32 位做符号扩展后组合为低位加高位乘 2 的 32 次方。
### 逻辑
    令 字节0（b0） = 无符号单字节读取（load8）（缓冲区（buf），位置（pos））
    令 字节1（b1） = 无符号单字节读取（load8）（缓冲区（buf），位置（pos） + 1）
    令 字节2（b2） = 无符号单字节读取（load8）（缓冲区（buf），位置（pos） + 2）
    令 字节3（b3） = 无符号单字节读取（load8）（缓冲区（buf），位置（pos） + 3）
    令 低位（lo） = 字节0（b0） + 字节1（b1） * 256 + 字节2（b2） * 65536 + 字节3（b3） * 16777216
    令 高位字节0（h0） = 无符号单字节读取（load8）（缓冲区（buf），位置（pos） + 4）
    令 高位字节1（h1） = 无符号单字节读取（load8）（缓冲区（buf），位置（pos） + 5）
    令 高位字节2（h2） = 无符号单字节读取（load8）（缓冲区（buf），位置（pos） + 6）
    令 高位字节3（h3） = 无符号单字节读取（load8）（缓冲区（buf），位置（pos） + 7）
    令 高位（hi） = 高位字节0（h0） + 高位字节1（h1） * 256 + 高位字节2（h2） * 65536（可变）
    如果 高位字节3（h3） 大于等于 128，那么：令 高位（hi） = 高位（hi） + （高位字节3（h3） - 256） * 16777216
    返回 低位（lo） + 高位（hi） * 4294967296
### 测试要点
1. 零值读取返回 0
2. 小的负数（如 -7）正确读取——低 32 位无符号读取避免双重符号扩展
3. 大负数（如 -4294967296）正确读取
4. 正 64 位数（含高于 2^32 的值）正确读取

## 函数 计算 线性指令流（CCR） 大小（calc_ccr_size）
### 作用
计算序列化整个 .线性指令流（ccr） 文件所需的字节数。遍历字符串表、函数元数据、指令、IR 变量、字符串常量、结构体、枚举、全局变量、优化元数据和 SG（region）段（v5+），累加各部分占用的字节数。
### 逻辑
    令 总大小（sz） = 36（可变）（头 + 7 个 u32 计数 = 4 + 4 + 28）
    令 字符串索引（si） = 0（可变）
    循环（当 字符串索引 小于 字符串常量计数（g_str_count） 时）：
        令 字符串长度（sl） = 驻留字符串长度（istr_len）（字符串索引）
        令 总大小（sz） = 总大小（sz） + 4 + 字符串长度（sl）
        令 字符串索引 = 字符串索引 + 1
    令 总大小（sz） = 总大小（sz） + IR 函数个数（g_ir_func_count） * 28
    令 总大小（sz） = 总大小（sz） + IR 指令总数（g_ir_instr_count） * 24
    令 总大小（sz） = 总大小（sz） + IR 变量总数（g_ir_var_count） * 12
    令 总大小（sz） = 总大小（sz） + IR 字符串常量计数（g_ir_str_const_count） * 4
    令 结构体索引（sti） = 0（可变）
    循环（当 结构体索引 小于 结构体计数（g_struct_count） 时）：
        令 字段数（fc） = 结构体信息访问器：字段计数（si_field_count）（结构体索引）
        令 总大小（sz） = 总大小（sz） + 8 + 字段数（fc） * 8
        令 结构体索引 = 结构体索引 + 1
    令 枚举索引（ei） = 0（可变）
    循环（当 枚举索引 小于 枚举计数（g_enum_count） 时）：
        令 变体数（vc） = 枚举信息访问器：变体计数（ei_variant_count）（枚举索引）
        令 总大小（sz） = 总大小（sz） + 8
        令 变体索引（vi） = 0（可变）
        循环（当 变体索引 小于 变体数（vc） 时）：
            令 类型数（tc） = 枚举信息访问器：变体类型计数（ei_variant_type_count）（枚举索引，变体索引）
            令 总大小（sz） = 总大小（sz） + 8
            令 总大小（sz） = 总大小（sz） + 类型数（tc） * 4
            令 变体索引 = 变体索引 + 1
        令 枚举索引 = 枚举索引 + 1
    令 总大小（sz） = 总大小（sz） + 4 + IR 全局变量计数（g_ir_global_count） * 16
    令 总大小（sz） = 总大小（sz） + 4
    令 元数据索引（mi） = 0（可变）
    循环（当 元数据索引 小于 优化元数据计数（g_opt_meta_count） 时）：
        令 总大小（sz） = 总大小（sz） + 8 + 读 32 位（r32）（优化元数据数组（g_opt_meta），元数据索引 * 优化元数据步幅（OPT_META_STRIDE） + 4）
        令 元数据索引 = 元数据索引 + 1
    令 总大小（sz） = 总大小（sz） + 4 + 结构图计数（g_sg_count） * 磁盘 SG 条目大小（ESZ_SG_DISK）
    返回 总大小（sz）
### 测试要点
1. 所有计数为零时（空程序），返回 36（仅头 + 七个零计数）
2. 字符串部分正确计算长度前缀（4 字节）+ 内容的总大小
3. 枚举的嵌套变体及其类型字段正确计入
4. 优化元数据的可变长度数据（data_len）正确加入
5. 版本 5 的 SG 段：结构图计数 * 24 字节正确加入

## 函数 保存 .线性指令流（ccr） 文件（save_ccr）
### 作用
将当前编译的全部全局状态序列化为 .线性指令流（ccr） 二进制文件。依次写入：魔数 "CCR1"（v5）、各计数（函数/指令/变量/字符串/结构体/枚举）、字符串表、函数元数据（每条 7 个 u32）、指令流（i32）、IR 变量（每条 3 变量甲 u32）、字符串常量索引、结构体定义（含字段）、枚举定义（含变体）、全局变量（每条 16 字节）、优化元数据（含可变长度数据）和 SG region 段。最后通过系统调用直接写入文件。
### 逻辑
    令 总大小（tsz） = 计算 线性指令流（CCR） 大小（calc_ccr_size）（）
    令 缓冲区（buf） = 分配（alloc）（tsz）
    令 位置（pos） = 0（可变）
    缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），线性指令流（CCR） 魔数（CCR_MAGIC））
    令 位置（pos） = 位置（位置） + 4
    缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），5）
    令 位置（pos） = 位置（位置） + 4
    缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），IR 函数个数（g_ir_func_count））
    令 位置（pos） = 位置（位置） + 4
    缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），IR 指令总数（g_ir_instr_count））
    令 位置（pos） = 位置（位置） + 4
    缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），IR 变量总数（g_ir_var_count））
    令 位置（pos） = 位置（位置） + 4
    缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），字符串常量计数（g_str_count））
    令 位置（pos） = 位置（位置） + 4
    缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），IR 字符串常量计数（g_ir_str_const_count））
    令 位置（pos） = 位置（位置） + 4
    缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），结构体计数（g_struct_count））
    令 位置（pos） = 位置（位置） + 4
    缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），枚举计数（g_enum_count））
    令 位置（pos） = 位置（位置） + 4
    令 字符串索引（si） = 0（可变）
    循环（当 字符串索引 小于 字符串常量计数（g_str_count） 时）：
        令 字符串长度（sl） = 驻留字符串长度（istr_len）（字符串索引）
        缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），字符串长度（sl））
        令 位置（pos） = 位置（位置） + 4
        令 字符索引（ci） = 0（可变）
        循环（当 字符索引 小于 字符串长度（sl） 时）：
            令 字符（ch） = 字符串按字节读取（str_load8）（字符串索引，字符索引）
            写单字节字节存储（store8）（缓冲区（buf），位置（pos），字符（ch））
            令 位置（pos） = 位置（位置） + 1
            令 字符索引 = 字符索引 + 1
        令 字符串索引 = 字符串索引 + 1
    令 函数索引（fi） = 0（可变）
    循环（当 函数索引 小于 IR 函数个数（g_ir_func_count） 时）：
        缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），读 64 位（r64）（IR 函数名索引数组（g_ir_func_name_idx），函数索引 * 8））
        令 位置（pos） = 位置（位置） + 4
        缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），读 64 位（r64）（IR 函数参数计数数组（g_ir_func_param_count），函数索引 * 8））
        令 位置（pos） = 位置（位置） + 4
        缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），读 64 位（r64）（IR 函数返回类型数组（g_ir_func_ret_type），函数索引 * 8））
        令 位置（pos） = 位置（位置） + 4
        缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），读 64 位（r64）（IR 函数指令起始索引数组（g_ir_func_instr_start），函数索引 * 8））
        令 位置（pos） = 位置（位置） + 4
        缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），读 64 位（r64）（IR 函数指令计数数组（g_ir_func_instr_count），函数索引 * 8））
        令 位置（pos） = 位置（位置） + 4
        缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），读 64 位（r64）（IR 函数变量起始索引数组（g_ir_func_var_start），函数索引 * 8））
        令 位置（pos） = 位置（位置） + 4
        缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），读 64 位（r64）（IR 函数变量计数数组（g_ir_func_var_count），函数索引 * 8））
        令 位置（pos） = 位置（位置） + 4
        令 函数索引 = 函数索引 + 1
    令 指令索引（ii） = 0（可变）
    循环（当 指令索引 小于 IR 指令总数（g_ir_instr_count） 时）：
        缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），IR 指令访问器：操作码（iri_op）（指令索引））
        令 位置（pos） = 位置（位置） + 4
        缓冲区写入32位整数（i32）（buf_write_i32）（缓冲区（buf），位置（pos），IR 指令访问器：目标（iri_dest）（指令索引））
        令 位置（pos） = 位置（位置） + 4
        缓冲区写入32位整数（i32）（buf_write_i32）（缓冲区（buf），位置（pos），IR 指令访问器：操作数1（iri_s1）（指令索引））
        令 位置（pos） = 位置（位置） + 4
        缓冲区写入32位整数（i32）（buf_write_i32）（缓冲区（buf），位置（pos），IR 指令访问器：操作数2（iri_s2）（指令索引））
        令 位置（pos） = 位置（位置） + 4
        缓冲区写入32位整数（i32）（buf_write_i32）（缓冲区（buf），位置（pos），IR 指令访问器：操作数3（iri_s3）（指令索引））
        令 位置（pos） = 位置（位置） + 4
        缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），IR 指令访问器：类型类别（iri_tk）（指令索引））
        令 位置（pos） = 位置（位置） + 4
        令 指令索引 = 指令索引 + 1
    令 变量索引（vi） = 0（可变）
    循环（当 变量索引 小于 IR 变量总数（g_ir_var_count） 时）：
        缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），IR 变量访问器：名称（irv_name）（变量索引））
        令 位置（pos） = 位置（位置） + 4
        缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），IR 变量访问器：ID（irv_id）（变量索引））
        令 位置（pos） = 位置（位置） + 4
        缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），IR 变量访问器：类型（irv_type）（变量索引））
        令 位置（pos） = 位置（位置） + 4
        令 变量索引 = 变量索引 + 1
    令 字符串常量索引（sci） = 0（可变）
    循环（当 字符串常量索引 小于 IR 字符串常量计数（g_ir_str_const_count） 时）：
        缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），读 64 位（r64）（IR 字符串常量数组（g_ir_str_consts），字符串常量索引 * 8））
        令 位置（pos） = 位置（位置） + 4
        令 字符串常量索引 = 字符串常量索引 + 1
    令 结构体索引（sti） = 0（可变）
    循环（当 结构体索引 小于 结构体计数（g_struct_count） 时）：
        令 字段数（fc） = 结构体信息访问器：字段计数（si_field_count）（结构体索引）
        缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），结构体信息访问器：名称（si_name）（结构体索引））
        令 位置（pos） = 位置（位置） + 4
        缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），字段数（fc））
        令 位置（pos） = 位置（位置） + 4
        令 字段索引（fii） = 0（可变）
        循环（当 字段索引 小于 字段数（fc） 时）：
            缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），结构体信息访问器：字段名称（si_field_name）（结构体索引，字段索引））
            令 位置（pos） = 位置（位置） + 4
            缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），结构体信息访问器：字段类型（si_field_type）（结构体索引，字段索引））
            令 位置（pos） = 位置（位置） + 4
            令 字段索引 = 字段索引 + 1
        令 结构体索引 = 结构体索引 + 1
    令 枚举索引（ei） = 0（可变）
    循环（当 枚举索引 小于 枚举计数（g_enum_count） 时）：
        令 变体数（vc） = 枚举信息访问器：变体计数（ei_variant_count）（枚举索引）
        缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），枚举信息访问器：名称（ei_name）（枚举索引））
        令 位置（pos） = 位置（位置） + 4
        缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），变体数（vc））
        令 位置（pos） = 位置（位置） + 4
        令 变体索引2（vi2） = 0（可变）
        循环（当 变体索引2 小于 变体数（vc） 时）：
            令 类型计数（tcnt） = 枚举信息访问器：变体类型计数（ei_variant_type_count）（枚举索引，变体索引2）
            缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），枚举信息访问器：变体名称（ei_variant_name）（枚举索引，变体索引2））
            令 位置（pos） = 位置（位置） + 4
            缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），类型计数（tcnt））
            令 位置（pos） = 位置（位置） + 4
            令 类型字段索引（tf） = 0（可变）
            循环（当 类型字段索引 小于 类型计数（tcnt） 时）：
                缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），枚举信息访问器：变体类型（ei_variant_type）（枚举索引，变体索引2，类型字段索引））
                令 位置（pos） = 位置（位置） + 4
                令 类型字段索引 = 类型字段索引 + 1
            令 变体索引2 = 变体索引2 + 1
        令 枚举索引 = 枚举索引 + 1
    缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），IR 全局变量计数（g_ir_global_count））
    令 位置（pos） = 位置（位置） + 4
    令 全局索引（gi） = 0（可变）
    循环（当 全局索引 小于 IR 全局变量计数（g_ir_global_count） 时）：
        缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），读 64 位（r64）（IR 全局变量数组（g_ir_globals），全局索引 * 24））
        令 位置（pos） = 位置（位置） + 4
        缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），读 64 位（r64）（IR 全局变量数组（g_ir_globals），全局索引 * 24 + 8））
        令 位置（pos） = 位置（位置） + 4
        写 64 位（w64）（缓冲区（buf），位置（pos），读 64 位（r64）（IR 全局变量数组（g_ir_globals），全局索引 * 24 + 16））
        令 位置（pos） = 位置（位置） + 8
        令 全局索引 = 全局索引 + 1
    缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），优化元数据计数（g_opt_meta_count））
    令 位置（pos） = 位置（位置） + 4
    令 元数据索引（mi） = 0（可变）
    循环（当 元数据索引 小于 优化元数据计数（g_opt_meta_count） 时）：
        令 元数据偏移（mo） = 元数据索引 * 优化元数据步幅（OPT_META_STRIDE）
        令 元数据键（mk） = 读 32 位（r32）（优化元数据数组（g_opt_meta），元数据偏移（mo））
        令 数据长度（md_len） = 读 32 位（r32）（优化元数据数组（g_opt_meta），元数据偏移（mo） + 4）
        缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），元数据键（mk））
        令 位置（pos） = 位置（位置） + 4
        缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），数据长度（md_len））
        令 位置（pos） = 位置（位置） + 4
        令 数据索引（di） = 0（可变）
        循环（当 数据索引 小于 数据长度（md_len） 时）：
            写单字节字节存储（store8）（缓冲区（buf），位置（pos），无符号单字节读取（load8）（优化元数据数组（g_opt_meta），元数据偏移（mo） + 8 + 数据索引））
            令 位置（pos） = 位置（位置） + 1
            令 数据索引 = 数据索引 + 1
        令 元数据索引 = 元数据索引 + 1
    缓冲区写入u32（buf_write_u32）（缓冲区（buf），位置（pos），结构图计数（g_sg_count））
    令 位置（pos） = 位置（位置） + 4
    令 SG 索引（si2） = 0（可变）
    循环（当 SG 索引 小于 结构图计数（g_sg_count） 时）：
        令 SG 字段基址（f） = SG 索引 * SG 条目大小（内存）（ESZ_SG）
        缓冲区写入32位整数（i32）（buf_write_i32）（缓冲区（buf），位置（pos），读 64 位（r64）（结构图数组（g_sgs），SG 字段基址（f） + SG 条目类别偏移（OFF_SG_KIND）））
        令 位置（pos） = 位置（位置） + 4
        缓冲区写入32位整数（i32）（buf_write_i32）（缓冲区（buf），位置（pos），读 64 位（r64）（结构图数组（g_sgs），SG 字段基址（f） + SG 条目入口偏移（OFF_SG_ENTER）））
        令 位置（pos） = 位置（位置） + 4
        缓冲区写入32位整数（i32）（buf_write_i32）（缓冲区（buf），位置（pos），读 64 位（r64）（结构图数组（g_sgs），SG 字段基址（f） + SG 条目出口偏移（OFF_SG_EXIT）））
        令 位置（pos） = 位置（位置） + 4
        缓冲区写入32位整数（i32）（buf_write_i32）（缓冲区（buf），位置（pos），读 64 位（r64）（结构图数组（g_sgs），SG 字段基址（f） + SG 条目父节点偏移（OFF_SG_PARENT）））
        令 位置（pos） = 位置（位置） + 4
        缓冲区写入32位整数（i32）（buf_write_i32）（缓冲区（buf），位置（pos），读 64 位（r64）（结构图数组（g_sgs），SG 字段基址（f） + SG 条目节点起始偏移（OFF_SG_NSTART）））
        令 位置（pos） = 位置（位置） + 4
        缓冲区写入32位整数（i32）（buf_write_i32）（缓冲区（buf），位置（pos），读 64 位（r64）（结构图数组（g_sgs），SG 字段基址（f） + SG 条目节点计数偏移（OFF_SG_NCOUNT）））
        令 位置（pos） = 位置（位置） + 4
        令 SG 索引 = SG 索引 + 1
    令 文件描述符（fd） = 系统调用3（syscall3）（2，路径（path），577，420）
    如果 文件描述符（fd） 小于 0，那么：返回 -1
    令 已写入（written） = 0（可变）
    令 已写入（written） = 系统调用3（syscall3）（1，文件描述符（fd），缓冲区（buf），总大小（tsz））
    令 返回值（r2） = 系统调用3（syscall3）（3，文件描述符（fd），0，0）
    如果 已写入（written） 不等于 总大小（tsz），那么：返回 -1
    返回 0
### 测试要点
1. 路径不可写时（open 返回负数），返回 -1
2. 写入字节数不等于预计总大小时（磁盘满等），返回 -1
3. 空程序（所有计数为零）仍能正确写出头部 + 零计数 + 零长度各段
4. SG 段（v5）在结构图计数（g_sg_count）大于 0 时正确写入 6 个 32位整数（i32） 字段
5. 文件描述符在返回前正确关闭（无论成功或失败）

## 函数 加载 .线性指令流（ccr） 文件（load_ccr）
### 作用
从内存中的二进制数据解析 .线性指令流（ccr） 文件，将状态恢复到编译器的全局数组中。支持版本 1-5：检查魔数和版本范围，按序读取各段数据并填充全局数组（字符串表、函数元数据、指令、IR 变量、字符串常量、结构体、枚举、全局变量（v2+）、优化元数据（v3+）和 SG region 段（v5+））。每段读取前预扩展数组容量，对结构体和枚举的字段/变体槽位做零初始化以确保固定大小数组被完整清理。遇到数据损坏（字段数/变体数/类型数超限、读取超出缓冲区末尾）时报错并返回 -1 或 1。
### 逻辑
    如果 文件大小（fsize） 小于 36，那么：返回 -1
    令 位置（pos） = 0（可变）
    令 魔数（magic） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
    令 位置（pos） = 位置（位置） + 4
    如果 魔数（magic） 不等于 线性指令流（CCR） 魔数（CCR_MAGIC），那么：返回 -1
    令 版本（ver） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
    令 位置（pos） = 位置（位置） + 4
    如果 版本（ver） 不等于 1 且 版本（ver） 不等于 2 且 版本（ver） 不等于 3 且 版本（ver） 不等于 4 且 版本（ver） 不等于 5，那么：返回 -1
    令 函数数（func_cnt） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
    令 位置（pos） = 位置（位置） + 4
    令 指令数（instr_cnt） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
    令 位置（pos） = 位置（位置） + 4
    令 变量数（var_cnt） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
    令 位置（pos） = 位置（位置） + 4
    令 字符串数（str_cnt） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
    令 位置（pos） = 位置（位置） + 4
    令 字符串常量数（str_const_cnt） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
    令 位置（pos） = 位置（位置） + 4
    令 结构体数（struct_cnt） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
    令 位置（pos） = 位置（位置） + 4
    令 枚举数（enum_cnt） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
    令 位置（pos） = 位置（位置） + 4
    扩展 IR 变量数组（grow_ir_vars）（var_cnt）
    扩展 IR 指令数组（grow_ir_instrs）（instr_cnt）
    扩展 IR 函数元数据数组（grow_ir_func_meta）（func_cnt）
    扩展 IR 字符串常量数组（grow_ir_str_consts）（str_const_cnt）
    扩展结构体数组（grow_structs）（struct_cnt）
    扩展枚举数组（grow_enums）（enum_cnt）
    令 字符串常量计数（g_str_count） = 0
    令 IR 变量总数（g_ir_var_count） = 0
    令 IR 指令总数（g_ir_instr_count） = 0
    令 IR 函数个数（g_ir_func_count） = 0
    令 IR 字符串常量计数（g_ir_str_const_count） = 0
    令 结构体计数（g_struct_count） = 结构体数（struct_cnt）
    令 枚举计数（g_enum_count） = 枚举数（enum_cnt）
    令 结构图计数（g_sg_count） = 0
    令 字符串索引（si） = 0（可变）
    循环（当 字符串索引 小于 字符串数（str_cnt） 时）：
        令 字符串长度（sl） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
        令 位置（pos） = 位置（位置） + 4
        令 字符串缓冲区（s） = 分配（alloc）（字符串长度（sl） + 1）
        令 字符索引（ci） = 0（可变）
        循环（当 字符索引 小于 字符串长度（sl） 时）：
            令 字符（ch） = 无符号单字节读取（load8）（数据（data），位置（pos））
            写单字节字节存储（store8）（字符串缓冲区（s），字符索引，字符（ch））
            令 位置（pos） = 位置（位置） + 1
            令 字符索引 = 字符索引 + 1
        写单字节字节存储（store8）（字符串缓冲区（s），字符串长度（sl），0）
        字符串驻留（str_intern）（s）
        令 字符串索引 = 字符串索引 + 1
    令 函数索引（fi） = 0（可变）
    循环（当 函数索引 小于 函数数（func_cnt） 时）：
        令 字段值0（fv0） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
        令 位置（pos） = 位置（位置） + 4
        写 64 位（w64）（IR 函数名索引数组（g_ir_func_name_idx），函数索引 * 8，字段值0（fv0））
        令 字段值1（fv1） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
        令 位置（pos） = 位置（位置） + 4
        写 64 位（w64）（IR 函数参数计数数组（g_ir_func_param_count），函数索引 * 8，字段值1（fv1））
        令 字段值2（fv2） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
        令 位置（pos） = 位置（位置） + 4
        写 64 位（w64）（IR 函数返回类型数组（g_ir_func_ret_type），函数索引 * 8，字段值2（fv2））
        令 字段值3（fv3） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
        令 位置（pos） = 位置（位置） + 4
        写 64 位（w64）（IR 函数指令起始索引数组（g_ir_func_instr_start），函数索引 * 8，字段值3（fv3））
        令 字段值4（fv4） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
        令 位置（pos） = 位置（位置） + 4
        写 64 位（w64）（IR 函数指令计数数组（g_ir_func_instr_count），函数索引 * 8，字段值4（fv4））
        令 字段值5（fv5） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
        令 位置（pos） = 位置（位置） + 4
        写 64 位（w64）（IR 函数变量起始索引数组（g_ir_func_var_start），函数索引 * 8，字段值5（fv5））
        令 字段值6（fv6） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
        令 位置（pos） = 位置（位置） + 4
        写 64 位（w64）（IR 函数变量计数数组（g_ir_func_var_count），函数索引 * 8，字段值6（fv6））
        令 IR 函数个数（g_ir_func_count） = 函数索引 + 1
        令 函数索引 = 函数索引 + 1
    令 指令索引（ii） = 0（可变）
    循环（当 指令索引 小于 指令数（instr_cnt） 时）：
        令 操作码（opcode） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
        令 位置（pos） = 位置（位置） + 4
        令 目标变量（dest） = 缓冲区读取32位整数（i32）（buf_read_i32）（数据（data），位置（pos））
        令 位置（pos） = 位置（位置） + 4
        令 源操作数1（s1） = 缓冲区读取32位整数（i32）（buf_read_i32）（数据（data），位置（pos））
        令 位置（pos） = 位置（位置） + 4
        令 源操作数2（s2） = 缓冲区读取32位整数（i32）（buf_read_i32）（数据（data），位置（pos））
        令 位置（pos） = 位置（位置） + 4
        令 源操作数3（s3） = 缓冲区读取32位整数（i32）（buf_read_i32）（数据（data），位置（pos））
        令 位置（pos） = 位置（位置） + 4
        令 类型类别（tk） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
        令 位置（pos） = 位置（位置） + 4
        IR 指令访问器：设置操作码（iri_set_op）（指令索引，操作码）
        IR 指令访问器：设置目标（iri_set_dest）（指令索引，目标）
        IR 指令访问器：设置操作数1（iri_set_s1）（指令索引，操作数1）
        IR 指令访问器：设置操作数2（iri_set_s2）（s2）
        IR 指令访问器：设置操作数3（iri_set_s3）（s3）
        IR 指令访问器：设置类型类别（iri_set_tk）（tk）
        令 IR 指令总数（g_ir_instr_count） = 指令索引 + 1
        令 指令索引 = 指令索引 + 1
    令 变量索引（vi） = 0（可变）
    循环（当 变量索引 小于 变量数（var_cnt） 时）：
        令 名称索引（name_ni） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
        令 位置（pos） = 位置（位置） + 4
        令 标识符（id） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
        令 位置（pos） = 位置（位置） + 4
        令 类型类别（tk） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
        令 位置（pos） = 位置（位置） + 4
        IR 变量访问器：设置名称（irv_set_name）（变量索引，名称索引）
        IR 变量访问器：设置ID（irv_set_id）（id）
        IR 变量访问器：设置类型（irv_set_type）（变量索引，类型）
        令 IR 变量总数（g_ir_var_count） = 变量索引 + 1
        令 变量索引 = 变量索引 + 1
    令 字符串常量索引（sci） = 0（可变）
    循环（当 字符串常量索引 小于 字符串常量数（str_const_cnt） 时）：
        令 常量值（scv） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
        令 位置（pos） = 位置（位置） + 4
        写 64 位（w64）（IR 字符串常量数组（g_ir_str_consts），字符串常量索引 * 8，常量值（scv））
        令 IR 字符串常量计数（g_ir_str_const_count） = 字符串常量索引 + 1
        令 字符串常量索引 = 字符串常量索引 + 1
    令 结构体索引（sti） = 0（可变）
    循环（当 结构体索引 小于 结构体数（struct_cnt） 时）：
        令 名称索引（name_ni） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
        令 位置（pos） = 位置（位置） + 4
        令 字段数（fc） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
        令 位置（pos） = 位置（位置） + 4
        如果 字段数（fc） 大于 最大结构体字段数（MAX_STRUCT_FIELDS），那么：
            输出行（println）（"error: .ccr struct field count exceeds max"）
            返回 1
        写 64 位（w64）（结构体数组（g_structs），结构体索引 * 结构体条目大小（ESZ_STRUCTINFO） + 结构体条目名称偏移（OFF_SI_NAME），名称索引（name_ni））
        写 64 位（w64）（结构体数组（g_structs），结构体索引 * 结构体条目大小（ESZ_STRUCTINFO） + 结构体条目字段计数偏移（OFF_SI_FIELD_COUNT），字段数（fc））
        令 零字段索引（zfi） = 0（可变）
        循环（当 零字段索引 小于 16 时）：
            写 64 位（w64）（结构体数组（g_structs），结构体索引 * 结构体条目大小（ESZ_STRUCTINFO） + 结构体条目字段名称偏移（OFF_SI_FIELD_NAMES） + 零字段索引 * 8，0）
            写 64 位（w64）（结构体数组（g_structs），结构体索引 * 结构体条目大小（ESZ_STRUCTINFO） + 结构体条目字段类型偏移（OFF_SI_FIELD_TYPES） + 零字段索引 * 8，0）
            写 64 位（w64）（结构体数组（g_structs），结构体索引 * 结构体条目大小（ESZ_STRUCTINFO） + 结构体条目字段类型节点偏移（OFF_SI_FIELD_TYPE_NODES） + 零字段索引 * 8，0）
            令 零字段索引 = 零字段索引 + 1
        写 64 位（w64）（结构体数组（g_structs），结构体索引 * 结构体条目大小（ESZ_STRUCTINFO） + 结构体条目泛型计数偏移（OFF_SI_GENERIC_COUNT），0）
        令 零泛型索引（zgi） = 0（可变）
        循环（当 零泛型索引 小于 4 时）：
            写 64 位（w64）（结构体数组（g_structs），结构体索引 * 结构体条目大小（ESZ_STRUCTINFO） + 结构体条目泛型名称偏移（OFF_SI_GENERIC_NAMES） + 零泛型索引 * 8，0）
            令 零泛型索引 = 零泛型索引 + 1
        令 字段索引2（fi2） = 0（可变）
        循环（当 字段索引2 小于 字段数（fc） 时）：
            令 字段名索引（fn_ni） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
            令 位置（pos） = 位置（位置） + 4
            令 字段类型（ft） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
            令 位置（pos） = 位置（位置） + 4
            写 64 位（w64）（结构体数组（g_structs），结构体索引 * 结构体条目大小（ESZ_STRUCTINFO） + 结构体条目字段名称偏移（OFF_SI_FIELD_NAMES） + 字段索引2 * 8，字段名索引（fn_ni））
            写 64 位（w64）（结构体数组（g_structs），结构体索引 * 结构体条目大小（ESZ_STRUCTINFO） + 结构体条目字段类型偏移（OFF_SI_FIELD_TYPES） + 字段索引2 * 8，字段类型（ft））
            令 字段索引2 = 字段索引2 + 1
        令 结构体索引 = 结构体索引 + 1
    令 枚举索引（ei） = 0（可变）
    循环（当 枚举索引 小于 枚举数（enum_cnt） 时）：
        令 枚举名索引（ename_ni） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
        令 位置（pos） = 位置（位置） + 4
        令 变体数（vc） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
        令 位置（pos） = 位置（位置） + 4
        如果 变体数（vc） 大于 最大枚举变体数（MAX_ENUM_VARIANTS），那么：
            输出行（println）（"error: .线性指令流（ccr） 枚举（enum） variant count exceeds max"）
            返回 1
        写 64 位（w64）（枚举数组（g_enums），枚举索引 * 枚举条目大小（ESZ_ENUMINFO） + 枚举条目名称偏移（OFF_EI_NAME），枚举名索引（ename_ni））
        写 64 位（w64）（枚举数组（g_enums），枚举索引 * 枚举条目大小（ESZ_ENUMINFO） + 枚举条目变体计数偏移（OFF_EI_VARIANT_COUNT），变体数（vc））
        令 零变体索引（zvi） = 0（可变）
        循环（当 零变体索引 小于 16 时）：
            写 64 位（w64）（枚举数组（g_enums），枚举索引 * 枚举条目大小（ESZ_ENUMINFO） + 枚举条目变体数组偏移（OFF_EI_VARIANTS） + 零变体索引 * 枚举变体偏移大小（OFF_EV_SIZE） + 枚举变体条目名称偏移（OFF_EV_NAME），0）
            写 64 位（w64）（枚举数组（g_enums），枚举索引 * 枚举条目大小（ESZ_ENUMINFO） + 枚举条目变体数组偏移（OFF_EI_VARIANTS） + 零变体索引 * 枚举变体偏移大小（OFF_EV_SIZE） + 枚举变体条目类型计数偏移（OFF_EV_TYPE_COUNT），0）
            令 零类型索引（ztj） = 0（可变）
            循环（当 零类型索引 小于 16 时）：
                写 64 位（w64）（枚举数组（g_enums），枚举索引 * 枚举条目大小（ESZ_ENUMINFO） + 枚举条目变体数组偏移（OFF_EI_VARIANTS） + 零变体索引 * 枚举变体偏移大小（OFF_EV_SIZE） + 枚举变体条目类型数组偏移（OFF_EV_TYPES） + 零类型索引 * 8，0）
                令 零类型索引 = 零类型索引 + 1
            令 零变体索引 = 零变体索引 + 1
        写 64 位（w64）（枚举数组（g_enums），枚举索引 * 枚举条目大小（ESZ_ENUMINFO） + 枚举条目泛型计数偏移（OFF_EI_GENERIC_COUNT），0）
        令 零泛型索引2（zgi2） = 0（可变）
        循环（当 零泛型索引2 小于 4 时）：
            写 64 位（w64）（枚举数组（g_enums），枚举索引 * 枚举条目大小（ESZ_ENUMINFO） + 枚举条目泛型名称偏移（OFF_EI_GENERIC_NAMES） + 零泛型索引2 * 8，0）
            令 零泛型索引2 = 零泛型索引2 + 1
        令 变体索引3（vi3） = 0（可变）
        循环（当 变体索引3 小于 变体数（vc） 时）：
            令 变体名索引（vni） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
            令 位置（pos） = 位置（位置） + 4
            令 类型计数（tc） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
            令 位置（pos） = 位置（位置） + 4
            如果 类型计数（tc） 大于 最大变体类型数（MAX_VARIANT_TYPES），那么：
                输出行（println）（"error: .线性指令流（ccr） variant type count exceeds max"）
                返回 1
            写 64 位（w64）（枚举数组（g_enums），枚举索引 * 枚举条目大小（ESZ_ENUMINFO） + 枚举条目变体数组偏移（OFF_EI_VARIANTS） + 变体索引3 * 枚举变体偏移大小（OFF_EV_SIZE） + 枚举变体条目名称偏移（OFF_EV_NAME），变体名索引（vni））
            写 64 位（w64）（枚举数组（g_enums），枚举索引 * 枚举条目大小（ESZ_ENUMINFO） + 枚举条目变体数组偏移（OFF_EI_VARIANTS） + 变体索引3 * 枚举变体偏移大小（OFF_EV_SIZE） + 枚举变体条目类型计数偏移（OFF_EV_TYPE_COUNT），类型计数（tc））
            令 类型字段索引（tf） = 0（可变）
            循环（当 类型字段索引 小于 类型计数（tc） 时）：
                令 类型值（tval） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
                令 位置（pos） = 位置（位置） + 4
                写 64 位（w64）（枚举数组（g_enums），枚举索引 * 枚举条目大小（ESZ_ENUMINFO） + 枚举条目变体数组偏移（OFF_EI_VARIANTS） + 变体索引3 * 枚举变体偏移大小（OFF_EV_SIZE） + 枚举变体条目类型数组偏移（OFF_EV_TYPES） + 类型字段索引 * 8，类型值（tval））
                令 类型字段索引 = 类型字段索引 + 1
            令 变体索引3 = 变体索引3 + 1
        令 枚举索引 = 枚举索引 + 1
    如果 版本（ver） 大于等于 2，那么：
        令 全局计数（gc） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
        令 位置（pos） = 位置（位置） + 4
        扩展 IR 全局变量数组（grow_ir_globals）（gc）
        令 IR 全局变量计数（g_ir_global_count） = 0
        令 全局索引（gi） = 0（可变）
        循环（当 全局索引 小于 全局计数（gc） 时）：
            令 名称索引（name_ni） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
            令 位置（pos） = 位置（位置） + 4
            令 变量索引（var_idx） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
            令 位置（pos） = 位置（位置） + 4
            令 初始值（init_val） = 0（可变）
            如果 版本（ver） 大于等于 4，那么：
                令 初始值（init_val） = 缓冲区读取64位整数（i64）（buf_read_i64）（数据（data），位置（pos））
                令 位置（pos） = 位置（位置） + 8
            写 64 位（w64）（IR 全局变量数组（g_ir_globals），全局索引 * 24，名称索引（name_ni））
            写 64 位（w64）（IR 全局变量数组（g_ir_globals），全局索引 * 24 + 8，变量索引（var_idx））
            写 64 位（w64）（IR 全局变量数组（g_ir_globals），全局索引 * 24 + 16，初始值（init_val））
            令 IR 全局变量计数（g_ir_global_count） = 全局索引 + 1
            令 全局索引 = 全局索引 + 1
    令 优化元数据计数（g_opt_meta_count） = 0
    如果 版本（ver） 大于等于 3，那么：
        如果 位置（pos） + 4 大于 文件大小（fsize），那么：返回 -1
        令 元数据计数（mc） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
        令 位置（pos） = 位置（位置） + 4
        令 元数据索引（mi） = 0（可变）
        循环（当 元数据索引 小于 元数据计数（mc） 时）：
            如果 位置（pos） + 8 大于 文件大小（fsize），那么：返回 -1
            令 元数据键（mk） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
            令 位置（pos） = 位置（位置） + 4
            令 数据长度（md_len） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
            令 位置（pos） = 位置（位置） + 4
            如果 数据长度（md_len） 大于 优化元数据步幅（OPT_META_STRIDE） - 8 或 位置（pos） + 数据长度（md_len） 大于 文件大小（fsize），那么：返回 -1
            扩展优化元数据数组（grow_opt_meta）（元数据索引 + 1）
            令 元数据偏移（mo） = 元数据索引 * 优化元数据步幅（OPT_META_STRIDE）
            写 32 位（w32）（优化元数据数组（g_opt_meta），元数据偏移（mo），元数据键（mk））
            写 32 位（w32）（优化元数据数组（g_opt_meta），元数据偏移（mo） + 4，数据长度（md_len））
            令 数据索引（di） = 0（可变）
            循环（当 数据索引 小于 数据长度（md_len） 时）：
                写单字节字节存储（store8）（优化元数据数组（g_opt_meta），元数据偏移（mo） + 8 + 数据索引，无符号单字节读取（load8）（数据（data），位置（pos）））
                令 位置（pos） = 位置（位置） + 1
                令 数据索引 = 数据索引 + 1
            令 优化元数据计数（g_opt_meta_count） = 元数据索引 + 1
            令 元数据索引 = 元数据索引 + 1
    如果 版本（ver） 大于等于 5，那么：
        如果 位置（pos） + 4 大于 文件大小（fsize），那么：返回 -1
        令 SG 数（sg_n） = 缓冲区读取u32（buf_read_u32）（数据（data），位置（pos））
        令 位置（pos） = 位置（位置） + 4
        如果 位置（pos） + SG 数（sg_n） * 磁盘 SG 条目大小（ESZ_SG_DISK） 大于 文件大小（fsize），那么：返回 -1
        令 SG 索引（sg_i） = 0（可变）
        循环（当 SG 索引 小于 SG 数（sg_n） 时）：
            扩展结构图数组（grow_sg）（SG 索引 + 1）
            令 SG 字段基址（f） = SG 索引 * SG 条目大小（内存）（ESZ_SG）
            写 64 位（w64）（结构图数组（g_sgs），SG 字段基址（f） + SG 条目类别偏移（OFF_SG_KIND），缓冲区读取32位整数（i32）（buf_read_i32）（数据（data），位置（pos）））
            令 位置（pos） = 位置（位置） + 4
            写 64 位（w64）（结构图数组（g_sgs），SG 字段基址（f） + SG 条目入口偏移（OFF_SG_ENTER），缓冲区读取32位整数（i32）（buf_read_i32）（数据（data），位置（pos）））
            令 位置（pos） = 位置（位置） + 4
            写 64 位（w64）（结构图数组（g_sgs），SG 字段基址（f） + SG 条目出口偏移（OFF_SG_EXIT），缓冲区读取32位整数（i32）（buf_read_i32）（数据（data），位置（pos）））
            令 位置（pos） = 位置（位置） + 4
            写 64 位（w64）（结构图数组（g_sgs），SG 字段基址（f） + SG 条目父节点偏移（OFF_SG_PARENT），缓冲区读取32位整数（i32）（buf_read_i32）（数据（data），位置（pos）））
            令 位置（pos） = 位置（位置） + 4
            写 64 位（w64）（结构图数组（g_sgs），SG 字段基址（f） + SG 条目节点起始偏移（OFF_SG_NSTART），缓冲区读取32位整数（i32）（buf_read_i32）（数据（data），位置（pos）））
            令 位置（pos） = 位置（位置） + 4
            写 64 位（w64）（结构图数组（g_sgs），SG 字段基址（f） + SG 条目节点计数偏移（OFF_SG_NCOUNT），缓冲区读取32位整数（i32）（buf_read_i32）（数据（data），位置（pos）））
            令 位置（pos） = 位置（位置） + 4
            令 SG 索引 = SG 索引 + 1
        令 结构图计数（g_sg_count） = SG 数（sg_n）
    返回 0
### 测试要点
1. 文件大小小于 36（最小头大小）时返回 -1
2. 魔数不匹配时返回 -1
3. 版本不合法（非 1-5）时返回 -1
4. 结构体字段数超过最大结构体字段数（MAX_STRUCT_FIELDS）时报错并返回 1
5. 枚举变体数超过最大枚举变体数（MAX_ENUM_VARIANTS）时报错并返回 1
6. 枚举变体类型数超过最大变体类型数（MAX_VARIANT_TYPES）时报错并返回 1
7. 版本 1 和版本 2 文件（无优化元数据段、无 SG 段）正确跳过后处理
8. 版本 4 前的文件正确加载全局变量（init_val 默认 0）
9. 版本 5 文件正确加载 SG region 段并恢复结构图计数（g_sg_count）
10. 优化元数据数据长度超过步幅或超出缓冲区末尾时返回 -1
11. SG 段总大小超出缓冲区末尾时返回 -1
12. 空数据（所有计数为 0）成功加载且不崩溃
