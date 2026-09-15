struct Node { val: int, next: *Node }
fn main() -> int {
    a : ., mut = Node { val: 1, next: 0 };
    b : ., mut = Node { val: 2, next: 0 };
    a = b;
    return a.val;
}
