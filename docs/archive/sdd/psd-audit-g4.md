# 伪代码审查报告：组 4（dataflow、ccr_io、cir_cache）

审查人：只读审查员，组 4
审查日期：2026-08-09
审查对象：

- `docs/pseudocode/compiler/dataflow.md` 对应 `src/compiler/dataflow.cr`，521 行
- `docs/pseudocode/compiler/ccr_io.md` 对应 `src/compiler/ccr_io.cr`，594 行
- `docs/pseudocode/compiler/cir_cache.md` 对应 `src/compiler/cir_cache.cr`，314 行

对照基准：`docs/pseudocode/标识符对照表.md`，即共享术语表。
铁律执行情况：全程只读，没有修改 `docs/pseudocode/`、`src/`、`tools/` 中的任何文件，没有运行 jj 或 git。本报告是唯一交付文件。

## 一、覆盖率核查（每个 fn 都有对应的“## 函数”节）

| 源文件 | fn 总数 | 文档函数节数 | 结果 |
|---|---|---|---|
| dataflow.cr | 16（init_df、sg_push、sg_pop、df_create_node、df_add_edge_kind、df_add_edge、df_connect_state、df_use_var、df_connect_srcs、grow_var_use_count、compute_usage_counts、lower_to_ccr、df_begin_func、df_end_func、df_graph_to_dot、df_opcode_name） | 16 | 通过 |
| ccr_io.cr | 9（bw_byte、buf_write_u32、buf_write_i32、buf_read_u32、buf_read_i32、buf_read_i64、calc_ccr_size、save_ccr、load_ccr） | 9 | 通过 |
| cir_cache.cr | 6（save_cir_cache、w64_cir、w8_cir、write_fd、load_cir_cache、make_cir_cache_dir） | 6 | 通过 |

合计 31/31，无遗漏，没有多余函数节。

## 二、语义等价抽查（条件方向、边界值、返回路径）

抽查 8 个函数节逐条比对，全部与源码等价。

1. dataflow.md 的“扩展变量使用计数数组（grow_var_use_count）”：needed 小于 cap 时提前返回、2 倍增长、下限 128、`nc < needed → needed + 128`、拷贝 cap*8 字节，全部一致。只有参数名乱码，见问题 M1。
2. dataflow.md 的“弹出结构图（sg_pop）”：`g_sg_count <= 0` 返回、从尾部回扫 EXIT<0、`idx < 0` 返回、NCOUNT 等于 node_count 减 NSTART、SG_LOOP 和 SG_FOR 时 `last_node >= NSTART` 与 `g_last_state_node >= NSTART` 双层门控加类别 1 终止边、状态链头推进、`g_cur_sg = PARENT`。嵌套层级和条件方向完全一致。
3. dataflow.md 的“数据流图：连接源操作数（df_connect_srcs）”：IR_CALL 和 IR_SPAWN 用 s2 作参数个数，循环 s1+ac；IR_CALL_EXTERN 仅用 s2；IR_RETURN 仅当 s1 >= 0；IR_STORE_INDEX_VAR 用 s1、s2、s3；IR_HOTPATCH_ROUTE 用 s2；IR_MAKE_ENUM 直接返回。全部一致。
4. ccr_io.md 的“缓冲区读取32位整数（i32）（buf_read_i32）”：b3 >= 128 时按 `(b3-256)*16777216` 符号扩展，其余走正数路径，一致。
5. ccr_io.md 的“缓冲区读取64位整数（i64）（buf_read_i64）”：低 32 位无符号读取、高 32 位符号扩展、`lo + hi*4294967296`，一致，包含“避免双重符号扩展”的设计说明。
6. ccr_io.md 的“计算线性指令流（CCR）大小（calc_ccr_size）”：36 字节头、字符串 4+len、func 28、instr 24、var 12、str_const 4、struct 8+fc*8、enum 8+变体(8+tc*4)、globals 4+count*16、opt_meta 4+每项(8+len)、SG 4+count*24。所有长度公式逐一吻合。
7. ccr_io.md 的“加载 .线性指令流（ccr）文件（load_ccr）”：fsize 小于 36、魔数、版本 1 到 5 门控、各段读取顺序和位置推进、字段数超限返回 1 而不是 -1，文档正确保留了这个细节；版本门控为 globals v2+、init_val v4+、opt_meta v3+、SG v5+；opt_meta 和 SG 段越界检查为 `pos+md_len > fsize`、`pos+sg_n*24 > fsize`；结构体和枚举零初始化循环上限为 16/16/4。全部一致。
8. cir_cache.md 的“保存和加载数据流图（CIR）缓存”：总大小公式 40+name_len、var 8+count*24、node 8+count*64、edge 8+count*32、instr 8+count*48、str 8+每项(8+len)；缓冲扩容 2 倍，下限 4096；加载最小 48 字节，即 6×8 头；指纹和签名校验失败返回 -1；`v_id >= g_ir_var_count` 时扩容并置计数；`irv_set_id(v_id, v_id)`；节点 region 映射写 `g_cur_sg`；边数组整体覆盖，edge_count 不是增量。这些特殊行为与源码逐项一致。

