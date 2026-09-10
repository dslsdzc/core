// === ast.core ===
// Core compiler - shared type definitions and constants

// Token kind constants
T_EOF : int = 0;
T_IDENT : int = 1;
T_INT : int = 2;
T_DEX : int = 3;  // 3.14 字面量令牌（数值迁移 Task 3：T_FLOAT → T_DEX，值=binary64 位模式 = apx 快路径表示；精确解析在 Task 4）
T_STRING : int = 4;
T_FN : int = 5;
T_MUT : int = 7;
T_IF : int = 8;
T_ELSE : int = 9;
T_LOOP : int = 10;
T_FOR : int = 11;
T_IN : int = 12;
T_RETURN : int = 13;
T_BREAK : int = 14;
T_CONTINUE : int = 15;
T_STRUCT : int = 16;
T_ENUM : int = 17;
T_IMPL : int = 18;
T_PUB : int = 19;
T_TRUE : int = 20;
T_FALSE : int = 21;
T_MOVE : int = 22;
T_SELF : int = 23;
T_LPAREN : int = 24;
T_RPAREN : int = 25;
T_LBRACE : int = 26;
T_RBRACE : int = 27;
T_COMMA : int = 28;
T_SEMI : int = 29;
T_COLON : int = 30;
T_DOT : int = 31;
T_ARROW : int = 32;
T_EQ : int = 33;
T_EQEQ : int = 34;
T_BANG : int = 35;
T_BANGEQ : int = 36;
T_LT : int = 37;
T_GT : int = 38;
T_LTEQ : int = 39;
T_GTEQ : int = 40;
T_PLUS : int = 41;
T_MINUS : int = 42;
T_STAR : int = 43;
T_SLASH : int = 44;
T_ANDAND : int = 45;
T_PIPEPIPE : int = 46;
T_AMPERSAND : int = 47;
T_UNDERSCORE : int = 48;
T_UNIT : int = 49;
T_PATHSEP : int = 50;
T_LBRACKET : int = 51;
T_RBRACKET : int = 52;
T_MATCH : int = 53;
T_FATARROW : int = 54;
T_PERCENT : int = 55;
T_CHAR : int = 56;
T_WHILE : int = 57;
T_DOTDOT : int = 58;
T_DOTDOTDOT : int = 59;
T_TYPE : int = 60;
T_MOD : int = 61;
T_IMPORT : int = 62;
T_AS : int = 63;
T_GO : int = 64;
T_AWAIT : int = 65;
T_FLOW : int = 66;
T_YIELD : int = 67;
T_UNSAFE : int = 68;
T_INTERFACE : int = 97;
T_COLON_EQ : int = 98;
T_AUTO : int = 69;
T_AT : int = 70;
T_FILEID : int = 71;
T_QUESTION : int = 72;
T_PLUS_EQ : int = 73;
T_MINUS_EQ : int = 74;
T_STAR_EQ : int = 75;
T_SLASH_EQ : int = 76;

// 77-86 原为宽度后缀 token kind（T_INT_I8..T_INT_U64 / T_FLOAT_F32 / T_FLOAT_F64）。
// 2026-09-10 语言面收窄 §2 删除：lexer 从不发射这些 kind（宽度后缀已退役，改响亮报错），
// parser 侧引用同步移除。**勿重编号**——编号空间稳定（先例：T_FLOAT_TYPE 91 已删除）。
T_NONE : int = 87;
T_SOME : int = 88;
T_LET : int = 89;
T_INT_TYPE : int = 90;
// T_FLOAT_TYPE 91 已删除（数值迁移 Task 5：float 类型名移除；勿重编号——保持 LSP
// 区间 T_INT_TYPE..T_AUTO_TYPE 90..95 连续，见 analysis.cr 说明）
T_BOOL_TYPE : int = 92;
T_UNIT_TYPE : int = 93;
T_STR_TYPE : int = 94;
T_AUTO_TYPE : int = 95;
T_REF : int = 96;
T_DYN : int = 99;  // dynamic type
T_EXTERN : int = 100;  // extern "C" / foreign function declaration

// W_I8..W_F64（1..10）原为「宽度标注」值域，仅供宽度后缀 token 分支使用。
// 2026-09-10 语言面收窄 §2 随死分支一并删除。**勿重编号**。

