.section .text
.globl _start

add:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    add x2, x0, x1
    mov x0, x2
    ldp x29, x30, [sp], #16
    ret
_start:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov x0, #3
    mov x1, #4
    mov x0, x0
    mov x1, x1
    bl add
    mov x2, x0
    mov x0, x2
    // exit syscall
    mov x0, #0
    mov x8, #93
    svc #0