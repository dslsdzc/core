#!/usr/bin/env python3
"""TODO #5 回归：cir 缓存缺编译器身份 ⇒ 跨编译器重建不失效（2026-09-11 修复）。

背景（RED，修复前实测，pre-fix 二进制 sha256 f0f00d7d…）：
  缓存键 = 源路径::函数名，头部指纹 = magic/格式版本/纯 AST 指纹（只覆盖目标源）
  ——**无编译器身份分量**。二进制重建后字符串驻留序（g_strs intern 序）漂移，
  而键与指纹一字未变 ⇒ 旧条目被命中，旧序索引被当活产物使用。
  实测（手工，pre-fix）：把 alpha 条目内 var[0]/var[2] 的 name_ni（2 ↔ 146）
  互换（=「另一个编译器写下的」索引序）后重跑——条目原样未被重写（命中），
  dump 通道随之错位：`binary 24 = a + b` → `24 = 20 + b`、`dest=22` → `dest=a`，
  rc=0 静默污染。（同族第二实例 = 同一二进制冷/热缓存 dump 渲染差异，见
  TODO #5 末条，非本单。）

修复：缓存头写入**运行中编译器自身 ELF 的内容哈希**（/proc/self/exe 全文件
  单趟乘加哈希，cir_cache.cr cir_compiler_identity/cir_hash_running_binary），
  装载时比对：不等 = cache miss = 无害重建。身份取不到（无 procfs/读取失败）
  则两端点均关缓存（绝不落「身份 0」条目——那是同一静默类的退化复活）。
  头部布局 v16→v17 整体后移 8B（magic/ver/identity/fp/sig/name_len/name…）。
  与 CIR_CACHE_VER 的分工：VER = 手工粗粒度（格式/行为代），身份 = 自动细粒度
  （编译器内容驱动）——两者都必须匹配才命中。

判据（5 组 7 例）：
  ① identity_semantics：条目身份字段 == FNV-1(运行中编译器 ELF 全文件) 且 ver==VER_EXPECTED（**#78 批 2 起 = 18**）
  ② same_identity_hit：同身份条目仍命中（正常路径无退化）——改条目内**被装载
     跳过**的“函数名字节”（canary），重跑后字节原样留存（命中 = 从不重写）
  ③ foreign_identity_rejected：身份字段被改（+载荷 name_ni 互换，模拟异序）→
     重跑后条目身份被改写回当前身份、载荷被重建（= 判为 miss 并整体重算）
  ④ foreign_entry_fully_discarded（差分）：「条目缺失」与「条目毒化（身份+载荷）」
     两次运行的 stdout dump 逐字节相同 + 重建出的条目逐字节相同 ⇒ 外来条目被
     完整丢弃、以全新产物替代（修复前该差分必然非零：毒化条目被当命中沿用）
  ⑤ cross_binary_ab：两份**内容不同**的编译器二进制共用一个缓存目录（同一份
     源码构建出的新二进制 = 同内容副本 + 追加一字节）——A 写的条目不被 B 接受：
     canary 被重写抹除 + 条目身份改写为 B；反向亦然。
     （人工另以真实第二编译器 corec2 = `corec build src/compiler/main.cr` 自举
     产物验证同判据：身份 3584… vs -3398…，条目被改写为运行方身份。）
"""

import os
import pathlib
import shutil
import struct
import subprocess
import tempfile

BASE = pathlib.Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"
CACHE_DIR = BASE / ".core" / "cache" / "cir"

# 17 → 18：TODO #78「聚合读丢型」批 2（裁-AGG-7）换代——旧值 17 / 新值 18 /
# 归因 = 聚合读结果槽型由 TI_INT 改为声明面形式（旧快照与新语义不等价，命中旧条目会把
# 「丢型」的坏 IR 复活）/ 出处 = docs/superpowers/plans/2026-09-16-agg-read-type.md §12.4·§13。
# **布局未变**（v18 与 v17 同构：magic/ver/identity/fp/sig/name_len/name…）⇒ layout() 的
# v17 分支按 VER_EXPECTED 复用。
VER_EXPECTED = 18
FNV_OFFSET = -3750763034362895579   # FNV-1 64 offset basis（signed i64）
FNV_PRIME = 1099511628211
M64 = 1 << 64

PROBE = """// cache identity probe (tests/selfhost/test_cache_identity.py)
fn alpha(a: int, b: int) -> int {
    x := a + b;
    y := x * 2;
    z := y - a;
    return z;
}

fn beta(p: int) -> int {
    m := p + 1;
    n := m * m;
    return n;
}

fn main() -> int {
    return alpha(3, 4) + beta(5);
}
"""


