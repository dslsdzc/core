# Core Spec IR Schema — 规约约束层 (.csr)

## 概述

`.csr` 是 `.cir`（HDFG）的规约约束扩展的二进制序列化格式。它不是独立的 IR，而是 `.cir` 的补充——携带规约约束元数据（check/ensure/invariant/标签），与 `.cir` 的 DFNode 数组通过节点索引精确关联。

```
.cir（HDFG） = DFNode[] + DFEdge[] + 符号表
.csr（规约层）   = TagNode[] + 符号引用表 + 自动推导标签元数据
                      ↑
                 通过 target_node 字段指向 DFNode 索引
```

验证工具同时加载 `.cir` + `.csr`，获取完整的程序语义和规约约束。

## 格式（v1）

### 整体布局

```
[文件头：32 字节]
[约束节点数组：tag_count × 40 字节]
[符号引用表：变长]
[函数约束映射：func_count × 8 字节]
[字符串表：变长]
```

### 文件头（32 字节）

| 偏移 | 大小 | 字段 | 说明 |
|------|------|------|------|
| 0 | 4 | magic | `0x31525343`（ASCII `CSR1`） |
| 4 | 4 | version | 版本号，当前为 1 |
| 8 | 4 | tag_count | 约束节点数量 |
| 12 | 4 | func_count | 函数数量 |
| 16 | 4 | symbol_ref_count | 符号引用数量 |
| 20 | 4 | str_count | 字符串表条目数 |
| 24 | 8 | reserved | 保留 |

### 约束节点（TagNode，40 字节）

| 偏移 | 大小 | 字段 | 说明 |
|------|------|------|------|
| 0 | 4 | tag_kind | 约束类型（见下文） |
| 4 | 4 | target_node | 绑定的 DFNode 索引（-1 = 全局/类型级） |
| 8 | 4 | target_symbol | 绑定的符号引用索引（-1 = 无） |
| 12 | 4 | condition_node | 条件表达式所在的 DFNode 索引 |
| 16 | 4 | status | 验证状态：0=unproven, 1=auto_proven, 2=user_proven |
| 20 | 4 | source_line | 源文件行号 |
| 24 | 4 | source_col | 源文件列号 |
| 28 | 4 | name_idx | 标签/约束名在字符串表中的索引（-1 = 匿名） |
| 32 | 8 | reserved | 保留 |

**约束类型（tag_kind）：**

| 值 | 名称 | 说明 |
|----|------|------|
| 0 | TAG_AUTO_LABEL | 编译器自动推导的标签 |
| 1 | TAG_CHECK | 前置条件 |
| 2 | TAG_ENSURE | 后置条件 |
| 3 | TAG_INVARIANT | 类型不变量 |
| 4 | TAG_LOOP_INVARIANT | 循环不变量 |
| 5 | TAG_VARIANT | 终止度量 |
| 6 | TAG_SPEC_FN | 检查函数引用 |
| 7 | TAG_USER_TAG | 自定义标签 |

### 符号引用表

每个条目 8 字节：

| 偏移 | 大小 | 字段 | 说明 |
|------|------|------|------|
| 0 | 4 | name_idx | 符号名在字符串表中的索引 |
| 4 | 1 | symbol_kind | 0=func, 1=var, 2=type, 3=field, 4=module |
| 5 | 3 | reserved | 保留 |

### 函数约束映射

快速定位每个函数的约束列表：

| 偏移 | 大小 | 字段 | 说明 |
|------|------|------|------|
| 0 | 4 | tag_start | 该函数在 TagNode 数组中的起始索引 |
| 4 | 4 | tag_count | 该函数的 TagNode 数量 |

### 字符串表

同 `.ccr` 格式：`count` 个 `[len(4) + data(len)]`。

## 与 `.cir` 的关系

```
.cir 负责：程序语义（HDFG）
.csr 负责：规约约束（图上的标注）

关联方式：TagNode.target_node → DFNode 索引
          TagNode.target_symbol → 符号引用索引
          TagNode.condition_node → 条件表达式的 DFNode 索引

加载方式：load_cir() + load_csr() → 验证工具合并两份数据
```

编译器只在 `-s` 模式下输出 `.csr`（与 `.cir` 成对）。缺少 `.csr` 不影响代码生成（`.ccr` 不依赖规约），只影响验证。

---

## 与验证架构（spec-design v2）的关系

本文档描述的 `.csr` 二进制格式（v1）为**约束存储层**，在验证体系 v2 中保持不变——spec-design v2（CIC 内核 + SMT 证书架构）引入的验证管线消费的正是本格式：

- **约束存储**（本 schema）：`.csr` 的 TagNode[] 携带 check/ensure/invariant/标签元数据，与 `.cir` 的 DFNode 通过 `target_node`/`condition_node` 索引关联
- **验证执行**（spec-design v2）：规约表达式（`#check`/`#ensure`/`spec fn` 体）经**翻译桥**编译为 CIC 项，走 CIC 内核 + SMT 证书双通道；`.csr` 的 `status` 字段（0=unproven, 1=auto_proven, 2=user_proven）承接验证结果
- **自动推导**：编译器从 `.cir` 图结构推导的标签（`#pure`/`#terminating`/`#safe_index` 等）写入 `.csr`（status=auto_proven）

即：**本 schema 定义"约束存在哪里"，spec-design v2 定义"约束如何被验证"**——两者分层，v2 不改变本格式。完整验证工作流见 `docs/maintainer/design/spec-design.md`。
