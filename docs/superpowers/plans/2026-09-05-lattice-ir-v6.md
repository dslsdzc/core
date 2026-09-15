# 格形态 IR v6（存在结构）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `.ccr` 从 v5（格层线性投影）升级为 v6（存在结构段：条目版本/存在区间/共存/home/无配方标记），供寄存器分配判定直接消费。

**执行顺序（2026-09-05 定）：格数据面先行**——Task 1-3（存在区间/版本化/共存推导）为 Phase 1 立即执行（纯编译器内推导，不依赖格式 IO）；v6 格式 IO（Task 4）与 HIT（`2026-09-05-hit-minimal-core-m1.md`）在数据面落地后推进；HIT 事件流与 v6 NOD 同构对齐（交汇点 = 事件层）。坐标说明：现管线 DF 节点序 = IR 指令序（`lower_to_ccr` node i → instruction i）——本计划「指令序」即 v6 格式定稿的「NOD 坐标」，落地后同一坐标零迁移。

**Architecture:** v6 = v5 全部基础段 + 新增存在结构段，version 字段 5→6，magic（`CCR1`）/扩展名/CLI 不动（方案 A 定案）。存在结构的数据（版本化条目 × 存在区间）由新推导 pass 从线性 IR 重建（`alloc_registers` 的 live-interval 雏形升级为独立 pass），共存按设计文档「推导规则优先，避免冗余存储」。ELF 后端只消费线性段（v6 保留），故后端改动面小；存在段是分配的判定输入（`docs/regalloc-cache-mapping.md` §4 一致性四条）。

**Tech Stack:** Core 自举编译器（`src/compiler/`）、Python bootstrap（`bootstrap/corec/`）、x86-64 ELF 后端（`src/arch/linux/ld/`）。无外部依赖。

## Global Constraints

- 版本控制用 `jj`（铁律 #2，git 被 hook 拦截）。提交：`jj commit -m '<msg>'`；推送：`jj git push ...`
- 长时间编译/测试用 `nice -n 19`（铁律 #6；无 cpulimit 时）
- `.ccr` 扩展名 / magic `CCR1` / CLI / 文件路径**不动**（2026-08-27 方案 A 定案）
- v6 **不承诺 v5 后向兼容**；v6 落地即 v6-only（.ccr 为管线中间产物，corec→corearch 现生成、零持久生态，无需 v5→v6 转换工具——2026-09-05 计划定稿取消）
- 宽度标签（`T_INT_I8..U64` / `W_*`）不进入 v6（width-out-of-language 定案；v5 格式本身无宽度字段——parser 的宽度标注在 AST 节点，不落 .ccr）
- 共存不落盘冗余存储——推导规则（存在区间相交）优先（设计文档 §4.2 第 2 条）
- 内存数组操作沿用仓库模式：动态 byte buffer + `grow_*`/`w64`/`r64`/`i32` 字段访问器，无 `MAX_*` 硬限
- 所有 i32 落盘字段过 `ccr_i32_fits`/`ccr_validate_i32_fields` 校验（v5 先例，`test_ccr_writer_rejects_i32_overflow_inputs` 模式）
- 测试：修改后跑 `tests/bootstrap/` 三套 + `tests/selfhost/`（`test_compile.py` 为首）＋ `./build/corec check src/compiler` 自检；trap 类测试进程内置 `RLIMIT_CORE=0`（core_pattern 坑，见 TODO:125）
- 参考文档：`docs/superpowers/specs/2026-08-27-lattice-form-ir-design.md`（方向定稿）、`docs/regalloc-cache-mapping.md`（判定四条 §四）、`docs/memory-model-capability-lattice.md` v4（条款 4b）、`docs/ir-schema/coreir-schema.md`（v6 落地后同步）

---

## 现状事实（执行前必读）

