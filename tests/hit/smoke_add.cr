// === tests/hit/smoke_add.cr ===
// HIT M1 冒烟：减法（sub 事件直通；const 走常量池 load）。期望 exit 2（7-5）。
fn main() -> int {
    a := 7;
    b := 5;
    return a - b;
}
