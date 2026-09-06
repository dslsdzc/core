# 示例集

> 定位:受众 = 开发者;状态 = active。仓库 examples/ 的可跑程序,按复杂度排列。

## 运行方式

```bash
./build/corec build examples/<name>/main.cr -o /tmp/<name> --static
/tmp/<name>
```

或先检查:`./build/corec check examples/<name>/main.cr`

## 示例清单

| 示例 | 内容 | 看点 |
|---|---|---|
| [add](../examples/add/main.cr) | 两数相加,main 返回退出码 | 最小完整程序——第一个程序从这里开始 |
| [complex](../examples/complex/main.cr) | 复数运算 | 结构体 + 函数组合 |
| [pi](../examples/pi/main.cr) | 圆周率计算 | 数值循环(带 deploy.toml 的部署配置示例) |
| [load_balancer](../examples/load_balancer/main.cr) | 负载均衡器 | 并发/任务分发方向(含 spec/ 规约骨架) |

> 注:examples/hello/ 目前是空骨架(未填 main)——忽略或用 add/ 起步。

## 更多示例:测试套件(tests/suite/)

仓库测试套件的 .cr 文件是按主题组织的可跑示例(覆盖更广):

| 主题 | 文件 |
|---|---|
| 基础/控制流 | test_control_flow.cr、generics_test.cr |
| 结构体/枚举 | at_test_struct.cr 等 at_test*.cr(@ 内建 + 结构) |
| 并发 | go_test.cr、chan_test.cr、conc_test.cr |
| 动态类型 | dyn_test.cr、dex_test.cr |
| 内存/指针 | ptr_arith.cr、ptr_ref_first.cr、arena_test.cr |
| FFI/热补丁/惰性 | ffi_test.cr、hotpatch_test.cr、lazy_test.cr |

> 注:套件文件可能依赖测试驱动(检查点/期望输出)——作示例阅读时关注语言用法,运行请走测试入口(见 `../maintainer/testing.md`)。

## 配套

- 每个示例目录可能带 `.cir`/`.ccr`/`.s`/`prog`——构建副产物,手工分步调试时对照用
- 完整编译产物链:`.cr` →(corec)→ `.cir`(图形态)+ `.ccr`(格形态)→(corearch)→ ELF

## 建议下一步

写自己的程序时:类型检查循环(`check`)先行,`run` 试小段,`build` 出产物。
语法速查见 [syntax.md](syntax.md);构建与命令见 [quickstart.md](quickstart.md)。
