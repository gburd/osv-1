/*
 * Copyright (C) 2014 Cloudius Systems, Ltd.
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

#include <osv/net_channel.hh>
#include <osv/poll.h>
#include <bsd/sys/sys/mbuf.h>
#include <bsd/sys/net/ethernet.h>
#include <bsd/sys/netinet/ip.h>
#include <bsd/sys/netinet/ip.h>
#include <bsd/sys/netinet/tcp.h>
#include <bsd/sys/net/ethernet.h>
#include <bsd/sys/net/netisr.h>

#include <osv/net_trace.hh>
#include <osv/rxprof.hh>
#include <osv/sched.hh>
#include <stdio.h>
#include <stdlib.h>
#include <algorithm>

// ===================== RXPROF (RX hop-by-hop profiler) =====================
namespace rxprof {
    bool enabled = false;
    std::atomic<u64> drain_ns_hist[NB];
    std::atomic<u64> gap_ns_hist[NB];
    std::atomic<u64> h1q_ns_hist[NB];
    std::atomic<u64> h2_ns_hist[NB];
    std::atomic<u64> batch_hist[64];
    std::atomic<u64> passes{0};
    std::atomic<u64> packets{0};
    std::atomic<u64> drain_ns_sum{0};
    std::atomic<u64> gap_ns_sum{0};
    std::atomic<u64> h1q_ns_sum{0};
    std::atomic<u64> h2_ns_sum{0};
    std::atomic<u64> h2_ns_max{0};

    static void dump_hist(const char* name, std::atomic<u64>* h, int n) {
        printf("RXPROF %s:", name);
        for (int i = 0; i < n; i++) {
            u64 c = h[i].load();
            if (c) printf(" b%d(<%luns)=%lu", i, (unsigned long)(1ull << i), (unsigned long)c);
        }
        printf("\n");
    }
    void dump() {
        u64 np = passes.load(), pk = packets.load();
        printf("RXPROF passes=%lu packets=%lu pkts/pass=%lu "
               "drain_avg_ns=%lu gap_avg_ns=%lu h1q_avg_ns=%lu h2_avg_ns=%lu h2_max_ns=%lu\n",
               (unsigned long)np, (unsigned long)pk,
               (unsigned long)(np ? pk / np : 0),
               (unsigned long)(np ? drain_ns_sum.load() / np : 0),
               (unsigned long)(np ? gap_ns_sum.load() / np : 0),
               (unsigned long)(pk ? h1q_ns_sum.load() / pk : 0),
               (unsigned long)(pk ? h2_ns_sum.load() / pk : 0),
               (unsigned long)h2_ns_max.load());
        printf("RXPROF batch_per_pass:");
        for (int i = 0; i < 64; i++) {
            u64 c = batch_hist[i].load();
            if (c) printf(" n%d=%lu", i, (unsigned long)c);
        }
        printf("\n");
        dump_hist("drain_ns(log2)", drain_ns_hist, NB);
        dump_hist("gap_ns(log2)", gap_ns_hist, NB);
        dump_hist("h1q_ns(log2)", h1q_ns_hist, NB);
        dump_hist("h2_ns(log2)", h2_ns_hist, NB);
    }
    void arm_from_env() {
        const char* e = getenv("OSV_RXPROF");
        if (e && e[0] == '1') {
            enabled = true;
            auto dumper = sched::thread::make([] {
                for (;;) {
                    sched::thread::sleep(std::chrono::seconds(5));
                    rxprof::dump();
                }
            }, sched::thread::attr().name("rxprof").detached());
            dumper->start();
            printf("RXPROF ARMED (dumping every 5s)\n");
        }
    }
}

#include <osv/kernel_config_lazy_stack.h>
#include <osv/kernel_config_lazy_stack_invariant.h>
#include <osv/kernel_config_core_epoll.h>
#include <osv/fork_arena.hh>

#if CONF_fork
// The poller/epoll/classifier structures below are populated by APPLICATION
// threads (a PG backend adding its connection socket to epoll) but WALKED by
// the virtio-net RX path (net_channel::wake_pollers, classifier::post_packet)
// running in a kernel thread / IRQ context in AS0 with preemption disabled.
// If their RCU vectors / hashtable nodes lived in the COW fork arena, those
// arena VAs are not mapped in the RX thread's address space -> the RX walk
// takes a page fault while !preemptable() -> "Assertion failed:
// sched::preemptable() (page_fault)".  Force every such allocation onto the
// shared identity kernel heap so the RX path sees the same nodes in every AS,
// the same rule already applied to struct file, ramfs nodes and the signal
// waiters list (see fork_arena.hh).
#define NET_SHARED_KH fork_arena::kernel_heap_scope _net_kh
#else
#define NET_SHARED_KH do {} while (0)
#endif

void net_channel::process_queue()
{
    mbuf* m;
    while (_queue.pop(m)) {
        _process_packet(m);
    }
}

void net_channel::wake_pollers()
{
#if CONF_lazy_stack_invariant
    assert(!sched::thread::current()->is_app());
#endif
    WITH_LOCK(osv::rcu_read_lock) {
        auto pl = _pollers.read();
        if (pl) {
            for (pollreq* pr : *pl) {
                // net_channel is self synchronizing
                pr->_awake.store(true, std::memory_order_relaxed);
                pr->_poll_thread.wake_from_kernel_or_with_irq_disabled();
            }
        }
#if CONF_core_epoll
        // can't call epoll_wake from rcu, so copy the data
        if (!_epollers.empty()) {
            _epollers.reader_for_each([&] (const epoll_ptr& ep) {
                epoll_wake_in_rcu(ep);
            });
        }
#endif
    }
}

void net_channel::add_poller(pollreq& pr)
{
    WITH_LOCK(_pollers_mutex) {
        NET_SHARED_KH;
        auto old = _pollers.read_by_owner();
        std::unique_ptr<std::vector<pollreq*>> neww{new std::vector<pollreq*>};
        if (old) {
            *neww = *old;
        }
        neww->push_back(&pr);
        _pollers.assign(neww.release());
        osv::rcu_dispose(old);
    }
}

void net_channel::del_poller(pollreq& pr)
{
    WITH_LOCK(_pollers_mutex) {
        NET_SHARED_KH;
        auto old = _pollers.read_by_owner();
        std::unique_ptr<std::vector<pollreq*>> neww{new std::vector<pollreq*>};
        if (old) {
            *neww = *old;
        }
        neww->erase(std::remove(neww->begin(), neww->end(), &pr), neww->end());
        _pollers.assign(neww.release());
        osv::rcu_dispose(old);
    }
}

void net_channel::add_epoll(const epoll_ptr& ep)
{
#if CONF_core_epoll
    WITH_LOCK(_pollers_mutex) {
        NET_SHARED_KH;
        if (!_epollers.owner_find(ep)) {
            _epollers.insert(ep);
        }
    }
#endif
}

void net_channel::del_epoll(const epoll_ptr& ep)
{
#if CONF_core_epoll
    WITH_LOCK(_pollers_mutex) {
        NET_SHARED_KH;
        auto i = _epollers.owner_find(ep);
        if (i) {
            _epollers.erase(i);
        }
    }
#endif
}

classifier::classifier()
{
}

void classifier::add(ipv4_tcp_conn_id id, net_channel* channel)
{
    WITH_LOCK(_mtx) {
        NET_SHARED_KH;
        _ipv4_tcp_channels.emplace(id, channel);
    }
}

void classifier::remove(ipv4_tcp_conn_id id)
{
    WITH_LOCK(_mtx) {
        auto i = _ipv4_tcp_channels.owner_find(id,
                std::hash<ipv4_tcp_conn_id>(), key_item_compare());
        assert(i);
        _ipv4_tcp_channels.erase(i);
    }
}

bool classifier::post_packet(mbuf* m)
{
#if CONF_lazy_stack_invariant
    assert(!sched::thread::current()->is_app());
#endif
    WITH_LOCK(osv::rcu_read_lock) {
        if (auto nc = classify_ipv4_tcp(m)) {
            log_packet_in(m, NETISR_ETHER);
            if (!nc->push(m)) {
                return false;
            }
            // FIXME: find a way to batch wakes
            nc->wake();
            return true;
        }
    }
    return false;
}

// RXPROF variant: pass_start is the ns timestamp at the start of the current
// receiver drain pass. pre is stamped just before classify+push+wake so the
// H1 per-packet queueing delay (pass_start->pre) and the H2 post_packet cost
// (pre->post) are attributed. Returns fast_path as post_packet() does.
bool classifier::post_packet(mbuf* m, u64 pass_start)
{
    u64 pre = rxprof::now_ns();
    bool fast = post_packet(m);
    u64 post = rxprof::now_ns();
    rxprof::record_packet(pass_start, pre, post);
    return fast;
}

// must be called with rcu lock held
net_channel* classifier::classify_ipv4_tcp(mbuf* m)
{
    caddr_t h = m->m_hdr.mh_data;
    if (unsigned(m->m_hdr.mh_len) < ETHER_HDR_LEN + sizeof(ip)) {
        return nullptr;
    }
    auto ether_hdr = reinterpret_cast<ether_header*>(h);
    if (ntohs(ether_hdr->ether_type) != ETHERTYPE_IP) {
        return nullptr;
    }
    h += ETHER_HDR_LEN;
    auto ip_hdr = reinterpret_cast<ip*>(h);
    unsigned ip_size = ip_hdr->ip_hl << 2;
    if (ip_size < sizeof(ip)) {
        return nullptr;
    }
    if (ip_hdr->ip_p != IPPROTO_TCP) {
        return nullptr;
    }
    if (ntohs(ip_hdr->ip_off) & ~IP_DF) {
        return nullptr;
    }
    auto src_addr = ip_hdr->ip_src;
    auto dst_addr = ip_hdr->ip_dst;
    h += ip_size;
    auto tcp_hdr = reinterpret_cast<tcphdr*>(h);
    if (tcp_hdr->th_flags & (TH_SYN | TH_FIN | TH_RST)) {
	    return nullptr;
    }
    auto src_port = ntohs(tcp_hdr->th_sport);
    auto dst_port = ntohs(tcp_hdr->th_dport);
    auto id = ipv4_tcp_conn_id{src_addr, dst_addr, src_port, dst_port};
    auto i = _ipv4_tcp_channels.reader_find(id,
            std::hash<ipv4_tcp_conn_id>(), key_item_compare());
    if (!i) {
        return nullptr;
    }
    return i->chan;
}
