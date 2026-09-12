// _import.cr — imports for the corearch backend project
import cli
import fmt
import io
import toml
import ast
import globals
import dyn_arr
import hit
// 降低层（HIT M2）：instr.cr 的表编码器消费 lower_to_core.cr 的事件流
// （hit_rel_add/hit_ev_*/hit_pool_patch_add/HIT_EV_*/g_hit_*）——本文件原先只
// import hit 而漏 lower_to_core，致 ld project-mode 单元 15×N06+16×N01 静默未
// 定义（含 TA01 级联；与 c138c44c「compiler 单元缺 ent_kernel」同类）。经
// src/arch/hit/ 跨树回退命中（与 hit 同机制、同目录）。
import lower_to_core
// R2 P3 Task 7 收官修复（2026-09-12）：此处原 `import monomorph`——P3 Task 5 给 monomorph.cr
// 加的实例键类型项化（inst_key_of_ti/inst_type_node_of_ti 族）引入 checker/parser 层符号
// （get_type_kind/get_type_data/get_type_extra/alloc_node/alloc_type），project-mode corearch
// 单元集不含该层 ⇒ 构建 33×error[N06] 静默未定义（rc=0 + 产物照出 ⇒ stage 链互测不可见）；
// concat 面 build_selfhost_native.py 的 backend_support_files 已同批迁出，唯本文件漏改。
// 与 concat 面同一证据：monomorph 在 corearch 链接集**零代码引用**（全部定义符只出现在
// globals.cr 的注释里），单态化本就是前端 ir_gen 期动作。删除本行 = 两面清单重新对齐；
// 该缺陷的机械守卫 = tests/selfhost/test_backend_bootstrap.py 的 project-mode error[ 门
// （TODO #31：该套件未挂 CI，收官全量枚举才跑到）。若将来自复活本文件，须先让它不依赖
// checker/parser 层符号。
// R2 P4 Task 2（TYPE 段内容面读回）：ccr_io.cr 的 load 侧重建类型项表——调
// tt_hash5/grow_tt_index/tt_reindex/tt_layer_reset（type_terms.cr）与 --dump-types
// 通道的项层原语（tt_norm/tt_is_dnf/tt_is_literal）。**必须先于 ccr_io 入本清单**
// （常量可见性：ESZ_TYPE_TERM/OFF_TT_*/TT_*——若漏列本行，project-mode corearch
// 单元即 N06 静默未定义，B.6 同族；concat 面 = backend_support_files 头部同位置）。
// **type_engine.cr 不入本清单**：既有两条诊断（lits_copy 类型洗白 TF01 +
// ty_memo_slot_no_grow loop-落空误报）会触发本单元的 project-mode `error[`=0 门
// （test_backend_bootstrap）；判定原语跨进程同值因此未覆盖（T2 报告登记）。
import type_terms
import ccr_io
import ent_kernel
// 内核完备 Task 1（调度重建移实例）：build_linear_schedule（regalloc.cr——
// 实例侧调度重建）须进自举 stage 链编译集——本文件（自举 project 入口
// main.cr 的共享导入）与 build_selfhost_native.py corearch concat 双注册
// （regalloc 原 = concat 独有；main.cr 的 load 后调用依赖本导入）。
import regalloc
import sizes
import instr
// 架构轴 tag2l（x86 实例化波 1 Task 4 落位）：int 多字 M1 的 tag 表 owner
// （mw_setup_tags——elf.cr Phase 2/3 各一次）+ mw 族纯编码（jo 溢出跳/慢路径块/
// 2L 操作数块/tag 卫生助手——自 instr.cr 整函数迁出）+ 表发射门
// mw_int_arith_jo_needed。与 frame.cr 同轴双向引用（裁定②可接受——frame 的
// pf_epilogue 调本文件 e2_mw_*，本文件经 frame 的 g2_tag_off 读表）。project-mode
// 单元须经本清单收编（回退链命中 src/arch/x86_64/；concat 面 = arch_x86_64_files）。
import tag2l
// 架构轴 frame（x86 实例化波 1 Task 3 落位）：函数帧单源——pf_frame_size
// （Phase 2 dry-run 与 Phase 3 sub rsp 立即数共用）+ pf_prologue/pf_epilogue
// （帧发射序自 format/elf/elf.cr 抽出）+ g2_tag_off（自 instr.cr 迁入，H3）。
// project-mode 单元须经本清单收编（回退链命中 src/arch/x86_64/；concat 面 =
// arch_x86_64_files）。
import frame
import resolve
import elf
import ld
// OS 轴（x86 实例化波 1 Task 2 落位）：_start 发射序 emit_start/emit_start_size
// 自 format/elf/elf.cr 整函数迁 src/os/linux/entry.cr——elf.cr 的调用点跨轴引它，
// project-mode 单元须经本清单收编（回退链命中 src/os/linux/；concat 面 = os_linux_files）。
import entry
// OS 轴（x86 实例化波 1 Task 5 落位）：SysV AMD64 调用约定序列——cs_args_dispatch
// （寄存器参数分派，IR_CALL/EXTERN/SPAWN 三处同源合流）/cs_stack_args（+ 判定
// cs_arg_on_stack/计数 cs_stack_count）/cs_stack_cleanup/cs_ret_value（IR_RETURN
// 值序列 + tag 读路径 A）/cs_call_direct——自 instr.cr emit_instr 内联段落抽出。
// instr.cr 的四分支调用点跨轴引它，project-mode 单元须经本清单收编（回退链命中
// src/os/linux/；concat 面 = os_linux_files）。
import callseq
// OS 轴（x86 实例化波 1 Task 6 落位）：Linux syscall 约定发射序——sys_syscall3_stub
// （rax 号 + rdi/rsi/rdx 参数序 + 0F 05 + 回存）/sys_syscall4_stub（第 4 参经 r10
// ——I-2 wait4 EFAULT 修复史随迁）——自 instr.cr emit_instr 内置体分派链抽出
// （syscall3/4 两分支改调）。内置体名索引扫描段留 elf.cr 原位（波 2 参数化面）。
// instr.cr 的分派链跨轴引它，project-mode 单元须经本清单收编（回退链命中
// src/os/linux/；concat 面 = os_linux_files）。
import syscall
