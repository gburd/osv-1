/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

// Multibyte conversion and MB_CUR_MAX in the C and C.UTF-8 locales, as glibc
// gives them with the distribution's standard C.utf8 installed (Debian/Ubuntu
// libc-bin, Fedora glibc). The expectations were measured on glibc 2.41, and
// this test passes there too (g++ -std=c++17, default environment).
//
// C: bytes 0..0x7f are characters, any other byte is EILSEQ, MB_CUR_MAX is 1,
// and regex and fnmatch take each high byte as one character.
// C.UTF-8: glibc's UTF-8, including the legacy 5- and 6-byte forms up to
// 0x7fffffff when decoding; MB_CUR_MAX is 6.
//
// One deliberate difference: glibc's wcrtomb() encodes 0x200000..0x7fffffff
// as 5 or 6 bytes, while OSv's fails with EILSEQ, because musl's stdio
// converts into 4-byte (MB_LEN_MAX) buffers and such values are never
// Unicode. Those checks accept either answer.

#include <cerrno>
#include <clocale>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cwchar>
#include <string>
#include <thread>

#include <fnmatch.h>
#include <langinfo.h>
#include <locale.h>
#include <regex.h>
#include <sys/mman.h>
#include <unistd.h>

static int tests, fails;

static void report(bool ok, const std::string &what)
{
    tests++;
    if (!ok) {
        fails++;
        printf("FAIL: %s\n", what.c_str());
    }
}

static std::string hex(const char *s, size_t n)
{
    std::string r;
    char b[4];
    for (size_t i = 0; i < n; i++) {
        snprintf(b, sizeof(b), "%02x", (unsigned char)s[i]);
        r += b;
    }
    return r;
}

static size_t mb_cur_max_item()
{
    return uintptr_t(nl_langinfo((LC_CTYPE << 16) | 13));    // _NL_CTYPE_MB_CUR_MAX
}

// mbrtowc from the initial state: the return value, the character and errno.
struct conv {
    size_t r;
    wchar_t wc;
    int err;
};

static conv mbr(const char *s, size_t n)
{
    mbstate_t st{};
    wchar_t wc = L'#';
    errno = 0;
    size_t r = mbrtowc(&wc, s, n, &st);
    return { r, wc, errno };
}

static void expect_mbr(const char *what, const char *s, size_t n, size_t r, wchar_t wc = L'#',
                       int err = 0)
{
    conv c = mbr(s, n);
    bool ok = c.r == r && c.err == err && (r >= size_t(-2) || c.wc == wc);
    report(ok, std::string(what) + ": mbrtowc(" + hex(s, n) + ") = " +
           std::to_string(long(c.r)) + " wc " + std::to_string(long(c.wc)) +
           " errno " + std::to_string(c.err));
}

static size_t wcr(wchar_t wc, char *buf, int *err)
{
    mbstate_t st{};
    errno = 0;
    size_t r = wcrtomb(buf, wc, &st);
    *err = errno;
    return r;
}

static bool regex_match(const char *re, const char *s)
{
    regex_t r;
    if (regcomp(&r, re, REG_NOSUB)) {
        return false;
    }
    bool m = regexec(&r, s, 0, nullptr, 0) == 0;
    regfree(&r);
    return m;
}

