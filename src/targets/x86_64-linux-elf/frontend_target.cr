// === targets/x86_64-linux-elf/frontend_target.cr ===
// Frontend-visible target description for the x86_64 / Linux / ELF instance.
//
// The three axes are explicit. The frontend asks this file for import roots,
// the backend command, and runtime source locations; it does not embed target
// directory names or backend flags itself.

fn target_name() -> string:
    return "x86_64-linux-elf"

fn target_arch_name() -> string:
    return "x86_64"

fn target_system_name() -> string:
    return "linux"

fn target_container_name() -> string:
    return "elf"

fn target_import_root_count() -> int:
    return 10

// Return a search root with its trailing slash. The source directory is
// handled separately by module.cr because it is project-relative.
fn target_import_root(i: int) -> string:
    if i == 0:
        return "src/stdlib/"
    if i == 1:
        return "src/runtime/"
    if i == 2:
        return "src/kernel/"
    if i == 3:
        return "src/format/elf/"
    if i == 4:
        return "src/arch/x86_64/"
    if i == 5:
        return "src/os/linux/"
    if i == 6:
        return "src/compiler/"
    if i == 7:
        return "src/arch/hit/"
    if i == 8:
        return "src/lattice/"
    if i == 9:
        return "src/targets/x86_64-linux-elf/"
    return ""

fn target_so_index_path(home_dir: string, fs_path: string) -> string:
    return home_dir + "/.core/lib/" + fs_path + "/index"

fn target_static_runtime_source() -> string:
    return "src/runtime/rt.cr"

// Build the backend command for this target. The caller prefixes the sibling
// corearch directory; the target owns the backend name and ABI flags.
fn target_backend_command(ccr_path: string, out_path: string, is_static: int, opt_level: int) -> string:
    cmd : ., mut = "corearch " + ccr_path + " --elf"
    if opt_level > 0:
        cmd = cmd + " --opt-level " + int_str(opt_level)
    if is_static != 0:
        cmd = cmd + " --static"
    else:
        cmd = cmd + " --link auto"
    cmd = cmd + " -o " + out_path
    return cmd
