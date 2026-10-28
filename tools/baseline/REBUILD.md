# 固定基线：重建方法 + sha 允许清单（R2 P6 Task 1 / 交接包 E-13）

## 定义

固定基线是判定面回归检查分支 1（固定基线同源对拍）使用的 pre-阶段编译器二进制。
用它编译当前源，与用当前二进制编译当前源的结果逐档比较（89 档 `check` 的 rc 和日志；档数按实际枚举读取：
`tests/suite/*.cr` 34 + `src/compiler/{main,_import}.cr` 2 + 后端/内核单元 26 + `src/stdlib/*.cr` 23 +
`examples/*.cr` 4 = 89，与 `parity_run.sh` 的 `CORPUS_TOTAL=89` 硬性断言一致。
2026-09-24 的规则为 76 档（t1=36、t3=15）。v4 迁移删除了 2 档空 fixture，并把架构轴、OS 轴、
target 轴的文件纳入 t3，所以 2026-10-25 起改为 85 档。2026-10-27 起改为 89 档：stdlib 公开面阶段
新增 `bits.cr` / `hash.cr` / `hashmap.cr` / `rawbuf.cr`（t4 19 → 23）；本行与 runner 同阶段同步。）
差异即该阶段对判定面的行为变更（预期内为收紧或放宽，须逐条列入清单；预期外为回归）。

二进制不入库（维护者裁定，2026-09-13）。入库的是方法和 sha 允许清单：
任何人可用一条命令重建出逐字节相同的三个二进制。

## 方法（唯一被许可的产生方式）

```bash
bash tools/baseline/rebuild.sh /tmp/p6-baseline      # 产物：/tmp/p6-baseline/{corec,corearch,corelsp}
```

脚本做三件事（等价手工命令见脚本头注）：

1. `jj workspace add <tmpdir> --name p6-baseline-build --revision <PINNED_REV>`（在仓库工作树之外检出；
   结束后执行 `jj workspace forget` 并删除 tmp 目录）
2. `nice -n 19 python3 build_selfhost_native.py`（在检出根目录内执行）
3. `sha256sum` 对照允许清单（不符则失败退出）+ 复制到 outdir + 快速验证（`corec run 'fn main()->int{return 42;}'` 返回 rc=42）

前置条件：`jj` 可用、工作树不处于多 agent 并发构建窗口（本仓规则：一次只运行一个构建或编译）。
`COREC_REPO_ROOT=<path>` 可覆盖仓库根（脚本默认从自身位置 `../..` 推导）。

## sha 允许清单（现行代）

| 二进制 | sha256 | 源修订 |
|---|---|---|
| `corec` | `5fe3de891380c5909e6f5cefccac53781acbe1eccf4540f568988290467a6726` | `28483a42`（语言面与 AST span 批 #222 合入 develop） |
| `corearch` | `e8b3e30b116c09200dfb9b2d023b0c1608f4f917e89b3f7dabf74ee6e295c542` | 同上 |
| `corelsp` | `db51fdc7c420396152f363385174a96fed770af951339482cbb42376b62908e2` | 同上 |

> `PINNED_REV` = `28483a42`（语言面与 AST span 批 #222 合入 develop 的提交）。2026-10-28 换代：
> 旧代 `7eb9669d` 早于 develop 的库可见性批，固定基线无法编译当前源，因此把 `PINNED_REV`
> 重指到合入后的提交并同阶段重锁三个 sha。旧代的记录：
> `7eb9669d` 是首个 develop 历史内可达的 v4 基线。2026-10-11 曾固定到 `25e70197`，但那枚提交只存在于本地 jj 提交图；#183 以 squash
> 合入 develop 后，换人或换机无法检出该修订。2026-10-25 T7 收尾把 `PINNED_REV` 重指到
> `7eb9669d`，并同阶段重锁三个 sha。
> 换代自证（2026-10-28 实际运行）：从 `28483a42` 重建，三个 sha 与上表相同；快速验证返回 42；
> `parity_run.sh` 实测 89 档。上一代 `7eb9669d` 的自证（2026-10-25）：三个 sha 相同、快速验证 42、
> parity 85 档，rc 分布 `49×0 / 36×1`。

## 允许清单历史（旧值不删，换代纪律 2；本表 = 历次换代清单）

