// === math.cr ===
// Core standard library — basic math functions.
//
// Usage:
//   import math
//   result := math.abs(-42);
//
// All functions work with the int type.

fn abs(x: int) -> int, pub:
    if x < 0:
        return -x
    return x

fn min(a: int, b: int) -> int, pub:
    if a < b:
        return a
    return b

fn max(a: int, b: int) -> int, pub:
    if a > b:
        return a
    return b

fn clamp(val: int, lo: int, hi: int) -> int, pub:
    if val < lo:
        return lo
    if val > hi:
        return hi
    return val

fn pow(base: int, exp: int) -> int, pub:
    r : ., mut = 1
    i : ., mut = 0
    loop:
        if i >= exp:
            break
        r = r * base
        i = i + 1
    return r

fn gcd(a: int, b: int) -> int, pub:
    x : ., mut = a
    y : ., mut = b
    loop:
        if y == 0:
            break
        t := y
        y = x % y
        x = t
    return x

fn lcm(a: int, b: int) -> int, pub:
    if a == 0 || b == 0:
        return 0
    return (a / gcd(a, b)) * b

fn is_even(n: int) -> bool, pub:
    return n % 2 == 0

fn is_odd(n: int) -> bool, pub:
    return n % 2 != 0

fn factorial(n: int) -> int, pub:
    if n <= 1:
        return 1
    r : ., mut = 1
    i : ., mut = 2
    loop:
        if i > n:
            break
        r = r * i
        i = i + 1
    return r
