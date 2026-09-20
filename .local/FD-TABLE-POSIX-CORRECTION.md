# #1455: implementing per-process fd tables because POSIX requires it, not because an app demands it

2026-09-10. User correction, accepted, and it corrects a standard I had applied wrongly.

## The wrong standard I used
An agent answered `nyh`'s question on #1455 by conceding the shared-fd-table gap and arguing that no
application both works today and needs POSIX fd semantics. I endorsed that and converted the PR to
draft on those grounds.

**That was the wrong test.** OSv's goal is to be a **POSIX / Linux-ABI-compatible unikernel**, so a
feature implements the POSIX rule **first** and deviates only where Linux-ABI compatibility genuinely
conflicts. "I cannot name an application that needs it" is not an argument for omitting a POSIX
guarantee - it is at best an argument about priority. **nyh was right.**

## The POSIX rule to implement
After `fork()` the child gets a **copy** of the descriptor table:
- each fd number refers to the **same open file description**, so offset, status flags and locks are
  **shared** (a `read()` in the child advances the parent's offset);
- but table **entries are independent**: `close()` in the child does not close the parent's fd,
  `dup2()`/`fcntl(F_SETFD)`/`O_CLOEXEC` changes are private, and the child may reuse a number the
  parent still holds;
- **`FD_CLOEXEC` is per-descriptor** (private), while **`O_NONBLOCK` and the offset are per-file-
  description** (shared).
**The table is copied; the open file descriptions are shared and refcounted.**

## The strongest argument for doing it properly: the workarounds already exist
`fs/vfs/kern_descrip.cc:44` is a single global `rcu_ptr<file> gfdt[FDMAX]`, commented "in OSv we have a
single process so file descriptors are maintained globally", with **31 direct references** in that file.

But `libc/process/fork.cc` **already maintains per-address-space maps** `g_inherited_fds` and
`g_child_opened_fds` (~`:170-210`), feeding **three special-case hooks**:

    fork_child_close_inherited_fd(int fd)            kern_descrip.cc:113
    fork_owner_close_inherited_fd(int fd, file *fp)   kern_descrip.cc:118
    fork_child_owns_fd(int fd)                        kern_descrip.cc:129

So the design has **built half a per-process fd table sideways, keyed by address space** - which is
exactly the key a real table would use. And `fdclose()`'s own comments admit the cost: a child closing
an fd it did not inherit is "holding only a numeric handle onto one of the PARENT's fds", and nulling
the slot "would tear that fd out from under the parent -- exactly what corrupted PostgreSQL's postmaster
when a backend's `ClosePostmasterPorts()` closed the postmaster-owned death-watch pipe fd."

**So `close()` in a child is currently a silent no-op in some cases**: a POSIX violation with visible
consequences (a child cannot free a descriptor number; CLOEXEC-style cleanup does not work).

**Instruction given: the fix should DELETE that machinery, not extend it.** If it does not simplify
`fdclose()` and remove the three hooks, that is a signal the shape is wrong, and the agent is told to
stop and explain rather than proceed.

## Six tests demanded, each a distinct POSIX rule, each failing before and passing after
1. `close()` in the child does not close the parent's fd.
2. **The offset IS shared** - the half that must NOT change, and the one a naive "duplicate everything"
   fix breaks.
3. Independent numbering: child closes and reopens the same number while the parent still holds its own
   there, referring to a different file.
4. `FD_CLOEXEC` is private to the child.
5. Refcount lifetime: parent closes while the child holds one, child still reads; child exits and the
   description is genuinely released (observable via pipe/socket EOF).
6. The **PostgreSQL death-watch regression** the hooks were papering over.

Plus `conf_fork=0` must build clean (a previous change broke exactly that by guarding a base
declaration but not its override), and the fd-path cost must be **measured** - a per-syscall map lookup
would be a real regression even if correct.

## Disposition
Stays **DRAFT** unless the full set passes, and the agent must say which of the six pass. Partial
compliance with an explicit list of what does not yet hold is acceptable and far better than an
overclaim; claiming full POSIX compliance without the evidence is not.

The PR comment must address `nyh` directly: the gap he identified is **implemented rather than argued
away**, the POSIX rule was the right standard, and "no application needs it" was not. If the hooks are
gone, say so - "this change deletes the three fork-specific `close()` special cases" is the sentence a
reviewer most wants to read.

## MY SURVEY DESCRIBED THE WRONG TREE (2026-09-10)

Agent d532c5b7 caught this before writing code. Verified:

    #1455 head (dce0d32fd59a)  gfdt=14  forkhooks=0  fork.cc=230 lines  clone_address_space=0
    my local HEAD              gfdt=31  forkhooks=4  full COW/fork-arena machinery

**Everything I described - the three hooks, `g_inherited_fds`, `g_child_opened_fds`,
`fork_snapshot_open_fds`, `release_inherited_fds`, `mmu::address_space` - lives on the LATER branch I
had checked out (`wip/pg-rx-directwake`, ~2600 commits of subsequent fork work), not on #1455's head.**
My line numbers matched exactly because I read my own working tree and assumed it was the PR.

Third instance this session of the same error: **attributing integration-branch content to a PR head.**
The guard I keep failing to apply is one command: **`git show <pr-head>:<file>` before describing a
PR's code, never `sed` on the working tree.**

### Consequences
- **The "deletes the three fork-specific `close()` special cases" headline is FALSE on this base**, and I
  told the agent to drop it entirely rather than carry it over. I would rather have no headline than one
  a reviewer disproves by reading the diff. That sentence was my invention, and it was wrong.
- **Option (A), base on #1455's head, is still correct** for three reasons: it answers the question nyh
  actually asked about the PR he is reviewing; it stays reviewable in isolation, which is why #1455
  exists separately; and it is the **right layering** - a per-process fd table is a POSIX property of
  `fork()` itself, not of COW address spaces. Needing address spaces to express it would be a sign the
  design leaned on an accident of the later branch.

### The design answer for a base with no address spaces
Key the table by **the thread**, since that is what fork produces there. A descriptor-table object, a
pointer in `sched::thread`, children get a **clone** with a reference on each open file description, and
`pthread_create` threads **share** their creator's table (POSIX: threads share descriptors, processes do
not). **The crux is how a fork child is distinguished from a new thread on that base** - if it cannot be,
that is a finding to report, not to work around.

### Escape hatch I authorised
If the change genuinely cannot be done well on #1455's head - e.g. no reliable
fork-child-versus-new-thread signal - **stop and say so**. The honest outcome is a comment on #1455
explaining that the fd table requires the later fork infrastructure, which becomes an argument for
restructuring how these PRs are stacked. **What I will not accept is a per-process table that quietly
breaks shared offsets to make the base cooperate.** Tests 2 (offset IS shared) and 5 (refcount lifetime)
are the guards against exactly that, because on a base with a shared address space it is easy to build a
table that is either fully shared or fully independent, and the correct answer is neither.