// Type constants
TY_INT : int = 0;
TY_DEX : int = 1;  // dex 精确小数（数值迁移 Task 3：TY_FLOAT 更名；Task 5：float 类型名移除，用户写 dex）
TY_BOOL : int = 2;
TY_STRING : int = 3;
TY_UNIT : int = 4;
TY_NEVER : int = 5;
TY_CHAR : int = 6;
TY_GENERIC_PARAM : int = 7;  // special sentinel for generic type params
TY_DEX_S : int = 8;  // dex 定点形式（TI_DEX_S）的类型表占位 data（终审 M1：占住表项
                     // 下标 8，用户类型从 9 起；占位项永不参与解析/运算）
MAX_GENERICS : int = 4;      // max generic params per declaration (language limit)
MAX_STRUCT_FIELDS : int = 16; // max fields per struct (struct info size limit)
MAX_ENUM_VARIANTS : int = 16; // max variants per enum (enum info size limit)
MAX_VARIANT_TYPES : int = 16; // max payload types per variant

// Token struct
struct Token {
    kind: int,
    lexeme: string,
    int_val: int,
    line: int,
    col: int,
}

// Function signature (for call resolution)
struct FuncInfo {
    name: string,
    param_count: int,
    param_types: [int; 64],
    return_type: int,
    ast_node: int,  // index into ast array for the fn body
    generic_names: [string; 16],
    generic_count: int,
}

// Struct layout
struct StructInfo {
    name: string,
    field_names: [string; 64],
    field_types: [int; 64],
    field_type_nodes: [int; 64],  // original type node indices (for generic resolution)
    field_count: int,
    generic_names: [string; 16],
    generic_count: int,
}

// Enum variant description
struct EnumVariant {
    name: string,
    types: [int; 64],  // TY_* for each field
    type_count: int,
}

// Enum layout
struct EnumInfo {
    name: string,
    variants: [EnumVariant; 16],
    variant_count: int,
    generic_names: [string; 16],
    generic_count: int,
}

// Loop context (for break/continue)
struct LoopInfo {
    start_label: string,
    end_label: string,
}

// Block statement index storage: sequential statement indices for each block
// EXPR_BLOCK uses a=start_idx_into_g_block_stmts, b=stmt_count

// Flat AST node - representation varies by kind
struct ASTNode {
    kind: int,
    a: int,       // child/index slot 1
    b: int,       // child/index slot 2
    c: int,       // child/index slot 3
    int_val: int, // integer literal or string table ref
    type_val: int, // resolved type (TY_*)
    data: int,     // extra data (mutable flag, etc.)
    line: int,
    col: int,
}

