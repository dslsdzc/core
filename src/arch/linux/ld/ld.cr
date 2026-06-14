// === arch/linux/ld/ld.cr ===
// Core dynamic ELF linker — mold-inspired chunk architecture.
//
// Chunks (kind dispatch):
//   0 = EhdrChunk    — ELF header + program headers
//   1 = InterpChunk  — .interp
//   2 = UserChunk    — user code (.text)
//   3 = PltChunk     — .plt (header + entries)
//   4 = GotPltChunk  — .got.plt
//   5 = DynChunk     — .dynamic
//   6 = DynsymChunk  — .dynsym
//   7 = DynstrChunk  — .dynstr
//   8 = RelaChunk    — .rela.plt
//
// Pipeline:
//   ctx_init()
//   ctx_add_so("core_io.so")
//   ctx_add_plt("__builtin_print", 0)
//   ctx_set_user_code(code, size)
//   ctx_emit_dyn(buf, "output")  // or ctx_emit_so for --shared

// ============================================================
// Constants
// ============================================================

MAX_SO : int = 8;
MAX_PLT : int = 128;

SHT_DYNAMIC  : int = 6;
SHT_DYNSYM   : int = 11;
STB_GLOBAL   : int = 1;
STT_FUNC     : int = 2;
SHN_UNDEF    : int = 0;
DT_NULL      : int = 0;
DT_NEEDED    : int = 1;
DT_PLTGOT    : int = 3;
DT_STRTAB    : int = 5;
DT_SYMTAB    : int = 6;
DT_STRSZ     : int = 10;
DT_SYMENT    : int = 11;
DT_PLTRELSZ  : int = 2;
DT_PLTREL    : int = 20;
DT_JMPREL    : int = 23;

// ============================================================
// .so tracking
// ============================================================

g_so_paths : [string; MAX_SO], mut;
g_so_count : int, mut;

// ============================================================
// PLT entries
// ============================================================

struct PltEntry { name: string, so_idx: int }
g_plts : [PltEntry; MAX_PLT], mut;
g_plt_count : int, mut;

// ============================================================
// Linker state
// ============================================================

g_user_code : string, mut;
g_user_size : int, mut;
g_text_base : int, mut;

// Flat chunk arrays (avoid struct array compiler limitation)
g_ch_kind : [int; 10], mut;
g_ch_vaddr : [int; 10], mut;
g_ch_foff : [int; 10], mut;
g_ch_size : [int; 10], mut;
g_ch_count : int, mut;

// ============================================================
// Chunk helpers
// ============================================================

fn cnew(k: int) {
    g_ch_kind[g_ch_count] = k;
    g_ch_vaddr[g_ch_count] = 0;
    g_ch_foff[g_ch_count] = 0;
    g_ch_size[g_ch_count] = 0;
    g_ch_count = g_ch_count + 1; }

fn cby(k: int) -> int {
    i : ., mut = 0;
    loop {
        if i >= g_ch_count { break; }
        if g_ch_kind[i] == k { return i; }
        i = i + 1; }
    return 0; }

// ============================================================
// .so symbol lookup
// ============================================================

fn so_find(buf: string, name: string) -> int {
    if __builtin_str_len(buf) < 64 { return -1; }
    if r16(buf, 16) != 3 { return -1; }
    e_shoff := r64(buf, 40); e_shnum := r16(buf, 60);
    do : ., mut = 0; ds : ., mut = 0; so : ., mut = 0; ss : ., mut = 0;
    i : ., mut = 0; loop { if i >= e_shnum { break; }
        t := r32(buf, e_shoff+i*64+4); a := r64(buf, e_shoff+i*64+16);
        o := r64(buf, e_shoff+i*64+24); s := r64(buf, e_shoff+i*64+32);
        if t == 11 { do = o; ds = s; }
        if t == 3 && a != 0 { so = o; ss = s; }
        i = i + 1; }
    if ds == 0 || ss == 0 { return -1; }
    sc := ds / 24;
    i = 0; loop { if i >= sc { break; }
        sn := r32(buf, do+i*24); sv := r64(buf, do+i*24+8);
        si := bu8(buf, do+i*24+4); sx := r16(buf, do+i*24+6);
        if si/16 == 1 && si%16 == 2 && sx != 0 {
            nm : ., mut = ""; k : ., mut = sn;
            loop { if k >= ss { break; }
                c := bu8(buf, so+k); if c == 0 { break; }
                sc2 := __builtin_str_get(" ",0); __builtin_store8(sc2,0,c);
                nm = nm + sc2; k = k + 1; }
            if __builtin_str_len(nm) > 0 && __builtin_str_eq(nm, name) != 0 { return sv; }
        }
        i = i + 1; }
    return -1; }

