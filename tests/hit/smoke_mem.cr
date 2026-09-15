// === tests/hit/smoke_mem.cr ===
// HIT M1 冒烟：内存读写 + 加法链（add → sub 反减；store/load 事件）。
// 期望 exit 5（6+3=9，9-4=5）。
//
// 注（与 plan Task 4 草案差异）：原草案载体含 `a & b`（位与）——Core 源语言
// 无位与/位或运算符（& 为引用取址；&&/|| 恒短路分支化 = IR_BRANCH，超 M1 直线
// 子集），位与经 && 亦不可达 IR_BINARY(OP_AND)。载体改为链式加减 + 内存读写；
// and→nand 合成为 IR 层完备性代码（M2 位运算符落地后启用）。
fn main() -> int {
    a: ., mut = 6;
    b := 3;
    a = a + b;
    a = a - 4;
    return a;
}
