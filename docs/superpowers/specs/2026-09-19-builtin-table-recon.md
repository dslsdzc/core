# `bi_add` 内建表侦察（**只读产出 · 只报不改**；2026-09-19）

> **基线**：`develop@origin` = **`09f253b8`**（含 `#136`）。
> **取数纪律**：一律 `jj --ignore-working-copy file show -r develop@origin <path>`；先把 120 档落 `/tmp/dev` 再 grep，**未 grep 工作副本**。
> **锚**：**符号锚为主**（函数名 / 唯一子串）；行号只作示例（本仓已多次实测行锚漂移）。
> **范围**：`src/compiler/checker.cr` 的 `bi_add` 表（22 条）· 其消费者的三处扫描点 · 各条目的实现面（`src/runtime/rt.s` · `src/arch/**` · `src/stdlib/**`）。
> **性质**：本文件**只出分类与影响面**；裁决已由 team-lead 作出（见 §8）。**本文件是本次侦察唯一新增的文件**，未改任何其它档。
> **⚠ 证据等级（必读）**：本文所有「真实语义签名」均为 **取证**（读实现/注释/调用点推出），**不是实测**——本次侦察**未跑任何 S1P、未跑探针、零构建**。凡未取证处一律标「待定」（本表**零条**待定）。

---

## 0 结论摘要

| 项 | 结论 |
|---|---|
| ① 分类 | **裸字边界 20 · 有类型 2 · 待定 0**（全 22 条见 §1） |
| ② 爆炸半径 | 改动面 **22 处**（或最小 2 处）；**三处消费者全按名扫描 ⇒ 加列不动编号**（好消息）；**合成 FuncInfo ⇒ 动 SYM 段 ⇒ canary 面**（否 (甲) 的主因） |
| ③ 可行性 | **能**，成本极低；但「有类型族补参数型」**收益边际**（该族只有 2 条，调用点全在编译器自身）⇒ 裁决取 **(乙) 登记契约**（§8） |
| ⑤ 反预期 | **4 处**：类型信息在**返回面**不在参数面（§3）· **6 条被 `.cr` 真定义遮蔽**（§4）· `sched_call_0..4` 零调用点（§5）· 「22 条」≠「内建」（§6） |
| 另 | **潜伏**缺陷一条：`fiber_init` 名字碰撞（§7，**今天不可达**） |

---

## 1 ① 22 条逐条分类表

**判定规则（先写死，后取数）**：
- **裸字边界** = 该内建的实参在语义上是**机器字 / 字节 / 地址 / 下标 / 计数 / 打包字**；ABI 消费的就是裸寄存器值 ⇒ **类型不匹配不算错**。
- **有类型** = 实参在语义上是**带表示的值**（串缓冲 / 句柄），把它与普通 int 混同**是真缺陷**。
- **待定** = 取证不足以归类（**本表零条**）。