fn so_find_any(name: string) -> int {
    si : ., mut = 0; loop { if si >= g_so_count { break; }
        if __builtin_str_len(g_so_paths[si]) > 0 {
            b := __builtin_read_file(g_so_paths[si]);
            if __builtin_str_len(b) > 0 {
                a := so_find(b, name);
                if a >= 0 { return a; } }
        }
        si = si + 1; }
    return -1; }

// ============================================================
// Layout — assign VA and file offsets to all chunks
// ============================================================

fn layout() {
    va : ., mut = g_text_base;
    i : ., mut = 0; loop { if i >= g_ch_count { break; }
        sz : ., mut = 0;
        k := g_ch_kind[i];
        if k == 0 { sz = 288; }
        if k == 1 { sz = 29; }
        if k == 2 { sz = g_user_size; }
        if k == 3 { sz = 32 + g_plt_count * 16; }
        if k == 4 { sz = (3 + g_plt_count) * 8; }
        if k == 5 { sz = 10 * 16; }
        if k == 6 { sz = (1 + g_plt_count) * 24; }
        if k == 7 {
            sz = 1 + __builtin_str_len("core_librt.so") + 1;
            j : ., mut = 0; loop { if j >= g_plt_count { break; }
                sz = sz + __builtin_str_len(g_plts[j].name) + 1; j = j + 1; } }
        if k == 8 { sz = g_plt_count * 24; }
        g_ch_vaddr[i] = va;
        g_ch_foff[i] = va - g_text_base;
        g_ch_size[i] = sz;
        va = va + sz;
        i = i + 1; } }

// ============================================================
// Emit — write chunk data to output buffer
// ============================================================

fn w32s(buf: string, pos: int, v: int) { uv : ., mut = v; if uv < 0 { uv = uv + 4294967296; } w32(buf, pos, uv); }

