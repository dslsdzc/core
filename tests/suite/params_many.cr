// TODO #8 收口（波 1 Task 5 Minor 4）：≥18 形参静默误编译修复后的 runtime 用例。
//
// 修复前 ≥18 形参的函数在 .ccr 中 name_idx=0/param_count=0（FuncInfo 形参槽区
// 16 槽被无界写越界踩掉 return_type/ast_node），同源 checker 发 TF01 误归、IR
// 体丢失而 corec build 仍 rc=0 —— 即本文件在修复前不可能有 runtime 覆盖。
//
// 覆盖形：
//   * 18 形参 = 6 寄存器参 + 12 栈参（跨过修复前的 16 槽边界）
//   * 22 形参 = 6 寄存器参 + 16 栈参 = 128B 栈清理（> 127B ⇒ add rsp, imm32
//     7B 形；imm8 形编码不下，此形修复前结构不可达 = Minor 4 的收口条件）
//
// 判据：main rc=0（逐形参值全对；任一错位返回该参数序号+1 便于定位）。
// 运行：./build/corec build tests/suite/params_many.cr -o /tmp/pm --static && /tmp/pm

fn check18(a0: int, a1: int, a2: int, a3: int, a4: int, a5: int, a6: int, a7: int, a8: int, a9: int, a10: int, a11: int, a12: int, a13: int, a14: int, a15: int, a16: int, a17: int) -> int {
    if a0 != 1 { return 1; }
    if a1 != 2 { return 2; }
    if a2 != 3 { return 3; }
    if a3 != 4 { return 4; }
    if a4 != 5 { return 5; }
    if a5 != 6 { return 6; }
    if a6 != 7 { return 7; }
    if a7 != 8 { return 8; }
    if a8 != 9 { return 9; }
    if a9 != 10 { return 10; }
    if a10 != 11 { return 11; }
    if a11 != 12 { return 12; }
    if a12 != 13 { return 13; }
    if a13 != 14 { return 14; }
    if a14 != 15 { return 15; }
    if a15 != 16 { return 16; }
    if a16 != 17 { return 17; }
    if a17 != 18 { return 18; }
    return 0;
}

fn check22(a0: int, a1: int, a2: int, a3: int, a4: int, a5: int, a6: int, a7: int, a8: int, a9: int, a10: int, a11: int, a12: int, a13: int, a14: int, a15: int, a16: int, a17: int, a18: int, a19: int, a20: int, a21: int) -> int {
    if a0 != 1 { return 1; }
    if a1 != 2 { return 2; }
    if a2 != 3 { return 3; }
    if a3 != 4 { return 4; }
    if a4 != 5 { return 5; }
    if a5 != 6 { return 6; }
    if a6 != 7 { return 7; }
    if a7 != 8 { return 8; }
    if a8 != 9 { return 9; }
    if a9 != 10 { return 10; }
    if a10 != 11 { return 11; }
    if a11 != 12 { return 12; }
    if a12 != 13 { return 13; }
    if a13 != 14 { return 14; }
    if a14 != 15 { return 15; }
    if a15 != 16 { return 16; }
    if a16 != 17 { return 17; }
    if a17 != 18 { return 18; }
    if a18 != 19 { return 19; }
    if a19 != 20 { return 20; }
    if a20 != 21 { return 21; }
    if a21 != 22 { return 22; }
    return 0;
}

fn main() -> int {
    r18 := check18(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18);
    if r18 != 0 { return r18; }
    r22 := check22(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22);
    if r22 != 0 { return 40 + r22; }
    return 0;
}
