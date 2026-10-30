/* musl (zig 0.17's bundled copy) declares no epoll_pwait2; Linux >= 5.11 has the syscall */
#include <sys/epoll.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
static inline int epoll_pwait2(int fd, struct epoll_event *ev, int n, const struct timespec *t, const sigset_t *s) {
  return (int)syscall(SYS_epoll_pwait2, fd, ev, n, t, s, (size_t)8);
}