fn emit(buf: string, total: int, is_so: int) {
    // Zero buffer
    zi : ., mut = 0; loop { if zi >= total { break; } w8(buf, zi, 0); zi = zi + 1; }
    tb := g_text_base;
    i : ., mut = 0; loop { if i >= g_ch_count { break; }
        p : ., mut = g_ch_foff[i]; k := g_ch_kind[i];

        // Ehdr: ELF header + 4 program headers
        if k == 0 {
            w8(buf,0,127);w8(buf,1,69);w8(buf,2,76);w8(buf,3,70);
            w8(buf,4,2);w8(buf,5,1);w8(buf,6,1);
            etype : ., mut = 2; if is_so != 0 { etype = 3; }
            w16(buf,16,etype);w16(buf,18,62);w32(buf,20,1);
            uv := cby(2); ev := g_ch_vaddr[uv];
            w64(buf,24,ev); w64(buf,32,64); w64(buf,40,0);
            w16(buf,52,64);w16(buf,54,56);w16(buf,56,4);w16(buf,58,64);
            pe := g_ch_size[i];  // size of this chunk (EHDR+PHDRs)
            // PT_PHDR
            w32(buf,64,6);w32(buf,68,4);w64(buf,72,64);w64(buf,80,tb+64);
            w64(buf,88,tb+64);w64(buf,96,pe-64);w64(buf,104,pe-64);w64(buf,112,8);
            // PT_INTERP
            ic := cby(1);
            w32(buf,120,3);w32(buf,124,4);w64(buf,128,g_ch_foff[ic]);
            w64(buf,136,g_ch_vaddr[ic]);w64(buf,144,g_ch_vaddr[ic]);
            w64(buf,152,g_ch_size[ic]);w64(buf,160,g_ch_size[ic]);w64(buf,168,1);
            // PT_LOAD (RX)
            fs := g_ch_vaddr[g_ch_count-1] + g_ch_size[g_ch_count-1] - tb;
            w32(buf,176,1);w32(buf,180,5);w64(buf,184,0);
            w64(buf,192,tb);w64(buf,200,tb);w64(buf,208,fs);w64(buf,216,fs);w64(buf,224,4096);
            // PT_GNU_STACK
            w32(buf,232,1685382481);w32(buf,236,6);w64(buf,240,0);
            w64(buf,248,0);w64(buf,256,0);w64(buf,264,0);w64(buf,272,0);w64(buf,280,8); }

        // Interp
        if k == 1 {
            is := "/lib64/ld-linux-x86-64.so.2";
            j : ., mut = 0; loop { if j >= __builtin_str_len(is) { break; }
                w8(buf,p+j, __builtin_load8(is,j)); j = j + 1; }
            w8(buf,p+__builtin_str_len(is),0); }

        // User code
        if k == 2 {
            j : ., mut = 0; loop { if j >= g_user_size { break; }
                w8(buf,p+j,bu8(g_user_code,j)); j = j + 1; } }

        // PLT
        if k == 3 {
            gv := g_ch_vaddr[cby(4)]; pv := g_ch_vaddr[i];
            r1 := (gv+8)-(pv+6); w8(buf,p,255);w8(buf,p+1,53);w32s(buf,p+2,r1);
            r2 := (gv+16)-(pv+12); w8(buf,p+6,255);w8(buf,p+7,37);w32s(buf,p+8,r2);
            j : ., mut = 12; loop { if j < 32 { w8(buf,p+j,204); j=j+1; } }
            pi : ., mut = 0; loop { if pi >= g_plt_count { break; }
                eo := p+32+pi*16;
                w8(buf,eo,243);w8(buf,eo+1,15);w8(buf,eo+2,30);w8(buf,eo+3,250);
                w8(buf,eo+4,104);w8(buf,eo+5,pi%256);
                w8(buf,eo+6,255);w8(buf,eo+7,37);
                r3 := (gv+24+pi*8)-(eo+12); w32s(buf,eo+8,r3);
                pi=pi+1; } }

        // GOT.PLT
        if k == 4 {
            dv := g_ch_vaddr[cby(5)];
            w64(buf,p,dv);w64(buf,p+8,0);w64(buf,p+16,0);
            pi : ., mut = 0; loop { if pi >= g_plt_count { break; }
                pv2 := g_ch_vaddr[cby(3)];
                w64(buf,p+24+pi*8,pv2+32+pi*16+4);
                pi=pi+1; } }

        // .dynamic (also writes .dynstr)
        if k == 5 {
            // Build dynstr
            db : ., mut = __builtin_alloc(1024); w8(db,0,0); so_off : ., mut = 1;
            j : ., mut = 0; loop { if j >= __builtin_str_len("core_librt.so") { break; }
                w8(db,so_off+j, __builtin_load8("core_librt.so",j)); j=j+1; }
            w8(db,so_off+__builtin_str_len("core_librt.so"),0);
            nxt : ., mut = so_off+__builtin_str_len("core_librt.so")+1;
            pi : ., mut = 0; loop { if pi >= g_plt_count { break; }
                j=0; loop { if j >= __builtin_str_len(g_plts[pi].name) { break; }
                    w8(db,nxt+j, __builtin_load8(g_plts[pi].name,j)); j=j+1; }
                w8(db,nxt+__builtin_str_len(g_plts[pi].name),0);
                nxt=nxt+__builtin_str_len(g_plts[pi].name)+1; pi=pi+1; }
            // Write dynstr to its chunk
            dsc := cby(7);
            di2 : ., mut = 0; loop { if di2 >= __builtin_str_len(db) { break; }
                w8(buf,g_ch_foff[dsc]+di2,bu8(db,di2)); di2=di2+1; }
            // Write dynamic entries
            sv := g_ch_vaddr[cby(6)]; dv2 := g_ch_vaddr[dsc];
            gv2 := g_ch_vaddr[cby(4)]; rv := g_ch_vaddr[cby(8)];
            rs := g_ch_size[cby(8)];
            de : ., mut = 0;
            w64(buf,p+de*16,5);w64(buf,p+de*16+8,sv);de=de+1;  // DT_SYMTAB
            w64(buf,p+de*16,11);w64(buf,p+de*16+8,24);de=de+1;
            w64(buf,p+de*16,6);w64(buf,p+de*16+8,dv2);de=de+1;  // DT_STRTAB
            w64(buf,p+de*16,10);w64(buf,p+de*16+8,g_ch_size[dsc]);de=de+1;
            w64(buf,p+de*16,3);w64(buf,p+de*16+8,gv2);de=de+1;  // DT_PLTGOT
            w64(buf,p+de*16,2);w64(buf,p+de*16+8,rs);de=de+1;
            w64(buf,p+de*16,20);w64(buf,p+de*16+8,7);de=de+1;  // DT_PLTREL=RELA
            w64(buf,p+de*16,23);w64(buf,p+de*16+8,rv);de=de+1;  // DT_JMPREL
            w64(buf,p+de*16,1);w64(buf,p+de*16+8,so_off);de=de+1;  // DT_NEEDED
            w64(buf,p+de*16,0);w64(buf,p+de*16+8,0); }  // DT_NULL

        // .dynsym (already written by DynChunk for entries 1+, write null entry here)
        if k == 6 {
            pi : ., mut = 0; loop { if pi < 1+g_plt_count { break; }
                so := p+pi*24;
                w32(buf,so,0);w8(buf,so+4,0);w8(buf,so+5,0);
                w16(buf,so+6,0);w64(buf,so+8,0);w64(buf,so+16,0);
                pi=pi+1; } }

        // .rela.plt
        if k == 8 {
            gv3 := g_ch_vaddr[cby(4)];
            pi : ., mut = 0; loop { if pi >= g_plt_count { break; }
                ro := p+pi*24;
                w64(buf,ro,gv3+24+pi*8);
                w64(buf,ro+8,(pi+1)*4294967296+7);
                w64(buf,ro+16,0);
                pi=pi+1; } }
        i = i + 1; } }

