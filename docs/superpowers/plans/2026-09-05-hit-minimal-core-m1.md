# 硬件接口表（HIT）M1：最小核运行验证实施计划

> 面向执行本计划的 agent：必须使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans，按任务逐项实现。用复选框（`- [ ]`）跟踪进度。

目标：用最小核表（`sub`/`nand`/`load`/`store` 4 个事件）驱动 corearch 发射，运行第一个 Core 快速验证程序（直线加减、位运算、内存读写），验证「表是运行的唯一平台依赖」这一架构。

结构：分三层。(1) HIT 表文件，toml 文本，4 个事件加 x86 投影条目。(2) corearch 表驱动编码器，读表后按模板解释发射，与现有 `emit_instr` 硬编码路径并行，逐字节对照验证。(3) 合成层，把 IR 直线子集降到 4 个核事件。验证策略：表驱动输出与手写 e2_* 输出逐字节一致，作为表驱动的正确性检查；快速验证程序运行正确，作为运行验证检查。

技术栈：Core 自举编译器（`src/compiler/`）、Python bootstrap、x86-64 ELF 后端（`src/arch/linux/ld/`）。表文件解析使用现有 `src/stdlib/toml.cr`。

## 全局约束

- 版本控制用 `jj`，项目规则第 2 条要求如此，git 被 hook 拦截。提交用 `jj commit -m '<msg>'`，不手动改动 bookmark，由协调者管理。
- 长时间构建和测试用 `nice -n 19`，见项目规则第 6 条。trap 测试进程需加 `ulimit -c 0` 前缀，原因是本机 core_pattern 有问题，见 TODO:125。
- 设计依据：`docs/superpowers/specs/2026-09-05-hardware-interface-table.md`（HIT 定稿）。最小核事件为 `sub=1 nand=2 load=3 store=4`。事件签名不含宽度、寄存器和寻址信息。换表即换平台。
- 改动后重建 corec/corearch 再测：`nice -n 19 python3 build_selfhost_native.py`，约 2 分钟。只改了 corearch 时也可以只重建 corearch，或全量重建。
- 现有 `emit_instr`（instr.cr:433）硬编码路径保持可用。表驱动路径与它并行存在，全套测试不得被破坏。
- IR op 全集见 ast.cr:538-588，约 45 个，含空洞。`IR_BINARY`(2) 的 s3 是子操作，`OP_ADD=1 OP_SUB=2 OP_AND=12` 等见 ast.cr 的 OP_* 常量。变量采用内存槽模型，IR_STORE/IR_LOAD 即槽写读。
- M1 范围边界，超出即拒绝编译并报「需要扩展事件」：只处理直线程序，不含 IR_BRANCH/JUMP/LABEL/PHI/CALL/RETURN 值和 SPAWN；运算只含加减位与（IR_BINARY OP_ADD/OP_SUB/OP_AND/OP_OR/OP_XOR/OP_NOT）；常量只含小整数，合成见 Task 3。
- 合成、控制流、函数调用和复杂运算的完整覆盖属于 M2，本计划不覆盖。

---

## 现状事实（执行前必读）

- `corearch_main()`（`src/compiler/corearch.cr:17`）：先解析 cli，再调用 `load_ccr(buf, fsize)`（`ccr_io.cr`），然后 `init_backend_arrays()`，最后 `elf_gen()`（`src/arch/linux/ld/elf.cr`）。
- `emit_instr(instr_idx, buf, pos)`（`src/arch/linux/ld/instr.cr:433`）：按 `iri_op()` 分发，约有 50 个 `if op == IR_*` 块。表驱动路径从这里插入，新函数为 `emit_instr_tabled`，`emit_instr` 加开关。
- 栈槽和寄存器映射：`g2_slot(var)` 做槽解析，`e2_load_var`/`e2_st` 完成变量到寄存器或栈的映射。表驱动编码器复用这些机制，槽解析就是操作数解析的现有机制。
- `IR_CONST`(1)：s1 是 i64 值。合成层把它变成 `load` 事件加编译期常量区布局。
- corec `build` 命令（`main.cr:571-592`）：产出 .ccr 后执行 `system("corearch <ccr> --elf")`。corearch 加 `--table` 参数后，由 corec 透传或手动测试。