| 代 | 源修订 | `corec` | `corearch` | `corelsp` | 理由 / 出处 |
|---|---|---|---|---|---|
| 初代 | `9bcb7083`（R2 P4 完成 / P4 Task 7） | `5d2b15ad746018619b01143cce400e6f3489ae72a962e12283a7afd3dcdb41e7` | `493dc490dfaed7774b46b74ccf1cfeca9fe5f61620e34229afb8991b1628a2a7` | `18b94bd955fa204accf0753095a28f6499871566254d846333a7496c99109d49` | P5 阶段的 pre-侧（P6 T0 1.4 节：与本方法产物逐字节 IDENTICAL ×3，允许清单自洽） |
| 2 代 | `97f4394f`（R2 P6 终态） | `ae01de75…`（全值见本行原值注） | `228f82e9…` | `90eb19c6…` | 容量阶段 CAP 的 pre-侧；换代依据 = 换代纪律 1（下一组以本次完成为 pre-侧）；自证见 `cap-task1-report.md`。2026-10-11（T7）换代后降为历史代。旧全值保留记录：corec `ae01de7534ea8428e3e062fccbc5fef5d45abfc5d3dafb90b3c85e08f354cce2` · corearch `228f82e948cfaf8170ada982d80f1ebddfd3847e71cdf04ca4b42d9226373d2e` · corelsp `90eb19c6d3bd4e3234b4328d8b8f3284cca6d1644d3959bb83f07b7e71473032` |
| 3 代 | `25e70197`（v4 迁移 T6 完成） | `701a319f52696e9b098eac03b0e85ecbd6514e8d2ad05c9c30f662f62e402cdc` | `bd6b1c6af5e64d20eca120e3188f05d02ee4a6f6de510516b19d47861f522e30` | `2c1da86fc5c0044fb059d8d759a20a6167be18645eea43101948594949703661` | v4 基线：首个可读 v4 形式的 pre-侧；换代依据 = v4 可读性硬约束（见“现行代”注）。自证（2026-10-11 实际运行）= 重建三个 sha 与上表相同 + 快速验证 42 + 与工作树自建二进制逐字节相同。2026-10-25 降为历史代（该修订不在 develop 历史内） |
| 4 代 | `7eb9669d`（v4 迁移 #183 合入 develop） | `4234b7a6…`（全值见上表） | `3786eb4a…`（全值见上表） | `845ac048…`（全值见上表） | v4 计划 T7 收尾：`25e70197` 不进入 develop 历史（#183 为 squash 合入），把 `PINNED_REV` 重指到 develop 可达的 v4 提交，并同阶段重锁三个 sha。自证（2026-10-25）= 三个 sha 与上表相同 + 快速验证 42 + parity 85 档（`49×0 / 36×1`） |

| 5 代（现行） | `28483a42`（语言面与 AST span 批 #222 合入 develop） | `5fe3de89…`（全值见上表） | `e8b3e30b…`（全值见上表） | `db51fdc7…`（全值见上表） | #222 合入后换代：`cast`、`Self`、receiver 规则、64 字节 AST 节点与行表删除。自证（2026-10-28）= 三个 sha 与上表相同 + 快速验证 42 + parity 89 档 |

## 用法

阶段内（分支 1 主要检查）：

```bash
bash tools/baseline/parity_run.sh /tmp/p6-baseline/corec /tmp/parity_frozen   # 冻结基线 × 当前源
bash tools/baseline/parity_run.sh ./build/corec           /tmp/parity_post     # 当前二进制 × 当前源
diff -rq /tmp/parity_frozen/logs /tmp/parity_post/logs                        # 逐档 rc + 日志 diff
```

核对 runner 保真（一次性或换代时）：同一二进制分别运行入仓 runner 与迁移期
`/tmp/p3t0_run.sh check`，两者的 `logs/` 须 `diff -rq` 为空。

行为探针（分支 2）：`bash tools/baseline/probes_run.sh <corec> <outdir>`（语料 = `tests/probes/`，29 档；
`rc=1` 多为预期负例，检查是两态零差异而非全 0，见 `tests/probes/README.md`）。

有缓存状态分支（分支 3，#2026-09-15-5 T3）：`tools/baseline/warm_leg.sh` 逐档在同一路径运行两次 × `ccr` 面
（空缓存状态 = `clean-cache` 后第一次运行；有缓存状态 = 紧接的第二次运行），断言 rc + 诊断码集一致，并报告“有缓存状态生效
（≥1 真命中）档数”（0 = 覆盖为空警报：检查通过但没有进入有缓存状态）。两层：

