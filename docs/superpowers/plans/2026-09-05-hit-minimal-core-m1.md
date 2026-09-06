# 硬件接口表（HIT）M1：最小核运行闭环实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用最小核表（`sub`/`nand`/`load`/`store` 4 事件）驱动 corearch 发射，跑通第一个 Core 冒烟程序（直线加减/位运算/内存读写），验证「表 = 运行的唯一平台依赖」架构。

**Architecture:** 三层——(1) HIT 表文件（toml 文本，4 事件 × x86 投影条目）；(2) corearch 表驱动编码器（读表 → 按模板解释发射，与现有 `emit_instr` 硬编码路径并行、逐字节对照验证）；(3) 合成层（IR 直线子集 → 4 核事件）。验证策略：表驱动输出与手写 e2_* 输出**逐字节一致**为表驱动正确性判据，冒烟程序运行正确为闭环判据。

**Tech Stack:** Core 自举编译器（`src/compiler/`）、Python bootstrap、x86-64 ELF 后端（`src/arch/linux/ld/`）。表文件解析用现有 `src/stdlib/toml.cr`。

## Global Constraints

- 版本控制用 `jj`（铁律 #2，git 被 hook 拦截）。提交 `jj commit -m '<msg>'`，不手动动 bookmark（协调者管）
- 长时间构建/测试用 `nice -n 19`（铁律 #6）；trap 测试进程需 `ulimit -c 0` 前缀（本机 core_pattern 坑，TODO:125）
- 设计依据：`docs/superpowers/specs/2026-09-05-hardware-interface-table.md`（HIT 定稿）——最小核事件：`sub=1 nand=2 load=3 store=4`；事件签名无宽度/寄存器/寻址；换表 = 换平台
- 改动后重建 corec/corearch 再测：`nice -n 19 python3 build_selfhost_native.py`（约 2 分钟；corearch 改动只重建 corearch 的也可全量）
- 现有 `emit_instr`（instr.cr:433）硬编码路径**保持可用**——表驱动路径并行存在，全套测试不得破
- IR op 全集见 ast.cr:538-588（约 45 个，含空洞）；`IR_BINARY`(2) 的 s3 = 子操作（`OP_ADD=1 OP_SUB=2 OP_AND=12` 等，见 ast.cr OP_* 常量）；变量 = 内存槽模型（IR_STORE/IR_LOAD = 槽写读）
- M1 范围边界（超出即拒绝编译并报「需要扩展事件」）：**直线程序**——无 IR_BRANCH/JUMP/LABEL/PHI/CALL/RETURN 值/SPAWN；运算仅加减位与（IR_BINARY OP_ADD/OP_SUB/OP_AND/OP_OR/OP_XOR/OP_NOT）；常量仅小整数（合成见 Task 3）
- 合成/控制流/函数调用/复杂运算的完整覆盖 = M2（本计划不覆盖）

---

## 现状事实（执行前必读）

- `corearch_main()`（`src/compiler/corearch.cr:17`）：cli 解析 → `load_ccr(buf, fsize)`（`ccr_io.cr`）→ `init_backend_arrays()` → `elf_gen()`（`src/arch/linux/ld/elf.cr`）
- `emit_instr(instr_idx, buf, pos)`（`src/arch/linux/ld/instr.cr:433`）：按 `iri_op()` 分发（约 50 个 `if op == IR_*` 块）——**表驱动路径从这里插入**（新函数 `emit_instr_tabled`，`emit_instr` 加开关）
- 栈槽/寄存器映射：`g2_slot(var)`（槽解析）、`e2_load_var/e2_st`（变量 → 寄存器/栈）——表驱动编码器复用这些（槽 = 操作数解析的现有机制）
- `IR_CONST`(1)：s1 = i64 值。合成层把它变成 `load` 事件 + 编译期常量区布局
- corec `build` 命令（`main.cr:571-592`）：产出 .ccr 后 `system("corearch <ccr> --elf")`——corearch 加 `--table` 参数后由 corec 透传或手动测试