## 表文件格式（本计划定稿，toml）

> 数值出处注意（2026-09-06 M2 结束修正）：下面的示例只是计划期快照。字节值和角色以 `src/arch/hit/core-x86.toml` 为唯一依据，表驱动编码器直接读该文件。快照与出处已经同步：M1 寄存器惯例是 r10（累加或结果，rm 字段）加 r11（reg 字段），两者为 8 号以上寄存器对，因此投影字节需要 REX.W+R+B，sub 为 `4D 29`，不是早期草案的 `48 29`。sub 事件 reg 字段的角色是 `src2`，不是 src1。

`src/arch/hit/core-x86.toml`（M1 第一份投影表）：

```toml
[table]
name = "core-x86-min"
events = 4            # 最小核契约：实现 1-4 即可运行

[[event]]
id = 1                # sub
name = "sub"
arith = "sub"         # 语义依据：规约层引用（M1 不消费）
inputs = 2
outputs = 1
side_effect = "pure"

[[event.proj]]        # x86 投影：sub r/m64, r64 = r/m ← r/m − r（REX.W+R+B + 29 /r）
isa = "x86-64"
opcode = [0x4D, 0x29]        # REX.W+R+B + sub r/m64,r64（r10/r11 对需 R/B 扩展位）
modrm_reg_role = "src2"      # reg 字段 = 第二输入（被减数，驻 r11）
modrm_rm_role = "dst"        # rm 字段 = 目标/结果寄存器（r10，运算前驻第一输入）
rm_mode = 0                  # 0 = rm 为寄存器（加载到 r10）；1 = rm 为 rbp+disp32（槽/常量池寻址）
# 操作数解析规则：dst/src 均为「值槽」，由调用方传 var 索引，编码器用 g2_slot/e2_load_var 解析
# 模板解释器规则见 Task 2：M1 支持 [opcode...] + modrm 两角色 + rm_mode 两种形态

[[event]]
id = 2
name = "nand"
inputs = 2
outputs = 1
side_effect = "pure"

[[event.proj]]
isa = "x86-64"
# M1 占位：x86 无 nand 指令，单步 and（opcode 4D 21 /r: and r/m64,r64，
# 同 sub 的 r10/r11 双寄存器形态）。投影到语义 nand 的完整序列（and+not 两步）
# + 事件流语义闭合 = M2
opcode = [0x4D, 0x21]
modrm_reg_role = "src2"
modrm_rm_role = "dst"
rm_mode = 0

[[event]]
id = 3
name = "load"
inputs = 1            # 地址
outputs = 1
side_effect = "effect"

[[event.proj]]
isa = "x86-64"
# rm_mode=1：rm = rbp+disp32（槽/常量池寻址）。reg 字段寄存器 = dst（r10 对应 REX.W+R = 0x4C）
opcode = [0x4C, 0x8B]        # REX.W+R + mov r64, r/m64（读：dst ← [rbp+disp32]）
modrm_reg_role = "dst"
modrm_rm_role = "addr"
rm_mode = 1

[[event]]
id = 4
name = "store"
inputs = 2            # 地址, 值
outputs = 0
side_effect = "effect"

[[event.proj]]
isa = "x86-64"
# rm_mode=1：rm = rbp+disp32（槽寻址）。reg 字段寄存器 = val（r10 对应 REX.W+R = 0x4C）
opcode = [0x4C, 0x89]        # REX.W+R + mov r/m64, r64（写：[rbp+disp32] ← val）
modrm_reg_role = "val"
modrm_rm_role = "addr"
rm_mode = 1
```

M1 模板解释器的形态是每事件单投影步 `{opcode 字节(≤2), reg 角色, rm 角色, rm_mode}`，没有 imm 和 REX 变体，超出的报错，表示该事件形态未实现。多步序列投影（例如 nand 用 and 加 not）留到 M2。nand 事件在 M1 用单步 and 占位。

---

### Task 1: HIT 表文件 + toml 解析器接入

