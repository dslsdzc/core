# Core 规约系统设计

> 规约 = 图上的约束。

## 一、哲学

Core 的语义中间表示是数据流图（`.cir`），图穷尽了程序的全部语义。规约不是对代码的"另一套描述"，而是**图上的约束标注**。

```
# 正常编译（无规约）
corec build file.cr         → .cir + .ccr

# 编译 + 规约
corec build file.cr -s      → .cir + .ccr + 自动生成 file.csp → .csr

验证 = 证明图的所有可达状态满足图上的约束。
```

**.csp 是编译器自动生成的：**
- 包含所有函数的声明骨架 + 自动推导标签
- 用户在这个 `.csp` 里手写 `#check` / `#ensure` / `spec fn`
- 下次 `-s` 重新生成：新函数加入、删除的函数移除、已有手写规约保留
- 版本管理：`.csp` 应该入版本库

`.csr` 是将 `.csp` 中的规约约束（check/ensure/invariant/spec fn）编译为 TagNode 元数据的二进制序列化，与 `.cir`（DFNode）配套供验证工具消费。

## 二、平民化原理

**不需要写公式，不需要学数理逻辑。规约用 Core 语言本身书写。**

规约分三层，同一语言、同一 IR 格式承载：

| 层级 | 写法 | 谁负责 | 例 |
|------|------|--------|----|
| 编译器自动推导 | 零手写，.csr 自动附带 | 编译器（图结构分析） | `#pure`, `#terminating` 等 |
| 简单范围 | 一行 `#check` / `#ensure` | 用户写，编译器验证 | `#ensure(result > 0)` |
| 检查函数 | 用 Core 写一个纯函数 | 用户写，编译器验证 | `spec fn ... -> bool { ... }` |

三个层级最终都编译为 `.cir` 的规约 DFNode（条件表达式）+ `.csr` 的 TagNode（约束元数据），对验证工具无差别。

## 三、文件格式

### `.cr` — 实现源码（也可内联规约）

```core
// 简单的范围
fn divide(a: int, b: int) -> int
    #check(b != 0)
    #ensure(result != None)
{
    if b == 0 { return None; }
    return Some(a / b);
}

// 引用外部检查函数
fn sort(a: [int]) -> [int]
    #ensure(auto::sort_check(a, result))
{
    // 冒泡排序实现
}
```

### `.csp` — 编译器自动生成的规约文件

`corec build file.cr -s` 自动生成 `file.csp`：

```core
// file: sort.csp
// 自动生成于 2026-07-11
// 用户在此文件中手写规约，下次 -s 保留已有内容

// [auto] 编译器自动推导的标签（只读区域）
// #pure  #len_preserved  #terminating

// [user] 用户在此书写规约
#check(/* 用户填写前置条件 */)
#ensure(/* 用户填写后置条件 */)

// 检查函数 —— 用 Core 语言写规约
spec fn sort_check(input: [int], result: [int]) -> bool {
    // 编译器生成的骨架：已从图模式推导部分性质
    // ① 长度守恒（已从图结构推导）
    if result.len() != |input| { return false; }
    // ② 有序性（图有比较+交换模式，但需要用户确认）
    // TODO: 填写有序性检查
    // ③ 排列性质（编译器无法完全推导，需要用户补全）
    // TODO: 填写排列检查
    return true;
}

// 类型不变量
spec fn vec_invariant[T](v: Vec[T]) -> bool {
    return v.len <= v.cap && v.data != null;
}
```

生成规则：
- `-s` 第一次运行：生成完整的 `.csp`，包含所有函数的声明骨架
- `-s` 再次运行：保留用户手写内容，新增函数加入，删除的函数移除
- `.csp` 应该入版本库

### `.csr` — 规约约束的二进制序列化

详见 `docs/ir-schema/corespecir-schema.md`。

```
.csr 文件头 → TagNode 数组 → 符号引用表 → 函数约束映射 → 字符串表
```

