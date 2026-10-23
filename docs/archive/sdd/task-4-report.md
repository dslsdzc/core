# Task 4 报告：全局初始化修复（定长数组全局 SIGSEGV + 不报错地丢初始化）

状态：DONE_WITH_CONCERNS（判据全绿；brief 之外发现并修复同面 3 处根因，逐条列于 第6）

提交：`tmqyzzlorpyp` / commit `71cb6278`（jj，路径限定 4 文件）
判据一行结论：15/15 例 × 双路径全绿；无运行期初始化全局的样本 ELF 逐字节不变（sha256 `95084e7b…d475`，`cmp` = BYTE-IDENTICAL）；27 个 selfhost 套件 + 3 个 bootstrap 套件全绿。

---

## 1. Step 2 红态原始输出（修复前，双路径，八例）

命令：`nice -n 19 python3 tests/selfhost/test_global_init.py`（前接 `corec clean-cache`）

| # | 用例 | interp rc | elf rc | 期望 | 判定 |
|---|------|-----------|--------|------|------|
| 1 | array_global_literal      | -11（SIGSEGV，shell 记 139） | -11 | 9 | FAIL×2 |
| 2 | array_global_no_init      | -11 | -11 | 7 | FAIL×2 |
| 3 | array_global_copy         | -11 | -11 | 9 | FAIL×2 |
| 4 | array_global_unused       | 5 | 5 | 5 | PASS×2 |
| 5 | scalar_mut_global         | 1（不报错地 0 到 0+1） | 6 | 6 | interp FAIL |
| 6 | scalar_const_global       | 5 | 5 | 5 | PASS×2 |
| 7 | array_global_cross_func   | 0 | -11 | 4 | FAIL×2 |
| 8 | array_global_two_refs     | -11 | -11 | 17 | FAIL×2 |

汇总行：`2/8 global-init cases passed (dual path)`（原始输出全文：`/tmp/r1t4_red.txt`）。

与 brief 预期的差异（照实记录）：brief 预期例 7 双路径均 rc=139；实测例 7 的 interp rc=0
（非 139）。原因是 interp 的 callee 内联执行路径（`interp.cr` 的 `op2` 分派）根本不含
`IR_LOAD_INDEX` 等聚合族 opcode，callee 内读全局数组不报错地落 0（例 7 的 `get()` 里 `g[1]`）。
即「139 崩溃」与「不报错地 0」在例 7 上叠加成第二种机制，是独立于全局初始化的第二处根因（第6.2）。

## 2. Step 3 零变化基线（改动前捕获）

```
nice -n 19 ./build/corec clean-cache          # 输出 cleaned .core/cache/cir/
nice -n 19 ./build/corec build tests/suite/ptr_arith.cr --static -o /tmp/r1t4_base_bin
sha256sum /tmp/r1t4_base_bin
95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475  /tmp/r1t4_base_bin
```
样本：`tests/suite/ptr_arith.cr`（240 B，零文件级 let = 零运行期初始化全局；含数组/取址/解引用，覆盖后端）。
基线二进制运行 rc=0。

## 3. 清缓存命令与效果（Step 2 前置交互）

```
nice -n 19 ./build/corec clean-cache   # corec main.cr：system("rm -rf .core/cache/cir/") + 回显
cleaned .core/cache/cir/
```
交互事实（与 brief 注记一致，本批不修 = TODO #5）：运行期初始化的注入点在 `ir_gen_func(main)`
内，而 cir 缓存命中时根本不走 `ir_gen_func`（`main.cr` 的 cache-hit 分支），旧编译器写下的
`main.cir` 会让修复看起来「没生效」。实测复现一次：在 `/tmp/r1t4probe` 下跑的别名探针
（cwd 内自带 `.core/cache/cir/`）首次复跑返回 139，`rm -rf` 该缓存后即 7，见 第7。
判定运行一律先清缓存；测试脚本 `tests/selfhost/test_global_init.py` 自身在开跑前调一次
`clean-cache`（可复现性，不改语义）。

## 4. 重建（Step 6 前置）

