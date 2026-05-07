.intel_syntax noprefix
.text
.globl _start

_start:
    push rbp
    mov rbp, rsp
    sub rsp, 8
    mov qword ptr [rbp-8], 42
    mov rax, [rbp-8]
    mov edi, eax
    mov eax, 60
    syscall

.section .rodata
