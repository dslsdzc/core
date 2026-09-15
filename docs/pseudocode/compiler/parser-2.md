# 解析器（parser）.cr 伪代码（第 2 部分：后缀/基本表达式 + 语句 + 控制流）
> 源文件：src/compiler/解析器（parser）.cr（第 265~964 行）
> 功能概要：解析后缀表达式（函数调用、字段访问 `./::`、数组下标、`?` 运算符、`类型转换（cast）<泛型参数（T）>（expr）` 语法糖展开为 类型转换（as））、基本表达式（整数/浮点/字符串/布尔/无值（None）/某些值（Some）/标识符及结构体字面量/元组/字符/块/如果（if）/当（while）/循环（loop）/遍历（for）/协程启动（go）/等待（await）/匹配（match）/非安全（unsafe）/数组字面量）、代码块解析（含局部语句缓冲区→全局块语句数组的刷写）、新变量声明判断与解析（批量声明 `变量甲（a）,变量乙（b） : type = e1,e2` 含额外声明溢出到 g_extra_lets）、语句解析（声明/返回（return）/让出（yield）/跳出（break）/继续（continue）/表达式语句）、控制流表达式解析（如果/否则（else） 如果→否则 链、循环/当/遍历）、模式匹配解析（匹配 多臂含链表链接、pattern 含通配符/字面量/标识符/构造器/结构体模式）。

## 标识符对照表

| 中文名 | 原名 | 首次出现函数 |
|--------|------|-------------|
| 解析后缀表达式 | parse_postfix | 解析后缀表达式（parse_postfix） |
| 判断首字母大写 | is_upper_first | 判断首字母大写（is_upper_first） |
| 解析基本表达式 | parse_primary | 解析基本表达式（parse_primary） |
| 解析代码块 | parse_block | 解析代码块（parse_block） |
| 判断新变量声明 | is_new_var_decl | 判断新变量声明（is_new_var_decl） |
| 解析新变量声明 | parse_new_var_decl | 解析新变量声明（parse_new_var_decl） |
| 解析语句 | parse_stmt | 解析语句（parse_stmt） |
| 解析 if 表达式 | parse_if_expr | 解析 if 表达式（parse_if_expr） |
| 解析 loop 表达式 | parse_loop_expr | 解析 loop 表达式（parse_loop_expr） |
| 解析 while 表达式 | parse_while_expr | 解析 while 表达式（parse_while_expr） |
| 解析 for 表达式 | parse_for_expr | 解析 for 表达式（parse_for_expr） |
| 解析 match 表达式 | parse_match_expr | 解析 match 表达式（parse_match_expr） |
| 解析模式 | parse_pattern | 解析模式（parse_pattern） |
| AST 节点计数 | g_ast_count | 全局 |
| 代码块语句数组 | g_block_stmts | 全局 |
| 代码块语句计数 | g_block_stmt_count | 全局 |
| 额外声明数组 | g_extra_lets | 全局 |
| 额外声明容量 | g_extra_lets_cap | 全局 |
| 额外声明计数 | g_extra_let_count | 全局 |
| 循环嵌套深度 | g_loop_depth | 全局 |
| 解析器禁止结构体字面量标记 | g_parse_no_struct_literal | 全局 |
| 诊断数组/计数 | g_diags/g_diag_count | 全局 |

## 全局状态

本部分使用的全局变量：

| 中文名 | 原名 | 说明 |
|--------|------|------|
| AST 节点计数 | g_ast_count | 见第 1 部分/标识符对照表 |
| 代码块语句数组 | g_block_stmts | 见第 1 部分/标识符对照表 |
| 代码块语句计数 | g_block_stmt_count | 见第 1 部分/标识符对照表 |
| 额外声明数组 | g_extra_lets | 见第 1 部分/标识符对照表 |
| 额外声明容量 | g_extra_lets_cap | 见第 1 部分/标识符对照表 |
| 额外声明计数 | g_extra_let_count | 见第 1 部分/标识符对照表 |
| 循环嵌套深度 | g_loop_depth | 见第 1 部分/标识符对照表 |
| 解析器禁止结构体字面量标记 | g_parse_no_struct_literal | 见第 1 部分/标识符对照表 |
| 诊断数组/计数 | g_diags/g_diag_count | 见第 1 部分/标识符对照表 |

## 函数 解析后缀表达式（parse_postfix）
### 作用
解析基本表达式之后的后缀操作链。先调用 解析基本表达式（parse_primary） 获取基础表达式节点，然后检查 `类型转换（cast）<泛型参数 泛型参数（T）（泛型参数 T）>（expr）` 语法糖（EXPR_AS）。之后进入循环消费后缀操作符：
- `（args...）` → 函数调用（EXPR_CALL），每个参数包装为 参数表达式（EXPR_ARG） 链表节点；若被调者是首字母大写的标识符或路径访问则识别为枚举构造器调用（EXPR_ENUM_CONSTRUCTOR）
- `.字段（field）` → 字段访问（EXPR_FIELD）；若字段名是整数词法单元则 元组索引值（tv）=索引值+1（表示元组字段按索引访问）
- `::字段（field）` → 路径分隔访问（字段访问表达式（EXPR_FIELD）, 数据（data）=1）
- `[index]` → 数组/索引访问（EXPR_INDEX）
- `?` → 尝试（try） 运算符（EXPR_TRY）
### 逻辑
`
函数 解析后缀表达式（parse_postfix）（） -> 整数
    令 当前节点（node） = 解析基本表达式（parse_primary（））（可变）
    -- 类型转换（cast）<泛型参数 泛型参数（T）（泛型参数 T）>（expr） 语法糖：直接展开为 类型转换（as） 表达式，不做后缀循环
    如果 AST 访问器：类别（ast_kind（当前节点）） 等于 标识符表达式（EXPR_IDENT），那么：
        令 名称索引（ni） = AST 访问器：整数值（ast_int_val（当前节点））
        如果 字符串相等比较（str_eq）（驻留字符串获取（istr_get（名称索引））, "类型转换（cast）"） 不等于 0 且 词法单元类别（tok_k（cur_tok（））） 等于 小于号（T_LT），那么：
            前进词法单元（advance_tok）（） -- 跳过 <
            令 类型（typ） = 解析类型（parse_type（））
            前进词法单元（advance_tok）（） -- 跳过 >
            如果 词法单元类别（tok_k（cur_tok（））） 等于 左圆括号（T_LPAREN），那么：
                前进词法单元（advance_tok）（） -- 跳过 （
                令 内部表达式（inner） = 解析表达式（0）
                前进词法单元（advance_tok）（） -- 跳过 ）
                返回 分配 AST 节点（alloc_node）（类型转换表达式（EXPR_AS）, 内部表达式, 类型, 0, 0, 0, 0, AST 访问器：行号（tok_ln（当前节点））, AST 访问器：列号（tok_cl（当前节点）））
    循环（当 真 时）：
        令 当前词法单元索引（t） = 当前词法单元（cur_tok（））
        如果 词法单元类别（tok_k（当前词法单元索引）） 等于 左圆括号（T_LPAREN），那么：
            前进词法单元（advance_tok）（）
            令 首参数节点（af） = -1
            令 参数计数（ac） = 0（可变）
            如果 非 检查（入口）（T_RPAREN），那么：
                令 首个表达式（first_expr） = 解析表达式（parse_expr（））
                首参数节点 = 分配 AST 节点（alloc_node）（参数表达式（EXPR_ARG）, 首个表达式, -1, 0, 0, 0, 0, 词法单元行号（tok_ln（当前词法单元索引））, 词法单元列号（tok_cl（当前词法单元索引）））
                参数计数 = 1
                令 前一个参数节点（prev_arg） = 首参数节点
                循环（当 真 时）：
                    如果 非 检查（入口）（T_COMMA），那么：跳出循环
                    前进词法单元（advance_tok）（）
                    令 下一个表达式（next_expr） = 解析表达式（parse_expr（））
                    令 新参数节点（new_arg） = 分配 AST 节点（alloc_node）（参数表达式（EXPR_ARG）, 下一个表达式, -1, 0, 0, 0, 0, 词法单元行号（tok_ln（当前词法单元索引））, 词法单元列号（tok_cl（当前词法单元索引）））
                    AST 访问器：设置变量乙（b）（ast_set_b）（前一个参数节点, 新参数节点）
                    前一个参数节点 = 新参数节点
                    参数计数 = 参数计数 + 1
            前进词法单元（advance_tok）（） -- 跳过 ）
            -- 判断是否为枚举构造器调用：被调方首字母大写则为枚举构造器
            令 是否枚举构造器（is_enum_con） = 0（可变）
            令 名称索引（name_idx） = -1（可变）
            如果 AST 访问器：类别（ast_kind（当前节点）） 等于 标识符表达式（EXPR_IDENT），那么：
                名称索引 = AST 访问器：整数值（ast_int_val（当前节点））
            否则如果 AST 访问器：类别（ast_kind（当前节点）） 等于 字段访问表达式（EXPR_FIELD） 且 AST 访问器：数据（ast_data（当前节点）） 不等于 0，那么：
                -- 路径访问形式：形如 模块类型（Module）::变体（Variant），数据（data）=1 表示 :: 路径分隔
                名称索引 = AST 访问器：整数值（ast_int_val（当前节点））
            如果 名称索引 大于等于 0，那么：
                令 名称（name） = 驻留字符串获取（istr_get（名称索引））
                令 首字符（c） = 取字符串第 N 字符（get_char（名称, 0））
                如果 字符串比较（str_cmp）（首字符, "左操作数（A）"） 大于等于 0 且 字符串比较（str_cmp）（首字符, "Z"） 小于等于 0，那么：
                    是否枚举构造器 = 1
            如果 是否枚举构造器 等于 1，那么：
                当前节点 = 分配 AST 节点（alloc_node）（枚举构造表达式（EXPR_ENUM_CONSTRUCTOR）, 名称索引, 首参数节点, 参数计数, 0, 0, 0, 词法单元行号（tok_ln（当前词法单元索引））, 词法单元列号（tok_cl（当前词法单元索引）））
            否则：
                当前节点 = 分配 AST 节点（alloc_node）（调用表达式（EXPR_CALL）, 当前节点, 首参数节点, 参数计数, 0, 0, 0, 词法单元行号（tok_ln（当前词法单元索引））, 词法单元列号（tok_cl（当前词法单元索引）））
            继续下一次循环
        如果 词法单元类别（tok_k（当前词法单元索引）） 等于 点号（T_DOT），那么：
            前进词法单元（advance_tok）（）
            令 字段词法单元索引（f） = 前进词法单元（advance_tok）（）
            令 名称索引（ni） = 字符串驻留（str_intern（tok_lx（字段词法单元索引）））
            令 类型值（tv） = 0（可变）
            -- 若字段名为整数词法单元，则 元组索引值（tv）=索引值+1，表示元组字段按索引访问；0 表示结构体字段
            如果 词法单元类别（tok_k（字段词法单元索引）） 等于 整数字面量（T_INT），那么：类型值 = 词法单元整数值（tok_iv（字段词法单元索引）） + 1
            当前节点 = 分配 AST 节点（alloc_node）（字段访问表达式（EXPR_FIELD）, 当前节点, 0, 0, 名称索引, 类型值, 0, 词法单元行号（tok_ln（当前词法单元索引））, 词法单元列号（tok_cl（当前词法单元索引）））
            继续下一次循环
        如果 词法单元类别（tok_k（当前词法单元索引）） 等于 路径分隔符（T_PATHSEP），那么：
            前进词法单元（advance_tok）（）
            令 字段词法单元索引（f） = 前进词法单元（advance_tok）（）
            令 名称索引（ni） = 字符串驻留（str_intern（tok_lx（字段词法单元索引）））
            -- 数据（data）=1 标记为 :: 路径分隔访问，区别于 . 成员访问
            当前节点 = 分配 AST 节点（alloc_node）（字段访问表达式（EXPR_FIELD）, 当前节点, 0, 0, 名称索引, 0, 1, 词法单元行号（tok_ln（当前词法单元索引））, 词法单元列号（tok_cl（当前词法单元索引）））
            继续下一次循环
        如果 词法单元类别（tok_k（当前词法单元索引）） 等于 左方括号（T_LBRACKET），那么：
            前进词法单元（advance_tok）（）
            令 索引值（idx） = 解析表达式（parse_expr（））
            前进词法单元（advance_tok）（） -- 跳过 ]
            当前节点 = 分配 AST 节点（alloc_node）（下标访问表达式（EXPR_INDEX）, 当前节点, 索引值, 0, 0, 0, 0, 词法单元行号（tok_ln（当前词法单元索引））, 词法单元列号（tok_cl（当前词法单元索引）））
            继续下一次循环
        如果 词法单元类别（tok_k（当前词法单元索引）） 等于 问号（T_QUESTION），那么：
            前进词法单元（advance_tok）（）
            当前节点 = 分配 AST 节点（alloc_node）（尝试表达式（EXPR_TRY）, 当前节点, 0, 0, 0, 0, 0, 词法单元行号（tok_ln（当前词法单元索引））, 词法单元列号（tok_cl（当前词法单元索引）））
            继续下一次循环
        跳出循环
    返回 当前节点
`
### 测试要点
1. "f（变量甲（x）, y）" 产生 调用表达式（EXPR_CALL）（f, 首参数=参数表达式（EXPR_ARG）（变量甲）, 参数计数=2）
2. "某些值（Some）（42）" 首字母大写识别为 枚举构造表达式（EXPR_ENUM_CONSTRUCTOR）
3. "可选类型（Option）::某些值（Some）（42）" 通过路径访问同样识别为枚举构造器
4. "obj.字段（field）" 产生 字段访问表达式（EXPR_FIELD）（obj, 名称（name）=field）
5. "数组（arr）[0]" 产生 下标访问表达式（EXPR_INDEX）（数组, 0）
6. "变量甲（x）?" 产生 尝试表达式（EXPR_TRY）（变量甲）
7. "类型转换（cast）<整数（int）>（x）" 展开为 类型转换表达式（EXPR_AS）（TY_INT）
8. 空参数列表 "f（）" 产生 调用表达式（EXPR_CALL）（f, af=-1, 访问器（ac）=0）
9. 单参数无逗号 "f（x）" 正确产生 访问器（ac）=1

