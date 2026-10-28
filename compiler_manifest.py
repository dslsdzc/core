COREC_FILES = [
    'src/runtime/rt.cr',
    'src/kernel/bytes.cr',
    'src/stdlib/io.cr',
    'src/stdlib/fmt.cr',
    'src/runtime/bigint.cr',
    'src/stdlib/cli.cr',
    'src/compiler/ast.cr',
    'src/compiler/ccr_schema.cr',
    'src/compiler/globals.cr',
    'src/compiler/dyn_arr.cr',
    'src/compiler/source.cr',
    'src/compiler/lib_manager.cr',
    'src/compiler/literal.cr',
    'src/compiler/big_lit.cr',
    'src/compiler/lexer.cr',
    'src/compiler/parser.cr',
    'src/compiler/checker.cr',
    'src/compiler/mapping.cr',
    'src/arch/x86_64/x86_mapping.cr',
    'src/compiler/prelude.cr',
    'src/arch/x86_64/x86_frontend_abi.cr',
    'src/os/linux/linux_frontend_abi.cr',
    'src/runtime/runtime_frontend_abi.cr',
    'src/targets/x86_64/linux/elf/target_abi.cr',
    'src/targets/x86_64/linux/elf/frontend_target.cr',
    # R2 P0 类型项引擎（建层）：类型项 DAG 表 + 构造去重 → 判定引擎（桩）→ 自测通道。
    # 置于 checker 之后（计划 Step 9 指定位置）；引擎尚无 checker 侧消费者，
    # 本次为纯增量（checker/ir_gen/后端零改动 = 产物零变化）。
    'src/compiler/type_terms.cr',
    'src/compiler/type_engine.cr',
    # R2 P2b Task 1 本质条目表（native interface entries）+ iface_* 查询 API：**静态
    # 数据表 + 只读查询**，零消费者零行为变化（不 alloc g_types 行 ⇒ .ccr 零扰动）。
    # 置于引擎之后、桥接层之前（Task 2 起桥接层委托 iface_by_ty_code）。
    'src/compiler/iface_registry.cr',
    # R2 P4 Task 0：iface 满足判定簇 + `iface_kind_of` 的 corec-only 宿主（链接面纯化——
    # type_engine.cr 留纯核、iface_registry.cr 除该函数；corearch 清单**不含**本文件）。
    'src/compiler/iface_axis.cr',
    # R2 P1 桥接层（checker ti → 引擎类型项 + per-ti 缓存）。文件名 = 历史遗留（前身含
    # R2 P1 影子对拍挂点，已随 R2 P5 Task 5 下线）；现为**生产面**（判定路径无条件经它译项）。
    # **corelsp 清单也必须含本层**（checker.cr 的判定入口引用 sh_term_of_ti；corearch 无
    # checker 故仍不含）。相对顺序与 corec 一致（checker → 引擎 → 桥接）。
    'src/compiler/ty_shadow.cr',
    # R2 P4 Task 2：TYPE(7) 段内容构造（D13 确定性装填 + 段体缓冲 + corec-only
    # dump 节）。位置 = 影子层之后（装填引用 sh_term_of_ti 与 checker 类型行表；
    # 函数跨文件可见，顺序只为常量可见性与阅读序）、type_selftest 之前（自测段
    # ts_ccr_run 调本文件函数）。**corearch 清单不含本文件**（D18：装填引用
    # 桥接层——corearch 无此层）。
    'src/compiler/ccr_types.cr',
    'src/compiler/type_selftest.cr',
    'src/compiler/purity_selftest.cr',
    'src/compiler/stub_regalloc.cr',
    'src/compiler/stub_regalloc_selftest.cr',
    'src/compiler/opt.cr',
    'src/compiler/ptr_analysis.cr',
    'src/compiler/region_check.cr',
    'src/compiler/provenance_verify.cr',
    'src/compiler/diag.cr',
    'src/compiler/ext_mgr.cr',
    'src/compiler/ext_safety.cr',
    'src/compiler/ir_gen.cr',
    # R2 P3 Task 5：自 backend_support_files 迁入（原因与 corearch 零引用证据见该段注）。
    # 位置 = ir_gen 之后（函数跨文件可见与顺序无关；本文件的自有全局只在本文件使用）。
    'src/compiler/monomorph.cr',
    'src/compiler/pass.cr',
    'src/compiler/dataflow.cr',
    'src/compiler/ccr_lower.cr',
    'src/compiler/ccr_io.cr',
    'src/lattice/ent_kernel.cr',
    'src/lattice/regalloc_cag.cr',
    'src/compiler/module.cr',
    'src/stdlib/toml.cr',
    'src/stdlib/hotpatch.cr',
    'src/stdlib/arena.cr',
    'src/stdlib/goroutine.cr',
    'src/stdlib/chan.cr',
    'src/stdlib/sched.cr',
    'src/compiler/project.cr',
    'src/stdlib/os.cr',
    'src/compiler/interp.cr',
    'src/compiler/dump.cr',
    'src/compiler/cir_cache.cr',
    'src/compiler/main.cr',
]
