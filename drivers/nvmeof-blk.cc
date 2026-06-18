/*
 * NVMe-over-TCP (NVMe/TCP) initiator block device driver for OSv
 *
 * Copyright (C) 2026 OSv Contributors
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 *
 * Implementation: pure C++17, no PCI probe.  Modeled on the Crucible
 * network block driver.
 */

#include "drivers/nvmeof-blk.hh"
#include "drivers/nvmeof-client.hh"
#include "drivers/blk-common.hh"

#include <osv/device.h>
#include <osv/bio.h>
#include <osv/debug.h>
#include <osv/sched.hh>
#include <osv/mutex.h>
#include <osv/condvar.h>

#include <string>
#include <vector>
#include <deque>
#include <memory>
#include <cstring>
#include <algorithm>
#include <errno.h>

using namespace nvmeof;

/*
 * Asynchronous I/O dispatcher for the NVMe/TCP device.
 *
 * The NvmeofClient is synchronous: read_sync/write_sync/flush_sync block
 * the calling thread until the target responds.  We must NOT run that
 * blocking work (nor the biodone it triggers) directly in the strategy
 * callback, because ZFS drives the strategy from a zio I/O taskq thread
 * whose taskq entry (struct ostask) is embedded in the zio itself.
 * Completing the bio inline calls vdev_disk_bio_done -> zio_interrupt,
 * which re-enqueues that same embedded ostask onto the ZIO_TASKQ_INTERRUPT
 * taskq while the issuing thread is still inside taskqueue_run_locked()
 * running that very entry.  A second taskq thread then runs the zio to
 * completion and frees it, and the issuing thread returns to touch the
 * freed-and-reused ostask -- a use-after-free that corrupts the
 * taskqueue's TAILQ links and crashes later.  Virtio and NVMe never hit
 * this because their strategy is async: it queues the request and returns,
 * and the bio is completed later on a dedicated completion thread.  We
 * follow the same model here -- the strategy enqueues the bio and a pool
 * of worker threads performs the blocking I/O and calls biodone off the
 * zio-issue thread.
 */
class nvmeof_io_dispatcher {
public:
    explicit nvmeof_io_dispatcher(int nworkers) {
        _running = true;
        _workers.reserve(nworkers);
        for (int i = 0; i < nworkers; i++) {
            auto* t = sched::thread::make([this] { this->worker_loop(); });
            t->start();
            _workers.push_back(t);
        }
    }

    ~nvmeof_io_dispatcher() {
        WITH_LOCK(_mtx) {
            _running = false;
            _cv.wake_all();
        }
        for (auto* t : _workers) {
            t->join();
            delete t;
        }
    }

    void submit(struct bio* bio) {
        WITH_LOCK(_mtx) {
            _queue.push_back(bio);
            _cv.wake_one();
        }
    }

private:
    void worker_loop() {
        while (true) {
            struct bio* bio = nullptr;
            WITH_LOCK(_mtx) {
                while (_running && _queue.empty()) {
                    _cv.wait(&_mtx);
                }
                if (!_running && _queue.empty()) {
                    return;
                }
                bio = _queue.front();
                _queue.pop_front();
            }
            execute(bio);
        }
    }

    static void execute(struct bio* bio);

    mutex _mtx;
    condvar _cv;
    std::deque<struct bio*> _queue;
    std::vector<sched::thread*> _workers;
    bool _running{false};
};

/**
 * Private data for an NVMe/TCP block device.
 */
struct nvmeof_priv {
    std::unique_ptr<NvmeofClient> client;
    std::unique_ptr<nvmeof_io_dispatcher> dispatcher;
    uint64_t disk_size;
    uint32_t block_size;
};

// Maximum number of NVMe/TCP devices supported.
#define MAX_NVMEOF_DEVICES 8

/*
 * Read/write operations.
 *
 * We MUST go through physio() rather than bdev_read/bdev_write -- those
 * route through the OSv buf cache which is hard-coded to BSIZE=512 byte
 * blocks (see fs/vfs/vfs_bdev.cc).  NVMe namespaces commonly use 4096-byte
 * blocks and read_sync/write_sync reject sub-block requests as EINVAL, so
 * the buf-cache path produces a flood of EIO.  physio() hands the whole
 * uio to nvmeof_strategy() as a single bio, which is what we want: one
 * target round trip per logical I/O.
 */
