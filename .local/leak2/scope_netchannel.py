p="bsd/sys/netinet/tcp_input.cc"
s=open(p).read()
if "fork_kernel_heap_push" in s:
    print("already scoped"); raise SystemExit
# add extern decls before tcp_setup_net_channel
anchor="void\ntcp_setup_net_channel(tcpcb* tp, struct ifnet* intf)\n{\n"
assert anchor in s, "tcp_setup_net_channel anchor"
decl=('/* LEAK #2 REAL FIX: the net_channel (and its embedded 256-slot RX ring) is\n'
      ' * written by the AS0 virtio-net RX classifier (post_packet -> _queue.push)\n'
      ' * in a non-preemptable IRQ context, so it must live on the shared identity\n'
      ' * heap -- coherent in every address space -- never the COW fork arena or the\n'
      ' * per-AS fork overflow region (which is mapped only in the allocating AS; a\n'
      ' * cross-AS RX write there faults). Bracket the allocation so it lands on the\n'
      ' * identity heap, like the other cross-AS net objects. */\n'
      'extern "C" void fork_kernel_heap_push(void);\n'
      'extern "C" void fork_kernel_heap_pop(void);\n\n')
s=s.replace(anchor, decl+anchor, 1)
old="\tauto nc = aligned_new<net_channel>([=] (mbuf *m) { tcp_net_channel_packet(tp, m); });"
new=("\tfork_kernel_heap_push();\n"
     "\tauto nc = aligned_new<net_channel>([=] (mbuf *m) { tcp_net_channel_packet(tp, m); });\n"
     "\tfork_kernel_heap_pop();")
assert old in s, "aligned_new net_channel line"
s=s.replace(old,new,1)
open(p,"w").write(s)
print("net_channel scoped in tcp_input.cc")
