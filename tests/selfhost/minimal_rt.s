# minimal_rt.s - Tiny runtime providing __builtin_alloc and _start for bare-ld tests
# Bump allocator, AT&T syntax

.section .data
.align 8
heap: .space 65536
heap_ptr: .quad heap

.section .text
.globl _start
_start:
    call main
    mov %eax, %edi
    mov $60, %eax
    syscall

.globl __builtin_alloc
__builtin_alloc:
    pushq %rbp
    movq %rsp, %rbp
    # Align size to 8
    movq %rdi, %r10
    addq $7, %r10
    andq $-8, %r10
    # Load current heap pos, store in rax (return value)
    movq heap_ptr(%rip), %rax
    # Advance: heap_ptr += aligned_size
    movq %rax, %r11
    addq %r10, %r11
    movq %r11, heap_ptr(%rip)
    popq %rbp
    ret
