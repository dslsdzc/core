# 快速开始

> 定位：受众 = 开发者（第一次接触 Core）；状态 = active。
> 前提：Linux（x86-64）、Python 3、一个终端。构建与运行的全部命令以仓库 `CLAUDE.md` 为准。

## 构建编译器

Core 编译器由 Core 自身编写（自举），用 Python bootstrap 构建出原生二进制：

```bash
# 在仓库根目录
python3 build_selfhost_native.py
```

产物是 `build/corec`（前端，把源码转换为 IR）和 `build/corearch`（后端，把 IR 转换为 ELF）。

> 提示：构建是编译密集型任务，慢机器上可以用 `nice -n 19` 降低优先级。产物尚未随仓库分发，需要自行构建（发行打包见 PKGBUILD 方向）。

## 第一个程序

`examples/add/main.cr` 是最小完整程序：

```core
fn add(a: int, b: int) -> int:
    return a + b
fn main() -> int:
    return add(3, 4)
```

`main` 的返回值就是进程退出码，因此这个程序运行成功时退出码为 7。

## 三种运行方式

```bash
# 1. 类型检查（不产出）
./build/corec check examples/add/main.cr

# 2. 内联执行（解释器，适合试一小段）
./build/corec run 'fn main()->int{return 42;}'

# 3. 编译成原生二进制
./build/corec build examples/add/main.cr -o /tmp/add --static
/tmp/add; echo $?    # 打印退出码 7
```

`build` 会自动调用后端生成 ELF，也可以手工分步执行：`./build/corec ccr file.cr` 生成中间 IR，`./build/corearch file.ccr --elf --static -o out` 生成二进制，调试后端时有用。

## 目录导览

| 路径 | 内容 |
|---|---|
| src/compiler/ | 编译器源码（用 Core 编写），前端 |
| src/arch/ · src/format/ · src/os/ | 后端三个维度（架构、格式、操作系统）：指令编码、寄存器分配、帧；ELF 生成、链接；入口、调用序列、系统调用 |
| src/stdlib/ | 标准库（io、fmt、collections、arena 等） |
| examples/ | 示例程序（add、complex、pi、load_balancer 等，见 examples.md） |
| tests/ | 三套测试（bootstrap、selfhost、suite） |

> 注：`examples/hello/` 目前是占位示例，可以用 `add/` 或自建文件开始。
> 注：`src/arch/linux/ld/`（原来的 ELF 后端）已退役。后端现在按三个维度分目录，组合根在 `src/targets/x86_64-linux/`（2026-09-24 更正）。

## 下一步

- [tutorial.md](tutorial.md)：渐进学习路径（从基础到系统编程）
- [syntax.md](syntax.md)：语法参考
- [examples.md](examples.md)：可运行示例
- [concepts.md](concepts.md)：图模型等核心概念导览
