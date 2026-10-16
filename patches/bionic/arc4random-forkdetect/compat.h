#pragma once

#include <stddef.h>

/* getentropy is declared in bionic only behind API >= 28 guards; the sysroot
 * libc.a provides it at every level. explicit_bzero is an alias for
 * memset_explicit in this bionic. */
int getentropy(void* buffer, size_t length);
void* memset_explicit(void* s, int c, size_t n);
#define explicit_bzero(p, n) memset_explicit((p), 0, (n))

/* Upstream's arc4random.c marks both entry points DEF_WEAK, but the shipped
 * r30 libc.a exports them as plain globals and nothing depends on weakness,
 * so compile them strong. */
#define DEF_WEAK(x)
