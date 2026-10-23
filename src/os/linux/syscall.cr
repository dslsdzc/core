// === syscall.cr ===
// Linux syscall sequences for the OS axis.
// Convention: syscall number in rax; arguments in rdi, rsi, rdx, r10, r8, r9;
// syscall instruction 0F 05; return value in rax.
//
// sys_syscall3_stub and sys_syscall4_stub receive arguments already placed by
// cs_args_dispatch in SysV order: number in rdi, then rsi, rdx, rcx, r8. They
// shift the registers into Linux syscall order and store the result according
// to d.
//
// buf is the byte buffer, pos is the absolute buffer position of this IR
// instruction, and cp is the number of bytes already emitted relative to pos.
// The return value is the new cp. d is the return destination; d < 0 means no
// store.
//
// The builtin name scan and the g_ni_syscall3 and g_ni_syscall4 assignments
// remain in src/format/elf/elf.cr.
//
// Depends on instr.cr for e2_mov, e2_w8, and e2_store_ret, and on the shared
// g_ni_syscall3 and g_ni_syscall4 globals.

// syscall3(num, a, b, c): shift rdi to rax, rsi to rdi, rdx to rsi, and rcx to
// rdx. Emit 0F 05, then store rax according to d. Returns the new cp.
fn sys_syscall3_stub(buf: string, pos: int, cp: int, d: int) -> int:
    cp = cp + e2_mov(buf, pos+cp, 0, 7)
    cp = cp + e2_mov(buf, pos+cp, 7, 6)
    cp = cp + e2_mov(buf, pos+cp, 6, 2)
    cp = cp + e2_mov(buf, pos+cp, 2, 1)
    // syscall: 2-byte 0x0F 0x05
    e2_w8(buf, pos+cp, 15)
    e2_w8(buf, pos+cp+1, 5)
    cp = cp + 2
    if d >= 0:
        cp = cp + e2_store_ret(buf, pos+cp, d)
    return cp

// syscall4(num, a, b, c, arg4): the first three shifts are the same as
// syscall3. The fourth non-number argument arrives in r8 from cs_args_dispatch
// and moves to r10. Linux uses r10 for argument 4 because rcx holds the return
// address during the syscall instruction. Emit 0F 05, then store rax according
// to d. Returns the new cp.
fn sys_syscall4_stub(buf: string, pos: int, cp: int, d: int) -> int:
    cp = cp + e2_mov(buf, pos+cp, 0, 7)   // rax = rdi, syscall number
    cp = cp + e2_mov(buf, pos+cp, 7, 6)   // rdi = rsi, arg1
    cp = cp + e2_mov(buf, pos+cp, 6, 2)   // rsi = rdx, arg2
    cp = cp + e2_mov(buf, pos+cp, 2, 1)   // rdx = rcx, arg3
    cp = cp + e2_mov(buf, pos+cp, 10, 8)  // r10 = r8, arg4
    // syscall: 2-byte 0x0F 0x05
    e2_w8(buf, pos+cp, 15)
    e2_w8(buf, pos+cp+1, 5)
    cp = cp + 2
    if d >= 0:
        cp = cp + e2_store_ret(buf, pos+cp, d)
    return cp