```
nice -n 19 python3 build_selfhost_native.py        # rc=0
[GUARD] corec: manifest OK (37 files)
[GUARD] corec: build log clean (error[ = 0, undefined = 0)
[GUARD] corearch: build log clean (error[ = 0, undefined = 0)
[GUARD] corelsp: build log clean (error[ = 0, undefined = 0)
=== BUILD SUCCESS ===
  build/corec    ，frontend:  .cr 到 .ccr/.cir
  build/corearch ，backend:   .ccr 到 binary
  build/corelsp  ，LSP server: frontend + json
```
（Checker warnings 为既有非致命噪声，条目与本次改动无关；`error[` = 0 由守卫机械核验。）

## 5. Step 6 命令输出

```
nice -n 19 python3 tests/selfhost/test_global_init.py
… 15/15 global-init cases passed (dual path)          # 15 例 × interp/elf 全 PASS

nice -n 19 ./build/corec build tests/suite/ptr_arith.cr --static -o /tmp/r1t4_head_bin
sha256sum /tmp/r1t4_base_bin /tmp/r1t4_head_bin
95084e7b…d475  /tmp/r1t4_base_bin
95084e7b…d475  /tmp/r1t4_head_bin
cmp /tmp/r1t4_base_bin /tmp/r1t4_head_bin && echo BYTE-IDENTICAL
BYTE-IDENTICAL
（产物运行 rc=0）

nice -n 19 python3 tests/selfhost/test_compile.py     到 All selfhost compile tests passed.
nice -n 19 python3 tests/bootstrap/test_pipeline.py   到 29/29 passed
```

追加回归（全套 selfhost/bootstrap，全绿）：

```
test_compile / test_apx_tag 2/2 / test_dex_arith 11/11 / test_dex_type 5/5 /
test_interp_float ALL PASS / test_native_memory 6/6 / test_native_strings PASS /
test_native_float ALL PASS / test_slice_bounds 7/7 / test_pointer_safety PASS /
test_impl 7/7 / test_borrow 7/7 / test_directory_build PASS / test_ccr_v7 24/24 /
test_region_cfg 22/22 / test_ent_kernel_neutrality PASS / test_live_ranges 13/13 /
test_lexer_parity PASS / test_backend_bootstrap PASS / test_hit_table 24/24 /
test_lsp 9/9 / test_mw_task1..6 ALL PASS
bootstrap: test_pipeline 29/29 / test_borrow 4/4 / test_generics 3/3
```

额外自审（同面扩展，非判据）：注入的全局在 `-O 0/1/2` 三档均正确（混合程序：
`a : [int;2] = [8,9]; b : [int;2] = a; x : int, mut = 5; s : P = P{20,22};` 到 三档 rc=45）。

## 6. 实现：与 brief 骨架的差异（逐条理由）

### 6.0 最终代码 = brief 骨架 + 下列 4 项修正/扩展

分支/文件与 brief 一致：`src/compiler/ir_gen.cr`（`global_needs_runtime_init` /
`global_var_of` / `inject_global_inits` / `ir_gen_func` main 序言注入）、
`src/compiler/interp.cr`（常量初始化阶段）。新增第 4 个文件：`src/arch/x86_64/instr.cr`
（第6.3，理由见该节）。测试 15 例（brief 8 + 扩展 7，扩展为同一修复面的 pin）。

### 6.1 聚合判据：类型别名解析（brief 判据① 的补全）

brief 判据①：`ast_kind(ast_b(node)) == EXPR_ARRAY`。实测 `type Arr = [int;2]; g : Arr;`
（无初值）仍 rc=139，声明类型节点是 `EXPR_IDENT`（parser.cr `parse_type` 用户类型分支），
判据① 漏检 到 同一「定长数组全局」类里留一半 SIGSEGV。故新增：

