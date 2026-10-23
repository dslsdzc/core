// src/kernel/kernel_main.cr —— 内核 CLI（protocol.md §1/§4/§7）
// 用法：kernel QUERY_FILE...（与参考 harness 一致：文件参数，非 stdin——
//       Core 无 stdin API，run_diff.py 已按文件参数模式接线）
// 行处理：跳过 # 注释（允许前导空白）与空行；每行复位
//   g_kernel_count / g_ctx_len / g_env_len（arena/ctx/env 三复位纪律——
//   否则 arena 满后全部查询静默 reject，大规模假阴性）
// malformed 行（解析失败/未知命令）：不输出（保持 stdout 干净——
//   Core 无 stderr API，诊断省略）、计数、最终退出码 1。
//
// 接口约定（对拍接线，Task 6 手工移植侧）：
//   check.cr 必须提供：type_check(a, m) -> int   （1=接受；0/负=拒绝；
//        参数序 = (类型, 项)——协议行是「项在前、类型在后」，此处已交换）
//                      type_infer(m) -> int      （返回推断类型 nf 节点；-1=拒绝）
//   subtype.cr 必须提供：subtyping(a, b) -> int  （1=是；0/负=否）
//   ctx 从 mctt.cr 全局读取（g_ctx_buf/g_ctx_len）；nbe 用 nbe.cr 的
//   kern_nbe / kern_nbe_ty（读同一全局 ctx）。
// 依赖：mctt.cr（ctx）、nbe.cr（kern_nbe/环境）、term_io.cr（解析/打印）、
//   fmt.cr（str_len/str_sub/load8）、io.cr（println/read_file）、rt.cr（argv）。

// ── nf 相等（Syntax.v nf_eq_dec，convert 用）：nf/ne 结构相等 ──
fn nf_sub_eq(a: int, b: int) -> int:
    if a < 0 || b < 0:
        return 0
    ka := kern_get(a, 0)
    kb := kern_get(b, 0)
    if ka != K_SUB || kb != K_SUB:
        return 0
    sa := kern_get(a, 4)
    sb := kern_get(b, 4)
    if sa != sb:
        return 0
    if sa == S_ID || sa == S_WEAKEN:
        return 1
    if sa == S_COMPOSE:
        return nf_sub_eq(kern_get(a, 1), kern_get(b, 1)) != 0 && nf_sub_eq(kern_get(a, 2), kern_get(b, 2)) != 0
    if sa == S_EXTEND:
        return nf_sub_eq(kern_get(a, 1), kern_get(b, 1)) != 0 && nf_eq(kern_get(a, 2), kern_get(b, 2)) != 0
    return 0

fn nf_eq(a: int, b: int) -> int:
    if a < 0 || b < 0:
        return 0
    ka := kern_get(a, 0)
    kb := kern_get(b, 0)
    if ka != kb:
        return 0
    if ka == K_TYP:
        return kern_get(a, 1) == kern_get(b, 1)
    if ka == K_NAT || ka == K_ZERO:
        return 1
    if ka == K_SUCC:
        return nf_eq(kern_get(a, 1), kern_get(b, 1))
    if ka == K_VAR:
        return kern_get(a, 1) == kern_get(b, 1)
    if ka == K_NATREC:
        return nf_eq(kern_get(a, 1), kern_get(b, 1)) != 0 && nf_eq(kern_get(a, 2), kern_get(b, 2)) != 0 && nf_eq(kern_get(a, 3), kern_get(b, 3)) != 0 && nf_eq(kern_get(a, 4), kern_get(b, 4)) != 0
    if ka == K_PI || ka == K_FN || ka == K_APP:
        return nf_eq(kern_get(a, 1), kern_get(b, 1)) != 0 && nf_eq(kern_get(a, 2), kern_get(b, 2)) != 0
    if ka == K_SUB:
        return nf_eq(kern_get(a, 1), kern_get(b, 1)) != 0 && nf_sub_eq(kern_get(a, 2), kern_get(b, 2)) != 0
    return 0

// ── 行处理 ──
g_kernel_malformed : int, mut = 0

// (ctx exp*)：按出现顺序压入 ctx（协议 §3：e1 = 头部 = 最近绑定，与
// ctx_extend 的压头语义一致）。失败返回 -1。
fn kern_parse_ctx() -> int:
    kp_skip_ws()
    if kp_expect(40) == 0:
        return -1
    kp_skip_ws()
    if kp_take_name("ctx") == 0:
        return -1
    loop:
        kp_skip_ws()
        if g_kernel_parse_pos < kp_len() && load8(g_kernel_parse_text, g_kernel_parse_pos) == 41:
            kp_expect(41)
            return 1
        e := parse_exp()
        if e < 0:
            return -1
        ctx_extend(e)
    return 1