| # | 内建名 | `ret_ti` | 真实语义签名（取证） | 归类 | 取证锚 |
|---|---|---|---|---|---|
| 1 | `alloc` | `TI_STR` | `(size: int) -> string` | **裸字边界** | `src/runtime/rt.s` 头注 `alloc(size: int) -> string (pointer)`；调用点 384 处，如 `src/arch/hit/lower_to_core.cr` `alloc(nc * HIT_ES_REC)` |
| 2 | `get_arg` | `TI_STR` | `(n: int) -> string` | **裸字边界** | `rt.s` 头注 `get_arg(n: int) -> string`；调用点 `src/compiler/main.cr` `get_arg(0)` · `src/stdlib/cli.cr` · `src/compiler/corearch.cr` |
| 3 | `load_str_ptr` | `TI_STR` | `(buf: string, pos: int) -> string` | **有类型** | `rt.s` 头注 `load_str_ptr(buf: string, pos: int) -> string`；调用点 `src/compiler/module.cr` `load_str_ptr(g_open_docs, i * 24)` |
| 4 | `store_str_ptr` | `TI_INT` | `(buf: string, pos: int, val: string) -> int` | **有类型** | `rt.s` 头注 `store_str_ptr(buf: string, pos: int, val: string) -> int`；调用点 `src/compiler/module.cr`（两处）· `src/compiler/checker.cr` 诊断写入 |
| 5 | `fiber_switch` | `TI_INT` | `(current_sp_addr, next_sp) -> int` | **裸字边界** | `rt.s` 头注；调用点 `src/stdlib/sched.cr`（两处） |
| 6 | `fiber_init` | `TI_INT` | `(stack_bottom, entry_fn) -> int` | **裸字边界** | `rt.s` 头注；调用点 `src/stdlib/goroutine.cr`。⚠ **名字碰撞见 §7** |
| 7 | `g_set_curg` | `TI_UNIT` | `(ptr) -> unit` | **裸字边界** | `rt.s` 头注 `g_set_curg(ptr) — set current goroutine pointer`；调用点 `src/stdlib/sched.cr`（三处） |
| 8 | `g_get_curg` | `TI_INT` | `() -> ptr`（**无参**） | **裸字边界** | `rt.s` 头注 `g_get_curg() — get current goroutine pointer`；调用点 `src/stdlib/sched.cr` |
| 9 | `m_start_workers` | `TI_UNIT` | `(n: int) -> unit` | **裸字边界** | `rt.s` 头注 `m_start_workers(n: int) — launch N worker threads via clone`；调用点 `src/stdlib/sched.cr` |
| 10 | `load8` | `TI_INT` | `(buf, pos) -> int` | **裸字边界** | 调用点 `src/arch/hit/hit.cr`（多处，如 `load8(buf, pos) + load8(buf, pos + 1) * 256 + …`）；后端内联发射 |
| 11 | `store8` | `TI_INT` | `(buf, pos, val) -> int` | **裸字边界** | 调用点 `src/arch/hit/hit.cr`（`store8(buf, pos + 0, v % 256)` 族） |
| 12 | `load64` | `TI_INT` | `(buf: string, pos: int) -> int` | **裸字边界** | `rt.s` 头注 `load64(buf: string, pos: int) -> int`；调用点 `src/compiler/cir_cache.cr`（哈希循环） |
| 13 | `r64` | `TI_INT` | `(buf: string, pos: int) -> int` | **裸字边界** | **有 `.cr` 真定义** `src/compiler/dyn_arr.cr`（见 §4）；调用点 1260 处 |
| 14 | `w32` | `TI_UNIT` | `(buf, pos, val) -> unit` | **裸字边界** | **有 `.cr` 真定义** `src/compiler/dyn_arr.cr` · `src/compiler/elf.cr`（见 §4） |
| 15 | `w64` | `TI_UNIT` | `(buf, pos, val) -> unit` | **裸字边界** | **有 `.cr` 真定义** `src/compiler/dyn_arr.cr` · `src/compiler/elf.cr`；后端内联发射（`src/arch/x86_64/instr.cr` 注释写明 `rdi=buf, rsi=pos, rdx=val`） |
| 16 | `_dyncpy` | `TI_UNIT` | `(src, nbytes, dst) -> unit` | **裸字边界** | **有 `.cr` 真定义** `src/compiler/dyn_arr.cr`；后端内联发射（`instr.cr` 注释 `rdi=src, rsi=n, rdx=dst`） |
| 17–21 | `sched_call_0` … `sched_call_4` | `TI_INT` ×5 | `(buf, p, n) -> int` | **裸字边界 ×5** | `src/format/elf/elf.cr` 注释 `sched_call_N(buf, p, n): mov rax,[rdi+rsi*8]; shift N args; jmp rax` + 蹦床发射/注册（见 §5）；**0 个 `.cr` 调用点** |
| 22 | `sched_go` | `TI_INT` | 表内登记 `(?, ?) -> int`；**实际生效的是遮蔽它的 `.cr` 函数** `(fn_ptr: int, arg: int) -> string` | **裸字边界** | **有 `.cr` 真定义** `src/stdlib/sched.cr`；合成调用点 `src/compiler/ir_gen.cr`（`go` 表达式 → `sched_go(@addr(f), arg)`） |

**合计：裸字边界 20 · 有类型 2 · 待定 0。**

---

## 2 ② 参数型列的爆炸半径

