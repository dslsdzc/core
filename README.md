# Core Programming Language

**Core** 是一门全新的、完全自主设计的编程语言，以及一套围绕"语义保鲜"理念构建的编译工具链。  
其核心是一个保留全部类型与语义信息的中间表示（IR），并原生支持完全形式化验证。

---

## 项目状态

当前处于 **引导编译器（bootstrap）开发阶段**，使用 Python 实现前端、IR 生成器及解释器。  
已实现并验证的核心特性：

- ✅ 基本数据类型：`int`、`float`、`bool`、`string`、`char`、`unit`、`never`
- ✅ 变量定义与赋值（`:=` / `: type`、`auto`/`.` 类型推导、`mut`、`pub`）
- ✅ 函数定义、调用、泛型
- ✅ 控制流：`if` / `else`、`loop` + `break` / `continue`、`for`、`while`
- ✅ 结构体定义、字段访问、方法（含 `self`）
- ✅ 枚举与模式匹配（`match`）
- ✅ 嵌套结构体
- ✅ 比较运算（`>`, `<`, `>=`, `<=`, `==`, `!=`）和逻辑运算（`&&`, `||`）
- ✅ 多基本块 IR 与控制流图执行
- ✅ 语义检查：名字解析 + 类型检查
- ✅ 借用检查（borrow checker）
- ✅ 模块系统：多文件编译、导入、`_import.cr` 批量导入
- ✅ 数组、字符串、引用、`Option`/`Result` 类型
- ⬜ 规约层 IR 与形式化验证
- ⬜ 自举编译器稳定产出原生二进制

---

## 项目结构

```
.
├── bootstrap/                      # 引导编译器（Python 实现）
│   └── corec/
│       ├── syntax/               # AST 定义、Token、关键字
│       ├── frontend/             # 词法/语法/名字解析/脱糖/类型检查/IR 生成
│       ├── ir/                   # IR 数据结构
│       ├── backend/              # 解释器、ARM64/x86-64 代码生成
│       ├── verifier/             # 形式化验证（占位）
│       └── utils/                # 模块加载器等工具
├── src/                             # 自举编译器（Core 源码）
│   ├── compiler/                  # 编译器各模块（词法/语法/检查/IR/后端）
│   ├── stdlib/                    # 标准库（io、math、collections 等）
│   └── runtime/                   # 运行时支持（compiler_rt.c 等）
├── tests/                           # 测试
│   ├── bootstrap/                 # 引导编译器流水线测试
│   ├── selfhost/                  # 自举编译器测试
│   └── suite/                     # 集成测试（.cr 源文件）
├── tools/
│   └── corec                      # 命令行入口（编译/运行 Core 程序）
├── build/
│   └── corec                      # 自举编译器原生 x86-64 二进制
├── grammar/                        # EBNF 语法定义
├── docs/                           # 设计文档
│   ├── project-book.md          # 项目书
│   ├── language-syntax.md       # 语言语法参考
│   ├── dataflow-design.md       # 数据流执行模型设计图
│   └── execution-model.md       # 执行模型设计书
├── spec/                           # 形式规约文件（.corespec 示例）
├── examples/                       # 示例程序
└── README.md
```

---

## 快速开始

### 环境要求
- Python 3.10+（无需额外依赖）
- ARM64 平台（原生编译需要 `as` / `ld`）

### 运行测试

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

### 使用命令行工具

```bash
# Python 引导编译器：编译 .cr → ARM64 原生可执行文件
python3 tools/corec build FILE.cr -o OUTPUT

# 生成线性 IR 转储（.ccr）
python3 tools/corec ir FILE.cr
```

### 自举编译器原生二进制

```bash
# 构建自举编译器（Core 写编译器，通过 Python 引导编译为 x86-64 原生二进制）
python3 build_selfhost_native.py

# 使用原生二进制编译 Core 程序
./build/corec input.cr          # 输出 output.s
```

`build/corec` 是 Core 自举编译器的 x86-64 原生可执行文件。由 `build_selfhost_native.py` 构建，经过 Python 引导编译器流水线，直接生成 x86-64 汇编并静态链接。无需解释器、无需 GCC。

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


贡献

当前项目处于早期阶段，欢迎参与设计讨论和实验性实现。
请参阅 docs/ 下的设计文档了解整体构想。

---

许可
GNU General Public License v3.0
