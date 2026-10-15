/*
 * This file is an OSv copy of musl's src/locale/strfmon.c, modified for OSv by
 * Greg Burd in 2026 (formatting from LC_MONETARY as glibc 2.41 does,
 * measured by running it).
 *
 * musl as a whole is licensed under the following standard MIT license:
 *
 * Copyright (c) 2005-2020 Rich Felker, et al.
 *
 * Permission is hereby granted, free of charge, to any person obtaining
 * a copy of this software and associated documentation files (the
 * "Software"), to deal in the Software without restriction, including
 * without limitation the rights to use, copy, modify, merge, publish,
 * distribute, sublicense, and/or sell copies of the Software, and to
 * permit persons to whom the Software is furnished to do so, subject to
 * the following conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
 * IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
 * CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
 * TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
 * SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

/* strfmon and strfmon_l from the locale's LC_MONETARY items (POSIX), with
 * glibc 2.41's observable choices (scripts/locale-oracle/time-diff/
 * fmdiff.c compares every flag, width and precision with glibc's):
 * - flags =f ^ ( + ! -, a field width (in bytes, as glibc), #left and
 *   .right precision, L (long double), n or i;
 *   '(' and '+' together, or a bad conversion, is EINVAL;
 * - frac_digits CHAR_MAX (the C locale) is 2; an empty mon_decimal_point is
 *   "."; the value is rounded as printf("%.*f") rounds;
 * - grouping from mon_grouping and mon_thousands_sep, unless '^';
 * - #n pads the integer part with the fill character to the width n digits
 *   would take with their group separators, and reserves room for the sign;
 * - %i uses the international items, its symbol without its fourth
 *   character (the separator the symbol carries);
 * - the sign and symbol are placed by [int_]{p,n}_{cs_precedes,
 *   sep_by_space,sign_posn} (with '+', %i uses the national sign_posn, as
 *   glibc); CHAR_MAX positions act as glibc's defaults;
 * - with '#', the front is padded by how much longer the other sign's text
 *   before the digits is, counting the symbol even under '!'. */

#include <stdio.h>
#include <ctype.h>
#include <stdarg.h>
#include <monetary.h>
#include <errno.h>
#include <limits.h>
#include <langinfo.h>
#include <string.h>
#include <math.h>
#include "locale_impl.h"

#define MON(i) ((LC_MONETARY << 16) | (i))

struct buf {
	char *s;
	size_t n, l;
};

static void add(struct buf *b, const char *p, size_t k)
{
	for (size_t i = 0; i < k; i++) {
		if (b->l < b->n) b->s[b->l] = p[i];
		b->l++;
	}
}

static void adds(struct buf *b, const char *p)
{
	add(b, p, strlen(p));
}

static void addc(struct buf *b, int c, size_t k)
{
	char ch = c;
	while (k--) add(b, &ch, 1);
}

static int mbyte(locale_t loc, int i)
{
	int c = (signed char)*__nl_langinfo_l(MON(i), loc);
	return c == -1 ? CHAR_MAX : c;
}

/* The width in characters of a UTF-8 (or single-byte) string: the field
 * width counts characters, as glibc's does. */
static size_t chars(const char *p, size_t k)
{
	size_t n = 0;
	for (size_t i = 0; i < k; i++) n += ((unsigned char)p[i] & 0xc0) != 0x80;
	return n;
}

/* Group the k integer digits at d into out per grouping g with separator
 * sep; return the length. */
static size_t group(char *out, const char *d, size_t k, const char *g, const char *sep)
{
	/* group sizes from the right */
	char tmp[512];
	size_t t = 0, sl = strlen(sep), cnt = 0;
	const char *gp = g;
	int size = *gp > 0 && *gp != CHAR_MAX ? *gp : 0;
	for (size_t i = k; i > 0; i--) {
		if (size && cnt == (size_t)size && sl) {
			for (size_t j = sl; j > 0; j--) tmp[t++] = sep[j - 1];
			cnt = 0;
			if (gp[1] && gp[1] != CHAR_MAX) {
				gp++;
				size = *gp > 0 ? *gp : 0;
			} else if (gp[1] == CHAR_MAX) {
				size = 0;
			}
		}
		tmp[t++] = d[i - 1];
		cnt++;
		if (t > sizeof tmp - 16) break;
	}
	for (size_t i = 0; i < t; i++) out[i] = tmp[t - 1 - i];
	return t;
}

