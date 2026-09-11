# AST 数组（ast）.cr 伪代码
> 源文件：src/compiler/AST 数组（ast）.cr（629 行）
> 功能概要：编译器共享常量定义与数据结构声明。包含词法单元类别常量、类型常量、AST（语法树）节点类别常量与结构体、IR（中间表示）操作码、HDFG结构体、错误码定义，以及跨模块共享的全局数组变量。

## 标识符对照表

| 中文名 | 原名 | 首次出现函数 |
|--------|------|-------------|
| 文件结束（EOF） | T_EOF | （全局常量节） |
| 标识符 | T_IDENT | （全局常量节） |
| 整数字面量 | T_INT | （全局常量节） |
| 浮点数字面量 | T_FLOAT | （全局常量节） |
| 字符串字面量 | T_STRING | （全局常量节） |
| 函数关键字 | T_FN | （全局常量节） |
| 可变关键字 | T_MUT | （全局常量节） |
| 如果关键字 | T_IF | （全局常量节） |
| 否则关键字 | T_ELSE | （全局常量节） |
| 循环关键字 | T_LOOP | （全局常量节） |
| 遍历关键字 | T_FOR | （全局常量节） |
| 属于关键字 | T_IN | （全局常量节） |
| 返回关键字 | T_RETURN | （全局常量节） |
| 跳出循环关键字 | T_BREAK | （全局常量节） |
| 继续关键字 | T_CONTINUE | （全局常量节） |
| 结构体关键字 | T_STRUCT | （全局常量节） |
| 枚举关键字 | T_ENUM | （全局常量节） |
| 实现关键字 | T_IMPL | （全局常量节） |
| 公开关键字 | T_PUB | （全局常量节） |
| 真值字面量 | T_TRUE | （全局常量节） |
| 假值字面量 | T_FALSE | （全局常量节） |
| 移动关键字 | T_MOVE | （全局常量节） |
| 自身关键字 | T_SELF | （全局常量节） |
| 左圆括号 | T_LPAREN | （全局常量节） |
| 右圆括号 | T_RPAREN | （全局常量节） |
| 左花括号 | T_LBRACE | （全局常量节） |
| 右花括号 | T_RBRACE | （全局常量节） |
| 逗号 | T_COMMA | （全局常量节） |
| 分号 | T_SEMI | （全局常量节） |
| 冒号 | T_COLON | （全局常量节） |
| 点号 | T_DOT | （全局常量节） |
| 箭头 | T_ARROW | （全局常量节） |
| 赋值等号 | T_EQ | （全局常量节） |
| 相等比较 | T_EQEQ | （全局常量节） |
| 感叹号 | T_BANG | （全局常量节） |
| 不等比较 | T_BANGEQ | （全局常量节） |
| 小于号 | T_LT | （全局常量节） |
| 大于号 | T_GT | （全局常量节） |
| 小于等于号 | T_LTEQ | （全局常量节） |
| 大于等于号 | T_GTEQ | （全局常量节） |
| 加号 | T_PLUS | （全局常量节） |
| 减号 | T_MINUS | （全局常量节） |
| 星号 | T_STAR | （全局常量节） |
| 斜杠 | T_SLASH | （全局常量节） |
| 逻辑与 | T_ANDAND | （全局常量节） |
| 逻辑或 | T_PIPEPIPE | （全局常量节） |
| 按位与 | T_AMPERSAND | （全局常量节） |
| 下划线 | T_UNDERSCORE | （全局常量节） |
| 单元类型 | T_UNIT | （全局常量节） |
| 路径分隔符 | T_PATHSEP | （全局常量节） |
| 左方括号 | T_LBRACKET | （全局常量节） |
| 右方括号 | T_RBRACKET | （全局常量节） |
| 匹配关键字 | T_MATCH | （全局常量节） |
| 粗箭头 | T_FATARROW | （全局常量节） |
| 百分号 | T_PERCENT | （全局常量节） |
| 字符字面量 | T_CHAR | （全局常量节） |
| 当循环关键字 | T_WHILE | （全局常量节） |
| 双点号 | T_DOTDOT | （全局常量节） |
| 三点号 | T_DOTDOTDOT | （全局常量节） |
| 类型关键字 | T_TYPE | （全局常量节） |
| 模块关键字 | T_MOD | （全局常量节） |
| 引入关键字 | T_IMPORT | （全局常量节） |
| 别名关键字 | T_AS | （全局常量节） |
| 协程关键字 | T_GO | （全局常量节） |
| 等待关键字 | T_AWAIT | （全局常量节） |
| 数据流关键字 | T_FLOW | （全局常量节） |
| 让出关键字 | T_YIELD | （全局常量节） |
| 不安全关键字 | T_UNSAFE | （全局常量节） |
| 接口关键字 | T_INTERFACE | （全局常量节） |
| 声明等号 | T_COLON_EQ | （全局常量节） |
| 自动关键字 | T_AUTO | （全局常量节） |
| at 符号 | T_AT | （全局常量节） |
| 文件标识 | T_FILEID | （全局常量节） |
| 问号 | T_QUESTION | （全局常量节） |
| 加等号 | T_PLUS_EQ | （全局常量节） |
| 减等号 | T_MINUS_EQ | （全局常量节） |
| 星等号 | T_STAR_EQ | （全局常量节） |
| 斜杠等号 | T_SLASH_EQ | （全局常量节） |
| 后缀整数 i8 | T_INT_I8 | （全局常量节） |
| 后缀整数 i16 | T_INT_I16 | （全局常量节） |
| 后缀整数 i32 | T_INT_I32 | （全局常量节） |
| 后缀整数 i64 | T_INT_I64 | （全局常量节） |
| 后缀整数 u8 | T_INT_U8 | （全局常量节） |
| 后缀整数 u16 | T_INT_U16 | （全局常量节） |
| 后缀整数 u32 | T_INT_U32 | （全局常量节） |
| 后缀整数 u64 | T_INT_U64 | （全局常量节） |
| 后缀浮点数 f32 | T_FLOAT_F32 | （全局常量节） |
| 后缀浮点数 f64 | T_FLOAT_F64 | （全局常量节） |
| 无值（None）关键字 | T_NONE | （全局常量节） |
| 有值（Some）关键字 | T_SOME | （全局常量节） |
| 旧声明关键字 | T_LET | （全局常量节） |
| 整数类型关键字 | T_INT_TYPE | （全局常量节） |
| 浮点数类型关键字 | T_FLOAT_TYPE | （全局常量节） |
| 布尔类型关键字 | T_BOOL_TYPE | （全局常量节） |
| 单元类型关键字 | T_UNIT_TYPE | （全局常量节） |
| 字符串类型关键字 | T_STR_TYPE | （全局常量节） |
| 自动类型关键字 | T_AUTO_TYPE | （全局常量节） |
| 引用关键字 | T_REF | （全局常量节） |
| 动态关键字 | T_DYN | （全局常量节） |
| 外部关键字 | T_EXTERN | （全局常量节） |
| 宽度 I8 | W_I8 | （全局常量节） |
| 宽度 I16 | W_I16 | （全局常量节） |
| 宽度 I32 | W_I32 | （全局常量节） |
| 宽度 I64 | W_I64 | （全局常量节） |
| 宽度 U8 | W_U8 | （全局常量节） |
| 宽度 U16 | W_U16 | （全局常量节） |
| 宽度 U32 | W_U32 | （全局常量节） |
| 宽度 U64 | W_U64 | （全局常量节） |
| 宽度 F32 | W_F32 | （全局常量节） |
| 宽度 F64 | W_F64 | （全局常量节） |
| 整数类型 | TY_INT | （全局常量节） |
| 浮点数类型 | TY_FLOAT | （全局常量节） |
| 布尔类型 | TY_BOOL | （全局常量节） |
| 字符串类型 | TY_STRING | （全局常量节） |
| 单元类型 | TY_UNIT | （全局常量节） |
| 永无类型 | TY_NEVER | （全局常量节） |
| 字符类型 | TY_CHAR | （全局常量节） |
| 泛型参数哨兵 | TY_GENERIC_PARAM | （全局常量节） |
| 最大泛型参数数 | MAX_GENERICS | （全局常量节） |
| 最大结构体字段数 | MAX_STRUCT_FIELDS | （全局常量节） |
| 最大枚举变体数 | MAX_ENUM_VARIANTS | （全局常量节） |
| 最大变体载荷类型数 | MAX_VARIANT_TYPES | （全局常量节） |
| 词法单元结构 | Token | （全局常量节） |
| 函数信息 | FuncInfo | （全局常量节） |
| 结构体信息 | StructInfo | （全局常量节） |
| 枚举变体信息 | EnumVariant | （全局常量节） |
| 枚举信息 | EnumInfo | （全局常量节） |
| 循环信息 | LoopInfo | （全局常量节） |
| 语法树节点 | ASTNode | （全局常量节） |
| 空表达式 | EXPR_NONE | （全局常量节） |
| 整数字面量表达式 | EXPR_INT | （全局常量节） |
| 浮点数字面量表达式 | EXPR_FLOAT | （全局常量节） |
| 字符串字面量表达式 | EXPR_STRING | （全局常量节） |
| 布尔字面量表达式 | EXPR_BOOL | （全局常量节） |
| 标识符表达式 | EXPR_IDENT | （全局常量节） |
| 二元运算表达式 | EXPR_BINARY | （全局常量节） |
| 一元运算表达式 | EXPR_UNARY | （全局常量节） |
| 调用表达式 | EXPR_CALL | （全局常量节） |
| 代码块表达式 | EXPR_BLOCK | （全局常量节） |
| 如果表达式 | EXPR_IF | （全局常量节） |
| 循环表达式 | EXPR_LOOP | （全局常量节） |
| 声明表达式 | EXPR_LET | （全局常量节） |
| 返回表达式 | EXPR_RETURN | （全局常量节） |
| 字段访问表达式 | EXPR_FIELD | （全局常量节） |
| 索引访问表达式 | EXPR_INDEX | （全局常量节） |
| 赋值表达式 | EXPR_ASSIGN | （全局常量节） |
| 结构体字面量表达式 | EXPR_STRUCT | （全局常量节） |
| 函数定义表达式 | EXPR_FN | （全局常量节） |
| 参数表达式 | EXPR_PARAM | （全局常量节） |
| 数组字面量表达式 | EXPR_ARRAY | （全局常量节） |
| 跳出循环表达式 | EXPR_BREAK | （全局常量节） |
| 继续表达式 | EXPR_CONTINUE | （全局常量节） |
| 遍历表达式 | EXPR_FOR | （全局常量节） |
| 匹配表达式 | EXPR_MATCH | （全局常量节） |
| 分支表达式 | EXPR_ARM | （全局常量节） |
| 通配表达式 | EXPR_WILDCARD | （全局常量节） |
| 枚举模式表达式 | EXPR_ENUMPAT | （全局常量节） |
| 语句表达式 | EXPR_STMT | （全局常量节） |
| 字符字面量表达式 | EXPR_CHAR | （全局常量节） |
| 当循环表达式 | EXPR_WHILE | （全局常量节） |
| 范围表达式 | EXPR_RANGE | （全局常量节） |
| 移动表达式 | EXPR_MOVE | （全局常量节） |
| 枚举构造器表达式 | EXPR_ENUM_CONSTRUCTOR | （全局常量节） |
| 引用类型表达式 | EXPR_REFTYPE | （全局常量节） |
| 泛型应用表达式 | EXPR_GENERIC_APPLY | （全局常量节） |
| 元组字面量表达式 | EXPR_TUPLE | （全局常量节） |
| 参数链接表达式 | EXPR_ARG | （全局常量节） |
| 协程表达式 | EXPR_GO | （全局常量节） |
| 数据流函数表达式 | EXPR_FLOW | （全局常量节） |
| 让出表达式 | EXPR_YIELD | （全局常量节） |
| 等待表达式 | EXPR_AWAIT | （全局常量节） |
| 内建注解表达式 | EXPR_AT | （全局常量节） |
| 尝试表达式 | EXPR_TRY | （全局常量节） |
| 不安全块表达式 | EXPR_UNSAFE | （全局常量节） |
| 结构体模式表达式 | EXPR_STRUCTPAT | （全局常量节） |
| 类型转换表达式 | EXPR_AS | （全局常量节） |
| 指针类型表达式 | EXPR_PTRTYPE | （全局常量节） |
| 外部函数表达式 | EXPR_EXTERN | （全局常量节） |
| 字段对 | FieldPair | （全局常量节） |
| 加法运算指令（OP_ADD） | OP_ADD | （全局常量节） |
| 减法运算指令（OP_SUB） | OP_SUB | （全局常量节） |
| 乘法运算指令（OP_MUL） | OP_MUL | （全局常量节） |
| 除法运算指令（OP_DIV） | OP_DIV | （全局常量节） |
| 取模运算指令（OP_MOD） | OP_MOD | （全局常量节） |
| 等于比较指令（OP_EQ） | OP_EQ | （全局常量节） |
| 不等于比较指令（OP_NE） | OP_NE | （全局常量节） |
| 小于比较指令（OP_LT） | OP_LT | （全局常量节） |
| 大于比较指令（OP_GT） | OP_GT | （全局常量节） |
| 小于等于比较指令（OP_LE） | OP_LE | （全局常量节） |
| 大于等于比较指令（OP_GE） | OP_GE | （全局常量节） |
| 逻辑与指令（OP_AND） | OP_AND | （全局常量节） |
| 逻辑或指令（OP_OR） | OP_OR | （全局常量节） |
| 赋值指令（OP_ASSIGN） | OP_ASSIGN | （全局常量节） |
| 左移指令（OP_SHL） | OP_SHL | （全局常量节） |
| 右移指令（OP_SHR） | OP_SHR | （全局常量节） |
| 指针加法指令（OP_PTR_ADD） | OP_PTR_ADD | （全局常量节） |
| 指针减法指令（OP_PTR_SUB） | OP_PTR_SUB | （全局常量节） |
| 指针差值指令（OP_PTR_DIFF） | OP_PTR_DIFF | （全局常量节） |
| 一元取负（UOP_NEG） | UOP_NEG | （全局常量节） |
| 一元逻辑非（UOP_NOT） | UOP_NOT | （全局常量节） |
| 一元取引用（UOP_REF） | UOP_REF | （全局常量节） |
| 一元解引用（UOP_DEREF） | UOP_DEREF | （全局常量节） |
| 类型表预分配：整数（TI_INT） | TI_INT | （全局常量节） |
| 类型表预分配：浮点数（TI_FLOAT） | TI_FLOAT | （全局常量节） |
| 类型表预分配：布尔（TI_BOOL） | TI_BOOL | （全局常量节） |
| 类型表预分配：字符串（TI_STR） | TI_STR | （全局常量节） |
| 类型表预分配：单元（TI_UNIT） | TI_UNIT | （全局常量节） |
| 类型表预分配：永无（TI_NEVER） | TI_NEVER | （全局常量节） |
| 类型表预分配：字符（TI_CHAR） | TI_CHAR | （全局常量节） |
| 类型表预分配：动态（TI_DYN） | TI_DYN | （全局常量节） |
| 类型条目类别：基础（TYP_BASE） | TYP_BASE | （全局常量节） |
| 类型条目类别：命名（TYP_NAMED） | TYP_NAMED | （全局常量节） |
| 类型条目类别：数组（TYP_ARRAY） | TYP_ARRAY | （全局常量节） |
| 类型条目类别：引用（TYP_REF） | TYP_REF | （全局常量节） |
| 类型条目类别：指针（TYP_PTR） | TYP_PTR | （全局常量节） |
| 类型条目类别：泛型参数（TYP_GENERIC_PARAM） | TYP_GENERIC_PARAM | （全局常量节） |
| 类型条目类别：泛型应用（TYP_GENERIC_APPLY） | TYP_GENERIC_APPLY | （全局常量节） |
| 类型条目类别：切片（TYP_SLICE） | TYP_SLICE | （全局常量节） |
| 类型条目类别：元组（TYP_TUPLE） | TYP_TUPLE | （全局常量节） |
| 类型条目类别：动态（TYP_DYN） | TYP_DYN | （全局常量节） |
| 语法解析错误 P001～P019 | EC_P_* | （全局常量节） |
| 名称解析错误 N001～N021 | EC_N_* | （全局常量节） |
| 类型推断错误 I001～I006 | EC_I_* | （全局常量节） |
| 类型赋值错误 TA01～TA07 | EC_TA_* | （全局常量节） |
| 类型函数错误 TF01～TF17 | EC_TF_* | （全局常量节） |
| 类型二元运算错误 TB01～TB09 | EC_TB_* | （全局常量节） |
| 类型一元运算错误 TU01～TU03 | EC_TU_* | （全局常量节） |
| 类型控制流错误 TC01～TC07 | EC_TC_* | （全局常量节） |
| 类型匹配错误 TM01～TM09 | EC_TM_* | （全局常量节） |
| 类型数组切片错误 TK01～TK08 | EC_TK_* | （全局常量节） |
| 类型结构体错误 TS01～TS04 | EC_TS_* | （全局常量节） |
| 类型泛型错误 TG01～TG02 | EC_TG_* | （全局常量节） |
| 借用错误 B001～B022 | EC_B_* | （全局常量节） |
| 运行时错误 R001～R004 | EC_R_* | （全局常量节） |
| 输入输出错误 E001～E004 | EC_E_* | （全局常量节） |
| 内部编译器错误 ICE01～ICE03 | EC_ICE_* | （全局常量节） |
| 诊断信息 | Diag | （全局常量节） |
| 符号类别：函数（SYM_FN） | SYM_FN | （全局常量节） |
| 符号类别：类型（SYM_TYPE） | SYM_TYPE | （全局常量节） |
| 符号类别：局部变量（SYM_LOCAL） | SYM_LOCAL | （全局常量节） |
| 符号类别：参数（SYM_PARAM） | SYM_PARAM | （全局常量节） |
| 符号类别：全局变量（SYM_GLOBAL） | SYM_GLOBAL | （全局常量节） |
| 符号类别：模块（SYM_MODULE） | SYM_MODULE | （全局常量节） |
| 符号类别：动态库函数（SYM_SO_FN） | SYM_SO_FN | （全局常量节） |
| 标记：可变参数（TAG_VARIADIC） | TAG_VARIADIC | （全局常量节） |
| 标记：自动字符串（TAG_AUTO_STR） | TAG_AUTO_STR | （全局常量节） |
| 泛型应用数据数组 | g_gen_apply_data | （全局变量声明节） |
| 泛型应用数据计数 | g_gen_apply_data_count | （全局变量声明节） |
| 泛型应用数据容量 | g_gen_apply_data_cap | （全局变量声明节） |
| 段起始索引数组 | g_seg_starts | （全局变量声明节） |
| 段文件 ID 数组 | g_seg_fileids | （全局变量声明节） |
| 段计数 | g_seg_count | （全局变量声明节） |
| 段容量 | g_seg_cap | （全局变量声明节） |
| 行文件 ID 数组 | g_line_fileid | （全局变量声明节） |
| 行计数 | g_line_count | （全局变量声明节） |
| 行数组容量 | g_line_cap | （全局变量声明节） |
| 源码目录 | g_source_dir | （全局变量声明节） |
| 空操作指令（IR_NOP） | IR_NOP | （全局常量节） |
| 常量指令（IR_CONST） | IR_CONST | （全局常量节） |
| 二元运算指令（IR_BINARY） | IR_BINARY | （全局常量节） |
| 一元运算指令（IR_UNARY） | IR_UNARY | （全局常量节） |
| 调用指令（IR_CALL） | IR_CALL | （全局常量节） |
| 返回指令（IR_RETURN） | IR_RETURN | （全局常量节） |
| 分配指令（IR_ALLOC） | IR_ALLOC | （全局常量节） |
| 分配结构体指令（IR_ALLOC_STRUCT） | IR_ALLOC_STRUCT | （全局常量节） |
| 分配数组指令（IR_ALLOC_ARRAY） | IR_ALLOC_ARRAY | （全局常量节） |
| 存储指令（IR_STORE） | IR_STORE | （全局常量节） |
| 加载指令（IR_LOAD） | IR_LOAD | （全局常量节） |
| 加载字段指令（IR_LOAD_FIELD） | IR_LOAD_FIELD | （全局常量节） |
| 存储字段指令（IR_STORE_FIELD） | IR_STORE_FIELD | （全局常量节） |
| 加载索引指令（IR_LOAD_INDEX） | IR_LOAD_INDEX | （全局常量节） |
| 存储索引指令（IR_STORE_INDEX） | IR_STORE_INDEX | （全局常量节） |
| 加载可变索引指令（IR_LOAD_INDEX_VAR） | IR_LOAD_INDEX_VAR | （全局常量节） |
| 存储可变索引指令（IR_STORE_INDEX_VAR） | IR_STORE_INDEX_VAR | （全局常量节） |
| 构造枚举指令（IR_MAKE_ENUM） | IR_MAKE_ENUM | （全局常量节） |
| 引用指令（IR_REF） | IR_REF | （全局常量节） |
| 条件分支指令（IR_BRANCH） | IR_BRANCH | （全局常量节） |
| 跳转指令（IR_JUMP） | IR_JUMP | （全局常量节） |
| 标签指令（IR_LABEL） | IR_LABEL | （全局常量节） |
| Phi 指令（IR_PHI） | IR_PHI | （全局常量节） |
| 加载枚举标签指令（IR_LOAD_ENUM_TAG） | IR_LOAD_ENUM_TAG | （全局常量节） |
| 切片指令（IR_SLICE） | IR_SLICE | （全局常量节） |
| 解引用指令（IR_DEREF） | IR_DEREF | （全局常量节） |
| 指针存储指令（IR_STORE_PTR） | IR_STORE_PTR | （全局常量节） |
| 地址索引指令（IR_ADDR_INDEX） | IR_ADDR_INDEX | （全局常量节） |
| 协程派生指令（IR_SPAWN） | IR_SPAWN | （全局常量节） |
| 让出指令（IR_YIELD） | IR_YIELD | （全局常量节） |
| 等待指令（IR_AWAIT） | IR_AWAIT | （全局常量节） |
| 边界检查指令（IR_BOUNDS_CHECK） | IR_BOUNDS_CHECK | （全局常量节） |
| 竞技场新建指令（IR_ARENA_NEW） | IR_ARENA_NEW | （全局常量节） |
| 竞技场重置指令（IR_ARENA_RESET） | IR_ARENA_RESET | （全局常量节） |
| 内联提示指令（IR_INLINE） | IR_INLINE | （全局常量节） |
| 无边界检查指令（IR_NO_BOUNDS_CHECK） | IR_NO_BOUNDS_CHECK | （全局常量节） |
| 快速指令（IR_FAST） | IR_FAST | （全局常量节） |
| 循环展开指令（IR_UNROLL） | IR_UNROLL | （全局常量节） |
| 代码段指令（IR_SECTION） | IR_SECTION | （全局常量节） |
| 热补丁路由指令（IR_HOTPATCH_ROUTE） | IR_HOTPATCH_ROUTE | （全局常量节） |
| 动态标签指令（IR_DYN_TAG） | IR_DYN_TAG | （全局常量节） |
| 动态取值指令（IR_DYN_VAL） | IR_DYN_VAL | （全局常量节） |
| 动态封包指令（IR_DYN_PACK） | IR_DYN_PACK | （全局常量节） |
| 动态分发指令（IR_DYN_DISPATCH） | IR_DYN_DISPATCH | （全局常量节） |
| 外部调用指令（IR_CALL_EXTERN） | IR_CALL_EXTERN | （全局常量节） |
| 惰性求值封装指令（IR_LAZY_THUNK） | IR_LAZY_THUNK | （全局常量节） |
| 惰性求值强制执行指令（IR_LAZY_FORCE） | IR_LAZY_FORCE | （全局常量节） |
| 函数地址指令（IR_FNADDR） | IR_FNADDR | （全局常量节） |
| 已解析标记（IR_RESOLVED） | IR_RESOLVED | （全局常量节） |
| IR 变量 | IRVar | （全局常量节） |
| IR 指令 | IRInstr | （全局常量节） |
| 数据流节点 | DFNode | （全局常量节） |
| 数据流边 | DFEdge | （全局常量节） |
| 变量使用计数数组 | g_var_use_count | （全局变量声明节） |
| 变量使用计数容量 | g_var_use_count_cap | （全局变量声明节） |
| 优化元数据键：寄存器分配（OPT_KEY_REG_ASSIGN） | OPT_KEY_REG_ASSIGN | （全局常量节） |
| 优化元数据步长（OPT_META_STRIDE） | OPT_META_STRIDE | （全局常量节） |
| 优化元数据键：栈共享（OPT_KEY_STACK_SHARE） | OPT_KEY_STACK_SHARE | （全局常量节） |
| 优化元数据键：公共子表达式消除（OPT_KEY_CSE） | OPT_KEY_CSE | （全局常量节） |

