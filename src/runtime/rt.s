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
    .space 1024 * 1024 * 1024
heap_end:
.balign 8
current_g: .space 8  # legacy slot; current G now lives in %fs:0
main_tls:
    .space 32        # +0 current_g, +8 m_idx, +16 current_arena, +24 arena_suspend

.section .data
heap_ptr: .quad 0
empty_str_hdr: .quad 1
empty_str: .byte 0
.balign 8

# Hotpatch SIGHUP sigaction struct — registered in _start
hotpatch_sa:
    .quad _hotpatch_sighup    # sa_handler
    .quad 0                   # sa_flags
    .quad 0                   # sa_mask  (empty sigset_t, 8 bytes on x86-64)

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

    # Per-thread runtime state: %fs base -> main_tls.
    lea rsi, [rip + main_tls]
    mov edi, 0x1002          # ARCH_SET_FS
    mov eax, 158             # arch_prctl
    syscall
    mov rax, -1
    mov qword ptr fs:[0], rax
    xor eax, eax
    mov qword ptr fs:[8], rax
    mov rax, -1
    mov qword ptr fs:[16], rax
    xor eax, eax
    mov qword ptr fs:[24], rax

    # Initialize bump allocator heap pointer
    lea rax, [rip + heap_start]
    lea r10, [rip + heap_ptr]
    mov [r10], rax
    call _init_globals

    # Register SIGHUP handler — reloads .hotpatch.toml on SIGHUP
    lea rsi, [rip + hotpatch_sa]
    mov rdi, 1          # SIGHUP = 1
    xor rdx, rdx        # oldact = NULL
    mov r10d, 8         # sigsetsize = sizeof(sigset_t) on x86-64
    mov eax, 13         # rt_sigaction syscall
    syscall

    call main

    mov edi, eax
    mov eax, 231         # exit_group: all M workers
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

# _hotpatch_sighup — SIGHUP signal handler
# Reloads .hotpatch.toml via hp_load_config().
# Kernel saves/restores all registers across signal delivery.
.globl _hotpatch_sighup
.type _hotpatch_sighup, @function
_hotpatch_sighup:
    call hp_load_config
    ret

# fiber_switch(current_sp_addr, next_sp) -> int
# Save current context, load next context
.globl fiber_switch
.type fiber_switch, @function
fiber_switch:
    # rdi = &current_g.stack_ptr (address to save RSP to)
    # rsi = next_g.stack_ptr (RSP to restore)

    # Save callee-saved registers
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp

    # Save RSP
    mov qword [rdi], rsp

    # Restore next RSP
    mov rsp, rsi

    # Restore callee-saved registers
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx

    ret

# fiber_init(stack_bottom, entry_fn) -> int
# Initialize a new fiber's stack and return its initial SP
.globl fiber_init
.type fiber_init, @function
fiber_init:
    # rdi = stack_bottom (highest address of the 16KB stack)
    # rsi = entry_fn (function to call when fiber starts)

    # Set up a fake stack frame so fiber_switch will jump to entry_fn
    # Stack layout (from top):
    #   [return address] = entry_fn
    #   [saved rbp] = 0
    #   [saved r15-r12, rbx] = 0
    # RSP after fiber_switch pops these will be at entry_fn

    mov rax, rdi        # rax = stack_bottom
    sub rax, 8          # [stack_bottom-8] = the return-address slot:
    mov qword [rax], rsi      # fiber_switch pops 6 regs (48 bytes) then ret
                        # reads [stack_bottom-8] — entry_fn must live there.
    sub rax, 48         # [stack_bottom-56] = first pop slot (saved rbp)
    xor ecx, ecx
    mov [rax], rcx      # 0 — popped into rbp; the rest of the slots are
                        # already zeroed by alloc's zero-init.

    ret

# g_set_curg(ptr) — set current goroutine pointer (per-thread)
.globl g_set_curg
.type g_set_curg, @function
g_set_curg:
    mov qword ptr fs:[0], rdi
    ret

# g_get_curg() — get current goroutine pointer (per-thread)
.globl g_get_curg
.type g_get_curg, @function
g_get_curg:
    mov rax, qword ptr fs:[0]
    ret

# Per-thread runtime state accessors.
.globl rt_m_idx
.type rt_m_idx, @function
rt_m_idx:
    mov rax, qword ptr fs:[8]
    ret

.globl rt_current_arena
.type rt_current_arena, @function
rt_current_arena:
    mov rax, qword ptr fs:[16]
    ret

.globl rt_set_current_arena
.type rt_set_current_arena, @function
rt_set_current_arena:
    mov qword ptr fs:[16], rdi
    ret

.globl rt_arena_suspend
.type rt_arena_suspend, @function
rt_arena_suspend:
    mov rax, qword ptr fs:[24]
    ret

.globl rt_set_arena_suspend
.type rt_set_arena_suspend, @function
rt_set_arena_suspend:
    mov qword ptr fs:[24], rdi
    ret

# Atomic primitives. Offsets are byte offsets; callers keep them 8-byte aligned.
.globl rt_atomic_load
.type rt_atomic_load, @function
rt_atomic_load:
    mov rax, qword ptr [rdi + rsi]
    ret

.globl rt_atomic_store
.type rt_atomic_store, @function
rt_atomic_store:
    mov qword ptr [rdi + rsi], rdx
    ret

.globl rt_atomic_xchg
.type rt_atomic_xchg, @function
rt_atomic_xchg:
    mov rax, rdx
    xchg qword ptr [rdi + rsi], rax
    ret

