#include <pthread.h>

static pthread_mutex_t arc4random_mtx = PTHREAD_MUTEX_INITIALIZER;

int arc4random_mutex_lock(void) {
  return pthread_mutex_lock(&arc4random_mtx);
}

int arc4random_mutex_unlock(void) {
  return pthread_mutex_unlock(&arc4random_mtx);
}
