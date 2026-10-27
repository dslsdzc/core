# Core 编程语言

[English](README.md) | 中文

![self-hosted](https://img.shields.io/badge/self--hosted-yes-blue)
![target](https://img.shields.io/badge/target-x86--64-lightgrey)
![license](https://img.shields.io/badge/license-GPLv3-blue)
![status](https://img.shields.io/badge/status-experimental-orange)

Core 是一门实验性编程语言，使用语义图 IR。编译器自举，直接生成原生 x86-64 ELF，
并在整个 IR 中保留 region、状态关系、provenance 等程序语义，不会过早转换成传统的机器模型。

Core 的编译模型分为 graph、lattice、encoding 三个阶段：计算先表示为关系，状态和存储单独映射，
最后生成机器表示。

```core
import io

fn fib(n: int) -> int:
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)

fn main() -> int:
    io.println_i(fib(10))   // 55
    return 0
```

Core 仍在积极开发中。

## 特性

- 自举编译器，三段自举，结果可复现
- 直接生成原生 x86-64 ELF，不依赖外部汇编器或链接器
- 语义图 IR：显式 region、状态边、provenance
- graph、lattice、target encoding 三阶段编译模型
- 原始指针，以及编译期的指针、region、provenance 分析
- 与程序 region 绑定的 arena 内存管理
- 协作式 fiber 与 channel
- 使用 `.cir` 快照做函数级增量编译
- 面向目标特定操作的硬件接口表（HIT）
- 泛型、接口、枚举、模式匹配、元组、数组、切片
- 规约使用 Core 语法；验证后端仍在开发中

## 设计

图表示计算与程序关系；格层表示状态与存储映射；目标编码把这些语义映射到具体执行模型。
类型、provenance 与规约信息在转换过程中始终保留在语义 IR 里（`.cir` 供验证使用，
`.ccr` 是格层存在结构的线性表示），因此验证与优化可以在最终目标编码之前完成。

详见 [Project Book](docs/project-book.md)、
[Execution Model](docs/maintainer/design/execution-model.md) 与
[Memory Model](docs/maintainer/design/memory-model.md)。

## 状态

Core 仍在积极开发中，尚不可用于生产。

- 自举链稳定：编译器三段自举，第 2 段与第 3 段逐字节相同。
- 规约层已设计但未实现；验证后端尚未实现。
- 语言、标准库与工具链的未完成项记录在 [TODO.md](TODO.md)。

## 构建

```bash
python3 build_selfhost_native.py
```

产物：`build/corec`（前端）与 `build/corearch`（后端）。

## 用法

```bash
./build/corec run 'fn main() -> int { return 42; }'    # 直接执行代码（解释器）
./build/corec check FILE.cr                             # 仅类型检查
./build/corec build FILE.cr -o OUT --static             # 编译为原生 ELF 二进制
./build/corec cir FILE.cr                               # 导出数据流图
./build/corec ccr FILE.cr                               # 导出格形态 IR
./build/corec clean-cache                               # 清除增量缓存
```

## 文档

- [Project Book](docs/project-book.md)：设计与理由
- [开发者文档](docs/developer/)：语法参考与内部实现
- [Execution Model](docs/maintainer/design/execution-model.md)
- [Memory Model](docs/maintainer/design/memory-model.md)
- [错误码](docs/developer/errors.md)

## 贡献

项目处于早期阶段，欢迎参与设计讨论与实验性实现。现有设计文档见 `docs/`。

## 许可

GNU General Public License v3.0（含 GPLv3 第 7 节附加许可）。
