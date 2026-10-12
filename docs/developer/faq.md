# 常见问题（FAQ）

> 定位：受众 = 开发者；状态 = active。答案以当前实现为准；标注「设计态」的条目尚未落地。

## 语言与设计

**与 Rust 的关系及无 borrow checker 的原因**
Rust 用借用检查在类型层保证内存安全，代价是学习曲线与表达力约束。Core 的指针安全由编译器在数据流图上自动验证（来源追踪 + 边界核对）——不需要标注生命周期。Rust 是启发，不是基础：语言从图模型独立设计。

**语义保鲜的含义**
编译中间表示（IR）保留全部类型与语义信息，不逐级降格为机器指令。验证器消费 IR 即获得完整语义模型——这是 Core 支持形式化验证、跨平台行为一致、范式可迁移（经典/量子/…）的共同基础。换言之，编译器不丢弃「程序是什么」。

**无 GC 的内存回收**
子图区域（arena）：函数/循环结束，其内存区域整块回收——O(1) 重置游标，无停顿。长期服务的内存上限 = 并发子图数 × 区域容量。

**部署配置中的 allocation = "static"/"dynamic"**
代码不决定内存策略；部署目标声明。static 目标（裸机）要求所有大小编译期可定；dynamic 目标允许运行时分配。同一份代码在两种部署下都成立时，它即可在两类目标上运行。

## 使用

**第一个程序的运行**
见 [quickstart.md](quickstart.md)——`python3 build_selfhost_native.py` 构建，`./build/corec build` 编译，`run` 内联执行。

**check / build / run / cir / ccr 的区别**
`check` 只做类型检查；`run` 解释器内联执行（不产文件）；`build` 全链到 ELF；`cir`/`ccr` 输出中间 IR（研究/调试）。

**print 无输出的排查**
先确认使用了标准库的 print/println（实现在 `src/stdlib/io.cr`；模块导入与目录级批量导入规则见 `syntax.md` 模块章）。注意：裸 `fn main()->int{return 42;}` 没有输出属**正常**——main 返回值 = 进程退出码，不是打印。

**编译耗时与资源占用**
自举编译是 CPU 密集任务；长时间构建（无人值守）建议 `nice -n 19` 或 `cpulimit -l 10` 限速——交互式短任务不必。

**corec2 及其 check 卡顿问题**
corec2 = 自举的第二代前端产物（自编译验证用）。它曾有 tokenizer 死循环已知问题（全局变量注册缺陷，见 TODO）——日常开发请用 `./build/corec`，不要用 corec2。

> 修订(2026-09-24):该问题**不再作为阻塞项**——`corec2` 链可跑通且逐字节稳定(`corec2 == corec3` IDENTICAL;由 `src/ci/run.sh` 的 `full-bootstrap` job 覆盖)。原文保留供追溯。

## 状态相关

**未实现功能**
语言与编译器在活跃自举期。已知设计态/挂账：验证管线（规约证明）、平台桥（IO/时钟语义接口落地）、惰性求值、分布式、部署配置完整消费、.ccr 内容随 v9 段表推进（版本以 `src/compiler/ccr_io.cr` 的 `CCR_VERSION` 为准）。最新状态见仓库 `TODO.md` 与各文档头部「状态」。

**float 的现状**
`float` 已退役（2026-08，dex/apx 定案）——精确小数用 `dex`，近似授权用 `apx`。历史遗留的 `float` 代码需迁移（见 ADR-0010）。

**.corespec 文件的现状**
无用途——独立规约格式 2026-09 退役，规约写成 `.cr` 内联 `#check`/`#ensure`（设计态，见 ADR-0001）。

## 相关

[tutorial.md](tutorial.md) / [syntax.md](syntax.md) / [quickstart.md](quickstart.md) / [concepts.md](concepts.md)
