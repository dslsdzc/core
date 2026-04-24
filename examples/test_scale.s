.section .text
.globl _start

Point.sum:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    sub sp, sp, #32
    str x0, [sp, #24]
    ldr x9, [sp, #24]
    ldr x10, [x9]
    str x10, [sp, #0]
    ldr x9, [sp, #24]
    ldr x10, [x9, #8]
    str x10, [sp, #8]
    ldr x10, [sp, #0]
    ldr x11, [sp, #8]
    add x12, x10, x11
    str x12, [sp, #16]
    ldr x0, [sp, #16]
    add sp, sp, #32
    ldp x29, x30, [sp], #16
    ret
Point.scale:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    sub sp, sp, #48
    str x0, [sp, #32]
    str x1, [sp, #40]
    ldr x9, [sp, #32]
    ldr x10, [x9]
    str x10, [sp, #0]
    ldr x9, [sp, #32]
    ldr x10, [x9, #8]
    str x10, [sp, #8]
    ldr x10, [sp, #0]
    ldr x11, [sp, #8]
    add x12, x10, x11
    str x12, [sp, #16]
    ldr x10, [sp, #16]
    ldr x11, [sp, #40]
    mul x12, x10, x11
    str x12, [sp, #24]
    ldr x0, [sp, #24]
    add sp, sp, #48
    ldp x29, x30, [sp], #16
    ret
_start:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    sub sp, sp, #96
    add x9, sp, #80
    str x9, [sp, #0]
    mov x9, #10
    str x9, [sp, #8]
    ldr x9, [sp, #0]
    ldr x10, [sp, #8]
    str x10, [x9]
    mov x9, #20
    str x9, [sp, #16]
    ldr x9, [sp, #0]
    ldr x10, [sp, #16]
    str x10, [x9, #8]
    ldr x9, [sp, #0]
    str x9, [sp, #24]
    ldr x0, [sp, #24]
    bl Point.sum
    str x0, [sp, #32]
    ldr x9, [sp, #32]
    str x9, [sp, #40]
    mov x9, #3
    str x9, [sp, #48]
    ldr x0, [sp, #24]
    ldr x1, [sp, #48]
    bl Point.scale
    str x0, [sp, #56]
    ldr x9, [sp, #56]
    str x9, [sp, #64]
    ldr x10, [sp, #40]
    ldr x11, [sp, #64]
    add x12, x10, x11
    str x12, [sp, #72]
    ldr x0, [sp, #72]
    // exit syscall
    mov x8, #93
    svc #0