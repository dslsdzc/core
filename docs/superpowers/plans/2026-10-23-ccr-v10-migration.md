# v10 目标无关 `.ccr` 迁移 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `.ccr` 从 v9.1 槽格式迁移到 v10 格形态：格式只表达存在、版本、区域、边和语义域；前端不再计算目标布局；corearch 从 v10 + target layout 生成投影。

**Architecture:** 先建立独立的 v10 wire oracle 和 Core schema，再迁移 NOD/ENT 语义，最后切换读写器。v9 文件整类拒绝，不做隐式兼容。布局、宽度、字节偏移、寄存器/栈/ABI 只出现在 corearch、target model 和 `.coi`。

**Tech Stack:** Core 自举编译器、`src/compiler/ccr_io.cr`、`src/lattice/ent_kernel.cr`、`src/arch/x86_64`、Python 自举测试。

**Spec:** `docs/superpowers/specs/2026-10-23-lattice-ccr-v10-design.md`

## Global Constraints

- 每个任务单独提交；前一个任务的验收通过后才开始下一个。
- 不使用全局字符串替换修改语义代码；移动或重命名时保留函数名、参数名和注释中的技术事实。
- v10 完成前，`CCR_VERSION` 保持 v9.1；不得产生“v10 header + v9 字段”的混合文件。
- 除任务 4 的格式切换外，任何任务都不能同时改变 wire 版本和 IR 语义。
- 前端语义文件（`src/compiler` 的 lexer/parser/checker/ir_gen/ccr_lower）不得出现 `mp_*`、字节偏移、步长、对齐、寄存器、栈和 ABI。
- `.ccr` 不得依赖 `.coi`；删除全部 `.coi` 后 v10 文件仍能加载、验证和投影。
- 所有新增 wire 字段只使用角色名：`count/kind/opcode/flags/offset/size/version/id/imm/word`，不写 `u32/i32` 作为语言类型。
- v4 语法没有 `<T>` 或 `[T]` 泛型参数语法；文档和测试不得引入这两种写法。
- 任务 1 到 3 的中间态仍使用 v9 writer；只有在 NOD/ENT 语义和 corearch 消费面同时准备好后，任务 4 才 bump 版本。
- 每个任务结束运行：
  ```bash
  nice -n 19 python3 build_selfhost_native.py
  ./build/corec check src/compiler
  ```
- 任务 4 起还要运行：
  ```bash
  nice -n 19 python3 tests/selfhost/test_ccr_v7.py
  nice -n 19 python3 tests/selfhost/test_ccr_types.py
  nice -n 19 python3 tests/selfhost/test_backend_bootstrap.py
  nice -n 19 bash tools/baseline/canary_check.sh
  ```

## Review Focus

- 输入：一个合法的 v9 `.ccr`。预期：v10 loader 明确拒绝，不能因为段表前缀相似而读成 v10。
- 输入：v10 段表有重复 tag、缺失段、段体重叠或尾随字节。预期：全部拒绝，不能把缺失段当空表。
- 输入：NOD 的 `type_id` 越界，或 `src2/src3` 填入旧宽度值。预期：按损坏拒绝，不能把它解释成字节宽度。
- 输入：ENT 仍有 `home` 或 `live_end` 越界。预期：记录长度或区间校验拒绝。
- 输入：删除全部 `.coi` 后加载 `.ccr`。预期：加载和投影不变，只允许优化质量下降。

---

### Task 1: v10 wire oracle 和负向 fixture

**Files:**
- Create: `tests/selfhost/ccr_v10_model.py`
- Create: `tests/selfhost/test_ccr_v10_format.py`
- Create: `tests/selfhost/fixtures/ccr_v10_min.ccr`（由测试生成，不入库时改为临时文件）

**Interfaces:**
- Consumes: v10 规格 §3、§4、§5、§7、§11。
- Produces:
  - `encode(segments: dict[int, bytes]) -> bytes`
  - `decode(data: bytes) -> dict[int, bytes]`
  - `validate(data: bytes) -> None`，失败抛 `CcrV10Error`
  - `SEG_TAGS = {1: "STR", 2: "TYPE", 3: "IFACE", 4: "SYM", 5: "NOD", 6: "ENT", 7: "REG", 8: "EDG", 9: "CASE"}`

- [ ] **Step 1: 写失败测试**