```bash
bash tools/baseline/warm_run.sh ./build/corec /tmp/warm_now   # 定点层（语料 tests/probes/warm/，7 档，期望值断言）
```

- 广度层：`parity_run.sh` / `probes_run.sh` 默认附带（清单单一依据 = `<outdir>/corpus.tsv`；
  结果写入 `<outdir>/warm/`，`logs/` 格式不变，因此历史对拍仍可比较）。`WARM_LEG=0` 关闭。
  对 pre-fix 固定基线预期通过（既有 75/29 语料不含 `as *T` 形态；实测 M1 二进制 75 档 FAIL=0）。
  〔2026-10-11 补正〕本行“75 档”是当时值；parity 语料现为 76 档（`tests/suite/*.cr` 36 + …，
  见本文件“定义”节与 `parity_run.sh:32` 的 `CORPUS_TOTAL=76` 硬性断言），不得当作当前语料数。
- 定点层：`tests/probes/warm/`（固定路径是该语料的设计要点；复制到唯一 temp 路径会导致检查恒通过且
  没有实际覆盖，突变 M3 已证实）。pre-fix 二进制在本层必然失败（缺陷本体），所以对固定基线调用
  `warm_run.sh` 时预期 rc=1，不是基线不合规（检查 = 突变 M1，见 `warm-task3-report.md`）。
- 时长实测（2026-09-15，本机）：定点层 0.9s，probes 广度层 +3.5s，parity 广度层
  +125s（75 档〔当时值；现 76 档〕×2 次 `ccr`，以大文件为主；注意该值对包含 `src/compiler/main.cr` 的大文件档不成立，
  见 `TODO #2026-09-17-8`：实测该层在含大文件的清单上 ≥7× 且未运行完）。因此 CI 只接入最小面（`tests/selfhost/test_warm_cache_gate.py`，0.5s），
  广度层留作手工检查。
- 检查本体不进 CI（维护者裁定 2026-09-15）：与套件同语料、覆盖重叠，收益仅是校验 runner 自身。
- 适用范围限制（W3 阶段实测登记，2026-09-15）：本检查现比对 rc + 诊断码集 + 产物 sha（`ccr`/ELF/DOT 三面），
  不覆盖 DOT label / 日志文本。实测存在有缓存状态名称字面差异（`ir_gen` 期合成名字串在有缓存状态缺席，导致
  DOT 变量名标签丢失前缀；不是不报错地面，不影响产物，见 TODO #2026-09-15-8）。若将来要把名称面纳入检查，须扩展比对约定
  （例如 DOT 逐行 diff 或 name 面专用通道），本次不实施。
- 适用范围限制（跨二进制有缓存状态分支，2026-09-16 (A) 阶段登记）：有缓存状态分支现比对 rc + 诊断码集 + 产物 sha，
  不覆盖日志文本。跨二进制比较日志会把冻结侧 `lower to ccr…` 与当前侧（FC 阶段硬检查 `main.cr:616-621`
  早停：负例探针不再进入 lowering）的打印差异误报为分歧（(A) 阶段实测：同一档 rc/产物全同，仅日志行不同）。
  因此有缓存状态分支检查标准 = 空缓存状态逐档 + 有缓存状态自洽（FAIL=0），不按跨二进制日志文本判失败。与上一条（#2026-09-15-8：不覆盖
  DOT label / 日志文本）是同一条适用范围限制，本条只补“跨二进制”这一维，不另立条目。
- 何时需要运行（手工检查纪律）：下列任一情形必须运行 `warm_run.sh`（0.9s）加至少一次
  parity 广度层（`parity_run.sh` 默认已含）：1 改动 `tools/baseline/*` runner 本体；
  2 改动缓存面（`src/compiler/cir_cache.cr`、`ccr_io.cr` 的保存/装载路径、`main.cr` 的缓存门/
  见证规则、`CIR_CACHE_VER`）；3 关闭、降级或重定向 `.core/cache`（含 `clean-cache` 语义变更）；
  4 新增或改动 `tests/probes/warm/` 语料（须同步 `warm_leg.sh` 的 `WARM_TOTAL` 与语料 README）。
  日常 CI 已由最小面覆盖语料本身，不替代上述检查。

