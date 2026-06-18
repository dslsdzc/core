// === backend/x86_64.core ===
// x86-64 assembly generation from flat IR (GAS .intel_syntax noprefix)

// Stack frame management per function
// g_x86 arrays declared in globals.cr

fn x86_init_frame() {
    g_x86_var_count = 0;
    g_x86_stack_size = 0;
    g_x86_func_idx = 0;
    g_x86_is_enum_count = 0;
}

fn x86_mark_enum(var_idx: int) {
    i : ., mut = 0;
    loop {
        if i >= g_x86_is_enum_count { break; }
        if r64(g_x86_vars, i * 8) == var_idx { return; }
        i = i + 1;
    }
    dyn_grow_x86_is_enum(g_x86_is_enum_count + 1);
    w64(g_x86_is_enum, g_x86_is_enum_count * 8, var_idx);
    g_x86_is_enum_count = g_x86_is_enum_count + 1;
}

fn x86_is_enum_var(var_idx: int) -> int {
    i : ., mut = 0;
    loop {
        if i >= g_x86_is_enum_count { break; }
        if r64(g_x86_is_enum, i * 8) == var_idx { return 1; }
        i = i + 1;
    }
    return 0;
}

fn x86_alloc_stack(var_idx: int) -> int {
    i : ., mut = 0;
    loop {
        if i >= g_x86_var_count { break; }
        if r64(g_x86_vars, i * 8) == var_idx {
            return -(i + 1) * 8;
        }
        i = i + 1;
    }
    dyn_grow_x86_vars(g_x86_var_count + 1);
    w64(g_x86_vars, g_x86_var_count * 8, var_idx);
    g_x86_var_count = g_x86_var_count + 1;
    g_x86_stack_size = g_x86_var_count * 8;
    return -(g_x86_var_count) * 8;
}

fn x86_get_offset(var_idx: int) -> int {
    i : ., mut = 0;
    loop {
        if i >= g_x86_var_count { break; }
        if r64(g_x86_vars, i * 8) == var_idx {
            return -(i + 1) * 8;
        }
        i = i + 1;
    }
    return x86_alloc_stack(var_idx);
}

fn x86_lookup_struct(name_ni: int) -> int {
    si : ., mut = 0;
    loop {
        if si >= g_struct_count { break; }
        if si_name(si) == name_ni { return si; }
        si = si + 1;
    }
    return -1;
}

fn x86_label(lbl: int) -> string {
    s : ., mut = ".L";
    s = s + int_str(lbl);
    s = s + ":";
    return s;
}

fn x86_jump_label(lbl: int) -> string {
    s : ., mut = ".L";
    s = s + int_str(lbl);
    return s;
}