static void test_c()
{
    setlocale(LC_ALL, "C");
    const char *tag = "C";
    report(MB_CUR_MAX == 1, "C MB_CUR_MAX " + std::to_string(MB_CUR_MAX));
    report(mb_cur_max_item() == 1, "C _NL_CTYPE_MB_CUR_MAX");

    expect_mbr(tag, "A", 1, 1, L'A');
    expect_mbr(tag, "\x7f", 1, 1, 0x7f);
    expect_mbr(tag, "", 1, 0, 0);
    expect_mbr(tag, "\x80", 1, size_t(-1), 0, EILSEQ);
    expect_mbr(tag, "\xc3\xa9", 2, size_t(-1), 0, EILSEQ);
    expect_mbr(tag, "\xff", 1, size_t(-1), 0, EILSEQ);
    expect_mbr(tag, "A", 0, size_t(-2));
    mbstate_t st{};
    report(mbrtowc(nullptr, nullptr, 0, &st) == 0 && mbsinit(&st), "C mbrtowc(NULL) resets");

    wchar_t wc = 0;
    report(mbtowc(nullptr, nullptr, 0) == 0, "C mbtowc(NULL) is 0");
    report(mbtowc(&wc, "a", 1) == 1 && wc == L'a', "C mbtowc a");
    errno = 0;
    report(mbtowc(&wc, "\xe9", 1) == -1 && errno == EILSEQ, "C mbtowc high byte EILSEQ");

    // mbsrtowcs stops at the high byte; counting leaves *src alone.
    const char *in = "ab\xe9" "c";
    const char *src = in;
    wchar_t out[8];
    st = {};
    errno = 0;
    size_t r = mbsrtowcs(out, &src, 8, &st);
    report(r == size_t(-1) && errno == EILSEQ && src == in + 2, "C mbsrtowcs stops at the high byte");
    src = in;
    errno = 0;
    r = mbsrtowcs(nullptr, &src, 0, &st);
    report(r == size_t(-1) && errno == EILSEQ && src == in, "C mbsrtowcs count");
    src = "abc";
    r = mbsrtowcs(out, &src, 8, &st);
    report(r == 3 && !src && !wcscmp(out, L"abc"), "C mbsrtowcs abc");
    const char *abc = "abc";
    src = abc;
    r = mbsrtowcs(out, &src, 2, &st);
    report(r == 2 && src == abc + 2, "C mbsrtowcs len 2");
    src = in;
    errno = 0;
    r = mbsnrtowcs(out, &src, 4, 8, &st);
    report(r == size_t(-1) && errno == EILSEQ && src == in + 2, "C mbsnrtowcs stops at the high byte");

    report(btowc('a') == L'a' && btowc(0x7f) == 0x7f, "C btowc ASCII");
    report(btowc(0x80) == WEOF && btowc(0xff) == WEOF && btowc(EOF) == WEOF &&
           btowc(-2) == WEOF && btowc(0x100) == WEOF, "C btowc non-ASCII is WEOF");
    report(wctob(L'a') == 'a' && wctob(0x80) == EOF && wctob(0xe9) == EOF, "C wctob");

    char buf[8];
    int err;
    report(wcr(L'a', buf, &err) == 1 && buf[0] == 'a', "C wcrtomb a");
    report(wcr(0x80, buf, &err) == size_t(-1) && err == EILSEQ, "C wcrtomb 0x80 EILSEQ");
    report(wcr(0xe9, buf, &err) == size_t(-1) && err == EILSEQ, "C wcrtomb 0xe9 EILSEQ");
    report(wcrtomb(nullptr, 0xe9, &st) == 1, "C wcrtomb(NULL) is 1");
    const wchar_t *ws = L"a\xe9";
    errno = 0;
    report(wcsrtombs(nullptr, &ws, 0, nullptr) == size_t(-1) && errno == EILSEQ,
           "C wcsrtombs(NULL) EILSEQ");

    // musl's callers of the six.
    report(mblen("\xe9", 1) == -1 && mblen("a", 1) == 1, "C mblen");
    report(wctomb(buf, 0xe9) == -1 && wctomb(buf, L'a') == 1, "C wctomb");
    report(mbstowcs(out, "a\xe9", 8) == size_t(-1), "C mbstowcs");

    // Each high byte is one character to regex and fnmatch.
    report(regex_match("a.b", "a\xe9" "b"), "C regex a.b matches a\\xe9b");
    report(regex_match("^..$", "\xc3\xa9"), "C regex ^..$ matches two bytes");
    report(!regex_match("^.$", "\xc3\xa9"), "C regex ^.$ does not match two bytes");
    report(regex_match("\xe9", "x\xe9"), "C regex high byte literal");
    report(fnmatch("?", "\xc3\xa9", 0) == FNM_NOMATCH, "C fnmatch ? two bytes NOMATCH");
    report(fnmatch("??", "\xc3\xa9", 0) == 0, "C fnmatch ?? two bytes");
    report(fnmatch("a*b", "a\xe9\xe9" "b", 0) == 0, "C fnmatch a*b");
    report(fnmatch("*\xe9", "ab\xe9", 0) == 0, "C fnmatch *\\xe9");
}