```core
// 类型节点 到 `[T; N]` 的元素数 N（`[T]` 切片 = 0）；非聚合 = -1。
// 类型别名解析一层：`type Arr = [int;2]; g : Arr;` 的声明类型节点是 EXPR_IDENT
// （parser.cr parse_type 的用户类型分支），须经 g_type_aliases（{name_idx, type_node}
// 16B/条）回到底层 EXPR_ARRAY，否则同一「定长数组全局」类仍留 SIGSEGV。
fn agg_elem_count_of(tn: int) -> int {
    if tn < 0 { return -1; }
    if ast_kind(tn) == EXPR_ARRAY { return ast_int_val(tn); }
    if ast_kind(tn) == EXPR_IDENT {
        ni := ast_int_val(tn);
        ai : ., mut = 0;
        loop {
            if ai >= g_type_alias_count { break; }
            if r64(g_type_aliases, ai * 16) == ni {
                rt := r64(g_type_aliases, ai * 16 + 8);
                if rt >= 0 && ast_kind(rt) == EXPR_ARRAY { return ast_int_val(rt); }
                break;
            }
            ai = ai + 1;
        }
    }
    return -1;
}
```
`global_needs_runtime_init` 判据① 改为 `if agg_elem_count_of(ast_b(node)) >= 0 { return 1; }`；
`inject_global_inits` 的 N 改取 `cnt := agg_elem_count_of(ast_b(lnode))`。
（brief 骨架的 `if tn >= 0 { cnt = ast_int_val(tn) }` 对别名会取到名字驻留索引当长度，
在别名路径开启后是真 bug，故一并改。）

### 6.2 解释器：callee 内联路径缺聚合族 opcode（第二处根因，brief 未列）

`interp.cr` 的 callee 内联执行循环（`op2` 分派）只覆盖 `1/2/3/5/6/9/10/19/20/32/33/46/47/49/50`，
不含任何聚合 opcode：callee 内读/写全局数组、结构体字段、`&arr[i]` 全部不报错地落 0
（例 7 的 interp rc=0 即此）。本批让聚合全局在 main 序言获得运行期存储（第6.1），callee 侧的
读路径必须同批补齐，否则双路径语义仍分叉。新增（与主循环同语义、同守卫，逐条对照主循环）：

```
op2 == 8  IR_ALLOC_ARRAY      op2 == 13/14/15/16  LOAD|STORE_INDEX(_VAR)
op2 == 31 IR_ADDR_INDEX       op2 == 11/12        LOAD|STORE_FIELD
op2 == 7  IR_ALLOC_STRUCT
```

### 6.3 ELF 后端：字段访问的全局基址（第三处根因，brief 未列 到 新增第 4 个改动文件）

触发路径（本批自身变更面）：判据② 让「结构体型全局 + 字面量初值」（`g : P = P{…}`）也获得
运行期初始化（初值节点非 int/bool/dex）。此时 `IR_LOAD_FIELD`/`IR_STORE_FIELD` 在 ELF 侧用
`g2_slot(s1) + e2_ld`：全局行落在本函数帧之外，`g2_slot` 返回正的伪 rbp 偏移 到 读栈垃圾。
实测：注入前 rc=139（空槽解引用），注入后变成不报错地错值（`g.x` 返回 84、`g.y` 返回 112，
期望 30/12），从崩溃变错值属于倒退，不能留。修法 = 与 `IR_LOAD_INDEX`/`IR_ADDR_INDEX`
既有的「handles local and global」同规约，改走 `e2_load_var`（局部字节不变、全局走 RIP 相对 lea）：

```core
    if op == IR_LOAD_FIELD && d >= 0 {
        do2 := g2_slot(d); fi2 := s3;
        fo : ., mut = fi2 * 8;
        cp = cp + e2_load_var(buf, pos+cp, 10, s1);      // ← 原 e2_ld(…, g2_slot(s1))
        …
    if op == IR_STORE_FIELD {
        fi2 := s3;
        fo : ., mut = fi2 * 8;
        cp = cp + e2_load_var(buf, pos+cp, 10, s1); cp = cp + e2_load_var(buf, pos+cp, 11, s2);
```
局部基址分支字节与改前恒等（`e2_load_var` 的非全局回退就是 `e2_ld(g2_slot(v))`）到 零变化判据不受影响。
表模式（`--table`）不在判据面：表投影对全局行本就回退旧路径（`hit_ev_slot_addr_ok` 显式排除全局），
本次改动落在该回退路径上。