## 表文件格式（本计划定稿，toml）

> 数值真源警示（2026-09-06 M2 收尾修正）：下方示例仅为计划期快照——**字节值与
> 角色以 `src/arch/hit/core-x86.toml` 为唯一真源**（表驱动编码器直读该文件）。
> 快照与真源已同步：M1 寄存器惯例 r10（累加/结果，rm 字段）+ r11（reg 字段）为
> 8 号以上寄存器对 → 投影字节需 **REX.W+R+B**（sub = `4D 29`，非早期草案的
> `48 29`）；sub 事件 reg 字段角色 = `src2`（非 src1）。

`src/arch/hit/core-x86.toml`（M1 第一份投影表）：

```toml
[table]
name = "core-x86-min"
events = 4            # 最小核契约：实现 1-4 即可运行

[[event]]
id = 1                # sub
name = "sub"
arith = "sub"         # 语义锚：规约层引用（M1 不消费）
inputs = 2
outputs = 1
side_effect = "pure"

[[event.proj]]        # x86 投影：sub r/m64, r64 = r/m ← r/m − r（REX.W+R+B + 29 /r）
isa = "x86-64"
opcode = [0x4D, 0x29]        # REX.W+R+B + sub r/m64,r64（r10/r11 对需 R/B 扩展位）
modrm_reg_role = "src2"      # reg 字段 = 第二输入（被减数，驻 r11）
modrm_rm_role = "dst"        # rm 字段 = 目标/结果寄存器（r10，运算前驻第一输入）
rm_mode = 0                  # 0 = rm 为寄存器（加载到 r10）；1 = rm 为 rbp+disp32（槽/常量池寻址）
# 操作数解析规则：dst/src 均为「值槽」——由调用方传 var 索引，编码器用 g2_slot/e2_load_var 解析
# 模板解释器规则见 Task 2：M1 支持 [opcode...] + modrm 两角色 + rm_mode 两种形态

[[event]]
id = 2
name = "nand"
inputs = 2
outputs = 1
side_effect = "pure"

[[event.proj]]
isa = "x86-64"
# M1 占位：x86 无 nand 指令——单步 and（opcode 4D 21 /r: and r/m64,r64，
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
# rm_mode=1：rm = rbp+disp32（槽/常量池寻址）。reg 字段寄存器 = dst（r10 → REX.W+R = 0x4C）
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
# rm_mode=1：rm = rbp+disp32（槽寻址）。reg 字段寄存器 = val（r10 → REX.W+R = 0x4C）
opcode = [0x4C, 0x89]        # REX.W+R + mov r/m64, r64（写：[rbp+disp32] ← val）
modrm_reg_role = "val"
modrm_rm_role = "addr"
rm_mode = 1
```

M1 模板解释器形态 = 每事件单投影步 `{opcode 字节(≤2), reg 角色, rm 角色, rm_mode}`，无 imm/REX 变体（超出报错 = 该事件形态未实现）。多步序列投影（如 nand = and+not）留 M2（nand 事件 M1 以单步 and 占位）。

---

### Task 1: HIT 表文件 + toml 解析器接线

**Files:**
- Create: `src/arch/hit/core-x86.toml`（上节格式全文件，含 4 事件；nand = 单步 and 占位 + M2 注释）
- Modify: `src/compiler/globals.cr`（表加载全局）
- Create: `src/arch/hit/hit.cr`（表结构 + `load_hit_table(path)` + `hit_event_lookup(event_id)`）
- Test: `tests/selfhost/test_hit_table.py`

