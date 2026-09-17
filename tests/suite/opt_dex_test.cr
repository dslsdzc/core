// 可选 dex（`dex?`）整族 —— **suite 常规腿**（批 5；run_suite 每档独立 build+run）
//
// 与 py 套件 `tests/selfhost/test_opt_dex.py` 的分工：本档是**常规语料腿**（走 `src/ci/run.sh`
// 的 suite job），只放**修后应绿**的正例（RED 基线 / 禁第三态纪律 / 编译期拒绝面 / apx 槽自证
// 在 py 套件里——suite 档跑红会拖挂整个 suite job）。
//
// 判据：全部经 **`@raw_int`** 锚定（唯一显式形式通道）——7.0 的 scaled 表示 7000000 / 10^6 == 7。
// 不直接比 decimal，否则踩 TODO #2026-09-16-30（apx 字面量走 lexer 位模式，~2ulp 截断）。
//
// 两条硬约束（见 py 套件头注）：
//   ① 涉全局探针**必须 `mut`**（否则被 find_global_const_node 折叠成 IR_CONST ⇒ 读点不碰全局行 ⇒ 假绿）；
//   ② apx 源**一律显式形** `d : dex, apx = 7.0`（类型位写 `.` ⇒ declared_ti 落 TI_UNIT ⇒ apx 槽不建立 ⇒ 假绿）。
//
// 返回码约定：0 = 全过；非 0 = **首个失败面的编号**（便于定位；逐个面独立成函数）。

g : dex?, mut = None;

struct SOpt { f: dex? }

enum EOpt { V(dex?) }

fn four_bare_bits() -> int {
    d : dex, apx = 7.0;
    x : dex? = d;
    return match x { Some(v) => { return @raw_int(v) / 1000000; } None => { return 0; } };
}

fn four_bare_scaled() -> int {
    e : dex = 7.0;
    x : dex? = e;
    return match x { Some(v) => { return @raw_int(v) / 1000000; } None => { return 0; } };
}

fn four_boxed_bits() -> int {
    d : dex, apx = 7.0;
    x : dex? = Some(d);
    return match x { Some(v) => { return @raw_int(v) / 1000000; } None => { return 0; } };
}

fn four_boxed_scaled() -> int {
    e : dex = 7.0;
    x : dex? = Some(e);
    return match x { Some(v) => { return @raw_int(v) / 1000000; } None => { return 0; } };
}

fn assign_bits() -> int {
    d : dex, apx = 7.0;
    x : dex?, mut = None;
    x = d;
    return match x { Some(v) => { return @raw_int(v) / 1000000; } None => { return 0; } };
}

fn ptr_write_bits() -> int {
    d : dex, apx = 7.0;
    x : dex?, mut = None;
    p := &x;
    *p = d;
    return match *p { Some(v) => { return @raw_int(v) / 1000000; } None => { return 0; } };
}

fn addr_taken_bits() -> int {
    d : dex, apx = 7.0;
    x : dex? = d;
    p := &x;
    return match *p { Some(v) => { return @raw_int(v) / 1000000; } None => { return 0; } };
}

fn ret_bits() -> int {
    d : dex, apx = 7.0;
    x : dex? = d;
    y := x?;
    return @raw_int(y) / 1000000;
}

fn field_lit_bits() -> int {
    d : dex, apx = 7.0;
    s : ., mut = SOpt { f = d };
    return match s.f { Some(v) => { return @raw_int(v) / 1000000; } None => { return 0; } };
}

fn field_assign_bits() -> int {
    d : dex, apx = 7.0;
    s : ., mut = SOpt { f = None };
    s.f = d;
    return match s.f { Some(v) => { return @raw_int(v) / 1000000; } None => { return 0; } };
}

fn global_bits() -> int {
    d : dex, apx = 7.0;
    g = d;
    return match g { Some(v) => { return @raw_int(v) / 1000000; } None => { return 0; } };
}

fn enum_payload_bits() -> int {
    d : dex, apx = 7.0;
    e := V(d);
    return match e {
        V(x) => { return match x { Some(v) => { return @raw_int(v) / 1000000; } None => { return 0; } }; }
    };
}

fn param_scaled_ctl() -> int {
    e : dex = 7.0;
    return take_opt(e);
}

fn take_opt(x: dex?) -> int {
    return match x { Some(v) => { return @raw_int(v) / 1000000; } None => { return 0; } };
}

fn nonopt_direct_bits() -> int {
    d : dex, apx = 7.0;
    return take_plain(d);
}

fn take_plain(x: dex) -> int { return @raw_int(x) / 1000000; }

fn main() -> int {
    if four_bare_bits() != 7 { return 1; }
    if four_bare_scaled() != 7 { return 2; }
    if four_boxed_bits() != 7 { return 3; }
    if four_boxed_scaled() != 7 { return 4; }
    if assign_bits() != 7 { return 5; }
    if ptr_write_bits() != 7 { return 6; }
    if addr_taken_bits() != 7 { return 7; }
    if ret_bits() != 7 { return 8; }
    if field_lit_bits() != 7 { return 9; }
    if field_assign_bits() != 7 { return 10; }
    if global_bits() != 7 { return 11; }
    if enum_payload_bits() != 7 { return 12; }
    if param_scaled_ctl() != 7 { return 13; }
    if nonopt_direct_bits() != 7 { return 14; }
    return 0;
}