## 全局状态

| 全局变量 | 含义 | 初始值 |
|---------|------|--------|
| 泛型应用数据数组（g_gen_apply_data） | 存储泛型应用的实际类型参数列表 | 空字节缓冲 |
| 泛型应用数据计数（g_gen_apply_data_count） | 当前已用条目数 | 0 |
| 泛型应用数据容量（g_gen_apply_data_cap） | 字节缓冲容量 | 0 |
| 段起始索引数组（g_seg_starts） | 各段在词法单元数组中的起始索引 | 空 |
| 段文件 ID 数组（g_seg_fileids） | 各段对应的源文件 ID | 空 |
| 段计数（g_seg_count） | 已注册的段数目 | 0 |
| 段容量（g_seg_cap） | 段数组的当前容量 | 0 |
| 行文件 ID 数组（g_line_fileid） | 每行所属源文件的 ID | 空 |
| 行计数（g_line_count） | 已注册的行数 | 0 |
| 行数组容量（g_line_cap） | 行数组的当前容量 | 0 |
| 源码目录（g_source_dir） | 主源文件所在目录（用于查找 _import.cr） | 空 |
| 数据流节点数组（g_df_nodes） | HDFG节点 | 空 |
| 数据流节点计数（g_df_node_count） | HDFG节点数 | 0 |
| 数据流节点容量（g_df_node_cap） | 数据流节点数组容量 | 0 |
| 数据流边数组（g_df_edges） | HDFG边 | 空 |
| 数据流边计数（g_df_edge_count） | HDFG边数 | 0 |
| 数据流边容量（g_df_edge_cap） | 数据流边数组容量 | 0 |
| 变量生产者节点映射（g_df_var_producer） | IR 变量到生产者数据流节点的映射 | 空 |
| HDFG各函数节点起始索引（g_df_func_node_start） | 各函数在数据流节点数组中的起始索引 | 空 |
| HDFG各函数节点计数（g_df_func_node_count） | 各函数的数据流节点数 | 空 |
| HDFG数组容量（g_df_cap） | HDFG数组总容量 | 0 |
| 变量使用计数数组（g_var_use_count） | 每个 IR 变量被多少消费者使用 | 空 |
| 变量使用计数容量（g_var_use_count_cap） | 变量使用计数数组容量 | 0 |