fn x86_gen_instr(instr_idx: int) -> string {
    op := iri_op(instr_idx);
    dest := iri_dest(instr_idx);
    s1 := iri_s1(instr_idx);
    s2 := iri_s2(instr_idx);
    s3 := iri_s3(instr_idx);
    asm : ., mut = "";

    if op == IR_NOP { return asm; }

    if op == IR_CONST {
        off := x86_get_offset(dest);
        val := s1;
        ti := iri_tk(instr_idx);
        if ti == TI_STR {
            //  str_idx (val)  g_ir_str_consts 
            lbl_idx : ., mut = 0;
            si2 : ., mut = 0;
            loop {
                if si2 >= g_ir_str_const_count { break; }
                if g_ir_str_consts[si2] == val { lbl_idx = si2; break; }
                si2 = si2 + 1;
            }
            lbl : ., mut = ".LC";
            lbl = lbl + int_str(lbl_idx);
            asm = asm + "    lea r10, ";
            asm = asm + lbl;
            asm = asm + "[rip]\n";
            asm = asm + "    mov [rbp";
            if off >= 0 { asm = asm + "+"; }
            asm = asm + int_str(off);
            asm = asm + "], r10\n";
        } else {
            asm = asm + "    mov qword ptr [rbp";
            if off >= 0 { asm = asm + "+"; }
            asm = asm + int_str(off);
            asm = asm + "], ";
            asm = asm + int_str(val);
            asm = asm + "\n";
        }
        return asm;
    }

    if op == IR_BINARY {
        off_s1 := x86_get_offset(s1);
        off_s2 := x86_get_offset(s2);
        off_d := x86_get_offset(dest);
        asm = asm + "    mov r10, [rbp";
        if off_s1 >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off_s1);
        asm = asm + "]\n";
        asm = asm + "    mov r11, [rbp";
        if off_s2 >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off_s2);
        asm = asm + "]\n";
        if s3 == OP_ADD { asm = asm + "    add r10, r11\n"; }
        if s3 == OP_SUB { asm = asm + "    sub r10, r11\n"; }
        if s3 == OP_MUL { asm = asm + "    imul r10, r11\n"; }
        if s3 == OP_DIV {
            asm = asm + "    mov rax, r10\n";
            asm = asm + "    cqo\n";
            asm = asm + "    idiv r11\n";
            asm = asm + "    mov r10, rax\n";
        }
        if s3 == OP_MOD {
            asm = asm + "    mov rax, r10\n";
            asm = asm + "    cqo\n";
            asm = asm + "    idiv r11\n";
            asm = asm + "    mov r10, rdx\n";
        }
        if s3 == OP_EQ {
            asm = asm + "    cmp r10, r11\n";
            asm = asm + "    sete al\n    movzx r10, al\n";
        }
        if s3 == OP_NE {
            asm = asm + "    cmp r10, r11\n";
            asm = asm + "    setne al\n    movzx r10, al\n";
        }
        if s3 == OP_LT {
            asm = asm + "    cmp r10, r11\n";
            asm = asm + "    setl al\n    movzx r10, al\n";
        }
        if s3 == OP_GT {
            asm = asm + "    cmp r10, r11\n";
            asm = asm + "    setg al\n    movzx r10, al\n";
        }
        if s3 == OP_LE {
            asm = asm + "    cmp r10, r11\n";
            asm = asm + "    setle al\n    movzx r10, al\n";
        }
        if s3 == OP_GE {
            asm = asm + "    cmp r10, r11\n";
            asm = asm + "    setge al\n    movzx r10, al\n";
        }
        if s3 == OP_AND { asm = asm + "    and r10, r11\n"; }
        if s3 == OP_OR { asm = asm + "    or r10, r11\n"; }
        asm = asm + "    mov [rbp";
        if off_d >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off_d);
        asm = asm + "], r10\n";
        return asm;
    }

    if op == IR_UNARY {
        off_s1 := x86_get_offset(s1);
        off_d := x86_get_offset(dest);
        asm = asm + "    mov r10, [rbp";
        if off_s1 >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off_s1);
        asm = asm + "]\n";
        if s3 == UOP_NEG { asm = asm + "    neg r10\n"; }
        else if s3 == UOP_NOT {
            asm = asm + "    cmp r10, 0\n";
            asm = asm + "    sete al\n    movzx r10, al\n";
        }
        asm = asm + "    mov [rbp";
        if off_d >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off_d);
        asm = asm + "], r10\n";
        return asm;
    }

    if op == IR_CALL {
        func_ni := s3;
        func_name := "";
        if func_ni >= 0 { func_name = istr_get(func_ni); }
        first_arg := s1;
        arg_count := s2;
        arg_regs := ["rdi", "rsi", "rdx", "rcx", "r8", "r9"];
        ai : ., mut = 0;
        loop {
            if ai >= arg_count { break; }
            if ai >= 6 { break; }
            arg_var := first_arg + ai;
            aoff := x86_get_offset(arg_var);
            asm = asm + "    mov ";
            asm = asm + arg_regs[ai];
            asm = asm + ", [rbp";
            if aoff >= 0 { asm = asm + "+"; }
            asm = asm + int_str(aoff);
            asm = asm + "]\n";
            ai = ai + 1;
        }
        if func_name == "syscall3" {
            //  syscall rdi=nr, rsi=a1, rdx=a2, rcx=a3
            // rax=nr, rdi=a1, rsi=a2, rdx=a3, r10=0
            asm = asm + "    mov rax, rdi\n";
            asm = asm + "    mov rdi, rsi\n";
            asm = asm + "    mov rsi, rdx\n";
            asm = asm + "    mov rdx, rcx\n";
            asm = asm + "    xor r10, r10\n";
            asm = asm + "    syscall\n";
        } else if str_eq(func_name, "load8") != 0 ||
                  str_eq(func_name, "store8") != 0 {
            // load8/store8  IR_STORE/IR_LOAD 
            asm = asm + "    xor eax, eax\n";
        } else if str_len(func_name) > 0 {
            //  __builtin_*   callrt_core.o
            asm = asm + "    call ";
            asm = asm + func_name;
            asm = asm + "\n";
        }
        if dest >= 0 {
            doff := x86_get_offset(dest);
            asm = asm + "    mov [rbp";
            if doff >= 0 { asm = asm + "+"; }
            asm = asm + int_str(doff);
            asm = asm + "], rax\n";
        }
        return asm;
    }

    if op == IR_RETURN {
        if s1 >= 0 {
            off := x86_get_offset(s1);
            asm = asm + "    mov rax, [rbp";
            if off >= 0 { asm = asm + "+"; }
            asm = asm + int_str(off);
            asm = asm + "]\n";
        }
        asm = asm + "    jmp .Lret";
        asm = asm + int_str(g_x86_func_idx);
        asm = asm + "\n";
        return asm;
    }

    if op == IR_ALLOC {
        x86_get_offset(dest);
        return asm;
    }

    if op == IR_ALLOC_STRUCT {
        off := x86_get_offset(dest);
        name_ni := s3;
        if name_ni >= 0 {
            si := x86_lookup_struct(name_ni);
            if si >= 0 {
                fc := si_field_count(si);
                if fc > 0 {
                    asm = asm + "    mov edi, ";
                    asm = asm + int_str(fc * 8);
                    asm = asm + "\n    call alloc\n";
                    asm = asm + "    mov [rbp";
                    if off >= 0 { asm = asm + "+"; }
                    asm = asm + int_str(off);
                    asm = asm + "], rax\n";
                }
            }
        }
        return asm;
    }

    if op == IR_ALLOC_ARRAY {
        off := x86_get_offset(dest);
        sz := s1 * 8;
        if sz > 0 {
            asm = asm + "    mov edi, ";
            asm = asm + int_str(sz);
            asm = asm + "\n    call alloc\n";
            asm = asm + "    mov [rbp";
            if off >= 0 { asm = asm + "+"; }
            asm = asm + int_str(off);
            asm = asm + "], rax\n";
        }
        return asm;
    }

    if op == IR_STORE {
        off_addr := x86_get_offset(s1);
        off_val := x86_get_offset(s2);
        asm = asm + "    mov r10, [rbp";
        if off_val >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off_val);
        asm = asm + "]\n";
        asm = asm + "    mov [rbp";
        if off_addr >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off_addr);
        asm = asm + "], r10\n";
        return asm;
    }

    if op == IR_LOAD {
        off_src := x86_get_offset(s1);
        off_d := x86_get_offset(dest);
        asm = asm + "    mov r10, [rbp";
        if off_src >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off_src);
        asm = asm + "]\n";
        asm = asm + "    mov [rbp";
        if off_d >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off_d);
        asm = asm + "], r10\n";
        return asm;
    }

    if op == IR_LOAD_FIELD {
        off_struct := x86_get_offset(s1);
        off_d := x86_get_offset(dest);
        field_idx := s3;
        field_off : ., mut = field_idx * 8;
        if x86_is_enum_var(s1) == 1 { field_off = (field_idx + 1) * 8; }
        asm = asm + "    mov r10, [rbp";
        if off_struct >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off_struct);
        asm = asm + "]\n";
        asm = asm + "    mov r11, [r10 + ";
        asm = asm + int_str(field_off);
        asm = asm + "]\n";
        asm = asm + "    mov [rbp";
        if off_d >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off_d);
        asm = asm + "], r11\n";
        return asm;
    }

    if op == IR_STORE_FIELD {
        off_struct := x86_get_offset(s1);
        off_val := x86_get_offset(s2);
        field_idx := s3;
        field_off : ., mut = field_idx * 8;
        if x86_is_enum_var(s1) == 1 { field_off = (field_idx + 1) * 8; }
        asm = asm + "    mov r10, [rbp";
        if off_struct >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off_struct);
        asm = asm + "]\n";
        asm = asm + "    mov r11, [rbp";
        if off_val >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off_val);
        asm = asm + "]\n";
        asm = asm + "    mov [r10 + ";
        asm = asm + int_str(field_off);
        asm = asm + "], r11\n";
        return asm;
    }

    if op == IR_LOAD_INDEX {
        off_arr := x86_get_offset(s1);
        off_d := x86_get_offset(dest);
        idx := s3;
        asm = asm + "    mov r10, [rbp";
        if off_arr >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off_arr);
        asm = asm + "]\n";
        asm = asm + "    mov r11, [r10 + ";
        asm = asm + int_str(idx * 8);
        asm = asm + "]\n";
        asm = asm + "    mov [rbp";
        if off_d >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off_d);
        asm = asm + "], r11\n";
        return asm;
    }

    if op == IR_STORE_INDEX {
        off_arr := x86_get_offset(s1);
        off_val := x86_get_offset(s2);
        idx := s3;
        asm = asm + "    mov r10, [rbp";
        if off_arr >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off_arr);
        asm = asm + "]\n";
        asm = asm + "    mov r11, [rbp";
        if off_val >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off_val);
        asm = asm + "]\n";
        asm = asm + "    mov [r10 + ";
        asm = asm + int_str(idx * 8);
        asm = asm + "], r11\n";
        return asm;
    }

    if op == IR_LOAD_INDEX_VAR {
        off_arr := x86_get_offset(s1);
        off_idx := x86_get_offset(s2);
        off_d := x86_get_offset(dest);
        asm = asm + "    mov r10, [rbp";
        if off_arr >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off_arr);
        asm = asm + "]\n";
        asm = asm + "    mov r11, [rbp";
        if off_idx >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off_idx);
        asm = asm + "]\n";
        asm = asm + "    mov r12, [r10 + r11 * 8]\n";
        asm = asm + "    mov [rbp";
        if off_d >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off_d);
        asm = asm + "], r12\n";
        return asm;
    }

    if op == IR_STORE_INDEX_VAR {
        off_arr := x86_get_offset(s1);
        off_idx := x86_get_offset(s2);
        off_val := x86_get_offset(dest);
        asm = asm + "    mov r10, [rbp";
        if off_arr >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off_arr);
        asm = asm + "]\n";
        asm = asm + "    mov r11, [rbp";
        if off_idx >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off_idx);
        asm = asm + "]\n";
        asm = asm + "    mov r12, [rbp";
        if off_val >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off_val);
        asm = asm + "]\n";
        asm = asm + "    mov [r10 + r11 * 8], r12\n";
        return asm;
    }

    if op == IR_MAKE_ENUM {
        off := x86_get_offset(dest);
        x86_mark_enum(dest);
        // s1 = variant name index, s2 = field_count
        alloc_size := 8 + s2 * 8;
        asm = asm + "    mov edi, ";
        asm = asm + int_str(alloc_size);
        asm = asm + "\n    call alloc\n";
        asm = asm + "    mov [rbp";
        if off >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off);
        asm = asm + "], rax\n";
        // Store tag (variant name index) at offset 0
        asm = asm + "    mov r10, [rbp";
        if off >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off);
        asm = asm + "]\n";
        asm = asm + "    mov qword ptr [r10 + 0], ";
        asm = asm + int_str(s1);
        asm = asm + "\n";
        return asm;
    }
    if op == IR_LOAD_ENUM_TAG {
        off_enum := x86_get_offset(s1);
        off_d := x86_get_offset(dest);
        asm = asm + "    mov r10, [rbp";
        if off_enum >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off_enum);
        asm = asm + "]\n";
        asm = asm + "    mov r11, [r10 + 0]\n";
        asm = asm + "    mov [rbp";
        if off_d >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off_d);
        asm = asm + "], r11\n";
        return asm;
    }
    if op == IR_REF {
        off_src := x86_get_offset(s1);
        off_d := x86_get_offset(dest);
        asm = asm + "    lea r10, [rbp";
        if off_src >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off_src);
        asm = asm + "]\n";
        asm = asm + "    mov [rbp";
        if off_d >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off_d);
        asm = asm + "], r10\n";
        return asm;
    }
    if op == IR_DEREF {
        off_src := x86_get_offset(s1);
        off_d := x86_get_offset(dest);
        asm = asm + "    mov r10, [rbp";
        if off_src >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off_src);
        asm = asm + "]\n";
        asm = asm + "    mov r11, [r10]\n";
        asm = asm + "    mov [rbp";
        if off_d >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off_d);
        asm = asm + "], r11\n";
        return asm;
    }
    if op == IR_STORE_PTR {
        off_ptr := x86_get_offset(s1);
        off_val := x86_get_offset(s2);
        asm = asm + "    mov r10, [rbp";
        if off_ptr >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off_ptr);
        asm = asm + "]\n";
        asm = asm + "    mov r11, [rbp";
        if off_val >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off_val);
        asm = asm + "]\n";
        asm = asm + "    mov [r10], r11\n";
        return asm;
    }

    if op == IR_SLICE {
        // Create slice pointer: dest = arr_ptr + low * 8
        off_arr := x86_get_offset(s1);
        off_low := x86_get_offset(s2);
        off_d := x86_get_offset(dest);
        asm = asm + "    mov r10, [rbp";
        if off_arr >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off_arr);
        asm = asm + "]\n";
        asm = asm + "    mov r11, [rbp";
        if off_low >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off_low);
        asm = asm + "]\n";
        asm = asm + "    shl r11, 3\n";
        asm = asm + "    add r10, r11\n";
        asm = asm + "    mov [rbp";
        if off_d >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off_d);
        asm = asm + "], r10\n";
        return asm;
    }

    if op == IR_BRANCH {
        off_cond := x86_get_offset(s1);
        true_lbl := s2;
        false_lbl := s3;
        asm = asm + "    mov r10, [rbp";
        if off_cond >= 0 { asm = asm + "+"; }
        asm = asm + int_str(off_cond);
        asm = asm + "]\n";
        asm = asm + "    cmp r10, 1\n";
        asm = asm + "    je  ";
        asm = asm + x86_jump_label(true_lbl);
        asm = asm + "\n    jmp ";
        asm = asm + x86_jump_label(false_lbl);
        asm = asm + "\n";
        return asm;
    }

    if op == IR_JUMP {
        asm = asm + "    jmp ";
        asm = asm + x86_jump_label(s1);
        asm = asm + "\n";
        return asm;
    }

    if op == IR_LABEL {
        asm = asm + x86_label(s1);
        asm = asm + "\n";
        return asm;
    }

    if op == IR_PHI { return asm; }
    return asm;
}

