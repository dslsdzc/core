// test_json.cr —— json.cr 自断言测试（TDD，Task 1）
// 运行：./build/corec build src/lsp/test_json.cr -o /tmp/test_json --static && /tmp/test_json
// 用例（brief Step 4）：
//   1) 往返：{"a": 1, "b": [true, null, "x"]} → stringify == 规范紧凑形式
//   2) 三层嵌套对象/数组
//   3) 字符串转义 "a\"b\\c\nd" 往返 + \uXXXX 往返
//   4) json_obj_get 链式取值
//   5) 错误输入 { [1, "abc 123abc 空串 → parse 返回 -1
//   6) 数字 -42 → J_NUM a=-42

import json
import fmt
import io

g_fail_count : int, mut = 0

fn t_expect(cond: bool, name: string):
    if !cond:
        print("FAIL: ")
        println(name)
        g_fail_count = g_fail_count + 1
    else:
        print("ok: ")
        println(name)

// 解析 + 序列化往返：输出须等于规范紧凑形式
fn check_roundtrip(text: string, canonical: string):
    idx := json_parse(text)
    t_expect(idx >= 0, "parse: " + text)
    if idx >= 0:
        out := json_stringify(idx)
        t_expect(str_eq(out, canonical) != 0, "stringify == canonical")
        if str_eq(out, canonical) == 0:
            print("  got: ")
            println(out)

// 非法输入必须返回 -1
fn check_bad(text: string):
    idx := json_parse(text)
    t_expect(idx < 0, "bad input rejected: " + text)

fn main() -> int:
    // 1. 往返：对象 + 数组 + 字面量
    check_roundtrip("{\"a\": 1, \"b\": [true, null, \"x\"]}",
        "{\"a\":1,\"b\":[true,null,\"x\"]}")

    // 2. 三层嵌套对象/数组
    check_roundtrip("{\"a\": {\"b\": {\"c\": [1, 2, [3, 4]]}}}",
        "{\"a\":{\"b\":{\"c\":[1,2,[3,4]]}}}")

    // 3. 字符串转义往返：\" \\ \n
    check_roundtrip("\"a\\\"b\\\\c\\nd\"", "\"a\\\"b\\\\c\\nd\"")
    // \uXXXX：解析为码点，序列化输出大写十六进制
    check_roundtrip("\"\\u4e2d\\u00e9\"", "\"\\u4E2D\\u00E9\"")
    // UTF-16 surrogate pair becomes one Unicode scalar and round-trips in
    // the canonical JSON form.
    check_roundtrip("\"\\uD83D\\uDE00\"", "\"\\uD83D\\uDE00\"")
    check_roundtrip("\"a\\b\\f\\/\"", "\"a\\u0008\\u000C/\"")

    // 4. json_obj_get：{"position": {"line": 3, "character": 7}} 取 line → 3
    root := json_parse("{\"position\": {\"line\": 3, \"character\": 7}}")
    t_expect(root >= 0, "obj_get: parse")
    pos := json_obj_get(root, "position")
    t_expect(pos >= 0, "obj_get: position found")
    ln := json_obj_get(pos, "line")
    t_expect(ln >= 0 && json_get(ln, 0) == J_NUM && json_get(ln, 1) == 3,
        "obj_get: line == 3")
    t_expect(json_obj_get(root, "nope") < 0, "obj_get: missing key -> -1")

    // 5. 错误输入：{  [1,  "abc  123abc  空串
    check_bad("{")
    check_bad("[1,")
    check_bad("\"abc")
    check_bad("123abc")
    check_bad("")

    // 6. 数字：-42 → J_NUM a=-42
    n := json_parse("-42")
    t_expect(n >= 0 && json_get(n, 0) == J_NUM && json_get(n, 1) == -42,
        "num: -42 -> J_NUM a=-42")
    t_expect(str_eq(json_stringify(n), "-42") != 0, "stringify: -42")

    // JSON object keys are last-wins, and signed 64-bit boundaries are valid.
    dup := json_parse("{\"x\":1,\"x\":2}")
    dx := json_obj_get(dup, "x")
    t_expect(dx >= 0 && json_get(dx, 1) == 2, "obj_get: duplicate key last wins")
    min_i64 := json_parse("-9223372036854775808")
    max_i64 := json_parse("9223372036854775807")
    t_expect(min_i64 >= 0 && json_get(min_i64, 1) == -9223372036854775808,
        "num: INT64_MIN accepted")
    t_expect(max_i64 >= 0 && json_get(max_i64, 1) == 9223372036854775807,
        "num: INT64_MAX accepted")
    check_bad("9223372036854775808")
    check_bad("-9223372036854775809")
    check_bad("01")
    check_bad("\"\\uD800\"")

    // Excessive nesting must fail without exhausting the native call stack.
    nested : string, mut = "0"
    ni : ., mut = 0
    loop:
        if ni >= 130:
            break
        nested = "[" + nested + "]"
        ni = ni + 1
    check_bad(nested)

    // 7. json_array_get：下标访问 + 越界
    a := json_parse("[10, 20]")
    e0 := json_array_get(a, 0)
    t_expect(e0 >= 0 && json_get(e0, 0) == J_NUM && json_get(e0, 1) == 10,
        "array_get: [0] == 10")
    e1 := json_array_get(a, 1)
    t_expect(e1 >= 0 && json_get(e1, 1) == 20, "array_get: [1] == 20")
    t_expect(json_array_get(a, 2) < 0, "array_get: out of bounds -> -1")

    if g_fail_count == 0:
        println("ALL TESTS PASSED")
        return 0
    print("FAILURES: ")
    println(int_str(g_fail_count))
    return g_fail_count
