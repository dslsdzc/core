// cli.cr 值面 e2e（2(a) 视图内建批补网）。
//
// 为什么有这一档：2(a) 计划 §2.3 实测 `grep -rln "cli_cmd\|cli_flag" tests/ examples/` = **0**
// ⇒ cli.cr 的 29 个「裸字 ⇄ 串」视图点**值面零覆盖**——改完也无从分辨「修好了」与「没测到」。
// 本档把注册（`@ptr_of` 写裸字表）与帮助打印（`@str_of` 读裸字表）串成一条**运行值**判据：
// 断言在 `tests/selfhost/test_view_builtins.py` 的 cli 腿（逐子串 + rc），本档自身 rc=0。
//
// 运行面：**原生腿**（`corec build --static`）。解释器腿对本档**不适用**——
// 解释器对 `alloc`+`w64/r64` 的裸内存路径是「近似」（`interp.cr:719` 自注），
// 与 2(a) 无关（实测：无 unsafe、无视图的同形程序在两腿亦分歧，见计划 §7.3 记录）。
import cli
import io

fn main() -> int {
    cli_init("myprog", "my program");
    cli_cmd("build", "compile things");
    cli_cmd("cir", "show graph");
    cli_flag("output", "o", "out path");
    cli_flag_bool("verbose", "v", "more noise");

    // 查询面：`cli_get` 读回「value」槽（初值经 `@ptr_of("")` 写入）⇒ 必须是空串
    if cli_get("output") != "" { return 11; }
    // `cli_has` 读 has_value 槽（int 语义，不经视图）⇒ 未解析前 = 0
    if cli_has("output") != 0 { return 12; }
    // 不存在旗标 ⇒ -1 分支（走 `_cli_find_flag` 的视图比较路径）
    if cli_has("nope") != 0 { return 13; }

    cli_help();
    return 0;
}
