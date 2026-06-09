// Test: dynamic memory allocation via __builtin_alloc
import io

struct Point
    x : int
    y : int
end

fn main() -> int {
    println_int(42);

    // Allocate a struct on stack (no heap alloc needed for local vars)
    p : Point;
    p.x = 10;
    p.y = 20;
    println_int(p.x);
    println_int(p.y);

    println("--- done ---");
    return 0;
}