/* How many separators k digits get under grouping g. */
static size_t nseps(size_t k, const char *g)
{
	size_t n = 0, left = k;
	const char *gp = g;
	int size = *gp > 0 && *gp != CHAR_MAX ? *gp : 0;
	while (size && left > (size_t)size) {
		left -= size;
		n++;
		if (gp[1] && gp[1] != CHAR_MAX) size = *++gp > 0 ? *gp : 0;
		else if (gp[1] == CHAR_MAX) size = 0;
	}
	return n;
}

/* Append the sign, the symbol and the value (vl bytes) to b, placed by the
 * locale's positions for a negative or positive value; return the number of
 * bytes before the value. */
static size_t assemble(struct buf *b, locale_t loc, int neg, int paren, int plus, int intl,
		       const char *sym, const char *val, size_t vl)
{
	int cs_pre = mbyte(loc, intl ? 16 + 2 * neg : 9 + 2 * neg);
	int sep_sp = mbyte(loc, intl ? 17 + 2 * neg : 10 + 2 * neg);
	/* glibc: with '+', %i takes the national sign position */
	int posn = mbyte(loc, intl && !plus ? 20 + neg : 13 + neg);
	const char *nsign = __nl_langinfo_l(MON(6), loc);
	if (!*nsign) nsign = "-";
	const char *sign = neg ? nsign : __nl_langinfo_l(MON(5), loc);
	if (paren) {
		posn = 0;
		sign = "";
	}
	if (cs_pre == CHAR_MAX) cs_pre = 1;
	if (sep_sp == CHAR_MAX) sep_sp = 0;
	if (posn == CHAR_MAX) posn = 1;
	int sp = *sym ? sep_sp : 0;
	if (posn == 0 && neg) adds(b, "(");
	if (posn == 1) adds(b, sign);
	if (cs_pre) {
		if (posn == 3) {
			adds(b, sign);
			if (sp == 2) adds(b, " ");
		}
		adds(b, sym);
		if (posn == 4) {
			if (sp == 2) adds(b, " ");
			adds(b, sign);
		}
		if (sp == 1) adds(b, " ");
	}
	size_t pre = b->l;
	add(b, val, vl);
	if (!cs_pre) {
		if (sp == 1) adds(b, " ");
		if (posn == 3) {
			adds(b, sign);
			if (sp == 2) adds(b, " ");
		}
		adds(b, sym);
		if (posn == 4) {
			if (sp == 2) adds(b, " ");
			adds(b, sign);
		}
	}
	if (posn == 2) adds(b, sign);
	if (posn == 0 && neg) adds(b, ")");
	return pre;
}

