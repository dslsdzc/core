// === type_engine.cr ===
// R2 P0：类型项判定引擎（语义包含 = 集合语义的值包含判定）。
// 本文件在 Task 3 补全（NNF/DNF 规范化消费 + 三态判定 1/0/-1 + 原子互斥公理 +
// μ memo + 预算守卫 g_ty_steps/g_ty_budget_max/g_ty_exhausted）；Task 1 只放
// 原子类常量 + ty_sub 桩（保证自测骨架可编译可跑）。
// 原子类 id 与 g_types 行解耦（spec §1）：natives 用 1:1 映射，结构/命名原子
// 挂 g_types 行（ti = -1 = 类级）。本文件只依赖 type_terms.cr 的公开 API。

// ─── 原子类 id（AK_*）───
AK_INT : int = 0;      AK_DEX : int = 1;     AK_STRING : int = 2;   AK_BOOL : int = 3;
AK_UNIT : int = 4;     AK_NEVER : int = 5;   AK_CHAR : int = 6;     AK_DYN : int = 7;
AK_PRODUCT : int = 8;  AK_SUM : int = 9;     AK_SEQUENCE : int = 10;
AK_REF : int = 11;     AK_PTR : int = 12;    AK_FN : int = 13;      AK_NAMED : int = 14;

// ─── 包含判定（桩）───
// Task 3 替换为真判定（三态：1 = 蕴含、0 = 不蕴含、-1 = 预算耗尽/未覆盖）。
// 桩只覆盖「与构造面代数律重合」的平凡真：同一项、⊤ 上界、⊥ 下界。
fn ty_sub(a: int, b: int) -> int {
    if a == b { return 1; }
    if tt_tag(b) == TT_TOP { return 1; }
    if tt_tag(a) == TT_BOT { return 1; }
    return 0;
}