`test_ccr_v10_format.py` 至少包含：

```python
def test_header_and_canonical_segment_order():
    data = encode({tag: b"\x00\x00\x00\x00" for tag in SEG_TAGS})
    assert data[:4] == b"CCR1"
    assert version(data) == 0x000A0000
    assert seg_count(data) == 9
    assert list(decode(data)) == [1, 2, 3, 4, 5, 6, 7, 8, 9]

def test_rejects_v9_version():
    data = encode({tag: b"\x00\x00\x00\x00" for tag in SEG_TAGS})
    with pytest.raises(CcrV10Error):
        validate(patch_u32(data, 4, 589825))

def test_rejects_duplicate_missing_overlap_and_trailing():
    ...
```

- [ ] **Step 2: 运行测试确认失败**

```bash
python3 tests/selfhost/test_ccr_v10_format.py
```

Expected: `ModuleNotFoundError` 或 `CcrV10Error` 未定义。

- [ ] **Step 3: 实现 oracle**

`ccr_v10_model.py` 只做 wire 编解码，不理解 NOD 业务字段。header 固定 16B，段表固定 9×12B，段表 tag 升序、offset 连续、末段尾 == 文件长度。所有拒绝路径抛 `CcrV10Error`。

- [ ] **Step 4: 运行测试确认通过**

```bash
python3 tests/selfhost/test_ccr_v10_format.py
```

Expected: 全部 PASS。

- [ ] **Step 5: 提交**

```bash
jj commit -m "test: add ccr v10 wire oracle and negative fixtures"
```

---

### Task 2: Core v10 schema 常量

**Files:**
- Create: `src/compiler/ccr_schema.cr`
- Modify: `src/compiler/ccr_io.cr`（删除重复常量，改引用）
- Modify: `build_selfhost_native.py`
- Modify: `src/targets/x86_64/linux/elf/_import.cr`
- Modify: `src/arch/x86_64/corearch.cr` 的构建清单引用

**Interfaces:**
- Consumes: Task 1 的 wire 形状。
- Produces:
  - `CCR_V10_VERSION : int = 655360`
  - `CCR_V10_SEG_COUNT : int = 9`
  - `CCR_V10_SEG_STR/TYPE/IFACE/SYM/NOD/ENT/REG/EDG/CASE : int`
  - `CCR_V10_NOD_DISK : int = 40`
  - `CCR_V10_ENT_DISK : int = 24`
  - `CCR_V10_REG_DISK : int = 24`
  - `CCR_V10_EDG_DISK : int = 8`
  - `CCR_V10_CASE_DISK : int = 24`

- [ ] **Step 1: 先写编译期断言 fixture**

在 `tests/selfhost/test_ccr_v10_format.py` 增加一个不依赖 Core 的常量对照测试：从 `ccr_schema.cr` 文本中读取 `CCR_V10_*` 常量，和 Python oracle 的 tag/size 比较。测试必须失败，因为文件尚未创建。

- [ ] **Step 2: 运行测试确认失败**

```bash
python3 tests/selfhost/test_ccr_v10_format.py
```

Expected: `ccr_schema.cr does not exist`。

- [ ] **Step 3: 创建 schema 文件**

只放 wire 常量、记录尺寸和段 tag，不放布局、宽度、ABI 或目标常量。`ccr_io.cr` 继续使用旧 `CCR_VERSION`，避免在任务 4 前 bump。

- [ ] **Step 4: 加入构建清单**

`ccr_schema.cr` 放在 `ccr_io.cr` 之前、`dyn_arr.cr` 之后；同时出现在 corec 和 corearch 的共享清单。运行：

```bash
nice -n 19 python3 build_selfhost_native.py
```

Expected: 三个 guard 通过，`corec` 构建成功。

- [ ] **Step 5: 提交**

```bash
jj commit -m "ccr: add v10 wire schema constants"
```

---

### Task 3: NOD 语义域（仍写 v9）

**Files:**
- Modify: `src/lattice/ent_kernel.cr`
- Modify: `src/compiler/globals.cr`
- Modify: `src/compiler/ccr_types.cr`
- Modify: `src/compiler/ccr_io.cr`
- Modify: `src/arch/x86_64/corearch.cr`
- Test: `tests/selfhost/test_ccr_types.py`

