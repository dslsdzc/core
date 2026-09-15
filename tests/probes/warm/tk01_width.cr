fn main() -> int {
    arr := [1, 2];
    p := (&arr[1]) as *[int; 2];
    wide := *p;
    return 0;
}
