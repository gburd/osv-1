# A bug CLASS, not a bug: process-global containers allocated lazily under fork

2026-09-08. Third confirmed instance found today. This is the unifying rule and it should drive
an audit rather than one-off fixes.

## The invariant

Under `conf_fork=1`, allocations made by a forked child land in that child's **COW fork arena**.
So any container that is (a) **process-global** but (b) **populated lazily by whichever address
space touches it first** ends up with nodes that are garbage in every other AS. The first free
from a different AS - a map rehash, or teardown in AS0 - trips
`Assertion failed: h->magic == chunk_magic (core/fork_arena.cc recover:257)` and aborts the VM.

The rule, already stated in-tree at `core/epoll.cc:63-81`: force such allocations onto the
identity kernel heap with `fork_arena::kernel_heap_scope`, so all address spaces share ONE
coherent set of nodes, freeable from AS0. That comment explicitly calls it "the same rule as
struct file, f_epolls and thread objects", and `KH()` is a no-op in a non-fork build.

## Confirmed instances

1. **`struct file`, `f_epolls`, thread objects** - earliest, already handled.
2. **`core/epoll.cc`** `map` (registered fds) and `_activity` (ready fds) - handled, with the
   documenting comment above.
3. **`elf::program`'s `_files` object cache** (today, agents 541f3862/0261152a) - a *variant*: the
   cache is global while PT_LOAD mappings are per-AS, so a cache hit returned a `_base` mapped in
   no AS. Fixed on `fix/elf-object-cache-address-space`.
4. **`fs/rofs/rofs_cache.cc` `global_file_cache`** (today, agent 3c967111) - `static
   std::unordered_map<rofs_cache_key, file_cache*>` at `:152`, with **zero** `kernel_heap_scope`
   in the file. `cache_read` at `:273` is the single entry point, and its own comment at `:270`
   says it is "assumed to be called by one thread" per file, an assumption that was true pre-fork
   and that fork breaks. Fixed with one `kernel_heap_scope` at the top of `cache_read`
   (commit `5af7da0be`, 33 lines, no-op without fork).

    Assertion failed: h->magic == chunk_magic (core/fork_arena.cc: recover: 257)
    fork_arena::free(void*)+120
    std::_Hashtable<rofs::rofs_cache_key, ...>::_M_rehash+168
    rofs::cache_read(rofs_inode*, device*, rofs_super_block*, uio*)+28
    vfs_file::read(uio*, int)+104  ... __uflow -> fgets -> getnameinfo+336

**Trigger under load:** every PostgreSQL backend calls `getnameinfo()` to resolve the client
address, which `fgets()` files off the rofs root, so the shared cache is grown and rehashed from
dozens of address spaces concurrently. That is why it needed real TPROC-C load at VU32 to appear
and never showed up in any microbenchmark.

## Why this framing matters
"Here is a random assert" invites a narrow patch. "This is the **third** instance of a rule
already documented in `core/epoll.cc`, and the rule was never applied here" invites an audit and
is far more likely to be accepted upstream. Instructed the agent to cite the epoll precedent in
the #1456 report.

## Audit requested (scoped, deliberately NOT done mid-sweep)
Asked for a **list of candidates only**: process-global maps/caches under `fs/`, `core/`, `libc/`
that allocate on first use from arbitrary threads. No fixes. That list is plausibly worth more
than any single fix, and it is exactly the generic, upstreamable hardening this program exists to
produce. Suspects to check when the list is compiled: other vfs/fs caches, DNS/resolver state,
locale state, and anything else reached from `getnameinfo`-like library paths.

## Not master-eligible
Needs `conf_fork=1`; `upstream/master` has no fork at all. Goes on **#1456** with the elf fix.

## AUDIT LIST delivered (agent 3c967111) - and the top candidate is a LIVE risk

Process-global containers populated lazily from arbitrary threads, with their
`kernel_heap_scope` count:

| file | container(s) | KH scopes |
|------|--------------|-----------|
| `core/pagecache.cc:361-364` | `arc_read_cache`, `read_cache`, `write_cache` | **0** |
| `core/osv_execve.cc:22` | `exited_threads` | **0** |
| `core/trace.cc:529` | `symbol_functions` | **0** |
| `libc/shm.cc:57-62` | `posix_shm_objects`, `shmkeys`, `shmmap` | 1 (partial: 3 maps, 1 scope) |
| `libc/sem.cc:129` | `named_semaphores` | 1 (verify it covers map nodes) |

**I escalated the top entry after checking reachability.** The agent flagged `pagecache.cc` as
highest suspicion but noted the ARC bridge is unreachable under `conf_zfs=openzfs` (patch 0005
removes `ZFS_ID`, so `IS_ZFS()` is false). That is true of **`arc_read_cache`** only. The file's own
comment at `core/pagecache.cc:31` says:

    ROFS and the OpenZFS 2.4.3 port route reads through read_cache.

and `read_cache` is used unconditionally at `:413`, `:415`, `:470`. So **`read_cache` IS reachable
on exactly the configuration we benchmark** (OpenZFS data disk + ROFS root), it is a process-global
`std::unordered_map<hashkey, cached_page*>`, and the file contains **zero** `kernel_heap_scope`.

That makes it the same shape as the rofs cache bug just fixed, in a hotter path: every mapped file
read. It is the **fourth instance** of the documented rule and the highest-priority remaining
candidate. Not fixed yet - next fork-hardening task.

Also worth noting `libc/shm.cc` has **three** maps and only **one** scope, which is exactly the
partial-application pattern that leaves a latent instance behind.
