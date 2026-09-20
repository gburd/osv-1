#!/usr/bin/env python3
# LEAK #2 FIX v3 (SAFE, AS-tied fallback; no full-table lock scan).
#
# v2 hung: the reaper's per-AS sweep held g_fb_lock across a 131072-slot linear
# scan (repeated in a batch loop) while all 32 app threads contended the same
# lock on every fallback malloc/free -> effective wedge. v3 threads a per-AS
# doubly-linked chain THROUGH the hash entries (by index, in BSS), so teardown
# walks only that AS's own entries (O(live-for-AS)) with short lock holds, and
# insert/erase stay O(1). Same safety: g_bump monotonic, no VA reissue; the
# arena-exhausted identity-heap fallback is made AS-tied so destroy_address_space
# frees it on reap. Env-gated OSV_FORK_ARENA_RECLAIM (default ON). Idempotent.
import sys
MEMPOOL="core/mempool.cc"; MMU="core/mmu.cc"; HH="include/osv/fork_arena.hh"; FA="core/fork_arena.cc"
def rd(p):
    with open(p, encoding="utf-8") as f: return f.read()
def wr(p, s):
    with open(p, "w", encoding="utf-8") as f: f.write(s)

m=rd(MEMPOOL)
if "fb_track" in m: print("mempool.cc already patched"); sys.exit(0)

inc="#if CONF_fork\n#include <osv/fork_arena.hh>\n#include <osv/wait_record.hh>\n#endif\n"
if inc not in m: print("FATAL inc"); sys.exit(1)
m=m.replace(inc, inc+"#if CONF_fork\n#include <osv/spinlock.h>\n#endif\n",1)

probe=('extern "C" void leak_probe_app_fallback(unsigned long *bytes, unsigned long *count) {\n'
 "    if (bytes) *bytes = g_app_fallback_bytes.load(std::memory_order_relaxed);\n"
 "    if (count) *count = g_app_fallback_count.load(std::memory_order_relaxed);\n}\n")
if probe not in m: print("FATAL probe (run instrument.py first)"); sys.exit(1)