## 词法单元类别常量（Token 种类（kind） constants）

> 所有常量均为整数（int）全局值。词法单元类别（kind）由词法分析器（lexer : tokenize）产生并存入 词法单元数组（g_tokens） 数组。

### 基本词法单元类别（数值 0～76）

| 常量 | 数值 | 含义 |
|------|------|------|
| 文件结束（T_EOF） | 0 | 源码结束标记 |
| 标识符（T_IDENT） | 1 | 用户定义的名称 |
| 整数（T_INT） | 2 | 整数字面量 |
| 浮点数（T_FLOAT） | 3 | 浮点数字面量 |
| 字符串（T_STRING） | 4 | 字符串字面量 |
| 函数（T_FN） | 5 | 保留字 `函数`（fn） |
| 可变（T_MUT） | 7 | 可变（mut）修饰符 |
| 如果（T_IF） | 8 | 如果（if）关键字 |
| 否则（T_ELSE） | 9 | 否则（else）关键字 |
| 循环（T_LOOP） | 10 | 无限循环（loop）关键字 |
| 遍历（T_FOR） | 11 | 遍历（for）循环关键字 |
| 属于（T_IN） | 12 | 属于（in）关键字 |
| 返回（T_RETURN） | 13 | 返回（return）关键字 |
| 跳出循环（T_BREAK） | 14 | 跳出循环（break）关键字 |
| 继续（T_CONTINUE） | 15 | 继续下一次循环（continue）关键字 |
| 结构体（T_STRUCT） | 16 | 结构体（struct）关键字 |
| 枚举（T_ENUM） | 17 | 枚举（enum）关键字 |
| 实现（T_IMPL） | 18 | 实现（impl）关键字 |
| 公开（T_PUB） | 19 | 公开（pub）修饰符 |
| 真（T_TRUE） | 20 | 真（true）字面量 |
| 假（T_FALSE） | 21 | 假（false）字面量 |
| 移动（T_MOVE） | 22 | 移动（move）关键字 |
| 自身（T_SELF） | 23 | 自身（self）关键字 |
| 左圆括号（T_LPAREN） | 24 | `（` |
| 右圆括号（T_RPAREN） | 25 | `）` |
| 左花括号（T_LBRACE） | 26 | `{` |
| 右花括号（T_RBRACE） | 27 | `}` |
| 逗号（T_COMMA） | 28 | `,` |
| 分号（T_SEMI） | 29 | `;` |
| 冒号（T_COLON） | 30 | `:` |
| 点号（T_DOT） | 31 | `.` |
| 箭头（T_ARROW） | 32 | `->` |
| 等号赋值（T_EQ） | 33 | `=` |
| 等号比较（T_EQEQ） | 34 | `==` |
| 感叹号（T_BANG） | 35 | `!` |
| 不等比较（T_BANGEQ） | 36 | `!=` |
| 小于号（T_LT） | 37 | `<` |
| 大于号（T_GT） | 38 | `>` |
| 小于等于号（T_LTEQ） | 39 | `<=` |
| 大于等于号（T_GTEQ） | 40 | `>=` |
| 加号（T_PLUS） | 41 | `+` |
| 减号（T_MINUS） | 42 | `-` |
| 星号（T_STAR） | 43 | `*` |
| 斜杠（T_SLASH） | 44 | `/` |
| 逻辑与（T_ANDAND） | 45 | `&&` |
| 逻辑或（T_PIPEPIPE） | 46 | `\|\|` |
| 按位与（T_AMPERSAND） | 47 | `&` |
| 下划线（T_UNDERSCORE） | 48 | `_` |
| 单元类型（T_UNIT） | 49 | 单元（unit）类型关键字 |
| 路径分隔符（T_PATHSEP） | 50 | `::` |
| 左方括号（T_LBRACKET） | 51 | `[` |
| 右方括号（T_RBRACKET） | 52 | `]` |
| 匹配（T_MATCH） | 53 | 匹配（match）关键字 |
| 粗箭头（T_FATARROW） | 54 | `=>` |
| 百分号（T_PERCENT） | 55 | `%` |
| 字符（T_CHAR） | 56 | 字符字面量 |
| 当循环（T_WHILE） | 57 | 当循环（while）关键字 |
| 双点号（T_DOTDOT） | 58 | `..` |
| 三点号（T_DOTDOTDOT） | 59 | `...` |
| 类型（T_TYPE） | 60 | 类型（type）关键字 |
| 模块（T_MOD） | 61 | 模块（mod）关键字 |
| 引入（T_IMPORT） | 62 | 引入（import）关键字 |
| 别名（T_AS） | 63 | 别名（as）关键字 |
| 协程（T_GO） | 64 | 协程（go）关键字 |
| 等待（T_AWAIT） | 65 | 等待（await）关键字 |
| 数据流（T_FLOW） | 66 | 数据流（flow）关键字 |
| 让出（T_YIELD） | 67 | 让出（yield）关键字 |
| 不安全（T_UNSAFE） | 68 | 不安全（unsafe）关键字 |
| 自动（T_AUTO） | 69 | 自动（auto）类型关键字 |
| at（T_AT） | 70 | `@` 内建注解 |
| 文件标识（T_FILEID） | 71 | 文件标识（fileid）关键字 |
| 问号（T_QUESTION） | 72 | `?` |
| 加等号（T_PLUS_EQ） | 73 | `+=` |
| 减等号（T_MINUS_EQ） | 74 | `-=` |
| 星等号（T_STAR_EQ） | 75 | `*=` |
| 斜杠等号（T_SLASH_EQ） | 76 | `/=` |

