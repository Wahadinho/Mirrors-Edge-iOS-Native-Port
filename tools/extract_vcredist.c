/* Standalone MIT vcredist_x86.exe CRT extractor (CAB Store/MSZIP/LZX + OLE2 MSI).
   Extracts msvcr80.dll and msvcp80.dll directly from Visual C++ 2005 vcredist_x86.exe
   using only zlib (-lz) and the C standard library — zero Homebrew dependencies. */
#include <ctype.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

static uint16_t u16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t u32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static int32_t i32(const uint8_t *p) { return (int32_t)u32(p); }

static void strlower(char *s) {
    for (; *s; s++) *s = (char)tolower((unsigned char)*s);
}

static uint8_t *read_file(const char *path, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (n <= 0) { fclose(f); return NULL; }
    uint8_t *buf = malloc((size_t)n);
    if (!buf || fread(buf, 1, (size_t)n, f) != (size_t)n) { free(buf); fclose(f); return NULL; }
    fclose(f);
    *out_len = (size_t)n;
    return buf;
}

static const uint8_t *find_sig(const uint8_t *buf, size_t len, const uint8_t *sig, size_t slen, size_t start) {
    for (size_t i = start; i + slen <= len; i++)
        if (memcmp(buf + i, sig, slen) == 0) return buf + i;
    return NULL;
}

/* ---- LZX Decompressor ([MS-PATCH] / CAB LZX window 15..21) ---- */
static const uint8_t lzx_extra[51] = {
    0,0,0,0, 1,1, 2,2, 3,3, 4,4, 5,5, 6,6, 7,7, 8,8, 9,9, 10,10, 11,11, 12,12,
    13,13, 14,14, 15,15, 16,16, 17,17, 17,17, 17,17, 17,17, 17,17, 17,17, 17,17, 17
};
static const uint32_t lzx_base[51] = {
    0,1,2,3, 4,6, 8,12, 16,24, 32,48, 64,96, 128,192, 256,384, 512,768, 1024,1536,
    2048,3072, 4096,6144, 8192,12288, 16384,24576, 32768,49152, 65536,98304, 131072,196608,
    262144,393216, 524288,655360, 786432,917504, 1048576,1179648, 1310720,1441792,
    1572864,1703936, 1835008,1966080, 2097152
};

typedef struct {
    const uint8_t *src;
    size_t len, pos;
    uint64_t buf;
    int bits;
} BitReader;

static void br_init(BitReader *b, const uint8_t *src, size_t len) {
    b->src = src; b->len = len; b->pos = 0; b->buf = 0; b->bits = 0;
}

static void br_ensure(BitReader *b, int n) {
    while (b->bits < n) {
        uint16_t w = (b->pos + 1 < b->len) ? u16(b->src + b->pos)
                   : (b->pos < b->len ? b->src[b->pos] : 0);
        if (b->pos < b->len) b->pos += (b->pos + 1 < b->len) ? 2 : 1;
        b->buf |= (uint64_t)w << (48 - b->bits);
        b->bits += 16;
    }
}

static uint32_t br_peek(BitReader *b, int n) {
    if (!n) return 0;
    br_ensure(b, n);
    return (uint32_t)(b->buf >> (64 - n));
}

static void br_drop(BitReader *b, int n) {
    b->buf <<= n;
    b->bits -= n;
}

static uint32_t br_read(BitReader *b, int n) {
    if (!n) return 0;
    uint32_t v = br_peek(b, n);
    br_drop(b, n);
    return v;
}

#define LZX_MAX_SYMS 660
typedef struct {
    int nsyms;
    uint16_t tbl[1 << 12]; /* fast 12-bit lookup: bit15=valid, low15=sym; overflow handled bitwise */
    uint32_t maxcode[17];
    int32_t valptr[17];
    uint8_t has_len[17];
    uint16_t sorted[LZX_MAX_SYMS];
    uint8_t lens[LZX_MAX_SYMS];
} Huff;