def fnv1_64(data: bytes) -> int:
    """cir_hash_running_binary 的 Python 独立实现（8 字节小端字 + 余尾逐字节 +
    末尾混入总长；见 cir_cache.cr 该函数头注）。"""
    h = FNV_OFFSET
    n = len(data)
    i = 0
    while i + 8 <= n:
        w = int.from_bytes(data[i:i + 8], "little", signed=True)
        h = (h * FNV_PRIME + w) % M64
        i += 8
    while i < n:
        h = (h * FNV_PRIME + data[i]) % M64
        i += 1
    h = (h * FNV_PRIME + n) % M64
    return h - M64 if h >= (1 << 63) else h


def identity_of(path: pathlib.Path) -> int:
    return fnv1_64(path.read_bytes())


def layout(d: bytes):
    """按头部版本给出字段偏移（v17 = 本修复；v16 = 修复前布局，用于 RED 对照）。"""
    ver = struct.unpack_from("<q", d, 8)[0]
    if ver == VER_EXPECTED:          # magic/ver/identity/fp/sig/name_len
        return {"ver": ver, "ident_off": 16, "name_len_off": 40, "name_off": 48}
    if ver == 16:                    # magic/ver/fp/sig/name_len（无身份字段）
        return {"ver": ver, "ident_off": None, "name_len_off": 32, "name_off": 40}
    return {"ver": ver, "ident_off": None, "name_len_off": None, "name_off": None}


def parse_entry(p: pathlib.Path):
    d = p.read_bytes()
    lay = layout(d)
    out = dict(lay, raw=d, identity=None, name=b"", var_base=-1)
    if lay["name_off"] is None:
        return out
    name_len = struct.unpack_from("<q", d, lay["name_len_off"])[0]
    out["name"] = d[lay["name_off"]:lay["name_off"] + name_len]
    out["var_base"] = lay["name_off"] + name_len + 8   # 跳过 name + var_count
    if lay["ident_off"] is not None:
        out["identity"] = struct.unpack_from("<q", d, lay["ident_off"])[0]
    return out


def var_name_ni(p: pathlib.Path, i: int) -> int:
    info = parse_entry(p)
    if info["var_base"] < 0:
        return -1
    return struct.unpack_from("<q", info["raw"], info["var_base"] + i * 24)[0]


def poison(path: pathlib.Path, identity: bool, payload: bool):
    """模拟「另一个编译器写下的条目」：身份字段被改 + var 名索引序漂移。"""
    info = parse_entry(path)
    d = bytearray(info["raw"])
    if identity and info["ident_off"] is not None:
        struct.pack_into("<q", d, info["ident_off"], info["identity"] ^ 0x5A5A5A5A)
    if payload and info["var_base"] >= 0:
        base = info["var_base"]
        a = struct.unpack_from("<q", d, base + 0 * 24)[0]
        b = struct.unpack_from("<q", d, base + 2 * 24)[0]
        struct.pack_into("<q", d, base + 0 * 24, b)
        struct.pack_into("<q", d, base + 2 * 24, a)
    path.write_bytes(bytes(d))


def set_name_canary(path: pathlib.Path) -> bytes:
    """把条目内被装载跳过的“函数名字节”改成同长 canary；返回 canary。"""
    info = parse_entry(path)
    d = bytearray(info["raw"])
    n = len(info["name"])
    canary = b"X" * n
    d[info["name_off"]:info["name_off"] + n] = canary
    path.write_bytes(bytes(d))
    return canary


def strip_dot_line(stdout: str, dot: pathlib.Path) -> str:
    """剔除只含输出路径的行（两次运行同一路径时本就相同；防御性过滤）。"""
    return "\n".join(l for l in stdout.splitlines() if str(dot) not in l)


def run_corec(compiler: pathlib.Path, src: pathlib.Path, dot: pathlib.Path):
    """corec cir（cwd=BASE：import 解析与缓存目录都在仓根——见 CLAUDE.md）。"""
    return subprocess.run(
        [str(compiler), "cir", str(src), "-o", str(dot)],
        capture_output=True, text=True, cwd=BASE, timeout=180,
    )


def entry_path(src: pathlib.Path, fn_name: str) -> pathlib.Path:
    return CACHE_DIR / f"{str(src).replace('/', '_')}::{fn_name}.cir"


