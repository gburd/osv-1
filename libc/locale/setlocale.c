/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

#include <locale.h>
#include <string.h>

/*
 * OSv has no on-disk locale database and ships only the C locale.  This
 * setlocale() must therefore return a locale name that the rest of the C
 * library (newlocale/uselocale) will actually accept, otherwise a caller that
 * feeds setlocale()'s result back into newlocale() -- as PostgreSQL does when
 * it derives a new database's default collation from the environment -- ends
 * up with a locale name that cannot be instantiated.
 *
 * The historical stub returned "C.UTF-8" unconditionally.  That name is not
 * accepted by OSv's newlocale (it recognizes only "C"/"POSIX"/""), so a
 * PostgreSQL cluster initialized with LC_COLLATE=C would nonetheless stamp
 * every CREATE DATABASE with datcollate="C.UTF-8" and then fail to open those
 * databases ("could not create locale \"C.UTF-8\": ENOENT").  Returning the
 * plain "C" name keeps setlocale() and newlocale() in agreement: the only
 * locale OSv actually provides is reported and can be reopened.  Server
 * character-set encoding (e.g. UTF8) is independent of the libc locale and is
 * unaffected.
 *
 * A query (locale == NULL) and any set request both report the single
 * supported locale; there is nothing else to switch to.
 */
char *setlocale(int category, const char *locale)
{
	(void)category;
	(void)locale;
	return "C";
}
