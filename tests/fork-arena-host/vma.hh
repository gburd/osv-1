// Copyright (C) 2026 Greg Burd
// SPDX-License-Identifier: BSD-2-Clause
// Platform facade for the real procfs_maps body. Its formatting allocator
// follows the production force_kernel_heap routing decision; allocator logic
// itself is the complete fork_arena.cc body compiled above.
namespace mmu {
constexpr unsigned perm_read = 1, perm_write = 2, perm_exec = 4, mmap_file = 8;
struct test_dentry { const char* d_path = "/test"; };
struct test_file { test_dentry* f_dentry; };
struct file_vma {
    unsigned perm() const { return perm_read | perm_write; }
    unsigned flags() const { return 0; }
    unsigned long start() const { return 0x1000; }
    unsigned long end() const { return 0x2000; }
    unsigned long offset() const { return 0; }
    unsigned long file_dev_id() const { return 0; }
    unsigned long file_inode() const { return 1; }
    test_file* file() const { return nullptr; }
};
std::vector<file_vma> vma_list(1);
struct test_vma_lock {
    test_vma_lock& for_read() { return *this; }
    void lock() {
        host::vma_lock.lock();
        host::vma_held = true;
        host::wait(host::growth_mapping);
    }
    void unlock() { host::vma_lock.unlock(); }
} vma_list_mutex;
}
// decltype(for_read()) is a reference; remove it for the scope guard.
#define WITH_LOCK(x) if (std::lock_guard<std::remove_reference<decltype(x)>::type> JOIN(lock_,__LINE__){x}; true)
namespace osv {
template<class... Args> std::string sprintf(const char* format, Args... args)
{
    char buf[256];
    int n = std::snprintf(buf, sizeof(buf), format, args...);
    assert(n > 0 && size_t(n) < sizeof(buf));
    void* p = fork_arena::force_kernel_heap ? std::malloc(n + 1) : fork_arena::alloc(n + 1, 16);
    assert(p);
    memcpy(p, buf, n + 1);
    std::string result(static_cast<char*>(p));
    if (fork_arena::contains(p)) fork_arena::free(p);
    else std::free(p);
    return result;
}
}
