# Arena size class 规格

> 状态：已批准，待实施
> 日期：2026-10-28
> 关联：`docs/maintainer/design/region-model.md` 第 4 节 · `docs/superpowers/specs/2026-07-28-arena-model-design.md`

## 概述

动态大小的分配走 size class 的分档子区域。每个档位只放同一大小的块，块大小是档位值，分配是档位内的游标推进。回收仍然只有区域整体重置，没有对象级释放。分配失败是硬失败（trap），不返回 0。

## 决定

1. 静态已知大小的分配不进档位，走精确 bump。
2. 动态大小的分配按档位向上取整：`class = round_up_class(n)`，在档位子区域内 bump。
3. 档位表使用 1.25 倍步长，从 16 字节到 8192 字节，共 25 档。取整浪费上限 20%。
   `region-model.md` 里写的 12.5% 对应 1.125 倍步长，档位数翻倍；本规格先用 1.25 倍，档位表是数据，后续可以换表而不用改分配路径。
4. 超过 8192 字节的对象走大对象路径：精确 bump，不取整。
5. 每个档位子区域从所属 Arena 的 chunk 链上取空间。档位子区域自己只做 bump，不做释放。
6. 回收只有一种：`arena_reset(ai)` 清空该 Arena 的全部档位子区域和大对象区。
7. 分配失败触发 trap，带四个值：请求字节数、档位、当前游标、当前上限。禁止返回 0，禁止静默降级到全局堆。
8. 全局堆只服务 `arena_init` 和 chunk 链的扩展；它的耗尽同样是 trap。

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

表的上限是 8192：最后一档覆盖 3361 到 8192。超过 8192 走大对象路径。

## 布局

每个 Arena 维护两组状态：

| 状态 | 含义 |
|---|---|
| `class_cursor[c]` | 档位 c 的当前游标 |
| `class_limit[c]` | 档位 c 的当前上限 |
| `large_cursor` | 大对象的游标 |
| `large_limit` | 大对象的上限 |

档位子区域从 Arena 的 chunk 链上切分：首次使用某档位时切一个 chunk，把 `class_cursor[c]` 指到 chunk 起点，`class_limit[c]` 指到终点。

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

## 实施顺序

1. 元数据：`arena.cr` 增加档位游标/上限数组和大对象游标；cap 按档位数扩展。
2. 解释器：`interp.cr` 的 `alloc` 走档位路径；失败 trap。
3. ELF 发射体：`elf.cr` 的 `emit_alloc_body` 增加档位查表与档位游标；失败 trap。
4. 测试：档位取整、跨档位、chunk 扩展、失败 trap、冷/暖一致。
5. canary：ELF 变化后按 `REBUILD.md` 重锁。

## 不包含

1. 对象级释放和块复用。
2. 提前回收点（由区域模型单独推进）。
3. 档位表的热更新或运行时配置。
