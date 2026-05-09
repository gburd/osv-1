/*
 * Copyright (C) 2014 Cloudius Systems, Ltd.
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */


#include <unordered_map>
#include <unordered_set>
#include <deque>
#include <stack>
#include <algorithm>
#include <boost/variant.hpp>
#include <osv/pagecache.hh>
#include <osv/mempool.hh>
#include <osv/export.h>
#include <fs/vfs/vfs.h>
#include <fs/vfs/vfs_id.h>
#include <osv/trace.hh>
#include <osv/prio.hh>

// NOTE: The ARC bridge (IS_ZFS() == true path) is intentionally unreachable
// with the OpenZFS 2.x integration. OpenZFS 2.x made arc_share_buf() a static
// function, breaking the hook that the original BSD-ZFS used to share ARC pages
// directly with the mmap layer. ZFS files now use the regular read_cache path,
// fed by the zfs_vop_cache() vnode hook which calls zfs_read() per page.
//
// No double-caching occurs: ARC caches compressed ZFS blocks; read_cache caches
// decompressed 4KB pages for mmap — they serve different granularities.
//
// The functions register_pagecache_arc_funs(), start_pagecache_access_scanner(),
// unmap_arc_buf(), and map_arc_buf() are kept as no-ops below because
// fs/zfs/zfs_initialize.c (linked into libsolaris.so) still references them.
// A future cleanup can remove both sides once the old BSD-ZFS compat layer is
// fully retired.

// No-op: kept for ABI compatibility with fs/zfs/zfs_initialize.c in libsolaris.so.
extern "C" OSV_LIBSOLARIS_API void register_pagecache_arc_funs(
    void (*)(arc_buf_t*),
    void (*)(arc_buf_t*),
    void (*)(const uint64_t[4]),
    void (*)(arc_buf_t*, uint64_t[4])) {
    // ARC bridge inactive with OpenZFS 2.x — see comment above.
}

namespace std {
template<>
struct hash<pagecache::hashkey> {
    size_t operator()(const pagecache::hashkey key) const noexcept {
        hash<uint64_t> h;
        return h(key.dev) ^ h(key.ino) ^ h(key.offset);
    }
};

template<> struct hash<mmu::hw_ptep<0>> {
    size_t operator()(const mmu::hw_ptep<0>& ptep) const noexcept {
        hash<const mmu::pt_element<0>*> h;
        return h(ptep.release());
    }
};

std::unordered_set<mmu::hw_ptep<0>>::iterator begin(std::unique_ptr<std::unordered_set<mmu::hw_ptep<0>>> const& e)
{
    return e->begin();
}

std::unordered_set<mmu::hw_ptep<0>>::iterator end(std::unique_ptr<std::unordered_set<mmu::hw_ptep<0>>> const& e)
{
    return e->end();
}

}

namespace pagecache {

static unsigned lru_max_length = 100;
static unsigned lru_free_count = 20;
constexpr unsigned max_lru_free_count = 200;
static void* zero_page;

void  __attribute__((constructor(init_prio::pagecache))) setup()
{
    lru_max_length = std::max(memory::phys_mem_size / memory::page_size / 100, size_t(100));
    lru_free_count = std::min(lru_max_length/5, max_lru_free_count);
    zero_page = memory::alloc_page();
    memset(zero_page, 0, mmu::page_size);
}

class cached_page {
protected:
    const hashkey _key;
    void* _page;
    typedef boost::variant<std::nullptr_t, mmu::hw_ptep<0>, std::unique_ptr<std::unordered_set<mmu::hw_ptep<0>>>> ptep_list;
    ptep_list _ptes; // set of pointers to ptes that map the page

    template<typename T>
    class ptes_visitor : public boost::static_visitor<T> {
    protected:
        ptep_list& _ptes;
    public:
        ptes_visitor(ptep_list& ptes) : _ptes(ptes) {}
    };
    class ptep_add : public ptes_visitor<void> {
        mmu::hw_ptep<0>& _ptep;
    public:
        ptep_add(ptep_list& ptes, mmu::hw_ptep<0>& ptep) : ptes_visitor(ptes), _ptep(ptep) {}
        void operator()(std::nullptr_t& v) {
            _ptes = _ptep;
        }
        void operator()(mmu::hw_ptep<0>& ptep) {
            auto ptes = std::unique_ptr<std::unordered_set<mmu::hw_ptep<0>>>(new std::unordered_set<mmu::hw_ptep<0>>({ptep}));
            ptes->emplace(_ptep);
            _ptes = std::move(ptes);
        }
        void operator()(std::unique_ptr<std::unordered_set<mmu::hw_ptep<0>>>& set) {
            set->emplace(_ptep);
        }
    };
    class ptep_remove : public ptes_visitor<int> {
        mmu::hw_ptep<0>& _ptep;
    public:
        ptep_remove(ptep_list& ptes, mmu::hw_ptep<0>& ptep) : ptes_visitor(ptes), _ptep(ptep) {}
        int operator()(std::nullptr_t &v) {
            assert(0);
            return -1;
        }
        int operator()(mmu::hw_ptep<0>& ptep) {
            _ptes = nullptr;
            return 0;
        }
        int operator()(std::unique_ptr<std::unordered_set<mmu::hw_ptep<0>>>& set) {
            set->erase(_ptep);
            if (set->size() == 1) {
                auto pte = *(set->begin());
                _ptes = pte;
                return 1;
            }
            return set->size();
        }
    };

