# dyn_arr.cr 伪代码
> 源文件：src/compiler/dyn_arr.cr（786 行）
> 功能概要：动态字节数组基础设施 —— 提供字节读写辅助函数（w8/bu8/w32/r32/w64/r64/_dyncpy）、元素大小常量（结构大小常量（ESZ_）*）和字段偏移常量（字段偏移常量（OFF_）*）、所有编译数据结构的动态数组扩容函数（grow_*，约 60 个）、AST/符号条目/IR 变量/IR 指令/函数信息/结构体信息/枚举信息的字段访问器（getter/setter）、字符串驻留系统（str_hash/hash_bytes/str_intern/istr_get/istr_len/istr_eq）。所有数组采用统一的倍增扩容策略，每元素大小和最小初始容量各异。

## 标识符对照表
| 中文名 | 原名 | 首次出现位置 |
|--------|------|-------------|
| 写单字节 | w8 | 字节辅助函数 |
| 读取无符号字节 | bu8 | 字节辅助函数 |
| 写 32 位 | w32 | 字节辅助函数 |
| 读 32 位 | r32 | 字节辅助函数 |
| 写 64 位 | w64 | 字节辅助函数 |
| 读 64 位 | r64 | 字节辅助函数 |
| 内部：动态拷贝 | _dyncpy | 内部：动态拷贝 |
| 扩展词法单元数组 | grow_tokens | 扩容函数族 |
| 扩展 AST 数组 | grow_ast | 扩容函数族 |
| 扩展符号数组 | grow_syms | 扩容函数族 |
| 扩展类型数组 | grow_types | 扩容函数族 |
| 扩展函数数组 | grow_funcs | 扩容函数族 |
| 扩展结构数组 | grow_structs | 扩容函数族 |
| 扩展枚举数组 | grow_enums | 扩容函数族 |
| 扩展接口数组 | grow_ifaces | 扩容函数族 |
| 扩展 IR 变量数组 | grow_ir_vars | 扩容函数族 |
| 扩展 IR 指令数组 | grow_ir_instrs | 扩容函数族 |
| 扩展 IR 局部变量数组 | grow_ir_locals | 扩容函数族 |
| 扩展 IR 全局变量数组 | grow_ir_globals | 扩容函数族 |
| 扩展 IR 字符串常量数组 | grow_ir_str_consts | 扩容函数族 |
| 扩展错误数组 | grow_errors | 扩容函数族 |
| 扩展代码块语句数组 | grow_block_stmts | 扩容函数族 |
| 扩展 IR 函数元数据数组 | grow_ir_func_meta | 扩容函数族 |
| AST 访问器：类别 | ast_kind | AST 节点访问器族 |
| 第一子节点访问器 | ast_a | AST 节点访问器族 |
| 第二子节点访问器 | ast_b | AST 节点访问器族 |
| 第三子节点访问器 | ast_c | AST 节点访问器族 |
| AST 访问器：整数值 | ast_int_val | AST 节点访问器族 |
| AST 访问器：类型值 | ast_type_val | AST 节点访问器族 |
| AST 访问器：数据 | ast_data | AST 节点访问器族 |
| AST 访问器：行号 | ast_line | AST 节点访问器族 |
| AST 访问器：列号 | ast_col | AST 节点访问器族 |
| AST 访问器：设置类别 | ast_set_kind | AST 节点访问器族 |
| AST 访问器：设置a | ast_set_a | AST 节点访问器族 |
| AST 访问器：设置b | ast_set_b | AST 节点访问器族 |
| AST 访问器：设置c | ast_set_c | AST 节点访问器族 |
| AST 访问器：设置整数值 | ast_set_int_val | AST 节点访问器族 |
| AST 访问器：设置类型值 | ast_set_type_val | AST 节点访问器族 |
| AST 访问器：设置数据 | ast_set_data | AST 节点访问器族 |
| AST 访问器：设置行号 | ast_set_line | AST 节点访问器族 |
| AST 访问器：设置列号 | ast_set_col | AST 节点访问器族 |
| AST 访问器：分配 | ast_alloc | AST 节点访问器族 |
| 符号名称 | sym_name | 符号条目访问器族 |
| 符号类别 | sym_kind | 符号条目访问器族 |
| 符号类型 | sym_type | 符号条目访问器族 |
| 符号节点 | sym_node | 符号条目访问器族 |
| 符号设置名称 | sym_set_name | 符号条目访问器族 |
| 符号设置类别 | sym_set_kind | 符号条目访问器族 |
| 符号设置类型 | sym_set_type | 符号条目访问器族 |
| 符号设置节点 | sym_set_node | 符号条目访问器族 |
| IR 变量访问器：名称 | irv_name | IR 变量访问器族 |
| IR 变量访问器：ID | irv_id | IR 变量访问器族 |
| IR 变量访问器：类型 | irv_type | IR 变量访问器族 |
| IR 变量访问器：设置名称 | irv_set_name | IR 变量访问器族 |
| IR 变量访问器：设置ID | irv_set_id | IR 变量访问器族 |
| IR 变量访问器：设置类型 | irv_set_type | IR 变量访问器族 |
| IR 指令访问器：操作码 | iri_op | IR 指令访问器族 |
| IR 指令访问器：目标 | iri_dest | IR 指令访问器族 |
| IR 指令访问器：操作数1 | iri_s1 | IR 指令访问器族 |
| IR 指令访问器：操作数2 | iri_s2 | IR 指令访问器族 |
| IR 指令访问器：操作数3 | iri_s3 | IR 指令访问器族 |
| IR 指令访问器：类型类别 | iri_tk | IR 指令访问器族 |
| IR 指令访问器：设置操作码 | iri_set_op | IR 指令访问器族 |
| IR 指令访问器：设置目标 | iri_set_dest | IR 指令访问器族 |
| IR 指令访问器：设置操作数1 | iri_set_s1 | IR 指令访问器族 |
| IR 指令访问器：设置操作数2 | iri_set_s2 | IR 指令访问器族 |
| IR 指令访问器：设置操作数3 | iri_set_s3 | IR 指令访问器族 |
| IR 指令访问器：设置类型类别 | iri_set_tk | IR 指令访问器族 |
| 函数信息访问器：名称 | fi_name | 函数信息访问器族 |
| 函数信息访问器：参数计数 | fi_param_count | 函数信息访问器族 |
| 函数信息访问器：返回类型 | fi_return_type | 函数信息访问器族 |
| 函数信息访问器：AST 节点 | fi_ast_node | 函数信息访问器族 |
| 函数信息访问器：泛型计数 | fi_generic_count | 函数信息访问器族 |
| 函数信息访问器：参数类型 | fi_param_type | 函数信息访问器族 |
| 函数信息访问器：泛型名称 | fi_generic_name | 函数信息访问器族 |
| 函数信息访问器：是否纯净 | fi_ispure | 函数信息访问器族 |
| 函数信息访问器：设置名称 | fi_set_name | 函数信息访问器族 |
| 函数信息访问器：设置参数计数 | fi_set_param_count | 函数信息访问器族 |
| 函数信息访问器：设置参数类型 | fi_set_param_type | 函数信息访问器族 |
| 函数信息访问器：设置返回类型 | fi_set_return_type | 函数信息访问器族 |
| 函数信息访问器：设置ast节点 | fi_set_ast_node | 函数信息访问器族 |
| 函数信息访问器：设置泛型名称 | fi_set_generic_name | 函数信息访问器族 |
| 函数信息访问器：设置泛型计数 | fi_set_generic_count | 函数信息访问器族 |
| 函数信息访问器：设置是否纯净 | fi_set_ispure | 函数信息访问器族 |
| 结构体信息访问器：名称 | si_name | 结构体信息访问器族 |
| 结构体信息访问器：字段计数 | si_field_count | 结构体信息访问器族 |
| 结构体信息访问器：泛型计数 | si_generic_count | 结构体信息访问器族 |
| 结构体信息访问器：字段名称 | si_field_name | 结构体信息访问器族 |
| 结构体信息访问器：字段类型 | si_field_type | 结构体信息访问器族 |
| 结构体信息访问器：字段类型节点 | si_field_type_node | 结构体信息访问器族 |
| 结构体信息访问器：泛型名称 | si_generic_name | 结构体信息访问器族 |
| 枚举信息访问器：名称 | ei_name | 枚举信息访问器族 |
| 枚举信息访问器：变体计数 | ei_variant_count | 枚举信息访问器族 |
| 枚举信息访问器：泛型计数 | ei_generic_count | 枚举信息访问器族 |
| 枚举信息访问器：泛型名称 | ei_generic_name | 枚举信息访问器族 |
| 枚举信息访问器：变体名称 | ei_variant_name | 枚举信息访问器族 |
| 枚举信息访问器：变体类型 | ei_variant_type | 枚举信息访问器族 |
| 枚举信息访问器：变体类型计数 | ei_variant_type_count | 枚举信息访问器族 |
| 扩展全局字符串数组 | grow_g_strs | 字符串表函数 |
| 字符串哈希 | str_hash | 字符串表函数 |
| 哈希字节序列 | hash_bytes | 字符串表函数 |
| 内部：扩展字符串哈希表 | _grow_str_hash | 字符串表函数 |
| 字符串驻留 | str_intern | 字符串表函数 |
| 驻留字符串获取 | istr_get | 字符串表函数 |
| 驻留字符串长度 | istr_len | 字符串表函数 |
| 字符串按字节读取 | str_load8 | 字符串表函数 |
| 驻留字符串相等比较 | istr_eq | 字符串表函数 |
| 字符串相等比较 | str_eq | 字符串驻留 |
| 字符串长度 | str_len | 驻留字符串长度 |

（其余约 50 个 扩容函数（grow） 函数和约 15 个 x86 后端数组扩容函数因篇幅原因不再逐个列出，其命名对照见全局术语表。）

## 全局状态

本文件定义了约 60+ 个全局变量的扩容函数，涉及的全局数组与对应容量变量包括：词法单元数组（g_tokens）/词法单元容量（g_tok_cap）, AST 节点数组（g_ast）/AST 节点容量（g_ast_cap）/AST 节点计数（g_ast_count）, 符号数组（g_syms）/符号容量（g_sym_cap）, 类型数组（g_types）/类型容量（g_type_cap）, 函数数组（g_funcs）/函数数组容量（g_func_cap）, 结构体数组（g_structs）/结构体容量（g_struct_cap）, 枚举数组（g_enums）/枚举容量（g_enum_cap）, 接口数组（g_ifaces）/接口容量（g_iface_cap）, IR 变量数组（g_ir_vars）/IR 变量容量（g_ir_var_cap）, IR 指令数组（g_ir_instrs）/IR 指令容量（g_ir_instr_cap）, IR 局部变量数组（g_ir_locals）/IR 局部变量容量（g_ir_local_cap）, IR 全局变量数组（g_ir_globals）/IR 全局变量容量（g_ir_global_cap）, IR 字符串常量数组（g_ir_str_consts）/IR 字符串常量容量（g_ir_str_const_cap）, 错误数组（g_errors）/错误数组容量（g_err_cap）, 代码块语句数组（g_block_stmts）/代码块语句容量（g_block_stmt_cap）, IR 函数名索引数组（g_ir_func_name_idx）/IR 函数返回类型数组（g_ir_func_ret_type）/IR 函数指令起始索引数组（g_ir_func_instr_start）/IR 函数指令计数数组（g_ir_func_instr_count）/IR 函数变量起始索引数组（g_ir_func_var_start）/IR 函数变量计数数组（g_ir_func_var_count）/IR 函数参数计数数组（g_ir_func_param_count） 及各 容量变量后缀（_cap）, 字符串常量数组（g_strs）/字符串常量容量（g_str_cap）/字符串常量计数（g_str_count）/字符串哈希表（g_str_hash）/字符串哈希表容量（g_str_hash_cap）, x86 后端各数组及其 容量变量后缀/计数变量后缀（_count）, 行文件 ID 数组（g_line_fileid）/行数组容量（g_line_cap）, 段起始索引数组（g_seg_starts）/段文件 ID 数组（g_seg_fileids）/段容量（g_seg_cap）, 泛型应用数据数组（g_gen_apply_data）/泛型应用数据容量（g_gen_apply_data_cap）, 数据流节点数组（g_df_nodes）/数据流节点数组容量（g_df_node_cap）, 数据流节点所属 region（g_df_node_region）/数据流节点 region 映射容量（g_df_node_region_cap）, 数据流边数组（g_df_edges）/数据流边数组容量（g_df_edge_cap）, 变量生产者节点映射（g_df_var_producer）/HDFG各函数节点起始索引（g_df_func_node_start）/HDFG各函数节点计数（g_df_func_node_count）/HDFG数组容量（g_df_cap）, 泛型映射名数组（g_gen_map_names）/泛型映射类型数组（g_gen_map_types）/泛型映射容量（g_gen_map_cap）, 借用变量数组（g_borrow_vars）/借用引用数组（g_borrow_refs）/借用可变标记数组（g_borrow_muts）/借用数组容量（g_borrow_cap）, 持有者-借用者（g_holder_borrowers）/持有者-被借数（g_holder_borrowed）/持有者可变标记（g_holder_is_mut）/持有者容量（g_holder_cap）, 全局声明数组（g_global_lets）/全局声明容量（g_global_lets_cap）, 循环标签栈（g_loop_stack）/循环栈容量（g_loop_stack_cap）, 类型别名数组（g_type_aliases）/类型别名容量（g_type_alias_cap）, 作用域边界数组（g_scope_bounds）/作用域边界容量（g_scope_bounds_cap）, 方法数组（g_methods）/方法容量（g_method_cap）, 借用作用域标记（g_borrow_scope_markers）/借用作用域标记容量（g_borrow_scope_markers_cap）, 优化元数据数组（g_opt_meta）/优化元数据容量（g_opt_meta_cap）/优化元数据计数（g_opt_meta_count）, 诊断数组（g_diags）/诊断容量（g_diag_cap）, 文件数组（g_files）/文件数组容量（g_file_cap）, 模块数组（g_mods）/模块容量（g_mod_cap）, 模块函数文件 ID 数组（g_mod_func_fileids）/模块函数名数组（g_mod_func_names）/模块函数类型索引数组（g_mod_func_tis）/模块函数容量（g_mod_func_cap）, 模块路径名数组（g_mod_path_names）/模块路径容量（g_mod_path_cap）, 接口实现数组（g_impl_for）/接口实现容量（g_impl_for_cap）, 泛型参数数组（g_gen_params）/泛型参数容量（g_gen_param_cap）, 泛型约束数组（g_generic_constr）/泛型约束容量（g_generic_constr_cap）, 结构图数组（g_sgs）/结构图数组容量（g_sg_cap）, 指针集数组（g_pts）/指针集容量（g_pts_cap）, 偏移量数组（g_offsets）/偏移量容量（g_offsets_cap）, 标签位置数组（g_label_poses）/标签容量（g_label_cap），以及所有 x86 后端相关数组。（完整全局变量列表见标识符对照表和 globals.cr。）

## 字节辅助函数

### 函数 写单字节（w8）
签名：`函数 写单字节（w8）（缓冲区（buf）：字符串，位置（pos）：整数，值（val）：整数）`
### 作用
向字节缓冲区的指定位置写入一个字节值，自动取模 256 确保值在 0-255 范围内。
### 逻辑
    将 值（val） 模 256 的结果通过存储单字节写入 缓冲区（buf） 的 位置（pos） 位置。
### 测试要点
1. 负数值被取模 256 后正确写入

### 函数 读取无符号字节（bu8）
签名：`函数 读取无符号字节（bu8）（缓冲区（buf）：字符串，位置（pos）：整数）-> 整数`
### 作用
从字节缓冲区的指定位置读取一个字节，返回无符号值（取模 256）。
### 逻辑
    从 缓冲区（buf） 的 位置（pos） 位置加载单字节，返回其模 256 的结果。
### 测试要点
1. 返回值始终在 0-255 范围内

