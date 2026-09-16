# RVSDG Region 化控制流 Implementation Plan

> **术语注记（2026-08-15）**：本计划中的"RVSDG 式"为当时路线的真实记录；该结构后定名为 **HDFG（Holographic Dataflow Graph）**，术语演进见 docs/project-book.md。正文保留历史原样。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把现有 SG 子图树升级为 RVSDG 式嵌套 region（新增 SG_IF、显式 node→region 映射、解释器 region 迭代执行、state edges、序列化 v2），根治解释器 for 循环 bug 并为验证工具铺路。

**Architecture:** 复用现有 `sg_push/sg_pop` 嵌套树（dataflow.cr）；新增 `g_df_node_region[]` 显式映射与 `SG_IF`；解释器循环从 label 位置表跳转改为 region 边界判定；DFEdge 加 kind 承载 state edges；.ccr 格式追加 SG 段（v2，v1 兼容加载）。ELF 后端零改动。

**Tech Stack:** Core 自举编译器（src/compiler/：dataflow.cr、ir_gen.cr、interp.cr、dump.cr、ccr_io.cr、region_check.cr）；Python 测试驱动（tests/selfhost/）；构建 `build_selfhost_native.py`。

## Global Constraints

- 版本控制用 `jj`，禁止 `git`（项目铁律 2）；提交只包含本任务文件
- 任何编译/测试命令用 `nice -n 19` 前缀限制 CPU（项目铁律 6）；快速单文件测试（<30s）可不加
- 禁止绕过问题、禁止还原文件（铁律 1/3/5）
- 常量/关键字以源码为准（`src/compiler/ast.cr`、`src/compiler/dyn_arr.cr` 的 ESZ_*/OFF_* 定义）
- 解释器 opcode 编号（interp.cr 实际值）：CONST=1 BINARY=2 RETURN=5 ALLOC=6 ALLOC_STRUCT=7 ALLOC_ARRAY=8 STORE=9 LOAD=10 LOAD_FIELD=11 STORE_FIELD=12 LOAD_INDEX=13 STORE_INDEX=14 LOAD_INDEX_VAR=15 STORE_INDEX_VAR=16 BRANCH=19 JUMP=20 LABEL=21
- SG 常量（dataflow.cr:104-106）：SG_FUNC=0 SG_LOOP=1 SG_FOR=2 SG_FLOW=3 SG_UNSAFE=4
- 规格：`docs/superpowers/specs/2026-08-08-region-cfg-design.md`（阶段划分 P1-P5 对应 Task 1-6）

---

### Task 1: SG_IF region 生成（ir_gen + dataflow 常量）

**Files:**
- Modify: `src/compiler/dataflow.cr:104-106`（SG 常量区）
- Modify: `src/compiler/ir_gen.cr:1147-1159`（if/else 生成处）
- Create: `tests/selfhost/test_region_cfg.py`（Python 测试驱动）

**Interfaces:**
- Consumes: `sg_push(kind)` / `sg_pop()`（dataflow.cr:36-64，已有）；`g_sgs` 表（globals.cr:123）；`cmd_cir` dump 输出格式（dump.cr:225-270，"Function: name" + "Block: labelN"）
- Produces: `SG_IF = 5` 常量；if/else 生成 SG_IF region（Task 2/3 依赖）

- [ ] **Step 1: 写失败测试**

创建 `tests/selfhost/test_region_cfg.py`：

```python
#!/usr/bin/env python3
"""Region-based control flow tests — dump .cir text and assert region structure."""
import os, subprocess, tempfile

BASE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
COREC = os.path.join(BASE, 'build/corec')

def cir_dump(src: str) -> str:
    with tempfile.NamedTemporaryFile('w', suffix='.cr', delete=False) as f:
        f.write(src)
        path = f.name
    r = subprocess.run(['./build/corec', 'cir', path], capture_output=True, text=True,
                       cwd=BASE, timeout=30)
    os.unlink(path)
    return r.stdout

def test_if_region():
    out = cir_dump("fn f(x: int) -> int {\n    if x > 0 { return 1; }\n    return 0;\n}\nfn main() -> int { return f(1); }\n")
    assert 'Region: if' in out, f"SG_IF region missing in cir dump:\n{out}"

def test_loop_region():
    out = cir_dump("fn main() -> int {\n    s : ., mut = 0;\n    for i in 0..3 { s = s + i; }\n    return s;\n}\n")
    assert 'Region: for' in out, f"SG_FOR region missing in cir dump:\n{out}"
```

- [ ] **Step 2: 运行测试确认失败**

Run: `nice -n 19 python3 tests/selfhost/test_region_cfg.py -v`
Expected: FAIL — 断言 `'Region: if' in out` 失败（cir dump 尚无 Region 行）

- [ ] **Step 3: 实现 SG_IF 常量**

`src/compiler/dataflow.cr:104-106` 常量区追加：

```core
SG_FUNC   : int = 0;
SG_LOOP   : int = 1;
SG_FOR    : int = 2;
SG_FLOW   : int = 3;
SG_UNSAFE : int = 4;
SG_IF     : int = 5;  // conditional region: covers [condition, merge)
```

- [ ] **Step 4: if/else 生成 SG_IF**