static int huff_build(Huff *h, const uint8_t *lens, int nsyms) {
    h->nsyms = nsyms;
    memcpy(h->lens, lens, (size_t)nsyms);
    int cnt[17] = {0}, next_code[17] = {0};
    for (int i = 0; i < nsyms; i++) {
        if (lens[i] > 16) return 0;
        if (lens[i]) cnt[lens[i]]++;
    }
    cnt[0] = 0;
    int code = 0, off[17] = {0};
    for (int bits = 1; bits <= 16; bits++) {
        code = (code + cnt[bits - 1]) << 1;
        next_code[bits] = code;
        off[bits] = off[bits - 1] + cnt[bits - 1];
        h->has_len[bits] = cnt[bits] > 0;
        h->maxcode[bits] = cnt[bits] ? (uint32_t)(code + cnt[bits] - 1) : 0;
        h->valptr[bits] = off[bits] - code;
    }
    int cur[17];
    memcpy(cur, off, sizeof cur);
    for (int s = 0; s < nsyms; s++) {
        if (lens[s]) h->sorted[cur[lens[s]]++] = (uint16_t)s;
    }
    memset(h->tbl, 0, sizeof h->tbl);
    for (int s = 0; s < nsyms; s++) {
        int l = lens[s];
        if (!l || l > 12) continue;
        int c = next_code[l]++;
        int fill = 1 << (12 - l);
        int base = c << (12 - l);
        if (base < 0 || base + fill > (1 << 12)) {
            fprintf(stderr, "huff overflow nsyms=%d s=%d l=%d base=%d fill=%d\n", nsyms, s, l, base, fill);
            return 0;
        }
        for (int k = 0; k < fill; k++) h->tbl[base + k] = (uint16_t)(0x8000u | s);
    }
    return 1;
}

static int huff_decode(BitReader *b, const Huff *h) {
    br_ensure(b, 16);
    uint32_t code = 0;
    for (int len = 1; len <= 16; len++) {
        code = (code << 1) | (uint32_t)((b->buf >> (64 - len)) & 1u);
        if (h->has_len[len] && code <= h->maxcode[len]) {
            int idx = h->valptr[len] + (int)code;
            br_drop(b, len);
            return h->sorted[idx];
        }
    }
    return -1;
}

static int lzx_read_lens(BitReader *b, uint8_t *lens, int start, int end) {
    uint8_t pre_len[20];
    for (int i = 0; i < 20; i++) pre_len[i] = (uint8_t)br_read(b, 4);
    Huff pre;
    if (!huff_build(&pre, pre_len, 20)) return 0;
    for (int i = start; i < end; ) {
        int z = huff_decode(b, &pre);
        if (z < 0) return 0;
        if (z == 17) {
            int run = 4 + (int)br_read(b, 4);
            while (run-- && i < end) lens[i++] = 0;
        } else if (z == 18) {
            int run = 20 + (int)br_read(b, 5);
            while (run-- && i < end) lens[i++] = 0;
        } else if (z == 19) {
            int run = 4 + (int)br_read(b, 1);
            int d = huff_decode(b, &pre);
            if (d < 0) return 0;
            uint8_t val = (uint8_t)((lens[i] - d + 17) % 17);
            while (run-- && i < end) lens[i++] = val;
        } else {
            lens[i] = (uint8_t)((lens[i] - z + 17) % 17);
            i++;
        }
    }
    return 1;
}

typedef struct {
    uint8_t *win;
    uint32_t win_sz, win_pos;
    uint32_t r0, r1, r2;
    int num_pos_slots, main_syms;
    int block_type, block_rem, uncomp_pad;
    int header_read;
    uint32_t e8_filesize, frame_idx;
    uint8_t main_lens[LZX_MAX_SYMS], len_lens[249];
    Huff main_huff, len_huff, align_huff;
} LzxState;

