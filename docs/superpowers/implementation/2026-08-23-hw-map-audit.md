# 硬件映射设计：决策记录与实施细节

> 对应设计：[2026-08-23-hw-map-design.md](../specs/2026-08-23-hw-map-design.md)

本文保存决策记录、检查规则细节、裸机输出对照、测试阶段和边界。设计正文只保留三层结构、语义表、投影表、检查和发射。

# 统一硬件映射设计：MMIO 管理（语义表、投影表、检查、参考机）

日期：2026-08-23
状态：已批准（brainstorming 会话，三节逐节确认）

## 一、背景与动机

内核路线（`project-book` 第五阶段）需要汇编级和硬件级能力，MMIO 是第一步。标准化的问题在于：x86 有标准手册可循，而 arm64 SoC 的外设各自定义，手册不统一，内存映射因芯片而异。结论是后端需要一个能直接编译的具体硬件目标，即参考机（固定 MMIO 映射的虚拟标准机），真实硬件通过平台投影接入。

先例（均已批准）：
- `crasm`（2026-08-08）：统一汇编层，加特权指令固定集（`mmio_read`/`mmio_write`/`barrier`/...）和平台映射表。
- `alloc_at`（2026-08-13）：MMIO 页以声明方式进入图，获得 `provenance`（`pointer-model.md`）。
- 平台桥抽象（2026-08-16）：语义接口（数学）加后端实现（惯例隔离）。
- 地址 = 映射（2026-08-15 语义定稿）：字节地址不是语义对象，只是经典投影实例。

## 二、决策记录（2026-08-23 brainstorming 确认）

1. 参考机加裸机输出：后端直接编译到固定 MMIO 映射的参考机，产出裸机镜像（无 OS）。
2. 全局生效的接入检查：每次 MMIO 访问都对照映射表验证，包括存在性与地址、宽度匹配、读写权限、`volatile` 顺序性（全面检查）。
3. 描述形态两者结合：语言内声明（主要方式）加外部数据文件（真实 SoC）。
4. 双方都生效：语言层与 crasm 层共用同一全局映射表和同一套检查。
5. 实施顺序：先定义表描述格式，再完成 x64 映射表。
6. 范式无关：设备声明不绑定物理地址，地址绑定下沉到投影层（与“地址 = 映射”定稿一致）。
7. 暂不接入能力模型：能力格 v4（`memory-model-capability-lattice.md`）已发布。M1 的定论是能力不提升为一等公民（语义仍还原到图上，授权归治理层）；本设计不绑定能力模型，与 v4 定位一致。

## 三、架构：三层结构（描述、检查、发射）

### 1. 描述层

语义表（范式无关，不含地址），编译期单例 `g_hw_sem`：

```
g_hw_sem
└── Device
    ├── id（逻辑身份："uart"）
    └── regs[]：Register
        ├── name / offset（设备内逻辑偏移）/ width(8|16|32|64) / perm(ro|wo|rw)
```

没有 `base`，也没有绝对地址。设备由逻辑身份和寄存器结构组成，在量子、分布式、GPU 范式下照常可用。语言声明与数据文件编译进同一张表，形式不同，语义相同。

语言内声明（声明式进图，与 `alloc_at` 同路径）：

```core
device UART {                    // 无 @ 基址，不绑定任何硬件
    DATA   : u8  @ 0x00, rw;
    STATUS : u8  @ 0x04, ro;
}
```

数据文件（真实 SoC 使用，复用 `stdlib/toml.cr` 解析器）：

```toml
[[device]]
name = "uart" # 无 base 字段
[[device.reg]]
name = "data"; offset = 0x00; width = 8; perm = "rw"
```

投影表（经典地址绑定，属于后端实现选择）：`device` id 对应物理基址。

```
uart -> 0x3F200000 （x64 参考机，编译器内置）
uart -> 0xFE201000 （真实平台：树莓派，数据文件导入）
uart -> 0x09000000 （真实平台：QEMU virt，数据文件导入）
```

x64 映射表是投影表的第一份实例。使用同一份语义表和不同的投影表，可以把同一程序编译到不同硬件。访问 `UART.DATA` 在语义上是访问逻辑设备内的逻辑寄存器，只有发射时才解析为基址加偏移的经典 `load`/`store`。

### 2. 检查层

`hw_check` pass 在 HDFG 上运行（与 `ptr_analysis` / `region_check` / `provenance_verify` 并列），消费 `g_hw_sem`。访问形式：语言层的 `UART.DATA` 下降为携带 `device` 和 `reg` 引用的 IR 节点（`IR_MMIO_READ/WRITE`）。

