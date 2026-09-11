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
| Stage 0 | Python 引导编译器 | `build/corec`（前端）+ `build/corearch`（后端） | 正常 |
| Stage 1 | `build/corec` + `build/corearch` 编译自举编译器源码 | `build/corec2`（自编译前端） | 可运行 |
| Stage 2 | `build/corec2` + `build/corearch` 再次编译 | `build/corec3`（二次自编译） | 可运行 |

> 注意（2026-08 现状）：`corec2 check` 卡在 tokenizer（约 9 个全局变量未注册进 `g_ir_globals`，赋值静默丢弃）——自举阻塞项，见 TODO.md。

### 已实现的核心特性

| 类别 | 特性 | 状态 |
|------|------|------|
| **类型系统** | `int`、`dex`、`bool`、`string`、`char`、`unit`、`never` | 完成 |
| | 泛型函数与泛型结构体 | 完成 |
| | `auto` / `.` 类型推导、位宽后缀 `_i32` `_u64`（`_f32`/`_f64` 保留为 apx 的 CPU 位宽标注） | 完成 |
| **变量** | `:=` / `: type` 声明，`mut` / `pub` / `apx` 标签，批量声明 | 完成 |
| **函数** | 函数定义、调用、单行函数体、`pub fn` 可见性 | 完成 |
| **控制流** | `if` / `else` / `elif`、`while`、`loop` + `break`/`continue`、`for` 区间和数组迭代 | 完成 |
| | region 嵌套式（SG_IF/LOOP/FOR/FLOW/UNSAFE + state edges + .ccr v5，即 HDFG 结构） | 完成 |
| **并发** | `go f(args)` / `go var start..end expr` 协程生成 | 完成（单 M 端到端） |
| | 协作式 Fiber 调度器、缓冲通道（阻塞） | 完成（单 M 验证） |
| | 多 M worker 线程 | 未完成（TODO bug 2） |
| | `await` 异步等待 | 未完成 |
| **复合类型** | 结构体、枚举 + `match`、元组、定长数组、切片 | 完成 |
| **方法** | `impl` 块、`self` / `&self` / `&mut self`、`impl Trait for Type` | 完成 |
| **引用与借用** | `&T` / `&mut T`、借用检查（Borrow Checker） | 完成 |
| **内存模型** | Arena 内存模型（init/new/reset + 子图绑定 + mmap 堆扩展） | 完成 |
| | 指针安全三 pass：PointerAnalysis / RegionCheck / ProvenanceVerify | 完成 |
| **@ 内建** | `@sizeOf` `@alignOf` `@fields` `@hasField` `@field` `@typeInfo` `@comptime` `@inline` `@no_bounds_check` `@fast` `@unroll` `@section`（12 个） | 完成 |
| **编译器** | 增量缓存（函数级 .cir，默认开启 + clean-cache） | 完成 |
| | `@hotpatch` 滚动更新（IR_HOTPATCH_ROUTE + SIGHUP 热加载） | 完成 |
| | 惰性求值（IR_LAZY_THUNK/FORCE，调用级） | 部分（thunk/force 为值搬运，无实际延迟） |
| | 控制流自动惰性（编译期指令下沉路线） | 设计定案，待实现 |
| **汇编层** | `.crasm` 统一汇编抽象层（虚拟寄存器 + 平台映射表） | 设计完成（docs/maintainer/design/crasm.md） |
| **语义检查** | 名字解析 + 类型检查、结构化错误码 + 源码定位 | 完成 |
| **模块系统** | `import`、`fileid`、`@project`、`_import.cr`、依赖裁剪 | 完成 |
| **标准库** | `io.cr` / `cli.cr` / `toml.cr` | 完成 |
| | `math.cr` / `collections.cr` | 部分（stub，TODO bug 4） |
| | 平台桥抽象：I/O 流（程序 = 流转导器）/ 随机 / 哈希 / 时钟（语义接口 + 后端实现） | 设计定案（[spec](docs/superpowers/specs/2026-08-16-platform-abstract-design.md)），待实现 |
| **编译器基础设施** | 自举编译器（Core 写编译器）、x86-64 ELF 直接输出 | 完成 |
| | `build`/`check`/`ccr`/`cir`/`run`/`clean-cache` 子命令 | 完成 |
| | CIR HDFG（带完整类型/语义信息）、`.ccr` 线性 CFG | 完成 |
| **形式化验证** | 规约层 IR / 验证条件生成 / SMT 求解器接口 | 占位 |
| **发布与治理** | Arch Linux PKGBUILD | 完成 |
| | GitFlow 治理：双 ruleset（main 仅维护者合入 / develop 集成分支）+ 签名提交 + merge queue（免费计划降级为手动合入） | 完成 |
| | CI 骨架（Rust 模板重写：PR 快速层 + 完整层） | 部分（GitHub 侧注册冻结，待自愈） |

### 未完成与已知限制

| 类别 | 项 | 参考 |
|------|-----|------|
| 自举 | corec2 tokenizer 死循环（约 9 个全局变量未注册进 g_ir_globals） | TODO 自举阻塞项 |
| | O1 自举稳定性（pass_cse 大函数崩溃） | TODO |
| 解释器 | for 循环 / 递归 / 泛型函数不支持 | TODO 预存 bug 3 |
| 运行时 | arena bump 分配死循环（编码已 objdump 排除，emit_alloc_body 运行时逻辑待查） | TODO 预存 bug 5 |
| 内存 | 完整自举 1 GiB bump heap 峰值（需按函数回收而非扩堆） | TODO 预存 bug 1 |
| 并发 | 多 M worker 未连调度器、channel 队列未并发验证 | TODO 预存 bug 2 |
| CI | 工作流注册冻结（注册表陈旧，GitHub 侧）——develop 的 required_status_checks 暂移除 | spec §3.3 |
| 语言 | 控制流自动惰性、`.crasm` 汇编层、分布式（跨机器/QUIC） | 设计完成/定案，待实现 |

---

## 快速开始

```bash
# 构建自举编译器
python3 build_selfhost_native.py

# -c 模式：直接执行代码（解释器）
./build/corec run '__builtin_println("hello"); 42'

# 编译文件
./build/corec ccr hello.cr              # → hello.ccr
./build/corec cir hello.cr              # → hello.cir（HDFG）
./build/corec build hello.cr --static   # → a.out（ELF，无需 as/ld）
as -o hello.o hello.s && ld ...          # 或用传统路径

# 通过引导编译器（Python）编译
python3 tools/corec ir hello.cr      # → .cir HDFG
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
│   ├── ir/                  # IR 数据结构（CIR HDFG / CCR 线性 CFG）
│   ├── backend/             # 解释器、ARM64/x86-64 代码生成
│   └── verifier/            # 形式化验证（占位）
├── src/
│   ├── compiler/            # 自举编译器（Core 源码）
│   │   ├── ast.cr            # Token 定义、AST 节点、IR 指令、类型常量
│   │   ├── lexer.cr          # 词法分析器
│   │   ├── parser.cr         # 语法分析器
│   │   ├── checker.cr        # 类型检查 + 借用检查
│   │   ├── ir_gen.cr, dataflow.cr  # IR 生成 + HDFG
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
