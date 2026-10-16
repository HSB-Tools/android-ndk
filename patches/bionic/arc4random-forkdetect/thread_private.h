/* ABI shim for the NDK sysroot's shipped libc.a.
 *
 * arc4random.o is a single archive member, and libc_init_common.o consumes
 * arc4random_mutex_lock/unlock from it. The replacement member therefore has
 * to keep exporting exactly those two symbols, so the lock shim is linked into
 * the same member and this header points _ARC4_LOCK/_ARC4_UNLOCK at it instead
 * of at bionic's internal _thread_arc4_lock/unlock. */
#pragma once

#include <pthread.h>
#include <signal.h>

int arc4random_mutex_lock(void);
int arc4random_mutex_unlock(void);

#define _ARC4_LOCK() arc4random_mutex_lock()
#define _ARC4_UNLOCK() arc4random_mutex_unlock()