**Interfaces:**
- Consumes: `iri_tk`、`sh_tk_face_of_code`、`sh_term_of_ti`、ENT 内存表。
- Produces:
  - `ccr_nod_type_populate() -> int`：为每个节点填 `type_id`。
  - `g_ccr_nod_type : string`、`g_ccr_nod_type_count : int`。
  - `nod_type_id(n: int) -> int`。
  - `nod_type_flags(n: int) -> int`（先恒 0）。
  - v9 写侧保持 28B ENT（含 `home`）；v10 写侧到 Task 4 才删除 `home`。

- [ ] **Step 1: 写失败测试**

在 `test_ccr_types.py` 增加：

```python
def test_nod_type_id_is_type_row_or_minus_one(...):
    # type-face 节点：0 <= type_id < row_count
    # 非类型节点：type_id == -1
```

以及一个“v9 ENT 仍为 28B 且 `home` 可由旧 loader 读取”的回归断言；v10 的 24B 断言放到 Task 4。

- [ ] **Step 2: 运行测试确认失败**

```bash
nice -n 19 python3 tests/selfhost/test_ccr_types.py
```

Expected: `nod_type_id` 或 `g_ccr_nod_type` 不存在。

- [ ] **Step 3: 实现 type_id 映射**

规则固定为：

```text
if sh_tk_face_of_code(op, tk) == 0:
    type_id = tk          // tk 是 TYPE row
else:
    type_id = -1
flags = 0
```

`item` 仍保留在 v9 内存镜像中供诊断；v10 落盘时不再使用 `item`。**本任务不改变 v9 wire 字节**：v9 写侧仍写 28B ENT（含 `home`），`home` 只在 Task 4 的 v10 写侧删除。这样任务 3 的产物仍可被当前 v9 loader 读取，`.ccr` canary 只应因 Task 3 新增的内部登记而按需重锁；如果 ELF 变化，停止并记录原因。

- [ ] **Step 4: 运行回归**

```bash
nice -n 19 python3 tests/selfhost/test_ccr_types.py
nice -n 19 python3 tests/selfhost/test_live_ranges.py
nice -n 19 python3 tests/selfhost/test_opt_dex.py
```

Expected: 全绿；`.ccr` 字节可变化，但 ELF canary 和语义断言不变。如果 ELF 变化，停止并记录原因。

- [ ] **Step 5: 提交**

```bash
jj commit -m "ccr: derive semantic type ids for v10 nod"
```

---

### Task 4: v10 cutover：版本、段序、ENT 24B、CASE、corearch 重建

**Files:**
- Modify: `src/compiler/ccr_io.cr`
- Modify: `src/compiler/ccr_schema.cr`
- Modify: `src/compiler/globals.cr`
- Modify: `src/arch/x86_64/instr.cr`
- Modify: `src/arch/x86_64/regalloc.cr`
- Modify: `src/arch/hit/lower_to_core.cr`
- Modify: `src/arch/x86_64/corearch.cr`
- Modify: `test` 目录中的 v9 断言
- Test: `tests/selfhost/test_ccr_v7.py`
- Test: `tests/selfhost/test_ccr_types.py`
- Test: `tests/selfhost/test_ccr_v10_format.py`
- Test: `tests/selfhost/test_native_memory.py`
- Test: `tests/selfhost/test_interp_parity.py`

**Interfaces:**
- Consumes: Task 2 schema、Task 3 NOD/ENT 语义。
- Produces:
  - `CCR_VERSION := CCR_V10_VERSION`
  - `CCR_SEG_COUNT := 9`
  - `calc_ccr_size`、`save_ccr`、`load_ccr` 使用 canonical order：`STR TYPE IFACE SYM NOD ENT REG EDG CASE`
  - v9 版本 `589825` 一律拒绝。
  - corearch 只从 `type_id` + target DataLayout 重建宽度/stride；不得从 `.ccr` 读回宽度。
  - NOD 的 `flags` 只接收语义节点特性，不接收宽度、字节偏移或 ABI。

- [ ] **Step 1: 写失败测试**

新增测试：

```python
def test_v10_end_to_end(ccr_path):
    data = Path(ccr_path).read_bytes()
    assert u32(data, 4) == 0x000A0000
    assert u32(data, 8) == 9
    assert tags(data) == [1, 2, 3, 4, 5, 6, 7, 8, 9]
    assert segment(data, 6)[0] == 4  # CASE 空 = count 0

def test_v9_rejected(v9_path):
    r = corearch(v9_path)
    assert r.returncode != 0
```

