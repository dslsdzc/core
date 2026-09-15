// ══════════════════════════════════════════════════════════════
// src/os/linux/syscall.cr —— OS 轴：Linux syscall 约定（内置体发射序）
//   （rax 号 + rdi/rsi/rdx(/r10) 参数序 + 0F 05 陷入 + rax 回存）
//
// x86 实例化波 1 Task 6 抽取：emit_instr（src/arch/x86_64/instr.cr）内置体
// 分派链中 syscall3 / syscall4 两分支的发射序列此前内联在巨函数里，本文件
// 把二者抽为两个入口（发射序逐字节 verbatim——波 1 判据 = stage 链
// byte-identical）：
//   sys_syscall3_stub —— syscall3(num, a, b, c)：通用装载器（cs_args_dispatch）
//     已按 SysV 把 4 个 int 实参放 rdi(号)/rsi/rdx/rcx，此处转位为 Linux
//     syscall 约定 rax=号 / rdi,rsi,rdx=前三参 → 0F 05 → rax 回存（d ≥ 0）。
//   sys_syscall4_stub —— syscall4(num, a, b, c, d)：第 4 参经 r10（**x86-64
//     syscall 约定：第 4 个非编号参数在 r10；rcx 被 syscall 指令用作返回
//     地址**）——I-2 修复史随迁（wait4 rusage EFAULT，见函数内注）。
//
// 归属裁决（设计 §1 "ABI = 交叉轴"；§2 OS 轴文件表列 syscall.cr）：syscall
// 约定 = OS 轴（Linux：rax 号 + rdi/rsi/rdx/r10 参数序）；编码原语
// （e2_mov/e2_w8/e2_store_ret）与内置体名索引/分派链（g_ni_syscall3/g_ni_
// syscall4、`if s3 ==` 链）留架构轴 src/arch/x86_64/instr.cr（concat 扁平
// 单元 / module.cr 三轴回退链解析，见组合根 _import.cr `import syscall`）。
// 与 instr.cr 的关系：instr.cr = 指令编码原语 + emit_instr 分派；本文件 =
// syscall 发射序——不新增任何编码原语。
//
// 抽取纪律（H1）：cp/pos/buf 三参数显式传递（无环境态假设）——buf = 字节
// 缓冲、pos = 本 IR 指令的绝对缓冲起点、cp = 相对 pos 的已发字节数；返回
// **新 cp**（相对量）——与同波 callseq.cr cs_* 同约定（frame.cr pf_* 取绝对
// 位置约定，按各自宿主函数风格定形，见 callseq.cr 头注）。d = 返回值目标
// 变量（< 0 = 无回存）。
//
// 内置体名索引扫描段（elf_gen 的 `str_eq(ns, "syscall3")` 段——g_ni_syscall3/
// g_ni_syscall4 赋值）**保留原位**（src/format/elf/elf.cr，该处加注指向本
// 文件）：扫描段整体参数化 = 波 2 面（设计 §5——本任务只抽发射两函数）。
//
// Depends on: x86_64/instr.cr（e2_mov/e2_w8/e2_store_ret——经 e2_st/e2_sd_store
//             分派）、共享全局（g_ni_syscall3/g_ni_syscall4——globals.cr 声明、
//             elf.cr 扫描段赋值、instr.cr 分派链消费）。
// ══════════════════════════════════════════════════════════════

// ── syscall3(num, a, b, c) —— 三个非编号参数 ──
// 转位（rax ← rdi, rdi ← rsi, rsi ← rdx, rdx ← rcx）后 0F 05；返回值 rax
// 按 d 的类型回存（int 槽 / binary64 槽，见 e2_store_ret）。返回新 cp。
fn sys_syscall3_stub(buf: string, pos: int, cp: int, d: int) -> int {
    cp = cp + e2_mov(buf, pos+cp, 0, 7);
    cp = cp + e2_mov(buf, pos+cp, 7, 6);
    cp = cp + e2_mov(buf, pos+cp, 6, 2);
    cp = cp + e2_mov(buf, pos+cp, 2, 1);
    // syscall: 2-byte 0x0F 0x05
    e2_w8(buf, pos+cp, 15); e2_w8(buf, pos+cp+1, 5); cp = cp + 2;
    if d >= 0 { cp = cp + e2_store_ret(buf, pos+cp, d); }
    return cp;
}

// ── syscall4(num, a, b, c, d) —— 第四个非编号参数经 r10 ──
// syscall4(num, a, b, c, d)——第 4 参 d 经 r10 传递（x86-64 syscall
// 约定：第 4 参在 r10；rcx 被 syscall 指令用作返回地址）。
// I-2：wait4 的 rusage 此前无第 4 参通道——通用装载器把第 4 参放
// rcx（ir_cnt=3）、第 5 参放 r8（ir_cnt=4），syscall 读 r10 = 残留
// 垃圾 → 内核 EFAULT 或写错地址 → 退出码传播不可靠。
// 返回新 cp。
fn sys_syscall4_stub(buf: string, pos: int, cp: int, d: int) -> int {
    cp = cp + e2_mov(buf, pos+cp, 0, 7);   // rax = rdi — syscall number
    cp = cp + e2_mov(buf, pos+cp, 7, 6);   // rdi = rsi — arg1
    cp = cp + e2_mov(buf, pos+cp, 6, 2);   // rsi = rdx — arg2
    cp = cp + e2_mov(buf, pos+cp, 2, 1);   // rdx = rcx — arg3
    cp = cp + e2_mov(buf, pos+cp, 10, 8);  // r10 = r8  — arg4
    // syscall: 2-byte 0x0F 0x05
    e2_w8(buf, pos+cp, 15); e2_w8(buf, pos+cp+1, 5); cp = cp + 2;
    if d >= 0 { cp = cp + e2_store_ret(buf, pos+cp, d); }
    return cp;
}