### 命令层陷阱（误报失败，2026-09-16 #2026-09-16-16 阶段 2 T1 实测登记）

运行本目录的 runner 或手工探针时，有两类会产生误报失败（让人觉得命令已经运行、结果是坏的）的问题。
两者叠加时表现为整阶段探针全部失败；#2026-09-16-16 T1 首轮 8/8“失败”全部由此产生：

- `noclobber`：重定向到已存在的日志文件时，重定向失败，命令根本没有运行，`tail`/`grep`
  读到的仍是上一轮的旧日志。做法：换新路径或用 `>|`；每次运行检查都核对日志时间戳
  （“旧日志被当成新结果”是第二次遇到：首次在 #2026-09-16-31 阶段 CI job 轮询）。
- `corec build` 必须在仓库根运行：在 `/tmp` 等仓库外目录运行时，
  报 `error: cannot locate src/runtime/rt.cr`（构建要读仓库内的 runtime 源），rc=1；
  这与“cwd 决定 import 解析”（在 `/tmp` 运行探针会得到假 139）属于同一类问题。

为什么单列：这类陷阱产生的是误报失败，而误报失败与漏报通过一样有害：它会让人去修一个不存在的缺陷，
或把真实失败当成环境噪声放过。通用做法：检查命令的运行环境要刻意设置
（cwd = 仓库根、受控 `HOME`、逐档 `clean-cache`）+ 日志路径唯一 + 每次核对产物是否存在。

## 换代纪律（只在此处更新允许清单）

1. 允许清单换代 = “基线世代”变更（例如尾阶段完成后，下一组以本次完成为 pre-侧）。
   不得因为重建 sha 不符就修改允许清单来对齐，那正是本方法要检出的“构建不可复现”。
2. 换代须同阶段记录：旧三 sha（含其源修订）+ 新源修订 + 理由 + 出处提交；旧值不删（清单保留记录）。
3. 换代后重新运行一次对拍自证（新基线 × 当前源 vs 当前二进制 × 当前源），并把结果记入该阶段报告。

## 已知限制（会报错）

- CI 内不运行：`.github/workflows/core-ci.yml` 用 `actions/checkout` + `fetch-depth: 2`（浅检出，
  无 `jj`），pinned revision 在 CI 环境不可得。本检查为手工检查（每任务或每阶段收尾运行），
  所以入库的是可复现性而不是 CI 挂钩（R2 P6 Task 1 Step 4 评估结论）。
- 75 档语料〔当时值；现 76 档，见下行注〕的既有 rc=1 不是回归（2026-09-17 阶段 6 T6 实测：`36×0 / 39×1`）：
  〔2026-09-24 加注（原文保留）〕语料已增至 76 档（#132 加 `tests/suite/cli_view_test.cr`），所以本行的
  `36×0 / 39×1` 是 75 档时的实测值；76 档的分布与划界须在下次采基线时重采。
  本次实测（2026-09-24）：用 `core-ctfeas-ws` 的二进制（2026-09-23 07:49 构建，因此不是 develop 当前二进制）
  运行计数分支，得到 PASS，76 档，rc 分布 `44×0 / 32×1`。注意该分布属于那枚二进制，不得当作基线；
  与上行旧值的差（rc=0 从 36 升到 44、rc=1 从 39 降到 32，语料净 +1）意味着 7 档由 rc=1 变为 rc=0（能力变更，非回归），
  划界清单须用 develop 自建二进制重划后才能当作“既有失败”使用。
  〔2026-10-11 T7 采基线·v4〕用本代固定基线（`25e70197` 自建，`corec` sha `701a319f…`）
  重划 76 档计数分支，得到 PASS，rc 分布 `43×0 / 33×1`（分层 rc=1：t1 7，t2 1，t3 13，
  t4 10，t5 2，共 33）。t1 的 7 档 = `apx_conversion_test`、`at_test_mini4`、`at_test_mini6`
  （`*_mini*` 由 CI `suite` job 跳过）、`opt_dex_test`、`ptr_arith`（B04 borrow）、`test_control_flow`、
  `test_generics`（空 fixture `cannot read`）。注意与上行 2026-09-24 那枚二进制的 `44×0 / 32×1` 差 1 档（由 rc=0 变为 rc=1），
  归属未定：跨二进制（且那枚非 develop 自建），须以代 0 基线（阶段外冻结，见 v4 计划二.1 节）逐档
  码集对拍才能判断是否回归；本条不作回归声明（本次 rc 等价规则 = 代 0 逐档码集，见 v4 计划二.2 节 B1/B2）。
  因此本文档其他位置出现的“75 档”同属 76 档之前的实测值（定点层的“既有 75/29 语料”`+125s（75 档 ×2 次 ccr）`），
  不得当作当前语料数；`src/ci/run.sh` 里那处同款引用已于 2026-09-24 一并补正。
  〔2026-10-25 T7 重采·85 档〕用新固定基线（`7eb9669d` 自建，`corec` sha `4234b7a6…`）重划，
  得到 PASS，85 档，rc 分布 `49×0 / 36×1`（分层 rc=1：t1 4、t2 1、t3 20、t4 9、t5 2）。
  t1 的 4 档 = `apx_conversion_test`、`at_test_mini4`、`at_test_mini6`、`ptr_arith`。
  旧 76 档值 `43×0 / 33×1` 保留为前一语料规则。
  空 fixture ×2（`tests/suite/{test_control_flow,test_generics}.cr`，2026-10-24 已删除；本行计数是删除前实测）、
  P21 嵌套 fn ×3、examples 解析错 ×2、库单元单独 check ×25、TF01 并发族 ×5、TF07 ×1、B04 ×2，划界见
  `p6-task0-report.md` 3.1 节（运行之前先读，不要把既有失败当成回归）。