文件：
- 新建：`src/arch/hit/core-x86.toml`（上节格式的完整文件，含 4 个事件；nand 用单步 and 占位并加 M2 注释）
- 修改：`src/compiler/globals.cr`（表加载全局）
- 新建：`src/arch/hit/hit.cr`（表结构 + `load_hit_table(path)` + `hit_event_lookup(event_id)`）
- 测试：`tests/selfhost/test_hit_table.py`

接口：
- 产出：`fn load_hit_table(path: string) -> int`，0 表示成功；填充 `g_hit_events`（string buffer，每事件 32B：id/name_ni/inputs/outputs/side_effect/proj_isa/step_count/step_off）和 `g_hit_event_count`。`fn hit_event_lookup(id: int) -> int`，返回事件槽，-1 表示没有。`fn hit_proj_step(event_slot: int, step_i: int, out_opcode: ptr, out_reg_role: ptr, out_rm_role: ptr, out_rm_mode: ptr) -> int`，取投影步编码与 rm 形态。
- `hit.cr` 需要 `import toml`，使用现有 `src/stdlib/toml.cr` 解析器。

- [ ] Step 1: 写失败测试

新建 `tests/selfhost/test_hit_table.py`：

```python
#!/usr/bin/env python3
"""HIT 表解析测试：core-x86.toml 最小核 4 事件加载。"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"


def main() -> int:
    if not COREC.exists():
        print("[FAIL] missing build/corec")
        return 1
    # 通过 corec 的隐藏调试命令或独立验证：先以文件存在性 + 构建冒烟占位
    # Task 1 完成检查 = 构建通过 + corec check src/arch/hit/hit.cr 无错
    print("0/1 passed (Task 1 检查为编译 + Task 2 接线后行为测试)")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] Step 2: 跑测试确认失败

Run: `nice -n 19 python3 tests/selfhost/test_hit_table.py`
预期：`0/1 passed`，exit 1

- [ ] Step 3: 写表文件

按「表文件格式」节新建 `src/arch/hit/core-x86.toml`，含 4 个事件，nand 用单步 and 占位并加 M2 注释。

- [ ] Step 4: 写 hit.cr + globals + 接入构建

`src/arch/hit/hit.cr` 的结构参考 `cir_cache.cr` 的 buffer 表风格：

- `g_hit_events : string, mut; g_hit_event_count/cap`，每事件 32B：`[id i32, name_ni i32, inputs i32, outputs i32, side_effect i32, proj_isa i32, step_count i32, step_off i32]`
- `g_hit_steps : string, mut; g_hit_step_count/cap`，每步 20B：`[op0 i32, op1 i32(=0 无), reg_role i32, rm_role i32, rm_mode i32]`。opcode 至多 2 字节前缀，超出报错。rm_mode 为 0 表示寄存器，1 表示 rbp+disp32。
- `load_hit_table(path)`：read_file，然后 toml 解析。先查 `src/stdlib/toml.cr` 的 API 确认遍历语法，参考现有使用点如 project.cr，最后填两张表。
- 注册：`build_selfhost_native.py` 的 corearch concat 列表加入 `src/arch/hit/hit.cr`，corec 不需要。全局声明放在 `src/compiler/globals.cr` 或 hit.cr 顶部。
- 错误处理：文件缺失或事件缺 id 时，println 后 return 1。

- [ ] Step 5: 构建 + 自检

Run: `nice -n 19 python3 build_selfhost_native.py && ./build/corec check src/arch/hit/hit.cr`
预期：BUILD SUCCESS 加 check ok，hit.cr 编译无错误。

- [ ] Step 6: 提交

```bash
jj commit -m 'feat: HIT 表文件 + toml 解析：core-x86.toml 最小核 4 事件（M1 Task 1）'
```

---

### Task 2: 表驱动编码器（模板解释器）+ 逐字节对照

文件：
- 修改：`src/arch/linux/ld/instr.cr`（新增 `emit_instr_tabled`）
- 修改：`src/arch/linux/ld/elf.cr`（`elf_gen` 加表路径入口）或 `corearch.cr`
- 修改：`src/compiler/corearch.cr`（`--table <path>` 参数）
- 测试：`tests/selfhost/test_hit_table.py`（替换为行为测试）

接口：
- 读取：Task 1 的 `load_hit_table` / `hit_event_lookup` / `hit_proj_step`
- 产出：`fn emit_instr_tabled(instr_idx, buf, pos) -> int`，与 `emit_instr` 同签名，返回字节数。表驱动的每个事件输出该事件的投影编码。另有 `fn hit_map_ir_op(ir_op) -> event_id`，做 IR op 到事件的映射，Task 3 之前先直接走 sub 形态。

- [ ] Step 1: 写失败测试（替换占位）

替换 `test_hit_table.py` 的 main。构造一个极小 .ccr：Task 2 先用手工汇编指令对照，用现有编译器编一个 `fn main()->int{x:=5;y:=3;return x-y;}` 得到 .ccr。corearch 用 `--table src/arch/hit/core-x86.toml` 输出的二进制与无表输出逐字节比较。M1 表只有 sub/nand/load/store 4 个事件，IR 的 add/const/alloc 未映射，因此 Task 2 的对照面是表驱动路径只处理 IR_BINARY(OP_SUB) 加 IR_LOAD/IR_STORE 形态，其余 op 走旧路径，即混合模式。对照测试使用只含 sub/load/store 的程序（IR 层面），两路径输出的 ELF 逐字节一致。

```python
def build_both(src: str) -> tuple:
    """corearch 旧路径 vs --table 路径，返回两二进制字节。"""
    # 1) corec build 出 .ccr
    # 2) corearch <ccr> --elf -o out_old
    # 3) corearch <ccr> --elf --table src/arch/hit/core-x86.toml -o out_new
    # 4) 读两文件比较
