# Arena size class 规格

> 状态：已实施
> 日期：2026-10-28
> 关联：`docs/maintainer/design/region-model.md` 第 4 节 · `docs/superpowers/specs/2026-07-28-arena-model-design.md`

## 概述

动态大小的分配走 size class 的分档子区域。每个档位只放同一大小的块，块大小是档位值，分配是档位内的游标推进。回收仍然只有区域整体重置，没有对象级释放。分配失败是硬失败（trap），不返回 0。

Arena 库按机器整数工作。编译器在源文件含 `fn arena_init` 时把整个程序切到 raw-int 模式（`ccr_set_raw_mode_from_source`）。原因是档位表、slot 编号、字节偏移和分配器 stub 共享同一批 cell；tagged 整数会让库写入的偏移与 stub 读出的偏移不一致。

## 决定

1. 静态已知大小的分配不进档位，走精确 bump。
2. 动态大小的分配按档位向上取整：`class = round_up_class(n)`，在档位子区域内 bump。
3. 档位表使用 1.25 倍步长，从 16 字节到 8192 字节，共 25 档。取整浪费上限 20%。
   `region-model.md` 里写的 12.5% 对应 1.125 倍步长，档位数翻倍；本规格先用 1.25 倍，档位表是数据，后续可以换表而不用改分配路径。
4. 超过最后一档（3361 字节）的对象走档位 25。档位 25 不切 4KB 块；它直接使用当前 slot 的剩余空间。
5. 档位 0 到 24 从所属 Arena 的 slot 余量切 4KB 块；块用尽后再切一块。slot 余量不足时申请新 slot。档位 25 用尽当前 slot 余量后同样申请新 slot。
6. 回收只有一种：`arena_reset(ai)` 清空该 Arena 的全部档位子区域和大对象区，并把专用 mmap extent 逐个 `munmap`。
7. 分配失败触发 trap，带四个值：请求字节数、档位、当前游标、当前上限。禁止返回 0，禁止静默降级到全局堆。
8. 全局堆只服务 `arena_init` 和 chunk 链的扩展；它的耗尽同样是 trap。
9. 超过 1MB 的对象从最新的 64MB segment 取连续 slot，最多 64 个 slot（64MB）。
10. 超过 64MB 的对象走独立 `mmap` extent。extent 头记录链指针和长度，`arena_reset` 时 `munmap`。
11. pool 上限由 `Core.toml` 的 `arena_pool_limit` 配置。`arena_grow_pool` 超过上限时打印 `arena: pool limit exceeded` 并返回；分配器随后按失败路径 trap。

## 档位表

| 档位 | 字节 | 上一档到本档的取整浪费 |
|---|---|---|
| 1 | 16 | — |
| 2 | 20 | 20% |
| 3 | 25 | 20% |
| 4 | 31 | 19% |
| 5 | 39 | 21% |
| 6 | 49 | 20% |
| 7 | 61 | 20% |
| 8 | 76 | 20% |
| 9 | 95 | 20% |
| 10 | 119 | 20% |
| 11 | 149 | 20% |
| 12 | 186 | 20% |
| 13 | 232 | 20% |
| 14 | 290 | 20% |
| 15 | 362 | 20% |
| 16 | 452 | 20% |
| 17 | 565 | 20% |
| 18 | 706 | 20% |
| 19 | 882 | 20% |
| 20 | 1102 | 20% |
| 21 | 1377 | 20% |
| 22 | 1721 | 20% |
| 23 | 2151 | 20% |
| 24 | 2689 | 20% |
| 25 | 3361 | 20% |

表按 1.25 倍步长生成。最后一档 3361 是档位 24 的上界；更大的请求统一进档位 25。

## 布局

每个 Arena 维护一份档位状态表，按 `ai * K + c` 索引，K = 26（25 个档位加大对象区）：

| 状态 | 含义 |
|---|---|
| `class_base[ai * K + c]` | 档位 c 当前 chunk 在 Arena slot 内的起点 |
| `class_cursor[ai * K + c]` | 档位 c 当前用到的偏移 |
| `class_limit[ai * K + c]` | 档位 c 当前 chunk 的终点 |

Arena slot 内部再切分：

1. `g_arena_slot_cursor[ai]` 记录该 slot 已切出的字节数。
2. 档位 0 到 24 第一次使用，或当前 chunk 用尽时，从 slot 余量切一个 4KB 块，把 `class_base/cursor/limit` 指向它。
3. 档位 25 第一次使用，或当前尾部用尽时，把当前 slot 的剩余空间作为该档位的 chunk。用尽后切新 slot。
4. slot 余量不足时，向全局堆申请新 slot，链接后从新 slot 继续切。slot 基址 = `segment_base[slot / 64] + (slot % 64) * 1MB`。
5. `arena_reset(ai)` 把 slot 游标和全部 `class_*` 清 0，slot 归还 arena slot free list，专用 extent 全部 `munmap`。

状态规模：每个 Arena 26 × 3 = 78 个字，加上原来的三张表，约 640 字节。metadata 数组按需扩容。

## 失败 trap

失败时先把见证写入固定地址的四个全局，再执行 `ud2`（SIGILL）：

| 全局 | 内容 |
|---|---|
| `g_alloc_fail_request` | 请求字节数 |
| `g_alloc_fail_class` | 档位号（大对象为 25） |
| `g_alloc_fail_cursor` | 失败时的游标 |
| `g_alloc_fail_limit` | 失败时的上限 |

不返回 0，不回退到全局堆。核心转储或调试器可以直接读这四个值。超过 1TB 的请求在进入档位逻辑前就走同一条 trap 路径。

## 失败语义

```text
alloc(n):
    c = class_of(n)
    if class_cursor[c] + class_size(c) <= class_limit[c]:
        p = class_cursor[c]
        class_cursor[c] += class_size(c)
        return p
    if 能从 chunk 链切出新的档位 chunk:
        重试
    trap(request=n, class=c, cursor=class_cursor[c], limit=class_limit[c])
```

trap 后不返回任何值。解释器和 ELF 两条路径行为一致。

## 术语

| 术语 | 含义 | 不再使用 |
|---|---|---|
| region | 内存字节区域 | — |
| SG region | 控制流区域（`SG_FUNC` 等） | 与上者混用 |
| arena | 区域在分配器层的实现 | — |
| arena slot | Arena 池中的一个槽位 | — |
| arena slot free list | 复用整个 slot 的空闲链表 | 单独的 “free list” |
| size class | 动态分配的档位 | 单独的 “class” |

## 实施结果

1. 元数据：`src/stdlib/arena.cr` 已有 `class_base/cursor/limit`、slot 游标、slot 链和四个 trap 见证。`arena_grow_pool` 是公开函数，分配器 stub 直接调用。
2. 发射体：`src/format/elf/elf.cr` 的 `emit_alloc_body` 已实现档位查表、4KB 块切分、档位 25 尾部、连续 slot、mmap extent 和 trap 见证。
3. stub 只在程序链接 arena 库时发射；`g_current_arena` 由静态运行时登记，不能单独作为信号。
4. 回归覆盖：`tests/suite/arena_test.cr`、档位边界、跨档位、超过 64 个 slot 的第二个 segment、2MB / 100MB / 1GB 分配与 reset、pool 上限和 1TB 上限 trap。
5. canary：`ea_mov_imm32` 的编码修复改变了 canary ELF，旧值和新值见 `tools/baseline/canary_values.tsv` 的重锁记录。

## 不包含

1. 对象级释放和块复用。
2. 提前回收点（由区域模型单独推进）。
3. 档位表的热更新或运行时配置。
