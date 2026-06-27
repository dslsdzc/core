# Core Programming Language

**Core** 是一门全新的、完全自主设计的编程语言，以及一套围绕"语义保鲜"理念构建的编译工具链。  
其核心是一个保留全部类型与语义信息的中间表示（IR），并原生支持完全形式化验证。

---

## 项目状态

当前处于 **自举编译器阶段**：编译器自身使用 Core 语言编写，可通过引导编译器（Python）编译为原生 x86-64 二进制。  
`build/corec` 是自举编译器前端，`build/corearch` 是后端。

### 自举里程碑：corec2 自我编译

**已实现三级自举管线：**

| 阶段 | 编译方式 | 产物 | 状态 |
|------|---------|------|------|
| Stage 0 | Python 引导编译器 | `build/corec`（前端）+ `build/corearch`（后端） | ✅ 正常 |
| Stage 1 | `build/corec` + `build/corearch` 编译自举编译器源码 | `build/corec2`（自编译前端） | ✅ 可运行 |
| Stage 2 | `build/corec2` + `build/corearch` 再次编译 | `build/corec3`（二次自编译） | ✅ 可运行 |

**当前限制：** corec2 自我编译虽可运行，但速度远慢于 build/corec（约 1000×），主要因为 ELF 后端代码生成尚无条件寄存器分配，所有变量走栈操作。优化方向包括寄存器分配、AST 折叠、公共子表达式消除等。

### 已实现的核心特性

| 类别 | 特性 | 状态 |
|------|------|------|
| **类型系统** | `int`、`float`、`bool`、`string`、`char`、`unit`、`never` | ✅ |
| | 泛型函数与泛型结构体 | ✅ |
| | `auto` / `.` 类型推导 | ✅ |
| | `char` 字面量 `'a'` | ✅ |
| | 位宽后缀 `_i32` `_u64` `_f32` `_f64` | ✅ |
| **变量** | `:=` / `: type` 声明，`mut` / `pub` 标签 | ✅ |
| | 批量声明 `a, b : int = 1, 2` | ✅ |
| **函数** | 函数定义、调用、参数、返回值 | ✅ |
| | 单行函数体 `fn add(a, b) -> int = a + b;` | ✅ |
| | `pub fn` 可见性 | ✅ |
| **控制流** | `if` / `else` / `elif` | ✅ |
| | `while`、`loop` + `break` / `continue` | ✅ |
| | `for` 区间和数组迭代 | ✅ |
| **并发** | `go [N] expr` 协程生成（单/批量） | ⚡ 新 |
| | `await expr` 异步等待 | ⬜ 待实现 |
| | 协作式 Fiber 调度器（round-robin） | ⚡ 新 |
| | 缓冲通道 `chan_send` / `chan_recv`（阻塞） | ⚡ 新 |
| | Arena 分配器（per-goroutine bump alloc + free-list） | ⚡ 新 |
| **复合类型** | 结构体定义、字段访问、嵌套结构体 | ✅ |
| | 枚举与模式匹配（`match`） | ✅ |
| | 元组字面量 `(1, 2)` + 字段访问 `t.0` | ✅ |
| | 定长数组 `[T; N]`、切片 `arr[0..2]` | ✅ |
| **方法** | `impl` 块、`self` / `&self` / `&mut self` 方法 | ✅ |
| | `impl Trait for Type` | ✅ |
| **运算符** | 算术 `+ - * / %` | ✅ |
| | 比较 `== != < > <= >=` | ✅ |
| | 逻辑 `&& \|\|`、一元 `!` `-` | ✅ |
| | 复合赋值 `+= -= *= /=` | ✅ |
| | `as` 类型转换 | ✅ |
| **引用与借用** | `&T` / `&mut T` 引用 | ✅ |
| | 借用检查（Borrow Checker） | ✅ |
| **字符串** | 字符串字面量、拼接 | ✅ |
| | 字符串插值 `"Hello {name}"` | ✅ |
| **语义检查** | 名字解析 + 类型检查 | ✅ |
| | 结构化错误码 + 源码定位 | ✅ |
| **模块系统** | `import`、`fileid`、`@project` 导入 | ✅ |
| | `_import.cr` 目录级批量导入 | ✅ |
| | 依赖裁剪（按引用链） | ✅ |
| **标准库** | `io.cr` — `print` / `println` / `print_int` | ✅ |
| | `math.cr` — `abs` / `min` / `max` / `gcd` 等 | ✅ |
| | `collections.cr` — `reverse` / `contains` / `fill` 等 | ✅ |
| | `cli.cr` — 命令行参数解析 | ✅ |
| | `toml.cr` — TOML 配置解析 | ✅ |
| **编译器基础设施** | 自举编译器（Core 写编译器） | ✅ |
| | x86-64 原生二进制输出（ELF，无需 as/ld） | ✅ |
| | `run` 子命令（直接执行代码） | ✅ |
| | `build`/`ccr`/`cir`/`run` 子命令 | ✅ |
| | CIR 数据流图（带完整类型/语义信息） | ✅ |
| | `.ccr` 线性 CFG 中间表示 | ✅ |
| | 错误诊断系统（Rust 风格源码定位） | ✅ |
| **形式化验证** | 规约层 IR（`.corespecir`）格式定义 | ⬜ 占位 |
| | 验证条件生成 | ⬜ 占位 |
| | SMT 求解器接口 | ⬜ 占位 |
| **包管理与发布** | Arch Linux PKGBUILD | ✅ |
| | CI 流水线 | ⬜

