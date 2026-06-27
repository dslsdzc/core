// Test flow and yield keywords
// Counter yields 0,1,2,3,4 then exits

flow counter() {
    i : ., mut = 0;
    loop {
        yield i;
        i = i + 1;
        if i >= 5 { break; }
    }
}

fn main() {
    go counter();
    return;
}