// AST node kind constants
EXPR_NONE : int = 0;
EXPR_INT : int = 1;      // int_val = value
EXPR_DEX : int = 27;   // int_val = value (as scaled int) —— 3.14 字面量节点（数值迁移 Task 3 更名）
EXPR_STRING : int = 2;   // int_val = str table index
EXPR_BOOL : int = 3;     // int_val = 0/1
EXPR_IDENT : int = 4;    // int_val = name str table index
EXPR_BINARY : int = 5;   // a=left, b=right, c=opcode
EXPR_UNARY : int = 6;    // a=operand, c=opcode
EXPR_CALL : int = 7;     // a=func, b=first arg idx, c=arg count, type_val=CALL_FLAG_*
CALL_FLAG_MODULE : int = 1;
CALL_FLAG_INLINE : int = 2;
EXPR_BLOCK : int = 8;    // a=g_block_stmts start, b=stmt count
EXPR_IF : int = 9;       // a=cond, b=then, c=else (-1 if none)
EXPR_LOOP : int = 10;    // a=body
EXPR_LET : int = 11;     // a=name idx, b=type, c=value, data=is_mut
EXPR_RETURN : int = 12;  // a=value expr (-1 if none)
EXPR_FIELD : int = 13;   // a=object, int_val=field name idx
EXPR_INDEX : int = 14;   // a=object, b=index
EXPR_ASSIGN : int = 15;  // a=target, b=value
EXPR_STRUCT : int = 16;  // a=type name idx, b=first field, c=field count
EXPR_FN : int = 17;      // a=name idx, b=first param, c=param count, d=body, data=return_type
EXPR_PARAM : int = 18;   // a=name idx, int_val=type
// 表示层概念（2026-09-10 语言面收窄裁决 §1）：`[T; N]` 的类型构造器身份已退役——
// 语义归处 = product（N 元聚合）/ 序列接口 + 长度 where（N 长序列）/ F11 图（长度事实，
// 可表达依赖长度）。本语法保留为「内联容量存储」表示提示（映射参数层，与 hw-map 同层；
// 随实例选择生效或退化，非经典范式映射可忽略）。见
// docs/superpowers/specs/2026-09-10-language-surface-narrowing-design.md §1
EXPR_ARRAY : int = 19;   // a=first elem, b=elem count
EXPR_BREAK : int = 20;
EXPR_CONTINUE : int = 21;
EXPR_FOR : int = 22;     // a=var name idx, b=iter, c=body
EXPR_MATCH : int = 23;   // a=expr, b=first arm, c=arm count
EXPR_ARM : int = 24;     // a=pattern, b=body
EXPR_WILDCARD : int = 25;
EXPR_ENUMPAT : int = 26; // a=name idx, b=first subpat, c=subpat count
EXPR_STMT : int = 28;   // a=inner expr; expression used as statement (with );), returns unit
EXPR_CHAR : int = 29;   // int_val = codepoint
EXPR_WHILE : int = 30;  // a=cond, b=body
EXPR_RANGE : int = 31;  // a=start, b=end
EXPR_MOVE : int = 32;     // a=expr being moved
EXPR_ENUM_CONSTRUCTOR : int = 37; // a=name idx, b=first arg, c=arg count
EXPR_REFTYPE : int = 38;   // a=inner type node, data=mut flag (for &T / &mut T in type position)
EXPR_GENERIC_APPLY : int = 39; // a=base name idx, b=first arg type node, c=arg count
EXPR_TUPLE : int = 40;         // a=first elem, b=elem count (tuple literal)
EXPR_ARG : int = 41;            // a=expr, b=next arg node or -1 (argument linked list)
EXPR_GO : int = 42;             // go expr: a=-1, b=body;  go var start..end expr: a=-1, b=body, c=iter_ni, data=range_node
EXPR_FLOW : int = 43;           // flow fn — a=fn_name_ni, b=param_count, c=first_param, data=body
EXPR_YIELD : int = 44;          // yield expr — a=value expr
EXPR_AWAIT : int = 45;          // await expr — a=value expr (future/flow to wait on)
EXPR_AT : int = 46;             // @builtin: a=name_ni, b=args_node, c=0, iv=0, tv=0, data=0

// Desugared constructs
EXPR_TRY : int = 33;      // a=expr being tried (? operator)
EXPR_UNSAFE : int = 34;   // a=block body
EXPR_STRUCTPAT : int = 35; // struct pattern: a=name ni, b=first field pat, c=field count
EXPR_AS : int = 36;        // a=expr, b=type node (cast: expr as Type)
EXPR_PTRTYPE : int = 47;  // a=inner_type (for *T in type position)
EXPR_EXTERN : int = 48;  // a=name_ni, b=first_param, c=param_count, data=ffi_lang_ni

// Field representation in struct literal: two consecutive AST nodes
// (name_idx, value_idx, line=line, col=col)
struct FieldPair {
    name_idx: int,
    value_idx: int,
    line: int,
    col: int,
}

// Binary operator codes
OP_ADD : int = 1;
OP_SUB : int = 2;
OP_MUL : int = 3;
OP_DIV : int = 4;
OP_MOD : int = 5;
OP_EQ : int = 6;
OP_NE : int = 7;
OP_LT : int = 8;
OP_GT : int = 9;
OP_LE : int = 10;
OP_GE : int = 11;
OP_AND : int = 12;
OP_OR : int = 13;
OP_ASSIGN : int = 14;
OP_SHL : int = 15;  // strength reduction: x << n
OP_SHR : int = 16;  // strength reduction: x >> n
OP_PTR_ADD  : int = 17;  // p + n (p: *T, n: int) → scaled by sizeof(T)
OP_PTR_SUB  : int = 18;  // p - n
OP_PTR_DIFF : int = 19;  // p - q → element count

// Unary operator codes
UOP_NEG : int = 1;
UOP_NOT : int = 2;
UOP_REF : int = 3;
UOP_DEREF : int = 4;

