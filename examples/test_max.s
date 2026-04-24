.section .text
.globl _start

max:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    sub sp, sp, #32
    str x0, [sp, #8]
    str x1, [sp, #16]
    ldr x10, [sp, #8]
    ldr x11, [sp, #16]
    cmp x10, x11
    cset w12, gt
    str x12, [sp, #0]
    ldr x9, [sp, #0]
    cmp x9, #1
    b.eq then_2
    b else_3
then_2:
    ldr x0, [sp, #8]
else_3:
    ldr x0, [sp, #16]
if_merge_4:
    add sp, sp, #32
    ldp x29, x30, [sp], #16
    ret
_start:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    sub sp, sp, #32
    mov x9, #3
    str x9, [sp, #0]
    mov x9, #7
    str x9, [sp, #8]
    ldr x0, [sp, #0]
    ldr x1, [sp, #8]
    bl max
    str x0, [sp, #16]
    ldr x0, [sp, #16]
    // exit syscall
    mov x8, #93
    svc #0