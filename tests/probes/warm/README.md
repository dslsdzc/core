# 暖态探针语料（#2026-09-15-5 批 T3：判据网「暖态判据」的载体）

**来源**：#2026-09-15-5 批 T1 的定路径探针矩阵（`/tmp/fct4/task1-report.md` §3.3，2026-09-15 实跑实拷入仓）。
**性质**：**不是**编译器编译单元（不被 `tests/suite/`、`src/ci/run.sh`、`tools/baseline/probes_run.sh`
的任何清单收集——那些都是非递归 glob）——它们是 `tools/baseline/warm_run.sh`（= `warm_leg.sh
--with-corpus`）与 `tests/selfhost/test_warm_cache_gate.py` 的**两态断言输入**。

## 设计要点：**定路径**

缓存键 = `源路径::函数名`，指纹 = 纯 AST。把语料拷到唯一 temp 路径（既有套件的普遍写法）
⇒ 键唯一 ⇒ **结构性无暖态** ⇒ 判据恒绿而空洞（T1 方法学发现；突变 M3 实证：缺陷在场时
唯一路径版判据 `FAIL=0` + 「暖态生效档数 = 0」）。故本语料**必须按入仓路径就地编译**，
两次编译（冷 = `clean-cache` 后首跑；暖 = 紧接二跑）用**同一路径**。

## 清点（**7 档**，只增不减；改动须同步 `tools/baseline/warm_leg.sh` 的 `WARM_TOTAL` 与本表）

| # | 文件 | 形态 | 判据（冷 → 暖） | 出处 |
|---|---|---|---|---|
| 1 | `tu03_load.cr` | 外部指针解引用（读）：`p := 4096 as *int; return *p;` | **rc=1 + `TU03` → rc=1 + `TU03`**（暖 rc=0 = **缺陷回归**） | T1 §3.3 / `test_pointer_safety.py:131-138` 形态 |
| 2 | `tu03_store.cr` | 同（写）：`*p = 1;` | 同上 | T1 §3.3 |
| 3 | `tk01_oob_load.cr` | 指针越界（读）：`&arr[0] + 1` | rc=1 + `TK01` → rc=1 + `TK01` | T1 §3.3 |
| 4 | `tk01_oob_store.cr` | 指针越界（写） | 同上 | T1 §3.3 |
| 5 | `tk01_width.cr` | 宽度跨界：`(&arr[1]) as *[int; 2]` | 同上 | T1 §3.3 |
| 6 | `plain.cr` | **正控**（普通程序） | rc=0 → rc=0 ∧ **`plain.cr::main.cir` 条目存在 ∧ 二跑真命中**（防判据恒绿空洞） | T2 正控 |
| 7 | `alloc_witness.cr` | **见证面**（数组字面量 + 取址 ⇒ ir_gen 期分配复合行） | rc=0 → rc=0 ∧ **自档 `main` 无条目**（#2026-09-15-5 T2 见证规则） | T2 §3.2 |

**旁面对照的意义**：`tk01_*` 三档走 `g_pts`/辅码宽度（**每次构建重算**），不依赖 ir_gen 期类型行
⇒ 暖态**本就不该**变脸；它们的绿 = 缺陷面被精确锁定在「读生成期类型行」的判定（T1 E1 旁证）。

## 用法

```bash
bash tools/baseline/warm_run.sh ./build/corec /tmp/warm_now     # 当前二进制（牙齿层）
bash tools/baseline/warm_run.sh /tmp/<pre-fix>/corec /tmp/warm_before   # pre-fix ⇒ **必红**（腿有牙）
```

**判读**：`WARM LEG DONE（…）：7 档 · **暖态生效（≥1 真命中）档数 = N** · FAIL=M`
—— `FAIL>0` = 冷/暖分歧（缺陷回归）或期望值不命中；**`暖态生效档数 = 0` = 空洞警报**
（判据绿但根本没走到暖态，例如路径不固定/缓存被关），二者都不可接受。

## 与既有 runner 的关系（#2026-09-15-5 T3 落位）

- `tools/baseline/warm_leg.sh`：判据本体（两层：广度层 = 父 runner 传入清单；牙齿层 = 本语料）。
- `tools/baseline/warm_run.sh`：牙齿层专用入口（= `--with-corpus`）。
- `parity_run.sh` / `probes_run.sh`：各加**广度层**调用（同一清单单一依据 `<outdir>/corpus.tsv`）；
  其 `logs/` 产物**格式不变**（历史对拍可比性保持），暖态结果落 `<outdir>/warm/`。
