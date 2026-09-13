# 冻结基线：重建配方 + sha 白名单（R2 P6 Task 1 / 交接包 E-13）

## 这是什么

「**冻结基线**」= 判定面回归网**腿 ①（冻结基线同源对拍）** 里的那个「pre-批」编译器二进制：
拿它乘**当前源**，与**当前二进制**乘**当前源**逐档比（72 档 `check` 的 rc + 日志），
差异 = 该批对判定面的**行为变更**（预期内 = 收紧/放宽，须逐条入台账；预期外 = 回归）。

**二进制不入库**（维护者裁定，2026-09-13）——入库的是**配方 + sha 白名单**：
任何人可一条命令重建出**逐字节相同**的三二进制。

## 配方（唯一被许可的产生方式）

```bash
bash tools/baseline/rebuild.sh /tmp/p6-baseline      # 产物：/tmp/p6-baseline/{corec,corearch,corelsp}
```

脚本做的三件事（等价手工命令，见脚本头注）：

1. `jj workspace add <tmpdir> --name p6-baseline-build --revision <PINNED_REV>`（**仓库工作树之外**检出；
   收工 `jj workspace forget` + 删 tmp 目录）
2. `nice -n 19 python3 build_selfhost_native.py`（在检出根内）
3. `sha256sum` 对**白名单**（不符 ⇒ **失败退出**）+ 拷到 outdir + 冒烟（`corec run 'fn main()->int{return 42;}'` ⇒ rc=42）

前置：`jj` 可用、工作树不处于多 agent 并发构建窗口（本仓纪律：一构建一编译串行）。
`COREC_REPO_ROOT=<path>` 可覆盖仓库根（脚本默认从自身位置 `../..` 推导）。

## sha 白名单（**现行代**）

| 二进制 | sha256 | 源修订 |
|---|---|---|
| `corec` | `ae01de7534ea8428e3e062fccbc5fef5d45abfc5d3dafb90b3c85e08f354cce2` | `97f4394f`（R2 P6 终态 / P6 Task 6 收官） |
| `corearch` | `228f82e948cfaf8170ada982d80f1ebddfd3847e71cdf04ca4b42d9226373d2e` | 同上 |
| `corelsp` | `90eb19c6d3bd4e3234b4328d8b8f3284cca6d1644d3959bb83f07b7e71473032` | 同上 |

> `PINNED_REV` = `97f4394f`（**P6 终态**）——容量批（CAP：E-2 表示面聚合 / E-3 `MAX_*` 解除 /
> E-4 收回可选程序 `.cir` 缓存）的「pre-批」侧。换代自证：重跑本配方 ⇒ 三 sha = 上表 +
> 冒烟 42 + 确定性 ×2（rebuilt 两次逐字节同）；且 `jj diff --from 97f4394f --to <本批起点树>`
> 证明其后仅有计划文档新增（无构建输入变化）⇒ 与直接构建产物同 sha。

## 白名单历史（**旧值不删**——换代纪律 2；本表 = 历次换代台账）

| 代 | 源修订 | `corec` | `corearch` | `corelsp` | 理由 / 出处 |
|---|---|---|---|---|---|
| 初代 | `9bcb7083`（R2 P4 收官 / P4 Task 7） | `5d2b15ad746018619b01143cce400e6f3489ae72a962e12283a7afd3dcdb41e7` | `493dc490dfaed7774b46b74ccf1cfeca9fe5f61620e34229afb8991b1628a2a7` | `18b94bd955fa204accf0753095a28f6499871566254d846333a7496c99109d49` | P5 批的 pre-侧（P6 T0 §1.4：与本配方产物逐字节 IDENTICAL ×3，白名单自洽） |
| **2 代（现行）** | `97f4394f`（R2 P6 终态） | `ae01de75…`（全值见上表） | `228f82e9…`（全值见上表） | `90eb19c6…`（全值见上表） | 容量批 CAP 的 pre-侧；换代依据 = 换代纪律 1（下一批以本批收官为 pre-侧）；自证见「现行代」注与 `cap-task1-report.md` |

## 用法

**批内（腿 ① 主判据）**：

```bash
bash tools/baseline/parity_run.sh /tmp/p6-baseline/corec /tmp/parity_frozen   # 冻结基线 × 当前源
bash tools/baseline/parity_run.sh ./build/corec           /tmp/parity_post     # 当前二进制 × 当前源
diff -rq /tmp/parity_frozen/logs /tmp/parity_post/logs                        # 逐档 rc + 日志 diff
```

**核对 runner 保真**（一次性 / 换代时）：同一二进制分别跑入仓 runner 与迁移期
`/tmp/p3t0_run.sh check`，两者 `logs/` 须 `diff -rq` 空。

**行为探针（腿 ②）**：`bash tools/baseline/probes_run.sh <corec> <outdir>`（语料 = `tests/probes/`，29 档；
`rc=1` 多为**预期负例**，判据是两态零差异而非全 0 —— 见 `tests/probes/README.md`）。

## 换代纪律（**只在此处更新白名单**）

1. 白名单换代 = 「基线世代」变更（例如尾批收官后，下一批以本批收官为 pre-侧）。
   **不得**因为重建 sha 不符就改白名单对齐——那正是本配方要抓的「构建不可复现」。
2. 换代须**同批**记录：旧三 sha（含其源修订）+ 新源修订 + 理由 + 出处提交；旧值不删（台账留痕）。
3. 换代后重跑一次**对拍自证**（新基线 × 当前源 vs 当前二进制 × 当前源）并把结果记入该批报告。

## 已知限制（不静默）

- **CI 内不跑**：`.github/workflows/core-ci.yml` 用 `actions/checkout` + `fetch-depth: 2`（浅检出，
  无 `jj`）⇒ pinned revision 在 CI 环境**不可得**。本腿为**手工判据**（每任务/每批收尾跑），
  故入仓的是**可复现性**而非 CI 挂钩（R2 P6 Task 1 §Step 4 评估结论）。
- **72 档语料的既有 rc=1 不是回归**：0 字节 fixture ×2 / P21 嵌套 fn 负例 ×2 / examples 解析错 ×2 /
  库单元单独 check（N01/N06/N11）×25 / TF01 并发族 ×5 / TF07 ×1 / B04 借用 ×1 —— 划界见
  `p6-task0-report.md` §3.1（跑之前先读，勿把既有失败当回归）。
- **`examples/` 不在任何 CI job 的覆盖面内**（`suite` job 只跑 `tests/suite`）——但本对拍面含之
  （4 档），故对拍是 examples 的**唯一**行为证据来源。
- **`.ccr`/`.cir` 缓存态**：比较任何产物前 `clean-cache`（runner 已逐档做）；`.ccr` 记录值引用须带
  命令口径 + 缓存态（TODO #26 / P4 附录 D-1）。
