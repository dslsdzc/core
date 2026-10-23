fn main() -> int:
    arr := [10, 20, 30, 40, 50]

    // &arr[i] and deref
    p := &arr[2]
    if *p != 30:
        return 1

    // &x and deref
    x : ., mut = 42
    q := &x
    *q = 99
    if x != 99:
        return 2

    return 0