每条 `#check`、`#ensure`、`#invariant` 以及每个 `spec fn` 的身体，都编译为 `.cir` 的规约 DFNode（条件表达式）+ `.csr` 的 TagNode（约束元数据：类型、验证状态、行列号）。TagNode 通过 `target_node` 指向 `.cir` 中对应的 DFNode，通过 `condition_node` 指向条件表达式所在的 DFNode。

## 四、编译器自动推导（零门槛的核心）

编译器从 `.cir` 图结构中自动推导性质，写入 `.csr`，不需要用户写任何东西。

### 自动推导的标签

| 标签 | 推导条件（图模式） | 例 |
|------|-------------------|----|
| `#pure` | 无 STORE 到外部变量、无 CALL 到非纯函数 | |
| `#deterministic` | 纯 + 无随机/外部依赖 | |
| `#terminating` | 所有循环有可识别变体 | |
| `#no_alloc` | 无 ALLOC/ALLOC_ARRAY 节点 | |
| `#no_throw` | 无异常路径 | |
| `#safe_index` | 所有索引访问在边界内 | |
| `#len_preserved` | 集合长度不变（无插入/删除） | `sort` |
| `#atomic` | 配对操作之间无并发观测点 | `transfer` |

### 自动生成的检查函数（骨架）

编译器识别常见图模式，自动生成检查函数代码。用户可以在 `.csp` 中 `#use` 或忽略。

```
fn sort(a: [int]) -> [int]
         ↓ 编译器从图模式识别：
  - 只有比较+交换，无插入/删除 → 生成 #len_preserved
  - 有比较→分支→交换结构     → 生成 auto::sorted 检查函数
  - 纯函数                     → 生成 #pure
         ↓ .csr 自动包含
  #pure
  #len_preserved
  #ifdef auto::sorted
  #ensure(auto::sorted(input, result))

fn transfer(from: &mut Account, to: &mut Account, amt: int)
         ↓ 编译器从图模式识别：
  - from.balance 和 to.balance 有配对的加减
  - 无 yield/recv 在加减之间
         ↓ .csr 自动包含
  #atomic
  #ifdef auto::守恒(from, to, amt)
  #ensure(auto::守恒(from, to, amt))
```

用户看到这些自动生成的约束，可以：
- `#use auto::sorted` — 接受
- `#ignore auto::sorted` — 跳过（编译器不再生成）
- `#check(result.len() == |a|)` — 手写更精确的替代

**模式匹配库可扩展**：社区可以贡献新的图模式 → 标签映射，编译器新增推导能力。

## 五、标签语法（标注/annotation）

使用 `#` 前缀，与 `@`（外部项目引用）区分。

```core
// 在 .cr 或 .csp 中使用
fn foo() -> int
    #pure
    #check(x > 0)

// 自定义标签
#tag sorted = {
    forall i: 0 <= i < result.len() - 1 -> result[i] <= result[i+1]
}
```

`#` 风格：
- 更干净，视觉上区分于代码逻辑
- 不占用 `@`（后者保留给 `import @project`）
- 语义清晰：`#` 标记的东西不影响运行时语义

## 六、检查函数（规约的主力）

检查函数是用 Core 语言写的纯函数，返回值是 `bool`。它们被编译为 `.cir` 图，然后与实现函数的 `.cir` 并列供验证器消费。

```core
// 检查函数的语法特征：
spec fn 函签名 -> bool
    #pure  // 编译器自动标注
{
    // 函数体 —— 纯 Core 代码
    // 可以有变量、循环、分支
    // 不能有 IO、unsafe、外部调用
    return true_or_false;
}
```

### 检查函数 vs 普通函数的区别