### 函数 写 32 位（w32）
签名：`函数 写 32 位（w32）（缓冲区（buf）：字符串，位置（pos）：整数，值（val）：整数）`
### 作用
将 32 位整数以小端字节序写入缓冲区。使用借位链（borrow chain）处理负数的二进制补码表示，确保每字节落在 0-255 内。
### 逻辑
    将 值（val） 依次除以 256 分解为 4 个字节（字节0（b0）=最低字节, 字节1（b1）, 字节2（b2）, 字节3（b3）=最高字节）。
    如果 字节0（b0） 小于 0，那么：令 字节0 = 字节0 + 256；令 字节1（b1） = 字节1 - 1（从下一字节借位）
    如果 字节1（b1） 小于 0，那么：令 字节1 = 字节1 + 256；令 字节2（b2） = 字节2 - 1
    如果 字节2（b2） 小于 0，那么：令 字节2 = 字节2 + 256；令 字节3（b3） = 字节3 - 1
    如果 字节3（b3） 小于 0，那么：令 字节3 = 字节3 + 256（最高字节无更高位可借，直接加 256）
    按小端序依次将 字节0（b0）, 字节1（b1）, 字节2（b2）, 字节3（b3） 通过存储单字节写入 缓冲区（buf） 的 位置（pos）, 位置+1, 位置+2, 位置+3。
### 测试要点
1. 正值正常按小端序写入 4 字节
2. 负数通过借位链正确转换为补码表示
3. 最高字节 字节3（b3） 为负时直接加 256 修正

### 函数 读 32 位（r32）
签名：`函数 读 32 位（r32）（缓冲区（buf）：字符串，位置（pos）：整数）-> 整数`
### 作用
从缓冲区以小端序读取 32 位有符号整数。最高字节 字节3（b3） 大于等于 128 时视为负数的二进制补码高位，通过 字节3 - 256 实现符号扩展。
### 逻辑
    从 缓冲区（buf） 的 位置（pos）, 位置+1, 位置+2, 位置+3 分别读取 4 个无符号字节 字节0（b0）, 字节1（b1）, 字节2（b2）, 字节3（b3）。
    计算 基础值（v）= 字节0（b0） + 字节1（b1） * 256 + 字节2（b2） * 65536。
    如果 字节3（b3） 大于等于 128，那么：令 基础值 = 基础值 + （字节3 - 256） * 16777216（负数符号扩展）
    否则：令 基础值 = 基础值 + 字节3（b3） * 16777216（正数直接计算）
    返回 基础值。
### 测试要点
1. 正数（字节3（b3） 小于 128）正常计算
2. 负数（字节3（b3） 大于等于 128）通过 字节3（b3） - 256 进行符号扩展

### 函数 写 64 位（w64）
签名：`函数 写 64 位（w64）（缓冲区（buf）：字符串，位置（pos）：整数，值（val）：整数）`
### 作用
将 64 位整数以小端字节序写入缓冲区。逐字节处理：每轮取当前剩余值的模 256 作为当前字节，然后通过 （当前剩余值 - 当前字节） / 256 推进到下一轮，自动正确处理负数。
### 逻辑
    令 当前剩余值（cur）= 值（val）（可变）
    令 字节索引（i）= 0
    循环（当 字节索引 小于 8 时）：
        令 当前字节（byte）= 当前剩余值 模 256
        如果 当前字节 小于 0，那么：令 当前字节 = 当前字节 + 256
        存储单字节（缓冲区（buf）, 位置（pos） + 字节索引, 当前字节）
        令 当前剩余值 = （当前剩余值 - 当前字节） / 256
        令 字节索引 = 字节索引 + 1
### 测试要点
1. 小端序逐字节写入共 8 字节
2. 负数每字节通过加 256 修正后写入
3. 余数通过 （cur - byte） / 256 正确传播到高位字节

### 函数 读 64 位（r64）
签名：`函数 读 64 位（r64）（缓冲区（buf）：字符串，位置（pos）：整数）-> 整数`
### 作用
从缓冲区以小端序读取 64 位整数。低 32 位通过读 32 位（r32）直接读取，高 32 位同样通过读 32 位（r32）读取后乘以 2^32（分两次乘 65536 避免溢出）再与低 32 位相加。
### 逻辑
    令 低 32 位（lo）= 读 32 位（r32）（缓冲区（buf）, 位置（pos））
    令 高 32 位（hi）= 读 32 位（r32）（缓冲区（buf）, 位置（pos） + 4）
    令 高位部分（hi_part）= 高 32 位 * 65536
    令 高位部分 = 高位部分 * 65536（等价于 hi * 2^32）
    返回 低 32 位 + 高位部分。
### 测试要点
1. 低 32 位直接通过 读 32 位（r32） 读取
2. 高 32 位通过两次乘 65536 实现乘以 2^32 的放大

## 函数 内部：动态拷贝（_dyncpy）
签名：`函数 内部：动态拷贝（_dyncpy）（源缓冲区（src）：字符串，字节数（nbytes）：整数，目标缓冲区（dst）：字符串）`
### 作用
将源缓冲区的前 字节数（nbytes） 字节逐字节拷贝到目标缓冲区。
### 逻辑
    令 拷贝索引（ci）= 0
    循环（当 拷贝索引 小于 字节数（nbytes） 时）：
        写单字节（w8）（dst, 拷贝索引, 读取无符号字节（bu8）（src, 拷贝索引））
        令 拷贝索引 = 拷贝索引 + 1
### 测试要点
1. 字节数（nbytes） 等于 0 时循环不执行，无操作
2. 逐字节拷贝 字节数（nbytes） 个字节，源与目标缓冲区若重叠则行为未定义（通常用于扩容后旧缓冲区到新缓冲区的拷贝，两者不重叠）

## 扩容函数族（grow_*）

所有单数组 扩容函数（grow） 函数遵循统一的倍增扩容模式：
1. 如果当前需求 需求（needed） 未超过容量变量，直接返回
2. 新容量 = 当前容量 * 2
3. 确保新容量大于等于最小初始容量
4. 确保新容量大于等于 需求（needed） + 余量
5. 分配新缓冲区（容量 * 每元素字节数）
6. 调用 内部：动态拷贝（_dyncpy）将旧数据拷贝到新缓冲区
7. 更新全局数组指针和容量变量为新值

### 单数组扩容函数通用模式伪代码
    函数 <扩容函数名>（需要的索引（needed）：整数）：
        如果 需求（needed） 小于 <容量变量>，那么：返回
        令 新容量（nc）= <容量变量> * 2
        如果 新容量 小于 <最小初始容量>，那么：令 新容量 = <最小初始容量>
        如果 新容量 小于 需求（needed），那么：令 新容量 = 需求 + <余量>
        令 新缓冲区（nb）= 分配内存（新容量 * <每元素字节数>）
        内部：动态拷贝（<数组变量>, <容量变量> * <每元素字节数>, 新缓冲区）
        令 <数组变量> = 新缓冲区
        令 <容量变量> = 新容量

### 各单数组扩容函数的具体参数表

| 函数 | 数组变量 | 容量变量 | 每元素字节数 | 最小初始容量 | 余量 |
|------|---------|---------|-------------|-------------|------|
| 扩展词法单元数组（grow_tokens） | g_tokens（词法单元数组） | g_tok_cap（词法单元容量） | ESZ_TOKEN （40） | 128 | 128 |
| 扩展 AST 数组（grow_ast） | g_ast（AST 节点数组） | g_ast_cap（AST 节点容量） | ESZ_ASTNODE （72） | 128 | 128 |
| 扩展符号数组（grow_syms） | g_syms（符号数组） | g_sym_cap（符号容量） | ESZ_SYMENTRY （32） | 64 | 64 |
| 扩展类型数组（grow_types） | g_types（类型数组） | g_type_cap（类型容量） | 24 | 64 | 64 |
| 扩展函数数组（grow_funcs） | g_funcs（函数数组） | g_func_cap（函数数组容量） | ESZ_FUNCINFO （208） | 64 | 64 |
| 扩展结构数组（grow_structs） | g_structs（结构体数组） | g_struct_cap（结构体容量） | ESZ_STRUCTINFO （440） | 32 | 32 |
| 扩展枚举数组（grow_enums） | g_enums（枚举数组） | g_enum_cap（枚举容量） | ESZ_ENUMINFO （2360） | 16 | 16 |
| 扩展接口数组（grow_ifaces） | g_ifaces（接口数组） | g_iface_cap（接口容量） | ESZ_IFACEINFO （1432） | 4 | 4 |
| 扩展 IR 变量数组（grow_ir_vars） | g_ir_vars（IR 变量数组） | g_ir_var_cap（IR 变量容量） | ESZ_IRVAR （24） | 128 | 128 |
| 扩展 IR 指令数组（grow_ir_instrs） | g_ir_instrs（IR 指令数组） | g_ir_instr_cap（IR 指令容量） | ESZ_IRINSTR （48） | 128 | 128 |
| 扩展 IR 局部变量数组（grow_ir_locals） | g_ir_locals（IR 局部变量数组） | g_ir_local_cap（IR 局部变量容量） | 16 | 64 | 64 |
| 扩展 IR 全局变量数组（grow_ir_globals） | g_ir_globals（IR 全局变量数组） | g_ir_global_cap（IR 全局变量容量） | 24 | 16 | 16 |
| 扩展 IR 字符串常量数组（grow_ir_str_consts） | g_ir_str_consts（IR 字符串常量数组） | g_ir_str_const_cap（IR 字符串常量容量） | 8 | 64 | 64 |
| 扩展错误数组（grow_errors） | g_errors（错误数组） | g_err_cap（错误数组容量） | 8 | 16 | 16 |
| 扩展代码块语句数组（grow_block_stmts） | g_block_stmts（代码块语句数组） | g_block_stmt_cap（代码块语句容量） | 8 | 64 | 64 |

### 函数 扩展 IR 函数元数据数组（grow_ir_func_meta）
签名：`函数 扩展 IR 函数元数据数组（grow_ir_func_meta）（需要的索引（needed）：整数）`
### 作用
同时扩容 7 个 IR 函数元数据并行数组（名称索引、返回类型、指令起始、指令计数、变量起始、变量计数、参数计数），所有数组使用相同的容量值。每个数组独立分配新缓冲区并拷贝旧数据。
### 逻辑
    如果 需求（needed） 小于 IR 函数名索引容量（g_ir_func_name_idx_cap）（IR 函数名索引容量），那么：返回
    （源码中此处有两次相同的边界检查——疑似笔误冗余）

    令 新容量（nc）= IR 函数名索引容量（g_ir_func_name_idx_cap） * 2
    如果 新容量 小于 64，那么：令 新容量 = 64
    如果 新容量 小于 需求（needed），那么：令 新容量 = 需求 + 64
    令 单个数组字节数（sz）= 新容量 * 8

    （依次为 7 个数组分配新缓冲区并拷贝旧数据）
    令 新名索数组（n1）= 分配内存（单个数组字节数）
    内部：动态拷贝（_dyncpy）（g_ir_func_name_idx（IR 函数名索引数组）, g_ir_func_name_idx_cap * 8, 新名索数组）
    令 IR 函数名索引数组（g_ir_func_name_idx） = 新名索数组

    令 新返回类型数组（n2）= 分配内存（单个数组字节数）
    内部：动态拷贝（g_ir_func_ret_type（IR 函数返回类型数组）, g_ir_func_ret_type_cap（IR 函数返回类型容量）* 8, 新返回类型数组）
    令 IR 函数返回类型数组（g_ir_func_ret_type） = 新返回类型数组

    令 新指令起始数组（n3）= 分配内存（单个数组字节数）
    内部：动态拷贝（g_ir_func_instr_start（IR 函数指令起始索引数组）, g_ir_func_instr_start_cap（IR 函数指令起始索引容量）* 8, 新指令起始数组）
    令 IR 函数指令起始索引数组（g_ir_func_instr_start） = 新指令起始数组

    令 新指令计数数组（n4）= 分配内存（单个数组字节数）
    内部：动态拷贝（g_ir_func_instr_count（IR 函数指令计数数组）, g_ir_func_instr_count_cap（IR 函数指令计数容量）* 8, 新指令计数数组）
    令 IR 函数指令计数数组（g_ir_func_instr_count） = 新指令计数数组

    令 新变量起始数组（n5）= 分配内存（单个数组字节数）
    内部：动态拷贝（g_ir_func_var_start（IR 函数变量起始索引数组）, g_ir_func_var_start_cap（IR 函数变量起始索引容量）* 8, 新变量起始数组）
    令 IR 函数变量起始索引数组（g_ir_func_var_start） = 新变量起始数组

    令 新变量计数数组（n6）= 分配内存（单个数组字节数）
    内部：动态拷贝（g_ir_func_var_count（IR 函数变量计数数组）, g_ir_func_var_count_cap（IR 函数变量计数容量）* 8, 新变量计数数组）
    令 IR 函数变量计数数组（g_ir_func_var_count） = 新变量计数数组

    令 新参数计数数组（n7）= 分配内存（单个数组字节数）
    内部：动态拷贝（g_ir_func_param_count（IR 函数参数计数数组）, g_ir_func_param_count_cap（IR 函数参数计数容量）* 8, 新参数计数数组）
    令 IR 函数参数计数数组（g_ir_func_param_count） = 新参数计数数组

    （统一更新所有容量变量为 新容量）
    令 IR 函数名索引容量（g_ir_func_name_idx_cap） = 新容量
    令 IR 函数返回类型容量（g_ir_func_ret_type_cap） = 新容量
    令 IR 函数指令起始索引容量（g_ir_func_instr_start_cap） = 新容量
    令 IR 函数指令计数容量（g_ir_func_instr_count_cap） = 新容量
    令 IR 函数变量起始索引容量（g_ir_func_var_start_cap） = 新容量
    令 IR 函数变量计数容量（g_ir_func_var_count_cap） = 新容量
    令 IR 函数参数计数容量（g_ir_func_param_count_cap） = 新容量
### 测试要点
1. 7 个数组同步扩容到相同的 新容量
2. 各数组独立分配并拷贝旧数据
3. 所有 容量变量后缀（_cap） 变量统一更新
4. 开头的双重边界检查（两次相同的 如果（if） 语句）疑似笔误

## AST 节点访问器族

所有 AST 节点访问器从 AST 节点数组（g_ast）（AST 节点数组）按偏移公式 `节点索引 数量（n） * ESZ_ASTNODE（72） + OFF_AS_<字段>` 读取或写入 64 位值。读取器返回 读 64 位（r64）结果，写入器通过 写 64 位（w64）修改对应字段。

| 函数 | 操作 | 逻辑描述 |
|------|------|----------|
| AST 访问器：类别（ast_kind） | 读 | 返回 读 64 位（g_ast, n * 72 + OFF_AS_KIND（0）） |
| 第一子节点访问器（ast_a） | 读 | 返回 读 64 位（g_ast, n * 72 + OFF_AS_A（8）） |
| 第二子节点访问器（ast_b） | 读 | 返回 读 64 位（g_ast, n * 72 + OFF_AS_B（16）） |
| 第三子节点访问器（ast_c） | 读 | 返回 读 64 位（g_ast, n * 72 + OFF_AS_C（24）） |
| AST 访问器：整数值（ast_int_val） | 读 | 返回 读 64 位（g_ast, n * 72 + OFF_AS_INTVAL（32）） |
| AST 访问器：类型值（ast_type_val） | 读 | 返回 读 64 位（g_ast, n * 72 + OFF_AS_TYPEVAL（40）） |
| AST 访问器：数据（ast_data） | 读 | 返回 读 64 位（g_ast, n * 72 + OFF_AS_DATA（48）） |
| AST 访问器：行号（ast_line） | 读 | 返回 读 64 位（g_ast, n * 72 + OFF_AS_LINE（56）） |
| AST 访问器：列号（ast_col） | 读 | 返回 读 64 位（g_ast, n * 72 + OFF_AS_COL（64）） |
| AST 访问器：设置类别（ast_set_kind） | 写 | 写 64 位（g_ast, n * 72 + 0, v） |
| AST 访问器：设置a（ast_set_a） | 写 | 写 64 位（g_ast, n * 72 + 8, v） |
| AST 访问器：设置b（ast_set_b） | 写 | 写 64 位（g_ast, n * 72 + 16, v） |
| AST 访问器：设置c（ast_set_c） | 写 | 写 64 位（g_ast, n * 72 + 24, v） |
| AST 访问器：设置整数值（ast_set_int_val） | 写 | 写 64 位（g_ast, n * 72 + 32, v） |
| AST 访问器：设置类型值（ast_set_type_val） | 写 | 写 64 位（g_ast, n * 72 + 40, v） |
| AST 访问器：设置数据（ast_set_data） | 写 | 写 64 位（g_ast, n * 72 + 48, v） |
| AST 访问器：设置行号（ast_set_line） | 写 | 写 64 位（g_ast, n * 72 + 56, v） |
| AST 访问器：设置列号（ast_set_col） | 写 | 写 64 位（g_ast, n * 72 + 64, v） |

