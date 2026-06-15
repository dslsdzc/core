# rt.s — x86-64 runtime for Core native binaries
# Provides: __builtin_alloc (bump allocator),
#           __builtin_get_arg (command-line argument access).
# Assemble: as -o rt.o rt.s
# Link: ld -o binary rt.o <other.o>

.intel_syntax noprefix

.section .data
.globl rt_argc
rt_argc: .quad 0
.globl rt_argv
rt_argv: .quad 0

.section .bss
.balign 4096
heap_start:
    .space 256 * 1024 * 1024
heap_end:

.section .data
heap_ptr: .quad heap_start
empty_str: .byte 0

.text

# _start — entry point: saves argc/argv, calls main, exits via syscall.
.globl _start
.type _start, @function
_start:
    # Save argc/argv from stack (Linux process initialization)
    mov rdi, [rsp]
    lea rsi, [rsp + 8]
    mov [rip + rt_argc], rdi
    mov [rip + rt_argv], rsi

    call _init_globals
    call main

    mov edi, eax
    mov eax, 60
    syscall

# __builtin_alloc(size: int) -> string (pointer)
# Bump allocator, 8-byte aligned, never frees.
.globl __builtin_alloc
.type __builtin_alloc, @function
__builtin_alloc:
    add rdi, 7
    and rdi, -8

    mov rax, [rip + heap_ptr]
    lea rdx, [rax + rdi]
    lea rcx, [rip + heap_end]
    cmp rdx, rcx
    ja .Lalloc_oom

    mov [rip + heap_ptr], rdx

    # Zero-initialize
    push rax
    push rdx
    mov rdi, rax
    xor eax, eax
    sub rdx, rdi
    mov rcx, rdx
    cld
    rep stosb
    pop rdx
    pop rax
    ret

.Lalloc_oom:
    xor eax, eax
    ret


# __builtin_get_arg(n: int) -> string
# Returns a copy of the nth command-line argument (0 = program name).
.globl __builtin_get_arg
.type __builtin_get_arg, @function
__builtin_get_arg:
    mov rcx, [rip + rt_argc]
    cmp rdi, rcx
    jge .Larg_oob
    cmp rdi, 0
    jl .Larg_oob

    push r12
    mov rcx, [rip + rt_argv]
    mov r12, [rcx + rdi*8]      # r12 = argv[n]

    # strlen(r12)
    mov rdi, r12
    xor eax, eax
    mov rcx, -1
    repne scasb
    not rcx
    dec rcx                     # rcx = strlen

    # Allocate len + 1
    lea rdi, [rcx + 1]
    push rcx                    # save len
    call __builtin_alloc
    pop rcx                     # rcx = len
    test rax, rax
    jz .Larg_alloc_fail

    # memcpy(rax, r12, len+1)
    mov rdi, rax
    push rax                    # save buffer start
    mov rsi, r12
    lea rcx, [rcx + 1]          # len+1 (include null)
    rep movsb
    pop rax                     # restore buffer start
    pop r12
    ret

.Larg_alloc_fail:
    xor eax, eax
    pop r12
    ret

.Larg_oob:
    lea rax, [rip + empty_str]
    ret

# __builtin_load_str_ptr(buf: string, pos: int) -> string
# Load 8-byte string pointer from byte buffer at given offset.
.globl __builtin_load_str_ptr
.type __builtin_load_str_ptr, @function
__builtin_load_str_ptr:
    mov rax, [rdi + rsi]
    ret

# __builtin_store_str_ptr(buf: string, pos: int, val: string) -> int
# Store 8-byte string pointer into byte buffer at given offset.
.globl __builtin_store_str_ptr
.type __builtin_store_str_ptr, @function
__builtin_store_str_ptr:
    mov [rdi + rsi], rdx
    xor eax, eax
    ret
