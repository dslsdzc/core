# x86 实例化：三轴组合

## 概述

x86 实例是三个轴的组合：

```text
架构 x86_64 × 格式 ELF × OS Linux
```

组合根目录必须显式包含三部分：`src/targets/x86_64-linux-elf/`；`Core.toml` 同时记录 `arch = "x86_64"`、`system = "linux"`、`container = "elf"`。旧的两段名 `x86_64-linux` 只表示架构和系统，不能作为完整目标名。

架构轴提供指令、寄存器、编码和序列。格式轴提供容器、段、重定位和链接。OS 轴提供系统调用、入口和 ABI 约定。

三个轴都使用同一模式：通用机制加特化参数。换实例就是换轴组合。例如 `arm64 × ELF × Linux` 是换架构轴，`x86_64 × PE × Windows` 是换格式和 OS 轴。内核和其余轴零改动。

设计状态：批次 1 结构已实施，批次 2 参数化和批次 3 能力未启动。执行注记、提交链和挂账见 `docs/superpowers/implementation/2026-09-10-x86-instance-audit.md`。

## 三轴目录

```text
src/arch/x86_64/    架构轴
    instr.cr        指令编码
    sizes.cr        尺寸
    regalloc.cr     寄存器分配 CAG
    frame.cr        帧布局
    tag2l.cr        tag 和 2L 编码
    core-x86.toml   表数据

src/format/elf/     格式轴
    elf.cr          容器、段、程序头
    resolve.cr      重定位
    ld.cr           链接机制

src/os/linux/       OS 轴
    syscall.cr      系统调用约定
    callseq.cr      参数传递和调用序列
    entry.cr        入口和启动集成

src/arch/hit/       表引擎
src/lattice/        语义内核
src/kernel/         验证内核
src/runtime/        运行时
```

ABI 是交叉轴：机器寄存器集来自架构轴，调用约定来自 OS 轴。`callseq` 归 OS 轴，参数寄存器表引用架构轴。

序列算法文件化是本设计的实质内容。帧、调用、系统调用和入口原来散在 `elf.cr` 和 `instr.cr` 中，现在显式成文件，成为实例算法。

目录平铺，不设子目录。当前文件规模不值得增加 concat 和导入成本，文件增多后再分。

## 构建清单

构建清单按轴分段：

```text
common_files
kernel_files
non_x86 前端
arch_x86_64_files
format_elf_files
os_linux_files
hit 引擎
```

concat 按确定顺序组合。

守卫：

1. 清单文件存在性断言，防止路径变化。
2. 检查目录中新文件没有进入清单，在构建设置期提示。
3. 构建日志中 `error[` 计数非零即失败。

其他 concat 复用同一分段机制。

## 寄存器分配切分

| 阶段 | 内容 | 归属 |
|---|---|---|
| 1 门控扫描 | DEX、DYN、UNIT、CONST、REF、I2F 排除，涉及 XMM 路径和立即数编码 | 实例 |
| 2 回边探测和携带值标记 | 跨回边存在性和条件定值差分 | 内核候选，需求推导 |
| 3 候选窗口构建 | 区间和扩窗 | 内核候选，需求推导 |
| 4 First Fit 搜索 | 不透明位置的搜索 | 待定。搜索泛型，可用位置集来自实例域 |
| 5 终分配 | 每块最多 5 对，写 meta，块格式编码 | 实例 |

实施节奏：需求推导上收是原则记录，按需执行。实例 B 出现前收益低。本设计先做物理侧归位和参数化。

## 能力演进

spill 和移除是独立能力批次。激活点是实例声明 `needs_eviction=1`，触发判定 3 的引擎扩展。

双向契约有三段：

1. 实例到内核：位置登记 `kern_loc_*` 已建立。移除和替换事件登记预留 API 位。
2. 内核到实例：判定输出，包括 violations 和共存证据，已建立。持久条目的 home 需求查询预留接口位。
3. 判定 3 和 4 的引擎实现：`needs_* = 1` 时扩展。当前声明为 `{0,0}`。

引入 spill 会同时解锁判定 4：调用点失效，检查被调用者保存集和调用点未维护条目的配对。

## 检查

结构批次，即批次 1 和 2：

- 行为零变化。
- 全回归通过。
- `backend_bootstrap` stage 链逐字节相同。
- `ccr_v7` 产物逐字节相同。
- 完整自举 guard 通过。

能力批次，即批次 3：

- 行为等价，不逐字节复刻。
- 检查投影正确性。
- M2 复启时同步修订检查。

## 演进批次

1. 批次 1 结构：三轴目录重组，序列算法文件化，表数据迁到架构轴，构建清单分段和守卫。已实施，检查为行为零变化。
2. 批次 2 参数化：序列算法按实例边界参数化，处理双入口分歧。
3. 批次 3 能力：spill 和移除，判定 3、4 激活，双向契约第三段，M2 复启。
4. 远期实例 B：arm64 或非经典实例，验证换轴零内核改动。

## 挂账和风险

- M2 交互：HIT 表数据迁到架构轴，表引擎留在原位。批次 1 只搬定位面，M2 仍挂起。复启时表定位已经解决。
- 文件移动不改变产物。汇编后端没有 `.loc`，注释变化不影响字节。
- `main.cr` 双入口：批次 2 处理，注册收敛或显式留档。批次 1 只搬位置，不收敛 flag 面。
- 架构特化参数位，例如格式层的 machine 和 reloc 类型，批次 1 只搬迁，不建参数机制。
- 前端多参数误编译、`IR_CALL_EXTERN` 多整数参数语义缺口、ELF 格式化手写系统调用，这三项已登记，属于批次 2 或后续专项。
- 本设计不承诺需求推导上收、spill 和移除的实施、格式轴跨 OS 的全面参数化。

## 关联

- 执行记录和批次 1 注记：`docs/superpowers/implementation/2026-09-10-x86-instance-audit.md`
- 目标架构：`docs/superpowers/specs/2026-09-09-corearch-rewrite-design.md`
- 格层边界：`docs/superpowers/specs/2026-09-09-lattice-encoding-boundary-design.md`
- 内核完备化：`docs/superpowers/specs/2026-09-10-corearch-kernel-completion-design.md`
- 寄存器分配：`docs/maintainer/design/regalloc-cache-mapping.md`
- 硬件接口表：`docs/superpowers/specs/2026-09-05-hardware-interface-table.md`