- [ ] **Step 2: 运行测试确认失败**

```bash
nice -n 19 python3 tests/selfhost/test_ccr_v10_format.py
nice -n 19 python3 tests/selfhost/test_ccr_v7.py
```

Expected: 版本/段表断言失败。

- [ ] **Step 3: 实现 container cutover**

- header：`version = 0x000A0000`，`seg_count = 9`，flags 只保留 `PORTABLE/SYSTEM/CONCURRENT` 位。
- 段表：9×12B，`tag 1..9`；写侧按 canonical order 连续写；CASE 先写 4B `case_count=0`。
- ENT：`ESZ_ENTRY_DISK = 24`，字段序 `var_id/version/def_nod/live_start/live_end/flags`；不再读 `home`。
- NOD：写 `op/dest/src1/src2/src3/type_id/flags/first_edge/edge_count`；`type_id` 来自 Task 3；`flags` 只写语义特性。
- loader：拒绝 v9、8 段、重复/缺失/重叠/尾随；按段表 offset 解析（顺序流式在 Task 6 收紧）。
- corearch：`nod_tk`/访问宽度改为从 `type_id` 和 target layout 重建；`IR_DEREF`、`IR_ALLOC_ARRAY`、`IR_STORE_PTR` 不再依赖盘上宽度。所有旧 `tk` 辅码必须先分类：语义特性进 `flags`，目标事实留给 corearch，不可分类的码在保存时拒绝。

- [ ] **Step 4: 迁移测试常量**

`test_ccr_v7.py` 改名为语义测试但保留文件名；把 `V7 = 589825` 改为 `V10 = 0x000A0000`，段 tag/顺序、ENT 24B、`CASE` 断言全部更新。旧 v9 fixture 保留在负向测试中，必须继续拒绝。

- [ ] **Step 5: 运行完整回归**

```bash
nice -n 19 python3 tests/selfhost/test_ccr_v7.py
nice -n 19 python3 tests/selfhost/test_ccr_types.py
nice -n 19 python3 tests/selfhost/test_native_memory.py
nice -n 19 python3 tests/selfhost/test_interp_parity.py
nice -n 19 python3 tests/selfhost/test_backend_bootstrap.py
nice -n 19 python3 tests/selfhost/test_opt_dex.py
nice -n 19 python3 tests/selfhost/test_bigint_arith.py
nice -n 19 bash tools/baseline/canary_check.sh
```

Expected: 全绿；`.ccr` canary 四条的尺寸/哈希重锁，ELF canary 保持 `826d74cf...`。重锁必须在 `tools/baseline/canary_values.tsv` 注释中写归因：v10 header/段序/ENT/NOD 字段变化。

- [ ] **Step 6: 提交**

```bash
jj commit -m "ccr: cut over to v10 lattice container and reject v9"
```

---

### Task 5: 前端去布局，corearch 接管 DataLayout

**Files:**
- Modify: `src/compiler/ir_gen.cr`
- Modify: `src/compiler/ptr_analysis.cr`
- Modify: `src/compiler/provenance_verify.cr`
- Modify: `src/compiler/interp.cr`
- Modify: `src/compiler/ccr_lower.cr`
- Modify: `src/arch/x86_64/instr.cr`
- Modify: `src/arch/x86_64/regalloc.cr`
- Modify: `src/arch/hit/lower_to_core.cr`
- Test: `tests/selfhost/test_native_memory.py`
- Test: `tests/selfhost/test_interp_parity.py`
- Test: `tests/selfhost/test_pointer_safety.py`

**Interfaces:**
- Consumes: v10 `type_id`、target layout。
- Produces:
  - `ir_gen` 不再调用 `mp_size/mp_align/mp_stride/mp_field_offset/mp_extent/mp_offset`。
  - `IR_DEREF`、`IR_ALLOC_ARRAY`、`IR_STORE_PTR` 的宽度/stride 不再进入 `.ccr`。
  - corearch 的 `dl_*` 函数（`dl_size/dl_align/dl_stride/dl_field_offset`）从 `type_id` 和 target 计算。

- [ ] **Step 1: 写失败静态测试**

在 `tests/selfhost/test_ccr_v10_format.py` 增加：

