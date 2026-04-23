# Core Programming Language

**Core** 是一门全新的、完全自主设计的编程语言，以及一套围绕“语义保鲜”理念构建的编译工具链。  
其核心是一个保留全部类型与语义信息的中间表示（IR），并原生支持完全形式化验证。

---

## 项目状态

当前处于 **引导编译器（bootstrap）开发阶段**，使用 Python 实现前端、IR 生成器及解释器。  
已实现并验证的核心特性：

- ✅ 基本数据类型：`int`、`float`、`bool`、`string`、`char`、`unit`、`never`
- ✅ 变量定义与赋值（`let`、`mut`、`move`）
- ✅ 函数定义、调用、泛型占位
- ✅ 控制流：`if` / `else`、`loop` + `break` / `continue`
- ✅ 复合类型：结构体定义、字面量初始化、字段访问、方法（含 `self`）
- ✅ 嵌套结构体
- ✅ 比较运算（`>`, `<`, `>=`, `<=`, `==`, `!=`）和逻辑运算（`&&`, `||`）
- ✅ 多基本块 IR 与控制流图执行
- ✅ 语义检查：名字解析 + 类型检查
- ⬜ 枚举与模式匹配（`match`）
- ⬜ 泛型（结构体/函数/方法）
- ⬜ 模块系统与外文件复用
- ⬜ 规约层 IR 与形式化验证
- ⬜ 自举编译器（Core → IR → C → 原生可执行）

---

## 项目结构

```

.
├── bootstrap/                      # 引导编译器（Python 实现）
│   ├── corec/
│   │   ├── syntax/               # AST 定义、Token、关键字
│   │   ├── frontend/             # 语法检查器、名字解析、类型检查、IR 生成
│   │   ├── ir/                     # IR 数据结构（coreir.py、spec_node 等）
│   │   ├── backend/             # 解释器、多平台后端占位
│   │   └── verifier/               # 形式化验证器（占位）
│   └── tests/
├── src/                             # 自举编译器 + 标准库（Core 源码，待实现）
│   ├── compiler/
│   ├── stdlib/
│   └── runtime/
├── spec/                           # 形式规约文件（.corespec 示例）
├── examples/                      # 示例程序
├── tests/                           # 集成测试
├── grammar/                      # 语法形式定义（EBNF）
├── docs/                           # 设计文档（项目书、执行模型等）
└── README.md

```

---

## 快速开始

### 环境要求
- Python 3.10+（无需额外依赖）

### 运行测试
```bash
# 运行全部综合测试
python3 test_all.py
```

预期输出：

```
[PASS] Arithmetic & Call: got 7
[PASS] Loop & Break: got 10
[PASS] If/Else: got 7
[PASS] Struct Field Access: got 30
[PASS] Method Call: got 3
[PASS] Nested Structs: got 15
[PASS] Comparisons: got 1
All tests completed.
```

运行单个 Core 程序

```python
import sys
sys.path.insert(0, 'bootstrap')
from corec.frontend.lexer import Lexer
from corec.frontend.parser import Parser
from corec.frontend.name_resolver import NameResolver
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
checker = TypeChecker(resolver.symtab); checker.check(ast)
ir_gen = IRGen(resolver.symtab); mod = ir_gen.gen_module(ast)
interp = Interpreter(mod); print(interp.run('main', []))   # 输出 7
```

---

设计哲学

· 语义 IR 是单一事实源：编译时不丢弃任何类型/语义信息，IR 可被验证工具直接消费。
· 双轨规约：实现层 IR 与规约层 IR 分立，通过符号引用关联，支持独立演化与工具解耦。
· 程序即数据流图：无模式概念，代码结构决定执行方式（DAG/静态循环/动态图）。
· 渐进式学习：从基础语法到并发，同一门语言陪伴开发者走完从零到内核的旅程。

---

贡献

当前项目处于早期阶段，欢迎参与设计讨论和实验性实现。
请参阅 docs/ 下的设计文档了解整体构想。

---

许可
GNU General Public License v3.0

