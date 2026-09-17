import io

struct Point { x: int, y: int }

fn test_fields_basic() -> int {
    flds := @fields(Point);
    // check flds contains field names
    // @fields 实现 = **逗号拼接、无尾分隔**（ir_gen.cr 的 `fields` 分支：`if fi > 0 { + "," }`）
    // ⇒ Point{x,y} 得 "x,y" = **3 字符**。原判据 `< 4` 是对「逗号+空格」格式的旧期望（成文时点已不可考），
    // 现按实测格式钉死为 `!= 3`（**强于** `>= 3`：3 字符的垃圾串也能骗过下界）。
    if str_len(flds) != 3 { return 1; }
    return 0;
}

fn main() -> int {
    r7 := test_fields_basic();  if r7 != 0 { print("FAIL fields: "); println(int_str(r7)); return r7; }
    println("ALL PASS");
    return 0;
}