```python
def test_frontend_has_no_layout_calls():
    src = Path("src/compiler/ir_gen.cr").read_text()
    for name in ("mp_size", "mp_align", "mp_stride", "mp_field_offset"):
        assert name not in src
```

以及 `ptr_analysis.cr`、`provenance_verify.cr` 的同类断言。

- [ ] **Step 2: 运行测试确认失败**

```bash
python3 tests/selfhost/test_ccr_v10_format.py -k frontend_has_no_layout
```

Expected: 找到 `mp_*`。

- [ ] **Step 3: 迁移逐处**

按操作分类：

```text
IR_ALLOC_ARRAY   -> src3 删除 stride；corearch 用数组元素 type_id + target stride
IR_DEREF         -> src3 删除 access width；corearch 用 pointee type_id
IR_STORE_PTR     -> 同上，值域来自 type_id
ptr_analysis     -> 不再做字节地址缩放；只保留语义路径/索引
provenance       -> 只做区间存在性，不做字节 extent
interp           -> 使用 target layout 回调，不读编译器 Mapping
```

保留现有 `-1`/unknown 拒绝路径，不能把未知宽度当 0。

- [ ] **Step 4: 运行回归**

```bash
nice -n 19 python3 tests/selfhost/test_native_memory.py
nice -n 19 python3 tests/selfhost/test_interp_parity.py
nice -n 19 python3 tests/selfhost/test_pointer_safety.py
nice -n 19 python3 tests/selfhost/test_bigint_containers.py
nice -n 19 python3 tests/selfhost/test_view_builtins.py
```

Expected: 全绿；同一源程序的 v10 `.ccr` 不因 target 布局变化而变。

- [ ] **Step 5: 提交**

```bash
jj commit -m "ccr: move layout out of frontend into target projection"
```

---

### Task 6: 顺序流式 loader

**Files:**
- Modify: `src/compiler/ccr_io.cr`
- Test: `tests/selfhost/test_ccr_v10_stream.py`

**Interfaces:**
- Consumes: Task 4 canonical file order。
- Produces:
  - `load_ccr` 只从当前 cursor 前进，不按段表 offset 回跳。
  - 段表只用于边界/一致性校验，不用于后向 seek。
  - `TYPE` 在 `SYM` 前就绪，`IFACE` 在 `SYM` 前就绪，`NOD` 在 `ENT/REG/EDG` 前就绪。

- [ ] **Step 1: 写失败测试**

构造一个段表合法但段体顺序为 `STR/SYM/.../TYPE` 的文件；流式 loader 必须拒绝，随机访问 loader 可以接受。测试同时验证 canonical order 文件两种模式语义一致。

- [ ] **Step 2: 运行测试确认失败**

```bash
python3 tests/selfhost/test_ccr_v10_stream.py
```

Expected: loader 仍然用 offset 回跳，负向用例被接受。

- [ ] **Step 3: 重排解析块**

把 `load_ccr` 的解析顺序改为：

```text
STR -> TYPE -> IFACE -> SYM -> NOD -> ENT -> REG -> EDG -> CASE
```

`REG` 依赖 `SYM` 的 `fn_meta`，`ENT` 依赖 `SYM` 的 var 命名空间和 `NOD` 的 `instr_cnt`；把这些临时状态保留到对应段读完。CASE 先只校验空表，后续 match 迁移时再填充。

- [ ] **Step 4: 运行回归**

```bash
nice -n 19 python3 tests/selfhost/test_ccr_v10_stream.py
nice -n 19 python3 tests/selfhost/test_backend_bootstrap.py
nice -n 19 bash tools/baseline/canary_check.sh
```

Expected: 全绿；`test_ccr_v10_stream` 的负向文件被拒。

- [ ] **Step 5: 提交**

```bash
jj commit -m "ccr: make v10 loader consume canonical segment order"
```

---

### Task 7: `.ccrb` 分发和 `.coi` 边界

**Files:**
- Create: `src/dist/ccrb.cr`（或现有分发层中的对应文件）
- Modify: `docs/maintainer/design/coi-optimization-knowledge-sidecar.md`
- Test: `tests/selfhost/test_ccrb_bundle.py`

**Interfaces:**
- Consumes: raw v10 `.ccr`。
- Produces:
  - `ccrb_pack(raw_ccr: string, coi: string) -> string`，输出 zstd(deterministic tar)。
  - `ccrb_unpack(bundle: string) -> int`，解出 `manifest`、`program.ccr`、可选 `coi/<target>.coi`。
  - corearch 只接收解压后的 raw `.ccr`，不依赖 zstd。