static void lzx_init(LzxState *st, int win_bits) {
    memset(st, 0, sizeof *st);
    if (win_bits < 15) win_bits = 15;
    if (win_bits > 21) win_bits = 21;
    st->win_sz = 1u << win_bits;
    st->win = calloc(1, st->win_sz);
    static const int slots_tbl[7] = {30, 32, 34, 36, 38, 42, 50};
    st->num_pos_slots = slots_tbl[win_bits - 15];
    st->main_syms = 256 + 8 * st->num_pos_slots;
    st->r0 = st->r1 = st->r2 = 1;
}

static void lzx_free(LzxState *st) { free(st->win); }

static int lzx_decompress_frame(LzxState *st, const uint8_t *src, size_t slen, uint8_t *dst, size_t dlen) {
    BitReader br;
    br_init(&br, src, slen);
    if (!st->header_read) {
        st->header_read = 1;
        if (br_read(&br, 1)) {
            uint32_t hi = br_read(&br, 16);
            uint32_t lo = br_read(&br, 16);
            st->e8_filesize = (hi << 16) | lo;
        }
    }
    size_t written = 0;
    while (written < dlen) {
        if (st->block_rem == 0) {
            if (st->uncomp_pad && br.pos < br.len) { br.pos++; st->uncomp_pad = 0; }
            st->block_type = (int)br_read(&br, 3);
            st->block_rem = (int)((br_read(&br, 8) << 16) | (br_read(&br, 8) << 8) | br_read(&br, 8));
            if (st->block_rem <= 0) return 0;
            if (st->block_type == 2) {
                uint8_t al[8];
                for (int i = 0; i < 8; i++) al[i] = (uint8_t)br_read(&br, 3);
                if (!huff_build(&st->align_huff, al, 8)) return 0;
            }
            if (st->block_type == 1 || st->block_type == 2) {
                if (!lzx_read_lens(&br, st->main_lens, 0, 256)) return 0;
                if (!lzx_read_lens(&br, st->main_lens, 256, st->main_syms)) return 0;
                if (!huff_build(&st->main_huff, st->main_lens, st->main_syms)) return 0;
                if (!lzx_read_lens(&br, st->len_lens, 0, 249)) return 0;
                if (!huff_build(&st->len_huff, st->len_lens, 249)) return 0;
            } else if (st->block_type == 3) {
                /* LZX aligns to 16-bit boundary; if already aligned (rem == 0), a 16-bit pad word is still present. */
                int rem = br.bits % 16;
                br.bits -= rem;
                size_t byte_off = br.pos - (size_t)(br.bits / 8) + (rem == 0 ? 2u : 0u);
                if (byte_off + 12 > br.len) return 0;
                st->r0 = u32(br.src + byte_off);
                st->r1 = u32(br.src + byte_off + 4);
                st->r2 = u32(br.src + byte_off + 8);
                br.pos = byte_off + 12;
                br.buf = 0; br.bits = 0;
                st->uncomp_pad = st->block_rem & 1;
            } else {
                return 0;
            }
        }
        int todo = (int)(dlen - written);
        if (todo > st->block_rem) todo = st->block_rem;
        if (st->block_type == 3) {
            while (todo > 0) {
                if (br.pos >= br.len) return 0;
                uint8_t b = br.src[br.pos++];
                dst[written++] = b;
                st->win[st->win_pos] = b;
                st->win_pos = (st->win_pos + 1) & (st->win_sz - 1);
                st->block_rem--;
                todo--;
            }
            if (st->block_rem == 0 && st->uncomp_pad && br.pos < br.len) {
                br.pos++;
                st->uncomp_pad = 0;
            }
            continue;
        }
        size_t stop_at = written + (size_t)todo;
        while (written < stop_at) {
            int sym = huff_decode(&br, &st->main_huff);
            if (sym < 0) return 0;
            if (sym < 256) {
                uint8_t c = (uint8_t)sym;
                dst[written++] = c;
                st->win[st->win_pos] = c;
                st->win_pos = (st->win_pos + 1) & (st->win_sz - 1);
                st->block_rem--;
            } else {
                sym -= 256;
                int m_hdr = sym & 7;
                int p_slot = sym >> 3;
                int m_len = (m_hdr == 7) ? (huff_decode(&br, &st->len_huff) + 9) : (m_hdr + 2);
                uint32_t m_off;
                if (p_slot == 0) m_off = st->r0;
                else if (p_slot == 1) { m_off = st->r1; st->r1 = st->r0; st->r0 = m_off; }
                else if (p_slot == 2) { m_off = st->r2; st->r2 = st->r0; st->r0 = m_off; }
                else {
                    int eb = lzx_extra[p_slot];
                    uint32_t verbatim = 0, aligned = 0;
                    if (st->block_type == 2 && eb >= 3) {
                        verbatim = br_read(&br, eb - 3) << 3;
                        int al = huff_decode(&br, &st->align_huff);
                        if (al < 0) return 0;
                        aligned = (uint32_t)al;
                    } else {
                        verbatim = br_read(&br, eb);
                    }
                    m_off = lzx_base[p_slot] + verbatim + aligned - 2;
                    st->r2 = st->r1; st->r1 = st->r0; st->r0 = m_off;
                }
                uint32_t src_pos = (st->win_pos - m_off) & (st->win_sz - 1);
                for (int k = 0; k < m_len; k++) {
                    uint8_t c = st->win[(src_pos + (uint32_t)k) & (st->win_sz - 1)];
                    dst[written++] = c;
                    st->win[st->win_pos] = c;
                    st->win_pos = (st->win_pos + 1) & (st->win_sz - 1);
                }
                st->block_rem -= m_len;
            }
        }
    }
    if (st->e8_filesize > 0 && dlen > 10 && st->frame_idx < 32768) {
        uint32_t curpos = st->frame_idx * 32768u;
        for (size_t i = 0; i <= dlen - 10; i++) {
            if (dst[i] == 0xE8) {
                int32_t rel = i32(dst + i + 1);
                int32_t cp = (int32_t)(curpos + i);
                if (rel >= -cp && rel < (int32_t)st->e8_filesize) {
                    int32_t fixed = (rel >= 0) ? (rel - cp) : (rel + (int32_t)st->e8_filesize);
                    dst[i + 1] = (uint8_t)fixed;
                    dst[i + 2] = (uint8_t)(fixed >> 8);
                    dst[i + 3] = (uint8_t)(fixed >> 16);
                    dst[i + 4] = (uint8_t)(fixed >> 24);
                }
                i += 4;
            }
        }
    }
    st->frame_idx++;
    return 1;
}

