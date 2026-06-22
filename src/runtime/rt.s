# rt.s — x86-64 runtime for Core native binaries
# Provides: __builtin_alloc (bump allocator),
#           __builtin_get_arg (command-line argument access).
# Assemble: as -o rt.o rt.s
# Link: ld -o binary rt.o <other.o>

.intel_syntax noprefix

.section .data
rt_argc: .quad 0
rt_argv: .quad 0

.section .bss
.balign 4096
heap_start:
    .space 256 * 1024 * 1024
heap_end:

.section .data
heap_ptr: .quad 0
empty_str_hdr: .quad 1
empty_str: .byte 0
.balign 8

.text

# _start — entry point: saves argc/argv, calls main, exits via syscall.
.globl _start
.type _start, @function
_start:
    # Save argc/argv from stack (Linux process initialization)
    mov rdi, [rsp]
    lea rsi, [rsp + 8]
    lea rax, [rip + rt_argc]
    mov [rax], rdi
    lea rax, [rip + rt_argv]
    mov [rax], rsi

    # Initialize bump allocator heap pointer
    lea rax, [rip + heap_start]
    lea r10, [rip + heap_ptr]
    mov [r10], rax
    call _init_globals
    call main

    mov edi, eax
    mov eax, 60
    syscall

# alloc(size: int) -> string (pointer)
# Allocate size bytes + 8-byte length header.
# Layout: [8-byte size][data...]
# Returns pointer to data (after the header).
# str_len(returned_ptr) = read_header(returned_ptr - 8) - 1 (minus null byte)
.globl alloc
.type alloc, @function
alloc:
    # rdi = requested_size (caller wants rdi usable bytes)
    mov r8, rdi          # save requested size in r8
    add rdi, 15          # size + 8(header) + 7(align)
    and rdi, -8          # align to 8
    lea r10, [rip + heap_ptr]
    mov rax, [r10]
    lea rdx, [rax + rdi]
    lea rcx, [rip + heap_end]
    cmp rdx, rcx
    ja .Lalloc_oom
    mov [r10], rdx

    # Write requested size at header (before data ptr)
    mov [rax], r8

    # Zero-initialize the data portion only (skip header)
    push rax
    push rdx
    lea rdi, [rax + 8]
    xor eax, eax
    sub rdx, rdi
    mov rcx, rdx
    cld
    rep stosb
    pop rdx
    pop rax

    lea rax, [rax + 8]    # return ptr to data (after header)
    ret

.Lalloc_oom:
    xor eax, eax
    ret


# get_arg(n: int) -> string
# Returns a copy of the nth command-line argument (0 = program name).
.globl get_arg
.type get_arg, @function
get_arg:
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
    call alloc
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

# load_str_ptr(buf: string, pos: int) -> string
# Load 8-byte string pointer from byte buffer at given offset.
.globl load_str_ptr
.type load_str_ptr, @function
load_str_ptr:
    mov rax, [rdi + rsi]
    ret

# store_str_ptr(buf: string, pos: int, val: string) -> int
# Store 8-byte string pointer into byte buffer at given offset.
.globl store_str_ptr
.type store_str_ptr, @function
store_str_ptr:
    mov [rdi + rsi], rdx
    xor eax, eax
    ret

# load64(buf: string, pos: int) -> int
# Load 8-byte integer from byte buffer at given offset.
.globl load64
.type load64, @function
load64:
    mov rax, [rdi + rsi]
    ret
