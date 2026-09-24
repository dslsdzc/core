# @hotpatch 滚动更新设计

## 概述

Core 编译器的滚动更新（hotpatch）机制。通过 `@hotpatch` 注解支持函数的多版本共存、按比例流量分发、渐进式 rollout 和排水回收。

基于现有子图边界 + Arena 隔离，不需要额外运行时。

## 核心原则

- **同名函数多版本共存**：`@hotpatch(ver=N)` 标记的函数允许同名，签名必须一致
- **编译期路由节点**：调用点 emit `IR_HOTPATCH_ROUTE`，运行时根据配置选择版本
- **运行时配置**：`.hotpatch.toml` 配置文件，SIGHUP 信号重读
- **排水安全**：`in_flight` 计数追踪进行中请求，drain 完成后回收旧版本

## IR 指令

```core
IR_HOTPATCH_ROUTE : int = 39;  // dest=result_var, s1=fn_name_ni, s2=first_arg, s3=arg_count
```

`IR_HOTPATCH_ROUTE` 在调用点替代 `IR_CALL`。后端将其编译为：

1. 加载 `g_hotpatch_config[fn_name]` 配置
2. 根据权重随机数选择版本
3. 跳转到对应版本的函数体
4. 函数入口 `g_hotpatch_inflight[fn_name_vN]++`
5. 函数返回前 `g_hotpatch_inflight[fn_name_vN]--`

## 解析器

**新增关键字**：`@hotpatch` 作为 `@` 内建原语扩展。

```core
@hotpatch(ver=1) fn handle(x: dyn) -> dyn { body1 }
@hotpatch(ver=2) fn handle(x: dyn) -> dyn { body2 }
```

解析器：
- `@hotpatch(...)` → `EXPR_AT("hotpatch", args)` 处理
- 参数解析：`ver=1` 表示版本号，`canary="5%"` 表示金丝雀比例
- 内部存储：函数符号表允许同名条目，附加版本号标签

## 类型检查器

允许同名函数共存的条件：
1. 所有版本都有 `@hotpatch` 注解
2. 所有版本的签名完全相同（参数类型 + 返回类型）
3. 版本号唯一且递增

## IR 生成

```core
// 调用点 emit 路由而非直接 call
if is_hotpatch(fn_name_ni) {
    emit(IR_HOTPATCH_ROUTE, dest, fn_name_ni, first_arg, arg_count);
} else {
    emit(IR_CALL, dest, first_arg, arg_count, fn_name_ni, 0);
}
```

## 运行时

### 全局状态

```core
// 由 ELF 后端 emit，与 g_current_arena 同级
g_hp_config  : string, mut;  // 序列化配置表
g_hp_inflight : string, mut;  // in_flight 计数数组
```

### 配置格式（`.hotpatch.toml`）

```toml
[hotpatch.handle]
canary = 5          # 5% 流量到 canary 版本

# 或 rollout 阶段
[hotpatch.handle]
rollout = 50        # 50% 流量到新版本

# 或 100% + drain
[hotpatch.handle]
rollout = 100
drain = true        # 旧版本开始排水
```

### 信号处理

SIGHUP 信号 → 重新读取 `.hotpatch.toml` → 更新 `g_hp_config`。

### Drain 流程

```
1. 配置更新将版本 v1 标记为 drain
2. 路由节点停止向 v1 分发新请求
3. 函数入口 g_hp_inflight[fn_v1]++
4. 函数返回前 g_hp_inflight[fn_v1]--
5. 后台/定时检查 in_flight 是否为 0
6. 为 0 → 回收 v1 的子图数据
```

## 实现清单

| # | 文件 | 改动 |
|---|------|------|
| 1 | `src/compiler/ast.cr` | 新增 `IR_HOTPATCH_ROUTE`(39) |
| 2 | `src/compiler/parser.cr` | 解析 `@hotpatch(args)` 参数 |
| 3 | `src/compiler/checker.cr` | 允许同名函数 + 签名一致性检查 |
| 4 | `src/compiler/ir_gen.cr` | `IR_HOTPATCH_ROUTE` emit |
| 5 | `src/compiler/dataflow.cr` | 注册 opcode |
| 6 | `src/compiler/opt.cr` | 跳过 |
| 7 | `src/compiler/ccr_io.cr` | 序列化 |
| 8 | `src/arch/linux/ld/elf.cr` | 运行时全局变量 + 信号处理 |
| 9 | `src/arch/linux/ld/instr.cr` | `IR_HOTPATCH_ROUTE` 编码 |
| 10 | `src/arch/linux/ld/sizes.cr` | 大小估算 |
| 11 | `src/runtime/rt.cr` | 运行时变量声明 |
| 12 | `tests/suite/hotpatch_test.cr` | 测试 |
