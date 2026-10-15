/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

// Fuzz OSv's locale data loader (libc/locale/locale-data.cc) on Linux under
// ASan and UBSan. Build and run (from the OSv tree):
//
//   g++ -std=gnu++17 -g -O1 -fsanitize=address,undefined -fno-sanitize-recover=all
//       -Ilibc/locale scripts/locale-oracle/fuzz-locale-data.cc libc/locale/locale-data.cc
//       -o fuzz-locale-data
//   ./fuzz-locale-data <iterations> <rng-seed> <locale-dir>... [--archive <locale-archive>]
//
// Each <locale-dir> is a localedef output directory (de_DE.utf8); its twelve
// category files are seeds, and so is a small archive the harness builds from
// them and, if given, a real locale-archive. Each input is a seed mutated in
// place (bit flips, words set to boundary values in the header, string index
// and archive tables, truncation by poisoning the tail): the loader must
// either reject it or accept it with every item readable as its type within
// the data, which the harness then reads (an overrun is an ASan report).
// Deterministic cases first: every seed is accepted unchanged (the positive
// control) and each named corruption is rejected (the negative control).
// "--self-test" reads items of a truncated file without validating it and
// must die under ASan, showing the harness detects what the checks prevent.

#include "locale-data.h"

#include <sanitizer/asan_interface.h>

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <vector>

#include <sys/stat.h>
#include <unistd.h>

