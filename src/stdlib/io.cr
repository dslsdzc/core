// Core standard library: I/O output.

fn print(s: string) {
    slen := str_len(s);
    r1 := syscall3(1, 1, s, slen);  // write(1, s, len)
    return;
}

fn println(s: string) {
    slen := str_len(s);
    r1 := syscall3(1, 1, s, slen);  // write(1, s, len)
    r2 := syscall3(1, 1, "\n", 1);  // write(1, "\n", 1)
    return;
}

fn print_int(n: int) {
    print(int_str(n));
}

fn println_int(n: int) {
    println(int_str(n));
}

fn read_file(path: string) -> string {
    fd := syscall3(2, path, 0, 0);  // open(path, O_RDONLY, 0)
    if fd < 0 { return ""; }
    fsize := syscall3(8, fd, 0, 2);  // lseek(fd, 0, SEEK_END)
    if fsize < 0 {
        r1 := syscall3(3, fd, 0, 0);  // close(fd)
        return "";
    }
    r1 := syscall3(8, fd, 0, 0);  // lseek(fd, 0, SEEK_SET)
    buf := alloc(fsize + 1);
    nread := syscall3(0, fd, buf, fsize);  // read(fd, buf, size)
    r2 := syscall3(3, fd, 0, 0);  // close(fd)
    if nread > 0 {
        store8(buf, nread, 0);
    }
    return buf;
}

fn write_file(path: string, content: string) -> int {
    fd := syscall3(2, path, 577, 420);  // open O_WRONLY|O_CREAT|O_TRUNC, 0644
    if fd < 0 { return -1; }
    clen := str_len(content);
    nwritten := syscall3(1, fd, content, clen);  // write(fd, content, len)
    r1 := syscall3(3, fd, 0, 0);  // close(fd)
    return nwritten;
}
