Core 数据流执行模型设计图

---

1. 核心抽象

Core 将一切执行抽象为数据流图。
程序员编写顺序的函数调用与并发启动，编译器自动构建并优化对应的数据流图。

编程概念 数据流图映射
函数 fn f(x) -> y 计算节点（从输入边到输出边）
函数调用 f(a) 节点实例化，参数作为输入令牌
return x 或 yield x 产生输出令牌
go f() 创建新的执行流节点，立即返回数据流句柄
await handle 显式同步边：等待上游节点产出值
recv() 从通道/流接收数据令牌，触发节点激活
循环 for / loop 扇出/扇入拓扑的生成器
分支 if / match 选择路由（有条件的数据转发）
flow 声明 持续运行的节点（有状态，可多次激活）

关键性质：

· 执行顺序由数据可用性驱动，而非文本顺序。
· 显式并发与隐式数据流融合，不引入额外心智模型。

---

2. 静态与动态数据流图

2.1 静态图

编译时已知：函数调用关系、模块连接。
等价于传统的数据流程序图。

```core
fn transform(x: int) -> int { x * 2 }
fn display(v: int) { println(v); }

fn main() {
    data := [1, 2, 3];
    for d in data {
        go display(transform(d));
    }
}
```

图结构：data → transform 节点（多个实例） → display 节点（多个实例）。
for 展开为扇出，go 为每个实例创建执行流节点。

2.2 动态图

运行时图拓扑可变：产生新节点、删除节点、重新连线。
这是 Core 应对长期运行服务和自适应系统的关键能力。

```core
flow load_balancer() {
    loop {
        select {
            req: Request = recv => {
                worker := go handle_request();
                worker.send(req);
            }
            signal: HealthCheck = recv from monitor => {
                signal.target.terminate();
            }
        }
    }
}
```

load_balancer 节点不断创建/移除 worker 节点，数据流图在运行时动态演化。

---

3. 执行流与数据流节点的统一视图

一个 flow 实例既是：

· 执行流：拥有自己的栈和指令指针。
· 数据流节点：通过 recv 消费输入，通过 yield 或 return 产出输出。
· 图中的顶点：可以连接到其他节点（通道/句柄）。

这种统一性使得：

· 并发推理无需关心线程/协程的底层差异。
· 静态分析工具可以提取完整的数据依赖图用于形式化验证。

---

4. 语法元素到图元件的映射

语法元素 图语义 激活条件
fn f(in) -> out 有向无环子图，输入边->节点->输出边 调用时实例化
go f(args) 新建执行流节点，边连接实参到形参 立即激活
x := f(args) 创建临时节点，当前执行流挂起等待结果 等待输出令牌
yield value 向当前流句柄发送输出令牌 消费方 recv 时激活
recv() 等待输入令牌到达，激活节点 令牌到达
select { ... } 多输入汇合点，任一输入到达即激活对应分支 最早到达的令牌
chan.send(v) / chan.recv() 通过通道连接节点，形成数据边 边界匹配
for x in source 扇出：source产生序列，每次迭代产生新节点实例 迭代时
loop { ... } 自环反馈结构，节点激活后可再次激活 内部 yield/recv

---

5. 并行计算 π 的图表示例

```core
flow worker(id, base, chunk) -> float {
    loop {
        partial := leibniz_partial(offset, chunk);
        yield partial;
        offset += chunk * num_workers();
    }
}

flow orchestrator(workers, chunk_size) {
    flows : ., mut = [go worker(...), ...];   // 扇出多个 worker 节点
    loop {
        for f in &flows {
            pi += 4.0 * f.recv();           // 扇入：从每个 worker 收集部分和
        }
        println(pi);
    }
}

fn main() {
    go orchestrator(8, 10000);
}
```

图结构：

· 8 个 worker 节点，每个独立运行，产出 float 令牌。
· orchestrator 节点通过 recv() 从 8 条边收集令牌，累加后输出。
· 所有边是缓冲通道，允许生产者/消费者异步执行。
· 循环构成反馈：worker 每次 yield 后继续计算下一块。

---

6. 形式化验证视角

从这张数据流图可以直接导出：

· 数据依赖：边定义了节点间的偏序关系。
· 吞吐量/延迟分析：节点执行时间 + 通道缓冲。
· 无死锁证明：若图无环且缓冲合理，则无死锁。
· 功能规约：可将每个节点的 requires/ensures 组合，验证整体管道正确性。

---

7. 与硬件执行模型的映射

Core 的数据流图可以高效映射到多种底层硬件：

· 多核 CPU：节点映射为线程/协程，边用无锁队列或共享内存。
· GPU：节点映射为 kernel，边映射为 global memory + 同步。
· 分布式：节点映射为远程执行器，边映射为网络消息。
· 无 MMU 嵌入式：节点与边静态分配，无动态分配。

语言自身不规定映射策略，由后端根据目标平台决定，保证"写一次，处处高效"。

---

结论：Core 程序员只需要掌握极少的并发原语（go，await，flow，recv/yield），代码即自动构成可动态演化的数据流图。这张图既是运行时模型，也是编译期分析和验证的蓝图。