static void test_utf8()
{
    if (!setlocale(LC_ALL, "C.UTF-8")) {
        report(false, "setlocale(C.UTF-8)");
        return;
    }
    const char *tag = "UTF-8";
    report(MB_CUR_MAX == 6, "UTF-8 MB_CUR_MAX " + std::to_string(MB_CUR_MAX));
    report(mb_cur_max_item() == 6, "UTF-8 _NL_CTYPE_MB_CUR_MAX");

    expect_mbr(tag, "A", 1, 1, L'A');
    expect_mbr(tag, "", 1, 0, 0);
    expect_mbr(tag, "\xc2\x80", 2, 2, 0x80);
    expect_mbr(tag, "\xc3\xa9", 2, 2, 0xe9);
    expect_mbr(tag, "\xdf\xbf", 2, 2, 0x7ff);
    expect_mbr(tag, "\xe0\xa0\x80", 3, 3, 0x800);
    expect_mbr(tag, "\xe2\x82\xac", 3, 3, 0x20ac);
    expect_mbr(tag, "\xed\x9f\xbf", 3, 3, 0xd7ff);
    expect_mbr(tag, "\xee\x80\x80", 3, 3, 0xe000);
    expect_mbr(tag, "\xef\xbf\xbf", 3, 3, 0xffff);
    expect_mbr(tag, "\xf0\x90\x80\x80", 4, 4, 0x10000);
    expect_mbr(tag, "\xf0\x9f\x98\x80", 4, 4, 0x1f600);
    expect_mbr(tag, "\xf4\x8f\xbf\xbf", 4, 4, 0x10ffff);
    expect_mbr(tag, "\xf4\x90\x80\x80", 4, 4, 0x110000);
    expect_mbr(tag, "\xf7\xbf\xbf\xbf", 4, 4, 0x1fffff);
    expect_mbr(tag, "\xf8\x88\x80\x80\x80", 5, 5, 0x200000);
    expect_mbr(tag, "\xfb\xbf\xbf\xbf\xbf", 5, 5, 0x3ffffff);
    expect_mbr(tag, "\xfc\x84\x80\x80\x80\x80", 6, 6, 0x4000000);
    expect_mbr(tag, "\xfd\xbf\xbf\xbf\xbf\xbf", 6, 6, 0x7fffffff);
    // Bytes that cannot start a character.
    for (const char *s : { "\x80\x80", "\xbf\x80", "\xc0\x80", "\xc1\xbf", "\xfe\x80", "\xff\x80" }) {
        expect_mbr(tag, s, 2, size_t(-1), 0, EILSEQ);
    }
    // Overlong forms and surrogates fail at the byte that completes them,
    // not before (glibc 2.41: e0 80 80 byte by byte is -2, -2, -1).
    for (const char *s : { "\xe0\x80\x80", "\xe0\x9f\xbf", "\xed\xa0\x80", "\xed\xbf\xbf",
                           "\xf0\x80\x80\x80", "\xf0\x8f\xbf\xbf", "\xf8\x80\x80\x80\x80",
                           "\xf8\x87\xbf\xbf\xbf", "\xfc\x80\x80\x80\x80\x80",
                           "\xfc\x83\xbf\xbf\xbf\xbf" }) {
        size_t n = strlen(s);
        expect_mbr(tag, s, n, size_t(-1), 0, EILSEQ);
        expect_mbr(tag, s, n - 1, size_t(-2));
        mbstate_t bst{};
        wchar_t bwc;
        bool ok = true;
        for (size_t i = 0; i < n; i++) {
            errno = 0;
            size_t r = mbrtowc(&bwc, s + i, 1, &bst);
            ok = ok && (i + 1 < n ? r == size_t(-2) : (r == size_t(-1) && errno == EILSEQ));
        }
        report(ok, std::string("UTF-8 bytewise ") + hex(s, n) + " is -2 until the last byte");
    }
    expect_mbr(tag, "\xe0\x80\x41", 3, size_t(-1), 0, EILSEQ);
    // c0 and c1 fail at once; a non-continuation byte ends a character early.
    struct { const char *s; size_t r0, r1; } early[] = {
        { "\xc0\x80", size_t(-1), 0 },
        { "\xc3\x41", size_t(-2), size_t(-1) },
        { "\xe0\xa0\x41", size_t(-2), size_t(-2) },
    };
    for (auto &e : early) {
        mbstate_t bst{};
        wchar_t bwc;
        errno = 0;
        size_t r0 = mbrtowc(&bwc, e.s, 1, &bst);
        bool ok = r0 == e.r0;
        if (r0 == size_t(-2)) {
            size_t r1 = mbrtowc(&bwc, e.s + 1, 1, &bst);
            ok = ok && r1 == e.r1;
            if (r1 == size_t(-2)) {
                errno = 0;
                ok = ok && mbrtowc(&bwc, e.s + 2, 1, &bst) == size_t(-1) && errno == EILSEQ;
            }
        }
        ok = ok && errno == EILSEQ;
        report(ok, std::string("UTF-8 bytewise ") + hex(e.s, strlen(e.s)) + " ends early");
    }
    expect_mbr(tag, "\xc3\x41", 2, size_t(-1), 0, EILSEQ);
    expect_mbr(tag, "\xc3", 1, size_t(-2));
    expect_mbr(tag, "\xc3", 0, size_t(-2));

    // A character split across calls; each call returns the bytes it used.
    mbstate_t st{};
    wchar_t wc = 0;
    size_t r1 = mbrtowc(&wc, "\xe2", 1, &st);
    bool partial = !mbsinit(&st);
    size_t r2 = mbrtowc(&wc, "\x82", 1, &st);
    size_t r3 = mbrtowc(&wc, "\xac", 1, &st);
    report(r1 == size_t(-2) && partial && r2 == size_t(-2) && r3 == 1 && wc == 0x20ac &&
           mbsinit(&st), "UTF-8 mbrtowc split character");
    st = {};
    mbrtowc(&wc, "\xc3", 1, &st);
    errno = 0;
    size_t r = mbrtowc(nullptr, nullptr, 0, &st);
    report(r == size_t(-1) && errno == EILSEQ, "UTF-8 mbrtowc(NULL) mid-character EILSEQ");

    // mbtowc: incomplete input is -1 with errno unchanged. OSv's mbtowc is
    // stateless; glibc keeps the partial character in hidden state after an
    // incomplete sequence, so reset it with mbtowc(NULL, ...) after each
    // failure to keep the test valid on both.
    errno = 0;
    report(mbtowc(&wc, "\xc3", 1) == -1 && errno == 0, "UTF-8 mbtowc incomplete, errno 0");
    mbtowc(nullptr, nullptr, 0);
    errno = 0;
    report(mbtowc(&wc, "\xff", 1) == -1 && errno == EILSEQ, "UTF-8 mbtowc invalid EILSEQ");
    mbtowc(nullptr, nullptr, 0);
    report(mbtowc(&wc, "\xc3\xa9", 2) == 2 && wc == 0xe9, "UTF-8 mbtowc");
    report(mbtowc(nullptr, nullptr, 0) == 0, "UTF-8 mbtowc(NULL) is 0");

    const char *in = "a\xc3\xa9" "b";
    const char *src = in;
    wchar_t out[64];
    st = {};
    report(mbsrtowcs(out, &src, 8, &st) == 3 && !src && out[1] == 0xe9, "UTF-8 mbsrtowcs");
    src = in;
    report(mbsrtowcs(nullptr, &src, 0, &st) == 3 && src == in, "UTF-8 mbsrtowcs count");
    const char *bad = "a\xff" "b";
    src = bad;
    errno = 0;
    report(mbsrtowcs(out, &src, 8, &st) == size_t(-1) && errno == EILSEQ && src == bad + 1,
           "UTF-8 mbsrtowcs stops at the invalid byte");

    report(btowc('a') == L'a' && btowc(0x80) == WEOF && btowc(0xc3) == WEOF && btowc(EOF) == WEOF,
           "UTF-8 btowc");
    report(wctob(L'a') == 'a' && wctob(0x80) == EOF && wctob(0xe9) == EOF, "UTF-8 wctob");

    struct { wchar_t wc; size_t n; const char *bytes; } enc[] = {
        { 0x7f, 1, "\x7f" },
        { 0x80, 2, "\xc2\x80" },
        { 0x7ff, 2, "\xdf\xbf" },
        { 0x800, 3, "\xe0\xa0\x80" },
        { 0xd7ff, 3, "\xed\x9f\xbf" },
        { 0xe000, 3, "\xee\x80\x80" },
        { 0xfffe, 3, "\xef\xbf\xbe" },
        { 0xffff, 3, "\xef\xbf\xbf" },
        { 0x10000, 4, "\xf0\x90\x80\x80" },
        { 0x10ffff, 4, "\xf4\x8f\xbf\xbf" },
        { 0x110000, 4, "\xf4\x90\x80\x80" },
        { 0x1fffff, 4, "\xf7\xbf\xbf\xbf" },
    };
    char buf[8];
    int err;
    for (auto &e : enc) {
        memset(buf, 0, sizeof(buf));
        size_t n = wcr(e.wc, buf, &err);
        report(n == e.n && !memcmp(buf, e.bytes, e.n),
               "UTF-8 wcrtomb " + std::to_string(e.wc) + " = " + std::to_string(long(n)) +
               " " + hex(buf, n <= 8 ? n : 0));
    }
    for (wchar_t s : { wchar_t(0xd800), wchar_t(0xdfff), wchar_t(0x80000000) }) {
        report(wcr(s, buf, &err) == size_t(-1) && err == EILSEQ,
               "UTF-8 wcrtomb " + std::to_string(long(s)) + " EILSEQ");
    }
    // The encoder cap: glibc gives 5 or 6 bytes, OSv EILSEQ.
    struct { wchar_t wc; size_t n; const char *bytes; } big[] = {
        { 0x200000, 5, "\xf8\x88\x80\x80\x80" },
        { 0x7fffffff, 6, "\xfd\xbf\xbf\xbf\xbf\xbf" },
    };
    for (auto &e : big) {
        size_t n = wcr(e.wc, buf, &err);
        report((n == e.n && !memcmp(buf, e.bytes, e.n)) || (n == size_t(-1) && err == EILSEQ),
               "UTF-8 wcrtomb " + std::to_string(e.wc) + " = " + std::to_string(long(n)));
    }
    report(wcrtomb(nullptr, 0xe9, &st) == 1, "UTF-8 wcrtomb(NULL) is 1");

    // wcsrtombs stops before a character that does not fit.
    const wchar_t w4[] = { L'a', 0x10000, L'b', 0 };
    const wchar_t *ws = w4;
    memset(buf, 0, sizeof(buf));
    report(wcsrtombs(buf, &ws, 4, nullptr) == 1 && ws == w4 + 1 && buf[0] == 'a',
           "UTF-8 wcsrtombs stops before 0x10000");
    // 0x7fffffff: glibc stops before it (1); OSv fails with EILSEQ only
    // because of the 4-byte encoder cap described above.
    const wchar_t w6[] = { L'a', 0x7fffffff, L'b', 0 };
    ws = w6;
    errno = 0;
    size_t n6 = wcsrtombs(buf, &ws, 4, nullptr);
    report(n6 == 1 || (n6 == size_t(-1) && errno == EILSEQ),
           "UTF-8 wcsrtombs a,7fffffff,b n=4 = " + std::to_string(long(n6)));

    report(mblen("\xc3\xa9", 2) == 2 && mblen("\xc3", 1) == -1, "UTF-8 mblen");
    mblen(nullptr, 0);
    report(wctomb(buf, 0xe9) == 2, "UTF-8 wctomb");
    report(mbstowcs(out, in, 8) == 3, "UTF-8 mbstowcs");

    report(regex_match("a.b", "a\xc3\xa9" "b"), "UTF-8 regex a.b matches a\\u00e9b");
    report(regex_match("^.$", "\xc3\xa9"), "UTF-8 regex ^.$ matches one character");
    report(fnmatch("?", "\xc3\xa9", 0) == 0, "UTF-8 fnmatch ? one character");
    setlocale(LC_ALL, "C");
}