.globl rt_atomic_cas
.type rt_atomic_cas, @function
rt_atomic_cas:
    mov rax, rdx
    lock cmpxchg qword ptr [rdi + rsi], rcx
    sete al
    movzx eax, al
    ret

.globl rt_atomic_fetch_add
.type rt_atomic_fetch_add, @function
rt_atomic_fetch_add:
    mov rax, rdx
    lock xadd qword ptr [rdi + rsi], rax
    ret

# m_start_workers(n: int) — launch N worker threads via clone
# Each worker runs the scheduler loop (sched_worker_run).
# clone flags: CLONE_VM|CLONE_FS|CLONE_FILES|CLONE_SIGHAND|CLONE_THREAD
# = 0x10F00
# syscall 56: clone(flags, child_stack, parent_tid, child_tls, child_tid)
#
# Register usage:
#   rbx = n (total workers to start)
#   r12 = current worker index (0 = main thread, 1..n-1 = workers)
#   r15 = child stack top (scratch)
.globl m_start_workers
.type m_start_workers, @function
m_start_workers:
    push rbx
    push r12
    push r13
    push r15
    mov rbx, rdi         # rbx = n (total workers)
    xor r12d, r12d       # r12 = 0; increment before first use
.Lworker_loop:
    inc r12              # worker index 1..n-1
    cmp r12, rbx
    jge .Ldone

    # 64KB stack for the worker; 16-byte align the top.
    push r12
    mov rdi, 65536
    call alloc
    pop r12
    test rax, rax
    jz .Lnext_worker
    mov r15, rax
    add r15, 65536
    and r15, -16

    # 32-byte TLS block per worker: current_g, m_idx, current_arena, suspend.
    mov rdi, 32
    call alloc
    test rax, rax
    jz .Lnext_worker
    mov r13, rax
    mov qword ptr [r13], -1
    mov [r13 + 8], r12
    mov qword ptr [r13 + 16], -1
    mov qword ptr [r13 + 24], 0

    # Child stack: [top-16] = worker_entry, [top-8] = worker index.
    lea r11, [rip + worker_entry]
    mov [r15 - 16], r11
    mov [r15 - 8], r12

    # clone(flags=CLONE_*|CLONE_SETTLS, child_stack, parent_tid, child_tls, child_tid)
    mov edi, 0x90F00
    lea rsi, [r15 - 16]
    xor edx, edx
    xor r10d, r10d
    mov r8, r13
    mov eax, 56
    syscall

    test rax, rax
    jz .Lchild

.Lnext_worker:
    jmp .Lworker_loop

.Lchild:
    # Child thread: RSP = child_stack = r15 - 16
    # Pop return address (worker_entry) and jump there via ret
    xor ebp, ebp
    ret

.Ldone:
    pop r15
    pop r13
    pop r12
    pop rbx
    ret

# worker_entry: entry point for worker threads spawned by m_start_workers.
# The worker index is at [RSP] (pushed before clone on child stack).
# We pop it and call sched_worker_run(m_idx) — never returns.
worker_entry:
    pop rdi              # rdi = worker index (first arg to sched_worker_run)
    call sched_worker_run
    # Should never return, but just in case:
    mov eax, 60          # exit syscall
    xor edi, edi
    syscall

# goroutine_entry_wrapper: entry point for goroutines spawned via go.
# Called via fiber_init as the fiber entry.
# Reads the current G via g_get_curg(),
# loads saved_fn and saved_arg from G, calls saved_fn(saved_arg),
# sends rax to result_ch, then reclaims the goroutine:
# g_free (arena_reset + mark _Gdead) and sched_schedule to the next G.
.globl goroutine_entry_wrapper
.type goroutine_entry_wrapper, @function
goroutine_entry_wrapper:
    call g_get_curg       # rax = current G pointer
    mov rdi, [rax + 64]   # rdi = saved_arg (first parameter — SysV rdi)
    mov rax, [rax + 56]   # rax = saved_fn (G pointer no longer needed)
    call rax              # call saved_fn(saved_arg)
    # rax = return value
    push rax
    call g_get_curg
    mov rdi, [rax + 40]   # rdi = result_ch
    pop rsi               # rsi = return value
    call chan_send        # chan_send(result_ch, return_value)
.Lexit:
    # Get current G and reclaim it: arena_reset + mark _Gdead
    call g_get_curg
    mov rdi, rax
    call g_free
    # Exit goroutine: switch to next without re-enqueueing
    call sched_schedule
    # If schedule returns (no more work), just return (fiber dead)
    ret

# sched_call_N(table, index, args...): load the function pointer and tail-call it.
# These are the native/rt.s counterparts of the backend-emitted trampolines;
# they are used by the self-hosted compiler's own conc runtime.
.globl sched_call_0
.type sched_call_0, @function
sched_call_0:
    mov rax, [rdi + rsi*8]
    jmp rax

.globl sched_call_1
.type sched_call_1, @function
sched_call_1:
    mov rax, [rdi + rsi*8]
    mov rdi, rdx
    jmp rax

.globl sched_call_2
.type sched_call_2, @function
sched_call_2:
    mov rax, [rdi + rsi*8]
    mov rdi, rdx
    mov rsi, rcx
    jmp rax

.globl sched_call_3
.type sched_call_3, @function
sched_call_3:
    mov rax, [rdi + rsi*8]
    mov rdi, rdx
    mov rsi, rcx
    mov rdx, r8
    jmp rax

.globl sched_call_4
.type sched_call_4, @function
sched_call_4:
    mov rax, [rdi + rsi*8]
    mov rdi, rdx
    mov rsi, rcx
    mov rdx, r8
    mov rcx, r9
    jmp rax
