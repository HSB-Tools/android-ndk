/* Fork-safety oracle for bionic arc4random / arc4random_buf.
 *
 * Why this exists: the spliced sysroot arc4random.o replaced a madvise-based
 * fork-safety mechanism with the getpid-check forkdetect. A `-static` binary
 * built against the spliced libc.a must give a child a stream that differs from
 * the parent's continuation; a regression (parent == child) means the fork
 * safety broke. This is the executable gate for that property.
 *
 * Warm the RNG, draw a reference block, fork, then draw a block on each side.
 * Pass  -> exits 0, prints RESULT=DIFF.
 * Fail  -> exits 1, prints RESULT=SAME. (Against the ORIGINAL r30 archive this
 *          instead aborts rc=134 with "arc4random data MADV_WIPEONFORK failed"
 *          on kernels < 4.14, which is why the splice exists.)
 *
 * arc4random is not declared in headers before API 28, so declare it here.
 */
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>
#include <sys/wait.h>

extern uint32_t arc4random(void);
extern void arc4random_buf(void *, size_t);

#define N 32

static void hex(const char *tag, const unsigned char *b, size_t n) {
    printf("%-8s= ", tag);
    for (size_t i = 0; i < n; i++) printf("%02x", b[i]);
    printf("\n");
}

/* Block test: draw on both sides of a fork and compare the child against the
 * parent's continuation and against the pre-fork reference. */
static int test_buf(void) {
    int fd[2];
    if (pipe(fd) != 0) { perror("pipe"); return 2; }

    (void)arc4random();                 /* warm the state before forking */
    unsigned char pre[N];
    arc4random_buf(pre, sizeof pre);

    pid_t pid = fork();
    if (pid < 0) { perror("fork"); return 2; }

    if (pid == 0) {
        close(fd[0]);
        unsigned char c[N];
        arc4random_buf(c, sizeof c);
        if (write(fd[1], c, sizeof c) != (ssize_t)sizeof c) _exit(3);
        close(fd[1]);
        _exit(0);
    }

    close(fd[1]);
    unsigned char par[N], ch[N];
    arc4random_buf(par, sizeof par);
    ssize_t r = read(fd[0], ch, sizeof ch);
    close(fd[0]);
    int st = 0; waitpid(pid, &st, 0);
    if (r != (ssize_t)sizeof ch) { printf("buf: short read %zd\n", r); return 2; }

    int pc = memcmp(par, ch, sizeof par) == 0;
    int pre_hit = memcmp(pre, ch, sizeof ch) == 0 || memcmp(pre, par, sizeof par) == 0;

    hex("pre", pre, sizeof pre);
    hex("parent", par, sizeof par);
    hex("child", ch, sizeof ch);
    printf("buf: PARENT_%s_CHILD  PRE_COLLISION=%s\n",
           pc ? "EQ" : "NE", pre_hit ? "YES" : "NO");
    return (pc || pre_hit) ? 1 : 0;
}

/* Scalar test: same structure for arc4random(), so the oracle covers both
 * entry points rather than just one. */
static int test_scalar(void) {
    int fd[2];
    if (pipe(fd) != 0) return 2;
    (void)arc4random();
    uint32_t pre = arc4random();
    pid_t pid = fork();
    if (pid < 0) return 2;
    if (pid == 0) {
        close(fd[0]);
        uint32_t c = arc4random();
        if (write(fd[1], &c, sizeof c) != (ssize_t)sizeof c) _exit(3);
        close(fd[1]);
        _exit(0);
    }
    close(fd[1]);
    uint32_t par = arc4random(), ch = 0;
    ssize_t r = read(fd[0], &ch, sizeof ch);
    close(fd[0]);
    int st = 0; waitpid(pid, &st, 0);
    if (r != (ssize_t)sizeof ch) return 2;
    int pc = (par == ch);
    int pre_hit = (pre == ch || pre == par);
    printf("scalar: parent=%08x child=%08x PARENT_%s_CHILD PRE_COLLISION=%s\n",
           par, ch, pc ? "EQ" : "NE", pre_hit ? "YES" : "NO");
    return (pc || pre_hit) ? 1 : 0;
}

int main(void) {
    int bad = 0;
    if (test_buf())    bad = 1;
    if (test_scalar()) bad = 1;
    printf("RESULT=%s\n", bad ? "SAME" : "DIFF");
    return bad;
}