## 函数 判断首字母大写（is_upper_first）
### 作用
判断字符串的首字符是否为大写字母（左操作数（A）~Z）。用于区分标识符是类型/构造器名（大写）还是变量名（小写）。
### 逻辑
`
函数 判断首字母大写（is_upper_first）（s） -> 布尔
    令 首字符（c） = 取字符串第 N 字符（get_char）（状态（s）, 0）
    如果 字符串比较（str_cmp）（首字符, "左操作数（A）"） 大于等于 0 且 字符串比较（str_cmp）（首字符, "Z"） 小于等于 0，那么：返回 真
    返回 假
`
### 测试要点
1. "Foo" 返回真；"foo" 返回假
2. 空字符串行为取决于 取字符串第 N 字符（get_char）（"", 0） 的返回值

## 函数 解析基本表达式（parse_primary）
### 作用
解析所有可能作为后缀链起点的基本表达式。支持的种类：
- 整数字面量（整数字面量（T_INT））：构造 整数字面量表达式（EXPR_INT），数据（data） 槽恒 0
- 浮点字面量（浮点字面量（T_FLOAT））：构造 浮点字面量表达式（EXPR_FLOAT），数据（data） 槽恒 0
> **2026-09-10 R1 语言面收窄 §2 更新**：带位宽后缀的整数（8位整数字面量（T_INT_I8）~64位无符号整数字面量（T_INT_U64））与浮点（32位浮点字面量（T_FLOAT_F32）/64位浮点字面量（T_FLOAT_F64））字面量类别**已删除**——lexer 对数字字面量的字母后缀一律响亮报错，这些类别无生产者（commit ce3e541c）；节点 数据（data） 槽不再承载宽度标注（恒 0）。下方逻辑段中对应宽度分支同批删除。
- 字符串字面量（T_STRING）：构造 字符串字面量表达式（EXPR_STRING）
- 布尔字面量（真关键字（T_TRUE）→数据（data）=1, 假关键字（T_FALSE）→数据=0）：构造 布尔字面量表达式（EXPR_BOOL）
- 无值（None） 字面量（T_NONE）：直接构造 枚举构造表达式（EXPR_ENUM_CONSTRUCTOR）（"无值"）
- 某些值（Some）（T_SOME）：若后跟 `（expr）` 则构造 枚举构造表达式（EXPR_ENUM_CONSTRUCTOR）（"某些值"），否则作为普通标识符
- `@内建（builtin）`（T_AT）：解析 `@名称（name）` 为 属性访问表达式（EXPR_AT），后续参数由后缀解析处理
- 标识符（标识符（T_IDENT）/自身关键字（T_SELF）/下划线（T_UNDERSCORE））：若后跟 `「` 且非禁止结构体字面量模式则解析为结构体字面量 结构构造表达式（EXPR_STRUCT）（字段列表→连续 ast_alloc 节点构成）；否则为 标识符表达式（EXPR_IDENT）
- `（expr）` / 元组 `（e1, e2, ...）`：括号表达式或元组
- 字符字面量（T_CHAR）：构造 字符字面量表达式（EXPR_CHAR）
- 块表达式（T_LBRACE）：委托 解析代码块（parse_block）
- 控制流关键字（如果关键字（T_IF）/当关键字（T_WHILE）/循环关键字（T_LOOP）/遍历关键字（T_FOR）/协程启动关键字（T_GO）/等待关键字（T_AWAIT）/匹配关键字（T_MATCH）/非安全关键字（T_UNSAFE））：委托对应解析函数
- `[elem, ...]` 或 `[值（val）； 统计个数（count）]` 数组字面量：数组表达式（EXPR_ARRAY）；重复构造时复制元素 AST 节点 统计个数-1 份
- 未知词法单元：报错后消费该词法单元防止死循环
### 逻辑
`
函数 解析基本表达式（parse_primary）（） -> 整数
    令 当前词法单元索引（t） = 当前词法单元（cur_tok（））
    -- 整数字面量（2026-09-10 R1 语言面收窄 §2：带位宽后缀分支已删除——lexer 不再发射这些类别）
    如果 词法单元类别（tok_k（当前词法单元索引）） 等于 整数字面量（T_INT），那么：
        前进词法单元（advance_tok）（）
        返回 分配 AST 节点（alloc_node）（整数字面量表达式（EXPR_INT）, 0, 0, 0, 词法单元整数值（tok_iv（当前词法单元索引））, 整数类型（TY_INT）, 0, 词法单元行号（tok_ln（当前词法单元索引））, 词法单元列号（tok_cl（当前词法单元索引）））
    -- 浮点字面量（2026-09-10 R1：T_FLOAT_F32/F64 分支与 W_F32/W_F64 宽度赋值已删除）
    如果 词法单元类别（tok_k（当前词法单元索引）） 等于 浮点字面量（T_FLOAT），那么：
        前进词法单元（advance_tok）（）
        返回 分配 AST 节点（alloc_node）（浮点字面量表达式（EXPR_FLOAT）, 0, 0, 0, 词法单元整数值（tok_iv（当前词法单元索引））, 浮点类型（TY_FLOAT）, 0, 词法单元行号（tok_ln（当前词法单元索引））, 词法单元列号（tok_cl（当前词法单元索引）））
    -- 字符串字面量
    如果 词法单元类别（tok_k（当前词法单元索引）） 等于 字符串字面量（T_STRING），那么：
        前进词法单元（advance_tok）（）
        返回 分配 AST 节点（alloc_node）（字符串字面量表达式（EXPR_STRING）, 0, 0, 0, 字符串驻留（str_intern（tok_lx（当前词法单元索引）））, 字符串类型（TY_STRING）, 0, 词法单元行号（tok_ln（当前词法单元索引））, 词法单元列号（tok_cl（当前词法单元索引）））
    -- 布尔字面量
    如果 词法单元类别（tok_k（当前词法单元索引）） 等于 真关键字（T_TRUE），那么：前进词法单元（advance_tok）（）； 返回 分配 AST 节点（alloc_node）（布尔字面量表达式（EXPR_BOOL）, 0, 0, 0, 1, 布尔类型（TY_BOOL）, 0, 词法单元行号（tok_ln（当前词法单元索引））, 词法单元列号（tok_cl（当前词法单元索引）））
    如果 词法单元类别（tok_k（当前词法单元索引）） 等于 假关键字（T_FALSE），那么：前进词法单元（advance_tok）（）； 返回 分配 AST 节点（alloc_node）（布尔字面量表达式（EXPR_BOOL）, 0, 0, 0, 0, 布尔类型（TY_BOOL）, 0, 词法单元行号（tok_ln（当前词法单元索引））, 词法单元列号（tok_cl（当前词法单元索引）））
    -- 无值（None） 字面量：直接构造枚举构造器
    如果 词法单元类别（tok_k（当前词法单元索引）） 等于 无值关键字（T_NONE），那么：
        前进词法单元（advance_tok）（）
        返回 分配 AST 节点（alloc_node）（枚举构造表达式（EXPR_ENUM_CONSTRUCTOR）, 字符串驻留（str_intern（"无值（None）"））, -1, 0, 0, 0, 0, 词法单元行号（tok_ln（当前词法单元索引））, 词法单元列号（tok_cl（当前词法单元索引）））
    -- 某些值（Some） 字面量
    如果 词法单元类别（tok_k（当前词法单元索引）） 等于 某些关键字（T_SOME），那么：
        前进词法单元（advance_tok）（）
        令 名称索引（ni） = 字符串驻留（str_intern（"某些值（Some）"））
        如果 检查（入口）（T_LPAREN），那么：
            -- 某些值（Some）（expr）：带参数，构造枚举构造器
            前进词法单元（advance_tok）（）； 令 值（val） = 解析表达式（parse_expr（））； 前进词法单元（advance_tok）（）
            返回 分配 AST 节点（alloc_node）（枚举构造表达式（EXPR_ENUM_CONSTRUCTOR）, 名称索引, 值, 1, 0, 0, 0, 词法单元行号（tok_ln（当前词法单元索引））, 词法单元列号（tok_cl（当前词法单元索引）））
        -- 某些值（Some） 无括号：作为普通标识符（后续由首字母大写判定为枚举构造器）
        返回 分配 AST 节点（alloc_node）（标识符表达式（EXPR_IDENT）, 0, 0, 0, 名称索引, 0, 0, 词法单元行号（tok_ln（当前词法单元索引））, 词法单元列号（tok_cl（当前词法单元索引）））
    -- @内建（builtin） 内建调用
    如果 词法单元类别（tok_k（当前词法单元索引）） 等于 @符号（T_AT），那么：
        前进词法单元（advance_tok）（）
        如果 词法单元类别（tok_k（cur_tok（））） 等于 标识符（T_IDENT），那么：
            令 名称索引（name_ni） = 字符串驻留（str_intern（tok_lx（cur_tok（））））； 前进词法单元（advance_tok）（）
            -- 参数由后缀解析处理（args_node=-1 表示无参数）
            返回 分配 AST 节点（alloc_node）（属性访问表达式（EXPR_AT）, 名称索引, -1, 0, 0, 0, 0, 词法单元行号（tok_ln（当前词法单元索引））, 词法单元列号（tok_cl（当前词法单元索引）））
        添加错误（add_error）（"期望（expected） identifier after @"）
        返回 分配 AST 节点（alloc_node）（0, 0, 0, 0, 0, 单元类型（TY_UNIT）, 0, 词法单元行号（tok_ln（当前词法单元索引））, 词法单元列号（tok_cl（当前词法单元索引）））
    -- 标识符 / 自身（self） / 下划线
    如果 词法单元类别（tok_k（当前词法单元索引）） 等于 标识符（T_IDENT） 或 词法单元类别（tok_k（当前词法单元索引）） 等于 自身关键字（T_SELF） 或 词法单元类别（tok_k（当前词法单元索引）） 等于 下划线（T_UNDERSCORE），那么：
        前进词法单元（advance_tok）（）
        令 名称（name） = 词法单元词素索引（tok_lx（当前词法单元索引））
        令 名称索引（ni） = 字符串驻留（str_intern（名称））
-- 结构体字面量：名称（Name） 「 字段（field） = 值（value）, ... 」，仅在未禁止时解析
        如果 检查（入口）（T_LBRACE） 且 解析器禁止结构体字面量标记（g_parse_no_struct_literal） 等于 0，那么：
            前进词法单元（advance_tok）（）
            令 首字段索引（ff） = -1
            令 字段计数（fc） = 0（可变）
            循环（当 真 时）：
                如果 检查（入口）（T_RBRACE），那么：跳出循环
                令 字段词法单元索引（ft） = 前进词法单元（advance_tok）（）
                令 字段名称索引（fni） = 字符串驻留（str_intern（tok_lx（字段词法单元索引）））
                前进词法单元（advance_tok）（） -- 跳过 =
                令 字段值（fv） = 解析表达式（parse_expr（））
                -- 字段以独立节点存入 AST 数组（连续排列）
                AST 访问器：分配（ast_alloc）（0, 字段值, 0, 0, 0, 0, 0, 词法单元行号（tok_ln（字段词法单元索引））, 词法单元列号（tok_cl（字段词法单元索引）））
                如果 字段计数 等于 0，那么：首字段索引 = AST 节点计数（g_ast_count） - 1
                字段计数 = 字段计数 + 1
                如果 检查（入口）（T_COMMA），那么：前进词法单元（advance_tok）（）
前进词法单元（advance_tok）（） -- 跳过 」
            返回 分配 AST 节点（alloc_node）（结构构造表达式（EXPR_STRUCT）, 名称索引, 首字段索引, 字段计数, 0, 0, 0, 词法单元行号（tok_ln（当前词法单元索引））, 词法单元列号（tok_cl（当前词法单元索引）））
        返回 分配 AST 节点（alloc_node）（标识符表达式（EXPR_IDENT）, 0, 0, 0, 名称索引, 0, 0, 词法单元行号（tok_ln（当前词法单元索引））, 词法单元列号（tok_cl（当前词法单元索引）））
    -- 括号表达式或元组
    如果 词法单元类别（tok_k（当前词法单元索引）） 等于 左圆括号（T_LPAREN），那么：
        前进词法单元（advance_tok）（）
        令 保存的禁止结构体字面量标记（saved_nsl） = 解析器禁止结构体字面量标记（g_parse_no_struct_literal）
        解析器禁止结构体字面量标记（g_parse_no_struct_literal） = 0
        令 表达式节点（e） = 解析表达式（parse_expr（））
        解析器禁止结构体字面量标记（g_parse_no_struct_literal） = 保存的禁止结构体字面量标记
        如果 检查（入口）（T_COMMA），那么：
            -- 元组：（e1, e2, ...）
            令 首元素表达式（ef） = 表达式节点
            令 元素计数（ec） = 1（可变）
            循环（当 真 时）：
                前进词法单元（advance_tok）（） -- 跳过 ,
                解析表达式（parse_expr（）） -- 后续元素存入连续 AST 槽位
                元素计数 = 元素计数 + 1
                如果 非 检查（入口）（T_COMMA），那么：跳出循环
            前进词法单元（advance_tok）（） -- 跳过 ）
            返回 分配 AST 节点（alloc_node）（元组表达式（EXPR_TUPLE）, 首元素表达式, 元素计数, 0, 0, 0, 0, 词法单元行号（tok_ln（当前词法单元索引））, 词法单元列号（tok_cl（当前词法单元索引）））
        前进词法单元（advance_tok）（） -- 跳过 ），单元素括号表达式直接返回
        返回 表达式节点
    -- 字符字面量
    如果 词法单元类别（tok_k（当前词法单元索引）） 等于 字符字面量（T_CHAR），那么：
        前进词法单元（advance_tok）（）
        返回 分配 AST 节点（alloc_node）（字符字面量表达式（EXPR_CHAR）, 0, 0, 0, 字符串驻留（str_intern（tok_lx（当前词法单元索引）））, 字符类型（TY_CHAR）, 0, 词法单元行号（tok_ln（当前词法单元索引））, 词法单元列号（tok_cl（当前词法单元索引）））
    -- 委托到其他解析函数
    如果 词法单元类别（tok_k（当前词法单元索引）） 等于 左花括号（T_LBRACE），那么：返回 解析代码块（parse_block（））
    如果 词法单元类别（tok_k（当前词法单元索引）） 等于 如果关键字（T_IF），那么：返回 解析 如果（if） 表达式（parse_if_expr（））
    如果 词法单元类别（tok_k（当前词法单元索引）） 等于 当关键字（T_WHILE），那么：返回 解析 当（while） 表达式（parse_while_expr（））
    如果 词法单元类别（tok_k（当前词法单元索引）） 等于 循环关键字（T_LOOP），那么：返回 解析 循环（loop） 表达式（parse_loop_expr（））
    如果 词法单元类别（tok_k（当前词法单元索引）） 等于 遍历关键字（T_FOR），那么：返回 解析 遍历（for） 表达式（parse_for_expr（））
    -- 协程启动（go） 并发表达式
    如果 词法单元类别（tok_k（当前词法单元索引）） 等于 协程启动关键字（T_GO），那么：
        令 第二个词法单元索引（t2） = 前进词法单元（advance_tok）（）
        如果 检查（入口）（T_SEMI） 或 检查（入口）（T_RBRACE） 或 检查（入口）（T_EOF），那么：
            添加错误（add_error）（"Expected expression after `协程启动（go）`"）； 返回 0
        令 并发计数（count） = -1（可变）
        令 迭代变量名称索引（iter_var_ni） = -1（可变）
        令 范围起始（range_start） = -1（可变）
        令 范围结束（range_end） = -1（可变）
        -- 尝试范围模式：协程启动（go） 变量（var） 开始（start）..结束（end） 表达式（expr）
        令 保存的位置（saved_pos） = 当前词法单元位置（g_token_pos）（可变）
        如果 词法单元类别（tok_k（cur_tok（））） 等于 标识符（T_IDENT），那么：
            令 变量名称索引（vn） = 字符串驻留（str_intern（tok_lx（cur_tok（））））； 前进词法单元（advance_tok）（）
            如果 词法单元类别（tok_k（cur_tok（））） 等于 整数字面量（T_INT），那么：
                迭代变量名称索引 = 变量名称索引
                范围起始 = 词法单元整数值（tok_iv（cur_tok（）））； 前进词法单元（advance_tok）（）
                如果 词法单元类别（tok_k（cur_tok（））） 等于 双点号（T_DOTDOT），那么：
                    前进词法单元（advance_tok）（）
                    如果 词法单元类别（tok_k（cur_tok（））） 等于 整数字面量（T_INT），那么：
                        范围结束 = 词法单元整数值（tok_iv（cur_tok（）））； 前进词法单元（advance_tok）（）
                    令 循环体（body） = 解析表达式（parse_expr（））
                    令 范围节点（range_node） = 分配 AST 节点（alloc_node）（范围表达式（EXPR_RANGE）, 范围起始, 范围结束, 0, 0, 0, 0, 词法单元行号（tok_ln（第二个词法单元索引））, 词法单元列号（tok_cl（第二个词法单元索引）））
                    返回 分配 AST 节点（alloc_node）（协程启动表达式（EXPR_GO）, -1, 循环体, 迭代变量名称索引, 0, 0, 范围节点, 词法单元行号（tok_ln（第二个词法单元索引））, 词法单元列号（tok_cl（第二个词法单元索引）））
            -- 非范围模式，回溯
            当前词法单元位置（g_token_pos） = 保存的位置
        -- 单表达式 协程启动（go）：协程启动 表达式（expr）
        令 循环体（body） = 解析表达式（parse_expr（））
        返回 分配 AST 节点（alloc_node）（协程启动表达式（EXPR_GO）, 并发计数, 循环体, 0, 0, 0, 0, 词法单元行号（tok_ln（第二个词法单元索引））, 词法单元列号（tok_cl（第二个词法单元索引）））
    -- 等待（await） 异步等待表达式
    如果 词法单元类别（tok_k（当前词法单元索引）） 等于 等待关键字（T_AWAIT），那么：
        令 第二个词法单元索引（t2） = 前进词法单元（advance_tok）（）； 令 值（val） = 解析表达式（parse_expr（））
        返回 分配 AST 节点（alloc_node）（等待表达式（EXPR_AWAIT）, 值, 0, 0, 0, 0, 0, 词法单元行号（tok_ln（第二个词法单元索引））, 词法单元列号（tok_cl（第二个词法单元索引）））
    -- 委托：匹配（match） / 非安全（unsafe）
    如果 词法单元类别（tok_k（当前词法单元索引）） 等于 匹配关键字（T_MATCH），那么：返回 解析 匹配（match） 表达式（parse_match_expr（））
    如果 词法单元类别（tok_k（当前词法单元索引）） 等于 非安全关键字（T_UNSAFE），那么：
        令 第二个词法单元索引（t2） = 前进词法单元（advance_tok）（）； 令 循环体（body） = 解析代码块（parse_block（））
        返回 分配 AST 节点（alloc_node）（非安全块表达式（EXPR_UNSAFE）, 循环体, 0, 0, 0, 0, 0, 词法单元行号（tok_ln（第二个词法单元索引））, 词法单元列号（tok_cl（第二个词法单元索引）））
    -- 数组字面量
    如果 词法单元类别（tok_k（当前词法单元索引）） 等于 左方括号（T_LBRACKET），那么：
        前进词法单元（advance_tok）（）
        令 首元素表达式（ef） = -1
        令 元素计数（ec） = 0（可变）
        如果 非 检查（入口）（T_RBRACKET），那么：
            首元素表达式 = 解析表达式（parse_expr（））
            元素计数 = 1
            如果 检查（入口）（T_SEMI），那么：
                -- 重复构造数组：[值（value）； 统计个数（count）]
                前进词法单元（advance_tok）（）
                令 计数词法单元（ct） = 前进词法单元（advance_tok）（）
                令 重复计数（cnt） = 词法单元整数值（tok_iv（计数词法单元））（可变）
                令 复制索引（ri） = 1（可变）
                循环（当 复制索引 小于 重复计数 时）：
                    -- 逐份复制元素 AST 节点
                    AST 访问器：分配（ast_alloc）（AST 访问器：类别（ast_kind（首元素表达式））, 第一子节点访问器（ast_a（首元素表达式））, 第二子节点访问器（ast_b（首元素表达式））, 第三子节点访问器（ast_c（首元素表达式））, AST 访问器：整数值（ast_int_val（首元素表达式））, AST 访问器：类型值（ast_type_val（首元素表达式））, AST 访问器：数据（ast_data（首元素表达式））, AST 访问器：行号（ast_line（首元素表达式））, AST 访问器：列号（ast_col（首元素表达式）））
                    复制索引 = 复制索引 + 1
                元素计数 = 重复计数
            否则：
                -- 逐个元素：[变量甲（a）, 变量乙（b）, 变量丙（c）]
                循环（当 真 时）：
                    如果 非 检查（入口）（T_COMMA），那么：跳出循环
                    前进词法单元（advance_tok）（）
                    解析表达式（parse_expr（）） -- 解析剩余元素
                    元素计数 = 元素计数 + 1
        前进词法单元（advance_tok）（） -- 跳过 ]
        返回 分配 AST 节点（alloc_node）（数组表达式（EXPR_ARRAY）, 首元素表达式, 元素计数, 0, 0, 0, 0, 词法单元行号（tok_ln（当前词法单元索引））, 词法单元列号（tok_cl（当前词法单元索引）））
    -- 未识别词法单元：报错并消费一单位防止死循环
    添加错误（add_error）（"Unexpected token in expression"）
    前进词法单元（advance_tok）（）
    返回 0
`
### 测试要点
1. "42" 产生 整数字面量表达式（EXPR_INT）（iv=42, w=0）；"42u8" 产生 整数字面量表达式（iv=42, w=8位无符号宽度（W_U8），来自后缀/词法单元类别）
2. "true" 产生 布尔字面量表达式（EXPR_BOOL）（数据（data）=1）；"false" 产生 布尔字面量表达式（数据=0）
3. "无值（None）" 产生 枚举构造表达式（EXPR_ENUM_CONSTRUCTOR）（"无值", 参数=-1）
4. "某些值（Some）（x）" 产生 枚举构造表达式（EXPR_ENUM_CONSTRUCTOR）（"某些值", 参数=变量甲, 计数=1）
5. "某些值（Some）" 无括号时产生 标识符表达式（EXPR_IDENT）
6. "变量甲（x） 「变量甲（a） = 1, 变量乙（b） = 2」" 在 解析器禁止结构体字面量标记（g_parse_no_struct_literal）=0 时产生 结构构造表达式（EXPR_STRUCT）（变量甲, 字段计数=2）
7. "@内建（builtin）" 产生 属性访问表达式（EXPR_AT）（name=内建）
8. "（1, 2, 3）" 产生 元组表达式（EXPR_TUPLE）（元素计数=3）
9. "协程启动（go） 变量甲（x）" 产生 协程启动表达式（EXPR_GO）（并发计数=-1, 循环体=变量甲）
10. "协程启动（go） 索引（i） 0..10 函数体（AST 节点）（body）" 产生 协程启动表达式（EXPR_GO）（range_node=范围表达式（EXPR_RANGE）（0,10）, 迭代变量名称索引=索引）
11. "等待（await） f" 产生 等待表达式（EXPR_AWAIT）（f）
12. "[0； 10]" 产生 数组表达式（EXPR_ARRAY）（元素计数=10），元素为重复的 0
13. "[变量甲（a）, 变量乙（b）, 变量丙（c）]" 产生 数组表达式（EXPR_ARRAY）（元素计数=3）
14. 未知词法单元报错且消费一单位防止死循环

