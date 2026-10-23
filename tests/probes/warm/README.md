# 有缓存状态探针语料（#2026-09-15-5 批 T3：检查集合有缓存状态分支的实现方式）

来源：#2026-09-15-5 批 T1 的固定路径探针矩阵（`/tmp/fct4/task1-report.md` 3.3 节，2026-09-15 实际运行并实拷入仓）。
性质：不是编译器编译单元（不被 `tests/suite/`、`src/ci/run.sh`、`tools/baseline/probes_run.sh`
的任何清单收集，那些都是非递归 glob）。它们是 `tools/baseline/warm_run.sh`（= `warm_leg.sh
--with-corpus`）与 `tests/selfhost/test_warm_cache_gate.py` 的两态断言输入。

## 设计要点：固定路径

缓存键 = `源路径::函数名`，指纹 = 纯 AST。把语料复制到唯一 temp 路径（既有套件的普遍写法）
会得到唯一键，从结构上不会产生有缓存状态，检查恒通过但没有实际覆盖（T1 方法学发现；突变 M3 证实：缺陷在场时
唯一路径版检查 `FAIL=0`，有缓存状态生效档数 = 0）。所以本语料必须按入仓路径就地编译，
两次编译（空缓存状态 = `clean-cache` 后第一次运行；有缓存状态 = 紧接的第二次运行）使用同一路径。

## 清点（7 档，只增不减；改动须同步 `tools/baseline/warm_leg.sh` 的 `WARM_TOTAL` 与本表）

| # | 文件 | 形态 | 检查（空缓存状态到有缓存状态） | 出处 |
|---|---|---|---|---|
| 1 | `tu03_load.cr` | 外部指针解引用（读）：`p := 4096 as *int; return *p;` | 冷 rc=1 + `TU03`；暖 rc=1 + `TU03`（有缓存状态 rc=0 即缺陷回归） | T1 3.3 节 / `test_pointer_safety.py:131-138` 形态 |
| 2 | `tu03_store.cr` | 同（写）：`*p = 1;` | 同上 | T1 3.3 节 |
| 3 | `tk01_oob_load.cr` | 指针越界（读）：`&arr[0] + 1` | 冷 rc=1 + `TK01`；暖 rc=1 + `TK01` | T1 3.3 节 |
| 4 | `tk01_oob_store.cr` | 指针越界（写） | 同上 | T1 3.3 节 |
| 5 | `tk01_width.cr` | 宽度跨界：`(&arr[1]) as *[int; 2]` | 同上 | T1 3.3 节 |
| 6 | `plain.cr` | 正控（普通程序） | 冷 rc=0；暖 rc=0，且 `plain.cr::main.cir` 条目存在、第二次运行真正命中（防止检查恒通过且没有覆盖） | T2 正控 |
| 7 | `alloc_witness.cr` | 见证面（数组字面量 + 取址，所以在 ir_gen 期分配复合行） | 冷 rc=0；暖 rc=0，且本档 `main` 无条目（#2026-09-15-5 T2 见证规则） | T2 3.2 节 |

旁面对照的意义：`tk01_*` 三档走 `g_pts`/辅码宽度（每次构建重算），不依赖 ir_gen 期类型行，
所以有缓存状态本不应变化；这三档通过，说明缺陷面被精确限定在“读生成期类型行”的判定（T1 E1 旁证）。

## 用法

```bash
bash tools/baseline/warm_run.sh ./build/corec /tmp/warm_now     # 当前二进制（定点层）
bash tools/baseline/warm_run.sh /tmp/<pre-fix>/corec /tmp/warm_before   # pre-fix 时必然失败（说明判据能检出缺陷）
```

判读：`WARM LEG DONE（…）：7 档 · 有缓存状态生效（≥1 真命中）档数 = N · FAIL=M`。
`FAIL>0` 表示空缓存状态和有缓存状态不一致（缺陷回归）或期望值不命中；`有缓存状态生效档数 = 0` 表示覆盖为空警报
（检查通过但没有进入有缓存状态，例如路径不固定或缓存被关闭）。两者都不可接受。

## 与既有 runner 的关系（#2026-09-15-5 T3 落位）

- `tools/baseline/warm_leg.sh`：检查本体（两层：广度层 = 父 runner 传入清单；定点层 = 本语料）。
- `tools/baseline/warm_run.sh`：定点层专用入口（= `--with-corpus`）。
- `parity_run.sh` / `probes_run.sh`：各加广度层调用（同一清单单一依据 `<outdir>/corpus.tsv`）；
  其 `logs/` 产物格式不变（历史对拍可比性保持），有缓存状态结果写入 `<outdir>/warm/`。