### 函数 AST 访问器：分配（ast_alloc）
签名：`函数 AST 访问器：分配（ast_alloc）（类别（kind）：整数，变量甲（a）：整数，变量乙（b）：整数，变量丙（c）：整数，整数值（iv）：整数，类型值（tv）：整数，数据（d）：整数，行号（line）：整数，列号（col）：整数）-> 整数`
### 作用
在 AST 节点数组（g_ast） 数组末尾分配一个新的 AST 节点，写入全部 9 个字段，递增 AST 节点计数（g_ast_count）（AST 节点计数），返回新节点的索引。
### 逻辑
    令 新节点索引（idx）= AST 节点计数（g_ast_count）（AST 节点计数）
    扩展AST 数组（ast）（grow_ast）（新节点索引 + 1）（确保容量足够）

    写 64 位（w64）（g_ast, 新节点索引 * 72 + OFF_AS_KIND（0）, 类别（kind））
    写 64 位（g_ast, 新节点索引 * 72 + OFF_AS_A（8）, 变量甲（a））
    写 64 位（g_ast, 新节点索引 * 72 + OFF_AS_B（16）, 变量乙（b））
    写 64 位（g_ast, 新节点索引 * 72 + OFF_AS_C（24）, 变量丙（c））
    写 64 位（g_ast, 新节点索引 * 72 + OFF_AS_INTVAL（32）, iv）
    写 64 位（g_ast, 新节点索引 * 72 + OFF_AS_TYPEVAL（40）, 元组索引值（tv））
    写 64 位（g_ast, 新节点索引 * 72 + OFF_AS_DATA（48）, d）
    写 64 位（g_ast, 新节点索引 * 72 + OFF_AS_LINE（56）, line）
    写 64 位（g_ast, 新节点索引 * 72 + OFF_AS_COL（64）, col）

    令 AST 节点计数（g_ast_count） = 新节点索引 + 1
    返回 新节点索引
### 测试要点
1. 先扩容再写入，确保索引有效
2. 返回值为新节点的索引（等于扩容前的 count）
3. AST 节点计数（g_ast_count） 递增 1

## 符号条目访问器族

所有 符号条目（SymEntry） 访问器在 符号数组（g_syms）（符号数组）上操作，偏移公式为 `索引 数量（n） * ESZ_SYMENTRY（32） + OFF_SY_<字段>`。每个访问器为独立的 1-2 行函数。

| 函数 | 操作 | 逻辑描述 |
|------|------|----------|
| 符号名称（sym_name） | 读 | 返回 读 64 位（g_syms, n * 32 + OFF_SY_NAME（0）） |
| 符号类别（sym_kind） | 读 | 返回 读 64 位（g_syms, n * 32 + OFF_SY_KIND（8）） |
| 符号类型（sym_type） | 读 | 返回 读 64 位（g_syms, n * 32 + OFF_SY_TYPE（16）） |
| 符号节点（sym_node） | 读 | 返回 读 64 位（g_syms, n * 32 + OFF_SY_NODE（24）） |
| 符号设置名称（sym_set_name） | 写 | 写 64 位（g_syms, n * 32 + 0, v） |
| 符号设置类别（sym_set_kind） | 写 | 写 64 位（g_syms, n * 32 + 8, v） |
| 符号设置类型（sym_set_type） | 写 | 写 64 位（g_syms, n * 32 + 16, v） |
| 符号设置节点（sym_set_node） | 写 | 写 64 位（g_syms, n * 32 + 24, v） |

## IR 变量访问器族

所有 IR 变量（IRVar） 访问器在 IR 变量数组（g_ir_vars）（IR 变量数组）上操作，偏移公式为 `索引 数量（n） * ESZ_IRVAR（24） + OFF_IRV_<字段>`。

| 函数 | 操作 | 逻辑描述 |
|------|------|----------|
| IR 变量访问器：名称（irv_name） | 读 | 返回 读 64 位（g_ir_vars, n * 24 + OFF_IRV_NAME（0）） |
| IR 变量访问器：ID（irv_id） | 读 | 返回 读 64 位（g_ir_vars, n * 24 + OFF_IRV_ID（8）） |
| IR 变量访问器：类型（irv_type） | 读 | 返回 读 64 位（g_ir_vars, n * 24 + OFF_IRV_TYPE（16）） |
| IR 变量访问器：设置名称（irv_set_name） | 写 | 写 64 位（g_ir_vars, n * 24 + 0, v） |
| IR 变量访问器：设置ID（irv_set_id） | 写 | 写 64 位（g_ir_vars, n * 24 + 8, v） |
| IR 变量访问器：设置类型（irv_set_type） | 写 | 写 64 位（g_ir_vars, n * 24 + 16, v） |

## IR 指令访问器族

所有 IR 指令（IRInstr） 访问器在 IR 指令数组（g_ir_instrs）（IR 指令数组）上操作，偏移公式为 `指令索引 数量（n） * ESZ_IRINSTR（48） + OFF_IRI_<字段>`。

| 函数 | 操作 | 逻辑描述 |
|------|------|----------|
| IR 指令访问器：操作码（iri_op） | 读 | 返回 读 64 位（g_ir_instrs, n * 48 + OFF_IRI_OP（0）） |
| IR 指令访问器：目标（iri_dest） | 读 | 返回 读 64 位（g_ir_instrs, n * 48 + OFF_IRI_DEST（8）） |
| IR 指令访问器：操作数1（iri_s1） | 读 | 返回 读 64 位（g_ir_instrs, n * 48 + OFF_IRI_S1（16）） |
| IR 指令访问器：操作数2（iri_s2） | 读 | 返回 读 64 位（g_ir_instrs, n * 48 + OFF_IRI_S2（24）） |
| IR 指令访问器：操作数3（iri_s3） | 读 | 返回 读 64 位（g_ir_instrs, n * 48 + OFF_IRI_S3（32）） |
| IR 指令访问器：类型类别（iri_tk） | 读 | 返回 读 64 位（g_ir_instrs, n * 48 + OFF_IRI_TK（40）） |
| IR 指令访问器：设置操作码（iri_set_op） | 写 | 写 64 位（g_ir_instrs, n * 48 + 0, v） |
| IR 指令访问器：设置目标（iri_set_dest） | 写 | 写 64 位（g_ir_instrs, n * 48 + 8, v） |
| IR 指令访问器：设置操作数1（iri_set_s1） | 写 | 写 64 位（g_ir_instrs, n * 48 + 16, v） |
| IR 指令访问器：设置操作数2（iri_set_s2） | 写 | 写 64 位（g_ir_instrs, n * 48 + 24, v） |
| IR 指令访问器：设置操作数3（iri_set_s3） | 写 | 写 64 位（g_ir_instrs, n * 48 + 32, v） |
| IR 指令访问器：设置类型类别（iri_set_tk） | 写 | 写 64 位（g_ir_instrs, n * 48 + 40, v） |

## 函数信息访问器族

所有 函数信息（FuncInfo） 访问器在 函数数组（g_funcs）（函数数组）上操作，偏移公式为 `索引 数量（n） * ESZ_FUNCINFO（208） + OFF_FI_<字段>`。带子索引的访问器（如参数类型、泛型名称）在基偏移上加 `子索引 * 8`。

| 函数 | 操作 | 逻辑描述 |
|------|------|----------|
| 函数信息访问器：名称（fi_name） | 读 | 返回 读 64 位（g_funcs, n * 208 + OFF_FI_NAME（0）） |
| 函数信息访问器：参数计数（fi_param_count） | 读 | 返回 读 64 位（g_funcs, n * 208 + OFF_FI_PARAM_COUNT（8）） |
| 函数信息访问器：返回类型（fi_return_type） | 读 | 返回 读 64 位（g_funcs, n * 208 + OFF_FI_RETURN_TYPE（144）） |
| 函数信息访问器：AST 节点（fi_ast_node） | 读 | 返回 读 64 位（g_funcs, n * 208 + OFF_FI_AST_NODE（152）） |
| 函数信息访问器：泛型计数（fi_generic_count） | 读 | 返回 读 64 位（g_funcs, n * 208 + OFF_FI_GENERIC_COUNT（192）） |
| 函数信息访问器：是否纯净（fi_ispure） | 读 | 返回 读 64 位（g_funcs, n * 208 + OFF_FI_ISPURE（200）） |
| 函数信息访问器：参数类型（fi_param_type） | 读 | 返回 读 64 位（g_funcs, n * 208 + OFF_FI_PARAM_TYPES（16） + pi * 8） |
| 函数信息访问器：泛型名称（fi_generic_name） | 读 | 返回 读 64 位（g_funcs, n * 208 + OFF_FI_GENERIC_NAMES（160） + gi * 8） |
| 函数信息访问器：设置名称（fi_set_name） | 写 | 写 64 位（g_funcs, n * 208 + 0, v） |
| 函数信息访问器：设置参数计数（fi_set_param_count） | 写 | 写 64 位（g_funcs, n * 208 + 8, v） |
| 函数信息访问器：设置参数类型（fi_set_param_type） | 写 | 写 64 位（g_funcs, n * 208 + 16 + pi * 8, v） |
| 函数信息访问器：设置返回类型（fi_set_return_type） | 写 | 写 64 位（g_funcs, n * 208 + 144, v） |
| 函数信息访问器：设置ast节点（fi_set_ast_node） | 写 | 写 64 位（g_funcs, n * 208 + 152, v） |
| 函数信息访问器：设置泛型名称（fi_set_generic_name） | 写 | 写 64 位（g_funcs, n * 208 + 160 + gi * 8, v） |
| 函数信息访问器：设置泛型计数（fi_set_generic_count） | 写 | 写 64 位（g_funcs, n * 208 + 192, v） |
| 函数信息访问器：设置是否纯净（fi_set_ispure） | 写 | 写 64 位（g_funcs, n * 208 + 200, v） |

### 测试要点（访问器族通用）
1. 各访问器使用正确的 结构大小常量（ESZ_）* 和 字段偏移常量（OFF_）* 偏移常量
2. 读访问器直接返回 读 64 位（r64） 结果（无边界检查）
3. 写访问器无返回值

## 结构体信息访问器族

所有 结构体信息（StructInfo） 访问器在 结构体数组（g_structs）（结构体数组）上操作，偏移公式为 `索引 数量（n） * 结构信息大小（ESZ_STRUCTINFO）（440） + OFF_SI_<字段>`。均为只读访问器。

| 函数 | 逻辑描述 |
|------|----------|
| 结构体信息访问器：名称（si_name） | 返回 读 64 位（g_structs, n * 440 + OFF_SI_NAME（0）） |
| 结构体信息访问器：字段计数（si_field_count） | 返回 读 64 位（g_structs, n * 440 + OFF_SI_FIELD_COUNT（392）） |
| 结构体信息访问器：泛型计数（si_generic_count） | 返回 读 64 位（g_structs, n * 440 + OFF_SI_GENERIC_COUNT（432）） |
| 结构体信息访问器：字段名称（si_field_name） | 返回 读 64 位（g_structs, n * 440 + OFF_SI_FIELD_NAMES（8） + fi * 8） |
| 结构体信息访问器：字段类型（si_field_type） | 返回 读 64 位（g_structs, n * 440 + OFF_SI_FIELD_TYPES（136） + fi * 8） |
| 结构体信息访问器：字段类型节点（si_field_type_node） | 返回 读 64 位（g_structs, n * 440 + OFF_SI_FIELD_TYPE_NODES（264） + fi * 8） |
| 结构体信息访问器：泛型名称（si_generic_name） | 返回 读 64 位（g_structs, n * 440 + OFF_SI_GENERIC_NAMES（400） + gi * 8） |

## 枚举信息访问器族

所有 枚举信息（EnumInfo） 访问器在 枚举数组（g_enums）（枚举数组）上操作，偏移公式为 `索引 数量（n） * 枚举信息大小（ESZ_ENUMINFO）（2360） + OFF_EI_<字段>`。变体访问器额外加 `变体索引 * OFF_EV_SIZE（144）`。

| 函数 | 逻辑描述 |
|------|----------|
| 枚举信息访问器：名称（ei_name） | 返回 读 64 位（g_enums, n * 2360 + OFF_EI_NAME（0）） |
| 枚举信息访问器：变体计数（ei_variant_count） | 返回 读 64 位（g_enums, n * 2360 + OFF_EI_VARIANT_COUNT（2312）） |
| 枚举信息访问器：泛型计数（ei_generic_count） | 返回 读 64 位（g_enums, n * 2360 + OFF_EI_GENERIC_COUNT（2352）） |
| 枚举信息访问器：泛型名称（ei_generic_name） | 返回 读 64 位（g_enums, n * 2360 + OFF_EI_GENERIC_NAMES（2320） + gi * 8） |
| 枚举信息访问器：变体名称（ei_variant_name） | 返回 读 64 位（g_enums, n * 2360 + OFF_EI_VARIANTS（8） + vi * 144 + OFF_EV_NAME（0）） |
| 枚举信息访问器：变体类型（ei_variant_type） | 返回 读 64 位（g_enums, n * 2360 + 8 + vi * 144 + OFF_EV_TYPES（8） + ti * 8） |
| 枚举信息访问器：变体类型计数（ei_variant_type_count） | 返回 读 64 位（g_enums, n * 2360 + 8 + vi * 144 + OFF_EV_TYPE_COUNT（136）） |

## 字符串表函数

### 函数 扩展全局字符串数组（grow_g_strs）
签名：`函数 扩展全局字符串数组（grow_g_strs）（需要的索引（needed）：整数）`
### 作用
扩容 字符串常量数组（g_strs）（字符串常量数组，每项 8 字节存储字符串指针），遵循通用倍增扩容模式。
### 逻辑
    如果 需求（needed） 小于 字符串常量容量（g_str_cap）（字符串常量容量），那么：返回
    令 新容量（nc）= 字符串常量容量（g_str_cap） * 2
    如果 新容量 小于 64，那么：令 新容量 = 64
    如果 新容量 小于 需求（needed），那么：令 新容量 = 需求 + 64
    令 新缓冲区（nb）= 分配内存（新容量 * 8）
    内部：动态拷贝（_dyncpy）（g_strs（字符串常量数组）, g_str_cap * 8, 新缓冲区）
    令 字符串常量数组（g_strs） = 新缓冲区
    令 字符串常量容量（g_str_cap） = 新容量
### 测试要点
1. 与通用 扩容函数（grow） 模式一致

### 函数 字符串哈希（str_hash）
签名：`函数 字符串哈希（str_hash）（字符串指针（s）：字符串）-> 整数`
### 作用
计算以空字符终止的字符串的哈希值。使用 DJB2 哈希算法（初始值 5381，乘数 33），逐字节累计直到遇到空终止符（字节值 0）。
### 逻辑
    令 哈希值（h）= 5381（可变，DJB2 哈希算法（djb2） 初始值）
    令 字符索引（i）= 0
    循环：
        令 当前字符（c）= 加载单字节（字符串指针（s）, 字符索引）
        如果 当前字符 等于 0（空终止符），那么：跳出循环
        令 哈希值 = 哈希值 * 33 + 当前字符
        令 字符索引 = 字符索引 + 1
    返回 哈希值
### 测试要点
1. 空字符串返回 5381（因首字节即为空终止符，循环体不执行）
2. 相同字符串产生相同哈希值
3. 逐字节累计，包含全部字符直到空终止符

### 函数 哈希字节序列（hash_bytes）
签名：`函数 哈希字节序列（hash_bytes）（数据指针（data）：字符串，长度（len）：整数）-> 整数`
### 作用
对任意字节序列计算哈希值，用于函数体内容指纹。使用 FNV-1a 风格哈希（初始偏移 2166136261，质数乘数 16777619）。
### 逻辑
    令 哈希值（h）= 2166136261（可变，FNV 哈希（FNV） 哈希（FNV 哈希） 初始偏移量）
    令 字节索引（i）= 0
    循环（当 字节索引 小于 长度（len） 时）：
        令 哈希值 = 哈希值 * 16777619（FNV 哈希（FNV） 质数乘数）
        令 哈希值 = 哈希值 + （加载单字节（数据（data）, 字节索引）模 256）
        令 字节索引 = 字节索引 + 1
    返回 哈希值
### 测试要点
1. 长度（len） 等于 0 时返回初始值 2166136261
2. 相同字节序列产生相同哈希值