### 后缀整数/浮点数词法单元（数值 77～86）

> 词法分析器遇到 `_i32`、`_u64`、`_f32` 等后缀时产生这些类别。

| 常量 | 数值 | 含义 |
|------|------|------|
| 后缀整数 i8（T_INT_I8） | 77 | i8 后缀整数 |
| 后缀整数 i16（T_INT_I16） | 78 | i16 后缀整数 |
| 后缀整数 i32（T_INT_I32） | 79 | i32 后缀整数 |
| 后缀整数 i64（T_INT_I64） | 80 | i64 后缀整数 |
| 后缀整数 u8（T_INT_U8） | 81 | u8 后缀整数 |
| 后缀整数 u16（T_INT_U16） | 82 | u16 后缀整数 |
| 后缀整数 u32（T_INT_U32） | 83 | u32 后缀整数 |
| 后缀整数 u64（T_INT_U64） | 84 | u64 后缀整数 |
| 后缀浮点数 f32（T_FLOAT_F32） | 85 | f32 后缀浮点数 |
| 后缀浮点数 f64（T_FLOAT_F64） | 86 | f64 后缀浮点数 |

### 扩展词法单元类别（数值 87～100）

| 常量 | 数值 | 含义 |
|------|------|------|
| 无值（T_NONE） | 87 | 无值（None）关键字 |
| 有值（T_SOME） | 88 | 有值（Some）关键字 |
| 旧声明（T_LET） | 89 | 旧式声明（let）关键字 |
| 整数类型（T_INT_TYPE） | 90 | 整数（int）类型关键字 |
| 浮点数类型（T_FLOAT_TYPE） | 91 | 浮点数（float）类型关键字 |
| 布尔类型（T_BOOL_TYPE） | 92 | 布尔（bool）类型关键字 |
| 单元类型（T_UNIT_TYPE） | 93 | 单元（unit）类型关键字 |
| 字符串类型（T_STR_TYPE） | 94 | 字符串（str）类型关键字 |
| 自动类型（T_AUTO_TYPE） | 95 | 自动（auto）类型关键字 |
| 引用（T_REF） | 96 | 引用（ref）关键字 |
| 接口（T_INTERFACE） | 97 | 接口（interface）关键字 |
| 声明等号（T_COLON_EQ） | 98 | `:=` 声明操作符 |
| 动态（T_DYN） | 99 | 动态（dyn）类型关键字 |
| 外部（T_EXTERN） | 100 | 外部（extern）声明关键字 |

## 宽度常量（Width constants）

> 存入整数字面量/浮点数字面量节点的 数据（data） 字段，表示具体数值宽度。

| 常量 | 数值 | 含义 |
|------|------|------|
| 宽度 I8（W_I8） | 1 | 有符号 8 位整数 |
| 宽度 I16（W_I16） | 2 | 有符号 16 位整数 |
| 宽度 I32（W_I32） | 3 | 有符号 32 位整数 |
| 宽度 I64（W_I64） | 4 | 有符号 64 位整数 |
| 宽度 U8（W_U8） | 5 | 无符号 8 位整数 |
| 宽度 U16（W_U16） | 6 | 无符号 16 位整数 |
| 宽度 U32（W_U32） | 7 | 无符号 32 位整数 |
| 宽度 U64（W_U64） | 8 | 无符号 64 位整数 |
| 宽度 F32（W_F32） | 9 | 32 位浮点数 |
| 宽度 F64（W_F64） | 10 | 64 位浮点数 |

## 类型常量（类型（Type） constants）