// Type table pre-allocated indices (for checker type system)
TI_INT : int = 0;
TI_DEX : int = 1;    // dex 精确小数（数值迁移 Task 3：TI_FLOAT 更名，编号不变——.ccr 兼容）
TI_BOOL : int = 2;
TI_STR : int = 3;
TI_UNIT : int = 4;
TI_NEVER : int = 5;
TI_CHAR : int = 6;
TI_DYN : int = 7;    // dynamic type
// TI_DEX_S = 8：dex 定点精确形式（缩放整数）的 IR 变量类型（数值迁移 Task 4）。
// 终审 M1 修复：8 现在是类型表的占位表项下标（init_types 末尾 alloc_type(TYP_BASE,
// TY_DEX_S, 0) 占位）——用户类型从 9 起，TI_DEX_S 哨兵永不再与真实类型碰撞。
// TI_DEX_S 仍不查类型表（type_size/type_align/is_ptr_var 处保留显式守卫，见 ir_gen.cr），
// 值永远以 8 字节槽存储。
TI_DEX_S : int = 8;

// Type table entry kinds
TYP_BASE : int = 0;   // data = TY_* constant
TYP_NAMED : int = 1;  // data = name string index
// 表示层概念（2026-09-10 语言面收窄裁决 §1）：`[T; N]` 退役为「内联容量存储」表示提示（语义归处 = product / 序列+长度约束 / F11）——完整注记见本文件 EXPR_ARRAY 常量处，spec 见 docs/superpowers/specs/2026-09-10-language-surface-narrowing-design.md §1
TYP_ARRAY : int = 2;  // data = element type idx, extra = size
TYP_REF : int = 3;    // data = inner type idx, extra = mut flag
TYP_PTR : int = 4;    // data=pointee_type, extra=address_space (0=tracked, 1=external)
TYP_GENERIC_PARAM : int = 7;  // data = name string index (unresolved generic param)
TYP_GENERIC_APPLY : int = 8;  // data = base type idx, extra = arg list start in g_gen_apply_data
// 表示层概念（2026-09-10 语言面收窄裁决 §1）：`[T; N]` 退役为「内联容量存储」表示提示（语义归处 = product / 序列+长度约束 / F11）——完整注记见本文件 EXPR_ARRAY 常量处，spec 见 docs/superpowers/specs/2026-09-10-language-surface-narrowing-design.md §1
TYP_SLICE : int = 9;   // data = element type idx (dynamic-length view into array)
TYP_TUPLE : int = 10;  // data = element_count, extra = elem types start in g_gen_apply_data
TYP_DYN : int = 11;  // data = type set bitmap (0 = single known type)

// Error codes: category * 1000 + number, matching docs/error-codes.md
// Category 0 = unclassified (000-)
// Category 1 = P  (Parser)
// Category 2 = N  (Name resolution)
// Category 3 = I  (Type inference)
// Category 4 = TA (Type: assignment)
// Category 5 = TF (Type: function)
// Category 6 = TB (Type: binary op)
// Category 7 = TU (Type: unary)
// Category 8 = TC (Type: control flow)
// Category 9 = TM (Type: match)
// Category 10= TK (Type: array/slice)
// Category 11= TS (Type: struct)
// Category 12= TG (Type: generic)
// Category 13= B  (Borrow)
// Category 14= R  (Runtime)
// Category 15= E  (I/O)
// Category 16= ICE (Internal compiler error)

// P0xx — Syntax (Parser)
EC_P_EXPECTED  : int = 1001;  // P001  Expected X, got Y
EC_P_TOPLEVEL  : int = 1002;  // P002  Unexpected token at top level
EC_P_EXPR      : int = 1003;  // P003  Unexpected token in expression
EC_P_ARR_SIZE  : int = 1004;  // P004  Array size not constant
EC_P_PATTERN   : int = 1005;  // P005  Unexpected token in pattern
EC_P_BRACKET   : int = 1006;  // P006  Missing closing delimiter
EC_P_SEMI      : int = 1007;  // P007  Expected semicolon
EC_P_STRUCT_EMPTY : int = 1008; // P008  Empty struct body
EC_P_ENUM_EMPTY   : int = 1009; // P009  Empty enum body
EC_P_FN_EMPTY     : int = 1010; // P010  Empty function body
EC_P_PARAM_TYPE   : int = 1011; // P011  Parameter needs type annotation
EC_P_GENERIC_LIST : int = 1012; // P012  Invalid generic param list
EC_P_FIELD_SYNTAX : int = 1013; // P013  Invalid field syntax
EC_P_MATCH_EMPTY  : int = 1014; // P014  Match body empty
EC_P_PAT_BIND     : int = 1015; // P015  Invalid pattern binding
EC_P_IMPORT_PATH  : int = 1016; // P016  Invalid import path
EC_P_FILEID       : int = 1017; // P017  Invalid fileid declaration
EC_P_VAR_DECL     : int = 1018; // P018  Invalid var declaration
EC_P_LIT_OVERFLOW : int = 1019; // P019  Numeric literal overflow

