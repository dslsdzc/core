Core 语言语法

---

设计哲学

· 像写伪代码一样写系统软件
    类型自动推导，所有权编译器代劳，并发只需两个关键字。
· 源码即真理
    没有指针，没有未定义行为，所有高级结构完整保留到编译后端，供验证与静态分析。
· 规约是代码的注释
    requires / ensures 与函数体并列，不写也行，写了就能自动验证。
· 执行流 = 数据流节点
    你只管写同步调用，go 和 await 自动织出并发数据流图。

---

一、词法与注释

```
// 单行注释
/* 多行注释 */
```

关键字
fn struct enum interface impl type let mut move go await flow
if else match for loop return break continue
pub mod import as unsafe
requires ensures old result self Self
true false unit None Some

注意：* 不作为指针语法，-> 仅用于返回类型，& 仅用于借用引用（不允许取地址运算）。

---

二、模块与导入

```core
mod my_project::network;             // 文件顶层声明模块

import std::io::println;            // 导入单个项
import std::collections::Vec;
import my_project::utils::parse_addr;
```

· 模块路径与文件路径对应。
· 无通配符导入，所有依赖显式可见。

---

三、变量与基础类型

3.1 变量声明

```core
let x = 42;          // 不可变，类型推断为 int
let mut y = 3.14;    // 可变
```

类型标注可选：

```core
let x: int = 42;
let name: string = "Core";
```

3.2 基础类型

类型 说明
int 整数（编译器按需选择宽度）
float 64 位浮点数
bool true / false
string 不可变 UTF-8 字符串
char Unicode 标量值
unit 空值 ()
never 发散类型

显式位宽后缀：

```core
let addr = 0x1000_u64;
let count = 100_i32;
```

3.3 引用

· &T —— 不可变借用
· &mut T —— 可变借用，独占

引用不是地址，不能算术运算，不能从整数强转。

```core
let x = 5;
let r = &x;        // r: &int
let mut y = 10;
let rm = &mut y;   // rm: &mut int
```

使用引用与被引用对象完全相同，无需解引用操作符。

3.4 可选类型

```core
let maybe: int? = Some(5);
let nothing: int? = None;
```

---

四、复合类型

4.1 元组

```core
let pair = (42, true);
let (n, b) = pair;   // 解构
```

4.2 数组与切片

```core
let arr = [1, 2, 3];
let zeros: [int; 16] = [0; 16];
let slice: [int] = arr[0..2];   // 切片，引用原数组
```

4.3 结构体

```core
struct Point {
    x: float,
    y: float,
}

let p = Point { x = 1.0, y = 2.0 };
println(p.x);
```

4.4 枚举

```core
enum IpAddr {
    V4(u8, u8, u8, u8),
    V6(u16, u16, u16, u16, u16, u16, u16, u16),
}

enum Option[T] {
    Some(T),
    None,
}
```

---

五、函数

5.1 定义

```core
fn add(a: int, b: int) -> int {
    return a + b;
}

// 单行形式
fn add(a: int, b: int) -> int = a + b;
```

5.2 方法

```core
impl Point {
    fn norm(&self) -> float {
        (self.x * self.x + self.y * self.y).sqrt()
    }
    
    fn move_by(&mut self, dx: float, dy: float) {
        self.x += dx;
        self.y += dy;
    }
}
```

5.3 泛型

```core
fn first[T](list: &[T]) -> T? {
    if list.len() > 0 {
        return Some(list[0]);
    }
    None
}
```

5.4 形式规约

```core
fn divide(a: int, b: int) -> int?
    requires b != 0
    ensures result.is_some() implies (a / b) == result.unwrap()
{
    if b == 0 {
        return None;
    }
    return Some(a / b);
}
```

· requires —— 调用方必须满足的前提条件
· ensures —— 保证的后置条件，result 指返回值，old(expr) 指函数入口时表达式的值

规约参与静态检查，不影响运行时性能。

---

六、控制流

6.1 条件

```core
if x > 0 {
    println("positive");
} else if x < 0 {
    println("negative");
} else {
    println("zero");
}

let category = if x > 0 { "positive" } else { "not positive" };
```

6.2 循环

```core
for i in 0..10 {
    println(i);
}

for item in items {
    println(item);
}

loop {
    if done { break; }
}

while condition {
    // ...
}
```

6.3 模式匹配