- **v5 段序列**（`src/compiler/ccr_io.cr:6-20` 注释）：`magic "CCR1"` → `version=5` → `strings` → `func_meta`（7×u32/函数）→ `instrs`（op i32, dest i32, s1 i64, s2 i32, s3 i32, tk u32 = **28B/条**）→ `vars` → `str_consts` → `structs` → `enums` → `globals`（16B/条）→ `opt_meta` → `sgs`（**ESZ_SG_DISK=24B**/条：kind/enter/exit/parent/nstart/ncount）
- **线性投影机制**（`dataflow.cr:351 lower_to_ccr`）：图节点创建序 = 指令序直投（node i → instruction i，df 边界 = ir 边界）——v6 保留此机制
- **活区间雏形**（`opt.cr:198 alloc_registers`）：每函数每变量 `[first_ref, last_ref]`（指令序 ii），5 个 callee-saved 寄存器（rbx/r12-r15）First-Fit；`g_opt_level < 1` 时跳过。**升级点**：变量可能多次 store（非 SSA）——单区间近似；版本化 = 每次 store 切分条目
- **RegionCheck cur_seq/exit_seq**：设计文档声称存在（`regalloc-cache-mapping.md` 表格引用），**代码中不存在**——区间推导不依赖它，从指令序直接推导
- **无配方/驱逐/home 标注**：代码零实现
- **save/load**：`save_ccr`（ccr_io.cr:193）、`load_ccr`（:376）、`calc_ccr_size`（:130）、字段校验 `ccr_i32_fits`（:99）/`ccr_validate_i32_fields`（:104）
- **消费方**：corearch（后端）读 .ccr → ELF；`.cir` 缓存走 `cir_cache.cr`（独立，不动）

## v6 格式布局（2026-09-05 定案：**以格式定稿 spec 为唯一真相**）

> 本文档早前的「追加式 24B」布局是草案残留，已废弃。**权威布局 = `docs/superpowers/specs/2026-09-05-lattice-ir-v6-format.md`**（B 方向：存在结构主体）：
>
> - Header 16B（magic `CCR1` / version 6 / seg_count）+ 段表（每段 {tag, offset, size}）——段序自由
> - 段：STR（字符串）/ SYM（符号表，函数含 first_ent/last_ent）/ NOD（图事件 + 显式边）/ **ENT（条目表 28B/条：var_id, version, def_nod, live_start, live_end(半开), home, flags）** / REG（region，NOD 坐标）
> - 坐标 = NOD id（图节点序 = 现 IR 指令序，见计划头注记）
> - 共存不落盘（判定现算，sweep 不超线性）
> - v6-only（无转换工具）

---

### Task 1: 存在区间推导 pass（liveness 升级为独立函数）

**Files:**
- Modify: `src/compiler/opt.cr`（新增函数；`alloc_registers` 改为调用它）
- Create: `tests/selfhost/test_live_ranges.py`
- Modify: `src/compiler/globals.cr`（区间表全局）

**Interfaces:**
- Produces: `fn compute_live_ranges()` — 填充全局 `g_ir_live_ranges`（string buffer，每函数每变量两条 i64：first_ref/last_ref，指令序），`g_live_range_count/g_live_range_cap`；`fn live_first(func_i, var_i) -> int` / `fn live_last(func_i, var_i) -> int` 查询（未使用返回 -1）。从 `alloc_registers`（opt.cr:210-241）提取同一逻辑，**行为不变**（alloc_registers 改读表）

- [ ] **Step 1: 写失败测试**

Create `tests/selfhost/test_live_ranges.py`：

```python
#!/usr/bin/env python3
"""存在区间推导（v6 数据基础）——通过 ccr dump 校验每变量区间表。"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"


def main() -> int:
    if not COREC.exists():
        print(f"[FAIL] missing native compiler: {COREC}")
        return 1
    # 占位：Task 1 结束前替换为真实断言（见 Step 4）
    print("0/1 passed (placeholder)")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 2: 跑测试确认失败**

Run: `nice -n 19 python3 tests/selfhost/test_live_ranges.py`
Expected: `0/1 passed (placeholder)`，exit 1

- [ ] **Step 3: 实现 compute_live_ranges**

在 `src/compiler/opt.cr` 的 `alloc_registers`（:198）上方新增（表全局声明放 `src/compiler/globals.cr`，与 `g_ir_slice_lens` 同风格；opt.cr 只放函数）。把 :210-241 的区间构建循环搬入（同样的扫描：逐函数逐指令，dest/s1/s2 在函数变量范围内则扩展 [first_ref,last_ref]），结果写全局表；`alloc_registers` 改为读表（删除其内部区间构建，保留寄存器指派逻辑）：

```core
// v6 数据基础：存在区间推导（指令序 [first_ref, last_ref]）。
// 与 alloc_registers 共用——后者改读本表。
// 表布局：每函数一段，段内每「函数内 var」16B（段偏移 = 前缀 var 数累计，见
// live_range_slot——func_i 段起始 = Σ var_count[0..func_i)，不乘固定稠密系数）。
g_ir_live_ranges : string, mut;
g_live_range_cap : int, mut;

