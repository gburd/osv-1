#!/usr/bin/env python3
# LEAK #2 REAL FIX, cross-AS scoping (Outcome A: the BOUNDED audited set).
#
# THE AUDIT (masking insight): the fork ARENA is COW-mapped in EVERY address
# space, so a cross-AS raw-pointer read of an app-thread-allocated object returns
# a DIVERGENT COW copy instead of faulting -- it MASKS latent fork-coherence
# bugs. The per-AS overflow region (mapped in ONE AS) turns those into hard
# faults, which EXPOSED them. The BSD net stack is already scoped wholesale via
# bsd/porting/uma_stub.cc (every UMA slab -> identity heap, because the AS0
# virtio RX/timer threads dereference mbufs/tcpcb/socket cross-AS). The ONLY gaps
# are per-connection kernel objects allocated with C++ new / aligned_new, which
# BYPASS uma_stub, on an app thread (so they can land in the arena/overflow), and
# are then dereferenced cross-AS by the AS0 RX classifier / timer / tx-complete:
#     socket, inpcb (tcp/udp/raw), serial_timer_task (x6), net_channel, ztx_handle
# plus the libc FILE object (on the process-global ofl_head list, walked by
# fflush(NULL)/exit cross-AS). net_channel + FILE are patched separately; this
# script closes the rest. Boot/device-init new (syncache hashbase, s_ifnet,
# arpcom, driver aligned_new) are NOT reached by a child app thread -> safe, not
# scoped. This set is BOUNDED and enumerable: the boundary is "per-connection
# kernel object via C++ new/aligned_new (uma-bypass), cross-AS-dereferenced."
# Idempotent.
DECL_C = ('/* LEAK #2 REAL FIX: this per-connection kernel object is dereferenced\n'
          ' * cross-AS by the AS0 virtio-net RX classifier / TCP timer / tx-complete\n'
          ' * thread, so it must live on the shared identity heap (coherent in every\n'
          ' * address space), never the COW fork arena or the per-AS fork overflow\n'
          ' * region.  It is allocated with C++ new (bypassing the wholesale UMA\n'
          ' * identity-heap scope in bsd/porting/uma_stub.cc), so scope it here. */\n'
          'extern "C" void fork_kernel_heap_push(void);\n'
          'extern "C" void fork_kernel_heap_pop(void);\n\n')
DECL_ANCHOR = "#include <bsd/porting/netport.h>\n"

def patch(path, edits):
    with open(path, encoding="utf-8") as f:
        s = f.read()
    if "fork_kernel_heap_push" in s:
        print(f"{path}: already scoped"); return
    assert DECL_ANCHOR in s, f"{path}: netport.h anchor missing"
    s = s.replace(DECL_ANCHOR, DECL_ANCHOR + DECL_C, 1)
    for old, new in edits:
        assert old in s, f"{path}: edit anchor missing: {old[:60]!r}"
        s = s.replace(old, new, 1)
    with open(path, "w") as f:
        f.write(s)
    print(f"{path}: scoped")

patch("bsd/sys/kern/uipc_socket.cc",
      [("\tso = new socket{};",
        "\tfork_kernel_heap_push();\n\tso = new socket{};\n\tfork_kernel_heap_pop();")])

patch("bsd/sys/netinet/tcp_usrreq.cc",
      [("\tinp = new inpcb(so, &V_tcbinfo);",
        "\tfork_kernel_heap_push();\n\tinp = new inpcb(so, &V_tcbinfo);\n\tfork_kernel_heap_pop();")])

patch("bsd/sys/netinet/udp_usrreq.cc",
      [("\tinp = new inpcb(so, &V_udbinfo);",
        "\tfork_kernel_heap_push();\n\tinp = new inpcb(so, &V_udbinfo);\n\tfork_kernel_heap_pop();")])

patch("bsd/sys/netinet/raw_ip.cc",
      [("\tinp = new inpcb(so, &V_ripcbinfo);",
        "\tfork_kernel_heap_push();\n\tinp = new inpcb(so, &V_ripcbinfo);\n\tfork_kernel_heap_pop();")])

patch("bsd/sys/netinet/tcp_timer.cc",
      [("\tusing namespace std::placeholders;\n\n\ttimers->timers[tcp_timer_type::TT_DELACK] =",
        "\tusing namespace std::placeholders;\n"
        "\t/* LEAK #2 REAL FIX: the 6 serial_timer_task nodes are fired by the AS0\n"
        "\t * timer thread; keep them on the identity heap (see the decl comment). */\n"
        "\tfork_kernel_heap_push();\n\n\ttimers->timers[tcp_timer_type::TT_DELACK] ="),
       ("\t\tnew serial_timer_task(inp->inp_lock, std::bind(tcp_timer_tso_flush, _1, tp));\n}",
        "\t\tnew serial_timer_task(inp->inp_lock, std::bind(tcp_timer_tso_flush, _1, tp));\n"
        "\tfork_kernel_heap_pop();\n}")])

patch("bsd/sys/kern/uipc_syscalls.cc",
      [("\tstruct ztx_handle *zh = new ztx_handle();",
        "\tfork_kernel_heap_push();\n\tstruct ztx_handle *zh = new ztx_handle();\n\tfork_kernel_heap_pop();")])

print("CROSS-AS SCOPING DONE")
