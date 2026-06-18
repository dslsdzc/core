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
//   ctx_add_plt("print", 0)
//   ctx_set_user_code(code, size)
//   ctx_emit_dyn(buf, "output")  // or ctx_emit_so for --shared

// ============================================================
// Constants
// ============================================================


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

g_so_paths : string, mut; g_so_count : int, mut; g_so_cap : int, mut;

fn dyn_grow_so(needed: int) {
    if needed < g_so_cap { return; }
    nc : ., mut = g_so_cap * 2; if nc < 4 { nc = 4; } if nc < needed { nc = needed + 4; }
    nb := alloc(nc * 8); _dyncpy(g_so_paths, g_so_cap * 8, nb); g_so_paths = nb; g_so_cap = nc; }

struct PltEntry { name: string, so_idx: int }
g_plts : string, mut; g_plt_count : int, mut; g_plt_cap : int, mut;

fn dyn_grow_plts(needed: int) {
    if needed < g_plt_cap { return; }
    nc : ., mut = g_plt_cap * 2; if nc < 16 { nc = 16; } if nc < needed { nc = needed + 16; }
    nb := alloc(nc * 16); _dyncpy(g_plts, g_plt_cap * 16, nb); g_plts = nb; g_plt_cap = nc; }

// ============================================================
// Linker state
// ============================================================

g_user_code : string, mut;
g_user_size : int, mut;
g_text_base : int, mut;

// Flat chunk arrays (avoid struct array compiler limitation)
g_ch_kind : string, mut;                                    g_ch_kind_cap : int, mut;
g_ch_vaddr : string, mut;   g_ch_vaddr_cap : int, mut;
g_ch_foff : string, mut;   g_ch_foff_cap : int, mut;
g_ch_size : string, mut;   g_ch_size_cap : int, mut;
g_ch_count : int, mut;

// ============================================================
// Chunk helpers
// ============================================================

fn dyn_grow_chunks(needed: int) {
    nc : ., mut = g_ch_kind_cap * 2; if nc < 8 { nc = 8; } if nc < needed { nc = needed + 8; }
    nb := alloc(nc * 8); zi : ., mut = 0; loop { if zi >= nc * 8 { break; } store8(nb, zi, 0); zi = zi + 1; } _dyncpy(g_ch_kind, g_ch_kind_cap * 8, nb); g_ch_kind = nb; g_ch_kind_cap = nc;
    nb2 := alloc(nc * 8); zi = 0; loop { if zi >= nc * 8 { break; } store8(nb2, zi, 0); zi = zi + 1; } _dyncpy(g_ch_vaddr, g_ch_vaddr_cap * 8, nb2); g_ch_vaddr = nb2; g_ch_vaddr_cap = nc;
    nb3 := alloc(nc * 8); zi = 0; loop { if zi >= nc * 8 { break; } store8(nb3, zi, 0); zi = zi + 1; } _dyncpy(g_ch_foff, g_ch_foff_cap * 8, nb3); g_ch_foff = nb3; g_ch_foff_cap = nc;
    nb4 := alloc(nc * 8); zi = 0; loop { if zi >= nc * 8 { break; } store8(nb4, zi, 0); zi = zi + 1; } _dyncpy(g_ch_size, g_ch_size_cap * 8, nb4); g_ch_size = nb4; g_ch_size_cap = nc; }

fn cnew(k: int) {
    dyn_grow_chunks(g_ch_count + 1);
    w64(g_ch_kind, g_ch_count * 8, k);
    w64(g_ch_vaddr, g_ch_count * 8, 0);
    w64(g_ch_foff, g_ch_count * 8, 0);
    w64(g_ch_size, g_ch_count * 8, 0);
    g_ch_count = g_ch_count + 1; }

fn cby(k: int) -> int {
    i : ., mut = 0;
    loop {
        if i >= g_ch_count { break; }
        if r64(g_ch_kind, i * 8) == k { return i; }
        i = i + 1; }
    return -1; }  // -1 = not found (callers must guard)

// ============================================================
// .so symbol lookup
// ============================================================

fn so_find(buf: string, name: string) -> int {
    if str_len(buf) < 64 { return -1; }
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
                sc2 := get_char(" ",0); store8(sc2,0,c);
                nm = nm + sc2; k = k + 1; }
            if str_len(nm) > 0 && str_eq(nm, name) != 0 { return sv; }
        }
        i = i + 1; }
    return -1; }

