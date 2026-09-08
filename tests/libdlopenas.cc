/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 *
 * Companion library for tst-fork-dlopen-as.  It is dlopen()ed (never linked
 * against) so the test controls exactly which address space loads it first.
 *
 * dlopenas_value() reads a writable global that a constructor initializes.  A
 * caller that gets this library through the process-global object cache without
 * the mapping, the relocations or the constructor being established in its own
 * address space cannot return the right answer: it either faults or reads an
 * unrelocated zero.
 */

static int dlopenas_global;

extern "C" {

__attribute__((constructor))
static void dlopenas_init()
{
    dlopenas_global = 41;
}

int dlopenas_value()
{
    return dlopenas_global + 1;
}

}
