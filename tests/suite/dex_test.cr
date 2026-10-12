// dex 精确运算测试（数值迁移 Task 4）——定点缩放（S = 10^6）精确语义
// 精确断言（binary64 做不到的）：0.1 + 0.2 == 0.3、3.14 + 2.86 == 6.0、1/10 打印 "0.1"
import io
import fmt
import dex

fn main() -> int:
    // 1. 精确加法：3.14 + 2.86 == 6.0
    a := 3.14 + 2.86
    if a != 6.0:
        print("FAIL 3.14+2.86: ")
        println(dex_str(a))
        return 1
    // 2. 0.1 + 0.2 == 0.3（精确——binary64 做不到）
    b := 0.1 + 0.2
    if b != 0.3:
        print("FAIL 0.1+0.2: ")
        println(dex_str(b))
        return 2
    // 3. 除法：1/10 = 0.1，打印 "0.1"
    c := 1.0 / 10.0
    if c != 0.1:
        print("FAIL 1/10: ")
        println(dex_str(c))
        return 3
    if !str_eq(dex_str(c), "0.1"):
        print("FAIL print 1/10: ")
        println(dex_str(c))
        return 4
    // 4. 乘法：1.5 * 2.0 == 3.0
    d := 1.5 * 2.0
    if d != 3.0:
        print("FAIL 1.5*2.0: ")
        println(dex_str(d))
        return 5
    // 5. 减法 + 负数：0.3 - 1.0 == -0.7
    e := 0.3 - 1.0
    if e != -0.7:
        print("FAIL 0.3-1.0: ")
        println(dex_str(e))
        return 6
    // 6. 打印去尾零：6.0 → "6"；0.10 → "0.1"；3.14 → "3.14"
    if !str_eq(dex_str(6.0), "6"):
        print("FAIL print 6.0: ")
        println(dex_str(6.0))
        return 7
    if !str_eq(dex_str(0.10), "0.1"):
        print("FAIL print 0.10: ")
        println(dex_str(0.10))
        return 8
    if !str_eq(dex_str(3.14), "3.14"):
        print("FAIL print 3.14: ")
        println(dex_str(3.14))
        return 9
    // 7. 整数参与：1 + 0.5 == 1.5
    f := 1 + 0.5
    if f != 1.5:
        print("FAIL 1+0.5: ")
        println(dex_str(f))
        return 10
    // 8. 变量运算
    g : dex = 0.1
    h : dex = 0.2
    if g + h != 0.3:
        print("FAIL var add: ")
        println(dex_str(g + h))
        return 11
    // 9. 函数边界：dex 参数/返回走精确形式（缩放整数）
    r := dex_add_fn(0.1, 0.2)
    if r != 0.3:
        print("FAIL fn dex: ")
        println(dex_str(r))
        return 12
    // 10. 1/3 判别子：定点 6 位（0.333333）≠ binary64（0.3333333333333333）
    q := 1.0 / 3.0
    if q != 0.3333333:
        print("FAIL 1/3: ")
        println(dex_str(q))
        return 13
    // 11. 模运算截断恒等式（5 指令序列 a - trunc(a/b)·b），含负数
    if 7.0 % 2.5 != 2.0:
        print("FAIL 7.0%2.5: ")
        println(dex_str(7.0 % 2.5))
        return 14
    if -7.0 % 2.5 != -2.0:
        print("FAIL -7.0%2.5: ")
        println(dex_str(-7.0 % 2.5))
        return 15
    if 1.0 % 0.3 != 0.1:
        print("FAIL 1.0%0.3: ")
        println(dex_str(1.0 % 0.3))
        return 16
    if -1.0 % 0.3 != -0.1:
        print("FAIL -1.0%0.3: ")
        println(dex_str(-1.0 % 0.3))
        return 17
    // 12. LET 边界转换（审查发现回归）：`y : dex = x`（x apx bits）→ y 存缩放形式
    x : dex, apx = 3.0
    y : dex = x
    if 1.0 / y != 0.3333333:
        print("FAIL LET apx->exact: ")
        println(dex_str(1.0 / y))
        return 18
    // 13. apx 跨函数边界（b1 调用点 + b2 返回点：bits → 定点 6 位）
    b1 := dex_double_fn(x)
    if b1 != 6.0:
        print("FAIL call-site bits->scaled: ")
        println(dex_str(b1))
        return 19
    b2 := dex_apx_ret_fn()
    if b2 != 0.5:
        print("FAIL return-site bits->scaled: ")
        println(dex_str(b2))
        return 20
    println("ALL PASS")
    return 0

fn dex_double_fn(a: dex) -> dex:
    return a * 2.0

fn dex_apx_ret_fn() -> dex:
    v : dex, apx = 1.0
    return v / 2.0

fn dex_add_fn(a: dex, b: dex) -> dex:
    return a + b