| 检查 | 规则 | 违反示例 |
|---|---|---|
| 存在性 | 访问的设备/寄存器必须存在于语义表 | `UART.DATA` 表里没有 DATA |
| 宽度匹配 | 访问宽度 == 寄存器声明宽度 | 32 位写 u8 寄存器 |
| 读写权限 | ro 不被写、wo 不被读 | `UART.STATUS = 1` |
| volatile 顺序性 | MMIO 节点不可消除/不可重排/不可合并 | 优化器 CSE 两个 MMIO 读 |

全部检查在编译期完成，运行期没有开销。

`crasm` 双方都生效，规则是“可解析即检查”：`crasm` 的 `mmio_read(addr)` / `mmio_write(addr, val)` 中，地址若经投影表静态解析回语义寄存器，四项检查照常执行；解析不到（动态地址）则作为 `unsafe` 外部入口（与 0x 字面量同角色，见 `pointer-model.md`）。

```
mmio_read(0x3F200000) // 投影解析得到 UART.DATA，执行四项检查
mmio_read(addr_var) // 解析不到，属于 unsafe 边界（检查不适用）
```

`volatile` 实现：IR 节点带 `volatile` 标记；`pass.cr`（常量折叠）、`opt.cr`（CSE/regalloc/调度）一律不消除、不重排、不合并 MMIO 读写。每个 MMIO 读都是副作用，读后不用也必须保留。发射为普通 `load`/`store` 到解析地址；跨核和跨硬件的顺序保障由 `crasm` 的 `barrier` 负责，不混入本层。

错误报告：走现有 `diag` 体系，新增错误码（`E_MMIO_UNKNOWN_REG` / `E_MMIO_WIDTH_MISMATCH` / `E_MMIO_PERM` / `E_MMIO_VOLATILE`），实现时在 `error-codes` 规格里确定归属。

### 3. 发射层

参考机定义（x64 投影表第一份实例）：编译器内置投影表（如 `src/arch/x86_64/hw_ref.toml`），第一版外设范围只有 UART（能打印即可完成最小验证完整流程）；`timer`、中断控制器、GPIO 后续扩展。

发射流程：

```
IR_MMIO_READ/WRITE（语义引用 device+reg）
  投影解析：经典地址 = 投影基址 + 逻辑偏移
  ELF 后端：直接 load/store 到该地址（volatile 标记抑制优化）
```

裸机输出模式（区别于现有 Linux 用户态输出）：

| | 现有（Linux ELF） | 裸机模式（新增，`corearch --bare`） |
|---|---|---|
| 入口 | `_start`（rt.s） | 同 `_start`，无 OS 依赖 |
| 动态链接 | PLT/GOT（ld.cr） | 无，纯静态 |
| 全局变量寻址 | RIP-relative | 直接绝对地址（固定加载地址，如 0x100000） |
| 加载 | 用户态加载器 | QEMU multiboot / flat binary |

复用现有 `elf.cr` / `instr.cr` / `resolve.cr`，只改链接和入口装配。

## 四、边界

- `crasm` 的 `mmio_read(addr)` 使用显式地址时，属于 `unsafe` 外部入口（不可静态解析时），与 0x 字面量同角色，不与语义层混淆。
- 检查全部在编译期完成，运行期没有开销。
- 语言层的 `device` 是声明，不是运行时对象，映射表只存在于编译期。

## 五、测试与阶段目标

1. 语义表构建：`device` 声明解析加 `toml` 导入，得到同一张表（单测）。
2. `hw_check` pass 加四项检查测试（`tests/selfhost` 实现方式）。
3. 投影表加地址解析（可解析即检查路径测试）。
4. x64 参考机投影表加 `IR_MMIO` 发射。
5. `corearch --bare` 裸机输出。
6. 端到端：`.cr`（`device` UART 声明和打印）经 `--bare` 编译后在 QEMU 运行，断言串口输出（无 QEMU 环境时跳过）。
7. （后补）真实平台投影表数据文件（树莓派、QEMU virt）。

回归：现有测试全部保持通过（`test_pipeline` / `test_compile` / `test_pointer_safety` 等）。

## 六、明确不做（YAGNI）

- 中断、定时器、GPIO：参考机第一版只有 UART
- 页表、MMU、内存管理：直接使用物理地址，单核
- 能力模型接入：能力格 v4 已发布（能力不提升为一等公民，语义仍还原到图上）；本设计按 v4 定位评估
- 设备语义注解（表项携带规约语义）：留给规约层，后续展开

## 七、参考

- `docs/crasm.md`、`docs/superpowers/specs/2026-08-08-crasm-design.md`（特权指令固定集、平台映射表）
- `docs/pointer-model.md`（`alloc_at` 声明式进图、`unsafe` 边界、地址 = 映射）
- `docs/superpowers/specs/2026-08-16-platform-abstract-design.md`（语义接口加后端实现原则）
- `docs/memory-model-capability-lattice.md`（能力格 v4，已发布，能力不提升为一等公民）
