.section .text
.globl _start

sum_to:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    sub sp, sp, #80
    str x0, [sp, #64]
    mov x9, #1
    str x9, [sp, #0]
    ldr x9, [sp, #0]
    str x9, [sp, #8]
    mov x9, #0
    str x9, [sp, #16]
    ldr x9, [sp, #16]
    str x9, [sp, #24]
    b loop_header_2
loop_header_2:
    b loop_body_3
loop_body_3:
    ldr x10, [sp, #8]
    ldr x11, [sp, #64]
    cmp x10, x11
    cset w12, gt
    str x12, [sp, #32]
    ldr x9, [sp, #32]
    cmp x9, #1
    b.eq then_5
    b if_merge_6
then_5:
    b loop_exit_4
if_merge_6:
    ldr x10, [sp, #24]
    ldr x11, [sp, #8]
    add x12, x10, x11
    str x12, [sp, #40]
    ldr x9, [sp, #40]
    str x9, [sp, #24]
    mov x9, #1
    str x9, [sp, #48]
    ldr x10, [sp, #8]
    ldr x11, [sp, #48]
    add x12, x10, x11
    str x12, [sp, #56]
    ldr x9, [sp, #56]
    str x9, [sp, #8]
    b loop_header_2
loop_exit_4:
    ldr x0, [sp, #24]
    add sp, sp, #80
    ldp x29, x30, [sp], #16
    ret
_start:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    sub sp, sp, #16
    mov x9, #5
    str x9, [sp, #0]
    ldr x0, [sp, #0]
    bl sum_to
    str x0, [sp, #8]
    ldr x0, [sp, #8]
    // exit syscall
    mov x8, #93
    svc #0