- [ ] **Step 1: 写失败测试**

测试固定 tar 顺序和元数据；同一输入两次打包逐字节相同；删除 `.coi` 后 raw `.ccr` 字节不变；缺失 `.coi` 时加载/投影不变。

- [ ] **Step 2: 实现打包/解包**

manifest 只含 bundle 版本、raw `.ccr` 哈希、`.coi` 目标列表和哈希。`.coi` 不能包含语义、布局或正确性条件。

- [ ] **Step 3: 运行测试**

```bash
nice -n 19 python3 tests/selfhost/test_ccrb_bundle.py
nice -n 19 python3 tests/selfhost/test_ccr_v10_stream.py
```

- [ ] **Step 4: 提交**

```bash
jj commit -m "dist: add ccrb bundle with optional coi sidecar"
```

---

### Task 8: 删除残留旧面并重锁

**Files:**
- Modify: `src/arch/x86_64/x86_frontend_abi.cr`
- Modify: `src/compiler/ccr_io.cr`
- Modify: `src/compiler/globals.cr`
- Modify: `docs/superpowers/specs/2026-09-09-lattice-ir-v7-format.md`（标注 v9 历史）
- Modify: `tools/baseline/canary_values.tsv`

**Interfaces:**
- Consumes: Task 4 至 7 的 v10 路径。
- Produces:
  - 普通语言 API 不再注册 `cell_store/cell_load/load8/store8/load64/w32/load_str_ptr/store_str_ptr/_dyncpy` 中的机器名。
  - v9 常量、`OFF_ENTRY_HOME`、v9 测试常量全部删除或标为历史 fixture。
  - canary 只保留 v10 值。

- [ ] **Step 1: 写失败测试**

静态断言 `src/arch/x86_64/x86_frontend_abi.cr` 不出现 fixed-width builtin 名；`src/compiler/ccr_io.cr` 不出现 `589825`、`ESZ_ENTRY_DISK : int = 28`、`home` 写入。

- [ ] **Step 2: 删除并运行**

```bash
nice -n 19 python3 build_selfhost_native.py
./build/corec check src/compiler
nice -n 19 python3 tests/selfhost/test_opt_dex.py
nice -n 19 python3 tests/selfhost/test_bigint_arith.py
nice -n 19 python3 tests/selfhost/test_backend_bootstrap.py
nice -n 19 bash tools/baseline/canary_check.sh
```

Expected: 全绿；`.ccr` 四条重锁后稳定，ELF canary 保持 `826d74cf...`。

- [ ] **Step 3: 提交**

```bash
jj commit -m "refactor: remove v9 ccr and residual raw frontend surface"
```

---

## 任务依赖

```text
Task 1 wire oracle
  -> Task 2 schema
  -> Task 3 NOD/ENT semantics
  -> Task 4 v10 cutover
      -> Task 5 layout out of frontend
      -> Task 6 streaming loader
      -> Task 7 ccrb/coi
      -> Task 8 cleanup + canary
```

Task 5 和 Task 6 可以在 Task 4 之后并行设计，但**不要并行改同一文件**；Task 5 先合入，Task 6 再重排 `load_ccr`，避免冲突。

## 验收总门槛

最终一次完整运行：

```bash
nice -n 19 python3 build_selfhost_native.py
./build/corec check src/compiler
python3 tests/selfhost/test_ccr_v10_format.py
python3 tests/selfhost/test_ccr_v10_stream.py
python3 tests/selfhost/test_ccr_types.py
python3 tests/selfhost/test_ccr_v7.py
python3 tests/selfhost/test_backend_bootstrap.py
python3 tests/selfhost/test_opt_dex.py
python3 tests/selfhost/test_bigint_arith.py
python3 tests/selfhost/test_native_memory.py
python3 tests/selfhost/test_interp_parity.py
bash tools/baseline/canary_check.sh
```

全部通过后，用三阶段自举确认：

```bash
./build/corec build src/compiler/main.cr -o /tmp/corec2 --static -O 0
/tmp/corec2 build src/compiler/main.cr -o /tmp/corec3 --static -O 0
cmp /tmp/corec2 /tmp/corec3
```

`cmp` 必须无输出。
