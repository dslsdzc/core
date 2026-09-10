// === src/os/linux/entry.cr（OS 轴：Linux 进程入口/启动集成；波 1 Task 2 自
// src/format/elf/elf.cr 整函数迁入——emit_start/emit_start_size 逐字节 verbatim）===
// _start 发射序：argc/argv 自初始栈装载 → g_rt_argc/g_rt_argv_ptr 存（RIP 补丁登记）
// → g_current_arena = -1 初始化 → 编译期常量全局初值环（imm32/imm64 两式）
// → call main（位置登记 g_call_main_pos 供重定位）→ exit(60) syscall。
// 外部耦合（共享全局——声明留格式轴 elf.cr，扁平编译单元内单次声明）：
//   g_call_main_pos / gv_argc / gv_argv / gv_current_arena —— elf_gen 扫描段
//   （src/format/elf/elf.cr）赋值；消费方 = 本文件 + elf.cr 补丁段 + instr.cr
//   get_arg（gv_argv）。跨轴引用经 module.cr 三轴回退链 / 组合根 _import.cr 的
//   `import entry` 解析（与 concat 清单 os_linux_files 双注册）。
// Depends on: x86_64/instr.cr（emit_rex/emit_modrm/emit_sib/e2_*）、
//             x86_64/sizes.cr（sz_start_body/sz_start_argv_save）

fn emit_start(buf: string, pos: int) -> int {
    cp : ., mut = pos;
    // mov rdi, [rsp]  — load argc (rdi=7)
    cp = cp + emit_rex(buf, cp, 1, 0, 0, 0);
    e2_w8(buf, cp, 139); cp = cp + 1;
    cp = cp + emit_modrm(buf, cp, 0, 7, 4);  // [rsp] via SIB
    cp = cp + emit_sib(buf, cp, 0, 4, 4);

    // lea rsi, [rsp+8]  — pointer to argv (rsi=6, no REX extension)
    cp = cp + emit_rex(buf, cp, 1, 0, 0, 0);
    e2_w8(buf, cp, 141); cp = cp + 1;
    cp = cp + emit_modrm(buf, cp, 1, 6, 4);  // [rsp+disp8]
    cp = cp + emit_sib(buf, cp, 0, 4, 4);
    e2_w8(buf, cp, 8); cp = cp + 1;

    if gv_argc >= 0 {
        // lea r10, [rip + 0]  (placeholder, patched in Phase 3)
        rip_pos := cp + 3;
        cp = cp + e2_lr(buf, cp, 0);
        grow_rip_patch(g_x86_rip_patch_count + 1);
        w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip_pos);
        w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gv_argc);
        g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
        // mov [r10], rdi — store argc
        cp = cp + emit_rex(buf, cp, 1, 0, 0, 10/8);
        e2_w8(buf, cp, 137); cp = cp + 1;
        cp = cp + emit_modrm(buf, cp, 0, 7, 10%8);
    }

    if gv_argv >= 0 {
        rip_pos2 := cp + 3;
        cp = cp + e2_lr(buf, cp, 0);
        grow_rip_patch(g_x86_rip_patch_count + 1);
        w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip_pos2);
        w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gv_argv);
        g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
        // mov [r10], rsi — store argv
        cp = cp + emit_rex(buf, cp, 1, 0, 0, 10/8);
        e2_w8(buf, cp, 137); cp = cp + 1;
        cp = cp + emit_modrm(buf, cp, 0, 6, 10%8);
    }

    // Initialize g_current_arena = -1 (no arena active)
    if gv_current_arena >= 0 {
        rip_ca := cp + 3;
        cp = cp + e2_lr(buf, cp, 0);  // lea r10, [rip+0]
        grow_rip_patch(g_x86_rip_patch_count + 1);
        w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip_ca);
        w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gv_current_arena);
        g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
        // mov qword [r10], -1  — REX.WB + 0xC7 /0
        cp = cp + emit_rex(buf, cp, 1, 0, 0, 10/8);
        e2_w8(buf, cp, 199); cp = cp + 1;      // 0xC7 MOV r/m64, imm32
        cp = cp + emit_modrm(buf, cp, 0, 0, 10%8);
        e2_w32(buf, cp, -1); cp = cp + 4;      // immediate = -1 (0xFFFFFFFF)
    }

    // Write compile-time constant global initializers (g_ir_globals[i].
    // init_val, i64 at +16; 0 = none — BSS is already zero).
    // g_current_arena is also covered by the explicit init above; the
    // LET-based init below writes it again with the same value (harmless).
    gi0 : ., mut = 0;
    loop { if gi0 >= g_ir_global_count { break; }
        iv := r64(g_ir_globals, gi0 * 24 + 16);
        gvv0 := r64(g_ir_globals, gi0 * 24 + 8);
        if iv != 0 && gvv0 >= 0 {
            // lea r10, [rip+0] — rip_patch for the global's BSS slot
            rip_pos_g := cp + 3;
            cp = cp + e2_lr(buf, cp, 0);
            grow_rip_patch(g_x86_rip_patch_count + 1);
            w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip_pos_g);
            w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gvv0);
            g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
            if iv >= -2147483647 - 1 && iv <= 2147483647 {
                // mov qword [r10], imm32 (sign-extended) — 49 C7 02 imm32
                w8(buf, cp, 73); w8(buf, cp+1, 199); w8(buf, cp+2, 2);
                e2_w32(buf, cp+3, iv); cp = cp + 7;
            } else {
                // mov rax, imm64; mov [r10], rax
                w8(buf, cp, 72); w8(buf, cp+1, 184); e2_w64(buf, cp+2, iv); cp = cp + 10;
                w8(buf, cp, 73); w8(buf, cp+1, 137); w8(buf, cp+2, 2); cp = cp + 3;
            }
        }
    gi0 = gi0 + 1; }

    g_call_main_pos = cp;
    cp = cp + e2_call(buf, cp, 0);  // call main

    // mov edi, eax
    e2_w8(buf, cp, 137); cp = cp + 1;
    cp = cp + emit_modrm(buf, cp, 3, 0, 7);

    // mov eax, 60  (sys_exit)
    e2_w8(buf, cp, 184); cp = cp + 1;  // 0xB8 MOV r, imm32 (rax)
    cp = cp + e2_w32(buf, cp, 60);

    // syscall
    e2_w8(buf, cp, 15); cp = cp + 1;
    e2_w8(buf, cp, 5); cp = cp + 1;

    return cp - pos;
}

fn emit_start_size() -> int {
    sz : ., mut = sz_start_body();
    if gv_argc >= 0 { sz = sz + sz_start_argv_save(); }
    if gv_argv >= 0 { sz = sz + sz_start_argv_save(); }
    // g_current_arena init: lea(7) + rex+mov+modrm+imm32(7) = 14 bytes
    if gv_current_arena >= 0 { sz = sz + 14; }
    // Constant global initializers: lea r10(7) + mov imm32(7) = 14 bytes,
    // or mov rax imm64 + mov [r10],rax = 20 bytes for large values.
    gi0s : ., mut = 0;
    loop { if gi0s >= g_ir_global_count { break; }
        ivs := r64(g_ir_globals, gi0s * 24 + 16);
        gvvs := r64(g_ir_globals, gi0s * 24 + 8);
        if ivs != 0 && gvvs >= 0 {
            if ivs >= -2147483647 - 1 && ivs <= 2147483647 { sz = sz + 14; }
            else { sz = sz + 20; }
        }
    gi0s = gi0s + 1; }
    return sz;
}
