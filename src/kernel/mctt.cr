fn mk_typ(i : int) -> int:
    n := kern_new(K_TYP)
    kern_set(n , 1 , i)
    return n

fn mk_pi(a : int , b : int) -> int:
    n := kern_new(K_PI)
    kern_set(n , 1 , a)
    kern_set(n , 2 , b)
    return n

fn mk_natrec(a : int , mz : int , ms : int , m : int) -> int:
    n := kern_new(K_NATREC)
    kern_set(n , 1 , a)
    kern_set(n , 2 , mz)
    kern_set(n , 3 , ms)
    kern_set(n , 4 , m)
    return n

fn mk_nat() -> int:
    return kern_new(K_NAT)
fn mk_zero() -> int:
    return kern_new(K_ZERO)

fn mk_succ(e : int) -> int:
    n := kern_new(K_SUCC)
    kern_set(n , 1 , e)
    return n

fn mk_fn(a : int, m : int) -> int:
    n := kern_new(K_FN)
    kern_set(n , 1 , a)
    kern_set(n , 2 , m)
    return n

fn mk_app(m : int, n : int) -> int:
    n := kern_new(K_APP)
    kern_set(n , 1 , m)
    kern_set(n , 2 , n)
    return n

fn mk_var(x : int) -> int:
    n := kern_new(K_VAR)
    kern_set(n , 1 , x)
    return n

fn mk_sub(e : int, s : int) -> int:
    n := kern_new(K_SUB)
    kern_set(n , 1 , e)
    kern_set(n , 2 , s)
    return n

fn mk_id() -> int:
    n := kern_new(K_SUB)
    kern_set(n , 4 , S_ID)
    return n

fn mk_weaken() -> int:
    n := kern_new(K_SUB)
    kern_set(n , 4 , S_WEAKEN)
    return n

fn mk_compose(s1 : int, s2 : int) -> int:
    n := kern_new(K_SUB)
    kern_set(n , 1 , s1)
    kern_set(n , 2 , s2)
    kern_set(n , 4 , S_COMPOSE)
    return n

fn mk_extend(s : int, e : int) -> int:
    n := kern_new(K_SUB)
    kern_set(n , 1 , s)
    kern_set(n , 2 , e)
    kern_set(n , 4 , S_EXTEND)
    return n

fn kern_kind(e : int) -> int:
    return kern_get(e , 0)
fn exp_a(e : int) -> int:
    return kern_get(e , 1)
fn exp_b(e : int) -> int:
    return kern_get(e , 2)

g_ctx_buf : string , mut
g_ctx_len : int , mut = 0
g_ctx_cap : int , mut = 0

fn ctx_extend(a : int):
    if g_ctx_len >= g_ctx_cap:
        nc := g_ctx_cap * 2
        if nc == 0:
            nc = 16
        nb := alloc( nc * 8 )
        i : . , mut = 0
        loop:
            if i >= g_ctx_len:
                break
            cell_store(nb , i * 8 , cell_load(g_ctx_buf , i * 8))
            i = i + 1
        g_ctx_buf = nb
        g_ctx_cap = nc
    cell_store(g_ctx_buf , g_ctx_len * 8 , a)
    g_ctx_len = g_ctx_len + 1

fn ctx_get(x : int) -> int:
    if x < 0 || x >= g_ctx_len:
        return -1
    return cell_load(g_ctx_buf , (g_ctx_len - 1 -x) * 8)
