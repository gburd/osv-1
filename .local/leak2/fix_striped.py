#!/usr/bin/env python3
# LEAK #2 FIX (final): AS-tied identity-heap fallback tracker, STRIPED + CHAINED.
#
# The safe mechanism (proven: 0 corruption, never faults -- identity-heap VAs are
# coherent in every address space): when a forked child's malloc falls through
# the exhausted fork arena to the identity heap, record (ptr -> child AS); free
# it per-pointer on free(); and sweep the whole AS on reap
# (destroy_address_space). The two per-AS-private-VA designs (VA-reclaim, per-AS
# overflow region) both faulted on the COW boundary; this one cannot, because it
# frees the SAME identity-heap object the app allocated, tied to its AS.
#
# Throughput: the earlier single-lock version wedged under 32-way churn. This
# version SHARDS by pointer hash into 256 independent stripes (each: own spinlock,
# hash buckets, node pool, free-list, per-AS chain heads) so concurrent
# malloc/free contend different locks. All ops are O(1) via chaining (no open-
# addressing backward-shift): insert pops a free node and links it into its hash
# bucket + its (AS,stripe) chain; erase unlinks from both; reap walks each
# stripe's AS-chain and returns the nodes. Fixed BSS, no dynamic allocation.
#
# Env-gated OSV_FORK_ARENA_RECLAIM (default ON; =0 => old identity-heap leak A/B).
# Idempotent.
import sys
MEMPOOL="core/mempool.cc"; MMU="core/mmu.cc"; HH="include/osv/fork_arena.hh"; FA="core/fork_arena.cc"
def rd(p):
    with open(p, encoding="utf-8") as f: return f.read()
def wr(p,s):
    with open(p,"w",encoding="utf-8") as f: f.write(s)

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
// ---- LEAK #2 FIX: AS-tied fallback tracker (striped + chained, fixed BSS) ---
// Records identity-heap FALLBACK allocations made by a forked CHILD address
// space (after the fork arena exhausts) so destroy_address_space() frees them on
// reap -- they are otherwise never freed (the identity heap is shared verbatim
// in every AS and not tied to a child), which is the ~0.77 MB/backend leak.
// Sharded 256 ways by pointer hash to avoid the single-lock wedge; chained (not
// open-addressing) so insert/erase/reap are all O(1) with no backward-shift.
namespace {
#if CONF_fork
constexpr unsigned FB_STRIPES = 256;
constexpr unsigned FB_STRIPE_MASK = FB_STRIPES - 1;
constexpr unsigned FB_NODES_PER = 4096;   // live fallback allocs per stripe cap
constexpr unsigned FB_BUCKETS = 2048;     // hash buckets per stripe
constexpr unsigned FB_BUCKET_MASK = FB_BUCKETS - 1;
constexpr unsigned FB_AS_PER = 32;        // concurrent AS with entries per stripe
constexpr int FB_NIL = -1;
struct fb_node { void *ptr; void *as; size_t size; int hnext; int aprev; int anext; };
struct fb_stripe {
    spinlock lock;
    bool     inited;
    int      buckets[FB_BUCKETS];       // -> node index or NIL
    fb_node  nodes[FB_NODES_PER];
    int      free_head;                 // free-list of node indices
    void    *as_key[FB_AS_PER];         // AS -> chain-head slot
    int      as_head[FB_AS_PER];
};
fb_stripe g_fb[FB_STRIPES];
std::atomic<unsigned long> g_fb_live{0};
__thread void *t_fb_pending_as = nullptr;

inline unsigned fb_stripe_of(void *p){ return (unsigned)((reinterpret_cast<uintptr_t>(p) >> 4)) & FB_STRIPE_MASK; }
inline unsigned fb_bucket_of(void *p){ return (unsigned)((reinterpret_cast<uintptr_t>(p) >> 12) * 0x9E3779B1u) & FB_BUCKET_MASK; }

void fb_stripe_init(fb_stripe &s){
    for (unsigned i=0;i<FB_BUCKETS;i++) s.buckets[i]=FB_NIL;
    for (unsigned i=0;i<FB_NODES_PER;i++) s.nodes[i].hnext=(int)(i+1);
    s.nodes[FB_NODES_PER-1].hnext=FB_NIL;
    s.free_head=0;
    for (unsigned i=0;i<FB_AS_PER;i++){ s.as_key[i]=nullptr; s.as_head[i]=FB_NIL; }
    s.inited=true;
}
int fb_as_slot(fb_stripe &s, void *as, bool create){
    for (unsigned i=0;i<FB_AS_PER;i++) if (s.as_key[i]==as) return (int)i;
    if (!create) return -1;
    for (unsigned i=0;i<FB_AS_PER;i++) if (s.as_key[i]==nullptr){ s.as_key[i]=as; s.as_head[i]=FB_NIL; return (int)i; }
    return -1;   // AS table full for this stripe: track unchained (won't be swept)
}
void fb_track_insert(void *ptr, void *as, size_t size){
    fb_stripe &s=g_fb[fb_stripe_of(ptr)];
    SCOPE_LOCK(s.lock);
    if (!s.inited) fb_stripe_init(s);
    int n=s.free_head;
    if (n==FB_NIL) return;                 // stripe full: drop (reverts to old leak)
    s.free_head=s.nodes[n].hnext;
    fb_node &nd=s.nodes[n];
    nd.ptr=ptr; nd.as=as; nd.size=size;
    unsigned b=fb_bucket_of(ptr);
    nd.hnext=s.buckets[b]; s.buckets[b]=n;
    int as_i=fb_as_slot(s, as, true);
    if (as_i>=0){
        nd.aprev=FB_NIL; nd.anext=s.as_head[as_i];
        if (nd.anext!=FB_NIL) s.nodes[nd.anext].aprev=n;
        s.as_head[as_i]=n;
    } else { nd.aprev=FB_NIL; nd.anext=FB_NIL; }
    g_fb_live.fetch_add(1, std::memory_order_relaxed);
}
// unlink node n (index) from its hash bucket + AS chain. caller holds s.lock.
void fb_unlink(fb_stripe &s, int n){
    fb_node &nd=s.nodes[n];
    unsigned b=fb_bucket_of(nd.ptr);
    int *pp=&s.buckets[b];
    while (*pp!=FB_NIL && *pp!=n) pp=&s.nodes[*pp].hnext;
    if (*pp==n) *pp=nd.hnext;
    if (nd.aprev!=FB_NIL) s.nodes[nd.aprev].anext=nd.anext;
    else { int as_i=fb_as_slot(s, nd.as, false); if (as_i>=0) s.as_head[as_i]=nd.anext; }
    if (nd.anext!=FB_NIL) s.nodes[nd.anext].aprev=nd.aprev;
    nd.ptr=nullptr; nd.hnext=s.free_head; s.free_head=n;
    g_fb_live.fetch_sub(1, std::memory_order_relaxed);
}
bool fb_track_erase(void *ptr){
    fb_stripe &s=g_fb[fb_stripe_of(ptr)];
    SCOPE_LOCK(s.lock);
    if (!s.inited) return false;
    unsigned b=fb_bucket_of(ptr);
    for (int n=s.buckets[b]; n!=FB_NIL; n=s.nodes[n].hnext){
        if (s.nodes[n].ptr==ptr){ fb_unlink(s,n); return true; }
    }
    return false;
}
#endif
} // anonymous namespace

