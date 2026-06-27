// === collections.cr ===
// Core standard library — basic collection operations.
//
// Usage:
//   import collections
//   collections.reverse(arr);
//
// Current limitations: operates on int arrays; no HashMap/HashSet yet.

fn swap(arr: [int; N], i: int, j: int) {
    tmp := arr[i];
    arr[i] = arr[j];
    arr[j] = tmp;
}

fn reverse(arr: [int; N]) {
    i : ., mut = 0;
    j : ., mut = N - 1;
    loop {
        if i >= j { break; }
        t := arr[i];
        arr[i] = arr[j];
        arr[j] = t;
        i = i + 1;
        j = j - 1;
    }
}

fn contains(arr: [int; N], val: int) -> bool {
    i : ., mut = 0;
    loop {
        if i >= N { break; }
        if arr[i] == val { return true; }
        i = i + 1;
    }
    return false;
}

fn index_of(arr: [int; N], val: int) -> int {
    i : ., mut = 0;
    loop {
        if i >= N { break; }
        if arr[i] == val { return i; }
        i = i + 1;
    }
    return -1;
}

fn min_element(arr: [int; N]) -> int {
    if N == 0 { return 0; }
    m : ., mut = arr[0];
    i : ., mut = 1;
    loop {
        if i >= N { break; }
        if arr[i] < m { m = arr[i]; }
        i = i + 1;
    }
    return m;
}

fn max_element(arr: [int; N]) -> int {
    if N == 0 { return 0; }
    m : ., mut = arr[0];
    i : ., mut = 1;
    loop {
        if i >= N { break; }
        if arr[i] > m { m = arr[i]; }
        i = i + 1;
    }
    return m;
}

fn fill(arr: [int; N], val: int) {
    i : ., mut = 0;
    loop {
        if i >= N { break; }
        arr[i] = val;
        i = i + 1;
    }
}

fn sum(arr: [int; N]) -> int {
    s : ., mut = 0;
    i : ., mut = 0;
    loop { if i >= N { break; } s = s + arr[i]; i = i + 1; }
    return s;
}

fn product(arr: [int; N]) -> int {
    p : ., mut = 1;
    i : ., mut = 0;
    loop { if i >= N { break; } p = p * arr[i]; i = i + 1; }
    return p;
}

fn count(arr: [int; N], val: int) -> int {
    c : ., mut = 0;
    i : ., mut = 0;
    loop { if i >= N { break; } if arr[i] == val { c = c + 1; } i = i + 1; }
    return c;
}

fn find(arr: [int; N], val: int) -> int {
    i : ., mut = 0;
    loop { if i >= N { break; } if arr[i] == val { return i; } i = i + 1; }
    return -1;
}

fn copy(src: [int; N], dst: [int; N]) {
    i : ., mut = 0;
    loop { if i >= N { break; } dst[i] = src[i]; i = i + 1; }
}

fn equals(a: [int; N], b: [int; M]) -> bool {
    if N != M { return false; }
    i : ., mut = 0;
    loop { if i >= N { break; } if a[i] != b[i] { return false; } i = i + 1; }
    return true;
}

fn slice_sum(arr: [int; N], start: int, end: int) -> int {
    s : ., mut = 0;
    i : ., mut = start;
    loop { if i >= end || i >= N { break; } s = s + arr[i]; i = i + 1; }
    return s;
}
