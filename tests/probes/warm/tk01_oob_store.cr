fn main() -> int {
    arr := [1];
    p := &arr[0] + 1;
    *p = 2;
    return 0;
}