static int nvmeof_read(struct device *dev, struct uio *uio, int ioflags)
{
    return physio(dev, uio, ioflags);
}

static int nvmeof_write(struct device *dev, struct uio *uio, int ioflags)
{
    return physio(dev, uio, ioflags);
}

/**
 * Ioctl operation: no NVMe/TCP-specific commands, fall back to generic.
 */
static int nvmeof_ioctl(struct device *dev, u_long cmd, void *arg)
{
    return blk_ioctl(dev, cmd, arg);
}

/*
 * Perform the (blocking) I/O for one bio and complete it.  Runs on a
 * dispatcher worker thread, never on the ZFS zio-issue taskq thread.
 */
void nvmeof_io_dispatcher::execute(struct bio *bio)
{
    auto* prv = static_cast<struct nvmeof_priv*>(bio->bio_dev->private_data);
    int error = 0;

    if (!prv || !prv->client) {
        biodone(bio, false);
        return;
    }

    // One reconnect attempt per bio: a transport error tears down the
    // controller's queues, so we rebuild the session and reissue the command
    // once.  More than one retry risks wedging the ZFS zio behind an endless
    // reconnect loop against a target that is genuinely gone; a single retry
    // rides out a transient drop without that hazard.
    constexpr int max_attempts = 2;

    for (int attempt = 0; attempt < max_attempts; attempt++) {
        error = 0;
        try {
            switch (bio->bio_cmd) {
                case BIO_READ:
                    error = prv->client->read_sync(
                        bio->bio_offset,
                        bio->bio_bcount,
                        bio->bio_data
                    );
                    break;

                case BIO_WRITE:
                    error = prv->client->write_sync(
                        bio->bio_offset,
                        bio->bio_bcount,
                        bio->bio_data
                    );
                    break;

                case BIO_FLUSH:
                    error = prv->client->flush_sync();
                    break;

                default:
                    error = ENOTBLK;
                    break;
            }
        } catch (const std::exception& e) {
            kprintf("nvmeof_strategy: exception: %s\n", e.what());
            error = EIO;
        } catch (...) {
            kprintf("nvmeof_strategy: unknown exception\n");
            error = EIO;
        }

        // EINVAL/ENOTBLK are caller errors, not transport faults; a reconnect
        // cannot help, so only retry an EIO and only if a session rebuild
        // succeeds.  The single-worker dispatcher guarantees no other command
        // is in flight while we tear the connection down.
        if (error != EIO || attempt + 1 >= max_attempts) {
            break;
        }
        kprintf("nvmeof_strategy: I/O error, attempting reconnect\n");
        if (!prv->client->reconnect()) {
            break;
        }
    }

    bio->bio_error = error;
    biodone(bio, error == 0);
}

/**
 * Block I/O strategy function.
 *
 * Hands the bio to the dispatcher's worker pool and returns immediately so
 * the blocking target I/O (and the biodone it triggers) never runs on the
 * ZFS zio-issue taskq thread.  See nvmeof_io_dispatcher for why.
 */
static void nvmeof_strategy(struct bio *bio)
{
    auto* prv = static_cast<struct nvmeof_priv*>(bio->bio_dev->private_data);

    if (!prv || !prv->dispatcher) {
        biodone(bio, false);
        return;
    }

    prv->dispatcher->submit(bio);
}

/**
 * Device operations structure.
 */
static struct devops nvmeof_devops = {
    .open = no_open,
    .close = no_close,
    .read = nvmeof_read,
    .write = nvmeof_write,
    .ioctl = nvmeof_ioctl,
    .devctl = no_devctl,
    .strategy = nvmeof_strategy,
};

/**
 * Driver structure.
 */
static struct driver nvmeof_driver = {
    .name = "nvmeof",
    .devops = &nvmeof_devops,
    .devsz = sizeof(struct nvmeof_priv),
};