| 常量 | 数值 | 含义 |
|------|------|------|
| 整数类型（TY_INT） | 0 | 基础整数 |
| 浮点数类型（TY_FLOAT） | 1 | 基础浮点数 |
| 布尔类型（TY_BOOL） | 2 | 真/假布尔值 |
| 字符串类型（TY_STRING） | 3 | 字节缓冲字符串 |
| 单元类型（TY_UNIT） | 4 | 空元组，无返回值 |
| 永无类型（TY_NEVER） | 5 | 永不返回（发散类型） |
| 字符类型（TY_CHAR） | 6 | 单个 Unicode 码点 |
| 泛型参数哨兵（TY_GENERIC_PARAM） | 7 | 标记泛型参数节点的特殊值 |
| 最大泛型参数数（MAX_GENERICS） | 4 | 每个声明允许的最大泛型参数数 |
| 最大结构体字段数（MAX_STRUCT_FIELDS） | 16 | 每个结构体最大字段数 |
| 最大枚举变体数（MAX_ENUM_VARIANTS） | 16 | 每个枚举最大变体数 |
| 最大变体载荷类型数（MAX_VARIANT_TYPES） | 16 | 每个变体最大载荷类型数 |

## 类型表预分配索引（类型（Type） table pre-allocated indices）

> 在类型检查器初始化时预分配的固定类型索引号。

| 常量 | 数值 | 含义 |
|------|------|------|
| 类型表预分配：整数（TI_INT） | 0 | 整数类型的类型表索引 |
| 类型表预分配：浮点数（TI_FLOAT） | 1 | 浮点数类型的类型表索引 |
| 类型表预分配：布尔（TI_BOOL） | 2 | 布尔类型的类型表索引 |
| 类型表预分配：字符串（TI_STR） | 3 | 字符串类型的类型表索引 |
| 类型表预分配：单元（TI_UNIT） | 4 | 单元类型的类型表索引 |
| 类型表预分配：永无（TI_NEVER） | 5 | 永无类型的类型表索引 |
| 类型表预分配：字符（TI_CHAR） | 6 | 字符类型的类型表索引 |
| 类型表预分配：动态（TI_DYN） | 7 | 动态类型的类型表索引 |

## 类型表条目类别（类型（Type） table entry kinds）

| 常量 | 数值 | 含义 |
|------|------|------|
| 类型条目类别：基础（TYP_BASE） | 0 | 基础类型（data = TY_*） |
| 类型条目类别：命名（TYP_NAMED） | 1 | 命名类型（data = 名称索引） |
| 类型条目类别：数组（TYP_ARRAY） | 2 | 定长数组（data = 元素类型，extra = 大小） |
| 类型条目类别：引用（TYP_REF） | 3 | 引用类型（data = 内部类型，extra = 可变标记） |
| 类型条目类别：指针（TYP_PTR） | 4 | 指针类型（data = 目标类型，extra = 地址空间） |
| 类型条目类别：泛型参数（TYP_GENERIC_PARAM） | 7 | 未解析泛型参数（data = 名称字符串索引） |
| 类型条目类别：泛型应用（TYP_GENERIC_APPLY） | 8 | 泛型实例化（data = 基础类型，extra = g_gen_apply_data 起始索引） |
| 类型条目类别：切片（TYP_SLICE） | 9 | 动态长度切片视图（data = 元素类型索引） |
| 类型条目类别：元组（TYP_TUPLE） | 10 | 元组类型（data = 元素数，extra = g_gen_apply_data 起始索引） |
| 类型条目类别：动态（TYP_DYN） | 11 | 动态类型（data = 类型集位图，0 表示单一已知类型） |

## 符号类别常量（Symbol kinds）

| 常量 | 数值 | 含义 |
|------|------|------|
| 符号类别：函数（SYM_FN） | 0 | 函数符号 |
| 符号类别：类型（SYM_TYPE） | 1 | 类型符号（结构体/枚举/别名） |
| 符号类别：局部变量（SYM_LOCAL） | 2 | 局部变量符号 |
| 符号类别：参数（SYM_PARAM） | 3 | 函数参数符号 |
| 符号类别：全局变量（SYM_GLOBAL） | 4 | 全局变量符号 |
| 符号类别：模块（SYM_MODULE） | 5 | 模块别名符号 |
| 符号类别：动态库函数（SYM_SO_FN） | 6 | .so 动态库函数符号 |

### 参数/函数标记（Tag flags）

| 常量 | 数值 | 含义 |
|------|------|------|
| 标记：可变参数（TAG_VARIADIC） | 1 | 可变参数函数 |
| 标记：自动字符串（TAG_AUTO_STR） | 2 | 自动字符串参数 |

## 结构体定义（Struct definitions）

### 词法单元结构
`
结构 词法单元结构：
    字段：类别（kind），类型：整数
    字段：词素（lexeme），类型：字符串（字符串）
    字段：整数值（int_val），类型：整数
    字段：行号（line），类型：整数
    字段：列号（col），类型：整数
`

### 结构 函数信息（FuncInfo）
`
结构 函数信息：
    字段：名称（name），类型：字符串（字符串）
    字段：参数计数（param_count），类型：整数
    字段：参数类型（param_types），类型：64 元素整数数组
    字段：返回类型（return_type），类型：整数
    字段：AST 节点（ast_node），类型：整数（AST 数组索引）
    字段：泛型名称（generic_names），类型：16 元素字符串数组
    字段：泛型计数（generic_count），类型：整数
`

### 结构体信息
`
结构 结构体信息：
    字段：名称（name），类型：字符串（字符串）
    字段：字段名称（field_names），类型：64 元素字符串数组
    字段：字段类型（field_types），类型：64 元素整数数组
    字段：字段类型节点（field_type_nodes），类型：64 元素整数数组（用于泛型解析）
    字段：字段计数（field_count），类型：整数
    字段：泛型名称（generic_names），类型：16 元素字符串数组
    字段：泛型计数（generic_count），类型：整数
`

### 枚举变体信息
`
结构 枚举变体信息：
    字段：名称（name），类型：字符串（字符串）
    字段：类型列表（types），类型：64 元素整数数组（每个字段的 TY_* 值）
    字段：类型计数（type_count），类型：整数
`

### 枚举信息
`
结构 枚举信息：
    字段：名称（name），类型：字符串（字符串）
    字段：变体列表（variants），类型：16 元素 枚举变体信息 数组
    字段：变体计数（variant_count），类型：整数
    字段：泛型名称（generic_names），类型：16 元素字符串数组
    字段：泛型计数（generic_count），类型：整数
`

### 循环信息
`
结构 循环信息：
    字段：起始标签（start_label），类型：字符串（字符串）
    字段：结束标签（end_label），类型：字符串（字符串）
`

### 语法树节点
`
结构 语法树节点：
    字段：类别（kind），类型：整数
    字段：子节点 变量甲（a）（变量甲），类型：整数          （子节点/索引槽 1）
    字段：子节点 变量乙（b）（变量乙），类型：整数          （子节点/索引槽 2）
    字段：子节点 变量丙（c）（变量丙），类型：整数          （子节点/索引槽 3）
    字段：整数值（int_val），类型：整数      （整数字面量或字符串表引用）
    字段：类型值（type_val），类型：整数     （已解析类型 TY_*）
    字段：数据（data），类型：整数           （额外数据：可变标记等）
    字段：行号（line），类型：整数
    字段：列号（col），类型：整数
`

## AST 节点类别常量（AST 节点（node） 种类（kind） constants）

