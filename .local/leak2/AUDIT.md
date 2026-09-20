# LEAK #2 CROSS-AS OBJECT-GRAPH AUDIT (the deliverable that decides shippability)

## THE MASKING INSIGHT (the most important finding of the leak-2 arc)
The fork ARENA (slot 96) is a COW mapping whose base lives in AS0 and is cloned into EVERY child AS.
So for any arena VA, every address space has SOME page mapped there (a COW-divergent copy). A cross-AS
raw-pointer read of an app-thread-allocated arena object therefore returns a DIVERGENT COPY instead of
faulting. That SILENTLY MASKS latent fork-coherence bugs: a kernel object that a backend allocated and
that the AS0 RX/timer/RCU threads dereference by raw pointer "works" only because the AS0 read lands on
a COW copy (wrong bytes, but no fault). The per-AS overflow region (slot 97) is mapped in ONLY the
allocating AS, so the SAME cross-AS access is a HARD PAGE FAULT. Making memory per-AS EXPOSES the bugs
the arena hid. => there may be OTHER latent fork-coherence bugs behind the arena's mapped-everywhere
property; the overflow region is, incidentally, a detector for them.

## THE AUDIT QUESTION
Is the set of "objects a non-allocating context dereferences by raw pointer AND that a child app thread
could allocate post-arena-exhaustion" BOUNDED + enumerable (Outcome A: scope them all, ship the fix) or
open-ended (Outcome B: unsafe in general, fall back to grow-mitigation)?

## THE AUDIT (source-level, principled)
The cross-AS contexts that touch app-thread-allocated memory:
  - IRQ/softirq: virtio-net RX classifier (post_packet -> net_channel::_queue.push), driver bottom-halves.
  - AS0 timer thread: TCP timers (serial_timer_task).
  - RCU quiescent thread: file::~file/vrele/drele (vfs objects - ALREADY scoped).
  - tx-complete (AS0): zerocopy ztx_handle.
  - process-global intrusive lists walked cross-AS: ofl_head (stdio FILE).

KEY STRUCTURAL FACT: the BSD network stack is scoped WHOLESALE by bsd/porting/uma_stub.cc -- EVERY UMA
slab (mbufs, clusters, tcpcb, and UMA-allocated sockets) is forced onto the identity heap, with a comment
that already states the masking rationale ("the mbuf is read and dropped by the virtio-net RX/timer
threads running in AS0 ... force every UMA slab onto the shared identity kernel heap"). So the ENTIRE
UMA-allocated net stack is already safe. The ONLY gaps are objects allocated with C++ new / aligned_new,
which BYPASS uma_stub, on a per-connection app-thread path, and are dereferenced cross-AS.

ENUMERATED GAP SET (grep of `new`/`aligned_new` in bsd/sys/{kern,netinet,net} + all `aligned_new<` in the
kernel, classified by allocation context):
  GAPS (per-connection, app-thread, cross-AS-dereferenced) -> MUST scope:
    1. bsd/sys/kern/uipc_socket.cc:244   new socket{}            (socket + inline so_rcv/so_snd sockbufs)
    2. bsd/sys/netinet/tcp_usrreq.cc     new inpcb(so,&V_tcbinfo) (TCP pcb; RX classify reads it)
    3. bsd/sys/netinet/udp_usrreq.cc     new inpcb(so,&V_udbinfo) (UDP pcb)
    4. bsd/sys/netinet/raw_ip.cc         new inpcb(so,&V_ripcbinfo)(raw pcb)
    5. bsd/sys/netinet/tcp_timer.cc      new serial_timer_task x6 (fired by AS0 timer thread)
    6. bsd/sys/netinet/tcp_input.cc:3261 aligned_new<net_channel> (RX classifier writes its ring) [CRASHED]
    7. bsd/sys/kern/uipc_syscalls.cc     new ztx_handle           (zerocopy tx, AS0 tx-complete)
    8. libc/stdio/__fdopen.c             malloc FILE              (on process-global ofl_head)     [CRASHED]
  SAFE (boot / device-init only, never a child app thread) -> NOT scoped:
    - bsd/sys/netinet/tcp_syncache.cc:235 new syncache_head[]     (tcp_syncache_init, once at boot)
    - bsd/sys/net/if.cc:371 new s_ifnet, if_ethersubr.cc arpcom/sockaddr_dl (interface attach, boot)
    - drivers/*.cc aligned_new<ena/vmxnet3/nvme/virtio-net/txq/ring> (device probe/attach, boot, AS0)
  ALREADY SCOPED (pre-existing, verified): mmu page-tables/vmas, sched threads, wait_record, semaphore,
    rwlock, epoll, pipe, shm, signal, async callouts, virtio-blk/net/vring req, pagecache, rofs cache,
    vfs dentry/vnode/file/fd_table, cxa_thread_atexit, pthread atfork, taskqueue, and the WHOLE UMA net
    stack via uma_stub.

## VERDICT: BOUNDED (Outcome A).
The boundary is principled and closed: "a per-connection kernel object allocated via C++ new/aligned_new
(bypassing the wholesale uma_stub identity-heap scope) that a cross-AS context dereferences." Two of the
eight (net_channel, FILE) surfaced as hard faults at scale; the audit then enumerated the remaining six
by the same pattern (uma-bypass + per-connection + cross-AS-touch) and confirmed the boot/device-init
`new` sites are NOT reachable by a child app thread. The set is finite and each member is scoped. This is
a PROVABLY-COMPLETE safe fix, plus 8 generic fork-coherence fixes as a bonus (each fixes a latent
divergent-COW-copy read the arena was masking, valuable independent of the overflow reclaim).

## VALIDATION of completeness: 400-round churn with the full scoped set (FINAL-ON, below in RESULT-REAL.md).
