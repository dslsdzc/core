// os.cr — 操作系统接口标准库
// 提供系统命令调用等操作系统级功能
// 纯 Core 实现，通过 syscall3 直接使用 Linux 系统调用

// 用于构造 execve argv 数组的结构体
// 内存布局：4 个连续的 8 字节值（指针数组）
// d=0 作为 NULL 终止符
struct Argv4 { a: string, b: string, c: string, d: int }

// system(cmd) — 执行 shell 命令
// 功能：fork() → 子进程 execve("/bin/sh", ["/bin/sh", "-c", cmd], environ)
//       父进程 wait4() 等待子进程结束，返回退出状态码
// 返回：子进程的退出码（0-255），失败返回 -1
fn system(cmd: string) -> int {
    // fork()
    pid := syscall3(57, 0, 0, 0);
    if pid < 0 { return -1; }
    if pid > 0 {
        // 父进程：等待子进程结束
        status_buf := alloc(16);
        syscall3(61, pid, status_buf, 0);  // wait4(pid, &status, 0, NULL)
        status := load8(status_buf, 0);
        return status % 256;  // WEXITSTATUS
    }
    // 子进程：执行命令
    // Argv4 结构体在堆上分配，字段连续存储：
    //   offset+0: 指向 "/bin/sh" 的指针
    //   offset+8: 指向 "-c" 的指针
    //   offset+16: 指向 cmd 的指针
    //   offset+24: 0 (NULL 终止符)
    argv := Argv4 { a = "/bin/sh", b = "-c", c = cmd, d = 0 };
    syscall3(59, "/bin/sh", argv, 0);  // execve — 成功则不返回
    syscall3(60, 127, 0, 0);  // execve 失败时 _exit(127)
    return -1;
}

// get_env(name) — 读取环境变量
// 从 /proc/self/environ 中读取指定环境变量的值
// 返回：变量值字符串，未找到返回 ""
fn get_env(name: string) -> string {
    env := read_file("/proc/self/environ");
    if str_len(env) == 0 { return ""; }
    elen := str_len(env);
    i : ., mut = 0;
    loop {
        if i >= elen { break; }
        eq_pos : ., mut = -1;
        j : ., mut = i;
        loop {
            if j >= elen { break; }
            c := load8(env, j);
            if c == 61 { eq_pos = j; break; }  // '='
            if c == 0 { break; }  // null 分隔符
            j = j + 1;
        }
        if eq_pos >= 0 {
            key_len := eq_pos - i;
            nlen := str_len(name);
            if key_len == nlen {
                is_match : ., mut = 1;
                ki : ., mut = 0;
                loop {
                    if ki >= key_len { break; }
                    if load8(env, i + ki) != load8(name, ki) { is_match = 0; break; }
                    ki = ki + 1;
                }
                if is_match != 0 {
                    val_start := eq_pos + 1;
                    val_end : ., mut = val_start;
                    loop {
                        if val_end >= elen { break; }
                        if load8(env, val_end) == 0 { break; }
                        val_end = val_end + 1;
                    }
                    return str_sub(env, val_start, val_end - val_start);
                }
            }
        }
        while i < elen && load8(env, i) != 0 { i = i + 1; }
        i = i + 1;
    }
    return "";
}