namespace {

/* Parse "host:port"; returns false on malformed input. */
bool parse_target(const std::string& target, std::string& host, uint16_t& port)
{
    auto colon = target.rfind(':');
    if (colon == std::string::npos || colon == 0 ||
        colon + 1 >= target.length()) {
        return false;
    }
    host = target.substr(0, colon);
    long p = std::strtol(target.substr(colon + 1).c_str(), nullptr, 10);
    if (p <= 0 || p > 65535) {
        return false;
    }
    port = static_cast<uint16_t>(p);
    return true;
}

} // namespace

namespace nvmeof {

int nvmeof_init(const std::string& target, const std::string& subnqn,
                const std::string& hostnqn, int device_index)
{
    if (target.empty()) {
        kprintf("nvmeof_init: missing --nvmeof%d target\n", device_index);
        return EINVAL;
    }
    if (subnqn.empty()) {
        kprintf("nvmeof_init: missing subsystem NQN for device %d; skipping\n",
                device_index);
        return EINVAL;
    }
    if (device_index < 0 || device_index >= MAX_NVMEOF_DEVICES) {
        kprintf("nvmeof_init: invalid device_index %d (must be 0-%d)\n",
                device_index, MAX_NVMEOF_DEVICES - 1);
        return EINVAL;
    }

    std::string host;
    uint16_t port = 0;
    if (!parse_target(target, host, port)) {
        kprintf("nvmeof_init: invalid target '%s' (expected host:port)\n",
                target.c_str());
        return EINVAL;
    }

    std::string effective_hostnqn = hostnqn.empty()
        ? "nqn.2014-08.org.nvmexpress:uuid:osv-initiator"
        : hostnqn;

    kprintf("nvmeof_init: device %d target=%s:%u subnqn=%s\n",
            device_index, host.c_str(), port, subnqn.c_str());

    try {
        std::unique_ptr<NvmeofClient> client(
            new NvmeofClient(host, port, subnqn, effective_hostnqn));

        try {
            client->connect();
            client->identify();
        } catch (const std::exception& e) {
            kprintf("nvmeof_init: WARNING: setup failed: %s\n", e.what());
            kprintf("nvmeof_init: boot will continue, but /dev/nvmeof%d "
                    "will not be available\n", device_index);
            return ENOTCONN;
        }

        std::string dev_name = "nvmeof" + std::to_string(device_index);
        struct device* dev =
            device_create(&nvmeof_driver, dev_name.c_str(), D_BLK);

        auto* prv = static_cast<struct nvmeof_priv*>(dev->private_data);
        prv->client = std::move(client);
        prv->block_size = prv->client->get_block_size();
        prv->disk_size = prv->client->total_size();

        /*
         * Single worker thread that runs the synchronous target I/O off the
         * caller's (ZFS zio-issue taskq) thread.  The client serialises every
         * command-through-response round-trip on its single I/O queue under
         * _io_mutex, so additional workers would only queue on that mutex --
         * one worker is sufficient and avoids a misleading fan-out.
         */
        prv->dispatcher.reset(new nvmeof_io_dispatcher(1));

        dev->size = prv->disk_size;
        dev->block_size = prv->block_size;
        dev->max_io_size = 1024 * 1024;   // 1 MiB max I/O

        read_partition_table(dev);

        kprintf("nvmeof_init: SUCCESS: created device %s, size=%llu bytes, "
                "block_size=%u\n", dev_name.c_str(),
                (unsigned long long)prv->disk_size, prv->block_size);

    } catch (const std::exception& e) {
        kprintf("nvmeof_init: WARNING: failed to create client: %s\n",
                e.what());
        kprintf("nvmeof_init: boot will continue, but /dev/nvmeof%d "
                "will not be available\n", device_index);
        return EIO;
    } catch (...) {
        kprintf("nvmeof_init: WARNING: unknown exception during init\n");
        kprintf("nvmeof_init: boot will continue, but /dev/nvmeof%d "
                "will not be available\n", device_index);
        return EIO;
    }

    return 0;
}

} // namespace nvmeof