| | 普通函数 | 检查函数 |
|---|---|---|
| 编译 | 生成代码 | 只生成 `.cir` + `.csr`，不生成机器码 |
| 副作用 | 可有 | 必须纯 |
| 验证角色 | 被验证的对象 | 验证的标准 |
| 调用规则 | 可在运行时代码中调用 | 不能在运行时代码中调用 |

### 纯公式支持

对于习惯写公式的人，提供语法糖：

```core
// 检查函数写法
spec fn all_nonneg(arr: [int]) -> bool {
    for x in arr:
        if x < 0 { return false; }
    return true;
}

// 等价公式写法（编译器展开为检查函数）
spec fn all_nonneg(arr: [int]) -> bool
    = forall x in arr: x >= 0;
```

## 七、约束的验证

验证器（外部贡献）的操作：

1. 加载 `.cir`（程序图）+ `.csr`（图上约束）
2. 从图结构推导自动标签（标签 = 编译器已证明）
3. 对 `#check`/`#ensure`：生成证明义务 → SMT / 溯因推理 / 归纳
4. 对 `spec fn`：检查实现函数的图是否蕴含检查函数的图
5. 输出：每条约束绿（证明）/ 黄（部分证明）/ 红（未证明）

约束可以同时在开发期插桩运行时 assert 检查，验证器到位前也有保障。

## 八、完整管线

```
# 编译（无规约）
corec build file.cr
  → tokenize/parse/check/ir_gen/lower
  → file.cir + file.ccr

# 编译 + 规约
corec build file.cr -s
  → tokenize/parse/check/ir_gen/lower
  → file.cir + file.ccr
  → 自动生成/更新 file.csp
      ├── 所有函数的声明骨架
      ├── 编译器自动推导的标签（从 .cir 图结构分析）
      └── 用户上次手写的规约（保留）
  → 解析 file.csp → spec ir_gen → 输出 file.csr
      ├── DFNode[]（指令节点 + 规约约束节点）
      ├── TagNode[]（约束元数据：check/ensure/invariant/标签）
      └── 符号引用表（指向 .cir 中的函数/变量）

# 验证（外部工具）
verify file.csr
  → 加载 .cir + .csr
  → 验证 pending 约束
  → 输出验证报告
```

编译器输出的 `.csr` 包含：
- 编译器自动推导的全部标签（status=auto_proven）
- 用户写的 `#check/#ensure/#invariant`（status=pending）
- `spec fn` 编译为 spec 图节点（status=pending）

## 九、内核场景的应用

普通开发者的代码：编译器自动推导 + 可能几行 `#ensure`。

内核级别的代码：

```core
spec fn pagetable_invariant(pt: &PageTable) -> bool {
    for virt in pt.mappings {
        entry := pt.mappings[virt];
        // 虚拟地址到物理地址的映射
        if entry.present {
            // 物理地址必须在有效范围
            if entry.phys < PHYS_START || entry.phys >= PHYS_END {
                return false;
            }
            // 用户态不能映射内核页
            if virt < USER_END && entry.privilege == KERNEL {
                return false;
            }
        }
    }
    return true;
}

fn map_page(pt: &mut PageTable, virt: Addr, phys: Addr, flags: u64)
    #check(PHYS_START <= phys && phys < PHYS_END)
    #check(virt < USER_END)   // 用户态进程不能映射内核地址
    #ensure(pagetable_invariant(pt))
```

即使在这里，规约还是 Core 代码——变量、循环、分支。不是公式，是你能读也能写的代码。

内核的量词（`for all mappings`）写成了 `for` 循环，编译器把它编译成纯逻辑约束。纯公式语法糖（`forall`）也存在，但只是编译器的展开。

## 十、总结

```
不需要学新语言 ── 规约 = Core 函数
不需要写公式  ── 编译器从图推导能推导的一切
不需要自己来  ── 剩下的用同一门语言写检查函数
```

完全形式化的代价被压缩到最低：只有编译器推导不了的函数正确性需要手写检查函数，而检查函数本身也是 Core 代码，不是数理逻辑公式。