#if CONF_fork
// Reaper hook (AS0): free every still-live fallback alloc this child made, by
// walking each stripe's AS chain (short per-stripe lock holds, O(live)).
extern "C" void fork_arena_free_as_fallbacks(void *as){
    if (g_fb_live.load(std::memory_order_relaxed)==0) return;
    for (unsigned st=0; st<FB_STRIPES; st++){
        fb_stripe &s=g_fb[st];
        for (;;){
            void *batch[64]; unsigned cnt=0;
            {
                SCOPE_LOCK(s.lock);
                if (!s.inited) break;
                int as_i=fb_as_slot(s, as, false);
                if (as_i<0) break;
                int n=s.as_head[as_i];
                while (n!=FB_NIL && cnt<64){
                    int nx=s.nodes[n].anext;
                    batch[cnt++]=s.nodes[n].ptr;
                    fb_unlink(s, n);       // O(1), returns node; updates as_head
                    n=nx;
                }
                if (cnt==0){ s.as_key[as_i]=nullptr; s.as_head[as_i]=FB_NIL; break; }
            }
            for (unsigned i=0;i<cnt;i++) free(batch[i]);
        }
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

tail="#if CONF_memory_tracker\n    memory::tracker_remember(ret, size);\n#endif\n    return ret;\n}"
if tail not in m: print("FATAL tail"); sys.exit(1)
tailn=("#if CONF_memory_tracker\n    memory::tracker_remember(ret, size);\n#endif\n"
       "#if CONF_fork\n    if (t_fb_pending_as) {\n"
       "        void *as = t_fb_pending_as; t_fb_pending_as = nullptr;\n"
       "        if (ret) fb_track_insert(ret, as, size);\n    }\n#endif\n    return ret;\n}")
m=m.replace(tail,tailn,1)

fa_anchor="    if (!mmu::is_linear_mapped(object, 0)) {\n        return memory::mapped_free_large(object);\n    }"
if fa_anchor not in m: print("FATAL free anchor"); sys.exit(1)
fan=("#if CONF_fork\n    if (g_fb_live.load(std::memory_order_relaxed) != 0) fb_track_erase(object);\n#endif\n"
     "    if (!mmu::is_linear_mapped(object, 0)) {\n        return memory::mapped_free_large(object);\n    }")
m=m.replace(fa_anchor,fan,1)
wr(MEMPOOL,m); print("mempool.cc striped tracker applied")

h=rd(HH)
if "arena_reclaim_on" not in h:
    hk="void release_as(void *as);"
    h=h.replace(hk, hk+"\n\n// LEAK #2 FIX: OSV_FORK_ARENA_RECLAIM env gate (default ON).\nbool arena_reclaim_on();",1)
    wr(HH,h); print("fork_arena.hh")

fa=rd(FA)
if "arena_reclaim_on" not in fa:
    fa=fa.replace("#include <cstring>","#include <cstring>\n#include <cstdlib>",1)
    ia="void release_as(void *as)\n{"
    impl=("bool arena_reclaim_on()\n{\n    static int cached=-1; int v=cached;\n"
          "    if (v<0){ const char *e=getenv(\"OSV_FORK_ARENA_RECLAIM\"); v=(e&&e[0]=='0')?0:1; cached=v; }\n"
          "    return v!=0;\n}\n\n")
    fa=fa.replace(ia, impl+ia,1); wr(FA,fa); print("fork_arena.cc")

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
    wr(MMU,mm); print("mmu.cc")
print("STRIPED TRACKER DONE")