fn so_find_any(name: string) -> int {
    si : ., mut = 0; loop { if si >= g_so_count { break; }
        if istr_len(r64(g_so_paths, si * 8)) > 0 {
            b := read_file(r64(g_so_paths, si * 8));
            if str_len(b) > 0 {
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
        k := r64(g_ch_kind, i * 8);
        if k == 0 { sz = 344; }
        if k == 1 { sz = 29; }
        if k == 2 { sz = g_user_size; }
        if k == 3 { sz = 32 + g_plt_count * 16; }
        if k == 4 { sz = (3 + g_plt_count) * 8; }
        if k == 5 { sz = 10 * 16; }
        if k == 6 { sz = (1 + g_plt_count) * 24; }
        if k == 7 {
            sz = 1 + str_len("core_rt.so") + 1;
            j : ., mut = 0; loop { if j >= g_plt_count { break; }
                sz = sz + istr_len(r64(g_plts, j * 16)) + 1; j = j + 1; } }
        if k == 8 { sz = g_plt_count * 24; }
        w64(g_ch_vaddr, i * 8, va);
        w64(g_ch_foff, i * 8, va - g_text_base);
        w64(g_ch_size, i * 8, sz);
        va = va + sz;
        i = i + 1; }
     }

// ============================================================
// Emit — write chunk data to output buffer
// ============================================================

fn w32s(buf: string, pos: int, v: int) { uv : ., mut = v; if uv < 0 { uv = uv + 4294967296; } w32(buf, pos, uv); }

fn emit(buf: string, total: int, is_so: int) {
    // Zero buffer
    zi : ., mut = 0; loop { if zi >= total { break; } w8(buf, zi, 0); zi = zi + 1; }
    tb := g_text_base;
    i : ., mut = 0; loop { if i >= g_ch_count { break; }
        p : ., mut = r64(g_ch_foff, i * 8); k := r64(g_ch_kind, i * 8);


        // Ehdr: ELF header + 4 program headers
        if k == 0 {
            w8(buf,0,127);w8(buf,1,69);w8(buf,2,76);w8(buf,3,70);
            w8(buf,4,2);w8(buf,5,1);w8(buf,6,1);
            etype : ., mut = 2; if is_so != 0 { etype = 3; }
            w16(buf,16,etype);w16(buf,18,62);w32(buf,20,1);
            uv := cby(2); ev := r64(g_ch_vaddr, uv * 8);
            w64(buf,24,ev); w64(buf,32,64); w64(buf,40,0);
            w16(buf,52,64);w16(buf,54,56);w16(buf,56,5);w16(buf,58,64);
            pe := r64(g_ch_size, i * 8);  // size of this chunk (EHDR+PHDRs)
            // PT_PHDR
            w32(buf,64,6);w32(buf,68,4);w64(buf,72,64);w64(buf,80,tb+64);
            w64(buf,88,tb+64);w64(buf,96,pe-64);w64(buf,104,pe-64);w64(buf,112,8);
            // PT_INTERP
            ic := cby(1);
            w32(buf,120,3);w32(buf,124,4);w64(buf,128,r64(g_ch_foff, ic * 8));
            w64(buf,136,r64(g_ch_vaddr, ic * 8));w64(buf,144,r64(g_ch_vaddr, ic * 8));
            w64(buf,152,r64(g_ch_size, ic * 8));w64(buf,160,r64(g_ch_size, ic * 8));w64(buf,168,1);
            // PT_LOAD (RX)
            fs := r64(g_ch_vaddr, (g_ch_count - 1) * 8) + r64(g_ch_size, (g_ch_count - 1) * 8) - tb;
            w32(buf,176,1);w32(buf,180,7);w64(buf,184,0);
            w64(buf,192,tb);w64(buf,200,tb);w64(buf,208,fs);w64(buf,216,fs);w64(buf,224,4096);
            // PT_GNU_STACK
            w32(buf,232,1685382481);w32(buf,236,6);w64(buf,240,0);
            w64(buf,248,0);w64(buf,256,0);w64(buf,264,0);w64(buf,272,0);w64(buf,280,8);
            // PT_DYNAMIC
            dc := cby(5);
            w32(buf,288,2);w32(buf,292,4);
            w64(buf,296,r64(g_ch_foff, dc * 8));w64(buf,304,r64(g_ch_vaddr, dc * 8));
            w64(buf,312,r64(g_ch_vaddr, dc * 8));
            w64(buf,320,r64(g_ch_size, dc * 8));w64(buf,328,r64(g_ch_size, dc * 8));w64(buf,336,8); }

        // Interp
        if k == 1 {
            is := "/lib64/ld-linux-x86-64.so.2";
            j : ., mut = 0; loop { if j >= str_len(is) { break; }
                w8(buf,p+j, load8(is,j)); j = j + 1; }
            w8(buf,p+str_len(is),0); }

        // User code
        if k == 2 {
            j : ., mut = 0; loop { if j >= g_user_size { break; }
                w8(buf,p+j,bu8(g_user_code,j)); j = j + 1; } }

        // PLT
        if k == 3 {
            gv := r64(g_ch_vaddr, cby(4) * 8); pv := r64(g_ch_vaddr, i * 8);
            r1 := (gv+8)-(pv+6); w8(buf,p,255);w8(buf,p+1,53);w32s(buf,p+2,r1);
            r2 := (gv+16)-(pv+12); w8(buf,p+6,255);w8(buf,p+7,37);w32s(buf,p+8,r2);
            // 4-byte nop (not INT3)
            w8(buf,p+12,15);w8(buf,p+13,31);w8(buf,p+14,64);w8(buf,p+15,0);
            pi : ., mut = 0; loop { if pi >= g_plt_count { break; }
                eo := p+16+pi*16;
                ev := pv + 16 + pi*16;
                // jmp [GOT[3+pi]]
                rg := (gv+24+pi*8)-(ev+6); w8(buf,eo,255);w8(buf,eo+1,37);w32s(buf,eo+2,rg);
                // push $pi (5 bytes)
                w8(buf,eo+6,104); w32(buf,eo+7,pi);
                // jmp PLT[0]
                rp := pv - (ev + 16); w8(buf,eo+11,233); w32s(buf,eo+12,rp);
                pi=pi+1; }  }

        // GOT.PLT
        if k == 4 {
                        dv := r64(g_ch_vaddr, cby(5) * 8);
            w64(buf,p,dv);w64(buf,p+8,0);w64(buf,p+16,0);
            pi : ., mut = 0; loop { if pi >= g_plt_count { break; }
                pv2 := r64(g_ch_vaddr, cby(3) * 8);
                w64(buf,p+24+pi*8,pv2+16+pi*16+6);
                pi=pi+1; } }

        // .dynamic (also writes .dynstr)
        if k == 5 {
            // Compute dynstr size: null + "core_rt.so\0" + all plt names
            dn : ., mut = 1 + str_len("core_rt.so") + 1;
            dnp : ., mut = 0; loop { if dnp >= g_plt_count { break; }
                dn = dn + istr_len(r64(g_plts, dnp * 16)) + 1; dnp = dnp + 1; }
            // Build dynstr
            db : ., mut = alloc(dn); w8(db,0,0); so_off : ., mut = 1;
            j : ., mut = 0; loop { if j >= str_len("core_rt.so") { break; }
                w8(db,so_off+j, load8("core_rt.so",j)); j=j+1; }
            w8(db,so_off+str_len("core_rt.so"),0);
            nxt : ., mut = so_off+str_len("core_rt.so")+1;
            pi : ., mut = 0; loop { if pi >= g_plt_count { break; }
                j=0; loop { if j >= istr_len(r64(g_plts, pi * 16)) { break; }
                    w8(db,nxt+j, load8(r64(g_plts, pi * 16),j)); j=j+1; }
                w8(db,nxt+istr_len(r64(g_plts, pi * 16)),0);
                nxt=nxt+istr_len(r64(g_plts, pi * 16))+1; pi=pi+1; }
            // Write dynstr to its chunk
            dsc := cby(7);
            di2 : ., mut = 0; loop { if di2 >= nxt { break; }
                w8(buf,r64(g_ch_foff, dsc * 8)+di2,bu8(db,di2)); di2=di2+1; }
            // Write dynamic entries
            sv := r64(g_ch_vaddr, cby(6) * 8); dv2 := r64(g_ch_vaddr, dsc * 8);
            gv2 := r64(g_ch_vaddr, cby(4) * 8); rv := r64(g_ch_vaddr, cby(8) * 8);
            rs := r64(g_ch_size, cby(8) * 8);
            de : ., mut = 0;
            w64(buf,p+de*16,5);w64(buf,p+de*16+8,dv2);de=de+1;  // DT_STRTAB
            w64(buf,p+de*16,11);w64(buf,p+de*16+8,24);de=de+1;
            w64(buf,p+de*16,6);w64(buf,p+de*16+8,sv);de=de+1;  // DT_SYMTAB
            w64(buf,p+de*16,10);w64(buf,p+de*16+8,r64(g_ch_size, dsc * 8));de=de+1;
            w64(buf,p+de*16,3);w64(buf,p+de*16+8,gv2);de=de+1;  // DT_PLTGOT
            w64(buf,p+de*16,2);w64(buf,p+de*16+8,rs);de=de+1;
            w64(buf,p+de*16,20);w64(buf,p+de*16+8,7);de=de+1;  // DT_PLTREL=RELA
            w64(buf,p+de*16,23);w64(buf,p+de*16+8,rv);de=de+1;  // DT_JMPREL
            w64(buf,p+de*16,1);w64(buf,p+de*16+8,so_off);de=de+1;  // DT_NEEDED
            w64(buf,p+de*16,0);w64(buf,p+de*16+8,0); }
        
        // .dynsym
        if k == 6 {
            w32(buf,p,0);w8(buf,p+4,0);w8(buf,p+5,0);w16(buf,p+6,0);
            w64(buf,p+8,0);w64(buf,p+16,0);
            so_off2 : ., mut = 1;
            nxt2 : ., mut = 12;
            pi : ., mut = 0; loop { if pi >= g_plt_count { break; }
                so2 := p+(pi+1)*24;
                w32(buf,so2,nxt2);
                w8(buf,so2+4,18); w8(buf,so2+5,0);
                w16(buf,so2+6,0); w64(buf,so2+8,0); w64(buf,so2+16,0);
                nxt2 = nxt2 + istr_len(r64(g_plts, pi * 16)) + 1;
                pi=pi+1; } }

        // .rela.plt
        if k == 8 {
            gv3 := r64(g_ch_vaddr, cby(4) * 8);
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
    uc := cby(2); uv := r64(g_ch_vaddr, uc * 8);
    pv := r64(g_ch_vaddr, cby(3) * 8);
    ri : ., mut = 0; loop { if ri >= g_x86_ext_rel_count { break; }
        abs_pos := r64(g_x86_ext_rel_pos, ri * 8);
        code_off : ., mut = abs_pos - 176;
        if code_off < 0 || code_off >= g_user_size { ri=ri+1; continue; }
        fn_name_ni := r64(g_x86_ext_rel_name, ri * 8); fn_name : ., mut = "";
        if fn_name_ni >= 0 { fn_name = istr_get(fn_name_ni); }
        plt_idx : ., mut = -1;
        si : ., mut = 0; loop { if si >= g_plt_count { break; }
            if str_eq(r64(g_plts, si * 16), fn_name) != 0 { plt_idx = si; break; }
            si = si + 1; }
        if plt_idx >= 0 {
            call_va := uv + code_off;
            plt_va2 := pv + 16 + plt_idx * 16;
            rel := plt_va2 - call_va - 5;
            w32s(g_user_code, code_off, rel); }
        ri = ri + 1; } }

// ============================================================
// Public API
// ============================================================

fn ctx_init() {
    g_ch_count = 0; g_so_count = 0; g_plt_count = 0; g_so_cap = 0; g_plt_cap = 0;
    g_text_base = 4194304; g_user_code = ""; g_user_size = 0; }

fn ctx_set_user_code(data: string, sz: int) { g_user_code = data; g_user_size = sz; }
fn ctx_add_so(path: string) { dyn_grow_so(g_so_count + 1); w64(g_so_paths, g_so_count * 8, path); g_so_count = g_so_count + 1; }
fn ctx_add_plt(name: string, so_idx: int) {
    dyn_grow_plts(g_plt_count + 1); w64(g_plts, g_plt_count * 16, name); w64(g_plts, g_plt_count * 16 + 8, so_idx); g_plt_count = g_plt_count + 1; }

// Produce dynamically-linked ELF executable
fn ctx_emit_dyn(buf: string, path: string) -> int {
        cnew(0); cnew(1); cnew(2); cnew(3); cnew(4); cnew(5); cnew(6); cnew(7); cnew(8);
        layout();
        patch_relocs();
        total := r64(g_ch_vaddr, (g_ch_count - 1) * 8) + r64(g_ch_size, (g_ch_count - 1) * 8) - g_text_base;
     println(int_str(total));
    emit(buf, total, 0);
        fd := syscall3(2, path, 577, 420);
    if fd < 0 { return -1; }
    nw := syscall3(1, fd, buf, total);
    syscall3(3, fd, 0, 0);
    return total; }

// Produce shared library (--shared)
fn ctx_emit_so(buf: string, path: string) -> int {
    cnew(0); cnew(2);
    g_ch_count = 2;
    layout();
    total := r64(g_ch_vaddr, (g_ch_count - 1) * 8) + r64(g_ch_size, (g_ch_count - 1) * 8) - g_text_base;
    emit(buf, total, 1);
    fd := syscall3(2, path, 577, 420);
    if fd < 0 { return -1; }
    nw := syscall3(1, fd, buf, total);
    syscall3(3, fd, 0, 0);
    return total; }

// ============================================================
// Static linking — embed .so text into ELF, resolve relocations
// ============================================================
// Scans all .so files in g_so_paths. For each external symbol
// referenced by user code, looks it up in the .so symbol table
// and copies the needed section into the output.

g_so_off : int, mut;  // .so .text file offset
g_so_sz : int, mut;   // .so .text size
g_so_addr : int, mut; // .so .text base address

fn so_parse_text(buf: string) -> int {
    // Find the executable PROGBITS section (.text) in the .so
    if str_len(buf) < 64 { return -1; }
    e_shoff := r64(buf, 40); e_shnum := r16(buf, 60);
    i : ., mut = 0;
    loop { if i >= e_shnum { break; }
        t := r32(buf, e_shoff+i*64+4); fl := r64(buf, e_shoff+i*64+8);
        a := r64(buf, e_shoff+i*64+16); o := r64(buf, e_shoff+i*64+24); s := r64(buf, e_shoff+i*64+32);
        // SHT_PROGBITS(1) + SHF_ALLOC|SHF_EXECINSTR(6) = .text
        if t == 1 && fl == 6 && s > 0 {
            g_so_off = o; g_so_sz = s; g_so_addr = a;
            return 0; }
        i = i + 1; }
    return -1; }

fn ctx_emit_static(buf: string, path: string) -> int {
    so_buf : ., mut = "";
    si : ., mut = 0;
    loop { if si >= g_so_count { break; }
        sp := r64(g_so_paths, si * 8);
        if str_len(sp) > 0 {
            b := read_file(sp);
            if str_len(b) > 0 && so_parse_text(b) == 0 { so_buf = b; break; }
        }
        si = si + 1; }
    if str_len(so_buf) == 0 { return -1; }
    if g_so_sz <= 0 { return -1; }

    // Layout: 176 header + .so code + user code
    hdr_sz : ., mut = 176;
    so_out := hdr_sz;                    // .so .text starts right after header
    user_out := so_out + g_so_sz;        // user code after .so
    total := user_out + g_user_size;

    zi : ., mut = 0; loop { if zi >= total { break; } w8(buf, zi, 0); zi = zi + 1; }

    // Copy .so .text
    ci : ., mut = 0; loop { if ci >= g_so_sz { break; }
        w8(buf, so_out + ci, bu8(so_buf, g_so_off + ci)); ci = ci + 1; }

    // Copy user code (includes _start + all functions)
    cj : ., mut = 0; loop { if cj >= g_user_size { break; }
        w8(buf, user_out + cj, bu8(g_user_code, cj)); cj = cj + 1; }

    // Patch external relocations: user code calls → .so functions
    rpi : ., mut = 0;
    loop { if rpi >= g_x86_ext_rel_count { break; }
        abs_pos := r64(g_x86_ext_rel_pos, rpi * 8);
        fn_ni := r64(g_x86_ext_rel_name, rpi * 8);
        fn_name := istr_get(fn_ni);
        if str_len(fn_name) > 0 {
            sym_addr := so_find(so_buf, fn_name);
            if sym_addr >= g_so_addr && sym_addr < g_so_addr + g_so_sz {
                func_off := sym_addr - g_so_addr;
                call_pos := user_out + abs_pos;
                target_va := 0x400000 + so_out + func_off;
                rel := target_va - (call_pos + 5);
                w32(buf, call_pos + 1, rel); }
        }
    rpi = rpi + 1; }

    // ELF header: single PT_LOAD
    w8(buf,0,127);w8(buf,1,69);w8(buf,2,76);w8(buf,3,70);
    w8(buf,4,2);w8(buf,5,1);w8(buf,6,1);
    w16(buf,16,2);w16(buf,18,62);w32(buf,20,1);
    w64(buf,24,0x400000 + user_out);  // entry = user code's _start
    w64(buf,32,64);w64(buf,40,0);
    w16(buf,52,64);w16(buf,54,56);w16(buf,56,1);w16(buf,58,64);
    w32(buf,64,1);w32(buf,68,5);w64(buf,72,0);
    w64(buf,80,0x400000);w64(buf,88,0x400000);
    w64(buf,96,total);w64(buf,104,total);
    w64(buf,112,4096);

    fd := syscall3(2, path, 577, 420);
    if fd < 0 { return -1; }
    nw := syscall3(1, fd, buf, total);
    syscall3(3, fd, 0, 0);
    return total; }