fn grow_live_ranges(needed: int) {
    if needed < g_live_range_cap { return; }
    nc := g_live_range_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 16); _dyncpy(g_ir_live_ranges, g_live_range_cap * 16, nb);
    g_ir_live_ranges = nb; g_live_range_cap = nc;
}

fn live_range_slot(func_i: int, var_i: int) -> int {
    // 函数内 var 索引 = var_i − var_start[func_i]；func_i 段起始 = 前缀 var_count 累计
    off : ., mut = 0;
    fi : ., mut = 0;
    loop { if fi >= func_i { break; }
        off = off + r64(g_ir_func_var_count, fi * 8);
        fi = fi + 1; }
    return (off + (var_i - r64(g_ir_func_var_start, func_i * 8))) * 16;
}

fn live_first(func_i: int, var_i: int) -> int {
    if func_i < 0 || var_i < 0 { return -1; }
    return r64(g_ir_live_ranges, live_range_slot(func_i, var_i));
}

fn live_last(func_i: int, var_i: int) -> int {
    if func_i < 0 || var_i < 0 { return -1; }
    return r64(g_ir_live_ranges, live_range_slot(func_i, var_i) + 8);
}
```

`compute_live_ranges()` 实现：先按 Σ var_count 总量 grow 并首遍写 -1（区间未知 = -1，沿用 alloc_registers 的 iv_buf 初始化语义）；再逐函数逐指令扫描：op/dest/s1/s2 落在 `[var_start, var_start+var_count)` 内则扩展区间（首见写 first，之后推进 last——与 opt.cr:210-241 逻辑逐行一致）。末尾把 `alloc_registers` 的重复扫描删除并改读 `live_first/live_last`。

- [ ] **Step 4: 补真实测试断言**

把 `test_live_ranges.py` 的 main 替换为真实校验——用 `cir` dump 的指令序计算期望区间不现实（脆弱），改为**用 O1 编译冒烟 + 回归套件验证行为不变**：直接跑现有 `test_compile.py`/`test_dex_arith.py`（O1 路径覆盖 alloc_registers → 现在读新表）。测试文件保留为「smoke: 编译+运行通过即区间表不破坏分配」：

```python
def build_and_run(source: str) -> int:
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as f:
        f.write(source)
        src = f.name
    out = src[:-3]
    try:
        b = subprocess.run([str(COREC), "build", src, "-o", out, "--static"],
                           capture_output=True, text=True, cwd=BASE, timeout=120)
        if b.returncode != 0:
            return 999
        r = subprocess.run([out], capture_output=True, text=True, timeout=10)
        return r.returncode
    finally:
        for p in (src, out, out + ".ccr"):
            try: os.unlink(p)
            except FileNotFoundError: pass


def main() -> int:
    if not COREC.exists():
        print("[FAIL] missing build/corec")
        return 1
    src = "fn fib(n:int)->int{if n<2{return n;}return fib(n-1)+fib(n-2);}\n" \
          "fn main()->int{return fib(10);}\n"
    rc = build_and_run(src)
    ok = rc == 55
    print(f"[{'PASS' if ok else 'FAIL'}] O1 live-range smoke: rc={rc}")
    return 0 if ok else 1