`src/compiler/ir_gen.cr:1147-1159` 的 if 处理（当前是 `emit(IR_BRANCH...)` 开始 then/else/merge label 序列）在 BRANCH 之前加 region 打开、merge label 之后加关闭：

```core
// 现有 if 处理第一行（约 1145 行 `if ast_kind(node) == EXPR_IF {`）之后插入：
sg_push(SG_IF);
// ... 现有 BRANCH/LABEL/body/merge 生成不变 ...
// 现有 merge label emit（约 1159 行 emit(IR_LABEL, -1, merge_lbl, ...)）之后、return -1 之前：
sg_pop();
```

（`sg_push`/`sg_pop` 已在 ir_gen.cr:29/35 被 `sg_alloc_push`/`sg_alloc_pop` 调用——直接调用即可，无需新声明。）

- [ ] **Step 5: 实现 region 标注输出**

`src/compiler/dump.cr` 的 `cmd_cir`（dump.cr:225），在 Function 循环内、Block 循环前加 region 段输出：

```core
// 在 ccr = ccr + "Function: " + istr_get(name_ni) + "\n"; 之后插入：
// 该函数的 region 列表（SG_IF/SG_LOOP/SG_FOR/SG_FLOW/SG_UNSAFE，含 parent 缩进）
ri : ., mut = 0;
loop {
    if ri >= g_sg_count { break; }
    rkind := r64(g_sgs, ri * ESZ_SG + OFF_SG_KIND);
    rstart := r64(g_sgs, ri * ESZ_SG + OFF_SG_NSTART);
    rend := r64(g_sgs, ri * ESZ_SG + OFF_SG_EXIT);
    if rstart >= start && rstart < start + count {
        rname : ., mut = "?";
        if rkind == SG_IF     { rname = "if"; }
        if rkind == SG_LOOP   { rname = "loop"; }
        if rkind == SG_FOR    { rname = "for"; }
        if rkind == SG_FLOW   { rname = "flow"; }
        if rkind == SG_UNSAFE { rname = "unsafe"; }
        ccr = ccr + "  Region: " + rname + " nodes " + int_str(rstart) + ".." + int_str(rend) + "\n";
    }
    ri = ri + 1;
}
```

（`start`/`count` 是外层已有变量：`r64(g_ir_func_instr_start, fi * 8)` / `r64(g_ir_func_instr_count, fi * 8)`。注意 SG 的 ENTER/NSTART 是 DFNode 序号而函数 start 是线性指令序号——两套编号在 dump 里都以本函数内相对位置近似显示，断言只查 `Region: if` 存在，不查具体编号。）

- [ ] **Step 6: 运行测试确认通过**

Run: `nice -n 19 python3 tests/selfhost/test_region_cfg.py -v`
Expected: PASS（两个断言通过）

- [ ] **Step 7: 回归——编译器自举检查**

Run: `nice -n 19 ./build/corec check src/compiler/main.cr`
Expected: 无致命错误（若 SG_IF 常量冲突或 if 生成破坏编译，在此暴露）

- [ ] **Step 8: 提交**

```bash
jj commit -m "feat: SG_IF region for conditionals + region annotation in cir dump"
```

---

### Task 2: 显式 g_df_node_region 映射 + DOT 按 region 分组

**Files:**
- Modify: `src/compiler/dataflow.cr`（g_df_node_region 数组 + df_create_node 写入）
- Modify: `src/compiler/globals.cr:121-123`（新全局声明）
- Modify: `src/compiler/dataflow.cr:331+`（df_graph_to_dot 分组）
- Modify: `tests/selfhost/test_region_cfg.py`

**Interfaces:**
- Consumes: `sg_push/sg_pop`（Task 1 已含 SG_IF）；`g_sg_count`/`g_sgs`
- Produces: `g_df_node_region[]`（每 DFNode → region id，-1 = 无）；`g_cur_sg`（当前 open region id，sg_push 设置、sg_pop 恢复为 parent）

- [ ] **Step 1: 写失败测试（追加到 test_region_cfg.py）**

```python
def test_node_region_mapping():
    out = cir_dump("fn main() -> int {\n    s : ., mut = 0;\n    for i in 0..3 { s = s + i; }\n    return s;\n}\n")
    # DOT cluster 分组：for region 的节点应出现在同一 cluster 内
    assert 'cluster_for' in out, f"DOT region cluster missing:\n{out}"
```

- [ ] **Step 2: 运行确认失败**

Run: `nice -n 19 python3 tests/selfhost/test_region_cfg.py -v`
Expected: FAIL（`cluster_for` 不存在）

- [ ] **Step 3: 修复 sg_pop close 语义（硬性要求）+ 实现 g_cur_sg 与映射数组**

> **硬性要求（Task 1 审查发现，root cause 在既有代码）**：`sg_pop` 当前关闭 `g_sg_count-1` 且不递减 count——ir_gen 的 pop 正确关闭嵌套 region 后，`df_end_func`（dataflow.cr:321-327）再 pop 又落到同一条目，把最内层 region 的 EXIT 覆盖为全函数节点数（已用重建二进制验证：`Region: if nodes 4..18`，实际 if 在 ~12 结束）。SG_FOR 同样被腐蚀 → Task 3 的循环预扫会算错范围。**修复：`sg_pop` 改为弹出"最后 open 条目"（EXIT<0），并同步恢复 `g_cur_sg` 为其 parent。**

```core
// sg_pop：弹出最后一个 open（EXIT<0）的 region，而非 g_sg_count-1
fn sg_pop() {
    if g_sg_count <= 0 { return; }
    idx : ., mut = -1;
    pi := g_sg_count - 1;
    loop {
        if pi < 0 { break; }
        if r64(g_sgs, pi * ESZ_SG + OFF_SG_EXIT) < 0 { idx = pi; break; }
        pi = pi - 1;
    }
    if idx < 0 { return; }
    w64(g_sgs, idx * ESZ_SG + OFF_SG_EXIT, g_df_node_count);
    w64(g_sgs, idx * ESZ_SG + OFF_SG_NCOUNT,
        g_df_node_count - r64(g_sgs, idx * ESZ_SG + OFF_SG_NSTART));
    g_cur_sg = r64(g_sgs, idx * ESZ_SG + OFF_SG_PARENT);
}
```

验证修复（dump 断言）：if 后跟尾代码的函数，`Region: if nodes A..B` 的 B 必须等于 merge label 处节点数（不吞尾代码）。测试：`tests/selfhost/test_region_cfg.py` 的 if/for 用例改为断言区域边界在函数指令跨度内（sanity 检查）。

（`sg_alloc_push/sg_alloc_pop` 与 `g_sg_alloc_total/g_sg_arena_var` 并行表按 push/pop 配对索引，不受"弹出最后 open"影响——arena 用例 `tests/suite/arena_test.cr` 回归验证。）

`src/compiler/globals.cr:123` 附近（g_sgs 声明处）追加：

```core
g_df_node_region : string, mut;   g_df_node_region_cap : int, mut;  // per DFNode: owning region id (-1 = none)
g_cur_sg : int, mut;              // currently open region id (-1 = none)
```

`src/compiler/dataflow.cr`：

```core
// df_create_node 内、g_df_node_count = nid 递增之前插入（约 68-90 行）：
fn df_create_node(opcode: int, dest: int, src1: int, src2: int, src3: int, type_kind: int) -> int {
    nid := g_df_node_count;
    grow_df_nodes(nid + 1);
    grow_df_node_region(nid + 1);
    w64(g_df_node_region, nid * 8, g_cur_sg);
    // ... 现有初始化不变 ...
}
```

（`grow_df_node_region` 照 `grow_df_nodes` 模式实现：cap 倍增、_dyncpy 复制。）

`sg_push` 末尾追加 `g_cur_sg = idx;`（parent 计算之后、`g_sg_count = idx + 1` 之前）；`sg_pop` 的 g_cur_sg 恢复已包含在上方硬性要求的新实现中。

`src/compiler/dataflow.cr` 的 init_df 中重置：`g_df_node_region_cap = 0;`（node region 数组随 grow 重建）。

- [ ] **Step 4: DOT 按 region 分组**

`df_graph_to_dot`（dataflow.cr:331）中，节点输出前加 cluster 头（用 `digraph` 现有的 subgraph 语法）：

```core
// df_graph_to_dot 中，遍历 g_sgs 输出 cluster 定义（在输出节点之前）：
si : ., mut = 0;
loop {
    if si >= g_sg_count { break; }
    skind := r64(g_sgs, si * ESZ_SG + OFF_SG_KIND);
    sname : ., mut = "region";
    if skind == SG_IF     { sname = "if"; }
    if skind == SG_LOOP   { sname = "loop"; }
    if skind == SG_FOR    { sname = "for"; }
    if skind == SG_FLOW   { sname = "flow"; }
    if skind == SG_UNSAFE { sname = "unsafe"; }
    dot = dot + "  subgraph cluster_" + sname + int_str(si) + " { label=\"" + sname + "\";\n";
    // 该 region 内节点：
    n0 := r64(g_sgs, si * ESZ_SG + OFF_SG_NSTART);
    n1 := r64(g_sgs, si * ESZ_SG + OFF_SG_EXIT);
    ni : ., mut = n0;
    loop { if ni >= n1 { break; }
        dot = dot + "    n" + int_str(ni) + ";\n";
        ni = ni + 1; }
    dot = dot + "  }\n";
    si = si + 1;
}
```

（`dot` 变量为 df_graph_to_dot 内部累加串——插入到现有节点循环之前。节点命名与现有输出一致：`n{id}`。）

- [ ] **Step 5: 运行测试确认通过**

Run: `nice -n 19 python3 tests/selfhost/test_region_cfg.py -v`
Expected: PASS

- [ ] **Step 6: 回归——cir dump 无崩溃**

Run: `nice -n 19 ./build/corec cir tests/suite/go_parallel_test.cr 2>&1 | head -20`
Expected: 正常输出（DOT 含 cluster 段，无崩溃）

- [ ] **Step 7: 提交**

```bash
jj commit -m "feat: explicit DFNode→region mapping (g_df_node_region) + DOT clusters"
```

---

### Task 3: 解释器 region 迭代执行（根治 for 循环 bug）

**Files:**
- Modify: `src/compiler/interp.cr`（预扫描 + IR_JUMP 处理）
- Modify: `src/compiler/globals.cr`（循环 region 表全局）
- Create: `tests/selfhost/test_region_cfg.py` 追加运行类测试

**Interfaces:**
- Consumes: `g_sgs`（SG 表）；`g_df_node_region`（Task 2）；`g_df_func_node_start/node_count`（main 函数图区间）；`g_label_poses`（label→node 偏移，interp.cr:42-57 预扫描已有）
- Produces: `g_loop_regions[]`（每循环 region 的 enter/exit 图内偏移）；循环执行不再依赖 label 回跳查找

- [ ] **Step 1: 写失败测试（复现 TODO #2026-07-25-1 for 循环 bug）**

追加到 `tests/selfhost/test_region_cfg.py`：

```python
def test_for_loop_run():
    """for 循环在解释器中正确执行并返回累加和（TODO #2026-07-25-1 回归用例）"""
    with tempfile.NamedTemporaryFile('w', suffix='.cr', delete=False) as f:
        f.write("fn main() -> int {\n    s : ., mut = 0;\n    for i in 0..4 { s = s + i; }\n    return s;\n}\n")
        path = f.name
    r = subprocess.run(['./build/corec', 'run', 'fn main() -> int { s : ., mut = 0; for i in 0..4 { s = s + i; } return s; }'],
                       capture_output=True, text=True, cwd=BASE, timeout=30)
    os.unlink(path)
    assert '6' in r.stdout, f"for loop expected 6, got stdout={r.stdout!r} stderr={r.stderr!r}"

def test_while_loop_run():
    r = subprocess.run(['./build/corec', 'run',
                        'fn main() -> int { n : ., mut = 0; while n < 5 { n = n + 1; } return n; }'],
                       capture_output=True, text=True, cwd=BASE, timeout=30)
    assert '5' in r.stdout, f"while loop expected 5, got {r.stdout!r}"

def test_break_continue_run():
    r = subprocess.run(['./build/corec', 'run',
                        'fn main() -> int { s : ., mut = 0; for i in 0..10 { if i == 2 { continue; } if i == 6 { break; } s = s + i; } return s; }'],
                       capture_output=True, text=True, cwd=BASE, timeout=30)
    assert '13' in r.stdout, f"break/continue expected 13 (0+1+3+4+5), got {r.stdout!r}"
```

（`corec run` 为解释器模式，见 CLAUDE.md。若 `corec run` 对多行/字符串有解析限制，改用临时文件 + `./build/corec build path -o /tmp/out && /tmp/out` 的形式运行并捕获输出。）

- [ ] **Step 2: 运行确认失败**

Run: `nice -n 19 python3 tests/selfhost/test_region_cfg.py -v`
Expected: test_for_loop_run FAIL（stdout 无 `6`——解释器 for 循环不兼容，即 TODO #2026-07-25-1）

- [ ] **Step 3: 实现循环 region 预扫描**

`src/compiler/globals.cr` 追加：

```core
g_loop_region_enter : string, mut;  g_loop_region_exit : string, mut;
g_loop_region_count : int, mut;     g_loop_region_cap : int, mut;  // per loop region: enter/exit node offsets
```

`src/compiler/interp.cr`，现有 label 预扫描（42-57 行）之后追加：

```core
    // Pre-scan: record SG_LOOP/SG_FOR region enter/exit node offsets
    // (main function graph only — filter by node_start..node_start+node_count)
    g_loop_region_count = 0;
    li = 0;
    loop {
        if li >= g_sg_count { break; }
        lk := r64(g_sgs, li * ESZ_SG + OFF_SG_KIND);
        if lk == SG_LOOP || lk == SG_FOR {
            l_enter := r64(g_sgs, li * ESZ_SG + OFF_SG_ENTER);
            l_exit  := r64(g_sgs, li * ESZ_SG + OFF_SG_EXIT);
            if l_enter >= node_start && l_enter < node_start + node_count {
                if g_loop_region_count + 1 > g_loop_region_cap {
                    nc := g_loop_region_cap * 2; if nc < 16 { nc = 16; }
                    nb := alloc(nc * 8); _dyncpy(g_loop_region_enter, g_loop_region_cap * 8, nb);
                    g_loop_region_enter = nb; g_loop_region_cap = nc;
                    nb2 := alloc(nc * 8); _dyncpy(g_loop_region_exit, g_loop_region_cap * 8, nb2);
                    g_loop_region_exit = nb2;
                }
                w64(g_loop_region_enter, g_loop_region_count * 8, l_enter - node_start);
                w64(g_loop_region_exit,  g_loop_region_count * 8, l_exit  - node_start);
                g_loop_region_count = g_loop_region_count + 1;
            }
        }
        li = li + 1;
    }
```

- [ ] **Step 4: 实现 region 迭代的 JUMP 处理**

`src/compiler/interp.cr:193-197` 现有 IR_JUMP 处理改为：

```core
        if op == 20 {  // IR_JUMP
            // Region iteration: a jump back to the innermost loop region's
            // enter node restarts the iteration; a jump to the region exit
            // label falls through to region-external code.  Loop execution
            // is thus driven by region boundaries, not the label table.
            if s1 >= 0 && s1 < g_label_count {
                target := r64(g_label_poses, s1 * 8);
                if target >= 0 {
                    // 当前 ip 所在循环 region（若在区域内）
                    cur_enter : ., mut = -1;
                    ri2 : ., mut = 0;
                    loop {
                        if ri2 >= g_loop_region_count { break; }
                        e2 := r64(g_loop_region_enter, ri2 * 8);
                        x2 := r64(g_loop_region_exit,  ri2 * 8);
                        if ip >= e2 && ip < x2 && e2 > cur_enter {
                            cur_enter = e2;
                            if target == e2 { ip = e2; }
                        }
                        ri2 = ri2 + 1;
                    }
                    if cur_enter < 0 { ip = target; }        // 非循环跳转照旧
                    else if target != r64(g_loop_region_enter, 0) { ip = target; }  // 区域内跳转照旧
                    // 若 target == 当前 region enter：ip 已设为 e2（迭代）
                } else { ip = ip + 1; }
            } else { ip = ip + 1; }
            if ip < node_count { continue; } else { break; }
        }
```

（该实现把"回跳 header"显式化为 region 迭代：target == 当前 innermost region 的 enter → 回到 region 起点继续迭代；其余照旧 label 跳转。若测试表明原 bug 另有成因——如 IR_ALLOC/STORE 对循环变量的处理——Step 5 中按解释器实际输出修正，保持"region 边界判定"为循环执行的主路径。）

- [ ] **Step 5: 运行测试**

Run: `nice -n 19 python3 tests/selfhost/test_region_cfg.py -v`
Expected: test_for_loop_run / test_while_loop_run / test_break_continue_run 全部 PASS

若仍有失败：用 `./build/corec run` 加 `cir` dump 对比指令序列，按实际失败模式修正 Step 4 实现（回归断言以测试为准，不修改测试期望值）。

- [ ] **Step 6: 全量解释器回归**

Run: `nice -n 19 python3 tests/bootstrap/test_pipeline.py && nice -n 19 python3 tests/selfhost/test_compile.py`
Expected: 全绿（解释器改动不影响编译管线；若有失败属解释器行为变化，逐个确认后修正）

- [ ] **Step 7: 提交**

```bash
jj commit -m "fix: interpreter loop execution via region iteration (TODO #2026-07-25-1)"
```

---

### Task 4: State Edges（副作用链 + 循环终止依赖）

**Files:**
- Modify: `src/compiler/dyn_arr.cr:52,99`（ESZ_DFEDGE 24→32、OFF_DFE_* 加 KIND）
- Modify: `src/compiler/dataflow.cr`（df_connect_srcs 副作用链 + sg_pop 终止边）
- Modify: `src/compiler/dump.cr`（cir 文本显示 state 边）
- Modify: `tests/selfhost/test_region_cfg.py`

**Interfaces:**
- Consumes: `df_add_edge`（dataflow.cr:94）；`g_sgs`；`g_df_node_region`（Task 2）
- Produces: `OFF_DFE_KIND = 16`（0=data, 1=state）；副作用链与循环终止边

- [ ] **Step 1: 写失败测试**

```python
def test_state_edges():
    out = cir_dump("fn main() -> int {\n    s : ., mut = 0;\n    s = s + 1;\n    s = s + 2;\n    return s;\n}\n")
    assert 'state' in out, f"state edges not shown in cir dump:\n{out}"
```

- [ ] **Step 2: 运行确认失败**

Run: `nice -n 19 python3 tests/selfhost/test_region_cfg.py -v`
Expected: FAIL（`state` 不存在）

- [ ] **Step 3: 边结构加 kind**

`src/compiler/dyn_arr.cr:99`：

```core
// DFEdge sizes and offsets
ESZ_DFEDGE : int = 32;   // from_node,to_node,next_out,kind = 4x8
OFF_DFE_FROM : int = 0;  OFF_DFE_TO : int = 8;  OFF_DFE_NEXT : int = 16;
OFF_DFE_KIND : int = 24; // 0=data (def-use), 1=state (ordering/termination)
```

- [ ] **Step 4: 副作用链 + 终止边实现**

`src/compiler/dataflow.cr`：

```core
// df_add_edge 改为带 kind 版本；原 df_add_edge 保持 0 参数语义内部调 df_add_edge_kind(..., 0)
fn df_add_edge_kind(from_id: int, to_id: int, kind: int) {
    if from_id < 0 || to_id < 0 { return; }
    // ... 原 df_add_edge 逻辑（grow_df_edges、写 from/to/next、g_df_edge_count 递增）...
    w64(g_df_edges, (g_df_edge_count - 1) * ESZ_DFEDGE + OFF_DFE_KIND, kind);
}

fn df_add_edge(from_id: int, to_id: int) { df_add_edge_kind(from_id, to_id, 0); }
```

副作用链（模块级变量，df_begin_func 重置）：

```core
// df_begin_func 中：g_last_state_node = -1;
// df_connect_srcs 内，opcode 判定为副作用时：
fn df_connect_state(node_id: int, opcode: int) {
    is_side_effect : ., mut = 0;
    if opcode == IR_STORE        { is_side_effect = 1; }
    if opcode == IR_STORE_FIELD  { is_side_effect = 1; }
    if opcode == IR_STORE_INDEX  { is_side_effect = 1; }
    if opcode == IR_STORE_INDEX_VAR { is_side_effect = 1; }
    if opcode == IR_CALL && fi_ispure(find_func(/*当前函数*/)) == 0 { is_side_effect = 1; }
    if is_side_effect != 0 {
        if g_last_state_node >= 0 { df_add_edge_kind(g_last_state_node, node_id, 1); }
        g_last_state_node = node_id;
    }
}
```

（`IR_CALL` 的纯度判定：call 的 s3 是 func name idx——`fi_ispure` 需要 func index；实现时经 `find_func(s3)` 获得。非纯调用才进链。若 find_func 不可得（外部函数），保守进链。）

循环终止依赖（`sg_pop` 内，kind 为 SG_LOOP/SG_FOR 时）：

```core
// sg_pop 中、OFF_SG_EXIT 写入之后：
if kind == SG_LOOP || kind == SG_FOR {
    // region 内最后一条副作用指令 → region 最后一个节点（exit label）
    last_node := g_df_node_count - 1;
    if last_node >= r64(g_sgs, idx * ESZ_SG + OFF_SG_NSTART) {
        if g_last_state_node >= 0 {
            df_add_edge_kind(g_last_state_node, last_node, 1);  // termination dependency
        }
    }
}
```

- [ ] **Step 5: dump 显示 state 边**

`src/compiler/dump.cr` 的 cir 文本输出（DFNode 转储处）：DFEdge 遍历时按 kind 标注：

```core
// 现有边输出逻辑处（若存在）或 DFNode 转储追加：
// 每节点输出其后加：
//   if edge kind == 1: "state" 标注
```

（若 dump.cr 当前不输出 DFEdge 明细，则在 `cmd_cir` 的 Function 段后追加一个 edges 段：遍历 `g_df_edges`，kind==1 的行输出 `state: n{from} -> n{to}`。测试断言只查 `state` 字符串存在。）

- [ ] **Step 6: 运行测试确认通过**

Run: `nice -n 19 python3 tests/selfhost/test_region_cfg.py -v`
Expected: PASS

- [ ] **Step 7: 回归**

Run: `nice -n 19 python3 tests/bootstrap/test_pipeline.py`
Expected: 全绿（ESZ_DFEDGE 改 32 影响所有读写该结构的代码——grep `ESZ_DFEDGE` 全部使用点确认无越界）

- [ ] **Step 8: 提交**

```bash
jj commit -m "feat: state edges — side-effect chain + loop termination dependency (VSDG)"
```

---

### Task 5: 序列化 v2（.ccr 追加 SG 段 + edge kind）

**Files:**
- Modify: `src/compiler/ccr_io.cr`（save_ccr/load_ccr）
- Create: `tests/selfhost/test_region_cfg.py` 追加往返测试

**Interfaces:**
- Consumes: `save_ccr(path)` / `load_ccr(buf, size)`（ccr_io.cr:137+）；`g_sgs`
- Produces: .ccr v2（version 5：追加 SG 段 + DFEdge kind）；v1（version 4）兼容加载

- [ ] **Step 1: 写失败测试**

```python
def test_ccr_roundtrip_v2():
    """save→load 往返：v2 文件含 SG 段，load 后 g_sg_count 恢复"""
    src = "fn main() -> int {\n    s : ., mut = 0;\n    for i in 0..3 { s = s + i; }\n    return s;\n}\n"
    with tempfile.NamedTemporaryFile('w', suffix='.cr', delete=False) as f:
        f.write(src); path = f.name
    r = subprocess.run(['./build/corec', 'build', path, '-o', '/tmp/core_region_v2', '--static'],
                       capture_output=True, text=True, cwd=BASE, timeout=60)
    os.unlink(path)
    assert r.returncode == 0, f"build failed: {r.stderr}"
    # 生成的二进制运行（ELF 路径，region 元数据不影响代码）
    run = subprocess.run(['/tmp/core_region_v2'], capture_output=True, text=True, timeout=10)
    assert '6' in run.stdout, f"expected 6, got {run.stdout!r}"
```

- [ ] **Step 2: 运行确认当前状态**

Run: `nice -n 19 python3 tests/selfhost/test_region_cfg.py -v`
Expected: 当前即 PASS（v2 未加，但 ELF 路径不受影响）——本测试为 v2 后行为不变的守卫；真正的 v2 断言在 Step 4 实现后补充（load 侧 g_sg_count 恢复的检查经 corearch 加载回归验证）。

- [ ] **Step 3: save_ccr 追加 SG 段**

`src/compiler/ccr_io.cr:144` 版本号 4 → 5，并在文件尾部（现有各段写完、字符串表之后）追加：

```core
    // v5: SG (region) section — sg_count × 48B
    buf_write_u32(buf, pos, g_sg_count); pos = pos + 4;
    si : ., mut = 0;
    loop {
        if si >= g_sg_count { break; }
        // 直写 48B 记录（kind/enter/exit/parent/nstart/ncount）
        f := si * ESZ_SG;
        buf_write_i32(buf, pos, r64(g_sgs, f + OFF_SG_KIND)); pos = pos + 4;
        buf_write_i32(buf, pos, r64(g_sgs, f + OFF_SG_ENTER)); pos = pos + 4;
        buf_write_i32(buf, pos, r64(g_sgs, f + OFF_SG_EXIT)); pos = pos + 4;
        buf_write_i32(buf, pos, r64(g_sgs, f + OFF_SG_PARENT)); pos = pos + 4;
        buf_write_i32(buf, pos, r64(g_sgs, f + OFF_SG_NSTART)); pos = pos + 4;
        buf_write_i32(buf, pos, r64(g_sgs, f + OFF_SG_NCOUNT)); pos = pos + 4;
        si = si + 1;
    }
```

（`buf_write_i32` 已存在（ccr_io.cr:35）。追加在字符串表段之后、文件结束前——load 侧对应位置读取。）

- [ ] **Step 4: load_ccr 兼容 v4/v5**

`src/compiler/ccr_io.cr` 的 load：版本判断处（当前读取 version 的位置）改为：

```core
    ver := <读出的 version 字段>;
    // v4（无 SG 段）：跳过 SG 读取，g_sg_count = 0
    // v5：按 Step 3 布局读取 SG 段并回填 g_sgs
    if ver >= 5 {
        sg_n := buf_read_i32(buf, pos); pos = pos + 4;
        si = 0;
        loop {
            if si >= sg_n { break; }
            grow_sg(si + 1);
            f = si * ESZ_SG;
            w64(g_sgs, f + OFF_SG_KIND, buf_read_i32(buf, pos)); pos = pos + 4;
            w64(g_sgs, f + OFF_SG_ENTER, buf_read_i32(buf, pos)); pos = pos + 4;
            w64(g_sgs, f + OFF_SG_EXIT, buf_read_i32(buf, pos)); pos = pos + 4;
            w64(g_sgs, f + OFF_SG_PARENT, buf_read_i32(buf, pos)); pos = pos + 4;
            w64(g_sgs, f + OFF_SG_NSTART, buf_read_i32(buf, pos)); pos = pos + 4;
            w64(g_sgs, f + OFF_SG_NCOUNT, buf_read_i32(buf, pos)); pos = pos + 4;
            si = si + 1;
        }
        g_sg_count = sg_n;
    }
```

- [ ] **Step 5: 兼容性回归——旧 v4 文件**

Run: 用仓库中任一既有 `.ccr` 产物（或先生成一个 v4 文件存档）验证：

```bash
nice -n 19 ./build/corec ccr tests/suite/go_parallel_test.cr -o /tmp/old_v4.ccr   # 若当前已产出 v4
# 修改后重新构建 corec，再加载：
nice -n 19 python3 build_selfhost_native.py 2>&1 | tail -3   # 重新构建（含 v5 支持）
./build/corearch /tmp/old_v4.ccr --elf --static -o /tmp/old_v4_bin && /tmp/old_v4_bin
```

Expected: v4 文件正常加载执行（返回 0/正确输出）——验证向后兼容。若仓库无 v4 产物，用 `jj show qvkrpwxs --tool=..` 前一个版本生成一个再测，或跳过本步并在提交信息注明。

- [ ] **Step 6: 自举三阶段回归（v5 格式全链路）**

Run: `nice -n 19 python3 build_selfhost_native.py && nice -n 19 ./build/corec build build/all.cr -o /tmp/corec2 --static -O 0 2>&1 | tail -3`
Expected: corec2 构建成功（v5 格式经 corec→corearch 全链路，无解析错误）

- [ ] **Step 7: 提交**

```bash
jj commit -m "feat: ccr serialization v2 — SG region section + version 5, v4 compatible load"
```

---

### Task 6: RegionCheck 显式映射 + 全量回归 + 文档同步

**Files:**
- Modify: `src/compiler/region_check.cr`（subgraph_containing 用 g_df_node_region）
- Modify: `docs/project-book.md`（5.2 反馈环愿景修正）
- Modify: `docs/execution-model.md`（静态循环图描述修正）
- Modify: `docs/ir-schema/coreir-schema.md`（SG 段 + edge kind + v2）
- Modify: `CLAUDE.md`（dataflow.cr 职责描述）
- Create: `tests/selfhost/test_region_cfg.py` 追加 region_check 断言

**Interfaces:**
- Consumes: `g_df_node_region`（Task 2）；`subgraph_containing`（region_check.cr:36-49）
- Produces: 文档同步（规格第 11 节）

- [ ] **Step 1: 写失败测试**

```python
def test_region_check_pointer_escape():
    """嵌套 region 下的指针逃逸检测（RegionCheck 走显式映射后仍正确）"""
    src = "fn bad() -> &int {\n    x := 42;\n    return &x;\n}\nfn main() -> int { return 0; }\n"
    with tempfile.NamedTemporaryFile('w', suffix='.cr', delete=False) as f:
        f.write(src); path = f.name
    r = subprocess.run(['./build/corec', 'check', path], capture_output=True, text=True,
                       cwd=BASE, timeout=30)
    os.unlink(path)
    assert 'B010' in r.stdout or 'error' in r.stdout, f"expected escape error, got {r.stdout!r}"
```

- [ ] **Step 2: 运行确认当前行为**

Run: `nice -n 19 python3 tests/selfhost/test_region_cfg.py -v`
Expected: 当前即 PASS（B010 已在）——本测试为迁移后的守卫。真正的迁移验证在 Step 4 后重跑全量。

- [ ] **Step 3: subgraph_containing 用显式映射**

`src/compiler/region_check.cr:36-49` 的 `subgraph_containing(ni)`（当前线性扫 g_sgs 区间）改为：

```core
fn subgraph_containing(node_seq: int) -> int {
    // 显式映射：O(1) 归属查询（g_df_node_region 由 df_create_node 写入）
    if node_seq >= 0 && node_seq < g_df_node_count {
        return r64(g_df_node_region, node_seq * 8);
    }
    return -1;
}
```

（调用处 `alloc_seq_to_sg` 仍保留其现有逻辑——两者语义对齐：region id == g_sgs 索引。）

- [ ] **Step 4: 全量回归**

Run:
```bash
nice -n 19 python3 tests/selfhost/test_region_cfg.py -v
nice -n 19 python3 tests/bootstrap/test_pipeline.py
nice -n 19 python3 tests/bootstrap/test_borrow.py
nice -n 19 python3 tests/bootstrap/test_generics.py
nice -n 19 python3 tests/selfhost/test_compile.py
nice -n 19 python3 tests/selfhost/test_impl.py
nice -n 19 python3 tests/selfhost/test_borrow.py
```
Expected: 全绿。再跑自举三阶段：
```bash
nice -n 19 ./build/corec build build/all.cr -o /tmp/corec2 --static -O 0 2>&1 | tail -3
nice -n 19 /tmp/corec2 build build/all.cr -o /tmp/corec3 --static -O 0 2>&1 | tail -3
nice -n 19 /tmp/corec3 build build/all.cr -o /tmp/corec4 --static -O 0 2>&1 | tail -3
cmp /tmp/corec3 /tmp/corec4 && echo "BYTE-IDENTICAL"
```
Expected: corec2/corec3/corec4 全部成功且 corec3 与 corec4 逐字节一致

- [ ] **Step 5: 文档同步**

`docs/project-book.md` 5.2 段（当前"当代码中出现 loop 构造，图中引入反馈边——从循环体末端回到循环头。执行器按迭代周期调度"）改为：

```markdown
### 5.2 带环静态图：有节奏的循环

当代码中出现 loop 构造，图中引入带环结构：编译为嵌套 region（loop/for 结构节点
含子区域，RVSDG 式层次无环图）。执行器按迭代周期调度：每个周期内循环体子 region
按拓扑序执行；周期结束回到 region 头部触发下一轮迭代。循环不变量和变体标注于
region 边界，供验证工具证明终止性和循环正确性（终止性依赖经 state edge 显式表达）。
```

`docs/execution-model.md` 2.2 段（"图包含反馈边。执行器按迭代节奏执行。"）改为：

```markdown
### 2.2 静态循环图：有节奏的循环调度

```core
fn main() {
    data := [1, 2, 3, 4, 5];
    loop {
        if data.is_empty() { break; }
        item := data.pop();
        println(item);
    }
}
```

图包含循环 region（loop/for 结构节点，含子区域；region 边界表达迭代与终止依赖）。
执行器按迭代节奏执行。仍然可串行模拟，可单步跟踪循环迭代。
```

`docs/ir-schema/coreir-schema.md`：
- 文件头版本描述处加："v2（2026-08）：追加 SG region 段（sg_count × 48B：kind/enter/exit/parent/nstart/ncount）与 DFEdge kind 字段（0=data, 1=state），版本号 5；v4 文件兼容加载"
- 布局图加 SG 段一行；DFEdge 表加 kind 行

`CLAUDE.md` 架构段 dataflow.cr 行改为：

```
├── dataflow.cr     → 数据流图构建：DFNode/DFEdge（含 state edges）+ 嵌套 region（SG_IF/LOOP/FOR/FLOW/UNSAFE）+ g_df_node_region 显式映射 + DOT
```

- [ ] **Step 6: 提交**

```bash
jj commit -m "feat: RegionCheck via explicit node→region mapping + docs sync (region semantics)"
```

---

## Self-Review（执行前自查）

- **规格覆盖**：P1（SG_IF+映射+DOT）→ Task 1/2；P2（region 迭代）→ Task 3；P3（state edges）→ Task 4；P4（序列化 v2）→ Task 5；P5（RegionCheck+回归+文档）→ Task 6。规格第 11 节文档同步 → Task 6 Step 5 
- **类型一致**：`g_df_node_region`/`g_cur_sg`/`g_loop_region_*`/`OFF_DFE_KIND`/`SG_IF` 在各 Task 定义处与使用处一致 
- **全局约束**：所有长任务命令带 `nice -n 19`；提交用 `jj` 
- **已知不确定点**：Task 3 复现测试若与预期失败模式不符，以实际输出为准修正（步骤已注明）；Task 5 的 v4 存档文件若无现成产物则跳过兼容测试并在提交注明