| 常量 | 数值 | 含义 |
|------|------|------|
| 空表达式（EXPR_NONE） | 0 | 空/兜底节点 |
| 整数字面量表达式（EXPR_INT） | 1 | int_val = 整数值 |
| 浮点数字面量表达式（EXPR_FLOAT） | 27 | int_val = 值（缩放整数） |
| 字符串字面量表达式（EXPR_STRING） | 2 | int_val = 字符串表索引 |
| 布尔字面量表达式（EXPR_BOOL） | 3 | int_val = 0/1 |
| 标识符表达式（EXPR_IDENT） | 4 | int_val = 名称字符串表索引 |
| 二元运算表达式（EXPR_BINARY） | 5 | a = 左侧，b = 右侧，c = 操作码 |
| 一元运算表达式（EXPR_UNARY） | 6 | a = 操作数，c = 操作码 |
| 调用表达式（EXPR_CALL） | 7 | a = 被调用节点，b = 首参节点索引，c = 实参个数 |
| 代码块表达式（EXPR_BLOCK） | 8 | a = g_block_stmts 起始索引，b = 语句个数 |
| 如果表达式（EXPR_IF） | 9 | a = 条件，b = 真分支，c = 假分支（-1 无） |
| 循环表达式（EXPR_LOOP） | 10 | a = 循环体 |
| 声明表达式（EXPR_LET） | 11 | a = 名称索引，b = 类型，c = 值，data = 是否可变 |
| 返回表达式（EXPR_RETURN） | 12 | a = 返回值表达式（-1 无） |
| 字段访问表达式（EXPR_FIELD） | 13 | a = 对象，int_val = 字段名称索引 |
| 索引访问表达式（EXPR_INDEX） | 14 | a = 对象，b = 索引 |
| 赋值表达式（EXPR_ASSIGN） | 15 | a = 目标，b = 值 |
| 结构体字面量表达式（EXPR_STRUCT） | 16 | a = 类型名称索引，b = 首字段值，c = 字段个数 |
| 函数定义表达式（EXPR_FN） | 17 | a = 名称索引，b = 首参，c = 参数个数，data = 返回类型 |
| 参数表达式（EXPR_PARAM） | 18 | a = 名称索引，int_val = 类型 |
| 数组字面量表达式（EXPR_ARRAY） | 19 | a = 首元素，b = 元素个数 |
| 跳出循环表达式（EXPR_BREAK） | 20 | 跳出当前循环 |
| 继续表达式（EXPR_CONTINUE） | 21 | 继续下一次迭代 |
| 遍历表达式（EXPR_FOR） | 22 | a = 变量名称索引，b = 迭代源，c = 循环体 |
| 匹配表达式（EXPR_MATCH） | 23 | a = 被匹配表达式，b = 首分支，c = 分支个数 |
| 分支表达式（EXPR_ARM） | 24 | a = 模式，b = 分支体 |
| 通配表达式（EXPR_WILDCARD） | 25 | 通配符 `_` |
| 枚举模式表达式（EXPR_ENUMPAT） | 26 | a = 名称索引，b = 首子模式，c = 子模式个数 |
| 语句表达式（EXPR_STMT） | 28 | a = 内部表达式；作为语句使用的表达式（带 `;`），返回单元 |
| 字符字面量表达式（EXPR_CHAR） | 29 | int_val = 码点 |
| 当循环表达式（EXPR_WHILE） | 30 | a = 条件，b = 循环体 |
| 范围表达式（EXPR_RANGE） | 31 | a = 起始，b = 结束 |
| 移动表达式（EXPR_MOVE） | 32 | a = 被移动的表达式 |
| 枚举构造器表达式（EXPR_ENUM_CONSTRUCTOR） | 37 | a = 名称索引，b = 首参，c = 参数个数 |
| 引用类型表达式（EXPR_REFTYPE） | 38 | a = 内部类型节点，data = 可变标记（用于类型位置的 `&T`/`&mut T`） |
| 泛型应用表达式（EXPR_GENERIC_APPLY） | 39 | a = 基础名称索引，b = 首参数类型节点，c = 参数个数 |
| 元组字面量表达式（EXPR_TUPLE） | 40 | a = 首元素，b = 元素个数 |
| 参数链接表达式（EXPR_ARG） | 41 | a = 表达式，b = 下一参数节点或 -1（参数链表） |
| 协程表达式（EXPR_GO） | 42 | go expr：a = -1，b = 体；go var start..end expr：a = -1，b = 体，c = 迭代变量名索引，data = 范围节点 |
| 数据流函数表达式（EXPR_FLOW） | 43 | a = 函数名索引，b = 参数个数，c = 首参，data = 函数体 |
| 让出表达式（EXPR_YIELD） | 44 | a = 值表达式 |
| 等待表达式（EXPR_AWAIT） | 45 | a = 值表达式（待等待的 future/flow） |
| 内建注解表达式（EXPR_AT） | 46 | a = 名称索引，b = 参数节点，c = 0 |
| 尝试表达式（EXPR_TRY） | 33 | a = 被尝试的表达式（`?` 操作符） |
| 不安全块表达式（EXPR_UNSAFE） | 34 | a = 块体 |
| 结构体模式表达式（EXPR_STRUCTPAT） | 35 | a = 名称索引，b = 首字段模式，c = 字段个数 |
| 类型转换表达式（EXPR_AS） | 36 | a = 表达式，b = 类型节点（`expr as Type`） |
| 指针类型表达式（EXPR_PTRTYPE） | 47 | a = 内部类型（类型位置的 `*T`） |
| 外部函数表达式（EXPR_EXTERN） | 48 | a = 名称索引，b = 首参，c = 参数个数，data = FFI 语言名称索引 |

## 字段对结构（FieldPair）

> 结构体字面量中字段由两个连续的 AST 节点表示（名称索引，值索引，行号 = 行号，列号 = 列号）。

`
结构 字段对：
    字段：名称索引（name_idx），类型：整数
    字段：值索引（value_idx），类型：整数
    字段：行号（line），类型：整数
    字段：列号（col），类型：整数
`

## 二元操作码（Binary operator codes）

| 常量 | 数值 | 含义 |
|------|------|------|
| 加法运算指令（OP_ADD） | 1 | 加法 |
| 减法运算指令（OP_SUB） | 2 | 减法 |
| 乘法运算指令（OP_MUL） | 3 | 乘法 |
| 除法运算指令（OP_DIV） | 4 | 除法 |
| 取模运算指令（OP_MOD） | 5 | 取模 |
| 等于比较指令（OP_EQ） | 6 | 等于 `==` |
| 不等于比较指令（OP_NE） | 7 | 不等于 `!=` |
| 小于比较指令（OP_LT） | 8 | 小于 `<` |
| 大于比较指令（OP_GT） | 9 | 大于 `>` |
| 小于等于比较指令（OP_LE） | 10 | 小于等于 `<=` |
| 大于等于比较指令（OP_GE） | 11 | 大于等于 `>=` |
| 逻辑与指令（OP_AND） | 12 | 逻辑与 `&&` |
| 逻辑或指令（OP_OR） | 13 | 逻辑或 `\|\|` |
| 赋值指令（OP_ASSIGN） | 14 | 赋值 `=` |
| 左移指令（OP_SHL） | 15 | 左移 `<<` |
| 右移指令（OP_SHR） | 16 | 右移 `>>` |
| 指针加法指令（OP_PTR_ADD） | 17 | 指针加整数（T） |
| 指针减法指令（OP_PTR_SUB） | 18 | 指针减整数 |
| 指针差值指令（OP_PTR_DIFF） | 19 | 指针减指针（得元素个数） |

## 一元操作码（Unary operator codes）

| 常量 | 数值 | 含义 |
|------|------|------|
| 一元取负（UOP_NEG） | 1 | 算术取负 |
| 一元逻辑非（UOP_NOT） | 2 | 逻辑非 `!` |
| 一元取引用（UOP_REF） | 3 | 取引用 `&` |
| 一元解引用（UOP_DEREF） | 4 | 解引用 `*` |

## 错误码定义（Error codes）

> 格式：类别 * 1000 + 编号，与 `docs/developer/errors.md` 对应。
> 0=未分类，1=语法解析（P），2=名称解析（N），3=类型推断（I），4=类型赋值（TA），5=类型函数（TF），6=类型二元运算（TB），7=类型一元运算（TU），8=类型控制流（TC），9=类型匹配（TM），10=类型数组切片（TK），11=类型结构体（TS），12=类型泛型（TG），13=借用（B），14=运行时（R），15=输入输出（E），16=内部编译器错误（ICE）。

### 语法解析错误（P0xx）
| P001 | EC_P_EXPECTED | 1001 | 期望 X 但遇到 Y |
| P002 | EC_P_TOPLEVEL | 1002 | 顶层意外的词法单元 |
| P003 | EC_P_EXPR | 1003 | 表达式中意外的词法单元 |
| P004 | EC_P_ARR_SIZE | 1004 | 数组大小不是常量 |
| P005 | EC_P_PATTERN | 1005 | 模式中意外的词法单元 |
| P006 | EC_P_BRACKET | 1006 | 缺少闭合定界符 |
| P007 | EC_P_SEMI | 1007 | 期望分号 |
| P008 | EC_P_STRUCT_EMPTY | 1008 | 空结构体体 |
| P009 | EC_P_ENUM_EMPTY | 1009 | 空枚举体 |
| P010 | EC_P_FN_EMPTY | 1010 | 空函数体 |
| P011 | EC_P_PARAM_TYPE | 1011 | 参数需要类型注解 |
| P012 | EC_P_GENERIC_LIST | 1012 | 无效泛型参数列表 |
| P013 | EC_P_FIELD_SYNTAX | 1013 | 无效字段语法 |
| P014 | EC_P_MATCH_EMPTY | 1014 | 匹配体为空 |
| P015 | EC_P_PAT_BIND | 1015 | 无效模式绑定 |
| P016 | EC_P_IMPORT_PATH | 1016 | 无效引入路径 |
| P017 | EC_P_FILEID | 1017 | 无效文件标识声明 |
| P018 | EC_P_VAR_DECL | 1018 | 无效变量声明 |
| P019 | EC_P_LIT_OVERFLOW | 1019 | 数值字面量溢出 |

