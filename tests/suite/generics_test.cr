// Generics test suite
// Tests generic functions, generic structs, and multi-param generics.
// Note: testing is done inline in main() to avoid a pre-existing ELF backend issue
// with non-generic user functions called from main.

import io
import fmt

// === Generic function: identity[T] ===

fn identity[T](x: T) -> T:
    return x

// === Generic struct: Box[T] ===

struct Box[T]:
    val: T

// === Function on generic struct ===

fn get_val[T](b: Box[T]) -> T:
    return b.val

// === Multi-param generic function ===

fn pair[A, B](a: A, b: B) -> int:
    if a != 1:
        return 1
    if str_len(b) < 1:
        return 1
    return 0

// === Main: run all tests inline ===

fn main() -> int:
    // Test 1: Generic identity with int
    r1 := identity(42)
    if r1 != 42:
        print("FAIL identity_int: ")
        println(int_str(r1))
        return 1
    println("PASS identity_int")

    // Test 2: Generic identity with string
    r2 := identity("hello")
    if str_len(r2) != 5:
        print("FAIL identity_str: ")
        println(int_str(str_len(r2)))
        return 2
    println("PASS identity_str")

    // Test 3: Generic struct Box with int
    b1 := Box { val = 100 }
    if b1.val != 100:
        print("FAIL box_int: ")
        println(int_str(b1.val))
        return 3
    println("PASS box_int")

    // Test 4: Generic struct Box with string
    b2 := Box { val = "world" }
    if str_len(b2.val) != 5:
        print("FAIL box_str: ")
        println(int_str(str_len(b2.val)))
        return 4
    println("PASS box_str")

    // Test 5: Function on generic struct (type inference from argument)
    b3 := Box { val = 42 }
    v5 := get_val(b3)
    if v5 != 42:
        print("FAIL get_val_int: ")
        println(int_str(v5))
        return 5
    println("PASS get_val_int")

    // Test 6: Function on generic struct with string type
    b4 := Box { val = "hello" }
    v6 := get_val(b4)
    if str_len(v6) != 5:
        print("FAIL get_val_str: ")
        println(int_str(str_len(v6)))
        return 6
    println("PASS get_val_str")

    // Test 7: Multi-param generic function
    r7 := pair(1, "two")
    if r7 != 0:
        print("FAIL multi_param: ")
        println(int_str(r7))
        return 7
    println("PASS multi_param")

    // Test 8: Generic identity with bool
    r8 := identity(true)
    if r8 != true:
        print("FAIL identity_bool")
        return 8
    println("PASS identity_bool")

    println("ALL PASS")
    return 0