## 函数 解析代码块（parse_block）
### 作用
解析花括号包围的语句序列。先消费 `「`，然后循环调用 解析语句（parse_stmt） 收集局部语句列表（最多 256 条，缓冲区动态分配），遇到 `」` 或 文件结束标记（EOF） 时停止（深度超过 1024 时报错）。收集完毕后消费 `」`，将局部语句列表刷写入全局代码块语句数组 代码块语句数组（g_block_stmts），返回 代码块表达式（EXPR_BLOCK） 节点（变量甲（a）=块语句起始索引, 变量乙（b）=语句个数）。
### 逻辑
`
函数 解析代码块（parse_block）（） -> 整数
令 起始位置（t） = 前进词法单元（advance_tok）（） -- 消费 「
    令 局部语句缓冲区（local_stmts） = 分配函数（alloc）（256 * 8）（可变）
    令 局部语句缓冲区容量（local_stmts_cap） = 256（可变）
    令 语句计数（sc） = 0（可变）
    循环（当 真 时）：
        如果 检查（入口）（T_RBRACE） 或 检查（入口）（T_EOF），那么：跳出循环
        如果 语句计数 大于 1024，那么：添加错误（add_error）（"块（block） too deep"）； 跳出循环
        令 语句节点（st） = 解析语句（parse_stmt（））
        如果 语句计数 小于 256，那么：写 64 位（w64）（局部语句缓冲区, 语句计数 * 8, 语句节点）
        语句计数 = 语句计数 + 1
前进词法单元（advance_tok）（） -- 消费 」
    -- 将局部语句刷写入全局代码块语句数组（各块独立分段，互不干扰）
    令 起始索引（si） = 代码块语句计数（g_block_stmt_count）
    令 索引（i） = 0（可变）
    循环（当 索引 小于 语句计数 时）：
        扩展代码块语句数组（grow_block_stmts）（代码块语句计数（g_block_stmt_count） + 1）
        写 64 位（w64）（代码块语句数组（g_block_stmts）, 代码块语句计数（g_block_stmt_count） * 8, 读 64 位（r64）（局部语句缓冲区, 索引 * 8））
        代码块语句计数（g_block_stmt_count） = 代码块语句计数（g_block_stmt_count） + 1
        索引 = 索引 + 1
    返回 分配 AST 节点（alloc_node）（代码块表达式（EXPR_BLOCK）, 起始索引, 语句计数, 0, 0, 0, 0, 词法单元行号（tok_ln（起始位置））, 词法单元列号（tok_cl（起始位置）））
`
### 测试要点
1. 空块 "「」" 返回 代码块表达式（EXPR_BLOCK）（si, sc=0）
2. 单语句块 "「 变量甲（x）； 」" 返回 代码块表达式（EXPR_BLOCK）（sc=1）
3. 深度超过 1024 时报错停止
4. 嵌套块各自刷入不同段（各 块（block） 有独立的 si）