### 函数 内部：扩展字符串哈希表（_grow_str_hash）
签名：`函数 内部：扩展字符串哈希表（_grow_str_hash）（新容量（ncap）：整数）`
### 作用
分配新的哈希表并全部初始化为 -1（空槽标记），然后将所有已有字符串条目重新哈希插入到新表中。使用开放寻址法（线性探测：位置（pos） = （位置 + 1） % 名称容量（ncap））解决哈希冲突。
### 逻辑
    （分配并初始化新表为全 -1）
    令 新表（nb）= 分配内存（名称容量（ncap） * 8）
    令 初始化索引（i）= 0
    循环（当 初始化索引 小于 名称容量（ncap） 时）：
        写 64 位（w64）（新表, 初始化索引 * 8, -1）
        令 初始化索引 = 初始化索引 + 1

    （重新哈希所有已有字符串到新表）
    令 字符串索引（si）= 0
    循环（当 字符串索引 小于 g_str_count（字符串常量计数）时）：
        令 字符串指针（s）= 字符串指针加载（load_str_ptr）（g_strs（字符串常量数组）, 字符串索引 * 8）
        令 哈希值（h）= 字符串哈希（str_hash）（字符串指针）
        令 探测位置（pos）= 哈希值 模 名称容量（ncap）
        如果 探测位置 小于 0，那么：令 探测位置 = -探测位置
        （线性探测找空槽）
        循环：
            如果 读 64 位（新表, 探测位置 * 8）小于 0（空槽），那么：
                写 64 位（新表, 探测位置 * 8, 字符串索引）
                跳出循环
            令 探测位置 = （探测位置 + 1） 模 名称容量（ncap）
        令 字符串索引 = 字符串索引 + 1

    令 字符串哈希表（g_str_hash）（字符串哈希表）= 新表
    令 字符串哈希表容量（g_str_hash_cap）（字符串哈希表容量）= 名称容量（ncap）
### 测试要点
1. 新表所有槽位初始化为 -1
2. 所有已有字符串被重新哈希到新表
3. 哈希冲突通过线性探测解决
4. 哈希取模后的负值取绝对值处理

### 函数 字符串驻留（str_intern）
签名：`函数 字符串驻留（str_intern）（字符串指针（s）：字符串）-> 整数`
### 作用
在全局字符串驻留表中查找或插入字符串。若字符串已存在则返回已有索引，否则追加新条目并返回新索引。首次调用时延迟初始化哈希表（容量 64，通过 _grow_str_hash）。当负载因子超过 70%（即 count * 10 > 容量（cap） * 7）时自动翻倍扩容并重新哈希。
### 逻辑
    （延迟初始化哈希表）
    如果 字符串哈希表容量（g_str_hash_cap）（字符串哈希表容量）等于 0，那么：
        内部：扩展字符串哈希表（_grow_str_hash）（64）

    （哈希查找：计算哈希值并在表中线性探测）
    令 哈希值（h）= 字符串哈希（str_hash）（s）
    令 当前容量（cap）= 字符串哈希表容量（g_str_hash_cap）
    令 探测位置（pos）= 哈希值 模 当前容量
    如果 探测位置 小于 0，那么：令 探测位置 = -探测位置

    循环：
        令 槽中字符串索引（si）= 读 64 位（r64）（g_str_hash（字符串哈希表）, 探测位置 * 8）
        如果 槽中字符串索引 小于 0，那么：跳出循环（找到空槽，字符串不在表中）
        如果 字符串相等比较（str_eq）（字符串指针加载（load_str_ptr）（g_strs, 槽中字符串索引 * 8）, 字符串指针（s））不等于 0，那么：
            返回 槽中字符串索引（已存在，直接返回）
        令 探测位置 = （探测位置 + 1） 模 当前容量（线性探测下一个槽位）

    （未找到：将新字符串追加到 g_strs 数组）
    扩展全局字符串数组（grow_g_strs）（g_str_count + 1）
    字符串指针存储（store_str_ptr）（g_strs, g_str_count * 8, 字符串指针（s））
    令 字符串常量计数（g_str_count） = 字符串常量计数 + 1

    （将新条目插入哈希表：使用之前找到的空槽位置）
    写 64 位（w64）（g_str_hash, 探测位置 * 8, g_str_count - 1）

    （自动扩容检查：负载因子超过 70% 时翻倍扩容）
    如果 字符串常量计数（g_str_count） * 10 大于 字符串哈希表容量（g_str_hash_cap） * 7，那么：
        内部：扩展字符串哈希表（g_str_hash_cap * 2）

    返回 字符串常量计数（g_str_count） - 1
### 测试要点
1. 首次调用时自动创建容量 64 的哈希表
2. 已存在的字符串直接返回已有索引（不重复存储）
3. 新字符串追加到 字符串常量数组（g_strs） 并插入哈希表的空槽
4. 负载因子超过 0.7 时自动触发翻倍扩容
5. 线性探测正确解决哈希冲突
6. 注意：哈希表在扩容前插入新条目，扩容后条目也在新表中——插入使用扩容前的空槽位置直接写入

### 函数 驻留字符串获取（istr_get）
签名：`函数 驻留字符串获取（istr_get）（索引（idx）：整数）-> 字符串`
### 作用
按索引从驻留表获取字符串指针。索引超出范围（小于 0 或大于等于 g_str_count）返回空串。
### 逻辑
    如果 索引（idx） 小于 0 或 索引 大于等于 字符串常量计数（g_str_count），那么：返回 ""
    返回 字符串指针加载（load_str_ptr）（g_strs, 索引（idx） * 8）
### 测试要点
1. 索引（idx） 小于 0 返回空串
2. 索引（idx） 大于等于 字符串常量计数（g_str_count） 返回空串
3. 有效索引返回存储的字符串指针

### 函数 驻留字符串长度（istr_len）
签名：`函数 驻留字符串长度（istr_len）（索引（idx）：整数）-> 整数`
### 作用
按索引获取驻留字符串的长度（str_len）。索引超出范围返回 0。
### 逻辑
    如果 索引（idx） 小于 0 或 索引 大于等于 字符串常量计数（g_str_count），那么：返回 0
    返回 字符串长度（str_len）（驻留字符串获取（istr_get）（idx））
### 测试要点
1. 索引超出范围返回 0

### 函数 字符串按字节读取（str_load8）
签名：`函数 字符串按字节读取（str_load8）（索引（idx）：整数，字符位置（ci）：整数）-> 整数`
### 作用
按驻留表索引和字符位置读取一个字节。索引超出范围返回 0。
### 逻辑
    如果 索引（idx） 小于 0 或 索引 大于等于 字符串常量计数（g_str_count），那么：返回 0
    返回 加载单字节（驻留字符串获取（idx）, 字符位置（ci））
### 测试要点
1. 索引超出范围返回 0

### 函数 驻留字符串相等比较（istr_eq）
签名：`函数 驻留字符串相等比较（istr_eq）（索引（idx）：整数，字面量字符串（lit）：字符串）-> 整数`
### 作用
判断驻留表中索引 索引（idx） 的字符串是否与字面量字符串 字面量（lit） 相等。索引超出范围或不等返回 0（假），相等返回 1（真）。
### 逻辑
    如果 索引（idx） 小于 0 或 索引 大于等于 字符串常量计数（g_str_count），那么：返回 0
    如果 字符串相等比较（str_eq）（驻留字符串获取（istr_get）（idx）, 字面量（lit））不等于 0，那么：返回 1
    返回 0
### 测试要点
1. 索引超出范围返回 0
2. 字符串相等返回 1
3. 字符串不等返回 0

## x86 后端数组及特殊扩容函数

以下 扩容函数（grow） 函数服务于 x86 ELF 后端，大多遵循通用倍增扩容模式。

### 单数组扩容函数参数表（x86 后端部分）

| 函数 | 数组变量 | 容量变量 | 每元素字节数 | 最小初始容量 | 余量 |
|------|---------|---------|-------------|-------------|------|
| x86 变量数组 | g_x86_vars | g_x86_var_cap | 8 | 128 | 128 |
| x86 变量是否枚举标记数组 | g_x86_is_enum | g_x86_is_enum_cap | 8 | 128 | 128 |
| x86 变量是否全局标记数组 | g_x86_is_global | g_x86_global_cap | 8 | 128 | 128 |
| x86 全局变量偏移数组 | g_x86_global_off | g_x86_global_off_cap | 8 | 128 | 128 |
| x86 字符串偏移数组 | g_x86_str_offs | g_x86_str_cap | 8 | 64 | 64 |
| x86 发射级别变量数组 | g_x86_emit_vars | g_x86_emit_vars_cap | 8 | 128 | 128 |
| x86 函数偏移数组 | g_x86_func_offsets | g_x86_func_offsets_cap | 16 | 64 | 64 |
| x86 函数当前指针 | g_x86_func_cp | g_x86_func_cp_cap | 8 | 64 | 64 |
| x86 函数代码大小数组 | g_x86_func_code_sz | g_x86_func_code_sz_cap | 8 | 64 | 64 |
| x86 RET 修补位置数组 | g_x86_ret_patch_pos | g_x86_ret_patch_cap | 8 | 64 | 64 |
| x86 分配修补位置数组 | g_x86_alloc_patch_pos | g_x86_alloc_patch_cap | 8 | 64 | 64 |
| 行文件 ID 数组 | g_line_fileid | g_line_cap | 8 | 128 | 128 |
| 泛型应用数据数组 | g_gen_apply_data | g_gen_apply_data_cap | 8 | 64 | 64 |
| 数据流节点数组 | g_df_nodes | g_df_node_cap | ESZ_DFNODE（64） | 128 | 128 |
| 数据流节点所属 region | g_df_node_region | g_df_node_region_cap | 8 | 128 | 128 |
| 数据流边数组 | g_df_edges | g_df_edge_cap | ESZ_DFEDGE（32） | 128 | 128 |
| 全局声明数组 | g_global_lets | g_global_lets_cap | 8 | 64 | 64 |
| 循环标签栈 | g_loop_stack | g_loop_stack_cap | 24 | 64 | 64 |
| 类型别名数组 | g_type_aliases | g_type_alias_cap | 16 | 32 | 32 |
| 作用域边界数组 | g_scope_bounds | g_scope_bounds_cap | 8 | 64 | 64 |
| 方法数组 | g_methods | g_method_cap | 24 | 64 | 64 |
| 借用作用域标记 | g_borrow_scope_markers | g_borrow_scope_markers_cap | 8 | 64 | 64 |
| IR 局部作用域栈 | g_ir_local_scopes | g_ir_local_scopes_cap | 8 | 64 | 64 |
| 标签位置数组 | g_label_poses | g_label_cap | 8 | 64 | 64 |
| 诊断数组 | g_diags | g_diag_cap | 32 | 16 | 16 |
| 文件数组 | g_files | g_file_cap | 16 | 16 | 16 |
| 模块数组 | g_mods | g_mod_cap | 24 | 16 | 16 |
| 模块路径名数组 | g_mod_path_names | g_mod_path_cap | 8 | 32 | 32 |
| 接口实现数组 | g_impl_for | g_impl_for_cap | 16 | 8 | 8 |
| 泛型参数数组 | g_gen_params | g_gen_param_cap | 8 | 16 | 16 |
| 泛型约束数组 | g_generic_constr | g_generic_constr_cap | 8 | 16 | 16 |

### 函数 扩展优化元数据数组（grow_opt_meta）
签名：`函数 扩展优化元数据数组（grow_opt_meta）（需要的索引（needed）：整数）`
### 作用
扩容 优化元数据数组（g_opt_meta）（优化元数据数组）。与其他 扩容函数（grow） 函数的差异：仅拷贝已使用的条目（g_opt_meta_count * OPT_META_STRIDE）而非全容量拷贝（g_opt_meta_cap * OPT_META_STRIDE）。入口条件使用 `需求（needed） <= 优化元数据容量（g_opt_meta_cap）`（小于等于）而非 `需求 < 优化元数据容量`（小于）。
### 逻辑
    如果 需求（needed） 小于等于 优化元数据容量（g_opt_meta_cap）（优化元数据容量），那么：返回
    令 新容量（nc）= 优化元数据容量（g_opt_meta_cap） * 2
    如果 新容量 小于 16，那么：令 新容量 = 16
    如果 新容量 小于 需求（needed），那么：令 新容量 = 需求 + 16
    令 新缓冲区（nb）= 分配内存（新容量 * OPT_META_STRIDE）
    内部：动态拷贝（_dyncpy）（g_opt_meta（优化元数据数组）, g_opt_meta_count（优化元数据计数）* OPT_META_STRIDE, 新缓冲区）
    令 优化元数据数组（g_opt_meta） = 新缓冲区
    令 优化元数据容量（g_opt_meta_cap） = 新容量
### 测试要点
1. 拷贝量基于 统计个数（count） 而非 容量（cap），避免拷贝未初始化的尾部
2. 入口条件使用小于等于（<=）而非小于（<）

### 多数组同步扩容函数

以下函数同时扩容多个并行数组，每个子数组独立分配新缓冲区、拷贝旧数据。所有子数组使用相同的元素大小（8 字节）和相同的容量值。

| 函数 | 同步扩容的子数组 | 最小初始容量 | 余量 |
|------|-----------------|-------------|------|
| 扩展 RIP 修补数组（grow_rip_patch） | g_x86_rip_patch_pos, g_x86_rip_patch_globals | 128 | 128 |
| 扩展外部重定位数组（grow_ext_rel） | g_x86_ext_rel_pos, g_x86_ext_rel_name | 32 | 32 |
| 扩展段数组（grow_segs） | g_seg_starts, g_seg_fileids | 16 | 16 |
| 扩展数据流数组（grow_df_arrays） | g_df_var_producer, g_df_func_node_start, g_df_func_node_count | 128 | 128 |
| 扩展泛型映射数组（grow_gen_map） | g_gen_map_names, g_gen_map_types | 8 | 8 |
| 扩展借用变量数组（grow_borrow_vars） | g_borrow_vars, g_borrow_refs, g_borrow_muts | 16 | 16 |
| 扩展持有者数组（grow_holder） | g_holder_borrowers, g_holder_borrowed, g_holder_is_mut | 16 | 16 |
| 扩展待处理数组（grow_pending） | g_pending_pos, g_pending_label | 64 | 64 |
| 扩展调用修补数组（grow_call_patch） | g_x86_call_patch_pos, g_x86_call_patch_name | 64 | 64 |
| 扩展函数地址修补数组（grow_fnaddr_patch） | g_x86_fnaddr_patch_pos, g_x86_fnaddr_patch_name | 64 | 64 |
| 扩展只读数据引用数组（grow_rodataref） | g_x86_rodataref_pos, g_x86_rodataref_ro | 64 | 64 |
| 扩展 IR 循环栈数组（grow_ir_loop_stacks） | g_ir_loop_header, g_ir_loop_exit | 64 | 64 |
| 扩展模块函数数组（grow_mod_funcs） | g_mod_func_fileids, g_mod_func_names, g_mod_func_tis | 64 | 64 |

### 函数 扩展结构图数组（grow_sg）
签名：`函数 扩展结构图数组（grow_sg）（需要的最大索引（n）：整数）`
### 作用
扩容 结构图数组（g_sgs）（结构图数组，每元素 ESZ_SG = 48 字节）。采用不同的扩容策略：从 0 或当前容量开始反复翻倍直到超过 数量（n）。旧容量为 0 时不执行拷贝。
### 逻辑
    令 新容量（nc）= 结构图数组容量（g_sg_cap）（结构图数组容量）
    如果 新容量 等于 0，那么：令 新容量 = 16
    循环（当 新容量 小于等于 数量（n） 时）：令 新容量 = 新容量 * 2
    令 新缓冲区（nb）= 分配内存（新容量 * 48）    // 分配（新容量 * ESZ_SG）字节
    如果 结构图数组容量（g_sg_cap） 大于 0，那么：内部：动态拷贝（_dyncpy）（g_sgs（结构图数组）, g_sg_cap * 48, 新缓冲区）
    令 结构图数组（g_sgs） = 新缓冲区
    令 结构图数组容量（g_sg_cap） = 新容量
### 测试要点
1. 初始容量为 0 时从 16 开始
2. 循环翻倍直到容量大于 数量（n）
3. 旧容量为 0 时不执行拷贝（无可拷贝内容）