/* ---- MSZIP Decompressor (RFC 1951 DEFLATE with "CK" header and 32K history) ---- */
static int mszip_decompress_frame(const uint8_t *src, size_t slen, uint8_t *dst, size_t dlen,
                                  const uint8_t *prev_win, size_t prev_len) {
    if (slen < 2 || src[0] != 'C' || src[1] != 'K') return 0;
    z_stream zs = {0};
    if (inflateInit2(&zs, -15) != Z_OK) return 0;
    if (prev_win && prev_len) inflateSetDictionary(&zs, prev_win, (uInt)prev_len);
    zs.next_in = (Bytef *)(src + 2);
    zs.avail_in = (uInt)(slen - 2);
    zs.next_out = (Bytef *)dst;
    zs.avail_out = (uInt)dlen;
    int rc = inflate(&zs, Z_FINISH);
    size_t got = zs.total_out;
    inflateEnd(&zs);
    return (rc == Z_STREAM_END || rc == Z_OK) && got == dlen;
}

/* ---- Cabinet Extractor Callback ---- */
typedef void (*CabFileCb)(const char *name, const uint8_t *data, size_t len, void *ctx);

static int extract_cab(const uint8_t *cab, size_t cab_len, CabFileCb cb, void *cb_ctx) {
    if (cab_len < 36 || memcmp(cab, "MSCF\0\0\0\0", 8) != 0) return 0;
    uint32_t coffFiles = u32(cab + 16);
    uint16_t cFolders = u16(cab + 26), cFiles = u16(cab + 28), flags = u16(cab + 30);
    size_t pos = 36;
    uint16_t cbCFHeader = 0; uint8_t cbCFFolder = 0, cbCFData = 0;
    if (flags & 4) {
        if (pos + 4 > cab_len) return 0;
        cbCFHeader = u16(cab + pos); cbCFFolder = cab[pos + 2]; cbCFData = cab[pos + 3];
        pos += 4 + cbCFHeader;
    }
    if (flags & 1) { /* prev cabinet strings */
        while (pos < cab_len && cab[pos]) pos++; pos++;
        while (pos < cab_len && cab[pos]) pos++; pos++;
    }
    if (flags & 2) { /* next cabinet strings */
        while (pos < cab_len && cab[pos]) pos++; pos++;
        while (pos < cab_len && cab[pos]) pos++; pos++;
    }

    typedef struct { uint32_t off; uint16_t ndata, type; uint8_t *buf; size_t len; } Folder;
    Folder *folders = calloc(cFolders ? cFolders : 1, sizeof *folders);
    for (uint16_t i = 0; i < cFolders; i++) {
        if (pos + 8 + cbCFFolder > cab_len) { free(folders); return 0; }
        folders[i].off = u32(cab + pos);
        folders[i].ndata = u16(cab + pos + 4);
        folders[i].type = u16(cab + pos + 6);
        pos += 8 + cbCFFolder;
    }

    /* Decompress every folder cleanly */
    for (uint16_t i = 0; i < cFolders; i++) {
        uint16_t comp = folders[i].type;
        int method = comp & 0x0Fu;
        size_t dp = folders[i].off;
        size_t cap = (size_t)folders[i].ndata * 32768u + 4096u;
        uint8_t *out = malloc(cap);
        size_t out_len = 0;

        LzxState lzx;
        if (method == 3) lzx_init(&lzx, (comp >> 8) & 0x1Fu);

        uint8_t *partial = NULL;
        size_t partial_len = 0, partial_cap = 0;
        const uint8_t *prev_mszip = NULL;
        size_t prev_mszip_len = 0;

        for (uint16_t b = 0; b < folders[i].ndata; b++) {
            if (dp + 8 + cbCFData > cab_len) { free(out); if (method == 3) lzx_free(&lzx); free(partial); free(folders); return 0; }
            uint16_t cbData = u16(cab + dp + 4);
            uint16_t cbUncomp = u16(cab + dp + 6);
            dp += 8 + cbCFData;
            if (dp + cbData > cab_len) { free(out); if (method == 3) lzx_free(&lzx); free(partial); free(folders); return 0; }

            const uint8_t *chunk = cab + dp;
            size_t chunk_len = cbData;
            dp += cbData;

            if (cbUncomp == 0 || partial_len > 0) {
                if (partial_len + chunk_len > partial_cap) {
                    partial_cap = partial_len + chunk_len + 4096;
                    partial = realloc(partial, partial_cap);
                }
                memcpy(partial + partial_len, chunk, chunk_len);
                partial_len += chunk_len;
                if (cbUncomp == 0) continue;
                chunk = partial;
                chunk_len = partial_len;
            }
            if (out_len + cbUncomp > cap) {
                cap = out_len + cbUncomp + 65536u;
                out = realloc(out, cap);
            }
            int ok = 0;
            if (method == 0) {
                memcpy(out + out_len, chunk, cbUncomp);
                ok = 1;
            } else if (method == 1) {
                ok = mszip_decompress_frame(chunk, chunk_len, out + out_len, cbUncomp, prev_mszip, prev_mszip_len);
                prev_mszip = out + out_len;
                prev_mszip_len = cbUncomp;
            } else if (method == 3) {
                ok = lzx_decompress_frame(&lzx, chunk, chunk_len, out + out_len, cbUncomp);
            }
            partial_len = 0;
            if (!ok) {
                fprintf(stderr, "CAB decompress failed (folder %u block %u frame %u method %d)\n", i, b, lzx.frame_idx, method);
                free(out); free(partial); if (method == 3) lzx_free(&lzx); free(folders); return 0;
            }
            out_len += cbUncomp;
        }
        free(partial);
        if (method == 3) lzx_free(&lzx);
        folders[i].buf = out;
        folders[i].len = out_len;
    }

    size_t fp = coffFiles;
    for (uint16_t i = 0; i < cFiles; i++) {
        if (fp + 16 > cab_len) break;
        uint32_t cbFile = u32(cab + fp);
        uint32_t uoff = u32(cab + fp + 4);
        uint16_t iFolder = u16(cab + fp + 8);
        fp += 16;
        const char *name = (const char *)(cab + fp);
        size_t nlen = strlen(name);
        fp += nlen + 1;
        if (iFolder < cFolders && uoff + cbFile <= folders[iFolder].len) {
            cb(name, folders[iFolder].buf + uoff, cbFile, cb_ctx);
        }
    }

    for (uint16_t i = 0; i < cFolders; i++) free(folders[i].buf);
    free(folders);
    return 1;
}