### 名称解析错误（N0xx）
| N001 | EC_N_UNDEFINED | 2001 | 未定义名称 |
| N002 | EC_N_STRUCT | 2002 | 未定义结构体 |
| N003 | EC_N_FIELD | 2003 | 未定义字段 |
| N004 | EC_N_ENUM_CON | 2004 | 未定义枚举构造器 |
| N005 | EC_N_ENUM_VAR | 2005 | 未定义枚举变体 |
| N006 | EC_N_FUNC | 2006 | 未定义函数 |
| N007 | EC_N_TYPE | 2007 | 未定义类型 |
| N008 | EC_N_METHOD | 2008 | 未定义方法 |
| N009 | EC_N_GENERIC_TYPE | 2009 | 泛型应用中未定义的类型 |
| N010 | EC_N_GENERIC_PARAM | 2010 | 未定义泛型参数 |
| N011 | EC_N_DUPLICATE | 2011 | 重复定义 |
| N012 | EC_N_DUP_FIELD | 2012 | 重复字段 |
| N013 | EC_N_DUP_VARIANT | 2013 | 重复变体 |
| N014 | EC_N_DUP_FUNC | 2014 | 重复函数 |
| N015 | EC_N_FILEID_CONFLICT | 2015 | 文件标识冲突 |
| N016 | EC_N_MODULE | 2016 | 未定义模块 |
| N017 | EC_N_PROJECT | 2017 | 未定义项目 |
| N018 | EC_N_CYCLE | 2018 | 循环引入 |
| N019 | EC_N_IMPORT_FILE | 2019 | 引入文件不存在 |
| N020 | EC_N_IMPORT_READ | 2020 | 引入文件读取失败 |
| N021 | EC_N_REEXPORT | 2021 | 重新导出冲突 |

### 类型推断错误（I0xx）
| I001 | EC_I_INFER | 3001 | 无法推断类型 |
| I002 | EC_I_INFER_GLOBAL | 3002 | 无法推断全局变量类型 |
| I003 | EC_I_INFER_RET | 3003 | 无法推断返回类型 |
| I004 | EC_I_INFER_GENERIC | 3004 | 无法推断泛型参数 |
| I005 | EC_I_AMBIGUOUS | 3005 | 歧义类型 |
| I006 | EC_I_INFINITE | 3006 | 无限类型 |

### 类型赋值错误（TA0xx）
| TA01 | EC_TA_ASSIGN | 4001 | 无法将 T2 赋值给 T1 |
| TA02 | EC_TA_DECL | 4002 | 声明类型与初始化表达式类型不匹配 |
| TA03 | EC_TA_BATCH | 4003 | 批量声明类型混合 |
| TA04 | EC_TA_IMMUTABLE | 4004 | 不可变变量被赋值 |
| TA05 | EC_TA_NOT_MUT | 4005 | 变量非可变 |
| TA06 | EC_TA_GLOBAL_MUT | 4006 | 全局变量非可变 |
| TA07 | EC_TA_TUPLE_ARITY | 4007 | 元组解构元素个数不匹配 |

### 类型函数错误（TF0xx）
| TF01 | EC_TF_RETURN | 5001 | 返回类型不匹配 |
| TF02 | EC_TF_MISSING_RET | 5002 | 缺少返回语句 |
| TF03 | EC_TF_EXTRA_RET | 5003 | 单元函数中多余的返回值 |
| TF04 | EC_TF_BRANCH_RET | 5004 | 分支返回类型不匹配 |
| TF05 | EC_TF_ARG_COUNT | 5005 | 实参个数不匹配 |
| TF06 | EC_TF_ARG_TOO_MANY | 5006 | 实参过多 |
| TF07 | EC_TF_ARG_TYPE | 5007 | 实参类型不匹配 |
| TF08 | EC_TF_METHOD_NOT_FOUND | 5008 | 方法未找到 |
| TF09 | EC_TF_METHOD_ARG_CNT | 5009 | 方法实参个数不匹配 |
| TF10 | EC_TF_METHOD_ARG_TYP | 5010 | 方法实参类型不匹配 |
| TF11 | EC_TF_NON_STRUCT | 5011 | 对非结构体调用方法 |
| TF12 | EC_TF_NO_MAIN | 5012 | 无 主入口（main） 函数 |
| TF13 | EC_TF_MAIN_SIG | 5013 | 主入口（main） 函数签名错误 |
| TF14 | EC_TF_SELF_PARAM | 5014 | 无效 self 参数 |
| TF15 | EC_TF_SELF_REQUIRED | 5015 | 方法需要 self 参数 |
| TF16 | EC_TF_CALL_NOT_FOUND | 5016 | 函数不在作用域内 |
| TF17 | EC_TF_AMBIGUOUS | 5017 | 模糊函数调用 |

### 类型二元运算错误（TB0xx）
| TB01 | EC_TB_ADD | 6001 | 无法进行加法 |
| TB02 | EC_TB_SUB | 6002 | 无法进行减法 |
| TB03 | EC_TB_MUL | 6003 | 无法进行乘法 |
| TB04 | EC_TB_DIV | 6004 | 无法进行除法 |
| TB05 | EC_TB_MOD | 6005 | 无法进行取模 |
| TB06 | EC_TB_CMP | 6006 | 无法比较 == 或 != |
| TB07 | EC_TB_ORDER | 6007 | 无法排序比较 < 或 > 或 <= 或 >= |
| TB08 | EC_TB_AND_OR | 6008 | && 和 || 需要布尔操作数 |
| TB09 | EC_TB_STR_CONCAT | 6009 | 字符串与非字符串相加 |

### 类型一元运算错误（TU0xx）
| TU01 | EC_TU_NEG | 7001 | 无法取负 |
| TU02 | EC_TU_NOT | 7002 | ! 需要布尔操作数 |
| TU03 | EC_TU_DEREF | 7003 | 无法解引用非引用类型 |

### 类型控制流错误（TC0xx）
| TC01 | EC_TC_IF_COND | 8001 | 如果条件必须为布尔 |
| TC02 | EC_TC_IF_BRANCH | 8002 | 如果的分支类型不同 |
| TC03 | EC_TC_IF_NO_ELSE | 8003 | 没有否则分支的如果返回单元类型 |
| TC04 | EC_TC_WHILE_COND | 8004 | 当循环条件必须为布尔 |
| TC05 | EC_TC_BREAK_VAL | 8005 | 跳出循环的值不匹配 |
| TC06 | EC_TC_BREAK_OUT | 8006 | 在循环外使用跳出循环 |
| TC07 | EC_TC_CONT_OUT | 8007 | 在循环外使用继续 |

### 类型匹配错误（TM0xx）
| TM01 | EC_TM_ENUM | 9001 | 匹配的目标必须为枚举 |
| TM02 | EC_TM_ARM_TYPE | 9002 | 分支类型不匹配 |
| TM03 | EC_TM_EXHAUST | 9003 | 非穷尽匹配 |
| TM04 | EC_TM_REDUNDANT | 9004 | 冗余分支 |
| TM05 | EC_TM_WILDCARD_ORDER | 9005 | 通配符不是最后一个分支 |
| TM06 | EC_TM_ARG_CNT | 9006 | 构造器参数个数不匹配 |
| TM07 | EC_TM_ARG_TYPE | 9007 | 构造器参数类型不匹配 |
| TM08 | EC_TM_BIND_DUP | 9008 | 模式绑定重复 |
| TM09 | EC_TM_NESTED | 9009 | 不允许嵌套模式 |

### 类型数组切片错误（TK0xx）
- 词法单元种类1（TK01）（EC_TK_INDEX = 10001）：无法索引非数组类型
- 词法单元种类2（TK02）（EC_TK_ELEM_TYPE = 10002）：元素类型不匹配
- 词法单元种类3（TK03）（EC_TK_SIZE_TYPE = 10003）：大小必须为整数
- 词法单元种类4（TK04）（EC_TK_SIZE_NEG = 10004）：大小必须为正数
- 词法单元种类5（TK05）（EC_TK_SLICE_BOUNDS = 10005）：切片越界
- 词法单元种类6（TK06）（EC_TK_SLICE_LEN = 10006）：切片长度为负
- 词法单元种类7（TK07）（EC_TK_FOR_ITER = 10007）：无法遍历
- 词法单元种类8（TK08）（EC_TK_FOR_TYPE = 10008）：遍历变量类型不匹配

### 类型结构体错误（TS0xx）
| TS01 | EC_TS_MISSING_FIELD | 11001 | 缺少字段 |
| TS02 | EC_TS_UNKNOWN_FIELD | 11002 | 未知字段 |
| TS03 | EC_TS_FIELD_TYPE | 11003 | 字段类型不匹配 |
| TS04 | EC_TS_FIELD_DUP | 11004 | 字段重复初始化 |

### 类型泛型错误（TG0xx）
| TG01 | EC_TG_ARG_COUNT | 12001 | 泛型参数个数不匹配 |
| TG02 | EC_TG_BOUND | 12002 | 泛型约束不满足 |

### 借用错误（B0xx）
| B001 | EC_B_BORROW_MUT | 13001 | 可变借用于已借用变量 |
| B002 | EC_B_BORROW_IMMUT | 13002 | 不可变借用于可变借用中的变量 |
| B003 | EC_B_BORROW_MUT2 | 13003 | 两个可变借用 |
| B004 | EC_B_USE_WHILE_BORROWED | 13004 | 在借用期间使用 |
| B010 | EC_B_ESCAPE | 13010 | 引用逃逸函数 |
| B011 | EC_B_LIFETIME | 13011 | 生命周期过短 |
| B020 | EC_B_MOVE_USE | 13020 | 使用已移动的值 |
| B021 | EC_B_MOVE_AGAIN | 13021 | 移动已移动的值 |
| B022 | EC_B_MOVE_BORROWED | 13022 | 在借用期间移动 |

