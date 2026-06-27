// Minimal test for `go` keyword concurrency support

fn worker(id: int) {
    return;
}

fn main() {
    // Test 1: go without count
    go worker(1);

    // Test 2: go with batch spawn
    go 4 worker(2);

    return;
}
