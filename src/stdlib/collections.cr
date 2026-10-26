// === collections.cr ===
// Core standard library — basic collection operations.
//
// V4 form: element, length and element type are inferred from the call site.
// No `[T; N]` type positions; length comes from `.len`.

fn swap(arr, i, j), pub:
    tmp := arr[i]
    arr[i] = arr[j]
    arr[j] = tmp

fn reverse(arr), pub:
    i : ., mut = 0
    j : ., mut = arr.len - 1
    loop:
        if i >= j:
            break
        t := arr[i]
        arr[i] = arr[j]
        arr[j] = t
        i = i + 1
        j = j - 1

fn contains(arr, val) -> bool, pub:
    for x in arr:
        if x == val:
            return true
    return false

fn index_of(arr, val) -> int, pub:
    for i in 0..arr.len:
        if arr[i] == val:
            return i
    return -1

fn min_element(arr) -> int, pub:
    if arr.len == 0:
        return 0
    m : ., mut = arr[0]
    for x in arr:
        if x < m:
            m = x
    return m

fn max_element(arr) -> int, pub:
    if arr.len == 0:
        return 0
    m : ., mut = arr[0]
    for x in arr:
        if x > m:
            m = x
    return m

fn fill(arr, val), pub:
    for i in 0..arr.len:
        arr[i] = val

fn sum(arr) -> int, pub:
    s : ., mut = 0
    for x in arr:
        s = s + x
    return s

fn product(arr) -> int, pub:
    p : ., mut = 1
    for x in arr:
        p = p * x
    return p

fn count(arr, val) -> int, pub:
    c : ., mut = 0
    for x in arr:
        if x == val:
            c = c + 1
    return c

fn find(arr, val) -> int, pub:
    for i in 0..arr.len:
        if arr[i] == val:
            return i
    return -1

fn copy(src, dst), pub:
    i : ., mut = 0
    loop:
        if i >= src.len:
            break
        dst[i] = src[i]
        i = i + 1

fn equals(a, b) -> bool, pub:
    if a.len != b.len:
        return false
    for i in 0..a.len:
        if a[i] != b[i]:
            return false
    return true

fn slice_sum(arr, start, end) -> int, pub:
    s : ., mut = 0
    for i in start..end:
        if i >= arr.len:
            break
        s = s + arr[i]
    return s