/* ---- Recursive vcredist_x86.exe -> OLE2 .msi -> CAB -> msvcr80.dll/msvcp80.dll ---- */
typedef struct {
    const char *out_dir;
    int got_r80, got_p80;
} OutCtx;

static void scan_ole2_msi(const uint8_t *msi, size_t msi_len, OutCtx *oc);

static void on_cab_file(const char *name, const uint8_t *data, size_t len, void *ctx) {
    OutCtx *oc = (OutCtx *)ctx;
    char low[512];
    snprintf(low, sizeof low, "%s", name);
    strlower(low);

    if (strstr(low, "msvcr80") && strstr(low, "dll") && !oc->got_r80 && len > 200000) {
        char p[1024]; snprintf(p, sizeof p, "%s/msvcr80.dll", oc->out_dir);
        FILE *f = fopen(p, "wb");
        if (f) { fwrite(data, 1, len, f); fclose(f); oc->got_r80 = 1; }
    } else if (strstr(low, "msvcp80") && strstr(low, "dll") && !oc->got_p80 && len > 200000) {
        char p[1024]; snprintf(p, sizeof p, "%s/msvcp80.dll", oc->out_dir);
        FILE *f = fopen(p, "wb");
        if (f) { fwrite(data, 1, len, f); fclose(f); oc->got_p80 = 1; }
    } else if (strstr(low, ".exe")) {
        const uint8_t *cab = find_sig(data, len, (const uint8_t *)"MSCF\0\0\0\0", 8, 0);
        if (cab) extract_cab(cab, (size_t)(data + len - cab), on_cab_file, oc);
    } else if (strstr(low, ".msi")) {
        scan_ole2_msi(data, len, oc);
    } else if (strstr(low, ".cab")) {
        extract_cab(data, len, on_cab_file, oc);
    }
}

