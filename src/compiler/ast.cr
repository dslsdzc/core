// === ast.core ===
// Core compiler - shared type definitions and constants

// Token kind constants
T_EOF : int = 0;
T_IDENT : int = 1;
T_INT : int = 2;
T_FLOAT : int = 3;
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
T_TYPE : int = 59;
T_MOD : int = 60;
T_IMPORT : int = 61;
T_AS : int = 62;
T_GO : int = 63;
T_AWAIT : int = 64;
T_UNSAFE : int = 65;
T_INTERFACE : int = 66;
T_COLON_EQ : int = 67;
T_AUTO : int = 68;
T_AT : int = 69;
T_FILEID : int = 70;
T_QUESTION : int = 71;
T_PLUS_EQ : int = 72;
T_MINUS_EQ : int = 73;
T_STAR_EQ : int = 74;
T_SLASH_EQ : int = 75;

// Suffixed integer/float token kinds (lexer emits these when suffix like _i32, _u64, _f32 is found)
T_INT_I8 : int = 76;
T_INT_I16 : int = 77;
T_INT_I32 : int = 78;
T_INT_I64 : int = 79;
T_INT_U8 : int = 80;
T_INT_U16 : int = 81;
T_INT_U32 : int = 82;
T_INT_U64 : int = 83;
T_FLOAT_F32 : int = 84;
T_FLOAT_F64 : int = 85;

// Width constants (stored in EXPR_INT/EXPR_FLOAT data field)
W_I8 : int = 1;
W_I16 : int = 2;
W_I32 : int = 3;
W_I64 : int = 4;
W_U8 : int = 5;
W_U16 : int = 6;
W_U32 : int = 7;
W_U64 : int = 8;
W_F32 : int = 9;
W_F64 : int = 10;

// Type constants
TY_INT : int = 0;
TY_FLOAT : int = 1;
TY_BOOL : int = 2;
TY_STRING : int = 3;
TY_UNIT : int = 4;
TY_NEVER : int = 5;
TY_CHAR : int = 6;
TY_GENERIC_PARAM : int = 7;  // special sentinel for generic type params

// Storage limits
MAX_FUNCS : int = 128;
MAX_STRUCTS : int = 64;
MAX_ENUMS : int = 32;
MAX_VARIANTS : int = 16;
MAX_FIELDS : int = 16;
MAX_PARAMS : int = 16;
MAX_LOOPS : int = 16;

// Compiler buffer sizes
MAX_TOKENS : int = 8192;
MAX_AST : int = 16384;
MAX_STRS : int = 2048;
MAX_ERRS : int = 128;
MAX_ASM : int = 8192;
MAX_BLOCK_STMTS : int = 16384; // total statements across all blocks

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
    param_types: [int; 16],
    return_type: int,
    ast_node: int,  // index into ast array for the fn body
    generic_names: [string; 4],
    generic_count: int,
}

// Struct layout
struct StructInfo {
    name: string,
    field_names: [string; 16],
    field_types: [int; 16],
    field_type_nodes: [int; 16],  // original type node indices (for generic resolution)
    field_count: int,
    generic_names: [string; 4],
    generic_count: int,
}

// Enum variant description
struct EnumVariant {
    name: string,
    types: [int; 16],  // TY_* for each field
    type_count: int,
}

// Enum layout
struct EnumInfo {
    name: string,
    variants: [EnumVariant; 16],
    variant_count: int,
    generic_names: [string; 4],
    generic_count: int,
}

// Loop context (for break/continue)
struct LoopInfo {
    start_label: string,
    end_label: string,
}

// Block statement index storage: sequential statement indices for each block
// EXPR_BLOCK uses a=start_idx_into_g_block_stmts, b=stmt_count
g_block_stmts : [int; MAX_BLOCK_STMTS];
g_block_stmt_count : int;

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
EXPR_FLOAT : int = 27;   // int_val = value (as scaled int)
EXPR_STRING : int = 2;   // int_val = str table index
EXPR_BOOL : int = 3;     // int_val = 0/1
EXPR_IDENT : int = 4;    // int_val = name str table index
EXPR_BINARY : int = 5;   // a=left, b=right, c=opcode
EXPR_UNARY : int = 6;    // a=operand, c=opcode
EXPR_CALL : int = 7;     // a=func, b=first arg idx, c=arg count
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
EXPR_ARRAY : int = 19;   // a=first elem, b=elem count
EXPR_BREAK : int = 20;
EXPR_CONTINUE : int = 21;
EXPR_FOR : int = 22;     // a=var name idx, b=iter, c=body
EXPR_MATCH : int = 23;   // a=expr, b=first arm, c=arm count
EXPR_ARM : int = 24;     // a=pattern, b=body
EXPR_WILDCARD : int = 25;
EXPR_ENUMPAT : int = 26; // a=name idx, b=first subpat, c=subpat count
EXPR_STMT : int = 28;   // a=inner expr; expression used as statement (with ;), returns unit
EXPR_CHAR : int = 29;   // int_val = codepoint
EXPR_WHILE : int = 30;  // a=cond, b=body
EXPR_RANGE : int = 31;  // a=start, b=end
EXPR_MOVE : int = 32;     // a=expr being moved
EXPR_ENUM_CONSTRUCTOR : int = 37; // a=name idx, b=first arg, c=arg count
EXPR_REFTYPE : int = 38;   // a=inner type node, data=mut flag (for &T / &mut T in type position)
EXPR_GENERIC_APPLY : int = 39; // a=base name idx, b=first arg type node, c=arg count

