// === ext.cr ===
// 编译器扩展管理器 — 插件注册、钩子调度、功能开关
//
// 设计目标：编译器核心不直接依赖任何扩展。扩展通过 pass.cr 的钩子接口
// 注册到编译器流程中，由 ext_init() 根据环境变量/CLI 标志启用。
//
// 钩子类型：
//   EXT_AFTER_IR    — IR 生成后（优化/安全检查插入）
//   EXT_BEFORE_CODEGEN — 代码生成前
//
// 用法：
//   CORE_SAFE=1     — 启用安全检查（越界、溢出等）

g_ext_flags : int, mut = 0;     // 功能开关位图
g_ext_inited : int, mut = 0;    // 是否已初始化

// 扩展功能位
EXT_SAFE : int = 1;             // 运行时安全检查

fn ext_init() {
    if g_ext_inited != 0 { return; }
    g_ext_inited = 1;

    // CORE_SAFE 环境变量
    ev := get_env("CORE_SAFE");
    if str_len(ev) > 0 && ev == "1" { g_ext_flags = g_ext_flags + EXT_SAFE; }

    // TODO: .so 插件加载（未来）
    // - 扫描 ~/.core/plugins/ 或 CORE_PLUGIN_PATH
    // - dlopen() 每个 .so
    // - 调用每个插件的 plugin_init() 注册钩子
}

fn ext_has(flag: int) -> int {
    if g_ext_inited == 0 { ext_init(); }
    if g_ext_flags >= flag { return 1; } else { return 0; }
}
