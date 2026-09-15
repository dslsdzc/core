// 全局行 operand seam 回归语料（2026-09-16 批；run_suite 逐档 build + run ⇒ 期望 rc=0）。
// 覆盖：B1 IR_BINARY(TI_DEX) 全局操作数 · B2 IR_I2F 全局源 · B4 IR_SLICE 全局数组/低界 ·
//       B5 IR_AWAIT 全局源（全部 = 修复前 ELF 侧静默错值/139 的形态；逐点局部对照见
//       tests/selfhost/test_global_seams.py）。
// 两条硬约束（改动本档前必读）：
//   ① 必须以 **mut 全局**表达被测形态——`find_global_const_node`（ir_gen.cr:592-611）把
//      「不可变 + 字面量初值」的全局折叠成 IR_CONST ⇒ 读点不碰全局行、探针不触达被测面。
//   ② apx 算术**无解释器腿**（`corec run` 显式拒收 rc=255，能力边界非缺陷）⇒ 本档只走 ELF 腿。

g1_neg : dex, apx, mut = -100.0;
g1_pos : dex, apx, mut = 100.0;
g2 : dex, mut = -100.0;
g4 : [int;4] = [10, 20, 30, 40];
lo : int, mut = 1;
g5 : int, mut = 5;

fn main() -> int {
    // B1（IR_BINARY TI_DEX 双操作数）：负号全局判真 ⇒ 错；正号全局判负 ⇒ 错
    if g1_neg > 0.0 { return 1; }
    if g1_pos < 0.0 { return 2; }
    // B2（IR_I2F 全局源，scaled → apx）：负号全局经转换后判真 ⇒ 错
    d : dex, apx = g2;
    if d > 0.0 { return 3; }
    // B4（IR_SLICE 数组指针 + 低界，两端皆全局）：g4[lo..3] 首元素 = 20
    s := g4[lo..3];
    if s[0] != 20 { return 4; }
    // B5（IR_AWAIT 全局源）：运行期赋值 9 ⇒ 读回 9（不可折叠）
    g5 = 9;
    x := await g5;
    if x != 9 { return 5; }
    return 0;
}