static void scan_ole2_msi(const uint8_t *msi, size_t msi_len, OutCtx *oc) {
    static const uint8_t sig[8] = {0xD0,0xCF,0x11,0xE0,0xA1,0xB1,0x1A,0xE1};
    if (msi_len < 512 || memcmp(msi, sig, 8) != 0) return;
    uint16_t sec_shift = u16(msi + 30);
    size_t sec_sz = (size_t)1u << sec_shift;
    uint32_t fat_cnt = u32(msi + 44), dir_sec = u32(msi + 48);
    if (sec_sz < 512 || sec_sz > 4096) return;

    size_t max_secs = msi_len / sec_sz;
    uint32_t *fat = malloc(fat_cnt * sec_sz);
    size_t fat_len = 0;
    for (uint32_t i = 0; i < fat_cnt && i < 109; i++) {
        uint32_t s = u32(msi + 76 + i * 4);
        if (s + 1 >= max_secs) break;
        const uint8_t *p = msi + (size_t)(s + 1) * sec_sz;
        for (size_t k = 0; k < sec_sz / 4; k++) fat[fat_len++] = u32(p + k * 4);
    }
    uint32_t difat_sec = u32(msi + 68);
    for (uint32_t i = 109; i < fat_cnt && difat_sec < 0xFFFFFFFAu; ) {
        if (difat_sec + 1 >= max_secs) break;
        const uint8_t *dp = msi + (size_t)(difat_sec + 1) * sec_sz;
        for (size_t k = 0; k < sec_sz / 4 - 1 && i < fat_cnt; k++, i++) {
            uint32_t s = u32(dp + k * 4);
            if (s + 1 >= max_secs) break;
            const uint8_t *p = msi + (size_t)(s + 1) * sec_sz;
            for (size_t j = 0; j < sec_sz / 4; j++) fat[fat_len++] = u32(p + j * 4);
        }
        difat_sec = u32(dp + sec_sz - 4);
    }

    uint8_t *dirs = malloc(msi_len);
    size_t dirs_len = 0;
    uint32_t ds = dir_sec, dsteps = 0;
    while (ds < fat_len && ds < 0xFFFFFFFAu && dirs_len + sec_sz <= msi_len && dsteps++ < max_secs) {
        if (ds + 1 >= max_secs) break;
        memcpy(dirs + dirs_len, msi + (size_t)(ds + 1) * sec_sz, sec_sz);
        dirs_len += sec_sz;
        ds = fat[ds];
    }

    for (size_t i = 0; i + 128 <= dirs_len && !(oc->got_r80 && oc->got_p80); i += 128) {
        const uint8_t *e = dirs + i;
        if (e[66] != 2) continue; /* stream */
        uint32_t start = u32(e + 116), size = u32(e + 120);
        if (size < 4096 || size > msi_len || start >= fat_len) continue;
        uint8_t *sbuf = malloc(size + sec_sz);
        size_t got = 0;
        uint32_t cs = start, csteps = 0;
        while (cs < fat_len && cs < 0xFFFFFFFAu && got < size && csteps++ < max_secs) {
            if (cs + 1 >= max_secs) break;
            size_t chunk = sec_sz < (size - got) ? sec_sz : (size - got);
            memcpy(sbuf + got, msi + (size_t)(cs + 1) * sec_sz, chunk);
            got += chunk;
            cs = fat[cs];
        }
        if (got >= 8 && memcmp(sbuf, "MSCF\0\0\0\0", 8) == 0) {
            extract_cab(sbuf, got, on_cab_file, oc);
        }
        free(sbuf);
    }
    free(dirs);
    free(fat);
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <vcredist_x86.exe> <out_dir>\n", argv[0]);
        return 2;
    }
    size_t len = 0;
    uint8_t *exe = read_file(argv[1], &len);
    if (!exe) { fprintf(stderr, "cannot read %s\n", argv[1]); return 1; }
    OutCtx oc = {argv[2], 0, 0};
    const uint8_t *cab = find_sig(exe, len, (const uint8_t *)"MSCF\0\0\0\0", 8, 0);
    if (!cab || !extract_cab(cab, (size_t)(exe + len - cab), on_cab_file, &oc)) {
        free(exe);
        fprintf(stderr, "failed to extract cabinet from %s\n", argv[1]);
        return 1;
    }
    free(exe);
    if (!oc.got_r80 || !oc.got_p80) {
        fprintf(stderr, "msvcr80.dll/msvcp80.dll not found inside %s\n", argv[1]);
        return 1;
    }
    return 0;
}