static ssize_t vstrfmon_l(char *s, size_t n, locale_t loc, const char *fmt, va_list ap)
{
	struct buf out = { s, n, 0 };
	while (*fmt) {
		if (*fmt != '%') {
			add(&out, fmt++, 1);
			continue;
		}
		fmt++;
		if (*fmt == '%') {
			add(&out, fmt++, 1);
			continue;
		}
		int fill = ' ', nogrp = 0, paren = 0, plus = 0, nosym = 0, left = 0;
		for (;; fmt++) {
			if (*fmt == '=') {
				if (!*++fmt) goto einval;
				fill = *fmt;
			} else if (*fmt == '^') nogrp = 1;
			else if (*fmt == '(') {
				if (plus) goto einval;
				paren = 1;
			} else if (*fmt == '+') {
				if (paren) goto einval;
				plus = 1;
			} else if (*fmt == '!') nosym = 1;
			else if (*fmt == '-') left = 1;
			else break;
		}
		size_t fw = 0, lp = 0, rp = 0;
		int have_lp = 0, have_rp = 0;
		while (isdigit((unsigned char)*fmt)) fw = fw * 10 + (*fmt++ - '0');
		if (*fmt == '#') {
			fmt++;
			if (!isdigit((unsigned char)*fmt)) goto einval;
			while (isdigit((unsigned char)*fmt)) lp = lp * 10 + (*fmt++ - '0');
			have_lp = 1;
		}
		if (*fmt == '.') {
			fmt++;
			if (!isdigit((unsigned char)*fmt)) goto einval;
			while (isdigit((unsigned char)*fmt)) rp = rp * 10 + (*fmt++ - '0');
			have_rp = 1;
		}
		int ldbl = 0, intl;
		if (*fmt == 'L') ldbl = 1, fmt++;
		if (*fmt == 'n') intl = 0;
		else if (*fmt == 'i') intl = 1;
		else goto einval;
		fmt++;
		if (fw > 4096 || lp > 4096 || rp > 400) goto e2big;

		long double x = ldbl ? va_arg(ap, long double) : va_arg(ap, double);
		int neg = x < 0;
		if (neg) x = -x;
		if (!have_rp) {
			int fd = mbyte(loc, intl ? 7 : 8);
			rp = fd == CHAR_MAX ? 2 : fd;
		}
		const char *sym = __nl_langinfo_l(MON(intl ? 0 : 1), loc);
		char isym[8];
		if (intl) {
			size_t k = strlen(sym);
			if (k > 3) k = 3;
			memcpy(isym, sym, k);
			isym[k] = 0;
			sym = isym;
		}
		const char *fsym = sym;
		if (nosym) sym = "";
		/* the digits */
		char num[1024];
		int k = snprintf(num, sizeof num, "%.*Lf", (int)rp, x);
		if (k < 0 || k >= (int)sizeof num) goto e2big;
		char *dot = strchr(num, '.');
		size_t ilen = dot ? (size_t)(dot - num) : (size_t)k;
		const char *dp = __nl_langinfo_l(MON(2), loc);
		if (!*dp) dp = ".";
		const char *g = __nl_langinfo_l(MON(4), loc), *ts = __nl_langinfo_l(MON(3), loc);
		if (nogrp || !*ts) g = "";
		char val[2048];
		size_t vl = 0;
		if (have_lp) {
			size_t want = lp + nseps(lp, g) * chars(ts, strlen(ts));
			size_t have = ilen + nseps(ilen, g) * chars(ts, strlen(ts));
			for (; have < want && vl < 1024; have++) val[vl++] = fill;
		}
		vl += group(val + vl, num, ilen, g, ts);
		if (dot) {
			size_t dl = strlen(dp);
			memcpy(val + vl, dp, dl);
			vl += dl;
			memcpy(val + vl, dot + 1, k - ilen - 1);
			vl += k - ilen - 1;
		}

		/* Assemble; with '#', pad the front by how much longer the other
		 * sign's text before the digits is (glibc aligns both signs). */
		struct buf f;
		char fbuf[4096];
		f.s = fbuf;
		f.n = sizeof fbuf;
		f.l = 0;
		if (have_lp) {
			char tmp[256];
			struct buf t = { tmp, sizeof tmp, 0 };
			/* measured with the symbol even under '!' */
			size_t other = assemble(&t, loc, !neg, paren, plus, intl, fsym, "", 0);
			struct buf u = { tmp, sizeof tmp, 0 };
			size_t mine = assemble(&u, loc, neg, paren, plus, intl, fsym, "", 0);
			if (other > mine) addc(&f, ' ', other - mine);
		}
		assemble(&f, loc, neg, paren, plus, intl, sym, val, vl);
		if (f.l > f.n) goto e2big;

		size_t wch = f.l;	/* glibc counts the field width in bytes */
		if (!left && fw > wch) addc(&out, ' ', fw - wch);
		add(&out, fbuf, f.l);
		if (left && fw > wch) addc(&out, ' ', fw - wch);
	}
	if (out.l >= n) goto e2big;
	s[out.l] = 0;
	return out.l;
einval:
	errno = EINVAL;
	return -1;
e2big:
	errno = E2BIG;
	return -1;
}

ssize_t strfmon_l(char *restrict s, size_t n, locale_t loc, const char *restrict fmt, ...)
{
	va_list ap;
	ssize_t ret;

	va_start(ap, fmt);
	ret = vstrfmon_l(s, n, loc, fmt, ap);
	va_end(ap);

	return ret;
}


ssize_t strfmon(char *restrict s, size_t n, const char *restrict fmt, ...)
{
	va_list ap;
	ssize_t ret;

	va_start(ap, fmt);
	ret = vstrfmon_l(s, n, CURRENT_LOCALE, fmt, ap);
	va_end(ap);

	return ret;
}
