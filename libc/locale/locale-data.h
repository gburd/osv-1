/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

// Named locales from glibc-format locale data (conf_locale=1). The formats
// and the search order are described at the top of locale-data.cc.

#ifndef OSV_LOCALE_DATA_H
#define OSV_LOCALE_DATA_H

#include <stddef.h>
#include <stdint.h>

#define OSV_LOCALE_HIDDEN __attribute__((visibility("hidden")))

// The LC_CTYPE tables of a loaded locale (STAGE1-FORMAT-SPEC.md section 5),
// validated when the category is loaded so every lookup stays in the data.
// A 3-level table is: uint32_t shift1, n1, shift2, mask2, mask3, then n1
// offsets (from the table) of level-2 arrays of mask2 + 1 offsets of level-3
// arrays of mask3 + 1 entries: words of class bits, int32_t case deltas, or
// width bytes (0xff: -1). An offset 0 is "no entry".
struct osv_ctype {
    // __ctype_b, __ctype_toupper, __ctype_tolower, indexable -128..255. They
    // point into copies (bytes[]) in the cache entry, not into the mapped
    // file: OSv's own kernel code calls toupper() (ACPICA at power-off),
    // after vfs_exit() has unmounted the file systems the file is on.
    const uint16_t *class_b;
    const int32_t *toupper_b, *tolower_b;
    const char *cls[12];                // alnum .. xdigit (wctype.cc order), or null
    const char *toupper, *tolower;      // map tables, or null
    const char *width;
    const char *class_names, *map_names;    // consecutive NUL-terminated names
    uint32_t class_offset, map_offset, nclass, nmap;
    const char *base;
    const uint32_t *strindex;
};

// One validated category of a named locale: a category file, or its slice of
// the locale archive. Mapped read-only and kept for the life of the process.
struct osv_locale_data {
    const char *base;
    uint32_t size;
    uint32_t nstrings;
    int cat;
    osv_ctype ctype;    // LC_CTYPE only
    // LC_CTYPE: the three byte tables, copied (see osv_ctype).
    uint16_t class_copy[384];
    int32_t toupper_copy[384], tolower_copy[384];
};

// Find, map and validate category cat (glibc numbering, LC_ALL excluded) of
// the locale name. Only UTF-8 locales load. On failure return nullptr with
// errno ENOENT (or EINVAL for a bad category or name, ENOMEM).
OSV_LOCALE_HIDDEN const osv_locale_data *osv_locale_load(int cat, const char *name) noexcept;

// nl_langinfo() of item idx of a loaded category: a pointer into the data,
// or for a word item its value in the pointer bits; "" past nstrings.
OSV_LOCALE_HIDDEN char *osv_locale_item(const osv_locale_data *d, int idx) noexcept;

// String i of item idx read as a list of NUL-terminated strings (ERA,
// ALT_DIGITS), or nullptr if it would not end within the data.
OSV_LOCALE_HIDDEN const char *osv_locale_list(const osv_locale_data *d, int idx,
                                              unsigned i) noexcept;

// The checks osv_locale_load() applies, also used by the fuzz harness
// (scripts/locale-oracle/fuzz-locale-data.cc). osv_locale_check() validates
// one category of size bytes at base; osv_locale_archive_find() finds a
// locale's category in an archive image and validates it. Both return true
// and fill *out on success.
OSV_LOCALE_HIDDEN bool osv_locale_check(int cat, const char *base, size_t size,
                                        osv_locale_data *out) noexcept;
OSV_LOCALE_HIDDEN bool osv_locale_archive_find(const char *archive, size_t size,
                                               const char *name, int cat,
                                               osv_locale_data *out) noexcept;

// Lookups in a validated 3-level table (any wc, including WEOF).
OSV_LOCALE_HIDDEN int osv_ctype_class(const char *table, uint32_t wc) noexcept;
OSV_LOCALE_HIDDEN uint32_t osv_ctype_map(const char *table, uint32_t wc) noexcept;
OSV_LOCALE_HIDDEN int osv_ctype_width(const char *table, uint32_t wc) noexcept;
// The class or map table of a locale named name (CLASS_NAMES, MAP_NAMES), or
// null.
OSV_LOCALE_HIDDEN const char *osv_ctype_find(const osv_ctype *c, const char *name,
                                             bool map) noexcept;

#endif
