// 探针语料（判据 J3）：「**承重面**」——调用一个**只存在于索引**的名字。
// src/stdlib/io.cr 未声明 `print_int` ⇒ 无索引时前端响亮拒绝
// （`error[N06]: Undefined function 'print_int'`，rc=1，无产物）；有索引时 rc=0。
// ⇒ 本语料钉住「索引对索引独有名字是承重输入」这一面：修 #82 时**不得**把它砍掉。
//
// 注意：调用点用到的名字本就该进产物（IR_CALL 的 callee 名），故本语料**不是**「未引用不物化」
// 的判据对象——那条由 io.index 档下的 generics_test 承担（判据 J1/J2）。
import io

fn main() -> int {
    print_int(42);
    return 0;
}