| 项 | 读数 | 依据 |
|---|---|---|
| `bi_add` 调用点 | **22**（全在 `src/compiler/checker.cr` 的 `init_builtins` 内，行 281–302 示例） | `grep -c -F 'bi_add('` = **23**（22 调用 + 1 定义，定义在 `checker.cr:305` 附近） |
| 表构造时机 | **运行期**（非编译期常量表） | `init_builtins` 里 `alloc(8 * 8)` 起步、`bi_add` 内**按需翻倍**（`checker.cr` 的两处 `if … > str_len(…)` 扩容分支） |
| 平行数组 | **2 条同索引数组**：`g_rt_builtin_names` · `g_rt_builtin_ret_types`（另有计数 `g_rt_builtin_count`） | `checker.cr:274-276` 声明；写入点 = `bi_add` 内两处 `w64` |
| 加「参数型」的代价 | 第 3 条同索引平行数组（或改 stride）⇒ 声明 +1 · init +1 · 扩容 +1 · `bi_add` 写入 +1 · 消费点读 +1 | 同上 |
| **编号/顺序敏感度** | **不敏感（好消息）**：三处消费者**全按名字扫描** ⇒ **加列不动任何编号、不 shift 现有条目** | ① `checker.cr` EXPR_CALL 回退分支（`bi` 循环扫 `g_rt_builtin_names` → 命中即回 `g_rt_builtin_ret_types`）② `checker.cr` 注册分支（同扫描，逐条注册 SYM_FN）③ `src/compiler/ir_gen.cr` 的 `ir_call_return_type`（同扫描） |
| `.ccr` 段布局 | **不动**：表**不序列化**（全仓 `g_rt_builtin` 仅出现在 `checker.cr` + `ir_gen.cr` + 两处注释，**无 `ccr_*` 引用**） | 同上 |
| ⚠ **canary 面（否 (甲) 的主因）** | `checker.cr` 的注册分支会为**每个未被用户遮蔽的内建建一行 SYM_FN**（`g_sym_count` 递增，注释明写「必须在 collect_decls 之后」）⇒ **若方案走「给内建合成 FuncInfo / 参数符号」⇒ 符号编号变 ⇒ `.ccr` SYM 段字节面可能变 ⇒ canary 需重锁声明**（并按 D1 闸门：红 ⇒ 非确定性不得重锁） | `checker.cr` 注册循环（`sym_set_name/sym_set_kind/sym_set_type/sym_set_node` + `g_sym_count = si2 + 1`） |
| 同步点 | **`checker.cr` 与 `ir_gen.cr` 是同一张表的两次独立扫描** ⇒ 任何新列若 ir_gen 也要用，**必须两处同改**（否则又是两面不一致） | 上表 ①③ |

**⇒ 最小改法**（只给 §1 的「有类型」2 条补参数型）**不动编号、不动 `.ccr`**，前提是**不引入参数符号**。

---

## 3 ⑤(a) 反预期之一：**类型信息在返回面，不在参数面**

**被推翻的定性**（team-lead 转述 `b8-e1` 的举例，未核验）：

> ~~「『有类型』那族（`alloc → string`、`sched_go`、`g_get_curg`）**类型是有意义的**，该补参数型」~~ **【已作废】**

**实测/取证结论**：
- `alloc` 的 `string` 是它的**返回型**（`ret_ti = TI_STR`）；它的**实参 `size` 是裸字**（`rt.s` 头注 `alloc(size: int) -> string`）。
- `sched_go` 的「函数值」属于**遮蔽它的那个 `.cr` 函数**（`src/stdlib/sched.cr`），**不是内建表条目的实参**。
- ⇒ **这张表的参数面几乎全是裸字；带类型的部分集中在返回面**（`alloc` / `get_arg` / `load_str_ptr` 三条返回 `string`）。

**判据意义**：若要提升内建族的类型保护，**目标应是返回面或统一 FuncInfo**，不是「给参数面补类型」。

---

## 4 ⑤(b) 反预期之二：**6 条被 `.cr` 真定义遮蔽**

| 内建名 | `.cr` 真定义处 | 遮蔽后果 |
|---|---|---|
| `r64` | `src/compiler/dyn_arr.cr`（`fn r64(buf: string, pos: int) -> int`） | 编译编译器时走真定义 ⇒ 内建条目**不生效** |
| `w32` | `src/compiler/dyn_arr.cr` · `src/compiler/elf.cr` | 同上 |
| `w64` | `src/compiler/dyn_arr.cr` · `src/compiler/elf.cr` | 同上 |
| `_dyncpy` | `src/compiler/dyn_arr.cr` | 同上 |
| `fiber_init` | `src/stdlib/scheduler.cr`（**0 参**，见 §7） | ⚠ 签名与内建侧**不同** |
| `sched_go` | `src/stdlib/sched.cr`（`-> string`，即 A₂ 对齐后的形态） | 同上 |

**遮蔽规则出处**：注册分支注释明写「**skip if already defined by user**」⇒ 用户定义优先。