// Desugared constructs
EXPR_TRY : int = 33;      // a=expr being tried (? operator)
EXPR_UNSAFE : int = 34;   // a=block body
EXPR_STRUCTPAT : int = 35; // struct pattern: a=name ni, b=first field pat, c=field count
EXPR_AS : int = 36;        // a=expr, b=type node (cast: expr as Type)

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

// Unary operator codes
UOP_NEG : int = 1;
UOP_NOT : int = 2;
UOP_REF : int = 3;
UOP_DEREF : int = 4;

// Type table pre-allocated indices (for checker type system)
TI_INT : int = 0;
TI_FLOAT : int = 1;
TI_BOOL : int = 2;
TI_STR : int = 3;
TI_UNIT : int = 4;
TI_NEVER : int = 5;
TI_CHAR : int = 6;

// Type table entry kinds
TYP_BASE : int = 0;   // data = TY_* constant
TYP_NAMED : int = 1;  // data = name string index
TYP_ARRAY : int = 2;  // data = element type idx, extra = size
TYP_REF : int = 3;    // data = inner type idx, extra = mut flag
TYP_GENERIC_PARAM : int = 7;  // data = name string index (unresolved generic param)
TYP_GENERIC_APPLY : int = 8;  // data = base type idx, extra = arg list start in g_gen_apply_data
TYP_SLICE : int = 9;   // data = element type idx (dynamic-length view into array)

// Symbol kinds for checker
SYM_FN : int = 0;
SYM_TYPE : int = 1;
SYM_LOCAL : int = 2;
SYM_PARAM : int = 3;
SYM_GLOBAL : int = 4;
SYM_MODULE : int = 5;

// Module system structures
struct FileEntry {
    fileid_ni: int,
    path: string,
}
struct ModEntry {
    alias_ni: int,    // name index of alias (e.g., "m" from "import math : m")
    fileid_ni: int,   // name index of actual fileid
    path: string,     // resolved file path
}
// Additional size limits
MAX_SYMS : int = 512;
MAX_TYPES : int = 128;
MAX_SCOPES : int = 32;
MAX_FILES : int = 64;
MAX_MODS : int = 32;
MAX_SEGS : int = 64;
MAX_LINES : int = 5000;
MAX_IREXPRS : int = 4096;
MAX_IRINSTRUCTIONS : int = 16384;
MAX_BLOCKS : int = 512;
MAX_LABELS : int = 512;
MAX_GENERICS : int = 4;        // max generic params per declaration
MAX_GEN_ARGS : int = 128;      // total storage for generic type args
g_gen_apply_data : [int; MAX_GEN_ARGS];  // flat: [count, arg1, arg2, ...] for each GENERIC_APPLY
g_gen_apply_data_count : int;

// Module system globals
g_files : [FileEntry; MAX_FILES], mut;
g_file_count : int, mut;
g_mods : [ModEntry; MAX_MODS], mut;
g_mod_count : int, mut;
g_seg_starts : [int; MAX_SEGS], mut;    // parallel arrays replacing SegBoundary struct
g_seg_fileids : [int; MAX_SEGS], mut;   // (struct arrays don't work in interpreter)
g_seg_count : int, mut;
g_line_fileid : [int; MAX_LINES], mut;  // maps source line -> fileid_ni (0 = main)
g_line_count : int, mut;
g_source_dir : string, mut;  // directory of the main source file (for _import.core lookup)
MAX_MOD_FUNCS : int = 128;
g_mod_func_fileids : [int; MAX_MOD_FUNCS], mut;   // fileid name index
g_mod_func_names : [int; MAX_MOD_FUNCS], mut;     // function name index
g_mod_func_tis : [int; MAX_MOD_FUNCS], mut;       // type index
g_mod_func_count : int, mut;

// Mod path declarations (mod foo::bar;)
MAX_MOD_PATHS : int = 32;
g_mod_path_names : [int; MAX_MOD_PATHS], mut;  // name indices
g_mod_path_count : int, mut;

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
IR_DEREF : int = 25;   // dest=loaded_val, s1=ref_var — load value through pointer stored in ref_var
IR_STORE_PTR : int = 26; // dest=val_var, s1=ptr_var, s2=val_var — store value through pointer

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
}

// Max limits (literal values: bootstrap compiler doesn't constant-fold)
MAX_DF_NODES : int = 16384;    // == MAX_IRINSTRUCTIONS
MAX_DF_EDGES : int = 65536;    // == MAX_IRINSTRUCTIONS * 4

// Dataflow graph arrays
g_df_nodes : [DFNode; MAX_DF_NODES], mut;
g_df_node_count : int, mut;
g_df_edges : [DFEdge; MAX_DF_EDGES], mut;
g_df_edge_count : int, mut;
g_df_var_producer : [int; MAX_IREXPRS], mut;  // var_idx → node_id that produces it
// Per-function metadata for lowering
g_df_func_node_start : [int; MAX_FUNCS], mut;  // first node idx for each function
g_df_func_node_count : [int; MAX_FUNCS], mut;  // node count per function
