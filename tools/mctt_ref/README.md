# McTT 参考侧（Task 1：参考侧构建记录）

McTT（ICFP'25，Beluga-lang）是首个经 Coq 验证的 MLTT 类型检查器。本目录记录参考侧的构建与验证信息，供后续差分测试（Task 3+）的 harness 使用。

## 位置与版本

- 源码：`~/mctt`（**仓库外**，McTT 源码不提交进本仓库）
- 分支：`icfp25`，头 `a3d97e9c427d311566ba25540292d55be4adfdba`（经 `gh api` 确认）
- 获取方式为 curl tarball（`https://github.com/Beluga-lang/McTT/archive/refs/heads/icfp25.tar.gz`）。
  `git clone` 因本机到 github.com 网络不稳超时失败；tarball 亦间歇失败，重试后成功。

## 构建配方（实际执行，已成功）

官方配方（README.md）为 opam 全量构建，产出提取的类型检查器：

```bash
opam update
opam switch create coq-8.20.0 4.14.2
opam pin add coq 8.20.0
opam repo add coq-released https://coq.inria.fr/opam/released
opam install -y menhir coq-equations coq-menhirlib ppx_inline_test ppx_expect
cd ~/mctt && make          # theories（Coq 证明 + extraction）→ dune build（driver）
```

**实际执行脚本：`~/mctt/build_ref.sh`**（`set -e`，可续跑：已建 switch/已装包一律跳过），
配套 `~/mctt/curl_gh.sh`（见「网络问题与修复」）。

### 对官方配方的必要修正

1. `opam install` 须显式补装 `dune`：官方配方漏列该项，新建 switch 若无 dune，`dune build` 必然失败。
2. **ppx_inline_test/ppx_expect 须保留，不得跳过**：检查结论为 driver/dune 的 McttLib 库存在**库级**
   `(preprocess (pps ppx_expect))` 指令，而 `mctt.exe` 链接 McttLib，故主构建在 dune 编译期需要
   ppx_expect 可执行文件（ppx 虽为 Test.ml inline-tests 的测试框架，但预处理指令作用于整个库）。
   结论为主构建**依赖** ppx，不能跳过；已安装成功（ppxlib.0.35.0 / ppx_inline_test.v0.16.1 /
   ppx_expect.v0.16.2）。
3. CPU 限制（仓库铁律 #6）为外层 `nice -n 19` 配合 `OPAMJOBS=2`（opam 内 OCaml/Coq 编译）、
   `make -C theories J=2` 与 `dune build -j 2`。本机 4 核，全量构建约 2-3 小时。

### 网络问题与修复（github.com 主域 TLS 间歇重置）

- 现象为 github.com 主域（默认 DNS 20.205.243.166）TLS 连接间歇重置（curl exit 35），
  且各 IP 不同时失效；重试 15 次仍可能全部失败（曾两次停在源码拉取、一次停在 ppx 拉取）。
- 修复方式为 `OPAMCURL="$HOME/mctt/curl_gh.sh"`：包装 curl 对 github.com:443 做**多 IP 轮换**
  （140.82.114.3 / 140.82.112.3 / 140.82.113.3 / 140.82.116.3 / 140.82.121.3 / 20.205.243.166），
  成功者 stdout 原样透传（opam 解析 `--write-out` 的 http 码），并配 `OPAMRETRIES=15` 兜底。
- codeload.github.com / raw.githubusercontent.com / release-assets.githubusercontent.com
  走正常 DNS，无此问题。

## 构建状态：**COMPLETE**（2026-08-16 00:12）

- 日志：`/tmp/mctt-build.log`（尾部应见 `===== BUILD COMPLETE =====` 与
  `_build/default/driver/mctt.exe` 行）。
- switch `coq-8.20.0`（OCaml 4.14.2）：coq 8.20.0（pin）、coq-equations 1.3.1+8.20、
  coq-menhirlib 20260209、menhir 20260209、dune 3.23.1、ppx 全家已装。
- 产物：`~/mctt/_build/default/driver/mctt.exe`（6593400 字节）。

## 用法（以源码为准，已实测）