tracker=probe + r'''
// ---- LEAK #2 FIX: AS-tied fallback tracker (fixed BSS, per-AS chained) -----
// Maps an identity-heap FALLBACK pointer -> the child address_space that made
// it, so destroy_address_space() can free it on reap (it is otherwise never
// freed once the fork arena has exhausted -> ~0.77 MB/backend leak). No dynamic
// allocation (entered from inside malloc/free); one spinlock; open-addressing
// hash for O(1) ptr lookup PLUS a per-AS doubly-linked chain threaded through
// the entries by index, so a reap frees only that AS's entries (O(live-for-AS))
// with short lock holds -- never a full-table scan (that wedged v2).
namespace {
#if CONF_fork
constexpr unsigned fb_bits = 18;                 // 262144 slots
constexpr unsigned fb_size = 1u << fb_bits;
constexpr unsigned fb_mask = fb_size - 1;
constexpr int FB_NIL = -1;
struct fb_ent { void *ptr; void *as; size_t size; int aprev, anext; };
fb_ent  g_fb_track[fb_size];      // BSS: ptr==nullptr => empty slot
spinlock g_fb_lock;
std::atomic<unsigned long> g_fb_live{0};
// Per-AS chain heads: a small fixed table AS* -> head index into g_fb_track.
constexpr unsigned fb_as_max = 512;
struct fb_as_head { void *as; int head; };
fb_as_head g_fb_as[fb_as_max];    // BSS: as==nullptr => free
__thread void *t_fb_pending_as = nullptr;

inline unsigned fb_hash(void *p) {
    uintptr_t x = reinterpret_cast<uintptr_t>(p) >> 4;
    return (unsigned)((x * 0x9E3779B97F4A7C15ull) >> (64 - fb_bits)) & fb_mask;
}
// find/create the AS-head entry (caller holds g_fb_lock). Returns index in
// g_fb_as, or -1 if the AS table is full (then the ptr is tracked but unchained
// -> it just won't be swept on reap; correctness preserved, only completeness).
int fb_as_slot(void *as) {
    for (unsigned i=0;i<fb_as_max;i++) if (g_fb_as[i].as==as) return (int)i;
    for (unsigned i=0;i<fb_as_max;i++) if (g_fb_as[i].as==nullptr) {
        g_fb_as[i].as=as; g_fb_as[i].head=FB_NIL; return (int)i;
    }
    return -1;
}
void fb_track_insert(void *ptr, void *as, size_t size) {
    SCOPE_LOCK(g_fb_lock);
    unsigned h=fb_hash(ptr);
    for (unsigned i=0;i<fb_size;i++){
        unsigned s=(h+i)&fb_mask;
        if (g_fb_track[s].ptr==nullptr){
            int hs=fb_as_slot(as);
            g_fb_track[s].ptr=ptr; g_fb_track[s].as=as; g_fb_track[s].size=size;
            g_fb_track[s].aprev=FB_NIL; g_fb_track[s].anext=FB_NIL;
            if (hs>=0){
                int old=g_fb_as[hs].head;
                g_fb_track[s].anext=old;
                if (old!=FB_NIL) g_fb_track[old].aprev=(int)s;
                g_fb_as[hs].head=(int)s;
            }
            g_fb_live.fetch_add(1, std::memory_order_relaxed);
            return;
        }
        if (g_fb_track[s].ptr==ptr){ g_fb_track[s].size=size; return; }  // shouldn't happen
    }
    // table full: drop (this alloc reverts to old leak)
}
// unchain slot s from its AS list (caller holds lock).
inline void fb_unchain(unsigned s){
    int p=g_fb_track[s].aprev, n=g_fb_track[s].anext;
    if (p!=FB_NIL) g_fb_track[p].anext=n;
    else {
        void *as=g_fb_track[s].as;
        for (unsigned i=0;i<fb_as_max;i++) if (g_fb_as[i].as==as){ g_fb_as[i].head=n; break; }
    }
    if (n!=FB_NIL) g_fb_track[n].aprev=p;
}
// Robin-hood-free backward-shift delete to keep probe chains valid. Re-inserting
// a shifted entry re-links it, so we re-thread AS chains as we shift.
bool fb_track_erase(void *ptr){
    SCOPE_LOCK(g_fb_lock);
    unsigned h=fb_hash(ptr);
    for (unsigned i=0;i<fb_size;i++){
        unsigned s=(h+i)&fb_mask;
        if (g_fb_track[s].ptr==nullptr) return false;
        if (g_fb_track[s].ptr==ptr){
            fb_unchain(s);
            g_fb_track[s].ptr=nullptr;
            g_fb_live.fetch_sub(1, std::memory_order_relaxed);
            // backward-shift: move any following entry whose ideal slot lets it
            // fill the hole; re-thread its AS chain by fixing neighbor indices.
            unsigned j=s;
            for (unsigned k=1;k<fb_size;k++){
                unsigned t=(s+k)&fb_mask;
                if (g_fb_track[t].ptr==nullptr) break;
                unsigned hh=fb_hash(g_fb_track[t].ptr);
                bool movable=(j<=t)?(hh<=j||hh>t):(hh<=j&&hh>t);
                if (movable){
                    // relink AS chain: neighbors of t now point at j
                    int tp=g_fb_track[t].aprev, tn=g_fb_track[t].anext;
                    g_fb_track[j]=g_fb_track[t];
                    if (tp!=FB_NIL) g_fb_track[tp].anext=(int)j;
                    else { void *as=g_fb_track[t].as;
                        for (unsigned x=0;x<fb_as_max;x++) if (g_fb_as[x].as==as){ g_fb_as[x].head=(int)j; break; } }
                    if (tn!=FB_NIL) g_fb_track[tn].aprev=(int)j;
                    g_fb_track[t].ptr=nullptr;
                    j=t;
                }
            }
            return true;
        }
    }
    return false;
}
#endif
} // anonymous namespace

#if CONF_fork
// Reaper hook (AS0): free every still-live fallback allocation this child made,
// by walking ONLY this AS's chain (short lock holds; no full-table scan).
extern "C" void fork_arena_free_as_fallbacks(void *as){
    if (g_fb_live.load(std::memory_order_relaxed)==0) return;
    for (;;){
        void *batch[128]; unsigned n=0;
        {
            SCOPE_LOCK(g_fb_lock);
            int hs=-1;
            for (unsigned i=0;i<fb_as_max;i++) if (g_fb_as[i].as==as){ hs=(int)i; break; }
            if (hs<0) return;              // no chained entries for this AS
            int cur=g_fb_as[hs].head;
            while (cur!=FB_NIL && n<128){
                unsigned s=(unsigned)cur; int nx=g_fb_track[s].anext;
                batch[n++]=g_fb_track[s].ptr;
                // remove s: unchain + backward-shift would move entries, which
                // invalidates nx. Simpler: just null it and unchain; leave the
                // hole (a tombstone). Probe correctness: a null slot ends probes,
                // so we must NOT leave holes mid-chain. Instead detach the whole
                // chain first (below) -- so here we only collect, then clear.
                cur=nx;
            }
            if (n==0){ g_fb_as[hs].as=nullptr; g_fb_as[hs].head=FB_NIL; return; }
            // Clear the collected entries with proper backward-shift by erasing
            // each ptr via the hash (keeps probe chains valid). Do it outside via
            // fb_track_erase after releasing the lock is cleaner, but erase takes
            // the lock again; so erase here inline is fine -- release first.
        }
        for (unsigned i=0;i<n;i++){ fb_track_erase(batch[i]); }  // keeps hash valid
        for (unsigned i=0;i<n;i++){ free(batch[i]); }
        if (n<128) break;
    }
}
#endif
'''
m=m.replace(probe, tracker,1)

