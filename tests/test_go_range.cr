// Test go range syntax: go var start end expr
// Desugars to: for var in start..end { go expr; }

fn worker(id: int) {
    return;
}

fn main() {
    // Range spawn: go i 1 8 worker(i)
    go i 1 8 worker(i);

    // Old-style: go 4 worker(0)
    go 4 worker(0);

    // Single: go worker(42)
    go worker(42);

    return;
}
