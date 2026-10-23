# 前端机器边界清理计划

## 概述

这份计划处理前端代码中的机器映射泄漏。前端指 `corec` 中从词法、语法、类型检查到 IR 生成的部分。后端指 `src/arch`、`src/format`、`src/os` 和 `src/targets`。计划只改变代码所在层和接口位置，不改变语言语义、`.ccr` 格式、ELF 产物和运行结果。

## 范围

| 任务 | 内容 | 主要位置 | 产物要求 |
|---|---|---|---|
| 1 | 把 x86 后端数组和扩容函数移出共享前端文件 | `globals.cr`、`dyn_arr.cr`、`src/arch/x86_64/` | 逐字节不变 |
| 2 | 把后端入口、后端旗标和分配器契约移出 `src/compiler` | `corearch.cr`、`backend_flags.cr`、`regalloc-consistency.cr` | 逐字节不变 |
| 3 | 拆分 HDFG 构图与 `.ccr` 线性调度降级 | `dataflow.cr` | 逐字节不变 |
| 4 | 建立 Mapping 接口，迁移尺寸、对齐和偏移计算 | `ir_gen.cr`、`provenance_verify.cr`、`ptr_analysis.cr` | 逐字节不变 |
| 5 | 把环境变量和 OS 内建判断移出语义检查器 | `checker.cr`、`main.cr`、`globals.cr` | 行为不变 |
| 6 | 把 `.ccr` 记录布局和后端优化键移出语义模块 | `type_terms.cr`、`iface_registry.cr`、`ty_shadow.cr`、`ast.cr` | 格式不变 |
| 7 | 迁移数值字面量转换，登记无法在当前 ABI 下移除的机器限制 | `lexer.cr`、`parser.cr`、`goroutine.cr` | 行为不变 |

## 全局约束

1. 每个任务单独提交。一个任务验证通过后再开始下一个任务。
2. 任务 1 到 4 要求 `.ccr`、ELF 和 canary 值逐字节不变。任务 5 到 7 要求可观察行为不变；如果必须改变产物，先停止并记录原因。
3. 不使用全局字符串替换修改代码。移动函数时保留函数名、参数名、常量名和注释中的技术事实。
4. `docs/superpowers/specs/2026-10-23-pattern-matching-ir-design.md` 是当前工作区中的独立文件，不纳入本次提交。
5. 每个任务完成后运行：

```bash
nice -n 19 python3 build_selfhost_native.py
./build/corec check src/compiler
nice -n 19 python3 tests/selfhost/test_type_engine.py
nice -n 19 python3 tests/selfhost/test_purity.py
```

6. 任务 1、2、3、6、7 还要运行：

```bash
nice -n 19 bash tools/baseline/canary_check.sh
```

7. 任务 4 还要运行旧计划第 5 节的逐处证明检查，保留 `-1` 后备路径。正控和反控都通过后才能继续。
8. 全部任务完成后运行三阶段自举，并比较 `corec2` 与 `corec3`：

```bash
nice -n 19 ./build/corec build src/compiler/main.cr -o /tmp/corec2 --static -O 0
nice -n 19 /tmp/corec2 build src/compiler/main.cr -o /tmp/corec3 --static -O 0
cmp /tmp/corec2 /tmp/corec3
```

## 任务 1：移出 x86 后端数组

### 文件

- `src/compiler/globals.cr`
- `src/compiler/dyn_arr.cr`
- 新建 `src/arch/x86_64/backend_globals.cr`
- 新建 `src/arch/x86_64/backend_arrays.cr`
- `build_selfhost_native.py`
- `src/targets/x86_64-linux/_import.cr`

### 步骤

1. 在 `src/arch/x86_64/backend_globals.cr` 中声明所有 `g_x86_*` 全局变量。保留原有的字段顺序、类型和注释。
2. 在 `src/arch/x86_64/backend_arrays.cr` 中放置 `grow_x86_vars`、`grow_is_enum`、`grow_is_global`、`grow_global_off`、`grow_str_offs`、`grow_rip_patch`。
3. 从 `src/compiler/globals.cr` 删除这些 `g_x86_*` 声明。保留 `g_opt_*`、`g_sgs`、`.so` 侧表和规格注记侧表。
4. 从 `src/compiler/dyn_arr.cr` 删除 x86 扩容函数。保留 `grow_so_side`、`grow_spec_side` 和其余前端扩容函数。
5. 在 `build_selfhost_native.py` 的 `arch_x86_64_files` 开头加入两个新文件，顺序为 `backend_globals.cr`、`backend_arrays.cr`、`regalloc.cr`。
6. 在 `src/targets/x86_64-linux/_import.cr` 中加入 `import backend_globals` 和 `import backend_arrays`，位置在 `import regalloc` 之前。

