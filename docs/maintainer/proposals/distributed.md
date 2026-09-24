# Core 分布式

> 定位：受众 = 维护者/贡献者；状态 = **proposal（核心已备，运行时未实现）**——go/await/子图边界就位；跨机器传输/QUIC/认证/重试未实现。

## 设计原则

- **图跨机器。** `go` 默认在本地创建节点，加上 `@("node")` 目标即为远程节点。
- **编译时决定，运行时只执行。** 图上哪些边是远程的，编译期即已确定；序列化、认证、重试代码由编译器生成，运行时只负责执行。
- **接口兼容够用。** 版本号由人维护，编译器只检查接口签名。

## 语法

`go @("node") fn()` 在目标节点上创建一个远程节点。

```core
flow worker(id: int) -> int {
    return compute(id);
}

w1 := go worker(1);              // 本地——和现在一样
w2 := go @("server2") worker(2); // 远程——新节点在 server2
v := await w1 + await w2;        // 等两边结果
```

## 图上的表示

```
                    ┌── server1 ──┐
go worker(1) ──────→│ compute(1)  │──→ await ─┐
                    └─────────────┘           │
                                              ├──→ ADD
                    ┌── server2 ──┐           │
go @("server2") ───→│ compute(2)  │──→ await ─┘
  worker(2)         │ (远程节点)   │
                    └─────────────┘
```

## 协议

远程节点间使用 QUIC 通信。

```
go @("server2") fn()
   ↓
编译器生成的代码：
   QUIC 连接（0-RTT，自带 TLS）
   每个远程 go 一条独立 QUIC stream
   断线重连由 QUIC connection migration 处理
```

QUIC 提供的能力：

| 需求 | QUIC 的应对 |
|------|-----------|
| 加密 | 自带 TLS 1.3 |
| 多路复用 | 单连接多条 stream，互不阻塞 |
| 连接迁移 | 断线自动重连，stream 不中断 |
| 0-RTT | 首次握手后免往返 |

## 跨节点数据传输

```core
flow process(data: [int]) -> int {
    return sum(data);
}

big_data := read_file("1gb.bin");
result := go @("server2") process(big_data);
```

编译器看图即知 `data` 跨节点。大块数据不直接走网络：编译器生成共享存储读写的代码（由部署配置指定）：

```toml
[data]
backend = "s3"           # 也可以在部署配置中声明共享存储路径
cache = "/mnt/shared"
```

代码不感知数据在本地还是远程：编译器在边界插入读共享存储的逻辑，不走网络。

这也是平台桥抽象在分布式场景的体现。`read_file` 的语义是读取文件流（字节序列），物理存储后端（本地文件系统、共享存储 s3、网络）是后端实现，由部署配置决定；代码只见流语义，不见物理实现。

## 接口兼容

```core
go @("server2") worker(1);
```

编译器检查 server2 上暴露的接口签名与调用处的签名是否匹配：

| 调用处 | 远端接口 | 结果 |
|--------|---------|------|
| `fn(x: int) -> int` | `fn(x: int) -> int` |  匹配 |
| `fn(x: int) -> int` | `fn(x: int) -> string` |  不匹配 |
| `fn(x: int) -> int` | `fn(x: dyn) -> int` |  dyn 兼容 |

不需要版本号。接口签名一致即可运行；版本号由人控制，编译器只检查接口类型。

## 不安全与恢复

远程节点断开时：

```
go @("server2") worker(1)
      ↓
server2 挂了
      ↓
QUIC 检测连接断开（内置心跳）
      ↓
编译时生成的超时重试代码接逾
      ↓
部署配置可以指定重试策略
```

```toml
[cluster]
retry = 3
timeout = "5s"
```

未设置超时时，代码无法感知远端失效；超时由 QUIC 的心跳与编译器生成的远程 await 超时逻辑共同保证。

## 认证

```
go @("server2") read_file("/etc/passwd");
```

远程节点不接受来自其他节点的未授权请求。认证模型与 FFI 一致：编译器在生成的 QUIC 连接建立时插入认证 token。

```
首次连接：token 交换（由部署配置提供）
后续复用：QUIC 连接保持，不需要重复认证
失败：返回 auth 错误，图上的远程节点标记为失败
```

## 部署配置

```toml
[cluster]
nodes = ["server1:7200", "server2:7200", "server3:7200"]

[data]
backend = "s3"

[auth]
token = "..."
```

## 当前状态

设计完成。核心机制已就位（`go`、`await`、子图边界），但跨机器传输、QUIC 连接、认证、重试等运行时部分未实现。