## 函数 判断新变量声明（is_new_var_decl）
### 作用
向前查看词法单元序列，判断当前位置是否开启了新变量声明。识别三种模式：
- `变量甲（x） := 表达式（expr）`（标识符（T_IDENT） 后跟 冒号等号（T_COLON_EQ））
- `变量甲（x） : 类型（type） ...`（标识符（T_IDENT） 后跟 冒号（T_COLON））
- `变量甲（a）, 变量乙（b）, ..., 变量乙（z） : 类型（type） ...` 或 `变量甲, 变量乙, ..., 变量乙 := ...`（批量声明，任意个 标识符（T_IDENT） 以逗号分隔，最后一个 标识符 后跟 `:` 或 `:=`）
### 逻辑
`
函数 判断新变量声明（is_new_var_decl）（） -> 布尔
    令 位置索引（p） = 当前词法单元（cur_tok（））
    如果 词法单元类别（tok_k（位置索引）） 不等于 标识符（T_IDENT），那么：返回 假
    -- 模式一：变量甲（x） := 表达式（expr）
    如果 词法单元类别（tok_k（位置索引 + 1）） 等于 冒号等号（T_COLON_EQ），那么：返回 真
    -- 模式二：变量甲（x） : 类型（type） ...
    如果 词法单元类别（tok_k（位置索引 + 1）） 等于 冒号（T_COLON），那么：返回 真
    -- 模式三：变量甲（a）, 变量乙（b）, ..., 变量乙（z） : 类型（type） ... 或 变量甲, 变量乙, ..., 变量乙 := ...（批量声明）
    如果 词法单元类别（tok_k（位置索引 + 1）） 等于 逗号（T_COMMA），那么：
        令 索引（i） = 2（可变）
        循环（当 真 时）：
            如果 词法单元类别（tok_k（位置索引 + 索引）） 等于 标识符（T_IDENT） 且 词法单元类别（tok_k（位置索引 + 索引 + 1）） 等于 逗号（T_COMMA），那么：
                索引 = 索引 + 2； 继续下一次循环
            如果 词法单元类别（tok_k（位置索引 + 索引）） 等于 标识符（T_IDENT） 且 （词法单元类别（tok_k（位置索引 + 索引 + 1）） 等于 冒号（T_COLON） 或 词法单元类别（tok_k（位置索引 + 索引 + 1）） 等于 冒号等号（T_COLON_EQ）），那么：返回 真
            跳出循环
    返回 假
`
### 测试要点
1. "变量甲（x） := 1" 返回真
2. "变量甲（x） : 整数（int） = 1" 返回真
3. "变量甲（a）, 变量乙（b） : 整数（int） = 1, 2" 返回真
4. "变量甲（x） + 1" 返回假（非 标识符（T_IDENT） 开头或后非 :/:=）