def main():
    failures = []
    checks = 0

    fd, src_name = tempfile.mkstemp(suffix="_cacheid_probe.cr")
    src = pathlib.Path(src_name)
    with os.fdopen(fd, "w") as f:
        f.write(PROBE)
    tmpdir = pathlib.Path(tempfile.mkdtemp(prefix="core_cacheid_"))
    dot = tmpdir / "probe.cir"
    alpha = entry_path(src, "alpha")

    def cleanup_cache():
        # 只清本探针 key（前缀 = 探针源路径的 sanitize 形态）的条目，不牵动他者。
        prefix = str(src).replace("/", "_")
        for p in CACHE_DIR.glob(f"{prefix}::*.cir"):
            try:
                p.unlink()
            except FileNotFoundError:
                pass

    def check(name, cond, detail=""):
        nonlocal checks
        checks += 1
        print(f"[{'PASS' if cond else 'FAIL'}] {name}{(' — ' + detail) if detail else ''}")
        if not cond:
            failures.append(name)

    try:
        if not COREC.exists():
            print("[FAIL] 缺 build/corec（先跑 build_selfhost_native.py）")
            return 1
        expect_id = identity_of(COREC)
        cleanup_cache()

        # ① 身份语义：条目身份 = 运行中编译器 ELF 全文件哈希 + 版本 VER_EXPECTED（#78 批 2 起 = 18）
        r = run_corec(COREC, src, dot)
        if r.returncode != 0 or not alpha.exists():
            print(f"[FAIL] 探针首次编译失败 rc={r.returncode} alpha_exists={alpha.exists()}\n{r.stdout}{r.stderr}")
            return 1
        info = parse_entry(alpha)
        check("identity_semantics",
              info["ver"] == VER_EXPECTED and info["identity"] == expect_id,
              f"ver={info['ver']} identity={info['identity']} expect={expect_id}")

        # ② 同身份命中：改「被装载跳过」的函数名字节，重跑必须原样留存
        canary = set_name_canary(alpha)
        r = run_corec(COREC, src, dot)
        now = parse_entry(alpha)
        check("same_identity_hit",
              r.returncode == 0 and now["name"] == canary,
              f"name_canary={'kept（命中）' if now['name'] == canary else 'rewritten（miss）'}")

        # ③ 异身份拒绝：身份+载荷毒化 → 条目被改写回当前身份、载荷被重建
        v0_clean = var_name_ni(alpha, 0)
        v2_clean = var_name_ni(alpha, 2)
        if v0_clean == v2_clean:
            print("[FAIL] 探针要求 var[0]/var[2] 名索引不同")
            return 1
        poison(alpha, identity=True, payload=True)
        r = run_corec(COREC, src, dot)
        after = parse_entry(alpha)
        check("foreign_identity_rejected",
              r.returncode == 0 and after["identity"] == expect_id
              and var_name_ni(alpha, 0) == v0_clean and var_name_ni(alpha, 2) == v2_clean,
              f"identity_after={after['identity']}（==当前 ⇒ miss 重算）")

        # ④ 差分：条目缺失 vs 条目毒化 —— dump/重建条目必须逐字节相同
        alpha.unlink()
        r_x = run_corec(COREC, src, dot)
        dot_x, entry_x = dot.read_bytes(), alpha.read_bytes()
        poison(alpha, identity=True, payload=True)
        r_y = run_corec(COREC, src, dot)
        dot_y, entry_y = dot.read_bytes(), alpha.read_bytes()
        check("foreign_entry_fully_discarded",
              r_x.returncode == 0 and r_y.returncode == 0 and dot_x == dot_y
              and entry_x == entry_y
              and strip_dot_line(r_x.stdout, dot) == strip_dot_line(r_y.stdout, dot),
              "条目缺失 ≡ 条目毒化（dump + 重建条目逐字节同）")

        # ⑤ 跨二进制 A/B：内容不同的编译器不共享条目（canary 判据与版本无关）
        compiler_b = tmpdir / "corec_rebuilt"
        shutil.copyfile(COREC, compiler_b)
        os.chmod(compiler_b, 0o755)
        with open(compiler_b, "ab") as fb:
            fb.write(b"\x00")          # 重建后的新编译器（语义同、内容异）
        id_b = identity_of(compiler_b)
        if id_b == expect_id:
            print("[FAIL] 副本身份与本体相同（内容哈希失效）")
            return 1
        run_corec(COREC, src, dot)                    # A 写条目
        a_ident = parse_entry(alpha)["identity"]
        canary = set_name_canary(alpha)
        r_b = run_corec(compiler_b, src, dot)         # B 读 A 的条目
        after_b = parse_entry(alpha)
        r_a = run_corec(COREC, src, dot)              # A 再读 B 的条目
        after_a = parse_entry(alpha)
        check("cross_binary_ab",
              r_b.returncode == 0 and r_a.returncode == 0
              and after_b["name"] != canary               # B 拒绝并重写（canary 被抹）
              and after_b["identity"] == id_b
              and after_a["identity"] == expect_id,
              f"A写={a_ident} → B读后={after_b['identity']}(=B身份, canary "
              f"{'gone' if after_b['name'] != canary else 'KEPT!'}) → A读后={after_a['identity']}")

        print(f"{checks - len(failures)}/{checks} passed")
        for f in failures:
            print(f"  FAILED: {f}")
        return 0 if not failures else 1
    finally:
        cleanup_cache()
        try:
            src.unlink()
        except FileNotFoundError:
            pass
        shutil.rmtree(tmpdir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