---

## 快速开始

```bash
# 构建自举编译器
python3 build_selfhost_native.py

# -c 模式：直接执行代码（解释器）
./build/corec run '__builtin_println("hello"); 42'

# 编译文件
./build/corec ccr hello.cr              # → hello.ccr
./build/corec cir hello.cr              # → hello.cir（数据流图）
./build/corec build hello.cr --static   # → a.out（ELF，无需 as/ld）
as -o hello.o hello.s && ld ...          # 或用传统路径

# 通过引导编译器（Python）编译
python3 tools/corec ir hello.cr      # → .cir 数据流图
python3 tools/corec cir hello.cr     # → .ccr 线性 IR
```

### 并发示例

```core
import io;

fn worker(id: int, base: int) {
    io.println_int(id + base);
}

fn main() {
    // 批量生成 8 个 worker 协程，每个传入不同 ID
    go f 1..8 worker(f * 10000, 10000);

    // 单个协程
    go worker(1, 0);
}
```

---

## 项目结构

```
core/
├── bootstrap/corec/         # 引导编译器（Python）
│   ├── syntax/              # AST 定义、Token、关键字
│   ├── frontend/            # 词法/语法/语义分析/IR 生成
│   ├── ir/                  # IR 数据结构（CIR 数据流图 / CCR 线性 CFG）
│   ├── backend/             # 解释器、ARM64/x86-64 代码生成
│   └── verifier/            # 形式化验证（占位）
├── src/
│   ├── compiler/            # 自举编译器（Core 源码）
│   │   ├── ast.cr            # Token 定义、AST 节点、IR 指令、类型常量
│   │   ├── lexer.cr          # 词法分析器
│   │   ├── parser.cr         # 语法分析器
│   │   ├── checker.cr        # 类型检查 + 借用检查
│   │   ├── ir_gen.cr, dataflow.cr  # IR 生成 + 数据流图
│   │   ├── main.cr           # 前端入口（corec）
│   │   ├── corearch.cr       # 后端入口（corearch）
│   │   ├── ccr_io.cr         # .ccr 二进制序列化
│   │   ├── elf.cr            # ELF 直接输出（无需 as/ld）
│   │   ├── interp.cr         # IR 解释器（-c 模式）
│   │   ├── project.cr        # 项目文件读取（Core.toml）
│   │   └── backend/x86_64.cr # x86-64 汇编生成
│   ├── stdlib/              # 标准库
│   │   ├── io.cr, cli.cr     # I/O、命令行
│   │   ├── math.cr, toml.cr  # 数学、TOML 解析
│   │   ├── arena.cr          # Arena 分配器
│   │   ├── scheduler.cr      # Fiber 调度器
│   │   ├── chan.cr           # 缓冲通道
│   │   └── collections.cr    # 集合操作
│   └── runtime/             # 运行时（rt.s  bump allocator + 系统调用）
├── tests/                    # 测试
│   ├── bootstrap/            # 引导编译器流水线测试
│   └── selfhost/             # 自举编译器测试
├── tools/corec               # Python CLI 工具
├── build/corec               # 自举编译器原生 x86-64 二进制
├── grammar/                   # EBNF 语法定义
├── docs/                      # 设计文档
└── PKGBUILD                   # Arch Linux 打包
├── spec/                           # 形式规约文件（.corespec 示例）
├── examples/                       # 示例程序
└── README.md
```

---

## 运行测试

```bash
# 引导编译器流水线测试（19 项）
python3 tests/bootstrap/test_pipeline.py

# 泛型测试
python3 tests/bootstrap/test_generics.py

# 借用检查测试
python3 tests/bootstrap/test_borrow.py

# 自举编译器测试
python3 tests/selfhost/test_compile.py
```

### 通过 Python 调用流水线

```python
import sys
sys.path.insert(0, 'bootstrap')
from corec.frontend.lexer import Lexer
from corec.frontend.parser import Parser
from corec.frontend.name_resolver import NameResolver
from corec.frontend.desugar import MatchDesugarer
from corec.frontend.type_checker import TypeChecker
from corec.frontend.ir_gen import IRGen
from corec.backend.interpreter import Interpreter

src = '''
fn add(a: int, b: int) -> int { return a + b; }
fn main() -> int { return add(3, 4); }
'''
lex = Lexer(src)
ast = Parser(lex.tokenize()).parse_compilation_unit()
resolver = NameResolver(); resolver.resolve(ast)
desugarer = MatchDesugarer(resolver.symtab)
ast = desugarer.desugar(ast)
checker = TypeChecker(resolver.symtab); checker.check(ast)
ir_gen = IRGen(resolver.symtab); mod = ir_gen.gen_module(ast)
interp = Interpreter(mod); print(interp.run('main', []))   # 输出 7
```


## 贡献

当前项目处于早期阶段，欢迎参与设计讨论和实验性实现。
请参阅 docs/ 下的设计文档了解整体构想。

---

## 许可

GNU General Public License v3.0（含 GPLv3 第 7 节附加许可）
