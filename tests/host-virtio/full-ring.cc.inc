// Copyright (C) 2026 Greg Burd
// BSD license; see LICENSE in the top-level directory.
#include <cerrno>
#define trace_virtio_blk_req_ok(...) ((void)0)
#define trace_virtio_blk_req_unsupp(...) ((void)0)
#define trace_virtio_blk_req_err(...) ((void)0)
#define trace_virtio_blk_wake(...) ((void)0)
#define trace_virtio_blk_make_request_readonly(...) ((void)0)
#define trace_virtio_blk_make_request_seg_max(...) ((void)0)
static const int sector_size = 512;
enum { BIO_READ, BIO_WRITE, BIO_FLUSH, BIO_DISCARD };
struct bio {
    int bio_cmd = BIO_FLUSH;
    size_t bio_bcount = 0;
    off_t bio_offset = 0;
    void* bio_data = nullptr;
    bool done = false;
};
void biodone(bio* b, bool ok) { assert(ok); b->done = true; }
namespace mmu { constexpr size_t page_size = 4096; }
namespace sched {
struct cpu { int id = 0; static cpu* current() { static cpu c; return &c; } };
}
namespace virtio {
class blk {
public:
    struct blk_outhdr { u32 type, ioprio; u64 sector; };
    struct blk_res { u8 status; };
    struct blk_req {
        explicit blk_req(struct bio* b) : bio(b) {}
        blk_outhdr hdr;
        blk_res res;
        struct bio* bio;
        struct { u64 sector; u32 num_sectors, flags; } discard_desc;
    };
    enum blk_request_type { VIRTIO_BLK_T_IN, VIRTIO_BLK_T_OUT,
                           VIRTIO_BLK_T_FLUSH = 4, VIRTIO_BLK_T_DISCARD = 11 };
    enum { VIRTIO_BLK_F_SEG_MAX = 2, VIRTIO_BLK_F_DISCARD = 13 };
    static constexpr int VIRTIO_BLK_S_OK = 0, VIRTIO_BLK_S_UNSUPP = 2;
    int _num_queues = 1;
    std::vector<mutex> _queue_locks{1};
    struct { u32 seg_max = 0, max_discard_sectors = 0; } _config;
    vring* ring;
    vring* get_virt_queue(int) { return ring; }
    bool is_readonly() { return false; }
    bool get_guest_feature_bit(int) { return false; }
    void req_done(int qid);
    int make_request(struct bio*);
};
// The production consumer waits through the driver's wait_for_queue(); the
// host stand-in polls the predicate through the scheduler shim.
inline void virtio_driver::wait_for_queue(vring* queue, bool (vring::*pred)() const)
{
    sched::thread::wait_until([queue, pred] { return (queue->*pred)(); });
}
}