// N0xx — Name Resolution
EC_N_UNDEFINED     : int = 2001; // N001  Undefined name
EC_N_STRUCT        : int = 2002; // N002  Undefined struct
EC_N_FIELD         : int = 2003; // N003  Undefined field
EC_N_ENUM_CON      : int = 2004; // N004  Undefined enum constructor
EC_N_ENUM_VAR      : int = 2005; // N005  Undefined enum variant
EC_N_FUNC          : int = 2006; // N006  Undefined function
EC_N_TYPE          : int = 2007; // N007  Undefined type
EC_N_METHOD        : int = 2008; // N008  Undefined method
EC_N_GENERIC_TYPE  : int = 2009; // N009  Undefined type in generic apply
EC_N_GENERIC_PARAM : int = 2010; // N010  Undefined generic param
EC_N_DUPLICATE     : int = 2011; // N011  Duplicate definition
EC_N_DUP_FIELD     : int = 2012; // N012  Duplicate field
EC_N_DUP_VARIANT   : int = 2013; // N013  Duplicate variant
EC_N_DUP_FUNC      : int = 2014; // N014  Duplicate function
EC_N_FILEID_CONFLICT : int = 2015; // N015  Fileid conflict
EC_N_MODULE        : int = 2016; // N016  Undefined module
EC_N_PROJECT       : int = 2017; // N017  Undefined project
EC_N_CYCLE         : int = 2018; // N018  Cyclic import
EC_N_IMPORT_FILE   : int = 2019; // N019  Import file not found
EC_N_IMPORT_READ   : int = 2020; // N020  Import read failure
EC_N_REEXPORT      : int = 2021; // N021  Re-export conflict

// I0xx — Type Inference
EC_I_INFER      : int = 3001; // I001  Cannot infer type
EC_I_INFER_GLOBAL : int = 3002; // I002  Cannot infer global type
EC_I_INFER_RET   : int = 3003; // I003  Cannot infer return type
EC_I_INFER_GENERIC : int = 3004; // I004  Cannot infer generic param
EC_I_AMBIGUOUS   : int = 3005; // I005  Ambiguous type
EC_I_INFINITE    : int = 3006; // I006  Infinite type

// TA0xx — Type: Assignment
EC_TA_ASSIGN     : int = 4001; // TA01  Cannot assign T2 to T1
EC_TA_DECL       : int = 4002; // TA02  Declared vs init type mismatch
EC_TA_BATCH      : int = 4003; // TA03  Batch declaration mixed types
EC_TA_IMMUTABLE  : int = 4004; // TA04  Assign to immutable
EC_TA_NOT_MUT    : int = 4005; // TA05  Variable not mutable
EC_TA_GLOBAL_MUT : int = 4006; // TA06  Global not mutable
EC_TA_TUPLE_ARITY : int = 4007; // TA07  Tuple destructuring arity
EC_TA_UNKNOWN_TAG : int = 4008; // TA08  Unknown declaration tag

// TF0xx — Type: Function
EC_TF_RETURN     : int = 5001; // TF01  Return type mismatch
EC_TF_MISSING_RET : int = 5002; // TF02  Missing return
EC_TF_EXTRA_RET  : int = 5003; // TF03  Extra return in unit fn
EC_TF_BRANCH_RET : int = 5004; // TF04  Branch return mismatch
EC_TF_ARG_COUNT  : int = 5005; // TF05  Arg count mismatch
EC_TF_ARG_TOO_MANY : int = 5006; // TF06  Too many args
EC_TF_ARG_TYPE   : int = 5007; // TF07  Arg type mismatch
EC_TF_METHOD_NOT_FOUND : int = 5008; // TF08  Method not found
EC_TF_METHOD_ARG_CNT : int = 5009; // TF09  Method arg count mismatch
EC_TF_METHOD_ARG_TYP : int = 5010; // TF10  Method arg type mismatch
EC_TF_NON_STRUCT  : int = 5011; // TF11  Method call on non-struct
EC_TF_NO_MAIN     : int = 5012; // TF12  No main function
EC_TF_MAIN_SIG    : int = 5013; // TF13  Main signature wrong
EC_TF_SELF_PARAM  : int = 5014; // TF14  Invalid self param
EC_TF_SELF_REQUIRED : int = 5015; // TF15  Method needs self
EC_TF_CALL_NOT_FOUND : int = 5016; // TF16  Function not in scope
EC_TF_AMBIGUOUS   : int = 5017; // TF17  Ambiguous function call