结论：语义等价维度通过。没有发现条件方向、边界值或返回路径与源码不等价的地方。唯一例外是“作用”散文中的自相矛盾表述，见 M2。

## 三、样式合规（基准文档）

- 每个函数节都有“作用、逻辑、测试要点”三小节，31/31 通过。
- 逻辑节没有英文关键字，没有裸英文标识符，基本通过。个别乱码和字面量翻译问题见问题清单。
- 比较只使用大于等于、小于等于、大于、小于、等于、不等于，逻辑节内通过。违规点出现在“作用”和“测试要点”散文中，见 M2、M5、M7 的 ASCII `>=`、`<`、`!=`。
- 另有系统性的渲染乱码：cir_cache.md 全篇出现“偏移\_DF\下划线（_）操作码”式注入，见问题 I1。

## 四、术语一致性（与 `docs/pseudocode/标识符对照表.md` 比对）

- 三份文档表中的所有共享 fn 和全局标识符，包括 iri_*、irv_*、si_*、ei_*、grow_*、g_df_*、g_ir_*、数据流图：*、函数指纹、签名指纹、追踪字符串常量、字符串驻留、读取文件、输出行、整数转字符串、写 64 位、读 64 位等约 80 个，与共享表逐一吻合，没有自造名冲突。
- 例外见问题清单：ESZ_SG、OFF_DF_* 系列在跨文档命名不一致，见 M11、I1；fi_ast_node 在 cir_cache.md 逻辑节的渲染与共享表不一致，见 M12。
- 结论：基本通过，问题集中在常量和偏移类标识符以及个别渲染。

## 问题清单（分级）

### Critical（无）

没有发现 Critical 级问题。

### Important（1 条）

- I1，cir_cache.md，save_cir_cache 和 load_cir_cache 的节点、边循环，逻辑节：OFF_DF_* 和 OFF_DFE_* 偏移标识符被渲染为“偏移\_DF\下划线（_）操作码（OFF_DF_OPCODE）”式乱码。节点循环 8 处，边循环和恢复循环约 17 处，共 25 处以上。本文档自身的标识符对照表写“偏移\_DF\_操作码”，dataflow.md 的同一标识符写“数据流节点操作码偏移”，三方不一致，严重影响可读性和跨文件一致性。建议统一为与对照表一致的规范名，例如“数据流节点操作码偏移”。

### Minor（13 条）

