import io

fn f1(n: int) -> int {
    s : ., mut = 0;
    i : ., mut = 0;
    loop {
        if i >= n { break; }
        if i % 3 == 0 { s = s + i * 2; } else { s = s + 1; }
        i = i + 1;
    }
    return s;
}

fn f2(n: int) -> int {
    s : ., mut = 1;
    i : ., mut = 0;
    loop {
        if i >= n { break; }
        if i % 2 == 0 { s = s * 2; } else { s = s + 3; }
        i = i + 1;
    }
    return s;
}

fn f3(n: int) -> int {
    s : ., mut = 0;
    i : ., mut = 0;
    loop {
        if i >= n { break; }
        if i % 5 == 0 { s = s + 7; } else { s = s - 2; }
        i = i + 1;
    }
    return s;
}

fn f4(n: int) -> int {
    s : ., mut = 3;
    i : ., mut = 0;
    loop {
        if i >= n { break; }
        if i > 3 { s = s + i; } else { s = s * 2; }
        i = i + 1;
    }
    return s;
}

fn f5(n: int) -> int {
    s : ., mut = 0;
    i : ., mut = 0;
    loop {
        if i >= n { break; }
        if i % 4 == 1 { s = s + 11; } else { s = s - 5; }
        i = i + 1;
    }
    return s;
}

fn f6(n: int) -> int {
    s : ., mut = 2;
    i : ., mut = 0;
    loop {
        if i >= n { break; }
        if i % 3 == 2 { s = s - 6; } else { s = s + 13; }
        i = i + 1;
    }
    return s;
}

fn main() -> int {
    a := f1(10);
    b := f2(9);
    c := f3(8);
    d := f4(7);
    e := f5(6);
    f := f6(5);
    print("R=");
    println(int_str(a + b + c + d + e + f));
    return 0;
}