**⇒ 约定要求**：登记/引用一律写「**未被 `.cr` 遮蔽的内建条目**」，**不得写「22 个 callee 零覆盖」**。

---

## 5 ⑤(d) 反预期之三：`sched_call_0..4` **零 `.cr` 调用点**

- 它们只在后端**被发射与注册**（`src/format/elf/elf.cr`：蹦床发射 `emit_sched_call` + 按名登记进 `g_x86_func_offsets`），**全仓无 `.cr` 侧调用点**。
- ⇒ **对它们「补参数型」没有可保护的调用点**（分类仍为裸字边界：`(buf, p, n)` 三字）。

---

## 6 ⑤(e) 约定：**22 = 这张表的约定 ≠ 「内建」的约定**

- `str_len`（全仓高频使用）**不在表里**——它是 `src/stdlib/fmt.cr` 的**普通 `.cr` 函数**。
- ⇒ 引用时**不得写「22 个内建」**；正确写法 =「`bi_add` 表的 22 条条目」。

---

## 7 潜伏缺陷（**今天不可达**）：`fiber_init` 名字碰撞

> ⚠ **措辞纪律**：这是**潜伏**缺陷，**当前不可达**，**不得写成「现网缺陷」**。要素如下（供 TODO 落条）。

| 要素 | 事实 | 锚 |
|---|---|---|
| 内建侧 | `fiber_init(stack_bottom, entry_fn) -> int`（**2 参**） | `src/runtime/rt.s` 头注 + 实现 |
| `.cr` 侧 | `fn fiber_init()`（**0 参**，初始化调度全局） | `src/stdlib/scheduler.cr` |
| 调用点 | `fiber_init(stack_top, wrap_addr)`（**2 参**调用，意图是内建侧） | `src/stdlib/goroutine.cr` |
| 可达性 | **全仓无 `import scheduler`**（只有 `import sched`）⇒ 0 参 `.cr` 定义与 2 参调用**当前不在同一编译单元** ⇒ **不可达** | `grep 'import scheduler'` 零命中 |
| **可达后果** | 一旦某单元同时引入两者：**0 参 `.cr` 定义遮蔽 2 参内建**，而**实参个数当前不校验** ⇒ 静默错行为（**fiber 栈永不初始化、`sp` 拿到 unit**） | 遮蔽规则见 §4；实参面不校验见批 8 `(甲)` |
| 建议判据方向 | ① 同名跨源检测（内建表 × `.cr` 定义的**同名不同签名**清单类判据）；② 或至少一条**负控**：同单元引入两者 ⇒ 必须红（当前会绿） | 待裁 |

**TODO 落条归属**：本条 = team-lead 编号 **`-6`**；内建回退覆盖洞 = **`-5`**。**均由 `b8-e1` 统一落 `TODO.md`**（避免同档双写），**本文件不落 TODO**。

---

## 8 裁决记录（team-lead 2026-09-19）

- **取 (乙)：明确登记「内建族参数面免检」这个契约。**
  理由（按本仓约定 = **契约比较**，非成本比较）：`bi_add` 只有返回型、**20/22 条的实参语义就是裸字/字节/地址/下标**，ABI 消费的就是裸寄存器值 ⇒ **「参数面免检」是有意设计的边界，不是缺陷**（有契约 = 有意设计）。
- **否 (甲)：给内建合成 FuncInfo / 参数符号走统一实参校验。**
  **主因 = §2 末行查出的那条**：合成 FuncInfo ⇒ 每个未被遮蔽的内建都建 SYM_FN ⇒ **符号编号变 ⇒ `.ccr` SYM 段字节面可能变 ⇒ canary 需重锁声明**（且须先过 D1 闸门：红 ⇒ 非确定性不得重锁）。**为 2 条有类型条目付这个代价不成立。**
- **边界要「登记」而不是「留着不说」**——消除静默是本批主旨。

---

## 9 待办（转 `b8-e1`）

1. 落 `TODO` **`-5`**：内建回退覆盖洞（约定按 §4 改写为「**未被 `.cr` 遮蔽的内建条目**」；并把 §3 的「类型在返回面」写进机理叙述）。
2. 落 `TODO` **`-6`**：§7 的 `fiber_init` 名字碰撞（**必须写明「潜伏、今天不可达」**）。
3. 若日后要做 (乙) 的「契约登记」，本文件 §1/§2 可直接作证据面（**引用时保留 §6 的约定限定**）。
