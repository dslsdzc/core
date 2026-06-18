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