## 函数 解析新变量声明（parse_new_var_decl）
### 作用
解析变量声明语句。处理流程：
1. 解析名字列表（逗号分隔的标识符序列）
2. 若为 `:=` 则解析右侧表达式列表
3. 若为 `: 类型（type）` 则解析类型，可选标签（可变（mut）, 公开（pub）, 插件标签），再解析 `= expr_list`
4. 为每个名字生成 变量声明表达式（EXPR_LET） 节点（变量甲（a）=名称索引, 变量乙（b）=类型节点, 变量丙（c）=值节点, 数据（data）=is_mut）
5. 第一个声明节点直接返回，额外声明存入 额外声明数组（g_extra_lets）（供 parse_stmt 逐个排出）
### 逻辑
`
函数 解析新变量声明（parse_new_var_decl）（） -> 整数
    令 起始位置（t） = 当前词法单元（cur_tok（））
    -- 第一步：解析名字列表（逗号分隔）
    令 名字缓冲区（names） = 分配函数（alloc）（64 * 8）； 令 名字缓冲区容量（names_cap） = 64
    令 名字计数（nc） = 0（可变）
    令 名字词法单元（nt） = 前进词法单元（advance_tok）（）
    写 64 位（w64）（名字缓冲区, 名字计数 * 8, 词法单元词素索引（tok_lx（名字词法单元）））
    名字计数 = 名字计数 + 1
    -- 批量名字：变量甲（a）, 变量乙（b）, 变量丙（c）
    如果 检查（入口）（T_COMMA），那么：
        循环（当 真 时）：
            如果 非 检查（入口）（T_COMMA），那么：跳出循环
            前进词法单元（advance_tok）（）
            令 第二个名字词法单元（nt2） = 前进词法单元（advance_tok）（）
            写 64 位（w64）（名字缓冲区, 名字计数 * 8, 词法单元词素索引（tok_lx（第二个名字词法单元）））
            名字计数 = 名字计数 + 1
    -- 第二步：解析类型、标签和值
    令 类型节点（typ） = -1（可变）
    令 是否可变（is_mut） = 0（可变）
    令 是否公开（is_pub） = 0（可变）
    令 值缓冲区（values） = 分配函数（alloc）（64 * 8）； 令 值缓冲区容量（values_cap） = 64
    令 值计数（vc） = 0（可变）
    -- 分支 左操作数（A）：:= 语法（类型推断）
    如果 检查（入口）（T_COLON_EQ），那么：
        前进词法单元（advance_tok）（）
        写 64 位（w64）（值缓冲区, 值计数 * 8, 解析表达式（parse_expr（）））； 值计数 = 值计数 + 1
        循环（当 真 时）：
            如果 非 检查（入口）（T_COMMA），那么：跳出循环
            前进词法单元（advance_tok）（）； 写 64 位（w64）（值缓冲区, 值计数 * 8, 解析表达式（parse_expr（）））； 值计数 = 值计数 + 1
    否则：
        -- 分支 B：: 类型（type） 语法
        前进词法单元（advance_tok）（） -- 跳过 :
        -- 自动类型推导（auto 或 .）
        如果 词法单元类别（tok_k（cur_tok（））） 等于 自动类型词法单元（T_AUTO） 或 词法单元类别（tok_k（cur_tok（））） 等于 点号（T_DOT），那么：
            类型节点 = -1； 前进词法单元（advance_tok）（）
        否则：类型节点 = 解析类型（parse_type（））
        -- 可选标签（可变（mut）, 公开（pub）, 插件扩展标签）
        如果 检查（入口）（T_COMMA），那么：
            前进词法单元（advance_tok）（）
            循环（当 真 时）：
                如果 检查（入口）（T_EQ） 或 检查（入口）（T_SEMI） 或 检查（入口）（T_EOF），那么：跳出循环
                令 标签词法单元索引（tag_t） = 前进词法单元（advance_tok）（）
                令 标签（tag） = 词法单元词素索引（tok_lx（标签词法单元索引））
                如果 标签 等于 "可变（mut）"，那么：是否可变 = 1
                否则如果 标签 等于 "公开（pub）"，那么：是否公开 = 1
                否则：
                    -- 查找插件标签：匹配则读取其数据位
                    令 标签名称索引（tni） = 字符串驻留（str_intern（标签））
                    令 扩展索引（ei） = 查找插件入口（find_plugin_entry）（g_plugin_tags, 插件标签计数（g_plugin_tag_count）, 标签名称索引, -1）
                    如果 扩展索引 大于等于 0，那么：
                        令 插件数据（pd） = 读 64 位（r64）（g_plugin_tags, 扩展索引 * 24 + 16）
                        如果 插件数据 不等于 0，那么：是否可变 = 1
                如果 非 检查（入口）（T_COMMA），那么：跳出循环
                前进词法单元（advance_tok）（）
        -- 初始化值缓冲区第一项为 -1（若无可选等号则无值）
        写 64 位（w64）（值缓冲区, 0 * 8, -1）
        -- 解析值列表
        如果 检查（入口）（T_EQ），那么：
            前进词法单元（advance_tok）（）
            写 64 位（w64）（值缓冲区, 值计数 * 8, 解析表达式（parse_expr（）））； 值计数 = 值计数 + 1
            循环（当 真 时）：
                如果 非 检查（入口）（T_COMMA），那么：跳出循环
                前进词法单元（advance_tok）（）； 写 64 位（w64）（值缓冲区, 值计数 * 8, 解析表达式（parse_expr（）））； 值计数 = 值计数 + 1
    -- 可选尾部分号
    如果 检查（入口）（T_SEMI），那么：前进词法单元（advance_tok）（）
    -- 第三步：为每个名字生成 变量声明指令（LET） 节点
    令 首个节点（first_node） = -1（可变）
    令 索引（i） = 0（可变）
    循环（当 索引 小于 名字计数 时）：
        令 名称索引（ni） = 字符串驻留（str_intern（读 64 位（r64）（名字缓冲区, 索引 * 8）））
        令 节点值（nv） = 读 64 位（r64）（值缓冲区, 索引 * 8）
        令 节点（node） = 分配 AST 节点（alloc_node）（变量声明表达式（EXPR_LET）, 名称索引, 类型节点, 节点值, 0, 0, 是否可变, 词法单元行号（tok_ln（起始位置））, 词法单元列号（tok_cl（起始位置）））
        如果 索引 等于 0，那么：首个节点 = 节点
        否则：
            -- 额外声明存入 额外声明数组（g_extra_lets），由 解析语句（parse_stmt） 逐个排出
            如果 额外声明容量（g_extra_lets_cap） 等于 0，那么：额外声明数组（g_extra_lets） = 分配函数（alloc）（128）； 额外声明容量（g_extra_lets_cap） = 16
            如果 额外声明计数（g_extra_let_count） 小于 额外声明容量（g_extra_lets_cap），那么：
                写 64 位（w64）（额外声明数组（g_extra_lets）, 额外声明计数（g_extra_let_count） * 8, 节点）
                额外声明计数（g_extra_let_count） = 额外声明计数（g_extra_let_count） + 1
        索引 = 索引 + 1
    返回 首个节点
`
### 测试要点
1. "变量甲（x） := 42" 产生 变量声明表达式（EXPR_LET）（名称=变量甲, 值=42）
2. "变量甲（x） : 整数（int） = 42" 产生 变量声明表达式（EXPR_LET）（名称=变量甲, 类型=整数类型（TY_INT）, 值=42）
3. "变量甲（a）, 变量乙（b） := 1, 2" 第一个返回 变量声明表达式（EXPR_LET）（变量甲,1），第二个在 额外声明数组（g_extra_lets） 中
4. "变量甲（x） : ., 可变（mut） = 42" 产生 变量声明表达式（EXPR_LET）（名称=变量甲, 值=42, 数据=是否可变=1）
5. 值不足名字数时 节点值 取 -1