// TB0xx — Type: Binary ops
EC_TB_ADD  : int = 6001; // TB01  Cannot add
EC_TB_SUB  : int = 6002; // TB02  Cannot sub
EC_TB_MUL  : int = 6003; // TB03  Cannot mul
EC_TB_DIV  : int = 6004; // TB04  Cannot div
EC_TB_MOD  : int = 6005; // TB05  Cannot mod
EC_TB_CMP  : int = 6006; // TB06  Cannot compare ==/!=
EC_TB_ORDER : int = 6007; // TB07  Cannot order </>/<=/>=
EC_TB_AND_OR : int = 6008; // TB08  &&/|| need bool
EC_TB_STR_CONCAT : int = 6009; // TB09  String + non-string

// TU0xx — Type: Unary ops
EC_TU_NEG : int = 7001; // TU01  Cannot negate
EC_TU_NOT : int = 7002; // TU02  ! requires bool
EC_TU_DEREF : int = 7003; // TU03  Cannot deref non-ref

// TC0xx — Type: Control flow
EC_TC_IF_COND : int = 8001; // TC01  If condition must be bool
EC_TC_IF_BRANCH : int = 8002; // TC02  If branches have different types
EC_TC_IF_NO_ELSE : int = 8003; // TC03  If without else returns unit
EC_TC_WHILE_COND : int = 8004; // TC04  While condition must be bool
EC_TC_BREAK_VAL : int = 8005; // TC05  Break value mismatch
EC_TC_BREAK_OUT : int = 8006; // TC06  Break outside loop
EC_TC_CONT_OUT  : int = 8007; // TC07  Continue outside loop

// TM0xx — Type: Match
EC_TM_ENUM     : int = 9001; // TM01  Match must be enum
EC_TM_ARM_TYPE : int = 9002; // TM02  Arm type mismatch
EC_TM_EXHAUST  : int = 9003; // TM03  Non-exhaustive
EC_TM_REDUNDANT : int = 9004; // TM04  Redundant arm
EC_TM_WILDCARD_ORDER : int = 9005; // TM05  Wildcard not last
EC_TM_ARG_CNT  : int = 9006; // TM06  Constructor arg count
EC_TM_ARG_TYPE : int = 9007; // TM07  Constructor arg type
EC_TM_BIND_DUP : int = 9008; // TM08  Pattern binding dup
EC_TM_NESTED   : int = 9009; // TM09  Nested pattern not allowed

// TK0xx — Type: Array/Slice
EC_TK_INDEX     : int = 10001; // TK01  Cannot index
EC_TK_ELEM_TYPE : int = 10002; // TK02  Element type mismatch
EC_TK_SIZE_TYPE : int = 10003; // TK03  Size must be int
EC_TK_SIZE_NEG  : int = 10004; // TK04  Size must be positive
EC_TK_SLICE_BOUNDS : int = 10005; // TK05  Slice out of bounds
EC_TK_SLICE_LEN : int = 10006; // TK06  Slice length negative
EC_TK_FOR_ITER  : int = 10007; // TK07  Cannot iterate
EC_TK_FOR_TYPE  : int = 10008; // TK08  For var type mismatch

// TS0xx — Type: Struct literal
EC_TS_MISSING_FIELD : int = 11001; // TS01  Missing field
EC_TS_UNKNOWN_FIELD : int = 11002; // TS02  Unknown field
EC_TS_FIELD_TYPE    : int = 11003; // TS03  Field type mismatch
EC_TS_FIELD_DUP     : int = 11004; // TS04  Field init twice

// TG0xx — Type: Generic
EC_TG_ARG_COUNT  : int = 12001; // TG01  Generic arg count mismatch
EC_TG_BOUND      : int = 12002; // TG02  Generic bound unsatisfied