### 运行时错误（R0xx）
| R001 | EC_R_DIV_ZERO | 14001 | 除以零 |
| R002 | EC_R_OOB | 14002 | 索引越界 |
| R003 | EC_R_OVERFLOW | 14003 | 整数溢出 |
| R004 | EC_R_LOSSY_CONVERT | 14004 | 有损转换 |

### 输入输出错误（E0xx）
| E001 | EC_E_READ_FILE | 15001 | 无法读取源文件 |
| E002 | EC_E_WRITE_FILE | 15002 | 无法写入输出文件 |
| E003 | EC_E_CCR_CORRUPT | 15003 | CCR 文件损坏 |
| E004 | EC_E_CCR_OPEN | 15004 | 无法打开 CCR 文件 |

### 内部编译器错误（ICE）
| ICE01 | EC_ICE_UNEXPECTED | 16001 | 意外情况 |
| ICE02 | EC_ICE_OVERFLOW | 16002 | 缓冲区溢出 |
| ICE03 | EC_ICE_UNSUPPORTED | 16003 | 不支持 |

## 诊断信息结构（Diag）
`
结构 诊断信息：
    字段：错误码（code），类型：整数
    字段：消息（msg），类型：字符串（字符串）
    字段：行号（line），类型：整数
    字段：列号（col），类型：整数
`

## IR 操作码常量（IR instruction opcodes）

| 常量 | 数值 | 含义 |
|------|------|------|
| 空操作指令（IR_NOP） | 0 | 无操作 |
| 常量指令（IR_CONST） | 1 | 加载常量 |
| 二元运算指令（IR_BINARY） | 2 | 二元运算 |
| 一元运算指令（IR_UNARY） | 3 | 一元运算 |
| 调用指令（IR_CALL） | 4 | 函数调用 |
| 返回指令（IR_RETURN） | 5 | 函数返回 |
| 分配指令（IR_ALLOC） | 6 | 栈上分配 |
| 分配结构体指令（IR_ALLOC_STRUCT） | 7 | 分配结构体 |
| 分配数组指令（IR_ALLOC_ARRAY） | 8 | 分配数组 |
| 存储指令（IR_STORE） | 9 | 存储到栈变量 |
| 加载指令（IR_LOAD） | 10 | 从栈变量加载 |
| 加载字段指令（IR_LOAD_FIELD） | 11 | 加载结构体字段 |
| 存储字段指令（IR_STORE_FIELD） | 12 | 存储结构体字段 |
| 加载索引指令（IR_LOAD_INDEX） | 13 | 加载数组元素 |
| 存储索引指令（IR_STORE_INDEX） | 14 | 存储数组元素 |
| 加载可变索引指令（IR_LOAD_INDEX_VAR） | 15 | 可变索引加载 |
| 存储可变索引指令（IR_STORE_INDEX_VAR） | 16 | 可变索引存储 |
| 构造枚举指令（IR_MAKE_ENUM） | 17 | 构造枚举值 |
| 引用指令（IR_REF） | 18 | 取引用 |
| 条件分支指令（IR_BRANCH） | 19 | 条件分支 |
| 跳转指令（IR_JUMP） | 20 | 无条件跳转 |
| 标签指令（IR_LABEL） | 21 | 标签 |
| Phi 指令（IR_PHI） | 22 | Phi 节点（SSA） |
| 加载枚举标签指令（IR_LOAD_ENUM_TAG） | 23 | 提取枚举标签 |
| 切片指令（IR_SLICE） | 24 | dest=切片变量，s1=数组变量，s2=低位变量，src3=高位变量 |
| 解引用指令（IR_DEREF） | 25 | dest=加载值，s1=引用变量（通过指针加载） |
| 指针存储指令（IR_STORE_PTR） | 26 | dest=值变量，s1=指针变量，s2=值变量（通过指针存储） |
| 地址索引指令（IR_ADDR_INDEX） | 31 | dest=地址，s1=数组变量，s2=索引变量，s3=缩放（计算地址不加载） |
| 协程派生指令（IR_SPAWN） | 27 | dest=结果变量，s1=函数名索引，s2=首参，src3=参数个数，type_kind=派生个数 |
| 让出指令（IR_YIELD） | 28 | s1=值变量（从 flow 发射值到消费者通道） |
| 等待指令（IR_AWAIT） | 29 | dest=值变量，s1=future 变量（阻塞等待 future 就绪） |
| 边界检查指令（IR_BOUNDS_CHECK） | 30 | s1=索引变量，s2=最大长度（索引越界中止） |
| 竞技场新建指令（IR_ARENA_NEW） | 32 | dest=竞技场变量，src1=大小估计 |
| 竞技场重置指令（IR_ARENA_RESET） | 33 | src1=竞技场 ID |
| 内联提示指令（IR_INLINE） | 34 | src1=函数变量 |
| 无边界检查指令（IR_NO_BOUNDS_CHECK） | 35 | 跳过后续解引用的边界检查 |
| 快速指令（IR_FAST） | 36 | 允许精度换速度优化 |
| 循环展开指令（IR_UNROLL） | 37 | src1=展开次数 |
| 代码段指令（IR_SECTION） | 38 | src1=段名称索引 |
| 热补丁路由指令（IR_HOTPATCH_ROUTE） | 39 | dest=结果变量，s1=函数名索引，s2=首参，s3=参数个数 |
| 动态标签指令（IR_DYN_TAG） | 41 | dest=标签变量，s1=动态变量（提取标签） |
| 动态取值指令（IR_DYN_VAL） | 42 | dest=值变量，s1=动态变量（提取值） |
| 动态封包指令（IR_DYN_PACK） | 43 | dest=动态变量，s1=值变量，s2=类型索引 |
| 动态分发指令（IR_DYN_DISPATCH） | 44 | s1=动态变量，s2=分发表索引 |
| 外部调用指令（IR_CALL_EXTERN） | 45 | dest=结果变量，s1=函数名索引，s2=首参，s3=参数个数 |
| 惰性求值封装指令（IR_LAZY_THUNK） | 46 | dest=惰性变量，s1=表达式变量（包装为惰性求值） |
| 惰性求值强制执行指令（IR_LAZY_FORCE） | 47 | dest=值变量，s1=惰性变量（强制求值） |
| 函数地址指令（IR_FNADDR） | 48 | dest=地址变量，s1=函数名索引（movabs + 链接时修补） |

### 标签解析标记
| 常量 | 数值 | 含义 |
|------|------|------|
| 已解析标记（IR_RESOLVED） | 1 | 分支/跳转标签已解析（存入 type_kind 字段） |

## IR 数据结构（IR 数据（data） structures）

### IR 变量
`
结构 IR 变量：
    字段：名称（name），类型：字符串（字符串）
    字段：ID（id），类型：整数
    字段：类型类别（type_kind），类型：整数
`

### IR 指令
`
结构 IR 指令：
    字段：操作码（opcode），类型：整数
    字段：目标（dest），类型：整数      （目标变量索引）
    字段：操作数1（src1），类型：整数     （源变量/值 1）
    字段：操作数2（src2），类型：整数     （源变量/值 2）
    字段：操作数3（src3），类型：整数     （额外数据：标签、字段名等）
    字段：类型类别（type_kind），类型：整数 （类型信息）
`

## HDFG结构（Dataflow Graph structures）

### 数据流节点
`
结构 数据流节点：
    字段：操作码（opcode），类型：整数
    字段：目标变量（dest_var），类型：整数   （该节点定义的 IR 变量，-1 表无）
    字段：操作数1（src1），类型：整数         （原始操作数，语义同 IR 指令）
    字段：操作数2（src2），类型：整数
    字段：操作数3（src3），类型：整数
    字段：类型类别（type_kind），类型：整数
    字段：首出边（first_edge），类型：整数    （在 g_df_edges 中第一条出边的索引，-1 表无）
    字段：出边计数（edge_count），类型：整数   （出边数量）
`

### 数据流边
`
结构 数据流边：
    字段：来源节点（from_node），类型：整数
    字段：目标节点（to_node），类型：整数
    字段：下一条出边（next_out），类型：整数   （同一源节点的下一条出边，-1 表无）
    字段：边类别（kind），类型：整数           （0 = 数据（def-use），1 = 状态（排序/终止））
`

## 优化元数据键（Optimization metadata keys）

| 常量 | 数值 | 含义 |
|------|------|------|
| 优化元数据键：寄存器分配（OPT_KEY_REG_ASSIGN） | 0 | [var_idx:u32, reg_num:u8]... |
| 优化元数据步长（OPT_META_STRIDE） | 64 | 头部 8 字节 + 最多 5 个寄存器对 |
| 优化元数据键：栈共享（OPT_KEY_STACK_SHARE） | 1 | [var_idx:u32, mapped_to:u32]... |
| 优化元数据键：公共子表达式消除（OPT_KEY_CSE） | 2 | [op:u32, s1:u32, s2:u32, res:u32]... |
