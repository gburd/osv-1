/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

#include <osv/fork.hh>
#include <errno.h>
#include <signal.h>
#include <sys/wait.h>
#include <unordered_map>
#include <memory>
#include <osv/sched.hh>
#include <osv/mutex.h>
#include <osv/condvar.h>
#include <osv/app.hh>
#include "../libc.hh"

// Arch hook (arch/<arch>/clone.cc): create a child thread that resumes at the
// same point fork() was called, on a PRIVATE COPY of the parent's current user
// stack, returning 0 in the child.  Reuses the register/continuation machinery
// that clone_thread() already implements for pthread_create; the only delta is
// that fork supplies a copied stack instead of a caller-provided one.
extern sched::thread *fork_thread();

namespace osv {
namespace fork {

namespace {

struct child_state {
    pid_t parent_pid;
    bool exited = false;
    int status = 0;              // encoded: (exit_code & 0xff) << 8, or signal
    shared_app_t execed_app;     // set if the child execve()'d a program
};

mutex g_lock;
condvar g_cv;
// child pid -> state
std::unordered_map<pid_t, std::shared_ptr<child_state>> g_children;

pid_t current_pid()
{
    return sched::thread::current()->id();
}

} // anonymous namespace

void adopt_execed_app(shared_app_t app)
{
    SCOPE_LOCK(g_lock);
    auto it = g_children.find(current_pid());
    if (it != g_children.end()) {
        it->second->execed_app = app;
    }
}

void register_child(pid_t child_pid, pid_t parent_pid)
{
    SCOPE_LOCK(g_lock);
    auto st = std::make_shared<child_state>();
    st->parent_pid = parent_pid;
    g_children[child_pid] = st;
}

void child_exited(pid_t child_pid, int status)
{
    pid_t parent;
    {
        SCOPE_LOCK(g_lock);
        auto it = g_children.find(child_pid);
        if (it == g_children.end()) {
            return;
        }
        if (it->second->exited) {
            return;   // already recorded (e.g. exit() then thread cleanup); don't clobber/re-notify
        }
        it->second->exited = true;
        it->second->status = status;
        parent = it->second->parent_pid;
        g_cv.wake_all();
    }
    // Notify the parent, Linux-style, that a child changed state.
    (void)parent;
    kill(getpid(), SIGCHLD);
}

bool exit_current_child(int status)
{
    pid_t me = current_pid();
    {
        SCOPE_LOCK(g_lock);
        if (g_children.find(me) == g_children.end()) {
            return false;   // top-level app: exit() shuts OSv down as usual
        }
    }
    // Encode like Linux wait status for a normal exit: WEXITSTATUS in bits 8-15.
    child_exited(me, (status & 0xff) << 8);
    return true;
}

pid_t wait_child(pid_t pid, int *status, int options)
{
    pid_t me = getpid();
    WITH_LOCK(g_lock) {
        while (true) {
            // Find a matching, exited child of the caller.
            for (auto it = g_children.begin(); it != g_children.end(); ++it) {
                bool match = (pid == -1 || pid == 0) ? (it->second->parent_pid == me)
                                                     : (it->first == pid);
                if (!match) {
                    continue;
                }
                if (it->second->exited) {
                    pid_t cpid = it->first;
                    if (status) {
                        *status = it->second->status;
                    }
                    g_children.erase(it);
                    return cpid;
                }
            }
            // No exited match.  Do we even have a matching (live) child?
            bool have_match = false;
            for (auto &kv : g_children) {
                if ((pid == -1 || pid == 0) ? (kv.second->parent_pid == me)
                                            : (kv.first == pid)) {
                    have_match = true;
                    break;
                }
            }
            if (!have_match) {
                errno = ECHILD;
                return -1;
            }
            if (options & WNOHANG) {
                return 0;   // matching child(ren) exist but none has exited yet
            }
            g_cv.wait(&g_lock);
        }
    }
    // not reached
    return -1;
}

} // namespace fork
} // namespace osv

using namespace osv;

extern "C"
pid_t fork(void)
{
    pid_t parent = getpid();

    sched::thread *child = fork_thread();
    if (!child) {
        errno = ENOMEM;
        return -1;
    }
    pid_t cpid = child->id();

    // Register the child BEFORE starting it so a fast child->exit cannot race
    // ahead of the parent's bookkeeping.
    fork::register_child(cpid, parent);

    // Arrange the child's exit to record status + notify the parent.  The child
    // thread's completion carries its exit code via _exit()/thread completion;
    // we hook it through a cleanup that fork::child_exited() consumes.
    child->set_cleanup([cpid] {
        // Default status if the child fell off the end without _exit(); real
        // exit codes are recorded by exit()/execve() via fork::child_exited().
        fork::child_exited(cpid, 0);
    });

    child->start();

    // Parent path: return the child's pid.  (The child, resuming on its copied
    // stack inside fork_thread(), returns 0 from this same call site.)
    return cpid;
}

extern "C"
pid_t vfork(void)
{
    // On OSv the child already shares the parent's address space (the classic
    // vfork contract of "child borrows the parent's memory until exec/_exit")
    // is actually served more faithfully than fork's copy semantics.  Map to
    // fork(); the shared-memory behavior matches vfork's documented contract.
    return fork();
}
