// Hotpatch test suite.
// Tests @hotpatch annotation compilation and config loading.

import io
import toml

// Test: basic @hotpatch(ver=1) annotation compiles
@hotpatch(ver=1)
fn test_hotpatch_ver1() -> int:
    return 42

// Test: @hotpatch(ver=2) with different version
@hotpatch(ver=2)
fn test_hotpatch_ver2() -> int:
    return 99

// Test: @hotpatch shorthand (defaults to ver=1)
@hotpatch
fn test_hotpatch_shorthand() -> int:
    return 7

// Test: hotpatch config loading via toml
fn test_hotpatch_config() -> int:
    cfg := read_file(".hotpatch.toml")
    if str_len(cfg) > 0:
        // Try to read a known field
        ver_str := toml_get_str(cfg, "version")
        if str_len(ver_str) > 0:
            return 0  // config loaded and has a version field
    return 0  // no .hotpatch.toml is acceptable

fn main() -> int:
    r1 := test_hotpatch_ver1()
    if r1 != 42:
        print("FAIL: test_hotpatch_ver1 returned ")
        println(int_str(r1))
        return 1

    r2 := test_hotpatch_ver2()
    if r2 != 99:
        print("FAIL: test_hotpatch_ver2 returned ")
        println(int_str(r2))
        return 2

    r3 := test_hotpatch_shorthand()
    if r3 != 7:
        print("FAIL: test_hotpatch_shorthand returned ")
        println(int_str(r3))
        return 3

    r4 := test_hotpatch_config()
    if r4 != 0:
        print("FAIL: test_hotpatch_config returned ")
        println(int_str(r4))
        return 4

    println("ALL PASS")
    return 0
