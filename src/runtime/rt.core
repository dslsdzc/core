// rt.core — Core runtime library
// Replaces compiler_rt.c with pure Core code using __builtin_syscall3,
// __builtin_load8, __builtin_store8, and __builtin_alloc.
//
// Memory access primitives (inlined by backends):
//   __builtin_load8(ptr: string, idx: int) -> int
//   __builtin_store8(ptr: string, idx: int, val: int) -> int
// Syscall (inlined by backends):
//   __builtin_syscall3(nr: int, arg1: int, arg2: int, arg3: int) -> int
// Provided by rt.s (assembly):
//   __builtin_alloc(size: int) -> string
//   __builtin_get_arg(n: int) -> string

// --- String length ---

fn __builtin_str_len(s: string) -> int {
    i : ., mut = 0;
    loop {
        c := __builtin_load8(s, i);
        if c == 0 { return i; }
        i = i + 1;
    }
    return 0;
}

// --- Character access ---

fn __builtin_str_get(s: string, idx: int) -> string {
    len := __builtin_str_len(s);
    if idx < 0 || idx >= len { return ""; }
    c := __builtin_load8(s, idx);
    res := __builtin_alloc(2);
    __builtin_store8(res, 0, c);
    __builtin_store8(res, 1, 0);
    return res;
}

// --- Substring ---

fn __builtin_str_sub(s: string, start: int, len: int) -> string {
    slen := __builtin_str_len(s);
    if start < 0 || start >= slen { return ""; }
    actual_len : ., mut = len;
    if start + actual_len > slen { actual_len = slen - start; }
    if actual_len <= 0 { return ""; }
    res := __builtin_alloc(actual_len + 1);
    i : ., mut = 0;
    loop {
        if i >= actual_len { break; }
        c := __builtin_load8(s, start + i);
        __builtin_store8(res, i, c);
        i = i + 1;
    }
    __builtin_store8(res, actual_len, 0);
    return res;
}

// --- String equality ---

fn __builtin_str_eq(a: string, b: string) -> int {
    i : ., mut = 0;
    loop {
        ca := __builtin_load8(a, i);
        cb := __builtin_load8(b, i);
        if ca != cb { return 0; }
        if ca == 0 { return 1; }
        i = i + 1;
    }
    return 0;
}

// --- String comparison ---

fn __builtin_str_cmp(a: string, b: string) -> int {
    i : ., mut = 0;
    loop {
        ca := __builtin_load8(a, i);
        cb := __builtin_load8(b, i);
        if ca == 0 && cb == 0 { return 0; }
        if ca == 0 { return -1; }
        if cb == 0 { return 1; }
        if ca < cb { return -1; }
        if ca > cb { return 1; }
        i = i + 1;
    }
    return 0;
}

// --- String concatenation ---

fn __builtin_str_push(a: string, b: string) -> string {
    lena := __builtin_str_len(a);
    lenb := __builtin_str_len(b);
    res := __builtin_alloc(lena + lenb + 1);
    i : ., mut = 0;
    loop {
        if i >= lena { break; }
        c := __builtin_load8(a, i);
        __builtin_store8(res, i, c);
        i = i + 1;
    }
    j : ., mut = 0;
    loop {
        if j >= lenb { break; }
        c := __builtin_load8(b, j);
        __builtin_store8(res, lena + j, c);
        j = j + 1;
    }
    __builtin_store8(res, lena + lenb, 0);
    return res;
}

// --- Integer to string ---

fn __builtin_int_to_str(n: int) -> string {
    if n == 0 { return "0"; }
    val : ., mut = n;
    neg : ., mut = 0;
    if val < 0 { neg = 1; val = -val; }

    // Count digits
    tmp : ., mut = val;
    ndigits : ., mut = 0;
    loop {
        ndigits = ndigits + 1;
        tmp = tmp / 10;
        if tmp == 0 { break; }
    }

    extra : ., mut = neg;
    buf := __builtin_alloc(ndigits + extra + 1);
    end : ., mut = ndigits;
    pos : ., mut = ndigits - 1;

    // Write digits from right to left
    loop {
        rem := val % 10;
        __builtin_store8(buf, pos, rem + 48);
        val = val / 10;
        if pos == 0 { break; }
        pos = pos - 1;
    }

    // Write negative sign if needed
    if neg == 1 {
        // Shift all chars right by 1
        k : ., mut = ndigits;
        loop {
            if k == 0 { break; }
            ci := __builtin_load8(buf, k - 1);
            __builtin_store8(buf, k, ci);
            k = k - 1;
        }
        __builtin_store8(buf, 0, 45);
        end = end + 1;
    }
    __builtin_store8(buf, end, 0);
    return buf;
}

fn __builtin_str_from_int(i: int) -> string {
    return __builtin_int_to_str(i);
}

// --- String to integer ---

fn __builtin_str_to_int(s: string) -> int {
    slen := __builtin_str_len(s);
    if slen == 0 { return 0; }
    i : ., mut = 0;
    neg : ., mut = 0;
    c0 := __builtin_load8(s, 0);
    if c0 == 45 {  // '-'
        neg = 1;
        i = 1;
    }
    res : ., mut = 0;
    loop {
        if i >= slen { break; }
        c := __builtin_load8(s, i);
        if c < 48 || c > 57 { break; }  // not a digit
        res = res * 10 + (c - 48);
        i = i + 1;
    }
    if neg == 1 { return -res; }
    return res;
}

// --- Print to stdout ---

fn __builtin_print(s: string) -> unit {
    slen := __builtin_str_len(s);
    r1 := __builtin_syscall3(1, 1, s, slen);  // write(1, s, len)
    return;
}

fn __builtin_println(s: string) -> unit {
    slen := __builtin_str_len(s);
    r1 := __builtin_syscall3(1, 1, s, slen);  // write(1, s, len)
    r2 := __builtin_syscall3(1, 1, "\n", 1);  // write(1, "\n", 1)
    return;
}

// --- File I/O ---

fn __builtin_read_file(path: string) -> string {
    fd := __builtin_syscall3(2, path, 0, 0);  // open(path, O_RDONLY, 0)
    if fd < 0 { return ""; }
    fsize := __builtin_syscall3(8, fd, 0, 2);  // lseek(fd, 0, SEEK_END)
    if fsize < 0 {
        r1 := __builtin_syscall3(3, fd, 0, 0);  // close(fd)
        return "";
    }
    r1 := __builtin_syscall3(8, fd, 0, 0);  // lseek(fd, 0, SEEK_SET)
    buf := __builtin_alloc(fsize + 1);
    nread := __builtin_syscall3(0, fd, buf, fsize);  // read(fd, buf, size)
    r2 := __builtin_syscall3(3, fd, 0, 0);  // close(fd)
    if nread > 0 {
        __builtin_store8(buf, nread, 0);
    }
    return buf;
}

fn __builtin_write_file(path: string, content: string) -> int {
    fd := __builtin_syscall3(2, path, 577, 420);  // open O_WRONLY|O_CREAT|O_TRUNC, 0644
    if fd < 0 { return -1; }
    clen := __builtin_str_len(content);
    nwritten := __builtin_syscall3(1, fd, content, clen);  // write(fd, content, len)
    r1 := __builtin_syscall3(3, fd, 0, 0);  // close(fd)
    return nwritten;
}