### 函数 扩展指针集数组（grow_pts）
签名：`函数 扩展指针集数组（grow_pts）（需要的最大索引（n）：整数）`
### 作用
扩容 指针集数组（g_pts）（指针集数组，每元素 8 字节）。策略同 扩展结构图数组（grow_sg）（初始 16、翻倍、容量 0 时不拷贝）。
### 逻辑
    与 扩展结构图数组（grow_sg） 相同的翻倍策略，区别为每元素 8 字节。
### 测试要点
1. 同 扩展结构图数组（grow_sg）

### 函数 扩展偏移量数组（grow_offsets）
签名：`函数 扩展偏移量数组（grow_offsets）（需要的最大索引（n）：整数）`
### 作用
扩容 偏移量数组（g_offsets）（偏移量数组，每元素 8 字节）。策略同 扩展结构图数组（grow_sg）。
### 逻辑
    与 扩展结构图数组（grow_sg） 相同的翻倍策略，每元素 8 字节。
### 测试要点
1. 同 扩展结构图数组（grow_sg）

### 函数 扩展 词法单元数组（grow_tokens）
签名：`函数 扩展 词法单元数组（grow_tokens）（需要的最大索引（needed）：整数）`
### 作用
扩容 词法单元数组（g_tokens） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 128 起步翻倍扩容（仍不足时按 需要的最大索引+128），分配新缓冲区并拷贝旧数据。每元素大小（ESZ_TOKEN）字节。
### 逻辑
    如果 需要的最大索引 小于 词法单元容量（g_tok_cap），那么：返回
    令 新容量（nc）= 词法单元容量 * 2；如果 新容量 小于 128，那么：令 新容量 = 128；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 128
    令 新缓冲区（nb）= 分配内存（新容量 * ESZ_TOKEN）
    内部：动态拷贝（_dyncpy）（词法单元数组，词法单元容量 * ESZ_TOKEN，新缓冲区）
    令 词法单元数组 = 新缓冲区；令 词法单元容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（128 起步），旧数据完整拷贝

### 函数 扩展 AST 节点数组（grow_ast）
签名：`函数 扩展 AST 节点数组（grow_ast）（需要的最大索引（needed）：整数）`
### 作用
扩容 AST 节点数组（g_ast） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 128 起步翻倍扩容（仍不足时按 需要的最大索引+128），分配新缓冲区并拷贝旧数据。每元素大小（ESZ_ASTNODE）字节。
### 逻辑
    如果 需要的最大索引 小于 AST 节点容量（g_ast_cap），那么：返回
    令 新容量（nc）= AST 节点容量 * 2；如果 新容量 小于 128，那么：令 新容量 = 128；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 128
    令 新缓冲区（nb）= 分配内存（新容量 * ESZ_ASTNODE）
    内部：动态拷贝（_dyncpy）（AST 节点数组，AST 节点容量 * ESZ_ASTNODE，新缓冲区）
    令 AST 节点数组 = 新缓冲区；令 AST 节点容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（128 起步），旧数据完整拷贝

### 函数 扩展 符号数组（grow_syms）
签名：`函数 扩展 符号数组（grow_syms）（需要的最大索引（needed）：整数）`
### 作用
扩容 符号数组（g_syms） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 64 起步翻倍扩容（仍不足时按 需要的最大索引+64），分配新缓冲区并拷贝旧数据。每元素大小（ESZ_SYMENTRY）字节。
### 逻辑
    如果 需要的最大索引 小于 符号容量（g_sym_cap），那么：返回
    令 新容量（nc）= 符号容量 * 2；如果 新容量 小于 64，那么：令 新容量 = 64；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 64
    令 新缓冲区（nb）= 分配内存（新容量 * ESZ_SYMENTRY）
    内部：动态拷贝（_dyncpy）（符号数组，符号容量 * ESZ_SYMENTRY，新缓冲区）
    令 符号数组 = 新缓冲区；令 符号容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（64 起步），旧数据完整拷贝

### 函数 扩展 类型数组（grow_types）
签名：`函数 扩展 类型数组（grow_types）（需要的最大索引（needed）：整数）`
### 作用
扩容 类型数组（g_types） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 64 起步翻倍扩容（仍不足时按 需要的最大索引+64），分配新缓冲区并拷贝旧数据。每元素大小（24）字节。
### 逻辑
    如果 需要的最大索引 小于 类型容量（g_type_cap），那么：返回
    令 新容量（nc）= 类型容量 * 2；如果 新容量 小于 64，那么：令 新容量 = 64；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 64
    令 新缓冲区（nb）= 分配内存（新容量 * 24）
    内部：动态拷贝（_dyncpy）（类型数组，类型容量 * 24，新缓冲区）
    令 类型数组 = 新缓冲区；令 类型容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（64 起步），旧数据完整拷贝

### 函数 扩展 函数数组（grow_funcs）
签名：`函数 扩展 函数数组（grow_funcs）（需要的最大索引（needed）：整数）`
### 作用
扩容 函数数组（g_funcs） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 64 起步翻倍扩容（仍不足时按 需要的最大索引+64），分配新缓冲区并拷贝旧数据。每元素大小（ESZ_FUNCINFO）字节。
### 逻辑
    如果 需要的最大索引 小于 函数数组容量（g_func_cap），那么：返回
    令 新容量（nc）= 函数数组容量 * 2；如果 新容量 小于 64，那么：令 新容量 = 64；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 64
    令 新缓冲区（nb）= 分配内存（新容量 * ESZ_FUNCINFO）
    内部：动态拷贝（_dyncpy）（函数数组，函数数组容量 * ESZ_FUNCINFO，新缓冲区）
    令 函数数组 = 新缓冲区；令 函数数组容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（64 起步），旧数据完整拷贝

### 函数 扩展 结构体数组（grow_structs）
签名：`函数 扩展 结构体数组（grow_structs）（需要的最大索引（needed）：整数）`
### 作用
扩容 结构体数组（g_structs） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 32 起步翻倍扩容（仍不足时按 需要的最大索引+32），分配新缓冲区并拷贝旧数据。每元素大小（ESZ_STRUCTINFO）字节。
### 逻辑
    如果 需要的最大索引 小于 结构体容量（g_struct_cap），那么：返回
    令 新容量（nc）= 结构体容量 * 2；如果 新容量 小于 32，那么：令 新容量 = 32；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 32
    令 新缓冲区（nb）= 分配内存（新容量 * ESZ_STRUCTINFO）
    内部：动态拷贝（_dyncpy）（结构体数组，结构体容量 * ESZ_STRUCTINFO，新缓冲区）
    令 结构体数组 = 新缓冲区；令 结构体容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（32 起步），旧数据完整拷贝

### 函数 扩展 枚举数组（grow_enums）
签名：`函数 扩展 枚举数组（grow_enums）（需要的最大索引（needed）：整数）`
### 作用
扩容 枚举数组（g_enums） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 16 起步翻倍扩容（仍不足时按 需要的最大索引+16），分配新缓冲区并拷贝旧数据。每元素大小（ESZ_ENUMINFO）字节。
### 逻辑
    如果 需要的最大索引 小于 枚举容量（g_enum_cap），那么：返回
    令 新容量（nc）= 枚举容量 * 2；如果 新容量 小于 16，那么：令 新容量 = 16；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 16
    令 新缓冲区（nb）= 分配内存（新容量 * ESZ_ENUMINFO）
    内部：动态拷贝（_dyncpy）（枚举数组，枚举容量 * ESZ_ENUMINFO，新缓冲区）
    令 枚举数组 = 新缓冲区；令 枚举容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（16 起步），旧数据完整拷贝

### 函数 扩展 接口数组（grow_ifaces）
签名：`函数 扩展 接口数组（grow_ifaces）（需要的最大索引（needed）：整数）`
### 作用
扩容 接口数组（g_ifaces） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 4 起步翻倍扩容（仍不足时按 需要的最大索引+4），分配新缓冲区并拷贝旧数据。每元素大小（ESZ_IFACEINFO）字节。
### 逻辑
    如果 需要的最大索引 小于 接口容量（g_iface_cap），那么：返回
    令 新容量（nc）= 接口容量 * 2；如果 新容量 小于 4，那么：令 新容量 = 4；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 4
    令 新缓冲区（nb）= 分配内存（新容量 * ESZ_IFACEINFO）
    内部：动态拷贝（_dyncpy）（接口数组，接口容量 * ESZ_IFACEINFO，新缓冲区）
    令 接口数组 = 新缓冲区；令 接口容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（4 起步），旧数据完整拷贝

### 函数 扩展 IR 变量数组（grow_ir_vars）
签名：`函数 扩展 IR 变量数组（grow_ir_vars）（需要的最大索引（needed）：整数）`
### 作用
扩容 IR 变量数组（g_ir_vars） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 128 起步翻倍扩容（仍不足时按 需要的最大索引+128），分配新缓冲区并拷贝旧数据。每元素大小（ESZ_IRVAR）字节。
### 逻辑
    如果 需要的最大索引 小于 IR 变量容量（g_ir_var_cap），那么：返回
    令 新容量（nc）= IR 变量容量 * 2；如果 新容量 小于 128，那么：令 新容量 = 128；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 128
    令 新缓冲区（nb）= 分配内存（新容量 * ESZ_IRVAR）
    内部：动态拷贝（_dyncpy）（IR 变量数组，IR 变量容量 * ESZ_IRVAR，新缓冲区）
    令 IR 变量数组 = 新缓冲区；令 IR 变量容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（128 起步），旧数据完整拷贝

### 函数 扩展 IR 指令数组（grow_ir_instrs）
签名：`函数 扩展 IR 指令数组（grow_ir_instrs）（需要的最大索引（needed）：整数）`
### 作用
扩容 IR 指令数组（g_ir_instrs） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 128 起步翻倍扩容（仍不足时按 需要的最大索引+128），分配新缓冲区并拷贝旧数据。每元素大小（ESZ_IRINSTR）字节。
### 逻辑
    如果 需要的最大索引 小于 IR 指令容量（g_ir_instr_cap），那么：返回
    令 新容量（nc）= IR 指令容量 * 2；如果 新容量 小于 128，那么：令 新容量 = 128；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 128
    令 新缓冲区（nb）= 分配内存（新容量 * ESZ_IRINSTR）
    内部：动态拷贝（_dyncpy）（IR 指令数组，IR 指令容量 * ESZ_IRINSTR，新缓冲区）
    令 IR 指令数组 = 新缓冲区；令 IR 指令容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（128 起步），旧数据完整拷贝

### 函数 扩展 IR 局部变量数组（grow_ir_locals）
签名：`函数 扩展 IR 局部变量数组（grow_ir_locals）（需要的最大索引（needed）：整数）`
### 作用
扩容 IR 局部变量数组（g_ir_locals） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 64 起步翻倍扩容（仍不足时按 需要的最大索引+64），分配新缓冲区并拷贝旧数据。每元素大小（16）字节。
### 逻辑
    如果 需要的最大索引 小于 IR 局部变量容量（g_ir_local_cap），那么：返回
    令 新容量（nc）= IR 局部变量容量 * 2；如果 新容量 小于 64，那么：令 新容量 = 64；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 64
    令 新缓冲区（nb）= 分配内存（新容量 * 16）
    内部：动态拷贝（_dyncpy）（IR 局部变量数组，IR 局部变量容量 * 16，新缓冲区）
    令 IR 局部变量数组 = 新缓冲区；令 IR 局部变量容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（64 起步），旧数据完整拷贝

### 函数 扩展 IR 全局变量数组（grow_ir_globals）
签名：`函数 扩展 IR 全局变量数组（grow_ir_globals）（需要的最大索引（needed）：整数）`
### 作用
扩容 IR 全局变量数组（g_ir_globals） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 16 起步翻倍扩容（仍不足时按 需要的最大索引+16），分配新缓冲区并拷贝旧数据。每元素大小（24）字节。
### 逻辑
    如果 需要的最大索引 小于 IR 全局变量容量（g_ir_global_cap），那么：返回
    令 新容量（nc）= IR 全局变量容量 * 2；如果 新容量 小于 16，那么：令 新容量 = 16；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 16
    令 新缓冲区（nb）= 分配内存（新容量 * 24）
    内部：动态拷贝（_dyncpy）（IR 全局变量数组，IR 全局变量容量 * 24，新缓冲区）
    令 IR 全局变量数组 = 新缓冲区；令 IR 全局变量容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（16 起步），旧数据完整拷贝

### 函数 扩展 IR 字符串常量数组（grow_ir_str_consts）
签名：`函数 扩展 IR 字符串常量数组（grow_ir_str_consts）（需要的最大索引（needed）：整数）`
### 作用
扩容 IR 字符串常量数组（g_ir_str_consts） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 64 起步翻倍扩容（仍不足时按 需要的最大索引+64），分配新缓冲区并拷贝旧数据。每元素大小（8）字节。
### 逻辑
    如果 需要的最大索引 小于 IR 字符串常量容量（g_ir_str_const_cap），那么：返回
    令 新容量（nc）= IR 字符串常量容量 * 2；如果 新容量 小于 64，那么：令 新容量 = 64；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 64
    令 新缓冲区（nb）= 分配内存（新容量 * 8）
    内部：动态拷贝（_dyncpy）（IR 字符串常量数组，IR 字符串常量容量 * 8，新缓冲区）
    令 IR 字符串常量数组 = 新缓冲区；令 IR 字符串常量容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（64 起步），旧数据完整拷贝

### 函数 扩展 错误数组（grow_errors）
签名：`函数 扩展 错误数组（grow_errors）（需要的最大索引（needed）：整数）`
### 作用
扩容 错误数组（g_errors） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 16 起步翻倍扩容（仍不足时按 需要的最大索引+16），分配新缓冲区并拷贝旧数据。每元素大小（8）字节。
### 逻辑
    如果 需要的最大索引 小于 错误数组容量（g_err_cap），那么：返回
    令 新容量（nc）= 错误数组容量 * 2；如果 新容量 小于 16，那么：令 新容量 = 16；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 16
    令 新缓冲区（nb）= 分配内存（新容量 * 8）
    内部：动态拷贝（_dyncpy）（错误数组，错误数组容量 * 8，新缓冲区）
    令 错误数组 = 新缓冲区；令 错误数组容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（16 起步），旧数据完整拷贝

### 函数 扩展 代码块语句数组（grow_block_stmts）
签名：`函数 扩展 代码块语句数组（grow_block_stmts）（需要的最大索引（needed）：整数）`
### 作用
扩容 代码块语句数组（g_block_stmts） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 64 起步翻倍扩容（仍不足时按 需要的最大索引+64），分配新缓冲区并拷贝旧数据。每元素大小（8）字节。
### 逻辑
    如果 需要的最大索引 小于 代码块语句容量（g_block_stmt_cap），那么：返回
    令 新容量（nc）= 代码块语句容量 * 2；如果 新容量 小于 64，那么：令 新容量 = 64；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 64
    令 新缓冲区（nb）= 分配内存（新容量 * 8）
    内部：动态拷贝（_dyncpy）（代码块语句数组，代码块语句容量 * 8，新缓冲区）
    令 代码块语句数组 = 新缓冲区；令 代码块语句容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（64 起步），旧数据完整拷贝

### 函数 扩展 行文件 ID 数组（grow_line_file）
签名：`函数 扩展 行文件 ID 数组（grow_line_file）（需要的最大索引（needed）：整数）`
### 作用
扩容 行文件 ID 数组（g_line_fileid） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 128 起步翻倍扩容（仍不足时按 需要的最大索引+128），分配新缓冲区并拷贝旧数据。每元素大小（8）字节。
### 逻辑
    如果 需要的最大索引 小于 行数组容量（g_line_cap），那么：返回
    令 新容量（nc）= 行数组容量 * 2；如果 新容量 小于 128，那么：令 新容量 = 128；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 128
    令 新缓冲区（nb）= 分配内存（新容量 * 8）
    内部：动态拷贝（_dyncpy）（行文件 ID 数组，行数组容量 * 8，新缓冲区）
    令 行文件 ID 数组 = 新缓冲区；令 行数组容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（128 起步），旧数据完整拷贝