### 验收

1. 构建通过，`corec`、`corearch`、`corelsp` 三个清单都通过存在性检查。
2. `./build/corec check src/compiler` 通过。
3. `src/compiler/globals.cr` 和 `src/compiler/dyn_arr.cr` 中不再出现 `g_x86_` 或 `grow_x86_`。任务 2 完成前，`src/compiler/corearch.cr` 仍会引用这些符号。
4. canary 五条全部通过。
5. `.ccr` 和 ELF 产物与改动前逐字节相同。

## 任务 2：移出后端入口和契约文件

### 文件

- `src/compiler/corearch.cr` 移到 `src/arch/x86_64/corearch.cr`
- `src/compiler/backend_flags.cr` 移到 `src/arch/x86_64/backend_flags.cr`
- `src/compiler/regalloc-consistency.cr` 移到 `docs/maintainer/design/regalloc-consistency.md`
- `build_selfhost_native.py`
- `src/targets/x86_64-linux/_import.cr`
- 相关路径引用

### 步骤

1. 移动文件，保留文件内部函数名和代码。
2. 更新 `backend_support_files` 中的路径。
3. 更新 `src/targets/x86_64-linux/_import.cr` 的导入名。
4. 搜索 `src/compiler/corearch.cr`、`src/compiler/backend_flags.cr` 和 `regalloc-consistency.cr` 的路径引用，全部改为新位置。
5. 不修改 `src/targets/x86_64-linux/main.cr` 的行为。

### 验收

1. 构建通过。
2. `src/compiler` 目录不再包含这三个文件。
3. canary 五条全部通过。
4. `corearch` 产物逐字节不变。

## 任务 3：拆分 dataflow 的构图与降级

### 文件

- `src/compiler/dataflow.cr`
- 新建 `src/compiler/ccr_lower.cr`
- `build_selfhost_native.py`

### 步骤

1. 保留 HDFG 节点、区域、变量生产者、纯度计算和 DOT 输出在 `dataflow.cr`。
2. 把 `lower_to_ccr` 及其专用辅助函数移到 `ccr_lower.cr`。
3. 在 `corec_files` 中把 `ccr_lower.cr` 放在 `dataflow.cr` 之后、`ccr_io.cr` 之前。
4. `corearch` 清单不加入 `ccr_lower.cr`，因为后端从 `.ccr` 重建线性调度。
5. 保留所有函数名和签名。

### 验收

1. 构建通过。
2. `./build/corec check src/compiler` 通过。
3. 全量自举产物逐字节一致。
4. canary 五条全部通过。

## 任务 4：建立 Mapping 接口

### 文件

- 新建 `src/compiler/mapping.cr`
- `src/compiler/ir_gen.cr`
- `src/compiler/provenance_verify.cr`
- `src/compiler/ptr_analysis.cr`
- `build_selfhost_native.py`

### 接口

```core
fn mp_size(ti: int) -> int
fn mp_align(ti: int) -> int
fn mp_field_offset(field_index: int) -> int
fn mp_stride(ti: int) -> int
fn mp_extent(count: int, ti: int) -> int
fn mp_offset(index: int, ti: int) -> int
```

这些函数在 `mapping.cr` 中实现。当前实现使用经典 x86-64 映射，返回值与现有 `type_size`、`type_align` 和 `* 8` 完全相同。接口是后续非经典映射的替换点，不在本任务改变数值。

### 步骤

1. 把 `ir_gen.cr` 的 `type_size` 和 `type_align` 函数体改为调用 `mp_size` 和 `mp_align`，或者把调用点直接改为 `mp_size` 和 `mp_align`。
2. 把 `provenance_verify.cr` 的两处 `s1 * 8` 和 `si_field_count(fi) * 8` 改为 `mp_extent`。
3. 把 `ptr_analysis.cr` 的 `idx_val * 8` 和 `low * 8` 改为 `mp_offset`。
4. 保留所有 `-1` 未知分支和运行时检查路径。
5. 在 `corec_files` 中加入 `mapping.cr`，位置在 `checker.cr` 之后、`type_terms.cr` 之前。

### 验收

1. 构建通过。
2. 旧计划第 5 节逐处证明表更新，`-1` 路径仍可触发。
3. 正控程序仍被拒绝，反控程序仍返回 0。
4. `.ccr`、ELF 和 canary 值逐字节不变。

## 任务 5：移出环境变量和 OS 内建判断

### 文件

- `src/compiler/checker.cr`
- `src/compiler/globals.cr`
- `src/compiler/main.cr`
- 新建 `src/compiler/prelude.cr`

### 步骤

