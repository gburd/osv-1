/*
 * RXPROF -- hop-by-hop RX round-trip latency profiler (bench instrumentation).
 *
 * Env OSV_RXPROF=1 arms it. Attributes the per-request round-trip latency to
 * the hops that live inside the single virtio-net receiver drain path:
 *
 *   H1 (receiver serial queueing): how many packets one used_ring_not_empty
 *       wakeup drains (batch), the wall time to drain that pass (drain_ns),
 *       and the idle gap between passes (gap_ns).  If batch grows and gap
 *       stays large, the single receiver is NOT cpu-saturated but packets
 *       still queue behind earlier packets in the same drain pass -- a
 *       serial-drain latency, the H1 hypothesis.
 *   H1q (per-packet queueing delay): for the k-th packet in a pass, the time
 *       from pass start to its post_packet() call -- a packet at index k
 *       waited behind k earlier packets' classify+push+wake.  Bucketed.
 *   H2 (post_packet cost): wall time of classify+push+wake for one packet.
 *
 * H3 (wake->run) is measured by the sibling WAKEPROF; H4 (PG compute) and
 * H5 (TX + NIC round-trip) are inferred as: round_trip - (H1+H2+H3+...).
 *
 * A background thread prints to the console every 5s (captured over serial).
 * Zero cost when off. Generic net/sched instrumentation, no PG awareness.
 */
#ifndef RXPROF_HH
#define RXPROF_HH

#include <atomic>
#include <osv/types.h>
#include <osv/clock.hh>

namespace rxprof {
    extern bool enabled;

    // log2(ns) histograms, buckets 0..NB-1 (<1ns .. ~2^27 ns == ~134ms).
    static const int NB = 28;
    extern std::atomic<u64> drain_ns_hist[NB];   // wall time to drain one pass
    extern std::atomic<u64> gap_ns_hist[NB];     // idle gap between passes
    extern std::atomic<u64> h1q_ns_hist[NB];     // per-packet queueing delay (pass_start->post)
    extern std::atomic<u64> h2_ns_hist[NB];      // post_packet wall time (one packet)
    extern std::atomic<u64> batch_hist[64];      // packets drained per pass

    extern std::atomic<u64> passes;              // number of drain passes
    extern std::atomic<u64> packets;             // total packets classified
    extern std::atomic<u64> drain_ns_sum;
    extern std::atomic<u64> gap_ns_sum;
    extern std::atomic<u64> h1q_ns_sum;
    extern std::atomic<u64> h2_ns_sum;
    extern std::atomic<u64> h2_ns_max;

    inline int bucket(u64 ns) {
        int b = 0;
        while (ns > 1 && b < NB - 1) { ns >>= 1; b++; }
        return b;
    }
    inline u64 now_ns() {
        return osv::clock::uptime::now().time_since_epoch().count();
    }
    inline void rec_hist(std::atomic<u64>* h, u64 ns) {
        h[bucket(ns)].fetch_add(1, std::memory_order_relaxed);
    }
    // one packet processed inside a pass: k = its 0-based index in the pass,
    // pass_start = pass start ns, pre/post = timestamps around post_packet().
    inline void record_packet(u64 pass_start, u64 pre, u64 post) {
        if (!enabled) return;
        u64 q = pre > pass_start ? pre - pass_start : 0;   // H1 queueing delay
        u64 h2 = post > pre ? post - pre : 0;              // H2 post_packet cost
        rec_hist(h1q_ns_hist, q);
        rec_hist(h2_ns_hist, h2);
        h1q_ns_sum.fetch_add(q, std::memory_order_relaxed);
        h2_ns_sum.fetch_add(h2, std::memory_order_relaxed);
        packets.fetch_add(1, std::memory_order_relaxed);
        u64 om = h2_ns_max.load(std::memory_order_relaxed);
        while (h2 > om && !h2_ns_max.compare_exchange_weak(om, h2)) {}
    }
    // one drain pass completed: batch packets, drain wall time, idle gap since
    // the previous pass ended.
    inline void record_pass(unsigned batch, u64 drain_ns, u64 gap_ns) {
        if (!enabled) return;
        batch_hist[batch < 64 ? batch : 63].fetch_add(1, std::memory_order_relaxed);
        rec_hist(drain_ns_hist, drain_ns);
        rec_hist(gap_ns_hist, gap_ns);
        passes.fetch_add(1, std::memory_order_relaxed);
        drain_ns_sum.fetch_add(drain_ns, std::memory_order_relaxed);
        gap_ns_sum.fetch_add(gap_ns, std::memory_order_relaxed);
    }

    void dump();
    void arm_from_env();   // called once at boot
}

#endif /* RXPROF_HH */