### 函数 扩展 段容量 对应数组（grow_segs）
签名：`函数 扩展 段容量 对应数组（grow_segs）（需要的最大索引（needed）：整数）`
### 作用
同步扩容 段起始索引数组（g_seg_starts） 与 段文件 ID 数组（g_seg_fileids）（每元素 8 字节） 以容纳 需要的最大索引 个元素。容量不足时按 16 起步翻倍扩容，各数组同步分配新缓冲区并拷贝旧数据。
### 逻辑
    如果 需要的最大索引 小于 段容量（g_seg_cap），那么：返回
    令 新容量（nc）= 段容量 * 2；如果 新容量 小于 16，那么：令 新容量 = 16；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 16
    令 新缓冲区1（n1）= 分配内存（新容量 * 8）；内部：动态拷贝（_dyncpy）（段起始索引数组，段容量 * 8，新缓冲区1）；令 段起始索引数组 = 新缓冲区1
    令 新缓冲区2（n2）= 分配内存（新容量 * 8）；内部：动态拷贝（_dyncpy）（段文件 ID 数组，段容量 * 8，新缓冲区2）；令 段文件 ID 数组 = 新缓冲区2
    令 段容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回
2. 容量不足 → 各数组同步翻倍扩容（16 起步），旧数据完整拷贝

### 函数 扩展 泛型应用数据数组（grow_gen_apply_data）
签名：`函数 扩展 泛型应用数据数组（grow_gen_apply_data）（需要的最大索引（needed）：整数）`
### 作用
扩容 泛型应用数据数组（g_gen_apply_data） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 64 起步翻倍扩容（仍不足时按 需要的最大索引+64），分配新缓冲区并拷贝旧数据。每元素大小（8）字节。
### 逻辑
    如果 需要的最大索引 小于 泛型应用数据容量（g_gen_apply_data_cap），那么：返回
    令 新容量（nc）= 泛型应用数据容量 * 2；如果 新容量 小于 64，那么：令 新容量 = 64；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 64
    令 新缓冲区（nb）= 分配内存（新容量 * 8）
    内部：动态拷贝（_dyncpy）（泛型应用数据数组，泛型应用数据容量 * 8，新缓冲区）
    令 泛型应用数据数组 = 新缓冲区；令 泛型应用数据容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（64 起步），旧数据完整拷贝

### 函数 扩展 数据流节点数组（grow_df_nodes）
签名：`函数 扩展 数据流节点数组（grow_df_nodes）（需要的最大索引（needed）：整数）`
### 作用
扩容 数据流节点数组（g_df_nodes） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 128 起步翻倍扩容（仍不足时按 需要的最大索引+128），分配新缓冲区并拷贝旧数据。每元素大小（ESZ_DFNODE）字节。
### 逻辑
    如果 需要的最大索引 小于 数据流节点数组容量（g_df_node_cap），那么：返回
    令 新容量（nc）= 数据流节点数组容量 * 2；如果 新容量 小于 128，那么：令 新容量 = 128；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 128
    令 新缓冲区（nb）= 分配内存（新容量 * ESZ_DFNODE）
    内部：动态拷贝（_dyncpy）（数据流节点数组，数据流节点数组容量 * ESZ_DFNODE，新缓冲区）
    令 数据流节点数组 = 新缓冲区；令 数据流节点数组容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（128 起步），旧数据完整拷贝

### 函数 扩展 数据流节点所属 region（grow_df_node_region）
签名：`函数 扩展 数据流节点所属 region（grow_df_node_region）（需要的最大索引（needed）：整数）`
### 作用
扩容 数据流节点所属 region（g_df_node_region） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 128 起步翻倍扩容（仍不足时按 需要的最大索引+128），分配新缓冲区并拷贝旧数据。每元素大小（8）字节。
### 逻辑
    如果 需要的最大索引 小于 数据流节点 region 映射容量（g_df_node_region_cap），那么：返回
    令 新容量（nc）= 数据流节点 region 映射容量 * 2；如果 新容量 小于 128，那么：令 新容量 = 128；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 128
    令 新缓冲区（nb）= 分配内存（新容量 * 8）
    内部：动态拷贝（_dyncpy）（数据流节点所属 region，数据流节点 region 映射容量 * 8，新缓冲区）
    令 数据流节点所属 region = 新缓冲区；令 数据流节点 region 映射容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（128 起步），旧数据完整拷贝

### 函数 扩展 数据流边数组（grow_df_edges）
签名：`函数 扩展 数据流边数组（grow_df_edges）（需要的最大索引（needed）：整数）`
### 作用
扩容 数据流边数组（g_df_edges） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 128 起步翻倍扩容（仍不足时按 需要的最大索引+128），分配新缓冲区并拷贝旧数据。每元素大小（ESZ_DFEDGE）字节。
### 逻辑
    如果 需要的最大索引 小于 数据流边数组容量（g_df_edge_cap），那么：返回
    令 新容量（nc）= 数据流边数组容量 * 2；如果 新容量 小于 128，那么：令 新容量 = 128；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 128
    令 新缓冲区（nb）= 分配内存（新容量 * ESZ_DFEDGE）
    内部：动态拷贝（_dyncpy）（数据流边数组，数据流边数组容量 * ESZ_DFEDGE，新缓冲区）
    令 数据流边数组 = 新缓冲区；令 数据流边数组容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（128 起步），旧数据完整拷贝

### 函数 扩展 HDFG数组容量 对应数组（grow_df_arrays）
签名：`函数 扩展 HDFG数组容量 对应数组（grow_df_arrays）（需要的最大索引（needed）：整数）`
### 作用
同步扩容 变量生产者节点映射（g_df_var_producer） 与 HDFG各函数节点起始索引（g_df_func_node_start） 与 HDFG各函数节点计数（g_df_func_node_count）（每元素 8 字节） 以容纳 需要的最大索引 个元素。容量不足时按 128 起步翻倍扩容，各数组同步分配新缓冲区并拷贝旧数据。
### 逻辑
    如果 需要的最大索引 小于 HDFG数组容量（g_df_cap），那么：返回
    令 新容量（nc）= HDFG数组容量 * 2；如果 新容量 小于 128，那么：令 新容量 = 128；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 128
    令 新缓冲区1（n1）= 分配内存（新容量 * 8）；内部：动态拷贝（_dyncpy）（变量生产者节点映射，HDFG数组容量 * 8，新缓冲区1）；令 变量生产者节点映射 = 新缓冲区1
    令 新缓冲区2（n2）= 分配内存（新容量 * 8）；内部：动态拷贝（_dyncpy）（HDFG各函数节点起始索引，HDFG数组容量 * 8，新缓冲区2）；令 HDFG各函数节点起始索引 = 新缓冲区2
    令 新缓冲区3（n3）= 分配内存（新容量 * 8）；内部：动态拷贝（_dyncpy）（HDFG各函数节点计数，HDFG数组容量 * 8，新缓冲区3）；令 HDFG各函数节点计数 = 新缓冲区3
    令 HDFG数组容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回
2. 容量不足 → 各数组同步翻倍扩容（128 起步），旧数据完整拷贝

### 函数 扩展 泛型映射容量 对应数组（grow_gen_map）
签名：`函数 扩展 泛型映射容量 对应数组（grow_gen_map）（需要的最大索引（needed）：整数）`
### 作用
同步扩容 泛型映射名数组（g_gen_map_names） 与 泛型映射类型数组（g_gen_map_types）（每元素 8 字节） 以容纳 需要的最大索引 个元素。容量不足时按 8 起步翻倍扩容，各数组同步分配新缓冲区并拷贝旧数据。
### 逻辑
    如果 需要的最大索引 小于 泛型映射容量（g_gen_map_cap），那么：返回
    令 新容量（nc）= 泛型映射容量 * 2；如果 新容量 小于 8，那么：令 新容量 = 8；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 8
    令 新缓冲区1（n1）= 分配内存（新容量 * 8）；内部：动态拷贝（_dyncpy）（泛型映射名数组，泛型映射容量 * 8，新缓冲区1）；令 泛型映射名数组 = 新缓冲区1
    令 新缓冲区2（n2）= 分配内存（新容量 * 8）；内部：动态拷贝（_dyncpy）（泛型映射类型数组，泛型映射容量 * 8，新缓冲区2）；令 泛型映射类型数组 = 新缓冲区2
    令 泛型映射容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回
2. 容量不足 → 各数组同步翻倍扩容（8 起步），旧数据完整拷贝

### 函数 扩展 借用数组容量 对应数组（grow_borrow_vars）
签名：`函数 扩展 借用数组容量 对应数组（grow_borrow_vars）（需要的最大索引（needed）：整数）`
### 作用
同步扩容 借用变量数组（g_borrow_vars） 与 借用引用数组（g_borrow_refs） 与 借用可变标记数组（g_borrow_muts）（每元素 8 字节） 以容纳 需要的最大索引 个元素。容量不足时按 16 起步翻倍扩容，各数组同步分配新缓冲区并拷贝旧数据。
### 逻辑
    如果 需要的最大索引 小于 借用数组容量（g_borrow_cap），那么：返回
    令 新容量（nc）= 借用数组容量 * 2；如果 新容量 小于 16，那么：令 新容量 = 16；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 16
    令 新缓冲区1（n1）= 分配内存（新容量 * 8）；内部：动态拷贝（_dyncpy）（借用变量数组，借用数组容量 * 8，新缓冲区1）；令 借用变量数组 = 新缓冲区1
    令 新缓冲区2（n2）= 分配内存（新容量 * 8）；内部：动态拷贝（_dyncpy）（借用引用数组，借用数组容量 * 8，新缓冲区2）；令 借用引用数组 = 新缓冲区2
    令 新缓冲区3（n3）= 分配内存（新容量 * 8）；内部：动态拷贝（_dyncpy）（借用可变标记数组，借用数组容量 * 8，新缓冲区3）；令 借用可变标记数组 = 新缓冲区3
    令 借用数组容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回
2. 容量不足 → 各数组同步翻倍扩容（16 起步），旧数据完整拷贝

### 函数 扩展 持有者容量 对应数组（grow_holder）
签名：`函数 扩展 持有者容量 对应数组（grow_holder）（需要的最大索引（needed）：整数）`
### 作用
同步扩容 持有者-借用者（g_holder_borrowers） 与 持有者-被借数（g_holder_borrowed） 与 持有者可变标记（g_holder_is_mut）（每元素 8 字节） 以容纳 需要的最大索引 个元素。容量不足时按 16 起步翻倍扩容，各数组同步分配新缓冲区并拷贝旧数据。
### 逻辑
    如果 需要的最大索引 小于 持有者容量（g_holder_cap），那么：返回
    令 新容量（nc）= 持有者容量 * 2；如果 新容量 小于 16，那么：令 新容量 = 16；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 16
    令 新缓冲区1（n1）= 分配内存（新容量 * 8）；内部：动态拷贝（_dyncpy）（持有者-借用者，持有者容量 * 8，新缓冲区1）；令 持有者-借用者 = 新缓冲区1
    令 新缓冲区2（n2）= 分配内存（新容量 * 8）；内部：动态拷贝（_dyncpy）（持有者-被借数，持有者容量 * 8，新缓冲区2）；令 持有者-被借数 = 新缓冲区2
    令 新缓冲区3（n3）= 分配内存（新容量 * 8）；内部：动态拷贝（_dyncpy）（持有者可变标记，持有者容量 * 8，新缓冲区3）；令 持有者可变标记 = 新缓冲区3
    令 持有者容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回
2. 容量不足 → 各数组同步翻倍扩容（16 起步），旧数据完整拷贝

### 函数 扩展 全局声明数组（grow_global_lets）
签名：`函数 扩展 全局声明数组（grow_global_lets）（需要的最大索引（needed）：整数）`
### 作用
扩容 全局声明数组（g_global_lets） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 64 起步翻倍扩容（仍不足时按 需要的最大索引+64），分配新缓冲区并拷贝旧数据。每元素大小（8）字节。
### 逻辑
    如果 需要的最大索引 小于 全局声明容量（g_global_lets_cap），那么：返回
    令 新容量（nc）= 全局声明容量 * 2；如果 新容量 小于 64，那么：令 新容量 = 64；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 64
    令 新缓冲区（nb）= 分配内存（新容量 * 8）
    内部：动态拷贝（_dyncpy）（全局声明数组，全局声明容量 * 8，新缓冲区）
    令 全局声明数组 = 新缓冲区；令 全局声明容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（64 起步），旧数据完整拷贝

### 函数 扩展 循环标签栈（grow_loop_stack）
签名：`函数 扩展 循环标签栈（grow_loop_stack）（需要的最大索引（needed）：整数）`
### 作用
扩容 循环标签栈（g_loop_stack） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 64 起步翻倍扩容（仍不足时按 需要的最大索引+64），分配新缓冲区并拷贝旧数据。每元素大小（24）字节。
### 逻辑
    如果 需要的最大索引 小于 循环栈容量（g_loop_stack_cap），那么：返回
    令 新容量（nc）= 循环栈容量 * 2；如果 新容量 小于 64，那么：令 新容量 = 64；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 64
    令 新缓冲区（nb）= 分配内存（新容量 * 24）
    内部：动态拷贝（_dyncpy）（循环标签栈，循环栈容量 * 24，新缓冲区）
    令 循环标签栈 = 新缓冲区；令 循环栈容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（64 起步），旧数据完整拷贝

### 函数 扩展 类型别名数组（grow_type_aliases）
签名：`函数 扩展 类型别名数组（grow_type_aliases）（需要的最大索引（needed）：整数）`
### 作用
扩容 类型别名数组（g_type_aliases） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 32 起步翻倍扩容（仍不足时按 需要的最大索引+32），分配新缓冲区并拷贝旧数据。每元素大小（16）字节。
### 逻辑
    如果 需要的最大索引 小于 类型别名容量（g_type_alias_cap），那么：返回
    令 新容量（nc）= 类型别名容量 * 2；如果 新容量 小于 32，那么：令 新容量 = 32；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 32
    令 新缓冲区（nb）= 分配内存（新容量 * 16）
    内部：动态拷贝（_dyncpy）（类型别名数组，类型别名容量 * 16，新缓冲区）
    令 类型别名数组 = 新缓冲区；令 类型别名容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（32 起步），旧数据完整拷贝

### 函数 扩展 作用域边界数组（grow_scope_bounds）
签名：`函数 扩展 作用域边界数组（grow_scope_bounds）（需要的最大索引（needed）：整数）`
### 作用
扩容 作用域边界数组（g_scope_bounds） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 64 起步翻倍扩容（仍不足时按 需要的最大索引+64），分配新缓冲区并拷贝旧数据。每元素大小（8）字节。
### 逻辑
    如果 需要的最大索引 小于 作用域边界容量（g_scope_bounds_cap），那么：返回
    令 新容量（nc）= 作用域边界容量 * 2；如果 新容量 小于 64，那么：令 新容量 = 64；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 64
    令 新缓冲区（nb）= 分配内存（新容量 * 8）
    内部：动态拷贝（_dyncpy）（作用域边界数组，作用域边界容量 * 8，新缓冲区）
    令 作用域边界数组 = 新缓冲区；令 作用域边界容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（64 起步），旧数据完整拷贝

### 函数 扩展 方法数组（grow_methods）
签名：`函数 扩展 方法数组（grow_methods）（需要的最大索引（needed）：整数）`
### 作用
扩容 方法数组（g_methods） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 64 起步翻倍扩容（仍不足时按 需要的最大索引+64），分配新缓冲区并拷贝旧数据。每元素大小（24）字节。
### 逻辑
    如果 需要的最大索引 小于 方法容量（g_method_cap），那么：返回
    令 新容量（nc）= 方法容量 * 2；如果 新容量 小于 64，那么：令 新容量 = 64；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 64
    令 新缓冲区（nb）= 分配内存（新容量 * 24）
    内部：动态拷贝（_dyncpy）（方法数组，方法容量 * 24，新缓冲区）
    令 方法数组 = 新缓冲区；令 方法容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（64 起步），旧数据完整拷贝

### 函数 扩展 借用作用域标记（grow_borrow_markers）
签名：`函数 扩展 借用作用域标记（grow_borrow_markers）（需要的最大索引（needed）：整数）`
### 作用
扩容 借用作用域标记（g_borrow_scope_markers） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 64 起步翻倍扩容（仍不足时按 需要的最大索引+64），分配新缓冲区并拷贝旧数据。每元素大小（8）字节。
### 逻辑
    如果 需要的最大索引 小于 借用作用域标记容量（g_borrow_scope_markers_cap），那么：返回
    令 新容量（nc）= 借用作用域标记容量 * 2；如果 新容量 小于 64，那么：令 新容量 = 64；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 64
    令 新缓冲区（nb）= 分配内存（新容量 * 8）
    内部：动态拷贝（_dyncpy）（借用作用域标记，借用作用域标记容量 * 8，新缓冲区）
    令 借用作用域标记 = 新缓冲区；令 借用作用域标记容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（64 起步），旧数据完整拷贝

