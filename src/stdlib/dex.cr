// dex.cr — dex 定点缩放运算辅助（数值迁移 Task 4）
//
// ── 定点方案（执行时定稿，2026-08-16）──
//
// 表示：dex 值 = 缩放整数 int64，内部精度 S = 10^6（6 位小数）。
//   值 x 存为 x·S（如 3.14 → 3140000）。精确语义：0.1+0.2==0.3、
//   3.14+2.86==6.0 精确成立（binary64 做不到）。
//
// 运算（ir_gen 编译为缩放整数指令序列；本文件注释与编译器内 dex 分流注释同位）：
//   加/减：缩放整数直接加减（x1·S ± x2·S）
//   乘   ：(a·S × b·S)/S —— 中间值 a·b·S² ≤ 9.2e18 → |a|·|b| ≤ 9.2e6
//   除   ：(a·S × S)/(b·S) —— 中间值 a·S² ≤ 9.2e18 → |a| ≤ 9.2e6；结果向零截断
//   模   ：a mod b = a - trunc(a/b)·b（截断除法恒等式）
//   比较 ：缩放整数直接比较
//
// 溢出规则（int64 ±9.2e18，越界环绕——无陷阱，与 int 溢出一致）：
//   加减：|结果| ≤ 9.2e12；乘：|a|·|b| ≤ 9.2e6（如两者 ≤ 3033）；
//   除：|a| ≤ 9.2e6 且 b ≠ 0。
// 舍入规则：除法/模向零截断（与 cvttsd2si/IR_F2I 一致）；字面量第 7 位小数起
//   四舍五入（半进，lexer str_to_scaled）；打印去尾零。
//
// apx 分流：变量级 apx 标签（x : dex, apx）的运算走 binary64 快路径（现成
//   SSE2 浮点路径）；本模块的精确辅助不经 apx 路径。跨函数边界 dex 一律精确
//   形式（缩放整数）——apx 结果在边界按定点 6 位舍入（四舍五入半进，数值迁移
//   Task 6 定稿：bits→scaled 转换舍入而非截断；与字面量 str_to_scaled 半进一致）。
//
// apx 打印（Task 6 定稿 v1）：apx 变量经 dex_str 打印 = 6 位定点舍入——用户写
//   0.1 打印 "0.1"（非全精度 binary64 显示，也非截断出的 "0.099999"）。此舍入
//   同时吸收字面量转换（str_to_f64_bits）的 ~2ulp 截断误差（6 位打印精度下不可见）。
//   全精度打印（Ryu 式）留待后续版本。
//
// 解释器（corec run）无 binary64 语义：apx dex 运算的 I2F/F2I 转换显式报错
//   （Task 6：替代静默跳过，SIGFPE 防护）——apx 程序须 native 构建执行。
//
// @raw_int(v) 是显式转换：dex 表达式 → 其缩放整数原值（int）——本模块以此
//   访问原始整数做打印（纯整数运算，无 dex 运算溢出约束）。

// 定点 → 十进制字符串（去尾零）：3.14 → "3.14"、6.0 → "6"、0.1 → "0.1"
fn dex_str(v: dex) -> string:
    n : ., mut = @raw_int(v)    // 缩放整数原值
    neg : int = 0
    if n < 0:
        neg = 1
        n = 0 - n
    ip := n / 1000000           // 整数部分（int 截断除法）
    fp := n % 1000000           // 小数部分（缩放）
    s : ., mut = ""
    if neg != 0:
        s = "-"
    s = s + int_str(ip)
    if fp != 0:
        s = s + "."
        fs : ., mut = ""
        d : ., mut = fp
        k : ., mut = 100000
        loop:
            if k <= 0:
                break
            dg := d / k
            d = d - dg * k
            fs = fs + int_str(dg)
            k = k / 10
        // 去尾零
        li : ., mut = str_len(fs) - 1
        loop:
            if li < 0:
                break
            if load8(fs, li) != 48:
                break
            fs = str_sub(fs, 0, li)
            li = li - 1
        s = s + fs
    return s
