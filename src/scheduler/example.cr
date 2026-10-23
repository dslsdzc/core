// Scheduler usage example.
//
// Creates a scheduler table, registers two functions, and calls them through the
// table.

import io

fn hello(name: string):
    print("hello ")
    println(name)

fn add(a: int, b: int) -> int:
    return a + b

fn main() -> int:
    // Create a scheduler table with two entries.
    table := sched_create(2)

    // Register functions by writing function pointers into the table.
    // Core has no function pointer type. load_str_ptr and store_str_ptr would be
    // needed at assembly level. This example stores integer addresses directly;
    // real function addresses must come from the linker.
    //
    // Pseudocode:
    //   sched_set(table, 0, &hello);
    //   sched_set(table, 1, &add);
    //
    // Calls through the table:
    //   sched_call_1(table.entries, 0, "world");
    //   result := sched_call_2(table.entries, 1, 3, 5);

    println("scheduler example")

    // This only demonstrates table operations. Function pointers are not
    // available in Core yet.

    return 0