### 函数 扩展 x86 变量数组（grow_x86_vars）
签名：`函数 扩展 x86 变量数组（grow_x86_vars）（需要的最大索引（needed）：整数）`
### 作用
扩容 x86 变量数组（g_x86_vars） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 128 起步翻倍扩容（仍不足时按 需要的最大索引+128），分配新缓冲区并拷贝旧数据。每元素大小（8）字节。
### 逻辑
    如果 需要的最大索引 小于 x86 变量容量（g_x86_var_cap），那么：返回
    令 新容量（nc）= x86 变量容量 * 2；如果 新容量 小于 128，那么：令 新容量 = 128；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 128
    令 新缓冲区（nb）= 分配内存（新容量 * 8）
    内部：动态拷贝（_dyncpy）（x86 变量数组，x86 变量容量 * 8，新缓冲区）
    令 x86 变量数组 = 新缓冲区；令 x86 变量容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（128 起步），旧数据完整拷贝

### 函数 扩展 x86 变量是否枚举标记数组（grow_is_enum）
签名：`函数 扩展 x86 变量是否枚举标记数组（grow_is_enum）（需要的最大索引（needed）：整数）`
### 作用
扩容 x86 变量是否枚举标记数组（g_x86_is_enum） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 128 起步翻倍扩容（仍不足时按 需要的最大索引+128），分配新缓冲区并拷贝旧数据。每元素大小（8）字节。
### 逻辑
    如果 需要的最大索引 小于 x86 枚举变量容量（g_x86_is_enum_cap），那么：返回
    令 新容量（nc）= x86 枚举变量容量 * 2；如果 新容量 小于 128，那么：令 新容量 = 128；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 128
    令 新缓冲区（nb）= 分配内存（新容量 * 8）
    内部：动态拷贝（_dyncpy）（x86 变量是否枚举标记数组，x86 枚举变量容量 * 8，新缓冲区）
    令 x86 变量是否枚举标记数组 = 新缓冲区；令 x86 枚举变量容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（128 起步），旧数据完整拷贝

### 函数 扩展 x86 变量是否全局标记数组（grow_is_global）
签名：`函数 扩展 x86 变量是否全局标记数组（grow_is_global）（需要的最大索引（needed）：整数）`
### 作用
扩容 x86 变量是否全局标记数组（g_x86_is_global） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 128 起步翻倍扩容（仍不足时按 需要的最大索引+128），分配新缓冲区并拷贝旧数据。每元素大小（8）字节。
### 逻辑
    如果 需要的最大索引 小于 x86 全局变量容量（g_x86_global_cap），那么：返回
    令 新容量（nc）= x86 全局变量容量 * 2；如果 新容量 小于 128，那么：令 新容量 = 128；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 128
    令 新缓冲区（nb）= 分配内存（新容量 * 8）
    内部：动态拷贝（_dyncpy）（x86 变量是否全局标记数组，x86 全局变量容量 * 8，新缓冲区）
    令 x86 变量是否全局标记数组 = 新缓冲区；令 x86 全局变量容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（128 起步），旧数据完整拷贝

### 函数 扩展 x86 全局变量偏移数组（grow_global_off）
签名：`函数 扩展 x86 全局变量偏移数组（grow_global_off）（需要的最大索引（needed）：整数）`
### 作用
扩容 x86 全局变量偏移数组（g_x86_global_off） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 128 起步翻倍扩容（仍不足时按 需要的最大索引+128），分配新缓冲区并拷贝旧数据。每元素大小（8）字节。
### 逻辑
    如果 需要的最大索引 小于 x86 全局变量偏移容量（g_x86_global_off_cap），那么：返回
    令 新容量（nc）= x86 全局变量偏移容量 * 2；如果 新容量 小于 128，那么：令 新容量 = 128；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 128
    令 新缓冲区（nb）= 分配内存（新容量 * 8）
    内部：动态拷贝（_dyncpy）（x86 全局变量偏移数组，x86 全局变量偏移容量 * 8，新缓冲区）
    令 x86 全局变量偏移数组 = 新缓冲区；令 x86 全局变量偏移容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（128 起步），旧数据完整拷贝

### 函数 扩展 x86 字符串偏移数组（grow_str_offs）
签名：`函数 扩展 x86 字符串偏移数组（grow_str_offs）（需要的最大索引（needed）：整数）`
### 作用
扩容 x86 字符串偏移数组（g_x86_str_offs） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 64 起步翻倍扩容（仍不足时按 需要的最大索引+64），分配新缓冲区并拷贝旧数据。每元素大小（8）字节。
### 逻辑
    如果 需要的最大索引 小于 x86 字符串容量（g_x86_str_cap），那么：返回
    令 新容量（nc）= x86 字符串容量 * 2；如果 新容量 小于 64，那么：令 新容量 = 64；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 64
    令 新缓冲区（nb）= 分配内存（新容量 * 8）
    内部：动态拷贝（_dyncpy）（x86 字符串偏移数组，x86 字符串容量 * 8，新缓冲区）
    令 x86 字符串偏移数组 = 新缓冲区；令 x86 字符串容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（64 起步），旧数据完整拷贝

### 函数 扩展 x86 RIP 修补容量 对应数组（grow_rip_patch）
签名：`函数 扩展 x86 RIP 修补容量 对应数组（grow_rip_patch）（需要的最大索引（needed）：整数）`
### 作用
同步扩容 x86 RIP 修补位置数组（g_x86_rip_patch_pos） 与 x86 RIP 全局变量修补数组（g_x86_rip_patch_globals）（每元素 8 字节） 以容纳 需要的最大索引 个元素。容量不足时按 128 起步翻倍扩容，各数组同步分配新缓冲区并拷贝旧数据。
### 逻辑
    如果 需要的最大索引 小于 x86 RIP 修补容量（g_x86_rip_patch_cap），那么：返回
    令 新容量（nc）= x86 RIP 修补容量 * 2；如果 新容量 小于 128，那么：令 新容量 = 128；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 128
    令 新缓冲区1（n1）= 分配内存（新容量 * 8）；内部：动态拷贝（_dyncpy）（x86 RIP 修补位置数组，x86 RIP 修补容量 * 8，新缓冲区1）；令 x86 RIP 修补位置数组 = 新缓冲区1
    令 新缓冲区2（n2）= 分配内存（新容量 * 8）；内部：动态拷贝（_dyncpy）（x86 RIP 全局变量修补数组，x86 RIP 修补容量 * 8，新缓冲区2）；令 x86 RIP 全局变量修补数组 = 新缓冲区2
    令 x86 RIP 修补容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回
2. 容量不足 → 各数组同步翻倍扩容（128 起步），旧数据完整拷贝

### 函数 扩展 x86 外部重定位容量 对应数组（grow_ext_rel）
签名：`函数 扩展 x86 外部重定位容量 对应数组（grow_ext_rel）（需要的最大索引（needed）：整数）`
### 作用
同步扩容 x86 外部重定位位置数组（g_x86_ext_rel_pos） 与 x86 外部重定位名称数组（g_x86_ext_rel_name）（每元素 8 字节） 以容纳 需要的最大索引 个元素。容量不足时按 32 起步翻倍扩容，各数组同步分配新缓冲区并拷贝旧数据。
### 逻辑
    如果 需要的最大索引 小于 x86 外部重定位容量（g_x86_ext_rel_cap），那么：返回
    令 新容量（nc）= x86 外部重定位容量 * 2；如果 新容量 小于 32，那么：令 新容量 = 32；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 32
    令 新缓冲区1（n1）= 分配内存（新容量 * 8）；内部：动态拷贝（_dyncpy）（x86 外部重定位位置数组，x86 外部重定位容量 * 8，新缓冲区1）；令 x86 外部重定位位置数组 = 新缓冲区1
    令 新缓冲区2（n2）= 分配内存（新容量 * 8）；内部：动态拷贝（_dyncpy）（x86 外部重定位名称数组，x86 外部重定位容量 * 8，新缓冲区2）；令 x86 外部重定位名称数组 = 新缓冲区2
    令 x86 外部重定位容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回
2. 容量不足 → 各数组同步翻倍扩容（32 起步），旧数据完整拷贝

### 函数 扩展 x86 函数偏移数组（grow_func_offsets）
签名：`函数 扩展 x86 函数偏移数组（grow_func_offsets）（需要的最大索引（needed）：整数）`
### 作用
扩容 x86 函数偏移数组（g_x86_func_offsets） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 64 起步翻倍扩容（仍不足时按 需要的最大索引+64），分配新缓冲区并拷贝旧数据。每元素大小（16）字节。
### 逻辑
    如果 需要的最大索引 小于 x86 函数偏移容量（g_x86_func_offsets_cap），那么：返回
    令 新容量（nc）= x86 函数偏移容量 * 2；如果 新容量 小于 64，那么：令 新容量 = 64；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 64
    令 新缓冲区（nb）= 分配内存（新容量 * 16）
    内部：动态拷贝（_dyncpy）（x86 函数偏移数组，x86 函数偏移容量 * 16，新缓冲区）
    令 x86 函数偏移数组 = 新缓冲区；令 x86 函数偏移容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（64 起步），旧数据完整拷贝

### 函数 扩展 x86 发射级别变量数组（grow_emit_vars）
签名：`函数 扩展 x86 发射级别变量数组（grow_emit_vars）（需要的最大索引（needed）：整数）`
### 作用
扩容 x86 发射级别变量数组（g_x86_emit_vars） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 128 起步翻倍扩容（仍不足时按 需要的最大索引+128），分配新缓冲区并拷贝旧数据。每元素大小（8）字节。
### 逻辑
    如果 需要的最大索引 小于 x86 发射级别变量容量（g_x86_emit_vars_cap），那么：返回
    令 新容量（nc）= x86 发射级别变量容量 * 2；如果 新容量 小于 128，那么：令 新容量 = 128；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 128
    令 新缓冲区（nb）= 分配内存（新容量 * 8）
    内部：动态拷贝（_dyncpy）（x86 发射级别变量数组，x86 发射级别变量容量 * 8，新缓冲区）
    令 x86 发射级别变量数组 = 新缓冲区；令 x86 发射级别变量容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（128 起步），旧数据完整拷贝

### 函数 扩展 待处理容量 对应数组（grow_pending）
签名：`函数 扩展 待处理容量 对应数组（grow_pending）（需要的最大索引（needed）：整数）`
### 作用
同步扩容 待处理位置数组（g_pending_pos） 与 待处理标签数组（g_pending_label）（每元素 8 字节） 以容纳 需要的最大索引 个元素。容量不足时按 64 起步翻倍扩容，各数组同步分配新缓冲区并拷贝旧数据。
### 逻辑
    如果 需要的最大索引 小于 待处理容量（g_pending_cap），那么：返回
    令 新容量（nc）= 待处理容量 * 2；如果 新容量 小于 64，那么：令 新容量 = 64；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 64
    令 新缓冲区1（n1）= 分配内存（新容量 * 8）；内部：动态拷贝（_dyncpy）（待处理位置数组，待处理容量 * 8，新缓冲区1）；令 待处理位置数组 = 新缓冲区1
    令 新缓冲区2（n2）= 分配内存（新容量 * 8）；内部：动态拷贝（_dyncpy）（待处理标签数组，待处理容量 * 8，新缓冲区2）；令 待处理标签数组 = 新缓冲区2
    令 待处理容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回
2. 容量不足 → 各数组同步翻倍扩容（64 起步），旧数据完整拷贝

### 函数 扩展 x86 RET 修补位置数组（grow_ret_patch）
签名：`函数 扩展 x86 RET 修补位置数组（grow_ret_patch）（需要的最大索引（needed）：整数）`
### 作用
扩容 x86 RET 修补位置数组（g_x86_ret_patch_pos） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 64 起步翻倍扩容（仍不足时按 需要的最大索引+64），分配新缓冲区并拷贝旧数据。每元素大小（8）字节。
### 逻辑
    如果 需要的最大索引 小于 x86 RET 修补容量（g_x86_ret_patch_cap），那么：返回
    令 新容量（nc）= x86 RET 修补容量 * 2；如果 新容量 小于 64，那么：令 新容量 = 64；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 64
    令 新缓冲区（nb）= 分配内存（新容量 * 8）
    内部：动态拷贝（_dyncpy）（x86 RET 修补位置数组，x86 RET 修补容量 * 8，新缓冲区）
    令 x86 RET 修补位置数组 = 新缓冲区；令 x86 RET 修补容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（64 起步），旧数据完整拷贝

### 函数 扩展 x86 调用修补容量 对应数组（grow_call_patch）
签名：`函数 扩展 x86 调用修补容量 对应数组（grow_call_patch）（需要的最大索引（needed）：整数）`
### 作用
同步扩容 x86 调用修补位置数组（g_x86_call_patch_pos） 与 x86 调用修补名称数组（g_x86_call_patch_name）（每元素 8 字节） 以容纳 需要的最大索引 个元素。容量不足时按 64 起步翻倍扩容，各数组同步分配新缓冲区并拷贝旧数据。
### 逻辑
    如果 需要的最大索引 小于 x86 调用修补容量（g_x86_call_patch_cap），那么：返回
    令 新容量（nc）= x86 调用修补容量 * 2；如果 新容量 小于 64，那么：令 新容量 = 64；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 64
    令 新缓冲区1（n1）= 分配内存（新容量 * 8）；内部：动态拷贝（_dyncpy）（x86 调用修补位置数组，x86 调用修补容量 * 8，新缓冲区1）；令 x86 调用修补位置数组 = 新缓冲区1
    令 新缓冲区2（n2）= 分配内存（新容量 * 8）；内部：动态拷贝（_dyncpy）（x86 调用修补名称数组，x86 调用修补容量 * 8，新缓冲区2）；令 x86 调用修补名称数组 = 新缓冲区2
    令 x86 调用修补容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回
2. 容量不足 → 各数组同步翻倍扩容（64 起步），旧数据完整拷贝

### 函数 扩展 x86 函数地址修补容量 对应数组（grow_fnaddr_patch）
签名：`函数 扩展 x86 函数地址修补容量 对应数组（grow_fnaddr_patch）（需要的最大索引（needed）：整数）`
### 作用
同步扩容 x86 函数地址修补位置数组（g_x86_fnaddr_patch_pos） 与 x86 函数地址修补名称数组（g_x86_fnaddr_patch_name）（每元素 8 字节） 以容纳 需要的最大索引 个元素。容量不足时按 64 起步翻倍扩容，各数组同步分配新缓冲区并拷贝旧数据。
### 逻辑
    如果 需要的最大索引 小于 x86 函数地址修补容量（g_x86_fnaddr_patch_cap），那么：返回
    令 新容量（nc）= x86 函数地址修补容量 * 2；如果 新容量 小于 64，那么：令 新容量 = 64；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 64
    令 新缓冲区1（n1）= 分配内存（新容量 * 8）；内部：动态拷贝（_dyncpy）（x86 函数地址修补位置数组，x86 函数地址修补容量 * 8，新缓冲区1）；令 x86 函数地址修补位置数组 = 新缓冲区1
    令 新缓冲区2（n2）= 分配内存（新容量 * 8）；内部：动态拷贝（_dyncpy）（x86 函数地址修补名称数组，x86 函数地址修补容量 * 8，新缓冲区2）；令 x86 函数地址修补名称数组 = 新缓冲区2
    令 x86 函数地址修补容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回
2. 容量不足 → 各数组同步翻倍扩容（64 起步），旧数据完整拷贝

### 函数 扩展 x86 函数当前指针（grow_func_cp）
签名：`函数 扩展 x86 函数当前指针（grow_func_cp）（需要的最大索引（needed）：整数）`
### 作用
扩容 x86 函数当前指针（g_x86_func_cp） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 64 起步翻倍扩容（仍不足时按 需要的最大索引+64），分配新缓冲区并拷贝旧数据。每元素大小（8）字节。
### 逻辑
    如果 需要的最大索引 小于 x86 函数当前指针容量（g_x86_func_cp_cap），那么：返回
    令 新容量（nc）= x86 函数当前指针容量 * 2；如果 新容量 小于 64，那么：令 新容量 = 64；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 64
    令 新缓冲区（nb）= 分配内存（新容量 * 8）
    内部：动态拷贝（_dyncpy）（x86 函数当前指针，x86 函数当前指针容量 * 8，新缓冲区）
    令 x86 函数当前指针 = 新缓冲区；令 x86 函数当前指针容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（64 起步），旧数据完整拷贝