// B0xx — Borrow
EC_B_BORROW_MUT     : int = 13001; // B001  Mutable borrow on already-borrowed
EC_B_BORROW_IMMUT   : int = 13002; // B002  Immutable borrow on mutable-borrowed
EC_B_BORROW_MUT2    : int = 13003; // B003  Two mutable borrows
EC_B_USE_WHILE_BORROWED : int = 13004; // B004  Use while borrowed
EC_B_ESCAPE         : int = 13010; // B010  Reference escapes function
EC_B_LIFETIME       : int = 13011; // B011  Lifetime too short
EC_B_MOVE_USE       : int = 13020; // B020  Use of moved value
EC_B_MOVE_AGAIN     : int = 13021; // B021  Move of already-moved
EC_B_MOVE_BORROWED  : int = 13022; // B022  Move while borrowed

// R0xx — Runtime
EC_R_DIV_ZERO     : int = 14001; // R001  Division by zero
EC_R_OOB          : int = 14002; // R002  Index out of bounds
EC_R_OVERFLOW     : int = 14003; // R003  Integer overflow
EC_R_LOSSY_CONVERT : int = 14004; // R004  Lossy conversion

// E0xx — I/O
EC_E_READ_FILE    : int = 15001; // E001  Cannot read source
EC_E_WRITE_FILE   : int = 15002; // E002  Cannot write output
EC_E_CCR_CORRUPT  : int = 15003; // E003  CCR file corrupt
EC_E_CCR_OPEN     : int = 15004; // E004  Cannot open CCR

// ICE — Internal
EC_ICE_UNEXPECTED : int = 16001; // ICE01  Unexpected
EC_ICE_OVERFLOW   : int = 16002; // ICE02  Buffer overflow
EC_ICE_UNSUPPORTED : int = 16003; // ICE03  Unsupported

// Diagnostic entry
struct Diag {
    code: int,
    msg: string,
    line: int,
    col: int,
}

// Symbol kinds for checker
SYM_FN : int = 0;
SYM_TYPE : int = 1;
SYM_LOCAL : int = 2;
SYM_PARAM : int = 3;
SYM_GLOBAL : int = 4;
SYM_MODULE : int = 5;
SYM_SO_FN : int = 6;

// Parameter/function tag flags (stored in sym_type for SYM_SO_FN)
TAG_VARIADIC : int = 1;
TAG_AUTO_STR  : int = 2;

g_gen_apply_data : string, mut;         g_gen_apply_data_count : int, mut; g_gen_apply_data_cap : int, mut;

// Module system globals
g_seg_starts : string, mut;             g_seg_fileids : string, mut;        g_seg_count : int, mut; g_seg_cap : int, mut;
g_line_fileid : string, mut;            g_line_count : int, mut;    g_line_cap : int, mut;
g_source_dir : string, mut;  // directory of the main source file (for _import.core lookup)

