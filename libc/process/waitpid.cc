#include <errno.h>
#include <sys/wait.h>
#include <osv/fork.hh>

// waitpid()/wait4() are backed by the fork() emulation's child registry
// (libc/process/fork.cc).  A child created by fork() records its exit status
// there when it exits; here the parent reaps it.

extern "C"
pid_t waitpid(pid_t pid, int *status, int options)
{
    return osv::fork::wait_child(pid, status, options);
}

extern "C"
pid_t wait4(pid_t pid, int *status, int options, struct rusage *rusage)
{
    if (rusage) {
        // We do not account per-child resource usage; zero it so callers that
        // read it see a well-defined (empty) result rather than garbage.
        __builtin_memset(rusage, 0, sizeof(*rusage));
    }
    return osv::fork::wait_child(pid, status, options);
}

extern "C"
pid_t wait(int *status)
{
    return osv::fork::wait_child(-1, status, 0);
}