**Interfaces:**
- Produces: `fn load_hit_table(path: string) -> int`（0=成功；填充 `g_hit_events`（string buffer，每事件 32B：id/name_ni/inputs/outputs/side_effect/proj_isa/step_count/step_off）、`g_hit_event_count`）；`fn hit_event_lookup(id: int) -> int`（返回事件槽 -1=无）；`fn hit_proj_step(event_slot: int, step_i: int, out_opcode: ptr, out_reg_role: ptr, out_rm_role: ptr, out_rm_mode: ptr) -> int`（取投影步编码与 rm 形态）
- `hit.cr` 需要 `import toml`（现有 `src/stdlib/toml.cr` 解析器）

- [ ] **Step 1: 写失败测试**

Create `tests/selfhost/test_hit_table.py`：

```python
#!/usr/bin/env python3
"""HIT 表解析测试——core-x86.toml 最小核 4 事件加载。"""

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
    # Task 1 完成判据 = 构建通过 + corec check src/arch/hit/hit.cr 无错
    print("0/1 passed (Task 1 判据为编译 + Task 2 接线后行为测试)")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 2: 跑测试确认失败**

Run: `nice -n 19 python3 tests/selfhost/test_hit_table.py`
Expected: `0/1 passed`，exit 1

- [ ] **Step 3: 写表文件**

按「表文件格式」节创建 `src/arch/hit/core-x86.toml`（4 事件，nand = 单步 and 占位 + M2 注释）。

- [ ] **Step 4: 写 hit.cr + globals + 接线构建**

`src/arch/hit/hit.cr`：结构（仿 `cir_cache.cr` 的 buffer 表风格）：
- `g_hit_events : string, mut; g_hit_event_count/cap`——每事件 32B：`[id i32, name_ni i32, inputs i32, outputs i32, side_effect i32, proj_isa i32, step_count i32, step_off i32]`
- `g_hit_steps : string, mut; g_hit_step_count/cap`——每步 20B：`[op0 i32, op1 i32(=0 无), reg_role i32, rm_role i32, rm_mode i32]`（opcode 至多 2 字节前缀，超出报错；rm_mode 0=寄存器 1=rbp+disp32）
- `load_hit_table(path)`：read_file → toml 解析（查 `src/stdlib/toml.cr` API 确认遍历语法，跟随现有使用点如 project.cr）→ 填两表
- 注册：`build_selfhost_native.py` 的 corearch concat 列表加 `src/arch/hit/hit.cr`（corec 不需要）；`src/compiler/globals.cr` 或 hit.cr 顶部声明全局
- 错误：文件缺/事件缺 id → println + return 1

- [ ] **Step 5: 构建 + 自检**

Run: `nice -n 19 python3 build_selfhost_native.py && ./build/corec check src/arch/hit/hit.cr`
Expected: BUILD SUCCESS + check ok（hit.cr 编译干净）

- [ ] **Step 6: 提交**

```bash
jj commit -m 'feat: HIT 表文件 + toml 解析——core-x86.toml 最小核 4 事件（M1 Task 1）'
```

---

### Task 2: 表驱动编码器（模板解释器）+ 逐字节对照

**Files:**
- Modify: `src/arch/linux/ld/instr.cr`（新增 `emit_instr_tabled`）
- Modify: `src/arch/linux/ld/elf.cr`（`elf_gen` 加表路径入口）或 `corearch.cr`
- Modify: `src/compiler/corearch.cr`（`--table <path>` 参数）
- Test: `tests/selfhost/test_hit_table.py`（替换为行为测试）

**Interfaces:**
- Consumes: Task 1 的 `load_hit_table` / `hit_event_lookup` / `hit_proj_step`
- Produces: `fn emit_instr_tabled(instr_idx, buf, pos) -> int`（与 `emit_instr` 同签名；返回字节数；**对表驱动的每事件，输出 = 该事件投影编码**）；`fn hit_map_ir_op(ir_op) -> event_id`（IR op → 事件映射，Task 3 前先直通 sub 形态）

- [ ] **Step 1: 写失败测试（替换占位）**

`test_hit_table.py` main 替换：构造一个极小 .ccr（Task 2 先用手工汇编指令对照——用现有编译器编一个 `fn main()->int{x:=5;y:=3;return x-y;}` 的 .ccr），corearch 用 `--table src/arch/hit/core-x86.toml` 输出二进制与无表输出**逐字节比较**——但 M1 表只有 sub/nand/load/store 4 事件，IR 的 add/const/alloc 未映射 → **Task 2 的对照面 = 表驱动路径仅处理 IR_BINARY(OP_SUB) + IR_LOAD/IR_STORE 形态**，其余 op 走旧路径（混合模式）。对照测试：程序只用 sub/load/store（IR 层面），两路径 ELF 输出逐字节一致。

```python
def build_both(src: str) -> tuple:
    """corearch 旧路径 vs --table 路径，返回两二进制字节。"""
    # 1) corec build 出 .ccr
    # 2) corearch <ccr> --elf -o out_old
    # 3) corearch <ccr> --elf --table src/arch/hit/core-x86.toml -o out_new
    # 4) 读两文件比较
