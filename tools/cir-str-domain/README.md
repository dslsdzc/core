# `tools/cir-str-domain/` — `.cir` 快照「串域跨进程 id」缺陷的证据复现包

**性质**：**证据复现工具，不是判据**（判据见计划 §3，由修复批落在 `tests/selfhost/test_cir_str_domain_warm.py` 并挂
`run.sh selfhost-tests`）。本目录随只读调查轮入库，动机 = 「可复跑的证据别只活在 `/tmp`」。

- **登记条目**：`TODO.md` 的 `#2026-09-18-9`
- **修法计划**：`docs/superpowers/plans/2026-09-18-cir-cache-str-domain.md`
- **一句话**：`.cir` 快照把串操作数存成**写侧进程的绝对 intern id**、装载侧**原样恢复且不重映射** ⇒ 凡
  **首次 intern 发生在 IR 生成期**的串（多字段 `@fields`、合成变量名…）在暖态解析到别的串（可到垃圾字节），
  两次 `build` 均 `rc=0`。

## 用法

```bash
# 1) 范围矩阵（7 档：lit/concat/interp/typeinfo/fields/firstintern/partial）——报告模式，恒 rc=0
CORE_BIN=./build/corec bash tools/cir-str-domain/run_scope.sh
# 2) 判据模式（冷=暖才通过）——**缺陷未修时必然红**，这是判据语义，不是脚本故障
CORE_BIN=./build/corec bash tools/cir-str-domain/run_scope.sh --assert
# 3) 年龄判定（对历史二进制；读回其自写的 CIR_CACHE_VER）
bash tools/cir-str-domain/age_probe.sh /path/to/old/bin_dir [tag]
```

`run_scope.sh` 每档**独立目录、先冷后暖**（`/tmp/cir-str-domain-run`，可 `WORK_DIR=` 覆盖）；`CORE_BIN` 缺省
`<repo>/build/corec`。

## 探针清单（`probes/`）

| 文件 | 形态 | 冷/暖预期（**修复前实测**） |
|---|---|---|
| `repro_6line.cr` | `@fields(Point)` 6 行复现 | 冷 `x,y`/3 · 暖 **`arena_reset`/11**（rc 0/1） |
| `scope_lit.cr` | 源字面量（main + helper） | 冷=暖（安全：解析期已 intern） |
| `scope_concat.cr` | `"AA"+"BB"` | 冷=暖 |
| `scope_interp.cr` | 插值 `"n=${n}"` | 冷=暖 |
| `scope_typeinfo.cr` | `@typeInfo(Point/int)` | 冷=暖（内容已在源里出现过） |
| `scope_fields.cr` | 双字段 `@fields` | **冷≠暖**（缺陷面） |
| `scope_firstintern.cr` | **判别实验**：单字段 `One{x}` vs 双字段 `Two{x,y}` | 暖态 `ONE=x`（对）/**`TWO=chan_send`（错）** |
| `scope_partial.cr` | 单函数 `@fields` | 冷≠暖 |
| `label_collision.cr` | 6 个含 loop/if 的函数（**无字符串**） | 冷=暖（⇒ 用于证明 label 域**结构自保**） |
| `undefined_name.cr` | 引用未定义名 | `build` rc=1 + 无产物（⇒ locals 域收口依据） |

## 为什么暂不挂 CI job

`run_scope.sh --assert` 的语义是「修复后行为」——**缺陷未修时它按定义就是红的**。挂点由修复批随修法一起落
（计划 §3 第 6 条：载体 = `tests/selfhost/test_cir_str_domain_warm.py`，挂 `run.sh selfhost-tests` ⇒ 在 PR 门上跑）。
在此之前本目录只提供**可复跑证据**，不参与任何门禁。
