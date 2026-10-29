# Allocator 代码生成设计

> 状态：待批准
> 日期：2026-10-29
> 关联：`docs/superpowers/specs/2026-10-29-arena-boundaries-design.md` · `docs/superpowers/specs/2026-10-28-stub-regalloc.md`

## 目标

把 `alloc` 的机器码从 `src/format/elf/elf.cr` 的手写字节改成由 Core 源码编译
出的 raw blob：

1. allocator 的 class、slot、extent、全局堆逻辑写在受限 Core 源码里。
2. `elf_gen` 只保留一个极小 trampoline、blob 拷贝和重定位表。
3. 用 clang/LLVM 编译的 C 参考实现做差分验证，不作为构建依赖。

## 非目标

1. 用 LLVM 替换整个 corearch 后端。
2. 改变 `alloc(size) -> string` 的公开 ABI。
3. 引入运行期链接器、GOT/PLT 或动态符号表。
4. 在 allocator body 内调用 `alloc`。

## 现状

`alloc` 是 frontend builtin，不是 Core 函数：

- `src/runtime/runtime_frontend_abi.cr` 注册 `alloc`。
- `alloc(n)` 降低成 `IR_CALL`，返回内部 `TI_UNIT` 指针哨兵。
- `src/arch/x86_64/instr.cr` 在 tagged 模式下先把实参转成 raw word。
- `src/format/elf/elf.cr` 的 `emit_alloc_body` / `emit_alloc_body_simple` 直接
  写 x86-64 字节，所有跳转、寄存器保存、RIP 位移都在这里手工维护。
- `src/runtime/bigint_blob.cr` 已经证明“Python bootstrap → `.o` → 抽取
  `.text/.rodata/.data` → 拷进代码段”的路线可用。

手写字节的问题是编码和帧维护错误不会被编译器发现。最近修复的 SIB、栈上多压
寄存器、tagged/raw 偏移都属于这一类。

## 架构

```text
src/runtime/alloc_body.cr
        │  Python bootstrap（raw 语义）
        ▼
build/alloc_blob/alloc_body.o
        │  tools/gen_alloc_blob.py
        ▼
src/runtime/alloc_blob.cr        （字节 + 符号表 + 重定位表）
        │  corearch/elf_gen
        ▼
目标 ELF：
  alloc_start:  trampoline（mov rsi, heap_start; jmp alloc_body）
  blob:         alloc_simple / alloc_arena 的 .text/.rodata/.data
  BSS:          现有 g_heap_*、g_arena_* 全局，保持不变
```

### alloc_body.cr

新增 `src/runtime/alloc_body.cr`，只包含：

- `fn alloc_simple(size: int, heap_start: string) -> string`
- `fn alloc_arena(size: int, heap_start: string) -> string`

约束：

1. 用 raw 机器字。Python bootstrap 以 `bigint_mode=False` 编译。
2. 不调用 `alloc`、`println`、`str_*` 或任何可能分配的函数。
3. 只通过 `cell_load` / `cell_store` 读写内存。生成器在源文件前拼接
   `cell_load` / `cell_store` 的 raw 实现，和 bigint blob 相同。
4. 直接引用现有全局：`g_heap_ptr`、`g_heap_end`、`g_arena_scalars`、
   `g_arena_scalars_ready`、`g_arena_suspend`、`g_arena_slot`、
   `g_arena_slot_cursor`、`g_arena_slot_next`、`g_arena_static`、
   `g_arena_sizes`、`g_arena_cursors`、`g_segment_base`、`g_class_base`、
   `g_class_cursor`、`g_class_limit`、`g_class_lookup`、`g_class_sizes`、
   `g_arena_large_head`、`g_arena_large_count`、`g_alloc_fail_*`、
   `g_alloc_home_idx`。
   这些声明不写初值，编译后落在 `.bss`；生成器把它们当作外部全局，不拷进
   blob。生成器维护一份固定的外部全局 allowlist，不在表内的 `.bss` 符号
   直接失败，防止 body 偷偷带入本地状态。
5. 允许调用 `heap_expand` 和 `arena_grow_pool`。它们是外部函数，生成器记录
   call relocation，`elf_gen` 回填到现有函数地址。
6. `heap_start` 作为第二个参数传入，不在 body 内计算 `bss_va`。
7. 失败路径先写 `g_alloc_fail_*` 见证，再用
   `syscall3(60, 132, 0, 0)` 退出。shell 看到的退出码与 SIGILL 相同，都是
   132；后续如果增加 `@trap` 内建再替换。

`alloc_simple` 只引用 `g_heap_ptr` / `g_heap_end`，`alloc_arena` 引用全部
arena 全局。两个函数放在同一个编译单元，一次生成一个 blob。

### trampoline

`alloc_start` 处只发射：

```text
movabs rsi, heap_start
jmp rel32 -> alloc_simple 或 alloc_arena
```

`rdi` 已经是 raw size，`rsi` 是 heap 起点。body 用 `ret` 直接回到 `alloc`
的调用点。trampoline 不保存寄存器，不建栈帧。

`heap_start` 是链接期常量（`bss_va + 16 + globals_size`），在第二次发射时
回填。body 目标由 `has_arena_runtime()` 选择。

