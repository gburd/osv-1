# Audit Agent 1: our new code (3404e486) - COMPLETE
## CONFIRMED
1. HIGH: OOB read in classify_ipv6_tcp (core/net_channel.cc:271-296). ip6_lasthdr_nofrag only guarantees base ip6 hdr fits; no check nxt_off+sizeof(tcphdr)<=mh_len before deref tcp_hdr (reads th_flags@+13, ports@0-3). Network-reachable via any IPv6 frame; crafted 54-byte or chained-mbuf frame -> OOB/fault on RX interrupt path. IPv4 sibling has same historical gap (pre-existing in master). FIX: require nxt_off+sizeof(tcphdr)<=mh_len (+ pullup for chains).
## SUSPECTED / lower
2. MED(susp): dhcp6.cc parse() assumes payload contiguous in first mbuf; blen from pkthdr.len (whole chain) but p from first mbuf. udp6 IP6_EXTHDR_CHECK only makes UDP hdr contiguous. Chained small UDP -> OOB read. Not reachable via default virtio single-buffer RX. FIX: m_pullup or clamp blen to mh_len-payload_off.
3. LOW/MED: dhcp6 _dns/_server_duid grow unbounded - process_packet calls parse() even when BOUND; on-link attacker sniffs xid, floods REPLYs -> mem DoS. FIX: ignore when not SOLICITING|REQUESTING, cap/clear _dns.
4. MED(susp): mremap in-place-grow TOCTOU (core/mmu.cc:1489-1503) - tail_free snapshot under read lock released, then mmap_fixed evacuates; concurrent mmap into tail gets clobbered. FIX: hold vma_list_mutex across check+fixed-map.
5. MED(susp): mremap move of MAP_PRIVATE file mapping drops COW-dirty pages (data loss, mmu.cc:1519-1531). FIX: copy contents like anon path.
6. LOW: mremap align_up(old_size) integer overflow near SIZE_MAX. FIX: reject overflowing sizes.
7. LOW: signalfd set_mask races watches() on _mask (benign mis-route). FIX: guard _mask with _mutex.
## CLEAN (within scope): ext4 read-ahead ring (bounded, gen-counter prevents UAF), libaio teardown, virtio-net v6 offload (RX bounds reused), virtio-balloon, splice, signalfd/inotify read bounds, sigfills, fs-syscalls (TOCTOUs documented), close-range, setrlimit, membarrier, numa-alloc.
## TOP: fix #1 first (closest to remotely-triggerable memory-safety defect). No confirmed remote RCE or kernel-write corruption in added code.