- 可执行文件为 `~/mctt/_build/default/driver/mctt.exe`（**含 driver/ 段**；不是 `Main.exe`，因
  driver/dune 中 executable 为 `name mctt`、模块为 `Mctt.ml`，`Main.ml` 在 McttLib 库内）。
- 用法（经 Mctt.ml 源码确认，单参数 `<input-file>`；缺参时打印 usage 并 exit 7）：

```bash
cd ~/mctt
./_build/default/driver/mctt.exe examples/simple_nat.mctt     # 直接跑，无需 switch 环境
opam exec --switch=coq-8.20.0 -- dune exec mctt -- examples/simple_nat.mctt   # 或经 dune
```

- exit 0 表示类型检查通过。注意 dune 必须在 coq-8.20.0 switch 环境运行（default switch 无 ppx_expect，
  会报 "Library ppx_expect not found"）。

## 冒烟测试结果（2026-08-16，已验证）

```text
$ ./_build/default/driver/mctt.exe examples/simple_nat.mctt
Parsed:
  4 : Nat
Elaborated:
  4 : Nat
Normalized Result:
  4 : Nat
$ echo $?    # 0
```

## extracted 模块清单（构建完成，`ls driver/extracted/*.mli` 实测 40 个）

提取代码由构建期生成（**McTT 仓库的 `driver/extracted/` 本身不含任何 `.ml`/`.mli`**：icfp25 与
icfp25-artifact 标签树均已核对，只有 dune/.gitignore/.ocamlformat 三个文件）。

**McTT 核心（Task 3 harness 的差分对拍目标）：**
`Domain` `Elaborator` `Entrypoint` `Evaluation` `Interpreter` `Interpreter_complete`
`Interpreter_correct` `Main` `NbE` `Parser` `Readback` `Subtyping` `Syntax` `TypeCheck`
`Validator_complete` `Validator_safe`

**Coq 标准库提取（依赖）：**
`Alphabet` `Ascii` `Automaton` `BinInt` `BinNums` `BinPos` `Compare_dec` `Datatypes`
`FMapAVL` `FMapList` `FSetAVL` `Grammar` `Int` `List` `MSetAVL` `MSetInterface` `Nat`
`OrderedType` `Orders` `OrdersAlt` `OrdersFacts` `OrdersTac` `PeanoNat` `Specif` `String`

## 环境备注

- switch `coq-8.20.0`（OCaml 4.14.2，独立于 default switch 5.4.1）。
- 本仓库禁止 git（hook 机械拦截）；McTT 的克隆与构建属第三方仓库操作，git/curl 均只作用于 `~/mctt`。

## Task 3 补充：harness 入口签名（侦查实测，以提取 .mli 为准）

harness 接线用到的真实模块与签名（`driver/extracted/*.mli`，均位于 wrapped 库
`McttExtracted` 内，外部须经 `McttExtracted.Module` 引用）：

| 模块 | 签名（M1 用到的入口） |
|------|----------------------|
| `Syntax` | `type exp`（`Coq_a_typ/Coq_a_nat/Coq_a_zero/Coq_a_succ/Coq_a_natrec(exp*exp*exp*exp)/Coq_a_pi/Coq_a_fn/Coq_a_app/Coq_a_var/Coq_a_sub`）、`type sub`、`type nf`、`type ne`、`nf_to_exp`、`ne_to_exp`、`nf_eq_dec` |
| `TypeCheck` | `type_check : exp list -> exp -> exp -> bool`（**参数序 (ctx, 类型, 项)**）、`type_infer : exp list -> exp -> nf option`（(ctx, 项)，返回已正规化 nf）、`type_check_closed` |
| `Subtyping` | `subtyping_impl : exp list -> exp -> exp -> bool`（(ctx, A, B)：A ≤ B）、`subtyping_nf_impl` |
| `NbE` | `nbe_impl : exp list -> exp -> exp -> nf`（(ctx, 项, 类型)）、`nbe_ty_impl : exp list -> exp -> nf` |
| `Evaluation` | `eval_exp_impl : exp -> (int -> domain) -> domain` |
| `Readback` | `read_nf_impl/read_ne_impl/read_typ_impl : int -> … -> nf/ne` |

要点（构建/调试中实测）：