1. 在 `prelude.cr` 增加 `prelude_init()`，读取 `CORE_S1P` 并设置 `g_s1p_seen` 和 `g_s1p_on`。
2. `checker.cr` 的两个 S1P 入口在首次调用时调用 `prelude_init()`，不再直接读取环境变量。
3. 删除 `checker.cr` 中两处 `get_env("CORE_S1P")`。
4. 把 `syscall3` 和 `syscall4` 的返回类型判断移到 `prelude.cr`。`checker.cr` 只调用 `prelude_builtin_return_ti`。
5. 删除未使用的 `g_ni_syscall3` 和 `g_ni_syscall4`，后端仍然使用的同名状态移到 `backend_globals.cr`。
6. 不改变 `extern` 的可选类型拒绝规则。该规则属于外部接口边界，保留在解析器中，并在文档中记录原因。

### 验收

1. `CORE_S1P=1 ./build/corec check <file>` 与改动前输出相同。
2. 不设置 `CORE_S1P` 时输出相同。
3. `syscall3` 和 `syscall4` 的类型检查结果相同。
4. 全部自举测试和 canary 通过。

## 任务 6：移出 `.ccr` 记录布局和后端优化键

### 文件

- 新建 `src/compiler/ccr_schema.cr`
- `src/compiler/type_terms.cr`
- `src/compiler/iface_registry.cr`
- `src/compiler/ty_shadow.cr`
- `src/compiler/ast.cr`
- `build_selfhost_native.py`
- `src/targets/x86_64-linux/_import.cr`

### 步骤

1. 把 `ESZ_TYPE_TERM`、`ESZ_TYPE_TERM_DISK`、`OFF_TT_*` 和 `OPT_META_STRIDE` 移到 `ccr_schema.cr`。`ESZ_IFACE_ENTRY`、`OFF_IFM_*` 是解析器和类型桥接层直接使用的内存表布局，保留在 `dyn_arr.cr`，避免语义模块反向依赖载体层。
2. `type_terms.cr` 保留类型项结构和判定函数，只引用 `ccr_schema.cr` 的常量。`iface_registry.cr` 和 `ty_shadow.cr` 的内存表访问保持不变。
3. 把 `OPT_KEY_REG_ASSIGN`、`OPT_KEY_STACK_SHARE` 和 `OPT_KEY_CSE` 移到后端使用的 `src/arch/x86_64/backend_schema.cr`，因为只有后端读取这些键。
4. `ast.cr` 不再声明后端优化键。`ir_gen.cr` 和 `opt.cr` 不使用这些键。
5. 更新 `corec`、`corearch`、`corelsp` 三个清单的常量可见顺序。

### 验收

1. 三个构建单元都通过。
2. `.ccr` 的 TYPE、IFACE、NOD 段逐字节不变。
3. `test_ccr_types.py`、`test_ccr_v7.py` 通过。
4. canary 五条全部通过。

## 任务 7：数值字面量与执行策略

### 文件

- `src/compiler/lexer.cr`
- `src/compiler/parser.cr`
- `src/stdlib/goroutine.cr`
- 相关文档

### 步骤

1. 把 `str_to_f64_bits` 从 `lexer.cr` 移到 `parser.cr` 或独立的数值字面量模块。词法层只保留原始数字字符串。
2. 为 `str_int_literal` 的 64 位上限增加明确注释，说明这是当前 token 载体的编码限制，不是语言语义上限。是否支持任意精度由后续多字整数设计决定，本任务不改变行为。
3. 把 `goroutine.cr` 的 `alloc(16384)` 改为命名常量 `G_STACK_SIZE`，值仍为 16384。该常量属于运行时执行策略，不进入前端。
4. 更新 `docs/maintainer/adr/adr-0017-concurrency-gmp.md` 中的栈尺寸表述，指向 `G_STACK_SIZE`。

### 验收

1. 浮点字面量、整数溢出错误和协程行为的测试结果不变。
2. canary 五条全部通过。
3. 文档链接目标存在。

## 不包含

1. 不改变 `.ccr` 格式、ELF 格式、SysV ABI 和 x86-64 指令编码。
2. 不实现任意精度整数。
3. 不改变 arena 的语义地位，也不改变解释器与 ELF 路径在 arena 和地址上的既有差异。
4. 不修改 `docs/superpowers/specs/2026-10-23-pattern-matching-ir-design.md`。

## 未决问题

1. `extern` 的可选类型拒绝规则是否应移到独立的 FFI 映射层。当前保留在解析器，因为它描述外部接口的表示能力，而不是目标机器细节。
2. `IR_ALLOC_ARRAY` 的元素步长 8 是否应进入 Mapping 接口。当前后端固定按 8 计算，前置改动需要同时修改 IR 语义和后端发射。
3. 64 位整数上限是否解除，取决于多字整数的前端表示和后端运算是否完整覆盖。