### 函数 扩展 x86 函数代码大小数组（grow_func_code_sz）
签名：`函数 扩展 x86 函数代码大小数组（grow_func_code_sz）（需要的最大索引（needed）：整数）`
### 作用
扩容 x86 函数代码大小数组（g_x86_func_code_sz） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 64 起步翻倍扩容（仍不足时按 需要的最大索引+64），分配新缓冲区并拷贝旧数据。每元素大小（8）字节。
### 逻辑
    如果 需要的最大索引 小于 x86 函数代码大小容量（g_x86_func_code_sz_cap），那么：返回
    令 新容量（nc）= x86 函数代码大小容量 * 2；如果 新容量 小于 64，那么：令 新容量 = 64；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 64
    令 新缓冲区（nb）= 分配内存（新容量 * 8）
    内部：动态拷贝（_dyncpy）（x86 函数代码大小数组，x86 函数代码大小容量 * 8，新缓冲区）
    令 x86 函数代码大小数组 = 新缓冲区；令 x86 函数代码大小容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（64 起步），旧数据完整拷贝

### 函数 扩展 x86 .rodata 引用容量 对应数组（grow_rodataref）
签名：`函数 扩展 x86 .rodata 引用容量 对应数组（grow_rodataref）（需要的最大索引（needed）：整数）`
### 作用
同步扩容 x86 .rodata 引用位置数组（g_x86_rodataref_pos） 与 x86 .rodata 引用目标数组（g_x86_rodataref_ro）（每元素 8 字节） 以容纳 需要的最大索引 个元素。容量不足时按 64 起步翻倍扩容，各数组同步分配新缓冲区并拷贝旧数据。
### 逻辑
    如果 需要的最大索引 小于 x86 .rodata 引用容量（g_x86_rodataref_cap），那么：返回
    令 新容量（nc）= x86 .rodata 引用容量 * 2；如果 新容量 小于 64，那么：令 新容量 = 64；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 64
    令 新缓冲区1（n1）= 分配内存（新容量 * 8）；内部：动态拷贝（_dyncpy）（x86 .rodata 引用位置数组，x86 .rodata 引用容量 * 8，新缓冲区1）；令 x86 .rodata 引用位置数组 = 新缓冲区1
    令 新缓冲区2（n2）= 分配内存（新容量 * 8）；内部：动态拷贝（_dyncpy）（x86 .rodata 引用目标数组，x86 .rodata 引用容量 * 8，新缓冲区2）；令 x86 .rodata 引用目标数组 = 新缓冲区2
    令 x86 .rodata 引用容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回
2. 容量不足 → 各数组同步翻倍扩容（64 起步），旧数据完整拷贝

### 函数 扩展 x86 分配修补位置数组（grow_alloc_patch）
签名：`函数 扩展 x86 分配修补位置数组（grow_alloc_patch）（需要的最大索引（needed）：整数）`
### 作用
扩容 x86 分配修补位置数组（g_x86_alloc_patch_pos） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 64 起步翻倍扩容（仍不足时按 需要的最大索引+64），分配新缓冲区并拷贝旧数据。每元素大小（8）字节。
### 逻辑
    如果 需要的最大索引 小于 x86 分配修补容量（g_x86_alloc_patch_cap），那么：返回
    令 新容量（nc）= x86 分配修补容量 * 2；如果 新容量 小于 64，那么：令 新容量 = 64；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 64
    令 新缓冲区（nb）= 分配内存（新容量 * 8）
    内部：动态拷贝（_dyncpy）（x86 分配修补位置数组，x86 分配修补容量 * 8，新缓冲区）
    令 x86 分配修补位置数组 = 新缓冲区；令 x86 分配修补容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（64 起步），旧数据完整拷贝

### 函数 扩展 IR 局部作用域栈（grow_ir_local_scopes）
签名：`函数 扩展 IR 局部作用域栈（grow_ir_local_scopes）（需要的最大索引（needed）：整数）`
### 作用
扩容 IR 局部作用域栈（g_ir_local_scopes） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 64 起步翻倍扩容（仍不足时按 需要的最大索引+64），分配新缓冲区并拷贝旧数据。每元素大小（8）字节。
### 逻辑
    如果 需要的最大索引 小于 IR 局部作用域栈容量（g_ir_local_scopes_cap），那么：返回
    令 新容量（nc）= IR 局部作用域栈容量 * 2；如果 新容量 小于 64，那么：令 新容量 = 64；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 64
    令 新缓冲区（nb）= 分配内存（新容量 * 8）
    内部：动态拷贝（_dyncpy）（IR 局部作用域栈，IR 局部作用域栈容量 * 8，新缓冲区）
    令 IR 局部作用域栈 = 新缓冲区；令 IR 局部作用域栈容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（64 起步），旧数据完整拷贝

### 函数 扩展 IR 循环栈容量 对应数组（grow_ir_loop_stacks）
签名：`函数 扩展 IR 循环栈容量 对应数组（grow_ir_loop_stacks）（需要的最大索引（needed）：整数）`
### 作用
同步扩容 IR 循环头标签栈（g_ir_loop_header） 与 IR 循环出口标签栈（g_ir_loop_exit）（每元素 8 字节） 以容纳 需要的最大索引 个元素。容量不足时按 64 起步翻倍扩容，各数组同步分配新缓冲区并拷贝旧数据。
### 逻辑
    如果 需要的最大索引 小于 IR 循环栈容量（g_ir_loop_stacks_cap），那么：返回
    令 新容量（nc）= IR 循环栈容量 * 2；如果 新容量 小于 64，那么：令 新容量 = 64；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 64
    令 新缓冲区1（n1）= 分配内存（新容量 * 8）；内部：动态拷贝（_dyncpy）（IR 循环头标签栈，IR 循环栈容量 * 8，新缓冲区1）；令 IR 循环头标签栈 = 新缓冲区1
    令 新缓冲区2（n2）= 分配内存（新容量 * 8）；内部：动态拷贝（_dyncpy）（IR 循环出口标签栈，IR 循环栈容量 * 8，新缓冲区2）；令 IR 循环出口标签栈 = 新缓冲区2
    令 IR 循环栈容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回
2. 容量不足 → 各数组同步翻倍扩容（64 起步），旧数据完整拷贝

### 函数 扩展 标签位置数组（grow_label_poses）
签名：`函数 扩展 标签位置数组（grow_label_poses）（需要的最大索引（needed）：整数）`
### 作用
扩容 标签位置数组（g_label_poses） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 64 起步翻倍扩容（仍不足时按 需要的最大索引+64），分配新缓冲区并拷贝旧数据。每元素大小（8）字节。
### 逻辑
    如果 需要的最大索引 小于 标签容量（g_label_cap），那么：返回
    令 新容量（nc）= 标签容量 * 2；如果 新容量 小于 64，那么：令 新容量 = 64；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 64
    令 新缓冲区（nb）= 分配内存（新容量 * 8）
    内部：动态拷贝（_dyncpy）（标签位置数组，标签容量 * 8，新缓冲区）
    令 标签位置数组 = 新缓冲区；令 标签容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（64 起步），旧数据完整拷贝

### 函数 扩展 诊断数组（grow_diags）
签名：`函数 扩展 诊断数组（grow_diags）（需要的最大索引（needed）：整数）`
### 作用
扩容 诊断数组（g_diags） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 16 起步翻倍扩容（仍不足时按 需要的最大索引+16），分配新缓冲区并拷贝旧数据。每元素大小（32）字节。
### 逻辑
    如果 需要的最大索引 小于 诊断容量（g_diag_cap），那么：返回
    令 新容量（nc）= 诊断容量 * 2；如果 新容量 小于 16，那么：令 新容量 = 16；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 16
    令 新缓冲区（nb）= 分配内存（新容量 * 32）
    内部：动态拷贝（_dyncpy）（诊断数组，诊断容量 * 32，新缓冲区）
    令 诊断数组 = 新缓冲区；令 诊断容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（16 起步），旧数据完整拷贝

### 函数 扩展 文件数组（grow_files）
签名：`函数 扩展 文件数组（grow_files）（需要的最大索引（needed）：整数）`
### 作用
扩容 文件数组（g_files） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 16 起步翻倍扩容（仍不足时按 需要的最大索引+16），分配新缓冲区并拷贝旧数据。每元素大小（16）字节。
### 逻辑
    如果 需要的最大索引 小于 文件数组容量（g_file_cap），那么：返回
    令 新容量（nc）= 文件数组容量 * 2；如果 新容量 小于 16，那么：令 新容量 = 16；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 16
    令 新缓冲区（nb）= 分配内存（新容量 * 16）
    内部：动态拷贝（_dyncpy）（文件数组，文件数组容量 * 16，新缓冲区）
    令 文件数组 = 新缓冲区；令 文件数组容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（16 起步），旧数据完整拷贝

### 函数 扩展 模块数组（grow_mods）
签名：`函数 扩展 模块数组（grow_mods）（需要的最大索引（needed）：整数）`
### 作用
扩容 模块数组（g_mods） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 16 起步翻倍扩容（仍不足时按 需要的最大索引+16），分配新缓冲区并拷贝旧数据。每元素大小（24）字节。
### 逻辑
    如果 需要的最大索引 小于 模块容量（g_mod_cap），那么：返回
    令 新容量（nc）= 模块容量 * 2；如果 新容量 小于 16，那么：令 新容量 = 16；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 16
    令 新缓冲区（nb）= 分配内存（新容量 * 24）
    内部：动态拷贝（_dyncpy）（模块数组，模块容量 * 24，新缓冲区）
    令 模块数组 = 新缓冲区；令 模块容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（16 起步），旧数据完整拷贝

### 函数 扩展 模块函数容量 对应数组（grow_mod_funcs）
签名：`函数 扩展 模块函数容量 对应数组（grow_mod_funcs）（需要的最大索引（needed）：整数）`
### 作用
同步扩容 模块函数文件 ID 数组（g_mod_func_fileids） 与 模块函数名数组（g_mod_func_names） 与 模块函数类型索引数组（g_mod_func_tis）（每元素 8 字节） 以容纳 需要的最大索引 个元素。容量不足时按 64 起步翻倍扩容，各数组同步分配新缓冲区并拷贝旧数据。
### 逻辑
    如果 需要的最大索引 小于 模块函数容量（g_mod_func_cap），那么：返回
    令 新容量（nc）= 模块函数容量 * 2；如果 新容量 小于 64，那么：令 新容量 = 64；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 64
    令 新缓冲区1（n1）= 分配内存（新容量 * 8）；内部：动态拷贝（_dyncpy）（模块函数文件 ID 数组，模块函数容量 * 8，新缓冲区1）；令 模块函数文件 ID 数组 = 新缓冲区1
    令 新缓冲区2（n2）= 分配内存（新容量 * 8）；内部：动态拷贝（_dyncpy）（模块函数名数组，模块函数容量 * 8，新缓冲区2）；令 模块函数名数组 = 新缓冲区2
    令 新缓冲区3（n3）= 分配内存（新容量 * 8）；内部：动态拷贝（_dyncpy）（模块函数类型索引数组，模块函数容量 * 8，新缓冲区3）；令 模块函数类型索引数组 = 新缓冲区3
    令 模块函数容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回
2. 容量不足 → 各数组同步翻倍扩容（64 起步），旧数据完整拷贝

### 函数 扩展 模块路径名数组（grow_mod_paths）
签名：`函数 扩展 模块路径名数组（grow_mod_paths）（需要的最大索引（needed）：整数）`
### 作用
扩容 模块路径名数组（g_mod_path_names） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 32 起步翻倍扩容（仍不足时按 需要的最大索引+32），分配新缓冲区并拷贝旧数据。每元素大小（8）字节。
### 逻辑
    如果 需要的最大索引 小于 模块路径容量（g_mod_path_cap），那么：返回
    令 新容量（nc）= 模块路径容量 * 2；如果 新容量 小于 32，那么：令 新容量 = 32；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 32
    令 新缓冲区（nb）= 分配内存（新容量 * 8）
    内部：动态拷贝（_dyncpy）（模块路径名数组，模块路径容量 * 8，新缓冲区）
    令 模块路径名数组 = 新缓冲区；令 模块路径容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（32 起步），旧数据完整拷贝

### 函数 扩展 接口实现数组（grow_impl_for）
签名：`函数 扩展 接口实现数组（grow_impl_for）（需要的最大索引（needed）：整数）`
### 作用
扩容 接口实现数组（g_impl_for） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 8 起步翻倍扩容（仍不足时按 需要的最大索引+8），分配新缓冲区并拷贝旧数据。每元素大小（16）字节。
### 逻辑
    如果 需要的最大索引 小于 接口实现容量（g_impl_for_cap），那么：返回
    令 新容量（nc）= 接口实现容量 * 2；如果 新容量 小于 8，那么：令 新容量 = 8；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 8
    令 新缓冲区（nb）= 分配内存（新容量 * 16）
    内部：动态拷贝（_dyncpy）（接口实现数组，接口实现容量 * 16，新缓冲区）
    令 接口实现数组 = 新缓冲区；令 接口实现容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（8 起步），旧数据完整拷贝

### 函数 扩展 泛型参数数组（grow_gen_params）
签名：`函数 扩展 泛型参数数组（grow_gen_params）（需要的最大索引（needed）：整数）`
### 作用
扩容 泛型参数数组（g_gen_params） 以容纳 需要的最大索引 个元素。若容量足够则直接返回；否则按 16 起步翻倍扩容（仍不足时按 需要的最大索引+16），分配新缓冲区并拷贝旧数据。每元素大小（8）字节。
### 逻辑
    如果 需要的最大索引 小于 泛型参数容量（g_gen_param_cap），那么：返回
    令 新容量（nc）= 泛型参数容量 * 2；如果 新容量 小于 16，那么：令 新容量 = 16；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 16
    令 新缓冲区（nb）= 分配内存（新容量 * 8）
    内部：动态拷贝（_dyncpy）（泛型参数数组，泛型参数容量 * 8，新缓冲区）
    令 泛型参数数组 = 新缓冲区；令 泛型参数容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回，不分配
2. 容量不足 → 翻倍扩容（16 起步），旧数据完整拷贝

### 函数 扩展 泛型约束容量 对应数组（grow_gen_constr）
签名：`函数 扩展 泛型约束容量 对应数组（grow_gen_constr）（需要的最大索引（needed）：整数）`
### 作用
同步扩容 泛型约束数组（g_generic_constr） 与 结构图数组（g_sgs） 与 指针集数组（g_pts） 与 偏移量数组（g_offsets）（每元素 8 字节） 以容纳 需要的最大索引 个元素。容量不足时按 16 起步翻倍扩容，各数组同步分配新缓冲区并拷贝旧数据。
### 逻辑
    如果 需要的最大索引 小于 泛型约束容量（g_generic_constr_cap），那么：返回
    令 新容量（nc）= 泛型约束容量 * 2；如果 新容量 小于 16，那么：令 新容量 = 16；如果 新容量 小于 需要的最大索引，那么：令 新容量 = 需要的最大索引 + 16
    令 新缓冲区1（n1）= 分配内存（新容量 * 8）；内部：动态拷贝（_dyncpy）（泛型约束数组，泛型约束容量 * 8，新缓冲区1）；令 泛型约束数组 = 新缓冲区1
    令 新缓冲区2（n2）= 分配内存（新容量 * 8）；内部：动态拷贝（_dyncpy）（结构图数组，泛型约束容量 * 8，新缓冲区2）；令 结构图数组 = 新缓冲区2
    令 新缓冲区3（n3）= 分配内存（新容量 * 8）；内部：动态拷贝（_dyncpy）（指针集数组，泛型约束容量 * 8，新缓冲区3）；令 指针集数组 = 新缓冲区3
    令 新缓冲区4（n4）= 分配内存（新容量 * 8）；内部：动态拷贝（_dyncpy）（偏移量数组，泛型约束容量 * 8，新缓冲区4）；令 偏移量数组 = 新缓冲区4
    令 泛型约束容量 = 新容量
### 测试要点
1. 需要的最大索引 小于 当前容量 → 直接返回
2. 容量不足 → 各数组同步翻倍扩容（16 起步），旧数据完整拷贝