```core
match opt {
    Some(x) => println("got {x}"),
    None => println("nothing"),
}
```

匹配必须穷尽所有情况。

---

七、所有权与借用

· 默认借用：函数传参、赋值等不移动所有权，编译器自动插入借用。
· 显式移动：使用 move 关键字转移所有权。

```core
let a = vec![1, 2, 3];
let b = move a;          // a 失效

fn consume(v: Vec<int>) { ... }
consume(move b);         // b 移动进去
```

· 复制类型：整数、浮点数、布尔、小元组等实现 Copy 接口，赋值时自动复制。

无生命周期标注，编译器全权推断引用有效性。

---

八、接口

```core
interface Hash {
    fn hash(&self) -> u64;
}

interface Eq {
    fn eq(&self, other: &Self) -> bool;
}
```

实现：

```core
impl Hash for Point {
    fn hash(&self) -> u64 {
        ...
    }
}
```

---

九、并发

9.1 异步启动

```core
let handle = go some_work(arg1, arg2);  // handle: Flow<T>
```

9.2 等待结果

```core
let result = await handle;   // 阻塞直到完成
```

属性：当需要值时自动等待

```core
let val = go fetch(url) + go fetch(other);  // 自动等待
```

9.3 长期执行流

```core
flow counter(start: int) -> int {
    let mut n = start;
    loop {
        yield n;      // 产出数据
        n += 1;
    }
}

let f = go counter(0);
for i in 0..5 {
    let v = f.recv();  // 接收一个值
    println(v);
}
```

9.4 通道（标准库）

```core
import std::chan;
let (tx, rx) = chan::new();
go producer(tx);
go consumer(rx);
```

---

十、错误处理

```core
enum Result[T, E] {
    Ok(T),
    Err(E),
}

fn fetch() -> Result<string, IoError> {
    let data = read_file("config.txt")?;   // 出错则立刻返回 Err
    Ok(data)
}
```

? 只能用于返回 Result 的函数中。

---

十一、不安全区域

```core
unsafe {
    let reg = 0xFEED_0000 as RawRef<u64>;
    reg.write(0x42);
}
```

unsafe 块内允许：

· 使用 RawRef<T>
· 调用外部 C 函数
· 编译器固有

RawRef<T> 无法逃逸到安全代码。

---

十二、数据流图视图（设计）

编写顺序代码时，后台自动构建数据流图：

· 每个 flow / go 映射为图节点
· yield / recv 定义连续的数据边
· 并行例程形成动态扇出/扇入结构
· 集成 select 可以表达汇合点

整张图可被静态分析和形式化验证。

---

十三、示例：并行计算 π

```core
mod examples::pi;

fn leibniz_partial(start: int, n: int) -> float {
    let mut sum = 0.0;
    let mut sign = if start % 4 == 1 { 1.0 } else { -1.0 };
    for i in 0..n {
        sum += sign / ((start + 2 * i) as float);
        sign = -sign;
    }
    return sum;
}

flow worker(id: int, base: int, chunk: int) -> float {
    let mut offset = base;
    loop {
        let partial = leibniz_partial(offset, chunk);
        yield partial;
        offset += chunk * num_workers();
    }
}

flow orchestrator(workers: int, chunk_size: int) {
    let mut flows = [];
    for i in 0..workers {
        flows.push(go worker(i, 1 + 2 * i * chunk_size, chunk_size));
    }
    
    let mut pi = 0.0;
    loop {
        for f in &flows {
            pi += 4.0 * f.recv();
        }
        println("π ≈ {pi}");
    }
}

fn main() {
    let worker_count = 8;
    let chunk = 10_000;
    go orchestrator(worker_count, chunk);
}
```

输出：持续逼近 π 的近似值，如

```
π ≈ 3.1415926...
π ≈ 3.141592653...
...
```

此程序展示了：只用 go、flow、yield、recv，就能构建并行的数据流网络。

---

为什么它极其容易学习？

1. 无指针：没有 *, ->, 地址运算
2. 类型自动推导：多数地方无需写类型
3. 所有权无感：默认借用，需要转移才用 move
4. 并发仅需两个词：go 和 await
5. 控制流即伪代码：if, for, match 直观
6. 规约是加强注释：不影响运行
7. 不安全藏进盒子：unsafe 块清晰隔离

Core 让你用最小的心智负担，写出在裸金属上飞奔的系统代码。