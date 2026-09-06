# 快速开始

> 定位:受众 = 开发者(第一次接触 Core);状态 = active。
> 前提:Linux(x86-64)、Python 3、一个终端。构建与运行的全部命令以仓库 CLAUDE.md 为真源。

## 一、构建编译器

Core 编译器由 Core 自身编写(自举),用 Python bootstrap 构建出原生二进制:

```bash
# 在仓库根目录
python3 build_selfhost_native.py
```

产物:`build/corec`(前端:源码 → IR)→ `build/corearch`(后端:IR → ELF)。

> 提示:构建是编译密集型任务,慢机器上可用 `nice -n 19` 降优先级。产物尚不随仓库分发——需要自己构建(发行打包见 PKGBUILD 方向)。

## 二、第一个程序

`examples/add/main.cr` 是最小完整程序:

```core
fn add(a: int, b: int) -> int {
    return a + b;
}
fn main() -> int {
    return add(3, 4);
}
```

`main` 的返回值 = 进程退出码(所以这个程序"运行成功" = 退出码 7)。

## 三、三种运行方式

```bash
# 1. 类型检查(不产出)
./build/corec check examples/add/main.cr

# 2. 内联执行(解释器,适合试一小段)
./build/corec run 'fn main()->int{return 42;}'

# 3. 编译成原生二进制
./build/corec build examples/add/main.cr -o /tmp/add --static
/tmp/add; echo $?    # 打印退出码 7
```

`build` 会自动调用后端产出 ELF;也可手工分步:`./build/corec ccr file.cr` 出中间 IR,`./build/corearch file.ccr --elf --static -o out` 出二进制(调试后端时有用)。

## 四、目录导览

| 路径 | 内容 |
|---|---|
| src/compiler/ | 编译器源码(用 Core 写)——前端 |
| src/arch/linux/ld/ | ELF 后端(指令编码/链接) |
| src/stdlib/ | 标准库(io/fmt/collections/arena/…) |
| examples/ | 示例程序(add/complex/pi/load_balancer 等,见 examples.md) |
| tests/ | 测试三套(bootstrap/selfhost/suite) |

> 注:examples/hello/ 目前是空骨架——用 add/ 或自建文件开始。

## 五、下一步

- [tutorial.md](tutorial.md)— 渐进学习路径(从基础到系统编程)
- [syntax.md](syntax.md)— 语法参考
- [examples.md](examples.md)— 可跑示例
- [concepts.md](concepts.md)— 图模型等核心概念导览