    template<typename Map, typename Reduce, typename Ret>
    class map_reduce : public boost::static_visitor<Ret> {
    private:
        Map _mapper;
        Reduce _reducer;
        Ret _initial;
    public:
        map_reduce(Map mapper, Reduce reducer, Ret initial) : _mapper(mapper), _reducer(reducer), _initial(initial) {}
        Ret operator()(std::nullptr_t &v) {
            return _initial;
        }
        Ret operator()(mmu::hw_ptep<0>& ptep) {
            return _reducer(_initial, _mapper(ptep));
        }
        Ret operator()(std::unique_ptr<std::unordered_set<mmu::hw_ptep<0>>>& set) {
            Ret acc = _initial;
            for (auto&& i: set) {
              acc = _reducer(acc, _mapper(i));
            }
            return acc;
        }
    };

    template <typename Map, typename Reduce = std::plus<int>, typename Ret = int>
    Ret for_each_pte(Map mapper, Reduce reducer = std::plus<int>(), Ret initial = 0)
    {
        map_reduce<Map, Reduce, Ret> mr(mapper, reducer, initial);
        return boost::apply_visitor(mr, _ptes);
    }

public:
    cached_page(hashkey key, void* page) : _key(key), _page(page) {
    }
    virtual ~cached_page() {
    }