- M1，dataflow.md，扩展变量使用计数数组（grow_var_use_count）逻辑节：参数名乱码，“令新容量（名称计数）= 128”“令新容量（名称计数）= 所需容量（需求）+ 128”。“名称计数”无法回源到 nc，“需求”无法回源到 needed，破坏“中文名可无歧义回源”原则，语义值本身正确。
- M2，dataflow.md，计算变量使用次数（compute_usage_counts）作用节：“对每条非状态边（种类（kind）!= 0 的边）”自相矛盾。非状态边应为种类等于 0，源码跳过种类不等于 0 的边。作用散文还使用了 ASCII `!=`。逻辑节本身正确，只有散文误导。
- M3，dataflow.md，数据流图：操作码名称（df_opcode_name）逻辑节：IR_RETURN、IR_ALLOC、IR_REF、IR_YIELD 四个字符串字面量被中文化，写成“返回名称（"返回（return）"）”“分配名称（"分配函数（alloc）"）”“引用名称（"引用（ref）"）”“让出名称（"让出（yield）"）”。同一函数其余约 40 个字面量都原样保留，例如 "const"、"store"、"call"。字面量是 DOT 输出契约，应统一为 "return"、"alloc"、"ref"、"yield"。
- M4，dataflow.md，数据流图：导出 DOT（df_graph_to_dot）逻辑节：输出字面量全部意译，例如 "digraph G {" 写成“有向图声明开始”，"rankdir=TB;"、cluster 名 if/loop/for/flow/unsafe、节点和边行格式也被改写，无法还原精确的 DOT 输出。这与 df_opcode_name 节保留字面量的风格不一致，测试要点也没有覆盖具体输出字符串。
- M5，dataflow.md，数据流图：创建节点（df_create_node）测试要点 4：使用 ASCII 比较符“当前结构图索引（g_cur_sg）>= 0”，应改为“大于等于 0”。
- M6，ccr_io.md，缓冲区读取32位整数（i32）（buf_read_i32）逻辑节：“（字节3（字节3）- 256）* 16777216”参数名重复乱码，应为“字节3（b3）”。
- M7，ccr_io.md，缓冲区读取32位整数（i32）（buf_read_i32）作用和测试要点：裸英文标识符和 ASCII 比较符，包括“最高字节（b3）若 >= 128”，作用节；“正数（字节3（b3）< 128）”，测试要点 2。
- M8，ccr_io.md，保存 .线性指令流（ccr）文件（save_ccr）作用节：“函数元数据（每条 7 变量甲（x）u32）”是乱码文本，“变量甲（x）”为生成噪声，应为“7 个 u32”。
- M9，ccr_io.md，加载 .线性指令流（ccr）文件（load_ccr）逻辑节：iri_set_op、iri_set_dest 到 iri_set_tk，以及 irv_set_name、irv_set_id、irv_set_type 调用丢失了数组索引实参。源码是 `iri_set_op(ii, opcode)`、`irv_set_name(vi, name_ni)`，文档只列一个实参，例如“IR 指令访问器：设置操作码（iri_set_op）（opcode）”。这与 dataflow.md 降为线性 IR 节的双实参写法不一致，无法无歧义回源。
- M10，ccr_io.md，加载 .线性指令流（ccr）文件（load_ccr）逻辑节：三条错误消息字面量被改写。源码是 "error: .ccr struct field count exceeds max" 等，文档写成“"error: .线性指令流（ccr）结构（struct）field count exceeds max"”，实际输出文本会不同。
- M11，ccr_io.md 和 dataflow.md，标识符对照表，跨文件：同一标识符命名不一致。ESZ_SG 在 dataflow.md 为“SG 条目大小”，在 ccr_io.md 为“结构图条目大小（内存）”。ccr_io.md 内部 OFF_SI_FIELD_TYPE_NODES 的对照表写“结构体条目字段类型节点偏移”，逻辑节却写“结构体条目字段类型偏移节点”。共享表未收录这些常量，但跨文档应统一。
- M12，cir_cache.md，保存和加载数据流图（CIR）缓存，逻辑节 2 处：“函数信息访问器：AST 数组（ast）节点（fi_ast_node）”是乱码。本文档对照表和共享表都写“函数信息访问器：ast节点”。
- M13，cir_cache.md，文件头功能概要和全局状态，3 处：“4 变量甲（x）8 字节”应为“4 个 8 字节”或“4×8B”，共 2 处；“签名字哈希”应为“签名指纹哈希”。这些是生成噪声文本。

## 总结论

组 4 的三份文档在覆盖率，31/31 个函数节，和语义等价性，抽查 8 个函数节，条件方向、序列化边界值、返回路径全部与源码一致，两个维度通过。样式和术语维度基本达标。其余问题都是生成噪声和命名乱码类，1 条 Important 加 13 条 Minor，没有 Critical。建议按 I1 到 M 系列的顺序做一轮机械性清理，不需要重写任何函数节。