### 重定位

`tools/gen_alloc_blob.py` 复用 `tools/gen_bigint_blob.py` 的 ELF 解析：

1. 编译 `alloc_body.cr` 为 `.o`。
2. 解析 `.text` / `.rodata` / `.data`，按 text、rodata、data 顺序拼成 blob。
3. 内部 `R_X86_64_PC32` / `PLT32` 直接解析成相对 blob 的位移。
4. `.bss` 不拷入 blob。所有指向 `.bss` 的 PC32 重定位记录为
   `(symbol_name, rel32_offset)`，由 `elf_gen` 回填到目标程序的 BSS 地址。
   Python bootstrap 把全局名编译成 `_g_<name>`（例如 `_g_g_heap_ptr`）；
   生成器去掉 `_g_` 前缀后再写入汇总，`elf_gen` 按 `g_heap_ptr` 查找。
5. 未定义函数调用记录为 `(symbol_name, rel32_offset)`，由 `elf_gen` 回填到
   `heap_expand_start` 或 `g_x86_func_offsets["arena_grow_pool"]`。
6. 其它未定义符号、绝对重定位、`TLS`、`GOT` 一律失败。

生成的 `src/runtime/alloc_blob.cr` 暴露：

```text
ALLOC_BLOB_SIZE
ALLOC_BLOB_SIMPLE_OFF
ALLOC_BLOB_ARENA_OFF
alloc_blob_bytes()
alloc_blob_call_count()
alloc_blob_call_name(i)
alloc_blob_call_off(i)
alloc_blob_global_count()
alloc_blob_global_name(i)
alloc_blob_global_off(i)
```

### elf_gen

`emit_alloc_body` / `emit_alloc_body_simple` 被替换为：

1. 计算 `alloc_start`，发射 trampoline 占位。
2. 拷贝 blob，记录 `blob_start`。
3. 注册 `alloc`、`alloc_simple`、`alloc_arena` 到 `g_x86_func_offsets`。
4. 回填 trampoline 的 `movabs rsi, heap_start` 和 `jmp body`。
5. 回填 global relocation：`target = bss_va + 16 + global_off[gv]`，
   `rel = target - (blob_start + off + 4)`。
6. 回填 call relocation：`target = heap_expand_start` 或函数表地址，
   `rel = target - (blob_start + off + 4)`。
7. 第一次发射只用于计算大小；第二次在最终 `bss_va` 下重写。

`alloc_start` 仍然是 `alloc` 的入口；`g_x86_alloc_patch_*` 和
`patch_forward_calls` 不需要改语义。

## 验证

### 差分参考

`tests/selfhost/test_alloc_llvm_parity.py`：

- 用 clang 编译一份 C 参考 allocator，`-O2`。
- 用 Python bootstrap 生成 Core allocator `.o`。
- 同一组输入序列分别调用 C 参考和 Core body，比较：
  - 返回指针相对 heap 的偏移；
  - 隐藏长度头；
  - 可写范围（首尾字节）；
  - `g_heap_ptr` / slot / class / extent 状态；
  - 失败路径的退出码或 trap 见证。
- 序列覆盖：0、1、7、8、15、16、3361、3362、4088、4089、4096、1MB-8、
  1MB、1MB+8、64MB-8、64MB、64MB+1、1TB-1、1TB、1TB+1、负值；多 arena、
  reset、重复 reset、pool limit、mmap 失败。

### 结构检查

- `objdump -d` 检查 trampoline 是 `movabs rsi; jmp`，body 入口没有 `ud2`。
- `tools/asm_check.py` 检查生成的 `.s` 栈帧平衡。
- 生成器必须拒绝含 `call alloc` 的 body。

### 现有回归

- `tests/suite/arena_test.cr`、`arena_boundary_test.cr`。
- 2MB/100MB/1GB、chunks、many_slots、static_peak、tagged BigInt。
- `corec selftest-stub-regalloc`、`corec check src/compiler`。
- canary 5/5；ELF 变化按值表纪律重新锁定并记录归因。

## 风险

1. 受限 Core 子集可能不支持全部语法。先做 simple body，确认 bootstrap 能编译
   再扩到 arena。
2. Core 循环清零大块内存比 `rep stosb` 慢。正确性优先；性能优化另开任务，
   可以用一个同样是 Core/汇编生成的 `zero_bytes` helper。
3. 外部全局名必须和 `g_ir_globals` 完全一致。生成器和 `elf_gen` 都需要在
   名字找不到时失败，不能静默跳过。
4. Python bootstrap 的栈对齐不保证 16 字节。body 不调用 SSE 代码；如果以后
   调用 C 参考或 `memcpy`，需要先修对齐。
5. canary 会因代码布局变化再次位移；只按编译器身份位移重新锁定，不改
   `.ccr`。

## 实施顺序

1. 生成器 + simple body + 差分测试。
2. `elf_gen` 接入 simple body，保留旧路径作为 fallback，跑普通程序。
3. arena body + 差分测试，跑 arena 回归。
4. 切换默认，删掉手写 body，重锁 canary。
5. 把 LLVM 差分和结构检查接入 CI。
