// === ext_mgr.cr ===
// 编译器扩展管理器 — 插件注册表 + 钩子调度
//
// 插件通过 ext_reg() 注册自己监听哪些钩子。
// pass.cr 通过 ext_dispatch() 触发钩子，遍历所有已注册的插件。
//
// 注册流程：
//   1. 每个插件在初始化时调用 ext_reg(hook_type, plugin_id)
//   2. 编译器核心在关键点位调用 pass_*()
//   3. pass_*() 调 ext_dispatch() 遍历注册表
//   4. ext_dispatch() 对每个注册的插件调对应的 handler
//
// 插件 ID（在 ext_plugins.cr 中定义）:
//   EXT_PLUGIN_SAFETY = 1   — 安全检查插件

g_ext_flags : int, mut = 0;
g_ext_inited : int, mut = 0;

// 插件注册表：[hook_type, plugin_id] pairs, flat array
g_ext_reg : string, mut;     g_ext_reg_count : int, mut;  g_ext_reg_cap : int, mut;

// 钩子类型
EXT_HOOK_ARRAY_ACCESS : int = 1;  // 数组访问前
EXT_HOOK_BINARY_OP    : int = 2;  // 二元运算后

fn grow_ext_reg(needed: int) {
    if needed < g_ext_reg_cap { return; }
    ncap : ., mut = g_ext_reg_cap * 2; if ncap < 8 { ncap = 8; } if ncap < needed { ncap = needed + 8; }
    nb := alloc(ncap * 8); _dyncpy(g_ext_reg, g_ext_reg_cap * 8, nb); g_ext_reg = nb; g_ext_reg_cap = ncap;
}

fn ext_init() {
    if g_ext_inited != 0 { return; }
    g_ext_inited = 1;
    g_ext_reg_cap = 0; g_ext_reg_count = 0;
    // 环境变量控制
    ev := get_env("CORE_SAFE");
    if str_len(ev) > 0 && ev == "1" { g_ext_flags = 1; }
    // 内置插件初始化（未来从 .so 加载）
    ext_safety_init();
}

fn ext_has(flag: int) -> int {
    if g_ext_inited == 0 { ext_init(); }
    return g_ext_flags;
}

// 注册一个插件到指定钩子
fn ext_reg(hook_type: int, plugin_id: int) {
    grow_ext_reg(g_ext_reg_count + 1);
    w64(g_ext_reg, g_ext_reg_count * 8, hook_type);
    w64(g_ext_reg, g_ext_reg_count * 8 + 4, plugin_id);
    g_ext_reg_count = g_ext_reg_count + 1;
}

// 分发钩子 — 遍历注册表，调所有匹配的插件
// arr_var / idx_var / idx_lit / arr_len_lit: 数组访问参数
// 返回: 0=继续, 1=跳过此次访问
fn ext_dispatch_array_access(arr_var: int, idx_var: int, idx_lit: int, arr_len_lit: int) -> int {
    if g_ext_inited == 0 { ext_init(); }
    ri : ., mut = 0;
    loop {
        if ri >= g_ext_reg_count { break; }
        ht := r64(g_ext_reg, ri * 8);
        pid := r64(g_ext_reg, ri * 8 + 4);
        if ht == EXT_HOOK_ARRAY_ACCESS {
            if pid == 1 {  // EXT_PLUGIN_SAFETY
                r := ext_safety_on_array_access(arr_var, idx_var, idx_lit, arr_len_lit);
                if r != 0 { return r; }
            }
        }
        ri = ri + 1;
    }
    return 0;
}

// 分发二元运算钩子
fn ext_dispatch_binary_op(op: int, lv: int, rv: int, result_var: int) -> int {
    if g_ext_inited == 0 { ext_init(); }
    ri : ., mut = 0;
    loop {
        if ri >= g_ext_reg_count { break; }
        ht := r64(g_ext_reg, ri * 8);
        pid := r64(g_ext_reg, ri * 8 + 4);
        if ht == EXT_HOOK_BINARY_OP {
            if pid == 1 {
                return ext_safety_on_binary_op(op, lv, rv, result_var);
            }
        }
        ri = ri + 1;
    }
    return 0;
}