// 校验行尾无残留；有残留 → malformed
fn kern_line_end_ok() -> int:
    kp_skip_ws()
    if g_kernel_parse_pos < kp_len():
        return 0
    return 1

// 处理一行查询；返回 0=正常（已输出）、1=malformed（无输出、计数）
fn kern_process_line(line: string) -> int:
    // 前导空白 + 空行 / # 注释 → 跳过（无输出）
    pos : ., mut = 0
    loop:
        if pos >= str_len(line):
            break
        c := load8(line, pos)
        if c == 32 || c == 9 || c == 13:
            pos = pos + 1
        else:
            break
    if pos >= str_len(line):
        return 0
    if load8(line, pos) == 35:
        return 0
    // '#'

    // 每行三复位（arena / ctx / env）——直接调 parse_exp/parse_sub，勿用
    // kernel_parse（它每次复位 arena 且要求整行单 exp）
    g_kernel_count = 0
    g_ctx_len = 0
    g_kernel_parse_text = line
    g_kernel_parse_pos = pos

    if kp_take_name("check") != 0:
        if kern_parse_ctx() < 0:
            g_kernel_malformed = g_kernel_malformed + 1
            return 1
        m := parse_exp()
        a := parse_exp()
        if m < 0 || a < 0:
            g_kernel_malformed = g_kernel_malformed + 1
            return 1
        if kern_line_end_ok() == 0:
            g_kernel_malformed = g_kernel_malformed + 1
            return 1
        r := type_check(a, m)                       // 协议：项在前类型在后 → 交换
        if r > 0:
            println("check: accept")
        else:
            println("check: reject")
        return 0
    if kp_take_name("infer") != 0:
        if kern_parse_ctx() < 0:
            g_kernel_malformed = g_kernel_malformed + 1
            return 1
        m := parse_exp()
        if m < 0:
            g_kernel_malformed = g_kernel_malformed + 1
            return 1
        if kern_line_end_ok() == 0:
            g_kernel_malformed = g_kernel_malformed + 1
            return 1
        r := type_infer(m)
        if r >= 0:
            println("infer: type: " + kernel_print(r))
        else:
            println("infer: reject")
        return 0
    if kp_take_name("convert") != 0:
        if kern_parse_ctx() < 0:
            g_kernel_malformed = g_kernel_malformed + 1
            return 1
        t1 := parse_exp()
        t2 := parse_exp()
        tv := parse_exp()
        if t1 < 0 || t2 < 0 || tv < 0:
            g_kernel_malformed = g_kernel_malformed + 1
            return 1
        if kern_line_end_ok() == 0:
            g_kernel_malformed = g_kernel_malformed + 1
            return 1
        n1 := kern_nbe(t1, tv)
        n2 := kern_nbe(t2, tv)
        if n1 >= 0 && n2 >= 0 && nf_eq(n1, n2) != 0:
            println("convert: yes")
        else:
            println("convert: no")
        return 0
    if kp_take_name("subtype") != 0:
        if kern_parse_ctx() < 0:
            g_kernel_malformed = g_kernel_malformed + 1
            return 1
        a := parse_exp()
        b := parse_exp()
        if a < 0 || b < 0:
            g_kernel_malformed = g_kernel_malformed + 1
            return 1
        if kern_line_end_ok() == 0:
            g_kernel_malformed = g_kernel_malformed + 1
            return 1
        r := subtyping(a, b)
        if r > 0:
            println("subtype: yes")
        else:
            println("subtype: no")
        return 0
    g_kernel_malformed = g_kernel_malformed + 1
    return 1

// ── 入口 ──
fn kernel_main() -> int:
    // get_arg 是内建（instr.cr:701，corec 同款）：get_arg(0)=argc（字符串），
    // get_arg(i) = 第 i 个参数（i ≥ 1）；到空串结束
    n : ., mut = 1
    files : ., mut = 0
    loop:
        a := get_arg(n)
        if str_len(a) == 0:
            break
        txt := read_file(a)
        tl := str_len(txt)
        pos : ., mut = 0
        loop:
            if pos >= tl:
                break
            end := pos
            loop:
                if end >= tl:
                    break
                if load8(txt, end) == 10:
                    break
                end = end + 1
            line := str_sub(txt, pos, end - pos)
            kern_process_line(line)
            if end >= tl:
                break
            pos = end + 1
        files = files + 1
        n = n + 1
    if files <= 0:
        return 1
    // usage：无文件参数
    if g_kernel_malformed > 0:
        return 1
    return 0