fn x86_gen_function(func_idx: int) -> string {
    name_idx := r64(g_ir_func_name_idx, func_idx * 8);
    func_name := istr_get(name_idx);
    instr_start := r64(g_ir_func_instr_start, func_idx * 8);
    instr_count := r64(g_ir_func_instr_count, func_idx * 8);
    var_count := r64(g_ir_func_var_count, func_idx * 8);
    var_start := r64(g_ir_func_var_start, func_idx * 8);

    asm : ., mut = "";

    if func_name == "main" {
        asm = asm + ".globl main\nmain:\n";
    } else {
        asm = asm + func_name;
        asm = asm + ":\n";
    }

    asm = asm + "    push rbp\n    mov rbp, rsp\n";

    x86_init_frame();
    vi : ., mut = 0;
    loop {
        if vi >= var_count { break; }
        x86_alloc_stack(var_start + vi);
        vi = vi + 1;
    }

    stack_sz : ., mut = g_x86_stack_size;

    if stack_sz > 0 {
        asm = asm + "    sub rsp, ";
        asm = asm + int_str(stack_sz);
        asm = asm + "\n";
    }

    // Save incoming register params to stack slots (x86-64 ABI: rdi, rsi, rdx, rcx, r8, r9)
    regs := ["rdi", "rsi", "rdx", "rcx", "r8", "r9"];
    param_count := r64(g_ir_func_param_count, func_idx * 8);
    pi : ., mut = 0;
    loop {
        if pi >= param_count { break; }
        if pi >= 6 { break; }
        poff := x86_get_offset(var_start + pi);
        asm = asm + "    mov [rbp";
        if poff >= 0 { asm = asm + "+"; }
        asm = asm + int_str(poff);
        asm = asm + "], ";
        asm = asm + regs[pi];
        asm = asm + "\n";
        pi = pi + 1;
    }

    g_x86_func_idx = func_idx;

    i : ., mut = 0;
    loop {
        if i >= instr_count { break; }
        instr_asm := x86_gen_instr(instr_start + i);
        asm = asm + instr_asm;
        i = i + 1;
    }

    asm = asm + ".Lret";
    asm = asm + int_str(g_x86_func_idx);
    asm = asm + ":\n";
    if stack_sz > 0 {
        asm = asm + "    add rsp, ";
        asm = asm + int_str(stack_sz);
        asm = asm + "\n";
    }
    asm = asm + "    pop rbp\n    ret\n";
    asm = asm + "\n";
    return asm;
}

fn x86_64_generate() -> string {
    asm : ., mut = "";
    asm = asm + ".intel_syntax noprefix\n.text\n.globl main\n.globl _init_globals\n\n";

    i : ., mut = 0;
    loop {
        if i >= g_ir_func_count { break; }
        asm = asm + x86_gen_function(i);
        i = i + 1;
    }

    asm = asm + "_init_globals:\n";
    asm = asm + "    push rbp\n    mov rbp, rsp\n";
    asm = asm + "    pop rbp\n    ret\n\n";

    asm = asm + ".section .rodata\n";
    si : ., mut = 0;
    loop {
        if si >= g_ir_str_const_count { break; }
        str_idx := r64(g_ir_str_consts, si * 8);
        lbl : ., mut = ".LC";
        lbl = lbl + int_str(si);
        lbl = lbl + ": .asciz \"";
        lbl = lbl + istr_get(str_idx);
        lbl = lbl + "\"\n";
        asm = asm + lbl;
        si = si + 1;
    }

    return asm;
}
