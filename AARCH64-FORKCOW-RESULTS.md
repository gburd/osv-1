# aarch64 fork-COW port — PostgreSQL-on-ZFS on Graviton3

Branch: `wip/aarch64-forkcow` (based on `wip/pg-zfs-bench-v24` @ ddad7f4e0).
Box: c7gd.metal (Graviton3, /dev/kvm), AL2023 arm64; built in an aarch64
fedora:39 container (native gcc 13.3.1), booted under KVM.

## Result: PASS — PG serves queries on aarch64 (ramfs AND ZFS)

    OSv v0.57.0-507-gd467e0af
    ZFS: OpenZFS 5000 initialized
    [ZFS] Pool 'pgdata' is up-to-date at version 5000   (fs on real zpool /dev/vblk1)
    ZFS: root mounted ok
    2026-... LOG:  starting PostgreSQL 18.6 on aarch64-unknown-linux-musl
    2026-... LOG:  database system is ready to accept connections

    psql select version() -> PostgreSQL 18.6 on aarch64-unknown-linux-musl (1 row)
    create table + insert 1000 rows + select count,sum -> 1000 | 500500
    checkpoint (forces ZFS sync write) + select -> 1000 rows
    pgbench -i -s 10        -> 1,000,000 tuples loaded
    pgbench -c 4 -T 30 ZFS  -> 78,577 tx, 0 failed, tps=2190  (sustained forked
                               backends + ZFS commits; checkpoint wrote 38 buffers)
    pgbench -c 4 -T 30 ramfs-> 111,841 tx, 0 failed, tps=3739

## fork-COW root causes + fixes (the main job)

OSv aarch64 uses a SPLIT TTBR MMU (TCR T0SZ=T1SZ=16): TTBR0 covers the low 48
bits, TTBR1 the high 48 bits.  Every reachable OSv VA (kernel linear map
@0x400.., ELF, app mmaps, fork arena @0x300..) has bit63=0 -> it ALL lives in
TTBR0 (page_table_root[0]); ident_pt_l4_ttbr1 maps nothing.

1. get_root_pt() ignored the per-process root (arch/aarch64/mmu.cc).  It always
   returned the arch static page_table_root[virt>>63], so a forked child's
   CLONED page tables never took effect and the fork_arena COW faulted forever.
   Fix: under CONF_fork, route the TTBR0 half through current_pt_root() (the
   child's private cloned root when a child thread runs); add kernel_pml4() and
   kernel_pt_root_phys() (page_table_root[0]) that core/mmu.cc's clone path needs.

2. No TTBR0 switch on context switch.  x86 writes CR3 in thread::switch_to();
   the aarch64 switch (cpu_schedule_next_thread + sched.S) had none.
   Fix: thread_state.ttbr0 (offset 56) set by cpu_schedule_next_thread from the
   incoming thread's address space; sched.S installs it at the switch when it
   differs from the live TTBR0 (tlbi vmalle1 + dsb ish + isb; ASID 0 shared).

3. Caller-context capture for the same-VA fork child was wrong.  The child must
   resume in fork()'s caller on the caller's exact x19-x28/x29/x30/SP; the in-C
   capture (__builtin_frame/return_address + inline stp) was inconsistent under
   -O2 (ctx.lr != real return addr; ctx.fp = fork's frame).  gdb: at fork entry
   sp=x29=0x200000200d50, x30=0x1000007b5420 (true caller PC), but the child
   ret'd to ctx.x20's value 0x200000200d80 -> instruction abort (ESR EC=0x21).
   Fix: capture the context in assembly at fork's TRUE first instruction
   (arch/aarch64/fork-entry.S; GCC/aarch64 ignores __attribute__((naked)) for C)
   and tail-call fork_impl.  arch/aarch64/fork.cc rewritten to the same-VA model
   (restore fork_resume_ctx, thread object on the identity heap), mirroring x64.

4. Fork timer-park missing on the aarch64 scheduler.  A timer IRQ during
   fork_impl walked another thread's app-stack timer off the shared per-CPU
   timer_list through the forking AS -> assert(preemptable()) abort at
   page_fault:105 (fork -> fork_impl -> interrupt -> timer_list::fired).
   Fix (core/sched.cc, aarch64+CONF_fork): park_timers(*p) in
   cpu_schedule_next_thread before the sched.S swap; unpark_timers(current) in
   destroy_current_cpu_terminating_thread at the resume point.

## build ports (re-derived; the prior run's were lost)

- SPL isa_defs.h: __aarch64__ branch; simd.h: zfs_sha512_available()=B_FALSE
  non-x86 (patch 0001).
- open_zfs_sources.mk: arch-gate ICP crypto — x86-64 asm x64-only; armv8
  sha256/sha512 + blake3 NEON + generic AES on aarch64.
- Makefile: gate the external/x64/acpica submodule guard to arch=x64; apply each
  ZFS patch with graduated fallback (git apply -> --recount -> patch --fuzz=3);
  build arch/aarch64/fork-entry.o under conf_fork.
- patches/0032: re-anchor the zfs_initialize_osv.c hunk.
- libc/arch/aarch64/atomic.h: self-contained (drop <machine/atomic.h> + BSD
  types; a_fetch_add via __atomic builtin) so the ZFS userspace libspl links.
- arch/aarch64/arm-clock.cc: raise generic-timer freq cap 1GHz->2GHz (Graviton3
  ~1.05GHz).
- apps/postgres18-musl/build.sh: -mno-outline-atomics on aarch64 (GCC13 libgcc
  lse-init.o references glibc __getauxval, absent in musl -> PG configure can't
  detect atomics).

Build: ./scripts/build -j64 arch=aarch64 conf_fork=1 conf_zfs=openzfs fs=ramfs
image=open_zfs,zfs,zfs-tools,postgres18-musl (native aarch64 fedora:39 container).

## Known follow-ups (not blockers for the serve gate)

- fs=zfs ROOTED image build (README flow) needs a nested zfs_builder qemu guest
  with KVM in the build container; the runtime `zpool create` path above proves
  PG-on-ZFS without it.
- >=4GB RAM still hangs (separate setup_temporary_phys_map coverage bug); ran <=3G.
- apps submodule commit (b38b99c, -mno-outline-atomics) must be pushed to
  gburd/osv-apps@wip/postgres18-musl-demo.
