// === targets/x86_64/linux/elf/target_abi.cr ===
// Combination-root frontend ABI composition for x86_64/linux/elf.
//
// The root owns no target facts. It composes the architecture, OS, and runtime
// axes; the container axis (ELF) is provided by src/format/elf and is not part
// of this frontend ABI table.

fn target_builtin_register():
    x86_frontend_builtin_register()
    linux_frontend_builtin_register()
    runtime_frontend_builtin_register()

fn target_builtin_return_ti(name_ni: int) -> int:
    return linux_frontend_builtin_return_ti(name_ni)