1. **提取库是 wrapped**：`(library (name McttExtracted) (public_name mctt.extracted))`
   无 `wrapped false`；外部必须写 `McttExtracted.TypeCheck` 等（driver/Main.ml 即
   `module Parser = McttExtracted.Parser` 的写法）。
2. **`type_check` 的参数序是 (ctx, 类型, 项)**：协议行 `check <ctx> <项> <类型>`
   接线时必须交换实参（实测不交换时 `check (ctx) (zero) (nat)` 会因
   `nbe_ty (zero)` 触发 Readback.ml:60 assert 崩溃）。
3. **语义总化**：提取代码对前提不满足的输入触发 `assert false`
   （Readback.ml:17/27/28/60、Evaluation.ml:33/45/46）；harness 统一捕获
   `Assert_failure` 并按拒绝态处理（协议 §5）。`type_infer` 对任意语法良构输入
   为全函数（逐分支核实，无 assert 可达）。
4. **顶层 `(sub …)` 恒推断失败**：TypeCheck.ml 的 `Coq_a_sub (_, _) -> None`
   （即使语义良型亦然）；`check (sub …)` 一律 reject，但 `convert` 经 nbe 可处理
   sub 项。以上均为 McTT 的实际行为，语料以此为准。

## Task 3 补充：harness 构建与运行

- 源文件：本目录 `harness.ml` 与 `dune`（dune 内容为 `(executable (name harness)
  (libraries McttExtracted))`；brief 假设的 `mctt_driver` 库名不存在，实际为
  `McttExtracted`）。
- 构建（需要 opam switch 环境；不在 switch 下的命令须用
  `opam exec --switch=coq-8.20.0 --` 前缀）：

```bash
mkdir -p ~/mctt/driver/harness
cp tools/mctt_ref/harness.ml tools/mctt_ref/dune ~/mctt/driver/harness/
cd ~/mctt && nice -n 19 opam exec --switch=coq-8.20.0 -- dune build driver/harness/harness.exe
# 产物：~/mctt/_build/default/driver/harness/harness.exe（可直接运行，无需 switch）
```

- 运行：`harness.exe QUERY_FILE...`；`#` 注释行与空行跳过；malformed 行输出 stderr
  诊断并返回退出码 1（无 stdout 输出）。
- 冒烟：`harness.exe tools/mctt_ref/smoke.txt` 应与 `smoke.expected` 逐行一致
  （7/7，见下节）。

## Task 3 补充：冒烟结果（2026-08-16，7/7 与 brief 期望表一致）

```text
check: accept      # check (ctx) (zero) (nat)
check: reject      # check (ctx) (zero) (typ 0)
infer: type: (nat) # infer (ctx) (succ (zero))
infer: type: (nat) # infer (ctx) (app (fn (nat) (var 0)) (zero))
convert: yes       # convert (ctx) (nat) (nat) (typ 1)
subtype: yes       # subtype (ctx) (typ 0) (typ 1)
check: reject      # check (ctx) (app (fn (nat) (var 0)) (zero)) (typ 0)
```

brief 标注「第 7 行预期 reject 存在不确定性」，实测 **reject 确认无误**
（app 推断类型为 (nat)，(nat) 与 (typ 0) 不可比）。

## Task 3 补充：全量语料验证（2026-08-16）

三个语料文件全部通过（无 stderr、exit 0；输出行数 = 查询行数 - `#` 注释行）：

| 语料 | 查询行 | 注释行 | 输出行 | 耗时 |
|------|--------|--------|--------|------|
| corpus_manual.txt | 25 | 0 | 25 | <0.01s |
| corpus_random.txt | 1200 | 0 | 1200 | 0.01s |
| corpus_exhaustive.txt | 45244 | 8 | 45236 | 0.22s |

抽查核验（manual 案卷 25 条全部人工对过语义）：natrec 的 succ 分支按 McTT 规则
`MS ⟸ A[Wk∘Wk,,succ #1]`（Definitions.v:29）——动机为 (nat) 时分支须为 nat
形态，(fn (nat) (succ (var 0))) 推断为 Πℕℕ 故 reject（McTT 的实际判定，非 harness
错误）；`check (ctx (nat) (nat)) (sub (var 0) (compose (weaken) (id))) (nat)` 因顶层 sub
恒 None 而 reject，亦为 McTT 的实际行为。
