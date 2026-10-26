// os.cr: operating system interface library.
// Provides process commands and environment access.
// Pure Core implementation using Linux system calls through syscall3 and syscall4.

// Structure used to build an execve argv array.
// Layout: four consecutive 8-byte values. d = 0 is the null terminator.
struct Argv4:
    a: string, b: string, c: string, d: int

// get_cwd() - return the process working directory.
fn get_cwd() -> string, pub:
    buf := alloc(4096)
    n := syscall3(79, buf, 4096, 0)
    if n <= 1:
        return ""
    return str_sub(buf, 0, n - 1)

// get_exe_path() - resolve the running executable even when argv[0] came from PATH.
fn get_exe_path() -> string, pub:
    buf := alloc(4096)
    n := syscall3(89, "/proc/self/exe", buf, 4095)
    if n <= 0:
        return ""
    return str_sub(buf, 0, n)

// system(cmd): fork, run /bin/sh -c cmd in the child, wait4 in the parent, and
// return the child's exit status. Returns -1 on failure.
fn system(cmd: string) -> int, pub:
    // Fork.
    pid := syscall3(57, 0, 0, 0)
    if pid < 0:
        return -1
    if pid > 0:
        // Parent: wait for the child.
        status_buf := alloc(16)
        // wait4 takes four arguments: pid, &status, options, and rusage. syscall3
        // provides only three non-numbered argument channels, and the fourth
        // would be clobbered by the syscall instruction. syscall4 passes it in
        // r10.
        syscall4(61, pid, status_buf, 0, 0)  // wait4(pid, &status, options=0, rusage=NULL)
        // Linux wait status stores a normal exit code in bits 8..15.
        return load8(status_buf, 1) % 256
    // Child: execute the command.
    // Build argv explicitly so execve receives a raw pointer array.
    argv := alloc(32)
    store_str_ptr(argv, 0, "/bin/sh")
    store_str_ptr(argv, 8, "-c")
    store_str_ptr(argv, 16, cmd)
    zi : ., mut = 0
    loop:
        if zi >= 8:
            break
        store8(argv, 24 + zi, 0)
        zi = zi + 1
    syscall3(59, "/bin/sh", argv, 0)  // execve; it does not return on success
    syscall3(60, 127, 0, 0)  // _exit(127) when execve fails
    return -1

// get_env(name): read an environment variable from /proc/self/environ.
// Returns the value, or "" when the variable is absent.
fn get_env(name: string) -> string, pub:
    env := read_file("/proc/self/environ")
    if str_len(env) == 0:
        return ""
    elen := str_len(env)
    i : ., mut = 0
    loop:
        if i >= elen:
            break
        eq_pos : ., mut = -1
        j : ., mut = i
        loop:
            if j >= elen:
                break
            c := load8(env, j)
            if c == 61:
                eq_pos = j
                break
            // Equal sign.
            if c == 0:
                break
            // Null separator.
            j = j + 1
        if eq_pos >= 0:
            key_len := eq_pos - i
            nlen := str_len(name)
            if key_len == nlen:
                is_match : ., mut = 1
                ki : ., mut = 0
                loop:
                    if ki >= key_len:
                        break
                    if load8(env, i + ki) != load8(name, ki):
                        is_match = 0
                        break
                    ki = ki + 1
                if is_match != 0:
                    val_start := eq_pos + 1
                    val_end : ., mut = val_start
                    loop:
                        if val_end >= elen:
                            break
                        if load8(env, val_end) == 0:
                            break
                        val_end = val_end + 1
                    return str_sub(env, val_start, val_end - val_start)
        while i < elen && load8(env, i) != 0:
            i = i + 1
        i = i + 1
    return ""
