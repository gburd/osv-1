/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

/* Shared by libc/time/strftime.c and libc/time/strptime.c: eras (LC_TIME
 * ERA entries) and list items (ERA, ALT_DIGITS). */

#ifndef OSV_TIME_H
#define OSV_TIME_H

#include <langinfo.h>
#include <locale.h>
#include <stddef.h>

#define OSV_HIDDEN_C __attribute__((visibility("hidden")))

struct __osv_era {
	long long start, end;	/* yyyy*10000 + mm*100 + dd; LLONG_MIN, LLONG_MAX for -* and +* */
	long offset;
	int dir;		/* '+' or '-' */
	const char *name, *format;
	size_t name_len;
};

/* Parse one ERA entry "dir:offset:start:end:name:format"; 0 if malformed. */
OSV_HIDDEN_C int __osv_era_parse(const char *, struct __osv_era *);
/* The era year of Gregorian year y in era e. */
OSV_HIDDEN_C long long __osv_era_year(const struct __osv_era *, long long y);
/* String i of the list item (ERA, ALT_DIGITS) of locale l, or 0 past its
 * end (libc/locale/locale.cc). */
OSV_HIDDEN_C const char *__osv_nl_list(nl_item, unsigned, locale_t);

#endif