    void map(mmu::hw_ptep<0> ptep) {
        ptep_add add(_ptes, ptep);
        boost::apply_visitor(add, _ptes);
    }
    int unmap(mmu::hw_ptep<0> ptep) {
        ptep_remove rm(_ptes, ptep);
        return boost::apply_visitor(rm, _ptes);
    }
    void* addr() {
        return _page;
    }
    int flush() {
        return for_each_pte([] (mmu::hw_ptep<0> pte) { mmu::clear_pte(pte); return 1;});
    }
    int clear_accessed() {
        return for_each_pte([] (mmu::hw_ptep<0> pte) -> int { return mmu::clear_accessed(pte); });
    }
    int clear_dirty() {
        return for_each_pte([] (mmu::hw_ptep<0> pte) -> int { return mmu::clear_dirty(pte); });
    }
    const hashkey& key() {
        return _key;
    }
};

class cached_page_write : public cached_page {
private:
    struct vnode* _vp;
    bool _dirty = false;
public:
    cached_page_write(hashkey key, vfs_file* fp) : cached_page(key, memory::alloc_page()) {
        _vp = fp->f_dentry->d_vnode;
        vref(_vp);
    }
    virtual ~cached_page_write() {
        if (_page) {
            if (_dirty) {
                writeback();
            }
            memory::free_page(_page);
            vrele(_vp);
        }
    }
    int writeback()
    {
        int error;
        struct iovec iov {_page, mmu::page_size};
        struct uio uio {&iov, 1, _key.offset, mmu::page_size, UIO_WRITE};

        _dirty = false;

        vn_lock(_vp);
        error = VOP_WRITE(_vp, &uio, 0);
        vn_unlock(_vp);

        return error;
    }
    void* release() { // called to demote a page from cache page to anonymous
        assert(boost::get<std::nullptr_t>(_ptes) == nullptr);
        void *p = _page;
        _page = nullptr;
        vrele(_vp);
        return p;
    }
    void mark_dirty() {
        _dirty |= true;
    }
    bool flush_check_dirty() {
        return for_each_pte([] (mmu::hw_ptep<0> pte) { return mmu::clear_pte(pte).dirty(); }, std::logical_or<bool>(), false);
    }
};

static std::unordered_map<hashkey, cached_page*> read_cache;
static std::unordered_map<hashkey, cached_page_write*> write_cache;
static std::deque<cached_page_write*> write_lru;
static mutex read_lock; // protects against parallel access to the read cache
static mutex write_lock; // protect against parallel access to the write cache

template<typename T>
static T find_in_cache(std::unordered_map<hashkey, T>& cache, hashkey& key)
{
    auto cpi = cache.find(key);

    if (cpi == cache.end()) {
        return nullptr;
    } else {
        return cpi->second;
    }
}

static void add_read_mapping(cached_page *cp, mmu::hw_ptep<0> ptep)
{
    cp->map(ptep);
}

template<typename T>
static void remove_read_mapping(std::unordered_map<hashkey, T>& cache, cached_page* cp, mmu::hw_ptep<0> ptep)
{
    if (cp->unmap(ptep) == 0) {
        cache.erase(cp->key());
        delete cp;
    }
}

void remove_read_mapping(hashkey& key, mmu::hw_ptep<0> ptep)
{
    SCOPE_LOCK(read_lock);
    cached_page* cp = find_in_cache(read_cache, key);
    if (cp) {
        remove_read_mapping(read_cache, cp, ptep);
        // The method remove_read_mapping() is called by pagecache::get()
        // to handle MAP_PRIVATE COW (Copy-On-Write) scenario triggered by an attempt to write
        // to read-only page in read_cache (write protection page-fault). To handle it properly
        // we need to remove the existing mapping for specified file hash (ino, offset) so that
        // the physical address of newly allocated read-write page with the exact copy of
        // the original data can be placed in pte instead.
        // Normally this works fine and the application continues after and reads from/writes to
        // new allocated page. But sometimes when applications "mmap" same portions of the same file
        // with MAP_PRIVATE flag at the same time from multiple threads under load,
        // those threads get migrated to different CPUs so it is important we flush tlb
        // on all cpus. Otherwise given thread after migrated to different CPU may still see old
        // read-only page with stale data and cause spectacular crash.
        // The fact we have to flush tlb is very unfortunate as it is pretty expensive operation.
        // On positive side most applications loaded from Read-Only FS will experience pretty limited
        // number of COW faults mostly caused by ELF linker writing to GOT or PLT section.
        // TODO 1: Investigate if there is an alternative "cheaper" way to solve this problem.
        // TODO 2: Investigate why flushing TLB is necessary in single CPU scenario.
        // TODO 3: Investigate why we do not have to flush tlb when removing read mapping with ZFS.
        mmu::flush_tlb_all();
    }
}

template<typename T>
static unsigned drop_read_cached_page(std::unordered_map<hashkey, T>& cache, cached_page* cp, bool flush)
{
    int flushed = cp->flush();
    cache.erase(cp->key());

    if (flush && flushed > 1) { // if there was only one pte it is the one we are faulting on; no need to flush.
        mmu::flush_tlb_all();
    }

    delete cp;

    return flushed;
}

static void drop_read_cached_page(hashkey& key)
{
    SCOPE_LOCK(read_lock);
    cached_page* cp = find_in_cache(read_cache, key);
    if (cp) {
        drop_read_cached_page(read_cache, cp, true);
    }
}

// No-op: ARC bridge inactive with OpenZFS 2.x (see comment near register_pagecache_arc_funs).
// Kept for ABI compatibility with bsd/porting/mmu.cc in loader.elf.
void unmap_arc_buf(arc_buf_t*) {}

// No-op: ARC bridge inactive with OpenZFS 2.x (see comment near register_pagecache_arc_funs).
// Kept for ABI compatibility with bsd/porting/mmu.cc in loader.elf.
void map_arc_buf(hashkey*, arc_buf_t*, void*) {}

void map_read_cached_page(hashkey *key, void *page)
{
    SCOPE_LOCK(read_lock);
    cached_page* pc = new cached_page(*key, page);
    read_cache.emplace(*key, pc);
}

// C-linkage helpers used by ZFS vop_cache (zfs_vnops_os.c is a C file).
extern "C" void osv_pagecache_map_page(void *key, void *page)
{
    map_read_cached_page(static_cast<hashkey*>(key), page);
}

extern "C" void *osv_alloc_page(void)
{
    return memory::alloc_page();
}

extern "C" void osv_free_page(void *p)
{
    memory::free_page(p);
}

static int create_read_cached_page(vfs_file* fp, hashkey& key)
{
    return fp->read_page_from_cache(&key, key.offset);
}

static std::unique_ptr<cached_page_write> create_write_cached_page(vfs_file* fp, hashkey& key)
{
    size_t bytes;
    cached_page_write* cp = new cached_page_write(key, fp);
    struct iovec iov {cp->addr(), mmu::page_size};

    assert(sys_read(fp, &iov, 1, key.offset, &bytes) == 0);
    return std::unique_ptr<cached_page_write>(cp);
}

TRACEPOINT(trace_drop_write_cached_page, "addr=%p", void*);
static void insert(cached_page_write* cp) {
    static cached_page_write* tofree[max_lru_free_count];
    write_cache.emplace(cp->key(), cp);
    write_lru.push_front(cp);

    if (write_lru.size() > lru_max_length) {
        for (unsigned i = 0; i < lru_free_count; i++) {
            cached_page_write *p = write_lru.back();
            write_lru.pop_back();
            trace_drop_write_cached_page(p->addr());
            write_cache.erase(p->key());
            if (p->flush_check_dirty()) {
                p->mark_dirty();
            }
            tofree[i] = p;
        }
        mmu::flush_tlb_all();
        for (auto p: tofree) {
            delete p;
        }
    }
}

bool get(vfs_file* fp, off_t offset, mmu::hw_ptep<0> ptep, mmu::pt_element<0> pte, bool write, bool shared)
{
    struct stat st;
    fp->stat(&st);
    hashkey key {st.st_dev, st.st_ino, offset};
    SCOPE_LOCK(write_lock);
    cached_page_write* wcp = find_in_cache(write_cache, key);

    if (write) {
        if (!wcp) {
            auto newcp = create_write_cached_page(fp, key);
            if (shared) {
                // write fault into shared mapping, there page is not in write cache yet, add it.
                wcp = newcp.release();
                insert(wcp);
                // page is moved from read cache to write cache
                // drop read page if exists, removing all mappings
                drop_read_cached_page(key);
            } else {
                // remove mapping to read cache page if exists
                remove_read_mapping(key, ptep);
                // cow (copy-on-write) of private page from read cache
                return mmu::write_pte(newcp->release(), ptep, pte);
            }
        } else if (!shared) {
            // cow (copy-on-write) of private page from write cache
            void* page = memory::alloc_page();
            memcpy(page, wcp->addr(), mmu::page_size);
            return mmu::write_pte(page, ptep, pte);
        }
    } else if (!wcp) {
        int ret;
        // read fault and page is not in write cache yet, return one from read cache, mark it cow
        do {
            WITH_LOCK(read_lock) {
                cached_page* cp = find_in_cache(read_cache, key);
                if (cp) {
                    add_read_mapping(cp, ptep);
                    return mmu::write_pte(cp->addr(), ptep, mmu::pte_mark_cow(pte, true));
                }
            }

            DROP_LOCK(write_lock) {
                // page is not in cache yet, create and try again
                // function may sleep so drop write lock while executing it
                ret = create_read_cached_page(fp, key);
            }

            // we dropped write lock, need to re-check write cache again
            wcp = find_in_cache(write_cache, key);
            if (wcp) {
                // write cache page appeared while we were creating a read cache page from ARC
                // return will cause faulting thread to re-fault and we will try again
                return false;
            }

        } while (ret != -1);

        // try to access a hole in a file, map by zero_page
        return mmu::write_pte(zero_page, ptep, mmu::pte_mark_cow(pte, true));
    }

    wcp->map(ptep);

    return mmu::write_pte(wcp->addr(), ptep, mmu::pte_mark_cow(pte, !shared));
}

bool release(vfs_file* fp, void *addr, off_t offset, mmu::hw_ptep<0> ptep)
{
    struct stat st;
    fp->stat(&st);
    hashkey key {st.st_dev, st.st_ino, offset};

    auto old = clear_pte(ptep);

    // page is either in ARC cache or write cache or zero page or private page

    WITH_LOCK(write_lock) {
        cached_page_write* wcp = find_in_cache(write_cache, key);

        if (wcp && mmu::virt_to_phys(wcp->addr()) == old.addr()) {
            // page is in write cache
            wcp->unmap(ptep);
            if (old.dirty()) {
                // unmapped pte was dirty, mark page dirty for writeback
                wcp->mark_dirty();
            }
            return false;
        }
    }

    WITH_LOCK(read_lock) {
        cached_page* rcp = find_in_cache(read_cache, key);
        if (rcp && mmu::virt_to_phys(rcp->addr()) == old.addr()) {
            // page is in read cache
            remove_read_mapping(read_cache, rcp, ptep);
            return false;
        }
    }

    // if a private page, caller will free it
    return addr != zero_page;
}

void sync(vfs_file* fp, off_t start, off_t end)
{
    static std::stack<cached_page_write*> dirty; // protected by write_lock
    struct stat st;
    fp->stat(&st);
    hashkey key {st.st_dev, st.st_ino, 0};
    SCOPE_LOCK(write_lock);

    for (key.offset = start; key.offset < end; key.offset += mmu::page_size) {
        cached_page_write* cp = find_in_cache(write_cache, key);
        if (cp && cp->clear_dirty()) {
            dirty.push(cp);
        }
    }

    mmu::flush_tlb_all();

    while(!dirty.empty()) {
        auto cp = dirty.top();
        auto err = cp->writeback();
        if (err) {
            throw make_error(err);
        }
        dirty.pop();
    }
}

}

// No-op: ARC access scanner is not used with OpenZFS 2.x (see comment near
// register_pagecache_arc_funs). Kept for ABI compatibility with libsolaris.so.
extern "C" OSV_LIBSOLARIS_API void start_pagecache_access_scanner() {}
