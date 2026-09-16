// apx（dex）形式转换缺口族——**suite 常规腿**（apx 批 T5；run_suite 每档独立 build+run）
//
// 与 py 套件 `tests/selfhost/test_apx_conversion.py` 的分工：本档是**常规语料腿**（走
// `src/ci/run.sh` 的 suite job），只放**已绿**形态；负例/哨兵/自证在 py 套件里
// （suite 档跑红会拖挂整个 suite job）。
//
// 判据：全部经 **`@raw_int`** 锚定 scaled 整数（唯一显式形式通道）——不直接比 decimal，
// 否则会踩 TODO #2026-09-16-30（apx 字面量走 lexer 位模式，~2ulp 截断；与聚合槽里的精确 scaled 值
// 在 binary64 下可不相等）。
//
// 两条硬约束（见 py 套件头注）：涉全局探针**必须 `mut`**；apx 探针**一律显式形**
// `d : dex, apx = …`（类型位写 `.` 会让 apx 槽压根不建立 ⇒ 假绿）。
import dex

struct S3 { f: dex }

impl S3 {
    fn m(self: S3, x: dex) -> int { return @raw_int(x) / 1000000; }
}

fn scaled7() -> dex { return 7.0; }
g_apx : dex, apx, mut = scaled7();
g_exact : dex, mut = scaled7();

fn main() -> int {
    // 1. 方法调用实参（TODO #2026-09-16-17 原形）
    d : dex, apx = 7.0;
    s : ., mut = S3 { f = 0.0 };
    if s.m(d) != 7 { return 1; }

    // 2. 模块限定调用（apx 批 T2 新增活点；与直调同值对拍）
    //    ⚠ **必须先绑定到变量**：模块限定调用**直接作实参**（`str_eq(m.f(x), "y")`）在
    //    本批起点即 **SIGSEGV 139**——**既有缺陷，非本批引入**（T3/T5 实测：T3 二进制、
    //    预变更二进制、**冻结基线 97f4394f** 三者同崩）⇒ 见 TODO #2026-09-16-31；本档走绑定形。
    ma := dex.dex_str(d);
    me := dex_str(d);
    if !str_eq(ma, me) { return 2; }
    if !str_eq(ma, "7") { return 3; }

    // 3. 结构体字面量字段 + 字段赋值
    f1 : ., mut = S3 { f = d };
    if @raw_int(f1.f) / 1000000 != 7 { return 4; }
    f1.f = d;
    if @raw_int(f1.f) / 1000000 != 7 { return 5; }

    // 4. 数组字面量元素 + 动态下标赋值
    a : [dex; 2] = [d, 1.0];
    if @raw_int(a[0]) / 1000000 != 7 { return 6; }
    i : ., mut = 1;
    a[i] = d;
    if @raw_int(a[i]) / 1000000 != 7 { return 7; }

    // 5. 元组元素（数字下标须写 `t . 0`，带空格）
    t := (d, 1.0);
    if @raw_int(t . 0) / 1000000 != 7 { return 8; }

    // 6. 指针写
    px : dex, mut = 1.0;
    p := &px;
    *p = d;
    if @raw_int(px) / 1000000 != 7 { return 9; }

    // 7. 全局运行期初值（⑦a；apx 全局须 mut）
    if @raw_int(g_apx) / 1000000 != 7 { return 10; }
    if @raw_int(g_exact) / 1000000 != 7 { return 11; }

    // 8. 全局作方法实参（全局 vs 局部同形对拍）
    if s.m(g_apx) != 7 { return 12; }

    // 9. 比较点声明面查表（L10）：聚合读 vs 精确值
    e : dex = 7.0;
    s9 : ., mut = S3 { f = 7.0 };
    if s9.f != e { return 13; }

    // 10. 枚举载荷
    if payload7(d) != 7 { return 14; }

    // 11. 非回归：直调 + 泛型实例化 dex 形参
    if direct7(d) != 7 { return 15; }
    if generic7(1, d) != 7 { return 16; }

    return 0;
}

enum E1 { V(dex) }

fn payload7(d: dex) -> int {
    e := V(d);
    return match e { V(x) => { return @raw_int(x) / 1000000; } };
}

fn direct7(x: dex) -> int { return @raw_int(x) / 1000000; }

fn generic7[T](t: T, x: dex) -> int { return @raw_int(x) / 1000000; }