// ============================================================
// Relocation patching — fix up call offsets to PLT entries
// ============================================================

fn patch_relocs() {
    if g_x86_ext_rel_count == 0 { return; }
    uc := cby(2); uv := g_ch_vaddr[uc];
    pv := g_ch_vaddr[cby(3)];
    ri : ., mut = 0; loop { if ri >= g_x86_ext_rel_count { break; }
        abs_pos := g_x86_ext_rel_pos[ri];
        code_off : ., mut = abs_pos - 176;
        if code_off < 0 || code_off >= g_user_size { ri=ri+1; continue; }
        fn_name_ni := g_x86_ext_rel_name[ri]; fn_name : ., mut = "";
        if fn_name_ni >= 0 { fn_name = str_get(fn_name_ni); }
        plt_idx : ., mut = -1;
        si : ., mut = 0; loop { if si >= g_plt_count { break; }
            if __builtin_str_eq(g_plts[si].name, fn_name) != 0 { plt_idx = si; break; }
            si = si + 1; }
        if plt_idx >= 0 {
            call_va := uv + code_off;
            plt_va2 := pv + 32 + plt_idx * 16;
            rel := plt_va2 - call_va - 5;
            w32s(g_user_code, code_off + 1, rel); }
        ri = ri + 1; } }

// ============================================================
// Public API
// ============================================================

fn ctx_init() {
    g_ch_count = 0; g_so_count = 0; g_plt_count = 0;
    g_text_base = 4194304; g_user_code = ""; g_user_size = 0; }

fn ctx_set_user_code(data: string, sz: int) { g_user_code = data; g_user_size = sz; }
fn ctx_add_so(path: string) { if g_so_count < MAX_SO { g_so_paths[g_so_count] = path; g_so_count = g_so_count + 1; } }
fn ctx_add_plt(name: string, so_idx: int) {
    if g_plt_count < MAX_PLT { g_plts[g_plt_count] = PltEntry { name = name, so_idx = so_idx }; g_plt_count = g_plt_count + 1; } }

// Produce dynamically-linked ELF executable
fn ctx_emit_dyn(buf: string, path: string) -> int {
    cnew(0); cnew(1); cnew(2); cnew(3); cnew(4); cnew(5); cnew(6); cnew(7); cnew(8);
    layout();
    patch_relocs();
    total := g_ch_vaddr[g_ch_count-1] + g_ch_size[g_ch_count-1] - g_text_base;
    emit(buf, total, 0);
    fd := __builtin_syscall3(2, path, 577, 420);
    if fd < 0 { return -1; }
    nw := __builtin_syscall3(1, fd, buf, total);
    __builtin_syscall3(3, fd, 0, 0);
    return total; }

// Produce shared library (--shared)
fn ctx_emit_so(buf: string, path: string) -> int {
    cnew(0); cnew(2);
    g_ch_count = 2;
    layout();
    total := g_ch_vaddr[g_ch_count-1] + g_ch_size[g_ch_count-1] - g_text_base;
    emit(buf, total, 1);
    fd := __builtin_syscall3(2, path, 577, 420);
    if fd < 0 { return -1; }
    nw := __builtin_syscall3(1, fd, buf, total);
    __builtin_syscall3(3, fd, 0, 0);
    return total; }