```

（fib(10)=55 需要 O1——`corec build` 默认 opt 级别见 main.cr；若默认非 O1，命令加 `--opt-level 1`，先确认 CLI 标志名。）

- [ ] **Step 5: 跑回归**

Run: `nice -n 19 python3 tests/selfhost/test_compile.py && nice -n 19 python3 tests/selfhost/test_live_ranges.py && nice -n 19 python3 tests/bootstrap/test_pipeline.py`
Expected: 全部通过（区间表行为与内联扫描一致）

- [ ] **Step 6: 提交**

```bash
jj commit -m 'feat: 存在区间推导 pass——compute_live_ranges 独立表，alloc_registers 改读表（v6 数据基础 Task 1）'
```

---

### Task 2: 条目版本化（变量 × 定值点）

**Files:**
- Modify: `src/compiler/opt.cr`
- Test: `tests/selfhost/test_live_ranges.py`（追加断言）

**Interfaces:**
- Consumes: Task 1 的 `compute_live_ranges`
- Produces: `fn compute_entries(func_i) -> int`（返回该函数条目数）填充全局条目表 `g_ir_entries`（24B/条内存表：var_idx(全局), def_instr(全局), live_start, live_end, home, flags——盘上 28B/含 version 由 Task 4 转换，见「v6 格式布局」）；`fn entry_count(func_i) -> int`

- [ ] **Step 1: 设计确认（读代码）**

读 `opt.cr` alloc_registers 全文，确认 IR 变量定值形态：`IR_ALLOC`（局部槽初定值）后续 `IR_STORE` 重定值。条目版本切分规则：**每个对该变量的 STORE/ALLOC 指令 = 一个版本条目**；版本存在区间 = 该版本定值点到下一版本定值点（或最后使用）。

- [ ] **Step 2: 写失败测试**

`test_live_ranges.py` 追加：一个 `x := 1; x = x + 1; x = x + 2; return x;` 程序 → 期望 x 有 **4** 个条目——真实 IR 里 LET 初始化 `x := 1` 发射 `IR_ALLOC` + `IR_STORE` 两条定值（ir_gen EXPR_LET 路径），故 x = ALLOC 定值 + 3 次 STORE = 4 版本（2026-09-05 勘误：原写 3 系误按「LET 只发 ALLOC」的错误 IR 模型估算；规则原文含 ALLOC 定值，实现按规则得 4，测试断言 4）。

**定值识别假设注记**（评审 Important）："函数段内 var 只被 ALLOC/STORE 写"成立范围有限——`IR_ALLOC_ARRAY/IR_ALLOC_STRUCT` 的 dest 也直写 var（`x : [3]int;` 无初值声明不发 IR_ALLOC）。若此类 var 后续被 STORE 重定值且其间有读，窗口无条目覆盖。当前影响小（内存对象非寄存器候选），Task 5 读点判定前需处理（格式定稿 §4.1「dest≥0 = 定值点」规则可消解）。

- [ ] **Step 3: 实现 compute_entries**

扫描函数指令：对每条 `IR_STORE`/`IR_ALLOC` 的 dest（函数内 var）登记新版本条目（版本号递增），版本存在区间端点 = 定值指令号与「下一版本定值前最后引用」——实现时用 Task 1 区间表与定值点表合并。版本间切割：条目 k 的 [start,end] = [def_k, def_{k+1}-1] 与变量全局 last_ref 的截断。

- [ ] **Step 4: 跑测试**

Run: `nice -n 19 python3 tests/selfhost/test_live_ranges.py`
Expected: 新断言 PASS，旧 smoke 仍 PASS

- [ ] **Step 5: 提交**

```bash
jj commit -m 'feat: 条目版本化——STORE/ALLOC 定值切分版本条目（v6 Task 2）'
```

---

### Task 3: 共存推导规则（区间相交）

**Files:**
- Modify: `src/compiler/opt.cr`
- Test: `tests/selfhost/test_live_ranges.py`（追加断言）

**Interfaces:**
- Consumes: Task 2 条目表
- Produces: `fn entries_coexist(func_i, e1, e2) -> int`（1=相交 0=不相交，纯区间比较）；文档确认共存不落盘（推导规则）

- [ ] **Step 1: 写失败测试**

追加断言：`fn main()->int{a:=1;b:=2;return a+b;}` 中 a/b 条目共存（区间相交）；顺序重用的程序（`a:=1;tmp:=a;a:=2;`）中 a 的两版本不共存。

- [ ] **Step 2: 实现 entries_coexist**

```core
fn entries_coexist(func_i: int, e1: int, e2: int) -> int {
    // 存在区间 [s1,e1) 与 [s2,e2) 相交 ⟺ s1 < e2 && s2 < e1（半开区间）
    s1 := <e1 的 live_start>; en1 := <e1 的 live_end>;
    s2 := <e2 的 live_start>; en2 := <e2 的 live_end>;
    if s1 < 0 || s2 < 0 { return 0; }
    if s1 < en2 && s2 < en1 { return 1; }
    return 0;
}
```

- [ ] **Step 3: 跑测试 + 提交**

Run: `nice -n 19 python3 tests/selfhost/test_live_ranges.py`
Commit: `jj commit -m 'feat: 共存推导规则（存在区间相交，不落盘冗余）——v6 Task 3'`

---

### Task 4: v6 entries 段序列化/反序列化（ccr_io.cr）

**Files:**
- Modify: `src/compiler/ccr_io.cr`（save_ccr:193 / load_ccr:376 / calc_ccr_size:130）
- Modify: `src/compiler/globals.cr`（entry 表全局）
- Modify: `src/compiler/dataflow.cr`（lower_to_ccr 尾部调 compute_entries？——**不**：entries 由 save_ccr 前显式计算，见 Step 3）
- Test: `tests/selfhost/test_region_cfg.py` 同款 ccr round-trip 模式或新 `test_ccr_v6.py`

**Interfaces:**
- Produces: version 常量升 6；**ENT 段按格式定稿 spec 落盘**（`docs/superpowers/specs/2026-09-05-lattice-ir-v6-format.md` §3.4：28B/条含 version + 半开区间；段表架构 Header+seg 表）；`load_ccr` 校验 version==6 + 段表完整性（越界拒绝）后按段表解析填充条目表

- [ ] **Step 1: 写 round-trip 测试**

Create `tests/selfhost/test_ccr_v6.py`：编译一个含多版本变量的程序 → `ccr` 命令出 .ccr → 用 `corearch` 或 `corec` 读回（现有 `test_region_cfg.py::test_ccr_v2_sg_section` 模式）→ 断言字节含 version=6 且 round-trip 后 ELF 可跑、退出码正确。

- [ ] **Step 2: 更新格式注释与 version**

`ccr_io.cr` 头注释按 spec 更新段布局；version 写 `6`；`calc_ccr_size` 按 spec 段表 + 各段大小（ENT = entry_count × 28）计算。

- [ ] **Step 3: save 前计算 + 落盘**

save_ccr 按 spec 段表写各段（STR/SYM/NOD/ENT/REG）；ENT 条目（28B/条：var_id/version/def_nod/live_start/live_end/home/flags——version = 组内定值升序序数，半开 live_end = 最后使用点+1，由 Task 2 内存表转换）。**调用点**：save_ccr 由 corec/corearch 调用，条目表须在 save 前就绪——在 `lower_to_ccr()` 尾部（dataflow.cr:351 函数末尾）显式调 `compute_live_ranges()` + 各函数 `compute_entries()`（compute 与 opt 门控解耦，无条件在 lower 尾部算）。

- [ ] **Step 4: load_ccr 读 entries**

load_ccr 按段表定位 ENT 段：校验 `entry_count ≤ 段大小/28`（越界拒绝，先例 ccr 校验风格），填充条目表；ELF 后端只读 NOD 段（= 原线性指令消费路径的坐标化），不依赖 ENT。

- [ ] **Step 5: 跑测试 + 回归 + 提交**

Run: `nice -n 19 python3 tests/selfhost/test_ccr_v6.py && nice -n 19 python3 tests/selfhost/test_region_cfg.py && nice -n 19 python3 tests/selfhost/test_compile.py`
Commit: `jj commit -m 'feat: .ccr v6 entries 段 save/load——版本 6 落盘（v6 Task 4）'`

---

### Task 5: 判定消费最小闭环（.corespec + checker 自检）

**Files:**
- Create: `spec/regalloc-consistency.corespec`（判定四条规约，先规格后实现——TODO 判据「判定规约：一致性四条写成 .corespec」）
- Modify: `src/compiler/checker.cr`（debug 自检钩子）或独立 pass 文件
- Test: `tests/selfhost/test_live_ranges.py`（追加判定用例）

**Interfaces:**
- Produces: 判定实现 `fn verify_regalloc_consistency(func_i) -> int`（0=一致 1=违反）：消费条目表（存在区间/共存/home）+ 当前分配（alloc_registers 结果）——四条：① 共存互斥（同寄存器条目不共存）② 读点无陈旧 ③ 驱逐配对 ④ 调用失效。debug 模式（环境变量或 `g_opt_level ≥ 2`）下 checker 自检调用；违反即编译错误（诊断）。

- [ ] **Step 1: 写 .corespec**

Create `spec/regalloc-consistency.corespec`：四条判定以规范语言陈述（参考 `spec/` 现有文件风格），附条目/区间/共存定义。

- [ ] **Step 2: 写失败测试**

`test_live_ranges.py` 追加：O2 编译已知正确程序 → 自检静默通过（exit 0）；构造错误 home 冲突（测试内直接调 verify 函数注入冲突条目——通过导出测试钩子）→ 返回违反。

- [ ] **Step 3: 实现 verify_regalloc_consistency**

对每函数：① 遍历条目对（同 home 且非 -1）→ entries_coexist 为真则违反；② 读点（使用指令）所在条目版本须是活跃版本（无陈旧）；③④ 按驱逐/调用点标注（v6 先以 home=-1 与调用点指令列表近似——标注字段 flags 预留，精确驱逐语义与贪心放置同批）。范围控制：**本任务只做 ①（共存互斥）+ ② 的框架**，③④ 留 TODO 注记——YAGNI，四条规约先行落文档，代码验证主路径。

- [ ] **Step 4: 测试 + 提交**

Run: `nice -n 19 python3 tests/selfhost/test_live_ranges.py`
Commit: `jj commit -m 'feat: 判定一致性自检（共存互斥闭环）+ regalloc-consistency.corespec 规约——v6 Task 5'`

---

### Task 6: 自举管线 / 测试迁移 / 文档同步

**Files:**
- Modify: `docs/ir-schema/coreir-schema.md`（v6 段布局 + ENT 记录 28B 字段表，按格式定稿 spec）
- Modify: `CLAUDE.md`（`.ccr` 描述 v5 → v6：格层存在结构）
- Modify: `docs/superpowers/specs/2026-08-27-lattice-form-ir-design.md`（状态：执行中→按实施结果复核 §4.2/§5；**§4.2/§5 的「v5→v6 一次性转换工具」按计划定稿取消**（.ccr 为管线中间产物、零持久生态）——同步删除该事项并注记）
- Modify: `docs/project-book.md`、`docs/compcert-reference.md`（如提及 .ccr v5 线性投影描述处）
- Modify: `TODO.md`（v6 事项划销：见「格形态 IR 升级」节 8 事项逐条核对）
- 验证：`bootstrap/corec/ir/ccr.py`（Python bootstrap 的 .ccr 读写——查它是否真的读写 .ccr 还是仅占位）

- [ ] **Step 1: 核对 bootstrap 侧 .ccr 参与度**

Run: `grep -n "ccr\|CCR_MAGIC\|save\|load" bootstrap/corec/ir/ccr.py | head -20`
判定：Python bootstrap 是否实际产出/消费 .ccr（若仅定义未接线，标注「自举管线不受 v6 影响」并跳过该迁移面；若接线则同步格式）。

- [ ] **Step 2: 更新 coreir-schema.md**

按本文「v6 格式布局」写入 entries 段字段表与 version 6 说明；附共存推导规则（不落盘）注记。

- [ ] **Step 3: 更新 CLAUDE.md / 设计文档状态 / TODO**

CLAUDE.md 的 `.ccr` 描述更新（Architecture 节 + Key Conventions）；lattice-form-ir-design.md 状态行改「执行中（2026-09 起）」并在 §4.2 标实施结果；TODO「格形态 IR 升级」8 事项按完成状态划销/标注。

- [ ] **Step 4: 全量回归 + 自检 + 提交**

Run: `nice -n 19 python3 tests/bootstrap/test_pipeline.py && nice -n 19 python3 tests/bootstrap/test_borrow.py && nice -n 19 python3 tests/bootstrap/test_generics.py && ./build/corec check src/compiler`
Commit: `jj commit -m 'docs: v6 落地同步——coreir-schema/CLAUDE.md/设计文档状态/TODO 划销（v6 Task 6）'`

---

## 后续（本计划外，挂 TODO）

- **SYM 归并 / REG 重排 + 区内条目范围**（Task 4 评审 I-1 条件，2026-09-06）：v6.0 保守路径未做 spec §3.2/§3.5 目标形状——SYM 现为 v5 符号面装入段表、REG 为 v5 sgs 原序。坐标化全量目标须挂账（spec 与代码避免永久脱节）
- Task 6 schema 同步以**实现形状**为准落笔（不写编译器永不产出的格式）

- **贪心放置升级**（`opt.cr` alloc_registers → 上下文贪心：存在结构上的 First Fit + 驱逐写回 + 调用点失效）——消费 v6 条目/共存/home；解锁 caller-saved
- **证书层**：最优性证书（DP 表重放 / ILP 对偶）
- **无配方条目完整语义**（条款 4b 边界 + 驱逐必写回）——v6 flags 位 0 字段已预留
- **v6.1**：驱逐/填充点标注段（设计文档 §4.2 第 5 条，可选）
- 宽度标签清理（width-out-of-language 语言侧）与 v6 无交互——v6 格式无宽度字段，可并行
