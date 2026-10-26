// === os/linux/frontend_abi.cr ===
// OS-axis frontend ABI builtins.
//
// Process-entry access and Linux syscall names belong to the OS axis, not to
// the semantic checker. The target composition root calls this registration;
// prelude_builtin_return_ti delegates syscall3/syscall4 here.
//
// get_arg/syscall3/syscall4 are also SYSTEM boundaries in the graph classifier
// (ccr_io.cr:ccr_raw_abi_builtin). Keep the two lists in sync.

fn linux_frontend_builtin_register():
    prelude_builtin_add("get_arg", TI_STR, 0)

fn linux_frontend_builtin_return_ti(name_ni: int) -> int:
    if name_ni < 0:
        return -1
    s := istr_get(name_ni)
    if s == "syscall3":
        return TI_INT
    if s == "syscall4":
        return TI_INT
    return -1
