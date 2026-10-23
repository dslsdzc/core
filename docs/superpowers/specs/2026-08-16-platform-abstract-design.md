# 平台桥抽象设计：I/O 流、随机、哈希、时钟

日期：2026-08-16
状态：已批准（brainstorming-lite；模式无新决策，直接定稿）

## 一、原则

1. 语义接口（数学）加后端实现（惯例隔离）：语言层只呈现数学语义接口，系统调用、熵源和算法选择全部隔离到后端实现。
2. 现有 API 零变化（“不敢自动”兼容原则）：`print`/`println`/`read_file`/`write_file`/`str_hash` 等保持原样，抽象是新增的接口层。
3. 小而准：四个抽象各有一个语义接口和一个后端实现，不做非阻塞 IO、加密级随机、异步流（YAGNI）。

## 二、四个抽象

### 1. I/O 流

```
语义：流 = 字节序列（数学：序列/流，coinductive 域）
 程序 IO = 流转导器（transducer）：(输入流) -> (输出流)
 输入输出是同一数学对象（流）的两端，输出 = 对世界的输入
 验证意义：I/O 程序语义 = 流变换，规约可描述流性质（输入流性质 -> 输出流性质），
 I/O 不是无法验证的部分，而是一等公民语义
接口：输入流 read(buf) -> int（读取字节数）
 输出流 write(buf, len) -> int
 可关闭 close()
实现：文件流 / 终端流（系统调用隔离）
兼容：print/println/read_file/write_file 保持
```

### 2. 随机

```
语义：概率分布（数学）
接口：uniform_int(a, b) -> int（闭区间均匀分布）
 seed(s: int)
实现：熵源 = 后端（getrandom 系统调用；回退时间种子）
兼容：新增（math.cr 是 stub，无既有 API）
```

### 3. 哈希

```
语义：散列函数（数学）
接口：hash_bytes(buf, len) -> u64（算法可替换）
 hash_str(s) -> u64（转发 str_hash 语义）
实现：默认算法（现有 str_hash 同族）；算法选择后端/未来可替换
兼容：str_hash 保持
```

### 4. 时钟

```
语义：单调时间序（数学）
接口：now_monotonic() -> int（毫秒）
 sleep_ms(ms)
实现：clock_gettime / nanosleep（系统调用隔离）
兼容：新增
```

## 三、明确不做（YAGNI）

- 非阻塞/异步 I/O、事件循环
- 加密级随机（密码学另议）
- 跨平台文件系统抽象（目录遍历/路径，更大的议题，后议）
- 流组合子库（`map`/`filter` 流变换，用户层可做）

## 四、验证

- 现有测试全部保持通过（`test_pipeline`/`test_compile` 等回归）
- 新接口快速验证：流读写往返、`uniform_int` 分布范围、`hash` 确定性、时钟单调
- 与 LSP 并行（`tests/selfhost/test_lsp.py` 不回归）
