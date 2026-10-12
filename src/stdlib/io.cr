// Core standard library: I/O.
// Python-style print/println (multi-arg, auto-conversion via int_str).
// Rust-style string interpolation via format() in fmt.cr.
// Note: depends on fmt.cr (str_len, int_str) — see stdlib/_import.cr or import fmt

fn print(s: string):
    slen := str_len(s)
    r1 := syscall3(1, 1, s, slen)  // write(1, s, len)
    return

fn println(s: string):
    slen := str_len(s)
    r1 := syscall3(1, 1, s, slen)  // write(1, s, len)
    r2 := syscall3(1, 1, "\n", 1)  // write(1, "\n", 1)
    return

fn print_i(n: int):
    print(int_str(n))

fn println_i(n: int):
    println(int_str(n))

fn read_file(path: string) -> string:
    fd := syscall3(2, path, 0, 0)  // open(path, O_RDONLY, 0)
    if fd < 0:
        return ""
    fsize := syscall3(8, fd, 0, 2)  // lseek(fd, 0, SEEK_END)
    if fsize < 0:
        r1 := syscall3(3, fd, 0, 0)  // close(fd)
        return ""
    if fsize == 0:
        // I-1：伪文件（/proc/self/environ 等）——procfs 的 lseek SEEK_END 恒返回
        // 0，长度不可信 → 循环读取直到 EOF。修复前 get_env("CORE_SAFE") 恒读
        // 空串 → CORE_SAFE=0 关检查的分支永不可达。正常文件的 lseek 行为不变。
        // 注意：不用 while 做增长（自托管 parser 对裸 while + 双标识符条件有
        // 预存崩溃——见波 3 报告 N2），用 loop+break 等价实现。
        r1 := syscall3(8, fd, 0, 0)  // lseek(fd, 0, SEEK_SET)
        cap : ., mut = 4096
        buf := alloc(cap)
        chunk := alloc(4096)
        blen : ., mut = 0
        loop:
            n := syscall3(0, fd, chunk, 4096)  // read(fd, chunk, 4096)
            if n <= 0:
                break
            if blen + n >= cap:
                cap2 : ., mut = cap
                loop:
                    if cap2 >= blen + n:
                        break
                    cap2 = cap2 * 2
                nb := alloc(cap2)
                _dyncpy(buf, blen, nb)
                buf = nb
                cap = cap2
            ci : ., mut = 0
            loop:
                if ci >= n:
                    break
                store8(buf, blen + ci, load8(chunk, ci))
                ci = ci + 1
            blen = blen + n
        r2 := syscall3(3, fd, 0, 0)  // close(fd)
        if blen <= 0:
            return ""
        return str_sub(buf, 0, blen)
    r1 := syscall3(8, fd, 0, 0)  // lseek(fd, 0, SEEK_SET)
    buf := alloc(fsize + 1)
    nread := syscall3(0, fd, buf, fsize)  // read(fd, buf, size)
    r2 := syscall3(3, fd, 0, 0)  // close(fd)
    if nread > 0:
        store8(buf, nread, 0)
    return buf

fn write_file(path: string, content: string) -> int:
    fd := syscall3(2, path, 577, 420)  // open O_WRONLY|O_CREAT|O_TRUNC, 0644
    if fd < 0:
        return -1
    clen := str_len(content)
    nwritten := syscall3(1, fd, content, clen)  // write(fd, content, len)
    r1 := syscall3(3, fd, 0, 0)  // close(fd)
    return nwritten
