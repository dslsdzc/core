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
    b return_1
return_1:
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
    b return_2
return_2:
    add sp, sp, #48
    ldp x29, x30, [sp], #16
    ret
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
    b loop_header_4
loop_header_4:
    b loop_body_5
loop_body_5:
    ldr x10, [sp, #8]
    ldr x11, [sp, #64]
    cmp x10, x11
    cset w12, gt
    str x12, [sp, #32]
    ldr x9, [sp, #32]
    cmp x9, #1
    b.eq then_7
    b if_merge_8
then_7:
    b loop_exit_6
if_merge_8:
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
    b loop_header_4
loop_exit_6:
    ldr x0, [sp, #24]
    b return_3
return_3:
    add sp, sp, #80
    ldp x29, x30, [sp], #16
    ret
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
    b.eq then_10
    b else_11
then_10:
    ldr x0, [sp, #8]
    b return_4
else_11:
    ldr x0, [sp, #16]
    b return_4
if_merge_12:
    b return_4
return_4:
    add sp, sp, #32
    ldp x29, x30, [sp], #16
    ret
_start:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    sub sp, sp, #144
    add x9, sp, #120
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
    mov x9, #5
    str x9, [sp, #72]
    ldr x0, [sp, #72]
    bl sum_to
    str x0, [sp, #80]
    ldr x9, [sp, #80]
    str x9, [sp, #88]
    ldr x0, [sp, #40]
    ldr x1, [sp, #88]
    bl max
    str x0, [sp, #96]
    ldr x9, [sp, #96]
    str x9, [sp, #104]
    ldr x10, [sp, #104]
    ldr x11, [sp, #64]
    add x12, x10, x11
    str x12, [sp, #112]
    ldr x0, [sp, #112]
    b return_5
return_5:
    // exit syscall
    mov x8, #93
    svc #0