```

M1 混合模式：表覆盖到的 op 走表，未覆盖的走旧路径。逐字节一致检查只对表覆盖的形态严格，混合模式以快速验证正确性为准，Task 4 再细化。

- [ ] Step 2: 跑测试确认失败

预期：FAIL，`--table` 未实现

- [ ] Step 3: 实现编码器

`emit_instr_tabled`：查 `hit_map_ir_op(iri_op)`，无映射时返回 -1，调用方走旧路径；有映射时调用 `hit_event_lookup`，再逐投影步发射。每一步按 `{opcode, reg_role, rm_role}` 组装，操作数角色从 IR 指令取（dst/src1/src2 依角色名），变量到寄存器或栈的映射使用现有 `g2_slot` 加 `e2_load_var` 机制，复用 instr.cr 现有 e2_* 的槽解析。sub 模板为 `48 29 /r`，modrm 的 reg 取 src1 寄存器，沿用 e2 家族 r10 为左操作数、r11 为右操作数的寄存器加载惯例。M1 的形态集：操作数经栈槽加载到固定寄存器对 r10/r11，再发 opcode 和 modrm（rm=r10 型），load/store 使用 rbp+disp 寻址形态。共两种 modrm 形态，由模板字段 `rm_mode` 区分（0=reg，1=rbp+disp32），已在 Task 1 表格式中补齐。nand 事件在 M1 用单步 and 占位，表文件已定。在 Task 3 用合成层把 nand 语义表达为「and 步加取反组合」之前，表模式不发射真正的 nand 程序。偏差记录见计划末尾。

- [ ] Step 4: 接入 --table 参数

corearch：`cli_flag("table", "", "HIT table path")`。有值时调用 `load_hit_table(path)`，失败即退出。`elf_gen` 内的 emit 循环改调 `emit_instr_tabled`，返回 -1 时回退到旧路径。

- [ ] Step 5: 重建 + 对照测试

Run: `nice -n 19 python3 build_selfhost_native.py && nice -n 19 python3 tests/selfhost/test_hit_table.py`
预期：对照用例 PASS，两路径二进制一致。若 M1 混合模式放宽，则以快速验证正确性为检查。

- [ ] Step 6: 提交

```bash
jj commit -m 'feat: 表驱动发射框架：corearch --table + emit_instr_tabled 模板解释（M1 Task 2）'
```

---

### Task 3: 合成层（IR 直线子集降到 4 核事件）

文件：
- 新建：`src/arch/hit/lower_to_core.cr`（事件降低规则，corearch 侧）
- 修改：`src/arch/linux/ld/elf.cr` 或 corearch（表模式下发射前先过降低）
- 测试：`tests/selfhost/test_hit_table.py`（追加降低规则单测，通过 cir dump 或专门验证）

接口：
- 产出：`fn lower_ir_to_core(instr_idx) -> int`，0 表示已降低或直通，1 表示需要合成且已改写指令流，-1 表示不可合成并报错。合成规则表：
  - `OP_ADD` 用反减实现：`add(a,b) := sub(a, sub(0,b))`。其中 0 由常量合成，见下。
  - `OP_SUB` 直接走 `sub`。
  - `OP_AND` 用 `nand(nand(a,b), nand(a,b))`。
  - `OP_OR` 用德摩根律：`nand(nand(a,a), nand(b,b))`。
  - `OP_XOR`、`OP_NOT` 和移位在 M1 报错「需扩展事件」，不覆盖。
  - `IR_CONST n` 合成「常量等于只读区 load」：编译期布局 `g_const_pool`，每常量 8B 槽，发射前把常量池写入 ELF rodata，`IR_CONST` 替换为 `load(pool_addr(n))`，pool_addr 由布局 pass 填。
  - `IR_LOAD/IR_STORE`（槽读写）直接走 `load/store` 事件。
  - 变量槽地址作为 load/store 的地址操作数，即槽地址（栈基址加偏移，由投影解析）。x86 投影的 addr 角色是 rbp+disp 形态。这里需要扩展形态：Task 2 的单形态（rm=寄存器）不够，槽读写需要 rbp+disp 寻址。修正是 Task 2 实现时 load/store 模板需支持 disp 寻址形态（modrm rm=101 加 disp32 相对 rbp）。Task 2 的形态范围包含「rm = rbp+disp32」一种。
- 合成在 IR 层完成，位置是 corearch load_ccr 之后、发射之前的指令数组改写。新指令用现有 IR 结构（g_ir_instrs）表达。合成输出不是 IR 指令，而是事件级指令：表模式下的发射中间层是事件流。corearch 增加事件流数组 `g_hit_ev_stream`，每条包含 event_id、操作数 var 引用和常量地址。降低 pass 把 IR 指令翻译或合成为事件流，编码器消费事件流。
- 这是本计划最关键的结构决策：表模式下 corearch 内部是 IR 经降低得到事件流，再经表投影得到字节；旧模式是 IR 直接得到字节。

- [ ] Step 1: 写失败测试

测试实现方式：`x := 7; y := 5; z := x - y;`，覆盖纯 sub 直通加 const 和槽；另有 `w := x & y`，覆盖 and 到 nand 的合成。断言：表模式编译运行结果正确，exit 等于期望值；事件流可以 dump，加 `--dump-events` 调试输出。

- [ ] Step 2: 实现事件流 + 降低

实现事件流结构和 `lower_ir_to_core`，规则按上表。实现常量池布局和 rodata 写入，参考 elf.cr 的 rodata 段机制。

- [ ] Step 3: 编码器消费事件流

`emit_instr_tabled` 改为消费事件流（event_id 加操作数槽）。要求 sub 直通正确，load/store 槽寻址正确。

- [ ] Step 4: 快速验证断言

Run: `nice -n 19 python3 tests/selfhost/test_hit_table.py`
预期：加减程序 exit 正确；`&` 程序经 nand 合成后 exit 正确。

- [ ] Step 5: 提交

```bash
jj commit -m 'feat: 合成层：IR 直线子集降到 4 核事件流（add 用 sub 反减/and 用 nand/常量池 load；M1 Task 3）'
```

---

### Task 4: 快速验证完整流程（端到端正确性）

文件：
- 新建：`tests/hit/smoke_add.cr`、`tests/hit/smoke_mem.cr`（快速验证源）
- 修改：`tests/selfhost/test_hit_table.py`（端到端用例）
- 修改：`src/compiler/main.cr`（corec build 透传 `--table`，或测试直接调 corearch。测试直接调 corearch 即可，corec 透传属于 M2）

接口：
- 读取：Task 2 和 Task 3 的全部内容

- [ ] Step 1: 写快速验证源

`smoke_add.cr`：`fn main()->int{a:=7;b:=5;return a-b;}`，期望 exit 2。
`smoke_mem.cr`：含内存读写和位与，`fn main()->int{a:.,mut=6;b:=3;c:=a&b;a=c+1;return a;}`。原文写期望 exit 1；手算 6&3=2，2+1=3，数值经合成链正确即断言 exit 3。期望值写死，并在注释中写明手算过程。

- [ ] Step 2: 端到端测试函数

corec build，然后 corearch `--table`，最后运行并断言 exit code。

- [ ] Step 3: 跑通 + 修正

Run: `nice -n 19 python3 tests/selfhost/test_hit_table.py`
预期：快速验证 exit 断言全部通过。修正合成和模板 bug，直到通过。

- [ ] Step 4: 回归不破

Run: `nice -n 19 python3 tests/selfhost/test_compile.py && nice -n 19 python3 tests/bootstrap/test_pipeline.py && ./build/corec check src/compiler`
预期：全部通过，旧路径不受影响。

- [ ] Step 5: 提交

```bash
jj commit -m 'feat: M1 冒烟完整流程：最小核表端到端运行正确 + 回归不破（M1 Task 4）'
```

---

### Task 5: 文档 + 结束

文件：
- 修改：`docs/superpowers/specs/2026-09-05-hardware-interface-table.md`（回填实施状态：M1 完成注记、表文件路径、事件流结构定稿）
- 修改：`docs/superpowers/plans/2026-09-05-lattice-ir-v6.md`（引用 crasm/HIT 处的状态同步）
- 修改：`TODO.md`（记录 M1 完成，列出 M2 待办：控制流与调用合成、全 op 降低、nand 真语义、corec 透传 --table、事件流入 v6 段）

- [ ] Step 1: 更新文档

- [ ] Step 2: 全量回归

Run: bootstrap 三套 + `test_compile` + `test_slice_bounds` + `corec check src/compiler`
预期：全部通过

- [ ] Step 3: 提交

```bash
jj commit -m 'docs: HIT M1 完成记录 + M2 待办（最小核表端到端完整流程实施）'
```

---

## 计划内已知偏差（评审注意，2026-09-06 更新）

0. and 到 nand、or 到德摩根的两条合成规则未实现（Task 3 评审确认）。源语言没有位与、位或运算符，`&` 是取址，`&&`/`||` 恒为短路分支，超出 M1 直线子集，因此 IR 层规则没有源码实现方式，推迟到 M2。IR 中若出现 OP_AND，会明确报错拒绝（'needs more events'），不会不报错却生成错误代码。
1. M1 子集边界是 main 入口函数。从仓库根编译 .ccr 时无条件带 stdlib fmt 闭包辅助函数，其中含分支和除法。辅助函数走旧路径，即混合模式计划偏差第 2 条。全部走表是 M2 的全量切换。
2. `--table` 与 `--link/--shared` 的组合未测试。池 mov 的 rip disp 在链接路径 ctx 重布局下的指向没有覆盖，M2 记录或显式拒绝。
3. 负值和宽常量池没有实现方式。M1 快速验证没有负常量形态，hit_pool_w64 的借位链论证正确，但没有实证。
4. M2 待办（评审 Minor）：hit_w32 负值标记值写入实现分裂（store dst/load s2 未用标记值 −1 读回 255 vs 0xFFFFFFFF）、预检对称性断言、add 反减的 dest-fresh 前提固化、'events emitted' 计数改名、REX 注释 W+R+B。

1. nand 的 x86 投影：x86 没有 nand 指令，M1 用 and 单步占位。nand 语义由合成层在 Task 3 覆盖之前，不发射 nand 事件程序。完整 nand 序列投影（and 加 not 两步）与事件流语义闭合属于 M2 事项。
2. 混合模式：M1 表驱动与旧路径并行，未映射的 op 走旧路径。「表是唯一平台依赖」的完全实现，即全 op 走表，是 M2 的 `--table` 全量切换。
3. 常量注入：设计上常量等于只读区 load，最小核没有 const 事件。M1 先做常量池布局，图常量区（v6 语义）后续处理。
4. 地址形态：load/store 的槽和池寻址使用投影层 disp 形态，M1 支持 rbp+disp 一种。
