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

**暖态腿（腿 ③，#60 T3）**：`tools/baseline/warm_leg.sh` —— 逐档「**同路径二跑**」× `ccr` 面
（冷 = `clean-cache` 后首跑；暖 = 紧接二跑），断言 rc + 诊断码集一致，并报「**暖态生效
（≥1 真命中）档数**」（0 = 空洞警报：腿绿但没走到暖态）。两层：

```bash
bash tools/baseline/warm_run.sh ./build/corec /tmp/warm_now   # 牙齿层（语料 tests/probes/warm/，7 档，期望值断言）
```

- **广度层**：`parity_run.sh` / `probes_run.sh` 默认附带（清单单一真源 = `<outdir>/corpus.tsv`；
  结果落 `<outdir>/warm/`，**`logs/` 格式不变** ⇒ 历史对拍可比性保持）。`WARM_LEG=0` 关闭。
  对 **pre-fix 冻结基线预期绿**（既有 72/29 语料不含 `as *T` 形态；实测 M1 二进制 72 档 FAIL=0）。
- **牙齿层**：`tests/probes/warm/`（**定路径**是该语料的设计要点；拷到唯一 temp 路径 ⇒ 腿恒绿而
  空洞 —— 突变 M3 实证）。**pre-fix 二进制在本层必红**（缺陷本体）⇒ 对**冻结基线**调用
  `warm_run.sh` 时预期 rc=1，**不是**基线不合规（判据 = 突变 M1，见 `warm-task3-report.md`）。
- 时长实测（2026-09-15，本机）：牙齿层 **0.9s** · probes 广度层 **+3.5s** · parity 广度层
  **+125s**（72 档 ×2 次 `ccr`，大文件为主）⇒ **CI 只挂最小面**（`tests/selfhost/test_warm_cache_gate.py`，0.5s），
  广度层留手工判据。
- **腿本体不进 CI**（维护者裁定 2026-09-15）：与套件**同语料**、覆盖重叠，收益仅「校验 runner 自身」。
- **口径限制（W3 批实测登记，2026-09-15）**：本腿现比对 = **rc + 诊断码集 + 产物 sha**（`ccr`/ELF/DOT 三面），
  **不覆盖 DOT label / 日志文本**——实测存在「暖态名字面」分歧（`ir_gen` 期合成名字串在暖态缺席 ⇒
  DOT 变量名标签掉前缀；**非静默面、不传导产物**，见 TODO #65）。**若将来要把名字面纳入腿**，须扩比对口径
  （例如 DOT 逐行 diff 或 name 面专用通道）——**本批不实施**。
- **口径限制（跨二进制暖态腿，2026-09-16 (A) 批登记）**：暖态腿现比对 = **rc + 诊断码集 + 产物 sha**，
  **不覆盖日志文本**——**跨二进制**比日志会把 frozen 侧 `lower to ccr…` 与当前侧（FC 批硬闸 `main.cr:616-621`
  早停：负例探针不再进入 lowering）的**打印差异**误报成分歧（(A) 批实测：同一档 rc/产物全同，仅日志行不同）。
  ⇒ 暖态腿判据口径 = **冷态逐档 + 暖态自洽（FAIL=0）**；**不按跨二进制日志文本判红**。与上条（#65：不覆盖
  DOT label / 日志文本）**同一条口径限制**，本条只补「跨二进制」这一维（**不另立条目**）。
- **何时该跑（手工判据纪律）**——下列任一情形**必跑** `warm_run.sh`（0.9s）**加**至少一次
  parity 广度层（`parity_run.sh` 默认已含）：① 改动 `tools/baseline/*` runner 本体；
  ② 改动缓存面（`src/compiler/cir_cache.cr` · `ccr_io.cr` 的保存/装载路径 · `main.cr` 的缓存门/
  见证规则 · `CIR_CACHE_VER`）；③ 关闭、降级或重定向 `.core/cache`（含 `clean-cache` 语义变更）；
  ④ 新增/改动 `tests/probes/warm/` 语料（须同步 `warm_leg.sh` 的 `WARM_TOTAL` 与语料 README）。
  日常 CI 已由最小面覆盖语料本身，**不**替代上述腿。

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
- **`.ccr` 记录值还依赖 `$HOME` 内容（2026-09-16 判据载体化批 CI 红档实锤）**：编译器解析 `import`
  时会读 `$HOME/.core/lib/<模块>/index` 并把这些名字驻留进 `.ccr`（`src/compiler/module.cr:523-530`）
  ⇒ **同一提交、同一编译器，换台机器产物就变**（`tests/suite/generics_test.cr` 在本机
  `~/.core/lib/io/index` 在场时 142793B、在 CI 上 142765B）。**判据的效力范围**：`tools/baseline/`
  的 `.ccr` 记录值**自本批起**锁定「环境归一化（受控空 `HOME`）下的产物」——载体
  `canary_check.sh` 已把 `HOME` 钉到采集目录内的空 `home/`；**手工复跑时也须同样归一化**，
  否则会得到本机态的假红（**不得** unset/置空 `HOME`：`module.cr:526` 有硬编码 `/home/DslsDZC`
  兜底，置空反会去读原开发者家目录）。根因已独立登记（TODO #79/#82，与「缓存键缺编译器身份」同族）。
  注：本条的**两档语料**中 `ptr_arith` 零 import ⇒ 不受影响；受影响的只有 `generics_test`（两口径）。
