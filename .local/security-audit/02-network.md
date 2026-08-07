# Audit Agent 2: network stack (aee3de7e) - COMPLETE
Imported FreeBSD-9 IPv6 (frag6/nd6/nd6_rtr/nd6_nbr/icmp6/ip6_input) ported FAITHFULLY - all KAME bounds/anti-overlap/loop-caps/IP6_EXTHDR_CHECK preserved. Risk is in OSv-authored glue.
## CONFIRMED
1. HIGH (CVSS~7.4 AV:A/pre-auth): DHCPv6 parse() OOB read across mbuf chain (dhcp6.cc:262-372). p=first mbuf, blen=pkthdr.len(whole chain). Reachable: Managed-flag RA starts client (default y), on-link attacker (DHCPv6 no auth) sends >4096B REPLY, virtio MRG_RXBUF+GRO/jumbo -> chain; udp6 only makes UDP hdr contiguous, in6_cksum walks chain so passes. Reads up to ~60KB past first buffer -> panic or heap leak into installed DNS. FIX: m_pullup/m_copydata payload or clamp blen to mh_len. [= Agent1 #2 but CONFIRMED reachable]
2. MED-HIGH (CVSS~6.5): classify_ipv6_tcp OOB read (net_channel.cc:271-300). No nxt_off+sizeof(tcphdr)<=mh_len check before deref; attacker pads nxt_off via ext-headers on established flow -> OOB read on lock-free RX softirq. FIX: bound check before deref. [= Agent1 #1]
## SUSPECTED
3. LOW-MED: classify_ipv4_tcp same missing TCP-hdr bound (net_channel.cc:199-225) - PRE-EXISTING in master, not our regression. Same one-line fix.
4. LOW: tcp_net_channel_ipv6_packet trusts th_off w/o floor(5); tlen unsigned underflow -> tcp_do_segment (which re-validates, contains impact). Also ip6_lasthdr return <0 unchecked. FIX: validate th_off*4>=sizeof(tcphdr) + lasthdr>=0.
## CLEAN (faithful port): frag6 anti-overlap+limits, nd6 option overrun/maxndopt, nd6_rtr RA prefix walk, nd6_nbr NS/NA lladdr, ip6_input ext-hdr nestlimit, icmp6 per-type gating, __dns.cc (only added osv_set_dns_config_str parsing own strings; musl DNS unchanged).
## PRIORITY: #1 DHCPv6 (pre-auth, default-y, auto on AWS Managed RA) then #2 classifier.
