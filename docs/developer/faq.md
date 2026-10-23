# 常见问题（FAQ）

> 定位：受众 = 开发者；状态 = active。答案以当前实现为准；标注“设计态”的条目尚未实现。

## 语言与设计

### 与 Rust 的关系及无 borrow checker 的原因

Rust 使用借用检查在类型层保证内存安全，代价是学习成本和表达力约束。Core 的指针安全由编译器在数据流图上自动验证，验证方式是来源追踪和边界核对，不需要标注生命周期。Rust 是设计上的启发，不是 Core 的基础，Core 的语言设计从图模型独立发展。

### 语义保留的含义

编译中间表示（IR）保留全部类型和语义信息，不逐级降格为机器指令。验证器使用 IR 就能得到完整的语义模型，这是 Core 支持形式化验证、跨平台行为一致和范式可迁移（经典、量子等）的共同基础。也就是说，编译器不会丢弃“程序是什么”这一信息。

### 无 GC 的内存回收

子图区域（arena）：函数或循环结束时，其内存区域整块回收，以 O(1) 重置游标，没有停顿。长期服务的内存上限等于并发子图数乘以区域容量。

### 部署配置中的 allocation = "static"/"dynamic"

代码不决定内存策略，由部署目标声明。static 目标（裸机）要求所有大小在编译期可以确定；dynamic 目标允许运行时分配。同一份代码在两种部署下都成立时，就可以在两类目标上运行。

## 使用

### 第一个程序的运行

见 [quickstart.md](quickstart.md)。构建使用 `python3 build_selfhost_native.py`，编译使用 `./build/corec build`，`run` 用于内联执行。

### check / build / run / cir / ccr 的区别

`check` 只做类型检查；`run` 由解释器内联执行，不产生文件；`build` 执行完整流程并生成 ELF；`cir` 和 `ccr` 输出中间 IR，用于研究或调试。

### print 无输出的排查

先确认使用了标准库的 print 和 println（实现在 `src/stdlib/io.cr`；模块导入和目录级批量导入规则见 `syntax.md` 的模块章）。注意：裸 `fn main()->int{return 42;}` 没有输出是正常现象，main 的返回值是进程退出码，不是打印内容。

### 编译耗时与资源占用

自举编译是 CPU 密集型任务。长时间构建（无人值守）建议用 `nice -n 19` 或 `cpulimit -l 10` 限速，交互式短任务不需要。

### corec2 及其 check 卡顿问题

corec2 是自举的第二代前端产物，用于自编译验证。它曾经有一个 tokenizer 死循环的已知问题，原因是全局变量注册缺陷，见 TODO。日常开发请使用 `./build/corec`，不要使用 corec2。

> 该问题不再作为阻塞项。`corec2` 自举可以跑通，并且逐字节稳定（`corec2 == corec3`，IDENTICAL，由 `src/ci/run.sh` 的 `full-bootstrap` job 覆盖）。

## 状态相关

### 未实现功能

语言和编译器处于活跃自举期。已知的设计态或待办事项包括：验证管线（规约证明）、平台桥（I/O 和时钟语义接口的实现）、惰性求值、分布式、部署配置的完整消费，以及 `.ccr` 内容随 v9 段表推进（版本以 `src/compiler/ccr_io.cr` 的 `CCR_VERSION` 为准）。最新状态见仓库的 `TODO.md` 和各文档头部的“状态”。

### float 的现状

`float` 已于 2026-08 退役（dex/apx 定案）。精确小数使用 `dex`，允许近似的场景使用 `apx`。历史遗留的 `float` 代码需要迁移，见 ADR-0010。

### .corespec 文件的现状

该格式没有用途。独立的规约格式已于 2026-09 退役，规约改为在 `.cr` 中内联 `#check`/`#ensure`（设计态，见 ADR-0001）。

## 相关

[tutorial.md](tutorial.md) / [syntax.md](syntax.md) / [quickstart.md](quickstart.md) / [concepts.md](concepts.md)
