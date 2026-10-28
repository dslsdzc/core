fn main() -> int:
    arr := [1, 2]
    p := (&arr[1]) cast *[int; 2]
    wide := *p
    return 0
