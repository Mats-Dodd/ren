/* The real `Proc.run`'s child, started where OCaml's `Unix` can't start
   one: in a process group of its own, so cancelling the run kills the
   group, the program and everything it started (`kill: Tree`,
   compiler.md, "Services stage", step 4). `Unix.create_process` can't
   set a process group, and OCaml code can't run between `fork` and
   `exec` safely, so the child here runs only C: it leaves its parent's
   group if asked, clears the signal mask it inherited, and `execv`s.
   An `execv` that fails says why through a pipe closed on `exec`, so the
   parent raises it as `Unix.create_process` would. */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/unixsupport.h>

/* A pipe whose ends close on `exec`. Linux makes one at once; macOS has
   no `pipe2`, so its ends are marked after, which leaves a moment where
   another thread's `fork` could inherit them: harmless here, since such a
   child only keeps the pipe open until it `exec`s. */
static int cloexec_pipe(int fds[2])
{
#ifdef __linux__
  return pipe2(fds, O_CLOEXEC);
#else
  if (pipe(fds) == -1) return -1;
  if (fcntl(fds[0], F_SETFD, FD_CLOEXEC) == -1 ||
      fcntl(fds[1], F_SETFD, FD_CLOEXEC) == -1) {
    int e = errno;
    close(fds[0]);
    close(fds[1]);
    errno = e;
    return -1;
  }
  return 0;
#endif
}

/* ren_spawn(path, argv, group): the child's pid. [path] is the program,
   found already; [argv] its arguments, its name first; [group] whether it
   goes in a process group of its own. */
CAMLprim value ren_spawn(value path, value argv, value group)
{
  CAMLparam3(path, argv, group);
  mlsize_t n = Wosize_val(argv);
  /* copied before the fork: the child touches no OCaml value */
  char **args = malloc((n + 1) * sizeof(char *));
  char *prog = strdup(String_val(path));
  int own = Bool_val(group);
  if (args == NULL || prog == NULL) {
    free(args);
    free(prog);
    caml_unix_error(ENOMEM, "fork", Nothing);
  }
  for (mlsize_t i = 0; i < n; i++) args[i] = strdup(String_val(Field(argv, i)));
  args[n] = NULL;

  int fds[2];
  if (cloexec_pipe(fds) == -1) {
    int e = errno;
    for (mlsize_t i = 0; i < n; i++) free(args[i]);
    free(args);
    free(prog);
    caml_unix_error(e, "pipe", Nothing);
  }

  pid_t pid = fork();
  if (pid == 0) {
    sigset_t none;
    if (own) setpgid(0, 0);
    sigemptyset(&none);
    sigprocmask(SIG_SETMASK, &none, NULL);
    execv(prog, args);
    int e = errno;
    ssize_t w;
    do w = write(fds[1], &e, sizeof e); while (w == -1 && errno == EINTR);
    _exit(127);
  }
  int forked = errno;
  close(fds[1]);
  for (mlsize_t i = 0; i < n; i++) free(args[i]);
  free(args);
  free(prog);
  if (pid == -1) {
    close(fds[0]);
    caml_unix_error(forked, "fork", Nothing);
  }
  /* the parent sets the group too, so a kill of it right after this
     returns reaches the child even if it hasn't run yet; once the child
     has `exec`d this fails, harmlessly */
  if (own) setpgid(pid, pid);

  int e;
  ssize_t r;
  do r = read(fds[0], &e, sizeof e); while (r == -1 && errno == EINTR);
  close(fds[0]);
  if (r == (ssize_t)sizeof e) {
    /* it never ran: reap the child that tried */
    while (waitpid(pid, NULL, 0) == -1 && errno == EINTR) {}
    caml_unix_error(e, "execv", Nothing);
  }
  CAMLreturn(Val_int(pid));
}