### 6.4 解释器：callee 返回值暂存槽覆写首个全局（第四处根因，brief 未列）

callee 内联路径用 `g_ir_vals[0]` 传返回值（`w64(g_ir_vals, 0, …)` / `rval := r64(g_ir_vals, 0*8)`）。
槽 0 就是第一个 IR 变量，而文件级全局按序注册在最前（`ir_gen_globals` 先于 `ir_gen_func`）
到 每次 callee 返回都不报错地覆写第一个全局。实测：`struct P{…}; g : P = P{…}; fn set()->int{ g.y = 40; return 0; }`
的 interp 返回 0（ELF 返回 40），正是 `set()` 的 `return 0` 把 `g` 的槽写成 0。
修法（`interp.cr ir_interpret`）：

```core
    ret_slot := g_ir_var_count;   // 清零区 need 内的首个填充槽，不与任何真变量重叠
    …
    w64(g_ir_vals, ret_slot * 8, 0);                              // 调用前清零（无值返回 到 0）
    … if t1 >= 0 { w64(g_ir_vals, ret_slot * 8, r64(g_ir_vals, t1 * 8)); }   // callee IR_RETURN
    … rval := r64(g_ir_vals, ret_slot * 8);
```

### 6.5 注入点位置（微调）

brief：`ir_gen_func` 内 `emit(IR_ARENA_NEW, …)` 之后、`gen_expr(body)` 之前。最终放在
`g_cur_ret_ti = ret_ti;` 之后、`gen_expr(body)` 之前（仍在 IR_ARENA_NEW 之后），
注入期调用 `gen_expr` 时返回类型上下文已就位，与函数体生成同状态，无行为差异、只为稳健。

### 6.6 未注入（按 brief 保留）

`[T]`（切片，N=0）/别名到切片：不注入，保持 BSS 零 = 空切片/哑指针（空切片解引用 = 独立
null 陷阱类，不在本批）。实测 `g : [int];` 程序 rc=5 两路径一致（无新崩溃面）。

## 7. 复现陷阱（供后续判据运行参考）

1. 缓存：不改编译器身份、跨重建不失效（TODO #5）。除 `clean-cache` 外，任何在别处 cwd 跑的
   探针会自带 `.core/cache/cir/`；本次实测一次「别名修复看起来没生效」（139）即该缓存所致，
   清后即正确（`alias2` 7）。
2. cwd：`corec` 的 import 解析相对 cwd/源目录。在 `/tmp` 下跑探针会 `!! import fail: str_len`
   到 程序带诊断且 ELF 崩溃（139），是探针环境假象而非编译器缺陷；判据脚本一律 cwd=仓库根。
3. fish 下重定向已存在文件需 `>|`（`>` 报「文件已存在」并不报错地用旧产物）。

## 8. 提交

```
jj commit src/compiler/ir_gen.cr src/compiler/interp.cr src/arch/x86_64/instr.cr \
          tests/selfhost/test_global_init.py -m '<fix: …>'
```
提交哈希：change `tmqyzzlorpyp` / commit `71cb6278`（`jj diff --stat -r @-`：4 files changed, 401 insertions(+), 6 deletions(-)；
报告文件 `docs/archive/sdd/task-4-report.md` 因 `.gitignore` 的 `.superpowers/` 不入版本。）

## 9. 交付物

- `src/compiler/ir_gen.cr`：`agg_elem_count_of` / `global_needs_runtime_init` / `global_var_of` /
  `inject_global_inits` + main 序言注入点（第6.1、第6.5）
- `src/compiler/interp.cr`：标量常量初始化阶段；callee 聚合族 opcode；返回值暂存槽
  （第6.2、第6.4；常量阶段 = Step 5）
- `src/arch/x86_64/instr.cr`：字段访问全局基址（第6.3）
- `tests/selfhost/test_global_init.py`：15 例双路径（brief 8 + 扩展 7），每例断言
  「无 `error[`」+「rc 精确值」，开跑前清 cir 缓存