## 函数 解析语句（parse_stmt）
### 作用
语句解析入口。首先将上一调用残留的额外声明（g_extra_lets）排出（每次返回一个），排出完毕后才读取当前词法单元进行正常解析：
- 新变量声明（标识符（T_IDENT） + is_new_var_decl）→ 解析新变量声明（parse_new_var_decl）
- 返回（return） [表达式（expr）] → 返回表达式（EXPR_RETURN）
- 让出（yield） [表达式（expr）] → 让出表达式（EXPR_YIELD）（无表达式时为纯暂停）
- 跳出（break） → 跳出表达式（EXPR_BREAK）
- 继续（continue） → 继续表达式（EXPR_CONTINUE）
- 普通表达式 → 后跟 `；` 则包裹为 语句表达式（EXPR_STMT）（表达式语句），否则直接返回表达式
### 逻辑
`
函数 解析语句（parse_stmt）（） -> 整数
    -- 优先排出上次调用残留的额外声明（每次调用消耗一个）
    如果 额外声明计数（g_extra_let_count） 大于 0，那么：
        额外声明计数（g_extra_let_count） = 额外声明计数（g_extra_let_count） - 1
        返回 读 64 位（r64）（额外声明数组（g_extra_lets）, 额外声明计数（g_extra_let_count） * 8）
    令 起始位置（t） = 当前词法单元（cur_tok（））
    -- 新变量声明
    如果 词法单元类别（tok_k（起始位置）） 等于 标识符（T_IDENT） 且 判断新变量声明（is_new_var_decl（）），那么：返回 解析新变量声明（parse_new_var_decl（））
    -- 返回（return） [表达式（expr）]
    如果 词法单元类别（tok_k（起始位置）） 等于 返回关键字（T_RETURN），那么：
        前进词法单元（advance_tok）（）； 令 返回值（val） = -1（可变）
        如果 非 检查（入口）（T_SEMI） 且 非 检查（入口）（T_RBRACE），那么：返回值 = 解析表达式（parse_expr（））
        如果 检查（入口）（T_SEMI），那么：前进词法单元（advance_tok）（）
        返回 分配 AST 节点（alloc_node）（返回表达式（EXPR_RETURN）, 返回值, 0, 0, 0, 0, 0, 词法单元行号（tok_ln（起始位置））, 词法单元列号（tok_cl（起始位置）））
    -- 让出（yield） [表达式（expr）]
    如果 词法单元类别（tok_k（起始位置）） 等于 让出关键字（T_YIELD），那么：
        前进词法单元（advance_tok）（）； 令 返回值（val） = -1（可变）
        -- 裸 让出（yield）； 为纯暂停（无值）；仅当后跟表达式时才解析
        如果 非 检查（入口）（T_SEMI） 且 非 检查（入口）（T_RBRACE），那么：返回值 = 解析表达式（parse_expr（））
        如果 检查（入口）（T_SEMI），那么：前进词法单元（advance_tok）（）
        返回 分配 AST 节点（alloc_node）（让出表达式（EXPR_YIELD）, 返回值, 0, 0, 0, 0, 0, 词法单元行号（tok_ln（起始位置））, 词法单元列号（tok_cl（起始位置）））
    -- 跳出（break）
    如果 词法单元类别（tok_k（起始位置）） 等于 跳出关键字（T_BREAK），那么：
        前进词法单元（advance_tok）（）； 如果 检查（入口）（T_SEMI），那么：前进词法单元（advance_tok）（）
        返回 分配 AST 节点（alloc_node）（跳出表达式（EXPR_BREAK）, 0, 0, 0, 0, 0, 0, 词法单元行号（tok_ln（起始位置））, 词法单元列号（tok_cl（起始位置）））
    -- 继续（continue）
    如果 词法单元类别（tok_k（起始位置）） 等于 继续关键字（T_CONTINUE），那么：
        前进词法单元（advance_tok）（）； 如果 检查（入口）（T_SEMI），那么：前进词法单元（advance_tok）（）
        返回 分配 AST 节点（alloc_node）（继续表达式（EXPR_CONTINUE）, 0, 0, 0, 0, 0, 0, 词法单元行号（tok_ln（起始位置））, 词法单元列号（tok_cl（起始位置）））
    -- 普通表达式
    令 表达式节点（e） = 解析表达式（parse_expr（））
    -- 后跟分号则包裹为表达式语句；否则直接返回（用于块尾表达式）
    如果 检查（入口）（T_SEMI），那么：
        前进词法单元（advance_tok）（）
        返回 分配 AST 节点（alloc_node）（语句表达式（EXPR_STMT）, 表达式节点, 0, 0, 0, 0, 0, 词法单元行号（tok_ln（起始位置））, 词法单元列号（tok_cl（起始位置）））
    返回 表达式节点
`
### 测试要点
1. 额外声明先排出：第二次调用 解析语句（parse_stmt） 时先返回 变量甲（a）,变量乙（b） 中的 变量乙
2. "返回（return） 42；" 产生 返回表达式（EXPR_RETURN）（返回值=42）
3. "返回（return）；" 产生 返回表达式（EXPR_RETURN）（返回值=-1）
4. "让出（yield）；" 无表达式时产生 让出表达式（EXPR_YIELD）（返回值=-1）（纯暂停）
5. "跳出（break）；" "继续（continue）；" 产生对应节点
6. "变量甲（x） + 1；" 产生 语句表达式（EXPR_STMT）（二元运算表达式（EXPR_BINARY）（...））
7. 块内最后一条表达式无反分号时直接返回（非 STMT 包裹）

