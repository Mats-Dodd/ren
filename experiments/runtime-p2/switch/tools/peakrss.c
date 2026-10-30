// Linux stand-in for macOS `/usr/bin/time -l` (which this machine lacks):
//   peakrss cmd args...
// runs cmd with stdout/stderr passed through, waits for it, then prints
//   PEAKRSS peak_rss_bytes=<ru_maxrss * 1024> status=<exit status>
// to stderr and exits with cmd's status. ru_maxrss is the child's peak
// resident set (kB on Linux), not macOS's peak phys_footprint.
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: %s cmd [args...]\n", argv[0]); return 2; }
  pid_t pid = fork();
  if (pid < 0) { perror("fork"); return 2; }
  if (pid == 0) { execvp(argv[1], argv + 1); fprintf(stderr, "peakrss: exec %s: %s\n", argv[1], strerror(errno)); _exit(127); }
  int st = 0;
  struct rusage ru;
  while (wait4(pid, &st, 0, &ru) < 0) {
    if (errno != EINTR) { perror("wait4"); return 2; }
  }
  int code = WIFEXITED(st) ? WEXITSTATUS(st) : 128 + (WIFSIGNALED(st) ? WTERMSIG(st) : 0);
  fprintf(stderr, "PEAKRSS peak_rss_bytes=%ld status=%d\n", ru.ru_maxrss * 1024L, code);
  return code;
}