namespace {

const char *const file_names[13] = {
    "LC_CTYPE", "LC_NUMERIC", "LC_TIME", "LC_COLLATE", "LC_MONETARY",
    "LC_MESSAGES/SYS_LC_MESSAGES", nullptr, "LC_PAPER", "LC_NAME",
    "LC_ADDRESS", "LC_TELEPHONE", "LC_MEASUREMENT", "LC_IDENTIFICATION",
};

// The item types the harness reads back, independently of the loader's
// table: the nl-typed.txt types, grouping strings as strings.
const char *const types[13] = {
    "xxxxxxxxxxssxdsxxdddssssssssssdwwwwwwwwwwssssssssssdddddddddddxxxxdxdxdd",
    "sssdds",
    "ssssssssssssssssssssssssssssssssssssssssssssssssssdxwwwwwwwwwwwwwwwwwwww"
    "wwwwwwwwwwwwwwwwwwwwwwwwwwwwwbdbbbbsswssssssssssssswwwwwwwwwwwwsssssssss"
    "ssswwwwwwwwwwww",
    "dxxxxxxxxxxxxdxxxxs",
    "sssssssbbbbbbbbsbbbbbbssbbbbbbbbbbbbbbddddrdds",
    "sssss",
    "",
    "dds",
    "sssssss",
    "ssssssdssssss",
    "sssss",
    "bs",
    "ssssssssssssssss",
};

struct seed {
    std::string what;
    int cat;            // -1: an archive
    std::vector<std::string> names;    // locale names in an archive
    char *buf;          // malloc'd, exactly size bytes
    size_t size;
};

std::vector<seed> seeds;
unsigned long accepted, rejected, inputs;
unsigned long last_found;    // categories an archive input yielded
volatile unsigned long sink;

char *read_file(const std::string &path, size_t *size)
{
    FILE *f = fopen(path.c_str(), "rb");
    if (!f) {
        return nullptr;
    }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *b = static_cast<char *>(malloc(n));
    if (fread(b, 1, n, f) != size_t(n)) {
        exit(2);
    }
    fclose(f);
    *size = n;
    return b;
}

uint32_t rd(const char *p)
{
    uint32_t w;
    memcpy(&w, p, 4);
    return w;
}

void wr(char *p, uint32_t w)
{
    memcpy(p, &w, 4);
}

// Read every item of an accepted category as its type: strings to their NUL,
// wide strings to their 0, words and bytes. Any read outside the data is an
// ASan report. Also check osv_locale_item() agrees with the index.
void read_items(const osv_locale_data &d)
{
    const char *t = types[d.cat];
    size_t nt = strlen(t);
    unsigned long acc = 0;
    for (uint32_t i = 0; i < d.nstrings; i++) {
        uint32_t off = rd(d.base + 8 + 4 * size_t(i));
        char type = i < nt ? t[i] : 'x';
        char *v = osv_locale_item(&d, int(i));
        const char *p = d.base + off;
        switch (type) {
        case 's':
            acc += strlen(v);
            if (v != p) {
                abort();
            }
            break;
        case 'w': {
            const uint32_t *w = reinterpret_cast<const uint32_t *>(v);
            while (*w) {
                acc += *w++;
            }
            break;
        }
        case 'd':
            acc += uintptr_t(v);
            if (uintptr_t(v) != rd(p)) {
                abort();
            }
            break;
        case 'r':
            acc += reinterpret_cast<const uint32_t *>(v)[0] + reinterpret_cast<const uint32_t *>(v)[1];
            break;
        case 'b':
            acc += static_cast<unsigned char>(*v);
            break;
        default:
            if (off < d.size) {
                acc += static_cast<unsigned char>(*v);
            }
        }
    }
    acc += *osv_locale_item(&d, int(d.nstrings)) + *osv_locale_item(&d, 0xffff) +
        *osv_locale_item(&d, -1);
    // An accepted LC_CTYPE (Stage 1a-2): its byte tables and every class, map
    // and width table are used through OSv's own lookups, at code points that
    // reach every level-1 slot and a spread of level-2/3 slots, and the
    // boundary values; a lookup outside the data is an ASan report.
    if (d.cat == 0) {
        const osv_ctype &c = d.ctype;
        for (int i = -128; i < 256; i++) {
            acc += c.class_b[i] + uint32_t(c.toupper_b[i]) + uint32_t(c.tolower_b[i]);
        }
        static const uint32_t edge[] = { 0x10ffff, 0x110000, 0x7fffffff, 0xffffffff, 0xfffffffe };
        auto probe = [&](uint32_t cp) {
            for (int k = 0; k < 12; k++) {
                acc += osv_ctype_class(c.cls[k], cp);
            }
            acc += osv_ctype_map(c.toupper, cp) + osv_ctype_map(c.tolower, cp) +
                osv_ctype_width(c.width, cp);
            const char *p = c.class_names;
            for (uint32_t k = 0; k < c.nclass; k++, p += strlen(p) + 1) {
                acc += osv_ctype_class(osv_ctype_find(&c, p, false), cp);
            }
            p = c.map_names;
            for (uint32_t k = 0; k < c.nmap; k++, p += strlen(p) + 1) {
                acc += osv_ctype_map(osv_ctype_find(&c, p, true), cp);
            }
        };
        for (uint32_t cp = 0; cp < 0x110000; cp += 0x1f3) {
            probe(cp);
        }
        for (uint32_t e : edge) {
            probe(e);
        }
        // Any shift: a code point with every high bit pattern.
        for (int b = 0; b < 32; b++) {
            probe(1u << b);
            probe((1u << b) - 1);
        }
    }
    sink += acc;
}

// Try one input: a category or an archive. Return whether it was accepted.
bool run(const seed &s, size_t size)
{
    inputs++;
    osv_locale_data d;
    bool ok = false;
    if (s.cat >= 0) {
        ok = osv_locale_check(s.cat, s.buf, size, &d);
        if (ok) {
            read_items(d);
        }
    } else {
        last_found = 0;
        for (const std::string &n : s.names) {
            for (int c = 0; c < 13; c++) {
                if (c != 6 && osv_locale_archive_find(s.buf, size, n.c_str(), c, &d)) {
                    if (d.base < s.buf || d.base + d.size > s.buf + size || d.cat != c) {
                        abort();
                    }
                    read_items(d);
                    ok = true;
                    last_found++;
                }
            }
        }
        // A name that is not there, and one that is too long for any entry.
        if (osv_locale_archive_find(s.buf, size, "xx_YY.utf8", 1, &d)) {
            abort();
        }
    }
    (ok ? accepted : rejected)++;
    return ok;
}

// A small archive of the seed locales' small categories: header, name
// table, names, data, records.
seed build_archive(const std::vector<std::pair<std::string, std::vector<seed *>>> &locs)
{
    std::string img(56, '\0');
    auto align = [&]() { while (img.size() % 4) img.push_back('\0'); };
    // A prime above twice the names (at least 7), so probing collides and
    // wraps and every slot is reachable.
    uint32_t hsize = 2 * locs.size() + 1 < 7 ? 7 : 2 * locs.size() + 1;
    for (bool prime = false; !prime; hsize += prime ? 0 : 2) {
        prime = true;
        for (uint32_t d = 3; d * d <= hsize; d += 2) {
            prime &= hsize % d != 0;
        }
    }
    uint32_t hoff = img.size();
    img.append(12 * hsize, '\0');
    std::vector<uint32_t> name_off, rec_off;
    for (auto &l : locs) {
        name_off.push_back(img.size());
        img += l.first;
        img.push_back('\0');
    }
    align();
    std::vector<std::vector<std::pair<uint32_t, uint32_t>>> spans(locs.size());
    for (size_t i = 0; i < locs.size(); i++) {
        spans[i].assign(13, { 0, 0 });
        for (seed *s : locs[i].second) {
            if (s->cat == 0 || s->cat == 3) {
                continue;   // the big tables; the category seeds cover them
            }
            spans[i][s->cat] = { uint32_t(img.size()), uint32_t(s->size) };
            img.append(s->buf, s->size);
            align();
        }
    }
    for (size_t i = 0; i < locs.size(); i++) {
        rec_off.push_back(img.size());
        img.append(4 + 13 * 8, '\0');
        wr(&img[rec_off[i]], 1);
        for (int c = 0; c < 13; c++) {
            wr(&img[rec_off[i] + 4 + 8 * c], spans[i][c].first);
            wr(&img[rec_off[i] + 8 + 8 * c], spans[i][c].second);
        }
    }
    wr(&img[0], 0xde020109);
    wr(&img[8], hoff);
    wr(&img[12], locs.size());
    wr(&img[16], hsize);
    seed a;
    a.what = "built-archive";
    a.cat = -1;
    for (size_t i = 0; i < locs.size(); i++) {
        const std::string &n = locs[i].first;
        uint32_t h = n.size();
        for (unsigned char c : n) {
            h = ((h << 9) | (h >> 23)) + c;
        }
        uint32_t idx = h % hsize, step = 1 + h % (hsize - 2);
        while (rd(&img[hoff + 12 * idx + 4])) {
            idx = (idx + step) % hsize;
        }
        wr(&img[hoff + 12 * idx], h);
        wr(&img[hoff + 12 * idx + 4], name_off[i]);
        wr(&img[hoff + 12 * idx + 8], rec_off[i]);
        a.names.push_back(n);
    }
    a.size = img.size();
    a.buf = static_cast<char *>(malloc(a.size));
    memcpy(a.buf, img.data(), a.size);
    return a;
}

// Undo log for in-place mutation.
struct undo {
    size_t off;
    char old[4];
    size_t n;
};

int fails;

void expect(bool cond, const std::string &what)
{
    if (!cond) {
        printf("FAIL: %s\n", what.c_str());
        fails++;
    }
}

// Apply f to a scratch copy of s and expect rejection.
template <typename F>
void negative(const seed &s, const char *what, F f)
{
    std::vector<char> copy(s.buf, s.buf + s.size);
    size_t size = s.size;
    f(copy.data(), size);
    char *b = static_cast<char *>(malloc(size ? size : 1));
    memcpy(b, copy.data(), size);
    seed t = s;
    t.buf = b;
    expect(!run(t, size), s.what + ": " + what + " rejected");
    free(b);
}

void deterministic()
{
    for (const seed &s : seeds) {
        expect(run(s, s.size), s.what + ": unmodified seed accepted");
        if (s.cat < 0) {
            // Every category of every locale; the built archive leaves out
            // LC_CTYPE and LC_COLLATE.
            size_t want = s.names.size() * (s.what == "built-archive" ? 10 : 12);
            expect(last_found == want, s.what + ": " + std::to_string(last_found) + " of " +
                   std::to_string(want) + " categories found");
        }
    }
    for (const seed &s : seeds) {
        if (s.cat < 0) {
            negative(s, "bad magic", [](char *b, size_t &) { b[0] ^= 1; });
            for (uint32_t hs : { 0u, 1u, 2u }) {
                negative(s, ("namehash_size " + std::to_string(hs)).c_str(),
                         [hs](char *b, size_t &) { wr(b + 16, hs); });
            }
            negative(s, "namehash_offset past end", [](char *b, size_t &n) { wr(b + 8, n); });
            negative(s, "namehash_size past end", [](char *b, size_t &n) { wr(b + 16, n / 12 + 1); });
            negative(s, "truncated header", [](char *, size_t &n) { n = 40; });
            negative(s, "every record offset past end", [&s](char *b, size_t &n) {
                uint32_t ho = rd(b + 8), hs = rd(b + 16);
                for (uint32_t i = 0; i < hs; i++) {
                    if (rd(b + ho + 12 * i + 4)) {
                        wr(b + ho + 12 * i + 8, n);
                    }
                }
            });
            negative(s, "every record misaligned", [](char *b, size_t &) {
                uint32_t ho = rd(b + 8), hs = rd(b + 16);
                for (uint32_t i = 0; i < hs; i++) {
                    if (rd(b + ho + 12 * i + 4)) {
                        wr(b + ho + 12 * i + 8, rd(b + ho + 12 * i + 8) + 2);
                    }
                }
            });
            negative(s, "every name offset past end", [](char *b, size_t &n) {
                uint32_t ho = rd(b + 8), hs = rd(b + 16);
                for (uint32_t i = 0; i < hs; i++) {
                    if (rd(b + ho + 12 * i + 4)) {
                        wr(b + ho + 12 * i + 4, n);
                    }
                }
            });
            continue;
        }
        uint32_t n = rd(s.buf + 4);
        negative(s, "bad magic", [](char *b, size_t &) { b[3] ^= 0x80; });
        negative(s, "other category's magic", [&s](char *b, size_t &) {
            wr(b, rd(b) ^ (s.cat == 1 ? 3 : 1));
        });
        negative(s, "size 7", [](char *, size_t &sz) { sz = 7; });
        negative(s, "truncated to the index", [n](char *, size_t &sz) { sz = 8 + 4 * n; });
        // LC_CTYPE and LC_COLLATE end in internal tables OSv does not read
        // in 1a-1 (only their offsets are checked), so a lost last byte
        // shows only in the other categories.
        if (s.cat != 0 && s.cat != 3) {
            negative(s, "truncated by one byte", [](char *, size_t &sz) { sz -= 1; });
        }
        negative(s, "nstrings huge", [](char *b, size_t &) { wr(b + 4, 0xffffffff); });
        negative(s, "nstrings past the end", [](char *b, size_t &sz) { wr(b + 4, sz / 4); });
        // The fewest items glibc 2.41 accepts (measured): LC_CTYPE 86, the
        // others every public item.
        negative(s, "nstrings one too few", [&s](char *b, size_t &) {
            wr(b + 4, s.cat == 0 ? 85 : strlen(types[s.cat]) - 1);
        });
        negative(s, "last offset past end", [n](char *b, size_t &sz) { wr(b + 8 + 4 * (n - 1), sz + 1); });
        if (s.cat == 0) {
            // Stage 1a-2: the LC_CTYPE tables are parsed, so each of these
            // must be rejected. item(i): its offset; tab(i): its 3-level
            // table header.
            auto item = [](char *b, uint32_t i) { return rd(b + 8 + 4 * size_t(i)); };
            uint32_t co = rd(s.buf + item(s.buf, 17)), mo = rd(s.buf + item(s.buf, 18));
            negative(s, "truncated by one byte", [](char *, size_t &sz) { sz -= 1; });
            negative(s, "class table n1 huge", [&](char *b, size_t &) { wr(b + item(b, co) + 4, 0x7fffffff); });
            negative(s, "map table level-1 offset past end", [&](char *b, size_t &sz) {
                wr(b + item(b, mo) + 20, sz);
            });
            negative(s, "width level-2 offset past end", [&](char *b, size_t &sz) {
                size_t t = item(b, 12);
                uint32_t o2 = rd(b + t + 20);
                wr(b + t + o2, sz - t);
            });
            negative(s, "class level-3 offset misaligned", [&](char *b, size_t &) {
                size_t t = item(b, co);
                uint32_t o2 = rd(b + t + 20);
                wr(b + t + o2, rd(b + t + o2) + 2);
            });
            negative(s, "class table header past end", [&](char *b, size_t &sz) {
                wr(b + 8 + 4 * size_t(co), sz - 8);
            });
            negative(s, "class table misaligned", [&](char *b, size_t &) {
                wr(b + 8 + 4 * size_t(co), item(b, co) + 2);
            });
            negative(s, "byte class table past end", [&](char *b, size_t &sz) { wr(b + 8, sz - 100); });
            negative(s, "byte toupper misaligned", [&](char *b, size_t &) { wr(b + 12, item(b, 1) + 1); });
            negative(s, "class offset past nstrings", [&](char *b, size_t &) { wr(b + item(b, 17), n); });
            negative(s, "map offset below 19", [&](char *b, size_t &) { wr(b + item(b, 18), 3); });
            negative(s, "class names unterminated", [&](char *b, size_t &sz) {
                wr(b + 8 + 40, sz - 1);
                b[sz - 1] = 'x';
            });
            negative(s, "shift1 32", [&](char *b, size_t &) { wr(b + item(b, mo), 32); });
            negative(s, "mask3 huge", [&](char *b, size_t &) { wr(b + item(b, co) + 16, 0xfffff); });
        }
        // A word item moved off alignment, and a string with no NUL.
        const char *t = types[s.cat];
        for (uint32_t i = 0; i < n && i < strlen(t); i++) {
            if (t[i] == 'd' || t[i] == 'w') {
                negative(s, ("misaligned word item " + std::to_string(i)).c_str(),
                         [i](char *b, size_t &) { wr(b + 8 + 4 * i, rd(b + 8 + 4 * i) + 1); });
                break;
            }
        }
        for (uint32_t i = 0; i < n && i < strlen(t); i++) {
            if (t[i] == 's') {
                negative(s, ("unterminated string item " + std::to_string(i)).c_str(),
                         [i](char *b, size_t &sz) {
                             // Point the item at the last byte and make it non-NUL.
                             wr(b + 8 + 4 * i, sz - 1);
                             b[sz - 1] = 'x';
                         });
                break;
            }
        }
    }
}

// One random input: mutate a seed in place, run, undo.
void random_input(std::mt19937_64 &rng)
{
    seed &s = seeds[rng() % seeds.size()];
    std::vector<undo> log;
    auto put = [&](size_t off, const void *src, size_t n) {
        if (off + n > s.size) {
            return;
        }
        undo u;
        u.off = off;
        u.n = n;
        memcpy(u.old, s.buf + off, n);
        log.push_back(u);
        memcpy(s.buf + off, src, n);
    };
    // Where the interesting words are: header and index, or archive tables.
    auto hot_word = [&]() -> size_t {
        if (s.cat >= 0) {
            uint32_t n = rd(s.buf + 4);
            size_t idx_end = 8 + 4 * size_t(n);
            if (idx_end > s.size) {
                idx_end = s.size;
            }
            // LC_CTYPE: half the time a word of a table header or a level-1/2
            // offset of a table (Stage 1a-2: the tables are parsed).
            if (s.cat == 0 && n > 12 && idx_end == 8 + 4 * size_t(n) && rng() % 2) {
                uint32_t i = rng() % 3 ? 72 + rng() % (n > 72 ? n - 72 : 1) : 12;
                if (i >= n) {
                    i = 12;
                }
                size_t t = rd(s.buf + 8 + 4 * size_t(i));
                if (t % 4 == 0 && t + 20 <= s.size) {
                    uint32_t n1 = rd(s.buf + t + 4);
                    size_t k = rng() % 3;
                    if (k == 0 || !n1 || n1 > 0x10000) {
                        return t + 4 * (rng() % 5);
                    }
                    size_t l1 = t + 20 + 4 * (rng() % n1);
                    if (k == 1 || l1 + 4 > s.size) {
                        return l1;
                    }
                    size_t o2 = rd(s.buf + l1);
                    return o2 && t + o2 + 4 <= s.size ? ((t + o2) & ~size_t(3)) + 4 * (rng() % 16) : l1;
                }
            }
            return (rng() % (idx_end / 4)) * 4;
        }
        // The archive's own tables, read from the seed as mutated so far:
        // every read is bounds-checked, since earlier mutations may have
        // changed the offsets.
        auto rdw = [&](size_t off) -> uint32_t { return off + 4 <= s.size ? rd(s.buf + off) : 0; };
        size_t ho = rdw(8), hs = rdw(16);
        switch (hs ? rng() % 3 : 0) {
        case 0:
            return (rng() % 14) * 4;
        case 1:
            return ho + 4 * (rng() % (3 * hs));
        default: {
            size_t ro = rdw(ho + 12 * (rng() % hs) + 8);
            return ro ? ro + 4 * (rng() % 27) : (rng() % 14) * 4;
        }
        }
    };
    int nmut = 1 + rng() % 4;
    size_t size = s.size;
    for (int m = 0; m < nmut; m++) {
        switch (rng() % 6) {
        case 0: {   // bit flip anywhere
            size_t off = rng() % s.size;
            char c = s.buf[off] ^ char(1 << (rng() % 8));
            put(off, &c, 1);
            break;
        }
        case 1:     // bit flip in a hot word
        case 2: {   // a hot word set to a boundary value
            size_t off = hot_word();
            if (off + 4 > s.size) {
                break;
            }
            uint32_t w = rd(s.buf + off);
            uint32_t vals[] = { 0, 1, 2, 3, uint32_t(s.size), uint32_t(s.size - 1),
                uint32_t(s.size + 1), uint32_t(s.size - 4), 0xffffffff, 0x7fffffff,
                0x80000000, w + 1, w + 2, w - 1, w + 4, w * 2, uint32_t(rng()) };
            uint32_t v = m % 2 && rng() % 2 ? w ^ (1u << (rng() % 32)) :
                vals[rng() % (sizeof(vals) / sizeof(vals[0]))];
            put(off, &v, 4);
            break;
        }
        case 3: {   // a NUL byte removed or inserted at a hot word's target
            size_t off = hot_word();
            if (off + 4 > s.size) {
                break;
            }
            size_t t = rd(s.buf + off);
            if (t < s.size) {
                char c = s.buf[t] ? 0 : 'x';
                put(t, &c, 1);
            }
            break;
        }
        case 4:     // truncation
            size = rng() % 4 ? size - rng() % (size < 64 ? size + 1 : 64) : rng() % (size + 1);
            break;
        default: {  // a random word anywhere
            size_t off = (rng() % (s.size / 4)) * 4;
            uint32_t v = uint32_t(rng());
            put(off, &v, 4);
        }
        }
    }
    if (size < s.size) {
        ASAN_POISON_MEMORY_REGION(s.buf + size, s.size - size);
    }
    run(s, size);
    if (size < s.size) {
        ASAN_UNPOISON_MEMORY_REGION(s.buf + size, s.size - size);
    }
    for (auto it = log.rbegin(); it != log.rend(); ++it) {
        memcpy(s.buf + it->off, it->old, it->n);
    }
}

// End to end through osv_locale_load(): mutated files under a LOCPATH
// directory, each in a fresh locale name (the loader caches by path).
void through_files(std::mt19937_64 &rng, int count)
{
    char tmpl[] = "/tmp/fuzz-locpath-XXXXXX";
    if (!mkdtemp(tmpl)) {
        exit(2);
    }
    setenv("LOCPATH", tmpl, 1);
    unsigned long ok = 0, enoent = 0;
    for (int i = 0; i < count; i++) {
        seed &s = seeds[rng() % seeds.size()];
        if (s.cat <= 0 || s.cat == 3) {
            continue;   // small categories only; their codeset item gates loading
        }
        std::string dir = std::string(tmpl) + "/xx_YY" + std::to_string(i) + ".utf8";
        mkdir(dir.c_str(), 0755);
        mkdir((dir + "/LC_MESSAGES").c_str(), 0755);
        std::vector<char> b(s.buf, s.buf + s.size);
        size_t size = s.size;
        if (rng() % 3) {
            b[rng() % size] ^= char(1 << (rng() % 8));
        } else {
            size = rng() % size;
        }
        std::string path = dir + "/" + file_names[s.cat];
        FILE *f = fopen(path.c_str(), "wb");
        fwrite(b.data(), 1, size, f);
        fclose(f);
        errno = 0;
        std::string name = "xx_YY" + std::to_string(i) + (rng() % 2 ? ".UTF-8" : ".utf8");
        const osv_locale_data *d = osv_locale_load(s.cat, name.c_str());
        if (d) {
            read_items(*d);
            ok++;
        } else {
            expect(errno == ENOENT, "load failure is ENOENT, errno " + std::to_string(errno));
            enoent++;
        }
        unlink(path.c_str());
        rmdir((dir + "/LC_MESSAGES").c_str());
        rmdir(dir.c_str());
    }
    rmdir(tmpl);
    printf("files: %lu loaded, %lu ENOENT\n", ok, enoent);
}

// Names at and past the 255-byte limit, with codesets whose normalised form
// is longer than the name (an all-digit codeset gains "iso"), through the
// archive (LOCPATH unset; needs /usr/lib/locale/locale-archive to reach the
// archive key) and a LOCPATH directory. All must fail cleanly.
void long_names()
{
    char *saved = getenv("LOCPATH") ? strdup(getenv("LOCPATH")) : nullptr;
    for (int with_locpath = 0; with_locpath < 2; with_locpath++) {
        if (with_locpath) {
            setenv("LOCPATH", "/tmp", 1);
        } else {
            unsetenv("LOCPATH");
        }
        for (size_t len = 240; len <= 260; len++) {
            for (const char *tail : { ".1", ".12345", ".8859-1", ".utf8", ".UTF-8@x", "" }) {
                std::string n(len - strlen(tail) > 0 ? len - strlen(tail) : 1, 'a');
                n += tail;
                errno = 0;
                const osv_locale_data *d = osv_locale_load(1, n.c_str());
                expect(!d && (errno == ENOENT || errno == EINVAL),
                       "long name " + std::to_string(n.size()) + " rejected, errno " +
                       std::to_string(errno));
            }
        }
    }
    if (saved) {
        setenv("LOCPATH", saved, 1);
        free(saved);
    } else {
        unsetenv("LOCPATH");
    }
}

} // namespace