- `examples/` 不在任何 CI job 的覆盖面内（`suite` job 只运行 `tests/suite`），但本对拍面包含它
  （4 档），所以对拍是 examples 的唯一行为证据来源。
- `.ccr`/`.cir` 缓存态：比较任何产物前 `clean-cache`（runner 已逐档做）；`.ccr` 记录值引用须带
  命令形式 + 缓存态（TODO #2026-09-11-9 / P4 附录 D-1）。
- `.ccr` 记录值还依赖 `$HOME` 内容（2026-09-16 检查实现方式化阶段 CI 失败档已确认）：编译器解析 `import`
  时会读 `$HOME/.core/lib/<模块>/index` 并把这些名字驻留进 `.ccr`（`src/compiler/module.cr:523-530`），
  所以同一提交、同一编译器，换台机器产物就变（`tests/suite/generics_test.cr` 在本机
  `~/.core/lib/io/index` 在场时 142793B、在 CI 上 142765B）。检查的效力范围：`tools/baseline/`
  的 `.ccr` 记录值自本次起固定为“环境归一化（受控空 `HOME`）下的产物”，实现方式
  `canary_check.sh` 已把 `HOME` 固定到采集目录内的空 `home/`；手工重新运行时也须同样归一化，
  否则会得到本机态的误报失败（不得 unset 或置空 `HOME`：`module.cr:526` 有硬编码 `/home/DslsDZC`
  后备逻辑，置空反而会去读原开发者家目录）。根因已独立登记（TODO #2026-09-16-20/#2026-09-16-21，与“缓存键缺编译器身份”同类）。
  注：本条的两档语料中 `ptr_arith` 零 import，不受影响；受影响的只有 `generics_test`（两种形式）。
  2026-09-17 更新（第 4 阶段 `home-repro` 已修，TODO #2026-09-16-20/#2026-09-16-21）：索引不再影响产物。
  `import` 期只写入侧表（不 `str_intern`、不追加 SYM），仅被引用的名字在首次查找时物化，
  且 `.cr` 声明优先（主机文件不得改写源码声明的含义）。因此实现方式和手工重新运行不再需要靠 `HOME`
  归一化来规避本条（归一化仍保留，作为双保险）；`HOME` unset 也不再读任何家目录（硬编码
  后备逻辑已删）。检查 = `tests/selfhost/test_so_index_repro.py`（8 例，已接入 `selfhost-tests`）：
  两态 `.ccr` 两种形式逐字节相同 · 良性索引零影响 · 关键面（索引独有名字）不退化 · 索引行数
  不再是行为分界（N=2/200/2000 三档产物相同且 rc 正常）· `HOME` unset 与空 `HOME` 结果相同 · ELF 跨两态相同。