## 函数 解析 如果（if） 表达式（parse_if_expr）
### 作用
解析 `如果（if） 条件 「 那么（then）块 」 [否则（else） 「 否则块 」 | 否则 如果 ...]` 表达式。条件上下文禁用结构体字面量（设置 g_parse_no_struct_literal=1）。否则 分支若以 `如果` 开头则递归调用自身形成 否则-如果 链。
### 逻辑
`
函数 解析 如果（if） 表达式（parse_if_expr）（） -> 整数
    令 起始位置（t） = 前进词法单元（advance_tok）（） -- 跳过 如果（if）
    -- 条件上下文中禁用结构体字面量解析
    令 保存的禁止结构体字面量标记（saved_nsl） = 解析器禁止结构体字面量标记（g_parse_no_struct_literal）
    解析器禁止结构体字面量标记（g_parse_no_struct_literal） = 1
    令 条件节点（cond） = 解析表达式（parse_expr（））
    解析器禁止结构体字面量标记（g_parse_no_struct_literal） = 保存的禁止结构体字面量标记
    令 真分支体（tb） = 解析代码块（parse_block（））
    令 假分支体（eb） = -1（可变）
    如果 检查（入口）（T_ELSE），那么：
        前进词法单元（advance_tok）（）
        -- 否则（else） 如果（if） 递归调用形成 否则-如果 链
        如果 检查（入口）（T_IF），那么：假分支体 = 解析 如果（if） 表达式（parse_if_expr（））
        否则：假分支体 = 解析代码块（parse_block（））
    返回 分配 AST 节点（alloc_node）（条件表达式（EXPR_IF）, 条件节点, 真分支体, 假分支体, 0, 0, 0, 词法单元行号（tok_ln（起始位置））, 词法单元列号（tok_cl（起始位置）））
`
### 测试要点
1. "如果（if） 变量甲（x） 「 变量甲（a） 」" 产生 条件表达式（EXPR_IF）（条件=变量甲, 真分支=变量甲, 假分支=-1）
2. "如果（if） 变量甲（x） 「 变量甲（a） 」 否则（else） 「 变量乙（b） 」" 产生 条件表达式（EXPR_IF）（条件=变量甲, 真分支=变量甲, 假分支=变量乙）
3. "如果（if） 变量甲（x） 「 变量甲（a） 」 否则（else） 如果 y 「 变量乙（b） 」 否则 「 变量丙（c） 」" 产生嵌套 条件表达式（EXPR_IF）（孙节点=条件表达式（y, 第二子节点（变量乙）, 变量丙））
4. 条件内 `「` 不解析为结构体字面量

## 函数 解析 循环（loop） 表达式（parse_loop_expr）
### 作用
解析 `循环（loop） 「 函数体（AST 节点）（body） 」` 无限循环表达式。
### 逻辑
`
函数 解析 循环（loop） 表达式（parse_loop_expr）（） -> 整数
    令 起始位置（t） = 前进词法单元（advance_tok）（）
    令 循环体（body） = 解析代码块（parse_block（））
    返回 分配 AST 节点（alloc_node）（无限循环表达式（EXPR_LOOP）, 循环体, 0, 0, 0, 0, 0, 词法单元行号（tok_ln（起始位置））, 词法单元列号（tok_cl（起始位置）））
`
### 测试要点
1. "循环（loop） 「 」" 产生 无限循环表达式（EXPR_LOOP）（body=空块）

## 函数 解析 当（while） 表达式（parse_while_expr）
### 作用
解析 `当（while） 条件 「 函数体（AST 节点）（body） 」` 条件循环表达式。
### 逻辑
`
函数 解析 当（while） 表达式（parse_while_expr）（） -> 整数
    令 起始位置（t） = 前进词法单元（advance_tok）（）
    令 条件节点（cond） = 解析表达式（parse_expr（））
    令 循环体（body） = 解析代码块（parse_block（））
    返回 分配 AST 节点（alloc_node）（条件循环表达式（EXPR_WHILE）, 条件节点, 循环体, 0, 0, 0, 0, 词法单元行号（tok_ln（起始位置））, 词法单元列号（tok_cl（起始位置）））
`
### 测试要点
1. "当（while） 变量甲（x） > 0 「 变量甲 = 变量甲 - 1 」" 产生 条件循环表达式（EXPR_WHILE）（条件, 循环体）

## 函数 解析 遍历（for） 表达式（parse_for_expr）
### 作用
解析 `遍历（for） 变量（var） := 范围表达式（range_expr） 「 函数体（AST 节点）（body） 」` 迭代表达式。Core 仅支持 遍历...范围（range） 风格，不支持 C 风格三要素。若 `:=` 后非 `「` 则跳过词法单元直到遇到 `「` 或 文件结束标记（EOF），避免错误级联。
### 逻辑
`
函数 解析 遍历（for） 表达式（parse_for_expr）（） -> 整数
    令 起始位置（t） = 前进词法单元（advance_tok）（）
    令 变量词法单元索引（vt） = 前进词法单元（advance_tok）（）
    令 变量名称索引（vn） = 字符串驻留（str_intern（tok_lx（变量词法单元索引）））
    前进词法单元（advance_tok）（） -- 跳过 :=
    令 迭代表达式（iter） = 解析表达式（parse_expr（））
    令 循环体（body） = -1（可变）
-- Core 仅支持 遍历（for） 变量（var） := 范围表达式（range_expr） 「 函数体（AST 节点）（body） 」；非 「 则跳过后续词法单元防止级联错误
    如果 非 检查（入口）（T_LBRACE），那么：
        循环（当 真 时）：
            如果 检查（入口）（T_LBRACE） 或 检查（入口）（T_EOF），那么：跳出循环
            前进词法单元（advance_tok）（）
    如果 检查（入口）（T_LBRACE），那么：循环体 = 解析代码块（parse_block（））
    返回 分配 AST 节点（alloc_node）（遍历循环表达式（EXPR_FOR）, 变量名称索引, 迭代表达式, 循环体, 0, 0, 0, 词法单元行号（tok_ln（起始位置））, 词法单元列号（tok_cl（起始位置）））
`
### 测试要点
1. "遍历（for） 索引（i） := 0..10 「 」" 产生 遍历循环表达式（EXPR_FOR）（变量名称=索引, 迭代=范围表达式（EXPR_RANGE）（0,10）, 循环体=块）
2. 无块体时 循环体=-1

## 函数 解析 匹配（match） 表达式（parse_match_expr）
### 作用
解析 `匹配（match） 表达式（expr） 「 分支1（arm1） => 主体1（body1）, 分支2（arm2） => 主体2（body2）, ... 」` 模式匹配表达式。每个匹配臂由 解析模式（parse_pattern） 解析模式、`=>` 消费后 解析表达式（parse_expr） 解析体；各臂通过 变量丙（c） 字段链接为链表（ARM 节点的 第三子节点（变量丙） 指向下一臂）。返回 匹配表达式（EXPR_MATCH） 节点（变量甲（a）=被匹配表达式, 变量乙（b）=首臂, 变量丙=臂数）。
### 逻辑
`
函数 解析 匹配（match） 表达式（parse_match_expr）（） -> 整数
    令 起始位置（t） = 前进词法单元（advance_tok）（）
    -- 被匹配表达式中禁用结构体字面量
    解析器禁止结构体字面量标记（g_parse_no_struct_literal） = 1
    令 被匹配表达式（expr） = 解析表达式（parse_expr（））
    解析器禁止结构体字面量标记（g_parse_no_struct_literal） = 0
前进词法单元（advance_tok）（） -- 跳过 「
    令 首臂索引（af） = -1
    令 末尾臂索引（al） = -1（可变）
    令 臂计数（ac） = 0（可变）
    循环（当 真 时）：
        如果 检查（入口）（T_RBRACE） 或 检查（入口）（T_EOF），那么：跳出循环
        令 模式节点（pat） = 解析模式（parse_pattern（））
        前进词法单元（advance_tok）（） -- 跳过 =>
        令 臂体（body） = 解析表达式（parse_expr（））
        -- 可选尾随逗号
        如果 检查（入口）（T_COMMA），那么：前进词法单元（advance_tok）（）
        令 臂节点（n） = 分配 AST 节点（alloc_node）（EXPR_ARM, 模式节点, 臂体, -1, 0, 0, 0, 词法单元行号（tok_ln（起始位置））, 词法单元列号（tok_cl（起始位置）））
        如果 臂计数 等于 0，那么：首臂索引 = 臂节点
        -- 通过 变量丙（c） 字段将上一臂链接到当前臂（形成有序链表）
        如果 末尾臂索引 大于等于 0，那么：AST 访问器：设置变量丙（c）（ast_set_c）（末尾臂索引, 臂节点）
        末尾臂索引 = 臂节点
        臂计数 = 臂计数 + 1
前进词法单元（advance_tok）（） -- 跳过 」
    返回 分配 AST 节点（alloc_node）（匹配表达式（EXPR_MATCH）, 被匹配表达式, 首臂索引, 臂计数, 0, 0, 0, 词法单元行号（tok_ln（起始位置））, 词法单元列号（tok_cl（起始位置）））
`
### 测试要点
1. "匹配（match） 变量甲（x） 「 1 => 变量甲（a）, 下划线（_） => 变量乙（b） 」" 产生 匹配表达式（EXPR_MATCH）（被匹配表达式=变量甲, 臂计数=2）
2. 各臂通过 变量丙（c） 字段正确链接
3. 空 匹配（match） "匹配 变量甲（x） 「」" 产生 臂计数=0