int main(int argc, char **argv)
{
    if (argc >= 3 && !strcmp(argv[1], "--self-test")) {
        // Read every string item of a truncated file without validation:
        // must die under ASan.
        size_t size;
        char *full = read_file(argv[2], &size);
        size_t cut = 8 + 4 * size_t(rd(full + 4)) + 4;
        char *b = static_cast<char *>(malloc(cut));
        memcpy(b, full, cut);
        unsigned long acc = 0;
        for (uint32_t i = 0; i < rd(b + 4); i++) {
            acc += strlen(b + rd(b + 8 + 4 * size_t(i)));
        }
        printf("self-test: not detected (%lu)\n", acc);
        return 0;
    }
    if (argc < 4) {
        fprintf(stderr, "usage: %s <iterations> <rng-seed> <locale-dir>... [--archive <file>]\n",
                argv[0]);
        return 2;
    }
    unsigned long iters = strtoul(argv[1], nullptr, 0);
    std::mt19937_64 rng(strtoull(argv[2], nullptr, 0));
    std::vector<std::pair<std::string, std::vector<seed *>>> locs;
    std::string archive_path;
    std::vector<std::string> dirs;
    for (int i = 3; i < argc; i++) {
        if (!strcmp(argv[i], "--archive") && i + 1 < argc) {
            archive_path = argv[++i];
        } else {
            dirs.push_back(argv[i]);
        }
    }
    seeds.reserve(13 * dirs.size() + 2);
    for (const std::string &dir : dirs) {
        std::string name = dir.substr(dir.find_last_of('/') + 1);
        locs.push_back({ name, {} });
        for (int c = 0; c < 13; c++) {
            if (c == 6) {
                continue;
            }
            seed s;
            s.what = name + "/" + file_names[c];
            s.cat = c;
            s.buf = read_file(dir + "/" + file_names[c], &s.size);
            if (!s.buf) {
                fprintf(stderr, "cannot read %s\n", s.what.c_str());
                return 2;
            }
            seeds.push_back(s);
        }
    }
    for (size_t i = 0; i < dirs.size(); i++) {
        for (size_t j = 0; j < 12; j++) {
            locs[i].second.push_back(&seeds[12 * i + j]);
        }
    }
    seeds.push_back(build_archive(locs));
    if (!archive_path.empty()) {
        seed a;
        a.what = "locale-archive";
        a.cat = -1;
        a.buf = read_file(archive_path, &a.size);
        if (!a.buf) {
            return 2;
        }
        // Its names, from its own name table (read before any mutation).
        uint32_t ho = rd(a.buf + 8), hs = rd(a.buf + 16);
        for (uint32_t i = 0; i < hs; i++) {
            uint32_t no = rd(a.buf + ho + 12 * i + 4);
            if (no) {
                a.names.push_back(a.buf + no);
            }
        }
        seeds.push_back(a);
    }
    deterministic();
    long_names();
    printf("deterministic: %lu inputs, %d failures; archive %s\n", inputs, fails,
           access("/usr/lib/locale/locale-archive", R_OK) ? "absent (long names not checked "
           "through it)" : "present");
    through_files(rng, 3000);
    unsigned long before = inputs;
    accepted = rejected = 0;
    for (unsigned long i = 0; i < iters; i++) {
        random_input(rng);
    }
    printf("random: %lu inputs, %lu accepted (all items read back), %lu rejected\n",
           inputs - before, accepted, rejected);
    printf("SUMMARY: %d failures\n", fails);
    for (seed &s : seeds) {
        free(s.buf);
    }
    return fails ? 1 : 0;
}
