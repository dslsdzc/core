# `.so` 扩展索引夹具（TODO #2026-09-16-20/#2026-09-16-21/#2026-09-17-1/#2026-09-17-2；第 4 批 T0）

**为什么夹具必须入仓**（本批立的规矩）：判据要跑「`HOME` 含索引 vs 不含索引」两态对拍；
若索引由**各机自备**（真实路径 `$HOME/.core/lib/<模块>/index`），则**判据自己就不可复现**——
正是 #82 要消灭的形态。⇒ 两态所需的索引一律用**本目录的夹具**（放进临时 `HOME`）。

## 档位

| 文件 | 用途 | 要点 |
|---|---|---|
| `io.index` | 判据 J1（主判据·未引用面） | 含两条 `io.cr` **未声明**的名字（`print_int`/`println_int`）⇒ 现状令 canary 语料 **+28B** |
| `io_benign.index` | 判据 J2（良性档） | 全部名字**已在** `io.cr` 声明 ⇒ 现状仍扰动产物（覆盖 + 索引平移） |
| `use_ext.cr` | 判据 J3（**承重面**） | 调用**索引独有**名字 ⇒ 无索引必须**响亮失败**（`error[N06]`），有索引 rc=0 |

## `N` 行大索引（判据 J9 / TODO #2026-09-17-1）

不committed 成大文件：由探针**确定性生成**（同一生成器入仓 = 可复现）。生成规则：

```
首行 `print: string, variadic, auto_str` + 随后 N 行 `ghost{i}: int`（i = 0..N-1）
```
⇒ 索引行数 = N+1；SO_FN 条目数随之线性增长，用来压 `check_all` 的保全缓冲
（`checker.cr:3872-3874` 容量 128，**写入无界** —— #99 的越界写堆面）。

## 用法（探针内的标准步骤）

```
D=$(mktemp -d); mkdir -p "$D/.core/lib/io"
cp <本目录>/io.index "$D/.core/lib/io/index"      # 或 benign / 生成的大索引
cd <仓库根> && ./build/corec clean-cache
HOME="$D" ./build/corec ccr <语料> -o <产物>      # 口径①；口径② = build ... --static
```
**注意**：`HOME` 必须指向**真实存在的目录**（`module.cr:526` 对空 `HOME` 有硬编码兜底）；
「unset」一态须用 `env -u HOME`（判据 J5）。