## 函数 解析模式（parse_pattern）
### 作用
解析 匹配（match） 表达式中的模式。支持：
- `下划线（_）` → 通配符模式（EXPR_WILDCARD）
- 整数/浮点/字符串/字符/布尔字面量 → 对应字面量模式
- `枚举（Enum）.变体（Variant）（subpat, ...）` 或 `变体（subpat, ...）` → 枚举构造器模式（EXPR_ENUMPAT）
- `类型（Type） 「 字段（field） = 模式（pat）, ... 」` → 结构体模式（EXPR_STRUCTPAT）
- 大写标识符（无参数/无括号）→ 简写枚举模式（EXPR_ENUMPAT）
- 小写标识符 → 变量绑定模式（EXPR_IDENT）
### 逻辑
`
函数 解析模式（parse_pattern）（） -> 整数
    令 起始词法单元索引（t） = 当前词法单元（cur_tok（））
    -- 通配符模式：下划线（_）
    如果 词法单元类别（tok_k（起始词法单元索引）） 等于 下划线（T_UNDERSCORE），那么：
        前进词法单元（advance_tok）（）
        返回 分配 AST 节点（alloc_node）（通配模式（EXPR_WILDCARD）, 0, 0, 0, 0, 0, 0, 词法单元行号（tok_ln（起始词法单元索引））, 词法单元列号（tok_cl（起始词法单元索引）））
    -- 整数字面量模式（2026-09-10 R1 语言面收窄 §2：带位宽后缀区间分支已删除——lexer 不再发射这些类别）
    如果 词法单元类别（tok_k（起始词法单元索引）） 等于 整数字面量（T_INT），那么：
        前进词法单元（advance_tok）（）
        返回 分配 AST 节点（alloc_node）（整数字面量表达式（EXPR_INT）, 0, 0, 0, 词法单元整数值（tok_iv（起始词法单元索引））, 整数类型（TY_INT）, 0, 词法单元行号（tok_ln（起始词法单元索引））, 词法单元列号（tok_cl（起始词法单元索引）））
    -- 字符串字面量模式
    如果 词法单元类别（tok_k（起始词法单元索引）） 等于 字符串字面量（T_STRING），那么：
        前进词法单元（advance_tok）（）
        返回 分配 AST 节点（alloc_node）（字符串字面量表达式（EXPR_STRING）, 0, 0, 0, 字符串驻留（str_intern（tok_lx（起始词法单元索引）））, 字符串类型（TY_STRING）, 0, 词法单元行号（tok_ln（起始词法单元索引））, 词法单元列号（tok_cl（起始词法单元索引）））
    -- 字符字面量模式
    如果 词法单元类别（tok_k（起始词法单元索引）） 等于 字符字面量（T_CHAR），那么：
        前进词法单元（advance_tok）（）
        返回 分配 AST 节点（alloc_node）（字符字面量表达式（EXPR_CHAR）, 0, 0, 0, 字符串驻留（str_intern（tok_lx（起始词法单元索引）））, 字符类型（TY_CHAR）, 0, 词法单元行号（tok_ln（起始词法单元索引））, 词法单元列号（tok_cl（起始词法单元索引）））
    -- 布尔字面量模式
    如果 词法单元类别（tok_k（起始词法单元索引）） 等于 真关键字（T_TRUE），那么：
        前进词法单元（advance_tok）（）
        返回 分配 AST 节点（alloc_node）（布尔字面量表达式（EXPR_BOOL）, 0, 0, 0, 1, 布尔类型（TY_BOOL）, 0, 词法单元行号（tok_ln（起始词法单元索引））, 词法单元列号（tok_cl（起始词法单元索引）））
    如果 词法单元类别（tok_k（起始词法单元索引）） 等于 假关键字（T_FALSE），那么：
        前进词法单元（advance_tok）（）
        返回 分配 AST 节点（alloc_node）（布尔字面量表达式（EXPR_BOOL）, 0, 0, 0, 0, 布尔类型（TY_BOOL）, 0, 词法单元行号（tok_ln（起始词法单元索引））, 词法单元列号（tok_cl（起始词法单元索引）））
    -- 标识符、无值（None）、某些值（Some）：多义模式入口
    如果 词法单元类别（tok_k（起始词法单元索引）） 等于 标识符（T_IDENT） 或 词法单元类别（tok_k（起始词法单元索引）） 等于 无值关键字（T_NONE） 或 词法单元类别（tok_k（起始词法单元索引）） 等于 某些关键字（T_SOME），那么：
        前进词法单元（advance_tok）（）
        令 名称（name） = 词法单元词素索引（tok_lx（起始词法单元索引））
        令 名称索引（ni） = 字符串驻留（str_intern（名称））
        -- 处理 枚举（Enum）.变体（Variant） 模式
        如果 检查（入口）（T_DOT），那么：
            前进词法单元（advance_tok）（）
            令 变体词法单元索引（vt） = 前进词法单元（advance_tok）（）
            名称 = 名称 + "." + 词法单元词素索引（tok_lx（变体词法单元索引））
            名称索引 = 字符串驻留（str_intern（名称））
            如果 检查（入口）（T_LPAREN），那么：
                -- 枚举（Enum）.变体（Variant）（subpat, ...）：带子模式
                前进词法单元（advance_tok）（）
                令 首个子模式（sub_first） = -1（可变）
                令 子模式计数（ac） = 0（可变）
                如果 非 检查（入口）（T_RPAREN），那么：
                    首个子模式 = 解析模式（parse_pattern（））
                    子模式计数 = 1
                    循环（当 真 时）：
                        如果 非 检查（入口）（T_COMMA），那么：跳出循环
                        前进词法单元（advance_tok）（）； 解析模式（parse_pattern（））
                        子模式计数 = 子模式计数 + 1
                前进词法单元（advance_tok）（） -- 跳过 ）
                返回 分配 AST 节点（alloc_node）（枚举模式（EXPR_ENUMPAT）, 名称索引, 首个子模式, 子模式计数, 0, 0, 0, 词法单元行号（tok_ln（起始词法单元索引））, 词法单元列号（tok_cl（起始词法单元索引）））
            -- 枚举（Enum）.变体（Variant）：无子模式
            返回 分配 AST 节点（alloc_node）（枚举模式（EXPR_ENUMPAT）, 名称索引, 0, 0, 0, 0, 0, 词法单元行号（tok_ln（起始词法单元索引））, 词法单元列号（tok_cl（起始词法单元索引）））
        -- 处理 变体（Variant）（subpat, ...） 枚举构造器模式
        如果 检查（入口）（T_LPAREN），那么：
            前进词法单元（advance_tok）（）
            令 首个子模式（sub_first） = -1（可变）
            令 子模式计数（ac） = 0（可变）
            如果 非 检查（入口）（T_RPAREN），那么：
                首个子模式 = 解析模式（parse_pattern（））
                子模式计数 = 1
                循环（当 真 时）：
                    如果 非 检查（入口）（T_COMMA），那么：跳出循环
                    前进词法单元（advance_tok）（）； 解析模式（parse_pattern（））
                    子模式计数 = 子模式计数 + 1
            前进词法单元（advance_tok）（） -- 跳过 ）
            返回 分配 AST 节点（alloc_node）（枚举模式（EXPR_ENUMPAT）, 名称索引, 首个子模式, 子模式计数, 0, 0, 0, 词法单元行号（tok_ln（起始词法单元索引））, 词法单元列号（tok_cl（起始词法单元索引）））
-- 处理结构体模式：名称（Name） 「 字段（field） = 模式（pat）, ... 」
        如果 检查（入口）（T_LBRACE），那么：
            前进词法单元（advance_tok）（）
            令 首字段索引（ff） = -1
            令 字段计数（fc） = 0（可变）
            循环（当 真 时）：
                如果 检查（入口）（T_RBRACE），那么：跳出循环
                令 字段词法单元索引（ft） = 前进词法单元（advance_tok）（）
                令 字段名称索引（fni） = 字符串驻留（str_intern（tok_lx（字段词法单元索引）））
                前进词法单元（advance_tok）（） -- 跳过 =
                令 字段模式（fp） = 解析模式（parse_pattern（））
                -- 字段以独立节点存入 AST 数组（连续排列）
                AST 访问器：分配（ast_alloc）（0, 字段模式, 0, 0, 0, 0, 0, 词法单元行号（tok_ln（字段词法单元索引））, 词法单元列号（tok_cl（字段词法单元索引）））
                如果 字段计数 等于 0，那么：首字段索引 = AST 节点计数（g_ast_count） - 1
                字段计数 = 字段计数 + 1
                如果 检查（入口）（T_COMMA），那么：前进词法单元（advance_tok）（）
前进词法单元（advance_tok）（） -- 跳过 」
            返回 分配 AST 节点（alloc_node）（结构模式（EXPR_STRUCTPAT）, 名称索引, 首字段索引, 字段计数, 0, 0, 0, 词法单元行号（tok_ln（起始词法单元索引））, 词法单元列号（tok_cl（起始词法单元索引）））
        -- 大写标识符（无参数、无括号）→ 简写枚举构造器模式
        如果 判断首字母大写（is_upper_first（名称）），那么：
            返回 分配 AST 节点（alloc_node）（枚举模式（EXPR_ENUMPAT）, 名称索引, 0, 0, 0, 0, 0, 词法单元行号（tok_ln（起始词法单元索引））, 词法单元列号（tok_cl（起始词法单元索引）））
        -- 小写标识符 → 变量绑定模式
        返回 分配 AST 节点（alloc_node）（标识符表达式（EXPR_IDENT）, 0, 0, 0, 名称索引, 0, 0, 词法单元行号（tok_ln（起始词法单元索引））, 词法单元列号（tok_cl（起始词法单元索引）））
    -- 未识别模式：消费一单位防止死循环
    前进词法单元（advance_tok）（）
    返回 0
`
### 测试要点
1. "下划线（_）" 产生 通配模式（EXPR_WILDCARD）
2. "某些值（Some）（x）" 产生 枚举模式（EXPR_ENUMPAT）（"某些值", 子模式计数=1）
3. "Point 「变量甲（x） = 变量甲（a）, y = 变量乙（b）」" 产生 结构模式（EXPR_STRUCTPAT）（"Point", 字段计数=2）
4. 大写 "无值（None）" 产生 枚举模式（EXPR_ENUMPAT）（"无值"）
5. 小写 "变量甲（x）" 产生 标识符表达式（EXPR_IDENT）（变量绑定）