```

（M1 混合模式：表覆盖到的 op 走表、未覆盖走旧路径——逐字节一致判据只对「表覆盖形态」严格，混合模式以冒烟正确性为准——Task 4 细化。）

- [ ] **Step 2: 跑测试确认失败**

Expected: FAIL（--table 未实现）

- [ ] **Step 3: 实现编码器**

`emit_instr_tabled`：查 `hit_map_ir_op(iri_op)` → 无映射回 -1（调用方走旧路径）；有映射 → `hit_event_lookup` → 逐投影步发射：每步按 `{opcode, reg_role, rm_role}` 组装——操作数角色从 IR 指令取（dst/src1/src2 依角色名），变量 → 寄存器/栈用现有 `g2_slot` + `e2_load_var` 机制（读 instr.cr 现有 e2_* 的槽解析复用）。sub 模板 `48 29 /r`：modrm = reg=src1 寄存器（沿用 e2 家族 r10=左操作数/r11=右操作数 的寄存器加载惯例）。M1 形态集：操作数经栈槽加载到固定寄存器对（r10/r11）再 opcode+modrm（rm=r10 型）+ load/store 的 rbp+disp 寻址形态——共两种 modrm 形态，模板字段 `rm_mode`（0=reg / 1=rbp+disp32）在 Task 1 表格式中补齐。nand 事件 M1 = 单步 and 占位（表文件已定）；nand 语义经合成层在 Task 3 用「and 步 + 取反组合」表达前，表模式不发射真 nand 程序（偏差记录见计划尾）。

- [ ] **Step 4: 接线 --table 参数**

corearch：`cli_flag("table", "", "HIT table path")`；有值时 `load_hit_table(path)` 失败即退出；`elf_gen` 内 emit 循环改调 `emit_instr_tabled`（返回 -1 落旧路径）。

- [ ] **Step 5: 重建 + 对照测试**

Run: `nice -n 19 python3 build_selfhost_native.py && nice -n 19 python3 tests/selfhost/test_hit_table.py`
Expected: 对照用例 PASS（两路径二进制一致，若 M1 混合模式放宽则冒烟正确性为判据）

- [ ] **Step 6: 提交**

```bash
jj commit -m 'feat: 表驱动发射框架——corearch --table + emit_instr_tabled 模板解释（M1 Task 2）'
```

---

### Task 3: 合成层（IR 直线子集 → 4 核事件）

**Files:**
- Create: `src/arch/hit/lower_to_core.cr`（事件降低规则；corearch 侧）
- Modify: `src/arch/linux/ld/elf.cr` 或 corearch（表模式下发射前先过降低）
- Test: `tests/selfhost/test_hit_table.py`（追加降低规则单测——通过 cir dump 或专门验证）

**Interfaces:**
- Produces: `fn lower_ir_to_core(instr_idx) -> int`（0=已降低/直通；1=需合成已改写指令流；-1=不可合成报错）；合成规则表：
  - `OP_ADD` → sub 反减：`add(a,b) := sub(a, sub(0,b))`——0 从常量合成（见下）
  - `OP_SUB` → 直通 `sub`
  - `OP_AND` → `nand(nand(a,b), nand(a,b))`
  - `OP_OR` → 德摩根：`nand(nand(a,a), nand(b,b))`
  - `OP_XOR`/`OP_NOT`/移位 → M1 报错「需扩展事件」（不覆盖）
  - `IR_CONST n` → 合成「常量 = 只读区 load」：编译期布局 `g_const_pool`（每常量 8B 槽），发射前把常量池写入 ELF rodata，`IR_CONST` 替换为 `load(pool_addr(n))`——pool_addr 由布局 pass 填
  - `IR_LOAD/IR_STORE`（槽读写）→ 直通 `load/store` 事件
  - 变量槽地址 → load/store 的「地址操作数」= 槽地址（栈基址+偏移，由投影解析——x86 投影的 addr 角色 = rbp+disp 形态……**形态扩展**：Task 2 的单形态（rm=寄存器）不够——槽读写要 rbp+disp 寻址。修正：Task 2 实现时 load/store 模板需支持 disp 寻址形态（modrm rm=101 + disp32 相对 rbp）——Task 2 的形态范围含「rm = rbp+disp32」一种）
- 合成实现在 IR 层（corearch load_ccr 后、发射前的指令数组改写）——新指令用现有 IR 结构（g_ir_instrs）表达（合成的 sub/nand/load 仍是 IR 指令？不——是事件。**合成输出 = 事件级指令**：表模式下的发射中间层 = 事件流。corearch 加事件流数组 `g_hit_ev_stream`（每条：event_id + 操作数 var 引用 + 常量地址）——降低 pass 把 IR 指令翻译/合成为事件流，编码器消费事件流）
- 这是本计划最关键结构决策：**表模式下 corearch 内部 = IR →（降低）→ 事件流 →（表投影）→ 字节**；旧模式 = IR → 字节

- [ ] **Step 1: 写失败测试**

测试载体：`x := 7; y := 5; z := x - y;`（纯 sub 直通 + const/槽）+ `w := x & y`（and → nand 合成）。断言：表模式编译运行结果正确（exit = 期望值）+ 事件流可 dump（加 `--dump-events` 调试输出）。

- [ ] **Step 2: 实现事件流 + 降低**

事件流结构 + `lower_ir_to_core`（规则按上表）；常量池布局 + rodata 写入（读 elf.cr rodata 段机制）。

- [ ] **Step 3: 编码器消费事件流**

`emit_instr_tabled` 改为消费事件流（event_id + 操作数槽）；sub 直通正确、load/store 槽寻址正确。

- [ ] **Step 4: 冒烟断言**

Run: `nice -n 19 python3 tests/selfhost/test_hit_table.py`
Expected: 加减程序 exit 正确；`&` 程序（经 nand 合成）exit 正确

- [ ] **Step 5: 提交**

```bash
jj commit -m 'feat: 合成层——IR 直线子集降到 4 核事件流（add→sub 反减/and→nand/常量池 load；M1 Task 3）'
```

---

### Task 4: 冒烟闭环（端到端正确性）

**Files:**
- Create: `tests/hit/smoke_add.cr`、`tests/hit/smoke_mem.cr`（冒烟源）
- Modify: `tests/selfhost/test_hit_table.py`（端到端用例）
- Modify: `src/compiler/main.cr`（corec build 透传 `--table` 或测试直接调 corearch——测试直接调 corearch 即可，corec 透传 = M2）

**Interfaces:**
- Consumes: Task 2/3 全部

- [ ] **Step 1: 写冒烟源**

`smoke_add.cr`：`fn main()->int{a:=7;b:=5;return a-b;}`（期望 exit 2）
`smoke_mem.cr`：含内存读写 + 位与：`fn main()->int{a:.,mut=6;b:=3;c:=a&b;a=c+1;return a;}`（期望 exit 1：6&3=2，+1=3？——`2+1=3`；数值经合成链正确即断言 exit 3——写死期望值并注释手算）

- [ ] **Step 2: 端到端测试函数**

corec build → corearch `--table` → 运行断言 exit code

- [ ] **Step 3: 跑通 + 修正**

Run: `nice -n 19 python3 tests/selfhost/test_hit_table.py`
Expected: 冒烟 exit 断言全过；修正合成/模板 bug 直至绿

- [ ] **Step 4: 回归不破**

Run: `nice -n 19 python3 tests/selfhost/test_compile.py && nice -n 19 python3 tests/bootstrap/test_pipeline.py && ./build/corec check src/compiler`
Expected: 全绿（旧路径不受影响）

- [ ] **Step 5: 提交**

```bash
jj commit -m 'feat: M1 冒烟闭环——最小核表端到端运行正确 + 回归不破（M1 Task 4）'
```

---

### Task 5: 文档 + 收尾

**Files:**
- Modify: `docs/superpowers/specs/2026-09-05-hardware-interface-table.md`（实施状态：M1 完成注记、表文件路径、事件流结构定稿回填）
- Modify: `docs/superpowers/plans/2026-09-05-lattice-ir-v6.md`（若引用 crasm/HIT 处状态同步）
- Modify: `TODO.md`（M1 完成记录 + M2 挂账：控制流/调用合成、全 op 降低、nand 真语义、corec 透传 --table、事件流入 v6 段）

- [ ] **Step 1: 更新文档**

- [ ] **Step 2: 全量回归**

Run: bootstrap 三套 + `test_compile` + `test_slice_bounds` + `corec check src/compiler`
Expected: 全绿

- [ ] **Step 3: 提交**

```bash
jj commit -m 'docs: HIT M1 完成记录 + M2 挂账（最小核表端到端闭环落地）'
```

---

## 计划内已知偏差（评审注意，2026-09-06 更新）

0. **and→nand / or→德摩根 合成规则未实现（Task 3 评审确认）**：源语言无位与/位或运算符（`&` 是取址、`&&`/`||` 恒短路分支化超 M1 直线子集）——IR 层规则无源码载体，推迟 M2；IR 若出现 OP_AND 会大声拒绝（'needs more events'）而非静默错码
1. **M1 子集边界 = main 入口函数**：.ccr 自仓库根编译无条件带 stdlib fmt 闭包辅助函数（含分支/除法）——辅助函数走旧路径（混合模式 plan 偏差 #2 落地）；纯化 = M2 全量切换
2. **`--table` × `--link/--shared` 组合未测试**：池 mov rip disp 在链接路径 ctx 重布局下的指向无覆盖——M2 记录或显式拒绝
3. **负值/宽常量池无载体**：M1 冒烟无负常量形态（hit_pool_w64 借位链论证正确无实证）
4. **M2 挂账（评审 Minor）**：hit_w32 负值哨兵写入实现分裂（store dst/load s2 未用哨兵 −1 读回 255 vs 0xFFFFFFFF）、预检对称性断言、add 反减 dest-fresh 前提固化、'events emitted' 计数改名、REX 注释 W+R+B

1. **nand 的 x86 投影**：x86 无 nand 指令——M1 以 and 单步占位，nand 语义由合成层（and→nand 反推）在 Task 3 覆盖前**不发射 nand 事件程序**；完整 nand 序列投影（and+not 两步）与事件流语义闭合 = M2 事项
2. **混合模式**：M1 表驱动与旧路径并行（未映射 op 落旧路径）——「表 = 唯一平台依赖」的纯化（全 op 走表）是 M2 的 `--table` 全量切换
3. **常量注入**：设计上常量 = 只读区 load（最小核无 const 事件）——M1 常量池布局先行，图常量区（v6 语义）后续
4. **地址形态**：load/store 的槽/池寻址 = 投影层 disp 形态（M1 支持 rbp+disp 一种）