// mbsnrtowcs never reads past n, even with 5- and 6-byte forms: the input
// ends at a guard page. A partial character at the end is consumed into the
// state, as glibc does.
static void test_mbsnrtowcs_bound()
{
    if (!setlocale(LC_ALL, "C.UTF-8")) {
        return;
    }
    long pg = sysconf(_SC_PAGESIZE);
    char *map = static_cast<char *>(mmap(nullptr, 2 * pg, PROT_READ | PROT_WRITE,
                                         MAP_PRIVATE | MAP_ANONYMOUS, -1, 0));
    if (map == MAP_FAILED || mprotect(map + pg, pg, PROT_NONE)) {
        report(false, "mmap guard page");
        return;
    }
    // 30 six-byte characters (enough for musl's n / 4 fast path) and the
    // first five bytes of a sixth-byte form, ending at the guard page.
    const char six[] = "\xfd\xbf\xbf\xbf\xbf\xbf";
    const char part[] = "\xfc\x84\x80\x80\x80";
    size_t n = 30 * 6 + 5;
    char *in = map + pg - n;
    for (int i = 0; i < 30; i++) {
        memcpy(in + 6 * i, six, 6);
    }
    memcpy(in + 180, part, 5);

    wchar_t out[64];
    mbstate_t st{};
    const char *src = in;
    size_t r = mbsnrtowcs(nullptr, &src, n, 0, &st);
    report(r == 30 && src == in && mbsinit(&st), "mbsnrtowcs count = " + std::to_string(long(r)));
    r = mbsnrtowcs(out, &src, n, 64, &st);
    report(r == 30 && src == in + n && out[29] == 0x7fffffff && !mbsinit(&st),
           "mbsnrtowcs = " + std::to_string(long(r)) + " consumed " +
           std::to_string(src ? long(src - in) : -1L));
    wchar_t wc = 0;
    r = mbrtowc(&wc, "\x80", 1, &st);
    report(r == 1 && wc == 0x4000000, "mbsnrtowcs leaves the partial character in the state");

    // A short input ending in a partial form.
    memcpy(map + pg - 7, "ab\xfc\x84\x80\x80\x80", 7);
    src = map + pg - 7;
    st = {};
    r = mbsnrtowcs(out, &src, 7, 64, &st);
    report(r == 2 && src == map + pg && !mbsinit(&st), "mbsnrtowcs short partial");
    munmap(map, 2 * pg);
    setlocale(LC_ALL, "C");
}