// IR instruction opcodes
IR_NOP : int = 0;
IR_CONST : int = 1;
IR_BINARY : int = 2;
IR_UNARY : int = 3;
IR_CALL : int = 4;
IR_RETURN : int = 5;
IR_ALLOC : int = 6;
IR_ALLOC_STRUCT : int = 7;
IR_ALLOC_ARRAY : int = 8;
IR_STORE : int = 9;
IR_LOAD : int = 10;
IR_LOAD_FIELD : int = 11;
IR_STORE_FIELD : int = 12;
IR_LOAD_INDEX : int = 13;
IR_STORE_INDEX : int = 14;
IR_LOAD_INDEX_VAR : int = 15;
IR_STORE_INDEX_VAR : int = 16;
IR_MAKE_ENUM : int = 17;
IR_REF : int = 18;
IR_BRANCH : int = 19;
IR_JUMP : int = 20;
IR_LABEL : int = 21;
IR_PHI : int = 22;
IR_LOAD_ENUM_TAG : int = 23;
IR_SLICE : int = 24;   // dest=slice_var, s1=arr_var, s2=low_var, src3=high_var — create slice ptr from range
IR_DEREF : int = 25;   // dest=loaded_val, s1=ptr, s2=runtime_base, s3=alloc_size, type_kind=width
IR_STORE_PTR : int = 26; // dest=runtime_base, s1=ptr, s2=value, s3=alloc_size, type_kind=width
IR_ADDR_INDEX : int = 31; // dest=addr, s1=arr_var, s2=index_var, s3=scale — compute &arr[index] without loading
IR_SPAWN : int = 27;     // dest=result_var, s1=first_arg, s2=arg_count, s3=fn_name_ni, type_kind=spawn_count (-1=dynamic)
IR_YIELD : int = 28;     // s1=value_var — emit value from flow to consumer channel
IR_AWAIT : int = 29;     // dest=value_var, s1=future_var — block until future ready, get value
IR_BOUNDS_CHECK : int = 30; // s1=index, s2=max_len/len_var, type_kind=1 for dynamic max
IR_ARENA_NEW   : int = 32;   // dest=arena_var, src1=size_estimate
IR_ARENA_RESET : int = 33;   // src1=arena_id (dest=-1)
IR_INLINE            : int = 34;   // src1=fn_var — inline hint
IR_NO_BOUNDS_CHECK   : int = 35;   // — skip bounds check for subsequent DEREFs
IR_FAST              : int = 36;   // — allow precision-for-speed optimizations
IR_UNROLL            : int = 37;   // src1=unroll_count — loop unroll hint
IR_SECTION           : int = 38;   // src1=section_name_ni — code section hint
IR_HOTPATCH_ROUTE    : int = 39;   // dest=result_var, s1=fn_name_ni, s2=first_arg, s3=arg_count
IR_DYN_TAG      : int = 41;  // dest=tag_var, s1=dyn_var — extract tag
IR_DYN_VAL      : int = 42;  // dest=val_var, s1=dyn_var — extract value
IR_DYN_PACK     : int = 43;  // dest=dyn_var, s1=val_var, s2=type_idx — pack dyn
IR_DYN_DISPATCH : int = 44;  // s1=dyn_var, s2=dispatch_table_ni — dispatch by tag
IR_CALL_EXTERN : int = 45;  // dest=result_var, s1=func_name_ni, s2=first_arg, s3=arg_count
IR_LAZY_THUNK  : int = 46;  // dest=thunk_var, s1=expr_var — wrap as lazy thunk
IR_LAZY_FORCE  : int = 47;  // dest=val_var, s1=thunk_var — force evaluation
IR_FNADDR : int = 48;  // dest=addr_var, s1=fn_name_ni — load function address (movabs + link-time patch)
IR_I2F : int = 49;  // dest=dex_var(bits), s1=int_var — int → binary64（cvtsi2sd，apx 快路径）
IR_F2I : int = 50;  // dest=int_var, s1=dex_var(bits) — binary64 → int（cvttsd2si 截断，apx 快路径）
IR_APPROX : int = 51;  // — 无操作数注解：apx 变量声明处（语义许可，后端可忽略，interp 跳过）

// Resolution flag for BRANCH/JUMP (stored in type_kind field after label resolution)
IR_RESOLVED : int = 1;

// IR variable
struct IRVar {
    name: string,
    id: int,
    type_kind: int,
}

// IR instruction (flat representation)
struct IRInstr {
    opcode: int,
    dest: int,      // destination var index
    src1: int,      // source var/val 1
    src2: int,      // source var/val 2
    src3: int,      // extra data (label, field name, etc.)
    type_kind: int, // type info
}

// === Dataflow Graph (.cir) structures ===

struct DFNode {
    opcode: int,
    dest_var: int,   // IR var this node defines (-1 if none)
    src1: int,       // original operands (same semantics as IRInstr)
    src2: int,
    src3: int,
    type_kind: int,
    first_edge: int, // index of first outgoing edge into g_df_edges (-1 = none)
    edge_count: int, // number of outgoing edges
}

struct DFEdge {
    from_node: int,
    to_node: int,
    next_out: int,   // next edge from same source (-1 = none)
    kind: int,       // 0=data (def-use), 1=state (ordering/termination)
}

// Dataflow graph arrays
g_df_nodes : string, mut;               g_df_node_count : int, mut;     g_df_node_cap : int, mut;
g_df_edges : string, mut;               g_df_edge_count : int, mut;     g_df_edge_cap : int, mut;
g_df_var_producer : string, mut;        g_df_func_node_start : string, mut;  g_df_func_node_count : string, mut;
g_df_cap : int, mut;

// Usage count: how many consumers each IR variable has
g_var_use_count : string, mut;          g_var_use_count_cap : int, mut;


// ── Optimization metadata keys (.ccr v3+ extensible section) ──
OPT_KEY_REG_ASSIGN  : int = 0;  // [var_idx:u32, reg_num:u8]...
OPT_META_STRIDE     : int = 64; // header (8) + up to 5 register pairs
OPT_KEY_STACK_SHARE : int = 1;  // [var_idx:u32, mapped_to:u32]...
OPT_KEY_CSE         : int = 2;  // [op:u32, s1:u32, s2:u32, res:u32]...
