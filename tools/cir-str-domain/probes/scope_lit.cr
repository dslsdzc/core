import io

fn helper() -> int {
    println("HELPER_LITERAL");
    return 0;
}

fn main() -> int {
    println("MAIN_LITERAL");
    helper();
    return 0;
}