// A wide stream oriented in C.UTF-8 writes and reads UTF-8.
static void test_wide_stream()
{
    if (!setlocale(LC_ALL, "C.UTF-8")) {
        return;
    }
    FILE *f = tmpfile();
    if (!f) {
        report(false, "tmpfile");
        setlocale(LC_ALL, "C");
        return;
    }
    bool w = fputwc(0xa2, f) == 0xa2 && fputwc(0x20ac, f) == 0x20ac && fputwc(0x24b62, f) == 0x24b62;
    fflush(f);
    unsigned char b[16] = {};
    ssize_t n = pread(fileno(f), b, sizeof(b), 0);
    report(w && n == 9 && !memcmp(b, "\xc2\xa2\xe2\x82\xac\xf0\xa4\xad\xa2", 9),
           "UTF-8 fputwc writes UTF-8 (" + std::to_string(long(n)) + " bytes)");
    rewind(f);
    wint_t c1 = fgetwc(f), c2 = fgetwc(f), c3 = fgetwc(f);
    report(c1 == 0xa2 && c2 == 0x20ac && c3 == 0x24b62, "UTF-8 fgetwc reads UTF-8");
    fclose(f);
    setlocale(LC_ALL, "C");
}

// MB_CUR_MAX follows LC_CTYPE of the thread's locale.
static void test_locale_objects()
{
    setlocale(LC_ALL, "C");
    setlocale(LC_NUMERIC, "C.UTF-8");
    report(MB_CUR_MAX == 1, "LC_NUMERIC alone does not change MB_CUR_MAX");
    setlocale(LC_CTYPE, "C.UTF-8");
    report(MB_CUR_MAX == 6, "setlocale(LC_CTYPE, C.UTF-8)");
    setlocale(LC_ALL, "C.UTF-8");
    setlocale(LC_CTYPE, "C");
    report(MB_CUR_MAX == 1, "setlocale(LC_CTYPE, C) after C.UTF-8");
    setlocale(LC_ALL, "C");

    locale_t u = newlocale(LC_ALL_MASK, "C.UTF-8", nullptr);
    if (!u) {
        report(false, "newlocale(C.UTF-8)");
        return;
    }
    uselocale(u);
    report(MB_CUR_MAX == 6, "uselocale(C.UTF-8)");
    size_t other = 0;
    std::thread t([&] { other = MB_CUR_MAX; });
    t.join();
    report(other == 1, "another thread keeps the global C");
    wchar_t wc;
    report(mbtowc(&wc, "\xc3\xa9", 2) == 2, "mbtowc follows the thread locale");
    locale_t d = duplocale(u);
    uselocale(LC_GLOBAL_LOCALE);
    report(MB_CUR_MAX == 1, "back on the global locale");
    if (d) {
        uselocale(d);
        report(MB_CUR_MAX == 6, "duplocale copies the UTF-8 ctype");
        uselocale(LC_GLOBAL_LOCALE);
        freelocale(d);
    }
    locale_t c = newlocale(LC_CTYPE_MASK, "C", u);
    if (c) {
        uselocale(c);
        report(MB_CUR_MAX == 1, "newlocale(LC_CTYPE, C, base) clears it");
        uselocale(LC_GLOBAL_LOCALE);
        freelocale(c);
    } else {
        freelocale(u);
    }
}

int main()
{
    test_c();
    test_utf8();
    test_mbsnrtowcs_bound();
    test_wide_stream();
    test_locale_objects();
    printf("SUMMARY: %d tests, %d failures\n", tests, fails);
    return fails ? 1 : 0;
}