# fallback note (gated size < 2MB)
fb=("        g_app_fallback_bytes.fetch_add(size, std::memory_order_relaxed);\n"
    "        g_app_fallback_count.fetch_add(1, std::memory_order_relaxed);\n"
    "        // Arena could not serve it (too large / exhausted): fall through to the")
if fb not in m: print("FATAL fb marker"); sys.exit(1)
fbn=("        g_app_fallback_bytes.fetch_add(size, std::memory_order_relaxed);\n"
     "        g_app_fallback_count.fetch_add(1, std::memory_order_relaxed);\n"
     "        // LEAK #2 FIX: child-AS fallback to the identity heap -- note the AS so\n"
     "        // the pointer is tracked at the return and freed on reap. Gate size<2MiB:\n"
     "        // >=2MiB goes via mapped_malloc_large to the child's OWN app-slot mmap,\n"
     "        // already freed by destroy_address_space page teardown (tracking those\n"
     "        // would double-free). The leaking fallbacks are all small (~7.5KB).\n"
     "        if (fork_arena::arena_reclaim_on() && size < mmu::huge_page_size) {\n"
     "            mmu::address_space *cas = mmu::current_address_space();\n"
     "            if (cas != mmu::kernel_address_space()) t_fb_pending_as = cas;\n"
     "        }\n"
     "        // Arena could not serve it (too large / exhausted): fall through to the")
m=m.replace(fb,fbn,1)

# track at std_malloc's single return
tail="#if CONF_memory_tracker\n    memory::tracker_remember(ret, size);\n#endif\n    return ret;\n}"
if tail not in m: print("FATAL tail"); sys.exit(1)
tailn=("#if CONF_memory_tracker\n    memory::tracker_remember(ret, size);\n#endif\n"
       "#if CONF_fork\n    if (t_fb_pending_as) {\n"
       "        void *as = t_fb_pending_as; t_fb_pending_as = nullptr;\n"
       "        if (ret) fb_track_insert(ret, as, size);\n    }\n#endif\n    return ret;\n}")
m=m.replace(tail,tailn,1)

# free() drain
fa_anchor="    if (!mmu::is_linear_mapped(object, 0)) {\n        return memory::mapped_free_large(object);\n    }"
if fa_anchor not in m: print("FATAL free anchor"); sys.exit(1)
fan=("#if CONF_fork\n    if (g_fb_live.load(std::memory_order_relaxed) != 0) fb_track_erase(object);\n#endif\n"
     "    if (!mmu::is_linear_mapped(object, 0)) {\n        return memory::mapped_free_large(object);\n    }")
m=m.replace(fa_anchor,fan,1)
wr(MEMPOOL,m); print("mempool.cc v3 applied")

h=rd(HH)
if "arena_reclaim_on" not in h:
    hk="void release_as(void *as);"
    h=h.replace(hk, hk+"\n\n// LEAK #2 FIX: OSV_FORK_ARENA_RECLAIM env gate (default ON).\nbool arena_reclaim_on();",1)
    wr(HH,h); print("fork_arena.hh v3")

fa=rd(FA)
if "arena_reclaim_on" not in fa:
    fa=fa.replace("#include <cstring>","#include <cstring>\n#include <cstdlib>",1)
    ia="void release_as(void *as)\n{"
    impl=("bool arena_reclaim_on()\n{\n    static int cached=-1; int v=cached;\n"
          "    if (v<0){ const char *e=getenv(\"OSV_FORK_ARENA_RECLAIM\"); v=(e&&e[0]=='0')?0:1; cached=v; }\n"
          "    return v!=0;\n}\n\n")
    fa=fa.replace(ia, impl+ia,1); wr(FA,fa); print("fork_arena.cc v3")

mm=rd(MMU)
if "fork_arena_free_as_fallbacks" not in mm:
    da="std::atomic<int> live_child_address_spaces{0};"
    mm=mm.replace(da, da+"\n// LEAK #2 FIX: free a reaped child's live identity-heap fallbacks (mempool.cc).\nextern \"C\" void fork_arena_free_as_fallbacks(void *as);",1)
    ra="    fork_arena::release_as(as);\n    delete as;"
    mm=mm.replace(ra,
        "    // LEAK #2 FIX: free this child's still-live identity-heap fallback allocs\n"
        "    // (its per-connection heap not freed before exit) -- else they leak once\n"
        "    // the arena has exhausted.\n"
        "    fork_arena_free_as_fallbacks(as);\n"
        "    fork_arena::release_as(as);\n    delete as;",1)
    wr(MMU,mm); print("mmu.cc v3")
print("V3 DONE")
